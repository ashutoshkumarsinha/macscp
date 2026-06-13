// TraversioSFTPBackend.swift — Alternate SFTP backend (libssh2 via Traversio).
//
// Selected for SSH agent auth. Also used in macscp-benchmark comparisons.

import Foundation
import MacSCPCore
import Traversio

public final class TraversioSFTPBackend: CapableTransferBackend, @unchecked Sendable {
    public let backendIdentifier = "sftp-traversio"

    public var capabilities: BackendCapabilities {
        [.chmod, .atomicRename]
    }

    private var connection: SSHConnection?
    private var sftp: SFTPClient?
    private var configuration: SessionConfiguration?
    private var pathResolver = SFTPPathResolver()
    private let directoryCache = SFTPDirectoryCache()
    private let listingCache = SFTPListingCache()

    public private(set) var isConnected = false

    public init() {}

    public func connect(configuration: SessionConfiguration) async throws {
        if isConnected {
            try await disconnect()
        }

        let sshConfig = try await makeConfiguration(from: configuration)
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
        let bytes = try await sftp.uploadFile(
            from: localURL,
            to: resolved,
            chunkSize: UInt32(max(options.chunkSize, 32 * 1024)),
            maxConcurrentWrites: max(options.maxConcurrentWrites, 1),
            syncAfterWrite: false,
            shouldContinue: shouldContinue
        )

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

        return TransferResult(bytesTransferred: Int64(bytes), checksum: checksum)
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

        let start = Date()
        let shouldContinue = TransferContinuationFactory.shouldContinue(for: options.cancellation)
        let bytes = try await sftp.downloadFile(
            resolved,
            to: destination,
            chunkSize: UInt32(max(options.chunkSize, 32 * 1024)),
            maxConcurrentReads: max(options.maxConcurrentReads, 1),
            shouldContinue: shouldContinue
        )

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

        return TransferResult(bytesTransferred: Int64(bytes), checksum: checksum)
    }

    // MARK: - Private

    private func makeConfiguration(from configuration: SessionConfiguration) async throws -> SSHClientConfiguration {
        let auth: SSHAuthenticationMethod
        switch configuration.authMethod {
        case .password, .interactive:
            guard let password = configuration.password else {
                throw BackendError.authenticationFailed("Password required")
            }
            auth = .password(password)
        case .publicKey:
            guard let keyPath = configuration.keyPath else {
                throw BackendError.authenticationFailed("Key path required")
            }
            let expanded = NSString(string: keyPath).expandingTildeInPath
            auth = try SSHAuthenticationMethod.openSSHPrivateKey(
                contentsOfFile: expanded,
                passphrase: configuration.keyPassphrase
            )
        case .agent:
            auth = try await SSHAgentAuthSupport.traversioAuthentication()
        }

        return SSHClientConfiguration(
            host: configuration.host,
            port: UInt16(clamping: configuration.port),
            username: configuration.username,
            authentication: auth,
            hostKeyPolicy: makeHostKeyPolicy(for: configuration)
        )
    }

    private func makeHostKeyPolicy(for configuration: SessionConfiguration) -> SSHHostKeyPolicy {
        let endpoint = MacSCPHostKeyTrustStore.endpointKey(
            host: configuration.host,
            port: configuration.port
        )
        let expected = configuration.advanced.hostKeyFingerprint.map(MacSCPHostKeyTrustStore.normalizeFingerprint)

        if let expected, !expected.isEmpty {
            return .callback { request in
                let received = MacSCPHostKeyTrustStore.normalizeFingerprint(
                    request.trustedHostKey.fingerprintSHA256
                )
                if received == expected {
                    return .callback
                }
                throw BackendError.hostKeyRejected(expected: expected, actual: received)
            }
        }

        return .callback { request in
            let received = request.trustedHostKey.fingerprintSHA256
            try MacSCPHostKeyTrustStore.validateTOFU(
                endpoint: endpoint,
                receivedFingerprint: received,
                expectedFingerprint: nil
            )
            return .callback
        }
    }

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

    private func mapEntryType(_ attributes: SSHSFTPFileAttributes) -> EntryType {
        SFTPAttributeMapping.entryType(fromPermissions: attributes.permissions)
    }
}
