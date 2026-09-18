# Pester 5 tests for the sync engine, run against fixture trees via -RootsOverride.
# Covers: cross-account propagation, seeding, health rules (healing, title
# false-positives), device guards, deletion propagation (partial-failure
# non-resurrection, freeze durability, stash retention and quality), sidebar
# groups (three-way merge in a fixture Local Storage LevelDB, the app-running
# refusal, the config mirror's byte fidelity, BOM and decoy anchors), the MSIX
# shadow refusal, and -WhatIf inertness.

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
        param($Root, $StateDir, [switch]$WhatIf, [switch]$Loud, [string]$ConfigPath = '', [string]$LevelDb = '', [string]$HelperDir = '', [string]$PackagesRoot = '')
        $p = @{ RootsOverride = $Root; StateDirOverride = $StateDir; Quiet = (-not $Loud) }
        $p.LevelDbPathOverride = if ($LevelDb) { $LevelDb } else { Join-Path $TestDrive 'no-leveldb-here' }
        $p.ConfigPathOverride  = if ($ConfigPath) { $ConfigPath } else { Join-Path $TestDrive 'no-config-here.json' }
        if ($HelperDir)    { $p.GroupHelperOverride = $HelperDir }
        if ($PackagesRoot) { $p.PackagesRootOverride = $PackagesRoot }
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
        Get-Heartbeat $state | Should -Match 'groups off$'
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
        Get-Heartbeat $state | Should -Match 'groups updated$'
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
        Get-Heartbeat $state | Should -Match 'groups unchanged$'
        Join-Path $state 'groups-base.json' | Should -Exist
        # A deletes cg-1 (and its assignment); B renames cg-2.
        $a = New-ScopeEntry @(@{ id = 'cg-2'; name = 'two' }) @{ 'code:local_bbb' = 'cg-2' } @{ 'cg-2' = @('code:local_bbb') }
        $b = New-ScopeEntry @(@{ id = 'cg-1'; name = 'one' }, @{ id = 'cg-2'; name = 'Two!' }) @{ 'code:local_aaa' = 'cg-1'; 'code:local_bbb' = 'cg-2' } @{ 'cg-1' = @('code:local_aaa'); 'cg-2' = @('code:local_bbb') }
        $ldb2 = New-LevelDb @{ 'devA/ws1' = $a; 'devB/ws2' = $b } -LastScope 'devB/ws2'
        Invoke-Sync $root $state -LevelDb $ldb2
        Get-Heartbeat $state | Should -Match 'groups updated$'
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
        Get-Heartbeat $state | Should -Match 'groups updated$'
        foreach ($scope in 'devA/ws1', 'devB/ws2') { @((Get-ScopeFromStore $ldb1 $scope).groups).id | Sort-Object | Should -Be @('cg-collect', 'cg-skole') }
        Read-LevelDbText $ldb1 'ccd-sync-pending:ccd/dframe-store' | Should -Be 'devA/ws1'   # A pushes its local state at the next start
        $merged = Get-ScopeFromStore $ldb1 'devA/ws1'
        # 2. The user relogs into B: the switch discards the marker unpushed, and B's
        #    server row replaces B's local list, dropping skole and its two members.
        $switchAfter = [string]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
        $ldb2 = New-LevelDb @{ 'devA/ws1' = $merged; 'devB/ws2' = $collect } -LastScope 'devB/ws2' -Extra @{ 'ccd-sync-owner' = 'devB'; 'epitaxy-context-usage-logout-at' = $switchAfter }
        Invoke-Sync $root $state -LevelDb $ldb2
        Get-Heartbeat $state | Should -Match 'groups updated$'
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
        Get-Heartbeat $state | Should -Match 'groups updated$'
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
        Get-Heartbeat $state | Should -Match 'groups updated$'
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
        Get-Heartbeat $state | Should -Match 'groups deferred$'
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
        Get-Heartbeat $state | Should -Match 'groups mirrored$'
        $parsed = Get-Content $cfg -Raw | ConvertFrom-Json
        @($parsed.preferences.epitaxyPrefs.'dframe-group-scopes'.'devB/ws2'.groups)[0].id | Should -Be 'cg-1'
    }

    It 'reports groups off, and still syncs chats, when the helper is missing' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 'aaa' | Out-Null
        $ldb = New-LevelDb @{ 'devA/ws1' = New-ScopeEntry @(@{ id = 'cg-1'; name = 'one' }); 'devB/ws2' = New-ScopeEntry @() }
        Invoke-Sync $root $state -LevelDb $ldb -HelperDir (Join-Path $TestDrive 'no-helper')
        Get-Heartbeat $state | Should -Match 'groups off$'
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
