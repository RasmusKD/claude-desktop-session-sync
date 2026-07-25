# Pester 5 tests for the sync engine, run against a fixture tree via -RootsOverride.
# Covers the failure modes from the pre-publication adversarial review:
# cross-account propagation, damaged-never-beats-healthy, unknown-destination
# protection, multi-workspace device skip, fresh-account seeding, and -WhatIf.

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
        param($Layout)   # @{ 'devA/ws1' = @(); 'devB/ws2' = @() } - dirs to create
        $root = Join-Path $TestDrive ("root-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        foreach ($rel in $Layout) { New-Item -ItemType Directory -Force -Path (Join-Path $root $rel) | Out-Null }
        return $root
    }

    function Invoke-Sync($Root, [switch]$WhatIf) {
        if ($WhatIf) { & $script:engine -RootsOverride $Root -Quiet -WhatIf }
        else         { & $script:engine -RootsOverride $Root -Quiet -Confirm:$false }
    }
}

Describe 'cross-account propagation' {
    It 'copies a chat from one account into another account single workspace' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2')
        New-Chat (Join-Path $root 'devA/ws1') 'aaa' | Out-Null
        New-Chat (Join-Path $root 'devB/ws2') 'bbb' | Out-Null
        Invoke-Sync $root
        Join-Path $root 'devB/ws2/local_aaa.json' | Should -Exist
        Join-Path $root 'devA/ws1/local_bbb.json' | Should -Exist
    }

    It 'seeds a fresh account whose workspace folder is still empty' {
        $root = New-Fixture @('devA/ws1', 'devFresh/wsNew')
        New-Chat (Join-Path $root 'devA/ws1') 'aaa' | Out-Null
        Invoke-Sync $root
        Join-Path $root 'devFresh/wsNew/local_aaa.json' | Should -Exist
    }
}

Describe 'health rules' {
    It 'never lets a newer damaged copy beat an older healthy one - and heals the damaged side' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2')
        New-Chat (Join-Path $root 'devA/ws1') 'ccc' -Kind damaged -AgeMinutes 0  | Out-Null
        New-Chat (Join-Path $root 'devB/ws2') 'ccc' -Kind healthy -AgeMinutes 60 | Out-Null
        Invoke-Sync $root
        Get-Content (Join-Path $root 'devB/ws2/local_ccc.json') -Raw | Should -Not -Match 'transcriptUnavailable'
        Get-Content (Join-Path $root 'devA/ws1/local_ccc.json') -Raw | Should -Not -Match 'transcriptUnavailable'
    }

    It 'does not overwrite an unreadable (locked) destination with a damaged winner' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2')
        New-Chat (Join-Path $root 'devA/ws1') 'ddd' -Kind damaged | Out-Null
        $dst = New-Chat (Join-Path $root 'devB/ws2') 'ddd' -Kind junk -AgeMinutes 60   # junk parses as damaged when readable
        New-Chat (Join-Path $root 'devB/ws2') 'filler' | Out-Null                       # keep devB a source
        $lock = [System.IO.File]::Open($dst, 'Open', 'Read', 'None')                    # now unreadable -> unknown
        try { Invoke-Sync $root } finally { $lock.Dispose() }
        Get-Content $dst -Raw | Should -Not -Match 'transcriptUnavailable'
    }
}

Describe 'device guards' {
    It 'skips a device with multiple chat-bearing workspaces instead of blending them' {
        $root = New-Fixture @('devA/ws1', 'devA/ws2', 'devB/ws3')
        New-Chat (Join-Path $root 'devA/ws1') 'e1' | Out-Null
        New-Chat (Join-Path $root 'devA/ws2') 'e2' | Out-Null
        New-Chat (Join-Path $root 'devB/ws3') 'e3' | Out-Null
        Invoke-Sync $root
        # devA skipped entirely -> only devB remains -> fewer than 2 targets -> nothing moves
        Join-Path $root 'devB/ws3/local_e1.json' | Should -Not -Exist
        Join-Path $root 'devA/ws1/local_e2.json' | Should -Not -Exist
        Join-Path $root 'devA/ws1/local_e3.json' | Should -Not -Exist
    }
}

Describe 'dry run' {
    It '-WhatIf changes nothing' {
        $root = New-Fixture @('devA/ws1', 'devB/ws2')
        New-Chat (Join-Path $root 'devA/ws1') 'fff' | Out-Null
        New-Chat (Join-Path $root 'devB/ws2') 'ggg' | Out-Null
        Invoke-Sync $root -WhatIf
        Join-Path $root 'devB/ws2/local_fff.json' | Should -Not -Exist
        Join-Path $root 'devA/ws1/local_ggg.json' | Should -Not -Exist
    }
}
