// CLIProfileResolver.swift
//
// WHAT THIS FILE DOES
// -------------------
// Resolves saved GUI profiles by name or UUID for macscp --session / open -session.
// Reads Application Support profiles.json and Keychain secrets (same as MacSCP app).
//
import Foundation
import MacSCPCore
import Security

enum CLIProfileResolver {
    private struct StoredProfile: Decodable {
        let id: UUID
        let name: String
        let host: String
        let port: Int
        let username: String
        let authMethod: AuthMethod
        let keyPath: String?
        let initialRemotePath: String
        let hostKeyFingerprint: String?
        let cloudRegion: String?
        let cloudBucket: String?
        let proxyType: ProxyType?
        let proxyHost: String?
        let proxyPort: Int?
        let transferProtocol: TransferProtocol?

        private enum CodingKeys: String, CodingKey {
            case id, name, host, port, username, authMethod, keyPath, initialRemotePath, hostKeyFingerprint
            case transferProtocol = "protocol"
            case cloudRegion, cloudBucket, proxyType, proxyHost, proxyPort
        }
    }

    static func resolve(nameOrID: String, homeDirectory: URL) throws -> SessionConfiguration {
        let profilesURL = homeDirectory
            .appendingPathComponent("Library/Application Support/MacSCP/profiles.json")
        guard FileManager.default.fileExists(atPath: profilesURL.path) else {
            throw CLIError.usage("No saved profiles found")
        }
        let data = try Data(contentsOf: profilesURL)
        let profiles = try JSONDecoder().decode([StoredProfile].self, from: data)
        let match = profiles.first { profile in
            profile.name.caseInsensitiveCompare(nameOrID) == .orderedSame
                || profile.id.uuidString.caseInsensitiveCompare(nameOrID) == .orderedSame
        }
        guard let profile = match else {
            throw CLIError.usage("Unknown session profile: \(nameOrID)")
        }
        return sessionConfiguration(from: profile)
    }

    private static func sessionConfiguration(from profile: StoredProfile) -> SessionConfiguration {
        var advanced = AdvancedSettings()
        if let hostKeyFingerprint = profile.hostKeyFingerprint, !hostKeyFingerprint.isEmpty {
            advanced.hostKeyFingerprint = hostKeyFingerprint
        }
        if profile.transferProtocol == .ftps, profile.port == 990 {
            advanced.ftpsImplicit = true
        }
        if let cloudRegion = profile.cloudRegion, !cloudRegion.isEmpty {
            advanced.cloudRegion = cloudRegion
        }
        if let cloudBucket = profile.cloudBucket, !cloudBucket.isEmpty {
            advanced.cloudBucket = cloudBucket
        }
        if let proxyType = profile.proxyType, proxyType != .none {
            advanced.proxyType = proxyType
            advanced.proxyHost = profile.proxyHost
            advanced.proxyPort = profile.proxyPort
        }
        let password = loadKeychainSecret(profileID: profile.id, service: "com.macscp.session-password")
            ?? ProcessInfo.processInfo.environment["MACSCP_PASSPHRASE"]
        let keyPassphrase = loadKeychainSecret(profileID: profile.id, service: "com.macscp.session-key-passphrase")
            ?? ProcessInfo.processInfo.environment["MACSCP_PASSPHRASE"]
        return SessionConfiguration(
            id: profile.id,
            name: profile.name,
            protocol: profile.transferProtocol ?? .sftp,
            host: profile.host,
            port: profile.port,
            username: profile.username,
            password: password,
            authMethod: profile.authMethod,
            keyPath: profile.keyPath.map { NSString(string: $0).expandingTildeInPath },
            keyPassphrase: keyPassphrase,
            initialRemotePath: profile.initialRemotePath,
            advanced: advanced
        )
    }

    private static func loadKeychainSecret(profileID: UUID, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
