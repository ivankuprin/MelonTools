import SwiftUI

/// Codex composer chips: live pool chips injected into the Codex app.
struct CodexComposerView: View {
    @ObservedObject private var bridge = ComposerBridge.shared
    @ObservedObject private var store = CodexStore.shared
    @State private var confirmRelaunch = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MTTheme.s5) {
                MTPageHeader(
                    kicker: "codex composer",
                    title: L("Composer Chips"),
                    subtitle: L("Composer chips subtitle")
                )

                toggleCard
                statusCard
                helpCard
            }
            .padding(MTTheme.s5)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(MTTheme.background)
        .onAppear {
            store.load()
            if bridge.enabled { bridge.start() }
        }
        .confirmationDialog(L("Quit and relaunch the Codex app?"), isPresented: $confirmRelaunch) {
            Button(L("Quit and relaunch")) { bridge.relaunchCodexWithDebugPort() }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("The Codex app will quit and reopen — the chips connect right after. Unsaved input may be lost."))
        }
    }

    // MARK: - Cards

    private var toggleCard: some View {
        MTCard(title: L("Composer chips"), systemImage: "capsule") {
            Toggle(isOn: $bridge.enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Show pool chips in the Codex composer"))
                        .font(MTTheme.body(13, weight: .medium))
                        .foregroundStyle(MTTheme.textPrimary)
                    Text(L("Accounts, 5-hour and weekly quota chips in the Codex app input bar."))
                        .font(MTTheme.body(11))
                        .foregroundStyle(MTTheme.textSecondary)
                }
            }
            .toggleStyle(.switch)
            .tint(MTTheme.gold)
        }
    }

    private var statusCard: some View {
        MTCard(title: L("Status"), systemImage: "dot.radiowaves.left.and.right") {
            VStack(alignment: .leading, spacing: MTTheme.s2) {
                HStack(spacing: MTTheme.s2) {
                    MTStatusDot(status: statusTint, size: 8)
                    Text(statusTitle)
                        .font(MTTheme.body(13, weight: .semibold))
                        .foregroundStyle(MTTheme.textPrimary)
                    Spacer()
                }

                HStack(spacing: MTTheme.s2) {
                    MTSecondaryButton(title: L("Check now"), systemImage: "arrow.clockwise", isLoading: bridge.busy) {
                        bridge.verifyNow()
                    }
                    if bridge.status == .codexNotRunning || bridge.status == .noDebugPort {
                        MTSecondaryButton(title: L("Relaunch Codex with chips"), systemImage: "arrow.triangle.2.circlepath") {
                            confirmRelaunch = true
                        }
                    }
                }
                .padding(.top, MTTheme.s1)
            }
        }
    }

    private var helpCard: some View {
        MTCard(title: L("How it works"), systemImage: "questionmark.circle") {
            VStack(alignment: .leading, spacing: MTTheme.s2) {
                Text(L("Melon Tools shows live pool chips right inside the Codex window: accounts, 5-hour and weekly quota, and account health."))
                    .font(MTTheme.body(12))
                    .foregroundStyle(MTTheme.textSecondary)
                Text(L("Data comes from Melon Tools on this Mac. When Melon Tools is not running, the chips dim and keep the last values."))
                    .font(MTTheme.body(12))
                    .foregroundStyle(MTTheme.textSecondary)
                Text(L("Click the Accounts chip to see the details. If the chips are missing, relaunch the Codex app with the button above."))
                    .font(MTTheme.body(12))
                    .foregroundStyle(MTTheme.textSecondary)
            }
        }
    }

    // MARK: - Status mapping

    private var statusTitle: String {
        switch bridge.status {
        case .off: return L("Disabled")
        case .codexNotRunning: return L("Codex app is not running")
        case .noDebugPort: return L("The Codex app needs a relaunch to show the chips.")
        case .connecting: return L("Looking for the Codex app…")
        case .connected: return L("Connected to the Codex app")
        case .failed: return L("Could not connect to the Codex app.")
        }
    }

    private var statusTint: MTStatus {
        switch bridge.status {
        case .off: return .idle
        case .connected: return .ok
        case .connecting: return .running
        case .codexNotRunning, .noDebugPort, .failed: return .warn
        }
    }

}
