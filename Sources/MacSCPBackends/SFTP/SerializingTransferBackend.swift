// SerializingTransferBackend.swift — Actor gate so one SFTP connection is not raced by concurrent jobs.

import Foundation
import MacSCPCore

/// Serializes all SFTP operations on a single connection so concurrent queue jobs cannot race.
public final class SerializingTransferBackend: CapableTransferBackend, @unchecked Sendable {
    public let backendIdentifier: String
    public var capabilities: BackendCapabilities { innerCapabilities }
    public private(set) var isConnected = false

    private let gate: TransferBackendGate
    private let innerCapabilities: BackendCapabilities

    public init(wrapping backend: CapableTransferBackend) {
        self.gate = TransferBackendGate(backend: backend)
        self.backendIdentifier = "serializing-\(backend.backendIdentifier)"
        self.innerCapabilities = backend.capabilities
    }

    public func connect(configuration: SessionConfiguration) async throws {
        try await gate.connect(configuration: configuration)
        isConnected = true
    }

    public func disconnect() async throws {
        try await gate.disconnect()
        isConnected = false
    }

    public func changeDirectory(to path: String) async throws {
        try await gate.changeDirectory(to: path)
    }

    public func workingDirectory() async throws -> String {
        try await gate.workingDirectory()
    }

    public func listDirectory(at path: String) async throws -> [RemoteEntry] {
        try await gate.listDirectory(at: path)
    }

    public func stat(path: String) async throws -> RemoteEntry {
        try await gate.stat(path: path)
    }

    public func createDirectory(at path: String, recursive: Bool) async throws {
        try await gate.createDirectory(at: path, recursive: recursive)
    }

    public func removeDirectory(at path: String, recursive: Bool) async throws {
        try await gate.removeDirectory(at: path, recursive: recursive)
    }

    public func removeFile(at path: String) async throws {
        try await gate.removeFile(at: path)
    }

    public func rename(from: String, to: String) async throws {
        try await gate.rename(from: from, to: to)
    }

    public func setPermissions(_ permissions: FilePermissions, at path: String) async throws {
        try await gate.setPermissions(permissions, at: path)
    }

    public func upload(
        localURL: URL,
        remotePath: String,
        options: TransferOptions
    ) async throws -> TransferResult {
        try await gate.upload(localURL: localURL, remotePath: remotePath, options: options)
    }

    public func download(
        remotePath: String,
        localURL: URL,
        options: TransferOptions
    ) async throws -> TransferResult {
        try await gate.download(remotePath: remotePath, localURL: localURL, options: options)
    }

    public func uploadBatch(
        items: [BatchUploadItem],
        options: TransferOptions
    ) async throws -> [TransferResult] {
        var results: [TransferResult] = []
        results.reserveCapacity(items.count)
        for item in items {
            let result = try await gate.upload(
                localURL: item.localURL,
                remotePath: item.remotePath,
                options: options
            )
            results.append(result)
        }
        return results
    }
}

private actor TransferBackendGate {
    private let backend: CapableTransferBackend

    init(backend: CapableTransferBackend) {
        self.backend = backend
    }

    func connect(configuration: SessionConfiguration) async throws {
        try await backend.connect(configuration: configuration)
    }

    func disconnect() async throws {
        try await backend.disconnect()
    }

    func changeDirectory(to path: String) async throws {
        try await backend.changeDirectory(to: path)
    }

    func workingDirectory() async throws -> String {
        try await backend.workingDirectory()
    }

    func listDirectory(at path: String) async throws -> [RemoteEntry] {
        try await backend.listDirectory(at: path)
    }

    func stat(path: String) async throws -> RemoteEntry {
        try await backend.stat(path: path)
    }

    func createDirectory(at path: String, recursive: Bool) async throws {
        try await backend.createDirectory(at: path, recursive: recursive)
    }

    func removeDirectory(at path: String, recursive: Bool) async throws {
        try await backend.removeDirectory(at: path, recursive: recursive)
    }

    func removeFile(at path: String) async throws {
        try await backend.removeFile(at: path)
    }

    func rename(from: String, to: String) async throws {
        try await backend.rename(from: from, to: to)
    }

    func setPermissions(_ permissions: FilePermissions, at path: String) async throws {
        try await backend.setPermissions(permissions, at: path)
    }

    func upload(
        localURL: URL,
        remotePath: String,
        options: TransferOptions
    ) async throws -> TransferResult {
        try await backend.upload(localURL: localURL, remotePath: remotePath, options: options)
    }

    func download(
        remotePath: String,
        localURL: URL,
        options: TransferOptions
    ) async throws -> TransferResult {
        try await backend.download(remotePath: remotePath, localURL: localURL, options: options)
    }
}
