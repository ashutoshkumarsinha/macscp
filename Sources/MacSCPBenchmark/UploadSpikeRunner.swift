import Foundation
import MacSCPCore
import MacSCPBackends

struct UploadSpikeRunner {
    let config: BenchmarkConfig

    func run() async throws -> UploadSpikeReport {
        var results: [UploadSpikeResult] = []
        results.append(try await runLargeUpload(backend: .citadel, label: "citadel"))
        results.append(try await runLargeUpload(backend: .traversio, label: "traversio"))
        results.append(try await runLargeUploadOpenSSH())
        results.append(try await runSmallUpload(backend: .citadel, label: "citadel"))
        results.append(try await runSmallUpload(backend: .traversio, label: "traversio"))
        results.append(try await runSmallUploadOpenSSH())
        return UploadSpikeReport(timestamp: ISO8601DateFormatter().string(from: Date()), results: results)
    }

    private func runLargeUpload(backend: SFTPBackendKind, label: String) async throws -> UploadSpikeResult {
        let size = config.largeFileSizes.first ?? 1_048_576
        let local = config.workDirectory.appendingPathComponent("spike_large_\(label).bin")
        let remote = "\(config.dataDirectory.path)/bench/spike/large_\(label).bin"
        try FixtureGenerator.largeFile(at: local, size: size)

        let transferBackend = try TransferBackendFactory.make(for: .sftp, backend: backend)
        try await transferBackend.connect(configuration: config.sessionConfiguration())

        let start = Date()
        _ = try await transferBackend.upload(
            localURL: local,
            remotePath: remote,
            options: TransferOptions(checksum: nil, chunkSize: 1024 * 1024, maxConcurrentUploads: 16)
        )
        let elapsed = Date().timeIntervalSince(start)
        try await transferBackend.disconnect()
        let mbps = Double(size) / elapsed / 1_048_576.0

        return UploadSpikeResult(
            scenario: "large_upload_1mb",
            backend: label,
            durationSeconds: elapsed,
            throughputMBps: mbps,
            itemCount: 1,
            bytes: Int64(size),
            notes: nil
        )
    }

    private func runLargeUploadOpenSSH() async throws -> UploadSpikeResult {
        let size = config.largeFileSizes.first ?? 1_048_576
        let local = config.workDirectory.appendingPathComponent("spike_large_openssh.bin")
        let remote = "\(config.dataDirectory.path)/bench/spike/large_openssh.bin"
        try FixtureGenerator.largeFile(at: local, size: size)

        let elapsed = try OpenSSHSFTPBaseline.upload(local: local, remotePath: remote, config: config)
        return UploadSpikeResult(
            scenario: "large_upload_1mb",
            backend: "openssh",
            durationSeconds: elapsed,
            throughputMBps: Double(size) / elapsed / 1_048_576.0,
            itemCount: 1,
            bytes: Int64(size),
            notes: nil
        )
    }

    private func runSmallUpload(backend: SFTPBackendKind, label: String) async throws -> UploadSpikeResult {
        let count = min(config.smallFileCount, 500)
        let localDir = config.workDirectory.appendingPathComponent("spike_small_\(label)", isDirectory: true)
        let remoteDir = "\(config.dataDirectory.path)/bench/spike/small_\(label)"
        try FixtureGenerator.smallFileTree(at: localDir, count: count)

        let transferBackend = try TransferBackendFactory.make(for: .sftp, backend: backend)
        try await transferBackend.connect(configuration: config.sessionConfiguration())

        let files = try FileManager.default.contentsOfDirectory(at: localDir, includingPropertiesForKeys: nil)
        let items = files.map {
            BatchUploadItem(localURL: $0, remotePath: "\(remoteDir)/\($0.lastPathComponent)")
        }

        let start = Date()
        _ = try await transferBackend.uploadBatch(
            items: items,
            options: TransferOptions(
                checksum: nil,
                chunkSize: 256 * 1024,
                maxConcurrentUploads: 12,
                smallFileThreshold: 512 * 1024
            )
        )
        let elapsed = Date().timeIntervalSince(start)
        try await transferBackend.disconnect()

        return UploadSpikeResult(
            scenario: "small_upload_\(count)_files",
            backend: label,
            durationSeconds: elapsed,
            throughputMBps: nil,
            itemCount: count,
            bytes: Int64(count * 4096),
            notes: String(format: "%.0f files/s", Double(count) / elapsed)
        )
    }

    private func runSmallUploadOpenSSH() async throws -> UploadSpikeResult {
        let count = min(config.smallFileCount, 500)
        let localDir = config.workDirectory.appendingPathComponent("spike_small_openssh", isDirectory: true)
        let remoteDir = "\(config.dataDirectory.path)/bench/spike/small_openssh"
        try FixtureGenerator.smallFileTree(at: localDir, count: count)

        let files = try FileManager.default.contentsOfDirectory(at: localDir, includingPropertiesForKeys: nil)
        let batch = files.map { (local: $0, remote: "\(remoteDir)/\($0.lastPathComponent)") }

        let start = Date()
        _ = try OpenSSHSFTPBaseline.uploadBatch(files: batch, config: config)
        let elapsed = Date().timeIntervalSince(start)

        return UploadSpikeResult(
            scenario: "small_upload_\(count)_files",
            backend: "openssh",
            durationSeconds: elapsed,
            throughputMBps: nil,
            itemCount: count,
            bytes: Int64(count * 4096),
            notes: String(format: "%.0f files/s", Double(count) / elapsed)
        )
    }
}

struct UploadSpikeResult: Codable, Sendable {
    var scenario: String
    var backend: String
    var durationSeconds: Double
    var throughputMBps: Double?
    var itemCount: Int?
    var bytes: Int64
    var notes: String?
}

struct UploadSpikeReport: Codable, Sendable {
    var timestamp: String
    var results: [UploadSpikeResult]
}
