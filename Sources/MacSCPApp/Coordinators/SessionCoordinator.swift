// SessionCoordinator.swift — SSH/SFTP connect and disconnect lifecycle.
//
// Picks Citadel for key/password auth and Traversio for SSH agent auth.
// Uses a connection pool when maxConcurrentTransfers > 1 for parallel jobs.

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

        let session = draft.toSessionConfiguration()
        MacSCPLogger.shared.info(
            "Connecting to \(session.username)@\(session.host):\(session.port) via \(session.protocol.rawValue)",
            category: .session
        )

        do {
            let backendKind = selectBackendKind(for: draft.authMethod)
            let rawBackend: TransferBackend
            if transferSettings.maxConcurrentTransfers > 1 {
                let pool = PooledTransferBackend(
                    poolSize: transferSettings.maxConcurrentTransfers,
                    backendKind: backendKind
                )
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

    private func selectBackendKind(for authMethod: AuthMethod) -> SFTPBackendKind {
        if authMethod == .agent {
            return .traversio
        }
        if transferSettings.useTraversioForPerformance {
            return .traversio
        }
        return .citadel
    }
}
