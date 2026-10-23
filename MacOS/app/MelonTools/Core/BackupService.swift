import CommonCrypto
import CoreFoundation
import CryptoKit
import Foundation
import Security

// MARK: - Envelope

/// Portable encrypted backup envelope shared with the future Rust
/// implementation. The shape is frozen by `formatVersion`:
///
/// ```json
/// {
///   "format": "melon-backup",
///   "formatVersion": 1,
///   "appVersion": "2.3.5",
///   "createdAt": 1760000000,
///   "kdf": { "name": "PBKDF2-HMAC-SHA256", "iterations": 210000,
///            "salt": "<base64 16 bytes>" },
///   "cipher": { "name": "AES-256-GCM", "nonce": "<base64 12 bytes>" },
///   "payload": "<base64 ciphertext||16-byte tag>"
/// }
/// ```
struct BackupEnvelope: Codable, Equatable {
    struct KDF: Codable, Equatable {
        var name: String
        var iterations: Int
        var salt: String
    }

    struct Cipher: Codable, Equatable {
        var name: String
        var nonce: String
    }

    var format: String
    var formatVersion: Int
    var appVersion: String
    var createdAt: Int
    var kdf: KDF
    var cipher: Cipher
    var payload: String
}

/// What one export or import did. Counts only — no account names and no
/// secret values, so the summary can be shown in the UI and written to logs.
struct BackupSummary: Equatable {
    var schedulerTasks: Int
    var schedulerHistory: Int
    var accounts: Int
    var authFiles: Int
    var modelSourcesIncluded: Bool
    var settingsKeys: Int
}

/// Decrypted payload before it is written as the portable JSON object.
struct BackupPayload {
    var scheduler: [String: Any]?
    var vault: [String: Any]?
    var auths: [String: [String: Any]]
    var modelSources: [String: Any]?
    var settings: [String: Any]

    var schedulerTasks: Int { Self.arrayCount(scheduler?["tasks"]) }
    var schedulerHistory: Int { Self.arrayCount(scheduler?["history"]) }
    var accounts: Int { Self.arrayCount(vault?["accounts"]) }
    var settingsKeys: Int { settings.count }

    /// Portable payload object. `settingsWindows` is written as `null` on
    /// macOS: Windows readers may ignore it, macOS readers ignore the field.
    func jsonObject() -> [String: Any] {
        var object: [String: Any] = [:]
        if let scheduler { object["scheduler"] = scheduler }
        if let vault { object["vault"] = vault }
        object["auths"] = auths
        if let modelSources { object["modelSources"] = modelSources }
        object["settingsMac"] = settings
        object["settingsWindows"] = NSNull()
        return object
    }

    func encoded() throws -> Data {
        try JSONSerialization.data(
            withJSONObject: jsonObject(),
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    private static func arrayCount(_ value: Any?) -> Int {
        (value as? [Any])?.count ?? 0
    }
}

// MARK: - Backup service

/// Encrypted backup / export / import.
///
/// The envelope is independent of both app implementations: PBKDF2-HMAC-SHA256
/// (210 000 iterations, 32-byte key), AES-256-GCM with a random 12-byte nonce,
/// and a random 16-byte salt. The password exists only in memory and is never
/// written to the backup, to defaults or to a log.
///
/// The payload embeds raw JSON objects so a Rust reader does not have to know
/// Swift model shapes:
/// `scheduler`, `vault`, `auths` (filename → object), `modelSources`,
/// `settingsMac`, `settingsWindows` (ignored here).
///
/// Import decrypts and validates the whole payload before it writes one live
/// file. Files are written through `SecureFile` (0600, atomic rename); the
/// auth directory is created with mode 0700. Unrelated files are never
/// deleted, and the gateway API key / management secret are never included.
enum BackupService {
    // MARK: Format constants

    static let format = "melon-backup"
    static let formatVersion = 1
    /// Product version recorded in the envelope. Bumped with the release
    /// metadata; the Rust implementation writes its own value.
    static let appVersion = "2.3.5"
    static let kdfName = "PBKDF2-HMAC-SHA256"
    static let cipherName = "AES-256-GCM"
    static let iterations = 210_000
    static let minimumIterations = 210_000
    static let maximumIterations = 10_000_000
    static let saltLength = 16
    static let nonceLength = 12
    static let tagLength = 16
    static let keyLength = 32
    static let lastBackupKey = "backup.lastAt"

    /// Refuse absurd files before they are decrypted in memory.
    static let maximumBackupBytes = 128 * 1024 * 1024

    enum BackupError: LocalizedError {
        case emptyPassword
        case malformedEnvelope
        case unsupportedFormat(String)
        case unsupportedFormatVersion(Int)
        case unsupportedKDF(String)
        case unsupportedCipher(String)
        case invalidKDFParameters
        case wrongPasswordOrCorrupt
        case malformedPayload(String)
        case cryptoFailure(String)
        case ioFailure(String)

        var errorDescription: String? {
            switch self {
            case .emptyPassword:
                return "Enter a backup password."
            case .malformedEnvelope:
                return "This file is not a Melon Tools backup."
            case .unsupportedFormat(let name):
                return "Unsupported backup format: \(name)."
            case .unsupportedFormatVersion(let version):
                return "Unsupported backup format version \(version). Update Melon Tools."
            case .unsupportedKDF(let name):
                return "Unsupported backup encryption method: \(name)."
            case .unsupportedCipher(let name):
                return "Unsupported backup cipher: \(name)."
            case .invalidKDFParameters:
                return "The backup has invalid encryption parameters."
            case .wrongPasswordOrCorrupt:
                return "Wrong password or the backup file is damaged."
            case .malformedPayload(let detail):
                return "The backup payload is damaged: \(detail)."
            case .cryptoFailure(let detail):
                return "Backup encryption failed: \(detail)."
            case .ioFailure(let detail):
                return "Backup file error: \(detail)."
            }
        }
    }

    // MARK: - Last backup timestamp

    /// Timestamp of the last successful export (`backup.lastAt`). The getter
    /// and setter use `UserDefaults.standard`; tests pass an isolated suite to
    /// the `in:` helpers.
    static var lastBackupAt: Date? {
        get { lastBackupAt(in: .standard) }
        set { setLastBackupAt(newValue, in: .standard) }
    }

    static func lastBackupAt(in defaults: UserDefaults) -> Date? {
        defaults.object(forKey: lastBackupKey) as? Date
    }

    static func setLastBackupAt(_ date: Date?, in defaults: UserDefaults) {
        if let date {
            defaults.set(date, forKey: lastBackupKey)
        } else {
            defaults.removeObject(forKey: lastBackupKey)
        }
    }

    // MARK: - Export

    /// Build the encrypted envelope, write it with mode 0600 and remember the
    /// export time. The destination directory is created when missing.
    static func export(
        to url: URL,
        password: String,
        supportDir: URL = CodexStore.supportDir,
        defaults: UserDefaults = .standard
    ) throws -> BackupSummary {
        guard !password.isEmpty else { throw BackupError.emptyPassword }

        let payload = try makePayload(supportDir: supportDir, defaults: defaults)
        let payloadData = try payload.encoded()
        let envelopeData = try seal(payload: payloadData, password: password, createdAt: Date())
        try SecureFile.write(envelopeData, to: url)
        setLastBackupAt(Date(), in: defaults)

        return BackupSummary(
            schedulerTasks: payload.schedulerTasks,
            schedulerHistory: payload.schedulerHistory,
            accounts: payload.accounts,
            authFiles: payload.auths.count,
            modelSourcesIncluded: payload.modelSources != nil,
            settingsKeys: payload.settingsKeys
        )
    }

    // MARK: - Import

    /// Read, validate and decrypt the whole envelope, then restore the known
    /// components. Any error before the write phase leaves live data
    /// untouched. Existing files that the backup does not contain are kept.
    static func importBackup(
        from url: URL,
        password: String,
        supportDir: URL = CodexStore.supportDir,
        defaults: UserDefaults = .standard
    ) throws -> BackupSummary {
        guard !password.isEmpty else { throw BackupError.emptyPassword }
        let envelope = try readEnvelope(from: url)
        let key = try deriveKey(
            password: password,
            salt: try decodeBase64(envelope.kdf.salt),
            iterations: try validatedIterations(envelope.kdf.iterations)
        )
        let payloadData = try decrypt(envelope: envelope, key: key)
        return try restorePayload(payloadData, supportDir: supportDir, defaults: defaults)
    }

    /// Alias with the name the product specification uses.
    static func `import`(
        from url: URL,
        password: String,
        supportDir: URL = CodexStore.supportDir,
        defaults: UserDefaults = .standard
    ) throws -> BackupSummary {
        try importBackup(from: url, password: password, supportDir: supportDir, defaults: defaults)
    }

    // MARK: - Payload: collect

    /// Collect the portable components from one support directory.
    ///
    /// Only known files are read. Logs, caches, the gateway pid, the gateway
    /// config, the API key and the management secret are never touched.
    static func makePayload(
        supportDir: URL,
        defaults: UserDefaults = .standard
    ) throws -> BackupPayload {
        let scheduler = readJSONObject(at: supportDir.appendingPathComponent("scheduler.json"))
        let vault = readJSONObject(at: supportDir.appendingPathComponent("codex/accounts.json"))
        let modelSources = readJSONObject(at: supportDir.appendingPathComponent("model-sources.json"))
        let auths = readAuthEntries(
            from: supportDir.appendingPathComponent("gateway/auths", isDirectory: true)
        )
        return BackupPayload(
            scheduler: scheduler,
            vault: vault,
            auths: auths,
            modelSources: modelSources,
            settings: captureSettings(defaults)
        )
    }

    /// Every `*.json` in `gateway/auths` that parses as a JSON object.
    /// `.lock`, hidden, symlinked, corrupt and unsafe-named entries are skipped.
    static func readAuthEntries(from directory: URL) -> [String: [String: Any]] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else {
            return [:]
        }
        var result: [String: [String: Any]] = [:]
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = url.lastPathComponent
            guard isSafeAuthFileName(name) else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            guard let object = readJSONObject(at: url) else { continue }
            result[name] = object
        }
        return result
    }

    // MARK: - Payload: restore

    /// Validate a decrypted payload completely, then write scheduler, vault,
    /// auths, model sources and settings. The function is internal so tests can
    /// exercise traversal and malformed-payload cases without building a full
    /// envelope.
    private static func validateScheduler(_ object: [String: Any]) throws {
        do {
            let data = try encodeObject(object, context: "scheduler")
            _ = try JSONDecoder().decode(SchedulerFile.self, from: data)
        } catch let error as BackupError {
            throw error
        } catch {
            throw BackupError.malformedPayload("scheduler: \(error.localizedDescription)")
        }
    }

    private static func validateVault(_ object: [String: Any]) throws {
        do {
            let data = try encodeObject(object, context: "vault")
            _ = try JSONDecoder().decode(CodexStore.Vault.self, from: data)
        } catch let error as BackupError {
            throw error
        } catch {
            throw BackupError.malformedPayload("vault: \(error.localizedDescription)")
        }
    }

    static func restorePayload(
        _ data: Data,
        supportDir: URL,
        defaults: UserDefaults
    ) throws -> BackupSummary {
        let root = try parseObject(data, context: "payload")
        let scheduler = try optionalObject(root["scheduler"], name: "scheduler")
        let vault = try optionalObject(root["vault"], name: "vault")
        let modelSources = try optionalObject(root["modelSources"], name: "modelSources")
        let settings = try optionalObject(root["settingsMac"], name: "settingsMac") ?? [:]

        // A decryptable backup can still contain structurally damaged data.
        // Decode the exact live models before touching a single file; otherwise
        // the next app launch would quarantine the file and silently lose all
        // tasks or accounts.
        if let scheduler {
            try validateScheduler(scheduler)
        }
        if let vault {
            try validateVault(vault)
        }

        var auths: [(name: String, object: [String: Any])] = []
        if let rawAuths = root["auths"], !(rawAuths is NSNull) {
            guard let dictionary = rawAuths as? [String: Any] else {
                throw BackupError.malformedPayload("auths is not a JSON object")
            }
            for name in dictionary.keys.sorted() {
                // Unsafe names are ignored, never written: a hand-crafted
                // backup must not escape the auth directory.
                guard isSafeAuthFileName(name),
                      let object = dictionary[name] as? [String: Any] else { continue }
                auths.append((name, object))
            }
        }

        // Serialize every file before the first live write. A damaged payload
        // therefore cannot leave a half-restored directory.
        let fm = FileManager.default
        var files: [(url: URL, data: Data)] = []
        if let scheduler {
            files.append((
                supportDir.appendingPathComponent("scheduler.json"),
                try encodeObject(scheduler, context: "scheduler")
            ))
        }
        if let vault {
            files.append((
                supportDir.appendingPathComponent("codex/accounts.json"),
                try encodeObject(vault, context: "vault")
            ))
        }
        if let modelSources {
            files.append((
                supportDir.appendingPathComponent("model-sources.json"),
                try encodeObject(modelSources, context: "modelSources")
            ))
        }
        for auth in auths {
            files.append((
                supportDir
                    .appendingPathComponent("gateway/auths", isDirectory: true)
                    .appendingPathComponent(auth.name),
                try encodeObject(auth.object, context: "auths/\(auth.name)")
            ))
        }

        if !auths.isEmpty {
            let authsDir = supportDir.appendingPathComponent("gateway/auths", isDirectory: true)
            do {
                try fm.createDirectory(at: authsDir, withIntermediateDirectories: true)
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: authsDir.path)
            } catch {
                throw BackupError.ioFailure(error.localizedDescription)
            }
        }

        // Snapshot only the targets we are about to replace. If a write fails
        // (disk full, permission), put the previous bytes back so the profile
        // is not left with a mixed scheduler/vault/auth set.
        // A read failure on an existing target must abort before any write:
        // treating it as "absent" would delete the live file during rollback.
        var previous: [(URL, Data?)] = []
        for file in files {
            if fm.fileExists(atPath: file.url.path) {
                guard let snapshot = SecureFile.read(file.url) else {
                    throw BackupError.ioFailure(
                        "cannot snapshot \(file.url.lastPathComponent) before restore"
                    )
                }
                previous.append((file.url, snapshot))
            } else {
                previous.append((file.url, nil))
            }
        }
        do {
            for file in files {
                try SecureFile.write(file.data, to: file.url)
            }
        } catch {
            for (url, data) in previous.reversed() {
                if let data {
                    try? SecureFile.write(data, to: url)
                } else {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            throw BackupError.ioFailure(error.localizedDescription)
        }

        let settingsKeys = restoreSettings(settings, into: defaults)

        return BackupSummary(
            schedulerTasks: arrayCount(scheduler?["tasks"]),
            schedulerHistory: arrayCount(scheduler?["history"]),
            accounts: arrayCount(vault?["accounts"]),
            authFiles: auths.count,
            modelSourcesIncluded: modelSources != nil,
            settingsKeys: settingsKeys
        )
    }

    // MARK: - Encryption

    /// Build one envelope from payload bytes. Internal for tests that need a
    /// custom payload (for example a traversal auth name).
    static func seal(payload: Data, password: String, createdAt: Date) throws -> Data {
        guard !password.isEmpty else { throw BackupError.emptyPassword }
        let salt = try randomBytes(saltLength)
        let nonceData = try randomBytes(nonceLength)
        let key = try deriveKey(password: password, salt: salt, iterations: iterations)
        let sealed: AES.GCM.SealedBox
        do {
            let nonce = try AES.GCM.Nonce(data: nonceData)
            // No additional authenticated data: the Rust implementation must
            // pass none as well. The nonce lives in the envelope, so the
            // payload field is exactly ciphertext||tag.
            sealed = try AES.GCM.seal(payload, using: key, nonce: nonce)
        } catch {
            throw BackupError.cryptoFailure(error.localizedDescription)
        }
        let combined = sealed.ciphertext + sealed.tag
        let envelope = BackupEnvelope(
            format: format,
            formatVersion: formatVersion,
            appVersion: appVersion,
            createdAt: Int(createdAt.timeIntervalSince1970),
            kdf: BackupEnvelope.KDF(
                name: kdfName,
                iterations: iterations,
                salt: salt.base64EncodedString()
            ),
            cipher: BackupEnvelope.Cipher(
                name: cipherName,
                nonce: nonceData.base64EncodedString()
            ),
            payload: combined.base64EncodedString()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            return try encoder.encode(envelope)
        } catch {
            throw BackupError.cryptoFailure(error.localizedDescription)
        }
    }

    private static func readEnvelope(from url: URL) throws -> BackupEnvelope {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw BackupError.ioFailure("file not found")
        }
        let data: Data
        do {
            let attributes = try fm.attributesOfItem(atPath: url.path)
            if let size = attributes[.size] as? Int, size > maximumBackupBytes {
                throw BackupError.ioFailure("file is too large")
            }
            data = try Data(contentsOf: url)
        } catch let error as BackupError {
            throw error
        } catch {
            throw BackupError.ioFailure(error.localizedDescription)
        }
        guard data.count <= maximumBackupBytes else {
            throw BackupError.ioFailure("file is too large")
        }

        let envelope: BackupEnvelope
        do {
            envelope = try JSONDecoder().decode(BackupEnvelope.self, from: data)
        } catch {
            throw BackupError.malformedEnvelope
        }
        guard envelope.format == format else {
            throw BackupError.unsupportedFormat(envelope.format)
        }
        guard envelope.formatVersion == formatVersion else {
            throw BackupError.unsupportedFormatVersion(envelope.formatVersion)
        }
        guard envelope.kdf.name == kdfName else {
            throw BackupError.unsupportedKDF(envelope.kdf.name)
        }
        guard envelope.cipher.name == cipherName else {
            throw BackupError.unsupportedCipher(envelope.cipher.name)
        }
        return envelope
    }

    private static func decrypt(envelope: BackupEnvelope, key: SymmetricKey) throws -> Data {
        let salt = try decodeBase64(envelope.kdf.salt)
        guard salt.count == saltLength else { throw BackupError.invalidKDFParameters }
        let nonceData = try decodeBase64(envelope.cipher.nonce)
        guard nonceData.count == nonceLength else { throw BackupError.invalidKDFParameters }
        guard let combined = Data(base64Encoded: envelope.payload),
              combined.count > tagLength else {
            throw BackupError.malformedEnvelope
        }

        let ciphertext = combined.prefix(combined.count - tagLength)
        let tag = combined.suffix(tagLength)
        do {
            let nonce = try AES.GCM.Nonce(data: nonceData)
            // Counterpart of `seal`: no AAD.
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw BackupError.wrongPasswordOrCorrupt
        }
    }

    /// Internal (not private) so `BackupTests` can pin the PBKDF2 output to a
    /// reference vector. A future Rust reader must derive the same 32 bytes.
    static func deriveKey(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let rounds = try validatedIterations(iterations)
        guard salt.count >= saltLength else { throw BackupError.invalidKDFParameters }
        var keyData = Data(count: keyLength)
        let status: Int32 = keyData.withUnsafeMutableBytes { keyBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    password,
                    password.utf8.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(rounds),
                    keyBytes.bindMemory(to: UInt8.self).baseAddress,
                    keyLength
                )
            }
        }
        guard status == Int32(kCCSuccess) else {
            throw BackupError.cryptoFailure("PBKDF2 failed (\(status))")
        }
        return SymmetricKey(data: keyData)
    }

    private static func validatedIterations(_ value: Int) throws -> Int {
        guard value >= minimumIterations, value <= maximumIterations else {
            throw BackupError.invalidKDFParameters
        }
        return value
    }

    private static func randomBytes(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw BackupError.cryptoFailure("secure random generation failed")
        }
        return data
    }

    private static func decodeBase64(_ value: String) throws -> Data {
        guard let data = Data(base64Encoded: value) else {
            throw BackupError.invalidKDFParameters
        }
        return data
    }

    // MARK: - Settings

    /// UserDefaults keys that belong in a portable backup. Secrets (gateway
    /// API key, management secret) live in files and are never in defaults.
    static let settingKeys: [String] = [
        "gatewayPort",
        "gatewayAutoStart",
        "gatewayStopOnQuit",
        "quotaRefreshInterval",
        "quotaNotifications",
        "taskNotifications",
        "codexRoutingStrategy",
        "accountPriorityOrder",
        "codexHome",
        "appLanguage",
    ]

    private enum SettingKind {
        case bool
        case integer
        case string
        case stringArray
        case dashboard
    }

    private static func settingKind(for key: String) -> SettingKind? {
        switch key {
        case "gatewayPort", "quotaRefreshInterval":
            return .integer
        case "gatewayAutoStart", "gatewayStopOnQuit", "quotaNotifications", "taskNotifications":
            return .bool
        case "codexRoutingStrategy", "codexHome", "appLanguage":
            return .string
        case "accountPriorityOrder":
            return .stringArray
        default:
            return key.hasPrefix("dashboard.") ? .dashboard : nil
        }
    }

    static func captureSettings(_ defaults: UserDefaults) -> [String: Any] {
        var result: [String: Any] = [:]
        for key in settingKeys.sorted() {
            guard let raw = defaults.object(forKey: key),
                  let kind = settingKind(for: key) else { continue }
            switch kind {
            case .bool:
                if let bool = strictBool(raw) { result[key] = bool }
            case .integer:
                if let int = strictInteger(raw) { result[key] = int }
            case .string:
                if let string = raw as? String { result[key] = string }
            case .stringArray:
                if let array = raw as? [String] { result[key] = array }
            case .dashboard:
                break
            }
        }
        // `dashboard.*` is an open namespace: keep every JSON-compatible
        // value, not only the four current booleans.
        for key in defaults.dictionaryRepresentation().keys.sorted() where key.hasPrefix("dashboard.") {
            guard let raw = defaults.object(forKey: key),
                  let value = jsonCompatible(raw) else { continue }
            result[key] = value
        }
        return result
    }

    @discardableResult
    static func restoreSettings(_ settings: [String: Any], into defaults: UserDefaults) -> Int {
        var applied = 0
        for key in settings.keys.sorted() {
            guard let kind = settingKind(for: key), let value = settings[key] else { continue }
            let didApply: Bool
            switch kind {
            case .bool:
                if let bool = strictBool(value) {
                    defaults.set(bool, forKey: key)
                    didApply = true
                } else {
                    didApply = false
                }
            case .integer:
                if let int = strictInteger(value), isValidInteger(int, for: key) {
                    defaults.set(int, forKey: key)
                    didApply = true
                } else {
                    didApply = false
                }
            case .string:
                if let string = value as? String {
                    // Never let an imported backup redirect Codex token writes.
                    // Only the conventional ~/.codex directory is restored;
                    // custom paths stay machine-local and are not portable.
                    let expanded = (string as NSString).expandingTildeInPath
                    let canonical = URL(fileURLWithPath: expanded)
                        .standardizedFileURL
                        .resolvingSymlinksInPath()
                        .path
                    let home = FileManager.default.homeDirectoryForCurrentUser
                    let expected = home.appendingPathComponent(".codex")
                        .standardizedFileURL
                        .resolvingSymlinksInPath()
                        .path
                    let safeCodexHome = canonical == expected
                    if key != "codexHome" || safeCodexHome {
                        defaults.set(string, forKey: key)
                        didApply = true
                    } else {
                        didApply = false
                    }
                } else {
                    didApply = false
                }
            case .stringArray:
                if let array = value as? [String] {
                    defaults.set(array, forKey: key)
                    didApply = true
                } else {
                    didApply = false
                }
            case .dashboard:
                if applyDashboardValue(value, forKey: key, to: defaults) {
                    didApply = true
                } else {
                    didApply = false
                }
            }
            if didApply { applied += 1 }
        }
        return applied
    }

    private static func isValidInteger(_ value: Int, for key: String) -> Bool {
        switch key {
        case "gatewayPort": return (1...65535).contains(value)
        case "quotaRefreshInterval": return value >= 0
        default: return true
        }
    }

    private static func applyDashboardValue(
        _ value: Any,
        forKey key: String,
        to defaults: UserDefaults
    ) -> Bool {
        if let bool = strictBool(value) {
            defaults.set(bool, forKey: key)
            return true
        }
        if let int = strictInteger(value) {
            defaults.set(int, forKey: key)
            return true
        }
        if let string = value as? String {
            defaults.set(string, forKey: key)
            return true
        }
        if let array = value as? [String] {
            defaults.set(array, forKey: key)
            return true
        }
        return false
    }

    /// UserDefaults bridges booleans to NSNumber; `as? Bool` would also accept
    /// `1`. The CF type check keeps a corrupted payload from turning an
    /// integer into a toggle.
    private static func strictBool(_ value: Any) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func strictInteger(_ value: Any) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double,
              double >= Double(Int.min), double <= Double(Int.max) else { return nil }
        return number.intValue
    }

    private static func jsonCompatible(_ value: Any) -> Any? {
        if let bool = strictBool(value) { return bool }
        if let int = strictInteger(value) { return int }
        if let string = value as? String { return string }
        if let array = value as? [String] { return array }
        return nil
    }

    // MARK: - Helpers

    static func isSafeAuthFileName(_ name: String) -> Bool {
        guard !name.isEmpty, name.hasSuffix(".json") else { return false }
        guard !name.lowercased().hasSuffix(".lock") else { return false }
        guard !name.hasPrefix(".") else { return false }
        guard !name.contains("/"), !name.contains("\\"), !name.contains("..") else { return false }
        guard !name.contains("\0") else { return false }
        guard name.rangeOfCharacter(from: .controlCharacters) == nil else { return false }
        guard name == (name as NSString).lastPathComponent else { return false }
        return true
    }

    private static func readJSONObject(at url: URL) -> [String: Any]? {
        guard let data = SecureFile.read(url), !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
    }

    private static func parseObject(_ data: Data, context: String) throws -> [String: Any] {
        do {
            guard let object = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
                throw BackupError.malformedPayload("\(context) is not a JSON object")
            }
            return object
        } catch let error as BackupError {
            throw error
        } catch {
            throw BackupError.malformedPayload(context)
        }
    }

    private static func optionalObject(_ value: Any?, name: String) throws -> [String: Any]? {
        guard let value, !(value is NSNull) else { return nil }
        guard let object = value as? [String: Any] else {
            throw BackupError.malformedPayload("\(name) is not a JSON object")
        }
        return object
    }

    private static func encodeObject(_ object: [String: Any], context: String) throws -> Data {
        do {
            return try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys]
            )
        } catch {
            throw BackupError.malformedPayload(context)
        }
    }

    private static func arrayCount(_ value: Any?) -> Int {
        (value as? [Any])?.count ?? 0
    }

    // MARK: - Post-restore reload

    /// Production hook: reload every store from disk and restart a running
    /// gateway so the restored vault and auth files take effect. Tests never
    /// call this, so no live process is touched during `xcodebuild test`.
    @MainActor
    static func reloadAfterRestore() async {
        CodexStore.shared.load()
        SchedulerStore.shared.load()
        ModelSourcesStore.shared.load()

        let gateway = CodexGatewayService.shared
        if gateway.isRunning {
            await gateway.restart(
                accounts: CodexStore.shared.accounts,
                priorities: CodexStore.shared.effectivePriorities()
            )
        }
    }
}
