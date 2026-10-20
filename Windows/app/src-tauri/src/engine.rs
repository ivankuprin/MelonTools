//! The gateway engine, embedded in the app.
//!
//! The app ships as a single executable: the zlib-compressed CLIProxyAPI
//! engine is a byte array inside the binary and is extracted into the data
//! directory on first run (and after an app update). Everything the user
//! sees is one file — no separate engine to keep next to the app.
//!
//! Extraction records the SHA256 of the payload in `engine.sha256`. Adoption
//! re-hashes the existing binary and re-extracts on any mismatch, so a
//! tampered or partially written engine is never executed.

use std::io::Write;
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

use crate::paths;

/// Pinned engine commit id: the extraction cache key. A release that ships a
/// different payload must change this value, otherwise the old extraction is
/// (correctly) distrusted by the hash check below.
const ENGINE_VERSION: &str = "e7003d2a";

static ENGINE_PAYLOAD: &[u8] = include_bytes!("../../resources/cliproxyapi.exe.z");

pub fn engine_dir() -> PathBuf {
    paths::appdata_dir().join("engine")
}

pub fn engine_path() -> PathBuf {
    engine_dir().join("cliproxyapi.exe")
}

fn version_path() -> PathBuf {
    engine_dir().join("engine.version")
}

fn hash_path() -> PathBuf {
    engine_dir().join("engine.sha256")
}

/// SHA256 of a file, streamed in 64 KiB chunks (the engine is large).
fn sha256_file(path: &Path) -> Result<String, String> {
    use std::io::Read;

    let mut file = std::fs::File::open(path).map_err(|e| e.to_string())?;
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer).map_err(|e| e.to_string())?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

/// True only for a full 64-hex SHA256 that matches the actual digest. The
/// recorded value may carry a trailing newline; comparison is case-insensitive.
pub(crate) fn checksum_matches(recorded: &str, actual: &str) -> bool {
    let recorded = recorded.trim();
    let actual = actual.trim();
    recorded.len() == 64
        && actual.len() == 64
        && recorded.chars().all(|c| c.is_ascii_hexdigit())
        && actual.chars().all(|c| c.is_ascii_hexdigit())
        && recorded.eq_ignore_ascii_case(actual)
}

/// The extraction runs once per process: the result (success or failure) is
/// cached, so a failing extract never retries a 68 MB decompress on every
/// status poll.
static EXTRACTED: std::sync::OnceLock<Result<PathBuf, String>> = std::sync::OnceLock::new();

/// Extracts the embedded engine when missing, from an older app version, or
/// when the extracted binary no longer matches the recorded payload hash.
/// Returns the path to a runnable executable.
pub fn ensure_engine() -> Result<PathBuf, String> {
    EXTRACTED.get_or_init(extract_engine).clone()
}

fn extract_engine() -> Result<PathBuf, String> {
    let dir = engine_dir();
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let path = engine_path();
    let current = std::fs::read_to_string(version_path()).unwrap_or_default();
    if current.trim() == ENGINE_VERSION && path.exists() {
        let recorded = std::fs::read_to_string(hash_path()).unwrap_or_default();
        if let Ok(actual) = sha256_file(&path) {
            if checksum_matches(&recorded, &actual) {
                return Ok(path);
            }
        }
        // Hash missing or different: a partial/tampered extraction. Fall
        // through and overwrite it from the embedded payload.
    }

    let mut decoder = flate2::read::ZlibDecoder::new(ENGINE_PAYLOAD);
    let tmp = dir.join("cliproxyapi.exe.tmp");
    {
        let mut out = std::fs::File::create(&tmp).map_err(|e| e.to_string())?;
        std::io::copy(&mut decoder, &mut out).map_err(|e| e.to_string())?;
        out.flush().map_err(|e| e.to_string())?;
    }
    let digest = sha256_file(&tmp)?;

    if std::fs::rename(&tmp, &path).is_err() {
        if std::fs::remove_file(&path).is_ok() {
            std::fs::rename(&tmp, &path).map_err(|e| e.to_string())?;
        } else {
            // The previous engine is still running from the target path
            // (a crash left it behind): keep the fresh extraction instead.
            let fallback = dir.join(format!(
                "cliproxyapi-{}.exe",
                ENGINE_VERSION.replace('.', "_")
            ));
            std::fs::rename(&tmp, &fallback).map_err(|e| e.to_string())?;
            write_provenance(&digest)?;
            return Ok(fallback);
        }
    }
    write_provenance(&digest)?;
    Ok(path)
}

/// Records the extraction identity after the binary is in place: the hash
/// first, then the version, so a crash in between never marks an unverified
/// binary as adopted.
fn write_provenance(digest: &str) -> Result<(), String> {
    std::fs::write(hash_path(), digest).map_err(|e| e.to_string())?;
    std::fs::write(version_path(), ENGINE_VERSION).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::{checksum_matches, sha256_file, ENGINE_VERSION};

    const EMPTY_SHA256: &str = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

    #[test]
    fn engine_version_is_the_pinned_commit() {
        assert_eq!(ENGINE_VERSION, "e7003d2a");
    }

    #[test]
    fn hash_comparison_requires_full_hex_and_ignores_case() {
        assert!(checksum_matches(EMPTY_SHA256, EMPTY_SHA256));
        assert!(checksum_matches(
            &format!("{}\n", EMPTY_SHA256),
            &EMPTY_SHA256.to_uppercase()
        ));
        assert!(!checksum_matches("", EMPTY_SHA256));
        assert!(!checksum_matches(&EMPTY_SHA256[..63], &EMPTY_SHA256[..63]));
        assert!(!checksum_matches(EMPTY_SHA256, &"f".repeat(64)));
        assert!(!checksum_matches(&"z".repeat(64), &"z".repeat(64)));
    }

    #[test]
    fn file_hash_matches_the_known_empty_vector() {
        let path = std::env::temp_dir().join(format!(
            "melontools-engine-hash-{}.bin",
            std::process::id()
        ));
        std::fs::write(&path, b"").unwrap();
        let digest = sha256_file(&path).unwrap();
        let _ = std::fs::remove_file(&path);
        assert_eq!(digest, EMPTY_SHA256);
    }
}
