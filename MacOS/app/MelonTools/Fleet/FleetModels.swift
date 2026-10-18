import Foundation

// MARK: - Unit identity

enum FleetUnit: String, CaseIterable, Identifiable, Codable {
    case gemini, grok, codex

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .gemini: return "Gemini"
        case .grok: return "Grok"
        case .codex: return "Codex"
        }
    }
    var cliName: String {
        switch self {
        case .gemini: return "agy"
        case .grok: return "grok"
        case .codex: return "codex"
        }
    }
    /// MCP tool names exposed by each unit's server (units/<unit>/adapter.mjs).
    var tools: [(name: String, summary: String, argsHint: String)] {
        switch self {
        case .gemini:
            return [
                ("gemini_research", "Grounded web research", #"{"prompt": "..."}"#),
                ("gemini_deep_research", "Multi-source deep research", #"{"question": "..."}"#),
                ("gemini_image", "Image generation", #"{"prompt": "..."}"#),
                ("gemini_models", "List available models", "{}"),
            ]
        case .grok:
            return [
                ("grok_research", "Fast research sweep", #"{"prompt": "...", "cwd": "/path"}"#),
                ("grok_code_review", "Mechanical code review", #"{"prompt": "...", "cwd": "/path"}"#),
                ("grok_image", "Image generation", #"{"prompt": "..."}"#),
                ("grok_image_edit", "Image-to-image editing", #"{"prompt": "...", "path": "..."}"#),
                ("grok_models", "List available models", "{}"),
            ]
        case .codex:
            return [
                ("codex_research", "Grounded research with web search", #"{"prompt": "...", "cwd": "/path"}"#),
                ("codex_code_review", "Strongest code review in the fleet", #"{"prompt": "...", "cwd": "/path"}"#),
                ("codex_image", "Image generation (gpt-image-2)", #"{"prompt": "..."}"#),
                ("codex_models", "List available models", "{}"),
            ]
        }
    }

    /// Model catalog heads (units/<unit>/models.js).
    var modelCatalog: [(id: String, label: String, effort: String)] {
        switch self {
        case .codex:
            return [
                ("gpt-6.1-sol", "GPT-6.1 Sol", "xhigh"),
                ("gpt-6-astra", "GPT-6 Astra", "xhigh"),
                ("gpt-6-sol", "GPT-6 Sol", "high"),
                ("gpt-6-luna", "GPT-6 Luna", "medium"),
                ("gpt-5.6-terra", "GPT-5.6 Terra", "high"),
                ("gpt-5.6-luna", "GPT-5.6 Luna", "medium"),
                ("gpt-5.6-sol", "GPT-5.6 Sol", "high"),
            ]
        case .grok:
            return [
                ("grok-4.7", "Grok 4.7", "high"),
                ("grok-4.7-build-fast", "Grok 4.7 Build (fast)", "high"),
                ("grok-4.6", "Grok 4.6", "high"),
            ]
        case .gemini:
            return [
                ("Gemini 3.8 Flash (High)", "Gemini 3.8 Flash (High)", "high"),
                ("Gemini 4 Argon (High)", "Gemini 4 Argon (High)", "high"),
                ("Claude Opus 5.5 (High)", "Claude Opus 5.5 (High)", "high"),
            ]
        }
    }
}

// MARK: - Status feed (schema 2)

struct FleetStatusSnapshot: Codable, Identifiable, Equatable {
    let schema: Int?
    let unit: String
    let pid: Int
    let active: [FleetActiveCall]?
    let lastEvent: FleetLastEvent?
    let updatedAt: String?

    var id: String { "\(unit)-\(pid)" }
    var fleetUnit: FleetUnit? { FleetUnit(rawValue: unit) }
}

struct FleetActiveCall: Codable, Identifiable, Equatable {
    let id: String
    let tool: String?
    let model: String?
    let effort: String?
    let promptPreview: String?
    let startedAt: String?
    let resultId: String?

    var startedDate: Date? { startedAt.flatMap(ISODate.parse) }
}

struct FleetLastEvent: Codable, Equatable {
    let tool: String?
    let status: String?       // ok | error | cancelled
    let endedAt: String?
    let durationMs: Int?
    let error: String?
    let resultId: String?
    let usage: FleetUsage?
    let partial: Bool?
    let detached: Bool?

    var endedDate: Date? { endedAt.flatMap(ISODate.parse) }
    var mtStatus: MTStatus {
        switch status {
        case "ok": return .ok
        case "error": return .error
        case "cancelled": return .warn
        default: return .absent
        }
    }
}

struct FleetUsage: Codable, Equatable {
    let input: Int?
    let cachedInput: Int?
    let output: Int?
    let reasoning: Int?
}

// MARK: - Fleet log (ndjson)

struct FleetLogEvent: Codable, Identifiable {
    let schema: Int?
    let ts: String?
    let unit: String
    let event: String          // start | end
    let logId: String?
    let tool: String?
    let model: String?
    let promptPreview: String?
    let resultId: String?
    // end-only:
    let status: String?
    let durationMs: Int?
    let error: String?
    let usage: FleetUsage?
    let partial: Bool?
    let detached: Bool?

    enum CodingKeys: String, CodingKey {
        case schema, ts, unit, event, tool, model, promptPreview, resultId
        case status, durationMs, error, usage, partial, detached
        case logId = "id"
    }

    var uid: String { "\(logId ?? UUID().uuidString)-\(event)-\(ts ?? "")" }
    var id: String { uid }

    var tsDate: Date? { ts.flatMap(ISODate.parse) }
    var fleetUnit: FleetUnit? { FleetUnit(rawValue: unit) }
}

// MARK: - Result spool

struct FleetResultFile: Identifiable {
    let unit: String
    let resultId: String
    let path: String
    var tool: String?
    var model: String?
    var status: String?
    var startedAt: String?
    var endedAt: String?
    var durationMs: Int?
    var usageLine: String?
    var cwd: String?
    var promptPreview: String?
    var partial: Bool?
    var detached: Bool?
    var body: String = ""

    var id: String { "\(unit)/\(resultId)" }
    var fleetUnit: FleetUnit? { FleetUnit(rawValue: unit) }
    var mtStatus: MTStatus {
        switch status {
        case "ok": return .ok
        case "error": return .error
        case "cancelled": return .warn
        default: return .absent
        }
    }
}

// MARK: - Doctor report

struct DoctorReport {
    struct Section {
        var unit: String
        var displayName: String
        var rows: [DoctorRow]
    }
    struct DoctorRow {
        var key: String
        var value: String
        var status: MTStatus
    }
    var header: String = ""
    var globals: [DoctorRow] = []
    var sections: [Section] = []
    var next: String?
    var rawOutput: String = ""
    var exitCode: Int32 = 0

    var hasFaults: Bool {
        exitCode != 0 || sections.contains { $0.rows.contains { $0.status == .error } }
    }

    /// Parse `melon-fleet doctor` stdout.
    static func parse(_ output: String, exitCode: Int32) -> DoctorReport {
        var report = DoctorReport()
        report.rawOutput = output
        report.exitCode = exitCode

        var currentSection: Section?

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { continue }

            // Header: "FLEET DOCTOR · ..."
            if trimmed.hasPrefix("FLEET DOCTOR") {
                report.header = trimmed
                continue
            }

            // Unit section: "── gemini (Gemini) ─────"
            if trimmed.hasPrefix("── ") {
                if let currentSection { report.sections.append(currentSection) }
                let body = trimmed.drop(while: { $0 == "─" || $0 == " " })
                let namePart = body.prefix(while: { $0 != "─" }).trimmingCharacters(in: .whitespaces)
                // namePart ~ "gemini (Gemini)"
                let unitKey = namePart.split(separator: " ").first.map(String.init) ?? namePart
                let display: String = {
                    if let open = namePart.firstIndex(of: "("), let close = namePart.firstIndex(of: ")"), open < close {
                        return String(namePart[namePart.index(after: open)..<close])
                    }
                    return unitKey
                }()
                currentSection = Section(unit: unitKey, displayName: display, rows: [])
                continue
            }

            // Top-level row: "key    value"
            let isIndented = line.hasPrefix("  ")
            if !isIndented {
                let (key, value) = Self.splitRow(trimmed)
                if let key {
                    if key == "next" {
                        report.next = value
                    } else {
                        report.globals.append(DoctorRow(key: key, value: value, status: Self.inferStatus(value)))
                    }
                }
                continue
            }

            // Indented inside unit section
            guard var section = currentSection else { continue }
            let stripped = trimmed
            if stripped.hasPrefix("KEY") && stripped.contains("SOURCE") {
                continue
            }
            let (key, value) = Self.splitRow(stripped)
            if let key {
                section.rows.append(DoctorRow(key: key, value: value, status: Self.inferStatus(value)))
                currentSection = section
            }
        }
        if let currentSection { report.sections.append(currentSection) }
        return report
    }

    private static func splitRow(_ line: String) -> (String?, String) {
        // Rows look like: "version       1.6.0 · latest 1.6.0" or "bin         agy → ..."
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else {
            return (line.isEmpty ? nil : line, "")
        }
        return (String(parts[0]), String(parts[1]).trimmingCharacters(in: .whitespaces))
    }

    static func inferStatus(_ value: String) -> MTStatus {
        let v = value.lowercased()
        if v.hasPrefix("ok") { return .ok }
        if v.contains("no faults") { return .ok }
        if v.contains("fault") { return .error }
        if v.contains("signed out") || v.contains("not found") || v.contains("breached") { return .error }
        if v.contains("not registered") || v.contains("absent") || v.contains("missing") { return .warn }
        if v.hasPrefix("unknown") { return .warn }
        return .absent
    }
}

// MARK: - ISO date helper

enum ISODate {
    private static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ string: String) -> Date? {
        withFractional.date(from: string) ?? plain.date(from: string)
    }

    static func relative(_ string: String?) -> String {
        guard let string, let date = parse(string) else { return "—" }
        let interval = Date().timeIntervalSince(date)
        let ru = L10n.shared.code == "ru"
        if interval < 60 { return ru ? "\(Int(interval)) с назад" : "\(Int(interval))s ago" }
        if interval < 3600 { return ru ? "\(Int(interval / 60)) мин назад" : "\(Int(interval / 60))m ago" }
        if interval < 86400 { return ru ? "\(Int(interval / 3600)) ч назад" : "\(Int(interval / 3600))h ago" }
        return ru ? "\(Int(interval / 86400)) дн назад" : "\(Int(interval / 86400))d ago"
    }

    static func duration(_ ms: Int?) -> String {
        guard let ms else { return "—" }
        let ru = L10n.shared.code == "ru"
        if ms < 1000 { return "\(ms) " + (ru ? "мс" : "ms") }
        let s = Double(ms) / 1000.0
        if s < 60 { return String(format: "%.1f ", s) + (ru ? "с" : "s") }
        let m = s / 60.0
        return String(format: "%.1f ", m) + (ru ? "мин" : "min")
    }
}
