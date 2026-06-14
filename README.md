# MacSCP

Open-source, WinSCP-inspired SFTP client for macOS (**v0.3** developer preview). Dual-pane commander, transfer queue, directory sync (one-way and bidirectional), file operations, host key prompts, external/internal remote editor, live sync, Touch ID lock, terminal hand-off, Quick Look, SSH agent auth, **OpenSSH config / ProxyJump**, multi-session tabs, explorer layout, integrated SSH pane, master password + encrypted profile export, cloud backends (WebDAV, S3, GCS), Apple Silicon performance tuning, `macscp` CLI, and configurable logging.

## Requirements

- macOS 15+
- Swift 6.2+ (Xcode 26+ on CI; Xcode 16.4+ may work locally with Xcode 26 selected)
- OpenSSH (`/usr/sbin/sshd`, `/usr/bin/sftp`) for integration benchmarks

## Package layout

```text
Sources/
  MacSCPCore/         Models, TransferBackend protocol, config, OpenSSH config parser, sync engine
  MacSCPBackends/     Citadel + Traversio SFTP/SCP, cloud/FTP/WebDAV backends
  MacSCPUI/           Transfer queue, overwrite batch types
  MacSCPApp/          SwiftUI app + coordinators (profile, session, panes, transfers, sync, tabs)
  MacSCPCLI/          macscp-cli scriptable SFTP client (installed as macscp)
  MacSCPBenchmark/    macscp-benchmark CLI (throughput vs OpenSSH)
Tests/
  MacSCPTests/        164 XCTest + 7 Swift Testing (+ optional live SFTP integration)
scripts/
  benchmark-env.sh    Local OpenSSH SFTP server on port 2222
  benchmark-cloud-env.sh  WebDAV + MinIO fixtures for cloud-backends
  run-benchmarks.sh   Release macscp-benchmark + SFTP fixture (--verify, --keep-server)
  verify-benchmark-report.sh  Fail when passCriteriaMet is false (lists failed scenarios)
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
make test      # 164 XCTest + 7 Swift Testing
make integration-test   # live SFTP smoke test (starts :2222 fixture)
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

**Authentication:** SSH key file, password (Keychain), or SSH agent (`SSH_AUTH_SOCK`). Agent and **proxy sessions** (HTTP, SOCKS5, ProxyJump) use the Traversio backend; key/password use Citadel by default. MacSCP merges `~/.ssh/config` at connect time (HostName, ProxyJump, etc.). See [Traversio licensing policy](docs/traversio-licensing.md).

**Configuration:** `~/.macscp/config.toml` (logging + transfer tuning). Presets: `default`, `lan`, `wan`, `apple_silicon`. On first launch on Apple Silicon, new configs default to `preset = "apple_silicon"`. Logs: `~/.macscp/logs/`. See `make paths` and `make config`.

## CLI

```bash
make cli
./scripts/macscp --help
./scripts/macscp open sftp://user@host/path --batch
./scripts/macscp sync ./local /remote --mirror --delete --preview
./scripts/macscp --session="My Profile" ls /
make package-cli   # sudo: install as /usr/local/bin/macscp
```

Subcommands: `open`, `close`, `ls`, `get`, `put`, `sync`, `cd`, `lcd`, `pwd`, `lpwd`, `rm`, `mkdir`, `mv`, `chmod`, `call`, `script`, `version`. Run a script with `macscp deploy.macscp`. See [docs/cli-reference.md](docs/cli-reference.md).

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

Benchmarks run the **release** `macscp-benchmark` binary (`run-benchmarks.sh` builds `-c release` first). Debug builds skew small-file batch timings.

```bash
make bench
make bench-apple-silicon   # tags hostInfo + MACSCP_BENCH_NETWORK=loopback in report
make bench-verify          # bench-apple-silicon + pass-criteria check
# or
./scripts/run-benchmarks.sh
./scripts/run-benchmarks.sh --verify
./scripts/run-benchmarks.sh pool-connect
./scripts/run-benchmarks.sh --keep-server multiplex-spike
```

Additional spike subcommands (also via `run-benchmarks.sh <subcommand>`):

```bash
make bench-pool-connect
make bench-multiplex
make bench-proxy-command
make bench-cloud          # requires Docker or native MinIO (see benchmark-cloud-env.sh)
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
- `make bench-apple-silicon` + `./scripts/verify-benchmark-report.sh` (release benchmarks)
- Optional cloud backend step (`benchmark-cloud-env.sh` + `cloud-backends`, `continue-on-error`)

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
