import XCTest
@testable import MelonTools

/// The diagnostics card is a pure evidence → rows mapping; these tests cover
/// the auth-file prefixes, the `owned_by` model filters, and the status rules.
final class ProviderDiagnosticsTests: XCTestCase {
    private func evidence(
        gatewayStatusCode: Int? = 200,
        gatewayError: String? = nil,
        modelsError: String? = nil,
        authFileNames: [String] = [],
        models: [ProviderDiagnostics.ModelEntry] = [],
        keys: ProviderDiagnostics.Evidence.Keys = .init(),
        quotaUpdatedAt: [String: Date] = [:],
        quotaErrors: [String: String] = [:]
    ) -> ProviderDiagnostics.Evidence {
        ProviderDiagnostics.Evidence(
            gatewayStatusCode: gatewayStatusCode,
            gatewayError: gatewayError,
            modelsError: modelsError,
            authFileNames: authFileNames,
            models: models,
            keys: keys,
            quotaUpdatedAt: quotaUpdatedAt,
            quotaErrors: quotaErrors
        )
    }

    private let allAuthNames = [
        "codex-work-12345678.json",
        "codex-home-87654321.json",
        "claude-me@example.com.json",
        "antigravity.json",
        "antigravity-other@example.com.json",
    ]

    func testAuthFilePrefixesAreSeparated() {
        let names = allAuthNames + ["model-sources.json", "codex-notes.txt", "claude.txt"]
        XCTAssertEqual(ProviderDiagnostics.authFileCount(id: "codex", names: names), 2)
        XCTAssertEqual(ProviderDiagnostics.authFileCount(id: "claude", names: names), 1)
        XCTAssertEqual(ProviderDiagnostics.authFileCount(id: "antigravity", names: names), 2)
        XCTAssertEqual(ProviderDiagnostics.authFileCount(id: "openrouter", names: names), 0)
        XCTAssertEqual(ProviderDiagnostics.authFileCount(id: "deepinfra", names: names), 0)
        XCTAssertEqual(ProviderDiagnostics.authFileCount(id: "vercel", names: names), 0)
    }

    func testModelCountsUseOwnershipAndTheAntigravityRegistry() {
        let models = [
            ProviderDiagnostics.ModelEntry(id: "gpt-5.2", owner: "openai"),
            ProviderDiagnostics.ModelEntry(id: "claude-opus-4-5", owner: nil),
            ProviderDiagnostics.ModelEntry(id: "claude-sonnet-4-6", owner: "antigravity"),
            ProviderDiagnostics.ModelEntry(id: "gemini-4-argon-high", owner: nil),
            ProviderDiagnostics.ModelEntry(id: "openrouter/openai/gpt-4o", owner: "openrouter"),
            ProviderDiagnostics.ModelEntry(id: "opencode/big-pickle", owner: "opencode"),
            ProviderDiagnostics.ModelEntry(id: "deepinfra/deepseek-ai/DeepSeek-V4", owner: "deepinfra"),
            ProviderDiagnostics.ModelEntry(id: "vercel/anthropic/claude-sonnet-4.6", owner: "vercel"),
        ]
        XCTAssertEqual(ProviderDiagnostics.modelCount(id: "codex", models: models), 1)
        XCTAssertEqual(ProviderDiagnostics.modelCount(id: "claude", models: models), 1)
        XCTAssertEqual(ProviderDiagnostics.modelCount(id: "antigravity", models: models), 2)
        XCTAssertEqual(ProviderDiagnostics.modelCount(id: "openrouter", models: models), 1)
        XCTAssertEqual(ProviderDiagnostics.modelCount(id: "opencode", models: models), 1)
        XCTAssertEqual(ProviderDiagnostics.modelCount(id: "deepinfra", models: models), 1)
        XCTAssertEqual(ProviderDiagnostics.modelCount(id: "vercel", models: models), 1)
    }

    func testRowsAreOKWithGatewayAuthAndKeys() {
        let date = Date(timeIntervalSince1970: 1_000_000)
        let rows = ProviderDiagnostics.rows(evidence(
            authFileNames: allAuthNames,
            models: [ProviderDiagnostics.ModelEntry(id: "gpt-5.2", owner: "openai")],
            keys: .init(openRouter: true, openCode: true, deepInfra: true, vercel: true, claude: true),
            quotaUpdatedAt: ["claude": date]
        ))

        XCTAssertEqual(rows.map(\.id), ProviderDiagnostics.ids)
        XCTAssertEqual(rows.map(\.status), Array(repeating: .ok, count: 7))
        XCTAssertEqual(rows.first { $0.id == "claude" }?.quotaUpdatedAt, date)
        XCTAssertEqual(rows.allSatisfy(\.authPresent), true)
        XCTAssertEqual(rows.first { $0.id == "codex" }?.modelCount, 1)
    }

    func testMissingCredentialsAreAWarning() {
        let rows = ProviderDiagnostics.rows(evidence())

        XCTAssertEqual(rows.map(\.status), Array(repeating: .warning, count: 7))
        XCTAssertTrue(rows.allSatisfy { !$0.authPresent })
    }

    func testGatewayFailureMarksEveryRowFailedAndKeepsTheErrorVerbatim() {
        let rows = ProviderDiagnostics.rows(evidence(
            gatewayStatusCode: nil,
            gatewayError: "Could not connect to the server.",
            authFileNames: allAuthNames
        ))

        XCTAssertEqual(rows.map(\.status), Array(repeating: .failed, count: 7))
        XCTAssertTrue(rows.allSatisfy { $0.error == "Could not connect to the server." })
        XCTAssertTrue(rows.allSatisfy { $0.modelCount == nil })
    }

    func testQuotaErrorsStayVerbatim() {
        let rows = ProviderDiagnostics.rows(evidence(
            authFileNames: allAuthNames,
            keys: .init(openRouter: true, openCode: true, deepInfra: true, vercel: true, claude: true),
            quotaErrors: ["claude": "HTTP 429 Too Many Requests"]
        ))

        let claude = rows.first { $0.id == "claude" }
        XCTAssertEqual(claude?.status, .warning)
        XCTAssertEqual(claude?.error, "HTTP 429 Too Many Requests")
        XCTAssertEqual(rows.filter { $0.id != "claude" }.map(\.status), Array(repeating: .ok, count: 6))
    }

    func testModelListDecodeFailureIsVisible() {
        let rows = ProviderDiagnostics.rows(evidence(
            modelsError: "The data could not be read.",
            authFileNames: allAuthNames
        ))

        XCTAssertEqual(rows.map(\.status), Array(repeating: .warning, count: 7))
        XCTAssertTrue(rows.allSatisfy { $0.error == "The data could not be read." })
        XCTAssertTrue(rows.allSatisfy { $0.modelCount == nil })
    }
}
