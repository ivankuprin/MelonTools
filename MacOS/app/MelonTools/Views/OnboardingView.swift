import SwiftUI

/// First-run onboarding sheet. Shown once, gated by the `onboardingDone`
/// defaults key; every action marks the guide as seen.
struct OnboardingView: View {
    @Binding var selection: MTSection
    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var gateway = CodexGatewayService.shared
    @ObservedObject private var codex = CodexStore.shared
    @ObservedObject private var scheduler = SchedulerStore.shared

    /// Bumped by "Run health check". The rows read live published state, so
    /// the timestamp is the only local state the refresh needs — no probe.
    @State private var healthCheckedAt = Date()
    /// Inline note after "Create demo task" (success or missing-model warning).
    @State private var healthNote: String?

    private struct Step {
        let number: Int
        let title: String
        let detail: String
    }

    private var steps: [Step] {
        [
            Step(
                number: 1,
                title: L("Add a Codex account"),
                detail: L("Sign in through the browser, by device code, or import a saved CLI login. The pool switches accounts when quota runs low.")
            ),
            Step(
                number: 2,
                title: L("Connect providers"),
                detail: L("Claude, Antigravity, OpenRouter and OpenCode models appear in the Codex picker after you select them.")
            ),
            Step(
                number: 3,
                title: L("Start the API service"),
                detail: L("Start the local service, apply the model list, and launch Codex from Melon Tools.")
            ),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MTTheme.s4) {
            header
            // The sheet is fixed at 560 pt wide and the health section makes
            // the content taller than a small screen: the middle scrolls while
            // the header and footer stay pinned.
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: MTTheme.s4) {
                    VStack(alignment: .leading, spacing: MTTheme.s3) {
                        ForEach(steps, id: \.number) { step in
                            stepRow(step)
                        }
                    }
                    disclaimer
                    healthCheck
                }
            }
            .frame(maxHeight: 420)
            footer
        }
        .padding(MTTheme.s6)
        .frame(width: 560)
        .background(MTTheme.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: MTTheme.s2) {
            Text(L("welcome").uppercased())
                .font(MTTheme.mono(10, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(MTTheme.gold)
            Text(L("Welcome to Melon Tools"))
                .font(MTTheme.display(26))
                .foregroundStyle(MTTheme.textPrimary)
            Text(L("A quick setup: accounts, providers, and the local service."))
                .font(MTTheme.body(12))
                .foregroundStyle(MTTheme.textSecondary)
        }
    }

    private func stepRow(_ step: Step) -> some View {
        HStack(alignment: .top, spacing: MTTheme.s3) {
            Text("\(step.number)")
                .font(MTTheme.mono(11, weight: .semibold))
                .foregroundStyle(MTTheme.onGold)
                .frame(width: 22, height: 22)
                .background(Circle().fill(MTTheme.gold))
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(MTTheme.body(13, weight: .semibold))
                    .foregroundStyle(MTTheme.textPrimary)
                Text(step.detail)
                    .font(MTTheme.body(11))
                    .foregroundStyle(MTTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var disclaimer: some View {
        HStack(alignment: .top, spacing: MTTheme.s2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MTTheme.warn)
            Text(L("Use your own accounts only. Third-party clients can conflict with provider terms; accounts may be limited or banned."))
                .font(MTTheme.body(11))
                .foregroundStyle(MTTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(MTTheme.s3)
        .background(
            MTTheme.warn.opacity(0.10),
            in: RoundedRectangle(cornerRadius: MTTheme.rSmall, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MTTheme.rSmall, style: .continuous)
                .strokeBorder(MTTheme.warn.opacity(0.35), lineWidth: 0.75)
        )
    }

    // MARK: - Health check

    private enum Verdict {
        case pass, warn, fail

        var label: String {
            switch self {
            case .pass: return L("PASS")
            case .warn: return L("WARN")
            case .fail: return L("FAIL")
            }
        }

        var status: MTStatus {
            switch self {
            case .pass: return .ok
            case .warn: return .warn
            case .fail: return .error
            }
        }
    }

    private struct HealthRow: Identifiable {
        let id: String
        let verdict: Verdict
        let title: String
        let detail: String
        /// Section the row's small action button opens (nil = no action).
        var section: MTSection? = nil
    }

    private var healthRows: [HealthRow] {
        [gatewayRow, accountsRow, modelsRow, schedulerRow, backupRow]
    }

    private var gatewayRow: HealthRow {
        switch gateway.status {
        case .running(let baseURL):
            return HealthRow(
                id: "gateway",
                verdict: .pass,
                title: L("Local API service"),
                detail: String(format: L("Running on %@"), baseURL),
                section: .codexAPI
            )
        case .starting:
            return HealthRow(
                id: "gateway",
                verdict: .warn,
                title: L("Local API service"),
                detail: L("starting"),
                section: .codexAPI
            )
        case .failed(let reason):
            return HealthRow(
                id: "gateway",
                verdict: .fail,
                title: L("Local API service"),
                detail: reason,
                section: .codexAPI
            )
        case .stopped:
            return HealthRow(
                id: "gateway",
                verdict: .warn,
                title: L("Local API service"),
                detail: L("Not running — start it from the Codex API page."),
                section: .codexAPI
            )
        }
    }

    private var accountsRow: HealthRow {
        let count = codex.accounts.count
        if count > 0 {
            return HealthRow(
                id: "accounts",
                verdict: .pass,
                title: L("Codex account"),
                detail: String(format: L("Accounts in vault: %d"), count),
                section: .codexAccounts
            )
        }
        return HealthRow(
            id: "accounts",
            verdict: .fail,
            title: L("Codex account"),
            detail: L("No accounts — sign in or import a CLI login."),
            section: .codexAccounts
        )
    }

    private var modelsRow: HealthRow {
        let gatewayModels = scheduler.models.count
        if gatewayModels > 0 {
            return HealthRow(
                id: "models",
                verdict: .pass,
                title: L("Model catalog"),
                detail: String(format: L("Gateway model list: %d"), gatewayModels),
                section: .providers
            )
        }
        let selected = ModelSourcesStore.shared.sources
            .filter(\.enabled)
            .reduce(0) { $0 + $1.selectedModels.count }
        if selected > 0 {
            return HealthRow(
                id: "models",
                verdict: .pass,
                title: L("Model catalog"),
                detail: String(format: L("Provider models selected: %d"), selected),
                section: .providers
            )
        }
        return HealthRow(
            id: "models",
            verdict: .fail,
            title: L("Model catalog"),
            detail: L("No models — connect a provider or load the model list."),
            section: .providers
        )
    }

    private var schedulerRow: HealthRow {
        let count = scheduler.tasks.count
        guard count > 0 else {
            return HealthRow(
                id: "scheduler",
                verdict: .warn,
                title: L("Scheduler"),
                detail: L("No scheduled tasks yet."),
                section: .scheduler
            )
        }
        var detail = String(format: L("Tasks: %d"), count)
        if let next = scheduler.tasks.filter(\.enabled).compactMap(\.nextRunAt).min() {
            let when = Date(timeIntervalSince1970: next)
                .formatted(date: .omitted, time: .shortened)
            detail += " · " + L("Next run") + " " + when
        }
        return HealthRow(
            id: "scheduler",
            verdict: .pass,
            title: L("Scheduler"),
            detail: detail,
            section: .scheduler
        )
    }

    private var backupRow: HealthRow {
        if let date = BackupService.lastBackupAt {
            return HealthRow(
                id: "backup",
                verdict: .pass,
                title: L("Backup"),
                detail: String(
                    format: L("Last backup %@"),
                    date.formatted(date: .abbreviated, time: .shortened)
                ),
                section: .settings
            )
        }
        return HealthRow(
            id: "backup",
            verdict: .warn,
            title: L("Backup"),
            detail: L("No backup yet — create one in Settings."),
            section: .settings
        )
    }

    private var healthCheck: some View {
        VStack(alignment: .leading, spacing: MTTheme.s3) {
            HStack(spacing: MTTheme.s2) {
                Image(systemName: "stethoscope")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MTTheme.gold)
                Text(L("Health check"))
                    .font(MTTheme.body(13, weight: .semibold))
                    .foregroundStyle(MTTheme.textPrimary)
                Spacer(minLength: MTTheme.s2)
                Text(String(format: L("Checked %@"), healthCheckedAt.formatted(date: .omitted, time: .shortened)))
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textTertiary)
                MTSecondaryButton(title: L("Run health check"), systemImage: "arrow.clockwise") {
                    healthCheckedAt = Date()
                    healthNote = nil
                }
            }
            VStack(alignment: .leading, spacing: MTTheme.s2) {
                ForEach(healthRows) { row in
                    healthRowView(row)
                }
            }
            HStack(alignment: .top, spacing: MTTheme.s3) {
                MTSecondaryButton(title: L("Create demo task"), systemImage: "plus") {
                    createDemoTask()
                }
                if let healthNote {
                    Text(healthNote)
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(MTTheme.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            MTTheme.cardSoft.opacity(0.5),
            in: RoundedRectangle(cornerRadius: MTTheme.rSmall, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MTTheme.rSmall, style: .continuous)
                .strokeBorder(MTTheme.borderColor.opacity(0.7), lineWidth: 0.75)
        )
    }

    private func healthRowView(_ row: HealthRow) -> some View {
        HStack(alignment: .center, spacing: MTTheme.s3) {
            MTStatusPill(text: row.verdict.label, status: row.verdict.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(MTTheme.body(12, weight: .semibold))
                    .foregroundStyle(MTTheme.textPrimary)
                Text(row.detail)
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let section = row.section {
                MTSecondaryButton(title: L("Open"), systemImage: "arrow.right") {
                    go(to: section)
                }
            }
        }
    }

    /// Adds a disabled demo task on the first available model — the gateway
    /// list first, then any enabled provider model alias. No request is sent;
    /// without a model an inline warning replaces the (invalid) task.
    private func createDemoTask() {
        let model = scheduler.models.first
            ?? ModelSourcesStore.shared.sources
                .filter(\.enabled)
                .flatMap(\.selectedModels)
                .first?
                .alias
        guard let model else {
            healthNote = L("No model is available yet — connect a provider or load the model list first.")
            return
        }
        scheduler.addTask(
            name: L("Demo task"),
            prompt: L("Demo: reply \"pong\" and finish. The task stays disabled until you enable it."),
            model: model,
            reasoningEffort: nil,
            intervalMinutes: 60,
            enabled: false
        )
        healthNote = String(format: L("Demo task added with model %@ (disabled)."), model)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: MTTheme.s2) {
            HStack(spacing: MTTheme.s3) {
                MTSecondaryButton(title: L("Open Providers"), systemImage: "square.stack.3d.up") {
                    go(to: .providers)
                }
                MTSecondaryButton(title: L("Open Accounts"), systemImage: "person.2") {
                    go(to: .codexAccounts)
                }
                Spacer(minLength: MTTheme.s2)
                MTSecondaryButton(title: L("Done")) {
                    dismiss()
                }
            }
            Text(L("This guide appears only once."))
                .font(MTTheme.mono(9))
                .foregroundStyle(MTTheme.textTertiary)
        }
    }

    private func go(to section: MTSection) {
        selection = section
        dismiss()
    }
}
