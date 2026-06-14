// CitadelBenchmarkConnector.swift
//
// WHAT THIS FILE DOES
// -------------------
// Citadel SSH helpers for performance benchmarks (multiplex spike, connect timing).
//

@preconcurrency import Citadel
import Crypto
import Foundation
import MacSCPCore

public enum CitadelBenchmarkConnector {
    public static func connectSSH(configuration: SessionConfiguration) async throws -> SSHClient {
        let authMethod = try await makeAuthenticationMethod(from: configuration)
        let hostKeyValidator = MacSCPHostKeyTrustStore.makeCitadelValidator(
            host: configuration.host,
            port: configuration.port,
            expectedFingerprint: configuration.advanced.hostKeyFingerprint
        )
        let endpoint = try SSHConnectRouting.prepare(from: configuration)
        return try await CitadelTCPConnector.connect(
            configuration: configuration,
            authenticationMethod: authMethod,
            hostKeyValidator: hostKeyValidator,
            endpoint: endpoint
        )
    }

    public static func listDirectory(client: SSHClient, path: String) async throws {
        let sftp = try await client.openSFTP()
        defer { Task { try? await sftp.close() } }
        _ = try await sftp.listDirectory(atPath: path)
    }

    public static func disconnect(_ client: SSHClient) async throws {
        try await client.close()
    }

    private static func makeAuthenticationMethod(from configuration: SessionConfiguration) async throws -> SSHAuthenticationMethod {
        switch configuration.authMethod {
        case .password, .interactive:
            guard let password = configuration.password else {
                throw BackendError.authenticationFailed("Password required")
            }
            return .passwordBased(username: configuration.username, password: password)
        case .publicKey:
            guard let keyPath = configuration.keyPath else {
                throw BackendError.authenticationFailed("Key path required")
            }
            let expanded = NSString(string: keyPath).expandingTildeInPath
            let keyString = try String(contentsOfFile: expanded, encoding: .utf8)
            let passData = configuration.keyPassphrase?.data(using: .utf8)
            let keyType = try SSHKeyDetection.detectPrivateKeyType(from: keyString)
            switch keyType {
            case .ed25519:
                let key = try Curve25519.Signing.PrivateKey(sshEd25519: keyString, decryptionKey: passData)
                return .ed25519(username: configuration.username, privateKey: key)
            case .rsa:
                let key = try Insecure.RSA.PrivateKey(sshRsa: keyString, decryptionKey: passData)
                return .rsa(username: configuration.username, privateKey: key)
            default:
                throw BackendError.authenticationFailed("Unsupported key type: \(keyType)")
            }
        case .agent:
            throw BackendError.authenticationFailed("SSH agent auth requires the Traversio SFTP backend")
        }
    }
}
