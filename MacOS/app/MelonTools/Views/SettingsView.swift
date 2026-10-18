import AppKit
import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var l10n = L10n.shared

    @AppStorage("gatewayAutoStart") private var gatewayAutoStart = true
    @AppStorage("gatewayStopOnQuit") private var gatewayStopOnQuit = false
    @AppStorage("quotaRefreshInterval") private var quotaRefreshInterval = 300
    @AppStorage("quotaNotifications") private var quotaNotifications = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MTTheme.s5) {
                MTPageHeader(kicker: "melon tools", title: L("Settings"), subtitle: L("Settings subtitle"))

                MTCard(title: L("Appearance"), systemImage: "paintbrush") {
                    VStack(alignment: .leading, spacing: MTTheme.s3) {
                        HStack(spacing: MTTheme.s3) {
                            Text(L("Theme"))
                                .font(MTTheme.mono(11))
                                .foregroundStyle(MTTheme.textSecondary)
                                .frame(width: 130, alignment: .leading)
                            Picker("", selection: $app.appearance) {
                                ForEach(AppState.Appearance.allCases) { style in
                                    Text(style.title).tag(style)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 280)
                            .onChange(of: app.appearance) { app.applyAppearance() }
                        }
                        HStack(spacing: MTTheme.s3) {
                            Text(L("Language"))
                                .font(MTTheme.mono(11))
                                .foregroundStyle(MTTheme.textSecondary)
                                .frame(width: 130, alignment: .leading)
                            Picker("", selection: $l10n.code) {
                                ForEach(L10n.available, id: \.code) { item in
                                    Text(item.title).tag(item.code)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 280)
                        }
                        HStack(spacing: MTTheme.s3) {
                            Text(L("Accent"))
                                .font(MTTheme.mono(11))
                                .foregroundStyle(MTTheme.textSecondary)
                                .frame(width: 130, alignment: .leading)
                            Circle()
                                .fill(MTTheme.gold)
                                .frame(width: 16, height: 16)
                            Text(L("golden melon"))
                                .font(MTTheme.mono(11))
                                .foregroundStyle(MTTheme.textPrimary)
                        }
                    }
                }

                MTCard(title: L("Service settings"), systemImage: "network") {
                    VStack(alignment: .leading, spacing: MTTheme.s2) {
                        Toggle(L("Start the service at app launch"), isOn: $gatewayAutoStart)
                            .toggleStyle(.switch)
                            .font(MTTheme.body(12))
                        Toggle(L("Stop the service on quit"), isOn: $gatewayStopOnQuit)
                            .toggleStyle(.switch)
                            .font(MTTheme.body(12))
                        Text(L("When “stop on quit” is off, the service keeps running in the background and the app adopts it on the next launch."))
                            .font(MTTheme.mono(10))
                            .foregroundStyle(MTTheme.textSecondary)
                        if let loginItemError {
                            Text(loginItemError)
                                .font(MTTheme.mono(10))
                                .foregroundStyle(MTTheme.danger)
                        }
                    }
                }

                MTCard(title: L("Quotas section"), systemImage: "gauge.with.dots.needle.33percent") {
                    VStack(alignment: .leading, spacing: MTTheme.s3) {
                        HStack(spacing: MTTheme.s3) {
                            Text(L("Auto-refresh"))
                                .font(MTTheme.mono(11))
                                .foregroundStyle(MTTheme.textSecondary)
                                .frame(width: 130, alignment: .leading)
                            Picker("", selection: $quotaRefreshInterval) {
                                Text(L("Off")).tag(0)
                                Text(L("1 min")).tag(60)
                                Text(L("5 min")).tag(300)
                                Text(L("15 min")).tag(900)
                                Text(L("30 min")).tag(1800)
                            }
                            .labelsHidden()
                            .frame(width: 160)
                            .onChange(of: quotaRefreshInterval) {
                                CodexStore.shared.startQuotaScheduler()
                            }
                        }
                        Toggle(L("Notifications when quota is low"), isOn: $quotaNotifications)
                            .toggleStyle(.switch)
                            .font(MTTheme.body(12))
                        Toggle(L("Launch at login"), isOn: $launchAtLogin)
                            .toggleStyle(.switch)
                            .font(MTTheme.body(12))
                            .onChange(of: launchAtLogin) { setLaunchAtLogin(launchAtLogin) }
                    }
                }

                MTCard(title: L("About"), systemImage: "info.circle") {
                    HStack(alignment: .center, spacing: MTTheme.s3) {
                        Image(nsImage: MelonAssets.logo)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: MTTheme.s2) {
                            Text("Melon Tools \(appVersion)")
                                .font(MTTheme.mono(11, weight: .semibold))
                                .foregroundStyle(MTTheme.textPrimary)
                            Text(L("A personal console for Fleet and the Codex account pool."))
                                .font(MTTheme.mono(10))
                                .foregroundStyle(MTTheme.textSecondary)
                        }
                    }
                }
            }
            .padding(MTTheme.s5)
            .frame(maxWidth: 840, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(MTTheme.background)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = L("Launch at login failed") + ": \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Menu bar panel

struct MenuBarView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.openWindow) private var openWindow

    @ObservedObject private var fleet = FleetStore.shared
    @ObservedObject private var codex = CodexStore.shared
    @ObservedObject private var gateway = CodexGatewayService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: MTTheme.s3) {
            HStack(spacing: MTTheme.s2) {
                Image(nsImage: MelonAssets.logo)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 16, height: 16)
                Text("Melon Tools")
                    .font(MTTheme.body(12, weight: .bold))
                Spacer()
                Button {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Image(systemName: "macwindow")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help(L("Open window"))
            }

            Divider()

            VStack(alignment: .leading, spacing: MTTheme.s1) {
                Text(L("Fleet").uppercased())
                    .font(MTTheme.mono(9, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(MTTheme.textSecondary)
                if fleet.snapshots.isEmpty {
                    Text(L("no live units"))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                } else {
                    ForEach(fleet.snapshots.prefix(4)) { snap in
                        HStack(spacing: 6) {
                            MTStatusDot(status: (snap.active?.isEmpty == false) ? .running : .idle, size: 6)
                            Text(snap.unit)
                                .font(MTTheme.mono(10))
                            if let last = snap.lastEvent {
                                Text(last.tool ?? "")
                                    .font(MTTheme.mono(9))
                                    .foregroundStyle(MTTheme.textSecondary)
                            }
                            Spacer()
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: MTTheme.s1) {
                Text(L("Codex").uppercased())
                    .font(MTTheme.mono(9, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(MTTheme.textSecondary)
                if codex.accounts.isEmpty {
                    Text(L("no accounts"))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                } else {
                    ForEach(codex.accounts.prefix(3)) { account in
                        HStack(spacing: 6) {
                            MTQuotaRing(fraction: account.quota?.weeklyRemainingPercent.map { $0 / 100.0 }, size: 20)
                            Text(account.displayName)
                                .font(MTTheme.mono(10))
                                .lineLimit(1)
                            Spacer()
                            if codex.currentAccountId == account.id {
                                Text(L("active"))
                                    .font(MTTheme.mono(8, weight: .semibold))
                                    .foregroundStyle(MTTheme.ok)
                            }
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: MTTheme.s2) {
                Circle()
                    .fill(gateway.isRunning ? MTTheme.ok : MTTheme.textTertiary)
                    .frame(width: 7, height: 7)
                Text(String(format: L("service %@"), gateway.status.label))
                    .font(MTTheme.mono(10))
                Spacer()
                if gateway.isRunning {
                    Button(L("Stop")) {
                        Task { await gateway.stop() }
                    }
                    .font(MTTheme.mono(10))
                    .buttonStyle(.plain)
                } else {
                    Button(L("Start")) {
                        codex.load()
                        Task { await gateway.start(accounts: codex.accounts, priorities: codex.effectivePriorities()) }
                    }
                    .font(MTTheme.mono(10))
                    .buttonStyle(.plain)
                }
            }

            if gateway.isRunning {
                Button {
                    gateway.launchThroughGateway()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 10))
                        Text(L("Launch Codex"))
                            .font(MTTheme.mono(10))
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }

            Divider()

            Button(L("Quit Melon Tools")) {
                NSApp.terminate(nil)
            }
            .font(MTTheme.mono(10))
            .buttonStyle(.plain)
        }
        .padding(MTTheme.s3)
        .frame(width: 300)
        .onAppear {
            fleet.start()
            codex.load()
            Task { await gateway.healthCheck() }
        }
    }
}
