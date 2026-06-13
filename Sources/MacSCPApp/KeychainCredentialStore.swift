// KeychainCredentialStore.swift — Profile passwords in macOS Keychain (not profiles.json).

import Foundation
import Security

enum KeychainCredentialStore {
    private static let service = "com.macscp.session-password"

    static func savePassword(_ password: String, profileID: UUID) throws {
        let account = profileID.uuidString
        let data = Data(password.utf8)

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

    static func loadPassword(profileID: UUID) -> String? {
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

    static func deletePassword(profileID: UUID) {
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
