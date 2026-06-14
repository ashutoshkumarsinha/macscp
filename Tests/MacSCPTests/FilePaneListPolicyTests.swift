// FilePaneListPolicyTests.swift
//
// WHAT THIS FILE TESTS
// --------------------
// Entry-count threshold for virtualized file pane rendering.
//
import MacSCPCore
import XCTest

final class FilePaneListPolicyTests: XCTestCase {
    func testUsesStandardListBelowThreshold() {
        XCTAssertFalse(FilePaneListPolicy.usesVirtualizedList(entryCount: 999))
        XCTAssertFalse(FilePaneListPolicy.usesVirtualizedList(entryCount: 0))
    }

    func testUsesVirtualizedListAtThreshold() {
        XCTAssertTrue(
            FilePaneListPolicy.usesVirtualizedList(
                entryCount: FilePaneListPolicy.virtualizedEntryThreshold
            )
        )
    }

    func testUsesVirtualizedListAboveThreshold() {
        XCTAssertTrue(FilePaneListPolicy.usesVirtualizedList(entryCount: 10_000))
    }
}
