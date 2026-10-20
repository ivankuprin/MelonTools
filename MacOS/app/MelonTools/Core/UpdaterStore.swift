import AppKit
import CryptoKit
import Foundation

/// GitHub-based self-update: checks the latest release, downloads the macOS
/// DMG, verifies SHA256 and hands the swap to a detached script that runs
/// after the app quits.
///
/// Public HTTPS endpoints only (no tokens, no SSH):
/// `api.github.com` for the release JSON and `github.com` /
/// `objects.githubusercontent.com` / `release-assets.githubusercontent.com`
/// for the download.
@MainActor
final class UpdaterStore: ObservableObject {
    static let shared = UpdaterStore()

    static let releaseAPI = URL(string: "https://api.github.com/repos/ivankuprin/MelonTools/releases/latest")!
    nonisolated static let allowedHosts: Set<String> = [
        "api.github.com",
        "github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
    ]

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate(String)
        case available(String, String) // version, notes
        case working(String)
        case failed(String)
    }

    enum UpdaterError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self {
            case .message(let text): return text
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published var sheetPresented = false

    private var assetURL: URL?
    private var assetDigest: String?
    private var busy = false

    /// How often the running app wakes up to ask for updates. The throttle
    /// below still owns the real cadence: a non-manual check within 24 hours
    /// of the last successful one is a no-op.
    nonisolated static let periodicCheckInterval: TimeInterval = 6 * 3600
    /// Only a successful non-manual check counts toward this throttle.
    nonisolated static let automaticCheckThrottle: TimeInterval = 24 * 3600

    var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    }

    // MARK: - Pure helpers (unit-tested)

    enum Version {
        /// Numeric per-segment comparison: 1.4.10 > 1.4.9; "1.4" <= "1.4.0".
        nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
            let left = candidate.split(separator: ".").map(String.init)
            let right = current.split(separator: ".").map(String.init)
            let count = max(left.count, right.count)
            for index in 0..<count {
                let l = index < left.count ? left[index] : "0"
                let r = index < right.count ? right[index] : "0"
                if let ln = Int(l), let rn = Int(r) {
                    if ln != rn { return ln > rn }
                } else if l != r {
                    return l > r
                }
            }
            return false
        }
    }

    /// Whether a non-manual check may hit the network. Pure so the periodic
    /// timer cadence (6 h) and the daily throttle stay independently testable.
    nonisolated static func shouldCheckAutomatically(lastCheck: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastCheck) > automaticCheckThrottle
    }

    nonisolated static func isAllowed(_ url: URL) -> Bool {
        url.scheme == "https" && allowedHosts.contains(url.host ?? "")
    }

    /// First token of a `.sha256` file, when it is a 64-char hex string.
    nonisolated static func parseSha256File(_ text: String) -> String? {
        guard let token = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }).first else {
            return nil
        }
        let hex = String(token).lowercased()
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit) ? hex : nil
    }

    nonisolated static func sha256Hex(of url: URL) throws -> String {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while autoreleasepool(invoking: { () -> Bool in
            let chunk = handle.readData(ofLength: 1 << 20)
            guard !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Checking

    func check(manual: Bool) async {
        guard !busy else { return }
        if !manual {
            let last = UserDefaults.standard.object(forKey: "updaterLastCheck") as? Date ?? .distantPast
            guard Self.shouldCheckAutomatically(lastCheck: last, now: Date()) else { return }
        }
        busy = true
        if manual { phase = .checking }
        defer { busy = false }

        do {
            var request = URLRequest(url: Self.releaseAPI)
            request.timeoutInterval = 20
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("MelonTools/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let finalURL = response.url, Self.isAllowed(finalURL) else {
                throw UpdaterError.message(L("The update server answered from a disallowed host."))
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw UpdaterError.message(L("The update server answered with an unexpected status."))
            }
            // Only a successful check counts toward the daily throttle.
            UserDefaults.standard.set(Date(), forKey: "updaterLastCheck")
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw UpdaterError.message(L("Malformed update response."))
            }
            let tag = (json["tag_name"] as? String) ?? ""
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let notes = (json["body"] as? String) ?? ""

            guard Self.Version.isNewer(version, than: currentVersion) else {
                assetURL = nil
                assetDigest = nil
                phase = .upToDate(currentVersion)
                return
            }
            let assets = (json["assets"] as? [[String: Any]]) ?? []
            guard let asset = assets.first(where: { item in
                let name = (item["name"] as? String) ?? ""
                return name.hasPrefix("MelonTools-") && name.hasSuffix(".dmg")
            }),
            let urlString = asset["browser_download_url"] as? String,
            let url = URL(string: urlString),
            Self.isAllowed(url) else {
                throw UpdaterError.message(L("This release has no installer for macOS."))
            }
            assetURL = url
            let digest = (asset["digest"] as? String)?.replacingOccurrences(of: "sha256:", with: "")
            assetDigest = (digest?.isEmpty == false) ? digest : nil
            phase = .available(version, notes.isEmpty ? L("No release notes.") : notes)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Installing

    func install() async {
        guard !busy, let assetURL else { return }
        busy = true
        defer { busy = false }
        do {
            guard Bundle.main.bundlePath.hasPrefix("/Applications/") else {
                throw UpdaterError.message(L("Updating works only from the Applications folder."))
            }
            phase = .working(L("Downloading the update…"))
            let (temp, response) = try await URLSession.shared.download(from: assetURL)
            guard let finalURL = response.url, Self.isAllowed(finalURL) else {
                throw UpdaterError.message(L("The download was redirected to a disallowed host."))
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw UpdaterError.message(L("The update download failed."))
            }
            let dmgURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("MelonTools-update-\(UUID().uuidString).dmg")
            try? FileManager.default.removeItem(at: dmgURL)
            try FileManager.default.moveItem(at: temp, to: dmgURL)

            let expected = await expectedDigest()
            let actual = try Self.sha256Hex(of: dmgURL)
            guard let expected, actual.caseInsensitiveCompare(expected) == .orderedSame else {
                try? FileManager.default.removeItem(at: dmgURL)
                throw UpdaterError.message(L("SHA256 check failed — the download was refused."))
            }

            phase = .working(L("Installing the update…"))
            try Self.launchInstaller(dmg: dmgURL)
            // A presented SwiftUI sheet can veto termination, which leaves the
            // swap script waiting until its timeout. Close the sheet first.
            sheetPresented = false
            // The script waits for this process to exit, then swaps the bundle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                NSApp.terminate(nil)
                // Hard watchdog: if termination is vetoed anyway, exit so the
                // detached installer can still replace the bundle.
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    exit(0)
                }
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Release digest, or the first token of the asset's `.sha256` sibling.
    private func expectedDigest() async -> String? {
        if let assetDigest { return assetDigest }
        guard let assetURL,
              let shaURL = URL(string: assetURL.absoluteString + ".sha256"),
              Self.isAllowed(shaURL) else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(from: shaURL),
              let finalURL = response.url, Self.isAllowed(finalURL) else { return nil }
        return Self.parseSha256File(String(data: data, encoding: .utf8) ?? "")
    }

    private static func launchInstaller(dmg: URL) throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("melontools-update-\(UUID().uuidString).sh")
        let script = installerScript(
            appPath: "/Applications/Melon Tools.app",
            dmgPath: dmg.path,
            pid: ProcessInfo.processInfo.processIdentifier
        )
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// The detached swap script. Pure so tests can assert the rollback
    /// contract without running an installer.
    nonisolated static func installerScript(appPath: String, dmgPath: String, pid: Int32) -> String {
        """
        #!/bin/bash
        # Melon Tools self-update: replace the running bundle after it exits.
        # The log lives in the user's Logs folder (0600): the update script runs
        # as the user, and /tmp is world-readable and periodically purged.
        umask 077
        LOG_DIR="$HOME/Library/Logs/MelonTools"
        mkdir -p "$LOG_DIR"
        LOG="$LOG_DIR/update.log"
        : >> "$LOG"
        chmod 0600 "$LOG" 2>/dev/null || true
        exec >> "$LOG" 2>&1
        APP="\(appPath)"
        DMG="\(dmgPath)"
        PID=\(pid)
        MNT="$(mktemp -d /tmp/melontools-dmg.XXXXXX)"
        for _ in $(seq 1 15); do
          kill -0 "$PID" 2>/dev/null || break
          sleep 1
        done
        # A hung terminate must not end with the bundle swapped under a live
        # process: force it down first, and give up only if signals fail.
        if kill -0 "$PID" 2>/dev/null; then kill -TERM "$PID" 2>/dev/null; sleep 2; fi
        if kill -0 "$PID" 2>/dev/null; then kill -KILL "$PID" 2>/dev/null; sleep 1; fi
        if kill -0 "$PID" 2>/dev/null; then exit 1; fi
        hdiutil attach -nobrowse -noverify -mountpoint "$MNT" "$DMG" || exit 1
        SRC="$(/bin/ls -d "$MNT"/*.app | head -1)"
        if [ ! -d "$SRC" ]; then hdiutil detach "$MNT" >/dev/null 2>&1; exit 1; fi
        rm -rf "$APP.melon-old"
        mv "$APP" "$APP.melon-old" || exit 1
        if ! ditto "$SRC" "$APP"; then
          rm -rf "$APP"
          if mv "$APP.melon-old" "$APP"; then open "$APP"; fi
          hdiutil detach "$MNT" >/dev/null 2>&1 || true
          rm -rf "$MNT" "$DMG"
          exit 1
        fi
        xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
        hdiutil detach "$MNT" >/dev/null 2>&1 || true
        open "$APP"
        # A broken update must not leave the user without a working app. Keep
        # the old bundle until the new process is actually visible, then roll
        # back if it never starts (bad build, quarantine, missing dylib).
        LAUNCHED=0
        for _ in $(seq 1 15); do
          if /usr/bin/pgrep -f "$APP/Contents/MacOS/MelonTools" >/dev/null 2>&1; then
            LAUNCHED=1
            break
          fi
          sleep 1
        done
        if [ "$LAUNCHED" -ne 1 ]; then
          echo "The new bundle did not start; restoring the previous one."
          rm -rf "$APP.melon-failed"
          if mv "$APP" "$APP.melon-failed" 2>/dev/null; then :; else rm -rf "$APP"; fi
          if mv "$APP.melon-old" "$APP"; then open "$APP"; fi
          rm -rf "$APP.melon-failed" "$MNT" "$DMG"
          rm -- "$0"
          exit 1
        fi
        rm -rf "$APP.melon-old" "$MNT" "$DMG"
        rm -- "$0"
        """
    }
}
