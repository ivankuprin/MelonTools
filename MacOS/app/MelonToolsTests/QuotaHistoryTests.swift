import XCTest
@testable import MelonTools

/// Pure rules of the local quota history: append order, the 288-sample cap,
/// per-key isolation, pruning, and JSON round-trip.
final class QuotaHistoryTests: XCTestCase {
    func testAppendKeepsChronologicalOrder() {
        var samples: [QuotaHistorySample] = []
        let first = QuotaHistorySample(at: Date(timeIntervalSince1970: 10), weekly: 90)
        let second = QuotaHistorySample(at: Date(timeIntervalSince1970: 20), weekly: 80)

        samples = QuotaHistory.appending(first, to: samples)
        samples = QuotaHistory.appending(second, to: samples)

        XCTAssertEqual(samples.map(\.at), [first.at, second.at])
        XCTAssertEqual(samples.map(\.weekly), [90, 80])
    }

    func testAppendCapsAt288SamplesAndDropsTheOldest() {
        XCTAssertEqual(QuotaHistory.maxSamples, 288)
        var samples: [QuotaHistorySample] = []
        for index in 0..<290 {
            samples = QuotaHistory.appending(
                QuotaHistorySample(
                    at: Date(timeIntervalSince1970: TimeInterval(index)),
                    hourly: Double(index)
                ),
                to: samples
            )
        }

        XCTAssertEqual(samples.count, 288)
        XCTAssertEqual(samples.first?.at, Date(timeIntervalSince1970: 2))
        XCTAssertEqual(samples.last?.at, Date(timeIntervalSince1970: 289))
    }

    func testZeroCapDropsEverything() {
        let sample = QuotaHistorySample(at: Date(timeIntervalSince1970: 1))
        XCTAssertTrue(QuotaHistory.appending(sample, to: [sample], cap: 0).isEmpty)
    }

    func testKeysAreIndependent() {
        var history: [String: [QuotaHistorySample]] = [:]
        for index in 0..<3 {
            history = QuotaHistory.appending(
                QuotaHistorySample(at: Date(timeIntervalSince1970: TimeInterval(index)), hourly: 50),
                for: "account-a",
                to: history
            )
        }
        history = QuotaHistory.appending(
            QuotaHistorySample(at: Date(timeIntervalSince1970: 99), balance: 12),
            for: "openrouter",
            to: history
        )

        XCTAssertEqual(history["account-a"]?.count, 3)
        XCTAssertEqual(history["openrouter"]?.count, 1)
        XCTAssertEqual(history["claude"], nil)
    }

    func testPruneCapsEverySeriesAndKeepsTheNewest() {
        let samples = (0..<5).map {
            QuotaHistorySample(at: Date(timeIntervalSince1970: TimeInterval($0)))
        }
        let pruned = QuotaHistory.pruned(
            ["account-a": samples, "claude": Array(samples.prefix(2))],
            cap: 3
        )

        XCTAssertEqual(pruned["account-a"]?.count, 3)
        XCTAssertEqual(pruned["account-a"]?.first?.at, Date(timeIntervalSince1970: 2))
        XCTAssertEqual(pruned["account-a"]?.last?.at, Date(timeIntervalSince1970: 4))
        XCTAssertEqual(pruned["claude"]?.count, 2)
        XCTAssertEqual(QuotaHistory.pruned(["account-a": samples], cap: 0)["account-a"], [])
    }

    func testSerializationRoundTripsOptionalFields() throws {
        let history: [String: [QuotaHistorySample]] = [
            "account-a": [
                QuotaHistorySample(
                    at: Date(timeIntervalSince1970: 1_000_000),
                    hourly: 42.5,
                    weekly: nil
                ),
            ],
            "claude": [
                QuotaHistorySample(
                    at: Date(timeIntervalSince1970: 1_000_060),
                    hourly: nil,
                    weekly: 7
                ),
            ],
            "openrouter": [
                QuotaHistorySample(
                    at: Date(timeIntervalSince1970: 1_000_120),
                    balance: 12.25
                ),
            ],
        ]

        let data = try QuotaHistory.encode(history)
        let decoded = try QuotaHistory.decode(data)

        XCTAssertEqual(decoded, history)
    }

    func testSerializationIsAKeyedJSONDictionary() throws {
        let history: [String: [QuotaHistorySample]] = [
            "account-a": [
                QuotaHistorySample(
                    at: Date(timeIntervalSince1970: 1_000_000),
                    hourly: 42.5,
                    weekly: 12
                ),
            ],
        ]

        let data = try QuotaHistory.encode(history)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["account-a"])
        let series = try XCTUnwrap(object["account-a"] as? [[String: Any]])
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series.first?["hourly"] as? Double, 42.5)
        XCTAssertEqual(series.first?["weekly"] as? Double, 12)
    }

    func testDecodeRejectsMalformedPayloads() {
        XCTAssertThrowsError(try QuotaHistory.decode(Data("not json".utf8)))
        XCTAssertThrowsError(try QuotaHistory.decode(Data(#"{"account-a":"nope"}"#.utf8)))
    }

    @MainActor
    func testStoreWrites0600AndReloads() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("melon-quota-history-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent(QuotaHistoryStore.fileName)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = QuotaHistoryStore(fileURL: url)
        store.record(
            QuotaHistorySample(at: Date(timeIntervalSince1970: 100), weekly: 25),
            for: "account-a"
        )
        store.record(
            QuotaHistorySample(at: Date(timeIntervalSince1970: 200), weekly: 20),
            for: "account-a"
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let reloaded = QuotaHistoryStore(fileURL: url)
        XCTAssertEqual(reloaded.samples(for: "account-a").map(\.weekly), [25, 20])

        // SecureFile renames its sibling temp file, so nothing is left behind.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(siblings, [QuotaHistoryStore.fileName])
    }
}

/// Pure dashboard aggregation: pool counters, trend buckets and provider
/// ranking. No store or clock dependency.
final class DashboardAggregationTests: XCTestCase {
    private func account(
        id: String,
        hourly: Double?,
        weekly: Double?,
        reserve: Int? = nil,
        error: String? = nil,
        updated: Date = Date()
    ) -> CodexAccount {
        var quota = CodexQuota()
        quota.hourlyRemainingPercent = hourly
        quota.weeklyRemainingPercent = weekly

        var account = CodexAccount(tokens: CodexTokens())
        account.id = id
        account.quota = quota
        account.quotaUpdatedAt = updated
        account.quotaError = error
        account.weeklyReservePercent = reserve
        return account
    }

    func testPoolHealthCountsUsablePausedAndErrors() {
        let accounts = [
            account(id: "a", hourly: 80, weekly: 60),
            account(id: "b", hourly: 40, weekly: 20),
            account(id: "c", hourly: 50, weekly: 3, reserve: 5),
            account(id: "d", hourly: nil, weekly: nil, error: "boom"),
        ]

        let health = DashboardMetrics.poolHealth(accounts: accounts)
        XCTAssertEqual(health.total, 4)
        XCTAssertEqual(health.usable, 3)
        XCTAssertEqual(health.paused, 1)
        XCTAssertEqual(health.errors, 1)
        XCTAssertEqual(health.hourlyAverage ?? 0, (80 + 40 + 50) / 3, accuracy: 0.001)
        XCTAssertEqual(health.weeklyAverage ?? 0, (60 + 20 + 3) / 3, accuracy: 0.001)
        XCTAssertNil(DashboardMetrics.average([]))
    }

    func testPoolHealthIgnoresStaleQuotaWhenCountingPaused() {
        let stale = account(
            id: "stale",
            hourly: 0,
            weekly: 0,
            updated: Date().addingTimeInterval(-2 * CodexRoutingPlanner.quotaFreshness)
        )
        let health = DashboardMetrics.poolHealth(accounts: [stale])
        XCTAssertEqual(health.paused, 0)
        XCTAssertEqual(health.usable, 1)
    }

    func testTrendBucketsHourlyAcrossAllKeys() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let start = now.addingTimeInterval(-24 * 3600)
        let history: [String: [QuotaHistorySample]] = [
            "account-a": [
                QuotaHistorySample(at: start.addingTimeInterval(600), hourly: 20),
                QuotaHistorySample(at: start.addingTimeInterval(23 * 3600 + 600), hourly: 60),
                QuotaHistorySample(at: start.addingTimeInterval(-60), hourly: 99),
            ],
            "claude": [
                QuotaHistorySample(at: start.addingTimeInterval(1_200), hourly: 40),
                QuotaHistorySample(at: start.addingTimeInterval(23 * 3600 + 1_200), hourly: 80),
            ],
        ]

        let points = DashboardTrend.points(
            history: history,
            field: .hourly,
            now: now,
            window: 24 * 3600,
            bucket: 3600
        )

        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].start, start)
        XCTAssertEqual(points[0].value, 30, accuracy: 0.001)
        XCTAssertEqual(points[1].start, start.addingTimeInterval(23 * 3600))
        XCTAssertEqual(points[1].value, 70, accuracy: 0.001)
    }

    func testTrendBucketsWeeklyByDayAndIgnoresMissingValues() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let start = now.addingTimeInterval(-7 * 24 * 3600)
        let history: [String: [QuotaHistorySample]] = [
            "account-a": [
                QuotaHistorySample(at: start.addingTimeInterval(3600), weekly: 30),
                QuotaHistorySample(at: start.addingTimeInterval(24 * 3600 + 7_200), weekly: 50),
            ],
            "openrouter": [
                QuotaHistorySample(at: start.addingTimeInterval(6 * 24 * 3600 + 10_800), weekly: 70),
                QuotaHistorySample(at: start.addingTimeInterval(2 * 3600), hourly: 10),
            ],
        ]

        let points = DashboardTrend.points(
            history: history,
            field: .weekly,
            now: now,
            window: 7 * 24 * 3600,
            bucket: 24 * 3600
        )

        XCTAssertEqual(points.map(\.value), [30, 50, 70])
        XCTAssertEqual(
            points.map(\.start),
            [
                start,
                start.addingTimeInterval(24 * 3600),
                start.addingTimeInterval(6 * 24 * 3600),
            ]
        )
    }

    func testTopProvidersRankByTokensAndKeepUnpricedRows() {
        var spend = SessionSpend()
        spend.providers = [
            "openrouter": SessionSpend.ProviderStats(usd: 2.5, turns: 3, tokens: 1_000),
            "opencode": SessionSpend.ProviderStats(usd: nil, turns: 5, tokens: 5_000),
            "Claude": SessionSpend.ProviderStats(usd: 1, turns: 2, tokens: 100),
            "Antigravity": SessionSpend.ProviderStats(usd: 9, turns: 1, tokens: 50),
        ]

        let top = spend.topProviders()
        XCTAssertEqual(top.map(\.provider), ["opencode", "openrouter", "Claude"])
        XCTAssertNil(top[0].stats.usd)
        XCTAssertEqual(top[1].stats.usd, 2.5)
        XCTAssertEqual(spend.topProviders(limit: 2).map(\.provider), ["opencode", "openrouter"])
        XCTAssertTrue(spend.topProviders(limit: 0).isEmpty)
    }
}
