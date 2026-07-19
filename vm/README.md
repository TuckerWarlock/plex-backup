# Windows VM + arr Stack Backup Plan

This plan creates one weekly backup zip that includes:

1. Your Windows **Documents** folder (skip with `-SkipDocuments`).
2. Optional **Hyper-V VM exports** (only if you pass VM names via `-HyperVVMNames`).
3. Backup payloads for **Sonarr, Radarr, Prowlarr, Lidarr, Bazarr, Jackett, qBittorrent**.

If you already back up the Hyper-V host/VM separately, just omit `-HyperVVMNames`
(the default) — the Hyper-V step is entirely skipped, no checkpoint or export is
attempted. Add `-SkipDocuments` too if you only want the arr stack + qBittorrent,
e.g. when running this from inside the VM itself.

Script: `vm/backup-vm-and-media-stack.ps1`

## Why these paths

- Servarr appdata defaults on Windows are:
  - `C:\ProgramData\Sonarr`
  - `C:\ProgramData\Radarr`
  - `C:\ProgramData\Prowlarr`
  - `C:\ProgramData\Lidarr`
  These are from Servarr Wiki appdata pages.
- Sonarr/Radarr/Prowlarr/Lidarr have built-in backup functions in `System => Backups` (Servarr Wiki system pages), so this plan copies recent backup zips from each app's `Backups` folder. Servarr apps file these into subfolders — `Backups\scheduled` (automatic, on the configured interval, default every 7 days), `Backups\manual` (triggered from the UI), and `Backups\update` (taken automatically before an update) — so the script searches recursively under `Backups` and takes the newest N files across all three, not just `Backups\scheduled`.
- Bazarr also has a built-in scheduled backup (`Settings => Backup`), defaulting to `C:\ProgramData\Bazarr\backup`, so it's treated the same way — newest N backup zips copied, app not stopped — rather than a full directory copy.
- Jackett has no equivalent built-in backup export, so its live appdata directory is copied directly (and the app is stopped first, see below). Per the community answer in [Jackett/Jackett#2576](https://github.com/Jackett/Jackett/issues/2576), what actually matters for a working restore is `ServerConfig.json`, the `Indexers` folder, and — critically — `DataProtection\*.xml`, which holds the keys needed to decrypt indexer passwords stored in the config; without it, a restored config's passwords are permanently unusable even though the files copied fine. A full directory copy already includes all three, but the script also explicitly verifies all three exist in the copied output and warns (recorded in `manifest.errors`) if any are missing, so a future narrowing of what gets copied can't silently break this.
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
- **Lidarr**
  - `C:\ProgramData\Lidarr\Backups\**\*.zip` (latest N files across `scheduled`/`manual`/`update`)
- **Bazarr**
  - `C:\ProgramData\Bazarr\backup\*.zip` (latest N files)
- **Jackett**
  - `C:\ProgramData\Jackett` (full directory copy)
- **qBittorrent**
  - `%APPDATA%\qBittorrent`
  - `%LOCALAPPDATA%\qBittorrent`
- **Hyper-V (optional)**
  - `Export-VM` output for each VM name you pass

The script writes a `manifest.json` inside each backup zip so you can see exactly what was captured. Each component (Documents, each arr app, qBittorrent, each Hyper-V VM) is backed up independently — if one fails (locked file, missing path, export error), the others still run and the zip is still produced. Check the manifest's top-level `errors` array for any partial failures; the script also prints a `Backup completed with N component failure(s)` warning when that array is non-empty, so a run isn't silently treated as fully successful when it wasn't.

## Stop/restart behavior

Jackett and qBittorrent hold live, mutable data with no built-in backup export, so the script stops each one (service if installed as one, otherwise the matching process) before copying its data and restarts it afterward — mirroring what `server/backup-plex-server.ps1` does for Plex. Sonarr/Radarr/Prowlarr/Lidarr/Bazarr are **not** stopped, since only their already-exported backup zips are copied, not live data.

The service/process names used to detect and stop Jackett (`Jackett` service / `JackettConsole` process) are best-effort guesses — if your install uses different names, the script won't find them, silently skips the stop/restart step, and copies the data live (same as previous behavior). If you know your install's actual service/process name differs, edit the `ServiceName`/`ProcessName` values in the `$apps` array in `vm/backup-vm-and-media-stack.ps1`.

## Run manually

```powershell
powershell -ExecutionPolicy Bypass -File "C:\path\to\repo\vm\backup-vm-and-media-stack.ps1" `
  -BackupRoot "D:\ServerBackups" `
  -RetentionCount 8 `
  -ArrBackupCopiesPerApp 4 `
  -HyperVVMNames @("MediaVM")
```

If you don't use Hyper-V, omit `-HyperVVMNames`.

`-RetentionCount` must be at least `1` — the script always keeps the most recently created backup regardless of the value.

### Arr stack + qBittorrent only (e.g. running from inside the VM)

```powershell
powershell -ExecutionPolicy Bypass -File "C:\path\to\repo\vm\backup-vm-and-media-stack.ps1" `
  -BackupRoot "D:\ServerBackups" `
  -RetentionCount 8 `
  -ArrBackupCopiesPerApp 4 `
  -SkipDocuments
```
Omitting `-HyperVVMNames` already skips the Hyper-V step by default, so combined with `-SkipDocuments` this backs up only Sonarr/Radarr/Prowlarr/Lidarr/Bazarr/Jackett/qBittorrent.

### Estimate size before running

```powershell
powershell -ExecutionPolicy Bypass -File "C:\path\to\repo\vm\backup-vm-and-media-stack.ps1" -SkipDocuments -EstimateOnly
```
`-EstimateOnly` walks the same source paths the real backup would use (respecting `-SkipDocuments`/`-HyperVVMNames`/`-ArrBackupCopiesPerApp`) and prints a per-component size breakdown, then exits — it never touches `-BackupRoot`, never stops any app, and never copies anything. The printed total is uncompressed source size; the actual zip will typically be smaller, though savings vary by data type (already-compressed backup zips and SQLite DBs compress poorly).

### Offsite/network destination

```powershell
powershell -ExecutionPolicy Bypass -File "C:\path\to\repo\vm\backup-vm-and-media-stack.ps1" `
  -BackupRoot "D:\ServerBackups" `
  -OffsiteDestination "\\nas\Backups\ServerBackups"
```
`-BackupRoot` stays local — staging, the live app copy (while Jackett/qBittorrent are briefly stopped), and zip creation all happen on local disk, so app downtime and total runtime aren't at the mercy of network speed. Once the local zip is created and passes its integrity check, it's copied to `-OffsiteDestination` (any path the account can write to — UNC share or mapped drive) and the same `-RetentionCount` policy is applied there independently. If the offsite copy fails (share unreachable, permissions), it's logged as a warning only — the local backup is not affected or rolled back.

## Schedule weekly (Task Scheduler)

```cmd
schtasks /Create /TN "Weekly VM+ARR Backup" /SC WEEKLY /D SUN /ST 03:30 /RL HIGHEST /TR "powershell -ExecutionPolicy Bypass -File C:\path\to\repo\vm\backup-vm-and-media-stack.ps1 -BackupRoot D:\ServerBackups -RetentionCount 8 -ArrBackupCopiesPerApp 4" /F
```

## Restore notes

0. Check `manifest.json`'s `errors` array first — a non-empty array means one or more components in that specific backup run failed and may be missing or incomplete; pick a different backup if the component you need to restore is affected.
1. Extract the selected backup zip.
2. Restore each app before first launch (or while app/service is stopped):
   - Sonarr/Radarr/Prowlarr/Lidarr/Bazarr: use app restore flow from backup zip if preferred.
   - Jackett/qBittorrent: restore copied config/data folders. For Jackett, make sure `DataProtection\*.xml` is restored alongside `ServerConfig.json`/`Indexers` — without it, indexer passwords in the restored config can't be decrypted and will need to be re-entered.
3. For Hyper-V, import or register from exported VM folders.
4. Start services and validate app health.

## Sources

- TRaSH Guides: https://trash-guides.info/
- TRaSH qBittorrent paths: https://trash-guides.info/Downloaders/qBittorrent/Paths/
- Servarr Wiki appdata pages:
  - https://wiki.servarr.com/sonarr/appdata-directory
  - https://wiki.servarr.com/radarr/appdata-directory
  - https://wiki.servarr.com/prowlarr/appdata-directory
  - https://wiki.servarr.com/lidarr/appdata-directory
