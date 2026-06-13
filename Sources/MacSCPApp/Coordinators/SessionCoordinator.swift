// SessionCoordinator.swift — SSH/SFTP connect and disconnect lifecycle.
//
// Picks Citadel for key/password auth and Traversio for SSH agent auth.
// Wraps the raw backend in SerializingTransferBackend so the transfer queue
// can run concurrent jobs without racing on one SFTP connection.

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

    var onStatusMessage: ((String) -> Void)?
    var onConnected: (() async -> Void)?
    var onDisconnected: (() -> Void)?

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
            // Traversio has native ssh-agent support; Citadel is default for key files.
            let backendKind: SFTPBackendKind = draft.authMethod == .agent ? .traversio : .citadel
            let rawBackend = try TransferBackendFactory.make(for: .sftp, backend: backendKind, serialized: true)
            try await connectionService.connect(backend: rawBackend, configuration: session)
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
