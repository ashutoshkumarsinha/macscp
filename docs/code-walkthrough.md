# MacSCP Code Walkthrough (Beginner)

This guide explains **how the code is organized** and **how data flows** when you use MacSCP. Read it alongside the source files.

> **Note on comments in source files:** We add comments on important lines and sections, not on every `{` or `}`. Commenting every single line makes code harder to read and is not standard practice—even in teaching projects.

---

## 1. Where to start

| If you want to learn… | Open this file first |
|---|---|
| How the app launches | `Sources/MacSCPApp/MacSCPApp.swift` |
| App state (facade) | `Sources/MacSCPApp/AppModel.swift` |
| Profile / session / transfer logic | `Sources/MacSCPApp/Coordinators/*.swift` |
| Dual-pane UI | `Sources/MacSCPApp/Views/CommanderView.swift` |
| Login screen | `Sources/MacSCPApp/Views/SessionLoginView.swift` |
| Background transfers | `Sources/MacSCPUI/TransferQueue.swift` |
| Directory tree expansion | `Sources/MacSCPCore/DirectoryTransferPlanner.swift` |
| Config + logging | `Sources/MacSCPCore/MacSCPConfiguration.swift`, `MacSCPLogger.swift` |
| “What is SFTP?” contract | `Sources/MacSCPCore/TransferBackend.swift` |
| Real SFTP network code | `Sources/MacSCPBackends/SFTP/CitadelSFTPBackend.swift` |
| Shared backend helpers | `Sources/MacSCPBackends/SFTP/SFTPPathResolver.swift`, etc. |

---

## 2. Module map

```text
MacSCPApp     → SwiftUI screens + coordinators (what the user sees)
MacSCPUI      → Transfer queue (works without SwiftUI views)
MacSCPCore    → Shared types and protocols (no UI, no network)
MacSCPBackends→ Talks to Citadel/Traversio SFTP libraries
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
   - `true` → show commander (dual pane)
5. `.environment(appModel)` passes state to child views.

---

## 4. Connect flow

1. User fills login form → `SessionProfileDraft` (auth: key file, password, or SSH agent).
2. User clicks Login → `AppModel.connect()` → `SessionCoordinator.connect(using:)`.
3. Backend selection:
   - **Key / password** → `TransferBackendFactory.make(..., backend: .citadel)`
   - **SSH agent** → `.traversio` (uses `SSHAgentClient` / `SSH_AUTH_SOCK`)
4. `SessionConnectionService.connect` calls `backend.connect(configuration:)`.
5. On success: `isConnected = true`, `RemotePaneCoordinator.refreshRemote(...)`.

---

## 5. Transfer flow

1. User selects files/folders and clicks Upload (or drags local → remote).
2. `TransferCoordinator` expands directories via `DirectoryTransferPlanner` when needed.
3. Conflict check → may show overwrite sheet (`OverwritePromptView`).
4. `TransferQueue.enqueueUpload(...)` or `enqueueUploadBatch(...)` adds job(s).
5. Queue processor picks queued jobs (concurrency from `config.toml` `[transfer]`).
6. Each job gets a `TransferCancellation` token (for Cancel button).
7. Calls `backend.upload(...)` with progress callback.
8. UI updates progress bar from callback on `@MainActor`.
9. After batch completes, panes refresh (debounced).

---

## 6. Coordinator map

`AppModel` forwards state; coordinators own behavior:

| File | Role |
|---|---|
| `ProfileCoordinator.swift` | Profiles JSON, draft, save/delete, Keychain passwords |
| `SessionCoordinator.swift` | Connect/disconnect, backend instance, backend kind |
| `LocalPaneCoordinator.swift` | Local path, listing, selection |
| `RemotePaneCoordinator.swift` | Remote listing, selection, refresh |
| `TransferCoordinator.swift` | Upload/download/drop, overwrite batch, queue |

---

## 7. Key Swift concepts used

| Concept | Where | Meaning |
|---|---|---|
| `async` / `await` | Backends, coordinators | Wait for network without freezing UI |
| `@MainActor` | AppModel, coordinators, TransferQueue | UI state must update on main thread |
| `@Observable` | AppModel, coordinators | SwiftUI auto-refreshes when properties change |
| `protocol` | TransferBackend | Interface any SFTP library must implement |
| `Task { }` | TransferQueue | Run work in background |
| `Sendable` | Core types | Safe to pass between threads |

---

## 8. SFTP backend shared code

Both `CitadelSFTPBackend` and `TraversioSFTPBackend` use:

- `SFTPPathResolver` — path normalization
- `SFTPDirectoryCache` — avoid redundant mkdir
- `SFTPUploadPlanner` — parent dir + file size
- `SFTPBatchUploadExecutor` — parallel file uploads
- `CitadelPipelinedWriter` / `CitadelPipelinedReader` — Citadel-only pipelined I/O

---

## 9. Running and testing

```bash
make build    # compile
make test     # 42 tests (39 XCTest + 3 Swift Testing)
make run      # start test server + open app
make paths    # show config/log/profile paths
make logs     # tail today's log
```

Tests live in `Tests/MacSCPTests/` — read them to see expected behavior.

Local SFTP fixture: `./scripts/benchmark-env.sh start` (port 2222, keys in `.benchmark/keys/`).

---

*For product features see [user-guide.md](user-guide.md). For architecture see [hld.md](hld.md).*
