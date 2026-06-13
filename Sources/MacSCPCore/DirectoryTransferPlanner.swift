// DirectoryTransferPlanner.swift
//
// WHAT THIS FILE DOES
// -------------------
// Expands directory trees into flat upload/download job lists. TransferCoordinator calls this
// before enqueueing; symlinks are skipped on download walks.
//

import Foundation

public struct DirectoryTransferFile: Sendable, Equatable {
    /// One file inside an expanded directory transfer.
    public var localURL: URL
    public var remotePath: String
    public var totalBytes: Int64?

    public init(localURL: URL, remotePath: String, totalBytes: Int64? = nil) {
        self.localURL = localURL
        self.remotePath = remotePath
        self.totalBytes = totalBytes
    }
}

public enum DirectoryTransferPlanner {
    public static func expandLocalDirectory(
        at directory: URL,
        remoteBase: String
    ) throws -> [DirectoryTransferFile] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [DirectoryTransferFile] = []
        let normalizedBase = SFTPPathJoin.normalizeRemote(remoteBase)

        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
            if values.isDirectory == true { continue }
            if values.isSymbolicLink == true {
                let resolved = fileURL.resolvingSymlinksInPath()
                let resolvedValues = try resolved.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if resolvedValues.isDirectory == true { continue }
            }

            let root = directory.standardizedFileURL.path
            let full = fileURL.standardizedFileURL.path
            guard full.hasPrefix(root + "/") else { continue }
            let relative = String(full.dropFirst(root.count + 1))
            let remotePath = SFTPPathJoin.joinRemote(normalizedBase, relative)
            files.append(
                DirectoryTransferFile(
                    localURL: fileURL,
                    remotePath: remotePath,
                    totalBytes: values.fileSize.map { Int64($0) }
                )
            )
        }

        return files.sorted { $0.remotePath < $1.remotePath }
    }

    public static func expandRemoteDirectory(
        backend: TransferBackend,
        at remoteDirectory: String,
        localBase: URL
    ) async throws -> [DirectoryTransferFile] {
        var files: [DirectoryTransferFile] = []
        try await collectRemoteFiles(
            backend: backend,
            remoteDirectory: remoteDirectory,
            localBase: localBase,
            into: &files
        )
        return files.sorted { $0.localURL.path < $1.localURL.path }
    }

    public static func ensureLocalDirectories(for files: [DirectoryTransferFile]) throws {
        let fileManager = FileManager.default
        let directories = Set(files.map { $0.localURL.deletingLastPathComponent().path })
        for path in directories.sorted() where !path.isEmpty {
            try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
    }

    private static func collectRemoteFiles(
        backend: TransferBackend,
        remoteDirectory: String,
        localBase: URL,
        into files: inout [DirectoryTransferFile]
    ) async throws {
        let entries = try await backend.listDirectory(at: remoteDirectory)
        for entry in entries {
            switch entry.type {
            case .directory:
                let childLocal = localBase.appendingPathComponent(entry.name, isDirectory: true)
                try await collectRemoteFiles(
                    backend: backend,
                    remoteDirectory: entry.path,
                    localBase: childLocal,
                    into: &files
                )
            case .file:
                files.append(
                    DirectoryTransferFile(
                        localURL: localBase.appendingPathComponent(entry.name),
                        remotePath: entry.path,
                        totalBytes: entry.size
                    )
                )
            case .symlink:
                if let target = try? await backend.stat(path: entry.path), target.type == EntryType.file {
                    files.append(
                        DirectoryTransferFile(
                            localURL: localBase.appendingPathComponent(entry.name),
                            remotePath: entry.path,
                            totalBytes: target.size
                        )
                    )
                }
            }
        }
    }
}

public enum SFTPPathJoin {
    public static func normalizeRemote(_ path: String) -> String {
        var components: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == ".." {
                if !components.isEmpty { components.removeLast() }
            } else if part != "." {
                components.append(String(part))
            }
        }
        if components.isEmpty { return "/" }
        return "/" + components.joined(separator: "/")
    }

    public static func joinRemote(_ base: String, _ name: String) -> String {
        if base == "/" { return "/\(name)" }
        if base.hasSuffix("/") { return base + name }
        return base + "/" + name
    }
}
