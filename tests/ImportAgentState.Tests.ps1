BeforeAll {
    $Path = Join-Path $PSScriptRoot '../Import-AgentState.ps1'
    $Tokens=$null; $Errors=$null
    $Ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$Tokens,[ref]$Errors)
    if($Errors.Count){throw $Errors[0]}
    $Definitions=$Ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)
    . ([scriptblock]::Create(($Definitions | ForEach-Object {$_.Extent.Text}) -join "`n"))
}

Describe 'Manual import safety' {
    BeforeEach {
        $Project=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $Native=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $Source=Join-Path $Project '.agent-state/codex/sessions'
        [void][IO.Directory]::CreateDirectory($Source)
        [void][IO.Directory]::CreateDirectory($Native)
        $Config=[pscustomobject]@{agents=@([pscustomobject]@{name='codex';routingMode='codex';targetSubDir='.agent-state/codex/sessions';localPath=$Native})}
        $Session=Join-Path $Source 'test.jsonl'
        [IO.File]::WriteAllText($Session,(@{type='session_meta';payload=@{cwd=$Project;id='fixture'}}|ConvertTo-Json -Compress)+"`n")
    }

    It 'plans without writing and atomically creates only the verified missing file' {
        $Plan=Get-AgentSyncImportPlan -ProjectRoot $Project -Config $Config
        $Plan.ToCopy | Should -Be 1
        @(Get-ChildItem $Native -File).Count | Should -Be 0
        Invoke-AgentSyncImportPlan -Plan $Plan | Should -Be 1
        (Get-FileHash (Join-Path $Native 'test.jsonl')).Hash | Should -Be (Get-FileHash $Session).Hash
        (Get-Item (Join-Path $Native 'test.jsonl')).LastWriteTimeUtc | Should -Be (Get-Item $Session).LastWriteTimeUtc
        (Get-AgentSyncImportPlan -ProjectRoot $Project -Config $Config).Identical | Should -Be 1
    }

    It 'does not call equal-size divergent content identical or overwrite it' {
        $Target=Join-Path $Native 'test.jsonl'
        $Content=[IO.File]::ReadAllText($Session).Replace('fixture','changed')
        [IO.File]::WriteAllText($Target,$Content)
        $Before=(Get-FileHash $Target).Hash
        $Plan=Get-AgentSyncImportPlan -ProjectRoot $Project -Config $Config
        $Plan.Identical | Should -Be 0
        $Plan.Blocked | Should -BeGreaterThan 0
        {Invoke-AgentSyncImportPlan -Plan $Plan} | Should -Throw
        (Get-FileHash $Target).Hash | Should -Be $Before
    }

    It 'rejects a source rewrite after the plan' {
        $Plan=Get-AgentSyncImportPlan -ProjectRoot $Project -Config $Config
        [IO.File]::WriteAllText($Session,'{"different":true}')
        {Invoke-AgentSyncImportPlan -Plan $Plan} | Should -Throw
        Test-Path (Join-Path $Native 'test.jsonl') | Should -BeFalse
    }

    It 'never overwrites a destination created after planning' {
        $Plan=Get-AgentSyncImportPlan -ProjectRoot $Project -Config $Config
        $Target=Join-Path $Native 'test.jsonl'
        [IO.File]::WriteAllText($Target,'native writer work')
        {Invoke-AgentSyncImportPlan -Plan $Plan} | Should -Throw
        [IO.File]::ReadAllText($Target) | Should -BeExactly 'native writer work'
    }

    It 'blocks unsupported provider restoration rather than copying an export into its database root' {
        $Config.agents[0].routingMode='opencode'
        $Config.agents[0].name='opencode'
        $Plan=Get-AgentSyncImportPlan -ProjectRoot $Project -Config $Config
        $Plan.Blocked | Should -BeGreaterThan 0
        ($Plan.Problems -join ' ') | Should -Match 'PROVIDER_RESTORE_UNSUPPORTED'
        {Invoke-AgentSyncImportPlan -Plan $Plan} | Should -Throw
    }

    It 'rejects traversal in configured source paths' {
        $Config.agents[0].targetSubDir='../outside'
        {Get-AgentSyncImportPlan -ProjectRoot $Project -Config $Config} | Should -Throw
    }

    It 'preserves archived Codex choices instead of resurrecting an active session' {
        $Archive=Join-Path $TestDrive 'archived-native'
        [void][IO.Directory]::CreateDirectory($Archive)
        Copy-Item $Session (Join-Path $Archive 'test.jsonl')
        $Config.agents[0] | Add-Member skipRestoreIfPresentIn @($Archive)
        $Plan=Get-AgentSyncImportPlan -ProjectRoot $Project -Config $Config
        $Plan.ToCopy | Should -Be 0
        $Plan.PreservedElsewhere | Should -Be 1
    }

    It 'does not count a same-name divergent archive as preserved history' {
        $Archive=Join-Path $TestDrive 'divergent-archive'
        [void][IO.Directory]::CreateDirectory($Archive)
        [IO.File]::WriteAllText((Join-Path $Archive 'test.jsonl'),'different archived history')
        $Config.agents[0] | Add-Member skipRestoreIfPresentIn @($Archive)
        $Plan=Get-AgentSyncImportPlan -ProjectRoot $Project -Config $Config
        $Plan.PreservedElsewhere | Should -Be 0
        $Plan.ToCopy | Should -Be 0
        $Plan.Blocked | Should -BeGreaterThan 0
        {Invoke-AgentSyncImportPlan $Plan} | Should -Throw
        Test-Path (Join-Path $Native 'test.jsonl') | Should -BeFalse
    }

    It 'finds a verified identical archive among several same-name candidates' {
        $Archive=Join-Path $TestDrive 'multiple-archive-candidates'
        [void][IO.Directory]::CreateDirectory((Join-Path $Archive 'a'))
        [void][IO.Directory]::CreateDirectory((Join-Path $Archive 'b'))
        [IO.File]::WriteAllText((Join-Path $Archive 'a/test.jsonl'),'different archived history')
        Copy-Item $Session (Join-Path $Archive 'b/test.jsonl')
        $Config.agents[0] | Add-Member skipRestoreIfPresentIn @($Archive)
        $Plan=Get-AgentSyncImportPlan -ProjectRoot $Project -Config $Config
        $Plan.PreservedElsewhere | Should -Be 1
        $Plan.ToCopy | Should -Be 0
        $Plan.Blocked | Should -Be 0
    }

    It 'fails closed for another project identity and incomplete JSONL' {
        [IO.File]::WriteAllText($Session,'{"type":"session_meta","payload":{"cwd":"C:/another-project"}}')
        (Get-AgentSyncImportPlan -ProjectRoot $Project -Config $Config).Blocked | Should -BeGreaterThan 0
        [IO.File]::WriteAllText($Session,'{"type":')
        (Get-AgentSyncImportPlan -ProjectRoot $Project -Config $Config).Blocked | Should -BeGreaterThan 0
    }

    It 'rejects a destination junction without touching its target' -Skip:(-not $IsWindows) {
        $Outside=Join-Path $TestDrive 'outside-junction-target'
        [void][IO.Directory]::CreateDirectory($Outside)
        $Link=Join-Path $Native 'linked'
        [void](New-Item -ItemType Junction -Path $Link -Target $Outside)
        $Config.agents[0].localPath=$Link
        {Get-AgentSyncImportPlan -ProjectRoot $Project -Config $Config} | Should -Throw
        @(Get-ChildItem $Outside -Force).Count | Should -Be 0
    }

    It 'keeps directory identity fixed for the duration of publication' -Skip:(-not $IsWindows) {
        $Leases=Assert-AgentSyncImportPath $Native -KeepDirectoryLeases
        try { {Move-Item -LiteralPath $Native -Destination ($Native+'-moved') -ErrorAction Stop} | Should -Throw }
        finally {foreach($Lease in $Leases){$Lease.Dispose()}}
        Test-Path $Native | Should -BeTrue
    }

    It 'accepts only the documented Cloud Files reparse tag family' -Skip:(-not $IsWindows) {
        $null=Assert-AgentSyncImportPath $Project
        foreach($Index in 0..15) { [AgentSyncImportPathHandle]::IsCloudTag([Convert]::ToUInt32('9000001A',16) + [uint32]($Index*4096)) | Should -BeTrue }
        foreach($Tag in @('A0000003','A000000C','9000001B','0')) { [AgentSyncImportPathHandle]::IsCloudTag([Convert]::ToUInt32($Tag,16)) | Should -BeFalse }
    }

    It 'reports completed copies accurately when a later file fails' {
        $Plan=Get-AgentSyncImportPlan -ProjectRoot $Project -Config $Config
        $First=$Plan.Copies[0]
        $Plan.Copies=@($First,[pscustomobject]@{Source='synthetic-failure'})
        $Script:OriginalImportCopy=(Get-Command Copy-AgentSyncImportFile).ScriptBlock
        Mock Copy-AgentSyncImportFile {if($File.Source -eq 'synthetic-failure'){throw 'fixture IO denied'}; & $Script:OriginalImportCopy $File}
        {Invoke-AgentSyncImportPlan -Plan $Plan} | Should -Throw -ExpectedMessage '*after 1 verified*'
        (Get-FileHash $First.Destination).Hash | Should -Be $First.Hash
    }

    It 'never includes invalid native JSON contents in problem messages' {
        [IO.File]::WriteAllText($Session,'{"private-content-do-not-print": invalid}')
        $Plan=Get-AgentSyncImportPlan -ProjectRoot $Project -Config $Config
        $Plan.Blocked | Should -BeGreaterThan 0
        ($Plan.Problems -join ' ') | Should -Match 'INVALID_JSONL'
        ($Plan.Problems -join ' ') | Should -Not -Match 'private-content-do-not-print'
    }

    It 'restores only the verified current Claude bucket layout' {
        $Config.agents[0].name='claude'
        $Config.agents[0].routingMode='claude'
        $Config.agents[0].targetSubDir='.agent-state/claude/sessions'
        $Slug=$Project -replace '[^A-Za-z0-9]','-'
        $Bucket=Join-Path $Project ('.agent-state/claude/sessions/'+$Slug)
        [void][IO.Directory]::CreateDirectory($Bucket)
        [IO.File]::WriteAllText((Join-Path $Bucket 'claude.jsonl'),(@{cwd=$Project;type='user';uuid='fixture'}|ConvertTo-Json -Compress))
        $Plan=Get-AgentSyncImportPlan -ProjectRoot $Project -Config $Config
        $Plan.Blocked | Should -Be 0
        $Plan.ToCopy | Should -Be 1
        Invoke-AgentSyncImportPlan -Plan $Plan | Should -Be 1
        Test-Path (Join-Path $Native ($Slug+'/claude.jsonl')) | Should -BeTrue
    }

    It 'keeps the actual script entrypoint read-only unless Apply is supplied' {
        $ConfigFile=Join-Path $TestDrive 'import-fixture-config.json'
        $Config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ConfigFile
        $Output=& (Join-Path $PSScriptRoot '../Import-AgentState.ps1') -ProjectRoot $Project -ConfigFile $ConfigFile -Agent codex 6>&1
        ($Output -join ' ') | Should -Match 'Ingen filer skrevet'
        @(Get-ChildItem $Native -File).Count | Should -Be 0
    }
}
