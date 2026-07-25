# Shared constants for install/uninstall. Dot-source: . "$PSScriptRoot\common.ps1"
$SyncTaskName       = 'ClaudeChatSync'
$SyncTaskPath       = '\ClaudeChatSync\'
$SyncInstallDir     = Join-Path $env:LOCALAPPDATA 'ClaudeChatSync'
$SyncScriptInstalled = Join-Path $SyncInstallDir 'sync-claude-sessions.ps1'
$SyncLauncher       = Join-Path $SyncInstallDir 'sync-hidden.vbs'
$SyncLogFile        = Join-Path $SyncInstallDir 'sync-log.txt'
$SyncManifestFile   = Join-Path $SyncInstallDir 'sync-fullset.txt'

# Strings that identify a scheduled task as ours (current or legacy versions).
# Used before any unregister so install/uninstall can never clobber a foreign task.
$SyncTaskMarkers = @('sync-claude-sessions.ps1', 'sync-hidden.vbs', 'sync-chats.ps1')

function Test-SyncTaskIsOurs($task) {
    $actionText = ($task.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' '
    foreach ($m in $SyncTaskMarkers) { if ($actionText -like "*$m*") { return $true } }
    return $false
}
