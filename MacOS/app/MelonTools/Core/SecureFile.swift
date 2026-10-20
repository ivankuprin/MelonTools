import Foundation

/// Writes small files with mode 0600 from the moment of creation, so secrets
/// never sit on disk with the umask-default 0644 permissions even briefly.
///
/// The write is atomic: bytes go to a sibling temp file (0600 from creation,
/// fsynced), then the temp file is renamed over the target. A reader never
/// sees a half-written secret, and an interrupted write leaves the previous
/// file intact instead of truncating it.
enum SecureFile {
    static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Hidden sibling in the same directory: rename(2) stays on one volume.
        let tempURL = directory
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = Darwin.open(tempURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var closed = false
        var renamed = false
        defer {
            if !closed { close(fd) }
            // A failed write must not leave the temp file (with its secret) behind.
            if !renamed { unlink(tempURL.path) }
        }
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
        guard fsync(fd) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        close(fd)
        closed = true
        guard rename(tempURL.path, url.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        renamed = true
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
