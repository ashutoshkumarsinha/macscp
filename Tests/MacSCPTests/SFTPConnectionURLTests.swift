// SFTPConnectionURLTests.swift
//
// WHAT THIS FILE TESTS
// --------------------
// SFTPConnectionURL.parse for credentials, custom ports, key paths, and path normalization.
//
import MacSCPCore
import XCTest

final class SFTPConnectionURLTests: XCTestCase {
    func testParseMinimalURL() throws {
        let parsed = try SFTPConnectionURL.parse("sftp://alice@example.com/var/www")
        XCTAssertEqual(parsed.host, "example.com")
        XCTAssertEqual(parsed.port, 22)
        XCTAssertEqual(parsed.username, "alice")
        XCTAssertNil(parsed.password)
        XCTAssertEqual(parsed.path, "/var/www")
        XCTAssertEqual(parsed.authMethod, .publicKey)
    }

    func testParsePasswordAndCustomPort() throws {
        let parsed = try SFTPConnectionURL.parse("sftp://bob:secret@files.example.net:2222/")
        XCTAssertEqual(parsed.host, "files.example.net")
        XCTAssertEqual(parsed.port, 2222)
        XCTAssertEqual(parsed.username, "bob")
        XCTAssertEqual(parsed.password, "secret")
        XCTAssertEqual(parsed.path, "/")
        XCTAssertEqual(parsed.authMethod, .password)
    }

    func testParseRejectsNonSftpScheme() {
        XCTAssertThrowsError(try SFTPConnectionURL.parse("https://example.com/")) { error in
            XCTAssertEqual(error as? SFTPConnectionURLError, .invalidFormat)
        }
    }
}

final class DirectorySyncEngineTransferTests: XCTestCase {
    func testToTransferFilesUploadDirection() {
        let local = URL(fileURLWithPath: "/tmp/local/a.txt")
        let rows = [
            SyncCompareRow(
                relativePath: "a.txt",
                status: .newLocal,
                localURL: local,
                remotePath: "/remote/a.txt",
                localSize: 10
            ),
            SyncCompareRow(
                relativePath: "b.txt",
                status: .same,
                localURL: URL(fileURLWithPath: "/tmp/local/b.txt"),
                remotePath: "/remote/b.txt"
            ),
        ]
        let files = DirectorySyncEngine.toTransferFiles(rows: rows, direction: .mirrorLocalToRemote)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].remotePath, "/remote/a.txt")
        XCTAssertEqual(files[0].localURL, local)
    }

    func testToTransferFilesDownloadDirection() {
        let local = URL(fileURLWithPath: "/tmp/local/new.txt")
        let rows = [
            SyncCompareRow(
                relativePath: "new.txt",
                status: .newRemote,
                localURL: local,
                remotePath: "/remote/new.txt",
                remoteSize: 42
            ),
        ]
        let files = DirectorySyncEngine.toTransferFiles(rows: rows, direction: .mirrorRemoteToLocal)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].totalBytes, 42)
    }
}
