# Spike: SSH Session Multiplexing

| Field | Value |
|---|---|
| Status | Benchmarked — staying on hybrid pool (option 3) |
| Related | `PooledTransferBackend`, [performance-roadmap.md](../performance-roadmap.md) |

## Problem

`PooledTransferBackend` opens **N independent SSH sessions** for parallelism. Each session pays:

- TCP + SSH handshake latency
- Server `MaxSessions` / rate limits
- Client CPU for key exchange

Lazy warm-up hides connect latency for browsing, but large batch uploads still benefit from multiple channels.

## Options

### 1. OpenSSH ControlMaster reuse

Spawn `ssh -M -S /path/control.sock` and attach SFTP sessions via control socket.

| Pros | Cons |
|---|---|
| Battle-tested | External `ssh` dependency; sandbox concerns |
| Fast subsequent connects | Control socket lifecycle management |

### 2. Multiple SFTP channels on one SSH connection

Audit Citadel / swift-nio-ssh for multiple concurrent SFTP clients over one `SSHConnection`.

| Pros | Cons |
|---|---|
| Pure Swift | May require upstream API work |
| One handshake | Channel-level locking complexity |

### 3. Hybrid (current direction)

Primary connection for browse; pool of 2–4 connections for transfers; lazy warm-up.

| Pros | Cons |
|---|---|
| Already shipped | Still N handshakes eventually |
| Simple mental model | Not optimal on WAN |

## Recommendation

Stay on **option 3** until a benchmark shows ≥30% connect-time improvement from option 2 on Apple Silicon loopback with pool size 4. Revisit Citadel channel multiplexing first; avoid ControlMaster in the GUI app unless running unsandboxed CLI only.

## Benchmark

Run against the local SFTP fixture:

```bash
make bench-multiplex
# or
./scripts/run-benchmarks.sh multiplex-spike
```

The runner compares:

1. **dual_separate_ssh** — two full Citadel SSH handshakes + list each
2. **dual_channel_single_ssh** — one handshake, two `openSFTP()` channels + list each
3. **improvement_threshold** — pass when multiplex saves ≥30% vs separate

Report: `.benchmark/benchmark-results/multiplex-spike.json`

Interpretation: if the threshold scenario fails, keep `PooledTransferBackend` lazy warm-up. If it passes on your target hosts, prototype a multiplex-aware pool before replacing the hybrid model.

## Next steps

1. Re-run `multiplex-spike` on WAN profiles (`MACSCP_BENCH_NETWORK=wan`) before production multiplex work.
2. Compare results with `pool-connect` (lazy vs single).
3. Document server compatibility matrix (OpenSSH, Dropbear, etc.) when multiplex is enabled.
