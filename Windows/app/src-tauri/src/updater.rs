//! GitHub-based self-update for the single-file Windows build: check the
//! latest release, download the exe, verify SHA256 and swap the executable
//! from a detached script after the app quits.
//!
//! Public HTTPS endpoints only — `api.github.com` for the release JSON and
//! `github.com` / `objects.githubusercontent.com` for the download.

use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Duration;

const RELEASE_API: &str = "https://api.github.com/repos/ivankuprin/MelonTools/releases/latest";
const ALLOWED_HOSTS: [&str; 3] = [
    "api.github.com",
    "github.com",
    "objects.githubusercontent.com",
];

/// Only https GitHub endpoints are ever fetched.
pub fn allowed(url: &str) -> bool {
    let Some(rest) = url.strip_prefix("https://") else {
        return false;
    };
    ALLOWED_HOSTS
        .iter()
        .any(|host| rest == *host || rest.starts_with(&format!("{}/", host)))
}

/// Numeric per-segment comparison: 1.4.10 > 1.4.9; "1.4" <= "1.4.0".
pub fn version_is_newer(candidate: &str, current: &str) -> bool {
    let left: Vec<&str> = candidate.split('.').collect();
    let right: Vec<&str> = current.split('.').collect();
    let count = left.len().max(right.len());
    for index in 0..count {
        let l = left.get(index).copied().unwrap_or("0");
        let r = right.get(index).copied().unwrap_or("0");
        match (l.parse::<u64>(), r.parse::<u64>()) {
            (Ok(ln), Ok(rn)) => {
                if ln != rn {
                    return ln > rn;
                }
            }
            _ => {
                if l != r {
                    return l > r;
                }
            }
        }
    }
    false
}

/// First token of a `.sha256` file, when it is a 64-char hex string.
pub fn parse_sha256(text: &str) -> Option<String> {
    let token = text.split_whitespace().next()?;
    let hex = token.trim().to_lowercase();
    (hex.len() == 64 && hex.chars().all(|c| c.is_ascii_hexdigit())).then_some(hex)
}

fn client(timeout: Duration) -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .timeout(timeout)
        .build()
        .map_err(|e| e.to_string())
}

fn client_no_redirect(timeout: Duration) -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .timeout(timeout)
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|e| e.to_string())
}

/// Fetches a URL without automatic redirects: every hop must stay inside the
/// allowlist, so a redirect from a trusted host cannot smuggle us elsewhere.
async fn get_following_allowed(
    url: &str,
    timeout: Duration,
) -> Result<reqwest::Response, String> {
    let client = client_no_redirect(timeout)?;
    let mut current = url.to_string();
    for _ in 0..4 {
        let response = client
            .get(&current)
            .send()
            .await
            .map_err(|e| e.to_string())?;
        if response.status().is_redirection() {
            let location = response
                .headers()
                .get(reqwest::header::LOCATION)
                .and_then(|value| value.to_str().ok())
                .ok_or_else(|| "редирект без адреса".to_string())?;
            if !allowed(location) {
                return Err("редирект на недопустимый адрес отклонён".to_string());
            }
            current = location.to_string();
            continue;
        }
        return Ok(response);
    }
    Err("слишком много редиректов".to_string())
}

/// Latest-release lookup. `force=false` skips when the last check is younger
/// than 24 hours (returns `{"skipped": true}`).
pub async fn check(force: bool, current: &str, last_check: Option<i64>) -> Result<Value, String> {
    if !force {
        if let Some(at) = last_check {
            if chrono::Utc::now().timestamp() - at < 24 * 3600 {
                return Ok(json!({ "skipped": true }));
            }
        }
    }
    let response = client(Duration::from_secs(20))?
        .get(RELEASE_API)
        .header("Accept", "application/vnd.github+json")
        .header("User-Agent", format!("MelonTools/{}", current))
        .send()
        .await
        .map_err(|e| format!("сеть: {}", e))?;
    if response.status().as_u16() != 200 {
        return Err(format!(
            "сервер обновлений ответил {}",
            response.status().as_u16()
        ));
    }
    let body: Value = response.json().await.map_err(|e| e.to_string())?;
    let tag = body
        .get("tag_name")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let version = tag.trim_start_matches('v').to_string();
    let notes = body
        .get("body")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let newer = version_is_newer(&version, current);

    let mut asset_name = String::new();
    let mut asset_url = String::new();
    let mut digest: Option<String> = None;
    if newer {
        if let Some(assets) = body.get("assets").and_then(|v| v.as_array()) {
            for asset in assets {
                let name = asset.get("name").and_then(|v| v.as_str()).unwrap_or("");
                if name.starts_with("MelonTools-") && name.ends_with("-win-x64.exe") {
                    asset_name = name.to_string();
                    asset_url = asset
                        .get("browser_download_url")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string();
                    digest = asset
                        .get("digest")
                        .and_then(|v| v.as_str())
                        .map(|d| d.trim_start_matches("sha256:").to_lowercase())
                        .filter(|d| !d.is_empty());
                    break;
                }
            }
        }
        if asset_url.is_empty() || !allowed(&asset_url) {
            return Err("в этом релизе нет сборки для Windows".to_string());
        }
    }

    Ok(json!({
        "skipped": false,
        "version": version,
        "tag": tag,
        "newer": newer,
        "notes": notes,
        "assetName": asset_name,
        "assetURL": asset_url,
        "digest": digest,
    }))
}

/// Release digest, or the first token of the asset's `.sha256` sibling.
async fn expected_digest(asset_url: &str, digest: Option<&str>) -> Option<String> {
    if let Some(digest) = digest {
        if !digest.is_empty() {
            return Some(digest.to_lowercase());
        }
    }
    let sha_url = format!("{}.sha256", asset_url);
    if !allowed(&sha_url) {
        return None;
    }
    let response = get_following_allowed(&sha_url, Duration::from_secs(20))
        .await
        .ok()?;
    let text = response.text().await.ok()?;
    parse_sha256(&text)
}

/// Downloads and verifies the update; returns the local path of the new exe.
pub async fn fetch_update(asset_url: &str, digest: Option<&str>) -> Result<PathBuf, String> {
    if !allowed(asset_url) {
        return Err("недопустимый адрес обновления".to_string());
    }
    let dir = std::env::temp_dir().join("melontools-update");
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let file = dir.join("MelonTools-update.exe");
    let _ = std::fs::remove_file(&file);

    let mut response = get_following_allowed(asset_url, Duration::from_secs(600)).await?;
    if !response.status().is_success() {
        return Err(format!("загрузка: HTTP {}", response.status().as_u16()));
    }
    let mut hasher = Sha256::new();
    let mut out = std::fs::File::create(&file).map_err(|e| e.to_string())?;
    while let Some(chunk) = response.chunk().await.map_err(|e| e.to_string())? {
        hasher.update(&chunk);
        out.write_all(&chunk).map_err(|e| e.to_string())?;
    }
    out.flush().map_err(|e| e.to_string())?;
    drop(out);

    let expected = expected_digest(asset_url, digest).await;
    let actual = format!("{:x}", hasher.finalize());
    match expected {
        Some(expected) if actual.eq_ignore_ascii_case(&expected) => Ok(file),
        Some(_) => {
            let _ = std::fs::remove_file(&file);
            Err("SHA256 не совпал — обновление отклонено".to_string())
        }
        None => {
            let _ = std::fs::remove_file(&file);
            Err("нет контрольной суммы SHA256 — обновление отклонено".to_string())
        }
    }
}

/// Writes the swap script and spawns it detached. The script waits for this
/// process to exit (PowerShell Get-Process — locale-independent), copies the
/// new exe over the current one, restarts it and deletes itself.
pub fn spawn_swapper(new_exe: &Path, current_exe: &Path, pid: u32) -> Result<PathBuf, String> {
    let dir = std::env::temp_dir().join("melontools-update");
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let script = dir.join("swap.cmd");
    let content = format!(
        "@echo off\r\nset \"PID={pid}\"\r\nset \"N=0\"\r\n:wait\r\npowershell -NoProfile -Command \"if (Get-Process -Id %PID% -ErrorAction SilentlyContinue) {{ exit 0 }} else {{ exit 1 }}\"\r\nif errorlevel 1 goto swap\r\nset /a N+=1\r\nif %N% geq 90 goto giveup\r\nping -n 2 127.0.0.1 >nul\r\ngoto wait\r\n:giveup\r\ndel \"%~f0\"\r\nexit /b 1\r\n:swap\r\ncopy /y \"{new}\" \"{cur}\" >nul\r\nstart \"\" \"{cur}\"\r\ndel /q \"{new}\" >nul 2>nul\r\ndel \"%~f0\"\r\n",
        pid = pid,
        new = new_exe.display(),
        cur = current_exe.display()
    );
    std::fs::write(&script, content).map_err(|e| e.to_string())?;
    let mut command = std::process::Command::new("cmd");
    command.args([
        "/C",
        "start",
        "",
        "/min",
        "cmd",
        "/C",
        &script.to_string_lossy(),
    ]);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x0800_0000);
    }
    command.spawn().map_err(|e| e.to_string())?;
    Ok(script)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_comparison() {
        assert!(version_is_newer("1.4.10", "1.4.9"));
        assert!(!version_is_newer("1.4.9", "1.4.10"));
        assert!(version_is_newer("1.5", "1.4.9"));
        assert!(!version_is_newer("1.4", "1.4.0"));
        assert!(version_is_newer("1.4.1", "1.4"));
        assert!(!version_is_newer("1.4.8", "1.4.8"));
    }

    #[test]
    fn allowlist() {
        assert!(allowed("https://api.github.com/repos/x"));
        assert!(allowed("https://github.com/a/b"));
        assert!(allowed("https://objects.githubusercontent.com/blob"));
        assert!(!allowed("http://github.com/a/b"));
        assert!(!allowed("https://github.com.evil.example.com/x"));
        assert!(!allowed("https://evil.example.com/x"));
    }

    #[test]
    fn sha256_sidecar_parsing() {
        let hash = "a".repeat(64);
        assert_eq!(parse_sha256(&format!("{}  file.exe\n", hash)), Some(hash.clone()));
        assert_eq!(parse_sha256(&hash), Some(hash));
        assert_eq!(parse_sha256("nope file.exe"), None);
        assert_eq!(parse_sha256(""), None);
        assert_eq!(parse_sha256(&"f".repeat(63)), None);
    }
}
