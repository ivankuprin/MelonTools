import Foundation

/// Melon Tools 2.0.0 task scheduler: domain model plus pure policy helpers.
///
/// Contract (see `MacOS/specs/scheduler-2.0.0.md`):
/// - file `~/Library/Application Support/MelonTools/scheduler.json`, 0600 and
///   atomic (`SecureFile`);
/// - history caps: 20 entries per task, 200 globally;
/// - result bodies are truncated to 64 KiB;
/// - the scheduler runs only while the app process is alive.

enum SchedulerLimits {
    static let resultByteLimit = 64 * 1024
    static let historyPerTask = 20
    static let historyGlobal = 200
    /// The scheduler wakes every 30 s; tolerance lets macOS coalesce the
    /// wake-up with other timers.
    static let tickInterval: TimeInterval = 30
    static let tickTolerance: TimeInterval = 5
    static let requestTimeout: TimeInterval = 300
    static let defaultIntervalMinutes = 60
    static let maximumIntervalMinutes = 30 * 24 * 60
}

enum SchedulerTaskStatus: String, Codable, CaseIterable {
    case never, ok, error, running

    var title: String {
        switch self {
        case .never: return L("Never")
        case .ok: return L("ok")
        case .error: return L("error")
        case .running: return L("running")
        }
    }
}

/// One scheduled prompt. Timestamps are stored as Unix epoch seconds — the
/// JSON contract is byte-for-byte stable and timezone-independent.
struct SchedulerTask: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var prompt: String
    var model: String
    var reasoningEffort: String?
    var intervalMinutes: Int
    var enabled: Bool
    var createdAt: TimeInterval
    var nextRunAt: TimeInterval?
    var lastRunAt: TimeInterval?
    var lastStatus: SchedulerTaskStatus
    var lastError: String?
    var lastResult: String
    var lastDurationMs: Int?
    var lastTokens: Int?

    /// Values the gateway accepts as `reasoning_effort`.
    static let reasoningEfforts = ["low", "medium", "high", "xhigh", "max"]

    init(
        id: String = UUID().uuidString,
        name: String,
        prompt: String = "",
        model: String = "",
        reasoningEffort: String? = nil,
        intervalMinutes: Int = SchedulerLimits.defaultIntervalMinutes,
        enabled: Bool = true,
        createdAt: TimeInterval = Date().timeIntervalSince1970,
        nextRunAt: TimeInterval? = nil,
        lastRunAt: TimeInterval? = nil,
        lastStatus: SchedulerTaskStatus = .never,
        lastError: String? = nil,
        lastResult: String = "",
        lastDurationMs: Int? = nil,
        lastTokens: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.intervalMinutes = intervalMinutes
        self.enabled = enabled
        self.createdAt = createdAt
        self.nextRunAt = nextRunAt
        self.lastRunAt = lastRunAt
        self.lastStatus = lastStatus
        self.lastError = lastError
        self.lastResult = lastResult
        self.lastDurationMs = lastDurationMs
        self.lastTokens = lastTokens
    }
}

/// One completed (or failed) run. `result` is already truncated to 64 KiB.
struct SchedulerHistoryEntry: Codable, Equatable {
    var taskId: String
    var at: TimeInterval
    var status: SchedulerTaskStatus
    var model: String
    var durationMs: Int?
    var tokens: Int?
    var result: String
    var error: String?
}

struct SchedulerFile: Codable, Equatable {
    var tasks: [SchedulerTask] = []
    var history: [SchedulerHistoryEntry] = []
}

/// Gateway endpoint and key the runner authenticates with.
struct SchedulerGateway: Equatable {
    var baseURL: String
    var apiKey: String
}

/// Pure scheduling decisions. Every function takes `now`, so the due policy
/// is testable without a live clock.
enum SchedulerPolicy {
    /// Tasks that must run at `now`: enabled, due, and not the task already
    /// running. Disabled tasks never become due.
    static func due(
        _ tasks: [SchedulerTask],
        now: Date,
        excluding runningID: String? = nil
    ) -> [SchedulerTask] {
        let stamp = now.timeIntervalSince1970
        return tasks.filter { task in
            guard task.enabled, task.id != runningID else { return false }
            guard let next = task.nextRunAt else { return false }
            return next <= stamp
        }
    }

    /// After a run (scheduled or manual) the next attempt is one full
    /// interval away. Missed intervals are never replayed, so a wake or a
    /// relaunch cannot produce a catch-up burst.
    static func nextRun(after date: Date, intervalMinutes: Int) -> Date {
        let minutes = max(1, min(intervalMinutes, SchedulerLimits.maximumIntervalMinutes))
        return date.addingTimeInterval(TimeInterval(minutes) * 60)
    }

    /// Cut a body to `limit` UTF-8 bytes without splitting a multi-byte
    /// character.
    static func truncatedResult(
        _ text: String,
        limit: Int = SchedulerLimits.resultByteLimit
    ) -> String {
        guard text.utf8.count > limit else { return text }
        var data = Data(text.utf8.prefix(limit))
        while !data.isEmpty {
            if let value = String(data: data, encoding: .utf8) { return value }
            data.removeLast()
        }
        return ""
    }

    /// Newest-first history with 20 entries per task and 200 global.
    static func trimHistory(_ entries: [SchedulerHistoryEntry]) -> [SchedulerHistoryEntry] {
        var perTask: [String: Int] = [:]
        var kept: [SchedulerHistoryEntry] = []
        for entry in entries {
            let count = perTask[entry.taskId, default: 0]
            guard count < SchedulerLimits.historyPerTask else { continue }
            perTask[entry.taskId] = count + 1
            kept.append(entry)
            if kept.count >= SchedulerLimits.historyGlobal { break }
        }
        return kept
    }
}

/// Picker section for the model list returned by `GET /v1/models`. The exact
/// id is always retained; the group only drives the menu label.
enum SchedulerModelGroup: String, CaseIterable, Identifiable {
    case pool
    case openCode
    case openRouter
    case claude
    case antigravity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pool: return L("Account pool")
        case .openCode: return "OpenCode"
        case .openRouter: return "OpenRouter"
        case .claude: return "Claude"
        case .antigravity: return "Antigravity"
        }
    }

    /// Antigravity serves slash-less `gemini-*`, `gpt-oss-*` and even some
    /// `claude-*` ids, so the registry check runs before the Claude prefix.
    static func group(for id: String) -> SchedulerModelGroup {
        if id.hasPrefix("opencode/") { return .openCode }
        if id.hasPrefix("openrouter/") { return .openRouter }
        if AntigravityModelRegistry.ids.contains(id) { return .antigravity }
        if id.hasPrefix("claude-") { return .claude }
        return .pool
    }
}

/// Timestamp formatting shared by the scheduler and the remaining Codex
/// views (this helper moved here when the 1.7 navigation was removed).
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
        return relative(date)
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "—" }
        return phrase(Date().timeIntervalSince(date), future: false)
    }

    /// “in 5 min” / “через 5 мин”.
    static func until(_ date: Date?) -> String {
        guard let date else { return "—" }
        return phrase(-Date().timeIntervalSince(date), future: true)
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

    private static func phrase(_ interval: TimeInterval, future: Bool) -> String {
        let ru = L10n.shared.code == "ru"
        let seconds = max(0, interval)
        let value: String
        if seconds < 60 {
            value = "\(Int(seconds)) " + (ru ? "с" : "s")
        } else if seconds < 3600 {
            value = "\(Int(seconds / 60)) " + (ru ? "мин" : "m")
        } else if seconds < 86400 {
            value = "\(Int(seconds / 3600)) " + (ru ? "ч" : "h")
        } else {
            value = "\(Int(seconds / 86400)) " + (ru ? "дн" : "d")
        }
        if future { return ru ? "через \(value)" : "in \(value)" }
        return ru ? "\(value) назад" : "\(value) ago"
    }
}
