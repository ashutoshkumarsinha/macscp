import Foundation

public enum TransferProtocol: String, Codable, Sendable {
    case sftp
    case scp
    case ftp
    case ftps
    case webdav
    case s3
    case gcs
}

public enum AuthMethod: String, Codable, Sendable {
    case password
    case publicKey
    case agent
    case interactive
}

public struct AdvancedSettings: Codable, Sendable, Equatable {
    public var compression: Bool
    public var connectionTimeoutSeconds: Int
    public var hostKeyFingerprint: String?

    public init(
        compression: Bool = false,
        connectionTimeoutSeconds: Int = 30,
        hostKeyFingerprint: String? = nil
    ) {
        self.compression = compression
        self.connectionTimeoutSeconds = connectionTimeoutSeconds
        self.hostKeyFingerprint = hostKeyFingerprint
    }
}

public struct SessionConfiguration: Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var `protocol`: TransferProtocol
    public var host: String
    public var port: Int
    public var username: String
    public var password: String?
    public var authMethod: AuthMethod
    public var keyPath: String?
    public var keyPassphrase: String?
    public var initialRemotePath: String
    public var advanced: AdvancedSettings
    /// Transfer network profile applied at connect (TCP buffer sizes, Nagle).
    public var networkProfile: TransferNetworkProfile

    public init(
        id: UUID = UUID(),
        name: String = "",
        protocol transferProtocol: TransferProtocol = .sftp,
        host: String,
        port: Int = 22,
        username: String,
        password: String? = nil,
        authMethod: AuthMethod = .password,
        keyPath: String? = nil,
        keyPassphrase: String? = nil,
        initialRemotePath: String = "/",
        advanced: AdvancedSettings = AdvancedSettings(),
        networkProfile: TransferNetworkProfile = .lan
    ) {
        self.id = id
        self.name = name
        self.protocol = transferProtocol
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.authMethod = authMethod
        self.keyPath = keyPath
        self.keyPassphrase = keyPassphrase
        self.initialRemotePath = initialRemotePath
        self.advanced = advanced
        self.networkProfile = networkProfile
    }
}
