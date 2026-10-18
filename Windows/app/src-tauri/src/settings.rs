//! Settings: a small JSON file next to the vault.

use serde::{Deserialize, Serialize};

use crate::paths;

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
    /// Routing: auto | quotaHighFirst | quotaLowFirst | planHighFirst |
    /// planLowFirst | expirySoonFirst | custom
    pub routing_strategy: String,
    /// Manual order of account ids (for the custom strategy).
    pub priority_order: Vec<String>,
    /// Toast when a window drops below 10% or a pause happens.
    pub notify_low_quota: bool,
    /// Fleet CLI home (snapshots, results, config).
    pub fleet_home: String,
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
            routing_strategy: "auto".to_string(),
            priority_order: Vec::new(),
            notify_low_quota: true,
            fleet_home: String::new(),
        }
    }
}

pub fn load() -> Settings {
    let mut s: Settings = std::fs::read_to_string(paths::settings_path())
        .ok()
        .and_then(|raw| serde_json::from_str(&raw).ok())
        .unwrap_or_default();
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
    s
}

pub fn save(s: &Settings) -> Result<(), String> {
    let dir = paths::appdata_dir();
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let data = serde_json::to_string_pretty(s).map_err(|e| e.to_string())?;
    std::fs::write(paths::settings_path(), data).map_err(|e| e.to_string())
}

fn generate_api_key() -> String {
    let bytes: [u8; 12] = rand::random();
    let hex: String = bytes.iter().map(|b| format!("{:02X}", b)).collect();
    format!("melon-{}", hex)
}
