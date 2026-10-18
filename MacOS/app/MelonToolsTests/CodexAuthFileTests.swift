import XCTest
@testable import MelonTools

/// The Codex app resolves its ChatGPT account from `~/.codex/auth.json`.
/// A file written without `tokens.account_id`/`auth_mode` (JSONEncoder drops
/// nil optionals) made Codex log “waiting for a ChatGPT account id” and block
/// chatting with “failed to load workspace settings” — these tests pin the
/// full file shape.
final class CodexAuthFileTests: XCTestCase {

    private static func jwt(accountId: String) -> String {
        let payload: [String: Any] = [
            "https://api.openai.com/auth": ["chatgpt_account_id": accountId]
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let b64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(b64).signature"
    }

    private func decoded(_ auth: CodexAuthFile) throws -> [String: Any] {
        let data = try auth.encoded()
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testAuthFileCarriesModeAndAccountID() throws {
        var tokens = CodexTokens(id_token: Self.jwt(accountId: "claim-id"))
        tokens.access_token = "access-token"
        tokens.refresh_token = "refresh-token"
        var account = CodexAccount(tokens: tokens)
        account.accountId = "acct-123"

        let json = try decoded(CodexAuthFile.make(from: account))

        XCTAssertEqual(json["auth_mode"] as? String, "chatgpt")
        XCTAssertTrue(json.keys.contains("OPENAI_API_KEY"), "the key must be present (null), like the app writes it")
        let tokensJSON = try XCTUnwrap(json["tokens"] as? [String: Any])
        XCTAssertEqual(tokensJSON["account_id"] as? String, "acct-123")
        XCTAssertEqual(tokensJSON["access_token"] as? String, "access-token")
        XCTAssertEqual(tokensJSON["refresh_token"] as? String, "refresh-token")
    }

    func testAuthFileFallsBackToTokenClaim() throws {
        let account = CodexAccount(tokens: CodexTokens(id_token: Self.jwt(accountId: "from-claim")))

        let json = try decoded(CodexAuthFile.make(from: account))

        let tokensJSON = try XCTUnwrap(json["tokens"] as? [String: Any])
        XCTAssertEqual(tokensJSON["account_id"] as? String, "from-claim")
    }

    func testStoredTokensAccountIDWins() throws {
        var tokens = CodexTokens(id_token: Self.jwt(accountId: "claim-id"))
        tokens.account_id = "stored-id"
        var account = CodexAccount(tokens: tokens)
        account.accountId = "record-id"

        let json = try decoded(CodexAuthFile.make(from: account))

        let tokensJSON = try XCTUnwrap(json["tokens"] as? [String: Any])
        XCTAssertEqual(tokensJSON["account_id"] as? String, "stored-id")
    }
}
