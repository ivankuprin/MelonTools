//! Settings: a small JSON file next to the vault.

use serde::{Deserialize, Serialize};

use crate::{dpapi, paths};

#[derive(Serialize, Deserialize, Clone)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    pub port: u16,
    pub api_key: String,
    pub lang: String,
    pub quota_interval: u32,
    pub openrouter_key: String,
    pub opencode_key: String,
    /// opencode / openrouter upstreams in the gateway config.
    pub opencode_enabled: bool,
    pub openrouter_enabled: bool,
    /// Claude (Anthropic) provider: engine-managed OAuth account and/or the
    /// API-key fallback.
    pub claude_enabled: bool,
    /// Anthropic console API key — the fallback connection method.
    pub claude_api_key: String,
    /// Plaintext secret for the engine management API. The engine hashes it
    /// when it loads the config, so config.yaml carries the plaintext value
    /// and management calls authenticate with it. Generated once, persisted.
    pub management_secret: String,
    /// Routing: auto | quotaHighFirst | quotaLowFirst | planHighFirst |
    /// planLowFirst | expirySoonFirst | custom
    pub routing_strategy: String,
    /// Manual order of account ids (for the custom strategy).
    pub priority_order: Vec<String>,
    /// Master switch for every toast notification.
    pub notifications: bool,
    /// Toast when an hourly/weekly window crosses below its account reserve
    /// (10 % when no reserve is configured).
    pub notify_low_quota: bool,
    /// Toast after an automatic or manual scheduler run.
    pub notify_scheduler: bool,
    /// Toast when a blocked account becomes usable after a refresh.
    pub notify_quota_reset: bool,
    /// Dashboard 2.0 card visibility. Default on.
    pub dashboard_show_pool_health: bool,
    pub dashboard_show_quota_trends: bool,
    pub dashboard_show_spend: bool,
    pub dashboard_show_scheduler: bool,
    /// `<account>:<window>:<reset>` markers for reset notifications. Bounded.
    pub quota_reset_notified: Vec<String>,
    /// Unix seconds of the last update check (auto-check is daily).
    pub last_update_check: Option<i64>,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            port: 18317,
            api_key: String::new(),
            lang: "ru".to_string(),
            quota_interval: 300,
            openrouter_key: String::new(),
            opencode_key: String::new(),
            opencode_enabled: true,
            openrouter_enabled: true,
            claude_enabled: false,
            claude_api_key: String::new(),
            management_secret: String::new(),
            routing_strategy: "auto".to_string(),
            priority_order: Vec::new(),
            notifications: true,
            notify_low_quota: true,
            notify_scheduler: true,
            notify_quota_reset: true,
            dashboard_show_pool_health: true,
            dashboard_show_quota_trends: true,
            dashboard_show_spend: true,
            dashboard_show_scheduler: true,
            quota_reset_notified: Vec::new(),
            last_update_check: None,
        }
    }
}

pub fn load() -> Settings {
    let mut s: Settings = std::fs::read_to_string(paths::settings_path())
        .ok()
        .and_then(|raw| serde_json::from_str(&raw).ok())
        .unwrap_or_default();
    unprotect_secrets(&mut s);
    if s.port == 0 {
        s.port = 18317;
    }
    if s.quota_interval == 0 {
        s.quota_interval = 300;
    }
    if s.lang.is_empty() {
        s.lang = "ru".to_string();
    }
    if s.routing_strategy.is_empty() {
        s.routing_strategy = "auto".to_string();
    }
    if s.api_key.is_empty() {
        s.api_key = generate_api_key();
        let _ = save(&s);
    }
    if s.management_secret.is_empty() {
        s.management_secret = generate_management_secret();
        let _ = save(&s);
    }
    s
}

pub fn save(s: &Settings) -> Result<(), String> {
    // Secrets are encrypted on disk only; the in-memory Settings stays
    // plaintext for the engine config and management calls.
    let mut stored = s.clone();
    protect_secrets(&mut stored)?;
    let dir = paths::appdata_dir();
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let data = serde_json::to_string_pretty(&stored).map_err(|e| e.to_string())?;
    let path = paths::settings_path();
    let tmp = paths::tmp_path(&path);
    std::fs::write(&tmp, data).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, &path).map_err(|e| e.to_string())
}

/// The secrets stored in `settings.json`. Vault tokens use the same helpers.
fn secret_fields(s: &mut Settings) -> [&mut String; 5] {
    [
        &mut s.api_key,
        &mut s.openrouter_key,
        &mut s.opencode_key,
        &mut s.claude_api_key,
        &mut s.management_secret,
    ]
}

fn protect_secrets(s: &mut Settings) -> Result<(), String> {
    for field in secret_fields(s) {
        let protected = dpapi::protect(field.as_str())?;
        *field = protected;
    }
    Ok(())
}

/// Legacy plaintext values pass through unchanged and are encrypted by the
/// next save. An undecryptable value becomes an empty string (treated as
/// unset), never ciphertext that could be used as a key.
fn unprotect_secrets(s: &mut Settings) {
    for field in secret_fields(s) {
        let plaintext = dpapi::unprotect(field.as_str()).unwrap_or_default();
        *field = plaintext;
    }
}

fn generate_api_key() -> String {
    let bytes: [u8; 12] = rand::random();
    let hex: String = bytes.iter().map(|b| format!("{:02X}", b)).collect();
    format!("melon-{}", hex)
}

/// The management secret is written into config.yaml verbatim, so it must stay
/// YAML-safe: hex only, no quotes, no whitespace.
fn generate_management_secret() -> String {
    let bytes: [u8; 16] = rand::random();
    let hex: String = bytes.iter().map(|b| format!("{:02x}", b)).collect();
    format!("melon-mgmt-{}", hex)
}

#[cfg(test)]
mod tests {
    use super::{protect_secrets, secret_fields, unprotect_secrets, Settings};

    fn legacy_settings() -> Settings {
        let mut s = Settings::default();
        s.api_key = "sk-legacy-api".to_string();
        s.openrouter_key = "sk-or-legacy".to_string();
        s.opencode_key = "sk-oc-legacy".to_string();
        s.claude_api_key = "sk-ant-legacy".to_string();
        s.management_secret = "melon-mgmt-legacy".to_string();
        s
    }

    #[test]
    fn legacy_plaintext_settings_are_read_unchanged() {
        let mut s = legacy_settings();
        unprotect_secrets(&mut s);
        assert_eq!(s.api_key, "sk-legacy-api");
        assert_eq!(s.openrouter_key, "sk-or-legacy");
        assert_eq!(s.opencode_key, "sk-oc-legacy");
        assert_eq!(s.claude_api_key, "sk-ant-legacy");
        assert_eq!(s.management_secret, "melon-mgmt-legacy");
    }

    #[test]
    fn save_roundtrip_preserves_every_secret() {
        let original = legacy_settings();
        let mut stored = original.clone();
        protect_secrets(&mut stored).unwrap();

        #[cfg(windows)]
        for field in secret_fields(&mut stored) {
            assert!(
                crate::dpapi::is_protected(field),
                "secret was not protected: {}",
                field.as_str()
            );
        }
        #[cfg(not(windows))]
        for field in secret_fields(&mut stored) {
            assert!(!crate::dpapi::is_protected(field));
        }

        unprotect_secrets(&mut stored);
        assert_eq!(stored.api_key, original.api_key);
        assert_eq!(stored.openrouter_key, original.openrouter_key);
        assert_eq!(stored.opencode_key, original.opencode_key);
        assert_eq!(stored.claude_api_key, original.claude_api_key);
        assert_eq!(stored.management_secret, original.management_secret);
    }

    #[test]
    fn empty_secrets_stay_empty() {
        let mut s = Settings::default();
        protect_secrets(&mut s).unwrap();
        for field in secret_fields(&mut s) {
            assert!(field.is_empty());
        }
        unprotect_secrets(&mut s);
        for field in secret_fields(&mut s) {
            assert!(field.is_empty());
        }
    }

    #[test]
    fn undecryptable_secrets_become_empty() {
        let mut s = Settings::default();
        s.api_key = "dpapi2:AAAA".to_string();
        s.openrouter_key = "dpapi:AAAA".to_string();
        s.opencode_key = "dpapi:not-base64!!!".to_string();
        s.claude_api_key = "dpapi2:".to_string();
        s.management_secret = "dpapi:not-base64!!!".to_string();
        unprotect_secrets(&mut s);
        for field in secret_fields(&mut s) {
            assert!(field.is_empty(), "ciphertext leaked: {}", field.as_str());
        }
    }

    #[test]
    fn reserved_prefix_secrets_roundtrip() {
        for value in ["dpapi:literal", "dpapi2:literal", "plain:literal"] {
            let mut s = Settings::default();
            s.api_key = value.to_string();
            protect_secrets(&mut s).unwrap();
            #[cfg(not(windows))]
            assert!(s.api_key.starts_with(crate::dpapi::PREFIX_PLAIN));
            unprotect_secrets(&mut s);
            assert_eq!(s.api_key, value);
        }
    }

    #[test]
    fn notification_and_dashboard_toggles_default_on() {
        let s = Settings::default();
        assert!(s.notifications);
        assert!(s.notify_low_quota);
        assert!(s.notify_scheduler);
        assert!(s.notify_quota_reset);
        assert!(s.dashboard_show_pool_health);
        assert!(s.dashboard_show_quota_trends);
        assert!(s.dashboard_show_spend);
        assert!(s.dashboard_show_scheduler);
        assert!(s.quota_reset_notified.is_empty());
    }

    #[test]
    fn legacy_settings_get_21_defaults_and_keep_explicit_values() {
        let s: Settings =
            serde_json::from_str(r#"{"port":19000,"notifyLowQuota":false}"#).unwrap();
        assert_eq!(s.port, 19000);
        assert!(!s.notify_low_quota);
        assert!(s.notifications);
        assert!(s.notify_scheduler);
        assert!(s.notify_quota_reset);
        assert!(s.dashboard_show_pool_health);
        assert!(s.dashboard_show_quota_trends);
        assert!(s.dashboard_show_spend);
        assert!(s.dashboard_show_scheduler);
        assert!(s.quota_reset_notified.is_empty());

        let raw = serde_json::to_value(&s).unwrap();
        for key in [
            "notifications",
            "notifyScheduler",
            "notifyQuotaReset",
            "dashboardShowPoolHealth",
            "dashboardShowQuotaTrends",
            "dashboardShowSpend",
            "dashboardShowScheduler",
            "quotaResetNotified",
        ] {
            assert!(raw.get(key).is_some(), "missing key {key}");
        }
    }
}
