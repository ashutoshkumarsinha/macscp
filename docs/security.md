# MacSCP Security & Distribution

Security posture for v0.3 developer preview and the path to Mac App Store distribution.

---

## Resolved decisions

| Topic | Decision (v0.3) |
|---|---|
| **App Sandbox** | **Not enabled** for direct/Homebrew distribution. Full sandbox deferred to the Mac App Store track (requires security-scoped bookmarks for local pane access). |
| **Hardened runtime** | Enabled when signing with `MACSCP_SIGN_IDENTITY` via `packaging/MacSCP.entitlements`. |
| **Outbound network** | Required for SFTP; entitlement `com.apple.security.network.client` is included in release signing. |
| **Traversio (AGPL)** | Citadel default; Traversio for SSH agent, **proxy sessions**, or explicit opt-in — see [traversio-licensing.md](traversio-licensing.md) and [NOTICE](../NOTICE). |
| **Sandbox variant** | `packaging/MacSCP.sandbox.entitlements` + `SecurityScopedBookmarkStore` for future MAS track; not used in default DMG yet. |

---

## Credentials & host keys

| Asset | Storage |
|---|---|
| Passwords | macOS Keychain (`KeychainCredentialStore`) |
| SSH key passphrases | macOS Keychain (separate service; never in profiles.json) |
| SSH private key paths | Profile JSON (`~/Library/Application Support/MacSCP/profiles.json`, mode 600) |
| Host keys (TOFU) | `~/.macscp/known_hosts.json` |
| Optional fingerprint pin | Profile advanced settings |

Host key changes trigger an interactive prompt in the GUI; CLI `--batch` rejects unknown keys.

---

## Code signing & notarization

Release builds use `scripts/package-dmg.sh`:

```bash
MACSCP_SIGN_IDENTITY="Developer ID Application: …" make package-dmg
```

| Step | Status |
|---|---|
| Hardened runtime + entitlements | Implemented |
| Developer ID signing | Supported via env var |
| Notarization / stapling | **Not automated** — required for smooth Gatekeeper on first open |

Entitlements file: `packaging/MacSCP.entitlements` (network client only; no App Sandbox in v0.3).

---

## App Sandbox roadmap (Mac App Store track)

Enabling App Sandbox breaks unfettered filesystem access in the local commander pane. Planned steps:

1. **Security-scoped bookmarks** — user picks local root via `NSOpenPanel`; store bookmark in profile or app support.
2. **Enable sandbox entitlement** — `com.apple.security.app-sandbox = true` plus `com.apple.security.files.bookmarks.app-scope` (or user-selected read/write).
3. **Network client** — retain outbound SFTP entitlement.
4. **Notarize + MAS review** — after bookmark flow covers upload/download paths.

Until then, direct distribution (DMG/Homebrew) runs without sandbox, matching most developer tools.

---

## Traversio / AGPL

MacSCP links Traversio in all builds because SSH agent auth requires it. Key/password sessions use Citadel unless the user sets:

```toml
[transfer]
use_traversio_for_performance = true
```

A **WARN** log line is emitted when performance mode is enabled. See [NOTICE](../NOTICE) for attribution and source pointers.

---

## Reporting issues

Report security vulnerabilities through the project issue tracker (private disclosure process TBD before public release).

---

*Related: [packaging.md](packaging.md), [traversio-licensing.md](traversio-licensing.md), [user-guide.md](user-guide.md)*
