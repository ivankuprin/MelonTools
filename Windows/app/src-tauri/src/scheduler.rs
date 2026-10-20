//! Scheduler: a persisted task list plus the serial in-process runner.
//!
//! Tasks live in `%APPDATA%\MelonTools\scheduler.json` (atomic tmp+rename).
//! A due task is sent to the local gateway as one chat completion; nothing is
//! spawned outside the app process, so a closed app never runs anything.

use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::{gateway, paths, settings};

/// How often the runner looks for a due task.
pub const TICK_SECS: u64 = 30;
/// A single completion must not keep the runner busy forever.
pub const RUN_TIMEOUT_SECS: u64 = 300;
/// `lastResult` and history `result` cap (bytes).
pub const RESULT_CAP: usize = 64 * 1024;
/// Newest history entries kept per task.
pub const HISTORY_PER_TASK: usize = 20;
/// Newest history entries kept overall.
pub const HISTORY_GLOBAL: usize = 200;
/// One week is a sane upper bound; anything longer is a typo.
pub const MAX_INTERVAL_MINUTES: i64 = 7 * 24 * 60;
pub const EFFORTS: [&str; 5] = ["low", "medium", "high", "xhigh", "max"];

/// 500 ms polls while a "Run now" waits for the scheduled run to finish.
const WAIT_ATTEMPTS: u64 = RUN_TIMEOUT_SECS * 4;

pub fn now_secs() -> i64 {
    chrono::Utc::now().timestamp()
}

pub fn path() -> PathBuf {
    paths::appdata_dir().join("scheduler.json")
}

// MARK: - Models

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct Task {
    pub id: String,
    pub name: String,
    pub prompt: String,
    pub model: String,
    pub reasoning_effort: Option<String>,
    pub interval_minutes: i64,
    pub enabled: bool,
    pub created_at: i64,
    pub next_run_at: Option<i64>,
    pub last_run_at: Option<i64>,
    pub last_status: String,
    pub last_error: Option<String>,
    pub last_result: String,
    pub last_duration_ms: Option<i64>,
    pub last_tokens: Option<i64>,
}

impl Default for Task {
    fn default() -> Self {
        Self {
            id: String::new(),
            name: String::new(),
            prompt: String::new(),
            model: String::new(),
            reasoning_effort: None,
            interval_minutes: 60,
            enabled: true,
            created_at: 0,
            next_run_at: None,
            last_run_at: None,
            last_status: "never".to_string(),
            last_error: None,
            last_result: String::new(),
            last_duration_ms: None,
            last_tokens: None,
        }
    }
}

#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct HistoryEntry {
    pub task_id: String,
    pub at: i64,
    pub status: String,
    pub model: String,
    pub duration_ms: Option<i64>,
    pub tokens: Option<i64>,
    pub result: String,
    pub error: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct Store {
    pub tasks: Vec<Task>,
    pub history: Vec<HistoryEntry>,
}

/// Renderer payload for create/update. An empty `id` creates a task.
#[derive(Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase", default)]
pub struct TaskInput {
    pub id: Option<String>,
    pub name: String,
    pub prompt: String,
    pub model: String,
    pub reasoning_effort: Option<String>,
    pub interval_minutes: i64,
    pub enabled: bool,
}

impl Default for TaskInput {
    fn default() -> Self {
        Self {
            id: None,
            name: String::new(),
            prompt: String::new(),
            model: String::new(),
            reasoning_effort: None,
            interval_minutes: 60,
            enabled: true,
        }
    }
}

/// Validated create/update payload: the DB layer must never see half a task.
struct Validated {
    id: Option<String>,
    name: String,
    prompt: String,
    model: String,
    effort: Option<String>,
    interval_minutes: i64,
    enabled: bool,
}

/// One completed (or failed) run.
#[derive(Serialize, Clone, Debug, Default, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Outcome {
    /// `ok` or `error`.
    pub status: String,
    pub result: String,
    pub error: Option<String>,
    pub duration_ms: i64,
    pub tokens: Option<i64>,
}

// MARK: - Persistence

pub fn load() -> Store {
    load_from(&path())
}

fn load_from(target: &std::path::Path) -> Store {
    let mut store: Store = std::fs::read_to_string(target)
        .ok()
        .and_then(|raw| serde_json::from_str(&raw).ok())
        .unwrap_or_default();
    let now = now_secs();
    clamp_store(&mut store);
    for task in &mut store.tasks {
        // Writing "running" then dying leaves a stuck status; the process that
        // owned it is gone, so the read view must not claim it still runs.
        if task.last_status == "running" {
            task.last_status = "error".to_string();
        }
        if task.enabled && task.next_run_at.is_none() {
            task.next_run_at = Some(next_after_run(now, task.interval_minutes));
        }
    }
    store
}

pub fn save(store: &Store) -> Result<(), String> {
    save_to(&path(), store)
}

fn save_to(target: &std::path::Path, store: &Store) -> Result<(), String> {
    if let Some(dir) = target.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let mut clean = store.clone();
    clamp_store(&mut clean);
    let data = serde_json::to_string_pretty(&clean).map_err(|e| e.to_string())?;
    let tmp = paths::tmp_path(target);
    std::fs::write(&tmp, data).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, target).map_err(|e| e.to_string())
}

/// Caps and clamps that every read and write must respect.
fn clamp_store(store: &mut Store) {
    store.tasks.retain(|task| !task.id.trim().is_empty());
    for task in &mut store.tasks {
        task.interval_minutes = task.interval_minutes.clamp(1, MAX_INTERVAL_MINUTES);
        task.last_result = truncate_result(&task.last_result);
        if !task.enabled {
            task.next_run_at = None;
        }
    }
    for entry in &mut store.history {
        entry.result = truncate_result(&entry.result);
    }
    trim_history(&mut store.history);
}

/// Newest 20 entries per task, newest 200 overall; the vector stays ordered
/// oldest → newest.
pub fn trim_history(history: &mut Vec<HistoryEntry>) {
    let mut per_task: std::collections::HashMap<String, usize> = std::collections::HashMap::new();
    let mut kept: Vec<HistoryEntry> = Vec::with_capacity(history.len().min(HISTORY_GLOBAL));
    for entry in history.drain(..).rev() {
        let count = per_task.entry(entry.task_id.clone()).or_insert(0);
        if *count < HISTORY_PER_TASK {
            *count += 1;
            kept.push(entry);
        }
    }
    kept.reverse();
    if kept.len() > HISTORY_GLOBAL {
        let drop = kept.len() - HISTORY_GLOBAL;
        kept.drain(..drop);
    }
    *history = kept;
}

/// Cut to [`RESULT_CAP`] bytes without splitting a UTF-8 sequence.
pub fn truncate_result(text: &str) -> String {
    if text.len() <= RESULT_CAP {
        return text.to_string();
    }
    let mut end = RESULT_CAP;
    while end > 0 && !text.is_char_boundary(end) {
        end -= 1;
    }
    text[..end].to_string()
}

// MARK: - Schedule decisions (clock injected)

pub fn next_after_run(now: i64, interval_minutes: i64) -> i64 {
    now + interval_minutes.clamp(1, MAX_INTERVAL_MINUTES) * 60
}

/// The single task to run now. Disabled tasks and future runs never qualify;
/// the caller runs one task per tick, so a long pause cannot produce a burst.
pub fn due_task(store: &Store, now: i64) -> Option<&Task> {
    store
        .tasks
        .iter()
        .find(|task| task.enabled && task.next_run_at.map(|at| at <= now).unwrap_or(false))
}

// MARK: - CRUD

pub fn view() -> Value {
    let store = load();
    json!({
        "path": path().to_string_lossy(),
        "tasks": store.tasks,
        "history": store.history,
    })
}

fn validate(input: &TaskInput) -> Result<Validated, String> {
    let name = input.name.trim();
    if name.is_empty() {
        return Err("укажите название задачи".to_string());
    }
    let prompt = input.prompt.trim();
    if prompt.is_empty() {
        return Err("укажите запрос задачи".to_string());
    }
    let model = input.model.trim();
    if model.is_empty() {
        return Err("выберите модель".to_string());
    }
    if input.interval_minutes < 1 || input.interval_minutes > MAX_INTERVAL_MINUTES {
        return Err(format!("интервал: от 1 до {} минут", MAX_INTERVAL_MINUTES));
    }
    let effort = match input
        .reasoning_effort
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        Some(value) if EFFORTS.contains(&value) => Some(value.to_string()),
        Some(value) => return Err(format!("неизвестный reasoning effort: {}", value)),
        None => None,
    };
    Ok(Validated {
        id: input
            .id
            .as_deref()
            .map(str::trim)
            .filter(|id| !id.is_empty())
            .map(str::to_string),
        name: name.to_string(),
        prompt: prompt.to_string(),
        model: model.to_string(),
        effort,
        interval_minutes: input.interval_minutes,
        enabled: input.enabled,
    })
}

/// Copy the edit into the task and decide the next run. Kept pure so the
/// scheduling rules are testable without touching the disk.
fn apply_input(task: &mut Task, input: &Validated, now: i64) {
    let schedule_changed =
        task.interval_minutes != input.interval_minutes || task.enabled != input.enabled;
    task.name = input.name.clone();
    task.prompt = input.prompt.clone();
    task.model = input.model.clone();
    task.reasoning_effort = input.effort.clone();
    task.interval_minutes = input.interval_minutes;
    task.enabled = input.enabled;
    if !task.enabled {
        // A disabled task has no schedule at all — re-enabling starts a fresh
        // interval instead of firing an overdue run immediately.
        task.next_run_at = None;
    } else if schedule_changed || task.next_run_at.is_none() {
        task.next_run_at = Some(next_after_run(now, input.interval_minutes));
    }
}

/// Create (empty `id`) or update a task and persist it.
pub fn upsert(input: TaskInput) -> Result<Value, String> {
    let valid = validate(&input)?;
    let now = now_secs();
    let mut store = load();
    let mut task = match valid.id.as_deref() {
        Some(id) => store
            .tasks
            .iter()
            .find(|task| task.id == id)
            .cloned()
            .ok_or_else(|| "задача не найдена".to_string())?,
        None => Task {
            id: new_uuid(),
            created_at: now,
            ..Task::default()
        },
    };
    apply_input(&mut task, &valid, now);
    match store.tasks.iter_mut().find(|slot| slot.id == task.id) {
        Some(slot) => *slot = task,
        None => store.tasks.push(task),
    }
    save(&store)?;
    Ok(view())
}

/// Remove the task and its history.
pub fn delete(id: &str) -> Result<Value, String> {
    let mut store = load();
    let before = store.tasks.len();
    store.tasks.retain(|task| task.id != id);
    if store.tasks.len() == before {
        return Err("задача не найдена".to_string());
    }
    store.history.retain(|entry| entry.task_id != id);
    save(&store)?;
    Ok(view())
}

// MARK: - Runner

/// Process-wide claim: exactly one completion runs at a time, whether the tick
/// or "Run now" started it.
static RUNNING: AtomicBool = AtomicBool::new(false);

struct RunGuard;

impl RunGuard {
    fn try_acquire() -> Option<RunGuard> {
        RUNNING
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .ok()
            .map(|_| RunGuard)
    }
}

impl Drop for RunGuard {
    fn drop(&mut self) {
        RUNNING.store(false, Ordering::SeqCst);
    }
}

/// `wait=false` skips a busy runner (the tick will retry in 30 s); `wait=true`
/// queues "Run now" behind the current run, bounded by twice the timeout.
async fn acquire(wait: bool) -> Option<RunGuard> {
    if let Some(guard) = RunGuard::try_acquire() {
        return Some(guard);
    }
    if !wait {
        return None;
    }
    for _ in 0..WAIT_ATTEMPTS {
        tokio::time::sleep(Duration::from_millis(500)).await;
        if let Some(guard) = RunGuard::try_acquire() {
            return Some(guard);
        }
    }
    None
}

/// One scheduler tick: at most one due task, serial with every other run.
pub async fn tick(settings: &settings::Settings) {
    let Some(_guard) = acquire(false).await else {
        return;
    };
    let store = load();
    let Some(task) = due_task(&store, now_secs()).cloned() else {
        return;
    };
    run_and_record(settings, &task).await;
}

/// "Run now" runs whatever the task state is (disabled included) and advances
/// the schedule; it waits for a scheduled run to finish first.
pub async fn run_now(settings: &settings::Settings, id: &str) -> Result<Value, String> {
    let task = load()
        .tasks
        .into_iter()
        .find(|task| task.id == id)
        .ok_or_else(|| "задача не найдена".to_string())?;
    let _guard = acquire(true)
        .await
        .ok_or_else(|| "планировщик занят — повторите позже".to_string())?;
    run_and_record(settings, &task).await;
    Ok(view())
}

async fn run_and_record(settings: &settings::Settings, task: &Task) {
    mark_running(&task.id);
    let outcome = execute(settings.port, &settings.api_key, task).await;
    let at = now_secs();
    // Re-read after the request: a concurrent edit must not be overwritten by
    // the store snapshot taken before the (up to 300 s) run.
    let mut store = load();
    if apply_outcome(&mut store, &task.id, at, &outcome).is_ok() {
        let _ = save(&store);
    }
}

fn mark_running(id: &str) {
    let mut store = load();
    let mut found = false;
    if let Some(task) = store.tasks.iter_mut().find(|task| task.id == id) {
        task.last_status = "running".to_string();
        found = true;
    }
    if found {
        let _ = save(&store);
    }
}

/// Store the outcome on the task, append history, and advance the schedule.
pub fn apply_outcome(
    store: &mut Store,
    task_id: &str,
    at: i64,
    outcome: &Outcome,
) -> Result<(), String> {
    let model = {
        let task = store
            .tasks
            .iter_mut()
            .find(|task| task.id == task_id)
            .ok_or_else(|| "задача не найдена".to_string())?;
        task.last_run_at = Some(at);
        task.last_status = outcome.status.clone();
        task.last_error = outcome.error.clone();
        task.last_result = truncate_result(&outcome.result);
        task.last_duration_ms = Some(outcome.duration_ms);
        task.last_tokens = outcome.tokens;
        // Failures keep the task enabled and move on to the next interval.
        // A manual run of a disabled task must not arm a schedule.
        task.next_run_at = if task.enabled {
            Some(next_after_run(at, task.interval_minutes))
        } else {
            None
        };
        task.model.clone()
    };
    store.history.push(HistoryEntry {
        task_id: task_id.to_string(),
        at,
        status: outcome.status.clone(),
        model,
        duration_ms: Some(outcome.duration_ms),
        tokens: outcome.tokens,
        result: truncate_result(&outcome.result),
        error: outcome.error.clone(),
    });
    trim_history(&mut store.history);
    Ok(())
}

pub fn endpoint(port: u16) -> String {
    format!("http://127.0.0.1:{}/v1/chat/completions", port)
}

pub fn request_body(task: &Task) -> Value {
    let mut body = json!({
        "model": task.model,
        "messages": [{ "role": "user", "content": task.prompt }],
        "stream": false,
    });
    if let Some(effort) = task
        .reasoning_effort
        .as_deref()
        .filter(|value| !value.is_empty())
    {
        body["reasoning_effort"] = json!(effort);
    }
    body
}

/// One completion through the local gateway.
pub async fn execute(port: u16, api_key: &str, task: &Task) -> Outcome {
    let started = Instant::now();
    let client = match reqwest::Client::builder()
        .timeout(Duration::from_secs(RUN_TIMEOUT_SECS))
        .build()
    {
        Ok(client) => client,
        Err(error) => return failure(error.to_string(), started),
    };
    let response = client
        .post(endpoint(port))
        .header("Authorization", format!("Bearer {}", api_key))
        .json(&request_body(task))
        .send()
        .await;
    let response = match response {
        Ok(response) => response,
        Err(error) => return failure(error.to_string(), started),
    };
    let code = response.status().as_u16();
    let text = match response.text().await {
        Ok(text) => text,
        Err(error) => return failure(error.to_string(), started),
    };
    let mut outcome = outcome_from_response(code, &text);
    outcome.duration_ms = started.elapsed().as_millis() as i64;
    outcome
}

/// Success carries `choices[0].message.content` and `usage.total_tokens`;
/// every failure keeps the gateway body (or transport message) verbatim.
pub fn outcome_from_response(code: u16, text: &str) -> Outcome {
    let error = |message: &str| Outcome {
        status: "error".to_string(),
        result: String::new(),
        error: Some(message.to_string()),
        duration_ms: 0,
        tokens: None,
    };
    if !(200..300).contains(&code) {
        return error(text);
    }
    let Ok(value) = serde_json::from_str::<Value>(text) else {
        return error(text);
    };
    let Some(content) = value
        .pointer("/choices/0/message/content")
        .and_then(Value::as_str)
    else {
        return error(text);
    };
    Outcome {
        status: "ok".to_string(),
        result: content.to_string(),
        error: None,
        duration_ms: 0,
        tokens: value
            .pointer("/usage/total_tokens")
            .and_then(Value::as_i64),
    }
}

fn failure(message: String, started: Instant) -> Outcome {
    Outcome {
        status: "error".to_string(),
        result: String::new(),
        error: Some(message),
        duration_ms: started.elapsed().as_millis() as i64,
        tokens: None,
    }
}

/// RFC 4122 version 4, from the same RNG the rest of the app uses.
pub fn new_uuid() -> String {
    let mut bytes: [u8; 16] = rand::random();
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|byte| format!("{:02x}", byte)).collect();
    format!(
        "{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    )
}

// MARK: - Models

pub fn model_group(id: &str) -> &'static str {
    if id.starts_with("opencode/") {
        "opencode"
    } else if id.starts_with("openrouter/") {
        "openrouter"
    } else if id.starts_with("claude-") {
        "claude"
    } else {
        "gateway"
    }
}

/// Ids grouped by prefix, order fixed, empty groups omitted. The id itself is
/// never rewritten: the task stores exactly what `/v1/models` returned.
pub fn model_groups(ids: &[String]) -> Vec<Value> {
    ["gateway", "claude", "opencode", "openrouter"]
        .iter()
        .filter_map(|group| {
            let bucket: Vec<&String> = ids
                .iter()
                .filter(|id| model_group(id.as_str()) == *group)
                .collect();
            (!bucket.is_empty()).then(|| json!({ "id": group, "ids": bucket }))
        })
        .collect()
}

pub async fn models(port: u16, api_key: &str) -> Result<Value, String> {
    let list = gateway::models(port, api_key).await?;
    let mut seen: HashSet<String> = HashSet::new();
    let mut ids: Vec<String> = Vec::new();
    for model in list.as_array().map(Vec::as_slice).unwrap_or_default() {
        let Some(id) = model
            .get("id")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|id| !id.is_empty())
        else {
            continue;
        };
        if seen.insert(id.to_string()) {
            ids.push(id.to_string());
        }
    }
    Ok(json!({
        "count": ids.len(),
        "ids": ids,
        "groups": model_groups(&ids),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn task(id: &str) -> Task {
        Task {
            id: id.to_string(),
            name: format!("task {}", id),
            prompt: "ping".to_string(),
            model: "gpt-6.1-sol".to_string(),
            ..Task::default()
        }
    }

    fn entry(task_id: &str, at: i64) -> HistoryEntry {
        HistoryEntry {
            task_id: task_id.to_string(),
            at,
            status: "ok".to_string(),
            model: "gpt-6.1-sol".to_string(),
            duration_ms: Some(1200),
            tokens: Some(10),
            result: "pong".to_string(),
            error: None,
        }
    }

    fn input(name: &str, interval: i64, enabled: bool) -> TaskInput {
        TaskInput {
            name: name.to_string(),
            prompt: "ping".to_string(),
            model: "gpt-6.1-sol".to_string(),
            interval_minutes: interval,
            enabled,
            ..TaskInput::default()
        }
    }

    #[test]
    fn task_serde_roundtrip_uses_camel_case() {
        let mut value = task("a");
        value.reasoning_effort = Some("high".to_string());
        value.next_run_at = Some(1_800);
        value.last_status = "ok".to_string();
        value.last_tokens = Some(42);
        let json = serde_json::to_value(&value).unwrap();
        for key in [
            "intervalMinutes",
            "nextRunAt",
            "lastRunAt",
            "lastStatus",
            "lastError",
            "lastResult",
            "lastDurationMs",
            "lastTokens",
            "reasoningEffort",
            "createdAt",
        ] {
            assert!(json.get(key).is_some(), "missing key {key}");
        }
        assert_eq!(json["nextRunAt"], 1_800);
        let back: Task = serde_json::from_value(json).unwrap();
        assert_eq!(back, value);
    }

    #[test]
    fn store_roundtrip_and_legacy_defaults() {
        let store = Store {
            tasks: vec![task("a")],
            history: vec![entry("a", 10)],
        };
        let raw = serde_json::to_string(&store).unwrap();
        let back: Store = serde_json::from_str(&raw).unwrap();
        assert_eq!(back, store);
        assert!(raw.contains("\"taskId\""));

        // A file written before a field existed must still load with the same
        // defaults the runner relies on.
        let legacy: Store = serde_json::from_str(r#"{"tasks":[{"id":"old","name":"n"}]}"#).unwrap();
        assert_eq!(legacy.tasks[0].interval_minutes, 60);
        assert!(legacy.tasks[0].enabled);
        assert_eq!(legacy.tasks[0].last_status, "never");
        assert!(legacy.history.is_empty());
    }

    #[test]
    fn result_is_cut_at_the_byte_cap_on_a_char_boundary() {
        let plain = "a".repeat(RESULT_CAP + 1024);
        assert_eq!(truncate_result(&plain).len(), RESULT_CAP);

        // A multi-byte char straddling the cap must not be split.
        let mut text = "a".repeat(RESULT_CAP - 1);
        text.push('ё');
        let cut = truncate_result(&text);
        assert!(cut.len() <= RESULT_CAP);
        assert!(cut.is_char_boundary(cut.len()));
        assert_eq!(cut.len(), RESULT_CAP - 1);

        let short = "ok";
        assert_eq!(truncate_result(short), "ok");
    }

    #[test]
    fn history_keeps_twenty_per_task_and_the_newest_overall() {
        let mut history: Vec<HistoryEntry> = Vec::new();
        for at in 0..25 {
            history.push(entry("a", at));
        }
        for at in 0..5 {
            history.push(entry("b", at));
        }
        trim_history(&mut history);
        assert_eq!(history.len(), 25);
        assert_eq!(history.iter().filter(|e| e.task_id == "a").count(), 20);
        assert_eq!(history.first().unwrap().at, 5, "oldest 'a' entries dropped");
        assert_eq!(history.last().unwrap().task_id, "b");

        // Twelve tasks at 20 entries each = 240 > 200: the newest 200 survive.
        let mut many: Vec<HistoryEntry> = Vec::new();
        for index in 0..12 {
            for at in 0..20 {
                many.push(entry(&format!("t{index}"), index * 100 + at));
            }
        }
        trim_history(&mut many);
        assert_eq!(many.len(), HISTORY_GLOBAL);
        assert_eq!(many.last().unwrap().at, 11 * 100 + 19);
        // 240 entries -> the 40 oldest (t0 and t1) are gone.
        assert_eq!(many.first().unwrap().at, 2 * 100);
    }

    #[test]
    fn due_requires_enabled_and_an_elapsed_next_run() {
        let now = 10_000;
        let mut future = task("future");
        future.next_run_at = Some(now + 60);
        let mut disabled = task("disabled");
        disabled.enabled = false;
        disabled.next_run_at = Some(now - 60);
        let mut due = task("due");
        due.next_run_at = Some(now - 1);
        let mut never = task("never");
        never.next_run_at = None;

        let store = Store {
            tasks: vec![future, disabled, due, never],
            history: Vec::new(),
        };
        assert_eq!(due_task(&store, now).map(|task| task.id.as_str()), Some("due"));
        assert!(due_task(&store, now - 120).is_none());
    }

    #[test]
    fn a_finished_run_advances_the_next_run_by_the_interval() {
        let mut store = Store {
            tasks: vec![task("a")],
            history: Vec::new(),
        };
        store.tasks[0].interval_minutes = 30;
        store.tasks[0].next_run_at = Some(0);
        let outcome = Outcome {
            status: "ok".to_string(),
            result: "pong".to_string(),
            error: None,
            duration_ms: 900,
            tokens: Some(12),
        };
        apply_outcome(&mut store, "a", 1_000, &outcome).unwrap();
        let task = &store.tasks[0];
        assert_eq!(task.last_run_at, Some(1_000));
        assert_eq!(task.next_run_at, Some(1_000 + 30 * 60));
        assert_eq!(task.last_status, "ok");
        assert_eq!(task.last_result, "pong");
        assert_eq!(task.last_tokens, Some(12));
        assert_eq!(store.history.len(), 1);
        assert_eq!(store.history[0].task_id, "a");
        assert_eq!(next_after_run(1_000, 30), 2_800);
    }

    #[test]
    fn overdue_tasks_run_one_at_a_time_without_a_burst() {
        let now = 50_000;
        let mut first = task("a");
        first.interval_minutes = 60;
        first.next_run_at = Some(now - 3 * 3600);
        let mut second = task("b");
        second.next_run_at = Some(now - 3 * 3600);
        let mut store = Store {
            tasks: vec![first, second],
            history: Vec::new(),
        };

        let picked = due_task(&store, now).cloned().unwrap();
        assert_eq!(picked.id, "a", "one task per pass");
        let outcome = Outcome {
            status: "ok".to_string(),
            ..Outcome::default()
        };
        apply_outcome(&mut store, &picked.id, now, &outcome).unwrap();

        // The finished task is no longer due; the other one waits for the next
        // tick instead of firing alongside it.
        assert_eq!(due_task(&store, now).map(|task| task.id.as_str()), Some("b"));
        assert!(store.tasks[0].next_run_at.unwrap() > now);
        assert_eq!(store.history.len(), 1);
    }

    #[test]
    fn failures_keep_the_task_enabled_and_reschedule_it() {
        let mut store = Store {
            tasks: vec![task("a")],
            history: Vec::new(),
        };
        store.tasks[0].interval_minutes = 15;
        let outcome = Outcome {
            status: "error".to_string(),
            result: String::new(),
            error: Some("502 bad gateway".to_string()),
            duration_ms: 40,
            tokens: None,
        };
        apply_outcome(&mut store, "a", 600, &outcome).unwrap();
        assert!(store.tasks[0].enabled);
        assert_eq!(store.tasks[0].last_status, "error");
        assert_eq!(store.tasks[0].next_run_at, Some(600 + 15 * 60));
        assert_eq!(store.history[0].error.as_deref(), Some("502 bad gateway"));
    }

    #[test]
    fn input_validation_rejects_half_a_task() {
        let mut task_input = input("", 60, true);
        assert!(validate(&task_input).is_err());
        task_input = input("nightly", 0, true);
        assert!(validate(&task_input).is_err());
        task_input = input("nightly", MAX_INTERVAL_MINUTES + 1, true);
        assert!(validate(&task_input).is_err());
        task_input = input("nightly", 60, true);
        task_input.model = "  ".to_string();
        assert!(validate(&task_input).is_err());
        task_input = input("nightly", 60, true);
        task_input.prompt = " ".to_string();
        assert!(validate(&task_input).is_err());
        task_input = input("nightly", 60, true);
        task_input.reasoning_effort = Some("turbo".to_string());
        assert!(validate(&task_input).is_err());

        let valid = validate(&input("  nightly  ", 90, true)).unwrap();
        assert_eq!(valid.name, "nightly");
        assert_eq!(valid.interval_minutes, 90);
        assert!(valid.effort.is_none());
    }

    #[test]
    fn edits_keep_history_and_schedule_rules() {
        let now = 2_000;
        let mut existing = task("a");
        existing.created_at = 100;
        existing.last_run_at = Some(900);
        existing.last_status = "ok".to_string();
        existing.interval_minutes = 60;
        existing.next_run_at = Some(4_000);
        existing.name = "old".to_string();

        // Same interval, same enabled: the pending run is preserved.
        let valid = validate(&input("new name", 60, true)).unwrap();
        apply_input(&mut existing, &valid, now);
        assert_eq!(existing.name, "new name");
        assert_eq!(existing.created_at, 100);
        assert_eq!(existing.last_run_at, Some(900));
        assert_eq!(existing.next_run_at, Some(4_000));

        // A new interval starts a fresh countdown.
        let valid = validate(&input("new name", 120, true)).unwrap();
        apply_input(&mut existing, &valid, now);
        assert_eq!(existing.next_run_at, Some(now + 120 * 60));

        // Disabling clears the schedule; enabling starts a fresh interval.
        let valid = validate(&input("new name", 120, false)).unwrap();
        apply_input(&mut existing, &valid, now);
        assert!(!existing.enabled);
        assert_eq!(existing.next_run_at, None);
        let valid = validate(&input("new name", 120, true)).unwrap();
        apply_input(&mut existing, &valid, now);
        assert_eq!(existing.next_run_at, Some(now + 120 * 60));
    }

    #[test]
    fn response_parsing_reads_content_and_tokens() {
        let body = r#"{"choices":[{"message":{"role":"assistant","content":"pong"}}],"usage":{"total_tokens":42}}"#;
        let outcome = outcome_from_response(200, body);
        assert_eq!(outcome.status, "ok");
        assert_eq!(outcome.result, "pong");
        assert_eq!(outcome.tokens, Some(42));
        assert!(outcome.error.is_none());

        let empty = outcome_from_response(200, r#"{"choices":[{"message":{"content":""}}]}"#);
        assert_eq!(empty.status, "ok");
        assert_eq!(empty.result, "");
        assert_eq!(empty.tokens, None);
    }

    #[test]
    fn errors_are_stored_verbatim() {
        let body = r#"{"error":{"message":"no available account","type":"pool_empty"}}"#;
        let outcome = outcome_from_response(429, body);
        assert_eq!(outcome.status, "error");
        assert_eq!(outcome.error.as_deref(), Some(body));
        assert!(outcome.result.is_empty());

        let broken = "upstream closed the connection";
        let outcome = outcome_from_response(502, broken);
        assert_eq!(outcome.error.as_deref(), Some(broken));

        // 2xx with a body that is not a completion is an error too, and the
        // body must survive unchanged for diagnosis.
        let outcome = outcome_from_response(200, "not json");
        assert_eq!(outcome.status, "error");
        assert_eq!(outcome.error.as_deref(), Some("not json"));
    }

    #[test]
    fn endpoint_and_request_body_match_the_contract() {
        assert_eq!(TICK_SECS, 30);
        assert_eq!(RUN_TIMEOUT_SECS, 300);
        assert_eq!(endpoint(18317), "http://127.0.0.1:18317/v1/chat/completions");

        let task = task("a");
        let body = request_body(&task);
        assert_eq!(body["model"], "gpt-6.1-sol");
        assert_eq!(body["messages"][0]["role"], "user");
        assert_eq!(body["messages"][0]["content"], "ping");
        assert_eq!(body["stream"], false);
        assert!(body.get("reasoning_effort").is_none());

        let mut with_effort = task;
        with_effort.reasoning_effort = Some("xhigh".to_string());
        assert_eq!(request_body(&with_effort)["reasoning_effort"], "xhigh");
    }

    #[test]
    fn ids_are_version_four_uuids() {
        let id = new_uuid();
        assert_eq!(id.len(), 36);
        let parts: Vec<&str> = id.split('-').collect();
        assert_eq!(parts.iter().map(|part| part.len()).collect::<Vec<_>>(), vec![8, 4, 4, 4, 12]);
        assert_eq!(&parts[2][0..1], "4");
        assert!(matches!(&parts[3][0..1], "8" | "9" | "a" | "b"));
        assert_ne!(id, new_uuid());
    }

    #[test]
    fn model_groups_keep_exact_ids_and_fixed_order() {
        let ids: Vec<String> = [
            "gpt-6.1-sol",
            "claude-opus-5-5",
            "opencode/grok-4.7",
            "openrouter/meta/llama",
            "gpt-6-luna",
        ]
        .iter()
        .map(|id| id.to_string())
        .collect();
        let groups = model_groups(&ids);
        let ids_of = |group: &str| -> Vec<String> {
            groups
                .iter()
                .find(|value| value["id"] == group)
                .map(|value| {
                    value["ids"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .map(|id| id.as_str().unwrap().to_string())
                        .collect()
                })
                .unwrap_or_default()
        };
        assert_eq!(ids_of("gateway"), vec!["gpt-6.1-sol", "gpt-6-luna"]);
        assert_eq!(ids_of("claude"), vec!["claude-opus-5-5"]);
        assert_eq!(ids_of("opencode"), vec!["opencode/grok-4.7"]);
        assert_eq!(ids_of("openrouter"), vec!["openrouter/meta/llama"]);
        assert_eq!(groups[0]["id"], "gateway");
        assert_eq!(model_group("claude-opus-5-5"), "claude");
    }

    #[test]
    fn store_path_sits_next_to_settings() {
        assert_eq!(path(), paths::appdata_dir().join("scheduler.json"));
    }

    #[test]
    fn store_persists_through_an_atomic_save_and_load() {
        let dir = std::env::temp_dir().join(format!("melon-scheduler-test-{}", new_uuid()));
        std::fs::create_dir_all(&dir).unwrap();
        let target = dir.join("scheduler.json");

        let mut store = Store {
            tasks: vec![task("a"), task("b")],
            history: vec![entry("a", 10)],
        };
        store.tasks[0].interval_minutes = 45;
        store.tasks[0].next_run_at = Some(now_secs() + 45 * 60);
        store.tasks[0].last_status = "ok".to_string();
        store.tasks[0].last_result = "pong".to_string();
        save_to(&target, &store).unwrap();

        let raw = std::fs::read_to_string(&target).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&raw).unwrap();
        assert!(parsed.get("tasks").and_then(|value| value.as_array()).is_some());
        assert!(parsed.get("history").and_then(|value| value.as_array()).is_some());
        assert!(raw.contains("\"nextRunAt\""), "camelCase on disk");

        let back = load_from(&target);
        assert_eq!(back.tasks.len(), 2);
        assert_eq!(back.tasks[0].interval_minutes, 45);
        assert_eq!(back.tasks[0].last_status, "ok");
        assert_eq!(back.tasks[0].last_result, "pong");
        assert!(back.tasks[1].next_run_at.is_some(), "enabled task is scheduled");
        assert_eq!(back.history.len(), 1);

        // The tmp sibling is renamed, never left next to the store.
        let leftovers = std::fs::read_dir(&dir)
            .unwrap()
            .filter(|entry| {
                entry
                    .as_ref()
                    .unwrap()
                    .file_name()
                    .to_string_lossy()
                    .ends_with(".tmp")
            })
            .count();
        assert_eq!(leftovers, 0);

        // A broken file loads as an empty store instead of failing the app.
        std::fs::write(&target, "{not json").unwrap();
        assert!(load_from(&target).tasks.is_empty());

        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_stale_running_status_loads_as_an_error() {
        let dir = std::env::temp_dir().join(format!("melon-scheduler-stale-{}", new_uuid()));
        std::fs::create_dir_all(&dir).unwrap();
        let target = dir.join("scheduler.json");
        let mut store = Store {
            tasks: vec![task("a")],
            history: Vec::new(),
        };
        store.tasks[0].last_status = "running".to_string();
        save_to(&target, &store).unwrap();
        assert_eq!(load_from(&target).tasks[0].last_status, "error");
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
