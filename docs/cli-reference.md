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
```

The `macscp` command-line tool provides scriptable file transfers and shares the session profile store with the MacSCP GUI. Syntax is intentionally close to [WinSCP scripting](https://winscp.net/eng/docs/scripting) where practical.

---

## Synopsis

```bash
macscp [--version] [--help] [GLOBAL OPTIONS] <command> [ARGS]
macscp [--version] [--help] [GLOBAL OPTIONS] /path/to/script.macscp
```

Invoking `macscp` with a `.macscp` script path as the sole argument is equivalent to `macscp script /path/to/script.macscp`.

---

## Global Options

| Option | Short | Description |
|---|---|---|
| `--session <name\|uuid>` | `-session` | Use saved profile from GUI store (password/key from Keychain) |
| `--ini <path>` | | Preferences file path. Use `none` to ignore GUI prefs (WinSCP `/ini=nul` equivalent) |
| `--loglevel <level>` | | `error`, `warn`, `info`, `debug` (default: `info`) |
| `--logfile <path>` | | Append structured log to file |
| `--json` | | Machine-readable output on stdout where supported |
| `--quiet` | `-q` | Suppress non-error stdout |
| `--batch` | | Never prompt; fail on ambiguity (for CI) |
| `--hostkey <fingerprint>` | | Accept only this host key (SHA256 base64 or MD5 hex). Repeatable |
| `--privatekey <path>` | | SSH private key path |
| `--passphrase <string>` | | Key passphrase (prefer `MACSCP_PASSPHRASE` env or Keychain) |
| `--timeout <seconds>` | | Connection timeout (default: 30) |
| `--rawsettings` | | Pass backend-specific settings (see below) |

### Environment Variables

| Variable | Purpose |
|---|---|
| `MACSCP_PASSPHRASE` | Default passphrase for encrypted private keys |
| `MACSCP_PROFILES` | Override profiles directory |
| `MACSCP_KNOWN_HOSTS` | Override known_hosts path |
| `SSH_AUTH_SOCK` | SSH agent socket (standard OpenSSH) |

---

## Exit Codes

| Code | Meaning |
|---:|---|
| 0 | Success |
| 1 | Usage / invalid arguments |
| 2 | Connection failed (network, DNS, timeout) |
| 3 | Transfer failed (one or more files) |
| 4 | Authentication failed |
| 5 | Host key / certificate rejected or mismatch |
| 6 | Operation cancelled (SIGINT) |
| 10 | Partial success (some transfers failed; see `--json` details) |

---

## Connection URLs

Commands that accept a remote location use URL-style paths:

```text
sftp://[user[:password]@]host[:port][/path]
scp://[user@]host[:port][/path]
ftp://[user[:password]@]host[:port][/path]
ftps://[user@]host[:port][/path]
```

When `--session` is set, host/user/key/password are taken from the profile; a URL may supply only the initial remote path.

---

## Commands

### `open`

Open a session. Required before other remote commands unless URL/session is implied.

```bash
macscp open <url>
macscp open sftp://deploy@staging.example.com/var/www -session="Production Web API"
macscp open sftp://user@host -hostkey="SHA256:abcdef..." -batch
```

| Option | Description |
|---|---|
| `-passive` | FTP passive mode (default for FTP) |
| `-explicit` / `-implicit` | FTPS mode |
| `-rawsettings ProxyJump=jump.host` | OpenSSH-style raw settings |

**Exit:** 0 connected; 2/4/5 on failure.

---

### `close`

Close the active session.

```bash
macscp close
```

---

### `ls`

List remote directory.

```bash
macscp ls [/remote/path]
macscp ls /var/www --json
```

**JSON output (`--json`):**

```json
{
  "path": "/var/www",
  "entries": [
    {
      "name": "index.html",
      "type": "file",
      "size": 4096,
      "modified": "2026-06-12T14:30:00Z",
      "permissions": "0644"
    }
  ]
}
```

---

### `get`

Download remote file(s) to local path.

```bash
macscp get /remote/file.txt ./local/
macscp get /remote/*.log ./logs/ -resume
macscp get /remote/big.iso ./ -checksum=sha256
```

| Option | Description |
|---|---|
| `-resume` | Resume partial download if local file exists |
| `-overwrite` | Overwrite without prompt (default in `--batch`) |
| `-skip` | Skip existing files |
| `-checksum <alg>` | Verify after transfer (`md5`, `sha256`) |
| `-transfer=binary\|ascii` | Transfer mode where protocol supports |

Multiple sources: last argument is destination directory.

---

### `put`

Upload local file(s) to remote path.

```bash
macscp put ./build/* /remote/releases/
macscp put ./config.json /etc/app/config.json -resume
```

Same transfer options as `get`.

---

### `rm`

Delete remote file(s).

```bash
macscp rm /remote/file.txt
macscp rm /remote/cache/*
```

---

### `mkdir`

Create remote directory (creates parents with `-p`).

```bash
macscp mkdir /remote/new/dir
macscp mkdir -p /remote/a/b/c
```

---

### `mv`

Rename or move remote file.

```bash
macscp mv /remote/old.txt /remote/new.txt
```

---

### `chmod`

Change remote permissions.

```bash
macscp chmod 644 /remote/file.txt
macscp chmod 755 /remote/scripts/*.sh
```

Accepts octal mode or symbolic (`u+x`).

---

### `call`

Execute backend-specific subcommand.

```bash
macscp call chmod 644 /remote/file.txt   # alias for chmod
macscp call chown user:group /remote/file
macscp call stat /remote/file.txt
```

`stat` with `--json`:

```json
{
  "path": "/remote/file.txt",
  "size": 1024,
  "modified": "2026-06-13T10:00:00Z",
  "permissions": "0644",
  "owner": "deploy",
  "group": "www-data"
}
```

---

### `sync`

Synchronize local and remote directories.

```bash
macscp sync <local> <remote> [options]
macscp sync ./public/ /var/www/html/ -mirror -delete
macscp sync ./public/ /var/www/html/ -preview
```

| Option | Description |
|---|---|
| `-mirror` | Mirror source → target (source is first path) |
| `-direction=local\|remote` | Explicit sync direction |
| `-delete` | Delete extraneous files on target |
| `-preview` | Dry run; print planned actions only |
| `-filemask <mask>` | Include/exclude glob (see below) |
| `-criteria=time\|size\|checksum` | Compare method (default: `time`) |

**File mask syntax** (WinSCP-compatible subset):

```text
*.html; *.css | *.tmp; .git/
```

Left of `|` = include; right = exclude.

---

### `option`

Set session or transfer option.

```bash
macscp option batch on
macscp option confirm off
macscp option transfer binary
macscp option reconnecttime 120
```

| Option | Values | Description |
|---|---|---|
| `batch` | `on` / `off` | Same as global `--batch` |
| `confirm` | `on` / `off` | Confirm overwrites/deletes |
| `transfer` | `binary` / `ascii` | Default transfer mode |
| `reconnecttime` | seconds | Auto-reconnect interval |
| `connectiontimeout` | seconds | Connect timeout |

---

### `pwd` / `lpwd`

Print remote or local working directory.

```bash
macscp pwd
macscp lpwd
```

---

### `cd` / `lcd`

Change remote or local working directory.

```bash
macscp cd /var/www
macscp lcd ~/Projects/site
```

Relative paths resolve against current remote/local cwd.

---

### `script`

Execute a script file.

```bash
macscp script deploy.macscp
macscp script deploy.macscp -logfile=deploy.log
```

See [scripting.md](scripting.md) for script syntax.

---

### `version`

Print version and build info.

```bash
macscp version
macscp version --json
```

---

## Examples

### CI deploy (non-interactive)

```bash
#!/bin/bash
set -euo pipefail

export MACSCP_PASSPHRASE="${DEPLOY_KEY_PASSPHRASE}"

macscp \
  --batch \
  --ini none \
  --hostkey "SHA256:expectedFingerprintBase64=" \
  /usr/local/share/macscp/deploy.macscp
```

**deploy.macscp:**

```text
open sftp://deploy@staging.example.com -privatekey=./ci_ed25519
option batch on
option confirm off
cd /var/www/releases
put ./dist/* .
call ln -sf /var/www/releases/current /var/www/live
close
exit
```

### One-liner upload

```bash
macscp -session="Production Web API" put ./app.zip /tmp/ -batch
```

### Sync with preview

```bash
macscp -session="Production Web API" sync ./build/ /var/www/ -mirror -preview
```

---

## WinSCP Mapping (Quick Reference)

| WinSCP | macscp |
|---|---|
| `winscp.com /ini=nul script.txt` | `macscp --ini none script.txt` |
| `open sftp://...` | `open sftp://...` |
| `get file .` | `get file .` |
| `put local remote` | `put local remote` |
| `synchronize local remote` | `sync local remote -mirror` |
| `option batch on` | `option batch on` |
| `-hostkey=...` | `--hostkey ...` |
| `exit` | `exit` |

Full mapping: [scripting.md § WinSCP Compatibility](scripting.md#winscp-compatibility).

---

## JSON Event Stream (Advanced)

With `--json`, long operations emit newline-delimited JSON events:

```json
{"type":"transfer_start","id":"t1","direction":"upload","remote":"/var/www/a.js","size":8192}
{"type":"transfer_progress","id":"t1","transferred":4096,"speed_bps":1048576}
{"type":"transfer_complete","id":"t1","checksum":"sha256:abc..."}
{"type":"summary","succeeded":1,"failed":0,"duration_ms":1200}
```

---

## Files & Paths

| Path | Purpose |
|---|---|
| `~/Library/Application Support/MacSCP/profiles.json` | Saved sessions |
| `~/Library/Application Support/MacSCP/known_hosts` | Trusted host keys |
| `~/Library/Logs/MacSCP/` | Default log directory (GUI + CLI) |

---

*End of CLI reference v0.1*
