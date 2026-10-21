//! Scheduler: a persisted task list plus the serial in-process runner.
//!
//! Tasks live in `%APPDATA%\MelonTools\scheduler.json` (atomic tmp+rename).
//! A due task is sent to the local gateway as one chat completion; nothing is
//! spawned outside the app process, so a quit app never runs anything. Hiding
//! the main window to the tray leaves the process and this runner alive.

use std::collections::HashSet;
use std::future::Future;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, MutexGuard};
use std::time::{Duration, Instant};

use chrono::{
    Datelike, Duration as ChronoDuration, FixedOffset, Local, LocalResult, NaiveDate,
    NaiveDateTime, TimeZone, Utc,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tauri_plugin_notification::NotificationExt;

use crate::{gateway, paths, settings, vault};

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
/// How many days the cron scanner looks ahead before giving up.
pub const MAX_CRON_SCAN_DAYS: i64 = 3653;
pub const SCHEDULE_INTERVAL: &str = "interval";
pub const SCHEDULE_CRON: &str = "cron";
pub const EFFORTS: [&str; 5] = ["low", "medium", "high", "xhigh", "max"];

/// Outcome status strings. Only `error` is retried; `cancelled` and `skipped`
/// keep the normal schedule.
pub const STATUS_OK: &str = "ok";
pub const STATUS_ERROR: &str = "error";
pub const STATUS_CANCELLED: &str = "cancelled";
pub const STATUS_SKIPPED: &str = "skipped";
/// Recorded for a user-cancelled run instead of a transport error.
pub const CANCELLED_MESSAGE: &str = "Cancelled by user";
/// Bounds of the optional per-task daily token budget.
pub const MIN_DAILY_TOKEN_LIMIT: i64 = 1;
pub const MAX_DAILY_TOKEN_LIMIT: i64 = 1_000_000;
/// How often an in-flight request checks the cancellation flag.
pub const CANCEL_POLL_MS: u64 = 200;

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
    pub working_directory: Option<String>,
    pub include_git_context: bool,
    pub max_tokens: Option<i64>,
    /// Optional daily token budget; `None` means unlimited.
    pub daily_token_limit: Option<i64>,
    pub retry_limit: i64,
    pub retry_delay_minutes: i64,
    pub retry_attempt: i64,
    /// `"interval"` or `"cron"`. Older files omit it and default to interval.
    pub schedule_kind: String,
    pub cron_expression: Option<String>,
    pub time_zone: Option<String>,
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
            working_directory: None,
            include_git_context: false,
            max_tokens: None,
            daily_token_limit: None,
            retry_limit: 0,
            retry_delay_minutes: 5,
            retry_attempt: 0,
            schedule_kind: SCHEDULE_INTERVAL.to_string(),
            cron_expression: None,
            time_zone: None,
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
    pub working_directory: Option<String>,
    pub include_git_context: bool,
    pub max_tokens: Option<i64>,
    /// Optional daily token budget; `None` means unlimited.
    pub daily_token_limit: Option<i64>,
    pub retry_limit: i64,
    pub retry_delay_minutes: i64,
    pub schedule_kind: String,
    pub cron_expression: Option<String>,
    pub time_zone: Option<String>,
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
            working_directory: None,
            include_git_context: false,
            max_tokens: None,
            daily_token_limit: None,
            retry_limit: 0,
            retry_delay_minutes: 5,
            schedule_kind: SCHEDULE_INTERVAL.to_string(),
            cron_expression: None,
            time_zone: None,
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
    working_directory: Option<String>,
    include_git_context: bool,
    max_tokens: Option<i64>,
    daily_token_limit: Option<i64>,
    retry_limit: i64,
    retry_delay_minutes: i64,
    schedule_kind: String,
    cron_expression: Option<String>,
    time_zone: Option<String>,
    interval_minutes: i64,
    enabled: bool,
}

/// One completed (or failed) run.
#[derive(Serialize, Clone, Debug, Default, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Outcome {
    /// `ok`, `error`, `cancelled` or `skipped`.
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
    let raw = std::fs::read_to_string(target).ok();
    let mut store: Store = raw
        .as_deref()
        .and_then(|text| serde_json::from_str(text).ok())
        .unwrap_or_else(|| {
            if raw.as_deref().map(|text| !text.trim().is_empty()).unwrap_or(false) {
                let _ = paths::quarantine(target);
            }
            Store::default()
        });
    let now = now_secs();
    clamp_store(&mut store);
    for task in &mut store.tasks {
        // Writing "running" then dying leaves a stuck status; the process that
        // owned it is gone, so the read view must not claim it still runs.
        if task.last_status == "running" {
            task.last_status = "error".to_string();
        }
        if task.enabled && task.next_run_at.is_none() {
            task.next_run_at = next_run_for(
                &task.schedule_kind,
                task.interval_minutes,
                task.cron_expression.as_deref(),
                task.time_zone.as_deref(),
                now,
            )
            .ok();
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

/// Raw scheduler JSON object, unknown keys preserved. `None` when the file is
/// missing, unreadable or not a JSON object — a backup export then omits the
/// component instead of shipping a corrupt/empty replacement.
pub fn load_raw_at(target: &std::path::Path) -> Option<Value> {
    let text = std::fs::read_to_string(target).ok()?;
    match serde_json::from_str::<Value>(&text).ok()? {
        Value::Object(object) => Some(Value::Object(object)),
        _ => None,
    }
}

/// Validate a raw scheduler object against the typed store, then replace the
/// file atomically. Validation happens before the write so a damaged backup
/// cannot destroy the live schedule.
pub fn save_raw_at(target: &std::path::Path, value: &Value) -> Result<(), String> {
    serde_json::from_value::<Store>(value.clone())
        .map_err(|error| format!("scheduler: {error}"))?;
    if let Some(dir) = target.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let data = serde_json::to_string_pretty(value).map_err(|e| e.to_string())?;
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

#[derive(Clone, Copy, Debug)]
enum TaskZone {
    Local,
    Fixed(FixedOffset),
}

/// Windows has no bundled IANA rules. Accept the system zone, UTC/GMT and a
/// fixed offset (`+03:00`, `UTC-5`, `+0530`); everything else is rejected
/// instead of silently running in the wrong zone.
fn normalize_time_zone(value: Option<&str>) -> Result<Option<String>, String> {
    let raw = value.unwrap_or("").trim();
    if raw.is_empty()
        || raw.eq_ignore_ascii_case("local")
        || raw.eq_ignore_ascii_case("system")
    {
        return Ok(None);
    }
    let upper = raw.to_ascii_uppercase();
    if upper == "UTC" || upper == "GMT" || upper == "Z" {
        return Ok(Some("UTC".to_string()));
    }
    let seconds = parse_offset_seconds(&upper)
        .ok_or_else(|| format!("часовой пояс: используйте System, UTC или смещение вида +03:00 (получено «{}»)", raw))?;
    let sign = if seconds < 0 { '-' } else { '+' };
    let abs = seconds.unsigned_abs();
    Ok(Some(format!(
        "{}{:02}:{:02}",
        sign,
        abs / 3600,
        (abs % 3600) / 60
    )))
}

fn parse_offset_seconds(raw: &str) -> Option<i32> {
    let rest = raw
        .strip_prefix("UTC")
        .or_else(|| raw.strip_prefix("GMT"))
        .unwrap_or(raw);
    let (sign, body) = if let Some(body) = rest.strip_prefix('+') {
        (1, body)
    } else if let Some(body) = rest.strip_prefix('-') {
        (-1, body)
    } else {
        return None;
    };
    let (hours, minutes) = if let Some((hours, minutes)) = body.split_once(':') {
        (hours.parse::<i32>().ok()?, minutes.parse::<i32>().ok()?)
    } else if body.len() == 4 && body.chars().all(|c| c.is_ascii_digit()) {
        (body[0..2].parse().ok()?, body[2..4].parse().ok()?)
    } else if body.len() <= 2 && body.chars().all(|c| c.is_ascii_digit()) {
        (body.parse().ok()?, 0)
    } else {
        return None;
    };
    if hours > 23 || minutes > 59 {
        return None;
    }
    Some(sign * (hours * 3600 + minutes * 60))
}

fn task_zone(value: Option<&str>) -> Result<TaskZone, String> {
    match normalize_time_zone(value)? {
        None => Ok(TaskZone::Local),
        Some(normalized) if normalized == "UTC" => Ok(TaskZone::Fixed(
            FixedOffset::east_opt(0).expect("UTC offset"),
        )),
        Some(normalized) => {
            let seconds = parse_offset_seconds(&normalized)
                .ok_or_else(|| "часовой пояс: некорректное смещение".to_string())?;
            Ok(TaskZone::Fixed(
                FixedOffset::east_opt(seconds)
                    .ok_or_else(|| "часовой пояс: смещение вне диапазона".to_string())?,
            ))
        }
    }
}

fn zone_epoch(zone: TaskZone, naive: NaiveDateTime) -> Option<i64> {
    match zone {
        TaskZone::Local => match Local.from_local_datetime(&naive) {
            LocalResult::Single(value) => Some(value.timestamp()),
            LocalResult::Ambiguous(first, _) => Some(first.timestamp()),
            LocalResult::None => None,
        },
        TaskZone::Fixed(offset) => offset
            .from_local_datetime(&naive)
            .single()
            .map(|value| value.timestamp()),
    }
}

/// Parsed five-field cron schedule. Values are sorted and deduplicated.
#[derive(Clone, Debug)]
struct CronSchedule {
    minutes: Vec<u32>,
    hours: Vec<u32>,
    days: Vec<u32>,
    months: Vec<u32>,
    weekdays: Vec<u32>,
    dom_restricted: bool,
    dow_restricted: bool,
}

fn parse_cron(expression: &str) -> Result<CronSchedule, String> {
    let fields: Vec<&str> = expression.split_whitespace().collect();
    if fields.len() != 5 {
        return Err(format!(
            "cron: нужно 5 полей (минута час день месяц день недели), получено {}",
            fields.len()
        ));
    }
    let months = [
        ("JAN", 1),
        ("FEB", 2),
        ("MAR", 3),
        ("APR", 4),
        ("MAY", 5),
        ("JUN", 6),
        ("JUL", 7),
        ("AUG", 8),
        ("SEP", 9),
        ("OCT", 10),
        ("NOV", 11),
        ("DEC", 12),
    ];
    let weekdays = [
        ("SUN", 0),
        ("MON", 1),
        ("TUE", 2),
        ("WED", 3),
        ("THU", 4),
        ("FRI", 5),
        ("SAT", 6),
    ];
    let minutes = parse_cron_field(fields[0], 0, 59, &[], "минуты")?;
    let hours = parse_cron_field(fields[1], 0, 23, &[], "часы")?;
    let days = parse_cron_field(fields[2], 1, 31, &[], "день")?;
    let months = parse_cron_field(fields[3], 1, 12, &months, "месяц")?;
    let mut weekdays = parse_cron_field(fields[4], 0, 7, &weekdays, "день недели")?;
    for value in &mut weekdays {
        if *value == 7 {
            *value = 0;
        }
    }
    weekdays.sort_unstable();
    weekdays.dedup();
    Ok(CronSchedule {
        minutes,
        hours,
        days,
        months,
        weekdays,
        // Vixie semantics: `*/n` still starts with `*`, so it does not make
        // the day field "restricted" for the OR rule.
        dom_restricted: !fields[2].starts_with('*'),
        dow_restricted: !fields[4].starts_with('*'),
    })
}

fn parse_cron_field(
    raw: &str,
    low: u32,
    high: u32,
    names: &[(&str, u32)],
    label: &str,
) -> Result<Vec<u32>, String> {
    let mut values = Vec::new();
    for part in raw.split(',') {
        if part.is_empty() {
            return Err(format!("cron: пустое значение в поле «{}»", label));
        }
        let mut pieces = part.split('/');
        let base = pieces.next().unwrap_or("");
        let step = match pieces.next() {
            Some(text) => text
                .parse::<u32>()
                .map_err(|_| format!("cron: шаг в поле «{}» должен быть числом", label))?,
            None => 1,
        };
        if pieces.next().is_some() {
            return Err(format!("cron: лишний «/» в поле «{}»", label));
        }
        if step == 0 {
            return Err(format!("cron: шаг в поле «{}» должен быть больше нуля", label));
        }
        let value = |text: &str| -> Result<u32, String> {
            let upper = text.to_ascii_uppercase();
            if let Some((_, value)) = names.iter().find(|(name, _)| *name == upper) {
                return Ok(*value);
            }
            text.parse::<u32>()
                .map_err(|_| format!("cron: некорректное значение «{}» в поле «{}»", text, label))
        };
        let (start, end) = if base == "*" {
            (low, high)
        } else if let Some((first, last)) = base.split_once('-') {
            (value(first)?, value(last)?)
        } else {
            let single = value(base)?;
            if step > 1 {
                (single, high)
            } else {
                (single, single)
            }
        };
        if start < low || end > high || start > end {
            return Err(format!(
                "cron: значение вне диапазона {}-{} в поле «{}»",
                low, high, label
            ));
        }
        let mut current = start;
        while current <= end {
            values.push(current);
            current += step;
        }
    }
    values.sort_unstable();
    values.dedup();
    Ok(values)
}

impl CronSchedule {
    fn matches_date(&self, date: NaiveDate) -> bool {
        if !self.months.contains(&date.month()) {
            return false;
        }
        let dom = self.days.contains(&date.day());
        let dow = self
            .weekdays
            .contains(&date.weekday().num_days_from_sunday());
        if self.dom_restricted && self.dow_restricted {
            dom || dow
        } else {
            dom && dow
        }
    }

    /// First fire time at or after `now`, in the task time zone.
    fn next_fire(&self, zone: TaskZone, now: i64) -> Result<i64, String> {
        let start = Utc
            .timestamp_opt(now, 0)
            .single()
            .ok_or_else(|| "cron: некорректная текущая дата".to_string())?;
        let local_start = match zone {
            TaskZone::Local => start.with_timezone(&Local).naive_local(),
            TaskZone::Fixed(offset) => start.with_timezone(&offset).naive_local(),
        };
        let start_date = local_start.date();
        for offset in 0..=MAX_CRON_SCAN_DAYS {
            let Some(date) = start_date.checked_add_signed(ChronoDuration::days(offset)) else {
                break;
            };
            if !self.matches_date(date) {
                continue;
            }
            for hour in &self.hours {
                for minute in &self.minutes {
                    let Some(naive) = date.and_hms_opt(*hour, *minute, 0) else {
                        continue;
                    };
                    if let Some(epoch) = zone_epoch(zone, naive) {
                        if epoch >= now {
                            return Ok(epoch);
                        }
                    }
                }
            }
        }
        Err("cron: следующее срабатывание не найдено в пределах 10 лет".to_string())
    }
}

fn next_run_for(
    schedule_kind: &str,
    interval_minutes: i64,
    cron_expression: Option<&str>,
    time_zone: Option<&str>,
    now: i64,
) -> Result<i64, String> {
    match schedule_kind {
        "" | SCHEDULE_INTERVAL => Ok(next_after_run(now, interval_minutes)),
        SCHEDULE_CRON => {
            let expression = cron_expression
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .ok_or_else(|| "cron: укажите выражение".to_string())?;
            let schedule = parse_cron(expression)?;
            let zone = task_zone(time_zone)?;
            schedule.next_fire(zone, now)
        }
        other => Err(format!("неизвестный тип расписания: {}", other)),
    }
}

/// The single task to run now. Disabled tasks and future runs never qualify;
/// the caller runs one task per tick, so a long pause cannot produce a burst.
pub fn due_task(store: &Store, now: i64) -> Option<&Task> {
    store
        .tasks
        .iter()
        .find(|task| task.enabled && task.next_run_at.map(|at| at <= now).unwrap_or(false))
}

// MARK: - Daily token budget (clock injected)

/// Local calendar day of an epoch timestamp. The clock is local because the
/// editor speaks in the user's day, not UTC.
fn local_day(at: i64) -> Option<NaiveDate> {
    Local
        .timestamp_opt(at, 0)
        .single()
        .map(|value| value.date_naive())
}

/// Sum of today's history tokens for one task. Other tasks, other local
/// calendar days and entries without tokens are ignored; negative values
/// (never written by this runner) cannot lower the sum.
pub fn tokens_used_today(task_id: &str, history: &[HistoryEntry], at: i64) -> i64 {
    let Some(today) = local_day(at) else {
        return 0;
    };
    history
        .iter()
        .filter(|entry| entry.task_id == task_id)
        .filter(|entry| local_day(entry.at) == Some(today))
        .map(|entry| entry.tokens.unwrap_or(0).max(0))
        .sum()
}

/// `Some(reason)` when the daily budget is already spent, so the caller must
/// not send a request. `None` without a limit or while budget remains.
pub fn daily_limit_message(task: &Task, history: &[HistoryEntry], at: i64) -> Option<String> {
    let limit = task.daily_token_limit?;
    let used = tokens_used_today(&task.id, history, at);
    (used >= limit).then(|| format!("Daily token limit reached ({}/{})", used, limit))
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
    let schedule_kind = match input.schedule_kind.trim().to_ascii_lowercase().as_str() {
        "" | SCHEDULE_INTERVAL => SCHEDULE_INTERVAL.to_string(),
        SCHEDULE_CRON => SCHEDULE_CRON.to_string(),
        other => return Err(format!("неизвестный тип расписания: {}", other)),
    };
    let cron_expression = if schedule_kind == SCHEDULE_CRON {
        let expression = input
            .cron_expression
            .as_deref()
            .unwrap_or("")
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ");
        if expression.is_empty() {
            return Err("cron: укажите выражение".to_string());
        }
        parse_cron(&expression)?;
        Some(expression)
    } else {
        None
    };
    let time_zone = normalize_time_zone(input.time_zone.as_deref())?;
    let working_directory = input
        .working_directory
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string);
    if let Some(directory) = &working_directory {
        if !std::path::Path::new(directory).is_dir() {
            return Err("рабочая папка не существует".to_string());
        }
    }
    if let Some(max_tokens) = input.max_tokens {
        if !(1..=32_768).contains(&max_tokens) {
            return Err("max tokens: от 1 до 32768".to_string());
        }
    }
    if let Some(limit) = input.daily_token_limit {
        if !(MIN_DAILY_TOKEN_LIMIT..=MAX_DAILY_TOKEN_LIMIT).contains(&limit) {
            return Err(format!(
                "дневной лимит токенов: от {} до {}",
                MIN_DAILY_TOKEN_LIMIT, MAX_DAILY_TOKEN_LIMIT
            ));
        }
    }
    if !(0..=10).contains(&input.retry_limit) {
        return Err("retry limit: от 0 до 10".to_string());
    }
    if !(1..=1440).contains(&input.retry_delay_minutes) {
        return Err("retry delay: от 1 до 1440 минут".to_string());
    }
    if schedule_kind == SCHEDULE_INTERVAL
        && (input.interval_minutes < 1 || input.interval_minutes > MAX_INTERVAL_MINUTES)
    {
        return Err(format!("интервал: от 1 до {} минут", MAX_INTERVAL_MINUTES));
    }
    // Validate the first fire now, not on the first tick: an impossible date
    // (for example 31 February) must be rejected with the editor open.
    next_run_for(
        &schedule_kind,
        input.interval_minutes,
        cron_expression.as_deref(),
        time_zone.as_deref(),
        now_secs(),
    )?;
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
        working_directory,
        include_git_context: input.include_git_context,
        max_tokens: input.max_tokens,
        daily_token_limit: input.daily_token_limit,
        retry_limit: input.retry_limit,
        retry_delay_minutes: input.retry_delay_minutes,
        schedule_kind,
        cron_expression,
        time_zone,
        interval_minutes: input.interval_minutes.clamp(1, MAX_INTERVAL_MINUTES),
        enabled: input.enabled,
    })
}

/// Copy the edit into the task and decide the next run. Kept pure so the
/// scheduling rules are testable without touching the disk.
fn apply_input(task: &mut Task, input: &Validated, now: i64) {
    let schedule_changed = task.interval_minutes != input.interval_minutes
        || task.schedule_kind != input.schedule_kind
        || task.cron_expression != input.cron_expression
        || task.time_zone != input.time_zone
        || task.enabled != input.enabled;
    task.name = input.name.clone();
    task.prompt = input.prompt.clone();
    task.model = input.model.clone();
    task.reasoning_effort = input.effort.clone();
    task.working_directory = input.working_directory.clone();
    task.include_git_context = input.include_git_context;
    task.max_tokens = input.max_tokens;
    task.daily_token_limit = input.daily_token_limit;
    task.retry_limit = input.retry_limit;
    task.retry_delay_minutes = input.retry_delay_minutes;
    task.interval_minutes = input.interval_minutes;
    task.schedule_kind = input.schedule_kind.clone();
    task.cron_expression = input.cron_expression.clone();
    task.time_zone = input.time_zone.clone();
    task.enabled = input.enabled;
    if !task.enabled {
        // A disabled task has no schedule at all — re-enabling starts a fresh
        // run instead of firing an overdue one immediately.
        task.next_run_at = None;
    } else if schedule_changed || task.next_run_at.is_none() {
        task.next_run_at = next_run_for(
            &task.schedule_kind,
            task.interval_minutes,
            task.cron_expression.as_deref(),
            task.time_zone.as_deref(),
            now,
        )
        .ok();
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
/// Manual "Run now" requests waiting for the active run, in arrival order.
/// Memory only: an app restart drops the queue by design.
static QUEUE: Mutex<Vec<String>> = Mutex::new(Vec::new());
/// Task id owned by the active run, reported by `scheduler_queue`.
static CURRENT: Mutex<Option<String>> = Mutex::new(None);
/// Set by `cancel`, polled by `execute`, reset at the start of every run.
static CANCEL: AtomicBool = AtomicBool::new(false);

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
        // Clear the claim under the queue lock: `claim_or_enqueue` either sees
        // an active runner (and queues) or takes the claim itself, so a manual
        // request can never land in the gap and wait forever.
        let _queue = queue_lock();
        RUNNING.store(false, Ordering::SeqCst);
    }
}

/// How a manual run is admitted: it starts now, or it waits in the queue.
enum Claim {
    Started(RunGuard),
    Queued,
}

/// The queue lock. A poisoned lock is recovered: the vector holds only ids and
/// cannot be left half-written.
fn queue_lock() -> MutexGuard<'static, Vec<String>> {
    QUEUE.lock().unwrap_or_else(|error| error.into_inner())
}

/// Append an id unless it is already waiting. Empty ids never enter.
fn push_queued(queue: &mut Vec<String>, id: &str) -> bool {
    if id.trim().is_empty() || queue.iter().any(|queued| queued == id) {
        return false;
    }
    queue.push(id.to_string());
    true
}

/// Oldest queued id that still resolves to a task. Deleted and unknown ids are
/// dropped; a disabled task still runs because the request was explicit.
fn pop_known_task(queue: &mut Vec<String>, tasks: &[Task]) -> Option<Task> {
    while !queue.is_empty() {
        let id = queue.remove(0);
        if let Some(task) = tasks.iter().find(|task| task.id == id) {
            return Some(task.clone());
        }
    }
    None
}

/// Take the claim when the runner is idle; otherwise append the id (deduped)
/// and report it as queued. The check and the append share the queue lock with
/// the release below, so no request can be stranded.
fn claim_or_enqueue(id: &str) -> Claim {
    let mut queue = queue_lock();
    if !RUNNING.load(Ordering::SeqCst) {
        if let Some(guard) = RunGuard::try_acquire() {
            return Claim::Started(guard);
        }
    }
    push_queued(&mut queue, id);
    Claim::Queued
}

/// Next queued run, or `None` after releasing the claim. The empty check and
/// the release share one critical section with `claim_or_enqueue`.
fn next_queued_or_finish() -> Option<Task> {
    let mut queue = queue_lock();
    let store = load();
    let next = pop_known_task(&mut queue, &store.tasks);
    if next.is_none() {
        RUNNING.store(false, Ordering::SeqCst);
    }
    next
}

/// Stop a batch after a cancel: drop the queue and release the claim together.
fn finish_batch() {
    let mut queue = queue_lock();
    queue.clear();
    RUNNING.store(false, Ordering::SeqCst);
}

fn set_current(id: Option<&str>) {
    let mut current = CURRENT.lock().unwrap_or_else(|error| error.into_inner());
    *current = id.map(str::to_string);
}

/// Queued manual runs, oldest first.
pub fn queued_ids() -> Vec<String> {
    queue_lock().clone()
}

/// Task id of the active run, if any.
pub fn current_task_id() -> Option<String> {
    CURRENT
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .clone()
}

/// Scheduler state for the UI: queued ids, the running id and whether a cancel
/// is pending. Never persisted.
pub fn queue_snapshot() -> Value {
    json!({
        "queued": queued_ids(),
        "running": current_task_id(),
        "cancelling": CANCEL.load(Ordering::SeqCst),
    })
}

/// "Cancel current": drop every queued manual run and abort the in-flight
/// request. The cancelled task keeps its normal schedule and is never retried.
pub fn cancel() -> Value {
    let mut queue = queue_lock();
    queue.clear();
    let running = RUNNING.load(Ordering::SeqCst);
    if running {
        CANCEL.store(true, Ordering::SeqCst);
    }
    drop(queue);
    json!({
        "status": if running { "cancelling" } else { "idle" },
        "queued": Vec::<String>::new(),
        "running": current_task_id(),
    })
}

/// Run one task, then every queued manual request, one at a time. The claim is
/// held for the whole batch and released by `next_queued_or_finish` or
/// `finish_batch`, so the schedule and the queue never overlap.
async fn run_batch(
    settings: &settings::Settings,
    app: &tauri::AppHandle,
    first: Task,
    guard: RunGuard,
) {
    let mut next = Some(first);
    while let Some(task) = next {
        let outcome = run_and_record(settings, &task).await;
        notify_outcome(app, settings, &task.name, &outcome);
        if CANCEL.load(Ordering::SeqCst) {
            // The user asked for everything to stop: no drain, no schedule.
            finish_batch();
            break;
        }
        next = next_queued_or_finish();
    }
    drop(guard);
}

/// One scheduler tick: at most one due task, serial with every other run.
pub async fn tick(settings: &settings::Settings, app: &tauri::AppHandle) {
    // A queued manual run has priority: the schedule must not start while the
    // queue is waiting.
    if !queue_lock().is_empty() {
        return;
    }
    let Some(guard) = RunGuard::try_acquire() else {
        return;
    };
    let store = load();
    let Some(task) = due_task(&store, now_secs()).cloned() else {
        return;
    };
    if !pool_allows(&task) {
        return;
    }
    run_batch(settings, app, task, guard).await;
}

/// Account-pool models need at least one usable Codex account. Namespaced
/// provider models route independently.
fn pool_allows(task: &Task) -> bool {
    if task.model.contains('/') || task.model.starts_with("claude-") {
        return true;
    }
    let accounts = vault::accounts();
    accounts.is_empty() || accounts.iter().any(|account| !account.is_blocked())
}

/// "Run now" runs whatever the task state is (disabled included) and advances
/// the schedule. When a run is already active the request joins the queue and
/// the call returns at once, so the UI never blocks on a 300 s run.
pub async fn run_now(
    settings: &settings::Settings,
    id: &str,
    app: &tauri::AppHandle,
) -> Result<Value, String> {
    let task = load()
        .tasks
        .into_iter()
        .find(|task| task.id == id)
        .ok_or_else(|| "задача не найдена".to_string())?;
    match claim_or_enqueue(&task.id) {
        Claim::Started(guard) => {
            run_batch(settings, app, task, guard).await;
            Ok(view())
        }
        Claim::Queued => Ok(json!({
            "status": "queued",
            "id": task.id,
            "queued": queued_ids(),
            "running": current_task_id(),
        })),
    }
}

async fn run_and_record(settings: &settings::Settings, task: &Task) -> Outcome {
    // Every run starts clean: a cancel meant for an earlier run must not abort
    // this one.
    CANCEL.store(false, Ordering::SeqCst);
    set_current(Some(&task.id));
    mark_running(&task.id);
    // Daily budget: checked before every request, scheduled or manual. A
    // reached limit sends nothing, spends nothing and is never retried.
    let started = now_secs();
    let store = load();
    let outcome = match daily_limit_message(task, &store.history, started) {
        Some(message) => skipped_outcome(message),
        None => execute(settings.port, &settings.api_key, task).await,
    };
    let at = now_secs();
    // Re-read after the request: a concurrent edit must not be overwritten by
    // the store snapshot taken before the (up to 300 s) run.
    let mut store = load();
    if apply_outcome(&mut store, &task.id, at, &outcome).is_ok() {
        let _ = save(&store);
    }
    set_current(None);
    outcome
}

/// Toast after every run, gated by the master switch and the scheduler toggle.
/// A cancelled run is user-initiated, so it stays silent.
fn notify_outcome(
    app: &tauri::AppHandle,
    settings: &settings::Settings,
    task_name: &str,
    outcome: &Outcome,
) {
    if !settings.notifications || !settings.notify_scheduler {
        return;
    }
    if outcome.status == STATUS_CANCELLED {
        return;
    }
    let (title, body) = notification_text(settings.lang == "en", task_name, outcome);
    let _ = app
        .notification()
        .builder()
        .title(title)
        .body(body)
        .show();
}

/// The first 120 characters of the result (success) or error (failure).
pub fn notification_text(english: bool, task_name: &str, outcome: &Outcome) -> (String, String) {
    let ok = outcome.status == "ok";
    let title = match (english, ok) {
        (true, true) => "Melon Tools · task completed",
        (true, false) => "Melon Tools · task failed",
        (false, true) => "Melon Tools · задача выполнена",
        (false, false) => "Melon Tools · задача с ошибкой",
    };
    let raw = if ok {
        outcome.result.as_str()
    } else {
        outcome.error.as_deref().unwrap_or("")
    };
    let prefix = notification_prefix(raw, 120);
    let body = if prefix.is_empty() {
        task_name.to_string()
    } else {
        format!("{}: {}", task_name, prefix)
    };
    (title.to_string(), body)
}

/// First non-empty line, trimmed and cut to `cap` characters on a UTF-8
/// boundary. Notifications are diagnostics, not the full result.
pub fn notification_prefix(text: &str, cap: usize) -> String {
    let line = text
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .unwrap_or("");
    line.chars().take(cap).collect()
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
        // Only a transport/gateway failure retries, with a bounded backoff;
        // after the limit the normal cron/interval schedule resumes. Cancelled
        // and skipped runs are not failures to retry: they keep the normal
        // schedule and the retry counter untouched. A manual run of a disabled
        // task must not arm a schedule.
        if outcome.status == STATUS_ERROR && task.enabled && task.retry_attempt < task.retry_limit {
            task.retry_attempt += 1;
            task.next_run_at = Some(at + task.retry_delay_minutes.max(1) * 60);
            let suffix = format!("retry {}/{}", task.retry_attempt, task.retry_limit);
            task.last_error = Some(format!(
                "{} · {}",
                outcome.error.clone().unwrap_or_default(),
                suffix
            ));
        } else {
            if outcome.status == STATUS_OK {
                task.retry_attempt = 0;
            }
            task.next_run_at = if task.enabled {
                // +1 s for cron only: `at` has whole-second precision, and a
                // fast run can finish in the same minute it was due.
                let reference = if task.schedule_kind == SCHEDULE_CRON {
                    at + 1
                } else {
                    at
                };
                next_run_for(
                    &task.schedule_kind,
                    task.interval_minutes,
                    task.cron_expression.as_deref(),
                    task.time_zone.as_deref(),
                    reference,
                )
                .ok()
            } else {
                None
            };
        }
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
    let mut prompt = task.prompt.clone();
    if task.include_git_context {
        if let Some(directory) = task
            .working_directory
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            let context = git_context(directory);
            if !context.is_empty() {
                prompt.push_str("\n\nRepository context (read-only):\n");
                prompt.push_str(&context);
            }
        }
    }
    let mut body = json!({
        "model": task.model,
        "messages": [{ "role": "user", "content": prompt }],
        "stream": false,
    });
    if let Some(effort) = task
        .reasoning_effort
        .as_deref()
        .filter(|value| !value.is_empty())
    {
        body["reasoning_effort"] = json!(effort);
    }
    if let Some(max_tokens) = task.max_tokens {
        body["max_tokens"] = json!(max_tokens);
    }
    body
}

/// Bounded read-only git context for a scheduled task. `git` must be on PATH;
/// a missing repository/tool simply yields no context.
fn git_context(directory: &str) -> String {
    if !std::path::Path::new(directory).is_dir() {
        return String::new();
    }
    let run = |args: &[&str]| -> String {
        let output = std::process::Command::new("git")
            .args(args)
            .current_dir(directory)
            .output();
        match output {
            Ok(output) if output.status.success() => {
                String::from_utf8_lossy(&output.stdout).trim().to_string()
            }
            _ => String::new(),
        }
    };
    if run(&["rev-parse", "--is-inside-work-tree"]).is_empty() {
        return String::new();
    }
    let mut text = String::new();
    let commands: [(&str, &[&str]); 3] = [
        ("status --short", &["status", "--short"]),
        ("log -5 --oneline", &["log", "-5", "--oneline", "--decorate"]),
        ("diff --stat", &["diff", "--stat"]),
    ];
    for (label, args) in commands {
        let out = run(args);
        if !out.is_empty() {
            text.push_str("$ git ");
            text.push_str(label);
            text.push('\n');
            text.push_str(&out);
            text.push('\n');
        }
    }
    text.chars().take(12_000).collect()
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

fn skipped_outcome(message: String) -> Outcome {
    Outcome {
        status: STATUS_SKIPPED.to_string(),
        error: Some(message),
        ..Outcome::default()
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
    fn success_notification_uses_the_result_prefix() {
        let outcome = Outcome {
            status: "ok".to_string(),
            result: "  first line  \nsecond line".to_string(),
            ..Outcome::default()
        };
        let (title, body) = notification_text(true, "Nightly", &outcome);
        assert_eq!(title, "Melon Tools · task completed");
        assert_eq!(body, "Nightly: first line");
    }

    #[test]
    fn error_notification_keeps_the_verbatim_prefix() {
        let outcome = Outcome {
            status: "error".to_string(),
            error: Some(format!("{}tail", "e".repeat(200))),
            ..Outcome::default()
        };
        let (title, body) = notification_text(true, "Nightly", &outcome);
        assert_eq!(title, "Melon Tools · task failed");
        assert_eq!(body, format!("Nightly: {}", "e".repeat(120)));
        assert!(notification_prefix(&"ё".repeat(200), 120).chars().count() == 120);
    }

    #[test]
    fn empty_notification_prefix_falls_back_to_the_name() {
        let outcome = Outcome {
            status: "error".to_string(),
            error: None,
            ..Outcome::default()
        };
        let (_, body) = notification_text(false, "Ночной отчёт", &outcome);
        assert_eq!(body, "Ночной отчёт");
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

    fn utc_at(year: i32, month: u32, day: u32, hour: u32, minute: u32) -> i64 {
        NaiveDate::from_ymd_opt(year, month, day)
            .unwrap()
            .and_hms_opt(hour, minute, 0)
            .unwrap()
            .and_utc()
            .timestamp()
    }

    #[test]
    fn cron_steps_fire_on_the_next_quarter_hour() {
        // Tuesday 20 October 2026, 08:07 UTC.
        let now = utc_at(2026, 10, 20, 8, 7);
        let next = next_run_for("cron", 60, Some("*/15 * * * *"), Some("UTC"), now).unwrap();
        assert_eq!(next, utc_at(2026, 10, 20, 8, 15));

        // A run finishes a few seconds after the exact fire time, so the next
        // fire is the following quarter hour.
        let next = next_run_for("cron", 60, Some("*/15 * * * *"), Some("UTC"), next + 5).unwrap();
        assert_eq!(next, utc_at(2026, 10, 20, 8, 30));
    }

    #[test]
    fn cron_weekdays_and_names_skip_the_weekend() {
        // Saturday 24 October 2026, 12:00 UTC.
        let saturday = utc_at(2026, 10, 24, 12, 0);
        let next = next_run_for("cron", 60, Some("0 9 * * MON-FRI"), Some("UTC"), saturday)
            .unwrap();
        assert_eq!(next, utc_at(2026, 10, 26, 9, 0), "Monday 09:00");
    }

    #[test]
    fn cron_day_of_month_and_weekday_use_or_semantics() {
        // Sunday 1 November 2026. The 13th or the first Friday after it.
        let now = utc_at(2026, 11, 1, 0, 0);
        let next = next_run_for("cron", 60, Some("0 0 13 * 5"), Some("UTC"), now).unwrap();
        assert_eq!(next, utc_at(2026, 11, 6, 0, 0), "Friday wins over the 13th");
    }

    #[test]
    fn cron_accepts_ranges_lists_and_steps() {
        let now = utc_at(2026, 10, 20, 8, 7);
        let schedule = parse_cron("5,10-20/5 8 * * *").unwrap();
        assert_eq!(schedule.minutes, vec![5, 10, 15, 20]);
        assert_eq!(schedule.hours, vec![8]);
        let next = schedule.next_fire(TaskZone::Fixed(FixedOffset::east_opt(0).unwrap()), now).unwrap();
        assert_eq!(next, utc_at(2026, 10, 20, 8, 10));
    }

    #[test]
    fn cron_rejects_invalid_expressions_and_time_zones() {
        assert!(parse_cron("* * * *").is_err());
        assert!(parse_cron("60 * * * *").is_err());
        assert!(parse_cron("*/0 * * * *").is_err());
        assert!(parse_cron("10-1 * * * *").is_err());
        assert!(parse_cron("* * 32 * *").is_err());
        assert!(parse_cron("* * * FOO *").is_err());
        assert!(next_run_for("cron", 60, Some("0 0 31 2 *"), Some("UTC"), 0).is_err());
        assert!(next_run_for("cron", 60, Some("* * * * *"), Some("Europe/Moscow"), 0).is_err());
        assert!(next_run_for("cron", 60, Some("* * * * *"), Some("+25:00"), 0).is_err());
        assert!(next_run_for("cron", 60, None, Some("UTC"), 0).is_err());
        assert!(next_run_for("weekly", 60, None, None, 0).is_err());
    }

    #[test]
    fn fixed_time_zone_shifts_the_next_fire() {
        let now = utc_at(2026, 10, 20, 5, 0); // 08:00 in +03:00
        let next = next_run_for("cron", 60, Some("0 9 * * *"), Some("+03:00"), now).unwrap();
        assert_eq!(next, utc_at(2026, 10, 20, 6, 0));
        assert_eq!(normalize_time_zone(Some("UTC+3")).unwrap().as_deref(), Some("+03:00"));
        assert_eq!(normalize_time_zone(Some("local")).unwrap(), None);
    }

    #[test]
    fn legacy_tasks_default_to_interval_and_cron_fields_round_trip() {
        let legacy: Task = serde_json::from_str(r#"{"id":"old","name":"n"}"#).unwrap();
        assert_eq!(legacy.schedule_kind, SCHEDULE_INTERVAL);
        assert!(legacy.cron_expression.is_none());
        assert!(legacy.time_zone.is_none());

        let mut value = task("cron");
        value.schedule_kind = SCHEDULE_CRON.to_string();
        value.cron_expression = Some("0 9 * * 1-5".to_string());
        value.time_zone = Some("+03:00".to_string());
        let json = serde_json::to_value(&value).unwrap();
        assert_eq!(json["scheduleKind"], "cron");
        assert_eq!(json["cronExpression"], "0 9 * * 1-5");
        assert_eq!(json["timeZone"], "+03:00");
        let back: Task = serde_json::from_value(json).unwrap();
        assert_eq!(back, value);
    }

    #[test]
    fn failed_run_uses_bounded_retry_before_the_interval() {
        let mut stored = task("a");
        stored.retry_limit = 2;
        stored.retry_delay_minutes = 1;
        stored.next_run_at = Some(0);
        let mut store = Store {
            tasks: vec![stored],
            history: Vec::new(),
        };
        let outcome = Outcome {
            status: "error".to_string(),
            error: Some("HTTP 500".to_string()),
            ..Outcome::default()
        };
        apply_outcome(&mut store, "a", 1_000, &outcome).unwrap();
        assert_eq!(store.tasks[0].retry_attempt, 1);
        assert_eq!(store.tasks[0].next_run_at, Some(1_060));
        assert!(store.tasks[0]
            .last_error
            .as_deref()
            .unwrap_or("")
            .contains("retry 1/2"));
    }

    #[test]
    fn daily_limit_counts_only_today_and_blocks_the_request() {
        let now = 1_760_000_000;
        let mut stored = task("a");
        stored.daily_token_limit = Some(20);
        let history = vec![entry("a", now), entry("a", now), entry("b", now)];
        assert_eq!(tokens_used_today("a", &history, now), 20);
        assert_eq!(
            daily_limit_message(&stored, &history, now).as_deref(),
            Some("Daily token limit reached (20/20)")
        );
        stored.daily_token_limit = Some(21);
        assert!(daily_limit_message(&stored, &history, now).is_none());
    }

    #[test]
    fn cancelled_and_skipped_runs_keep_the_normal_schedule_without_retry() {
        for status in [STATUS_CANCELLED, STATUS_SKIPPED] {
            let mut stored = task("a");
            stored.retry_limit = 3;
            stored.retry_delay_minutes = 1;
            let mut store = Store {
                tasks: vec![stored],
                history: Vec::new(),
            };
            let outcome = Outcome {
                status: status.to_string(),
                error: Some("not a retry".to_string()),
                ..Outcome::default()
            };
            apply_outcome(&mut store, "a", 1_000, &outcome).unwrap();
            assert_eq!(store.tasks[0].last_status, status);
            assert_eq!(store.tasks[0].retry_attempt, 0);
            assert_ne!(store.tasks[0].next_run_at, Some(1_060));
        }
    }

    #[test]
    fn queue_dedupes_and_skips_unknown_tasks() {
        let mut queue = Vec::new();
        assert!(push_queued(&mut queue, "a"));
        assert!(!push_queued(&mut queue, "a"));
        assert!(!push_queued(&mut queue, ""));
        assert_eq!(queue, vec!["a".to_string()]);
        let tasks = vec![task("b")];
        assert!(pop_known_task(&mut queue, &tasks).is_none());
        assert!(queue.is_empty());
    }

    #[test]
    fn cron_input_schedules_the_next_fire_and_advances_after_a_run() {
        let now = utc_at(2026, 10, 20, 8, 7);
        let mut payload = input("cron task", 60, true);
        payload.schedule_kind = SCHEDULE_CRON.to_string();
        payload.cron_expression = Some("0 9 * * *".to_string());
        payload.time_zone = Some("UTC".to_string());
        let valid = validate(&payload).unwrap();
        let mut stored = task("a");
        apply_input(&mut stored, &valid, now);
        assert_eq!(stored.next_run_at, Some(utc_at(2026, 10, 20, 9, 0)));

        let outcome = Outcome {
            status: "ok".to_string(),
            ..Outcome::default()
        };
        let mut store = Store {
            tasks: vec![stored],
            history: Vec::new(),
        };
        // Even a run that finishes in the same second must move to tomorrow.
        apply_outcome(&mut store, "a", utc_at(2026, 10, 20, 9, 0), &outcome).unwrap();
        assert_eq!(
            store.tasks[0].next_run_at,
            Some(utc_at(2026, 10, 21, 9, 0)),
            "the next run is tomorrow at 09:00"
        );
    }
}
