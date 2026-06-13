# MacSCP Documentation

Design and implementation references for the MacSCP project. All documents align with [spec.md](spec.md) v0.2.

| Document | Description |
|---|---|
| [Product Specification](spec.md) | PRD: features, architecture, roadmap |
| [High-Level Design (HLD)](hld.md) | As-built architecture, coordinators, backends, data flows |
| [User Guide](user-guide.md) | End-user guide: connect, transfer, config, troubleshooting |
| [Code Walkthrough](code-walkthrough.md) | Beginner-oriented tour of the source code |
| [Packaging Guide](packaging.md) | DMG, App Icon catalog, code signing |
| [SFTP Backend Spike](spikes/sftp-backend-spike.md) | Evaluation of Swift SFTP/SSH libraries; recommended backend choice |
| [Benchmark Results](../.benchmark/benchmark-results/report.json) | Latest `macscp-benchmark` JSON output (generated) |
| [CLI Reference](cli-reference.md) | `macscp` command-line tool: commands, flags, exit codes, JSON output |
| [Scripting Guide](scripting.md) | `.macscp` script format and WinSCP command mapping |
| [TransferBackend Protocol](transfer-backend.md) | Shared abstraction all protocol backends implement |

## Quick commands

```bash
make build test   # compile + 42 tests
make run          # local SFTP fixture + launch app
make paths        # ~/.macscp paths, profiles, known hosts
make bench        # SFTP throughput benchmarks
```

See the root [README.md](../README.md) and [Makefile](../Makefile) for all targets.

## Document Conventions

- **Status:** `draft` until implementation validates assumptions.
- **Version tags:** Each doc carries its own revision; breaking CLI changes bump `cli-reference.md` version.
- **Spike outcomes:** When a spike concludes, update the spike doc with a **Decision** section and link from `spec.md` §10.
