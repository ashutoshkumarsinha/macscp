import Foundation

public struct FTPConnectionURL: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var username: String
    public var password: String?
    public var path: String
    public var implicitTLS: Bool

    public init(
        host: String,
        port: Int,
        username: String,
        password: String? = nil,
        path: String,
        implicitTLS: Bool
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.path = path
        self.implicitTLS = implicitTLS
    }

    public static func parse(_ raw: String) throws -> FTPConnectionURL {
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "ftp" || scheme == "ftps" else {
            throw FTPConnectionURLError.invalidFormat
        }

        let host = components.host ?? "localhost"
        let implicitTLS = scheme == "ftps"
        let defaultPort = implicitTLS ? 990 : 21
        let port = components.port ?? defaultPort
        let username = components.user ?? "anonymous"
        let password = components.password
        let path = components.path.isEmpty ? "/" : components.path

        return FTPConnectionURL(
            host: host,
            port: port,
            username: username,
            password: password,
            path: path,
            implicitTLS: implicitTLS
        )
    }
}

public enum FTPConnectionURLError: Error, Equatable {
    case invalidFormat
}
