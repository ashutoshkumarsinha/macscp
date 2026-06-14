// TraversioSFTPBackend.swift
//
// WHAT THIS FILE DOES
// -------------------
// Alternate SFTP backend (libssh2 via Traversio) for SSH agent auth and benchmark comparisons.
// SFTPBackendSelector routes agent sessions here; shares listing cache and upload helpers with Citadel.
//

import Foundation
import MacSCPCore
import Traversio

public final class TraversioSFTPBackend: CapableTransferBackend, @unchecked Sendable {
    public let backendIdentifier = "sftp-traversio"

    public var capabilities: BackendCapabilities {
        [.resumeDownload, .resumeUpload, .chmod, .chown, .atomicRename]
    }

    private var connection: SSHConnection?
    private var sftp: SFTPClient?
    private var configuration: SessionConfiguration?
    private var proxyRelay: ProxyCommandRelay?
    private var pathResolver = SFTPPathResolver()
    private let directoryCache = SFTPDirectoryCache()
    private let listingCache = SFTPListingCache()

    public private(set) var isConnected = false

    public init() {}

    public func connect(configuration: SessionConfiguration) async throws {
        if isConnected {
            try await disconnect()
        }

        let endpoint = try SSHConnectRouting.prepare(from: configuration)
        proxyRelay = endpoint.relay
        let sshConfig = try await TraversioSSHConfigurationBuilder.makeConfiguration(
            from: configuration,
            tcpHost: endpoint.host,
            tcpPort: endpoint.port
        )
        let connection = try await SSHClient.connect(configuration: sshConfig)
        let sftp = try await connection.openSFTP()

        self.connection = connection
        self.sftp = sftp
        self.configuration = configuration
        self.pathResolver = SFTPPathResolver(workingDirectory: configuration.initialRemotePath)
        self.isConnected = true
    }

    public func disconnect() async throws {
        if let connection {
            await connection.close()
        }
        self.connection = nil
        self.sftp = nil
        self.configuration = nil
        proxyRelay?.stop()
        proxyRelay = nil
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
        let sftp = try requireSFTP()
        let resolved = pathResolver.resolve(path)
        if let cached = await listingCache.listing(for: resolved) {
            return cached
        }
        let names = try await sftp.listDirectory(resolved)
        let entries = names
            .filter { $0.filename != "." && $0.filename != ".." }
            .map { name in
            RemoteEntry(
                name: name.filename,
                path: SFTPPathResolver.joinRemote(resolved, name.filename),
                type: mapEntryType(name.attributes),
                size: name.attributes.size.map { Int64($0) },
                permissions: name.attributes.permissions.map { FilePermissions(octal: $0) }
            )
        }
        await listingCache.store(entries, for: resolved)
        return entries
    }

    public func stat(path: String) async throws -> RemoteEntry {
        let sftp = try requireSFTP()
        let resolved = pathResolver.resolve(path)
        let attrs = try await sftp.stat(resolved)
        let name = (resolved as NSString).lastPathComponent
        return RemoteEntry(
            name: name.isEmpty ? resolved : name,
            path: resolved,
            type: mapEntryType(attrs),
            size: attrs.size.map { Int64($0) },
            permissions: attrs.permissions.map { FilePermissions(octal: $0) }
        )
    }

    public func createDirectory(at path: String, recursive: Bool) async throws {
        let sftp = try requireSFTP()
        let resolved = pathResolver.resolve(path)
        if recursive {
            var parts: [String] = []
            for component in resolved.split(separator: "/") {
                parts.append(String(component))
                let partial = "/" + parts.joined(separator: "/")
                do {
                    try await sftp.makeDirectory(partial)
                } catch {
                    if !SFTPErrorHelpers.isAlreadyExists(error) {
                        throw error
                    }
                }
            }
        } else {
            try await sftp.makeDirectory(resolved)
        }
    }

    public func removeDirectory(at path: String, recursive: Bool) async throws {
        let sftp = try requireSFTP()
        let resolved = pathResolver.resolve(path)
        if recursive {
            for entry in try await listDirectory(at: resolved) {
                switch entry.type {
                case .directory:
                    try await removeDirectory(at: entry.path, recursive: true)
                case .file, .symlink:
                    try await removeFile(at: entry.path)
                }
            }
        }
        try await sftp.removeDirectory(resolved)
    }

    public func removeFile(at path: String) async throws {
        let sftp = try requireSFTP()
        try await sftp.removeFile(pathResolver.resolve(path))
    }

    public func rename(from: String, to: String) async throws {
        let sftp = try requireSFTP()
        try await sftp.rename(pathResolver.resolve(from), to: pathResolver.resolve(to))
    }

    public func setPermissions(_ permissions: FilePermissions, at path: String) async throws {
        let sftp = try requireSFTP()
        let attrs = SSHSFTPFileAttributes(
            flags: SSHSFTPFileAttributes.permissionsFlag,
            size: nil,
            userID: nil,
            groupID: nil,
            permissions: permissions.octal,
            accessTime: nil,
            modificationTime: nil,
            extensions: []
        )
        try await sftp.setAttributes(pathResolver.resolve(path), attributes: attrs)
    }

    public func setOwnership(user: String?, group: String?, at path: String) async throws {
        let connection = try requireSSHConnection()
        let resolved = pathResolver.resolve(path)
        let command = RemoteOwnershipSupport.chownCommand(user: user, group: group, path: resolved)
        let result = try await connection.execute(command)
        guard result.exitStatus == 0 else {
            throw BackendError.transferFailed("chown failed")
        }
    }

    public func uploadBatch(
        items: [BatchUploadItem],
        options: TransferOptions
    ) async throws -> [TransferResult] {
        try requireConnected()
        let parents = Set(
            items.compactMap { SFTPUploadPlanner.parentDirectory(of: pathResolver.resolve($0.remotePath)) }
        )
        for parent in parents {
            try await ensureParentDirectoryCached(parent)
        }

        let sortedItems = items.sorted { $0.remotePath < $1.remotePath }
        let concurrency = max(1, options.maxConcurrentUploads)
        return try await SFTPBatchUploadExecutor.uploadBatch(
            items: sortedItems,
            options: options,
            concurrency: concurrency
        ) { item, itemOptions in
            try await self.upload(
                localURL: item.localURL,
                remotePath: item.remotePath,
                options: itemOptions
            )
        }
    }

    public func upload(
        localURL: URL,
        remotePath: String,
        options: TransferOptions
    ) async throws -> TransferResult {
        let sftp = try requireSFTP()
        try options.throwIfCancelled()

        guard let resolved = await TransferDestinationResolver.resolveRemoteUploadPath(
            path: pathResolver.resolve(remotePath),
            policy: options.overwrite,
            remoteExists: { path in
                (try? await sftp.stat(path)) != nil
            }
        ) else {
            return TransferResult(bytesTransferred: 0)
        }

        if let parent = SFTPUploadPlanner.parentDirectory(of: resolved) {
            try await ensureParentDirectoryCached(parent)
        }

        let totalSize = try SFTPUploadPlanner.localFileSize(at: localURL)
        let start = Date()
        let shouldContinue = TransferContinuationFactory.shouldContinue(for: options.cancellation)

        var resumedFrom: Int64?
        let bytes: UInt64
        if options.resume,
           let attrs = try? await sftp.stat(resolved),
           let existingSize = attrs.size,
           existingSize > 0,
           existingSize < UInt64(totalSize) {
            resumedFrom = Int64(existingSize)
            bytes = try await resumeUpload(
                sftp: sftp,
                localURL: localURL,
                resolved: resolved,
                startOffset: existingSize,
                totalSize: UInt64(totalSize),
                options: options
            )
        } else {
            bytes = try await sftp.uploadFile(
                from: localURL,
                to: resolved,
                chunkSize: UInt32(max(options.chunkSize, 32 * 1024)),
                maxConcurrentWrites: max(options.maxConcurrentWrites, 1),
                syncAfterWrite: false,
                shouldContinue: shouldContinue
            )
        }

        if let progress = options.progress {
            let elapsed = Date().timeIntervalSince(start)
            progress(
                TransferProgress(
                    transferID: UUID(),
                    direction: .upload,
                    path: resolved,
                    totalBytes: Int64(totalSize),
                    transferredBytes: Int64(bytes),
                    bytesPerSecond: elapsed > 0 ? Double(bytes) / elapsed : nil
                )
            )
        }

        var checksum: String?
        if options.checksum == .sha256, options.verifyChecksum {
            checksum = try Checksum.sha256(of: localURL)
        }

        await listingCache.invalidate(path: resolved)

        return TransferResult(bytesTransferred: Int64(bytes), checksum: checksum, resumedFrom: resumedFrom)
    }

    private func resumeUpload(
        sftp: SFTPClient,
        localURL: URL,
        resolved: String,
        startOffset: UInt64,
        totalSize: UInt64,
        options: TransferOptions
    ) async throws -> UInt64 {
        let remoteHandle = try await sftp.openFile(resolved, flags: [.write])
        let reader = try LocalFileSequentialReader(url: localURL)
        let chunkSize = max(options.chunkSize, 32 * 1024)
        var offset = Int(startOffset)
        var bytesWritten: UInt64 = 0

        do {
            while offset < Int(totalSize) {
                try options.throwIfCancelled()
                let data = try reader.read(from: offset, count: chunkSize)
                if data.isEmpty { break }
                try await remoteHandle.write(Array(data), at: UInt64(offset))
                offset += data.count
                bytesWritten += UInt64(data.count)
            }
        } catch {
            try? await remoteHandle.close()
            throw error
        }
        try await remoteHandle.close()

        return bytesWritten
    }

    public func download(
        remotePath: String,
        localURL: URL,
        options: TransferOptions
    ) async throws -> TransferResult {
        let sftp = try requireSFTP()
        try options.throwIfCancelled()
        let resolved = pathResolver.resolve(remotePath)

        guard let destination = try TransferDestinationResolver.resolveLocalDownloadURL(
            localURL,
            policy: options.overwrite
        ) else {
            return TransferResult(bytesTransferred: 0)
        }

        let attrs = try await sftp.stat(resolved)
        guard let remoteSize = attrs.size else {
            throw BackendError.transferFailed("Remote file has unknown size: \(resolved)")
        }

        var startOffset: UInt64 = 0
        var resumedFrom: Int64?
        if options.resume, FileManager.default.fileExists(atPath: destination.path) {
            let localSize = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            if localSize > 0, UInt64(localSize) < remoteSize {
                startOffset = UInt64(localSize)
                resumedFrom = Int64(localSize)
            }
        }

        let start = Date()
        let shouldContinue = TransferContinuationFactory.shouldContinue(for: options.cancellation)
        let bytes: UInt64
        if startOffset > 0 {
            bytes = try await resumeDownload(
                sftp: sftp,
                resolved: resolved,
                destination: destination,
                startOffset: startOffset,
                remoteSize: remoteSize,
                options: options
            )
        } else {
            bytes = try await sftp.downloadFile(
                resolved,
                to: destination,
                expectedSize: remoteSize,
                chunkSize: UInt32(max(options.chunkSize, 32 * 1024)),
                maxConcurrentReads: max(options.maxConcurrentReads, 1),
                shouldContinue: shouldContinue
            )
        }

        if let progress = options.progress {
            let elapsed = Date().timeIntervalSince(start)
            progress(
                TransferProgress(
                    transferID: UUID(),
                    direction: .download,
                    path: resolved,
                    totalBytes: Int64(bytes),
                    transferredBytes: Int64(bytes),
                    bytesPerSecond: elapsed > 0 ? Double(bytes) / elapsed : nil
                )
            )
        }

        var checksum: String?
        if options.checksum == .sha256, options.verifyChecksum {
            checksum = try Checksum.sha256(of: destination)
        }

        return TransferResult(
            bytesTransferred: Int64(bytes) - (resumedFrom ?? 0),
            checksum: checksum,
            resumedFrom: resumedFrom
        )
    }

    private func resumeDownload(
        sftp: SFTPClient,
        resolved: String,
        destination: URL,
        startOffset: UInt64,
        remoteSize: UInt64,
        options: TransferOptions
    ) async throws -> UInt64 {
        let remoteHandle = try await sftp.openFile(resolved, flags: [.read])
        let handle = try FileHandle(forWritingTo: destination)
        try handle.seekToEnd()

        let chunkSize = UInt32(max(options.chunkSize, 32 * 1024))
        var offset = startOffset
        var bytesDownloaded: UInt64 = 0

        do {
            for try await chunk in remoteHandle.readChunks(startingAt: offset, chunkSize: chunkSize) {
                try options.throwIfCancelled()
                if chunk.bytes.isEmpty { continue }
                handle.write(Data(chunk.bytes))
                bytesDownloaded += UInt64(chunk.bytes.count)
                offset += UInt64(chunk.bytes.count)
                if offset >= remoteSize { break }
            }
        } catch {
            try? handle.close()
            try? await remoteHandle.close()
            throw error
        }
        try handle.close()
        try await remoteHandle.close()

        return startOffset + bytesDownloaded
    }

    // MARK: - Private

    private func ensureParentDirectoryCached(_ parent: String) async throws {
        guard !parent.isEmpty, parent != "/" else { return }
        if directoryCache.contains(parent) { return }

        let sftp = try requireSFTP()
        if (try? await sftp.stat(parent)) != nil {
            directoryCache.insert(parent)
            return
        }

        try await createDirectory(at: parent, recursive: true)
        directoryCache.insert(parent)
    }

    private func requireConnected() throws {
        guard isConnected else { throw BackendError.notConnected }
    }

    private func requireSFTP() throws -> SFTPClient {
        try requireConnected()
        guard let sftp else { throw BackendError.notConnected }
        return sftp
    }

    private func requireSSHConnection() throws -> SSHConnection {
        try requireConnected()
        guard let connection else { throw BackendError.notConnected }
        return connection
    }

    private func mapEntryType(_ attributes: SSHSFTPFileAttributes) -> EntryType {
        SFTPAttributeMapping.entryType(fromPermissions: attributes.permissions)
    }
}
