import Foundation

/// One Chrome DevTools Protocol WebSocket connection to a Codex app page.
///
/// The bridge uses it to enable the Page/Runtime domains, register the chips
/// script for future document loads and evaluate it right away. Fire-and-forget
/// commands are enough for injection; `evaluateWithResult` is used for
/// verification from the UI.
final class CDPSession: @unchecked Sendable {
    let wsURL: URL

    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private let lock = NSLock()
    private var nextID = 1
    private var dead = false
    private var lastError: String?
    private var pending: [Int: CheckedContinuation<Any?, Never>] = [:]

    /// Called for Runtime.bindingCalled events (name, payload).
    var onBinding: ((String, String) -> Void)?

    init(wsURL: URL) {
        self.wsURL = wsURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
        self.task = session.webSocketTask(with: wsURL)
    }

    var isAlive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !dead
    }

    var errorDescription: String? {
        lock.lock()
        defer { lock.unlock() }
        return lastError
    }

    func connect(script: String) {
        task.resume()
        receiveLoop()
        send(method: "Page.enable", params: [:])
        send(method: "Runtime.enable", params: [:])
        // The page calls __melonSend(payload) from the injected script; the event
        // arrives as Runtime.bindingCalled. No executionContextId → all contexts.
        send(method: "Runtime.addBinding", params: ["name": "__melonSend"])
        send(method: "Page.addScriptToEvaluateOnNewDocument", params: ["source": script])
        evaluate(script)
    }

    func evaluate(_ expression: String) {
        send(method: "Runtime.evaluate", params: [
            "expression": expression,
            "returnByValue": true,
            "awaitPromise": true,
        ])
    }

    func evaluateWithResult(_ expression: String, timeout: TimeInterval = 6) async -> Any? {
        guard isAlive else { return nil }
        let id = nextRequestID()
        let message: [String: Any] = [
            "id": id,
            "method": "Runtime.evaluate",
            "params": [
                "expression": expression,
                "returnByValue": true,
                "awaitPromise": true,
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Any?, Never>) in
            lock.lock()
            pending[id] = continuation
            lock.unlock()
            task.send(.string(text)) { [weak self] error in
                if let error {
                    self?.markDead(error.localizedDescription)
                    self?.resume(id: id, value: nil)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.resume(id: id, value: nil)
            }
        }
    }

    func ping() {
        guard isAlive else { return }
        task.sendPing { [weak self] error in
            if let error { self?.markDead("ping: \(error.localizedDescription)") }
        }
    }

    func close() {
        markDead("closed")
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
        resumeAllPending()
    }

    // MARK: - Plumbing

    private func nextRequestID() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let id = nextID
        nextID += 1
        return id
    }

    private func send(method: String, params: [String: Any]) {
        guard isAlive else { return }
        let id = nextRequestID()
        let message: [String: Any] = ["id": id, "method": method, "params": params]
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { [weak self] error in
            if let error { self?.markDead(error.localizedDescription) }
        }
    }

    private func receiveLoop() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.handle(message)
                self.receiveLoop()
            case .failure(let error):
                self.markDead(error.localizedDescription)
                self.resumeAllPending()
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let id = json["id"] as? Int {
            resume(id: id, value: json["result"])
            return
        }
        if let method = json["method"] as? String, method == "Runtime.bindingCalled",
           let params = json["params"] as? [String: Any],
           let name = params["name"] as? String {
            onBinding?(name, params["payload"] as? String ?? "")
        }
    }

    private func resume(id: Int, value: Any?) {
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume(returning: value)
    }

    private func resumeAllPending() {
        lock.lock()
        let all = pending
        pending.removeAll()
        lock.unlock()
        for (_, continuation) in all {
            continuation.resume(returning: nil)
        }
    }

    private func markDead(_ reason: String) {
        lock.lock()
        if !dead { lastError = reason }
        dead = true
        lock.unlock()
    }
}
