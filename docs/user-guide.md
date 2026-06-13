# MacSCP User Guide

| Field | Value |
|---|---|
| Version | 0.2 |
| Applies to | MacSCP Phase 0–1 (developer preview) |
| Related | [Product spec](spec.md), [HLD](hld.md) |

---

## 1. Introduction

MacSCP is an open-source, WinSCP-inspired SFTP client for macOS. It provides a **dual-pane commander** for browsing local and remote files, transferring data over SFTP, and managing saved connection profiles.

This guide covers what is **implemented today**. Features listed in the [product spec](spec.md) but not yet built (sync, remote editor, CLI, tabs) are noted where relevant.

---

## 2. Requirements

| Requirement | Detail |
|---|---|
| macOS | 15 Sequoia or later |
| Hardware | Apple Silicon recommended; Intel via Rosetta where supported |
| Remote server | Any SFTP server (OpenSSH `sshd` is the reference) |
| Build (from source) | Swift 6.0+, Xcode 16+ or Swift toolchain |

---

## 3. Installation (From Source)

```bash
git clone <repository-url> macscp
cd macscp
make build
make test
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
```

A future release will ship as a signed `.app` bundle or Homebrew cask.

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

For **SSH agent**, ensure `ssh-add -l` shows keys and `SSH_AUTH_SOCK` is set (macOS ssh-agent or 1Password agent). MacSCP uses the Traversio backend for agent sessions.

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

### 5.3 Authentication

| Method | Status | Notes |
|---|---|---|
| SSH public key | Supported | Path to private key (e.g. `~/.ssh/id_ed25519`) |
| Password | Supported | Stored in macOS Keychain (not in profiles.json) |
| SSH agent | Supported | Uses `SSH_AUTH_SOCK` (ssh-agent); connects via Traversio backend |
| Encrypted keys | Backend supports | Passphrase field coming in UI |

### 5.4 Logs

MacSCP reads logging settings from `~/.macscp/config.toml` (created automatically on first launch). Log files are written to:

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
max_concurrent_transfers = 2
max_concurrent_writes = 8
max_concurrent_reads = 8
max_concurrent_uploads = 8
chunk_size = 1048576
resume = true
```

Host keys are stored with trust-on-first-use in `~/.macscp/known_hosts.json`. Set `hostKeyFingerprint` in a session profile's advanced settings to pin a specific key.

View today's log:

```bash
tail -f ~/.macscp/logs/macscp-$(date +%Y-%m-%d).log
```

---

## 6. Commander Interface

### 6.1 Layout

```text
┌──────────────────────────────────────────────────────────┐
│  ↑  ↻   Upload   Download                    [Queue: N]  │
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
- Very large trees may take time to scan before jobs appear in the queue.

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

Up to **2 transfers** run concurrently by default (configurable in `~/.macscp/config.toml` → `[transfer].max_concurrent_transfers`).

### 9.4 Cancelling a Transfer

Click **×** on a running job. MacSCP signals the backend to stop; the job moves to **Cancelled**. Very small files may finish before cancel takes effect.

---

## 10. Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| **⇧⌘N** | New Connection (login sheet) |
| **⇧⌘U** | Upload selected local files |
| **⇧⌘D** | Download selected remote files |

Additional shortcuts (type-ahead, **⌘↑** parent) are planned per spec.

---

## 11. Troubleshooting

### Connection Failed

| Symptom | Things to check |
|---|---|
| Timeout | Host reachable? Port 22 open? Firewall? |
| Auth failed | Username, key path, password, or agent keys correct? |
| Agent empty | Run `ssh-add -l`; ensure `SSH_AUTH_SOCK` is set |
| Key not accepted | Server has your public key in `authorized_keys`? |
| Host key error | First connect stores TOFU in `~/.macscp/known_hosts.json`; pin fingerprint in profile advanced settings when available |

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
- Retry after cancel; resume is enabled for partial downloads.

### Slow Uploads

MacSCP uses pipelined SFTP reads/writes on the Citadel backend when `[transfer].max_concurrent_reads` / `max_concurrent_writes` > 1. Tune concurrency in `~/.macscp/config.toml`. Benchmark details: [SFTP backend spike](spikes/sftp-backend-spike.md).

---

## 12. What's Not in This Release

The following are specified but **not yet available** in the GUI:

- Directory sync / mirror (one-way recursive transfer is supported; bidirectional sync is not)
- Remote file editor
- Integrated terminal
- Tabs and multiple sessions per window
- Quick Look preview
- chmod/chown property sheets
- `macscp` command-line tool
- ProxyJump UI
- Key passphrase field in login UI (encrypted keys work in benchmarks)

See [spec.md](spec.md) roadmap for timelines.

---

## 13. Getting Help

| Resource | Link |
|---|---|
| Product specification | [spec.md](spec.md) |
| Architecture (HLD) | [hld.md](hld.md) |
| Developer / protocol docs | [README.md](README.md) |
| Issues | Project issue tracker (when published) |

---

## 14. Appendix: Sample Workflows

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

---

*End of user guide*
