# Bidirectional Claude Code chat-list sync across Claude desktop accounts on this
# machine. See README.md for the full design rationale.
#
# Design invariants:
#  - one sync target per device-id (account): its single workspace folder. A device
#    with MULTIPLE chat-bearing workspace folders is skipped with a logged warning,
#    because no safe pairing can be inferred.
#  - a fresh account's empty workspace folder IS a target (it gets seeded), and is
#    NEVER treated as deletion evidence.
#  - three-state health (healthy / damaged / unknown): a copy the app has mutated
#    never beats a healthy copy; an unreadable copy neither wins nor loses
#    protection. Health beats timestamps (a healthy copy heals a damaged newer one).
#  - writes are atomic: copy to a temp sibling, verify size + health, then rename.
#  - deletions propagate via a full-set manifest: a chat that was present in every
#    workspace at the end of a prior run, and is now missing from a chat-bearing
#    workspace, was deleted there; the remaining copies are stashed under
#    deleted\ in the state dir and then removed everywhere.
#  - sidebar groups and per-folder permission modes are mirrored across the
#    account-keyed sections of claude_desktop_config.json (union semantics,
#    change-only atomic writes, timestamped config backups kept).
#  - a named mutex serializes concurrent runs; every run writes a heartbeat.
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$Quiet,
    [switch]$Status,
    [string[]]$RootsOverride,     # tests point this at a fixture tree
    [string]$ConfigPathOverride,  # tests point this at a fixture config
    [string]$StateDirOverride     # tests keep manifest/log/stash out of the repo
)
$ErrorActionPreference = 'Continue'
$ToolVersion = '0.3.0'

$roots = if ($RootsOverride) { @($RootsOverride | Where-Object { Test-Path $_ }) } else {
    @(
        (Join-Path $env:APPDATA 'Claude\claude-code-sessions'),
        (Join-Path $env:LOCALAPPDATA 'Claude-3p\claude-code-sessions')
    ) | Where-Object { Test-Path $_ }
}
$configPath = if ($ConfigPathOverride) { $ConfigPathOverride } else { Join-Path $env:APPDATA 'Claude\claude_desktop_config.json' }
$stateDir   = if ($StateDirOverride) { $StateDirOverride } else { $PSScriptRoot }

$logF      = Join-Path $stateDir 'sync-log.txt'
$manifestF = Join-Path $stateDir 'sync-fullset.txt'
$deletedD  = Join-Path $stateDir 'deleted'
function Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg"
    Add-Content -Path $logF -Value $line -ErrorAction SilentlyContinue
    if (-not $Quiet) { Write-Host $line }
}

function Get-HealthRaw($path) {
    try {
        $raw = [System.IO.File]::ReadAllText($path)
        if ($raw -match '"transcriptUnavailable"\s*:\s*true') { return 'damaged' }
        if ($raw -match '"cliSessionId"\s*:\s*"[^"]+"') { return 'healthy' }
        return 'damaged'
    } catch { return 'unknown' }
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
        elseif ($wsDirs.Count -eq 1)   { $targets += $wsDirs[0] }
    }
}
$sourceSet = @{}
foreach ($t in $targets) {
    if ((Get-ChildItem -Path $t.FullName -Filter 'local_*.json' -File -ErrorAction SilentlyContinue).Count -gt 0) {
        $sourceSet[$t.FullName] = $true
    }
}

if ($Status) {
    Write-Host "claude-desktop-session-sync v$ToolVersion"
    Write-Host "roots found:      $(@($roots).Count)"
    $roots | ForEach-Object { Write-Host "  $_" }
    Write-Host "sync targets:     $(@($targets).Count) workspace(s), $($sourceSet.Count) with chats, $skippedDevices device(s) skipped"
    Write-Host "manifest:         $(@(Get-Content $manifestF -ErrorAction SilentlyContinue).Count) fully-synced chat(s) tracked"
    Write-Host "last log lines:"
    Get-Content $logF -Tail 3 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $_" }
    exit 0
}

# ── Serialize runs (scheduled vs manual) ─────────────────────────────────────
$mutex = New-Object System.Threading.Mutex($false, 'Local\ClaudeChatSync')
if (-not $mutex.WaitOne(0)) { exit 0 }
try {

foreach ($t in $targets) {
    Get-ChildItem -Path $t.FullName -Filter '*.cs-tmp-*' -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

$copies = 0; $skipped = 0; $contestedCount = 0; $deleted = 0; $cfgState = 'skipped'

if (@($targets).Count -ge 2 -and $sourceSet.Count -ge 1) {

    # Collect all copies of each chat by filename.
    $byName = @{}
    foreach ($ws in $targets) {
        foreach ($f in Get-ChildItem -Path $ws.FullName -Filter 'local_*.json' -File -ErrorAction SilentlyContinue) {
            if (-not $byName.ContainsKey($f.Name)) { $byName[$f.Name] = @() }
            $byName[$f.Name] += $f
        }
    }

    # ── Deletion propagation (before copies, so nothing is resurrected) ─────
    # A name in the manifest was present in EVERY workspace at the end of an
    # earlier run. If a chat-bearing workspace no longer has it, that is a real
    # deletion; empty workspaces are fresh accounts, never deletion evidence.
    $prevFull = @{}
    foreach ($line in @(Get-Content $manifestF -ErrorAction SilentlyContinue)) {
        if ($line) { $prevFull[$line] = $true }
    }
    foreach ($name in @($prevFull.Keys)) {
        if (-not $byName.ContainsKey($name)) { continue }   # gone everywhere; drops from manifest naturally
        $havers = @($byName[$name])
        if ($havers.Count -eq @($targets).Count) { continue }
        $haverDirs = @{}
        foreach ($h in $havers) { $haverDirs[$h.DirectoryName] = $true }
        $evidence = @($targets | Where-Object { (-not $haverDirs[$_.FullName]) -and $sourceSet[$_.FullName] })
        if ($evidence.Count -lt 1) { continue }
        if (-not $PSCmdlet.ShouldProcess($name, 'propagate deletion')) { continue }
        try {
            New-Item -ItemType Directory -Force -Path $deletedD | Out-Null
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            Copy-Item -LiteralPath $havers[0].FullName -Destination (Join-Path $deletedD "$stamp-$name") -Force -ErrorAction Stop
            foreach ($h in $havers) { Remove-Item -LiteralPath $h.FullName -Force -ErrorAction Stop }
            $byName.Remove($name)
            $deleted++
        } catch {
            Log "warning: deletion of $name failed mid-way; will retry next run"
        }
    }

    # ── Copy propagation (newest-healthy-wins, atomic) ───────────────────────
    $healthCache = @{}
    foreach ($name in $byName.Keys) {
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
            # a damaged winner only ever replaces a provably damaged destination.
            if (-not $dstItem) {
                if ($winnerHealth -ne 'healthy') { $skipped++; continue }
            } else {
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

    # ── Manifest: names present in EVERY workspace after this run ───────────
    if (-not $WhatIfPreference) {
        $fullNow = foreach ($name in $byName.Keys) {
            $everywhere = $true
            foreach ($ws in $targets) {
                if (-not (Test-Path -LiteralPath (Join-Path $ws.FullName $name))) { $everywhere = $false; break }
            }
            if ($everywhere) { $name }
        }
        Set-Content -Path $manifestF -Value ($fullNow | Sort-Object) -ErrorAction SilentlyContinue
    }

    # ── Mirror account-keyed config sections (groups, folder permissions) ───
    $cfgState = 'unchanged'
    if (Test-Path $configPath) {
        try {
            $cfgRaw = [System.IO.File]::ReadAllText($configPath)
            $cfg = $cfgRaw | ConvertFrom-Json
            $epitaxy = $null
            if ($cfg.preferences) { $epitaxy = $cfg.preferences.epitaxyPrefs }
            if ($epitaxy) {
                $cfgChanged = $false
                # Scope keys for our targets: "<device-id>/<workspace-id>".
                $scopeKeys = @($targets | ForEach-Object {
                    (Split-Path (Split-Path $_.FullName -Parent) -Leaf) + '/' + $_.Name
                })
                $deviceKeys = @($targets | ForEach-Object { Split-Path (Split-Path $_.FullName -Parent) -Leaf } | Sort-Object -Unique)

                # Groups: union across our accounts (first-seen name wins per id;
                # member order preserved, keys sorted for deterministic output).
                $gsProp = $epitaxy.PSObject.Properties['dframe-group-scopes']
                if ($gsProp -and $gsProp.Value) {
                    $gs = $gsProp.Value
                    $entries = @()
                    foreach ($k in ($scopeKeys | Sort-Object)) {
                        $p = $gs.PSObject.Properties[$k]
                        if ($p -and $p.Value) { $entries += $p.Value }
                    }
                    if ($entries.Count -gt 0) {
                        $seenIds = @{}; $mGroups = @()
                        foreach ($e in $entries) {
                            foreach ($g in @($e.groups)) {
                                if ($g -and $g.id -and -not $seenIds.ContainsKey($g.id)) {
                                    $seenIds[$g.id] = $true
                                    $mGroups += [pscustomobject]@{ id = $g.id; name = $g.name }
                                }
                            }
                        }
                        $mOrder = [ordered]@{}
                        foreach ($e in $entries) {
                            $op = $null
                            if ($e.PSObject.Properties['order']) { $op = $e.order }
                            if ($op) {
                                foreach ($prop in ($op.PSObject.Properties | Sort-Object Name)) {
                                    if (-not $mOrder.Contains($prop.Name)) { $mOrder[$prop.Name] = @() }
                                    foreach ($ref in @($prop.Value)) {
                                        if ($mOrder[$prop.Name] -notcontains $ref) { $mOrder[$prop.Name] += $ref }
                                    }
                                }
                            }
                        }
                        $merged = [pscustomobject]@{
                            groups = @($mGroups | Sort-Object id)
                            order  = [pscustomobject]$mOrder
                        }
                        $mergedJson = $merged | ConvertTo-Json -Compress -Depth 16
                        foreach ($k in $scopeKeys) {
                            $p = $gs.PSObject.Properties[$k]
                            $existingJson = if ($p -and $p.Value) { $p.Value | ConvertTo-Json -Compress -Depth 16 } else { '' }
                            if ($existingJson -ne $mergedJson) {
                                if ($p) { $p.Value = $merged }
                                else { $gs | Add-Member -NotePropertyName $k -NotePropertyValue $merged }
                                $cfgChanged = $true
                            }
                        }
                    }
                }

                # Folder permission modes: fill gaps across our accounts, never
                # overwrite an explicit existing value.
                $fpmProp = $epitaxy.PSObject.Properties['epitaxy-folder-permission-mode']
                if ($fpmProp -and $fpmProp.Value -and $deviceKeys.Count -ge 2) {
                    $fpm = $fpmProp.Value
                    $union = [ordered]@{}
                    foreach ($dk in $deviceKeys) {
                        $p = $fpm.PSObject.Properties[$dk]
                        if ($p -and $p.Value) {
                            foreach ($fp in $p.Value.PSObject.Properties) {
                                if (-not $union.Contains($fp.Name)) { $union[$fp.Name] = $fp.Value }
                            }
                        }
                    }
                    if ($union.Count -gt 0) {
                        foreach ($dk in $deviceKeys) {
                            $p = $fpm.PSObject.Properties[$dk]
                            if (-not $p) {
                                $fpm | Add-Member -NotePropertyName $dk -NotePropertyValue ([pscustomobject]$union)
                                $cfgChanged = $true
                            } else {
                                foreach ($name in $union.Keys) {
                                    if (-not $p.Value.PSObject.Properties[$name]) {
                                        $p.Value | Add-Member -NotePropertyName $name -NotePropertyValue $union[$name]
                                        $cfgChanged = $true
                                    }
                                }
                            }
                        }
                    }
                }

                if ($cfgChanged -and $PSCmdlet.ShouldProcess($configPath, 'mirror account-keyed sections')) {
                    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                    Copy-Item -LiteralPath $configPath -Destination (Join-Path $stateDir "config-backup-$stamp.json") -Force
                    Get-ChildItem -Path $stateDir -Filter 'config-backup-*.json' -File |
                        Sort-Object Name -Descending | Select-Object -Skip 5 |
                        Remove-Item -Force -ErrorAction SilentlyContinue
                    $tmpCfg = "$configPath.cs-tmp-$PID"
                    # WriteAllText = UTF-8 WITHOUT BOM. PS 5.1's Set-Content -Encoding UTF8
                    # writes a BOM, which strict JSON parsers reject.
                    [System.IO.File]::WriteAllText($tmpCfg, ($cfg | ConvertTo-Json -Depth 64))
                    Move-Item -LiteralPath $tmpCfg -Destination $configPath -Force -ErrorAction Stop
                    $cfgState = 'updated'
                }
            }
        } catch {
            Log "warning: config mirror skipped ($($_.Exception.Message))"
            $cfgState = 'error'
        }
    }
}

Log "v$ToolVersion run: $(@($roots).Count) root(s), $(@($targets).Count) workspace(s) ($($sourceSet.Count) with chats), $contestedCount contested, $copies copied, $skipped skipped, $deleted deleted, cfg $cfgState"
$tail = Get-Content $logF -Tail 1000 -ErrorAction SilentlyContinue
if ($tail) { Set-Content -Path $logF -Value $tail -ErrorAction SilentlyContinue }

} finally { [void]$mutex.ReleaseMutex(); $mutex.Dispose() }
