import Combine
import Foundation

/// Provider-side statistics for the composer chips.
///
/// When the model selected in the Codex composer belongs to OpenCode or
/// OpenRouter, the chips show that provider's numbers instead of the account
/// pool quota. Two sources feed the chips:
///
///   - the provider APIs (OpenRouter credits/key, OpenCode workspace config);
///   - the local Codex rollouts (`~/.codex/sessions/**/*.jsonl`), which carry
///     the token accounting of the active thread.
///
/// Network calls are throttled: OpenRouter once per 5 minutes, the OpenCode
/// workspace config once per 30 minutes.
@MainActor
final class ProviderUsageStore: ObservableObject {
    static let shared = ProviderUsageStore()

    /// Shared User-Agent for provider API calls (single source of truth).
    static let appUserAgent = "MelonTools/1.4"

    struct OpenRouterStats: Equatable {
        var creditsTotal: Double?
        var creditsUsage: Double?
        var keyUsage: Double?
        var keyLimit: Double?
        var keyRemaining: Double?
        var isFreeTier: Bool = false
        var updatedAt: Date?
        var error: String?

        var creditsRemaining: Double? {
            guard let total = creditsTotal, let usage = creditsUsage else { return nil }
            return max(0, total - usage)
        }
    }

    struct OpenCodeStats: Equatable {
        var workspace: String?
        var orgID: String?
        var modelCount: Int = 0
        var updatedAt: Date?
        var error: String?
    }

    @Published private(set) var openRouter: OpenRouterStats?
    @Published private(set) var openCode: OpenCodeStats?

    /// Token accounting of the Codex thread the user is looking at.
    @Published private(set) var sessionUsage: SessionUsageSnapshot?
    /// USD estimate for that thread, priced per turn.
    @Published private(set) var sessionSpend: SessionSpend?

    private let openRouterTTL: TimeInterval = 300
    private let openCodeTTL: TimeInterval = 1800
    private var lastOpenRouterFetch = Date.distantPast
    private var lastOpenCodeFetch = Date.distantPast
    private var openRouterBusy = false
    private var openCodeBusy = false

    private init() {}

    // MARK: - Refresh

    /// Refreshes both providers when their data is stale (or always with `force`).
    func refresh(force: Bool = false) async {
        let store = ModelSourcesStore.shared
        // Prices make the session estimate work for models selected before
        // pricing was stored; the call is a no-op once every model has them.
        await store.hydrateOpenRouterPrices()
        await refreshOpenRouter(key: store.openRouterKey.trimmingCharacters(in: .whitespacesAndNewlines), force: force)
        await refreshOpenCode(key: store.openCodeKey.trimmingCharacters(in: .whitespacesAndNewlines), force: force)
    }

    // MARK: - Session

    /// Re-reads the rollout of `threadUUID` (or the freshest one) and prices
    /// its turns with the provider model prices.
    func refreshSession(threadUUID: String?) async {
        let snapshot = await SessionUsageReader.read(threadUUID: threadUUID)
        // Publish only on change: the bridge ticks every 5 s and unchanged
        // snapshots would invalidate the views for nothing.
        if snapshot != sessionUsage {
            sessionUsage = snapshot
            sessionSpend = snapshot.map(estimateSpend)
        }
    }

    /// Prices every turn with the price of the model that ran it and keeps the
    /// token counts per provider. Turns of models outside the sources (the
    /// account pool) stay unpriced.
    private func estimateSpend(_ snapshot: SessionUsageSnapshot) -> SessionSpend {
        let store = ModelSourcesStore.shared
        var spend = SessionSpend()
        for turn in snapshot.turnUsage {
            guard let name = turn.model, let row = store.priceRow(for: name) else {
                spend.unpricedTurns += 1
                continue
            }
            let tag = CodexModelCatalog.providerTag(for: row.kind)
            var stats = spend.providers[tag] ?? SessionSpend.ProviderStats()
            stats.turns += 1
            stats.tokens += turn.tokens.total
            stats.input += turn.tokens.input
            stats.cached += turn.tokens.cached
            stats.output += turn.tokens.output
            stats.reasoning += turn.tokens.reasoning
            if let prompt = row.model.promptPerToken, let completion = row.model.completionPerToken {
                let cost = Self.turnCost(turn.tokens, prompt: prompt, completion: completion, cacheRead: row.model.cacheReadPerToken)
                stats.usd = (stats.usd ?? 0) + cost
                spend.totalUSD += cost
                spend.pricedTurns += 1
            }
            spend.providers[tag] = stats
        }
        // A long thread may start before the read window. Scale the priced part
        // by the share of tokens it covers so the number stays representative.
        let covered = snapshot.turnUsage.reduce(0) { $0 + $1.tokens.total }
        if covered > 0, snapshot.total.total > covered {
            let factor = Double(snapshot.total.total) / Double(covered)
            spend.totalUSD *= factor
            for (tag, value) in spend.providers {
                guard let usd = value.usd else { continue }
                var stats = value
                stats.usd = usd * factor
                spend.providers[tag] = stats
            }
            spend.scaled = true
        }
        return spend
    }

    /// Cost of one turn: fresh input, cache reads, and completion tokens.
    private static func turnCost(_ usage: SessionTokenUsage, prompt: Double, completion: Double, cacheRead: Double?) -> Double {
        let cached = min(usage.cached, usage.input)
        let fresh = max(0, usage.input - cached)
        return Double(fresh) * prompt
            + Double(cached) * (cacheRead ?? prompt)
            + Double(usage.output) * completion
    }

    private func isStale(_ last: Date, ttl: TimeInterval, force: Bool) -> Bool {
        force || Date().timeIntervalSince(last) >= ttl
    }

    // MARK: - OpenRouter

    private func refreshOpenRouter(key: String, force: Bool) async {
        guard !openRouterBusy, isStale(lastOpenRouterFetch, ttl: openRouterTTL, force: force) else { return }
        guard !key.isEmpty else {
            openRouter = nil
            return
        }
        openRouterBusy = true
        lastOpenRouterFetch = Date()
        defer { openRouterBusy = false }

        var stats = OpenRouterStats()
        do {
            if let credits = try await Self.fetchJSON(url: "https://openrouter.ai/api/v1/credits", key: key),
               let data = credits["data"] as? [String: Any] {
                stats.creditsTotal = Self.number(data["total_credits"])
                stats.creditsUsage = Self.number(data["total_usage"])
            }
            if let info = try await Self.fetchJSON(url: "https://openrouter.ai/api/v1/key", key: key),
               let data = info["data"] as? [String: Any] {
                stats.keyUsage = Self.number(data["usage"])
                stats.keyLimit = Self.number(data["limit"])
                stats.keyRemaining = Self.number(data["limit_remaining"])
                stats.isFreeTier = (data["is_free_tier"] as? Bool) ?? false
            }
            stats.updatedAt = Date()
            openRouter = stats
        } catch {
            var failed = openRouter ?? stats
            failed.error = error.localizedDescription
            openRouter = failed
        }
    }

    // MARK: - OpenCode

    private func refreshOpenCode(key: String, force: Bool) async {
        guard !openCodeBusy, isStale(lastOpenCodeFetch, ttl: openCodeTTL, force: force) else { return }
        guard !key.isEmpty else {
            openCode = nil
            return
        }
        openCodeBusy = true
        lastOpenCodeFetch = Date()
        defer { openCodeBusy = false }

        do {
            guard let root = try await Self.fetchJSON(url: "https://opencode.ai/console/api/v2/config", key: key) else {
                throw URLError(.badServerResponse)
            }
            var stats = OpenCodeStats()
            if let providers = root["providers"] as? [String: Any],
               let entry = providers["opencode"] as? [String: Any] {
                stats.workspace = entry["name"] as? String
                stats.modelCount = (entry["models"] as? [String: Any])?.count ?? 0
                if let headers = entry["headers"] as? [String: String] {
                    stats.orgID = headers["x-opencode-org-id"]
                }
            }
            stats.updatedAt = Date()
            openCode = stats
        } catch {
            var failed = openCode ?? OpenCodeStats()
            failed.error = error.localizedDescription
            openCode = failed
        }
    }

    // MARK: - Helpers

    private static func fetchJSON(url: String, key: String) async throws -> [String: Any]? {
        guard let url = URL(string: url) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.appUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }
}

// MARK: - Session usage

/// Token accounting of one Codex session (`total_token_usage` buckets).
struct SessionTokenUsage: Equatable {
    var input = 0
    var cached = 0
    var cacheWrite = 0
    var output = 0
    var reasoning = 0
    var total = 0

    /// Share of the input tokens that came from the provider cache.
    var cacheHitPercent: Int? {
        guard input > 0 else { return nil }
        return Int((Double(cached) / Double(input) * 100).rounded())
    }
}

/// Snapshot of the most recent `token_count` event in a Codex rollout.
struct SessionUsageSnapshot: Equatable {
    var model: String?
    var contextWindow: Int?
    var last = SessionTokenUsage()
    var total = SessionTokenUsage()
    var turns: Int = 0
    var updatedAt: Date?
    /// True when the rollout was located by the active thread id.
    var matchedThread = false
    /// Per-turn `last_token_usage` deltas, with the model that ran each turn.
    var turnUsage: [SessionTurnUsage] = []
}

/// One turn of the thread: the model in effect and the tokens it consumed.
struct SessionTurnUsage: Equatable {
    var model: String?
    var tokens: SessionTokenUsage
}

/// Token and USD accounting of a thread, split by the provider that ran each
/// turn. Only providers that expose per-token prices (OpenRouter) contribute
/// dollars; pool and OpenCode turns keep their token counts.
struct SessionSpend: Equatable {
    struct ProviderStats: Equatable {
        var usd: Double?
        var turns = 0
        var tokens = 0
        var input = 0
        var cached = 0
        var output = 0
        var reasoning = 0

        /// Share of the input tokens that came from the provider cache.
        var cacheHitPercent: Int? {
            guard input > 0 else { return nil }
            return Int((Double(cached) / Double(input) * 100).rounded())
        }
    }

    var totalUSD: Double = 0
    /// Provider tag → stats (`openrouter`, `opencode`).
    var providers: [String: ProviderStats] = [:]
    var pricedTurns = 0
    var unpricedTurns = 0
    /// True when older turns fell outside the read window and the numbers were
    /// scaled by the visible token share.
    var scaled = false

    var hasData: Bool { pricedTurns > 0 }

    func stats(for provider: String) -> ProviderStats? { providers[provider] }
}

/// Reads token accounting from the Codex CLI rollouts. The Codex app appends a
/// `token_count` event after every model turn, so the newest event describes
/// the context the thread currently carries — even for gateway models, where
/// the provider itself exposes no such API.
enum SessionUsageReader {
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .appendingPathComponent("sessions")
    }

    /// Parse cache: rollouts are appended-to, so an unchanged (size, mtime)
    /// means the previous parse is still valid. The bridge ticks every 5 s —
    /// without this each tick re-read and re-parsed up to 128 MB.
    private struct CacheKey: Equatable, Hashable {
        let path: String
        let size: UInt64
        let modified: TimeInterval
    }
    private static let cacheLock = NSLock()
    private static var cache: [CacheKey: SessionUsageSnapshot] = [:]

    private static func cachedSnapshot(for url: URL) -> SessionUsageSnapshot? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64,
              let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else { return nil }
        let key = CacheKey(path: url.path, size: size, modified: modified)
        cacheLock.lock()
        if let hit = cache[key] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()
        return nil
    }

    private static func storeCache(_ snapshot: SessionUsageSnapshot?, for url: URL) {
        guard let snapshot else { return }
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64,
              let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else { return }
        let key = CacheKey(path: url.path, size: size, modified: modified)
        cacheLock.lock()
        // Keep the cache bounded: rollouts rotate daily.
        if cache.count > 12 { cache.removeAll(keepingCapacity: true) }
        cache[key] = snapshot
        cacheLock.unlock()
    }

    /// Reads the snapshot for `threadUUID`, or for the most recently active
    /// thread when the id is unknown.
    static func read(threadUUID: String?) async -> SessionUsageSnapshot? {
        await Task.detached(priority: .utility) {
            readSync(threadUUID: threadUUID)
        }.value
    }

    // MARK: - File discovery

    private static func dayDirectories(daysBack: Int) -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        let now = Date()
        let calendar = Calendar(identifier: .gregorian)
        for offset in 0..<daysBack {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day else { continue }
            let dir = root
                .appendingPathComponent(String(format: "%04d", year))
                .appendingPathComponent(String(format: "%02d", month))
                .appendingPathComponent(String(format: "%02d", dayOfMonth))
            if fm.fileExists(atPath: dir.path) { result.append(dir) }
        }
        return result
    }

    private static func rolloutFiles(daysBack: Int) -> [(url: URL, modified: Date)] {
        let fm = FileManager.default
        var files: [(URL, Date)] = []
        for dir in dayDirectories(daysBack: daysBack) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names where name.hasSuffix(".jsonl") {
                let url = dir.appendingPathComponent(name)
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                files.append((url, modified))
            }
        }
        return files.sorted { $0.1 > $1.1 }
    }

    private static func fileURL(forThread uuid: String) -> URL? {
        let fm = FileManager.default
        for dir in dayDirectories(daysBack: 7) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            if let name = names.first(where: { $0.hasSuffix("-\(uuid).jsonl") }) {
                let url = dir.appendingPathComponent(name)
                if fm.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    // MARK: - Reading

    private static func readSync(threadUUID: String?) -> SessionUsageSnapshot? {
        // The exact thread is known: read the whole rollout so the estimate
        // covers every turn (long sessions do not fit into a fixed tail).
        if let uuid = threadUUID, !uuid.isEmpty, let url = fileURL(forThread: uuid) {
            if let hit = cachedSnapshot(for: url) {
                var matched = hit
                matched.matchedThread = true
                return matched
            }
            if var snapshot = parseTail(of: url, maxBytes: 128 * 1024 * 1024) {
                snapshot.matchedThread = true
                storeCache(snapshot, for: url)
                return snapshot
            }
        }
        // Fallback: the file with the freshest token_count event among the
        // recently touched rollouts.
        var best: (snapshot: SessionUsageSnapshot, at: Date)?
        for file in rolloutFiles(daysBack: 3).prefix(6) {
            let parsed = cachedSnapshot(for: file.url) ?? parseTail(of: file.url)
            guard let snapshot = parsed, let at = snapshot.updatedAt else { continue }
            storeCache(snapshot, for: file.url)
            if best == nil || at > best!.at {
                best = (snapshot, at)
            }
        }
        return best?.snapshot
    }

    private static func tail(of url: URL, maxBytes: Int = 2 * 1024 * 1024) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: offset)
        return try? handle.readToEnd()
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func parseTail(of url: URL, maxBytes: Int = 2 * 1024 * 1024) -> SessionUsageSnapshot? {
        guard let data = tail(of: url, maxBytes: maxBytes) else { return nil }
        let tokensMarker = Data("token_count".utf8)
        let contextMarker = Data("turn_context".utf8)
        var snapshot: SessionUsageSnapshot?
        var model: String?
        var turns = 0
        var turnUsage: [SessionTurnUsage] = []

        for line in data.split(separator: 0x0A) {
            let slice = Data(line)
            let hasTokens = slice.range(of: tokensMarker) != nil
            let hasTurn = slice.range(of: contextMarker) != nil
            guard hasTokens || hasTurn else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: slice) as? [String: Any] else { continue }
            if hasTurn, let payload = object["payload"] as? [String: Any], let value = payload["model"] as? String {
                model = value
                continue
            }
            guard let payload = object["payload"] as? [String: Any],
                  (payload["type"] as? String) == "token_count",
                  let info = payload["info"] as? [String: Any] else { continue }
            turns += 1
            var fresh = SessionUsageSnapshot()
            fresh.model = model
            fresh.last = usage(info["last_token_usage"])
            fresh.total = usage(info["total_token_usage"])
            fresh.contextWindow = info["model_context_window"] as? Int
            if let stamp = object["timestamp"] as? String {
                fresh.updatedAt = isoFormatter.date(from: stamp)
            }
            turnUsage.append(SessionTurnUsage(model: model, tokens: fresh.last))
            snapshot = fresh
        }

        guard var result = snapshot else { return nil }
        result.turns = turns
        result.model = model ?? result.model
        // A tail read can start mid-thread: keep the newest deltas only.
        if turnUsage.count > 2400 {
            turnUsage.removeFirst(turnUsage.count - 2400)
        }
        result.turnUsage = turnUsage
        return result
    }

    private static func usage(_ value: Any?) -> SessionTokenUsage {
        guard let dict = value as? [String: Any] else { return SessionTokenUsage() }
        var usage = SessionTokenUsage()
        usage.input = dict["input_tokens"] as? Int ?? 0
        usage.cached = dict["cached_input_tokens"] as? Int ?? 0
        usage.cacheWrite = dict["cache_write_input_tokens"] as? Int ?? 0
        usage.output = dict["output_tokens"] as? Int ?? 0
        usage.reasoning = dict["reasoning_output_tokens"] as? Int ?? 0
        usage.total = dict["total_tokens"] as? Int ?? 0
        return usage
    }
}
