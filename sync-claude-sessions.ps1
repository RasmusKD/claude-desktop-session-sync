# Bidirectional chat-list sync across all Claude desktop accounts on this machine.
# See README.md for the full design rationale.
#
#  - auto-detects both data roots (%APPDATA%\Claude today, %LOCALAPPDATA%\Claude-3p
#    after a future app migration), so a path move doesn't silently kill the sync
#  - content-aware winner: a copy that lost its cliSessionId or carries
#    transcriptUnavailable=true (app startup-scanner mutation) never beats a
#    healthy copy, regardless of timestamps
#  - per-file error tolerance: one locked/torn file skips that file, not the run
#  - copy-only, never deletes; Copy-Item preserves LastWriteTime, which
#    newest-wins depends on
param([switch]$Quiet)
$ErrorActionPreference = 'Continue'

$roots = @(
    (Join-Path $env:APPDATA 'Claude\claude-code-sessions'),
    (Join-Path $env:LOCALAPPDATA 'Claude-3p\claude-code-sessions')
) | Where-Object { Test-Path $_ }

$logF = Join-Path $PSScriptRoot 'sync-log.txt'
function Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg"
    Add-Content -Path $logF -Value $line -ErrorAction SilentlyContinue
    if (-not $Quiet) { Write-Host $line }
}

# Discover workspace folders (device-id/workspace-id) that contain chats, across all roots.
$workspaces = foreach ($root in $roots) {
    Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        Get-ChildItem -Path $_.FullName -Directory -ErrorAction SilentlyContinue
    } | Where-Object {
        (Get-ChildItem -Path $_.FullName -Filter 'local_*.json' -File -ErrorAction SilentlyContinue).Count -gt 0
    }
}
if (@($workspaces).Count -lt 2) { exit 0 }   # only one account has chats: nothing to share yet

# A copy is "healthy" if it parses and still carries its transcript link.
function Test-Healthy($file) {
    try {
        $j = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($j.transcriptUnavailable -eq $true) { return $false }
        return -not [string]::IsNullOrEmpty($j.cliSessionId)
    } catch { return $false }   # torn/locked/mid-write reads lose winner eligibility
}

# Pick a winner per chat filename: newest HEALTHY copy; only if none is healthy, newest overall.
$byName = @{}
foreach ($ws in $workspaces) {
    foreach ($f in Get-ChildItem -Path $ws.FullName -Filter 'local_*.json' -File -ErrorAction SilentlyContinue) {
        if (-not $byName.ContainsKey($f.Name)) { $byName[$f.Name] = [System.Collections.ArrayList]@() }
        [void]$byName[$f.Name].Add($f)
    }
}
$copies = 0; $skipped = 0
foreach ($name in $byName.Keys) {
    $all = $byName[$name] | Sort-Object LastWriteTimeUtc -Descending
    $healthy = @($all | Where-Object { Test-Healthy $_ })
    $winner = if ($healthy.Count -gt 0) { $healthy[0] } else { $all[0] }

    foreach ($ws in $workspaces) {
        $dst = Join-Path $ws.FullName $name
        if ($winner.DirectoryName -eq $ws.FullName) { continue }
        $dstItem = Get-Item -LiteralPath $dst -ErrorAction SilentlyContinue
        # 2s tolerance avoids timestamp-granularity ping-pong.
        if (-not $dstItem -or ($winner.LastWriteTimeUtc - $dstItem.LastWriteTimeUtc).TotalSeconds -gt 2) {
            # Guard: never replace a healthy copy with an unhealthy winner.
            if ($dstItem -and (Test-Healthy $dstItem) -and -not (Test-Healthy $winner)) { $skipped++; continue }
            try { Copy-Item -LiteralPath $winner.FullName -Destination $dst -Force -ErrorAction Stop; $copies++ }
            catch { $skipped++ }   # locked file: skip this file this round, next run retries
        }
    }
}

if ($copies -gt 0 -or $skipped -gt 0) {
    Log "synced $copies file(s), skipped $skipped, across $(@($workspaces).Count) workspace(s) in $(@($roots).Count) root(s)"
    $tail = Get-Content $logF -Tail 200 -ErrorAction SilentlyContinue
    if ($tail) { Set-Content -Path $logF -Value $tail }
}
