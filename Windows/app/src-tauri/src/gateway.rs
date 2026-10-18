//! The local Codex API gateway (CLIProxyAPI sidecar): config, auth sync,
//! process lifecycle and the live request-rate counter.

use serde_json::{json, Value};
use std::fs;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::time::Duration;

use crate::paths;
use crate::settings::Settings;
use crate::vault::{self, Account};

pub struct Gateway {
    pub child: Mutex<Option<Child>>,
}

impl Gateway {
    pub fn new() -> Self {
        Self {
            child: Mutex::new(None),
        }
    }
}

const SIDECAR_NAMES: [&str; 2] = [
    "cliproxyapi-x86_64-pc-windows-msvc.exe",
    "cliproxyapi.exe",
];

pub fn resolve_sidecar() -> Option<PathBuf> {
    resolve_sidecar_checked().ok()
}

/// The embedded engine comes first (single-file install); loose files next to
/// the app stay supported for development and manual installs.
fn resolve_sidecar_checked() -> Result<PathBuf, String> {
    if let Ok(path) = crate::engine::ensure_engine() {
        return Ok(path);
    }
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Ok(from_env) = std::env::var("MELON_GATEWAY_BIN") {
        candidates.push(PathBuf::from(from_env));
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            for name in SIDECAR_NAMES {
                candidates.push(dir.join(name));
                candidates.push(dir.join("binaries").join(name));
            }
        }
    }
    let dev = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("binaries");
    for name in SIDECAR_NAMES {
        candidates.push(dev.join(name));
    }
    candidates
        .into_iter()
        .find(|p| p.exists())
        .ok_or_else(|| "не удалось распаковать движок шлюза".to_string())
}

fn create_no_window(_cmd: &mut Command) {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        _cmd.creation_flags(0x0800_0000);
    }
}

// MARK: - Config

const OPENCODE_MODELS: &[(&str, &str)] = &[
    ("claude-haiku-5-5", "Claude Haiku 5.5"),
    ("deepseek-v4-pro", "DeepSeek V4 Pro"),
    ("deepseek-v4.1-flash", "DeepSeek V4.1 Flash"),
    ("glm-5.3", "GLM 5.3"),
    ("glm-5.3-flash", "GLM 5.3 Flash"),
    ("gpt-6-luna", "GPT 6 Luna"),
    ("grok-4.7", "Grok 4.7"),
    ("kimi-k2.7-code", "Kimi K2.7 Code"),
    ("kimi-k3", "Kimi K3"),
    ("minimax-m3", "MiniMax M3"),
    ("qwen3.6-plus", "Qwen3.6 Plus"),
    ("qwen3.8-flash", "Qwen3.8 Flash"),
];

pub fn write_config(settings: &Settings) -> Result<(), String> {
    fs::create_dir_all(paths::gateway_dir()).map_err(|e| e.to_string())?;
    fs::create_dir_all(paths::auths_dir()).map_err(|e| e.to_string())?;
    let auth_dir = paths::yaml_path(&paths::auths_dir());

    let mut yaml = format!(
        r#"# Melon Tools — Codex API gateway config (CLIProxyAPI)
config-version: 8
server:
  host: "127.0.0.1"
  port: {port}
access:
  api-keys:
    - "{api_key}"
oauth:
  auth-dir: "{auth_dir}"
remote-management:
  allow-remote: false
  secret-key: "$2a$10$f34uvllQ6GFMZdJvOuWZHOsFGm5Qe3tA63kd9cDH.yVVjYtCBSuC2"
  disable-control-panel: true
  disable-auto-update-panel: true
routing:
  strategy: "fill-first"
# Fail over to another account while the leader is cooling down.
request-retry: 3
max-retry-interval: 45
transient-error-cooldown-seconds: 20
"#,
        port = settings.port,
        api_key = settings.api_key,
        auth_dir = auth_dir,
    );

    if !settings.opencode_key.is_empty() {
        yaml.push_str(&format!(
            r#"api-keys:
  openai-compatibility:
    - name: "opencode-go"
      base-url: "https://opencode.ai/inference/go/openai/v1"
      headers:
        user-agent: "MelonTools/1.4"
        x-opencode-session: "melon-tools"
      keys:
        - api-key: "{key}"
      models:
"#,
            key = settings.opencode_key
        ));
        for (name, display) in OPENCODE_MODELS {
            yaml.push_str(&format!(
                "        - name: \"{name}\"\n          alias: \"opencode/{name}\"\n          display-name: \"{display}\"\n"
            ));
        }
    }

    if !settings.openrouter_key.is_empty() {
        yaml.push_str(&format!(
            r#"    - name: "openrouter"
      base-url: "https://openrouter.ai/api/v1"
      keys:
        - api-key: "{key}"
"#,
            key = settings.openrouter_key
        ));
    }

    fs::write(paths::config_path(), yaml).map_err(|e| e.to_string())
}

// MARK: - Auth files

fn auth_file_name(account: &Account, index: usize) -> String {
    let email: String = account
        .email
        .clone()
        .unwrap_or_else(|| format!("account{}", index))
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || "@._-".contains(*c))
        .collect();
    let account_id = account
        .account_id
        .clone()
        .or_else(|| account.tokens.account_id.clone())
        .unwrap_or_default();
    let short: String = account_id.chars().filter(|c| c.is_ascii_alphanumeric()).take(8).collect();
    if short.is_empty() {
        format!("codex-{}.json", email)
    } else {
        format!("codex-{}-{}.json", email, short)
    }
}

/// Mirrors the macOS sync: the auths directory is replaced with the current
/// vault, ordered by the routing planner (strategy + manual order + roles),
/// and accounts the planner paused (window exhausted or below the user's
/// reserve) get `"disabled": true`.
pub fn sync_accounts(settings: &Settings) -> Result<usize, String> {
    let accounts = vault::accounts();
    let (ordered_ids, _) = crate::routing::resolve(
        &accounts,
        &settings.routing_strategy,
        &settings.priority_order,
    );
    let mut ordered: Vec<Account> = Vec::new();
    for id in &ordered_ids {
        if let Some(account) = accounts.iter().find(|a| &a.id == id) {
            ordered.push(account.clone());
        }
    }

    let dir = paths::auths_dir();
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    if let Ok(entries) = fs::read_dir(&dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) == Some("json") {
                let _ = fs::remove_file(path);
            }
        }
    }

    let mut written = 0usize;
    for (index, account) in ordered.iter().enumerate() {
        let Some(access) = account.tokens.access_token.clone().filter(|t| !t.is_empty()) else {
            continue;
        };
        let expired = account
            .tokens
            .access_expiry_unix()
            .and_then(|ts| chrono::DateTime::from_timestamp(ts as i64, 0))
            .map(|dt| dt.to_rfc3339())
            .unwrap_or_default();
        let account_id = account
            .account_id
            .clone()
            .or_else(|| account.tokens.account_id.clone())
            .unwrap_or_default();

        let mut payload = json!({
            "id_token": account.tokens.id_token.clone().unwrap_or_default(),
            "access_token": access,
            "refresh_token": account.tokens.refresh_token.clone().unwrap_or_default(),
            "account_id": account_id,
            "last_refresh": account.last_refresh.clone().unwrap_or_else(|| chrono::Utc::now().to_rfc3339()),
            "email": account.email.clone().unwrap_or_default(),
            "type": "codex",
            "expired": expired,
            "plan_type": account.plan_type.clone().unwrap_or_else(|| "free".to_string()),
            "priority": index + 1,
        });
        if account.is_blocked() {
            payload["disabled"] = json!(true);
        }
        let file = dir.join(auth_file_name(account, index));
        fs::write(
            file,
            serde_json::to_string_pretty(&payload).map_err(|e| e.to_string())?,
        )
        .map_err(|e| e.to_string())?;
        written += 1;
    }
    Ok(written)
}

// MARK: - Lifecycle

pub async fn health(port: u16, api_key: &str) -> bool {
    let client = match reqwest::Client::builder()
        .timeout(Duration::from_secs(3))
        .build()
    {
        Ok(c) => c,
        Err(_) => return false,
    };
    match client
        .get(format!("http://127.0.0.1:{}/v1/models", port))
        .header("Authorization", format!("Bearer {}", api_key))
        .send()
        .await
    {
        Ok(resp) => resp.status().is_success(),
        Err(_) => false,
    }
}

pub async fn start(gateway: &Gateway, settings: &Settings) -> Result<String, String> {
    if health(settings.port, &settings.api_key).await {
        write_config(settings)?;
        sync_accounts(settings)?;
        return Ok("adopted".to_string());
    }

    write_config(settings)?;
    sync_accounts(settings)?;

    let binary = resolve_sidecar_checked()?;

    let log = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(paths::log_path())
        .map_err(|e| e.to_string())?;
    let log_err = log.try_clone().map_err(|e| e.to_string())?;

    let mut command = Command::new(&binary);
    command
        .arg("-config")
        .arg(paths::config_path())
        .stdin(Stdio::null())
        .stdout(Stdio::from(log))
        .stderr(Stdio::from(log_err));
    create_no_window(&mut command);

    let child = command.spawn().map_err(|e| e.to_string())?;
    let pid = child.id();
    if let Ok(mut guard) = gateway.child.lock() {
        *guard = Some(child);
    }
    let _ = fs::write(paths::pid_path(), pid.to_string());

    for _ in 0..30 {
        tokio::time::sleep(Duration::from_millis(500)).await;
        if health(settings.port, &settings.api_key).await {
            return Ok("started".to_string());
        }
    }
    Err("шлюз не ответил за 15 секунд — смотрите gateway.log".to_string())
}

pub fn stop(gateway: &Gateway) -> Result<String, String> {
    if let Ok(mut guard) = gateway.child.lock() {
        if let Some(mut child) = guard.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
    // Adopted or orphaned instances are killed by image name.
    #[cfg(windows)]
    {
        for name in SIDECAR_NAMES {
            let mut command = Command::new("taskkill");
            command.args(["/IM", name, "/F"]);
            create_no_window(&mut command);
            let _ = command.output();
        }
    }
    let _ = fs::remove_file(paths::pid_path());
    Ok("stopped".to_string())
}

// MARK: - Live rate

/// POST /v1/* requests in the last 60 seconds, parsed from the gateway log.
pub fn requests_last_minute() -> usize {
    let Ok(text) = fs::read_to_string(paths::log_path()) else {
        return 0;
    };
    let now = chrono::Local::now().naive_local();
    text.lines()
        .rev()
        .take(600)
        .filter(|line| {
            line.contains("POST") && line.contains("/v1/") && {
                match parse_timestamp(line) {
                    Some(ts) => (now - ts).num_seconds() <= 60,
                    None => false,
                }
            }
        })
        .count()
}

fn parse_timestamp(line: &str) -> Option<chrono::NaiveDateTime> {
    let start = line.find('[')? + 1;
    let end = line[start..].find(']')? + start;
    chrono::NaiveDateTime::parse_from_str(&line[start..end], "%Y-%m-%d %H:%M:%S").ok()
}

// MARK: - Recent calls + models (dashboard / providers)

fn log_tail(cap: usize) -> String {
    let Ok(data) = fs::read(paths::log_path()) else {
        return String::new();
    };
    if data.len() <= cap {
        return String::from_utf8_lossy(&data).to_string();
    }
    let slice = &data[data.len() - cap..];
    let start = slice
        .iter()
        .position(|b| *b == b'\n')
        .map(|offset| offset + 1)
        .unwrap_or(0);
    String::from_utf8_lossy(&slice[start..]).to_string()
}

/// The newest gateway requests (method, path, status, duration) for the
/// dashboard "recent calls" card.
pub fn recent_calls(limit: usize) -> Value {
    let text = log_tail(512 * 1024);
    let mut calls: Vec<Value> = Vec::new();
    for line in text.lines().rev() {
        if !line.contains("\"/v1/") {
            continue;
        }
        let parts: Vec<&str> = line.split('|').collect();
        if parts.len() < 5 {
            continue;
        }
        let time = line
            .find('[')
            .and_then(|start| line.find(']').map(|end| &line[start + 1..end]))
            .unwrap_or("");
        let rest = parts[4].trim();
        let mut tokens = rest.split_whitespace();
        let method = tokens.next().unwrap_or("");
        let path = tokens.next().unwrap_or("").trim_matches('"');
        calls.push(json!({
            "time": time,
            "status": parts[1].trim(),
            "duration": parts[2].trim(),
            "method": method,
            "path": path,
        }));
        if calls.len() >= limit {
            break;
        }
    }
    Value::Array(calls)
}

/// The gateway's live model list (id + owner) for the providers page.
pub async fn models(port: u16, api_key: &str) -> Result<Value, String> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .build()
        .map_err(|e| e.to_string())?;
    let response = client
        .get(format!("http://127.0.0.1:{}/v1/models", port))
        .header("Authorization", format!("Bearer {}", api_key))
        .send()
        .await
        .map_err(|e| e.to_string())?;
    let value: Value = response.json().await.map_err(|e| e.to_string())?;
    Ok(value.get("data").cloned().unwrap_or_else(|| json!([])))
}

// MARK: - End-to-end check

pub async fn check_api(port: u16, api_key: &str) -> Result<String, String> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(60))
        .build()
        .map_err(|e| e.to_string())?;
    let models_response = client
        .get(format!("http://127.0.0.1:{}/v1/models", port))
        .header("Authorization", format!("Bearer {}", api_key))
        .send()
        .await
        .map_err(|e| e.to_string())?;
    let models_text = models_response.text().await.map_err(|e| e.to_string())?;
    let models: Value = serde_json::from_str(&models_text).map_err(|e| e.to_string())?;
    let model = models
        .get("data")
        .and_then(|d| d.as_array())
        .and_then(|arr| {
            arr.iter()
                .filter_map(|m| m.get("id").and_then(|v| v.as_str()))
                .find(|id| !id.starts_with("opencode/") && !id.starts_with("openrouter/"))
                .or_else(|| {
                    arr.iter()
                        .filter_map(|m| m.get("id").and_then(|v| v.as_str()))
                        .next()
                })
        })
        .ok_or_else(|| "шлюз не вернул список моделей".to_string())?
        .to_string();

    let body = json!({
        "model": model,
        "messages": [{"role": "user", "content": "ping"}],
        "max_tokens": 5
    });
    let response = client
        .post(format!("http://127.0.0.1:{}/v1/chat/completions", port))
        .header("Authorization", format!("Bearer {}", api_key))
        .json(&body)
        .send()
        .await
        .map_err(|e| e.to_string())?;
    let status = response.status();
    let text = response.text().await.map_err(|e| e.to_string())?;
    if status.is_success() {
        Ok(text.chars().take(400).collect())
    } else {
        Err(format!(
            "{}: {}",
            status.as_u16(),
            text.chars().take(300).collect::<String>()
        ))
    }
}
