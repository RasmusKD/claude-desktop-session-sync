# Installs the ClaudeChatSync scheduled task (per-user, no admin required).
# Registers hardened triggers/settings so the task survives battery power and
# reboots (Windows defaults would silently kill it on both), generates the
# hidden launcher, and runs a first sync.
$ErrorActionPreference = 'Stop'

$taskName = 'ClaudeChatSync'
$syncPs1  = Join-Path $PSScriptRoot 'sync-claude-sessions.ps1'
$vbs      = Join-Path $PSScriptRoot 'sync-hidden.vbs'

if (-not (Test-Path $syncPs1)) { throw "sync-claude-sessions.ps1 not found next to install.ps1" }

# Hidden launcher: wscript runs the sync with no console window flash.
@"
' Runs the Claude session sync with no visible window (used by the $taskName scheduled task).
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -File ""$syncPs1"" -Quiet", 0, False
"@ | Set-Content -Path $vbs -Encoding ASCII

$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`""

# Trigger 1: every 5 minutes. EndBoundary is required for StartWhenAvailable to
# apply to a once-with-repetition trigger (see README for the Microsoft KB).
$t1 = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)
$t1.EndBoundary = (Get-Date).AddYears(30).ToString("yyyy-MM-dd'T'HH:mm:ss")

# Trigger 2: at logon, carrying the same repetition - the reboot safety net.
$t2 = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$t2.Repetition = $t1.Repetition

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

# Re-register cleanly if it already exists.
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $t1, $t2 -Settings $settings | Out-Null

Write-Host "Scheduled task '$taskName' registered (every 5 min + at logon, battery-safe)." -ForegroundColor Green

Start-ScheduledTask -TaskName $taskName
Start-Sleep 3
$result = (Get-ScheduledTaskInfo -TaskName $taskName).LastTaskResult
if ($result -eq 0 -or $result -eq 267009) {   # 267009 = still running
    Write-Host "First sync launched successfully." -ForegroundColor Green
    Write-Host "Restart the Claude desktop app after switching accounts to see the shared list."
} else {
    Write-Host "First run returned code $result - check sync-log.txt." -ForegroundColor Yellow
}
