//! Quota history for the UI sparklines, plus the persisted low-quota
//! notification bookkeeping.
//!
//! The file lives next to the vault (`%APPDATA%\MelonTools\quota-history.json`)
//! and is written atomically. Samples are capped per key so the file stays
//! small: 288 samples cover 24 hours at the default 5-minute quota cadence.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;

use crate::paths;

/// Samples kept per account id / provider id.
pub const MAX_SAMPLES: usize = 288;

#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct Sample {
    /// Unix seconds.
    pub timestamp: f64,
    /// Remaining share of the window (0…100); `None` when unavailable.
    pub hourly_left: Option<f64>,
    pub weekly_left: Option<f64>,
    /// `codex`, `claude` or `openrouter`.
    pub provider: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct NotifiedState {
    /// Unix seconds of the last notification.
    pub at: i64,
    /// Reset timestamp (Apple reference date) identifying the quota window.
    pub window: Option<f64>,
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct History {
    pub version: u32,
    pub samples: BTreeMap<String, Vec<Sample>>,
    /// `<account id>:<window>` → last notification. Never exposed over IPC.
    pub notified: BTreeMap<String, NotifiedState>,
}

pub fn path() -> std::path::PathBuf {
    paths::appdata_dir().join("quota-history.json")
}

/// Append one sample and keep only the newest `cap` samples for the key.
pub fn append_sample(history: &mut History, key: &str, sample: Sample, cap: usize) {
    let cap = cap.max(1);
    let samples = history.samples.entry(key.to_string()).or_default();
    samples.push(sample);
    let excess = samples.len().saturating_sub(cap);
    if excess > 0 {
        samples.drain(0..excess);
    }
}

pub fn serialize(history: &History) -> Result<String, String> {
    serde_json::to_string_pretty(history).map_err(|e| e.to_string())
}

/// Malformed or missing files degrade to an empty history instead of
/// discarding the next sample.
pub fn parse(raw: &str) -> History {
    serde_json::from_str(raw).unwrap_or_default()
}

pub fn load() -> History {
    std::fs::read_to_string(path())
        .ok()
        .map(|raw| parse(&raw))
        .unwrap_or_default()
}

fn save(history: &History) -> Result<(), String> {
    let dir = paths::appdata_dir();
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let data = serialize(history)?;
    let path = path();
    let tmp = paths::tmp_path(&path);
    std::fs::write(&tmp, data).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, &path).map_err(|e| e.to_string())
}

static HISTORY_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn lock() -> std::sync::MutexGuard<'static, ()> {
    HISTORY_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Record a successful refresh. Errors are swallowed on purpose: history is a
/// convenience and must never turn a good quota refresh into a failure.
pub fn record(key: &str, provider: &str, hourly_left: Option<f64>, weekly_left: Option<f64>) {
    let sample = Sample {
        timestamp: chrono::Utc::now().timestamp_millis() as f64 / 1000.0,
        hourly_left,
        weekly_left,
        provider: provider.to_string(),
    };
    let _guard = lock();
    let mut history = load();
    history.version = 1;
    append_sample(&mut history, key, sample, MAX_SAMPLES);
    let _ = save(&history);
}

/// Flat renderer payload: one object per sample, with the owning key.
pub fn samples_json(history: &History) -> Vec<Value> {
    let mut out = Vec::new();
    for (key, samples) in &history.samples {
        for sample in samples {
            out.push(json!({
                "key": key,
                "timestamp": sample.timestamp,
                "hourlyLeft": sample.hourly_left,
                "weeklyLeft": sample.weekly_left,
                "provider": sample.provider,
            }));
        }
    }
    out
}

pub fn ipc_samples() -> Vec<Value> {
    samples_json(&load())
}

/// Decide whether a refreshed window should notify.
///
/// A crossing means "was above the threshold before this refresh and is at or
/// below it now". A first reading counts as a crossing because there is no
/// earlier sample to compare with. Once a window has notified, the persisted
/// reset timestamp suppresses repeats until that timestamp changes; without a
/// reset timestamp the cooldown applies.
pub fn should_notify(
    previous: Option<f64>,
    current: Option<f64>,
    threshold: f64,
    window: Option<f64>,
    state: Option<&NotifiedState>,
    now: i64,
    cooldown: i64,
) -> bool {
    let Some(current) = current else {
        return false;
    };
    if current > threshold {
        return false;
    }
    let crossed = previous
        .map(|value| value > threshold)
        .unwrap_or(true);
    if !crossed {
        return false;
    }
    let Some(state) = state else {
        return true;
    };
    match window {
        Some(window) => state.window != Some(window),
        None => now.saturating_sub(state.at) >= cooldown,
    }
}

/// Pure claim helper: record the notification when `should_notify` says yes.
fn claim_in(
    history: &mut History,
    key: &str,
    previous: Option<f64>,
    current: Option<f64>,
    threshold: f64,
    window: Option<f64>,
    now: i64,
    cooldown: i64,
) -> bool {
    let state = history.notified.get(key);
    if !should_notify(previous, current, threshold, window, state, now, cooldown) {
        return false;
    }
    history.notified.insert(
        key.to_string(),
        NotifiedState {
            at: now,
            window,
        },
    );
    true
}

/// Atomically claim a low-quota notification for the current window.
pub fn claim_notification(
    key: &str,
    previous: Option<f64>,
    current: Option<f64>,
    threshold: f64,
    window: Option<f64>,
    now: i64,
    cooldown: i64,
) -> Result<bool, String> {
    let _guard = lock();
    let mut history = load();
    let claimed = claim_in(
        &mut history,
        key,
        previous,
        current,
        threshold,
        window,
        now,
        cooldown,
    );
    if claimed {
        save(&history)?;
    }
    Ok(claimed)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(timestamp: f64) -> Sample {
        Sample {
            timestamp,
            hourly_left: Some(50.0),
            weekly_left: Some(75.0),
            provider: "codex".to_string(),
        }
    }

    #[test]
    fn append_caps_per_key_and_keeps_the_newest() {
        let mut history = History::default();
        for index in 0..300 {
            append_sample(&mut history, "account-a", sample(index as f64), 288);
        }
        append_sample(&mut history, "account-b", sample(1.0), 288);

        let account = &history.samples["account-a"];
        assert_eq!(account.len(), 288);
        assert_eq!(account.first().unwrap().timestamp, 12.0);
        assert_eq!(account.last().unwrap().timestamp, 299.0);
        assert_eq!(history.samples["account-b"].len(), 1);
    }

    #[test]
    fn serialization_roundtrip_keeps_samples_and_notified_state() {
        let mut history = History::default();
        history.version = 1;
        append_sample(
            &mut history,
            "account-a",
            Sample {
                timestamp: 123.5,
                hourly_left: Some(42.0),
                weekly_left: None,
                provider: "codex".to_string(),
            },
            288,
        );
        history.notified.insert(
            "account-a:5h".to_string(),
            NotifiedState {
                at: 100,
                window: Some(55.0),
            },
        );

        let raw = serialize(&history).unwrap();
        let parsed = parse(&raw);
        assert_eq!(parsed.version, 1);
        assert_eq!(parsed.samples["account-a"][0].hourly_left, Some(42.0));
        assert!(parsed.samples["account-a"][0].weekly_left.is_none());
        assert_eq!(parsed.notified["account-a:5h"].window, Some(55.0));
        assert!(raw.contains("\"hourlyLeft\""));
        assert!(!raw.contains("\"hourly_left\""));
    }

    #[test]
    fn malformed_history_degrades_to_empty() {
        let history = parse("{not json");
        assert!(history.samples.is_empty());
        assert!(history.notified.is_empty());
    }

    #[test]
    fn ipc_samples_flatten_keys_and_use_camel_case() {
        let mut history = History::default();
        append_sample(&mut history, "account-a", sample(10.0), 288);
        append_sample(&mut history, "claude", sample(20.0), 288);

        let values = samples_json(&history);
        assert_eq!(values.len(), 2);
        assert_eq!(values[0]["key"], "account-a");
        assert_eq!(values[0]["hourlyLeft"], 50.0);
        assert_eq!(values[0]["weeklyLeft"], 75.0);
        assert_eq!(values[0]["provider"], "codex");
        assert_eq!(values[1]["key"], "claude");
        assert!(values[1].get("weeklyLeft").is_some());
    }

    #[test]
    fn notification_requires_a_crossing_and_rearms_per_window() {
        let threshold = 10.0;
        assert!(!should_notify(
            Some(50.0),
            Some(20.0),
            threshold,
            Some(1.0),
            None,
            100,
            3600
        ));
        assert!(should_notify(
            Some(50.0),
            Some(10.0),
            threshold,
            Some(1.0),
            None,
            100,
            3600
        ));
        // Already below before the refresh: not a crossing.
        assert!(!should_notify(
            Some(4.0),
            Some(3.0),
            threshold,
            Some(1.0),
            None,
            100,
            3600
        ));

        let state = NotifiedState {
            at: 100,
            window: Some(1.0),
        };
        assert!(!should_notify(
            Some(50.0),
            Some(10.0),
            threshold,
            Some(1.0),
            Some(&state),
            100,
            3600
        ));
        assert!(should_notify(
            Some(50.0),
            Some(9.0),
            threshold,
            Some(2.0),
            Some(&state),
            100,
            3600
        ));

        // Without a reset timestamp, the cooldown is authoritative.
        let no_window = NotifiedState {
            at: 100,
            window: None,
        };
        assert!(!should_notify(
            None,
            Some(9.0),
            threshold,
            None,
            Some(&no_window),
            100,
            3600
        ));
        assert!(should_notify(
            None,
            Some(9.0),
            threshold,
            None,
            Some(&no_window),
            3700,
            3600
        ));
    }

    #[test]
    fn claim_records_once_per_window() {
        let mut history = History::default();
        assert!(claim_in(
            &mut history,
            "account-a:5h",
            Some(50.0),
            Some(8.0),
            10.0,
            Some(1.0),
            100,
            3600
        ));
        assert!(!claim_in(
            &mut history,
            "account-a:5h",
            Some(50.0),
            Some(7.0),
            10.0,
            Some(1.0),
            200,
            3600
        ));
        assert!(claim_in(
            &mut history,
            "account-a:5h",
            Some(50.0),
            Some(6.0),
            10.0,
            Some(2.0),
            300,
            3600
        ));
        assert_eq!(history.notified["account-a:5h"].window, Some(2.0));
        assert_eq!(history.notified["account-a:5h"].at, 300);
    }
}
