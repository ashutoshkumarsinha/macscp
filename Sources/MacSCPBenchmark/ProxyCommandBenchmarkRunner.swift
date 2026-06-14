// ProxyCommandBenchmarkRunner.swift
//
// WHAT THIS FILE DOES
// -------------------
// Measures connect+list overhead when routing through an OpenSSH ProxyCommand relay.
//

import Foundation
import MacSCPCore
import MacSCPBackends

struct ProxyCommandBenchmarkRunner {
    let config: BenchmarkConfig

    func run() async throws -> [BenchmarkResult] {
        BenchmarkEnvironment.prepare()
        let listPath = config.dataDirectory.path

        let directSession = config.sessionConfiguration()
        let directStart = Date()
        let direct = CitadelSFTPBackend()
        try await direct.connect(configuration: directSession)
        _ = try await direct.listDirectory(at: listPath)
        let directSeconds = Date().timeIntervalSince(directStart)
        try await direct.disconnect()

        let proxySession = config.proxyCommandSessionConfiguration()
        let proxyStart = Date()
        let proxied = CitadelSFTPBackend()
        try await proxied.connect(configuration: proxySession)
        _ = try await proxied.listDirectory(at: listPath)
        let proxySeconds = Date().timeIntervalSince(proxyStart)
        try await proxied.disconnect()

        let overheadRatio = BenchmarkPassCriteria.proxyCommandOverheadRatio(
            directSeconds: directSeconds,
            proxySeconds: proxySeconds
        )
        let passed = BenchmarkPassCriteria.proxyCommandMeetsTarget(
            directSeconds: directSeconds,
            proxySeconds: proxySeconds
        )

        return [
            BenchmarkResult(
                scenario: "proxy_direct_connect_list",
                backend: "citadel",
                durationSeconds: directSeconds,
                throughputMBps: nil,
                filesPerSecond: nil,
                itemCount: nil,
                bytes: 0,
                sha256Match: nil,
                passed: true,
                notes: String(format: "direct connect+list=%.3fs", directSeconds),
                timingBreakdown: nil
            ),
            BenchmarkResult(
                scenario: "proxy_command_connect_list",
                backend: "citadel+proxycommand",
                durationSeconds: proxySeconds,
                throughputMBps: nil,
                filesPerSecond: nil,
                itemCount: nil,
                bytes: 0,
                sha256Match: nil,
                passed: passed,
                notes: String(
                    format: "ProxyCommand connect+list=%.3fs ratio=%.2f× direct (target ≤2.0×)",
                    proxySeconds,
                    overheadRatio
                ),
                timingBreakdown: nil
            ),
        ]
    }
}
