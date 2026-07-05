# Windows VM + arr Stack Backup Plan

This plan creates one weekly backup zip that includes:

1. Your Windows **Documents** folder.
2. Optional **Hyper-V VM exports** (if you pass VM names).
3. Backup payloads for **Sonarr, Radarr, Prowlarr, Bazarr, Jackett, qBittorrent**.

Script: `vm/backup-vm-and-media-stack.ps1`

## Why these paths

- Servarr appdata defaults on Windows are:
  - `C:\ProgramData\Sonarr`
  - `C:\ProgramData\Radarr`
  - `C:\ProgramData\Prowlarr`
  These are from Servarr Wiki appdata pages.
- Sonarr/Radarr/Prowlarr have built-in backup functions in `System => Backups` (Servarr Wiki system pages), so this plan copies recent backup zips from each app's `Backups` folder.
- TRaSH Guides qBittorrent pages focus on path consistency and shared-root layouts; this plan backs up qBittorrent directly from Windows profile paths.

## What the script backs up

- **Documents**
  - `%USERPROFILE%\Documents`
- **Sonarr**
  - `C:\ProgramData\Sonarr\Backups\*.zip` (latest N files)
- **Radarr**
  - `C:\ProgramData\Radarr\Backups\*.zip` (latest N files)
- **Prowlarr**
  - `C:\ProgramData\Prowlarr\Backups\*.zip` (latest N files)
- **Bazarr**
  - `C:\ProgramData\Bazarr` (full directory copy)
- **Jackett**
  - `C:\ProgramData\Jackett` (full directory copy)
- **qBittorrent**
  - `%APPDATA%\qBittorrent`
  - `%LOCALAPPDATA%\qBittorrent`
- **Hyper-V (optional)**
  - `Export-VM` output for each VM name you pass

The script writes a `manifest.json` inside each backup zip so you can see exactly what was captured.

## Run manually

```powershell
powershell -ExecutionPolicy Bypass -File "C:\path\to\repo\vm\backup-vm-and-media-stack.ps1" `
  -BackupRoot "D:\ServerBackups" `
  -RetentionCount 8 `
  -ArrBackupCopiesPerApp 4 `
  -HyperVVMNames @("MediaVM")
```

If you don't use Hyper-V, omit `-HyperVVMNames`.

## Schedule weekly (Task Scheduler)

```cmd
schtasks /Create /TN "Weekly VM+ARR Backup" /SC WEEKLY /D SUN /ST 03:30 /RL HIGHEST /TR "powershell -ExecutionPolicy Bypass -File C:\path\to\repo\vm\backup-vm-and-media-stack.ps1 -BackupRoot D:\ServerBackups -RetentionCount 8 -ArrBackupCopiesPerApp 4" /F
```

## Restore notes

1. Extract the selected backup zip.
2. Restore each app before first launch (or while app/service is stopped):
   - Sonarr/Radarr/Prowlarr: use app restore flow from backup zip if preferred.
   - Bazarr/Jackett/qBittorrent: restore copied config/data folders.
3. For Hyper-V, import or register from exported VM folders.
4. Start services and validate app health.

## Sources

- TRaSH Guides: https://trash-guides.info/
- TRaSH qBittorrent paths: https://trash-guides.info/Downloaders/qBittorrent/Paths/
- Servarr Wiki appdata pages:
  - https://wiki.servarr.com/sonarr/appdata-directory
  - https://wiki.servarr.com/radarr/appdata-directory
  - https://wiki.servarr.com/prowlarr/appdata-directory
