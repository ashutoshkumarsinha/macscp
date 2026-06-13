// ConnectionURL.swift
//
// WHAT THIS FILE DOES
// -------------------
// Parses sftp, scp, ftp, and ftps URLs into a unified ConnectionURL value.
// CLIActions, SessionConfigurationBuilder, and the app use parse for connection strings.
//
import Foundation

public enum TransferProtocolDefaults {
    public static func defaultPort(for transferProtocol: TransferProtocol) -> Int {
        switch transferProtocol {
        case .sftp, .scp:
            return 22
        case .ftp:
            return 21
        case .ftps:
            return 21
        case .webdav:
            return 443
        case .s3, .gcs:
            return 443
        }
    }

    public static func supportsSSHAuth(_ transferProtocol: TransferProtocol) -> Bool {
        switch transferProtocol {
        case .sftp, .scp:
            return true
        default:
            return false
        }
    }

    public static func usesCloudCredentials(_ transferProtocol: TransferProtocol) -> Bool {
        switch transferProtocol {
        case .webdav, .s3, .gcs:
            return true
        default:
            return false
        }
    }
}

public struct ConnectionURL: Sendable, Equatable {
    public var transferProtocol: TransferProtocol
    public var host: String
    public var port: Int
    public var username: String
    public var password: String?
    public var keyPath: String?
    public var path: String
    public var authMethod: AuthMethod
    public var implicitTLS: Bool

    public static func parse(_ raw: String) throws -> ConnectionURL {
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased() else {
            throw ConnectionURLError.invalidFormat
        }

        switch scheme {
        case "sftp", "scp":
            let parsed = try SFTPConnectionURL.parse(raw.replacingOccurrences(of: "scp://", with: "sftp://"))
            return ConnectionURL(
                transferProtocol: scheme == "scp" ? .scp : .sftp,
                host: parsed.host,
                port: parsed.port,
                username: parsed.username,
                password: parsed.password,
                keyPath: parsed.keyPath,
                path: parsed.path,
                authMethod: parsed.authMethod,
                implicitTLS: false
            )
        case "ftp", "ftps":
            let parsed = try FTPConnectionURL.parse(raw)
            return ConnectionURL(
                transferProtocol: scheme == "ftps" ? .ftps : .ftp,
                host: parsed.host,
                port: parsed.port,
                username: parsed.username,
                password: parsed.password,
                keyPath: nil,
                path: parsed.path,
                authMethod: .password,
                implicitTLS: parsed.implicitTLS
            )
        case "webdav", "dav", "davs":
            let transferProtocol: TransferProtocol = .webdav
            let host = components.host ?? "localhost"
            let port = components.port ?? (scheme == "davs" ? 443 : 443)
            let username = components.user ?? ""
            let password = components.password
            let path = components.path.isEmpty ? "/" : components.path
            return ConnectionURL(
                transferProtocol: transferProtocol,
                host: host,
                port: port,
                username: username,
                password: password,
                keyPath: nil,
                path: path,
                authMethod: .password,
                implicitTLS: false
            )
        case "s3":
            return parseObjectStorageURL(components: components, provider: .aws, raw: raw)
        case "gcs":
            return parseObjectStorageURL(components: components, provider: .gcs, raw: raw)
        default:
            throw ConnectionURLError.unsupportedScheme(scheme)
        }
    }

    private static func parseObjectStorageURL(
        components: URLComponents,
        provider: ObjectStorageLayout.Provider,
        raw: String
    ) -> ConnectionURL {
        let host = components.host ?? (provider == .aws ? "s3.amazonaws.com" : "storage.googleapis.com")
        let port = components.port ?? 443
        let username = components.user ?? ""
        let password = components.password
        let path = components.path.isEmpty ? "/" : components.path
        return ConnectionURL(
            transferProtocol: provider == .aws ? .s3 : .gcs,
            host: host,
            port: port,
            username: username,
            password: password,
            keyPath: nil,
            path: path,
            authMethod: .password,
            implicitTLS: false
        )
    }
}

public enum ConnectionURLError: Error, Equatable {
    case invalidFormat
    case unsupportedScheme(String)
}
