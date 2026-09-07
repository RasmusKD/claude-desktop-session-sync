# Removes the ClaudeChatSync scheduled task and the installed payload.
# Chat files are never touched. What stays behind is enumerated honestly, because
# it includes copies of a config file that can hold MCP API keys; -Purge deletes
# everything including those.
param([switch]$Purge)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"

$shadow = Get-ShadowDir $SyncInstallDir
if ($shadow) {
    throw "This terminal was launched from inside the Claude desktop app and sees an MSIX shadow of $SyncInstallDir (at $shadow); an uninstall from here would only touch that shadow. Open a normal terminal and run uninstall.ps1 there."
}

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

foreach ($f in @($SyncLauncher, $SyncScriptInstalled, $SyncCommonInstalled)) {
    if (Test-Path $f) { Remove-Item $f -Force; Write-Host "Removed $f" }
}
if (Test-Path $SyncGroupHelperDir) { Remove-Item $SyncGroupHelperDir -Recurse -Force; Write-Host "Removed $SyncGroupHelperDir" }
foreach ($stale in Get-StaleInstallShadows) {
    Remove-Item -LiteralPath $stale -Recurse -Force
    Write-Host "Removed a stale in-app shadow of the install dir: $stale"
}

# The manifest and the group base are derived state and dangerous when stale;
# the frozen list is a USER decision and deliberately survives (a reinstall must
# not reseed a workspace the user emptied on purpose).
if (Test-Path $SyncManifestFile) { Remove-Item $SyncManifestFile -Force; Write-Host 'Removed the sync manifest (derived state; rebuilt on reinstall).' }
$groupsBase = Join-Path $SyncInstallDir 'groups-base.json'
if (Test-Path $groupsBase) { Remove-Item $groupsBase -Force; Write-Host 'Removed the group-sync base (derived state; the first run after a reinstall merges without deletions).' }

if ($Purge) {
    Remove-Item $SyncInstallDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Purged $SyncInstallDir (backups, config copies, Local Storage snapshots, deleted-chat stash, log, freeze list)."
} else {
    $zips   = @(Get-ChildItem $SyncInstallDir -Filter 'backup-*.zip' -ErrorAction SilentlyContinue).Count
    $cfgs   = @(Get-ChildItem $SyncInstallDir -Filter 'config-*.json' -ErrorAction SilentlyContinue).Count
    $ldbs   = @(Get-ChildItem $SyncInstallDir -Filter 'leveldb-backup-*' -Directory -ErrorAction SilentlyContinue).Count
    $stash  = @(Get-ChildItem (Join-Path $SyncInstallDir 'deleted') -File -ErrorAction SilentlyContinue).Count
    Write-Host "Kept in ${SyncInstallDir}:"
    Write-Host "  - $zips session backup zip(s)"
    Write-Host "  - $cfgs claude_desktop_config.json cop(ies) - these can contain MCP API keys"
    Write-Host "  - $ldbs Local Storage snapshot(s) taken before group writes - these hold the app's per-account browser storage"
    Write-Host "  - $stash stashed deleted chat(s)"
    Write-Host "  - sync-log.txt and frozen.txt (the freeze list survives reinstalls by design)"
    Write-Host "Run 'uninstall.ps1 -Purge' to delete all of it."
}
Write-Host 'Done. Chat files were not touched. Each account keeps its current list; future changes no longer propagate.'
