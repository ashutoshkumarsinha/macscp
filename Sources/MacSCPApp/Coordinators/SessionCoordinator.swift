// SessionCoordinator.swift — SSH/SFTP connect and disconnect lifecycle.
//
// Picks backend via SFTPBackendSelector; uses a connection pool sized for Apple Silicon.

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
