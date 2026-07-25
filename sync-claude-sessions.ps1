# Bidirectional chat-list sync across Claude desktop accounts on this machine.
# See README.md for the full design rationale.
#
# Design invariants:
#  - one sync target per device-id (account): its single workspace folder. A device
#    with MULTIPLE chat-bearing workspace folders is skipped with a logged warning,
#    because no safe pairing can be inferred (observed layouts have exactly one
#    workspace per account; chats from different project dirs share it).
#  - a fresh account's empty workspace folder IS a target, so a newly added account
#    receives the shared list on the next run, before its first chat.
#  - three-state health (healthy / damaged / unknown): a copy the app has mutated
#    (stripped cliSessionId, transcriptUnavailable=true) never beats a healthy copy;
#    an unreadable copy neither wins nor loses protection.
#  - writes are atomic: copy to a temp sibling, verify size + health, then rename.
#    The app can never observe a half-written session file.
#  - copy-only: existing files are overwritten by newer versions, never deleted.
#  - a named mutex serializes concurrent runs (scheduled + manual).
#  - every run writes a heartbeat log line, so a silently dead sync is visible.
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$Quiet,
    [switch]$Status,
    [string[]]$RootsOverride   # tests point this at a fixture tree
)
$ErrorActionPreference = 'Continue'
$ToolVersion = '0.2.0'

$roots = if ($RootsOverride) { @($RootsOverride | Where-Object { Test-Path $_ }) } else {
    @(
        (Join-Path $env:APPDATA 'Claude\claude-code-sessions'),
        (Join-Path $env:LOCALAPPDATA 'Claude-3p\claude-code-sessions')
    ) | Where-Object { Test-Path $_ }
}

$logF = Join-Path $PSScriptRoot 'sync-log.txt'
function Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg"
    Add-Content -Path $logF -Value $line -ErrorAction SilentlyContinue
    if (-not $Quiet) { Write-Host $line }
}

# ── Discovery: one target workspace per device-id ────────────────────────────
$targets = @()
$skippedDevices = 0
foreach ($root in $roots) {
    foreach ($device in Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue) {
        $wsDirs = @(Get-ChildItem -Path $device.FullName -Directory -ErrorAction SilentlyContinue)
        if ($wsDirs.Count -eq 0) { continue }
        $chatBearing = @($wsDirs | Where-Object {
            (Get-ChildItem -Path $_.FullName -Filter 'local_*.json' -File -ErrorAction SilentlyContinue).Count -gt 0
        })
        if ($chatBearing.Count -gt 1) {
            Log "warning: device $($device.Name) has $($chatBearing.Count) chat-bearing workspaces; skipped (no safe pairing)"
            $skippedDevices++
            continue
        }
        if ($chatBearing.Count -eq 1)  { $targets += $chatBearing[0] }
        elseif ($wsDirs.Count -eq 1)   { $targets += $wsDirs[0] }   # fresh account, no chats yet
        # multiple empty workspaces: ambiguous, skip silently (nothing to lose)
    }
}
$sources = @($targets | Where-Object {
    (Get-ChildItem -Path $_.FullName -Filter 'local_*.json' -File -ErrorAction SilentlyContinue).Count -gt 0
})

if ($Status) {
    Write-Host "claude-desktop-session-sync v$ToolVersion"
    Write-Host "roots found:      $(@($roots).Count)"
    $roots | ForEach-Object { Write-Host "  $_" }
    Write-Host "sync targets:     $(@($targets).Count) workspace(s), $(@($sources).Count) with chats, $skippedDevices device(s) skipped"
    Write-Host "last log lines:"
    Get-Content $logF -Tail 3 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $_" }
    exit 0
}

# ── Serialize runs (scheduled vs manual) ─────────────────────────────────────
$mutex = New-Object System.Threading.Mutex($false, 'Local\ClaudeChatSync')
if (-not $mutex.WaitOne(0)) { exit 0 }
try {

# Sweep temp leftovers from a previously killed run.
foreach ($t in $targets) {
    Get-ChildItem -Path $t.FullName -Filter '*.cs-tmp-*' -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

$copies = 0; $skipped = 0; $contestedCount = 0

if (@($targets).Count -ge 2 -and @($sources).Count -ge 1) {

    # healthy: parses our markers and still carries its transcript link
    # damaged: app-mutated (transcriptUnavailable) or lost cliSessionId
    # unknown: unreadable right now (locked/mid-write) - neither wins nor loses protection
    $healthCache = @{}
    function Get-Health($path) {
        if ($healthCache.ContainsKey($path)) { return $healthCache[$path] }
        $h = 'unknown'
        try {
            $raw = [System.IO.File]::ReadAllText($path)
            if ($raw -match '"transcriptUnavailable"\s*:\s*true') { $h = 'damaged' }
            elseif ($raw -match '"cliSessionId"\s*:\s*"[^"]+"')   { $h = 'healthy' }
            else                                                   { $h = 'damaged' }
        } catch { $h = 'unknown' }
        $healthCache[$path] = $h
        return $h
    }

    # Collect all copies of each chat by filename.
    $byName = @{}
    foreach ($ws in $sources) {
        foreach ($f in Get-ChildItem -Path $ws.FullName -Filter 'local_*.json' -File -ErrorAction SilentlyContinue) {
            if (-not $byName.ContainsKey($f.Name)) { $byName[$f.Name] = @() }
            $byName[$f.Name] += $f
        }
    }

    foreach ($name in $byName.Keys) {
        $all = @($byName[$name] | Sort-Object LastWriteTimeUtc -Descending)

        # Uncontested (present everywhere, timestamps agree): skip without any file reads.
        $spread = ($all[0].LastWriteTimeUtc - $all[-1].LastWriteTimeUtc).TotalSeconds
        if ($all.Count -eq @($targets).Count -and $spread -le 2) { continue }
        $contestedCount++

        # Winner: newest healthy copy; else newest damaged (unknown never wins).
        $winner = $null; $winnerHealth = $null
        foreach ($state in 'healthy', 'damaged') {
            foreach ($c in $all) {
                if ((Get-Health $c.FullName) -eq $state) { $winner = $c; $winnerHealth = $state; break }
            }
            if ($winner) { break }
        }
        if (-not $winner) { $skipped++; continue }   # every copy unreadable right now

        foreach ($ws in $targets) {
            if ($winner.DirectoryName -eq $ws.FullName) { continue }
            $dst = Join-Path $ws.FullName $name
            $dstItem = Get-Item -LiteralPath $dst -ErrorAction SilentlyContinue

            $dstHealth = $null
            if ($dstItem) {
                $dstHealth = 'unknown'
                try {
                    $rawD = [System.IO.File]::ReadAllText($dst)
                    if ($rawD -match '"transcriptUnavailable"\s*:\s*true') { $dstHealth = 'damaged' }
                    elseif ($rawD -match '"cliSessionId"\s*:\s*"[^"]+"')   { $dstHealth = 'healthy' }
                    else                                                    { $dstHealth = 'damaged' }
                } catch { $dstHealth = 'unknown' }
            }

            # Precedence: health beats timestamps. A healthy copy may heal a damaged
            # destination even when the destination is newer (the app's startup
            # mutation bumps mtime, so the damaged side is USUALLY newer). Otherwise
            # newest wins with a 2s granularity tolerance, and a damaged winner may
            # only ever replace a provably damaged destination (healthy and
            # unreadable destinations stay protected).
            if (-not $dstItem) {
                if ($winnerHealth -ne 'healthy') { $skipped++; continue }   # don't seed new slots with damage
            } else {
                $winnerNewer = ($winner.LastWriteTimeUtc - $dstItem.LastWriteTimeUtc).TotalSeconds -gt 2
                if ($winnerHealth -eq 'healthy' -and $dstHealth -eq 'damaged') { }   # heal, regardless of age
                elseif (-not $winnerNewer)                { continue }               # dst same/newer, no heal needed
                elseif ($winnerHealth -eq 'healthy')      { }                        # newest healthy wins
                elseif ($dstHealth -eq 'damaged')         { }                        # damaged over damaged: take newest
                else                                      { $skipped++; continue }   # damaged winner vs healthy/unknown dst
            }

            if (-not $PSCmdlet.ShouldProcess($dst, "overwrite with $($winner.FullName)")) { continue }

            # Atomic: copy to temp sibling, verify, rename. The app never sees a torn file.
            $tmp = Join-Path $ws.FullName "$name.cs-tmp-$PID"
            try {
                Copy-Item -LiteralPath $winner.FullName -Destination $tmp -Force -ErrorAction Stop
                $tmpItem = Get-Item -LiteralPath $tmp -ErrorAction Stop
                $tmpHealthy = $false
                try {
                    $rawT = [System.IO.File]::ReadAllText($tmp)
                    $tmpHealthy = ($rawT -match '"cliSessionId"\s*:\s*"[^"]+"') -and ($rawT -notmatch '"transcriptUnavailable"\s*:\s*true')
                } catch { }
                $sizeOk   = $tmpItem.Length -eq $winner.Length   # source changed mid-copy -> retry next run
                $healthOk = if ($winnerHealth -eq 'healthy') { $tmpHealthy } else { $true }
                if ($sizeOk -and $healthOk) {
                    Move-Item -LiteralPath $tmp -Destination $dst -Force -ErrorAction Stop
                    $copies++
                } else {
                    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
                    $skipped++
                }
            } catch {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
                $skipped++
            }
        }
    }
}

# Heartbeat on EVERY run: a dead sync and a quiet sync must not look identical.
Log "v$ToolVersion run: $(@($roots).Count) root(s), $(@($targets).Count) workspace(s) ($(@($sources).Count) with chats), $contestedCount contested, $copies copied, $skipped skipped"
$tail = Get-Content $logF -Tail 1000 -ErrorAction SilentlyContinue
if ($tail) { Set-Content -Path $logF -Value $tail -ErrorAction SilentlyContinue }

} finally { [void]$mutex.ReleaseMutex(); $mutex.Dispose() }
