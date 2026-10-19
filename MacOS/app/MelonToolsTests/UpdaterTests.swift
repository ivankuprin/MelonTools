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

    func testSha256SidecarParsing() {
        let hash = String(repeating: "a", count: 64)
        XCTAssertEqual(UpdaterStore.parseSha256File("\(hash)  MelonTools-1.4.8.dmg\n"), hash)
        XCTAssertEqual(UpdaterStore.parseSha256File("\(hash)\n"), hash)
        XCTAssertNil(UpdaterStore.parseSha256File("not-a-hash file.dmg"))
        XCTAssertNil(UpdaterStore.parseSha256File(""))
        XCTAssertNil(UpdaterStore.parseSha256File(String(repeating: "f", count: 63)))
    }
}
