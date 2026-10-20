import SwiftUI

/// Overview: the Codex account pool and the gateway at a glance.
struct DashboardView: View {
    @EnvironmentObject private var app: AppState
    @Binding var selection: MTSection

    @ObservedObject private var codex = CodexStore.shared
    @ObservedObject private var gateway = CodexGatewayService.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MTTheme.s5) {
                MTPageHeader(
                    kicker: "melon tools",
                    title: L("Dashboard"),
                    subtitle: L("Dashboard subtitle")
                )

                codexCard
                gatewayCard
            }
            .padding(MTTheme.s5)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        .mtScrollMemory("scroll.dashboard")
        }
        .background(MTTheme.background)
        .onAppear {
            codex.load()
            Task { await gateway.healthCheck() }
        }
    }

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
                    if let average = averageWeeklyRemaining {
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

    private var averageWeeklyRemaining: Double? {
        let values = codex.accounts.compactMap(\.quota?.weeklyRemainingPercent)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
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
}
