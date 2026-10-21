//! GitHub-based self-update for the single-file Windows build: check the
//! latest release, download the exe, verify SHA256 and swap the executable
//! from a detached script after the app quits.
//!
//! Public HTTPS endpoints only — `api.github.com` for the release JSON and
//! `github.com` / `objects.githubusercontent.com` /
//! `release-assets.githubusercontent.com` for the download.

use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Duration;

const RELEASE_API: &str = "https://api.github.com/repos/ivankuprin/MelonTools/releases/latest";
const ALLOWED_HOSTS: [&str; 4] = [
    "api.github.com",
    "github.com",
    "objects.githubusercontent.com",
    "release-assets.githubusercontent.com",
];

/// Hosts a release asset may come from. `api.github.com` is deliberately
/// absent: the API serves the release JSON only, never the executable.
const ASSET_HOSTS: [&str; 3] = [
    "github.com",
    "objects.githubusercontent.com",
    "release-assets.githubusercontent.com",
];

/// Asset names the updater accepts: the portable build (preferred) and the
/// legacy name kept in releases so apps on 2.0.2 can still self-update.
fn is_asset_name(name: &str) -> bool {
    name.starts_with("MelonTools-")
        && (name.ends_with("-win-x64-portable.exe") || name.ends_with("-win-x64.exe"))
}

/// Picks the preferred Windows asset: portable first, legacy second. The NSIS
/// installer is deliberately never selected for self-update.
fn pick_asset<'a>(assets: &'a [serde_json::Value]) -> Option<&'a serde_json::Value> {
    for suffix in ["-win-x64-portable.exe", "-win-x64.exe"] {
        if let Some(asset) = assets.iter().find(|asset| {
            asset
                .get("name")
                .and_then(|value| value.as_str())
                .map(|name| name.starts_with("MelonTools-") && name.ends_with(suffix))
                .unwrap_or(false)
        }) {
            return Some(asset);
        }
    }
    None
}

/// Bare host of an https URL, or `None` for any other scheme or a malformed
/// authority. Userinfo and port are stripped so only the real host is checked.
fn https_host(url: &str) -> Option<&str> {
    let rest = url.strip_prefix("https://")?;
    let end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let authority = &rest[..end];
    let host = authority.rsplit('@').next()?.split(':').next()?;
    (!host.is_empty()).then_some(host)
}

/// Only https GitHub endpoints are ever fetched.
pub fn allowed(url: &str) -> bool {
    let Some(host) = https_host(url) else {
        return false;
    };
    ALLOWED_HOSTS
        .iter()
        .any(|allowed| host.eq_ignore_ascii_case(allowed))
}

/// Release assets must come from the download hosts, not from the API host.
pub fn asset_host_allowed(url: &str) -> bool {
    let Some(host) = https_host(url) else {
        return false;
    };
    ASSET_HOSTS
        .iter()
        .any(|allowed| host.eq_ignore_ascii_case(allowed))
}

/// Validated update information cached from the last `update_check`.
///
/// `update_apply` uses only this copy: the renderer arguments are ignored so a
/// compromised renderer cannot redirect the updater to its own binary or drop
/// the checksum.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize)]
pub struct UpdateInfo {
    pub version: String,
    pub asset_name: String,
    pub url: String,
    pub digest: String,
}

fn normalize_digest(text: &str) -> Option<String> {
    let hex = text
        .trim()
        .trim_start_matches("sha256:")
        .trim()
        .to_ascii_lowercase();
    (hex.len() == 64 && hex.chars().all(|c| c.is_ascii_hexdigit())).then_some(hex)
}

/// Re-validates cached info before it reaches the network: an https download
/// host, the Windows asset name and a full SHA256 must all be present.
pub fn validate_cached(info: &UpdateInfo) -> Result<(), String> {
    if !asset_host_allowed(&info.url) {
        return Err("недопустимый адрес обновления".to_string());
    }
    if !is_asset_name(&info.asset_name) {
        return Err("неподходящее имя файла обновления".to_string());
    }
    if normalize_digest(&info.digest).is_none() {
        return Err("нет контрольной суммы SHA256 — обновление отклонено".to_string());
    }
    Ok(())
}

/// Extracts the cacheable update from an `update_check` response. A missing or
/// invalid field yields `None`: an unverifiable update is never cached.
pub fn cached_from_check(result: &Value) -> Option<UpdateInfo> {
    if result.get("skipped").and_then(Value::as_bool) == Some(true) {
        return None;
    }
    if result.get("newer").and_then(Value::as_bool) != Some(true) {
        return None;
    }
    let info = UpdateInfo {
        version: result
            .get("version")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        asset_name: result.get("assetName")?.as_str()?.to_string(),
        url: result.get("assetURL")?.as_str()?.to_string(),
        digest: normalize_digest(result.get("digest")?.as_str()?)?,
    };
    validate_cached(&info).ok()?;
    Some(info)
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
            if let Some(asset) = pick_asset(assets) {
                asset_name = asset
                    .get("name")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
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

/// Writes a PowerShell swap script and spawns it detached. PowerShell reads
/// UTF-8 with BOM correctly on every Windows locale; `cmd.exe` does not.
/// The script waits for this process, keeps a backup and restores it when the
/// copy fails, then starts the new executable and removes itself.
pub fn spawn_swapper(new_exe: &Path, current_exe: &Path, pid: u32) -> Result<PathBuf, String> {
    let dir = std::env::temp_dir().join(format!("melontools-update-{}", uuid_like()));
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let script = dir.join("swap.ps1");
    let quote = |path: &Path| format!("'{}'", path.display().to_string().replace('\'', "''"));
    let content = format!(
        "$ErrorActionPreference = 'Stop'\r\n         $pidToWait = {pid}\r\n         $new = {new}\r\n         $cur = {cur}\r\n         $backup = \"$cur.melon-old\"\r\n         $deadline = (Get-Date).AddSeconds(90)\r\n         while ((Get-Process -Id $pidToWait -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {{ Start-Sleep -Milliseconds 500 }}\r\n         try {{\r\n           if (Test-Path -LiteralPath $cur) {{ Copy-Item -LiteralPath $cur -Destination $backup -Force }}\r\n           Copy-Item -LiteralPath $new -Destination $cur -Force\r\n           Start-Process -FilePath $cur\r\n           Start-Sleep -Seconds 3\r\n           if (-not (Get-Process -Name (Split-Path $cur -Leaf).Replace('.exe','') -ErrorAction SilentlyContinue)) {{ throw 'new executable did not start' }}\r\n           Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue\r\n         }} catch {{\r\n           if (Test-Path -LiteralPath $backup) {{ Copy-Item -LiteralPath $backup -Destination $cur -Force }}\r\n           exit 1\r\n         }} finally {{\r\n           Remove-Item -LiteralPath $new -Force -ErrorAction SilentlyContinue\r\n           Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue\r\n         }}\r\n",
        pid = pid,
        new = quote(new_exe),
        cur = quote(current_exe)
    );
    let mut bytes = vec![0xEF, 0xBB, 0xBF];
    bytes.extend_from_slice(content.as_bytes());
    std::fs::write(&script, bytes).map_err(|e| e.to_string())?;
    let mut command = std::process::Command::new("powershell");
    command.args([
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-WindowStyle",
        "Hidden",
        "-File",
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

fn uuid_like() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
    format!("{:x}-{}", nanos, std::process::id())
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
    fn cdn_asset_host_allowlist() {
        assert!(allowed(
            "https://release-assets.githubusercontent.com/github-production-release-asset/123/asset.exe"
        ));
        assert!(!allowed(
            "https://release-assets.githubusercontent.com.evil.example/asset.exe"
        ));
        assert!(!allowed(
            "https://evil-release-assets.githubusercontent.com/asset.exe"
        ));
        assert!(!allowed(
            "http://release-assets.githubusercontent.com/asset.exe"
        ));
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

    fn check_payload() -> Value {
        json!({
            "skipped": false,
            "version": "1.6.3",
            "newer": true,
            "assetName": "MelonTools-1.6.3-win-x64.exe",
            "assetURL": "https://github.com/ivankuprin/MelonTools/releases/download/v1.6.3/MelonTools-1.6.3-win-x64.exe",
            "digest": "sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        })
    }

    #[test]
    fn cached_update_accepts_a_valid_release() {
        let info = cached_from_check(&check_payload()).expect("valid update cached");
        assert_eq!(info.version, "1.6.3");
        assert_eq!(info.asset_name, "MelonTools-1.6.3-win-x64.exe");
        assert_eq!(info.digest, "a".repeat(64));
        assert!(validate_cached(&info).is_ok());
    }

    #[test]
    fn cached_update_rejects_untrusted_urls() {
        for url in [
            "http://github.com/ivankuprin/MelonTools/releases/download/v1.6.3/MelonTools-1.6.3-win-x64.exe",
            "https://api.github.com/repos/ivankuprin/MelonTools/releases/assets/1",
            "https://github.com.evil.example/MelonTools-1.6.3-win-x64.exe",
            "https://evil.example/MelonTools-1.6.3-win-x64.exe",
        ] {
            let mut payload = check_payload();
            payload["assetURL"] = json!(url);
            assert!(cached_from_check(&payload).is_none(), "accepted {url}");
        }
        assert!(!asset_host_allowed("http://github.com/a"));
        assert!(asset_host_allowed("https://objects.githubusercontent.com/a"));
    }

    #[test]
    #[test]
    fn asset_names_accept_portable_and_legacy_but_not_the_installer() {
        assert!(is_asset_name("MelonTools-2.0.3-win-x64-portable.exe"));
        assert!(is_asset_name("MelonTools-2.0.2-win-x64.exe"));
        assert!(!is_asset_name("MelonTools-2.0.3-setup.exe"));
        let assets = vec![
            serde_json::json!({"name": "MelonTools-2.0.3-setup.exe"}),
            serde_json::json!({"name": "MelonTools-2.0.3-win-x64.exe"}),
            serde_json::json!({"name": "MelonTools-2.0.3-win-x64-portable.exe"}),
        ];
        assert_eq!(
            pick_asset(&assets).and_then(|a| a.get("name")).and_then(|v| v.as_str()),
            Some("MelonTools-2.0.3-win-x64-portable.exe")
        );
    }

    fn cached_update_requires_asset_name_and_digest() {
        let mut payload = check_payload();
        payload["assetName"] = json!("MelonTools-setup.msi");
        assert!(cached_from_check(&payload).is_none());

        let mut payload = check_payload();
        payload["digest"] = json!("sha256:abcd");
        assert!(cached_from_check(&payload).is_none());

        let mut payload = check_payload();
        payload["digest"] = Value::Null;
        assert!(cached_from_check(&payload).is_none());

        let mut payload = check_payload();
        payload["newer"] = json!(false);
        assert!(cached_from_check(&payload).is_none());
    }
}
