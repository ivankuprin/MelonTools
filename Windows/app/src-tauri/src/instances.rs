//! Codex instances: separate CODEX_HOME directories with their own login,
//! so several Codex setups can run side by side (port of CodexInstancesView).

use serde_json::{json, Value};
use std::path::PathBuf;

use crate::paths;
use crate::vault::{self, Account};

fn file() -> PathBuf {
    paths::appdata_dir().join("codex").join("instances.json")
}

fn load() -> Vec<Value> {
    std::fs::read_to_string(file())
        .ok()
        .and_then(|raw| serde_json::from_str::<Value>(&raw).ok())
        .and_then(|value| value.as_array().cloned())
        .unwrap_or_default()
}

fn save(items: &[Value]) -> Result<(), String> {
    let path = file();
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let data = serde_json::to_string_pretty(&Value::Array(items.to_vec()))
        .map_err(|e| e.to_string())?;
    let tmp = crate::paths::tmp_path(&path);
    std::fs::write(&tmp, data).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, &path).map_err(|e| e.to_string())
}

fn home_for(id: &str) -> PathBuf {
    paths::appdata_dir().join("instances").join(id)
}

/// Resolve an instance home only when the id is a single safe path component.
/// `PathBuf::starts_with` does not normalize `..`, so every destructive or
/// credential-writing operation must go through this helper.
fn safe_home(id: &str) -> Option<PathBuf> {
    if !safe_id(id) {
        return None;
    }
    let root = paths::appdata_dir().join("instances");
    let home = root.join(id);
    if home.parent() != Some(root.as_path()) {
        return None;
    }
    Some(home)
}

/// Instance ids are generated as hex, but the value is read back from
/// `instances.json`: reject anything that could escape the instances root
/// before it is joined into a path.
fn safe_id(id: &str) -> bool {
    !id.is_empty()
        && id != "."
        && id != ".."
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
}

pub fn list() -> Vec<Value> {
    load()
        .into_iter()
        .map(|mut item| {
            if let Some(id) = item
                .get("id")
                .and_then(|v| v.as_str())
                .map(str::to_owned)
            {
                let home = home_for(&id);
                item["homePath"] = json!(home.to_string_lossy());
                item["exists"] = json!(home.exists());
            }
            item
        })
        .collect()
}

pub fn create(name: &str) -> Result<Value, String> {
    let name = name.trim();
    if name.is_empty() {
        return Err("имя не может быть пустым".to_string());
    }
    let id = {
        let bytes: [u8; 8] = rand::random();
        bytes.iter().map(|b| format!("{:02x}", b)).collect::<String>()
    };
    let home = home_for(&id);
    std::fs::create_dir_all(&home).map_err(|e| e.to_string())?;
    let mut items = load();
    let entry = json!({
        "id": id,
        "name": name,
        "accountId": Value::Null,
        "createdAt": vault::now_ref(),
    });
    items.push(entry.clone());
    save(&items)?;
    let mut view = entry;
    view["homePath"] = json!(home.to_string_lossy());
    view["exists"] = json!(true);
    Ok(view)
}

pub fn delete(id: &str) -> Result<Vec<Value>, String> {
    let home = safe_home(id).ok_or_else(|| "некорректный идентификатор инстанса".to_string())?;
    let mut items = load();
    items.retain(|item| item.get("id").and_then(|v| v.as_str()) != Some(id));
    save(&items)?;
    // Remove only a validated child of the instances root. A running CLI may
    // still hold files; cleanup is best effort.
    if home.exists() {
        let _ = std::fs::remove_dir_all(home);
    }
    Ok(list())
}

pub fn bind(id: &str, account_id: Option<String>) -> Result<Vec<Value>, String> {
    let mut items = load();
    for item in items.iter_mut() {
        if item.get("id").and_then(|v| v.as_str()) == Some(id) {
            item["accountId"] = match account_id.clone() {
                Some(value) => json!(value),
                None => Value::Null,
            };
        }
    }
    save(&items)?;
    Ok(list())
}

/// Writes the instance login (bound account, or the one currently in the
/// Codex home) and launches `codex` in a visible console with CODEX_HOME
/// pointed at the instance directory.
pub fn launch(id: &str) -> Result<String, String> {
    let home = safe_home(id).ok_or_else(|| "некорректный идентификатор инстанса".to_string())?;
    let items = load();
    let instance = items
        .iter()
        .find(|item| item.get("id").and_then(|v| v.as_str()) == Some(id))
        .ok_or_else(|| "инстанс не найден".to_string())?;
    std::fs::create_dir_all(&home).map_err(|e| e.to_string())?;

    // Pick the account: bound first, else the vault's current login.
    let accounts = vault::accounts();
    let bound = instance
        .get("accountId")
        .and_then(|v| v.as_str())
        .map(String::from);
    let account: Option<Account> = bound
        .and_then(|id| accounts.iter().find(|a| a.id == id).cloned())
        .or_else(|| {
            vault::read_codex_auth_tokens().and_then(|tokens| {
                accounts
                    .iter()
                    .find(|a| a.tokens.access_token == tokens.access_token)
                    .cloned()
            })
        })
        .or_else(|| accounts.first().cloned());

    if let Some(account) = account {
        vault::write_codex_auth_to(&home.join("auth.json"), &account)?;
    }

    #[cfg(windows)]
    {
        let inner = format!("set \"CODEX_HOME={}\" && codex", home.to_string_lossy());
        std::process::Command::new("cmd")
            .args(["/C", "start", "", "cmd", "/K", &inner])
            .spawn()
            .map_err(|e| format!("не удалось запустить codex: {}", e))?;
        Ok(home.to_string_lossy().to_string())
    }
    #[cfg(not(windows))]
    {
        Err("запуск инстансов поддерживается на Windows".to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::{safe_home, safe_id};

    #[test]
    fn instance_home_is_a_direct_child_or_rejected() {
        let root = crate::paths::appdata_dir().join("instances");
        let valid = safe_home("0123456789abcdef").expect("valid id");
        assert_eq!(valid.parent(), Some(root.as_path()));
        assert!(safe_home("..").is_none());
        assert!(safe_home("../..").is_none());
        assert!(safe_home("a/b").is_none());
        assert!(safe_home("a\\b").is_none());
    }

    #[test]
    fn instance_ids_reject_path_traversal() {
        assert!(safe_id("0123456789abcdef"));
        assert!(safe_id("a-b_c.1"));
        assert!(!safe_id(""));
        assert!(!safe_id("."));
        assert!(!safe_id(".."));
        assert!(!safe_id("../evil"));
        assert!(!safe_id("..\\evil"));
        assert!(!safe_id("a/b"));
        assert!(!safe_id("a b"));
        assert!(!safe_id("a:b"));
    }
}
