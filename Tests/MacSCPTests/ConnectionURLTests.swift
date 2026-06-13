// ConnectionURLTests.swift
//
// WHAT THIS FILE TESTS
// --------------------
// ConnectionURL.parse for sftp, scp, ftp, and ftps schemes including ports and paths.
//
import MacSCPCore
@testable import MacSCPBackends
import XCTest

final class ConnectionURLTests: XCTestCase {
    func testParseSFTPURL() throws {
        let url = try ConnectionURL.parse("sftp://deploy@example.com/var/www")
        XCTAssertEqual(url.transferProtocol, .sftp)
        XCTAssertEqual(url.host, "example.com")
        XCTAssertEqual(url.port, 22)
        XCTAssertEqual(url.username, "deploy")
        XCTAssertEqual(url.path, "/var/www")
    }

    func testParseSCPURL() throws {
        let url = try ConnectionURL.parse("scp://user@host.example:2222/tmp")
        XCTAssertEqual(url.transferProtocol, .scp)
        XCTAssertEqual(url.port, 2222)
    }

    func testParseFTPURL() throws {
        let url = try ConnectionURL.parse("ftp://anonymous@files.example/pub")
        XCTAssertEqual(url.transferProtocol, .ftp)
        XCTAssertEqual(url.port, 21)
        XCTAssertEqual(url.authMethod, .password)
    }

    func testParseFTPSURLDefaultsTo990WhenImplicit() throws {
        let url = try ConnectionURL.parse("ftps://user:pass@secure.example/remote")
        XCTAssertEqual(url.transferProtocol, .ftps)
        XCTAssertEqual(url.port, 990)
        XCTAssertTrue(url.implicitTLS)
    }

    func testParseWebDAVURL() throws {
        let url = try ConnectionURL.parse("webdav://user:secret@dav.example.com/projects")
        XCTAssertEqual(url.transferProtocol, .webdav)
        XCTAssertEqual(url.host, "dav.example.com")
        XCTAssertEqual(url.port, 443)
        XCTAssertEqual(url.path, "/projects")
    }

    func testParseS3URL() throws {
        let url = try ConnectionURL.parse("s3://AKIAKEY:secret@/my-bucket/logs/")
        XCTAssertEqual(url.transferProtocol, .s3)
        XCTAssertEqual(url.username, "AKIAKEY")
        XCTAssertEqual(url.password, "secret")
        XCTAssertEqual(url.path, "/my-bucket/logs/")
    }

    func testParseGCSURL() throws {
        let url = try ConnectionURL.parse("gcs://access:secret@/archive/data")
        XCTAssertEqual(url.transferProtocol, .gcs)
        XCTAssertEqual(url.path, "/archive/data")
    }
}

final class SSHRemoteListingParserTests: XCTestCase {
    func testParseLsOutput() {
        let output = """
        total 8
        drwxr-xr-x  2 user group 4096 Jun 13 10:00 .
        drwxr-xr-x  3 user group 4096 Jun 13 09:00 ..
        -rw-r--r--  1 user group  123 Jun 13 10:01 notes.txt
        """
        let entries = SSHRemoteListingParser.parse(output, basePath: "/data")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "notes.txt")
        XCTAssertEqual(entries[0].path, "/data/notes.txt")
        XCTAssertEqual(entries[0].size, 123)
    }
}

final class TransferProtocolDefaultsTests: XCTestCase {
    func testDefaultPorts() {
        XCTAssertEqual(TransferProtocolDefaults.defaultPort(for: .sftp), 22)
        XCTAssertEqual(TransferProtocolDefaults.defaultPort(for: .ftp), 21)
        XCTAssertEqual(TransferProtocolDefaults.defaultPort(for: .ftps), 21)
    }
}
