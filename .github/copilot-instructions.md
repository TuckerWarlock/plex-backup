# Copilot Instructions for `plex-backup`

## Build, test, and lint

This repository currently has no build system, test suite, or linter configuration.

- Validate by running scripts directly in PowerShell, for example:
  - `powershell -ExecutionPolicy Bypass -File ".\server\backup-plex-server.ps1" -BackupRoot "D:\PlexBackups" -RetentionCount 2`
  - `powershell -ExecutionPolicy Bypass -File ".\vm\backup-vm-and-media-stack.ps1" -RetentionCount 2 -ArrBackupCopiesPerApp 2` (run elevated; uploads to `\\TUCKER-DESKTOP\Shared R Drive\VM Backups` by default)
  - `powershell -ExecutionPolicy Bypass -File ".\vm\backup-vm-and-media-stack.ps1" -EstimateOnly` (read-only)
- There is no single-test command available because no automated tests are defined yet.

## High-level architecture

The repo is a Windows backup automation toolkit with two parallel backup flows:

1. `server/backup-plex-server.ps1` + `server/README.md`
   - Backs up Plex app data (`%LOCALAPPDATA%\Plex Media Server`) and Plex registry settings (`HKCU\Software\Plex, Inc.\Plex Media Server`).
   - Stops Plex before copy, writes a manifest, zips output, then applies retention.

2. `vm/backup-vm-and-media-stack.ps1` + `vm/README.md`
   - Creates one backup artifact for Documents, optional Hyper-V exports, Sonarr/Radarr/Prowlarr/Bazarr backup zips, Jackett data, and qBittorrent data. Lidarr is not on this VM.
   - Stages and zips locally, then uploads the verified zip to `\\TUCKER-DESKTOP\Shared R Drive\VM Backups`.
   - Stops the Jackett service, and shuts qBittorrent down gracefully through its WebUI API (never force-killed), before copying their data.
   - Retries each failing step once, logs every run, and exits 1 on any failure.
   - Uses a manifest to record what was actually captured in each run.

The per-directory README files are operational docs (manual run, Task Scheduler setup, and restore notes) and should stay aligned with script behavior.

## Key conventions

- **PowerShell style:** scripts use `[CmdletBinding()]`, parameterized defaults, and `$ErrorActionPreference = "Stop"`.
- **Path handling:** prefer `Join-Path` and environment variables (`$env:LOCALAPPDATA`, `$env:APPDATA`) instead of hard-coded user paths.
- **Copy semantics:** use `robocopy`; treat exit codes `>= 8` as failures and throw.
- **Retries:** in the VM script, wrap fallible steps in `Invoke-WithRetry` (one retry), and record final failures with `Add-ComponentError`.
- **Safety first for mutable app data:** stop relevant app/service before backup operations.
- **Artifact format:** each run creates a timestamped zip (`PlexBackup_yyyy-MM-dd_HH-mm-ss.zip`, `vm-media-backup_yyyy-MM-dd_HH-mm-ss.zip`) and removes staging folders afterward.
- **Retention:** keep newest N zip files per script, delete older backups.
- **Manifests:** include a `manifest.json` in backup payloads to capture run metadata and included components.
- **Missing sources:** for optional/machine-specific paths, warn and continue when appropriate rather than silently failing.
