// Melon Tools for Windows — UI (vanilla JS, no build step).
// The Tauri backend is called through window.__TAURI__.core.invoke; without
// Tauri (plain browser preview) a small mock answers with demo data so the
// design can be reviewed anywhere.

const IS_TAURI = !!(window.__TAURI__ && window.__TAURI__.core);

// MARK: - i18n

const DICT = {
  ru: {
    dashboard: "Дашборд", accounts: "Аккаунты", api: "API Service", providers: "Провайдеры", donate: "Донат", settings: "Настройки",
    codex: "Codex", general: "Приложение",
    dashTitle: "Обзор", dashSub: "Локальный шлюз Codex, пул аккаунтов и провайдеры — одним взглядом.",
    gateway: "Шлюз", running: "работает", stopped: "остановлен", starting: "запускается…",
    start: "Запустить", stop: "Остановить", restart: "Перезапустить", check: "Проверить API", refresh: "Обновить", sync: "Синхронизировать с шлюзом",
    port: "Порт", reqs: "Запросы/мин", sidecar: "движок", found: "найден", missing: "не найден",
    poolSummary: "Пул аккаунтов", accountsCount: "аккаунтов", pool5h: "5ч (суммарно)", poolWeek: "Неделя (суммарно)",
    blockedNow: "на паузе", allReady: "все готовы",
    quick: "Быстрые действия", refreshQuotas: "Обновить квоты", importAuth: "Импортировать текущий вход Codex",
    accountsSub: "Пул ChatGPT-аккаунтов: квоты, пауза по резерву, переключение входа Codex.",
    importHint: "Читает %USERPROFILE%\\.codex\\auth.json и добавляет аккаунт в пул.",
    fiveHour: "5 ч", week: "Неделя", resetIn: "сброс", resetNow: "сброс вот-вот", onceReset: "при первом запросе",
    reserveHourly: "Резерв 5ч, %", reserveWeekly: "Резерв недели, %", save: "Сохранить",
    makeCurrent: "Сделать текущим", refreshLogin: "Обновить логин", refreshQuota: "Обновить квоту", remove: "Удалить",
    current: "текущий", paused: "на паузе", ready: "готов",
    bHourly: "5-часовое окно исчерпано", bWeekly: "недельное окно исчерпано",
    bHourlyReserve: "осталось {r}% ≤ резерва {l}%", bWeeklyReserve: "осталось {r}% ≤ резерва {l}%",
    quotaAge: "квота обновлена", never: "никогда", stale: "устарела",
    history: "История", historyHint: "Остаток квоты по последним обновлениям.",
    notificationsHint: "Тост, когда остаток пересекает резерв аккаунта (или 10%).",
    apiSub: "Локальный OpenAI-совместимый шлюз для Codex: пул аккаунтов, апстримы, ключ доступа.",
    endpoint: "Адрес", apiKey: "Ключ", copy: "Копировать", copied: "Скопировано",
    endpointsTitle: "Endpoint-ы", checkTitle: "Сквозная проверка", checkHint: "маленький запрос через пул — видно, что шлюз обслуживает модели.",
    checkResult: "Результат", logFile: "Журнал", dataDir: "Данные",
    codexRoute: "Интеграция с Codex", routeApply: "Настроить Codex", routeRemove: "Снять настройку",
    routeActive: "Codex направлен в шлюз", routeInactive: "Codex использует свой провайдер",
    routeOther: "Codex настроен другим инструментом", catalog: "Каталог моделей", bridge: "Чипы в композере",
    bridgeOn: "подключены", bridgeOff: "нет связи", bridgeHint: "Codex должен быть запущен с --remote-debugging-port",
    bridgeRestart: "Перезапустить Codex с чипами",
    bridgeRestartConfirm: "Codex будет закрыт и запущен заново с debug-портом (нужен для чипов). Продолжить?",
    bridgeRestarted: "Codex запущен заново",
    providersSub: "Метрики ключей: OpenRouter, OpenCode, Claude, Antigravity. Ключи попадают в конфиг шлюза.",
    openrouter: "OpenRouter", orKey: "Ключ OpenRouter", totalCredits: "Куплено", spend: "Потрачено", remaining: "Остаток",
    keyLimit: "Лимит ключа", keySpend: "Расход ключа", opencode: "OpenCode", ocKey: "Ключ OpenCode (oc_sk_…)",
    ocHint: "После сохранения ключей перезапустите шлюз — модели opencode/* и openrouter/* появятся в списке.",
    claude: "Claude", claudeSub: "Anthropic Claude: вход по подписке через OAuth, опциональный API-ключ.",
    claudeConnect: "Подключить", claudeConnecting: "Ждём подтверждение…", claudeCancel: "Отмена",
    claudeDisconnect: "Отключить", claudeConnected: "подключён", claudeNotConnected: "не подключён",
    claudeLoginError: "Не удалось войти в Claude", claudeKey: "API-ключ Anthropic (резерв)",
    claudeHint: "OAuth — подписка Claude (основной способ). API-ключ — резерв pay-as-you-go: блок появится в конфиге шлюза, только когда тумблер включён и ключ непуст.",
    claudeDisconnected: "Claude отключён",
    confirmClaudeDisconnect: "Отключить Claude? Аккаунт будет удалён из шлюза.",
    antigravity: "Antigravity", antigravitySub: "Google-аккаунт (Antigravity) через OAuth.",
    antigravityConnect: "Подключить", antigravityConnecting: "Ждём подтверждение…", antigravityCancel: "Отмена",
    antigravityDisconnect: "Отключить", antigravityConnected: "подключён", antigravityNotConnected: "не подключён",
    antigravityLoginError: "Не удалось войти в Antigravity",
    antigravityHint: "Вход через Google-аккаунт Antigravity (только OAuth). Квоты не отображаются — их API не предоставляет.",
    antigravityDisconnected: "Antigravity отключён",
    confirmAntigravityDisconnect: "Отключить Antigravity? Аккаунт будет удалён из шлюза.",
    loginTimeout: "Вход не подтверждён за 10 минут — попробуйте снова",
    projectId: "Проект",
    settingsSub: "Язык, порт шлюза, интервал обновления квот.",
    language: "Язык", quotaInterval: "Обновлять квоты, сек", apply: "Применить", about: "О приложении", version: "Версия", platform: "Платформа",
    codexHome: "Папка Codex",
    donateSub: "Поддержать Melon Tools — USDT (TRC20).",
    donateAddress: "Адрес кошелька", donateNote: "Сеть TRON (TRC20). Спасибо за поддержку! 🍉",
    warnNoAccounts: "Пул пуст — импортируйте текущий вход Codex или добавьте аккаунт в macOS-версии и скопируйте vault.",
    loading: "Загрузка…", error: "Ошибка", done: "Готово",
    confirmDelete: "Удалить аккаунт {name} из пула?",
    confirmDeleteInstance: "Удалить инстанс {name}?",
    okPill: "готов", autoRefresh: "автообновление квот",
    addAccount: "Добавить аккаунт", addAccountHint: "Вход по коду: откроется страница OpenAI, введите код.",
    deviceCode: "Код", deviceWaiting: "Ждём подтверждение…", deviceOpen: "Открыть страницу входа",
    subscription: "Подписка", until: "до", resetsAvailable: "Сбросы 5ч", resetsNone: "нет", available: "доступно",
    accountModels: "Модели на аккаунте", availableShort: "есть", unavailableShort: "нет",
    routing: "Роутинг", strategy: "Стратегия", strategyAuto: "Авто (по остатку)", strategyQuotaHigh: "Больше квоты — выше",
    strategyQuotaLow: "Меньше квоты — выше", strategyPlanHigh: "Старше план — выше", strategyPlanLow: "Младше план — выше",
    strategyExpiry: "Скоро истекает — выше", strategyCustom: "Ручной порядок", orderUp: "Выше", orderDown: "Ниже", resetOrder: "Сбросить порядок",
    orderCustom: "Включён ручной порядок — шлюз следует списку карточек",
    preferred: "Первый", backup: "Бэкап", recentCalls: "Последние вызовы", noCalls: "пока пусто",
    fleet: "Fleet", fleetStatus: "Статус", fleetResults: "Результаты", fleetConfig: "Конфиг", fleetCommands: "Команды",
    fleetHome: "Папка Fleet", fleetCli: "CLI", fleetCliMissing: "не найден в PATH", fleetRun: "Выполнить", fleetOutput: "Вывод",
    fleetSnapshots: "Снимки", fleetLog: "Журнал", fleetOpenResult: "Открыть", fleetSave: "Сохранить",
    instances: "Инстансы", instanceNew: "Имя нового инстанса", instanceCreate: "Создать", instanceLaunch: "Запустить Codex",
    instanceBind: "Аккаунт", instanceNone: "текущий логин", instanceDelete: "Удалить", instanceHint: "Отдельный CODEX_HOME со своим входом.",
    composer: "Композер", composerHint: "Чипы в композере Codex: аккаунты и квоты прямо в строке ввода.",
    models: "Модели", modelsSearch: "Поиск модели…", modelsCount: "моделей", sources: "Источники", sourceEnabled: "включён",
    autostart: "Автозапуск с Windows", notifications: "Уведомления о низкой квоте", session: "Сессия",
    donateScan: "Отсканируйте QR — сеть TRON (TRC20)",
    update: "Обновить", updateCheck: "Проверить обновление", updateChecking: "Проверяем обновления…", updateAvailable: "Доступно обновление {v}",
    updateUpToDate: "У вас последняя версия ({v})", updateFailed: "Не удалось проверить обновления",
    updateDownloading: "Скачиваем обновление…", updateInstalling: "Устанавливаем… приложение перезапустится",
    updateCancel: "Отмена", updateApply: "Обновить",
    onboardingTitle: "Добро пожаловать в Melon Tools",
    onboardingWelcome: "Настройте приложение за три шага.",
    onboardingStep1: "Добавьте или импортируйте аккаунт Codex.",
    onboardingStep2: "Подключите провайдеров: OpenRouter, OpenCode, Claude, Antigravity.",
    onboardingStep3: "Запустите API-сервис и откройте Codex.",
    onboardingDisclaimer: "Используйте только свои аккаунты. Соблюдайте условия провайдеров: за нарушение правил возможна блокировка аккаунта.",
    onboardingAccounts: "Открыть аккаунты", onboardingProviders: "Открыть провайдеров", onboardingDone: "Готово",
    diagTitle: "Проверка подключений", diagHint: "только чтение", diagRun: "Проверить подключения",
    diagIdle: "Проверка ещё не запускалась.", diagAt: "проверено", diagProvider: "Провайдер",
    diagAuth: "Авторизация", diagQuota: "Последняя квота", diagCodex: "Аккаунты Codex",
    diagKeySet: "ключ есть", diagKeyMissing: "ключа нет", diagUp: "доступен", diagDown: "недоступен", diagApiOk: "API ok",
  },
  en: {
    dashboard: "Dashboard", accounts: "Accounts", api: "API Service", providers: "Providers", donate: "Donate", settings: "Settings",
    codex: "Codex", general: "App",
    dashTitle: "Overview", dashSub: "The local Codex gateway, the account pool and providers at a glance.",
    gateway: "Gateway", running: "running", stopped: "stopped", starting: "starting…",
    start: "Start", stop: "Stop", restart: "Restart", check: "Check API", refresh: "Refresh", sync: "Sync with gateway",
    port: "Port", reqs: "Requests/min", sidecar: "engine", found: "found", missing: "missing",
    poolSummary: "Account pool", accountsCount: "accounts", pool5h: "5h (total)", poolWeek: "Week (total)",
    blockedNow: "paused", allReady: "all ready",
    quick: "Quick actions", refreshQuotas: "Refresh quotas", importAuth: "Import current Codex login",
    accountsSub: "ChatGPT account pool: quotas, reserve pausing, Codex login switching.",
    importHint: "Reads %USERPROFILE%\\.codex\\auth.json and adds the account to the pool.",
    fiveHour: "5h", week: "Week", resetIn: "resets in", resetNow: "resetting now", onceReset: "on first request",
    reserveHourly: "5h reserve, %", reserveWeekly: "Week reserve, %", save: "Save",
    makeCurrent: "Make current", refreshLogin: "Refresh login", refreshQuota: "Refresh quota", remove: "Remove",
    current: "current", paused: "paused", ready: "ready",
    bHourly: "5-hour window exhausted", bWeekly: "weekly window exhausted",
    bHourlyReserve: "{r}% left ≤ {l}% reserve", bWeeklyReserve: "{r}% left ≤ {l}% reserve",
    quotaAge: "quota updated", never: "never", stale: "stale",
    history: "History", historyHint: "Quota remaining across recent refreshes.",
    notificationsHint: "Toast when remaining crosses an account reserve (or 10%).",
    apiSub: "Local OpenAI-compatible gateway for Codex: account pool, upstreams, access key.",
    endpoint: "Base URL", apiKey: "Key", copy: "Copy", copied: "Copied",
    endpointsTitle: "Endpoints", checkTitle: "End-to-end check", checkHint: "a tiny request through the pool — proves models are served.",
    checkResult: "Result", logFile: "Log", dataDir: "Data",
    codexRoute: "Codex integration", routeApply: "Point Codex at the gateway", routeRemove: "Remove route",
    routeActive: "Codex is routed to the gateway", routeInactive: "Codex uses its own provider",
    routeOther: "Codex is configured by another tool", catalog: "Model catalog", bridge: "Composer chips",
    bridgeOn: "attached", bridgeOff: "disconnected", bridgeHint: "Codex must run with --remote-debugging-port",
    bridgeRestart: "Restart Codex with chips",
    bridgeRestartConfirm: "Codex will close and relaunch with the debug port (required for chips). Continue?",
    bridgeRestarted: "Codex relaunched",
    providersSub: "Key metrics: OpenRouter, OpenCode, Claude, Antigravity. Keys are written into the gateway config.",
    openrouter: "OpenRouter", orKey: "OpenRouter key", totalCredits: "Purchased", spend: "Spent", remaining: "Remaining",
    keyLimit: "Key limit", keySpend: "Key usage", opencode: "OpenCode", ocKey: "OpenCode key (oc_sk_…)",
    ocHint: "After saving keys restart the gateway — opencode/* and openrouter/* models appear in the list.",
    claude: "Claude", claudeSub: "Anthropic Claude: subscription sign-in via OAuth, optional API key.",
    claudeConnect: "Connect", claudeConnecting: "Waiting for confirmation…", claudeCancel: "Cancel",
    claudeDisconnect: "Disconnect", claudeConnected: "connected", claudeNotConnected: "not connected",
    claudeLoginError: "Claude sign-in failed", claudeKey: "Anthropic API key (fallback)",
    claudeHint: "OAuth — the Claude subscription (primary). API key — pay-as-you-go fallback: the gateway config gains the block only when the toggle is on and the key is non-empty.",
    claudeDisconnected: "Claude disconnected",
    confirmClaudeDisconnect: "Disconnect Claude? The account is removed from the gateway.",
    antigravity: "Antigravity", antigravitySub: "Google account (Antigravity) via OAuth.",
    antigravityConnect: "Connect", antigravityConnecting: "Waiting for confirmation…", antigravityCancel: "Cancel",
    antigravityDisconnect: "Disconnect", antigravityConnected: "connected", antigravityNotConnected: "not connected",
    antigravityLoginError: "Antigravity sign-in failed",
    antigravityHint: "Sign in with the Antigravity Google account (OAuth only). No quota display — the API provides none.",
    antigravityDisconnected: "Antigravity disconnected",
    confirmAntigravityDisconnect: "Disconnect Antigravity? The account is removed from the gateway.",
    loginTimeout: "Sign-in was not confirmed within 10 minutes — try again",
    projectId: "Project",
    settingsSub: "Language, gateway port, quota refresh interval.",
    language: "Language", quotaInterval: "Refresh quotas, sec", apply: "Apply", about: "About", version: "Version", platform: "Platform",
    codexHome: "Codex home",
    donateSub: "Support Melon Tools — USDT (TRC20).",
    donateAddress: "Wallet address", donateNote: "TRON network (TRC20). Thanks for the support! 🍉",
    warnNoAccounts: "The pool is empty — import the current Codex login or copy the vault from the macOS app.",
    loading: "Loading…", error: "Error", done: "Done",
    confirmDelete: "Remove {name} from the pool?",
    confirmDeleteInstance: "Delete instance {name}?",
    okPill: "ready", autoRefresh: "quota auto-refresh",
    addAccount: "Add account", addAccountHint: "Device code: a page opens, enter the code.",
    deviceCode: "Code", deviceWaiting: "Waiting for confirmation…", deviceOpen: "Open the sign-in page",
    subscription: "Subscription", until: "until", resetsAvailable: "5h resets", resetsNone: "none", available: "available",
    accountModels: "Models on this account", availableShort: "yes", unavailableShort: "no",
    routing: "Routing", strategy: "Strategy", strategyAuto: "Auto (by remaining)", strategyQuotaHigh: "More quota first",
    strategyQuotaLow: "Less quota first", strategyPlanHigh: "Higher plan first", strategyPlanLow: "Lower plan first",
    strategyExpiry: "Ending soon first", strategyCustom: "Manual order", orderUp: "Up", orderDown: "Down", resetOrder: "Reset order",
    orderCustom: "Manual order enabled — the gateway follows the card list",
    preferred: "Preferred", backup: "Backup", recentCalls: "Recent calls", noCalls: "empty for now",
    fleet: "Fleet", fleetStatus: "Status", fleetResults: "Results", fleetConfig: "Config", fleetCommands: "Commands",
    fleetHome: "Fleet folder", fleetCli: "CLI", fleetCliMissing: "not found in PATH", fleetRun: "Run", fleetOutput: "Output",
    fleetSnapshots: "Snapshots", fleetLog: "Log", fleetOpenResult: "Open", fleetSave: "Save",
    instances: "Instances", instanceNew: "New instance name", instanceCreate: "Create", instanceLaunch: "Launch Codex",
    instanceBind: "Account", instanceNone: "current login", instanceDelete: "Delete", instanceHint: "A separate CODEX_HOME with its own login.",
    composer: "Composer", composerHint: "Chips in the Codex composer: accounts and quotas right in the input row.",
    models: "Models", modelsSearch: "Search models…", modelsCount: "models", sources: "Sources", sourceEnabled: "enabled",
    autostart: "Start with Windows", notifications: "Low-quota notifications", session: "Session",
    donateScan: "Scan the QR — TRON network (TRC20)",
    update: "Update", updateCheck: "Check for updates", updateChecking: "Checking for updates…", updateAvailable: "Update {v} is available",
    updateUpToDate: "You are up to date ({v})", updateFailed: "Could not check for updates",
    updateDownloading: "Downloading the update…", updateInstalling: "Installing… the app will restart",
    updateCancel: "Cancel", updateApply: "Update",
    onboardingTitle: "Welcome to Melon Tools",
    onboardingWelcome: "Set up the app in three steps.",
    onboardingStep1: "Add or import a Codex account.",
    onboardingStep2: "Connect providers: OpenRouter, OpenCode, Claude, Antigravity.",
    onboardingStep3: "Start the API service and launch Codex.",
    onboardingDisclaimer: "Use only your own accounts. Follow provider terms — accounts can be banned for rule violations.",
    onboardingAccounts: "Open Accounts", onboardingProviders: "Open Providers", onboardingDone: "Done",
    diagTitle: "Connection check", diagHint: "read-only", diagRun: "Check connections",
    diagIdle: "The check has not run yet.", diagAt: "checked", diagProvider: "Provider",
    diagAuth: "Auth", diagQuota: "Last quota", diagCodex: "Codex accounts",
    diagKeySet: "key set", diagKeyMissing: "no key", diagUp: "up", diagDown: "down", diagApiOk: "API ok",
  },
};

const S = {
  lang: "ru",
  section: "dashboard",
  accounts: [],
  history: [],
  status: null,
  settings: null,
  providers: null,
  claude: null,
  claudeLogin: null,
  lastClaudeUsageAt: 0,
  antigravity: null,
  antigravityLogin: null,
  antigravityIds: null,
  lastAntigravityAt: 0,
  info: null,
  checkResult: null,
  route: null,
  bridge: null,
  routing: null,
  calls: [],
  models: null,
  modelsQuery: "",
  diag: null,
  fleet: null,
  fleetTab: "status",
  fleetResult: null,
  instancesData: null,
  deviceLogin: null,
  autostart: false,
  busy: {},
  // M3 refresh guard: pending edits keep the full re-render deferred.
  dirtyInput: false,
  dirtyField: null,
  renderDeferred: false,
  _renderResumeTimer: null,
};

function t(key) {
  return (DICT[S.lang] && DICT[S.lang][key]) || DICT.ru[key] || key;
}
function fmt(text, values) {
  return text.replace(/\{(\w+)\}/g, (_, k) => (values[k] !== undefined ? values[k] : "{" + k + "}"));
}
function esc(value) {
  return String(value === null || value === undefined ? "" : value)
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;")
    // Ids and paths land inside single-quoted onclick attributes.
    .replace(/'/g, "&#39;");
}

// Tauri rejects with a string, but keep the message for Error-like values.
function errorText(error) {
  if (error === null || error === undefined) return String(error);
  if (typeof error === "string") return error;
  if (typeof error.message === "string") return error.message;
  try {
    return JSON.stringify(error);
  } catch {
    return String(error);
  }
}

// OAuth polls give up after 10 minutes instead of polling forever.
const LOGIN_TIMEOUT_MS = 10 * 60 * 1000;

// MARK: - Backend

async function inv(cmd, args = {}) {
  if (IS_TAURI) {
    return window.__TAURI__.core.invoke(cmd, args);
  }
  return mock(cmd, args);
}

// Browser preview data (used only outside Tauri).
function mock(cmd, args) {
  const nowSec = Date.now() / 1000;
  const demoAccounts = [
    {
      id: "demo-1", email: "account-1@example.invalid", displayName: "account-1@example.invalid", planType: "plus",
      subscriptionActiveUntil: "2026-11-18T05:54:42Z", blocked: false, blockInfo: null,
      hourlyRemaining: 100, weeklyRemaining: 85, hourlyResetAt: nowSec + 16698, weeklyResetAt: nowSec + 583541,
      hourlyWindowPresent: true, weeklyWindowPresent: true, quotaUpdatedAt: nowSec - 40,
      hourlyReservePercent: 5, weeklyReservePercent: null, preferredFirst: true, hasTokens: true,
    },
    {
      id: "demo-2", email: "account-2@example.invalid", displayName: "account-2@example.invalid", planType: "plus",
      subscriptionActiveUntil: "2026-11-13T13:01:27Z", blocked: true,
      blockInfo: { code: "hourly_reserve", remaining: 4, limit: 5 },
      hourlyRemaining: 4, weeklyRemaining: 85, hourlyResetAt: nowSec + 3600, weeklyResetAt: nowSec + 583000,
      hourlyWindowPresent: true, weeklyWindowPresent: true, quotaUpdatedAt: nowSec - 120,
      hourlyReservePercent: 5, weeklyReservePercent: null, preferredFirst: false, hasTokens: true,
    },
  ];
  const historySeries = (key, start, drop) => Array.from({ length: 12 }, (_, index) => ({
    key,
    provider: key === "claude" ? "claude" : key === "openrouter" ? "openrouter" : "codex",
    timestamp: nowSec - (11 - index) * 300,
    hourlyLeft: Math.max(0, start - index * drop),
    weeklyLeft: Math.max(0, 90 - index * 2),
  }));
  const historyMocks = [
    ...historySeries("demo-1", 100, 7),
    ...historySeries("demo-2", 80, 6),
    ...historySeries("claude", 88, 2),
    ...historySeries("openrouter", 60, 3),
  ];
  const mocks = {
    app_info: { name: "Melon Tools", version: "1.4.7", platform: "windows", dataDir: "C:\\Users\\you\\AppData\\Roaming\\MelonTools", codexHome: "C:\\Users\\you\\.codex" },
    settings_get: { port: 18317, apiKey: "", lang: S.lang, quotaInterval: 300, openrouterKey: "", opencodeKey: "", claudeEnabled: false, claudeApiKey: "", notifyLowQuota: true },
    settings_set: (a) => a.settings,
    vault_list: demoAccounts,
    quota_history: historyMocks,
    quota_refresh: { accounts: demoAccounts, errors: [], syncedAccounts: 2 },
    gateway_status: { running: true, port: 18317, requestsLastMinute: 0, sidecarFound: true, dataDir: "…", logPath: "…\\gateway.log" },
    gateway_start: "started", gateway_stop: "stopped", gateway_sync: { syncedAccounts: 2 },
    gateway_check: '{"model":"gpt-6-luna","choices":[{"message":{"content":"Понг! 🏓"}}]}',
    switch_account: { authPath: "C:\\Users\\you\\.codex\\auth.json" },
    import_current_auth: { result: "added", accounts: demoAccounts },
    account_refresh_tokens: demoAccounts,
    save_reserves: demoAccounts,
    delete_account: demoAccounts,
    openrouter_refresh: { totalCredits: 30, totalUsage: 29.87, remaining: 0.13, label: "melon", usage: 0.09, limit: 1000, limitRemaining: 999.9, isFreeTier: false, status: "ok" },
    claude_login_start: { url: "https://example.invalid/oauth/authorize?state=demo-state", state: "demo-state" },
    claude_login_status: { status: "wait" },
    claude_login_cancel: { canceled: true },
    claude_credentials: { credentials: [{ name: "claude-demo.json", type: "claude", email: "demo@claude.invalid" }] },
    claude_models: { models: [{ id: "claude-opus-5-5", displayName: "Claude Opus 5.5" }, { id: "claude-sonnet-5-5", displayName: "Claude Sonnet 5.5" }, { id: "claude-haiku-4-7", displayName: "Claude Haiku 4.7" }], count: 3 },
    claude_usage: { connected: true, email: "demo@claude.invalid", plan: "Pro", fiveHourPercent: 72, fiveHourReset: new Date(Date.now() + 2.5 * 3600 * 1000).toISOString(), weeklyPercent: 41, weeklyReset: new Date(Date.now() + 3.2 * 86400 * 1000).toISOString(), modelCount: 3, updatedAt: new Date().toISOString(), error: null, status: "ok" },
    claude_refresh: { ok: true },
    claude_disconnect: { removed: 1, remaining: 0 },
    antigravity_login_start: { url: "https://example.invalid/oauth/antigravity?state=ag-demo-state", state: "ag-demo-state" },
    antigravity_login_status: { status: "wait" },
    antigravity_login_cancel: { canceled: true },
    antigravity_credentials: { credentials: [{ name: "antigravity-demo@gmail.invalid", type: "antigravity", email: "demo@gmail.invalid" }] },
    antigravity_models: { models: [
      { id: "claude-opus-4-6-thinking", displayName: "Claude Opus 4.6 Thinking" },
      { id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6" },
      { id: "claude-opus-5-5-high", displayName: "Claude Opus 5.5 High" },
      { id: "claude-sonnet-5-5-high", displayName: "Claude Sonnet 5.5 High" },
      { id: "gemini-4-argon-high", displayName: "Gemini 4 Argon High" },
      { id: "gemini-3.8-flash-high", displayName: "Gemini 3.8 Flash High" },
      { id: "gemini-3-flash", displayName: "Gemini 3 Flash" },
      { id: "gemini-3.1-flash-image", displayName: "Gemini 3.1 Flash Image" },
      { id: "gpt-oss-120b-medium", displayName: "GPT-OSS 120B Medium" },
      { id: "gemini-3.1-flash-lite", displayName: "Gemini 3.1 Flash Lite" },
      { id: "gemini-3.5-flash-lite", displayName: "Gemini 3.5 Flash Lite" },
    ], count: 11 },
    antigravity_metrics: { connected: true, email: "demo@gmail.invalid", projectId: "melon-demo-project", modelCount: 11, updatedAt: new Date().toISOString(), error: null, status: "ok" },
    antigravity_refresh: { ok: true },
    antigravity_disconnect: { removed: 1, remaining: 0 },
    codex_route_status: { configPath: "C:\\Users\\you\\.codex\\config.toml", provider: "melon_local_access", ours: true, catalogExists: true, catalogPath: "C:\\Users\\you\\.codex\\melon-model-catalog.json" },
    codex_route_apply: { route: { provider: "melon_local_access", ours: true, catalogExists: true }, catalogCustom: 32 },
    codex_route_remove: { provider: null, ours: false, catalogExists: true },
    bridge_status: { attached: true, debugPort: 55660, model: "GPT-6.1 Sol", targets: 3, reason: null },
    routing_state: { strategy: "auto", strategies: ["auto", "quotaHighFirst", "quotaLowFirst", "planHighFirst", "planLowFirst", "expirySoonFirst", "custom"], priorityOrder: [], orderedIds: ["demo-1", "demo-2"], blockedIds: ["demo-2"] },
    set_routing_strategy: (a) => ({ strategy: a.strategy, orderedIds: ["demo-1", "demo-2"], blockedIds: ["demo-2"], accounts: demoAccounts }),
    move_priority: { strategy: "custom", orderedIds: ["demo-2", "demo-1"], blockedIds: [], accounts: demoAccounts },
    reset_priority: { strategy: "auto", orderedIds: ["demo-1", "demo-2"], blockedIds: [], accounts: demoAccounts },
    set_account_role: { strategy: "auto", orderedIds: ["demo-1", "demo-2"], blockedIds: [], accounts: demoAccounts },
    device_login_start: { deviceAuthId: "demo", userCode: "AB12-CD34", interval: 30, verificationURL: "https://auth.openai.com/codex/device" },
    device_login_poll: { done: false },
    gateway_models: [{ id: "gpt-6.1-sol", owned_by: "openai" }, { id: "opencode/grok-4.7", owned_by: "opencode-go" }],
    gateway_recent_calls: [{ time: "19:19:41", status: "200", duration: "9.743s", method: "POST", path: "/v1/responses" }],
    fleet_status: { home: "C:\\Users\\you\\.melon-fleet", cli: null, snapshots: [], logTail: [] },
    fleet_results: [],
    fleet_read_result: "(demo)",
    fleet_config_get: { path: "…\\fleet.config.json", text: "{}" },
    fleet_config_set: { path: "…", text: "{}" },
    fleet_cli: "(demo output)",
    instances_list: [],
    instance_create: [],
    instance_delete: [],
    instance_bind: [],
    instance_launch: "C:\\Users\\you\\AppData\\Roaming\\MelonTools\\instances\\demo",
    autostart_get: false,
    autostart_set: true,
    update_check: { skipped: false, version: "1.4.8", tag: "v1.4.8", newer: false, notes: "", assetName: "", assetURL: "", digest: null },
    update_apply: { ok: true },
    open_url: null,
  };
  const entry = mocks[cmd];
  return Promise.resolve(typeof entry === "function" ? entry(args) : entry);
}

// MARK: - Formatting

function nowRef() { return Date.now() / 1000; }

function round(value) {
  return value === null || value === undefined ? "—" : `${Math.round(value)}%`;
}

// Time units follow the UI language (same pattern as claudeResetText).
function unit(en, ru) {
  return S.lang === "en" ? en : ru;
}

function resetText(unixTs) {
  if (!unixTs) return t("onceReset");
  const secs = unixTs - nowRef();
  if (secs <= 0) return t("resetNow");
  const mins = Math.floor(secs / 60);
  if (mins < 60) return `${t("resetIn")} ${mins} ${unit("min", "мин")}`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${t("resetIn")} ${hours} ${unit("h", "ч")} ${mins % 60} ${unit("min", "мин")}`;
  const days = Math.floor(hours / 24);
  return `${t("resetIn")} ${days} ${unit("d", "дн")} ${hours % 24} ${unit("h", "ч")}`;
}

// Claude usage resets arrive as RFC-3339; render them relative like the
// account quota captions, in the current UI language.
function claudeResetText(iso) {
  if (!iso) return "—";
  const ts = Date.parse(iso);
  if (Number.isNaN(ts)) return esc(iso);
  const secs = (ts - Date.now()) / 1000;
  if (secs <= 0) return t("resetNow");
  const mins = Math.floor(secs / 60);
  if (mins < 60) return `${t("resetIn")} ${mins} ${unit("min", "мин")}`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${t("resetIn")} ${hours} ${unit("h", "ч")} ${mins % 60} ${unit("min", "мин")}`;
  const days = Math.floor(hours / 24);
  return `${t("resetIn")} ${days} ${unit("d", "дн")} ${hours % 24} ${unit("h", "ч")}`;
}

// RFC-3339 timestamp → "N с / N мин / N ч" since it (reuses ageText).
function claudeAgeText(iso) {
  const ts = Date.parse(iso);
  if (Number.isNaN(ts)) return "—";
  return ageText(ts / 1000);
}

function ageText(unixTs) {
  if (!unixTs) return t("never");
  const secs = nowRef() - unixTs;
  if (secs < 60) return `${Math.max(0, Math.floor(secs))} ${unit("s", "с")}`;
  const mins = Math.floor(secs / 60);
  if (mins < 60) return `${mins} ${unit("min", "мин")}`;
  return `${Math.floor(mins / 60)} ${unit("h", "ч")} ${mins % 60} ${unit("min", "мин")}`;
}

function quotaTint(percent) {
  if (percent === null || percent === undefined) return "";
  if (percent <= 5) return "danger";
  if (percent <= 25) return "warn";
  return "ok";
}

// Quota history: `key` is an account id or a provider id; samples carry
// timestamp (Unix seconds) and hourlyLeft/weeklyLeft shares (0…100).
function historySamples(key, field) {
  return (S.history || [])
    .filter((sample) => sample && sample.key === key)
    .map((sample) => Number(sample[field]))
    .filter((value) => Number.isFinite(value));
}

function sparkline(key, field, label) {
  const values = historySamples(key, field);
  if (!values.length) {
    return `<span class="spark-empty">${esc(label)}: —</span>`;
  }
  const min = Math.min(...values);
  const max = Math.max(...values);
  const span = max - min || 1;
  const points = values.map((value, index) => {
    const x = values.length === 1 ? 50 : (index / (values.length - 1)) * 100;
    const y = 22 - ((value - min) / span) * 20;
    return `${x.toFixed(1)},${y.toFixed(1)}`;
  }).join(" ");
  const title = `${label}: ${Math.round(values[0])}% → ${Math.round(values[values.length - 1])}%`;
  return `<span class="spark" title="${esc(title)}"><svg viewBox="0 0 100 24" preserveAspectRatio="none" role="img" aria-label="${esc(title)}"><polyline points="${points}"></polyline></svg></span>`;
}

function historyStrip(key) {
  const samples = (S.history || []).filter((sample) => sample && sample.key === key);
  if (!samples.length) return "";
  return `<div class="spark-row" title="${esc(t("historyHint"))}">
    <span class="spark-label">${esc(t("history"))}</span>
    ${sparkline(key, "hourlyLeft", t("fiveHour"))}<span class="spark-name">${esc(t("fiveHour"))}</span>
    ${sparkline(key, "weeklyLeft", t("week"))}<span class="spark-name">${esc(t("week"))}</span>
  </div>`;
}

function blockText(info) {
  if (!info) return "";
  switch (info.code) {
    case "hourly_exhausted": return t("bHourly");
    case "weekly_exhausted": return t("bWeekly");
    case "hourly_reserve": return fmt(t("bHourlyReserve"), { r: Math.round(info.remaining), l: info.limit });
    case "weekly_reserve": return fmt(t("bWeeklyReserve"), { r: Math.round(info.remaining), l: info.limit });
    default: return info.code;
  }
}

function toast(message, isError = false) {
  const node = document.getElementById("toast");
  node.textContent = message;
  node.className = isError ? "show error" : "show";
  clearTimeout(toast._timer);
  toast._timer = setTimeout(() => (node.className = ""), 4200);
}

async function run(action, fn) {
  if (S.busy[action]) return;
  S.busy[action] = true;
  render();
  try {
    await fn();
  } catch (error) {
    toast(String(error && error.message ? error.message : error), true);
  } finally {
    S.busy[action] = false;
    render();
  }
}

// MARK: - Icons

const ICONS = {
  dashboard: '<svg viewBox="0 0 24 24"><path d="M4 13h7V4H4v9Zm0 7h7v-5H4v5Zm9 0h7V11h-7v9Zm0-16v5h7V4h-7Z"/></svg>',
  accounts: '<svg viewBox="0 0 24 24"><path d="M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8Zm-7 8a7 7 0 0 1 14 0"/></svg>',
  api: '<svg viewBox="0 0 24 24"><path d="M4 7h16M4 12h16M4 17h10"/></svg>',
  providers: '<svg viewBox="0 0 24 24"><path d="M12 3 3 8l9 5 9-5-9-5ZM3 14l9 5 9-5"/></svg>',
  composer: '<svg viewBox="0 0 24 24"><path d="M4 5h16v10H8l-4 4V5Z"/></svg>',
  instances: '<svg viewBox="0 0 24 24"><path d="M4 6h16v12H4z"/><path d="M8 10h8M8 14h5"/></svg>',
  fleet: '<svg viewBox="0 0 24 24"><path d="M3 17h18M6 17V9l6-4 6 4v8"/></svg>',
  donate: '<svg viewBox="0 0 24 24"><path d="M12 20s-7-4.5-9-9a5 5 0 0 1 9-3 5 5 0 0 1 9 3c-2 4.5-9 9-9 9Z"/></svg>',
  settings: '<svg viewBox="0 0 24 24"><path d="M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6Z"/><path d="M19 12a7 7 0 0 0-.1-1l2-1.5-2-3.4-2.3 1a7 7 0 0 0-1.7-1L14.5 3h-5l-.4 2.6a7 7 0 0 0-1.7 1l-2.3-1-2 3.4L5 11a7 7 0 0 0 0 2l-2 1.5 2 3.4 2.3-1a7 7 0 0 0 1.7 1l.4 2.6h5l.4-2.6a7 7 0 0 0 1.7-1l2.3 1 2-3.4-2-1.5c.1-.3.1-.7.1-1Z"/></svg>',
};

const NAV = [
  { group: "codex", items: ["dashboard", "accounts", "api", "providers", "composer", "instances"] },
  { group: "general", items: ["fleet", "settings", "donate"] },
];

// MARK: - Render

function render() {
  renderNav();
  renderFooter();
  const main = document.getElementById("main");
  const pages = {
    dashboard: dashboardPage,
    accounts: accountsPage,
    api: apiPage,
    providers: providersPage,
    composer: composerPage,
    instances: instancesPage,
    fleet: fleetPage,
    donate: donatePage,
    settings: settingsPage,
  };
  main.innerHTML = (pages[S.section] || dashboardPage)();
  if (S.section === "donate") renderDonateQr();
  if (S.section === "fleet" && !S.fleet) A.fleetLoad();
  if (S.section === "providers" && !S.models) A.modelsLoad();
  if (S.section === "providers" && IS_TAURI && !S.claude && !S.claudeLogin) {
    A.claudeUsageLoad().then(() => {
      if (S.section === "providers") render();
    }).catch(() => {});
  }
  if (S.section === "providers" && IS_TAURI && !S.antigravity && !S.antigravityLogin) {
    A.antigravityUsageLoad().then(() => {
      if (S.section === "providers") render();
    }).catch(() => {});
  }
  if (S.section === "instances" && !S.instancesData) A.instancesLoad();
}

function renderNav() {
  const nav = document.getElementById("nav");
  let html = "";
  for (const group of NAV) {
    html += `<div class="nav-group"><div class="nav-caption">${esc(t(group.group))}</div>`;
    for (const item of group.items) {
      const active = S.section === item ? " active" : "";
      html += `<button class="nav-row${active}" onclick="A.go('${item}')">${ICONS[item]}<span>${esc(t(item))}</span></button>`;
    }
    html += "</div>";
  }
  nav.innerHTML = html;
}

function renderFooter() {
  const dot = document.getElementById("gw-dot");
  const label = document.getElementById("gw-label");
  const status = S.status;
  const running = status && status.running;
  dot.className = "dot " + (running ? "ok" : "err");
  label.textContent = running ? `${t("running")} · :${status.port}` : t("stopped");
  document.getElementById("ver").textContent = S.info ? `v${S.info.version}` : "";
  const updateLabel = document.getElementById("update-label");
  if (updateLabel) A.updateButton();
  const cancel = document.getElementById("update-cancel");
  if (cancel) {
    cancel.textContent = t("updateCancel");
    // C-F8: once the swap started the modal must stay put — keep Cancel off.
    cancel.disabled = !!A._updateApplying;
  }
  const apply = document.getElementById("update-apply");
  if (apply) apply.textContent = t("updateApply");
}

function pageHead(kicker, title, subtitle) {
  return `<div class="page-head"><div class="kicker">${esc(kicker)}</div><h1>${esc(title)}</h1><div class="subtitle">${esc(subtitle)}</div></div>`;
}

// MARK: - Pages

function dashboardPage() {
  const accounts = S.accounts || [];
  const ready = accounts.filter((a) => !a.blocked);
  const poolHourly = accounts.reduce((sum, a) => sum + (a.hourlyRemaining ?? 0), 0);
  const poolWeekly = accounts.reduce((sum, a) => sum + (a.weeklyRemaining ?? 0), 0);
  const status = S.status || {};

  return `
  ${pageHead("melon tools", t("dashTitle"), t("dashSub"))}
  <div class="grid2">
    <div class="card">
      <h2>${t("gateway")} <span class="hint">:${status.port || "—"}</span></h2>
      <div class="stack">
        <div class="row">
          <span class="dot ${status.running ? "ok" : "err"}"></span>
          <b>${status.running ? t("running") : t("stopped")}</b>
          <span class="pill">${t("reqs")}: ${status.requestsLastMinute ?? 0}</span>
          <span class="pill ${status.sidecarFound ? "ok" : "danger"}">${t("sidecar")}: ${status.sidecarFound ? t("found") : t("missing")}</span>
        </div>
        <div class="row">
          <button class="btn small" onclick="A.gatewayStart()" ${S.busy.start ? "disabled" : ""}>${t("start")}</button>
          <button class="ghost small" onclick="A.gatewayStop()" ${S.busy.stop ? "disabled" : ""}>${t("stop")}</button>
          <button class="ghost small" onclick="A.gatewaySync()">${t("sync")}</button>
        </div>
      </div>
    </div>

    <div class="card">
      <h2>${t("poolSummary")} <span class="hint">${accounts.length} ${t("accountsCount")}</span></h2>
      <div class="stack">
        <div class="quota">
          <div class="top"><span class="name">${t("pool5h")}</span><span class="val">${Math.round(poolHourly)}%</span></div>
          <div class="bar"><i class="${quotaTint(poolHourly / Math.max(1, accounts.length))}" style="width:${Math.min(100, poolHourly / Math.max(1, accounts.length))}%"></i></div>
        </div>
        <div class="quota">
          <div class="top"><span class="name">${t("poolWeek")}</span><span class="val">${Math.round(poolWeekly)}%</span></div>
          <div class="bar"><i class="${quotaTint(poolWeekly / Math.max(1, accounts.length))}" style="width:${Math.min(100, poolWeekly / Math.max(1, accounts.length))}%"></i></div>
        </div>
        <div class="row">
          <span class="pill ${accounts.length && ready.length === accounts.length ? "ok" : "warn"}">
            ${accounts.length ? (ready.length === accounts.length ? t("allReady") : `${accounts.length - ready.length} ${t("blockedNow")}`) : "—"}
          </span>
        </div>
      </div>
    </div>
  </div>

  <div class="card">
    <h2>${t("quick")}</h2>
    <div class="row">
      <button class="btn small" onclick="A.refreshQuotas()" ${S.busy.quotas ? "disabled" : ""}>${t("refreshQuotas")}</button>
      <button class="ghost small" onclick="A.importAuth()">${t("importAuth")}</button>
      <button class="ghost small" onclick="A.checkApi()" ${S.busy.check ? "disabled" : ""}>${t("check")}</button>
    </div>
    ${S.checkResult ? `<div class="footnote mono">${esc(S.checkResult)}</div>` : ""}
  </div>

  <div class="card">
    <h2>${t("recentCalls")}</h2>
    ${(S.calls && S.calls.length)
      ? `<table class="kv">${S.calls.map((call) => `<tr>
           <td>${esc(call.time || "")}</td>
           <td>${esc(call.method)} ${esc(call.path)} <span class="pill ${String(call.status).startsWith("2") ? "ok" : "warn"}">${esc(call.status)}</span> <span class="muted">${esc(call.duration || "")}</span></td>
         </tr>`).join("")}</table>`
      : `<div class="footnote">${t("noCalls")}</div>`}
  </div>

  ${!accounts.length ? `<div class="card"><div class="muted">${t("warnNoAccounts")}</div></div>` : ""}
  `;
}

function quotaBlock(title, percent, resetUnix, present) {
  const width = percent === null || percent === undefined ? 0 : Math.min(100, Math.max(0, percent));
  return `
  <div class="quota">
    <div class="top"><span class="name">${esc(title)}</span><span class="val">${round(percent)}</span></div>
    <div class="bar"><i class="${quotaTint(percent)}" style="width:${width}%"></i></div>
    <div class="bottom">
      <span>${present ? resetText(resetUnix) : t("onceReset")}</span>
    </div>
  </div>`;
}

function strategyOptions() {
  return [
    ["auto", "strategyAuto"],
    ["quotaHighFirst", "strategyQuotaHigh"],
    ["quotaLowFirst", "strategyQuotaLow"],
    ["planHighFirst", "strategyPlanHigh"],
    ["planLowFirst", "strategyPlanLow"],
    ["expirySoonFirst", "strategyExpiry"],
    ["custom", "strategyCustom"],
  ];
}

function subscriptionText(raw) {
  if (!raw) return "";
  const date = new Date(raw);
  if (Number.isNaN(date.getTime())) return `${t("subscription")}: ${esc(raw)}`;
  const expired = date.getTime() < Date.now();
  const text = `${t("subscription")}: ${t("until")} ${date.toLocaleDateString()}`;
  return expired ? `${text} ⚠` : text;
}

function accountCard(account) {
  const resetsText = account.resetCreditsAvailable === null || account.resetCreditsAvailable === undefined
    ? t("resetsNone")
    : `${account.resetCreditsAvailable} ${t("available")}${account.resetCreditsNextExpiry ? " · " + resetText(account.resetCreditsNextExpiry) : ""}`;
  const models = account.modelAvailability || [];
  const modelsBlock = models.length
    ? `<details><summary class="footnote" style="cursor:pointer">${t("accountModels")} (${models.length})</summary>
         <div class="stack" style="margin-top:8px">
           ${models.map((m) => `<div class="row" style="gap:8px"><span class="pill ${m.available ? "ok" : ""}">${m.available ? t("availableShort") : t("unavailableShort")}</span><span class="mono" style="font-size:11px">${esc(m.model)}</span></div>`).join("")}
         </div>
       </details>`
    : "";
  return `
    <div class="card">
      <div class="account-head">
        <span class="email">${esc(account.email || account.displayName)}</span>
        ${account.planType ? `<span class="plan">${esc(account.planType)}</span>` : ""}
        ${account.preferredFirst ? `<span class="pill gold">${t("preferred")}</span>` : ""}
        ${account.isBackup ? `<span class="pill">${t("backup")}</span>` : ""}
        ${account.blocked
          ? `<span class="pill warn" title="${esc(blockText(account.blockInfo))}">${t("paused")}</span>`
          : `<span class="pill ok">${t("ready")}</span>`}
        <span class="spacer"></span>
        <button class="ghost small" title="${t("orderUp")}" onclick="A.movePriority('${esc(account.id)}', true)">↑</button>
        <button class="ghost small" title="${t("orderDown")}" onclick="A.movePriority('${esc(account.id)}', false)">↓</button>
      </div>

      <div class="stack">
        ${quotaBlock(t("fiveHour"), account.hourlyRemaining, account.hourlyResetAt, account.hourlyWindowPresent)}
        ${quotaBlock(t("week"), account.weeklyRemaining, account.weeklyResetAt, account.weeklyWindowPresent)}
        ${historyStrip(account.id)}

        ${account.blocked ? `<div class="footnote">⏸ ${esc(blockText(account.blockInfo))}</div>` : ""}
        <div class="row">
          ${account.subscriptionActiveUntil ? `<span class="footnote">${esc(subscriptionText(account.subscriptionActiveUntil))}</span>` : ""}
          <span class="footnote">${t("resetsAvailable")}: ${esc(resetsText)}</span>
        </div>
        <div class="footnote">${t("quotaAge")}: ${esc(ageText(account.quotaUpdatedAt))}${account.quotaError ? " · " + esc(account.quotaError) : ""}</div>
        ${modelsBlock}

        <div class="row">
          <label class="field">${t("reserveHourly")}
            <input class="small" type="number" id="res-h-${esc(account.id)}" value="${account.hourlyReservePercent ?? ""}" min="0" max="100">
          </label>
          <label class="field">${t("reserveWeekly")}
            <input class="small" type="number" id="res-w-${esc(account.id)}" value="${account.weeklyReservePercent ?? ""}" min="0" max="100">
          </label>
          <label class="field">${t("preferred")}
            <input type="checkbox" ${account.preferredFirst ? "checked" : ""} onchange="A.setRole('${esc(account.id)}', this.checked, ${account.isBackup ? "true" : "false"})">
          </label>
          <label class="field">${t("backup")}
            <input type="checkbox" ${account.isBackup ? "checked" : ""} onchange="A.setRole('${esc(account.id)}', ${account.preferredFirst ? "true" : "false"}, this.checked)">
          </label>
          <button class="ghost small" onclick="A.saveReserves('${esc(account.id)}')">${t("save")}</button>
        </div>

        <div class="row">
          <button class="btn small" onclick="A.switchAccount('${esc(account.id)}')">${t("makeCurrent")}</button>
          <button class="ghost small" onclick="A.refreshQuota('${esc(account.id)}')">${t("refreshQuota")}</button>
          <button class="ghost small" onclick="A.refreshLogin('${esc(account.id)}')">${t("refreshLogin")}</button>
          <span class="spacer"></span>
          <button class="ghost small danger" onclick="A.deleteAccount('${esc(account.id)}')">${t("remove")}</button>
        </div>
      </div>
    </div>`;
}

function accountsPage() {
  const accounts = S.accounts || [];
  const status = S.status || {};
  const routing = S.routing || { strategy: "auto", orderedIds: [], blockedIds: [] };
  const orderedIds = routing.orderedIds && routing.orderedIds.length ? routing.orderedIds : accounts.map((a) => a.id);
  const byId = new Map(accounts.map((a) => [a.id, a]));
  const cards = orderedIds
    .map((id) => {
      const account = byId.get(id);
      return account ? accountCard(account) : "";
    })
    .join("");

  const deviceLogin = S.deviceLogin;
  const deviceCard = `
    <div class="card">
      <h2>${t("addAccount")}</h2>
      <div class="stack">
        ${deviceLogin && !deviceLogin.done
          ? `<div class="row">
               <span class="muted">${t("deviceCode")}:</span>
               <b class="mono" style="font-size:16px">${esc(deviceLogin.userCode)}</b>
               <button class="ghost small" onclick="A.copy('${esc(deviceLogin.userCode)}')">${t("copy")}</button>
               <button class="btn small" onclick="A.deviceOpen()">${t("deviceOpen")}</button>
             </div>
             <div class="footnote">${t("deviceWaiting")}</div>`
          : `<div class="row">
               <button class="btn small" onclick="A.deviceStart()" ${S.busy.device ? "disabled" : ""}>${t("addAccount")}</button>
               <span class="footnote">${t("addAccountHint")}</span>
             </div>`}
      </div>
    </div>`;

  const strategy = strategyOptions();
  const routingCard = `
    <div class="card">
      <h2>${t("routing")}</h2>
      <div class="row">
        <label class="field">${t("strategy")}
          <select id="routing-strategy" onchange="A.setStrategy(this.value)">
            ${strategy.map(([value, key]) => `<option value="${value}" ${routing.strategy === value ? "selected" : ""}>${t(key)}</option>`).join("")}
          </select>
        </label>
        <button class="ghost small" onclick="A.resetOrder()">${t("resetOrder")}</button>
        <span class="spacer"></span>
        <span class="footnote">${t("preferred")} → ${t("ready")} → ${t("paused")}</span>
      </div>
    </div>`;

  return `
  ${pageHead("codex", t("accounts"), t("accountsSub"))}
  <div class="row">
    <button class="btn" onclick="A.importAuth()">${t("importAuth")}</button>
    <span class="footnote">${t("importHint")}</span>
  </div>
  ${deviceCard}
  ${routingCard}
  <div class="accounts">${cards || `<div class="card"><div class="muted">${t("warnNoAccounts")}</div></div>`}</div>

  <div class="card">
    <h2>${t("gateway")} <span class="hint">:${status.port || "—"}</span></h2>
    <div class="row">
      <span class="dot ${status.running ? "ok" : "err"}"></span>
      <b>${status.running ? t("running") : t("stopped")}</b>
      <span class="pill">${t("reqs")}: ${status.requestsLastMinute ?? 0}</span>
      <span class="spacer"></span>
      <button class="btn small" onclick="A.gatewayStart()">${t("start")}</button>
      <button class="ghost small" onclick="A.gatewayStop()">${t("stop")}</button>
    </div>
  </div>`;
}

function apiPage() {
  const status = S.status || {};
  const settings = S.settings || {};
  const route = S.route;
  const bridge = S.bridge;
  const base = `http://127.0.0.1:${settings.port || status.port || 18317}/v1`;
  const routeState = !route || !route.provider
    ? `<span class="pill warn">${t("routeInactive")}</span>`
    : route.ours
      ? `<span class="pill ok">${t("routeActive")}</span>`
      : `<span class="pill danger">${t("routeOther")}: ${esc(route.provider)}</span>`;
  const bridgeState = bridge && bridge.attached
    ? `<span class="pill ok">${t("bridgeOn")}</span><span class="pill">${t("port")}: ${esc(bridge.debugPort ?? "—")}</span>${bridge.model ? `<span class="pill gold">${esc(bridge.model)}</span>` : ""}`
    : `<span class="pill warn">${t("bridgeOff")}</span><span class="footnote">${t("bridgeHint")}${bridge && bridge.reason ? " · " + esc(bridge.reason) : ""}</span>`;
  return `
  ${pageHead("codex", t("api"), t("apiSub"))}
  <div class="card">
    <h2>${t("gateway")}</h2>
    <div class="stack">
      <div class="row">
        <span class="dot ${status.running ? "ok" : "err"}"></span>
        <b>${status.running ? t("running") : t("stopped")}</b>
        <span class="pill">${t("reqs")}: ${status.requestsLastMinute ?? 0}</span>
        <span class="spacer"></span>
        <button class="btn small" onclick="A.gatewayStart()">${t("start")}</button>
        <button class="ghost small" onclick="A.gatewayStop()">${t("stop")}</button>
      </div>
      <table class="kv">
        <tr><td>${t("endpoint")}</td><td>${esc(base)}</td></tr>
        <tr><td>${t("apiKey")}</td><td>${esc(settings.apiKey || "—")} <button class="ghost small" onclick="A.copy('${esc(settings.apiKey || "")}')">${t("copy")}</button></td></tr>
        <tr><td>${t("logFile")}</td><td>${esc(status.logPath || "—")}</td></tr>
        <tr><td>${t("dataDir")}</td><td>${esc(status.dataDir || "—")}</td></tr>
      </table>
    </div>
  </div>

  <div class="card">
    <h2>${t("codexRoute")}</h2>
    <div class="stack">
      <div class="row">${routeState}</div>
      <div class="row">${bridgeState}</div>
      <table class="kv">
        <tr><td>config.toml</td><td>${esc((route && route.configPath) || "—")}</td></tr>
        <tr><td>${t("catalog")}</td><td>${route && route.catalogExists ? "✓ " + esc(route.catalogPath || "") : "—"}</td></tr>
      </table>
      <div class="row">
        <button class="btn small" onclick="A.codexRouteApply()" ${S.busy.route ? "disabled" : ""}>${t("routeApply")}</button>
        <button class="ghost small" onclick="A.codexRouteRemove()">${t("routeRemove")}</button>
        ${bridge && bridge.attached ? "" : `<button class="ghost small" onclick="A.bridgeLaunchCodex()" ${S.busy.launch ? "disabled" : ""}>${t("bridgeRestart")}</button>`}
      </div>
    </div>
  </div>

  <div class="card">
    <h2>${t("endpointsTitle")}</h2>
    <table class="kv">
      <tr><td>OpenAI-compatible</td><td>${esc(base)}/chat/completions · /responses · /models</td></tr>
      <tr><td>${t("apiKey")}</td><td>Authorization: Bearer ${esc(settings.apiKey || "…")}</td></tr>
    </table>
  </div>

  <div class="card">
    <h2>${t("checkTitle")} <span class="hint">${t("checkHint")}</span></h2>
    <div class="row">
      <button class="btn small" onclick="A.checkApi()" ${S.busy.check ? "disabled" : ""}>${t("check")}</button>
    </div>
    ${S.checkResult ? `<div class="footnote mono">${esc(S.checkResult)}</div>` : ""}
  </div>`;
}

function claudeQuotaTile(title, percent, resetIso) {
  const width = percent === null || percent === undefined ? 0 : Math.min(100, Math.max(0, percent));
  return `
  <div class="quota">
    <div class="top"><span class="name">${esc(title)}</span><span class="val">${round(percent)}</span></div>
    <div class="bar"><i class="${quotaTint(percent)}" style="width:${width}%"></i></div>
    <div class="bottom"><span>${claudeResetText(resetIso)}</span></div>
  </div>`;
}

function claudeCard(settings) {
  const u = S.claude;
  const login = S.claudeLogin;
  const connected = !!(u && u.connected);
  const pillClass = login ? "warn" : connected ? "ok" : u && u.error ? "danger" : "";
  const pillText = login ? t("claudeConnecting") : connected ? t("claudeConnected") : u && u.error ? t("error") : t("claudeNotConnected");
  const actions = login
    ? `<button class="btn small" disabled>${t("claudeConnecting")}</button>
       <button class="ghost small" onclick="A.claudeCancel()">${t("claudeCancel")}</button>`
    : `${connected ? "" : `<button class="btn small" onclick="A.claudeConnect()" ${S.busy.claudeConnect ? "disabled" : ""}>${t("claudeConnect")}</button>`}
       <button class="ghost small" onclick="A.claudeRefreshUsage()" ${S.busy.claudeUsage ? "disabled" : ""}>${t("refresh")}</button>
       ${connected ? `<button class="ghost small" onclick="A.claudeDisconnect()" ${S.busy.claudeDisconnect ? "disabled" : ""}>${t("claudeDisconnect")}</button>` : ""}`;

  return `
  <div class="card">
    <h2>${t("claude")} <span class="pill ${pillClass}">${pillText}</span></h2>
    <div class="stack">
      <div class="row">
        <span class="muted">${esc((u && u.email) || "—")}</span>
        ${u && u.plan ? `<span class="pill gold">${esc(u.plan)}</span>` : ""}
        <span class="pill">${t("models")}: ${u && u.modelCount !== null && u.modelCount !== undefined ? u.modelCount : "—"}</span>
      </div>
      <div class="grid2">
        ${claudeQuotaTile(t("fiveHour"), u ? u.fiveHourPercent : null, u ? u.fiveHourReset : null)}
        ${claudeQuotaTile(t("week"), u ? u.weeklyPercent : null, u ? u.weeklyReset : null)}
      </div>
      ${historyStrip("claude")}
      ${u && u.error ? `<div class="footnote">${esc(u.error)}</div>` : ""}
      ${u && u.updatedAt ? `<div class="footnote">${t("quotaAge")}: ${esc(claudeAgeText(u.updatedAt))}</div>` : ""}
      <div class="row">${actions}</div>

      <label class="field">${t("claudeKey")}
        <input type="password" id="claude-key" value="${esc(settings.claudeApiKey || "")}" placeholder="sk-ant-…">
      </label>
      <div class="row">
        <label class="field" style="flex-direction:row;align-items:center;gap:6px">
          <input type="checkbox" id="claude-enabled" ${settings.claudeEnabled ? "checked" : ""}>
          <span>${t("sourceEnabled")}</span>
        </label>
        <button class="btn small" onclick="A.claudeSaveKeys()">${t("save")}</button>
      </div>
      <div class="footnote">${t("claudeHint")}</div>
    </div>
  </div>`;
}

function antigravityCard() {
  const u = S.antigravity;
  const login = S.antigravityLogin;
  const connected = !!(u && u.connected);
  const pillClass = login ? "warn" : connected ? "ok" : u && u.error ? "danger" : "";
  const pillText = login ? t("antigravityConnecting") : connected ? t("antigravityConnected") : u && u.error ? t("error") : t("antigravityNotConnected");
  const actions = login
    ? `<button class="btn small" disabled>${t("antigravityConnecting")}</button>
       <button class="ghost small" onclick="A.antigravityCancel()">${t("antigravityCancel")}</button>`
    : `${connected ? "" : `<button class="btn small" onclick="A.antigravityConnect()" ${S.busy.antigravityConnect ? "disabled" : ""}>${t("antigravityConnect")}</button>`}
       <button class="ghost small" onclick="A.antigravityRefresh()" ${S.busy.antigravityUsage ? "disabled" : ""}>${t("refresh")}</button>
       ${connected ? `<button class="ghost small" onclick="A.antigravityDisconnect()" ${S.busy.antigravityDisconnect ? "disabled" : ""}>${t("antigravityDisconnect")}</button>` : ""}`;

  // No quota tiles: the engine exposes no Antigravity quota API, and the spec
  // forbids fabricating percentages (AC8).
  return `
  <div class="card">
    <h2>${t("antigravity")} <span class="pill ${pillClass}">${pillText}</span></h2>
    <div class="stack">
      <div class="row">
        <span class="muted">${esc((u && u.email) || "—")}</span>
        ${u && u.projectId ? `<span class="pill gold">${t("projectId")}: ${esc(u.projectId)}</span>` : ""}
        <span class="pill">${t("models")}: ${u && u.modelCount !== null && u.modelCount !== undefined ? u.modelCount : "—"}</span>
      </div>
      ${u && u.error ? `<div class="footnote">${esc(u.error)}</div>` : ""}
      ${u && u.updatedAt ? `<div class="footnote">${t("quotaAge")}: ${esc(claudeAgeText(u.updatedAt))}</div>` : ""}
      <div class="row">${actions}</div>
      <div class="footnote">${t("antigravityHint")}</div>
    </div>
  </div>`;
}

// Read-only diagnostics: every value comes from an existing IPC call, and
// rejected calls are printed verbatim instead of being summarized.
function diagCell(value) {
  const text = value && value.text !== undefined && value.text !== null && value.text !== ""
    ? String(value.text)
    : "—";
  const cls = value && value.cls ? ` ${value.cls}` : "";
  return `<td><span class="pill${cls}">${esc(text)}</span></td>`;
}

function diagnosticsCard() {
  const diag = S.diag;
  return `
  <div class="card">
    <h2>${t("diagTitle")} <span class="hint">${t("diagHint")}</span></h2>
    <div class="row">
      <button class="btn small" onclick="A.diagRun()" ${S.busy.diag ? "disabled" : ""}>${t("diagRun")}</button>
      <span class="footnote" style="margin-top:0">${diag ? `${t("diagAt")}: ${esc(ageText(diag.at / 1000))}` : t("diagIdle")}</span>
    </div>
    ${diag ? `
      <table class="diag">
        <thead><tr>
          <th>${t("diagProvider")}</th>
          <th>${t("gateway")}</th>
          <th>${t("diagAuth")}</th>
          <th>${t("models")}</th>
          <th>${t("diagQuota")}</th>
        </tr></thead>
        <tbody>
          ${diag.rows.map((row) => `<tr>
            <td>${esc(row.name)}</td>
            ${diagCell(row.reach)}
            ${diagCell(row.auth)}
            ${diagCell(row.models)}
            ${diagCell(row.quota)}
          </tr>`).join("")}
        </tbody>
      </table>
      ${diag.errors.length ? `<div class="stack" style="margin-top:10px">
        ${diag.errors.map((item) => `<div class="footnote mono" style="margin-top:0;white-space:pre-wrap">${esc(item.command)}: ${esc(item.message)}</div>`).join("")}
      </div>` : ""}` : ""}
  </div>`;
}

function providersPage() {
  const settings = S.settings || {};
  const p = S.providers;
  const models = S.models || [];
  const query = String(S.modelsQuery || "").trim().toLowerCase();
  const filtered = query
    ? models.filter((m) => {
        // Ids and display names are both searchable; the list stays deduped
        // upstream in modelsLoad.
        const haystack = `${m.id || ""} ${m.displayName || m.display_name || ""}`.toLowerCase();
        return haystack.includes(query);
      })
    : models;
  const metric = (label, value) => `
    <tr><td>${esc(label)}</td><td>${value === null || value === undefined ? "—" : esc(typeof value === "number" ? value.toFixed(4) : value)}</td></tr>`;

  return `
  ${pageHead("codex", t("providers"), t("providersSub"))}
  <div class="grid2">
    <div class="card">
      <h2>${t("openrouter")}</h2>
      <div class="stack">
        <label class="field">${t("orKey")}
          <input type="password" id="or-key" value="${esc(settings.openrouterKey || "")}" placeholder="sk-or-v1-…">
        </label>
        <div class="row">
          <label class="field" style="flex-direction:row;align-items:center;gap:6px">
            <input type="checkbox" id="or-enabled" ${settings.openrouterEnabled ? "checked" : ""}>
            <span>${t("sourceEnabled")}</span>
          </label>
          <label class="field" style="flex-direction:row;align-items:center;gap:6px">
            <input type="checkbox" id="oc-enabled" ${settings.opencodeEnabled ? "checked" : ""}>
            <span>OpenCode ${t("sourceEnabled")}</span>
          </label>
        </div>
        <div class="row">
          <button class="btn small" onclick="A.saveKeys()">${t("save")}</button>
          <button class="ghost small" onclick="A.openrouterRefresh()" ${S.busy.openrouter ? "disabled" : ""}>${t("refresh")}</button>
        </div>
        ${p ? `<table class="kv">
          ${metric(t("totalCredits"), p.totalCredits)}
          ${metric(t("spend"), p.totalUsage)}
          ${metric(t("remaining"), p.remaining)}
          ${metric(t("keyLimit"), p.limit)}
          ${metric(t("keySpend"), p.usage)}
        </table>` : `<div class="footnote">${t("loading")}</div>`}
        ${historyStrip("openrouter")}
      </div>
    </div>

    <div class="card">
      <h2>${t("opencode")}</h2>
      <div class="stack">
        <label class="field">${t("ocKey")}
          <input type="password" id="oc-key" value="${esc(settings.opencodeKey || "")}" placeholder="oc_sk_…">
        </label>
        <div class="row">
          <button class="btn small" onclick="A.saveKeys()">${t("save")}</button>
        </div>
        <div class="footnote">${t("ocHint")}</div>
      </div>
    </div>
  </div>

  ${claudeCard(settings)}

  ${antigravityCard()}

  ${diagnosticsCard()}

  <div class="card">
    <h2>${t("models")} <span class="hint">${filtered.length} ${t("modelsCount")}</span></h2>
    <div class="row">
      <input type="text" id="models-search" placeholder="${t("modelsSearch")}" value="${esc(S.modelsQuery || "")}" oninput="A.modelsSearch(this.value)">
      <button class="ghost small" onclick="A.modelsLoad()">${t("refresh")}</button>
    </div>
    <div style="max-height:420px;overflow:auto;margin-top:10px">
      ${filtered.slice(0, 400).map((m) => {
        const id = String(m.id || "");
        // Antigravity membership wins over the claude- prefix: it serves
        // claude-*/gemini-*/gpt-oss ids, so prefix alone would mislabel them.
        const provider = S.antigravityIds && S.antigravityIds.has(id)
          ? "Antigravity"
          : id.startsWith("opencode/") ? "OpenCode" : id.startsWith("openrouter/") ? "OpenRouter" : id.startsWith("claude-") ? "Claude" : "OpenAI";
        return `<div class="row" style="padding:3px 0;gap:8px">
          <span class="pill ${provider === "OpenAI" ? "gold" : ""}">${provider}</span>
          <span class="mono" style="font-size:11px">${esc(id)}</span>
        </div>`;
      }).join("") || `<div class="footnote">${t("noCalls")}</div>`}
    </div>
  </div>`;
}

function donatePage() {
  const address = "TXtXMdkwKt2Nnxwo7ST9h4otFp3WYWjpfw";
  return `
  ${pageHead("melon tools", t("donate"), t("donateSub"))}
  <div class="card">
    <h2>USDT · TRC20</h2>
    <div class="row" style="align-items:flex-start;gap:24px">
      <canvas id="donate-qr" width="220" height="220" style="background:#fff;border-radius:12px;padding:8px"></canvas>
      <div class="stack">
        <table class="kv">
          <tr><td>${t("donateAddress")}</td><td>${esc(address)} <button class="ghost small" onclick="A.copy('${address}')">${t("copy")}</button></td></tr>
        </table>
        <div class="footnote">${t("donateScan")}</div>
        <div class="footnote">${t("donateNote")}</div>
      </div>
    </div>
  </div>`;
}

function renderDonateQr() {
  const canvas = document.getElementById("donate-qr");
  if (!canvas || typeof qrcode === "undefined") return;
  const address = "TXtXMdkwKt2Nnxwo7ST9h4otFp3WYWjpfw";
  const qr = qrcode(0, "M");
  qr.addData(address);
  qr.make();
  const count = qr.getModuleCount();
  const size = canvas.width / count;
  const context = canvas.getContext("2d");
  context.fillStyle = "#ffffff";
  context.fillRect(0, 0, canvas.width, canvas.height);
  context.fillStyle = "#1A1A1C";
  for (let row = 0; row < count; row++) {
    for (let col = 0; col < count; col++) {
      if (qr.isDark(row, col)) {
        context.fillRect(col * size, row * size, Math.ceil(size), Math.ceil(size));
      }
    }
  }
}

function settingsPage() {
  const settings = S.settings || {};
  const info = S.info || {};
  return `
  ${pageHead("melon tools", t("settings"), t("settingsSub"))}
  <div class="card">
    <h2>${t("general")}</h2>
    <div class="stack">
      <div class="row">
        <label class="field">${t("language")}
          <select id="set-lang">
            <option value="ru" ${S.lang === "ru" ? "selected" : ""}>Русский</option>
            <option value="en" ${S.lang === "en" ? "selected" : ""}>English</option>
          </select>
        </label>
        <label class="field">${t("port")}
          <input class="small" type="number" id="set-port" value="${settings.port ?? 18317}" min="1024" max="65535">
        </label>
        <label class="field">${t("quotaInterval")}
          <input class="small" type="number" id="set-interval" value="${settings.quotaInterval ?? 300}" min="60" step="60">
        </label>
      </div>
      <div class="row">
        <label class="field" style="flex-direction:row;align-items:center;gap:6px">
          <input type="checkbox" ${S.autostart ? "checked" : ""} onchange="A.autostartToggle(this.checked)">
          <span>${t("autostart")}</span>
        </label>
        <label class="field" style="flex-direction:row;align-items:center;gap:6px">
          <input type="checkbox" ${settings.notifyLowQuota ? "checked" : ""} onchange="A.notifyToggle(this.checked)">
          <span>${t("notifications")}</span>
        </label>
      </div>
      <div class="footnote" style="margin-top:0">${t("notificationsHint")}</div>
      <div class="row">
        <label class="field" style="flex:1">${t("fleetHome")}
          <input type="text" id="set-fleet-home" value="${esc(settings.fleetHome || "")}" placeholder="%USERPROFILE%\\.melon-fleet">
        </label>
      </div>
      <div class="row">
        <button class="btn small" onclick="A.applySettings()">${t("apply")}</button>
        <span class="footnote">${t("autoRefresh")}</span>
      </div>
    </div>
  </div>

  <div class="card">
    <h2>${t("about")}</h2>
    <table class="kv">
      <tr><td>${t("version")}</td><td>${esc(info.version || "—")}</td></tr>
      <tr><td>${t("platform")}</td><td>${esc(info.platform || "—")}</td></tr>
      <tr><td>${t("dataDir")}</td><td>${esc(info.dataDir || "—")}</td></tr>
      <tr><td>${t("codexHome")}</td><td>${esc(info.codexHome || "—")}</td></tr>
    </table>
  </div>`;
}

function composerPage() {
  const bridge = S.bridge;
  const attached = bridge && bridge.attached;
  return `
  ${pageHead("codex", t("composer"), t("composerHint"))}
  <div class="card">
    <h2>${t("bridge")}</h2>
    <div class="stack">
      <div class="row">
        ${attached
          ? `<span class="pill ok">${t("bridgeOn")}</span>
             <span class="pill">${t("port")}: ${esc(bridge.debugPort ?? "—")}</span>
             ${bridge.model ? `<span class="pill gold">${esc(bridge.model)}</span>` : ""}`
          : `<span class="pill warn">${t("bridgeOff")}</span>
             <span class="footnote">${t("bridgeHint")}${bridge && bridge.reason ? " · " + esc(bridge.reason) : ""}</span>`}
      </div>
      <div class="row">
        <button class="ghost small" onclick="A.bridgeLaunchCodex()" ${S.busy.launch ? "disabled" : ""}>${t("bridgeRestart")}</button>
        <button class="ghost small" onclick="A.refreshStatus()">${t("refresh")}</button>
      </div>
      <table class="kv">
        <tr><td>${t("session")}</td><td>${esc(bridge && bridge.threadId ? bridge.threadId : "—")}</td></tr>
        <tr><td>${t("api")}</td><td>${t("composerHint")}</td></tr>
      </table>
    </div>
  </div>`;
}

function instancesPage() {
  const instances = S.instancesData || [];
  const accounts = S.accounts || [];
  return `
  ${pageHead("codex", t("instances"), t("instanceHint"))}
  <div class="card">
    <div class="row">
      <input type="text" id="instance-name" placeholder="${t("instanceNew")}">
      <button class="btn small" onclick="A.instanceCreate()">${t("instanceCreate")}</button>
      <span class="footnote">${t("instanceHint")}</span>
    </div>
  </div>
  <div class="accounts">
    ${instances.map((instance) => `
      <div class="card">
        <div class="account-head">
          <span class="email">${esc(instance.name)}</span>
          <span class="pill ${instance.exists ? "ok" : "warn"}">${instance.exists ? t("found") : t("missing")}</span>
        </div>
        <div class="stack">
          <div class="footnote mono">${esc(instance.homePath || "")}</div>
          <div class="row">
            <label class="field">${t("instanceBind")}
              <select onchange="A.instanceBind('${esc(instance.id)}', this.value)">
                <option value="">${t("instanceNone")}</option>
                ${accounts.map((a) => `<option value="${esc(a.id)}" ${instance.accountId === a.id ? "selected" : ""}>${esc(a.email || a.displayName)}</option>`).join("")}
              </select>
            </label>
            <button class="btn small" onclick="A.instanceLaunch('${esc(instance.id)}')">${t("instanceLaunch")}</button>
            <span class="spacer"></span>
            <button class="ghost small danger" onclick="A.instanceDelete('${esc(instance.id)}')">${t("instanceDelete")}</button>
          </div>
        </div>
      </div>`).join("") || `<div class="card"><div class="muted">${t("noCalls")}</div></div>`}
  </div>`;
}

function fleetPage() {
  const fleet = S.fleet;
  const tab = S.fleetTab || "status";
  const tabs = [["status", "fleetStatus"], ["results", "fleetResults"], ["config", "fleetConfig"], ["commands", "fleetCommands"]];
  const tabBar = `<div class="row">${tabs.map(([value, key]) => `<button class="${tab === value ? "btn" : "ghost"} small" onclick="A.fleetTabSet('${value}')">${t(key)}</button>`).join("")}
    <span class="spacer"></span>
    <button class="ghost small" onclick="A.fleetLoad()">${t("refresh")}</button></div>`;

  let body = "";
  if (!fleet) {
    body = `<div class="card"><div class="muted">${t("loading")}</div></div>`;
  } else if (tab === "status") {
    body = `
      <div class="card">
        <h2>${t("fleetCli")}</h2>
        <table class="kv">
          <tr><td>${t("fleetHome")}</td><td>${esc(fleet.home || "—")}</td></tr>
          <tr><td>${t("fleetCli")}</td><td>${fleet.cli ? esc(fleet.cli) : t("fleetCliMissing")}</td></tr>
        </table>
      </div>
      <div class="card">
        <h2>${t("fleetSnapshots")} <span class="hint">${(fleet.snapshots || []).length}</span></h2>
        ${(fleet.snapshots || []).map((snap) => `<details><summary class="footnote" style="cursor:pointer">${esc(snap.name)}</summary>
            <div class="footnote mono" style="white-space:pre-wrap;max-height:240px;overflow:auto">${esc(JSON.stringify(snap.data, null, 2) || "")}</div>
          </details>`).join("") || `<div class="footnote">${t("noCalls")}</div>`}
      </div>
      <div class="card">
        <h2>${t("fleetLog")}</h2>
        <div class="footnote mono" style="white-space:pre-wrap;max-height:280px;overflow:auto">${esc((fleet.logTail || []).join("\n")) || "—"}</div>
      </div>`;
  } else if (tab === "results") {
    const items = fleet.results || [];
    body = `
      <div class="card">
        <h2>${t("fleetResults")} <span class="hint">${items.length}</span></h2>
        ${items.map((item) => `<div class="row" style="padding:3px 0;gap:10px">
            <span class="pill">${esc(item.unit)}</span>
            <span class="mono" style="font-size:11px">${esc(item.name)}</span>
            <span class="muted footnote">${Math.round((item.size || 0) / 1024)} КБ</span>
            <span class="spacer"></span>
            <button class="ghost small" onclick="A.fleetOpenResult('${esc(item.path)}')">${t("fleetOpenResult")}</button>
          </div>`).join("") || `<div class="footnote">${t("noCalls")}</div>`}
        ${S.fleetResult ? `<div class="footnote mono" style="white-space:pre-wrap;max-height:360px;overflow:auto;margin-top:10px">${esc(S.fleetResult)}</div>` : ""}
      </div>`;
  } else if (tab === "config") {
    body = `
      <div class="card">
        <h2>${t("fleetConfig")} <span class="hint">${esc((S.fleetConfig && S.fleetConfig.path) || "")}</span></h2>
        <textarea id="fleet-config" style="width:100%;min-height:280px;background:var(--soft);color:var(--text);border:1px solid var(--border);border-radius:8px;padding:10px;font-family:var(--mono);font-size:12px">${esc((S.fleetConfig && S.fleetConfig.text) || "")}</textarea>
        <div class="row" style="margin-top:8px">
          <button class="btn small" onclick="A.fleetSaveConfig()">${t("fleetSave")}</button>
        </div>
      </div>`;
  } else {
    body = `
      <div class="card">
        <h2>${t("fleetCommands")} <span class="hint">melon-fleet</span></h2>
        <div class="row">
          <button class="ghost small" onclick="A.fleetRun(['status'])">status</button>
          <button class="ghost small" onclick="A.fleetRun(['doctor'])">doctor</button>
          <button class="ghost small" onclick="A.fleetRun(['--version'])">--version</button>
        </div>
        ${S.fleetOutput ? `<div class="footnote mono" style="white-space:pre-wrap;max-height:360px;overflow:auto;margin-top:10px">${esc(S.fleetOutput)}</div>` : ""}
      </div>`;
  }

  return `${pageHead("melon tools", t("fleet"), t("fleetHome"))}${tabBar}${body}`;
}

// MARK: - Refresh guard (M3)

const FORM_TAGS = ["INPUT", "TEXTAREA", "SELECT"];

function isFormField(node) {
  return !!node && FORM_TAGS.indexOf(node.tagName) >= 0;
}

// The 5 s status tick re-renders whole pages, which would wipe what the user
// is typing. The full render runs only when no field is focused and no edit
// is pending; the footer status update always runs.
function editsInProgress() {
  // The edited element can be removed by another render without a focusout
  // event — then there is nothing left to protect and the flag must not
  // stall future updates.
  if (S.dirtyInput && S.dirtyField && !S.dirtyField.isConnected) {
    S.dirtyInput = false;
    S.dirtyField = null;
  }
  if (isFormField(document.activeElement)) return true;
  return !!S.dirtyInput;
}

const A = {
  go(section) {
    S.section = section;
    render();
  },

  onboardingGo(section) {
    markOnboardingSeen();
    const modal = document.getElementById("onboarding-modal");
    if (modal) modal.hidden = true;
    S.section = section;
    render();
  },

  onboardingDone() {
    markOnboardingSeen();
    const modal = document.getElementById("onboarding-modal");
    if (modal) modal.hidden = true;
  },

  async copy(text) {
    try {
      await navigator.clipboard.writeText(text);
      toast(t("copied"));
    } catch {
      toast(text);
    }
  },

  async refreshStatus() {
    try {
      S.status = await inv("gateway_status");
      S.bridge = await inv("bridge_status");
      renderFooter();
      if (S.section !== "dashboard" && S.section !== "api" && S.section !== "accounts") return;
      if (editsInProgress()) {
        // Status-only update done; the full render resumes after the field
        // loses focus (see the focusout hook in the boot section).
        S.renderDeferred = true;
        return;
      }
      S.renderDeferred = false;
      render();
    } catch (error) {
      // Keep the previous status on transient failures.
    }
  },

  async refreshAccounts() {
    S.accounts = await inv("vault_list");
  },

  async historyLoad() {
    try {
      const raw = await inv("quota_history");
      const samples = Array.isArray(raw)
        ? raw
        : Array.isArray(raw && raw.samples) ? raw.samples : [];
      S.history = samples.filter((sample) => sample && typeof sample.key === "string");
    } catch {
      // History is decorative: keep the previous samples on a failed read.
    }
  },

  async loadAll() {
    try {
      S.info = await inv("app_info");
      S.settings = await inv("settings_get");
      S.lang = (S.settings && S.settings.lang) === "en" ? "en" : "ru";
      S.accounts = await inv("vault_list");
      await A.historyLoad();
      S.status = await inv("gateway_status");
      S.route = await inv("codex_route_status");
      S.bridge = await inv("bridge_status");
      S.routing = await inv("routing_state");
      S.calls = await inv("gateway_recent_calls", { limit: 8 });
      S.autostart = await inv("autostart_get");
    } catch (error) {
      toast(String(error), true);
    }
    render();
  },

  gatewayStart() {
    run("start", async () => {
      const result = await inv("gateway_start");
      toast(result === "adopted" ? `${t("gateway")}: adopted` : `${t("gateway")}: ${t("running")}`);
      await A.refreshStatus();
    });
  },

  gatewayStop() {
    run("stop", async () => {
      await inv("gateway_stop");
      toast(`${t("gateway")}: ${t("stopped")}`);
      await A.refreshStatus();
    });
  },

  gatewaySync() {
    run("sync", async () => {
      const result = await inv("gateway_sync");
      toast(`${t("sync")}: ${result.syncedAccounts}`);
    });
  },

  checkApi() {
    run("check", async () => {
      S.checkResult = await inv("gateway_check");
      toast(t("done"));
    });
  },

  // Read-only connectivity/auth/model check. Every probe is independent, so a
  // stopped gateway or one failing provider does not hide the other results.
  diagRun() {
    return run("diag", async () => {
      const checks = [
        ["settings", "settings_get", () => inv("settings_get")],
        ["accounts", "vault_list", () => inv("vault_list")],
        ["gatewayStatus", "gateway_status", () => inv("gateway_status")],
        ["gatewayCheck", "gateway_check", () => inv("gateway_check")],
        ["gatewayModels", "gateway_models", () => inv("gateway_models")],
        ["claudeCredentials", "claude_credentials", () => inv("claude_credentials")],
        ["claudeModels", "claude_models", () => inv("claude_models")],
        ["claudeUsage", "claude_usage", () => inv("claude_usage")],
        ["antigravityCredentials", "antigravity_credentials", () => inv("antigravity_credentials")],
        ["antigravityModels", "antigravity_models", () => inv("antigravity_models")],
        ["antigravityMetrics", "antigravity_metrics", () => inv("antigravity_metrics")],
      ];
      const settled = await Promise.allSettled(checks.map(([, , call]) => call()));
      const data = {};
      const errors = [];
      checks.forEach(([key, command], index) => {
        const result = settled[index];
        if (result.status === "fulfilled") data[key] = result.value;
        else errors.push({ command, message: errorText(result.reason) });
      });

      const has = (key) => Object.prototype.hasOwnProperty.call(data, key);
      const settings = data.settings || {};
      const accounts = Array.isArray(data.accounts) ? data.accounts : [];
      const gateway = data.gatewayStatus || null;
      const running = !!(gateway && gateway.running);
      const port = (gateway && gateway.port) || settings.port || "—";

      const gatewayIds = [];
      const seenIds = new Set();
      for (const model of Array.isArray(data.gatewayModels) ? data.gatewayModels : []) {
        const id = String((model && model.id) || "");
        if (seenIds.has(id)) continue;
        seenIds.add(id);
        gatewayIds.push(id);
      }
      const countPrefix = (prefix) => gatewayIds.filter((id) => id.startsWith(prefix)).length;

      const claudeModels = data.claudeModels && Array.isArray(data.claudeModels.models)
        ? data.claudeModels.models
        : null;
      const antigravityModels = data.antigravityModels && Array.isArray(data.antigravityModels.models)
        ? data.antigravityModels.models
        : null;
      const claudeCredentials = data.claudeCredentials && Array.isArray(data.claudeCredentials.credentials)
        ? data.claudeCredentials.credentials.length
        : null;
      const antigravityCredentials = data.antigravityCredentials && Array.isArray(data.antigravityCredentials.credentials)
        ? data.antigravityCredentials.credentials.length
        : null;

      const keyAuth = (value) => value && String(value).trim()
        ? { text: t("diagKeySet"), cls: "ok" }
        : { text: t("diagKeyMissing"), cls: "warn" };
      const countCell = (count) => ({
        text: count === null || count === undefined ? "—" : String(count),
        cls: count === null || count === undefined ? "" : count > 0 ? "ok" : "warn",
      });
      const quotaCell = (iso) => {
        const ts = Date.parse(iso || "");
        return Number.isNaN(ts) ? { text: "—", cls: "" } : { text: claudeAgeText(iso), cls: "ok" };
      };

      const reach = {
        text: running
          ? `${t("running")} · :${port}${has("gatewayCheck") ? " · " + t("diagApiOk") : ""}`
          : t("stopped"),
        cls: running ? "ok" : "danger",
      };
      const viaGateway = {
        text: running ? t("diagUp") : t("diagDown"),
        cls: running ? "ok" : "danger",
      };
      const codexQuota = accounts.reduce((latest, account) => Math.max(latest, Number(account.quotaUpdatedAt) || 0), 0);

      const rows = [
        {
          name: t("gateway"), reach,
          auth: { text: "—", cls: "" },
          models: countCell(has("gatewayModels") ? gatewayIds.length : null),
          quota: { text: "—", cls: "" },
        },
        {
          name: t("diagCodex"), reach: viaGateway,
          auth: { text: `${accounts.length} ${t("accountsCount")}`, cls: accounts.length ? "ok" : "warn" },
          models: countCell(has("gatewayModels")
            ? gatewayIds.filter((id) => !id.startsWith("opencode/") && !id.startsWith("openrouter/")).length
            : null),
          quota: codexQuota ? { text: ageText(codexQuota), cls: "ok" } : { text: "—", cls: "" },
        },
        {
          name: t("openrouter"), reach: viaGateway,
          auth: keyAuth(settings.openrouterKey),
          models: countCell(has("gatewayModels") ? countPrefix("openrouter/") : null),
          quota: { text: "—", cls: "" },
        },
        {
          name: t("opencode"), reach: viaGateway,
          auth: keyAuth(settings.opencodeKey),
          models: countCell(has("gatewayModels") ? countPrefix("opencode/") : null),
          quota: { text: "—", cls: "" },
        },
        {
          name: t("claude"), reach: viaGateway,
          auth: countCell(claudeCredentials),
          models: countCell(claudeModels ? claudeModels.length : null),
          quota: has("claudeUsage") ? quotaCell(data.claudeUsage && data.claudeUsage.updatedAt) : { text: "—", cls: "" },
        },
        {
          name: t("antigravity"), reach: viaGateway,
          auth: countCell(antigravityCredentials),
          models: countCell(antigravityModels ? antigravityModels.length : null),
          quota: has("antigravityMetrics") ? quotaCell(data.antigravityMetrics && data.antigravityMetrics.updatedAt) : { text: "—", cls: "" },
        },
      ];

      S.diag = { at: Date.now(), rows, errors };
    });
  },

  codexRouteApply() {
    run("route", async () => {
      const result = await inv("codex_route_apply");
      S.route = result.route;
      toast(`${t("routeApply")}: ok · models +${result.catalogCustom}`);
    });
  },

  codexRouteRemove() {
    run("route", async () => {
      S.route = await inv("codex_route_remove");
      toast(t("done"));
    });
  },

  async bridgeLaunchCodex() {
    if (!window.confirm(t("bridgeRestartConfirm"))) return;
    run("launch", async () => {
      const result = await inv("bridge_launch_codex");
      toast(`${t("bridgeRestarted")}: ${result}`);
      setTimeout(() => A.refreshStatus(), 8000);
    });
  },

  refreshQuotas() {
    S.lastQuotaRefreshAt = Date.now();
    run("quotas", async () => {
      const result = await inv("quota_refresh");
      S.accounts = result.accounts;
      await A.historyLoad();
      if (result.errors && result.errors.length) toast(result.errors.join("\n"), true);
      else toast(`${t("refreshQuotas")}: ${t("done")}`);
    });
  },

  refreshQuota(id) {
    run("quotas", async () => {
      const result = await inv("quota_refresh", { id });
      S.accounts = result.accounts;
      await A.historyLoad();
      if (result.errors && result.errors.length) toast(result.errors.join("\n"), true);
    });
  },

  refreshLogin(id) {
    run("login-" + id, async () => {
      S.accounts = await inv("account_refresh_tokens", { id });
      toast(t("done"));
    });
  },

  switchAccount(id) {
    run("switch-" + id, async () => {
      const result = await inv("switch_account", { id });
      toast(`${t("makeCurrent")}: ${result.authPath}`);
      await A.refreshAccounts();
    });
  },

  async importAuth() {
    run("import", async () => {
      const result = await inv("import_current_auth");
      S.accounts = result.accounts;
      toast(`${t("importAuth")}: ${result.result}`);
    });
  },

  saveReserves(id) {
    run("reserves-" + id, async () => {
      const hourly = parseInt(document.getElementById("res-h-" + id).value, 10);
      const weekly = parseInt(document.getElementById("res-w-" + id).value, 10);
      S.accounts = await inv("save_reserves", {
        id,
        hourly: Number.isFinite(hourly) ? hourly : null,
        weekly: Number.isFinite(weekly) ? weekly : null,
      });
      toast(t("done"));
    });
  },

  async deleteAccount(id) {
    const account = (S.accounts || []).find((a) => a.id === id);
    const name = account ? account.email || account.displayName : id;
    if (!window.confirm(fmt(t("confirmDelete"), { name }))) return;
    run("delete-" + id, async () => {
      S.accounts = await inv("delete_account", { id });
      toast(t("done"));
    });
  },

  saveKeys() {
    run("keys", async () => {
      const openrouterKey = document.getElementById("or-key").value.trim();
      const opencodeKey = document.getElementById("oc-key").value.trim();
      S.settings = await inv("settings_set", { settings: { ...S.settings, openrouterKey, opencodeKey } });
      toast(t("done"));
    });
  },

  openrouterRefresh() {
    run("openrouter", async () => {
      S.providers = await inv("openrouter_refresh");
      await A.historyLoad();
    });
  },

  claudeUsageLoad() {
    S.lastClaudeUsageAt = Date.now();
    return inv("claude_usage").then(async (usage) => {
      S.claude = usage;
      await A.historyLoad();
    });
  },

  claudeRefreshUsage() {
    run("claudeUsage", async () => {
      await A.claudeUsageLoad();
    });
  },

  claudeConnect() {
    run("claudeConnect", async () => {
      const session = await inv("claude_login_start");
      if (!session || !session.url || !session.state) throw new Error(t("claudeLoginError"));
      S.claudeLogin = { state: session.state, startedAt: Date.now(), done: false };
      render();
      inv("open_url", { url: session.url }).catch(() => {});
      clearInterval(A._claudeTimer);
      A._claudeTimer = setInterval(async () => {
        if (!S.claudeLogin) {
          clearInterval(A._claudeTimer);
          return;
        }
        // C-F9: the poll must not run forever — 10 minutes, then an honest error.
        if (Date.now() - S.claudeLogin.startedAt >= LOGIN_TIMEOUT_MS) {
          clearInterval(A._claudeTimer);
          S.claudeLogin = null;
          toast(t("loginTimeout"), true);
          render();
          return;
        }
        try {
          const result = await inv("claude_login_status", { stateToken: S.claudeLogin.state });
          if (!S.claudeLogin) return;
          if (result.status === "ok") {
            clearInterval(A._claudeTimer);
            S.claudeLogin = null;
            toast(t("done"));
            await A.claudeUsageLoad().catch(() => {});
            A.modelsLoad();
          } else if (result.status === "error") {
            clearInterval(A._claudeTimer);
            S.claudeLogin = null;
            toast(t("claudeLoginError"), true);
          }
          render();
        } catch (error) {
          clearInterval(A._claudeTimer);
          S.claudeLogin = null;
          toast(String(error), true);
          render();
        }
      }, 2000);
    });
  },

  claudeCancel() {
    const login = S.claudeLogin;
    if (!login) return;
    clearInterval(A._claudeTimer);
    S.claudeLogin = null;
    render();
    inv("claude_login_cancel", { stateToken: login.state }).catch(() => {});
  },

  claudeDisconnect() {
    // Destructive: the engine-written auth files are deleted, so the account
    // must be reconnected. Same confirmation pattern as account deletion.
    if (!window.confirm(t("confirmClaudeDisconnect"))) return;
    run("claudeDisconnect", async () => {
      const result = await inv("claude_disconnect");
      S.claude = null;
      S.lastClaudeUsageAt = 0;
      toast(`${t("claudeDisconnected")} (${(result && result.removed) || 0})`);
      await A.claudeUsageLoad().catch(() => {});
      A.modelsLoad();
    });
  },

  claudeSaveKeys() {
    run("claudeKeys", async () => {
      const claudeEnabled = document.getElementById("claude-enabled").checked;
      const claudeApiKey = document.getElementById("claude-key").value.trim();
      S.settings = await inv("settings_set", { settings: { ...S.settings, claudeEnabled, claudeApiKey } });
      toast(t("done"));
      A.claudeUsageLoad().catch(() => {});
    });
  },

  antigravityUsageLoad() {
    S.lastAntigravityAt = Date.now();
    return inv("antigravity_metrics").then((metrics) => {
      S.antigravity = metrics;
    });
  },

  antigravityRefresh() {
    run("antigravityUsage", async () => {
      await A.antigravityUsageLoad();
    });
  },

  antigravityConnect() {
    run("antigravityConnect", async () => {
      const session = await inv("antigravity_login_start");
      if (!session || !session.url || !session.state) throw new Error(t("antigravityLoginError"));
      S.antigravityLogin = { state: session.state, startedAt: Date.now(), done: false };
      render();
      inv("open_url", { url: session.url }).catch(() => {});
      clearInterval(A._antigravityTimer);
      A._antigravityTimer = setInterval(async () => {
        if (!S.antigravityLogin) {
          clearInterval(A._antigravityTimer);
          return;
        }
        // C-F9: the poll must not run forever — 10 minutes, then an honest error.
        if (Date.now() - S.antigravityLogin.startedAt >= LOGIN_TIMEOUT_MS) {
          clearInterval(A._antigravityTimer);
          S.antigravityLogin = null;
          toast(t("loginTimeout"), true);
          render();
          return;
        }
        try {
          const result = await inv("antigravity_login_status", { stateToken: S.antigravityLogin.state });
          if (!S.antigravityLogin) return;
          if (result.status === "ok") {
            clearInterval(A._antigravityTimer);
            S.antigravityLogin = null;
            toast(t("done"));
            await A.antigravityUsageLoad().catch(() => {});
            A.modelsLoad();
          } else if (result.status === "error") {
            clearInterval(A._antigravityTimer);
            S.antigravityLogin = null;
            toast(t("antigravityLoginError"), true);
          }
          render();
        } catch (error) {
          clearInterval(A._antigravityTimer);
          S.antigravityLogin = null;
          toast(String(error), true);
          render();
        }
      }, 2000);
    });
  },

  antigravityCancel() {
    const login = S.antigravityLogin;
    if (!login) return;
    clearInterval(A._antigravityTimer);
    S.antigravityLogin = null;
    render();
    inv("antigravity_login_cancel", { stateToken: login.state }).catch(() => {});
  },

  antigravityDisconnect() {
    // Destructive: the engine-written auth files are deleted, so the account
    // must be reconnected. Same confirmation pattern as Claude.
    if (!window.confirm(t("confirmAntigravityDisconnect"))) return;
    run("antigravityDisconnect", async () => {
      const result = await inv("antigravity_disconnect");
      S.antigravity = null;
      S.lastAntigravityAt = 0;
      toast(`${t("antigravityDisconnected")} (${(result && result.removed) || 0})`);
      await A.antigravityUsageLoad().catch(() => {});
      A.modelsLoad();
    });
  },

  applySettings() {
    run("settings", async () => {
      const lang = document.getElementById("set-lang").value;
      const port = parseInt(document.getElementById("set-port").value, 10);
      const quotaInterval = parseInt(document.getElementById("set-interval").value, 10);
      const fleetHome = (document.getElementById("set-fleet-home") || {}).value || "";
      S.settings = await inv("settings_set", {
        settings: {
          ...S.settings,
          lang,
          port: Number.isFinite(port) ? port : S.settings.port,
          quotaInterval: Number.isFinite(quotaInterval) ? quotaInterval : S.settings.quotaInterval,
          fleetHome,
        },
      });
      S.lang = lang;
      toast(t("done"));
      await A.refreshStatus();
    });
  },

  setStrategy(value) {
    run("routing", async () => {
      S.routing = await inv("set_routing_strategy", { strategy: value });
      if (S.routing.accounts) S.accounts = S.routing.accounts;
      toast(t("done"));
    });
  },

  movePriority(id, up) {
    run("order", async () => {
      S.routing = await inv("move_priority", { id, up });
      if (S.routing.accounts) S.accounts = S.routing.accounts;
      // Moving a card is what the manual order is: the planner follows the
      // list only in custom mode, and the switch happens silently otherwise.
      toast(t("orderCustom"));
    });
  },

  resetOrder() {
    run("order", async () => {
      S.routing = await inv("reset_priority");
      if (S.routing.accounts) S.accounts = S.routing.accounts;
      toast(t("done"));
    });
  },

  setRole(id, preferred, backup) {
    run("role-" + id, async () => {
      S.routing = await inv("set_account_role", { id, preferred, backup });
      if (S.routing.accounts) S.accounts = S.routing.accounts;
    });
  },

  deviceStart() {
    run("device", async () => {
      const session = await inv("device_login_start");
      S.deviceLogin = { ...session, done: false };
      A.deviceOpen();
      const interval = Math.max(3, session.interval || 5) * 1000;
      clearInterval(A._deviceTimer);
      A._deviceTimer = setInterval(async () => {
        try {
          const result = await inv("device_login_poll", {
            deviceAuthId: session.deviceAuthId,
            userCode: session.userCode,
          });
          if (result.done) {
            clearInterval(A._deviceTimer);
            S.accounts = result.accounts;
            S.deviceLogin = null;
            toast(`${t("addAccount")}: ${result.result}`);
            render();
          }
        } catch (error) {
          clearInterval(A._deviceTimer);
          toast(String(error), true);
        }
      }, interval);
    });
  },

  deviceOpen() {
    if (S.deviceLogin && S.deviceLogin.verificationURL) {
      inv("open_url", { url: S.deviceLogin.verificationURL }).catch(() => {});
    }
  },

  modelsLoad() {
    run("models", async () => {
      const rawModels = (await inv("gateway_models")) || [];
      // Dedupe the gateway list by id first; the provider lists below reuse the
      // same set so a model served by two sources renders once.
      const models = [];
      const seen = new Set();
      for (const model of rawModels) {
        const id = String((model && model.id) || "");
        if (seen.has(id)) continue;
        seen.add(id);
        models.push(model);
      }
      // Claude ids are served by the gateway too, but a direct fetch keeps the
      // list fresh right after a login, before the next gateway sync.
      try {
        const claude = await inv("claude_models");
        for (const model of (claude && claude.models) || []) {
          const id = String(model.id);
          if (!seen.has(id)) {
            seen.add(id);
            models.push({ id: model.id, owned_by: "claude", displayName: model.displayName });
          }
        }
      } catch (error) {
        // Gateway down or no Claude account — the base list stays valid.
      }
      // Antigravity ids drive the row tag by membership (not by prefix), since
      // it overlaps the claude-*/gemini-*/gpt-oss id space.
      try {
        const ag = await inv("antigravity_models");
        const ids = new Set();
        for (const model of (ag && ag.models) || []) {
          const id = String(model.id);
          ids.add(id);
          if (!seen.has(id)) {
            seen.add(id);
            models.push({ id, owned_by: "antigravity", displayName: model.displayName });
          }
        }
        S.antigravityIds = ids;
      } catch (error) {
        // Gateway down or no Antigravity account — the base list stays valid.
      }
      S.models = models;
    });
  },

  modelsSearch(value) {
    S.modelsQuery = value;
    render();
    setTimeout(() => {
      const input = document.getElementById("models-search");
      if (input) {
        input.focus();
        input.setSelectionRange(input.value.length, input.value.length);
      }
    }, 0);
  },

  instancesLoad() {
    run("instances", async () => {
      S.instancesData = await inv("instances_list");
    });
  },

  instanceCreate() {
    const input = document.getElementById("instance-name");
    const name = input ? input.value.trim() : "";
    if (!name) return;
    run("instance-create", async () => {
      S.instancesData = await inv("instance_create", { name });
      toast(t("done"));
    });
  },

  async instanceDelete(id) {
    // The confirmation must name the instance, like account deletion.
    const instance = (S.instancesData || []).find((item) => item.id === id);
    const name = (instance && instance.name) || id;
    if (!window.confirm(fmt(t("confirmDeleteInstance"), { name }))) return;
    run("instance-delete", async () => {
      S.instancesData = await inv("instance_delete", { id });
    });
  },

  instanceBind(id, accountId) {
    run("instance-bind", async () => {
      S.instancesData = await inv("instance_bind", { id, accountId: accountId || null });
    });
  },

  instanceLaunch(id) {
    run("instance-launch", async () => {
      const home = await inv("instance_launch", { id });
      toast(`${t("instanceLaunch")}: ${home}`);
    });
  },

  fleetLoad() {
    run("fleet", async () => {
      S.fleet = await inv("fleet_status");
      if (S.fleetTab === "results") {
        S.fleet.results = await inv("fleet_results", { limit: 100 });
      }
      if (S.fleetTab === "config") {
        S.fleetConfig = await inv("fleet_config_get");
      }
    });
  },

  fleetTabSet(tab) {
    S.fleetTab = tab;
    S.fleetResult = null;
    S.fleetOutput = null;
    A.fleetLoad();
    render();
  },

  fleetOpenResult(path) {
    run("fleet-result", async () => {
      S.fleetResult = await inv("fleet_read_result", { path });
    });
  },

  fleetSaveConfig() {
    const area = document.getElementById("fleet-config");
    if (!area) return;
    run("fleet-config", async () => {
      S.fleetConfig = await inv("fleet_config_set", { text: area.value });
      toast(t("done"));
    });
  },

  fleetRun(args) {
    run("fleet-run", async () => {
      S.fleetOutput = await inv("fleet_cli", { args });
    });
  },

  autostartToggle(enabled) {
    run("autostart", async () => {
      S.autostart = await inv("autostart_set", { enabled });
      toast(t("done"));
    });
  },

  notifyToggle(enabled) {
    run("notify", async () => {
      S.settings = await inv("settings_set", {
        settings: { ...S.settings, notifyLowQuota: enabled },
      });
    });
  },

  // MARK: Updater

  /// Two states of the sidebar control: quiet «Проверить обновление», and the
  /// gold CTA «Обновить» as soon as a newer release is known.
  updateButton() {
    const button = document.getElementById("update-btn");
    const label = document.getElementById("update-label");
    if (!button || !label) return;
    const newer = !!(S.update && S.update.newer);
    button.classList.toggle("primary", newer);
    label.textContent = newer ? t("update") : t("updateCheck");
  },

  async updateOpen() {
    const modal = document.getElementById("update-modal");
    const title = document.getElementById("update-title");
    const sub = document.getElementById("update-sub");
    const notes = document.getElementById("update-notes");
    const apply = document.getElementById("update-apply");
    const cancel = document.getElementById("update-cancel");
    modal.hidden = false;
    A._updateApplying = false;
    if (cancel) cancel.disabled = false;
    title.textContent = t("updateChecking");
    sub.textContent = "";
    notes.textContent = "";
    notes.style.display = "none";
    apply.style.display = "none";
    try {
      const result = await inv("update_check", { force: true });
      S.update = result;
      if (result.newer) {
        title.textContent = fmt(t("updateAvailable"), { v: result.version });
        sub.textContent = `${(S.info && S.info.version) || ""} → ${result.version}`;
        notes.textContent = result.notes || "";
        notes.style.display = "block";
        apply.style.display = "";
      } else {
        title.textContent = fmt(t("updateUpToDate"), { v: result.version });
      }
      A.updateButton();
    } catch (error) {
      title.textContent = t("updateFailed");
      sub.textContent = String(error && error.message ? error.message : error);
    }
  },

  updateClose() {
    // While the swap runs the window must not be able to hide.
    if (A._updateApplying) return;
    const modal = document.getElementById("update-modal");
    if (modal) modal.hidden = true;
  },

  async updateApply() {
    if (!S.update || !S.update.newer) return;
    const sub = document.getElementById("update-sub");
    const apply = document.getElementById("update-apply");
    const cancel = document.getElementById("update-cancel");
    // Cancel disappears as soon as applying starts; it comes back only if
    // the swap fails and the window stays.
    A._updateApplying = true;
    if (cancel) cancel.disabled = true;
    apply.style.display = "none";
    sub.textContent = t("updateDownloading");
    try {
      await inv("update_apply", { url: S.update.assetURL, digest: S.update.digest });
      sub.textContent = t("updateInstalling");
    } catch (error) {
      sub.textContent = String(error && error.message ? error.message : error);
      A._updateApplying = false;
      if (cancel) cancel.disabled = false;
      apply.style.display = "";
    }
  },
};

window.A = A;

// MARK: - Edit tracking (M3)

// Typing marks the current field dirty so the periodic refreshStatus does
// not re-render the page under the user's hands.
function markFieldDirty(event) {
  if (!isFormField(event.target)) return;
  S.dirtyInput = true;
  S.dirtyField = event.target;
}
document.addEventListener("input", markFieldDirty, true);
document.addEventListener("change", markFieldDirty, true);

// Focus left every field: the deferred full update runs now instead of
// waiting for the next 5 s tick.
document.addEventListener("focusout", (event) => {
  if (isFormField(event.relatedTarget)) return; // moved to another field
  S.dirtyInput = false;
  S.dirtyField = null;
  if (!S.renderDeferred) return;
  S.renderDeferred = false;
  clearTimeout(S._renderResumeTimer);
  // Small delay so a click (mousedown → focusout → mouseup → click) lands on
  // the current DOM before it is re-rendered.
  S._renderResumeTimer = setTimeout(() => A.refreshStatus(), 350);
}, true);

// MARK: - Onboarding

// The modal is injected here instead of index.html so the web UI stays one
// script plus one stylesheet. The flag is written on any dismissal, so the
// tour is shown exactly once per webview profile.
const ONBOARDING_KEY = "onboardingDone";

function onboardingSeen() {
  try {
    return window.localStorage.getItem(ONBOARDING_KEY) === "1";
  } catch {
    // Storage unavailable (hardened webview): never block the app on a tour.
    return true;
  }
}

function markOnboardingSeen() {
  try {
    window.localStorage.setItem(ONBOARDING_KEY, "1");
  } catch {
    // Same as above — the UI keeps working when storage is unavailable.
  }
}

function showOnboarding() {
  if (onboardingSeen()) return;
  let modal = document.getElementById("onboarding-modal");
  if (!modal) {
    modal = document.createElement("div");
    modal.id = "onboarding-modal";
    modal.className = "modal";
    document.body.appendChild(modal);
  }
  const steps = [
    ["1", "onboardingStep1"],
    ["2", "onboardingStep2"],
    ["3", "onboardingStep3"],
  ];
  modal.innerHTML = `
    <div class="modal-card" role="dialog" aria-modal="true" aria-labelledby="onboarding-title">
      <div class="kicker">melon tools</div>
      <h2 id="onboarding-title">${esc(t("onboardingTitle"))}</h2>
      <div class="subtitle">${esc(t("onboardingWelcome"))}</div>
      <div class="stack" style="margin:14px 0">
        ${steps.map(([number, key]) => `<div class="row" style="align-items:flex-start;gap:10px">
          <span class="pill gold">${number}</span>
          <span>${esc(t(key))}</span>
        </div>`).join("")}
      </div>
      <div class="footnote" style="color:var(--warn);border-top:1px solid var(--border);padding-top:10px">
        ${esc(t("onboardingDisclaimer"))}
      </div>
      <div class="row" style="justify-content:flex-end;margin-top:16px">
        <button class="ghost small" onclick="A.onboardingGo('accounts')">${esc(t("onboardingAccounts"))}</button>
        <button class="ghost small" onclick="A.onboardingGo('providers')">${esc(t("onboardingProviders"))}</button>
        <button class="btn small" onclick="A.onboardingDone()">${esc(t("onboardingDone"))}</button>
      </div>
    </div>`;
  modal.hidden = false;
}

// MARK: - Boot

(async function boot() {
  await A.loadAll();
  showOnboarding();
  // Daily update check: lights the badge only; the window opens on click.
  if (IS_TAURI) {
    inv("update_check", { force: false })
      .then((result) => {
        if (result && !result.skipped) {
          S.update = result;
          A.updateButton();
        }
      })
      .catch(() => {});
  }
  setInterval(() => A.refreshStatus(), 5000);
  // Adaptive quota refresh: the configured interval when idle, ~30 s while
  // the gateway is actually serving — a fixed cadence lets accounts burn
  // through a small reserve between checks.
  setInterval(() => {
    if (!IS_TAURI) return;
    const now = Date.now();
    const interval = ((S.settings && S.settings.quotaInterval) || 300) * 1000;
    const since = now - (S.lastQuotaRefreshAt || 0);
    const underLoad = !!(S.status && S.status.requestsLastMinute > 0);
    if (since >= interval || (underLoad && since >= 30000)) {
      A.refreshQuotas();
    }
    // Claude usage: same configured cadence, floored at 180 s per the spec.
    const claudeDue = now - (S.lastClaudeUsageAt || 0) >= Math.max(180000, interval);
    if (claudeDue && !S.claudeLogin && (S.claude ? S.claude.connected : !!(S.settings && S.settings.claudeEnabled))) {
      A.claudeUsageLoad().then(() => {
        if (S.section === "providers" && !S.claudeLogin) render();
      }).catch(() => {});
    }
    // Antigravity metrics: same ≥180 s cadence. Polling is harmless when the
    // engine exposes nothing (connected:false), so no settings gate.
    const agDue = now - (S.lastAntigravityAt || 0) >= Math.max(180000, interval);
    if (agDue && !S.antigravityLogin) {
      A.antigravityUsageLoad().then(() => {
        if (S.section === "providers" && !S.antigravityLogin) render();
      }).catch(() => {});
    }
  }, 30000);
  if (S.section === "providers" && IS_TAURI) {
    A.openrouterRefresh();
  }
})();
