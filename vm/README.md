# Windows VM + arr Stack Backup Plan

This plan creates one weekly backup zip for the indexer/downloader/monitor VM that includes:

1. Your Windows **Documents** folder (skip with `-SkipDocuments`).
2. Optional **Hyper-V VM exports** (only if you pass VM names via `-HyperVVMNames`).
3. Backup payloads for **Sonarr, Radarr, Prowlarr, Bazarr, Jackett, qBittorrent**.

Lidarr and the Soulseek/Nicotine+ stack run on a different machine and are not part of this backup.

If you already back up the Hyper-V host/VM separately, just omit `-HyperVVMNames`
(the default). The Hyper-V step is then skipped entirely, and no checkpoint or export is
attempted. Add `-SkipDocuments` too if you only want the arr stack and qBittorrent.

Script: `vm/backup-vm-and-media-stack.ps1`

## Where backups go

| What | Default location | Parameter |
|---|---|---|
| Finished backup zips | `\\TUCKER-DESKTOP\Shared R Drive\VM Backups` | `-BackupRoot` |
| Run logs (copied next to the zips) | `\\TUCKER-DESKTOP\Shared R Drive\VM Backups\logs` | derived from `-BackupRoot` |
| `last-success.json` (written only on a fully clean run) | `\\TUCKER-DESKTOP\Shared R Drive\VM Backups` | derived from `-BackupRoot` |
| Local staging and zip creation | `%LOCALAPPDATA%\vm-media-backup\staging` | `-StagingRoot` |
| Local copy of every run log | `%LOCALAPPDATA%\vm-media-backup\logs` | `-LogRoot` |

Staging and zipping happen on local disk, so app downtime and zip creation never depend on network speed. The share only receives the finished zip after it passes an integrity check, and the upload is then size-verified. If the upload fails (after its retry), the verified zip is **kept locally** in `-StagingRoot` and the run is reported as failed, so nothing is lost.

Retention (`-RetentionCount`, default 8) only deletes `vm-media-backup_*.zip` files in `-BackupRoot`. It never touches other folders on the share, such as older manual backups. Retention only runs after a successful upload, so a failed run can never rotate out a good backup. Logs keep the newest `-LogRetentionCount` (default 30) in both log locations.

## Why these paths

- Servarr appdata defaults on Windows are:
  - `C:\ProgramData\Sonarr`
  - `C:\ProgramData\Radarr`
  - `C:\ProgramData\Prowlarr`
  These are from the Servarr Wiki appdata pages.
- Sonarr, Radarr and Prowlarr have built-in backup functions in `System => Backups` (Servarr Wiki system pages), so this plan copies recent backup zips from each app's `Backups` folder. Servarr apps file these into subfolders:
  - `Backups\scheduled`: automatic, on the configured interval (default every 7 days).
  - `Backups\manual`: triggered from the UI.
  - `Backups\update`: taken automatically before an update.

  The script therefore searches recursively under `Backups` and takes the newest N files across all three, not just `Backups\scheduled`.
- Bazarr also has a built-in scheduled backup (`Settings => Backup`), defaulting to `C:\ProgramData\Bazarr\backup`. It's treated the same way, so the newest N backup zips are copied and the app isn't stopped. There's no full directory copy.
- Jackett has no equivalent built-in backup export, so its live appdata directory is copied directly, and the service is stopped first (see below). Per the community answer in [Jackett/Jackett#2576](https://github.com/Jackett/Jackett/issues/2576), a working restore needs three things:
  - `ServerConfig.json`
  - the `Indexers` folder
  - `DataProtection\*.xml`, which holds the keys needed to decrypt the indexer passwords stored in the config. Without it, a restored config's passwords are permanently unusable, even though the files copied fine.

  A full directory copy already includes all three. The script still verifies that all three exist in the copied output and records an error if any are missing, so a future narrowing of what gets copied can't silently break this.
- TRaSH Guides qBittorrent pages focus on path consistency and shared-root layouts; this plan backs up qBittorrent directly from Windows profile paths.

## What the script backs up

- **Documents**
  - `%USERPROFILE%\Documents`
- **Sonarr**
  - `C:\ProgramData\Sonarr\Backups\**\*.zip` (latest N files across `scheduled`/`manual`/`update`)
- **Radarr**
  - `C:\ProgramData\Radarr\Backups\**\*.zip` (latest N files across `scheduled`/`manual`/`update`)
- **Prowlarr**
  - `C:\ProgramData\Prowlarr\Backups\**\*.zip` (latest N files across `scheduled`/`manual`/`update`)
- **Bazarr**
  - `C:\ProgramData\Bazarr\backup\*.zip` (latest N files)
- **Jackett**
  - `C:\ProgramData\Jackett` (full directory copy)
- **qBittorrent**
  - `%APPDATA%\qBittorrent`
  - `%LOCALAPPDATA%\qBittorrent`
- **Hyper-V (optional)**
  - `Export-VM` output for each VM name you pass

The zip is built with `System.IO.Compression.ZipFile`. This means hidden files and folders, such as `.git` directories inside Documents, are included; Windows PowerShell 5.1's `Compress-Archive` silently skips them.

The script writes a `manifest.json` inside each backup zip so you can see exactly what was captured.

## Retries, logging, and failure reporting

- **One retry per step.** Every step that can fail is retried exactly once after `-RetryDelaySeconds` (default 30), then logged as an error. This covers:
  - each component copy
  - the Hyper-V export
  - Jackett service stop/start
  - the qBittorrent shutdown request and restart
  - zip creation, upload, retention, and the offsite copy
- **Components are independent.** If one still fails after its retry, the others still run, and the zip is still produced and uploaded.
- **Everything is logged.** Each run writes a full transcript to `%LOCALAPPDATA%\vm-media-backup\logs\vm-media-backup_<timestamp>.log` and copies it to `<BackupRoot>\logs`. Lines are tagged `[INFO]`, `[WARN]` (a first attempt failed and is being retried) or `[ERROR]` (failed after the retry).
- **Failures show in the exit code.** The run exits with code **1** if anything failed, so Task Scheduler's "Last Run Result" shows `0x1` instead of reporting success. Failures are also listed in the manifest's top-level `errors` array.
- **Zero zips counts as a failure.** An arr app with zero backup zips is reported as an error. It almost always means the app's scheduled backup is off or the path moved, and that shouldn't look like a healthy run.
- **`last-success.json`** in `-BackupRoot` is only updated on a fully clean run. Check its `completedAt` to confirm backups are still happening.

## Stop/restart behavior

Jackett and qBittorrent hold live, mutable data with no built-in backup export, so both are stopped before their data is copied and restarted afterward. Sonarr, Radarr, Prowlarr and Bazarr are **not** stopped, because only their already-exported backup zips are copied, not live data.

### Jackett

The `Jackett` Windows service is stopped through the Service Control Manager, which is a graceful shutdown that also ends its `JackettConsole` child process. The service is started again after the copy. If Jackett is ever installed without the service, the script falls back to stopping the `JackettConsole` process. To use different names, edit the `ServiceName`/`ProcessName` values in the `$apps` array.

### qBittorrent graceful shutdown

qBittorrent writes its torrent resume data (`BT_backup`) when it exits, so it is **never force-killed**.

1. The script logs into the WebUI API (`-QbtWebUIUrl`, default `http://localhost:8080`, user `-QbtWebUIUser`, default `admin`) and calls `/api/v2/app/shutdown`.
2. It then waits for the process to exit, for up to `-QbtShutdownTimeoutSeconds` (default 600).
3. If qBittorrent doesn't exit in time, or the shutdown request fails after its retry, qBittorrent is **left running untouched**. Its data is not copied, and the run is reported as failed.
4. After the copy, qBittorrent is relaunched through `explorer.exe`. It therefore comes back **unelevated in your desktop session**, the same way it normally runs, even though the backup script itself runs elevated.

The WebUI password is read from a DPAPI-encrypted file, `-QbtPasswordFile`, which defaults to `%LOCALAPPDATA%\qBittorrentPassword.txt`. This is the same file the ProtonVPN port-sync script uses. DPAPI files can only be decrypted by the Windows account that created them, so the backup must run as that same user. To create or refresh the file, run this as that user:

```powershell
Read-Host "qBittorrent WebUI password" -AsSecureString |
  ConvertFrom-SecureString |
  Out-File "$env:LOCALAPPDATA\qBittorrentPassword.txt"
```

## Requirements

- **Run elevated.** Stopping and starting the Jackett service requires administrator rights, and the script refuses to run otherwise (`-EstimateOnly` excepted).
- **Run as the desktop user, while logged on.** Three things depend on it:
  - The qBittorrent password file can only be decrypted by that account.
  - `%APPDATA%`, `%LOCALAPPDATA%` and Documents must resolve to that profile.
  - qBittorrent must be relaunched into the user's desktop session.

  Do not run the scheduled task as `SYSTEM`, or with "Run whether user is logged on or not".
- **Share access.** The account must be able to write to `-BackupRoot`.

## Run manually

From an elevated PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File "C:\path\to\repo\vm\backup-vm-and-media-stack.ps1"
```

The defaults already point at the share. Override as needed:

```powershell
powershell -ExecutionPolicy Bypass -File "C:\path\to\repo\vm\backup-vm-and-media-stack.ps1" `
  -BackupRoot "\\TUCKER-DESKTOP\Shared R Drive\VM Backups" `
  -RetentionCount 8 `
  -ArrBackupCopiesPerApp 4
```

`-RetentionCount` must be at least `1`. The script always keeps the most recently created backup, whatever the value.

### Arr stack + qBittorrent only

```powershell
powershell -ExecutionPolicy Bypass -File "C:\path\to\repo\vm\backup-vm-and-media-stack.ps1" -SkipDocuments
```
Omitting `-HyperVVMNames` already skips the Hyper-V step by default. Combined with `-SkipDocuments`, this backs up only Sonarr, Radarr, Prowlarr, Bazarr, Jackett and qBittorrent.

### Estimate size before running

```powershell
powershell -ExecutionPolicy Bypass -File "C:\path\to\repo\vm\backup-vm-and-media-stack.ps1" -SkipDocuments -EstimateOnly
```
`-EstimateOnly` walks the same source paths the real backup would use, respecting `-SkipDocuments`, `-HyperVVMNames` and `-ArrBackupCopiesPerApp`. It prints a per-component size breakdown, then exits. It never touches `-BackupRoot`, never stops any app, never copies anything, and doesn't need elevation. The printed total is uncompressed source size. The actual zip will typically be smaller, though savings vary by data type: already-compressed backup zips and SQLite DBs compress poorly.

### Additional offsite copy

```powershell
powershell -ExecutionPolicy Bypass -File "C:\path\to\repo\vm\backup-vm-and-media-stack.ps1" `
  -OffsiteDestination "\\nas\Backups\ServerBackups"
```
After a successful upload to `-BackupRoot`, the zip is also copied, with size verification, to `-OffsiteDestination`. The same `-RetentionCount` policy is applied there independently. A failure there (after its retry) is recorded as an error, but it doesn't affect the primary backup.

## Schedule weekly (Task Scheduler)

Run this from an elevated prompt, logged in as the user who runs qBittorrent. `/IT` makes the task run only when that user is logged on, so the conditions under Requirements hold. `/RL HIGHEST` runs it elevated.

```cmd
schtasks /Create /TN "Weekly VM+ARR Backup" /SC WEEKLY /D SUN /ST 03:30 /RL HIGHEST /IT /TR "powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"C:\path\to\repo\vm\backup-vm-and-media-stack.ps1\"" /F
```

`-WindowStyle Hidden` matters. A visible console window can be frozen by a single click inside it: Windows' QuickEdit mode starts a text selection, and the title changes to "Select ...". Every write to the console then blocks, and the backup silently hangs, possibly with Jackett or qBittorrent stopped, until someone presses Esc in that window. Everything the script prints also goes to the log file, so nothing is lost by hiding the window.

Check results with `schtasks /Query /TN "Weekly VM+ARR Backup" /V /FO LIST`. A "Last Result" of `0` means a fully clean run; `1` means at least one failure, which is listed in the log.

## Restore notes

0. Check the run's log and `manifest.json`'s `errors` array first. A non-empty array means one or more components in that specific backup run failed and may be missing or incomplete. Pick a different backup if the component you need to restore is affected.
1. Extract the selected backup zip.
2. Restore each app before first launch, or while the app/service is stopped:
   - **Sonarr, Radarr, Prowlarr, Bazarr:** use the app's restore flow with the backup zip, if you prefer.
   - **Jackett and qBittorrent:** restore the copied config/data folders. For Jackett, make sure `DataProtection\*.xml` is restored alongside `ServerConfig.json` and `Indexers`. Without it, the indexer passwords in the restored config can't be decrypted and will need to be re-entered.
3. For Hyper-V, import or register from the exported VM folders.
4. Start services and validate app health.

## Sources

- TRaSH Guides: https://trash-guides.info/
- TRaSH qBittorrent paths: https://trash-guides.info/Downloaders/qBittorrent/Paths/
- qBittorrent WebUI API: https://github.com/qbittorrent/qBittorrent/wiki/WebUI-API-(qBittorrent-5.0)
- Servarr Wiki appdata pages:
  - https://wiki.servarr.com/sonarr/appdata-directory
  - https://wiki.servarr.com/radarr/appdata-directory
  - https://wiki.servarr.com/prowlarr/appdata-directory
