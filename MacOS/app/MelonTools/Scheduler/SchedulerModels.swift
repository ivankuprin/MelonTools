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

/// How a task decides its next fire time. `.interval` keeps the 2.0.0
/// behavior; `.cron` evaluates `cronExpression` in `timeZoneIdentifier`.
enum SchedulerScheduleKind: String, Codable, CaseIterable, Identifiable {
    case interval
    case cron

    var id: String { rawValue }

    var title: String {
        switch self {
        case .interval: return L("Interval")
        case .cron: return L("Cron")
        }
    }
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
///
/// Decoding is backward compatible with 2.0.0 files: missing
/// `scheduleKind`/`cronExpression`/`timeZoneIdentifier` mean an interval task
/// in the current system time zone.
struct SchedulerTask: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var prompt: String
    var model: String
    var reasoningEffort: String?
    var intervalMinutes: Int
    var scheduleKind: SchedulerScheduleKind
    var cronExpression: String?
    var timeZoneIdentifier: String?
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

    enum CodingKeys: String, CodingKey {
        case id, name, prompt, model, reasoningEffort, intervalMinutes
        case scheduleKind, cronExpression, timeZoneIdentifier
        case enabled, createdAt, nextRunAt, lastRunAt, lastStatus, lastError
        case lastResult, lastDurationMs, lastTokens
    }

    init(
        id: String = UUID().uuidString,
        name: String,
        prompt: String = "",
        model: String = "",
        reasoningEffort: String? = nil,
        intervalMinutes: Int = SchedulerLimits.defaultIntervalMinutes,
        scheduleKind: SchedulerScheduleKind = .interval,
        cronExpression: String? = nil,
        timeZoneIdentifier: String? = nil,
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
        self.scheduleKind = scheduleKind
        self.cronExpression = cronExpression
        self.timeZoneIdentifier = timeZoneIdentifier
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        prompt = try container.decode(String.self, forKey: .prompt)
        model = try container.decode(String.self, forKey: .model)
        reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
        intervalMinutes = try container.decode(Int.self, forKey: .intervalMinutes)
        // Unknown raw values (a newer file) fall back to interval instead of
        // failing the whole file.
        if let raw = try container.decodeIfPresent(String.self, forKey: .scheduleKind),
           let kind = SchedulerScheduleKind(rawValue: raw) {
            scheduleKind = kind
        } else {
            scheduleKind = .interval
        }
        cronExpression = try container.decodeIfPresent(String.self, forKey: .cronExpression)
        timeZoneIdentifier = try container.decodeIfPresent(String.self, forKey: .timeZoneIdentifier)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        createdAt = try container.decode(TimeInterval.self, forKey: .createdAt)
        nextRunAt = try container.decodeIfPresent(TimeInterval.self, forKey: .nextRunAt)
        lastRunAt = try container.decodeIfPresent(TimeInterval.self, forKey: .lastRunAt)
        lastStatus = try container.decode(SchedulerTaskStatus.self, forKey: .lastStatus)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        lastResult = try container.decode(String.self, forKey: .lastResult)
        lastDurationMs = try container.decodeIfPresent(Int.self, forKey: .lastDurationMs)
        lastTokens = try container.decodeIfPresent(Int.self, forKey: .lastTokens)
    }

    /// Time zone used to evaluate a cron expression. `nil` means the current
    /// system zone, so an unset task follows the Mac.
    var resolvedTimeZone: TimeZone {
        timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current
    }

    /// Non-nil when the schedule cannot be stored. The editor shows the same
    /// message and the store refuses to persist such a task.
    var scheduleValidationError: String? {
        Self.scheduleValidationError(
            scheduleKind: scheduleKind,
            cronExpression: cronExpression,
            timeZoneIdentifier: timeZoneIdentifier,
            intervalMinutes: intervalMinutes
        )
    }

    static func scheduleValidationError(
        scheduleKind: SchedulerScheduleKind,
        cronExpression: String?,
        timeZoneIdentifier: String?,
        intervalMinutes: Int
    ) -> String? {
        if let timeZoneIdentifier,
           !timeZoneIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           TimeZone(identifier: timeZoneIdentifier) == nil {
            return L("Unknown time zone identifier.")
        }
        switch scheduleKind {
        case .interval:
            guard intervalMinutes >= 1 else {
                return L("Interval must be at least 1 minute.")
            }
            return nil
        case .cron:
            let expression = (cronExpression ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !expression.isEmpty else { return L("Enter a cron expression.") }
            do {
                let cron = try SchedulerCron.parse(expression)
                let zone = timeZoneIdentifier
                    .flatMap(TimeZone.init(identifier:)) ?? .current
                guard cron.nextRun(after: Date(), timeZone: zone) != nil else {
                    return L("No upcoming run for this cron expression.")
                }
                return nil
            } catch {
                return (error as? LocalizedError)?.errorDescription
                    ?? L("Invalid cron expression.")
            }
        }
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

/// Why a cron expression was rejected. The messages are user-facing: the
/// editor shows the same text and the store refuses to save the task.
enum SchedulerCronError: Error, Equatable, LocalizedError {
    case fieldCount(Int)
    case invalidValue(String)
    case outOfRange(String)
    case invalidRange(String)
    case invalidStep(String)

    var errorDescription: String? {
        switch self {
        case .fieldCount(let count):
            return String(
                format: L("A cron expression needs 5 fields (minute hour day month weekday), got %d."),
                count
            )
        case .invalidValue(let field):
            return String(format: L("Invalid cron value in the %@ field."), field)
        case .outOfRange(let field):
            return String(format: L("Cron value is out of range in the %@ field."), field)
        case .invalidRange(let field):
            return String(format: L("Cron range must be ascending in the %@ field."), field)
        case .invalidStep(let field):
            return String(format: L("Cron step must be greater than zero in the %@ field."), field)
        }
    }
}

/// Pure five-field cron engine: parse once, then compute the next fire time in
/// a specific time zone with `Calendar`. No timers and no global state.
///
/// Supported: `*`, numbers, lists (`1,15`), ranges (`1-5`), steps (`*/15`,
/// `1-5/2`, `5/10`), month/day names and Sunday as `0` or `7`.
struct SchedulerCron: Equatable {
    let expression: String
    let minutes: Set<Int>
    let hours: Set<Int>
    let daysOfMonth: Set<Int>
    let months: Set<Int>
    let daysOfWeek: Set<Int>
    /// Vixie cron rule: when both day fields are restricted, either may match.
    let dayOfMonthRestricted: Bool
    let dayOfWeekRestricted: Bool

    private enum Field: String {
        case minute, hour, dayOfMonth, month, dayOfWeek

        var title: String {
            switch self {
            case .minute: return L("minute")
            case .hour: return L("hour")
            case .dayOfMonth: return L("day of month")
            case .month: return L("month")
            case .dayOfWeek: return L("day of week")
            }
        }

        var bounds: ClosedRange<Int> {
            switch self {
            case .minute: return 0...59
            case .hour: return 0...23
            case .dayOfMonth: return 1...31
            case .month: return 1...12
            case .dayOfWeek: return 0...7
            }
        }

        var names: [String: Int] {
            switch self {
            case .month:
                return [
                    "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                    "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
                    "january": 1, "february": 2, "march": 3, "april": 4, "june": 6,
                    "july": 7, "august": 8, "september": 9, "october": 10,
                    "november": 11, "december": 12,
                ]
            case .dayOfWeek:
                return [
                    "sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6,
                    "sunday": 0, "monday": 1, "tuesday": 2, "wednesday": 3,
                    "thursday": 4, "friday": 5, "saturday": 6,
                ]
            default:
                return [:]
            }
        }
    }

    static func parse(_ expression: String) throws -> SchedulerCron {
        let fields = expression
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard fields.count == 5 else { throw SchedulerCronError.fieldCount(fields.count) }

        let minute = try parseField(fields[0], field: .minute, acceptsNames: false)
        let hour = try parseField(fields[1], field: .hour, acceptsNames: false)
        let dayOfMonth = try parseField(fields[2], field: .dayOfMonth, acceptsNames: false)
        let month = try parseField(fields[3], field: .month, acceptsNames: true)
        let dayOfWeek = try parseField(fields[4], field: .dayOfWeek, acceptsNames: true)

        return SchedulerCron(
            expression: expression,
            minutes: minute.values,
            hours: hour.values,
            daysOfMonth: dayOfMonth.values,
            months: month.values,
            daysOfWeek: dayOfWeek.values,
            dayOfMonthRestricted: dayOfMonth.restricted,
            dayOfWeekRestricted: dayOfWeek.restricted
        )
    }

    private static func parseField(
        _ text: String,
        field: Field,
        acceptsNames: Bool
    ) throws -> (values: Set<Int>, restricted: Bool) {
        let lower = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !lower.isEmpty else { throw SchedulerCronError.invalidValue(field.title) }
        // A field that starts with `*` is unrestricted even with a step, which
        // matches the original cron behavior for `*/n`.
        let restricted = !lower.hasPrefix("*")
        var result: Set<Int> = []

        for part in lower.split(separator: ",", omittingEmptySubsequences: false) {
            let partText = String(part)
            guard !partText.isEmpty else { throw SchedulerCronError.invalidValue(field.title) }

            let pieces = partText.split(separator: "/", omittingEmptySubsequences: false)
            guard pieces.count <= 2 else { throw SchedulerCronError.invalidValue(field.title) }

            let step: Int
            if pieces.count == 2 {
                guard let parsed = Int(pieces[1]), parsed > 0 else {
                    throw SchedulerCronError.invalidStep(field.title)
                }
                step = parsed
            } else {
                step = 1
            }

            let base = String(pieces[0])
            guard !base.isEmpty else { throw SchedulerCronError.invalidValue(field.title) }

            let bounds: ClosedRange<Int>
            if base == "*" {
                bounds = field.bounds
            } else if base.contains("-") {
                let rangeParts = base.split(separator: "-", omittingEmptySubsequences: false)
                guard rangeParts.count == 2 else {
                    throw SchedulerCronError.invalidValue(field.title)
                }
                let low = try parseValue(String(rangeParts[0]), field: field, acceptsNames: acceptsNames)
                let high = try parseValue(String(rangeParts[1]), field: field, acceptsNames: acceptsNames)
                guard low <= high else { throw SchedulerCronError.invalidRange(field.title) }
                bounds = low...high
            } else {
                let single = try parseValue(base, field: field, acceptsNames: acceptsNames)
                // `5/15` means "from 5 to the end, every 15".
                bounds = pieces.count == 2 ? single...field.bounds.upperBound : single...single
            }

            var value = bounds.lowerBound
            while value <= bounds.upperBound {
                result.insert(field == .dayOfWeek && value == 7 ? 0 : value)
                value += step
            }
        }
        return (result, restricted)
    }

    private static func parseValue(
        _ text: String,
        field: Field,
        acceptsNames: Bool
    ) throws -> Int {
        if text.allSatisfy({ $0.isNumber }), let number = Int(text) {
            guard field.bounds.contains(number) else {
                throw SchedulerCronError.outOfRange(field.title)
            }
            return number
        }
        guard acceptsNames, let named = field.names[text] else {
            throw SchedulerCronError.invalidValue(field.title)
        }
        return named
    }

    /// First fire instant `>= date` in `timeZone`, or `nil` when the
    /// expression has no match within the next ~366 days.
    func nextRun(after date: Date, timeZone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")

        guard let minuteStart = calendar.dateInterval(of: .minute, for: date)?.start,
              var day = calendar.dateInterval(of: .day, for: minuteStart)?.start else {
            return nil
        }

        let second = calendar.component(.second, from: date)
        let nanosecond = calendar.component(.nanosecond, from: date)
        let searchStart = (second > 0 || nanosecond > 0)
            ? minuteStart.addingTimeInterval(60)
            : minuteStart

        let orderedHours = hours.sorted()
        let orderedMinutes = minutes.sorted()

        for _ in 0..<367 {
            let components = calendar.dateComponents([.month, .day, .weekday], from: day)
            if let month = components.month,
               let dayOfMonth = components.day,
               let weekday = components.weekday,
               months.contains(month),
               matchesDay(dayOfMonth: dayOfMonth, cronWeekday: weekday - 1) {
                for hour in orderedHours {
                    for minute in orderedMinutes {
                        guard let candidate = calendar.date(
                            bySettingHour: hour,
                            minute: minute,
                            second: 0,
                            of: day
                        ) else { continue } // DST gap: the time does not exist.
                        if candidate >= searchStart { return candidate }
                    }
                }
            }
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else {
                return nil
            }
            day = calendar.startOfDay(for: nextDay)
        }
        return nil
    }

    private func matchesDay(dayOfMonth: Int, cronWeekday: Int) -> Bool {
        let byMonthDay = daysOfMonth.contains(dayOfMonth)
        let byWeekday = daysOfWeek.contains(cronWeekday)
        if dayOfMonthRestricted && dayOfWeekRestricted {
            return byMonthDay || byWeekday
        }
        if dayOfMonthRestricted { return byMonthDay }
        if dayOfWeekRestricted { return byWeekday }
        return true
    }
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

    /// Schedule-aware variant: cron tasks fire at the next matching wall-clock
    /// time in their own time zone, interval tasks keep the old behavior.
    /// An invalid cron expression yields `nil`; validated input never stores
    /// one.
    static func nextRun(after date: Date, task: SchedulerTask) -> Date? {
        switch task.scheduleKind {
        case .interval:
            return nextRun(after: date, intervalMinutes: task.intervalMinutes)
        case .cron:
            guard let expression = task.cronExpression?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !expression.isEmpty,
                let cron = try? SchedulerCron.parse(expression) else {
                return nil
            }
            return cron.nextRun(after: date, timeZone: task.resolvedTimeZone)
        }
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

// MARK: - Built-in templates

/// A ready-made task: prompt with `{{variable}}` placeholders plus a schedule.
/// Selecting a template only prefills the editor; the user still picks a model.
struct SchedulerTaskTemplate: Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
    let promptTemplate: String
    let variables: [String]
    let scheduleKind: SchedulerScheduleKind
    let intervalMinutes: Int
    let cronExpression: String?
}

enum SchedulerTemplates {
    /// Built-in set. Schedules are cron expressions in the system time zone
    /// unless the editor overrides the zone.
    static let all: [SchedulerTaskTemplate] = [
        SchedulerTaskTemplate(
            id: "morning-digest",
            name: "Morning digest",
            description: "Recent changes and open work, every weekday morning.",
            promptTemplate: """
            Give me a short morning digest for {{repo}} on branch {{branch}}.
            Summarize the latest commits, open work and anything that needs attention today.
            Keep it under 200 words.
            """,
            variables: ["repo", "branch"],
            scheduleKind: .cron,
            intervalMinutes: SchedulerLimits.defaultIntervalMinutes,
            cronExpression: "0 9 * * 1-5"
        ),
        SchedulerTaskTemplate(
            id: "pr-review",
            name: "PR review",
            description: "Open pull requests, checks and risky changes before the end of the workday.",
            promptTemplate: """
            Review the open pull requests in {{repo}} for branch {{branch}}.
            List failing checks, unresolved comments and the riskiest changes with file paths.
            Finish with the top three issues to fix first.
            """,
            variables: ["repo", "branch"],
            scheduleKind: .cron,
            intervalMinutes: SchedulerLimits.defaultIntervalMinutes,
            cronExpression: "0 18 * * 1-5"
        ),
        SchedulerTaskTemplate(
            id: "weekly-repo-summary",
            name: "Weekly repo summary",
            description: "Merged work, active branches and open risks for the week.",
            promptTemplate: """
            Write a weekly summary for {{repo}} at {{path}}.
            Cover merged changes, active branches, open risks and the next steps.
            Use no more than 250 words.
            """,
            variables: ["repo", "path"],
            scheduleKind: .cron,
            intervalMinutes: SchedulerLimits.defaultIntervalMinutes,
            cronExpression: "0 10 * * 1"
        ),
        SchedulerTaskTemplate(
            id: "log-check",
            name: "Log check",
            description: "Scan recent logs for errors and warnings every six hours.",
            promptTemplate: """
            Check the recent logs under {{path}} for errors and warnings.
            Group the findings by severity, point to the likely cause and suggest a fix.
            If everything is clean, say so in one line.
            """,
            variables: ["path"],
            scheduleKind: .cron,
            intervalMinutes: 6 * 60,
            cronExpression: "0 */6 * * *"
        ),
        SchedulerTaskTemplate(
            id: "daily-spend",
            name: "Daily spend report",
            description: "Token spend, expensive models and unusual spikes for the day.",
            promptTemplate: """
            Review today's model spend for {{repo}}.
            Summarize token usage, the most expensive models and any unusual spikes.
            Finish with one short recommendation.
            """,
            variables: ["repo"],
            scheduleKind: .cron,
            intervalMinutes: 24 * 60,
            cronExpression: "0 21 * * *"
        ),
    ]

    static func template(id: String) -> SchedulerTaskTemplate? {
        all.first { $0.id == id }
    }

    /// Replace every declared placeholder with the trimmed user value.
    static func render(_ template: SchedulerTaskTemplate, values: [String: String]) -> String {
        var text = template.promptTemplate
        for variable in template.variables {
            let value = (values[variable] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            text = text.replacingOccurrences(of: "{{\(variable)}}", with: value)
        }
        return text
    }

    static func missingVariables(
        _ template: SchedulerTaskTemplate,
        values: [String: String]
    ) -> [String] {
        template.variables.filter {
            (values[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Creation-time validation for template variables.
    static func validationError(
        _ template: SchedulerTaskTemplate,
        values: [String: String]
    ) -> String? {
        let missing = missingVariables(template, values: values)
        guard missing.isEmpty else {
            let names = missing.map { "{{\($0)}}" }.joined(separator: ", ")
            return String(format: L("Fill in: %@"), names)
        }
        return nil
    }

    /// Every built-in must carry a parseable schedule; the editor relies on it.
    static func invalidTemplateID() -> String? {
        for template in all {
            let error = SchedulerTask.scheduleValidationError(
                scheduleKind: template.scheduleKind,
                cronExpression: template.cronExpression,
                timeZoneIdentifier: nil,
                intervalMinutes: template.intervalMinutes
            )
            if error != nil { return template.id }
        }
        return nil
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
