import AppKit
import SwiftUI

@main
struct MelonToolsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var l10n = L10n.shared

    var body: some Scene {
        Window("Melon Tools", id: "main") {
            MainView()
                .environmentObject(appState)
                .frame(minWidth: 1060, minHeight: 680)
                .id(l10n.code) // full re-render on language switch
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))

        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
                .id(l10n.code)
        } label: {
            Image(nsImage: MelonAssets.menuBarLogo)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .id(l10n.code)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Re-checks for updates while the app runs. The launch check stays in
    /// MainView; this timer only wakes the same throttled code path.
    private var updateTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            ModelSourcesStore.shared.syncCatalogIfNeeded()
            CodexStore.shared.load()
            CodexStore.shared.startQuotaScheduler()
            SchedulerStore.shared.start()
            ComposerBridge.shared.start()
            startUpdateTimer()
            let autoStart = UserDefaults.standard.object(forKey: "gatewayAutoStart") as? Bool ?? true
            Task { @MainActor in
                // The Go split must be known before the gateway writes its
                // config: Go models route through the /go endpoints.
                await ModelSourcesStore.shared.refreshOpenCodeGoAccess()
                if autoStart {
                    await CodexGatewayService.shared.start(accounts: CodexStore.shared.accounts, priorities: CodexStore.shared.effectivePriorities())
                }
            }
        }
    }

    /// Fires every six hours; `check(manual: false)` is a no-op until 24 hours
    /// have passed since the last successful check, so the effective cadence
    /// stays daily. Invalidated with the application lifetime.
    private func startUpdateTimer() {
        updateTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: UpdaterStore.periodicCheckInterval, repeats: true) { _ in
            Task { @MainActor in
                await UpdaterStore.shared.check(manual: false)
            }
        }
        timer.tolerance = 60
        updateTimer = timer
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            updateTimer?.invalidate()
            updateTimer = nil
            ComposerBridge.shared.shutdownForQuit()
            if UserDefaults.standard.bool(forKey: "gatewayStopOnQuit") {
                CodexGatewayService.shared.stopSync()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // keep living in the menu bar
    }
}
