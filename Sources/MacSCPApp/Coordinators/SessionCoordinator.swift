// SessionCoordinator.swift
//
// WHAT THIS FILE DOES
// -------------------
// Owns the live TransferBackend during connect/disconnect: picks Citadel vs Traversio,
// opens one or pooled SFTP connections, and stores remotePath for the UI. Builds
// SessionConfiguration from the login form, calls SFTPBackendSelector.select, then
// SessionConnectionService.connect after effectivePoolSize chooses pooling.
//

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
        session.mergeOpenSSHConfig()
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
            let rawBackend: TransferBackend
            switch session.protocol {
            case .sftp:
                let backendKind = SFTPBackendSelector.select(
                    authMethod: draft.authMethod,
                    settings: transferSettings,
                    advanced: session.advanced
                )
                SFTPBackendSelector.logSelection(backendKind, settings: transferSettings, advanced: session.advanced)
                TransferNetworkTuning.logIntendedSettings(preset: transferSettings.preset)
                rawBackend = try await TransferSessionConnector.connect(
                    configuration: session,
                    transferSettings: transferSettings
                )
            case .scp, .ftp, .ftps, .webdav, .s3, .gcs:
                rawBackend = try await TransferSessionConnector.connect(
                    configuration: session,
                    transferSettings: transferSettings,
                    usePool: false
                )
            }

            try await rawBackend.changeDirectory(
                to: session.initialRemotePath.isEmpty ? "/" : session.initialRemotePath
            )
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
