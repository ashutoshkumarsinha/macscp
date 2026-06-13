# MacSCP — High-Level Design (HLD)

| Field | Value |
|---|---|
| Version | 0.3 |
| Status | Draft — reflects Phase 0–1 implementation (SFTP MVP + Apple Silicon performance) |
| Related | [Product spec](spec.md), [TransferBackend](transfer-backend.md), [Apple Silicon performance](apple-silicon-performance.md), [SFTP spike](spikes/sftp-backend-spike.md) |

---

## 1. Purpose

This document describes the **as-built architecture** of MacSCP: major components, data flows, concurrency model, and extension points. It is intended for engineers contributing to the Swift package, not end users.

For usage instructions see [user-guide.md](user-guide.md).

---

## 2. System Context

MacSCP is a native macOS SFTP client (WinSCP-inspired) built as a Swift 6 package. It connects directly to remote SSH/SFTP servers — no relay or cloud intermediary.

```text
┌─────────────────────────────────────────────────────────────────┐
│                         macOS Host                              │
│  ┌──────────────┐    ┌─────────────┐    ┌──────────────────┐  │
│  │  MacSCP App  │───▶│  MacSCPUI   │───▶│  MacSCPCore      │  │
│  │  (SwiftUI)   │    │  (queue)    │    │  (models/proto)  │  │
│  └──────┬───────┘    └──────┬──────┘    └────────┬─────────┘  │
│         │                   │                     │            │
│         └───────────────────┴─────────────────────┘            │
│                             │                                   │
│                    ┌────────▼────────┐                          │
│                    │ MacSCPBackends  │                          │
│                    │ Citadel /       │                          │
│                    │ Traversio       │                          │
│                    └────────┬────────┘                          │
│                             │ SSH / SFTP                        │
└─────────────────────────────┼───────────────────────────────────┘
                              │
                    ┌─────────▼─────────┐
                    │  Remote SFTP      │
                    │  Server           │
                    └───────────────────┘
```

**External dependencies (runtime):**

| Dependency | Role |
|---|---|
| [Citadel](https://github.com/orlandos-nl/Citadel) | Default SFTP backend for key/password auth (NIOSSH + SFTP v3) |
| [Traversio](https://github.com/GitSwiftHQ/Traversio) | SFTP backend for SSH agent auth; benchmark/spike comparison |
| OpenSSH | Benchmark baseline (`sftp`, `sshd` test fixture) |

**Backend selection:** `SessionCoordinator` uses `SFTPBackendSelector`: Citadel for key/password by default, Traversio for SSH agent or when `use_traversio_for_performance` is set. Connection pool size comes from `TransferPerformanceTuning.effectivePoolSize` (elevated for `apple_silicon` preset on arm64). Each session carries a `TransferNetworkProfile` (from preset) used by `CitadelTCPConnector` for post-connect socket tuning.

---

## 3. Package Structure

```text
Sources/
  MacSCPCore/         Protocol, session models, config, performance tuning, BenchmarkHostInfo
  MacSCPBackends/     Citadel/Traversio backends, listing cache, TCP tuning, buffer pool, mmap reads
  MacSCPUI/           TransferQueue, overwrite batch types (shared by app + tests)
  MacSCPApp/          SwiftUI executable + coordinators
    Coordinators/     Profile, Session, LocalPane, RemotePane, Transfer
  MacSCPBenchmark/    macscp-benchmark CLI for throughput spikes
Tests/
  MacSCPTests/        Unit + integration tests (82 cases)
scripts/
  benchmark-env.sh    Local OpenSSH SFTP on :2222
  run-benchmarks.sh   Benchmark runner (--verify optional)
  verify-benchmark-report.sh  Pass-criteria gate for CI
  ci-local.sh         Local GitHub Actions parity (check + bench + verify)
  generate-app-icon.sh
  package-dmg.sh
.github/workflows/
  ci.yml              macos-15: make check + bench-apple-silicon + verify
Makefile              build, test, ci, run, bench, logs, config, paths
```

### 3.1 Module Dependency Graph

```text
MacSCPApp ──▶ MacSCPUI ──▶ MacSCPBackends ──▶ MacSCPCore
                │                              ▲
                └──────────────────────────────┘
MacSCPBenchmark ──▶ MacSCPBackends
MacSCPTests ──▶ MacSCPCore, MacSCPBackends, MacSCPUI
```

| Module | Responsibility |
|---|---|
| **MacSCPCore** | `TransferBackend` protocol, `SessionConfiguration`, `TransferOptions`, `TransferCancellation`, `DirectoryTransferPlanner`, `MacSCPConfiguration`, `TransferPerformanceTuning`, `BenchmarkHostInfo`, `StreamingChecksum`, logging |
| **MacSCPBackends** | SFTP implementations, shared path/upload helpers, pipelined Citadel read/write, listing cache, TCP tuning, buffer pool, mmap local reads, host-key TOFU, agent auth (Traversio) |
| **MacSCPUI** | Background transfer queue, job state machine, overwrite batch model |
| **MacSCPApp** | SwiftUI shell, coordinator decomposition, session profiles, commander panes, drag-and-drop |
| **MacSCPBenchmark** | Automated throughput comparison vs OpenSSH; embeds `BenchmarkHostInfo` from MacSCPCore in JSON reports |

---

## 4. Layered Architecture

| Layer | Components | Depends on |
|---|---|---|
| **Presentation** | `MacSCPApp`, SwiftUI views, `@Observable AppModel` (facade) | MacSCPUI, MacSCPCore, MacSCPBackends |
| **Application** | Coordinators, `TransferQueue`, `SessionConnectionService`, `ProfileStore` | TransferBackend, TransferBackendProvider |
| **Domain** | Session/transfer models, overwrite policies, pane rules, directory expansion | — |
| **Infrastructure** | Citadel/Traversio backends, shared SFTP helpers, pipelined I/O, Keychain | Citadel, Traversio, swift-crypto |

**Design rule:** UI and future CLI must talk only to `TransferBackend` and shared core types — never to Citadel or Traversio APIs directly.

---

## 5. Core Abstractions

### 5.1 TransferBackend

All protocol access flows through `TransferBackend` ([transfer-backend.md](transfer-backend.md)):

- `connect` / `disconnect`
- `listDirectory`, `stat`, `mkdir`, `remove`, `rename`, `chmod`
- `upload` / `download` with `TransferOptions`
- `uploadBatch` (optional, on `CapableTransferBackend`)

Backends are selected via `TransferBackendFactory.make(for:backend:serialized:)` (default: `.citadel`).

### 5.2 TransferOptions

Key fields (defaults overridable in `~/.macscp/config.toml` `[transfer]`):

| Field | Default | Purpose |
|---|---|---|
| `overwrite` | `.overwrite` | UI sets batch prompt → user picks skip/rename/overwrite |
| `resume` | `true` (from config) | Partial transfer resume |
| `verifyChecksums` | `false` (from config) | Streaming SHA-256 during upload (`StreamingChecksum`) |
| `cancellation` | `nil` | `TransferCancellation` for mid-flight cancel |
| `maxConcurrentWrites` | from config / preset | Citadel pipelined SFTP WRITE window |
| `maxConcurrentReads` | from config / preset | Citadel pipelined SFTP READ window |
| `maxConcurrentUploads` | from config / preset | Batch upload concurrency |
| `chunkSize` | from config / preset | Read/write chunk size (2 MB for `apple_silicon`) |
| `smallFileThreshold` | 512 KB | Single-write fast path |
| `progress` | `nil` | Callback → transfer queue UI |

**Transfer presets** (`TransferPerformancePreset` in `MacSCPConfiguration`): `default`, `lan`, `wan`, `apple_silicon`. Presets apply tuned defaults; explicit keys in `config.toml` override. First launch on arm64 writes `apple_silicon` automatically. See [apple-silicon-performance.md](apple-silicon-performance.md).

### 5.3 TransferCancellation

Thread-safe cancellation token polled by backends during read/write loops and pipelined upload/download. Cancel propagates as `BackendError.cancelled`.

---

## 6. Component Design

### 6.1 MacSCP App — Coordinator Decomposition

`AppModel` is a thin `@MainActor @Observable` facade. Logic lives in coordinators under `Sources/MacSCPApp/Coordinators/`:

| Coordinator | Responsibility |
|---|---|
| **ProfileCoordinator** | Load/save/delete profiles, `SessionProfileDraft`, Keychain password migration |
| **SessionCoordinator** | Connect/disconnect, backend lifecycle, remote working path, backend kind selection, pool sizing, network profile on session |
| **LocalPaneCoordinator** | Local path, entries, selection, navigation |
| **RemotePaneCoordinator** | Remote entries, selection, refresh |
| **TransferCoordinator** | Upload/download/drop, directory expansion (local scan on detached task), overwrite batch, queue binding |

`AppModel` forwards properties for SwiftUI bindings and implements `TransferBackendProvider`.

### 6.2 Session Login

- Sidebar: saved profiles
- Form: host, port, username, authentication picker (SSH key / password / SSH agent)
- Passwords stored in Keychain (`KeychainCredentialStore`); profiles JSON holds metadata only
- Sample profile targets local benchmark server (`127.0.0.1:2222`)

### 6.3 Commander (Dual-Pane)

```text
┌────────────────────────────────────────────────────────────┐
│ Toolbar: Up · Refresh · Upload · Download                  │
├──────────────────────────┬─────────────────────────────────┤
│ LOCAL pane               │ REMOTE pane                     │
│ List + multi-select      │ List + multi-select             │
│ Drag source / drop tgt   │ Drag source / drop tgt          │
├──────────────────────────┴─────────────────────────────────┤
│ Transfer queue (progress, pause, cancel)                   │
├────────────────────────────────────────────────────────────┤
│ Status bar                                                 │
└────────────────────────────────────────────────────────────┘
```

**Drag-and-drop rules** (`PaneTransferRules`):

- Local → Remote: upload
- Remote → Local: download
- Same pane: rejected
- **Files and folders** may be dragged; folders expand recursively

### 6.4 Directory Transfers

`DirectoryTransferPlanner` (MacSCPCore) expands trees before enqueue:

- **Upload:** `expandLocalDirectory(at:remoteBase:)` walks local tree → flat file list with remote paths
- **Download:** `expandRemoteDirectory(backend:at:localBase:)` walks remote tree via `listDirectory`
- **Local mkdir:** `ensureLocalDirectories(for:)` creates parent paths before download jobs run
- **Remote mkdir:** backends call `ensureParentDirectoryCached` (via `SFTPDirectoryCache`) per upload path

### 6.5 Transfer Queue

Background processor on `@MainActor`:

```text
         enqueueUpload/Download/Batch
                 │
                 ▼
            ┌─────────┐
            │  queued │
            └────┬────┘
                 │ slot available (config: max_concurrent_transfers)
                 ▼
            ┌─────────┐     cancel() ──▶ TransferCancellation.cancel()
            │ running │                    + Task.cancel()
            └────┬────┘
                 │
     ┌───────────┼───────────┬──────────┐
     ▼           ▼           ▼          ▼
 completed   cancelled    skipped    failed
```

- Reads `[transfer]` settings from `~/.macscp/config.toml` on startup
- On disconnect: `handleDisconnect()` fails queued jobs
- Each job gets its own `TransferCancellation` and `Task`
- Debounced pane refresh after batch completion

### 6.6 Overwrite Flow

```text
User action (upload/download/drop)
        │
        ▼
Detect name conflicts (local FS or remote listing)
        │
   conflicts? ──no──▶ enqueue with .overwrite
        │
       yes
        ▼
Show OverwritePromptView sheet
        │
   user choice: Overwrite All | Skip | Rename All | Cancel
        │
        ▼
enqueue jobs with matching OverwritePolicy
        │
        ▼
TransferDestinationResolver (backend) applies skip/rename/overwrite
```

---

## 7. SFTP Backend Internals

### 7.1 Shared SFTP Helpers (`MacSCPBackends/SFTP/`)

Both Citadel and Traversio backends share:

| Helper | Purpose |
|---|---|
| `SFTPPathResolver` | Normalize paths, resolve against session working directory |
| `SFTPDirectoryCache` | Session-scoped set of ensured remote directories |
| `SFTPUploadPlanner` | Parent directory extraction, local file size |
| `SFTPBatchUploadExecutor` | Concurrent batch upload with `@Sendable` upload closure |
| `TransferDestinationResolver` | Skip/rename/overwrite resolution |
| `SFTPErrorHelpers` | Already-exists detection for mkdir |
| `SFTPListingCache` | 3 s TTL cache for remote directory listings (Citadel + Traversio) |
| `CitadelTCPConnector` | Post-connect TCP buffer / Nagle tuning for Citadel |
| `SFTPBackendSelector` | Citadel vs Traversio selection + logging |
| `LocalFileSequentialReader` | mmap reads for large local files (Citadel upload) |
| `TransferBufferPool` | Reusable NIO `ByteBuffer` pool |
| `MacSCPHostKeySupport` | TOFU store at `~/.macscp/known_hosts.json` |
| `SSHAgentAuthSupport` | Traversio `SSHAgentClient` wrapper for agent auth |
| `SerializingTransferBackend` | Actor wrapper serializing backend calls |

### 7.2 Citadel (Default for Key/Password)

| Feature | Implementation |
|---|---|
| Small upload | Read whole file + single `withFile` write |
| Large upload | Open handle + sequential or **pipelined** writes |
| Pipelined writes | `CitadelPipelinedWriter` — sliding window of SFTP WRITE packets |
| Pipelined downloads | `CitadelPipelinedReader` when `maxConcurrentReads > 1` |
| Directory cache | `SFTPDirectoryCache` — dedupe `mkdir` per session |
| Listing cache | `SFTPListingCache` — 3 s TTL on `listDirectory` |
| TCP tuning | `CitadelTCPConnector` — preset-driven socket options after connect |
| Batch upload | `uploadBatch()` via `SFTPBatchUploadExecutor` |
| Download | Chunked read with resume; pipelined when configured |
| Cancel | Poll `TransferCancellation` in loops + pipelined I/O |
| Agent auth | Not supported directly — use Traversio backend |

### 7.3 Traversio (Agent Auth + Benchmarks)

- Native `SSHAgentClient` for `SSH_AUTH_SOCK` / ssh-agent identities
- `uploadFile` / `downloadFile` with built-in concurrent read/write
- `SFTPListingCache` on remote directory listings (same TTL as Citadel)
- Selected automatically when profile uses SSH agent authentication
- **AGPL-3.0** — legal review before wide distribution as default backend

### 7.4 Upload/Download Performance Strategy

See [SFTP backend spike](spikes/sftp-backend-spike.md) for benchmark numbers.

1. Shared directory cache (fewer round-trips)
2. Small-file single write; large files via mmap (`LocalFileSequentialReader`) + pipelined or chunked I/O
3. Concurrent batch uploads
4. Pipelined WRITE/READ requests per handle (Citadel)
5. Config-driven concurrency from `config.toml` presets
6. Connection pool (`PooledTransferBackend`) sized by `TransferPerformanceTuning.effectivePoolSize`
7. Remote listing cache (`SFTPListingCache`, 3 s TTL) to reduce repeated `listDirectory` round-trips
8. NIO buffer reuse (`TransferBufferPool`) on hot upload paths

### 7.5 Transfer Performance Tuning (`MacSCPCore`)

```text
config.toml [transfer] preset + overrides
        │
        ▼
MacSCPConfiguration.parseSettings / loadSettings
        │
        ├──▶ TransferPerformanceTuning.effectivePoolSize  → SessionCoordinator → PooledTransferBackend
        ├──▶ TransferPerformanceTuning.networkProfile(from:) → SessionConfiguration.networkProfile
        │         └──▶ CitadelTCPConnector (SO_SNDBUF, SO_RCVBUF, TCP_NODELAY)
        └──▶ TransferOptions from settings → backends (chunk size, concurrency, resume, checksums)
```

| Preset | Pool / chunks (typical) | Network profile | Notes |
|---|---|---|---|
| `default` | 2 connections, 1 MB chunks | `lan` | Intel first-launch default |
| `lan` | Higher concurrency, 2 MB chunks | `lan` | Wired LAN |
| `wan` | 1 connection, 256 KB chunks | `wan` | TCP_NODELAY off |
| `apple_silicon` | 2–4 connections (core-based), 2 MB chunks | `lan` | arm64 first-launch default |

Benchmark reports tag runs via `BenchmarkHostInfo.current()` (`architecture`, `processorCount`, `isAppleSilicon`, `networkProfile` from `MACSCP_BENCH_NETWORK`).

---

## 8. Concurrency Model

| Context | Isolation | Notes |
|---|---|---|
| UI / `AppModel` + coordinators | `@MainActor` | Swift Observation for reactive UI |
| `TransferQueue` | `@MainActor` | Spawns `Task` per job for backend I/O |
| `TransferBackend` | `Sendable` class | `@unchecked Sendable` on concrete backends |
| `SerializingTransferBackend` | `actor` | Wraps backend for serialized access from queue |
| `TransferCancellation` | `@unchecked Sendable` | NSLock-protected flag |
| `SFTPListingCache` | `actor` | 3 s TTL remote listing cache |
| Citadel pipelined I/O | Task pool | Read/write coordinators wrap SFTP file handle |
| Local directory scan | `Task.detached` | `TransferCoordinator` expands large local trees off main actor |

**Cancellation path:** UI cancel → `TransferCancellation.cancel()` + `Task.cancel()` → backend throws `BackendError.cancelled` → queue marks job **Cancelled**. Disconnect calls `handleDisconnect()` on the queue.

---

## 9. Data Persistence

| Data | Location | Format |
|---|---|---|
| Session profiles | `~/Library/Application Support/MacSCP/profiles.json` | JSON (`SessionProfile`, mode 600) |
| Passwords | macOS Keychain | Per-profile UUID service |
| Application config | `~/.macscp/config.toml` | TOML (`[logging]`, `[transfer]`) |
| Application logs | `~/.macscp/logs/macscp-YYYY-MM-DD.log` | Text (daily rotation) |
| Known host keys | `~/.macscp/known_hosts.json` | JSON (TOFU fingerprints) |
| Test server keys | `.benchmark/keys/` | Ed25519 key pairs |

---

## 10. Benchmark Harness

```bash
make bench              # quick suite
make bench-full         # 1 MB / 100 MB / 1 GB, 10k files
make bench-apple-silicon
make bench-verify       # bench-apple-silicon + pass-criteria check
make bench-upload-spike # Citadel vs Traversio vs OpenSSH
make ci                 # check + bench-verify (local CI parity)
# or
./scripts/benchmark-env.sh start
./scripts/run-benchmarks.sh [--verify]
./scripts/ci-local.sh
```

Environment variables: `MACSCP_BENCH_FULL`, `MACSCP_BENCH_NETWORK` (`loopback` | `lan` | `wifi` | `wan`), `MACSCP_BENCH_HOST`, `MACSCP_BENCH_PORT`.

Reports: `.benchmark/benchmark-results/report.json` (includes `hostInfo` on Apple Silicon runs).

Scenarios: large upload/download, small-file batch, list directory, resume, encrypted key auth.

Pass criteria (spec): ≥ 90% OpenSSH throughput (large files); ≥ 80% (small files). CI verifies via `./scripts/verify-benchmark-report.sh` on GitHub Actions `macos-15`.

---

## 11. Testing Strategy

| Suite | Coverage |
|---|---|
| `MacSCPCoreTests` | Session defaults, `networkProfile`, checksum |
| `MacSCPConfigurationTests` | TOML parsing, presets (`lan`/`wan`/`apple_silicon`), first-launch arm64 defaults, Traversio perf flag |
| `MacSCPLoggerTests` | Bootstrap, log files, level filtering |
| `DirectoryTransferPlannerTests` | Local tree expansion, path join, mkdir |
| `TransferCancellationTests` | Cancel token, continuation factory |
| `PaneTransferRulesTests` | Cross-pane drop acceptance, payload JSON |
| `TransferOverwriteTests` | Path rename, batch conflict detection |
| `TransferDestinationResolverTests` | Skip/rename/overwrite resolution |
| `TransferQueueTests` | Cancel, disconnect, skip policy (mock backend) |
| `SFTPAttributeMappingTests` | Permission → entry type |
| `StreamingChecksumTests` | Incremental SHA-256 vs one-shot and file reads |
| `TransferPerformanceTuningTests` | Presets, TCP buffers, pool sizing, env network profile |
| `SFTPBackendSelectorTests` | Citadel vs Traversio routing |
| `SFTPListingCacheTests` | Store, invalidate, TTL expiry |
| `LocalFileReaderTests` | Small-file reads, mmap path, past-end |
| `TransferBufferPoolTests` | NIO `ByteBuffer` borrow/recycle |
| `BenchmarkHostInfoTests` | Host metadata in benchmark JSON |
| `SFTPErrorHelpersTests` | Already-exists detection |

Run: `make test` or `swift test` (**79** XCTest + **3** Swift Testing = **82** total). CI entry point: `make check`.

---

## 12. Roadmap vs Current State

| Spec feature | Phase | Status |
|---|---|---|
| Session login + profiles | 0 | Done |
| Dual-pane commander | 0–1 | Done |
| Upload / download | 1 | Done |
| Recursive directory transfer | 1 | Done |
| Transfer queue + progress | 1 | Done |
| Mid-transfer cancel | 1 | Done |
| Drag-and-drop (files + folders) | 1 | Done |
| Overwrite prompts | 1 | Done |
| Keychain passwords | 1 | Done |
| Host key TOFU store | 1 | Done (prompt UI pending) |
| Configurable logging + transfer tuning | 1 | Done |
| Apple Silicon preset + performance layer | 1 | Done |
| CI benchmarks (macos-15) | 1 | Done |
| SSH agent auth | 1 | Done (Traversio backend) |
| AppModel coordinator decomposition | 1 | Done |
| Directory sync / mirror | 2 | Not started |
| Remote editor | 2 | Not started |
| CLI (`macscp`) | 2 | Spec only |
| Tabs, Quick Look | 2+ | Not started |

---

## 13. Security Considerations

| Topic | Current | Target |
|---|---|---|
| Host key verification | TOFU JSON store + optional fingerprint pin | User prompt UI |
| Credentials | Keychain for passwords; key paths in profile JSON | Passphrase in Keychain |
| Profile file permissions | `chmod 600` on save | — |
| App Sandbox | Not enabled | Security-scoped bookmarks |
| AGPL backend | Traversio for agent + benchmarks | Legal review before default ship |

---

## 14. Extension Points

1. **New protocol** — implement `TransferBackend`, register in factory
2. **Backend preference** — expose Citadel vs Traversio in settings (today: auto by auth method)
3. **CLI** — reuse `MacSCPCore` + coordinators or headless runner
4. **Sync engine** — directory diff on top of `DirectoryTransferPlanner` + queue

---

## 15. References

- [Product specification](spec.md)
- [User guide](user-guide.md)
- [Code walkthrough](code-walkthrough.md)
- [Apple Silicon performance](apple-silicon-performance.md)
- [TransferBackend protocol](transfer-backend.md)
- [CLI reference](cli-reference.md) (planned)
- [SFTP backend spike](spikes/sftp-backend-spike.md)

---

*End of HLD v0.3*
