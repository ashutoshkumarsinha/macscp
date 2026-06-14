// TransferProtocol.swift
//
// WHAT THIS FILE DOES
// -------------------
// Core enums and structs for supported protocols, auth methods, proxies, and advanced settings.
// SessionConfiguration, ConnectionURL, and TransferBackendFactory reference these types.
//
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

public enum ProxyType: String, Codable, Sendable, Equatable {
    case none
    case http
    case socks5
    case jump
}

public enum UILayoutMode: String, Codable, Sendable, Equatable {
    case commander
    case explorer
}

public struct AdvancedSettings: Codable, Sendable, Equatable {
    public var compression: Bool
    public var connectionTimeoutSeconds: Int
    public var hostKeyFingerprint: String?
    public var ftpPassive: Bool
    public var ftpsImplicit: Bool
    public var cloudRegion: String?
    public var cloudBucket: String?
    public var proxyType: ProxyType
    public var proxyHost: String?
    public var proxyPort: Int?
    /// OpenSSH `ProxyCommand` template (expanded with %h/%p/%r/%n at connect time).
    public var proxyCommand: String?

    public init(
        compression: Bool = false,
        connectionTimeoutSeconds: Int = 30,
        hostKeyFingerprint: String? = nil,
        ftpPassive: Bool = true,
        ftpsImplicit: Bool = false,
        cloudRegion: String? = nil,
        cloudBucket: String? = nil,
        proxyType: ProxyType = .none,
        proxyHost: String? = nil,
        proxyPort: Int? = nil,
        proxyCommand: String? = nil
    ) {
        self.compression = compression
        self.connectionTimeoutSeconds = connectionTimeoutSeconds
        self.hostKeyFingerprint = hostKeyFingerprint
        self.ftpPassive = ftpPassive
        self.ftpsImplicit = ftpsImplicit
        self.cloudRegion = cloudRegion
        self.cloudBucket = cloudBucket
        self.proxyType = proxyType
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
        self.proxyCommand = proxyCommand
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
    /// Derived from config preset at connect time; used by CitadelTCPConnector for socket tuning.
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
