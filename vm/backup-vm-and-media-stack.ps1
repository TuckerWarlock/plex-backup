[CmdletBinding()]
param(
    # Final destination for backup zips, logs, and last-success.json.
    [string]$BackupRoot = "\\TUCKER-DESKTOP\Shared R Drive\VM Backups",
    # Local working area. Staging and zipping happen here so app downtime and
    # zip creation never depend on network speed; only the finished, verified
    # zip is copied to $BackupRoot.
    [string]$StagingRoot = (Join-Path $env:LOCALAPPDATA "vm-media-backup\staging"),
    [string]$LogRoot = (Join-Path $env:LOCALAPPDATA "vm-media-backup\logs"),
    [ValidateRange(1, [int]::MaxValue)]
    [int]$RetentionCount = 8,
    [ValidateRange(1, [int]::MaxValue)]
    [int]$LogRetentionCount = 30,
    [int]$ArrBackupCopiesPerApp = 4,
    [string[]]$HyperVVMNames = @(),
    [switch]$SkipHyperVExport,
    [switch]$SkipDocuments,
    [string]$OffsiteDestination = "",
    # Every failing step is retried exactly once after this delay, then logged.
    [ValidateRange(0, 3600)]
    [int]$RetryDelaySeconds = 30,
    # qBittorrent is shut down gracefully via its WebUI API, never killed.
    [string]$QbtWebUIUrl = "http://localhost:8080",
    [string]$QbtWebUIUser = "admin",
    # DPAPI-encrypted password (ConvertFrom-SecureString output), readable only
    # by the Windows account that created it. Same file the ProtonVPN port-sync
    # script uses.
    [string]$QbtPasswordFile = (Join-Path $env:LOCALAPPDATA "qBittorrentPassword.txt"),
    [ValidateRange(10, 86400)]
    [int]$QbtShutdownTimeoutSeconds = 600,
    [switch]$EstimateOnly
)

$ErrorActionPreference = "Stop"

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")][string]$Level = "INFO"
    )
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    if ($Level -eq "INFO") {
        Write-Host $line
    }
    else {
        Write-Warning $line
    }
}

function Invoke-WithRetry {
    # Runs $Action; on failure waits $RetryDelaySeconds and tries exactly once
    # more. A second failure is logged and rethrown for the caller to record.
    param(
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    try {
        return & $Action
    }
    catch {
        Write-Log -Level WARN "$Description failed (attempt 1 of 2): $_. Retrying in $RetryDelaySeconds s."
        Start-Sleep -Seconds $RetryDelaySeconds
        try {
            return & $Action
        }
        catch {
            Write-Log -Level ERROR "$Description failed (attempt 2 of 2): $_"
            throw
        }
    }
}

function Add-ComponentError {
    param(
        [Parameter(Mandatory = $true)][string]$Component,
        [Parameter(Mandatory = $true)][string]$Message
    )
    Write-Log -Level ERROR "${Component}: $Message"
    $manifest.errors += "${Component}: $Message"
}

function Test-IsAdmin {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

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
        Write-Log -Level WARN "Skipping missing path: $Source"
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
        Write-Log -Level WARN "Skipping missing path: $SourceDir"
        return 0
    }

    Ensure-Directory -Path $DestinationDir
    # Sonarr/Radarr/Prowlarr file their backups under Backups\scheduled,
    # Backups\manual, and Backups\update rather than directly in Backups, so
    # this has to recurse to find them.
    $files = @(Get-ChildItem -Path $SourceDir -Filter $Filter -File -Recurse -ErrorAction Stop |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First $KeepCount)

    foreach ($file in $files) {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $DestinationDir $file.Name) -Force
    }

    return $files.Count
}

function New-ZipFromDirectory {
    # ZipFile.CreateFromDirectory instead of Compress-Archive: Windows
    # PowerShell 5.1's Compress-Archive skips hidden files/folders (e.g. .git)
    # and is much slower on large trees.
    param(
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [Parameter(Mandatory = $true)][string]$ZipPath
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $ZipPath) {
        Remove-Item -LiteralPath $ZipPath -Force
    }
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $SourceDir,
        $ZipPath,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $false
    )
}

function Test-ZipIntegrity {
    param([Parameter(Mandatory = $true)][string]$ZipPath)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        if ($archive.Entries.Count -eq 0) {
            throw "Zip '$ZipPath' has no entries"
        }
        return $archive.Entries.Count
    }
    finally {
        $archive.Dispose()
    }
}

function Copy-FileVerified {
    # Copies a file and confirms the destination size matches the source.
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$DestinationDir
    )
    Ensure-Directory -Path $DestinationDir
    $destPath = Join-Path $DestinationDir (Split-Path -Leaf $Source)
    Copy-Item -LiteralPath $Source -Destination $destPath -Force
    $srcLen = (Get-Item -LiteralPath $Source).Length
    $dstLen = (Get-Item -LiteralPath $destPath).Length
    if ($srcLen -ne $dstLen) {
        throw "Size mismatch after copy to '$destPath' (source $srcLen bytes, destination $dstLen bytes)"
    }
    return $destPath
}

function Remove-OldFiles {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$Filter,
        [Parameter(Mandatory = $true)][int]$Keep
    )
    Get-ChildItem -LiteralPath $Directory -Filter $Filter -File -ErrorAction Stop |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $Keep |
        Remove-Item -Force
}

function Get-DirectorySize {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return 0
    }
    $size = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
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
    # Used for Jackett. A Windows service stop is a graceful SCM shutdown.
    # Service/process names for third-party apps vary by install method; if
    # neither matches, we assume the app isn't running and copy live.
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$ServiceName = $Name,
        [string]$ProcessName = $Name
    )

    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($service -and $service.Status -eq "Running") {
        Invoke-WithRetry -Description "Stopping $Name service" -Action {
            Stop-Service -Name $ServiceName -Force
        }
        Start-Sleep -Seconds 3
        return @{ WasRunning = $true; ViaService = $true; ExecutablePath = $null }
    }

    $processes = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
    if ($processes) {
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
    # Throws if the app could not be restarted, so the caller records it.
    param(
        [Parameter(Mandatory = $true)][hashtable]$StopState,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$ServiceName = $Name
    )

    if (-not $StopState.WasRunning) {
        return
    }

    if ($StopState.ViaService) {
        Invoke-WithRetry -Description "Starting $Name service" -Action {
            Start-Service -Name $ServiceName
        }
    }
    elseif ($StopState.ExecutablePath) {
        Invoke-WithRetry -Description "Starting $Name" -Action {
            Start-Process -FilePath $StopState.ExecutablePath
        }
    }
    else {
        throw "$Name was stopped for backup but could not be relaunched automatically. Start it manually."
    }
}

function Get-QbtCredential {
    if (-not (Test-Path -LiteralPath $QbtPasswordFile)) {
        throw "qBittorrent WebUI password file not found at '$QbtPasswordFile'. See vm/README.md 'qBittorrent graceful shutdown'."
    }
    $secure = Get-Content -LiteralPath $QbtPasswordFile -ErrorAction Stop | ConvertTo-SecureString
    return New-Object System.Management.Automation.PSCredential($QbtWebUIUser, $secure)
}

function Stop-QbittorrentGracefully {
    # Asks qBittorrent to quit through its WebUI API so it saves resume data
    # and closes cleanly, then waits for the process to exit. Never kills it:
    # if it doesn't exit within $QbtShutdownTimeoutSeconds this throws and
    # qBittorrent is left running untouched.
    $proc = Get-Process -Name "qbittorrent" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $proc) {
        Write-Log "qBittorrent is not running; copying its data as-is."
        return @{ WasRunning = $false; ExecutablePath = $null }
    }

    $executablePath = $proc.Path
    $credential = Get-QbtCredential

    $requestError = $null
    try {
        Invoke-WithRetry -Description "qBittorrent WebUI shutdown request" -Action {
            if ($proc.HasExited) {
                return
            }
            $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
            $login = Invoke-WebRequest -Uri "$QbtWebUIUrl/api/v2/auth/login" -Method Post -WebSession $session -UseBasicParsing -TimeoutSec 15 -Body @{
                username = $credential.UserName
                password = $credential.GetNetworkCredential().Password
            }
            if ($login.Content -ne "Ok.") {
                throw "WebUI login rejected (response '$($login.Content)')"
            }
            Invoke-WebRequest -Uri "$QbtWebUIUrl/api/v2/app/shutdown" -Method Post -WebSession $session -UseBasicParsing -TimeoutSec 15 | Out-Null
        }
    }
    catch {
        # The request can error out even though shutdown began (e.g. the
        # connection drops as the WebUI goes down), so still check whether the
        # process exits before treating this as a failure.
        $requestError = $_
    }

    $waitSeconds = if ($requestError) { 30 } else { $QbtShutdownTimeoutSeconds }
    Write-Log "Waiting up to $waitSeconds s for qBittorrent (PID $($proc.Id)) to exit..."
    $sw = [Diagnostics.Stopwatch]::StartNew()
    if (-not $proc.WaitForExit($waitSeconds * 1000)) {
        $reason = if ($requestError) { "shutdown request failed: $requestError" } else { "did not exit within $QbtShutdownTimeoutSeconds s" }
        throw "qBittorrent $reason. It was left running (not force-killed) and its data was not copied."
    }
    Write-Log ("qBittorrent exited cleanly after {0:N0} s." -f $sw.Elapsed.TotalSeconds)
    return @{ WasRunning = $true; ExecutablePath = $executablePath }
}

function Start-QbittorrentUnelevated {
    param([string]$ExecutablePath)

    if (-not $ExecutablePath) {
        $ExecutablePath = @(
            (Join-Path $env:ProgramFiles "qBittorrent\qbittorrent.exe"),
            (Join-Path ${env:ProgramFiles(x86)} "qBittorrent\qbittorrent.exe")
        ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    }
    if (-not $ExecutablePath) {
        throw "qBittorrent was stopped for backup but its executable could not be found. Start it manually."
    }

    Invoke-WithRetry -Description "Restarting qBittorrent" -Action {
        if (Get-Process -Name "qbittorrent" -ErrorAction SilentlyContinue) {
            return
        }
        if (Test-IsAdmin) {
            # This script runs elevated (Jackett service control needs it).
            # Launching through explorer.exe hands the start to the user's
            # existing desktop shell, so qBittorrent comes back unelevated in
            # the user's session - the same way it normally runs.
            Start-Process -FilePath "explorer.exe" -ArgumentList "`"$ExecutablePath`""
        }
        else {
            Start-Process -FilePath $ExecutablePath
        }
        $deadline = (Get-Date).AddSeconds(60)
        while (-not (Get-Process -Name "qbittorrent" -ErrorAction SilentlyContinue)) {
            if ((Get-Date) -gt $deadline) {
                throw "qBittorrent process did not appear within 60 s of launch"
            }
            Start-Sleep -Seconds 2
        }
    }
    Write-Log "qBittorrent restarted."
}

# arr stack.
# Sonarr/Radarr/Prowlarr/Bazarr only copy already-exported backup zips (low
# risk, app not stopped). Jackett has no built-in backup export, so its live
# app data is copied directly and its service is stopped first.
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

if (-not (Test-IsAdmin)) {
    throw "Run this script elevated (Run as administrator): stopping/starting the Jackett service requires it."
}

$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$backupName = "vm-media-backup_$timestamp"
Ensure-Directory -Path $LogRoot
$logFile = Join-Path $LogRoot "$backupName.log"
Start-Transcript -Path $logFile -Force | Out-Null

$exitCode = 0
$runFolder = Join-Path $StagingRoot $backupName
$payloadRoot = Join-Path $runFolder "staging"
$zipPath = Join-Path $StagingRoot "$backupName.zip"
$uploaded = $false

$manifest = [ordered]@{
    backupTimestamp = $timestamp
    computerName    = $env:COMPUTERNAME
    backupRoot      = $BackupRoot
    logFile         = "$backupName.log"
    included        = [ordered]@{
        documents = $false
        hyperV    = @()
        apps      = [ordered]@{}
    }
    errors          = @()
}

try {
    Write-Log "Starting $backupName -> $BackupRoot"
    Ensure-Directory -Path $payloadRoot

    # 1) Documents folder
    if ($SkipDocuments) {
        Write-Log "Skipping Documents backup (-SkipDocuments specified)"
    }
    else {
        try {
            $documentsPath = [Environment]::GetFolderPath("MyDocuments")
            $documentsDest = Join-Path $payloadRoot "Documents"
            $manifest.included.documents = Invoke-WithRetry -Description "Documents copy" -Action {
                Copy-DirectoryIfExists -Source $documentsPath -Destination $documentsDest
            }
            Write-Log "Documents copied."
        }
        catch {
            Add-ComponentError -Component "Documents" -Message "$_"
        }
    }

    # 2) Hyper-V export (optional)
    if (-not $SkipHyperVExport -and $HyperVVMNames.Count -gt 0) {
        $exportVmCommand = Get-Command -Name "Export-VM" -ErrorAction SilentlyContinue
        if ($null -eq $exportVmCommand) {
            Add-ComponentError -Component "HyperV" -Message "Export-VM command is unavailable; VM export skipped."
        }
        else {
            $hyperVDestination = Join-Path $payloadRoot "HyperV"
            Ensure-Directory -Path $hyperVDestination

            foreach ($vmName in $HyperVVMNames) {
                try {
                    Write-Log "Exporting Hyper-V VM: $vmName"
                    Invoke-WithRetry -Description "Hyper-V export of '$vmName'" -Action {
                        $partial = Join-Path $hyperVDestination $vmName
                        if (Test-Path -LiteralPath $partial) {
                            Remove-Item -LiteralPath $partial -Recurse -Force
                        }
                        Export-VM -Name $vmName -Path $hyperVDestination -ErrorAction Stop | Out-Null
                    }
                    $manifest.included.hyperV += $vmName
                }
                catch {
                    Add-ComponentError -Component "HyperV/$vmName" -Message "$_"
                }
            }
        }
    }

    # 3) arr stack ($apps defined above, shared with -EstimateOnly)
    foreach ($app in $apps) {
        $appName = $app.Name
        $appDest = Join-Path $payloadRoot ("Apps\" + $appName)

        try {
            if ($app.Mode -eq "NewestBackups") {
                $copiedCount = Invoke-WithRetry -Description "$appName backup copy" -Action {
                    Copy-NewestFiles -SourceDir $app.Source -Filter $app.Filter -DestinationDir $appDest -KeepCount $ArrBackupCopiesPerApp
                }
                $manifest.included.apps[$appName] = [ordered]@{
                    mode        = "NewestBackups"
                    source      = $app.Source
                    copiedFiles = $copiedCount
                }
                if ($copiedCount -eq 0) {
                    Add-ComponentError -Component $appName -Message "No backup zips found under '$($app.Source)'. Check the app's scheduled backup setting."
                }
                else {
                    Write-Log "$appName : copied $copiedCount backup zip(s)."
                }
            }
            else {
                $stopState = Stop-AppIfRunning -Name $appName -ServiceName $app.ServiceName -ProcessName $app.ProcessName
                try {
                    $copied = Invoke-WithRetry -Description "$appName directory copy" -Action {
                        Copy-DirectoryIfExists -Source $app.Source -Destination $appDest
                    }

                    $missingRequired = @()
                    if ($copied -and $app.RequiredSubpaths) {
                        foreach ($subpath in $app.RequiredSubpaths) {
                            if (-not (Test-Path -LiteralPath (Join-Path $appDest $subpath))) {
                                $missingRequired += $subpath
                            }
                        }
                        if ($missingRequired.Count -gt 0) {
                            Add-ComponentError -Component $appName -Message "Backup is missing expected path(s): $($missingRequired -join ', '). Restore may be incomplete."
                        }
                    }

                    $manifest.included.apps[$appName] = [ordered]@{
                        mode            = "DirectoryCopy"
                        source          = $app.Source
                        copied          = $copied
                        missingRequired = $missingRequired
                    }
                    Write-Log "$appName : directory copied."
                }
                finally {
                    try {
                        Start-AppIfWasRunning -StopState $stopState -Name $appName -ServiceName $app.ServiceName
                    }
                    catch {
                        Add-ComponentError -Component "$appName restart" -Message "$_"
                    }
                }
            }
        }
        catch {
            Add-ComponentError -Component $appName -Message "$_"
            $manifest.included.apps[$appName] = [ordered]@{
                mode  = $app.Mode
                error = "$_"
            }
        }
    }

    # 4) qBittorrent - shut down gracefully first since session/resume data
    # is written on exit and can be mid-write while the app is running.
    try {
        $qbtStopState = Stop-QbittorrentGracefully
        try {
            $qbtDest = Join-Path $payloadRoot "Apps\qBittorrent"
            Ensure-Directory -Path $qbtDest

            $qbtRoaming = Join-Path $env:APPDATA "qBittorrent"
            $qbtLocal = Join-Path $env:LOCALAPPDATA "qBittorrent"
            $roamingCopied = Invoke-WithRetry -Description "qBittorrent roaming profile copy" -Action {
                Copy-DirectoryIfExists -Source $qbtRoaming -Destination (Join-Path $qbtDest "Roaming")
            }
            $localCopied = Invoke-WithRetry -Description "qBittorrent local profile copy" -Action {
                Copy-DirectoryIfExists -Source $qbtLocal -Destination (Join-Path $qbtDest "Local")
            }

            $manifest.included.apps["qBittorrent"] = [ordered]@{
                mode          = "FilesystemCopy"
                roamingPath   = $qbtRoaming
                localPath     = $qbtLocal
                roamingCopied = $roamingCopied
                localCopied   = $localCopied
            }
            Write-Log "qBittorrent profile data copied."
        }
        finally {
            if ($qbtStopState.WasRunning) {
                try {
                    Start-QbittorrentUnelevated -ExecutablePath $qbtStopState.ExecutablePath
                }
                catch {
                    Add-ComponentError -Component "qBittorrent restart" -Message "$_"
                }
            }
        }
    }
    catch {
        Add-ComponentError -Component "qBittorrent" -Message "$_"
        $manifest.included.apps["qBittorrent"] = [ordered]@{
            mode  = "FilesystemCopy"
            error = "$_"
        }
    }

    $manifestPath = Join-Path $payloadRoot "manifest.json"
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -Path $manifestPath -Encoding UTF8

    # 5) Compress locally and verify
    Write-Log "Creating zip..."
    Invoke-WithRetry -Description "Zip creation" -Action {
        New-ZipFromDirectory -SourceDir $payloadRoot -ZipPath $zipPath
        $entries = Test-ZipIntegrity -ZipPath $zipPath
        Write-Log ("Zip verified: {0} entries, {1}" -f $entries, (Format-Bytes -Bytes (Get-Item -LiteralPath $zipPath).Length))
    }
    Remove-Item -LiteralPath $runFolder -Recurse -Force -ErrorAction SilentlyContinue

    # 6) Upload to $BackupRoot
    try {
        $remoteZip = Invoke-WithRetry -Description "Upload to '$BackupRoot'" -Action {
            Copy-FileVerified -Source $zipPath -DestinationDir $BackupRoot
        }
        $uploaded = $true
        Write-Log "Uploaded: $remoteZip"
        Remove-Item -LiteralPath $zipPath -Force
    }
    catch {
        # The verified zip stays in $StagingRoot so the backup isn't lost.
        Add-ComponentError -Component "Upload" -Message "$_. The verified zip was kept locally at '$zipPath'."
    }

    # 7) Retention (only after a successful upload, so a failed run never
    # rotates out a good backup)
    if ($uploaded) {
        try {
            Invoke-WithRetry -Description "Retention in '$BackupRoot'" -Action {
                Remove-OldFiles -Directory $BackupRoot -Filter "vm-media-backup_*.zip" -Keep $RetentionCount
            }
        }
        catch {
            Add-ComponentError -Component "Retention" -Message "$_"
        }

        if ($OffsiteDestination) {
            try {
                Invoke-WithRetry -Description "Offsite copy to '$OffsiteDestination'" -Action {
                    Copy-FileVerified -Source $remoteZip -DestinationDir $OffsiteDestination | Out-Null
                    Remove-OldFiles -Directory $OffsiteDestination -Filter "vm-media-backup_*.zip" -Keep $RetentionCount
                }
                Write-Log "Copied backup to offsite destination: $OffsiteDestination"
            }
            catch {
                Add-ComponentError -Component "Offsite" -Message "$_"
            }
        }
    }

    if ($manifest.errors.Count -gt 0) {
        $exitCode = 1
        Write-Log -Level WARN "Backup completed with $($manifest.errors.Count) failure(s). See log '$logFile' and manifest.json in the zip."
    }
    else {
        $lastSuccess = [ordered]@{
            backupTimestamp = $timestamp
            completedAt     = (Get-Date).ToString("o")
            computerName    = $env:COMPUTERNAME
            zip             = Split-Path -Leaf $remoteZip
        }
        $lastSuccess | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $BackupRoot "last-success.json") -Encoding UTF8
        Write-Log "Backup complete: $remoteZip"
    }
}
catch {
    # Fatal, non-component-scoped failure (e.g. staging folder can't be
    # created, or the zip couldn't be built after a retry).
    $exitCode = 1
    Write-Log -Level ERROR "Backup failed: $_"
    if (Test-Path -LiteralPath $runFolder) {
        Remove-Item -LiteralPath $runFolder -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not $uploaded -and (Test-Path -LiteralPath $zipPath)) {
        try {
            Test-ZipIntegrity -ZipPath $zipPath | Out-Null
        }
        catch {
            Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        }
    }
}
finally {
    Write-Log "Exit code: $exitCode"
    Stop-Transcript | Out-Null

    # Logs: keep locally, and copy next to the backups (best-effort).
    try {
        Remove-OldFiles -Directory $LogRoot -Filter "vm-media-backup_*.log" -Keep $LogRetentionCount
    }
    catch {
        Write-Warning "Local log retention failed: $_"
    }
    try {
        $remoteLogDir = Join-Path $BackupRoot "logs"
        Invoke-WithRetry -Description "Log upload" -Action {
            Copy-FileVerified -Source $logFile -DestinationDir $remoteLogDir | Out-Null
        }
        Remove-OldFiles -Directory $remoteLogDir -Filter "vm-media-backup_*.log" -Keep $LogRetentionCount
    }
    catch {
        Write-Warning "Could not copy log to '$BackupRoot\logs': $_. Local log: $logFile"
    }
}

exit $exitCode
