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

    // MARK: - Reset notifications

    private func window(
        _ remaining: Double?,
        reset: Date? = nil,
        reserve: Int? = nil
    ) -> QuotaWindowState {
        QuotaWindowState(remaining: remaining, reset: reset, reservePercent: reserve)
    }

    private func resetDecisions(
        accountId: String = "account-a",
        hourlyBefore: QuotaWindowState = QuotaWindowState(remaining: 50),
        hourlyAfter: QuotaWindowState = QuotaWindowState(remaining: 50),
        weeklyBefore: QuotaWindowState = QuotaWindowState(remaining: 50),
        weeklyAfter: QuotaWindowState = QuotaWindowState(remaining: 50),
        records: [String: QuotaNotificationRecord] = [:]
    ) -> [QuotaResetNotificationPolicy.Decision] {
        QuotaResetNotificationPolicy.decisions(
            accountId: accountId,
            hourlyBefore: hourlyBefore,
            hourlyAfter: hourlyAfter,
            weeklyBefore: weeklyBefore,
            weeklyAfter: weeklyAfter,
            records: records,
            now: now
        )
    }

    func testQuotaResetNotifiesWhenBlockedAccountBecomesUsable() throws {
        let decisions = resetDecisions(
            hourlyBefore: window(0),
            hourlyAfter: window(80, reset: reset),
            weeklyBefore: window(50),
            weeklyAfter: window(60)
        )

        let decision = try XCTUnwrap(decisions.first)
        XCTAssertEqual(decisions.count, 1)
        XCTAssertEqual(decision.window, .hourly)
        XCTAssertEqual(decision.stateKey, "account-a:reset:hourly")
        XCTAssertEqual(decision.windowKey, QuotaNotificationPolicy.windowKey(for: reset))
        XCTAssertEqual(decision.remaining, 80)
    }

    func testQuotaResetIsSilentWhileAnotherWindowStillBlocks() {
        let decisions = resetDecisions(
            hourlyBefore: window(0),
            hourlyAfter: window(80, reset: reset),
            weeklyBefore: window(0),
            weeklyAfter: window(0)
        )
        XCTAssertTrue(decisions.isEmpty, "the account is still not usable")
    }

    func testQuotaResetIgnoresAccountsThatWereNotBlocked() {
        XCTAssertTrue(resetDecisions(
            hourlyBefore: window(50),
            hourlyAfter: window(80, reset: reset),
            weeklyBefore: window(50),
            weeklyAfter: window(60)
        ).isEmpty)
    }

    func testQuotaResetCoversBothRecoveredWindows() {
        let decisions = resetDecisions(
            hourlyBefore: window(0),
            hourlyAfter: window(80, reset: reset),
            weeklyBefore: window(0),
            weeklyAfter: window(60, reset: reset.addingTimeInterval(3600))
        )
        XCTAssertEqual(decisions.count, 2)
        XCTAssertEqual(
            Set(decisions.map(\.stateKey)),
            ["account-a:reset:hourly", "account-a:reset:weekly"]
        )
    }

    func testQuotaResetFiresOncePerResetWindow() throws {
        let first = try XCTUnwrap(resetDecisions(
            hourlyBefore: window(0),
            hourlyAfter: window(80, reset: reset)
        ).first)
        let records = [
            first.stateKey: QuotaNotificationRecord(
                notifiedAt: now,
                windowKey: first.windowKey
            ),
        ]

        XCTAssertTrue(resetDecisions(
            hourlyBefore: window(0),
            hourlyAfter: window(80, reset: reset),
            records: records
        ).isEmpty)

        let next = resetDecisions(
            hourlyBefore: window(0),
            hourlyAfter: window(80, reset: reset.addingTimeInterval(3600)),
            records: records
        )
        XCTAssertEqual(next.count, 1, "a new reset window re-arms the notice")
    }

    func testQuotaResetRecognisesReserveRecovery() {
        let decisions = resetDecisions(
            hourlyBefore: window(50),
            hourlyAfter: window(50),
            weeklyBefore: window(4, reset: reset, reserve: 5),
            weeklyAfter: window(10, reset: reset, reserve: 5)
        )
        XCTAssertEqual(decisions.map(\.window), [.weekly])
    }
}
