# MacSCP

Open-source, WinSCP-inspired SFTP client for macOS. Phase 0 scaffold.

## Requirements

- macOS 15+
- Swift 6.0+
- OpenSSH (`/usr/sbin/sshd`, `/usr/bin/sftp`) for integration benchmarks

## Package layout

```text
Sources/
  MacSCPCore/       Shared models, TransferBackend protocol
  MacSCPBackends/   Citadel + Traversio SFTP backends
  MacSCPBenchmark/  SFTP spike benchmark harness
  MacSCPApp/        Phase 0–1 UI (login, commander, transfer queue)
Tests/
  MacSCPTests/
scripts/
  benchmark-env.sh  Local OpenSSH SFTP server on port 2222
  run-benchmarks.sh Start server + run benchmarks
docker/
  docker-compose.test.yml  Optional atmoz/sftp fixture
```

## Build

```bash
swift build
swift test
```

## Run SFTP benchmarks

```bash
./scripts/run-benchmarks.sh
```

Full suite (1 MB / 100 MB / 1 GB, 10k small files):

```bash
MACSCP_BENCH_FULL=1 ./scripts/run-benchmarks.sh
```

Results: `.benchmark/benchmark-results/report.json`

Upload-only comparison (Citadel vs Traversio vs OpenSSH):

```bash
./scripts/benchmark-env.sh start
swift run macscp-benchmark upload-spike
```

Results: `.benchmark/benchmark-results/upload-spike.json`

## Run Phase 0 UI

```bash
./scripts/benchmark-env.sh start   # optional: local test server on :2222
swift run MacSCP
```

Default sample profile connects to `127.0.0.1:2222` with `.benchmark/keys/client_key`.

**Commander transfers (Phase 1):** select files in a pane, then **Upload** (⇧⌘U) or **Download** (⇧⌘D). Progress appears in the transfer queue panel; pause/resume/cancel from there.

## Docs

See [docs/README.md](docs/README.md) for the [product specification](docs/spec.md), CLI reference, and SFTP backend spike.
