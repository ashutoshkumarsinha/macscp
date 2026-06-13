// Phase3FeatureTests.swift
//
// WHAT THIS FILE TESTS
// --------------------
// TransferHistoryStore persistence and related phase-3 feature settings integration.
//
import Foundation
@testable import MacSCPCore
import XCTest

final class Phase3FeatureTests: XCTestCase {
    func testTransferHistoryStoreAppendAndLoad() throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscp-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let entry = TransferHistoryEntry(
            direction: .upload,
            localPath: "/tmp/local.txt",
            remotePath: "/remote/local.txt",
            bytesTransferred: 42,
            sessionName: "staging",
            success: true
        )
        try TransferHistoryStore.append(entry, homeDirectory: tempHome)
        let loaded = try TransferHistoryStore.load(homeDirectory: tempHome)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].sessionName, "staging")
        XCTAssertEqual(loaded[0].bytesTransferred, 42)
    }

    func testObjectStorageLayoutResolveFromPath() throws {
        let configuration = SessionConfiguration(
            protocol: .s3,
            host: "",
            port: 443,
            username: "AKIAKEY",
            password: "secret",
            authMethod: .password,
            initialRemotePath: "/my-bucket/logs",
            advanced: AdvancedSettings(cloudRegion: "us-west-2")
        )
        let layout = try ObjectStorageLayout.resolve(from: configuration, provider: .aws)
        XCTAssertEqual(layout.bucket, "my-bucket")
        XCTAssertEqual(layout.prefix, "logs")
        XCTAssertEqual(layout.region, "us-west-2")
        XCTAssertEqual(layout.endpointHost, "s3.us-west-2.amazonaws.com")
    }

    func testObjectStorageLayoutObjectKey() {
        let layout = ObjectStorageLayout(
            provider: .gcs,
            bucket: "archive",
            prefix: "data",
            region: "auto",
            endpointHost: "storage.googleapis.com"
        )
        XCTAssertEqual(layout.objectKey(for: "report.csv"), "data/report.csv")
        XCTAssertEqual(layout.remotePath(for: "data/report.csv"), "report.csv")
    }

    func testBidirectionalPlanIncludesUploadsAndDownloads() {
        let rows = [
            SyncCompareRow(relativePath: "a.txt", status: .newerLocal, localURL: URL(fileURLWithPath: "/tmp/a"), remotePath: "/a.txt", localSize: 1),
            SyncCompareRow(relativePath: "b.txt", status: .newerRemote, localURL: URL(fileURLWithPath: "/tmp/b"), remotePath: "/b.txt", remoteSize: 2),
        ]
        let plan = DirectorySyncEngine.bidirectionalPlan(rows: rows, deleteExtraneous: false)
        XCTAssertEqual(plan.uploads.count, 1)
        XCTAssertEqual(plan.downloads.count, 1)
    }
}
