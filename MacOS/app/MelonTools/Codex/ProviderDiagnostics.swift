import Combine
import Foundation

/// Read-only provider diagnostics for the Providers page.
///
/// The probe only reads: the gateway model list (`GET /v1/models`), the
/// gateway auth directory, the model-source keys, and the cached quota
/// timestamps. It never writes files, never starts or stops the service, and
/// never touches an auth file.
enum ProviderDiagnostics {
    enum Status: String, Equatable {
        case ok
        case warning
        case failed
        case idle
    }

    /// One entry of the gateway model list. `owner` is the upstream
    /// `owned_by` field (absent for some providers).
    struct ModelEntry: Equatable {
        var id: String
        var owner: String?
    }

    /// Raw evidence gathered by the probe. Pure data so the mapping stays
    /// testable without the file system or the network.
    struct Evidence: Equatable {
        var gatewayStatusCode: Int?
        var gatewayError: String?
        var modelsError: String?
        var authFileNames: [String] = []
        var models: [ModelEntry] = []
        var keys = Keys()
        /// Quota cache timestamps, keyed by provider id.
        var quotaUpdatedAt: [String: Date] = [:]
        /// Quota errors, verbatim as reported by the provider, keyed by id.
        var quotaErrors: [String: String] = [:]

        struct Keys: Equatable {
            var openRouter = false
            var openCode = false
            var claude = false
        }
    }

    struct Row: Equatable, Identifiable {
        var id: String
        var title: String
        var status: Status
        var authFileCount: Int
        var hasKey: Bool
        var modelCount: Int?
        var quotaUpdatedAt: Date?
        var error: String?

        var authPresent: Bool { authFileCount > 0 || hasKey }
    }

    static let ids = ["codex", "claude", "antigravity", "openrouter", "opencode"]

    static func title(for id: String) -> String {
        switch id {
        case "codex": return "Codex pool"
        case "claude": return "Claude"
        case "antigravity": return "Antigravity"
        case "openrouter": return "OpenRouter"
        case "opencode": return "OpenCode"
        default: return id
        }
    }

    // MARK: - Auth files

    static func isCodexAuthFileName(_ name: String) -> Bool {
        name.hasPrefix("codex-") && name.hasSuffix(".json")
    }

    static func isClaudeAuthFileName(_ name: String) -> Bool {
        name.hasPrefix("claude-") && name.hasSuffix(".json")
    }

    static func isAntigravityAuthFileName(_ name: String) -> Bool {
        if name == "antigravity.json" { return true }
        return name.hasPrefix("antigravity-") && name.hasSuffix(".json")
    }

    // MARK: - Models

    /// Antigravity serves `claude-*` and `gemini-*` ids that overlap other
    /// providers; `owned_by` decides when present, the registry otherwise.
    static func isAntigravityModel(id: String, owner: String?) -> Bool {
        if let owner, !owner.isEmpty {
            return owner.caseInsensitiveCompare("antigravity") == .orderedSame
        }
        return AntigravityModelRegistry.ids.contains(id)
    }

    static func isClaudeModel(id: String, owner: String?) -> Bool {
        guard id.hasPrefix("claude-") else { return false }
        return !isAntigravityModel(id: id, owner: owner)
    }

    private static func isOwned(_ entry: ModelEntry, by owner: String) -> Bool {
        guard let value = entry.owner, !value.isEmpty else { return false }
        return value.caseInsensitiveCompare(owner) == .orderedSame
    }

    /// Model count of a provider. Claude and Antigravity use ownership filters;
    /// OpenRouter and OpenCode count their own `owned_by` entries. The pool
    /// keeps every model that no other provider claims.
    static func modelCount(id: String, models: [ModelEntry]) -> Int {
        switch id {
        case "claude":
            return models.filter { isClaudeModel(id: $0.id, owner: $0.owner) }.count
        case "antigravity":
            return models.filter { isAntigravityModel(id: $0.id, owner: $0.owner) }.count
        case "openrouter":
            return models.filter { isOwned($0, by: "openrouter") }.count
        case "opencode":
            return models.filter { isOwned($0, by: "opencode") }.count
        default:
            return models.filter {
                !isClaudeModel(id: $0.id, owner: $0.owner)
                    && !isAntigravityModel(id: $0.id, owner: $0.owner)
                    && !isOwned($0, by: "openrouter")
                    && !isOwned($0, by: "opencode")
            }.count
        }
    }

    // MARK: - Mapping

    /// Pure evidence → rows mapping. A gateway that is not HTTP 200 marks every
    /// row failed and carries the error verbatim; a missing credential is a
    /// warning; a quota error is a warning with the provider text untouched.
    static func rows(_ evidence: Evidence) -> [Row] {
        let gatewayOK = evidence.gatewayStatusCode == 200
        let modelListOK = gatewayOK && evidence.modelsError == nil

        return ids.map { id in
            var row = Row(
                id: id,
                title: title(for: id),
                status: .ok,
                authFileCount: authFileCount(id: id, names: evidence.authFileNames),
                hasKey: hasKey(id: id, keys: evidence.keys),
                modelCount: modelListOK ? modelCount(id: id, models: evidence.models) : nil,
                quotaUpdatedAt: evidence.quotaUpdatedAt[id],
                error: evidence.quotaErrors[id]
            )

            if !gatewayOK {
                row.status = .failed
                if let error = evidence.gatewayError {
                    row.error = error
                } else if let code = evidence.gatewayStatusCode {
                    row.error = "HTTP \(code)"
                }
            } else if let modelsError = evidence.modelsError {
                row.status = .warning
                row.error = modelsError
            } else if !row.authPresent {
                row.status = .warning
            } else if row.error != nil {
                row.status = .warning
            }
            return row
        }
    }

    static func authFileCount(id: String, names: [String]) -> Int {
        switch id {
        case "codex":
            return names.filter(isCodexAuthFileName).count
        case "claude":
            return names.filter(isClaudeAuthFileName).count
        case "antigravity":
            return names.filter(isAntigravityAuthFileName).count
        default:
            return 0
        }
    }

    static func hasKey(id: String, keys: Evidence.Keys) -> Bool {
        switch id {
        case "openrouter": return keys.openRouter
        case "opencode": return keys.openCode
        case "claude": return keys.claude
        default: return false
        }
    }
}

/// Collects the diagnostics evidence once and publishes the mapped rows.
/// Every field is read from existing stores — the probe has no side effects.
@MainActor
final class ProviderDiagnosticsStore: ObservableObject {
    static let shared = ProviderDiagnosticsStore()

    @Published private(set) var evidence: ProviderDiagnostics.Evidence?
    @Published private(set) var isRunning = false
    @Published private(set) var finishedAt: Date?

    private init() {}

    var rows: [ProviderDiagnostics.Row] {
        evidence.map(ProviderDiagnostics.rows) ?? []
    }

    var gatewayOK: Bool { evidence?.gatewayStatusCode == 200 }

    func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let sources = ModelSourcesStore.shared
        let usage = ProviderUsageStore.shared
        let store = CodexStore.shared
        let gateway = CodexGatewayService.shared

        var result = ProviderDiagnostics.Evidence()
        result.authFileNames = Self.authFileNames()
        result.keys = ProviderDiagnostics.Evidence.Keys(
            openRouter: !sources.openRouterKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            openCode: !sources.openCodeKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            claude: !sources.claudeKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )

        var request = URLRequest(url: URL(string: gateway.baseURL + "/v1/models")!)
        request.setValue("Bearer \(gateway.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(ProviderUsageStore.appUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            result.gatewayStatusCode = http?.statusCode
            if http?.statusCode == 200 {
                result.models = (try? Self.decodeModels(data)) ?? []
                if result.models.isEmpty {
                    result.modelsError = L("The service returned an empty model list.")
                }
            } else if let code = http?.statusCode {
                result.gatewayError = "HTTP \(code)"
            }
        } catch {
            result.gatewayError = error.localizedDescription
        }

        result.quotaUpdatedAt["codex"] = store.accounts.compactMap(\.quotaUpdatedAt).max()
        result.quotaErrors["codex"] = store.accounts.first { $0.quotaError != nil }?.quotaError
        if let claude = usage.claude {
            result.quotaUpdatedAt["claude"] = claude.updatedAt
            result.quotaErrors["claude"] = claude.error
        }
        if let antigravity = usage.antigravity {
            result.quotaUpdatedAt["antigravity"] = antigravity.updatedAt
            result.quotaErrors["antigravity"] = antigravity.error
        }
        if let openRouter = usage.openRouter {
            result.quotaUpdatedAt["openrouter"] = openRouter.updatedAt
            result.quotaErrors["openrouter"] = openRouter.error
        }
        if let openCode = usage.openCode {
            result.quotaUpdatedAt["opencode"] = openCode.updatedAt
            result.quotaErrors["opencode"] = openCode.error
        }

        evidence = result
        finishedAt = Date()
    }

    /// Reads the auth dir without creating it: the probe must stay read-only.
    private static func authFileNames() -> [String] {
        let dir = CodexGatewayService.gatewayDir.appendingPathComponent("auths", isDirectory: true)
        return (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    }

    private struct ModelList: Decodable {
        struct Entry: Decodable {
            let id: String
            let owned_by: String?
        }
        let data: [Entry]
    }

    private static func decodeModels(_ data: Data) throws -> [ProviderDiagnostics.ModelEntry] {
        try JSONDecoder().decode(ModelList.self, from: data).data.map {
            ProviderDiagnostics.ModelEntry(id: $0.id, owner: $0.owned_by)
        }
    }
}
