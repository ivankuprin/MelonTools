import SwiftUI

/// First-run onboarding sheet. Shown once, gated by the `onboardingDone`
/// defaults key; every action marks the guide as seen.
struct OnboardingView: View {
    @Binding var selection: MTSection
    @Environment(\.dismiss) private var dismiss

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
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                ForEach(steps, id: \.number) { step in
                    stepRow(step)
                }
            }
            disclaimer
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
