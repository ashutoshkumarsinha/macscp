import MacSCPCore
import XCTest

final class MacSCPCoreTests: XCTestCase {
    func testSessionConfigurationDefaults() {
        let session = SessionConfiguration(host: "example.com", username: "user")
        XCTAssertEqual(session.port, 22)
        XCTAssertEqual(session.protocol, .sftp)
    }

    func testChecksumDeterministic() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("macscp-checksum-test")
        try Data([1, 2, 3, 4]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let hash = try Checksum.sha256(of: url)
        XCTAssertEqual(hash.count, 64)
    }
}
