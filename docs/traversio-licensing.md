# Traversio (AGPL) licensing policy

MacSCP uses two SFTP backends:

| Backend | Library | License | Default use |
|---|---|---|---|
| **Citadel** | [orlandos-nl/Citadel](https://github.com/orlandos-nl/Citadel) | MIT | Password and SSH key sessions |
| **Traversio** | [GitSwiftHQ/Traversio](https://github.com/GitSwiftHQ/Traversio) | **AGPL-3.0** | SSH agent; **HTTP/SOCKS/ProxyJump**; optional performance mode |

## Policy (as of v0.3)

1. **Citadel remains the default** for password and on-disk key authentication.
2. **Traversio is used automatically** when `AuthMethod.agent` is selected, or when any **proxy** is configured (HTTP CONNECT, SOCKS5, SSH ProxyJump), because Citadel does not implement those paths in MacSCP.
3. **Traversio is opt-in** for plain key/password sessions (no proxy) via `use_traversio_for_performance = true` in `~/.macscp/config.toml`.
4. **Traversio is not the default for distribution** until AGPL implications are reviewed with counsel for your deployment model (SaaS, internal tool, shipped binary, CI-only, etc.).

## Why Traversio is included

Benchmarks (`make bench-upload-spike`) show Traversio uploads can exceed Citadel on Apple Silicon. Agent authentication and **proxy/ProxyJump** require Traversio today. The library is linked in all builds because those code paths depend on it.

## User-visible controls

```toml
# ~/.macscp/config.toml
[transfer]
use_traversio_for_performance = false   # default; set true to prefer Traversio for key/password
```

Backend selection logic: `Sources/MacSCPBackends/SFTP/SFTPBackendSelector.swift`.

## Distribution checklist

Project decision (v0.3):

- [x] Citadel remains default for key/password; Traversio opt-in only (`use_traversio_for_performance`).
- [x] Traversio attribution documented in [NOTICE](../NOTICE) and this file.
- [x] Runtime WARN log when performance mode is enabled (config load + backend selection).
- [ ] Confirm AGPL-3.0 obligations with counsel before **commercial** redistribution or making Traversio the default for all sessions.
- [ ] Decide whether to split an agent-only build variant (higher maintenance) vs. single binary with opt-in perf flag (current approach).

## Alternatives under evaluation

| Option | Trade-off |
|---|---|
| Citadel-only build (exclude Traversio) | No SSH agent; slower uploads; simpler licensing |
| Invest in Citadel upload pipelining | Keeps MIT default; engineering cost |
| Traversio as default after legal sign-off | Best agent + perf story; AGPL compliance required |

See also [SFTP backend spike](spikes/sftp-backend-spike.md) and [spec.md §10](spec.md) open question #6.
