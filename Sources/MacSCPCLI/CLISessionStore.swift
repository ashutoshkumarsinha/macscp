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
    private var settingsLoaded = false

    func loadSettings() throws {
        guard !CLIRuntime.skipIni else {
            settingsLoaded = true
            return
        }
        transferSettings = try MacSCPConfiguration.loadSettings(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        ).transfer
        settingsLoaded = true
    }

    func transferSettingsOrDefault() -> MacSCPTransferSettings {
        transferSettings
    }

    func connect(_ configuration: SessionConfiguration) async throws {
        if let backend {
            try await backend.disconnect()
        }
        if !settingsLoaded {
            try loadSettings()
        }
        if CLIRuntime.batchMode || TransferProtocolDefaults.supportsSSHAuth(configuration.protocol) {
            await HostKeyTrustGate.shared.setMode(.batchStrict)
        }
        defer {
            if TransferProtocolDefaults.supportsSSHAuth(configuration.protocol), !CLIRuntime.batchMode {
                Task { await HostKeyTrustGate.shared.setMode(.silentTOFU) }
            }
        }

        var session = configuration
        CLIRuntime.applyAdvanced(to: &session)
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
        remotePath = "/"
    }

    func backendOrThrow() throws -> TransferBackend {
        guard let backend, backend.isConnected else {
            throw CLIError.notConnected
        }
        return backend
    }

    func currentRemotePath() -> String { remotePath }

    func setRemotePath(_ path: String) { remotePath = path }

    func resolveRemotePath(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        if remotePath == "/" { return "/\(path)" }
        return "\(remotePath)/\(path)"
    }
}

enum CLIError: Error, CustomStringConvertible {
    case notConnected
    case usage(String)
    case connectionFailed(String)
    case transferFailed(String)
    case authFailed
    case hostKeyRejected
    case partialSuccess(String)
    case interrupted

    var description: String {
        switch self {
        case .notConnected: "Not connected"
        case let .usage(message): message
        case let .connectionFailed(message): message
        case let .transferFailed(message): message
        case .authFailed: "Authentication failed"
        case .hostKeyRejected: "Host key rejected"
        case let .partialSuccess(message): message
        case .interrupted: "Interrupted"
        }
    }

    var exitCode: Int32 {
        switch self {
        case .usage: 1
        case .connectionFailed, .notConnected: 2
        case .transferFailed: 3
        case .authFailed: 4
        case .hostKeyRejected: 5
        case .partialSuccess: 10
        case .interrupted: 6
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
        keyPassphrase: String?,
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
            keyPassphrase: keyPassphrase,
            authMethod: authMethod,
            remotePath: remotePath,
            hostKeyFingerprint: hostKeyFingerprint,
            implicitTLS: implicitTLS
        )
    }
}
