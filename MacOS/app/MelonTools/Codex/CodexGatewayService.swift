import Foundation
import Combine

/// Manages the local Codex API gateway (CLIProxyAPI sidecar) — a single shared service.
///
/// Lifecycle rules (v1.1.0):
/// - One instance for the whole app (`shared`): dashboard, API view and menu bar all observe the same state.
/// - Before spawning, the service health-checks the port. A healthy gateway is *adopted*, not duplicated.
/// - PIDs are tracked in `gateway.pid`; stop sends SIGTERM, waits, then SIGKILL.
/// - On app quit the gateway stops only if the "stop on quit" setting is on (default off).
@MainActor
final class CodexGatewayService: ObservableObject {
    static let shared = CodexGatewayService()

    enum Status: Equatable {
        case stopped
        case starting
        case running(baseURL: String)
        case failed(String)

        var label: String {
            switch self {
            case .stopped: return L("stopped")
            case .starting: return L("starting")
            case .running: return L("running")
            case .failed: return L("failed")
            }
        }
    }

    struct GatewayRequest: Identifiable {
        let id = UUID()
        let time: Date
        let method: String
        let path: String
        let status: Int
        let duration: String
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var lastError: String?
    // The request journal and the log tail are NOT published: no view renders
    // them, and every publish would invalidate every observer of the service
    // on each gateway log line (dozens per second under agent load).
    private(set) var logLines: [String] = []
    private(set) var requests: [GatewayRequest] = []
    @Published private(set) var adopted = false
    @Published private(set) var isStarting = false
    @Published private(set) var checkResult: String?
    @Published private(set) var checkPassed = false
    @Published private(set) var isChecking = false

    private var process: Process?
    private var healthTimer: Timer?
    private var logTailTimer: Timer?
    private var logReadOffset: UInt64 = 0
    private var logRemainder = ""
    private var userInitiatedStop = false

    // MARK: - Settings (persisted)

    @Published var port: Int = UserDefaults.standard.object(forKey: "gatewayPort") as? Int ?? 18317 {
        didSet { UserDefaults.standard.set(port, forKey: "gatewayPort") }
    }
    @Published var apiKey: String = CodexGatewayService.loadStoredApiKey() {
        didSet { CodexGatewayService.saveStoredApiKey(apiKey) }
    }

    /// Credential selection strategy (`routing.strategy` in config.yaml) is
    /// fixed to “fill-first”: the account order comes from the auth-file
    /// priorities that the pool planner computes (first account is used
    /// first, the next one takes over automatically).
    static let gatewayRoutingStrategy = "fill-first"

    /// Auth-file collision guard: two accounts whose display names sanitize to
    /// the same string would silently overwrite each other's gateway file and
    /// drop one account from routing. The id suffix makes names unique.
    nonisolated static func authFileName(for account: CodexAccount) -> String {
        let base = account.displayName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let idSuffix = String(account.id.suffix(8))
        return "codex-\(base)-\(idSuffix).json"
    }

    /// Property observers do not fire during initialization, so persist the
    /// initial port explicitly. The key is persisted by its didSet-less init
    /// path via `saveStoredApiKey`.
    init() {
        UserDefaults.standard.set(port, forKey: "gatewayPort")
        CodexGatewayService.saveStoredApiKey(apiKey)
        // Migrate away from the legacy UserDefaults location.
        UserDefaults.standard.removeObject(forKey: "gatewayApiKey")
    }

    /// Stored in a dedicated 0600 file (not UserDefaults / not the world-
    /// readable plist) so the key stays off the default 0644 plist.
    static func apiKeyFile() -> URL {
        CodexStore.supportDir
            .appendingPathComponent("gateway", isDirectory: true)
            .appendingPathComponent("api-key")
    }

    static func loadStoredApiKey() -> String {
        let url = apiKeyFile()
        if let data = SecureFile.read(url),
           let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        // One-time migration from the legacy UserDefaults location.
        if let legacy = UserDefaults.standard.string(forKey: "gatewayApiKey"), !legacy.isEmpty {
            saveStoredApiKey(legacy)
            UserDefaults.standard.removeObject(forKey: "gatewayApiKey")
            return legacy
        }
        return generateKey()
    }

    static func saveStoredApiKey(_ value: String) {
        let url = apiKeyFile()
        try? SecureFile.write(value, to: url)
    }

    /// Management API secret for the sidecar (never empty). Kept next to the
    /// access key with the same 0600 permissions.
    static func managementSecretFile() -> URL {
        CodexStore.supportDir
            .appendingPathComponent("gateway", isDirectory: true)
            .appendingPathComponent("management-secret")
    }

    static let managementSecret: String = {
        let url = managementSecretFile()
        if let data = SecureFile.read(url),
           let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        let generated = "melon-mgmt-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try? SecureFile.write(generated, to: url)
        return generated
    }()

    static func generateKey() -> String {
        "melon-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24)
    }

    var baseURL: String { "http://127.0.0.1:\(port)" }

    // MARK: - Paths

    static var gatewayDir: URL {
        let dir = CodexStore.supportDir.appendingPathComponent("gateway", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var authDir: URL {
        let dir = gatewayDir.appendingPathComponent("auths", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var configPath: String { Self.gatewayDir.appendingPathComponent("config.yaml").path }
    var logPath: String { Self.gatewayDir.appendingPathComponent("gateway.log").path }
    var pidPath: String { Self.gatewayDir.appendingPathComponent("gateway.pid").path }

    /// Locate the sidecar binary: app bundle resources → dev build → PATH.
    static func locateBinary() -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("bin/cliproxyapi").path)
        }
        // Dev fallback — only meaningful on the author's machine, but harmless
        // elsewhere (the path simply will not exist).
        #if DEBUG
        candidates.append(NSString(string: "~/Projects/MelonTools/build/cliproxyapi").expandingTildeInPath)
        #endif
        if let onPath = ShellService.which("cliproxyapi") { candidates.append(onPath) }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    // MARK: - Config generation

    func writeConfig() throws {
        // api-key and paths are escaped: a key containing quotes/colons would
        // otherwise break the YAML and the gateway would never come up.
        var yaml = """
        # Melon Tools — Codex API gateway config (CLIProxyAPI)
        config-version: 8

        server:
          host: "127.0.0.1"
          port: \(port)

        access:
          api-keys:
            - "\(ModelSourcesStore.yamlEscape(apiKey))"

        oauth:
          auth-dir: "\(ModelSourcesStore.yamlEscape(Self.authDir.path))"

        remote-management:
          allow-remote: false
          secret-key: "\(ModelSourcesStore.yamlEscape(Self.managementSecret))"
          disable-control-panel: true
          disable-auto-update-panel: true

        routing:
          strategy: "\(Self.gatewayRoutingStrategy)"

        # Fail over to another account while the leader is cooling down.
        request-retry: 3
        max-retry-interval: 45
        transient-error-cooldown-seconds: 20
        """
        // External model sources (OpenRouter, OpenCode) ride in the same config;
        // the running service hot-reloads the file.
        yaml += ModelSourcesStore.shared.gatewayYAML()
        let data = Data(yaml.utf8)
        try SecureFile.write(data, to: URL(fileURLWithPath: configPath))
    }

    /// Write each vault account as a CLIProxyAPI codex auth file.
    /// `priorities` maps account ids to a routing priority (higher = used sooner).
    func syncAccounts(_ accounts: [CodexAccount], priorities: [String: Int] = [:]) throws {
        let fm = FileManager.default
        if let names = try? fm.contentsOfDirectory(atPath: Self.authDir.path) {
            for name in names where name.hasSuffix(".json") {
                try? fm.removeItem(atPath: Self.authDir.appendingPathComponent(name).path)
            }
        }
        for account in accounts {
            guard let access = account.tokens.access_token, !access.isEmpty else { continue }
            let expired = account.accessTokenExpiry.map { ISO8601DateFormatter().string(from: $0) } ?? ""
            var payload: [String: Any] = [
                "id_token": account.tokens.id_token ?? "",
                "access_token": access,
                "refresh_token": account.tokens.refresh_token ?? "",
                "account_id": account.accountId ?? account.tokens.account_id ?? "",
                "last_refresh": account.lastRefresh ?? ISO8601DateFormatter().string(from: Date()),
                "email": account.email ?? "",
                "type": "codex",
                "expired": expired,
                "plan_type": account.planType ?? "free",
            ]
            if let priority = priorities[account.id], priority > 0 {
                payload["priority"] = priority
            }
            // Accounts the planner pauses — a window is exhausted or the
            // account dropped below the user's reserve — are excluded from
            // gateway routing until the next quota refresh clears the block.
            if CodexRoutingPlanner.blockReason(account) != nil {
                payload["disabled"] = true
            }
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            let fileURL = Self.authDir.appendingPathComponent(Self.authFileName(for: account))
            try SecureFile.write(data, to: fileURL)
        }
    }

    // MARK: - Lifecycle

    /// Start the gateway. If a healthy gateway already owns the port, adopt it instead of spawning a duplicate.
    func start(accounts: [CodexAccount], priorities: [String: Int] = [:], force: Bool = false) async {
        guard !isStarting else { return }
        if !force, isRunning { return }
        isStarting = true
        defer { isStarting = false }
        lastError = nil
        checkResult = nil

        // A (forced) start must not leave the previous process running:
        // spawning again on the same port fails with “address in use”.
        if isRunning { await stop() }

        // 1. Adopt an already-running gateway when it answers our key.
        if !force {
            switch await probeHealth() {
            case .ok:
                // Keep the adopted gateway aligned with the current vault and order.
                try? writeConfig()
                try? syncAccounts(accounts, priorities: priorities)
                adopted = true
                if let adoptedPID = adoptedListenerPID() {
                    writePIDFile(adoptedPID)
                }
                status = .running(baseURL: baseURL)
                auditLog(L("Adopted the running gateway."))
                startHealthCheck()
                startLogTail(replayLastBytes: true)
                return
            case .unauthorized:
                finishWithFailure(L("Port is busy: another service owns it with a different API key. Stop it first or change the port."))
                return
            case .unreachable:
                break
            }
        }

        status = .starting

        // 2. Clean up a stale child recorded in the PID file. The pid is only
        // trusted when it still runs our binary (PID-reuse guard).
        if let stale = Self.verifiedPIDFile(), stale != getpid(), Self.processAlive(stale) {
            auditLog("terminating stale gateway pid \(stale)")
            await terminateProcess(pid: stale, grace: 4)
            removePIDFile()
        } else if readPIDFile() != nil {
            // Stale PID that no longer matches our binary — just drop the file.
            removePIDFile()
        }

        // 3. Spawn.
        guard let binary = Self.locateBinary() else {
            finishWithFailure(L("The service component was not found — reinstall the app."))
            return
        }
        do {
            try writeConfig()
            try syncAccounts(accounts, priorities: priorities)
        } catch {
            finishWithFailure(L("Config write failed") + ": " + error.localizedDescription)
            return
        }
        logLines = []
        spawn(binary: binary)
    }

    func stop() async {
        userInitiatedStop = true
        defer { userInitiatedStop = false }
        healthTimer?.invalidate()
        healthTimer = nil
        logTailTimer?.invalidate()
        logTailTimer = nil
        let pid = process?.processIdentifier ?? Self.verifiedPIDFile() ?? adoptedListenerPID()
        if let pid, pid != getpid() {
            await terminateProcess(pid: pid, grace: 5)
        }
        process?.terminationHandler = nil
        process = nil
        removePIDFile()
        adopted = false
        requests = []
        status = .stopped
    }

    /// Blocking stop used at app termination (SIGTERM → wait → SIGKILL).
    func stopSync() {
        userInitiatedStop = true
        healthTimer?.invalidate()
        healthTimer = nil
        logTailTimer?.invalidate()
        logTailTimer = nil
        let pid = process?.processIdentifier ?? Self.verifiedPIDFile() ?? adoptedListenerPID()
        if let pid, pid != getpid() {
            kill(pid, SIGTERM)
            let deadline = Date().addingTimeInterval(2.5)
            while Date() < deadline, Self.processAlive(pid) {
                usleep(100_000)
            }
            if Self.processAlive(pid) {
                kill(pid, SIGKILL)
            }
        }
        process?.terminationHandler = nil
        process = nil
        removePIDFile()
        adopted = false
        status = .stopped
    }

    func restart(accounts: [CodexAccount], priorities: [String: Int] = [:]) async {
        await stop()
        try? await Task.sleep(nanoseconds: 400_000_000)
        await start(accounts: accounts, priorities: priorities, force: true)
    }

    /// Re-sync account files without stopping (the gateway hot-reloads the auth dir).
    func syncAccountsLive(_ accounts: [CodexAccount], priorities: [String: Int] = [:]) {
        do {
            try syncAccounts(accounts, priorities: priorities)
            auditLog("accounts synced (\(accounts.count))")
        } catch {
            auditLog("account sync failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Routing settings

    /// Applies the pool order: rewrites config.yaml (the strategy itself is
    /// fixed to “fill-first”; the order lives in the auth-file priorities) and
    /// hot-syncs the auth files. A running gateway picks the change up without
    /// a restart.
    func applyRouting(accounts: [CodexAccount], priorities: [String: Int]) async {
        do {
            try writeConfig()
        } catch {
            lastError = L("Config write failed") + ": " + error.localizedDescription
            return
        }
        if isRunning {
            syncAccountsLive(accounts, priorities: priorities)
        } else {
            do {
                try syncAccounts(accounts, priorities: priorities)
            } catch {
                lastError = L("Config write failed") + ": " + error.localizedDescription
                return
            }
        }
        auditLog("routing applied — \(priorities.count) account(s) in the pool")
    }

    // MARK: - Codex app route (~/.codex/config.toml)

    enum CodexRoute: Equatable {
        /// No provider configured — the Codex client talks to OpenAI directly.
        case none
        /// Routed through this gateway.
        case melon
        /// Routed through another local service (for example, Cockpit Tools).
        case other(String)
    }

    static var codexConfigPath: String {
        NSString(string: "~/.codex/config.toml").expandingTildeInPath
    }

    static var codexConfigBackupPath: String {
        codexConfigPath + ".melon-backup"
    }

    private var codexConfigText: String {
        (try? String(contentsOfFile: Self.codexConfigPath, encoding: .utf8)) ?? ""
    }

    var codexRoute: CodexRoute {
        guard let provider = CodexConfigRoute.currentProvider(in: codexConfigText) else { return .none }
        if provider == CodexConfigRoute.providerID { return .melon }
        if provider == "openai" { return .none }
        return .other(provider)
    }

    /// Points the Codex client at this gateway. The previous config is backed
    /// up once, before the first takeover. Returns true when the file changed.
    @discardableResult
    func enableCodexRoute() -> Bool {
        let fm = FileManager.default
        let current = codexConfigText
        var updated = CodexConfigRoute.upsertRoute(in: current, baseURL: baseURL + "/v1", token: apiKey)
        // The Codex app refuses to boot when `model_catalog_json` points at a
        // missing file. Route owners (e.g. Cockpit Tools) clean their catalog
        // up once their route drops, so a stale reference can turn the next
        // app start into a “configuration could not be loaded” dialog. Drop
        // the dangling key — the backup keeps the original line for “remove
        // routing”.
        if let reference = CodexConfigRoute.modelCatalogPath(in: updated), reference.isEmpty == false {
            let configDir = (Self.codexConfigPath as NSString).deletingLastPathComponent
            let resolved = reference.hasPrefix("/")
                ? reference
                : (configDir as NSString).appendingPathComponent(reference)
            if fm.fileExists(atPath: resolved) == false {
                updated = CodexConfigRoute.removingTopLevelKey("model_catalog_json", in: updated)
                auditLog("dropped dangling model_catalog_json (\(reference))")
            }
        }
        guard updated != current else { return false }
        if codexRoute != .melon, fm.fileExists(atPath: Self.codexConfigPath) {
            // Refresh the backup on every takeover so “remove routing” always
            // restores the most recent non-Melon config.
            try? fm.removeItem(atPath: Self.codexConfigBackupPath)
            try? fm.copyItem(atPath: Self.codexConfigPath, toPath: Self.codexConfigBackupPath)
            // The backup carries tokens — never leave it world-readable.
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.codexConfigBackupPath)
        }
        do {
            // The config carries the gateway bearer token — 0600 from creation.
            try SecureFile.write(updated, to: URL(fileURLWithPath: Self.codexConfigPath))
        } catch {
            lastError = L("Could not update the Codex config") + ": " + error.localizedDescription
            return false
        }
        auditLog("codex route enabled → \(CodexConfigRoute.providerID) @ \(baseURL)")
        return true
    }

    /// Restores the pre-takeover config (or strips the Melon route when no
    /// backup exists). Returns true when the file changed.
    @discardableResult
    func disableCodexRoute() -> Bool {
        let fm = FileManager.default
        let current = codexConfigText
        var updated: String
        if let backup = try? String(contentsOfFile: Self.codexConfigBackupPath, encoding: .utf8) {
            updated = backup
        } else {
            updated = CodexConfigRoute.removeRoute(in: current)
        }
        guard updated != current else { return false }
        if updated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? fm.removeItem(atPath: Self.codexConfigPath)
        } else {
            try? SecureFile.write(updated, to: URL(fileURLWithPath: Self.codexConfigPath))
        }
        try? fm.removeItem(atPath: Self.codexConfigBackupPath)
        auditLog("codex route removed")
        return true
    }

    private func spawn(binary: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["-config", configPath]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin"
        p.environment = env

        // Log directly to a file (not a pipe): a pipe would break when the app quits
        // and Go's runtime would kill the child with SIGPIPE on the next log write.
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let logHandle = FileHandle(forWritingAtPath: logPath)
        if let logHandle {
            logHandle.seekToEndOfFile()
            p.standardOutput = logHandle
            p.standardError = logHandle
        } else {
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
        }

        p.terminationHandler = { [weak self] proc in
            logHandle?.closeFile()
            DispatchQueue.main.async {
                guard let self else { return }
                guard !self.userInitiatedStop else { return }
                self.process = nil
                self.healthTimer?.invalidate()
                self.healthTimer = nil
                self.adopted = false
                self.removePIDFile()
                self.status = .failed(self.friendlyExitReason())
            }
        }

        do {
            try p.run()
        } catch {
            finishWithFailure(L("Launch failed") + ": " + error.localizedDescription)
            return
        }
        process = p
        writePIDFile(p.processIdentifier)
        adopted = false
        auditLog("gateway spawned pid \(p.processIdentifier)")
        startHealthCheck()
        startLogTail(replayLastBytes: false)
    }

    private func finishWithFailure(_ message: String) {
        status = .failed(message)
        lastError = message
    }

    /// Map raw exit statuses/log tails to human-readable reasons.
    private func friendlyExitReason() -> String {
        let tail = logLines.suffix(14).joined(separator: "\n").lowercased()
        if tail.contains("address already in use") {
            return L("Port is busy: another service already owns it. Try “Adopt running”.")
        }
        if tail.contains("permission denied") {
            return L("Permission denied while starting the service.")
        }
        if tail.contains("no such file") {
            return L("Service settings are missing — try “Restart”.")
        }
        if tail.contains("invalid config") || (tail.contains("config") && tail.contains("error")) {
            return L("The service rejected its settings — try “Restart”.")
        }
        return L("Service exited")
    }

    // MARK: - Health

    private enum Probe { case ok, unauthorized, unreachable }

    private func probeHealth() async -> Probe {
        var request = URLRequest(url: URL(string: "\(baseURL)/v1/models")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 3
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unreachable }
            if http.statusCode == 200 { return .ok }
            if http.statusCode == 401 || http.statusCode == 403 { return .unauthorized }
            return .unreachable
        } catch {
            return .unreachable
        }
    }

    private func startHealthCheck() {
        healthTimer?.invalidate()
        var misses = 0
        healthTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                switch await self.probeHealth() {
                case .ok:
                    misses = 0
                    if case .running = self.status {} else {
                        self.status = .running(baseURL: self.baseURL)
                    }
                    // Assign only on change: every write invalidates the views.
                    if self.lastError != nil { self.lastError = nil }
                case .unauthorized, .unreachable:
                    misses += 1
                    if self.process == nil, self.adopted, misses >= 3 {
                        self.healthTimer?.invalidate()
                        self.healthTimer = nil
                        self.adopted = false
                        self.status = .failed(L("The running service stopped responding."))
                    }
                }
            }
        }
        healthTimer?.tolerance = 1.0
    }

    /// No-op kept for call-site compatibility; health is driven by the timer.
    func healthCheck() async {
        guard isRunning else { return }
        if case .ok = await probeHealth() {
            // `@Published` publishes on every assignment, even when the value
            // is unchanged: guard so the idle 5s health probe does not
            // invalidate every gateway observer forever.
            if lastError != nil { lastError = nil }
        }
    }

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    /// POST /v1/* requests in the last 60 seconds — the live pool load, parsed
    /// from the gateway log tail. This is what burns the rolling windows.
    var requestsLastMinute: Int {
        let cutoff = Date().addingTimeInterval(-60)
        return requests.filter {
            $0.time >= cutoff && $0.method == "POST" && $0.path.hasPrefix("/v1/")
        }.count
    }

    // MARK: - API check + launch

    /// GET /v1/models plus a tiny chat completion — proves end-to-end request handling.
    func checkAPI() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        checkResult = nil
        checkPassed = false

        guard isRunning else {
            checkResult = L("Service is not running")
            return
        }
        do {
            var listRequest = URLRequest(url: URL(string: "\(baseURL)/v1/models")!)
            listRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            listRequest.timeoutInterval = 8
            let (listData, listResponse) = try await URLSession.shared.data(for: listRequest)
            guard let listHTTP = listResponse as? HTTPURLResponse, listHTTP.statusCode == 200 else {
                let code = (listResponse as? HTTPURLResponse)?.statusCode ?? -1
                checkResult = L("Check failed") + ": HTTP \(code)"
                return
            }
            let listObject = try? JSONSerialization.jsonObject(with: listData) as? [String: Any]
            let models = (listObject?["data"] as? [[String: Any]]) ?? []
            let ids = models.compactMap { $0["id"] as? String }
            // Probe a model that is actually usable right now: a Go-covered
            // OpenCode model or an OpenRouter one. Balance-only OpenCode models
            // (not covered by the Go plan) would answer 402 with an empty
            // console balance and make a healthy gateway look broken.
            let goAliases = Set(ModelSourcesStore.shared.sources
                .filter { $0.kind == .openCode }
                .flatMap { source in source.models.filter { $0.goTier == true }.map(\.alias) })
            let model = ids.first { goAliases.contains($0) }
                ?? ids.first { $0.hasPrefix("openrouter/") }
                ?? ids.first { !$0.lowercased().contains("image") }
                ?? ids.first
                ?? "gpt-5.1-codex-mini"

            let started = Date()
            var chatRequest = URLRequest(url: URL(string: "\(baseURL)/v1/chat/completions")!)
            chatRequest.httpMethod = "POST"
            chatRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            chatRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            chatRequest.timeoutInterval = 90
            chatRequest.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model,
                "messages": [["role": "user", "content": "ping"]],
                "max_tokens": 8,
                "stream": false,
            ])
            let (chatData, chatResponse) = try await URLSession.shared.data(for: chatRequest)
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            guard let chatHTTP = chatResponse as? HTTPURLResponse, (200..<300).contains(chatHTTP.statusCode) else {
                let code = (chatResponse as? HTTPURLResponse)?.statusCode ?? -1
                let snippet = String(data: chatData, encoding: .utf8).map { String($0.prefix(200)) } ?? ""
                checkResult = L("Check failed") + ": HTTP \(code) · \(snippet)"
                return
            }
            let usage = ((try? JSONSerialization.jsonObject(with: chatData)) as? [String: Any])?["usage"] as? [String: Any]
            let tokens = (usage?["total_tokens"] as? Int).map { " · \($0) tokens" } ?? ""
            checkPassed = true
            checkResult = L("Check passed") + " · \(ISODate.duration(elapsedMs)) · \(model)\(tokens)"
        } catch {
            checkResult = L("Check failed") + ": " + error.localizedDescription
        }
    }

    /// One-click “open Codex on this gateway”: starts the service when needed,
    /// points `~/.codex/config.toml` at it, then relaunches the Codex app so
    /// it rereads the route, applies the pool settings and attaches the
    /// composer chips through the debug port.
    ///
    /// Every launch restarts the app (like Cockpit Tools does for its default
    /// instance) — the app always comes up with the current routing.
    func launchCodexApp() async {
        let store = CodexStore.shared
        store.load()
        if !isRunning {
            await start(accounts: store.accounts, priorities: store.effectivePriorities())
        }
        guard isRunning else {
            auditLog(L("Launch failed:") + " " + (lastError ?? L("Service is not running")))
            return
        }
        enableCodexRoute()
        auditLog(L("Launching the Codex app through the service…"))
        ComposerBridge.shared.launchOrActivateCodex(forceRestart: true)
    }

    /// Button wrapper for the API view and Settings.
    func launchThroughGateway() {
        Task { @MainActor in await launchCodexApp() }
    }

    // MARK: - Logs & request journal

    func auditLog(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        logLines.append("[\(stamp)] \(line)")
        trimLog()
    }

    /// Appends a batch of gateway log lines with a single state publish.
    private func ingest(_ newLines: [String]) {
        guard !newLines.isEmpty else { return }
        logLines.append(contentsOf: newLines)
        trimLog()
        var parsed: [GatewayRequest] = []
        for line in newLines {
            if let request = Self.parseRequestLine(line) { parsed.append(request) }
        }
        if !parsed.isEmpty {
            requests.insert(contentsOf: parsed, at: 0)
            if requests.count > 100 {
                requests.removeLast(requests.count - 100)
            }
        }
    }

    private func trimLog() {
        if logLines.count > 800 {
            logLines.removeFirst(logLines.count - 800)
        }
    }

    // MARK: - Log tailing (gateway writes to gateway.log directly)

    /// Follow gateway.log. `replayLastBytes` reads the recent tail first (used when adopting).
    private func startLogTail(replayLastBytes: Bool) {
        logTailTimer?.invalidate()
        logTailTimer = nil
        logRemainder = ""
        let size = Self.fileSize(logPath)
        if replayLastBytes {
            logReadOffset = size > 65536 ? size - 65536 : 0
            readNewLogBytes()
        } else {
            logReadOffset = size
        }
        logTailTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.readNewLogBytes()
            }
        }
        logTailTimer?.tolerance = 0.5
    }

    private func readNewLogBytes() {
        guard let handle = FileHandle(forReadingAtPath: logPath) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < logReadOffset {
            // Log was recreated/truncated.
            logReadOffset = 0
            logRemainder = ""
        }
        guard size > logReadOffset else { return }
        try? handle.seek(toOffset: logReadOffset)
        let data = handle.readDataToEndOfFile()
        logReadOffset = size
        guard let text = String(data: data, encoding: .utf8) else { return }
        let combined = logRemainder + text
        var lines = combined.components(separatedBy: "\n")
        logRemainder = lines.popLast() ?? ""
        let fresh = lines.filter { !$0.isEmpty }
        if !fresh.isEmpty { ingest(fresh) }
    }

    private static func fileSize(_ path: String) -> UInt64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? UInt64 else {
            return 0
        }
        return size
    }

    /// Parse CLIProxyAPI gin logger lines (4+ pipe-separated columns):
    /// `[...] [gin_logger.go:56] 200 | 1.05s | 127.0.0.1 | GET "/v1/models"`
    private static func parseRequestLine(_ line: String) -> GatewayRequest? {
        guard line.contains("gin_logger") || line.contains("[GIN]") else { return nil }
        let parts = line.components(separatedBy: " | ")
        guard parts.count >= 4, let requestPart = parts.last else { return nil }
        let statusToken = parts[0].split(separator: " ").last.map(String.init) ?? ""
        guard let status = Int(statusToken) else { return nil }
        let duration = parts[1].trimmingCharacters(in: .whitespaces)
        guard let firstQuote = requestPart.firstIndex(of: "\""),
              let lastQuote = requestPart.lastIndex(of: "\""),
              firstQuote < lastQuote else { return nil }
        let path = String(requestPart[requestPart.index(after: firstQuote)..<lastQuote])
        let method = String(requestPart[..<firstQuote]).trimmingCharacters(in: .whitespaces)
        guard !method.isEmpty, path.hasPrefix("/") else { return nil }
        return GatewayRequest(time: Date(), method: method, path: path, status: status, duration: duration)
    }

    // MARK: - PID helpers

    private func writePIDFile(_ pid: pid_t?) {
        guard let pid else {
            removePIDFile()
            return
        }
        try? String(pid).write(toFile: pidPath, atomically: true, encoding: .utf8)
    }

    private func readPIDFile() -> pid_t? {
        guard let text = try? String(contentsOfFile: pidPath, encoding: .utf8) else { return nil }
        guard let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return value
    }

    /// PID from the file only when it currently runs our binary — protects
    /// against PID reuse after a reboot.
    private static func verifiedPIDFile() -> pid_t? {
        let path = gatewayDir.appendingPathComponent("gateway.pid").path
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        guard let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        guard isGatewayProcess(pid) else { return nil }
        return pid
    }

    private func removePIDFile() {
        try? FileManager.default.removeItem(atPath: pidPath)
    }

    /// PID of the process listening on our port (covers gateways started outside the app).
    private func listenerPID() -> pid_t? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-tiTCP:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard let first = text.split(separator: "\n").first else { return nil }
        return pid_t(first.trimmingCharacters(in: .whitespaces))
    }

    private static func processAlive(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// True when `pid` runs our gateway binary. Guards against PID reuse
    /// (stale PID file after a reboot) and against killing an unrelated
    /// process that happened to grab our port.
    private static func isGatewayProcess(_ pid: pid_t) -> Bool {
        let maxPath = 4096
        var buffer = [UInt8](repeating: 0, count: maxPath)
        let length = proc_pidpath(pid, &buffer, UInt32(maxPath))
        guard length > 0 else { return false }
        let path = String(cString: buffer)
        if path.hasSuffix("/cliproxyapi") { return true }
        // Adopted gateways may run under a different binary name on a
        // non-standard port; the PID file is only trusted when the process
        // path still exists at all (killed/reaped pids report no path).
        return false
    }

    /// PID of a process listening on our port that is actually our binary.
    private func adoptedListenerPID() -> pid_t? {
        guard let pid = listenerPID(), Self.isGatewayProcess(pid) else { return nil }
        return pid
    }

    private func terminateProcess(pid: pid_t, grace: TimeInterval) async {
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline {
            if !Self.processAlive(pid) { return }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        kill(pid, SIGKILL)
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
}
