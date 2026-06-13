// MacSCPHostKeySupport.swift — Trust-on-first-use host key store for SSH connections.

import Citadel
import Crypto
import Foundation
import MacSCPCore
import NIOCore
import NIOSSH

/// TOFU host-key store at `~/.macscp/known_hosts.json` (SHA-256 fingerprints).
public enum MacSCPHostKeyTrustStore {
    public struct Record: Codable, Equatable, Sendable {
        public var fingerprintSHA256: String
    }

    public static func storeURL(homeDirectory: URL? = nil) -> URL {
        let home = homeDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".macscp/known_hosts.json")
    }

    public static func endpointKey(host: String, port: Int) -> String {
        port == 22 ? host : "\(host):\(port)"
    }

    public static func load(homeDirectory: URL? = nil) -> [String: Record] {
        let url = storeURL(homeDirectory: homeDirectory)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: Record].self, from: data) else {
            return [:]
        }
        return decoded
    }

    public static func save(_ records: [String: Record], homeDirectory: URL? = nil) throws {
        let url = storeURL(homeDirectory: homeDirectory)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(records)
        try data.write(to: url, options: .atomic)
    }

    public static func fingerprintSHA256(for hostKey: NIOSSHPublicKey) -> String {
        let openSSH = String(openSSHPublicKey: hostKey)
        let parts = openSSH.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, let raw = Data(base64Encoded: String(parts[1])) else {
            return ""
        }
        let digest = SHA256.hash(data: raw)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func normalizeFingerprint(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "sha256:", with: "")
            .replacingOccurrences(of: ":", with: "")
    }

    public static func makeCitadelValidator(
        host: String,
        port: Int,
        expectedFingerprint: String?
    ) -> SSHHostKeyValidator {
        let endpoint = endpointKey(host: host, port: port)
        let expected = expectedFingerprint.map(normalizeFingerprint)

        return .custom(CitadelHostKeyValidator(endpoint: endpoint, expectedFingerprint: expected))
    }

    static func validateTOFU(
        endpoint: String,
        receivedFingerprint: String,
        expectedFingerprint: String?
    ) throws {
        let received = normalizeFingerprint(receivedFingerprint)

        if let expectedFingerprint {
            if received != expectedFingerprint {
                throw BackendError.hostKeyRejected(expected: expectedFingerprint, actual: received)
            }
            return
        }

        var records = load()
        if let stored = records[endpoint] {
            if normalizeFingerprint(stored.fingerprintSHA256) != received {
                throw BackendError.hostKeyRejected(
                    expected: stored.fingerprintSHA256,
                    actual: received
                )
            }
            return
        }

        records[endpoint] = Record(fingerprintSHA256: received)
        try save(records)
    }
}

private final class CitadelHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let endpoint: String
    private let expectedFingerprint: String?

    init(endpoint: String, expectedFingerprint: String?) {
        self.endpoint = endpoint
        self.expectedFingerprint = expectedFingerprint
    }

    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        let received = MacSCPHostKeyTrustStore.fingerprintSHA256(for: hostKey)
        do {
            try MacSCPHostKeyTrustStore.validateTOFU(
                endpoint: endpoint,
                receivedFingerprint: received,
                expectedFingerprint: expectedFingerprint
            )
            validationCompletePromise.succeed(())
        } catch {
            validationCompletePromise.fail(error)
        }
    }
}
