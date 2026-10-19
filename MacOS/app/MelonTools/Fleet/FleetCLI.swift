import Foundation
import Combine

/// Locates and invokes the melon-fleet CLI (Node ESM entry point).
@MainActor
final class FleetCLI: ObservableObject {
    static let shared = FleetCLI()

    /// Resolution order:
    /// 1. explicit override (settings)
    /// 2. app bundle resources (shipped copy)
    /// 3. dev tree fallback (DEBUG builds only)
    /// 4. `melon-fleet` on PATH (spawns a login shell — used only as the last resort)
    @Published private(set) var entryPath: String?
    @Published private(set) var nodePath: String?
    @Published private(set) var isResolved = false

    private init() {}

    func resolve() async {
        nodePath = await ShellService.whichAsync("node")
        let fm = FileManager.default

        var candidates: [String] = []
        if let override = UserDefaults.standard.string(forKey: "fleetCLIPath"), !override.isEmpty {
            candidates.append(override)
        }
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("melon-fleet/bin/melon-fleet.mjs").path)
        }
        #if DEBUG
        candidates.append(NSString(string: "~/Projects/MelonTools/_sources/melon-fleet/bin/melon-fleet.mjs").expandingTildeInPath)
        #endif
        if let bundled = candidates.first(where: { fm.isReadableFile(atPath: $0) }) {
            entryPath = bundled
        } else {
            // Only now pay for the PATH probe.
            entryPath = await ShellService.whichAsync("melon-fleet")
        }
        isResolved = true
    }

    var isReady: Bool { entryPath != nil && nodePath != nil }

    var unavailabilityReason: String? {
        if nodePath == nil { return L("Node.js 20+ not found. Install Node.js and try again.") }
        if entryPath == nil { return L("Fleet CLI not found. Install Fleet and try again.") }
        return nil
    }

    /// Run a CLI subcommand, capture output.
    func run(_ arguments: [String], cwd: String? = nil, timeout: TimeInterval? = nil) async throws -> ShellResult {
        guard let nodePath, let entryPath else {
            throw ShellError.launchFailed(unavailabilityReason ?? "fleet CLI unavailable")
        }
        var env: [String: String] = ["MELON_FLEET_UPDATE_CHECK": "0"]
        if let homeOverride = UserDefaults.standard.string(forKey: "fleetHome"), !homeOverride.isEmpty {
            env["MELON_FLEET_HOME"] = homeOverride
        }
        return try await ShellService.run(nodePath, [entryPath] + arguments, cwd: cwd, env: env, timeout: timeout)
    }

    /// Stream a CLI subcommand line-by-line.
    func stream(
        _ arguments: [String],
        cwd: String? = nil,
        onStdout: @escaping (String) -> Void,
        onStderr: @escaping (String) -> Void
    ) async -> Int32 {
        guard let nodePath, let entryPath else {
            onStderr(unavailabilityReason ?? "fleet CLI unavailable")
            return -1
        }
        var env: [String: String] = ["MELON_FLEET_UPDATE_CHECK": "0"]
        if let homeOverride = UserDefaults.standard.string(forKey: "fleetHome"), !homeOverride.isEmpty {
            env["MELON_FLEET_HOME"] = homeOverride
        }
        return await ShellService.stream(nodePath, [entryPath] + arguments, cwd: cwd, env: env, onStdout: onStdout, onStderr: onStderr)
    }

    /// Starts a streaming run and returns a cancellable handle at once.
    func startStream(
        _ arguments: [String],
        cwd: String? = nil,
        onExit: @escaping (Int32) -> Void,
        onStdout: @escaping (String) -> Void,
        onStderr: @escaping (String) -> Void
    ) throws -> ShellService.StreamHandle {
        guard let nodePath, let entryPath else {
            onStderr(unavailabilityReason ?? "fleet CLI unavailable")
            throw ShellError.launchFailed(unavailabilityReason ?? "fleet CLI unavailable")
        }
        var env: [String: String] = ["MELON_FLEET_UPDATE_CHECK": "0"]
        if let homeOverride = UserDefaults.standard.string(forKey: "fleetHome"), !homeOverride.isEmpty {
            env["MELON_FLEET_HOME"] = homeOverride
        }
        return try ShellService.streamCancelable(nodePath, [entryPath] + arguments, cwd: cwd, env: env, onExit: onExit, onStdout: onStdout, onStderr: onStderr)
    }
}
