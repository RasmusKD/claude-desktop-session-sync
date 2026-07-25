# Pester 5 tests for the sync engine, run against fixture trees via -RootsOverride.
# Covers: cross-account propagation, seeding, health rules (healing, title
# false-positives), device guards, deletion propagation (partial-failure
# non-resurrection, freeze durability, stash retention and quality), config
# splice fidelity (verbatim bytes, case-sensitivity, duplicate-key refusal,
# decoy anchors, BOM preservation), and -WhatIf inertness.

BeforeAll {
    $script:engine = Join-Path (Split-Path $PSScriptRoot -Parent) 'sync-claude-sessions.ps1'

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

    function Invoke-Sync {
        param($Root, $StateDir, [switch]$WhatIf, [string]$ConfigPath = '')
        $p = @{ RootsOverride = $Root; StateDirOverride = $StateDir; Quiet = $true }
        if ($ConfigPath) { $p.ConfigPathOverride = $ConfigPath }
        if ($WhatIf) { & $script:engine @p -WhatIf }
        else         { & $script:engine @p -Confirm:$false }
    }

    function New-Config([string]$Text) {
        $p = Join-Path $TestDrive ("cfg-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
        Set-Content -Path $p -Value $Text -NoNewline
        return $p
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

Describe 'config mirroring (raw splice)' {
    It 'copies the active account scope entry verbatim and leaves every other byte untouched' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 'aaa' | Out-Null
        $cfgPath = New-Config '{"first_launch_at":"2026-01-02T03:04:05.678Z","trusted":["C:\\one"],"preferences":{"epitaxyPrefs":{"dframe-group-scopes":{"devA/ws1":{"groups":[{"id":"cg-1","name":"grp","color":"red"}],"order":{"cg-1":["code:local_aaa"]},"pinnedOrder":["code:local_aaa"]}}}}}'
        Invoke-Sync $root $state -ConfigPath $cfgPath
        $after = Get-Content $cfgPath -Raw
        $after | Should -Match '"first_launch_at":"2026-01-02T03:04:05\.678Z"'
        $after | Should -Match '\["C:\\\\one"\]'
        $cfg = $after | ConvertFrom-Json
        $b = $cfg.preferences.epitaxyPrefs.'dframe-group-scopes'.'devB/ws2'
        $b | Should -Not -BeNullOrEmpty
        @($b.groups)[0].color | Should -Be 'red'
        @($b.pinnedOrder) | Should -Contain 'code:local_aaa'
    }

    It 'propagates a case-only group rename via the consensus tiebreak' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 'aaa' | Out-Null
        $cfgPath = New-Config '{"preferences":{"epitaxyPrefs":{"dframe-group-scopes":{"devA/ws1":{"groups":[{"id":"cg-1","name":"work"}],"order":{}}}}}}'
        Invoke-Sync $root $state -ConfigPath $cfgPath          # mirrors to devB, records consensus
        Invoke-Sync $root $state -ConfigPath $cfgPath          # steady state, consensus confirmed
        $t = Get-Content $cfgPath -Raw
        # Ordinal: culture-sensitive IndexOf (th-TH) matches at shifted positions
        # and would corrupt the fixture, which the engine then rightly refuses.
        $i = $t.IndexOf('"name":"work"', [System.StringComparison]::Ordinal)
        $t = $t.Substring(0, $i) + '"name":"Work"' + $t.Substring($i + '"name":"work"'.Length)
        Set-Content -Path $cfgPath -Value $t -NoNewline
        Invoke-Sync $root $state -ConfigPath $cfgPath          # divergent entry wins the tie
        $after = Get-Content $cfgPath -Raw
        ([regex]::Matches($after, '"name":"Work"')).Count | Should -Be 2
    }

    It 'refuses to insert a duplicate when the key exists in another escape encoding' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 'aaa' | Out-Null
        $before = '{"preferences":{"epitaxyPrefs":{"dframe-group-scopes":{"devA/ws1":{"groups":[{"id":"cg-1","name":"g"}],"order":{}},"devB\u002fws2":{"groups":[]}}}}}'
        $cfgPath = New-Config $before
        Invoke-Sync $root $state -ConfigPath $cfgPath
        (Get-Content $cfgPath -Raw) | Should -Be $before                      # untouched
        Join-Path $state 'CONFIG-MIRROR-BROKEN.txt' | Should -Exist           # loudly refused
    }

    It 'anchors on the real preferences path, never a decoy occurrence elsewhere' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 'aaa' | Out-Null
        $cfgPath = New-Config '{"backupOfOldProfile":{"epitaxyPrefs":{"dframe-group-scopes":{"devA/ws1":{"groups":[{"id":"cg-9","name":"DECOY"}],"order":{}}}}},"preferences":{"epitaxyPrefs":{"dframe-group-scopes":{"devA/ws1":{"groups":[{"id":"cg-1","name":"real"}],"order":{}}}}}}'
        Invoke-Sync $root $state -ConfigPath $cfgPath
        $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
        $cfg.preferences.epitaxyPrefs.'dframe-group-scopes'.'devB/ws2' | Should -Not -BeNullOrEmpty
        @($cfg.preferences.epitaxyPrefs.'dframe-group-scopes'.'devB/ws2'.groups)[0].name | Should -Be 'real'
        $cfg.backupOfOldProfile.epitaxyPrefs.'dframe-group-scopes'.PSObject.Properties.Name | Should -Not -Contain 'devB/ws2'
    }

    It 'preserves a UTF-8 BOM across a splice' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 'aaa' | Out-Null
        $cfgPath = Join-Path $TestDrive ("cfg-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
        $body = '{"preferences":{"epitaxyPrefs":{"dframe-group-scopes":{"devA/ws1":{"groups":[{"id":"cg-1","name":"g"}],"order":{}}}}}}'
        [System.IO.File]::WriteAllText($cfgPath, $body, (New-Object System.Text.UTF8Encoding($true)))
        Invoke-Sync $root $state -ConfigPath $cfgPath
        $bytes = [System.IO.File]::ReadAllBytes($cfgPath)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeTrue
        { Get-Content $cfgPath -Raw | ConvertFrom-Json } | Should -Not -Throw
    }

    It '-WhatIf leaves the config untouched' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 'aaa' | Out-Null
        $cfgPath = New-Config '{"preferences":{"epitaxyPrefs":{"dframe-group-scopes":{"devA/ws1":{"groups":[{"id":"cg-9","name":"g"}],"order":{}}}}}}'
        $before = Get-Content $cfgPath -Raw
        Invoke-Sync $root $state -WhatIf -ConfigPath $cfgPath
        (Get-Content $cfgPath -Raw) | Should -Be $before
    }
}
