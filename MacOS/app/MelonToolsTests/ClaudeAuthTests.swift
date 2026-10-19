import XCTest
@testable import MelonTools

/// Claude provider: engine auth-file parsing, the usage endpoint (both
/// documented-by-experiment shapes), the auth-dir cleanup guard, and the
/// gateway config merge (`api-keys.claude` inside the single root).
final class ClaudeAuthTests: XCTestCase {

    // MARK: - Auth files

    func testClaudeAuthFileDecodesTolerantly() throws {
        let data = Data(#"{"type":"claude","email":"dev@example.com","access_token":"tok-1","refresh_token":"ref-1"}"#.utf8)
        let file = try XCTUnwrap(ClaudeAuthService.decodeAuthFile(name: "claude-abcd1234-dev.json", path: "/tmp/x", data: data))
        XCTAssertEqual(file.email, "dev@example.com")
        XCTAssertEqual(file.accessToken, "tok-1")
        XCTAssertEqual(file.type, "claude")

        // No `type` at all: still a claude file for us (field is optional).
        let bare = Data(#"{"access_token":"tok-2"}"#.utf8)
        XCTAssertEqual(ClaudeAuthService.decodeAuthFile(name: "claude-x.json", path: "/tmp/x", data: bare)?.accessToken, "tok-2")

        // A foreign type must be rejected, as must non-JSON bytes.
        let foreign = Data(#"{"type":"codex","access_token":"tok-3"}"#.utf8)
        XCTAssertNil(ClaudeAuthService.decodeAuthFile(name: "codex-x.json", path: "/tmp/x", data: foreign))
        XCTAssertNil(ClaudeAuthService.decodeAuthFile(name: "claude-x.json", path: "/tmp/x", data: Data("not json".utf8)))
    }

    func testAuthFileNameFilterAndDirectoryScan() throws {
        XCTAssertTrue(ClaudeAuthService.isClaudeAuthFileName("claude-abcd-dev@example.com.json"))
        XCTAssertFalse(ClaudeAuthService.isClaudeAuthFileName("codex-old.json"))
        XCTAssertFalse(ClaudeAuthService.isClaudeAuthFileName("claude-x.txt"))

        let dir = try makeTempDir()
        try Data(#"{"type":"claude","email":"a@b.c"}"#.utf8).write(to: dir.appendingPathComponent("claude-1.json"))
        try Data(#"{"type":"codex"}"#.utf8).write(to: dir.appendingPathComponent("codex-1.json"))
        let files = ClaudeAuthService.authFiles(in: dir)
        XCTAssertEqual(files.map(\.name), ["claude-1.json"])
        XCTAssertEqual(files.first?.email, "a@b.c")
    }

    /// The connected account must be the most recently written file: a stale
    /// `claude-*` leftover must not shadow the account that was just linked.
    func testAuthFilesPreferMostRecentlyModified() throws {
        let dir = try makeTempDir()
        let fm = FileManager.default
        let older = dir.appendingPathComponent("claude-aaaa-older.json")
        let newer = dir.appendingPathComponent("claude-zzzz-newer.json")
        try Data(#"{"type":"claude","email":"older@example.com"}"#.utf8).write(to: older)
        try Data(#"{"type":"claude","email":"newer@example.com"}"#.utf8).write(to: newer)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: older.path)
        try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: newer.path)

        let files = ClaudeAuthService.authFiles(in: dir)
        XCTAssertEqual(files.map(\.name), ["claude-zzzz-newer.json", "claude-aaaa-older.json"])
        XCTAssertEqual(files.first?.email, "newer@example.com")
    }

    // MARK: - Usage parsing

    func testLegacyUsageShapeParses() throws {
        let data = Data(#"""
        {"five_hour":{"utilization":37.5,"resets_at":"2026-10-19T12:00:00Z"},
         "seven_day":{"utilization":10,"resets_at":"2026-10-20T12:00:00.500Z"}}
        """#.utf8)
        let snapshot = try XCTUnwrap(ClaudeAuthService.parseUsage(data))
        XCTAssertEqual(snapshot.fiveHourPercent, 62.5)
        XCTAssertNotNil(snapshot.fiveHourReset)
        XCTAssertEqual(snapshot.weeklyPercent, 90)
        XCTAssertNotNil(snapshot.weeklyReset)
        XCTAssertNil(snapshot.plan)
    }

    func testNewLimitsShapeParsesAndClamps() throws {
        let data = Data(#"""
        {"limits":[
          {"kind":"session","percent":25,"resets_at":"2026-10-19T12:00:00Z"},
          {"kind":"weekly_all","percent":120,"resets_at":"2026-10-20T12:00:00Z"},
          {"kind":"weekly_scoped","percent":5,"scope":{"model":{"display_name":"Opus"}}}
        ]}
        """#.utf8)
        let snapshot = try XCTUnwrap(ClaudeAuthService.parseUsage(data))
        XCTAssertEqual(snapshot.fiveHourPercent, 75)
        XCTAssertEqual(snapshot.weeklyPercent, 0)
        XCTAssertNotNil(snapshot.fiveHourReset)
        XCTAssertNotNil(snapshot.weeklyReset)
    }

    func testMissingUsageFieldsStayNil() {
        XCTAssertNil(ClaudeAuthService.parseUsage(Data("{}".utf8)))
        XCTAssertNil(ClaudeAuthService.parseUsage(Data("not json".utf8)))
        XCTAssertNil(ClaudeAuthService.parseUsage(Data(#"{"five_hour":{}}"#.utf8)))
    }

    func testPlanAppearsOnlyWhenPayloadCarriesIt() throws {
        let data = Data(#"{"subscriptionType":"max","five_hour":{"utilization":0}}"#.utf8)
        let snapshot = try XCTUnwrap(ClaudeAuthService.parseUsage(data))
        XCTAssertEqual(snapshot.plan, "max")
        XCTAssertEqual(snapshot.fiveHourPercent, 100)
    }

    // MARK: - Auth-dir cleanup guard (AC2)

    func testSyncAccountsPreservesClaudeAuthFiles() throws {
        let dir = try makeTempDir()
        let fm = FileManager.default
        try Data(#"{"type":"claude","email":"a@b.c"}"#.utf8).write(to: dir.appendingPathComponent("claude-abc.json"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("codex-old.json"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("notes.json"))

        try CodexGatewayService.syncAccounts([], priorities: [:], authDir: dir)

        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("claude-abc.json").path), "claude auth file must survive the sync")
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("notes.json").path), "foreign files must survive the sync")
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("codex-old.json").path), "stale codex files are replaced")
    }

    func testSyncAccountsWritesCodexAuthFile() throws {
        let dir = try makeTempDir()
        var tokens = CodexTokens(id_token: "id", access_token: "access-1")
        tokens.refresh_token = "refresh-1"
        var account = CodexAccount(tokens: tokens)
        account.email = "user@example.com"

        try CodexGatewayService.syncAccounts([account], priorities: [account.id: 5], authDir: dir)

        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let file = try XCTUnwrap(names.first { $0.hasPrefix("codex-") && $0.hasSuffix(".json") })
        let data = try Data(contentsOf: dir.appendingPathComponent(file))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "codex")
        XCTAssertEqual(json["access_token"] as? String, "access-1")
        XCTAssertEqual(json["priority"] as? Int, 5)
    }

    // MARK: - Gateway config generation (AC6)

    private func claudeSource(key: String, enabled: Bool = true, modelEnabled: Bool = true) -> ModelSource {
        ModelSource(
            id: "claude",
            kind: .claude,
            title: "Claude",
            baseURL: ModelSourcesStore.claudeBaseURL,
            apiKey: key,
            enabled: enabled,
            models: [SourceModel(
                id: "claude-opus-4-6",
                display: "Opus 4.6",
                contextLength: 200_000,
                enabled: modelEnabled,
                alias: "claude-opus-4-6",
                freeTier: nil
            )]
        )
    }

    private func openRouterSource() -> ModelSource {
        ModelSource(
            id: "openrouter",
            kind: .openRouter,
            title: "OpenRouter",
            baseURL: "https://openrouter.ai/api/v1",
            apiKey: "or-key",
            enabled: true,
            models: [SourceModel(
                id: "deepseek/deepseek-v3",
                display: "DeepSeek V3",
                contextLength: nil,
                enabled: true,
                alias: "openrouter/deepseek/deepseek-v3",
                freeTier: nil
            )]
        )
    }

    func testClaudeApiKeyMergesIntoTheSingleApiKeysRoot() {
        let yaml = ModelSourcesStore.gatewayYAML(sources: [openRouterSource(), claudeSource(key: "sk-ant-test")])
        XCTAssertEqual(yaml.components(separatedBy: "api-keys:").count - 1, 1, "exactly one api-keys root")
        XCTAssertTrue(yaml.contains("  openai-compatibility:"))
        XCTAssertTrue(yaml.contains("  claude:"))
        XCTAssertTrue(yaml.contains("sk-ant-test"))
        XCTAssertTrue(yaml.contains("- name: \"claude-opus-4-6\""))
        XCTAssertTrue(yaml.contains("alias: \"claude-opus-4-6\""))
    }

    func testOAuthClaudeSourceEmitsNothing() {
        // No API key: the engine serves the account from its own auth file.
        let oauth = claudeSource(key: "")
        XCTAssertEqual(ModelSourcesStore.gatewayYAML(sources: [oauth]), "")
        // With other sources present the claude section must not appear.
        let yaml = ModelSourcesStore.gatewayYAML(sources: [openRouterSource(), oauth])
        XCTAssertFalse(yaml.contains("\n  claude:\n"))
        XCTAssertTrue(yaml.contains("openai-compatibility"))
    }

    func testClaudeSectionSkippedWhenNoModelsSelected() {
        let source = claudeSource(key: "sk-ant-test", modelEnabled: false)
        XCTAssertEqual(ModelSourcesStore.gatewayYAML(sources: [source]), "")
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("melon-claude-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
}
