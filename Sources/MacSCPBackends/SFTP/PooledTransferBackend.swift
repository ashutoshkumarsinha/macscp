// PooledTransferBackend.swift
//
// WHAT THIS FILE DOES
// -------------------
// Multiple SFTP connections for parallel transfer jobs via TransferConnectionPool.
// SessionCoordinator wraps backends in PooledTransferBackend when pool size > 1 on Apple Silicon.
//

import Foundation
import MacSCPCore

actor TransferConnectionPool {
    private var available: [CapableTransferBackend]
    private var all: [CapableTransferBackend]

    init(primary: CapableTransferBackend) {
        self.all = [primary]
        self.available = [primary]
    }

    var allBackends: [CapableTransferBackend] { all }

    func add(_ backend: CapableTransferBackend) {
        all.append(backend)
        available.append(backend)
    }

    func borrow() async -> CapableTransferBackend {
        while available.isEmpty {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        return available.removeFirst()
    }

    func release(_ backend: CapableTransferBackend) {
        guard all.contains(where: { $0 === backend }) else { return }
        if !available.contains(where: { $0 === backend }) {
            available.append(backend)
        }
    }

    func shutdown() async throws {
        for backend in all {
            try await backend.disconnect()
        }
        available.removeAll()
        all.removeAll()
    }
}

/// Routes browse/metadata calls to a primary connection and transfer calls through a lease pool.
public final class PooledTransferBackend: CapableTransferBackend, @unchecked Sendable {
    public let backendIdentifier = "pooled-sftp"
    public var capabilities: BackendCapabilities {
        primary?.capabilities ?? []
    }

    public private(set) var isConnected = false

    private let poolSize: Int
    private let backendKind: SFTPBackendKind
    private var primary: CapableTransferBackend?
    private var pool: TransferConnectionPool?
    private var warmTask: Task<Void, Never>?
    private var sessionConfiguration: SessionConfiguration?
    private var currentRemotePath: String = "/"

    public init(poolSize: Int, backendKind: SFTPBackendKind = .citadel) {
        self.poolSize = max(1, poolSize)
        self.backendKind = backendKind
    }

    public func connect(configuration: SessionConfiguration) async throws {
        if isConnected {
            try await disconnect()
        }

        let primaryBackend = try await Self.makeConnectedBackend(
            backendKind: backendKind,
            configuration: configuration
        )
        primary = primaryBackend
        pool = TransferConnectionPool(primary: primaryBackend)
        sessionConfiguration = configuration
        currentRemotePath = configuration.initialRemotePath.isEmpty ? "/" : configuration.initialRemotePath
        isConnected = true

        if poolSize > 1 {
            warmTask = Task { [weak self] in
                await self?.warmRemainingConnections(startingAt: 1)
            }
        }
    }

    public func disconnect() async throws {
        warmTask?.cancel()
        warmTask = nil
        try await pool?.shutdown()
        pool = nil
        primary = nil
        sessionConfiguration = nil
        isConnected = false
    }

    public func changeDirectory(to path: String) async throws {
        guard let pool else { throw BackendError.notConnected }
        currentRemotePath = path
        for backend in await pool.allBackends {
            try await backend.changeDirectory(to: path)
        }
    }

    public func workingDirectory() async throws -> String {
        guard let primary else { throw BackendError.notConnected }
        return try await primary.workingDirectory()
    }

    public func listDirectory(at path: String) async throws -> [RemoteEntry] {
        guard let primary else { throw BackendError.notConnected }
        return try await primary.listDirectory(at: path)
    }

    public func stat(path: String) async throws -> RemoteEntry {
        guard let primary else { throw BackendError.notConnected }
        return try await primary.stat(path: path)
    }

    public func createDirectory(at path: String, recursive: Bool) async throws {
        guard let primary else { throw BackendError.notConnected }
        try await primary.createDirectory(at: path, recursive: recursive)
    }

    public func removeDirectory(at path: String, recursive: Bool) async throws {
        guard let primary else { throw BackendError.notConnected }
        try await primary.removeDirectory(at: path, recursive: recursive)
    }

    public func removeFile(at path: String) async throws {
        guard let primary else { throw BackendError.notConnected }
        try await primary.removeFile(at: path)
    }

    public func rename(from: String, to: String) async throws {
        guard let primary else { throw BackendError.notConnected }
        try await primary.rename(from: from, to: to)
    }

    public func setPermissions(_ permissions: FilePermissions, at path: String) async throws {
        guard let primary else { throw BackendError.notConnected }
        try await primary.setPermissions(permissions, at: path)
    }

    public func setOwnership(user: String?, group: String?, at path: String) async throws {
        guard let primary else { throw BackendError.notConnected }
        try await primary.setOwnership(user: user, group: group, at: path)
    }

    public func upload(
        localURL: URL,
        remotePath: String,
        options: TransferOptions
    ) async throws -> TransferResult {
        guard let pool else { throw BackendError.notConnected }
        let backend = await pool.borrow()
        do {
            let result = try await backend.upload(localURL: localURL, remotePath: remotePath, options: options)
            await pool.release(backend)
            return result
        } catch {
            await pool.release(backend)
            throw error
        }
    }

    public func download(
        remotePath: String,
        localURL: URL,
        options: TransferOptions
    ) async throws -> TransferResult {
        guard let pool else { throw BackendError.notConnected }
        let backend = await pool.borrow()
        do {
            let result = try await backend.download(remotePath: remotePath, localURL: localURL, options: options)
            await pool.release(backend)
            return result
        } catch {
            await pool.release(backend)
            throw error
        }
    }

    public func uploadBatch(
        items: [BatchUploadItem],
        options: TransferOptions
    ) async throws -> [TransferResult] {
        guard let pool else { throw BackendError.notConnected }
        let sortedItems = items.sorted { lhs, rhs in
            let lSize = (try? lhs.localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
            let rSize = (try? rhs.localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
            if lSize != rSize { return lSize < rSize }
            return lhs.remotePath < rhs.remotePath
        }
        let concurrency = max(1, options.maxConcurrentUploads)
        return try await SFTPBatchUploadExecutor.uploadBatch(
            items: sortedItems,
            options: options,
            concurrency: concurrency
        ) { item, itemOptions in
            let backend = await pool.borrow()
            do {
                let result = try await backend.upload(
                    localURL: item.localURL,
                    remotePath: item.remotePath,
                    options: itemOptions
                )
                await pool.release(backend)
                return result
            } catch {
                await pool.release(backend)
                throw error
            }
        }
    }

    private static func makeConnectedBackend(
        backendKind: SFTPBackendKind,
        configuration: SessionConfiguration
    ) async throws -> CapableTransferBackend {
        let raw = try TransferBackendFactory.make(
            for: .sftp,
            backend: backendKind,
            serialized: false
        )
        guard let capable = raw as? CapableTransferBackend else {
            throw BackendError.notImplemented("Pooled backend requires CapableTransferBackend")
        }
        try await capable.connect(configuration: configuration)
        return capable
    }

    private func warmRemainingConnections(startingAt index: Int) async {
        guard let configuration = sessionConfiguration, let pool else { return }
        for slot in index ..< poolSize {
            guard !Task.isCancelled else { return }
            do {
                let backend = try await Self.makeConnectedBackend(
                    backendKind: backendKind,
                    configuration: configuration
                )
                try await backend.changeDirectory(to: currentRemotePath)
                await pool.add(backend)
            } catch {
                MacSCPLogger.shared.warning(
                    "Pool warm-up connection \(slot + 1)/\(poolSize) failed: \(error.localizedDescription)",
                    category: .backend
                )
            }
        }
    }
}
