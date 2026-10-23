import XCTest
@testable import MelonTools

@MainActor
final class CodexModelCatalogTests: XCTestCase {
    func testPrivateCatalogMetadataIsRemovedRecursively() throws {
        let entry: [String: Any] = [
            "slug": "sample-model",
            "display_name": "Sample Model",
            "base_instructions": "private instruction fixture",
            "model_messages": [["role": "system", "content": "private fixture"]],
            "experimental_supported_tools": [["name": "fixture"]],
            "nested": [
                "policy": "private fixture",
                "safe_value": "kept",
                "items": [["timeout_instructions": "private fixture", "enabled": true]]
            ]
        ]

        let sanitized = try XCTUnwrap(CodexModelCatalog.sanitizedEntries([entry]).first)

        XCTAssertEqual(sanitized["slug"] as? String, "sample-model")
        XCTAssertEqual(sanitized["display_name"] as? String, "Sample Model")
        XCTAssertNil(sanitized["base_instructions"])
        XCTAssertNil(sanitized["model_messages"])
        XCTAssertNotNil(sanitized["experimental_supported_tools"])
        // Required by current Codex schemas; it is a capability list, not private prompt data.

        let nested = try XCTUnwrap(sanitized["nested"] as? [String: Any])
        XCTAssertNil(nested["policy"])
        XCTAssertEqual(nested["safe_value"] as? String, "kept")

        let items = try XCTUnwrap(nested["items"] as? [[String: Any]])
        XCTAssertNil(items.first?["timeout_instructions"])
        XCTAssertEqual(items.first?["enabled"] as? Bool, true)
    }

    /// Claude rides its own band above OpenCode/OpenRouter, with the
    /// `Claude` provider tag used by the picker grouping.
    func testClaudeBandAndProviderTag() {
        XCTAssertEqual(CodexModelCatalog.priorityBase(for: .claude), 500)
        XCTAssertEqual(CodexModelCatalog.providerTag(for: .claude), "Claude")
        XCTAssertEqual(CodexModelCatalog.priorityBase(for: .openRouter), 200)
        XCTAssertEqual(CodexModelCatalog.priorityBase(for: .openCode), 100)
    }

    /// Antigravity sits in the last band (600) with its own picker tag.
    func testAntigravityBandAndProviderTag() {
        XCTAssertEqual(CodexModelCatalog.priorityBase(for: .antigravity), 600)
        XCTAssertEqual(CodexModelCatalog.providerTag(for: .antigravity), "Antigravity")
        XCTAssertEqual(CodexModelCatalog.priorityBase(for: .claude), 500)
        XCTAssertEqual(CodexModelCatalog.priorityBase(for: .openRouter), 200)
        XCTAssertEqual(CodexModelCatalog.priorityBase(for: .openCode), 100)
    }

    func testDeepInfraAndVercelBandsAndTags() {
        XCTAssertEqual(CodexModelCatalog.priorityBase(for: .deepInfra), 300)
        XCTAssertEqual(CodexModelCatalog.priorityBase(for: .vercel), 400)
        XCTAssertEqual(CodexModelCatalog.providerTag(for: .deepInfra), "deepinfra")
        XCTAssertEqual(CodexModelCatalog.providerTag(for: .vercel), "vercel")
        XCTAssertEqual(CodexModelCatalog.priorityBase(for: .claude), 500)
        XCTAssertEqual(CodexModelCatalog.priorityBase(for: .antigravity), 600)
    }

    /// The per-provider index is capped at 99, so a 200-model DeepInfra list
    /// cannot spill into the Vercel band.
    func testProviderIndexIsCappedAt99() throws {
        let base: [[String: Any]] = [[
            "slug": "gpt-6.1-sol",
            "display_name": "GPT-6.1 Sol",
            "context_window": 128_000,
            "priority": 0,
        ]]
        let models = (0..<105).map { index in
            SourceModel(
                id: "model-\(index)",
                display: "Model \(index)",
                contextLength: nil,
                enabled: true,
                alias: "deepinfra/model-\(index)"
            )
        }
        let source = ModelSource(
            id: "deepinfra",
            kind: .deepInfra,
            title: "DeepInfra",
            baseURL: ModelSourcesStore.deepInfraBaseURL,
            apiKey: "key",
            enabled: true,
            models: models
        )
        let generated = CodexModelCatalog.generatedEntries(base: base, sources: [source], defaults: nil)
        let priorities = generated.entries.compactMap { $0["priority"] as? Int }.filter { $0 >= 300 }
        XCTAssertEqual(priorities.min(), 300)
        XCTAssertEqual(priorities.max(), 399)
        XCTAssertEqual(priorities.filter { $0 == 399 }.count, 6)
    }

    // MARK: - DeepInfra / Vercel wire shapes

    func testDeepInfraModelListDecodesChatPricingAndVision() throws {
        let json = #"""
        {"data":[
          {"id":"deepseek-ai/DeepSeek-V4","metadata":{
            "context_length":131072,
            "tags":["chat","vision"],
            "pricing":{"input_tokens":0.27,"output_tokens":1.1,"cache_read_tokens":0.027}
          }},
          {"id":"black-forest-labs/FLUX.1","metadata":{"tags":["image"]}}
        ]}
        """#
        let list = try JSONDecoder().decode(ModelSourcesStore.ModelList.self, from: Data(json.utf8))
        let chat = try XCTUnwrap(list.data.first)
        XCTAssertEqual(chat.metadata?.context_length, 131_072)
        XCTAssertEqual(chat.metadata?.pricing?.input_tokens?.value, 0.27)
        let promptPerToken = try XCTUnwrap(ModelSourcesStore.perMillionToToken(chat.metadata?.pricing?.input_tokens?.value))
        XCTAssertEqual(promptPerToken, 0.00000027, accuracy: 0.0000000001)
        XCTAssertEqual(ModelSourcesStore.supportsImages(tags: chat.metadata?.tags), true)
        XCTAssertEqual(chat.metadata?.tags?.contains("chat"), true)
        XCTAssertEqual(list.data[1].metadata?.tags?.contains("chat"), false)
    }

    func testVercelModelListDecodesLanguagePricingAndVision() throws {
        let json = #"""
        {"data":[
          {"id":"anthropic/claude-sonnet-4.6","name":"Claude Sonnet 4.6","type":"language",
           "context_window":200000,
           "pricing":{"input":"0.000003","output":"0.000015","input_cache_read":"0.0000003"},
           "modalities":{"input":["text","image"]}},
          {"id":"openai/gpt-image-1","type":"image"}
        ]}
        """#
        let list = try JSONDecoder().decode(ModelSourcesStore.ModelList.self, from: Data(json.utf8))
        let language = try XCTUnwrap(list.data.first)
        XCTAssertEqual(language.name, "Claude Sonnet 4.6")
        XCTAssertEqual(language.type, "language")
        XCTAssertEqual(language.context_window, 200_000)
        XCTAssertEqual(language.pricing?.input?.value, 0.000003)
        XCTAssertEqual(ModelSourcesStore.supportsImages(inputModalities: language.modalities?.input), true)
        XCTAssertEqual(ModelSourcesStore.displayName(id: language.id, fallback: language.name), "Claude Sonnet 4.6")
        XCTAssertEqual(ModelSourcesStore.displayName(id: "deepseek-ai/DeepSeek-V4", fallback: nil), "DeepSeek V4")
    }

    /// Claude ids are slash-less (`claude-opus-4-6`), unlike the namespaced
    /// OpenRouter/OpenCode slugs — stale-catalog detection must see both.
    func testSlashLessClaudeIdsAreThirdPartySlugs() {
        XCTAssertTrue(CodexModelCatalog.isThirdPartySlug("claude-opus-4-6"))
        XCTAssertTrue(CodexModelCatalog.isThirdPartySlug("openrouter/deepseek/deepseek-v3"))
        XCTAssertTrue(CodexModelCatalog.isThirdPartySlug("opencode/gpt-5.1"))
        XCTAssertFalse(CodexModelCatalog.isThirdPartySlug("gpt-6.1-sol"))
    }

    /// Antigravity ids are slash-less too; the stale-catalog check must see
    /// them even without the `claude-` prefix (`gemini-*`, `gpt-oss-*`).
    func testAntigravityIdsAreThirdPartySlugs() {
        XCTAssertTrue(CodexModelCatalog.isThirdPartySlug("gemini-4-argon-high"))
        XCTAssertTrue(CodexModelCatalog.isThirdPartySlug("gemini-3.5-flash-lite"))
        XCTAssertTrue(CodexModelCatalog.isThirdPartySlug("gpt-oss-120b-medium"))
        XCTAssertTrue(CodexModelCatalog.isThirdPartySlug("claude-opus-4-6-thinking"))
        XCTAssertFalse(CodexModelCatalog.isThirdPartySlug("gpt-6.1-sol"))
    }

    // MARK: - Shared model names

    /// The same model can be served by OpenCode and Antigravity. Codex keys
    /// picker rows by display name, so both rows must carry a provider suffix
    /// or one of them disappears from the menu.
    func testSharedModelNamesStayVisibleForBothProviders() throws {
        let base: [[String: Any]] = [[
            "slug": "gpt-6.1-sol",
            "display_name": "GPT-6.1 Sol",
            "context_window": 128_000,
            "priority": 0,
        ]]
        let openCode = ModelSource(
            id: "opencode",
            kind: .openCode,
            title: "OpenCode",
            baseURL: "",
            apiKey: "key",
            enabled: true,
            models: [
                SourceModel(
                    id: "gemini-3.5-flash-lite",
                    display: "Gemini 3.5 Flash Lite",
                    contextLength: nil,
                    enabled: true,
                    alias: "opencode/gemini-3.5-flash-lite"
                ),
            ]
        )
        let antigravity = ModelSource(
            id: "antigravity",
            kind: .antigravity,
            title: "Antigravity",
            baseURL: "",
            apiKey: "",
            enabled: true,
            models: [
                SourceModel(
                    id: "gemini-3.5-flash-lite",
                    display: "Gemini 3.5 Flash Lite",
                    contextLength: nil,
                    enabled: true,
                    alias: "gemini-3.5-flash-lite"
                ),
            ]
        )

        let generated = CodexModelCatalog.generatedEntries(
            base: base,
            sources: [openCode, antigravity],
            defaults: nil
        )
        let names = generated.entries.compactMap { $0["display_name"] as? String }
        XCTAssertEqual(generated.custom, 2)
        XCTAssertTrue(names.contains("Gemini 3.5 Flash Lite (OpenCode)"))
        XCTAssertTrue(names.contains("Gemini 3.5 Flash Lite (Antigravity)"))
        XCTAssertEqual(
            Set(names.filter { $0.hasPrefix("Gemini 3.5 Flash Lite") }).count,
            2
        )

        // The composer matches the selected menu row by name; the index must
        // use the same provider-qualified names as the catalog.
        let pickerNames = CodexModelCatalog.pickerIndex(sources: [openCode, antigravity])
            .map(\.name)
            .filter { $0.hasPrefix("Gemini 3.5 Flash Lite") }
        XCTAssertEqual(Set(pickerNames), Set(names.filter { $0.hasPrefix("Gemini 3.5 Flash Lite") }))
    }

    /// A name that is not shared stays clean; only collisions get a suffix.
    func testUniqueModelNameIsNotSuffixed() {
        let base: [[String: Any]] = [[
            "slug": "gpt-6.1-sol",
            "display_name": "GPT-6.1 Sol",
            "context_window": 128_000,
        ]]
        let source = ModelSource(
            id: "opencode",
            kind: .openCode,
            title: "OpenCode",
            baseURL: "",
            apiKey: "key",
            enabled: true,
            models: [
                SourceModel(
                    id: "unique-model",
                    display: "Unique Model",
                    contextLength: nil,
                    enabled: true,
                    alias: "opencode/unique-model"
                ),
            ]
        )
        let generated = CodexModelCatalog.generatedEntries(
            base: base,
            sources: [source],
            defaults: nil
        )
        XCTAssertEqual(
            generated.entries.compactMap { $0["display_name"] as? String },
            ["GPT-6.1 Sol", "Unique Model"]
        )
    }

    // MARK: - Test isolation

    func testTestHostDetectsXCTest() {
        XCTAssertTrue(AppRuntime.isTesting)
    }

    // MARK: - Instance names

    func testInstanceNamesRejectTraversalAndSeparators() {
        XCTAssertTrue(CodexInstance.isSafeName("Work account"))
        XCTAssertTrue(CodexInstance.isSafeName("work-1_test"))
        XCTAssertFalse(CodexInstance.isSafeName(".."))
        XCTAssertFalse(CodexInstance.isSafeName("../evil"))
        XCTAssertFalse(CodexInstance.isSafeName("a/b"))
        XCTAssertFalse(CodexInstance.isSafeName("a\\b"))
        XCTAssertFalse(CodexInstance.isSafeName("a:b"))
        XCTAssertFalse(CodexInstance.isSafeName(""))
        XCTAssertFalse(CodexInstance.isSafeName("bad\u{0007}name"))
    }

    func testLegacyUnsafeInstanceNameCannotEscapeInstancesDirectory() {
        let instance = CodexInstance(name: "../Documents/foo")
        let root = CodexInstancePaths.instancesDir.standardizedFileURL.path
        let home = URL(fileURLWithPath: instance.homePath).standardizedFileURL.path
        XCTAssertTrue(home.hasPrefix(root + "/"), home)
        XCTAssertFalse(home.contains("/../"))
        XCTAssertEqual(
            CodexInstance.safeDirectoryName("../Documents/foo", fallbackID: "abc12345"),
            ".._Documents_foo"
        )
        XCTAssertEqual(
            CodexInstance.safeDirectoryName("..", fallbackID: "abc12345"),
            "instance-abc12345"
        )
    }

    func testComposerMasksEmailIdentity() {
        XCTAssertEqual(
            ComposerBridge.maskedEmail("alice@example.com") as? String,
            "a***@example.com"
        )
        XCTAssertTrue(ComposerBridge.maskedEmail(nil) is NSNull)
    }

    // MARK: - Image input

    /// OpenRouter's `architecture.input_modalities` drives the store flag;
    /// a missing block means unknown, not text-only.
    func testOpenRouterInputModalitiesDecode() throws {
        let json = """
        {"data":[
          {"id":"vision/model","name":"Vision","architecture":{"input_modalities":["text","image"]}},
          {"id":"text/model","name":"Text","architecture":{"input_modalities":["text"]}},
          {"id":"plain/model","name":"Plain"}
        ]}
        """
        let list = try JSONDecoder().decode(
            ModelSourcesStore.ModelList.self,
            from: Data(json.utf8)
        )
        let byID = Dictionary(uniqueKeysWithValues: list.data.map { ($0.id, $0) })

        XCTAssertEqual(
            ModelSourcesStore.supportsImages(inputModalities: byID["vision/model"]?.architecture?.input_modalities),
            true
        )
        XCTAssertEqual(
            ModelSourcesStore.supportsImages(inputModalities: byID["text/model"]?.architecture?.input_modalities),
            false
        )
        XCTAssertNil(
            ModelSourcesStore.supportsImages(inputModalities: byID["plain/model"]?.architecture?.input_modalities)
        )
        XCTAssertNil(ModelSourcesStore.supportsImages(inputModalities: nil))
    }

    /// Generation adds the capability list Codex requires even when no local
    /// cache is available.
    func testCatalogCloneAlwaysCarriesExperimentalTools() throws {
        let template: [String: Any] = ["slug": "template", "context_window": 128_000]
        let source = ModelSource(
            id: "claude",
            kind: .claude,
            title: "Claude",
            baseURL: "",
            apiKey: "",
            enabled: true,
            models: []
        )
        let model = SourceModel(
            id: "claude-sonnet-4-6",
            display: "Claude Sonnet 4.6",
            contextLength: nil,
            enabled: true,
            alias: "claude-sonnet-4-6"
        )
        let clone = try XCTUnwrap(CodexModelCatalog.makeEntry(from: template, model: model, source: source))
        let entry = try XCTUnwrap(
            CodexModelCatalog.applyRequiredSchema(to: [clone], defaults: nil).first
        )
        XCTAssertEqual(entry["experimental_supported_tools"] as? [String], ["send_user_message_async", "clock"])
    }

    func testCatalogCloneCarriesImageCapability() throws {
        let template: [String: Any] = ["slug": "template", "context_window": 128_000]
        let source = ModelSource(
            id: "openrouter",
            kind: .openRouter,
            title: "OpenRouter",
            baseURL: ModelSourcesStore.openRouterBaseURL,
            apiKey: "key",
            enabled: true,
            models: []
        )

        func entry(supportsImages: Bool?) throws -> [String: Any] {
            let model = SourceModel(
                id: "vision-model",
                display: "Vision Model",
                contextLength: nil,
                enabled: true,
                alias: "openrouter/vision-model",
                supportsImages: supportsImages
            )
            return try XCTUnwrap(CodexModelCatalog.makeEntry(from: template, model: model, source: source))
        }

        let vision = try entry(supportsImages: true)
        XCTAssertEqual(vision["input_modalities"] as? [String], ["text", "image"])
        XCTAssertEqual(vision["supports_image_detail_original"] as? Bool, false)

        let textOnly = try entry(supportsImages: false)
        XCTAssertEqual(textOnly["input_modalities"] as? [String], ["text"])

        let unknown = try entry(supportsImages: nil)
        XCTAssertEqual(unknown["input_modalities"] as? [String], ["text"])
    }

    /// Claude lists only `claude-*` vision models; Antigravity knows Gemini
    /// and Claude are visual and `gpt-oss-120b-medium` is not.
    func testProviderImageDefaults() {
        XCTAssertEqual(ModelSourcesStore.claudeSupportsImages("claude-opus-4-6"), true)
        XCTAssertNil(ModelSourcesStore.claudeSupportsImages("gpt-6.1-sol"))

        XCTAssertEqual(ModelSourcesStore.antigravitySupportsImages("gemini-4-argon-high"), true)
        XCTAssertEqual(ModelSourcesStore.antigravitySupportsImages("claude-opus-4-6-thinking"), true)
        XCTAssertEqual(ModelSourcesStore.antigravitySupportsImages("gpt-oss-120b-medium"), false)
        XCTAssertNil(ModelSourcesStore.antigravitySupportsImages("some-other-model"))
    }

    /// Old stores decode the missing flag as `nil`; a toggle writes `true`
    /// or `false` through the store and survives a reload.
    func testImagesTogglePersistsAndMissingFieldIsUnknown() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("melon-images-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("model-sources.json")

        let fixture = ModelSourcesFixture(sources: [
            ModelSource(
                id: "openrouter",
                kind: .openRouter,
                title: "OpenRouter",
                baseURL: ModelSourcesStore.openRouterBaseURL,
                apiKey: "key",
                enabled: true,
                models: [SourceModel(
                    id: "vision-model",
                    display: "Vision Model",
                    contextLength: nil,
                    enabled: true,
                    alias: "openrouter/vision-model"
                )]
            )
        ])
        try JSONEncoder().encode(fixture).write(to: storeURL)

        let store = ModelSourcesStore(storeURL: storeURL)
        XCTAssertNil(store.source(id: "openrouter")?.models.first?.supportsImages)

        store.setModelSupportsImages("openrouter", modelId: "vision-model", supportsImages: true)
        let reloaded = ModelSourcesStore(storeURL: storeURL)
        XCTAssertEqual(reloaded.source(id: "openrouter")?.models.first?.supportsImages, true)

        reloaded.setModelSupportsImages("openrouter", modelId: "vision-model", supportsImages: false)
        let updated = ModelSourcesStore(storeURL: storeURL)
        XCTAssertEqual(updated.source(id: "openrouter")?.models.first?.supportsImages, false)
    }

    /// A store written before the flag existed gets Claude/Antigravity
    /// defaults on load, and the backfill is persisted for the catalog;
    /// OpenRouter/OpenCode stay unknown.
    func testOldStoreBackfillsProviderImageDefaults() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("melon-images-backfill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("model-sources.json")

        func model(_ id: String, alias: String? = nil) -> SourceModel {
            SourceModel(
                id: id,
                display: id,
                contextLength: nil,
                enabled: true,
                alias: alias ?? id
            )
        }

        let fixture = ModelSourcesFixture(sources: [
            ModelSource(
                id: "claude",
                kind: .claude,
                title: "Claude",
                baseURL: ModelSourcesStore.claudeBaseURL,
                apiKey: "",
                enabled: true,
                models: [model("claude-opus-4-6")]
            ),
            ModelSource(
                id: "antigravity",
                kind: .antigravity,
                title: "Antigravity",
                baseURL: "",
                apiKey: "",
                enabled: true,
                models: [
                    model("gemini-4-argon-high"),
                    model("claude-opus-4-6-thinking"),
                    model("gpt-oss-120b-medium")
                ]
            ),
            ModelSource(
                id: "openrouter",
                kind: .openRouter,
                title: "OpenRouter",
                baseURL: ModelSourcesStore.openRouterBaseURL,
                apiKey: "key",
                enabled: true,
                models: [model("vision-model", alias: "openrouter/vision-model")]
            ),
            ModelSource(
                id: "opencode",
                kind: .openCode,
                title: "OpenCode",
                baseURL: ModelSourcesStore.openCodeBaseURL,
                apiKey: "key",
                enabled: true,
                models: [model("vision-model", alias: "opencode/vision-model")]
            )
        ])
        try JSONEncoder().encode(fixture).write(to: storeURL)

        let store = ModelSourcesStore(storeURL: storeURL)
        XCTAssertEqual(store.source(id: "claude")?.models.first?.supportsImages, true)
        XCTAssertEqual(store.source(id: "antigravity")?.models[0].supportsImages, true)
        XCTAssertEqual(store.source(id: "antigravity")?.models[1].supportsImages, true)
        XCTAssertEqual(store.source(id: "antigravity")?.models[2].supportsImages, false)
        XCTAssertNil(store.source(id: "openrouter")?.models.first?.supportsImages)
        XCTAssertNil(store.source(id: "opencode")?.models.first?.supportsImages)

        // The defaults were written back, not only patched in memory.
        let persisted = try JSONDecoder().decode(
            ModelSourcesFixture.self,
            from: Data(contentsOf: storeURL)
        )
        XCTAssertEqual(persisted.sources.first { $0.id == "claude" }?.models.first?.supportsImages, true)
        let antigravity = try XCTUnwrap(persisted.sources.first { $0.id == "antigravity" })
        XCTAssertEqual(antigravity.models.map(\.supportsImages), [true, true, false] as [Bool?])
        XCTAssertNil(persisted.sources.first { $0.id == "openrouter" }?.models.first?.supportsImages)
        XCTAssertNil(persisted.sources.first { $0.id == "opencode" }?.models.first?.supportsImages)
    }

    // MARK: - Catalog schema (instructions + tools)

    /// Current Codex requires instructions and `experimental_supported_tools`
    /// on every entry. Generation takes them from Codex's local cache: the
    /// by-slug entry first, then the `gpt-6.1-sol` template.
    func testGeneratedCatalogEntriesCarryInstructionsAndTools() throws {
        let cache = """
        {"models":[
          {"slug":"gpt-6.1-sol","experimental_supported_tools":["send_user_message_async","clock"],
           "model_messages":{"instructions_template":"template instructions","instructions_variables":{}}},
          {"slug":"pool-model","experimental_supported_tools":[],
           "model_messages":{"instructions_template":"pool instructions"}}
        ]}
        """
        let defaults = try XCTUnwrap(CodexModelCatalog.SchemaDefaults.decode(Data(cache.utf8)))
        let base = CodexModelCatalog.sanitizedEntries([
            ["slug": "pool-model", "context_window": 128_000],
            ["slug": "gpt-6.1-sol", "context_window": 128_000]
        ])
        let source = ModelSource(
            id: "openrouter",
            kind: .openRouter,
            title: "OpenRouter",
            baseURL: ModelSourcesStore.openRouterBaseURL,
            apiKey: "key",
            enabled: true,
            models: [SourceModel(
                id: "vision-model",
                display: "Vision Model",
                contextLength: nil,
                enabled: true,
                alias: "openrouter/vision-model",
                supportsImages: true
            )]
        )

        let (entries, custom) = CodexModelCatalog.generatedEntries(
            base: base,
            sources: [source],
            defaults: defaults
        )

        XCTAssertEqual(custom, 1)
        XCTAssertEqual(entries.count, 3)
        for entry in entries {
            let messages = entry["model_messages"] as? [String: Any]
            let template = messages?["instructions_template"] as? String
            let baseInstructions = entry["base_instructions"] as? String
            XCTAssertTrue(
                !(template ?? "").isEmpty || !(baseInstructions ?? "").isEmpty,
                "missing instructions for \(entry["slug"] as? String ?? "?")"
            )
            XCTAssertNotNil(entry["experimental_supported_tools"] as? [String])
        }

        let pool = try XCTUnwrap(entries.first { $0["slug"] as? String == "pool-model" })
        XCTAssertEqual(
            (pool["model_messages"] as? [String: Any])?["instructions_template"] as? String,
            "pool instructions"
        )
        let clone = try XCTUnwrap(entries.first { $0["slug"] as? String == "openrouter/vision-model" })
        XCTAssertEqual(
            (clone["model_messages"] as? [String: Any])?["instructions_template"] as? String,
            "template instructions"
        )
        XCTAssertEqual(clone["input_modalities"] as? [String], ["text", "image"])
        XCTAssertEqual(clone["experimental_supported_tools"] as? [String], ["send_user_message_async", "clock"])
    }

    /// No `models_cache.json`: every entry still gets the minimal prompt and
    /// the native tool list, so Codex can parse the catalog.
    func testGeneratedCatalogFallsBackWithoutCodexCache() throws {
        let base = CodexModelCatalog.sanitizedEntries([
            ["slug": "pool-model", "context_window": 128_000]
        ])
        let (entries, _) = CodexModelCatalog.generatedEntries(base: base, sources: [], defaults: nil)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry["base_instructions"] as? String, CodexModelCatalog.fallbackInstructions)
        XCTAssertEqual(entry["experimental_supported_tools"] as? [String], ["send_user_message_async", "clock"])
        XCTAssertNil(entry["model_messages"])
    }

    /// Private prompt fields are dropped while sanitizing the base, before the
    /// public template is injected.
    func testSanitizeRemovesPrivatePromptFieldsBeforeInjection() throws {
        let base = CodexModelCatalog.sanitizedEntries([[
            "slug": "pool-model",
            "context_window": 128_000,
            "base_instructions": "private instruction fixture",
            "model_messages": ["instructions_template": "private template fixture"]
        ]])
        let sanitized = try XCTUnwrap(base.first)
        XCTAssertNil(sanitized["base_instructions"])
        XCTAssertNil(sanitized["model_messages"])

        let cache = """
        {"models":[{"slug":"gpt-6.1-sol","experimental_supported_tools":["send_user_message_async","clock"],
         "model_messages":{"instructions_template":"public template"}}]}
        """
        let defaults = try XCTUnwrap(CodexModelCatalog.SchemaDefaults.decode(Data(cache.utf8)))
        let generated = try XCTUnwrap(
            CodexModelCatalog.applyRequiredSchema(to: base, defaults: defaults).first
        )
        XCTAssertEqual(
            (generated["model_messages"] as? [String: Any])?["instructions_template"] as? String,
            "public template"
        )
        XCTAssertNotEqual(generated["base_instructions"] as? String, "private instruction fixture")
    }
}

private struct ModelSourcesFixture: Codable {
    var sources: [ModelSource]
}
