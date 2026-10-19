//! Filesystem layout for Melon Tools on Windows.
//!
//! The account vault and gateway directory follow the macOS app's layout under
//! `%APPDATA%\MelonTools` so a vault copied from macOS keeps working.

use std::env;
use std::path::PathBuf;

pub fn appdata_dir() -> PathBuf {
    if let Ok(appdata) = env::var("APPDATA") {
        return PathBuf::from(appdata).join("MelonTools");
    }
    // Development fallback (running the check/build on macOS or Linux).
    PathBuf::from(env::var("HOME").unwrap_or_default())
        .join("Library/Application Support/MelonTools")
}

pub fn gateway_dir() -> PathBuf {
    appdata_dir().join("gateway")
}

pub fn auths_dir() -> PathBuf {
    gateway_dir().join("auths")
}

pub fn config_path() -> PathBuf {
    gateway_dir().join("config.yaml")
}

pub fn log_path() -> PathBuf {
    gateway_dir().join("gateway.log")
}

pub fn pid_path() -> PathBuf {
    gateway_dir().join("gateway.pid")
}

pub fn vault_path() -> PathBuf {
    appdata_dir().join("codex").join("accounts.json")
}

pub fn settings_path() -> PathBuf {
    appdata_dir().join("settings.json")
}

pub fn codex_home() -> PathBuf {
    if let Ok(profile) = env::var("USERPROFILE") {
        return PathBuf::from(profile).join(".codex");
    }
    PathBuf::from(env::var("HOME").unwrap_or_default()).join(".codex")
}

pub fn codex_auth_path() -> PathBuf {
    codex_home().join("auth.json")
}

/// YAML wants forward slashes: backslashes are escape characters.
pub fn yaml_path(p: &std::path::Path) -> String {
    p.to_string_lossy().replace('\\', "/")
}

/// A unique temporary sibling for atomic writes: two concurrent writers of
/// the same file must not share one tmp path — the rename would publish the
/// wrong content and the other writer would fail on a missing file.
pub fn tmp_path(path: &std::path::Path) -> PathBuf {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let tick = COUNTER.fetch_add(1, Ordering::Relaxed);
    let name = path
        .file_name()
        .map(|f| f.to_string_lossy().to_string())
        .unwrap_or_else(|| "tmp".to_string());
    path.with_file_name(format!(".{}.{}.{}.tmp", name, std::process::id(), tick))
}
