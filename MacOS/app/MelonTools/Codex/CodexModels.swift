import Foundation

// MARK: - Account model

struct CodexTokens: Codable, Equatable {
    var id_token: String?
    var access_token: String?
    var refresh_token: String?
    var account_id: String?
}

struct CodexAccount: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var email: String?
    var planType: String?
    var accountId: String?
    var userId: String?
    var subscriptionActiveUntil: String?
    /// When `subscriptionActiveUntil` was last re-read from the backend.
    var subscriptionUpdatedAt: Date?
    var tokens: CodexTokens
    var lastRefresh: String?
    var addedAt: Date = Date()
    var note: String?

    // Quota cache
    var quota: CodexQuota?
    var quotaUpdatedAt: Date?
    var quotaError: String?

    // Routing preferences (Melon Tools). Optional so vaults written before
    // this feature still decode; nil means “off”.
    /// Pause this account when the 5-hour quota left drops to this percent (1…100).
    var hourlyReservePercent: Int?
    /// Pause this account when the weekly quota left drops to this percent (1…100).
    var weeklyReservePercent: Int?
    /// Keep this account first in automatic routing modes.
    var preferredFirst: Bool?
    /// Use this account only when the regular accounts are unavailable.
    var isBackup: Bool?

    var displayName: String { email ?? accountId ?? id }
    var isOpaqueToken: Bool { tokens.access_token?.hasPrefix("at-") == true }

    /// Access token expiry from JWT `exp`, when decodable.
    var accessTokenExpiry: Date? {
        guard let token = tokens.access_token, !isOpaqueToken else { return nil }
        return JWT.expiry(token)
    }

    var needsRefresh: Bool {
        guard let expiry = accessTokenExpiry else { return false }
        return expiry.timeIntervalSinceNow < 300
    }
}

/// Per-model availability reported by `wham/usage` (`model_usage`).
struct CodexModelAvailability: Codable, Equatable, Identifiable {
    var model: String
    var available: Bool
    var availableAt: String?
    var creditsWouldEnable: Bool?

    var id: String { model }
}

struct CodexQuota: Codable, Equatable {
    var planType: String?
    /// Percentage of the hourly (primary) window still available, 0...100.
    var hourlyRemainingPercent: Double?
    var hourlyResetAt: Date?
    var hourlyWindowMinutes: Int?
    var hourlyWindowPresent: Bool?
    /// Percentage of the weekly (secondary) window still available, 0...100.
    var weeklyRemainingPercent: Double?
    var weeklyResetAt: Date?
    var weeklyWindowMinutes: Int?
    var weeklyWindowPresent: Bool?
    var resetCreditsAvailable: Int?
    /// Nearest expiry of the available reset credits (`wham/rate-limit-reset-credits`).
    var resetCreditsNextExpiry: Date?
    /// Model availability list (`model_usage` dict, key = model id).
    var modelAvailability: [CodexModelAvailability]?
    /// Credits block.
    var hasCredits: Bool?
    var unlimitedCredits: Bool?
    var creditsBalance: String?
    var fetchedAt: Date?
    var rawJSON: String?
}

// MARK: - Official auth.json shape

struct CodexAuthFile: Codable {
    var auth_mode: String?
    var OPENAI_API_KEY: String?
    var tokens: CodexTokens?
    var last_refresh: String?
    var personal_access_token: String?

    enum CodingKeys: String, CodingKey {
        case auth_mode
        case OPENAI_API_KEY
        case tokens
        case last_refresh
        case personal_access_token
    }

    /// Explicit encoder that keeps the full file shape the Codex app expects.
    /// JSONEncoder drops nil optionals, and an `auth.json` without
    /// `auth_mode`/`tokens.account_id` makes Codex log “waiting for a ChatGPT
    /// account id”, then block chatting with “failed to load workspace
    /// settings”.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(auth_mode, forKey: .auth_mode)
        try container.encode(OPENAI_API_KEY, forKey: .OPENAI_API_KEY)
        try container.encodeIfPresent(tokens, forKey: .tokens)
        try container.encodeIfPresent(last_refresh, forKey: .last_refresh)
        try container.encodeIfPresent(personal_access_token, forKey: .personal_access_token)
    }

    static func load(from path: String) throws -> CodexAuthFile? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(CodexAuthFile.self, from: data)
    }

    /// A complete auth file for the Codex app, built from a vault account.
    /// Fills what the app relies on: `auth_mode` and `tokens.account_id`
    /// (from the stored value, the account record, or the id_token claim).
    static func make(from account: CodexAccount) -> CodexAuthFile {
        var tokens = account.tokens
        if tokens.account_id == nil || tokens.account_id?.isEmpty == true {
            tokens.account_id = account.accountId ?? JWT.codexClaims(idToken: tokens.id_token).accountId
        }
        var auth = CodexAuthFile()
        auth.auth_mode = "chatgpt"
        auth.tokens = tokens
        auth.last_refresh = ISO8601DateFormatter().string(from: Date())
        return auth
    }

    func encoded() throws -> Data {
        try JSONEncoder.pretty.encode(self)
    }
}

// MARK: - JWT helper

enum JWT {
    static func payload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    static func expiry(_ token: String) -> Date? {
        guard let payload = payload(token), let exp = payload["exp"] as? TimeInterval else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    /// Extract identity claims for a Codex account from its id_token.
    static func codexClaims(idToken: String?) -> (email: String?, planType: String?, accountId: String?, userId: String?, subscriptionUntil: String?) {
        guard let idToken, let payload = payload(idToken) else { return (nil, nil, nil, nil, nil) }
        var email = payload["email"] as? String
        if let auth = payload["https://api.openai.com/auth"] as? [String: Any] {
            return (
                email,
                auth["chatgpt_plan_type"] as? String,
                // The claim key is `chatgpt_account_id`; plain `account_id`
                // does not exist in the auth block.
                (auth["chatgpt_account_id"] as? String) ?? (auth["account_id"] as? String),
                auth["chatgpt_user_id"] as? String,
                auth["chatgpt_subscription_active_until"] as? String
            )
        }
        if let profile = payload["https://api.openai.com/profile"] as? [String: Any] {
            email = profile["email"] as? String ?? email
        }
        return (email, nil, nil, nil, nil)
    }
}

// MARK: - Encoder helper

extension JSONEncoder {
    static let pretty: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

// MARK: - Plan display

extension String {
    var planDisplayName: String {
        switch lowercased() {
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "free": return "Free"
        case "self_serve_business_usage_based": return "Business (usage-based)"
        case "": return "Unknown"
        default: return self
        }
    }
}
