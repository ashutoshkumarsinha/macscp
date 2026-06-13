// TransferQueueTests.swift
//
// WHAT THIS FILE TESTS
// --------------------
// TransferQueue enqueue, execution, pause, cancel, overwrite prompting, and completion callbacks.
//
import MacSCPCore
import MacSCPUI
import XCTest

@MainActor
final class MockBackendProvider: TransferBackendProvider {
    let backend: TransferBackend
    var completedJobIDs: [UUID] = []

    init(backend: TransferBackend) {
        self.backend = backend
    }

    var currentBackend: TransferBackend? { backend }

    func transferDidComplete(jobID: UUID) {
        completedJobIDs.append(jobID)
    }
}

final class SlowMockTransferBackend: TransferBackend, @unchecked Sendable {
    let backendIdentifier = "mock-slow"
    private(set) var isConnected = true
    nonisolated(unsafe) private var uploadStarted = false

    var uploadStartedSignal: Bool { uploadStarted }

    func connect(configuration: SessionConfiguration) async throws {}
    func disconnect() async throws { isConnected = false }
    func changeDirectory(to path: String) async throws {}
    func workingDirectory() async throws -> String { "/" }
    func listDirectory(at path: String) async throws -> [RemoteEntry] { [] }
    func stat(path: String) async throws -> RemoteEntry {
        throw BackendError.notImplemented("stat")
    }

    func createDirectory(at path: String, recursive: Bool) async throws {}
    func removeDirectory(at path: String, recursive: Bool) async throws {}
    func removeFile(at path: String) async throws {}
    func rename(from: String, to: String) async throws {}
    func setPermissions(_ permissions: FilePermissions, at path: String) async throws {}

    func upload(
        localURL: URL,
        remotePath: String,
        options: TransferOptions
    ) async throws -> TransferResult {
        uploadStarted = true

        for step in 1 ... 40 {
            try options.throwIfCancelled()
            options.progress?(
                TransferProgress(
                    transferID: UUID(),
                    direction: .upload,
                    path: remotePath,
                    totalBytes: 4000,
                    transferredBytes: Int64(step * 100),
                    bytesPerSecond: 1000
                )
            )
            try await Task.sleep(for: .milliseconds(25))
        }

        return TransferResult(bytesTransferred: 4000)
    }

    func download(
        remotePath: String,
        localURL: URL,
        options: TransferOptions
    ) async throws -> TransferResult {
        try options.throwIfCancelled()
        if options.overwrite == .skip, FileManager.default.fileExists(atPath: localURL.path) {
            return TransferResult(bytesTransferred: 0)
        }
        return TransferResult(bytesTransferred: 128)
    }
}

final class CancellationMockTransferBackend: TransferBackend, @unchecked Sendable {
    let backendIdentifier = "mock-cancel"
    private(set) var isConnected = true
    nonisolated(unsafe) private var uploadEnteredWait = false

    var uploadEnteredWaitSignal: Bool { uploadEnteredWait }

    func connect(configuration: SessionConfiguration) async throws {}
    func disconnect() async throws { isConnected = false }
    func changeDirectory(to path: String) async throws {}
    func workingDirectory() async throws -> String { "/" }
    func listDirectory(at path: String) async throws -> [RemoteEntry] { [] }
    func stat(path: String) async throws -> RemoteEntry {
        throw BackendError.notImplemented("stat")
    }

    func createDirectory(at path: String, recursive: Bool) async throws {}
    func removeDirectory(at path: String, recursive: Bool) async throws {}
    func removeFile(at path: String) async throws {}
    func rename(from: String, to: String) async throws {}
    func setPermissions(_ permissions: FilePermissions, at path: String) async throws {}

    func upload(
        localURL: URL,
        remotePath: String,
        options: TransferOptions
    ) async throws -> TransferResult {
        uploadEnteredWait = true
        while true {
            try options.throwIfCancelled()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func download(
        remotePath: String,
        localURL: URL,
        options: TransferOptions
    ) async throws -> TransferResult {
        try await Task.sleep(for: .milliseconds(50))
        try options.throwIfCancelled()
        return TransferResult(bytesTransferred: 1)
    }
}

@MainActor
final class TransferQueueTests: XCTestCase {
    func testCancelRunningJobStopsBackendTransfer() async throws {
        let backend = SlowMockTransferBackend()
        let provider = MockBackendProvider(backend: backend)
        let queue = TransferQueue()
        queue.bind(backendProvider: provider)
        queue.maxConcurrentTransfers = 1

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("macscp-cancel-test.dat")
        try Data(repeating: 0xAB, count: 16).write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }

        queue.enqueueUpload(localURL: temp, remotePath: "/remote/cancel-test.dat", totalBytes: 4000)

        try await waitUntil(timeout: 2) {
            backend.uploadStartedSignal
        }

        guard let jobID = queue.jobs.first?.id else {
            XCTFail("Expected queued job")
            return
        }
        queue.cancel(jobID: jobID)

        try await waitUntil(timeout: 2) {
            queue.jobs.first?.state == .cancelled
        }

        XCTAssertEqual(queue.jobs.first?.state, .cancelled)
        XCTAssertTrue(queue.jobs.first?.transferredBytes ?? 0 < 4000)
    }

    func testSkipOverwritePolicyMarksJobSkipped() async throws {
        let backend = SlowMockTransferBackend()
        let provider = MockBackendProvider(backend: backend)
        let queue = TransferQueue()
        queue.bind(backendProvider: provider)

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("macscp-skip-test.dat")
        try Data([1]).write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }

        FileManager.default.createFile(atPath: temp.path, contents: Data([2]))

        queue.enqueueDownload(
            remotePath: "/remote/existing.dat",
            localURL: temp,
            totalBytes: 128,
            overwritePolicy: .skip
        )

        try await waitUntil(timeout: 2) {
            queue.jobs.first?.state == .skipped
        }

        XCTAssertEqual(queue.jobs.first?.state, .skipped)
        XCTAssertEqual(queue.jobs.first?.transferredBytes, 0)
    }

    func testCancellationTokenStopsMockBackendUpload() async throws {
        let backend = CancellationMockTransferBackend()
        let cancellation = TransferCancellation()
        let options = TransferOptions(cancellation: cancellation)

        let uploadTask = Task {
            try await backend.upload(
                localURL: URL(fileURLWithPath: "/tmp/x"),
                remotePath: "/remote/x",
                options: options
            )
        }

        try await waitUntil(timeout: 2) {
            backend.uploadEnteredWaitSignal
        }
        cancellation.cancel()

        do {
            _ = try await uploadTask.value
            XCTFail("Expected cancellation")
        } catch BackendError.cancelled {
            // expected
        }
    }

    private func waitUntil(timeout: TimeInterval, condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for condition")
    }

    func testHandleDisconnectFailsQueuedJobs() async {
        let provider = DisconnectedBackendProvider()
        let queue = TransferQueue()
        queue.applyTransferSettings(MacSCPTransferSettings())
        queue.bind(backendProvider: provider)

        queue.enqueueUpload(
            localURL: URL(fileURLWithPath: "/tmp/a.txt"),
            remotePath: "/remote/a.txt",
            totalBytes: 10
        )

        queue.handleDisconnect()
        XCTAssertEqual(queue.jobs.first?.state, .failed("Disconnected"))
    }
}

@MainActor
private final class DisconnectedBackendProvider: TransferBackendProvider {
    var currentBackend: TransferBackend? { nil }
    func transferDidComplete(jobID: UUID) {}
}
