// MacSCPHostKeySupport.swift
//
// WHAT THIS FILE DOES
// -------------------
// Trust-on-first-use host key store for SSH connections at ~/.macscp/known_hosts.json.
// CitadelSFTPBackend and Traversio backends consult MacSCPHostKeyTrustStore and HostKeyTrustGate.
//

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
        MacSCPPaths.knownHostsURL(homeDirectory: homeDirectory)
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

    public static func validateTOFU(
        endpoint: String,
        receivedFingerprint: String,
        expectedFingerprint: String?
    ) throws {
        try validateTOFUWithGate(
            endpoint: endpoint,
            receivedFingerprint: receivedFingerprint,
            expectedFingerprint: expectedFingerprint,
            gate: HostKeyTrustGate.shared
        )
    }

    public static func validateTOFUWithGate(
        endpoint: String,
        receivedFingerprint: String,
        expectedFingerprint: String?,
        gate: HostKeyTrustGate
    ) throws {
        let approved = HostKeyTrustGate.runBlocking {
            await evaluateTrust(
                endpoint: endpoint,
                receivedFingerprint: receivedFingerprint,
                expectedFingerprint: expectedFingerprint,
                gate: gate
            )
        }
        if !approved {
            throw BackendError.hostKeyRejected(
                expected: expectedFingerprint ?? load()[endpoint]?.fingerprintSHA256,
                actual: normalizeFingerprint(receivedFingerprint)
            )
        }
    }

    static func evaluateTrust(
        endpoint: String,
        receivedFingerprint: String,
        expectedFingerprint: String?,
        gate: HostKeyTrustGate
    ) async -> Bool {
        let received = normalizeFingerprint(receivedFingerprint)
        let pinned = expectedFingerprint.map(normalizeFingerprint)

        if let pinned, !pinned.isEmpty {
            return received == pinned
        }

        var records = load()
        if let stored = records[endpoint] {
            let storedNorm = normalizeFingerprint(stored.fingerprintSHA256)
            if storedNorm == received {
                return true
            }
            let request = HostKeyTrustRequest(
                endpoint: endpoint,
                fingerprintSHA256: received,
                isKeyChange: true,
                storedFingerprint: stored.fingerprintSHA256
            )
            let approved = await gate.approveTrust(for: request)
            if approved {
                records[endpoint] = Record(fingerprintSHA256: received)
                try? save(records)
            }
            return approved
        }

        let request = HostKeyTrustRequest(
            endpoint: endpoint,
            fingerprintSHA256: received,
            isKeyChange: false
        )
        let approved = await gate.approveTrust(for: request)
        if approved {
            records[endpoint] = Record(fingerprintSHA256: received)
            try? save(records)
        }
        return approved
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
