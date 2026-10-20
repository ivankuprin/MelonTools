import XCTest
@testable import MelonTools

/// The updater's pure logic: numeric version comparison, the URL allowlist
/// and the `.sha256` sidecar parser. Network and file operations stay
/// untested here on purpose.
final class UpdaterTests: XCTestCase {
    func testNumericallyNewerVersions() {
        XCTAssertTrue(UpdaterStore.Version.isNewer("1.4.10", than: "1.4.9"))
        XCTAssertFalse(UpdaterStore.Version.isNewer("1.4.9", than: "1.4.10"))
        XCTAssertTrue(UpdaterStore.Version.isNewer("1.5", than: "1.4.9"))
        XCTAssertTrue(UpdaterStore.Version.isNewer("2.0.0", than: "1.99.99"))
    }

    func testEqualAndPaddedVersionsAreNotNewer() {
        XCTAssertFalse(UpdaterStore.Version.isNewer("1.4.7", than: "1.4.7"))
        XCTAssertFalse(UpdaterStore.Version.isNewer("1.4", than: "1.4.0"))
        XCTAssertFalse(UpdaterStore.Version.isNewer("1.4.0", than: "1.4"))
        XCTAssertTrue(UpdaterStore.Version.isNewer("1.4.1", than: "1.4"))
    }

    func testOnlyGitHubHostsOverHTTPSAreAllowed() {
        XCTAssertTrue(UpdaterStore.isAllowed(URL(string: "https://api.github.com/repos/x/y/releases/latest")!))
        XCTAssertTrue(UpdaterStore.isAllowed(URL(string: "https://github.com/ivankuprin/MelonTools/releases/download/v1/x.dmg")!))
        XCTAssertTrue(UpdaterStore.isAllowed(URL(string: "https://objects.githubusercontent.com/blob")!))
        XCTAssertFalse(UpdaterStore.isAllowed(URL(string: "http://github.com/x")!))
        XCTAssertFalse(UpdaterStore.isAllowed(URL(string: "https://evil.example.com/x")!))
        XCTAssertFalse(UpdaterStore.isAllowed(URL(string: "https://github.com.evil.example.com/x")!))
    }

    func testReleaseAssetCDNHostIsAllowed() {
        XCTAssertTrue(UpdaterStore.isAllowed(URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/123/asset.dmg")!))
    }

    func testReleaseAssetCDNLookalikesAndHTTPAreRejected() {
        XCTAssertFalse(UpdaterStore.isAllowed(URL(string: "https://release-assets.githubusercontent.com.evil.example/x")!))
        XCTAssertFalse(UpdaterStore.isAllowed(URL(string: "https://evil-release-assets.githubusercontent.com/x")!))
        XCTAssertFalse(UpdaterStore.isAllowed(URL(string: "http://release-assets.githubusercontent.com/x")!))
    }

    func testSha256SidecarParsing() {
        let hash = String(repeating: "a", count: 64)
        XCTAssertEqual(UpdaterStore.parseSha256File("\(hash)  MelonTools-1.4.8.dmg\n"), hash)
        XCTAssertEqual(UpdaterStore.parseSha256File("\(hash)\n"), hash)
        XCTAssertNil(UpdaterStore.parseSha256File("not-a-hash file.dmg"))
        XCTAssertNil(UpdaterStore.parseSha256File(""))
        XCTAssertNil(UpdaterStore.parseSha256File(String(repeating: "f", count: 63)))
    }

    func testPeriodicTimerStillHonoursTheDailyThrottle() {
        XCTAssertEqual(UpdaterStore.periodicCheckInterval, 6 * 3600)
        XCTAssertEqual(UpdaterStore.automaticCheckThrottle, 24 * 3600)
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(UpdaterStore.shouldCheckAutomatically(lastCheck: now.addingTimeInterval(-23 * 3600), now: now))
        XCTAssertFalse(UpdaterStore.shouldCheckAutomatically(lastCheck: now.addingTimeInterval(-24 * 3600), now: now))
        XCTAssertTrue(UpdaterStore.shouldCheckAutomatically(lastCheck: now.addingTimeInterval(-25 * 3600), now: now))
        XCTAssertTrue(UpdaterStore.shouldCheckAutomatically(lastCheck: .distantPast, now: now))
    }

    func testInstallerScriptKeepsTheOldBundleUntilTheNewAppRuns() throws {
        let script = UpdaterStore.installerScript(
            appPath: "/Applications/Melon Tools.app",
            dmgPath: "/tmp/MelonTools-1.7.0.dmg",
            pid: 4242
        )
        XCTAssertTrue(script.contains("PID=4242"))
        XCTAssertTrue(script.contains("APP=\"/Applications/Melon Tools.app\""))
        XCTAssertTrue(script.contains("/usr/bin/pgrep -f \"$APP/Contents/MacOS/MelonTools\""))

        let probe = try XCTUnwrap(script.range(of: "LAUNCHED=0"))
        let pgrep = try XCTUnwrap(script.range(of: "/usr/bin/pgrep -f"))
        let rollback = try XCTUnwrap(script.range(of: "The new bundle did not start; restoring the previous one."))
        let restore = try XCTUnwrap(script.range(of: "mv \"$APP.melon-old\" \"$APP\"", options: [], range: rollback.lowerBound..<script.endIndex))
        let successCleanup = try XCTUnwrap(script.range(of: "rm -rf \"$APP.melon-old\" \"$MNT\" \"$DMG\""))
        XCTAssertLessThan(probe.lowerBound, pgrep.lowerBound)
        XCTAssertLessThan(pgrep.lowerBound, rollback.lowerBound)
        XCTAssertLessThan(rollback.lowerBound, restore.lowerBound)
        XCTAssertLessThan(pgrep.lowerBound, successCleanup.lowerBound)
    }

    func testInstallerScriptIsSyntacticallyValid() throws {
        let script = UpdaterStore.installerScript(
            appPath: "/Applications/Melon Tools.app",
            dmgPath: "/tmp/MelonTools-1.7.0.dmg",
            pid: 4242
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdaterScriptTests-\(UUID().uuidString).sh")
        defer { try? FileManager.default.removeItem(at: url) }
        try script.write(to: url, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}

/// The secrets writer must never leave a half-written or world-readable file:
/// an interrupted write keeps the previous contents, and every write is 0600.
final class SecureFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecureFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }

    func testWriteCreatesFileWithContentsAnd0600() throws {
        let url = directory.appendingPathComponent("auth.json")
        let payload = Data(#"{"token":"secret"}"#.utf8)

        try SecureFile.write(payload, to: url)

        XCTAssertEqual(try Data(contentsOf: url), payload)
        XCTAssertEqual(try permissions(of: url) & 0o777, 0o600)
    }

    func testOverwriteReplacesContentsAndKeepsMode() throws {
        let url = directory.appendingPathComponent("auth.json")
        try SecureFile.write("first", to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        try SecureFile.write("second payload", to: url)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "second payload")
        XCTAssertEqual(try permissions(of: url) & 0o777, 0o600)
    }

    func testWriteLeavesNoTemporarySibling() throws {
        let url = directory.appendingPathComponent("auth.json")

        try SecureFile.write("payload", to: url)

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names, ["auth.json"])
    }

    func testFailedWriteKeepsThePreviousFile() throws {
        let url = directory.appendingPathComponent("auth.json")
        try SecureFile.write("stable", to: url)
        // A directory cannot be replaced by rename(2), so the write must throw
        // and the original file must survive untouched.
        let blocked = directory.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)

        XCTAssertThrowsError(try SecureFile.write("replacement", to: blocked))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "stable")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(".blocked.") }
        XCTAssertTrue(leftovers.isEmpty, "a failed write must remove its temp file")
    }
}
