//! Encrypted backup / export / import.
//!
//! The envelope is byte-for-byte compatible with the macOS app
//! (`MacOS/app/MelonTools/Core/BackupService.swift`):
//!
//! ```json
//! {
//!   "format": "melon-backup",
//!   "formatVersion": 1,
//!   "appVersion": "2.3.1",
//!   "createdAt": 1760000000,
//!   "kdf": { "name": "PBKDF2-HMAC-SHA256", "iterations": 210000,
//!            "salt": "<base64 16 bytes>" },
//!   "cipher": { "name": "AES-256-GCM", "nonce": "<base64 12 bytes>" },
//!   "payload": "<base64 ciphertext||16-byte tag>"
//! }
//! ```
//!
//! PBKDF2-HMAC-SHA256 (210 000 rounds) derives a 32-byte key; AES-256-GCM is
//! used without additional authenticated data, so the payload field is exactly
//! `ciphertext || tag`, like CryptoKit writes it. The password exists only in
//! memory and is never persisted or logged.
//!
//! The decrypted payload embeds raw JSON objects, so neither implementation
//! has to know the other one's model shapes:
//! `scheduler`, `vault`, `auths` (filename -> object), `modelSources`,
//! `settingsMac` (ignored on Windows) and `settingsWindows`.
//!
//! Import decrypts and validates the whole payload before it writes one live
//! file. Vault and settings secrets are plaintext inside the encrypted payload
//! and are re-protected with DPAPI by `vault::save_raw_at` /
//! `settings::save_to`. Logs, caches, pid files, gateway config and lock files
//! are never included.

use std::collections::BTreeMap;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Component, Path, PathBuf};

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce};
use base64::Engine as _;
use rand::rngs::OsRng;
use rand::RngCore;
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use sha2::Sha256;
use zeroize::Zeroizing;

use crate::{paths, scheduler, settings, vault};

pub const FORMAT: &str = "melon-backup";
pub const FORMAT_VERSION: u32 = 1;
/// Product version recorded in the envelope. Kept as a literal because the
/// portable format is shared with the matching macOS build.
pub const APP_VERSION: &str = "2.3.1";
pub const KDF_NAME: &str = "PBKDF2-HMAC-SHA256";
pub const CIPHER_NAME: &str = "AES-256-GCM";
pub const ITERATIONS: u32 = 210_000;
pub const MIN_ITERATIONS: u32 = 210_000;
pub const MAX_ITERATIONS: u32 = 10_000_000;
const SALT_LEN: usize = 16;
const NONCE_LEN: usize = 12;
const TAG_LEN: usize = 16;
const KEY_LEN: usize = 32;
/// Refuse absurd files before they are parsed/decrypted in memory.
const MAX_BACKUP_BYTES: usize = 128 * 1024 * 1024;

const EMPTY_PASSWORD: &str = "введите пароль резервной копии";
const MALFORMED_ENVELOPE: &str = "это не файл резервной копии Melon Tools";
const WRONG_PASSWORD: &str = "неверный пароль или файл резервной копии повреждён";
const INVALID_PARAMETERS: &str = "некорректные параметры шифрования резервной копии";

/// Filesystem layout used by one export/import. Production uses the app's
/// appdata/downloads directories; tests inject a temporary support directory.
#[derive(Clone, Debug)]
pub struct BackupPaths {
    pub support: PathBuf,
    pub destination: PathBuf,
}

impl BackupPaths {
    pub fn production() -> Self {
        Self {
            support: paths::appdata_dir(),
            destination: paths::downloads_dir(),
        }
    }

    fn scheduler_path(&self) -> PathBuf {
        self.support.join("scheduler.json")
    }

    fn vault_path(&self) -> PathBuf {
        self.support.join("codex").join("accounts.json")
    }

    fn settings_path(&self) -> PathBuf {
        self.support.join("settings.json")
    }

    fn auths_dir(&self) -> PathBuf {
        self.support.join("gateway").join("auths")
    }

    fn model_sources_path(&self) -> PathBuf {
        self.support.join("model-sources.json")
    }

    fn state_path(&self) -> PathBuf {
        self.support.join("backup-state.json")
    }
}

#[derive(Serialize, Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
struct Envelope {
    format: String,
    format_version: u32,
    app_version: String,
    created_at: i64,
    kdf: Kdf,
    cipher: CipherSpec,
    payload: String,
}

#[derive(Serialize, Deserialize, Debug)]
struct Kdf {
    name: String,
    iterations: u32,
    salt: String,
}

#[derive(Serialize, Deserialize, Debug)]
struct CipherSpec {
    name: String,
    nonce: String,
}

// MARK: - Public API

/// Export to `%USERPROFILE%\Downloads\MelonTools-backup-<timestamp>.melon`
/// (falling back to appdata when Downloads cannot be used). An existing file
/// is never overwritten.
pub fn export(password: &str) -> Result<Value, String> {
    export_to(
        &BackupPaths::production(),
        password,
        chrono::Utc::now().timestamp(),
    )
}

/// Testable export core with an explicit layout and clock.
pub fn export_to(paths: &BackupPaths, password: &str, created_at: i64) -> Result<Value, String> {
    if password.is_empty() {
        return Err(EMPTY_PASSWORD.to_string());
    }

    let payload = collect_payload(paths)?;
    let payload_text =
        serde_json::to_string_pretty(&payload).map_err(|e| format!("backup payload: {e}"))?;
    let envelope = seal(payload_text.as_bytes(), password, created_at)?;
    let bytes = envelope.as_bytes();
    let stem = format!("MelonTools-backup-{}", timestamp_label(created_at));

    let path = match write_backup(&paths.destination, &stem, bytes) {
        Ok(path) => path,
        Err(primary_error) if paths.destination != paths.support => {
            write_backup(&paths.support, &stem, bytes).map_err(|fallback_error| {
                format!("backup file error: {primary_error}; fallback: {fallback_error}")
            })?
        }
        Err(error) => return Err(format!("backup file error: {error}")),
    };

    // The state file is a convenience for the UI; a failed write must not
    // turn a valid backup into an error.
    let _ = set_last_backup_at(paths, created_at);

    Ok(json!({
        "path": path.to_string_lossy(),
        "bytes": bytes.len(),
        "createdAt": created_at,
    }))
}

/// Read, validate and decrypt a backup, then restore the known components.
/// Any error before the write phase leaves live data untouched.
pub fn import(content: &str, password: &str) -> Result<Value, String> {
    import_into(&BackupPaths::production(), content, password)
}

/// Testable import core with an explicit layout.
pub fn import_into(paths: &BackupPaths, content: &str, password: &str) -> Result<Value, String> {
    if password.is_empty() {
        return Err(EMPTY_PASSWORD.to_string());
    }
    let plaintext = open(content, password)?;
    let root: Value = serde_json::from_slice(&plaintext)
        .map_err(|e| format!("the backup payload is damaged: {e}"))?;
    let object = root
        .as_object()
        .ok_or_else(|| "the backup payload is damaged: not a JSON object".to_string())?;

    let scheduler_value = optional_object(object.get("scheduler"), "scheduler")?;
    if let Some(value) = &scheduler_value {
        serde_json::from_value::<scheduler::Store>(value.clone())
            .map_err(|e| format!("the backup payload is damaged: scheduler: {e}"))?;
    }

    let vault_value = optional_object(object.get("vault"), "vault")?;
    if let Some(value) = &vault_value {
        validate_vault(value)?;
    }

    let model_sources = optional_object(object.get("modelSources"), "modelSources")?;
    let settings_value = optional_object(object.get("settingsWindows"), "settingsWindows")?;
    let settings_restore = match &settings_value {
        Some(value) => {
            let mut restored = parse_settings(value)?;
            // The gateway key and management secret are machine-local. They
            // are never exported and must never be replaced by a backup.
            let current = settings::load_from(&paths.settings_path());
            restored.api_key = current.api_key;
            restored.management_secret = current.management_secret;
            Some(restored)
        }
        None => None,
    };
    let auths = parse_auths(object.get("auths"))?;

    // Serialize every component before the first live write: a damaged
    // payload cannot leave a half-restored directory.
    let mut auth_files: Vec<(String, String)> = Vec::with_capacity(auths.len());
    for (name, value) in &auths {
        let data = serde_json::to_string_pretty(value)
            .map_err(|e| format!("the backup payload is damaged: auths/{name}: {e}"))?;
        auth_files.push((name.clone(), data));
    }
    let model_sources_data = match &model_sources {
        Some(value) => Some(
            serde_json::to_string_pretty(value)
                .map_err(|e| format!("the backup payload is damaged: modelSources: {e}"))?,
        ),
        None => None,
    };

    // MARK: Live writes (all validation above is complete)

    // Snapshot every target first. Windows cannot rename over a file the
    // engine has open, and a disk-full mid-sequence must not leave a mixed
    // settings/vault/auth profile. A read failure aborts before any write.
    let auths_dir = paths.auths_dir();
    let mut targets: Vec<PathBuf> = Vec::new();
    if settings_restore.is_some() {
        targets.push(paths.settings_path());
    }
    if scheduler_value.is_some() {
        targets.push(paths.scheduler_path());
    }
    if vault_value.is_some() {
        targets.push(paths.vault_path());
    }
    if model_sources_data.is_some() {
        targets.push(paths.model_sources_path());
    }
    for (name, _) in &auth_files {
        targets.push(auths_dir.join(name));
    }
    let mut snapshots: Vec<(PathBuf, Option<Vec<u8>>)> = Vec::with_capacity(targets.len());
    for target in targets {
        if target.exists() {
            let bytes = fs::read(&target)
                .map_err(|e| format!("backup file error: cannot snapshot {}: {e}", target.display()))?;
            snapshots.push((target, Some(bytes)));
        } else {
            snapshots.push((target, None));
        }
    }

    let write_result = (|| -> Result<(), String> {
        if let Some(settings) = &settings_restore {
            settings::save_to(&paths.settings_path(), settings)?;
        }
        if let Some(value) = &scheduler_value {
            scheduler::save_raw_at(&paths.scheduler_path(), value)?;
        }
        if let Some(value) = &vault_value {
            vault::save_raw_at(&paths.vault_path(), value)?;
        }
        if let Some(data) = &model_sources_data {
            write_atomic(&paths.model_sources_path(), data)?;
        }
        if !auth_files.is_empty() {
            fs::create_dir_all(&auths_dir).map_err(|e| format!("backup file error: {e}"))?;
            set_directory_mode(&auths_dir);
            for (name, data) in &auth_files {
                let target = auths_dir.join(name);
                write_atomic(&target, data)?;
                set_file_mode(&target);
            }
        }
        Ok(())
    })();

    if let Err(error) = write_result {
        let mut rollback_error = None;
        for (target, previous) in snapshots.iter().rev() {
            let restored = match previous {
                Some(bytes) => write_atomic_bytes(target, bytes),
                None => match fs::remove_file(target) {
                    Ok(()) => Ok(()),
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
                    Err(e) => Err(format!("backup file error: {e}")),
                },
            };
            if restored.is_err() && rollback_error.is_none() {
                rollback_error = restored.err();
            }
        }
        return Err(match rollback_error {
            Some(rollback) => format!("{error}; rollback failed: {rollback}"),
            None => error,
        });
    }

    Ok(json!({
        "schedulerTasks": count_array(scheduler_value.as_ref(), "tasks"),
        "schedulerHistory": count_array(scheduler_value.as_ref(), "history"),
        "accounts": count_array(vault_value.as_ref(), "accounts"),
        "authFiles": auth_files.len(),
        "modelSourcesIncluded": model_sources.is_some(),
        "settingsKeys": settings_value
            .as_ref()
            .and_then(|value| value.as_object())
            .map(|object| object.len())
            .unwrap_or(0),
    }))
}

/// Unix seconds of the last successful export, if one was recorded.
pub fn last_backup_at() -> Option<i64> {
    read_last_backup_at(&BackupPaths::production())
}

fn read_last_backup_at(paths: &BackupPaths) -> Option<i64> {
    let text = fs::read_to_string(paths.state_path()).ok()?;
    let value: Value = serde_json::from_str(&text).ok()?;
    value.get("lastBackupAt")?.as_i64()
}

fn set_last_backup_at(paths: &BackupPaths, at: i64) -> Result<(), String> {
    let data = serde_json::to_string_pretty(&json!({"lastBackupAt": at}))
        .map_err(|e| e.to_string())?;
    write_atomic(&paths.state_path(), &data)
}

// MARK: - Payload: collect

fn collect_payload(paths: &BackupPaths) -> Result<Value, String> {
    let mut payload = Map::new();

    if let Some(scheduler) = read_valid_scheduler(&paths.scheduler_path()) {
        payload.insert("scheduler".to_string(), scheduler);
    }
    if let Some(vault) = read_valid_vault(&paths.vault_path()) {
        payload.insert("vault".to_string(), vault);
    }

    let auths: Map<String, Value> = collect_auths(&paths.auths_dir())
        .into_iter()
        .map(|(name, value)| (name, Value::Object(value)))
        .collect();
    payload.insert("auths".to_string(), Value::Object(auths));

    if let Some(object) = read_json_object(&paths.model_sources_path()) {
        payload.insert("modelSources".to_string(), Value::Object(object));
    }

    // `settings::load_from` returns plaintext secrets; they are protected
    // again by the envelope. `settingsMac` stays null on Windows, exactly like
    // the macOS writer writes `settingsWindows: null`.
    let settings = settings::load_from(&paths.settings_path());
    let mut settings_value =
        serde_json::to_value(&settings).map_err(|e| format!("settings: {e}"))?;
    if let Some(object) = settings_value.as_object_mut() {
        object.remove("apiKey");
        object.remove("managementSecret");
    }
    payload.insert("settingsMac".to_string(), Value::Null);
    payload.insert("settingsWindows".to_string(), settings_value);

    Ok(Value::Object(payload))
}

fn read_valid_scheduler(path: &Path) -> Option<Value> {
    let value = scheduler::load_raw_at(path)?;
    serde_json::from_value::<scheduler::Store>(value.clone()).ok()?;
    Some(value)
}

fn read_valid_vault(path: &Path) -> Option<Value> {
    let object = read_json_object(path)?;
    if !object.get("accounts").map(Value::is_array).unwrap_or(false) {
        return None;
    }
    // DPAPI-protected tokens are decrypted for the portable payload.
    Some(vault::load_raw_at(path))
}

/// Every safe `*.json` regular file in the auths directory that parses as a
/// JSON object. Hidden, symlinked, `.lock`, corrupt and unsafe-named entries
/// are skipped.
fn collect_auths(dir: &Path) -> BTreeMap<String, Map<String, Value>> {
    let mut result = BTreeMap::new();
    let Ok(entries) = fs::read_dir(dir) else {
        return result;
    };
    let mut files: Vec<PathBuf> = entries.flatten().map(|entry| entry.path()).collect();
    files.sort();
    for path in files {
        let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        if !is_safe_auth_file_name(name) {
            continue;
        }
        let Ok(metadata) = fs::symlink_metadata(&path) else {
            continue;
        };
        // `is_file` is false for symlinks, directories and device files.
        if !metadata.file_type().is_file() {
            continue;
        }
        let Some(object) = read_json_object(&path) else {
            continue;
        };
        result.insert(name.to_string(), object);
    }
    result
}

fn read_json_object(path: &Path) -> Option<Map<String, Value>> {
    let metadata = fs::symlink_metadata(path).ok()?;
    if !metadata.file_type().is_file() {
        return None;
    }
    let text = fs::read_to_string(path).ok()?;
    match serde_json::from_str::<Value>(&text).ok()? {
        Value::Object(object) => Some(object),
        _ => None,
    }
}

// MARK: - Payload: validate / restore

fn optional_object(value: Option<&Value>, name: &str) -> Result<Option<Value>, String> {
    match value {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Object(object)) => Ok(Some(Value::Object(object.clone()))),
        Some(_) => Err(format!(
            "the backup payload is damaged: {name} is not a JSON object"
        )),
    }
}

fn validate_vault(value: &Value) -> Result<(), String> {
    let object = value
        .as_object()
        .ok_or_else(|| "the backup payload is damaged: vault is not a JSON object".to_string())?;
    match object.get("accounts") {
        Some(Value::Array(_)) => Ok(()),
        Some(_) => Err("the backup payload is damaged: vault accounts is not an array".to_string()),
        None => Err("the backup payload is damaged: vault has no accounts array".to_string()),
    }
}

/// Names that may never be joined to the auths directory. Mirrors
/// `BackupService.isSafeAuthFileName` and is deliberately strict on import: a
/// path-traversal name rejects the whole backup instead of being skipped.
pub fn is_safe_auth_file_name(name: &str) -> bool {
    if name.is_empty() || !name.ends_with(".json") {
        return false;
    }
    if name.to_ascii_lowercase().ends_with(".lock") {
        return false;
    }
    if name.starts_with('.') {
        return false;
    }
    if name.contains('/') || name.contains('\\') || name.contains("..") || name.contains('\0') {
        return false;
    }
    if name.chars().any(char::is_control) {
        return false;
    }
    let mut components = Path::new(name).components();
    matches!(components.next(), Some(Component::Normal(_))) && components.next().is_none()
}

fn parse_auths(value: Option<&Value>) -> Result<BTreeMap<String, Value>, String> {
    let mut result = BTreeMap::new();
    let Some(value) = value else {
        return Ok(result);
    };
    if value.is_null() {
        return Ok(result);
    }
    let object = value.as_object().ok_or_else(|| {
        "the backup payload is damaged: auths is not a JSON object".to_string()
    })?;
    for (name, entry) in object {
        if !is_safe_auth_file_name(name) {
            return Err(format!("unsafe backup file name: {name}"));
        }
        if !entry.is_object() {
            return Err(format!(
                "the backup payload is damaged: auths/{name} is not a JSON object"
            ));
        }
        result.insert(name.clone(), entry.clone());
    }
    Ok(result)
}

fn parse_settings(value: &Value) -> Result<settings::Settings, String> {
    let mut settings: settings::Settings = serde_json::from_value(value.clone())
        .map_err(|e| format!("the backup payload is damaged: settingsWindows: {e}"))?;
    if settings.port == 0 {
        settings.port = 18317;
    }
    if !(1024..=65535).contains(&settings.port) {
        return Err("the backup payload is damaged: settingsWindows port is out of range".into());
    }
    if settings.quota_interval == 0 {
        settings.quota_interval = 300;
    }
    if !(60..=86_400).contains(&settings.quota_interval) {
        return Err(
            "the backup payload is damaged: settingsWindows quota interval is out of range".into(),
        );
    }
    if settings.lang.is_empty() {
        settings.lang = "ru".to_string();
    }
    if settings.lang != "ru" && settings.lang != "en" {
        return Err("the backup payload is damaged: settingsWindows language is unknown".into());
    }
    if settings.routing_strategy.is_empty() {
        settings.routing_strategy = "auto".to_string();
    }
    Ok(settings)
}

fn count_array(value: Option<&Value>, key: &str) -> usize {
    value
        .and_then(|value| value.get(key))
        .and_then(Value::as_array)
        .map(Vec::len)
        .unwrap_or(0)
}

// MARK: - Encryption

fn seal(payload: &[u8], password: &str, created_at: i64) -> Result<String, String> {
    if password.is_empty() {
        return Err(EMPTY_PASSWORD.to_string());
    }
    let mut salt = [0u8; SALT_LEN];
    OsRng.fill_bytes(&mut salt);
    let mut nonce_bytes = [0u8; NONCE_LEN];
    OsRng.fill_bytes(&mut nonce_bytes);

    let key = derive_key(password, &salt, ITERATIONS);
    let cipher = Aes256Gcm::new_from_slice(key.as_slice())
        .map_err(|_| "backup encryption failed".to_string())?;
    // No AAD: the payload field is exactly ciphertext || 16-byte tag.
    let sealed = cipher
        .encrypt(Nonce::from_slice(&nonce_bytes), payload)
        .map_err(|_| "backup encryption failed".to_string())?;

    let envelope = Envelope {
        format: FORMAT.to_string(),
        format_version: FORMAT_VERSION,
        app_version: APP_VERSION.to_string(),
        created_at,
        kdf: Kdf {
            name: KDF_NAME.to_string(),
            iterations: ITERATIONS,
            salt: base64::engine::general_purpose::STANDARD.encode(salt),
        },
        cipher: CipherSpec {
            name: CIPHER_NAME.to_string(),
            nonce: base64::engine::general_purpose::STANDARD.encode(nonce_bytes),
        },
        payload: base64::engine::general_purpose::STANDARD.encode(sealed),
    };
    serde_json::to_string_pretty(&envelope).map_err(|e| format!("backup envelope: {e}"))
}

fn open(content: &str, password: &str) -> Result<Vec<u8>, String> {
    if password.is_empty() {
        return Err(EMPTY_PASSWORD.to_string());
    }
    if content.len() > MAX_BACKUP_BYTES {
        return Err("backup file is too large".to_string());
    }
    let envelope: Envelope =
        serde_json::from_str(content).map_err(|_| MALFORMED_ENVELOPE.to_string())?;

    if envelope.format != FORMAT {
        return Err(format!("unsupported backup format: {}", envelope.format));
    }
    if envelope.format_version != FORMAT_VERSION {
        return Err(format!(
            "unsupported backup format version {}. Update Melon Tools.",
            envelope.format_version
        ));
    }
    if envelope.kdf.name != KDF_NAME {
        return Err(format!(
            "unsupported backup encryption method: {}",
            envelope.kdf.name
        ));
    }
    if envelope.cipher.name != CIPHER_NAME {
        return Err(format!("unsupported backup cipher: {}", envelope.cipher.name));
    }
    if !(MIN_ITERATIONS..=MAX_ITERATIONS).contains(&envelope.kdf.iterations) {
        return Err(INVALID_PARAMETERS.to_string());
    }

    let salt = decode_base64(&envelope.kdf.salt).ok_or_else(|| INVALID_PARAMETERS.to_string())?;
    if salt.len() != SALT_LEN {
        return Err(INVALID_PARAMETERS.to_string());
    }
    let nonce = decode_base64(&envelope.cipher.nonce).ok_or_else(|| INVALID_PARAMETERS.to_string())?;
    if nonce.len() != NONCE_LEN {
        return Err(INVALID_PARAMETERS.to_string());
    }
    let combined =
        decode_base64(&envelope.payload).ok_or_else(|| MALFORMED_ENVELOPE.to_string())?;
    if combined.len() <= TAG_LEN {
        return Err(MALFORMED_ENVELOPE.to_string());
    }

    let key = derive_key(password, &salt, envelope.kdf.iterations);
    let cipher = Aes256Gcm::new_from_slice(key.as_slice())
        .map_err(|_| "backup decryption failed".to_string())?;
    cipher
        .decrypt(Nonce::from_slice(&nonce), combined.as_slice())
        .map_err(|_| WRONG_PASSWORD.to_string())
}

fn derive_key(password: &str, salt: &[u8], iterations: u32) -> Zeroizing<[u8; KEY_LEN]> {
    Zeroizing::new(pbkdf2::pbkdf2_hmac_array::<Sha256, KEY_LEN>(
        password.as_bytes(),
        salt,
        iterations,
    ))
}

fn decode_base64(value: &str) -> Option<Vec<u8>> {
    base64::engine::general_purpose::STANDARD
        .decode(value)
        .ok()
}

// MARK: - Files

fn write_backup(dir: &Path, stem: &str, bytes: &[u8]) -> Result<PathBuf, String> {
    fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    for attempt in 0..1000 {
        let name = if attempt == 0 {
            format!("{stem}.melon")
        } else {
            format!("{stem}-{attempt}.melon")
        };
        let path = dir.join(name);
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        match options.open(&path) {
            Ok(mut file) => {
                let result = file.write_all(bytes).and_then(|_| file.sync_all());
                if let Err(error) = result {
                    drop(file);
                    let _ = fs::remove_file(&path);
                    return Err(error.to_string());
                }
                return Ok(path);
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error.to_string()),
        }
    }
    Err("too many backups with the same timestamp".to_string())
}

fn write_atomic(path: &Path, data: &str) -> Result<(), String> {
    write_atomic_bytes(path, data.as_bytes())
}

fn write_atomic_bytes(path: &Path, data: &[u8]) -> Result<(), String> {
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let tmp = paths::tmp_path(path);
    fs::write(&tmp, data).map_err(|e| e.to_string())?;
    fs::rename(&tmp, path).map_err(|e| e.to_string())
}

fn set_file_mode(path: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o600));
    }
    #[cfg(not(unix))]
    let _ = path;
}

fn set_directory_mode(path: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o700));
    }
    #[cfg(not(unix))]
    let _ = path;
}

fn timestamp_label(created_at: i64) -> String {
    chrono::DateTime::<chrono::Utc>::from_timestamp(created_at, 0)
        .map(|date| date.format("%Y%m%d-%H%M%S").to_string())
        .unwrap_or_else(|| created_at.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::collections::BTreeMap;

    const PASSWORD: &str = "correct horse battery staple";
    const ACCESS_TOKEN: &str = "eyJhbGciOiJSUzI1NiJ9.SECRET-ACCESS-TOKEN-abcdef123456.signature";
    const REFRESH_TOKEN: &str = "refresh-token-SECRET-0987654321";
    const API_KEY: &str = "sk-live-api-key-SECRET";
    const MANAGEMENT_SECRET: &str = "melon-mgmt-live-secret";
    const CREATED_AT: i64 = 1_760_000_000;

    struct TestDir {
        root: PathBuf,
        paths: BackupPaths,
    }

    impl Drop for TestDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    fn test_dir(label: &str) -> TestDir {
        let root = std::env::temp_dir().join(format!(
            "melon-backup-test-{}-{}",
            label,
            scheduler::new_uuid()
        ));
        let paths = BackupPaths {
            support: root.join("support"),
            destination: root.join("downloads"),
        };
        fs::create_dir_all(&paths.support).unwrap();
        TestDir { root, paths }
    }

    fn write_json(path: &Path, value: &Value) {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        fs::write(path, serde_json::to_string_pretty(value).unwrap()).unwrap();
    }

    fn seed_support(paths: &BackupPaths) {
        let store = scheduler::Store {
            tasks: vec![scheduler::Task {
                id: "task-1".to_string(),
                name: "Daily".to_string(),
                prompt: "ping".to_string(),
                model: "gpt-test".to_string(),
                ..Default::default()
            }],
            history: vec![scheduler::HistoryEntry {
                task_id: "task-1".to_string(),
                at: 1_759_000_000,
                status: "ok".to_string(),
                model: "gpt-test".to_string(),
                result: "pong".to_string(),
                ..Default::default()
            }],
        };
        scheduler::save_raw_at(&paths.scheduler_path(), &serde_json::to_value(&store).unwrap())
            .unwrap();

        vault::save_raw_at(
            &paths.vault_path(),
            &json!({
                "accounts": [{
                    "id": "acc-1",
                    "email": "user@example.com",
                    "tokens": {
                        "access_token": ACCESS_TOKEN,
                        "refresh_token": REFRESH_TOKEN,
                        "account_id": "chatgpt-account",
                    }
                }],
                "currentAccountId": "acc-1",
            }),
        )
        .unwrap();

        settings::save_to(
            &paths.settings_path(),
            &settings::Settings {
                port: 19000,
                api_key: API_KEY.to_string(),
                lang: "en".to_string(),
                management_secret: MANAGEMENT_SECRET.to_string(),
                ..Default::default()
            },
        )
        .unwrap();

        write_json(
            &paths.auths_dir().join("codex-user.json"),
            &json!({"access_token": "auth-file-SECRET", "type": "codex"}),
        );
        write_json(
            &paths.model_sources_path(),
            &json!({"sources": [{"id": "openrouter"}]}),
        );

        // Decoys that must never enter the backup.
        write_json(
            &paths.support.join("gateway").join("config.yaml"),
            &json!({"api-key": "melon-gateway-key-SECRET"}),
        );
        write_json(
            &paths.auths_dir().join("broken.json"),
            &json!("not an object"),
        );
        fs::write(
            &paths.auths_dir().join("codex.lock"),
            "melon-gateway-key-SECRET",
        )
        .unwrap();
        fs::write(
            paths.support.join("gateway").join("gateway.log"),
            "log line",
        )
        .unwrap();
    }

    fn export_content(paths: &BackupPaths) -> String {
        let result = export_to(paths, PASSWORD, CREATED_AT).unwrap();
        fs::read_to_string(result["path"].as_str().unwrap()).unwrap()
    }

    fn snapshot(root: &Path) -> BTreeMap<PathBuf, Vec<u8>> {
        fn walk(root: &Path, dir: &Path, out: &mut BTreeMap<PathBuf, Vec<u8>>) {
            let Ok(entries) = fs::read_dir(dir) else {
                return;
            };
            for entry in entries.flatten() {
                let path = entry.path();
                let Ok(metadata) = fs::symlink_metadata(&path) else {
                    continue;
                };
                if metadata.is_dir() {
                    walk(root, &path, out);
                } else if metadata.is_file() {
                    if let Ok(bytes) = fs::read(&path) {
                        let relative = path.strip_prefix(root).unwrap().to_path_buf();
                        out.insert(relative, bytes);
                    }
                }
            }
        }
        let mut out = BTreeMap::new();
        walk(root, root, &mut out);
        out
    }

    fn changed_live_files(paths: &BackupPaths) {
        scheduler::save_raw_at(
            &paths.scheduler_path(),
            &json!({"tasks": [], "history": []}),
        )
        .unwrap();
        vault::save_raw_at(
            &paths.vault_path(),
            &json!({"accounts": [], "currentAccountId": Value::Null}),
        )
        .unwrap();
        settings::save_to(
            &paths.settings_path(),
            &settings::Settings {
                port: 19999,
                api_key: "changed-api-key".to_string(),
                lang: "ru".to_string(),
                management_secret: "changed-management-secret".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        write_json(
            &paths.auths_dir().join("codex-user.json"),
            &json!({"access_token": "changed"}),
        );
    }

    #[test]
    fn export_import_round_trip_restores_every_component() {
        let dir = test_dir("roundtrip");
        seed_support(&dir.paths);

        let exported = export_to(&dir.paths, PASSWORD, CREATED_AT).unwrap();
        let path = PathBuf::from(exported["path"].as_str().unwrap());
        assert!(path.starts_with(&dir.paths.destination), "{}", path.display());
        let backup = fs::read(&path).unwrap();
        assert_eq!(exported["bytes"].as_i64().unwrap(), backup.len() as i64);
        assert_eq!(exported["createdAt"], CREATED_AT);
        assert_eq!(read_last_backup_at(&dir.paths), Some(CREATED_AT));

        let envelope: Value = serde_json::from_slice(&backup).unwrap();
        assert_eq!(envelope["format"], FORMAT);
        assert_eq!(envelope["formatVersion"], FORMAT_VERSION);
        assert_eq!(envelope["appVersion"], "2.3.1");
        assert_eq!(envelope["createdAt"], CREATED_AT);
        assert_eq!(envelope["kdf"]["name"], KDF_NAME);
        assert_eq!(envelope["kdf"]["iterations"], ITERATIONS);
        assert_eq!(envelope["cipher"]["name"], CIPHER_NAME);
        let salt = base64::engine::general_purpose::STANDARD
            .decode(envelope["kdf"]["salt"].as_str().unwrap())
            .unwrap();
        let nonce = base64::engine::general_purpose::STANDARD
            .decode(envelope["cipher"]["nonce"].as_str().unwrap())
            .unwrap();
        let combined = base64::engine::general_purpose::STANDARD
            .decode(envelope["payload"].as_str().unwrap())
            .unwrap();
        assert_eq!(salt.len(), SALT_LEN);
        assert_eq!(nonce.len(), NONCE_LEN);
        assert!(combined.len() > TAG_LEN);

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(&path).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }

        // Change every live component and add an unrelated auth file.
        changed_live_files(&dir.paths);
        write_json(
            &dir.paths.auths_dir().join("claude-keep.json"),
            &json!({"keep": true}),
        );
        write_json(
            &dir.paths.model_sources_path(),
            &json!({"sources": [{"id": "changed"}]}),
        );

        let content = fs::read_to_string(&path).unwrap();
        let summary = import_into(&dir.paths, &content, PASSWORD).unwrap();
        assert_eq!(summary["schedulerTasks"], 1);
        assert_eq!(summary["schedulerHistory"], 1);
        assert_eq!(summary["accounts"], 1);
        assert_eq!(summary["authFiles"], 1);
        assert_eq!(summary["modelSourcesIncluded"], true);
        assert!(summary["settingsKeys"].as_u64().unwrap() > 0);

        let raw = scheduler::load_raw_at(&dir.paths.scheduler_path()).unwrap();
        assert_eq!(raw["tasks"][0]["name"], "Daily");
        assert_eq!(raw["history"][0]["result"], "pong");

        let restored_vault = vault::load_raw_at(&dir.paths.vault_path());
        assert_eq!(
            restored_vault["accounts"][0]["tokens"]["access_token"],
            ACCESS_TOKEN
        );
        assert_eq!(
            restored_vault["accounts"][0]["tokens"]["refresh_token"],
            REFRESH_TOKEN
        );

        let restored_settings = settings::load_from(&dir.paths.settings_path());
        assert_eq!(restored_settings.port, 19000);
        // Gateway secrets are machine-local and survive a restore.
        assert_eq!(restored_settings.api_key, "changed-api-key");
        assert_eq!(restored_settings.management_secret, "changed-management-secret");
        assert_eq!(restored_settings.lang, "en");

        let auth = fs::read_to_string(dir.paths.auths_dir().join("codex-user.json")).unwrap();
        assert!(auth.contains("auth-file-SECRET"));
        // Unrelated auths survive the import.
        let unrelated = fs::read_to_string(dir.paths.auths_dir().join("claude-keep.json")).unwrap();
        assert!(unrelated.contains("keep"));
        // Invalid source decoys are not imported, but unrelated live files are
        // deliberately preserved.
        assert!(dir.paths.auths_dir().join("broken.json").exists());

        let model_sources = fs::read_to_string(dir.paths.model_sources_path()).unwrap();
        assert!(model_sources.contains("openrouter"));
    }

    #[test]
    fn exported_bytes_contain_no_plaintext_secrets() {
        let dir = test_dir("no-plaintext");
        seed_support(&dir.paths);
        let content = export_content(&dir.paths);

        for secret in [ACCESS_TOKEN, REFRESH_TOKEN, API_KEY, MANAGEMENT_SECRET, PASSWORD] {
            assert!(
                !content.contains(secret),
                "plaintext secret leaked into backup: {secret}"
            );
        }
        // The payload is encrypted, not merely base64 of JSON.
        let envelope: Value = serde_json::from_str(&content).unwrap();
        let combined = base64::engine::general_purpose::STANDARD
            .decode(envelope["payload"].as_str().unwrap())
            .unwrap();
        let haystack = String::from_utf8_lossy(&combined);
        assert!(!haystack.contains("access_token"));
        assert!(!haystack.contains("user@example.com"));
    }

    #[test]
    fn wrong_password_leaves_live_files_unchanged() {
        let dir = test_dir("wrong-password");
        seed_support(&dir.paths);
        let content = export_content(&dir.paths);
        changed_live_files(&dir.paths);
        let before = snapshot(&dir.root);

        let error = import_into(&dir.paths, &content, "wrong password").unwrap_err();
        assert!(error.contains("неверный пароль"), "{error}");
        assert_eq!(snapshot(&dir.root), before);
    }

    #[test]
    fn malformed_and_unsupported_envelopes_leave_live_files_unchanged() {
        let dir = test_dir("malformed");
        seed_support(&dir.paths);
        let content = export_content(&dir.paths);
        changed_live_files(&dir.paths);
        let before = snapshot(&dir.root);

        let error = import_into(&dir.paths, "not json at all", PASSWORD).unwrap_err();
        assert!(error.contains("не файл резервной копии"), "{error}");
        assert_eq!(snapshot(&dir.root), before);

        let mut envelope: Value = serde_json::from_str(&content).unwrap();
        envelope["format"] = json!("another-format");
        let error = import_into(&dir.paths, &envelope.to_string(), PASSWORD).unwrap_err();
        assert!(error.contains("unsupported backup format"), "{error}");
        assert_eq!(snapshot(&dir.root), before);

        let mut envelope: Value = serde_json::from_str(&content).unwrap();
        envelope["formatVersion"] = json!(99);
        let error = import_into(&dir.paths, &envelope.to_string(), PASSWORD).unwrap_err();
        assert!(error.contains("unsupported backup format version 99"), "{error}");
        assert_eq!(snapshot(&dir.root), before);

        let mut envelope: Value = serde_json::from_str(&content).unwrap();
        envelope["kdf"]["iterations"] = json!(1_000);
        let error = import_into(&dir.paths, &envelope.to_string(), PASSWORD).unwrap_err();
        assert!(error.contains("параметры шифрования"), "{error}");
        assert_eq!(snapshot(&dir.root), before);

        // A valid envelope with a payload that is not a JSON object fails
        // after decryption but still before the first live write.
        let bad_payload = seal(b"[]", PASSWORD, CREATED_AT).unwrap();
        let error = import_into(&dir.paths, &bad_payload, PASSWORD).unwrap_err();
        assert!(error.contains("payload is damaged"), "{error}");
        assert_eq!(snapshot(&dir.root), before);
    }

    #[test]
    fn auth_filename_traversal_is_rejected() {
        let dir = test_dir("traversal");
        seed_support(&dir.paths);
        let before = snapshot(&dir.root);

        let payload = json!({
            "scheduler": {"tasks": [], "history": []},
            "auths": {
                "safe.json": {"access_token": "safe"},
                "../escape.json": {"access_token": "evil"},
            },
        });
        let data = serde_json::to_vec(&payload).unwrap();
        let content = seal(&data, PASSWORD, CREATED_AT).unwrap();

        let error = import_into(&dir.paths, &content, PASSWORD).unwrap_err();
        assert!(error.contains("unsafe backup file name"), "{error}");
        assert_eq!(snapshot(&dir.root), before);
        assert!(!dir.paths.support.join("escape.json").exists());
        assert!(!dir.paths.support.join("gateway").join("escape.json").exists());
        assert!(!dir.paths.auths_dir().join("escape.json").exists());
        // Even the safe sibling is not written when another name is unsafe.
        assert!(!dir.paths.auths_dir().join("safe.json").exists());
    }

    #[test]
    fn export_never_overwrites_an_existing_backup() {
        let dir = test_dir("no-overwrite");
        seed_support(&dir.paths);

        let first = export_to(&dir.paths, PASSWORD, CREATED_AT).unwrap();
        let second = export_to(&dir.paths, PASSWORD, CREATED_AT).unwrap();
        let first_path = PathBuf::from(first["path"].as_str().unwrap());
        let second_path = PathBuf::from(second["path"].as_str().unwrap());
        assert_ne!(first_path, second_path);
        assert!(first_path.exists());
        assert!(second_path.exists());
    }

    #[test]
    fn pbkdf2_matches_the_macos_reference_vector() {
        let key = derive_key("melon-tools-test", b"0123456789abcdef", 210_000);
        let hex: String = key
            .as_slice()
            .iter()
            .map(|byte| format!("{:02x}", byte))
            .collect();
        assert_eq!(
            hex,
            "381d4dfbe8e6687fab5beab3ae936d2b1c7f9fa082552ac90842cc2da2578eba"
        );
    }
}
