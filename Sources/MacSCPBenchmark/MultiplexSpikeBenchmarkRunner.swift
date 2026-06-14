// MultiplexSpikeBenchmarkRunner.swift
//
// WHAT THIS FILE DOES
// -------------------
// Compares two independent SSH handshakes vs two SFTP channels on one SSH connection.
//

import Foundation
import MacSCPCore
import MacSCPBackends

struct MultiplexSpikeBenchmarkRunner {
    let config: BenchmarkConfig

    func run() async throws -> [BenchmarkResult] {
        BenchmarkEnvironment.prepare()
        let listPath = config.dataDirectory.path
        let session = config.sessionConfiguration()

        // Two full SSH + SFTP handshakes (sequential).
        let separateStart = Date()
        let client1 = try await CitadelBenchmarkConnector.connectSSH(configuration: session)
        try await CitadelBenchmarkConnector.listDirectory(client: client1, path: listPath)
        let client2 = try await CitadelBenchmarkConnector.connectSSH(configuration: session)
        try await CitadelBenchmarkConnector.listDirectory(client: client2, path: listPath)
        let separateSeconds = Date().timeIntervalSince(separateStart)
        try await CitadelBenchmarkConnector.disconnect(client1)
        try await CitadelBenchmarkConnector.disconnect(client2)

        // One SSH handshake, two SFTP channels.
        var multiplexSeconds = separateSeconds
        var multiplexSupported = true
        var multiplexNotes = ""
        let multiplexStart = Date()
        let shared = try await CitadelBenchmarkConnector.connectSSH(configuration: session)
        do {
            try await CitadelBenchmarkConnector.listDirectory(client: shared, path: listPath)
            try await CitadelBenchmarkConnector.listDirectory(client: shared, path: listPath)
            multiplexSeconds = Date().timeIntervalSince(multiplexStart)
            let improvement = (1.0 - (multiplexSeconds / separateSeconds)) * 100.0
            multiplexNotes = String(
                format: "multiplex=%.3fs separate=%.3fs improvement=%.1f%% (target ≥30%% for production)",
                multiplexSeconds,
                separateSeconds,
                improvement
            )
        } catch {
            multiplexSupported = false
            multiplexNotes = "second SFTP channel failed: \(error.localizedDescription)"
        }
        try await CitadelBenchmarkConnector.disconnect(shared)

        let improvementRatio = BenchmarkPassCriteria.multiplexImprovementRatio(
            separateSeconds: separateSeconds,
            multiplexSeconds: multiplexSeconds
        )
        let meetsTarget = BenchmarkPassCriteria.multiplexMeetsTarget(
            separateSeconds: separateSeconds,
            multiplexSeconds: multiplexSeconds,
            supported: multiplexSupported
        )

        return [
            BenchmarkResult(
                scenario: "multiplex_dual_separate_ssh",
                backend: "citadel",
                durationSeconds: separateSeconds,
                throughputMBps: nil,
                filesPerSecond: nil,
                itemCount: 2,
                bytes: 0,
                sha256Match: nil,
                passed: true,
                notes: String(format: "two SSH handshakes + list=%.3fs", separateSeconds),
                timingBreakdown: nil
            ),
            BenchmarkResult(
                scenario: "multiplex_dual_channel_single_ssh",
                backend: "citadel",
                durationSeconds: multiplexSeconds,
                throughputMBps: nil,
                filesPerSecond: nil,
                itemCount: 2,
                bytes: 0,
                sha256Match: nil,
                passed: multiplexSupported,
                notes: multiplexNotes,
                timingBreakdown: nil
            ),
            BenchmarkResult(
                scenario: "multiplex_improvement_threshold",
                backend: "citadel",
                durationSeconds: improvementRatio,
                throughputMBps: nil,
                filesPerSecond: nil,
                itemCount: nil,
                bytes: 0,
                sha256Match: nil,
                passed: meetsTarget,
                notes: meetsTarget
                    ? "≥30% connect win — revisit hybrid pool for multiplex"
                    : "Below 30% threshold — stay on lazy PooledTransferBackend (option 3)",
                timingBreakdown: nil
            ),
        ]
    }
}
