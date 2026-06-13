# Spike: SFTP / SSH Backend Choice

| Field | Value |
|---|---|
| Status | Draft — pending benchmark run |
| Author | MacSCP team |
| Created | 2026-06-13 |
| Related | [spec.md §7](../../spec.md), [TransferBackend](../transfer-backend.md) |

---

## 1. Objective

Select the SFTP implementation MacSCP will use for Phase 0–2. The choice must satisfy:

1. **Throughput** — ≥ 90% of OpenSSH `sftp` CLI on LAN (spec success metric).
2. **Feature coverage** — list, stat, upload, download, rename, mkdir, rmdir, remove, chmod, resume (read/write offset).
3. **Auth** — password, public key (Ed25519, ECDSA, RSA), encrypted keys, macOS ssh-agent / 1Password agent.
4. **Security** — host key verification, modern ciphers, no deprecated algorithms by default.
5. **Integration** — Swift 6, async/await, Apple Silicon native, App Sandbox–compatible where possible.
6. **Maintainability** — active maintenance, Apache/MIT license, no commercial runtime fees.

---

## 2. Candidates

### 2.1 Citadel (NIOSSH + built-in SFTP)

| | |
|---|---|
| **Repo** | [orlandos-nl/Citadel](https://github.com/orlandos-nl/Citadel) |
| **License** | MIT |
| **Stack** | High-level API on [swift-nio-ssh](https://github.com/apple/swift-nio-ssh); implements SFTP v3 client in Swift |
| **Stars / activity** | ~350+; regular commits through 2025–2026 |

**Pros**

- Pure Swift stack; aligns with spec §7.3 dependency direction.
- SFTP client API already exists: `openSFTP()`, `listDirectory`, `openFile`, chunked read/write.
- Same ecosystem as NIO — natural fit for concurrent transfer workers.
- MIT license; no XCFramework vendoring.
- Can share event loop with other async MacSCP services.

**Cons**

- SFTP layer is project-maintained, not Apple-backed — bug fixes depend on Citadel/NIO community.
- swift-nio-ssh intentionally supports **modern ciphers only**; legacy servers (old RSA-SHA1, diffie-hellman-group1-sha1) may fail unless Citadel adds compatibility shims.
- SSH agent integration may require custom work (verify current Citadel auth delegates).
- Less battle-tested than libssh2 for edge-case SFTP servers.

**Risk level:** Medium — best architectural fit, moderate protocol-compat risk.

---

### 2.2 Traversio (libssh2 wrapper, native Swift API)

| | |
|---|---|
| **Repo** | [GitSwiftHQ/Traversio](https://github.com/GitSwiftHQ/Traversio) |
| **License** | Check repo (verify before adoption) |
| **Stack** | Swift API over libssh2; SFTP, SCP, forwarding, ProxyJump |

**Pros**

- libssh2 SFTP compatibility — same engine family WinSCP uses indirectly via PuTTY stack; broad server support.
- Explicit feature list: SFTP transfers, host-key policy, agent auth, OpenSSH key loading, ProxyJump.
- macOS 26+ uses newer Apple transport APIs with fallback for older OS versions.
- Single library covers SFTP + SCP + jump hosts — reduces Phase 2 work.

**Cons**

- **C dependency** (libssh2 + likely OpenSSL/boringssl) — complicates App Sandbox, static linking, and supply-chain audit.
- Younger project; `1.0.x` line explicitly warns not all servers/conditions are covered.
- Less control over memory/copy behavior vs pure Swift NIO pipelines.
- Potential license/GPL contagion from OpenSSL linkage — legal review required.

**Risk level:** Medium-high — strongest compat story, weakest purity/sandbox story.

---

### 2.3 libssh2-apple (raw C bindings)

| | |
|---|---|
| **Repo** | [mfcollins3/libssh2-apple](https://github.com/mfcollins3/libssh2-apple) |
| **License** | Package wrapper + libssh2 license |
| **Stack** | XCFramework wrapping libssh2 for macOS/iOS |

**Pros**

- Direct access to libssh2 — maximum control, WinSCP-grade server compatibility.
- Prebuilt XCFramework for Apple Silicon + Intel.

**Cons**

- **No high-level Swift API** — MacSCP must build entire SFTP session layer (auth, channel, SFTP packet handling) or fork Traversio's approach.
- OpenSSL build/maintenance burden on MacSCP team.
- Highest implementation cost for Phase 0.

**Risk level:** High for timeline — only viable if Citadel and Traversio both fail benchmarks.

---

### 2.4 swift-ssh-client (NIOSSH + SFTP)

| | |
|---|---|
| **Repo** | [gaetanzanella/swift-ssh-client](https://github.com/gaetanzanella/swift-ssh-client) |
| **License** | MIT |
| **Stack** | Thin high-level layer on swift-nio-ssh with SFTP client |

**Pros**

- Similar stack to Citadel; small surface area to evaluate.
- MIT license.

**Cons**

- Marked **beta** (`0.1.x`); API unstable; single maintainer; last significant activity 2023.
- Less feature-complete than Citadel (no server, forwarding, etc.).
- Citadel subsumes this role with more momentum.

**Risk level:** High — superseded by Citadel for MacSCP purposes.

---

### 2.5 OpenSSH `sftp` subprocess (Process wrapper)

| | |
|---|---|
| **Stack** | Shell out to `/usr/bin/sftp` or `/usr/bin/ssh` with batch commands |

**Pros**

- Perfect server compatibility and throughput baseline.
- Zero SFTP implementation effort.
- Inherits ssh-agent, `~/.ssh/config`, ProxyJump for free.

**Cons**

- **Poor fit for GUI app** — parsing progress, cancel/resume, and queue management from batch mode is fragile.
- App Sandbox restricts subprocess and filesystem access.
- Hard to embed in `MacSCPCore` library for CLI/programmatic use.
- Cannot meet integrated transfer queue / per-file progress UX without scraping stderr.

**Risk level:** Reject for core backend — acceptable only as **benchmark baseline** and optional fallback debug mode.

---

### 2.6 libcurl / IPWorks (commercial)

| Option | Verdict |
|---|---|
| **libcurl** SFTP | Viable C path; awkward Swift API; same sandbox issues as libssh2 |
| **IPWorks SFTP** | Commercial license incompatible with OSS MacSCP goals |

**Risk level:** Reject unless sponsorship requires commercial support.

---

## 3. Evaluation Matrix

Scoring: 1 (poor) – 5 (excellent). Scores are **pre-benchmark estimates**; update after §5.

| Criterion | Weight | Citadel | Traversio | libssh2-apple | ssh-client | sftp CLI |
|---|---:|---:|---:|---:|---:|---:|
| SFTP feature coverage | 20% | 4 | 5 | 5 | 3 | 5 |
| Transfer throughput | 20% | 4 | 4 | 4 | 3 | 5 |
| Server compatibility (legacy) | 15% | 3 | 5 | 5 | 3 | 5 |
| Swift 6 / async ergonomics | 15% | 5 | 4 | 2 | 4 | 1 |
| Sandbox & packaging | 10% | 5 | 3 | 3 | 5 | 2 |
| Maintenance & community | 10% | 4 | 3 | 3 | 2 | 5 |
| License (OSS fit) | 10% | 5 | 4* | 4* | 5 | 5 |
| **Weighted total** | | **4.05** | **4.20** | **3.65** | **3.05** | **3.85** |

\*Verify Traversio/libssh2 transitive licenses before ship.

---

## 4. MacSCP Integration Model

Regardless of library, MacSCP wraps the choice behind `SFTPBackend: TransferBackend`:

```swift
public protocol TransferBackend: Sendable {
    func connect(configuration: SessionConfiguration) async throws
    func disconnect() async throws
    func listDirectory(at path: String) async throws -> [RemoteEntry]
    func upload(local: URL, remote: String, options: TransferOptions) async throws -> TransferResult
    func download(remote: String, local: URL, options: TransferOptions) async throws -> TransferResult
    // … rename, mkdir, remove, chmod, stat
}
```

This allows a **secondary backend** (e.g. Traversio) behind a feature flag for “legacy server mode” without rewriting UI/CLI.

---

## 5. Benchmark Plan

Run after Phase 0 scaffold exists (`MacSCPBenchmark` target).

### 5.1 Environment

| Item | Value |
|---|---|
| Client | MacBook Apple Silicon, macOS 26 |
| Server | OpenSSH 9.x in Docker (`atmoz/sftp`) + one legacy CentOS 7 SSH fixture |
| Network | localhost (loopback) and Wi-Fi LAN |
| Files | 1 MB, 100 MB, 1 GB single file; 10k × 4 KB tree |

### 5.2 Scenarios

1. Upload / download single large file (measure MB/s).
2. Upload / download 10k small files (measure files/sec).
3. List directory 10k entries.
4. Resume download from 50% offset.
5. Connect with Ed25519 key + password-protected key + ssh-agent.
6. Connect to legacy server (RSA host key, `diffie-hellman-group14-sha256`).

### 5.3 Baseline

```bash
# Throughput baseline
/usr/bin/sftp -B 262144 -b batch.txt user@localhost

# Latency baseline
/usr/bin/ssh user@localhost stat /tmp
```

### 5.4 Pass Criteria

- Large-file throughput ≥ **90%** of OpenSSH `sftp` on loopback.
- Small-file batch within **80%** (higher overhead expected).
- Zero data corruption (SHA-256 compare).
- Resume offset accurate to the byte.

---

## 6. Authentication & Agent Spike Tasks

Checklist to complete during Phase 0 (1–2 days each):

- [ ] Load `~/.ssh/id_ed25519` with passphrase from Keychain.
- [ ] Authenticate via `SSH_AUTH_SOCK` (system agent).
- [ ] Read `KnownHosts` / TOFU store; reject changed keys.
- [ ] Honor `ProxyJump` from OpenSSH config (Traversio native; Citadel may need manual jump implementation).
- [ ] Document cipher mismatch errors with actionable UI text.

---

## 7. Preliminary Recommendation

**Primary: Citadel** for Phase 0–1 implementation.

| Rationale | |
|---|---|
| Pure Swift + NIO | Matches architecture, Swift 6 concurrency, easiest App Sandbox path |
| SFTP client ready | Fastest path to dual-pane MVP |
| License | MIT, no royalties |
| Team ownership | MacSCP can contribute SFTP fixes upstream |

**Contingency: Traversio** if benchmarks or compatibility testing show:

- Throughput < 80% of OpenSSH on loopback, or
- > 10% failure rate against a [Public SFTP test server](http://www.sftp.net/public-servers) sample set, or
- Blocker on ssh-agent / ProxyJump with Citadel.

**Implementation strategy:**

1. Implement `SFTPBackend` against Citadel immediately.
2. Define `TransferBackend` protocol to be library-agnostic (see [transfer-backend.md](../transfer-backend.md)).
3. Run §5 benchmarks in Week 2 of Phase 0.
4. If Citadel fails pass criteria, swap backend behind protocol — UI/CLI unchanged.

---

## 8. Decision Log

| Date | Decision | Notes |
|---|---|---|
| 2026-06-13 | **Tentative: Citadel** | Pending benchmark + agent spike |
| — | Final decision | _Record here after benchmarks_ |

---

## 9. References

- [swift-nio-ssh README](https://github.com/apple/swift-nio-ssh) — programmatic SSH; no bundled SFTP
- [Citadel SFTP client](https://github.com/orlandos-nl/Citadel#sftp-client)
- [Traversio README](https://github.com/GitSwiftHQ/Traversio)
- [WinSCP SFTP documentation](https://winscp.net/eng/docs/protocols)
- [Apple Developer Forums: SFTP in Swift](https://developer.apple.com/forums/thread/729346)
- [OpenSSH sftp(1)](https://man.openbsd.org/sftp.1)

---

*End of spike document*
