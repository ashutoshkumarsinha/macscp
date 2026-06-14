// FTPTransferBackend.swift
//
// WHAT THIS FILE DOES
// -------------------
// Plain FTP and FTPS (implicit + explicit AUTH TLS) TransferBackend implementation.
// TransferBackendFactory routes FTP/FTPS sessions here; uses FTPListingParser and FTPStreamChannel.
//

import Foundation
import MacSCPCore

public final class FTPTransferBackend: CapableTransferBackend, @unchecked Sendable {
    public let backendIdentifier: String
    public var capabilities: BackendCapabilities {
        [.resumeUpload, .resumeDownload, .chmod]
    }

    private let useFTPS: Bool
    private var channel = FTPStreamChannel()
    private var controlHost = ""
    private var configuration: SessionConfiguration?
    private var pathResolver = SFTPPathResolver()
    private let directoryCache = SFTPDirectoryCache()

    public private(set) var isConnected = false

    public init(useFTPS: Bool) {
        self.useFTPS = useFTPS
        self.backendIdentifier = useFTPS ? "ftps-native" : "ftp-native"
    }

    public func connect(configuration: SessionConfiguration) async throws {
        if isConnected {
            try await disconnect()
        }

        let implicitTLS = useFTPS && (configuration.advanced.ftpsImplicit || configuration.port == 990)
        controlHost = configuration.host
        try await channel.connect(
            host: configuration.host,
            port: configuration.port,
            useTLS: implicitTLS
        )

        let banner = try await FTPResponseParser.readResponse(from: channel)
        guard (200 ... 399).contains(banner.code) else {
            throw BackendError.transferFailed("FTP banner rejected: \(banner.message)")
        }

        if useFTPS, !implicitTLS {
            let auth = try await channel.sendCommand("AUTH TLS")
            try FTPResponseParser.expect(auth, codes: [234])
            try channel.upgradeToTLS()
            _ = try await channel.sendCommand("PBSZ 0")
            let prot = try await channel.sendCommand("PROT P")
            try FTPResponseParser.expect(prot, codes: [200])
        }

        let user = try await channel.sendCommand("USER \(configuration.username)")
        if user.code == 331 {
            guard let password = configuration.password else {
                throw BackendError.authenticationFailed("Password required")
            }
            let pass = try await channel.sendCommand("PASS \(password)")
            try FTPResponseParser.expect(pass, codes: [230])
        } else {
            try FTPResponseParser.expect(user, codes: [230])
        }

        _ = try? await channel.sendCommand("OPTS UTF8 ON")
        _ = try? await channel.sendCommand("TYPE I")

        let initialPath = configuration.initialRemotePath.isEmpty ? "/" : configuration.initialRemotePath
        if initialPath != "/" {
            let cwd = try await channel.sendCommand("CWD \(quote(initialPath))")
            try FTPResponseParser.expect(cwd, codes: [250])
        }

        self.configuration = configuration
        self.pathResolver = SFTPPathResolver(workingDirectory: initialPath)
        self.isConnected = true
    }

    public func disconnect() async throws {
        _ = try? await channel.sendCommand("QUIT")
        channel.close()
        configuration = nil
        isConnected = false
    }

    public func changeDirectory(to path: String) async throws {
        let resolved = pathResolver.resolve(path)
        let response = try await channel.sendCommand("CWD \(quote(resolved))")
        try FTPResponseParser.expect(response, codes: [250])
        pathResolver.changeDirectory(to: resolved)
    }

    public func workingDirectory() async throws -> String {
        try requireConnected()
        return pathResolver.workingDirectory
    }

    public func listDirectory(at path: String) async throws -> [RemoteEntry] {
        let resolved = pathResolver.resolve(path)
        let passive = try await enterPassiveMode()
        let list = try await channel.sendCommand("MLSD \(quote(resolved))")
        if list.code == 500 || list.code == 502 {
            let fallback = try await channel.sendCommand("LIST \(quote(resolved))")
            try FTPResponseParser.expect(fallback, codes: [150, 125])
            let text = try await readDataResponse(passive: passive)
            let complete = try await FTPResponseParser.readResponse(from: channel)
            try FTPResponseParser.expect(complete, codes: [226, 250])
            return FTPListingParser.parse(text, basePath: resolved)
        }
        try FTPResponseParser.expect(list, codes: [150, 125])
        let text = try await readDataResponse(passive: passive)
        let complete = try await FTPResponseParser.readResponse(from: channel)
        try FTPResponseParser.expect(complete, codes: [226, 250])
        return FTPListingParser.parse(text, basePath: resolved)
    }

    public func stat(path: String) async throws -> RemoteEntry {
        let resolved = pathResolver.resolve(path)
        let parent = SFTPUploadPlanner.parentDirectory(of: resolved) ?? "/"
        let entries = try await listDirectory(at: parent)
        let name = (resolved as NSString).lastPathComponent
        if let match = entries.first(where: { $0.name == name }) {
            return RemoteEntry(
                name: match.name,
                path: resolved,
                type: match.type,
                size: match.size,
                modified: match.modified,
                permissions: match.permissions
            )
        }
        throw BackendError.pathNotFound(resolved)
    }

    public func createDirectory(at path: String, recursive: Bool) async throws {
        let resolved = pathResolver.resolve(path)
        if recursive {
            var parts: [String] = []
            for component in resolved.split(separator: "/") {
                parts.append(String(component))
                let partial = "/" + parts.joined(separator: "/")
                if directoryCache.contains(partial) { continue }
                let response = try await channel.sendCommand("MKD \(quote(partial))")
                if response.code == 257 || response.message.localizedCaseInsensitiveContains("exists") {
                    directoryCache.insert(partial)
                } else if response.code >= 400 {
                    throw BackendError.transferFailed("MKD failed: \(response.message)")
                }
            }
        } else {
            let response = try await channel.sendCommand("MKD \(quote(resolved))")
            try FTPResponseParser.expect(response, codes: [257])
            directoryCache.insert(resolved)
        }
    }

    public func removeDirectory(at path: String, recursive: Bool) async throws {
        let resolved = pathResolver.resolve(path)
        if recursive {
            let entries = try await listDirectory(at: resolved)
            for entry in entries where entry.type == .file {
                try await removeFile(at: entry.path)
            }
            for entry in entries where entry.type == .directory {
                try await removeDirectory(at: entry.path, recursive: true)
            }
        }
        let response = try await channel.sendCommand("RMD \(quote(resolved))")
        try FTPResponseParser.expect(response, codes: [250])
    }

    public func removeFile(at path: String) async throws {
        let resolved = pathResolver.resolve(path)
        let response = try await channel.sendCommand("DELE \(quote(resolved))")
        try FTPResponseParser.expect(response, codes: [250])
    }

    public func rename(from: String, to: String) async throws {
        let source = pathResolver.resolve(from)
        let destination = pathResolver.resolve(to)
        let rnfr = try await channel.sendCommand("RNFR \(quote(source))")
        try FTPResponseParser.expect(rnfr, codes: [350])
        let rnto = try await channel.sendCommand("RNTO \(quote(destination))")
        try FTPResponseParser.expect(rnto, codes: [250])
    }

    public func setPermissions(_ permissions: FilePermissions, at path: String) async throws {
        let resolved = pathResolver.resolve(path)
        let mode = String(format: "%o", permissions.octal)
        let response = try await channel.sendCommand("SITE CHMOD \(mode) \(quote(resolved))")
        try FTPResponseParser.expect(response, codes: [200, 250])
    }

    public func setOwnership(user: String?, group: String?, at path: String) async throws {
        throw BackendError.notImplemented("FTP chown")
    }

    public func upload(
        localURL: URL,
        remotePath: String,
        options: TransferOptions
    ) async throws -> TransferResult {
        let resolved = pathResolver.resolve(remotePath)
        if let parent = SFTPUploadPlanner.parentDirectory(of: resolved) {
            try await ensureParentDirectoryCached(parent)
        }

        let passive = try await enterPassiveMode()
        let stor = try await channel.sendCommand("STOR \(quote(resolved))")
        try FTPResponseParser.expect(stor, codes: [150, 125])
        let bytes = try await FTPDataTransfer.upload(
            localURL: localURL,
            dataIn: passive.0,
            dataOut: passive.1,
            options: options,
            remotePath: resolved
        )
        let complete = try await FTPResponseParser.readResponse(from: channel)
        try FTPResponseParser.expect(complete, codes: [226, 250])
        return TransferResult(bytesTransferred: bytes, checksum: nil)
    }

    public func download(
        remotePath: String,
        localURL: URL,
        options: TransferOptions
    ) async throws -> TransferResult {
        let resolved = pathResolver.resolve(remotePath)
        let passive = try await enterPassiveMode()
        let retr = try await channel.sendCommand("RETR \(quote(resolved))")
        try FTPResponseParser.expect(retr, codes: [150, 125])
        let bytes = try await FTPDataTransfer.download(
            localURL: localURL,
            dataIn: passive.0,
            dataOut: passive.1,
            options: options,
            remotePath: resolved
        )
        let complete = try await FTPResponseParser.readResponse(from: channel)
        try FTPResponseParser.expect(complete, codes: [226, 250])
        return TransferResult(bytesTransferred: bytes, checksum: nil)
    }

    // MARK: - Private

    private func enterPassiveMode() async throws -> (InputStream, OutputStream) {
        let useEPSV = configuration?.advanced.ftpPassive ?? true
        let response: FTPResponse
        if useEPSV {
            response = try await channel.sendCommand("EPSV")
            if response.code != 229 {
                let pasv = try await channel.sendCommand("PASV")
                try FTPResponseParser.expect(pasv, codes: [227])
                return try await channel.openPassiveDataConnection(from: pasv, controlHost: controlHost)
            }
        } else {
            response = try await channel.sendCommand("PASV")
            try FTPResponseParser.expect(response, codes: [227])
            return try await channel.openPassiveDataConnection(from: response, controlHost: controlHost)
        }
        return try await channel.openPassiveDataConnection(from: response, controlHost: controlHost)
    }

    private func readDataResponse(passive: (InputStream, OutputStream)) async throws -> String {
        let (input, output) = passive
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let read = input.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            bytes.append(contentsOf: buffer.prefix(read))
        }
        input.close()
        output.close()
        return String(decoding: bytes, as: UTF8.self)
    }

    private func ensureParentDirectoryCached(_ parent: String) async throws {
        guard !parent.isEmpty, parent != "/" else { return }
        if directoryCache.contains(parent) { return }
        try await createDirectory(at: parent, recursive: true)
        directoryCache.insert(parent)
    }

    private func requireConnected() throws {
        guard isConnected else { throw BackendError.notConnected }
    }

    private func quote(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\\\"")
    }
}
