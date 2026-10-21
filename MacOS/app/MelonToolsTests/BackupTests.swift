import XCTest
@testable import MelonTools

/// Backup contract tests: portable envelope shape, round-trip of every
/// component, wrong password and malformed input safety, no plaintext secrets,
/// and auth filename traversal. Every test runs in a temporary support
/// directory and an isolated UserDefaults suite.
final class BackupTests: XCTestCase {
    private var root: URL!
    private var supportDir: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    private let password = "correct horse battery staple"
    private let accessToken = "eyJhbGciOiJSUzI1NiJ9.SECRET-ACCESS-TOKEN-abcdef123456.signature"
    private let refreshToken = "refresh-token-SECRET-0987654321"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-tests-\(UUID().uuidString)", isDirectory: true)
        supportDir = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)

        suiteName = "backup-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Round trip

    func testExportImportRoundTripRestoresEveryComponent() throws {
        let scheduler = sampleScheduler()
        let vault = sampleVault()
        let auth = sampleAuth()
        let modelSources: [String: Any] = [
            "openRouterKey": "sk-or-SECRET-model-key",
            "sources": [],
        ]
        let authName = "codex-user-12345678.json"

        try writeJSON(scheduler, to: supportDir.appendingPathComponent("scheduler.json"))
        try writeJSON(vault, to: supportDir.appendingPathComponent("codex/accounts.json"))
        try writeJSON(auth, to: supportDir.appendingPathComponent("gateway/auths/\(authName)"))
        try writeJSON(modelSources, to: supportDir.appendingPathComponent("model-sources.json"))

        // Files that must never enter the backup.
        try SecureFile.write("not json", to: supportDir.appendingPathComponent("gateway/auths/broken.json"))
        try SecureFile.write("lock", to: supportDir.appendingPathComponent("gateway/auths/codex.lock"))
        try SecureFile.write("melon-gateway-key", to: supportDir.appendingPathComponent("gateway/api-key"))
        try SecureFile.write("melon-mgmt-secret", to: supportDir.appendingPathComponent("gateway/management-secret"))
        try SecureFile.write("gateway: config", to: supportDir.appendingPathComponent("gateway/config.yaml"))
        try SecureFile.write("log line", to: supportDir.appendingPathComponent("gateway/gateway.log"))

        seedSettings()

        let payload = try BackupService.makePayload(supportDir: supportDir, defaults: defaults)
        XCTAssertEqual(payload.auths.keys.sorted(), [authName])
        XCTAssertEqual(payload.schedulerTasks, 1)
        XCTAssertEqual(payload.schedulerHistory, 1)
        XCTAssertEqual(payload.accounts, 1)
        XCTAssertEqual(payload.settingsKeys, 11)
        XCTAssertNotNil(payload.modelSources)
        XCTAssertTrue(payload.jsonObject()["settingsWindows"] is NSNull)

        let payloadText = String(data: try payload.encoded(), encoding: .utf8) ?? ""
        XCTAssertFalse(payloadText.contains("melon-gateway-key"))
        XCTAssertFalse(payloadText.contains("melon-mgmt-secret"))

        let backupURL = root.appendingPathComponent("melon-backup-2.3.0.melon")
        let exportSummary = try BackupService.export(
            to: backupURL,
            password: password,
            supportDir: supportDir,
            defaults: defaults
        )
        XCTAssertEqual(exportSummary.schedulerTasks, 1)
        XCTAssertEqual(exportSummary.schedulerHistory, 1)
        XCTAssertEqual(exportSummary.accounts, 1)
        XCTAssertEqual(exportSummary.authFiles, 1)
        XCTAssertTrue(exportSummary.modelSourcesIncluded)
        XCTAssertEqual(exportSummary.settingsKeys, 11)

        XCTAssertEqual(try permissions(at: backupURL), 0o600)
        XCTAssertNotNil(BackupService.lastBackupAt(in: defaults))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))

        // Change every live component before the import.
        try writeJSON(["tasks": [], "history": []], to: supportDir.appendingPathComponent("scheduler.json"))
        try writeJSON(["accounts": [], "currentAccountId": NSNull()], to: supportDir.appendingPathComponent("codex/accounts.json"))
        try FileManager.default.removeItem(at: supportDir.appendingPathComponent("gateway/auths/\(authName)"))
        try writeJSON(["openRouterKey": "changed", "sources": []], to: supportDir.appendingPathComponent("model-sources.json"))

        defaults.set(19_999, forKey: "gatewayPort")
        defaults.set(true, forKey: "gatewayAutoStart")
        defaults.removeObject(forKey: "gatewayStopOnQuit")
        defaults.set(0, forKey: "quotaRefreshInterval")
        defaults.set(false, forKey: "quotaNotifications")
        defaults.set(true, forKey: "taskNotifications")
        defaults.set("auto", forKey: "codexRoutingStrategy")
        defaults.set([], forKey: "accountPriorityOrder")
        defaults.set("/tmp/other-codex", forKey: "codexHome")
        defaults.set("en", forKey: "appLanguage")
        defaults.set(false, forKey: "dashboard.showPoolHealth")
        defaults.set("keep-me", forKey: "unrelated.setting")

        // An unrelated auth file must survive the import.
        let unrelatedAuth = supportDir.appendingPathComponent("gateway/auths/claude-keep.json")
        try writeJSON(["keep": true], to: unrelatedAuth)

        let importSummary = try BackupService.import(
            from: backupURL,
            password: password,
            supportDir: supportDir,
            defaults: defaults
        )
        XCTAssertEqual(importSummary.schedulerTasks, 1)
        XCTAssertEqual(importSummary.schedulerHistory, 1)
        XCTAssertEqual(importSummary.accounts, 1)
        XCTAssertEqual(importSummary.authFiles, 1)
        XCTAssertTrue(importSummary.modelSourcesIncluded)
        XCTAssertEqual(importSummary.settingsKeys, 11)

        XCTAssertTrue(try readJSON(supportDir.appendingPathComponent("scheduler.json"))
            .isEqual(to: scheduler))
        XCTAssertTrue(try readJSON(supportDir.appendingPathComponent("codex/accounts.json"))
            .isEqual(to: vault))
        XCTAssertTrue(try readJSON(supportDir.appendingPathComponent("gateway/auths/\(authName)"))
            .isEqual(to: auth))
        XCTAssertTrue(try readJSON(supportDir.appendingPathComponent("model-sources.json"))
            .isEqual(to: modelSources))

        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedAuth.path))
        XCTAssertTrue(try readJSON(unrelatedAuth).isEqual(to: ["keep": true]))

        // Gateway secrets are neither included nor touched.
        XCTAssertEqual(try String(contentsOf: supportDir.appendingPathComponent("gateway/api-key"), encoding: .utf8), "melon-gateway-key")
        XCTAssertEqual(try String(contentsOf: supportDir.appendingPathComponent("gateway/management-secret"), encoding: .utf8), "melon-mgmt-secret")

        XCTAssertEqual(defaults.integer(forKey: "gatewayPort"), 18_317)
        XCTAssertFalse(defaults.bool(forKey: "gatewayAutoStart"))
        XCTAssertTrue(defaults.bool(forKey: "gatewayStopOnQuit"))
        XCTAssertEqual(defaults.integer(forKey: "quotaRefreshInterval"), 600)
        XCTAssertTrue(defaults.bool(forKey: "quotaNotifications"))
        XCTAssertFalse(defaults.bool(forKey: "taskNotifications"))
        XCTAssertEqual(defaults.string(forKey: "codexRoutingStrategy"), "manual")
        XCTAssertEqual(defaults.stringArray(forKey: "accountPriorityOrder"), ["acct-1"])
        XCTAssertEqual(defaults.string(forKey: "codexHome"), "~/.codex")
        XCTAssertEqual(defaults.string(forKey: "appLanguage"), "ru")
        XCTAssertTrue(defaults.bool(forKey: "dashboard.showPoolHealth"))
        XCTAssertEqual(defaults.string(forKey: "unrelated.setting"), "keep-me")

        XCTAssertEqual(try permissions(at: supportDir.appendingPathComponent("scheduler.json")), 0o600)
        XCTAssertEqual(try permissions(at: supportDir.appendingPathComponent("gateway/auths")), 0o700)
        XCTAssertEqual(try permissions(at: supportDir.appendingPathComponent("gateway/auths/\(authName)")), 0o600)
    }

    func testStructurallyDamagedPayloadDoesNotTouchLiveFiles() throws {
        let schedulerURL = supportDir.appendingPathComponent("scheduler.json")
        try writeJSON(sampleScheduler(), to: schedulerURL)
        let before = try Data(contentsOf: schedulerURL)

        let damaged: [String: Any] = [
            "scheduler": ["tasks": "not an array"],
            "vault": sampleVault(),
        ]
        let payload = try JSONSerialization.data(withJSONObject: damaged)
        XCTAssertThrowsError(
            try BackupService.restorePayload(payload, supportDir: supportDir, defaults: defaults)
        )
        XCTAssertEqual(try Data(contentsOf: schedulerURL), before)
    }

    func testCodexHomeCannotEscapeTheConventionalDirectory() {
        defaults.removeObject(forKey: "codexHome")
        _ = BackupService.restoreSettings(
            ["codexHome": "~/../../private/tmp/escape"],
            into: defaults
        )
        XCTAssertNil(defaults.string(forKey: "codexHome"))

        _ = BackupService.restoreSettings(
            ["codexHome": FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents").path],
            into: defaults
        )
        XCTAssertNil(defaults.string(forKey: "codexHome"))

        _ = BackupService.restoreSettings(["codexHome": "~/.codex"], into: defaults)
        XCTAssertEqual(defaults.string(forKey: "codexHome"), "~/.codex")
    }

    // MARK: - KDF portability

    /// PBKDF2-HMAC-SHA256, 210 000 rounds, 32-byte output. The expected bytes
    /// come from the reference implementation (Python hashlib / OpenSSL):
    /// a Rust backend using the same parameters must derive the same key.
    func testPBKDF2MatchesReferenceVector() throws {
        let salt = Data("0123456789abcdef".utf8)
        let key = try BackupService.deriveKey(
            password: "melon-tools-test",
            salt: salt,
            iterations: 210_000
        )
        let bytes = key.withUnsafeBytes { Data($0) }
        XCTAssertEqual(
            hex(bytes),
            "381d4dfbe8e6687fab5beab3ae936d2b1c7f9fa082552ac90842cc2da2578eba"
        )
    }

    // MARK: - Wrong password

    func testWrongPasswordFailsWithoutTouchingLiveFiles() throws {
        let scheduler = sampleScheduler()
        let vault = sampleVault()
        let schedulerURL = supportDir.appendingPathComponent("scheduler.json")
        let vaultURL = supportDir.appendingPathComponent("codex/accounts.json")
        let authURL = supportDir.appendingPathComponent("gateway/auths/codex-user-12345678.json")

        try writeJSON(scheduler, to: schedulerURL)
        try writeJSON(vault, to: vaultURL)
        try writeJSON(sampleAuth(), to: authURL)
        seedSettings()

        let backupURL = root.appendingPathComponent("backup.melon")
        _ = try BackupService.export(
            to: backupURL,
            password: password,
            supportDir: supportDir,
            defaults: defaults
        )

        let schedulerBytes = try Data(contentsOf: schedulerURL)
        let vaultBytes = try Data(contentsOf: vaultURL)
        let authBytes = try Data(contentsOf: authURL)
        let lastBackup = BackupService.lastBackupAt(in: defaults)
        let port = defaults.integer(forKey: "gatewayPort")

        XCTAssertThrowsError(
            try BackupService.import(
                from: backupURL,
                password: "wrong password",
                supportDir: supportDir,
                defaults: defaults
            )
        ) { error in
            guard case BackupService.BackupError.wrongPasswordOrCorrupt = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: schedulerURL), schedulerBytes)
        XCTAssertEqual(try Data(contentsOf: vaultURL), vaultBytes)
        XCTAssertEqual(try Data(contentsOf: authURL), authBytes)
        XCTAssertEqual(BackupService.lastBackupAt(in: defaults), lastBackup)
        XCTAssertEqual(defaults.integer(forKey: "gatewayPort"), port)
    }

    // MARK: - Malformed / unsupported envelopes

    func testMalformedAndUnsupportedEnvelopesFailSafely() throws {
        let schedulerURL = supportDir.appendingPathComponent("scheduler.json")
        try writeJSON(sampleScheduler(), to: schedulerURL)
        try writeJSON(sampleVault(), to: supportDir.appendingPathComponent("codex/accounts.json"))
        seedSettings()

        let backupURL = root.appendingPathComponent("backup.melon")
        _ = try BackupService.export(
            to: backupURL,
            password: password,
            supportDir: supportDir,
            defaults: defaults
        )
        let liveBytes = try Data(contentsOf: schedulerURL)

        let unsupportedVersionURL = root.appendingPathComponent("version.melon")
        try copy(backupURL, to: unsupportedVersionURL)
        try mutateEnvelope(at: unsupportedVersionURL) { $0["formatVersion"] = 2 }
        XCTAssertThrowsError(
            try BackupService.import(from: unsupportedVersionURL, password: password, supportDir: supportDir, defaults: defaults)
        ) { error in
            guard case BackupService.BackupError.unsupportedFormatVersion(2) = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let unsupportedFormatURL = root.appendingPathComponent("format.melon")
        try copy(backupURL, to: unsupportedFormatURL)
        try mutateEnvelope(at: unsupportedFormatURL) { $0["format"] = "other-backup" }
        XCTAssertThrowsError(
            try BackupService.import(from: unsupportedFormatURL, password: password, supportDir: supportDir, defaults: defaults)
        ) { error in
            guard case BackupService.BackupError.unsupportedFormat("other-backup") = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let weakKDFURL = root.appendingPathComponent("kdf.melon")
        try copy(backupURL, to: weakKDFURL)
        try mutateEnvelope(at: weakKDFURL) { object in
            var kdf = object["kdf"] as? [String: Any] ?? [:]
            kdf["iterations"] = 1_000
            object["kdf"] = kdf
        }
        XCTAssertThrowsError(
            try BackupService.import(from: weakKDFURL, password: password, supportDir: supportDir, defaults: defaults)
        ) { error in
            guard case BackupService.BackupError.invalidKDFParameters = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let badPayloadURL = root.appendingPathComponent("payload.melon")
        try copy(backupURL, to: badPayloadURL)
        try mutateEnvelope(at: badPayloadURL) { $0["payload"] = "!!!not-base64!!!" }
        XCTAssertThrowsError(
            try BackupService.import(from: badPayloadURL, password: password, supportDir: supportDir, defaults: defaults)
        ) { error in
            guard case BackupService.BackupError.malformedEnvelope = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let garbageURL = root.appendingPathComponent("garbage.melon")
        try SecureFile.write(Data("this is not a backup".utf8), to: garbageURL)
        XCTAssertThrowsError(
            try BackupService.import(from: garbageURL, password: password, supportDir: supportDir, defaults: defaults)
        ) { error in
            guard case BackupService.BackupError.malformedEnvelope = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        XCTAssertThrowsError(
            try BackupService.import(from: backupURL, password: "", supportDir: supportDir, defaults: defaults)
        ) { error in
            guard case BackupService.BackupError.emptyPassword = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        XCTAssertThrowsError(
            try BackupService.restorePayload(Data("[]".utf8), supportDir: supportDir, defaults: defaults)
        ) { error in
            guard case BackupService.BackupError.malformedPayload = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        XCTAssertThrowsError(
            try BackupService.restorePayload(
                Data(#"{"scheduler":"not an object"}"#.utf8),
                supportDir: supportDir,
                defaults: defaults
            )
        ) { error in
            guard case BackupService.BackupError.malformedPayload = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: schedulerURL), liveBytes)
        XCTAssertEqual(defaults.integer(forKey: "gatewayPort"), 18_317)
    }

    // MARK: - No plaintext secrets

    func testExportedBytesContainNoPlaintextTokens() throws {
        try writeJSON(sampleVault(), to: supportDir.appendingPathComponent("codex/accounts.json"))
        try writeJSON(
            sampleAuth(),
            to: supportDir.appendingPathComponent("gateway/auths/codex-user-12345678.json")
        )
        try writeJSON(
            ["openRouterKey": "sk-or-SECRET-model-key", "sources": []],
            to: supportDir.appendingPathComponent("model-sources.json")
        )

        let backupURL = root.appendingPathComponent("secrets.melon")
        _ = try BackupService.export(
            to: backupURL,
            password: password,
            supportDir: supportDir,
            defaults: defaults
        )

        let raw = try Data(contentsOf: backupURL)
        let text = String(data: raw, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains(accessToken))
        XCTAssertFalse(text.contains(refreshToken))
        XCTAssertFalse(text.contains("sk-or-SECRET-model-key"))
        XCTAssertFalse(text.contains("id-token-SECRET"))
        XCTAssertFalse(text.contains(password))

        let envelope = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        )
        XCTAssertEqual(envelope["format"] as? String, BackupService.format)
        XCTAssertEqual(envelope["formatVersion"] as? Int, BackupService.formatVersion)
        XCTAssertEqual(envelope["appVersion"] as? String, "2.3.0")

        let kdf = try XCTUnwrap(envelope["kdf"] as? [String: Any])
        XCTAssertEqual(kdf["name"] as? String, "PBKDF2-HMAC-SHA256")
        XCTAssertEqual(kdf["iterations"] as? Int, 210_000)
        let salt = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(kdf["salt"] as? String)))
        XCTAssertEqual(salt.count, 16)

        let cipher = try XCTUnwrap(envelope["cipher"] as? [String: Any])
        XCTAssertEqual(cipher["name"] as? String, "AES-256-GCM")
        let nonce = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(cipher["nonce"] as? String)))
        XCTAssertEqual(nonce.count, 12)

        let combined = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(envelope["payload"] as? String)))
        XCTAssertGreaterThan(combined.count, 16)
    }

    // MARK: - Auth filename traversal

    func testAuthFilenameTraversalIsIgnored() throws {
        let safeAuth: [String: Any] = ["access_token": "safe-token", "type": "codex"]
        let payload: [String: Any] = [
            "auths": [
                "safe.json": safeAuth,
                "../escape.json": ["access_token": "evil-token"],
                "nested/escape.json": ["access_token": "evil-token"],
                "nul\u{0}.json": ["access_token": "evil-token"],
                "codex.lock": ["access_token": "evil-token"],
                "broken.json": "not an object",
            ],
            "scheduler": ["tasks": [], "history": []],
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let envelope = try BackupService.seal(payload: payloadData, password: password, createdAt: Date())
        let backupURL = root.appendingPathComponent("traversal.melon")
        try SecureFile.write(envelope, to: backupURL)

        let summary = try BackupService.import(
            from: backupURL,
            password: password,
            supportDir: supportDir,
            defaults: defaults
        )
        XCTAssertEqual(summary.authFiles, 1)

        let authsDir = supportDir.appendingPathComponent("gateway/auths")
        let names = try FileManager.default.contentsOfDirectory(atPath: authsDir.path).sorted()
        XCTAssertEqual(names, ["safe.json"])
        XCTAssertTrue(try readJSON(authsDir.appendingPathComponent("safe.json")).isEqual(to: safeAuth))

        for candidate in [
            root.appendingPathComponent("escape.json"),
            supportDir.appendingPathComponent("escape.json"),
            supportDir.appendingPathComponent("gateway/escape.json"),
            authsDir.appendingPathComponent("escape.json"),
        ] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: candidate.path),
                "traversal wrote \(candidate.path)"
            )
        }

        XCTAssertTrue(BackupService.isSafeAuthFileName("codex-account.json"))
        XCTAssertFalse(BackupService.isSafeAuthFileName("../escape.json"))
        XCTAssertFalse(BackupService.isSafeAuthFileName("nested/escape.json"))
        XCTAssertFalse(BackupService.isSafeAuthFileName("nul\u{0}.json"))
        XCTAssertFalse(BackupService.isSafeAuthFileName("codex.lock"))
        XCTAssertFalse(BackupService.isSafeAuthFileName(".hidden.json"))
    }

    // MARK: - Fixtures

    private func sampleScheduler() -> [String: Any] {
        [
            "tasks": [
                [
                    "id": "task-1",
                    "name": "Nightly summary",
                    "prompt": "Summarize the repo",
                    "model": "gpt-5.1",
                    "enabled": true,
                    "intervalMinutes": 60,
                    "createdAt": 1_760_000_000.0,
                    "lastStatus": "never",
                    "lastResult": "",
                ],
            ],
            "history": [
                [
                    "taskId": "task-1",
                    "at": 1_760_000_100.0,
                    "status": "ok",
                    "model": "gpt-5.1",
                    "durationMs": 120,
                    "result": "done",
                ],
            ],
        ]
    }

    private func sampleVault() -> [String: Any] {
        [
            "accounts": [
                [
                    "id": "acct-1",
                    "email": "user@example.com",
                    "tokens": [
                        "access_token": accessToken,
                        "refresh_token": refreshToken,
                        "id_token": "id-token-SECRET",
                    ],
                    "lastRefresh": "2026-10-21T00:00:00Z",
                    "addedAt": 0,
                ],
            ],
            "currentAccountId": "acct-1",
        ]
    }

    private func sampleAuth() -> [String: Any] {
        [
            "access_token": accessToken,
            "refresh_token": refreshToken,
            "id_token": "id-token-SECRET",
            "email": "user@example.com",
            "type": "codex",
            "priority": 1,
        ]
    }

    private func seedSettings() {
        defaults.set(18_317, forKey: "gatewayPort")
        defaults.set(false, forKey: "gatewayAutoStart")
        defaults.set(true, forKey: "gatewayStopOnQuit")
        defaults.set(600, forKey: "quotaRefreshInterval")
        defaults.set(true, forKey: "quotaNotifications")
        defaults.set(false, forKey: "taskNotifications")
        defaults.set("manual", forKey: "codexRoutingStrategy")
        defaults.set(["acct-1"], forKey: "accountPriorityOrder")
        defaults.set("~/.codex", forKey: "codexHome")
        defaults.set("ru", forKey: "appLanguage")
        defaults.set(true, forKey: "dashboard.showPoolHealth")
    }

    // MARK: - Helpers

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try SecureFile.write(data, to: url)
    }

    private func readJSON(_ url: URL) throws -> NSDictionary {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "BackupTests", code: 1)
        }
        return object as NSDictionary
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        return mode & 0o777
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func copy(_ source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func mutateEnvelope(
        at url: URL,
        _ mutate: (inout [String: Any]) -> Void
    ) throws {
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        mutate(&object)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try SecureFile.write(data, to: url)
    }
}
