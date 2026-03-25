# SkyHook

A lightweight macOS menu bar app for mounting cloud storage as native Finder volumes. Powered by [rclone](https://rclone.org). No FUSE required.

## Features

- Mount any rclone-supported remote as a native macOS volume (S3, Google Drive, Dropbox, OneDrive, SFTP, and 40+ more)
- WebDAV mounting via Finder — no kernel extensions
- Volumes appear in Finder sidebar with proper names via `/etc/hosts` entries
- Interactive setup wizard for configuring remotes (OAuth, SSH, credentials)
- Live transfer monitoring with progress tracking
- Per-remote performance tuning (VFS cache mode, chunk size, transfers, etc.)
- Auto-mount remotes at login
- Auto-start at login
- Install/update/uninstall rclone from the app
- Native SwiftUI menu bar interface

## Requirements

- macOS 14.0 (Sonoma) or later
- [rclone](https://rclone.org) — SkyHook can download and install rclone for you, or you can point it to an existing rclone binary in Settings

> **Note:** SkyHook is not affiliated with the rclone project. rclone is an independent open-source tool licensed under the MIT license. SkyHook downloads rclone binaries directly from the [official rclone GitHub releases](https://github.com/rclone/rclone/releases).

## Build

```bash
./build.sh
```

Creates a universal binary (arm64 + x86_64) at `build/SkyHook.app`.

## Install

```bash
cp -r build/SkyHook.app /Applications/
```

Or drag `build/SkyHook.app` into your Applications folder.

## How It Works

SkyHook runs `rclone serve webdav` for each remote, then mounts the WebDAV server as a native Finder volume. Each remote gets a unique hostname in `/etc/hosts` so volumes show with clean names in Finder's sidebar. No FUSE, no kernel extensions, no background daemons.

### First Mount — Admin Password

The first time you mount a remote, SkyHook needs to add a hosts file entry (`/etc/hosts`) so the volume gets a clean name in Finder. You'll see:

1. A confirmation dialog explaining what's about to happen
2. The standard macOS admin password prompt

This is a one-time prompt per remote. The entry persists so you won't be asked again for that remote. Entries are tagged with `# SkyHook` and automatically cleaned up when you delete a remote.

### Quitting

When you quit SkyHook (Cmd+Q or the Quit button), all mounted volumes are automatically unmounted and mount points are cleaned up.

### VFS Cache Modes

SkyHook uses conservative cache defaults to prevent unwanted bulk downloads:

| Remote Type | Default Cache Mode | Why |
|---|---|---|
| FTP / SFTP | `minimal` | Prevents Finder indexing from downloading entire directories |
| Cloud (S3, Drive, Dropbox, etc.) | `writes` | Read-through without caching; only caches files opened for writing |

You can change the cache mode per-remote under **Performance** settings. Use `full` if you need aggressive local caching (e.g. for repeated reads of the same files).

## Supported Remotes

Any remote rclone supports — over 40 cloud storage providers including:

- Amazon S3 / Wasabi / Backblaze B2 / MinIO
- Google Drive / Google Cloud Storage
- Microsoft OneDrive / Azure Blob
- Dropbox / Box / pCloud / MEGA
- SFTP / FTP / SMB / WebDAV
- And many more

## License

MIT
