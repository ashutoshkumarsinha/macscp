// TransferCancellationTests.swift
//
// WHAT THIS FILE TESTS
// --------------------
// TransferCancellation flag lifecycle and throwIfCancelled integration with TransferOptions.
//
import MacSCPCore
import XCTest

final class TransferCancellationTests: XCTestCase {
    func testStartsNotCancelled() {
        let cancellation = TransferCancellation()
        XCTAssertFalse(cancellation.isCancelled)
    }

    func testCancelSetsFlag() {
        let cancellation = TransferCancellation()
        cancellation.cancel()
        XCTAssertTrue(cancellation.isCancelled)
    }

    func testThrowIfCancelledThrowsBackendError() {
        let cancellation = TransferCancellation()
        cancellation.cancel()
        var options = TransferOptions(cancellation: cancellation)
        XCTAssertThrowsError(try options.throwIfCancelled()) { error in
            XCTAssertEqual(error as? BackendError, .cancelled)
        }
    }

    func testContinuationFactoryReturnsNilWithoutCancellation() {
        XCTAssertNil(TransferContinuationFactory.shouldContinue(for: nil))
    }

    func testContinuationFactoryReturnsFalseAfterCancel() async {
        let cancellation = TransferCancellation()
        let shouldContinue = TransferContinuationFactory.shouldContinue(for: cancellation)
        XCTAssertNotNil(shouldContinue)
        cancellation.cancel()
        let result = await shouldContinue?()
        XCTAssertEqual(result, false)
    }
}
