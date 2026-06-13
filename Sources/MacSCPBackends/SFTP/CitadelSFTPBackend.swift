// CitadelSFTPBackend.swift — Default SFTP backend (NIOSSH via Citadel).
//
// Used for password and SSH key file authentication. Shares path/upload helpers
// with TraversioSFTPBackend under SFTP/. Pipelined read/write when config allows.

import Citadel
import Crypto
import Foundation
import MacSCPCore
import NIO

public final class CitadelSFTPBackend: CapableTransferBackend, @unchecked Sendable {
    public let backendIdentifier = "sftp-citadel"

    public var capabilities: BackendCapabilities {
        [.resumeDownload, .resumeUpload, .chmod, .atomicRename]
    }

    private var client: SSHClient?
    private var sftp: SFTPClient?
    private var configuration: SessionConfiguration?
    private var pathResolver = SFTPPathResolver()
    private let directoryCache = SFTPDirectoryCache()

    public private(set) var isConnected = false

    public init() {}

    public func connect(configuration: SessionConfiguration) async throws {
        if isConnected {
            try await disconnect()
        }

        let authMethod = try await makeAuthenticationMethod(from: configuration)
        let hostKeyValidator = MacSCPHostKeyTrustStore.makeCitadelValidator(
            host: configuration.host,
            port: configuration.port,
            expectedFingerprint: configuration.advanced.hostKeyFingerprint
        )

        MacSCPLogger.shared.info(
            "Connecting to \(configuration.host):\(configuration.port) via Citadel",
            category: .backend
        )

        let sshClient = try await SSHClient.connect(
            host: configuration.host,
            port: configuration.port,
            authenticationMethod: authMethod,
            hostKeyValidator: hostKeyValidator,
            reconnect: .never
        )

        let sftpClient = try await sshClient.openSFTP()

        self.client = sshClient
        self.sftp = sftpClient
        self.configuration = configuration
        self.pathResolver = SFTPPathResolver(workingDirectory: configuration.initialRemotePath)
        self.isConnected = true
    }

    public func disconnect() async throws {
        MacSCPLogger.shared.info("Disconnecting Citadel SFTP backend", category: .backend)
        if let sftp {
            try await sftp.close()
        }
        if let client {
            try await client.close()
        }
        self.sftp = nil
        self.client = nil
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
        let sftp = try requireSFTP()
        let resolved = pathResolver.resolve(path)
        let rawEntries = try await sftp.listDirectory(atPath: resolved)
        return rawEntries
            .flatMap(\.components)
            .filter { $0.filename != "." && $0.filename != ".." }
            .map { component in
                RemoteEntry(
                    name: component.filename,
                    path: SFTPPathResolver.joinRemote(resolved, component.filename),
                    type: mapEntryType(component.attributes),
                    size: component.attributes.size.map { Int64($0) },
                    permissions: component.attributes.permissions.map { FilePermissions(octal: $0) }
                )
            }
    }

    public func stat(path: String) async throws -> RemoteEntry {
        let sftp = try requireSFTP()
        let resolved = pathResolver.resolve(path)
        let attrs = try await sftp.getAttributes(at: resolved)
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
                    try await sftp.createDirectory(atPath: partial)
                } catch {
                    if !SFTPErrorHelpers.isAlreadyExists(error) {
                        throw error
                    }
                }
            }
        } else {
            try await sftp.createDirectory(atPath: resolved)
        }
    }

    public func removeDirectory(at path: String, recursive: Bool) async throws {
        let sftp = try requireSFTP()
        let resolved = pathResolver.resolve(path)
        if recursive {
            let entries = try await listDirectory(at: resolved)
            for entry in entries {
                switch entry.type {
                case .directory:
                    try await removeDirectory(at: entry.path, recursive: true)
                case .file, .symlink:
                    try await removeFile(at: entry.path)
                }
            }
        }
        try await sftp.rmdir(at: resolved)
    }

    public func removeFile(at path: String) async throws {
        let sftp = try requireSFTP()
        try await sftp.remove(at: pathResolver.resolve(path))
    }

    public func rename(from: String, to: String) async throws {
        let sftp = try requireSFTP()
        try await sftp.rename(at: pathResolver.resolve(from), to: pathResolver.resolve(to))
    }

    public func setPermissions(_ permissions: FilePermissions, at path: String) async throws {
        let sftp = try requireSFTP()
        try await sftp.setAttributes(
            at: pathResolver.resolve(path),
            to: {
                var attrs = SFTPFileAttributes()
                attrs.permissions = permissions.octal
                return attrs
            }()
        )
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
                await TransferDestinationResolver.remotePathExists(sftp: sftp, path: path)
            }
        ) else {
            return TransferResult(bytesTransferred: 0)
        }

        if let parent = SFTPUploadPlanner.parentDirectory(of: resolved) {
            try await ensureParentDirectoryCached(parent)
        }

        let totalSize = try SFTPUploadPlanner.localFileSize(at: localURL)
        if totalSize <= options.smallFileThreshold {
            return try await uploadSmallFile(
                sftp: sftp,
                localURL: localURL,
                resolved: resolved,
                totalSize: totalSize,
                options: options
            )
        }
        return try await uploadLargeFile(
            sftp: sftp,
            localURL: localURL,
            resolved: resolved,
            totalSize: totalSize,
            options: options
        )
    }

    private func uploadSmallFile(
        sftp: SFTPClient,
        localURL: URL,
        resolved: String,
        totalSize: Int,
        options: TransferOptions
    ) async throws -> TransferResult {
        try options.throwIfCancelled()
        let data = try Data(contentsOf: localURL)
        let transferID = UUID()
        let start = Date()

        try await sftp.withFile(
            filePath: resolved,
            flags: [.write, .create, .truncate]
        ) { file in
            try options.throwIfCancelled()
            let buffer = ByteBuffer(data: data)
            try await file.write(buffer, at: 0)
        }

        if let progress = options.progress {
            let elapsed = Date().timeIntervalSince(start)
            progress(
                TransferProgress(
                    transferID: transferID,
                    direction: .upload,
                    path: resolved,
                    totalBytes: Int64(totalSize),
                    transferredBytes: Int64(totalSize),
                    bytesPerSecond: elapsed > 0 ? Double(totalSize) / elapsed : nil
                )
            )
        }

        var checksum: String?
        if options.checksum == .sha256, options.verifyChecksum {
            checksum = Checksum.sha256(of: data)
        }

        return TransferResult(bytesTransferred: Int64(totalSize), checksum: checksum)
    }

    private func uploadLargeFile(
        sftp: SFTPClient,
        localURL: URL,
        resolved: String,
        totalSize: Int,
        options: TransferOptions
    ) async throws -> TransferResult {
        let chunkSize = max(options.chunkSize, 256 * 1024)
        var offset: UInt64 = 0
        var resumedFrom: Int64?

        if options.resume {
            if let attrs = try? await sftp.getAttributes(at: resolved),
               let existingSize = attrs.size,
               existingSize < UInt64(totalSize) {
                offset = existingSize
                resumedFrom = Int64(existingSize)
            }
        }

        let flags: SFTPOpenFileFlags = offset > 0 ? [.write] : [.write, .create, .truncate]
        let file = try await sftp.openFile(filePath: resolved, flags: flags)
        let handle = try FileHandle(forReadingFrom: localURL)
        defer { try? handle.close() }

        if offset > 0 {
            try handle.seek(toOffset: offset)
        }

        let transferID = UUID()

        let bytesWritten: Int64
        do {
            if options.maxConcurrentWrites > 1 {
                bytesWritten = try await CitadelPipelinedWriter.upload(
                    file: file,
                    readHandle: handle,
                    totalSize: totalSize,
                    startOffset: offset,
                    chunkSize: chunkSize,
                    transferID: transferID,
                    remotePath: resolved,
                    progress: options.progress,
                    cancellation: options.cancellation
                )
            } else {
                bytesWritten = try await uploadLargeFileSequential(
                    file: file,
                    handle: handle,
                    totalSize: totalSize,
                    startOffset: offset,
                    chunkSize: chunkSize,
                    transferID: transferID,
                    resolved: resolved,
                    resumedFrom: resumedFrom,
                    options: options
                )
            }
        } catch {
            try? await file.close()
            throw error
        }
        try await file.close()

        var checksum: String?
        if options.checksum == .sha256, options.verifyChecksum {
            checksum = try Checksum.sha256(of: localURL)
        }

        return TransferResult(
            bytesTransferred: bytesWritten,
            checksum: checksum,
            resumedFrom: resumedFrom
        )
    }

    private func uploadLargeFileSequential(
        file: SFTPFile,
        handle: FileHandle,
        totalSize: Int,
        startOffset: UInt64,
        chunkSize: Int,
        transferID: UUID,
        resolved: String,
        resumedFrom: Int64?,
        options: TransferOptions
    ) async throws -> Int64 {
        var offset = startOffset
        let start = Date()

        while Int(offset) < totalSize {
            try options.throwIfCancelled()
            let toRead = min(chunkSize, totalSize - Int(offset))
            let chunk = try handle.read(upToCount: toRead) ?? Data()
            if chunk.isEmpty { break }
            let buffer = ByteBuffer(data: chunk)
            try await file.write(buffer, at: offset)
            offset += UInt64(chunk.count)

            if let progress = options.progress {
                let elapsed = Date().timeIntervalSince(start)
                progress(
                    TransferProgress(
                        transferID: transferID,
                        direction: .upload,
                        path: resolved,
                        totalBytes: Int64(totalSize),
                        transferredBytes: Int64(offset),
                        bytesPerSecond: elapsed > 0
                            ? Double(offset - UInt64(resumedFrom ?? 0)) / elapsed : nil
                    )
                )
            }
        }

        return Int64(offset - startOffset)
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

        let attrs = try await sftp.getAttributes(at: resolved)
        guard let remoteSize = attrs.size else {
            throw BackendError.transferFailed("Remote file has unknown size: \(resolved)")
        }

        var offset: UInt64 = 0
        var resumedFrom: Int64?

        if options.resume, FileManager.default.fileExists(atPath: destination.path) {
            let localSize = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            if localSize > 0, UInt64(localSize) < remoteSize {
                offset = UInt64(localSize)
                resumedFrom = Int64(localSize)
            }
        }

        let file = try await sftp.openFile(filePath: resolved, flags: .read)

        if offset == 0 {
            FileManager.default.createFile(atPath: destination.path, contents: nil)
        } else if !FileManager.default.fileExists(atPath: destination.path) {
            throw BackendError.transferFailed("Cannot resume: local file missing")
        }

        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        if offset > 0 {
            try handle.seek(toOffset: offset)
        }

        let chunkSize = UInt32(max(options.chunkSize, 32 * 1024))
        var transferred = Int64(offset)
        let transferID = UUID()
        let start = Date()

        do {
            let bytesRead: Int64
            if options.maxConcurrentReads > 1 {
                // Overlap SFTP READ round-trips; falls back to sequential loop when == 1.
                bytesRead = try await CitadelPipelinedReader.download(
                    file: file,
                    writeHandle: handle,
                    totalSize: remoteSize,
                    startOffset: offset,
                    chunkSize: chunkSize,
                    maxConcurrentReads: options.maxConcurrentReads,
                    transferID: transferID,
                    remotePath: resolved,
                    progress: options.progress,
                    cancellation: options.cancellation
                )
                transferred = Int64(offset) + bytesRead
            } else {
                while offset < remoteSize {
                    try options.throwIfCancelled()
                    let length = min(chunkSize, UInt32(remoteSize - offset))
                    let buffer = try await file.read(from: offset, length: length)
                    let data = Data(buffer: buffer)
                    try handle.write(contentsOf: data)
                    offset += UInt64(data.count)
                    transferred = Int64(offset)

                    if let progress = options.progress {
                        let elapsed = Date().timeIntervalSince(start)
                        let speed = elapsed > 0 ? Double(transferred - (resumedFrom ?? 0)) / elapsed : nil
                        progress(
                            TransferProgress(
                                transferID: transferID,
                                direction: .download,
                                path: resolved,
                                totalBytes: Int64(remoteSize),
                                transferredBytes: transferred,
                                bytesPerSecond: speed
                            )
                        )
                    }
                }
            }
        } catch {
            try? await file.close()
            throw error
        }
        try await file.close()

        var checksum: String?
        if options.checksum == .sha256, options.verifyChecksum {
            checksum = try Checksum.sha256(of: destination)
        }

        return TransferResult(
            bytesTransferred: transferred - (resumedFrom ?? 0),
            checksum: checksum,
            resumedFrom: resumedFrom
        )
    }

    // MARK: - Private

    private func makeAuthenticationMethod(from configuration: SessionConfiguration) async throws -> SSHAuthenticationMethod {
        switch configuration.authMethod {
        case .password, .interactive:
            guard let password = configuration.password else {
                throw BackendError.authenticationFailed("Password required")
            }
            return .passwordBased(username: configuration.username, password: password)
        case .publicKey:
            guard let keyPath = configuration.keyPath else {
                throw BackendError.authenticationFailed("Key path required")
            }
            let expanded = NSString(string: keyPath).expandingTildeInPath
            let keyString = try String(contentsOfFile: expanded, encoding: .utf8)
            let passData = configuration.keyPassphrase?.data(using: .utf8)
            let keyType = try SSHKeyDetection.detectPrivateKeyType(from: keyString)
            switch keyType {
            case .ed25519:
                let key = try Curve25519.Signing.PrivateKey(sshEd25519: keyString, decryptionKey: passData)
                return .ed25519(username: configuration.username, privateKey: key)
            case .rsa:
                let key = try Insecure.RSA.PrivateKey(sshRsa: keyString, decryptionKey: passData)
                return .rsa(username: configuration.username, privateKey: key)
            default:
                throw BackendError.authenticationFailed("Unsupported key type: \(keyType)")
            }
        case .agent:
            // App routes agent sessions to Traversio; this path is a safety net.
            throw BackendError.authenticationFailed("SSH agent auth requires the Traversio SFTP backend")
        }
    }

    private func ensureParentDirectoryCached(_ parent: String) async throws {
        guard parent != "/", !parent.isEmpty else { return }
        if directoryCache.contains(parent) { return }

        let sftp = try requireSFTP()
        if (try? await sftp.getAttributes(at: parent)) != nil {
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

    private func mapEntryType(_ attributes: SFTPFileAttributes) -> EntryType {
        SFTPAttributeMapping.entryType(fromPermissions: attributes.permissions)
    }
}

public enum TransferBackendFactory {
    /// Default factory entry point; uses Citadel unless caller specifies backend kind.
    public static func make(for transferProtocol: TransferProtocol) throws -> TransferBackend {
        try make(for: transferProtocol, backend: .citadel)
    }

    public static func make(
        for transferProtocol: TransferProtocol,
        backend: SFTPBackendKind,
        serialized: Bool = false
    ) throws -> TransferBackend {
        switch transferProtocol {
        case .sftp, .scp:
            let raw: CapableTransferBackend
            switch backend {
            case .citadel:
                raw = CitadelSFTPBackend()
            case .traversio:
                raw = TraversioSFTPBackend()
            }
            if serialized {
                return SerializingTransferBackend(wrapping: raw)
            }
            return raw
        case .ftp, .ftps:
            throw BackendError.notImplemented("FTP")
        case .webdav:
            throw BackendError.notImplemented("WebDAV")
        case .s3, .gcs:
            throw BackendError.notImplemented("S3")
        }
    }
}

private extension Data {
    init(buffer: ByteBuffer) {
        var copy = buffer
        self = copy.readData(length: copy.readableBytes) ?? Data()
    }
}
