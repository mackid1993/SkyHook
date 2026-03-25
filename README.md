# SkyHook

A lightweight macOS menu bar app for mounting cloud storage as native Finder volumes. Powered by [rclone](https://rclone.org). No FUSE required.

## Features

- Mount any rclone-supported remote as a native macOS volume (S3, Google Drive, Dropbox, OneDrive, SFTP, and 40+ more)
- WebDAV mounting via Finder — no admin password, no kernel extensions
- Volumes appear in Finder sidebar with proper names
- Interactive setup wizard for configuring remotes (OAuth, SSH, credentials)
- Live transfer monitoring with progress and cancel
- Auto-mount remotes at login
- Auto-start at login
- Install/update/uninstall rclone from the app
- Configurable VFS cache, chunk size, transfers, and other rclone flags
- Native SwiftUI menu bar interface

## Requirements

- macOS 14.0 (Sonoma) or later
- rclone — install from within the app or via `brew install rclone`

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

SkyHook runs `rclone serve webdav` for each remote, then mounts the WebDAV server as a native Finder volume. Each remote gets a unique hostname in `/etc/hosts` (one-time admin prompt) so volumes show with clean names in Finder's sidebar. No FUSE, no kernel extensions, no background daemons.

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
