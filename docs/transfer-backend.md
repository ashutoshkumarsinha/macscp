# TransferBackend Protocol

| Field | Value |
|---|---|
| Version | 0.1 (draft) |
| Related | [spec.md §7](spec.md), [SFTP spike](spikes/sftp-backend-spike.md) |

All MacSCP protocol implementations (SFTP, FTP, S3, …) conform to a shared Swift protocol in `MacSCPCore`. The GUI, CLI, and sync engine depend only on this interface — never on Citadel, libssh2, or other backend specifics.

---

## Design Goals

1. **Backend swap** — change SFTP library without touching UI/CLI.
2. **Async-first** — all I/O is `async throws`; cancellation via `Task`.
3. **Progress** — uniform progress callbacks for transfer queue.
4. **Sendable** — backends safe to use across concurrency domains where possible.

---

## Core Types

```swift
public enum TransferProtocol: String, Codable, Sendable {
    case sftp, scp, ftp, ftps, webdav, s3, gcs
}

public struct SessionConfiguration: Codable, Sendable {
    public var id: UUID
    public var name: String
    public var protocol: TransferProtocol
    public var host: String
    public var port: Int
    public var username: String
    public var authMethod: AuthMethod
    public var keyPath: String?
    public var initialRemotePath: String
    public var advanced: AdvancedSettings
}

public enum AuthMethod: String, Codable, Sendable {
    case password
    case publicKey
    case agent
    case interactive
}

public struct RemoteEntry: Sendable {
    public var name: String
    public var path: String
    public var type: EntryType
    public var size: Int64?
    public var modified: Date?
    public var permissions: FilePermissions?
}

public enum EntryType: Sendable {
    case file, directory, symlink
}

public struct TransferOptions: Sendable {
    public var resume: Bool = false
    public var overwrite: OverwritePolicy = .prompt
    public var transferMode: TransferMode = .binary
    public var checksum: ChecksumAlgorithm?
    public var progress: ProgressHandler?
}

public enum OverwritePolicy: Sendable {
    case prompt, overwrite, skip, rename
}

public struct TransferResult: Sendable {
    public var bytesTransferred: Int64
    public var checksum: String?
    public var resumedFrom: Int64?
}
```

---

## Protocol Definition

```swift
public protocol TransferBackend: AnyObject, Sendable {
    /// Human-readable backend id, e.g. "sftp-citadel"
    var backendIdentifier: String { get }

    /// Connected state
    var isConnected: Bool { get }

    /// Open connection; idempotent if already connected to same config
    func connect(configuration: SessionConfiguration) async throws

    /// Graceful disconnect
    func disconnect() async throws

    // MARK: - Navigation

    func changeDirectory(to path: String) async throws
    func workingDirectory() async throws -> String

    // MARK: - Listing

    func listDirectory(at path: String) async throws -> [RemoteEntry]
    func stat(path: String) async throws -> RemoteEntry

    // MARK: - Mutations

    func createDirectory(at path: String, recursive: Bool) async throws
    func removeDirectory(at path: String, recursive: Bool) async throws
    func removeFile(at path: String) async throws
    func rename(from: String, to: String) async throws
    func setPermissions(_ permissions: FilePermissions, at path: String) async throws

    // MARK: - Transfers

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
```

---

## Optional Capabilities

Backends declare features via `BackendCapabilities`:

```swift
public struct BackendCapabilities: OptionSet, Sendable {
    public static let resumeUpload    = Self(rawValue: 1 << 0)
    public static let resumeDownload  = Self(rawValue: 1 << 1)
    public static let chmod           = Self(rawValue: 1 << 2)
    public static let chown           = Self(rawValue: 1 << 3)
    public static let symlink         = Self(rawValue: 1 << 4)
    public static let serverSideCopy  = Self(rawValue: 1 << 5)
    public static let atomicRename    = Self(rawValue: 1 << 6)
}

public protocol CapableTransferBackend: TransferBackend {
    var capabilities: BackendCapabilities { get }
}
```

CLI `call chown` and sync `-criteria=checksum` check capabilities before executing.

---

## Factory

```swift
public enum TransferBackendFactory {
    public static func make(for protocol: TransferProtocol) throws -> TransferBackend {
        switch `protocol` {
        case .sftp, .scp:
            return SFTPBackend()   // Citadel-backed by default; swappable
        case .ftp, .ftps:
            throw BackendError.notImplemented("FTP")
        case .webdav:
            throw BackendError.notImplemented("WebDAV")
        case .s3, .gcs:
            throw BackendError.notImplemented("S3")
        }
    }
}
```

---

## Progress Reporting

```swift
public struct TransferProgress: Sendable {
    public var transferID: UUID
    public var direction: TransferDirection
    public var path: String
    public var totalBytes: Int64?
    public var transferredBytes: Int64
    public var bytesPerSecond: Double?
}

public typealias ProgressHandler = @Sendable (TransferProgress) -> Void
```

Transfer queue aggregates progress from multiple concurrent `upload`/`download` calls.

---

## Error Model

```swift
public enum BackendError: Error, Sendable {
    case notConnected
    case notImplemented(String)
    case authenticationFailed(String)
    case hostKeyRejected(expected: String?, actual: String)
    case pathNotFound(String)
    case permissionDenied(String)
    case transferFailed(String, underlying: Error?)
    case cancelled
}
```

Map to CLI exit codes: auth → 4, host key → 5, transfer → 3, connection → 2.

---

## SFTP Backend Implementation Notes

See [sftp-backend-spike.md](spikes/sftp-backend-spike.md).

Initial layout:

```text
MacSCPBackends/
  SFTP/
    SFTPBackend.swift          # TransferBackend conformance
    CitadelSession.swift       # Citadel connect/auth/disconnect
    CitadelTransfer.swift      # upload/download with progress
    SFTPBackendLegacy.swift    # Optional Traversio implementation (feature flag)
```

Feature flag in build settings or runtime config:

```swift
#if MACSCP_SFTP_LEGACY
import Traversio
#endif
```

---

## Testing

`MockTransferBackend` in `MacSCPTests` implements the protocol with in-memory filesystem for UI and CLI unit tests.

Integration tests (`MacSCPIntegrationTests`) run against Docker:

```yaml
# docker-compose.test.yml (future)
services:
  sftp:
    image: atmoz/sftp
    volumes:
      - ./fixtures:/home/test/upload
```

Each backend must pass `TransferBackendConformanceTests` — list, round-trip upload/download, resume, chmod, rename.

---

*End of TransferBackend protocol v0.1*
