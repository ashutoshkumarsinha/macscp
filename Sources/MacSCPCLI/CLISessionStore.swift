// CLISessionStore.swift
//
// WHAT THIS FILE DOES
// -------------------
// Actor holding the CLI's singleton TransferBackend connection and remote cwd.
// CLIActions connect, list, transfer, and disconnect through this shared store.
//
import Foundation
import MacSCPCore
import MacSCPBackends

actor CLISessionStore {
    static let shared = CLISessionStore()

    private var backend: TransferBackend?
    private var configuration: SessionConfiguration?
    private var remotePath: String = "/"
    private var transferSettings = MacSCPTransferSettings()

    func loadSettings() throws {
        transferSettings = try MacSCPConfiguration.loadSettings(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        ).transfer
    }

    func connect(_ configuration: SessionConfiguration) async throws {
        if let backend {
            try await backend.disconnect()
        }
        if TransferProtocolDefaults.supportsSSHAuth(configuration.protocol) {
            await HostKeyTrustGate.shared.setMode(.batchStrict)
        }
        defer {
            if TransferProtocolDefaults.supportsSSHAuth(configuration.protocol) {
                Task { await HostKeyTrustGate.shared.setMode(.silentTOFU) }
            }
        }

        var session = configuration
        session.networkProfile = TransferPerformanceTuning.networkProfile(from: transferSettings.preset)

        let backendKind = SFTPBackendSelector.select(
            authMethod: configuration.authMethod,
            settings: transferSettings,
            advanced: session.advanced
        )
        let instance = try TransferBackendFactory.make(
            for: configuration.protocol,
            backend: backendKind,
            serialized: true
        )
        try await instance.connect(configuration: session)
        try await instance.changeDirectory(to: session.initialRemotePath.isEmpty ? "/" : session.initialRemotePath)
        backend = instance
        self.configuration = session
        remotePath = session.initialRemotePath.isEmpty ? "/" : session.initialRemotePath
    }

    func disconnect() async throws {
        if let backend {
            try await backend.disconnect()
        }
        backend = nil
        configuration = nil
    }

    func backendOrThrow() throws -> TransferBackend {
        guard let backend, backend.isConnected else {
            throw CLIError.notConnected
        }
        return backend
    }

    func currentRemotePath() -> String { remotePath }

    func setRemotePath(_ path: String) { remotePath = path }
}

enum CLIError: Error, CustomStringConvertible {
    case notConnected
    case usage(String)
    case connectionFailed(String)
    case transferFailed(String)
    case authFailed
    case hostKeyRejected

    var description: String {
        switch self {
        case .notConnected: "Not connected"
        case let .usage(message): message
        case let .connectionFailed(message): message
        case let .transferFailed(message): message
        case .authFailed: "Authentication failed"
        case .hostKeyRejected: "Host key rejected"
        }
    }

    var exitCode: Int32 {
        switch self {
        case .usage: 1
        case .connectionFailed: 2
        case .transferFailed: 3
        case .authFailed: 4
        case .hostKeyRejected: 5
        case .notConnected: 2
        }
    }
}

enum CLISessionBuilder {
    static func configuration(
        transferProtocol: TransferProtocol,
        host: String,
        port: Int,
        username: String,
        password: String?,
        keyPath: String?,
        authMethod: AuthMethod,
        remotePath: String,
        hostKeyFingerprint: String?,
        implicitTLS: Bool = false
    ) -> SessionConfiguration {
        SessionConfigurationBuilder.make(
            transferProtocol: transferProtocol,
            host: host,
            port: port,
            username: username,
            password: password,
            keyPath: keyPath,
            authMethod: authMethod,
            remotePath: remotePath,
            hostKeyFingerprint: hostKeyFingerprint,
            implicitTLS: implicitTLS
        )
    }
}
