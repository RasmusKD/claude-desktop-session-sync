# Bidirectional Claude Code chat-list sync across Claude desktop accounts on this
# machine. See README.md for the full design rationale and AUDIT.md for the
# adversarial-review history that shaped these invariants.
#
# Design invariants:
#  - one sync target per device-id (account): its single workspace folder. A device
#    with MULTIPLE chat-bearing workspace folders is skipped (no safe pairing), and
#    when BOTH data roots hold chat-bearing devices (mid app migration) only the
#    most recently active root is synced.
#  - a fresh account's empty workspace folder IS a target (it gets seeded). A
#    workspace that HELD chats last run and is empty now is FROZEN (neither seeded
#    nor used as deletion evidence) until the user resolves it; reseeding would
#    fight an intentional clear-out, deleting everywhere would amplify an accident.
#  - three-state health (healthy / damaged / unknown); health beats timestamps.
#  - writes are atomic (temp sibling, verify, rename).
#  - deletions propagate via a manifest of fully-synced chats. The manifest carries
#    a timestamp and is DISCARDED when older than 7 days (a stale manifest is
#    rebuilt, never trusted). A chat whose deletion partially fails is excluded
#    from both the copy pass and the manifest, so it cannot resurrect.
#  - sidebar groups mirror by last-writer-wins RAW TEXT SPLICE: the most recently
#    active account's scope entry is copied verbatim (bytes, not objects) onto the
#    other accounts' keys inside claude_desktop_config.json. The file is never
#    parsed-and-reserialized for writing, so unknown properties, dates, arrays and
#    formatting in untouched sections survive by construction.
#  - a lock file serializes concurrent runs across sessions; every run heartbeats.
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$Quiet,
    [switch]$Status,
    [string]$Restore,             # stash filename (or unique fragment) to restore everywhere
    [string[]]$RootsOverride,     # test hook: fixture tree
    [string]$ConfigPathOverride,  # test hook: fixture config
    [string]$StateDirOverride     # test hook: keep state out of the repo
)
$ErrorActionPreference = 'Continue'
$ToolVersion = '0.4.0'
$ManifestMaxAgeDays = 7
$StashRetentionDays = 30

$roots = if ($RootsOverride) { @($RootsOverride | Where-Object { Test-Path $_ }) } else {
    @(
        (Join-Path $env:APPDATA 'Claude\claude-code-sessions'),
        (Join-Path $env:LOCALAPPDATA 'Claude-3p\claude-code-sessions')
    ) | Where-Object { Test-Path $_ }
}
$configPath = if ($ConfigPathOverride) { $ConfigPathOverride } else { Join-Path $env:APPDATA 'Claude\claude_desktop_config.json' }
# State always lives in the per-user install dir, never next to whichever copy of
# the script happened to run: a git-clone test run must not write logs, manifests
# or config backups (which can carry MCP secrets) into a tree someone might push.
$stateDir = if ($StateDirOverride) { $StateDirOverride } else { Join-Path $env:LOCALAPPDATA 'ClaudeChatSync' }
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

$logF      = Join-Path $stateDir 'sync-log.txt'
$manifestF = Join-Path $stateDir 'sync-fullset.txt'
$deletedD  = Join-Path $stateDir 'deleted'
$brokenF   = Join-Path $stateDir 'CONFIG-MIRROR-BROKEN.txt'
$cfgErrCntF = Join-Path $stateDir 'cfg-error-count.txt'

function Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg"
    Add-Content -Path $logF -Value $line -ErrorAction SilentlyContinue
    if (-not $Quiet) { Write-Host $line }
}

function Get-HealthRaw($path) {
    try {
        $raw = [System.IO.File]::ReadAllText($path)
        # Negative lookbehind: a chat TITLE containing the literal marker text is
        # JSON-escaped (\"), so requiring an unescaped quote kills that false hit.
        if ($raw -match '(?<!\\)"transcriptUnavailable"\s*:\s*true') { return 'damaged' }
        if ($raw -match '(?<!\\)"cliSessionId"\s*:\s*"[^"]+"') { return 'healthy' }
        return 'damaged'
    } catch { return 'unknown' }
}

# ── Discovery: one target workspace per device-id, one root at a time ────────
$targetsByRoot = @{}
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
        $t = $null
        if ($chatBearing.Count -eq 1)  { $t = $chatBearing[0] }
        elseif ($wsDirs.Count -eq 1)   { $t = $wsDirs[0] }
        if ($t) {
            if (-not $targetsByRoot.ContainsKey($root)) { $targetsByRoot[$root] = @() }
            $targetsByRoot[$root] += $t
        }
    }
}
# Mid-migration both roots can hold devices; syncing into a root the app is
# abandoning repopulates it forever. Pick the root with the newest activity.
$activeRoot = $null
if ($targetsByRoot.Keys.Count -gt 1) {
    $best = $null
    foreach ($r in $targetsByRoot.Keys) {
        $newest = Get-ChildItem -Path $targetsByRoot[$r].FullName -Filter 'local_*.json' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
        $stamp = if ($newest) { $newest.LastWriteTimeUtc } else { [datetime]::MinValue }
        if (-not $best -or $stamp -gt $best.stamp) { $best = @{ root = $r; stamp = $stamp } }
    }
    $activeRoot = $best.root
    Log "warning: multiple data roots hold accounts; syncing only the most recently active ($activeRoot)"
} elseif ($targetsByRoot.Keys.Count -eq 1) {
    $activeRoot = @($targetsByRoot.Keys)[0]
}
$targets = if ($activeRoot) { @($targetsByRoot[$activeRoot]) } else { @() }

function Get-ScopeKey($ws) { (Split-Path (Split-Path $ws.FullName -Parent) -Leaf) + '/' + $ws.Name }

$sourceSet = @{}
foreach ($t in $targets) {
    if ((Get-ChildItem -Path $t.FullName -Filter 'local_*.json' -File -ErrorAction SilentlyContinue).Count -gt 0) {
        $sourceSet[$t.FullName] = $true
    }
}

# ── Manifest: header (#v1 <utc> sources=key;key) + one fully-synced name per line
$prevFull = @{}; $prevSources = @{}
if (Test-Path $manifestF) {
    $lines = @(Get-Content $manifestF -ErrorAction SilentlyContinue)
    $stale = $true
    if ($lines.Count -gt 0 -and $lines[0] -match '^#v1 (\S+)(?: sources=(.*))?$') {
        $age = $null
        try { $age = (Get-Date).ToUniversalTime() - [datetime]::Parse($Matches[1], [System.Globalization.CultureInfo]::InvariantCulture, 'AdjustToUniversal') } catch { }
        if ($age -ne $null -and $age.TotalDays -le $ManifestMaxAgeDays) {
            $stale = $false
            foreach ($l in ($lines | Select-Object -Skip 1)) { if ($l) { $prevFull[$l] = $true } }
            if ($Matches[2]) { foreach ($k in ($Matches[2] -split ';')) { if ($k) { $prevSources[$k] = $true } } }
        }
    }
    if ($stale) { Log 'manifest missing header or older than the trust window; rebuilding (no deletions this run)' }
}

# A workspace that was a source last run and is EMPTY now was either cleared on
# purpose or reset by the app. Freeze it: no reseeding, no deletion evidence.
$frozen = 0
$targets = @($targets | Where-Object {
    $key = Get-ScopeKey $_
    if ($prevSources.ContainsKey($key) -and -not $sourceSet[$_.FullName]) {
        Log "warning: workspace $key held chats last run and is now empty; FROZEN (not reseeding, not deleting). Delete the manifest line or let the $ManifestMaxAgeDays-day window expire to resume."
        $script:frozen++
        $false
    } else { $true }
})

if ($Status) {
    Write-Host "claude-desktop-session-sync v$ToolVersion"
    Write-Host "roots found:      $(@($roots).Count) (active: $activeRoot)"
    Write-Host "sync targets:     $(@($targets).Count) workspace(s), $($sourceSet.Count) with chats, $skippedDevices device(s) skipped, $frozen frozen"
    Write-Host "manifest:         $($prevFull.Count) fully-synced chat(s) tracked"
    if (Test-Path $brokenF) { Write-Host "CONFIG MIRROR BROKEN: see $brokenF" -ForegroundColor Red }
    Write-Host 'last log lines:'
    Get-Content $logF -Tail 3 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $_" }
    exit 0
}

# ── Cross-session lock file (works without SeCreateGlobalPrivilege, and a killed
#    run releases it with its process handle; a named mutex does neither cleanly).
$lock = $null
try { $lock = [System.IO.File]::Open((Join-Path $stateDir 'sync.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
catch { Log 'skipped: another sync is already running'; exit 0 }
try {

foreach ($t in $targets) {
    Get-ChildItem -Path $t.FullName -Filter '*.cs-tmp-*' -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}
$cfgDir = Split-Path $configPath -Parent
if (Test-Path $cfgDir) {
    Get-ChildItem -Path $cfgDir -Filter '*.cs-tmp-*' -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}
# Stash retention: deleted chats are not kept forever (README documents 30 days).
if (Test-Path $deletedD) {
    Get-ChildItem -Path $deletedD -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -lt (Get-Date).ToUniversalTime().AddDays(-$StashRetentionDays) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

# ── -Restore: copy a stashed deletion back into every workspace ──────────────
if ($Restore) {
    $hit = Get-ChildItem -Path $deletedD -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "*$Restore*" } | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if (-not $hit) { Write-Host "no stash entry matches '$Restore'"; exit 1 }
    if ($hit.Name -match '(local_.+\.json)$') {
        $chatName = $Matches[1]
        foreach ($ws in $targets) {
            if ($PSCmdlet.ShouldProcess((Join-Path $ws.FullName $chatName), "restore from $($hit.Name)")) {
                Copy-Item -LiteralPath $hit.FullName -Destination (Join-Path $ws.FullName $chatName) -Force
            }
        }
        Log "restored $chatName to $(@($targets).Count) workspace(s) from stash"
        Write-Host "restored $chatName. It will re-enter the manifest on the next run."
    }
    exit 0
}

$copies = 0; $skipped = 0; $contestedCount = 0; $deleted = 0; $cfgState = 'skipped'
$failedDeletes = @{}

if (@($targets).Count -ge 2 -and $sourceSet.Count -ge 1) {

    $byName = @{}
    foreach ($ws in $targets) {
        foreach ($f in Get-ChildItem -Path $ws.FullName -Filter 'local_*.json' -File -ErrorAction SilentlyContinue) {
            if (-not $byName.ContainsKey($f.Name)) { $byName[$f.Name] = @() }
            $byName[$f.Name] += $f
        }
    }

    # ── Deletion propagation ─────────────────────────────────────────────────
    foreach ($name in @($prevFull.Keys)) {
        if (-not $byName.ContainsKey($name)) { continue }
        $havers = @($byName[$name])
        if ($havers.Count -eq @($targets).Count) { continue }
        $haverDirs = @{}
        foreach ($h in $havers) { $haverDirs[$h.DirectoryName] = $true }
        $evidence = @($targets | Where-Object { (-not $haverDirs[$_.FullName]) -and $sourceSet[$_.FullName] })
        if ($evidence.Count -lt 1) { continue }
        if (-not $PSCmdlet.ShouldProcess($name, 'propagate deletion')) { continue }
        try {
            New-Item -ItemType Directory -Force -Path $deletedD | Out-Null
            # Stash the best copy (healthiest, then newest), named with its device
            # id so a multi-account stash stays attributable.
            $ordered = @($havers | Sort-Object @{E = { (Get-HealthRaw $_.FullName) -eq 'healthy' }; Descending = $true}, @{E = 'LastWriteTimeUtc'; Descending = $true})
            $deviceId = Split-Path (Split-Path $ordered[0].DirectoryName -Parent) -Leaf
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            Copy-Item -LiteralPath $ordered[0].FullName -Destination (Join-Path $deletedD "$stamp-$deviceId-$name") -Force -ErrorAction Stop
            foreach ($h in $havers) { Remove-Item -LiteralPath $h.FullName -Force -ErrorAction Stop }
            $byName.Remove($name)
            $deleted++
        } catch {
            # A live copy survived (typically held open by the app). Excluding the
            # name from the copy pass AND the manifest is what makes the retry
            # real: otherwise the survivor is copied back and re-recorded.
            $failedDeletes[$name] = $true
            Log "warning: deletion of $name incomplete (a copy is in use); retrying next run"
        }
    }

    # ── Copy propagation (newest-healthy-wins, atomic) ───────────────────────
    $healthCache = @{}
    foreach ($name in $byName.Keys) {
        if ($failedDeletes.ContainsKey($name)) { continue }
        $all = @($byName[$name] | Sort-Object LastWriteTimeUtc -Descending)

        $spread = ($all[0].LastWriteTimeUtc - $all[-1].LastWriteTimeUtc).TotalSeconds
        if ($all.Count -eq @($targets).Count -and $spread -le 2) { continue }
        $contestedCount++

        $winner = $null; $winnerHealth = $null
        foreach ($state in 'healthy', 'damaged') {
            foreach ($c in $all) {
                if (-not $healthCache.ContainsKey($c.FullName)) { $healthCache[$c.FullName] = Get-HealthRaw $c.FullName }
                if ($healthCache[$c.FullName] -eq $state) { $winner = $c; $winnerHealth = $state; break }
            }
            if ($winner) { break }
        }
        if (-not $winner) { $skipped++; continue }

        foreach ($ws in $targets) {
            if ($winner.DirectoryName -eq $ws.FullName) { continue }
            $dst = Join-Path $ws.FullName $name
            $dstItem = Get-Item -LiteralPath $dst -ErrorAction SilentlyContinue
            $dstHealth = $null
            if ($dstItem) { $dstHealth = Get-HealthRaw $dst }

            # Precedence: health beats timestamps; then newest wins (2s tolerance);
            # a damaged winner may replace a provably damaged destination, and may
            # SEED an absent one (a damaged copy of the chat beats no chat at all).
            if ($dstItem) {
                $winnerNewer = ($winner.LastWriteTimeUtc - $dstItem.LastWriteTimeUtc).TotalSeconds -gt 2
                if ($winnerHealth -eq 'healthy' -and $dstHealth -eq 'damaged') { }
                elseif (-not $winnerNewer)           { continue }
                elseif ($winnerHealth -eq 'healthy') { }
                elseif ($dstHealth -eq 'damaged')    { }
                else                                 { $skipped++; continue }
            }

            if (-not $PSCmdlet.ShouldProcess($dst, "overwrite with $($winner.FullName)")) { continue }

            $tmp = Join-Path $ws.FullName "$name.cs-tmp-$PID"
            try {
                Copy-Item -LiteralPath $winner.FullName -Destination $tmp -Force -ErrorAction Stop
                $tmpItem = Get-Item -LiteralPath $tmp -ErrorAction Stop
                $tmpHealth = Get-HealthRaw $tmp
                $sizeOk   = $tmpItem.Length -eq $winner.Length
                $healthOk = if ($winnerHealth -eq 'healthy') { $tmpHealth -eq 'healthy' } else { $tmpHealth -ne 'unknown' }
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

    # ── Manifest rewrite (header + names present everywhere; failures excluded)
    if (-not $WhatIfPreference) {
        $fullNow = foreach ($name in $byName.Keys) {
            if ($failedDeletes.ContainsKey($name)) { continue }
            $everywhere = $true
            foreach ($ws in $targets) {
                if (-not (Test-Path -LiteralPath (Join-Path $ws.FullName $name))) { $everywhere = $false; break }
            }
            if ($everywhere) { $name }
        }
        # Names with a partially-failed deletion STAY in the manifest: that is what
        # lets the next run recognize the survivor as a pending deletion instead of
        # reseeding it as a brand-new chat.
        $fullList = @($fullNow) + @($failedDeletes.Keys)
        $srcKeys = (@($targets | Where-Object { $sourceSet[$_.FullName] } | ForEach-Object { Get-ScopeKey $_ }) -join ';')
        $header = "#v1 $((Get-Date).ToUniversalTime().ToString('o')) sources=$srcKeys"
        $tmpMan = "$manifestF.tmp"
        Set-Content -Path $tmpMan -Value (@($header) + @($fullList | Sort-Object)) -ErrorAction SilentlyContinue
        Move-Item -LiteralPath $tmpMan -Destination $manifestF -Force -ErrorAction SilentlyContinue
    }

    # ── Sidebar groups: last-writer-wins raw text splice ─────────────────────
    # The winning account's scope entry inside "dframe-group-scopes" is copied
    # VERBATIM (raw bytes) onto the other accounts' keys. The config is never
    # parsed-and-reserialized: unknown properties, dates, single-element arrays
    # and formatting in every untouched byte survive by construction.
    $cfgState = 'unchanged'
    if (Test-Path $configPath) {
        try {
            $cfgRaw = [System.IO.File]::ReadAllText($configPath)

            # Scan one JSON value starting at $i (first non-ws char); returns index AFTER it.
            function Skip-JsonValue([string]$s, [int]$i) {
                while ($i -lt $s.Length -and [char]::IsWhiteSpace($s[$i])) { $i++ }
                if ($i -ge $s.Length) { return -1 }
                $c = $s[$i]
                if ($c -eq '"') {
                    $i++
                    while ($i -lt $s.Length) {
                        if ($s[$i] -eq '\') { $i += 2; continue }
                        if ($s[$i] -eq '"') { return $i + 1 }
                        $i++
                    }
                    return -1
                }
                if ($c -eq '{' -or $c -eq '[') {
                    $open = $c; $close = if ($c -eq '{') { '}' } else { ']' }
                    $depth = 0
                    while ($i -lt $s.Length) {
                        $ch = $s[$i]
                        if ($ch -eq '"') { $i = Skip-JsonValue $s $i; if ($i -lt 0) { return -1 }; continue }
                        if ($ch -eq $open) { $depth++ }
                        elseif ($ch -eq $close) { $depth--; if ($depth -eq 0) { return $i + 1 } }
                        $i++
                    }
                    return -1
                }
                while ($i -lt $s.Length -and $s[$i] -notmatch '[,\}\]\s]') { $i++ }
                return $i
            }

            # Find the value span of "key" at the top level of the object starting at $objStart.
            function Find-KeySpan([string]$s, [int]$objStart, [string]$key) {
                $i = $objStart + 1
                while ($i -lt $s.Length) {
                    while ($i -lt $s.Length -and ($s[$i] -match '[\s,]')) { $i++ }
                    if ($i -ge $s.Length -or $s[$i] -eq '}') { return $null }
                    if ($s[$i] -ne '"') { return $null }
                    $kEnd = Skip-JsonValue $s $i
                    if ($kEnd -lt 0) { return $null }
                    $k = $s.Substring($i + 1, $kEnd - $i - 2) -replace '\\/', '/'
                    $j = $kEnd
                    while ($j -lt $s.Length -and [char]::IsWhiteSpace($s[$j])) { $j++ }
                    if ($s[$j] -ne ':') { return $null }
                    $j++
                    while ($j -lt $s.Length -and [char]::IsWhiteSpace($s[$j])) { $j++ }
                    $vEnd = Skip-JsonValue $s $j
                    if ($vEnd -lt 0) { return $null }
                    if ($k -eq $key) { return @{ ValueStart = $j; ValueEnd = $vEnd } }
                    $i = $vEnd
                }
                return $null
            }

            # Locate the dframe-group-scopes object.
            $m = [regex]::Match($cfgRaw, '"dframe-group-scopes"\s*:\s*\{')
            if ($m.Success -and @($targets).Count -ge 2) {
                $scopesStart = $cfgRaw.IndexOf('{', $m.Index + $m.Length - 1)
                # Winner: most recently active account that HAS a scope entry.
                $byActivity = @($targets | Sort-Object {
                    $n = Get-ChildItem -Path $_.FullName -Filter 'local_*.json' -File -ErrorAction SilentlyContinue |
                        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
                    if ($n) { $n.LastWriteTimeUtc } else { [datetime]::MinValue }
                } -Descending)
                $srcSpan = $null; $srcKeyName = $null
                foreach ($t in $byActivity) {
                    $k = (Get-ScopeKey $t)
                    $span = Find-KeySpan $cfgRaw $scopesStart $k
                    if ($span) { $srcSpan = $span; $srcKeyName = $k; break }
                }
                if ($srcSpan) {
                    $srcRaw = $cfgRaw.Substring($srcSpan.ValueStart, $srcSpan.ValueEnd - $srcSpan.ValueStart)
                    $out = $cfgRaw; $cfgChanged = $false
                    foreach ($t in $byActivity) {
                        $k = Get-ScopeKey $t
                        if ($k -eq $srcKeyName) { continue }
                        # Re-locate spans in the CURRENT text (offsets shift per splice).
                        $mm = [regex]::Match($out, '"dframe-group-scopes"\s*:\s*\{')
                        $os = $out.IndexOf('{', $mm.Index + $mm.Length - 1)
                        $span = Find-KeySpan $out $os $k
                        if ($span) {
                            $existing = $out.Substring($span.ValueStart, $span.ValueEnd - $span.ValueStart)
                            if ($existing -ne $srcRaw) {
                                $out = $out.Substring(0, $span.ValueStart) + $srcRaw + $out.Substring($span.ValueEnd)
                                $cfgChanged = $true
                            }
                        } else {
                            $insertAt = $os + 1
                            $probe = $insertAt
                            while ($probe -lt $out.Length -and [char]::IsWhiteSpace($out[$probe])) { $probe++ }
                            $suffix = if ($out[$probe] -eq '}') { '' } else { ',' }
                            $kEsc = $k -replace '"', '\"'
                            $out = $out.Substring(0, $insertAt) + '"' + $kEsc + '":' + $srcRaw + $suffix + $out.Substring($insertAt)
                            $cfgChanged = $true
                        }
                    }
                    if ($cfgChanged -and $PSCmdlet.ShouldProcess($configPath, 'mirror sidebar groups (raw splice)')) {
                        Copy-Item -LiteralPath $configPath -Destination (Join-Path $stateDir "config-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss').json") -Force
                        Get-ChildItem -Path $stateDir -Filter 'config-backup-*.json' -File |
                            Sort-Object Name -Descending | Select-Object -Skip 5 |
                            Remove-Item -Force -ErrorAction SilentlyContinue
                        $tmpCfg = "$configPath.cs-tmp-$PID"
                        [System.IO.File]::WriteAllText($tmpCfg, $out)
                        # Lost-update guard: if the app rewrote the config between our
                        # read and now, skip; next run re-splices against fresh text.
                        if ([System.IO.File]::ReadAllText($configPath) -ne $cfgRaw) {
                            Log 'warning: config changed under us; skipping this write'
                            Remove-Item -LiteralPath $tmpCfg -Force -ErrorAction SilentlyContinue
                        } else {
                            Move-Item -LiteralPath $tmpCfg -Destination $configPath -Force -ErrorAction Stop
                            $cfgState = 'updated'
                        }
                    }
                }
            }
            Set-Content -Path $cfgErrCntF -Value '0' -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $brokenF -Force -ErrorAction SilentlyContinue
        } catch {
            $cfgState = 'error'
            Log "warning: config mirror skipped ($($_.Exception.Message))"
            $n = 0; try { $n = [int](Get-Content $cfgErrCntF -ErrorAction SilentlyContinue) } catch { }
            $n++
            Set-Content -Path $cfgErrCntF -Value $n -ErrorAction SilentlyContinue
            if ($n -ge 3) {
                Set-Content -Path $brokenF -Value "Config mirroring has failed $n consecutive runs.`nLast error: $($_.Exception.Message)`nAt: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ErrorAction SilentlyContinue
            }
        }
    }
}

Log "v$ToolVersion run: $(@($roots).Count) root(s), $(@($targets).Count) workspace(s) ($($sourceSet.Count) with chats, $frozen frozen), $contestedCount contested, $copies copied, $skipped skipped, $deleted deleted, cfg $cfgState"
$tail = Get-Content $logF -Tail 1000 -ErrorAction SilentlyContinue
if ($tail) {
    $tmpLog = "$logF.tmp"
    Set-Content -Path $tmpLog -Value $tail -ErrorAction SilentlyContinue
    Move-Item -LiteralPath $tmpLog -Destination $logF -Force -ErrorAction SilentlyContinue
}

} finally { if ($lock) { $lock.Dispose() } }
