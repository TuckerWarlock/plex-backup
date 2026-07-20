# Windows Plex Backup Plan

This script creates a weekly Plex backup zip containing:

1. Plex data directory (`%LOCALAPPDATA%\Plex Media Server`)
2. Plex Windows registry settings (`HKCU\Software\Plex, Inc.\Plex Media Server`)

Script: `server/backup-plex-server.ps1`

## Paths and keys

- Plex data folder (Plex docs): `%LOCALAPPDATA%\Plex Media Server`
- Registry key (Plex migration docs): `HKEY_CURRENT_USER\Software\Plex, Inc.\Plex Media Server\`

Because this key is under `HKCU`, run backup/restore using the same Windows user profile Plex runs under. If the scheduled task is ever changed to run as a different account (e.g. `SYSTEM`), `%LOCALAPPDATA%` and `HKCU` will resolve to that account's profile, not Plex's — the backup will silently capture the wrong (or empty) data.

## Stop/restart behavior

The script stops Plex before copying (service if installed as one, otherwise the `Plex Media Server` process — most Windows installs run Plex as a plain process, not a service) and always attempts to restart it afterward, even if the backup itself fails partway through. If Plex was running as a process and its install path can't be found under `Program Files`, the script logs a warning instead of failing silently — check for that warning if Plex doesn't come back up after a run.

## Run manually

```powershell
powershell -ExecutionPolicy Bypass -File "C:\path\to\repo\server\backup-plex-server.ps1" `
  -BackupRoot "D:\PlexBackups" `
  -RetentionCount 8
```

`-RetentionCount` must be at least `1` — the script always keeps the most recently created backup regardless of the value.

### Offsite/network destination

```powershell
powershell -ExecutionPolicy Bypass -File "C:\path\to\repo\server\backup-plex-server.ps1" `
  -BackupRoot "D:\PlexBackups" `
  -OffsiteDestination "\\nas\Backups\PlexBackups"
```
`-BackupRoot` stays local — Plex stays stopped for the local copy only, not for however long a network copy would take. Once the local zip is created and passes its integrity check, it's copied to `-OffsiteDestination` (any path the account can write to — UNC share or mapped drive) and the same `-RetentionCount` policy is applied there independently. A failed offsite copy is logged as a warning only; it doesn't affect the local backup.

## Schedule weekly (Task Scheduler)

```cmd
schtasks /Create /TN "Plex Weekly Backup" /SC WEEKLY /D SUN /ST 03:00 /RL HIGHEST /TR "powershell -ExecutionPolicy Bypass -File C:\path\to\repo\server\backup-plex-server.ps1 -BackupRoot D:\PlexBackups -RetentionCount 8" /F
```

## Restore notes (Windows to Windows)

1. Install Plex on destination system and stop Plex.
2. Extract chosen `PlexBackup_*.zip`.
3. Replace `%LOCALAPPDATA%\Plex Media Server` with the extracted data.
4. Import `PlexSettings.reg`.
5. Start Plex and verify libraries.

Before migration/restore, disable **Empty trash automatically after every scan** in Plex server settings.

## Sources

- Plex move/migration guide: https://support.plex.tv/articles/201370363-move-an-install-to-another-system/
- Plex data directory locations: https://support.plex.tv/articles/202915258-where-is-the-plex-media-server-data-directory-located/
