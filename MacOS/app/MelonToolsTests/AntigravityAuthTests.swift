import XCTest
@testable import MelonTools

/// Antigravity provider: engine auth-file parsing, the disconnect scope guard,
/// provider ownership filtering (the `claude-*` collision with Claude), and the
/// OAuth-only gateway behaviour.
final class AntigravityAuthTests: XCTestCase {

    // MARK: - Auth files

    func testAntigravityAuthFileDecodesTolerantly() throws {
        let data = Data(#"{"type":"antigravity","email":"dev@example.com","access_token":"tok-1","project_id":"proj-1","expires_in":3600}"#.utf8)
        let file = try XCTUnwrap(AntigravityAuthService.decodeAuthFile(name: "antigravity-dev@example.com.json", path: "/tmp/x", data: data))
        XCTAssertEqual(file.email, "dev@example.com")
        XCTAssertEqual(file.accessToken, "tok-1")
        XCTAssertEqual(file.projectID, "proj-1")
        XCTAssertEqual(file.type, "antigravity")

        // No `type` at all: still an Antigravity file (field is optional).
        let bare = Data(#"{"access_token":"tok-2","project_id":"proj-2"}"#.utf8)
        XCTAssertEqual(AntigravityAuthService.decodeAuthFile(name: "antigravity.json", path: "/tmp/x", data: bare)?.projectID, "proj-2")

        // A foreign type must be rejected, as must non-JSON bytes.
        let foreign = Data(#"{"type":"claude","access_token":"tok-3"}"#.utf8)
        XCTAssertNil(AntigravityAuthService.decodeAuthFile(name: "antigravity-x.json", path: "/tmp/x", data: foreign))
        XCTAssertNil(AntigravityAuthService.decodeAuthFile(name: "antigravity-x.json", path: "/tmp/x", data: Data("not json".utf8)))
    }

    func testAuthFileNamePredicate() {
        XCTAssertTrue(AntigravityAuthService.isAuthFileName("antigravity.json"))
        XCTAssertTrue(AntigravityAuthService.isAuthFileName("antigravity-dev@example.com.json"))
        XCTAssertFalse(AntigravityAuthService.isAuthFileName("claude-dev@example.com.json"))
        XCTAssertFalse(AntigravityAuthService.isAuthFileName("codex-1.json"))
        XCTAssertFalse(AntigravityAuthService.isAuthFileName("antigravity-notes.txt"))
        XCTAssertFalse(AntigravityAuthService.isAuthFileName("xantigravity-1.json"))
    }

    func testAuthFilesPreferMostRecentlyModified() throws {
        let dir = try makeTempDir()
        let fm = FileManager.default
        let older = dir.appendingPathComponent("antigravity-aaaa-older.json")
        let newer = dir.appendingPathComponent("antigravity-zzzz-newer.json")
        try Data(#"{"type":"antigravity","email":"older@example.com","project_id":"old"}"#.utf8).write(to: older)
        try Data(#"{"type":"antigravity","email":"newer@example.com","project_id":"new"}"#.utf8).write(to: newer)
        try Data(#"{"type":"claude","email":"claude@example.com"}"#.utf8).write(to: dir.appendingPathComponent("claude-1.json"))
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: older.path)
        try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: newer.path)

        let files = AntigravityAuthService.authFiles(in: dir)
        XCTAssertEqual(files.map(\.name), ["antigravity-zzzz-newer.json", "antigravity-aaaa-older.json"])
        XCTAssertEqual(files.first?.email, "newer@example.com")
        XCTAssertEqual(files.first?.projectID, "new")
    }

    /// AC6: disconnect removes Antigravity auth files only. Claude/Codex files
    /// and foreign files must survive.
    func testDeleteAuthFilesOnlyRemovesAntigravityFiles() throws {
        let dir = try makeTempDir()
        let fm = FileManager.default
        try Data(#"{"type":"antigravity","email":"a@b.c"}"#.utf8).write(to: dir.appendingPathComponent("antigravity-a@b.c.json"))
        try Data(#"{"type":"antigravity","email":"b@b.c"}"#.utf8).write(to: dir.appendingPathComponent("antigravity.json"))
        try Data(#"{"type":"claude","email":"c@b.c"}"#.utf8).write(to: dir.appendingPathComponent("claude-abc.json"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("codex-old.json"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("notes.json"))

        let removed = AntigravityAuthService.deleteAuthFiles(in: dir)

        XCTAssertEqual(Set(removed), ["antigravity-a@b.c.json", "antigravity.json"])
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("antigravity-a@b.c.json").path))
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("antigravity.json").path))
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("claude-abc.json").path), "Claude auth file must survive")
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("codex-old.json").path), "Codex auth file must survive")
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("notes.json").path), "foreign files must survive")
    }

    // MARK: - Model ownership (AC4)

    /// `/v1/models` exposes `owned_by`; `claude-sonnet-4-6` is served by both
    /// Antigravity and Claude, so ownership (not the id prefix) decides.
    func testOwnershipFilteringFixture() {
        // Explicit ownership: Antigravity claims its entry, Claude the other.
        XCTAssertTrue(ModelSourcesStore.isAntigravityModel(id: "claude-sonnet-4-6", owner: "antigravity"))
        XCTAssertFalse(ModelSourcesStore.isAntigravityModel(id: "claude-sonnet-4-6", owner: "anthropic"))
        XCTAssertTrue(ModelSourcesStore.isClaudeModel(id: "claude-sonnet-4-6", owner: "anthropic"))
        XCTAssertFalse(ModelSourcesStore.isClaudeModel(id: "claude-sonnet-4-6", owner: "antigravity"))

        // Ownership wins over the id allowlist.
        XCTAssertFalse(ModelSourcesStore.isAntigravityModel(id: "gemini-4-argon-high", owner: "openai"))

        // Ownership is case-insensitive.
        XCTAssertTrue(ModelSourcesStore.isAntigravityModel(id: "claude-sonnet-4-6", owner: "Antigravity"))

        // Old payload without ownership: fall back to the registry allowlist,
        // and subtract the same set from the Claude loader.
        XCTAssertTrue(ModelSourcesStore.isAntigravityModel(id: "gemini-4-argon-high", owner: nil))
        XCTAssertTrue(ModelSourcesStore.isAntigravityModel(id: "gpt-oss-120b-medium", owner: nil))
        XCTAssertFalse(ModelSourcesStore.isClaudeModel(id: "claude-opus-4-6-thinking", owner: nil))
        XCTAssertFalse(ModelSourcesStore.isClaudeModel(id: "claude-sonnet-4-6", owner: nil))
        XCTAssertTrue(ModelSourcesStore.isClaudeModel(id: "claude-opus-4-5", owner: nil))

        // Non-Claude ids never enter the Claude source.
        XCTAssertFalse(ModelSourcesStore.isClaudeModel(id: "gpt-6.1-sol", owner: nil))
        XCTAssertFalse(ModelSourcesStore.isClaudeModel(id: "gemini-4-argon-high", owner: "antigravity"))
    }

    func testAntigravityRegistryAllowlistMatchesVerifiedEngineIds() {
        XCTAssertEqual(AntigravityModelRegistry.ids.count, 11)
        XCTAssertTrue(AntigravityModelRegistry.ids.contains("claude-opus-5-5-high"))
        XCTAssertTrue(AntigravityModelRegistry.ids.contains("gemini-3.5-flash-lite"))
        XCTAssertFalse(AntigravityModelRegistry.ids.contains("claude-opus-4-5"))
    }

    // MARK: - OAuth plumbing / gateway

    func testAuthURLAndStatusParsing() throws {
        let payload = Data(#"{"url":"https://accounts.google.com/o/oauth2/auth?x=1","state":"state-1"}"#.utf8)
        let parsed = try XCTUnwrap(AntigravityAuthService.parseAuthURLResponse(payload))
        XCTAssertEqual(parsed.state, "state-1")
        XCTAssertTrue(parsed.url.hasPrefix("https://accounts.google.com/"))
        XCTAssertNil(AntigravityAuthService.parseAuthURLResponse(Data(#"{"state":"x"}"#.utf8)))

        XCTAssertEqual(AntigravityAuthService.parseStatusResponse(Data(#"{"status":"wait"}"#.utf8)), "wait")
        XCTAssertNil(AntigravityAuthService.parseStatusResponse(Data("{}".utf8)))
    }

    func testCredentialsParsingIsTolerant() {
        let wrapped = Data(#"{"credentials":[{"name":"antigravity-a@b.c.json","type":"antigravity","email":"a@b.c"}]}"#.utf8)
        let credentials = AntigravityAuthService.parseCredentials(wrapped)
        XCTAssertEqual(credentials.first?.name, "antigravity-a@b.c.json")
        XCTAssertEqual(credentials.first?.email, "a@b.c")

        let rootArray = Data(#"[{"file":"antigravity.json","type":"antigravity"}]"#.utf8)
        XCTAssertEqual(AntigravityAuthService.parseCredentials(rootArray).first?.name, "antigravity.json")
        XCTAssertTrue(AntigravityAuthService.parseCredentials(Data("not json".utf8)).isEmpty)
    }

    /// OAuth-only: no key, no `api-keys` block. Claude/OpenRouter behaviour is
    /// unaffected (covered by ClaudeAuthTests).
    func testAntigravitySourceEmitsNoGatewayYAML() {
        let source = ModelSource(
            id: "antigravity",
            kind: .antigravity,
            title: "Antigravity",
            baseURL: "",
            apiKey: "",
            enabled: true,
            models: [SourceModel(
                id: "gemini-4-argon-high",
                display: "Gemini 4 Argon",
                contextLength: 1_048_576,
                enabled: true,
                alias: "gemini-4-argon-high"
            )]
        )
        XCTAssertEqual(ModelSourcesStore.gatewayYAML(sources: [source]), "")
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("melon-antigravity-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
}
