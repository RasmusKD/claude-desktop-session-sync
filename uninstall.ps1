# Removes the ClaudeChatSync scheduled task and the installed payload.
# Chat files are never touched. Backups and the log are deliberately kept.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"

$removed = $false
foreach ($path in @('\', $SyncTaskPath)) {
    $task = Get-ScheduledTask -TaskName $SyncTaskName -TaskPath $path -ErrorAction SilentlyContinue
    if (-not $task) { continue }
    if (Test-SyncTaskIsOurs $task) {
        Stop-ScheduledTask -TaskName $SyncTaskName -TaskPath $path -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $SyncTaskName -TaskPath $path -Confirm:$false
        Write-Host "Scheduled task '$path$SyncTaskName' removed." -ForegroundColor Green
        $removed = $true
    } else {
        Write-Host "Task '$path$SyncTaskName' exists but was not created by this tool - leaving it alone." -ForegroundColor Yellow
    }
}
if (-not $removed) { Write-Host "No '$SyncTaskName' task of ours found." }

foreach ($f in @($SyncLauncher, $SyncScriptInstalled)) {
    if (Test-Path $f) { Remove-Item $f -Force; Write-Host "Removed $f" }
}

$leftovers = Get-ChildItem -Path $SyncInstallDir -ErrorAction SilentlyContinue
if ($leftovers) {
    Write-Host "Kept (backups + log): $SyncInstallDir - delete it yourself if you don't want them."
} else {
    Remove-Item $SyncInstallDir -Force -ErrorAction SilentlyContinue
}
Write-Host 'Done. Chat files were not touched. Each account keeps its current list; future changes no longer propagate.'
