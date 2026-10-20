//! Melon Tools for Windows — Codex account pool, local API gateway, chips
//! bridge and the scheduler/instances tooling. Tauri 2 backend with the same
//! vault and gateway layout as the macOS app.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod antigravity;
mod bridge;
mod claude;
mod codex_route;
mod device_login;
mod dpapi;
mod engine;
mod gateway;
mod history;
mod instances;
mod paths;
mod providers;
mod quota;
mod routing;
mod scheduler;
mod settings;
mod updater;
mod vault;

use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Mutex;
use tauri::{Emitter, Manager, State};
use tauri_plugin_notification::NotificationExt;

pub struct AppState {
    pub gw: gateway::Gateway,
    pub bridge: bridge::BridgeState,
    pub settings: Mutex<settings::Settings>,
    /// Engine watchdog bookkeeping.
    pub watchdog: Mutex<Watchdog>,
    /// Last validated `update_check` result. `update_apply` uses only this
    /// copy and never trusts renderer-supplied URL/digest.
    pub update: Mutex<Option<updater::UpdateInfo>>,
}

/// Keeps the local engine alive: after we started (or adopted) the gateway,
/// two consecutive failed health probes trigger a bounded restart — unless
/// the user stopped it explicitly.
#[derive(Default, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Watchdog {
    pub supervised: bool,
    pub user_stopped: bool,
    #[serde(skip)]
    pub misses: u32,
    pub restarts: u32,
    pub last_restart: Option<String>,
}

impl AppState {
    fn settings(&self) -> settings::Settings {
        self.settings.lock().map(|s| s.clone()).unwrap_or_default()
    }
}

fn hidden_command(_command: &mut std::process::Command) {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        _command.creation_flags(0x0800_0000);
    }
}

// MARK: - App info / settings

#[tauri::command]
fn app_info() -> Value {
    json!({
        "name": "Melon Tools",
        "version": env!("CARGO_PKG_VERSION"),
        "platform": std::env::consts::OS,
        "dataDir": paths::appdata_dir().to_string_lossy(),
        "codexHome": paths::codex_home().to_string_lossy(),
        "enginePath": engine::engine_path().to_string_lossy(),
        "schedulerPath": scheduler::path().to_string_lossy(),
    })
}

#[tauri::command]
async fn settings_get(state: State<'_, AppState>) -> Result<Value, String> {
    settings_view(&state.settings())
}

/// Renderer-facing settings. The management secret is app-internal (the engine
/// config and management calls need the plaintext value) and must not cross the
/// IPC boundary: it is redacted, the other fields pass through unchanged.
fn settings_view(settings: &settings::Settings) -> Result<Value, String> {
    let mut value = serde_json::to_value(settings).map_err(|e| e.to_string())?;
    if let Some(object) = value.as_object_mut() {
        object.insert("managementSecret".to_string(), json!(""));
    }
    Ok(value)
}

#[tauri::command]
async fn settings_set(
    state: State<'_, AppState>,
    settings: settings::Settings,
) -> Result<Value, String> {
    let mut merged = settings;
    if merged.api_key.trim().is_empty() {
        merged.api_key = state.settings().api_key;
    }
    // The management secret is app-managed: a settings payload from an older
    // UI must not wipe the persisted value (a fresh one would invalidate every
    // management call until the engine reloads the config).
    if merged.management_secret.trim().is_empty() {
        merged.management_secret = state.settings().management_secret;
    }
    // Reset-notification markers are app-managed: an older UI payload without
    // them must not cause the same window to be announced again.
    if merged.quota_reset_notified.is_empty() {
        merged.quota_reset_notified = state.settings().quota_reset_notified;
    }
    settings::save(&merged)?;
    if let Ok(mut guard) = state.settings.lock() {
        *guard = merged.clone();
    }
    settings_view(&merged)
}

// MARK: - Gateway

#[tauri::command]
async fn gateway_status(state: State<'_, AppState>) -> Result<Value, String> {
    let settings = state.settings();
    let running = gateway::health(settings.port, &settings.api_key).await;
    Ok(json!({
        "running": running,
        "port": settings.port,
        "requestsLastMinute": gateway::requests_last_minute(),
        "sidecarFound": gateway::resolve_sidecar().is_some(),
        "dataDir": paths::appdata_dir().to_string_lossy(),
        "logPath": paths::log_path().to_string_lossy(),
        "watchdog": state
            .watchdog
            .lock()
            .map(|w| w.clone())
            .unwrap_or_default(),
    }))
}

async fn start_gateway(state: &AppState) -> Result<String, String> {
    let settings = state.settings();
    let result = gateway::start(&state.gw, &settings).await?;
    let _ = codex_route::apply(settings.port, &settings.api_key);
    if let Ok(client) = quota::client() {
        let _ = codex_route::sync_catalog(&client, settings.port, &settings.api_key).await;
    }
    if let Ok(mut guard) = state.watchdog.lock() {
        guard.supervised = true;
        guard.user_stopped = false;
        guard.misses = 0;
        // A manual start resets the restart budget: the user asked for it.
        guard.restarts = 0;
    }
    Ok(result)
}

async fn stop_gateway(state: &AppState) -> Result<String, String> {
    let result = gateway::stop(&state.gw)?;
    let _ = codex_route::remove();
    if let Ok(mut guard) = state.watchdog.lock() {
        guard.user_stopped = true;
        guard.supervised = false;
    }
    Ok(result)
}

#[tauri::command]
async fn gateway_start(state: State<'_, AppState>) -> Result<String, String> {
    start_gateway(state.inner()).await
}

#[tauri::command]
async fn gateway_stop(state: State<'_, AppState>) -> Result<String, String> {
    stop_gateway(state.inner()).await
}

/// Rewrites config.yaml + gateway auth files from the vault.
#[tauri::command]
async fn gateway_sync(state: State<'_, AppState>) -> Result<Value, String> {
    let settings = state.settings();
    gateway::write_config(&settings)?;
    let written = gateway::sync_accounts(&settings)?;
    Ok(json!({ "syncedAccounts": written }))
}

#[tauri::command]
async fn gateway_check(state: State<'_, AppState>) -> Result<String, String> {
    let settings = state.settings();
    gateway::check_api(settings.port, &settings.api_key).await
}

#[tauri::command]
async fn gateway_recent_calls(limit: Option<usize>) -> Result<Value, String> {
    Ok(gateway::recent_calls(limit.unwrap_or(10)))
}

#[tauri::command]
async fn gateway_models(state: State<'_, AppState>) -> Result<Value, String> {
    let settings = state.settings();
    gateway::models(settings.port, &settings.api_key).await
}

// MARK: - Vault + quotas

#[tauri::command]
async fn vault_list() -> Result<Vec<Value>, String> {
    Ok(vault::list_views())
}

/// Last quota reading before a refresh, used to detect a crossing and a
/// recovered block.
type PreviousQuota = HashMap<String, PreviousAccount>;

#[derive(Clone)]
struct PreviousAccount {
    hourly: Option<f64>,
    weekly: Option<f64>,
    blocked: bool,
    block_code: Option<String>,
}

fn quota_snapshot() -> PreviousQuota {
    vault::accounts()
        .into_iter()
        .filter_map(|account| {
            let quota = account.quota.clone()?;
            let block_code = account
                .block_info()
                .and_then(|info| info.get("code").and_then(|code| code.as_str()).map(String::from));
            let id = account.id.clone();
            Some((
                id,
                PreviousAccount {
                    hourly: quota.hourly_remaining_percent,
                    weekly: quota.weekly_remaining_percent,
                    blocked: account.is_blocked(),
                    block_code,
                },
            ))
        })
        .collect()
}

#[tauri::command]
async fn quota_refresh(
    app: tauri::AppHandle,
    state: State<'_, AppState>,
    id: Option<String>,
) -> Result<Value, String> {
    let client = quota::client()?;
    let previous = quota_snapshot();
    let errors = quota::refresh_all(&client, id.as_deref()).await;
    let settings = state.settings();
    let synced = if gateway::health(settings.port, &settings.api_key).await {
        gateway::sync_accounts(&settings).unwrap_or(0)
    } else {
        0
    };
    check_low_quota(&app, &state, &previous);
    check_quota_reset(&app, &state, &previous);
    Ok(json!({
        "accounts": vault::list_views(),
        "errors": errors,
        "syncedAccounts": synced,
    }))
}

/// Read-only quota history for the sparkline strips.
#[tauri::command]
fn quota_history() -> Vec<Value> {
    history::ipc_samples()
}

/// Toast when a refreshed window crosses below its account reserve (10 % when
/// the reserve is unset). `history::claim_notification` persists the reset
/// window id, so each window notifies at most once across restarts.
fn check_low_quota(app: &tauri::AppHandle, state: &AppState, previous: &PreviousQuota) {
    let settings = state.settings();
    if !settings.notifications || !settings.notify_low_quota {
        return;
    }
    let now = chrono::Utc::now().timestamp();
    let english = settings.lang == "en";
    for account in vault::accounts() {
        let Some(quota) = account.quota.clone() else {
            continue;
        };
        let before = previous.get(&account.id);
        let checks = [
            (
                "5h",
                quota.hourly_remaining_percent,
                quota.hourly_reset_at,
                account.hourly_reserve_percent,
                before.and_then(|value| value.hourly),
                3600i64,
                if english { "5-hour window" } else { "5-часовое окно" },
            ),
            (
                "week",
                quota.weekly_remaining_percent,
                quota.weekly_reset_at,
                account.weekly_reserve_percent,
                before.and_then(|value| value.weekly),
                21600i64,
                if english { "weekly window" } else { "недельное окно" },
            ),
        ];
        for (kind, remaining, reset_at, reserve, before_value, cooldown, label) in checks {
            let Some(remaining) = remaining else {
                continue;
            };
            let threshold = reserve
                .filter(|value| *value > 0)
                .map(|value| value as f64)
                .unwrap_or(10.0);
            let key = format!("{}:{}", account.id, kind);
            let claimed = history::claim_notification(
                &key,
                before_value,
                Some(remaining),
                threshold,
                reset_at,
                now,
                cooldown,
            )
            .unwrap_or(false);
            if !claimed {
                continue;
            }
            let body = if english {
                format!(
                    "{}: {}% left ≤ {}% threshold ({})",
                    account.display_name(),
                    remaining.round() as i64,
                    threshold.round() as i64,
                    label
                )
            } else {
                format!(
                    "{}: осталось {}% ≤ порога {}% ({})",
                    account.display_name(),
                    remaining.round() as i64,
                    threshold.round() as i64,
                    label
                )
            };
            let _ = app
                .notification()
                .builder()
                .title(if english {
                    "Melon Tools · low quota"
                } else {
                    "Melon Tools · низкая квота"
                })
                .body(body)
                .show();
        }
    }
}

/// One toast per account/window when a refresh turns a blocked account into a
/// usable one. The marker is stored in settings, so restarts cannot repeat it.
fn check_quota_reset(app: &tauri::AppHandle, state: &AppState, previous: &PreviousQuota) {
    let settings = state.settings();
    if !settings.notifications || !settings.notify_quota_reset {
        return;
    }
    let english = settings.lang == "en";
    let now = chrono::Utc::now().timestamp();
    let mut markers = settings.quota_reset_notified.clone();
    let mut changed = false;
    for account in vault::accounts() {
        let Some(before) = previous.get(&account.id) else {
            continue;
        };
        let Some(window) = before.block_code.as_deref().and_then(quota::block_window) else {
            continue;
        };
        let reset_at = match window {
            "hourly" => account
                .quota
                .as_ref()
                .and_then(|quota| quota.hourly_reset_at),
            "weekly" => account
                .quota
                .as_ref()
                .and_then(|quota| quota.weekly_reset_at),
            _ => None,
        }
        .map(|value| value + vault::APPLE_REF_UNIX_OFFSET);
        let key = quota::reset_notification_key(&account.id, window, reset_at, now);
        let notified = markers.iter().any(|marker| marker == &key);
        if !quota::should_notify_quota_reset(before.blocked, account.is_blocked(), notified) {
            continue;
        }
        markers.push(key);
        changed = true;
        let label = match (english, window) {
            (true, "hourly") => "5-hour window",
            (true, "weekly") => "weekly window",
            (false, "hourly") => "5-часовое окно",
            (false, "weekly") => "недельное окно",
            (true, _) => "quota",
            (false, _) => "квота",
        };
        let body = if english {
            format!("{}: {} is available again", account.display_name(), label)
        } else {
            format!("{}: {} снова доступна", account.display_name(), label)
        };
        let _ = app
            .notification()
            .builder()
            .title(if english {
                "Melon Tools · quota reset"
            } else {
                "Melon Tools · сброс квоты"
            })
            .body(body)
            .show();
    }
    if changed {
        if markers.len() > 200 {
            let excess = markers.len() - 200;
            markers.drain(0..excess);
        }
        if let Ok(mut guard) = state.settings.lock() {
            guard.quota_reset_notified = markers;
            let _ = settings::save(&guard);
        }
    }
}

#[tauri::command]
async fn switch_account(state: State<'_, AppState>, id: String) -> Result<Value, String> {
    let account = vault::accounts()
        .into_iter()
        .find(|a| a.id == id)
        .ok_or_else(|| "аккаунт не найден".to_string())?;
    let path = vault::write_codex_auth(&account)?;
    let mut raw = vault::load_raw();
    raw["currentAccountId"] = json!(id);
    vault::save_raw(&raw)?;
    let settings = state.settings();
    if gateway::health(settings.port, &settings.api_key).await {
        let _ = gateway::sync_accounts(&settings);
    }
    Ok(json!({ "authPath": path.to_string_lossy() }))
}

#[tauri::command]
async fn import_current_auth(state: State<'_, AppState>) -> Result<Value, String> {
    let tokens = vault::read_codex_auth_tokens()
        .ok_or_else(|| "не нашёл %USERPROFILE%\\.codex\\auth.json — войдите в Codex".to_string())?;
    let result = vault::upsert_from_tokens(&tokens)?;
    let settings = state.settings();
    if gateway::health(settings.port, &settings.api_key).await {
        let _ = gateway::sync_accounts(&settings);
    }
    Ok(json!({ "result": result, "accounts": vault::list_views() }))
}

#[tauri::command]
async fn account_refresh_tokens(id: String) -> Result<Vec<Value>, String> {
    let account = vault::accounts()
        .into_iter()
        .find(|a| a.id == id)
        .ok_or_else(|| "аккаунт не найден".to_string())?;
    let client = quota::client()?;
    let tokens = quota::refresh_tokens(&client, &account).await?;
    vault::update_tokens(&id, &tokens, &chrono::Utc::now().to_rfc3339())?;
    Ok(vault::list_views())
}

#[tauri::command]
async fn save_reserves(
    state: State<'_, AppState>,
    id: String,
    hourly: Option<i64>,
    weekly: Option<i64>,
) -> Result<Vec<Value>, String> {
    vault::set_account_field(&id, move |item| {
        item["hourlyReservePercent"] = json!(hourly);
        item["weeklyReservePercent"] = json!(weekly);
    })?;
    let settings = state.settings();
    if gateway::health(settings.port, &settings.api_key).await {
        let _ = gateway::sync_accounts(&settings);
    }
    Ok(vault::list_views())
}

#[tauri::command]
async fn delete_account(state: State<'_, AppState>, id: String) -> Result<Vec<Value>, String> {
    vault::delete_account(&id)?;
    let settings = state.settings();
    if gateway::health(settings.port, &settings.api_key).await {
        let _ = gateway::sync_accounts(&settings);
    }
    Ok(vault::list_views())
}

// MARK: - Device login (add an account)

#[tauri::command]
async fn device_login_start() -> Result<Value, String> {
    let client = quota::client()?;
    device_login::start(&client).await
}

#[tauri::command]
async fn device_login_poll(
    state: State<'_, AppState>,
    device_auth_id: String,
    user_code: String,
) -> Result<Value, String> {
    let client = quota::client()?;
    match device_login::poll(&client, &device_auth_id, &user_code).await? {
        Some(tokens) => {
            let result = vault::upsert_from_tokens(&tokens)?;
            let settings = state.settings();
            if gateway::health(settings.port, &settings.api_key).await {
                let _ = gateway::sync_accounts(&settings);
            }
            Ok(json!({ "done": true, "result": result, "accounts": vault::list_views() }))
        }
        None => Ok(json!({ "done": false })),
    }
}

// MARK: - Routing

#[tauri::command]
async fn routing_state(state: State<'_, AppState>) -> Result<Value, String> {
    let settings = state.settings();
    let accounts = vault::accounts();
    let (ordered, blocked) = routing::resolve(
        &accounts,
        &settings.routing_strategy,
        &settings.priority_order,
    );
    Ok(json!({
        "strategy": settings.routing_strategy,
        "strategies": routing::STRATEGIES,
        "priorityOrder": settings.priority_order,
        "orderedIds": ordered,
        "blockedIds": blocked,
    }))
}

#[tauri::command]
async fn set_routing_strategy(state: State<'_, AppState>, strategy: String) -> Result<Value, String> {
    if !routing::STRATEGIES.contains(&strategy.as_str()) {
        return Err(format!("неизвестная стратегия: {}", strategy));
    }
    mutate_settings(&state, |s| s.routing_strategy = strategy)?;
    resync(&state).await
}

#[tauri::command]
async fn move_priority(state: State<'_, AppState>, id: String, up: bool) -> Result<Value, String> {
    mutate_settings(&state, |s| {
        let mut order = s.priority_order.clone();
        if order.is_empty() {
            order = vault::accounts().iter().map(|a| a.id.clone()).collect();
        }
        if let Some(index) = order.iter().position(|value| value == &id) {
            let target = if up {
                index.checked_sub(1)
            } else if index + 1 < order.len() {
                Some(index + 1)
            } else {
                None
            };
            if let Some(target) = target {
                order.swap(index, target);
            }
        }
        s.priority_order = order;
    })?;
    mutate_settings(&state, |s| s.routing_strategy = "custom".to_string())?;
    resync(&state).await
}

#[tauri::command]
async fn reset_priority(state: State<'_, AppState>) -> Result<Value, String> {
    mutate_settings(&state, |s| {
        s.priority_order = vault::accounts().iter().map(|a| a.id.clone()).collect();
    })?;
    resync(&state).await
}

#[tauri::command]
async fn set_account_role(
    state: State<'_, AppState>,
    id: String,
    preferred: bool,
    backup: bool,
) -> Result<Value, String> {
    vault::set_account_field(&id, move |item| {
        item["preferredFirst"] = json!(preferred);
        item["isBackup"] = json!(backup);
    })?;
    resync(&state).await
}

fn mutate_settings(
    state: &State<'_, AppState>,
    mutate: impl FnOnce(&mut settings::Settings),
) -> Result<(), String> {
    let mut guard = state.settings.lock().map_err(|_| "settings lock".to_string())?;
    mutate(&mut guard);
    settings::save(&guard)
}

async fn resync(state: &State<'_, AppState>) -> Result<Value, String> {
    let settings = state.settings();
    if gateway::health(settings.port, &settings.api_key).await {
        let _ = gateway::sync_accounts(&settings);
    }
    let accounts = vault::accounts();
    let (ordered, blocked) =
        routing::resolve(&accounts, &settings.routing_strategy, &settings.priority_order);
    Ok(json!({
        "strategy": settings.routing_strategy,
        "priorityOrder": settings.priority_order,
        "orderedIds": ordered,
        "blockedIds": blocked,
        "accounts": vault::list_views(),
    }))
}

// MARK: - Codex route + chips bridge

#[tauri::command]
async fn codex_route_status() -> Result<Value, String> {
    Ok(codex_route::status())
}

#[tauri::command]
async fn codex_route_apply(state: State<'_, AppState>) -> Result<Value, String> {
    let settings = state.settings();
    codex_route::apply(settings.port, &settings.api_key)?;
    if let Ok(client) = quota::client() {
        let custom = codex_route::sync_catalog(&client, settings.port, &settings.api_key).await?;
        return Ok(json!({ "route": codex_route::status(), "catalogCustom": custom }));
    }
    Ok(json!({ "route": codex_route::status(), "catalogCustom": 0 }))
}

#[tauri::command]
async fn codex_route_remove() -> Result<Value, String> {
    codex_route::remove()?;
    Ok(codex_route::status())
}

#[tauri::command]
async fn bridge_status(state: State<'_, AppState>) -> Result<Value, String> {
    let value = state
        .bridge
        .status
        .lock()
        .map(|v| v.clone())
        .unwrap_or_else(|_| json!({"attached": false}));
    Ok(value)
}

/// Restarts the Codex app with the CDP flags so the chips can attach.
#[tauri::command]
async fn bridge_launch_codex() -> Result<String, String> {
    bridge::launch_codex_with_debug_port().await
}

// MARK: - Scheduler

#[tauri::command]
async fn scheduler_list() -> Result<Value, String> {
    Ok(scheduler::view())
}

#[tauri::command]
async fn scheduler_save(task: scheduler::TaskInput) -> Result<Value, String> {
    scheduler::upsert(task)
}

#[tauri::command]
async fn scheduler_delete(id: String) -> Result<Value, String> {
    scheduler::delete(&id)
}

#[tauri::command]
async fn scheduler_run_now(
    app: tauri::AppHandle,
    state: State<'_, AppState>,
    id: String,
) -> Result<Value, String> {
    let settings = state.settings();
    scheduler::run_now(&settings, &id, &app).await
}

/// Model ids served by the running gateway, grouped by id prefix. The picker
/// stores the exact id, so an unavailable gateway is a hard error the UI shows.
#[tauri::command]
async fn scheduler_models(state: State<'_, AppState>) -> Result<Value, String> {
    let settings = state.settings();
    scheduler::models(settings.port, &settings.api_key).await
}

// MARK: - Instances

#[tauri::command]
async fn instances_list() -> Result<Vec<Value>, String> {
    Ok(instances::list())
}

#[tauri::command]
async fn instance_create(name: String) -> Result<Vec<Value>, String> {
    instances::create(&name)?;
    Ok(instances::list())
}

#[tauri::command]
async fn instance_delete(id: String) -> Result<Vec<Value>, String> {
    instances::delete(&id)
}

#[tauri::command]
async fn instance_bind(id: String, account_id: Option<String>) -> Result<Vec<Value>, String> {
    instances::bind(&id, account_id)
}

#[tauri::command]
async fn instance_launch(id: String) -> Result<String, String> {
    instances::launch(&id)
}

// MARK: - Autostart (HKCU Run key, no admin rights needed)

#[tauri::command]
async fn autostart_get() -> Result<bool, String> {
    #[cfg(windows)]
    {
        let mut command = std::process::Command::new("reg");
        command.args([
            "query",
            "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run",
            "/v",
            "MelonTools",
        ]);
        hidden_command(&mut command);
        return Ok(command.output().map(|o| o.status.success()).unwrap_or(false));
    }
    #[cfg(not(windows))]
    Ok(false)
}

#[tauri::command]
async fn autostart_set(enabled: bool) -> Result<bool, String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    #[cfg(windows)]
    {
        let mut command = std::process::Command::new("reg");
        if enabled {
            let value = format!("\"{}\"", exe.to_string_lossy());
            command.args([
                "add",
                "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run",
                "/v",
                "MelonTools",
                "/t",
                "REG_SZ",
                "/d",
                &value,
                "/f",
            ]);
        } else {
            command.args([
                "delete",
                "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run",
                "/v",
                "MelonTools",
                "/f",
            ]);
        }
        hidden_command(&mut command);
        let output = command.output().map_err(|e| e.to_string())?;
        Ok(output.status.success())
    }
    #[cfg(not(windows))]
    Ok(false)
}

// MARK: - Updater (GitHub releases)

/// Latest release lookup. `force=false` throttles to once per 24 h.
#[tauri::command]
async fn update_check(state: State<'_, AppState>, force: bool) -> Result<Value, String> {
    let settings = state.settings();
    let result =
        updater::check(force, env!("CARGO_PKG_VERSION"), settings.last_update_check).await?;
    if result.get("skipped").and_then(|v| v.as_bool()) != Some(true) {
        let now = chrono::Utc::now().timestamp();
        mutate_settings(&state, |s| s.last_update_check = Some(now))?;
        // The latest check replaces the apply target: a release that is no
        // longer newer/verifiable must not leave an older cache behind.
        let cached = updater::cached_from_check(&result);
        if let Ok(mut guard) = state.update.lock() {
            *guard = cached;
        }
    }
    Ok(result)
}

/// Downloads and verifies the new executable, then hands the swap to a
/// detached script and exits so the file is not locked.
///
/// The `url`/`digest` arguments are kept for UI compatibility but ignored: the
/// download target comes exclusively from the last validated `update_check`
/// cached in app state.
#[tauri::command]
async fn update_apply(
    app: tauri::AppHandle,
    state: State<'_, AppState>,
    url: String,
    digest: Option<String>,
) -> Result<Value, String> {
    let _ = (url, digest);
    let info = state
        .update
        .lock()
        .ok()
        .and_then(|guard| guard.clone())
        .ok_or_else(|| {
            "нет проверенных данных об обновлении — проверьте обновления ещё раз".to_string()
        })?;
    updater::validate_cached(&info)?;
    let current = std::env::current_exe().map_err(|e| e.to_string())?;
    let new_exe = updater::fetch_update(&info.url, Some(&info.digest)).await?;
    updater::spawn_swapper(&new_exe, &current, std::process::id())?;
    let handle = app.clone();
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_millis(400)).await;
        handle.exit(0);
    });
    Ok(json!({ "ok": true }))
}

// MARK: - Providers

#[tauri::command]
async fn openrouter_refresh(state: State<'_, AppState>) -> Result<Value, String> {
    let settings = state.settings();
    providers::openrouter(&settings.openrouter_key).await
}

// MARK: - Claude provider (engine management API)

fn management(state: &State<'_, AppState>) -> Result<claude::Management, String> {
    let settings = state.settings();
    claude::Management::new(&settings)
}

/// Starts the engine-managed OAuth login: returns the authorization URL (the
/// UI opens it through `open_url`) and the state token used for polling.
#[tauri::command]
async fn claude_login_start(state: State<'_, AppState>) -> Result<Value, String> {
    management(&state)?.login_start().await
}

#[tauri::command]
async fn claude_login_status(
    state: State<'_, AppState>,
    state_token: String,
) -> Result<Value, String> {
    management(&state)?.login_status(&state_token).await
}

#[tauri::command]
async fn claude_login_cancel(
    state: State<'_, AppState>,
    state_token: String,
) -> Result<Value, String> {
    management(&state)?.login_cancel(&state_token).await
}

#[tauri::command]
async fn claude_credentials(state: State<'_, AppState>) -> Result<Value, String> {
    management(&state)?.credentials().await
}

/// Claude model ids served by the running gateway (`/v1/models`), with
/// Antigravity-owned ids removed.
#[tauri::command]
async fn claude_models(state: State<'_, AppState>) -> Result<Value, String> {
    let settings = state.settings();
    antigravity::claude_models_without_antigravity(settings.port, &settings.api_key).await
}

/// Account status + quota windows for the Claude card.
#[tauri::command]
async fn claude_usage(state: State<'_, AppState>) -> Result<Value, String> {
    let settings = state.settings();
    providers::claude(&settings).await
}

/// Refreshes one credential (`name`) or all of them.
#[tauri::command]
async fn claude_refresh(state: State<'_, AppState>, name: Option<String>) -> Result<Value, String> {
    management(&state)?.refresh(name.as_deref()).await
}

/// Disconnects every Claude account: removes ALL engine-written
/// `claude-*.json` auth files (the engine hot-reloads the auth dir) and
/// reports what is left. There is no per-account selection here.
#[tauri::command]
async fn claude_disconnect() -> Result<Value, String> {
    let mut removed = 0usize;
    for file in claude::auth_files() {
        if std::fs::remove_file(&file.path).is_ok() {
            removed += 1;
        }
    }
    Ok(json!({ "removed": removed, "remaining": claude::auth_files().len() }))
}

// MARK: - Antigravity provider (engine management API)

fn antigravity_management(state: &State<'_, AppState>) -> Result<antigravity::Management, String> {
    let settings = state.settings();
    antigravity::Management::new(&settings)
}

/// Starts the engine-managed Google OAuth login: returns the authorization URL
/// (the UI opens it through `open_url`) and the state token used for polling.
#[tauri::command]
async fn antigravity_login_start(state: State<'_, AppState>) -> Result<Value, String> {
    antigravity_management(&state)?.login_start().await
}

#[tauri::command]
async fn antigravity_login_status(
    state: State<'_, AppState>,
    state_token: String,
) -> Result<Value, String> {
    antigravity_management(&state)?.login_status(&state_token).await
}

#[tauri::command]
async fn antigravity_login_cancel(
    state: State<'_, AppState>,
    state_token: String,
) -> Result<Value, String> {
    antigravity_management(&state)?.login_cancel(&state_token).await
}

/// Antigravity credential entries written by the engine.
#[tauri::command]
async fn antigravity_credentials(state: State<'_, AppState>) -> Result<Value, String> {
    antigravity_management(&state)?.credentials().await
}

/// Antigravity model ids served by the running gateway (`/v1/models`).
#[tauri::command]
async fn antigravity_models(state: State<'_, AppState>) -> Result<Value, String> {
    let settings = state.settings();
    antigravity::models(settings.port, &settings.api_key).await
}

/// Account identity + model count for the Antigravity card. No quota values:
/// the engine exposes no Antigravity quota endpoint.
#[tauri::command]
async fn antigravity_metrics(state: State<'_, AppState>) -> Result<Value, String> {
    let settings = state.settings();
    providers::antigravity(&settings).await
}

/// Refreshes one credential (`name`) or all of them. Failures come back as
/// `{ "ok": false }` instead of an error.
#[tauri::command]
async fn antigravity_refresh(
    state: State<'_, AppState>,
    name: Option<String>,
) -> Result<Value, String> {
    Ok(antigravity_management(&state)?
        .refresh(name.as_deref())
        .await)
}

/// Disconnects every Antigravity account: removes only the engine-written
/// `antigravity*.json` auth files and reports what is left.
#[tauri::command]
async fn antigravity_disconnect() -> Result<Value, String> {
    let (removed, remaining) = antigravity::disconnect_in(&paths::auths_dir());
    Ok(json!({ "removed": removed, "remaining": remaining }))
}

/// Launcher argv for an http(s) URL. The browser is opened through
/// `rundll32 url.dll,FileProtocolHandler`: unlike `cmd /C start`, no shell
/// re-parses the URL, so quotes, `&` or `^` cannot inject another command.
fn launcher_argv(url: &str) -> Result<[String; 2], String> {
    if !(url.starts_with("https://") || url.starts_with("http://")) {
        return Err("разрешены только http(s)-ссылки".to_string());
    }
    Ok(["url.dll,FileProtocolHandler".to_string(), url.to_string()])
}

/// Opens an http(s) URL in the default browser (device login page).
#[tauri::command]
async fn open_url(url: String) -> Result<(), String> {
    #[cfg(windows)]
    {
        let argv = launcher_argv(&url)?;
        let mut command = std::process::Command::new("rundll32.exe");
        command.args(argv);
        hidden_command(&mut command);
        command.spawn().map_err(|e| e.to_string())?;
        Ok(())
    }
    #[cfg(not(windows))]
    {
        launcher_argv(&url)?;
        Err("открытие ссылок поддерживается на Windows".to_string())
    }
}

// MARK: - Entry point

/// Restarts the engine when it dies while we believe it should run.
async fn watchdog_check(state: &AppState) {
    let (supervised, user_stopped, misses, restarts) = match state.watchdog.lock() {
        Ok(guard) => (
            guard.supervised,
            guard.user_stopped,
            guard.misses,
            guard.restarts,
        ),
        Err(_) => return,
    };
    if !supervised || user_stopped || restarts >= 3 {
        return;
    }
    let settings = state.settings();
    if gateway::health(settings.port, &settings.api_key).await {
        if let Ok(mut guard) = state.watchdog.lock() {
            guard.misses = 0;
        }
        return;
    }
    let missed = misses + 1;
    if let Ok(mut guard) = state.watchdog.lock() {
        guard.misses = missed;
    }
    if missed < 2 {
        return;
    }
    // Every attempt counts toward the bound (a persistently failing start
    // must not retry forever), and the miss counter resets so a failed
    // attempt is followed by a fresh two-miss wait instead of a hot loop.
    let outcome = gateway::start(&state.gw, &settings).await;
    if let Ok(mut guard) = state.watchdog.lock() {
        guard.misses = 0;
        guard.restarts += 1;
        if outcome.is_ok() {
            guard.last_restart = Some(chrono::Utc::now().to_rfc3339());
        }
    }
}

/// Holds the instance lock for the whole process lifetime; the OS releases it
/// even after a crash. A second launch exits instead of racing over the vault.
static INSTANCE_LOCK: std::sync::OnceLock<std::fs::File> = std::sync::OnceLock::new();

fn ensure_single_instance() {
    let dir = paths::appdata_dir();
    let _ = std::fs::create_dir_all(&dir);
    let path = dir.join("app.lock");
    let Ok(file) = std::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(false)
        .open(&path)
    else {
        return; // No lock file — run anyway rather than blocking the app.
    };
    use fs2::FileExt;
    if file.try_lock_exclusive().is_ok() {
        let _ = INSTANCE_LOCK.set(file);
    } else {
        eprintln!("Melon Tools is already running.");
        std::process::exit(0);
    }
}

fn show_main_window(app: &tauri::AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.set_focus();
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum ApiToggle {
    Start,
    Stop,
}

/// Pause a running gateway; start it again when it is stopped or the user
/// explicitly stopped it earlier.
fn api_toggle_action(running: bool, user_stopped: bool) -> ApiToggle {
    if user_stopped || !running {
        ApiToggle::Start
    } else {
        ApiToggle::Stop
    }
}

/// Frontend payload for the tray items that the webview owns. Show, API toggle
/// and Quit are handled entirely in Rust.
fn tray_event_payload(menu_id: &str) -> Option<Value> {
    match menu_id {
        "scheduler" => Some(json!({"action": "navigate", "section": "scheduler"})),
        "run-next" => Some(json!({"action": "run-next"})),
        _ => None,
    }
}

fn handle_tray_menu(app: &tauri::AppHandle, menu_id: &str) {
    match menu_id {
        "show" => show_main_window(app),
        "scheduler" | "run-next" => {
            show_main_window(app);
            if let Some(payload) = tray_event_payload(menu_id) {
                let _ = app.emit("tray-action", payload);
            }
        }
        "api-toggle" => {
            let handle = app.clone();
            tauri::async_runtime::spawn(async move {
                let state = handle.state::<AppState>();
                let settings = state.settings();
                let running = gateway::health(settings.port, &settings.api_key).await;
                let user_stopped = state
                    .watchdog
                    .lock()
                    .map(|guard| guard.user_stopped)
                    .unwrap_or(false);
                match api_toggle_action(running, user_stopped) {
                    ApiToggle::Start => {
                        let _ = start_gateway(state.inner()).await;
                    }
                    ApiToggle::Stop => {
                        let _ = stop_gateway(state.inner()).await;
                    }
                }
                let running = gateway::health(settings.port, &settings.api_key).await;
                let _ = handle.emit(
                    "tray-action",
                    json!({"action": "refresh", "running": running}),
                );
            });
        }
        "quit" => app.exit(0),
        _ => {}
    }
}

fn main() {
    ensure_single_instance();
    let initial_settings = settings::load();

    tauri::Builder::default()
        .plugin(tauri_plugin_notification::init())
        .manage(AppState {
            gw: gateway::Gateway::new(),
            bridge: bridge::BridgeState::new(),
            settings: Mutex::new(initial_settings),
            watchdog: Mutex::new(Watchdog::default()),
            update: Mutex::new(None),
        })
        .setup(|app| {
            // System tray: window, scheduler navigation, run-next, API
            // pause/resume and quit.
            let show_item = tauri::menu::MenuItem::with_id(
                app,
                "show",
                "Показать",
                true,
                None::<&str>,
            )?;
            let scheduler_item = tauri::menu::MenuItem::with_id(
                app,
                "scheduler",
                "Планировщик",
                true,
                None::<&str>,
            )?;
            let run_item = tauri::menu::MenuItem::with_id(
                app,
                "run-next",
                "Выполнить следующую задачу",
                true,
                None::<&str>,
            )?;
            let api_item = tauri::menu::MenuItem::with_id(
                app,
                "api-toggle",
                "Пауза / Возобновить API",
                true,
                None::<&str>,
            )?;
            let quit_item =
                tauri::menu::MenuItem::with_id(app, "quit", "Выход", true, None::<&str>)?;
            let menu = tauri::menu::Menu::with_items(
                app,
                &[
                    &show_item,
                    &scheduler_item,
                    &run_item,
                    &api_item,
                    &quit_item,
                ],
            )?;
            let icon = tauri::image::Image::from_bytes(include_bytes!("../icons/icon.png"))?;
            tauri::tray::TrayIconBuilder::new()
                .icon(icon)
                .menu(&menu)
                .tooltip("Melon Tools")
                .on_menu_event(|app, event| handle_tray_menu(app, event.id.as_ref()))
                .on_tray_icon_event(|tray, event| {
                    if let tauri::tray::TrayIconEvent::Click { .. } = event {
                        show_main_window(tray.app_handle());
                    }
                })
                .build(app)?;

            // Auto-start the gateway, point Codex at it, then keep the chips
            // bridge ticking every 5 seconds.
            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                {
                    let state = handle.state::<AppState>();
                    let settings = state.settings();
                    if gateway::start(&state.gw, &settings).await.is_ok() {
                        let _ = codex_route::apply(settings.port, &settings.api_key);
                        if let Ok(client) = quota::client() {
                            let _ =
                                codex_route::sync_catalog(&client, settings.port, &settings.api_key)
                                    .await;
                        }
                        // Arm the watchdog: without this the auto-started
                        // engine would get no auto-restart after a crash.
                        if let Ok(mut guard) = state.watchdog.lock() {
                            guard.supervised = true;
                            guard.user_stopped = false;
                            guard.misses = 0;
                        }
                    }
                }
                let mut tick: u64 = 0;
                loop {
                    {
                        let state = handle.state::<AppState>();
                        let settings = state.settings();
                        bridge::tick(&state.bridge, &settings).await;
                        tick += 1;
                        if tick % 6 == 0 {
                            watchdog_check(&state).await;
                        }
                    }
                    tokio::time::sleep(std::time::Duration::from_secs(5)).await;
                }
            });

            // Scheduler: one due task per 30 s tick, serial with "Run now".
            // It runs only while this process is alive — no background service.
            let scheduler_handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                loop {
                    let settings = {
                        let state = scheduler_handle.state::<AppState>();
                        state.settings()
                    };
                    scheduler::tick(&settings, &scheduler_handle).await;
                    tokio::time::sleep(std::time::Duration::from_secs(scheduler::TICK_SECS)).await;
                }
            });
            Ok(())
        })
        // Closing the window must not stop the scheduler: hide it to the tray
        // and keep the process (and the 30 s tick) alive. Quit is explicit in
        // the tray menu.
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .invoke_handler(tauri::generate_handler![
            app_info,
            settings_get,
            settings_set,
            gateway_status,
            gateway_start,
            gateway_stop,
            gateway_sync,
            gateway_check,
            gateway_recent_calls,
            gateway_models,
            vault_list,
            quota_refresh,
            quota_history,
            switch_account,
            import_current_auth,
            account_refresh_tokens,
            save_reserves,
            delete_account,
            device_login_start,
            device_login_poll,
            routing_state,
            set_routing_strategy,
            move_priority,
            reset_priority,
            set_account_role,
            codex_route_status,
            codex_route_apply,
            codex_route_remove,
            bridge_status,
            bridge_launch_codex,
            scheduler_list,
            scheduler_save,
            scheduler_delete,
            scheduler_run_now,
            scheduler_models,
            instances_list,
            instance_create,
            instance_delete,
            instance_bind,
            instance_launch,
            autostart_get,
            autostart_set,
            update_check,
            update_apply,
            openrouter_refresh,
            claude_login_start,
            claude_login_status,
            claude_login_cancel,
            claude_credentials,
            claude_models,
            claude_usage,
            claude_refresh,
            claude_disconnect,
            antigravity_login_start,
            antigravity_login_status,
            antigravity_login_cancel,
            antigravity_credentials,
            antigravity_models,
            antigravity_metrics,
            antigravity_refresh,
            antigravity_disconnect,
            open_url,
        ])
        .run(tauri::generate_context!())
        .expect("Melon Tools failed to start");
}

#[cfg(test)]
mod tests {
    use super::{api_toggle_action, launcher_argv, settings_view, tray_event_payload, ApiToggle};

    #[test]
    fn tray_events_map_to_frontend_actions() {
        let scheduler = tray_event_payload("scheduler").unwrap();
        assert_eq!(scheduler["action"], "navigate");
        assert_eq!(scheduler["section"], "scheduler");
        let run = tray_event_payload("run-next").unwrap();
        assert_eq!(run["action"], "run-next");
        assert!(tray_event_payload("show").is_none());
        assert!(tray_event_payload("api-toggle").is_none());
        assert!(tray_event_payload("unknown").is_none());
    }

    #[test]
    fn api_toggle_pauses_only_a_running_gateway() {
        assert_eq!(api_toggle_action(true, false), ApiToggle::Stop);
        assert_eq!(api_toggle_action(false, false), ApiToggle::Start);
        assert_eq!(api_toggle_action(true, true), ApiToggle::Start);
        assert_eq!(api_toggle_action(false, true), ApiToggle::Start);
    }

    #[test]
    fn launcher_accepts_only_http_schemes() {
        assert_eq!(
            launcher_argv("https://example.com/login?x=1&y=2").unwrap(),
            [
                "url.dll,FileProtocolHandler".to_string(),
                "https://example.com/login?x=1&y=2".to_string()
            ]
        );
        assert!(launcher_argv("http://127.0.0.1:18317/").is_ok());
        for bad in [
            "file:///C:/Windows/System32/cmd.exe",
            "javascript:alert(1)",
            "shell:startup",
            "ms-settings:",
            "cmd /C calc",
        ] {
            assert!(launcher_argv(bad).is_err(), "accepted {bad}");
        }
    }

    #[test]
    fn settings_view_redacts_the_management_secret() {
        let mut settings = crate::settings::Settings::default();
        settings.port = 19000;
        settings.management_secret = "melon-mgmt-0123456789abcdef".to_string();
        let value = settings_view(&settings).unwrap();
        assert_eq!(value["managementSecret"], "");
        assert_eq!(value["port"], 19000);
        assert!(!value.to_string().contains("melon-mgmt-"));
    }
}
