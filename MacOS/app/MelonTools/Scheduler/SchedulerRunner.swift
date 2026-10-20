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

/// Executes a task against the local gateway:
/// `POST {baseURL}/v1/chat/completions` with a Bearer key, 300 s timeout.
/// The transport is injectable so tests can exercise parsing and error
/// handling without a live service.
struct SchedulerRunner {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    private let transport: Transport

    init(transport: @escaping Transport = { request in
        try await URLSession.shared.data(for: request)
    }) {
        self.transport = transport
    }

    func run(task: SchedulerTask, gateway: SchedulerGateway) async -> SchedulerRunResult {
        let started = Date()
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

        var payload: [String: Any] = [
            "model": task.model,
            "messages": [["role": "user", "content": task.prompt]],
            "stream": false,
        ]
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
            // Verbatim network error: domain, code and the system message.
            return SchedulerRunResult(
                status: .error,
                result: "",
                error: String(describing: error),
                durationMs: elapsed(since: started),
                tokens: nil
            )
        }

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
