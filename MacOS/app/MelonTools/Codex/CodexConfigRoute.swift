import Foundation

/// Clean-room editor for the Codex client route in `~/.codex/config.toml`.
///
/// The Codex app and CLI read this file when they start. To send their traffic
/// through the Melon Tools gateway we set a top-level `model_provider` key plus
/// a matching `[model_providers.<id>]` table (base URL, bearer token, responses
/// wire API) — the same shape other local API services use, so switching
/// between tools stays transparent.
///
/// Editing is line based and preserves everything else in the file. All
/// functions are pure `String → String` transforms so they can be unit tested.
enum CodexConfigRoute {
    static let providerID = "melon_local_access"
    static let defaultProviderName = "Melon Tools API"

    /// Value of the top-level `model_provider` key, if present.
    /// In TOML bare keys can only appear before the first table header.
    static func currentProvider(in text: String) -> String? {
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") { return nil }
            if let value = providerKeyValue(in: line) { return value }
        }
        return nil
    }

    /// Value of the top-level `model_catalog_json` key, if present.
    ///
    /// The Codex app refuses to boot when this key points at a missing file
    /// (“No such file or directory”). Route owners such as Cockpit Tools
    /// clean their catalog up when their route drops, so the reference can
    /// go stale behind the user's back.
    static func modelCatalogPath(in text: String) -> String? {
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") { return nil }
            if let value = rawValue(of: "model_catalog_json", in: line) { return value }
        }
        return nil
    }

    /// Inserts or replaces a top-level `key = "value"` line before the first
    /// table header. Used to point `model_catalog_json` at the Melon catalog.
    static func upsertTopLevelKey(_ key: String, value: String, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let firstHeader = lines.firstIndex {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[")
        } ?? lines.count
        let line = "\(key) = \"\(value)\""
        for index in 0..<firstHeader where rawValue(
            of: key,
            in: lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
        ) != nil {
            lines[index] = line
            return normalized(lines, endsWithNewline: text.hasSuffix("\n"))
        }
        // Insert right after the model_provider line when present, else at the top.
        var insertAt = 0
        for index in 0..<firstHeader where providerKeyValue(
            in: lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
        ) != nil {
            insertAt = index + 1
            break
        }
        lines.insert(line, at: insertAt)
        return normalized(lines, endsWithNewline: text.hasSuffix("\n"))
    }

    /// Removes the top-level `model_catalog_json` line (a dangling reference
    /// would stop the Codex app from starting). The route backup keeps the
    /// original line, so “remove routing” restores it intact.
    static func removingTopLevelKey(_ key: String, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let firstHeader = lines.firstIndex {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[")
        } ?? lines.count
        for index in 0..<firstHeader where rawValue(
            of: key,
            in: lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
        ) != nil {
            lines.remove(at: index)
            break
        }
        return normalized(lines, endsWithNewline: text.hasSuffix("\n"))
    }

    /// Raw value of `key = …` in a single line: quotes stripped, trailing
    /// comment removed. `nil` when the line is not an assignment for `key`.
    private static func rawValue(of key: String, in line: String) -> String? {
        guard line.hasPrefix(key) else { return nil }
        let rest = line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("=") else { return nil }
        var value = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
        if let hash = value.firstIndex(of: "#") {
            value = String(value[..<hash]).trimmingCharacters(in: .whitespaces)
        }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    /// `model_provider = "…"` compared key by key, not by prefix.
    private static func providerKeyValue(in line: String) -> String? {
        guard let value = rawValue(of: "model_provider", in: line), value.isEmpty == false else {
            return nil
        }
        return value
    }

    /// Writes (or updates) the Melon route. Idempotent: running it twice on the
    /// same input produces the same output.
    static func upsertRoute(
        in text: String,
        baseURL: String,
        token: String,
        providerName: String = defaultProviderName
    ) -> String {
        var lines = text.components(separatedBy: "\n")

        // 1. Top-level `model_provider` — replace ours, or insert at the very top.
        let firstHeader = lines.firstIndex {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[")
        } ?? lines.count
        var providerLineIndex: Int?
        for index in 0..<firstHeader where providerKeyValue(
            in: lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
        ) != nil {
            providerLineIndex = index
            break
        }
        let providerLine = "model_provider = \"\(providerID)\""
        if let providerLineIndex {
            lines[providerLineIndex] = providerLine
        } else {
            lines.insert(providerLine, at: 0)
            if lines.count > 1, lines[1].isEmpty == false {
                lines.insert("", at: 1)
            }
        }

        // 2. `[model_providers.<id>]` table — replace the existing block or append.
        let block: [String] = [
            "[model_providers.\(providerID)]",
            "name = \"\(providerName)\"",
            "base_url = \"\(baseURL)\"",
            "wire_api = \"responses\"",
            "requires_openai_auth = true",
            "experimental_bearer_token = \"\(token)\"",
            "supports_websockets = false",
        ]
        if let bounds = tableBounds(of: providerID, in: lines) {
            lines.replaceSubrange(bounds.start..<bounds.end, with: block)
        } else {
            if lines.isEmpty == false, lines.last?.isEmpty == false {
                lines.append("")
            }
            lines.append(contentsOf: block)
        }

        return normalized(lines, endsWithNewline: text.hasSuffix("\n"))
    }

    /// Removes the Melon route: our provider table and — only when it points at
    /// us — the top-level `model_provider` key.
    static func removeRoute(in text: String) -> String {
        var lines = text.components(separatedBy: "\n")

        if let bounds = tableBounds(of: providerID, in: lines) {
            lines.removeSubrange(bounds.start..<bounds.end)
        }

        let firstHeader = lines.firstIndex {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[")
        } ?? lines.count
        for index in 0..<firstHeader where providerKeyValue(
            in: lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
        ) == providerID {
            lines.remove(at: index)
            break
        }

        return normalized(lines, endsWithNewline: text.hasSuffix("\n"))
    }

    // MARK: - Helpers

    /// Line range of `[model_providers.<id>]` — from its header to the next
    /// table header (or end of file).
    private static func tableBounds(of id: String, in lines: [String]) -> (start: Int, end: Int)? {
        let header = "[model_providers.\(id)]"
        var start: Int?
        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line == header {
                if start == nil { start = index }
                continue
            }
            if let s = start, index > s, line.hasPrefix("[") {
                return (s, index)
            }
        }
        if let s = start { return (s, lines.count) }
        return nil
    }

    /// Keeps the trailing-newline state of the original file stable.
    private static func normalized(_ lines: [String], endsWithNewline: Bool) -> String {
        var result = lines
        if endsWithNewline {
            if result.last?.isEmpty != true { result.append("") }
        } else if result.last?.isEmpty == true {
            result.removeLast()
        }
        return result.joined(separator: "\n")
    }
}
