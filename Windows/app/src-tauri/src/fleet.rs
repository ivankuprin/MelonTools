//! Fleet: the CLI workspace on disk (snapshots, results, config, log) plus
//! CLI actions. The CLI itself (`melon-fleet`) is resolved from PATH.

use serde_json::{json, Value};
use std::path::{Path, PathBuf};

use crate::settings::Settings;

pub fn home(settings: &Settings) -> PathBuf {
    if !settings.fleet_home.trim().is_empty() {
        return PathBuf::from(settings.fleet_home.trim());
    }
    if let Ok(profile) = std::env::var("USERPROFILE") {
        return PathBuf::from(profile).join(".melon-fleet");
    }
    PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".melon-fleet")
}

/// Workspace overview: snapshots + the tail of the ndjson log.
pub fn status(settings: &Settings) -> Value {
    let home = home(settings);
    let mut snapshots: Vec<Value> = Vec::new();
    if let Ok(entries) = std::fs::read_dir(home.join("snapshots")) {
        for entry in entries.flatten().take(50) {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("json") {
                continue;
            }
            let modified = entry
                .metadata()
                .ok()
                .and_then(|m| m.modified().ok())
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_secs() as i64)
                .unwrap_or(0);
            let parsed = std::fs::read_to_string(&path)
                .ok()
                .and_then(|raw| serde_json::from_str::<Value>(&raw).ok());
            snapshots.push(json!({
                "name": path.file_name().map(|n| n.to_string_lossy().to_string()),
                "modified": modified,
                "data": parsed.unwrap_or(Value::Null),
            }));
        }
    }
    snapshots.sort_by(|a, b| {
        b.get("modified")
            .and_then(|v| v.as_i64())
            .unwrap_or(0)
            .cmp(&a.get("modified").and_then(|v| v.as_i64()).unwrap_or(0))
    });

    let mut log_tail: Vec<String> = Vec::new();
    if let Ok(text) = std::fs::read_to_string(home.join("fleet-log.ndjson")) {
        for line in text.lines().rev().take(40) {
            log_tail.push(line.to_string());
        }
        log_tail.reverse();
    }

    json!({
        "home": home.to_string_lossy(),
        "cli": cli_path().map(|p| p.to_string_lossy().to_string()),
        "snapshots": snapshots,
        "logTail": log_tail,
    })
}

/// Result files under `results/<unit>/*.md`, newest first.
pub fn results(settings: &Settings, limit: usize) -> Value {
    let home = home(settings);
    let mut items: Vec<Value> = Vec::new();
    let units = std::fs::read_dir(home.join("results"));
    if let Ok(units) = units {
        for unit in units.flatten().take(20) {
            let unit_name = unit.file_name().to_string_lossy().to_string();
            let Ok(files) = std::fs::read_dir(unit.path()) else {
                continue;
            };
            let mut names: Vec<String> = files
                .flatten()
                .filter_map(|entry| {
                    let name = entry.file_name().to_string_lossy().to_string();
                    name.ends_with(".md").then_some(name)
                })
                .collect();
            names.sort();
            names.reverse();
            for name in names.into_iter().take(40) {
                let path = unit.path().join(&name);
                let size = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
                let modified = std::fs::metadata(&path)
                    .ok()
                    .and_then(|m| m.modified().ok())
                    .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|d| d.as_secs() as i64)
                    .unwrap_or(0);
                items.push(json!({
                    "unit": unit_name,
                    "name": name,
                    "path": path.to_string_lossy(),
                    "size": size,
                    "modified": modified,
                }));
            }
        }
    }
    items.sort_by(|a, b| {
        b.get("modified")
            .and_then(|v| v.as_i64())
            .unwrap_or(0)
            .cmp(&a.get("modified").and_then(|v| v.as_i64()).unwrap_or(0))
    });
    items.truncate(limit);
    Value::Array(items)
}

/// Bounded prefix of a result file (results can be tens of MB).
pub fn read_result(path: &str) -> Result<String, String> {
    let home_prefix = home(&crate::settings::load());
    let target = std::fs::canonicalize(path).map_err(|e| e.to_string())?;
    let home_canonical = std::fs::canonicalize(&home_prefix).unwrap_or(home_prefix);
    if !target.starts_with(&home_canonical) {
        return Err("файл вне рабочей папки Fleet".to_string());
    }
    let data = std::fs::read(&target).map_err(|e| e.to_string())?;
    let cap = 512 * 1024;
    let mut text = String::from_utf8_lossy(&data[..data.len().min(cap)]).to_string();
    if data.len() > cap {
        text.push_str("\n\n… предпросмотр обрезан");
    }
    Ok(text)
}

pub fn config_get(settings: &Settings) -> Value {
    let path = home(settings).join("fleet.config.json");
    let text = std::fs::read_to_string(&path).unwrap_or_default();
    json!({ "path": path.to_string_lossy(), "text": text })
}

pub fn config_set(settings: &Settings, text: &str) -> Result<(), String> {
    // Validate before writing: a broken config must not reach the CLI.
    serde_json::from_str::<Value>(text).map_err(|e| format!("не JSON: {}", e))?;
    let path = home(settings).join("fleet.config.json");
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    std::fs::write(path, text).map_err(|e| e.to_string())
}

pub fn cli_path() -> Option<PathBuf> {
    #[cfg(windows)]
    {
        let mut command = std::process::Command::new("where.exe");
        command.arg("melon-fleet");
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x0800_0000);
        if let Ok(output) = command.output() {
            let text = String::from_utf8_lossy(&output.stdout);
            if let Some(first) = text.lines().map(str::trim).find(|l| !l.is_empty()) {
                let path = PathBuf::from(first);
                if path.exists() {
                    return Some(path);
                }
            }
        }
        None
    }
    #[cfg(not(windows))]
    {
        let output = std::process::Command::new("which")
            .arg("melon-fleet")
            .output()
            .ok()?;
        let text = String::from_utf8_lossy(&output.stdout);
        let first = text.lines().next()?.trim();
        (!first.is_empty()).then(|| PathBuf::from(first))
    }
}

/// Runs the Fleet CLI (`melon-fleet <args…>`) and returns its output.
pub async fn cli_run(settings: &Settings, args: Vec<String>) -> Result<String, String> {
    let cli = cli_path().ok_or_else(|| {
        "CLI melon-fleet не найден в PATH (npm i -g melon-fleet)".to_string()
    })?;
    let mut command = tokio::process::Command::new(&cli);
    command.args(&args);
    command.env("MELON_FLEET_HOME", home(settings));
    command.stdout(std::process::Stdio::piped());
    command.stderr(std::process::Stdio::piped());
    let output = tokio::time::timeout(std::time::Duration::from_secs(120), command.output())
        .await
        .map_err(|_| "CLI не ответил за 120 секунд".to_string())?
        .map_err(|e| e.to_string())?;
    let mut text = String::from_utf8_lossy(&output.stdout).to_string();
    let errors = String::from_utf8_lossy(&output.stderr);
    if !errors.trim().is_empty() {
        text.push_str("\n[stderr]\n");
        text.push_str(&errors);
    }
    if text.len() > 60_000 {
        text.truncate(60_000);
        text.push_str("\n… вывод обрезан");
    }
    Ok(text)
}

pub fn path_home_display(settings: &Settings) -> String {
    home(settings).to_string_lossy().to_string()
}

#[allow(dead_code)]
fn _unused(_p: &Path) {}
