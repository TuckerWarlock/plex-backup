# plex-backup

Windows-focused backup scripts for:

- **Plex server** configuration and database restore readiness
- **VM / media stack** backups for the indexer/downloader/monitor VM (Documents, optional Hyper-V export, Sonarr/Radarr/Prowlarr/Bazarr/Jackett/qBittorrent), written to `\\TUCKER-DESKTOP\Shared R Drive\VM Backups` by default

## Repository layout

- `server/`
  - `backup-plex-server.ps1`
  - `README.md`
- `vm/`
  - `backup-vm-and-media-stack.ps1`
  - `README.md`

## Quick start

Run from PowerShell on the machine being backed up:

```powershell
# On the Plex server
powershell -ExecutionPolicy Bypass -File ".\server\backup-plex-server.ps1"
# On the indexer/downloader/monitor VM, from an elevated prompt
powershell -ExecutionPolicy Bypass -File ".\vm\backup-vm-and-media-stack.ps1"
```

For scheduling and restore steps, use each directory's `README.md`.
