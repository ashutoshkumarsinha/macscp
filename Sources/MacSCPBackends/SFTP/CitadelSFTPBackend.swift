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
    private var remoteWorkingDirectory = "/"
    private let directoryCache = CitadelDirectoryCache()

    public private(set) var isConnected = false

    public init() {}

    public func connect(configuration: SessionConfiguration) async throws {
        if isConnected {
            try await disconnect()
        }

        let authMethod = try makeAuthenticationMethod(from: configuration)
        let hostKeyValidator = SSHHostKeyValidator.acceptAnything()

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
        self.remoteWorkingDirectory = configuration.initialRemotePath
        self.isConnected = true
    }

    public func disconnect() async throws {
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
        remoteWorkingDirectory = normalizeRemotePath(path)
    }

    public func workingDirectory() async throws -> String {
        try requireConnected()
        return remoteWorkingDirectory
    }

    public func listDirectory(at path: String) async throws -> [RemoteEntry] {
        let sftp = try requireSFTP()
        let resolved = resolveRemotePath(path)
        let rawEntries = try await sftp.listDirectory(atPath: resolved)
        return rawEntries
            .flatMap(\.components)
            .filter { $0.filename != "." && $0.filename != ".." }
            .map { component in
                RemoteEntry(
                    name: component.filename,
                    path: joinRemote(resolved, component.filename),
                    type: mapEntryType(component.attributes),
                    size: component.attributes.size.map { Int64($0) },
                    permissions: component.attributes.permissions.map { FilePermissions(octal: $0) }
                )
            }
    }

    public func stat(path: String) async throws -> RemoteEntry {
        let sftp = try requireSFTP()
        let resolved = resolveRemotePath(path)
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
        let resolved = resolveRemotePath(path)
        if recursive {
            var parts: [String] = []
            for component in resolved.split(separator: "/") {
                parts.append(String(component))
                let partial = "/" + parts.joined(separator: "/")
                do {
                    try await sftp.createDirectory(atPath: partial)
                } catch {
                    // Directory may already exist when recursive.
                }
            }
        } else {
            try await sftp.createDirectory(atPath: resolved)
        }
    }

    public func removeDirectory(at path: String, recursive: Bool) async throws {
        let sftp = try requireSFTP()
        let resolved = resolveRemotePath(path)
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
        try await sftp.remove(at: resolveRemotePath(path))
    }

    public func rename(from: String, to: String) async throws {
        let sftp = try requireSFTP()
        try await sftp.rename(at: resolveRemotePath(from), to: resolveRemotePath(to))
    }

    public func setPermissions(_ permissions: FilePermissions, at path: String) async throws {
        let sftp = try requireSFTP()
        try await sftp.setAttributes(
            at: resolveRemotePath(path),
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
        let resolved = resolveRemotePath(remotePath)
        if let parent = CitadelUploadPlanner.parentDirectory(of: resolved) {
            try await ensureParentDirectoryCached(parent)
        }

        let totalSize = try CitadelUploadPlanner.localFileSize(at: localURL)
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
        let data = try Data(contentsOf: localURL)
        let transferID = UUID()
        let start = Date()

        try await sftp.withFile(
            filePath: resolved,
            flags: [.write, .create, .truncate]
        ) { file in
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
        if options.checksum == .sha256 {
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
        if options.maxConcurrentWrites > 1 {
            bytesWritten = try await CitadelPipelinedWriter.upload(
                file: file,
                readHandle: handle,
                totalSize: totalSize,
                startOffset: offset,
                maxConcurrentWrites: options.maxConcurrentWrites,
                transferID: transferID,
                remotePath: resolved,
                progress: options.progress
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

        try await file.close()

        var checksum: String?
        if options.checksum == .sha256 {
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

    public func download(
        remotePath: String,
        localURL: URL,
        options: TransferOptions
    ) async throws -> TransferResult {
        let sftp = try requireSFTP()
        let resolved = resolveRemotePath(remotePath)
        let attrs = try await sftp.getAttributes(at: resolved)
        guard let remoteSize = attrs.size else {
            throw BackendError.transferFailed("Remote file has unknown size: \(resolved)")
        }

        var offset: UInt64 = 0
        var resumedFrom: Int64?

        if options.resume, FileManager.default.fileExists(atPath: localURL.path) {
            let localSize = try localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            if localSize > 0, UInt64(localSize) < remoteSize {
                offset = UInt64(localSize)
                resumedFrom = Int64(localSize)
            }
        }

        let file = try await sftp.openFile(filePath: resolved, flags: .read)

        if offset == 0 {
            FileManager.default.createFile(atPath: localURL.path, contents: nil)
        } else if !FileManager.default.fileExists(atPath: localURL.path) {
            throw BackendError.transferFailed("Cannot resume: local file missing")
        }

        let handle = try FileHandle(forWritingTo: localURL)
        defer { try? handle.close() }

        if offset > 0 {
            try handle.seek(toOffset: offset)
        }

        let chunkSize = UInt32(max(options.chunkSize, 32 * 1024))
        var transferred = Int64(offset)
        let transferID = UUID()
        let start = Date()

        while offset < remoteSize {
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

        try await file.close()

        var checksum: String?
        if options.checksum == .sha256 {
            checksum = try Checksum.sha256(of: localURL)
        }

        return TransferResult(
            bytesTransferred: transferred - (resumedFrom ?? 0),
            checksum: checksum,
            resumedFrom: resumedFrom
        )
    }

    // MARK: - Private

    private func makeAuthenticationMethod(from configuration: SessionConfiguration) throws -> SSHAuthenticationMethod {
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
            throw BackendError.notImplemented("SSH agent auth")
        }
    }

    private func ensureParentDirectoryCached(_ parent: String) async throws {
        guard parent != "/", !parent.isEmpty else { return }
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

    private func mapEntryType(_ attributes: SFTPFileAttributes) -> EntryType {
        if attributes.permissions.map({ $0 & 0o170000 == 0o040000 }) == true {
            return .directory
        }
        return .file
    }
}

public enum TransferBackendFactory {
    public static func make(for transferProtocol: TransferProtocol) throws -> TransferBackend {
        try make(for: transferProtocol, backend: .citadel)
    }

    public static func make(
        for transferProtocol: TransferProtocol,
        backend: SFTPBackendKind
    ) throws -> TransferBackend {
        switch transferProtocol {
        case .sftp, .scp:
            switch backend {
            case .citadel:
                return CitadelSFTPBackend()
            case .traversio:
                return TraversioSFTPBackend()
            }
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
