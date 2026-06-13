// TraversioSCPBackend.swift
//
// WHAT THIS FILE DOES
// -------------------
// SCP transfers via Traversio (one-shot copies over SSH). TransferBackendFactory selects
// this for scp:// protocol when the user needs legacy SCP instead of SFTP.
//

import Foundation
import MacSCPCore
import Traversio

public final class TraversioSCPBackend: CapableTransferBackend, @unchecked Sendable {
    public let backendIdentifier = "scp-traversio"

    public var capabilities: BackendCapabilities {
        [.chmod]
    }

    private var connection: SSHConnection?
    private var configuration: SessionConfiguration?
    private var pathResolver = SFTPPathResolver()
    private let directoryCache = SFTPDirectoryCache()

    public private(set) var isConnected = false

    public init() {}

    public func connect(configuration: SessionConfiguration) async throws {
        if isConnected {
            try await disconnect()
        }

        let sshConfig = try await TraversioSSHConfigurationBuilder.makeConfiguration(from: configuration)
        let connection = try await SSHClient.connect(configuration: sshConfig)

        self.connection = connection
        self.configuration = configuration
        self.pathResolver = SFTPPathResolver(workingDirectory: configuration.initialRemotePath)
        self.isConnected = true
    }

    public func disconnect() async throws {
        if let connection {
            await connection.close()
        }
        self.connection = nil
        self.configuration = nil
        self.isConnected = false
    }

    public func changeDirectory(to path: String) async throws {
        try requireConnected()
        pathResolver.changeDirectory(to: path)
    }

    public func workingDirectory() async throws -> String {
        try requireConnected()
        return pathResolver.workingDirectory
    }

    public func listDirectory(at path: String) async throws -> [RemoteEntry] {
        let connection = try requireConnection()
        let resolved = pathResolver.resolve(path)
        let quoted = shellQuote(resolved)
        let result = try await connection.execute("ls -la \(quoted)")
        guard result.exitStatus == 0 else {
            throw BackendError.transferFailed(
                "ls failed (exit \(result.exitStatus ?? 0))"
            )
        }
        let output = String(decoding: result.standardOutput, as: UTF8.self)
        return SSHRemoteListingParser.parse(output, basePath: resolved)
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
        let connection = try requireConnection()
        let resolved = pathResolver.resolve(path)
        let command = recursive ? "mkdir -p \(shellQuote(resolved))" : "mkdir \(shellQuote(resolved))"
        let result = try await connection.execute(command)
        guard result.exitStatus == 0 else {
            throw BackendError.transferFailed("mkdir failed")
        }
        directoryCache.insert(resolved)
    }

    public func removeDirectory(at path: String, recursive: Bool) async throws {
        let connection = try requireConnection()
        let resolved = pathResolver.resolve(path)
        let command = recursive ? "rm -rf \(shellQuote(resolved))" : "rmdir \(shellQuote(resolved))"
        let result = try await connection.execute(command)
        guard result.exitStatus == 0 else {
            throw BackendError.transferFailed("rmdir failed")
        }
    }

    public func removeFile(at path: String) async throws {
        let connection = try requireConnection()
        let resolved = pathResolver.resolve(path)
        let result = try await connection.execute("rm -f \(shellQuote(resolved))")
        guard result.exitStatus == 0 else {
            throw BackendError.transferFailed("rm failed")
        }
    }

    public func rename(from: String, to: String) async throws {
        let connection = try requireConnection()
        let source = pathResolver.resolve(from)
        let destination = pathResolver.resolve(to)
        let result = try await connection.execute(
            "mv \(shellQuote(source)) \(shellQuote(destination))"
        )
        guard result.exitStatus == 0 else {
            throw BackendError.transferFailed("rename failed")
        }
    }

    public func setPermissions(_ permissions: FilePermissions, at path: String) async throws {
        let connection = try requireConnection()
        let resolved = pathResolver.resolve(path)
        let mode = String(format: "%o", permissions.octal)
        let result = try await connection.execute("chmod \(mode) \(shellQuote(resolved))")
        guard result.exitStatus == 0 else {
            throw BackendError.transferFailed("chmod failed")
        }
    }

    public func upload(
        localURL: URL,
        remotePath: String,
        options: TransferOptions
    ) async throws -> TransferResult {
        let connection = try requireConnection()
        let resolved = pathResolver.resolve(remotePath)
        if let parent = SFTPUploadPlanner.parentDirectory(of: resolved) {
            try await ensureParentDirectoryCached(parent)
        }

        let start = Date()
        let result = try await connection.uploadSCPFile(
            from: localURL,
            to: resolved,
            fileName: localURL.lastPathComponent
        )
        reportProgress(
            direction: .upload,
            path: resolved,
            totalBytes: Int64(result.byteCount),
            start: start,
            options: options
        )
        return TransferResult(bytesTransferred: Int64(result.byteCount), checksum: nil)
    }

    public func download(
        remotePath: String,
        localURL: URL,
        options: TransferOptions
    ) async throws -> TransferResult {
        let connection = try requireConnection()
        let resolved = pathResolver.resolve(remotePath)
        let parent = localURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let start = Date()
        let result = try await connection.downloadSCPFile(resolved, to: localURL)
        reportProgress(
            direction: .download,
            path: resolved,
            totalBytes: Int64(result.byteCount),
            start: start,
            options: options
        )
        return TransferResult(bytesTransferred: Int64(result.byteCount), checksum: nil)
    }

    // MARK: - Private

    private func ensureParentDirectoryCached(_ parent: String) async throws {
        guard !parent.isEmpty, parent != "/" else { return }
        if directoryCache.contains(parent) { return }
        try await createDirectory(at: parent, recursive: true)
        directoryCache.insert(parent)
    }

    private func requireConnected() throws {
        guard isConnected else { throw BackendError.notConnected }
    }

    private func requireConnection() throws -> SSHConnection {
        try requireConnected()
        guard let connection else { throw BackendError.notConnected }
        return connection
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func reportProgress(
        direction: TransferDirection,
        path: String,
        totalBytes: Int64,
        start: Date,
        options: TransferOptions
    ) {
        guard let progress = options.progress else { return }
        let elapsed = Date().timeIntervalSince(start)
        progress(
            TransferProgress(
                transferID: UUID(),
                direction: direction,
                path: path,
                totalBytes: totalBytes,
                transferredBytes: totalBytes,
                bytesPerSecond: elapsed > 0 ? Double(totalBytes) / elapsed : nil
            )
        )
    }
}
