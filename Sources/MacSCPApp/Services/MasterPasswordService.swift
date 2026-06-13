// MasterPasswordService.swift
//
// WHAT THIS FILE DOES
// -------------------
// Stores and verifies an optional app master password in the Keychain.
// Settings and profile export flows call setMasterPassword, verify, and clear.
//
import CryptoKit
import Foundation
import Security

enum MasterPasswordService {
    private static let service = "com.macscp.master-password"

    static func isEnabled() -> Bool {
        loadVerifier() != nil
    }

    static func setMasterPassword(_ password: String) throws {
        let verifier = SHA256.hash(data: Data(password.utf8))
        try saveVerifier(Data(verifier))
    }

    static func verify(_ password: String) -> Bool {
        guard let stored = loadVerifier() else { return true }
        let candidate = SHA256.hash(data: Data(password.utf8))
        return stored == Data(candidate)
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "master",
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func saveVerifier(_ data: Data) throws {
        clear()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "master",
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw ProfileStoreError.keychainWriteFailed(status) }
    }

    private static func loadVerifier() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "master",
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
}
