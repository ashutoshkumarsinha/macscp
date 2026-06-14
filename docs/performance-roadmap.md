# Performance Roadmap

Tracking document for MacSCP throughput, latency, and resource-use improvements.

## Phase 1 — Quick wins

- [x] Lazy pool warm-up (`PooledTransferBackend` connects primary first, warms rest in background)
- [x] CLI `--pool` / `--no-pool` flags and `TransferSessionConnector`
- [x] WebDAV streaming upload (`URLSession.upload(for:fromFile:)`)
- [x] S3 parallel multipart parts (up to 4 in flight)
- [x] Traversio resume upload concurrent writes
- [x] Post-transfer pane refresh debounce (500 ms, skip while queue active)
- [x] Transfer queue small-file-first scheduling

## Phase 2 — Medium effort

- [x] Parallel remote indexing for sync (`DirectorySyncEngine.collectRemoteParallel`)
- [x] Intel pool sizing under `apple_silicon` preset (`recommendedIntelPoolSize = 2`)
- [x] Traversio TCP intent logging at connect (Network framework hooks pending upstream)
- [x] Shortcuts / automation pool when preset allows
- [x] `pool-connect` benchmark subcommand

## Phase 3 — Architectural

- [x] Sync remote index cache (`SyncIndexStore`, 5 min TTL, invalidated after sync)
- [x] rsync-style block delta sync (`RsyncDelta`, `DeltaSyncEngine`, SFTP ranged I/O)
- [x] GUI stale-while-revalidate remote listing (`RemotePaneCoordinator`)
- [x] SSH session multiplexing spike — `multiplex-spike` benchmark; see [spikes/ssh-multiplex-spike.md](spikes/ssh-multiplex-spike.md)
- [x] ProxyCommand overhead benchmark — `macscp-benchmark proxy-command`
- [x] GUI list virtualization for 10k+ entry directories (`FilePaneView` LazyVStack ≥1000 entries)
- [x] CI WebDAV / S3 benchmark fixtures — `docker/docker-compose.bench-cloud.yml`, `scripts/benchmark-cloud-env.sh`

## Metrics

| Scenario | Target |
|---|---|
| SFTP large upload vs OpenSSH | ≥ 0.90× |
| SFTP small files vs OpenSSH | ≥ 0.80× |
| Pool first list vs single connect | ≤ 1.5× |
| WebDAV upload peak RSS | ≈ chunk size, not full file |
| S3 500 MB+ multipart | ≥ 1.5× vs sequential parts |

Run benchmarks:

```bash
make bench-verify
swift run macscp-benchmark pool-connect
swift run macscp-benchmark multiplex-spike
swift run macscp-benchmark proxy-command
make bench-cloud   # WebDAV + MinIO fixtures
```

See [apple-silicon-performance.md](apple-silicon-performance.md) for tuning presets.
