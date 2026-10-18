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
}
