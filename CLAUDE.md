# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Windows-focused PowerShell backup automation for a Plex/media server: one script backs up the Plex server itself, another backs up the indexer/downloader/monitor VM's Documents folder plus the arr/download-client stack (Sonarr, Radarr, Prowlarr, Bazarr, Jackett, qBittorrent) and optional Hyper-V VM exports. Lidarr and the Soulseek/Nicotine+ stack run on a different machine and are intentionally not covered.

## Build, test, and lint

There is no build system, test suite, or linter in this repo. Validate changes by running the scripts directly in PowerShell (Windows only — these rely on `robocopy`, the Windows registry, `System.IO.Compression`/`Compress-Archive`, and optionally Hyper-V cmdlets):

```powershell
powershell -ExecutionPolicy Bypass -File ".\server\backup-plex-server.ps1" -BackupRoot "D:\PlexBackups" -RetentionCount 2
# VM script: run elevated; defaults upload to \\TUCKER-DESKTOP\Shared R Drive\VM Backups
powershell -ExecutionPolicy Bypass -File ".\vm\backup-vm-and-media-stack.ps1" -RetentionCount 2 -ArrBackupCopiesPerApp 2
# Read-only size estimate, no elevation needed
powershell -ExecutionPolicy Bypass -File ".\vm\backup-vm-and-media-stack.ps1" -EstimateOnly
```

There's no single-test command since there are no automated tests. Test the VM script on the indexer/downloader/monitor VM. Do not run the Plex script against the live Plex server without the owner's explicit go-ahead.

## Architecture

Two independent, parallel backup flows, each pairing a script with an operational README:

- **`server/backup-plex-server.ps1`** (+ `server/README.md`) — stops the Plex service/process, `robocopy`-mirrors `%LOCALAPPDATA%\Plex Media Server` (excluding `Cache`, `Codecs`, `Crash Reports`, `Logs`), exports the `HKCU\Software\Plex, Inc.\Plex Media Server` registry key to a `.reg` file, restarts Plex, writes `manifest.json`, zips the staging folder, then applies retention.
- **`vm/backup-vm-and-media-stack.ps1`** (+ `vm/README.md`) — stages and zips locally under `%LOCALAPPDATA%\vm-media-backup`, then uploads one verified zip to `$BackupRoot` (default `\\TUCKER-DESKTOP\Shared R Drive\VM Backups`). The zip covers:
  - the Documents folder
  - optional Hyper-V `Export-VM` output
  - the newest N backup zips from each arr app's `Backups` folder (Sonarr/Radarr/Prowlarr; searched recursively, because Servarr apps file these under `Backups\scheduled`/`manual`/`update`), plus Bazarr's built-in `backup` folder
  - a full directory copy of Jackett (service stopped first)
  - qBittorrent's `%APPDATA%`/`%LOCALAPPDATA%` profile data. qBittorrent is shut down gracefully via its WebUI API first and never killed, then relaunched unelevated via `explorer.exe`.

  Behavior:
  - Every step gets one retry (`Invoke-WithRetry`).
  - Each run writes a transcript log, both locally and to `<BackupRoot>\logs`.
  - The script exits 1 on any failure, and writes `last-success.json` only on clean runs.
  - It records what was actually captured in `manifest.json`.

  It must run elevated, as the desktop user, while logged on. This is because of the DPAPI password file, the user-profile paths, and relaunching qBittorrent into the desktop session.

The per-directory README files are operational docs (manual run commands, Task Scheduler setup, restore steps) and must stay aligned with actual script behavior when either changes.

## Key conventions

- **PowerShell style:** `[CmdletBinding()]`, parameterized defaults (e.g. `$BackupRoot`, `$RetentionCount`), `$ErrorActionPreference = "Stop"`.
- **Path handling:** use `Join-Path` and environment variables (`$env:LOCALAPPDATA`, `$env:APPDATA`) instead of hard-coded user paths.
- **Copy semantics:** copy operations go through `robocopy`; treat exit codes `>= 8` as failures and `throw`.
- **Retries (VM script):** wrap any step that can fail in `Invoke-WithRetry`, which retries once after `$RetryDelaySeconds`, then logs and rethrows. Record final failures with `Add-ComponentError`, so they reach the log, `manifest.errors`, and the exit code.
- **Safety first for mutable app data:** stop the relevant app/service before backing up its data (see Plex service stop/start in `server/backup-plex-server.ps1`).
- **Never force-kill qBittorrent:** shut it down through the WebUI API and wait. If it won't exit, leave it running and skip its copy.
- **Artifact format:** each run produces a timestamped zip — `PlexBackup_yyyy-MM-dd_HH-mm-ss.zip` or `vm-media-backup_yyyy-MM-dd_HH-mm-ss.zip` — and the staging folder is removed afterward. The VM script builds its zip with `System.IO.Compression.ZipFile`, because Windows PowerShell 5.1's `Compress-Archive` skips hidden files.
- **Retention:** keep the newest N zip files per script (by `LastWriteTime`), delete the rest.
- **Manifests:** every backup payload includes a `manifest.json` describing run metadata and what was actually included (important since some sources are optional/machine-specific).
- **Missing sources:** for optional or machine-specific paths, warn (`Write-Warning`) and continue rather than failing the whole run — see `Copy-DirectoryIfExists` / `Copy-NewestFiles` in `vm/backup-vm-and-media-stack.ps1`.

## Source paths this repo assumes (Windows)

- Plex data: `%LOCALAPPDATA%\Plex Media Server`; Plex registry: `HKCU\Software\Plex, Inc.\Plex Media Server`.
- Sonarr/Radarr/Prowlarr appdata: `C:\ProgramData\<App>` with backup zips under `C:\ProgramData\<App>\Backups` (searched recursively — Servarr apps file these into `scheduled`/`manual`/`update` subfolders, not directly in `Backups`).
- Bazarr appdata: `C:\ProgramData\Bazarr`, with its own built-in scheduled backup zips under `C:\ProgramData\Bazarr\backup`.
- Jackett appdata: `C:\ProgramData\Jackett` (full directory copy, no built-in backup export used).
- qBittorrent: `%APPDATA%\qBittorrent` and `%LOCALAPPDATA%\qBittorrent`.
- qBittorrent WebUI: `http://localhost:8080`, user `admin`. The DPAPI-encrypted password is in `%LOCALAPPDATA%\qBittorrentPassword.txt`, shared with the ProtonVPN port-sync script.
- VM backup destination: `\\TUCKER-DESKTOP\Shared R Drive\VM Backups`. The other folders there are older manual backups; retention only touches `vm-media-backup_*.zip`.

If these locations change (e.g. app moved to a different data root), update both the script's source paths and the corresponding README.
