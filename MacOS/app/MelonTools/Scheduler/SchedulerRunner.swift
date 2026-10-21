import Foundation

/// Outcome of one chat-completions call.
struct SchedulerRunResult: Equatable {
    var status: SchedulerTaskStatus
    /// `choices[0].message.content`, truncated to 64 KiB.
    var result: String
    /// Verbatim HTTP body or network error; nil on success.
    var error: String?
    var durationMs: Int
    var tokens: Int?
}

/// Owns the active `URLSessionDataTask` behind the default transport.
/// `SchedulerRunner.cancel()` cancels it from the main actor; Task
/// cancellation does the same through `withTaskCancellationHandler`.
final class SchedulerRequestCancellation: @unchecked Sendable {
    private let session: URLSession
    private let lock = NSLock()
    private var activeTask: URLSessionDataTask?
    private var cancelled = false

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Called once per run: a cancel from a previous run must not leak into
    /// the next one.
    func reset() {
        lock.lock()
        cancelled = false
        activeTask = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = activeTask
        activeTask = nil
        lock.unlock()
        task?.cancel()
    }

    /// Bridge `URLSessionDataTask` to async without losing cancellation.
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let state = SchedulerDataTaskState()
        let dataTask = session.dataTask(with: request) { data, response, error in
            if let error {
                state.finish(.failure(error))
            } else if let response {
                state.finish(.success((data ?? Data(), response)))
            } else {
                state.finish(.failure(URLError(.badServerResponse)))
            }
        }
        defer { detach(dataTask) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                guard attach(dataTask) else {
                    state.finish(.failure(CancellationError()))
                    return
                }
                dataTask.resume()
            }
        } onCancel: {
            dataTask.cancel()
            state.finish(.failure(CancellationError()))
        }
    }

    /// `false` means a cancel arrived before the task could start.
    private func attach(_ task: URLSessionDataTask) -> Bool {
        lock.lock()
        if cancelled {
            lock.unlock()
            return false
        }
        activeTask = task
        lock.unlock()
        return true
    }

    private func detach(_ task: URLSessionDataTask) {
        lock.lock()
        if activeTask === task { activeTask = nil }
        lock.unlock()
    }
}

/// One-shot continuation box: a late `cancel` and the URLSession callback
/// race, but only the first result is delivered.
private final class SchedulerDataTaskState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var finished = false
    private var result: Result<(Data, URLResponse), Error>?

    func install(_ continuation: CheckedContinuation<(Data, URLResponse), Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ result: Result<(Data, URLResponse), Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = continuation
        self.continuation = nil
        self.result = result
        lock.unlock()
        continuation?.resume(with: result)
    }
}

/// Executes a task against the local gateway:
/// `POST {baseURL}/v1/chat/completions` with a Bearer key, 300 s timeout.
/// The transport is injectable so tests can exercise parsing and error
/// handling without a live service.
struct SchedulerRunner {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    /// Recorded for an aborted run; a cancelled run is never retried.
    static let cancelledMessage = "Cancelled by user"

    private let transport: Transport
    private let cancellation: SchedulerRequestCancellation?

    /// Default transport: one cancellable `URLSessionDataTask`.
    init(session: URLSession = .shared) {
        let cancellation = SchedulerRequestCancellation(session: session)
        self.cancellation = cancellation
        self.transport = { request in
            try await cancellation.data(for: request)
        }
    }

    /// Injected transport for tests. Behavior is unchanged.
    init(transport: @escaping Transport) {
        self.cancellation = nil
        self.transport = transport
    }

    /// Abort the in-flight request. Safe to call when nothing is running.
    func cancel() {
        cancellation?.cancel()
    }

    func run(task: SchedulerTask, gateway: SchedulerGateway) async -> SchedulerRunResult {
        let started = Date()
        guard !Task.isCancelled else { return cancelledResult(started: started) }
        cancellation?.reset()
        let base = gateway.baseURL.hasSuffix("/")
            ? String(gateway.baseURL.dropLast())
            : gateway.baseURL
        guard let url = URL(string: "\(base)/v1/chat/completions") else {
            return SchedulerRunResult(
                status: .error,
                result: "",
                error: "Invalid gateway URL: \(gateway.baseURL)",
                durationMs: elapsed(since: started),
                tokens: nil
            )
        }

        var prompt = task.prompt
        if task.includeGitContext,
           let directory = task.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !directory.isEmpty {
            let context = await Task.detached(priority: .utility) {
                SchedulerGitContext.build(directory: directory)
            }.value
            if !context.isEmpty {
                prompt += "\n\nRepository context (read-only):\n" + context
            }
        }

        var payload: [String: Any] = [
            "model": task.model,
            "messages": [["role": "user", "content": prompt]],
            "stream": false,
        ]
        if let maxTokens = task.maxTokens {
            payload["max_tokens"] = maxTokens
        }
        // The spec fixes the body shape; the optional effort is forwarded only
        // when the user picked one, so the default request stays minimal.
        if let effort = task.reasoningEffort, !effort.isEmpty {
            payload["reasoning_effort"] = effort
        }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return SchedulerRunResult(
                status: .error,
                result: "",
                error: "Could not encode the request body.",
                durationMs: elapsed(since: started),
                tokens: nil
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(gateway.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = SchedulerLimits.requestTimeout
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            // Cancellation is not a failure: no retry and a distinct status.
            if Self.isCancellation(error) || Task.isCancelled {
                return cancelledResult(started: started)
            }
            // Verbatim network error: domain, code and the system message.
            return SchedulerRunResult(
                status: .error,
                result: "",
                error: String(describing: error),
                durationMs: elapsed(since: started),
                tokens: nil
            )
        }
        guard !Task.isCancelled else { return cancelledResult(started: started) }

        let http = response as? HTTPURLResponse
        let statusCode = http?.statusCode ?? -1
        let text = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(statusCode) else {
            // Verbatim gateway answer, including the status line.
            return SchedulerRunResult(
                status: .error,
                result: "",
                error: "HTTP \(statusCode): \(text)",
                durationMs: elapsed(since: started),
                tokens: nil
            )
        }

        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            return SchedulerRunResult(
                status: .error,
                result: "",
                error: "Malformed response: \(String(text.prefix(500)))",
                durationMs: elapsed(since: started),
                tokens: nil
            )
        }

        let tokens = ((root["usage"] as? [String: Any])?["total_tokens"] as? Int)
        return SchedulerRunResult(
            status: .ok,
            result: SchedulerPolicy.truncatedResult(content),
            error: nil,
            durationMs: elapsed(since: started),
            tokens: tokens
        )
    }

    private func cancelledResult(started: Date) -> SchedulerRunResult {
        SchedulerRunResult(
            status: .cancelled,
            result: "",
            error: Self.cancelledMessage,
            durationMs: elapsed(since: started),
            tokens: nil
        )
    }

    /// `CancellationError`, `URLError.cancelled` and the raw
    /// `NSURLErrorCancelled` code all mean the same thing.
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func elapsed(since date: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(date) * 1000))
    }
}

/// `GET /v1/models` client for the model picker. The exact returned id is
/// preserved; grouping is a UI concern.
struct SchedulerModelCatalog {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    private let transport: Transport

    init(transport: @escaping Transport = { request in
        try await URLSession.shared.data(for: request)
    }) {
        self.transport = transport
    }

    func fetchModels(gateway: SchedulerGateway) async throws -> [String] {
        let base = gateway.baseURL.hasSuffix("/")
            ? String(gateway.baseURL.dropLast())
            : gateway.baseURL
        guard let url = URL(string: "\(base)/v1/models") else {
            throw NSError(
                domain: "SchedulerModelCatalog",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid gateway URL: \(gateway.baseURL)"]
            )
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(gateway.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (data, response) = try await transport(request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "SchedulerModelCatalog",
                code: code,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(code): \(text)"]
            )
        }
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = root["data"] as? [[String: Any]]
        else {
            throw NSError(
                domain: "SchedulerModelCatalog",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Malformed model list."]
            )
        }
        let ids = entries.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
        return Array(Set(ids)).sorted()
    }
}

/// Read-only repository context for scheduled tasks. Bounded so a huge diff
/// cannot exceed the model context or blow up `scheduler.json`.
enum SchedulerGitContext {
    static func build(directory: String, maxBytes: Int = 12_000) -> String {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        guard !run(["rev-parse", "--is-inside-work-tree"], in: url).isEmpty else { return "" }
        let status = run(["status", "--short"], in: url)
        let log = run(["log", "-5", "--oneline", "--decorate"], in: url)
        let diff = run(["diff", "--stat"], in: url)
        var text = ""
        if !status.isEmpty { text += "$ git status --short\n\(status)\n" }
        if !log.isEmpty { text += "$ git log -5 --oneline\n\(log)\n" }
        if !diff.isEmpty { text += "$ git diff --stat\n\(diff)\n" }
        return String(text.prefix(maxBytes))
    }

    private static func run(_ arguments: [String], in directory: URL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
