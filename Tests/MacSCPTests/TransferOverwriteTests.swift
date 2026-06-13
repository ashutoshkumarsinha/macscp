import MacSCPCore
import MacSCPUI
import XCTest

final class TransferOverwriteTests: XCTestCase {
    func testRenamedLocalURLAddsSuffixBeforeExtension() {
        let original = URL(fileURLWithPath: "/tmp/report.pdf")
        let renamed = TransferPathPlanner.renamedLocalURL(original, attempt: 2)
        XCTAssertEqual(renamed.lastPathComponent, "report (2).pdf")
    }

    func testRenamedRemotePathAddsSuffixBeforeExtension() {
        let renamed = TransferPathPlanner.renamedRemotePath("/var/www/index.html", attempt: 1)
        XCTAssertEqual(renamed, "/var/www/index (1).html")
    }

    func testNextAvailableLocalURLFindsFirstFreeName() {
        let preferred = URL(fileURLWithPath: "/tmp/data.txt")
        let existing: Set<String> = [
            preferred.path,
            TransferPathPlanner.renamedLocalURL(preferred, attempt: 1).path,
        ]

        let resolved = TransferPathPlanner.nextAvailableLocalURL(preferred: preferred) {
            existing.contains($0.path)
        }

        XCTAssertEqual(resolved.lastPathComponent, "data (2).txt")
    }

    func testNextAvailableRemotePathFindsFirstFreeName() {
        let preferred = "/remote/data.txt"
        let existing: Set<String> = [
            preferred,
            TransferPathPlanner.renamedRemotePath(preferred, attempt: 1),
        ]

        let resolved = TransferPathPlanner.nextAvailableRemotePath(preferred: preferred) {
            existing.contains($0)
        }

        XCTAssertEqual(resolved, "/remote/data (2).txt")
    }

    func testPendingBatchRequiresPromptWhenConflictExists() {
        let batch = PendingTransferBatch(
            kind: .upload,
            items: [
                PendingTransferItem(
                    localURL: URL(fileURLWithPath: "/tmp/new.txt"),
                    remotePath: "/remote/new.txt",
                    hasConflict: false
                ),
                PendingTransferItem(
                    localURL: URL(fileURLWithPath: "/tmp/existing.txt"),
                    remotePath: "/remote/existing.txt",
                    hasConflict: true
                ),
            ]
        )

        XCTAssertTrue(batch.requiresPrompt)
        XCTAssertEqual(batch.conflictNames, ["existing.txt"])
    }

    func testPendingBatchDoesNotRequirePromptWithoutConflicts() {
        let batch = PendingTransferBatch(
            kind: .download,
            items: [
                PendingTransferItem(
                    localURL: URL(fileURLWithPath: "/tmp/a.txt"),
                    remotePath: "/remote/a.txt",
                    hasConflict: false
                ),
            ]
        )

        XCTAssertFalse(batch.requiresPrompt)
        XCTAssertTrue(batch.conflictNames.isEmpty)
    }
}
