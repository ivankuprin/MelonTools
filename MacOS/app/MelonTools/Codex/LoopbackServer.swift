import Foundation

/// One-shot loopback HTTP server that receives the OAuth PKCE redirect
/// (`http://localhost:1455/auth/callback`), mirroring the official Codex CLI.
///
/// Implemented on POSIX sockets (Network.framework's NWListener refuses to bind
/// in some host contexts on macOS 26 — EINVAL — while plain BSD sockets work everywhere).
final class LoopbackServer: @unchecked Sendable {
    enum ServerError: Error, LocalizedError {
        case noPort
        case stateMismatch
        case denied(String)
        case timeout
        case cancelled

        var errorDescription: String? {
            switch self {
            case .noPort: return L("Local ports 1455 and 1457 are busy — close other login attempts and try again.")
            case .stateMismatch: return L("OAuth state mismatch — the callback does not belong to this login attempt.")
            case .denied(let reason): return reason
            case .timeout: return L("Login timed out — the browser did not return a code.")
            case .cancelled: return L("Login cancelled.")
            }
        }
    }

    private let queue = DispatchQueue(label: "dev.melontools.loopback")
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var continuation: CheckedContinuation<String, Error>?
    private var expectedState = ""
    private var finished = false
    private(set) var port: UInt16 = 0

    /// Bind 1455, falling back to 1457. Returns the port actually bound.
    func start(expectedState: String, ports: [UInt16] = [1455, 1457]) async throws -> UInt16 {
        self.expectedState = expectedState
        for candidate in ports {
            guard let fd = Self.bind(port: candidate) else { continue }
            listenFD = fd
            port = candidate
            queue.async { [weak self] in
                self?.acceptLoop()
            }
            return candidate
        }
        throw ServerError.noPort
    }

    /// Wait for the browser to hit /auth/callback; resolves with the authorization code.
    func waitForCode(timeout: TimeInterval = 300) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            lock.lock()
            if finished {
                lock.unlock()
                cont.resume(throwing: ServerError.cancelled)
                return
            }
            continuation = cont
            lock.unlock()
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failure(ServerError.timeout))
            }
        }
    }

    func cancel() {
        finish(.failure(ServerError.cancelled))
    }

    // MARK: - Socket plumbing

    private static func bind(port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0, listen(fd, 16) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    private func finish(_ result: Result<String, Error>) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let cont = continuation
        continuation = nil
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        cont?.resume(with: result)
    }

    private func acceptLoop() {
        while true {
            lock.lock()
            let fd = listenFD
            lock.unlock()
            guard fd >= 0 else { return }
            var clientAddr = sockaddr()
            var clientLen = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(fd, &clientAddr, &clientLen)
            if client < 0 {
                if errno == EINTR { continue }
                return // listener closed
            }
            handleClient(client)
        }
    }

    private func handleClient(_ client: Int32) {
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var buffer = [UInt8](repeating: 0, count: 16384)
        var received = 0
        while received < buffer.count {
            let n = read(client, &buffer[received], buffer.count - received)
            if n <= 0 { break }
            received += n
            if let text = String(bytes: buffer[0..<received], encoding: .utf8), text.contains("\r\n\r\n") {
                break
            }
        }
        guard received > 0, let request = String(bytes: buffer[0..<received], encoding: .utf8) else {
            close(client)
            return
        }

        let firstLine = request
            .split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: true).first
            .map(String.init)
            ?? request.split(separator: "\n", maxSplits: 1).first.map(String.init)
            ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            close(client)
            return
        }
        let target = String(parts[1])

        guard target.hasPrefix("/auth/callback") else {
            respond(client, html: "<h2>Melon Tools</h2><p>Not found.</p>", status: "404 Not Found")
            close(client)
            return
        }

        let components = URLComponents(string: "http://localhost" + target)
        let items = components?.queryItems ?? []
        let code = items.first { $0.name == "code" }?.value
        let state = items.first { $0.name == "state" }?.value
        let errorParam = items.first { $0.name == "error" }?.value

        if let errorParam {
            respond(client, html: Self.failureHTML(errorParam))
            close(client)
            finish(.failure(ServerError.denied(Self.escape(errorParam))))
            return
        }
        guard let code, let state, state == expectedState else {
            respond(client, html: Self.failureHTML(L("OAuth state mismatch — the callback does not belong to this login attempt.")))
            close(client)
            finish(.failure(ServerError.stateMismatch))
            return
        }
        respond(client, html: Self.successHTML())
        close(client)
        finish(.success(code))
    }

    private func respond(_ client: Int32, html: String, status: String = "200 OK") {
        let body = """
        <!doctype html><html><head><meta charset="utf-8"><title>Melon Tools</title>
        <style>
        body{font-family:-apple-system,system-ui;background:#1a1a1c;color:#f5f5f7;display:grid;place-items:center;height:100vh;margin:0}
        .c{text-align:center;max-width:460px}.m{font-size:56px;margin-bottom:4px}
        h2{font-weight:600}p{color:#a2a2aa;font-size:14px}
        </style></head><body><div class="c">\(html)</div></body></html>
        """
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        var offset = 0
        let data = Array(response.utf8)
        while offset < data.count {
            let n = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return write(client, base.advanced(by: offset), data.count - offset)
            }
            if n <= 0 { break }
            offset += n
        }
    }

    private static func successHTML() -> String {
        "<div class=\"m\">🍉</div><h2>\(escape(L("Login complete")))</h2><p>\(escape(L("You can close this window and return to Melon Tools.")))</p>"
    }

    private static func failureHTML(_ reason: String) -> String {
        "<div class=\"m\">⚠️</div><h2>\(escape(L("Login failed")))</h2><p>\(escape(String(reason.prefix(300))))</p>"
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
