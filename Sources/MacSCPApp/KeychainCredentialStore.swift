// KeychainCredentialStore.swift
//
// WHAT THIS FILE DOES
// -------------------
// Stores profile passwords and key passphrases in macOS Keychain (not profiles.json).
// ProfileCoordinator and SessionProfile persistence read and write secrets via this helper.
//

import Foundation
import Security

enum KeychainCredentialStore {
    private static let passwordService = "com.macscp.session-password"
    private static let keyPassphraseService = "com.macscp.session-key-passphrase"

    static func savePassword(_ password: String, profileID: UUID) throws {
        try saveSecret(password, profileID: profileID, service: passwordService)
    }

    static func loadPassword(profileID: UUID) -> String? {
        loadSecret(profileID: profileID, service: passwordService)
    }

    static func deletePassword(profileID: UUID) {
        deleteSecret(profileID: profileID, service: passwordService)
    }

    static func saveKeyPassphrase(_ passphrase: String, profileID: UUID) throws {
        try saveSecret(passphrase, profileID: profileID, service: keyPassphraseService)
    }

    static func loadKeyPassphrase(profileID: UUID) -> String? {
        loadSecret(profileID: profileID, service: keyPassphraseService)
    }

    static func deleteKeyPassphrase(profileID: UUID) {
        deleteSecret(profileID: profileID, service: keyPassphraseService)
    }

    static func deleteAllCredentials(profileID: UUID) {
        deletePassword(profileID: profileID)
        deleteKeyPassphrase(profileID: profileID)
    }

    private static func saveSecret(_ value: String, profileID: UUID, service: String) throws {
        let account = profileID.uuidString
        let data = Data(value.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ProfileStoreError.keychainWriteFailed(status)
        }
    }

    private static func loadSecret(profileID: UUID, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteSecret(profileID: UUID, service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum ProfileStoreError: LocalizedError {
    case writeFailed(String)
    case keychainWriteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .writeFailed(let message):
            return message
        case .keychainWriteFailed(let status):
            return "Keychain write failed (status \(status))"
        }
    }
}
