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
        backend: TransferBackend,
        options: SyncCompareOptions = SyncCompareOptions()
    ) async throws -> [SyncCompareRow] {
        let localFiles = try indexLocalFiles(at: localRoot)
        let remoteFiles = try await indexRemoteFiles(
            backend: backend,
            at: remoteRoot,
            options: options
        )
        let allPaths = Set(localFiles.keys).union(remoteFiles.keys)
            .filter { options.fileMask.matches(relativePath: $0) }
            .sorted()

        return allPaths.map { relative in
            let local = localFiles[relative]
            let remote = remoteFiles[relative]
            return buildRow(
                relative: relative,
                local: local,
                remote: remote,
                localRoot: localRoot,
                remoteRoot: remoteRoot,
                criteria: options.criteria
            )
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

    public struct MirrorTransferPlan: Sendable, Equatable {
        public var transfers: [DirectoryTransferFile]
        public var remoteDeletes: [String]
        public var localDeletes: [URL]

        public init(
            transfers: [DirectoryTransferFile] = [],
            remoteDeletes: [String] = [],
            localDeletes: [URL] = []
        ) {
            self.transfers = transfers
            self.remoteDeletes = remoteDeletes
            self.localDeletes = localDeletes
        }
    }

    public static func mirrorPlan(
        rows: [SyncCompareRow],
        direction: SyncDirection,
        deleteExtraneous: Bool
    ) -> MirrorTransferPlan {
        let transfers = toTransferFiles(rows: rows, direction: direction)
        guard deleteExtraneous else {
            return MirrorTransferPlan(transfers: transfers)
        }
        switch direction {
        case .mirrorLocalToRemote:
            return MirrorTransferPlan(
                transfers: transfers,
                remoteDeletes: rows.filter { $0.status == .newRemote }.compactMap(\.remotePath)
            )
        case .mirrorRemoteToLocal:
            return MirrorTransferPlan(
                transfers: transfers,
                localDeletes: rows.filter { $0.status == .newLocal }.compactMap(\.localURL)
            )
        case .bidirectional:
            return MirrorTransferPlan(transfers: transfers)
        }
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
        at remoteRoot: String,
        options: SyncCompareOptions
    ) async throws -> [String: RemoteIndexEntry] {
        let normalizedRoot = SFTPPathJoin.normalizeRemote(remoteRoot)
        let cacheKey = SyncIndexStore.cacheKey(
            remoteRoot: normalizedRoot,
            backendIdentifier: options.remoteIndexCacheKey ?? backend.backendIdentifier
        )

        if options.useRemoteIndexCache,
           let cached = await SyncIndexStore.shared.cachedEntries(forKey: cacheKey) {
            return cached.mapValues {
                RemoteIndexEntry(path: $0.path, size: $0.size, modified: $0.modified)
            }
        }

        let index = try await collectRemoteParallel(
            backend: backend,
            remoteDirectory: normalizedRoot,
            relativePrefix: "",
            concurrency: options.maxConcurrentRemoteLists
        )

        if options.useRemoteIndexCache {
            let stored = index.mapValues {
                SyncRemoteIndexEntry(path: $0.path, size: $0.size, modified: $0.modified)
            }
            await SyncIndexStore.shared.store(stored, forKey: cacheKey)
        }

        return index
    }

    private struct RemoteDirectoryWork: Sendable {
        var remoteDirectory: String
        var relativePrefix: String
    }

    private actor RemoteIndexBuilder {
        private var index: [String: RemoteIndexEntry] = [:]

        func addFile(relative: String, entry: RemoteIndexEntry) {
            index[relative] = entry
        }

        func snapshot() -> [String: RemoteIndexEntry] {
            index
        }
    }

    private static func collectRemoteParallel(
        backend: TransferBackend,
        remoteDirectory: String,
        relativePrefix: String,
        concurrency: Int
    ) async throws -> [String: RemoteIndexEntry] {
        let builder = RemoteIndexBuilder()
        var queue: [RemoteDirectoryWork] = [
            RemoteDirectoryWork(remoteDirectory: remoteDirectory, relativePrefix: relativePrefix),
        ]
        var queueIndex = 0

        try await withThrowingTaskGroup(of: [RemoteDirectoryWork].self) { group in
            var inFlight = 0

            func enqueueWork(_ work: RemoteDirectoryWork) {
                inFlight += 1
                group.addTask {
                    let entries = try await backend.listDirectory(at: work.remoteDirectory)
                    var childDirs: [RemoteDirectoryWork] = []
                    for entry in entries where entry.name != "." && entry.name != ".." {
                        let relative = work.relativePrefix.isEmpty
                            ? entry.name
                            : "\(work.relativePrefix)/\(entry.name)"
                        switch entry.type {
                        case .file:
                            await builder.addFile(
                                relative: relative,
                                entry: RemoteIndexEntry(
                                    path: entry.path,
                                    size: entry.size,
                                    modified: entry.modified
                                )
                            )
                        case .directory:
                            childDirs.append(
                                RemoteDirectoryWork(
                                    remoteDirectory: entry.path,
                                    relativePrefix: relative
                                )
                            )
                        case .symlink:
                            continue
                        }
                    }
                    return childDirs
                }
            }

            while queueIndex < queue.count || inFlight > 0 {
                while inFlight < concurrency, queueIndex < queue.count {
                    enqueueWork(queue[queueIndex])
                    queueIndex += 1
                }
                if inFlight == 0 { break }
                if let childDirs = try await group.next() {
                    queue.append(contentsOf: childDirs)
                    inFlight -= 1
                }
            }
        }

        return await builder.snapshot()
    }

    private static func buildRow(
        relative: String,
        local: LocalIndexEntry?,
        remote: RemoteIndexEntry?,
        localRoot: URL,
        remoteRoot: String,
        criteria: SyncCompareCriteria = .time
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
            let base = SyncCompareRow(
                relativePath: relative,
                status: .same,
                localURL: local.url,
                remotePath: remote.path,
                localSize: local.size,
                remoteSize: remote.size,
                localModified: local.modified,
                remoteModified: remote.modified
            )
            switch criteria {
            case .size:
                if local.size == remote.size {
                    return base
                }
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
            case .checksum:
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
                    return base
                }
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
            case .time:
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
                    return base
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
}
