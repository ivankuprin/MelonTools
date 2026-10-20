import Combine
import Foundation

/// Task scheduler store: CRUD, persistence, the 30 s tick and the serial run
/// queue. The file is `~/Library/Application Support/MelonTools/scheduler.json`
/// written atomically with mode 0600 through `SecureFile`.
///
/// Nothing runs unless the app process is alive — there is no launchd agent,
/// no background helper and no retry queue. A stopped gateway only pauses
/// scheduled ticks; when it is running again the next tick starts from the
/// current time, so a downtime can never turn into a burst.
@MainActor
final class SchedulerStore: ObservableObject {
    static let shared = SchedulerStore()

    @Published private(set) var tasks: [SchedulerTask] = []
    @Published private(set) var history: [SchedulerHistoryEntry] = []
    /// Non-nil while one task is in flight; the runner is strictly serial.
    @Published private(set) var runningTaskID: String?
    @Published private(set) var models: [String] = []
    @Published private(set) var modelsError: String?
    @Published private(set) var isLoadingModels = false
    @Published private(set) var persistenceError: String?

    private let fileURL: URL
    private let runner: SchedulerRunner
    private let catalog: SchedulerModelCatalog
    private let gatewayOverride: SchedulerGateway?
    private let gatewayRunningOverride: Bool?
    private var timer: Timer?
    private var loaded = false

    init(
        fileURL: URL = SchedulerStore.defaultFileURL(),
        runner: SchedulerRunner = SchedulerRunner(),
        catalog: SchedulerModelCatalog = SchedulerModelCatalog(),
        gateway: SchedulerGateway? = nil,
        isGatewayRunning: Bool? = nil
    ) {
        self.fileURL = fileURL
        self.runner = runner
        self.catalog = catalog
        self.gatewayOverride = gateway
        self.gatewayRunningOverride = isGatewayRunning
    }

    nonisolated static func defaultFileURL() -> URL {
        CodexStore.supportDir.appendingPathComponent("scheduler.json")
    }

    private var currentGateway: SchedulerGateway {
        gatewayOverride ?? SchedulerGateway(
            baseURL: CodexGatewayService.shared.baseURL,
            apiKey: CodexGatewayService.shared.apiKey
        )
    }

    private var gatewayIsRunning: Bool {
        gatewayRunningOverride ?? CodexGatewayService.shared.isRunning
    }

    var isRunning: Bool { runningTaskID != nil }

    // MARK: - Lifecycle

    /// Load the file once, then arm the 30 s timer and run one overdue task.
    /// Calling it again (dashboard, menu bar, scheduler page) is a no-op.
    func start() {
        if !loaded { load() }
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(
            withTimeInterval: SchedulerLimits.tickInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.tick()
            }
        }
        timer.tolerance = SchedulerLimits.tickTolerance
        self.timer = timer
        Task { await tick() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Persistence

    func load(now: Date = Date()) {
        loaded = true
        guard let data = SecureFile.read(fileURL) else {
            tasks = []
            history = []
            persistenceError = nil
            return
        }
        do {
            let file = try JSONDecoder().decode(SchedulerFile.self, from: data)
            var restored = file.tasks
            var changed = false
            for index in restored.indices {
                // A task that was mid-run when the app quit has no live
                // process behind it any more.
                if restored[index].lastStatus == .running {
                    restored[index].lastStatus = .error
                    restored[index].lastError = restored[index].lastError
                        ?? "Interrupted: Melon Tools quit while the task was running."
                    changed = true
                }
                // An enabled task without a schedule (hand-edited file) gets
                // one interval from now instead of running immediately.
                if restored[index].enabled, restored[index].nextRunAt == nil {
                    restored[index].nextRunAt = SchedulerPolicy.nextRun(
                        after: now,
                        intervalMinutes: restored[index].intervalMinutes
                    ).timeIntervalSince1970
                    changed = true
                }
            }
            let trimmed = SchedulerPolicy.trimHistory(file.history)
            tasks = restored
            history = trimmed
            if changed || trimmed.count != file.history.count { save() }
        } catch {
            // Leave the unreadable file on disk for manual recovery.
            tasks = []
            history = []
            persistenceError = "Could not read scheduler.json: \(error.localizedDescription)"
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let file = SchedulerFile(tasks: tasks, history: history)
            try SecureFile.write(encoder.encode(file), to: fileURL)
            persistenceError = nil
        } catch {
            persistenceError = "Could not save scheduler.json: \(error.localizedDescription)"
        }
    }

    // MARK: - CRUD

    @discardableResult
    func addTask(
        name: String,
        prompt: String,
        model: String,
        reasoningEffort: String?,
        intervalMinutes: Int,
        enabled: Bool,
        now: Date = Date()
    ) -> SchedulerTask {
        let interval = clampedInterval(intervalMinutes)
        var task = SchedulerTask(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            prompt: prompt,
            model: model,
            reasoningEffort: reasoningEffort,
            intervalMinutes: interval,
            enabled: enabled,
            createdAt: now.timeIntervalSince1970
        )
        task.nextRunAt = enabled
            ? SchedulerPolicy.nextRun(after: now, intervalMinutes: interval).timeIntervalSince1970
            : nil
        tasks.append(task)
        save()
        return task
    }

    func updateTask(
        id: String,
        name: String,
        prompt: String,
        model: String,
        reasoningEffort: String?,
        intervalMinutes: Int,
        enabled: Bool,
        now: Date = Date()
    ) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        var task = tasks[index]
        let interval = clampedInterval(intervalMinutes)
        task.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        task.prompt = prompt
        task.model = model
        task.reasoningEffort = reasoningEffort
        task.intervalMinutes = interval
        task.enabled = enabled
        task.nextRunAt = enabled
            ? SchedulerPolicy.nextRun(after: now, intervalMinutes: interval).timeIntervalSince1970
            : nil
        tasks[index] = task
        save()
    }

    func deleteTask(id: String) {
        tasks.removeAll { $0.id == id }
        history.removeAll { $0.taskId == id }
        if runningTaskID == id { runningTaskID = nil }
        save()
    }

    func setEnabled(_ enabled: Bool, id: String, now: Date = Date()) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard tasks[index].enabled != enabled else { return }
        var task = tasks[index]
        task.enabled = enabled
        task.nextRunAt = enabled
            ? SchedulerPolicy.nextRun(after: now, intervalMinutes: task.intervalMinutes).timeIntervalSince1970
            : nil
        tasks[index] = task
        save()
    }

    // MARK: - Running

    /// One tick: at most one due task is executed. Overdue tasks are never
    /// replayed — each run moves its own `nextRunAt` one interval forward.
    func tick(now: Date = Date()) async {
        guard runningTaskID == nil else { return }
        guard gatewayIsRunning else { return }
        guard let task = SchedulerPolicy.due(tasks, now: now, excluding: runningTaskID).first else {
            return
        }
        await execute(taskID: task.id)
    }

    /// Run now always runs, even for a disabled task, and advances the
    /// schedule so the next scheduled run is a full interval away.
    func runNow(id: String) async {
        guard runningTaskID == nil else { return }
        await execute(taskID: id)
    }

    private func execute(taskID: String) async {
        guard runningTaskID == nil else { return }
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }

        var running = tasks[index]
        running.lastStatus = .running
        running.lastError = nil
        tasks[index] = running
        runningTaskID = taskID

        let result = await runner.run(task: running, gateway: currentGateway)

        // The task may have been deleted while the request was in flight.
        guard let currentIndex = tasks.firstIndex(where: { $0.id == taskID }) else {
            runningTaskID = nil
            return
        }
        var updated = tasks[currentIndex]
        let finishedAt = Date()
        let body = SchedulerPolicy.truncatedResult(result.result)
        updated.lastRunAt = finishedAt.timeIntervalSince1970
        updated.lastStatus = result.status
        updated.lastResult = body
        updated.lastError = result.error
        updated.lastDurationMs = result.durationMs
        updated.lastTokens = result.tokens
        // Failures keep the task enabled; the next attempt is one interval
        // away (no exponential retry, no burst).
        updated.nextRunAt = updated.enabled
            ? SchedulerPolicy.nextRun(
                after: finishedAt,
                intervalMinutes: updated.intervalMinutes
            ).timeIntervalSince1970
            : nil
        tasks[currentIndex] = updated

        let entry = SchedulerHistoryEntry(
            taskId: taskID,
            at: finishedAt.timeIntervalSince1970,
            status: result.status,
            model: updated.model,
            durationMs: result.durationMs,
            tokens: result.tokens,
            result: body,
            error: result.error
        )
        history = SchedulerPolicy.trimHistory([entry] + history)
        runningTaskID = nil
        save()
    }

    // MARK: - Model list

    /// `GET /v1/models` with the Bearer key. The exact id is kept for storage;
    /// the picker groups it by prefix.
    func loadModels() async {
        guard !isLoadingModels else { return }
        isLoadingModels = true
        modelsError = nil
        defer { isLoadingModels = false }
        do {
            let ids = try await catalog.fetchModels(gateway: currentGateway)
            models = ids
            if ids.isEmpty {
                modelsError = L("The service returned an empty model list.")
            }
        } catch {
            modelsError = String(describing: error)
        }
    }

    func loadModelsIfNeeded() async {
        guard models.isEmpty else { return }
        await loadModels()
    }

    // MARK: - Helpers

    func history(for taskID: String) -> [SchedulerHistoryEntry] {
        history.filter { $0.taskId == taskID }
    }

    private func clampedInterval(_ value: Int) -> Int {
        max(1, min(value, SchedulerLimits.maximumIntervalMinutes))
    }
}
