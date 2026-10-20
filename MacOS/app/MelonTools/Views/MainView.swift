import AppKit
import SwiftUI

enum MTSection: String, CaseIterable, Identifiable {
    case dashboard, scheduler, codexAccounts, codexAPI, providers, codexComposer, codexInstances, settings, donate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return L("Dashboard")
        case .scheduler: return L("Scheduler")
        case .codexAccounts: return L("Accounts")
        case .codexAPI: return L("Codex API")
        case .providers: return L("Providers")
        case .codexComposer: return L("Composer Chips")
        case .codexInstances: return L("Instances")
        case .settings: return L("Settings")
        case .donate: return L("Donate")
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .scheduler: return "clock.badge.checkmark"
        case .codexAccounts: return "person.2"
        case .codexAPI: return "network"
        case .providers: return "square.stack.3d.up"
        case .codexComposer: return "capsule"
        case .codexInstances: return "square.on.square"
        case .settings: return "gear"
        case .donate: return "heart.circle.fill"
        }
    }

    struct Group {
        let title: String
        let sections: [MTSection]
    }

    static let groups: [Group] = [
        Group(title: L("Overview"), sections: [.dashboard]),
        Group(title: L("Scheduler"), sections: [.scheduler]),
        Group(title: L("Codex"), sections: [.codexAccounts, .codexAPI, .providers, .codexComposer, .codexInstances]),
        Group(title: L("App"), sections: [.settings, .donate]),
    ]
}

/// Bento layout: one solid card on the left (navigation), a card board on the right.
struct MainView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var updater = UpdaterStore.shared
    @State private var selection: MTSection = .dashboard
    /// First-run guide: shown once, then never again on this account.
    @AppStorage("onboardingDone") private var onboardingDone = false

    private static let sidebarWidth: CGFloat = 228

    var body: some View {
        HStack(spacing: 0) {
            sidebarBoard
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(MTTheme.background)
        .onAppear {
            app.applyAppearance()
            Task { await updater.check(manual: false) }
        }
        .onChange(of: app.appearance) { app.applyAppearance() }
        .sheet(isPresented: $updater.sheetPresented) {
            UpdateSheet()
        }
        .sheet(isPresented: onboardingPresented) {
            OnboardingView(selection: $selection)
        }
        .overlay {
            // Cmd-1…9 jump to the first nine sidebar sections (the display
            // order of MTSection).
            ForEach(Array(MTSection.allCases.prefix(9).enumerated()), id: \.offset) { index, section in
                Button("") { selection = section }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    /// The sheet is visible only while the defaults key is unset; dismissing
    /// it (or picking a destination) writes the key once.
    private var onboardingPresented: Binding<Bool> {
        Binding(
            get: { !onboardingDone },
            set: { presented in
                if !presented { onboardingDone = true }
            }
        )
    }

    /// Sidebar update control, almost full width: a quiet «Проверить
    /// обновление» while up to date, and a gold CTA «Обновить» the moment a
    /// newer release is known (the daily check flips it automatically).
    private var updateRow: some View {
        Button {
            updater.sheetPresented = true
            Task { await updater.check(manual: true) }
        } label: {
            Text(isUpdateAvailable ? L("Update") : L("Check for updates"))
                .font(MTTheme.body(12, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .foregroundStyle(isUpdateAvailable ? MTTheme.onGold : MTTheme.textPrimary)
                .background(
                    RoundedRectangle(cornerRadius: MTTheme.rSmall, style: .continuous)
                        .fill(isUpdateAvailable ? MTTheme.gold : MTTheme.cardSoft.opacity(0.65))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: MTTheme.rSmall, style: .continuous)
                        .strokeBorder(
                            isUpdateAvailable ? Color.clear : MTTheme.borderColor.opacity(0.7),
                            lineWidth: 0.75
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: MTTheme.rSmall, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, MTTheme.s3)
        .padding(.top, MTTheme.s2)
        .padding(.bottom, MTTheme.s1)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(MTTheme.borderColor.opacity(0.35))
                .frame(height: 0.75)
        }
    }

    private var isUpdateAvailable: Bool {
        if case .available = updater.phase { return true }
        return false
    }

    // MARK: - Sidebar card

    private var sidebarBoard: some View {
        VStack(alignment: .leading, spacing: 0) {
            brandHeader
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: MTTheme.s4) {
                    ForEach(MTSection.groups, id: \.title) { group in
                        VStack(alignment: .leading, spacing: MTTheme.s1) {
                            Text(group.title)
                                .font(MTTheme.mono(9, weight: .semibold))
                                .textCase(.uppercase)
                                .tracking(1.1)
                                .foregroundStyle(MTTheme.textTertiary)
                                .padding(.horizontal, MTTheme.s3)
                            ForEach(group.sections) { section in
                                NavRow(section: section, isSelected: selection == section) { picked in
                                    selection = picked
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, MTTheme.s2)
                .padding(.vertical, MTTheme.s3)
            }
            Spacer(minLength: 0)
            updateRow
            GatewayFooter()
        }
        .frame(width: Self.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(MTTheme.cardBackground, in: RoundedRectangle(cornerRadius: MTTheme.rCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MTTheme.rCard, style: .continuous)
                .strokeBorder(MTTheme.borderColor.opacity(0.7), lineWidth: 0.75)
        )
        .padding(.leading, MTTheme.s3)
        .padding(.vertical, MTTheme.s3)
        .padding(.trailing, MTTheme.s2)
    }

    private var brandHeader: some View {
        HStack(spacing: MTTheme.s2) {
            Image(nsImage: MelonAssets.logo)
                .resizable()
                .interpolation(.high)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text("Melon Tools")
                    .font(MTTheme.body(13, weight: .bold))
                    .foregroundStyle(MTTheme.textPrimary)
                Text(L("scheduler + codex"))
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, MTTheme.s3)
        .padding(.top, MTTheme.s3)
        .padding(.bottom, MTTheme.s3)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(MTTheme.borderColor.opacity(0.55))
                .frame(height: 0.75)
        }
    }

    /// A sidebar row with its own hover state: hover stays local, so moving
    /// the pointer over the sidebar re-renders just the row instead of the
    /// whole main layout (sidebar + active detail page body).
    private struct NavRow: View {
        let section: MTSection
        let isSelected: Bool
        let select: (MTSection) -> Void
        @State private var hovered = false

        var body: some View {
            Button {
                select(section)
            } label: {
                HStack(spacing: MTTheme.s3) {
                    Image(systemName: section.systemImage)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 18, alignment: .center)
                    Text(section.title)
                        .font(MTTheme.body(12.5, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(isSelected ? MTTheme.onGold : MTTheme.textPrimary)
                .padding(.horizontal, MTTheme.s3)
                .padding(.vertical, 6.5)
                .background(
                    RoundedRectangle(cornerRadius: MTTheme.rSmall, style: .continuous)
                        .fill(isSelected ? MTTheme.gold : (hovered ? MTTheme.cardSoft.opacity(0.7) : Color.clear))
                )
                .contentShape(RoundedRectangle(cornerRadius: MTTheme.rSmall, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
        }
    }

/// Sidebar footer: the only place that needs the gateway live status. Kept as
/// a separate view so gateway traffic cannot invalidate the whole main layout
/// (sidebar + active detail page) on every log line.
private struct GatewayFooter: View {
    @ObservedObject private var gateway = CodexGatewayService.shared

    var body: some View {
        HStack(spacing: MTTheme.s2) {
            Circle()
                .fill(gateway.status.color)
                .frame(width: 6, height: 6)
            Text(gateway.status.label)
                .font(MTTheme.mono(9))
                .foregroundStyle(MTTheme.textSecondary)
            Spacer(minLength: 0)
            Text(MainView.appVersion)
                .font(MTTheme.mono(9))
                .foregroundStyle(MTTheme.textTertiary)
        }
        .padding(.horizontal, MTTheme.s3)
        .padding(.vertical, MTTheme.s2)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(MTTheme.borderColor.opacity(0.55))
                .frame(height: 0.75)
        }
    }
}

    static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "—"
    }

    // MARK: - Detail board

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .dashboard: DashboardView(selection: $selection)
        case .scheduler: SchedulerView()
        case .codexAccounts: CodexAccountsView(selection: $selection)
        case .codexAPI: CodexAPIView()
        case .providers: CodexProvidersView(selection: $selection)
        case .codexComposer: CodexComposerView()
        case .codexInstances: CodexInstancesView()
        case .settings: SettingsView()
        case .donate: DonateView()
        }
    }
}

private extension CodexGatewayService.Status {
    var color: Color {
        switch self {
        case .running: return MTTheme.ok
        case .starting: return MTTheme.gold
        case .stopped: return MTTheme.textTertiary
        case .failed: return MTTheme.danger
        }
    }
}
