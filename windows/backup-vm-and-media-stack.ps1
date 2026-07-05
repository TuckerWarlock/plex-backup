[CmdletBinding()]
param(
    [string]$BackupRoot = "D:\ServerBackups",
    [int]$RetentionCount = 8,
    [int]$ArrBackupCopiesPerApp = 4,
    [string[]]$HyperVVMNames = @(),
    [switch]$SkipHyperVExport
)

$ErrorActionPreference = "Stop"

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Copy-DirectoryIfExists {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        Write-Warning "Skipping missing path: $Source"
        return $false
    }

    Ensure-Directory -Path $Destination
    $robocopyArgs = @(
        "`"$Source`"",
        "`"$Destination`"",
        "/E",
        "/R:2",
        "/W:2",
        "/COPY:DAT",
        "/DCOPY:T",
        "/XJ",
        "/NFL",
        "/NDL",
        "/NJH",
        "/NJS",
        "/NP"
    )
    cmd /c ("robocopy " + ($robocopyArgs -join " ")) | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw "Robocopy failed for '$Source' -> '$Destination' with exit code $LASTEXITCODE"
    }

    return $true
}

function Copy-NewestFiles {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [Parameter(Mandatory = $true)][string]$Filter,
        [Parameter(Mandatory = $true)][string]$DestinationDir,
        [int]$KeepCount = 4
    )

    if (-not (Test-Path -LiteralPath $SourceDir)) {
        Write-Warning "Skipping missing path: $SourceDir"
        return 0
    }

    Ensure-Directory -Path $DestinationDir
    $files = Get-ChildItem -Path $SourceDir -Filter $Filter -File -ErrorAction Stop |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First $KeepCount

    foreach ($file in $files) {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $DestinationDir $file.Name) -Force
    }

    return $files.Count
}

$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
Ensure-Directory -Path $BackupRoot

$runFolder = Join-Path $BackupRoot "vm-media-backup_$timestamp"
$stagingRoot = Join-Path $runFolder "staging"
Ensure-Directory -Path $stagingRoot

$manifest = [ordered]@{
    backupTimestamp = $timestamp
    computerName = $env:COMPUTERNAME
    backupRoot = $BackupRoot
    included = [ordered]@{
        documents = $false
        hyperV = @()
        apps = @{}
    }
}

# 1) Documents folder
$documentsPath = [Environment]::GetFolderPath("MyDocuments")
$documentsDest = Join-Path $stagingRoot "Documents"
$manifest.included.documents = Copy-DirectoryIfExists -Source $documentsPath -Destination $documentsDest

# 2) Hyper-V export (optional)
if (-not $SkipHyperVExport -and $HyperVVMNames.Count -gt 0) {
    $exportVmCommand = Get-Command -Name "Export-VM" -ErrorAction SilentlyContinue
    if ($null -eq $exportVmCommand) {
        Write-Warning "Hyper-V Export-VM command is unavailable. Skipping VM export."
    }
    else {
        $hyperVDestination = Join-Path $stagingRoot "HyperV"
        Ensure-Directory -Path $hyperVDestination

        foreach ($vmName in $HyperVVMNames) {
            Write-Host "Exporting Hyper-V VM: $vmName"
            Export-VM -Name $vmName -Path $hyperVDestination -ErrorAction Stop | Out-Null
            $manifest.included.hyperV += $vmName
        }
    }
}

# 3) arr stack and download clients
$apps = @(
    @{
        Name = "Sonarr"
        Mode = "NewestBackups"
        Source = "C:\ProgramData\Sonarr\Backups"
        Filter = "*.zip"
    },
    @{
        Name = "Radarr"
        Mode = "NewestBackups"
        Source = "C:\ProgramData\Radarr\Backups"
        Filter = "*.zip"
    },
    @{
        Name = "Prowlarr"
        Mode = "NewestBackups"
        Source = "C:\ProgramData\Prowlarr\Backups"
        Filter = "*.zip"
    },
    @{
        Name = "Bazarr"
        Mode = "DirectoryCopy"
        Source = "C:\ProgramData\Bazarr"
    },
    @{
        Name = "Jackett"
        Mode = "DirectoryCopy"
        Source = "C:\ProgramData\Jackett"
    }
)

foreach ($app in $apps) {
    $appName = $app.Name
    $appDest = Join-Path $stagingRoot ("Apps\" + $appName)

    if ($app.Mode -eq "NewestBackups") {
        $copiedCount = Copy-NewestFiles -SourceDir $app.Source -Filter $app.Filter -DestinationDir $appDest -KeepCount $ArrBackupCopiesPerApp
        $manifest.included.apps[$appName] = @{
            mode = "NewestBackups"
            source = $app.Source
            copiedFiles = $copiedCount
        }
    }
    else {
        $copied = Copy-DirectoryIfExists -Source $app.Source -Destination $appDest
        $manifest.included.apps[$appName] = @{
            mode = "DirectoryCopy"
            source = $app.Source
            copied = $copied
        }
    }
}

# 4) qBittorrent
$qbtDest = Join-Path $stagingRoot "Apps\qBittorrent"
Ensure-Directory -Path $qbtDest

$qbtbar = Get-Command -Name "qbtbar" -ErrorAction SilentlyContinue
if ($null -ne $qbtbar) {
    $qbtbarOut = Join-Path $qbtDest "qbtbar"
    Ensure-Directory -Path $qbtbarOut
    & $qbtbar.Source -b $qbtbarOut
    if ($LASTEXITCODE -ne 0) {
        throw "qbtbar backup failed with exit code $LASTEXITCODE"
    }

    $manifest.included.apps["qBittorrent"] = @{
        mode = "qbtbar"
        destination = $qbtbarOut
    }
}
else {
    $qbtRoaming = Join-Path $env:APPDATA "qBittorrent"
    $qbtLocal = Join-Path $env:LOCALAPPDATA "qBittorrent"
    $roamingCopied = Copy-DirectoryIfExists -Source $qbtRoaming -Destination (Join-Path $qbtDest "Roaming")
    $localCopied = Copy-DirectoryIfExists -Source $qbtLocal -Destination (Join-Path $qbtDest "Local")

    $manifest.included.apps["qBittorrent"] = @{
        mode = "FilesystemCopy"
        roamingPath = $qbtRoaming
        localPath = $qbtLocal
        roamingCopied = $roamingCopied
        localCopied = $localCopied
    }
}

$manifestPath = Join-Path $stagingRoot "manifest.json"
$manifest | ConvertTo-Json -Depth 8 | Set-Content -Path $manifestPath -Encoding UTF8

# 5) Compress run output
$zipPath = "$runFolder.zip"
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}
Compress-Archive -Path (Join-Path $stagingRoot "*") -DestinationPath $zipPath -CompressionLevel Optimal
Remove-Item -LiteralPath $runFolder -Recurse -Force

# 6) Retention
Get-ChildItem -Path $BackupRoot -Filter "vm-media-backup_*.zip" -File |
    Sort-Object LastWriteTime -Descending |
    Select-Object -Skip $RetentionCount |
    Remove-Item -Force

Write-Host "Backup complete: $zipPath"
