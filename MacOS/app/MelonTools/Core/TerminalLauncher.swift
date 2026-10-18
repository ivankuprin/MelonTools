import AppKit
import Foundation

/// Opens Terminal with a shell script. Used by Codex instances and the gateway launcher.
enum TerminalLauncher {

    /// Run a shell script in a new Terminal window. Returns an error message, or nil on success.
    @discardableResult
    static func run(_ script: String) -> String? {
        let appleScript = "tell application \"Terminal\" to do script \(quoteAppleScript(script))"
        var error: NSDictionary?
        NSAppleScript(source: appleScript)?.executeAndReturnError(&error)
        if let error {
            return "\(error)"
        }
        return nil
    }

    /// POSIX single-quote a value for safe interpolation into a shell script.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Quote a value for an AppleScript string literal. Raw newlines inside
    /// the literal break NSAppleScript compilation, so they are flattened.
    static func quoteAppleScript(_ value: String) -> String {
        let flattened = value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let escaped = flattened
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
