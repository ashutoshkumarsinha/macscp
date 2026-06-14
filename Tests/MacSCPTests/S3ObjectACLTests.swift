// S3ObjectACLTests.swift
//
// WHAT THIS FILE TESTS
// --------------------
// Mapping from Unix permission bits to S3 canned ACL values.
//

import MacSCPCore
import MacSCPBackends
import XCTest

final class S3ObjectACLTests: XCTestCase {
    func testPrivateACLForOwnerOnlyMode() {
        XCTAssertEqual(S3ObjectACL.canned(for: FilePermissions(octal: 0o600)), "private")
    }

    func testPublicReadWhenWorldReadable() {
        XCTAssertEqual(S3ObjectACL.canned(for: FilePermissions(octal: 0o644)), "public-read")
    }

    func testPublicReadWriteWhenWorldWritable() {
        XCTAssertEqual(S3ObjectACL.canned(for: FilePermissions(octal: 0o666)), "public-read-write")
    }

    func testAuthenticatedReadWhenGroupReadable() {
        XCTAssertEqual(S3ObjectACL.canned(for: FilePermissions(octal: 0o640)), "authenticated-read")
    }
}
