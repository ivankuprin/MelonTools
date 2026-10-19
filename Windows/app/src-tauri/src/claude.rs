//! Claude (Anthropic) provider: engine-managed OAuth login, credential
//! listing/refresh, the model list and the subscription usage poll.
//!
//! The engine (CLIProxyAPI) runs the OAuth flow and stores the account as
//! `claude-*.json` in the gateway auth dir, where it hot-reloads it. The app
//! asks for the authorization URL, opens it in the user's browser and polls
//! the login status. Quota comes from the Anthropic usage endpoint, read with
//! the access token of the auth file; every value is optional and never
//! fabricated.
//!
//! Every management call authenticates with the settings-held plaintext
//! secret (`Authorization: Bearer …` and `X-Management-Key`) — the engine
//! hashed it when it loaded the config.

use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::paths;
use crate::settings::Settings;

const USAGE_URL: &str = "https://api.anthropic.com/api/oauth/usage";
/// Anthropic answers 429 without a Claude-Code-style user agent.
const USAGE_USER_AGENT: &str = "claude-code/1.0";
const CLAUDE_BETA: &str = "oauth-2025-04-20";

// MARK: - Auth files

/// Auth files owned by the Codex account sync. Everything else in the auth
/// dir — above all the engine-written `claude-*.json` — must survive a sync.
pub fn is_codex_auth_file_name(name: &str) -> bool {
    name.starts_with("codex-") && name.ends_with(".json")
}

pub fn is_claude_auth_file_name(name: &str) -> bool {
    name.starts_with("claude-") && name.ends_with(".json")
}

/// Gateway model ids of the Claude provider (slash-less raw ids).
pub fn is_claude_model_id(id: &str) -> bool {
    id.starts_with("claude-")
}

#[derive(Debug, Clone, PartialEq)]
pub struct AuthFile {
    pub name: String,
    pub path: PathBuf,
    pub email: Option<String>,
    pub access_token: Option<String>,
    /// Last modification time: the newest file is the account that was just
    /// connected.
    pub modified: Option<std::time::SystemTime>,
}

/// Tolerant decode of an engine-written auth file: field spellings vary
/// between engine versions, so every field is optional; `type` is enforced
/// only when the file carries one.
pub fn decode_auth_file(name: &str, path: &Path, data: &str) -> Option<AuthFile> {
    let root: Value = serde_json::from_str(data).ok()?;
    if let Some(kind) = root.get("type").and_then(|v| v.as_str()) {
        if kind != "claude" {
            return None;
        }
    }
    Some(AuthFile {
        name: name.to_string(),
        path: path.to_path_buf(),
        email: root.get("email").and_then(|v| v.as_str()).map(String::from),
        access_token: root
            .get("access_token")
            .and_then(|v| v.as_str())
            .map(String::from),
        modified: None,
    })
}

/// Every `claude-*.json` in `dir`, sorted by name (stable first account).
pub fn auth_files_in(dir: &Path) -> Vec<AuthFile> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut files: Vec<AuthFile> = Vec::new();
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().to_string();
        if !is_claude_auth_file_name(&name) {
            continue;
        }
        let path = entry.path();
        let Ok(data) = std::fs::read_to_string(&path) else {
            continue;
        };
        if let Some(mut file) = decode_auth_file(&name, &path, &data) {
            file.modified = entry.metadata().and_then(|m| m.modified()).ok();
            files.push(file);
        }
    }
    files.sort_by(|a, b| a.name.cmp(&b.name));
    files
}

/// The "current account" file: the most recently modified one (the account
/// that was just connected). Ties fall back to the name so the choice stays
/// deterministic.
pub fn newest_of(files: &[AuthFile]) -> Option<AuthFile> {
    files
        .iter()
        .max_by(|a, b| a.modified.cmp(&b.modified).then_with(|| a.name.cmp(&b.name)))
        .cloned()
}

pub fn newest_auth_file_in(dir: &Path) -> Option<AuthFile> {
    newest_of(&auth_files_in(dir))
}

/// Auth files in the live gateway auth dir.
pub fn auth_files() -> Vec<AuthFile> {
    auth_files_in(&paths::auths_dir())
}

/// The newest auth file in the live gateway auth dir.
pub fn newest_auth_file() -> Option<AuthFile> {
    newest_auth_file_in(&paths::auths_dir())
}

// MARK: - Management client

pub struct Management {
    port: u16,
    secret: String,
    client: reqwest::Client,
}

impl Management {
    pub fn new(settings: &Settings) -> Result<Self, String> {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(15))
            .build()
            .map_err(|e| e.to_string())?;
        Ok(Self {
            port: settings.port,
            secret: settings.management_secret.clone(),
            client,
        })
    }

    fn request(&self, method: reqwest::Method, path: &str) -> reqwest::RequestBuilder {
        // The engine accepts either header; both are sent so the app is robust
        // against middleware variants.
        self.client
            .request(
                method,
                format!("http://127.0.0.1:{}{}", self.port, path),
            )
            .header("Authorization", format!("Bearer {}", self.secret))
            .header("X-Management-Key", self.secret.clone())
            .header("Accept", "application/json")
    }

    async fn call(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<Value>,
    ) -> Result<(u16, String), String> {
        let mut request = self.request(method, path);
        if let Some(body) = body {
            request = request.json(&body);
        }
        let response = request.send().await.map_err(|e| e.to_string())?;
        let status = response.status().as_u16();
        let text = response.text().await.map_err(|e| e.to_string())?;
        Ok((status, text))
    }

    fn body_json(text: &str) -> Value {
        serde_json::from_str(text).unwrap_or(Value::Null)
    }

    /// `GET /v8/management/oauth/auth-url?provider=claude&is_webui=true` —
    /// `is_webui=true` is required: it activates the engine callback forwarder
    /// on port 54545.
    pub async fn login_start(&self) -> Result<Value, String> {
        let (status, text) = self
            .call(
                reqwest::Method::GET,
                "/v8/management/oauth/auth-url?provider=claude&is_webui=true",
                None,
            )
            .await
            .map_err(|_| "шлюз не отвечает — запустите его и повторите".to_string())?;
        let body = Self::body_json(&text);
        if status != 200 {
            return Err(format!(
                "шлюз отклонил вход ({})",
                status
            ));
        }
        let (url, state) = parse_auth_url(&body)
            .ok_or_else(|| "шлюз не вернул ссылку входа".to_string())?;
        Ok(json!({ "url": url, "state": state }))
    }

    /// `GET /v8/management/oauth/status?state=…` → `ok` | `wait` | `error`.
    pub async fn login_status(&self, state: &str) -> Result<Value, String> {
        let (status, text) = self
            .call(
                reqwest::Method::GET,
                &format!("/v8/management/oauth/status?state={}", url_query(state)),
                None,
            )
            .await?;
        if status != 200 {
            return Err(format!("шлюз отклонил запрос статуса ({})", status));
        }
        let value = Self::body_json(&text);
        let state_name = parse_status(&value)
            .ok_or_else(|| "шлюз не вернул статус входа".to_string())?;
        Ok(json!({ "status": state_name }))
    }

    /// `DELETE /v8/management/oauth/session?state=…` — drops a pending login.
    pub async fn login_cancel(&self, state: &str) -> Result<Value, String> {
        let (status, _) = self
            .call(
                reqwest::Method::DELETE,
                &format!("/v8/management/oauth/session?state={}", url_query(state)),
                None,
            )
            .await?;
        Ok(json!({ "canceled": (200..300).contains(&status) }))
    }

    /// `GET /v8/management/credentials` (tolerant shape).
    pub async fn credentials(&self) -> Result<Value, String> {
        let (status, text) = self
            .call(reqwest::Method::GET, "/v8/management/credentials", None)
            .await?;
        if status != 200 {
            return Ok(json!({ "credentials": [] }));
        }
        Ok(json!({ "credentials": parse_credentials(&Self::body_json(&text)) }))
    }

    /// Refreshes one credential file (`{"name": …}`) or all of them
    /// (`?all=true`) when no name is given.
    pub async fn refresh(&self, name: Option<&str>) -> Result<Value, String> {
        let (path, body) = match name.filter(|n| !n.is_empty()) {
            Some(name) => (
                "/v8/management/credentials/refresh".to_string(),
                Some(json!({ "name": name })),
            ),
            None => ("/v8/management/credentials/refresh?all=true".to_string(), None),
        };
        let (status, _) = self.call(reqwest::Method::POST, &path, body).await?;
        Ok(json!({ "ok": (200..300).contains(&status) }))
    }
}

// MARK: - Credentials / models

/// Tolerant credential list: entries may sit at the root or under a wrapper
/// key, and the file name may be spelled differently.
pub fn parse_credentials(root: &Value) -> Vec<Value> {
    let items = root
        .as_array()
        .cloned()
        .or_else(|| {
            ["credentials", "files", "items", "data"]
                .iter()
                .find_map(|key| root.get(key).and_then(|v| v.as_array()).cloned())
        })
        .unwrap_or_default();
    items
        .iter()
        .filter_map(|entry| {
            let name = ["name", "file", "file_name", "filename"]
                .iter()
                .find_map(|key| entry.get(key).and_then(|v| v.as_str()))
                .filter(|n| !n.is_empty())?;
            Some(json!({
                "name": name,
                "type": entry.get("type").and_then(|v| v.as_str()),
                "email": entry.get("email").and_then(|v| v.as_str()),
            }))
        })
        .collect()
}

/// `claude-*` model ids served by the running gateway (`GET /v1/models`).
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
    let entries: Vec<Value> = value
        .get("data")
        .and_then(|d| d.as_array())
        .map(|items| {
            items
                .iter()
                .filter_map(|item| item.get("id").and_then(|v| v.as_str()))
                .filter(|id| is_claude_model_id(id))
                .map(|id| {
                    json!({
                        "id": id,
                        "displayName": crate::codex_route::prettify(id),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    Ok(json!({ "models": entries.clone(), "count": entries.len() }))
}

// MARK: - Usage (quota)

/// Quota snapshot. Percent values are the share of the window still
/// available (0…100); every field is optional.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct UsageSnapshot {
    pub five_hour_percent: Option<f64>,
    pub five_hour_reset: Option<String>,
    pub weekly_percent: Option<f64>,
    pub weekly_reset: Option<String>,
    pub plan: Option<String>,
}

pub fn client() -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .timeout(Duration::from_secs(20))
        .build()
        .map_err(|e| e.to_string())
}

/// `GET /v8/management/oauth/auth-url` response: `{status, url, state}`.
pub fn parse_auth_url(root: &Value) -> Option<(String, Option<String>)> {
    let url = root
        .get("url")
        .and_then(|v| v.as_str())
        .or_else(|| root.get("auth_url").and_then(|v| v.as_str()))
        .filter(|url| !url.is_empty())?;
    Some((
        url.to_string(),
        root.get("state").and_then(|v| v.as_str()).map(String::from),
    ))
}

pub fn parse_status(root: &Value) -> Option<String> {
    root.get("status")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .map(String::from)
}

/// Tolerant parser for both usage shapes: legacy (`five_hour`/`seven_day` with
/// `utilization`) and newer (`limits[]` with `kind: session|weekly_all` and
/// `percent`). Legacy values win; per-model `weekly_scoped` windows are not
/// shown. Returns `None` when the payload carries nothing usable.
pub fn parse_usage(root: &Value) -> Option<UsageSnapshot> {
    let mut snapshot = UsageSnapshot::default();

    if let Some(five) = root.get("five_hour") {
        snapshot.five_hour_percent = remaining_percent(five.get("utilization"));
        snapshot.five_hour_reset = reset_date(five.get("resets_at"));
    }
    if let Some(seven) = root.get("seven_day") {
        snapshot.weekly_percent = remaining_percent(seven.get("utilization"));
        snapshot.weekly_reset = reset_date(seven.get("resets_at"));
    }
    if let Some(limits) = root.get("limits").and_then(|v| v.as_array()) {
        for limit in limits {
            match limit.get("kind").and_then(|v| v.as_str()) {
                Some("session") => {
                    if snapshot.five_hour_percent.is_none() {
                        snapshot.five_hour_percent = remaining_percent(limit.get("percent"));
                    }
                    if snapshot.five_hour_reset.is_none() {
                        snapshot.five_hour_reset = reset_date(limit.get("resets_at"));
                    }
                }
                Some("weekly_all") => {
                    if snapshot.weekly_percent.is_none() {
                        snapshot.weekly_percent = remaining_percent(limit.get("percent"));
                    }
                    if snapshot.weekly_reset.is_none() {
                        snapshot.weekly_reset = reset_date(limit.get("resets_at"));
                    }
                }
                _ => {}
            }
        }
    }

    // The payload may carry a plan name; when it does not, the UI shows "—"
    // instead of inventing one.
    snapshot.plan = ["subscriptionType", "subscription_type", "plan"]
        .iter()
        .find_map(|key| root.get(key).and_then(|v| v.as_str()))
        .filter(|plan| !plan.is_empty())
        .map(String::from);

    let has_data = snapshot.five_hour_percent.is_some()
        || snapshot.weekly_percent.is_some()
        || snapshot.plan.is_some();
    has_data.then_some(snapshot)
}

/// `utilization`/`percent` count the *used* share; the app shows what is
/// left. Values outside 0…100 clamp; non-numeric input stays `None`.
pub fn remaining_percent(value: Option<&Value>) -> Option<f64> {
    let used = number(value)?;
    Some((100.0 - used).clamp(0.0, 100.0))
}

pub fn number(value: Option<&Value>) -> Option<f64> {
    let value = value?;
    value
        .as_f64()
        .or_else(|| value.as_str().and_then(|s| s.trim().parse::<f64>().ok()))
}

/// ISO-8601 (with or without fractional seconds) or epoch seconds → RFC-3339.
pub fn reset_date(value: Option<&Value>) -> Option<String> {
    let value = value?;
    if let Some(text) = value.as_str() {
        if let Ok(parsed) = chrono::DateTime::parse_from_rfc3339(text) {
            return Some(parsed.with_timezone(&chrono::Utc).to_rfc3339());
        }
        // Some payloads carry the epoch as a string.
        let seconds = text.trim().parse::<f64>().ok()?;
        return epoch_to_rfc3339(seconds);
    }
    epoch_to_rfc3339(number(Some(value))?)
}

fn epoch_to_rfc3339(seconds: f64) -> Option<String> {
    // Reject absurd epochs (milliseconds would land far in the future).
    if !(1_000_000_000.0..4_000_000_000.0).contains(&seconds) {
        return None;
    }
    chrono::DateTime::from_timestamp(seconds as i64, 0)
        .map(|dt| dt.to_rfc3339())
}

/// Percent-encodes a query value (state tokens, file names).
pub fn url_query(value: &str) -> String {
    let mut out = String::new();
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(byte as char)
            }
            other => out.push_str(&format!("%{:02X}", other)),
        }
    }
    out
}

/// Usage with one recovery on 401/403: refresh the engine credential, re-read
/// the auth file and retry once; otherwise degrade to `None` ("—").
pub async fn usage_snapshot(settings: &Settings) -> Option<UsageSnapshot> {
    let client = client().ok()?;
    let file = newest_auth_file()?;
    let token = file.access_token.clone().filter(|t| !t.is_empty())?;
    match fetch_usage(&client, &token).await {
        Ok(snapshot) => snapshot,
        Err(status) if status == 401 || status == 403 => {
            if let Ok(management) = Management::new(settings) {
                let _ = management.refresh(Some(&file.name)).await;
                tokio::time::sleep(Duration::from_millis(1200)).await;
            }
            let fresh = newest_auth_file()?
                .access_token
                .filter(|t| !t.is_empty())?;
            fetch_usage(&client, &fresh).await.ok().flatten()
        }
        Err(_) => None,
    }
}

/// `Err(status)` for 401/403 (the caller may refresh and retry), `Ok(None)`
/// for any other non-200 answer, `Ok(Some(..))` on a usable payload.
async fn fetch_usage(
    client: &reqwest::Client,
    token: &str,
) -> Result<Option<UsageSnapshot>, u16> {
    let response = client
        .get(USAGE_URL)
        .header("Authorization", format!("Bearer {}", token))
        .header("anthropic-beta", CLAUDE_BETA)
        .header("Accept", "application/json")
        .header("User-Agent", USAGE_USER_AGENT)
        .send()
        .await
        .map_err(|_| 0u16)?;
    let status = response.status().as_u16();
    if status == 401 || status == 403 {
        return Err(status);
    }
    if status != 200 {
        return Ok(None);
    }
    let text = response.text().await.map_err(|_| 0u16)?;
    let value: Value = serde_json::from_str(&text).map_err(|_| 0u16)?;
    Ok(parse_usage(&value))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::fs;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "melon-claude-test-{}-{}",
            std::process::id(),
            tag
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("temp dir");
        dir
    }

    #[test]
    fn auth_file_predicates_split_codex_and_claude() {
        assert!(is_codex_auth_file_name("codex-user@example.com-abc12345.json"));
        assert!(!is_codex_auth_file_name("claude-1a2b3c4d-user@example.com.json"));
        assert!(is_claude_auth_file_name("claude-1a2b3c4d-user@example.com.json"));
        // The old cleanup matched every *.json — these must never be owned.
        assert!(!is_codex_auth_file_name("claude-1a2b3c4d-user@example.com.json"));
        assert!(!is_codex_auth_file_name("codex-user.json.bak"));
        assert!(!is_claude_auth_file_name("codex-user@example.com.json"));
        assert!(is_claude_model_id("claude-opus-5-5"));
        assert!(!is_claude_model_id("opencode/claude-haiku-5-5"));
    }

    #[test]
    fn auth_files_in_reads_only_claude_files_and_sorts_them() {
        let dir = temp_dir("authfiles");
        fs::write(
            dir.join("codex-user@example.com.json"),
            r#"{"type":"codex","email":"codex@example.com"}"#,
        )
        .unwrap();
        fs::write(
            dir.join("claude-zzzz1111-user@example.com.json"),
            r#"{"type":"claude","email":"second@example.com","access_token":"token-2"}"#,
        )
        .unwrap();
        fs::write(
            dir.join("claude-aaaa0000-user@example.com.json"),
            r#"{"type":"claude","email":"first@example.com","access_token":"token-1"}"#,
        )
        .unwrap();
        fs::write(dir.join("notes.txt"), "not an auth file").unwrap();

        let files = auth_files_in(&dir);
        assert_eq!(files.len(), 2);
        assert_eq!(files[0].email.as_deref(), Some("first@example.com"));
        assert_eq!(files[0].access_token.as_deref(), Some("token-1"));
        assert_eq!(files[1].email.as_deref(), Some("second@example.com"));

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn newest_of_picks_the_most_recently_modified_file() {
        let base = std::time::SystemTime::UNIX_EPOCH;
        let older = AuthFile {
            name: "claude-aaaa0000-old@example.com.json".to_string(),
            path: PathBuf::from("/x/older.json"),
            email: Some("old@example.com".to_string()),
            access_token: None,
            modified: Some(base),
        };
        let newer = AuthFile {
            name: "claude-zzzz9999-new@example.com.json".to_string(),
            path: PathBuf::from("/x/newer.json"),
            email: Some("new@example.com".to_string()),
            access_token: None,
            modified: Some(base + Duration::from_secs(60)),
        };
        // The name order and the mtime order disagree on purpose: the newest
        // file must win (the account that was just connected).
        let picked = newest_of(&[newer.clone(), older.clone()]).unwrap();
        assert_eq!(picked.email.as_deref(), Some("new@example.com"));

        // Without usable timestamps the name decides, deterministically.
        let mut a = older.clone();
        a.modified = None;
        let mut b = newer.clone();
        b.modified = None;
        assert_eq!(newest_of(&[a, b]).unwrap().name, "claude-zzzz9999-new@example.com.json");
        assert!(newest_of(&[]).is_none());
    }

    #[test]
    fn newest_auth_file_in_follows_the_modification_time() {
        let dir = temp_dir("newest");
        fs::write(
            dir.join("claude-aaaa0000-old@example.com.json"),
            r#"{"type":"claude","email":"old@example.com","access_token":"old-token"}"#,
        )
        .unwrap();
        // Filesystem timestamps are coarse on some volumes: a visible gap keeps
        // the ordering unambiguous.
        std::thread::sleep(Duration::from_millis(1100));
        fs::write(
            dir.join("claude-zzzz9999-new@example.com.json"),
            r#"{"type":"claude","email":"new@example.com","access_token":"new-token"}"#,
        )
        .unwrap();

        let newest = newest_auth_file_in(&dir).expect("a claude auth file");
        assert_eq!(newest.email.as_deref(), Some("new@example.com"));
        assert_eq!(newest.access_token.as_deref(), Some("new-token"));
        assert!(newest.modified.is_some());
        // The full listing stays name-sorted (disconnect removes every file).
        assert_eq!(
            auth_files_in(&dir)[0].email.as_deref(),
            Some("old@example.com")
        );

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn decode_auth_file_tolerates_missing_fields_and_rejects_other_types() {
        let path = PathBuf::from("/tmp/claude-x.json");
        let decoded = decode_auth_file("claude-x.json", &path, r#"{"email":"a@b.c"}"#)
            .expect("no type field is accepted");
        assert_eq!(decoded.email.as_deref(), Some("a@b.c"));
        assert!(decoded.access_token.is_none());
        assert!(decode_auth_file("claude-x.json", &path, r#"{"type":"claude"}"#).is_some());
        assert!(decode_auth_file("claude-x.json", &path, r#"{"type":"codex"}"#).is_none());
        assert!(decode_auth_file("claude-x.json", &path, "{not json").is_none());
    }

    #[test]
    fn usage_parses_the_legacy_shape() {
        let root = json!({
            "five_hour": {"utilization": 12.5, "resets_at": "2026-10-19T20:00:00Z"},
            "seven_day": {"utilization": 100, "resets_at": 1800000000i64},
            "seven_day_opus": {"utilization": 3},
            "extra_usage": {"enabled": false}
        });
        let snapshot = parse_usage(&root).expect("legacy payload parses");
        assert_eq!(snapshot.five_hour_percent, Some(87.5));
        assert_eq!(
            snapshot.five_hour_reset.as_deref(),
            Some("2026-10-19T20:00:00+00:00")
        );
        assert_eq!(snapshot.weekly_percent, Some(0.0));
        assert!(snapshot.weekly_reset.is_some());
        assert_eq!(snapshot.plan, None);
    }

    #[test]
    fn usage_parses_the_limits_shape_and_ignores_scoped_windows() {
        let root = json!({
            "limits": [
                {"kind": "session", "percent": 40, "resets_at": "2026-10-19T22:00:00.500Z"},
                {"kind": "weekly_scoped", "percent": 90, "scope": {"model": {"display_name": "Opus"}}},
                {"kind": "weekly_all", "percent": 10.25, "resets_at": 1800000000i64}
            ],
            "subscription_type": "pro"
        });
        let snapshot = parse_usage(&root).expect("limits payload parses");
        assert_eq!(snapshot.five_hour_percent, Some(60.0));
        assert_eq!(
            snapshot.five_hour_reset.as_deref(),
            Some("2026-10-19T22:00:00.500+00:00")
        );
        assert_eq!(snapshot.weekly_percent, Some(89.75));
        assert!(snapshot.weekly_reset.is_some());
        assert_eq!(snapshot.plan.as_deref(), Some("pro"));
    }

    #[test]
    fn usage_prefers_legacy_values_over_limits() {
        let root = json!({
            "five_hour": {"utilization": 20},
            "limits": [{"kind": "session", "percent": 80}]
        });
        let snapshot = parse_usage(&root).unwrap();
        assert_eq!(snapshot.five_hour_percent, Some(80.0));
    }

    #[test]
    fn usage_stays_none_without_usable_data() {
        assert!(parse_usage(&json!({})).is_none());
        assert!(parse_usage(&json!({"five_hour": {}, "seven_day": {}})).is_none());
        assert!(parse_usage(&json!({"limits": [{"kind": "weekly_scoped", "percent": 5}]})).is_none());
    }

    #[test]
    fn usage_numbers_clamp_and_tolerate_strings() {
        assert_eq!(remaining_percent(Some(&json!(150))), Some(0.0));
        assert_eq!(remaining_percent(Some(&json!(-5))), Some(100.0));
        assert_eq!(remaining_percent(Some(&json!("25"))), Some(75.0));
        assert_eq!(remaining_percent(Some(&json!("not a number"))), None);
        assert_eq!(remaining_percent(None), None);
        assert_eq!(number(Some(&json!(7))), Some(7.0));
    }

    #[test]
    fn reset_dates_reject_absurd_epochs_and_accept_iso() {
        assert!(reset_date(Some(&json!("2026-10-19T20:00:00Z"))).is_some());
        assert!(reset_date(Some(&json!(1800000000i64))).is_some());
        assert!(reset_date(Some(&json!(1_700_000_000_000i64))).is_none());
        assert!(reset_date(Some(&json!("garbage"))).is_none());
        assert!(reset_date(None).is_none());
    }

    #[test]
    fn auth_url_and_status_parsers_are_tolerant() {
        let (url, state) = parse_auth_url(&json!({
            "status": "ok",
            "url": "https://claude.ai/oauth/authorize?x=1",
            "state": "abc"
        }))
        .unwrap();
        assert_eq!(url, "https://claude.ai/oauth/authorize?x=1");
        assert_eq!(state.as_deref(), Some("abc"));
        assert!(parse_auth_url(&json!({"status": "ok"})).is_none());
        assert_eq!(parse_status(&json!({"status": "wait"})).as_deref(), Some("wait"));
        assert!(parse_status(&json!({})).is_none());
    }

    #[test]
    fn credentials_parse_root_and_wrapper_shapes() {
        let wrapped = parse_credentials(&json!({
            "credentials": [
                {"name": "claude-1a2b3c4d-user@example.com.json", "type": "claude", "email": "user@example.com"},
                {"file_name": "other.json"},
                {"type": "claude"}
            ]
        }));
        assert_eq!(wrapped.len(), 2);
        assert_eq!(wrapped[0]["name"], "claude-1a2b3c4d-user@example.com.json");
        assert_eq!(wrapped[0]["email"], "user@example.com");
        assert_eq!(wrapped[1]["name"], "other.json");
        assert_eq!(wrapped[1]["email"], serde_json::Value::Null);

        let direct = parse_credentials(&json!([{"filename": "a.json"}]));
        assert_eq!(direct.len(), 1);
        assert!(parse_credentials(&json!({"unexpected": true})).is_empty());
    }

    #[test]
    fn url_query_encodes_state_tokens() {
        assert_eq!(url_query("abc-123"), "abc-123");
        assert_eq!(url_query("a b/c+d"), "a%20b%2Fc%2Bd");
    }
}
