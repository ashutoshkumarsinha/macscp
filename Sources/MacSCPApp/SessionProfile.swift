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

    func load() -> [SessionProfile] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([SessionProfile].self, from: data)) ?? []
    }

    func save(_ profiles: [SessionProfile]) {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(profiles) {
            try? data.write(to: url)
        }
    }
}
