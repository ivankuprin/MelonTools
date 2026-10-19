import Foundation
import Combine

/// Live view over the fleet home directory (~/.melon-fleet):
/// status snapshots, ndjson log tail, result spool, doctor, config.
@MainActor
final class FleetStore: ObservableObject {
    static let shared = FleetStore()

    // Live state
    @Published private(set) var snapshots: [FleetStatusSnapshot] = []
    @Published private(set) var recentEvents: [FleetLogEvent] = []      // newest first, capped
    @Published private(set) var results: [FleetResultFile] = []          // newest first, capped
    @Published private(set) var doctor: DoctorReport?
    @Published private(set) var isDoctorRunning = false
    @Published var configRaw: String = ""
    @Published private(set) var configValues: [String: Any] = [:]
    @Published private(set) var cliError: String?
    @Published private(set) var fleetVersion: String?
    /// Fleet CLI resolved and ready (async — never blocks onAppear).
    @Published private(set) var cliReady = false

    private var watchSource: DispatchSourceFileSystemObject?
    private var pollTimer: Timer?
    private var logOffset: UInt64 = 0

    private let fm = FileManager.default
    private var homePath: String { AppStateLocator.shared.homePath }

    // MARK: - Lifecycle

    func start() {
        guard pollTimer == nil else { return }
        Task { @MainActor in
            await FleetCLI.shared.resolve()
            cliReady = FleetCLI.shared.isReady
        }
        refreshAll()
        startWatcher()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLive() }
        }
        pollTimer?.tolerance = 1.0
    }

    func stop() {
        watchSource?.cancel()
        watchSource = nil
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Fleet data is only polled while its pages (or the dashboard that shows
    /// the summary) are visible; switching away suspends the poll timer and
    /// the directory watcher, switching back re-arms them.
    func setActive(_ active: Bool) {
        if active {
            start()
        } else {
            stop()
        }
    }

    private func startWatcher() {
        watchSource?.cancel()
        let path = homePath
        if !fm.fileExists(atPath: path) {
            // Create it lazily: the CLI creates it too, but an early watcher needs it to exist.
            try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            // Fall through and arm the watcher on the fresh directory — a bare
            // return would leave live updates dead for the whole session.
        }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.refreshLive()
                // re-arm if directory was replaced
                self?.startWatcher()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watchSource = source
    }

    // MARK: - Refresh

    func refreshAll() {
        refreshLive()
        Task { await refreshResults() }
        Task { await refreshVersion() }
        Task { await refreshConfig() }
    }

    private func refreshLive() {
        let fresh = Self.loadSnapshots(home: homePath)
        // Publish only when something actually changed; the file watcher and the
        // poll timer both land here and unconditional writes invalidate every view.
        if fresh != snapshots { snapshots = fresh }
        // Reset the tail offset if the log was trimmed by the CLI.
        let logPath = (homePath as NSString).appendingPathComponent("fleet-log.ndjson")
        if let attrs = try? fm.attributesOfItem(atPath: logPath),
           let size = attrs[.size] as? UInt64, size < logOffset {
            logOffset = 0
            recentEvents = []
        }
        let freshEvents = Self.loadLogTail(home: homePath, existingOffset: &logOffset)
        mergeLogEvents(freshEvents)
    }

    func refreshVersion() async {
        do {
            let result = try await FleetCLI.shared.run(["--version"])
            if result.ok {
                fleetVersion = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                cliError = nil
            } else {
                cliError = result.stderr.isEmpty ? "CLI exited \(result.exitCode)" : result.stderr
            }
        } catch {
            cliError = error.localizedDescription
        }
    }

    // MARK: - Doctor

    func runDoctor(probeModels: Bool = false, probeSandbox: Bool = false) async {
        isDoctorRunning = true
        defer { isDoctorRunning = false }
        var args = ["doctor"]
        if probeModels { args.append("--probe-models") }
        if probeSandbox { args.append("--probe-sandbox") }
        do {
            let result = try await FleetCLI.shared.run(args, timeout: 900)
            doctor = DoctorReport.parse(result.stdout, exitCode: result.exitCode)
        } catch {
            cliError = error.localizedDescription
        }
    }

    // MARK: - Config

    func refreshConfig() async {
        do {
            let result = try await FleetCLI.shared.run(["show"])
            if result.ok {
                configRaw = result.stdout
                cliError = nil
            } else {
                // `show` may fail if no config exists yet; read the file directly
                configRaw = (try? String(contentsOfFile: configFilePath, encoding: .utf8)) ?? ""
            }
        } catch {
            cliError = error.localizedDescription
        }
        configValues = (try? Self.loadConfigValues(path: configFilePath)) ?? [:]
    }

    var configFilePath: String {
        (homePath as NSString).appendingPathComponent("fleet.config.json")
    }

    /// Set a config key through the CLI (`set key=value`), which validates.
    func setConfig(key: String, value: String) async -> (ok: Bool, message: String) {
        do {
            let result = try await FleetCLI.shared.run(["set", "\(key)=\(value)"])
            await refreshConfig()
            let message = result.ok ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                                    : result.stderr.isEmpty ? "exit \(result.exitCode)" : result.stderr
            return (result.ok, message)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    struct ConfigEntry: Identifiable {
        let key: String
        let value: String
        var id: String { key }
    }

    /// Flatten fleet.config.json into editable `key=value` rows (dot-paths).
    var editableConfigEntries: [ConfigEntry] {
        var entries: [ConfigEntry] = []
        func walk(_ prefix: String, _ dict: [String: Any]) {
            for key in dict.keys.sorted() {
                let full = prefix.isEmpty ? key : "\(prefix).\(key)"
                let value = dict[key]!
                if let nested = value as? [String: Any] {
                    walk(full, nested)
                } else {
                    entries.append(ConfigEntry(key: full, value: Self.display(value)))
                }
            }
        }
        if let units = configValues["units"] as? [String: Any] {
            for unitKey in units.keys.sorted() {
                if let unit = units[unitKey] as? [String: Any] {
                    walk("units.\(unitKey)", unit)
                }
            }
        }
        for key in configValues.keys.sorted() where key != "units" {
            let value = configValues[key]!
            if let nested = value as? [String: Any] {
                walk(key, nested)
            } else {
                entries.append(ConfigEntry(key: key, value: Self.display(value)))
            }
        }
        return entries
    }

    private static func display(_ value: Any) -> String {
        switch value {
        case let b as Bool: return b ? "true" : "false"
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case let a as [Any]: return a.map { "\($0)" }.joined(separator: ",")
        default: return "\(value)"
        }
    }

    private static func loadConfigValues(path: String) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: path) else { return [:] }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let obj = try JSONSerialization.jsonObject(with: data)
        return obj as? [String: Any] ?? [:]
    }

    // MARK: - Results spool

    func refreshResults(limitPerUnit: Int = 100) async {
        var items: [FleetResultFile] = []
        for unit in FleetUnit.allCases {
            let dir = (homePath as NSString).appendingPathComponent("results/\(unit.rawValue)")
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            let mdFiles = names.filter { $0.hasSuffix(".md") }.sorted(by: >) // resultId sorts lexicographically = time
            for name in mdFiles.prefix(limitPerUnit) {
                let path = (dir as NSString).appendingPathComponent(name)
                if let item = Self.parseResultFile(path: path, unit: unit.rawValue) {
                    items.append(item)
                }
            }
        }
        items.sort { ($0.resultId) > ($1.resultId) }
        results = items
    }

    func loadResultBody(_ item: FleetResultFile) -> String {
        // Results can be tens of MB; the preview shows a bounded prefix.
        guard let handle = FileHandle(forReadingAtPath: item.path) else { return "" }
        defer { try? handle.close() }
        let cap = 512 * 1024
        let data = handle.readData(ofLength: cap)
        var text = String(data: data, encoding: .utf8) ?? ""
        let fullSize = (try? handle.seekToEnd()) ?? 0
        if fullSize > UInt64(data.count) {
            text += "\n\n… " + L("Preview truncated — the full file is larger.")
        }
        return text
    }

    /// Parse the spool file header block (bounded prefix) per core/results.mjs format.
    static func parseResultFile(path: String, unit: String) -> FleetResultFile? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let prefix = handle.readData(ofLength: 8192)
        guard let text = String(data: prefix, encoding: .utf8) else { return nil }

        var item = FleetResultFile(unit: unit, resultId: (path as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: ""), path: path)

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first == "---" else { return nil }
        for line in lines.dropFirst() {
            if line == "---" { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            switch key {
            case "tool": item.tool = value
            case "model": item.model = value
            case "status": item.status = value
            case "startedAt": item.startedAt = value
            case "endedAt": item.endedAt = value
            case "durationMs": item.durationMs = Int(value)
            case "usage": item.usageLine = value
            case "cwd": item.cwd = value
            case "promptPreview": item.promptPreview = value
            case "partial": item.partial = value == "true"
            case "detached": item.detached = value == "true"
            default: break
            }
        }
        return item
    }

    // MARK: - Feed readers

    static func loadSnapshots(home: String) -> [FleetStatusSnapshot] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: home) else { return [] }
        let decoder = JSONDecoder()
        var snapshots: [FleetStatusSnapshot] = []
        for name in names where name.hasPrefix("status-") && name.hasSuffix(".json") {
            let path = (home as NSString).appendingPathComponent(name)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let snap = try? decoder.decode(FleetStatusSnapshot.self, from: data) else { continue }
            snapshots.append(snap)
        }
        snapshots.sort { $0.unit < $1.unit }
        return snapshots
    }

    /// Incremental tail of fleet-log.ndjson. Reads only new bytes since last
    /// call, capped to the most recent `maxEvents` lines — a log flood between
    /// ticks must not spike memory.
    static func loadLogTail(home: String, existingOffset: inout UInt64, maxEvents: Int = 400) -> [FleetLogEvent] {
        let path = (home as NSString).appendingPathComponent("fleet-log.ndjson")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64 else { return [] }
        if size < existingOffset { existingOffset = 0 } // log was trimmed
        guard size > existingOffset else {
            // nothing new — keep whatever the store already has (caller merges)
            return []
        }
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }

        // Cap the delta read: keep only the newest maxEvents lines.
        let delta = size - existingOffset
        let cap: UInt64 = 4 * 1024 * 1024
        if delta > cap {
            // Re-anchor to the tail and skip the (possibly partial) first line.
            try? handle.seek(toOffset: size - cap)
            _ = handle.readData(ofLength: 1)
            let data = handle.readDataToEndOfFile()
            existingOffset = size
            var lines = data.split(separator: 0x0A)
            if lines.count > maxEvents {
                lines.removeFirst(lines.count - maxEvents)
            }
            let decoder = JSONDecoder()
            return lines.compactMap { try? decoder.decode(FleetLogEvent.self, from: Data($0)) }
        }
        try? handle.seek(toOffset: existingOffset)
        let data = handle.readDataToEndOfFile()
        existingOffset = size

        let decoder = JSONDecoder()
        var events: [FleetLogEvent] = []
        for line in data.split(separator: 0x0A) {
            if let event = try? decoder.decode(FleetLogEvent.self, from: Data(line)) {
                events.append(event)
            }
        }
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
        return events
    }

    /// Merge fresh tail events with kept history (newest first).
    func mergeLogEvents(_ fresh: [FleetLogEvent]) {
        guard !fresh.isEmpty else { return }
        var merged = fresh.reversed() + recentEvents
        if merged.count > 400 { merged = Array(merged.prefix(400)) }
        recentEvents = merged
    }
}

/// Small locator so FleetStore doesn't need AppState injected at init.
final class AppStateLocator {
    static let shared = AppStateLocator()
    var homePath: String = UserDefaults.standard.string(forKey: "fleetHome")
        ?? NSString(string: "~/.melon-fleet").expandingTildeInPath
}
