# Bidirectional Claude Code chat-list sync across Claude desktop accounts on this
# machine. See README.md for the full design rationale.
#
# Design invariants:
#  - one sync target per device-id (account): its single workspace folder. A device
#    with MULTIPLE chat-bearing workspaces is skipped (no safe pairing); when BOTH
#    data roots hold accounts (mid app migration) only the most recently active
#    root is synced, with ties resolved toward the migration target.
#  - a fresh account's empty workspace is seeded. A workspace that HELD chats and
#    is suddenly empty is FROZEN: recorded in frozen.txt (which survives both the
#    manifest window and uninstall), excluded from seeding and deletion evidence,
#    but it does NOT stop the rest of the run. It thaws automatically when chats
#    appear in it again, or explicitly via -Unfreeze <key>.
#  - three-state health (healthy / damaged / unknown); health beats timestamps.
#  - writes are atomic (temp sibling, verify, rename); all temp files share the
#    .cs-tmp- infix so the startup sweep can reclaim any orphan.
#  - deletions propagate via a timestamped manifest (stale or future-dated ones
#    are discarded, never trusted). Partially-failed deletions stay listed as
#    pending so the next run retries instead of reseeding. Stash entries are
#    stamped with the STASH time, so retention means what the README says.
#  - sidebar groups live in the app's Local Storage (a LevelDB the app holds
#    open while it runs). They are merged three-way against the last synced
#    result by group-sync\group-sync.mjs, which opens that database with a real
#    LevelDB implementation, only while the app is closed (its own lock refuses
#    us otherwise, reported as "deferred", never as success), backup-first, and
#    then mirrors the result into claude_desktop_config.json the way the app
#    itself does. Without Node.js the group stage is off and everything else runs.
#  - a process whose view of %LOCALAPPDATA% is an MSIX shadow (one launched from
#    inside the desktop app) refuses to run: its state directory would be a
#    copy nobody else reads, and its log would look dead from everywhere else.
#  - a lock file serializes concurrent runs; persistent failure states escalate
#    to marker files that -Status surfaces.
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$Quiet,
    [switch]$Status,
    [string]$Restore,             # stash filename fragment to restore everywhere ('list' shows the stash)
    [string]$Unfreeze,            # scope key (device/workspace) to thaw
    [string[]]$RootsOverride,     # unsupported test hook: fixture tree
    [string]$ConfigPathOverride,  # unsupported test hook: fixture config
    [string]$StateDirOverride,    # unsupported test hook: keep state out of the repo
    [string]$LevelDbPathOverride, # unsupported test hook: fixture Local Storage (skips the app-running pre-check)
    [string]$GroupHelperOverride, # unsupported test hook: helper directory
    [string]$PackagesRootOverride # unsupported test hook: MSIX packages root for the shadow probe
)
$ErrorActionPreference = 'Continue'
$ToolVersion = '0.7.0'
$ManifestMaxAgeDays = 7
$StashRetentionDays = 30
. "$PSScriptRoot\common.ps1"

$roots = if ($RootsOverride) { @($RootsOverride | Where-Object { Test-Path $_ }) } else {
    @(
        (Join-Path $env:APPDATA 'Claude\claude-code-sessions'),
        (Join-Path $env:LOCALAPPDATA 'Claude-3p\claude-code-sessions')
    ) | Where-Object { Test-Path $_ }
}
$configPath = if ($ConfigPathOverride) { $ConfigPathOverride } else { Join-Path $env:APPDATA 'Claude\claude_desktop_config.json' }
$leveldbPath = if ($LevelDbPathOverride) { $LevelDbPathOverride } else { $ClaudeLocalStorageDir }
$helperDir = if ($GroupHelperOverride) { $GroupHelperOverride } else { Join-Path $PSScriptRoot 'group-sync' }
$packagesRoot = if ($PackagesRootOverride) { $PackagesRootOverride } else { Join-Path $env:LOCALAPPDATA 'Packages' }
# State always lives in the per-user install dir, never next to whichever copy of
# the script happened to run: a git-clone test run must not write logs, manifests
# or config backups (which can carry MCP secrets) into a tree someone might push.
$stateDir = if ($StateDirOverride) { $StateDirOverride } else { Join-Path $env:LOCALAPPDATA 'ClaudeChatSync' }
# .NET on purpose: the state dir is infrastructure, not a previewable operation,
# so it must exist even under -WhatIf (the lock file lives in it).
[System.IO.Directory]::CreateDirectory($stateDir) | Out-Null

$logF        = Join-Path $stateDir 'sync-log.txt'
$manifestF   = Join-Path $stateDir 'sync-fullset.txt'
$deletedD    = Join-Path $stateDir 'deleted'
$frozenF     = Join-Path $stateDir 'frozen.txt'
$brokenF     = Join-Path $stateDir 'GROUP-SYNC-BROKEN.txt'
$lockStuckF  = Join-Path $stateDir 'SYNC-LOCK-STUCK.txt'
$grpErrCntF  = Join-Path $stateDir 'groups-error-count.txt'
$lockCntF    = Join-Path $stateDir 'lock-skip-count.txt'
$groupsBaseF = Join-Path $stateDir 'groups-base.json'

function Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg"
    Add-Content -Path $logF -Value $line -ErrorAction SilentlyContinue
    if (-not $Quiet) { Write-Host $line }
}

# A shadowed process must not run: everything it wrote would land in a mirror
# only processes launched the same way can see. -Status still reports, in red.
$shadowDir = Get-ShadowDir $stateDir $packagesRoot
if ($shadowDir -and -not $Status) {
    Write-Host "refused: this process sees an MSIX shadow of $stateDir (at $shadowDir)." -ForegroundColor Red
    Write-Host 'It was launched from inside the Claude desktop app. Run the sync from a normal terminal, or let the scheduled task run it.'
    exit 2
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

function Get-NewestActivity($wsPath) {
    $n = Get-ChildItem -Path $wsPath -Filter 'local_*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if ($n) { $n.LastWriteTimeUtc } else { [datetime]::MinValue }
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
# abandoning repopulates it forever. Iterate in declared order with >= so a tie
# resolves toward the LAST declared root (the migration target).
$activeRoot = $null
$rootsWithTargets = @($roots | Where-Object { $targetsByRoot.ContainsKey($_) })
if ($rootsWithTargets.Count -gt 1) {
    $best = $null
    foreach ($r in $rootsWithTargets) {
        $stamp = ($targetsByRoot[$r] | ForEach-Object { Get-NewestActivity $_.FullName } | Sort-Object -Descending | Select-Object -First 1)
        if (-not $best -or $stamp -ge $best.stamp) { $best = @{ root = $r; stamp = $stamp } }
    }
    $activeRoot = $best.root
    Log "warning: multiple data roots hold accounts; syncing only the most recently active ($activeRoot)"
} elseif ($rootsWithTargets.Count -eq 1) {
    $activeRoot = $rootsWithTargets[0]
}
$allTargets = if ($activeRoot) { @($targetsByRoot[$activeRoot]) } else { @() }

function Get-ScopeKey($ws) { (Split-Path (Split-Path $ws.FullName -Parent) -Leaf) + '/' + $ws.Name }

$sourceSet = @{}
foreach ($t in $allTargets) {
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
        # Reject FUTURE-dated headers too (clock rollback): trusting an arbitrarily
        # old manifest is exactly what the window exists to prevent.
        if ($age -ne $null -and $age.TotalDays -le $ManifestMaxAgeDays -and $age.TotalHours -ge -1) {
            $stale = $false
            foreach ($l in ($lines | Select-Object -Skip 1)) { if ($l) { $prevFull[$l] = $true } }
            if ($Matches[2]) { foreach ($k in ($Matches[2] -split ';')) { if ($k) { $prevSources[$k] = $true } } }
        }
    }
    if ($stale) { Log 'manifest missing header, stale, or future-dated; rebuilding (no deletions this run)' }
}

# ── Freeze: a persistent per-workspace role, not a list membership ───────────
# frozen.txt outlives the manifest window AND uninstall; a frozen workspace is
# excluded from seeding and deletion evidence but the run proceeds without it.
$frozenSet = @{}
if (Test-Path $frozenF) { foreach ($l in @(Get-Content $frozenF -ErrorAction SilentlyContinue)) { if ($l) { $frozenSet[$l] = $true } } }
if ($Unfreeze) {
    if ($frozenSet.ContainsKey($Unfreeze)) {
        $frozenSet.Remove($Unfreeze)
        Set-Content -Path $frozenF -Value @($frozenSet.Keys)
        Write-Host "thawed $Unfreeze; it will be seeded on the next run."
    } else { Write-Host "'$Unfreeze' is not frozen. Frozen keys: $(@($frozenSet.Keys) -join ', ')" }
    exit 0
}
$frozenChanged = $false
$thawedNow = @{}
foreach ($t in $allTargets) {
    $key = Get-ScopeKey $t
    if ($frozenSet.ContainsKey($key) -and $sourceSet[$t.FullName]) {
        $frozenSet.Remove($key); $frozenChanged = $true      # chats are back: thaw
        $thawedNow[$key] = $true
        Log "workspace $key has chats again; thawed (reseeding; its pre-freeze clear-out is NOT applied as deletions)"
    } elseif ((-not $frozenSet.ContainsKey($key)) -and $prevSources.ContainsKey($key) -and -not $sourceSet[$t.FullName]) {
        $frozenSet[$key] = $true; $frozenChanged = $true
        Log "warning: workspace $key held chats last run and is now empty; FROZEN (no reseed, no deletion evidence). Thaw with -Unfreeze '$key'."
    }
}
if ($frozenChanged) { Set-Content -Path $frozenF -Value @($frozenSet.Keys) -ErrorAction SilentlyContinue }
$activeTargets = @($allTargets | Where-Object { -not $frozenSet.ContainsKey((Get-ScopeKey $_)) })
$frozen = $frozenSet.Count

if ($Status) {
    Write-Host "claude-desktop-session-sync v$ToolVersion"
    if ($shadowDir) {
        Write-Host "ATTENTION: this process sees an MSIX shadow of $stateDir (at $shadowDir); the log and state shown below are that shadow, not what the scheduled task writes. Run -Status from a normal terminal." -ForegroundColor Red
    }
    Write-Host "roots found:      $(@($roots).Count) (active: $activeRoot)"
    Write-Host "sync targets:     $(@($activeTargets).Count) active workspace(s), $($sourceSet.Count) with chats, $skippedDevices device(s) skipped"
    if ($frozen -gt 0) { Write-Host "frozen:           $(@($frozenSet.Keys) -join ', ')  (thaw with -Unfreeze)" -ForegroundColor Yellow }
    Write-Host "manifest:         $($prevFull.Count) fully-synced chat(s) tracked"
    $hs = Get-GroupHelperState $helperDir
    if ($hs.ok) {
        $appNote = if (Test-ClaudeAppRunning) { 'the app is running, so groups sync on the first run after it closes' } else { 'app closed' }
        $baseNote = if (Test-Path $groupsBaseF) { "base $(([System.IO.File]::GetLastWriteTime($groupsBaseF)).ToString('yyyy-MM-dd HH:mm'))" } else { 'no base yet' }
        Write-Host "group sync:       on ($appNote; $baseNote)"
    } else {
        Write-Host "group sync:       off ($($hs.reason))" -ForegroundColor Yellow
    }
    Write-Host "log:              $logF"
    foreach ($marker in @($brokenF, $lockStuckF)) {
        if (Test-Path $marker) { Write-Host "ATTENTION: $(Split-Path $marker -Leaf) exists; see $marker" -ForegroundColor Red }
    }
    Write-Host 'last log lines:'
    Get-Content $logF -Tail 3 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $_" }
    exit 0
}

# ── Cross-session lock file. Typed catch: a sharing violation means another run
#    holds it (count and escalate); anything else is a real error, not "busy".
$lock = $null
try {
    $lock = [System.IO.File]::Open((Join-Path $stateDir 'sync.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    Set-Content -Path $lockCntF -Value '0' -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $lockStuckF -Force -ErrorAction SilentlyContinue
} catch [System.IO.IOException] {
    $n = 0; try { $n = [int](Get-Content $lockCntF -ErrorAction SilentlyContinue) } catch { }
    $n++
    Set-Content -Path $lockCntF -Value $n -ErrorAction SilentlyContinue
    if ($n -ge 12) {
        Set-Content -Path $lockStuckF -Value "Sync has been blocked by the lock for $n consecutive runs (~$([int]($n*5/60))h). Check for a stuck powershell.exe, or reboot; if it persists, delete sync.lock while no sync process is running." -ErrorAction SilentlyContinue
    }
    Log "skipped: another sync is already running (consecutive: $n)"
    exit 0
} catch {
    Log "skipped: could not acquire the lock ($($_.Exception.Message))"
    exit 1
}
try {

foreach ($t in $allTargets) {
    Get-ChildItem -Path $t.FullName -Filter '*.cs-tmp-*' -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}
foreach ($d in @((Split-Path $configPath -Parent), $stateDir)) {
    if (Test-Path $d) {
        Get-ChildItem -Path $d -Filter '*.cs-tmp-*' -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
}
# A Local Storage snapshot the helper took and never promoted (killed mid-run).
Get-ChildItem -Path $stateDir -Filter 'leveldb-backup-*.tmp' -Directory -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
# Stash retention keys on the file's write time, which the stash write STAMPS
# (Copy-Item would otherwise inherit the chat's own last-edit time, silently
# gutting retention for any chat older than the window).
if (Test-Path $deletedD) {
    Get-ChildItem -Path $deletedD -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -lt (Get-Date).ToUniversalTime().AddDays(-$StashRetentionDays) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

# ── -Restore: copy a stashed deletion back into every active workspace ───────
if ($Restore) {
    $entries = @(Get-ChildItem -Path $deletedD -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)
    $frag = [System.Management.Automation.WildcardPattern]::Escape($Restore)
    $hit = $entries | Where-Object { $_.Name -like "*$frag*" } | Select-Object -First 1
    if ($Restore -eq 'list' -or -not $hit) {
        if ($Restore -ne 'list') { Write-Host "no stash entry matches '$Restore'." }
        if ($entries.Count -eq 0) { Write-Host 'the stash is empty.' } else {
            Write-Host "stash ($($entries.Count) entr$(if ($entries.Count -eq 1) { 'y' } else { 'ies' }), newest first):"
            $entries | ForEach-Object { Write-Host ("  {0}  {1,8:N0} bytes" -f $_.Name, $_.Length) }
        }
        exit $(if ($Restore -eq 'list') { 0 } else { 1 })
    }
    if ($hit.Name -notmatch '(local_.+\.json)$') { Write-Host "stash entry '$($hit.Name)' has an unexpected name; not restoring."; exit 1 }
    $chatName = $Matches[1]
    $ok = 0
    foreach ($ws in $activeTargets) {
        if ($PSCmdlet.ShouldProcess((Join-Path $ws.FullName $chatName), "restore from $($hit.Name)")) {
            try { Copy-Item -LiteralPath $hit.FullName -Destination (Join-Path $ws.FullName $chatName) -Force -ErrorAction Stop; $ok++ }
            catch { Log "warning: restore into $($ws.FullName) failed: $($_.Exception.Message)" }
        }
    }
    if ($ok -eq @($activeTargets).Count -and $ok -gt 0) {
        Log "restored $chatName to all $ok workspace(s) from stash"
        Write-Host "restored $chatName to all $ok workspace(s). It will re-enter the manifest on the next run."
    } else {
        Write-Host "restored $chatName to $ok of $(@($activeTargets).Count) workspace(s). Close the Claude app and re-run: a pending deletion can undo a partial restore."
        exit 1
    }
    exit 0
}

$copies = 0; $skipped = 0; $contestedCount = 0; $deleted = 0; $groupsState = 'skipped'
$failedDeletes = @{}

if (@($activeTargets).Count -ge 2 -and $sourceSet.Count -ge 1) {

    $byName = @{}
    foreach ($ws in $activeTargets) {
        foreach ($f in Get-ChildItem -Path $ws.FullName -Filter 'local_*.json' -File -ErrorAction SilentlyContinue) {
            if (-not $byName.ContainsKey($f.Name)) { $byName[$f.Name] = @() }
            $byName[$f.Name] += $f
        }
    }

    # ── Deletion propagation ─────────────────────────────────────────────────
    foreach ($name in @($prevFull.Keys)) {
        if (-not $byName.ContainsKey($name)) { continue }
        $havers = @($byName[$name])
        if ($havers.Count -eq @($activeTargets).Count) { continue }
        $haverDirs = @{}
        foreach ($h in $havers) { $haverDirs[$h.DirectoryName] = $true }
        # A workspace that thawed THIS run is a seed target, not deletion evidence:
        # applying its pre-freeze clear-out retroactively would be the mass delete
        # the freeze exists to prevent.
        $evidence = @($activeTargets | Where-Object { (-not $haverDirs[$_.FullName]) -and $sourceSet[$_.FullName] -and -not $thawedNow.ContainsKey((Get-ScopeKey $_)) })
        if ($evidence.Count -lt 1) { continue }
        if (-not $PSCmdlet.ShouldProcess($name, 'propagate deletion')) { continue }
        try {
            New-Item -ItemType Directory -Force -Path $deletedD | Out-Null
            # Stash the best copy (healthiest, then newest), named with its device
            # id, and STAMPED with the stash time so retention starts now.
            $ordered = @($havers | Sort-Object @{E = { (Get-HealthRaw $_.FullName) -eq 'healthy' }; Descending = $true}, @{E = 'LastWriteTimeUtc'; Descending = $true})
            $deviceId = Split-Path (Split-Path $ordered[0].DirectoryName -Parent) -Leaf
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $stashPath = Join-Path $deletedD "$stamp-$deviceId-$name"
            Copy-Item -LiteralPath $ordered[0].FullName -Destination $stashPath -Force -ErrorAction Stop
            [System.IO.File]::SetLastWriteTimeUtc($stashPath, (Get-Date).ToUniversalTime())
            foreach ($h in $havers) { Remove-Item -LiteralPath $h.FullName -Force -ErrorAction Stop }
            $byName.Remove($name)
            $deleted++
        } catch {
            $failedDeletes[$name] = $true
            Log "warning: deletion of $name incomplete (a copy is in use); retrying next run"
        }
    }

    # ── Copy propagation (newest-healthy-wins, atomic) ───────────────────────
    $healthCache = @{}
    function Get-HealthCached($item) {
        $k = $item.FullName + '|' + $item.LastWriteTimeUtc.Ticks + '|' + $item.Length
        if (-not $healthCache.ContainsKey($k)) { $healthCache[$k] = Get-HealthRaw $item.FullName }
        $healthCache[$k]
    }
    foreach ($name in $byName.Keys) {
        if ($failedDeletes.ContainsKey($name)) { continue }
        $all = @($byName[$name] | Sort-Object LastWriteTimeUtc -Descending)

        # Fast path requires size agreement too: app damage changes the length,
        # and health must beat timestamps even inside the 2s tolerance.
        $spread = ($all[0].LastWriteTimeUtc - $all[-1].LastWriteTimeUtc).TotalSeconds
        $sameSize = (@($all | Select-Object -ExpandProperty Length -Unique).Count -eq 1)
        if ($all.Count -eq @($activeTargets).Count -and $spread -le 2 -and $sameSize) { continue }
        $contestedCount++

        $winner = $null; $winnerHealth = $null
        foreach ($state in 'healthy', 'damaged') {
            foreach ($c in $all) {
                if ((Get-HealthCached $c) -eq $state) { $winner = $c; $winnerHealth = $state; break }
            }
            if ($winner) { break }
        }
        if (-not $winner) { $skipped++; continue }

        foreach ($ws in $activeTargets) {
            if ($winner.DirectoryName -eq $ws.FullName) { continue }
            $dst = Join-Path $ws.FullName $name
            $dstItem = Get-Item -LiteralPath $dst -ErrorAction SilentlyContinue

            # Precedence: health beats timestamps; then newest wins (2s tolerance);
            # a damaged winner may replace a provably damaged destination, and may
            # SEED an absent one (a damaged copy of the chat beats no chat at all).
            if ($dstItem) {
                $winnerNewer = ($winner.LastWriteTimeUtc - $dstItem.LastWriteTimeUtc).TotalSeconds -gt 2
                $dstHealth = Get-HealthCached $dstItem
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

    # ── Manifest rewrite (pending deletions stay listed; see invariants) ─────
    if (-not $WhatIfPreference) {
        $fullNow = foreach ($name in $byName.Keys) {
            if ($failedDeletes.ContainsKey($name)) { continue }
            $everywhere = $true
            foreach ($ws in $activeTargets) {
                if (-not (Test-Path -LiteralPath (Join-Path $ws.FullName $name))) { $everywhere = $false; break }
            }
            if ($everywhere) { $name }
        }
        $fullList = @($fullNow) + @($failedDeletes.Keys)
        $srcKeys = (@($activeTargets | Where-Object { $sourceSet[$_.FullName] } | ForEach-Object { Get-ScopeKey $_ }) -join ';')
        $header = "#v1 $((Get-Date).ToUniversalTime().ToString('o')) sources=$srcKeys"
        $tmpMan = "$manifestF.cs-tmp-$PID"
        try {
            Set-Content -Path $tmpMan -Value (@($header) + @($fullList | Sort-Object)) -ErrorAction Stop
            Move-Item -LiteralPath $tmpMan -Destination $manifestF -Force -ErrorAction Stop
        } catch {
            Remove-Item -LiteralPath $tmpMan -Force -ErrorAction SilentlyContinue
            Log "warning: manifest write failed ($($_.Exception.Message))"
        }
    }

    # ── Sidebar groups: three-way merge in Local Storage, app closed only ────
    # The helper owns the merge, the backups and the config mirror; this side
    # decides whether it may run at all and turns its answer into state.
    $groupsState = 'off'
    $hs = Get-GroupHelperState $helperDir
    if (-not $hs.ok) {
        $groupsState = 'off'
    } elseif ($RootsOverride -and -not $LevelDbPathOverride) {
        # A fixture tree never pairs with the real Local Storage: its scope keys
        # would be merged into the app's database as new accounts.
        $groupsState = 'off'
    } elseif (-not (Test-Path -LiteralPath $leveldbPath)) {
        $groupsState = 'off'
        Log "warning: Local Storage not found at $leveldbPath; group sync off"
    } elseif ((-not $LevelDbPathOverride) -and (Test-ClaudeAppRunning)) {
        # Cheap pre-check. The authoritative refusal is the app's own LevelDB lock
        # inside the helper; this only avoids taking a snapshot for nothing.
        $groupsState = 'deferred'
    } else {
        $scopeKeys = (@($allTargets | ForEach-Object { Get-ScopeKey $_ }) -join ';')
        $helperArgs = @('--leveldb', $leveldbPath, '--state', $stateDir, '--scopes', $scopeKeys)
        # The mirror gets the real config only on a real run: a fixture tree's
        # scopes must never be written into the app's config.
        $mirrorConfig = (Test-Path -LiteralPath $configPath) -and -not ($RootsOverride -and -not $ConfigPathOverride)
        if ($mirrorConfig) { $helperArgs += @('--config', $configPath) }
        if ($WhatIfPreference) { $helperArgs += '--dry-run' }
        $raw = ''
        try {
            $raw = (& $hs.node $hs.script @helperArgs 2>&1 | Out-String)
            $code = $LASTEXITCODE
        } catch { $raw = $_.Exception.Message; $code = 1 }
        $res = $null
        $jsonLine = @($raw -split "`r?`n" | Where-Object { $_.TrimStart().StartsWith('{') }) | Select-Object -Last 1
        if ($jsonLine) { try { $res = $jsonLine | ConvertFrom-Json } catch { } }
        if (-not $res) {
            $groupsState = 'error'
            Log "warning: group helper produced no result (exit $code): $($raw.Trim())"
        } else {
            foreach ($w in @($res.warnings)) { if ($w) { Log "warning: groups: $w" } }
            switch ($res.status) {
                'updated'      { $groupsState = 'updated'; Log "groups merged into $(@($res.scopesRewritten).Count) scope(s): +$(@($res.changes.groupsAdded).Count) -$(@($res.changes.groupsRemoved).Count) ~$(@($res.changes.groupsChanged).Count) group(s), $(@($res.changes.groupsWithheld).Count) withheld, $($res.changes.assignmentsChanged) assignment(s); publish $($res.publish.marker) for $($res.publish.owner); backup $($res.backupDir); config $($res.configState)" }
                'would-update' { $groupsState = 'would-update'; Log "groups would be merged into $(@($res.scopesRewritten).Count) scope(s) (-WhatIf)" }
                'unchanged'    { $groupsState = if ($res.configState -eq 'updated') { 'mirrored' } else { 'unchanged' } }
                'deferred'     { $groupsState = 'deferred' }
                default        { $groupsState = 'error'; Log "warning: group sync failed: $($res.reason)" }
            }
        }
        if ($groupsState -eq 'error') {
            $n = 0; try { $n = [int](Get-Content $grpErrCntF -ErrorAction SilentlyContinue) } catch { }
            $n++
            Set-Content -Path $grpErrCntF -Value $n -ErrorAction SilentlyContinue
            if ($n -ge 3) {
                Set-Content -Path $brokenF -Value "Group sync has failed $n consecutive runs.`nLast output: $($raw.Trim())`nAt: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ErrorAction SilentlyContinue
            }
        } elseif ($groupsState -ne 'deferred') {
            Set-Content -Path $grpErrCntF -Value '0' -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $brokenF -Force -ErrorAction SilentlyContinue
        }
    }
}

Log "v$ToolVersion run: $(@($roots).Count) root(s), $(@($activeTargets).Count) workspace(s) ($($sourceSet.Count) with chats, $frozen frozen), $contestedCount contested, $copies copied, $skipped skipped, $deleted deleted, groups $groupsState"
$tail = Get-Content $logF -Tail 1000 -ErrorAction SilentlyContinue
if ($tail) {
    $tmpLog = "$logF.cs-tmp-$PID"
    try {
        Set-Content -Path $tmpLog -Value $tail -ErrorAction Stop
        Move-Item -LiteralPath $tmpLog -Destination $logF -Force -ErrorAction Stop
    } catch { Remove-Item -LiteralPath $tmpLog -Force -ErrorAction SilentlyContinue }
}

} finally { if ($lock) { $lock.Dispose() } }
