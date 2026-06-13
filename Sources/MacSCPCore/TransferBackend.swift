// TransferBackend.swift
//
// WHAT THIS FILE DOES
// -------------------
// Protocol contract every file-transfer backend must implement. UI, CLI, and TransferQueue depend
// on this interface rather than Citadel or Traversio directly; BackendCapabilities flag optional features.
//

import Foundation

// Bit flags describing optional features a backend supports (resume, chmod, etc.).
public struct BackendCapabilities: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let resumeUpload = Self(rawValue: 1 << 0)
    public static let resumeDownload = Self(rawValue: 1 << 1)
    public static let chmod = Self(rawValue: 1 << 2)
    public static let chown = Self(rawValue: 1 << 3)
    public static let symlink = Self(rawValue: 1 << 4)
    public static let serverSideCopy = Self(rawValue: 1 << 5)
    public static let atomicRename = Self(rawValue: 1 << 6)
}

// Main abstraction: connect to a server and transfer files.
// AnyObject = class-only; Sendable = safe across Swift concurrency domains.
public protocol TransferBackend: AnyObject, Sendable {
    var backendIdentifier: String { get }
    var isConnected: Bool { get }

    // Session lifecycle
    func connect(configuration: SessionConfiguration) async throws
    func disconnect() async throws

    // Remote filesystem navigation
    func changeDirectory(to path: String) async throws
    func workingDirectory() async throws -> String

    // Directory listing and metadata
    func listDirectory(at path: String) async throws -> [RemoteEntry]
    func stat(path: String) async throws -> RemoteEntry

    // Remote file operations
    func createDirectory(at path: String, recursive: Bool) async throws
    func removeDirectory(at path: String, recursive: Bool) async throws
    func removeFile(at path: String) async throws
    func rename(from: String, to: String) async throws
    func setPermissions(_ permissions: FilePermissions, at path: String) async throws

    // Core transfer operations used by the transfer queue
    func upload(
        localURL: URL,
        remotePath: String,
        options: TransferOptions
    ) async throws -> TransferResult

    func download(
        remotePath: String,
        localURL: URL,
        options: TransferOptions
    ) async throws -> TransferResult
}

// Backends that advertise their capability flags implement this extension protocol.
public protocol CapableTransferBackend: TransferBackend {
    var capabilities: BackendCapabilities { get }
}
