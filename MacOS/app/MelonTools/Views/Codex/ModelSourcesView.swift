import AppKit
import SwiftUI

/// Providers: the Codex account pool plus the key-based sources (OpenCode and
/// OpenRouter). The board renders one bento card per provider with its live
/// numbers; the «Настройки» button opens the key + model picker of the source,
/// while the pool card leads to Accounts.
struct CodexProvidersView: View {
    @ObservedObject private var gateway = CodexGatewayService.shared
    @ObservedObject private var sources = ModelSourcesStore.shared
    @ObservedObject private var store = CodexStore.shared
    @ObservedObject private var usage = ProviderUsageStore.shared
    @ObservedObject private var quotaHistory = QuotaHistoryStore.shared
    @ObservedObject private var claudeAuth = ClaudeAuthService.shared
    @ObservedObject private var antigravityAuth = AntigravityAuthService.shared
    @ObservedObject private var diagnostics = ProviderDiagnosticsStore.shared
    @Binding var selection: MTSection

    @State private var route: ProviderRoute?
    @State private var searches: [String: String] = [:]
    @State private var confirmClaudeDisconnect = false
    @State private var confirmAntigravityDisconnect = false

    /// Sub-pages of the provider board.
    enum ProviderRoute: String, Identifiable {
        case openRouter
        case openCode
        case claude
        case antigravity

        var id: String { rawValue }

        var title: String {
            switch self {
            case .openRouter: return "OpenRouter"
            case .openCode: return "OpenCode"
            case .claude: return "Claude"
            case .antigravity: return "Antigravity"
            }
        }

        var systemImage: String {
            switch self {
            case .openRouter: return "point.3.connected.trianglepath.dotted"
            case .openCode: return "chevron.left.forwardslash.chevron.right"
            case .claude: return "sparkles"
            case .antigravity: return "globe.americas"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MTTheme.s5) {
                if let route {
                    settingsPage(route)
                } else {
                    MTPageHeader(kicker: "codex", title: L("Providers"), subtitle: L("Providers subtitle"))
                    diagnosticsCard
                    HStack(alignment: .top, spacing: MTTheme.s4) {
                        poolCard
                        openCodeCard
                    }
                    openRouterCard
                    HStack(alignment: .top, spacing: MTTheme.s4) {
                        claudeCard
                        antigravityCard
                    }
                    applyCard
                }
            }
            .padding(MTTheme.s5)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        .mtScrollMemory("scroll.providers")
        }
        .background(MTTheme.background)
        .onAppear {
            sources.load()
            store.load()
            Task {
                await sources.refreshOpenCodeGoAccess()
                await usage.refresh()
                await usage.refreshSession(threadUUID: ComposerBridge.shared.activeThreadID)
            }
        }
    }

    // MARK: - Connection check

    /// Compact, read-only health summary: gateway `/v1/models`, auth files or
    /// keys, model counts and the last quota poll. The probe never writes.
    private var diagnosticsCard: some View {
        MTCard(title: L("Connection check"), systemImage: "checklist") {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                HStack(alignment: .top, spacing: MTTheme.s3) {
                    if let evidence = diagnostics.evidence {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: MTTheme.s2) {
                                MTStatusPill(
                                    text: gatewayPill(evidence),
                                    status: diagnostics.gatewayOK ? .ok : .error
                                )
                                if let finished = diagnostics.finishedAt {
                                    Text(L("Updated") + " " + Self.timeFormatter.string(from: finished))
                                        .font(MTTheme.mono(9))
                                        .foregroundStyle(MTTheme.textTertiary)
                                }
                            }
                            Text(diagnosticsCaption(evidence))
                                .font(MTTheme.mono(9))
                                .foregroundStyle(evidence.gatewayError == nil && evidence.modelsError == nil ? MTTheme.textSecondary : MTTheme.danger)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text(L("Read-only check of the service, auth files, model list and quota updates."))
                            .font(MTTheme.mono(10))
                            .foregroundStyle(MTTheme.textSecondary)
                    }
                    Spacer(minLength: MTTheme.s2)
                    MTSecondaryButton(title: L("Check"), systemImage: "arrow.clockwise", isLoading: diagnostics.isRunning) {
                        Task { await diagnostics.run() }
                    }
                }
                if !diagnostics.rows.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(diagnostics.rows) { row in
                            diagnosticRow(row)
                        }
                    }
                } else {
                    Text(L("Not checked yet."))
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.textTertiary)
                }
            }
        }
    }

    private func gatewayPill(_ evidence: ProviderDiagnostics.Evidence) -> String {
        if let code = evidence.gatewayStatusCode { return "HTTP \(code)" }
        return L("Unreachable")
    }

    private func diagnosticsCaption(_ evidence: ProviderDiagnostics.Evidence) -> String {
        if let error = evidence.gatewayError { return error }
        if let error = evidence.modelsError { return error }
        return String(format: L("Gateway model list: %d"), evidence.models.count)
    }

    private func diagnosticRow(_ row: ProviderDiagnostics.Row) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: MTTheme.s2) {
                MTStatusDot(status: rowStatus(row.status), size: 6)
                Text(L(row.title))
                    .font(MTTheme.body(11, weight: .medium))
                    .foregroundStyle(MTTheme.textPrimary)
                    .frame(width: 96, alignment: .leading)
                Text(authDetail(row))
                    .font(MTTheme.mono(9))
                    .foregroundStyle(row.authPresent ? MTTheme.textSecondary : MTTheme.warn)
                Spacer(minLength: MTTheme.s2)
                Text(row.modelCount.map { String(format: L("Models: %d"), $0) } ?? L("No model list"))
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textSecondary)
                Text("·")
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textTertiary)
                Text(row.quotaUpdatedAt.map { L("Quota updated") + " " + Self.timeFormatter.string(from: $0) } ?? L("No quota data"))
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textSecondary)
                diagnosticHistory(row.id)
            }
            if let error = row.error {
                Text(error)
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.danger)
                    .textSelection(.enabled)
                    .padding(.leading, 16)
            }
        }
        .padding(.vertical, 2)
    }

    private func authDetail(_ row: ProviderDiagnostics.Row) -> String {
        if row.authFileCount > 0 {
            return String(format: L("Auth files: %d"), row.authFileCount)
        }
        return row.hasKey ? L("Key configured") : L("No credentials")
    }

    private func rowStatus(_ status: ProviderDiagnostics.Status) -> MTStatus {
        switch status {
        case .ok: return .ok
        case .warning: return .warn
        case .failed: return .error
        case .idle: return .idle
        }
    }

    /// Read-only history line for diagnostics rows that have a series. Only
    /// the provider-wide keys exist here; per-account history stays in the
    /// account cards.
    @ViewBuilder
    private func diagnosticHistory(_ id: String) -> some View {
        if id == "claude" {
            let samples = quotaHistory.samples(for: id)
            if samples.count >= 2 {
                HStack(spacing: 2) {
                    QuotaSparkline(samples: samples, field: .hourly, width: 36, height: 11)
                    QuotaSparkline(samples: samples, field: .weekly, tint: MTTheme.info, width: 36, height: 11)
                }
            }
        } else if id == "openrouter" {
            let samples = quotaHistory.samples(for: id)
            if samples.count >= 2 {
                QuotaSparkline(samples: samples, field: .balance, tint: MTTheme.ok, width: 48, height: 11)
            }
        }
    }

    // MARK: - Board: the pool

    private var poolCard: some View {
        MTCard(title: L("Codex pool"), systemImage: "person.2") {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                HStack(alignment: .firstTextBaseline, spacing: MTTheme.s2) {
                    Text("\(store.accounts.count)")
                        .font(MTTheme.display(30))
                        .foregroundStyle(MTTheme.textPrimary)
                    Text(L("Accounts"))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                    Spacer(minLength: MTTheme.s2)
                    MTStatusPill(text: gateway.status.label, status: gateway.status.pillStatus)
                }
                quotaRow(title: L("5 h"), fraction: poolQuota(\.hourlyRemainingPercent))
                quotaRow(title: L("Week"), fraction: poolQuota(\.weeklyRemainingPercent))
                HStack(spacing: MTTheme.s4) {
                    healthStat(L("Working"), count: poolHealth.working, status: .ok)
                    healthStat(L("Failed"), count: poolHealth.failed, status: .error)
                    healthStat(L("Paused"), count: poolHealth.paused, status: .warn)
                }
                MTSecondaryButton(title: L("Settings"), systemImage: "slider.horizontal.3") {
                    selection = .codexAccounts
                }
            }
        }
    }

    /// Pool-wide share of quota still available (mean over accounts with data).
    private func poolQuota(_ keyPath: KeyPath<CodexQuota, Double?>) -> Double? {
        let values = store.accounts.compactMap { $0.quota?[keyPath: keyPath] }
        guard !values.isEmpty else { return nil }
        return min(1, max(0, values.reduce(0, +) / Double(values.count) / 100))
    }

    private var poolHealth: (working: Int, failed: Int, paused: Int) {
        let total = store.accounts.count
        let failed = store.accounts.filter { $0.quotaError != nil }.count
        let paused = store.accounts.filter { account in
            guard let quota = account.quota, account.quotaError == nil else { return false }
            return (quota.hourlyRemainingPercent ?? 1) <= 0 || (quota.weeklyRemainingPercent ?? 1) <= 0
        }.count
        return (max(0, total - failed - paused), failed, paused)
    }

    private func quotaRow(title: String, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title.uppercased())
                    .font(MTTheme.mono(9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(MTTheme.textTertiary)
                Spacer()
                Text(fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                    .font(MTTheme.mono(10, weight: .semibold))
                    .foregroundStyle(MTTheme.textPrimary)
            }
            MTMeter(fraction: fraction)
        }
    }

    private func healthStat(_ title: String, count: Int, status: MTStatus) -> some View {
        HStack(spacing: 5) {
            MTStatusDot(status: status, size: 6)
            Text("\(count)")
                .font(MTTheme.mono(10, weight: .semibold))
                .foregroundStyle(MTTheme.textPrimary)
            Text(title)
                .font(MTTheme.mono(9))
                .foregroundStyle(MTTheme.textSecondary)
        }
    }

    // MARK: - Board: OpenCode

    private var openCodeCard: some View {
        let configured = !sources.openCodeKey.isEmpty
        return MTCard(title: "OpenCode", systemImage: ProviderRoute.openCode.systemImage) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                HStack(spacing: MTTheme.s2) {
                    MTStatusPill(text: configured ? L("Key configured") : L("No key"), status: configured ? .ok : .idle)
                    Spacer(minLength: MTTheme.s2)
                }
                keyValueRow(L("Workspace"), usage.openCode?.workspace ?? "—")
                if let source = sources.openCodeSource {
                    modelsMeter(source: source)
                    let goCount = source.models.filter { $0.goTier == true }.count
                    if goCount > 0 {
                        Text(String(format: L("Go plan: %d models"), goCount))
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.textTertiary)
                    }
                }
                sessionLine(provider: "opencode")
                Text(L("Free OpenCode models only work inside the OpenCode app itself."))
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textTertiary)
                Text(L("Go limits and subscription live in the OpenCode console."))
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textTertiary)
                HStack(spacing: MTTheme.s3) {
                    MTSecondaryButton(title: L("Open console"), systemImage: "arrow.up.forward.app") {
                        if let url = URL(string: "https://opencode.ai/console") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    MTSecondaryButton(title: L("Settings"), systemImage: "slider.horizontal.3") {
                        route = .openCode
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - Board: OpenRouter

    private var openRouterCard: some View {
        let configured = !sources.openRouterKey.isEmpty
        let stats = usage.openRouter
        return MTCard(title: "OpenRouter", systemImage: ProviderRoute.openRouter.systemImage) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                HStack(spacing: MTTheme.s2) {
                    MTStatusPill(text: configured ? L("Key configured") : L("No key"), status: configured ? .ok : .idle)
                    Spacer(minLength: MTTheme.s2)
                    if let updated = stats?.updatedAt {
                        Text(L("Updated") + " " + Self.timeFormatter.string(from: updated))
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.textTertiary)
                    }
                }
                if let stats {
                    HStack(alignment: .top, spacing: MTTheme.s3) {
                        MTMetricTile(
                            title: L("Available"),
                            value: stats.creditsRemaining.map(money) ?? "—",
                            caption: L("Balance"),
                            fraction: fraction(stats.creditsRemaining, stats.creditsTotal),
                            tint: MTTheme.ok
                        )
                        MTMetricTile(
                            title: L("Credits spent"),
                            value: stats.creditsUsage.map(money) ?? "—",
                            caption: stats.creditsTotal.map { L("Lifetime") + " · " + L("Purchased").lowercased() + " " + money($0) },
                            fraction: fraction(stats.creditsUsage, stats.creditsTotal)
                        )
                        MTMetricTile(
                            title: L("Key usage"),
                            value: stats.keyUsage.map(money) ?? "—",
                            caption: stats.keyLimit.map { L("Key limit").lowercased() + " " + money($0) },
                            fraction: fraction(stats.keyUsage, stats.keyLimit)
                        )
                    }
                    if let error = stats.error {
                        Text(error)
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.danger)
                    }
                } else {
                    Text(L("Paste the OpenRouter key to load the model list."))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                }
                sessionLine(provider: "openrouter")
                HStack(spacing: MTTheme.s3) {
                    Text(L("Price routing: cheapest providers first."))
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.textTertiary)
                    Spacer(minLength: MTTheme.s2)
                    MTSecondaryButton(title: L("Refresh"), systemImage: "arrow.clockwise") {
                        Task {
                            await usage.refresh(force: true)
                            await usage.refreshSession(threadUUID: ComposerBridge.shared.activeThreadID)
                        }
                    }
                    MTSecondaryButton(title: L("Settings"), systemImage: "slider.horizontal.3") {
                        route = .openRouter
                    }
                }
            }
        }
    }

    // MARK: - Board: Claude

    private var claudeCard: some View {
        let stats = usage.claude
        let connected = stats?.connected == true
        return MTCard(title: "Claude", systemImage: ProviderRoute.claude.systemImage) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                HStack(spacing: MTTheme.s2) {
                    MTStatusPill(text: connected ? L("Connected") : L("Not connected"), status: connected ? .ok : .idle)
                    Spacer(minLength: MTTheme.s2)
                    if let updated = stats?.updatedAt {
                        Text(L("Updated") + " " + Self.timeFormatter.string(from: updated))
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.textTertiary)
                    }
                }
                keyValueRow(L("Account"), stats?.email ?? "—")
                keyValueRow(L("Plan"), stats?.plan ?? "—")
                if let stats {
                    HStack(alignment: .top, spacing: MTTheme.s3) {
                        MTMetricTile(
                            title: L("5 h"),
                            value: percentText(stats.fiveHourPercent),
                            caption: resetCaption(prefix: L("left"), date: stats.fiveHourReset),
                            fraction: stats.fiveHourPercent.map { min(1, max(0, $0 / 100)) },
                            tint: MTTheme.ok
                        )
                        MTMetricTile(
                            title: L("Week"),
                            value: percentText(stats.weeklyPercent),
                            caption: resetCaption(prefix: L("left"), date: stats.weeklyReset),
                            fraction: stats.weeklyPercent.map { min(1, max(0, $0 / 100)) }
                        )
                        MTMetricTile(
                            title: L("Models"),
                            value: "\(stats.modelCount)",
                            caption: L("Selected for Codex")
                        )
                    }
                    QuotaHistorySparklineStrip(
                        samples: quotaHistory.samples(for: "claude"),
                        hourlyTitle: L("5 h"),
                        weeklyTitle: L("Week")
                    )
                    if let error = stats.error {
                        Text(error)
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.danger)
                    }
                } else {
                    Text(L("Connect your Claude account to use subscription models."))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                }
                sessionLine(provider: "Claude")
                HStack(spacing: MTTheme.s3) {
                    Text(L("Quota windows come from the connected Anthropic account."))
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.textTertiary)
                    Spacer(minLength: MTTheme.s2)
                    MTSecondaryButton(title: L("Refresh"), systemImage: "arrow.clockwise") {
                        Task {
                            await usage.refresh(force: true)
                            await usage.refreshSession(threadUUID: ComposerBridge.shared.activeThreadID)
                        }
                    }
                    MTSecondaryButton(title: L("Settings"), systemImage: "slider.horizontal.3") {
                        route = .claude
                    }
                }
            }
        }
    }

    // MARK: - Board: Antigravity

    private var antigravityCard: some View {
        let stats = usage.antigravity
        let connected = stats?.connected == true
        return MTCard(title: "Antigravity", systemImage: ProviderRoute.antigravity.systemImage) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                HStack(spacing: MTTheme.s2) {
                    MTStatusPill(text: connected ? L("Connected") : L("Not connected"), status: connected ? .ok : .idle)
                    Spacer(minLength: MTTheme.s2)
                    if let updated = stats?.updatedAt {
                        Text(L("Updated") + " " + Self.timeFormatter.string(from: updated))
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.textTertiary)
                    }
                }
                keyValueRow(L("Account"), stats?.email ?? "—")
                keyValueRow(L("Project"), stats?.projectID ?? "—")
                if let stats {
                    HStack(alignment: .top, spacing: MTTheme.s3) {
                        MTMetricTile(
                            title: L("Models"),
                            value: "\(stats.modelCount)",
                            caption: L("Selected for Codex")
                        )
                    }
                    if let error = stats.error {
                        Text(error)
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.danger)
                    }
                } else {
                    Text(L("Connect your Google account to use Antigravity models."))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                }
                sessionLine(provider: "Antigravity")
                HStack(spacing: MTTheme.s3) {
                    Text(L("Google account login; no API key is needed."))
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.textTertiary)
                    Spacer(minLength: MTTheme.s2)
                    MTSecondaryButton(title: L("Refresh"), systemImage: "arrow.clockwise") {
                        Task {
                            _ = await antigravityAuth.refreshCredential()
                            await usage.refreshAntigravityNow()
                        }
                    }
                    MTSecondaryButton(title: L("Settings"), systemImage: "slider.horizontal.3") {
                        route = .antigravity
                    }
                }
            }
        }
    }

    private var connectAntigravityButton: some View {
        MTPrimaryButton(title: L("Connect Antigravity"), systemImage: "link", isLoading: antigravityAuth.login.isBusy) {
            Task { await antigravityAuth.startLogin() }
        }
    }

    /// Disconnect removes only the Antigravity auth files. The selected models
    /// are cleared and the catalog regenerated so the picker drops the entries
    /// until the account is connected again.
    private func disconnectAntigravity() {
        antigravityAuth.disconnect()
        sources.setAllModels("antigravity", enabled: false)
        Task {
            await usage.refreshAntigravityNow()
            await sources.apply()
        }
    }

    /// Disconnect removes only the Claude auth files. The selected Claude
    /// models are cleared and the catalog regenerated too, so the Codex picker
    /// drops the entries instead of keeping models that can no longer run.
    private func disconnectClaude() {
        claudeAuth.disconnect()
        sources.setAllModels("claude", enabled: false)
        Task {
            await usage.refreshClaudeNow()
            await sources.apply()
        }
    }

    private func percentText(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()))%"
    }

    private func resetCaption(prefix: String, date: Date?) -> String {
        guard let date else { return prefix }
        return prefix + " · " + Self.resetFormatter.string(from: date)
    }

    private static let resetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: - Shared rows

    private func keyValueRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: MTTheme.s3) {
            Text(title)
                .font(MTTheme.mono(10))
                .foregroundStyle(MTTheme.textSecondary)
            Spacer(minLength: MTTheme.s2)
            Text(value)
                .font(MTTheme.mono(10, weight: .medium))
                .foregroundStyle(MTTheme.textPrimary)
                .textSelection(.enabled)
        }
    }

    /// Models of a source: selected share with a meter and a percent figure.
    private func modelsMeter(source: ModelSource) -> some View {
        let selected = source.selectedModels.count
        let total = source.models.count
        let share = total > 0 ? Double(selected) / Double(total) : nil
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(L("Models").uppercased())
                    .font(MTTheme.mono(9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(MTTheme.textTertiary)
                Spacer()
                Text(String(format: L("Selected %d of %d"), selected, total)
                    + (share.map { " · \(Int(($0 * 100).rounded()))%" } ?? ""))
                    .font(MTTheme.mono(10, weight: .semibold))
                    .foregroundStyle(MTTheme.textPrimary)
            }
            MTMeter(fraction: share)
        }
    }

    /// Session numbers of one provider: spend estimate plus tokens, cache share
    /// and turns that this provider's models ran.
    @ViewBuilder
    private func sessionLine(provider: String) -> some View {
        let stats = usage.sessionSpend?.stats(for: provider)
        let amount = stats?.usd
        VStack(alignment: .leading, spacing: 3) {
            Text(L("Session spend (estimate)").uppercased())
                .font(MTTheme.mono(9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(MTTheme.textTertiary)
            Text(amount.map { "≈ " + money($0) } ?? "—")
                .font(MTTheme.display(18, weight: .semibold))
                .foregroundStyle(amount != nil ? MTTheme.textPrimary : MTTheme.textTertiary)
            if let stats, stats.turns > 0 {
                Text(sessionDetail(stats))
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textSecondary)
            }
            Text(sessionCaption(stats: stats, amount: amount))
                .font(MTTheme.mono(9))
                .foregroundStyle(MTTheme.textSecondary)
        }
    }

    private func sessionDetail(_ stats: SessionSpend.ProviderStats) -> String {
        var parts = [L("Tokens") + " " + tokens(stats.tokens), L("Turns") + " " + "\(stats.turns)"]
        if let hit = stats.cacheHitPercent { parts.append(L("Cache") + " " + "\(hit)%") }
        return parts.joined(separator: " · ")
    }

    private func sessionCaption(stats: SessionSpend.ProviderStats?, amount: Double?) -> String {
        guard stats != nil else {
            return L("Session data appears when a thread runs this provider's models.")
        }
        if amount != nil {
            var caption = L("Estimated from tokens and the model price.")
            if usage.sessionSpend?.scaled == true {
                caption += " " + L("Older turns are outside the read window; the estimate is scaled.")
            }
            return caption
        }
        return L("No pricing data for this model.")
    }

    private func tokens(_ value: Int) -> String {
        let n = Double(value)
        if n >= 1_000_000 { return String(format: "%.1fM", n / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fK", n / 1_000) }
        return "\(value)"
    }

    private func fraction(_ part: Double?, _ whole: Double?) -> Double? {
        guard let part, let whole, whole > 0 else { return nil }
        return min(1, max(0, part / whole))
    }

    /// `$3.03`, `$30`, `$1000` — locale-independent, same as the composer chips.
    private func money(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.005, value.magnitude >= 1 {
            return String(format: "$%.0f", rounded)
        }
        return String(format: "$%.2f", value)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    // MARK: - Settings sub-pages

    @ViewBuilder
    private func settingsPage(_ route: ProviderRoute) -> some View {
        HStack(spacing: MTTheme.s3) {
            MTSecondaryButton(title: L("Back"), systemImage: "chevron.left") {
                self.route = nil
            }
            Spacer(minLength: 0)
        }
        MTPageHeader(
            kicker: "provider settings",
            title: String(format: L("Settings · %@"), route.title),
            subtitle: routeSubtitle(route)
        )
        switch route {
        case .openRouter:
            openRouterSettings
        case .openCode:
            openCodeSettings
        case .claude:
            claudeSettings
        case .antigravity:
            antigravitySettings
        }
        applyCard
    }

    private func routeSubtitle(_ route: ProviderRoute) -> String {
        switch route {
        case .openRouter: return L("Price routing: cheapest providers first.")
        case .openCode: return L("Paid models use your OpenCode account balance.")
        case .claude: return L("Connect your Claude subscription or paste an Anthropic API key.")
        case .antigravity: return L("Connect your Google account to use Antigravity models.")
        }
    }

    private var openRouterSettings: some View {
        MTCard(title: "OpenRouter", systemImage: ProviderRoute.openRouter.systemImage) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                keyRow(key: $sources.openRouterKey) {
                    Task { await sources.loadOpenRouterModels() }
                }
                if let source = sources.openRouterSource {
                    modelBlock(source: source)
                } else {
                    Text(L("Paste the OpenRouter key to load the model list."))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                }
            }
        }
    }

    private var openCodeSettings: some View {
        MTCard(title: "OpenCode", systemImage: ProviderRoute.openCode.systemImage) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                keyRow(key: $sources.openCodeKey) {
                    Task { await sources.loadOpenCodeModels() }
                }
                if let source = sources.openCodeSource {
                    modelBlock(source: source)
                } else {
                    Text(L("Paste the OpenCode key to load the model list."))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Go models route through the Go endpoints (Go plan); other models use the console balance."))
                    Text(L("Free OpenCode models only work inside the OpenCode app itself."))
                    Text(L("Paid models use your OpenCode account balance."))
                }
                .font(MTTheme.mono(10))
                .foregroundStyle(MTTheme.textTertiary)
            }
        }
    }

    private var claudeSettings: some View {
        let stats = usage.claude
        let connected = stats?.connected == true
        return MTCard(title: "Claude", systemImage: ProviderRoute.claude.systemImage) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                if connected {
                    keyValueRow(L("Account"), stats?.email ?? "—")
                    keyValueRow(L("Plan"), stats?.plan ?? "—")
                    HStack(spacing: MTTheme.s3) {
                        MTSecondaryButton(title: L("Refresh login"), systemImage: "arrow.clockwise") {
                            Task {
                                _ = await claudeAuth.refreshCredential()
                                await usage.refreshClaudeNow()
                            }
                        }
                        MTSecondaryButton(title: L("Disconnect"), systemImage: "xmark.circle") {
                            confirmClaudeDisconnect = true
                        }
                        Spacer(minLength: 0)
                    }
                } else {
                    switch claudeAuth.login {
                    case .starting, .waiting:
                        HStack(spacing: MTTheme.s2) {
                            ProgressView().controlSize(.small)
                            Text(L("Waiting for the browser…"))
                                .font(MTTheme.mono(10))
                                .foregroundStyle(MTTheme.textSecondary)
                        }
                        MTSecondaryButton(title: L("Cancel login"), systemImage: "xmark") {
                            Task { await claudeAuth.cancelLogin() }
                        }
                    case .failed(let message):
                        Text(message)
                            .font(MTTheme.mono(10))
                            .foregroundStyle(MTTheme.danger)
                        connectClaudeButton
                    default:
                        connectClaudeButton
                    }
                }
                Text(L("The login opens in your browser; the service stores the account itself."))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textTertiary)

                HStack(spacing: MTTheme.s2) {
                    SecureField(L("Anthropic API key (fallback)"), text: $sources.claudeKey)
                        .textFieldStyle(.roundedBorder)
                        .font(MTTheme.mono(11))
                        .frame(maxWidth: 360)
                    MTPrimaryButton(title: L("Load models"), systemImage: "arrow.down.circle", isLoading: sources.isBusy) {
                        Task { await sources.loadClaudeModels() }
                    }
                    Spacer()
                }
                Text(L("The fallback key is only used when no OAuth account serves the models."))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textTertiary)
                if let source = sources.claudeSource {
                    modelBlock(source: source)
                } else {
                    Text(L("Start the service and connect an account, then load the model list."))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                }
            }
        }
        .confirmationDialog(L("Disconnect this Claude account?"), isPresented: $confirmClaudeDisconnect, titleVisibility: .visible) {
            Button(L("Disconnect"), role: .destructive) {
                disconnectClaude()
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(usage.claude?.email ?? "")
        }
    }

    private var antigravitySettings: some View {
        let stats = usage.antigravity
        let connected = stats?.connected == true
        return MTCard(title: "Antigravity", systemImage: ProviderRoute.antigravity.systemImage) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                if connected {
                    keyValueRow(L("Account"), stats?.email ?? "—")
                    keyValueRow(L("Project"), stats?.projectID ?? "—")
                    HStack(spacing: MTTheme.s3) {
                        MTSecondaryButton(title: L("Refresh login"), systemImage: "arrow.clockwise") {
                            Task {
                                _ = await antigravityAuth.refreshCredential()
                                await usage.refreshAntigravityNow()
                            }
                        }
                        MTSecondaryButton(title: L("Disconnect"), systemImage: "xmark.circle") {
                            confirmAntigravityDisconnect = true
                        }
                        Spacer(minLength: 0)
                    }
                } else {
                    switch antigravityAuth.login {
                    case .starting, .waiting:
                        HStack(spacing: MTTheme.s2) {
                            ProgressView().controlSize(.small)
                            Text(L("Waiting for the browser…"))
                                .font(MTTheme.mono(10))
                                .foregroundStyle(MTTheme.textSecondary)
                        }
                        MTSecondaryButton(title: L("Cancel login"), systemImage: "xmark") {
                            Task { await antigravityAuth.cancelLogin() }
                        }
                    case .failed(let message):
                        Text(message)
                            .font(MTTheme.mono(10))
                            .foregroundStyle(MTTheme.danger)
                        connectAntigravityButton
                    default:
                        connectAntigravityButton
                    }
                }
                Text(L("The login opens in your browser; the service stores the account itself."))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textTertiary)

                HStack(spacing: MTTheme.s2) {
                    MTPrimaryButton(title: L("Load models"), systemImage: "arrow.down.circle", isLoading: sources.isBusy) {
                        Task { await sources.loadAntigravityModels() }
                    }
                    Spacer()
                }
                Text(L("Antigravity models are served by the engine from the connected Google account."))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textTertiary)
                if let source = sources.antigravitySource {
                    modelBlock(source: source)
                } else {
                    Text(L("Start the service and connect an account, then load the model list."))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                }
            }
        }
        .confirmationDialog(L("Disconnect this Antigravity account?"), isPresented: $confirmAntigravityDisconnect, titleVisibility: .visible) {
            Button(L("Disconnect"), role: .destructive) {
                disconnectAntigravity()
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(usage.antigravity?.email ?? "")
        }
    }

    private var connectClaudeButton: some View {
        MTPrimaryButton(title: L("Connect Claude"), systemImage: "link", isLoading: claudeAuth.login.isBusy) {
            Task { await claudeAuth.startLogin() }
        }
    }

    // MARK: - Key + model list

    private func keyRow(key: Binding<String>, action: @escaping () -> Void) -> some View {
        HStack(spacing: MTTheme.s2) {
            SecureField(L("API key"), text: key)
                .textFieldStyle(.roundedBorder)
                .font(MTTheme.mono(11))
                .frame(maxWidth: 360)
            MTPrimaryButton(title: L("Load models"), systemImage: "arrow.down.circle", isLoading: sources.isBusy, action: action)
            Spacer()
        }
    }

    private func modelBlock(source: ModelSource) -> some View {
        VStack(alignment: .leading, spacing: MTTheme.s2) {
            HStack(spacing: MTTheme.s2) {
                Toggle(isOn: Binding(
                    get: { source.enabled },
                    set: { sources.setSourceEnabled(source.id, enabled: $0) }
                )) {
                    Text(L("Enable source"))
                        .font(MTTheme.body(12))
                        .foregroundStyle(MTTheme.textPrimary)
                }
                .toggleStyle(.checkbox)
                Text(String(format: L("Selected %d of %d"), source.selectedModels.count, source.models.count))
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textSecondary)
                Spacer()
                SelectAllControls(
                    search: searchBinding(source.id),
                    placeholder: L("Search"),
                    onSelectAll: { query in sources.setAllModels(source.id, enabled: true, matching: query) },
                    onClear: { query in sources.setAllModels(source.id, enabled: false, matching: query) }
                )
            }
            modelList(source: source, height: 320)
        }
    }

    private func modelList(source: ModelSource, height: CGFloat) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(filtered(source)) { model in
                    modelRow(sourceId: source.id, model: model)
                }
            }
            .padding(.vertical, MTTheme.s1)
        }
        .frame(height: height)
        .background(MTTheme.cardBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: MTTheme.rSmall, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MTTheme.rSmall, style: .continuous)
                .strokeBorder(MTTheme.borderColor.opacity(0.6), lineWidth: 0.75)
        )
    }

    /// A pure-SwiftUI checkbox mark: real Toggles host an AppKit control per
    /// row, and re-hosting them while scrolling a 400+ row list shows as jank.
    private func checkbox(_ isOn: Bool) -> some View {
        Image(systemName: isOn ? "checkmark.square.fill" : "square")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isOn ? MTTheme.gold : MTTheme.textTertiary)
    }

    /// Compact image-capability switch. A plain Button keeps the lazy list
    /// free of one AppKit control per row (see `checkbox` above).
    private func imagesToggle(sourceId: String, model: SourceModel) -> some View {
        let on = model.supportsImages == true
        return Button {
            sources.setModelSupportsImages(sourceId, modelId: model.id, supportsImages: !on)
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "photo")
                Text(L("Images"))
            }
            .font(MTTheme.mono(9, weight: on ? .semibold : .regular))
            .foregroundStyle(on ? MTTheme.gold : MTTheme.textTertiary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(on ? MTTheme.gold.opacity(0.12) : MTTheme.cardSoft.opacity(0.6))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(L("Images"))
        .accessibilityLabel(L("Images"))
        .accessibilityValue(on ? L("On") : L("Off"))
    }

    private func modelRow(sourceId: String, model: SourceModel) -> some View {
        HStack(spacing: MTTheme.s2) {
            checkbox(model.enabled)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.display)
                    .font(MTTheme.body(12))
                    .foregroundStyle(MTTheme.textPrimary)
                    .lineLimit(1)
                if model.display != model.id {
                    Text(model.id)
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: MTTheme.s2)
            if model.goTier == true {
                MTStatusPill(text: "Go", status: .ok)
            }
            if model.freeTier == true {
                MTStatusPill(text: L("app only"), status: .warn)
            }
            imagesToggle(sourceId: sourceId, model: model)
            if let context = model.contextLength, context > 0 {
                Text(context >= 1000 ? "\(context / 1000)K" : "\(context)")
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textSecondary)
            }
        }
        .padding(.horizontal, MTTheme.s3)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onTapGesture {
            sources.setModel(sourceId, modelId: model.id, enabled: !model.enabled)
        }
    }

    private func filtered(_ source: ModelSource) -> [SourceModel] {
        let query = (searches[source.id] ?? "").trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return source.models }
        return source.models.filter {
            $0.id.localizedCaseInsensitiveContains(query) || $0.display.localizedCaseInsensitiveContains(query)
        }
    }

    private func searchBinding(_ id: String) -> Binding<String> {
        Binding(
            get: { searches[id] ?? "" },
            set: { searches[id] = $0 }
        )
    }

    // MARK: - Apply

    private var applyCard: some View {
        MTCard(title: L("Apply"), systemImage: "checkmark.seal") {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                HStack(spacing: MTTheme.s3) {
                    MTPrimaryButton(title: L("Apply"), systemImage: "checkmark") {
                        Task { await sources.apply() }
                    }
                    MTSecondaryButton(title: L("Apply and relaunch Codex"), systemImage: "arrow.clockwise") {
                        Task { await sources.applyAndRelaunch() }
                    }
                    Spacer()
                    Text(String(format: L("Selected %d of %d"), sources.selectedCount, sources.sources.reduce(0) { $0 + $1.models.count }))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                }
                Text(L("Selected models will appear in the Codex picker after a relaunch."))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textSecondary)
                if let note = sources.note {
                    Text(note)
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                        .textSelection(.enabled)
                }
                if let lastApply = sources.lastApply {
                    Text(lastApply)
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.gold)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

private extension CodexGatewayService.Status {
    var pillStatus: MTStatus {
        switch self {
        case .running: return .ok
        case .starting: return .warn
        case .failed: return .error
        case .stopped: return .idle
        }
    }
}

/// Search well + select-all/clear buttons shared by every model list.
private struct SelectAllControls: View {
    @Binding var search: String
    let placeholder: String
    let onSelectAll: (String) -> Void
    let onClear: (String) -> Void

    var body: some View {
        HStack(spacing: MTTheme.s2) {
            TextField(placeholder, text: $search)
                .textFieldStyle(.roundedBorder)
                .font(MTTheme.mono(10))
                .frame(width: 170)
            MTSecondaryButton(title: L("Select all")) { onSelectAll(search) }
            MTSecondaryButton(title: L("Clear")) { onClear(search) }
        }
    }
}
