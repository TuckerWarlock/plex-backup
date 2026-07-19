[CmdletBinding()]
param(
    [string]$BackupRoot = "D:\PlexBackups",
    [ValidateRange(1, [int]::MaxValue)]
    [int]$RetentionCount = 8,
    [string]$OffsiteDestination = ""
)

$ErrorActionPreference = "Stop"

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Test-ZipIntegrity {
    param([Parameter(Mandatory = $true)][string]$ZipPath)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        if ($archive.Entries.Count -eq 0) {
            throw "Zip '$ZipPath' has no entries"
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Copy-BackupOffsite {
    # Best-effort: local backup already succeeded by the time this runs, so a
    # failure here is a warning, not a script failure.
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][string]$OffsiteDestination,
        [Parameter(Mandatory = $true)][string]$FilePattern,
        [Parameter(Mandatory = $true)][int]$RetentionCount
    )

    try {
        Ensure-Directory -Path $OffsiteDestination
        $offsiteZipPath = Join-Path $OffsiteDestination (Split-Path -Leaf $ZipPath)
        Copy-Item -LiteralPath $ZipPath -Destination $offsiteZipPath -Force
        Write-Host "Copied backup to offsite destination: $offsiteZipPath"

        Get-ChildItem -Path $OffsiteDestination -Filter $FilePattern -File -ErrorAction Stop |
            Sort-Object LastWriteTime -Descending |
            Select-Object -Skip $RetentionCount |
            Remove-Item -Force
    }
    catch {
        Write-Warning "Offsite copy to '$OffsiteDestination' failed: $_. Local backup at '$ZipPath' is unaffected."
    }
}

function Get-PlexExecutablePath {
    # Plex is normally launched as a per-user process, not a Windows service,
    # so there's no service PathName to read in the common case. Fall back to
    # the well-known install locations.
    $candidates = @(
        (Join-Path $env:ProgramFiles "Plex\Plex Media Server\Plex Media Server.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "Plex\Plex Media Server\Plex Media Server.exe")
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }
    return $null
}

$plexData = Join-Path $env:LOCALAPPDATA "Plex Media Server"
$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

Ensure-Directory -Path $BackupRoot
$runFolder = Join-Path $BackupRoot "PlexBackup_$timestamp"
Ensure-Directory -Path $runFolder

$plexService = Get-Service -Name "Plex Media Server" -ErrorAction SilentlyContinue
$plexWasRunning = $false
$plexStoppedViaService = $false

try {
    # Stop Plex before copying DB/settings so files aren't locked or mid-write
    if ($plexService -and $plexService.Status -eq "Running") {
        Stop-Service -Name "Plex Media Server" -Force
        $plexWasRunning = $true
        $plexStoppedViaService = $true
        Start-Sleep -Seconds 5
    }
    else {
        $plexProcesses = Get-Process -Name "Plex Media Server" -ErrorAction SilentlyContinue
        if ($plexProcesses) {
            $plexWasRunning = $true
            $plexProcesses | Stop-Process -Force
            Start-Sleep -Seconds 5
        }
    }

    try {
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
    }
    finally {
        # Always attempt to bring Plex back, even if the backup step above
        # threw. A failed restart is reported as a warning, not a terminating
        # error, so it never masks the original failure (if any).
        if ($plexWasRunning) {
            try {
                if ($plexStoppedViaService) {
                    Start-Service -Name "Plex Media Server"
                }
                else {
                    $plexExe = Get-PlexExecutablePath
                    if ($plexExe) {
                        Start-Process -FilePath $plexExe
                    }
                    else {
                        Write-Warning "Plex was running as a process (not a service) and its install path could not be found. Start Plex manually."
                    }
                }
            }
            catch {
                Write-Warning "Failed to restart Plex: $_"
            }
        }
    }

    # Include simple manifest
    $manifest = [ordered]@{
        backupTimestamp = $timestamp
        computerName    = $env:COMPUTERNAME
        dataPath        = $plexData
        registryKey     = "HKCU\Software\Plex, Inc.\Plex Media Server"
    }
    $manifest | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $runFolder "manifest.json") -Encoding UTF8

    # Compress and clean staging
    $zipPath = "$runFolder.zip"
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }
    Compress-Archive -Path (Join-Path $runFolder "*") -DestinationPath $zipPath -CompressionLevel Optimal
    Test-ZipIntegrity -ZipPath $zipPath
    Remove-Item -LiteralPath $runFolder -Recurse -Force
}
catch {
    # Don't leave partial staging output or a corrupt zip behind on failure
    if (Test-Path -LiteralPath $runFolder) {
        Remove-Item -LiteralPath $runFolder -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($zipPath -and (Test-Path -LiteralPath $zipPath)) {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    }
    throw
}

# Retention
Get-ChildItem -Path $BackupRoot -Filter "PlexBackup_*.zip" -File |
    Sort-Object LastWriteTime -Descending |
    Select-Object -Skip $RetentionCount |
    Remove-Item -Force

if ($OffsiteDestination) {
    Copy-BackupOffsite -ZipPath $zipPath -OffsiteDestination $OffsiteDestination -FilePattern "PlexBackup_*.zip" -RetentionCount $RetentionCount
}

Write-Host "Plex backup complete: $zipPath"
