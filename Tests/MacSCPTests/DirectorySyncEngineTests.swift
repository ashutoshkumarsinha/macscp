// DirectorySyncEngineTests.swift
//
// WHAT THIS FILE TESTS
// --------------------
// DirectorySyncEngine row filtering for upload, download, and bidirectional sync plans.
//
import MacSCPCore
import XCTest

final class DirectorySyncEngineTests: XCTestCase {
    func testRowsNeedingUploadIncludesNewLocalAndNewerLocal() {
        let rows = [
            SyncCompareRow(relativePath: "a.txt", status: .same),
            SyncCompareRow(relativePath: "b.txt", status: .newLocal),
            SyncCompareRow(relativePath: "c.txt", status: .newerLocal),
            SyncCompareRow(relativePath: "d.txt", status: .newRemote),
        ]
        let upload = DirectorySyncEngine.rowsNeedingUpload(rows)
        XCTAssertEqual(upload.map(\.relativePath), ["b.txt", "c.txt"])
    }

    func testRowsNeedingDownloadIncludesNewRemote() {
        let rows = [
            SyncCompareRow(relativePath: "a.txt", status: .newRemote),
            SyncCompareRow(relativePath: "b.txt", status: .same),
        ]
        let download = DirectorySyncEngine.rowsNeedingDownload(rows)
        XCTAssertEqual(download.map(\.relativePath), ["a.txt"])
    }

    func testSyncFileMaskExcludesPatterns() {
        let mask = SyncFileMask.parse("*.txt|*.bak")
        XCTAssertTrue(mask.matches(relativePath: "notes.txt"))
        XCTAssertFalse(mask.matches(relativePath: "notes.bak"))
    }

    func testMirrorPlanDeletesExtraneousRemoteFiles() {
        let rows = [
            SyncCompareRow(relativePath: "keep.txt", status: .same, remotePath: "/remote/keep.txt"),
            SyncCompareRow(relativePath: "extra.txt", status: .newRemote, remotePath: "/remote/extra.txt"),
        ]
        let plan = DirectorySyncEngine.mirrorPlan(
            rows: rows,
            direction: .mirrorLocalToRemote,
            deleteExtraneous: true
        )
        XCTAssertEqual(plan.remoteDeletes, ["/remote/extra.txt"])
    }
}

final class HostKeyTrustGateTests: XCTestCase {
    func testSilentModeAutoApproves() async {
        let gate = HostKeyTrustGate()
        await gate.setMode(.silentTOFU)
        let approved = await gate.approveTrust(for: HostKeyTrustRequest(
            endpoint: "example.com",
            fingerprintSHA256: "abc",
            isKeyChange: false
        ))
        XCTAssertTrue(approved)
    }

    func testBatchStrictRejectsUnknown() async {
        let gate = HostKeyTrustGate()
        await gate.setMode(.batchStrict)
        let approved = await gate.approveTrust(for: HostKeyTrustRequest(
            endpoint: "example.com",
            fingerprintSHA256: "abc",
            isKeyChange: false
        ))
        XCTAssertFalse(approved)
    }
}
