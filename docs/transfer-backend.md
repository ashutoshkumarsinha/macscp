# TransferBackend Protocol

| Field | Value |
|---|---|
| Version | 0.3 |
| Related | [spec.md §7](spec.md), [HLD §7](hld.md), [SFTP spike](spikes/sftp-backend-spike.md) |

All MacSCP protocol implementations (SFTP, FTP, S3, …) conform to a shared Swift protocol in `MacSCPCore`. The GUI, CLI, and sync engine depend only on this interface — never on Citadel, libssh2, or other backend specifics.

---

## Design Goals

1. **Backend swap** — change SFTP library without touching UI/CLI.
2. **Async-first** — all I/O is `async throws`; cancellation via `TransferCancellation`.
3. **Progress** — uniform progress callbacks for transfer queue.
4. **Sendable** — backends safe to use across concurrency domains where possible.

---

## Core Types

See `Sources/MacSCPCore/` for authoritative definitions. Highlights:

```swift
public enum AuthMethod: String, Codable, Sendable {
    case password, publicKey, agent, interactive
}

public struct TransferOptions: Sendable {
    public var resume: Bool
    public var overwrite: OverwritePolicy
    public var chunkSize: Int
    public var maxConcurrentWrites: Int
    public var maxConcurrentReads: Int
    public var maxConcurrentUploads: Int
    public var smallFileThreshold: Int
    public var cancellation: TransferCancellation?
    public var progress: ProgressHandler?
    public var checksum: ChecksumAlgorithm?
}
```

Transfer queue reads defaults from `~/.macscp/config.toml` `[transfer]` via `MacSCPConfiguration`.

---

## Protocol Definition

```swift
public protocol TransferBackend: AnyObject, Sendable {
    var backendIdentifier: String { get }
    var isConnected: Bool { get }

    func connect(configuration: SessionConfiguration) async throws
    func disconnect() async throws

    func changeDirectory(to path: String) async throws
    func workingDirectory() async throws -> String

    func listDirectory(at path: String) async throws -> [RemoteEntry]
    func stat(path: String) async throws -> RemoteEntry

    func createDirectory(at path: String, recursive: Bool) async throws
    func removeDirectory(at path: String, recursive: Bool) async throws
    func removeFile(at path: String) async throws
    func rename(from: String, to: String) async throws
    func setPermissions(_ permissions: FilePermissions, at path: String) async throws

    func upload(localURL: URL, remotePath: String, options: TransferOptions) async throws -> TransferResult
    func download(remotePath: String, localURL: URL, options: TransferOptions) async throws -> TransferResult
}
```

`CapableTransferBackend` adds `capabilities` and optional `uploadBatch(items:options:)`.

---

## Optional Capabilities

```swift
public struct BackendCapabilities: OptionSet, Sendable {
    public static let resumeUpload    = Self(rawValue: 1 << 0)
    public static let resumeDownload  = Self(rawValue: 1 << 1)
    public static let chmod           = Self(rawValue: 1 << 2)
    public static let atomicRename    = Self(rawValue: 1 << 6)
    // ...
}
```

| Backend | Capabilities |
|---|---|
| Citadel | resume upload/download, chmod, atomic rename |
| Traversio | chmod, atomic rename |

---

## Factory

```swift
public enum TransferBackendFactory {
    public static func make(
        for transferProtocol: TransferProtocol,
        backend: SFTPBackendKind = .citadel,
        serialized: Bool = false
    ) throws -> TransferBackend
}

public enum SFTPBackendKind: String, Sendable, CaseIterable {
    case citadel
    case traversio
}
```

**App / CLI selection logic** (`SessionCoordinator`, `CLISessionStore`):

| Condition | Backend |
|---|---|
| `.publicKey`, `.password` (no proxy) | Citadel (default) |
| `.agent` | Traversio |
| `advanced.proxyType != .none` (HTTP, SOCKS5, jump) | Traversio |
| `use_traversio_for_performance = true` | Traversio (key/password) |

Before connect, `SessionConfiguration.mergeOpenSSHConfig()` may set `proxyType = .jump` from `~/.ssh/config`. Traversio connects via `TraversioSSHConfigurationBuilder` (`proxyJumpHosts`, `connectionProxy`).

Pass `serialized: true` to wrap the backend in `SerializingTransferBackend` (actor) for safe concurrent queue access.

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
    case transferFailed(String)
    case cancelled
}
```

---

## SFTP Backend Layout (As-Built)

```text
MacSCPBackends/SFTP/
  CitadelSFTPBackend.swift      # Default key/password backend
  TraversioSFTPBackend.swift    # Agent + proxy + optional perf mode
  TraversioSSHConfigurationBuilder.swift  # ProxyJump, HTTP/SOCKS → Traversio SSHClientConfiguration
  CitadelTCPConnector.swift     # Citadel TCP buffer / Nagle tuning
  SFTPPathResolver.swift        # Shared path normalize/resolve
  SFTPDirectoryCache.swift      # Session mkdir cache
  SFTPListingCache.swift        # Remote listDirectory cache (3 s TTL)
  SFTPBackendSelector.swift     # Backend selection + logging
  LocalFileReader.swift         # mmap local reads (Citadel upload)
  TransferBufferPool.swift      # NIO ByteBuffer reuse
  TransferNetworkTuning.swift   # TCP tuning log helpers
  SFTPUploadPlanner.swift       # Parent dir, file size
  SFTPBatchUploadExecutor.swift # Concurrent batch uploads
  CitadelPipelinedWriter.swift  # Pipelined SFTP WRITE (Citadel)
  CitadelPipelinedReader.swift  # Pipelined SFTP READ (Citadel)
  TransferDestinationResolver.swift
  MacSCPHostKeySupport.swift    # TOFU known_hosts.json
  SSHAgentAuthSupport.swift     # Traversio ssh-agent wrapper
  PooledTransferBackend.swift   # Multi-connection pool for parallel queue jobs
  SerializingTransferBackend.swift
  SFTPErrorHelpers.swift

MacSCPCore/
  OpenSSHConfigParser.swift     # Parse ~/.ssh/config Host blocks
  SessionConfiguration+OpenSSH.swift  # mergeOpenSSHConfig, CLI raw settings
```

### Performance notes

- **Small files** (< `smallFileThreshold`, default 256 KB): single SFTP write/read.
- **Large files**: chunked I/O with read-ahead overlap (Citadel read-ahead on download; local read-ahead on upload when `maxConcurrentWrites` > 1).
- **Batch uploads**: `uploadBatch` with `maxConcurrentUploads`; remote paths sorted for directory-cache locality; skip/rename policies still stat when needed.
- **Overwrite uploads**: no remote `stat` when policy is `.overwrite` or `.prompt`.
- **Parallel queue jobs**: when `max_concurrent_transfers` > 1, `PooledTransferBackend` opens one SFTP connection per slot.
- **Remote listings**: `SFTPListingCache` (3 s TTL) on Citadel and Traversio reduces repeated `listDirectory` round-trips.
- **Citadel TCP tuning**: `CitadelTCPConnector` sets `SO_SNDBUF`, `SO_RCVBUF`, and `TCP_NODELAY` from the active preset after connect.
- **Checksums**: optional via `verify_checksums` in config (`TransferOptions.verifyChecksum`); off by default for throughput.
- **Presets**: `preset = "default" | "lan" | "wan" | "apple_silicon"` in `~/.macscp/config.toml` apply tuned defaults (see user guide §5.4 and [apple-silicon-performance.md](apple-silicon-performance.md)).

---

## Testing

Mock backends in `MacSCPTests` implement the protocol for queue and cancellation tests.

Integration tests use the local OpenSSH fixture:

```bash
make server-start
make test
make bench-verify   # optional throughput + pass-criteria gate
```

Conformance coverage: list, upload/download, skip/rename/overwrite, cancellation, disconnect handling, directory planner.

---

*End of TransferBackend protocol v0.3*
