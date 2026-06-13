// DirectorySyncEngine.swift
//
// WHAT THIS FILE DOES
// -------------------
// Compares local and remote directory trees for one-way sync. SyncCoordinator and SyncCompareView
// use SyncCompareRow status to plan upload or download of differing files.
//

import Foundation

public enum SyncEntryStatus: String, Sendable, Equatable, Codable {
    case same
    case newLocal
    case newRemote
    case newerLocal
    case newerRemote
    case sizeMismatch
}

public struct SyncCompareRow: Sendable, Equatable, Identifiable {
    public var id: String { relativePath }
    public var relativePath: String
    public var status: SyncEntryStatus
    public var localURL: URL?
    public var remotePath: String?
    public var localSize: Int64?
    public var remoteSize: Int64?
    public var localModified: Date?
    public var remoteModified: Date?

    public init(
        relativePath: String,
        status: SyncEntryStatus,
        localURL: URL? = nil,
        remotePath: String? = nil,
        localSize: Int64? = nil,
        remoteSize: Int64? = nil,
        localModified: Date? = nil,
        remoteModified: Date? = nil
    ) {
        self.relativePath = relativePath
        self.status = status
        self.localURL = localURL
        self.remotePath = remotePath
        self.localSize = localSize
        self.remoteSize = remoteSize
        self.localModified = localModified
        self.remoteModified = remoteModified
    }
}

public enum SyncDirection: Sendable {
    case mirrorLocalToRemote
    case mirrorRemoteToLocal
    case bidirectional
}

public enum DirectorySyncEngine {
    private static let compareKeys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]

    public static func compare(
        localRoot: URL,
        remoteRoot: String,
        backend: TransferBackend
    ) async throws -> [SyncCompareRow] {
        let localFiles = try indexLocalFiles(at: localRoot)
        let remoteFiles = try await indexRemoteFiles(backend: backend, at: remoteRoot)
        let allPaths = Set(localFiles.keys).union(remoteFiles.keys).sorted()

        return allPaths.map { relative in
            let local = localFiles[relative]
            let remote = remoteFiles[relative]
            return buildRow(relative: relative, local: local, remote: remote, localRoot: localRoot, remoteRoot: remoteRoot)
        }
    }

    public static func rowsNeedingUpload(_ rows: [SyncCompareRow]) -> [SyncCompareRow] {
        rows.filter { $0.status == .newLocal || $0.status == .newerLocal || $0.status == .sizeMismatch }
    }

    public static func rowsNeedingDownload(_ rows: [SyncCompareRow]) -> [SyncCompareRow] {
        rows.filter { $0.status == .newRemote || $0.status == .newerRemote || $0.status == .sizeMismatch }
    }

    public struct BidirectionalTransferPlan: Sendable, Equatable {
        public var uploads: [DirectoryTransferFile]
        public var downloads: [DirectoryTransferFile]
        public var remoteDeletes: [String]
        public var localDeletes: [URL]

        public init(
            uploads: [DirectoryTransferFile] = [],
            downloads: [DirectoryTransferFile] = [],
            remoteDeletes: [String] = [],
            localDeletes: [URL] = []
        ) {
            self.uploads = uploads
            self.downloads = downloads
            self.remoteDeletes = remoteDeletes
            self.localDeletes = localDeletes
        }
    }

    public static func toTransferFiles(
        rows: [SyncCompareRow],
        direction: SyncDirection
    ) -> [DirectoryTransferFile] {
        switch direction {
        case .mirrorLocalToRemote:
            return uploads(from: rows)
        case .mirrorRemoteToLocal:
            return downloads(from: rows)
        case .bidirectional:
            return uploads(from: rows) + downloads(from: rows)
        }
    }

    public static func bidirectionalPlan(
        rows: [SyncCompareRow],
        deleteExtraneous: Bool
    ) -> BidirectionalTransferPlan {
        var plan = BidirectionalTransferPlan(
            uploads: uploads(from: rows),
            downloads: downloads(from: rows)
        )
        if deleteExtraneous {
            plan.remoteDeletes = rows.filter { $0.status == .newLocal }.compactMap(\.remotePath)
            plan.localDeletes = rows.filter { $0.status == .newRemote }.compactMap(\.localURL)
        }
        return plan
    }

    private static func uploads(from rows: [SyncCompareRow]) -> [DirectoryTransferFile] {
        rowsNeedingUpload(rows).compactMap { row in
            guard let localURL = row.localURL, let remotePath = row.remotePath else { return nil }
            return DirectoryTransferFile(localURL: localURL, remotePath: remotePath, totalBytes: row.localSize)
        }
    }

    private static func downloads(from rows: [SyncCompareRow]) -> [DirectoryTransferFile] {
        rowsNeedingDownload(rows).compactMap { row in
            guard let localURL = row.localURL, let remotePath = row.remotePath else { return nil }
            return DirectoryTransferFile(localURL: localURL, remotePath: remotePath, totalBytes: row.remoteSize)
        }
    }

    private struct LocalIndexEntry {
        var url: URL
        var size: Int64?
        var modified: Date?
    }

    private struct RemoteIndexEntry {
        var path: String
        var size: Int64?
        var modified: Date?
    }

    private static func indexLocalFiles(at root: URL) throws -> [String: LocalIndexEntry] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: compareKeys,
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        var index: [String: LocalIndexEntry] = [:]
        let rootPath = root.standardizedFileURL.path

        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(compareKeys))
            if values.isDirectory == true { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(rootPath + "/") else { continue }
            let relative = String(full.dropFirst(rootPath.count + 1))
            index[relative] = LocalIndexEntry(
                url: url,
                size: values.fileSize.map { Int64($0) },
                modified: values.contentModificationDate
            )
        }
        return index
    }

    private static func indexRemoteFiles(
        backend: TransferBackend,
        at remoteRoot: String
    ) async throws -> [String: RemoteIndexEntry] {
        var index: [String: RemoteIndexEntry] = [:]
        let normalizedRoot = SFTPPathJoin.normalizeRemote(remoteRoot)
        try await collectRemote(
            backend: backend,
            remoteDirectory: normalizedRoot,
            relativePrefix: "",
            into: &index
        )
        return index
    }

    private static func collectRemote(
        backend: TransferBackend,
        remoteDirectory: String,
        relativePrefix: String,
        into index: inout [String: RemoteIndexEntry]
    ) async throws {
        let entries = try await backend.listDirectory(at: remoteDirectory)
        for entry in entries where entry.name != "." && entry.name != ".." {
            let relative = relativePrefix.isEmpty ? entry.name : "\(relativePrefix)/\(entry.name)"
            switch entry.type {
            case .file:
                index[relative] = RemoteIndexEntry(path: entry.path, size: entry.size, modified: entry.modified)
            case .directory:
                try await collectRemote(
                    backend: backend,
                    remoteDirectory: entry.path,
                    relativePrefix: relative,
                    into: &index
                )
            case .symlink:
                continue
            }
        }
    }

    private static func buildRow(
        relative: String,
        local: LocalIndexEntry?,
        remote: RemoteIndexEntry?,
        localRoot: URL,
        remoteRoot: String
    ) -> SyncCompareRow {
        let remotePath = remote?.path ?? SFTPPathJoin.joinRemote(SFTPPathJoin.normalizeRemote(remoteRoot), relative)
        let localURL = local?.url ?? localRoot.appendingPathComponent(relative)

        switch (local, remote) {
        case (nil, nil):
            return SyncCompareRow(relativePath: relative, status: .same)
        case (nil, let remote?):
            return SyncCompareRow(
                relativePath: relative,
                status: .newRemote,
                localURL: localURL,
                remotePath: remote.path,
                remoteSize: remote.size,
                remoteModified: remote.modified
            )
        case (let local?, nil):
            return SyncCompareRow(
                relativePath: relative,
                status: .newLocal,
                localURL: local.url,
                remotePath: remotePath,
                localSize: local.size,
                localModified: local.modified
            )
        case (let local?, let remote?):
            if local.size != remote.size {
                return SyncCompareRow(
                    relativePath: relative,
                    status: .sizeMismatch,
                    localURL: local.url,
                    remotePath: remote.path,
                    localSize: local.size,
                    remoteSize: remote.size,
                    localModified: local.modified,
                    remoteModified: remote.modified
                )
            }
            let localDate = local.modified ?? .distantPast
            let remoteDate = remote.modified ?? .distantPast
            if abs(localDate.timeIntervalSince(remoteDate)) < 1 {
                return SyncCompareRow(
                    relativePath: relative,
                    status: .same,
                    localURL: local.url,
                    remotePath: remote.path,
                    localSize: local.size,
                    remoteSize: remote.size,
                    localModified: local.modified,
                    remoteModified: remote.modified
                )
            }
            if localDate > remoteDate {
                return SyncCompareRow(
                    relativePath: relative,
                    status: .newerLocal,
                    localURL: local.url,
                    remotePath: remote.path,
                    localSize: local.size,
                    remoteSize: remote.size,
                    localModified: local.modified,
                    remoteModified: remote.modified
                )
            }
            return SyncCompareRow(
                relativePath: relative,
                status: .newerRemote,
                localURL: local.url,
                remotePath: remote.path,
                localSize: local.size,
                remoteSize: remote.size,
                localModified: local.modified,
                remoteModified: remote.modified
            )
        }
    }
}
