import XCTest
@testable import MelonTools

/// Pure low-quota policy: default and reserve thresholds, opt-in hourly
/// notifications, once-per-window dedupe, reset re-arm, and the legacy
/// debounce when the provider exposes no reset timestamp.
final class LowQuotaNotificationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 3_000_000)
    private let reset = Date(timeIntervalSince1970: 3_600_000)

    private func decisions(
        accountId: String = "account-a",
        hourly: Double? = 50,
        hourlyReset: Date? = nil,
        hourlyReserve: Int? = nil,
        weekly: Double? = 50,
        weeklyReset: Date? = nil,
        weeklyReserve: Int? = nil,
        records: [String: QuotaNotificationRecord] = [:]
    ) -> [QuotaNotificationPolicy.Decision] {
        QuotaNotificationPolicy.decisions(
            accountId: accountId,
            hourlyRemaining: hourly,
            hourlyReset: hourlyReset,
            hourlyReservePercent: hourlyReserve,
            weeklyRemaining: weekly,
            weeklyReset: weeklyReset,
            weeklyReservePercent: weeklyReserve,
            records: records,
            now: now
        )
    }

    func testWeeklyDefaultThresholdIsTenPercent() {
        let atThreshold = decisions(weekly: 10)
        XCTAssertEqual(atThreshold.map(\.window.rawValue), ["weekly"])
        XCTAssertEqual(atThreshold.first?.threshold, 10)
        XCTAssertEqual(atThreshold.first?.remaining, 10)

        XCTAssertTrue(decisions(weekly: 10.1).isEmpty)
        XCTAssertTrue(decisions(weekly: nil).isEmpty)
    }

    func testHealthyQuotaDoesNotNotify() {
        XCTAssertTrue(decisions(hourly: 100, weekly: 100).isEmpty)
        XCTAssertTrue(decisions(hourly: nil, weekly: nil).isEmpty)
    }

    func testHourlyWindowIsOptInThroughTheReserve() {
        // No reserve: the 5-hour window stays quiet even when nearly empty.
        XCTAssertTrue(decisions(hourly: 4, weekly: 50).isEmpty)

        let optedIn = decisions(hourly: 4, hourlyReserve: 5, weekly: 50)
        XCTAssertEqual(optedIn.map(\.window.rawValue), ["hourly"])
        XCTAssertEqual(optedIn.first?.threshold, 5)

        XCTAssertTrue(decisions(hourly: 6, hourlyReserve: 5, weekly: 50).isEmpty)
    }

    func testWeeklyReserveOverridesTheDefault() {
        let overridden = decisions(weekly: 12, weeklyReserve: 15)
        XCTAssertEqual(overridden.map(\.window.rawValue), ["weekly"])
        XCTAssertEqual(overridden.first?.threshold, 15)

        // A reserve below the default tightens it: 12% is no longer “low”.
        XCTAssertTrue(decisions(weekly: 12, weeklyReserve: 10).isEmpty)

        // At the threshold the notification fires.
        XCTAssertEqual(decisions(weekly: 10, weeklyReserve: 10).count, 1)
    }

    func testBothWindowsCanNotifyTogether() {
        let both = decisions(
            hourly: 3,
            hourlyReset: reset,
            hourlyReserve: 5,
            weekly: 4,
            weeklyReset: reset
        )
        XCTAssertEqual(both.map(\.window.rawValue), ["hourly", "weekly"])
        XCTAssertEqual(Set(both.map(\.stateKey)), ["account-a:hourly", "account-a:weekly"])
    }

    func testOneNotificationPerWindow() throws {
        let first = decisions(weekly: 5, weeklyReset: reset)
        let decision = try XCTUnwrap(first.first)
        XCTAssertEqual(decision.windowKey, QuotaNotificationPolicy.windowKey(for: reset))

        let records = [
            decision.stateKey: QuotaNotificationRecord(
                notifiedAt: now,
                windowKey: decision.windowKey
            ),
        ]
        XCTAssertTrue(decisions(weekly: 5, weeklyReset: reset, records: records).isEmpty)
    }

    func testNewResetRearmsTheWindow() throws {
        let first = try XCTUnwrap(decisions(weekly: 5, weeklyReset: reset).first)
        let records = [
            first.stateKey: QuotaNotificationRecord(
                notifiedAt: now,
                windowKey: first.windowKey
            ),
        ]
        let nextReset = reset.addingTimeInterval(3600)
        let next = decisions(weekly: 5, weeklyReset: nextReset, records: records)

        XCTAssertEqual(next.map(\.window.rawValue), ["weekly"])
        XCTAssertNotEqual(next.first?.windowKey, first.windowKey)
    }

    func testMissingResetUsesTheSixHourDebounce() throws {
        let first = try XCTUnwrap(decisions(weekly: 5, weeklyReset: nil).first)
        XCTAssertEqual(first.windowKey, "")

        let recent = [
            first.stateKey: QuotaNotificationRecord(
                notifiedAt: now.addingTimeInterval(-3600),
                windowKey: ""
            ),
        ]
        XCTAssertTrue(decisions(weekly: 5, weeklyReset: nil, records: recent).isEmpty)

        let stale = [
            first.stateKey: QuotaNotificationRecord(
                notifiedAt: now.addingTimeInterval(-7 * 3600),
                windowKey: ""
            ),
        ]
        XCTAssertEqual(decisions(weekly: 5, weeklyReset: nil, records: stale).count, 1)
    }

    func testAccountsKeepIndependentNotificationState() throws {
        let first = try XCTUnwrap(decisions(accountId: "account-a", weekly: 5, weeklyReset: reset).first)
        let records = [
            first.stateKey: QuotaNotificationRecord(
                notifiedAt: now,
                windowKey: first.windowKey
            ),
        ]

        XCTAssertTrue(decisions(
            accountId: "account-a",
            weekly: 5,
            weeklyReset: reset,
            records: records
        ).isEmpty)
        XCTAssertEqual(decisions(
            accountId: "account-b",
            weekly: 5,
            weeklyReset: reset,
            records: records
        ).count, 1)
    }

    func testWindowKeyUsesTheResetSecond() {
        XCTAssertEqual(
            QuotaNotificationPolicy.windowKey(for: Date(timeIntervalSince1970: 1_234.9)),
            "1234"
        )
        XCTAssertEqual(QuotaNotificationPolicy.windowKey(for: nil), "")
    }
}
