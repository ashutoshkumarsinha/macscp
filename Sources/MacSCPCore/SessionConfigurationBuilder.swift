// SessionConfigurationBuilder.swift
//
// WHAT THIS FILE DOES
// -------------------
// Factory for SessionConfiguration from protocol, host, credentials, and remote path.
// App connect UI, CLIActions, and tests use make to assemble a ready-to-connect session.
//
import Foundation

public enum SessionConfigurationBuilder {
    public static func make(
        transferProtocol: TransferProtocol,
        host: String,
        port: Int,
        username: String,
        password: String?,
        keyPath: String?,
        keyPassphrase: String? = nil,
        authMethod: AuthMethod,
        remotePath: String,
        hostKeyFingerprint: String? = nil,
        implicitTLS: Bool = false
    ) -> SessionConfiguration {
        var advanced = AdvancedSettings()
        if let hostKeyFingerprint, !hostKeyFingerprint.isEmpty {
            advanced.hostKeyFingerprint = hostKeyFingerprint
        }
        if transferProtocol == .ftps, implicitTLS || port == 990 {
            advanced.ftpsImplicit = true
        }
        return SessionConfiguration(
            protocol: transferProtocol,
            host: host,
            port: port,
            username: username,
            password: password,
            authMethod: authMethod,
            keyPath: keyPath,
            keyPassphrase: keyPassphrase,
            initialRemotePath: remotePath,
            advanced: advanced
        )
    }
}
