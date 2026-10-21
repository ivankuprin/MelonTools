import Foundation
import SwiftUI

// MARK: - Pure dashboard helpers

/// `@AppStorage` keys shared by the dashboard and the settings toggles.
enum DashboardWidgetKey {
    static let poolHealth = "dashboard.showPoolHealth"
    static let quotaTrends = "dashboard.showQuotaTrends"
    static let spend = "dashboard.showSpend"
    static let scheduler = "dashboard.showScheduler"
}

/// Pool counters and averages. Paused is the routing planner's decision, so
/// stale quota readings never park an account in the overview.
struct DashboardPoolHealth: Equatable {
    var total = 0
    var usable = 0
    var paused = 0
    var errors = 0
    var hourlyAverage: Double?
    var weeklyAverage: Double?

    static func make(accounts: [CodexAccount]) -> DashboardPoolHealth {
        var health = DashboardPoolHealth()
        health.total = accounts.count
        health.usable = accounts.filter { CodexRoutingPlanner.blockReason($0) == nil }.count
        health.paused = health.total - health.usable
        health.errors = accounts.filter { $0.quotaError != nil }.count
        health.hourlyAverage = DashboardMetrics.average(
            accounts.compactMap(\.quota?.hourlyRemainingPercent)
        )
        health.weeklyAverage = DashboardMetrics.average(
            accounts.compactMap(\.quota?.weeklyRemainingPercent)
        )
        return health
    }
}

enum DashboardMetrics {
    static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    static func poolHealth(accounts: [CodexAccount]) -> DashboardPoolHealth {
        DashboardPoolHealth.make(accounts: accounts)
    }

    static func dueCount(tasks: [SchedulerTask], now: Date = Date()) -> Int {
        SchedulerPolicy.due(tasks, now: now).count
    }

    /// Earliest armed schedule; a past timestamp still counts (the task is due
    /// and the next tick will run it).
    static func nextRun(tasks: [SchedulerTask]) -> Date? {
        tasks.compactMap { task -> Date? in
            guard task.enabled, let stamp = task.nextRunAt else { return nil }
            return Date(timeIntervalSince1970: stamp)
        }.min()
    }

    /// Newest history entry wins; otherwise the most recently run task.
    static func lastStatus(
        tasks: [SchedulerTask],
        history: [SchedulerHistoryEntry]
    ) -> SchedulerTaskStatus? {
        if let newest = history.first { return newest.status }
        let ran = tasks.compactMap { task -> SchedulerTask? in
            task.lastRunAt == nil ? nil : task
        }
        return ran.max { ($0.lastRunAt ?? 0) < ($1.lastRunAt ?? 0) }?.lastStatus
    }
}

/// Aggregate quota history across all account/provider keys.
enum DashboardTrend {
    enum Field {
        case hourly
        case weekly
    }

    struct Point: Equatable {
        let start: Date
        let value: Double
    }

    /// Averages every sample that falls inside `window`, grouped by `bucket`.
    /// Buckets without samples are omitted rather than fabricated as zero.
    static func points(
        history: [String: [QuotaHistorySample]],
        field: Field,
        now: Date,
        window: TimeInterval,
        bucket: TimeInterval
    ) -> [Point] {
        guard window > 0, bucket > 0 else { return [] }
        let start = now.addingTimeInterval(-window)
        var groups: [Int: (sum: Double, count: Int)] = [:]

        for samples in history.values {
            for sample in samples {
                guard sample.at >= start, sample.at <= now else { continue }
                let value: Double?
                switch field {
                case .hourly: value = sample.hourly
                case .weekly: value = sample.weekly
                }
                guard let value else { continue }
                let offset = sample.at.timeIntervalSince(start)
                let index = Int(floor(offset / bucket))
                guard index >= 0 else { continue }
                let current = groups[index] ?? (0, 0)
                groups[index] = (current.sum + value, current.count + 1)
            }
        }

        return groups.keys.sorted().map { index in
            let group = groups[index] ?? (0, 1)
            return Point(
                start: start.addingTimeInterval(Double(index) * bucket),
                value: group.sum / Double(group.count)
            )
        }
    }
}

// MARK: - Dashboard

/// Overview: the scheduler, the Codex account pool and the gateway at a glance.
struct DashboardView: View {
    @EnvironmentObject private var app: AppState
    @Binding var selection: MTSection

    @ObservedObject private var codex = CodexStore.shared
    @ObservedObject private var gateway = CodexGatewayService.shared
    @ObservedObject private var quotaHistory = QuotaHistoryStore.shared
    @ObservedObject private var usage = ProviderUsageStore.shared
    @ObservedObject private var scheduler = SchedulerStore.shared

    @AppStorage(DashboardWidgetKey.poolHealth) private var showPoolHealth = true
    @AppStorage(DashboardWidgetKey.quotaTrends) private var showQuotaTrends = true
    @AppStorage(DashboardWidgetKey.spend) private var showSpend = true
    @AppStorage(DashboardWidgetKey.scheduler) private var showScheduler = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MTTheme.s5) {
                MTPageHeader(
                    kicker: "melon tools",
                    title: L("Dashboard"),
                    subtitle: L("Dashboard subtitle")
                )

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 340), spacing: MTTheme.s3)],
                    spacing: MTTheme.s3
                ) {
                    if showPoolHealth { dashboardTile { poolHealthCard } }
                    if showScheduler { dashboardTile { schedulerCard } }
                    if showQuotaTrends { dashboardTile { quotaTrendsCard } }
                    if showSpend { dashboardTile { spendCard } }
                    dashboardTile { codexCard }
                    dashboardTile { gatewayCard }
                }
            }
            .padding(MTTheme.s5)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        .mtScrollMemory("scroll.dashboard")
        }
        .background(MTTheme.background)
        .onAppear {
            codex.load()
            scheduler.start()
            // The store loads its file lazily; this call primes it before the
            // trend helpers read `history`.
            _ = quotaHistory.samples(for: "")
            Task { await gateway.healthCheck() }
            Task { await usage.refreshSession(threadUUID: ComposerBridge.shared.activeThreadID) }
        }
    }

    /// Every dashboard card has the same height, regardless of how much
    /// content it carries. The grid then reads as one aligned surface instead
    /// of a staircase of differently sized tiles.
    private func dashboardTile<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, minHeight: 250, maxHeight: 250, alignment: .top)
    }

    // MARK: - Pool health

    private var poolHealth: DashboardPoolHealth {
        DashboardMetrics.poolHealth(accounts: codex.accounts)
    }

    private var poolHealthCard: some View {
        let health = poolHealth
        return MTCard(title: L("Pool health"), systemImage: "heart.text.square") {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 88), spacing: MTTheme.s2)],
                    spacing: MTTheme.s2
                ) {
                    MTMetricTile(title: L("Total"), value: "\(health.total)")
                    MTMetricTile(title: L("Usable"), value: "\(health.usable)", tint: MTTheme.ok)
                    MTMetricTile(title: L("Paused"), value: "\(health.paused)", tint: MTTheme.warn)
                    MTMetricTile(
                        title: L("Errors"),
                        value: "\(health.errors)",
                        tint: health.errors > 0 ? MTTheme.danger : MTTheme.textTertiary
                    )
                }
                HStack(spacing: MTTheme.s3) {
                    averageCell(title: L("5-hour average"), value: health.hourlyAverage)
                    averageCell(title: L("Weekly average"), value: health.weeklyAverage)
                }
            }
        }
    }

    private func averageCell(title: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(MTTheme.mono(9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(MTTheme.textTertiary)
            Text(value.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(MTTheme.display(18, weight: .semibold))
                .foregroundStyle(value == nil ? MTTheme.textTertiary : MTTheme.textPrimary)
            MTMeter(fraction: value.map { $0 / 100.0 })
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Quota trends

    private var hourlyTrend: [DashboardTrend.Point] {
        DashboardTrend.points(
            history: quotaHistory.history,
            field: .hourly,
            now: Date(),
            window: 24 * 3600,
            bucket: 3600
        )
    }

    private var weeklyTrend: [DashboardTrend.Point] {
        DashboardTrend.points(
            history: quotaHistory.history,
            field: .weekly,
            now: Date(),
            window: 7 * 24 * 3600,
            bucket: 24 * 3600
        )
    }

    private var quotaTrendsCard: some View {
        MTCard(title: L("Quota trends"), systemImage: "chart.xyaxis.line") {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                trendRow(title: L("Last 24 hours"), points: hourlyTrend, tint: MTTheme.gold)
                trendRow(title: L("Last 7 days"), points: weeklyTrend, tint: MTTheme.info)
                Text(L("Aggregated across accounts and providers."))
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textSecondary)
            }
        }
    }

    private func trendRow(title: String, points: [DashboardTrend.Point], tint: Color) -> some View {
        HStack(spacing: MTTheme.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(MTTheme.mono(9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(MTTheme.textTertiary)
                Text(points.last.map { "\(Int($0.value.rounded()))%" } ?? "—")
                    .font(MTTheme.display(15, weight: .semibold))
                    .foregroundStyle(points.isEmpty ? MTTheme.textTertiary : MTTheme.textPrimary)
            }
            Spacer(minLength: MTTheme.s2)
            if points.count >= 2 {
                QuotaSparklineShape(values: points.map(\.value), fixedRange: 0...100)
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                    .frame(width: 150, height: 26)
                    .background(
                        MTTheme.borderColor.opacity(0.35),
                        in: RoundedRectangle(cornerRadius: 3)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .accessibilityHidden(true)
            } else {
                Text("—")
                    .font(MTTheme.mono(11))
                    .foregroundStyle(MTTheme.textTertiary)
            }
        }
    }

    // MARK: - Spend and top providers

    private var spendCard: some View {
        MTCard(title: L("Spend & top providers"), systemImage: "dollarsign.circle") {
            if let spend = usage.sessionSpend, !spend.providers.isEmpty {
                VStack(alignment: .leading, spacing: MTTheme.s2) {
                    HStack(alignment: .firstTextBaseline, spacing: MTTheme.s2) {
                        Text(L("Session spend (estimate)").uppercased())
                            .font(MTTheme.mono(9, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(MTTheme.textTertiary)
                        Spacer()
                        Text(spend.hasData ? "≈ " + money(spend.totalUSD) : "—")
                            .font(MTTheme.display(20, weight: .semibold))
                            .foregroundStyle(spend.hasData ? MTTheme.textPrimary : MTTheme.textTertiary)
                    }
                    Divider().overlay(MTTheme.borderColor)
                    ForEach(spend.topProviders(), id: \.provider) { row in
                        providerRow(row)
                    }
                    if spend.scaled {
                        Text(L("Older turns are outside the read window; the estimate is scaled."))
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.textSecondary)
                    }
                }
            } else {
                Text(L("Session data appears when a thread runs this provider's models."))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textSecondary)
            }
        }
    }

    private func providerRow(_ row: SessionSpend.ProviderRanking) -> some View {
        HStack(spacing: MTTheme.s2) {
            Text(providerTitle(row.provider))
                .font(MTTheme.mono(10, weight: .semibold))
                .foregroundStyle(MTTheme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: MTTheme.s2)
            Text(tokens(row.stats.tokens))
                .font(MTTheme.mono(10))
                .foregroundStyle(MTTheme.textSecondary)
            Text(row.stats.usd.map { "≈ " + money($0) } ?? "—")
                .font(MTTheme.mono(10, weight: .semibold))
                .foregroundStyle(row.stats.usd == nil ? MTTheme.textTertiary : MTTheme.textPrimary)
            Text("\(row.stats.turns) " + L("Turns").lowercased())
                .font(MTTheme.mono(9))
                .foregroundStyle(MTTheme.textTertiary)
        }
    }

    private func providerTitle(_ tag: String) -> String {
        switch tag.lowercased() {
        case "openrouter": return "OpenRouter"
        case "opencode": return "OpenCode"
        case "claude": return "Claude"
        case "antigravity": return "Antigravity"
        default: return tag.capitalized
        }
    }

    // MARK: - Scheduler summary

    private var schedulerCard: some View {
        let now = Date()
        let due = SchedulerPolicy.due(scheduler.tasks, now: now)
        let next = DashboardMetrics.nextRun(tasks: scheduler.tasks)
        let last = DashboardMetrics.lastStatus(tasks: scheduler.tasks, history: scheduler.history)
        return MTCard(title: L("Scheduler summary"), systemImage: "clock.badge.checkmark") {
            VStack(alignment: .leading, spacing: MTTheme.s2) {
                HStack(spacing: MTTheme.s2) {
                    MTMetricTile(title: L("Due now"), value: "\(due.count)")
                    MTMetricTile(title: L("Next run"), value: next.map { ISODate.until($0) } ?? "—")
                }
                HStack(spacing: MTTheme.s2) {
                    Text(L("Last status").uppercased())
                        .font(MTTheme.mono(9, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(MTTheme.textTertiary)
                    statusPill(last)
                    Spacer()
                    MTSecondaryButton(
                        title: L("Run next"),
                        systemImage: "play.fill",
                        isLoading: scheduler.isRunning
                    ) {
                        guard gateway.isRunning, let task = due.first else { return }
                        Task { await scheduler.runNow(id: task.id) }
                    }
                    .disabled(due.isEmpty || scheduler.isRunning || !gateway.isRunning)
                }
                if !gateway.isRunning {
                    Text(L("Scheduled runs wait until the service is running."))
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.textSecondary)
                } else if due.isEmpty {
                    Text(L("No due tasks"))
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.textSecondary)
                }
            }
        }
    }

    @ViewBuilder
    private func statusPill(_ status: SchedulerTaskStatus?) -> some View {
        switch status {
        case .ok:
            MTStatusPill(text: L("ok"), status: .ok)
        case .error:
            MTStatusPill(text: L("error"), status: .error)
        case .running:
            MTStatusPill(text: L("running"), status: .running)
        case .cancelled:
            MTStatusPill(text: L("cancelled"), status: .absent)
        case .never, .none:
            MTStatusPill(text: L("Never"), status: .absent)
        }
    }

    // MARK: - Existing pool and API cards

    private var codexCard: some View {
        MTCard(title: L("Codex pool"), systemImage: "person.2") {
            VStack(alignment: .leading, spacing: MTTheme.s2) {
                if codex.accounts.isEmpty {
                    Text(L("No accounts yet."))
                        .font(MTTheme.mono(11))
                        .foregroundStyle(MTTheme.textSecondary)
                } else {
                    ForEach(codex.accounts.prefix(4)) { account in
                        HStack(spacing: MTTheme.s2) {
                            MTQuotaRing(fraction: account.quota?.weeklyRemainingPercent.map { $0 / 100.0 }, size: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(account.displayName)
                                    .font(MTTheme.mono(10, weight: .semibold))
                                    .foregroundStyle(MTTheme.textPrimary)
                                    .lineLimit(1)
                                Text((account.planType ?? "").planDisplayName)
                                    .font(MTTheme.mono(9))
                                    .foregroundStyle(MTTheme.textSecondary)
                            }
                            Spacer()
                            if codex.currentAccountId == account.id {
                                MTStatusPill(text: L("active"), status: .ok)
                            }
                        }
                    }
                }
                Divider().overlay(MTTheme.borderColor)
                HStack(spacing: MTTheme.s2) {
                    Text(String(format: L("Accounts in pool: %d"), codex.accounts.count))
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.textSecondary)
                    if let average = poolHealth.weeklyAverage {
                        Text("·")
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.textSecondary)
                        Text(String(format: L("Weekly quota left: %d%%"), Int(average.rounded())))
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.textSecondary)
                    }
                    Spacer()
                    MTSecondaryButton(title: L("Open"), systemImage: "arrow.right") {
                        selection = .codexAccounts
                    }
                }
            }
        }
    }

    private var gatewayCard: some View {
        MTCard(title: L("Codex API"), systemImage: "network") {
            HStack(spacing: MTTheme.s3) {
                switch gateway.status {
                case .stopped: MTStatusPill(text: L("stopped"), status: .absent)
                case .starting: MTStatusPill(text: L("starting"), status: .warn)
                case .running: MTStatusPill(text: L("running"), status: .ok)
                case .failed: MTStatusPill(text: L("failed"), status: .error)
                }
                if let error = gateway.lastError, case .failed = gateway.status {
                    Text(error)
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.danger)
                        .lineLimit(1)
                }
                Spacer()
                if gateway.isRunning {
                    MTSecondaryButton(title: L("Stop")) {
                        Task { await gateway.stop() }
                    }
                } else {
                    MTPrimaryButton(title: L("Start"), systemImage: "play.fill", isLoading: gateway.isStarting) {
                        codex.load()
                        Task { await gateway.start(accounts: codex.accounts, priorities: codex.effectivePriorities()) }
                    }
                }
                MTSecondaryButton(title: L("Open"), systemImage: "arrow.right") {
                    selection = .codexAPI
                }
            }
        }
    }

    // MARK: - Formatting

    private func tokens(_ value: Int) -> String {
        let n = Double(value)
        if n >= 1_000_000 { return String(format: "%.1fM", n / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fK", n / 1_000) }
        return "\(value)"
    }

    /// `$3.03`, `$30`, `$1000` — locale-independent, same as the composer chips.
    private func money(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.005, value.magnitude >= 1 {
            return String(format: "$%.0f", rounded)
        }
        return String(format: "$%.2f", value)
    }
}
