// LiveSFTPIntegrationTests.swift
//
// WHAT THIS FILE TESTS
// --------------------
// Live SFTP smoke tests against the local benchmark fixture (127.0.0.1:2222).
// Skipped unless MACSCP_INTEGRATION=1 and scripts/benchmark-env.sh has started sshd.
//
import MacSCPCore
import MacSCPBackends
import XCTest

final class LiveSFTPIntegrationTests: XCTestCase {
    private var enabled: Bool {
        ProcessInfo.processInfo.environment["MACSCP_INTEGRATION"] == "1"
    }

    func testConnectAndListDirectory() async throws {
        try XCTSkipUnless(enabled, "Set MACSCP_INTEGRATION=1 and start benchmark-env")
        let keyPath = URL(fileURLWithPath: ".benchmark/keys/client_key").path
        guard FileManager.default.fileExists(atPath: keyPath) else {
            throw XCTSkip("Missing .benchmark/keys/client_key")
        }

        var session = SessionConfiguration(
            host: "127.0.0.1",
            port: 2222,
            username: NSUserName(),
            authMethod: .publicKey,
            keyPath: keyPath,
            initialRemotePath: "/"
        )
        session.mergeOpenSSHConfig()

        let backend = try TransferBackendFactory.make(for: .sftp, backend: .citadel, serialized: true)
        try await backend.connect(configuration: session)
        let entries = try await backend.listDirectory(at: "/")
        try await backend.disconnect()
        XCTAssertFalse(entries.isEmpty)
    }
}
