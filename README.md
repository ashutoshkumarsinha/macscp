# MacSCP

Open-source, WinSCP-inspired SFTP client for macOS (**v0.3** developer preview). dual-pane commander, transfer queue, directory sync, file operations, host key prompts, external remote editor, live sync, Touch ID lock, terminal hand-off, Quick Look, SSH agent auth, Apple Silicon performance tuning, `macscp` CLI, and configurable logging.

## Requirements

- macOS 15+
- Swift 6.2+ (Xcode 26+ on CI; Xcode 16.4+ may work locally with Xcode 26 selected)
- OpenSSH (`/usr/sbin/sshd`, `/usr/bin/sftp`) for integration benchmarks

## Package layout

```text
Sources/
  MacSCPCore/         Models, TransferBackend protocol, config, sync engine, host key gate
  MacSCPBackends/     Citadel + Traversio SFTP backends, listing cache, TCP tuning, buffer pool
  MacSCPUI/           Transfer queue, overwrite batch types
  MacSCPApp/          SwiftUI app + coordinators (profile, session, panes, transfers, sync)
  MacSCPCLI/          macscp-cli scriptable SFTP client (installed as macscp)
  MacSCPBenchmark/    macscp-benchmark CLI (throughput vs OpenSSH)
Tests/
  MacSCPTests/        91 tests (88 XCTest + 3 Swift Testing)
scripts/
  benchmark-env.sh    Local OpenSSH SFTP server on port 2222
  run-benchmarks.sh   Start server + run benchmarks (--verify optional)
  verify-benchmark-report.sh  Fail when passCriteriaMet is false
  ci-local.sh         Local mirror of GitHub Actions CI
  generate-app-icon.sh
  package-dmg.sh
packaging/homebrew/   Cask (GUI) + Formula (CLI) templates
.github/workflows/
  ci.yml              Tests + Apple Silicon benchmarks on macos-15 (Xcode 26)
```

## Build & test

```bash
make build
make test      # 91 tests (88 XCTest + 3 Swift Testing)
make check     # build + test (CI-friendly)
make ci        # check + bench-apple-silicon + verify pass criteria
make cli       # build macscp-cli product
```

Or directly:

```bash
swift build
swift test
swift run macscp-cli --help
```

> **Note:** The CLI Swift product is named `macscp-cli` because `MacSCP` and `macscp` collide on case-insensitive macOS build outputs. `make package-cli` installs the binary as `/usr/local/bin/macscp`.

## Run the app

```bash
make run                  # starts test server + launches MacSCP
# or manually:
./scripts/benchmark-env.sh start
swift run MacSCP
```

Default sample profile connects to `127.0.0.1:2222` with `.benchmark/keys/client_key`.

**Commander:** select files or folders, then **Upload** (⇧⌘U) or **Download** (⇧⌘D). Drag between panes for the same. Use the toolbar for **Sync**, **Terminal**, and **Live Sync**. Right-click entries for rename, delete, properties, Quick Look, and edit.

**Authentication:** SSH key file, password (Keychain), or SSH agent (`SSH_AUTH_SOCK`). Agent sessions use the Traversio backend; key/password use Citadel by default. See [Traversio licensing policy](docs/traversio-licensing.md).

**Configuration:** `~/.macscp/config.toml` (logging + transfer tuning). Presets: `default`, `lan`, `wan`, `apple_silicon`. On first launch on Apple Silicon, new configs default to `preset = "apple_silicon"`. Logs: `~/.macscp/logs/`. See `make paths` and `make config`.

## CLI

```bash
make cli
./scripts/macscp --help
./scripts/macscp open sftp://user@host/path --batch
make package-cli   # sudo: install as /usr/local/bin/macscp
```

The release `.app` bundle also includes `Contents/MacOS/macscp` (see `make package-dmg`).

Swift product name is **`macscp-cli`** (avoids case collision with `MacSCP` on macOS build paths).

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
make bench-apple-silicon   # tags hostInfo + MACSCP_BENCH_NETWORK=loopback in report
make bench-verify          # bench-apple-silicon + pass-criteria check
# or
./scripts/run-benchmarks.sh
./scripts/run-benchmarks.sh --verify
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
make bench-profile
# or
.build/debug/macscp-benchmark profile-upload
```

Results: `.benchmark/benchmark-results/profile-upload.json`

Verify pass criteria locally (same check as CI):

```bash
./scripts/verify-benchmark-report.sh
```

## CI

GitHub Actions (`.github/workflows/ci.yml`) runs on `macos-15` (Apple Silicon) with **Xcode 26** (Swift 6.2+ for Traversio):

- `make check` — build + unit tests
- `make bench-apple-silicon` + `./scripts/verify-benchmark-report.sh`

Local equivalent:

```bash
./scripts/ci-local.sh
# tests only:
./scripts/ci-local.sh --skip-bench
```

See [Apple Silicon Performance Guide](docs/apple-silicon-performance.md) for presets and tuning.

## Distribution

```bash
make icon          # square crop + asset catalog + AppIcon.icns
make package-dmg   # release build → MacSCP.app → dist/MacSCP-0.3.0.dmg
brew install --cask ./packaging/homebrew/Casks/macscp.rb
brew install ./packaging/homebrew/Formula/macscp-cli.rb
```

See [docs/packaging.md](docs/packaging.md) and [packaging/homebrew/README.md](packaging/homebrew/README.md) for signing, Homebrew tap, and release checklist.

## Docs

See [docs/README.md](docs/README.md):

- [Product specification](docs/spec.md) (v0.3)
- [High-level design (HLD)](docs/hld.md)
- [User guide](docs/user-guide.md)
- [CLI reference](docs/cli-reference.md)
- [Traversio licensing policy](docs/traversio-licensing.md)
- [Security & distribution](docs/security.md)
- [Code walkthrough](docs/code-walkthrough.md) — includes §9 performance file tour
- [Apple Silicon performance](docs/apple-silicon-performance.md)
