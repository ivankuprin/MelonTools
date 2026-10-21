import AppKit
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var l10n = L10n.shared

    @AppStorage("gatewayAutoStart") private var gatewayAutoStart = true
    @AppStorage("gatewayStopOnQuit") private var gatewayStopOnQuit = false
    @AppStorage("quotaRefreshInterval") private var quotaRefreshInterval = 300
    @AppStorage("quotaNotifications") private var quotaNotifications = false
    @AppStorage("taskNotifications") private var taskNotifications = true
    @AppStorage(DashboardWidgetKey.poolHealth) private var showPoolHealth = true
    @AppStorage(DashboardWidgetKey.quotaTrends) private var showQuotaTrends = true
    @AppStorage(DashboardWidgetKey.spend) private var showSpend = true
    @AppStorage(DashboardWidgetKey.scheduler) private var showScheduler = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    @State private var backupPassword = ""
    @State private var backupNotice: String?
    @State private var backupNoticeIsError = false
    @State private var backupRefresh = 0
    @State private var pendingImportURL: URL?

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

                MTCard(title: L("Dashboard widgets"), systemImage: "square.grid.2x2") {
                    VStack(alignment: .leading, spacing: MTTheme.s2) {
                        Toggle(L("Show pool health"), isOn: $showPoolHealth)
                            .toggleStyle(.switch)
                            .font(MTTheme.body(12))
                        Toggle(L("Show quota trends"), isOn: $showQuotaTrends)
                            .toggleStyle(.switch)
                            .font(MTTheme.body(12))
                        Toggle(L("Show spend & top providers"), isOn: $showSpend)
                            .toggleStyle(.switch)
                            .font(MTTheme.body(12))
                        Toggle(L("Show scheduler summary"), isOn: $showScheduler)
                            .toggleStyle(.switch)
                            .font(MTTheme.body(12))
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
                        Toggle(L("Notifications after scheduled runs"), isOn: $taskNotifications)
                            .toggleStyle(.switch)
                            .font(MTTheme.body(12))
                        Toggle(L("Launch at login"), isOn: $launchAtLogin)
                            .toggleStyle(.switch)
                            .font(MTTheme.body(12))
                            .onChange(of: launchAtLogin) { setLaunchAtLogin(launchAtLogin) }
                    }
                }

                MTCard(title: L("Backup"), systemImage: "externaldrive.badge.timemachine") {
                    VStack(alignment: .leading, spacing: MTTheme.s3) {
                        Text(L("Encrypted backup of the scheduler, settings, accounts with auth files and model sources. Logs and gateway keys are not included."))
                            .font(MTTheme.mono(10))
                            .foregroundStyle(MTTheme.textSecondary)
                        HStack(spacing: MTTheme.s3) {
                            Text(L("Backup password"))
                                .font(MTTheme.mono(11))
                                .foregroundStyle(MTTheme.textSecondary)
                                .frame(width: 130, alignment: .leading)
                            SecureField(L("Password"), text: $backupPassword)
                                .textFieldStyle(.roundedBorder)
                                .font(MTTheme.mono(11))
                                .frame(width: 240)
                        }
                        HStack(spacing: MTTheme.s2) {
                            MTPrimaryButton(title: L("Export backup…"), systemImage: "square.and.arrow.up") {
                                exportBackup()
                            }
                            MTSecondaryButton(title: L("Import backup…"), systemImage: "square.and.arrow.down") {
                                chooseBackupToImport()
                            }
                        }
                        Text(lastBackupText)
                            .font(MTTheme.mono(10))
                            .foregroundStyle(MTTheme.textTertiary)
                        if let backupNotice {
                            Text(backupNotice)
                                .font(MTTheme.mono(10))
                                .foregroundStyle(backupNoticeIsError ? MTTheme.danger : MTTheme.ok)
                        }
                    }
                }
                .onAppear { backupRefresh += 1 }
                .alert(
                    L("Restore backup?"),
                    isPresented: Binding(
                        get: { pendingImportURL != nil },
                        set: { if !$0 { pendingImportURL = nil } }
                    ),
                    presenting: pendingImportURL
                ) { url in
                    Button(L("Import"), role: .destructive) {
                        pendingImportURL = nil
                        importBackup(from: url)
                    }
                    Button(L("Cancel"), role: .cancel) {
                        pendingImportURL = nil
                    }
                } message: { url in
                    Text(String(format: L("The live scheduler, settings, accounts and auth files will be replaced by “%@”."), url.lastPathComponent))
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
                            Text(L("A personal console for the Scheduler and the Codex account pool."))
                                .font(MTTheme.mono(10))
                                .foregroundStyle(MTTheme.textSecondary)
                        }
                    }
                }
            }
            .padding(MTTheme.s5)
            .frame(maxWidth: 840, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        .mtScrollMemory("scroll.settings")
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

    // MARK: - Backup

    /// Last export time. Reading `backupRefresh` ties the value to a state
    /// the card bumps after every export/import and on appear, so the date
    /// re-renders without a store.
    private var lastBackupText: String {
        _ = backupRefresh
        guard let date = BackupService.lastBackupAt else { return L("No backup yet") }
        return String(format: L("Last backup: %@"), date.formatted(date: .abbreviated, time: .shortened))
    }

    private func exportBackup() {
        let password = backupPassword
        guard !password.isEmpty else {
            backupNoticeIsError = true
            backupNotice = L("Enter a backup password.")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.data, .json]
        panel.nameFieldStringValue = "MelonTools-backup-\(Self.backupDateFormatter.string(from: Date())).melon"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // The panel may append its own allowed extension to the ".melon"
        // default; keep the melon suffix unless the user picked another one.
        let destination = url.pathExtension.lowercased() == "melon"
            ? url
            : url.deletingPathExtension().appendingPathExtension("melon")
        do {
            let summary = try BackupService.export(to: destination, password: password)
            backupNoticeIsError = false
            backupNotice = L("Backup exported") + " — " + Self.backupSummaryText(summary)
            backupRefresh += 1
        } catch {
            backupNoticeIsError = true
            backupNotice = L("Backup export failed") + ": \(error.localizedDescription)"
        }
    }

    private func chooseBackupToImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingImportURL = url
    }

    private func importBackup(from url: URL) {
        let password = backupPassword
        guard !password.isEmpty else {
            backupNoticeIsError = true
            backupNotice = L("Enter a backup password.")
            return
        }
        do {
            let summary = try BackupService.`import`(from: url, password: password)
            backupNoticeIsError = false
            backupNotice = L("Backup imported") + " — " + Self.backupSummaryText(summary)
            backupRefresh += 1
            Task { await BackupService.reloadAfterRestore() }
        } catch {
            backupNoticeIsError = true
            backupNotice = L("Backup import failed") + ": \(error.localizedDescription)"
        }
    }

    private static let backupDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func backupSummaryText(_ summary: BackupSummary) -> String {
        let modelSources = summary.modelSourcesIncluded ? L("included") : L("not included")
        return String(
            format: L("Tasks %d · history %d · accounts %d · auth files %d · model sources %@ · settings %d"),
            summary.schedulerTasks,
            summary.schedulerHistory,
            summary.accounts,
            summary.authFiles,
            modelSources,
            summary.settingsKeys
        )
    }
}

// MARK: - Menu bar panel

/// Menu bar panel: compact pool totals, quick actions and the live service
/// state. Everything is one click away without opening the main window.
struct MenuBarView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.openWindow) private var openWindow

    @ObservedObject private var codex = CodexStore.shared
    @ObservedObject private var gateway = CodexGatewayService.shared
    @ObservedObject private var scheduler = SchedulerStore.shared

    /// One scheduler window for the app lifetime; reopening brings it back.
    private static var schedulerWindow: NSWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: MTTheme.s3) {
            header
            poolTotals
            Divider()
            quickActions
            Divider()
            accountsSection
            Divider()
            serviceRow
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
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(MTTheme.s3)
        .frame(width: 320)
        .onAppear {
            codex.load()
            scheduler.start()
            Task { await gateway.healthCheck() }
        }
    }

    // MARK: - Header and totals

    private var header: some View {
        HStack(spacing: MTTheme.s2) {
            Image(nsImage: MelonAssets.logo)
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)
            Text("Melon Tools")
                .font(MTTheme.body(12, weight: .bold))
            Spacer()
            Button(action: openMainWindow) {
                Image(systemName: "macwindow")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help(L("Open window"))
        }
    }

    private var poolTotals: some View {
        let health = DashboardMetrics.poolHealth(accounts: codex.accounts)
        return HStack(spacing: MTTheme.s3) {
            compactMetric(title: L("5 h"), value: health.hourlyAverage)
            compactMetric(title: L("Week"), value: health.weeklyAverage)
            Spacer()
            Text(String(format: L("Accounts in pool: %d"), codex.accounts.count))
                .font(MTTheme.mono(9))
                .foregroundStyle(MTTheme.textTertiary)
        }
    }

    private func compactMetric(title: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(MTTheme.mono(8, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(MTTheme.textTertiary)
            Text(value.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(MTTheme.mono(13, weight: .semibold))
                .foregroundStyle(value == nil ? MTTheme.textTertiary : MTTheme.textPrimary)
        }
    }

    // MARK: - Quick actions

    private var dueTasks: [SchedulerTask] {
        SchedulerPolicy.due(scheduler.tasks, now: Date())
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: MTTheme.s1) {
            actionRow(icon: "macwindow", title: L("Open Melon Tools")) {
                openMainWindow()
            }
            actionRow(icon: "clock.badge.checkmark", title: L("Scheduler")) {
                openSchedulerWindow()
            }
            actionRow(
                icon: "play.circle",
                title: L("Run next due task") + (dueTasks.isEmpty ? "" : " (\(dueTasks.count))"),
                disabled: dueTasks.isEmpty || !gateway.isRunning || scheduler.isRunning
            ) {
                guard let task = dueTasks.first else { return }
                Task { await scheduler.runNow(id: task.id) }
            }
            actionRow(
                icon: gateway.isRunning ? "pause.circle" : "play.circle",
                title: gateway.isRunning ? L("Pause API") : L("Resume API"),
                disabled: gateway.isStarting
            ) {
                toggleGateway()
            }
            actionRow(icon: "power", title: L("Quit Melon Tools")) {
                NSApp.terminate(nil)
            }
        }
    }

    private func actionRow(
        icon: String,
        title: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .frame(width: 14)
                Text(title)
                    .font(MTTheme.mono(10))
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .foregroundStyle(disabled ? MTTheme.textTertiary : MTTheme.textPrimary)
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openSchedulerWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = Self.schedulerWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let root = SchedulerView().environmentObject(app)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Melon Tools — " + L("Scheduler")
        window.contentView = NSHostingView(rootView: root)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        Self.schedulerWindow = window
    }

    private func toggleGateway() {
        if gateway.isRunning {
            Task { await gateway.stop() }
        } else {
            codex.load()
            Task {
                await gateway.start(
                    accounts: codex.accounts,
                    priorities: codex.effectivePriorities()
                )
            }
        }
    }

    // MARK: - Account preview and service

    private var accountsSection: some View {
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
    }

    private var serviceRow: some View {
        HStack(spacing: MTTheme.s2) {
            Circle()
                .fill(gateway.isRunning ? MTTheme.ok : MTTheme.textTertiary)
                .frame(width: 7, height: 7)
            Text(String(format: L("service %@"), gateway.status.label))
                .font(MTTheme.mono(10))
            Spacer()
            if gateway.isRunning {
                Text(L("running"))
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.ok)
            }
        }
    }
}
