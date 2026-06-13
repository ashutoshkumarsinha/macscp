// SFTPAttributeMappingTests.swift
//
// WHAT THIS FILE TESTS
// --------------------
// SFTPAttributeMapping.entryType classification from Unix permission bitmasks.
//
import Foundation
@testable import MacSCPCore
import XCTest

final class SFTPAttributeMappingTests: XCTestCase {
    func testDirectoryPermissions() {
        XCTAssertEqual(SFTPAttributeMapping.entryType(fromPermissions: 0o040755), .directory)
    }

    func testSymlinkPermissions() {
        XCTAssertEqual(SFTPAttributeMapping.entryType(fromPermissions: 0o120777), .symlink)
    }

    func testFilePermissions() {
        XCTAssertEqual(SFTPAttributeMapping.entryType(fromPermissions: 0o100644), .file)
    }
}
