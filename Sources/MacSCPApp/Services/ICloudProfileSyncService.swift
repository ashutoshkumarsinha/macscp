// ICloudProfileSyncService.swift
//
// WHAT THIS FILE DOES
// -------------------
// Opt-in encrypted profile sync via iCloud Drive. ProfileCoordinator calls syncIfEnabled
// after saves; profiles.enc and a Keychain sync key protect credentials off-device.
//

import CryptoKit
import Foundation
import MacSCPCore
import Security

enum ICloudProfileSyncService {
    private static let encryptedFileName = "profiles.enc"
    private static let keychainService = "com.macscp.icloud-sync-key"

    static func syncIfEnabled(profiles: [SessionProfile]) {
        guard isEnabled() else { return }
        Task {
            try? await push(profiles: profiles)
        }
    }

    static func pullAndMerge(into profiles: inout [SessionProfile]) {
        guard isEnabled() else { return }
        guard let localURL = encryptedFileURL(),
              FileManager.default.fileExists(atPath: localURL.path),
              let data = try? Data(contentsOf: localURL),
              let decrypted = try? decrypt(data),
              let remote = try? JSONDecoder().decode([SessionProfile].self, from: decrypted) else {
            return
        }
        merge(remote: remote, into: &profiles)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "macscp.icloudProfileSync")
        if enabled {
            _ = try? ensureSyncKey()
        }
    }

    static func isEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: "macscp.icloudProfileSync")
    }

    static func push(profiles: [SessionProfile]) async throws {
        let data = try JSONEncoder().encode(profiles)
        let encrypted = try encrypt(data)
        guard let url = encryptedFileURL() else {
            throw ICloudProfileSyncError.containerUnavailable
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encrypted.write(to: url, options: .atomic)
    }

    private static func merge(remote: [SessionProfile], into profiles: inout [SessionProfile]) {
        var byID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        for profile in remote {
            byID[profile.id] = profile
        }
        profiles = byID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func encryptedFileURL() -> URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: MacSCPSharedConstants.iCloudContainerID)?
            .appendingPathComponent("Documents/\(encryptedFileName)")
    }

    private static func ensureSyncKey() throws -> SymmetricKey {
        let account = "icloud-sync"
        if let existing = loadKey(account: account) {
            return existing
        }
        let key = SymmetricKey(size: .bits256)
        try saveKey(key, account: account)
        return key
    }

    private static func encrypt(_ data: Data) throws -> Data {
        let key = try ensureSyncKey()
        let sealed = try AES.GCM.seal(data, using: key)
        return sealed.combined ?? Data()
    }

    private static func decrypt(_ data: Data) throws -> Data {
        let key = try ensureSyncKey()
        let box = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(box, using: key)
    }

    private static func saveKey(_ key: SymmetricKey, account: String) throws {
        let data = key.withUnsafeBytes { Data($0) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw ICloudProfileSyncError.keychainFailed(status) }
    }

    private static func loadKey(account: String) -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return SymmetricKey(data: data)
    }
}

enum ICloudProfileSyncError: Error {
    case containerUnavailable
    case keychainFailed(OSStatus)
}
