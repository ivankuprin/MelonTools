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
