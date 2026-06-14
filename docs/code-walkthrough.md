# MacSCP Code Walkthrough (Beginner)

This guide explains **how the code is organized** and **how data flows** when you use MacSCP. Read it alongside the source files.

> **Note on comments in source files:** Each Swift file begins with a `WHAT THIS FILE DOES` header (filename, purpose, key callers). Shell scripts and the Makefile use section headers the same way. We do not comment every line — that would hurt readability.

---

## 1. Where to start

| If you want to learn… | Open this file first |
|---|---|
| How the app launches | `Sources/MacSCPApp/MacSCPApp.swift` |
| App state (facade) | `Sources/MacSCPApp/AppModel.swift` |
| Profile / session / transfer logic | `Sources/MacSCPApp/Coordinators/*.swift` |
| Multi-session tabs | `Sources/MacSCPApp/Coordinators/SessionTabWorkspace.swift` |
| Dual-pane UI | `Sources/MacSCPApp/Views/CommanderView.swift` |
| Login screen + proxy fields | `Sources/MacSCPApp/Views/SessionLoginView.swift` |
| OpenSSH config merge | `Sources/MacSCPCore/OpenSSHConfigParser.swift`, `SessionConfiguration+OpenSSH.swift` |
| Traversio ProxyJump wiring | `Sources/MacSCPBackends/SFTP/TraversioSSHConfigurationBuilder.swift` |
| Background transfers | `Sources/MacSCPUI/TransferQueue.swift` |
| Directory tree expansion | `Sources/MacSCPCore/DirectoryTransferPlanner.swift` |
| Bidirectional sync | `Sources/MacSCPCore/DirectorySyncEngine.swift` |
| Config + logging | `Sources/MacSCPCore/MacSCPConfiguration.swift`, `MacSCPLogger.swift` |
| CLI entry | `Sources/MacSCPCLI/MacSCPCLIMain.swift`, `CLIActions.swift` |
| Transfer presets / TCP tuning | `Sources/MacSCPCore/TransferPerformanceTuning.swift` |
| Apple Silicon performance | [apple-silicon-performance.md](apple-silicon-performance.md) + files in §10 below |
| “What is SFTP?” contract | `Sources/MacSCPCore/TransferBackend.swift` |
| Real SFTP network code | `Sources/MacSCPBackends/SFTP/CitadelSFTPBackend.swift` |
| Shared backend helpers | `Sources/MacSCPBackends/SFTP/SFTPPathResolver.swift`, etc. |

---

## 2. Module map

```text
MacSCPApp     → SwiftUI screens + coordinators (what the user sees)
MacSCPUI      → Transfer queue (works without SwiftUI views)
MacSCPCore    → Shared types and protocols (no UI, no network)
MacSCPBackends→ Talks to Citadel/Traversio SFTP libraries + cloud/FTP backends
MacSCPCLI     → macscp-cli scriptable client
MacSCPBenchmark→ Command-line speed tests
```

**Rule:** UI never imports Citadel directly. It always goes through `TransferBackend`.

---

## 3. Launch flow

1. `@main struct MacSCPApp` — Swift entry point (like `main()` in other languages).
2. `MacSCPLogger.shared.bootstrap()` — creates `~/.macscp/config.toml` if missing.
3. Creates one `AppModel` — facade over coordinators.
4. `RootView` checks `appModel.isConnected`:
   - `false` → show login
   - `true` → show commander (dual pane) or explorer layout
5. `.environment(appModel)` passes state to child views.

---

## 4. Connect flow

1. User fills login form → `SessionProfileDraft` (auth: key file, password, SSH agent, optional proxy).
2. User clicks Login → `AppModel.connect()` → `SessionCoordinator.connect(using:)`.
3. `configuredSession` builds `SessionConfiguration`, applies transfer **preset** → `networkProfile`, then **`mergeOpenSSHConfig()`** (reads `~/.ssh/config` for HostName, ProxyJump, etc.).
4. **Backend selection** (`SFTPBackendSelector`):
   - **SSH agent** → Traversio
   - **Any proxy** (HTTP, SOCKS5, jump) → Traversio
   - **`use_traversio_for_performance = true`** → Traversio (optional max-throughput mode, AGPL)
   - **Otherwise** → Citadel (default for key/password without proxy)
5. **Pool size** (`TransferPerformanceTuning.effectivePoolSize`):
   - `apple_silicon` on arm64 → several parallel SSH connections (`PooledTransferBackend`)
   - Otherwise → usually one connection (`max_concurrent_transfers` from config)
6. `SessionConnectionService.connect` calls `backend.connect(configuration:)`.
   - Citadel path uses `CitadelTCPConnector` (SSH + TCP buffer tuning).
   - Traversio path uses `TraversioSSHConfigurationBuilder` (ProxyJump hops, HTTP/SOCKS proxy).
7. On success: `isConnected = true`, `RemotePaneCoordinator.refreshRemote(...)`.

```text
Login form → SessionCoordinator → mergeOpenSSHConfig → SFTPBackendSelector → PooledTransferBackend?
                                      ↓
                              CitadelTCPConnector or TraversioSSHConfigurationBuilder
                                      ↓
                              SFTP open → commander / explorer UI
```

---

## 5. Transfer flow (upload)

1. User selects local files → clicks Upload (or drag to remote pane).
2. `TransferCoordinator.enqueueUpload` → if folder, `DirectoryTransferPlanner.expandLocalDirectory` on detached task.
3. Overwrite conflicts → `OverwritePromptView` if needed.
4. Jobs enqueued on `TransferQueue` with `TransferOptions` from config.
5. Queue picks backend from `AppModel` (via `TransferBackendProvider`).
6. `backend.upload(localURL:remotePath:options:)` — Citadel or Traversio SFTP path.
7. Progress callbacks update queue UI; cancel via `TransferCancellation`.

---

## 6. Coordinator map

| Coordinator | Owns |
|---|---|
| `ProfileCoordinator` | Saved profiles, draft form, Keychain |
| `SessionCoordinator` | Connect/disconnect, backend, OpenSSH merge |
| `SessionTabWorkspace` | Per-tab session state |
| `LocalPaneCoordinator` | Local path, listing, selection |
| `RemotePaneCoordinator` | Remote listing, selection, refresh |
| `TransferCoordinator` | Upload/download/drop, queue binding |
| `SyncCoordinator` | Directory compare + sync (one-way and bidirectional) |
| `FileOperationsCoordinator` | Rename, delete, mkdir, chmod |

---

## 7. Swift concepts used

| Concept | Where | Why |
|---|---|---|
| `@Observable` | AppModel, coordinators | SwiftUI auto-refreshes when properties change |
| `protocol` | TransferBackend | Interface any SFTP library must implement |
| `Task { }` | TransferQueue | Run work in background |
| `Sendable` | Core types | Safe to pass between threads |
| `actor` | SFTPListingCache, CLISessionStore | One task at a time inside the cache/store |
| `Task.detached` | TransferCoordinator | Heavy directory scan off main thread |

---

## 8. SFTP backend shared code

Both `CitadelSFTPBackend` and `TraversioSFTPBackend` use:

- `SFTPPathResolver` — path normalization
- `SFTPDirectoryCache` — avoid redundant mkdir
- `SFTPListingCache` — 3 s cache for remote directory listings (both backends)
- `SFTPUploadPlanner` — parent dir + file size
- `SFTPBatchUploadExecutor` — parallel file uploads
- `TraversioSSHConfigurationBuilder` — Traversio-only: auth, host key policy, ProxyJump, HTTP/SOCKS
- `CitadelPipelinedWriter` / `CitadelPipelinedReader` — Citadel-only pipelined I/O
- `LocalFileSequentialReader` — mmap reads for large local files (Citadel upload)
- `TransferBufferPool` — reuse NIO buffers between chunks
- `StreamingSHA256` — checksum while uploading (optional, config flag)
- `CitadelTCPConnector` — Citadel-only TCP socket tuning after connect
- `SFTPBackendSelector` — Citadel vs Traversio choice (used by app + CLI, not inside backends)

---

## 9. Performance layer (Apple Silicon)

Read these files in order if you are new to the performance work:

| Order | File | One-line purpose |
|---|---|---|
| 1 | `MacSCPCore/TransferPerformanceTuning.swift` | Presets → numbers (pool size, TCP buffers) |
| 2 | `MacSCPCore/MacSCPConfiguration.swift` | Parses `config.toml`; first arm64 launch → `apple_silicon` |
| 3 | `MacSCPBackends/SFTP/SFTPBackendSelector.swift` | Pick Citadel or Traversio |
| 4 | `MacSCPBackends/SFTP/CitadelTCPConnector.swift` | SSH connect + socket options |
| 5 | `MacSCPBackends/SFTP/LocalFileReader.swift` | Fast local disk reads |
| 6 | `MacSCPBackends/SFTP/TransferBufferPool.swift` | Reuse upload buffers |
| 7 | `MacSCPBackends/SFTP/SFTPListingCache.swift` | Cache remote folder listings |
| 8 | `MacSCPCore/StreamingChecksum.swift` | SHA-256 during upload |
| 9 | `MacSCPBackends/SFTP/PooledTransferBackend.swift` | Multiple SFTP connections |
| 10 | `MacSCPBenchmark/BenchmarkHostInfo.swift` | Machine info in benchmark JSON |

**Config presets** (`~/.macscp/config.toml`):

| preset | When to use |
|---|---|
| `default` | Generic; no extra tuning |
| `lan` | Fast local network |
| `wan` | High latency; smaller chunks and buffers |
| `apple_silicon` | M-series Macs; pool + 2 MB chunks + 24 upload workers |

See [apple-silicon-performance.md](apple-silicon-performance.md) for benchmarks and CI.

---

## 10. Running and testing

```bash
make build    # compile
make test     # 144 XCTest + 3 Swift Testing
make check    # build + test
make ci         # check + bench-verify (matches GitHub Actions)
make run      # start test server + open app
make paths    # show config/log/profile paths
make logs     # tail today's log
make bench-verify
```

Tests live in `Tests/MacSCPTests/` — read them to see expected behavior. Notable suites: `OpenSSHConfigParserTests`, `TraversioSSHConfigurationBuilderTests`, `DirectorySyncEngineTests`.

Local SFTP fixture: `./scripts/benchmark-env.sh start` (port 2222, keys in `.benchmark/keys/`).

See [Apple Silicon Performance Guide](apple-silicon-performance.md) for presets, benchmarks, and CI scripts.

---

*For product features see [user-guide.md](user-guide.md). For architecture see [hld.md](hld.md).*
