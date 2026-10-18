import SwiftUI

/// Call a unit's MCP tool through the CLI (`call <unit> <tool> [json] --timeout S`),
/// streaming the answer into a console pane.
struct FleetCallView: View {
    @ObservedObject private var store = FleetStore.shared

    @State private var unit: FleetUnit = .codex
    @State private var toolIndex = 0
    @State private var jsonArgs = "{}"
    @State private var timeout = 900
    @State private var output: [(line: String, isErr: Bool)] = []
    @State private var isRunning = false
    @State private var exitCode: Int32? = nil
    @State private var startedAt: Date? = nil
    @State private var streamHandle: ShellService.StreamHandle?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MTTheme.s5) {
                MTPageHeader(
                    kicker: "fleet call",
                    title: L("Call Unit"),
                    subtitle: L("Call subtitle")
                )

                if let reason = store.cliReady ? nil : FleetCLI.shared.unavailabilityReason {
                    MTCard {
                        HStack(spacing: MTTheme.s2) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(MTTheme.warn)
                            Text(reason)
                                .font(MTTheme.mono(11))
                                .foregroundStyle(MTTheme.textPrimary)
                        }
                    }
                }

                formCard
                consoleCard
            }
            .padding(MTTheme.s5)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(MTTheme.background)
        .onAppear {
            store.start()
            jsonArgs = tool.argsHint
        }
    }

    private var tool: (name: String, summary: String, argsHint: String) {
        let tools = unit.tools
        return tools[min(toolIndex, tools.count - 1)]
    }

    private var formCard: some View {
        MTCard(title: L("Invocation"), systemImage: "phone.arrow.up.right") {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                HStack(spacing: MTTheme.s3) {
                    Picker(L("Unit"), selection: $unit) {
                        ForEach(FleetUnit.allCases) { u in
                            Text(u.displayName).tag(u)
                        }
                    }
                    .frame(width: 160)
                    .onChange(of: unit) {
                        toolIndex = 0
                        jsonArgs = tool.argsHint
                    }

                    Picker(L("Tool"), selection: $toolIndex) {
                        ForEach(Array(unit.tools.enumerated()), id: \.offset) { idx, t in
                            Text(t.name).tag(idx)
                        }
                    }
                    .frame(width: 240)
                    .onChange(of: toolIndex) {
                        jsonArgs = tool.argsHint
                    }

                    Spacer()

                    Text(L("timeout"))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                    TextField("900", value: $timeout, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .font(MTTheme.mono(11))
                        .frame(width: 70)
                    Text("s")
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                }

                Text(tool.summary)
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textSecondary)

                VStack(alignment: .leading, spacing: MTTheme.s1) {
                    Text(L("JSON args"))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                    TextEditor(text: $jsonArgs)
                        .font(MTTheme.mono(11))
                        .scrollContentBackground(.hidden)
                        .background(MTTheme.background)
                        .frame(height: 90)
                        .overlay(RoundedRectangle(cornerRadius: MTTheme.rSmall).strokeBorder(MTTheme.borderColor))
                }

                HStack(spacing: MTTheme.s3) {
                    MTPrimaryButton(title: isRunning ? L("Running…") : "\(L("Call")) \(tool.name)", systemImage: "play.fill", isLoading: isRunning) {
                        run()
                    }
                    if isRunning {
                        MTSecondaryButton(title: L("Cancel"), systemImage: "stop.fill") {
                            streamHandle?.cancel()
                        }
                    }
                    if let exitCode {
                        MTStatusPill(
                            text: exitCode == 0 ? L("Done") : exitCode == 2 ? L("Tool error") : String(format: L("Failed (%d)"), Int(exitCode)),
                            status: exitCode == 0 ? .ok : exitCode == 2 ? .warn : .error
                        )
                    }
                    if let startedAt, isRunning {
                        TimelineView(.periodic(from: startedAt, by: 1)) { context in
                            Text(ISODate.duration(Int(context.date.timeIntervalSince(startedAt) * 1000)))
                                .font(MTTheme.mono(10))
                                .foregroundStyle(MTTheme.textSecondary)
                        }
                    }
                    Spacer()
                }
            }
        }
    }

    private var consoleCard: some View {
        MTCard(title: L("Console"), systemImage: "terminal") {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(output.enumerated()), id: \.offset) { idx, item in
                            Text(item.line)
                                .font(MTTheme.mono(10))
                                .foregroundStyle(item.isErr ? MTTheme.danger : MTTheme.textPrimary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(MTTheme.s3)
                }
                .frame(minHeight: 200, maxHeight: 380)
                .background(MTTheme.background)
                .clipShape(RoundedRectangle(cornerRadius: MTTheme.rSmall))
                .overlay(RoundedRectangle(cornerRadius: MTTheme.rSmall).strokeBorder(MTTheme.borderColor))
                .onChange(of: output.count) {
                    if let last = output.indices.last {
                        withAnimation(.linear(duration: 0.1)) {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func appendLine(_ line: String, isErr: Bool) {
        output.append((line, isErr))
        // A chatty CLI must not grow the buffer unbounded.
        if output.count > 1000 {
            output.removeFirst(output.count - 1000)
        }
    }

    private func run() {
        guard store.cliReady else {
            output = [(line: FleetCLI.shared.unavailabilityReason ?? L("Fleet CLI not found. Install Fleet and try again."), isErr: true)]
            return
        }
        output = [(line: "→ \(unit.displayName) · \(tool.name)", isErr: false)]
        exitCode = nil
        isRunning = true
        startedAt = Date()

        // Keep the timeout inside the CLI's sane range.
        let clampedTimeout = min(max(timeout, 1), 3600)
        Task {
            do {
                let handle = try FleetCLI.shared.startStream(
                    ["call", unit.rawValue, tool.name, jsonArgs, "--timeout", String(clampedTimeout)],
                    onExit: { code in
                        exitCode = code
                        isRunning = false
                        startedAt = nil
                        streamHandle = nil
                        Task { await store.refreshResults() }
                    },
                    onStdout: { line in appendLine(line, isErr: false) },
                    onStderr: { line in appendLine(line, isErr: true) }
                )
                streamHandle = handle
            } catch {
                appendLine(error.localizedDescription, isErr: true)
                exitCode = -1
                isRunning = false
                startedAt = nil
            }
        }
    }
}
