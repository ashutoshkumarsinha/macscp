# MacSCP Scripting Guide

| Field | Value |
|---|---|
| Version | 0.3 |
| Related | [cli-reference.md](cli-reference.md), [spec.md §4.2](spec.md) |

MacSCP scripts (`.macscp`) are line-oriented command files for automated transfers. They mirror [WinSCP scripting](https://winscp.net/eng/docs/scripting) closely enough that many existing WinSCP scripts can be adapted with minimal edits.

---

## Script Basics

```text
# Deploy static site to staging
# Comments start with #

open sftp://deploy@staging.example.com -session="Staging"
option batch on
option confirm off

cd /var/www/html
lcd ~/Projects/website/dist
put *
close
exit
```

| Rule | Detail |
|---|---|
| Encoding | UTF-8 |
| Line endings | LF or CRLF |
| Commands | One command per line; args space-separated |
| Quoting | Use double quotes for paths with spaces |
| Exit | Script ends at `exit` or EOF |
| Errors | Non-zero exit unless `option continue on` |

Run:

```bash
macscp script deploy.macscp
macscp --ini none --batch deploy.macscp   # isolated, CI-safe
```

---

## Commands

Script verbs match the [CLI command set](cli-reference.md#commands). Global-only flags (`--json`, `--logfile`, `--timeout`) belong on the `macscp` invocation line, not inside the script.

### Session lifecycle

```text
open sftp://user@host:22/path
open sftp://user@host -session=ProfileName
open sftp://user@host -privatekey=~/.ssh/id_ed25519 -passphrase=***
open sftp://user@host -agent -batch -hostkey=SHA256:...
open sftp://user@host -rawsettings=ProxyJump=bastion
close
exit
```

### Navigation

```text
cd /remote/path
lcd /local/path
pwd
lpwd
```

### Transfers

```text
get /remote/file.txt ./local/
put ./build/app.zip /remote/releases/
rm /remote/old.txt
mkdir /remote/new
mkdir -p /remote/a/b/c
mv /remote/a.txt /remote/b.txt
chmod 644 /remote/config.yml
call stat /remote/config.yml
```

Use `option transfer binary` (or `ascii`) before `get`/`put` for transfer mode. Resume: add `-resume` on script `get`/`put` lines (not yet a global script default).

### Synchronization

```text
sync ./public/ /var/www/html/ -mirror -delete
sync ./public/ /var/www/html/ -mirror-remote -preview
sync ./public/ /var/www/html/ -bidirectional
sync ./public/ /var/www/ -filemask="*.html; *.css|*.tmp" -criteria=time
```

Script flags use WinSCP-style `-flag` tokens on the `sync` line (`-mirror`, `-delete`, `-preview`, `-bidirectional`, `-filemask=…`, `-criteria=…`).

### Options

```text
option batch on
option confirm off
option continue on
option failonnomatch on
option transfer binary
```

| Option | Status |
|---|---|
| `batch`, `confirm`, `continue`, `failonnomatch`, `transfer` | Supported |
| `reconnecttime`, `connectiontimeout` | **Not implemented** — use `macscp --timeout` on the command line |

---

## Open Command Switches

Script `open` supports inline switches (WinSCP-style):

```text
open sftp://user:pass@host -hostkey="ssh-ed25519 255 ..."
open sftp://user@host -privatekey="~/.ssh/id_ed25519" -passphrase=***
open ftps://user@host -explicit -passive=on
```

| Switch | Description |
|---|---|
| `-session=<name>` | Load saved profile |
| `-privatekey=<path>` | SSH private key |
| `-passphrase=<value>` | Key passphrase (avoid in committed scripts) |
| `-hostkey=<fp>` | Expected host key fingerprint |
| `-agent` | SSH agent |
| `-batch` | Strict host keys |
| `-rawsettings=<k=v>` | ProxyJump, HostName, Port, User |

---

## WinSCP Compatibility

### Direct equivalents

| WinSCP script | MacSCP script |
|---|---|
| `open sftp://user@host/` | `open sftp://user@host/` |
| `lcd C:\local` | `lcd /Users/me/local` |
| `cd /remote` | `cd /remote` |
| `put -resume` | `put ... -resume` |
| `get -delete` | _Use `sync -delete` instead_ |
| `call chmod 644 file` | `call chmod 644 file` |
| `option batch on` | `option batch on` |
| `synchronize remote local` | `sync local remote -mirror -direction=remote` |
| `synchronize local remote` | `sync local remote -mirror` |
| `keepuptodate` | GUI **Live Sync** (FSEvents); no CLI `watch` yet |

### Commands not supported (v0.3)

| WinSCP | MacSCP alternative |
|---|---|
| `call chown` | SSH/SCP backends; numeric uid/gid on Citadel SFTP |
| `call ln -sf …` | Use `mv` or shell out manually |
| Remote globs on `get` | Loop in shell |
| `option reconnecttime` | Not implemented |
| `ProxyCommand` in ssh config | Merged from config; or `-rawsettings=proxycommand=…` |
| `keepuptodate` | GUI **Live Sync**; no CLI `watch` yet |

### Migration checklist

1. Replace Windows paths (`C:\...`) with POSIX paths.
2. Replace `winscp.com /ini=nul` with `macscp --ini none`.
3. Verify `-hostkey` fingerprint format (MacSCP accepts SHA256 or MD5).
4. Remove WinSCP-only options (`reconnecttime` — use `macscp --timeout`).
5. Test with `-preview` on `sync` before `-delete`.

---

## Example Scripts

### Nightly backup

```text
# backup.macscp
open sftp://backup@nas.local -session="Home NAS"
option batch on
lcd ~/Documents
cd /backups/macbook
put -resume *.tar.gz
close
exit
```

### Staged deploy with dry run

```text
open sftp://deploy@prod.example.com -session="Production Web API"
option batch on
option confirm off

lcd ./dist
cd /var/www/releases/2026-06-13

# Preview sync
sync . . -mirror -preview

# Uncomment after review:
# sync . . -mirror
# call ln -sfn /var/www/releases/2026-06-13 /var/www/current

close
exit
```

### CI/CD (credentials from env)

```text
# ci-upload.macscp — invoke with MACSCP_PASSPHRASE set
open sftp://ci@build.example.com -privatekey=./ci_key -hostkey="SHA256:xxx"
option batch on
option confirm off
put ./artifact.zip /incoming/
exit
```

---

## Error Handling

Default: first failing command aborts script with that command's exit code.

Supported script options:

```text
option continue on          # log errors, continue
option failonnomatch on     # globs must match at least one file
```

Bidirectional sync from CLI: `macscp sync --bidirectional` (see [cli-reference.md](cli-reference.md)).

Log failed transfers to stderr; use `--logfile` for audit trail.

---

## Security Notes

- Do not commit passphrases or passwords in scripts; use `--session`, Keychain, or env vars.
- Prefer `--hostkey` in CI over `StrictHostKeyChecking=no`.
- Use `--ini none` so GUI preference changes cannot break automation (WinSCP documented pitfall).

---

## AppleScript (macOS app)

The MacSCP app ships an AppleScript dictionary (`MacSCP.sdef`) with four commands:

| Command | Parameters |
|---|---|
| `connect` | profile name (direct parameter) |
| `disconnect` | — |
| `upload` | `local path`, `remote path` |
| `download` | `remote path`, `local path` |

Example:

```applescript
tell application "MacSCP"
    connect "Production"
    upload local path "~/build/app.zip" remote path "/srv/releases/app.zip"
    disconnect
end tell
```

When a session is already connected in the GUI, upload/download use the active backend instead of opening a new connection.

---

*End of scripting guide v0.3*
