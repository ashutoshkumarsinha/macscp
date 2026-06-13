import Foundation
import MacSCPCore
import Traversio

public final class TraversioSFTPBackend: CapableTransferBackend, @unchecked Sendable {
    public let backendIdentifier = "sftp-traversio"

    public var capabilities: BackendCapabilities {
        [.resumeDownload, .resumeUpload, .chmod, .atomicRename]
    }

    private var connection: SSHConnection?
    private var sftp: SFTPClient?
    private var configuration: SessionConfiguration?
    private var remoteWorkingDirectory = "/"
    private let directoryCache = CitadelDirectoryCache()

    public private(set) var isConnected = false

    public init() {}

    public func connect(configuration: SessionConfiguration) async throws {
        if isConnected {
            try await disconnect()
        }

        let sshConfig = try makeConfiguration(from: configuration)
        let connection = try await SSHClient.connect(configuration: sshConfig)
        let sftp = try await connection.openSFTP()

        self.connection = connection
        self.sftp = sftp
        self.configuration = configuration
        self.remoteWorkingDirectory = configuration.initialRemotePath
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
        remoteWorkingDirectory = normalizeRemotePath(path)
    }

    public func workingDirectory() async throws -> String {
        try requireConnected()
        return remoteWorkingDirectory
    }

    public func listDirectory(at path: String) async throws -> [RemoteEntry] {
        let sftp = try requireSFTP()
        let resolved = resolveRemotePath(path)
        let names = try await sftp.listDirectory(resolved)
        return names
            .filter { $0.filename != "." && $0.filename != ".." }
            .map { name in
            RemoteEntry(
                name: name.filename,
                path: joinRemote(resolved, name.filename),
                type: mapEntryType(name.attributes),
                size: name.attributes.size.map { Int64($0) },
                permissions: name.attributes.permissions.map { FilePermissions(octal: $0) }
            )
        }
    }

    public func stat(path: String) async throws -> RemoteEntry {
        let sftp = try requireSFTP()
        let resolved = resolveRemotePath(path)
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
        let resolved = resolveRemotePath(path)
        if recursive {
            var parts: [String] = []
            for component in resolved.split(separator: "/") {
                parts.append(String(component))
                let partial = "/" + parts.joined(separator: "/")
                do {
                    try await sftp.makeDirectory(partial)
                } catch {
                    // May already exist.
                }
            }
        } else {
            try await sftp.makeDirectory(resolved)
        }
    }

    public func removeDirectory(at path: String, recursive: Bool) async throws {
        let sftp = try requireSFTP()
        let resolved = resolveRemotePath(path)
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
        try await sftp.removeFile(resolveRemotePath(path))
    }

    public func rename(from: String, to: String) async throws {
        let sftp = try requireSFTP()
        try await sftp.rename(resolveRemotePath(from), to: resolveRemotePath(to))
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
        try await sftp.setAttributes(resolveRemotePath(path), attributes: attrs)
    }

    public func uploadBatch(
        items: [BatchUploadItem],
        options: TransferOptions
    ) async throws -> [TransferResult] {
        try requireConnected()
        let parents = Set(
            items.compactMap { CitadelUploadPlanner.parentDirectory(of: resolveRemotePath($0.remotePath)) }
        )
        for parent in parents {
            try await ensureParentDirectoryCached(parent)
        }

        let concurrency = max(1, options.maxConcurrentUploads)
        var results = [TransferResult?](repeating: nil, count: items.count)

        try await withThrowingTaskGroup(of: (Int, TransferResult).self) { group in
            var nextIndex = 0

            func scheduleNext() {
                guard nextIndex < items.count else { return }
                let index = nextIndex
                nextIndex += 1
                let item = items[index]
                var itemOptions = options
                itemOptions.checksum = nil
                group.addTask {
                    let result = try await self.upload(
                        localURL: item.localURL,
                        remotePath: item.remotePath,
                        options: itemOptions
                    )
                    return (index, result)
                }
            }

            for _ in 0 ..< min(concurrency, items.count) {
                scheduleNext()
            }

            for try await (index, result) in group {
                results[index] = result
                scheduleNext()
            }
        }

        return results.map { $0! }
    }

    public func upload(
        localURL: URL,
        remotePath: String,
        options: TransferOptions
    ) async throws -> TransferResult {
        let sftp = try requireSFTP()
        let resolved = resolveRemotePath(remotePath)
        if let parent = CitadelUploadPlanner.parentDirectory(of: resolved) {
            try await ensureParentDirectoryCached(parent)
        }

        let totalSize = try CitadelUploadPlanner.localFileSize(at: localURL)
        let start = Date()
        let bytes = try await sftp.uploadFile(
            from: localURL,
            to: resolved,
            chunkSize: UInt32(max(options.chunkSize, 32 * 1024)),
            maxConcurrentWrites: max(options.maxConcurrentWrites, 1),
            syncAfterWrite: false
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
        if options.checksum == .sha256 {
            checksum = try Checksum.sha256(of: localURL)
        }

        return TransferResult(bytesTransferred: Int64(bytes), checksum: checksum)
    }

    public func download(
        remotePath: String,
        localURL: URL,
        options: TransferOptions
    ) async throws -> TransferResult {
        let sftp = try requireSFTP()
        let resolved = resolveRemotePath(remotePath)
        let start = Date()
        let bytes = try await sftp.downloadFile(
            resolved,
            to: localURL,
            chunkSize: UInt32(max(options.chunkSize, 32 * 1024)),
            maxConcurrentReads: max(options.maxConcurrentUploads, 1)
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
        if options.checksum == .sha256 {
            checksum = try Checksum.sha256(of: localURL)
        }

        return TransferResult(bytesTransferred: Int64(bytes), checksum: checksum)
    }

    // MARK: - Private

    private func makeConfiguration(from configuration: SessionConfiguration) throws -> SSHClientConfiguration {
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
            throw BackendError.notImplemented("SSH agent auth")
        }

        return SSHClientConfiguration(
            host: configuration.host,
            port: UInt16(clamping: configuration.port),
            username: configuration.username,
            authentication: auth,
            hostKeyPolicy: .acceptAnyVerifiedHostKey
        )
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

    private func requireSFTP() throws -> SFTPClient {
        try requireConnected()
        guard let sftp else { throw BackendError.notConnected }
        return sftp
    }

    private func resolveRemotePath(_ path: String) -> String {
        if path.hasPrefix("/") {
            return normalizeRemotePath(path)
        }
        return normalizeRemotePath(joinRemote(remoteWorkingDirectory, path))
    }

    private func normalizeRemotePath(_ path: String) -> String {
        var components: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == ".." {
                if !components.isEmpty { components.removeLast() }
            } else if part != "." {
                components.append(String(part))
            }
        }
        return "/" + components.joined(separator: "/")
    }

    private func joinRemote(_ base: String, _ name: String) -> String {
        if base.hasSuffix("/") {
            return base + name
        }
        return base + "/" + name
    }

    private func mapEntryType(_ attributes: SSHSFTPFileAttributes) -> EntryType {
        if attributes.permissions.map({ $0 & 0o170000 == 0o040000 }) == true {
            return .directory
        }
        return .file
    }
}
