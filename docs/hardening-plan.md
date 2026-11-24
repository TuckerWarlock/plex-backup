# Backup Hardening Plan

Findings from a code review of `server/backup-plex-server.ps1` and
`vm/backup-vm-and-media-stack.ps1`, ranked by severity. Work through in order —
each item below should become its own change/commit.

## Critical — breaks things even on the happy path

- [x] **1. Plex likely never restarts, even on success.**
  `server/backup-plex-server.ps1:24-32` checks `Get-Service -Name "Plex Media Server"`
  first and only falls back to `Stop-Process` if that's null. Plex on Windows does
  **not** install as a service by default — it runs as a per-user process. So the
  common case takes the `Stop-Process` branch, and the restart logic at line 56-58
  (`if ($plexService) { Start-Service ... }`) is skipped entirely because
  `$plexService` is `$null`. Every run kills Plex and never brings it back.
  **Fix:** add a fallback that locates the Plex install path (registry or
  `${env:ProgramFiles}\Plex\Plex Media Server\Plex Media Server.exe`) and
  `Start-Process`es it when no service was found.
  **Done:** `Get-PlexExecutablePath` added; the stop/restart path now tracks
  whether Plex was stopped via service or process and restarts it the same
  way, falling back to a `Write-Warning` if neither works. See `server/README.md`
  "Stop/restart behavior".

- [x] **2. No `try/finally` anywhere — a mid-run failure leaves things broken.**
  - `server/backup-plex-server.ps1`: if robocopy (line 44-46) or `reg export`
    (line 51-53) fails *after* Plex was stopped, the script `throw`s immediately.
    Plex stays down indefinitely with no restart attempt.
  - `vm/backup-vm-and-media-stack.ps1`: `Copy-DirectoryIfExists` throws on any
    robocopy failure ≥8 (line 47-49), and there's no isolation between
    components — one flaky component (locked file, Hyper-V hiccup) aborts the
    entire run, including work that already succeeded (e.g. Documents). No zip,
    no manifest, staging folder left behind as debris.
  **Fix:** wrap stop → backup → restart/cleanup in `try/finally` in both
  scripts so restart-service and cleanup always run regardless of failure.
  **Done:** `server/backup-plex-server.ps1` now restarts Plex in a `finally`
  block around the copy/registry-export step, then a top-level `try/catch`
  cleans up staging debris and rethrows on any failure. `vm/backup-vm-and-media-stack.ps1`
  now wraps each component (Documents, each Hyper-V VM, each arr app, qBittorrent)
  in its own `try/catch`, recording failures into a new `manifest.errors` array
  and continuing to the next component instead of aborting the whole run; a
  manifest and zip are always produced as long as staging itself succeeded.

## High — data can be quietly corrupted or missing

- [x] **3. Mutable app data copied live in the VM script, unlike the Plex script.**
  qBittorrent (`vm/backup-vm-and-media-stack.ps1:174-189`), Bazarr, and Jackett
  (`:140-150`, `DirectoryCopy` mode) are copied while running, with no attempt to
  stop them first — inconsistent with the Plex script's own "stop before copy"
  pattern and the convention documented in `.github/copilot-instructions.md`.
  Resume/session data or the Bazarr SQLite DB can be mid-write during copy.
  **Fix:** stop the relevant process/service before copying qBittorrent, Bazarr,
  and Jackett data; restart after, inside the `try/finally` from item 2.
  **Done:** added `Stop-AppIfRunning`/`Start-AppIfWasRunning` helpers (same
  service-or-process pattern as the Plex fix) and applied them to Bazarr,
  Jackett, and qBittorrent. Sonarr/Radarr/Prowlarr are intentionally left
  running since only their own already-exported backup zips are copied, not
  live data. Service/process name guesses for Bazarr/Jackett are documented
  as best-effort in `vm/README.md` — if wrong, the script degrades to the old
  copy-while-running behavior rather than failing.
  **Later changes:**
  - Bazarr was switched to copying its own built-in backup zips, so it is no longer stopped.
  - qBittorrent is no longer stopped with `Stop-Process -Force`, because a hard kill is exactly how its resume data (`BT_backup`) gets lost. It is now shut down gracefully through its WebUI API and the script waits for the process to exit. If it doesn't exit, it's left running and its copy is skipped. See item 13.

- [x] **4. No integrity verification after zipping.**
  Both scripts `Compress-Archive` and trust the result unconditionally
  (`server:69-75`, `vm:194-200`). A truncated/corrupt archive silently becomes
  "the backup" and can rotate out good ones via retention.
  **Fix:** verify the archive opens and has a sane entry count/size before
  declaring success (e.g. `[System.IO.Compression.ZipFile]::OpenRead`).
  **Done:** added `Test-ZipIntegrity` to both scripts (opens the archive via
  `System.IO.Compression.ZipFile` and confirms it has at least one entry) run
  right after `Compress-Archive` and before the staging folder is deleted. If
  it fails, the outer `catch` now removes both the staging folder and the bad
  zip, then rethrows, so a corrupt archive is never left for retention to
  count as a "good" backup.

## Medium — footguns and silent misconfiguration

- [x] **5. `-RetentionCount 0` (or a bad input) deletes the backup just made.**
  Both retention blocks (`server:78-81`, `vm:203-206`) do
  `Sort-Object -Descending | Select-Object -Skip $RetentionCount | Remove-Item`.
  With `RetentionCount = 0`, every file passes through and gets removed,
  including the one just created. No validation on the parameter.
  **Fix:** add `[ValidateRange(1, [int]::MaxValue)]` and/or always keep at
  least the newest backup regardless of the configured count.
  **Done:** `[ValidateRange(1, [int]::MaxValue)]` added to `$RetentionCount`
  in both scripts — PowerShell now rejects `0`/negative values outright, and
  since the pipeline always ranks the just-created zip first, `-Skip N` with
  `N >= 1` can never delete it. Documented in both READMEs.

- [ ] **6. Registry/user-context mismatch if the scheduled task runs as a
  different account than the Plex user.**
  `server/backup-plex-server.ps1` relies on `%LOCALAPPDATA%` and `HKCU`
  (lines 16, 50) resolving to the account that actually runs Plex. Fine today
  since the README's `schtasks` example doesn't pin `/RU`, but a landmine if
  anyone later switches the task to run as `SYSTEM` or another account —
  it would silently back up an empty/wrong profile instead of erroring.
  **Fix:** document this constraint prominently in `server/README.md`, and
  consider an explicit sanity check (e.g. verify `$plexData` exists and
  contains expected subfolders before proceeding).

- [x] **7. Silently-empty backups aren't distinguished from healthy ones.**
  Missing arr-app paths just log a warning and record `copiedFiles = 0` in the
  manifest (`vm:62-65`, `152-172`). A months-long silent misconfiguration looks
  identical to a healthy run in the manifest.
  **Fix:** surface zero-count "expected" components as a loud warning
  (distinct from genuinely-optional/missing ones) so it's actionable in logs.
  **Done (VM script):** an arr app with zero backup zips is now recorded as an
  error, which affects the exit code and `last-success.json`. Lidarr, which
  isn't on this VM, was removed rather than left as a permanent warning.

- [ ] **8. No monitoring/alerting on failure.**
  Both scripts run unattended via Task Scheduler with no notification hook and
  no "last successful backup" marker. Combined with item 2, a broken backup
  chain can go unnoticed indefinitely.
  **Fix:** write a `last-success.json`/timestamp file on completion that's easy
  to check externally; consider an optional notification hook (email/webhook)
  on failure.
  **Partly done (VM script only):**
  - Every run writes a transcript log, locally and to `<BackupRoot>\logs`.
  - The script exits 1 on any failure, so Task Scheduler's Last Run Result shows it.
  - `last-success.json` is written to `<BackupRoot>` only on a fully clean run.

  Still open: a push notification hook, and the same treatment for
  `server/backup-plex-server.ps1`, which hasn't been tested on the live Plex server.

- [ ] **9. Documents folder may be OneDrive-redirected.**
  `vm/backup-vm-and-media-stack.ps1:98-100` backs up
  `[Environment]::GetFolderPath("MyDocuments")` via robocopy with no handling
  for OneDrive Files-On-Demand placeholder/reparse-point files — the Windows 11
  default — which can force-download everything or copy stub files depending
  on flags.
  **Fix:** detect/document this case; decide whether to force-hydrate or skip
  cloud-only placeholders explicitly.

## Lower-severity / polish

- [ ] **10.** Retention sorts by `LastWriteTime`, not the timestamp embedded in
  the filename — timestamps can shift if backups are copied offsite and back,
  causing retention to delete the wrong files. Parse the filename timestamp
  instead.
- [ ] **11.** No disk-space preflight check before large copies (VM export,
  Documents) — failures mid-copy aren't distinguished from "nothing to do."
- [ ] **12.** No lock/mutex — overlapping manual + scheduled runs aren't
  guarded against (`Export-VM` in particular fails outright on a concurrent
  export of the same VM, which then hits item 2).

## From the first live test on the indexer/downloader/monitor VM (2026-11-23)

- [x] **13. qBittorrent was force-killed.** `Stop-Process -Force` risks the
  resume data the backup exists to protect.
  **Done:** the script now shuts qBittorrent down through the WebUI API
  (`/api/v2/app/shutdown`), using the existing DPAPI password file, and waits
  for the process to exit (`-QbtShutdownTimeoutSeconds`). It never kills it.
  It relaunches qBittorrent through `explorer.exe`, so it comes back unelevated
  in the user's desktop session.
- [x] **14. The default `D:\ServerBackups` didn't exist on the VM.** On this VM, D:
  is the read-only Windows install media.
  **Done:** `-BackupRoot` now defaults to
  `\\TUCKER-DESKTOP\Shared R Drive\VM Backups`. Staging and zipping happen
  locally (`-StagingRoot`), and only the verified zip is uploaded. A failed
  upload keeps the zip locally.
- [x] **15. A transient failure lost a component for that run.**
  **Done:** `Invoke-WithRetry` gives every fallible step exactly one retry
  (`-RetryDelaySeconds`) before it's logged as a failure.
- [x] **16. Hidden files were silently skipped.** Windows PowerShell 5.1's
  `Compress-Archive` drops hidden files, such as `.git` folders under Documents.
  **Done:** the VM script uses `System.IO.Compression.ZipFile` instead.

## Suggested order of work

1. ~~Item 2 (try/finally + always-restart)~~ — done.
2. ~~Item 1 (Plex process-not-service restart fallback)~~ — done, folded into item 2's edit.
3. ~~Item 3 (stop qBittorrent/Bazarr/Jackett before copy)~~ — done, folded into item 2's edit.
4. ~~Item 5 (retention floor/validation)~~ — done.
5. ~~Item 4 (zip integrity check)~~ — done.
6. ~~Items 7, 13-16 (VM script)~~ — done; item 8 partly done for the VM script.
7. **Next:**
   - Bring the retry, logging and exit-code changes to `server/backup-plex-server.ps1`. This is held until it can be tested on the Plex server.
   - Add a push notification hook for item 8.
   - Then items 6 and 9-12 as time allows.

Note: `pwsh` is available in this environment (via `dotnet tool install --global
PowerShell`, on the PATH through `~/.dotnet/tools`) and was used to parse-check
both scripts with `[System.Management.Automation.Language.Parser]::ParseFile`
— both come back with zero syntax errors. Full execution isn't possible here
though: the scripts assume Windows paths (`D:\...`, `%LOCALAPPDATA%`) and
Windows-only tooling (`robocopy`, `reg export`, `Get-Service`, Hyper-V
cmdlets), none of which exist on macOS. Logic has been reviewed by hand;
still worth a real dry run on Windows before relying on these for backups.
