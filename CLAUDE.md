# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Windows-focused PowerShell backup automation for a Plex/media server: one script backs up the Plex server itself, another backs up a VM's Documents folder plus the arr/download-client stack (Sonarr, Radarr, Prowlarr, Bazarr, Jackett, qBittorrent) and optional Hyper-V VM exports.

## Build, test, and lint

There is no build system, test suite, or linter in this repo. Validate changes by running the scripts directly in PowerShell (Windows only — these rely on `robocopy`, the Windows registry, `Compress-Archive`, and optionally Hyper-V cmdlets):

```powershell
powershell -ExecutionPolicy Bypass -File ".\server\backup-plex-server.ps1" -BackupRoot "D:\PlexBackups" -RetentionCount 2
powershell -ExecutionPolicy Bypass -File ".\vm\backup-vm-and-media-stack.ps1" -BackupRoot "D:\ServerBackups" -RetentionCount 2 -ArrBackupCopiesPerApp 2
```

There's no single-test command since there are no automated tests.

## Architecture

Two independent, parallel backup flows, each pairing a script with an operational README:

- **`server/backup-plex-server.ps1`** (+ `server/README.md`) — stops the Plex service/process, `robocopy`-mirrors `%LOCALAPPDATA%\Plex Media Server` (excluding `Cache`, `Codecs`, `Crash Reports`, `Logs`), exports the `HKCU\Software\Plex, Inc.\Plex Media Server` registry key to a `.reg` file, restarts Plex, writes `manifest.json`, zips the staging folder, then applies retention.
- **`vm/backup-vm-and-media-stack.ps1`** (+ `vm/README.md`) — builds one zip covering the Documents folder, optional Hyper-V `Export-VM` output, the newest N backup zips from each arr app's `Backups` folder (Sonarr/Radarr/Prowlarr), full directory copies for Bazarr/Jackett, and filesystem copies of qBittorrent's `%APPDATA%`/`%LOCALAPPDATA%` profile data. Records what was actually captured in `manifest.json`.

The per-directory README files are operational docs (manual run commands, Task Scheduler setup, restore steps) and must stay aligned with actual script behavior when either changes.

## Key conventions

- **PowerShell style:** `[CmdletBinding()]`, parameterized defaults (e.g. `$BackupRoot`, `$RetentionCount`), `$ErrorActionPreference = "Stop"`.
- **Path handling:** use `Join-Path` and environment variables (`$env:LOCALAPPDATA`, `$env:APPDATA`) instead of hard-coded user paths.
- **Copy semantics:** copy operations go through `robocopy`; treat exit codes `>= 8` as failures and `throw`.
- **Safety first for mutable app data:** stop the relevant app/service before backing up its data (see Plex service stop/start in `server/backup-plex-server.ps1`).
- **Artifact format:** each run produces a timestamped zip — `PlexBackup_yyyy-MM-dd_HH-mm-ss.zip` or `vm-media-backup_yyyy-MM-dd_HH-mm-ss.zip` — and the staging folder is removed afterward.
- **Retention:** keep the newest N zip files per script (by `LastWriteTime`), delete the rest.
- **Manifests:** every backup payload includes a `manifest.json` describing run metadata and what was actually included (important since some sources are optional/machine-specific).
- **Missing sources:** for optional or machine-specific paths, warn (`Write-Warning`) and continue rather than failing the whole run — see `Copy-DirectoryIfExists` / `Copy-NewestFiles` in `vm/backup-vm-and-media-stack.ps1`.

## Source paths this repo assumes (Windows)

- Plex data: `%LOCALAPPDATA%\Plex Media Server`; Plex registry: `HKCU\Software\Plex, Inc.\Plex Media Server`.
- Sonarr/Radarr/Prowlarr appdata: `C:\ProgramData\<App>` with backup zips under `C:\ProgramData\<App>\Backups`.
- Bazarr/Jackett appdata: `C:\ProgramData\Bazarr`, `C:\ProgramData\Jackett` (full directory copy, no built-in backup export used).
- qBittorrent: `%APPDATA%\qBittorrent` and `%LOCALAPPDATA%\qBittorrent`.

If these locations change (e.g. app moved to a different data root), update both the script's source paths and the corresponding README.
