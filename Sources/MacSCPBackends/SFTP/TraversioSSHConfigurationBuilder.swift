// TraversioSSHConfigurationBuilder.swift
//
// WHAT THIS FILE DOES
// -------------------
// Builds Traversio SSHClientConfiguration from SessionConfiguration.
// TraversioSFTPBackend and TraversioSCPBackend call makeConfiguration at connect time.
//
import Foundation
import MacSCPCore
import Traversio

enum TraversioSSHConfigurationBuilder {
    /// Maps MacSCP session settings to Traversio's SSHClientConfiguration, including ProxyJump hops.
    static func makeConfiguration(from configuration: SessionConfiguration) async throws -> SSHClientConfiguration {
        let auth = try await makeAuthentication(from: configuration)
        let hostKeyPolicy = makeHostKeyPolicy(
            host: configuration.host,
            port: configuration.port,
            configuration: configuration
        )
        let connectionProxy = makeConnectionProxy(from: configuration.advanced)
        let proxyJumpHosts = try await makeProxyJumpHosts(
            from: configuration,
            authentication: auth
        )

        return SSHClientConfiguration(
            host: configuration.host,
            port: UInt16(clamping: configuration.port),
            username: configuration.username,
            authentication: auth,
            hostKeyPolicy: hostKeyPolicy,
            connectionProxy: connectionProxy,
            proxyJumpHosts: proxyJumpHosts
        )
    }

    private static func makeAuthentication(from configuration: SessionConfiguration) async throws -> SSHAuthenticationMethod {
        switch configuration.authMethod {
        case .password, .interactive:
            guard let password = configuration.password else {
                throw BackendError.authenticationFailed("Password required")
            }
            return .password(password)
        case .publicKey:
            guard let keyPath = configuration.keyPath else {
                throw BackendError.authenticationFailed("Key path required")
            }
            let expanded = NSString(string: keyPath).expandingTildeInPath
            return try SSHAuthenticationMethod.openSSHPrivateKey(
                contentsOfFile: expanded,
                passphrase: configuration.keyPassphrase
            )
        case .agent:
            return try await SSHAgentAuthSupport.traversioAuthentication()
        }
    }

    private static func makeConnectionProxy(from advanced: AdvancedSettings) -> SSHConnectionProxy? {
        // HTTP/SOCKS apply to the first TCP hop only; ProxyJump uses separate SSHProxyJumpHost entries.
        guard let proxyHost = advanced.proxyHost, !proxyHost.isEmpty else { return nil }
        switch advanced.proxyType {
        case .none, .jump:
            return nil
        case .http:
            let port = UInt16(clamping: advanced.proxyPort ?? 8080)
            return .httpConnect(SSHHTTPConnectConnectionProxy(host: proxyHost, port: port))
        case .socks5:
            let port = UInt16(clamping: advanced.proxyPort ?? 1080)
            return .socks5(SSHSOCKS5ConnectionProxy(host: proxyHost, port: port))
        }
    }

    private static func makeProxyJumpHosts(
        from configuration: SessionConfiguration,
        authentication: SSHAuthenticationMethod
    ) async throws -> [SSHProxyJumpHost] {
        guard configuration.advanced.proxyType == .jump else { return [] }
        guard let proxyHost = configuration.advanced.proxyHost, !proxyHost.isEmpty else { return [] }

        let tokens = proxyHost
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let endpoints = OpenSSHConfigParser.resolveJumpChain(
            tokens: tokens,
            defaultUsername: configuration.username
        )

        guard !endpoints.isEmpty else {
            throw BackendError.invalidConfiguration("Invalid ProxyJump host list")
        }

        return endpoints.map { endpoint in
            let username = endpoint.username ?? configuration.username
            let policy = makeHostKeyPolicy(
                host: endpoint.host,
                port: endpoint.port,
                configuration: configuration
            )
            return SSHProxyJumpHost(
                host: endpoint.host,
                port: UInt16(clamping: endpoint.port),
                username: username,
                authentication: authentication,
                hostKeyPolicy: policy
            )
        }
    }

    private static func makeHostKeyPolicy(
        host: String,
        port: Int,
        configuration: SessionConfiguration
    ) -> SSHHostKeyPolicy {
        let endpoint = MacSCPHostKeyTrustStore.endpointKey(host: host, port: port)
        let expected = configuration.advanced.hostKeyFingerprint.map(MacSCPHostKeyTrustStore.normalizeFingerprint)

        if let expected, !expected.isEmpty {
            return .callback { request in
                let received = MacSCPHostKeyTrustStore.normalizeFingerprint(
                    request.trustedHostKey.fingerprintSHA256
                )
                if received == expected {
                    return .callback
                }
                throw BackendError.hostKeyRejected(expected: expected, actual: received)
            }
        }

        return .callback { request in
            let received = request.trustedHostKey.fingerprintSHA256
            try MacSCPHostKeyTrustStore.validateTOFU(
                endpoint: endpoint,
                receivedFingerprint: received,
                expectedFingerprint: nil
            )
            return .callback
        }
    }
}
