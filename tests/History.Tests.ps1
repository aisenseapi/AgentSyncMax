# Long-term history: real Git against throwaway folders under $TestDrive.
# Nothing here touches a real project or the real history store.
BeforeAll {
    . (Join-Path $PSScriptRoot '..\AgentSync.Process.ps1')
    . (Join-Path $PSScriptRoot '..\AgentSync.History.ps1')

    function New-HistoryFixture {
        $Root = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        $Base = Join-Path $Root 'projects'
        New-Item -ItemType Directory -Path $Base -Force | Out-Null
        $Config = [pscustomobject]@{
            history = [pscustomobject]@{
                enabled         = $true
                storeDirectory  = (Join-Path $Root 'store')
                exportDirectory = (Join-Path $Root 'export')
                # The test drive is the system drive; the production floor would refuse it.
                minFreeGB       = 0
            }
        }
        [pscustomobject]@{
            Root     = $Root
            Base     = $Base
            Settings = Get-AgentSyncHistorySettings -Config $Config -ToolkitRoot $Root -MachineId 'TESTBOX'
        }
    }

    function New-HistoryProject {
        param ($Fixture, [string]$Name, [hashtable]$Files = @{})
        $Path = Join-Path $Fixture.Base $Name
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        foreach ($Relative in $Files.Keys) {
            $Target = Join-Path $Path $Relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $Target) -Force | Out-Null
            [System.IO.File]::WriteAllText($Target, [string]$Files[$Relative])
        }
        return $Path
    }

    function Get-HistoryUnit {
        param ($Fixture, [string[]]$Projects)
        return @(Get-AgentSyncHistoryUnits -ProjectPaths $Projects -ProjectsBasePath $Fixture.Base -Settings $Fixture.Settings)
    }

    function Get-HistoryTree {
        param ($Unit, [string]$Revision = 'work')
        $Listing = Invoke-AgentSyncHistoryGit -Repository $Unit.RepositoryPath -Arguments @('ls-tree', '-r', $Revision)
        return @($Listing.StdOut -split "`r?`n" | Where-Object { $_ })
    }

    function Get-HistoryManifest {
        param ($Unit, [string]$Revision = 'work')
        $Blob = Invoke-AgentSyncHistoryGit -Repository $Unit.RepositoryPath -Arguments @('cat-file', '-p', "${Revision}:.agentsync-history/manifest.json")
        return ($Blob.StdOut | ConvertFrom-Json)
    }

    function Initialize-TestRepository {
        param ([string]$Path)
        & git -C $Path init --quiet 2>$null | Out-Null
    }
}

Describe 'History credential storage boundary' -Tag 'HistorySecrets' {
    It 'keeps classified files and folders out of Git objects even when project rules explicitly include them' {
        $Fixture = New-HistoryFixture
        $SecretPaths = @('crates-io.token', '.m2m-token', 'nested/access_token.json', 'nested/api-key[prod].txt', 'secrets/value.txt')
        $Files = @{
            '.gitignore' = "!crates-io.token`n!.m2m-token`n!nested/access_token.json`n!nested/api-key*.txt`n!secrets/`n!secrets/**`n"
            'tokens.css' = 'body { color: white; }'
            'nested/api-key-docs.md' = 'Public documentation'
        }
        foreach ($Path in $SecretPaths) { $Files[$Path] = "synthetic-secret-$Path-$([guid]::NewGuid())" }
        $Project = New-HistoryProject $Fixture 'credential-boundary' $Files
        $Unit = (Get-HistoryUnit $Fixture @($Project))[0]

        $InheritedPathspecs = $env:GIT_LITERAL_PATHSPECS
        try {
            $env:GIT_LITERAL_PATHSPECS = '1'
            $Result = New-AgentSyncHistorySnapshot -Unit $Unit -Settings $Fixture.Settings -AllowBaseline
        }
        finally { $env:GIT_LITERAL_PATHSPECS = $InheritedPathspecs }
        $Result.Outcome | Should -Be 'committed'
        $Paths = (Invoke-AgentSyncHistoryGit -Repository $Unit.RepositoryPath -Arguments @('ls-tree', '-r', '--name-only', 'work')).StdOut -split "`r?`n"
        $Paths | Should -Contain 'tokens.css'
        $Paths | Should -Contain 'nested/api-key-docs.md'
        foreach ($Path in $SecretPaths) {
            $Paths | Should -Not -Contain $Path
            # Checking only the final tree would miss a secret added as a blob
            # and then removed from the index before commit.
            $Hash = (Invoke-AgentSyncHistoryGit -Repository $Unit.RepositoryPath -Arguments @('hash-object', '--no-filters', '--', (Join-Path $Project $Path))).StdOut.Trim()
            (Invoke-AgentSyncHistoryGit -Repository $Unit.RepositoryPath -Arguments @('cat-file', '-e', $Hash)).ExitCode | Should -Not -Be 0
            Test-Path -LiteralPath (Join-Path $Project $Path) | Should -BeTrue
        }
        $Skipped = @((Get-HistoryManifest $Unit).skipped | Where-Object reason -EQ 'secret').path
        $Skipped | Should -Contain 'crates-io.token'
        $Skipped | Should -Contain 'nested/api-key[prod].txt'
        $Skipped | Should -Contain 'secrets'
    }

    It 'enforces the same boundary in the <Line> history line' -TestCases @(
        @{ Line = 'state'; RelativeRoot = '.agent-state' }
        @{ Line = 'records'; RelativeRoot = 'records' }
    ) {
        param ($Line, $RelativeRoot)
        $Fixture = New-HistoryFixture
        $Project = New-HistoryProject $Fixture "credential-$Line" @{
            'readme.md' = 'project'
            "$RelativeRoot/.m2m-token" = "synthetic-$([guid]::NewGuid())"
            "$RelativeRoot/secrets/value.txt" = "synthetic-$([guid]::NewGuid())"
            "$RelativeRoot/session.json" = '{}'
        }
        if ($Line -eq 'records') {
            $Fixture.Settings.ExtraLines = @([pscustomobject]@{ line = $Line; path = (Join-Path $Project $RelativeRoot); exclude = @() })
        }
        $Unit = (Get-HistoryUnit $Fixture @($Project))[0]
        $Result = New-AgentSyncHistorySnapshot -Unit $Unit -Line $Line -Settings $Fixture.Settings -AllowBaseline
        $Result.Outcome | Should -Be 'committed'
        $Paths = (Invoke-AgentSyncHistoryGit -Repository $Unit.RepositoryPath -Arguments @('ls-tree', '-r', '--name-only', $Line)).StdOut -split "`r?`n"
        $Paths | Should -Contain 'session.json'
        $Paths | Should -Not -Contain '.m2m-token'
        $Paths | Should -Not -Contain 'secrets/value.txt'
        foreach ($Path in @('.m2m-token', 'secrets/value.txt')) {
            $Source = Join-Path (Join-Path $Project $RelativeRoot) $Path
            $Hash = (Invoke-AgentSyncHistoryGit -Repository $Unit.RepositoryPath -Arguments @('hash-object', '--no-filters', '--', $Source)).StdOut.Trim()
            (Invoke-AgentSyncHistoryGit -Repository $Unit.RepositoryPath -Arguments @('cat-file', '-e', $Hash)).ExitCode | Should -Not -Be 0
        }
    }

    It 'removes previously tracked secrets before reading their new contents without rewriting prior snapshots' {
        $Fixture = New-HistoryFixture
        $SecretPattern = $Fixture.Settings.SecretPattern
        $Fixture.Settings.SecretPattern = ''
        $Project = New-HistoryProject $Fixture 'credential-policy-change' @{
            '.gitignore' = "!.m2m-token`n!secrets/`n!secrets/**`n"
            'readme.md' = 'before'
            '.m2m-token' = 'synthetic old file'
            'secrets/value.txt' = 'synthetic old folder'
        }
        $Unit = (Get-HistoryUnit $Fixture @($Project))[0]
        $First = New-AgentSyncHistorySnapshot -Unit $Unit -Settings $Fixture.Settings -AllowBaseline
        $First.Outcome | Should -Be 'committed'
        $Fixture.Settings.SecretPattern = $SecretPattern
        foreach ($Path in @('.m2m-token', 'secrets/value.txt')) {
            [System.IO.File]::WriteAllText((Join-Path $Project $Path), "synthetic new secret-$([guid]::NewGuid())")
        }

        $Next = New-AgentSyncHistorySnapshot -Unit $Unit -Settings $Fixture.Settings
        $Next.Outcome | Should -Be 'committed' -Because $Next.Reason
        $Next.Parent | Should -Be $First.Commit
        $Paths = (Invoke-AgentSyncHistoryGit -Repository $Unit.RepositoryPath -Arguments @('ls-tree', '-r', '--name-only', 'work')).StdOut -split "`r?`n"
        foreach ($Path in @('.m2m-token', 'secrets/value.txt')) {
            $Paths | Should -Not -Contain $Path
            $Hash = (Invoke-AgentSyncHistoryGit -Repository $Unit.RepositoryPath -Arguments @('hash-object', '--no-filters', '--', (Join-Path $Project $Path))).StdOut.Trim()
            (Invoke-AgentSyncHistoryGit -Repository $Unit.RepositoryPath -Arguments @('cat-file', '-e', $Hash)).ExitCode | Should -Not -Be 0
            (Invoke-AgentSyncHistoryGit -Repository $Unit.RepositoryPath -Arguments @('cat-file', '-e', "$($First.Commit):$Path")).ExitCode | Should -Be 0
        }
    }

    It 'stops before adding files if the secret cannot be removed from the private index' {
        $Fixture = New-HistoryFixture
        $SecretPattern = $Fixture.Settings.SecretPattern
        $Fixture.Settings.SecretPattern = ''
        $Project = New-HistoryProject $Fixture 'credential-remove-failure' @{ '.m2m-token' = 'synthetic before' }
        $Unit = (Get-HistoryUnit $Fixture @($Project))[0]
        $First = New-AgentSyncHistorySnapshot -Unit $Unit -Settings $Fixture.Settings -AllowBaseline
        $First.Outcome | Should -Be 'committed'
        $Fixture.Settings.SecretPattern = $SecretPattern
        [System.IO.File]::WriteAllText((Join-Path $Project '.m2m-token'), "synthetic-after-$([guid]::NewGuid())")
        $script:HistoryGitForFailureTest = ${function:Invoke-AgentSyncHistoryGit}
        Mock Invoke-AgentSyncHistoryGit { & $script:HistoryGitForFailureTest @PesterBoundParameters }
        Mock Invoke-AgentSyncHistoryGit {
            [pscustomobject]@{ ExitCode = 1; TimedOut = $false; StdOut = ''; StdErr = 'injected index failure' }
        } -ParameterFilter { $Arguments -contains 'rm' -and [bool]($Arguments -match 'secrets\.tmp$') }

        $Result = New-AgentSyncHistorySnapshot -Unit $Unit -Settings $Fixture.Settings
        $Result.Outcome | Should -Be 'failed'
        $Result.Commit | Should -BeNullOrEmpty
        $Result.Reason | Should -Match 'no files were added'
        (Get-AgentSyncHistoryLineTip -Unit $Unit -Line 'work').Commit | Should -Be $First.Commit
        $Hash = (Invoke-AgentSyncHistoryGit -Repository $Unit.RepositoryPath -Arguments @('hash-object', '--no-filters', '--', (Join-Path $Project '.m2m-token'))).StdOut.Trim()
        (Invoke-AgentSyncHistoryGit -Repository $Unit.RepositoryPath -Arguments @('cat-file', '-e', $Hash)).ExitCode | Should -Not -Be 0
    }
}

Describe 'History writes as AgentSync itself' {
    # The optional history store is separate from the project's source repository.
    # Its generated snapshots use a fixed tool identity so they are not mistaken
    # for source commits made by the user. This does not change the source
    # repository's configured author or committer identity.
    It 'signs a snapshot as the tool, never as the user or the machine' {
        $Fixture = New-HistoryFixture
        $Project = New-HistoryProject $Fixture 'P' @{ 'a.txt' = 'a' }
        $Unit = (Get-HistoryUnit $Fixture @($Project))[0]
        $Result = New-AgentSyncHistorySnapshot -Unit $Unit -Settings $Fixture.Settings -AllowBaseline
        $Signature = (Invoke-AgentSyncHistoryGit -Repository $Unit.RepositoryPath -Arguments @('log', '-1', '--format=%an|%ae|%cn|%ce', $Result.Commit)).StdOut.Trim()

        $Signature | Should -Be 'AgentSync History|history@agentsync.invalid|AgentSync History|history@agentsync.invalid'
        # Whatever the person running it has configured, and whoever they are.
        foreach ($Human in (& git config --get user.name), (& git config --get user.email), $env:USERNAME, $env:COMPUTERNAME) {
            if ($Human) { $Signature | Should -Not -Match ([regex]::Escape($Human)) }
        }
    }

    It 'ignores a Git identity inherited from the caller' {
        $Fixture = New-HistoryFixture
        $Project = New-HistoryProject $Fixture 'P' @{ 'a.txt' = 'a' }
        $Unit = (Get-HistoryUnit $Fixture @($Project))[0]
        $env:GIT_AUTHOR_NAME = 'Someone Else'
        $env:GIT_AUTHOR_EMAIL = 'someone@example.invalid'
        $env:GIT_COMMITTER_NAME = 'Someone Else'
        $env:GIT_COMMITTER_EMAIL = 'someone@example.invalid'
        try {
            $Result = New-AgentSyncHistorySnapshot -Unit $Unit -Settings $Fixture.Settings -AllowBaseline
            $Signature = (Invoke-AgentSyncHistoryGit -Repository $Unit.RepositoryPath -Arguments @('log', '-1', '--format=%an|%ae', $Result.Commit)).StdOut.Trim()
            $Signature | Should -Be 'AgentSync History|history@agentsync.invalid'
        }
        finally {
            foreach ($Name in 'GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL') {
                Remove-Item "Env:$Name" -ErrorAction SilentlyContinue
            }
        }
    }

}

Describe 'History module isolation' {
    It 'takes a snapshot even when another test file has replaced the engine log function' {
        # AgentSync.Tests.ps1 redefines Write-AgentSyncLog to write into its own
        # $Script:TestLog. In one combined run that definition can reach this
        # file, where the variable does not exist. A snapshot must not depend on
        # whose logging function happens to be loaded.
        $Fixture = New-HistoryFixture
        $Project = New-HistoryProject $Fixture 'P' @{ 'a.txt' = 'a' }
        $Unit = (Get-HistoryUnit $Fixture @($Project))[0]
        function Write-AgentSyncLog { param ([string]$Level, [string]$Message, [switch]$Console) $Script:NeverInitialised.Add($Message) }
        try {
            { Write-AgentSyncHistoryLog -Level 'INFO' -Message 'probe' } | Should -Not -Throw
            (New-AgentSyncHistorySnapshot -Unit $Unit -Settings $Fixture.Settings -AllowBaseline -DryRun).Outcome | Should -Be 'dry-run'
            (New-AgentSyncHistorySnapshot -Unit $Unit -Settings $Fixture.Settings -AllowBaseline).Outcome | Should -Be 'committed'
        }
        finally {
            Remove-Item -LiteralPath 'Function:Write-AgentSyncLog' -ErrorAction SilentlyContinue
        }
    }
}

Describe 'History units' {
    It 'normalizes lock paths and keeps independent resources separate' -Tag 'HistoryContinuation' {
        $Path = Join-Path $TestDrive 'store/P.git'
        foreach ($Kind in @('Unit', 'Ledger', 'Readable', 'Sweep')) {
            $Name = Get-AgentSyncHistoryMutexName -Kind $Kind -Path $Path
            $Name | Should -Match "^AgentSyncHistory\.$Kind\.[a-f0-9]{64}$"
            (Get-AgentSyncHistoryMutexName -Kind $Kind -Path (Join-Path $Path '.')) | Should -Be $Name
            (Get-AgentSyncHistoryMutexName -Kind $Kind -Path (Join-Path $TestDrive 'other/P.git')) | Should -Not -Be $Name
            if ($IsWindows) {
                (Get-AgentSyncHistoryMutexName -Kind $Kind -Path $Path.ToUpperInvariant().Replace('\', '/')) | Should -Be $Name
                (Get-AgentSyncHistoryMutexName -Kind $Kind -Path "\\?\$Path") | Should -Be $Name
            }
        }
        (Get-AgentSyncHistoryMutexName -Kind Unit -Path $Path) | Should -Not -Be (Get-AgentSyncHistoryMutexName -Kind Ledger -Path $Path)
        if ($IsWindows) {
            (Get-AgentSyncHistoryMutexName -Kind Unit -Path '\\?\UNC\server\share\P.git') | Should -Be (Get-AgentSyncHistoryMutexName -Kind Unit -Path '\\server\share\P.git')
        }
    }

    It 'gives a path a stable, readable, ASCII id' {
        $First = ConvertTo-AgentSyncHistoryUnitId -RelativePath 'Projects\Example\SampleApp\code\php'
        $First | Should -Be (ConvertTo-AgentSyncHistoryUnitId -RelativePath 'projects/example/sampleapp/code/php/')
        $First | Should -Match '^[a-z0-9-]+-[0-9a-f]{8}$'
        $First | Should -Match 'sampleapp-code-php'
        (ConvertTo-AgentSyncHistoryUnitId -RelativePath 'Regnskap\Blåbær og fløte') | Should -Match '^regnskap-blabaer-og-flote-'
        (ConvertTo-AgentSyncHistoryUnitId -RelativePath 'a\b') | Should -Not -Be (ConvertTo-AgentSyncHistoryUnitId -RelativePath 'a\c')
        # A long path keeps its tail, and the folder name starts at a whole word.
        $Long = ConvertTo-AgentSyncHistoryUnitId -RelativePath 'SampleProjects\Example Company\AgentSyncToolkit\inspiration\sample-reference'
        $Long | Should -Match '^agentsynctoolkit-inspiration-sample-reference-[0-9a-f]{8}$'
    }

    It 'makes one unit per repository and one per folder project, and never captures a folder twice' {
        $Fixture = New-HistoryFixture
        $Plain = New-HistoryProject $Fixture 'Docs' @{ 'note.txt' = 'n'; '.agent-state\claude\s.jsonl' = '{}' }
        $Repo = New-HistoryProject $Fixture 'App' @{ 'main.php' = 'p'; 'web\index.html' = 'h'; 'web\.agent-state\codex\r.jsonl' = '{}' }
        Initialize-TestRepository $Repo
        $Collection = New-HistoryProject $Fixture 'Client' @{ 'readme.md' = 'r'; 'code\php\a.php' = 'a' }
        Initialize-TestRepository (Join-Path $Collection 'code\php')

        $Units = Get-HistoryUnit $Fixture @($Plain, $Repo, (Join-Path $Repo 'web'), $Collection)

        ($Units | Where-Object Path -EQ $Plain).Kind | Should -Be 'folder'
        ($Units | Where-Object Path -EQ $Plain).StateLines.Line | Should -Be 'state'
        # Two projects inside one repository share that repository's unit.
        @($Units | Where-Object { $_.Path -like "$Repo*" }).Count | Should -Be 1
        ($Units | Where-Object Path -EQ $Repo).Kind | Should -Be 'git'
        ($Units | Where-Object Path -EQ $Repo).StateLines.Line | Should -Be 'state-web'
        # The repository inside the collection folder is found and owned by itself.
        $Nested = Join-Path $Collection 'code\php'
        ($Units | Where-Object Path -EQ $Nested).Kind | Should -Be 'git'
        ($Units | Where-Object Path -EQ $Collection).NestedUnits | Should -Contain $Nested
        @($Units.Id | Sort-Object -Unique).Count | Should -Be $Units.Count
    }
}

Describe 'History snapshots' {
    It 'refuses a first snapshot unless the baseline is asked for, then records only real change' {
        $Fixture = New-HistoryFixture
        $Project = New-HistoryProject $Fixture 'P' @{ 'a.txt' = 'one' }
        $Unit = (Get-HistoryUnit $Fixture @($Project))[0]

        (New-AgentSyncHistorySnapshot -Unit $Unit -Settings $Fixture.Settings).Outcome | Should -Be 'no-baseline'
        Test-Path -LiteralPath $Unit.RepositoryPath | Should -BeFalse

        $Baseline = New-AgentSyncHistorySnapshot -Unit $Unit -Settings $Fixture.Settings -Trigger 'baseline' -AllowBaseline
        $Baseline.Outcome | Should -Be 'committed'
        $Baseline.Completeness | Should -Be 'complete'
        $Baseline.Added | Should -Be 1

        (New-AgentSyncHistorySnapshot -Unit $Unit -Settings $Fixture.Settings).Outcome | Should -Be 'unchanged'

        [System.IO.File]::WriteAllText((Join-Path $Project 'a.txt'), 'two')
        [System.IO.File]::WriteAllText((Join-Path $Project 'b.txt'), 'new')
        $Next = New-AgentSyncHistorySnapshot -Unit $Unit -Settings $Fixture.Settings
        $Next.Outcome | Should -Be 'committed'
        $Next.Modified | Should -Be 1
        $Next.Added | Should -Be 1
        $Next.Parent | Should -Be $Baseline.Commit
        $Next.ChangedPaths | Should -Contain 'a.txt'
    }

    It 'keeps the old bytes after the working copy is overwritten' {
        $Fixture = New-HistoryFixture
        $Project = New-HistoryProject $Fixture 'P' @{ 'a.txt' = 'before' }
        $Unit = (Get-HistoryUnit $Fixture @($Project))[0]
        $First = New-AgentSyncHistorySnapshot -Unit $Unit -Settings $Fixture.Settings -AllowBaseline
        [System.IO.File]::WriteAllText((Join-Path $Project 'a.txt'), 'after')
        [void](New-AgentSyncHistorySnapshot -Unit $Unit -Settings $Fixture.Settings)

        (Invoke-AgentSyncHistoryGit -Repository $Unit.RepositoryPath -Arguments @('cat-file', '-p', "$($First.Commit):a.txt")).StdOut | Should -Be 'before'
        (Invoke-AgentSyncHistoryGit -Repository $Unit.RepositoryPath -Arguments @('cat-file', '-p', 'work:a.txt')).StdOut | Should -Be 'after'
    }

    It 'stores the bytes on disk, whatever the project says about line endings, filters and idents' {
        $Fixture = New-HistoryFixture
        $Project = New-HistoryProject $Fixture 'P' @{
            '.gitattributes' = "* text=auto eol=lf`n*.bin filter=lfs diff=lfs merge=lfs -text`n*.idt ident`n"
            'crlf.txt'       = "one`r`ntwo`r`n"
            'data.bin'       = "bin`r`npayload"
            'stamp.idt'      = "`$Id`$`r`n"
        }
        $Unit = (Get-HistoryUnit $Fixture @($Project))[0]
        [void](New-AgentSyncHistorySnapshot -Unit $Unit -Settings $Fixture.Settings -AllowBaseline)

        foreach ($Name in 'crlf.txt', 'data.bin', 'stamp.idt') {
            $OnDisk = (Invoke-AgentSyncHistoryGit -Repository $Unit.RepositoryPath -Arguments @('hash-object', '--no-filters', '--', (Join-Path $Project $Name))).StdOut.Trim()
            $Stored = (Invoke-AgentSyncHistoryGit -Repository $Unit.RepositoryPath -Arguments @('rev-parse', "work:$Name")).StdOut.Trim()
            $Stored | Should -Be $OnDisk
        }
    }

    It 'leaves out what the project ignores, keeps agent state on its own line, and writes nothing into the project' {
        $Fixture = New-HistoryFixture
        $Project = New-HistoryProject $Fixture 'P' @{
            '.gitignore'                  = "ignored.txt`n.agent-state/`n"
            'kept.txt'                    = 'k'
            'ignored.txt'                 = 'i'
            'node_modules\lib\index.js'   = 'm'
            '.agent-state\claude\s.jsonl' = '{"a":1}'
            '.agent-state\manifest.json'  = '{}'
        }
        $Unit = (Get-HistoryUnit $Fixture @($Project))[0]
        $Before = @(Get-ChildItem -LiteralPath $Project -Recurse -Force -File | ForEach-Object FullName | Sort-Object)
        $Results = Invoke-AgentSyncHistoryUnitSnapshot -Unit $Unit -Settings $Fixture.Settings -Trigger 'baseline' -AllowBaseline
        @($Results | Where-Object Outcome -NE 'committed').Count | Should -Be 0

        $Work = (Get-HistoryTree $Unit 'work') -join "`n"
        $Work | Should -Match 'kept\.txt'
        $Work | Should -Not -Match 'ignored\.txt'
        $Work | Should -Not -Match 'node_modules'
        $Work | Should -Not -Match 'agent-state'
        $State = (Get-HistoryTree $Unit 'state') -join "`n"
        $State | Should -Match 'claude/s\.jsonl'
        # The engine rewrites its own manifest every cycle; that is not history.
        $State | Should -Not -Match "`tmanifest\.json"

        @(Get-ChildItem -LiteralPath $Project -Recurse -Force -File | ForEach-Object FullName | Sort-Object) | Should -Be $Before
    }

    It 'does not add mission records to toolkit history by default' -Tag 'HistoryContinuation' {
        $Fixture = New-HistoryFixture
        $Project = New-HistoryProject $Fixture 'Toolkit' @{
            '.gitignore' = "missions/`n"
            'engine.ps1' = 'engine'
            'missions/mission-1.json' = '{"prompt":"synthetic private prompt"}'
            'missions/evaluations/rev-1.json' = '{"note":"synthetic private evaluation"}'
        }
        # Use the toolkit itself: that was the old implicit records-line route.
        $Config = [pscustomobject]@{ history = [pscustomobject]@{
            storeDirectory = $Fixture.Settings.StoreDirectory
            exportDirectory = $Fixture.Settings.ExportDirectory
            minFreeGB = 0
        } }
        $Fixture.Settings = Get-AgentSyncHistorySettings -Config $Config -ToolkitRoot $Project -MachineId 'TESTBOX'
        $Unit = (Get-HistoryUnit $Fixture @($Project))[0]
        @($Fixture.Settings.ExtraLines).Count | Should -Be 0
        @($Unit.ExtraLines).Count | Should -Be 0
        $Results = @(Invoke-AgentSyncHistoryUnitSnapshot -Unit $Unit -Settings $Fixture.Settings -AllowBaseline)
        $Results.Line | Should -Be 'work'
        $Results.Outcome | Should -Be 'committed'
        foreach ($Path in @('missions/mission-1.json', 'missions/evaluations/rev-1.json')) {
            $Source = Join-Path $Project $Path
            $Hash = (Invoke-AgentSyncHistoryGit -Repository $Unit.RepositoryPath -Arguments @('hash-object', '--no-filters', '--', $Source)).StdOut.Trim()
            (Invoke-AgentSyncHistoryGit -Repository $Unit.RepositoryPath -Arguments @('cat-file', '-e', $Hash)).ExitCode | Should -Not -Be 0
            Test-Path -LiteralPath $Source | Should -BeTrue
        }
    }

    It 'keeps a folder the project ignores when it is named as history, on a line of its own' {
        $Fixture = New-HistoryFixture
        $Project = New-HistoryProject $Fixture 'Toolkit' @{
            '.gitignore'                        = "missions/`n"
            'engine.ps1'                        = 'e'
            'missions\mission-1.json'           = '{"prompt":"p"}'
            'missions\evaluations\c\rev-1.json' = '{}'
            'missions\checkpoints\m1\copy.txt'  = 'rollback copy'
        }
        $Fixture.Settings.ExtraLines = @([pscustomobject]@{ line = 'records'; path = (Join-Path $Project 'missions'); exclude = @('/checkpoints/') })
        $Unit = (Get-HistoryUnit $Fixture @($Project))[0]
        $Unit.ExtraLines.Line | Should -Be 'records'

        $Results = Invoke-AgentSyncHistoryUnitSnapshot -Unit $Unit -Settings $Fixture.Settings -Trigger 'baseline' -AllowBaseline
        ($Results | Where-Object Line -EQ 'records').Outcome | Should -Be 'committed'
        (Get-HistoryTree $Unit 'work') -join "`n" | Should -Not -Match 'mission-1'
        $Records = (Get-HistoryTree $Unit 'records') -join "`n"
        $Records | Should -Match 'mission-1\.json'
        $Records | Should -Match 'evaluations/c/rev-1\.json'
        $Records | Should -Not -Match 'checkpoints'
        (Get-AgentSyncHistoryUnitStatus -Unit $Unit).Baseline | Should -BeTrue
    }

    It 'does not walk a folder the line leaves out, so the manifest never names what was never in scope' {
        # A checkpoint is a verbatim copy of a project, secrets and all. Reporting
        # its contents as "left out" of a line that never covered it is misleading,
        # and walking thousands of files to do it is waste.
        $Fixture = New-HistoryFixture
        $Project = New-HistoryProject $Fixture 'Toolkit' @{
            '.gitignore'                              = "missions/`n"
            'engine.ps1'                              = 'e'
            'missions\mission-1.json'                 = '{}'
            'missions\checkpoints\m1\before\.env'     = 'SECRET=1'
            'missions\checkpoints\m1\before\id_rsa'   = 'private key'
            'missions\checkpoints\m1\before\note.txt' = 'n'
        }
        $Fixture.Settings.ExtraLines = @([pscustomobject]@{ line = 'records'; path = (Join-Path $Project 'missions'); exclude = @('/checkpoints/') })
        $Unit = (Get-HistoryUnit $Fixture @($Project))[0]
        [void](Invoke-AgentSyncHistoryUnitSnapshot -Unit $Unit -Settings $Fixture.Settings -Trigger 'baseline' -AllowBaseline)

        $Manifest = Get-HistoryManifest $Unit 'records'
        @($Manifest.skipped).Count | Should -Be 0
        @($Manifest.unreadable).Count | Should -Be 0
        (Get-HistoryTree $Unit 'records') -join "`n" | Should -Not -Match 'checkpoints|id_rsa'
    }

    It 'makes the ignore rules authoritative for files that were captured earlier' {
        $Fixture = New-HistoryFixture
        $Project = New-HistoryProject $Fixture 'P' @{ 'a.txt' = 'a'; 'later-ignored.log' = 'l' }
        $Unit = (Get-HistoryUnit $Fixture @($Project))[0]
        [void](New-AgentSyncHistorySnapshot -Unit $Unit -Settings $Fixture.Settings -AllowBaseline)
        (Get-HistoryTree $Unit) -join "`n" | Should -Match 'later-ignored\.log'

        [System.IO.File]::WriteAllText((Join-Path $Project '.gitignore'), "*.log`n")
        $Next = New-AgentSyncHistorySnapshot -Unit $Unit -Settings $Fixture.Settings
        $Next.Deleted | Should -Be 1
        (Get-HistoryTree $Unit) -join "`n" | Should -Not -Match 'later-ignored\.log'
    }

    It 'never reports a snapshot as complete when a file could not be read' {
        $Fixture = New-HistoryFixture
        $Project = New-HistoryProject $Fixture 'P' @{ 'fine.txt' = 'f'; 'locked.db' = 'l' }
        $Unit = (Get-HistoryUnit $Fixture @($Project))[0]
        $Lock = [System.IO.FileStream]::new((Join-Path $Project 'locked.db'), [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try {
            $Result = New-AgentSyncHistorySnapshot -Unit $Unit -Settings $Fixture.Settings -AllowBaseline
        }
        finally {
            $Lock.Dispose()
        }

        $Result.Outcome | Should -Be 'committed'
        $Result.Completeness | Should -Be 'partial'
        $Result.Unreadable | Should -Be 1
        (Get-HistoryTree $Unit) -join "`n" | Should -Match 'fine\.txt'
        (Get-HistoryManifest $Unit).unreadable.path | Should -Be 'locked.db'

        # Once the file can be read, the next snapshot is complete and says so.
        $Healed = New-AgentSyncHistorySnapshot -Unit $Unit -Settings $Fixture.Settings
        $Healed.Completeness | Should -Be 'complete'
        (Get-HistoryTree $Unit) -join "`n" | Should -Match 'locked\.db'
    }

    It 'reads a file that an agent holds open for writing' {
        $Fixture = New-HistoryFixture
        $Project = New-HistoryProject $Fixture 'P' @{ 'session.jsonl' = "{`"n`":1}`n" }
        $Unit = (Get-HistoryUnit $Fixture @($Project))[0]
        $Writer = [System.IO.FileStream]::new((Join-Path $Project 'session.jsonl'), [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        try {
            $Result = New-AgentSyncHistorySnapshot -Unit $Unit -Settings $Fixture.Settings -AllowBaseline
        }
        finally {
            $Writer.Dispose()
        }
        $Result.Completeness | Should -Be 'complete'
        (Get-HistoryTree $Unit) -join "`n" | Should -Match 'session\.jsonl'
    }

    It 'keeps a large file once, outside Git, under its own hash' {
        $Fixture = New-HistoryFixture
        $Fixture.Settings.LargeFileBytes = 1024
        $Payload = 'x' * 4096
        $Project = New-HistoryProject $Fixture 'P' @{ 'small.txt' = 's'; 'video.mp4' = $Payload; 'copy\same.mp4' = $Payload }
        $Unit = (Get-HistoryUnit $Fixture @($Project))[0]
        $Result = New-AgentSyncHistorySnapshot -Unit $Unit -Settings $Fixture.Settings -AllowBaseline

        $Result.Completeness | Should -Be 'complete'
        (Get-HistoryTree $Unit) -join "`n" | Should -Not -Match 'mp4'
        $Entries = @((Get-HistoryManifest $Unit).skipped | Where-Object reason -EQ 'large')
        $Entries.Count | Should -Be 2
        $Entries[0].stored | Should -BeTrue
        $Expected = Get-AgentSyncHistoryFileSha256 -Path (Join-Path $Project 'video.mp4')
        $Entries[0].sha256 | Should -Be $Expected
        $Kept = @(Get-ChildItem -LiteralPath (Join-Path $Unit.RepositoryPath 'agentsync\large') -Recurse -File)
        $Kept.Count | Should -Be 1
        $Kept[0].Name | Should -Be $Expected
    }

    It 'does not copy a large file that the project itself ignores' {
        $Fixture = New-HistoryFixture
        $Fixture.Settings.LargeFileBytes = 1024
        $Project = New-HistoryProject $Fixture 'P' @{ '.gitignore' = "build/`n"; 'a.txt' = 'a'; 'build\artifact.bin' = ('y' * 4096) }
        $Unit = (Get-HistoryUnit $Fixture @($Project))[0]
        [void](New-AgentSyncHistorySnapshot -Unit $Unit -Settings $Fixture.Settings -AllowBaseline)
        Test-Path -LiteralPath (Join-Path $Unit.RepositoryPath 'agentsync\large') | Should -BeFalse
        @((Get-HistoryManifest $Unit).skipped).Count | Should -Be 0
    }

    It 'names secrets as left out and never stores them' {
        $Fixture = New-HistoryFixture
        $Project = New-HistoryProject $Fixture 'P' @{ 'app.php' = 'a'; '.env' = 'KEY=1'; '.env.example' = 'KEY='; 'deploy\server.pem' = 'pem'; 'config.local.json' = '{}' }
        $Unit = (Get-HistoryUnit $Fixture @($Project))[0]
        [void](New-AgentSyncHistorySnapshot -Unit $Unit -Settings $Fixture.Settings -AllowBaseline)

        $Tree = (Get-HistoryTree $Unit) -join "`n"
        $Tree | Should -Match '\.env\.example'
        $Tree | Should -Not -Match "`t\.env`n|`t\.env$"
        $Tree | Should -Not -Match 'server\.pem'
        $Tree | Should -Not -Match 'config\.local\.json'
        @((Get-HistoryManifest $Unit).skipped | Where-Object reason -EQ 'secret').path | Sort-Object | Should -Be @('.env', 'config.local.json', 'deploy/server.pem')
    }

    It 'catches credential filenames a list of exact names would miss' {
        # Codex found crates-io.token and .m2m-token slipping through; the same
        # check then showed .credentials.json, .git-credentials, .pgpass and
        # access_token.json doing the same. An exact-name list always loses, so a
        # bounded word in the name is enough — bounded so that a design-token
        # stylesheet is still history and not mistaken for a secret.
        $Fixture = New-HistoryFixture
        $MustCatch = @(
            'crates-io.token', '.m2m-token', '.credentials.json', '.git-credentials', '.pgpass',
            'access_token.json', 'refresh-token.json', 'gh-token.txt', 'api-key.txt', 'api_key.yml',
            '.aws-credentials', 'secret_token', 'settings.local.json', 'my.keystore', 'app.jks',
            'deploy.ppk', 'private-key.pem', '.env.production'
        )
        foreach ($Name in $MustCatch) {
            Test-AgentSyncHistorySecretName -Name $Name -Settings $Fixture.Settings | Should -BeTrue -Because "$Name is a credential file"
        }
        $MustKeep = @(
            'tokenizer.py', 'tokens.css', 'tokens.scss', 'design-tokens.ts', 'keyboard.css',
            'passwordless.md', 'password-policy.md', 'secretary-notes.md', 'keystore-docs.md',
            '.env.example', '.env.sample', 'README.md', 'main.rs', 'monkey.png'
        )
        foreach ($Name in $MustKeep) {
            Test-AgentSyncHistorySecretName -Name $Name -Settings $Fixture.Settings | Should -BeFalse -Because "$Name is an ordinary project file"
        }
    }

    It 'never stores a repository inside the project as an empty pointer' {
        $Fixture = New-HistoryFixture
        $Project = New-HistoryProject $Fixture 'P' @{ 'a.txt' = 'a'; 'deep\er\inner\n.txt' = 'n' }
        $Inner = Join-Path $Project 'deep\er\inner'
        Initialize-TestRepository $Inner
        & git -C $Inner add n.txt 2>$null | Out-Null
        & git -C $Inner -c user.name=t -c user.email=t@example.invalid commit --quiet -m n 2>$null | Out-Null
        $Fixture.Settings.GitScanDepth = 1   # too shallow to find it: the prescan has to
        $Unit = (Get-HistoryUnit $Fixture @($Project))[0]
        [void](New-AgentSyncHistorySnapshot -Unit $Unit -Settings $Fixture.Settings -AllowBaseline)

        (Get-HistoryTree $Unit) | Where-Object { $_.StartsWith('160000') } | Should -BeNullOrEmpty
        (Get-HistoryTree $Unit) -join "`n" | Should -Not -Match 'n\.txt'
        $Entry = (Get-HistoryManifest $Unit).skipped | Where-Object reason -EQ 'nested-repository'
        $Entry.path | Should -Be 'deep/er/inner'
        $Entry.ownHistory | Should -BeFalse
    }

    It 'captures a path longer than 260 characters' {
        $Fixture = New-HistoryFixture
        $Project = New-HistoryProject $Fixture 'P' @{ 'a.txt' = 'a' }
        $Deep = $Project
        1..12 | ForEach-Object { $Deep = Join-Path $Deep ("segment-" + ('x' * 16) + "-$_") }
        [void][System.IO.Directory]::CreateDirectory("\\?\$Deep")
        [System.IO.File]::WriteAllText("\\?\$(Join-Path $Deep 'deep.txt')", 'deep')
        try {
            (Join-Path $Deep 'deep.txt').Length | Should -BeGreaterThan 260
            $Unit = (Get-HistoryUnit $Fixture @($Project))[0]
            $Result = New-AgentSyncHistorySnapshot -Unit $Unit -Settings $Fixture.Settings -AllowBaseline
            $Result.Completeness | Should -Be 'complete'
            (Get-HistoryTree $Unit) -join "`n" | Should -Match 'deep\.txt'
        }
        finally {
            [System.IO.Directory]::Delete("\\?\$(Join-Path $Project ('segment-' + ('x' * 16) + '-1'))", $true)
        }
    }

    It 'serializes actual snapshots by their storage destination: <Case>' -Tag 'HistoryContinuation' -TestCases @(
        @{ Case = 'same repository'; SharedRepository = $true; RenameId = $false; Expected = 'busy' }
        @{ Case = 'same ID in separate stores'; SharedRepository = $false; RenameId = $false; Expected = 'committed' }
        @{ Case = 'same repository with another label'; SharedRepository = $true; RenameId = $true; Expected = 'busy' }
    ) {
        param ($Case, $SharedRepository, $RenameId, $Expected)
        $Fixture = New-HistoryFixture
        $Project = New-HistoryProject $Fixture 'P' @{ 'a.txt' = 'a' }
        $Unit = (Get-HistoryUnit $Fixture @($Project))[0]
        if ($SharedRepository) {
            $OtherFixture = $Fixture
            $OtherUnit = $Unit.PSObject.Copy()
            if ($RenameId) { $OtherUnit.Id = 'another-label' }
        }
        else {
            $OtherFixture = New-HistoryFixture
            $OtherProject = New-HistoryProject $OtherFixture 'P' @{ 'a.txt' = 'independent' }
            $OtherUnit = (Get-HistoryUnit $OtherFixture @($OtherProject))[0]
            $OtherUnit.Id | Should -Be $Unit.Id
            $OtherUnit.RepositoryPath | Should -Not -Be $Unit.RepositoryPath
        }

        $Flag = Join-Path $Fixture.Root 'held.flag'
        $Release = Join-Path $Fixture.Root 'release.flag'
        # Pause a real snapshot inside its critical section. Do not manufacture
        # a mutex name here: that would only test the test's copy of the rule.
        $ModuleRoot = Split-Path -Parent $PSScriptRoot
        $Job = Start-ThreadJob -ArgumentList $ModuleRoot, $Unit, $Fixture.Settings, $Flag, $Release -ScriptBlock {
            param ($ModuleRoot, $Unit, $Settings, $Flag, $Release)
            . (Join-Path $ModuleRoot 'AgentSync.Process.ps1')
            . (Join-Path $ModuleRoot 'AgentSync.History.ps1')
            $script:PrescanBeforeBarrier = ${function:Get-AgentSyncHistoryPrescan}
            function Get-AgentSyncHistoryPrescan {
                param ($Root, $Line, $NestedUnits, $ExcludedRoots, $Settings)
                [System.IO.File]::WriteAllText($Flag, 'held')
                $Deadline = [DateTime]::UtcNow.AddSeconds(30)
                while (-not (Test-Path -LiteralPath $Release) -and [DateTime]::UtcNow -lt $Deadline) { Start-Sleep -Milliseconds 50 }
                if (-not (Test-Path -LiteralPath $Release)) { throw 'Snapshot test barrier timed out.' }
                & $script:PrescanBeforeBarrier @PSBoundParameters
            }
            New-AgentSyncHistorySnapshot -Unit $Unit -Settings $Settings -AllowBaseline
        }
        try {
            $Deadline = [DateTime]::UtcNow.AddSeconds(20)
            while (-not (Test-Path -LiteralPath $Flag) -and [DateTime]::UtcNow -lt $Deadline) { Start-Sleep -Milliseconds 50 }
            Test-Path -LiteralPath $Flag | Should -BeTrue -Because 'the first snapshot must actually hold the lock'
            $Next = New-AgentSyncHistorySnapshot -Unit $OtherUnit -Settings $OtherFixture.Settings -AllowBaseline
            $Next.Outcome | Should -Be $Expected -Because $Next.Reason
            if ($Expected -eq 'busy') { $Next.Commit | Should -BeNullOrEmpty }
        }
        finally {
            Set-Content -LiteralPath $Release -Value 'go'
            $Job | Wait-Job -Timeout 40 | Out-Null
            $First = @($Job | Receive-Job)
            $Job | Remove-Job -Force
        }
        $First[-1].Outcome | Should -Be 'committed'
    }

    It 'changes nothing on disk in a dry run' {
        $Fixture = New-HistoryFixture
        $Project = New-HistoryProject $Fixture 'P' @{ 'a.txt' = 'a' }
        $Unit = (Get-HistoryUnit $Fixture @($Project))[0]
        $Results = Invoke-AgentSyncHistoryUnitSnapshot -Unit $Unit -Settings $Fixture.Settings -AllowBaseline -DryRun
        $Results[0].Outcome | Should -Be 'dry-run'
        Test-Path -LiteralPath $Fixture.Settings.StoreDirectory | Should -BeFalse
        Test-Path -LiteralPath $Fixture.Settings.ExportDirectory | Should -BeFalse
    }

    It 'refuses to fill a history drive that is nearly full, and says why' {
        $Fixture = New-HistoryFixture
        $Fixture.Settings.MinFreeBytes = [long]::MaxValue
        $Project = New-HistoryProject $Fixture 'P' @{ 'a.txt' = 'a' }
        $Unit = (Get-HistoryUnit $Fixture @($Project))[0]
        $Result = New-AgentSyncHistorySnapshot -Unit $Unit -Settings $Fixture.Settings -AllowBaseline
        $Result.Outcome | Should -Be 'failed'
        $Result.Reason | Should -Match 'GB free'
    }
}

Describe 'History command line' {
    BeforeAll {
        function New-HistoryToolkitFixture {
            $Fixture = New-HistoryFixture
            $Project = New-HistoryProject $Fixture 'Kunde\Prosjekt' @{ 'a.txt' = 'a'; '.agent-state\claude\s.jsonl' = '{}' }
            New-Item -ItemType Directory -Path (Join-Path $Fixture.Root 'project-index') -Force | Out-Null
            $Index = [ordered]@{ format = 1; machine = 'TESTBOX'; root = $Fixture.Base; projects = @('Kunde/Prosjekt') }
            [System.IO.File]::WriteAllText((Join-Path $Fixture.Root 'project-index\TESTBOX.json'), ($Index | ConvertTo-Json))
            $Config = [ordered]@{
                sharedProjectsDir = $Fixture.Base
                history           = [ordered]@{ enabled = $false; storeDirectory = (Join-Path $Fixture.Root 'store'); exportDirectory = (Join-Path $Fixture.Root 'export'); minFreeGB = 0 }
            }
            [System.IO.File]::WriteAllText((Join-Path $Fixture.Root 'config.json'), ($Config | ConvertTo-Json -Depth 4))
            [pscustomobject]@{ Root = $Fixture.Root; Project = $Project; Config = (Join-Path $Fixture.Root 'config.json') }
        }

        function Invoke-HistoryCommand {
            param ($Toolkit, [string[]]$Arguments)
            $Script = Join-Path $PSScriptRoot '..\Invoke-AgentSyncHistory.ps1'
            $Text = & pwsh -NoProfile -NonInteractive -File $Script -ToolkitRoot $Toolkit.Root -ConfigFile $Toolkit.Config @Arguments 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = $Text }
        }
    }

    It 'parses, and keeps the switches the desktop app and the daemon depend on' {
        $Tokens = $null; $Errors = $null
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\Invoke-AgentSyncHistory.ps1'), [ref]$Tokens, [ref]$Errors)
        $Errors.Count | Should -Be 0
        $Names = @($Ast.ParamBlock.Parameters.Name.VariablePath.UserPath)
        foreach ($Expected in 'Initialize', 'Snapshot', 'Sweep', 'VerifyLedger', 'Project', 'All', 'Trigger', 'MissionId', 'ObservedSession', 'TimeBudgetSeconds', 'DryRun', 'Json') {
            $Names | Should -Contain $Expected
        }
    }

    It 'shows status without creating anything' {
        $Toolkit = New-HistoryToolkitFixture
        $Run = Invoke-HistoryCommand $Toolkit @()
        $Run.ExitCode | Should -Be 0
        $Run.Text | Should -Match 'no baseline'
        $Run.Text | Should -Match 'Kunde/Prosjekt'
        Test-Path -LiteralPath (Join-Path $Toolkit.Root 'store') | Should -BeFalse
    }

    It 'takes the baseline on request, sweeps without new snapshots, and leaves an intact ledger' {
        $Toolkit = New-HistoryToolkitFixture
        $Baseline = Invoke-HistoryCommand $Toolkit @('-Initialize', '-Project', $Toolkit.Project, '-Json')
        $Baseline.ExitCode | Should -Be 0
        $Document = $Baseline.Text.Trim() | ConvertFrom-Json
        $Document.action | Should -Be 'initialize'
        @($Document.results | Where-Object Outcome -EQ 'committed').Line | Sort-Object | Should -Be @('state', 'work')

        $Sweep = (Invoke-HistoryCommand $Toolkit @('-Sweep', '-Json')).Text.Trim() | ConvertFrom-Json
        $Sweep.counts.unchanged | Should -Be 2
        $Sweep.counts.committed | Should -Be 0

        [System.IO.File]::WriteAllText((Join-Path $Toolkit.Project 'a.txt'), 'changed')
        $Mission = (Invoke-HistoryCommand $Toolkit @('-Snapshot', '-Project', $Toolkit.Project, '-Trigger', 'mission-end', '-MissionId', 'mission-42', '-Json')).Text.Trim() | ConvertFrom-Json
        ($Mission.results | Where-Object Line -EQ 'work').Outcome | Should -Be 'committed'
        ($Mission.results | Where-Object Line -EQ 'work').MissionId | Should -Be 'mission-42'

        $Verify = Invoke-HistoryCommand $Toolkit @('-VerifyLedger')
        $Verify.ExitCode | Should -Be 0
        $Verify.Text | Should -Match 'Ledger intact'
    }

    It 'refuses to snapshot everything unless that is what was asked for' {
        $Toolkit = New-HistoryToolkitFixture
        $Run = Invoke-HistoryCommand $Toolkit @('-Snapshot')
        $Run.ExitCode | Should -Be 1
        $Run.Text | Should -Match '-Project'
    }
}

Describe 'History ledger and readable log' {
    It 'chains every line to the one before it and notices a changed line' {
        $Fixture = New-HistoryFixture
        1..4 | ForEach-Object { [void](Add-AgentSyncHistoryLedgerEntry -Settings $Fixture.Settings -Entry ([ordered]@{ event = 'snapshot'; unit = "u$_" })) }
        $Check = Test-AgentSyncHistoryLedger -Settings $Fixture.Settings
        $Check.Lines | Should -Be 4
        $Check.Ok | Should -BeTrue

        $File = Get-ChildItem -LiteralPath (Join-Path $Fixture.Settings.ExportDirectory 'ledger') -Filter '*.jsonl' | Select-Object -First 1
        $Lines = [System.IO.File]::ReadAllLines($File.FullName)
        ($Lines[0] | ConvertFrom-Json).prev | Should -BeNullOrEmpty
        ($Lines[1] | ConvertFrom-Json).prev | Should -Be (Get-AgentSyncHistoryLineHash -Line $Lines[0])

        $Lines[1] = $Lines[1].Replace('"u2"', '"uX"')
        [System.IO.File]::WriteAllLines($File.FullName, $Lines)
        $Tampered = Test-AgentSyncHistoryLedger -Settings $Fixture.Settings
        $Tampered.Ok | Should -BeFalse
        $Tampered.Broken[0].line | Should -Be 3
    }

    It 'notices a removal at either end, which the hash chain alone cannot' {
        # Codex, 19 September 2026: removing the newest of three entries still
        # returned Ok. It did, because every remaining link matched. A backward
        # chain says nothing about where the ledger ends, so the numbers and a
        # separate anchor carry that instead.
        $Fixture = New-HistoryFixture
        1..3 | ForEach-Object { [void](Add-AgentSyncHistoryLedgerEntry -Settings $Fixture.Settings -Entry ([ordered]@{ event = 'snapshot'; unit = "u$_" })) }
        $Directory = Join-Path $Fixture.Settings.ExportDirectory 'ledger'
        $File = (Get-ChildItem -LiteralPath $Directory -Filter '*.jsonl')[0].FullName
        $All = [System.IO.File]::ReadAllLines($File)
        (Test-AgentSyncHistoryLedger -Settings $Fixture.Settings).Ok | Should -BeTrue

        [System.IO.File]::WriteAllLines($File, $All[0..1])
        $Tail = Test-AgentSyncHistoryLedger -Settings $Fixture.Settings
        $Tail.Ok | Should -BeFalse
        $Tail.Broken[0].reason | Should -Match 'newest entries were removed'

        [System.IO.File]::WriteAllLines($File, $All[1..2])
        $Head = Test-AgentSyncHistoryLedger -Settings $Fixture.Settings
        $Head.Ok | Should -BeFalse
        $Head.Broken[0].reason | Should -Match 'earlier entries were removed'

        # And a missing anchor is a finding, not a footnote: without it, removal
        # at the end cannot be ruled out, and an unreadable check is not clean.
        [System.IO.File]::WriteAllLines($File, $All)
        Remove-Item -LiteralPath (Join-Path $Directory 'tip.json')
        $NoAnchor = Test-AgentSyncHistoryLedger -Settings $Fixture.Settings
        $NoAnchor.Ok | Should -BeFalse
        $NoAnchor.Anchor | Should -Be 'missing'
        $NoAnchor.Broken[0].reason | Should -Match 'cannot be ruled out'
    }

    It 'says what a clean answer actually covered' {
        $Fixture = New-HistoryFixture
        [void](Add-AgentSyncHistoryLedgerEntry -Settings $Fixture.Settings -Entry ([ordered]@{ event = 'snapshot' }))
        $Check = Test-AgentSyncHistoryLedger -Settings $Fixture.Settings
        $Check.Ok | Should -BeTrue
        $Check.Checked | Should -Match 'hash chain over 1 entries, numbering on 1, anchor read'
    }

    It 'continues the chain across a month boundary' {
        $Fixture = New-HistoryFixture
        $Directory = Join-Path $Fixture.Settings.ExportDirectory 'ledger'
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
        $Old = '{"v":1,"t":"2001-01-31T23:59:00.0000000Z","machine":"TESTBOX","event":"snapshot","prev":null}'
        [System.IO.File]::WriteAllText((Join-Path $Directory '2001-01.jsonl'), "$Old`n")
        [void](Add-AgentSyncHistoryLedgerEntry -Settings $Fixture.Settings -Entry ([ordered]@{ event = 'snapshot' }))
        $Current = Get-ChildItem -LiteralPath $Directory -Filter '*.jsonl' | Sort-Object Name | Select-Object -Last 1
        (([System.IO.File]::ReadAllLines($Current.FullName))[0] | ConvertFrom-Json).prev | Should -Be (Get-AgentSyncHistoryLineHash -Line $Old)
        (Test-AgentSyncHistoryLedger -Settings $Fixture.Settings).Ok | Should -BeTrue
    }

    It 'carries metadata only: a new free-text field has to be argued for here' {
        $Fixture = New-HistoryFixture
        $Project = New-HistoryProject $Fixture 'P' @{ 'a.txt' = 'a' }
        $Unit = (Get-HistoryUnit $Fixture @($Project))[0]
        [void](Invoke-AgentSyncHistoryUnitSnapshot -Unit $Unit -Settings $Fixture.Settings -Trigger 'mission-end' -MissionId 'mission-123' -ObservedSessions @('codex:01a0') -AllowBaseline)

        $File = Get-ChildItem -LiteralPath (Join-Path $Fixture.Settings.ExportDirectory 'ledger') -Filter '*.jsonl' | Select-Object -First 1
        $Entry = ([System.IO.File]::ReadAllLines($File.FullName))[0] | ConvertFrom-Json
        @($Entry.PSObject.Properties.Name) | Should -Be @('v', 'seq', 't', 'machine', 'event', 'unit', 'path', 'line', 'trigger', 'outcome', 'status', 'reason', 'commit', 'parent', 'added', 'modified', 'deleted', 'skipped', 'unreadable', 'mission', 'observed', 'seconds', 'prev')
        $Entry.mission | Should -Be 'mission-123'
        $Entry.observed | Should -Be @('codex:01a0')
    }

    It 'writes one readable Norwegian line per snapshot under a day heading, and says observed, not made by' {
        $Fixture = New-HistoryFixture
        $Project = New-HistoryProject $Fixture 'P' @{ 'a.txt' = 'a' }
        $Unit = (Get-HistoryUnit $Fixture @($Project))[0]
        [void](Invoke-AgentSyncHistoryUnitSnapshot -Unit $Unit -Settings $Fixture.Settings -Trigger 'baseline' -AllowBaseline)
        [System.IO.File]::WriteAllText((Join-Path $Project 'a.txt'), 'changed')
        [void](Invoke-AgentSyncHistoryUnitSnapshot -Unit $Unit -Settings $Fixture.Settings -Trigger 'mission-end' -MissionId 'mission-9' -ObservedSessions @('claude:cbe5'))

        $Log = Get-ChildItem -LiteralPath $Unit.ExportPath -Filter 'HISTORIKK-*.md' | Select-Object -First 1
        $Text = [System.IO.File]::ReadAllText($Log.FullName)
        @([regex]::Matches($Text, '(?m)^## \d{4}-\d{2}-\d{2}$')).Count | Should -Be 1
        $Text | Should -Match 'arbeidsfiler · grunnlinje · 1 filer'
        $Text | Should -Match 'oppdrag slutt · 1 endret, 0 nye, 0 slettet'
        $Text | Should -Match 'observert: claude:cbe5'
        $Text | Should -Match 'bilde [0-9a-f]{10}'
        $Text | Should -Match 'a\.txt'
        $Text | Should -Not -Match 'laget av'
    }

    It 'says so when only the rules changed, instead of reading as if nothing happened' {
        $Fixture = New-HistoryFixture
        $Project = New-HistoryProject $Fixture 'P' @{ 'a.txt' = 'a'; 'big.bin' = ('x' * 4096) }
        $Unit = (Get-HistoryUnit $Fixture @($Project))[0]
        [void](Invoke-AgentSyncHistoryUnitSnapshot -Unit $Unit -Settings $Fixture.Settings -Trigger 'baseline' -AllowBaseline)

        # Same files, stricter policy: big.bin leaves the snapshot.
        $Fixture.Settings.LargeFileBytes = 1024
        $Second = (Invoke-AgentSyncHistoryUnitSnapshot -Unit $Unit -Settings $Fixture.Settings)[0]
        $Second.Outcome | Should -Be 'committed'
        $Second.Deleted | Should -Be 1

        # And once more with nothing at all changed but the manifest.
        $Fixture.Settings.StoreLargeFiles = $false
        $Third = (Invoke-AgentSyncHistoryUnitSnapshot -Unit $Unit -Settings $Fixture.Settings)[0]
        $Third.Outcome | Should -Be 'committed'
        @($Third.Added, $Third.Modified, $Third.Deleted) | Should -Be @(0, 0, 0)
        $Text = [System.IO.File]::ReadAllText((Get-ChildItem -LiteralPath $Unit.ExportPath -Filter 'HISTORIKK-*.md')[0].FullName)
        $Text | Should -Match 'reglene for hva som tas med er endret'
        $Text | Should -Not -Match '0 endret, 0 nye, 0 slettet'
    }

    It 'writes down the snapshot that was not taken for a mission, but not the one a sweep skipped' {
        $Fixture = New-HistoryFixture
        $Project = New-HistoryProject $Fixture 'P' @{ 'a.txt' = 'a' }
        $Unit = (Get-HistoryUnit $Fixture @($Project))[0]
        [void](Invoke-AgentSyncHistoryUnitSnapshot -Unit $Unit -Settings $Fixture.Settings -Trigger 'sweep')
        Test-Path -LiteralPath (Join-Path $Fixture.Settings.ExportDirectory 'ledger') | Should -BeFalse

        [void](Invoke-AgentSyncHistoryUnitSnapshot -Unit $Unit -Settings $Fixture.Settings -Trigger 'mission-start' -MissionId 'mission-7')
        $File = Get-ChildItem -LiteralPath (Join-Path $Fixture.Settings.ExportDirectory 'ledger') -Filter '*.jsonl' | Select-Object -First 1
        $Entry = ([System.IO.File]::ReadAllLines($File.FullName))[0] | ConvertFrom-Json
        $Entry.outcome | Should -Be 'no-baseline'
        $Entry.mission | Should -Be 'mission-7'
        [System.IO.File]::ReadAllText((Get-ChildItem -LiteralPath $Unit.ExportPath -Filter 'HISTORIKK-*.md')[0].FullName) | Should -Match 'ikke tatt'
    }
}
