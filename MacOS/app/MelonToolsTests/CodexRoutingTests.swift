import XCTest
@testable import MelonTools

/// Routing is the highest-risk pure logic in the app: a mistake here either
/// parks a healthy account or routes to an exhausted one.
final class CodexRoutingTests: XCTestCase {

    private func account(
        id: String = UUID().uuidString,
        email: String = "a@example.com",
        hourly: Double? = 100,
        weekly: Double? = 100,
        quotaAge: TimeInterval = 0,
        hourlyReserve: Int? = nil,
        weeklyReserve: Int? = nil,
        preferred: Bool? = nil,
        backup: Bool? = nil,
        plan: String? = "plus"
    ) -> CodexAccount {
        var quota = CodexQuota()
        quota.hourlyRemainingPercent = hourly
        quota.weeklyRemainingPercent = weekly
        var account = CodexAccount(tokens: CodexTokens())
        account.id = id
        account.email = email
        account.planType = plan
        account.quota = quota
        account.quotaUpdatedAt = Date().addingTimeInterval(-quotaAge)
        account.hourlyReservePercent = hourlyReserve
        account.weeklyReservePercent = weeklyReserve
        account.preferredFirst = preferred
        account.isBackup = backup
        return account
    }

    func testExhaustedWeeklyWindowBlocks() {
        let account = account(hourly: 80, weekly: 0)
        XCTAssertNotNil(CodexRoutingPlanner.blockReason(account))
    }

    func testExhaustedHourlyWindowBlocks() {
        let account = account(hourly: 0, weekly: 50)
        XCTAssertNotNil(CodexRoutingPlanner.blockReason(account))
    }

    func testReserveThresholdBlocksAtOrBelowLimit() {
        XCTAssertNotNil(CodexRoutingPlanner.blockReason(account(hourly: 10, weekly: 80, hourlyReserve: 10)))
        XCTAssertNil(CodexRoutingPlanner.blockReason(account(hourly: 11, weekly: 80, hourlyReserve: 10)))
    }

    func testStaleQuotaNeverBlocks() {
        // Older than the freshness window: a stale gauge must not park an account.
        let account = account(hourly: 0, weekly: 0, quotaAge: CodexRoutingPlanner.quotaFreshness + 60)
        XCTAssertNil(CodexRoutingPlanner.blockReason(account))
    }

    func testBlockedAccountsSinkBelowUsableOnes() {
        let healthy = account(email: "healthy@example.com", hourly: 50, weekly: 50)
        let exhausted = account(email: "exhausted@example.com", hourly: 0, weekly: 0)
        let resolution = CodexRoutingPlanner.resolve(accounts: [exhausted, healthy], strategy: .auto, manualOrder: [])
        XCTAssertEqual(resolution.orderedIds.first, healthy.id)
        XCTAssertTrue(resolution.blocked.contains(exhausted.id))
    }

    func testPreferredAccountLeadsAutoMode() {
        let preferred = account(hourly: 40, weekly: 40, preferred: true)
        let richer = account(hourly: 95, weekly: 95)
        let resolution = CodexRoutingPlanner.resolve(accounts: [richer, preferred], strategy: .auto, manualOrder: [])
        XCTAssertEqual(resolution.orderedIds.first, preferred.id)
    }

    func testBackupsGoLast() {
        let regular = account(hourly: 10, weekly: 10)
        let backup = account(hourly: 99, weekly: 99, backup: true)
        let resolution = CodexRoutingPlanner.resolve(accounts: [backup, regular], strategy: .quotaHighFirst, manualOrder: [])
        XCTAssertEqual(resolution.orderedIds.last, backup.id)
    }

    func testPrioritiesGiveFirstAccountHighestValue() {
        let first = account()
        let second = account()
        let values = CodexRoutingPlanner.priorities(from: [first.id, second.id])
        XCTAssertEqual(values[first.id], 2)
        XCTAssertEqual(values[second.id], 1)
    }

    func testManualOrderIsRespected() {
        let a = account(email: "a@example.com")
        let b = account(email: "b@example.com")
        let resolution = CodexRoutingPlanner.resolve(accounts: [a, b], strategy: .custom, manualOrder: [b.id, a.id])
        XCTAssertEqual(resolution.orderedIds, [b.id, a.id])
    }
}

/// Token accounting and cost math feed the session estimate; a sign error or
/// a bad cache split produces visibly wrong money.
final class SessionUsageTests: XCTestCase {

    func testCacheHitPercentUsesInputAsDenominator() {
        var usage = SessionTokenUsage()
        usage.input = 100
        usage.cached = 25
        XCTAssertEqual(usage.cacheHitPercent, 25)
        usage.input = 0
        XCTAssertNil(usage.cacheHitPercent)
    }

    func testSpendStatsAggregatePerProvider() {
        var stats = SessionSpend.ProviderStats()
        stats.turns = 3
        stats.input = 1_000
        stats.cached = 400
        stats.output = 100
        stats.tokens = 1_100
        XCTAssertEqual(stats.cacheHitPercent, 40)
        XCTAssertEqual(stats.turns, 3)
    }
}

/// The CDP endpoint has no auth; the port must come from the kernel, not from
/// a hardcoded constant.
@MainActor
final class ComposerBridgeTests: XCTestCase {
    func testFreeDebugPortIsUsable() {
        guard let port = ComposerBridge.freeDebugPort() else {
            return XCTFail("freeDebugPort returned nil")
        }
        XCTAssertGreaterThan(port, 1024)
        XCTAssertLessThan(port, 65536)
    }

    func testJavaScriptEscapingKeepsTheLiteralOnOneLine() {
        let json = "{\"model\":\"a\u{2028}b\u{2029}c\"}"
        XCTAssertTrue(json.contains("\u{2028}"))
        XCTAssertTrue(json.contains("\u{2029}"))

        let escaped = ComposerBridge.escapedForJavaScript(json)

        XCTAssertFalse(escaped.contains("\u{2028}"))
        XCTAssertFalse(escaped.contains("\u{2029}"))
        XCTAssertTrue(escaped.contains("\\u2028"))
        XCTAssertTrue(escaped.contains("\\u2029"))
        XCTAssertEqual(escaped.components(separatedBy: "\n").count, 1)
    }

    func testJavaScriptEscapingLeavesOrdinaryJSONAlone() {
        let json = #"{"model":"gpt-5.1-codex","threadId":"0199"}"#
        XCTAssertEqual(ComposerBridge.escapedForJavaScript(json), json)
    }
}

/// The rollout parse cache must stay bounded without throwing away the whole
/// parse history every time it fills up.
final class LRUCacheTests: XCTestCase {
    func testInsertEvictsOnlyTheOldestEntries() {
        var cache = LRUCache<String, Int>(limit: 3)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        cache.insert(3, for: "c")
        cache.insert(4, for: "d")

        XCTAssertEqual(cache.count, 3)
        XCTAssertNil(cache.value(for: "a"), "the oldest entry is the only one dropped")
        XCTAssertEqual(cache.value(for: "b"), 2)
        XCTAssertEqual(cache.value(for: "c"), 3)
        XCTAssertEqual(cache.value(for: "d"), 4)
        XCTAssertEqual(cache.keys, ["b", "c", "d"])
    }

    func testReadRefreshesRecency() {
        var cache = LRUCache<String, Int>(limit: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")

        XCTAssertEqual(cache.value(for: "a"), 1, "a read makes 'a' the newest entry")
        cache.insert(3, for: "c")

        XCTAssertEqual(cache.keys, ["a", "c"])
        XCTAssertNil(cache.value(for: "b"))
    }

    func testReinsertingAKeyMovesItWithoutGrowing() {
        var cache = LRUCache<String, Int>(limit: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        cache.insert(3, for: "a")

        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.keys, ["b", "a"])
        XCTAssertEqual(cache.value(for: "a"), 3)
    }

    func testEvictionKeepsTheMostRecentKeysWithinTheLimit() {
        var cache = LRUCache<Int, Int>(limit: 12)
        for index in 0..<40 {
            cache.insert(index, for: index)
        }

        XCTAssertEqual(cache.count, 12)
        XCTAssertEqual(cache.keys, Array(28..<40))
    }
}
