import AppKit
import Combine
import Foundation

/// Claude (Anthropic) integration through the local engine (CLIProxyAPI v8
/// management API): OAuth login, credential listing/refresh, and the usage
/// (quota) endpoint.
///
/// The engine performs the OAuth flow and stores the account as
/// `claude-*.json` in the gateway auth dir (fsnotify hot-reloads it). The app
/// opens the authorization URL in the user's browser, polls the login status,
/// and reads the auth file back for the account email and the usage poll.
@MainActor
final class ClaudeAuthService: ObservableObject {
    static let shared = ClaudeAuthService()

    enum LoginState: Equatable {
        case idle
        case starting
        case waiting
        case connected(email: String?)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .starting, .waiting: return true
            default: return false
            }
        }
    }

    @Published private(set) var login: LoginState = .idle

    private var pollTask: Task<Void, Never>?
    private var stateToken: String?

    // MARK: - Auth files (written by the engine into the gateway auth dir)

    struct AuthFile: Equatable {
        var name: String
        var path: String
        var email: String?
        var accessToken: String?
        var type: String?
    }

    nonisolated static func isClaudeAuthFileName(_ name: String) -> Bool {
        name.hasPrefix("claude-") && name.hasSuffix(".json")
    }

    /// Tolerant decode: the engine's auth-file shape varies between versions,
    /// so every field is optional and `type` is only enforced when present.
    nonisolated static func decodeAuthFile(name: String, path: String, data: Data) -> AuthFile? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let type = root["type"] as? String, type != "claude" { return nil }
        return AuthFile(
            name: name,
            path: path,
            email: root["email"] as? String,
            accessToken: root["access_token"] as? String,
            type: root["type"] as? String
        )
    }

    /// Every `claude-*.json` in `directory`, newest first (mtime desc, name as
    /// tie-breaker) — the account that was just connected wins over an older
    /// leftover file.
    nonisolated static func authFiles(in directory: URL) -> [AuthFile] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        let ordered = names.filter(isClaudeAuthFileName).compactMap { name -> (name: String, modified: Date)? in
            let url = directory.appendingPathComponent(name)
            guard let attributes = try? fm.attributesOfItem(atPath: url.path) else { return nil }
            let modified = (attributes[.modificationDate] as? Date) ?? .distantPast
            return (name, modified)
        }
        .sorted { lhs, rhs in
            if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }
            return lhs.name < rhs.name
        }
        return ordered.compactMap { entry in
            let url = directory.appendingPathComponent(entry.name)
            guard let data = try? Data(contentsOf: url) else { return nil }
            return decodeAuthFile(name: entry.name, path: url.path, data: data)
        }
    }

    /// Auth files in the live gateway auth dir.
    static func authFiles() -> [AuthFile] {
        authFiles(in: CodexGatewayService.authDir)
    }

    // MARK: - OAuth login (engine-managed)

    /// Response of `GET /v8/management/oauth/auth-url`.
    struct AuthURLResponse: Equatable {
        var url: String
        var state: String?
    }

    nonisolated static func parseAuthURLResponse(_ data: Data) -> AuthURLResponse? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let url = (root["url"] as? String) ?? (root["auth_url"] as? String) ?? ""
        guard !url.isEmpty else { return nil }
        return AuthURLResponse(url: url, state: root["state"] as? String)
    }

    /// `{status: "ok"|"wait"|"error"}` — the login status itself.
    nonisolated static func parseStatusResponse(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return root["status"] as? String
    }

    /// `GET /v8/management/credentials` — tolerant: entries may sit at the
    /// root or under a wrapper key, and `name` may be spelled differently.
    struct Credential: Equatable {
        var name: String
        var type: String?
        var email: String?
    }

    nonisolated static func parseCredentials(_ data: Data) -> [Credential] {
        let object = try? JSONSerialization.jsonObject(with: data)
        var items: [[String: Any]] = []
        if let array = object as? [[String: Any]] {
            items = array
        } else if let root = object as? [String: Any] {
            for key in ["credentials", "files", "items", "data"] {
                if let array = root[key] as? [[String: Any]] {
                    items = array
                    break
                }
            }
        }
        return items.compactMap { entry in
            let name = (entry["name"] as? String)
                ?? (entry["file"] as? String)
                ?? (entry["file_name"] as? String)
                ?? (entry["filename"] as? String)
            guard let name, !name.isEmpty else { return nil }
            return Credential(name: name, type: entry["type"] as? String, email: entry["email"] as? String)
        }
    }

    // MARK: - Management API plumbing

    nonisolated static func managementRequest(baseURL: String, secret: String, path: String, method: String = "GET", body: Data? = nil) -> URLRequest? {
        guard let url = URL(string: baseURL + path) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        // The engine accepts either header; both are sent so the app is
        // robust against middleware variants.
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue(secret, forHTTPHeaderField: "X-Management-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.timeoutInterval = 15
        return request
    }

    nonisolated static func urlQuery(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    private var baseURL: String { CodexGatewayService.shared.baseURL }

    private func send(_ request: URLRequest?) async -> (Data, HTTPURLResponse)? {
        guard let request else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return (data, http)
    }

    /// Starts the OAuth flow: asks the engine for the authorization URL,
    /// opens it in the user's browser and polls until the login settles.
    /// `is_webui=true` is required — it activates the engine callback
    /// forwarder on port 54545.
    func startLogin() async {
        pollTask?.cancel()
        pollTask = nil
        stateToken = nil
        login = .starting
        let request = Self.managementRequest(
            baseURL: baseURL,
            secret: CodexGatewayService.managementSecret,
            path: "/v8/management/oauth/auth-url?provider=claude&is_webui=true"
        )
        guard let response = await send(request), response.1.statusCode == 200,
              let payload = Self.parseAuthURLResponse(response.0) else {
            login = .failed(L("Could not reach the service — start it first."))
            return
        }
        guard let url = URL(string: payload.url) else {
            login = .failed(L("The service returned an invalid login URL."))
            return
        }
        NSWorkspace.shared.open(url)
        stateToken = payload.state
        login = .waiting
        let state = payload.state ?? ""
        pollTask = Task { [weak self] in
            await self?.poll(state: state)
        }
    }

    private func poll(state: String) async {
        let deadline = Date().addingTimeInterval(900)
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled { return }
            if Date() > deadline {
                login = .failed(L("The login timed out — try again."))
                return
            }
            let request = Self.managementRequest(
                baseURL: baseURL,
                secret: CodexGatewayService.managementSecret,
                path: "/v8/management/oauth/status?state=\(Self.urlQuery(state))"
            )
            guard let response = await send(request),
                  let status = Self.parseStatusResponse(response.0) else { continue }
            switch status {
            case "ok":
                let email = await waitForAuthFile()
                login = .connected(email: email)
                await ProviderUsageStore.shared.refreshClaudeNow()
                return
            case "error":
                login = .failed(L("The service rejected the login."))
                return
            default:
                continue
            }
        }
    }

    /// After `ok` the engine writes the auth file asynchronously — give it a
    /// moment before reading the account email back.
    private func waitForAuthFile() async -> String? {
        for _ in 0..<12 {
            if let file = Self.authFiles().first { return file.email }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return nil
    }

    /// Cancels an in-flight login: stops polling and tells the engine to drop
    /// the session.
    func cancelLogin() async {
        pollTask?.cancel()
        pollTask = nil
        let token = stateToken
        stateToken = nil
        if let token, !token.isEmpty {
            let request = Self.managementRequest(
                baseURL: baseURL,
                secret: CodexGatewayService.managementSecret,
                path: "/v8/management/oauth/session?state=\(Self.urlQuery(token))",
                method: "DELETE"
            )
            _ = await send(request)
        }
        login = .idle
    }

    /// Disconnects the account: removes the engine-written auth files (the
    /// engine hot-reloads the auth dir) and resets the login state.
    func disconnect() {
        pollTask?.cancel()
        pollTask = nil
        stateToken = nil
        for file in Self.authFiles() {
            try? FileManager.default.removeItem(atPath: file.path)
        }
        login = .idle
    }

    // MARK: - Credentials

    /// `GET /v8/management/credentials` (tolerant shape).
    func credentials() async -> [Credential] {
        let request = Self.managementRequest(
            baseURL: baseURL,
            secret: CodexGatewayService.managementSecret,
            path: "/v8/management/credentials"
        )
        guard let response = await send(request), response.1.statusCode == 200 else { return [] }
        return Self.parseCredentials(response.0)
    }

    /// Refreshes one credential file (`{"name": …}`), or all of them
    /// (`?all=true`) when no name is given.
    @discardableResult
    func refreshCredential(name: String? = nil) async -> Bool {
        var path = "/v8/management/credentials/refresh"
        var body: Data?
        if let name, !name.isEmpty {
            body = try? JSONSerialization.data(withJSONObject: ["name": name])
        } else {
            path += "?all=true"
        }
        let request = Self.managementRequest(
            baseURL: baseURL,
            secret: CodexGatewayService.managementSecret,
            path: path,
            method: "POST",
            body: body
        )
        guard let response = await send(request) else { return false }
        return (200..<300).contains(response.1.statusCode)
    }

    // MARK: - Usage (quota)

    /// Quota snapshot: every field is optional — absent data renders as “—”.
    /// Percent values are the share of the window still *available* (0…100);
    /// the endpoint reports the used share and the parser converts it.
    struct UsageSnapshot: Equatable {
        var fiveHourPercent: Double?
        var fiveHourReset: Date?
        var weeklyPercent: Double?
        var weeklyReset: Date?
        var plan: String?
    }

    enum UsageError: Error {
        case unauthorized
    }

    nonisolated static func usageRequest(token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Anthropic answers 429 without a Claude-Code-style user agent.
        request.setValue("claude-code/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        return request
    }

    nonisolated static func fetchUsage(token: String) async throws -> UsageSnapshot? {
        let (data, response) = try await URLSession.shared.data(for: usageRequest(token: token))
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 401 || http.statusCode == 403 { throw UsageError.unauthorized }
        guard http.statusCode == 200 else { return nil }
        return parseUsage(data)
    }

    /// Usage with one recovery on 401: refresh the engine credential, re-read
    /// the auth file and retry once; otherwise degrade to nil (“—”).
    func usageSnapshot() async -> UsageSnapshot? {
        guard let file = Self.authFiles().first, let token = file.accessToken, !token.isEmpty else { return nil }
        do {
            return try await Self.fetchUsage(token: token)
        } catch UsageError.unauthorized {
            _ = await refreshCredential(name: file.name)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let refreshed = Self.authFiles().first,
                  let freshToken = refreshed.accessToken, !freshToken.isEmpty else { return nil }
            return try? await Self.fetchUsage(token: freshToken)
        } catch {
            return nil
        }
    }

    /// Tolerant parser for both endpoint shapes: legacy
    /// (`five_hour`/`seven_day` with `utilization`) and newer (`limits[]`
    /// with `kind: session|weekly_all|weekly_scoped` and `percent`).
    nonisolated static func parseUsage(_ data: Data) -> UsageSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var snapshot = UsageSnapshot()
        if let five = root["five_hour"] as? [String: Any] {
            snapshot.fiveHourPercent = remainingPercent(five["utilization"])
            snapshot.fiveHourReset = date(five["resets_at"])
        }
        if let seven = root["seven_day"] as? [String: Any] {
            snapshot.weeklyPercent = remainingPercent(seven["utilization"])
            snapshot.weeklyReset = date(seven["resets_at"])
        }
        if let limits = root["limits"] as? [[String: Any]] {
            for limit in limits {
                switch limit["kind"] as? String {
                case "session":
                    if snapshot.fiveHourPercent == nil { snapshot.fiveHourPercent = remainingPercent(limit["percent"]) }
                    if snapshot.fiveHourReset == nil { snapshot.fiveHourReset = date(limit["resets_at"]) }
                case "weekly_all":
                    if snapshot.weeklyPercent == nil { snapshot.weeklyPercent = remainingPercent(limit["percent"]) }
                    if snapshot.weeklyReset == nil { snapshot.weeklyReset = date(limit["resets_at"]) }
                default:
                    // `weekly_scoped` windows are per-model and not shown.
                    break
                }
            }
        }
        // The payload may carry a plan name; when it does not, the UI shows
        // “—” instead of inventing one.
        snapshot.plan = (root["subscriptionType"] as? String)
            ?? (root["subscription_type"] as? String)
            ?? (root["plan"] as? String)
        let hasData = snapshot.fiveHourPercent != nil || snapshot.weeklyPercent != nil || snapshot.plan != nil
        return hasData ? snapshot : nil
    }

    /// `utilization`/`percent` count the *used* share; the app shows what is
    /// left. Values outside 0…100 clamp; non-numeric input stays nil.
    nonisolated static func remainingPercent(_ value: Any?) -> Double? {
        guard let used = number(value) else { return nil }
        return min(100, max(0, 100 - used))
    }

    nonisolated static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    /// ISO-8601 (with or without fractional seconds) or epoch seconds.
    nonisolated static func date(_ value: Any?) -> Date? {
        if let string = value as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = fractional.date(from: string) { return parsed }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: string)
        }
        guard let seconds = number(value) else { return nil }
        // Reject absurd epochs (milliseconds would land far in the future).
        guard seconds > 1_000_000_000, seconds < 4_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
