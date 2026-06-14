# MacSCP User Guide

| Field | Value |
|---|---|
| Version | 0.3 |
| Applies to | MacSCP v0.3 developer preview |
| Related | [Product spec](spec.md) v0.3, [HLD](hld.md), [Apple Silicon performance](apple-silicon-performance.md) |

---

## 1. Introduction

MacSCP is an open-source, WinSCP-inspired SFTP client for macOS. It provides a **dual-pane commander** for browsing local and remote files, transferring data over SFTP, and managing saved connection profiles.

On Apple Silicon, MacSCP applies optional **transfer presets** (connection pooling, larger chunks, TCP tuning) to improve throughput without manual tuning.

This guide covers what is **implemented in v0.3**, including Phase 3 cloud protocols (WebDAV, S3, GCS), Finder Sync, AppleScript, optional iCloud profile sync, transfer history, queue notifications, and **Phase 4** features (tabs, explorer layout, integrated SSH pane, bidirectional sync, proxy/OpenSSH config, master password, encrypted profile export).

---

## 2. Requirements

| Requirement | Detail |
|---|---|
| macOS | 15 Sequoia or later |
| Hardware | Apple Silicon recommended; Intel via Rosetta where supported |
| Remote server | Any SFTP server (OpenSSH `sshd` is the reference) |
| Build (from source) | Swift 6.2+, Xcode 26+ (CI) or Xcode 16+ with Xcode 26 selected locally |

---

## 3. Installation (From Source)

```bash
git clone <repository-url> macscp
cd macscp
make build
make test    # 144 XCTest + 3 Swift Testing (+ make integration-test for live SFTP)
make check   # build + test (same as CI first step)
```

Run the app (starts local test SFTP server on port 2222):

```bash
make run
```

Or without Make:

```bash
swift build
swift test
swift run MacSCP
```

Useful development targets:

```bash
make paths    # config, log, profile, known-hosts paths
make config   # show ~/.macscp/config.toml
make logs     # tail today's log file
make ci       # check + SFTP benchmarks + pass-criteria verify (local CI parity)
```

A signed `.app` bundle and Homebrew cask/formula templates are available — see [packaging.md](packaging.md) and [packaging/homebrew/README.md](../packaging/homebrew/README.md).

---

## 4. Quick Start

### 4.1 Local Test Server (Optional)

For development and demos, MacSCP includes a local SFTP fixture:

```bash
make run
# or
./scripts/benchmark-env.sh start
swift run MacSCP
```

This starts OpenSSH on `127.0.0.1:2222` with key auth. The sample profile uses `.benchmark/keys/client_key`.

### 4.2 Connect to a Server

1. Launch **MacSCP**.
2. In the **Session Login** window, select or create a profile:
   - **Host Name** — server address (e.g. `server.example.com`)
   - **Port** — usually `22`
   - **Username** — your SSH user
   - **Authentication** — SSH key file, password, or SSH agent
3. Click **Login**.

For **SSH agent**, ensure `ssh-add -l` shows keys and `SSH_AUTH_SOCK` is set (macOS ssh-agent or 1Password agent). MacSCP uses the **Traversio** backend for agent sessions.

For **proxy or ProxyJump** (HTTP, SOCKS5, SSH bastion), MacSCP also uses **Traversio**. Set proxy in the connection form **Advanced → Proxy**, or rely on `~/.ssh/config` (see §12).

For **SSH key file** or **password**, MacSCP uses the **Citadel** backend by default when no proxy is configured.

On success, the **Commander** window opens with local files on the left and remote files on the right.

### 4.3 Transfer Files

1. **Navigate** — double-click folders to enter; use the **↑** button to go up.
2. **Select** — click one or more files or folders (Cmd-click for multi-select).
3. **Upload** — select local items, click **Upload** (or press **⇧⌘U**). Folders upload recursively.
4. **Download** — select remote items, click **Download** (or press **⇧⌘D**). Folders download recursively.
5. Watch progress in the **Transfers** panel at the bottom.

---

## 5. Session Profiles

### 5.1 Saving a Profile

1. Fill in connection details on the login screen.
2. Click **Save**.
3. The profile appears in the sidebar for reuse.

Profiles are stored in:

```text
~/Library/Application Support/MacSCP/profiles.json
```

### 5.2 Editing a Profile

Select a profile in the sidebar — the form updates. Change fields and click **Save** again.

### 5.3 Authentication and backends

| Method | Backend | Notes |
|---|---|---|
| SFTP | Citadel (default) / Traversio | Dual-pane commander, sync, queue |
| SCP | Traversio | Legacy SSH copy; remote listings via `ls` |
| FTP / FTPS | Native CFStream client | Password auth; passive mode; explicit + implicit TLS |
| SSH public key | Citadel (default) | Path to private key (e.g. `~/.ssh/id_ed25519`) |
| Password | Citadel (default) | Stored in macOS Keychain (not in profiles.json) |
| SSH agent | Traversio | Uses `SSH_AUTH_SOCK` (ssh-agent or 1Password agent) |
| Encrypted keys | Citadel / Traversio | Optional **Key Passphrase** field on login (stored in Keychain) |

**Optional:** set `use_traversio_for_performance = true` under `[transfer]` to route key/password sessions through Traversio for maximum throughput experiments. SSH agent sessions always use Traversio regardless of this flag.

### 5.4 Configuration and logs

MacSCP reads settings from `~/.macscp/config.toml` (created automatically on first launch).

**First launch on Apple Silicon:** a new config file is written with `preset = "apple_silicon"` and matching tuned numbers (pool size, 2 MB chunks, etc.). Intel Macs get `preset = "default"`.

Log files are written to:

```text
~/.macscp/logs/macscp-YYYY-MM-DD.log
```

The `logs` folder is created only when logging is enabled. Logs include connection events, transfers, and errors. Passwords and key passphrases are never written to log files.

Example `~/.macscp/config.toml`:

```toml
[logging]
enabled = true
level = "debug"        # debug | info | warn | error
retention_days = 14    # delete log files older than this (0 = keep all)
mirror_stderr = false

[transfer]
preset = "default"     # default | lan | wan | apple_silicon
max_concurrent_transfers = 2
max_concurrent_writes = 16
max_concurrent_reads = 8
max_concurrent_uploads = 12
chunk_size = 1048576
resume = true
verify_checksums = false
use_traversio_for_performance = false  # AGPL — see §11 slow uploads
```

**Preset cheat sheet:**

| Preset | Typical use | What changes |
|---|---|---|
| `default` | General / Intel Mac first launch | 1 MB chunks, modest concurrency |
| `lan` | Fast wired network | Higher concurrency, 2 MB chunks |
| `wan` | High latency / internet | Smaller chunks, single connection pool, conservative TCP |
| `apple_silicon` | M-series Mac (arm64 first launch) | 2–4 parallel SFTP connections, 2 MB chunks, tuned upload workers |

Presets apply tuned defaults for concurrency and chunk size. Explicit keys in the same `[transfer]` section override preset values.

**Other transfer options:**

| Key | Purpose |
|---|---|
| `verify_checksums` | When `true`, compute SHA-256 while uploading and compare with a full-file hash at the end (slight CPU cost) |
| `resume` | When `true`, partial downloads can continue from the last byte (default) |
| `max_concurrent_transfers` | Number of parallel SSH/SFTP connections for the queue (raised automatically by `apple_silicon` on arm64 unless you set a higher value) |

After editing `config.toml`, restart MacSCP or reconnect sessions for pool and preset changes to take effect.

See [Apple Silicon Performance Guide](apple-silicon-performance.md) and [code walkthrough §9](code-walkthrough.md) for implementation details.

Host keys use trust-on-first-use in `~/.macscp/known_hosts.json`. On first connect (or key change), MacSCP shows a **Host Key** sheet with the SHA-256 fingerprint — choose **Trust** or **Reject**. Pin a expected fingerprint in the profile **Advanced** field (`hostKeyFingerprint`) to enforce a specific key. CLI batch mode (`macscp-cli open --batch`) rejects unknown keys without prompting.

View today's log:

```bash
tail -f ~/.macscp/logs/macscp-$(date +%Y-%m-%d).log
```

---

## 6. Commander Interface

### 6.1 Layout

```text
┌──────────────────────────────────────────────────────────┐
│  ↑  ↻   Upload   Download   Sync   Terminal   Live Sync   [Queue: N]  │
├─────────────────────────┬────────────────────────────────┤
│ LOCAL                   │ REMOTE                         │
│ ~/path                  │ host:/remote/path              │
│                         │                                │
│  📁 folder              │  📁 folder                     │
│  📄 file.txt            │  📄 file.txt                   │
├─────────────────────────┴────────────────────────────────┤
│ Transfers — progress bars, pause, cancel                 │
├──────────────────────────────────────────────────────────┤
│ Status message                                           │
└──────────────────────────────────────────────────────────┘
```

### 6.2 Navigation

| Action | How |
|---|---|
| Enter folder | Double-click folder row |
| Go up | **↑** in pane header or toolbar |
| Refresh listing | **↻** in pane header or toolbar |
| Disconnect | **Disconnect** in window toolbar |

### 6.3 Selection

- **Single file** — click row
- **Multiple files** — Cmd-click or Shift-click
- Selection count appears in the toolbar

Only **files** transfer by default; **folders** can also be selected, dragged, or uploaded/downloaded recursively (preserving directory structure).

### 6.4 File operations (context menu)

Right-click a file or folder in either pane:

| Action | Local | Remote |
|---|---|---|
| **Rename** | Yes | Yes |
| **Delete** | Moves to Trash | Removes file or recursive directory |
| **Properties / chmod** | — | Octal permissions sheet |
| **Quick Look** | — | Preview remote file |
| **Edit (internal)** | — | In-app editor with encoding and line-ending options; Save uploads |
| **Edit (external)** | — | Download → external editor → re-upload on save |

### 6.5 Directory sync

1. Click **Sync** in the toolbar (or use the sync sheet).
2. MacSCP compares the current local and remote directories.
3. Review the diff table (new, newer, size mismatch).
4. Choose direction (local → remote or remote → local) and run sync or preview only.

### 6.6 Live sync, terminal, and lock

| Feature | How |
|---|---|
| **Live Sync** | Toolbar toggle — watches the local folder with FSEvents and uploads changed files |
| **Terminal** | Opens Terminal.app or iTerm2 with `ssh user@host` (uses profile settings) |
| **Touch ID lock** | Enable in login screen **Advanced** — requires authentication before connect |

### 6.7 Command-line tool (`macscp`)

```bash
make cli
./scripts/macscp open sftp://user@127.0.0.1:2222/ --batch
./scripts/macscp sync ./local /remote --mirror --delete --preview
./scripts/macscp --session="My Profile" ls /
make package-cli   # sudo: installs /usr/local/bin/macscp
```

Commands: `open`, `close`, `ls`, `get`, `put`, `sync`, `cd`, `lcd`, `pwd`, `lpwd`, `rm`, `mkdir`, `mv`, `chmod`, `call`, `script`, `version`. Global flags: `--session`, `--batch`, `--ini none`, `--hostkey`, `--timeout`, `--json`, `--quiet`. Run `macscp script.macscp` or `macscp script script.macscp`.

Release `.app` bundles the same CLI at `MacSCP.app/Contents/MacOS/macscp`. Swift package product: **`macscp-cli`**. See [cli-reference.md](cli-reference.md).

Supported `open` URLs: `sftp://`, `scp://`, `ftp://`, `ftps://`.

### 6.8 Shortcuts and deep links

MacSCP registers App Shortcuts for:

- **Connect to Session** — profile name
- **Upload File** / **Download File** — profile + paths
- **Sync Directories** — compare and sync (one-way mirror or bidirectional)
- **Run MacSCP Script** — `.macscp` file path

Deep link to a saved profile:

```text
macscp://open?session=<profile-uuid>
```

The app also handles `sftp://user@host/path` URLs when registered as the default handler.

---

## 7. Transferring Files

### 7.1 Upload (Local → Remote)

Uploads copy selected local files and folders to the **current remote directory**. Folder uploads preserve relative paths under the remote pane's current path.

**Toolbar:** Upload button or **⇧⌘U**

**Drag-and-drop:** Drag files or folders from the **LOCAL** pane and drop onto the **REMOTE** pane.

### 7.2 Download (Remote → Local)

Downloads copy selected remote files and folders to the **current local directory**. Folder downloads recreate the tree under the local pane's current path.

**Toolbar:** Download button or **⇧⌘D**

**Drag-and-drop:** Drag files or folders from the **REMOTE** pane and drop onto the **LOCAL** pane.

### 7.3 Folder Transfers

- Selecting a folder queues all nested **files** (symlinks are skipped on download).
- Parent directories are created automatically on the destination side.
- Overwrite prompts apply per file when names conflict.
- Very large local folder trees are scanned on a background task before jobs appear in the queue (the UI stays responsive).

### 7.4 Drag-and-Drop Tips

- Dragging within the same pane does nothing (not supported).
- A blue dashed border shows valid drop targets.
- Multi-select files and folders before dragging to transfer several items at once.
- Dropping triggers the same overwrite checks as toolbar transfers.

---

## 8. Overwrite Prompts

When a file with the **same name** already exists at the destination, MacSCP shows a confirmation sheet:

| Option | Behavior |
|---|---|
| **Overwrite All** | Replace existing files |
| **Skip Existing** | Skip conflicting files (shown as *Skipped* in queue) |
| **Rename All** | Save as `filename (1).ext`, `filename (2).ext`, … |
| **Cancel** | Abort the entire batch |

Non-conflicting files in the same batch transfer normally without prompting.

---

## 9. Transfer Queue

The **Transfers** panel shows all active and recent jobs.

### 9.1 Job States

| State | Meaning |
|---|---|
| Queued | Waiting for a transfer slot |
| Running | Transfer in progress |
| Paused | Queue paused (global) |
| Done | Completed successfully |
| Skipped | Skipped due to overwrite policy |
| Cancelled | Stopped by user |
| Failed | Error (message shown) |

### 9.2 Controls

| Control | Action |
|---|---|
| **Pause** | Pause starting new jobs; running jobs marked paused |
| **Resume** | Resume queue processing |
| **Clear Done** | Remove finished/cancelled/failed/skipped jobs |
| **×** (per job) | Cancel that job |

### 9.3 Progress

Each running job shows:

- Progress bar (bytes transferred / total)
- Transfer speed (MB/s or KB/s)
- ETA when estimable

Up to **2 transfers** run concurrently by default (`max_concurrent_transfers = 2`). With `preset = "apple_silicon"` on Apple Silicon, MacSCP may raise the pool to **2–4** connections based on CPU cores unless you set `max_concurrent_transfers` explicitly in config.

### 9.4 Cancelling a Transfer

Click **×** on a running job. MacSCP signals the backend to stop; the job moves to **Cancelled**. Very small files may finish before cancel takes effect.

---

## 10. Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| **⇧⌘N** | New Connection (login sheet) |
| **⌘T** / **⇧⌘T** | New session tab |
| **⌘W** / **⇧⌘W** | Close session tab |
| **⇧⌘U** | Upload selected local files |
| **⇧⌘D** | Download selected remote files |
| **Space** | Quick Look preview (remote file) |
| Type-ahead | Start typing in a pane to jump to matching names |
| **⌘↑** | Go to parent directory (local or remote pane) |

---

## 11. Troubleshooting

### Connection Failed

| Symptom | Things to check |
|---|---|
| Timeout | Host reachable? Port 22 open? Firewall? |
| Auth failed | Username, key path, password, or agent keys correct? |
| Agent empty | Run `ssh-add -l`; ensure `SSH_AUTH_SOCK` is set |
| Key not accepted | Server has your public key in `authorized_keys`? |
| Host key error | First connect stores TOFU in `~/.macscp/known_hosts.json`; pin fingerprint in profile advanced settings |
| Proxy / jump fails | Verify bastion reachable; check `~/.ssh/config` ProxyJump chain; profile proxy overrides config |

Test SSH manually:

```bash
ssh -p 22 user@host
sftp user@host
```

### Remote List Empty or Wrong Path

- Check the path in the remote pane header.
- Use **↑** to navigate to `/` and browse down.
- Set **Initial Remote Path** in profile advanced settings (when available).

### Transfer Failed

- Verify write permission on remote path (upload) or local folder (download).
- Check available disk space.
- Retry after cancel; **resume** is enabled for partial downloads when `resume = true` in config.

### Slow Uploads or Downloads

MacSCP optimizes SFTP throughput in several ways:

1. **Presets** — `lan`, `wan`, or `apple_silicon` in `~/.macscp/config.toml` adjust chunk sizes, concurrency, and (for Citadel) TCP socket buffers after connect.
2. **Connection pool** — when `max_concurrent_transfers` > 1, parallel queue jobs use separate SSH sessions instead of blocking each other.
3. **Pipelined I/O** — Citadel backends issue multiple SFTP READ/WRITE requests in flight when `max_concurrent_reads` / `max_concurrent_writes` > 1.
4. **Listing cache** — remote directory listings are cached briefly (3 seconds) to speed up repeated browsing and folder uploads.
5. **Large local files** — files ≥ 256 KB are read via memory mapping on upload for lower overhead.

**Quick fixes to try:**

| Goal | Config change |
|---|---|
| Faster on M-series Mac | `preset = "apple_silicon"` (auto on first launch) |
| Saturate a fast LAN | `preset = "lan"` or raise `max_concurrent_uploads` |
| Stable on slow internet | `preset = "wan"` |
| Experiment with Traversio throughput | `use_traversio_for_performance = true` (AGPL; key/password only) |

**Presets:** see [Apple Silicon Performance Guide](apple-silicon-performance.md).

**Traversio performance mode:** `use_traversio_for_performance = true` switches key/password sessions to Traversio. SSH agent and **proxy** sessions always use Traversio.

**Benchmarks (developers):** compare MacSCP against OpenSSH on loopback:

```bash
make bench-apple-silicon
make bench-verify    # fails if below spec pass criteria (large ≥ 0.90×, small ≥ 0.80× OpenSSH)
```

Details: [SFTP backend spike](spikes/sftp-backend-spike.md).

---

## 12. Phase 3 Features

### Cloud protocols (WebDAV, S3, GCS)

Choose **WebDAV**, **Amazon S3**, or **Google Cloud Storage** in the connection form. For object storage, use access key ID as username and secret as password. Path `/bucket/prefix` sets the default remote location; optional **Bucket** and **Region** fields override path parsing.

URL schemes: `https://user@host/path` (WebDAV), `s3://KEY:SECRET@/bucket/prefix`, `gcs://KEY:SECRET@/bucket/prefix`.

### Optional app features (`~/.macscp/config.toml` `[app]` section)

| Setting | Description |
|---|---|
| `transfer_history = true` | Append completed transfers to `~/.macscp/transfer-history.json` |
| `notify_on_queue_complete = true` | Notification Center alert when the queue goes idle |
| `icloud_profile_sync = true` | Encrypt and sync saved profiles via iCloud Drive (opt-in) |

Toggles are also available under **Optional Features** in the connection form.

### Finder Sync extension

When packaged with `make package-dmg`, MacSCP embeds a Finder Sync extension. Right-click files in synced local folders for **Upload to MacSCP (session)…**. The active session name and local pane path are shared via app group `group.com.macscp.app`.

Enable the extension in **System Settings → Privacy & Security → Extensions → Finder Extensions**.

### AppleScript

Dictionary: `MacSCP.sdef` (embedded in the app bundle). Commands:

```applescript
tell application "MacSCP"
    connect "Staging"
    upload local path "~/Sites/index.html" remote path "/var/www/index.html"
    download remote path "/var/log/app.log" local path "~/Downloads/app.log"
    disconnect
end tell
```

---

### Proxy and ProxyJump

MacSCP reads `~/.ssh/config` when connecting, including **`Include`** directives. If your profile host matches a `Host` alias, MacSCP applies `HostName`, `Port`, `User`, `IdentityFile`, and `ProxyJump` from matching blocks (profile proxy settings take precedence over config).

In the connection form, set **Proxy → Jump host** to connect through a bastion without editing `~/.ssh/config`. Jump connections use the Traversio backend automatically.

CLI equivalent:

```bash
macscp-cli open sftp://deploy@production/var/www --rawsettings ProxyJump=jump1,jump2
```

`ProxyCommand` from `~/.ssh/config` is merged into the session and executed at connect time (local TCP relay to the subprocess). You can also pass it explicitly:

```bash
macscp-cli open sftp://deploy@production --rawsettings proxycommand='ssh -W %h:%p bastion'
```

---

## 13. Phase 4 Features

### Multi-session tabs

Use **⌘T** to open a new tab and **⌘W** to close the active tab. Each tab maintains its own connection and remote path. Tab titles and pane paths **persist across relaunch** when `persist_tabs = true` in `[app]` (default); sessions are not auto-reconnected. Toolbar **back/forward** navigates local and remote history.

### Explorer layout

In the connection form, choose **Layout → Explorer** for a single remote tree with integrated local browsing (alternative to dual-pane Commander).

### Integrated SSH pane

When connected, open the embedded SSH command pane from the toolbar to run remote shell commands in-session (distinct from Terminal/iTerm hand-off).

### Bidirectional sync

**Sync Directories** supports mirror local→remote, mirror remote→local, and **bidirectional** compare (upload + download changed files). CLI: `macscp sync --bidirectional`.

### Master password and encrypted export

Optional master password protects encrypted profile export/import. Enable in login **Advanced**; export from the profile menu.

### Proxy settings (UI)

Connection form **Advanced → Proxy**: HTTP CONNECT, SOCKS5, or SSH jump host. Comma-separated hosts define a ProxyJump chain. Overrides are preserved over `~/.ssh/config`.

---

## 14. What's Not in This Release

The following remain **planned** or require distribution signing:

- **Mac App Store** build with full sandbox product
- **Full WinSCP script parity** (symbolic chmod, `option reconnecttime`, symlinks via `call`)

---

## 15. Getting Help

| Resource | Link |
|---|---|
| Product specification | [spec.md](spec.md) |
| Architecture (HLD) | [hld.md](hld.md) |
| Apple Silicon tuning | [apple-silicon-performance.md](apple-silicon-performance.md) |
| Code tour (developers) | [code-walkthrough.md](code-walkthrough.md) |
| Developer / protocol docs | [README.md](../README.md) |
| Issues | Project issue tracker (when published) |

---

## 16. Appendix: Sample Workflows

### Deploy a Single File to Staging

1. Connect to staging profile.
2. Local pane: navigate to project build output.
3. Remote pane: navigate to web root (e.g. `/var/www/html`).
4. Select `app.js`, click **Upload**.
5. Confirm overwrite if the file exists.

### Pull Logs from a Server

1. Connect to production (read-only user recommended).
2. Remote pane: open `/var/log/myapp`.
3. Select `*.log` files.
4. Local pane: navigate to `~/Downloads/logs`.
5. Click **Download**.

### Cancel a Long Upload

1. Start upload of a large file.
2. In Transfers panel, click **×** on the job.
3. Status changes to **Cancelled**; remote may contain a partial file depending on server behavior.

### Tune Transfer Performance on Apple Silicon

1. Quit MacSCP if running.
2. Edit `~/.macscp/config.toml` — confirm or set:

   ```toml
   [transfer]
   preset = "apple_silicon"
   ```

3. Relaunch and reconnect. The app opens multiple SFTP connections when the queue has parallel jobs.
4. Optional: enable `verify_checksums = true` when uploading critical files.

---

*End of user guide v0.3*
