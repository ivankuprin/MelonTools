//! The account vault. The file format matches the macOS app
//! (`%APPDATA%\MelonTools\codex\accounts.json`) so vaults can be copied
//! between platforms. Windows stores token strings DPAPI-protected
//! (`dpapi2:<base64>`, see `dpapi.rs`); other readers see them as opaque
//! values. Writes go through `serde_json::Value` edits to keep every unknown
//! field of the original file intact.

use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::PathBuf;

use crate::{dpapi, paths};

/// Apple reference date (2001-01-01) offset: file dates are stored the way
/// Swift's JSONEncoder writes `Date` values.
pub const APPLE_REF_UNIX_OFFSET: f64 = 978_307_200.0;

pub fn now_ref() -> f64 {
    unix_now() - APPLE_REF_UNIX_OFFSET
}

pub fn unix_now() -> f64 {
    chrono::Utc::now().timestamp_millis() as f64 / 1000.0
}

#[derive(Serialize, Deserialize, Clone, Default, Debug)]
#[serde(default)]
pub struct Tokens {
    pub id_token: Option<String>,
    pub access_token: Option<String>,
    pub refresh_token: Option<String>,
    pub account_id: Option<String>,
}

impl Tokens {
    pub fn access_expiry_unix(&self) -> Option<f64> {
        let payload = jwt_payload(self.access_token.as_deref()?)?;
        payload.get("exp")?.as_f64()
    }

    pub fn needs_refresh(&self) -> bool {
        match self.access_expiry_unix() {
            Some(exp) => exp - unix_now() < 300.0,
            None => true,
        }
    }
}

#[derive(Serialize, Deserialize, Clone, Default, Debug)]
#[serde(rename_all = "camelCase", default)]
pub struct Quota {
    pub hourly_remaining_percent: Option<f64>,
    pub weekly_remaining_percent: Option<f64>,
    pub hourly_reset_at: Option<f64>,
    pub weekly_reset_at: Option<f64>,
    pub hourly_window_present: Option<bool>,
    pub weekly_window_present: Option<bool>,
    pub hourly_window_minutes: Option<f64>,
    pub weekly_window_minutes: Option<f64>,
}

#[derive(Serialize, Deserialize, Clone, Default, Debug)]
#[serde(rename_all = "camelCase", default)]
pub struct Account {
    pub id: String,
    pub email: Option<String>,
    pub plan_type: Option<String>,
    pub account_id: Option<String>,
    pub user_id: Option<String>,
    pub subscription_active_until: Option<String>,
    pub subscription_updated_at: Option<f64>,
    pub tokens: Tokens,
    pub last_refresh: Option<String>,
    pub quota: Option<Quota>,
    pub quota_updated_at: Option<f64>,
    pub quota_error: Option<String>,
    pub hourly_reserve_percent: Option<i64>,
    pub weekly_reserve_percent: Option<i64>,
    pub preferred_first: Option<bool>,
    pub is_backup: Option<bool>,
    /// Set when a stored token could not be decrypted; the account must be
    /// re-added (the tokens are cleared instead of passed through).
    pub needs_relogin: Option<bool>,
}

impl Account {
    pub fn display_name(&self) -> String {
        self.email.clone().unwrap_or_else(|| {
            self.id.chars().take(8).collect()
        })
    }

    /// Reason this account is paused by the routing planner, if any.
    /// Quota readings older than 30 minutes never block.
    pub fn block_info(&self) -> Option<Value> {
        let quota = self.quota.as_ref()?;
        let updated = self.quota_updated_at?;
        if now_ref() - updated >= 1800.0 {
            return None;
        }
        if let Some(r) = quota.hourly_remaining_percent {
            if r <= 0.0 {
                return Some(json!({"code": "hourly_exhausted"}));
            }
        }
        if let Some(r) = quota.weekly_remaining_percent {
            if r <= 0.0 {
                return Some(json!({"code": "weekly_exhausted"}));
            }
        }
        if let Some(limit) = self.hourly_reserve_percent {
            if limit > 0 {
                if let Some(r) = quota.hourly_remaining_percent {
                    if r <= limit as f64 {
                        return Some(json!({"code": "hourly_reserve", "remaining": r, "limit": limit}));
                    }
                }
            }
        }
        if let Some(limit) = self.weekly_reserve_percent {
            if limit > 0 {
                if let Some(r) = quota.weekly_remaining_percent {
                    if r <= limit as f64 {
                        return Some(json!({"code": "weekly_reserve", "remaining": r, "limit": limit}));
                    }
                }
            }
        }
        None
    }

    pub fn is_blocked(&self) -> bool {
        self.block_info().is_some()
    }
}

// MARK: - File access

pub fn vault_file() -> PathBuf {
    paths::vault_path()
}

/// The token fields encrypted at rest in `codex/accounts.json`.
const SECRET_TOKEN_KEYS: [&str; 3] = ["id_token", "access_token", "refresh_token"];

/// Encrypt every account token in the raw JSON before writing the file.
/// Missing keys, nulls and empty strings are left untouched.
pub fn protect_tokens(value: &mut Value) -> Result<(), String> {
    let Some(accounts) = value.get_mut("accounts").and_then(|a| a.as_array_mut()) else {
        return Ok(());
    };
    for account in accounts {
        let Some(tokens) = account.get_mut("tokens").and_then(|t| t.as_object_mut()) else {
            continue;
        };
        for key in SECRET_TOKEN_KEYS {
            let Some(Value::String(secret)) = tokens.get_mut(key) else {
                continue;
            };
            *secret = dpapi::protect(secret.as_str())?;
        }
    }
    Ok(())
}

/// Decrypt every account token after reading the file. Legacy plaintext
/// passes through. A token that cannot be decoded/decrypted is cleared (never
/// used as ciphertext) and the account is marked for re-login.
pub fn unprotect_tokens(value: &mut Value) {
    let Some(accounts) = value.get_mut("accounts").and_then(|a| a.as_array_mut()) else {
        return;
    };
    for account in accounts {
        let mut needs_relogin = false;
        {
            if let Some(tokens) = account.get_mut("tokens").and_then(|t| t.as_object_mut()) {
                for key in SECRET_TOKEN_KEYS {
                    let failed = match tokens.get_mut(key) {
                        Some(Value::String(secret)) => match dpapi::unprotect(secret.as_str()) {
                            Ok(plaintext) => {
                                *secret = plaintext;
                                false
                            }
                            Err(_) => true,
                        },
                        _ => false,
                    };
                    if failed {
                        tokens.insert(key.to_string(), Value::Null);
                        needs_relogin = true;
                    }
                }
            }
        }
        if needs_relogin {
            if let Some(object) = account.as_object_mut() {
                object.insert("needsRelogin".to_string(), json!(true));
                object.insert("quotaError".to_string(), json!("Re-login required"));
            }
        }
    }
}

pub fn load_raw() -> Value {
    let path = vault_file();
    let raw = std::fs::read_to_string(&path).ok();
    let mut value = raw
        .as_deref()
        .and_then(|text| serde_json::from_str::<Value>(text).ok())
        .unwrap_or_else(|| {
            if raw.as_deref().map(|text| !text.trim().is_empty()).unwrap_or(false) {
                let _ = paths::quarantine(&path);
            }
            json!({"accounts": [], "currentAccountId": Value::Null})
        });
    unprotect_tokens(&mut value);
    value
}

pub fn save_raw(value: &Value) -> Result<(), String> {
    // Vault tokens are encrypted on disk only; callers keep plaintext values
    // in memory (the gateway config and Codex auth files need them).
    let mut stored = value.clone();
    protect_tokens(&mut stored)?;
    let path = vault_file();
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let data = serde_json::to_string_pretty(&stored).map_err(|e| e.to_string())?;
    let tmp = paths::tmp_path(&path);
    std::fs::write(&tmp, data).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, &path).map_err(|e| e.to_string())
}

pub fn accounts() -> Vec<Account> {
    let raw = load_raw();
    raw.get("accounts")
        .and_then(|a| a.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|v| serde_json::from_value::<Account>(v.clone()).ok())
                .collect()
        })
        .unwrap_or_default()
}

/// Views for the UI: quotas converted to Unix seconds, block info resolved.
/// Extra quota keys written by the fetchers (reset credits, model
/// availability) are read from the raw JSON so nothing is dropped.
pub fn list_views() -> Vec<Value> {
    let raw = load_raw();
    let empty = Vec::new();
    let items = raw
        .get("accounts")
        .and_then(|a| a.as_array())
        .unwrap_or(&empty);
    let mut views = Vec::new();
    for item in items {
        let Ok(account) = serde_json::from_value::<Account>(item.clone()) else {
            continue;
        };
        let quota_raw = item.get("quota").cloned().unwrap_or_else(|| json!({}));
        let reset_available = quota_raw
            .get("resetCreditsAvailable")
            .cloned()
            .unwrap_or(Value::Null);
        let reset_expiry = quota_raw
            .get("resetCreditsNextExpiry")
            .and_then(|v| v.as_f64())
            .map(|v| v + APPLE_REF_UNIX_OFFSET);
        let models = quota_raw
            .get("modelAvailability")
            .cloned()
            .unwrap_or_else(|| json!([]));
        let quota = account.quota.clone().unwrap_or_default();
        views.push(json!({
            "id": account.id,
            "email": account.email,
            "displayName": account.display_name(),
            "planType": account.plan_type,
            "subscriptionActiveUntil": account.subscription_active_until,
            "blocked": account.is_blocked(),
            "blockInfo": account.block_info(),
            "hourlyRemaining": quota.hourly_remaining_percent,
            "weeklyRemaining": quota.weekly_remaining_percent,
            "hourlyResetAt": quota.hourly_reset_at.map(|v| v + APPLE_REF_UNIX_OFFSET),
            "weeklyResetAt": quota.weekly_reset_at.map(|v| v + APPLE_REF_UNIX_OFFSET),
            "hourlyWindowPresent": quota.hourly_window_present.unwrap_or(false),
            "weeklyWindowPresent": quota.weekly_window_present.unwrap_or(false),
            "quotaUpdatedAt": account.quota_updated_at.map(|v| v + APPLE_REF_UNIX_OFFSET),
            "quotaError": account.quota_error,
            "hourlyReservePercent": account.hourly_reserve_percent,
            "weeklyReservePercent": account.weekly_reserve_percent,
            "preferredFirst": account.preferred_first.unwrap_or(false),
            "isBackup": account.is_backup.unwrap_or(false),
            "needsRelogin": account.needs_relogin.unwrap_or(false),
            "hasTokens": account.tokens.access_token.as_deref().map(|t| !t.is_empty()).unwrap_or(false),
            "resetCreditsAvailable": reset_available,
            "resetCreditsNextExpiry": reset_expiry,
            "modelAvailability": models,
        }));
    }
    views
}

pub fn set_account_field(id: &str, mutate: impl FnOnce(&mut Value)) -> Result<(), String> {
    let mut raw = load_raw();
    if let Some(arr) = raw.get_mut("accounts").and_then(|a| a.as_array_mut()) {
        for item in arr.iter_mut() {
            if item.get("id").and_then(|v| v.as_str()) == Some(id) {
                mutate(item);
                return save_raw(&raw);
            }
        }
    }
    Err(format!("account not found: {}", id))
}

pub fn update_tokens(id: &str, tokens: &Tokens, last_refresh: &str) -> Result<(), String> {
    let tokens_value = serde_json::to_value(tokens).map_err(|e| e.to_string())?;
    set_account_field(id, move |item| {
        item["tokens"] = tokens_value;
        item["lastRefresh"] = json!(last_refresh);
        clear_relogin(item);
    })
}

/// A successful token write means the account no longer needs a re-login.
fn clear_relogin(item: &mut Value) {
    let Some(object) = item.as_object_mut() else {
        return;
    };
    object.remove("needsRelogin");
    if object.get("quotaError").and_then(|v| v.as_str()) == Some("Re-login required") {
        object.insert("quotaError".to_string(), Value::Null);
    }
}

pub fn update_quota(id: &str, quota: &Quota, raw_json: &str, extra: Value) -> Result<(), String> {
    set_account_field(id, move |item| {
        let mut obj = item
            .get("quota")
            .cloned()
            .unwrap_or_else(|| json!({}));
        obj["hourlyRemainingPercent"] = json!(quota.hourly_remaining_percent);
        obj["weeklyRemainingPercent"] = json!(quota.weekly_remaining_percent);
        obj["hourlyResetAt"] = json!(quota.hourly_reset_at);
        obj["weeklyResetAt"] = json!(quota.weekly_reset_at);
        obj["hourlyWindowPresent"] = json!(quota.hourly_window_present);
        obj["weeklyWindowPresent"] = json!(quota.weekly_window_present);
        obj["hourlyWindowMinutes"] = json!(quota.hourly_window_minutes);
        obj["weeklyWindowMinutes"] = json!(quota.weekly_window_minutes);
        obj["fetchedAt"] = json!(now_ref());
        obj["rawJSON"] = json!(raw_json);
        // Reset credits, model availability and anything else the fetchers
        // produced merge into the same object.
        if let (Some(target), Some(source)) = (obj.as_object_mut(), extra.as_object()) {
            for (key, value) in source {
                target.insert(key.clone(), value.clone());
            }
        }
        item["quota"] = obj;
        item["quotaUpdatedAt"] = json!(now_ref());
        item["quotaError"] = Value::Null;
    })
}

/// Subscription dates / plan discovered from the backend.
pub fn update_subscription(id: &str, plan: Option<&str>, until: Option<&str>) -> Result<(), String> {
    let plan = plan.map(String::from);
    let until = until.map(String::from);
    set_account_field(id, move |item| {
        if let Some(plan) = &plan {
            if !plan.is_empty() {
                item["planType"] = json!(plan);
            }
        }
        if let Some(until) = &until {
            if !until.is_empty() {
                item["subscriptionActiveUntil"] = json!(until);
            }
        }
        item["subscriptionUpdatedAt"] = json!(now_ref());
    })
}

pub fn set_quota_error(id: &str, error: &str) -> Result<(), String> {
    set_account_field(id, move |item| apply_quota_error(item, error))
}

/// A re-login requirement is the actionable reason: quota polling must not
/// overwrite it while `needsRelogin` is set.
fn apply_quota_error(item: &mut Value, error: &str) {
    let needs_relogin = item
        .get("needsRelogin")
        .and_then(|value| value.as_bool())
        .unwrap_or(false);
    item["quotaError"] = json!(if needs_relogin {
        "Re-login required"
    } else {
        error
    });
}

pub fn delete_account(id: &str) -> Result<(), String> {
    let mut raw = load_raw();
    if let Some(arr) = raw.get_mut("accounts").and_then(|a| a.as_array_mut()) {
        arr.retain(|item| item.get("id").and_then(|v| v.as_str()) != Some(id));
    }
    save_raw(&raw)
}

pub fn upsert_from_tokens(tokens: &Tokens) -> Result<String, String> {
    let claims = jwt_claims(tokens.id_token.as_deref());
    let account_id = claims.account_id.clone().or(tokens.account_id.clone());
    let mut raw = load_raw();

    let existing_index = raw
        .get("accounts")
        .and_then(|a| a.as_array())
        .map(|arr| {
            arr.iter().position(|item| {
                let item_account = item.get("accountId").and_then(|v| v.as_str());
                let item_email = item.get("email").and_then(|v| v.as_str());
                (item_account.is_some() && item_account == account_id.as_deref())
                    || (item_email.is_some() && item_email == claims.email.as_deref())
            })
        })
        .flatten();

    let tokens_value = serde_json::to_value(tokens).map_err(|e| e.to_string())?;
    let now = chrono::Utc::now().to_rfc3339();

    if let Some(index) = existing_index {
        if let Some(arr) = raw.get_mut("accounts").and_then(|a| a.as_array_mut()) {
            let item = &mut arr[index];
            item["tokens"] = tokens_value;
            item["lastRefresh"] = json!(now);
            if let Some(email) = &claims.email {
                item["email"] = json!(email);
            }
            if let Some(plan) = &claims.plan_type {
                item["planType"] = json!(plan);
            }
            if let Some(value) = &account_id {
                item["accountId"] = json!(value);
            }
            clear_relogin(item);
        }
        save_raw(&raw)?;
        return Ok("updated".to_string());
    }

    let id = uuid_like();
    let entry = json!({
        "id": id,
        "email": claims.email,
        "planType": claims.plan_type,
        "accountId": account_id,
        "userId": claims.user_id,
        "subscriptionActiveUntil": claims.subscription_until,
        "tokens": tokens_value,
        "lastRefresh": now,
        "addedAt": now_ref(),
    });
    if let Some(arr) = raw.get_mut("accounts").and_then(|a| a.as_array_mut()) {
        arr.push(entry);
    }
    save_raw(&raw)?;
    Ok("added".to_string())
}

// MARK: - The Codex app auth file (full shape, the macOS 1.4.5 fix)

/// The Codex app resolves its ChatGPT account from this file: `auth_mode` and
/// `tokens.account_id` must be present, otherwise Codex blocks chatting with
/// "failed to load workspace settings".
pub fn write_codex_auth(account: &Account) -> Result<PathBuf, String> {
    let path = paths::codex_auth_path();
    write_codex_auth_to(&path, account)?;
    Ok(path)
}

/// Same file shape, at an arbitrary path (instances have their own CODEX_HOME).
pub fn write_codex_auth_to(path: &std::path::Path, account: &Account) -> Result<(), String> {
    let mut tokens = account.tokens.clone();
    if tokens.account_id.as_deref().unwrap_or("").is_empty() {
        let claims = jwt_claims(tokens.id_token.as_deref());
        tokens.account_id = account.account_id.clone().or(claims.account_id);
    }
    let payload = json!({
        "OPENAI_API_KEY": Value::Null,
        "auth_mode": "chatgpt",
        "last_refresh": chrono::Utc::now().to_rfc3339(),
        "tokens": {
            "access_token": tokens.access_token,
            "account_id": tokens.account_id,
            "id_token": tokens.id_token,
            "refresh_token": tokens.refresh_token,
        }
    });
    let backup = path.with_extension("json.melon-backup");
    if path.exists() {
        let _ = std::fs::remove_file(&backup);
        let _ = std::fs::copy(path, &backup);
    }
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    // Atomic replace keeps a crash from truncating the login file.
    let data = serde_json::to_string_pretty(&payload).map_err(|e| e.to_string())?;
    let tmp = crate::paths::tmp_path(path);
    std::fs::write(&tmp, data).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, path).map_err(|e| e.to_string())
}

pub fn read_codex_auth_tokens() -> Option<Tokens> {
    let raw = std::fs::read_to_string(paths::codex_auth_path()).ok()?;
    let value: Value = serde_json::from_str(&raw).ok()?;
    serde_json::from_value(value.get("tokens")?.clone()).ok()
}

// MARK: - JWT

pub struct Claims {
    pub email: Option<String>,
    pub account_id: Option<String>,
    pub user_id: Option<String>,
    pub plan_type: Option<String>,
    pub subscription_until: Option<String>,
}

pub fn jwt_payload(token: &str) -> Option<Value> {
    let parts: Vec<&str> = token.split('.').collect();
    if parts.len() < 2 {
        return None;
    }
    let engine = base64::engine::general_purpose::URL_SAFE_NO_PAD;
    let bytes = engine.decode(parts[1]).ok()?;
    serde_json::from_slice::<Value>(&bytes).ok()
}

pub fn jwt_claims(id_token: Option<&str>) -> Claims {
    let mut claims = Claims {
        email: None,
        account_id: None,
        user_id: None,
        plan_type: None,
        subscription_until: None,
    };
    let Some(payload) = id_token.and_then(jwt_payload) else {
        return claims;
    };
    claims.email = payload
        .get("email")
        .and_then(|v| v.as_str())
        .map(String::from);
    if let Some(auth) = payload.get("https://api.openai.com/auth") {
        claims.account_id = auth
            .get("chatgpt_account_id")
            .and_then(|v| v.as_str())
            .map(String::from);
        claims.user_id = auth
            .get("chatgpt_user_id")
            .and_then(|v| v.as_str())
            .map(String::from);
        claims.plan_type = auth
            .get("chatgpt_plan_type")
            .and_then(|v| v.as_str())
            .map(String::from);
        claims.subscription_until = auth
            .get("chatgpt_subscription_active_until")
            .and_then(|v| v.as_str())
            .map(String::from);
    }
    claims
}

fn uuid_like() -> String {
    let bytes: [u8; 16] = rand::random();
    let hex: String = bytes.iter().map(|b| format!("{:02X}", b)).collect();
    format!(
        "{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    )
}

#[cfg(test)]
mod tests {
    use super::{protect_tokens, unprotect_tokens};
    use serde_json::{json, Value};

    fn vault_with_tokens() -> Value {
        json!({
            "accounts": [{
                "id": "acc-1",
                "email": "user@example.com",
                "tokens": {
                    "id_token": "id-secret",
                    "access_token": "access-secret",
                    "refresh_token": "refresh-secret",
                    "account_id": "chatgpt-account",
                },
                "quota": {"hourlyRemainingPercent": 42.0},
            }],
            "currentAccountId": "acc-1",
        })
    }

    #[test]
    fn token_protection_roundtrip_preserves_secrets() {
        let mut raw = vault_with_tokens();
        protect_tokens(&mut raw).unwrap();

        #[cfg(windows)]
        {
            let tokens = &raw["accounts"][0]["tokens"];
            for key in super::SECRET_TOKEN_KEYS {
                let stored = tokens[key].as_str().expect("token stays a string");
                assert!(crate::dpapi::is_protected(stored), "{key} not protected");
            }
            assert_eq!(tokens["account_id"], "chatgpt-account");
        }
        #[cfg(not(windows))]
        {
            // Host fallback keeps plaintext, exactly like the first save on a
            // platform without DPAPI.
            assert_eq!(raw["accounts"][0]["tokens"]["access_token"], "access-secret");
        }

        unprotect_tokens(&mut raw);
        let tokens = &raw["accounts"][0]["tokens"];
        assert_eq!(tokens["id_token"], "id-secret");
        assert_eq!(tokens["access_token"], "access-secret");
        assert_eq!(tokens["refresh_token"], "refresh-secret");
        assert_eq!(tokens["account_id"], "chatgpt-account");
        assert_eq!(raw["accounts"][0]["email"], "user@example.com");
        assert_eq!(raw["accounts"][0]["quota"]["hourlyRemainingPercent"], 42.0);
        assert_eq!(raw["currentAccountId"], "acc-1");
    }

    #[test]
    fn legacy_plaintext_vault_is_read_unchanged() {
        let mut raw = vault_with_tokens();
        unprotect_tokens(&mut raw);
        assert_eq!(raw["accounts"][0]["tokens"]["access_token"], "access-secret");
        assert_eq!(raw["accounts"][0]["tokens"]["refresh_token"], "refresh-secret");
        assert!(raw["accounts"][0].get("needsRelogin").is_none());
    }

    #[test]
    fn undecryptable_tokens_are_cleared_and_account_marked() {
        let mut raw = json!({
            "accounts": [{
                "id": "acc-1",
                "tokens": {
                    "id_token": "dpapi2:AAAA",
                    "access_token": "access-legacy",
                    "refresh_token": "dpapi:not-base64!!!",
                }
            }]
        });
        unprotect_tokens(&mut raw);
        let account = &raw["accounts"][0];
        assert!(account["tokens"]["id_token"].is_null());
        assert!(account["tokens"]["refresh_token"].is_null());
        assert_eq!(account["tokens"]["access_token"], "access-legacy");
        assert_eq!(account["needsRelogin"], true);
        assert_eq!(account["quotaError"], "Re-login required");
    }

    #[test]
    fn relogin_marker_survives_the_next_save() {
        let mut raw = json!({
            "accounts": [{
                "id": "acc-1",
                "tokens": {"access_token": "dpapi2:AAAA"}
            }]
        });
        unprotect_tokens(&mut raw);
        protect_tokens(&mut raw).unwrap();
        let account = &raw["accounts"][0];
        assert!(account["tokens"]["access_token"].is_null());
        assert_eq!(account["needsRelogin"], true);
        assert_eq!(account["quotaError"], "Re-login required");
    }

    #[test]
    fn reserved_token_prefixes_roundtrip() {
        let mut raw = json!({
            "accounts": [{
                "id": "acc-1",
                "tokens": {
                    "access_token": "dpapi:literal",
                    "refresh_token": "plain:literal",
                }
            }]
        });
        protect_tokens(&mut raw).unwrap();
        let stored = raw["accounts"][0]["tokens"]["access_token"]
            .as_str()
            .unwrap();
        assert!(
            stored.starts_with(crate::dpapi::PREFIX_PLAIN)
                || stored.starts_with(crate::dpapi::PREFIX_V2),
            "reserved token was stored raw: {stored}"
        );
        unprotect_tokens(&mut raw);
        assert_eq!(raw["accounts"][0]["tokens"]["access_token"], "dpapi:literal");
        assert_eq!(raw["accounts"][0]["tokens"]["refresh_token"], "plain:literal");
        assert!(raw["accounts"][0].get("needsRelogin").is_none());
    }

    #[test]
    fn empty_and_missing_token_fields_are_untouched() {
        let mut raw = json!({
            "accounts": [
                {"id": "a", "tokens": {"access_token": "", "refresh_token": null}},
                {"id": "b"},
                {"id": "c", "tokens": {}},
            ],
            "currentAccountId": Value::Null,
        });
        let before = raw.clone();
        protect_tokens(&mut raw).unwrap();
        assert_eq!(raw, before);
        unprotect_tokens(&mut raw);
        assert_eq!(raw, before);
    }

    #[test]
    fn non_account_shapes_are_ignored() {
        for mut raw in [json!({}), json!({"accounts": "nope"}), json!({"accounts": []})] {
            let before = raw.clone();
            protect_tokens(&mut raw).unwrap();
            unprotect_tokens(&mut raw);
            assert_eq!(raw, before);
        }
    }

    #[test]
    fn successful_token_write_clears_the_relogin_marker() {
        let mut item = json!({
            "tokens": {},
            "needsRelogin": true,
            "quotaError": "Re-login required",
        });
        super::clear_relogin(&mut item);
        assert!(item.get("needsRelogin").is_none());
        assert!(item["quotaError"].is_null());

        let mut unrelated = json!({"quotaError": "quota fetch failed"});
        super::clear_relogin(&mut unrelated);
        assert_eq!(unrelated["quotaError"], "quota fetch failed");
    }

    #[test]
    fn quota_errors_do_not_hide_the_relogin_reason() {
        let mut marked = json!({
            "needsRelogin": true,
            "quotaError": "Re-login required",
        });
        super::apply_quota_error(&mut marked, "HTTP 401");
        assert_eq!(marked["quotaError"], "Re-login required");

        let mut normal = json!({"needsRelogin": false});
        super::apply_quota_error(&mut normal, "HTTP 500");
        assert_eq!(normal["quotaError"], "HTTP 500");
    }
}
