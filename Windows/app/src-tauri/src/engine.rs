//! The gateway engine, embedded in the app.
//!
//! The app ships as a single executable: the zlib-compressed CLIProxyAPI
//! engine is a byte array inside the binary and is extracted into the data
//! directory on first run (and after an app update). Everything the user
//! sees is one file — no separate engine to keep next to the app.

use std::io::Write;
use std::path::PathBuf;

use crate::paths;

/// Bumped with each release that ships a new engine build: the extracted
/// copy is refreshed when this differs from `engine.version` on disk.
const ENGINE_VERSION: &str = "1.4.6";

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

/// The extraction runs once per process: the result (success or failure) is
/// cached, so a failing extract never retries a 68 MB decompress on every
/// status poll.
static EXTRACTED: std::sync::OnceLock<Result<PathBuf, String>> = std::sync::OnceLock::new();

/// Extracts the embedded engine when missing or from an older app version.
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
        return Ok(path);
    }

    let mut decoder = flate2::read::ZlibDecoder::new(ENGINE_PAYLOAD);
    let tmp = dir.join("cliproxyapi.exe.tmp");
    {
        let mut out = std::fs::File::create(&tmp).map_err(|e| e.to_string())?;
        std::io::copy(&mut decoder, &mut out).map_err(|e| e.to_string())?;
        out.flush().map_err(|e| e.to_string())?;
    }

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
            let _ = std::fs::write(version_path(), ENGINE_VERSION);
            return Ok(fallback);
        }
    }
    std::fs::write(version_path(), ENGINE_VERSION).map_err(|e| e.to_string())?;
    Ok(path)
}
