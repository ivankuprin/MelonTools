import Foundation

/// High-level pool routing strategies, inspired by the account modes other
/// Codex tools offer: auto, quota-first, plan-first, expiry-first and a
/// manual order. The planner turns the chosen mode plus per-account limits,
/// “always first” and “backup” roles into the concrete account order that
/// the gateway follows (higher priority = used sooner, next account takes
/// over automatically when the leader runs out or hits a user limit).
enum CodexRoutingStrategy: String, CaseIterable, Identifiable {
    case auto
    case quotaHighFirst
    case quotaLowFirst
    case planHighFirst
    case planLowFirst
    case expirySoonFirst
    case custom

    var id: String { rawValue }

    /// Migrates legacy stored values (“round-robin”, “fill-first”).
    static func migrate(_ raw: String?) -> CodexRoutingStrategy {
        switch raw {
        case "fill-first": return .custom
        case "round-robin": return .auto
        default: return raw.flatMap(CodexRoutingStrategy.init(rawValue:)) ?? .auto
        }
    }

    var title: String {
        switch self {
        case .auto: return L("Auto (recommended)")
        case .quotaHighFirst: return L("Most quota left first")
        case .quotaLowFirst: return L("Least quota left first")
        case .planHighFirst: return L("Top plan first")
        case .planLowFirst: return L("Lower plan first")
        case .expirySoonFirst: return L("Expiring soon first")
        case .custom: return L("Manual order")
        }
    }

    var hint: String {
        switch self {
        case .auto:
            return L("The “always first” account leads; then the one with the most quota left. Backups go last.")
        case .quotaHighFirst:
            return L("The account with the most quota left is used first.")
        case .quotaLowFirst:
            return L("The account with the least quota left is used first — it drains before switching.")
        case .planHighFirst:
            return L("Higher-tier subscriptions are used first.")
        case .planLowFirst:
            return L("Lower-tier subscriptions are used first.")
        case .expirySoonFirst:
            return L("The account whose subscription ends soonest is used first.")
        case .custom:
            return L("Order is set with the arrows; limits and the backup role still apply.")
        }
    }
}

/// Pure routing planner: accounts in, effective order out. No side effects so
/// the same result can feed both the gateway priorities and the UI.
enum CodexRoutingPlanner {
    struct Resolution {
        /// Account ids from the first account to the last (highest priority first).
        var orderedIds: [String]
        /// Accounts currently paused because a user limit was reached.
        var blocked: Set<String>
        /// Human-readable reason for every paused account.
        var blockReasons: [String: String]
    }

    /// Returns the reason this account is paused, or nil when it may be used.
    /// A limit of 0 (or none) means “no limit”. Quota readings older than
    /// `quotaFreshness` never block — a stale gauge must not park an account.
    static func blockReason(_ account: CodexAccount) -> String? {
        guard let quota = account.quota, quotaIsFresh(account) else { return nil }
        if let remaining = quota.hourlyRemainingPercent, remaining <= 0 {
            return L("5-hour quota exhausted")
        }
        if let remaining = quota.weeklyRemainingPercent, remaining <= 0 {
            return L("weekly quota exhausted")
        }
        if let hourlyLimit = account.hourlyReservePercent, hourlyLimit > 0,
           let remaining = quota.hourlyRemainingPercent, remaining <= Double(hourlyLimit) {
            return String(format: L("5-hour quota left %d%% ≤ %d%%"), Int(remaining.rounded()), hourlyLimit)
        }
        if let weeklyLimit = account.weeklyReservePercent, weeklyLimit > 0,
           let remaining = quota.weeklyRemainingPercent, remaining <= Double(weeklyLimit) {
            return String(format: L("weekly quota left %d%% ≤ %d%%"), Int(remaining.rounded()), weeklyLimit)
        }
        return nil
    }

    /// How long a quota reading stays believable.
    static let quotaFreshness: TimeInterval = 1800

    static func quotaIsFresh(_ account: CodexAccount) -> Bool {
        guard let updated = account.quotaUpdatedAt else { return false }
        return Date().timeIntervalSince(updated) < quotaFreshness
    }

    static func resolve(accounts: [CodexAccount], strategy: CodexRoutingStrategy, manualOrder: [String]) -> Resolution {
        var manualIndex: [String: Int] = [:]
        for (index, id) in manualOrder.enumerated() where manualIndex[id] == nil {
            manualIndex[id] = index
        }

        var blocked: Set<String> = []
        var reasons: [String: String] = [:]
        for account in accounts {
            if let reason = blockReason(account) {
                blocked.insert(account.id)
                reasons[account.id] = reason
            }
        }

        // Grouping (always, in every mode): usable regular accounts, then
        // usable backups, then paused regular accounts, then paused backups.
        // Paused groups sink below usable ones so limits take effect first.
        func groupKey(_ account: CodexAccount) -> Int {
            switch (account.isBackup == true, blocked.contains(account.id)) {
            case (false, false): return 0
            case (true, false): return 1
            case (false, true): return 2
            case (true, true): return 3
            }
        }

        func quotaScore(_ account: CodexAccount) -> Double {
            let hourly = account.quota?.hourlyRemainingPercent ?? 100
            let weekly = account.quota?.weeklyRemainingPercent ?? 100
            return min(hourly, weekly)
        }

        func expiryDate(_ account: CodexAccount) -> Date? {
            guard let raw = account.subscriptionActiveUntil, !raw.isEmpty else { return nil }
            return ISO8601DateFormatter().date(from: raw)
        }

        let sorted = accounts.sorted { lhs, rhs in
            let leftGroup = groupKey(lhs)
            let rightGroup = groupKey(rhs)
            if leftGroup != rightGroup { return leftGroup < rightGroup }

            if strategy != .custom {
                let leftPreferred = lhs.preferredFirst == true ? 0 : 1
                let rightPreferred = rhs.preferredFirst == true ? 0 : 1
                if leftPreferred != rightPreferred { return leftPreferred < rightPreferred }
            }

            switch strategy {
            case .custom:
                let left = manualIndex[lhs.id] ?? Int.max
                let right = manualIndex[rhs.id] ?? Int.max
                if left != right { return left < right }
            case .auto, .quotaHighFirst:
                let left = quotaScore(lhs)
                let right = quotaScore(rhs)
                if left != right { return left > right }
            case .quotaLowFirst:
                let left = quotaScore(lhs)
                let right = quotaScore(rhs)
                if left != right { return left < right }
            case .planHighFirst:
                let left = planRank(lhs.planType)
                let right = planRank(rhs.planType)
                if left != right { return left > right }
            case .planLowFirst:
                let left = planRank(lhs.planType)
                let right = planRank(rhs.planType)
                if left != right { return left < right }
            case .expirySoonFirst:
                let left = expiryDate(lhs) ?? Date.distantFuture
                let right = expiryDate(rhs) ?? Date.distantFuture
                if left != right { return left < right }
            }

            let left = manualIndex[lhs.id] ?? Int.max
            let right = manualIndex[rhs.id] ?? Int.max
            if left != right { return left < right }
            return lhs.id < rhs.id
        }

        return Resolution(orderedIds: sorted.map(\.id), blocked: blocked, blockReasons: reasons)
    }

    /// Gateway priorities: the first account gets the highest number (that is
    /// what “fill-first” uses first), the last gets 1.
    static func priorities(from orderedIds: [String]) -> [String: Int] {
        var values: [String: Int] = [:]
        let count = orderedIds.count
        for (index, id) in orderedIds.enumerated() {
            values[id] = count - index
        }
        return values
    }

    /// Rough subscription tiers for plan-based modes.
    static func planRank(_ planType: String?) -> Int {
        switch (planType ?? "").lowercased() {
        case "free": return 0
        case "": return 1
        case "plus": return 1
        case "pro": return 2
        case "team": return 3
        case "business", "self_serve_business_usage_based": return 4
        case "enterprise": return 5
        default: return 1
        }
    }
}
