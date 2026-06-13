// SFTPErrorHelpersTests.swift
//
// WHAT THIS FILE TESTS
// --------------------
// SFTPErrorHelpers.isAlreadyExists recognizes Citadel and Traversio mkdir failure messages.
//
@testable import MacSCPBackends
import XCTest

final class SFTPErrorHelpersTests: XCTestCase {
    struct FakeError: Error, CustomStringConvertible {
        let description: String
    }

    func testRecognizesTraversioMkdirAlreadyExistsMessage() {
        let error = FakeError(description: "status 4: Failure")
        XCTAssertTrue(SFTPErrorHelpers.isAlreadyExists(error))
    }

    func testRecognizesCitadelMkdirAlreadyExistsMessage() {
        let error = FakeError(description: "SFTP failure (4) for path /data/bench")
        XCTAssertTrue(SFTPErrorHelpers.isAlreadyExists(error))
    }

    func testDoesNotTreatUnrelatedErrorsAsAlreadyExists() {
        let error = FakeError(description: "connection reset by peer")
        XCTAssertFalse(SFTPErrorHelpers.isAlreadyExists(error))
    }
}
