# Removes the ClaudeChatSync scheduled task and the installed payload.
# Chat files are never touched. What stays behind is enumerated honestly, because
# it includes copies of a config file that can hold MCP API keys; -Purge deletes
# everything including those.
param([switch]$Purge)
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

# The manifest is derived state and dangerous when stale; the frozen list is a
# USER decision and deliberately survives (a reinstall must not reseed a
# workspace the user emptied on purpose).
if (Test-Path $SyncManifestFile) { Remove-Item $SyncManifestFile -Force; Write-Host 'Removed the sync manifest (derived state; rebuilt on reinstall).' }

if ($Purge) {
    Remove-Item $SyncInstallDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Purged $SyncInstallDir (backups, config copies, deleted-chat stash, log, freeze list)."
} else {
    $zips   = @(Get-ChildItem $SyncInstallDir -Filter 'backup-*.zip' -ErrorAction SilentlyContinue).Count
    $cfgs   = @(Get-ChildItem $SyncInstallDir -Filter 'config-*.json' -ErrorAction SilentlyContinue).Count
    $stash  = @(Get-ChildItem (Join-Path $SyncInstallDir 'deleted') -File -ErrorAction SilentlyContinue).Count
    Write-Host "Kept in ${SyncInstallDir}:"
    Write-Host "  - $zips session backup zip(s)"
    Write-Host "  - $cfgs claude_desktop_config.json cop(ies) - these can contain MCP API keys"
    Write-Host "  - $stash stashed deleted chat(s)"
    Write-Host "  - sync-log.txt and frozen.txt (the freeze list survives reinstalls by design)"
    Write-Host "Run 'uninstall.ps1 -Purge' to delete all of it."
}
Write-Host 'Done. Chat files were not touched. Each account keeps its current list; future changes no longer propagate.'
