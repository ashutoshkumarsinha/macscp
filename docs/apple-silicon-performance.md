# Apple Silicon Performance Guide

MacSCP targets Apple Silicon (arm64) as the primary platform. This guide summarizes tuning options, benchmarks, and CI.

**New to the codebase?** Read [code-walkthrough.md §9](code-walkthrough.md) for a file-by-file tour of the performance modules (each source file has a beginner header comment too).

## Quick start

On Apple Silicon, set in `~/.macscp/config.toml`:

```toml
[transfer]
preset = "apple_silicon"
```

This enables:

- Connection pool sized to performance cores (`min(cores/2, 4)`)
- 2 MB transfer chunks with read-ahead pipelining
- 24 concurrent small-file uploads across pooled SFTP sessions
- Checksum verification off by default (enable with `verify_checksums = true`)

On first launch on Apple Silicon, MacSCP writes `preset = "apple_silicon"` (and matching numeric defaults) into new `~/.macscp/config.toml` files automatically.

On Intel Macs, the same preset uses a conservative pool size of 2 connections.

See also [performance-roadmap.md](performance-roadmap.md) for the full enhancement checklist.

## Architecture optimizations

| Feature | Module | Benefit |
|---|---|---|
| Presets + TCP math | `TransferPerformanceTuning.swift` | Turns config preset into pool size and socket sizes |
| Backend routing | `SFTPBackendSelector.swift` | Citadel vs Traversio with logged reason |
| mmap local reads | `LocalFileSequentialReader` | Fewer copies on large uploads |
| `ByteBuffer` pool | `TransferBufferPool` | Less allocator churn |
| Read-ahead SFTP I/O | `CitadelPipelinedWriter/Reader` | Overlap disk and network |
| Streaming SHA-256 | `StreamingSHA256` | Verify without re-reading file |
| Listing cache (3 s TTL) | `SFTPListingCache` (Citadel + Traversio) | Faster pane refresh |
| Connection pool | `PooledTransferBackend` | Parallel queue jobs; lazy warm-up (primary first) |
| Shared connect | `TransferSessionConnector` | CLI, GUI, and Shortcuts use the same pool logic |
| Sync index cache | `SyncIndexStore` | Skip full remote walks on repeat compares (5 min TTL) |
| Parallel sync index | `DirectorySyncEngine` | Concurrent `listDirectory` during compare |
| Streaming WebDAV upload | `HTTPClient.upload` | Disk streaming via `URLSession.upload(for:fromFile:)` |
| S3 parallel multipart | `S3MultipartUpload` | Up to 4 parts in flight |
| Background directory scan | `TransferCoordinator` | UI stays responsive |
| TCP tuning | `CitadelTCPConnector` | Preset-driven socket buffers + Nagle |

## Benchmarks

`run-benchmarks.sh` and `make bench*` build and run the **release** `macscp-benchmark` binary. Debug builds inflate small-file batch times and can fail the ≥0.80× OpenSSH gate spuriously.

```bash
make bench-apple-silicon   # hostInfo in report (MACSCP_BENCH_NETWORK=loopback)
make bench                 # standard quick suite
make bench-upload-spike    # Citadel vs Traversio vs OpenSSH
make bench-verify          # bench-apple-silicon + pass-criteria check
make bench-pool-connect    # single vs pooled connect latency
make bench-multiplex       # dual SSH vs multiplex SFTP channels
make bench-proxy-command   # ProxyCommand relay overhead
make bench-cloud           # WebDAV + S3 (benchmark-cloud-env.sh)
./scripts/run-benchmarks.sh --verify
./scripts/run-benchmarks.sh --keep-server pool-connect
```

Environment variables:

| Variable | Purpose |
|---|---|
| `MACSCP_BENCH_NETWORK` | `loopback` (default), `lan`, `wifi`, `wan` — tagged in report `hostInfo` |
| `MACSCP_BENCH_FULL` | Full file sizes and 10k small files |
| `MACSCP_BENCH_KEEP_SERVER` | Leave SFTP fixture running after `run-benchmarks.sh` (same as `--keep-server`) |

Reports include `hostInfo` (architecture, core count, OS version, network profile).

Verify locally:

```bash
./scripts/verify-benchmark-report.sh
# or after benchmarks:
./scripts/run-benchmarks.sh --verify
```

## Traversio performance mode

For maximum throughput (AGPL — see user guide):

```toml
use_traversio_for_performance = true
```

SSH agent sessions always use Traversio.

## Network tuning

Citadel connections use `CitadelTCPConnector` to apply `SO_SNDBUF`, `SO_RCVBUF`, and `TCP_NODELAY` on the live NIO channel immediately after connect, using values from the active transfer preset (`lan` / `wan` / `apple_silicon`). Traversio uses the Network framework transport, which does not expose the same socket hooks.

Buffer sizes (from `TransferPerformanceTuning`):

| Profile | Send/receive buffer | TCP_NODELAY |
|---|---|---|
| loopback / lan | 2 MB | on |
| wifi | 1 MB | on |
| wan | 256 KB | off |

## CI benchmarks

GitHub Actions workflow [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) runs on `macos-15` (Apple Silicon):

1. `make check` — build + unit tests
2. `make bench-apple-silicon` — release throughput suite with `hostInfo`
3. `./scripts/verify-benchmark-report.sh` — fail when `passCriteriaMet` is false (lists failed scenarios)
4. Optional: cloud backend benchmarks via `benchmark-cloud-env.sh`

Benchmark JSON is uploaded as a workflow artifact. Local parity:

```bash
make ci
# or
./scripts/ci-local.sh
```

## Success criteria

See `docs/spikes/sftp-backend-spike.md` — large upload ≥ 0.90× OpenSSH, small upload ≥ 0.80× on loopback. Run benchmarks in **release** mode (`run-benchmarks.sh` does this automatically).
