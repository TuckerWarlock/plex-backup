[CmdletBinding()]
param(
    [string]$BackupRoot = "D:\PlexBackups",
    [int]$RetentionCount = 8
)

$ErrorActionPreference = "Stop"

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

$plexData = Join-Path $env:LOCALAPPDATA "Plex Media Server"
$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

Ensure-Directory -Path $BackupRoot
$runFolder = Join-Path $BackupRoot "PlexBackup_$timestamp"
Ensure-Directory -Path $runFolder

# Stop Plex server before copying DB/settings
$plexService = Get-Service -Name "Plex Media Server" -ErrorAction SilentlyContinue
if ($plexService -and $plexService.Status -eq "Running") {
    Stop-Service -Name "Plex Media Server" -Force
    Start-Sleep -Seconds 5
}
else {
    Get-Process -Name "Plex Media Server" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 5
}

# Backup Plex data folder (exclude cache/logs)
$excludeDirs = @(
    "Cache",
    "Codecs",
    "Crash Reports",
    "Logs"
)
$excludeArgs = $excludeDirs | ForEach-Object { "/XD `"$plexData\$_`"" }
$copyCmd = "robocopy `"$plexData`" `"$runFolder\Plex Media Server`" /MIR /R:2 /W:2 /XJ " + ($excludeArgs -join " ")
cmd /c $copyCmd | Out-Null
if ($LASTEXITCODE -ge 8) {
    throw "Robocopy failed with exit code $LASTEXITCODE"
}

# Backup Windows registry values Plex documents for migration
$registryFile = Join-Path $runFolder "PlexSettings.reg"
reg export "HKCU\Software\Plex, Inc.\Plex Media Server" "$registryFile" /y | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Registry export failed with exit code $LASTEXITCODE"
}

# Start Plex service again
if ($plexService) {
    Start-Service -Name "Plex Media Server"
}

# Include simple manifest
$manifest = [ordered]@{
    backupTimestamp = $timestamp
    computerName = $env:COMPUTERNAME
    dataPath = $plexData
    registryKey = "HKCU\Software\Plex, Inc.\Plex Media Server"
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $runFolder "manifest.json") -Encoding UTF8

# Compress and clean staging
$zipPath = "$runFolder.zip"
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}
Compress-Archive -Path (Join-Path $runFolder "*") -DestinationPath $zipPath -CompressionLevel Optimal
Remove-Item -LiteralPath $runFolder -Recurse -Force

# Retention
Get-ChildItem -Path $BackupRoot -Filter "PlexBackup_*.zip" -File |
    Sort-Object LastWriteTime -Descending |
    Select-Object -Skip $RetentionCount |
    Remove-Item -Force

Write-Host "Plex backup complete: $zipPath"
