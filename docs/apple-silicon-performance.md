# Apple Silicon Performance Guide

MacSCP targets Apple Silicon (arm64) as the primary platform. This guide summarizes tuning options, benchmarks, and CI.

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

## Architecture optimizations

| Feature | Module | Benefit |
|---|---|---|
| mmap local reads | `LocalFileSequentialReader` | Fewer copies on large uploads |
| `ByteBuffer` pool | `TransferBufferPool` | Less allocator churn |
| Read-ahead SFTP I/O | `CitadelPipelinedWriter/Reader` | Overlap disk and network |
| Streaming SHA-256 | `StreamingSHA256` | Verify without re-reading file |
| Listing cache (3 s TTL) | `SFTPListingCache` (Citadel + Traversio) | Faster pane refresh |
| Connection pool | `PooledTransferBackend` | Parallel queue jobs |
| Background directory scan | `TransferCoordinator` | UI stays responsive |
| TCP tuning | `CitadelTCPConnector` | Preset-driven socket buffers + Nagle |

## Benchmarks

```bash
make bench-apple-silicon   # hostInfo in report (MACSCP_BENCH_NETWORK=loopback)
make bench                 # standard quick suite
make bench-upload-spike    # Citadel vs Traversio vs OpenSSH
make bench-verify          # bench-apple-silicon + pass-criteria check
./scripts/run-benchmarks.sh --verify
```

Environment variables:

| Variable | Purpose |
|---|---|
| `MACSCP_BENCH_NETWORK` | `loopback` (default), `lan`, `wifi`, `wan` — tagged in report `hostInfo` |
| `MACSCP_BENCH_FULL` | Full file sizes and 10k small files |

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
2. `make bench-apple-silicon` — throughput suite with `hostInfo`
3. `./scripts/verify-benchmark-report.sh` — fail when `passCriteriaMet` is false

Benchmark JSON is uploaded as a workflow artifact. Local parity:

```bash
make ci
# or
./scripts/ci-local.sh
```

## Success criteria

See `docs/spikes/sftp-backend-spike.md` — large upload ≥ 0.90× OpenSSH, small upload ≥ 0.80× on loopback.
