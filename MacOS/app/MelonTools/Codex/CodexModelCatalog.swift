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
        "experimental_supported_tools",
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
        guard let template = referenceEntry(in: entries) else { throw CatalogError.baseMissing }

        var result = entries
        let poolSlugs = Set(entries.compactMap { $0["slug"] as? String })
        var custom = 0
        for source in sources where source.enabled {
            for (position, model) in source.selectedModels.enumerated() {
                // Never shadow an account-pool model.
                if poolSlugs.contains(model.alias) { continue }
                if var entry = makeEntry(from: template, model: model, source: source) {
                    // The Codex picker sorts its list by `priority`, so one
                    // band per provider keeps the models grouped in the menu
                    // (pool → OpenCode → OpenRouter).
                    entry["priority"] = priorityBase(for: source.kind) + position
                    result.append(entry)
                    custom += 1
                }
            }
        }

        let payload: [String: Any] = ["models": result]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try SecureFile.write(data, to: URL(fileURLWithPath: targetPath))
        try ensureConfigReference()
        return custom
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
    /// (`openrouter/…`, `opencode/…`). Used to detect a stale file at launch.
    static func thirdPartySlugs() -> Set<String> {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: targetPath)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else { return [] }
        return Set(models.compactMap { $0["slug"] as? String }.filter { $0.contains("/") })
    }

    // MARK: - Provider bands

    /// Priority band per provider kind. The base catalog uses 0…8 for the
    /// account-pool models (1000 = hidden), so third-party models start above
    /// that and keep the picker grouped.
    static func priorityBase(for kind: ModelSource.Kind) -> Int {
        switch kind {
        case .openCode: return 100
        case .openRouter: return 200
        }
    }

    /// Provider tag used by the composer bridge and the picker grouping.
    static func providerTag(for kind: ModelSource.Kind) -> String {
        switch kind {
        case .openCode: return "opencode"
        case .openRouter: return "openrouter"
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

    private static func makeEntry(from template: [String: Any], model: SourceModel, source: ModelSource) -> [String: Any]? {
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
        entry["supports_image_detail_original"] = false
        entry["input_modalities"] = ["text"]
        return entry
    }
}
