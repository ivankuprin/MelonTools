import XCTest
@testable import MelonTools

/// Scheduler contract tests: due policy, serial/no-burst execution, run-now,
/// persistence, history caps and the HTTP runner. All clock-sensitive checks
/// receive an explicit `now`; the network is replaced by an injected transport.
@MainActor
final class SchedulerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheduler-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    private var fileURL: URL {
        directory.appendingPathComponent("scheduler.json")
    }

    private let gateway = SchedulerGateway(baseURL: "http://127.0.0.1:18317", apiKey: "test-key")

    private final class Counter {
        var value = 0
    }

    private func okRunner(
        _ content: String = "answer",
        tokens: Int = 42,
        counter: Counter? = nil
    ) -> SchedulerRunner {
        SchedulerRunner { request in
            counter?.value += 1
            let object: [String: Any] = [
                "choices": [["message": ["content": content]]],
                "usage": ["total_tokens": tokens],
            ]
            let data = try JSONSerialization.data(withJSONObject: object)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (data, response)
        }
    }

    private func makeStore(
        runner: SchedulerRunner,
        gatewayRunning: Bool = true
    ) -> SchedulerStore {
        SchedulerStore(
            fileURL: fileURL,
            runner: runner,
            gateway: gateway,
            isGatewayRunning: gatewayRunning
        )
    }

    private func seed(_ tasks: [SchedulerTask]) throws {
        let file = SchedulerFile(tasks: tasks, history: [])
        try SecureFile.write(JSONEncoder().encode(file), to: fileURL)
    }

    // MARK: - Due policy

    func testDuePolicyUsesEnabledDueAndNotRunning() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let past = now.addingTimeInterval(-60).timeIntervalSince1970
        let future = now.addingTimeInterval(60).timeIntervalSince1970

        let due = SchedulerTask(name: "due", model: "m", intervalMinutes: 60, nextRunAt: past)
        let disabled = SchedulerTask(
            name: "disabled", model: "m", intervalMinutes: 60,
            enabled: false, nextRunAt: past
        )
        let later = SchedulerTask(name: "later", model: "m", intervalMinutes: 60, nextRunAt: future)
        let running = SchedulerTask(name: "running", model: "m", intervalMinutes: 60, nextRunAt: past)
        let unscheduled = SchedulerTask(name: "unscheduled", model: "m", intervalMinutes: 60, nextRunAt: nil)

        let result = SchedulerPolicy.due(
            [due, disabled, later, running, unscheduled],
            now: now,
            excluding: running.id
        )
        XCTAssertEqual(result.map(\.id), [due.id])
    }

    func testDisabledTasksNeverRunAndToggleSchedules() async {
        let counter = Counter()
        let counted = makeStore(runner: okRunner(counter: counter), gatewayRunning: true)

        let task = counted.addTask(
            name: "off",
            prompt: "p",
            model: "m",
            reasoningEffort: nil,
            intervalMinutes: 15,
            enabled: false
        )
        XCTAssertNil(task.nextRunAt)

        await counted.tick()
        XCTAssertEqual(counter.value, 0)

        counted.setEnabled(true, id: task.id)
        XCTAssertTrue(counted.tasks[0].enabled)
        XCTAssertNotNil(counted.tasks[0].nextRunAt)

        // Freshly enabled: one full interval away, so the next tick is a no-op.
        await counted.tick()
        XCTAssertEqual(counter.value, 0)
    }

    // MARK: - Serial execution and no catch-up burst

    func testOneDueTaskPerTickAndNoReplayOfMissedIntervals() async throws {
        let now = Date()
        let past = now.addingTimeInterval(-4 * 3600).timeIntervalSince1970
        let first = SchedulerTask(name: "first", model: "m", intervalMinutes: 30, nextRunAt: past)
        let second = SchedulerTask(name: "second", model: "m", intervalMinutes: 30, nextRunAt: past)
        try seed([first, second])
        let counter = Counter()
        let store = makeStore(runner: okRunner(counter: counter), gatewayRunning: true)
        store.load()

        await store.tick(now: now)
        XCTAssertEqual(counter.value, 1, "serial queue: one task per tick")
        XCTAssertEqual(store.tasks.filter { $0.lastStatus == .ok }.count, 1)

        let ranIndex = store.tasks.firstIndex { $0.lastStatus == .ok }!
        let task = store.tasks[ranIndex]
        XCTAssertEqual(
            task.nextRunAt!,
            task.lastRunAt! + 30 * 60,
            accuracy: 0.001,
            "nextRunAt advances one interval; missed intervals are not replayed"
        )
        XCTAssertGreaterThan(task.nextRunAt!, now.timeIntervalSince1970)

        await store.tick(now: now.addingTimeInterval(31 * 60))
        XCTAssertEqual(counter.value, 2, "second overdue task runs on the next tick")
    }

    func testTickIsPausedWhileGatewayIsStopped() async throws {
        let past = Date().addingTimeInterval(-3600).timeIntervalSince1970
        try seed([SchedulerTask(name: "due", model: "m", intervalMinutes: 60, nextRunAt: past)])
        let counter = Counter()
        let store = makeStore(runner: okRunner(counter: counter), gatewayRunning: false)
        store.load()

        await store.tick()
        XCTAssertEqual(counter.value, 0)
        XCTAssertNotNil(store.tasks[0].nextRunAt)
    }

    // MARK: - Run now

    func testRunNowRecordsResultAndAdvancesNextRunAt() async {
        let store = makeStore(runner: okRunner("hello world", tokens: 99), gatewayRunning: true)
        let task = store.addTask(
            name: "run",
            prompt: "ping",
            model: "gpt-test",
            reasoningEffort: "low",
            intervalMinutes: 60,
            enabled: true
        )
        let before = task.nextRunAt!

        await store.runNow(id: task.id)

        let updated = store.tasks[0]
        XCTAssertEqual(updated.lastStatus, .ok)
        XCTAssertEqual(updated.lastResult, "hello world")
        XCTAssertNil(updated.lastError)
        XCTAssertEqual(updated.lastTokens, 99)
        XCTAssertNotNil(updated.lastDurationMs)
        XCTAssertGreaterThan(updated.nextRunAt!, before)
        XCTAssertEqual(store.history.count, 1)
        XCTAssertEqual(store.history[0].status, .ok)
        XCTAssertEqual(store.history[0].tokens, 99)
    }

    func testRunNowOnDisabledTaskStillRuns() async {
        let counter = Counter()
        let store = makeStore(runner: okRunner(counter: counter), gatewayRunning: true)
        let task = store.addTask(
            name: "disabled run-now",
            prompt: "p",
            model: "m",
            reasoningEffort: nil,
            intervalMinutes: 60,
            enabled: false
        )

        await store.runNow(id: task.id)

        XCTAssertEqual(counter.value, 1)
        XCTAssertFalse(store.tasks[0].enabled)
        XCTAssertEqual(store.tasks[0].lastStatus, .ok)
        // A manual run of a disabled task must not arm a schedule.
        XCTAssertNil(store.tasks[0].nextRunAt)
    }

    func testFailureStaysEnabledAndKeepsErrorVerbatim() async {
        let runner = SchedulerRunner { request in
            let data = Data("upstream exploded".utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (data, response)
        }
        let store = makeStore(runner: runner, gatewayRunning: true)
        let task = store.addTask(
            name: "fails",
            prompt: "p",
            model: "m",
            reasoningEffort: nil,
            intervalMinutes: 45,
            enabled: true
        )
        let before = task.nextRunAt!

        await store.runNow(id: task.id)

        let updated = store.tasks[0]
        XCTAssertEqual(updated.lastStatus, .error)
        XCTAssertEqual(updated.lastError, "HTTP 500: upstream exploded")
        XCTAssertTrue(updated.enabled, "failures keep the task enabled")
        XCTAssertGreaterThan(updated.nextRunAt!, before)
        XCTAssertEqual(store.history[0].error, "HTTP 500: upstream exploded")
    }

    // MARK: - Persistence

    func testCRUDPersistenceRoundTripWith0600File() throws {
        let store = makeStore(runner: okRunner(), gatewayRunning: true)
        let task = store.addTask(
            name: "persist",
            prompt: "prompt body",
            model: "openrouter/x",
            reasoningEffort: "high",
            intervalMinutes: 90,
            enabled: true
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)

        let restored = makeStore(runner: okRunner(), gatewayRunning: true)
        restored.load()
        XCTAssertEqual(restored.tasks.count, 1)
        XCTAssertEqual(restored.tasks[0].id, task.id)
        XCTAssertEqual(restored.tasks[0].name, "persist")
        XCTAssertEqual(restored.tasks[0].prompt, "prompt body")
        XCTAssertEqual(restored.tasks[0].model, "openrouter/x")
        XCTAssertEqual(restored.tasks[0].reasoningEffort, "high")
        XCTAssertEqual(restored.tasks[0].intervalMinutes, 90)

        restored.updateTask(
            id: task.id,
            name: "renamed",
            prompt: "new prompt",
            model: "opencode/x",
            reasoningEffort: nil,
            intervalMinutes: 120,
            enabled: false
        )
        let updated = makeStore(runner: okRunner(), gatewayRunning: true)
        updated.load()
        XCTAssertEqual(updated.tasks[0].name, "renamed")
        XCTAssertEqual(updated.tasks[0].model, "opencode/x")
        XCTAssertEqual(updated.tasks[0].intervalMinutes, 120)
        XCTAssertFalse(updated.tasks[0].enabled)
        XCTAssertNil(updated.tasks[0].nextRunAt)

        updated.deleteTask(id: task.id)
        let empty = makeStore(runner: okRunner(), gatewayRunning: true)
        empty.load()
        XCTAssertTrue(empty.tasks.isEmpty)
    }

    func testRunHistoryPersistsAndIsRemovedWithTheTask() async {
        let store = makeStore(runner: okRunner(), gatewayRunning: true)
        let task = store.addTask(
            name: "history",
            prompt: "p",
            model: "m",
            reasoningEffort: nil,
            intervalMinutes: 60,
            enabled: true
        )
        await store.runNow(id: task.id)
        await store.runNow(id: task.id)

        let restored = makeStore(runner: okRunner(), gatewayRunning: true)
        restored.load()
        XCTAssertEqual(restored.history.count, 2)

        restored.deleteTask(id: task.id)
        let empty = makeStore(runner: okRunner(), gatewayRunning: true)
        empty.load()
        XCTAssertTrue(empty.history.isEmpty)
    }

    // MARK: - Caps and truncation

    func testHistoryCapsAtTwentyPerTaskAndTwoHundredGlobal() {
        let perTask = (0..<25).map { index in
            SchedulerHistoryEntry(
                taskId: "a", at: Double(index), status: .ok, model: "m",
                durationMs: 1, tokens: 1, result: "", error: nil
            )
        }
        XCTAssertEqual(SchedulerPolicy.trimHistory(perTask).count, 20)

        let many = (0..<400).map { index in
            SchedulerHistoryEntry(
                taskId: "task-\(index % 20)", at: Double(index), status: .ok, model: "m",
                durationMs: 1, tokens: 1, result: "", error: nil
            )
        }
        let trimmed = SchedulerPolicy.trimHistory(many)
        XCTAssertEqual(trimmed.count, 200)
        XCTAssertEqual(trimmed.first?.at, 0)
        XCTAssertEqual(trimmed.last?.at, 199)
    }

    func testResultsAreTruncatedTo64KiB() async {
        let limit = SchedulerLimits.resultByteLimit
        let huge = String(repeating: "я", count: limit) // 2 bytes per character
        XCTAssertGreaterThan(huge.utf8.count, limit)

        let cut = SchedulerPolicy.truncatedResult(huge)
        XCTAssertLessThanOrEqual(cut.utf8.count, limit)
        XCTAssertFalse(cut.hasSuffix("\u{FFFD}"), "no split multi-byte character")

        let store = makeStore(runner: okRunner(huge), gatewayRunning: true)
        let task = store.addTask(
            name: "big",
            prompt: "p",
            model: "m",
            reasoningEffort: nil,
            intervalMinutes: 60,
            enabled: true
        )
        await store.runNow(id: task.id)
        XCTAssertLessThanOrEqual(store.tasks[0].lastResult.utf8.count, limit)
        XCTAssertLessThanOrEqual(store.history[0].result.utf8.count, limit)
    }

    // MARK: - Model grouping

    func testModelGroupingKeepsExactIds() {
        XCTAssertEqual(SchedulerModelGroup.group(for: "opencode/claude-sonnet"), .openCode)
        XCTAssertEqual(SchedulerModelGroup.group(for: "openrouter/openai/gpt-5"), .openRouter)
        XCTAssertEqual(SchedulerModelGroup.group(for: "claude-haiku-4-5"), .claude)
        XCTAssertEqual(SchedulerModelGroup.group(for: "gemini-3-flash"), .antigravity)
        XCTAssertEqual(SchedulerModelGroup.group(for: "gpt-5.1-codex-mini"), .pool)

        let ids = ["opencode/a", "openrouter/b", "claude-c", "gemini-3-flash", "gpt-5"]
        let grouped = Dictionary(grouping: ids, by: SchedulerModelGroup.group(for:))
        XCTAssertEqual(grouped[.openCode], ["opencode/a"])
        XCTAssertEqual(grouped[.openRouter], ["openrouter/b"])
        XCTAssertEqual(grouped[.claude], ["claude-c"])
        XCTAssertEqual(grouped[.antigravity], ["gemini-3-flash"])
        XCTAssertEqual(grouped[.pool], ["gpt-5"])
    }

    // MARK: - Runner

    func testRunnerSendsContractRequestAndParsesContent() async throws {
        var captured: URLRequest?
        let runner = SchedulerRunner { request in
            captured = request
            let object: [String: Any] = [
                "choices": [["message": ["content": "  spaced answer  "]]],
                "usage": ["total_tokens": 7],
            ]
            let data = try JSONSerialization.data(withJSONObject: object)
            return (data, HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!)
        }
        let task = SchedulerTask(
            name: "run",
            prompt: "hello",
            model: "gpt-test",
            reasoningEffort: "high",
            intervalMinutes: 60
        )

        let result = await runner.run(task: task, gateway: gateway)

        XCTAssertEqual(result.status, .ok)
        XCTAssertEqual(result.result, "  spaced answer  ")
        XCTAssertEqual(result.tokens, 7)
        XCTAssertNil(result.error)

        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:18317/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(request.timeoutInterval, 300)

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "gpt-test")
        XCTAssertEqual(json["stream"] as? Bool, false)
        XCTAssertEqual(json["reasoning_effort"] as? String, "high")
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "user")
        XCTAssertEqual(messages.first?["content"] as? String, "hello")
    }

    func testRunnerStoresHTTPErrorVerbatim() async {
        let runner = SchedulerRunner { request in
            (Data("no capacity".utf8), HTTPURLResponse(
                url: request.url!,
                statusCode: 503,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!)
        }
        let task = SchedulerTask(name: "run", prompt: "p", model: "m", intervalMinutes: 60)

        let result = await runner.run(task: task, gateway: gateway)

        XCTAssertEqual(result.status, .error)
        XCTAssertEqual(result.error, "HTTP 503: no capacity")
        XCTAssertEqual(result.result, "")
    }

    func testRunnerStoresNetworkErrorVerbatim() async {
        let runner = SchedulerRunner { _ in
            throw URLError(.cannotConnectToHost)
        }
        let task = SchedulerTask(name: "run", prompt: "p", model: "m", intervalMinutes: 60)

        let result = await runner.run(task: task, gateway: gateway)

        XCTAssertEqual(result.status, .error)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error?.contains("NSURLErrorDomain") == true, result.error ?? "nil")
    }

    // MARK: - Model list

    func testModelCatalogParsesAndSortsIds() async throws {
        let catalog = SchedulerModelCatalog { request in
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:18317/v1/models")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            let data = try JSONSerialization.data(withJSONObject: [
                "data": [["id": "openrouter/z"], ["id": "gpt-5"], ["id": "opencode/a"], ["id": "gpt-5"]],
            ])
            return (data, HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!)
        }

        let ids = try await catalog.fetchModels(gateway: gateway)
        XCTAssertEqual(ids, ["gpt-5", "opencode/a", "openrouter/z"])
    }
}
