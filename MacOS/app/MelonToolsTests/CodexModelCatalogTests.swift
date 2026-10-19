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
        XCTAssertNil(sanitized["experimental_supported_tools"])

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
        XCTAssertEqual(CodexModelCatalog.priorityBase(for: .claude), 300)
        XCTAssertEqual(CodexModelCatalog.providerTag(for: .claude), "Claude")
        XCTAssertEqual(CodexModelCatalog.priorityBase(for: .openRouter), 200)
        XCTAssertEqual(CodexModelCatalog.priorityBase(for: .openCode), 100)
    }

    /// Antigravity sits in the last band (400) with its own picker tag.
    func testAntigravityBandAndProviderTag() {
        XCTAssertEqual(CodexModelCatalog.priorityBase(for: .antigravity), 400)
        XCTAssertEqual(CodexModelCatalog.providerTag(for: .antigravity), "Antigravity")
        XCTAssertEqual(CodexModelCatalog.priorityBase(for: .claude), 300)
        XCTAssertEqual(CodexModelCatalog.priorityBase(for: .openRouter), 200)
        XCTAssertEqual(CodexModelCatalog.priorityBase(for: .openCode), 100)
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
}
