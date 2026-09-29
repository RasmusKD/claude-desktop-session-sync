# Pester 5 tests for the sync engine, run against fixture trees via -RootsOverride.
# Covers: cross-account propagation, seeding, health rules (healing, title
# false-positives), device guards, deletion propagation (partial-failure
# non-resurrection, freeze durability, stash retention and quality), sidebar
# groups (three-way merge in a fixture Local Storage LevelDB, the app-running
# refusal, the config mirror's byte fidelity, BOM and decoy anchors), scheduled
# tasks (union, run-state propagation, deletions, holds, the first-run rule, the
# running-app and locked-file deferrals), the MSIX shadow refusal, and -WhatIf
# inertness.

BeforeAll {
    $script:repo    = Split-Path $PSScriptRoot -Parent
    $script:engine  = Join-Path $script:repo 'sync-claude-sessions.ps1'
    $script:fixture = Join-Path $PSScriptRoot 'leveldb-fixture.mjs'
    $script:node    = (Get-Command node -ErrorAction SilentlyContinue).Source
    $script:noNode  = (-not $script:node) -or -not (Test-Path (Join-Path $script:repo 'group-sync\node_modules\classic-level\package.json'))
    if ($script:noNode) { Write-Warning 'node or group-sync/node_modules missing: the sidebar-group tests are skipped (run npm ci in group-sync/).' }

    function New-Chat {
        param($Dir, $Name, [ValidateSet('healthy','damaged','junk','markerTitle')]$Kind = 'healthy', $AgeMinutes = 0)
        $json = switch ($Kind) {
            'healthy'     { '{"sessionId":"' + $Name + '","cliSessionId":"cli-' + $Name + '","title":"t"}' }
            'damaged'     { '{"sessionId":"' + $Name + '","cliSessionId":"cli-' + $Name + '","transcriptUnavailable":true}' }
            'junk'        { '{"sessionId":"' + $Name + '"}' }
            'markerTitle' { '{"sessionId":"' + $Name + '","cliSessionId":"cli-' + $Name + '","title":"the \"transcriptUnavailable\": true bug"}' }
        }
        $path = Join-Path $Dir "local_$Name.json"
        Set-Content -Path $path -Value $json -NoNewline
        [System.IO.File]::SetLastWriteTimeUtc($path, (Get-Date).ToUniversalTime().AddMinutes(-$AgeMinutes))
        return $path
    }

    function New-Fixture {
        param($Layout)
        $root = Join-Path $TestDrive ("root-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        foreach ($rel in $Layout) { New-Item -ItemType Directory -Force -Path (Join-Path $root $rel) | Out-Null }
        return $root
    }

    function New-StateDir {
        $d = Join-Path $TestDrive ("state-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        return $d
    }

    # Every run points Local Storage AND the config at paths that do not exist
    # unless a test hands it fixtures: a fixture tree must never pair with the
    # real database or the real config (the engine refuses that pairing too).
    function Invoke-Sync {
        param($Root, $StateDir, [switch]$WhatIf, [switch]$Loud, [string]$ConfigPath = '', [string]$LevelDb = '', [string]$HelperDir = '', [string]$PackagesRoot = '', [string]$AppState = '', [string]$AppConfig = '')
        $p = @{ RootsOverride = $Root; StateDirOverride = $StateDir; Quiet = (-not $Loud) }
        $p.LevelDbPathOverride = if ($LevelDb) { $LevelDb } else { Join-Path $TestDrive 'no-leveldb-here' }
        $p.ConfigPathOverride  = if ($ConfigPath) { $ConfigPath } else { Join-Path $TestDrive 'no-config-here.json' }
        if ($HelperDir)    { $p.GroupHelperOverride = $HelperDir }
        if ($PackagesRoot) { $p.PackagesRootOverride = $PackagesRoot }
        if ($AppState)     { $p.AppStateOverride = $AppState }
        if ($AppConfig)    { $p.AppConfigOverride = $AppConfig }
        if ($WhatIf) { & $script:engine @p -WhatIf }
        else         { & $script:engine @p -Confirm:$false }
    }

    function Get-Heartbeat($StateDir) { Get-Content (Join-Path $StateDir 'sync-log.txt') -Tail 1 }

    function New-Config([string]$Text, [switch]$Bom) {
        $p = Join-Path $TestDrive ("cfg-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
        [System.IO.File]::WriteAllText($p, $Text, (New-Object System.Text.UTF8Encoding($Bom.IsPresent)))
        return $p
    }

    # ── Local Storage fixtures (shape observed in Claude desktop 1.46388.4) ──
    function New-ScopeEntry([object[]]$Groups, [hashtable]$Assignments = @{}, [hashtable]$Order = @{}) {
        @{ groups = @($Groups); assignments = $Assignments; order = $Order }
    }
    # Extra: further Local Storage keys, e.g. the app's server-sync bookkeeping
    # (ccd-sync-owner, the logout stamp). A string value is stored verbatim.
    function New-LevelDb([hashtable]$Scopes, [string]$LastScope = '', [hashtable]$Extra = @{}) {
        $dir = Join-Path $TestDrive ("ldb-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $entries = @{
            'dframe-store' = @{ state = @{ collapsed = $false; pinnedOrder = @('code:local_pinned'); collapsedGroups = @(); customGroupsByScope = $Scopes; lastSidebarScopeKey = $LastScope }; version = 1 }
            'LSS-persisted.dframe-group-scopes' = @{ value = $Scopes; tabId = ''; timestamp = 1788766673183 }
            'LSS-persisted.dframe-local-slice' = @{ value = @{ pinnedOrder = @('code:local_pinned'); homeProjectsPinnedOrder = @() }; tabId = ''; timestamp = 1788766673184 }
            'spa:locale' = 'en-US'
        }
        foreach ($k in $Extra.Keys) { $entries[$k] = $Extra[$k] }
        $json = Join-Path $TestDrive ("ldb-entries-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
        [System.IO.File]::WriteAllText($json, ($entries | ConvertTo-Json -Depth 30 -Compress), (New-Object System.Text.UTF8Encoding($false)))
        & $script:node $script:fixture create $dir $json | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "fixture create failed" }
        return $dir
    }
    function Read-LevelDbJson([string]$Dir, [string]$Name) {
        $out = (& $script:node $script:fixture read $Dir $Name) -join "`n"
        if ($LASTEXITCODE -ne 0) { throw "fixture read failed" }
        if (-not $out) { return $null }
        $out | ConvertFrom-Json
    }
    function Read-LevelDbText([string]$Dir, [string]$Name) {
        $out = (& $script:node $script:fixture read $Dir $Name) -join "`n"
        if ($LASTEXITCODE -ne 0) { throw "fixture read failed" }
        $out
    }
    function Get-LevelDbMeta([string]$Dir) { ((& $script:node $script:fixture meta $Dir) -join '') | ConvertFrom-Json }
    function Get-ScopeFromStore($Dir, $Scope) { (Read-LevelDbJson $Dir 'dframe-store').state.customGroupsByScope.$Scope }
    function Get-ScopeFromLss($Dir, $Scope)   { (Read-LevelDbJson $Dir 'LSS-persisted.dframe-group-scopes').value.$Scope }
    function New-GroupConfig([switch]$Bom, [switch]$Decoy) {
        $decoyText = if ($Decoy) { '"backupOfOldProfile": {"epitaxyPrefs": {"dframe-group-scopes": {"devA/ws1": {"groups": [{"id": "cg-decoy", "name": "DECOY"}], "assignments": {}, "order": {}}}}},' } else { '' }
        New-Config -Bom:$Bom ('{' + "`n" + '  "coworkUserFilesPath": "C:\\Users\\x\\Cowork",' + "`n" + '  ' + $decoyText + "`n" + '  "preferences": {' + "`n" + '    "sidebarMode": "code",' + "`n" + '    "epitaxyPrefs": {' + "`n" + '      "starred-local-code-sessions": ["local_1"],' + "`n" + '      "dframe-group-scopes": {' + "`n" + '        "devA/ws1": {"groups": [], "assignments": {}, "order": {}}' + "`n" + '      },' + "`n" + '      "fastMode": {"value": false, "tabId": ""}' + "`n" + '    }' + "`n" + '  }' + "`n" + '}')
    }
}

Describe 'cross-account propagation' {
    It 'copies a chat from one account into another account single workspace' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 'aaa' | Out-Null
        New-Chat (Join-Path $root 'devB/ws2') 'bbb' | Out-Null
        Invoke-Sync $root $state
        Join-Path $root 'devB/ws2/local_aaa.json' | Should -Exist
        Join-Path $root 'devA/ws1/local_bbb.json' | Should -Exist
    }

    It 'seeds a fresh account whose workspace folder is still empty' {
        $root = New-Fixture @('devA/ws1', 'devFresh/wsNew'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 'aaa' | Out-Null
        Invoke-Sync $root $state
        Join-Path $root 'devFresh/wsNew/local_aaa.json' | Should -Exist
    }

    It 'seeds a damaged-only chat into a fresh account (a damaged copy beats no chat)' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 'dmg' -Kind damaged | Out-Null
        New-Chat (Join-Path $root 'devA/ws1') 'aaa' | Out-Null
        Invoke-Sync $root $state
        Join-Path $root 'devB/ws2/local_dmg.json' | Should -Exist
    }

    It 'writes a heartbeat naming the group stage even when it is off' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 'aaa' | Out-Null
        Invoke-Sync $root $state
        Get-Heartbeat $state | Should -Match 'groups off, tasks '
    }
}

Describe 'health rules' {
    It 'never lets a newer damaged copy beat an older healthy one - and heals the damaged side' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 'ccc' -Kind damaged -AgeMinutes 0  | Out-Null
        New-Chat (Join-Path $root 'devB/ws2') 'ccc' -Kind healthy -AgeMinutes 60 | Out-Null
        Invoke-Sync $root $state
        Get-Content (Join-Path $root 'devB/ws2/local_ccc.json') -Raw | Should -Not -Match 'transcriptUnavailable'
        Get-Content (Join-Path $root 'devA/ws1/local_ccc.json') -Raw | Should -Not -Match 'transcriptUnavailable'
    }

    It 'does not overwrite an unreadable (locked) destination, and leaves no temp residue' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 'ddd' -Kind damaged | Out-Null
        $dst = New-Chat (Join-Path $root 'devB/ws2') 'ddd' -Kind junk -AgeMinutes 60
        New-Chat (Join-Path $root 'devB/ws2') 'filler' | Out-Null
        $lock = [System.IO.File]::Open($dst, 'Open', 'Read', 'None')
        try { Invoke-Sync $root $state } finally { $lock.Dispose() }
        Get-Content $dst -Raw | Should -Not -Match 'transcriptUnavailable'
        @(Get-ChildItem (Join-Path $root 'devB/ws2') -Filter '*.cs-tmp-*').Count | Should -Be 0
    }

    It 'a title containing the literal damage marker does not poison health' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 'ttt' -Kind markerTitle -AgeMinutes 0 | Out-Null
        New-Chat (Join-Path $root 'devB/ws2') 'ttt' -Kind healthy -AgeMinutes 60 | Out-Null
        Invoke-Sync $root $state
        Get-Content (Join-Path $root 'devB/ws2/local_ttt.json') -Raw | Should -Match 'bug'
    }
}

Describe 'device guards' {
    It 'skips a device with multiple chat-bearing workspaces instead of blending them' {
        $root = New-Fixture @('devA/ws1', 'devA/ws2', 'devB/ws3'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 'e1' | Out-Null
        New-Chat (Join-Path $root 'devA/ws2') 'e2' | Out-Null
        New-Chat (Join-Path $root 'devB/ws3') 'e3' | Out-Null
        Invoke-Sync $root $state
        Join-Path $root 'devB/ws3/local_e1.json' | Should -Not -Exist
        Join-Path $root 'devA/ws1/local_e2.json' | Should -Not -Exist
        Join-Path $root 'devA/ws1/local_e3.json' | Should -Not -Exist
    }
}

Describe 'deletion propagation' {
    It 'deletes everywhere when a fully-synced chat disappears from a chat-bearing account, and stashes a copy' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 'del1' | Out-Null
        New-Chat (Join-Path $root 'devA/ws1') 'keep1' | Out-Null
        Invoke-Sync $root $state
        Join-Path $root 'devB/ws2/local_del1.json' | Should -Exist
        Remove-Item (Join-Path $root 'devA/ws1/local_del1.json')
        Invoke-Sync $root $state
        Join-Path $root 'devB/ws2/local_del1.json' | Should -Not -Exist
        @(Get-ChildItem (Join-Path $state 'deleted') -Filter '*local_del1.json').Count | Should -Be 1
        Join-Path $root 'devB/ws2/local_keep1.json' | Should -Exist
    }

    It 'does not resurrect a chat when one copy cannot be deleted, and finishes the job next run' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2', 'devC/ws3'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 'x1' | Out-Null
        New-Chat (Join-Path $root 'devA/ws1') 'keep' | Out-Null
        Invoke-Sync $root $state
        Remove-Item (Join-Path $root 'devA/ws1/local_x1.json')
        $held = Join-Path $root 'devC/ws3/local_x1.json'
        $lock = [System.IO.File]::Open($held, 'Open', 'Read', 'None')
        try { Invoke-Sync $root $state } finally { $lock.Dispose() }
        Join-Path $root 'devA/ws1/local_x1.json' | Should -Not -Exist
        Invoke-Sync $root $state
        $held | Should -Not -Exist
        Join-Path $root 'devA/ws1/local_x1.json' | Should -Not -Exist
    }

    It 'keeps a frozen workspace frozen across runs while other accounts keep syncing' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2', 'devC/ws3'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 'aaa' | Out-Null
        Invoke-Sync $root $state; Invoke-Sync $root $state    # all three become sources
        Get-ChildItem (Join-Path $root 'devB/ws2') -Filter 'local_*.json' | Remove-Item
        Invoke-Sync $root $state; Invoke-Sync $root $state    # TWO runs after the clear-out
        @(Get-ChildItem (Join-Path $root 'devB/ws2') -Filter 'local_*.json').Count | Should -Be 0   # still frozen
        Join-Path $root 'devA/ws1/local_aaa.json' | Should -Exist                                    # not deleted
        Join-Path $root 'devC/ws3/local_aaa.json' | Should -Exist                                    # others unaffected
    }

    It 'thaws a frozen workspace automatically when chats appear in it again' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 'aaa' | Out-Null
        Invoke-Sync $root $state; Invoke-Sync $root $state
        Get-ChildItem (Join-Path $root 'devB/ws2') -Filter 'local_*.json' | Remove-Item
        Invoke-Sync $root $state                              # B frozen
        New-Chat (Join-Path $root 'devB/ws2') 'fresh' | Out-Null
        Invoke-Sync $root $state                              # B thaws, sync resumes
        Join-Path $root 'devA/ws1/local_fresh.json' | Should -Exist
        Join-Path $root 'devB/ws2/local_aaa.json' | Should -Exist
    }

    It 'retains the stash for chats older than the retention window (stash time, not chat time)' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 'old1' -AgeMinutes (45 * 24 * 60) | Out-Null
        New-Chat (Join-Path $root 'devA/ws1') 'keep' | Out-Null
        Invoke-Sync $root $state
        Remove-Item (Join-Path $root 'devA/ws1/local_old1.json')
        Invoke-Sync $root $state                              # stash written, stamped NOW
        Invoke-Sync $root $state                              # retention sweep runs again
        @(Get-ChildItem (Join-Path $state 'deleted') -Filter '*local_old1.json').Count | Should -Be 1
    }

    It 'stashes the healthiest newest copy with the device id in the name' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2', 'devC/ws3'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 's1' | Out-Null
        New-Chat (Join-Path $root 'devA/ws1') 'keep' | Out-Null
        Invoke-Sync $root $state
        Remove-Item (Join-Path $root 'devA/ws1/local_s1.json')
        Set-Content (Join-Path $root 'devB/ws2/local_s1.json') -Value '{"sessionId":"s1","cliSessionId":"cli-s1","title":"FRESH-EDIT"}' -NoNewline
        Invoke-Sync $root $state
        $stash = @(Get-ChildItem (Join-Path $state 'deleted') -Filter '*local_s1.json')
        $stash.Count | Should -Be 1
        $stash[0].Name | Should -Match 'devB'
        Get-Content $stash[0].FullName -Raw | Should -Match 'FRESH-EDIT'
    }

    It '-WhatIf does not delete' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 'del2' | Out-Null
        New-Chat (Join-Path $root 'devA/ws1') 'keep2' | Out-Null
        Invoke-Sync $root $state
        Remove-Item (Join-Path $root 'devA/ws1/local_del2.json')
        Invoke-Sync $root $state -WhatIf
        Join-Path $root 'devB/ws2/local_del2.json' | Should -Exist
    }
}

Describe 'sidebar groups (Local Storage merge)' -Skip:$script:noNode {
    It 'propagates a group created on one account into the other, in both Local Storage keys and the config mirror, with the size accounting intact' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 'aaa' | Out-Null
        $g1 = @{ id = 'cg-1'; name = 'skole' }
        $ldb = New-LevelDb @{
            'devA/ws1' = New-ScopeEntry @($g1) @{ 'code:local_aaa' = 'cg-1' } @{ 'cg-1' = @('code:local_aaa') }
            'devB/ws2' = New-ScopeEntry @()
        } -LastScope 'devB/ws2'
        $cfg = New-GroupConfig
        Invoke-Sync $root $state -LevelDb $ldb -ConfigPath $cfg
        Get-Heartbeat $state | Should -Match 'groups updated, tasks '
        foreach ($scope in 'devA/ws1', 'devB/ws2') {
            $s = Get-ScopeFromStore $ldb $scope
            @($s.groups).id | Should -Be @('cg-1')
            $s.assignments.'code:local_aaa' | Should -Be 'cg-1'
            @($s.order.'cg-1') | Should -Be @('code:local_aaa')
            (Get-ScopeFromLss $ldb $scope | ConvertTo-Json -Compress -Depth 10) | Should -Be ($s | ConvertTo-Json -Compress -Depth 10)
        }
        (Read-LevelDbJson $ldb 'dframe-store').state.pinnedOrder | Should -Be @('code:local_pinned')   # untouched sibling state
        $meta = Get-LevelDbMeta $ldb
        $meta.sizeBytes | Should -Be $meta.computed
        Join-Path $state 'groups-base.json' | Should -Exist
        @(Get-ChildItem $state -Filter 'leveldb-backup-*' -Directory).Count | Should -Be 1
        @(Get-ChildItem $state -Filter 'leveldb-backup-*.tmp' -Directory).Count | Should -Be 0
        $after = Get-Content $cfg -Raw
        $after | Should -Match '"coworkUserFilesPath": "C:\\\\Users\\\\x\\\\Cowork"'
        $after | Should -Match '"starred-local-code-sessions": \["local_1"\]'
        $after | Should -Match '"fastMode": \{"value": false, "tabId": ""\}'
        $parsed = $after | ConvertFrom-Json
        @($parsed.preferences.epitaxyPrefs.'dframe-group-scopes'.'devB/ws2'.groups)[0].name | Should -Be 'skole'
        @($parsed.preferences.epitaxyPrefs.'dframe-group-scopes'.'devA/ws1'.groups)[0].name | Should -Be 'skole'
        @(Get-ChildItem $state -Filter 'config-backup-*.json').Count | Should -Be 1
    }

    It 'merges three-way after a base exists: a deletion on one side and a rename on the other both propagate' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 'aaa' | Out-Null
        $both = @(@{ id = 'cg-1'; name = 'one' }, @{ id = 'cg-2'; name = 'two' })
        $entry = New-ScopeEntry $both @{ 'code:local_aaa' = 'cg-1'; 'code:local_bbb' = 'cg-2' } @{ 'cg-1' = @('code:local_aaa'); 'cg-2' = @('code:local_bbb') }
        $ldb1 = New-LevelDb @{ 'devA/ws1' = $entry; 'devB/ws2' = $entry }
        Invoke-Sync $root $state -LevelDb $ldb1
        Get-Heartbeat $state | Should -Match 'groups unchanged, tasks '
        Join-Path $state 'groups-base.json' | Should -Exist
        # A deletes cg-1 (and its assignment); B renames cg-2.
        $a = New-ScopeEntry @(@{ id = 'cg-2'; name = 'two' }) @{ 'code:local_bbb' = 'cg-2' } @{ 'cg-2' = @('code:local_bbb') }
        $b = New-ScopeEntry @(@{ id = 'cg-1'; name = 'one' }, @{ id = 'cg-2'; name = 'Two!' }) @{ 'code:local_aaa' = 'cg-1'; 'code:local_bbb' = 'cg-2' } @{ 'cg-1' = @('code:local_aaa'); 'cg-2' = @('code:local_bbb') }
        $ldb2 = New-LevelDb @{ 'devA/ws1' = $a; 'devB/ws2' = $b } -LastScope 'devB/ws2'
        Invoke-Sync $root $state -LevelDb $ldb2
        Get-Heartbeat $state | Should -Match 'groups updated, tasks '
        foreach ($scope in 'devA/ws1', 'devB/ws2') {
            $s = Get-ScopeFromStore $ldb2 $scope
            @($s.groups).id | Should -Be @('cg-2')
            @($s.groups)[0].name | Should -Be 'Two!'
            $s.assignments.PSObject.Properties.Name | Should -Not -Contain 'code:local_aaa'
            $s.order.PSObject.Properties.Name | Should -Not -Contain 'cg-1'
        }
    }

    It 'carries a group with members across a relog: the server merge that dropped it is not a deletion, the app is told to push, and a deletion made after the push still propagates' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 'aaa' | Out-Null
        New-Chat (Join-Path $root 'devA/ws1') 'bbb' | Out-Null
        $skole = New-ScopeEntry @(@{ id = 'cg-skole'; name = 'skole' }) @{ 'code:local_aaa' = 'cg-skole'; 'code:local_bbb' = 'cg-skole' } @{ 'cg-skole' = @('code:local_aaa', 'code:local_bbb') }
        $collect = New-ScopeEntry @(@{ id = 'cg-collect'; name = 'collect' })
        $switchBefore = [string]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - 60000)
        # 1. The app last ran on A, which created skole; B's row on the server holds collect only.
        $ldb1 = New-LevelDb @{ 'devA/ws1' = $skole; 'devB/ws2' = $collect } -LastScope 'devA/ws1' -Extra @{ 'ccd-sync-owner' = 'devA'; 'epitaxy-context-usage-logout-at' = $switchBefore }
        Invoke-Sync $root $state -LevelDb $ldb1
        Get-Heartbeat $state | Should -Match 'groups updated, tasks '
        foreach ($scope in 'devA/ws1', 'devB/ws2') { @((Get-ScopeFromStore $ldb1 $scope).groups).id | Sort-Object | Should -Be @('cg-collect', 'cg-skole') }
        Read-LevelDbText $ldb1 'ccd-sync-pending:ccd/dframe-store' | Should -Be 'devA/ws1'   # A pushes its local state at the next start
        $merged = Get-ScopeFromStore $ldb1 'devA/ws1'
        # 2. The user relogs into B: the switch discards the marker unpushed, and B's
        #    server row replaces B's local list, dropping skole and its two members.
        $switchAfter = [string]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
        $ldb2 = New-LevelDb @{ 'devA/ws1' = $merged; 'devB/ws2' = $collect } -LastScope 'devB/ws2' -Extra @{ 'ccd-sync-owner' = 'devB'; 'epitaxy-context-usage-logout-at' = $switchAfter }
        Invoke-Sync $root $state -LevelDb $ldb2
        Get-Heartbeat $state | Should -Match 'groups updated, tasks '
        (Get-Content (Join-Path $state 'sync-log.txt') -Tail 2)[0] | Should -Match '\+0 -0 ~0 group\(s\), 0 withheld'
        $b = Get-ScopeFromStore $ldb2 'devB/ws2'
        @($b.groups).id | Sort-Object | Should -Be @('cg-collect', 'cg-skole')
        $b.assignments.'code:local_aaa' | Should -Be 'cg-skole'
        $b.assignments.'code:local_bbb' | Should -Be 'cg-skole'
        @($b.order.'cg-skole') | Should -Be @('code:local_aaa', 'code:local_bbb')
        @((Get-ScopeFromStore $ldb2 'devA/ws1').groups).id | Sort-Object | Should -Be @('cg-collect', 'cg-skole')
        Read-LevelDbText $ldb2 'ccd-sync-pending:ccd/dframe-store' | Should -Be 'devB/ws2'
        $base = Get-Content (Join-Path $state 'groups-base.json') -Raw | ConvertFrom-Json
        @($base.tombstones.PSObject.Properties).Count | Should -Be 0
        $base.pending.'devB/ws2'.entry.groups.id | Should -Contain 'cg-skole'
        # 3. The app started on B and pushed (marker gone, no switch since), then the
        #    user deleted skole on B. That deletion is real and reaches A.
        $ldb3 = New-LevelDb @{ 'devA/ws1' = $merged; 'devB/ws2' = $collect } -LastScope 'devB/ws2' -Extra @{ 'ccd-sync-owner' = 'devB'; 'epitaxy-context-usage-logout-at' = $switchAfter }
        Invoke-Sync $root $state -LevelDb $ldb3
        Get-Heartbeat $state | Should -Match 'groups updated, tasks '
        @((Get-ScopeFromStore $ldb3 'devA/ws1').groups).id | Should -Be @('cg-collect')
        (Get-ScopeFromStore $ldb3 'devA/ws1').assignments.PSObject.Properties.Name | Should -Not -Contain 'code:local_aaa'
        Read-LevelDbText $ldb3 'ccd-sync-pending:ccd/dframe-store' | Should -BeNullOrEmpty       # B's server row already lacks it
        $base = Get-Content (Join-Path $state 'groups-base.json') -Raw | ConvertFrom-Json
        $base.tombstones.PSObject.Properties.Name | Should -Contain 'cg-skole'
        # 4. A relogs and its stale server row hands skole back: the tombstone withholds it.
        $ldb4 = New-LevelDb @{ 'devA/ws1' = $merged; 'devB/ws2' = $collect } -LastScope 'devA/ws1' -Extra @{ 'ccd-sync-owner' = 'devA'; 'epitaxy-context-usage-logout-at' = [string]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) }
        Invoke-Sync $root $state -LevelDb $ldb4
        @((Get-ScopeFromStore $ldb4 'devA/ws1').groups).id | Should -Be @('cg-collect')
        Read-LevelDbText $ldb4 'ccd-sync-pending:ccd/dframe-store' | Should -Be 'devA/ws1'
    }

    It 'does not read a write the app discarded at an account switch as a deletion' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 'aaa' | Out-Null
        $skole = New-ScopeEntry @(@{ id = 'cg-skole'; name = 'skole' }) @{ 'code:local_aaa' = 'cg-skole' } @{ 'cg-skole' = @('code:local_aaa') }
        $collect = New-ScopeEntry @(@{ id = 'cg-collect'; name = 'collect' })
        $ldb1 = New-LevelDb @{ 'devA/ws1' = $collect; 'devB/ws2' = $skole } -LastScope 'devA/ws1' -Extra @{ 'ccd-sync-owner' = 'devA'; 'epitaxy-context-usage-logout-at' = '1000' }
        Invoke-Sync $root $state -LevelDb $ldb1
        Read-LevelDbText $ldb1 'ccd-sync-pending:ccd/dframe-store' | Should -Be 'devA/ws1'
        # The user relogged away and back to A before the app pushed: the marker is
        # gone, A's server row never had skole, and the pull put A back to collect.
        $switchAfter = [string]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
        $ldb2 = New-LevelDb @{ 'devA/ws1' = $collect; 'devB/ws2' = (Get-ScopeFromStore $ldb1 'devB/ws2') } -LastScope 'devA/ws1' -Extra @{ 'ccd-sync-owner' = 'devA'; 'epitaxy-context-usage-logout-at' = $switchAfter }
        Invoke-Sync $root $state -LevelDb $ldb2
        Get-Heartbeat $state | Should -Match 'groups updated, tasks '
        @((Get-ScopeFromStore $ldb2 'devA/ws1').groups).id | Sort-Object | Should -Be @('cg-collect', 'cg-skole')
        @((Get-ScopeFromStore $ldb2 'devB/ws2').groups).id | Sort-Object | Should -Be @('cg-collect', 'cg-skole')
        Read-LevelDbText $ldb2 'ccd-sync-pending:ccd/dframe-store' | Should -Be 'devA/ws1'
        @((Get-Content (Join-Path $state 'groups-base.json') -Raw | ConvertFrom-Json).tombstones.PSObject.Properties).Count | Should -Be 0
    }

    It 'never deletes on the first merge: two accounts with different groups end up with the union' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 'aaa' | Out-Null
        $ldb = New-LevelDb @{
            'devA/ws1' = New-ScopeEntry @(@{ id = 'cg-1'; name = 'one' }) @{ 'code:local_aaa' = 'cg-1' } @{ 'cg-1' = @('code:local_aaa') }
            'devB/ws2' = New-ScopeEntry @(@{ id = 'cg-2'; name = 'two' }) @{ 'code:local_bbb' = 'cg-2' } @{ 'cg-2' = @('code:local_bbb') }
        } -LastScope 'devB/ws2'
        Invoke-Sync $root $state -LevelDb $ldb
        foreach ($scope in 'devA/ws1', 'devB/ws2') {
            $ids = @((Get-ScopeFromStore $ldb $scope).groups).id
            $ids | Should -Be @('cg-2', 'cg-1')                # the last-used account's order leads
        }
    }

    It 'treats a scope the app wiped as a seed target, never as deletion evidence' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 'aaa' | Out-Null
        $entry = New-ScopeEntry @(@{ id = 'cg-1'; name = 'one' }) @{ 'code:local_aaa' = 'cg-1' } @{ 'cg-1' = @('code:local_aaa') }
        Invoke-Sync $root $state -LevelDb (New-LevelDb @{ 'devA/ws1' = $entry; 'devB/ws2' = $entry })
        $ldb = New-LevelDb @{ 'devA/ws1' = $entry }                  # devB/ws2 vanished from the map
        Invoke-Sync $root $state -LevelDb $ldb
        @((Get-ScopeFromStore $ldb 'devB/ws2').groups).id | Should -Be @('cg-1')
        @((Get-ScopeFromStore $ldb 'devA/ws1').groups).id | Should -Be @('cg-1')
    }

    It 'refuses to write while the app holds the Local Storage lock, and reports it as deferred' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 'aaa' | Out-Null
        $ldb = New-LevelDb @{
            'devA/ws1' = New-ScopeEntry @(@{ id = 'cg-1'; name = 'one' })
            'devB/ws2' = New-ScopeEntry @()
        }
        $holdOut = Join-Path $TestDrive ("hold-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
        $holder = Start-Process -FilePath $script:node -ArgumentList @('"' + $script:fixture + '"', 'hold', '"' + $ldb + '"', '20000') -PassThru -NoNewWindow -RedirectStandardOutput $holdOut
        try {
            $deadline = (Get-Date).AddSeconds(15)
            while ((Get-Date) -lt $deadline -and -not ((Test-Path $holdOut) -and (Get-Content $holdOut -Raw -ErrorAction SilentlyContinue) -match 'held')) { Start-Sleep -Milliseconds 100 }
            (Get-Content $holdOut -Raw) | Should -Match 'held'
            # Captured after the holder opened the database: LevelDB's own open
            # rolls the log, and that is the holder's doing, not ours.
            $before = @(Get-ChildItem $ldb -File | ForEach-Object { "$($_.Name):$($_.Length)" }) -join ';'
            Invoke-Sync $root $state -LevelDb $ldb
        } finally { Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue; $holder.WaitForExit() }
        Get-Heartbeat $state | Should -Match 'groups deferred, tasks '
        Join-Path $state 'groups-base.json' | Should -Not -Exist
        @(Get-ChildItem $state -Filter 'leveldb-backup-*' -Directory).Count | Should -Be 0
        (@(Get-ChildItem $ldb -File | ForEach-Object { "$($_.Name):$($_.Length)" }) -join ';') | Should -Be $before
        @((Get-ScopeFromStore $ldb 'devB/ws2').groups).Count | Should -Be 0
    }

    It '-WhatIf reports the merge and writes nothing: no Local Storage change, no base, no backup, no config change' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 'aaa' | Out-Null
        $ldb = New-LevelDb @{
            'devA/ws1' = New-ScopeEntry @(@{ id = 'cg-1'; name = 'one' })
            'devB/ws2' = New-ScopeEntry @()
        }
        $cfg = New-GroupConfig
        $cfgBefore = Get-Content $cfg -Raw
        # Under -WhatIf the log itself is a previewed write, so the heartbeat is read from the console.
        $out = Invoke-Sync $root $state -LevelDb $ldb -ConfigPath $cfg -WhatIf -Loud 6>&1
        ($out | Out-String) | Should -Match 'groups would-update'
        @((Get-ScopeFromStore $ldb 'devB/ws2').groups).Count | Should -Be 0
        Join-Path $state 'groups-base.json' | Should -Not -Exist
        @(Get-ChildItem $state -Filter 'leveldb-backup-*' -Directory).Count | Should -Be 0
        (Get-Content $cfg -Raw) | Should -Be $cfgBefore
    }

    It 'preserves a UTF-8 BOM and ignores a decoy occurrence of the key outside preferences' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 'aaa' | Out-Null
        $ldb = New-LevelDb @{
            'devA/ws1' = New-ScopeEntry @(@{ id = 'cg-1'; name = 'real' })
            'devB/ws2' = New-ScopeEntry @()
        }
        $cfg = New-GroupConfig -Bom -Decoy
        Invoke-Sync $root $state -LevelDb $ldb -ConfigPath $cfg
        $bytes = [System.IO.File]::ReadAllBytes($cfg)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeTrue
        $parsed = Get-Content $cfg -Raw | ConvertFrom-Json
        @($parsed.backupOfOldProfile.epitaxyPrefs.'dframe-group-scopes'.'devA/ws1'.groups)[0].name | Should -Be 'DECOY'
        $parsed.backupOfOldProfile.epitaxyPrefs.'dframe-group-scopes'.PSObject.Properties.Name | Should -Not -Contain 'devB/ws2'
        @($parsed.preferences.epitaxyPrefs.'dframe-group-scopes'.'devB/ws2'.groups)[0].name | Should -Be 'real'
    }

    It 'keeps the config mirror in step on a later run even when the merge itself has nothing to change' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 'aaa' | Out-Null
        $entry = New-ScopeEntry @(@{ id = 'cg-1'; name = 'one' })
        $ldb = New-LevelDb @{ 'devA/ws1' = $entry; 'devB/ws2' = $entry }
        $cfg = New-GroupConfig                                  # mirror is behind: devB/ws2 missing, devA/ws1 empty
        Invoke-Sync $root $state -LevelDb $ldb -ConfigPath $cfg
        Get-Heartbeat $state | Should -Match 'groups mirrored, tasks '
        $parsed = Get-Content $cfg -Raw | ConvertFrom-Json
        @($parsed.preferences.epitaxyPrefs.'dframe-group-scopes'.'devB/ws2'.groups)[0].id | Should -Be 'cg-1'
    }

    It 'reports groups off, and still syncs chats, when the helper is missing' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 'aaa' | Out-Null
        $ldb = New-LevelDb @{ 'devA/ws1' = New-ScopeEntry @(@{ id = 'cg-1'; name = 'one' }); 'devB/ws2' = New-ScopeEntry @() }
        Invoke-Sync $root $state -LevelDb $ldb -HelperDir (Join-Path $TestDrive 'no-helper')
        Get-Heartbeat $state | Should -Match 'groups off, tasks '
        Join-Path $root 'devB/ws2/local_aaa.json' | Should -Exist
        @((Get-ScopeFromStore $ldb 'devB/ws2').groups).Count | Should -Be 0
    }
}

Describe 'MSIX shadow refusal' {
    It 'refuses to run when the state dir it sees is a package shadow, and touches nothing' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 'aaa' | Out-Null
        # A junction makes a file written into the state dir show up under a
        # package's LocalCache mirror of it: exactly what the probe detects.
        $packages = Join-Path $TestDrive ("pk-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $mirrorParent = Join-Path $packages 'SomeApp_abc123\LocalCache\Local'
        New-Item -ItemType Directory -Force -Path $mirrorParent | Out-Null
        $junction = Join-Path $mirrorParent (Split-Path $state -Leaf)
        New-Item -ItemType Junction -Path $junction -Target $state | Out-Null
        try {
            $out = Invoke-Sync $root $state -PackagesRoot $packages 6>&1
            $LASTEXITCODE | Should -Be 2
            ($out | Out-String) | Should -Match 'refused: this process sees an MSIX shadow'
        } finally { [System.IO.Directory]::Delete($junction, $false) }
        Join-Path $root 'devB/ws2/local_aaa.json' | Should -Not -Exist
        Join-Path $state 'sync-log.txt' | Should -Not -Exist
        @(Get-ChildItem $state -Filter '.virt-probe-*' -Force).Count | Should -Be 0
    }

    It 'runs normally when no package mirrors the state dir' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 'aaa' | Out-Null
        $packages = Join-Path $TestDrive ("pk-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path (Join-Path $packages 'SomeApp_abc123\LocalCache\Local') | Out-Null
        Invoke-Sync $root $state -PackagesRoot $packages
        Join-Path $root 'devB/ws2/local_aaa.json' | Should -Exist
        @(Get-ChildItem $state -Filter '.virt-probe-*' -Force).Count | Should -Be 0
    }
}

Describe 'data-root discovery (packaged and unpackaged installs)' {
    BeforeAll {
        . (Join-Path $script:repo 'common.ps1')

        # $env:APPDATA is what Get-ClaudeDataRoots reads for the unpackaged
        # candidate, so a test that wants "no real root" has to move it, not
        # just point the packages root elsewhere.
        function Use-FakeAppData([scriptblock]$Body) {
            $prev = $env:APPDATA
            $env:APPDATA = Join-Path $TestDrive ("appdata-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Force -Path $env:APPDATA | Out-Null
            try { & $Body } finally { $env:APPDATA = $prev }
        }

        function New-PackagedRoot($Packages, $Package = 'Claude_pzs8sxrjxfjjc') {
            $d = Join-Path $Packages "$Package\LocalCache\Roaming\Claude"
            New-Item -ItemType Directory -Force -Path $d | Out-Null
            return $d
        }
    }

    It 'finds the sessions of an MSIX install that virtualizes Roaming' {
        Use-FakeAppData {
            $packages = Join-Path $TestDrive ("pk-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
            $packaged = New-PackagedRoot $packages
            New-Item -ItemType Directory -Force -Path (Join-Path $packaged 'claude-code-sessions\devA\ws1') | Out-Null

            $roots = @(Get-ClaudeSessionRoots $packages)

            $roots.Count | Should -Be 1
            $roots[0] | Should -Be (Join-Path $packaged 'claude-code-sessions')
        }
    }

    It 'ignores a package that is not the app, and one with no Roaming mirror' {
        Use-FakeAppData {
            $packages = Join-Path $TestDrive ("pk-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Force -Path (Join-Path $packages 'SomeApp_abc123\LocalCache\Roaming\Claude\claude-code-sessions') | Out-Null
            New-Item -ItemType Directory -Force -Path (Join-Path $packages 'Claude_pzs8sxrjxfjjc\LocalCache\Local') | Out-Null

            @(Get-ClaudeSessionRoots $packages).Count | Should -Be 0
        }
    }

    It 'keeps both roots on a half-migrated machine, migration target last' {
        Use-FakeAppData {
            $packages = Join-Path $TestDrive ("pk-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
            $real = Join-Path $env:APPDATA 'Claude'
            New-Item -ItemType Directory -Force -Path (Join-Path $real 'claude-code-sessions') | Out-Null
            $packaged = New-PackagedRoot $packages
            New-Item -ItemType Directory -Force -Path (Join-Path $packaged 'claude-code-sessions') | Out-Null
            # The engine resolves a tie toward the LAST root, so the freshest
            # (the one the app moved to) has to sort last, not first.
            [System.IO.Directory]::SetLastWriteTimeUtc($real, (Get-Date).ToUniversalTime().AddDays(-2))
            [System.IO.Directory]::SetLastWriteTimeUtc($packaged, (Get-Date).ToUniversalTime())

            $roots = @(Get-ClaudeSessionRoots $packages)

            $roots.Count | Should -Be 2
            $roots[0] | Should -Be (Join-Path $real 'claude-code-sessions')
            $roots[1] | Should -Be (Join-Path $packaged 'claude-code-sessions')
        }
    }

    It 'resolves a single-valued path to the freshest root that holds it' {
        Use-FakeAppData {
            $packages = Join-Path $TestDrive ("pk-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
            $real = Join-Path $env:APPDATA 'Claude'
            New-Item -ItemType Directory -Force -Path $real | Out-Null
            Set-Content -Path (Join-Path $real 'claude_desktop_config.json') -Value '{}' -NoNewline
            $packaged = New-PackagedRoot $packages
            Set-Content -Path (Join-Path $packaged 'claude_desktop_config.json') -Value '{}' -NoNewline
            [System.IO.Directory]::SetLastWriteTimeUtc($real, (Get-Date).ToUniversalTime().AddDays(-2))
            [System.IO.Directory]::SetLastWriteTimeUtc($packaged, (Get-Date).ToUniversalTime())

            Resolve-ClaudeDataPath 'claude_desktop_config.json' $packages |
                Should -Be (Join-Path $packaged 'claude_desktop_config.json')
        }
    }

    It 'falls back to the real %APPDATA% path when nothing holds the file' {
        Use-FakeAppData {
            $packages = Join-Path $TestDrive ("pk-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Force -Path $packages | Out-Null

            Resolve-ClaudeDataPath 'claude_desktop_config.json' $packages |
                Should -Be (Join-Path (Join-Path $env:APPDATA 'Claude') 'claude_desktop_config.json')
        }
    }
}

Describe 'scheduled tasks (three-way merge of scheduled-tasks.json)' {
    BeforeAll {
        . (Join-Path $script:repo 'task-sync.ps1')
        $script:nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $script:day = 24L * 3600 * 1000

        function Get-Iso([long]$Ms) { [DateTimeOffset]::FromUnixTimeMilliseconds($Ms).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [System.Globalization.CultureInfo]::InvariantCulture) }

        # Shape observed in Claude desktop 1.46388.x.
        function New-Task([string]$Id, [hashtable]$Props = @{}) {
            $t = New-OrdinalDict
            $t['id'] = $Id
            $t['displayName'] = "task $Id"
            if (-not $Props.ContainsKey('cronExpression')) { $t['fireAt'] = $script:nowMs + 3 * $script:day }
            $t['enabled'] = $true
            $t['filePath'] = "C:\Users\x\.claude\scheduled-tasks\$Id\SKILL.md"
            $t['createdAt'] = $script:nowMs - $script:day
            $t['cwd'] = 'C:\work'
            foreach ($k in $Props.Keys) { if ($null -eq $Props[$k]) { $t.Remove($k) } else { $t[$k] = $Props[$k] } }
            return ,$t
        }

        function Set-Tasks([string]$Ws, [object[]]$Tasks, [hashtable]$Extra = @{}) {
            $doc = New-OrdinalDict
            $list = New-Object System.Collections.ArrayList
            foreach ($t in $Tasks) { [void]$list.Add($t) }
            $doc['scheduledTasks'] = $list
            $doc['recordedSkips'] = New-OrdinalDict
            $doc['sundayAliasBoundaryStamped'] = $true
            foreach ($k in $Extra.Keys) { if ($null -eq $Extra[$k]) { $doc.Remove($k) } else { $doc[$k] = $Extra[$k] } }
            [System.IO.File]::WriteAllText((Join-Path $Ws 'scheduled-tasks.json'), (ConvertTo-TaskJson $doc), (New-Object System.Text.UTF8Encoding($false)))
        }
        function Get-TaskDoc([string]$Ws) { ConvertFrom-TaskJson ([System.IO.File]::ReadAllText((Join-Path $Ws 'scheduled-tasks.json'))) }
        function Get-Tasks([string]$Ws) { Get-TaskMap (Get-TaskDoc $Ws) }
        function Get-TaskText([string]$Ws) { [System.IO.File]::ReadAllText((Join-Path $Ws 'scheduled-tasks.json')) }
        function Get-TaskIds([string]$Ws) { $k = @((Get-Tasks $Ws).Keys); [Array]::Sort($k, [System.StringComparer]::Ordinal); $k }

        function New-AppConfig([string]$Account) {
            $p = Join-Path $TestDrive ("appcfg-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
            [System.IO.File]::WriteAllText($p, "{`n`t`"lastKnownAccountUuid`": `"$Account`"`n}")
            return $p
        }

        # Two accounts, one chat so the chat stage (and with it the task stage) runs.
        function New-TaskFixture([string[]]$Layout = @('devA/ws1', 'devB/ws2')) {
            $root = New-Fixture $Layout
            New-Chat (Join-Path $root $Layout[0]) 'c1' | Out-Null
            return $root
        }
    }

    It 'unions tasks by id across accounts, and a second run is quiet' {
        $root = New-TaskFixture; $state = New-StateDir
        $a = Join-Path $root 'devA/ws1'; $b = Join-Path $root 'devB/ws2'
        Set-Tasks $a @((New-Task 't1'))
        Set-Tasks $b @((New-Task 't2' @{ cronExpression = '0 9 * * 1'; fireAt = $null }))
        Invoke-Sync $root $state
        Get-TaskIds $a | Should -Be @('t1', 't2')
        Get-TaskIds $b | Should -Be @('t1', 't2')
        (Get-Tasks $a)['t2']['cronExpression'] | Should -Be '0 9 * * 1'
        (Get-Tasks $a)['t2'].Contains('fireAt') | Should -Be $false
        Get-Heartbeat $state | Should -Match 'tasks updated$'
        @(Get-ChildItem $state -Filter 'tasks-backup-*' -Directory).Count | Should -Be 1
        Invoke-Sync $root $state
        Get-Heartbeat $state | Should -Match 'tasks unchanged$'
    }

    It 'propagates a one-time run to every copy, so no other account can fire it again' {
        $root = New-TaskFixture; $state = New-StateDir
        $a = Join-Path $root 'devA/ws1'; $b = Join-Path $root 'devB/ws2'
        $fire = $script:nowMs + 3 * $script:day
        Set-Tasks $a @((New-Task 't1' @{ fireAt = $fire }))
        Set-Tasks $b @((New-Task 't1' @{ fireAt = $fire }))
        Invoke-Sync $root $state                                   # base
        $ran = Get-Iso ($script:nowMs)
        Set-Tasks $a @((New-Task 't1' @{ fireAt = $fire; enabled = $false; lastRunAt = $ran; lastScheduledFor = (Get-Iso $fire) }))
        Invoke-Sync $root $state
        $t = (Get-Tasks $b)['t1']
        $t['enabled'] | Should -Be $false
        $t['lastRunAt'] | Should -Be $ran
        $t['lastScheduledFor'] | Should -Be (Get-Iso $fire)
    }

    It 'lets a recorded run win over an enabled copy even before any base exists' {
        $root = New-TaskFixture; $state = New-StateDir
        $a = Join-Path $root 'devA/ws1'; $b = Join-Path $root 'devB/ws2'
        $fire = $script:nowMs - 3600000
        $ran = Get-Iso ($fire + 60000)
        Set-Tasks $a @((New-Task 't1' @{ fireAt = $fire; enabled = $false; lastRunAt = $ran }))
        Set-Tasks $b @((New-Task 't1' @{ fireAt = $fire; enabled = $true; createdAt = $script:nowMs - 60000 }))
        Invoke-Sync $root $state -AppConfig (New-AppConfig 'devB')
        foreach ($ws in $a, $b) {
            (Get-Tasks $ws)['t1']['enabled'] | Should -Be $false
            (Get-Tasks $ws)['t1']['lastRunAt'] | Should -Be $ran
        }
    }

    It 'deletes a task everywhere once the base shows it synced, and does not let a stale copy back' {
        $root = New-TaskFixture; $state = New-StateDir
        $a = Join-Path $root 'devA/ws1'; $b = Join-Path $root 'devB/ws2'
        $orig = New-Task 't1'
        Set-Tasks $a @($orig, (New-Task 'keep'))
        Set-Tasks $b @()
        Invoke-Sync $root $state
        (Get-Tasks $b).Contains('t1') | Should -Be $true
        Set-Tasks $a @((New-Task 'keep'))                          # deleted in A
        Invoke-Sync $root $state
        (Get-Tasks $b).Contains('t1') | Should -Be $false
        (Get-Tasks $b).Contains('keep') | Should -Be $true
        # A stale copy (same createdAt) reappearing is removed again ...
        Set-Tasks $b @($orig, (New-Task 'keep'))
        Invoke-Sync $root $state
        (Get-Tasks $b).Contains('t1') | Should -Be $false
        # ... but the id recreated later is a new task and propagates.
        Set-Tasks $a @((New-Task 'keep'), (New-Task 't1' @{ createdAt = $script:nowMs }))
        Invoke-Sync $root $state
        (Get-Tasks $b).Contains('t1') | Should -Be $true
    }

    It 'never deletes without a base: a task missing from one account is added there' {
        $root = New-TaskFixture; $state = New-StateDir
        $a = Join-Path $root 'devA/ws1'; $b = Join-Path $root 'devB/ws2'
        Set-Tasks $a @((New-Task 't1'))
        Set-Tasks $b @()
        Invoke-Sync $root $state
        (Get-Tasks $a).Contains('t1') | Should -Be $true
        (Get-Tasks $b).Contains('t1') | Should -Be $true
    }

    It 'takes the newest run state of a recurring task from any copy' {
        $root = New-TaskFixture; $state = New-StateDir
        $a = Join-Path $root 'devA/ws1'; $b = Join-Path $root 'devB/ws2'
        $old = Get-Iso ($script:nowMs - 2 * $script:day); $new = Get-Iso ($script:nowMs - 3600000)
        Set-Tasks $a @((New-Task 'r1' @{ cronExpression = '0 * * * *'; fireAt = $null; lastRunAt = $new; lastScheduledFor = $new }))
        Set-Tasks $b @((New-Task 'r1' @{ cronExpression = '0 * * * *'; fireAt = $null; lastRunAt = $old; lastScheduledFor = $old; missedRunScanFloor = $new }))
        Invoke-Sync $root $state
        foreach ($ws in $a, $b) {
            $t = (Get-Tasks $ws)['r1']
            $t['lastRunAt'] | Should -Be $new
            $t['lastScheduledFor'] | Should -Be $new
            $t['missedRunScanFloor'] | Should -Be $new
            $t['enabled'] | Should -Be $true
        }
    }

    It 'merges concurrent edits field by field, and breaks a tie toward the account the app last ran on' {
        $root = New-TaskFixture; $state = New-StateDir
        $a = Join-Path $root 'devA/ws1'; $b = Join-Path $root 'devB/ws2'
        Set-Tasks $a @((New-Task 'r1' @{ cronExpression = '0 9 * * *'; fireAt = $null }))
        Set-Tasks $b @((New-Task 'r1' @{ cronExpression = '0 9 * * *'; fireAt = $null }))
        Invoke-Sync $root $state
        Set-Tasks $a @((New-Task 'r1' @{ cronExpression = '30 7 * * *'; fireAt = $null; displayName = 'from A' }))
        Set-Tasks $b @((New-Task 'r1' @{ cronExpression = '0 9 * * *'; fireAt = $null; displayName = 'from B' }))
        Invoke-Sync $root $state -AppConfig (New-AppConfig 'devB')
        foreach ($ws in $a, $b) {
            $t = (Get-Tasks $ws)['r1']
            $t['displayName'] | Should -Be 'from B'                 # both changed it: the last-shown account wins
            $t['cronExpression'] | Should -Be '30 7 * * *'          # only A changed it: A's edit propagates
        }
    }

    It 'propagates a deliberate disable once a base exists (the first-run preference for live copies is first-run only)' {
        $root = New-TaskFixture; $state = New-StateDir
        $a = Join-Path $root 'devA/ws1'; $b = Join-Path $root 'devB/ws2'
        Set-Tasks $a @((New-Task 't1'))
        Set-Tasks $b @((New-Task 't1'))
        Invoke-Sync $root $state
        Set-Tasks $b @((New-Task 't1' @{ enabled = $false }))
        Invoke-Sync $root $state -AppConfig (New-AppConfig 'devA')
        (Get-Tasks $a)['t1']['enabled'] | Should -Be $false
        (Get-Tasks $a)['t1'].Contains('lastRunAt') | Should -Be $false
        Invoke-Sync $root $state
        (Get-Tasks $a)['t1']['enabled'] | Should -Be $false
        (Get-Tasks $b)['t1']['enabled'] | Should -Be $false
    }

    It 'first run after a manual move: disabled future copies neither disable the live ones nor count as a run' {
        $root = New-TaskFixture @('devOld/wsO', 'devNew/wsN'); $state = New-StateDir
        $old = Join-Path $root 'devOld/wsO'; $new = Join-Path $root 'devNew/wsN'
        New-Chat $old 'n1' | Out-Null
        $created = $script:nowMs - 60000
        $fire1 = $script:nowMs + 1 * $script:day; $fire2 = $script:nowMs + 20 * $script:day
        Set-Tasks $old @(
            (New-Task 'm1' @{ fireAt = $fire1; enabled = $false; createdAt = $script:nowMs - 5 * $script:day; notifySessionId = 'local_n1' }),
            (New-Task 'm2' @{ fireAt = $fire2; enabled = $false; createdAt = $script:nowMs - 5 * $script:day; notifySessionId = 'local_n1' }))
        Set-Tasks $new @((New-Task 'm1' @{ fireAt = $fire1; createdAt = $created }), (New-Task 'm2' @{ fireAt = $fire2; createdAt = $created }))
        $cfg = New-AppConfig 'devNew'
        $newBefore = Get-TaskText $new
        # As it happens for real: the app is open on the new account.
        Invoke-Sync $root $state -AppState running -AppConfig $cfg
        Get-TaskText $new | Should -Be $newBefore
        foreach ($id in 'm1', 'm2') {
            $t = (Get-Tasks $old)[$id]
            $t['enabled'] | Should -Be $true
            $t['createdAt'] | Should -Be $created
            $t.Contains('lastRunAt') | Should -Be $false
            $t['notifySessionId'] | Should -Be 'local_n1'
        }
        # The app closes: the new account catches up, still live, still unrun.
        Invoke-Sync $root $state -AppState closed -AppConfig $cfg
        foreach ($ws in $old, $new) {
            foreach ($id in 'm1', 'm2') {
                $t = (Get-Tasks $ws)[$id]
                $t['enabled'] | Should -Be $true
                $t.Contains('lastRunAt') | Should -Be $false
            }
        }
        (Get-Tasks $new)['m1']['notifySessionId'] | Should -Be 'local_n1'
    }

    It 'enables a one-time task about to fire in one account only, and lifts the hold when it is rescheduled' {
        $root = New-TaskFixture; $state = New-StateDir
        $a = Join-Path $root 'devA/ws1'; $b = Join-Path $root 'devB/ws2'
        $cfg = New-AppConfig 'devA'
        $soon = $script:nowMs + 5 * 60000
        Set-Tasks $a @((New-Task 'h1' @{ fireAt = $soon }))
        Set-Tasks $b @((New-Task 'h1' @{ fireAt = $soon }))
        Invoke-Sync $root $state -AppConfig $cfg
        (Get-Tasks $a)['h1']['enabled'] | Should -Be $true
        (Get-Tasks $b)['h1']['enabled'] | Should -Be $false
        # A fires it; the run reaches B, which never becomes due.
        $ran = Get-Iso ($soon + 1000)
        Set-Tasks $a @((New-Task 'h1' @{ fireAt = $soon; enabled = $false; lastRunAt = $ran }))
        Invoke-Sync $root $state -AppConfig $cfg
        (Get-Tasks $b)['h1']['enabled'] | Should -Be $false
        (Get-Tasks $b)['h1']['lastRunAt'] | Should -Be $ran
        # Rescheduled far out in A (the app clears lastRunAt): live everywhere again.
        $later = $script:nowMs + 10 * $script:day
        Set-Tasks $a @((New-Task 'h1' @{ fireAt = $later; enabled = $true }))
        Invoke-Sync $root $state -AppConfig $cfg
        foreach ($ws in $a, $b) {
            $t = (Get-Tasks $ws)['h1']
            $t['enabled'] | Should -Be $true
            $t['fireAt'] | Should -Be $later
            $t.Contains('lastRunAt') | Should -Be $false
        }
    }

    It 'while the app runs, never writes the running account and still updates the others' {
        $root = New-TaskFixture; $state = New-StateDir
        $a = Join-Path $root 'devA/ws1'; $b = Join-Path $root 'devB/ws2'
        Set-Tasks $a @((New-Task 't1'))
        Set-Tasks $b @((New-Task 't2'))
        $aBefore = Get-TaskText $a
        Invoke-Sync $root $state -AppState running -AppConfig (New-AppConfig 'devA')
        Get-TaskText $a | Should -Be $aBefore
        Get-TaskIds $b | Should -Be @('t1', 't2')
        Get-Heartbeat $state | Should -Match 'tasks updated$'
        (Get-Content (Join-Path $state 'sync-log.txt') -Raw) | Should -Match 'devA/ws1 is the account the app runs on'
        # Nothing left to write but A's catch-up: deferred, not success.
        Invoke-Sync $root $state -AppState running -AppConfig (New-AppConfig 'devA')
        Get-Heartbeat $state | Should -Match 'tasks deferred$'
        Get-TaskText $a | Should -Be $aBefore
    }

    It 'defers, writing nothing, when the app runs on an account it cannot identify' {
        $root = New-TaskFixture; $state = New-StateDir
        $a = Join-Path $root 'devA/ws1'; $b = Join-Path $root 'devB/ws2'
        Set-Tasks $a @((New-Task 't1'))
        Set-Tasks $b @((New-Task 't2'))
        $aBefore = Get-TaskText $a; $bBefore = Get-TaskText $b
        Invoke-Sync $root $state -AppState running
        Get-Heartbeat $state | Should -Match 'tasks deferred$'
        Get-TaskText $a | Should -Be $aBefore
        Get-TaskText $b | Should -Be $bBefore
        Join-Path $state 'tasks-base.json' | Should -Not -Exist
    }

    It 'defers, writing nothing, while a task file is locked, and merges once it is free' {
        $root = New-TaskFixture; $state = New-StateDir
        $a = Join-Path $root 'devA/ws1'; $b = Join-Path $root 'devB/ws2'
        Set-Tasks $a @((New-Task 't1'))
        Set-Tasks $b @((New-Task 't2'))
        $aBefore = Get-TaskText $a
        $lock = [System.IO.File]::Open((Join-Path $b 'scheduled-tasks.json'), 'Open', 'ReadWrite', 'None')
        try { Invoke-Sync $root $state } finally { $lock.Dispose() }
        Get-Heartbeat $state | Should -Match 'tasks deferred$'
        Get-TaskText $a | Should -Be $aBefore
        @(Get-ChildItem $b -Filter '*.cs-tmp-*').Count | Should -Be 0
        Invoke-Sync $root $state
        Get-Heartbeat $state | Should -Match 'tasks updated$'
        Get-TaskIds $a | Should -Be @('t1', 't2')
    }

    It 'keeps runRetries and the stamped markers per file, drops a notification target whose chat is absent, and -WhatIf writes nothing' {
        $root = New-TaskFixture; $state = New-StateDir
        $a = Join-Path $root 'devA/ws1'; $b = Join-Path $root 'devB/ws2'
        $retry = New-OrdinalDict; $slot = New-OrdinalDict
        $slot['slot'] = Get-Iso $script:nowMs; $slot['attempts'] = 1; $slot['notBefore'] = $null
        $retry['t1'] = $slot
        Set-Tasks $a @((New-Task 't1' @{ notifySessionId = 'local_missing' })) @{ runRetries = $retry; dayFieldsOrBoundaryStamped = $true }
        Set-Tasks $b @() @{ sundayAliasBoundaryStamped = $null }
        $bBefore = Get-TaskText $b
        $out = Invoke-Sync $root $state -WhatIf -Loud 6>&1
        # Under -WhatIf the log is a previewed write too: read the console.
        ($out | Out-String) | Should -Match 'tasks would be merged'
        ($out | Out-String) | Should -Match 'tasks would-update'
        Get-TaskText $b | Should -Be $bBefore
        Join-Path $state 'tasks-base.json' | Should -Not -Exist
        Invoke-Sync $root $state
        $docB = Get-TaskDoc $b
        (Get-TaskMap $docB)['t1'].Contains('notifySessionId') | Should -Be $false
        $docB.Contains('runRetries') | Should -Be $false
        $docB.Contains('dayFieldsOrBoundaryStamped') | Should -Be $false
        $docB.Contains('sundayAliasBoundaryStamped') | Should -Be $false
        (Get-TaskDoc $a)['runRetries'].Contains('t1') | Should -Be $true
    }

    It 'round-trips the app file byte for byte, non-ASCII names included' {
        $text = "{`n  `"scheduledTasks`": [`n    {`n      `"id`": `"x`",`n      `"displayName`": `"n" + [char]0xE6 + "vn \`"q\`"`",`n      `"fireAt`": 1790928000000,`n      `"enabled`": true,`n      `"lastRunAt`": `"2026-09-29T20:00:00.000Z`"`n    }`n  ],`n  `"recordedSkips`": {}`n}"
        ConvertTo-TaskJson (ConvertFrom-TaskJson $text) | Should -BeExactly $text
        (ConvertFrom-TaskJson $text)['scheduledTasks'][0]['lastRunAt'] | Should -BeOfType [string]
    }
}
