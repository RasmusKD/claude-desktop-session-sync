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
# Where the desktop app keeps everything it owns: claude-code-sessions,
# claude_desktop_config.json and the Electron profile's Local Storage.
#
# It is not always %APPDATA%\Claude. The MSIX build turns on write
# virtualization and does not exempt Roaming, so on a machine where the app
# never had a real %APPDATA%\Claude to write into, all of it lands under the
# package's own mirror of Roaming instead and the real path never appears. A
# machine that ran the unpackaged build first keeps the real path and the
# mirror stays absent, and a machine that did both has both.
#
# So the roots are discovered, never assumed: every candidate that exists is
# returned, LEAST recently written first. That order is the engine's convention,
# not a presentation choice: it resolves a tie toward the last root, which is
# the one a half-migrated machine is migrating INTO, and syncing into the root
# the app is abandoning repopulates it forever.
function Get-ClaudeDataRoots([string]$PackagesRoot = (Join-Path $env:LOCALAPPDATA 'Packages')) {
    $candidates = @(Join-Path $env:APPDATA 'Claude')
    $candidates += @(
        Get-ChildItem -Path $PackagesRoot -Directory -Filter 'Claude_*' -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'LocalCache\Roaming\Claude' }
    )
    @($candidates | Where-Object { Test-Path -LiteralPath $_ } |
        Sort-Object { (Get-Item -LiteralPath $_).LastWriteTimeUtc })
}

# One path under the app's data root, e.g. 'claude_desktop_config.json'. The app
# reads and writes exactly one of them, and a write into the stale copy is
# silently discarded, so this takes the FRESHEST root that actually holds the
# file: last in the list, hence the reverse walk. With no hit anywhere it
# returns the real %APPDATA% path, so a caller creating the file creates it
# where an unpackaged app would look for it.
function Resolve-ClaudeDataPath([string]$RelativePath, [string]$PackagesRoot = (Join-Path $env:LOCALAPPDATA 'Packages')) {
    $roots = @(Get-ClaudeDataRoots $PackagesRoot)
    for ($i = $roots.Count - 1; $i -ge 0; $i--) {
        $candidate = Join-Path $roots[$i] $RelativePath
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    Join-Path (Join-Path $env:APPDATA 'Claude') $RelativePath
}

# The third-party/enterprise build keeps its sessions outside the Roaming tree,
# so it is a root in its own right rather than a path under one.
function Get-ClaudeSessionRoots([string]$PackagesRoot = (Join-Path $env:LOCALAPPDATA 'Packages')) {
    @(
        @(Get-ClaudeDataRoots $PackagesRoot | ForEach-Object { Join-Path $_ 'claude-code-sessions' }) +
        @(Join-Path $env:LOCALAPPDATA 'Claude-3p\claude-code-sessions')
    ) | Where-Object { Test-Path -LiteralPath $_ }
}

# The desktop app's Electron profile: sidebar groups live in its Local Storage.
$ClaudeLocalStorageDir = Resolve-ClaudeDataPath 'Local Storage\leveldb'

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
