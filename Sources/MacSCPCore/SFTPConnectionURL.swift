import Foundation

public struct SFTPConnectionURL: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var username: String
    public var password: String?
    public var keyPath: String?
    public var path: String
    public var authMethod: AuthMethod

    public init(
        host: String,
        port: Int,
        username: String,
        password: String? = nil,
        keyPath: String? = nil,
        path: String,
        authMethod: AuthMethod
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.keyPath = keyPath
        self.path = path
        self.authMethod = authMethod
    }

    public static func parse(_ raw: String) throws -> SFTPConnectionURL {
        guard let components = URLComponents(string: raw), components.scheme == "sftp" else {
            throw SFTPConnectionURLError.invalidFormat
        }
        let host = components.host ?? "localhost"
        let port = components.port ?? 22
        let username = components.user ?? NSUserName()
        let password = components.password
        let path = components.path.isEmpty ? "/" : components.path
        let authMethod: AuthMethod = password == nil ? .publicKey : .password
        return SFTPConnectionURL(
            host: host,
            port: port,
            username: username,
            password: password,
            keyPath: nil,
            path: path,
            authMethod: authMethod
        )
    }
}

public enum SFTPConnectionURLError: Error, Equatable {
    case invalidFormat
}
