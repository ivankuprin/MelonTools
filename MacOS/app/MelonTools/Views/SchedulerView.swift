import AppKit
import SwiftUI

/// Scheduler page: task list (name, model, interval, status, next run), enable
/// toggle, run-now, add/edit sheet, delete confirmation and a bounded result
/// viewer. The scheduler runs only while the app process is alive.
struct SchedulerView: View {
    @ObservedObject private var store = SchedulerStore.shared
    @ObservedObject private var gateway = CodexGatewayService.shared

    @State private var editorTarget: EditorTarget?
    @State private var resultTarget: SchedulerTask?
    @State private var deleteTarget: SchedulerTask?

    private struct EditorTarget: Identifiable {
        let id = UUID()
        let task: SchedulerTask?
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MTTheme.s5) {
                MTPageHeader(
                    kicker: "melon tools",
                    title: L("Scheduler"),
                    subtitle: L("Scheduler subtitle")
                )

                if !gateway.isRunning {
                    MTCard(title: L("Service"), systemImage: "network") {
                        HStack(spacing: MTTheme.s2) {
                            MTStatusPill(text: L("stopped"), status: .absent)
                            Text(L("Scheduled runs wait until the service is running."))
                                .font(MTTheme.mono(10))
                                .foregroundStyle(MTTheme.textSecondary)
                            Spacer()
                        }
                    }
                }

                if let error = store.persistenceError {
                    Text(error)
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.danger)
                }

                tasksCard

                if !store.history.isEmpty {
                    historyCard
                }
            }
            .padding(MTTheme.s5)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .mtScrollMemory("scroll.scheduler")
        }
        .background(MTTheme.background)
        .onAppear {
            store.start()
            Task { await store.loadModelsIfNeeded() }
        }
        .sheet(item: $editorTarget) { target in
            SchedulerEditorSheet(task: target.task)
        }
        .sheet(item: $resultTarget) { task in
            SchedulerResultSheet(taskID: task.id)
        }
        .alert(
            L("Delete task?"),
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            presenting: deleteTarget
        ) { task in
            Button(L("Delete"), role: .destructive) {
                store.deleteTask(id: task.id)
                deleteTarget = nil
            }
            Button(L("Cancel"), role: .cancel) {
                deleteTarget = nil
            }
        } message: { task in
            Text(String(format: L("“%@” and its history will be removed."), task.name))
        }
    }

    // MARK: - Tasks

    private var tasksCard: some View {
        MTCard(title: L("Tasks"), systemImage: "clock.badge.checkmark") {
            VStack(alignment: .leading, spacing: MTTheme.s2) {
                if store.tasks.isEmpty {
                    VStack(alignment: .leading, spacing: MTTheme.s1) {
                        Text(L("No scheduled tasks yet."))
                            .font(MTTheme.body(12, weight: .medium))
                            .foregroundStyle(MTTheme.textPrimary)
                        Text(L("Create a task to run a prompt on a schedule."))
                            .font(MTTheme.mono(10))
                            .foregroundStyle(MTTheme.textSecondary)
                    }
                    .padding(.vertical, MTTheme.s2)
                } else {
                    ForEach(store.tasks) { task in
                        taskRow(task)
                        if task.id != store.tasks.last?.id {
                            Divider().overlay(MTTheme.borderColor.opacity(0.6))
                        }
                    }
                }

                HStack(spacing: MTTheme.s2) {
                    Text(String(format: L("%d tasks"), store.tasks.count))
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.textSecondary)
                    Spacer()
                    MTSecondaryButton(title: L("New task"), systemImage: "plus") {
                        editorTarget = EditorTarget(task: nil)
                    }
                }
                .padding(.top, MTTheme.s1)
            }
        }
    }

    private func taskRow(_ task: SchedulerTask) -> some View {
        let isRunning = store.runningTaskID == task.id
        let status: MTStatus = isRunning ? .running : task.lastStatus.mtStatus
        return VStack(alignment: .leading, spacing: MTTheme.s2) {
            HStack(spacing: MTTheme.s2) {
                MTStatusDot(status: status, size: 7)
                Text(task.name)
                    .font(MTTheme.body(12.5, weight: .semibold))
                    .foregroundStyle(MTTheme.textPrimary)
                    .lineLimit(1)
                MTStatusPill(text: isRunning ? L("running") : task.lastStatus.title, status: status)
                Spacer(minLength: MTTheme.s2)
                Toggle("", isOn: Binding(
                    get: { task.enabled },
                    set: { store.setEnabled($0, id: task.id) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(L("Enabled"))
            }

            HStack(spacing: MTTheme.s2) {
                Text(task.model)
                    .font(MTTheme.mono(10, weight: .semibold))
                    .foregroundStyle(MTTheme.textPrimary)
                    .lineLimit(1)
                Text("·")
                    .foregroundStyle(MTTheme.textTertiary)
                Text(String(format: L("Every %d min"), task.intervalMinutes))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textSecondary)
                Text("·")
                    .foregroundStyle(MTTheme.textTertiary)
                Text(L("Next run") + ": " + nextRunText(task))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textSecondary)
                Spacer(minLength: 0)
            }

            HStack(spacing: MTTheme.s2) {
                if let last = task.lastRunAt {
                    Text(L("Last run") + ": " + ISODate.relative(Date(timeIntervalSince1970: last)))
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.textTertiary)
                }
                if let tokens = task.lastTokens {
                    Text("· \(tokens) " + L("tokens"))
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.textTertiary)
                }
                if let duration = task.lastDurationMs {
                    Text("· " + ISODate.duration(duration))
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.textTertiary)
                }
                Spacer(minLength: 0)
                MTSecondaryButton(
                    title: L("Run now"),
                    systemImage: "play.fill",
                    isLoading: isRunning
                ) {
                    Task { await store.runNow(id: task.id) }
                }
                .disabled(store.isRunning)

                MTSecondaryButton(title: L("Result"), systemImage: "doc.text.magnifyingglass") {
                    resultTarget = task
                }
                .disabled(task.lastRunAt == nil)

                Button {
                    editorTarget = EditorTarget(task: task)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(MTTheme.textSecondary)
                .help(L("Edit task"))

                Button {
                    deleteTarget = task
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(MTTheme.danger)
                .help(L("Delete"))
            }

            if task.lastStatus == .error, let error = task.lastError, !error.isEmpty {
                Text(error)
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.danger)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(MTTheme.s3)
        .background(
            MTTheme.cardSoft.opacity(0.55),
            in: RoundedRectangle(cornerRadius: MTTheme.rSmall, style: .continuous)
        )
    }

    private func nextRunText(_ task: SchedulerTask) -> String {
        guard task.enabled else { return L("Disabled") }
        guard let next = task.nextRunAt else { return "—" }
        return ISODate.until(Date(timeIntervalSince1970: next))
    }

    // MARK: - History

    private var historyCard: some View {
        MTCard(title: L("History"), systemImage: "clock.arrow.circlepath") {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(store.history.prefix(12).enumerated()), id: \.offset) { _, entry in
                    HStack(spacing: MTTheme.s2) {
                        MTStatusDot(status: entry.status.mtStatus, size: 6)
                        Text(ISODate.relative(Date(timeIntervalSince1970: entry.at)))
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.textSecondary)
                            .frame(width: 90, alignment: .leading)
                        Text(taskName(entry.taskId))
                            .font(MTTheme.mono(10, weight: .semibold))
                            .foregroundStyle(MTTheme.textPrimary)
                        Text(entry.model)
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if let tokens = entry.tokens {
                            Text("\(tokens) " + L("tokens"))
                                .font(MTTheme.mono(9))
                                .foregroundStyle(MTTheme.textTertiary)
                        }
                    }
                }
            }
        }
    }

    private func taskName(_ id: String) -> String {
        store.tasks.first { $0.id == id }?.name ?? "—"
    }
}

private extension SchedulerTaskStatus {
    var mtStatus: MTStatus {
        switch self {
        case .never: return .idle
        case .ok: return .ok
        case .error: return .error
        case .running: return .running
        }
    }
}

// MARK: - Add / edit sheet

private struct SchedulerEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = SchedulerStore.shared

    let task: SchedulerTask?

    @State private var name: String
    @State private var prompt: String
    @State private var model: String
    @State private var effort: String
    @State private var intervalMinutes: Int
    @State private var enabled: Bool

    init(task: SchedulerTask?) {
        self.task = task
        _name = State(initialValue: task?.name ?? "")
        _prompt = State(initialValue: task?.prompt ?? "")
        _model = State(initialValue: task?.model ?? "")
        _effort = State(initialValue: task?.reasoningEffort ?? "")
        _intervalMinutes = State(initialValue: task?.intervalMinutes ?? SchedulerLimits.defaultIntervalMinutes)
        _enabled = State(initialValue: task?.enabled ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(task == nil ? L("New task") : L("Edit task"))
                .font(MTTheme.display(18))
                .foregroundStyle(MTTheme.textPrimary)
                .padding(MTTheme.s4)

            Divider().overlay(MTTheme.borderColor)

            ScrollView {
                VStack(alignment: .leading, spacing: MTTheme.s4) {
                    field(L("Name")) {
                        TextField(L("Name"), text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    field(L("Prompt")) {
                        TextEditor(text: $prompt)
                            .font(MTTheme.mono(11))
                            .scrollContentBackground(.hidden)
                            .frame(height: 140)
                            .padding(MTTheme.s2)
                            .background(
                                MTTheme.cardSoft,
                                in: RoundedRectangle(cornerRadius: MTTheme.rSmall, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: MTTheme.rSmall, style: .continuous)
                                    .strokeBorder(MTTheme.borderColor.opacity(0.7), lineWidth: 0.75)
                            )
                    }

                    field(L("Model")) {
                        modelField
                    }

                    HStack(alignment: .top, spacing: MTTheme.s4) {
                        field(L("Reasoning effort")) {
                            Picker("", selection: $effort) {
                                Text(L("None")).tag("")
                                ForEach(SchedulerTask.reasoningEfforts, id: \.self) { value in
                                    Text(value).tag(value)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        field(L("Interval")) {
                            HStack(spacing: MTTheme.s2) {
                                TextField("", value: $intervalMinutes, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 80)
                                Text(L("minutes"))
                                    .font(MTTheme.mono(10))
                                    .foregroundStyle(MTTheme.textSecondary)
                            }
                        }
                    }

                    Toggle(L("Enabled"), isOn: $enabled)
                        .toggleStyle(.switch)
                        .font(MTTheme.body(12))

                    Text(L("Scheduler runs only while Melon Tools is open."))
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.textTertiary)
                }
                .padding(MTTheme.s4)
            }

            Divider().overlay(MTTheme.borderColor)

            HStack(spacing: MTTheme.s2) {
                Spacer()
                MTSecondaryButton(title: L("Cancel")) { dismiss() }
                MTPrimaryButton(title: L("Save"), systemImage: "checkmark", isLoading: false) {
                    save()
                }
                .disabled(!canSave)
            }
            .padding(MTTheme.s4)
        }
        .frame(width: 560, height: 620)
        .background(MTTheme.background)
        .onAppear {
            Task { await store.loadModelsIfNeeded() }
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        guard canSave else { return }
        let selectedEffort = effort.isEmpty ? nil : effort
        if let task {
            store.updateTask(
                id: task.id,
                name: name,
                prompt: prompt,
                model: model,
                reasoningEffort: selectedEffort,
                intervalMinutes: intervalMinutes,
                enabled: enabled
            )
        } else {
            store.addTask(
                name: name,
                prompt: prompt,
                model: model,
                reasoningEffort: selectedEffort,
                intervalMinutes: intervalMinutes,
                enabled: enabled
            )
        }
        dismiss()
    }

    @ViewBuilder
    private var modelField: some View {
        if store.models.isEmpty {
            VStack(alignment: .leading, spacing: MTTheme.s1) {
                TextField(L("Model id"), text: $model)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: MTTheme.s2) {
                    if store.isLoadingModels {
                        ProgressView().controlSize(.small)
                    }
                    Text(store.modelsError ?? L("Load the model list from the running service."))
                        .font(MTTheme.mono(9))
                        .foregroundStyle(store.modelsError == nil ? MTTheme.textTertiary : MTTheme.danger)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    MTSecondaryButton(title: L("Refresh models"), systemImage: "arrow.clockwise", isLoading: store.isLoadingModels) {
                        Task { await store.loadModels() }
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: MTTheme.s1) {
                Picker("", selection: $model) {
                    if !model.isEmpty, !store.models.contains(model) {
                        Text(model).tag(model)
                    }
                    ForEach(SchedulerModelGroup.allCases) { group in
                        let ids = store.models.filter { SchedulerModelGroup.group(for: $0) == group }
                        if !ids.isEmpty {
                            Section(group.title) {
                                ForEach(ids, id: \.self) { id in
                                    Text(id).tag(id)
                                }
                            }
                        }
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: MTTheme.s2) {
                    Text(String(format: L("%d models"), store.models.count))
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.textTertiary)
                    Spacer(minLength: 0)
                    MTSecondaryButton(title: L("Refresh models"), systemImage: "arrow.clockwise", isLoading: store.isLoadingModels) {
                        Task { await store.loadModels() }
                    }
                }
            }
        }
    }

    private func field<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: MTTheme.s1) {
            Text(title)
                .font(MTTheme.mono(9, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(MTTheme.textSecondary)
            content()
        }
    }
}

// MARK: - Result viewer

private struct SchedulerResultSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = SchedulerStore.shared

    let taskID: String
    @State private var selectedIndex: Int?

    private var task: SchedulerTask? {
        store.tasks.first { $0.id == taskID }
    }

    private var entries: [SchedulerHistoryEntry] {
        store.history(for: taskID)
    }

    private var selectedEntry: SchedulerHistoryEntry? {
        guard let selectedIndex, entries.indices.contains(selectedIndex) else { return nil }
        return entries[selectedIndex]
    }

    private var result: String {
        selectedEntry?.result ?? task?.lastResult ?? ""
    }

    private var error: String? {
        selectedEntry?.error ?? task?.lastError
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: MTTheme.s2) {
                Text(task?.name ?? L("Result"))
                    .font(MTTheme.display(18))
                    .foregroundStyle(MTTheme.textPrimary)
                if let model = selectedEntry?.model ?? task?.model {
                    Text(model)
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                }
                Spacer()
            }
            .padding(MTTheme.s4)

            Divider().overlay(MTTheme.borderColor)

            if let error, !error.isEmpty {
                ScrollView {
                    Text(error)
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.danger)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(MTTheme.s3)
                }
                .frame(maxHeight: 110)
                .background(MTTheme.danger.opacity(0.08))
            }

            ScrollView {
                if result.isEmpty {
                    Text(L("No result yet."))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(MTTheme.s4)
                } else {
                    Text(result)
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(MTTheme.s4)
                }
            }

            Divider().overlay(MTTheme.borderColor)

            VStack(alignment: .leading, spacing: MTTheme.s1) {
                Text(L("History").uppercased())
                    .font(MTTheme.mono(9, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(MTTheme.textSecondary)

                if entries.isEmpty {
                    Text(L("No runs yet."))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                                Button {
                                    selectedIndex = index
                                } label: {
                                    HStack(spacing: MTTheme.s2) {
                                        MTStatusDot(status: entry.status.mtStatus, size: 6)
                                        Text(ISODate.relative(Date(timeIntervalSince1970: entry.at)))
                                            .font(MTTheme.mono(9))
                                            .foregroundStyle(MTTheme.textSecondary)
                                            .frame(width: 90, alignment: .leading)
                                        Text(entry.status.title)
                                            .font(MTTheme.mono(9, weight: .semibold))
                                            .foregroundStyle(MTTheme.textPrimary)
                                        if let tokens = entry.tokens {
                                            Text("\(tokens) " + L("tokens"))
                                                .font(MTTheme.mono(9))
                                                .foregroundStyle(MTTheme.textTertiary)
                                        }
                                        if let duration = entry.durationMs {
                                            Text(ISODate.duration(duration))
                                                .font(MTTheme.mono(9))
                                                .foregroundStyle(MTTheme.textTertiary)
                                        }
                                        Spacer(minLength: 0)
                                        if selectedIndex == index {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundStyle(MTTheme.gold)
                                        }
                                    }
                                    .padding(.vertical, 3)
                                    .padding(.horizontal, MTTheme.s2)
                                    .background(
                                        selectedIndex == index
                                            ? MTTheme.cardSoft
                                            : Color.clear,
                                        in: RoundedRectangle(cornerRadius: MTTheme.rSmall, style: .continuous)
                                    )
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 110)
                }
            }
            .padding(MTTheme.s3)

            Divider().overlay(MTTheme.borderColor)

            HStack {
                Spacer()
                MTSecondaryButton(title: L("Close")) { dismiss() }
            }
            .padding(MTTheme.s4)
        }
        .frame(width: 640, height: 580)
        .background(MTTheme.background)
    }
}
