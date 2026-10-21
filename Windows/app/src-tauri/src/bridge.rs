//! Composer chips bridge: injects `composer-chips.js` into the Codex desktop
//! app through the DevTools protocol and pushes live pool status into the
//! composer — the Windows port of ComposerBridge.swift.
//!
//! Discovery: the Codex app (ChatGPT.exe) must run with
//! `--remote-debugging-port=NNNN`. `MELON_CODEX_DEBUG_PORT` overrides the
//! lookup for manual testing.

use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::Duration;
use tokio_tungstenite::tungstenite::Message;

use crate::paths;
use crate::vault;

const INJECTED_SCRIPT: &str = include_str!("../../resources/composer-chips.js");

pub struct BridgeState {
    pub status: Mutex<Value>,
    /// Debug-port discovery cache — the PowerShell scan is far too heavy for
    /// the 5 s tick.
    discovery: Mutex<Option<(Option<u16>, std::time::Instant)>>,
    /// Rollout path per thread id: saves a full sessions walk every tick.
    session_path: Mutex<Option<(String, PathBuf, std::time::Instant)>>,
    /// Gateway model list for the chips (short freshness).
    models: Mutex<Option<(Value, std::time::Instant)>>,
    /// OpenRouter metrics for the chips popover (5-minute freshness).
    providers: Mutex<Option<(Value, std::time::Instant)>>,
}

impl BridgeState {
    pub fn new() -> Self {
        Self {
            status: Mutex::new(json!({"attached": false, "reason": "starting"})),
            discovery: Mutex::new(None),
            session_path: Mutex::new(None),
            models: Mutex::new(None),
            providers: Mutex::new(None),
        }
    }
}

fn set_status(state: &BridgeState, value: Value) {
    if let Ok(mut guard) = state.status.lock() {
        *guard = value;
    }
}

// MARK: - Process discovery

fn parse_debug_port(line: &str) -> Option<u16> {
    let marker = "remote-debugging-port=";
    let start = line.find(marker)? + marker.len();
    let digits: String = line[start..]
        .chars()
        .take_while(|c| c.is_ascii_digit())
        .collect();
    digits.parse().ok()
}

fn find_debug_port() -> Option<u16> {
    if let Ok(explicit) = std::env::var("MELON_CODEX_DEBUG_PORT") {
        return explicit.parse().ok();
    }
    #[cfg(windows)]
    {
        // The ChatGPT desktop app must be started with the debug flag; read the
        // command lines of its processes.
        let script = "Get-CimInstance Win32_Process -Filter \"Name='ChatGPT.exe'\" | \
                      Select-Object ProcessId,CommandLine | ConvertTo-Json -Compress";
        let mut command = std::process::Command::new("powershell");
        command.args(["-NoProfile", "-NonInteractive", "-Command", script]);
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            command.creation_flags(0x0800_0000);
        }
        let output = command.output().ok()?;
        let text = String::from_utf8_lossy(&output.stdout);
        let value: Value = serde_json::from_str(text.trim()).ok()?;
        let items = match value {
            Value::Array(items) => items,
            single => vec![single],
        };
        for item in items {
            if let Some(line) = item.get("CommandLine").and_then(|v| v.as_str()) {
                if let Some(port) = parse_debug_port(line) {
                    return Some(port);
                }
            }
        }
        None
    }
    #[cfg(not(windows))]
    {
        // Local development fallback (macOS/Linux).
        let output = std::process::Command::new("/bin/ps")
            .args(["-axww", "-o", "command="])
            .output()
            .ok()?;
        let text = String::from_utf8_lossy(&output.stdout);
        for line in text.lines() {
            let executable = line.trim().split(' ').next().unwrap_or("");
            if executable.ends_with("ChatGPT.app/Contents/MacOS/ChatGPT") {
                if let Some(port) = parse_debug_port(line) {
                    return Some(port);
                }
            }
        }
        None
    }
}

/// Cached discovery: the PowerShell process scan runs at most once per TTL,
/// or immediately when the previous port goes silent (Codex restarted).
fn find_debug_port_cached(state: &BridgeState) -> Option<u16> {
    if let Ok(explicit) = std::env::var("MELON_CODEX_DEBUG_PORT") {
        return explicit.parse().ok();
    }
    if let Ok(guard) = state.discovery.lock() {
        if let Some((cached, at)) = guard.as_ref() {
            let ttl = if cached.is_some() { 45 } else { 30 };
            if at.elapsed() < Duration::from_secs(ttl) {
                return *cached;
            }
        }
    }
    let found = find_debug_port();
    if let Ok(mut guard) = state.discovery.lock() {
        *guard = Some((found, std::time::Instant::now()));
    }
    found
}

fn invalidate_discovery(state: &BridgeState) {
    if let Ok(mut guard) = state.discovery.lock() {
        *guard = None;
    }
}

/// One long-lived HTTP client for the whole bridge.
fn client() -> &'static reqwest::Client {
    static CLIENT: std::sync::OnceLock<reqwest::Client> = std::sync::OnceLock::new();
    CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            .timeout(Duration::from_secs(10))
            .build()
            .unwrap_or_default()
    })
}

// MARK: - CDP

async fn fetch_targets(client: &reqwest::Client, port: u16) -> Result<Vec<Value>, String> {
    let value: Value = client
        .get(format!("http://127.0.0.1:{}/json", port))
        .send()
        .await
        .map_err(|e| e.to_string())?
        .json()
        .await
        .map_err(|e| e.to_string())?;
    Ok(value
        .as_array()
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .filter(|t| t.get("type").and_then(|v| v.as_str()) == Some("page"))
        .collect())
}

fn pick_target(targets: &[Value]) -> Option<&Value> {
    targets
        .iter()
        .find(|t| {
            let url = t.get("url").and_then(|v| v.as_str()).unwrap_or("");
            (url.contains("index.html") || url.starts_with("app://")) && !url.contains("avatar-overlay")
        })
        .or_else(|| targets.first())
}

type Ws = tokio_tungstenite::WebSocketStream<
    tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
>;

struct Session {
    ws: Ws,
    next_id: u64,
}

impl Session {
    async fn connect(ws_url: &str) -> Result<Self, String> {
        let (ws, _) = tokio_tungstenite::connect_async(ws_url)
            .await
            .map_err(|e| e.to_string())?;
        Ok(Self { ws, next_id: 1 })
    }

    async fn evaluate(&mut self, expression: &str) -> Result<Option<Value>, String> {
        let id = self.next_id;
        self.next_id += 1;
        let request = json!({
            "id": id,
            "method": "Runtime.evaluate",
            "params": {
                "expression": expression,
                "returnByValue": true,
                "awaitPromise": true,
            }
        });
        self.ws
            .send(Message::Text(request.to_string().into()))
            .await
            .map_err(|e| e.to_string())?;
        let deadline = tokio::time::Instant::now() + Duration::from_secs(15);
        loop {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                return Err("evaluate timeout".to_string());
            }
            match tokio::time::timeout(remaining, self.ws.next()).await {
                Ok(Some(Ok(Message::Text(text)))) => {
                    let value: Value = match serde_json::from_str(text.as_str()) {
                        Ok(value) => value,
                        Err(_) => continue,
                    };
                    if value.get("id").and_then(|v| v.as_u64()) != Some(id) {
                        continue;
                    }
                    if let Some(error) = value.get("error") {
                        return Err(error.to_string());
                    }
                    return Ok(value.pointer("/result/result/value").cloned());
                }
                Ok(Some(Ok(_))) => continue,
                Ok(Some(Err(error))) => return Err(error.to_string()),
                Ok(None) => return Err("сокет закрыт".to_string()),
                Err(_) => return Err("evaluate timeout".to_string()),
            }
        }
    }
}

// MARK: - Chips payload

fn labels(lang: &str) -> Value {
    let ru = lang != "en";
    let pairs: &[(&str, &str, &str)] = &[
        ("accounts", "Аккаунты", "Accounts"),
        ("fiveHour", "5 ч", "5 h"),
        ("week", "Неделя", "Week"),
        ("title", "Статус аккаунтов", "Account status"),
        ("working", "Работают", "Working"),
        ("failed", "С ошибкой", "Failed"),
        ("paused", "На паузе", "Paused"),
        ("refresh", "Обновить квоты", "Refresh quotas"),
        ("context", "Контекст", "Context"),
        ("session", "Сессия", "Session"),
        ("spent", "Потрачено", "Spent"),
        ("sessionSpend", "Расход сессии (оценка)", "Session spend (estimate)"),
        ("estimatedFrom", "Оценка по токенам и цене модели.", "Estimated from tokens and the model price."),
        ("noPricing", "Нет данных о цене модели.", "No pricing data for this model."),
        ("scaledNote", "Старые ходы вне окна чтения; оценка масштабирована.", "Older turns are outside the read window; the estimate is scaled."),
        ("purchased", "Куплено", "Purchased"),
        ("creditsSpent", "Кредиты потрачены", "Credits spent"),
        ("available", "Доступно", "Available"),
        ("keyLimit", "Лимит ключа", "Key limit"),
        ("lifetime", "За всё время", "Lifetime"),
        ("keyUsage", "Расход ключа", "Key usage"),
        ("creditsNote", "Кредиты и лимит ключа — за всё время.", "Credits and the key limit are lifetime figures."),
        ("sessionNoData", "Данные сессии появятся при работе модели этого провайдера.", "Session data appears when a thread runs this provider's models."),
        ("remaining", "Остаток", "Remaining"),
        ("sessionModel", "Модель сессии", "Session model"),
        ("keyRemaining", "Остаток ключа", "Key remaining"),
        ("requests", "Запросы", "Requests"),
        ("updated", "Обновлено", "Updated"),
        ("noData", "Нет данных", "No data"),
        ("tokens", "Токены", "Tokens"),
        ("of", "из", "of"),
        ("yes", "Да", "Yes"),
        ("no", "Нет", "No"),
    ];
    let mut map = serde_json::Map::new();
    for (key, ru_text, en_text) in pairs {
        map.insert(
            (*key).to_string(),
            json!(if ru { ru_text } else { en_text }),
        );
    }
    Value::Object(map)
}

fn injection_source(lang: &str) -> String {
    let config = json!({
        "labels": labels(lang),
        "providers": {"openai": "OpenAI", "opencode": "OpenCode", "openrouter": "OpenRouter"},
    });
    format!(
        "window.__MELON_COMPOSER_CONFIG__ = {};\n{}",
        config, INJECTED_SCRIPT
    )
}

fn provider_of(model: &str) -> &'static str {
    if model.starts_with("opencode/") {
        "opencode"
    } else if model.starts_with("openrouter/") {
        "openrouter"
    } else {
        "openai"
    }
}

/// The payload `window.__melonChipsSetStatus` renders from — the same shape
/// the macOS bridge sends (session/provider details degrade to "no data"
/// until those subsystems are ported).
async fn status_payload(
    state: &BridgeState,
    port: u16,
    api_key: &str,
    openrouter_key: &str,
    model: Option<String>,
) -> Value {
    let accounts = vault::accounts();
    let mut groups: BTreeMap<String, (i64, i64, f64, f64, bool)> = BTreeMap::new();
    let mut failed = 0i64;
    let mut paused = 0i64;
    let mut latest = 0f64;

    for account in &accounts {
        let plan = account
            .plan_type
            .clone()
            .filter(|p| !p.is_empty())
            .unwrap_or_else(|| "unknown".to_string())
            .to_lowercase();
        let entry = groups.entry(plan).or_insert((0, 0, 0.0, 0.0, false));
        entry.0 += 1;
        if let Some(quota) = &account.quota {
            let five = quota.hourly_remaining_percent.unwrap_or(0.0);
            let week = quota.weekly_remaining_percent.unwrap_or(0.0);
            entry.1 += 1;
            entry.2 += five;
            entry.3 += week;
            entry.4 = true;
            if account.quota_error.is_none() && (five <= 0.0 || week <= 0.0) {
                paused += 1;
            }
            if let Some(updated) = account.quota_updated_at {
                if updated > latest {
                    latest = updated;
                }
            }
        }
        if account.quota_error.is_some() {
            failed += 1;
        }
    }

    let total = accounts.len() as i64;
    let working = (total - failed - paused).max(0);
    let group_list: Vec<Value> = groups
        .iter()
        .map(|(plan, (count, quota_count, five, week, has_quota))| {
            json!({
                "plan": plan,
                "count": count,
                "fiveHour": if *has_quota { json!(five.round() as i64) } else { Value::Null },
                "weekly": if *has_quota { json!(week.round() as i64) } else { Value::Null },
                "hasQuota": *has_quota && *quota_count > 0,
            })
        })
        .collect();

    // Picker models: names + providers, so the chips can label the active one.
    let models = picker_models(state, port, api_key).await;

    let mut payload = json!({
        "accounts": total,
        "groups": group_list,
        "health": {
            "working": working,
            "total": total,
            "failed": failed,
            "paused": paused,
        },
        "refreshing": false,
        "updatedAt": if latest > 0.0 { (latest + vault::APPLE_REF_UNIX_OFFSET) as i64 } else { vault::unix_now() as i64 },
        "requests": crate::gateway::requests_last_minute(),
        "models": models,
        "providers": providers_metrics(state, openrouter_key).await,
    });
    let model_name = model.clone().unwrap_or_default();
    payload["active"] = json!({
        "model": if model_name.is_empty() { Value::Null } else { json!(model_name.clone()) },
        "provider": if model_name.is_empty() { Value::Null } else { json!(provider_of(&model_name)) },
    });
    payload
}

/// Gateway model list with a short freshness window — the 5 s tick has no
/// reason to hit the gateway every time.
async fn picker_models(state: &BridgeState, port: u16, api_key: &str) -> Vec<Value> {
    if let Ok(guard) = state.models.lock() {
        if let Some((value, at)) = guard.as_ref() {
            if at.elapsed() < Duration::from_secs(45) {
                return value.as_array().cloned().unwrap_or_default();
            }
        }
    }
    let mut models: Vec<Value> = Vec::new();
    if let Ok(response) = client()
        .get(format!("http://127.0.0.1:{}/v1/models", port))
        .header("Authorization", format!("Bearer {}", api_key))
        .send()
        .await
    {
        if let Ok(list) = response.json::<Value>().await {
            if let Some(array) = list.get("data").and_then(|d| d.as_array()) {
                for item in array {
                    if let Some(id) = item.get("id").and_then(|v| v.as_str()) {
                        let provider = if crate::antigravity::is_antigravity_model_entry(item) {
                            "Antigravity"
                        } else {
                            provider_of(id)
                        };
                        models.push(json!({
                            // Codex displays the catalog display name, not the
                            // raw gateway id. Keep both for exact matching.
                            "name": crate::codex_route::prettify(id),
                            "slug": id,
                            "provider": provider,
                        }));
                    }
                }
            }
        }
    }
    if let Ok(mut guard) = state.models.lock() {
        *guard = Some((Value::Array(models.clone()), std::time::Instant::now()));
    }
    models
}

/// OpenRouter metrics for the chips popover (cached for five minutes).
async fn providers_metrics(state: &BridgeState, openrouter_key: &str) -> Value {
    if openrouter_key.trim().is_empty() {
        return json!({});
    }
    if let Ok(guard) = state.providers.lock() {
        if let Some((value, at)) = guard.as_ref() {
            if at.elapsed() < Duration::from_secs(300) {
                return value.clone();
            }
        }
    }
    let Ok(data) = crate::providers::openrouter(openrouter_key).await else {
        return json!({});
    };
    let value = json!({
        "openrouter": {
            "total": data.get("totalCredits").cloned().unwrap_or(Value::Null),
            "usage": data.get("totalUsage").cloned().unwrap_or(Value::Null),
            "remaining": data.get("remaining").cloned().unwrap_or(Value::Null),
            "keyUsage": data.get("usage").cloned().unwrap_or(Value::Null),
            "keyLimit": data.get("limit").cloned().unwrap_or(Value::Null),
        }
    });
    if let Ok(mut guard) = state.providers.lock() {
        *guard = Some((value.clone(), std::time::Instant::now()));
    }
    value
}

// MARK: - Tick

pub async fn tick(state: &BridgeState, settings: &crate::settings::Settings) {
    let port = settings.port;
    let api_key = settings.api_key.as_str();
    let openrouter_key = settings.openrouter_key.as_str();
    let lang = settings.lang.as_str();
    let Some(debug_port) = find_debug_port_cached(state) else {
        set_status(state, json!({"attached": false, "reason": "codex_not_running"}));
        return;
    };
    let targets = match fetch_targets(client(), debug_port).await {
        Ok(targets) => targets,
        Err(error) => {
            invalidate_discovery(state);
            set_status(
                state,
                json!({"attached": false, "reason": format!("targets: {}", error), "debugPort": debug_port}),
            );
            return;
        }
    };
    let Some(target) = pick_target(&targets) else {
        set_status(state, json!({"attached": false, "reason": "no_pages", "debugPort": debug_port}));
        return;
    };
    let Some(ws_url) = target.get("webSocketDebuggerUrl").and_then(|v| v.as_str()) else {
        set_status(state, json!({"attached": false, "reason": "no_ws_url", "debugPort": debug_port}));
        return;
    };
    // Never follow a target that points the CDP session at a remote host or
    // a different debug port.
    let loopback = format!("ws://127.0.0.1:{debug_port}/");
    let localhost = format!("ws://localhost:{debug_port}/");
    if !(ws_url.starts_with(&loopback) || ws_url.starts_with(&localhost)) {
        set_status(
            state,
            json!({"attached": false, "reason": "non_loopback_ws", "debugPort": debug_port}),
        );
        return;
    }

    let mut session = match Session::connect(ws_url).await {
        Ok(session) => session,
        Err(error) => {
            invalidate_discovery(state);
            set_status(
                state,
                json!({"attached": false, "reason": format!("ws: {}", error), "debugPort": debug_port}),
            );
            return;
        }
    };

    // Inject when the page changed (fresh window, reload, app restart).
    let attached = session
        .evaluate("typeof window.__melonChipsPing === 'function' ? 1 : 0")
        .await
        .ok()
        .flatten()
        .and_then(|v| v.as_i64())
        .unwrap_or(0);
    if attached == 0 {
        if let Err(error) = session.evaluate(&injection_source(lang)).await {
            set_status(
                state,
                json!({"attached": false, "reason": format!("inject: {}", error), "debugPort": debug_port}),
            );
            return;
        }
    }

    // Active composer context (selected model) for the "provider" chip.
    let mut model: Option<String> = None;
    let mut thread_id: Option<String> = None;
    if let Ok(Some(text)) = session
        .evaluate("window.__melonChipsContext ? JSON.stringify(window.__melonChipsContext()) : null")
        .await
    {
        if let Some(text) = text.as_str() {
            if let Ok(context) = serde_json::from_str::<Value>(text) {
                model = context
                    .get("model")
                    .and_then(|v| v.as_str())
                    .map(String::from)
                    .filter(|m| !m.is_empty());
                thread_id = context
                    .get("threadId")
                    .and_then(|v| v.as_str())
                    .map(String::from)
                    .filter(|t| !t.is_empty());
            }
        }
    }

    let mut payload = status_payload(state, port, api_key, openrouter_key, model.clone()).await;
    payload["active"]["threadId"] = json!(thread_id.clone());
    if let Some(session_usage) =
        thread_id.as_deref().and_then(|id| session_usage_cached(state, id))
    {
        payload["session"] = session_usage;
    }
    let push = format!(
        "window.__melonChipsSetStatus && window.__melonChipsSetStatus({});",
        payload
    );
    let push_result = session.evaluate(&push).await;

    set_status(
        state,
        match push_result {
            Ok(_) => json!({
                "attached": true,
                "debugPort": debug_port,
                "model": model,
                "threadId": thread_id,
                "targets": targets.len(),
                "reason": Value::Null,
            }),
            Err(error) => json!({
                "attached": false,
                "debugPort": debug_port,
                "reason": format!("push: {}", error),
            }),
        },
    );
}

// MARK: - Session spend (Codex rollout files)

/// Token usage of the thread the composer is looking at: the newest rollout
/// file whose name carries the thread id, parsed from its tail.
fn find_rollout(thread_id: &str) -> Option<PathBuf> {
    let sessions = crate::paths::codex_home().join("sessions");
    let mut newest: Option<(std::time::SystemTime, PathBuf)> = None;
    let mut scanned = 0usize;
    walk_rollouts(&sessions, thread_id, &mut newest, &mut scanned, 0);
    newest.map(|(_, path)| path)
}

fn read_session_usage(path: &std::path::Path) -> Option<Value> {
    let data = std::fs::read(path).ok()?;
    let cap = 4 * 1024 * 1024;
    let slice = if data.len() > cap {
        &data[data.len() - cap..]
    } else {
        &data[..]
    };
    let text = String::from_utf8_lossy(slice);

    let mut usage: Option<Value> = None;
    let mut model: Option<String> = None;
    let mut turns: i64 = 0;
    for line in text.lines().rev() {
        if line.contains("\"user_message\"") {
            turns += 1;
        }
        if usage.is_none() && line.contains("total_token_usage") {
            if let Ok(value) = serde_json::from_str::<Value>(line) {
                if let Some(found) = find_key(&value, "total_token_usage") {
                    usage = Some(normalize_usage(found));
                }
            }
        }
        if model.is_none()
            && line.contains("\"model\"")
            && line.contains("turn_context")
        {
            if let Ok(value) = serde_json::from_str::<Value>(line) {
                if let Some(found) = find_key(&value, "model") {
                    model = found.as_str().map(String::from);
                }
            }
        }
    }
    let usage = usage?;
    Some(json!({
        "last": usage,
        "total": usage,
        "turns": turns,
        "matched": true,
        "model": model,
        "contextWindow": Value::Null,
    }))
}

/// The directory walk is the expensive part — the resolved path is cached per
/// thread (a rolling file keeps its path), with a short TTL as a safety net
/// and an existence check so a fresh thread re-scans immediately.
fn session_usage_cached(state: &BridgeState, thread_id: &str) -> Option<Value> {
    let cached = state.session_path.lock().ok().and_then(|guard| {
        guard
            .as_ref()
            .filter(|(thread, path, at)| {
                thread == thread_id
                    && path.exists()
                    && at.elapsed() < Duration::from_secs(20)
            })
            .map(|(_, path, _)| path.clone())
    });
    let path = match cached {
        Some(path) => path,
        None => {
            let found = find_rollout(thread_id)?;
            if let Ok(mut guard) = state.session_path.lock() {
                *guard = Some((
                    thread_id.to_string(),
                    found.clone(),
                    std::time::Instant::now(),
                ));
            }
            found
        }
    };
    read_session_usage(&path)
}

fn walk_rollouts(
    dir: &std::path::Path,
    needle: &str,
    newest: &mut Option<(std::time::SystemTime, PathBuf)>,
    scanned: &mut usize,
    depth: usize,
) {
    if depth > 5 || *scanned > 4000 {
        return;
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            walk_rollouts(&path, needle, newest, scanned, depth + 1);
            continue;
        }
        *scanned += 1;
        let name = entry.file_name().to_string_lossy().to_string();
        if !name.ends_with(".jsonl") || !name.contains(needle) {
            continue;
        }
        let modified = entry
            .metadata()
            .ok()
            .and_then(|m| m.modified().ok())
            .unwrap_or(std::time::UNIX_EPOCH);
        if newest.as_ref().map(|(t, _)| modified > *t).unwrap_or(true) {
            *newest = Some((modified, path));
        }
    }
}

fn find_key<'a>(value: &'a Value, key: &str) -> Option<&'a Value> {
    match value {
        Value::Object(map) => {
            if let Some(found) = map.get(key) {
                return Some(found);
            }
            map.values().find_map(|v| find_key(v, key))
        }
        Value::Array(items) => items.iter().find_map(|v| find_key(v, key)),
        _ => None,
    }
}

fn normalize_usage(value: &Value) -> Value {
    let get = |key: &str| value.get(key).and_then(|v| v.as_i64()).unwrap_or(0);
    json!({
        "input": get("input_tokens"),
        "cached": get("cached_input_tokens"),
        "cacheWrite": get("cache_write_tokens"),
        "output": get("output_tokens"),
        "reasoning": get("reasoning_output_tokens"),
        "total": get("total_tokens"),
    })
}

/// Path of the Codex home, exposed for the UI.
pub fn codex_home_display() -> String {
    paths::codex_home().to_string_lossy().to_string()
}

// MARK: - Codex app launch (the debug port only exists when the app starts
// with the DevTools flags — the macOS bridge does the same)

fn codex_exe_candidates() -> Vec<std::path::PathBuf> {
    let mut candidates: Vec<std::path::PathBuf> = Vec::new();
    if let Ok(from_env) = std::env::var("MELON_CODEX_EXE") {
        candidates.push(std::path::PathBuf::from(from_env));
    }
    if let Ok(local) = std::env::var("LOCALAPPDATA") {
        for tail in [
            "Programs\\ChatGPT\\ChatGPT.exe",
            "ChatGPT\\ChatGPT.exe",
            "Programs\\ChatGPT-Desktop\\ChatGPT.exe",
        ] {
            candidates.push(std::path::PathBuf::from(&local).join(tail));
        }
    }
    if let Ok(program_files) = std::env::var("PROGRAMFILES") {
        candidates.push(std::path::PathBuf::from(&program_files).join("ChatGPT\\ChatGPT.exe"));
    }
    candidates
}

fn find_codex_exe() -> Option<std::path::PathBuf> {
    for candidate in codex_exe_candidates() {
        if candidate.exists() {
            return Some(candidate);
        }
    }
    #[cfg(windows)]
    {
        let mut command = std::process::Command::new("where.exe");
        command.arg("ChatGPT.exe");
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x0800_0000);
        if let Ok(output) = command.output() {
            let text = String::from_utf8_lossy(&output.stdout);
            if let Some(first) = text.lines().map(str::trim).find(|l| !l.is_empty()) {
                let path = std::path::PathBuf::from(first);
                if path.exists() {
                    return Some(path);
                }
            }
        }
    }
    None
}

fn codex_is_running() -> bool {
    #[cfg(windows)]
    {
        let mut command = std::process::Command::new("tasklist.exe");
        command.args(["/FI", "IMAGENAME eq ChatGPT.exe", "/NH"]);
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x0800_0000);
        if let Ok(output) = command.output() {
            return String::from_utf8_lossy(&output.stdout).contains("ChatGPT.exe");
        }
    }
    false
}

fn free_local_port() -> Option<u16> {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").ok()?;
    listener.local_addr().ok().map(|addr| addr.port())
}

/// Kills every running ChatGPT process by its resolved PID. The image identity
/// is verified per PID first: an image-name taskkill could terminate an
/// unrelated binary that happens to share the name.
#[cfg(windows)]
fn kill_chatgpt_processes(force: bool) {
    for pid in crate::gateway::tasklist_pids("ChatGPT.exe") {
        let verified = crate::gateway::tasklist_image_name(pid)
            .map(|image| crate::gateway::image_starts_with(&image, "chatgpt"))
            .unwrap_or(false);
        if verified {
            let _ = crate::gateway::taskkill_pid(pid, force);
        }
    }
}

/// Restarts the Codex app with the CDP flags (the chips need the debug port;
/// an already running instance cannot gain the flags any other way).
pub async fn launch_codex_with_debug_port() -> Result<String, String> {
    let exe = find_codex_exe().ok_or_else(|| {
        "не нашёл ChatGPT.exe — укажите путь через переменную MELON_CODEX_EXE".to_string()
    })?;
    if codex_is_running() {
        #[cfg(windows)]
        kill_chatgpt_processes(false);
        for _ in 0..20 {
            tokio::time::sleep(Duration::from_millis(500)).await;
            if !codex_is_running() {
                break;
            }
        }
        if codex_is_running() {
            #[cfg(windows)]
            kill_chatgpt_processes(true);
            tokio::time::sleep(Duration::from_secs(2)).await;
        }
    }
    let port = free_local_port().ok_or_else(|| "нет свободного порта".to_string())?;
    let mut command = std::process::Command::new(&exe);
    command.args([
        "--remote-debugging-address=127.0.0.1",
        &format!("--remote-debugging-port={}", port),
    ]);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x0800_0000);
    }
    command
        .spawn()
        .map_err(|e| format!("запуск не удался: {}", e))?;
    Ok(format!("{} · port {}", exe.to_string_lossy(), port))
}
