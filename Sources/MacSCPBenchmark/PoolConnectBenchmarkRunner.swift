// PoolConnectBenchmarkRunner.swift
//
// WHAT THIS FILE DOES
// -------------------
// Measures time-to-first-listing for single vs pooled SFTP connect (lazy warm-up).
//

import Foundation
import MacSCPCore
import MacSCPBackends

struct PoolConnectBenchmarkRunner {
    let config: BenchmarkConfig

    func run() async throws -> [BenchmarkResult] {
        BenchmarkEnvironment.prepare()
        var results: [BenchmarkResult] = []

        let listPath = config.dataDirectory.path

        let singleStart = Date()
        let single = CitadelSFTPBackend()
        try await single.connect(configuration: config.sessionConfiguration())
        _ = try await single.listDirectory(at: listPath)
        let singleSeconds = Date().timeIntervalSince(singleStart)
        try await single.disconnect()

        let poolStart = Date()
        let pool = PooledTransferBackend(poolSize: 4, backendKind: .citadel)
        try await pool.connect(configuration: config.sessionConfiguration())
        _ = try await pool.listDirectory(at: listPath)
        let poolFirstListSeconds = Date().timeIntervalSince(poolStart)
        try await pool.disconnect()

        results.append(
            BenchmarkResult(
                scenario: "connect_single_first_list",
                backend: "citadel",
                durationSeconds: singleSeconds,
                throughputMBps: nil,
                filesPerSecond: nil,
                itemCount: nil,
                bytes: 0,
                sha256Match: nil,
                passed: true,
                notes: String(format: "single connect+list=%.3fs", singleSeconds),
                timingBreakdown: nil
            )
        )
        results.append(
            BenchmarkResult(
                scenario: "connect_pool_first_list",
                backend: "pooled-citadel",
                durationSeconds: poolFirstListSeconds,
                throughputMBps: nil,
                filesPerSecond: nil,
                itemCount: nil,
                bytes: 0,
                sha256Match: nil,
                passed: poolFirstListSeconds <= singleSeconds * 1.5,
                notes: String(
                    format: "pool(4) connect+first list=%.3fs (target ≤1.5× single=%.3fs)",
                    poolFirstListSeconds,
                    singleSeconds
                ),
                timingBreakdown: nil
            )
        )
        return results
    }
}
