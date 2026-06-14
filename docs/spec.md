# MacSCP — Product Specification

An open-source, WinSCP-inspired file transfer client rebuilt from the ground up for macOS. MacSCP brings dual-pane utility, session management, and robust automation to Apple Silicon Macs using native Swift, AppKit/SwiftUI, and macOS system integrations.

---

## Document Status

| Field | Value |
|---|---|
| Version | 0.3 (draft) |
| Status | Phase 0–4 largely implemented; v0.3 developer preview (SFTP MVP + cloud + parity features) |
| Target OS | macOS 15 Sequoia minimum; macOS 26 Tahoe primary |
| Architecture | Apple Silicon native (arm64); Intel best-effort via Rosetta where feasible |
| Language | Swift 6 |
| License | MIT (see [LICENSE](../LICENSE)) |
| Inspiration | [WinSCP](https://winscp.net/) — feature parity where sensible, macOS-native UX everywhere else |

### Related Documents

| Document | Path |
|---|---|
| Documentation index | [README.md](README.md) |
| High-level design | [hld.md](hld.md) |
| User guide | [user-guide.md](user-guide.md) |
| Code walkthrough | [code-walkthrough.md](code-walkthrough.md) |
| Apple Silicon performance | [apple-silicon-performance.md](apple-silicon-performance.md) |
| SFTP backend spike | [spikes/sftp-backend-spike.md](spikes/sftp-backend-spike.md) |
| CLI reference | [cli-reference.md](cli-reference.md) |
| Scripting guide | [scripting.md](scripting.md) |
| TransferBackend protocol | [transfer-backend.md](transfer-backend.md) |

---

## Executive Summary

MacSCP fills the gap left by WinSCP being Windows-only. macOS users currently choose between polished but closed clients (Transmit, ForkLift) and cross-platform tools with dated UX (FileZilla, Cyberduck). MacSCP targets **power users, sysadmins, and developers** who need WinSCP-grade automation and protocol breadth in a client that feels at home on macOS.

### Core Value Propositions

1. **WinSCP-class capability** — dual-pane transfers, directory sync, remote editing, scripting.
2. **Native macOS experience** — tabs, Quick Look, Keychain, Shortcuts, SF Symbols, HIG-compliant layouts.
3. **Open source & extensible** — no connection limits, no adware, community-driven protocol and integration plugins.

### Non-Goals (v1)

- Windows or Linux ports
- Full managed file transfer (MFT) enterprise features (audit trails, compliance reporting, role-based admin console)
- Replacing dedicated S3/cloud consoles for bucket lifecycle management
- Built-in VPN or SSH tunnel configuration UI (defer; link to system SSH config)
- Real-time collaborative editing of remote files

---

## User Personas

| Persona | Needs | MacSCP Features |
|---|---|---|
| **Sysadmin** | Reliable SFTP/SCP, terminal hand-off, host key trust, batch ops | Sessions, sync, CLI, chmod/chown |
| **Web Developer** | Quick config edits, live sync to staging, drag-and-drop deploys | Remote editor, live sync, external editor mapping |
| **DevOps Engineer** | Scriptable transfers in CI/CD, S3 artifacts, idempotent sync | `macscp` CLI, Shortcuts, JSON session export |
| **Homelab User** | Saved Raspberry Pi / NAS profiles, Keychain passwords | Session sidebar, Touch ID lock, SSH keys |

---

## Success Metrics

| Metric | Target (GA) | Current (Phase 1) |
|---|---|---|
| SFTP transfer throughput | ≥ 90% of `sftp` CLI on same network | CI gate: large upload ≥ 0.90× OpenSSH; small upload ≥ 0.80× on loopback (`verify-benchmark-report.sh`) |
| Cold launch to connected dual-pane | < 3 s (cached session) | Not measured |
| Crash-free sessions | > 99.5% | Not measured |
| Keychain credential retrieval | < 100 ms | Not measured |
| CLI script compatibility | Documented subset of WinSCP scripting verbs | **Shipped:** full verb set (open/close/ls/get/put/sync/cd/lcd/pwd/rm/mkdir/mv/chmod/call/script); see [cli-reference.md](cli-reference.md) |
| Unit test coverage (core/backends) | All critical transfer paths covered | **144** XCTest cases + **3** Swift Testing cases (`make check`) |

---

## 1. User Interface & Experience (UI/UX)

MacSCP bridges functional density and macOS elegance. Default layout is **Commander** (dual-pane); optional **Explorer** mode (single remote tree + local integration) is available in the connection form.

### 1.1 Dual-Pane Commander (Primary)

- **Left pane:** local filesystem rooted at user-selected directory (defaults to `$HOME` or last-used path).
- **Right pane:** remote directory for active session.
- **Unified toolbar:** back/forward, up, refresh, new folder, delete, properties, sync, terminal, search.
- **Status bar:** transfer queue summary, connection latency, protocol badge, encryption indicator.
- **Column view option:** Name, Size, Modified, Permissions, Owner/Group (remote), Kind (local).

### 1.2 Tabs & Windows

- Native macOS tab bar: multiple server connections per window (`⌘T` new tab, `⌘W` close tab).
- Detach tab to new window; merge windows via drag.
- Tab state persists across app relaunch (optional preference).

### 1.3 Quick Look Integration

- **Spacebar** on selected remote file: stream to temp cache and invoke `QLPreviewPanel`.
- Supported without full download: images, PDF, plain text, common code formats (< 10 MB default cap; configurable).
- Unsupported/binary large files: offer download or open with default app.

### 1.4 Drag-and-Drop

- Local → remote: upload with overwrite/skip/rename prompt policy.
- Remote → local: download to drop target.
- Remote → remote (same session): server-side copy when protocol supports; otherwise stream through client.
- **Spring-loaded folders** and **badge progress** on pane headers during multi-file drops.

### 1.5 Context Menus & Actions

- Copy, Move, Rename, Duplicate, Delete, Get Info, Copy URL (`sftp://user@host/path`).
- **Permissions sheet** (remote): chmod numeric/symbolic, chown where supported.
- **Create symlink** (SFTP/SSH) where server allows.

### 1.6 Accessibility & Localization

- Full VoiceOver labels on panes, transfer queue, and session list.
- Keyboard navigation: arrow keys, `⌘↑` parent, `⌘↓` enter, type-ahead search.
- Dynamic Type / system font scaling respected.
- v1 English; strings externalized for community localization.

---

## 2. Core Protocol Support

All protocol implementations live behind a shared **`TransferBackend`** protocol (see §7). UI and automation layers never speak raw protocol details.

| Protocol | Priority | Notes |
|---|---|---|
| **SFTP** | P0 (MVP) | **Shipped:** [Citadel](https://github.com/orlandos-nl/Citadel) (NIOSSH + SFTP v3) for key/password; [Traversio](https://github.com/GitSwiftHQ/Traversio) for SSH agent and optional max-throughput mode (AGPL — legal review before default) |
| **SCP** | P1 | Legacy one-shot copies; prefer SFTP for interactive use |
| **FTP** | P1 | Active/passive mode, MLSD, UTF-8 |
| **FTPS** | P1 | Explicit (AUTH TLS) and implicit TLS |
| **WebDAV** | P2 | HTTPS, PROPFIND, large-file streaming; benchmark buffer sizes |
| **Amazon S3** | P2 | SigV4, regions, prefixes, multipart upload |
| **Google Cloud Storage** | P3 | S3-compatible API or native JSON API |

### 2.1 Connection Features (All Protocols)

- Proxy: HTTP CONNECT, SOCKS5, SSH jump host (`ProxyJump` from OpenSSH config).
- Timeout, keep-alive, and auto-reconnect with exponential backoff.
- **Host key / certificate verification** with trust-on-first-use (TOFU) store and fingerprint display.
- Resume interrupted transfers (offset resume for SFTP; REST for FTP where supported).
- Concurrent transfer workers (default from `config.toml`; presets tune pool size, pipelined reads/writes, and batch uploads).
- **Transfer performance presets** (`default`, `lan`, `wan`, `apple_silicon`) in `~/.macscp/config.toml` — see §2.3.
- **Backend selection:** Citadel for key/password by default; Traversio when auth method is SSH agent, when any **proxy** is configured (HTTP, SOCKS5, ProxyJump), or when `use_traversio_for_performance = true`.
- **OpenSSH config:** At connect, merge `~/.ssh/config` Host blocks (HostName, Port, User, IdentityFile, ProxyJump). Profile proxy fields override config. CLI: `--rawsettings ProxyJump=…`.
- **TCP tuning (Citadel):** post-connect `SO_SNDBUF`, `SO_RCVBUF`, and `TCP_NODELAY` derived from active preset / network profile.
- **Listing cache:** 3 s TTL on remote directory listings (Citadel and Traversio).
- **Optional streaming checksums** during upload when `verify_checksums = true`.

### 2.3 Application Configuration (`~/.macscp/config.toml`)

Global tuning and logging live outside session profiles. First launch on Apple Silicon writes `preset = "apple_silicon"` automatically; Intel Macs get `preset = "default"`.

```toml
[logging]
enabled = true
level = "debug"
retention_days = 14
mirror_stderr = false

[transfer]
preset = "default"                    # default | lan | wan | apple_silicon
max_concurrent_transfers = 2          # SSH connection pool size (elevated by apple_silicon on arm64)
max_concurrent_writes = 16
max_concurrent_reads = 8
max_concurrent_uploads = 12
chunk_size = 1048576                  # bytes; apple_silicon uses 2097152
resume = true
verify_checksums = false
use_traversio_for_performance = false # optional Traversio for key/password (AGPL)
```

| Preset | Intended use | Key defaults |
|---|---|---|
| `default` | General / Intel Mac | 1 MB chunks, modest concurrency |
| `lan` | Fast wired LAN | Higher concurrency, 2 MB chunks |
| `wan` | High-latency internet | Smaller chunks, single connection pool, TCP_NODELAY off |
| `apple_silicon` | M-series Mac (auto on first arm64 launch) | Pool sized to performance cores (2–4), 2 MB chunks, 24 upload workers |

Explicit keys in `[transfer]` override preset values. See [apple-silicon-performance.md](apple-silicon-performance.md) and [user-guide.md](user-guide.md) §5.4.

**Benchmark environment:** `MACSCP_BENCH_NETWORK` (`loopback` | `lan` | `wifi` | `wan`) tags `macscp-benchmark` reports via `BenchmarkHostInfo` in `MacSCPCore`.

### 2.2 Session Profile Schema

Each saved session stores (Keychain holds secrets):

```yaml
id: UUID
name: string
group: string | null          # sidebar folder
protocol: sftp | scp | ftp | ftps | webdav | s3 | gcs
host: string
port: int
username: string
auth_method: password | publickey | agent | interactive
key_path: string | null       # path reference only; passphrase in Keychain
keychain_account: string      # lookup key for password/passphrase
advanced:
  proxy_type: none | http | socks5 | jump
  proxy_host: string | null
  compression: bool
  preferred_kex: string | null
  host_key_fingerprint: string | null
  remote_path: string         # initial cwd
  encoding: utf8 | legacy
tags: [string]
favorite: bool
last_connected: ISO8601 | null
```

Profiles export/import as `.macscp` bundle (JSON + optional encrypted secrets).

---

## 3. Advanced Features

### 3.1 Terminal & Keychain Integration

- **Terminal hand-off:** toolbar button opens Terminal.app or iTerm2 (user preference) with:
  ```bash
  ssh -i <key> user@host -t 'cd /remote/path && exec $SHELL'
  ```
  Respects `~/.ssh/config` `Host` aliases when session is linked to a config entry.
- **SSH agent:** integrate with macOS ssh-agent and 1Password SSH agent.
- **Secure storage:** passwords, passphrases, and session tokens in Keychain (`kSecAttrAccessibleWhenUnlocked` default; optional `AfterFirstUnlock` for background sync).
- **Master password option:** encrypt exported session bundles; distinct from Keychain item protection.

### 3.2 Directory Synchronization

| Mode | Behavior |
|---|---|
| **Mirror local → remote** | Upload new/changed; optional delete extraneous remote files |
| **Mirror remote → local** | Download new/changed; optional delete extraneous local files |
| **Bidirectional** | Newer-wins or prompt per conflict |
| **Live sync (watch)** | FSEvents on local folder → debounced upload queue (WinSCP "Keep Remote Directory Up To Date") |

- **Compare directories:** side-by-side diff view — missing, newer, size mismatch, permission mismatch; color-coded rows.
- **Dry run:** preview actions before execution.
- **Filters:** include/exclude globs, min/max size, modified-since.

### 3.3 Remote Editing

- **Internal editor:** lightweight `NSTextView` / SwiftUI text editor with syntax highlighting (Tree-sitter or Highlight.js equivalent via native port); line numbers, encoding selector (UTF-8, Latin-1), line ending conversion (LF/CRLF).
- **External editor mapping:** per extension or global default (VS Code, Cursor, BBEdit, etc.).
  1. Download to `~/Library/Caches/MacSCP/edit/<session-id>/…`
  2. Watch file with `FSEvents` or `DispatchSource`
  3. On save, upload and optionally verify checksum
  4. Clean temp on editor close or session disconnect (configurable)
- **Conflict policy:** if remote changed while editing locally, prompt: overwrite, merge, compare.

### 3.4 Transfer Queue

- Background queue with pause, resume, cancel, retry failed.
- Per-file progress: bytes, speed, ETA, protocol operation (upload/download/checksum).
- **Global concurrency limit** separate from per-folder sync workers.
- Notification Center alert on queue completion (optional).

---

## 4. Automation & Scripting

### 4.1 CLI (`macscp`)

Installed at `/usr/local/bin/macscp` or via Homebrew cask formula. Shares session store with GUI.

```bash
# Examples (target syntax — align toward WinSCP scripting familiarity)
macscp open sftp://user@host/path -session="Production Web API"
macscp get /remote/file.txt ./local/
macscp put ./local/* /remote/dir/
macscp sync local/ /remote/dir/ -mirror -delete
macscp ls /remote/dir/
macscp call chmod 644 /remote/file.txt
macscp script deploy.macscp
```

| Requirement | Detail |
|---|---|
| Exit codes | 0 success; 1 usage; 2 connection; 3 transfer; 4 auth; 10 partial |
| Output formats | human (default), `--json` for automation (`ls`/`stat`/`version` objects; `get`/`put`/`sync` NDJSON events) |
| Config isolation | `--ini /dev/null` equivalent: no GUI prefs side effects |
| Host key automation | `--hostkey=fingerprint` for CI (explicit opt-in) |

### 4.2 Script Files (`.macscp`)

Line-oriented command files with `#` comments, `open`, `get`, `put`, `sync`, `option`, `call`, `exit`. Document mapping from [WinSCP scripting](https://winscp.net/eng/docs/scripting) commands.

### 4.3 Shortcuts & System Integration

- **Shortcuts actions:** Connect to Session, Upload File, Download File, Sync Directories, Run Script.
- **AppleScript / JXA:** basic suite — `connect`, `disconnect`, `upload`, `download` (P2).
- **URL scheme:** `macscp://open?session=<uuid>` and `sftp://user@host/path` handler registration.
- **Finder Sync Extension (P2):** badge synced folders; context menu "Upload to MacSCP Session…".

---

## 5. Security & Privacy

| Control | Implementation |
|---|---|
| **Touch ID / Apple Watch** | Optional lock on app launch or session reveal |
| **Host key trust store** | SQLite + Keychain-backed trust decisions; warn on change |
| **SSH keys** | OpenSSH formats: RSA, ECDSA, Ed25519, `.pem`, PKCS#8; encrypted keys with passphrase in Keychain |
| **Certificate pinning** | FTPS/WebDAV: trust store or custom CA import |
| **App Sandbox** | Enabled where compatible; security-scoped bookmarks for user-granted folders |
| **Telemetry** | Off by default; optional anonymous crash reports (Sentry OSS or none) |
| **Network** | No relay servers; direct client-to-host only |

---

## 6. Screen Designs

### 6.1 Session Login / Profile Editor

Classic source-list sidebar (groups + saved sessions) and dense detail panel. Follows macOS HIG.

```text
+-----------------------------------------------------------------------------------+
| 🪟 MacSCP — New Connection                                                        |
+------------------------------------+----------------------------------------------+
| 🔍 Search Profiles                 |  Protocol:  [ SFTP (SSH)                ▾ ]  |
+------------------------------------+----------------------------------------------+
| 📂 SAVED SESSIONS                  |  Host Name: [ server.example.com          ]  |
|    ⭐ Production Web API           |                                              |
|    📁 AWS Staging Environments     |  Port:      [ 22                          ]  |
|       ├─ S3 Assets                 +----------------------------------------------+
|       └─ EC2 Linux Box             |  Username:  [ deploy                    ]  |
|    ⭐ Home Raspberry Pi            |                                              |
|                                    |  Password:  [ ••••••••••••••••••••••  ] [🔐] |
|                                    |   — or —                                     |
|                                    |  SSH Key:   [ ~/.ssh/id_ed25519       ] […]  |
+------------------------------------+----------------------------------------------+
|                                    |  Advanced Settings…  [ Advanced Options  ]   |
|                                    +----------------------------------------------+
|                                    |              [ Save ]  [ Cancel ]  [ Login ]   |
+------------------------------------+----------------------------------------------+
| [+] [−] [⚙️]                       | 💡 Tip: Press ⌘L to log in with selection.    |
+------------------------------------+----------------------------------------------+
```

**Advanced Options sheet:** proxy, compression, host key fingerprint, initial remote path, encoding, connection timeout, custom SSH ciphers (expert mode).

### 6.2 Main Commander Window

```text
+-----------------------------------------------------------------------------------+
| MacSCP — Production Web API                                    [ − □ × ]        |
+-----------------------------------------------------------------------------------+
| ◀ ▶ ▲  🔄  📁+  🗑  ℹ  ⇅ Sync  ⌘ Terminal  🔍                    [Queue: 2/5] ⚙ |
+------------------------------------+----------------------------------------------+
| LOCAL                              | REMOTE — server.example.com:/var/www        |
| ~/Projects/website                 | /var/www                                     |
+------------------------------------+----------------------------------------------+
| ▾ assets                           | ▾ html                                       |
|   logo.png          24 KB  Today   |   index.html        4 KB   Jun 12            |
| ▾ css                              | ▾ css                                        |
|   main.css          8 KB   Today   |   main.css          7 KB   Jun 10  ⚠ newer  |
|   …                                |   …                                          |
+------------------------------------+----------------------------------------------+
| 2 selected · 32 KB                 | Connected · SFTP · TLS · 42 ms               |
+-----------------------------------------------------------------------------------+
```

`⚠` = compare/sync mismatch indicator.

### 6.3 Directory Compare / Sync Dialog

```text
+-------------------------------- Compare Directories ------------------------------+
| Local:  ~/Projects/website          Remote: /var/www                              |
| Mode:   ● Mirror local → remote   ○ Mirror remote → local   ○ Bidirectional       |
| [✓] Delete extraneous files       [✓] Preview only (dry run)                      |
+-----------------------------------------------------------------------------------+
| Status        File                      Local          Remote         Action    |
| Newer local   css/main.css              8 KB Jun 13      7 KB Jun 10    Upload    |
| Missing       assets/logo.png           24 KB            —              Upload    |
| Same          html/index.html           4 KB             4 KB             —        |
+-----------------------------------------------------------------------------------+
|                                    [ Cancel ]              [ Synchronize ]       |
+-----------------------------------------------------------------------------------+
```

---

## 7. Technical Architecture

```text
┌─────────────────────────────────────────────────────────────┐
│  MacSCPApp — SwiftUI + AppKit (coordinators, commander UI)  │
├─────────────────────────────────────────────────────────────┤
│  MacSCPUI — TransferQueue · overwrite batch model           │
├─────────────────────────────────────────────────────────────┤
│  MacSCPCore — TransferBackend protocol · config · models    │
│    TransferPerformanceTuning · BenchmarkHostInfo            │
├─────────────────────────────────────────────────────────────┤
│  MacSCPBackends — SFTP implementations                      │
│    ├─ CitadelSFTPBackend (+ TCP tuning, listing cache)      │
│    ├─ TraversioSFTPBackend (agent auth, optional perf mode) │
│    └─ PooledTransferBackend · pipelined read/write          │
├─────────────────────────────────────────────────────────────┤
│  Keychain · ProfileStore · known_hosts (TOFU) · config.toml │
└─────────────────────────────────────────────────────────────┘
         ▲                              ▲
         │ macscp-benchmark CLI         │ macscp-cli → macscp
         └──────────────────────────────┘
```

Future backends (FTP, WebDAV, S3) implement the same `TransferBackend` surface without changing UI layers.

### 7.1 Module Layout (Swift Package)

| Module | Responsibility |
|---|---|
| `MacSCPCore` | `TransferBackend` protocol, session/transfer models, `MacSCPConfiguration`, `TransferPerformanceTuning`, `BenchmarkHostInfo`, directory planner, logging |
| `MacSCPBackends` | Citadel and Traversio SFTP backends, connection pool, pipelined I/O, listing cache, local file mmap reader, buffer pool |
| `MacSCPUI` | Background transfer queue, job state machine, overwrite batch types (shared by app and tests) |
| `MacSCPApp` | SwiftUI executable, coordinator decomposition, session profiles, dual-pane commander |
| `MacSCPBenchmark` | `macscp-benchmark` CLI — throughput comparison vs OpenSSH (`make bench-apple-silicon`) |
| `MacSCPTests` | Unit and integration tests against local OpenSSH fixture (port 2222); **144** XCTest + **3** Swift Testing cases |

Shipped: `macscp-cli` Swift product (installed as `macscp`; see [cli-reference.md](cli-reference.md)).

### 7.2 Persistence

- **Profiles:** `~/Library/Application Support/MacSCP/profiles.json` (JSON, mode 600).
- **Application config:** `~/.macscp/config.toml` — logging and transfer presets (§2.3).
- **Trust store:** `~/.macscp/known_hosts.json` (TOFU fingerprints).
- **Logs:** `~/.macscp/logs/macscp-YYYY-MM-DD.log` (daily rotation).
- **Transfer history:** optional, user-enabled, local JSON at `~/.macscp/transfer-history.json`.

### 7.3 Dependencies (Current)

| Package | Role |
|---|---|
| [Citadel](https://github.com/orlandos-nl/Citadel) | Default SFTP backend (NIOSSH) |
| [Traversio](https://github.com/GitSwiftHQ/Traversio) | SSH agent auth; optional performance backend |
| [swift-crypto](https://github.com/apple/swift-crypto) | Checksums, key handling |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | `macscp-benchmark` CLI |
| [swift-log](https://github.com/apple/swift-log) | Structured logging in benchmark target |

Future backends: additional protocol clients as needed (S3/GCS/WebDAV shipped in Phase 3).

### 7.4 Quality Assurance & Benchmarks

**CI** (`.github/workflows/ci.yml`, runner `macos-15` Apple Silicon):

1. `make check` — build + unit tests
2. `make bench-apple-silicon` — SFTP throughput suite with `hostInfo` metadata
3. `./scripts/verify-benchmark-report.sh` — fail when pass criteria not met

Local parity: `./scripts/ci-local.sh` or `make ci`.

**Pass criteria** (loopback, vs OpenSSH `sftp`):

| Scenario | Minimum ratio |
|---|---|
| Large-file upload | ≥ 0.90× |
| Small-file batch upload | ≥ 0.80× |

Reports: `.benchmark/benchmark-results/report.json`. Fixture: `./scripts/benchmark-env.sh start` (OpenSSH on `127.0.0.1:2222`).

**Test suites** (representative):

| Suite | Coverage |
|---|---|
| `TransferPerformanceTuningTests` | Presets, TCP buffers, pool sizing, env network profile |
| `MacSCPConfigurationTests` | TOML parsing, presets, first-launch arm64 defaults |
| `SFTPBackendSelectorTests` | Citadel vs Traversio routing |
| `SFTPListingCacheTests` | TTL cache hit/miss/invalidate |
| `LocalFileReaderTests` | Small-file reads and mmap path (≥ 256 KB) |
| `TransferBufferPoolTests` | NIO `ByteBuffer` reuse |
| `StreamingChecksumTests` | Incremental SHA-256 vs one-shot |
| `BenchmarkHostInfoTests` | Host metadata in benchmark JSON |
| `TransferQueueTests` | Cancel, disconnect, skip policy (mock backend) |

Run: `make test` or `swift test`.

---

## 8. Competitive Positioning

| Client | Strength | MacSCP Differentiator |
|---|---|---|
| **WinSCP** | Automation, protocol breadth | Native macOS, open source, modern UI |
| **Transmit 5** | Polish, speed, S3 | Free/OSS, WinSCP-style sync + scripting |
| **Cyberduck** | Cloud protocols | Dual-pane commander, CLI parity, no JVM |
| **ForkLift** | Dual-pane, remote editing | Open source, deeper automation |

---

## 9. Delivery Roadmap

### Phase 0 — Foundation (4–6 weeks)

- [x] Swift package skeleton, CI (build + test + benchmarks on macOS 15 Apple Silicon — `.github/workflows/ci.yml`)
- [x] Profile model + Keychain storage
- [x] Session login UI (§6.1)
- [x] SFTP connect/list/upload/download/delete (Citadel + Traversio backends)
- [x] Dual-pane commander

### Phase 1 — MVP (8–10 weeks)

- [x] Transfer queue with progress and cancel
- [x] Host key verification UI (TOFU store + interactive prompt)
- [x] Rename, mkdir, chmod, properties (context menus + sheets)
- [x] Drag-and-drop upload/download (files and folders)
- [x] Overwrite prompts (skip / rename / overwrite)
- [x] SSH agent authentication (Traversio backend)
- [x] Configurable logging + transfer tuning (`~/.macscp/config.toml`)
- [x] Apple Silicon performance layer (presets, TCP tuning, pool, listing cache, mmap reads)
- [x] CI benchmark gate vs OpenSSH (`verify-benchmark-report.sh`)
- [x] External remote editor (download → edit → re-upload)
- [x] Internal remote editor
- [x] Directory compare + one-way and bidirectional sync
- [x] `macscp` CLI: open, close, ls, get, put, sync, cd/lcd/pwd, rm/mkdir/mv/chmod, call, script, version (product `macscp-cli`)

### Phase 2 — Parity+ (8–12 weeks)

- [x] SCP, FTP, FTPS
- [x] Live sync (FSEvents watch)
- [x] Terminal hand-off (Terminal + iTerm2)
- [x] Shortcuts actions
- [x] Quick Look remote preview
- [x] Script runner + WinSCP command mapping doc (basic `.macscp` subset)
- [x] Touch ID session lock

### Phase 3 — Cloud & Integrations (ongoing)

- [x] WebDAV with performance tuning
- [x] Amazon S3 + GCS
- [x] Finder Sync extension
- [x] AppleScript dictionary
- [x] iCloud session sync (opt-in, encrypted)
- [x] Transfer history (optional, local)
- [x] Notification Center on queue completion

### Phase 4 — Parity completion (shipped)

- [x] Multi-session tabs (`⌘T` / `⌘W`)
- [x] Explorer layout mode
- [x] Integrated SSH command pane
- [x] Bidirectional directory sync
- [x] Proxy settings (HTTP, SOCKS5, SSH jump → Traversio)
- [x] OpenSSH `~/.ssh/config` merge + CLI `--rawsettings` (ProxyJump, HostName, Port, User)
- [x] Master password + encrypted profile export
- [x] S3 multipart upload (large files)
- [x] Finder Sync badges on synced folders
- [x] CLI script options (`option continue on`, `option failonnomatch on`)
- [x] Symlink following in directory transfers
- [x] Keyboard navigation (type-ahead, `⌘↑` up, Space Quick Look)
- [x] App Sandbox entitlements variant + security-scoped bookmarks
- [x] Launch/connect timing metrics

---

## 10. Open Questions

| # | Question | Status / recommendation |
|---|---|---|
| 1 | Swift NIO SSH vs libssh2 for SFTP? | **Resolved:** Citadel (NIOSSH) default; Traversio for agent/optional perf (see [SFTP spike](spikes/sftp-backend-spike.md)) |
| 2 | Sandbox enabled at ship? | **Resolved (phased):** No App Sandbox in v0.3 direct distribution; hardened runtime + network entitlements when signed; full sandbox + bookmarks for MAS track — [security.md](security.md) |
| 3 | Ship on Mac App Store? | Direct + Homebrew first; MAS after sandbox/bookmarks |
| 4 | Master password vs pure Keychain? | Both: Keychain default, master password for exports |
| 5 | Explorer mode in v1? | **Resolved:** Explorer layout mode shipped (Phase 4); Commander remains default |
| 6 | Traversio as default backend? | **Resolved:** Citadel default; Traversio for agent + explicit opt-in only — [traversio-licensing.md](traversio-licensing.md), [NOTICE](../NOTICE) |

---

## 11. Glossary

| Term | Definition |
|---|---|
| **Session / Site / Profile** | Saved connection configuration (WinSCP: "Site") |
| **Commander** | Dual-pane local/remote file manager layout |
| **Live sync** | Automatic upload on local filesystem change |
| **Backend** | Protocol-specific adapter implementing `TransferBackend` |
| **Preset** | Named bundle of transfer defaults in `config.toml` (`lan`, `wan`, `apple_silicon`, etc.) |
| **Network profile** | Derived TCP tuning class (`loopback`, `lan`, `wifi`, `wan`) used for socket buffer sizes |
| **Connection pool** | Multiple parallel SSH/SFTP sessions (`PooledTransferBackend`) sized by preset and CPU cores |

---

## Appendix A — WinSCP Feature Mapping

| WinSCP | MacSCP | Phase | Status |
|---|---|---|---|
| Site Manager | Session sidebar + profile editor | 0 | Done |
| Commander interface | Dual-pane commander | 0–1 | Done |
| Synchronize directories | Compare + sync dialog | 1–4 | Done (one-way + bidirectional) |
| Session tabs | Multi-connection tab bar | 4 | Done (`⌘T` / `⌘W`) |
| Proxy / bastion | HTTP, SOCKS5, ProxyJump | 4 | Done (Traversio; OpenSSH config merge) |
| Keep Remote Directory Up To Date | Live sync | 2 | Done |
| Integrated editor | Internal + external editor | 1 | Done |
| PuTTY integration | Terminal / iTerm hand-off | 2 | Done |
| Scripting / `winscp.com` | `macscp` CLI + script files | 1–2 | CLI done; full script parity partial |
| Performance tuning | Transfer presets + Apple Silicon layer | 1 | Done |
| .NET assembly | Swift `MacSCPCore` library (documented API) | 3 | Partial (library exists) |
| Master password | Export encryption + optional app lock | 1–4 | Touch ID lock + encrypted export shipped |

---

*End of specification v0.3*
