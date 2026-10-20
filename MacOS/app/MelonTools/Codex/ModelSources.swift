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
        /// Anthropic Claude: served from the engine OAuth account by default
        /// (no key); `apiKey` holds the optional API-key fallback.
        case claude
        /// Google Antigravity: OAuth-only (no key, no gateway config block);
        /// the engine serves the models from its own auth file.
        case antigravity
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
    /// Whether the upstream model accepts image input. `nil` means unknown
    /// (stores written before this field); the Codex catalog treats unknown
    /// as text-only.
    var supportsImages: Bool?
}

/// Registry ids served by Antigravity (CLIProxyAPI `models.json`). Used in two
/// places: as the Antigravity allowlist when `/v1/models` omits ownership, and
/// as the subtraction set for the Claude loader. Top-level (not actor-bound)
/// so the ownership predicates stay `nonisolated` and testable.
enum AntigravityModelRegistry {
    static let ids: Set<String> = [
        "claude-opus-4-6-thinking",
        "claude-sonnet-4-6",
        "claude-opus-5-5-high",
        "claude-sonnet-5-5-high",
        "gemini-4-argon-high",
        "gemini-3.8-flash-high",
        "gemini-3-flash",
        "gemini-3.1-flash-image",
        "gpt-oss-120b-medium",
        "gemini-3.1-flash-lite",
        "gemini-3.5-flash-lite",
    ]
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
    /// Optional Anthropic API key (fallback when no OAuth account is used).
    @Published var claudeKey: String = ""
    @Published private(set) var note: String?
    @Published private(set) var isBusy = false
    @Published private(set) var lastApply: String?

    private let fm = FileManager.default
    private var lastPriceHydration = Date.distantPast
    private var lastGoAccessRefresh = Date.distantPast

    let storeURL: URL

    private struct Persisted: Codable {
        var openRouterKey: String?
        var openCodeKey: String?
        var claudeKey: String?
        var sources: [ModelSource]?
    }

    /// Fallback that keeps the pasted keys when an older store cannot decode.
    private struct PersistedKeys: Codable {
        var openRouterKey: String?
        var openCodeKey: String?
        var claudeKey: String?
    }

    /// `storeURL` is injectable so tests can use an isolated store file.
    init(storeURL: URL? = nil) {
        self.storeURL = storeURL ?? CodexStore.supportDir.appendingPathComponent("model-sources.json")
        load()
    }

    // MARK: - Persistence

    func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        if let persisted = try? JSONDecoder().decode(Persisted.self, from: data) {
            openRouterKey = persisted.openRouterKey ?? ""
            openCodeKey = persisted.openCodeKey ?? ""
            claudeKey = persisted.claudeKey ?? persisted.sources?.first { $0.kind == .claude }?.apiKey ?? ""
            sources = persisted.sources ?? []
            // Backfill known capabilities once for stores written before the
            // flag existed; the catalog reads the saved file at startup.
            let backfilled = backfillImageCapabilities()
            let migrated = migrateOpenRouterAliases()
            if backfilled || migrated { save() }
            return
        }
        if let keys = try? JSONDecoder().decode(PersistedKeys.self, from: data) {
            openRouterKey = keys.openRouterKey ?? ""
            openCodeKey = keys.openCodeKey ?? ""
            claudeKey = keys.claudeKey ?? ""
        }
    }

    func save() {
        // The fallback key lives in two places by design: the editable field
        // and the claude source (`api-keys.claude` needs it on the source).
        if let index = sources.firstIndex(where: { $0.kind == .claude }) {
            sources[index].apiKey = claudeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if !claudeKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // A pasted fallback key must survive even before the model list
            // is loaded — create the source so the gateway config can use it.
            sources.append(ModelSource(
                id: "claude",
                kind: .claude,
                title: "Claude",
                baseURL: Self.claudeBaseURL,
                apiKey: claudeKey.trimmingCharacters(in: .whitespacesAndNewlines),
                enabled: true,
                models: []
            ))
        }
        let persisted = Persisted(
            openRouterKey: openRouterKey,
            openCodeKey: openCodeKey,
            claudeKey: claudeKey,
            sources: sources
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(persisted) else { return }
        try? SecureFile.write(data, to: storeURL)
    }

    /// Stores written before 1.4.1 kept the raw OpenRouter id as the alias; the
    /// `openrouter/` prefix is what routes those models to the price sorting
    /// rule in the gateway config.
    @discardableResult
    private func migrateOpenRouterAliases() -> Bool {
        guard let index = sources.firstIndex(where: { $0.kind == .openRouter }) else { return false }
        var source = sources[index]
        var changed = false
        for modelIndex in source.models.indices {
            let model = source.models[modelIndex]
            guard !model.alias.hasPrefix(Self.openRouterAliasPrefix) else { continue }
            source.models[modelIndex].alias = Self.openRouterAlias(model.id)
            changed = true
        }
        guard changed else { return false }
        sources[index] = source
        return true
    }

    /// Fills `supportsImages` for stores written before the flag existed.
    /// Claude and Antigravity have deterministic defaults; OpenRouter/OpenCode
    /// stay unknown until a model-list reload or the picker toggle sets them.
    @discardableResult
    private func backfillImageCapabilities() -> Bool {
        var changed = false
        for sourceIndex in sources.indices {
            let kind = sources[sourceIndex].kind
            for modelIndex in sources[sourceIndex].models.indices {
                guard sources[sourceIndex].models[modelIndex].supportsImages == nil else { continue }
                let id = sources[sourceIndex].models[modelIndex].id
                let images: Bool?
                switch kind {
                case .claude:
                    images = true
                case .antigravity:
                    images = Self.antigravitySupportsImages(id)
                case .openRouter, .openCode:
                    images = nil
                }
                guard let images else { continue }
                sources[sourceIndex].models[modelIndex].supportsImages = images
                changed = true
            }
        }
        return changed
    }

    // MARK: - Queries

    var openRouterSource: ModelSource? { sources.first { $0.id == "openrouter" } }

    var openCodeSource: ModelSource? { sources.first { $0.id == "opencode" } }

    var claudeSource: ModelSource? { sources.first { $0.id == "claude" } }

    var antigravitySource: ModelSource? { sources.first { $0.id == "antigravity" } }

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

    /// Picker "Images" toggle: an explicit user choice (never `nil` after a
    /// click) that survives a store reload and a model-list refresh.
    func setModelSupportsImages(_ sourceId: String, modelId: String, supportsImages: Bool) {
        guard let sIndex = sources.firstIndex(where: { $0.id == sourceId }),
              let mIndex = sources[sIndex].models.firstIndex(where: { $0.id == modelId }) else { return }
        guard sources[sIndex].models[mIndex].supportsImages != supportsImages else { return }
        sources[sIndex].models[mIndex].supportsImages = supportsImages
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

    /// Decoded model list shared by OpenRouter and the engine endpoints.
    /// Internal (not private) so the modality-mapping tests can decode the
    /// exact wire shape.
    struct ModelList: Decodable {
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
        /// OpenRouter publishes input modalities here; other providers may
        /// omit the block entirely.
        struct Architecture: Decodable {
            let input_modalities: [String]?
        }
        struct Entry: Decodable {
            let id: String
            let name: String?
            let context_length: Int?
            /// `/v1/models` (OpenAI shape) exposes the serving provider here.
            /// OpenRouter/OpenCode omit it, so it stays optional.
            let owned_by: String?
            let pricing: Pricing?
            let architecture: Architecture?
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

    /// Maps provider `architecture.input_modalities` to the picker flag.
    /// Absent metadata means unknown (`nil`), not "text only".
    nonisolated static func supportsImages(inputModalities: [String]?) -> Bool? {
        guard let inputModalities else { return nil }
        return inputModalities.contains("image")
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
        var imagesById: [String: Bool] = [:]
        for model in existing?.models ?? [] {
            enabledById[model.id] = model.enabled
            if let images = model.supportsImages { imagesById[model.id] = images }
        }
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
                    cacheReadPerToken: $0.pricing?.input_cache_read?.value,
                    supportsImages: imagesById[$0.id]
                        ?? Self.supportsImages(inputModalities: $0.architecture?.input_modalities)
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
        var imagesById: [String: Bool] = [:]
        for model in existing?.models ?? [] {
            enabledById[model.id] = model.enabled
            if let go = model.goTier { goById[model.id] = go }
            if let images = model.supportsImages { imagesById[model.id] = images }
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
                    goTier: goIds.map { $0.contains(entry.id) } ?? goById[entry.id],
                    supportsImages: imagesById[entry.id]
                        ?? Self.supportsImages(inputModalities: entry.architecture?.input_modalities)
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

    // MARK: - Claude (engine account or API-key fallback)

    /// Anthropic endpoint used by the API-key fallback entry.
    static let claudeBaseURL = "https://api.anthropic.com"

    /// Loads the Claude model list from the running engine
    /// (`GET /v1/models`), filtered to raw `claude-*` ids — OAuth accounts and
    /// API-key fallback models come from the same catalogue. The ids are
    /// slash-less, so they are used as-is for both name and alias.
    func loadClaudeModels() async {
        guard !isBusy else { return }
        let gateway = CodexGatewayService.shared
        guard gateway.isRunning else {
            note = L("Start the service to load the Claude model list.")
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let entries = try await fetchModels(
                url: gateway.baseURL + "/v1/models",
                key: gateway.apiKey,
                userAgent: "MelonTools/1.4"
            )
            // Antigravity serves some of the same `claude-*` ids through its
            // Google account. Ownership decides the provider: an
            // `owned_by: "antigravity"` entry must not be claimed by the
            // Anthropic-key/OAuth source. When the engine omits ownership,
            // subtract the Antigravity registry ids instead.
            let claudeEntries = entries.filter {
                Self.isClaudeModel(id: $0.id, owner: $0.owned_by)
            }
            guard !claudeEntries.isEmpty else {
                note = L("No Claude models — connect an account first.")
                return
            }
            mergeClaude(entries: claudeEntries)
            note = String(format: L("Claude: %d models"), claudeEntries.count)
        } catch {
            note = L("The service did not answer the model list.")
        }
    }

    private func mergeClaude(entries: [ModelList.Entry]) {
        let existing = claudeSource
        var enabledById: [String: Bool] = [:]
        var imagesById: [String: Bool] = [:]
        for model in existing?.models ?? [] {
            enabledById[model.id] = model.enabled
            if let images = model.supportsImages { imagesById[model.id] = images }
        }
        let models = entries
            .map { entry in
                SourceModel(
                    id: entry.id,
                    display: entry.name ?? Self.prettyName(entry.id),
                    contextLength: entry.context_length,
                    enabled: enabledById[entry.id] ?? false,
                    alias: entry.id,
                    supportsImages: imagesById[entry.id] ?? Self.claudeSupportsImages(entry.id)
                )
            }
            .sorted { $0.id.lowercased() < $1.id.lowercased() }
        replace(ModelSource(
            id: "claude",
            kind: .claude,
            title: "Claude",
            baseURL: Self.claudeBaseURL,
            apiKey: claudeKey.trimmingCharacters(in: .whitespacesAndNewlines),
            enabled: existing?.enabled ?? true,
            models: models
        ))
        save()
    }

    // MARK: - Antigravity (engine account, OAuth only)

    /// `/v1/models` carries the serving provider as `owned_by`. Antigravity
    /// entries say `"antigravity"`; Claude entries say `"anthropic"`. Only
    /// fall back to the registry id allowlist when ownership is absent.
    nonisolated static func isAntigravityModel(id: String, owner: String?) -> Bool {
        if let owner, !owner.isEmpty {
            return owner.caseInsensitiveCompare("antigravity") == .orderedSame
        }
        return AntigravityModelRegistry.ids.contains(id)
    }

    /// Antigravity vision defaults: Gemini and Claude accept images;
    /// `gpt-oss-120b-medium` does not; anything else stays unknown.
    nonisolated static func antigravitySupportsImages(_ id: String) -> Bool? {
        if id == "gpt-oss-120b-medium" { return false }
        if id.hasPrefix("gemini-") || id.hasPrefix("claude-") { return true }
        return nil
    }

    /// The Claude source claims raw `claude-*` ids, but not the ones the
    /// engine serves through Antigravity.
    nonisolated static func isClaudeModel(id: String, owner: String?) -> Bool {
        guard id.hasPrefix("claude-") else { return false }
        return !isAntigravityModel(id: id, owner: owner)
    }

    /// Every model the Claude source lists is a `claude-*` vision model.
    nonisolated static func claudeSupportsImages(_ id: String) -> Bool? {
        id.hasPrefix("claude-") ? true : nil
    }

    /// Loads the Antigravity model list from the running engine
    /// (`GET /v1/models`), filtered by ownership rather than id prefixes —
    /// Antigravity serves `claude-*` and `gemini-*` ids that overlap other
    /// providers. The OAuth auth file is enough; no key is involved.
    func loadAntigravityModels() async {
        guard !isBusy else { return }
        let gateway = CodexGatewayService.shared
        guard gateway.isRunning else {
            note = L("Start the service to load the Antigravity model list.")
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let entries = try await fetchModels(
                url: gateway.baseURL + "/v1/models",
                key: gateway.apiKey,
                userAgent: "MelonTools/1.4"
            )
            let owned = entries.filter {
                Self.isAntigravityModel(id: $0.id, owner: $0.owned_by)
            }
            guard !owned.isEmpty else {
                note = L("No Antigravity models — connect an account first.")
                return
            }
            mergeAntigravity(entries: owned)
            note = String(format: L("Antigravity: %d models"), owned.count)
        } catch {
            note = L("The service did not answer the model list.")
        }
    }

    private func mergeAntigravity(entries: [ModelList.Entry]) {
        let existing = antigravitySource
        var enabledById: [String: Bool] = [:]
        var imagesById: [String: Bool] = [:]
        for model in existing?.models ?? [] {
            enabledById[model.id] = model.enabled
            if let images = model.supportsImages { imagesById[model.id] = images }
        }
        let models = entries
            .map { entry in
                SourceModel(
                    id: entry.id,
                    display: entry.name ?? Self.prettyName(entry.id),
                    contextLength: entry.context_length,
                    enabled: enabledById[entry.id] ?? false,
                    alias: entry.id,
                    supportsImages: imagesById[entry.id] ?? Self.antigravitySupportsImages(entry.id)
                )
            }
            .sorted { $0.id.lowercased() < $1.id.lowercased() }
        replace(ModelSource(
            id: "antigravity",
            kind: .antigravity,
            title: "Antigravity",
            baseURL: "",
            apiKey: "",
            enabled: existing?.enabled ?? true,
            models: models
        ))
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

    /// Builds the gateway `api-keys` block from the current sources.
    ///
    /// OpenRouter/OpenCode ride `openai-compatibility`; the Claude API-key
    /// fallback rides `claude` — inside the SAME top-level `api-keys:` root
    /// (a second root would break the config). A Claude OAuth source carries
    /// no key and emits nothing: the engine serves it from its own account.
    /// Antigravity is OAuth-only and likewise emits nothing.
    nonisolated static func gatewayYAML(sources: [ModelSource]) -> String {
        var compatBlocks: [String] = []
        var claudeBlocks: [String] = []
        for source in sources where source.enabled {
            let selected = source.selectedModels
            guard !selected.isEmpty else { continue }
            if source.kind == .antigravity {
                // OAuth-only: the engine serves the models from its Google
                // account, so there is nothing to put into `api-keys`.
                continue
            }
            if source.kind == .claude {
                // Only the explicit API-key fallback needs a config block.
                let key = source.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { continue }
                claudeBlocks.append(claudeBlock(source: source, key: key, models: selected))
                continue
            }
            let key = source.apiKey
            guard !key.isEmpty else { continue }
            if source.kind == .openCode {
                // Go models ride the Go endpoints (billed against the Go plan);
                // the generic surface would charge console credits instead.
                let goModels = selected.filter { $0.goTier == true }
                let genericModels = selected.filter { $0.goTier != true }
                if !goModels.isEmpty {
                    compatBlocks.append(block(name: "opencode-go",
                                              baseURL: Self.openCodeGoBaseURL,
                                              key: key,
                                              models: goModels,
                                              headers: Self.openCodeHeaders))
                }
                if !genericModels.isEmpty {
                    compatBlocks.append(block(name: source.id,
                                              baseURL: source.baseURL,
                                              key: key,
                                              models: genericModels,
                                              headers: Self.openCodeHeaders))
                }
                continue
            }
            compatBlocks.append(block(name: source.id,
                                      baseURL: source.baseURL,
                                      key: key,
                                      models: selected,
                                      headers: nil))
        }
        guard !compatBlocks.isEmpty || !claudeBlocks.isEmpty else { return "" }
        var yaml = "\napi-keys:\n"
        if !compatBlocks.isEmpty {
            yaml += "  openai-compatibility:\n" + compatBlocks.joined(separator: "\n") + "\n"
        }
        if !claudeBlocks.isEmpty {
            yaml += "  claude:\n" + claudeBlocks.joined(separator: "\n") + "\n"
        }
        let openRouterRouted = sources.contains {
            $0.enabled && $0.kind == .openRouter && !$0.selectedModels.isEmpty && !$0.apiKey.isEmpty
        }
        if openRouterRouted {
            yaml += Self.priceRoutingYAML
        }
        return yaml
    }

    func gatewayYAML() -> String {
        Self.gatewayYAML(sources: sources)
    }

    /// One `api-keys.claude` entry (Anthropic API-key fallback): same model
    /// mapping shape as `openai-compatibility`, no `prefix` namespace.
    private nonisolated static func claudeBlock(source: ModelSource, key: String, models: [SourceModel]) -> String {
        var lines: [String] = []
        lines.append("    - name: \"\(yamlEscape(source.id))\"")
        lines.append("      base-url: \"\(yamlEscape(source.baseURL))\"")
        lines.append("      keys:")
        lines.append("        - api-key: \"\(yamlEscape(key))\"")
        lines.append("      models:")
        for model in models {
            lines.append("        - name: \"\(yamlEscape(model.id))\"")
            lines.append("          alias: \"\(yamlEscape(model.alias))\"")
            if model.display != model.id, !model.display.isEmpty {
                lines.append("          display-name: \"\(yamlEscape(model.display))\"")
            }
            if let context = model.contextLength, context > 0 {
                lines.append("          max-context-length: \(context)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// One `openai-compatibility` entry.
    private nonisolated static func block(name: String, baseURL: String, key: String, models: [SourceModel], headers: [String: String]?) -> String {
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
    /// before the provider bands, aliases or display-name disambiguation
    /// existed — must be regenerated before the next Codex launch. Slug sets
    /// alone are not enough: a fix that only changes display names would
    /// otherwise leave the old catalog in place.
    func syncCatalogIfNeeded() {
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
