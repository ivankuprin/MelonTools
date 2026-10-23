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

    let mut yaml = base_config(
        settings.port,
        &settings.api_key,
        &auth_dir,
        &settings.management_secret,
    );
    yaml.push_str(&api_keys_yaml(settings));

    // Atomic replace: a crash mid-write must not leave a broken config the
    // engine would refuse to start with.
    let path = paths::config_path();
    let tmp = paths::tmp_path(&path);
    fs::write(&tmp, yaml).map_err(|e| e.to_string())?;
    fs::rename(&tmp, &path).map_err(|e| e.to_string())
}

/// The fixed part of config.yaml. `secret` is the plaintext management secret:
/// the engine bcrypt-hashes it on load and every management call authenticates
/// with the plaintext value.
fn base_config(port: u16, api_key: &str, auth_dir: &str, secret: &str) -> String {
    format!(
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
  secret-key: "{secret}"
  disable-control-panel: true
  disable-auto-update-panel: true
routing:
  strategy: "fill-first"
# Fail over to another account while the leader is cooling down.
request-retry: 3
max-retry-interval: 45
transient-error-cooldown-seconds: 20
"#,
        port = port,
        api_key = yaml_escape(api_key),
        auth_dir = auth_dir,
        secret = yaml_escape(secret),
    )
}

/// Claude model catalogue for the API-key fallback: raw Anthropic ids used as
/// both `name` and `alias`, so the engine lists slash-less `claude-*` ids.
const CLAUDE_MODELS: &[(&str, &str)] = &[
    ("claude-opus-5-5", "Claude Opus 5.5"),
    ("claude-sonnet-5-5", "Claude Sonnet 5.5"),
    ("claude-opus-4-6", "Claude Opus 4.6"),
    ("claude-sonnet-4-6", "Claude Sonnet 4.6"),
    ("claude-haiku-4-5-20251001", "Claude Haiku 4.5"),
];

/// Version-carrying User-Agent for managed upstreams (D2): derived from the
/// crate version so a release never advertises a stale build.
pub(crate) const USER_AGENT: &str = concat!("MelonTools/", env!("CARGO_PKG_VERSION"));

/// The single optional top-level `api-keys:` root. OpenCode and OpenRouter
/// ride `openai-compatibility`; the Anthropic API-key fallback rides `claude`.
/// Every section is emitted from this one builder — a second root would break
/// the engine config. Returns an empty string when nothing is configured.
pub fn api_keys_yaml(settings: &Settings) -> String {
    let opencode = settings.opencode_enabled && !settings.opencode_key.trim().is_empty();
    let openrouter = settings.openrouter_enabled && !settings.openrouter_key.trim().is_empty();
    let deepinfra = settings.deepinfra_enabled
        && !settings.deepinfra_key.trim().is_empty()
        && !settings.deepinfra_models.is_empty();
    let vercel = settings.vercel_enabled
        && !settings.vercel_key.trim().is_empty()
        && !settings.vercel_models.is_empty();
    let claude = settings.claude_enabled && !settings.claude_api_key.trim().is_empty();
    if !opencode && !openrouter && !deepinfra && !vercel && !claude {
        return String::new();
    }

    let mut yaml = String::from("api-keys:\n");

    if opencode || openrouter || deepinfra || vercel {
        yaml.push_str("  openai-compatibility:\n");
        if opencode {
            yaml.push_str("    - name: \"opencode-go\"\n");
            yaml.push_str("      base-url: \"https://opencode.ai/inference/go/openai/v1\"\n");
            yaml.push_str("      headers:\n");
            yaml.push_str(&format!("        user-agent: \"{}\"\n", USER_AGENT));
            yaml.push_str("        x-opencode-session: \"melon-tools\"\n");
            yaml.push_str(&format!(
                "      keys:\n        - api-key: \"{}\"\n",
                yaml_escape(&settings.opencode_key)
            ));
            yaml.push_str("      models:\n");
            for (name, display) in OPENCODE_MODELS {
                yaml.push_str(&format!(
                    "        - name: \"{name}\"\n          alias: \"opencode/{name}\"\n          display-name: \"{display}\"\n"
                ));
            }
        }
        if openrouter {
            yaml.push_str("    - name: \"openrouter\"\n");
            yaml.push_str("      base-url: \"https://openrouter.ai/api/v1\"\n");
            yaml.push_str(&format!(
                "      keys:\n        - api-key: \"{}\"\n",
                yaml_escape(&settings.openrouter_key)
            ));
        }
        if deepinfra {
            yaml.push_str("    - name: \"deepinfra\"\n");
            yaml.push_str("      base-url: \"https://api.deepinfra.com/v1/openai\"\n");
            yaml.push_str(&format!(
                "      keys:\n        - api-key: \"{}\"\n",
                yaml_escape(&settings.deepinfra_key)
            ));
            push_cached_models(&mut yaml, "deepinfra", &settings.deepinfra_models);
        }
        if vercel {
            yaml.push_str("    - name: \"vercel\"\n");
            yaml.push_str("      base-url: \"https://ai-gateway.vercel.sh/v1\"\n");
            yaml.push_str(&format!(
                "      keys:\n        - api-key: \"{}\"\n",
                yaml_escape(&settings.vercel_key)
            ));
            push_cached_models(&mut yaml, "vercel", &settings.vercel_models);
        }
    }

    if claude {
        yaml.push_str("  claude:\n");
        yaml.push_str("    - name: \"claude\"\n");
        yaml.push_str("      base-url: \"https://api.anthropic.com\"\n");
        yaml.push_str(&format!(
            "      keys:\n        - api-key: \"{}\"\n",
            yaml_escape(&settings.claude_api_key)
        ));
        yaml.push_str("      models:\n");
        for (name, display) in CLAUDE_MODELS {
            yaml.push_str(&format!(
                "        - name: \"{name}\"\n          alias: \"{name}\"\n          display-name: \"{display}\"\n"
            ));
        }
    }

    yaml
}

/// Explicit model list for a cached provider. The gateway must never discover
/// unfiltered upstream models when a key is configured.
fn push_cached_models(
    yaml: &mut String,
    provider: &str,
    models: &[crate::settings::ProviderModel],
) {
    yaml.push_str("      models:\n");
    for model in models {
        yaml.push_str(&format!(
            "        - name: \"{id}\"\n          alias: \"{provider}/{id}\"\n",
            id = yaml_escape(&model.id),
            provider = provider,
        ));
        if !model.display.trim().is_empty() {
            yaml.push_str(&format!(
                "          display-name: \"{}\"\n",
                yaml_escape(&model.display)
            ));
        }
        if let Some(context) = model.context_window.filter(|value| *value > 0) {
            yaml.push_str(&format!("          max-context-length: {}\n", context));
        }
    }
}

/// YAML values are double-quoted: escape the quote and the backslash, and drop
/// control characters (a pasted key must not break the config).
fn yaml_escape(value: &str) -> String {
    value
        .chars()
        .filter(|c| !c.is_control())
        .flat_map(|c| match c {
            '"' => vec!['\\', '"'],
            '\\' => vec!['\\', '\\'],
            other => vec![other],
        })
        .collect()
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
    // Only the files this sync owns are replaced: engine-written auth files of
    // other providers (claude-*.json) must survive an account sync.
    if let Ok(entries) = fs::read_dir(&dir) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if crate::claude::is_codex_auth_file_name(&name) {
                let _ = fs::remove_file(entry.path());
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
        let payload = serde_json::to_string_pretty(&payload).map_err(|e| e.to_string())?;
        // Temp + rename, like config.yaml: the engine must never hot-reload a
        // half-written auth file.
        let tmp = paths::tmp_path(&file);
        fs::write(&tmp, payload).map_err(|e| e.to_string())?;
        fs::rename(&tmp, &file).map_err(|e| e.to_string())?;
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
    rotate_log(&paths::log_path());
    if health(settings.port, &settings.api_key).await {
        write_config(settings)?;
        sync_accounts(settings)?;
        return Ok("adopted".to_string());
    }

    write_config(settings)?;
    sync_accounts(settings)?;

    // A wedged child (alive but not answering health) would hold the port:
    // terminate it before spawning a fresh engine, otherwise the retry path
    // accumulates engines that can never bind.
    if let Ok(mut guard) = gateway.child.lock() {
        if let Some(mut child) = guard.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }

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
    // An adopted or orphaned engine is killed by the PID we recorded when we
    // started it, and only after tasklist confirms that PID is still our
    // engine: an image-name taskkill could hit an unrelated cliproxyapi.
    let recorded = fs::read_to_string(paths::pid_path()).ok();
    match recorded.as_deref().and_then(parse_pid) {
        Some(pid) => stop_recorded_pid(pid),
        None => {
            // No usable PID record (first run of an older build): keep the
            // old image-name sweep as the only available cleanup.
            #[cfg(windows)]
            {
                for name in SIDECAR_NAMES {
                    let mut command = Command::new("taskkill");
                    command.args(["/IM", name, "/F"]);
                    create_no_window(&mut command);
                    let _ = command.output();
                }
            }
        }
    }
    let _ = fs::remove_file(paths::pid_path());
    Ok("stopped".to_string())
}

/// PID file contents: one decimal process id (whitespace and a trailing
/// newline are tolerated). Zero is never a valid target.
pub(crate) fn parse_pid(text: &str) -> Option<u32> {
    text.trim().parse::<u32>().ok().filter(|pid| *pid != 0)
}

/// First CSV field of `tasklist /FO CSV /NH` output. The "no tasks" notice is
/// not CSV, so it yields `None` instead of a bogus image name.
#[cfg(any(windows, test))]
pub(crate) fn parse_tasklist_image(output: &str) -> Option<String> {
    let line = output.lines().map(str::trim).find(|line| line.starts_with('"'))?;
    let name = line.trim_start_matches('"').split('"').next()?.trim();
    (!name.is_empty()).then(|| name.to_string())
}

/// PID column of `tasklist /FO CSV /NH` rows. Non-CSV output is skipped.
#[cfg(any(windows, test))]
pub(crate) fn parse_tasklist_pids(output: &str) -> Vec<u32> {
    let mut pids = Vec::new();
    for line in output.lines().map(str::trim).filter(|line| line.starts_with('"')) {
        let fields: Vec<&str> = line.split("\",\"").collect();
        if let Some(pid) = fields
            .get(1)
            .and_then(|field| field.trim_end_matches('"').trim().parse::<u32>().ok())
        {
            pids.push(pid);
        }
    }
    pids
}

/// Image-name identity check: tasklist may report a bare name or a path.
#[cfg(any(windows, test))]
pub(crate) fn image_starts_with(image: &str, prefix: &str) -> bool {
    let base = image
        .rsplit(|c| c == '\\' || c == '/')
        .next()
        .unwrap_or(image)
        .trim();
    base.to_ascii_lowercase()
        .starts_with(&prefix.to_ascii_lowercase())
}

#[cfg(any(windows, test))]
pub(crate) fn image_matches_engine(image: &str) -> bool {
    image_starts_with(image, "cliproxyapi")
}

#[cfg(windows)]
pub(crate) fn tasklist_image_name(pid: u32) -> Option<String> {
    let mut command = Command::new("tasklist.exe");
    command.args(["/FI", &format!("PID eq {}", pid), "/FO", "CSV", "/NH"]);
    create_no_window(&mut command);
    let output = command.output().ok()?;
    if !output.status.success() {
        return None;
    }
    parse_tasklist_image(&String::from_utf8_lossy(&output.stdout))
}

#[cfg(windows)]
pub(crate) fn tasklist_pids(image: &str) -> Vec<u32> {
    let mut command = Command::new("tasklist.exe");
    command.args([
        "/FI",
        &format!("IMAGENAME eq {}", image),
        "/FO",
        "CSV",
        "/NH",
    ]);
    create_no_window(&mut command);
    match command.output() {
        Ok(output) if output.status.success() => {
            parse_tasklist_pids(&String::from_utf8_lossy(&output.stdout))
        }
        _ => Vec::new(),
    }
}

#[cfg(windows)]
pub(crate) fn taskkill_pid(pid: u32, force: bool) -> bool {
    let pid = pid.to_string();
    let mut command = Command::new("taskkill.exe");
    if force {
        command.args(["/PID", &pid, "/F"]);
    } else {
        command.args(["/PID", &pid]);
    }
    create_no_window(&mut command);
    command
        .output()
        .map(|output| output.status.success())
        .unwrap_or(false)
}

#[cfg(windows)]
fn stop_recorded_pid(pid: u32) {
    let Some(image) = tasklist_image_name(pid) else {
        return;
    };
    if image_matches_engine(&image) {
        let _ = taskkill_pid(pid, true);
    }
}

#[cfg(not(windows))]
fn stop_recorded_pid(_pid: u32) {}

// MARK: - Live rate

/// POST /v1/* requests in the last 60 seconds, parsed from the gateway log
/// tail (bounded read — the log grows through the session).
pub fn requests_last_minute() -> usize {
    let text = log_tail(256 * 1024);
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

/// The log is rotated on gateway start once it exceeds this size: the engine is
/// restarted anyway, so the open-handle rename window is safe.
const LOG_ROTATE_BYTES: u64 = 8 * 1024 * 1024;

/// Keeps one backup (`gateway.log.1`). Rotation failure is ignored: the engine
/// may still hold the handle, and the next fresh start retries.
fn rotate_log(path: &std::path::Path) {
    let Ok(metadata) = fs::metadata(path) else {
        return;
    };
    if metadata.len() <= LOG_ROTATE_BYTES {
        return;
    }
    let backup = path.with_extension("log.1");
    let _ = fs::remove_file(&backup);
    let _ = fs::rename(path, &backup);
}

/// Last `cap` bytes of the log, read with a seek. The file grows throughout a
/// session, so a whole-file read here would stall every status poll.
fn log_tail(cap: usize) -> String {
    use std::io::{Read, Seek, SeekFrom};

    let path = paths::log_path();
    let Ok(metadata) = fs::metadata(&path) else {
        return String::new();
    };
    let len = metadata.len();
    let start = len.saturating_sub(cap as u64);
    let Ok(mut file) = fs::File::open(&path) else {
        return String::new();
    };
    if file.seek(SeekFrom::Start(start)).is_err() {
        return String::new();
    }
    let mut data = Vec::with_capacity((len - start) as usize);
    if file.read_to_end(&mut data).is_err() {
        return String::new();
    }
    String::from_utf8_lossy(tail_bytes(&data, start > 0)).to_string()
}

/// Drops the first, partially read line of a bounded tail.
pub(crate) fn tail_bytes<'a>(bytes: &'a [u8], truncated: bool) -> &'a [u8] {
    if !truncated {
        return bytes;
    }
    match bytes.iter().position(|byte| *byte == b'\n') {
        Some(offset) => &bytes[offset + 1..],
        None => bytes,
    }
}

/// Parse one engine access-log line. Error lines append another `| message`,
/// which must not shift the four base fields.
fn parse_recent_call(line: &str) -> Option<Value> {
    if !line.contains("\"/v1/") {
        return None;
    }
    let parts: Vec<&str> = line.split('|').map(str::trim).collect();
    if parts.len() < 4 {
        return None;
    }
    let time = line
        .find('[')
        .and_then(|start| line.find(']').map(|end| &line[start + 1..end]))
        .unwrap_or("");
    let status = parts[0].split_whitespace().last().unwrap_or("");
    let mut tokens = parts[3].split_whitespace();
    let method = tokens.next().unwrap_or("");
    let path = tokens.next().unwrap_or("").trim_matches('"');
    Some(json!({
        "time": time,
        "status": status,
        "duration": parts[1],
        "method": method,
        "path": path,
    }))
}

/// The newest gateway requests (method, path, status, duration) for the
/// dashboard "recent calls" card.
pub fn recent_calls(limit: usize) -> Value {
    let text = log_tail(512 * 1024);
    let mut calls: Vec<Value> = Vec::new();
    for line in text.lines().rev() {
        if let Some(call) = parse_recent_call(line) {
            calls.push(call);
            if calls.len() >= limit {
                break;
            }
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
                .find(|id| {
                    !id.starts_with("opencode/")
                        && !id.starts_with("openrouter/")
                        && !id.starts_with("deepinfra/")
                        && !id.starts_with("vercel/")
                })
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

#[cfg(test)]
mod tests {
    use super::{
        api_keys_yaml, base_config, image_matches_engine, image_starts_with, parse_pid,
        parse_recent_call, parse_tasklist_image, parse_tasklist_pids, tail_bytes, yaml_escape,
        USER_AGENT,
    };
    use crate::settings::Settings;

    fn settings() -> Settings {
        Settings::default()
    }

    #[test]
    fn base_config_carries_the_plaintext_management_secret() {
        let yaml = base_config(18317, "melon-abc", "/tmp/auths", "melon-mgmt-1234");
        assert!(yaml.contains("secret-key: \"melon-mgmt-1234\""));
        // The old hard-coded bcrypt hash must be gone.
        assert!(!yaml.contains("$2a$"));
        assert!(yaml.contains("auth-dir: \"/tmp/auths\""));
    }

    #[test]
    fn yaml_escape_keeps_the_config_valid() {
        assert_eq!(yaml_escape("sk-\"quoted\\path"), "sk-\\\"quoted\\\\path");
        assert_eq!(yaml_escape("sk-line\nbreak"), "sk-linebreak");
    }

    #[test]
    fn api_keys_yaml_is_empty_without_any_source() {
        assert_eq!(api_keys_yaml(&settings()), "");
    }

    #[test]
    fn api_keys_yaml_uses_one_root_for_opencode_openrouter_and_claude() {
        let mut s = settings();
        s.opencode_key = "oc-key".to_string();
        s.openrouter_key = "or-key".to_string();
        s.claude_enabled = true;
        s.claude_api_key = "sk-ant-key".to_string();
        let yaml = api_keys_yaml(&s);
        assert_eq!(yaml.matches("api-keys:").count(), 1);
        assert!(yaml.contains("  openai-compatibility:\n"));
        assert!(yaml.contains("    - name: \"opencode-go\"\n"));
        assert!(yaml.contains("    - name: \"openrouter\"\n"));
        assert!(yaml.contains("  claude:\n"));
        assert!(yaml.contains("    - name: \"claude\"\n"));
        assert!(yaml.contains("      base-url: \"https://api.anthropic.com\"\n"));
        assert!(yaml.contains("        - api-key: \"sk-ant-key\"\n"));
        // Claude models keep a slash-less alias so the gateway lists raw ids.
        assert!(yaml.contains("        - name: \"claude-opus-5-5\"\n          alias: \"claude-opus-5-5\"\n"));
    }

    #[test]
    fn api_keys_yaml_openrouter_only_still_emits_the_root() {
        let mut s = settings();
        s.openrouter_key = "or-key".to_string();
        let yaml = api_keys_yaml(&s);
        assert_eq!(yaml.matches("api-keys:").count(), 1);
        assert!(yaml.contains("  openai-compatibility:\n"));
        assert!(yaml.contains("    - name: \"openrouter\"\n"));
        assert!(!yaml.contains("  claude:\n"));
    }

    #[test]
    fn api_keys_yaml_carries_deepinfra_and_vercel_models() {
        let mut s = settings();
        s.deepinfra_key = "di-key".to_string();
        s.deepinfra_models = vec![crate::settings::ProviderModel {
            id: "deepseek-ai/DeepSeek-V4".to_string(),
            display: "DeepSeek V4".to_string(),
            context_window: Some(131_072),
            ..Default::default()
        }];
        s.vercel_key = "vc-key".to_string();
        s.vercel_models = vec![crate::settings::ProviderModel {
            id: "anthropic/claude-sonnet-4.6".to_string(),
            display: "Claude Sonnet 4.6".to_string(),
            ..Default::default()
        }];
        let yaml = api_keys_yaml(&s);
        assert_eq!(yaml.matches("api-keys:").count(), 1);
        assert!(yaml.contains("    - name: \"deepinfra\"\n"));
        assert!(yaml.contains("      base-url: \"https://api.deepinfra.com/v1/openai\"\n"));
        assert!(yaml.contains("        - name: \"deepseek-ai/DeepSeek-V4\"\n          alias: \"deepinfra/deepseek-ai/DeepSeek-V4\"\n"));
        assert!(yaml.contains("          display-name: \"DeepSeek V4\"\n"));
        assert!(yaml.contains("          max-context-length: 131072\n"));
        assert!(yaml.contains("    - name: \"vercel\"\n"));
        assert!(yaml.contains("      base-url: \"https://ai-gateway.vercel.sh/v1\"\n"));
        assert!(yaml.contains("alias: \"vercel/anthropic/claude-sonnet-4.6\"\n"));
    }

    #[test]
    fn api_keys_yaml_skips_providers_without_cached_models() {
        let mut s = settings();
        s.deepinfra_key = "di-key".to_string();
        s.vercel_key = "vc-key".to_string();
        assert_eq!(api_keys_yaml(&s), "");
        s.deepinfra_enabled = false;
        s.deepinfra_models = vec![crate::settings::ProviderModel {
            id: "chat".to_string(),
            display: "Chat".to_string(),
            ..Default::default()
        }];
        assert_eq!(api_keys_yaml(&s), "");
    }

    #[test]
    fn api_keys_yaml_claude_requires_the_key_and_the_switch() {
        let mut s = settings();
        s.claude_api_key = "sk-ant-key".to_string();
        // Enabled is still false: nothing is emitted.
        assert_eq!(api_keys_yaml(&s), "");
        s.claude_enabled = true;
        assert!(api_keys_yaml(&s).contains("  claude:\n"));
        // A whitespace-only key never reaches the config.
        s.claude_api_key = "   ".to_string();
        assert_eq!(api_keys_yaml(&s), "");
    }

    #[test]
    fn user_agent_derives_from_the_crate_version() {
        assert_eq!(
            USER_AGENT,
            format!("MelonTools/{}", env!("CARGO_PKG_VERSION"))
        );
        let mut s = settings();
        s.opencode_key = "oc-key".to_string();
        assert!(api_keys_yaml(&s).contains(&format!("user-agent: \"{}\"", USER_AGENT)));
    }

    #[test]
    fn pid_file_parsing_accepts_only_positive_ids() {
        assert_eq!(parse_pid("1234"), Some(1234));
        assert_eq!(parse_pid(" 1234\n"), Some(1234));
        assert_eq!(parse_pid("0"), None);
        assert_eq!(parse_pid(""), None);
        assert_eq!(parse_pid("12 34"), None);
        assert_eq!(parse_pid("pid=1234"), None);
    }

    #[test]
    fn tasklist_csv_parsing() {
        let output = "\"cliproxyapi.exe\",\"4321\",\"Console\",\"1\",\"12,345 K\"\r\n";
        assert_eq!(parse_tasklist_image(output).as_deref(), Some("cliproxyapi.exe"));
        assert_eq!(parse_tasklist_pids(output), vec![4321]);
        assert_eq!(
            parse_tasklist_image("INFO: No tasks are running which match the specified criteria."),
            None
        );
        assert!(parse_tasklist_pids("INFO: No tasks are running").is_empty());
        let two = "\"ChatGPT.exe\",\"10\",\"Console\",\"1\",\"1 K\"\r\n\"ChatGPT.exe\",\"11\",\"Console\",\"1\",\"1 K\"\r\n";
        assert_eq!(parse_tasklist_pids(two), vec![10, 11]);
    }

    #[test]
    fn pid_identity_matches_only_the_engine() {
        assert!(image_matches_engine("cliproxyapi.exe"));
        assert!(image_matches_engine("CLIProxyAPI-x86_64-pc-windows-msvc.exe"));
        assert!(image_matches_engine("C:\\Tools\\cliproxyapi.exe"));
        assert!(!image_matches_engine("chatgpt.exe"));
        assert!(!image_matches_engine("notcliproxyapi.exe"));
        assert!(image_starts_with("ChatGPT.exe", "chatgpt"));
        assert!(!image_starts_with("ChatGPT-helper.exe", "chatgpt.exe"));
    }

    #[test]
    fn recent_call_parser_matches_the_engine_log_format() {
        let call = parse_recent_call(
            "[2026-10-21 12:00:00] [a1b2c3d4] [info ] 200 |       1.2s |       127.0.0.1 | POST    \"/v1/responses\"",
        )
        .expect("call");
        assert_eq!(call["status"], "200");
        assert_eq!(call["duration"], "1.2s");
        assert_eq!(call["method"], "POST");
        assert_eq!(call["path"], "/v1/responses");
        assert!(parse_recent_call("not a call").is_none());
    }

    #[test]
    fn bounded_tail_drops_the_partial_first_line() {
        let data = b"partial line\nfull line one\nfull line two\n";
        assert_eq!(
            tail_bytes(data, true),
            b"full line one\nfull line two\n".as_slice()
        );
        assert_eq!(tail_bytes(data, false), data.as_slice());
        // A single over-long line is kept (bounded by the read cap).
        assert_eq!(tail_bytes(b"one huge line", true), b"one huge line");
    }
}
