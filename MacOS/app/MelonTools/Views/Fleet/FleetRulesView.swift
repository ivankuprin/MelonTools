import AppKit
import SwiftUI

/// Install Fleet operating rules into a project (agents, skills, guard hook).
struct FleetRulesView: View {
    @ObservedObject private var store = FleetStore.shared
    @State private var projectDir: String = NSHomeDirectory()
    @State private var withAgents = true
    @State private var withHooks = true
    @State private var dryRun = true
    @State private var output: [(line: String, isErr: Bool)] = []
    @State private var isRunning = false
    @State private var exitCode: Int32?
    @State private var confirmInstall = false
    @State private var streamHandle: ShellService.StreamHandle?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MTTheme.s5) {
                MTPageHeader(
                    kicker: "project rules",
                    title: L("Project Rules"),
                    subtitle: L("Rules subtitle")
                )

                MTCard(title: L("Target project"), systemImage: "folder") {
                    VStack(alignment: .leading, spacing: MTTheme.s3) {
                        HStack(spacing: MTTheme.s2) {
                            Text(projectDir)
                                .font(MTTheme.mono(11))
                                .foregroundStyle(MTTheme.textPrimary)
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            MTSecondaryButton(title: L("Choose…")) {
                                chooseDirectory()
                            }
                            Spacer()
                        }

                        HStack(spacing: MTTheme.s4) {
                            Toggle(L("agents + skills"), isOn: $withAgents)
                                .toggleStyle(.checkbox)
                                .font(MTTheme.mono(11))
                            Toggle(L("guard hook"), isOn: $withHooks)
                                .toggleStyle(.checkbox)
                                .font(MTTheme.mono(11))
                            Toggle(L("dry run"), isOn: $dryRun)
                                .toggleStyle(.checkbox)
                                .font(MTTheme.mono(11))
                        }

                        HStack(spacing: MTTheme.s3) {
                            MTPrimaryButton(
                                title: dryRun ? L("Preview (dry-run)") : L("Install rules"),
                                systemImage: dryRun ? "eye" : "text.badge.checkmark",
                                isLoading: isRunning
                            ) {
                                // A real install writes files into the target
                                // project — confirm first; dry-run is safe.
                                if dryRun {
                                    run()
                                } else {
                                    confirmInstall = true
                                }
                            }
                            if isRunning {
                                MTSecondaryButton(title: L("Cancel"), systemImage: "stop.fill") {
                                    streamHandle?.cancel()
                                }
                            }
                            if let exitCode {
                                MTStatusPill(
                                    text: exitCode == 0 ? L("Done") : String(format: L("Failed (%d)"), Int(exitCode)),
                                    status: exitCode == 0 ? .ok : .error
                                )
                            }
                        }

                        Text(L("What it writes: project rules for Fleet (agents, skills, guard hook). Existing files without the fleet's version marker are refused unless forced."))
                            .font(MTTheme.mono(10))
                            .foregroundStyle(MTTheme.textSecondary)
                    }
                }

                MTCard(title: L("Output"), systemImage: "terminal") {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            if output.isEmpty {
                                Text(L("No output yet."))
                                    .font(MTTheme.mono(10))
                                    .foregroundStyle(MTTheme.textSecondary)
                            }
                            ForEach(Array(output.enumerated()), id: \.offset) { _, item in
                                Text(item.line)
                                    .font(MTTheme.mono(10))
                                    .foregroundStyle(item.isErr ? MTTheme.danger : MTTheme.textPrimary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(MTTheme.s3)
                    }
                    .frame(minHeight: 200, maxHeight: 420)
                    .background(MTTheme.background)
                    .clipShape(RoundedRectangle(cornerRadius: MTTheme.rSmall))
                    .overlay(RoundedRectangle(cornerRadius: MTTheme.rSmall).strokeBorder(MTTheme.borderColor))
                }
            }
            .padding(MTTheme.s5)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(MTTheme.background)
        .onAppear { store.start() }
        .confirmationDialog(
            L("Write rules into this project?"),
            isPresented: $confirmInstall,
            titleVisibility: .visible
        ) {
            Button(L("Install rules"), role: .destructive) { run() }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(projectDir)
        }
    }

    private func appendLine(_ line: String, isErr: Bool) {
        output.append((line, isErr))
        if output.count > 1000 {
            output.removeFirst(output.count - 1000)
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: projectDir)
        if panel.runModal() == .OK, let url = panel.url {
            projectDir = url.path
        }
    }

    private func run() {
        var args = ["rules"]
        if withAgents { args.append("--agents") }
        if withHooks { args.append("--hooks") }
        if dryRun { args.append("--dry-run") }

        output = [(line: "→ \(dryRun ? L("Preview (dry-run)") : L("Install rules"))", isErr: false)]
        exitCode = nil
        isRunning = true

        Task {
            do {
                let handle = try FleetCLI.shared.startStream(
                    args,
                    cwd: projectDir,
                    onExit: { code in
                        exitCode = code
                        isRunning = false
                        streamHandle = nil
                    },
                    onStdout: { line in appendLine(line, isErr: false) },
                    onStderr: { line in appendLine(line, isErr: true) }
                )
                streamHandle = handle
            } catch {
                appendLine(error.localizedDescription, isErr: true)
                exitCode = -1
                isRunning = false
            }
        }
    }
}
