// ProfileUploadRunner.swift
//
// WHAT THIS FILE DOES
// -------------------
// Benchmarks upload throughput across network presets and emits ProfileUploadReport JSON.
// The benchmark CLI profile-upload subcommand runs this against a configured host.
//
import Foundation
import MacSCPCore
import MacSCPBackends

struct ProfileUploadReport: Codable, Sendable {
    var timestamp: String
    var fileSize: Int
    var results: [ProfileUploadResult]
}

struct ProfileUploadResult: Codable, Sendable {
    var maxConcurrentWrites: Int
    var chunkSize: Int
    var transferSeconds: Double
    var throughputMBps: Double
}

struct ProfileUploadRunner {
    let config: BenchmarkConfig
    let fileSize: Int
    let writeSettings: [Int]

    init(config: BenchmarkConfig, fileSize: Int = 10_485_760, writeSettings: [Int] = [1, 4, 8, 16, 32]) {
        self.config = config
        self.fileSize = fileSize
        self.writeSettings = writeSettings
    }

    func run() async throws -> ProfileUploadReport {
        BenchmarkEnvironment.prepare()

        let local = config.workDirectory.appendingPathComponent("profile_upload.bin")
        let remote = "\(config.dataDirectory.path)/bench/profile_upload.bin"
        try FixtureGenerator.largeFile(at: local, size: fileSize)

        var results: [ProfileUploadResult] = []

        for writes in writeSettings {
            let backend = CitadelSFTPBackend()
            try await backend.connect(configuration: config.sessionConfiguration())

            let options = TransferOptions(
                overwrite: .overwrite,
                chunkSize: 1024 * 1024,
                maxConcurrentWrites: writes
            )

            let start = Date()
            _ = try await backend.upload(localURL: local, remotePath: remote, options: options)
            let elapsed = Date().timeIntervalSince(start)
            try await backend.disconnect()

            let mbps = Double(fileSize) / elapsed / 1_048_576.0
            results.append(
                ProfileUploadResult(
                    maxConcurrentWrites: writes,
                    chunkSize: options.chunkSize,
                    transferSeconds: elapsed,
                    throughputMBps: mbps
                )
            )

            print(String(
                format: "  maxConcurrentWrites=%2d  %.3fs  %.1f MB/s",
                writes, elapsed, mbps
            ))
        }

        return ProfileUploadReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            fileSize: fileSize,
            results: results
        )
    }
}
