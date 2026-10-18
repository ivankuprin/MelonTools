import Foundation
import Combine

/// A model source is an upstream provider registered in the Melon gateway
/// (`api-keys.openai-compatibility`). Both sources are connected by an API key
/// the user pastes: OpenRouter and the OpenCode Console API.
///
/// OpenCode Console serves every model family (GPT, Claude, Gemini, GLM, …)
/// through its OpenAI-compatible surface, so one upstream entry is enough.
struct ModelSource: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case openRouter
        case openCode
    }

    var id: String
    var kind: Kind
    var title: String
    var baseURL: String
    var apiKey: String
    var enabled: Bool
    var models: [SourceModel]

    var selectedModels: [SourceModel] { models.filter(\.enabled) }
}

/// One model inside a source. `id` is the upstream model name; `alias` is the
/// name the Codex app uses (and which the gateway maps back to `id`).
struct SourceModel: Identifiable, Codable, Equatable {
    var id: String
    var display: String
    var contextLength: Int?
    var enabled: Bool
    var alias: String
    /// Free-tier OpenCode models are blocked outside the OpenCode app itself.
    var freeTier: Bool?
    /// USD per token from the provider model list (OpenRouter exposes these).
    var promptPerToken: Double?
    var completionPerToken: Double?
    var cacheReadPerToken: Double?
    /// OpenCode: the model is served by the Go subscription endpoints.
    var goTier: Bool?
}

/// Model sources: OpenRouter and OpenCode, both key-based. Persists user
/// choices in `~/Library/Application Support/MelonTools/model-sources.json`
/// (0600) and renders the gateway `api-keys.openai-compatibility` block.
@MainActor
final class ModelSourcesStore: ObservableObject {
    static let shared = ModelSourcesStore()

    // OpenCode Console: the account model list and the OpenAI-compatible
    // inference surface that fronts every model family.
    static let openCodeModelsURL = "https://opencode.ai/inference/v1/models"
    static let openCodeBaseURL = "https://opencode.ai/inference/openai/v1"
    /// Go subscription surface: models listed here are billed against the Go
    /// plan instead of the console balance, and the endpoint requires the
    /// `x-opencode-session` header.
    static let openCodeGoModelsURL = "https://opencode.ai/inference/go/v1/models"
    static let openCodeGoBaseURL = "https://opencode.ai/inference/go/openai/v1"
    static let openRouterModelsURL = "https://openrouter.ai/api/v1/models"
    static let openRouterBaseURL = "https://openrouter.ai/api/v1"

    @Published private(set) var sources: [ModelSource] = []
    @Published var openRouterKey: String = ""
    @Published var openCodeKey: String = ""
    @Published private(set) var note: String?
    @Published private(set) var isBusy = false
    @Published private(set) var lastApply: String?

    private let fm = FileManager.default
    private var lastPriceHydration = Date.distantPast
    private var lastGoAccessRefresh = Date.distantPast

    var storeURL: URL { CodexStore.supportDir.appendingPathComponent("model-sources.json") }

    private struct Persisted: Codable {
        var openRouterKey: String?
        var openCodeKey: String?
        var sources: [ModelSource]?
    }

    /// Fallback that keeps the pasted keys when an older store cannot decode.
    private struct PersistedKeys: Codable {
        var openRouterKey: String?
        var openCodeKey: String?
    }

    private init() {
        load()
    }

    // MARK: - Persistence

    func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        if let persisted = try? JSONDecoder().decode(Persisted.self, from: data) {
            openRouterKey = persisted.openRouterKey ?? ""
            openCodeKey = persisted.openCodeKey ?? ""
            sources = persisted.sources ?? []
            migrateOpenRouterAliases()
            return
        }
        if let keys = try? JSONDecoder().decode(PersistedKeys.self, from: data) {
            openRouterKey = keys.openRouterKey ?? ""
            openCodeKey = keys.openCodeKey ?? ""
        }
    }

    func save() {
        let persisted = Persisted(openRouterKey: openRouterKey, openCodeKey: openCodeKey, sources: sources)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(persisted) else { return }
        try? SecureFile.write(data, to: storeURL)
    }

    /// Stores written before 1.4.1 kept the raw OpenRouter id as the alias; the
    /// `openrouter/` prefix is what routes those models to the price sorting
    /// rule in the gateway config.
    private func migrateOpenRouterAliases() {
        guard let index = sources.firstIndex(where: { $0.kind == .openRouter }) else { return }
        var source = sources[index]
        var changed = false
        for modelIndex in source.models.indices {
            let model = source.models[modelIndex]
            guard !model.alias.hasPrefix(Self.openRouterAliasPrefix) else { continue }
            source.models[modelIndex].alias = Self.openRouterAlias(model.id)
            changed = true
        }
        guard changed else { return }
        sources[index] = source
        save()
    }

    // MARK: - Queries

    var openRouterSource: ModelSource? { sources.first { $0.id == "openrouter" } }

    var openCodeSource: ModelSource? { sources.first { $0.id == "opencode" } }

    func source(id: String) -> ModelSource? { sources.first { $0.id == id } }

    var selectedCount: Int { sources.reduce(0) { $0 + $1.selectedModels.count } }

    /// Price row for a model name from the Codex picker (display name, alias or
    /// upstream id). Feeds the session-cost estimate.
    ///
    /// Attribution order matters: pool models come first (a slug like
    /// `gpt-6.1-sol` is also served by OpenCode — without this check its turns
    /// would be billed to the OpenCode session stats), then the exact gateway
    /// alias, then the upstream id, then the display name.
    func priceRow(for name: String) -> (kind: ModelSource.Kind, model: SourceModel)? {
        let lowered = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !lowered.isEmpty else { return nil }
        let poolMatches = CodexModelCatalog.basePickerModels().contains {
            $0.slug.lowercased() == lowered || $0.name.lowercased() == lowered
        }
        if poolMatches { return nil }
        for source in sources where source.enabled {
            if let model = source.models.first(where: { $0.alias.lowercased() == lowered }) {
                return (source.kind, model)
            }
        }
        for source in sources where source.enabled {
            if let model = source.models.first(where: { $0.id.lowercased() == lowered }) {
                return (source.kind, model)
            }
        }
        for source in sources where source.enabled {
            if let model = source.models.first(where: { $0.display.lowercased() == lowered }) {
                return (source.kind, model)
            }
        }
        return nil
    }

    // MARK: - Mutation helpers

    func setSourceEnabled(_ id: String, enabled: Bool) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].enabled = enabled
        save()
    }

    func setModel(_ sourceId: String, modelId: String, enabled: Bool) {
        guard let sIndex = sources.firstIndex(where: { $0.id == sourceId }),
              let mIndex = sources[sIndex].models.firstIndex(where: { $0.id == modelId }) else { return }
        sources[sIndex].models[mIndex].enabled = enabled
        save()
    }

    func setAllModels(_ sourceId: String, enabled: Bool, matching query: String = "") {
        guard let sIndex = sources.firstIndex(where: { $0.id == sourceId }) else { return }
        for mIndex in sources[sIndex].models.indices {
            if query.isEmpty || sources[sIndex].models[mIndex].id.localizedCaseInsensitiveContains(query)
                || sources[sIndex].models[mIndex].display.localizedCaseInsensitiveContains(query) {
                sources[sIndex].models[mIndex].enabled = enabled
            }
        }
        save()
    }

    private func replace(_ source: ModelSource) {
        if let index = sources.firstIndex(where: { $0.id == source.id }) {
            sources[index] = source
        } else {
            sources.append(source)
        }
    }

    // MARK: - Model lists

    /// OpenRouter publishes per-token prices in its public model list. Stores
    /// written before pricing existed have `nil` prices, so the estimate fills
    /// them in on demand (no key needed) and saves the store once. Attempts are
    /// throttled: a model that has no price upstream must not re-fetch forever.
    func hydrateOpenRouterPrices() async {
        guard let index = sources.firstIndex(where: { $0.kind == .openRouter }) else { return }
        let needsPrices = sources[index].models.contains {
            $0.promptPerToken == nil || $0.completionPerToken == nil
        }
        guard needsPrices else { return }
        guard Date().timeIntervalSince(lastPriceHydration) >= 1800 else { return }
        lastPriceHydration = Date()
        guard let entries = try? await fetchModels(url: Self.openRouterModelsURL, key: "", userAgent: "MelonTools/1.4") else { return }
        var pricingById: [String: ModelList.Pricing] = [:]
        for entry in entries {
            if let pricing = entry.pricing { pricingById[entry.id] = pricing }
        }
        var changed = false
        for modelIndex in sources[index].models.indices {
            let id = sources[index].models[modelIndex].id
            guard let pricing = pricingById[id] else { continue }
            if sources[index].models[modelIndex].promptPerToken == nil, let value = pricing.prompt?.value {
                sources[index].models[modelIndex].promptPerToken = value
                changed = true
            }
            if sources[index].models[modelIndex].completionPerToken == nil, let value = pricing.completion?.value {
                sources[index].models[modelIndex].completionPerToken = value
                changed = true
            }
            if sources[index].models[modelIndex].cacheReadPerToken == nil, let value = pricing.input_cache_read?.value {
                sources[index].models[modelIndex].cacheReadPerToken = value
                changed = true
            }
        }
        if changed { save() }
    }

    /// Marks which OpenCode models the Go plan covers. Runs at launch (before
    /// the gateway writes its config); throttled so a failing call cannot spin.
    func refreshOpenCodeGoAccess() async {
        guard let index = sources.firstIndex(where: { $0.kind == .openCode }) else { return }
        let key = openCodeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let needsFlags = sources[index].models.contains { $0.goTier == nil }
        guard needsFlags || Date().timeIntervalSince(lastGoAccessRefresh) >= 1800 else { return }
        lastGoAccessRefresh = Date()
        guard let entries = try? await fetchModels(url: Self.openCodeGoModelsURL, key: key, userAgent: "MelonTools/1.4") else { return }
        let goIds = Set(entries.map(\.id))
        var changed = false
        for modelIndex in sources[index].models.indices {
            let flag = goIds.contains(sources[index].models[modelIndex].id)
            if sources[index].models[modelIndex].goTier != flag {
                sources[index].models[modelIndex].goTier = flag
                changed = true
            }
        }
        if changed { save() }
    }

    private struct ModelList: Decodable {
        /// Provider prices arrive as strings (`"0.000003"`) or numbers.
        struct FlexibleNumber: Decodable {
            let value: Double?
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let double = try? container.decode(Double.self) {
                    value = double
                } else if let string = try? container.decode(String.self) {
                    value = Double(string)
                } else {
                    value = nil
                }
            }
        }
        struct Pricing: Decodable {
            let prompt: FlexibleNumber?
            let completion: FlexibleNumber?
            let input_cache_read: FlexibleNumber?
        }
        struct Entry: Decodable {
            let id: String
            let name: String?
            let context_length: Int?
            let pricing: Pricing?
        }
        let data: [Entry]
    }

    private func fetchModels(url: String, key: String, userAgent: String?) async throws -> [ModelList.Entry] {
        var request = URLRequest(url: URL(string: url)!)
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.userAuthenticationRequired)
        }
        return try JSONDecoder().decode(ModelList.self, from: data).data
    }

    // MARK: - OpenRouter (API key)

    /// Every OpenRouter model is aliased with this prefix, so the gateway
    /// payload rules (`openrouter/*`) and the picker grouping can tell the
    /// provider apart from the account pool and from OpenCode.
    static let openRouterAliasPrefix = "openrouter/"

    nonisolated static func openRouterAlias(_ id: String) -> String {
        id.hasPrefix(openRouterAliasPrefix) ? id : openRouterAliasPrefix + id
    }

    func loadOpenRouterModels() async {
        let key = openRouterKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            note = L("Enter an OpenRouter key first.")
            return
        }
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let entries = try await fetchModels(url: Self.openRouterModelsURL, key: key, userAgent: nil)
            mergeOpenRouter(entries: entries, key: key)
            note = String(format: L("OpenRouter: %d models"), entries.count)
        } catch {
            note = L("OpenRouter did not accept the key.")
        }
    }

    private func mergeOpenRouter(entries: [ModelList.Entry], key: String) {
        let existing = openRouterSource
        var enabledById: [String: Bool] = [:]
        for model in existing?.models ?? [] { enabledById[model.id] = model.enabled }
        let models = entries
            .map {
                SourceModel(
                    id: $0.id,
                    display: $0.name ?? $0.id,
                    contextLength: $0.context_length,
                    enabled: enabledById[$0.id] ?? false,
                    alias: Self.openRouterAlias($0.id),
                    freeTier: nil,
                    promptPerToken: $0.pricing?.prompt?.value,
                    completionPerToken: $0.pricing?.completion?.value,
                    cacheReadPerToken: $0.pricing?.input_cache_read?.value
                )
            }
            .sorted { $0.id.lowercased() < $1.id.lowercased() }
        replace(ModelSource(
            id: "openrouter",
            kind: .openRouter,
            title: "OpenRouter",
            baseURL: Self.openRouterBaseURL,
            apiKey: key,
            enabled: existing?.enabled ?? true,
            models: models
        ))
        openRouterKey = key
        save()
    }

    // MARK: - OpenCode (API key)

    func loadOpenCodeModels() async {
        let key = openCodeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            note = L("Enter an OpenCode key first.")
            return
        }
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let entries = try await fetchModels(url: Self.openCodeModelsURL, key: key, userAgent: "MelonTools/1.4")
            // Go-eligible models must ride the /go endpoints; the generic
            // surface rejects them with “Insufficient account funds”.
            let goEntries = try? await fetchModels(url: Self.openCodeGoModelsURL, key: key, userAgent: "MelonTools/1.4")
            var goIds: Set<String>?
            if let goEntries {
                goIds = Set(goEntries.map(\.id))
            }
            mergeOpenCode(entries: entries, key: key, goIds: goIds)
            note = String(format: L("OpenCode: %d models"), entries.count)
        } catch {
            note = L("OpenCode did not accept the key.")
        }
    }

    private func mergeOpenCode(entries: [ModelList.Entry], key: String, goIds: Set<String>?) {
        let existing = openCodeSource
        var enabledById: [String: Bool] = [:]
        var goById: [String: Bool] = [:]
        for model in existing?.models ?? [] {
            enabledById[model.id] = model.enabled
            if let go = model.goTier { goById[model.id] = go }
        }
        let models = entries
            .map { entry in
                SourceModel(
                    id: entry.id,
                    display: entry.name ?? Self.prettyName(entry.id),
                    contextLength: entry.context_length,
                    enabled: enabledById[entry.id] ?? false,
                    alias: "opencode/\(entry.id)",
                    freeTier: Self.isFreeTier(entry.id),
                    goTier: goIds.map { $0.contains(entry.id) } ?? goById[entry.id]
                )
            }
            .sorted { $0.id.lowercased() < $1.id.lowercased() }
        replace(ModelSource(
            id: "opencode",
            kind: .openCode,
            title: "OpenCode",
            baseURL: Self.openCodeBaseURL,
            apiKey: key,
            enabled: existing?.enabled ?? true,
            models: models
        ))
        openCodeKey = key
        save()
    }

    /// Turns a raw OpenCode model id into a readable name
    /// (`claude-opus-5-5` → `Claude Opus 5.5`).
    nonisolated static func prettyName(_ id: String) -> String {
        let dotted = id.replacingOccurrences(
            of: "(?<=[0-9])-([0-9]+)(?=$|-)",
            with: ".$1",
            options: .regularExpression
        )
        let brands: [(String, String)] = [
            ("glm", "GLM"), ("gpt", "GPT"), ("ll", "LL"), ("vl", "VL"), ("mimo", "MiMo"),
            ("kimi", "Kimi"), ("qwen", "Qwen"), ("minimax", "MiniMax"), ("deepseek", "DeepSeek"),
            ("claude", "Claude"), ("gemini", "Gemini"), ("grok", "Grok"), ("muse", "Muse"),
            ("mistral", "Mistral"), ("nemotron", "Nemotron"), ("longcat", "LongCat"),
            ("space", "Space"), ("bunny", "Bunny"), ("beam", "Beam"), ("exo", "Exo"),
            ("big", "Big"), ("pickle", "Pickle"), ("jev", "Jev"),
        ]
        let tokens = dotted.split(separator: "-").map { token -> String in
            let lower = token.lowercased()
            for (prefix, brand) in brands where lower.hasPrefix(prefix) {
                return brand + token.dropFirst(prefix.count)
            }
            return token.prefix(1).uppercased() + token.dropFirst()
        }
        return tokens.joined(separator: " ")
    }

    /// Free-tier models answer with `FreeTierError` outside the OpenCode app.
    nonisolated static func isFreeTier(_ id: String) -> Bool {
        id.hasSuffix("-free") || id == "big-pickle" || id == "test"
    }

    // MARK: - Gateway YAML

    /// Headers for the OpenCode endpoints: the Go surface rejects requests
    /// without `x-opencode-session`, and the docs ask clients to identify
    /// themselves with their own user agent instead of a generic one.
    static let openCodeHeaders = ["x-opencode-session": "melon-tools", "user-agent": "MelonTools/1.4"]

    /// Builds the `api-keys.openai-compatibility` block for the gateway config.
    func gatewayYAML() -> String {
        var blocks: [String] = []
        for source in sources where source.enabled {
            let selected = source.selectedModels
            guard !selected.isEmpty else { continue }
            let key = source.apiKey
            guard !key.isEmpty else { continue }
            if source.kind == .openCode {
                // Go models ride the Go endpoints (billed against the Go plan);
                // the generic surface would charge console credits instead.
                let goModels = selected.filter { $0.goTier == true }
                let genericModels = selected.filter { $0.goTier != true }
                if !goModels.isEmpty {
                    blocks.append(block(name: "opencode-go",
                                        baseURL: Self.openCodeGoBaseURL,
                                        key: key,
                                        models: goModels,
                                        headers: Self.openCodeHeaders))
                }
                if !genericModels.isEmpty {
                    blocks.append(block(name: source.id,
                                        baseURL: source.baseURL,
                                        key: key,
                                        models: genericModels,
                                        headers: Self.openCodeHeaders))
                }
                continue
            }
            blocks.append(block(name: source.id,
                                baseURL: source.baseURL,
                                key: key,
                                models: selected,
                                headers: nil))
        }
        guard !blocks.isEmpty else { return "" }
        var yaml = "\napi-keys:\n  openai-compatibility:\n" + blocks.joined(separator: "\n") + "\n"
        let openRouterRouted = sources.contains {
            $0.enabled && $0.kind == .openRouter && !$0.selectedModels.isEmpty && !$0.apiKey.isEmpty
        }
        if openRouterRouted {
            yaml += Self.priceRoutingYAML
        }
        return yaml
    }

    /// One `openai-compatibility` entry.
    private func block(name: String, baseURL: String, key: String, models: [SourceModel], headers: [String: String]?) -> String {
        var lines: [String] = []
        lines.append("    - name: \"\(Self.yamlEscape(name))\"")
        lines.append("      base-url: \"\(Self.yamlEscape(baseURL))\"")
        if let headers, !headers.isEmpty {
            lines.append("      headers:")
            for header in headers.keys.sorted() {
                lines.append("        \(header): \"\(Self.yamlEscape(headers[header]!))\"")
            }
        }
        lines.append("      keys:")
        lines.append("        - api-key: \"\(Self.yamlEscape(key))\"")
        lines.append("      models:")
        for model in models {
            lines.append("        - name: \"\(Self.yamlEscape(model.id))\"")
            lines.append("          alias: \"\(Self.yamlEscape(model.alias))\"")
            if model.display != model.id, !model.display.isEmpty {
                lines.append("          display-name: \"\(Self.yamlEscape(model.display))\"")
            }
            if let context = model.contextLength, context > 0 {
                lines.append("          max-context-length: \(context)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// OpenRouter provider routing: send `provider: {"sort": "price"}` so the
    /// cheapest upstream providers are used first. The rule matches only the
    /// `openrouter/*` aliases — the account pool and OpenCode stay untouched.
    private static let priceRoutingYAML = """
    payload:
      default-raw:
        - models:
            - name: "\(openRouterAliasPrefix)*"
              protocol: "openai"
          params:
            "provider": "{\\"sort\\":\\"price\\"}"
    """

    nonisolated static func yamlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: - Apply

    /// Keeps the Codex catalog in step with the store at launch. The picker
    /// reads `melon-model-catalog.json` at startup, so a stale file — written
    /// before the provider bands or the `openrouter/` aliases existed — must be
    /// regenerated before the next Codex launch.
    func syncCatalogIfNeeded() {
        let wanted = Set(sources.filter(\.enabled).flatMap { $0.selectedModels.map(\.alias) })
        guard wanted != CodexModelCatalog.thirdPartySlugs() else {
            try? CodexModelCatalog.ensureConfigReference()
            return
        }
        do {
            let count = try CodexModelCatalog.sync(sources: sources)
            lastApply = String(format: L("Applied: %d models for Codex."), count)
        } catch {
            lastApply = L("Apply failed") + ": " + error.localizedDescription
        }
    }

    /// Writes the gateway config (hot-reloaded by the service) and regenerates
    /// the Codex model catalog so the picker shows the selected models.
    func apply() async {
        save()
        let gateway = CodexGatewayService.shared
        do {
            try gateway.writeConfig()
            gateway.auditLog("model sources applied (\(selectedCount) model(s) selected)")
            let count = try CodexModelCatalog.sync(sources: sources)
            lastApply = String(format: L("Applied: %d models for Codex."), count)
            gateway.auditLog("model catalog updated (\(count) model(s))")
        } catch {
            lastApply = L("Apply failed") + ": " + error.localizedDescription
        }
    }

    func applyAndRelaunch() async {
        await apply()
        let gateway = CodexGatewayService.shared
        if !gateway.isRunning {
            let store = CodexStore.shared
            store.load()
            await gateway.start(accounts: store.accounts, priorities: store.effectivePriorities())
        }
        gateway.enableCodexRoute()
        ComposerBridge.shared.launchOrActivateCodex(forceRestart: true)
    }
}
