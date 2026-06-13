# MacSCP Documentation

Design and implementation references for the MacSCP project. All documents align with [spec.md](../spec.md) v0.2.

| Document | Description |
|---|---|
| [SFTP Backend Spike](spikes/sftp-backend-spike.md) | Evaluation of Swift SFTP/SSH libraries; recommended backend choice |
| [CLI Reference](cli-reference.md) | `macscp` command-line tool: commands, flags, exit codes, JSON output |
| [Scripting Guide](scripting.md) | `.macscp` script format and WinSCP command mapping |
| [TransferBackend Protocol](transfer-backend.md) | Shared abstraction all protocol backends implement |

## Document Conventions

- **Status:** `draft` until implementation validates assumptions.
- **Version tags:** Each doc carries its own revision; breaking CLI changes bump `cli-reference.md` version.
- **Spike outcomes:** When a spike concludes, update the spike doc with a **Decision** section and link from `spec.md` §10.
