import SwiftUI

/// In-app update window: what's new plus «Отмена» / «Обновить».
struct UpdateSheet: View {
    @ObservedObject private var updater = UpdaterStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: MTTheme.s4) {
            HStack(spacing: MTTheme.s2) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(MTTheme.gold)
                Text(title)
                    .font(MTTheme.body(15, weight: .bold))
                    .foregroundStyle(MTTheme.textPrimary)
                Spacer(minLength: 0)
            }

            content

            HStack(spacing: MTTheme.s2) {
                Spacer(minLength: 0)
                MTSecondaryButton(title: L("Cancel")) { dismiss() }
                if case .available = updater.phase {
                    MTPrimaryButton(title: L("Update"), systemImage: "arrow.down.circle.fill") {
                        Task { await updater.install() }
                    }
                }
                if case .failed = updater.phase {
                    MTPrimaryButton(title: L("Try again"), systemImage: "arrow.clockwise") {
                        Task { await updater.check(manual: true) }
                    }
                }
            }
        }
        .padding(MTTheme.s5)
        .frame(width: 480)
        .background(MTTheme.background)
    }

    private var title: String {
        switch updater.phase {
        case .available(let version, _):
            return String(format: L("Update %@ is available"), version)
        case .upToDate(let version):
            return String(format: L("You are up to date (%@)"), version)
        case .failed:
            return L("Could not check for updates")
        default:
            return L("Checking for updates…")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch updater.phase {
        case .available(let version, let notes):
            Text(String(format: L("Current version %@ → %@"), updater.currentVersion, version))
                .font(MTTheme.mono(10))
                .foregroundStyle(MTTheme.textSecondary)
            ScrollView {
                Text(notes)
                    .font(MTTheme.body(12))
                    .foregroundStyle(MTTheme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
        case .upToDate(let version):
            Text(String(format: L("Melon Tools %@ is the latest version."), version))
                .font(MTTheme.body(12))
                .foregroundStyle(MTTheme.textSecondary)
        case .failed(let message):
            Text(message)
                .font(MTTheme.body(12))
                .foregroundStyle(MTTheme.danger)
                .fixedSize(horizontal: false, vertical: true)
        case .working(let text):
            HStack(spacing: MTTheme.s2) {
                ProgressView().controlSize(.small)
                Text(text)
                    .font(MTTheme.body(12))
                    .foregroundStyle(MTTheme.textSecondary)
            }
        case .idle, .checking:
            HStack(spacing: MTTheme.s2) {
                ProgressView().controlSize(.small)
                Text(L("Checking for updates…"))
                    .font(MTTheme.body(12))
                    .foregroundStyle(MTTheme.textSecondary)
            }
        }
    }
}
