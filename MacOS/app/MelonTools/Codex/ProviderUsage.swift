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

    /// Vercel AI Gateway team-level numbers. `balance` and `totalUsed` are
    /// account-wide, not key-wide; the UI labels them accordingly.
    struct VercelStats: Equatable {
        var balance: Double?
        var totalUsed: Double?
        var updatedAt: Date?
        var error: String?
    }

    /// Claude (subscription) status: account identity plus the two rolling
    /// quota windows. Every number is nil-tolerant — missing data renders
    /// as “—” and nothing is fabricated.
    struct ClaudeStats: Equatable {
        var connected = false
        var email: String?
        /// Plan name only when the usage payload carries one; otherwise nil.
        var plan: String?
        /// Share of the 5-hour window still available, 0…100.
        var fiveHourPercent: Double?
        var fiveHourReset: Date?
        /// Share of the weekly window still available, 0…100.
        var weeklyPercent: Double?
        var weeklyReset: Date?
        var modelCount = 0
        var updatedAt: Date?
        var error: String?
    }

    /// Antigravity (Google account) status: identity only. The engine exposes
    /// no Antigravity quota endpoint, so there are deliberately no percentages
    /// here — nothing is fabricated.
    struct AntigravityStats: Equatable {
        var connected = false
        var email: String?
        var projectID: String?
        var modelCount = 0
        var updatedAt: Date?
        var error: String?
    }

    @Published private(set) var openRouter: OpenRouterStats?
    @Published private(set) var openCode: OpenCodeStats?
    @Published private(set) var vercel: VercelStats?
    @Published private(set) var claude: ClaudeStats?
    @Published private(set) var antigravity: AntigravityStats?

    /// Token accounting of the Codex thread the user is looking at.
    @Published private(set) var sessionUsage: SessionUsageSnapshot?
    /// USD estimate for that thread, priced per turn.
    @Published private(set) var sessionSpend: SessionSpend?

    private let openRouterTTL: TimeInterval = 300
    private let openCodeTTL: TimeInterval = 1800
    private let vercelTTL: TimeInterval = 300
    /// Claude quota windows move slowly; the endpoint is polled rarely.
    private let claudeTTL: TimeInterval = 180
    /// Antigravity has no network poll — only the auth file and selection.
    private let antigravityTTL: TimeInterval = 180
    private var lastOpenRouterFetch = Date.distantPast
    private var lastOpenCodeFetch = Date.distantPast
    private var lastVercelFetch = Date.distantPast
    private var lastClaudeFetch = Date.distantPast
    private var lastAntigravityFetch = Date.distantPast
    private var openRouterBusy = false
    private var openCodeBusy = false
    private var vercelBusy = false
    private var claudeBusy = false
    private var antigravityBusy = false

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
        await refreshVercel(key: store.vercelKey.trimmingCharacters(in: .whitespacesAndNewlines), force: force)
        await refreshClaude(force: force)
        await refreshAntigravity(force: force)
    }

    /// Forces a Claude usage refresh — called right after a successful login.
    func refreshClaudeNow() async {
        await refreshClaude(force: true)
    }

    /// Forces an Antigravity identity refresh — called right after a
    /// successful login or a disconnect.
    func refreshAntigravityNow() async {
        await refreshAntigravity(force: true)
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
            // Credits are the meaningful balance for this provider; the key
            // limit is the fallback for free-tier keys.
            if let balance = stats.creditsRemaining ?? stats.keyRemaining {
                QuotaHistoryStore.shared.record(
                    QuotaHistorySample(at: Date(), balance: balance),
                    for: "openrouter"
                )
            }
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

    // MARK: - Vercel AI Gateway

    /// The gateway has no per-key balance endpoint; `/v1/credits` returns the
    /// team wallet. Missing values stay nil rather than being derived.
    private func refreshVercel(key: String, force: Bool) async {
        guard !vercelBusy, isStale(lastVercelFetch, ttl: vercelTTL, force: force) else { return }
        guard !key.isEmpty else {
            vercel = nil
            return
        }
        vercelBusy = true
        lastVercelFetch = Date()
        defer { vercelBusy = false }

        var stats = VercelStats()
        do {
            guard let root = try await Self.fetchJSON(url: ModelSourcesStore.vercelCreditsURL, key: key) else {
                throw URLError(.badServerResponse)
            }
            stats.balance = Self.number(root["balance"])
            stats.totalUsed = Self.number(root["total_used"])
            stats.updatedAt = Date()
            vercel = stats
            if let balance = stats.balance {
                QuotaHistoryStore.shared.record(
                    QuotaHistorySample(at: Date(), balance: balance),
                    for: "vercel"
                )
            }
        } catch {
            var failed = vercel ?? stats
            failed.error = error.localizedDescription
            vercel = failed
        }
    }

    // MARK: - Claude

    /// Claude has no per-key config: the account comes from the engine auth
    /// file. Without one the card shows “not connected”. The usage endpoint is
    /// undocumented, so every value stays nil when absent.
    private func refreshClaude(force: Bool) async {
        guard !claudeBusy, isStale(lastClaudeFetch, ttl: claudeTTL, force: force) else { return }
        claudeBusy = true
        lastClaudeFetch = Date()
        defer { claudeBusy = false }

        guard let file = ClaudeAuthService.authFiles().first else {
            claude = nil
            return
        }
        var stats = ClaudeStats()
        stats.connected = true
        stats.email = file.email
        stats.modelCount = ModelSourcesStore.shared.claudeSource?.selectedModels.count ?? 0
        if let snapshot = await ClaudeAuthService.shared.usageSnapshot() {
            stats.fiveHourPercent = snapshot.fiveHourPercent
            stats.fiveHourReset = snapshot.fiveHourReset
            stats.weeklyPercent = snapshot.weeklyPercent
            stats.weeklyReset = snapshot.weeklyReset
            stats.plan = snapshot.plan
            stats.updatedAt = Date()
        }
        claude = stats
        if stats.updatedAt != nil, stats.fiveHourPercent != nil || stats.weeklyPercent != nil {
            QuotaHistoryStore.shared.record(
                QuotaHistorySample(at: Date(), hourly: stats.fiveHourPercent, weekly: stats.weeklyPercent),
                for: "claude"
            )
        }
    }

    // MARK: - Antigravity

    /// Antigravity has no quota API — the card shows identity and the selected
    /// model count only. The account comes from the engine auth file and goes
    /// stale only when the file disappears.
    private func refreshAntigravity(force: Bool) async {
        guard !antigravityBusy, isStale(lastAntigravityFetch, ttl: antigravityTTL, force: force) else { return }
        antigravityBusy = true
        lastAntigravityFetch = Date()
        defer { antigravityBusy = false }

        guard let file = AntigravityAuthService.authFiles().first else {
            antigravity = nil
            return
        }
        var stats = AntigravityStats()
        stats.connected = true
        stats.email = file.email
        stats.projectID = file.projectID
        stats.modelCount = ModelSourcesStore.shared.antigravitySource?.selectedModels.count ?? 0
        stats.updatedAt = Date()
        antigravity = stats
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

    /// One ranked provider row for the dashboard.
    struct ProviderRanking: Equatable {
        let provider: String
        let stats: SessionSpend.ProviderStats
    }

    /// Top providers by tokens consumed in the session. Spend breaks ties,
    /// then the provider name, so the result is deterministic. Tokens are the
    /// primary key because unpriced providers still report them.
    func topProviders(limit: Int = 3) -> [ProviderRanking] {
        let ranked = providers.map { ProviderRanking(provider: $0.key, stats: $0.value) }
            .sorted { lhs, rhs in
                if lhs.stats.tokens != rhs.stats.tokens {
                    return lhs.stats.tokens > rhs.stats.tokens
                }
                let leftUSD = lhs.stats.usd ?? 0
                let rightUSD = rhs.stats.usd ?? 0
                if leftUSD != rightUSD { return leftUSD > rightUSD }
                return lhs.provider < rhs.provider
            }
        return Array(ranked.prefix(max(0, limit)))
    }
}

/// A small least-recently-used cache. Reads and inserts refresh recency, and
/// an insert drops only the oldest entries once `limit` is exceeded.
///
/// The rollout parse cache used to be emptied completely when it grew past its
/// cap, so every tick after an eviction re-parsed files it had just parsed.
struct LRUCache<Key: Hashable, Value> {
    let limit: Int
    private var entries: [Key: Value] = [:]
    /// Keys from least to most recently used.
    private var order: [Key] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    var count: Int { entries.count }

    /// Keys from least to most recently used (oldest first).
    var keys: [Key] { order }

    mutating func value(for key: Key) -> Value? {
        guard let value = entries[key] else { return nil }
        touch(key)
        return value
    }

    mutating func insert(_ value: Value, for key: Key) {
        entries[key] = value
        touch(key)
        while order.count > limit {
            let oldest = order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }

    mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
    }

    private mutating func touch(_ key: Key) {
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
        }
        order.append(key)
    }
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
    private static var cache = LRUCache<CacheKey, SessionUsageSnapshot>(limit: 12)

    private static func cachedSnapshot(for url: URL) -> SessionUsageSnapshot? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64,
              let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else { return nil }
        let key = CacheKey(path: url.path, size: size, modified: modified)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache.value(for: key)
    }

    private static func storeCache(_ snapshot: SessionUsageSnapshot?, for url: URL) {
        guard let snapshot else { return }
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64,
              let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else { return }
        let key = CacheKey(path: url.path, size: size, modified: modified)
        cacheLock.lock()
        // Keep the cache bounded: rollouts rotate daily. Eviction is
        // least-recently-used, so the thread being watched stays cached.
        cache.insert(snapshot, for: key)
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
            // Cap the exact-thread read; the composer tick is every 5 s and a
            // 128 MB parse per tick would stall the main actor. The estimate
            // already marks truncated windows as scaled.
            if var snapshot = parseTail(of: url, maxBytes: 32 * 1024 * 1024) {
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
