# Homebrew distribution

MacSCP ships two Homebrew artifacts:

| Artifact | Path | Installs |
|---|---|---|
| **Cask** (GUI) | `Casks/macscp.rb` | `MacSCP.app` from a release DMG |
| **Formula** (CLI) | `Formula/macscp-cli.rb` | `macscp` command built from source |

## GUI app (cask)

### From a GitHub release (recommended after v0.3.0 is published)

```bash
brew tap ashutoshkumarsinha/macscp https://github.com/ashutoshkumarsinha/macscp
brew install --cask macscp
```

### Local install (before a release is published)

```bash
make icon
make package-dmg
brew install --cask ./packaging/homebrew/Casks/macscp.rb
```

The local cask reads `dist/MacSCP-0.3.0.dmg` produced by `make package-dmg`.

## CLI (formula)

Builds the `macscp-cli` Swift product and installs the binary as `macscp`:

```bash
brew install ./packaging/homebrew/Formula/macscp-cli.rb
# or after tap is published:
brew install ashutoshkumarsinha/macscp/macscp-cli
```

During development:

```bash
make cli
swift run macscp-cli open sftp://user@127.0.0.1:2222/
make package-cli   # sudo: copies to /usr/local/bin/macscp
```

## Maintainer checklist for a release

1. Bump `MACSCP_SHORT_VERSION` (default `div` in `scripts/package-dmg.sh` is `0.3.0`).
2. Run `make ci` locally.
3. `make icon && make package-dmg` with `MACSCP_SIGN_IDENTITY` when signing.
4. Attach `dist/MacSCP-<version>.dmg` to the GitHub release.
5. Update `sha256` in `Casks/macscp.rb`.
6. Push the tap branch or tag the release.

See [packaging.md](../../docs/packaging.md) for code signing and notarization notes.
