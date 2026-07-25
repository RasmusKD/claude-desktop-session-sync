# Installs the ClaudeChatSync scheduled task (per-user, no admin required).
#  - copies the sync script to %LOCALAPPDATA%\ClaudeChatSync (the repo clone stays
#    a repo; git pull can never silently change what the task executes)
#  - takes a one-time zip backup of the session folders before the first sync
#  - registers hardened triggers/settings (battery-safe, reboot-safe)
#  - refuses to touch a scheduled task it does not recognize as its own
param([switch]$Force)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"

$srcScript = Join-Path $PSScriptRoot 'sync-claude-sessions.ps1'
if (-not (Test-Path $srcScript)) { throw 'sync-claude-sessions.ps1 not found next to install.ps1' }

function Get-ToolVersion($path) {
    $m = Select-String -Path $path -Pattern "^\`$ToolVersion\s*=\s*'([^']+)'" | Select-Object -First 1
    if ($m) { $m.Matches[0].Groups[1].Value } else { '' }
}

# ── Payload to a stable, user-private location ───────────────────────────────
New-Item -ItemType Directory -Force -Path $SyncInstallDir | Out-Null
$installedVer = if (Test-Path $SyncScriptInstalled) { Get-ToolVersion $SyncScriptInstalled } else { '' }
$srcVer = Get-ToolVersion $srcScript
Copy-Item $srcScript -Destination $SyncScriptInstalled -Force

# ── Backup on first install AND on every version change: the users upgrading
#    into new behavior are exactly the ones who need a fresh snapshot. ───────
$existingBackup = Get-ChildItem -Path $SyncInstallDir -Filter 'backup-*.zip' -ErrorAction SilentlyContinue
$backupRoots = @(
    (Join-Path $env:APPDATA 'Claude\claude-code-sessions'),
    (Join-Path $env:LOCALAPPDATA 'Claude-3p\claude-code-sessions')
) | Where-Object { Test-Path $_ }
$needBackup = (-not $existingBackup) -or ($installedVer -ne $srcVer)
if ($needBackup -and @($backupRoots).Count -gt 0) {
    $zip = Join-Path $SyncInstallDir "backup-$(Get-Date -Format 'yyyyMMdd-HHmmss').zip"
    try {
        Compress-Archive -Path $backupRoots -DestinationPath $zip -ErrorAction Stop
        Write-Host "Pre-sync backup written: $zip" -ForegroundColor Green
        Get-ChildItem -Path $SyncInstallDir -Filter 'backup-*.zip' -File |
            Sort-Object Name -Descending | Select-Object -Skip 3 |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {
        if (-not $Force) { throw "Backup failed ($($_.Exception.Message)). Refusing to install a tool that propagates deletions without a snapshot. Re-run with -Force to override." }
        Write-Host "Backup failed ($($_.Exception.Message)) - continuing because -Force was given." -ForegroundColor Yellow
    }
}

# ── Launcher: path arrives as a task argument (task XML is UTF-16), so any
#    username - including non-ASCII ones - survives. wait=False because
#    wait=True deadlocks under Task Scheduler (wscript hangs without spawning
#    the child; verified empirically, works fine interactively). The named
#    mutex in the sync script is what prevents overlapping runs from piling up:
#    a new run exits immediately while an old one still holds the mutex. ─────
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
    $fresh = ([datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', $null) -gt (Get-Date).AddMinutes(-2))
}
if ($fresh) {
    Write-Host 'First sync ran and wrote its heartbeat:' -ForegroundColor Green
    Write-Host "  $lastLine"
    Write-Host 'Restart the Claude desktop app after switching accounts to see the shared list.'
} else {
    Write-Host "No fresh heartbeat found in $SyncLogFile - the first run did not complete." -ForegroundColor Yellow
    Write-Host "Diagnose with: powershell -File `"$SyncScriptInstalled`" -Status"
}
