# Pester 5 tests for the sync engine, run against fixture trees via -RootsOverride.
# Covers: cross-account propagation, fresh-account seeding, damaged-never-beats-
# healthy (and healing), locked-destination protection, multi-workspace device skip,
# deletion propagation with its fresh-account guard, config group mirroring, and
# -WhatIf inertness.

BeforeAll {
    $script:engine = Join-Path (Split-Path $PSScriptRoot -Parent) 'sync-claude-sessions.ps1'

    function New-Chat {
        param($Dir, $Name, [ValidateSet('healthy','damaged','junk')]$Kind = 'healthy', $AgeMinutes = 0)
        $json = switch ($Kind) {
            'healthy' { '{"sessionId":"' + $Name + '","cliSessionId":"cli-' + $Name + '","title":"t"}' }
            'damaged' { '{"sessionId":"' + $Name + '","cliSessionId":"cli-' + $Name + '","transcriptUnavailable":true}' }
            'junk'    { '{"sessionId":"' + $Name + '"}' }
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
        $args = @{ RootsOverride = $Root; StateDirOverride = $StateDir; Quiet = $true }
        if ($ConfigPath) { $args.ConfigPathOverride = $ConfigPath }
        if ($WhatIf) { & $script:engine @args -WhatIf }
        else         { & $script:engine @args -Confirm:$false }
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
        Invoke-Sync $root $state    # propagates both, manifest records full set
        Join-Path $root 'devB/ws2/local_del1.json' | Should -Exist
        Remove-Item (Join-Path $root 'devA/ws1/local_del1.json')
        Invoke-Sync $root $state
        Join-Path $root 'devB/ws2/local_del1.json' | Should -Not -Exist
        @(Get-ChildItem (Join-Path $state 'deleted') -Filter '*local_del1.json').Count | Should -Be 1
        Join-Path $root 'devB/ws2/local_keep1.json' | Should -Exist
    }

    It 'treats an empty fresh account as a seed target, never as deletion evidence' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 'aaa' | Out-Null
        Invoke-Sync $root $state    # manifest now holds aaa (present in both)
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'devC/wsNew') | Out-Null
        Invoke-Sync $root $state
        Join-Path $root 'devA/ws1/local_aaa.json' | Should -Exist
        Join-Path $root 'devB/ws2/local_aaa.json' | Should -Exist
        Join-Path $root 'devC/wsNew/local_aaa.json' | Should -Exist
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

Describe 'config mirroring' {
    It 'mirrors sidebar groups to every account scope key' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 'aaa' | Out-Null
        $cfgPath = Join-Path $TestDrive ("cfg-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
        @{
            preferences = @{
                epitaxyPrefs = @{
                    'dframe-group-scopes' = @{
                        'devA/ws1' = @{
                            groups = @(@{ id = 'cg-1'; name = 'grp' })
                            order  = @{ 'cg-1' = @('code:local_aaa') }
                        }
                    }
                }
            }
        } | ConvertTo-Json -Depth 10 | Set-Content -Path $cfgPath
        Invoke-Sync $root $state -ConfigPath $cfgPath
        $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
        $scope = $cfg.preferences.epitaxyPrefs.'dframe-group-scopes'.'devB/ws2'
        $scope | Should -Not -BeNullOrEmpty
        @($scope.groups)[0].id | Should -Be 'cg-1'
        @($scope.order.'cg-1') | Should -Contain 'code:local_aaa'
    }

    It '-WhatIf leaves the config untouched' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2'); $state = New-StateDir
        New-Chat (Join-Path $root 'devA/ws1') 'aaa' | Out-Null
        $cfgPath = Join-Path $TestDrive ("cfg-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
        @{ preferences = @{ epitaxyPrefs = @{ 'dframe-group-scopes' = @{ 'devA/ws1' = @{ groups = @(@{ id = 'cg-9'; name = 'g' }); order = @{} } } } } } |
            ConvertTo-Json -Depth 10 | Set-Content -Path $cfgPath
        $before = Get-Content $cfgPath -Raw
        Invoke-Sync $root $state -WhatIf -ConfigPath $cfgPath
        (Get-Content $cfgPath -Raw) | Should -Be $before
    }
}
