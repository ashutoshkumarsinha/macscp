# MacSCP

Open-source, WinSCP-inspired SFTP client for macOS. Phase 1 developer preview: dual-pane commander, transfer queue, recursive directory transfers, SSH agent auth, and configurable logging.

## Requirements

- macOS 15+
- Swift 6.0+
- OpenSSH (`/usr/sbin/sshd`, `/usr/bin/sftp`) for integration benchmarks

## Package layout

```text
Sources/
  MacSCPCore/         Shared models, TransferBackend protocol, config, directory planner
  MacSCPBackends/     Citadel + Traversio SFTP backends, shared SFTP helpers
  MacSCPUI/           Transfer queue, overwrite batch types
  MacSCPApp/          SwiftUI app + coordinators (profile, session, panes, transfers)
  MacSCPBenchmark/    SFTP benchmark harness
Tests/
  MacSCPTests/        42 tests (XCTest + Swift Testing)
scripts/
  benchmark-env.sh    Local OpenSSH SFTP server on port 2222
  run-benchmarks.sh   Start server + run benchmarks
  generate-app-icon.sh
  package-dmg.sh
```

## Build & test

```bash
make build
make test      # 42 tests
make check     # build + test (CI-friendly)
```

Or directly:

```bash
swift build
swift test
```

## Run the app

```bash
make run                  # starts test server + launches MacSCP
# or manually:
./scripts/benchmark-env.sh start
swift run MacSCP
```

Default sample profile connects to `127.0.0.1:2222` with `.benchmark/keys/client_key`.

**Commander:** select files or folders, then **Upload** (⇧⌘U) or **Download** (⇧⌘D). Drag between panes for the same. Progress appears in the transfer queue; pause/resume/cancel from there.

**Authentication:** SSH key file, password (Keychain), or SSH agent (`SSH_AUTH_SOCK`). Agent sessions use the Traversio backend; key/password use Citadel by default.

**Configuration:** `~/.macscp/config.toml` (logging + transfer tuning). Logs: `~/.macscp/logs/`. See `make paths` and `make config`.

## Development helpers

```bash
make paths     # runtime paths (config, logs, profiles, known hosts)
make config    # show ~/.macscp/config.toml
make logs      # tail today's log file
make server-status
```

## Run SFTP benchmarks

```bash
make bench
# or
./scripts/run-benchmarks.sh
```

Full suite (1 MB / 100 MB / 1 GB, 10k small files):

```bash
make bench-full
```

Results: `.benchmark/benchmark-results/report.json`

Upload-only comparison (Citadel vs Traversio vs OpenSSH):

```bash
make bench-upload-spike
```

Results: `.benchmark/benchmark-results/upload-spike.json`

Upload profiling (sweep `maxConcurrentWrites`):

```bash
.build/debug/macscp-benchmark profile-upload
```

Results: `.benchmark/benchmark-results/profile-upload.json`

## Package DMG

```bash
make icon          # square crop + asset catalog + AppIcon.icns
make package-dmg   # release build → MacSCP.app → dist/MacSCP-0.1.0.dmg
```

See [docs/packaging.md](docs/packaging.md) for signing and environment variables.

## Docs

See [docs/README.md](docs/README.md):

- [Product specification](docs/spec.md)
- [High-level design (HLD)](docs/hld.md)
- [User guide](docs/user-guide.md)
- [Code walkthrough](docs/code-walkthrough.md)
- SFTP backend spike and CLI reference (planned CLI)
