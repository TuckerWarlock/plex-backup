# plex-backup

Windows-focused backup scripts for:

- **Plex server** configuration and database restore readiness
- **VM / media stack** backups (Documents, optional Hyper-V export, Sonarr/Radarr/Prowlarr/Bazarr/Jackett/qBittorrent)

## Repository layout

- `server/`
  - `backup-plex-server.ps1`
  - `README.md`
- `vm/`
  - `backup-vm-and-media-stack.ps1`
  - `README.md`

## Quick start

Run from PowerShell on your Windows host:

```powershell
powershell -ExecutionPolicy Bypass -File ".\server\backup-plex-server.ps1"
powershell -ExecutionPolicy Bypass -File ".\vm\backup-vm-and-media-stack.ps1"
```

For scheduling and restore steps, use each directory's `README.md`.
