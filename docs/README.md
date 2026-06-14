# MacSCP Documentation

Design and implementation references for the MacSCP project. All documents align with [spec.md](spec.md) v0.3.

| Document | Description |
|---|---|
| [Product Specification](spec.md) | PRD: features, architecture, roadmap (Phases 0–4) |
| [High-Level Design (HLD)](hld.md) | As-built architecture, coordinators, backends, OpenSSH merge, data flows |
| [User Guide](user-guide.md) | End-user guide: connect, transfer, proxy, config, troubleshooting |
| [Code Walkthrough](code-walkthrough.md) | Beginner-oriented tour of the source code (file headers: `WHAT THIS FILE DOES`) |
| [Packaging Guide](packaging.md) | DMG, App Icon catalog, code signing |
| [SFTP Backend Spike](spikes/sftp-backend-spike.md) | Evaluation of Swift SFTP/SSH libraries; ProxyJump wired via Traversio |
| [Benchmark Results](../.benchmark/benchmark-results/report.json) | Latest `macscp-benchmark` JSON output (generated) |
| [CLI Reference](cli-reference.md) | `macscp-cli` command-line tool (installed as `macscp`) |
| [Traversio licensing](traversio-licensing.md) | AGPL policy for Traversio (agent, proxy, optional perf mode) |
| [Security & distribution](security.md) | Sandbox roadmap, entitlements, signing, credentials |
| [Scripting Guide](scripting.md) | `.macscp` script format and WinSCP command mapping |
| [TransferBackend Protocol](transfer-backend.md) | Shared abstraction all protocol backends implement |
| [Apple Silicon Performance](apple-silicon-performance.md) | arm64 tuning, `apple_silicon` preset, benchmarks, CI |

## Quick commands

```bash
make build test   # compile + 144 XCTest + 3 Swift Testing
make integration-test   # live SFTP against :2222 (CI)
make run          # local SFTP fixture + launch app
make paths        # ~/.macscp paths, profiles, known hosts
make bench                 # SFTP throughput benchmarks
make bench-apple-silicon   # bench with hostInfo metadata
make bench-verify          # bench-apple-silicon + pass-criteria check
make ci                    # check + bench-verify (local GitHub Actions parity)
./scripts/ci-local.sh      # same as make ci
```

## Scripts

| Script | Purpose |
|---|---|
| [benchmark-env.sh](../scripts/benchmark-env.sh) | Start/stop local OpenSSH SFTP on `:2222` |
| [run-benchmarks.sh](../scripts/run-benchmarks.sh) | Run `macscp-benchmark` (optional `--verify`) |
| [verify-benchmark-report.sh](../scripts/verify-benchmark-report.sh) | Exit non-zero when `passCriteriaMet` is false |
| [ci-local.sh](../scripts/ci-local.sh) | `make check` + benchmarks + verify |
| [package-dmg.sh](../scripts/package-dmg.sh) | Release `.app` + DMG packaging |
| [build-finder-sync.sh](../scripts/build-finder-sync.sh) | Compile Finder Sync extension |
| [generate-app-icon.sh](../scripts/generate-app-icon.sh) | App icon asset catalog + `.icns` |
| [macscp](../scripts/macscp) | Dev wrapper → `.build/debug/macscp-cli` |

CI workflow: [.github/workflows/ci.yml](../.github/workflows/ci.yml) (`macos-15` runner, Xcode 26).

See the root [README.md](../README.md) and [Makefile](../Makefile) for all targets.

## Document Conventions

- **Status:** `draft` until implementation validates assumptions; v0.3 docs reflect as-built code on `main`.
- **Version tags:** Each doc carries its own revision; breaking CLI changes bump `cli-reference.md` version.
- **Source comments:** Swift/shell files use `WHAT THIS FILE DOES` headers — see [code-walkthrough.md](code-walkthrough.md).
- **Spike outcomes:** When a spike concludes, update the spike doc with a **Decision** section and link from `spec.md` §10.
