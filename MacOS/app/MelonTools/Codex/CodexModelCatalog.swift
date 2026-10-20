import Foundation

/// Builds `~/.codex/melon-model-catalog.json` — the file the Codex app reads
/// through the `model_catalog_json` key in `~/.codex/config.toml` to fill its
/// model picker.
///
/// The base list (account-pool models) comes from the catalog a local route
/// owner produced, or from the copy bundled with the app. Every selected
/// source model is added as a clone of a reference entry with its own slug,
/// display name, context window and conservative capability flags.
@MainActor
enum CodexModelCatalog {
    static let fileName = "melon-model-catalog.json"

    /// Prompt and policy fields are delivered by model catalogs, but they may
    /// contain client-private instructions. Never bundle or forward them to
    /// third-party model providers when building a local catalog.
    private static let privateMetadataKeys: Set<String> = [
        "base_instructions",
        "model_messages",
        "policy",
        "policy_template",
        "node_repl_policy",
        "rejection_instructions",
        "timeout_instructions",
        "instructions_variables"
    ]

    static func sanitizedEntries(_ entries: [[String: Any]]) -> [[String: Any]] {
        entries.map { sanitizeMetadata(in: $0) as? [String: Any] ?? [:] }
    }

    private static func sanitizeMetadata(in value: Any) -> Any {
        if let object = value as? [String: Any] {
            return object.reduce(into: [String: Any]()) { result, pair in
                guard !privateMetadataKeys.contains(pair.key) else { return }
                result[pair.key] = sanitizeMetadata(in: pair.value)
            }
        }
        if let array = value as? [Any] {
            return array.map { sanitizeMetadata(in: $0) }
        }
        return value
    }

    static var directory: String {
        (CodexGatewayService.codexConfigPath as NSString).deletingLastPathComponent
    }

    static var targetPath: String {
        (directory as NSString).appendingPathComponent(fileName)
    }

    enum CatalogError: LocalizedError {
        case baseMissing
        var errorDescription: String? {
            switch self {
            case .baseMissing: return "Model catalog base is missing."
            }
        }
    }

    /// Regenerates the catalog. Returns the number of custom models written.
    @discardableResult
    static func sync(sources: [ModelSource]) throws -> Int {
        guard let entries = loadBaseEntries() else { throw CatalogError.baseMissing }
        let (result, custom) = generatedEntries(
            base: entries,
            sources: sources,
            defaults: SchemaDefaults.load()
        )
        let payload: [String: Any] = ["models": result]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try SecureFile.write(data, to: URL(fileURLWithPath: targetPath))
        try ensureConfigReference()
        return custom
    }

    /// Appends the selected source models to the sanitized base list and gives
    /// every final entry the fields current Codex requires. Internal so tests
    /// can drive generation with a fixture base and a fixture cache.
    static func generatedEntries(
        base entries: [[String: Any]],
        sources: [ModelSource],
        defaults: SchemaDefaults?
    ) -> (entries: [[String: Any]], custom: Int) {
        guard let template = referenceEntry(in: entries) else {
            return (applyRequiredSchema(to: entries, defaults: defaults), 0)
        }
        var pending: [(entry: [String: Any], display: String, provider: String)] = []
        let poolSlugs = Set(entries.compactMap { $0["slug"] as? String })
        for source in sources where source.enabled {
            for (position, model) in source.selectedModels.enumerated() {
                // Never shadow an account-pool model.
                if poolSlugs.contains(model.alias) { continue }
                if var entry = makeEntry(from: template, model: model, source: source) {
                    // The Codex picker sorts its list by `priority`, so one
                    // band per provider keeps the models grouped in the menu
                    // (pool → OpenCode → OpenRouter → Claude → Antigravity).
                    entry["priority"] = priorityBase(for: source.kind) + position
                    pending.append((
                        entry: entry,
                        display: entry["display_name"] as? String ?? model.alias,
                        provider: source.title
                    ))
                }
            }
        }

        // The Codex picker keys rows by display name. When the same model is
        // offered by two providers (for example Gemini 3.5 Flash Lite from
        // OpenCode and Antigravity), identical names collapse into one row and
        // the surviving provider steals the other provider's slot. Keep both
        // rows by qualifying only the colliding names with the provider.
        var displayCounts: [String: Int] = [:]
        for entry in entries {
            guard let name = entry["display_name"] as? String else { continue }
            displayCounts[name.lowercased(), default: 0] += 1
        }
        for item in pending {
            displayCounts[item.display.lowercased(), default: 0] += 1
        }
        var result = entries
        for item in pending {
            var entry = item.entry
            if displayCounts[item.display.lowercased(), default: 0] > 1 {
                entry["display_name"] = Self.disambiguatedDisplayName(
                    item.display,
                    provider: item.provider
                )
            }
            result.append(entry)
        }
        return (applyRequiredSchema(to: result, defaults: defaults), pending.count)
    }

    /// The picker's deduplication key is the display name, so a shared model
    /// needs a provider suffix to stay visible in both provider sections.
    nonisolated static func disambiguatedDisplayName(_ display: String, provider: String) -> String {
        "\(display) (\(provider))"
    }

    // MARK: - Required schema fields

    /// Instructions and tool lists that current Codex requires in every
    /// entry. They are read from Codex's local cache at generation time, so
    /// prompt text never lives in this repository.
    struct SchemaDefaults {
        var bySlug: [String: [String: Any]]
        var template: [String: Any]?

        static func decode(_ data: Data) -> SchemaDefaults? {
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = root["models"] as? [[String: Any]], !models.isEmpty else { return nil }
            var bySlug: [String: [String: Any]] = [:]
            for entry in models {
                guard let slug = entry["slug"] as? String else { continue }
                bySlug[slug] = entry
            }
            return SchemaDefaults(bySlug: bySlug, template: bySlug["gpt-6.1-sol"] ?? models.first)
        }

        /// `~/.codex/models_cache.json` — written by Codex itself.
        @MainActor
        static func load() -> SchemaDefaults? {
            let url = URL(fileURLWithPath: (directory as NSString).appendingPathComponent("models_cache.json"))
            guard let data = try? Data(contentsOf: url) else { return nil }
            return decode(data)
        }
    }

    static let fallbackInstructions = "You are Codex, a coding agent. Follow the user's instructions and use the available tools."
    static let fallbackTools = ["send_user_message_async", "clock"]

    /// Fills the fields Codex validates for every entry. The bundled base
    /// catalog stores no prompt text, so both instructions and tools are
    /// added here, after sanitization, from the local Codex cache.
    static func applyRequiredSchema(
        to entries: [[String: Any]],
        defaults: SchemaDefaults?
    ) -> [[String: Any]] {
        entries.map { entry in
            var output = entry
            let slug = entry["slug"] as? String
            if !hasInstructions(output) {
                let candidates = [slug.flatMap { defaults?.bySlug[$0] }, defaults?.template].compactMap { $0 }
                for source in candidates {
                    if let payload = instructions(from: source) {
                        output[payload.key] = payload.value
                        break
                    }
                }
            }
            if !hasInstructions(output) {
                output["base_instructions"] = fallbackInstructions
            }
            let currentTools = output["experimental_supported_tools"] as? [String]
            if currentTools == nil || currentTools?.isEmpty == true {
                let templateTools = defaults?.template?["experimental_supported_tools"] as? [String]
                if let templateTools, !templateTools.isEmpty {
                    output["experimental_supported_tools"] = templateTools
                } else {
                    output["experimental_supported_tools"] = fallbackTools
                }
            }
            return output
        }
    }

    private static func hasInstructions(_ entry: [String: Any]) -> Bool {
        instructions(from: entry) != nil
    }

    /// `model_messages.instructions_template` is the preferred form; a plain
    /// `base_instructions` string is the fallback. Empty values do not count.
    private static func instructions(from entry: [String: Any]) -> (key: String, value: Any)? {
        if let messages = entry["model_messages"] as? [String: Any],
           let template = messages["instructions_template"] as? String,
           !template.isEmpty {
            return ("model_messages", messages)
        }
        if let base = entry["base_instructions"] as? String, !base.isEmpty {
            return ("base_instructions", base)
        }
        return nil
    }

    /// Points `model_catalog_json` at our file (top-level key).
    static func ensureConfigReference() throws {
        let path = CodexGatewayService.codexConfigPath
        guard FileManager.default.fileExists(atPath: path) else { return }
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let updated = CodexConfigRoute.upsertTopLevelKey("model_catalog_json", value: fileName, in: text)
        guard updated != text else { return }
        try SecureFile.write(updated, to: URL(fileURLWithPath: path))
    }

    /// Slugs the catalog currently lists for the third-party sources
    /// (`openrouter/…`, `opencode/…`, slash-less `claude-*`). Used to detect a
    /// stale file at launch.
    static func thirdPartySlugs() -> Set<String> {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: targetPath)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else { return [] }
        return Set(models.compactMap { $0["slug"] as? String }.filter { isThirdPartySlug($0) })
    }

    /// Third-party slugs: namespaced ids (`openrouter/…`, `opencode/…`),
    /// slash-less Claude ids (`claude-*`), and the slash-less Antigravity ids
    /// (`gemini-*`, `gpt-oss-*`, …). The account pool never uses those.
    nonisolated static func isThirdPartySlug(_ slug: String) -> Bool {
        slug.contains("/")
            || slug.hasPrefix("claude-")
            || AntigravityModelRegistry.ids.contains(slug)
    }

    // MARK: - Provider bands

    /// Priority band per provider kind. The base catalog uses 0…8 for the
    /// account-pool models (1000 = hidden), so third-party models start above
    /// that and keep the picker grouped.
    static func priorityBase(for kind: ModelSource.Kind) -> Int {
        switch kind {
        case .openCode: return 100
        case .openRouter: return 200
        case .claude: return 300
        case .antigravity: return 400
        }
    }

    /// Provider tag used by the composer bridge and the picker grouping.
    static func providerTag(for kind: ModelSource.Kind) -> String {
        switch kind {
        case .openCode: return "opencode"
        case .openRouter: return "openrouter"
        case .claude: return "Claude"
        case .antigravity: return "Antigravity"
        }
    }

    // MARK: - Picker index

    /// One picker row: the display name the Codex app shows, the provider it
    /// belongs to and the slug the gateway routes on.
    struct PickerModel: Equatable {
        var name: String
        var provider: String
        var slug: String
    }

    /// Pool names from the base catalog (cached — the file rarely changes).
    private static var cachedBaseNames: [PickerModel]?

    static func basePickerModels() -> [PickerModel] {
        if let cachedBaseNames { return cachedBaseNames }
        let list: [PickerModel] = (loadBaseEntries() ?? []).compactMap { entry in
            guard (entry["visibility"] as? String ?? "list") == "list",
                  let slug = entry["slug"] as? String else { return nil }
            return PickerModel(
                name: entry["display_name"] as? String ?? slug,
                provider: "openai",
                slug: slug
            )
        }
        cachedBaseNames = list
        return list
    }

    /// Every model the picker can show, with its provider.
    static func pickerIndex(sources: [ModelSource]) -> [PickerModel] {
        var list = basePickerModels()
        for source in sources where source.enabled {
            for model in source.selectedModels {
                list.append(PickerModel(
                    name: model.display.isEmpty ? model.alias : model.display,
                    provider: providerTag(for: source.kind),
                    slug: model.alias
                ))
            }
        }
        return list
    }

    // MARK: - Base catalog

    private static func loadBaseEntries() -> [[String: Any]]? {
        let fm = FileManager.default
        var candidates: [URL] = []
        // A catalog written by another local route owner (freshest first).
        let owned = (directory as NSString).appendingPathComponent("cockpit-model-catalog.json")
        if fm.fileExists(atPath: owned) {
            candidates.append(URL(fileURLWithPath: owned))
        }
        // Shipped copy — always present in the app bundle.
        if let bundled = Bundle.main.url(forResource: "BaseModelCatalog", withExtension: "json") {
            candidates.append(bundled)
        }
        for url in candidates {
            if let data = try? Data(contentsOf: url),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = root["models"] as? [[String: Any]], !models.isEmpty {
                return sanitizedEntries(models)
            }
        }
        return nil
    }

    /// Preferred template slugs: a balanced model without speed tiers quirks.
    private static var templatePreference: [String] {
        ["gpt-5.6-luna", "gpt-6-luna", "gpt-5.6-terra", "gpt-5.5", "gpt-6-sol", "gpt-6.1-sol"]
    }

    private static func referenceEntry(in entries: [[String: Any]]) -> [String: Any]? {
        for slug in templatePreference {
            if let entry = entries.first(where: { ($0["slug"] as? String) == slug }) {
                return entry
            }
        }
        return entries.first
    }

    // MARK: - Custom entries

    static func makeEntry(from template: [String: Any], model: SourceModel, source: ModelSource) -> [String: Any]? {
        guard !model.alias.isEmpty else { return nil }
        var entry = template
        let templateContext = template["context_window"] as? Int ?? 128_000
        let context = max(model.contextLength ?? templateContext, 8_000)

        entry["slug"] = model.alias
        let display = model.display.isEmpty ? model.alias : model.display
        entry["display_name"] = display
        entry["description"] = "\(display) · \(source.title)"
        entry["context_window"] = context
        entry["max_context_window"] = context
        entry["auto_compact_token_limit"] = Int(Double(context) * 0.85)
        entry["effective_context_window_percent"] = 95

        // Third-party upstreams do not implement OpenAI speed tiers or hosted
        // search, and the Codex app must not offer those switches for them.
        entry["additional_speed_tiers"] = []
        entry["service_tiers"] = []
        entry["default_service_tier"] = NSNull()
        entry["supported_in_api"] = true
        entry["visibility"] = "list"
        entry["prefer_websockets"] = false
        entry["use_responses_lite"] = false
        entry["supports_search_tool"] = false
        // The template usually advertises text+image; a provider model must
        // carry only the modalities its upstream actually accepts. Unknown
        // (`nil`, old stores) stays text-only until the user toggles it.
        let supportsImages = model.supportsImages ?? false
        entry["input_modalities"] = supportsImages ? ["text", "image"] : ["text"]
        entry["supports_image_detail_original"] = false
        return entry
    }
}
