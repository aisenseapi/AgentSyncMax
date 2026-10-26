# Tests for capturing JetBrains Junie sessions into projects.
#
# Loaded the same way as AgentSync.Tests.ps1: the engine is parsed to an AST and
# only its function definitions are dot-sourced, with script state stubbed.
#
# Run:  pwsh -NoProfile -Command "Invoke-Pester -Path tests/Junie.Tests.ps1 -Output Detailed"

BeforeAll {
    . (Join-Path $PSScriptRoot '..\AgentSync.Process.ps1')
    $EnginePath = Join-Path $PSScriptRoot '..\Sync-AgentState.ps1'
    $Tokens = $null
    $Errors = $null
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile($EnginePath, [ref]$Tokens, [ref]$Errors)
    if ($Errors.Count -gt 0) { throw "Engine does not parse: $($Errors[0].Message)" }
    $Functions = $Ast.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
    . ([scriptblock]::Create((($Functions | ForEach-Object { $_.Extent.Text }) -join "`n")))

    $Script:MachineId = 'TESTHOST'
    $Script:PlatformName = 'windows'
    $Script:PathComparison = [System.StringComparison]::OrdinalIgnoreCase
    $Script:DryRun = $false
    $Script:TouchedProjects = @{}
    $Script:HeartbeatSeen = @{}
    $Script:UnsafeIdWarned = @{}
    $Script:UnreadableWarned = @{}
    $Script:SessionCwdCache = @{}
    $Script:WatchAgentByPath = @{}
    $Script:ToolkitRoot = 'P:\Dropbox\Tools\AgentSyncToolkit'
    $Script:WatchEventLogTimes = @{}
    $Script:WatcherSequence = 0
    $Script:SelfWrittenPaths = @{}
    $Script:CycleErrorCount = 0
    $Script:CycleDeferredCopies = 0
    $Script:CycleContentConflicts = 0
    $Script:CycleNewContentConflicts = 0
    $Script:SilentFailures = @{}
    $Script:ScopeEscalationWarned = @{}
    $Script:TestLog = [System.Collections.Generic.List[string]]::new()
    $Script:Config = [PSCustomObject]@{
        maxRetryCount = 3
        fileLockRetryDelayMs = 10
        safety = [PSCustomObject]@{
            protectAppendOnly = $true
            overwrittenRetentionDays = 7
            overwrittenKeepPerFile = 3
        }
        activity = [PSCustomObject]@{ parallelWarningSeconds = 120 }
        projectAliases = $null
    }

    function Write-AgentSyncLog {
        param ([string]$Level, [string]$Message, [switch]$Console)
        [void]$Script:TestLog.Add("$Level $Message")
    }
    function Write-ActivityHeartbeat { param ($ProjectRoot, $AgentName, $SessionId, $Direction) }
    function Write-Host { param ([Parameter(ValueFromRemainingArguments)]$Rest, $ForegroundColor) }

    # A Junie layout as JetBrains writes it: an IDE system folder holding one
    # folder per project, named <project name>.<hash of the project path>.
    function New-JunieFixture {
        param (
            [string]$Root,
            [string[]]$ProjectPaths,
            [string]$Ide = 'PhpStorm2026.2'
        )
        $System = Join-Path $Root 'system'
        $Options = Join-Path $Root 'options'
        $Chains = @{}
        $Entries = foreach ($ProjectPath in $ProjectPaths) {
            New-Item -ItemType Directory -Path $ProjectPath -Force | Out-Null
            $Key = $ProjectPath.Replace('\', '/')
            $Folder = '{0}.{1:x}' -f (Split-Path $ProjectPath -Leaf), (Get-JavaStringHash -Text $Key)
            $Matterhorn = Join-Path $System "$Ide\projects\$Folder\matterhorn\.matterhorn"
            $Id = [guid]::NewGuid().ToString()
            $Chains[$ProjectPath] = [PSCustomObject]@{ Id = $Id; Matterhorn = $Matterhorn; Folder = $Folder }
            New-Item -ItemType Directory -Path "$Matterhorn\issues\chain-$Id\task-0\steps" -Force | Out-Null
            New-Item -ItemType Directory -Path "$Matterhorn\exit_status" -Force | Out-Null
            Set-Content -LiteralPath "$Matterhorn\issues\chain-$Id.json" -Value ('{"id":{"id":"' + $Id + '"},"name":"Test","created":"2026-09-30T07:58:47Z","state":"Finished"}') -NoNewline
            Set-Content -LiteralPath "$Matterhorn\issues\chain-$Id\task-0.json" -Value '{"id":"t0","sessionHistory":[]}' -NoNewline
            Set-Content -LiteralPath "$Matterhorn\issues\chain-$Id\task-0\steps\step-0.json" -Value '{"step":0}' -NoNewline
            Set-Content -LiteralPath "$Matterhorn\exit_status\$Id 0.status" -Value '0' -NoNewline
            # Belongs to no conversation, so it must not be captured.
            Set-Content -LiteralPath "$Matterhorn\exit.status" -Value '0' -NoNewline
            "    <entry key=`"$([Security.SecurityElement]::Escape($Key))`"><value><RecentProjectMetaInfo /></value></entry>"
        }
        New-Item -ItemType Directory -Path "$Options\$Ide\options" -Force | Out-Null
        @(
            '<application>'
            '  <component name="RecentProjectsManager"><option name="additionalInfo"><map>'
            $Entries
            '  </map></option></component>'
            '</application>'
        ) | Set-Content -LiteralPath "$Options\$Ide\options\recentProjects.xml"
        return [PSCustomObject]@{
            Chains = $Chains
            Agent = [PSCustomObject]@{
                name = 'junie'
                targetSubDir = '.agent-state/junie'
                routingMode = 'junie'
                roots = @([PSCustomObject]@{ surface = 'ide'; localPathWindows = $System; optionsPathWindows = $Options })
            }
        }
    }

    function Get-NativeRoot {
        param ([string]$ProjectRoot, [string]$Id)
        return Join-Path $ProjectRoot ".agent-state\junie\ide\sessions\$Id\native"
    }
}

Describe 'Junie project mapping' {

    It 'reproduces Java String.hashCode for a synthetic project folder' {
        # "hello".hashCode() is 99162322 in Java.
        Get-JavaStringHash -Text 'hello' | Should -Be ([uint32]99162322)
        # Independently calculated with Java's 31-based, 32-bit hash formula.
        '{0:x}' -f (Get-JavaStringHash -Text 'C:/Projects/SampleApp/code/php') | Should -Be 'fd05074b'
    }

    It 'splits a project folder at its last dot, and rejects a folder without a hash' {
        $Folder = Split-JunieProjectFolderName -Name 'my.app.1a2b3c4d'
        $Folder.Name | Should -Be 'my.app'
        $Folder.Hash | Should -Be ([uint32]0x1a2b3c4d)
        Split-JunieProjectFolderName -Name 'nohash' | Should -BeNullOrEmpty
    }

    It 'tells apart two projects with the same name by their hash' {
        $First = 'P:/Dropbox/Kunde/php'
        $Second = 'P:/Dropbox/Annet/php'
        $FirstFolder = 'php.{0:x}' -f (Get-JavaStringHash -Text $First)
        $SecondFolder = 'php.{0:x}' -f (Get-JavaStringHash -Text $Second)
        Resolve-JunieProjectPath -FolderName $FirstFolder -Candidates @($First, $Second) | Should -Be $First
        Resolve-JunieProjectPath -FolderName $SecondFolder -Candidates @($First, $Second) | Should -Be $Second
    }

    It 'never places sessions in a project whose name matches but whose hash does not' {
        Resolve-JunieProjectPath -FolderName 'php.12345678' -Candidates @('P:/Dropbox/Kunde/php') | Should -BeNullOrEmpty
    }

    It 'still finds a project the IDE has renamed, because the hash comes from the path' {
        $Path = 'P:/Dropbox/Kunde/php'
        Resolve-JunieProjectPath -FolderName ('Kundeportal.{0:x}' -f (Get-JavaStringHash -Text $Path)) -Candidates @($Path) | Should -Be $Path
    }

    It 'expands the home macro JetBrains writes into recentProjects.xml' {
        $Options = Join-Path $TestDrive 'options-home'
        New-Item -ItemType Directory -Path "$Options\PhpStorm2026.2\options" -Force | Out-Null
        '<application><component name="RecentProjectsManager"><option name="additionalInfo"><map><entry key="$USER_HOME$/code/app" /><entry key="P:/Dropbox/x" /></map></option></component></application>' |
            Set-Content -LiteralPath "$Options\PhpStorm2026.2\options\recentProjects.xml"
        $Home_ = ([Environment]::GetFolderPath('UserProfile')).Replace('\', '/').TrimEnd('/')
        $Paths = @(Get-JunieRecentProjectPaths -OptionsRoot $Options -IdeDirName 'PhpStorm2026.2')
        $Paths | Should -Contain "$Home_/code/app"
        $Paths | Should -Contain 'P:/Dropbox/x'
    }
}

Describe 'Sync-Junie' {

    BeforeEach {
        $Script:TestLog.Clear()
        $Script:JunieUnresolvedReported = @{}
        # The workspace is its own project root here; project discovery is the
        # engine's concern and is tested elsewhere.
        Mock Get-ProjectRootFromCwd { param ([string]$Cwd) return $Cwd }
        Mock Get-AgentSyncProjects { @() }
    }

    It 'captures every file of a conversation into the project, and nothing else' {
        $Project = Join-Path $TestDrive 'a\SampleApp\code\php'
        $Fixture = New-JunieFixture -Root (Join-Path $TestDrive 'a') -ProjectPaths @($Project)
        $Chain = $Fixture.Chains[$Project]

        Sync-Junie -Agent $Fixture.Agent

        $Native = Get-NativeRoot -ProjectRoot $Project -Id $Chain.Id
        foreach ($Relative in @("issues\chain-$($Chain.Id).json", "issues\chain-$($Chain.Id)\task-0.json", "issues\chain-$($Chain.Id)\task-0\steps\step-0.json", "exit_status\$($Chain.Id) 0.status")) {
            $Copy = Join-Path $Native $Relative
            Test-Path -LiteralPath $Copy | Should -BeTrue -Because $Relative
            (Get-FileHash -LiteralPath $Copy).Hash | Should -Be (Get-FileHash -LiteralPath (Join-Path $Chain.Matterhorn $Relative)).Hash
        }
        @(Get-ChildItem -LiteralPath (Join-Path $Project '.agent-state') -Recurse -Filter 'exit.status').Count | Should -Be 0
    }

    It 'writes where the session came from, and leaves the IDE folder untouched' {
        $Project = Join-Path $TestDrive 'b\php'
        $Fixture = New-JunieFixture -Root (Join-Path $TestDrive 'b') -ProjectPaths @($Project)
        $Chain = $Fixture.Chains[$Project]
        $Before = @(Get-ChildItem -LiteralPath $Chain.Matterhorn -Recurse -File | ForEach-Object { "$($_.FullName)|$((Get-FileHash -LiteralPath $_.FullName).Hash)" })

        Sync-Junie -Agent $Fixture.Agent

        $After = @(Get-ChildItem -LiteralPath $Chain.Matterhorn -Recurse -File | ForEach-Object { "$($_.FullName)|$((Get-FileHash -LiteralPath $_.FullName).Hash)" })
        Compare-Object $Before $After | Should -BeNullOrEmpty
        $Index = Get-Content -LiteralPath (Join-Path $Project ".agent-state\index\junie-workspaces\ide\$($Chain.Id).json") -Raw | ConvertFrom-Json
        $Index.workspace | Should -Be $Project
        $Index.ide | Should -Be 'PhpStorm2026.2'
        $Index.projectFolder | Should -Be $Chain.Folder
        $Index.machine | Should -Be 'TESTHOST'
        $Index.state | Should -Be 'Finished'
    }

    It 'copies nothing on a second run when nothing changed' {
        $Project = Join-Path $TestDrive 'c\php'
        $Fixture = New-JunieFixture -Root (Join-Path $TestDrive 'c') -ProjectPaths @($Project)
        Sync-Junie -Agent $Fixture.Agent
        $Script:TestLog.Clear()

        Sync-Junie -Agent $Fixture.Agent

        @($Script:TestLog | Where-Object { $_ -match 'SYNC agent=junie' }).Count | Should -Be 0
    }

    It 'follows a conversation that grows, and keeps what Junie later deletes' {
        $Project = Join-Path $TestDrive 'd\php'
        $Fixture = New-JunieFixture -Root (Join-Path $TestDrive 'd') -ProjectPaths @($Project)
        $Chain = $Fixture.Chains[$Project]
        $Task = Join-Path $Chain.Matterhorn "issues\chain-$($Chain.Id)\task-0.json"
        Sync-Junie -Agent $Fixture.Agent

        Set-Content -LiteralPath $Task -Value '{"id":"t0","sessionHistory":["a longer conversation"]}' -NoNewline
        Sync-Junie -Agent $Fixture.Agent
        $Copy = Join-Path (Get-NativeRoot -ProjectRoot $Project -Id $Chain.Id) "issues\chain-$($Chain.Id)\task-0.json"
        (Get-Content -LiteralPath $Copy -Raw) | Should -Match 'a longer conversation'

        Remove-Item -LiteralPath (Join-Path $Chain.Matterhorn 'issues') -Recurse -Force
        Sync-Junie -Agent $Fixture.Agent
        Test-Path -LiteralPath $Copy | Should -BeTrue -Because 'history is kept when the source goes away'
    }

    It 'keeps two projects with the same name apart' {
        $First = Join-Path $TestDrive 'e\Kunde\php'
        $Second = Join-Path $TestDrive 'e\Annet\php'
        $Fixture = New-JunieFixture -Root (Join-Path $TestDrive 'e') -ProjectPaths @($First, $Second)

        Sync-Junie -Agent $Fixture.Agent

        Test-Path -LiteralPath (Get-NativeRoot -ProjectRoot $First -Id $Fixture.Chains[$First].Id) | Should -BeTrue
        Test-Path -LiteralPath (Get-NativeRoot -ProjectRoot $Second -Id $Fixture.Chains[$Second].Id) | Should -BeTrue
        Test-Path -LiteralPath (Get-NativeRoot -ProjectRoot $First -Id $Fixture.Chains[$Second].Id) | Should -BeFalse
        Test-Path -LiteralPath (Get-NativeRoot -ProjectRoot $Second -Id $Fixture.Chains[$First].Id) | Should -BeFalse
    }

    It 'leaves sessions it cannot place where they are, and says so once' {
        $Project = Join-Path $TestDrive 'f\php'
        $Fixture = New-JunieFixture -Root (Join-Path $TestDrive 'f') -ProjectPaths @($Project)
        # The IDE forgot the project: nothing on record hashes to its folder.
        Remove-Item -LiteralPath (Join-Path $TestDrive 'f\options') -Recurse -Force

        Sync-Junie -Agent $Fixture.Agent
        Sync-Junie -Agent $Fixture.Agent

        Test-Path -LiteralPath (Join-Path $Project '.agent-state') | Should -BeFalse
        @($Script:TestLog | Where-Object { $_ -match 'JUNIE_PROJECT_UNRESOLVED' }).Count | Should -Be 1
    }

    It 'skips a conversation whose id is not a safe folder name' {
        $Project = Join-Path $TestDrive 'g\php'
        $Fixture = New-JunieFixture -Root (Join-Path $TestDrive 'g') -ProjectPaths @($Project)
        Set-Content -LiteralPath (Join-Path $Fixture.Chains[$Project].Matterhorn 'issues\chain-bad id!.json') -Value '{}' -NoNewline

        Sync-Junie -Agent $Fixture.Agent

        @(Get-ChildItem -LiteralPath (Join-Path $Project '.agent-state\junie\ide\sessions') -Directory).Name | Should -Be @($Fixture.Chains[$Project].Id)
    }

    It 'writes nothing in a dry run' {
        $Project = Join-Path $TestDrive 'h\php'
        $Fixture = New-JunieFixture -Root (Join-Path $TestDrive 'h') -ProjectPaths @($Project)
        $Script:DryRun = $true
        try { Sync-Junie -Agent $Fixture.Agent }
        finally { $Script:DryRun = $false }
        Test-Path -LiteralPath (Join-Path $Project '.agent-state') | Should -BeFalse
    }
}

Describe 'Junie in the event scope' {

    It 'does not escalate a change under .agent-state\junie to a full cycle' {
        $Event = [PSCustomObject]@{
            SourceIdentifier = 'AgentSyncWatcher-1-0-P-Changed'
            SourceEventArgs = [PSCustomObject]@{ FullPath = 'P:\Dropbox\Proj\A\.agent-state\junie\ide\sessions\x\native\issues\chain-x.json' }
        }
        $Scope = Get-EventScope -WatcherEvent $Event
        $Scope.Full | Should -BeFalse
        @($Scope.Agents).Count | Should -Be 0
        $Scope.ProjectRoot | Should -Be 'P:\Dropbox\Proj\A'
    }

    It 'does not escalate a Junie index write either' {
        $Event = [PSCustomObject]@{
            SourceIdentifier = 'AgentSyncWatcher-1-0-P-Changed'
            SourceEventArgs = [PSCustomObject]@{ FullPath = 'P:\Dropbox\Proj\A\.agent-state\index\junie-workspaces\ide\x.json' }
        }
        $Scope = Get-EventScope -WatcherEvent $Event
        $Scope.Full | Should -BeFalse
        @($Scope.Agents).Count | Should -Be 0
    }
}

Describe 'Junie in the watcher' {

    BeforeEach {
        Mock Get-AgentSyncProjects { @() }
        Mock Get-AgentSyncProjectIndexDirectory { Join-Path $TestDrive 'no-index' }
    }

    AfterEach {
        $Script:WatchAgentByPath = @{}
    }

    It 'watches the folder Junie writes in each project, not the IDE folder around it' {
        $Used = Join-Path $TestDrive 'w\php'
        $Fixture = New-JunieFixture -Root (Join-Path $TestDrive 'w') -ProjectPaths @($Used)
        # A project the IDE has opened but where Junie was never used.
        New-Item -ItemType Directory -Path (Join-Path $TestDrive 'w\system\PhpStorm2026.2\projects\other.1a2b3c4d\caches') -Force | Out-Null
        # Read by Get-AgentWatchPaths through the caller's scope.
        $Config = [PSCustomObject]@{ agents = @($Fixture.Agent) }

        $Paths = @(Get-AgentWatchPaths)

        $Matterhorn = $Fixture.Chains[$Used].Matterhorn
        $Paths | Should -Be @($Matterhorn)
        $Script:WatchAgentByPath[$Matterhorn] | Should -Be 'junie'
    }

    It 'sends a change in a watched Junie folder to the Junie adapter alone' {
        $Matterhorn = 'C:\Users\x\AppData\Local\JetBrains\PhpStorm2026.2\projects\php.fd05074b\matterhorn\.matterhorn'
        $Script:WatchAgentByPath = @{ $Matterhorn = 'junie' }
        $Event = [PSCustomObject]@{
            SourceIdentifier = 'AgentSyncWatcher-1-0-A-Changed'
            SourceEventArgs = [PSCustomObject]@{ FullPath = "$Matterhorn\issues\chain-x\task-0.json" }
        }

        $Scope = Get-EventScope -WatcherEvent $Event

        $Scope.Full | Should -BeFalse
        @($Scope.Agents) | Should -Be @('junie')
    }
}
