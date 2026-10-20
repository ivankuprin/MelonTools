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
    poolPauseHourly: "Все аккаунты на паузе по часовому резерву — сброс в {time}",
    poolPauseWeekly: "Все аккаунты на паузе по недельному резерву — сброс в {time}",
    poolPauseMixed: "Все аккаунты на паузе — ближайший сброс в {time}",
    poolPauseExhausted: "Квота исчерпана — сброс в {time}",
    poolPauseLift: "Снять паузу",
    poolPauseConfirm: "Снять паузу по резерву? Квота может опуститься до 0%.",
    quotaAge: "квота обновлена", never: "никогда", stale: "устарела",
    history: "История", historyHint: "Остаток квоты по последним обновлениям.",
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
    scheduler: "Планировщик", schedulerSub: "Задачи по расписанию: cron, интервалы и шаблоны. Работают, пока Melon Tools в трее.",
    schedulerAdd: "Добавить задачу", schedulerAddTitle: "Новая задача", schedulerEditTitle: "Изменить задачу",
    schedulerName: "Название", schedulerPrompt: "Запрос", schedulerModel: "Модель", schedulerEffort: "Reasoning effort",
    schedulerEffortDefault: "по умолчанию", schedulerInterval: "Интервал, мин", schedulerEnabled: "Включена",
    schedulerRunNow: "Выполнить сейчас", schedulerNext: "Следующий запуск", schedulerLast: "Последний запуск",
    schedulerStatus: "Статус", schedulerResult: "Результат", schedulerNoResult: "Результатов пока нет",
    schedulerEmpty: "Задач пока нет — добавьте первую.", schedulerDelete: "Удалить", schedulerEdit: "Изменить",
    schedulerRequired: "Заполните название, запрос и модель", confirmDeleteTask: "Удалить задачу {name}?",
    schedulerEvery: "каждые {n} мин", schedulerDue: "вот-вот", schedulerRunning: "выполняется…",
    schedulerOk: "успех", schedulerError: "ошибка", schedulerNever: "не запускалась",
    schedulerHistory: "История", schedulerFile: "Файл", schedulerClose: "Закрыть",
    schedulerModelHint: "Модели шлюза из /v1/models.", schedulerModelsFailed: "Список моделей недоступен — запустите шлюз и обновите.",
    schedulerGatewayOff: "Шлюз не отвечает — выполнять задачи некуда. Запустите API-сервис и повторите.",
    schedulerTokens: "токены", schedulerDuration: "время", schedulerMinutesShort: "{n} мин",
    schedulerTemplate: "Шаблон", schedulerTemplateNone: "Без шаблона", schedulerFromTemplate: "Из шаблона",
    schedulerScheduleType: "Тип расписания", schedulerScheduleInterval: "Интервал", schedulerScheduleCron: "Cron",
    schedulerCron: "Cron-выражение", schedulerCronHint: "Минута час день месяц день недели",
    schedulerCronExamples: "*/15 * * * * · 0 9 * * 1-5 · 0 */6 * * * · 0 0 1 * *",
    schedulerCronInvalid: "Проверьте cron-выражение: нужно 5 полей", schedulerTimeZone: "Часовой пояс",
    schedulerZoneSystem: "Системный", schedulerVariables: "Переменные",
    schedulerVariableRequired: "Заполните переменные шаблона", schedulerTrayHint: "Закройте окно — Melon Tools останется в трее и продолжит выполнять задачи.",
    schedulerRepo: "Репозиторий", schedulerBranch: "Ветка", schedulerPath: "Путь",
    schedulerTplMorning: "Утренняя сводка", schedulerTplMorningDesc: "Свежие изменения и открытые задачи каждое утро в будни.",
    schedulerTplPR: "Проверка PR", schedulerTplPRDesc: "Открытые PR, проверки и рискованные изменения перед концом рабочего дня.",
    schedulerTplWeekly: "Недельная сводка репозитория", schedulerTplWeeklyDesc: "Слитые изменения, активные ветки и риски за неделю.",
    schedulerTplLogs: "Проверка логов", schedulerTplLogsDesc: "Поиск ошибок и предупреждений в свежих логах каждые шесть часов.",
    schedulerTplSpend: "Отчёт о расходе за день", schedulerTplSpendDesc: "Расход токенов, дорогие модели и необычные всплески за день.",
    sgGateway: "Шлюз", sgClaude: "Claude", sgOpenCode: "OpenCode", sgOpenRouter: "OpenRouter", cancel: "Отмена",
    instances: "Инстансы", instanceNew: "Имя нового инстанса", instanceCreate: "Создать", instanceLaunch: "Запустить Codex",
    instanceBind: "Аккаунт", instanceNone: "текущий логин", instanceDelete: "Удалить", instanceHint: "Отдельный CODEX_HOME со своим входом.",
    composer: "Композер", composerHint: "Чипы в композере Codex: аккаунты и квоты прямо в строке ввода.",
    models: "Модели", modelsSearch: "Поиск модели…", modelsCount: "моделей", sources: "Источники", sourceEnabled: "включён",
    autostart: "Автозапуск с Windows", session: "Сессия",
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
    onboardingClose: "Закрыть",
    diagTitle: "Проверка подключений", diagHint: "только чтение", diagRun: "Проверить подключения",
    diagIdle: "Проверка ещё не запускалась.", diagAt: "проверено", diagProvider: "Провайдер",
    diagAuth: "Авторизация", diagQuota: "Последняя квота", diagCodex: "Аккаунты Codex",
    diagKeySet: "ключ есть", diagKeyMissing: "ключа нет", diagUp: "доступен", diagDown: "недоступен", diagApiOk: "API ok",
    notifications: "Уведомления", notifyLowQuota: "Низкая квота", notifyScheduler: "Запуски планировщика", notifyQuotaReset: "Сброс квоты",
    notificationsHint: "Главный переключатель уведомлений; ниже — отдельные категории.",
    dashCards: "Карточки дашборда", dashCardPool: "Здоровье пула", dashCardTrends: "Тренды квот", dashCardSpend: "Расход", dashCardScheduler: "Планировщик",
    dashPoolHealth: "Здоровье пула", dashUsable: "Рабочие", dashPaused: "На паузе", dashErrors: "С ошибкой",
    dashAvgFive: "Средний 5ч", dashAvgWeek: "Средняя неделя",
    dashQuotaTrends: "Тренды квот", dashLast24h: "24 часа · по часам", dashLast7d: "7 дней · по дням",
    dashTrendEmpty: "Данных пока нет", dashTrendHint: "Средний остаток по всем аккаунтам и провайдерам.",
    dashSamples: "точек", dashAvg: "среднее",
    dashSpend: "Расход и провайдеры", dashSessionSpend: "Расход сессии", dashSessionTokens: "Токены сессии",
    dashTopProviders: "Топ-3 провайдера по токенам", dashProvider: "Провайдер", dashTokens: "Токены", dashTurns: "Ходы", dashSpendShort: "Расход",
    dashNoUsage: "Нет данных об использовании — выполните задачу в планировщике.",
    dashScheduler: "Планировщик", dashDue: "Готовы к запуску", dashNextRun: "Следующий запуск", dashLastRun: "Последний статус",
    dashRunNext: "Запустить следующую", dashOpenScheduler: "Открыть планировщик", dashNoTasks: "Нет включённых задач.",
    dashRunNextDone: "Запущено: {name}",
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
    poolPauseHourly: "All accounts are paused by the hourly reserve — resets at {time}",
    poolPauseWeekly: "All accounts are paused by the weekly reserve — resets at {time}",
    poolPauseMixed: "All accounts are paused — nearest reset at {time}",
    poolPauseExhausted: "Quota exhausted — resets at {time}",
    poolPauseLift: "Lift pause",
    poolPauseConfirm: "Lift the reserve pause? Quota may drop to 0%.",
    quotaAge: "quota updated", never: "never", stale: "stale",
    history: "History", historyHint: "Quota remaining across recent refreshes.",
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
    scheduler: "Scheduler", schedulerSub: "Scheduled tasks: cron, intervals and templates. They run while Melon Tools is in the tray.",
    schedulerAdd: "Add task", schedulerAddTitle: "New task", schedulerEditTitle: "Edit task",
    schedulerName: "Name", schedulerPrompt: "Prompt", schedulerModel: "Model", schedulerEffort: "Reasoning effort",
    schedulerEffortDefault: "default", schedulerInterval: "Interval, min", schedulerEnabled: "Enabled",
    schedulerRunNow: "Run now", schedulerNext: "Next run", schedulerLast: "Last run",
    schedulerStatus: "Status", schedulerResult: "Result", schedulerNoResult: "No results yet",
    schedulerEmpty: "No tasks yet — add the first one.", schedulerDelete: "Delete", schedulerEdit: "Edit",
    schedulerRequired: "Fill in the name, prompt and model", confirmDeleteTask: "Delete task {name}?",
    schedulerEvery: "every {n} min", schedulerDue: "due", schedulerRunning: "running…",
    schedulerOk: "ok", schedulerError: "error", schedulerNever: "never ran",
    schedulerHistory: "History", schedulerFile: "File", schedulerClose: "Close",
    schedulerModelHint: "Gateway models from /v1/models.", schedulerModelsFailed: "Model list unavailable — start the gateway and refresh.",
    schedulerGatewayOff: "The gateway is not reachable — there is nowhere to run tasks. Start the API service and retry.",
    schedulerTokens: "tokens", schedulerDuration: "time", schedulerMinutesShort: "{n} min",
    schedulerTemplate: "Template", schedulerTemplateNone: "No template", schedulerFromTemplate: "From template",
    schedulerScheduleType: "Schedule type", schedulerScheduleInterval: "Interval", schedulerScheduleCron: "Cron",
    schedulerCron: "Cron expression", schedulerCronHint: "Minute hour day month weekday",
    schedulerCronExamples: "*/15 * * * * · 0 9 * * 1-5 · 0 */6 * * * · 0 0 1 * *",
    schedulerCronInvalid: "Check the cron expression: 5 fields are required", schedulerTimeZone: "Time zone",
    schedulerZoneSystem: "System", schedulerVariables: "Variables",
    schedulerVariableRequired: "Fill in the template variables", schedulerTrayHint: "Close the window — Melon Tools stays in the tray and keeps running tasks.",
    schedulerRepo: "Repository", schedulerBranch: "Branch", schedulerPath: "Path",
    schedulerTplMorning: "Morning digest", schedulerTplMorningDesc: "Recent changes and open work, every weekday morning.",
    schedulerTplPR: "PR review", schedulerTplPRDesc: "Open pull requests, checks and risky changes before the end of the workday.",
    schedulerTplWeekly: "Weekly repo summary", schedulerTplWeeklyDesc: "Merged work, active branches and open risks for the week.",
    schedulerTplLogs: "Log check", schedulerTplLogsDesc: "Scan recent logs for errors and warnings every six hours.",
    schedulerTplSpend: "Daily spend report", schedulerTplSpendDesc: "Token spend, expensive models and unusual spikes for the day.",
    sgGateway: "Gateway", sgClaude: "Claude", sgOpenCode: "OpenCode", sgOpenRouter: "OpenRouter", cancel: "Cancel",
    instances: "Instances", instanceNew: "New instance name", instanceCreate: "Create", instanceLaunch: "Launch Codex",
    instanceBind: "Account", instanceNone: "current login", instanceDelete: "Delete", instanceHint: "A separate CODEX_HOME with its own login.",
    composer: "Composer", composerHint: "Chips in the Codex composer: accounts and quotas right in the input row.",
    models: "Models", modelsSearch: "Search models…", modelsCount: "models", sources: "Sources", sourceEnabled: "enabled",
    autostart: "Start with Windows", session: "Session",
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
    onboardingClose: "Close",
    diagTitle: "Connection check", diagHint: "read-only", diagRun: "Check connections",
    diagIdle: "The check has not run yet.", diagAt: "checked", diagProvider: "Provider",
    diagAuth: "Auth", diagQuota: "Last quota", diagCodex: "Codex accounts",
    diagKeySet: "key set", diagKeyMissing: "no key", diagUp: "up", diagDown: "down", diagApiOk: "API ok",
    notifications: "Notifications", notifyLowQuota: "Low quota", notifyScheduler: "Scheduler runs", notifyQuotaReset: "Quota reset",
    notificationsHint: "Master notification switch; individual categories below.",
    dashCards: "Dashboard cards", dashCardPool: "Pool health", dashCardTrends: "Quota trends", dashCardSpend: "Spend", dashCardScheduler: "Scheduler",
    dashPoolHealth: "Pool health", dashUsable: "Usable", dashPaused: "Paused", dashErrors: "Errors",
    dashAvgFive: "Avg 5h", dashAvgWeek: "Avg week",
    dashQuotaTrends: "Quota trends", dashLast24h: "24 hours · hourly", dashLast7d: "7 days · daily",
    dashTrendEmpty: "No data yet", dashTrendHint: "Average remaining across all accounts and providers.",
    dashSamples: "samples", dashAvg: "avg",
    dashSpend: "Spend & providers", dashSessionSpend: "Session spend", dashSessionTokens: "Session tokens",
    dashTopProviders: "Top 3 providers by tokens", dashProvider: "Provider", dashTokens: "Tokens", dashTurns: "Turns", dashSpendShort: "Spend",
    dashNoUsage: "No usage data — run a scheduler task.",
    dashScheduler: "Scheduler", dashDue: "Due", dashNextRun: "Next run", dashLastRun: "Last status",
    dashRunNext: "Run next", dashOpenScheduler: "Open scheduler", dashNoTasks: "No enabled tasks.",
    dashRunNextDone: "Started: {name}",
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
  scheduler: null,
  schedulerAt: 0,
  schedulerError: null,
  schedulerForm: null,
  schedulerModels: null,
  schedulerModelsError: null,
  schedulerOpen: null,
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
    settings_get: { port: 18317, apiKey: "", lang: S.lang, quotaInterval: 300, openrouterKey: "", opencodeKey: "", claudeEnabled: false, claudeApiKey: "", notifications: true, notifyLowQuota: true, notifyScheduler: true, notifyQuotaReset: true, dashboardShowPoolHealth: true, dashboardShowQuotaTrends: true, dashboardShowSpend: true, dashboardShowScheduler: true, quotaResetNotified: [] },
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
    bridge_status: { attached: true, debugPort: 55660, model: "GPT-6.1 Sol", targets: 3, reason: null, session: { total: { total: 2730 }, cost: { total: 0.42, providers: { openai: { usd: 0.32 }, opencode: { usd: 0.10 } } } } },
    routing_state: { strategy: "auto", strategies: ["auto", "quotaHighFirst", "quotaLowFirst", "planHighFirst", "planLowFirst", "expirySoonFirst", "custom"], priorityOrder: [], orderedIds: ["demo-1", "demo-2"], blockedIds: ["demo-2"] },
    set_routing_strategy: (a) => ({ strategy: a.strategy, orderedIds: ["demo-1", "demo-2"], blockedIds: ["demo-2"], accounts: demoAccounts }),
    move_priority: { strategy: "custom", orderedIds: ["demo-2", "demo-1"], blockedIds: [], accounts: demoAccounts },
    reset_priority: { strategy: "auto", orderedIds: ["demo-1", "demo-2"], blockedIds: [], accounts: demoAccounts },
    set_account_role: { strategy: "auto", orderedIds: ["demo-1", "demo-2"], blockedIds: [], accounts: demoAccounts },
    device_login_start: { deviceAuthId: "demo", userCode: "AB12-CD34", interval: 30, verificationURL: "https://auth.openai.com/codex/device" },
    device_login_poll: { done: false },
    gateway_models: [{ id: "gpt-6.1-sol", owned_by: "openai" }, { id: "opencode/grok-4.7", owned_by: "opencode-go" }],
    gateway_recent_calls: [{ time: "19:19:41", status: "200", duration: "9.743s", method: "POST", path: "/v1/responses" }],
    scheduler_list: () => demoScheduler(),
    scheduler_save: (a) => {
      const demo = demoScheduler();
      const input = (a && a.task) || {};
      const now = nowSec;
      const task = {
        id: input.id || "demo-task-" + (demo.tasks.length + 1),
        name: input.name || "",
        prompt: input.prompt || "",
        model: input.model || "",
        reasoningEffort: input.reasoningEffort || null,
        scheduleKind: input.scheduleKind === "cron" ? "cron" : "interval",
        cronExpression: input.cronExpression || null,
        timeZone: input.timeZone || null,
        intervalMinutes: input.intervalMinutes || 60,
        enabled: input.enabled !== false,
        createdAt: now,
        nextRunAt: input.enabled === false ? null : now + (input.intervalMinutes || 60) * 60,
        lastRunAt: null, lastStatus: "never", lastError: null, lastResult: "", lastDurationMs: null, lastTokens: null,
      };
      const index = demo.tasks.findIndex((item) => item.id === task.id);
      if (index >= 0) demo.tasks[index] = { ...demo.tasks[index], ...task, createdAt: demo.tasks[index].createdAt };
      else demo.tasks.push(task);
      return demo;
    },
    scheduler_delete: (a) => {
      const demo = demoScheduler();
      demo.tasks = demo.tasks.filter((task) => task.id !== (a && a.id));
      demo.history = demo.history.filter((entry) => entry.taskId !== (a && a.id));
      return demo;
    },
    scheduler_run_now: () => demoScheduler(),
    scheduler_models: { count: 3, ids: ["gpt-6.1-sol", "claude-opus-5-5", "opencode/grok-4.7"], groups: [
      { id: "gateway", ids: ["gpt-6.1-sol"] },
      { id: "claude", ids: ["claude-opus-5-5"] },
      { id: "opencode", ids: ["opencode/grok-4.7"] },
    ] },
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

// Browser preview only: a mutable scheduler demo so the page actions work
// without Tauri (the real app answers from the Rust scheduler).
let DEMO_SCHEDULER = null;
function demoScheduler() {
  if (!DEMO_SCHEDULER) {
    const now = Date.now() / 1000;
    const task = {
      id: "demo-task-1", name: "Ночной отчёт", prompt: "Собери отчёт по изменениям за сутки.",
      model: "gpt-6.1-sol", reasoningEffort: null,
      scheduleKind: "cron", cronExpression: "0 9 * * 1-5", timeZone: null,
      intervalMinutes: 60, enabled: true,
      createdAt: now - 7200, nextRunAt: now + 1800, lastRunAt: now - 1800,
      lastStatus: "ok", lastError: null, lastResult: "Отчёт готов: 3 изменения, 2 предупреждения.",
      lastDurationMs: 4200, lastTokens: 1530,
    };
    DEMO_SCHEDULER = {
      path: "C:\\Users\\you\\AppData\\Roaming\\MelonTools\\scheduler.json",
      tasks: [task],
      history: [
        { taskId: task.id, at: now - 1800, status: "ok", model: task.model, durationMs: 4200, tokens: 1530, result: task.lastResult, error: null },
        { taskId: task.id, at: now - 3600, status: "ok", model: "opencode/grok-4.7", durationMs: 3100, tokens: 820, result: "ok", error: null },
        { taskId: task.id, at: now - 5400, status: "ok", model: "claude-opus-5-5", durationMs: 2800, tokens: 380, result: "ok", error: null },
      ],
    };
  }
  return DEMO_SCHEDULER;
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

// MARK: - Dashboard 2.0 helpers

const HOUR_SECONDS = 3600;
const DAY_SECONDS = 86400;
const DASHBOARD_CARD_SETTINGS = [
  "dashboardShowPoolHealth",
  "dashboardShowQuotaTrends",
  "dashboardShowSpend",
  "dashboardShowScheduler",
];

function finiteNumber(value) {
  if (value === null || value === undefined || value === "") return null;
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function formatTokens(value) {
  const number = finiteNumber(value);
  if (number === null) return "—";
  return Math.round(number).toLocaleString(S.lang === "en" ? "en-US" : "ru-RU");
}

function formatMoney(value) {
  const number = finiteNumber(value);
  return number === null ? "—" : `$${number.toFixed(2)}`;
}

// Counts partition the pool: an account with a quota error is "error" even if
// it also carries a block reason. Averages use only numeric readings.
function poolHealth(accounts, routing) {
  const list = Array.isArray(accounts) ? accounts : [];
  const blockedIds = new Set(((routing && routing.blockedIds) || []).map(String));
  let usable = 0;
  let paused = 0;
  let errors = 0;
  let hourlySum = 0;
  let hourlyCount = 0;
  let weeklySum = 0;
  let weeklyCount = 0;
  for (const account of list) {
    if (!account) continue;
    if (account.quotaError || account.needsRelogin) errors += 1;
    else if (account.blocked || account.blockInfo || blockedIds.has(String(account.id))) paused += 1;
    else usable += 1;
    const hourly = finiteNumber(account.hourlyRemaining);
    if (hourly !== null) { hourlySum += hourly; hourlyCount += 1; }
    const weekly = finiteNumber(account.weeklyRemaining);
    if (weekly !== null) { weeklySum += weekly; weeklyCount += 1; }
  }
  return {
    total: list.length,
    usable,
    paused,
    errors,
    averageHourly: hourlyCount ? hourlySum / hourlyCount : null,
    averageWeekly: weeklyCount ? weeklySum / weeklyCount : null,
  };
}

// One series of bucket means. `field` is hourlyLeft or weeklyLeft; samples
// outside the window are ignored instead of being clamped into an edge slot.
function quotaTrend(history, field, windowSeconds, bucketSeconds, nowSeconds) {
  const buckets = Math.max(1, Math.round(windowSeconds / bucketSeconds));
  const sums = new Array(buckets).fill(0);
  const counts = new Array(buckets).fill(0);
  const cutoff = nowSeconds - windowSeconds;
  for (const sample of Array.isArray(history) ? history : []) {
    const timestamp = finiteNumber(sample && sample.timestamp);
    const value = finiteNumber(sample && sample[field]);
    if (timestamp === null || value === null) continue;
    if (timestamp < cutoff || timestamp > nowSeconds + bucketSeconds) continue;
    const index = Math.min(buckets - 1, Math.max(0, Math.floor((timestamp - cutoff) / bucketSeconds)));
    sums[index] += value;
    counts[index] += 1;
  }
  const points = [];
  let total = 0;
  let totalCount = 0;
  for (let index = 0; index < buckets; index += 1) {
    if (!counts[index]) continue;
    const value = sums[index] / counts[index];
    points.push({ index, value });
    total += sums[index];
    totalCount += counts[index];
  }
  return {
    points,
    buckets,
    average: totalCount ? total / totalCount : null,
    latest: points.length ? points[points.length - 1].value : null,
    count: totalCount,
  };
}

function quotaTrends(history, nowSeconds) {
  const now = finiteNumber(nowSeconds) ?? nowRef();
  return {
    hourly: quotaTrend(history, "hourlyLeft", 24 * HOUR_SECONDS, HOUR_SECONDS, now),
    weekly: quotaTrend(history, "weeklyLeft", 7 * DAY_SECONDS, DAY_SECONDS, now),
  };
}

function trendChart(trend, label) {
  if (!trend || !trend.points.length) {
    return `<div class="trend"><div class="trend-head"><span>${esc(label)}</span><span class="val">—</span></div>
      <div class="trend-empty">${esc(t("dashTrendEmpty"))}</div></div>`;
  }
  const points = trend.points.map((point) => {
    const x = trend.buckets <= 1 ? 50 : (point.index / (trend.buckets - 1)) * 100;
    const y = 30 - (Math.max(0, Math.min(100, point.value)) / 100) * 28;
    return `${x.toFixed(1)},${y.toFixed(1)}`;
  }).join(" ");
  const latest = trend.latest === null ? "—" : `${Math.round(trend.latest)}%`;
  const average = trend.average === null ? "—" : `${Math.round(trend.average)}%`;
  return `<div class="trend" title="${esc(t("dashTrendHint"))}">
    <div class="trend-head"><span>${esc(label)}</span><span class="val">${latest}</span></div>
    <svg class="trend-svg" viewBox="0 0 100 32" preserveAspectRatio="none" role="img" aria-label="${esc(label)}">
      <line x1="0" y1="16" x2="100" y2="16" class="trend-grid"></line>
      <polyline points="${points}"></polyline>
    </svg>
    <div class="trend-foot"><span>${trend.count} ${esc(t("dashSamples"))}</span><span>${esc(t("dashAvg"))}: ${average}</span></div>
  </div>`;
}

function providerOfModel(model) {
  const id = String(model || "");
  if (id.startsWith("opencode/")) return "opencode";
  if (id.startsWith("openrouter/")) return "openrouter";
  if (id.startsWith("claude-")) return "claude";
  return "gateway";
}

function providerName(provider) {
  switch (provider) {
    case "gateway": return t("sgGateway");
    case "claude": return t("sgClaude");
    case "opencode": return t("sgOpenCode");
    case "openrouter": return t("sgOpenRouter");
    default: return String(provider || "—");
  }
}

// Windows has no provider price table: the scheduler history contributes
// tokens/turns, the optional bridge session contributes priced spend. A row
// without a USD value renders "—" instead of a fabricated number.
function usageSummary(scheduler, bridge) {
  const rows = new Map();
  const rowFor = (provider) => {
    if (!rows.has(provider)) rows.set(provider, { provider, tokens: 0, usd: null, priced: false, turns: 0 });
    return rows.get(provider);
  };
  for (const entry of (scheduler && scheduler.history) || []) {
    if (!entry) continue;
    const row = rowFor(providerOfModel(entry.model));
    const tokens = finiteNumber(entry.tokens);
    if (tokens !== null) row.tokens += tokens;
    row.turns += 1;
    const usd = finiteNumber(entry.usd !== undefined ? entry.usd : entry.cost);
    if (usd !== null) {
      row.usd = (row.usd || 0) + usd;
      row.priced = true;
    }
  }
  const session = bridge && bridge.session;
  const cost = session && session.cost;
  const providers = (cost && cost.providers) || {};
  for (const [provider, stats] of Object.entries(providers)) {
    const row = rowFor(provider === "openai" ? "gateway" : provider);
    const usd = finiteNumber(stats && stats.usd);
    if (usd !== null) {
      row.usd = (row.usd || 0) + usd;
      row.priced = true;
    }
  }
  const list = [...rows.values()].sort((left, right) =>
    right.tokens - left.tokens || (right.usd || 0) - (left.usd || 0));
  const totalTokens = list.reduce((sum, row) => sum + row.tokens, 0);
  const bridgeTokens = finiteNumber(
    session && session.total && (session.total.total !== undefined ? session.total.total : session.total.tokens)
  );
  return {
    rows: list.slice(0, 3),
    totalTokens,
    sessionSpend: finiteNumber(cost && (cost.total !== undefined ? cost.total : cost.usd)),
    sessionTokens: bridgeTokens !== null ? bridgeTokens : (totalTokens || null),
  };
}

// The tray and dashboard "Run next" share this pick: due tasks first because
// they have the earliest nextRunAt, disabled tasks never qualify.
function schedulerNextTask(data, nowSeconds) {
  const now = finiteNumber(nowSeconds) ?? nowRef();
  const tasks = ((data && data.tasks) || []).filter((task) =>
    task && task.enabled && finiteNumber(task.nextRunAt) !== null);
  tasks.sort((left, right) => Number(left.nextRunAt) - Number(right.nextRunAt));
  return tasks[0] || null;
}

function schedulerSummary(data, nowSeconds) {
  const now = finiteNumber(nowSeconds) ?? nowRef();
  const tasks = ((data && data.tasks) || []).filter(Boolean);
  const enabled = tasks.filter((task) => task.enabled);
  const due = enabled.filter((task) =>
    finiteNumber(task.nextRunAt) !== null && Number(task.nextRunAt) <= now);
  const last = tasks
    .filter((task) => finiteNumber(task.lastRunAt) !== null)
    .sort((left, right) => Number(right.lastRunAt) - Number(left.lastRunAt))[0] || null;
  return { due: due.length, next: schedulerNextTask(data, now), last };
}

function dashboardVisibility(settings) {
  const value = settings || {};
  return {
    pool: value.dashboardShowPoolHealth !== false,
    trends: value.dashboardShowQuotaTrends !== false,
    spend: value.dashboardShowSpend !== false,
    scheduler: value.dashboardShowScheduler !== false,
  };
}

function dashboardCardToggles(settings) {
  const value = settings || {};
  const cards = [
    ["dashboardShowPoolHealth", "dashCardPool"],
    ["dashboardShowQuotaTrends", "dashCardTrends"],
    ["dashboardShowSpend", "dashCardSpend"],
    ["dashboardShowScheduler", "dashCardScheduler"],
  ];
  return `<div class="card dashboard-toggle-card" data-dashboard-toggles>
    <div class="row">
      <span class="spark-label">${esc(t("dashCards"))}</span>
      ${cards.map(([setting, key]) => `<label class="card-toggle">
        <input type="checkbox" ${value[setting] !== false ? "checked" : ""} onchange="A.dashboardCardToggle('${setting}', this.checked)">
        <span>${esc(t(key))}</span>
      </label>`).join("")}
    </div>
  </div>`;
}

function dashboardPoolCard(health) {
  const stat = (label, value, cls) => `<div class="stat ${cls || ""}">
    <span class="value">${value}</span><span class="label">${esc(label)}</span></div>`;
  return `<div class="card" data-dashboard-card="pool-health">
    <h2>${t("dashPoolHealth")} <span class="hint">${health.total} ${t("accountsCount")}</span></h2>
    <div class="stat-grid">
      ${stat(t("dashUsable"), health.usable, "ok")}
      ${stat(t("dashPaused"), health.paused, "warn")}
      ${stat(t("dashErrors"), health.errors, "danger")}
      ${stat(t("dashAvgFive"), health.averageHourly === null ? "—" : `${Math.round(health.averageHourly)}%`, "")}
      ${stat(t("dashAvgWeek"), health.averageWeekly === null ? "—" : `${Math.round(health.averageWeekly)}%`, "")}
    </div>
  </div>`;
}

function dashboardTrendsCard(trends) {
  return `<div class="card" data-dashboard-card="quota-trends">
    <h2>${t("dashQuotaTrends")} <span class="hint">${t("dashTrendHint")}</span></h2>
    <div class="trend-grid">
      ${trendChart(trends.hourly, t("dashLast24h"))}
      ${trendChart(trends.weekly, t("dashLast7d"))}
    </div>
  </div>`;
}

function dashboardSpendCard(usage) {
  const rows = usage.rows.map((row) => `<tr>
    <td>${esc(providerName(row.provider))}</td>
    <td>${formatTokens(row.tokens)}</td>
    <td>${row.priced && row.usd !== null ? formatMoney(row.usd) : "—"}</td>
    <td>${row.turns}</td>
  </tr>`).join("");
  return `<div class="card" data-dashboard-card="spend">
    <h2>${t("dashSpend")}</h2>
    <div class="usage-totals">
      <div class="stat"><span class="value">${formatMoney(usage.sessionSpend)}</span><span class="label">${esc(t("dashSessionSpend"))}</span></div>
      <div class="stat"><span class="value">${formatTokens(usage.sessionTokens)}</span><span class="label">${esc(t("dashSessionTokens"))}</span></div>
    </div>
    ${usage.rows.length ? `<div class="usage-title">${esc(t("dashTopProviders"))}</div>
      <table class="usage">
        <thead><tr><th>${t("dashProvider")}</th><th>${t("dashTokens")}</th><th>${t("dashSpendShort")}</th><th>${t("dashTurns")}</th></tr></thead>
        <tbody>${rows}</tbody>
      </table>` : `<div class="footnote">${t("dashNoUsage")}</div>`}
  </div>`;
}

function dashboardSchedulerCard(summary) {
  const next = summary.next;
  const last = summary.last;
  return `<div class="card" data-dashboard-card="scheduler">
    <h2>${t("dashScheduler")}</h2>
    <div class="stat-grid">
      <div class="stat ${summary.due ? "warn" : ""}"><span class="value">${summary.due}</span><span class="label">${esc(t("dashDue"))}</span></div>
      <div class="stat"><span class="value">${next ? esc(schedulerNextText(next.nextRunAt)) : "—"}</span><span class="label">${esc(t("dashNextRun"))}</span></div>
      <div class="stat"><span class="value">${last ? esc(ageText(last.lastRunAt)) : "—"}</span><span class="label">${esc(t("dashLastRun"))}</span></div>
    </div>
    <div class="row" style="margin-top:12px">
      <button class="btn small" onclick="A.schedulerRunNext()" ${next && !S.busy["sched-run-next"] ? "" : "disabled"}>${t("dashRunNext")}</button>
      <button class="ghost small" onclick="A.go('scheduler')">${t("dashOpenScheduler")}</button>
      ${last ? schedulerStatusPill(last) : ""}
      ${last ? `<span class="footnote" style="margin:0">${esc(last.name || "")}</span>` : `<span class="footnote" style="margin:0">${t("dashNoTasks")}</span>`}
    </div>
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

// Pool-pause preflight: the vault has accounts, but every one is paused by
// a quota window or by the routing planner.
function poolPauseBlock(account) {
  const info = (account && account.blockInfo) || {};
  const code = String(info.code || "");
  const remaining = info.remaining === null || info.remaining === undefined ? NaN : Number(info.remaining);
  const limit = info.limit === null || info.limit === undefined ? NaN : Number(info.limit);
  let window = null;
  if (code === "hourly_reserve" || code === "hourly_exhausted") window = "hourly";
  else if (code === "weekly_reserve" || code === "weekly_exhausted") window = "weekly";
  const reset = window === "hourly"
    ? account.hourlyResetAt
    : window === "weekly"
      ? account.weeklyResetAt
      : null;
  const exhausted = code === "hourly_exhausted" || code === "weekly_exhausted" ||
    (Number.isFinite(remaining) && remaining <= 0);
  const liftable = code.endsWith("_reserve") && Number.isFinite(remaining) && remaining > 0 &&
    Number.isFinite(limit) && limit > 0;
  return { account, window, reset, exhausted, liftable, code, remaining, limit };
}

function poolPauseResetTime(unixTs, weekly) {
  if (!Number.isFinite(unixTs)) return "—";
  const date = new Date(unixTs * 1000);
  if (Number.isNaN(date.getTime())) return "—";
  const hours = String(date.getHours()).padStart(2, "0");
  const minutes = String(date.getMinutes()).padStart(2, "0");
  if (!weekly) return `${hours}:${minutes}`;
  const day = String(date.getDate()).padStart(2, "0");
  const month = String(date.getMonth() + 1).padStart(2, "0");
  return `${day}.${month} ${hours}:${minutes}`;
}

function poolPauseState() {
  const accounts = S.accounts || [];
  if (!accounts.length) return null;
  const blockedIds = new Set(((S.routing && S.routing.blockedIds) || []).map(String));
  const paused = accounts.filter((account) => account &&
    (account.blocked || account.blockInfo || blockedIds.has(String(account.id))));
  if (paused.length !== accounts.length) return null;

  const blocks = paused.map(poolPauseBlock);
  const allHourly = blocks.every((block) => block.code === "hourly_reserve");
  const allWeekly = blocks.every((block) => block.code === "weekly_reserve");
  const allExhausted = blocks.every((block) => block.exhausted);
  let kind = "mixed";
  if (allExhausted) kind = "exhausted";
  else if (allHourly) kind = "hourly";
  else if (allWeekly) kind = "weekly";

  const relevant = kind === "hourly"
    ? blocks.filter((block) => block.window === "hourly")
    : kind === "weekly"
      ? blocks.filter((block) => block.window === "weekly")
      : blocks;
  const timed = relevant.filter((block) => Number.isFinite(block.reset));
  const nearest = timed.length
    ? timed.reduce((left, right) => (right.reset < left.reset ? right : left))
    : null;
  const weeklyTime = kind === "weekly" || (kind === "mixed" && nearest && nearest.window === "weekly");
  const time = poolPauseResetTime(nearest ? nearest.reset : null, weeklyTime);
  let message = fmt(t("poolPauseMixed"), { time });
  if (kind === "hourly") message = fmt(t("poolPauseHourly"), { time });
  else if (kind === "weekly") message = fmt(t("poolPauseWeekly"), { time });
  else if (kind === "exhausted") message = fmt(t("poolPauseExhausted"), { time });

  return { kind, message, blocks, liftable: blocks.some((block) => block.liftable) };
}

function poolPauseWindows(block) {
  const windows = new Set();
  if (block.window && block.code.endsWith("_reserve")) windows.add(block.window);
  const account = block.account;
  const hourlyReserve = Number(account.hourlyReservePercent);
  const weeklyReserve = Number(account.weeklyReservePercent);
  const hourlyRemaining = Number(account.hourlyRemaining);
  const weeklyRemaining = Number(account.weeklyRemaining);
  if (Number.isFinite(hourlyReserve) && hourlyReserve > 0 &&
      Number.isFinite(hourlyRemaining) && hourlyRemaining > 0 && hourlyRemaining <= hourlyReserve) {
    windows.add("hourly");
  }
  if (Number.isFinite(weeklyReserve) && weeklyReserve > 0 &&
      Number.isFinite(weeklyRemaining) && weeklyRemaining > 0 && weeklyRemaining <= weeklyReserve) {
    windows.add("weekly");
  }
  return windows;
}

function poolPauseBanner() {
  const state = poolPauseState();
  if (!state) return "";
  return `<div class="card pool-pause" id="pool-pause-banner" data-kind="${esc(state.kind)}">
    <div class="row">
      <span class="pill warn">${esc(t("paused"))}</span>
      <span>${esc(state.message)}</span>
      <span class="spacer"></span>
      ${state.liftable
        ? `<button class="btn small" id="pool-pause-lift" onclick="A.liftPoolPause()" ${S.busy.poolPause ? "disabled" : ""}>${esc(t("poolPauseLift"))}</button>`
        : ""}
    </div>
  </div>`;
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
  scheduler: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="8"/><path d="M12 8v4l3 2"/></svg>',
  donate: '<svg viewBox="0 0 24 24"><path d="M12 20s-7-4.5-9-9a5 5 0 0 1 9-3 5 5 0 0 1 9 3c-2 4.5-9 9-9 9Z"/></svg>',
  settings: '<svg viewBox="0 0 24 24"><path d="M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6Z"/><path d="M19 12a7 7 0 0 0-.1-1l2-1.5-2-3.4-2.3 1a7 7 0 0 0-1.7-1L14.5 3h-5l-.4 2.6a7 7 0 0 0-1.7 1l-2.3-1-2 3.4L5 11a7 7 0 0 0 0 2l-2 1.5 2 3.4 2.3-1a7 7 0 0 0 1.7 1l.4 2.6h5l.4-2.6a7 7 0 0 0 1.7-1l2.3 1 2-3.4-2-1.5c.1-.3.1-.7.1-1Z"/></svg>',
};

const NAV = [
  { group: "codex", items: ["dashboard", "accounts", "api", "providers", "composer", "instances"] },
  { group: "general", items: ["scheduler", "settings", "donate"] },
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
    scheduler: schedulerPage,
    donate: donatePage,
    settings: settingsPage,
  };
  main.innerHTML = (pages[S.section] || dashboardPage)();
  if (S.section === "donate") renderDonateQr();
  if (S.section === "scheduler" && !S.scheduler && !S.schedulerError) A.schedulerLoad();
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
  const accounts = Array.isArray(S.accounts) ? S.accounts : [];
  const ready = accounts.filter((a) => !a.blocked);
  const poolHourly = accounts.reduce((sum, a) => sum + (a.hourlyRemaining ?? 0), 0);
  const poolWeekly = accounts.reduce((sum, a) => sum + (a.weeklyRemaining ?? 0), 0);
  const status = S.status || {};
  const cards = dashboardVisibility(S.settings);
  const health = poolHealth(accounts, S.routing);
  const trends = quotaTrends(S.history, nowRef());
  const usage = usageSummary(S.scheduler, S.bridge);
  const schedule = schedulerSummary(S.scheduler, nowRef());

  return `
  ${pageHead("melon tools", t("dashTitle"), t("dashSub"))}
  ${dashboardCardToggles(S.settings)}
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

  <div class="dash-grid">
    ${cards.pool ? dashboardPoolCard(health) : ""}
    ${cards.spend ? dashboardSpendCard(usage) : ""}
  </div>
  ${cards.trends ? dashboardTrendsCard(trends) : ""}
  ${cards.scheduler ? dashboardSchedulerCard(schedule) : ""}

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
  ${poolPauseBanner()}
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
          <input type="checkbox" id="claude-enabled" ${settings.claudeEnabled ? "checked" : ""} onchange="A.providerToggleChanged()">
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
  ${poolPauseBanner()}
  <div class="grid2">
    <div class="card">
      <h2>${t("openrouter")}</h2>
      <div class="stack">
        <label class="field">${t("orKey")}
          <input type="password" id="or-key" value="${esc(settings.openrouterKey || "")}" placeholder="sk-or-v1-…">
        </label>
        <div class="row">
          <label class="field" style="flex-direction:row;align-items:center;gap:6px">
            <input type="checkbox" id="or-enabled" ${settings.openrouterEnabled ? "checked" : ""} onchange="A.providerToggleChanged()">
            <span>${t("sourceEnabled")}</span>
          </label>
          <label class="field" style="flex-direction:row;align-items:center;gap:6px">
            <input type="checkbox" id="oc-enabled" ${settings.opencodeEnabled ? "checked" : ""} onchange="A.providerToggleChanged()">
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
          <input type="checkbox" ${settings.notifications !== false ? "checked" : ""} onchange="A.notifyToggle(this.checked)">
          <span>${t("notifications")}</span>
        </label>
      </div>
      <div class="row">
        <label class="field" style="flex-direction:row;align-items:center;gap:6px">
          <input type="checkbox" ${settings.notifyLowQuota !== false ? "checked" : ""} onchange="A.notifyDetailToggle('notifyLowQuota', this.checked)">
          <span>${t("notifyLowQuota")}</span>
        </label>
        <label class="field" style="flex-direction:row;align-items:center;gap:6px">
          <input type="checkbox" ${settings.notifyScheduler !== false ? "checked" : ""} onchange="A.notifyDetailToggle('notifyScheduler', this.checked)">
          <span>${t("notifyScheduler")}</span>
        </label>
        <label class="field" style="flex-direction:row;align-items:center;gap:6px">
          <input type="checkbox" ${settings.notifyQuotaReset !== false ? "checked" : ""} onchange="A.notifyDetailToggle('notifyQuotaReset', this.checked)">
          <span>${t("notifyQuotaReset")}</span>
        </label>
      </div>
      <div class="footnote" style="margin-top:0">${t("notificationsHint")}</div>
      <div class="row">
        <button class="btn small" onclick="A.applySettings()">${t("apply")}</button>
        <span class="footnote">${t("autoRefresh")}</span>
      </div>
    </div>
  </div>

  ${dashboardCardToggles(settings)}

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

// Scheduled tasks: result bodies are capped server-side (64 KiB); the viewer
// caps again so a huge answer cannot stall the DOM.
const RESULT_VIEW_CAP = 20000;

function boundedText(text) {
  const value = String(text || "");
  return value.length > RESULT_VIEW_CAP ? `${value.slice(0, RESULT_VIEW_CAP)}\n…` : value;
}

function schedulerNextText(unixTs) {
  if (!unixTs) return "—";
  const secs = unixTs - nowRef();
  if (secs <= 0) return t("schedulerDue");
  const mins = Math.ceil(secs / 60);
  if (mins < 60) return fmt(t("schedulerMinutesShort"), { n: mins });
  const hours = Math.floor(mins / 60);
  return `${hours} ${unit("h", "ч")} ${mins % 60} ${unit("min", "мин")}`;
}

function schedulerGroupLabel(id) {
  switch (id) {
    case "claude": return t("sgClaude");
    case "opencode": return t("sgOpenCode");
    case "openrouter": return t("sgOpenRouter");
    default: return t("sgGateway");
  }
}

function schedulerStatusPill(task) {
  switch (task.lastStatus) {
    case "running": return `<span class="pill gold">${t("schedulerRunning")}</span>`;
    case "ok": return `<span class="pill ok">${t("schedulerOk")}</span>`;
    case "error": return `<span class="pill danger">${t("schedulerError")}</span>`;
    default: return `<span class="pill">${t("schedulerNever")}</span>`;
  }
}

// Built-in task templates. The prompt keeps `{{variable}}` placeholders until
// the user fills the fields and saves; the backend never sees the placeholders.
const SCHEDULER_TEMPLATES = [
  {
    id: "morning-digest", nameKey: "schedulerTplMorning", descKey: "schedulerTplMorningDesc",
    prompt: "Give me a short morning digest for {{repo}} on branch {{branch}}.\nSummarize the latest commits, open work and anything that needs attention today.\nKeep it under 200 words.",
    variables: ["repo", "branch"], scheduleKind: "cron", cronExpression: "0 9 * * 1-5", intervalMinutes: 60,
  },
  {
    id: "pr-review", nameKey: "schedulerTplPR", descKey: "schedulerTplPRDesc",
    prompt: "Review the open pull requests in {{repo}} for branch {{branch}}.\nList failing checks, unresolved comments and the riskiest changes with file paths.\nFinish with the top three issues to fix first.",
    variables: ["repo", "branch"], scheduleKind: "cron", cronExpression: "0 18 * * 1-5", intervalMinutes: 60,
  },
  {
    id: "weekly-repo-summary", nameKey: "schedulerTplWeekly", descKey: "schedulerTplWeeklyDesc",
    prompt: "Write a weekly summary for {{repo}} at {{path}}.\nCover merged changes, active branches, open risks and the next steps.\nUse no more than 250 words.",
    variables: ["repo", "path"], scheduleKind: "cron", cronExpression: "0 10 * * 1", intervalMinutes: 60,
  },
  {
    id: "log-check", nameKey: "schedulerTplLogs", descKey: "schedulerTplLogsDesc",
    prompt: "Check the recent logs under {{path}} for errors and warnings.\nGroup the findings by severity, point to the likely cause and suggest a fix.\nIf everything is clean, say so in one line.",
    variables: ["path"], scheduleKind: "cron", cronExpression: "0 */6 * * *", intervalMinutes: 360,
  },
  {
    id: "daily-spend", nameKey: "schedulerTplSpend", descKey: "schedulerTplSpendDesc",
    prompt: "Review today's model spend for {{repo}}.\nSummarize token usage, the most expensive models and any unusual spikes.\nFinish with one short recommendation.",
    variables: ["repo"], scheduleKind: "cron", cronExpression: "0 21 * * *", intervalMinutes: 1440,
  },
];

function schedulerTemplate(id) {
  return SCHEDULER_TEMPLATES.find((item) => item.id === id) || null;
}

function schedulerVariableLabel(variable) {
  if (variable === "repo") return t("schedulerRepo");
  if (variable === "branch") return t("schedulerBranch");
  if (variable === "path") return t("schedulerPath");
  return variable;
}

function schedulerSystemZone() {
  const offset = -new Date().getTimezoneOffset();
  const sign = offset >= 0 ? "+" : "-";
  const abs = Math.abs(offset);
  return `System (${sign}${String(Math.floor(abs / 60)).padStart(2, "0")}:${String(abs % 60).padStart(2, "0")})`;
}

function schedulerZoneOptions(selected) {
  const zones = ["", "UTC", "+03:00", "+02:00", "+01:00", "-05:00", "-08:00", "+05:30", "+08:00", "+10:00"];
  return zones.map((value) => {
    const label = value === "" ? schedulerSystemZone() : value;
    return `<option value="${esc(value)}" ${value === (selected || "") ? "selected" : ""}>${esc(label)}</option>`;
  }).join("");
}

function schedulerPage() {
  const data = S.scheduler;
  const tasks = (data && data.tasks) || [];
  const path = (data && data.path) || "";
  const head = pageHead("melon tools", t("scheduler"), t("schedulerSub"));
  // Tasks run through the local gateway: a stopped service makes every task
  // fail, so say it before the list instead of after a failed run.
  const stopped = S.status && S.status.running === false;
  const banner = stopped
    ? `<div class="card"><div class="row"><span class="pill warn">${t("gateway")}</span>
        <span class="muted">${t("schedulerGatewayOff")}</span></div></div>`
    : "";

  if (S.schedulerError) {
    return `${head}
      <div class="card">
        <div class="row"><span class="pill danger">${t("error")}</span>
          <span class="mono" style="font-size:11px">${esc(S.schedulerError)}</span></div>
        <div class="footnote">${t("schedulerGatewayOff")}</div>
        <div class="row" style="margin-top:10px">
          <button class="ghost small" onclick="A.schedulerLoad()">${t("refresh")}</button>
        </div>
      </div>
      ${schedulerModal()}`;
  }
  if (!data) {
    return `${head}${banner}<div class="card"><div class="muted">${t("loading")}</div></div>${schedulerModal()}`;
  }
  return `${head}
    ${banner}
    <div class="footnote" style="margin-top:0">${t("schedulerTrayHint")}</div>
    <div class="row">
      <button class="btn small" onclick="A.schedulerEdit()">${t("schedulerAdd")}</button>
      <button class="ghost small" onclick="A.schedulerLoad()">${t("refresh")}</button>
      <span class="spacer"></span>
      ${path ? `<span class="footnote mono" style="margin:0">${esc(path)}</span>` : ""}
    </div>
    ${tasks.length
      ? `<div class="accounts">${tasks.map((task) => schedulerCard(task, data)).join("")}</div>`
      : `<div class="card"><div class="muted">${t("schedulerEmpty")}</div></div>`}
    ${schedulerModal()}`;
}

function schedulerCard(task, data) {
  const open = S.schedulerOpen === task.id;
  return `<div class="card">
    <div class="account-head">
      <span class="email">${esc(task.name)}</span>
      ${schedulerStatusPill(task)}
      <span class="spacer"></span>
      <label class="row" style="gap:6px;font-size:11px;color:var(--text2)">
        <input type="checkbox" ${task.enabled ? "checked" : ""} onchange="A.schedulerToggle('${esc(task.id)}', this.checked)">
        <span>${t("schedulerEnabled")}</span>
      </label>
    </div>
    <div class="task-meta">
      <span>${t("schedulerModel")}: <span class="val">${esc(task.model || "—")}</span></span>
      ${task.reasoningEffort ? `<span class="pill gold">${esc(task.reasoningEffort)}</span>` : ""}
      <span>${task.scheduleKind === "cron"
        ? `${t("schedulerScheduleCron")}: <span class="mono">${esc(task.cronExpression || "—")}</span>`
        : fmt(t("schedulerEvery"), { n: task.intervalMinutes || 0 })}</span>
      ${task.timeZone ? `<span>${t("schedulerTimeZone")}: <span class="mono">${esc(task.timeZone)}</span></span>` : ""}
      <span>${t("schedulerNext")}: <span class="val">${task.enabled ? esc(schedulerNextText(task.nextRunAt)) : "—"}</span></span>
      <span>${t("schedulerLast")}: <span class="val">${task.lastRunAt ? esc(ageText(task.lastRunAt)) : t("never")}</span></span>
      ${task.lastDurationMs != null ? `<span>${t("schedulerDuration")}: ${Math.round(task.lastDurationMs / 100) / 10} ${unit("s", "с")}</span>` : ""}
      ${task.lastTokens != null ? `<span>${t("schedulerTokens")}: ${task.lastTokens}</span>` : ""}
    </div>
    ${task.lastError ? `<div class="footnote mono" style="color:var(--danger);white-space:pre-wrap;max-height:140px;overflow:auto">${esc(boundedText(task.lastError))}</div>` : ""}
    <div class="row" style="margin-top:12px">
      <button class="ghost small" onclick="A.schedulerRunNow('${esc(task.id)}')" ${S.busy["sched-run-" + task.id] ? "disabled" : ""}>${t("schedulerRunNow")}</button>
      <button class="ghost small" onclick="A.schedulerEdit('${esc(task.id)}')">${t("schedulerEdit")}</button>
      <button class="ghost small" onclick="A.schedulerToggleResult('${esc(task.id)}')">${open ? t("schedulerClose") : t("schedulerResult")}</button>
      <span class="spacer"></span>
      <button class="ghost small danger" onclick="A.schedulerDelete('${esc(task.id)}')">${t("schedulerDelete")}</button>
    </div>
    ${open ? schedulerDetails(task, data) : ""}
  </div>`;
}

function schedulerDetails(task, data) {
  const history = (data.history || [])
    .filter((entry) => entry.taskId === task.id)
    .slice(-20)
    .reverse();
  return `<div class="result-view">${esc(boundedText(task.lastResult || t("schedulerNoResult")))}</div>
    ${history.length
      ? `<div class="footnote" style="margin-top:10px">${t("schedulerHistory")}</div>
        ${history.map((entry) => `<div class="footnote mono" style="margin-top:2px">
          ${esc(new Date(entry.at * 1000).toLocaleString())} · ${esc(entry.status)}${entry.tokens != null ? ` · ${entry.tokens} ${t("schedulerTokens")}` : ""} · ${esc(boundedText(String(entry.result || entry.error || "")).slice(0, 240))}
        </div>`).join("")}`
      : ""}`;
}

function schedulerModal() {
  const form = S.schedulerForm;
  if (!form) return "";
  const selected = form.model || "";
  const covered = new Set();
  const groups = (S.schedulerModels && S.schedulerModels.groups) || [];
  const options = groups.map((group) => `<optgroup label="${esc(schedulerGroupLabel(group.id))}">${(group.ids || [])
    .map((id) => {
      covered.add(id);
      return `<option value="${esc(id)}" ${id === selected ? "selected" : ""}>${esc(id)}</option>`;
    })
    .join("")}</optgroup>`);
  // A saved model missing from the current gateway list must stay selectable:
  // the gateway may be stopped or the pool may have changed since the save.
  if (selected && !covered.has(selected)) {
    options.push(`<optgroup label="${esc(t("schedulerModel"))}"><option value="${esc(selected)}" selected>${esc(selected)}</option></optgroup>`);
  }
  return `<div class="modal" id="scheduler-modal"><div class="modal-card">
    <h2>${form.id ? t("schedulerEditTitle") : t("schedulerAddTitle")}</h2>
    <div class="stack">
      ${!form.id ? `<label class="field">${t("schedulerTemplate")}<select id="sched-template" onchange="A.schedulerTemplateApply(this.value)">
        <option value="">${t("schedulerTemplateNone")}</option>
        ${SCHEDULER_TEMPLATES.map((item) => `<option value="${esc(item.id)}" ${form.templateId === item.id ? "selected" : ""}>${esc(t(item.nameKey))}</option>`).join("")}
      </select></label>` : ""}
      <label class="field">${t("schedulerName")}<input type="text" id="sched-name" value="${esc(form.name || "")}"></label>
      ${form.templateId && form.variables ? `<div class="row" style="align-items:flex-end">${Object.keys(form.variables).map((variable) => `
        <label class="field">${esc(schedulerVariableLabel(variable))}<input type="text" id="sched-var-${esc(variable)}" value="${esc(form.variables[variable] || "")}" oninput="A.schedulerVarInput('${esc(variable)}', this.value)"></label>`).join("")}</div>
        <div class="footnote" style="margin-top:0">${t("schedulerVariables")}: ${Object.keys(form.variables).map((variable) => `{{${esc(variable)}}}`).join(" · ")}</div>` : ""}
      <label class="field">${t("schedulerPrompt")}<textarea id="sched-prompt">${esc(form.prompt || "")}</textarea></label>
      <label class="field">${t("schedulerModel")}<select id="sched-model">${options.join("") || `<option value="">${t("schedulerModelsFailed")}</option>`}</select></label>
      <label class="field">${t("schedulerEffort")}<select id="sched-effort">
        <option value="" ${!form.reasoningEffort ? "selected" : ""}>${t("schedulerEffortDefault")}</option>
        ${["low", "medium", "high", "xhigh", "max"].map((value) => `<option value="${value}" ${form.reasoningEffort === value ? "selected" : ""}>${value}</option>`).join("")}
      </select></label>
      <label class="field">${t("schedulerScheduleType")}<select id="sched-schedule-kind" onchange="A.schedulerKindChanged(this.value)">
        <option value="interval" ${(form.scheduleKind || "interval") === "interval" ? "selected" : ""}>${t("schedulerScheduleInterval")}</option>
        <option value="cron" ${form.scheduleKind === "cron" ? "selected" : ""}>${t("schedulerScheduleCron")}</option>
      </select></label>
      <div id="sched-interval-row" style="${(form.scheduleKind || "interval") === "cron" ? "display:none" : ""}">
        <label class="field">${t("schedulerInterval")}<input class="small" type="number" id="sched-interval" min="1" step="1" value="${form.intervalMinutes || 60}"></label>
      </div>
      <div id="sched-cron-row" style="${form.scheduleKind === "cron" ? "" : "display:none"}">
        <label class="field">${t("schedulerCron")}<input type="text" id="sched-cron" class="mono" value="${esc(form.cronExpression || "")}" placeholder="0 9 * * 1-5"></label>
        <div class="footnote" style="margin-top:0">${t("schedulerCronHint")} · ${t("schedulerCronExamples")}</div>
      </div>
      <label class="field">${t("schedulerTimeZone")}<select id="sched-timezone">${schedulerZoneOptions(form.timeZone || "")}</select></label>
      <label class="field" style="flex-direction:row;align-items:center;gap:6px">
        <input type="checkbox" id="sched-enabled" ${form.enabled !== false ? "checked" : ""}><span>${t("schedulerEnabled")}</span>
      </label>
      <div class="footnote" style="margin-top:0">${t("schedulerTrayHint")}</div>
      <div class="footnote" style="margin-top:0">${S.schedulerModelsError ? esc(S.schedulerModelsError) : t("schedulerModelHint")}</div>
      <div class="row" style="justify-content:flex-end">
        <button class="ghost" onclick="A.schedulerFormClose()">${t("cancel")}</button>
        <button class="btn" onclick="A.schedulerFormSave()" ${S.busy["sched-save"] ? "disabled" : ""}>${t("save")}</button>
      </div>
    </div>
  </div></div>`;
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

  // Both actions go through dismissOnboarding(): the flag is written, the
  // node is dropped and the page scroll comes back. Only the two navigation
  // actions re-render the page.
  onboardingGo(section) {
    dismissOnboarding();
    S.section = section;
    render();
  },

  onboardingDone() {
    dismissOnboarding();
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
      if (S.section === "dashboard") {
        try {
          S.scheduler = await inv("scheduler_list");
          S.schedulerAt = Date.now();
        } catch {
          // Keep the previous scheduler snapshot on a failed read.
        }
      }
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
      try {
        S.scheduler = await inv("scheduler_list");
        S.schedulerAt = Date.now();
      } catch {
        S.scheduler = null;
      }
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

  providerToggleChanged() {
    const openrouter = document.getElementById("or-enabled");
    const opencode = document.getElementById("oc-enabled");
    const claude = document.getElementById("claude-enabled");
    S.settings = {
      ...S.settings,
      ...(openrouter ? { openrouterEnabled: openrouter.checked } : {}),
      ...(opencode ? { opencodeEnabled: opencode.checked } : {}),
      ...(claude ? { claudeEnabled: claude.checked } : {}),
    };
    inv("settings_set", { settings: S.settings })
      .then((settings) => { S.settings = settings; })
      .catch((error) => toast(errorText(error), true));
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

  liftPoolPause() {
    const state = poolPauseState();
    if (!state || !state.liftable) return;
    if (!window.confirm(t("poolPauseConfirm"))) return;
    const targets = state.blocks
      .filter((block) => block.liftable)
      .map((block) => ({ block, windows: poolPauseWindows(block) }));
    run("poolPause", async () => {
      for (const { block, windows } of targets) {
        const account = block.account;
        await inv("save_reserves", {
          id: account.id,
          hourly: windows.has("hourly") ? null : (account.hourlyReservePercent ?? null),
          weekly: windows.has("weekly") ? null : (account.weeklyReservePercent ?? null),
        });
      }
      await inv("gateway_sync");
      await inv("quota_refresh");
      S.accounts = await inv("vault_list");
      S.routing = await inv("routing_state");
      toast(t("done"));
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
      const openrouterEnabled = document.getElementById("or-enabled");
      const opencodeEnabled = document.getElementById("oc-enabled");
      S.settings = await inv("settings_set", {
        settings: {
          ...S.settings,
          openrouterKey,
          opencodeKey,
          openrouterEnabled: openrouterEnabled ? openrouterEnabled.checked : !!S.settings.openrouterEnabled,
          opencodeEnabled: opencodeEnabled ? opencodeEnabled.checked : !!S.settings.opencodeEnabled,
        },
      });
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
      S.settings = await inv("settings_set", {
        settings: {
          ...S.settings,
          lang,
          port: Number.isFinite(port) ? port : S.settings.port,
          quotaInterval: Number.isFinite(quotaInterval) ? quotaInterval : S.settings.quotaInterval,
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

  schedulerLoad() {
    run("scheduler", async () => {
      try {
        S.scheduler = await inv("scheduler_list");
        S.schedulerError = null;
      } catch (error) {
        // A failed read must not render as "no tasks": the page says why.
        S.schedulerError = errorText(error);
      }
    });
  },

  schedulerModelsLoad() {
    run("sched-models", async () => {
      try {
        S.schedulerModels = await inv("scheduler_models");
        S.schedulerModelsError = null;
      } catch (error) {
        S.schedulerModels = null;
        S.schedulerModelsError = errorText(error);
      }
    });
  },

  schedulerToggleResult(id) {
    S.schedulerOpen = S.schedulerOpen === id ? null : id;
    render();
  },

  schedulerEdit(id) {
    const task = id ? ((S.scheduler && S.scheduler.tasks) || []).find((item) => item.id === id) : null;
    S.schedulerForm = task
      ? {
        id: task.id,
        name: task.name,
        prompt: task.prompt,
        model: task.model,
        reasoningEffort: task.reasoningEffort || "",
        intervalMinutes: task.intervalMinutes,
        scheduleKind: task.scheduleKind || "interval",
        cronExpression: task.cronExpression || "",
        timeZone: task.timeZone || "",
        enabled: task.enabled,
      }
      : {
        id: "", name: "", prompt: "", model: "", reasoningEffort: "", intervalMinutes: 60,
        scheduleKind: "interval", cronExpression: "", timeZone: "", enabled: true,
        templateId: "", variables: null,
      };
    render();
    if (!S.schedulerModels) A.schedulerModelsLoad();
  },

  schedulerTemplateApply(id) {
    if (!S.schedulerForm) return;
    const template = schedulerTemplate(id);
    if (!template) {
      S.schedulerForm = {
        ...S.schedulerForm,
        templateId: "",
        variables: null,
      };
      render();
      return;
    }
    S.schedulerForm = {
      ...S.schedulerForm,
      templateId: template.id,
      name: t(template.nameKey),
      prompt: template.prompt,
      scheduleKind: template.scheduleKind,
      cronExpression: template.cronExpression || "",
      intervalMinutes: template.intervalMinutes,
      timeZone: S.schedulerForm.timeZone || "",
      variables: Object.fromEntries(template.variables.map((variable) => [variable, ""])),
    };
    render();
  },

  schedulerVarInput(variable, value) {
    if (!S.schedulerForm || !S.schedulerForm.variables) return;
    if (!(variable in S.schedulerForm.variables)) return;
    S.schedulerForm.variables[variable] = value;
  },

  schedulerKindChanged(kind) {
    if (S.schedulerForm) S.schedulerForm.scheduleKind = kind === "cron" ? "cron" : "interval";
    const interval = document.getElementById("sched-interval-row");
    const cron = document.getElementById("sched-cron-row");
    if (interval) interval.style.display = kind === "cron" ? "none" : "";
    if (cron) cron.style.display = kind === "cron" ? "" : "none";
  },

  schedulerFormClose() {
    S.schedulerForm = null;
    S.schedulerModelsError = null;
    render();
  },

  schedulerFormSave() {
    const form = S.schedulerForm || {};
    const value = (id) => {
      const node = document.getElementById(id);
      return node && typeof node.value === "string" ? node.value : "";
    };
    // Read the fields before run(): its first render rebuilds the modal.
    const name = value("sched-name").trim();
    let prompt = value("sched-prompt").trim();
    const model = value("sched-model").trim();
    const reasoningEffort = value("sched-effort").trim();
    const scheduleKind = value("sched-schedule-kind") === "cron" ? "cron" : "interval";
    const cronExpression = value("sched-cron").trim().replace(/\s+/g, " ");
    const timeZone = value("sched-timezone").trim();
    const intervalMinutes = parseInt(value("sched-interval"), 10) || 60;
    const enabledNode = document.getElementById("sched-enabled");
    const enabled = !!(enabledNode && enabledNode.checked);
    if (!name || !prompt || !model) {
      toast(t("schedulerRequired"), true);
      return;
    }
    if (scheduleKind === "interval" && (!Number.isFinite(intervalMinutes) || intervalMinutes < 1)) {
      toast(t("schedulerInterval"), true);
      return;
    }
    if (scheduleKind === "cron" && cronExpression.split(" ").filter(Boolean).length !== 5) {
      toast(t("schedulerCronInvalid"), true);
      return;
    }
    // A template is rendered in the renderer: the backend stores the final
    // prompt and never needs to know about {{placeholders}}.
    if (!form.id && form.templateId) {
      const template = schedulerTemplate(form.templateId);
      if (template) {
        for (const variable of template.variables) {
          const raw = (form.variables && form.variables[variable]) || "";
          const replacement = raw.trim();
          if (!replacement) {
            toast(t("schedulerVariableRequired"), true);
            return;
          }
          prompt = prompt.split(`{{${variable}}}`).join(replacement);
        }
      }
    }
    const task = {
      id: form.id || "",
      name,
      prompt,
      model,
      reasoningEffort: reasoningEffort || null,
      scheduleKind,
      cronExpression: scheduleKind === "cron" ? cronExpression : null,
      timeZone: timeZone || null,
      intervalMinutes,
      enabled,
    };
    run("sched-save", async () => {
      S.scheduler = await inv("scheduler_save", { task });
      S.schedulerError = null;
      S.schedulerForm = null;
      toast(t("done"));
    });
  },

  schedulerToggle(id, enabled) {
    const task = ((S.scheduler && S.scheduler.tasks) || []).find((item) => item.id === id);
    if (!task) return;
    run("sched-toggle-" + id, async () => {
      S.scheduler = await inv("scheduler_save", { task: { ...task, enabled } });
      S.schedulerError = null;
      toast(t("done"));
    });
  },

  schedulerRunNow(id) {
    run("sched-run-" + id, async () => {
      S.scheduler = await inv("scheduler_run_now", { id });
      S.schedulerError = null;
      S.schedulerOpen = id;
      toast(t("done"));
    });
  },

  // Dashboard/tray entry point: one serial run of the earliest due/enabled
  // task. The scheduler page opens so the result is visible immediately.
  schedulerRunNext() {
    run("sched-run-next", async () => {
      if (!S.scheduler) {
        S.scheduler = await inv("scheduler_list");
        S.schedulerAt = Date.now();
      }
      const task = schedulerNextTask(S.scheduler);
      if (!task) {
        toast(t("dashNoTasks"));
        return;
      }
      S.section = "scheduler";
      S.busy["sched-run-" + task.id] = true;
      try {
        S.scheduler = await inv("scheduler_run_now", { id: task.id });
        S.schedulerError = null;
        S.schedulerAt = Date.now();
        S.schedulerOpen = task.id;
        toast(fmt(t("dashRunNextDone"), { name: task.name }));
      } finally {
        S.busy["sched-run-" + task.id] = false;
      }
    });
  },

  schedulerDelete(id) {
    const task = ((S.scheduler && S.scheduler.tasks) || []).find((item) => item.id === id);
    const name = (task && task.name) || id;
    if (!window.confirm(fmt(t("confirmDeleteTask"), { name }))) return;
    run("sched-delete-" + id, async () => {
      S.scheduler = await inv("scheduler_delete", { id });
      if (S.schedulerOpen === id) S.schedulerOpen = null;
      toast(t("done"));
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
        settings: { ...S.settings, notifications: enabled },
      });
    });
  },

  notifyDetailToggle(key, enabled) {
    if (["notifyLowQuota", "notifyScheduler", "notifyQuotaReset"].indexOf(key) < 0) return;
    run("notify-detail", async () => {
      S.settings = await inv("settings_set", {
        settings: { ...S.settings, [key]: enabled },
      });
    });
  },

  // Persisted per-card visibility. The optimistic update keeps the checkbox
  // responsive; a failed save surfaces as a toast.
  dashboardCardToggle(setting, enabled) {
    if (DASHBOARD_CARD_SETTINGS.indexOf(setting) < 0) return;
    S.settings = { ...(S.settings || {}), [setting]: enabled };
    render();
    run("dashboard-cards", async () => {
      S.settings = await inv("settings_set", { settings: { ...S.settings } });
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

// Tray events arrive as `tray-action`: navigation and run-next are owned by the
// renderer, gateway pause/resume only asks for a status refresh.
function handleTrayAction(payload) {
  const action = payload && payload.action;
  if (action === "navigate") {
    S.section = payload.section || "dashboard";
    render();
    return;
  }
  if (action === "run-next") {
    A.schedulerRunNext();
    return;
  }
  if (action === "refresh") {
    A.refreshStatus();
  }
}

window.__mt = {
  S,
  A,
  handleTrayAction,
  poolHealth,
  quotaTrend,
  quotaTrends,
  trendChart,
  usageSummary,
  schedulerNextTask,
  schedulerSummary,
  dashboardPage,
  dashboardVisibility,
};

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
//
// The buttons do not carry inline onclick attributes: inline handlers are
// compiled by the webview under the page script policy, and in the Windows
// webview they were not running at all, which left the welcome window with
// dead buttons and no way out. Every action is a data-onboarding attribute
// handled by one delegated listener registered from this script.
const ONBOARDING_KEY = "onboardingDone";

// Session memory. A dismissal must stick for this launch even when
// localStorage throws, and the tour must be injected at most once.
let onboardingDismissed = false;
let onboardingShown = false;

// Body scroll lock taken while the modal covers the page, restored on close.
let onboardingScrollLocked = false;
let onboardingPrevOverflow = "";

function onboardingSeen() {
  if (onboardingDismissed) return true;
  try {
    return window.localStorage.getItem(ONBOARDING_KEY) === "1";
  } catch {
    // Storage unavailable (hardened webview): the in-memory flag set on
    // dismissal still stops the tour from reopening during this launch.
    return false;
  }
}

function markOnboardingSeen() {
  onboardingDismissed = true;
  try {
    window.localStorage.setItem(ONBOARDING_KEY, "1");
  } catch {
    // Same as above — the UI keeps working when storage is unavailable.
  }
}

function lockOnboardingScroll() {
  if (onboardingScrollLocked) return;
  onboardingScrollLocked = true;
  onboardingPrevOverflow = document.body.style.overflow;
  document.body.style.overflow = "hidden";
}

function unlockOnboardingScroll() {
  if (!onboardingScrollLocked) return;
  onboardingScrollLocked = false;
  document.body.style.overflow = onboardingPrevOverflow;
  onboardingPrevOverflow = "";
}

// Single close path: remember the dismissal, drop the node, give the page
// its scroll back. Reusable from the buttons, Esc and the backdrop.
function dismissOnboarding() {
  markOnboardingSeen();
  const modal = document.getElementById("onboarding-modal");
  if (modal && modal.parentNode) modal.parentNode.removeChild(modal);
  unlockOnboardingScroll();
}

// One delegated listener on the modal root. It is bound once per node and
// survives the innerHTML rewrite below.
function bindOnboarding(modal) {
  if (modal._mtOnboardingBound) return;
  modal._mtOnboardingBound = true;
  modal.addEventListener("click", (event) => {
    const target = event.target;
    // The backdrop is the modal root itself. A click inside the card does
    // nothing unless it lands on an element that carries an action.
    if (target === modal) {
      dismissOnboarding();
      return;
    }
    const action = target && target.closest ? target.closest("[data-onboarding]") : null;
    if (!action || !modal.contains(action)) return;
    const name = action.getAttribute("data-onboarding");
    if (name === "accounts" || name === "providers") {
      A.onboardingGo(name);
    } else {
      // "done" and "close" only close — no render.
      A.onboardingDone();
    }
  });
}

// Esc closes the tour. Registered once on the document, so it keeps working
// after the modal node is removed and recreated.
document.addEventListener("keydown", (event) => {
  if (event.key !== "Escape" && event.key !== "Esc") return;
  const modal = document.getElementById("onboarding-modal");
  if (!modal || modal.hidden) return;
  dismissOnboarding();
});

function showOnboarding() {
  // Once per launch, and never again after a dismissal — even when
  // localStorage is unavailable and the flag cannot be read back.
  if (onboardingShown) return;
  onboardingShown = true;
  if (onboardingSeen()) return;
  let modal = document.getElementById("onboarding-modal");
  if (!modal) {
    modal = document.createElement("div");
    modal.id = "onboarding-modal";
    modal.className = "modal";
    modal.hidden = true;
    document.body.appendChild(modal);
    bindOnboarding(modal);
  }
  const steps = [
    ["1", "onboardingStep1"],
    ["2", "onboardingStep2"],
    ["3", "onboardingStep3"],
  ];
  modal.innerHTML = `
    <div class="modal-card" role="dialog" aria-modal="true" aria-labelledby="onboarding-title">
      <div class="modal-head">
        <div>
          <div class="kicker">melon tools</div>
          <h2 id="onboarding-title">${esc(t("onboardingTitle"))}</h2>
        </div>
        <button type="button" class="onboarding-close" data-onboarding="close"
          title="${esc(t("onboardingClose"))}" aria-label="${esc(t("onboardingClose"))}">×</button>
      </div>
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
        <button type="button" class="ghost small" data-onboarding="accounts">${esc(t("onboardingAccounts"))}</button>
        <button type="button" class="ghost small" data-onboarding="providers">${esc(t("onboardingProviders"))}</button>
        <button type="button" class="btn small" data-onboarding="done">${esc(t("onboardingDone"))}</button>
      </div>
    </div>`;
  modal.hidden = false;
  lockOnboardingScroll();
}

// MARK: - Boot

(async function boot() {
  if (window.__TAURI__ && window.__TAURI__.event && typeof window.__TAURI__.event.listen === "function") {
    try {
      window.__TAURI__.event.listen("tray-action", (event) => {
        handleTrayAction(event && event.payload);
      }).catch(() => {});
    } catch {
      // Older webview without the event API: tray navigation degrades to
      // opening the window only.
    }
  }
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
