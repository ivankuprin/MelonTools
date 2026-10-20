import Foundation
import SwiftUI

// MARK: - Model

/// One point of the local quota history.
///
/// `hourly`/`weekly` are the remaining shares of the rolling windows, 0…100,
/// so a falling line means the quota is draining. `balance` keeps provider
/// values that are not percentages (OpenRouter credits / key balance).
struct QuotaHistorySample: Codable, Equatable {
    var at: Date
    var hourly: Double?
    var weekly: Double?
    var balance: Double?

    init(
        at: Date = Date(),
        hourly: Double? = nil,
        weekly: Double? = nil,
        balance: Double? = nil
    ) {
        self.at = at
        self.hourly = hourly
        self.weekly = weekly
        self.balance = balance
    }
}

/// Pure quota-history operations: appending enforces the per-key cap and
/// encode/decode are deterministic and round-trip safe. No file I/O here, so
/// every rule is testable without touching the user's Application Support.
enum QuotaHistory {
    /// 288 samples at the default 5-minute quota cadence cover 24 hours.
    static let maxSamples = 288

    static func appending(
        _ sample: QuotaHistorySample,
        to samples: [QuotaHistorySample],
        cap: Int = maxSamples
    ) -> [QuotaHistorySample] {
        let limit = max(0, cap)
        guard limit > 0 else { return [] }
        var updated = samples
        updated.append(sample)
        if updated.count > limit {
            updated.removeFirst(updated.count - limit)
        }
        return updated
    }

    static func appending(
        _ sample: QuotaHistorySample,
        for key: String,
        to history: [String: [QuotaHistorySample]],
        cap: Int = maxSamples
    ) -> [String: [QuotaHistorySample]] {
        var updated = history
        updated[key] = appending(sample, to: updated[key] ?? [], cap: cap)
        return updated
    }

    /// Drops samples beyond the cap, oldest first. Used on load so a file
    /// written by an older build can never grow without bound.
    static func pruned(
        _ history: [String: [QuotaHistorySample]],
        cap: Int = maxSamples
    ) -> [String: [QuotaHistorySample]] {
        let limit = max(0, cap)
        return history.mapValues { samples in
            guard limit > 0 else { return [] }
            return Array(samples.suffix(limit))
        }
    }

    static func encode(_ history: [String: [QuotaHistorySample]]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(history)
    }

    static func decode(_ data: Data) throws -> [String: [QuotaHistorySample]] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([String: [QuotaHistorySample]].self, from: data)
    }
}

// MARK: - Store

/// Loads, appends and atomically persists the quota history. History is
/// best-effort: a failed write never fails a quota refresh.
@MainActor
final class QuotaHistoryStore: ObservableObject {
    static let shared = QuotaHistoryStore()
    static let fileName = "quota-history.json"

    nonisolated static var defaultFileURL: URL {
        CodexStore.supportDir.appendingPathComponent(fileName)
    }

    @Published private(set) var history: [String: [QuotaHistorySample]] = [:]

    private let fileURL: URL
    private var loaded = false

    init(fileURL: URL = QuotaHistoryStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    func samples(for key: String) -> [QuotaHistorySample] {
        loadIfNeeded()
        return history[key] ?? []
    }

    func record(_ sample: QuotaHistorySample, for key: String) {
        guard !key.isEmpty else { return }
        loadIfNeeded()
        history = QuotaHistory.appending(sample, for: key, to: history)
        persist()
    }

    func clear() {
        history = [:]
        persist()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = SecureFile.read(fileURL),
              let decoded = try? QuotaHistory.decode(data) else { return }
        history = QuotaHistory.pruned(decoded)
    }

    private func persist() {
        guard let data = try? QuotaHistory.encode(history) else { return }
        try? SecureFile.write(data, to: fileURL)
    }
}

// MARK: - Sparkline

/// Mini line for one history series. A `Shape` has no layout pass of its own,
/// so it stays cheap inside the scrolling account/provider cards.
struct QuotaSparklineShape: Shape {
    var values: [Double]
    /// Fixed value domain for percentages; nil scales to the series range.
    var fixedRange: ClosedRange<Double>? = 0...100

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !values.isEmpty, rect.width > 0, rect.height > 0 else { return path }
        let domain = resolvedDomain
        let span = domain.upperBound - domain.lowerBound

        func y(_ value: Double) -> CGFloat {
            guard span > 0 else { return rect.midY }
            let fraction = min(1, max(0, (value - domain.lowerBound) / span))
            return rect.maxY - rect.height * CGFloat(fraction)
        }

        if values.count == 1 {
            let point = CGPoint(x: rect.midX, y: y(values[0]))
            path.move(to: point)
            path.addLine(to: point)
            return path
        }

        for (index, value) in values.enumerated() {
            let x = rect.minX + rect.width * CGFloat(index) / CGFloat(values.count - 1)
            let point = CGPoint(x: x, y: y(value))
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }

    private var resolvedDomain: ClosedRange<Double> {
        if let fixedRange { return fixedRange }
        let minimum = values.min() ?? 0
        let maximum = values.max() ?? 1
        guard maximum - minimum > 0.0001 else {
            return (minimum - 0.5)...(maximum + 0.5)
        }
        return minimum...maximum
    }
}

/// One compact line, hidden until there are at least two samples.
struct QuotaSparkline: View {
    enum Field {
        case hourly
        case weekly
        case balance
    }

    let samples: [QuotaHistorySample]
    let field: Field
    var tint: Color = MTTheme.gold
    var width: CGFloat = 64
    var height: CGFloat = 14

    private var values: [Double] {
        samples.compactMap { sample in
            switch field {
            case .hourly: return sample.hourly
            case .weekly: return sample.weekly
            case .balance: return sample.balance
            }
        }
    }

    private var fixedRange: ClosedRange<Double>? {
        switch field {
        case .hourly, .weekly: return 0...100
        case .balance: return nil
        }
    }

    @ViewBuilder
    var body: some View {
        if values.count >= 2 {
            QuotaSparklineShape(values: values, fixedRange: fixedRange)
                .stroke(tint, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                .frame(width: width, height: height)
                .background(MTTheme.borderColor.opacity(0.35), in: RoundedRectangle(cornerRadius: 3))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .accessibilityHidden(true)
        }
    }
}

/// Labelled hourly/weekly pair for an account or provider card. Renders
/// nothing when the key has fewer than two points in either series.
struct QuotaHistorySparklineStrip: View {
    let samples: [QuotaHistorySample]
    let hourlyTitle: String
    let weeklyTitle: String
    var hourlyTint: Color = MTTheme.gold
    var weeklyTint: Color = MTTheme.info

    var body: some View {
        let hourlyCount = samples.compactMap(\.hourly).count
        let weeklyCount = samples.compactMap(\.weekly).count
        if hourlyCount >= 2 || weeklyCount >= 2 {
            HStack(spacing: MTTheme.s3) {
                if hourlyCount >= 2 {
                    cell(title: hourlyTitle, field: .hourly, tint: hourlyTint)
                }
                if weeklyCount >= 2 {
                    cell(title: weeklyTitle, field: .weekly, tint: weeklyTint)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func cell(title: String, field: QuotaSparkline.Field, tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(title.uppercased())
                .font(MTTheme.mono(8, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(MTTheme.textTertiary)
            QuotaSparkline(samples: samples, field: field, tint: tint)
        }
    }
}
