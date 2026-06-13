// SessionProfile.swift — Saved connection profiles (JSON) and ProfileStore persistence.
//
// Passwords are stored in Keychain; profiles.json holds host, user, auth method, key path.

import Foundation
import MacSCPCore

struct SessionProfile: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var group: String?
    var host: String
    var port: Int
    var username: String
    var password: String?
    var authMethod: AuthMethod
    var keyPath: String?
    var initialRemotePath: String
    var favorite: Bool

    private enum CodingKeys: String, CodingKey {
        case id, name, group, host, port, username, authMethod, keyPath, initialRemotePath, favorite
        case password // legacy plaintext migration only
    }

    init(
        id: UUID = UUID(),
        name: String,
        group: String? = nil,
        host: String,
        port: Int = 22,
        username: String,
        password: String? = nil,
        authMethod: AuthMethod = .publicKey,
        keyPath: String? = nil,
        initialRemotePath: String = "/",
        favorite: Bool = false
    ) {
        self.id = id
        self.name = name
        self.group = group
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.authMethod = authMethod
        self.keyPath = keyPath
        self.initialRemotePath = initialRemotePath
        self.favorite = favorite
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        group = try container.decodeIfPresent(String.self, forKey: .group)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        username = try container.decode(String.self, forKey: .username)
        authMethod = try container.decode(AuthMethod.self, forKey: .authMethod)
        keyPath = try container.decodeIfPresent(String.self, forKey: .keyPath)
        initialRemotePath = try container.decodeIfPresent(String.self, forKey: .initialRemotePath) ?? "/"
        favorite = try container.decodeIfPresent(Bool.self, forKey: .favorite) ?? false

        if let legacyPassword = try container.decodeIfPresent(String.self, forKey: .password) {
            password = legacyPassword
        } else {
            password = KeychainCredentialStore.loadPassword(profileID: id)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(group, forKey: .group)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(username, forKey: .username)
        try container.encode(authMethod, forKey: .authMethod)
        try container.encodeIfPresent(keyPath, forKey: .keyPath)
        try container.encode(initialRemotePath, forKey: .initialRemotePath)
        try container.encode(favorite, forKey: .favorite)
    }

    var sessionConfiguration: SessionConfiguration {
        SessionConfiguration(
            id: id,
            name: name,
            protocol: .sftp,
            host: host,
            port: port,
            username: username,
            password: password,
            authMethod: authMethod,
            keyPath: keyPath,
            initialRemotePath: initialRemotePath
        )
    }

    static let sampleProfiles: [SessionProfile] = [
        SessionProfile(
            name: "Production Web API",
            group: nil,
            host: "127.0.0.1",
            port: 2222,
            username: NSUserName(),
            authMethod: .publicKey,
            keyPath: ".benchmark/keys/client_key",
            initialRemotePath: "/",
            favorite: true
        ),
        SessionProfile(
            name: "Home Raspberry Pi",
            group: nil,
            host: "raspberrypi.local",
            username: "pi",
            authMethod: .password,
            initialRemotePath: "/home/pi",
            favorite: true
        ),
    ]
}

struct ProfileStore {
    private var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("MacSCP/profiles.json")
    }

    func load() throws -> [SessionProfile] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        var profiles = try JSONDecoder().decode([SessionProfile].self, from: data)

        var migrated = false
        for index in profiles.indices {
            if let password = profiles[index].password, !password.isEmpty {
                try KeychainCredentialStore.savePassword(password, profileID: profiles[index].id)
                migrated = true
            }
        }
        if migrated {
            try save(profiles)
        }

        for index in profiles.indices where profiles[index].password == nil {
            profiles[index].password = KeychainCredentialStore.loadPassword(profileID: profiles[index].id)
        }

        return profiles
    }

    func save(_ profiles: [SessionProfile]) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for profile in profiles {
            if let password = profile.password, !password.isEmpty {
                try KeychainCredentialStore.savePassword(password, profileID: profile.id)
            } else {
                KeychainCredentialStore.deletePassword(profileID: profile.id)
            }
        }

        let tempURL = directory.appendingPathComponent("profiles.\(UUID().uuidString).json")
        let data = try JSONEncoder().encode(profiles)
        try data.write(to: tempURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func deleteCredentials(profileID: UUID) {
        KeychainCredentialStore.deletePassword(profileID: profileID)
    }
}
