//! Melon Tools for Windows — Codex account pool, local API gateway, chips
//! bridge and the Fleet/instances tooling. Tauri 2 backend with the same
//! vault and gateway layout as the macOS app.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod bridge;
mod codex_route;
mod device_login;
mod engine;
mod fleet;
mod gateway;
mod instances;
mod paths;
mod providers;
mod quota;
mod routing;
mod settings;
mod updater;
mod vault;

use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Mutex;
use tauri::{Manager, State};
use tauri_plugin_notification::NotificationExt;

pub struct AppState {
    pub gw: gateway::Gateway,
    pub bridge: bridge::BridgeState,
    pub settings: Mutex<settings::Settings>,
    /// Low-quota notification cooldowns: "<account>:<window>" → unix seconds.
    pub notified: Mutex<HashMap<String, i64>>,
    /// Engine watchdog bookkeeping.
    pub watchdog: Mutex<Watchdog>,
}

/// Keeps the local engine alive: after we started (or adopted) the gateway,
/// two consecutive failed health probes trigger a bounded restart — unless
/// the user stopped it explicitly.
#[derive(Default, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Watchdog {
    pub supervised: bool,
    pub user_stopped: bool,
    #[serde(skip)]
    pub misses: u32,
    pub restarts: u32,
    pub last_restart: Option<String>,
}

impl AppState {
    fn settings(&self) -> settings::Settings {
        self.settings.lock().map(|s| s.clone()).unwrap_or_default()
    }
}

fn hidden_command(_command: &mut std::process::Command) {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        _command.creation_flags(0x0800_0000);
    }
}

// MARK: - App info / settings

#[tauri::command]
fn app_info() -> Value {
    json!({
        "name": "Melon Tools",
        "version": "1.4.8",
        "platform": std::env::consts::OS,
        "dataDir": paths::appdata_dir().to_string_lossy(),
        "codexHome": paths::codex_home().to_string_lossy(),
        "enginePath": engine::engine_path().to_string_lossy(),
        "fleetHome": fleet::path_home_display(&settings::load()),
    })
}

#[tauri::command]
async fn settings_get(state: State<'_, AppState>) -> Result<Value, String> {
    serde_json::to_value(state.settings()).map_err(|e| e.to_string())
}

#[tauri::command]
async fn settings_set(
    state: State<'_, AppState>,
    settings: settings::Settings,
) -> Result<Value, String> {
    let mut merged = settings;
    if merged.api_key.trim().is_empty() {
        merged.api_key = state.settings().api_key;
    }
    settings::save(&merged)?;
    if let Ok(mut guard) = state.settings.lock() {
        *guard = merged.clone();
    }
    serde_json::to_value(merged).map_err(|e| e.to_string())
}

// MARK: - Gateway

#[tauri::command]
async fn gateway_status(state: State<'_, AppState>) -> Result<Value, String> {
    let settings = state.settings();
    let running = gateway::health(settings.port, &settings.api_key).await;
    Ok(json!({
        "running": running,
        "port": settings.port,
        "requestsLastMinute": gateway::requests_last_minute(),
        "sidecarFound": gateway::resolve_sidecar().is_some(),
        "dataDir": paths::appdata_dir().to_string_lossy(),
        "logPath": paths::log_path().to_string_lossy(),
        "watchdog": state
            .watchdog
            .lock()
            .map(|w| w.clone())
            .unwrap_or_default(),
    }))
}

#[tauri::command]
async fn gateway_start(state: State<'_, AppState>) -> Result<String, String> {
    let settings = state.settings();
    let result = gateway::start(&state.gw, &settings).await?;
    let _ = codex_route::apply(settings.port, &settings.api_key);
    if let Ok(client) = quota::client() {
        let _ = codex_route::sync_catalog(&client, settings.port, &settings.api_key).await;
    }
    if let Ok(mut guard) = state.watchdog.lock() {
        guard.supervised = true;
        guard.user_stopped = false;
        guard.misses = 0;
        // A manual start resets the restart budget: the user asked for it.
        guard.restarts = 0;
    }
    Ok(result)
}

#[tauri::command]
async fn gateway_stop(state: State<'_, AppState>) -> Result<String, String> {
    let result = gateway::stop(&state.gw)?;
    let _ = codex_route::remove();
    if let Ok(mut guard) = state.watchdog.lock() {
        guard.user_stopped = true;
        guard.supervised = false;
    }
    Ok(result)
}

/// Rewrites config.yaml + gateway auth files from the vault.
#[tauri::command]
async fn gateway_sync(state: State<'_, AppState>) -> Result<Value, String> {
    let settings = state.settings();
    gateway::write_config(&settings)?;
    let written = gateway::sync_accounts(&settings)?;
    Ok(json!({ "syncedAccounts": written }))
}

#[tauri::command]
async fn gateway_check(state: State<'_, AppState>) -> Result<String, String> {
    let settings = state.settings();
    gateway::check_api(settings.port, &settings.api_key).await
}

#[tauri::command]
async fn gateway_recent_calls(limit: Option<usize>) -> Result<Value, String> {
    Ok(gateway::recent_calls(limit.unwrap_or(10)))
}

#[tauri::command]
async fn gateway_models(state: State<'_, AppState>) -> Result<Value, String> {
    let settings = state.settings();
    gateway::models(settings.port, &settings.api_key).await
}

// MARK: - Vault + quotas

#[tauri::command]
async fn vault_list() -> Result<Vec<Value>, String> {
    Ok(vault::list_views())
}

#[tauri::command]
async fn quota_refresh(
    app: tauri::AppHandle,
    state: State<'_, AppState>,
    id: Option<String>,
) -> Result<Value, String> {
    let client = quota::client()?;
    let errors = quota::refresh_all(&client, id.as_deref()).await;
    let settings = state.settings();
    let synced = if gateway::health(settings.port, &settings.api_key).await {
        gateway::sync_accounts(&settings).unwrap_or(0)
    } else {
        0
    };
    check_low_quota(&app, &state);
    Ok(json!({
        "accounts": vault::list_views(),
        "errors": errors,
        "syncedAccounts": synced,
    }))
}

fn check_low_quota(app: &tauri::AppHandle, state: &AppState) {
    let settings = state.settings();
    if !settings.notify_low_quota {
        return;
    }
    let now = chrono::Utc::now().timestamp();
    let Ok(mut cache) = state.notified.lock() else {
        return;
    };
    for account in vault::accounts() {
        let Some(quota) = account.quota.clone() else {
            continue;
        };
        let checks = [
            ("5h", quota.hourly_remaining_percent, 3600i64, "5-часовое окно"),
            ("week", quota.weekly_remaining_percent, 21600i64, "недельное окно"),
        ];
        for (kind, remaining, cooldown, label) in checks {
            let Some(remaining) = remaining else {
                continue;
            };
            if remaining > 10.0 {
                continue;
            }
            let key = format!("{}:{}", account.id, kind);
            let last = cache.get(&key).copied().unwrap_or(0);
            if now - last < cooldown {
                continue;
            }
            cache.insert(key, now);
            let body = format!(
                "{}: осталось {}% ({})",
                account.display_name(),
                remaining.round() as i64,
                label
            );
            let _ = app
                .notification()
                .builder()
                .title("Melon Tools · низкая квота")
                .body(body)
                .show();
        }
    }
}

#[tauri::command]
async fn switch_account(state: State<'_, AppState>, id: String) -> Result<Value, String> {
    let account = vault::accounts()
        .into_iter()
        .find(|a| a.id == id)
        .ok_or_else(|| "аккаунт не найден".to_string())?;
    let path = vault::write_codex_auth(&account)?;
    let mut raw = vault::load_raw();
    raw["currentAccountId"] = json!(id);
    vault::save_raw(&raw)?;
    let settings = state.settings();
    if gateway::health(settings.port, &settings.api_key).await {
        let _ = gateway::sync_accounts(&settings);
    }
    Ok(json!({ "authPath": path.to_string_lossy() }))
}

#[tauri::command]
async fn import_current_auth(state: State<'_, AppState>) -> Result<Value, String> {
    let tokens = vault::read_codex_auth_tokens()
        .ok_or_else(|| "не нашёл %USERPROFILE%\\.codex\\auth.json — войдите в Codex".to_string())?;
    let result = vault::upsert_from_tokens(&tokens)?;
    let settings = state.settings();
    if gateway::health(settings.port, &settings.api_key).await {
        let _ = gateway::sync_accounts(&settings);
    }
    Ok(json!({ "result": result, "accounts": vault::list_views() }))
}

#[tauri::command]
async fn account_refresh_tokens(id: String) -> Result<Vec<Value>, String> {
    let account = vault::accounts()
        .into_iter()
        .find(|a| a.id == id)
        .ok_or_else(|| "аккаунт не найден".to_string())?;
    let client = quota::client()?;
    let tokens = quota::refresh_tokens(&client, &account).await?;
    vault::update_tokens(&id, &tokens, &chrono::Utc::now().to_rfc3339())?;
    Ok(vault::list_views())
}

#[tauri::command]
async fn save_reserves(
    state: State<'_, AppState>,
    id: String,
    hourly: Option<i64>,
    weekly: Option<i64>,
) -> Result<Vec<Value>, String> {
    vault::set_account_field(&id, move |item| {
        item["hourlyReservePercent"] = json!(hourly);
        item["weeklyReservePercent"] = json!(weekly);
    })?;
    let settings = state.settings();
    if gateway::health(settings.port, &settings.api_key).await {
        let _ = gateway::sync_accounts(&settings);
    }
    Ok(vault::list_views())
}

#[tauri::command]
async fn delete_account(state: State<'_, AppState>, id: String) -> Result<Vec<Value>, String> {
    vault::delete_account(&id)?;
    let settings = state.settings();
    if gateway::health(settings.port, &settings.api_key).await {
        let _ = gateway::sync_accounts(&settings);
    }
    Ok(vault::list_views())
}

// MARK: - Device login (add an account)

#[tauri::command]
async fn device_login_start() -> Result<Value, String> {
    let client = quota::client()?;
    device_login::start(&client).await
}

#[tauri::command]
async fn device_login_poll(
    state: State<'_, AppState>,
    device_auth_id: String,
    user_code: String,
) -> Result<Value, String> {
    let client = quota::client()?;
    match device_login::poll(&client, &device_auth_id, &user_code).await? {
        Some(tokens) => {
            let result = vault::upsert_from_tokens(&tokens)?;
            let settings = state.settings();
            if gateway::health(settings.port, &settings.api_key).await {
                let _ = gateway::sync_accounts(&settings);
            }
            Ok(json!({ "done": true, "result": result, "accounts": vault::list_views() }))
        }
        None => Ok(json!({ "done": false })),
    }
}

// MARK: - Routing

#[tauri::command]
async fn routing_state(state: State<'_, AppState>) -> Result<Value, String> {
    let settings = state.settings();
    let accounts = vault::accounts();
    let (ordered, blocked) = routing::resolve(
        &accounts,
        &settings.routing_strategy,
        &settings.priority_order,
    );
    Ok(json!({
        "strategy": settings.routing_strategy,
        "strategies": routing::STRATEGIES,
        "priorityOrder": settings.priority_order,
        "orderedIds": ordered,
        "blockedIds": blocked,
    }))
}

#[tauri::command]
async fn set_routing_strategy(state: State<'_, AppState>, strategy: String) -> Result<Value, String> {
    if !routing::STRATEGIES.contains(&strategy.as_str()) {
        return Err(format!("неизвестная стратегия: {}", strategy));
    }
    mutate_settings(&state, |s| s.routing_strategy = strategy)?;
    resync(&state).await
}

#[tauri::command]
async fn move_priority(state: State<'_, AppState>, id: String, up: bool) -> Result<Value, String> {
    mutate_settings(&state, |s| {
        let mut order = s.priority_order.clone();
        if order.is_empty() {
            order = vault::accounts().iter().map(|a| a.id.clone()).collect();
        }
        if let Some(index) = order.iter().position(|value| value == &id) {
            let target = if up {
                index.checked_sub(1)
            } else if index + 1 < order.len() {
                Some(index + 1)
            } else {
                None
            };
            if let Some(target) = target {
                order.swap(index, target);
            }
        }
        s.priority_order = order;
    })?;
    mutate_settings(&state, |s| s.routing_strategy = "custom".to_string())?;
    resync(&state).await
}

#[tauri::command]
async fn reset_priority(state: State<'_, AppState>) -> Result<Value, String> {
    mutate_settings(&state, |s| {
        s.priority_order = vault::accounts().iter().map(|a| a.id.clone()).collect();
    })?;
    resync(&state).await
}

#[tauri::command]
async fn set_account_role(
    state: State<'_, AppState>,
    id: String,
    preferred: bool,
    backup: bool,
) -> Result<Value, String> {
    vault::set_account_field(&id, move |item| {
        item["preferredFirst"] = json!(preferred);
        item["isBackup"] = json!(backup);
    })?;
    resync(&state).await
}

fn mutate_settings(
    state: &State<'_, AppState>,
    mutate: impl FnOnce(&mut settings::Settings),
) -> Result<(), String> {
    let mut guard = state.settings.lock().map_err(|_| "settings lock".to_string())?;
    mutate(&mut guard);
    settings::save(&guard)
}

async fn resync(state: &State<'_, AppState>) -> Result<Value, String> {
    let settings = state.settings();
    if gateway::health(settings.port, &settings.api_key).await {
        let _ = gateway::sync_accounts(&settings);
    }
    let accounts = vault::accounts();
    let (ordered, blocked) =
        routing::resolve(&accounts, &settings.routing_strategy, &settings.priority_order);
    Ok(json!({
        "strategy": settings.routing_strategy,
        "priorityOrder": settings.priority_order,
        "orderedIds": ordered,
        "blockedIds": blocked,
        "accounts": vault::list_views(),
    }))
}

// MARK: - Codex route + chips bridge

#[tauri::command]
async fn codex_route_status() -> Result<Value, String> {
    Ok(codex_route::status())
}

#[tauri::command]
async fn codex_route_apply(state: State<'_, AppState>) -> Result<Value, String> {
    let settings = state.settings();
    codex_route::apply(settings.port, &settings.api_key)?;
    if let Ok(client) = quota::client() {
        let custom = codex_route::sync_catalog(&client, settings.port, &settings.api_key).await?;
        return Ok(json!({ "route": codex_route::status(), "catalogCustom": custom }));
    }
    Ok(json!({ "route": codex_route::status(), "catalogCustom": 0 }))
}

#[tauri::command]
async fn codex_route_remove() -> Result<Value, String> {
    codex_route::remove()?;
    Ok(codex_route::status())
}

#[tauri::command]
async fn bridge_status(state: State<'_, AppState>) -> Result<Value, String> {
    let value = state
        .bridge
        .status
        .lock()
        .map(|v| v.clone())
        .unwrap_or_else(|_| json!({"attached": false}));
    Ok(value)
}

/// Restarts the Codex app with the CDP flags so the chips can attach.
#[tauri::command]
async fn bridge_launch_codex() -> Result<String, String> {
    bridge::launch_codex_with_debug_port().await
}

// MARK: - Fleet

#[tauri::command]
async fn fleet_status(state: State<'_, AppState>) -> Result<Value, String> {
    Ok(fleet::status(&state.settings()))
}

#[tauri::command]
async fn fleet_results(state: State<'_, AppState>, limit: Option<usize>) -> Result<Value, String> {
    Ok(fleet::results(&state.settings(), limit.unwrap_or(100)))
}

#[tauri::command]
async fn fleet_read_result(path: String) -> Result<String, String> {
    fleet::read_result(&path)
}

#[tauri::command]
async fn fleet_config_get(state: State<'_, AppState>) -> Result<Value, String> {
    Ok(fleet::config_get(&state.settings()))
}

#[tauri::command]
async fn fleet_config_set(state: State<'_, AppState>, text: String) -> Result<Value, String> {
    fleet::config_set(&state.settings(), &text)?;
    Ok(fleet::config_get(&state.settings()))
}

#[tauri::command]
async fn fleet_cli(state: State<'_, AppState>, args: Vec<String>) -> Result<String, String> {
    fleet::cli_run(&state.settings(), args).await
}

// MARK: - Instances

#[tauri::command]
async fn instances_list() -> Result<Vec<Value>, String> {
    Ok(instances::list())
}

#[tauri::command]
async fn instance_create(name: String) -> Result<Vec<Value>, String> {
    instances::create(&name)?;
    Ok(instances::list())
}

#[tauri::command]
async fn instance_delete(id: String) -> Result<Vec<Value>, String> {
    instances::delete(&id)
}

#[tauri::command]
async fn instance_bind(id: String, account_id: Option<String>) -> Result<Vec<Value>, String> {
    instances::bind(&id, account_id)
}

#[tauri::command]
async fn instance_launch(id: String) -> Result<String, String> {
    instances::launch(&id)
}

// MARK: - Autostart (HKCU Run key, no admin rights needed)

#[tauri::command]
async fn autostart_get() -> Result<bool, String> {
    #[cfg(windows)]
    {
        let mut command = std::process::Command::new("reg");
        command.args([
            "query",
            "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run",
            "/v",
            "MelonTools",
        ]);
        hidden_command(&mut command);
        return Ok(command.output().map(|o| o.status.success()).unwrap_or(false));
    }
    #[cfg(not(windows))]
    Ok(false)
}

#[tauri::command]
async fn autostart_set(enabled: bool) -> Result<bool, String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    #[cfg(windows)]
    {
        let mut command = std::process::Command::new("reg");
        if enabled {
            let value = format!("\"{}\"", exe.to_string_lossy());
            command.args([
                "add",
                "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run",
                "/v",
                "MelonTools",
                "/t",
                "REG_SZ",
                "/d",
                &value,
                "/f",
            ]);
        } else {
            command.args([
                "delete",
                "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run",
                "/v",
                "MelonTools",
                "/f",
            ]);
        }
        hidden_command(&mut command);
        let output = command.output().map_err(|e| e.to_string())?;
        Ok(output.status.success())
    }
    #[cfg(not(windows))]
    Ok(false)
}

// MARK: - Updater (GitHub releases)

/// Latest release lookup. `force=false` throttles to once per 24 h.
#[tauri::command]
async fn update_check(state: State<'_, AppState>, force: bool) -> Result<Value, String> {
    let settings = state.settings();
    let result =
        updater::check(force, env!("CARGO_PKG_VERSION"), settings.last_update_check).await?;
    if result.get("skipped").and_then(|v| v.as_bool()) != Some(true) {
        let now = chrono::Utc::now().timestamp();
        mutate_settings(&state, |s| s.last_update_check = Some(now))?;
    }
    Ok(result)
}

/// Downloads and verifies the new executable, then hands the swap to a
/// detached script and exits so the file is not locked.
#[tauri::command]
async fn update_apply(
    app: tauri::AppHandle,
    url: String,
    digest: Option<String>,
) -> Result<Value, String> {
    let current = std::env::current_exe().map_err(|e| e.to_string())?;
    let new_exe = updater::fetch_update(&url, digest.as_deref()).await?;
    updater::spawn_swapper(&new_exe, &current, std::process::id())?;
    let handle = app.clone();
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_millis(400)).await;
        handle.exit(0);
    });
    Ok(json!({ "ok": true }))
}

// MARK: - Providers

#[tauri::command]
async fn openrouter_refresh(state: State<'_, AppState>) -> Result<Value, String> {
    let settings = state.settings();
    providers::openrouter(&settings.openrouter_key).await
}

/// Opens an http(s) URL in the default browser (device login page).
#[tauri::command]
async fn open_url(url: String) -> Result<(), String> {
    if !(url.starts_with("https://") || url.starts_with("http://")) {
        return Err("разрешены только http(s)-ссылки".to_string());
    }
    #[cfg(windows)]
    {
        let mut command = std::process::Command::new("cmd");
        command.args(["/C", "start", "", &url]);
        hidden_command(&mut command);
        command.spawn().map_err(|e| e.to_string())?;
        Ok(())
    }
    #[cfg(not(windows))]
    {
        let _ = url;
        Err("открытие ссылок поддерживается на Windows".to_string())
    }
}

// MARK: - Entry point

/// Restarts the engine when it dies while we believe it should run.
async fn watchdog_check(state: &AppState) {
    let (supervised, user_stopped, misses, restarts) = match state.watchdog.lock() {
        Ok(guard) => (
            guard.supervised,
            guard.user_stopped,
            guard.misses,
            guard.restarts,
        ),
        Err(_) => return,
    };
    if !supervised || user_stopped || restarts >= 3 {
        return;
    }
    let settings = state.settings();
    if gateway::health(settings.port, &settings.api_key).await {
        if let Ok(mut guard) = state.watchdog.lock() {
            guard.misses = 0;
        }
        return;
    }
    let missed = misses + 1;
    if let Ok(mut guard) = state.watchdog.lock() {
        guard.misses = missed;
    }
    if missed < 2 {
        return;
    }
    // Every attempt counts toward the bound (a persistently failing start
    // must not retry forever), and the miss counter resets so a failed
    // attempt is followed by a fresh two-miss wait instead of a hot loop.
    let outcome = gateway::start(&state.gw, &settings).await;
    if let Ok(mut guard) = state.watchdog.lock() {
        guard.misses = 0;
        guard.restarts += 1;
        if outcome.is_ok() {
            guard.last_restart = Some(chrono::Utc::now().to_rfc3339());
        }
    }
}

/// Holds the instance lock for the whole process lifetime; the OS releases it
/// even after a crash. A second launch exits instead of racing over the vault.
static INSTANCE_LOCK: std::sync::OnceLock<std::fs::File> = std::sync::OnceLock::new();

fn ensure_single_instance() {
    let dir = paths::appdata_dir();
    let _ = std::fs::create_dir_all(&dir);
    let path = dir.join("app.lock");
    let Ok(file) = std::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(false)
        .open(&path)
    else {
        return; // No lock file — run anyway rather than blocking the app.
    };
    use fs2::FileExt;
    if file.try_lock_exclusive().is_ok() {
        let _ = INSTANCE_LOCK.set(file);
    } else {
        eprintln!("Melon Tools is already running.");
        std::process::exit(0);
    }
}

fn main() {
    ensure_single_instance();
    let initial_settings = settings::load();

    tauri::Builder::default()
        .plugin(tauri_plugin_notification::init())
        .manage(AppState {
            gw: gateway::Gateway::new(),
            bridge: bridge::BridgeState::new(),
            settings: Mutex::new(initial_settings),
            notified: Mutex::new(HashMap::new()),
            watchdog: Mutex::new(Watchdog::default()),
        })
        .setup(|app| {
            // System tray: open window / quit.
            let open_item =
                tauri::menu::MenuItem::with_id(app, "open", "Открыть Melon Tools", true, None::<&str>)?;
            let quit_item = tauri::menu::MenuItem::with_id(app, "quit", "Выход", true, None::<&str>)?;
            let menu = tauri::menu::Menu::with_items(app, &[&open_item, &quit_item])?;
            let icon = tauri::image::Image::from_bytes(include_bytes!("../icons/icon.png"))?;
            tauri::tray::TrayIconBuilder::new()
                .icon(icon)
                .menu(&menu)
                .tooltip("Melon Tools")
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "open" => {
                        if let Some(window) = app.get_webview_window("main") {
                            let _ = window.show();
                            let _ = window.set_focus();
                        }
                    }
                    "quit" => app.exit(0),
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let tauri::tray::TrayIconEvent::Click { .. } = event {
                        let app = tray.app_handle();
                        if let Some(window) = app.get_webview_window("main") {
                            let _ = window.show();
                            let _ = window.set_focus();
                        }
                    }
                })
                .build(app)?;

            // Auto-start the gateway, point Codex at it, then keep the chips
            // bridge ticking every 5 seconds.
            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                {
                    let state = handle.state::<AppState>();
                    let settings = state.settings();
                    if gateway::start(&state.gw, &settings).await.is_ok() {
                        let _ = codex_route::apply(settings.port, &settings.api_key);
                        if let Ok(client) = quota::client() {
                            let _ =
                                codex_route::sync_catalog(&client, settings.port, &settings.api_key)
                                    .await;
                        }
                        // Arm the watchdog: without this the auto-started
                        // engine would get no auto-restart after a crash.
                        if let Ok(mut guard) = state.watchdog.lock() {
                            guard.supervised = true;
                            guard.user_stopped = false;
                            guard.misses = 0;
                        }
                    }
                }
                let mut tick: u64 = 0;
                loop {
                    {
                        let state = handle.state::<AppState>();
                        let settings = state.settings();
                        bridge::tick(&state.bridge, &settings).await;
                        tick += 1;
                        if tick % 6 == 0 {
                            watchdog_check(&state).await;
                        }
                    }
                    tokio::time::sleep(std::time::Duration::from_secs(5)).await;
                }
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            app_info,
            settings_get,
            settings_set,
            gateway_status,
            gateway_start,
            gateway_stop,
            gateway_sync,
            gateway_check,
            gateway_recent_calls,
            gateway_models,
            vault_list,
            quota_refresh,
            switch_account,
            import_current_auth,
            account_refresh_tokens,
            save_reserves,
            delete_account,
            device_login_start,
            device_login_poll,
            routing_state,
            set_routing_strategy,
            move_priority,
            reset_priority,
            set_account_role,
            codex_route_status,
            codex_route_apply,
            codex_route_remove,
            bridge_status,
            bridge_launch_codex,
            fleet_status,
            fleet_results,
            fleet_read_result,
            fleet_config_get,
            fleet_config_set,
            fleet_cli,
            instances_list,
            instance_create,
            instance_delete,
            instance_bind,
            instance_launch,
            autostart_get,
            autostart_set,
            update_check,
            update_apply,
            openrouter_refresh,
            open_url,
        ])
        .run(tauri::generate_context!())
        .expect("Melon Tools failed to start");
}
