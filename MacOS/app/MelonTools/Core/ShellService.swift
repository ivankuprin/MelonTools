import Foundation

/// Result of a one-shot shell command.
struct ShellResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var ok: Bool { exitCode == 0 }
}

enum ShellError: Error, LocalizedError {
    case launchFailed(String)
    case nonZeroExit(code: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let reason): return "Failed to launch process: \(reason)"
        case .nonZeroExit(let code, let stderr):
            return "Command failed (exit \(code)): \(stderr.isEmpty ? "no stderr" : String(stderr.prefix(400)))"
        }
    }
}

/// Runs external processes. All calls are async and never block the main thread.
enum ShellService {

    /// Locate a binary in PATH (or take an absolute path as-is).
    static func which(_ name: String) -> String? {
        if name.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        // ask zsh for the login-shell PATH (GUI apps get a minimal PATH)
        if let resolved = loginShellWhich(name) { return resolved }
        let env = ProcessInfo.processInfo.environment
        let paths = (env["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin")
            .split(separator: ":").map(String.init)
        for dir in paths {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Non-blocking variant: the login-shell probe (two zsh spawns) runs off
    /// the calling thread, so a heavy `.zshrc` cannot freeze the UI.
    static func whichAsync(_ name: String) async -> String? {
        if name.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        if let resolved = await Task.detached(priority: .utility) { loginShellWhich(name) }.value {
            return resolved
        }
        let env = ProcessInfo.processInfo.environment
        let paths = (env["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin")
            .split(separator: ":").map(String.init)
        for dir in paths {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func loginShellWhich(_ name: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        // The name is passed as an argument, never interpolated into the shell
        // program: `$1` is the searched command, `--` becomes `$0`.
        p.arguments = ["-lc", "command -v \"$1\"", "--", name]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        // Read before waiting: a large output would otherwise deadlock on a
        // full pipe buffer.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let out = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let out, !out.isEmpty, FileManager.default.isExecutableFile(atPath: out) else { return nil }
        return out
    }

    /// One-shot run: capture stdout+stderr fully.
    static func run(
        _ executable: String,
        _ arguments: [String],
        cwd: String? = nil,
        env extraEnv: [String: String]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { continuation in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = arguments
            if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin"
            if let extraEnv { for (k, v) in extraEnv { env[k] = v } }
            p.environment = env

            let outPipe = Pipe(); let errPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = errPipe

            var outData = Data(); var errData = Data()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }

            p.terminationHandler = { proc in
                group.wait()
                let result = ShellResult(
                    exitCode: proc.terminationStatus,
                    stdout: String(data: outData, encoding: .utf8) ?? "",
                    stderr: String(data: errData, encoding: .utf8) ?? ""
                )
                continuation.resume(returning: result)
            }

            do {
                try p.run()
            } catch {
                continuation.resume(throwing: ShellError.launchFailed(error.localizedDescription))
                return
            }

            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard p.isRunning else { return }
                    p.terminate()
                    // Escalate when the child ignores SIGTERM.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                    }
                }
            }
        }
    }

    /// Long-running process with line-by-line stdout streaming (for `call`, `doctor`, gateway).
    final class Stream: @unchecked Sendable {
        private let process = Process()
        private let outPipe = Pipe()
        private let errPipe = Pipe()
        // Buffers are touched from readabilityHandler threads and from the
        // termination handler — one lock serializes all access.
        private let bufferLock = NSLock()
        private var outBuffer = Data()
        private var errBuffer = Data()
        var onStdoutLine: ((String) -> Void)?
        var onStderrLine: ((String) -> Void)?
        var onExit: ((Int32) -> Void)?
        private(set) var isRunning = false

        func start(_ executable: String, _ arguments: [String], cwd: String? = nil, env extraEnv: [String: String]? = nil) throws {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin"
            if let extraEnv { for (k, v) in extraEnv { env[k] = v } }
            process.environment = env
            process.standardOutput = outPipe
            process.standardError = errPipe

            outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard let self, !data.isEmpty else { return }
                self.consume(data, isErr: false)
            }
            errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard let self, !data.isEmpty else { return }
                self.consume(data, isErr: true)
            }
            process.terminationHandler = { [weak self] proc in
                guard let self else { return }
                self.outPipe.fileHandleForReading.readabilityHandler = nil
                self.errPipe.fileHandleForReading.readabilityHandler = nil
                // Give in-flight readabilityHandler blocks a beat to finish
                // before flushing under the lock.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                    self.flush()
                    self.isRunning = false
                    self.onExit?(proc.terminationStatus)
                }
            }
            try process.run()
            isRunning = true
        }

        private func consume(_ data: Data, isErr: Bool) {
            bufferLock.lock()
            if isErr { errBuffer.append(data) } else { outBuffer.append(data) }
            drainLocked(isErr: isErr)
            bufferLock.unlock()
        }

        /// Call only while holding `bufferLock`.
        private func drainLocked(isErr: Bool) {
            let callback = isErr ? onStderrLine : onStdoutLine
            guard let callback else { return }
            var buffer = isErr ? errBuffer : outBuffer
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                if let line = String(data: lineData, encoding: .utf8) {
                    callback(line)
                }
            }
            if isErr { errBuffer = buffer } else { outBuffer = buffer }
        }

        private func flush() {
            bufferLock.lock()
            let out = outBuffer
            let err = errBuffer
            outBuffer.removeAll()
            errBuffer.removeAll()
            bufferLock.unlock()
            if let line = String(data: out, encoding: .utf8), !line.isEmpty { onStdoutLine?(line) }
            if let line = String(data: err, encoding: .utf8), !line.isEmpty { onStderrLine?(line) }
        }

        func cancel() {
            if process.isRunning { process.terminate() }
        }

        var pid: Int32 { process.processIdentifier }
    }

    /// Run and stream lines to callbacks (async wrapper around Stream).
    static func stream(
        _ executable: String,
        _ arguments: [String],
        cwd: String? = nil,
        env extraEnv: [String: String]? = nil,
        onStdout: @escaping (String) -> Void,
        onStderr: @escaping (String) -> Void
    ) async -> Int32 {
        await withCheckedContinuation { continuation in
            do {
                try streamCancelable(
                    executable,
                    arguments,
                    cwd: cwd,
                    env: extraEnv,
                    onExit: { continuation.resume(returning: $0) },
                    onStdout: onStdout,
                    onStderr: onStderr
                )
            } catch {
                DispatchQueue.main.async {
                    onStderr("launch failed: \(error.localizedDescription)")
                }
                continuation.resume(returning: -1)
            }
        }
    }

    /// A started stream the caller can cancel (terminate the child process).
    final class StreamHandle {
        private let stream: Stream
        fileprivate init(_ stream: Stream) { self.stream = stream }
        public func cancel() { stream.cancel() }
        public var pid: Int32 { stream.pid }
    }

    /// Starts a streaming run and returns a cancellable handle at once.
    /// Exit (including a caller-initiated cancel) lands in `onExit`.
    static func streamCancelable(
        _ executable: String,
        _ arguments: [String],
        cwd: String? = nil,
        env extraEnv: [String: String]? = nil,
        onExit: @escaping (Int32) -> Void,
        onStdout: @escaping (String) -> Void,
        onStderr: @escaping (String) -> Void
    ) throws -> StreamHandle {
        let stream = Stream()
        stream.onStdoutLine = { line in
            DispatchQueue.main.async { onStdout(line) }
        }
        stream.onStderrLine = { line in
            DispatchQueue.main.async { onStderr(line) }
        }
        stream.onExit = { code in
            DispatchQueue.main.async { onExit(code) }
        }
        try stream.start(executable, arguments, cwd: cwd, env: extraEnv)
        return StreamHandle(stream)
    }
}
