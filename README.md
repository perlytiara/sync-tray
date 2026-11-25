<p align="center">
  <img src="docs/assets/synctray-logo.png" alt="SyncTray logo" height="160">
</p>

<h1 align="center">SyncTray · Drive workspace</h1>

<p align="center">
  Browse a cloud drive on macOS, see individual transfers, and check which files are cached locally.
</p>

<p align="center">
  <a href="https://github.com/perlytiara/sync-tray/actions/workflows/ci.yml"><img src="https://github.com/perlytiara/sync-tray/actions/workflows/ci.yml/badge.svg?branch=main" alt="Build and tests"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-blue" alt="macOS 13+">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="MIT license"></a>
</p>

This public fork builds on the native SwiftUI app by [mthines and the SyncTray contributors](https://github.com/mthines/sync-tray) and uses rclone for storage and transfers. Connect your own Google Drive account or another rclone remote in a Stream profile.

- **Files** opens one folder at a time in the mounted drive. Use breadcrumbs, search the current folder, open a file in its Mac app, or show the folder in Finder. Cache availability uses rclone’s recorded byte ranges.
- **Activity** shows the files moving now, upload queue, and recent transfers for this mount session. Idle, cache-only, disconnected, and unavailable readings have their own states.
- **Project backups** appears on Macs with the separate Project Archive Backup worker. It reads the current ledger, scheduler, and completed run, including skipped work and pending failures. **Verify on Drive** compares the recorded MD5 values with cloud metadata in the worker’s archive folder. Each result carries its date and applies to the same ledger. The worker and personal backup configuration are separate installations.

## Build this fork

Install Xcode and rclone, then build the app from this repository.

```bash
git clone https://github.com/perlytiara/sync-tray.git
cd sync-tray
xcodebuild -project SyncTray.xcodeproj -scheme SyncTray -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO build
open build/Build/Products/Release/SyncTray.app
```

For a first connection, open **Setup Wizard**, connect a remote, and choose **Stream (Mount)**. The drive appears under **Library** after setup. The default NFS backend works with Homebrew rclone. For macFUSE, use a FUSE-capable rclone build. Local signing for the optional Finder extension is documented in the [development guide](DEVELOPMENT.md).

## Why SyncTray

rclone can talk to almost any storage, but on its own it's a terminal tool — no status, no schedule, no Finder integration.
SyncTray turns it into the Mac sync client you'd expect, pointed at storage you control.

- **Any storage.** Synology, SMB, SFTP, WebDAV, S3, Backblaze B2, Google Drive, OneDrive, Dropbox — anything rclone can reach.
- **Three modes, one app.** Two-way sync, one-way backup, or stream files on demand.
- **No kernel extension.** Streaming uses rclone's built-in NFS mount, so it works on managed Macs where macFUSE is blocked.
- **Works offline.** Right-click a folder in Finder → **Available Offline**. Lose the connection and keep editing — changes upload when you're back.
- **Runs without the app.** Syncs and mounts are launchd agents, so they keep going when the menu bar app is closed.
- **Careful with your files.** Two-way conflicts keep both copies, and a two-way sync that would delete more than half your files stops and asks first.
- **Agent-ready.** Plain JSON config with a published schema, and a `synctray` CLI with `--json` output and blocking `--wait`.

## Let your agent set it up

Claude Code, Codex, Cursor — any agent with a terminal can set up rclone and SyncTray for you 🤖
Install SyncTray, launch it once, and ask:

```text
Set up SyncTray to two-way sync ~/Projects with the Projects folder on my NAS.
Use rclone and the synctray CLI (in ~/.local/bin), and show me the profile before you turn it on.
```

If the NAS isn't connected in rclone yet, the agent does that too.
You step in only to sign in, type a password, or approve the profile.

→ [Agent setup guide](docs/agent-setup.md): what the agent does step by step, a more detailed prompt, and rules to give it.

## Three ways to sync

| Mode               | Best for                                   | What happens                                                   |
| ------------------ | ------------------------------------------ | -------------------------------------------------------------- |
| **Two-Way Sync**   | Files you work on from more than one place | Changes on either side reach the other, on a schedule you pick |
| **One-Way Sync**   | Backups and mirrors                        | One side is the source; the other always matches it            |
| **Stream (Mount)** | Big libraries that don't fit on disk       | Every file shows up in Finder and downloads when you open it   |

### Stream, with offline folders

A Stream profile mounts your remote as a folder.
Files download the first time you open them and stay cached for as long as you choose (7 days by default).

- **Available Offline.** Right-click any folder in Finder to keep it fully downloaded, with live progress in the menu bar.
- **Cache Only.** One click — or automatically, when the remote can't be reached as the mount starts — switches the mount to serve only what's cached. You can keep creating and editing files, and they upload when you resume. If the same file changed on the remote meanwhile, yours uploads as a separate conflict copy — nothing gets overwritten.
- **Resilient by default.** A stalled server returns an error within about 30 seconds instead of freezing Finder.

### Home and away

Give a profile a **fallback remote** — say, your NAS over SMB at home and over SFTP or QuickConnect everywhere else.
Each two-way and one-way sync checks the primary first and switches over in about 3 seconds when it can't reach it.
The menu bar shows which one is in use.

### Choose what syncs

- **Don't Sync** skips files by pattern, like `*.rpp-bak` or `**/BACKUP/**`. Nothing is deleted on either side.
- **Sync Only These Folders** does the opposite: pick a few folders from a remote folder browser and leave the rest alone.

### Always know what's going on

- A menu bar icon for idle, syncing, paused, error, drive disconnected, and setup needed.
- Live transfer progress — bytes, files, and speed — for syncs and for streamed files.
- Batched notifications, and the last 20 changed files one click away in Finder.
- **Sync Now**, **Pause**, and **Abort** per profile, plus an optional bandwidth limit.
- External drives are detected: syncs pause while the drive is unplugged and resume when it's back.

Full walkthroughs for every feature are in the [user guide](docs/user-guide.md).

## Upstream releases

The upstream project distributes notarized builds and its Homebrew cask. The Drive workspace in this fork builds from the source above. [Upstream releases](https://github.com/mthines/sync-tray/releases)

## Quick start

1. **Launch SyncTray.** The icon appears in the menu bar. A yellow gear means there's nothing set up yet.
2. **Open Settings → +** to start the setup wizard.
3. **Pick or connect a remote.** The wizard can connect Google Drive, Dropbox, OneDrive, Synology, SMB, WebDAV, and SFTP for you, or reuse any remote you already set up with `rclone config`.
4. **Choose the folders, the mode, and how often to sync** (from 1 minute to 365 days; 5 minutes by default). Choose **Schedule only** for periodic backups, or **On local changes + schedule** for continuous sync.
5. **Install.** SyncTray creates the local folder, runs the first sync (or mounts the remote), and schedules the rest.

<p align="center">
  <img src="docs/assets/new-profile-wizard-providers.png" alt="Choosing a storage provider in the setup wizard" height="420">
</p>

Prefer the terminal? Everything above is also `synctray profile create` — see [Let your agent set it up](#let-your-agent-set-it-up).

## Documentation

| Guide                                            | What's in it                                                                    |
| ------------------------------------------------ | ------------------------------------------------------------------------------- |
| [User guide](docs/user-guide.md)                 | Every sync mode and feature, step by step                                       |
| [Agent setup](docs/agent-setup.md)               | Setting SyncTray up from an AI agent or a script                                |
| [CLI reference](docs/cli.md)                     | Every `synctray` command, its output, and its exit codes                        |
| [Configuration files](docs/configuration.md)     | `~/.config/synctray/`, the profile schema, and every file SyncTray creates      |
| [Troubleshooting](docs/troubleshooting.md)       | Sync errors, mounts, slow streaming, and Gatekeeper                             |
| [Development](DEVELOPMENT.md)                    | Building, signing, telemetry, and releasing                                     |

## FAQ

**Is SyncTray free?**
Yes. It's open source under the MIT license.

**Do I need macFUSE?**
No. Stream mode uses rclone's NFS mount and needs nothing beyond rclone.
A macFUSE backend is still available per profile if you want it.

**Where are my passwords stored?**
In rclone's own config file, `~/.config/rclone/rclone.conf`.
SyncTray's profile files never contain credentials.

**Does it sync when the app is closed?**
Yes. Scheduled syncs and mounts run as launchd agents.
By default, while the app is open, a local change also triggers a sync about 5 seconds after you stop editing. Choose **Schedule only** to check and transfer files only when your interval is due.

**What does it send home?**
Nothing, unless you turn on **Share usage data** in App Settings.
If you do, it sends pseudonymous usage and error data — never file names, folder names, remote names, or credentials.
The full list is in the app under **Privacy & Telemetry**.

## Community and support

Questions, feedback, or a feature idea? Join the [SyncTray Discord](https://discord.gg/KBp8kb3EwP) — it's also linked from **Help & Feedback** in the menu bar.
Report Drive workspace issues in [this fork’s tracker](https://github.com/perlytiara/sync-tray/issues).

## Contributing

Pull requests are welcome 🙌
Start with [DEVELOPMENT.md](DEVELOPMENT.md) for building, testing, and the commit convention that drives releases.

## License

[MIT](LICENSE)

## Acknowledgments

- [rclone](https://rclone.org/) — the sync engine underneath everything
- [macFUSE](https://osxfuse.github.io/) — the optional FUSE mount backend
- [OpenTelemetry Swift](https://github.com/open-telemetry/opentelemetry-swift) — opt-in telemetry
