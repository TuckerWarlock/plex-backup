[CmdletBinding()]
param(
    [string]$BackupRoot = "D:\ServerBackups",
    [ValidateRange(1, [int]::MaxValue)]
    [int]$RetentionCount = 8,
    [int]$ArrBackupCopiesPerApp = 4,
    [string[]]$HyperVVMNames = @(),
    [switch]$SkipHyperVExport,
    [switch]$SkipDocuments,
    [string]$OffsiteDestination = "",
    [switch]$EstimateOnly
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
    # Sonarr/Radarr/Prowlarr file their backups under Backups\scheduled,
    # Backups\manual, and Backups\update rather than directly in Backups, so
    # this has to recurse to find them.
    $files = Get-ChildItem -Path $SourceDir -Filter $Filter -File -Recurse -ErrorAction Stop |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First $KeepCount

    foreach ($file in $files) {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $DestinationDir $file.Name) -Force
    }

    return $files.Count
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

function Get-DirectorySize {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return 0
    }
    $size = (Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $size) {
        return 0
    }
    return $size
}

function Get-NewestFilesSize {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [Parameter(Mandatory = $true)][string]$Filter,
        [int]$KeepCount = 4
    )
    if (-not (Test-Path -LiteralPath $SourceDir)) {
        return 0
    }
    $files = Get-ChildItem -Path $SourceDir -Filter $Filter -File -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First $KeepCount
    $size = ($files | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $size) {
        return 0
    }
    return $size
}

function Format-Bytes {
    param([Parameter(Mandatory = $true)][double]$Bytes)
    if ($Bytes -ge 1GB) {
        return "{0:N2} GB" -f ($Bytes / 1GB)
    }
    elseif ($Bytes -ge 1MB) {
        return "{0:N2} MB" -f ($Bytes / 1MB)
    }
    elseif ($Bytes -ge 1KB) {
        return "{0:N2} KB" -f ($Bytes / 1KB)
    }
    else {
        return "$Bytes bytes"
    }
}

function Stop-AppIfRunning {
    # Best-effort: service/process names for third-party apps vary by install
    # method. If neither matches, we assume the app isn't running and copy
    # live - same as previous behavior - rather than failing the backup.
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$ServiceName = $Name,
        [string]$ProcessName = $Name
    )

    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($service -and $service.Status -eq "Running") {
        Stop-Service -Name $ServiceName -Force
        Start-Sleep -Seconds 3
        return @{ WasRunning = $true; ViaService = $true; ExecutablePath = $null }
    }

    $processes = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
    if ($processes) {
        # Capture the running exe's own path so a process-based (non-service)
        # install can be relaunched automatically, not just via a guessed path.
        $executablePath = $null
        try {
            $executablePath = $processes | Select-Object -First 1 -ExpandProperty Path -ErrorAction Stop
        }
        catch {
            $executablePath = $null
        }
        $processes | Stop-Process -Force
        Start-Sleep -Seconds 3
        return @{ WasRunning = $true; ViaService = $false; ExecutablePath = $executablePath }
    }

    return @{ WasRunning = $false; ViaService = $false; ExecutablePath = $null }
}

function Start-AppIfWasRunning {
    param(
        [Parameter(Mandatory = $true)][hashtable]$StopState,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$ServiceName = $Name,
        [string]$ExecutablePath
    )

    if (-not $StopState.WasRunning) {
        return
    }

    try {
        if ($StopState.ViaService) {
            Start-Service -Name $ServiceName
        }
        else {
            # Prefer the path captured from the actual running process over a
            # caller-supplied guess (e.g. qBittorrent's Program Files lookup).
            $resolvedPath = if ($StopState.ExecutablePath) { $StopState.ExecutablePath } else { $ExecutablePath }
            if ($resolvedPath) {
                Start-Process -FilePath $resolvedPath
            }
            else {
                Write-Warning "$Name was stopped for backup but could not be relaunched automatically. Start it manually."
            }
        }
    }
    catch {
        Write-Warning "Failed to restart ${Name}: $_"
    }
}

# arr stack and download clients.
# Sonarr/Radarr/Prowlarr/Lidarr/Bazarr only copy already-exported backup
# zips (low risk, app not stopped). Jackett has no built-in backup export,
# so its live app data is copied directly and it's stopped first the same
# way qBittorrent is below.
$apps = @(
    @{
        Name   = "Sonarr"
        Mode   = "NewestBackups"
        Source = "C:\ProgramData\Sonarr\Backups"
        Filter = "*.zip"
    },
    @{
        Name   = "Radarr"
        Mode   = "NewestBackups"
        Source = "C:\ProgramData\Radarr\Backups"
        Filter = "*.zip"
    },
    @{
        Name   = "Prowlarr"
        Mode   = "NewestBackups"
        Source = "C:\ProgramData\Prowlarr\Backups"
        Filter = "*.zip"
    },
    @{
        Name   = "Lidarr"
        Mode   = "NewestBackups"
        Source = "C:\ProgramData\Lidarr\Backups"
        Filter = "*.zip"
    },
    @{
        Name   = "Bazarr"
        Mode   = "NewestBackups"
        Source = "C:\ProgramData\Bazarr\backup"
        Filter = "*.zip"
    },
    @{
        Name             = "Jackett"
        Mode             = "DirectoryCopy"
        Source           = "C:\ProgramData\Jackett"
        ServiceName      = "Jackett"
        ProcessName      = "JackettConsole"
        # Per https://github.com/Jackett/Jackett/issues/2576: ServerConfig.json
        # and Indexers hold the config, but DataProtection holds the keys used
        # to decrypt indexer passwords in that config - without it, a restored
        # config's passwords are permanently unusable even though the file
        # copied fine. All three should already be inside a full directory
        # copy of $Source; this just verifies that actually happened.
        RequiredSubpaths = @("ServerConfig.json", "Indexers", "DataProtection")
    }
)

if ($EstimateOnly) {
    $breakdown = [ordered]@{}
    $total = 0

    if (-not $SkipDocuments) {
        $size = Get-DirectorySize -Path ([Environment]::GetFolderPath("MyDocuments"))
        $breakdown["Documents"] = $size
        $total += $size
    }

    if (-not $SkipHyperVExport -and $HyperVVMNames.Count -gt 0) {
        $getVhd = Get-Command -Name "Get-VMHardDiskDrive" -ErrorAction SilentlyContinue
        foreach ($vmName in $HyperVVMNames) {
            if (-not $getVhd) {
                Write-Warning "Hyper-V cmdlets unavailable; cannot estimate size for VM '$vmName'."
                continue
            }
            try {
                $vhdSize = (Get-VMHardDiskDrive -VMName $vmName -ErrorAction Stop |
                    ForEach-Object { Get-Item -LiteralPath $_.Path -ErrorAction SilentlyContinue } |
                    Measure-Object -Property Length -Sum).Sum
                if ($null -eq $vhdSize) { $vhdSize = 0 }
                $breakdown["HyperV/$vmName"] = $vhdSize
                $total += $vhdSize
            }
            catch {
                Write-Warning "Could not estimate size for VM '$vmName': $_"
            }
        }
    }

    foreach ($app in $apps) {
        if ($app.Mode -eq "NewestBackups") {
            $size = Get-NewestFilesSize -SourceDir $app.Source -Filter $app.Filter -KeepCount $ArrBackupCopiesPerApp
        }
        else {
            $size = Get-DirectorySize -Path $app.Source
        }
        $breakdown[$app.Name] = $size
        $total += $size
    }

    $qbtSize = (Get-DirectorySize -Path (Join-Path $env:APPDATA "qBittorrent")) + (Get-DirectorySize -Path (Join-Path $env:LOCALAPPDATA "qBittorrent"))
    $breakdown["qBittorrent"] = $qbtSize
    $total += $qbtSize

    Write-Host ""
    Write-Host "Estimated backup size (uncompressed source data):"
    foreach ($key in $breakdown.Keys) {
        Write-Host ("  {0,-20} {1}" -f $key, (Format-Bytes -Bytes $breakdown[$key]))
    }
    Write-Host ("  {0,-20} {1}" -f "TOTAL", (Format-Bytes -Bytes $total))
    Write-Host ""
    Write-Host "Actual zip size will typically be smaller due to compression; savings vary by data type."
    exit 0
}

$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
Ensure-Directory -Path $BackupRoot

$runFolder = Join-Path $BackupRoot "vm-media-backup_$timestamp"
$stagingRoot = Join-Path $runFolder "staging"
Ensure-Directory -Path $stagingRoot

$manifest = [ordered]@{
    backupTimestamp = $timestamp
    computerName    = $env:COMPUTERNAME
    backupRoot      = $BackupRoot
    included        = [ordered]@{
        documents = $false
        hyperV    = @()
        apps      = [ordered]@{}
    }
    errors          = @()
}

try {
    # 1) Documents folder
    if ($SkipDocuments) {
        Write-Host "Skipping Documents backup (-SkipDocuments specified)"
    }
    else {
        try {
            $documentsPath = [Environment]::GetFolderPath("MyDocuments")
            $documentsDest = Join-Path $stagingRoot "Documents"
            $manifest.included.documents = Copy-DirectoryIfExists -Source $documentsPath -Destination $documentsDest
        }
        catch {
            Write-Warning "Documents backup failed: $_"
            $manifest.errors += "Documents: $_"
        }
    }

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
                try {
                    Write-Host "Exporting Hyper-V VM: $vmName"
                    Export-VM -Name $vmName -Path $hyperVDestination -ErrorAction Stop | Out-Null
                    $manifest.included.hyperV += $vmName
                }
                catch {
                    Write-Warning "Hyper-V export failed for '$vmName': $_"
                    $manifest.errors += "HyperV/${vmName}: $_"
                }
            }
        }
    }

    # 3) arr stack and download clients ($apps defined above, shared with -EstimateOnly)
    foreach ($app in $apps) {
        $appName = $app.Name
        $appDest = Join-Path $stagingRoot ("Apps\" + $appName)

        try {
            if ($app.Mode -eq "NewestBackups") {
                $copiedCount = Copy-NewestFiles -SourceDir $app.Source -Filter $app.Filter -DestinationDir $appDest -KeepCount $ArrBackupCopiesPerApp
                $manifest.included.apps[$appName] = [ordered]@{
                    mode        = "NewestBackups"
                    source      = $app.Source
                    copiedFiles = $copiedCount
                }
            }
            else {
                $stopState = Stop-AppIfRunning -Name $appName -ServiceName $app.ServiceName -ProcessName $app.ProcessName
                try {
                    $copied = Copy-DirectoryIfExists -Source $app.Source -Destination $appDest

                    $missingRequired = @()
                    if ($copied -and $app.RequiredSubpaths) {
                        foreach ($subpath in $app.RequiredSubpaths) {
                            if (-not (Test-Path -LiteralPath (Join-Path $appDest $subpath))) {
                                $missingRequired += $subpath
                            }
                        }
                        if ($missingRequired.Count -gt 0) {
                            $warningText = "$appName backup is missing expected path(s): $($missingRequired -join ', '). Restore may be incomplete."
                            Write-Warning $warningText
                            $manifest.errors += $warningText
                        }
                    }

                    $manifest.included.apps[$appName] = [ordered]@{
                        mode            = "DirectoryCopy"
                        source          = $app.Source
                        copied          = $copied
                        missingRequired = $missingRequired
                    }
                }
                finally {
                    Start-AppIfWasRunning -StopState $stopState -Name $appName -ServiceName $app.ServiceName
                }
            }
        }
        catch {
            Write-Warning "$appName backup failed: $_"
            $manifest.errors += "${appName}: $_"
            $manifest.included.apps[$appName] = [ordered]@{
                mode  = $app.Mode
                error = "$_"
            }
        }
    }

    # 4) qBittorrent (PowerShell/filesystem backup) - stop first since
    # session/resume data can be mid-write while the app is running.
    try {
        $qbtStopState = Stop-AppIfRunning -Name "qBittorrent" -ServiceName "qBittorrent" -ProcessName "qbittorrent"
        try {
            $qbtDest = Join-Path $stagingRoot "Apps\qBittorrent"
            Ensure-Directory -Path $qbtDest

            $qbtRoaming = Join-Path $env:APPDATA "qBittorrent"
            $qbtLocal = Join-Path $env:LOCALAPPDATA "qBittorrent"
            $roamingCopied = Copy-DirectoryIfExists -Source $qbtRoaming -Destination (Join-Path $qbtDest "Roaming")
            $localCopied = Copy-DirectoryIfExists -Source $qbtLocal -Destination (Join-Path $qbtDest "Local")

            $manifest.included.apps["qBittorrent"] = [ordered]@{
                mode          = "FilesystemCopy"
                roamingPath   = $qbtRoaming
                localPath     = $qbtLocal
                roamingCopied = $roamingCopied
                localCopied   = $localCopied
            }
        }
        finally {
            $qbtExePath = @(
                (Join-Path $env:ProgramFiles "qBittorrent\qbittorrent.exe"),
                (Join-Path ${env:ProgramFiles(x86)} "qBittorrent\qbittorrent.exe")
            ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1

            Start-AppIfWasRunning -StopState $qbtStopState -Name "qBittorrent" -ServiceName "qBittorrent" -ExecutablePath $qbtExePath
        }
    }
    catch {
        Write-Warning "qBittorrent backup failed: $_"
        $manifest.errors += "qBittorrent: $_"
        $manifest.included.apps["qBittorrent"] = [ordered]@{
            mode  = "FilesystemCopy"
            error = "$_"
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
    Test-ZipIntegrity -ZipPath $zipPath
}
catch {
    # Fatal, non-component-scoped failure (e.g. can't write to $BackupRoot at
    # all, or a corrupt zip) - don't leave partial staging output or a bad
    # zip behind.
    if (Test-Path -LiteralPath $runFolder) {
        Remove-Item -LiteralPath $runFolder -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($zipPath -and (Test-Path -LiteralPath $zipPath)) {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    }
    throw
}

# Staging cleanup is best-effort now that the zip is verified - a transient
# file lock here (AV scan, indexer) shouldn't cost us an already-valid backup.
if (Test-Path -LiteralPath $runFolder) {
    try {
        Remove-Item -LiteralPath $runFolder -Recurse -Force
    }
    catch {
        Write-Warning "Could not remove staging folder '$runFolder': $_. The zip at '$zipPath' is valid; clean it up manually."
    }
}

# 6) Retention
Get-ChildItem -Path $BackupRoot -Filter "vm-media-backup_*.zip" -File |
    Sort-Object LastWriteTime -Descending |
    Select-Object -Skip $RetentionCount |
    Remove-Item -Force

if ($OffsiteDestination) {
    Copy-BackupOffsite -ZipPath $zipPath -OffsiteDestination $OffsiteDestination -FilePattern "vm-media-backup_*.zip" -RetentionCount $RetentionCount
}

if ($manifest.errors.Count -gt 0) {
    Write-Warning "Backup completed with $($manifest.errors.Count) component failure(s), see manifest.json inside: $zipPath"
}
else {
    Write-Host "Backup complete: $zipPath"
}
