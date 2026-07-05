# Windows Plex Backup Plan

This script creates a weekly Plex backup zip containing:

1. Plex data directory (`%LOCALAPPDATA%\Plex Media Server`)
2. Plex Windows registry settings (`HKCU\Software\Plex, Inc.\Plex Media Server`)

Script: `windows/backup-plex-server.ps1`

## Paths and keys

- Plex data folder (Plex docs): `%LOCALAPPDATA%\Plex Media Server`
- Registry key (Plex migration docs): `HKEY_CURRENT_USER\Software\Plex, Inc.\Plex Media Server\`

Because this key is under `HKCU`, run backup/restore using the same Windows user profile Plex runs under.

## Run manually

```powershell
powershell -ExecutionPolicy Bypass -File "C:\path\to\repo\windows\backup-plex-server.ps1" `
  -BackupRoot "D:\PlexBackups" `
  -RetentionCount 8
```

## Schedule weekly (Task Scheduler)

```cmd
schtasks /Create /TN "Plex Weekly Backup" /SC WEEKLY /D SUN /ST 03:00 /RL HIGHEST /TR "powershell -ExecutionPolicy Bypass -File C:\path\to\repo\windows\backup-plex-server.ps1 -BackupRoot D:\PlexBackups -RetentionCount 8" /F
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
