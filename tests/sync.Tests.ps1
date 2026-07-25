# Pester 5 tests for the sync engine, run against fixture trees via -RootsOverride.
# Covers: cross-account propagation, fresh-account seeding, health rules (including
# healing and title false-positives), multi-workspace device skip, deletion
# propagation with its fresh-account guard, partial-deletion non-resurrection,
# delete-all freezing, stash quality, config splice fidelity, and -WhatIf inertness.

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

    It 'does not overwrite an unreadable (locked) destination with a damaged winner' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 'ddd' -Kind damaged | Out-Null
        $dst = New-Chat (Join-Path $root 'devB/ws2') 'ddd' -Kind junk -AgeMinutes 60
        New-Chat (Join-Path $root 'devB/ws2') 'filler' | Out-Null
        $lock = [System.IO.File]::Open($dst, 'Open', 'Read', 'None')
        try { Invoke-Sync $root $state } finally { $lock.Dispose() }
        Get-Content $dst -Raw | Should -Not -Match 'transcriptUnavailable'
    }

    It 'a title containing the literal damage marker does not poison health' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 'ttt' -Kind markerTitle -AgeMinutes 0 | Out-Null
        New-Chat (Join-Path $root 'devB/ws2') 'ttt' -Kind healthy -AgeMinutes 60 | Out-Null
        Invoke-Sync $root $state
        # The newer marker-title copy is HEALTHY, so it must win over the older copy.
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
        Join-Path $root 'devA/ws1/local_x1.json' | Should -Not -Exist   # not resurrected
        Invoke-Sync $root $state                                        # retry completes
        $held | Should -Not -Exist
        Join-Path $root 'devA/ws1/local_x1.json' | Should -Not -Exist
    }

    It 'freezes an account that held chats and is suddenly empty (no reseed, no mass delete)' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 'aaa' | Out-Null
        Invoke-Sync $root $state
        Invoke-Sync $root $state    # second run records BOTH workspaces as sources
        Get-ChildItem (Join-Path $root 'devB/ws2') -Filter 'local_*.json' | Remove-Item
        Invoke-Sync $root $state
        @(Get-ChildItem (Join-Path $root 'devB/ws2') -Filter 'local_*.json').Count | Should -Be 0   # not reseeded
        Join-Path $root 'devA/ws1/local_aaa.json' | Should -Exist                                    # not deleted
    }

    It 'stashes the healthiest newest copy with the device id in the name' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2', 'devC/ws3'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 's1' | Out-Null
        New-Chat (Join-Path $root 'devA/ws1') 'keep' | Out-Null
        Invoke-Sync $root $state
        Remove-Item (Join-Path $root 'devA/ws1/local_s1.json')
        # devB's copy becomes the fresh edit; devC's stays stale.
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
        $cfgPath = Join-Path $TestDrive ("cfg-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
        # Untouched sections carry every 5.1 round-trip hazard: an ISO date string,
        # a single-element array, plus a group with an extra property and a sibling
        # key next to groups/order. All must survive byte-for-byte or verbatim.
        $cfgText = '{"first_launch_at":"2026-01-02T03:04:05.678Z","trusted":["C:\\one"],"preferences":{"epitaxyPrefs":{"dframe-group-scopes":{"devA/ws1":{"groups":[{"id":"cg-1","name":"grp","color":"red"}],"order":{"cg-1":["code:local_aaa"]},"pinnedOrder":["code:local_aaa"]}}}}}'
        Set-Content -Path $cfgPath -Value $cfgText -NoNewline
        Invoke-Sync $root $state -ConfigPath $cfgPath
        $after = Get-Content $cfgPath -Raw
        $after | Should -Match '"first_launch_at":"2026-01-02T03:04:05\.678Z"'   # date untouched
        $after | Should -Match '\["C:\\\\one"\]'                                  # single-element array untouched
        $cfg = $after | ConvertFrom-Json
        $b = $cfg.preferences.epitaxyPrefs.'dframe-group-scopes'.'devB/ws2'
        $b | Should -Not -BeNullOrEmpty
        @($b.groups)[0].color | Should -Be 'red'                                  # unknown property preserved
        @($b.pinnedOrder) | Should -Contain 'code:local_aaa'                      # sibling key preserved
    }

    It '-WhatIf leaves the config untouched' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 'aaa' | Out-Null
        $cfgPath = Join-Path $TestDrive ("cfg-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
        Set-Content -Path $cfgPath -Value '{"preferences":{"epitaxyPrefs":{"dframe-group-scopes":{"devA/ws1":{"groups":[{"id":"cg-9","name":"g"}],"order":{}}}}}}' -NoNewline
        $before = Get-Content $cfgPath -Raw
        Invoke-Sync $root $state -WhatIf -ConfigPath $cfgPath
        (Get-Content $cfgPath -Raw) | Should -Be $before
    }
}
