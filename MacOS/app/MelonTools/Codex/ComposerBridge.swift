import AppKit
import Combine
import Foundation

/// Bridges Melon Tools into the Codex desktop app.
///
/// The Codex app (ChatGPT.app — Electron) can be started with a Chrome DevTools
/// Protocol port (`--remote-debugging-port=…`). When it is, this bridge injects
/// the composer chips script into its pages and keeps them fed with live pool
/// data.
///
/// Data flow (push only — the app's CSP blocks fetches to localhost):
///   - every tick the bridge evaluates `window.__melonChipsSetStatus(json)`;
///   - the chips refresh button calls the `__melonSend` CDP binding, which the
///     bridge receives as `Runtime.bindingCalled` and answers with fresh data.
///
/// The chips are intentionally left in place when Melon Tools quits — they dim
/// to an “offline” state and reconnect when the app is back.
@MainActor
final class ComposerBridge: ObservableObject {
    static let shared = ComposerBridge()

    enum BridgeStatus: Equatable {
        case off
        case codexNotRunning
        case noDebugPort
        case connecting
        case connected(port: Int)
        case failed(String)
    }

    @Published private(set) var status: BridgeStatus = .off
    @Published private(set) var lastInjection: Date?
    @Published private(set) var injectedPages = 0
    // Bridge log lines are not published: no view renders them, and the log
    // only grows over time (publishing would invalidate observers forever).
    private(set) var logLines: [String] = []
    @Published private(set) var busy = false
    @Published private(set) var refreshing = false

    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            if enabled {
                start()
            } else {
                stop(disposeChips: true)
            }
        }
    }

    static let enabledKey = "composerChipsEnabled"

    private var tickTimer: Timer?
    private var sessions: [String: CDPSession] = [:]
    private var injectedLanguage: String?
    /// Provider statistics for the chips (OpenRouter credits, OpenCode workspace).
    private let providerUsage = ProviderUsageStore.shared
    /// Model and thread read from the Codex page (used to pick the session).
    private var pageContext: (model: String?, threadID: String?) = (nil, nil)
    /// Display name → provider index for the picker grouping.
    private var pickerModels: [CodexModelCatalog.PickerModel] = []
    private var sourcesSubscription: AnyCancellable?
    /// Last automatic relaunch that tried to bring the debug port back.
    private var lastAutoManagedRelaunch: Date?
    /// The pid first seen without a debug port, and when. A quitting app
    /// briefly loses its launch arguments, so the watchdog waits for the
    /// same pid to stay without a port across two ticks before acting.
    private var noDebugPortSeen: (pid: Int, at: Date)?
    /// Cached process discovery result for the tick loop (see `codexProcess()`).
    private var cachedCodexProcess: (process: CodexProcess, at: Date)?

    private init() {
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        pickerModels = CodexModelCatalog.pickerIndex(sources: ModelSourcesStore.shared.sources)
        sourcesSubscription = ModelSourcesStore.shared.$sources
            .receive(on: RunLoop.main)
            .sink { [weak self] sources in
                self?.pickerModels = CodexModelCatalog.pickerIndex(sources: sources)
            }
    }

    // MARK: - Lifecycle

    /// Starts the discovery/injection loop (no-op when disabled).
    func start() {
        guard enabled else { return }
        if status == .off { status = .connecting }
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.tick()
            }
        }
        Task { @MainActor in
            await tick()
        }
    }

    /// Quit path: dim the chips (they keep the last values) and release sockets.
    func shutdownForQuit() {
        tickTimer?.invalidate()
        tickTimer = nil
        for session in sessions.values {
            session.evaluate("window.__melonChipsSetOffline && window.__melonChipsSetOffline();")
        }
        if !sessions.isEmpty {
            usleep(150_000) // let the fire-and-forget evaluates flush before the sockets close
        }
        for session in sessions.values { session.close() }
        sessions.removeAll()
    }

    /// Disable path: optionally remove the chips from the Codex app and stop everything.
    func stop(disposeChips: Bool) {
        tickTimer?.invalidate()
        tickTimer = nil
        for session in sessions.values {
            if disposeChips {
                session.evaluate("window.__melonChipsDispose && window.__melonChipsDispose();")
            }
            session.close()
        }
        sessions.removeAll()
        injectedLanguage = nil
        injectedPages = 0
        lastInjection = nil
        refreshing = false
        status = .off
        if disposeChips {
            log(L("Chips removed from the Codex app."))
        }
    }

    // MARK: - Tick

    /// UI action: run a discovery pass and verify that chips are really attached.
    func verifyNow() {
        busy = true
        Task { @MainActor in
            await tick()
            await verifyInjected()
            busy = false
        }
    }

    private func tick() async {
        guard enabled else { return }
        guard !Self.scriptSource().isEmpty else {
            status = .failed(L("Composer chips script resource is missing from the app bundle."))
            return
        }
        // A cheap workspace check first: `ps` is a full process-table read, so it
        // only runs when the app is (or may be) around.
        if Self.runningCodexApps().isEmpty {
            if status != .codexNotRunning { status = .codexNotRunning }
            if injectedPages != 0 { injectedPages = 0 }
            noDebugPortSeen = nil
            cachedCodexProcess = nil
            pruneSessions(keep: [])
            return
        }
        guard let process = await codexProcess() else {
            if status != .codexNotRunning { status = .codexNotRunning }
            if injectedPages != 0 { injectedPages = 0 }
            noDebugPortSeen = nil
            pruneSessions(keep: [])
            return
        }
        guard let port = process.debugPort else {
            if status != .noDebugPort { status = .noDebugPort }
            if injectedPages != 0 { injectedPages = 0 }
            pruneSessions(keep: [])
            noteNoDebugPort(pid: process.pid)
            return
        }
        noDebugPortSeen = nil

        let targets = await Self.fetchTargets(port: port)
        guard !targets.isEmpty else {
            status = .failed(L("Codex debug port is open, but no app pages were found."))
            return
        }

        let source = Self.injectionSource()
        let language = L10n.shared.code
        let relanguage = injectedLanguage != nil && injectedLanguage != language
        var keep: [String] = []
        var fresh = 0
        for target in targets {
            keep.append(target.id)
            if let session = sessions[target.id], session.isAlive {
                if relanguage {
                    session.evaluate(source)
                }
                continue
            }
            guard let ws = target.webSocketDebuggerUrl, let wsURL = URL(string: ws) else { continue }
            let session = CDPSession(wsURL: wsURL)
            session.onBinding = { [weak self] name, payload in
                guard name == "__melonSend" else { return }
                Task { @MainActor in self?.handlePageMessage(payload) }
            }
            sessions[target.id] = session
            session.connect(script: source)
            fresh += 1
        }
        pruneSessions(keep: keep)
        for session in sessions.values { session.ping() }
        await refreshPageData()
        pushStatus()

        if fresh > 0 {
            lastInjection = Date()
            log(L("Injected composer chips into") + " \(fresh) — 127.0.0.1:\(port)")
        }
        if relanguage {
            log(L("Re-injected chips after a language change."))
        }
        injectedLanguage = language
        lastAutoManagedRelaunch = nil
        if status != .connected(port: port) { status = .connected(port: port) }
        if injectedPages != sessions.count { injectedPages = sessions.count }
    }

    /// Cached Codex process discovery: the pid/port rarely change, so the full
    /// `ps` read runs at most once per 20 seconds while the process is alive.
    private func codexProcess() async -> CodexProcess? {
        if let cached = cachedCodexProcess,
           Date().timeIntervalSince(cached.at) < 20,
           let app = NSRunningApplication(processIdentifier: pid_t(cached.process.pid)),
           !app.isTerminated {
            return cached.process
        }
        let found = await Self.findCodexProcess()
        cachedCodexProcess = found.map { ($0, Date()) }
        return found
    }

    /// Pushes the pool snapshot into every connected page. The app's CSP blocks
    /// fetches to localhost, so the data travels over the DevTools socket.
    private func pushStatus() {
        guard !sessions.isEmpty else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: statusPayload()),
              let json = String(data: data, encoding: .utf8) else { return }
        for session in sessions.values where session.isAlive {
            session.evaluate("window.__melonChipsSetStatus && window.__melonChipsSetStatus(\(json));")
        }
    }

    // MARK: - Page context and provider data

    /// Thread id of the composer the user is looking at (nil before the first read).
    var activeThreadID: String? { pageContext.threadID }

    /// Reads the visible composer state (selected model, active thread) from
    /// the Codex page, then refreshes the provider and session numbers the
    /// chips render.
    private func refreshPageData() async {
        await readPageContext()
        await providerUsage.refresh()
        await providerUsage.refreshSession(threadUUID: pageContext.threadID)
    }

    private func readPageContext() async {
        // Several page targets exist at once (the main window and a detached
        // window); only one carries a composer. Read them all and keep the
        // richest context instead of trusting a random session.
        let expression = "JSON.stringify(window.__melonChipsContext ? window.__melonChipsContext() : null)"
        var best: (model: String?, threadID: String?, score: Int)?
        for session in sessions.values where session.isAlive {
            guard let response = await session.evaluateWithResult(expression) as? [String: Any],
                  let inner = response["result"] as? [String: Any],
                  let text = inner["value"] as? String,
                  let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let model = object["model"] as? String
            let threadID = object["threadId"] as? String
            let score = (model == nil ? 0 : 2) + (threadID == nil ? 0 : 1)
            if best == nil || score > best!.score {
                best = (model, threadID, score)
            }
        }
        guard let best, best.score > 0 else { return }
        pageContext.model = best.model
        pageContext.threadID = best.threadID
    }

    private func provider(of name: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        if let match = pickerModels.first(where: { $0.name == name }) { return match.provider }
        if let match = pickerModels.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return match.provider
        }
        return nil
    }

    private func sessionPayload(_ snapshot: SessionUsageSnapshot) -> [String: Any] {
        func usage(_ value: SessionTokenUsage) -> [String: Any] {
            [
                "input": value.input,
                "cached": value.cached,
                "cacheWrite": value.cacheWrite,
                "output": value.output,
                "reasoning": value.reasoning,
                "total": value.total,
            ]
        }
        var payload: [String: Any] = [
            "last": usage(snapshot.last),
            "total": usage(snapshot.total),
            "turns": snapshot.turns,
            "matched": snapshot.matchedThread,
        ]
        payload["model"] = snapshot.model ?? NSNull()
        payload["contextWindow"] = snapshot.contextWindow ?? NSNull()
        payload["updatedAt"] = snapshot.updatedAt.map { Int($0.timeIntervalSince1970) } ?? NSNull()
        if let cost = providerUsage.sessionSpend {
            var providers: [String: Any] = [:]
            for (tag, stats) in cost.providers {
                var entry: [String: Any] = [
                    "turns": stats.turns,
                    "tokens": stats.tokens,
                    "input": stats.input,
                    "cached": stats.cached,
                    "output": stats.output,
                    "reasoning": stats.reasoning,
                ]
                entry["usd"] = stats.usd ?? NSNull()
                providers[tag] = entry
            }
            if !providers.isEmpty {
                payload["cost"] = [
                    "total": cost.totalUSD,
                    "providers": providers,
                    "pricedTurns": cost.pricedTurns,
                    "unpricedTurns": cost.unpricedTurns,
                    "scaled": cost.scaled,
                ]
            }
        }
        return payload
    }

    private func providersPayload() -> [String: Any] {
        var payload: [String: Any] = [:]
        if let stats = providerUsage.openRouter {
            var entry: [String: Any] = ["title": "OpenRouter", "isFreeTier": stats.isFreeTier]
            entry["creditsTotal"] = stats.creditsTotal ?? NSNull()
            entry["creditsUsage"] = stats.creditsUsage ?? NSNull()
            entry["creditsRemaining"] = stats.creditsRemaining ?? NSNull()
            entry["keyUsage"] = stats.keyUsage ?? NSNull()
            entry["keyLimit"] = stats.keyLimit ?? NSNull()
            entry["keyRemaining"] = stats.keyRemaining ?? NSNull()
            entry["updatedAt"] = stats.updatedAt.map { Int($0.timeIntervalSince1970) } ?? NSNull()
            entry["error"] = stats.error ?? NSNull()
            payload["openrouter"] = entry
        }
        if let stats = providerUsage.openCode {
            var entry: [String: Any] = ["title": "OpenCode", "modelCount": stats.modelCount]
            entry["workspace"] = stats.workspace ?? NSNull()
            entry["orgID"] = stats.orgID ?? NSNull()
            entry["updatedAt"] = stats.updatedAt.map { Int($0.timeIntervalSince1970) } ?? NSNull()
            entry["error"] = stats.error ?? NSNull()
            payload["opencode"] = entry
        }
        return payload
    }

    /// Messages from the page (currently only the chips refresh button).
    private func handlePageMessage(_ payload: String) {
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = json["action"] as? String else { return }
        if action == "refresh" {
            refreshQuotas()
        }
    }

    private func refreshQuotas() {
        guard !refreshing else { return }
        refreshing = true
        pushStatus() // spins the refresh button in every page
        log(L("Refreshing quotas…"))
        Task { @MainActor in
            await readPageContext()
            await CodexStore.shared.refreshAllQuotas()
            await providerUsage.refresh(force: true)
            await providerUsage.refreshSession(threadUUID: pageContext.threadID)
            refreshing = false
            pushStatus()
            log(L("Quotas refreshed."))
        }
    }

    private func verifyInjected() async {
        var attached = 0
        for session in sessions.values where session.isAlive {
            let expression = "JSON.stringify(window.__melonChipsPing ? window.__melonChipsPing() : null)"
            guard let response = await session.evaluateWithResult(expression) as? [String: Any],
                  let inner = response["result"] as? [String: Any],
                  let text = inner["value"] as? String,
                  text.contains("\"attached\":true") else { continue }
            attached += 1
        }
        injectedPages = attached
        log(L("Verification:") + " \(attached)/\(sessions.count) " + L("pages with active chips"))
    }

    private func pruneSessions(keep: [String]) {
        let keepSet = Set(keep)
        for (id, session) in sessions where !keepSet.contains(id) {
            session.close()
            sessions.removeValue(forKey: id)
        }
    }

    // MARK: - Pool snapshot

    /// Pool snapshot consumed by the injected chips (no tokens, no emails).
    func statusPayload() -> [String: Any] {
        let store = CodexStore.shared
        var groups: [String: (count: Int, quota: Int, five: Double, week: Double, hasQuota: Bool)] = [:]
        var failed = 0
        var paused = 0
        var latest: Date?

        for account in store.accounts {
            let plan = (account.planType?.isEmpty == false ? account.planType! : "unknown").lowercased()
            var group = groups[plan] ?? (count: 0, quota: 0, five: 0, week: 0, hasQuota: false)
            group.count += 1
            if let quota = account.quota {
                let five = quota.hourlyRemainingPercent ?? 0
                let week = quota.weeklyRemainingPercent ?? 0
                group.hasQuota = true
                group.quota += 1
                group.five += five
                group.week += week
                if account.quotaError == nil, five <= 0 || week <= 0 {
                    paused += 1
                }
                if let updated = account.quotaUpdatedAt {
                    if latest == nil || updated > latest! { latest = updated }
                }
            }
            if account.quotaError != nil {
                failed += 1
            }
            groups[plan] = group
        }

        let total = store.accounts.count
        let working = max(0, total - failed - paused)
        let groupList: [[String: Any]] = groups.keys.sorted().map { key in
            let group = groups[key]!
            var dict: [String: Any] = ["plan": key, "count": group.count]
            // Sums = the pool's total capacity: two accounts at 100% read as
            // 200%, which is the number the user actually plans around.
            dict["fiveHour"] = group.hasQuota ? Int(group.five.rounded()) : NSNull()
            dict["weekly"] = group.hasQuota ? Int(group.week.rounded()) : NSNull()
            return dict
        }
        var payload: [String: Any] = [
            "accounts": total,
            "groups": groupList,
            "health": [
                "working": working,
                "total": total,
                "failed": failed,
                "paused": paused,
            ],
            "refreshing": refreshing,
            "updatedAt": Int((latest ?? Date()).timeIntervalSince1970),
            "requests": CodexGatewayService.shared.requestsLastMinute,
            "models": pickerModels.map { ["name": $0.name, "provider": $0.provider, "slug": $0.slug] },
            "providers": providersPayload(),
        ]
        var active: [String: Any] = [:]
        active["model"] = pageContext.model ?? NSNull()
        active["provider"] = provider(of: pageContext.model) ?? NSNull()
        payload["active"] = active
        if let snapshot = providerUsage.sessionUsage {
            payload["session"] = sessionPayload(snapshot)
        }
        return payload
    }

    // MARK: - Codex app discovery

    struct CodexProcess {
        let pid: Int
        let debugPort: Int?
    }

    struct DebugTarget: Decodable {
        let id: String
        let type: String
        let url: String
        let title: String
        let webSocketDebuggerUrl: String?
    }

    static func findCodexProcess() async -> CodexProcess? {
        guard let result = try? await ShellService.run("/bin/ps", ["-axww", "-o", "pid=,command="]) else { return nil }
        for rawLine in result.stdout.split(separator: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard let spaceIndex = trimmed.firstIndex(of: " "),
                  let pid = Int(trimmed[..<spaceIndex]) else { continue }
            let command = String(trimmed[spaceIndex...])
            // The executable must be the Codex app itself. Matching the path
            // anywhere in the line would also catch shell pipelines that only
            // mention it (for example, a `grep ChatGPT.app/Contents/MacOS/ChatGPT`).
            guard let executable = command.split(separator: " ").first,
                  executable.hasSuffix("ChatGPT.app/Contents/MacOS/ChatGPT") else { continue }
            return CodexProcess(pid: pid, debugPort: parseDebugPort(from: command))
        }
        return nil
    }

    private static func parseDebugPort(from command: String) -> Int? {
        guard let range = command.range(of: "--remote-debugging-port=") else { return nil }
        let digits = command[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    static func fetchTargets(port: Int) async -> [DebugTarget] {
        guard let url = URL(string: "http://127.0.0.1:\(port)/json") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let list = try? JSONDecoder().decode([DebugTarget].self, from: data) else { return [] }
        return list.filter { target in
            guard target.type == "page",
                  let ws = target.webSocketDebuggerUrl, !ws.isEmpty,
                  let wsURL = URL(string: ws), wsURL.scheme == "ws" else { return false }
            guard target.url.hasPrefix("app://-/") else { return false }
            guard !target.url.contains("avatar-overlay") else { return false }
            return true
        }
    }

    // MARK: - Relaunch with a debug port

    /// Quits the Codex app (if needed) and relaunches it with a local debug port.
    func relaunchCodexWithDebugPort() {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            let running = Self.runningCodexApps()
            if !running.isEmpty {
                log(L("Quitting the Codex app…"))
                for app in running { app.terminate() }
                var attempts = 0
                while attempts < 20 && !Self.runningCodexApps().isEmpty {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    attempts += 1
                }
                if !Self.runningCodexApps().isEmpty {
                    log(L("The Codex app did not quit — forcing it to close."))
                    for app in Self.runningCodexApps() { app.forceTerminate() }
                    var forced = 0
                    while forced < 10 && !Self.runningCodexApps().isEmpty {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        forced += 1
                    }
                }
                if !Self.runningCodexApps().isEmpty {
                    log(L("The Codex app did not quit — quit it manually and try again."))
                    return
                }
            }
            guard let appURL = Self.codexAppURL() else {
                log(L("ChatGPT.app was not found."))
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            // The CDP endpoint has no authentication: an ephemeral port is a
            // smaller target than a predictable fixed one. Discovery reads the
            // port back from the process command line.
            let debugPort = Self.freeDebugPort() ?? 55522
            configuration.arguments = ["--remote-debugging-address=127.0.0.1", "--remote-debugging-port=\(debugPort)"]
            configuration.activates = true
            log("Codex debug port: \(debugPort)")
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { [weak self] _, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error {
                        self.log(L("Launch failed:") + " \(error.localizedDescription)")
                    } else {
                        self.log(L("Launched the Codex app with a debug port."))
                    }
                }
            }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await tick()
        }
    }

    private static func runningCodexApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { app in
            (app.bundleURL?.path ?? "").hasSuffix("ChatGPT.app")
        }
    }

    /// Ask the kernel for a free loopback port. Returns nil when the probe
    /// fails (the caller then falls back to the historical fixed port).
    static func freeDebugPort() -> Int? {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }
        var result = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &result) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else { return nil }
        let port = UInt16(bigEndian: result.sin_port)
        return port > 0 ? Int(port) : nil
    }

    /// Brings the Codex app forward for the Accounts control card. The app is
    /// restarted when `forceRestart` is true (needed after a route change) or
    /// when it runs without a debug port (chips would not attach otherwise).
    func launchOrActivateCodex(forceRestart: Bool) {
        Task { @MainActor in
            guard let app = Self.runningCodexApps().first else {
                relaunchCodexWithDebugPort()
                return
            }
            if !forceRestart, let process = await Self.findCodexProcess(), process.debugPort != nil {
                app.activate()
                log(L("The Codex app is running — brought it to the front."))
                return
            }
            log(L("Restarting the Codex app to apply the route…"))
            relaunchCodexWithDebugPort()
        }
    }

    /// A Codex app that is running without a debug port — but is otherwise
    /// healthy — leaves the composer without chips. Wait for the same pid to
    /// be seen without a port across two ticks: a quitting app briefly loses
    /// its launch arguments, and that must not trigger a relaunch.
    private func noteNoDebugPort(pid: Int) {
        guard let seen = noDebugPortSeen, seen.pid == pid else {
            noDebugPortSeen = (pid, Date())
            return
        }
        autoRelaunchForManagedRoute()
    }

    /// While this tool owns the Codex route (`melon_local_access`), an app
    /// that keeps running without a debug port — for example, one started
    /// from the Dock — would leave the composer without chips until it is
    /// relaunched by hand. Bring it back under management automatically
    /// (throttled so a broken app cannot cause a relaunch loop).
    private func autoRelaunchForManagedRoute() {
        guard enabled, !busy else { return }
        guard CodexGatewayService.shared.codexRoute == .melon else { return }
        if let last = lastAutoManagedRelaunch, Date().timeIntervalSince(last) < 120 { return }
        lastAutoManagedRelaunch = Date()
        log(L("Codex is running without a debug port — restarting it to attach the chips…"))
        relaunchCodexWithDebugPort()
    }

    private static func codexAppURL() -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            return url
        }
        let fallback = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    // MARK: - Injection payload

    static func injectionSource() -> String {
        let labels: [String: String] = [
            "accounts": L("Accounts"),
            "fiveHour": L("5 h"),
            "week": L("Week"),
            "title": L("Account status"),
            "working": L("Working"),
            "failed": L("Failed"),
            "paused": L("Paused"),
            "refresh": L("Refresh quotas"),
            "context": L("Context"),
            "session": L("Session"),
            "spent": L("Spent"),
            "sessionSpend": L("Session spend (estimate)"),
            "estimatedFrom": L("Estimated from tokens and the model price."),
            "noPricing": L("No pricing data for this model."),
            "scaledNote": L("Older turns are outside the read window; the estimate is scaled."),
            "purchased": L("Purchased"),
            "creditsSpent": L("Credits spent"),
            "available": L("Available"),
            "keyLimit": L("Key limit"),
            "lifetime": L("Lifetime"),
            "keyUsage": L("Key usage"),
            "creditsNote": L("Credits and the key limit are lifetime figures."),
            "sessionNoData": L("Session data appears when a thread runs this provider's models."),
            "remaining": L("Remaining"),
            "credits": L("Credits"),
            "key": L("Key"),
            "cached": L("Cached"),
            "cacheShare": L("Cache"),
            "input": L("Input"),
            "output": L("Output"),
            "reasoning": L("Reasoning"),
            "turns": L("Turns"),
            "workspace": L("Workspace"),
            "models": L("Models"),
            "balance": L("Balance"),
            "balanceUnavailable": L("The provider API does not expose the balance."),
            "freeTier": L("Free tier"),
            "providerData": L("Provider data"),
            "sessionModel": L("Session model"),
            "keyRemaining": L("Key remaining"),
            "requests": L("Requests"),
            "updated": L("Updated"),
            "noData": L("No data"),
            "tokens": L("Tokens"),
            "of": L("of"),
            "yes": L("Yes"),
            "no": L("No"),
        ]
        let config: [String: Any] = [
            "labels": labels,
            "providers": ["openai": "OpenAI", "opencode": "OpenCode", "openrouter": "OpenRouter"],
        ]
        let configJSON = (try? JSONSerialization.data(withJSONObject: config))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "window.__MELON_COMPOSER_CONFIG__ = \(configJSON);\n\(scriptSource())"
    }

    private static var cachedScript: String?

    static func scriptSource() -> String {
        if let cachedScript { return cachedScript }
        var text = ""
        if let url = Bundle.main.url(forResource: "composer-chips", withExtension: "js"),
           let contents = try? String(contentsOf: url, encoding: .utf8) {
            text = contents
        }
        cachedScript = text
        return text
    }

    // MARK: - Log

    private func log(_ line: String) {
        let stamp = Self.timeFormatter.string(from: Date())
        logLines.append("[\(stamp)] \(line)")
        if logLines.count > 120 {
            logLines.removeFirst(logLines.count - 120)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
