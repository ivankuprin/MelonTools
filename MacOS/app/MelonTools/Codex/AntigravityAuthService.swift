import AppKit
import Combine
import Foundation

/// Google Antigravity integration through the local engine (CLIProxyAPI v8
/// management API): Google-account OAuth login, credential listing/refresh,
/// and the auth files the engine writes.
///
/// The engine performs the OAuth flow and stores the account as
/// `antigravity.json` or `antigravity-<email>.json` in the gateway auth dir
/// (fsnotify hot-reloads it). The app opens the authorization URL in the
/// user's browser, polls the login status, and reads the auth file back for
/// the account email and project id. Antigravity exposes no quota endpoint,
/// so this service deliberately has no usage polling.
@MainActor
final class AntigravityAuthService: ObservableObject {
    static let shared = AntigravityAuthService()

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
        var projectID: String?
        var type: String?
    }

    /// The engine writes `antigravity-<email>.json`, or the bare
    /// `antigravity.json` when the account has no email. Both belong to this
    /// provider; every other file in the auth dir is foreign.
    nonisolated static func isAuthFileName(_ name: String) -> Bool {
        if name == "antigravity.json" { return true }
        return name.hasPrefix("antigravity-") && name.hasSuffix(".json")
    }

    /// Tolerant decode: the engine's auth-file shape varies between versions,
    /// so every field is optional and `type` is only enforced when present.
    nonisolated static func decodeAuthFile(name: String, path: String, data: Data) -> AuthFile? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let type = root["type"] as? String, type != "antigravity" { return nil }
        return AuthFile(
            name: name,
            path: path,
            email: root["email"] as? String,
            accessToken: root["access_token"] as? String,
            projectID: root["project_id"] as? String,
            type: root["type"] as? String
        )
    }

    /// Every Antigravity auth file in `directory`, newest first (mtime desc,
    /// name as tie-breaker) — the account that was just connected wins over an
    /// older leftover file.
    nonisolated static func authFiles(in directory: URL) -> [AuthFile] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        let ordered = names.filter(isAuthFileName).compactMap { name -> (name: String, modified: Date)? in
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

    /// Removes only Antigravity auth files from `directory` and returns their
    /// names. Claude/Codex auth files and foreign files are left untouched.
    @discardableResult
    nonisolated static func deleteAuthFiles(in directory: URL) -> [String] {
        var removed: [String] = []
        for file in authFiles(in: directory) {
            do {
                try FileManager.default.removeItem(atPath: file.path)
                removed.append(file.name)
            } catch {
                continue
            }
        }
        return removed
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

    private var baseURL: String { CodexGatewayService.shared.baseURL }

    private func send(_ request: URLRequest?) async -> (Data, HTTPURLResponse)? {
        guard let request else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return (data, http)
    }

    /// Starts the OAuth flow: asks the engine for the authorization URL,
    /// opens it in the user's browser and polls until the login settles.
    /// The engine listens on its fixed callback port (51121); no web-UI
    /// forwarder is needed for the desktop app.
    func startLogin() async {
        pollTask?.cancel()
        pollTask = nil
        stateToken = nil
        login = .starting
        let request = ClaudeAuthService.managementRequest(
            baseURL: baseURL,
            secret: CodexGatewayService.managementSecret,
            path: "/v8/management/oauth/auth-url?provider=antigravity"
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
            let request = ClaudeAuthService.managementRequest(
                baseURL: baseURL,
                secret: CodexGatewayService.managementSecret,
                path: "/v8/management/oauth/status?state=\(ClaudeAuthService.urlQuery(state))"
            )
            guard let response = await send(request),
                  let status = Self.parseStatusResponse(response.0) else { continue }
            switch status {
            case "ok":
                let email = await waitForAuthFile()
                login = .connected(email: email)
                await ProviderUsageStore.shared.refreshAntigravityNow()
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
            let request = ClaudeAuthService.managementRequest(
                baseURL: baseURL,
                secret: CodexGatewayService.managementSecret,
                path: "/v8/management/oauth/session?state=\(ClaudeAuthService.urlQuery(token))",
                method: "DELETE"
            )
            _ = await send(request)
        }
        login = .idle
    }

    /// Disconnects the account: removes only the engine-written Antigravity
    /// auth files (the engine hot-reloads the auth dir) and resets the login
    /// state. Claude and Codex credentials are untouched.
    func disconnect() {
        pollTask?.cancel()
        pollTask = nil
        stateToken = nil
        Self.deleteAuthFiles(in: CodexGatewayService.authDir)
        login = .idle
    }

    // MARK: - Credentials

    /// `GET /v8/management/credentials` (tolerant shape).
    func credentials() async -> [Credential] {
        let request = ClaudeAuthService.managementRequest(
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
        let request = ClaudeAuthService.managementRequest(
            baseURL: baseURL,
            secret: CodexGatewayService.managementSecret,
            path: path,
            method: "POST",
            body: body
        )
        guard let response = await send(request) else { return false }
        return (200..<300).contains(response.1.statusCode)
    }
}
