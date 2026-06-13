// SessionCoordinator.swift — SSH/SFTP connect and disconnect lifecycle.
//
// WHAT THIS FILE DOES
// -------------------
// Owns the live TransferBackend while you are connected: picks Citadel vs Traversio,
// opens one or more SFTP connections (pool), and stores remotePath for the UI.
//
// FLOW (connect)
// --------------
// 1. Build SessionConfiguration from login form + transfer preset → networkProfile
// 2. SFTPBackendSelector.select → .citadel or .traversio
// 3. effectivePoolSize → 1 connection or PooledTransferBackend (Apple Silicon)
// 4. SessionConnectionService.connect → backend.connect(configuration:)
//
// See docs/code-walkthrough.md §4 and §10 for diagrams.

import Foundation
import MacSCPCore
import MacSCPBackends
import MacSCPUI
import Observation

@MainActor
@Observable
final class SessionCoordinator {
    var isConnected = false
    var isConnecting = false
    var showLogin = true
    var activeSessionName = ""
    var remotePath = "/"

    private(set) var backend: TransferBackend?
    private let connectionService = SessionConnectionService()
    private var transferSettings = MacSCPTransferSettings()

    var onStatusMessage: ((String) -> Void)?
    var onConnected: (() async -> Void)?
    var onDisconnected: (() -> Void)?

    func applyTransferSettings(_ settings: MacSCPTransferSettings) {
        transferSettings = settings
    }

    /// Merges login form with transfer preset so backends know TCP profile (lan/wan/…).
    private func configuredSession(from draft: SessionProfileDraft) -> SessionConfiguration {
        var session = draft.toSessionConfiguration()
        session.networkProfile = TransferPerformanceTuning.networkProfile(from: transferSettings.preset)
        return session
    }

    func connect(using draft: SessionProfileDraft) async {
        guard draft.validatePort() else {
            onStatusMessage?("Invalid port (use 1–65535)")
            return
        }

        if isConnected {
            await disconnect()
        }

        await HostKeyTrustGate.shared.setMode(.interactive)
        defer {
            Task { await HostKeyTrustGate.shared.setMode(.silentTOFU) }
        }

        isConnecting = true
        onStatusMessage?("Connecting…")
        defer { isConnecting = false }

        let session = configuredSession(from: draft)
        MacSCPLogger.shared.info(
            "Connecting to \(session.username)@\(session.host):\(session.port) via \(session.protocol.rawValue)",
            category: .session
        )

        do {
            let backendKind = SFTPBackendSelector.select(
                authMethod: draft.authMethod,
                settings: transferSettings
            )
            SFTPBackendSelector.logSelection(backendKind, settings: transferSettings)
            TransferNetworkTuning.logIntendedSettings(preset: transferSettings.preset)

            let poolSize = TransferPerformanceTuning.effectivePoolSize(from: transferSettings)
            let rawBackend: TransferBackend
            if poolSize > 1 {
                // Multiple SSH sessions so parallel queue jobs don't share one SFTP handle.
                let pool = PooledTransferBackend(poolSize: poolSize, backendKind: backendKind)
                try await connectionService.connect(backend: pool, configuration: session)
                rawBackend = pool
            } else {
                let single = try TransferBackendFactory.make(for: .sftp, backend: backendKind, serialized: true)
                try await connectionService.connect(backend: single, configuration: session)
                rawBackend = single
            }

            backend = rawBackend
            remotePath = session.initialRemotePath.isEmpty ? "/" : session.initialRemotePath
            activeSessionName = draft.name.isEmpty ? session.host : draft.name
            isConnected = true
            showLogin = false
            onStatusMessage?("Connected to \(session.host)")
            MacSCPLogger.shared.info("Connected to \(session.host) (\(rawBackend.backendIdentifier))", category: .session)
            await onConnected?()
        } catch {
            onStatusMessage?("Connection failed: \(error.localizedDescription)")
            MacSCPLogger.shared.error(error, context: "Connection failed", category: .session)
        }
    }

    func disconnect() async {
        MacSCPLogger.shared.info("Disconnecting from \(activeSessionName)", category: .session)
        onDisconnected?()
        if let backend {
            try? await connectionService.disconnect(backend: backend)
        }
        backend = nil
        isConnected = false
        showLogin = true
        onStatusMessage?("Disconnected")
    }
}
