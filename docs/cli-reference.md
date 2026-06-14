# MacSCP CLI Reference

| Field | Value |
|---|---|
| Version | 0.3 |
| Binary | `macscp` (Swift product `macscp-cli`; see note below) |
| Related | [spec.md §4](spec.md), [scripting.md](scripting.md), [traversio-licensing.md](traversio-licensing.md) |

The Swift package product is named **`macscp-cli`** because the GUI binary `MacSCP` and CLI `macscp` collide on case-insensitive macOS build paths. After `make package-cli` or Homebrew install, the command on `$PATH` is **`macscp`**.

During development:

```bash
swift run macscp-cli --help
.build/debug/macscp-cli version
```

The `macscp` command-line tool provides scriptable file transfers and shares the session profile store with the MacSCP GUI. Syntax is intentionally close to [WinSCP scripting](https://winscp.net/eng/docs/scripting) where practical.

---

## Synopsis

```bash
macscp [--help] [GLOBAL OPTIONS] <command> [ARGS]
macscp [--help] [GLOBAL OPTIONS] /path/to/script.macscp
```

Invoking `macscp` with a `.macscp` (or `.txt`) script path as the sole argument is equivalent to `macscp script /path/to/script.macscp`.

Global options must appear **before** the subcommand (ArgumentParser convention), except when running a script as the sole argument.

---

## Global Options

These flags are available on every subcommand via `@OptionGroup`:

| Option | Description |
|---|---|
| `--session <name\|uuid>` | Use saved profile from `~/Library/Application Support/MacSCP/profiles.json` (password/key from Keychain or `MACSCP_PASSPHRASE`) |
| `--ini none` | Skip loading `~/.macscp/config.toml` (WinSCP `/ini=nul` equivalent). Other `--ini` paths are reserved |
| `--ini <path>` | Load transfer settings from a custom config.toml, or `none` to skip |
| `--loglevel <level>` | Minimum log level (`debug`, `info`, `warning`, `error`) |
| `--logfile <path>` | Append structured logs to a single file (NDJSON/human messages unaffected) |
| `--json` | JSON for `ls`, `call stat`, `version`; NDJSON event stream for `get`, `put`, `sync`, `open`, `close` |
| `--quiet` / `-q` | Suppress non-error stdout |
| `--batch` | Strict host keys; no interactive trust prompts |
| `--hostkey <fingerprint>` | Expected host key (repeatable; last value wins on `open`) |
| `--timeout <seconds>` | Sets `AdvancedSettings.connectionTimeoutSeconds` on connect |
| `--pool` | Force SFTP connection pool for transfers (overrides config) |
| `--no-pool` | Single serialized SFTP connection (disables pool even with `apple_silicon` preset) |

Subcommand-specific options:

| Option | Subcommands | Description |
|---|---|---|
| `--privatekey <path>` | `open` | SSH private key path |
| `--passphrase <string>` | `open` | Key passphrase (prefer `MACSCP_PASSPHRASE`) |
| `--rawsettings <k=v>` | `open` | Repeatable OpenSSH-style overrides (see below) |

### `--rawsettings` (OpenSSH-style)

Used with `macscp open` (repeatable):

| Key | Example | Effect |
|---|---|---|
| `ProxyJump` | `ProxyJump=bastion,jump2` | SSH jump chain → Traversio backend |
| `HostName` | `HostName=prod.internal` | Target hostname |
| `Port` | `Port=2222` | SSH port |
| `User` | `User=deploy` | SSH username |

After raw settings, MacSCP merges `~/.ssh/config` for matching Host aliases, including **`Include`** directives (unless profile proxy is already set).

---

### Environment variables

| Variable | Purpose |
|---|---|
| `MACSCP_PASSPHRASE` | Default passphrase for encrypted private keys |
| `MACSCP_PROFILES` | Override path to saved profiles JSON |
| `MACSCP_KNOWN_HOSTS` | Override path to TOFU known-hosts JSON |
| `SSH_AUTH_SOCK` | SSH agent socket (standard OpenSSH) |

---

## Exit Codes

| Code | Meaning |
|---:|---|
| 0 | Success |
| 1 | Usage / invalid arguments |
| 2 | Connection failed (network, DNS, timeout, not connected) |
| 3 | Transfer failed |
| 4 | Authentication failed |
| 5 | Host key / certificate rejected or mismatch |
| 6 | Operation cancelled (reserved) |
| 10 | Partial success (script `option continue on` with failures) |

---

## Connection URLs

```text
sftp://[user[:password]@]host[:port][/path]
scp://[user@]host[:port][/path]
ftp://[user[:password]@]host[:port][/path]
ftps://[user@]host[:port][/path]
```

When `--session` is set, host/user/key/password come from the profile; an optional URL may supply only the initial remote path.

---

## Commands

### `open`

```bash
macscp open <url>
macscp open --session="Production Web API"
macscp open sftp://deploy@staging.example.com/var/www --batch
macscp open sftp://user@host --hostkey="SHA256:..." --privatekey=~/.ssh/id_ed25519
macscp open sftp://user@host --rawsettings ProxyJump=jump.host
```

| Option | Description |
|---|---|
| `--agent` | Use SSH agent (`SSH_AUTH_SOCK`) |
| `--password` | Password authentication |
| `--passive` / `--active` | FTP passive or active mode |
| `--implicit` / `--explicit` | FTPS implicit (990) or explicit TLS |
| `--batch` | Strict host keys (also global `--batch`) |

On connect: `--rawsettings` → merge `~/.ssh/config` (HostName, Port, User, IdentityFile, ProxyJump, **Include**). Proxy/jump sessions use Traversio.

**Not on CLI `open`:** nothing critical — use `--passive`, `--implicit`, etc. above for FTP/FTPS tuning.

---

### `close` / `ls` / `get` / `put`

```bash
macscp close
macscp ls [/remote/path] [--json]
macscp get <remote> [remote...] <local> [--resume] [--skip] [--checksum md5|sha256] [--transfer binary|ascii]
macscp put <local> <remote> [--resume] [--skip] [--checksum md5|sha256] [--transfer binary|ascii]
```

- **`get` with multiple remotes:** last argument must be an existing local directory.
- **Remote globs on `get`:** `*` and `?` in the final path component (lists parent directory).

- **`--resume`:** Resume partial transfer when local (download) or remote (upload) file is shorter than source. Works on Citadel and Traversio SFTP backends.
- **`--skip`:** Skip if destination exists (`OverwritePolicy.skip`).
- Paths resolve against the session remote cwd after `cd`.
- With **`--json`**, each transfer emits NDJSON lines on stdout (`transfer.start`, `transfer.progress`, `transfer.complete`; `transfer.error` on failure). `sync` adds `sync.preview`, `sync.start`, and `sync.complete`.

**JSON `ls` output:**

```json
{
  "entries": [
    {
      "name": "index.html",
      "path": "/var/www/index.html",
      "type": "file",
      "size": 4096,
      "permissions": "0644"
    }
  ],
  "path": "/var/www"
}
```

**NDJSON transfer events** (`--json` on `get`, `put`, `sync`):

```json
{"event":"transfer.start","timestamp":"2026-06-13T12:00:00Z","transferId":"…","direction":"download","remotePath":"/remote/file.txt","localPath":"/tmp/file.txt"}
{"event":"transfer.progress","timestamp":"…","transferId":"…","direction":"download","path":"/remote/file.txt","transferredBytes":1048576,"totalBytes":4194304,"bytesPerSecond":125000,"percentComplete":25}
{"event":"transfer.complete","timestamp":"…","transferId":"…","direction":"download","remotePath":"/remote/file.txt","localPath":"/tmp/file.txt","bytesTransferred":4194304,"checksum":null,"resumedFrom":null}
```

`sync --preview` emits `sync.preview`; a run emits `sync.start`, one transfer event sequence per file, then `sync.complete`. Connection lifecycle: `session.connected` / `session.disconnected` (field `protocolName`).

---

### `rm` / `mkdir` / `mv` / `chmod`

```bash
macscp rm <remote-path>
macscp mkdir <remote-path> [-p]
macscp mv <source> <destination>
macscp chmod <octal-mode> <remote-path>
```

`chmod` accepts **octal** modes only (e.g. `644`, `755`). Symbolic modes (`u+x`) are not parsed yet.

---

### `call`

```bash
macscp call stat /remote/file.txt
macscp call chmod 644 /remote/file.txt
```

| Subcommand | Status |
|---|---|
| `stat` | Supported (`--json` for RemoteEntry JSON) |
| `chmod` | Alias for `chmod` command |
| `chown` | Supported on SSH backends (`call chown owner[:group] path`); SFTP Citadel requires numeric uid/gid |

---

### `sync`

```bash
macscp sync <local> <remote> [options]
macscp sync ./public/ /var/www/html/ --mirror --delete
macscp sync ./public/ /var/www/html/ --mirror-remote --preview
macscp sync ./public/ /var/www/html/ --bidirectional --preview
```

| Option | Description |
|---|---|
| `--mirror` | Mirror local → remote (default one-way direction) |
| `--mirror-remote` | Mirror remote → local |
| `--bidirectional` | Upload newer local + download newer remote |
| `--delete` | Delete extraneous files on target side |
| `--preview` | Dry run; print counts only |
| `--filemask <mask>` | WinSCP-style include/exclude (see below) |
| `--criteria time\|size\|checksum` | Compare method (default: `time`) |
| `--delta` | rsync-style block delta for files ≥64 KB when both sides exist (SFTP) |

**File mask syntax:**

```text
*.html; *.css | *.tmp; .git/
```

Left of `|` = include globs; right = exclude.

**Criteria notes:**

- `time` — size + mtime (1 s tolerance), same as GUI default
- `size` — equal sizes → skip; else transfer
- `checksum` — size match + mtime within 1 s → skip; else re-transfer (no full remote hash fetch)

**Delta sync:** enable with `--delta` or `delta_sync = true` in `config.toml`. For files ≥64 KB where both local and remote copies exist, MacSCP computes an rsync-style block delta and uploads only changed regions (SFTP Citadel/Traversio). Falls back to full transfer when delta would send >90% of the file.

---

### `cd` / `lcd` / `pwd` / `lpwd`

```bash
macscp cd /var/www
macscp lcd ~/Projects/site
macscp pwd
macscp lpwd
```

Relative paths resolve against current remote/local cwd stored in the CLI session.

---

### `script`

```bash
macscp script deploy.macscp
macscp deploy.macscp          # equivalent
macscp --batch --ini none deploy.macscp
```

See [scripting.md](scripting.md). Script verbs: `open`, `close`, `ls`, `get`, `put`, `sync`, `cd`, `lcd`, `pwd`, `lpwd`, `rm`, `mkdir`, `mv`, `chmod`, `call`, `option`, `exit`.

---

### `version`

```bash
macscp version
macscp version --json    # {"version":"0.3.0"}
```

---

## Script `option` commands

| Option | Values | CLI status |
|---|---|---|
| `batch` | `on` / `off` | Supported |
| `confirm` | `on` / `off` | Parsed (overwrite prompts N/A in batch CLI) |
| `continue` | `on` / `off` | Supported — exit 10 on failures |
| `failonnomatch` | `on` / `off` | Supported for local globs on `put` |
| `transfer` | `binary` / `ascii` | Supported in scripts |
| `reconnecttime` | seconds | **Not implemented** |
| `connectiontimeout` | seconds | Use global `--timeout` instead |

---

## Examples

### CI deploy

```bash
export MACSCP_PASSPHRASE="${DEPLOY_KEY_PASSPHRASE}"

macscp \
  --batch \
  --ini none \
  --hostkey "SHA256:expectedFingerprintBase64=" \
  deploy.macscp
```

**deploy.macscp:**

```text
open sftp://deploy@staging.example.com -privatekey=./ci_ed25519
option batch on
cd /var/www/releases
put ./dist/* .
close
exit
```

### Profile one-liner

```bash
macscp --session="Production Web API" put ./app.zip /tmp/ --batch
```

---

## WinSCP Mapping (Quick Reference)

| WinSCP | macscp |
|---|---|
| `winscp.com /ini=nul script.txt` | `macscp --ini none script.txt` |
| `open sftp://...` | `open sftp://...` |
| `synchronize local remote` | `sync local remote --mirror` |
| `option batch on` | `option batch on` |
| `-hostkey=...` | `--hostkey ...` |

Full mapping: [scripting.md § WinSCP Compatibility](scripting.md#winscp-compatibility).

---

## Not yet implemented

| Feature | Workaround |
|---|---|
| `option reconnecttime` in scripts | Use `macscp --timeout` on the command line |
| Symbolic `chmod` (`u+x`) | Use octal modes |
| `call chown` on FTP/WebDAV/S3 | SSH backends only |
| Multi-source `put` to one remote dir | Loop in shell script |

---

## Files & Paths

| Path | Purpose |
|---|---|
| `~/Library/Application Support/MacSCP/profiles.json` | Saved sessions |
| `~/.macscp/config.toml` | Transfer/logging defaults (unless `--ini none`) |
| `~/.macscp/known_hosts.json` | Trusted host keys (GUI + CLI batch mode) |
| `~/.macscp/logs/` | Default log directory |

---

*End of CLI reference v0.3*
