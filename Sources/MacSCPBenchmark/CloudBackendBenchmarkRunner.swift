// CloudBackendBenchmarkRunner.swift
//
// WHAT THIS FILE DOES
// -------------------
// Upload benchmarks for WebDAV and S3 backends against local docker/native fixtures.
//

import Foundation
import MacSCPCore
import MacSCPBackends

struct CloudBackendBenchmarkRunner {
    let config: BenchmarkConfig
    let uploadSize: Int

    func run() async throws -> [BenchmarkResult] {
        BenchmarkEnvironment.prepare()
        var results: [BenchmarkResult] = []

        let localFile = config.workDirectory.appendingPathComponent("cloud-upload.bin")
        try FixtureGenerator.largeFile(at: localFile, size: uploadSize)
        let remoteName = "bench-upload-\(UUID().uuidString).bin"

        if let webdav = config.webDAVSessionConfiguration() {
            let start = Date()
            let backend = WebDAVTransferBackend()
            try await backend.connect(configuration: webdav)
            let result = try await backend.upload(
                localURL: localFile,
                remotePath: remoteName,
                options: TransferOptions()
            )
            try await backend.removeFile(at: remoteName)
            try await backend.disconnect()
            let seconds = Date().timeIntervalSince(start)
            let mbps = Double(result.bytesTransferred) / seconds / 1_000_000.0
            results.append(
                BenchmarkResult(
                    scenario: "webdav_upload",
                    backend: "webdav-native",
                    durationSeconds: seconds,
                    throughputMBps: mbps,
                    filesPerSecond: nil,
                    itemCount: 1,
                    bytes: result.bytesTransferred,
                    sha256Match: nil,
                    passed: seconds > 0,
                    notes: String(format: "WebDAV PUT %d bytes", uploadSize),
                    timingBreakdown: nil
                )
            )
        } else {
            results.append(skipped(scenario: "webdav_upload", backend: "webdav-native"))
        }

        if let s3 = config.s3SessionConfiguration() {
            let start = Date()
            let backend = ObjectStorageTransferBackend(provider: .aws)
            try await backend.connect(configuration: s3)
            let result = try await backend.upload(
                localURL: localFile,
                remotePath: remoteName,
                options: TransferOptions()
            )
            try await backend.removeFile(at: remoteName)
            try await backend.disconnect()
            let seconds = Date().timeIntervalSince(start)
            let mbps = Double(result.bytesTransferred) / seconds / 1_000_000.0
            results.append(
                BenchmarkResult(
                    scenario: "s3_upload",
                    backend: "s3-native",
                    durationSeconds: seconds,
                    throughputMBps: mbps,
                    filesPerSecond: nil,
                    itemCount: 1,
                    bytes: result.bytesTransferred,
                    sha256Match: nil,
                    passed: seconds > 0,
                    notes: String(format: "S3 PUT %d bytes", uploadSize),
                    timingBreakdown: nil
                )
            )
        } else {
            results.append(skipped(scenario: "s3_upload", backend: "s3-native"))
        }

        try? FileManager.default.removeItem(at: localFile)
        return results
    }

    private func skipped(scenario: String, backend: String) -> BenchmarkResult {
        BenchmarkResult(
            scenario: scenario,
            backend: backend,
            durationSeconds: 0,
            throughputMBps: nil,
            filesPerSecond: nil,
            itemCount: nil,
            bytes: 0,
            sha256Match: nil,
            passed: true,
            notes: "skipped — start fixtures with scripts/benchmark-cloud-env.sh",
            timingBreakdown: nil
        )
    }
}
