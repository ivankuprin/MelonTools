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
    @Binding var selection: MTSection

    @State private var route: ProviderRoute?
    @State private var searches: [String: String] = [:]

    /// Sub-pages of the provider board.
    enum ProviderRoute: String, Identifiable {
        case openRouter
        case openCode

        var id: String { rawValue }

        var title: String {
            switch self {
            case .openRouter: return "OpenRouter"
            case .openCode: return "OpenCode"
            }
        }

        var systemImage: String {
            switch self {
            case .openRouter: return "point.3.connected.trianglepath.dotted"
            case .openCode: return "chevron.left.forwardslash.chevron.right"
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
                    HStack(alignment: .top, spacing: MTTheme.s4) {
                        poolCard
                        openCodeCard
                    }
                    openRouterCard
                    applyCard
                }
            }
            .padding(MTTheme.s5)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
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
            subtitle: route == .openRouter
                ? L("Price routing: cheapest providers first.")
                : L("Paid models use your OpenCode account balance.")
        )
        switch route {
        case .openRouter:
            openRouterSettings
        case .openCode:
            openCodeSettings
        }
        applyCard
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
