# Installs the ClaudeChatSync scheduled task (per-user, no admin required).
# Order matters: the backup gate runs BEFORE the new engine is copied into place,
# so a failed backup really does mean nothing changed. Backups are staged per
# root (the roots share a leaf name and would collide inside one zip), the very
# first snapshot is preserved outside the rotation, and a version-read failure
# aborts instead of silently disabling upgrade backups.
param([switch]$Force)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"

$srcScript = Join-Path $PSScriptRoot 'sync-claude-sessions.ps1'
if (-not (Test-Path $srcScript)) { throw 'sync-claude-sessions.ps1 not found next to install.ps1' }

function Get-ToolVersion($path) {
    $m = Select-String -Path $path -Pattern "^\`$ToolVersion\s*=\s*'([^']+)'" | Select-Object -First 1
    if ($m) { $m.Matches[0].Groups[1].Value } else { '' }
}

New-Item -ItemType Directory -Force -Path $SyncInstallDir | Out-Null
$installedVer = if (Test-Path $SyncScriptInstalled) { Get-ToolVersion $SyncScriptInstalled } else { '' }
$srcVer = Get-ToolVersion $srcScript
if (-not $srcVer) { throw 'Could not read $ToolVersion from the source script; refusing to install.' }

# ── Backup gate: first install AND every version change, BEFORE anything changes
$existingBackup = Get-ChildItem -Path $SyncInstallDir -Filter 'backup-*.zip' -ErrorAction SilentlyContinue
$backupRoots = @(
    (Join-Path $env:APPDATA 'Claude\claude-code-sessions'),
    (Join-Path $env:LOCALAPPDATA 'Claude-3p\claude-code-sessions')
) | Where-Object { Test-Path $_ }
$needBackup = (-not $existingBackup) -or ($installedVer -ne $srcVer)
if ($needBackup -and @($backupRoots).Count -gt 0) {
    $zip = Join-Path $SyncInstallDir "backup-$(Get-Date -Format 'yyyyMMdd-HHmmss').zip"
    $stage = Join-Path $env:TEMP "ccs-backup-$(Get-Date -Format 'yyyyMMddHHmmss')"
    try {
        # Stage per root: both roots end in 'claude-code-sessions', so zipping them
        # directly would collide; staging also survives one locked file.
        $i = 0
        foreach ($r in $backupRoots) {
            $i++
            $dest = Join-Path $stage "root$i-$(Split-Path (Split-Path $r -Parent) -Leaf)"
            New-Item -ItemType Directory -Force -Path $dest | Out-Null
            Copy-Item -Path (Join-Path $r '*') -Destination $dest -Recurse -Force -ErrorAction Continue
        }
        Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -ErrorAction Stop
        Write-Host "Pre-sync backup written: $zip" -ForegroundColor Green
        # The pristine first snapshot never rotates away.
        $original = Join-Path $SyncInstallDir 'backup-original.zip'
        if (-not (Test-Path $original)) { Copy-Item $zip $original -Force }
        Get-ChildItem -Path $SyncInstallDir -Filter 'backup-*.zip' -File |
            Where-Object { $_.Name -ne 'backup-original.zip' } |
            Sort-Object Name -Descending | Select-Object -Skip 3 |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {
        if (-not $Force) { throw "Backup failed ($($_.Exception.Message)). Nothing was installed or replaced; the previous version (if any) is still running. Re-run with -Force to override." }
        Write-Host "Backup failed ($($_.Exception.Message)) - continuing because -Force was given." -ForegroundColor Yellow
    } finally {
        Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ── Payload goes live only after the backup gate ─────────────────────────────
Copy-Item $srcScript -Destination $SyncScriptInstalled -Force

# ── Launcher: path arrives as a task argument (task XML is UTF-16), so any
#    username - including non-ASCII ones - survives. wait=False because
#    wait=True deadlocks under Task Scheduler (verified empirically); the lock
#    file in the sync script is what prevents overlapping runs from piling up.
@'
' Runs the Claude session sync with no visible window (used by the ClaudeChatSync scheduled task).
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -File """ & WScript.Arguments(0) & """ -Quiet", 0, False
'@ | Set-Content -Path $SyncLauncher -Encoding ASCII

$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$SyncLauncher`" `"$SyncScriptInstalled`""

# Trigger 1: every 5 minutes. "s" = culture-invariant sortable format; a custom
# format string would render Hijri/Buddhist years on some locales and produce an
# EndBoundary in the past. EndBoundary is required for StartWhenAvailable to
# apply to a once-with-repetition trigger.
$t1 = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)
$t1.EndBoundary = (Get-Date).AddYears(30).ToString('s')

# Trigger 2: at logon, carrying the same repetition - the reboot safety net.
$t2 = New-ScheduledTaskTrigger -AtLogOn -User ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
$t2.Repetition = $t1.Repetition

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

# ── Replace our own task (any version); never clobber a foreign one ─────────
foreach ($path in @('\', $SyncTaskPath)) {
    $existing = Get-ScheduledTask -TaskName $SyncTaskName -TaskPath $path -ErrorAction SilentlyContinue
    if ($existing) {
        if (Test-SyncTaskIsOurs $existing) {
            Stop-ScheduledTask -TaskName $SyncTaskName -TaskPath $path -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $SyncTaskName -TaskPath $path -Confirm:$false
        } else {
            throw "A scheduled task named '$SyncTaskName' (path '$path') already exists and was NOT created by this tool. Refusing to replace it."
        }
    }
}
Register-ScheduledTask -TaskName $SyncTaskName -TaskPath $SyncTaskPath -Action $action -Trigger $t1, $t2 -Settings $settings | Out-Null
Write-Host "Scheduled task '$SyncTaskPath$SyncTaskName' registered (every 5 min + at logon, battery-safe)." -ForegroundColor Green

# ── Verify by evidence, not exit codes: the first run must leave a heartbeat ─
Start-ScheduledTask -TaskName $SyncTaskName -TaskPath $SyncTaskPath
Start-Sleep 6
$lastLine = Get-Content $SyncLogFile -Tail 1 -ErrorAction SilentlyContinue
$fresh = $false
if ($lastLine -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})') {
    $fresh = ([datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture) -gt (Get-Date).AddMinutes(-2))
}
if ($fresh) {
    Write-Host 'First sync ran and wrote its heartbeat:' -ForegroundColor Green
    Write-Host "  $lastLine"
    Write-Host 'Restart the Claude desktop app after switching accounts to see the shared list.'
} else {
    Write-Host "No fresh heartbeat found in $SyncLogFile - the first run did not complete." -ForegroundColor Yellow
    Write-Host "Diagnose with: powershell -File `"$SyncScriptInstalled`" -Status"
}
