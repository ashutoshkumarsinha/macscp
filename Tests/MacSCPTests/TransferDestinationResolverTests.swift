@testable import MacSCPBackends
import MacSCPCore
import XCTest

final class TransferDestinationResolverTests: XCTestCase {
    func testResolveRemoteUploadPathReturnsPathWhenMissing() async {
        let resolved = await TransferDestinationResolver.resolveRemoteUploadPath(
            path: "/remote/new.txt",
            policy: .overwrite,
            remoteExists: { _ in false }
        )
        XCTAssertEqual(resolved, "/remote/new.txt")
    }

    func testResolveRemoteUploadPathSkipReturnsNilWhenExists() async {
        let resolved = await TransferDestinationResolver.resolveRemoteUploadPath(
            path: "/remote/existing.txt",
            policy: .skip,
            remoteExists: { _ in true }
        )
        XCTAssertNil(resolved)
    }

    func testResolveRemoteUploadPathRenameFindsAvailableName() async {
        let existing: Set<String> = ["/remote/file.txt", "/remote/file (1).txt"]

        let resolved = await TransferDestinationResolver.resolveRemoteUploadPath(
            path: "/remote/file.txt",
            policy: .rename,
            remoteExists: { existing.contains($0) }
        )

        XCTAssertEqual(resolved, "/remote/file (2).txt")
    }

    func testResolveLocalDownloadURLSkipReturnsNilWhenExists() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("macscp-overwrite-skip.dat")
        FileManager.default.createFile(atPath: temp.path, contents: Data([1]))
        defer { try? FileManager.default.removeItem(at: temp) }

        let resolved = try TransferDestinationResolver.resolveLocalDownloadURL(temp, policy: .skip)
        XCTAssertNil(resolved)
    }

    func testResolveLocalDownloadURLRenameFindsAvailableName() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("macscp-overwrite-rename")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let preferred = directory.appendingPathComponent("report.txt")
        FileManager.default.createFile(atPath: preferred.path, contents: Data([1]))
        let firstRename = TransferPathPlanner.renamedLocalURL(preferred, attempt: 1)
        FileManager.default.createFile(atPath: firstRename.path, contents: Data([2]))

        let resolved = try TransferDestinationResolver.resolveLocalDownloadURL(preferred, policy: .rename)
        XCTAssertEqual(resolved?.lastPathComponent, "report (2).txt")
    }
}
