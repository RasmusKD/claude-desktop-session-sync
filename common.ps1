# Shared constants and helpers for the engine, install and uninstall.
# Dot-source: . "$PSScriptRoot\common.ps1"
$SyncTaskName       = 'ClaudeChatSync'
$SyncTaskPath       = '\ClaudeChatSync\'
$SyncInstallDir     = Join-Path $env:LOCALAPPDATA 'ClaudeChatSync'
$SyncScriptInstalled = Join-Path $SyncInstallDir 'sync-claude-sessions.ps1'
$SyncCommonInstalled = Join-Path $SyncInstallDir 'common.ps1'
$SyncLauncher       = Join-Path $SyncInstallDir 'sync-hidden.vbs'
$SyncLogFile        = Join-Path $SyncInstallDir 'sync-log.txt'
$SyncManifestFile   = Join-Path $SyncInstallDir 'sync-fullset.txt'
$SyncGroupHelperDir = Join-Path $SyncInstallDir 'group-sync'
# The desktop app's Electron profile: sidebar groups live in its Local Storage.
$ClaudeLocalStorageDir = Join-Path $env:APPDATA 'Claude\Local Storage\leveldb'

# Strings that identify a scheduled task as ours (current or legacy versions).
# Used before any unregister so install/uninstall can never clobber a foreign task.
$SyncTaskMarkers = @('sync-claude-sessions.ps1', 'sync-hidden.vbs', 'sync-chats.ps1')

function Test-SyncTaskIsOurs($task) {
    $actionText = ($task.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' '
    foreach ($m in $SyncTaskMarkers) { if ($actionText -like "*$m*") { return $true } }
    return $false
}

# A process started from inside an MSIX-packaged app (a Claude Code session
# launched by the Claude desktop app, for instance) can have its %LOCALAPPDATA%
# writes redirected into that package's LocalCache and read a merged view in
# which those redirected files shadow the real ones. Nothing in the process
# identity APIs reports it, so the check is a probe: a file created in $Dir that
# shows up under a package's LocalCache mirror of $Dir means this process sees a
# shadow. Returns the shadow directory, or $null when the view is the real one.
function Get-ShadowDir([string]$Dir, [string]$PackagesRoot = (Join-Path $env:LOCALAPPDATA 'Packages')) {
    $leaf = Split-Path $Dir -Leaf
    $probe = '.virt-probe-' + $PID + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $probePath = Join-Path $Dir $probe
    try { [System.IO.File]::WriteAllText($probePath, '') } catch { return $null }
    try {
        foreach ($pkg in @(Get-ChildItem -Path $PackagesRoot -Directory -ErrorAction SilentlyContinue)) {
            $mirror = Join-Path $pkg.FullName "LocalCache\Local\$leaf"
            if (Test-Path -LiteralPath (Join-Path $mirror $probe)) { return $mirror }
        }
        return $null
    } finally {
        Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue
    }
}

# The stale shadow of the install dir left behind by an install that ran inside
# the app. Only meaningful from a process whose view is real (Get-ShadowDir
# returned $null): from a shadowed process the mirror IS the current view.
function Get-StaleInstallShadows([string]$PackagesRoot = (Join-Path $env:LOCALAPPDATA 'Packages')) {
    $leaf = Split-Path $SyncInstallDir -Leaf
    @(Get-ChildItem -Path $PackagesRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $m = Join-Path $_.FullName "LocalCache\Local\$leaf"
        if (Test-Path -LiteralPath $m) { $m }
    })
}

# The desktop app itself (not the Claude Code CLI, which shares the process
# name and lives under claude-code\). A process whose path cannot be read is
# treated as the app: an unreadable path must never unlock a Local Storage write.
function Test-ClaudeAppRunning {
    foreach ($p in @(Get-Process -Name 'Claude' -ErrorAction SilentlyContinue)) {
        $path = $null
        try { $path = $p.Path } catch { }
        if (-not $path) { return $true }
        if ($path -notmatch '\\claude-code\\') { return $true }
    }
    return $false
}

# node on PATH plus the helper's installed dependency; without both, group sync
# is off and everything else runs.
function Get-GroupHelperState([string]$HelperDir) {
    $script = Join-Path $HelperDir 'group-sync.mjs'
    if (-not (Test-Path -LiteralPath $script)) { return @{ ok = $false; reason = "helper missing ($script)" } }
    if (-not (Test-Path -LiteralPath (Join-Path $HelperDir 'node_modules\classic-level\package.json'))) { return @{ ok = $false; reason = 'helper dependency not installed (run install.ps1 with Node.js on PATH)' } }
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) { return @{ ok = $false; reason = 'node not on PATH' } }
    return @{ ok = $true; script = $script; node = $node.Source }
}
