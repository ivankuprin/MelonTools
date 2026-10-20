//! Antigravity (Google account OAuth) provider: engine-managed login,
//! credential listing/refresh, the model list and the auth-file helpers used
//! by the Providers card.
//!
//! The engine (CLIProxyAPI) runs the OAuth flow and stores the account as
//! `antigravity.json` or `antigravity-<email>.json` in the gateway auth dir,
//! where it hot-reloads it. There is no quota endpoint for Antigravity, so the
//! app only reports identity and the number of models the gateway serves —
//! never percentages.
//!
//! Model ownership is read from the `/v1/models` entry (`owned_by`/`type`);
//! when the response carries no ownership field the engine registry's
//! Antigravity id list is the documented fallback.

use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::paths;
use crate::settings::Settings;

/// Antigravity ids from the engine registry. Used only when `/v1/models`
/// carries no ownership field.
pub const ANTIGRAVITY_MODEL_IDS: &[&str] = &[
    "claude-opus-4-6-thinking",
    "claude-sonnet-4-6",
    "claude-opus-5-5-high",
    "claude-sonnet-5-5-high",
    "gemini-4-argon-high",
    "gemini-3.8-flash-high",
    "gemini-3-flash",
    "gemini-3.1-flash-image",
    "gpt-oss-120b-medium",
    "gemini-3.1-flash-lite",
    "gemini-3.5-flash-lite",
];

// MARK: - Auth files

/// `antigravity.json` or `antigravity-<email>.json`. Everything else — above
/// all `codex-*.json` and `claude-*.json` — is owned by another provider.
pub fn is_antigravity_auth_file_name(name: &str) -> bool {
    name == "antigravity.json" || (name.starts_with("antigravity-") && name.ends_with(".json"))
}

pub fn is_antigravity_model_id(id: &str) -> bool {
    ANTIGRAVITY_MODEL_IDS
        .iter()
        .any(|candidate| candidate.eq_ignore_ascii_case(id))
}

#[derive(Debug, Clone, PartialEq)]
pub struct AuthFile {
    pub name: String,
    pub path: PathBuf,
    pub email: Option<String>,
    pub project_id: Option<String>,
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
        if kind != "antigravity" {
            return None;
        }
    }
    let project_id = ["project_id", "projectId"]
        .iter()
        .find_map(|key| root.get(key).and_then(|v| v.as_str()))
        .filter(|value| !value.is_empty())
        .map(String::from);
    Some(AuthFile {
        name: name.to_string(),
        path: path.to_path_buf(),
        email: root.get("email").and_then(|v| v.as_str()).map(String::from),
        project_id,
        access_token: root
            .get("access_token")
            .and_then(|v| v.as_str())
            .map(String::from),
        modified: None,
    })
}

/// Every Antigravity auth file in `dir`, sorted by name (stable first
/// account).
pub fn auth_files_in(dir: &Path) -> Vec<AuthFile> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut files: Vec<AuthFile> = Vec::new();
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().to_string();
        if !is_antigravity_auth_file_name(&name) {
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

/// Removes only Antigravity auth files from `dir`; returns
/// `(removed, remaining_antigravity_files)`.
pub fn disconnect_in(dir: &Path) -> (usize, usize) {
    let mut removed = 0usize;
    for file in auth_files_in(dir) {
        if std::fs::remove_file(&file.path).is_ok() {
            removed += 1;
        }
    }
    (removed, auth_files_in(dir).len())
}

// MARK: - Model ownership

fn ownership_text<'a>(entry: &'a Value, key: &str) -> Option<&'a str> {
    entry
        .get(key)
        .and_then(|value| value.as_str())
        .map(str::trim)
        .filter(|value| !value.is_empty())
}

/// Whether a `/v1/models` entry is served by Antigravity. `owned_by` and
/// `type` are both checked because engine versions spell the marker
/// differently. When neither field is present the registry id allowlist is
/// the fallback.
pub fn is_antigravity_model_entry(entry: &Value) -> bool {
    let mut saw_ownership = false;
    for key in ["owned_by", "owner", "type"] {
        if let Some(owner) = ownership_text(entry, key) {
            saw_ownership = true;
            if owner.eq_ignore_ascii_case("antigravity") {
                return true;
            }
        }
    }
    if saw_ownership {
        return false;
    }
    entry
        .get("id")
        .and_then(|value| value.as_str())
        .map(is_antigravity_model_id)
        .unwrap_or(false)
}

fn display_name(entry: &Value, id: &str) -> String {
    ["display_name", "displayName", "name"]
        .iter()
        .find_map(|key| ownership_text(entry, key))
        .map(String::from)
        .unwrap_or_else(|| crate::codex_route::prettify(id))
}

fn model_entries<F>(root: &Value, include: F) -> Vec<Value>
where
    F: Fn(&Value, &str) -> bool,
{
    root.get("data")
        .and_then(|value| value.as_array())
        .map(|items| {
            items
                .iter()
                .filter_map(|item| {
                    let id = item.get("id").and_then(|value| value.as_str())?;
                    if !include(item, id) {
                        return None;
                    }
                    Some(json!({ "id": id, "displayName": display_name(item, id) }))
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Antigravity-owned entries of a `/v1/models` payload.
pub fn parse_models(root: &Value) -> Vec<Value> {
    model_entries(root, |entry, _id| is_antigravity_model_entry(entry))
}

/// Claude entries of a `/v1/models` payload, excluding ids the engine marks as
/// Antigravity-owned. Antigravity also serves `claude-*` ids, so the plain
/// prefix filter is not enough.
pub fn parse_claude_models(root: &Value) -> Vec<Value> {
    model_entries(root, |entry, id| {
        crate::claude::is_claude_model_id(id) && !is_antigravity_model_entry(entry)
    })
}

async fn fetch_models(port: u16, api_key: &str) -> Result<Value, String> {
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
    response.json().await.map_err(|e| e.to_string())
}

/// Antigravity model ids served by the running gateway.
pub async fn models(port: u16, api_key: &str) -> Result<Value, String> {
    let root = fetch_models(port, api_key).await?;
    let entries = parse_models(&root);
    Ok(json!({ "models": entries.clone(), "count": entries.len() }))
}

/// Claude model ids served by the gateway, with Antigravity-owned ids removed.
/// Replaces `claude::models` for the app's listing and metrics so the Claude
/// provider never claims Antigravity's Claude models.
pub async fn claude_models_without_antigravity(
    port: u16,
    api_key: &str,
) -> Result<Value, String> {
    let root = fetch_models(port, api_key).await?;
    let entries = parse_claude_models(&root);
    Ok(json!({ "models": entries.clone(), "count": entries.len() }))
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

    /// `GET /v8/management/oauth/auth-url?provider=antigravity&is_webui=true`.
    /// `is_webui=true` is required: it starts the engine callback forwarder
    /// on port 51121 that receives the Google redirect.
    pub async fn login_start(&self) -> Result<Value, String> {
        let (status, text) = self
            .call(
                reqwest::Method::GET,
                "/v8/management/oauth/auth-url?provider=antigravity&is_webui=true",
                None,
            )
            .await
            .map_err(|_| "шлюз не отвечает — запустите его и повторите".to_string())?;
        let body = Self::body_json(&text);
        if status != 200 {
            return Err(format!("шлюз отклонил вход ({})", status));
        }
        let (url, state) = crate::claude::parse_auth_url(&body)
            .ok_or_else(|| "шлюз не вернул ссылку входа".to_string())?;
        Ok(json!({ "url": url, "state": state }))
    }

    /// `GET /v8/management/oauth/status?state=…` → `ok` | `wait` | `error`.
    pub async fn login_status(&self, state: &str) -> Result<Value, String> {
        let (status, text) = self
            .call(
                reqwest::Method::GET,
                &format!(
                    "/v8/management/oauth/status?state={}",
                    crate::claude::url_query(state)
                ),
                None,
            )
            .await?;
        if status != 200 {
            return Err(format!("шлюз отклонил запрос статуса ({})", status));
        }
        let value = Self::body_json(&text);
        let state_name = crate::claude::parse_status(&value)
            .ok_or_else(|| "шлюз не вернул статус входа".to_string())?;
        Ok(json!({ "status": state_name }))
    }

    /// `DELETE /v8/management/oauth/session?state=…` — drops a pending login.
    pub async fn login_cancel(&self, state: &str) -> Result<Value, String> {
        let (status, _) = self
            .call(
                reqwest::Method::DELETE,
                &format!(
                    "/v8/management/oauth/session?state={}",
                    crate::claude::url_query(state)
                ),
                None,
            )
            .await?;
        Ok(json!({ "canceled": (200..300).contains(&status) }))
    }

    /// `GET /v8/management/credentials`, filtered to Antigravity accounts.
    pub async fn credentials(&self) -> Result<Value, String> {
        let (status, text) = self
            .call(reqwest::Method::GET, "/v8/management/credentials", None)
            .await?;
        if status != 200 {
            return Ok(json!({ "credentials": [] }));
        }
        let parsed = crate::claude::parse_credentials(&Self::body_json(&text));
        Ok(json!({ "credentials": filter_credentials(parsed) }))
    }

    /// Refreshes one credential file (`{"name": …}`) or all of them
    /// (`?all=true`) when no name is given. Failures are reported as
    /// `ok: false` — a refresh must not break the card.
    pub async fn refresh(&self, name: Option<&str>) -> Value {
        let (path, body) = match name.filter(|n| !n.is_empty()) {
            Some(name) => (
                "/v8/management/credentials/refresh".to_string(),
                Some(json!({ "name": name })),
            ),
            None => ("/v8/management/credentials/refresh?all=true".to_string(), None),
        };
        match self.call(reqwest::Method::POST, &path, body).await {
            Ok((status, _)) => json!({ "ok": (200..300).contains(&status) }),
            Err(_) => json!({ "ok": false }),
        }
    }
}

/// Keeps only credential entries that belong to Antigravity: the engine may
/// omit `type`, so the file-name predicate is checked as well.
pub fn filter_credentials(entries: Vec<Value>) -> Vec<Value> {
    entries
        .into_iter()
        .filter(|entry| {
            let by_type = entry
                .get("type")
                .and_then(|value| value.as_str())
                .map(|value| value.eq_ignore_ascii_case("antigravity"))
                .unwrap_or(false);
            let by_name = entry
                .get("name")
                .and_then(|value| value.as_str())
                .map(is_antigravity_auth_file_name)
                .unwrap_or(false);
            by_type || by_name
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::fs;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "melon-antigravity-test-{}-{}",
            std::process::id(),
            tag
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("temp dir");
        dir
    }

    fn fixture_entry(id: &str, owned_by: Option<&str>, kind: Option<&str>) -> Value {
        let mut entry = json!({"id": id, "object": "model"});
        if let Some(owned_by) = owned_by {
            entry["owned_by"] = json!(owned_by);
        }
        if let Some(kind) = kind {
            entry["type"] = json!(kind);
        }
        entry
    }

    #[test]
    fn auth_file_predicates_own_only_antigravity_files() {
        assert!(is_antigravity_auth_file_name("antigravity.json"));
        assert!(is_antigravity_auth_file_name(
            "antigravity-1a2b3c4d-user@example.com.json"
        ));
        assert!(!is_antigravity_auth_file_name("claude-user@example.com.json"));
        assert!(!is_antigravity_auth_file_name("codex-user@example.com.json"));
        assert!(!is_antigravity_auth_file_name(
            "._antigravity-user@example.com.json"
        ));
        assert!(!is_antigravity_auth_file_name("antigravity-user.json.bak"));
        assert!(is_antigravity_model_id("gemini-3-flash"));
        assert!(is_antigravity_model_id("claude-opus-4-6-thinking"));
        assert!(!is_antigravity_model_id("claude-opus-5-5"));
    }

    #[test]
    fn auth_files_in_reads_only_antigravity_files_and_sorts_them() {
        let dir = temp_dir("authfiles");
        fs::write(
            dir.join("claude-user@example.com.json"),
            r#"{"type":"claude","email":"claude@example.com"}"#,
        )
        .unwrap();
        fs::write(
            dir.join("antigravity-zzzz1111-second@example.com.json"),
            r#"{"type":"antigravity","email":"second@example.com","project_id":"project-2","access_token":"token-2"}"#,
        )
        .unwrap();
        fs::write(
            dir.join("antigravity-aaaa0000-first@example.com.json"),
            r#"{"type":"antigravity","email":"first@example.com","projectId":"project-1","access_token":"token-1"}"#,
        )
        .unwrap();
        fs::write(dir.join("notes.txt"), "not an auth file").unwrap();

        let files = auth_files_in(&dir);
        assert_eq!(files.len(), 2);
        assert_eq!(files[0].email.as_deref(), Some("first@example.com"));
        assert_eq!(files[0].project_id.as_deref(), Some("project-1"));
        assert_eq!(files[0].access_token.as_deref(), Some("token-1"));
        assert_eq!(files[1].email.as_deref(), Some("second@example.com"));
        assert_eq!(files[1].project_id.as_deref(), Some("project-2"));

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn decode_auth_file_tolerates_missing_fields_and_rejects_other_types() {
        let path = PathBuf::from("/tmp/antigravity-x.json");
        let decoded =
            decode_auth_file("antigravity.json", &path, r#"{"email":"a@b.c"}"#)
                .expect("no type field is accepted");
        assert_eq!(decoded.email.as_deref(), Some("a@b.c"));
        assert!(decoded.project_id.is_none());
        assert!(decoded.access_token.is_none());
        assert!(
            decode_auth_file("antigravity.json", &path, r#"{"type":"antigravity"}"#).is_some()
        );
        assert!(decode_auth_file("antigravity.json", &path, r#"{"type":"claude"}"#).is_none());
        assert!(decode_auth_file("antigravity.json", &path, "{not json").is_none());
    }

    #[test]
    fn newest_of_picks_the_most_recently_modified_file() {
        let base = std::time::SystemTime::UNIX_EPOCH;
        let older = AuthFile {
            name: "antigravity-aaaa0000-old@example.com.json".to_string(),
            path: PathBuf::from("/x/older.json"),
            email: Some("old@example.com".to_string()),
            project_id: None,
            access_token: None,
            modified: Some(base),
        };
        let newer = AuthFile {
            name: "antigravity-zzzz9999-new@example.com.json".to_string(),
            path: PathBuf::from("/x/newer.json"),
            email: Some("new@example.com".to_string()),
            project_id: Some("project-new".to_string()),
            access_token: None,
            modified: Some(base + Duration::from_secs(60)),
        };
        let picked = newest_of(&[older.clone(), newer.clone()]).unwrap();
        assert_eq!(picked.email.as_deref(), Some("new@example.com"));
        assert_eq!(picked.project_id.as_deref(), Some("project-new"));

        // Without usable timestamps the name decides, deterministically.
        let mut a = older;
        a.modified = None;
        let mut b = newer;
        b.modified = None;
        assert_eq!(
            newest_of(&[a, b]).unwrap().name,
            "antigravity-zzzz9999-new@example.com.json"
        );
        assert!(newest_of(&[]).is_none());
    }

    #[test]
    fn newest_auth_file_in_follows_the_modification_time() {
        let dir = temp_dir("newest");
        let old_path = dir.join("antigravity-aaaa0000-old@example.com.json");
        fs::write(
            &old_path,
            r#"{"type":"antigravity","email":"old@example.com","project_id":"p-old"}"#,
        )
        .unwrap();
        let new_path = dir.join("antigravity-zzzz9999-new@example.com.json");
        fs::write(
            &new_path,
            r#"{"type":"antigravity","email":"new@example.com","project_id":"p-new"}"#,
        )
        .unwrap();

        // Set explicit timestamps so the ordering does not depend on the
        // filesystem's timestamp resolution.
        let old_time = std::time::SystemTime::UNIX_EPOCH + Duration::from_secs(1_600_000_000);
        let new_time = old_time + Duration::from_secs(60);
        fs::File::options()
            .write(true)
            .open(&old_path)
            .unwrap()
            .set_modified(old_time)
            .unwrap();
        fs::File::options()
            .write(true)
            .open(&new_path)
            .unwrap()
            .set_modified(new_time)
            .unwrap();

        let newest = newest_auth_file_in(&dir).expect("an antigravity auth file");
        assert_eq!(newest.email.as_deref(), Some("new@example.com"));
        assert_eq!(newest.project_id.as_deref(), Some("p-new"));
        assert!(newest.modified.is_some());

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn disconnect_removes_only_antigravity_files() {
        let dir = temp_dir("disconnect");
        fs::write(
            dir.join("antigravity-a@example.com.json"),
            r#"{"type":"antigravity","email":"a@example.com"}"#,
        )
        .unwrap();
        fs::write(
            dir.join("antigravity-b@example.com.json"),
            r#"{"type":"antigravity","email":"b@example.com"}"#,
        )
        .unwrap();
        let claude = dir.join("claude-a@example.com.json");
        let codex = dir.join("codex-a@example.com.json");
        fs::write(&claude, r#"{"type":"claude"}"#).unwrap();
        fs::write(&codex, r#"{"type":"codex"}"#).unwrap();

        let (removed, remaining) = disconnect_in(&dir);
        assert_eq!(removed, 2);
        assert_eq!(remaining, 0);
        assert!(claude.exists());
        assert!(codex.exists());

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn model_filter_prefers_ownership_and_falls_back_to_the_allowlist() {
        let root = json!({
            "data": [
                fixture_entry("claude-opus-4-6-thinking", Some("antigravity"), Some("antigravity")),
                fixture_entry("claude-sonnet-4-6", Some("anthropic"), Some("claude")),
                fixture_entry("claude-opus-5-5", Some("anthropic"), Some("claude")),
                fixture_entry("gemini-3-flash", Some("antigravity"), Some("antigravity")),
                // No ownership field: the registry allowlist decides.
                fixture_entry("gemini-3.1-flash-lite", None, None),
                fixture_entry("gpt-6.1-sol", None, None)
            ]
        });

        let antigravity: Vec<String> = parse_models(&root)
            .iter()
            .map(|entry| entry["id"].as_str().unwrap().to_string())
            .collect();
        assert_eq!(
            antigravity,
            vec![
                "claude-opus-4-6-thinking",
                "gemini-3-flash",
                "gemini-3.1-flash-lite"
            ]
        );

        let claude: Vec<String> = parse_claude_models(&root)
            .iter()
            .map(|entry| entry["id"].as_str().unwrap().to_string())
            .collect();
        assert_eq!(claude, vec!["claude-sonnet-4-6", "claude-opus-5-5"]);
    }

    #[test]
    fn model_filter_without_ownership_data_uses_the_allowlist_for_both_views() {
        let root = json!({
            "data": [
                {"id": "claude-opus-4-6-thinking"},
                {"id": "claude-sonnet-4-6"},
                {"id": "claude-opus-5-5"},
                {"id": "gemini-3-flash"}
            ]
        });

        let antigravity: Vec<String> = parse_models(&root)
            .iter()
            .map(|entry| entry["id"].as_str().unwrap().to_string())
            .collect();
        assert_eq!(
            antigravity,
            vec![
                "claude-opus-4-6-thinking",
                "claude-sonnet-4-6",
                "gemini-3-flash"
            ]
        );

        // The overlapping Claude ids must not be claimed by the Claude view
        // when ownership is unavailable.
        let claude: Vec<String> = parse_claude_models(&root)
            .iter()
            .map(|entry| entry["id"].as_str().unwrap().to_string())
            .collect();
        assert_eq!(claude, vec!["claude-opus-5-5"]);
    }

    #[test]
    fn antigravity_model_entries_keep_registry_display_names() {
        let root = json!({
            "data": [
                {
                    "id": "gemini-3.8-flash-high",
                    "owned_by": "antigravity",
                    "display_name": "Gemini 3.8 Flash",
                    "name": "gemini-3.8-flash-high"
                },
                {"id": "gemini-3-flash", "type": "antigravity"}
            ]
        });
        let entries = parse_models(&root);
        assert_eq!(entries[0]["displayName"], "Gemini 3.8 Flash");
        assert_eq!(entries[1]["displayName"], "Gemini 3 Flash");
    }

    #[test]
    fn credentials_filter_keeps_only_antigravity_entries() {
        let entries = vec![
            json!({"name": "antigravity-a@example.com.json", "type": "antigravity"}),
            json!({"name": "claude-a@example.com.json", "type": "claude"}),
            // The engine may omit type; the file name still identifies it.
            json!({"name": "antigravity.json"}),
            json!({"name": "codex-a.json", "type": "codex"}),
        ];
        let filtered = filter_credentials(entries);
        assert_eq!(filtered.len(), 2);
        assert_eq!(filtered[0]["name"], "antigravity-a@example.com.json");
        assert_eq!(filtered[1]["name"], "antigravity.json");
    }
}
