import Foundation

/// Writes small files with mode 0600 from the moment of creation, so secrets
/// never sit on disk with the umask-default 0644 permissions even briefly.
enum SecureFile {
    static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { close(fd) }
        _ = fchmod(fd, 0o600)
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(fd, base.advanced(by: offset), data.count - offset)
            }
            guard written > 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            offset += written
        }
        fsync(fd)
    }

    static func write(_ string: String, to url: URL) throws {
        guard let data = string.data(using: .utf8) else { return }
        try write(data, to: url)
    }

    static func read(_ url: URL) -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }
}
