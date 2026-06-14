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
| `--loglevel <level>` | Parsed (`debug`, `info`, `warning`, `error`); wiring to file logger is partial |
| `--logfile <path>` | Parsed; full structured log append not yet wired |
| `--json` | JSON for `ls`, `call stat`, `version`; NDJSON event stream for `get`, `put`, `sync`, `open`, `close` |
| `--quiet` / `-q` | Suppress non-error stdout |
| `--batch` | Strict host keys; no interactive trust prompts |
| `--hostkey <fingerprint>` | Expected host key (repeatable; last value wins on `open`) |
| `--timeout <seconds>` | Sets `AdvancedSettings.connectionTimeoutSeconds` on connect |

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
| `SSH_AUTH_SOCK` | SSH agent socket (standard OpenSSH) |

Not yet implemented: `MACSCP_PROFILES`, `MACSCP_KNOWN_HOSTS` overrides.

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
| `--batch` | Strict host keys (also global `--batch`) |

On connect: `--rawsettings` → merge `~/.ssh/config` (HostName, Port, User, IdentityFile, ProxyJump, **Include**). Proxy/jump sessions use Traversio.

**Not on CLI `open` yet:** FTP `-passive`, FTPS `-explicit`/`-implicit` (use saved profiles or URLs).

---

### `close` / `ls` / `get` / `put`

```bash
macscp close
macscp ls [/remote/path] [--json]
macscp get <remote> <local> [--resume] [--skip] [--checksum md5|sha256] [--transfer binary|ascii]
macscp put <local> <remote> [--resume] [--skip] [--checksum md5|sha256] [--transfer binary|ascii]
```

- **`--resume`:** Resume partial transfer when local (download) or remote (upload) file is shorter than source. Works on Citadel and Traversio SFTP backends.
- **`--skip`:** Skip if destination exists (`OverwritePolicy.skip`).
- Paths resolve against the session remote cwd after `cd`.
- With **`--json`**, each transfer emits NDJSON lines on stdout (`transfer.start`, `transfer.progress`, `transfer.complete`; `transfer.error` on failure). `sync` adds `sync.preview`, `sync.start`, and `sync.complete`.

**Not yet:** multi-source `get`/`put` (last arg = directory), remote globs on `get`.

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

**File mask syntax:**

```text
*.html; *.css | *.tmp; .git/
```

Left of `|` = include globs; right = exclude.

**Criteria notes:**

- `time` — size + mtime (1 s tolerance), same as GUI default
- `size` — equal sizes → skip; else transfer
- `checksum` — size match + mtime within 1 s → skip; else re-transfer (no full remote hash fetch)

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
| `MACSCP_PROFILES` / `MACSCP_KNOWN_HOSTS` env | Default Application Support paths |
| FTP passive / FTPS modes on CLI `open` | Saved GUI profile or extend `open` |
| WebDAV / S3 `chmod` | WebDAV PROPPATCH; S3 PutObjectAcl (canned ACL mapping) |
| `call chown` on FTP/WebDAV/S3 | Not available (SSH backends only) |
| Multi-file `get` with glob | Loop in shell script |

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
