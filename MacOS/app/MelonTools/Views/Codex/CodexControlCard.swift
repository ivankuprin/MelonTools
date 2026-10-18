import AppKit
import SwiftUI

/// API service control: gateway state, the Codex app route, and the account
/// pool routing — one place to run the whole pool. Lives on the API Service
/// page; the Accounts page shows the compact version of this card.
///
/// «Запустить Codex» переводит приложение Codex на этот сервис (прошлое
/// подключение сохраняется) и перезапускает приложение — дальше запросы
/// идут по аккаунтам согласно режиму, лимитам и ролям учётных записей.
struct CodexControlCard: View {
    @ObservedObject private var gateway = CodexGatewayService.shared
    @ObservedObject private var store = CodexStore.shared

    @State private var launching = false

    var body: some View {
        MTCard(title: L("API control"), systemImage: "network") {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                serviceRow
                launchRow
                if let error = gateway.lastError {
                    noteLine(error, color: MTTheme.danger, icon: "exclamationmark.triangle")
                }
                if let check = gateway.checkResult {
                    noteLine(
                        check,
                        color: gateway.checkPassed ? MTTheme.ok : MTTheme.danger,
                        icon: gateway.checkPassed ? "checkmark.seal" : "xmark.seal"
                    )
                }
                Rectangle()
                    .fill(MTTheme.borderColor.opacity(0.6))
                    .frame(height: 1)
                routingSection
            }
        }
    }

    // MARK: - Service row

    private var serviceRow: some View {
        HStack(spacing: MTTheme.s2) {
            statusPill
            if gateway.adopted {
                MTStatusPill(text: L("adopted"), status: .info)
            }
            Spacer()
            if gateway.isRunning {
                MTSecondaryButton(title: L("Check API"), systemImage: "checkmark.seal", isLoading: gateway.isChecking) {
                    Task { await gateway.checkAPI() }
                }
                MTSecondaryButton(title: L("Restart"), systemImage: "arrow.clockwise") {
                    Task { await gateway.restart(accounts: store.accounts, priorities: store.effectivePriorities()) }
                }
                MTSecondaryButton(title: L("Stop"), systemImage: "stop.fill") {
                    Task { await gateway.stop() }
                }
            } else {
                MTPrimaryButton(title: L("Start gateway"), systemImage: "play.fill", isLoading: gateway.isStarting) {
                    store.load()
                    Task { await gateway.start(accounts: store.accounts, priorities: store.effectivePriorities()) }
                }
                MTSecondaryButton(title: L("Adopt running"), systemImage: "link") {
                    store.load()
                    Task { await gateway.start(accounts: store.accounts, priorities: store.effectivePriorities()) }
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

    // MARK: - Launch row

    private var launchRow: some View {
        VStack(alignment: .leading, spacing: MTTheme.s2) {
            HStack(spacing: MTTheme.s3) {
                MTPrimaryButton(
                    title: routeIsMelon ? L("Open Codex") : L("Launch Codex"),
                    systemImage: routeIsMelon ? "arrow.up.forward.app" : "play.fill",
                    isLoading: launching
                ) {
                    launch()
                }
                if routeIsMelon {
                    MTSecondaryButton(title: L("Remove routing"), systemImage: "arrow.uturn.backward") {
                        removeRoute()
                    }
                }
                routeBadge
                Spacer()
            }
            Text(launchNote)
                .font(MTTheme.mono(10))
                .foregroundStyle(MTTheme.textSecondary)
        }
    }

    private var routeIsMelon: Bool {
        gateway.codexRoute == .melon
    }

    private var routeBadge: some View {
        HStack(spacing: MTTheme.s2) {
            MTStatusDot(status: routeStatus, size: 6)
            Text(routeText)
                .font(MTTheme.mono(10))
                .foregroundStyle(MTTheme.textSecondary)
        }
    }

    private var routeStatus: MTStatus {
        switch gateway.codexRoute {
        case .melon: return .ok
        case .none: return .idle
        case .other: return .warn
        }
    }

    private var routeText: String {
        switch gateway.codexRoute {
        case .melon:
            return L("Codex routes through this service.")
        case .none:
            return L("No route — the Codex app talks to OpenAI directly.")
        case .other(let name):
            return String(format: L("External route active: %@ (another API tool)."), name)
        }
    }

    private var launchNote: String {
        routeIsMelon
            ? L("Routing is on — Codex requests are served from the account pool.")
            : L("The launch connects the Codex app to this service (the previous connection is backed up) and reopens the app with the current routing.")
    }

    // MARK: - Routing section

    private var routingSection: some View {
        let resolution = store.routingResolution()
        return VStack(alignment: .leading, spacing: MTTheme.s3) {
            HStack(spacing: MTTheme.s3) {
                Text(L("Account routing"))
                    .font(MTTheme.body(12, weight: .semibold))
                    .foregroundStyle(MTTheme.textPrimary)
                Spacer()
                Picker("", selection: $store.routingStrategy) {
                    ForEach(CodexRoutingStrategy.allCases) { strategy in
                        Text(strategy.title).tag(strategy)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 260, alignment: .trailing)
            }
            Text(store.routingStrategy.hint)
                .font(MTTheme.mono(10))
                .foregroundStyle(MTTheme.textSecondary)

            if let note = store.routingNote {
                noteLine(note, color: MTTheme.gold, icon: "arrow.triangle.branch")
            }

            if !store.accounts.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(resolution.orderedIds.enumerated()), id: \.element) { index, id in
                        if let account = store.accounts.first(where: { $0.id == id }) {
                            priorityRow(
                                account: account,
                                index: index,
                                blockedReason: resolution.blockReasons[id]
                            )
                        }
                    }
                }
            }

            HStack(spacing: MTTheme.s2) {
                if store.accounts.count > 1 {
                    MTSecondaryButton(title: L("Reset order"), systemImage: "arrow.counterclockwise") {
                        store.resetPriorityOrder()
                    }
                }
                MTPrimaryButton(title: L("Apply routing"), systemImage: "checkmark", isLoading: gateway.isStarting) {
                    Task { await gateway.applyRouting(accounts: store.accounts, priorities: store.effectivePriorities()) }
                }
                Spacer()
                Text(String(format: L("%d account(s) in the pool"), store.accounts.count))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textSecondary)
            }
        }
    }

    private func priorityRow(account: CodexAccount, index: Int, blockedReason: String?) -> some View {
        HStack(spacing: MTTheme.s2) {
            Text("\(index + 1)")
                .font(MTTheme.mono(10, weight: .semibold))
                .foregroundStyle(MTTheme.textSecondary)
                .frame(width: 16, alignment: .trailing)
            MTStatusDot(status: blockedReason == nil ? quotaDot(account) : .warn, size: 6)
            Text(account.displayName)
                .font(MTTheme.body(12, weight: .medium))
                .foregroundStyle(MTTheme.textPrimary)
                .lineLimit(1)
            Text((account.planType ?? "").planDisplayName)
                .font(MTTheme.mono(9, weight: .semibold))
                .foregroundStyle(MTTheme.gold)
            if let note = account.note, !note.isEmpty {
                Text(note)
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textSecondary)
                    .lineLimit(1)
            }
            if let hourly = account.quota?.hourlyRemainingPercent {
                Text("\(Int(hourly))%")
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textSecondary)
            }
            if let weekly = account.quota?.weeklyRemainingPercent {
                Text("· \(Int(weekly))%")
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textSecondary)
            }
            if account.preferredFirst == true {
                roleBadge(L("First"))
            }
            if account.isBackup == true {
                roleBadge(L("Backup"))
            }
            if let reason = blockedReason {
                Text(reason)
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.warn)
                    .lineLimit(1)
            }
            Spacer()
            if store.currentAccountId == account.id {
                MTStatusPill(text: L("active"), status: .ok)
            }
            if store.routingStrategy == .custom {
                Button {
                    store.moveAccountPriority(account.id, up: true)
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(index == 0 ? MTTheme.textTertiary : MTTheme.textSecondary)
                        .frame(width: 22, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(index == 0)
                .help(L("Raise priority"))
                Button {
                    store.moveAccountPriority(account.id, up: false)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(index == store.accounts.count - 1 ? MTTheme.textTertiary : MTTheme.textSecondary)
                        .frame(width: 22, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(index == store.accounts.count - 1)
                .help(L("Lower priority"))
            }
        }
        .padding(.vertical, 2)
    }

    private func roleBadge(_ text: String) -> some View {
        Text(text)
            .font(MTTheme.mono(9, weight: .semibold))
            .foregroundStyle(MTTheme.gold)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(MTTheme.gold.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func quotaDot(_ account: CodexAccount) -> MTStatus {
        guard let hourly = account.quota?.hourlyRemainingPercent else { return .idle }
        if hourly > 30 { return .ok }
        if hourly > 5 { return .warn }
        return .error
    }

    // MARK: - Actions

    private func launch() {
        guard !launching else { return }
        launching = true
        Task {
            defer { launching = false }
            await gateway.launchCodexApp()
        }
    }

    private func removeRoute() {
        Task {
            let changed = gateway.disableCodexRoute()
            if changed {
                ComposerBridge.shared.launchOrActivateCodex(forceRestart: true)
            }
        }
    }

    private func noteLine(_ text: String, color: Color, icon: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: MTTheme.s2) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
            Text(text)
                .font(MTTheme.mono(10))
                .foregroundStyle(MTTheme.textPrimary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}
