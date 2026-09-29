# Scheduled-task merge for the engine. Dot-source: . "$PSScriptRoot\task-sync.ps1"
#
# The desktop app keeps one scheduled-tasks.json per scope
# (claude-code-sessions\<account>\<org>\scheduled-tasks.json); the prompts live
# account-independently in %USERPROFILE%\.claude\scheduled-tasks\<id>\SKILL.md.
# These tasks can push to production, so the one property this file exists to
# keep is: a task never fires twice because it is listed in two accounts.
#
# What the app does with the file (read from its bundle, build 1.46388.x):
#  - a one-time task (fireAt) is due while enabled, fireAt <= now and lastRunAt
#    is ABSENT. A run writes lastRunAt/lastScheduledFor and then auto-disables
#    it. Changing fireAt clears lastRunAt, lastScheduledFor, missedRunScanFloor.
#    A manual run before fireAt does not consume it and writes nothing.
#  - a recurring task (cronExpression) catches up the newest missed slot within
#    7 days after max(lastScheduledFor ?? lastRunAt ?? createdAt,
#    missedRunScanFloor); a run stamps lastRunAt/lastScheduledFor.
#  - recordedSkips (id -> [{at, reason}], pruned to 7 days) is display history
#    of dispatches the app skipped; runRetries (id -> {slot, attempts,
#    notBefore}) is a retry cycle IN FLIGHT in that account.
#  - sundayAliasBoundaryStamped / dayFieldsOrBoundaryStamped are one-shot
#    migration markers: while one is missing the app stamps lastScheduledFor on
#    matching cron tasks at load, so a cron-matcher upgrade cannot back-fill a
#    run. The stamp only ever suppresses runs.
#  - completing a move to a cloud routine disables the local copy and records
#    migratedToRemote {triggerId, via}; a revert records revertedAt.
#
# PowerShell 5.1 compatible and dependency-free. JSON is parsed and written by
# the small reader/writer below rather than ConvertFrom-Json: PowerShell 7 turns
# ISO-8601 strings (lastRunAt) into DateTime objects, and 5.1 and 7 format
# numbers and non-ASCII differently; this file must round-trip byte-stably.

$script:TaskRunStateKeys = @('lastRunAt', 'lastScheduledFor', 'missedRunScanFloor')
$script:TaskSkipRetentionMs = 7 * 24 * 3600 * 1000
$script:TaskTombstoneRetentionMs = 90 * 24 * 3600 * 1000

# -- JSON reader: objects -> OrderedDictionary (ordinal keys), arrays -> ArrayList
$script:JNum = [regex]'\G-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?'
$script:JStr = [regex]'\G"((?:[^"\\\u0000-\u001F]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*)"'
$script:JWs  = [regex]'\G[ \t\r\n]*'
$script:JEsc = [regex]'\\(?:(["\\/])|([bfnrt])|u([0-9a-fA-F]{4}))'

function New-OrdinalDict { [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal) }

function ConvertFrom-TaskJson([string]$Text) {
    $st = @{ s = $Text; i = 0 }
    $v = Read-JValue $st
    Skip-JWs $st
    if ($st.i -ne $st.s.Length) { throw "json: trailing content at $($st.i)" }
    return ,$v
}

function Skip-JWs($st) { $m = $script:JWs.Match($st.s, $st.i); $st.i += $m.Length }

function Read-JString($st) {
    $m = $script:JStr.Match($st.s, $st.i)
    if (-not $m.Success) { throw "json: bad string at $($st.i)" }
    $st.i += $m.Length
    $raw = $m.Groups[1].Value
    if ($raw.IndexOf([char]'\') -lt 0) { return $raw }
    $script:JEsc.Replace($raw, [System.Text.RegularExpressions.MatchEvaluator] {
        param($e)
        if ($e.Groups[1].Success) { return $e.Groups[1].Value }
        if ($e.Groups[2].Success) {
            switch -CaseSensitive ($e.Groups[2].Value) { 'b' { return [string][char]8 } 'f' { return [string][char]12 } 'n' { return "`n" } 'r' { return "`r" } 't' { return "`t" } }
        }
        return [string][char][Convert]::ToInt32($e.Groups[3].Value, 16)
    })
}

function Read-JValue($st) {
    Skip-JWs $st
    if ($st.i -ge $st.s.Length) { throw 'json: unexpected end' }
    $c = $st.s[$st.i]
    if ($c -eq [char]'{') {
        $st.i++
        $o = New-OrdinalDict
        Skip-JWs $st
        if ($st.s[$st.i] -eq [char]'}') { $st.i++; return ,$o }
        while ($true) {
            Skip-JWs $st
            $k = Read-JString $st
            Skip-JWs $st
            if ($st.s[$st.i] -ne [char]':') { throw "json: expected : at $($st.i)" }
            $st.i++
            $o[$k] = Read-JValue $st
            Skip-JWs $st
            $d = $st.s[$st.i]; $st.i++
            if ($d -eq [char]'}') { return ,$o }
            if ($d -ne [char]',') { throw "json: expected , or } at $($st.i - 1)" }
        }
    }
    if ($c -eq [char]'[') {
        $st.i++
        $a = New-Object System.Collections.ArrayList
        Skip-JWs $st
        if ($st.s[$st.i] -eq [char]']') { $st.i++; return ,$a }
        while ($true) {
            [void]$a.Add((Read-JValue $st))
            Skip-JWs $st
            $d = $st.s[$st.i]; $st.i++
            if ($d -eq [char]']') { return ,$a }
            if ($d -ne [char]',') { throw "json: expected , or ] at $($st.i - 1)" }
        }
    }
    if ($c -eq [char]'"') { return (Read-JString $st) }
    if ([string]::CompareOrdinal($st.s, $st.i, 'true', 0, 4) -eq 0)  { $st.i += 4; return $true }
    if ([string]::CompareOrdinal($st.s, $st.i, 'false', 0, 5) -eq 0) { $st.i += 5; return $false }
    if ([string]::CompareOrdinal($st.s, $st.i, 'null', 0, 4) -eq 0)  { $st.i += 4; return $null }
    $m = $script:JNum.Match($st.s, $st.i)
    if (-not $m.Success -or $m.Length -eq 0) { throw "json: unexpected character at $($st.i)" }
    $st.i += $m.Length
    $t = $m.Value
    $l = 0L
    if ($t.IndexOfAny([char[]]'.eE') -lt 0 -and [long]::TryParse($t, [System.Globalization.NumberStyles]::AllowLeadingSign, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$l)) { return $l }
    return [double]::Parse($t, [System.Globalization.CultureInfo]::InvariantCulture)
}

# -- JSON writer. -Canonical: compact with ordinally sorted keys, for comparing.
function ConvertTo-TaskJson($Value, [switch]$Canonical) {
    $sb = New-Object System.Text.StringBuilder
    Write-JValue $sb $Value $Canonical.IsPresent 0
    $sb.ToString()
}

function Write-JString($sb, [string]$s) {
    [void]$sb.Append('"')
    foreach ($ch in $s.ToCharArray()) {
        $n = [int]$ch
        if ($ch -eq [char]'"') { [void]$sb.Append('\"') }
        elseif ($ch -eq [char]'\') { [void]$sb.Append('\\') }
        elseif ($n -lt 0x20) {
            switch ($n) { 8 { [void]$sb.Append('\b') } 9 { [void]$sb.Append('\t') } 10 { [void]$sb.Append('\n') } 12 { [void]$sb.Append('\f') } 13 { [void]$sb.Append('\r') } default { [void]$sb.Append('\u' + $n.ToString('x4', [System.Globalization.CultureInfo]::InvariantCulture)) } }
        }
        else { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
}

function Write-JValue($sb, $v, [bool]$canon, [int]$depth) {
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    if ($null -eq $v) { [void]$sb.Append('null'); return }
    if ($v -is [bool]) { [void]$sb.Append($(if ($v) { 'true' } else { 'false' })); return }
    if ($v -is [string]) { Write-JString $sb $v; return }
    if ($v -is [long] -or $v -is [int]) { [void]$sb.Append(([long]$v).ToString($inv)); return }
    if ($v -is [double]) { [void]$sb.Append($v.ToString('R', $inv)); return }
    $pad = if ($canon) { '' } else { "`n" + ('  ' * ($depth + 1)) }
    $end = if ($canon) { '' } else { "`n" + ('  ' * $depth) }
    if ($v -is [System.Collections.IDictionary]) {
        $keys = @($v.Keys | ForEach-Object { [string]$_ })
        if ($canon) { [Array]::Sort($keys, [System.StringComparer]::Ordinal) }
        if ($keys.Count -eq 0) { [void]$sb.Append('{}'); return }
        [void]$sb.Append('{')
        for ($i = 0; $i -lt $keys.Count; $i++) {
            if ($i -gt 0) { [void]$sb.Append(',') }
            [void]$sb.Append($pad)
            Write-JString $sb $keys[$i]
            [void]$sb.Append($(if ($canon) { ':' } else { ': ' }))
            Write-JValue $sb $v[$keys[$i]] $canon ($depth + 1)
        }
        [void]$sb.Append($end + '}')
        return
    }
    if ($v -is [System.Collections.IEnumerable]) {
        $items = @($v)
        if ($items.Count -eq 0) { [void]$sb.Append('[]'); return }
        [void]$sb.Append('[')
        for ($i = 0; $i -lt $items.Count; $i++) {
            if ($i -gt 0) { [void]$sb.Append(',') }
            [void]$sb.Append($pad)
            Write-JValue $sb $items[$i] $canon ($depth + 1)
        }
        [void]$sb.Append($end + ']')
        return
    }
    if ($v -is [decimal] -or $v -is [single]) { [void]$sb.Append(([double]$v).ToString('R', $inv)); return }
    Write-JString $sb ([string]$v)
}

function Get-Canon($v) { ConvertTo-TaskJson $v -Canonical }
function Copy-JValue($v) { if ($null -eq $v) { return $null }; return ,(ConvertFrom-TaskJson (ConvertTo-TaskJson $v -Canonical)) }
function Test-CanonEqual($a, $b) { [string]::Equals((Get-Canon $a), (Get-Canon $b), [System.StringComparison]::Ordinal) }

# An ISO timestamp as epoch ms, or $null when absent or unparseable.
function Get-IsoMs($s) {
    if (-not ($s -is [string]) -or -not $s) { return $null }
    $d = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($s, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$d)) { return $d.ToUnixTimeMilliseconds() }
    return $null
}
function Get-NumMs($v) { if ($v -is [long] -or $v -is [int] -or $v -is [double]) { return [double]$v }; return $null }

function Get-Field($task, [string]$key) { if ($task -and $task.Contains($key)) { return @{ has = $true; value = $task[$key] } }; return @{ has = $false; value = $null } }
function Get-FieldCanon($task, [string]$key) { if ($task -and $task.Contains($key)) { return (Get-Canon $task[$key]) }; return '<absent>' }

function Test-OneTimeTask($t) { return ($t.Contains('fireAt') -and $null -ne $t['fireAt'] -and -not ($t.Contains('cronExpression') -and $t['cronExpression'])) }
function Test-TaskHasRun($t) { return ($t.Contains('lastRunAt') -and $t['lastRunAt']) }
function Get-ScheduleSig($t) { (Get-FieldCanon $t 'cronExpression') + '|' + (Get-FieldCanon $t 'fireAt') }

# The file's task list as an ordinal map id -> task (entries without a string id
# are the app's problem, not ours; they are passed through untouched).
function Get-TaskMap($doc) {
    $map = New-OrdinalDict
    if ($doc -and $doc.Contains('scheduledTasks')) {
        foreach ($t in @($doc['scheduledTasks'])) {
            if ($t -is [System.Collections.IDictionary] -and $t['id'] -is [string] -and -not $map.Contains($t['id'])) { $map[$t['id']] = $t }
        }
    }
    return ,$map
}

function Get-BaseMap($base, [string]$name) {
    if ($base -and $base.Contains($name) -and $base[$name] -is [System.Collections.IDictionary]) { return ,$base[$name] }
    return ,(New-OrdinalDict)
}

# First-run rank of a copy (no base knows the task): a copy that is live
# (enabled, never run, recurring or due in the future) is what the user meant.
# A disabled copy with a future fireAt and no run is someone's hold or a manual
# move, never evidence of a run, so it ranks below the live copy instead of
# overriding it. Ties go to the tie order (last-shown account first).
function Test-LiveCopy($t, [double]$nowMs) {
    if (-not ($t['enabled'] -eq $true)) { return $false }
    if (Test-TaskHasRun $t) { return $false }
    if (Test-OneTimeTask $t) { $f = Get-NumMs $t['fireAt']; return ($null -ne $f -and $f -gt $nowMs) }
    return $true
}

# The merge. $Scopes: ordered list of @{ key; doc (parsed file or $null when the
# file does not exist); writable; sessions (ordinal set of local_*.json names) }.
# $TieOrder: scope keys, winner first. Returns @{ docs (key -> new doc, only for
# writable scopes whose content changes); base; stats }.
function Merge-ScheduledTaskScopes {
    param(
        [object[]]$Scopes,
        $Base,
        [double]$NowMs,
        [string[]]$TieOrder,
        [string]$RunningScope = '',
        [string]$KnownScope = '',
        [double]$HoldLeadMs = 15 * 60 * 1000
    )
    $baseMerged = Get-BaseMap $Base 'merged'
    $bScope = Get-BaseMap $Base 'scopes'
    $tomb   = Copy-JValue (Get-BaseMap $Base 'tombstones'); if (-not $tomb) { $tomb = New-OrdinalDict }
    $claims = Get-BaseMap $Base 'claims'
    $stats  = @{ added = 0; removed = 0; changed = 0; held = 0; firedPropagated = 0 }

    $rank = @{}
    for ($i = 0; $i -lt $TieOrder.Count; $i++) { $rank[$TieOrder[$i]] = $i }
    $ordered = @($Scopes | Sort-Object { if ($rank.ContainsKey($_.key)) { $rank[$_.key] } else { 1e6 } })

    $cur = @{}; $seen = @{}
    foreach ($s in $ordered) {
        $cur[$s.key] = Get-TaskMap $s.doc
        $seen[$s.key] = if ($bScope.Contains($s.key)) { $bScope[$s.key] } else { $null }
    }

    # Id universe, first-seen order: scopes in tie order, then the base.
    $ids = New-Object System.Collections.Generic.List[string]
    $idSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($s in $ordered) { foreach ($id in $cur[$s.key].Keys) { if ($idSet.Add($id)) { $ids.Add($id) } } }
    foreach ($id in $baseMerged.Keys) { if ($idSet.Add($id)) { $ids.Add($id) } }

    $merged = New-OrdinalDict
    $deleted = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($id in $ids) {
        $mt = if ($baseMerged.Contains($id)) { $baseMerged[$id] } else { $null }

        # Deletion: a scope that held the task at the last sync and lacks it now.
        # Needs a base by construction, so the first run never deletes.
        if ($mt) {
            $gone = @($ordered | Where-Object { $seen[$_.key] -and $seen[$_.key].Contains($id) -and -not $cur[$_.key].Contains($id) })
            if ($gone.Count -gt 0) {
                $t = New-OrdinalDict; $t['at'] = [long]$NowMs; $t['createdAt'] = $mt['createdAt']
                $tomb[$id] = $t
                $mt = $null
            }
        }

        $copies = New-Object System.Collections.ArrayList
        foreach ($s in $ordered) { if ($cur[$s.key].Contains($id)) { [void]$copies.Add(@{ key = $s.key; t = $cur[$s.key][$id] }) } }
        # A tombstoned id comes back only as a genuinely new task (created after
        # the deletion's copy); older copies are stale and get removed.
        if ($tomb.Contains($id)) {
            $tc = Get-NumMs $tomb[$id]['createdAt']
            $fresh = @($copies | Where-Object { $c = Get-NumMs $_.t['createdAt']; $null -ne $c -and ($null -eq $tc -or $c -gt $tc) })
            if ($fresh.Count -gt 0) { $tomb.Remove($id); $copies = [System.Collections.ArrayList]@($fresh); $mt = $null }
            else { [void]$deleted.Add($id); continue }
        }
        # Held by nobody any more and not a detected deletion: not resurrected.
        if ($copies.Count -eq 0) { continue }

        # Field groups: the schedule moves as one unit (fireAt and cronExpression
        # are exclusive); run state is merged separately below.
        $keys = New-Object System.Collections.Generic.List[string]
        $keySet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($c in $copies) { foreach ($k in $c.t.Keys) { if ($keySet.Add($k)) { $keys.Add($k) } } }
        if ($mt) { foreach ($k in $mt.Keys) { if ($keySet.Add($k)) { $keys.Add($k) } } }
        $groups = New-Object System.Collections.ArrayList
        [void]$groups.Add(@('cronExpression', 'fireAt'))
        foreach ($k in $keys) {
            if ($k -ceq 'id' -or $k -ceq 'cronExpression' -or $k -ceq 'fireAt' -or $script:TaskRunStateKeys -ccontains $k -or $k -ceq 'observedToolUse') { continue }
            [void]$groups.Add(@($k))
        }

        $pick = @{}
        if ($mt) {
            foreach ($g in $groups) {
                $winner = $null
                foreach ($c in $copies) {
                    $b = if ($seen[$c.key] -and $seen[$c.key].Contains($id)) { $seen[$c.key][$id] } else { $null }
                    $changed = (-not $b)
                    if (-not $changed) { foreach ($k in $g) { if ((Get-FieldCanon $c.t $k) -cne (Get-FieldCanon $b $k)) { $changed = $true; break } } }
                    if ($changed) { $winner = $c.t; break }
                }
                $src = if ($winner) { $winner } else { $mt }
                foreach ($k in $g) { $pick[$k] = Get-Field $src $k }
            }
        } else {
            $primary = $null
            foreach ($c in $copies) { if (Test-LiveCopy $c.t $NowMs) { $primary = $c.t; break } }
            if (-not $primary) {
                $best = $null
                foreach ($c in $copies) { $ca = Get-NumMs $c.t['createdAt']; if (-not $best -or ($null -ne $ca -and $ca -gt $best.ca)) { $best = @{ t = $c.t; ca = $(if ($null -ne $ca) { $ca } else { -1 }) } } }
                $primary = $best.t
            }
            foreach ($g in $groups) { foreach ($k in $g) { $pick[$k] = Get-Field $primary $k } }
            # A notification target is worth keeping from any copy; it is
            # filtered per scope later, so it only lands where the chat exists.
            if (-not $pick['notifySessionId'].has) {
                foreach ($c in $copies) { if ($c.t.Contains('notifySessionId') -and $c.t['notifySessionId']) { $pick['notifySessionId'] = Get-Field $c.t 'notifySessionId'; break } }
            }
        }

        $m = New-OrdinalDict
        $m['id'] = $id
        $refKeys = New-Object System.Collections.Generic.List[string]
        foreach ($k in $copies[0].t.Keys) { $refKeys.Add($k) }
        foreach ($k in $keys) { if (-not $refKeys.Contains($k)) { $refKeys.Add($k) } }
        foreach ($k in $refKeys) {
            if ($k -ceq 'id' -or $script:TaskRunStateKeys -ccontains $k -or $k -ceq 'observedToolUse') { continue }
            if ($pick.ContainsKey($k) -and $pick[$k].has) { $m[$k] = Copy-JValue $pick[$k].value }
        }

        # Run state is monotonic within one schedule: the newest run any copy (or
        # the base) recorded for THIS fireAt/cron wins everywhere. A reschedule
        # starts clean, as it does in the app.
        $sig = Get-ScheduleSig $m
        $cands = @($copies | ForEach-Object { $_.t })
        if ($mt) { $cands += ,$mt }
        $cands = @($cands | Where-Object { (Get-ScheduleSig $_) -ceq $sig })
        foreach ($k in $script:TaskRunStateKeys) {
            $bestV = $null; $bestMs = $null
            foreach ($c in $cands) {
                if (-not $c.Contains($k)) { continue }
                $ms = Get-IsoMs $c[$k]
                if ($null -eq $ms) { if ($null -eq $bestV) { $bestV = $c[$k] }; continue }
                if ($null -eq $bestMs -or $ms -gt $bestMs) { $bestMs = $ms; $bestV = $c[$k] }
            }
            if ($null -ne $bestV) { $m[$k] = $bestV }
        }
        $obs = $null
        foreach ($c in @($copies | ForEach-Object { $_.t }) + @($(if ($mt) { ,$mt }))) {
            if ($c -and $c.Contains('observedToolUse') -and $c['observedToolUse'] -is [System.Collections.IDictionary]) {
                $r = Get-NumMs $c['observedToolUse']['runsObserved']
                if (-not $obs -or ($null -ne $r -and $r -gt $obs.r)) { $obs = @{ v = $c['observedToolUse']; r = $(if ($null -ne $r) { $r } else { -1 }) } }
            }
        }
        if ($obs) { $m['observedToolUse'] = Copy-JValue $obs.v }

        if ((Test-OneTimeTask $m) -and (Test-TaskHasRun $m)) {
            if ($m['enabled'] -eq $true) { $stats.firedPropagated++ }
            $m['enabled'] = $false
        }
        $mig = if ($m.Contains('migratedToRemote')) { $m['migratedToRemote'] } else { $null }
        if ($mig -is [System.Collections.IDictionary] -and $mig.Contains('triggerId') -and -not $mig.Contains('revertedAt')) { $m['enabled'] = $false }

        $merged[$id] = $m
    }

    # Holds: a one-time task close to (or past) its fireAt with no run yet stays
    # enabled in exactly one scope, the claimant; every other copy is written
    # disabled. That closes the window in which the account that fires it and
    # an account the app switches to next would both see it due.
    $newClaims = New-OrdinalDict
    $holds = @{}
    foreach ($id in $merged.Keys) {
        $m = $merged[$id]
        if (-not (Test-OneTimeTask $m) -or (Test-TaskHasRun $m) -or $m['enabled'] -ne $true) { continue }
        $f = Get-NumMs $m['fireAt']
        if ($null -eq $f -or $f -gt ($NowMs + $HoldLeadMs)) { continue }
        $prev = if ($claims.Contains($id) -and (Get-Canon $claims[$id]['fireAt']) -ceq (Get-Canon $m['fireAt'])) { [string]$claims[$id]['scope'] } else { '' }
        $inScope = { param($k) $k -and @($ordered | Where-Object { $_.key -ceq $k }).Count -gt 0 }
        $claimant = ''
        if ($RunningScope) {
            $rt = if ($cur.ContainsKey($RunningScope) -and $cur[$RunningScope].Contains($id)) { $cur[$RunningScope][$id] } else { $null }
            if ($rt -and $rt['enabled'] -eq $true -and -not (Test-TaskHasRun $rt)) { $claimant = $RunningScope }
            elseif (& $inScope $prev) { $claimant = $prev }
            else { $claimant = @($ordered | Where-Object { $_.writable } | Select-Object -First 1 | ForEach-Object { $_.key }) -join '' }
        } else {
            if (& $inScope $KnownScope) { $claimant = $KnownScope }
            elseif (& $inScope $prev) { $claimant = $prev }
            else { $claimant = $ordered[0].key }
        }
        $c = New-OrdinalDict; $c['scope'] = $claimant; $c['fireAt'] = $m['fireAt']
        $newClaims[$id] = $c
        $holds[$id] = $claimant
    }

    # Per-scope output. The app's own per-file state stays per file: runRetries
    # (a retry cycle in flight THERE; copying it would make a second account
    # retry the run) and the *Stamped markers (setting one the file lacks would
    # switch off the app's protective stamp for tasks we brought in).
    $skipsAll = New-OrdinalDict
    foreach ($s in $ordered) {
        if (-not $s.doc -or -not $s.doc.Contains('recordedSkips') -or -not ($s.doc['recordedSkips'] -is [System.Collections.IDictionary])) { continue }
        foreach ($id in $s.doc['recordedSkips'].Keys) {
            if (-not $skipsAll.Contains($id)) { $skipsAll[$id] = New-OrdinalDict }
            foreach ($e in @($s.doc['recordedSkips'][$id])) {
                if (-not ($e -is [System.Collections.IDictionary])) { continue }
                $at = Get-NumMs $e['at']
                if ($null -ne $at -and $at -lt ($NowMs - $script:TaskSkipRetentionMs)) { continue }
                $skipsAll[$id][(Get-Canon $e)] = $e
            }
        }
    }

    $docs = @{}
    $pending = New-Object System.Collections.Generic.List[string]
    $newSeen = New-OrdinalDict
    foreach ($s in $ordered) {
        $old = $cur[$s.key]
        $list = New-Object System.Collections.ArrayList
        $written = New-OrdinalDict
        $order = New-Object System.Collections.Generic.List[string]
        foreach ($id in $old.Keys) { if ($merged.Contains($id)) { $order.Add($id) } }
        $fresh = @($merged.Keys | Where-Object { -not $old.Contains($_) } | Sort-Object { $c = Get-NumMs $merged[$_]['createdAt']; if ($null -ne $c) { $c } else { 0 } })
        foreach ($id in $fresh) { $order.Add($id) }
        foreach ($id in $order) {
            $t = Copy-JValue $merged[$id]
            if ($holds.ContainsKey($id) -and $holds[$id] -cne $s.key) { $t['enabled'] = $false }
            if ($t.Contains('notifySessionId')) {
                $n = [string]$t['notifySessionId']
                if (-not $n -or -not $s.sessions.Contains("$n.json")) { $t.Remove('notifySessionId') }
            }
            [void]$list.Add($t)
            $written[$id] = $t
        }
        # Entries the app would not recognize as tasks ride along untouched.
        $foreign = @()
        if ($s.doc -and $s.doc.Contains('scheduledTasks')) { $foreign = @(@($s.doc['scheduledTasks']) | Where-Object { -not ($_ -is [System.Collections.IDictionary] -and $_['id'] -is [string]) }) }
        foreach ($x in $foreign) { [void]$list.Add($x) }

        if (-not $s.doc -and $list.Count -eq 0) { $newSeen[$s.key] = $(if ($s.writable) { $written } else { Copy-JValue $old }); continue }

        $doc = New-OrdinalDict
        if ($s.doc) { foreach ($k in $s.doc.Keys) { $doc[$k] = $s.doc[$k] } }
        $doc['scheduledTasks'] = $list
        $skips = New-OrdinalDict
        foreach ($id in $skipsAll.Keys) {
            if (-not $merged.Contains($id)) { continue }
            $arr = New-Object System.Collections.ArrayList
            foreach ($e in @($skipsAll[$id].Values | Sort-Object { Get-NumMs $_['at'] })) { [void]$arr.Add($e) }
            if ($arr.Count -gt 0) { $skips[$id] = $arr }
        }
        $doc['recordedSkips'] = $skips
        if ($doc.Contains('runRetries') -and $doc['runRetries'] -is [System.Collections.IDictionary]) {
            $rr = New-OrdinalDict
            foreach ($id in $doc['runRetries'].Keys) { if ($merged.Contains($id)) { $rr[$id] = $doc['runRetries'][$id] } }
            if ($rr.Count -gt 0) { $doc['runRetries'] = $rr } else { $doc.Remove('runRetries') }
        }

        if (-not $s.writable) {
            # The account the app runs on: never written. What we saw is what the
            # base records, so its lag is not mistaken for an edit next run.
            if (-not $s.doc -or -not (Test-CanonEqual $doc $s.doc)) { $pending.Add($s.key) }
            $newSeen[$s.key] = Copy-JValue $old
            continue
        }
        if (-not $s.doc -or -not (Test-CanonEqual $doc $s.doc)) {
            $docs[$s.key] = $doc
            foreach ($id in $written.Keys) {
                if (-not $old.Contains($id)) { $stats.added++ }
                elseif (-not (Test-CanonEqual $written[$id] $old[$id])) { $stats.changed++ }
            }
            foreach ($id in $old.Keys) { if (-not $written.Contains($id)) { $stats.removed++ } }
        }
        $newSeen[$s.key] = $written
    }
    $stats.held = $holds.Count

    foreach ($id in @($tomb.Keys)) {
        $at = Get-NumMs $tomb[$id]['at']
        if ($null -eq $at -or $at -lt ($NowMs - $script:TaskTombstoneRetentionMs)) { $tomb.Remove($id) }
    }
    $nb = New-OrdinalDict
    $nb['version'] = 1
    $nb['merged'] = $merged
    $nb['scopes'] = $newSeen
    $nb['tombstones'] = $tomb
    $nb['claims'] = $newClaims
    return @{ docs = $docs; base = $nb; stats = $stats; deleted = $deleted; pending = $pending }
}

# The engine's task stage. Returns the heartbeat state:
# updated | unchanged | deferred | would-update | error.
function Invoke-ScheduledTaskSync {
    param(
        [object[]]$Targets,          # workspace DirectoryInfo objects (the chat sync's active targets)
        [string]$StateDir,
        [bool]$AppRunning,
        [string]$KnownAccount,       # config.json lastKnownAccountUuid, or ''
        [bool]$DryRun,
        [scriptblock]$Log,
        [double]$NowMs = [double][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    )
    if ($AppRunning -and -not $KnownAccount) {
        & $Log 'tasks: the app is running and the account it runs on is unknown (no lastKnownAccountUuid); nothing written'
        return 'deferred'
    }
    $scopes = @()
    foreach ($ws in $Targets) {
        $account = Split-Path (Split-Path $ws.FullName -Parent) -Leaf
        $key = $account + '/' + $ws.Name
        $path = Join-Path $ws.FullName 'scheduled-tasks.json'
        $doc = $null; $stamp = $null; $mtime = [datetime]::MinValue
        if (Test-Path -LiteralPath $path) {
            try {
                $item = Get-Item -LiteralPath $path -ErrorAction Stop
                $text = [System.IO.File]::ReadAllText($path)
                $after = Get-Item -LiteralPath $path -ErrorAction Stop
                if ($after.LastWriteTimeUtc -ne $item.LastWriteTimeUtc -or $after.Length -ne $item.Length) { throw 'the file changed while it was read' }
            } catch {
                & $Log "tasks: $key is in use ($($_.Exception.Message)); nothing written this run"
                return 'deferred'
            }
            try { $doc = ConvertFrom-TaskJson $text } catch {
                & $Log "warning: tasks: $path does not parse ($($_.Exception.Message)); nothing written this run"
                return 'error'
            }
            if (-not ($doc -is [System.Collections.IDictionary])) { & $Log "warning: tasks: $path is not a JSON object; nothing written this run"; return 'error' }
            $stamp = @{ ticks = $item.LastWriteTimeUtc.Ticks; length = $item.Length }
            $mtime = $item.LastWriteTimeUtc
        }
        $sessions = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($f in @(Get-ChildItem -LiteralPath $ws.FullName -Filter 'local_*.json' -File -ErrorAction SilentlyContinue)) { [void]$sessions.Add($f.Name) }
        $writable = -not ($AppRunning -and [string]::Equals($account, $KnownAccount, [System.StringComparison]::OrdinalIgnoreCase))
        $scopes += @{ key = $key; account = $account; doc = $doc; writable = $writable; sessions = $sessions; path = $path; stamp = $stamp; mtime = $mtime }
    }

    $baseF = Join-Path $StateDir 'tasks-base.json'
    $base = $null
    if (Test-Path -LiteralPath $baseF) {
        try { $base = ConvertFrom-TaskJson ([System.IO.File]::ReadAllText($baseF)) } catch { & $Log 'warning: tasks-base.json does not parse; merging as a first run (no deletions)'; $base = $null }
    }

    # Ties go to the account the app runs on / starts on, then to the file the
    # app wrote most recently.
    $known = @($scopes | Where-Object { $KnownAccount -and [string]::Equals($_.account, $KnownAccount, [System.StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { $_.key })
    $rest = New-Object System.Collections.Generic.List[object]
    foreach ($s in $scopes) { if ($known -notcontains $s.key) { $rest.Add($s) } }
    $rest.Sort([System.Comparison[object]] { param($a, $b)
        $c = $b.mtime.CompareTo($a.mtime); if ($c -ne 0) { return $c }
        return [string]::CompareOrdinal($a.key, $b.key) })
    $tie = @($known) + @($rest | ForEach-Object { $_.key })
    $knownScope = if ($known.Count -gt 0) { $known[0] } else { '' }
    $runningScope = if ($AppRunning) { $knownScope } else { '' }

    $res = Merge-ScheduledTaskScopes -Scopes $scopes -Base $base -NowMs $NowMs -TieOrder $tie -RunningScope $runningScope -KnownScope $knownScope
    $st = $res.stats
    $summary = "+$($st.added) -$($st.removed) ~$($st.changed) task(s), $($st.held) held near fireAt, $($st.firedPropagated) run(s) propagated"

    if ($DryRun) {
        if ($res.docs.Count -gt 0) { & $Log "tasks would be merged into $($res.docs.Count) scope(s): $summary (-WhatIf)"; return 'would-update' }
        return $(if ($res.pending.Count -gt 0) { 'deferred' } else { 'unchanged' })
    }

    $wrote = 0
    if ($res.docs.Count -gt 0) {
        # Backup-first: every file about to be replaced, before the first write.
        $bdir = Join-Path $StateDir ('tasks-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        try {
            [System.IO.Directory]::CreateDirectory($bdir) | Out-Null
            foreach ($s in $scopes) {
                if ($res.docs.ContainsKey($s.key) -and $s.doc) { Copy-Item -LiteralPath $s.path -Destination (Join-Path $bdir (($s.key -replace '/', '__') + '.json')) -Force -ErrorAction Stop }
            }
        } catch {
            & $Log "warning: tasks: backup failed ($($_.Exception.Message)); nothing written this run"
            return 'error'
        }
        Get-ChildItem -LiteralPath $StateDir -Filter 'tasks-backup-*' -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -Skip 5 | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        foreach ($s in $scopes) {
            if (-not $res.docs.ContainsKey($s.key)) { continue }
            $err = Write-TaskFileAtomic $s.path ((ConvertTo-TaskJson $res.docs[$s.key]) + "`n") $s.stamp
            if ($err) {
                & $Log "warning: tasks: $($s.key) not written ($err); retrying next run"
                $res.base['scopes'][$s.key] = Get-TaskMap $s.doc
            } else { $wrote++ }
        }
        if ($wrote -gt 0) { & $Log "tasks merged into $wrote scope(s): $summary; backup $bdir" }
    }
    foreach ($p in $res.pending) { & $Log "tasks: $p is the account the app runs on; its file is left alone until the app closes or switches account" }

    $baseText = (ConvertTo-TaskJson $res.base) + "`n"
    $oldText = if (Test-Path -LiteralPath $baseF) { [System.IO.File]::ReadAllText($baseF) } else { '' }
    if (-not [string]::Equals($baseText, $oldText, [System.StringComparison]::Ordinal)) {
        $tmp = "$baseF.cs-tmp-$PID"
        try {
            [System.IO.File]::WriteAllText($tmp, $baseText, (New-Object System.Text.UTF8Encoding($false)))
            Move-Item -LiteralPath $tmp -Destination $baseF -Force -ErrorAction Stop
        } catch {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            & $Log "warning: tasks-base.json write failed ($($_.Exception.Message))"
            return 'error'
        }
    }
    if ($wrote -gt 0) { return 'updated' }
    if ($res.docs.Count -gt 0 -or $res.pending.Count -gt 0) { return 'deferred' }
    return 'unchanged'
}

# Atomic replace of a scheduled-tasks.json: temp sibling, parse-verify, and a
# last check that the app has not rewritten the file since we read it.
function Write-TaskFileAtomic([string]$Path, [string]$Text, $ReadStamp) {
    $tmp = "$Path.cs-tmp-$PID"
    try {
        [System.IO.File]::WriteAllText($tmp, $Text, (New-Object System.Text.UTF8Encoding($false)))
        $null = ConvertFrom-TaskJson ([System.IO.File]::ReadAllText($tmp))
        if ($ReadStamp) {
            $now = Get-Item -LiteralPath $Path -ErrorAction Stop
            if ($now.LastWriteTimeUtc.Ticks -ne $ReadStamp.ticks -or $now.Length -ne $ReadStamp.length) { throw 'changed by the app since it was read' }
        } elseif (Test-Path -LiteralPath $Path) { throw 'created by the app since it was read' }
        Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
        return $null
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        return $_.Exception.Message
    }
}

# The account the app runs on (or will start on): config.json's
# lastKnownAccountUuid. $null when the file or the key cannot be read.
function Get-LastKnownAccount([string]$AppConfigPath) {
    if (-not $AppConfigPath -or -not (Test-Path -LiteralPath $AppConfigPath)) { return $null }
    try {
        $raw = [System.IO.File]::ReadAllText($AppConfigPath)
        $m = [regex]::Match($raw, '"lastKnownAccountUuid"\s*:\s*"([0-9A-Za-z-]+)"')
        if ($m.Success) { return $m.Groups[1].Value }
    } catch { }
    return $null
}
