import AppKit
import SwiftUI

/// Codex accounts: vault, quota rings, browser/device login, import, switch —
/// and the compact API control card, first in the list.
struct CodexAccountsView: View {
    private enum LoginMode { case browser, device }

    @ObservedObject private var store = CodexStore.shared
    @Binding var selection: MTSection
    @State private var showImportSheet = false
    @State private var importText = ""
    @State private var showLoginSheet = false
    @State private var loginMode: LoginMode = .browser
    @State private var selectedAccounts: Set<String> = []
    @State private var confirmDeleteSelection = false
    @State private var deleteTarget: CodexAccount?
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MTTheme.s5) {
                MTPageHeader(
                    kicker: "codex",
                    title: L("Accounts"),
                    subtitle: L("Accounts subtitle")
                )

                controls

                if !store.accounts.isEmpty {
                    selectionBar
                }

                if let message = store.lastMessage {
                    MTCard {
                        HStack(spacing: MTTheme.s2) {
                            Image(systemName: "info.circle")
                                .foregroundStyle(MTTheme.gold)
                            Text(message)
                                .font(MTTheme.mono(11))
                                .foregroundStyle(MTTheme.textPrimary)
                                .textSelection(.enabled)
                            Spacer()
                        }
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: MTTheme.s3)], spacing: MTTheme.s3) {
                    MiniAPICard(selection: $selection)
                    if store.accounts.isEmpty {
                        MTCard {
                            MTEmptyState(
                                systemImage: "person.badge.key",
                                title: L("No Codex accounts yet"),
                                subtitle: L("Sign in via browser, by device code, or import a saved login.")
                            )
                            .frame(height: 180)
                        }
                    } else {
                        ForEach(store.accounts) { account in
                            accountCard(account)
                        }
                    }
                }
            }
            .padding(MTTheme.s5)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        .mtScrollMemory("scroll.accounts")
        }
        .background(MTTheme.background)
        .onAppear { store.load() }
        .onChange(of: store.accounts) {
            selectedAccounts = selectedAccounts.intersection(Set(store.accounts.map(\.id)))
        }
        .sheet(isPresented: $showImportSheet) { importSheet }
        .sheet(isPresented: $showLoginSheet) { loginSheet }
        .sheet(item: $routingAccount) { account in
            AccountRoutingSheet(account: account)
        }
        .confirmationDialog(L("Delete selected accounts?"), isPresented: $confirmDeleteSelection, titleVisibility: .visible) {
            Button(L("Delete"), role: .destructive) { deleteSelected() }
            Button(L("Cancel"), role: .cancel) {}
        }
        .confirmationDialog(L("Delete this account?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(L("Delete"), role: .destructive) {
                if let target = deleteTarget { store.remove(target) }
                deleteTarget = nil
            }
            Button(L("Cancel"), role: .cancel) { deleteTarget = nil }
        } message: {
            Text(deleteTarget?.displayName ?? "")
        }
    }

    /// Shared formatter: a fresh ISO8601DateFormatter per body evaluation is
    /// pure allocation churn.
    private static let quotaStampISO = ISO8601DateFormatter()

    // MARK: - Selection

    private var allAccountsSelected: Bool {
        !store.accounts.isEmpty && store.accounts.allSatisfy { selectedAccounts.contains($0.id) }
    }

    private var selectionBar: some View {
        HStack(spacing: MTTheme.s3) {
            Toggle(isOn: Binding(
                get: { allAccountsSelected },
                set: { selectAll($0) }
            )) {
                Text(L("Select all"))
                    .font(MTTheme.body(12))
                    .foregroundStyle(MTTheme.textPrimary)
            }
            .toggleStyle(.checkbox)
            Text(String(format: L("Selected: %d"), selectedAccounts.count))
                .font(MTTheme.mono(10))
                .foregroundStyle(MTTheme.textSecondary)
            Spacer()
            MTSecondaryButton(title: L("Refresh selected"), systemImage: "arrow.clockwise") {
                Task {
                    for id in selectedAccounts {
                        await store.refreshQuota(for: id, forceTokens: true)
                    }
                }
            }
            .disabled(selectedAccounts.isEmpty)
            MTSecondaryButton(title: L("Delete selected"), systemImage: "trash") {
                confirmDeleteSelection = true
            }
            .disabled(selectedAccounts.isEmpty)
        }
    }

    private func selectionBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { selectedAccounts.contains(id) },
            set: { isOn in
                if isOn {
                    selectedAccounts.insert(id)
                } else {
                    selectedAccounts.remove(id)
                }
            }
        )
    }

    private func selectAll(_ on: Bool) {
        if on {
            selectedAccounts = Set(store.accounts.map(\.id))
        } else {
            selectedAccounts.removeAll()
        }
    }

    private func deleteSelected() {
        for account in store.accounts where selectedAccounts.contains(account.id) {
            store.remove(account)
        }
        selectedAccounts.removeAll()
    }

    @State private var routingAccount: CodexAccount?

    private var controls: some View {
        HStack(spacing: MTTheme.s3) {
            MTPrimaryButton(title: L("OAuth browser login"), systemImage: "safari") {
                loginMode = .browser
                showLoginSheet = true
                store.startBrowserLogin()
            }
            MTSecondaryButton(title: L("Device login"), systemImage: "person.badge.plus") {
                loginMode = .device
                showLoginSheet = true
                store.startDeviceLogin()
            }
            MTSecondaryButton(title: L("Import from CLI"), systemImage: "square.and.arrow.down") {
                store.importFromCodexCLI()
            }
            MTSecondaryButton(title: L("Paste login (JSON)"), systemImage: "doc.on.clipboard") {
                showImportSheet = true
            }
            Spacer()
            MTSecondaryButton(title: L("Refresh quotas"), systemImage: "arrow.clockwise") {
                Task { await store.refreshAllQuotas(forceTokens: true) }
            }
        }
    }

    private func accountCard(_ account: CodexAccount) -> some View {
        MTCard {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                HStack(alignment: .top, spacing: MTTheme.s3) {
                    Toggle("", isOn: selectionBinding(account.id))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.displayName)
                            .font(MTTheme.body(13, weight: .semibold))
                            .foregroundStyle(MTTheme.textPrimary)
                            .lineLimit(1)
                        HStack(spacing: MTTheme.s2) {
                            Text((account.planType ?? "").planDisplayName)
                                .font(MTTheme.mono(10, weight: .semibold))
                                .foregroundStyle(MTTheme.gold)
                            if let position = store.routingPosition(of: account.id) {
                                Text("· №\(position)")
                                    .font(MTTheme.mono(9))
                                    .foregroundStyle(MTTheme.textSecondary)
                            }
                        }
                    }
                    Spacer()
                    if store.currentAccountId == account.id {
                        MTStatusPill(text: L("active"), status: .ok)
                    }
                    Button {
                        routingAccount = account
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 11))
                            .foregroundStyle(MTTheme.textSecondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L("Account routing settings"))
                }

                routingBadges(account)

                subscriptionRow(account)

                VStack(alignment: .leading, spacing: MTTheme.s2) {
                    quotaBar(
                        title: L("hourly"),
                        percent: account.quota?.hourlyRemainingPercent,
                        reset: account.quota?.hourlyResetAt
                    )
                    quotaBar(
                        title: L("weekly"),
                        percent: account.quota?.weeklyRemainingPercent,
                        reset: account.quota?.weeklyResetAt
                    )
                    HStack(spacing: MTTheme.s3) {
                        if let credits = account.quota?.resetCreditsAvailable {
                            if credits > 0 {
                                HStack(spacing: 4) {
                                    Text("\(credits)")
                                        .font(MTTheme.mono(11, weight: .bold))
                                        .foregroundStyle(MTTheme.textPrimary)
                                    Text(L("resets"))
                                        .font(MTTheme.mono(9))
                                        .foregroundStyle(MTTheme.textSecondary)
                                }
                                .help(resetHelp(account))
                            } else {
                                Text(L("No resets available"))
                                    .font(MTTheme.mono(9))
                                    .foregroundStyle(MTTheme.textTertiary)
                            }
                        }
                        if account.quota?.unlimitedCredits == true {
                            MTStatusPill(text: L("Credits"), status: .ok)
                        } else if let balance = account.quota?.creditsBalance, balance != "0", !balance.isEmpty {
                            Text("\(L("Credits")): \(balance)")
                                .font(MTTheme.mono(9))
                                .foregroundStyle(MTTheme.textSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                }

                if account.quota?.weeklyRemainingPercent == 0, (account.quota?.hourlyRemainingPercent ?? 0) > 0 {
                    Text(L("Weekly quota is 0%, so the 5-hour window is unavailable"))
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.warn)
                }

                if let error = account.quotaError {
                    Text(error)
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.danger)
                        .lineLimit(2)
                } else if let updated = account.quotaUpdatedAt {
                    Text(String(format: L("quota updated %@"), ISODate.relative(Self.quotaStampISO.string(from: updated))))
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.textSecondary)
                }

                if let models = account.quota?.modelAvailability, !models.isEmpty {
                    modelAvailability(models)
                }

                HStack(spacing: MTTheme.s2) {
                    if store.currentAccountId != account.id {
                        MTSecondaryButton(title: L("Switch"), systemImage: "arrow.left.arrow.right", isLoading: store.busyAccountIds.contains(account.id)) {
                            Task { await store.switchTo(account) }
                        }
                    }
                    MTSecondaryButton(title: L("Quota"), systemImage: "gauge.with.dots.needle.33percent", isLoading: store.busyAccountIds.contains(account.id)) {
                        Task { await store.refreshQuota(for: account.id, forceTokens: true) }
                    }
                    MTSecondaryButton(title: L("Launch in Codex"), systemImage: "arrow.up.forward.app") {
                        store.launchInCodex(account)
                    }
                    Spacer()
                    Button {
                        deleteTarget = account
                        confirmDelete = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(MTTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help(L("Delete"))
                }
            }
        }
    }

    /// Small chips under the account name: quota limits, “first”, “backup”
    /// and the current paused-by-limit state.
    @ViewBuilder
    private func routingBadges(_ account: CodexAccount) -> some View {
        let hourlyLimit = account.hourlyReservePercent ?? 0
        let weeklyLimit = account.weeklyReservePercent ?? 0
        let blockedReason = CodexRoutingPlanner.blockReason(account)
        let hasAny = hourlyLimit > 0 || weeklyLimit > 0 || account.preferredFirst == true || account.isBackup == true || blockedReason != nil
        if hasAny {
            HStack(spacing: MTTheme.s2) {
                if hourlyLimit > 0 {
                    routingChip("\(L("5 h")) ≤ \(hourlyLimit)%")
                }
                if weeklyLimit > 0 {
                    routingChip("\(L("Week")) ≤ \(weeklyLimit)%")
                }
                if account.preferredFirst == true {
                    routingChip(L("First"), gold: true)
                }
                if account.isBackup == true {
                    routingChip(L("Backup"), gold: true)
                }
                if let reason = blockedReason {
                    Text(L("Paused by limit"))
                        .font(MTTheme.mono(9, weight: .semibold))
                        .foregroundStyle(MTTheme.warn)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(MTTheme.warn.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .help(reason)
                }
                Spacer()
            }
        }
    }

    private func routingChip(_ text: String, gold: Bool = false) -> some View {
        Text(text)
            .font(MTTheme.mono(9, weight: .semibold))
            .foregroundStyle(gold ? MTTheme.gold : MTTheme.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background((gold ? MTTheme.gold : MTTheme.textSecondary).opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func modelAvailability(_ models: [CodexModelAvailability]) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(models) { item in
                    HStack(spacing: MTTheme.s2) {
                        MTStatusDot(status: item.available ? .ok : .absent, size: 6)
                        Text(item.model)
                            .font(MTTheme.mono(10))
                            .foregroundStyle(MTTheme.textPrimary)
                        Spacer()
                        Text(item.available ? L("available") : L("unavailable"))
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.textSecondary)
                    }
                }
            }
            .padding(.top, MTTheme.s1)
        } label: {
            Text(String(format: L("Models on this account (%d)"), models.count))
                .font(MTTheme.mono(10, weight: .medium))
                .foregroundStyle(MTTheme.textSecondary)
        }
        .disclosureGroupStyle(.automatic)
    }

    /// Horizontal quota bar: label + percent, a bar and a detailed reset time.
    private func quotaBar(title: String, percent: Double?, reset: Date?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title.uppercased())
                    .font(MTTheme.mono(9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(MTTheme.textTertiary)
                Spacer()
                Text(percent.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(MTTheme.mono(10, weight: .semibold))
                    .foregroundStyle(MTTheme.textPrimary)
            }
            MTMeter(fraction: percent.map { min(1, max(0, $0 / 100)) })
            if let reset {
                Text(detailedResetText(reset))
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textSecondary)
            }
        }
    }

    /// Two-component reset times: «через 1 ч 23 мин», «через 6 дн 4 ч».
    private func detailedResetText(_ date: Date) -> String {
        let ru = L10n.shared.code == "ru"
        let interval = date.timeIntervalSinceNow
        if interval <= 0 { return L("reset now") }
        let minutes = Int(interval / 60)
        if minutes < 60 { return ru ? "через \(minutes) мин" : "in \(minutes)m" }
        let hours = minutes / 60
        if hours < 24 {
            return ru ? "через \(hours) ч \(minutes % 60) мин" : "in \(hours)h \(minutes % 60)m"
        }
        let days = hours / 24
        return ru ? "через \(days) дн \(hours % 24) ч" : "in \(days)d \(hours % 24)h"
    }

    // MARK: - Subscription & resets

    /// Subscription end date with a relative reminder, like the Cockpit cards.
    @ViewBuilder
    private func subscriptionRow(_ account: CodexAccount) -> some View {
        let until = account.subscriptionActiveUntil.flatMap { ISO8601DateFormatter().date(from: $0) }
        let plan = (account.planType ?? "").lowercased()
        let paidPlan = !plan.isEmpty && plan != "free"
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: MTTheme.s2) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 10))
                    .foregroundStyle(MTTheme.textSecondary)
                if let until {
                    let expired = until < Date()
                    Text(expired
                         ? L("Subscription expired")
                         : String(format: L("Subscription ends %@"), Self.subscriptionDate.string(from: until)))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(expired ? MTTheme.danger : MTTheme.textPrimary)
                    if !expired {
                        Text(relativeRemaining(until))
                            .font(MTTheme.mono(10, weight: .semibold))
                            .foregroundStyle(MTTheme.textSecondary)
                    }
                } else {
                    Text(L("Subscription end date unknown — refresh the login"))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textTertiary)
                }
                Spacer(minLength: 0)
            }
            if let until, until < Date(), paidPlan {
                Text(L("Paid plan, but the period has ended — the payment may still be processing; check billing in ChatGPT."))
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.warn)
            }
        }
    }

    private func relativeRemaining(_ until: Date) -> String {
        let interval = until.timeIntervalSinceNow
        if interval <= 0 { return L("expired") }
        let days = Int(interval / 86400)
        if days > 99 { return L("99+ days") }
        if days >= 1 { return String(format: L("%d days"), days) }
        let hours = max(1, Int(interval / 3600))
        return String(format: L("%d h"), hours)
    }

    private func resetHelp(_ account: CodexAccount) -> String {
        let count = account.quota?.resetCreditsAvailable ?? 0
        var text = String(format: L("Reset credits for the 5-hour window: %d"), count)
        if let expiry = account.quota?.resetCreditsNextExpiry {
            text += "\n" + String(format: L("Next reset credit expires %@"), Self.subscriptionDate.string(from: expiry))
        }
        return text
    }

    private static let subscriptionDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private var importSheet: some View {
        VStack(alignment: .leading, spacing: MTTheme.s4) {
            Text(L("Paste login (JSON)"))
                .font(MTTheme.display(20))
                .foregroundStyle(MTTheme.textPrimary)
            Text(L("Paste the full contents of a saved Codex login file (JSON)."))
                .font(MTTheme.body(12))
                .foregroundStyle(MTTheme.textSecondary)
            TextEditor(text: $importText)
                .font(MTTheme.mono(11))
                .scrollContentBackground(.hidden)
                .background(MTTheme.background)
                .frame(height: 200)
                .overlay(RoundedRectangle(cornerRadius: MTTheme.rSmall).strokeBorder(MTTheme.borderColor))
            HStack {
                Spacer()
                MTSecondaryButton(title: L("Cancel")) { showImportSheet = false }
                MTPrimaryButton(title: L("Import"), systemImage: "checkmark") {
                    store.importFromJSON(importText)
                    importText = ""
                    showImportSheet = false
                }
            }
        }
        .padding(MTTheme.s5)
        .frame(width: 560)
        .background(MTTheme.background)
    }

    private var loginSheet: some View {
        VStack(alignment: .leading, spacing: MTTheme.s4) {
            Text(loginMode == .browser ? L("Browser login") : L("Device login"))
                .font(MTTheme.display(20))
                .foregroundStyle(MTTheme.textPrimary)

            if loginMode == .browser {
                browserLoginBody
            } else {
                deviceLoginBody
            }

            HStack {
                Spacer()
                MTSecondaryButton(title: L("Close")) {
                    store.cancelBrowserLogin()
                    store.cancelDeviceLogin()
                    showLoginSheet = false
                }
            }
        }
        .padding(MTTheme.s5)
        .frame(width: 540)
        .background(MTTheme.background)
    }

    private var browserLoginBody: some View {
        VStack(alignment: .leading, spacing: MTTheme.s3) {
            HStack(spacing: MTTheme.s3) {
                if store.browserLoginActive {
                    ProgressView().controlSize(.small)
                }
                Text(store.browserLoginStatus.isEmpty ? L("Opening browser…") : store.browserLoginStatus)
                    .font(MTTheme.mono(12))
                    .foregroundStyle(MTTheme.textPrimary)
                    .textSelection(.enabled)
            }
            if store.browserLoginActive {
                Text(L("Waiting for you to finish sign-in in the browser…"))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textSecondary)
            }
        }
    }

    private var deviceLoginBody: some View {
        VStack(alignment: .leading, spacing: MTTheme.s3) {
            Text(store.deviceLoginStatus.isEmpty ? L("Requesting device code…") : store.deviceLoginStatus)
                .font(MTTheme.mono(12))
                .foregroundStyle(MTTheme.textPrimary)
                .textSelection(.enabled)
            if let session = store.deviceSession {
                HStack(spacing: MTTheme.s3) {
                    Text(session.userCode)
                        .font(MTTheme.mono(24, weight: .bold))
                        .foregroundStyle(MTTheme.onGold)
                        .padding(.horizontal, MTTheme.s4)
                        .padding(.vertical, MTTheme.s2)
                        .background(MTTheme.gold)
                        .clipShape(RoundedRectangle(cornerRadius: MTTheme.rSmall))
                    MTSecondaryButton(title: L("Copy code")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(session.userCode, forType: .string)
                    }
                    MTSecondaryButton(title: L("Open browser")) {
                        if let url = URL(string: session.verificationURL) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                Text(L("Waiting for you to finish sign-in in the browser…"))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textSecondary)
            }
        }
    }
}

// MARK: - Compact API card (first in the list)

/// Mini version of the API control block: state, address, routing mode and
/// the current queue order — with the Codex launch button. Full controls
/// live on the API Service page.
private struct MiniAPICard: View {
    @ObservedObject private var gateway = CodexGatewayService.shared
    @ObservedObject private var store = CodexStore.shared
    @Binding var selection: MTSection

    @State private var launching = false

    var body: some View {
        MTCard {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                HStack(spacing: MTTheme.s2) {
                    Text(L("API control"))
                        .font(MTTheme.body(13, weight: .semibold))
                        .foregroundStyle(MTTheme.textPrimary)
                    Spacer()
                    statusPill
                }

                HStack(spacing: MTTheme.s2) {
                    Text(L("Routing mode"))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                    Spacer()
                    Picker("", selection: $store.routingStrategy) {
                        ForEach(CodexRoutingStrategy.allCases) { strategy in
                            Text(strategy.title).tag(strategy)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 200, alignment: .trailing)
                }

                orderPreview

                Spacer(minLength: 0)

                HStack(spacing: MTTheme.s2) {
                    MTPrimaryButton(
                        title: gateway.codexRoute == .melon ? L("Open Codex") : L("Launch Codex"),
                        systemImage: "play.fill",
                        isLoading: launching
                    ) {
                        guard !launching else { return }
                        launching = true
                        Task {
                            defer { launching = false }
                            await gateway.launchCodexApp()
                        }
                    }
                    MTSecondaryButton(title: L("Manage"), systemImage: "arrow.right") {
                        selection = .codexAPI
                    }
                    Spacer()
                }
            }
        }
    }

    private var statusPill: MTStatusPill {
        switch gateway.status {
        case .stopped:
            return MTStatusPill(text: L("stopped"), status: .absent)
        case .starting:
            return MTStatusPill(text: L("starting"), status: .warn)
        case .running:
            return MTStatusPill(text: L("running"), status: .ok)
        case .failed:
            return MTStatusPill(text: L("failed"), status: .error)
        }
    }

    @ViewBuilder
    private var orderPreview: some View {
        let resolution = store.routingResolution()
        if store.accounts.isEmpty {
            Text(L("No Codex accounts yet"))
                .font(MTTheme.mono(10))
                .foregroundStyle(MTTheme.textSecondary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(resolution.orderedIds.prefix(3).enumerated()), id: \.element) { index, id in
                    if let account = store.accounts.first(where: { $0.id == id }) {
                        HStack(spacing: MTTheme.s2) {
                            Text("\(index + 1)")
                                .font(MTTheme.mono(9, weight: .semibold))
                                .foregroundStyle(MTTheme.textSecondary)
                                .frame(width: 12, alignment: .trailing)
                            MTStatusDot(status: resolution.blocked.contains(id) ? .warn : quotaDot(account), size: 5)
                            Text(account.displayName)
                                .font(MTTheme.mono(10))
                                .foregroundStyle(MTTheme.textPrimary)
                                .lineLimit(1)
                            if account.preferredFirst == true {
                                Text(L("First"))
                                    .font(MTTheme.mono(8, weight: .semibold))
                                    .foregroundStyle(MTTheme.gold)
                            }
                            if account.isBackup == true {
                                Text(L("Backup"))
                                    .font(MTTheme.mono(8, weight: .semibold))
                                    .foregroundStyle(MTTheme.gold)
                            }
                            if resolution.blocked.contains(id) {
                                Text(L("Paused by limit"))
                                    .font(MTTheme.mono(8, weight: .semibold))
                                    .foregroundStyle(MTTheme.warn)
                            }
                            Spacer()
                            if let hourly = account.quota?.hourlyRemainingPercent {
                                Text("\(Int(hourly))%")
                                    .font(MTTheme.mono(9))
                                    .foregroundStyle(MTTheme.textSecondary)
                            }
                        }
                    }
                }
                if resolution.orderedIds.count > 3 {
                    Text(String(format: L("+%d more"), resolution.orderedIds.count - 3))
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.textSecondary)
                }
            }
        }
    }

    private func quotaDot(_ account: CodexAccount) -> MTStatus {
        guard let hourly = account.quota?.hourlyRemainingPercent else { return .idle }
        if hourly > 30 { return .ok }
        if hourly > 5 { return .warn }
        return .error
    }
}

// MARK: - Per-account routing sheet

/// Limits and roles for one account: pause thresholds for the 5-hour and
/// weekly windows, “always first”, “backup”.
private struct AccountRoutingSheet: View {
    @ObservedObject private var store = CodexStore.shared
    let account: CodexAccount

    @Environment(\.dismiss) private var dismiss
    @State private var hourlyEnabled = false
    @State private var hourly = 10
    @State private var weeklyEnabled = false
    @State private var weekly = 5
    @State private var preferred = false
    @State private var backup = false
    @State private var initialized = false

    var body: some View {
        VStack(alignment: .leading, spacing: MTTheme.s4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Account routing settings"))
                    .font(MTTheme.display(20))
                    .foregroundStyle(MTTheme.textPrimary)
                Text(account.displayName)
                    .font(MTTheme.mono(11))
                    .foregroundStyle(MTTheme.textSecondary)
            }

            VStack(alignment: .leading, spacing: MTTheme.s3) {
                Text(L("Limits"))
                    .font(MTTheme.body(12, weight: .semibold))
                    .foregroundStyle(MTTheme.textPrimary)
                limitRow(title: L("5-hour limit"), enabled: $hourlyEnabled, value: $hourly)
                limitRow(title: L("Weekly limit"), enabled: $weeklyEnabled, value: $weekly)
                Text(L("When the threshold is reached, the next account takes over automatically; this one returns when its quota recovers."))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textSecondary)
            }

            Rectangle()
                .fill(MTTheme.borderColor.opacity(0.6))
                .frame(height: 1)

            VStack(alignment: .leading, spacing: MTTheme.s2) {
                Toggle(L("Always first"), isOn: $preferred)
                    .toggleStyle(.switch)
                Text(L("The “always first” account leads while it is not paused by limits."))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textSecondary)
                Toggle(L("Backup"), isOn: $backup)
                    .toggleStyle(.switch)
                    .padding(.top, MTTheme.s1)
                Text(L("A backup account is used only when the regular accounts are unavailable."))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textSecondary)
            }

            if let position = store.routingPosition(of: account.id) {
                Text(String(format: L("Queue position: %d"), position))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textSecondary)
            }

            HStack(spacing: MTTheme.s2) {
                Spacer()
                MTSecondaryButton(title: L("Cancel")) { dismiss() }
                MTPrimaryButton(title: L("Save"), systemImage: "checkmark") {
                    store.updateRoutingSettings(
                        account,
                        hourlyPercent: hourlyEnabled ? hourly : nil,
                        weeklyPercent: weeklyEnabled ? weekly : nil,
                        preferredFirst: preferred,
                        isBackup: backup
                    )
                    dismiss()
                }
            }
        }
        .padding(MTTheme.s5)
        .frame(width: 520)
        .background(MTTheme.background)
        .onAppear {
            guard !initialized else { return }
            initialized = true
            hourlyEnabled = (account.hourlyReservePercent ?? 0) > 0
            hourly = account.hourlyReservePercent ?? 10
            weeklyEnabled = (account.weeklyReservePercent ?? 0) > 0
            weekly = account.weeklyReservePercent ?? 5
            preferred = account.preferredFirst == true
            backup = account.isBackup == true
        }
    }

    private func limitRow(title: String, enabled: Binding<Bool>, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: MTTheme.s2) {
            Toggle(title, isOn: enabled)
                .toggleStyle(.switch)
            if enabled.wrappedValue {
                HStack(spacing: MTTheme.s3) {
                    Stepper(value: value, in: 1...100) {
                        Text("\(value.wrappedValue)%")
                            .font(MTTheme.mono(12, weight: .semibold))
                            .foregroundStyle(MTTheme.textPrimary)
                            .frame(width: 48, alignment: .leading)
                    }
                    .frame(width: 160)
                    Text(L("switch when quota left drops to this percent"))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                }
                .padding(.leading, MTTheme.s4)
            }
        }
    }
}
