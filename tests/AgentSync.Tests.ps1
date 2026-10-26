# Unit tests for the AgentSync engine's decision logic.
#
# The engine is a single script that starts a daemon at the bottom, so the
# tests load ONLY its function definitions: the file is parsed to an AST and
# every top-level function is dot-sourced into this scope. Script-scope state
# the functions rely on is stubbed in BeforeAll, and side-effectful helpers
# (logging, heartbeats) are overridden after loading.
#
# Run:  pwsh -NoProfile -Command "Invoke-Pester -Path tests -Output Detailed"

BeforeAll {
    . (Join-Path $PSScriptRoot '..\AgentSync.Process.ps1')
    $EnginePath = Join-Path $PSScriptRoot '..\Sync-AgentState.ps1'

    $Tokens = $null
    $Errors = $null
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile($EnginePath, [ref]$Tokens, [ref]$Errors)
    if ($Errors.Count -gt 0) {
        throw "Engine does not parse: $($Errors[0].Message)"
    }

    $Functions = $Ast.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
    $Definitions = ($Functions | ForEach-Object { $_.Extent.Text }) -join "`n"

    # Accessors created in the SAME scriptblock as the engine functions, so
    # they resolve $Script: against the same scope the engine mutates.
    $Definitions += @'

function Get-TouchedProjectsForTest { $Script:TouchedProjects }
function Reset-TouchedProjectsForTest { $Script:TouchedProjects = @{} }
function Get-DiagStateForTest { [PSCustomObject]@{ Errors = $Script:CycleErrorCount; Silent = $Script:SilentFailures } }
function Reset-DiagStateForTest { $Script:CycleErrorCount = 0; $Script:CycleContentConflicts = 0; $Script:CycleNewContentConflicts = 0; $Script:SilentFailures = @{}; $Script:ScopeEscalationWarned = @{} }
'@
    . ([scriptblock]::Create($Definitions))

    # --- Script-scope state the functions expect ---------------------------
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

    # --- Silence side effects ---------------------------------------------
    function Write-AgentSyncLog {
        param ([string]$Level, [string]$Message, [switch]$Console)
        [void]$Script:TestLog.Add("$Level $Message")
    }
    function Write-ActivityHeartbeat { param ($ProjectRoot, $AgentName, $SessionId, $Direction) }
    function Write-Host { param ([Parameter(ValueFromRemainingArguments)]$Rest, $ForegroundColor) }

    # Helper to build a watcher-event-shaped object for Get-EventScope.
    function New-FakeEvent {
        param ([string]$FullPath, [string]$Identifier = 'AgentSyncWatcher-1-0-P-Changed')
        [PSCustomObject]@{
            SourceIdentifier = $Identifier
            SourceEventArgs = [PSCustomObject]@{ FullPath = $FullPath }
        }
    }
}

Describe 'Get-EventScope' {

    Context 'project-state paths (agent and project parsed from the path)' {

        It 'maps a claude session write to the claude agent and its project' {
            $Scope = Get-EventScope -WatcherEvent (New-FakeEvent 'P:\Dropbox\Proj\A\.agent-state\claude\sessions\bucket\x.jsonl')
            $Scope.Full | Should -BeFalse
            $Scope.Agents | Should -Be @('claude')
            $Scope.ProjectRoot | Should -Be 'P:\Dropbox\Proj\A'
        }

        It 'maps codex archived_sessions to the codex-archived agent' {
            $Scope = Get-EventScope -WatcherEvent (New-FakeEvent 'P:\Dropbox\Proj\A\.agent-state\codex\archived_sessions\r.jsonl')
            $Scope.Agents | Should -Be @('codex-archived')
        }

        It 'maps codex sessions to the codex agent' {
            $Scope = Get-EventScope -WatcherEvent (New-FakeEvent 'P:\Dropbox\Proj\A\.agent-state\codex\sessions\2026\08\r.jsonl')
            $Scope.Agents | Should -Be @('codex')
        }

        It 'maps every <agent>-workspaces index to that agent' {
            # A new agent folder here used to escalate every write to a full cycle.
            (Get-EventScope -WatcherEvent (New-FakeEvent 'P:\D\P1\.agent-state\index\antigravity-workspaces\cli\c1.json')).Agents | Should -Be @('antigravity')
            $ClineScope = Get-EventScope -WatcherEvent (New-FakeEvent 'P:\D\P1\.agent-state\index\cline-workspaces\w1.json')
            $ClineScope.Full | Should -BeFalse
            $ClineScope.Agents | Should -Be @('cline')
            # An unknown folder still escalates rather than being skipped.
            (Get-EventScope -WatcherEvent (New-FakeEvent 'P:\D\P1\.agent-state\index\mystery-workspaces\w1.json')).Full | Should -BeTrue
        }

        It 'maps antigravity, opencode and cline state paths to their agents' {
            (Get-EventScope -WatcherEvent (New-FakeEvent 'P:\D\P1\.agent-state\antigravity\cli\sessions\c1\f')).Agents | Should -Be @('antigravity')
            (Get-EventScope -WatcherEvent (New-FakeEvent 'P:\D\P1\.agent-state\opencode\sessions\s1.json')).Agents | Should -Be @('opencode')
            (Get-EventScope -WatcherEvent (New-FakeEvent 'P:\D\P1\.agent-state\cline\sdk\sessions\s1\m.json')).Agents | Should -Be @('cline')
        }

        It 'maps the antigravity workspace index to the antigravity agent' {
            $Scope = Get-EventScope -WatcherEvent (New-FakeEvent 'P:\D\P1\.agent-state\index\antigravity-workspaces\cli\c1.json')
            $Scope.Agents | Should -Be @('antigravity')
        }

        It 'escalates an unknown state segment to a full cycle' {
            $Scope = Get-EventScope -WatcherEvent (New-FakeEvent 'P:\D\P1\.agent-state\some-new-agent\sessions\f.jsonl')
            $Scope.Full | Should -BeTrue
        }

        It 'resolves the deepest .agent-state as the owning project' {
            $Scope = Get-EventScope -WatcherEvent (New-FakeEvent 'P:\D\Outer\.agent-state\claude\Inner\.agent-state\claude\x.jsonl')
            $Scope.ProjectRoot | Should -Be 'P:\D\Outer\.agent-state\claude\Inner'
        }
    }

    Context 'native agent roots (mapped at watcher registration)' {

        BeforeEach {
            $Script:WatchAgentByPath = @{
                'C:\Users\t\.claude\projects' = 'claude'
                'C:\Users\t\.codex\sessions' = 'codex'
                'C:\Users\t\.codex\archived_sessions' = 'codex-archived'
                'C:\Users\t\tools\project-index' = '*full*'
            }
        }

        It 'maps a write under a registered agent root to that agent' {
            $Scope = Get-EventScope -WatcherEvent (New-FakeEvent 'C:\Users\t\.claude\projects\bucket\s.jsonl' 'AgentSyncWatcher-1-9-A-Changed')
            $Scope.Full | Should -BeFalse
            $Scope.Agents | Should -Be @('claude')
            $Scope.ProjectRoot | Should -BeNullOrEmpty
        }

        It 'prefers the longest matching root' {
            $Scope = Get-EventScope -WatcherEvent (New-FakeEvent 'C:\Users\t\.codex\archived_sessions\r.jsonl' 'AgentSyncWatcher-1-9-A-Changed')
            $Scope.Agents | Should -Be @('codex-archived')
        }

        It 'escalates the project-index directory to a full cycle' {
            $Scope = Get-EventScope -WatcherEvent (New-FakeEvent 'C:\Users\t\tools\project-index\OTHER.json' 'AgentSyncWatcher-1-9-A-Changed')
            $Scope.Full | Should -BeTrue
        }

        It 'escalates an unmatchable path to a full cycle' {
            $Scope = Get-EventScope -WatcherEvent (New-FakeEvent 'D:\somewhere\else\f.txt' 'AgentSyncWatcher-1-9-A-Changed')
            $Scope.Full | Should -BeTrue
        }

        It 'escalates a missing FullPath to a full cycle' {
            $Broken = [PSCustomObject]@{ SourceIdentifier = 'AgentSyncWatcher-1-9-A-Changed'; SourceEventArgs = $null }
            (Get-EventScope -WatcherEvent $Broken).Full | Should -BeTrue
        }
    }
}

Describe 'Mission Control checkpoints are not agent history' {

    # A checkpoint is a full copy of a project, thousands of files at a time,
    # written inside the toolkit folder. It must never dirty an adapter scope.
    # Historical CPU observations do not prove this was the only trigger.

    It 'ignores a write under missions entirely' {
        $Event = New-FakeEvent -FullPath 'P:\Dropbox\Tools\AgentSyncToolkit\missions\checkpoints\mission-1\before\src\a.js'
        $Scope = Get-EventScope -WatcherEvent $Event

        $Scope.Full | Should -BeFalse
        @($Scope.Agents).Count | Should -Be 0
        $Scope.ProjectRoot | Should -BeNullOrEmpty
        Test-RelevantWatcherEvent -WatcherEvent $Event | Should -Be 'ignore'
    }

    It 'ignores the mission records themselves' {
        $Event = New-FakeEvent -FullPath 'P:\Dropbox\Tools\AgentSyncToolkit\missions\mission-1.json'
        (Get-EventScope -WatcherEvent $Event).Full | Should -BeFalse
    }

    It 'still watches a project that merely has missions in its name' {
        $Event = New-FakeEvent -FullPath 'P:\Dropbox\Proj\missionsplan\.agent-state\claude\s.jsonl'
        (Get-EventScope -WatcherEvent $Event).ProjectRoot | Should -Be 'P:\Dropbox\Proj\missionsplan'
    }

    It 'retains a legitimate project inside a directory named exactly missions' {
        $Event = New-FakeEvent -FullPath 'P:\Dropbox\missions\Proj\.agent-state\claude\s.jsonl'
        Test-RelevantWatcherEvent -WatcherEvent $Event | Should -Be 'relevant'
        $Scope = Get-EventScope -WatcherEvent $Event
        $Scope.ProjectRoot | Should -Be 'P:\Dropbox\missions\Proj'
        $Scope.Agents | Should -Be @('claude')
    }
}

Describe 'Aider writes into the project itself' {

    # Aider has no native directory to copy from: it writes its history
    # straight into .agent-state/aider/. An unknown segment there escalates
    # every write to a full cycle, which is what Cline's 'index' segment did
    # before it was classified.

    It 'scopes an aider write to the project without escalating' {
        $Event = New-FakeEvent -FullPath 'P:\Dropbox\Proj\.agent-state\aider\1788469785000.chat.md'
        $Scope = Get-EventScope -WatcherEvent $Event

        $Scope.Full | Should -BeFalse
        @($Scope.Agents).Count | Should -Be 0
        $Scope.ProjectRoot | Should -Be 'P:\Dropbox\Proj'
        Test-RelevantWatcherEvent -WatcherEvent $Event | Should -Be 'relevant'
        $Plan = Get-AgentSyncDispatchPlan -AgentScope $Scope.Agents -ProjectScope @($Scope.ProjectRoot) -DirtyFull $Scope.Full
        $Plan.RunFull | Should -BeFalse
        $Plan.Trigger | Should -Be 'debounce'
    }

    It 'still escalates a state folder it has never seen' {
        $Event = New-FakeEvent -FullPath 'P:\Dropbox\Proj\.agent-state\brand-new-agent\x.json'
        (Get-EventScope -WatcherEvent $Event).Full | Should -BeTrue
    }

    It 'includes project-local Aider history in the project manifest' {
        $Project = Join-Path $TestDrive 'manifest-project'
        $AiderRoot = Join-Path $Project '.agent-state\aider'
        New-Item -ItemType Directory -Path $AiderRoot -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $AiderRoot '1788474478154.chat.md') -Value '# aider chat'
        Set-Content -LiteralPath (Join-Path $AiderRoot '1788474478154.llm.md') -Value '# aider llm'
        $Script:AgentSyncVersion = 'test'

        Update-ProjectManifest -ProjectRoot $Project

        $Manifest = Get-Content -LiteralPath (Join-Path $Project '.agent-state\manifest.json') -Raw | ConvertFrom-Json
        $Manifest.agents.aider.files | Should -Be 2
        $Manifest.agents.aider.bytes | Should -BeGreaterThan 0
    }

    It 'reads model and provider metadata from the Aider chat header' {
        $Chat = Join-Path $TestDrive 'aider-model.chat.md'
        Set-Content -LiteralPath $Chat -Value @(
            '# aider chat started at 2026-09-04 00:28:00'
            '> Aider v0.86.2'
            '> Model: ollama_chat/qwen3-coder-next:q8_0 with whole edit format'
        )

        $Info = Get-StatusAiderModelInfo -ChatPath $Chat

        $Info.Model | Should -Be 'ollama_chat/qwen3-coder-next:q8_0'
        $Info.Provider | Should -Be 'ollama_chat'
    }

    It 'adds Aider as a first-class metric without a configured native adapter' {
        $Script:ProjectsBasePath = $TestDrive
        $Script:KnownProjectRoots = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $Script:LocalProjectRoots = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $Project = Join-Path $TestDrive 'status-project'
        $AiderRoot = Join-Path $Project '.agent-state\aider'
        New-Item -ItemType Directory -Path $AiderRoot -Force | Out-Null
        $ChatPath = Join-Path $AiderRoot '1788474478154.chat.md'
        Set-Content -LiteralPath $ChatPath -Value '> Model: ollama_chat/qwen3-coder-next:q8_0 with whole edit format'
        $Map = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)

        $Added = Add-StatusAgentFiles -ProjectMap $Map -Cwd $Project -StorageProjectRoot $Project -AgentName 'aider' -Files @((Get-Item $ChatPath)) -Machines @('TESTHOST') -SessionId '1788474478154' -ModelInfo (Get-StatusAiderModelInfo -ChatPath $ChatPath)

        $Added | Should -BeTrue
        $Map.Count | Should -Be 1
        $Row = @($Map.Values)[0]
        $Row.Aider.Files | Should -Be 1
        $Row.Aider.SessionIds.Contains('1788474478154') | Should -BeTrue
        $Row.Aider.Model | Should -Be 'ollama_chat/qwen3-coder-next:q8_0'
    }
}

Describe 'Aider report adapters' {

    It 'keeps Recovery and Intelligence scripts parseable with project-local Aider readers' {
        foreach ($Contract in @(
            @{ Path = (Join-Path $PSScriptRoot '..\Test-AgentSync-Recovery.ps1'); Function = 'Test-AiderState' }
            @{ Path = (Join-Path $PSScriptRoot '..\Build-AgentSync-Intelligence.ps1'); Function = 'Read-AiderGroup' }
        )) {
            $Tokens = $null
            $Errors = $null
            $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Contract.Path, [ref]$Tokens, [ref]$Errors)
            $Errors.Count | Should -Be 0
            @($Ast.FindAll({
                param($Node)
                $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq $Contract.Function
            }, $false)).Count | Should -Be 1
        }
    }
}

Describe 'Adapter file-pair deduplication' -Tag 'AdapterPairDedup' {
    BeforeAll {
        function New-AdapterPairFixture {
            param ([string]$Provider)
            $Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $Base = Join-Path $Root 'projects'
            $Project = Join-Path $Base 'Parent'
            $Native = Join-Path $Root 'native'
            [void][IO.Directory]::CreateDirectory($Project)
            [void][IO.Directory]::CreateDirectory($Native)
            $Script:ProjectsBasePath = $Base
            $Script:Config = [pscustomobject]@{
                maxRetryCount = 1; fileLockRetryDelayMs = 1
                safety = [pscustomobject]@{ protectAppendOnly = $true }
                projectResolution = [pscustomobject]@{ preferExistingAncestor = $false }
            }
            $Agent = [pscustomobject]@{
                name = $Provider; routingMode = $Provider; localPath = $Native
                targetSubDir = ".agent-state/$Provider/sessions"; fileFilters = @('*.jsonl')
            }
            [void](Register-AgentSyncProjectRoot -ProjectRoot $Project)
            [pscustomobject]@{ Root = $Root; Base = $Base; Project = $Project; Native = $Native; Agent = $Agent }
        }

        function New-AdapterPairSession {
            param ($Fixture, [string]$Id, [string]$Project, [string]$Location = 'both')
            if (-not $Project) { $Project = $Fixture.Project }
            [void][IO.Directory]::CreateDirectory($Project)
            [void](Register-AgentSyncProjectRoot -ProjectRoot $Project)
            # Deliberately share one Claude bucket across exact nested projects.
            $Relative = if ($Fixture.Agent.name -eq 'claude') { "mixed-bucket/$Id.jsonl" } else { "2026/10/$Id.jsonl" }
            $Local = Join-Path $Fixture.Native $Relative
            $Cloud = Join-Path (Join-Path $Project $Fixture.Agent.targetSubDir) $Relative
            $Text = (@{cwd=$Project; message='synthetic value A'} | ConvertTo-Json -Compress) + "`n"
            foreach ($Path in $(if ($Location -eq 'local') { @($Local) } elseif ($Location -eq 'cloud') { @($Cloud) } else { @($Local,$Cloud) })) {
                [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
                [IO.File]::WriteAllText($Path, $Text)
            }
            [pscustomobject]@{ Local=$Local; Cloud=$Cloud; Text=$Text }
        }

        function Invoke-AdapterPairFixture {
            param ($Fixture)
            if ($Fixture.Agent.name -eq 'claude') { Sync-Claude -Agent $Fixture.Agent }
            else { Sync-RoutedFiles -Agent $Fixture.Agent }
        }
    }

    BeforeEach {
        $PreviousConfig = $Script:Config
        $PreviousBase = $Script:ProjectsBasePath
        $PreviousMetadataLines = $Script:MetadataReadLines
        $Script:MetadataReadLines = 40
        $Script:KnownProjectRoots = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $Script:LocalProjectRoots = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $Script:ClaudeWorkspaceMapCache = @{}
        $Script:SessionCwdCache = @{}
        $Script:RestoreSkipLogged = @{}
        $Script:HeartbeatSeen = @{}
        $Script:SelfWrittenPaths = @{}
        $Script:CycleDeferredCopies = 0
        Reset-DiagStateForTest
        Reset-TouchedProjectsForTest
        $Script:TestLog.Clear()
        # Isolate only the external project index, not routing or copy guards.
        Mock Update-AgentSyncProjectIndex {}
        $script:PairTestHash = ${function:Get-FileHashSafe}
        Mock Get-FileHashSafe { & $script:PairTestHash @PesterBoundParameters }
    }

    AfterEach {
        $Script:Config = $PreviousConfig
        $Script:ProjectsBasePath = $PreviousBase
        $Script:MetadataReadLines = $PreviousMetadataLines
    }

    It '<Provider> hashes an unchanged pair only once per adapter pass' -TestCases @(@{Provider='claude'},@{Provider='codex'}) {
        param ($Provider)
        $Fixture = New-AdapterPairFixture $Provider
        $Pair = New-AdapterPairSession $Fixture 'unchanged'
        (Get-SessionCwd -Path $Pair.Local) | Should -Be $Fixture.Project
        (Get-ProjectRootFromCwd -Cwd $Fixture.Project) | Should -Be $Fixture.Project
        Invoke-AdapterPairFixture $Fixture
        Should -Invoke Get-FileHashSafe -Exactly 2
        [IO.File]::ReadAllText($Pair.Local) | Should -BeExactly $Pair.Text
        [IO.File]::ReadAllText($Pair.Cloud) | Should -BeExactly $Pair.Text
    }

    It '<Provider> still copies both local-only and cloud-only sessions' -TestCases @(@{Provider='claude'},@{Provider='codex'}) {
        param ($Provider)
        $Fixture = New-AdapterPairFixture $Provider
        $Local = New-AdapterPairSession $Fixture 'from-native' -Location local
        $Cloud = New-AdapterPairSession $Fixture 'from-project' -Location cloud
        Invoke-AdapterPairFixture $Fixture
        [IO.File]::ReadAllText($Local.Cloud) | Should -BeExactly $Local.Text
        [IO.File]::ReadAllText($Cloud.Local) | Should -BeExactly $Cloud.Text
        $Script:CycleErrorCount | Should -Be 0
    }

    It '<Provider> retains verified append copying in both directions' -TestCases @(@{Provider='claude'},@{Provider='codex'}) {
        param ($Provider)
        $Fixture = New-AdapterPairFixture $Provider
        $Local = New-AdapterPairSession $Fixture 'local-growth'
        $Cloud = New-AdapterPairSession $Fixture 'cloud-growth'
        $Extra = '{"message":"synthetic appended record"}' + "`n"
        [IO.File]::AppendAllText($Local.Local, $Extra)
        [IO.File]::AppendAllText($Cloud.Cloud, $Extra)
        (Get-Item -LiteralPath $Local.Local).LastWriteTimeUtc = [datetime]::UtcNow.AddSeconds(2)
        (Get-Item -LiteralPath $Cloud.Cloud).LastWriteTimeUtc = [datetime]::UtcNow.AddSeconds(2)
        Invoke-AdapterPairFixture $Fixture
        [IO.File]::ReadAllText($Local.Cloud) | Should -BeExactly ($Local.Text + $Extra)
        [IO.File]::ReadAllText($Cloud.Local) | Should -BeExactly ($Cloud.Text + $Extra)
        $Script:CycleErrorCount | Should -Be 0
    }

    It '<Provider> detects same-size same-time content changes on the next pass' -TestCases @(@{Provider='claude'},@{Provider='codex'}) {
        param ($Provider)
        $Fixture = New-AdapterPairFixture $Provider
        $Pair = New-AdapterPairSession $Fixture 'changed'
        Invoke-AdapterPairFixture $Fixture
        $Stamp = (Get-Item -LiteralPath $Pair.Local).LastWriteTimeUtc
        $Changed = $Pair.Text.Replace('value A', 'value B')
        [IO.File]::WriteAllText($Pair.Local, $Changed)
        (Get-Item -LiteralPath $Pair.Local).LastWriteTimeUtc = $Stamp
        Invoke-AdapterPairFixture $Fixture
        Should -Invoke Get-FileHashSafe -Exactly 4
        $Script:CycleContentConflicts | Should -Be 1
        [IO.File]::ReadAllText($Pair.Local) | Should -BeExactly $Changed
        [IO.File]::ReadAllText($Pair.Cloud) | Should -BeExactly $Pair.Text
    }

    It '<Provider> keeps parent and nested projects distinct' -TestCases @(@{Provider='claude'},@{Provider='codex'}) {
        param ($Provider)
        $Fixture = New-AdapterPairFixture $Provider
        $Parent = New-AdapterPairSession $Fixture 'parent' -Location local
        $Nested = New-AdapterPairSession $Fixture 'nested' -Project (Join-Path $Fixture.Project 'Child') -Location local
        Invoke-AdapterPairFixture $Fixture
        [IO.File]::ReadAllText($Parent.Cloud) | Should -BeExactly $Parent.Text
        [IO.File]::ReadAllText($Nested.Cloud) | Should -BeExactly $Nested.Text
        Test-Path -LiteralPath (Join-Path (Split-Path -Parent $Parent.Cloud) 'nested.jsonl') | Should -BeFalse
    }

    It '<Provider> does not restore an old parent fallback after creating the canonical nested copy' -TestCases @(@{Provider='claude'},@{Provider='codex'}) {
        param ($Provider)
        $Fixture = New-AdapterPairFixture $Provider
        $Nested = Join-Path $Fixture.Project 'Child'
        $Pair = New-AdapterPairSession $Fixture 'nested-fallback' -Project $Nested -Location local
        $Relative = Get-RelativeChildPath -BasePath $Fixture.Native -FullPath $Pair.Local
        $Fallback = Join-Path (Join-Path $Fixture.Project $Fixture.Agent.targetSubDir) $Relative
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Fallback))
        $FallbackText = $Pair.Text + '{"message":"old broad-project fallback"}' + "`n"
        [IO.File]::WriteAllText($Fallback, $FallbackText)
        (Get-Item -LiteralPath $Fallback).LastWriteTimeUtc = [datetime]::UtcNow.AddSeconds(3)
        Invoke-AdapterPairFixture $Fixture
        [IO.File]::ReadAllText($Pair.Cloud) | Should -BeExactly $Pair.Text
        [IO.File]::ReadAllText($Pair.Local) | Should -BeExactly $Pair.Text
        [IO.File]::ReadAllText($Fallback) | Should -BeExactly $FallbackText
    }

    It 'never recreates a Codex session which exists in the local archive' {
        $Fixture = New-AdapterPairFixture 'codex'
        $Pair = New-AdapterPairSession $Fixture 'archived' -Location cloud
        $Archive = Join-Path $Fixture.Root 'archive'
        [void][IO.Directory]::CreateDirectory($Archive)
        [IO.File]::WriteAllText((Join-Path $Archive 'archived.jsonl'), $Pair.Text)
        $Fixture.Agent | Add-Member -NotePropertyName skipRestoreIfPresentIn -NotePropertyValue @($Archive)
        Invoke-AdapterPairFixture $Fixture
        Test-Path -LiteralPath $Pair.Local | Should -BeFalse
        [IO.File]::ReadAllText($Pair.Cloud) | Should -BeExactly $Pair.Text
        ($Script:TestLog -join "`n") | Should -Match 'ARCHIVE_RESPECTED'
    }
}

Describe 'Sync-FilePair decision matrix' {

    BeforeEach {
        $Script:TestLog.Clear()
        Reset-TouchedProjectsForTest
        $Script:ProjRoot = Join-Path $TestDrive 'Project'
        $Script:LocalDir = Join-Path $TestDrive 'local'
        $Script:CloudDir = Join-Path $Script:ProjRoot '.agent-state\codex\sessions'
        New-Item -ItemType Directory -Path $Script:LocalDir, $Script:CloudDir -Force | Out-Null
    }

    It 'copies a local-only file to the project' {
        $L = Join-Path $Script:LocalDir 'a.jsonl'
        Set-Content -LiteralPath $L -Value '{"line":1}'
        $C = Join-Path $Script:CloudDir 'a.jsonl'

        Sync-FilePair -LocalPath $L -CloudPath $C -AgentName 'codex' -DisplayPath 'P\a.jsonl' -ProjectRoot $Script:ProjRoot

        Test-Path $C | Should -BeTrue
        (Get-TouchedProjectsForTest).ContainsKey($Script:ProjRoot) | Should -BeTrue
    }

    It 'copies Antigravity transcript fragments from <SourceLayout> as opaque bytes' -Tag 'HistoryContinuation' -TestCases @(
        @{ SourceLayout = 'native session path'; RelativeSource = 'brain\session-1\.system_generated\logs\chunks\transcript' }
        @{ SourceLayout = 'project copy path'; RelativeSource = 'brain\.system_generated\logs\chunks\transcript' }
    ) {
        param ($SourceLayout, $RelativeSource)
        $LocalChunkDir = Join-Path $Script:LocalDir $RelativeSource
        $CloudChunkDir = Join-Path $Script:ProjRoot '.agent-state\antigravity\ide\sessions\session-1\brain\.system_generated\logs\chunks\transcript'
        New-Item -ItemType Directory -Path $LocalChunkDir, $CloudChunkDir -Force | Out-Null
        $L = Join-Path $LocalChunkDir '00000000.jsonl'
        $C = Join-Path $CloudChunkDir '00000000.jsonl'
        $Bytes = [byte[]](0xB8, 0x72, 0x65, 0x63, 0x6F, 0x72, 0x64, 0x22, 0x7D, 0x0A, 0x7B, 0x22, 0x6E, 0x65, 0x78, 0x74, 0x22, 0x3A)
        [System.IO.File]::WriteAllBytes($L, $Bytes)

        Test-AntigravityJsonlChunkPath -Path $L | Should -BeTrue
        Test-AppendOnlyName -Path $L | Should -BeFalse
        Sync-FilePair -LocalPath $L -CloudPath $C -AgentName 'antigravity' -DisplayPath 'brain\chunks\transcript\00000000.jsonl' -ProjectRoot $Script:ProjRoot

        Test-Path -LiteralPath $C | Should -BeTrue
        (Get-FileHash -LiteralPath $C).Hash | Should -Be (Get-FileHash -LiteralPath $L).Hash
        ($Script:TestLog -join "`n") | Should -Not -Match 'JSONL_INCOMPLETE'
    }

    It 'keeps complete Antigravity transcripts under append-only protection' {
        $Complete = Join-Path $Script:LocalDir 'brain\.system_generated\logs\transcript.jsonl'
        New-Item -ItemType Directory -Path (Split-Path -Parent $Complete) -Force | Out-Null
        Set-Content -LiteralPath $Complete -Value '{"complete":true}'

        Test-AntigravityJsonlChunkPath -Path $Complete | Should -BeFalse
        Test-AppendOnlyName -Path $Complete | Should -BeTrue
    }

    It 'lets the newer, larger local file win' {
        $L = Join-Path $Script:LocalDir 'b.jsonl'
        $C = Join-Path $Script:CloudDir 'b.jsonl'
        Set-Content -LiteralPath $C -Value '{"line":1}'
        (Get-Item $C).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddMinutes(-10)
        Set-Content -LiteralPath $L -Value @('{"line":1}', '{"line":"newer content"}')

        Sync-FilePair -LocalPath $L -CloudPath $C -AgentName 'codex' -DisplayPath 'P\b.jsonl' -ProjectRoot $Script:ProjRoot

        (Get-Content $C -Raw) | Should -Match 'newer content'
    }

    It 'APPEND_GUARD blocks a newer but smaller jsonl from overwriting' {
        $L = Join-Path $Script:LocalDir 'c.jsonl'
        $C = Join-Path $Script:CloudDir 'c.jsonl'
        Set-Content -LiteralPath $C -Value 'a much longer historical content line'
        (Get-Item $C).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddMinutes(-10)
        Set-Content -LiteralPath $L -Value 'tiny'

        Sync-FilePair -LocalPath $L -CloudPath $C -AgentName 'codex' -DisplayPath 'P\c.jsonl' -ProjectRoot $Script:ProjRoot

        (Get-Content $C -Raw) | Should -Match 'historical'
        ($Script:TestLog -join "`n") | Should -Match 'APPEND_GUARD'
    }

    It 'equal-time tie: larger jsonl wins WITHOUT a backup of the stale prefix' {
        $L = Join-Path $Script:LocalDir 'd.jsonl'
        $C = Join-Path $Script:CloudDir 'd.jsonl'
        Set-Content -LiteralPath $C -Value '{"prefix":true}'
        Set-Content -LiteralPath $L -Value @('{"prefix":true}', '{"appended growth":true}')
        $T = (Get-Date).ToUniversalTime().AddMinutes(-5)
        (Get-Item $L).LastWriteTimeUtc = $T
        (Get-Item $C).LastWriteTimeUtc = $T

        Sync-FilePair -LocalPath $L -CloudPath $C -AgentName 'codex' -DisplayPath 'P\d.jsonl' -ProjectRoot $Script:ProjRoot

        (Get-Content $C -Raw) | Should -Match 'appended growth'
        $Overwritten = Join-Path $Script:ProjRoot '.agent-state\conflicts\overwritten'
        @(Get-ChildItem $Overwritten -Recurse -File -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It 'equal-time tie: a non-append format still gets a backup before overwrite' {
        $L = Join-Path $Script:LocalDir 'e.db'
        $C = Join-Path $Script:CloudDir 'e.db'
        Set-Content -LiteralPath $C -Value 'small divergent db'
        Set-Content -LiteralPath $L -Value 'a bigger divergent database payload'
        $T = (Get-Date).ToUniversalTime().AddMinutes(-5)
        (Get-Item $L).LastWriteTimeUtc = $T
        (Get-Item $C).LastWriteTimeUtc = $T

        Sync-FilePair -LocalPath $L -CloudPath $C -AgentName 'codex' -DisplayPath 'P\e.db' -ProjectRoot $Script:ProjRoot

        $Overwritten = Join-Path $Script:ProjRoot '.agent-state\conflicts\overwritten'
        @(Get-ChildItem $Overwritten -Recurse -File -ErrorAction SilentlyContinue).Count | Should -Be 1
    }

    It 'skips identical files even when timestamps differ by more than the tolerance' {
        $L = Join-Path $Script:LocalDir 'f.jsonl'
        $C = Join-Path $Script:CloudDir 'f.jsonl'
        Set-Content -LiteralPath $L -Value 'same content'
        Set-Content -LiteralPath $C -Value 'same content'
        (Get-Item $L).LastWriteTimeUtc = (Get-Date).ToUniversalTime()
        (Get-Item $C).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddMinutes(-30)
        $Before = (Get-Item $C).LastWriteTimeUtc

        Sync-FilePair -LocalPath $L -CloudPath $C -AgentName 'codex' -DisplayPath 'P\f.jsonl' -ProjectRoot $Script:ProjRoot

        (Get-Item $C).LastWriteTimeUtc | Should -Be $Before
        ($Script:TestLog -join "`n") | Should -Not -Match 'SYNC agent'
    }

    It 'preserves divergent JSONL branches with equal timestamps' {
        $L = Join-Path $Script:LocalDir 'fork.jsonl'
        $C = Join-Path $Script:CloudDir 'fork.jsonl'
        Set-Content $L '{"branch":"longer local branch"}'
        Set-Content $C '{"branch":"remote"}'
        $T = [datetime]::UtcNow.AddMinutes(-5)
        (Get-Item $L).LastWriteTimeUtc = $T
        (Get-Item $C).LastWriteTimeUtc = $T
        $Before = Get-Content $C -Raw
        Sync-FilePair $L $C codex fixture $Script:ProjRoot
        (Get-Content $C -Raw) | Should -BeExactly $Before
        ($Script:TestLog -join "`n") | Should -Match 'CONTENT_CONFLICT'
        $Script:CycleErrorCount | Should -Be 0
        $Script:CycleNewContentConflicts | Should -Be 1
        @(Get-ChildItem (Join-Path $Script:ProjRoot '.agent-state\conflicts\content') -File).Count | Should -Be 1

        $Script:TestLog.Clear()
        Sync-FilePair $L $C codex fixture $Script:ProjRoot
        $Script:CycleNewContentConflicts | Should -Be 1
        @(Get-ChildItem (Join-Path $Script:ProjRoot '.agent-state\conflicts\content') -File).Count | Should -Be 1
        ($Script:TestLog -join "`n") | Should -Not -Match 'WARN CONTENT_CONFLICT'
    }

    It 'detects equal-length equal-time divergent JSONL instead of treating it as equal' {
        $L = Join-Path $Script:LocalDir 'same.jsonl'
        $C = Join-Path $Script:CloudDir 'same.jsonl'
        Set-Content $L '{"branch":"A"}'
        Set-Content $C '{"branch":"B"}'
        $T = [datetime]::UtcNow.AddMinutes(-5)
        (Get-Item $L).LastWriteTimeUtc = $T
        (Get-Item $C).LastWriteTimeUtc = $T
        Sync-FilePair $L $C codex fixture $Script:ProjRoot
        (Get-Content $C -Raw) | Should -Match '"B"'
        ($Script:TestLog -join "`n") | Should -Match 'CONTENT_CONFLICT'
    }

    It 'never overwrites a nonappend conflict when its backup fails' {
        $L = Join-Path $Script:LocalDir 'backup.db'
        $C = Join-Path $Script:CloudDir 'backup.db'
        Set-Content $L 'new larger local database'
        Set-Content $C 'old database'
        (Get-Item $L).LastWriteTimeUtc = (Get-Item $C).LastWriteTimeUtc
        Mock Save-OverwrittenCopy { throw 'fixture backup denied' }
        Sync-FilePair $L $C codex fixture $Script:ProjRoot
        (Get-Content $C -Raw).Trim() | Should -BeExactly 'old database'
    }

    It 'does not publish an incomplete last JSONL record' {
        $L = Join-Path $Script:LocalDir 'partial.jsonl'
        $C = Join-Path $Script:CloudDir 'partial.jsonl'
        Set-Content $C '{"line":1}'
        [IO.File]::WriteAllText($L, "{`"line`":1}`r`n{`"line`":")
        (Get-Item $L).LastWriteTimeUtc = (Get-Item $C).LastWriteTimeUtc
        Sync-FilePair $L $C codex fixture $Script:ProjRoot
        (Get-Content $C -Raw).Trim() | Should -BeExactly '{"line":1}'
    }

    It 'counts exhausted copy failures in the health diagnostics' {
        Reset-DiagStateForTest
        Mock Write-AgentSyncError { $Script:CycleErrorCount++; $Script:TotalErrorsSinceStart++ }
        $L = Join-Path $Script:LocalDir 'missing.jsonl'
        $C = Join-Path $Script:CloudDir 'missing.jsonl'
        Copy-FileSafe $L $C | Should -BeFalse
        (Get-DiagStateForTest).Errors | Should -Be 1
    }

    It 'refuses a destination that changed after the sync decision' {
        $L = Join-Path $Script:LocalDir 'race.jsonl'
        $C = Join-Path $Script:CloudDir 'race.jsonl'
        Set-Content $L @('{"line":1}', '{"line":2}')
        Set-Content $C '{"line":1}'
        $Expected = (Get-FileHash $C).Hash
        Set-Content $C '{"different":"writer work"}'
        Copy-FileSafe $L $C -ExpectedDestinationHash $Expected -ProjectRoot $Script:ProjRoot -AgentName codex | Should -BeFalse
        (Get-Content $C -Raw) | Should -Match 'writer work'
    }

    It 'refuses a source that changed after the sync decision' {
        $Script:CycleDeferredCopies = 0
        Reset-DiagStateForTest
        $L = Join-Path $Script:LocalDir 'source-race.jsonl'
        $C = Join-Path $Script:CloudDir 'source-race.jsonl'
        Set-Content $L @('{"line":1}', '{"line":2}')
        Set-Content $C '{"line":1}'
        $ExpectedSource = (Get-FileHash $L).Hash
        $ExpectedTarget = (Get-FileHash $C).Hash
        Set-Content $L '{"rewritten":true}'
        Copy-FileSafe $L $C -ExpectedSourceHash $ExpectedSource -ExpectedDestinationHash $ExpectedTarget -ProjectRoot $Script:ProjRoot -AgentName codex | Should -BeFalse
        (Get-Content $C -Raw).Trim() | Should -BeExactly '{"line":1}'
        $Script:CycleErrorCount | Should -Be 0
        $Script:CycleDeferredCopies | Should -Be 1
        ($Script:TestLog -join "`n") | Should -Match 'COPY_DEFERRED.*SOURCE_CHANGED'
    }

    It 'does not overwrite an open destination writer' {
        $L = Join-Path $Script:LocalDir 'leased.jsonl'
        $C = Join-Path $Script:CloudDir 'leased.jsonl'
        Set-Content $L @('{"line":1}', '{"line":2}')
        Set-Content $C '{"line":1}'
        $Expected = (Get-FileHash $C).Hash
        $Writer = [IO.FileStream]::new($C, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
        $OriginalLength = $Writer.Length
        try {
            Copy-FileSafe $L $C -ExpectedDestinationHash $Expected -ProjectRoot $Script:ProjRoot -AgentName codex | Should -BeFalse
            $Writer.Length | Should -Be $OriginalLength
        }
        finally { $Writer.Dispose() }
    }

    It 'can capture a stable source while its native writer handle remains open' {
        $L = Join-Path $Script:LocalDir 'open-source.jsonl'
        $C = Join-Path $Script:CloudDir 'open-source.jsonl'
        Set-Content $L @('{"line":1}', '{"line":2}')
        Set-Content $C '{"line":1}'
        (Get-Item $L).LastWriteTimeUtc = (Get-Item $C).LastWriteTimeUtc
        $Writer = [IO.FileStream]::new($L, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
        try {
            Sync-FilePair $L $C codex fixture $Script:ProjRoot
            (Get-Content $C -Raw) | Should -Match '"line":2'
        }
        finally { $Writer.Dispose() }
    }

    It 'discards a staged snapshot if the source changes during capture verification' {
        $L = Join-Path $Script:LocalDir 'mid-read.jsonl'
        $C = Join-Path $Script:CloudDir 'mid-read.jsonl'
        Set-Content $L @('{"line":1}', '{"line":2}')
        Set-Content $C '{"line":1}'
        $ExpectedTarget = (Get-FileHash $C).Hash
        $Script:UnmockedStreamHash = (Get-Command Get-AgentSyncStreamHash -CommandType Function).ScriptBlock
        Mock Get-AgentSyncStreamHash { & $Script:UnmockedStreamHash -Stream $Stream }
        Mock Get-AgentSyncStreamHash {
            [IO.File]::WriteAllText($Stream.Name, '{"writer":"changed while reading"}')
            & $Script:UnmockedStreamHash -Stream $Stream
        } -ParameterFilter { $Stream.Name -match '[\\/]local[\\/]mid-read\.jsonl$' }
        Copy-FileSafe $L $C -ExpectedDestinationHash $ExpectedTarget -ProjectRoot $Script:ProjRoot -AgentName codex | Should -BeFalse
        (Get-Content $C -Raw).Trim() | Should -BeExactly '{"line":1}'
        ($Script:TestLog -join "`n") | Should -Match 'SOURCE_CHANGED'
    }

    It 'verifies a backup even for ordinary newer binary content' {
        $L = Join-Path $Script:LocalDir 'newer.db'
        $C = Join-Path $Script:CloudDir 'newer.db'
        Set-Content $L 'newer database'
        Set-Content $C 'older database'
        (Get-Item $C).LastWriteTimeUtc = [datetime]::UtcNow.AddHours(-1)
        $BeforeHash = (Get-FileHash $C).Hash
        Sync-FilePair $L $C codex fixture $Script:ProjRoot
        $Backups = @(Get-ChildItem (Join-Path $Script:ProjRoot '.agent-state/conflicts/overwritten') -Recurse -File -Filter 'newer.db')
        $Backups.Count | Should -Be 1
        (Get-FileHash $Backups[0].FullName).Hash | Should -Be $BeforeHash
        (Get-Content $C -Raw).Trim() | Should -BeExactly 'newer database'
    }

    It 'does not replace content when backup hash verification fails' {
        $L = Join-Path $Script:LocalDir 'bad-backup.db'
        $C = Join-Path $Script:CloudDir 'bad-backup.db'
        Set-Content $L 'larger newer database'
        Set-Content $C 'older database'
        (Get-Item $C).LastWriteTimeUtc = [datetime]::UtcNow.AddHours(-1)
        $Script:UnmockedStreamHash = (Get-Command Get-AgentSyncStreamHash -CommandType Function).ScriptBlock
        Mock Get-AgentSyncStreamHash { & $Script:UnmockedStreamHash -Stream $Stream }
        Mock Get-AgentSyncStreamHash { 'NOT_THE_SOURCE_HASH' } -ParameterFilter { $Stream.Name -match '[\\/]conflicts[\\/]overwritten[\\/]' }
        Sync-FilePair $L $C codex fixture $Script:ProjRoot
        (Get-Content $C -Raw).Trim() | Should -BeExactly 'older database'
        Should -Invoke Get-AgentSyncStreamHash -Times 1 -ParameterFilter { $Stream.Name -match '[\\/]conflicts[\\/]overwritten[\\/]' }
    }
}

Describe 'Error observability' {

    BeforeEach {
        $Script:TestLog.Clear()
        Reset-DiagStateForTest
        $Script:LogDirectory = Join-Path $TestDrive 'logs'
        New-Item -ItemType Directory -Path $Script:LogDirectory -Force | Out-Null
    }

    It 'Write-AgentSyncError logs type, context and stack, and journals the error' {
        try { throw [System.InvalidOperationException]::new('boom') } catch { $Captured = $_ }

        Write-AgentSyncError -Context 'Unit test' -ErrorRecord $Captured

        $Joined = $Script:TestLog -join "`n"
        $Joined | Should -Match 'Unit test'
        $Joined | Should -Match 'InvalidOperationException'
        $Joined | Should -Match 'boom'
        (Get-DiagStateForTest).Errors | Should -Be 1

        $Journal = Join-Path $Script:LogDirectory "errors-$Script:MachineId.log"
        Test-Path $Journal | Should -BeTrue
        (Get-Content $Journal -Raw) | Should -Match 'InvalidOperationException'
    }

    It 'Add-AgentSyncSilentFailure aggregates per category' {
        Add-AgentSyncSilentFailure -Category 'x-parse'
        Add-AgentSyncSilentFailure -Category 'x-parse'
        Add-AgentSyncSilentFailure -Category 'y-parse'

        $Silent = (Get-DiagStateForTest).Silent
        $Silent['x-parse'] | Should -Be 2
        $Silent['y-parse'] | Should -Be 1
    }

    It 'Get-EventScope warns once (throttled) about unknown state segments' {
        $Ev = New-FakeEvent 'P:\D\P1\.agent-state\brand-new-agent\f.jsonl'
        $null = Get-EventScope -WatcherEvent $Ev
        $null = Get-EventScope -WatcherEvent $Ev

        @($Script:TestLog | Where-Object { $_ -match 'EVENT_SCOPE_FULL' }).Count | Should -Be 1
    }
}

Describe 'Project root resolution' {

    BeforeEach {
        $Script:ProjectsBasePath = $TestDrive
        $Script:KnownProjectRoots = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $Script:LocalProjectRoots = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $Script:ProjectIndexDirty = $false
    }

    It 'clips .agent-state segments from a session cwd' {
        Remove-AgentInternalWorkspaceSuffix -Path 'P:\D\Proj\.agent-state' | Should -Be 'P:\D\Proj'
        Remove-AgentInternalWorkspaceSuffix -Path 'P:\D\Proj\.agent-state\codex\sessions\x' | Should -Be 'P:\D\Proj'
        Remove-AgentInternalWorkspaceSuffix -Path 'P:\D\Proj\src\app' | Should -Be 'P:\D\Proj\src\app'
    }

    It 'still clips Claude worktrees' {
        Remove-AgentInternalWorkspaceSuffix -Path 'P:\D\Proj\.claude\worktrees\jolly-raman\sub' | Should -Be 'P:\D\Proj'
    }

    It 'a cwd inside .agent-state resolves to the owning project' {
        $Proj = Join-Path $TestDrive 'Alpha'
        New-Item -ItemType Directory -Path (Join-Path $Proj '.agent-state\codex') -Force | Out-Null

        $Root = Get-ProjectRootFromCwd -Cwd (Join-Path $Proj '.agent-state\codex')

        $Root | Should -Be $Proj
        $Script:KnownProjectRoots.Contains($Proj) | Should -BeTrue
    }

    It 'a new cwd below a known project is attributed to the deepest known ancestor' {
        $Parent = Join-Path $TestDrive 'Beta\code'
        $Deep = Join-Path $Parent 'php\blocks'
        New-Item -ItemType Directory -Path $Deep -Force | Out-Null
        [void]$Script:KnownProjectRoots.Add($Parent)

        (Get-ProjectRootFromCwd -Cwd $Deep) | Should -Be $Parent
    }

    It 'an already-known deep root keeps its own identity' {
        $Parent = Join-Path $TestDrive 'Gamma'
        $Deep = Join-Path $Parent 'sub'
        New-Item -ItemType Directory -Path $Deep -Force | Out-Null
        [void]$Script:KnownProjectRoots.Add($Parent)
        [void]$Script:KnownProjectRoots.Add($Deep)

        (Get-ProjectRootFromCwd -Cwd $Deep) | Should -Be $Deep
    }

    It 'ancestor preference can be disabled via config' {
        $Parent = Join-Path $TestDrive 'Delta'
        $Deep = Join-Path $Parent 'sub'
        New-Item -ItemType Directory -Path $Deep -Force | Out-Null
        [void]$Script:KnownProjectRoots.Add($Parent)

        $Script:Config = $Script:Config | Select-Object *
        $Script:Config | Add-Member -NotePropertyName projectResolution -NotePropertyValue ([PSCustomObject]@{ preferExistingAncestor = $false }) -Force

        (Get-ProjectRootFromCwd -Cwd $Deep) | Should -Be $Deep

        $Script:Config.projectResolution = $null
    }
}

Describe 'Supporting validators' {

    It 'Test-RelativePathMatchesFilter matches name filters at any depth' {
        Test-RelativePathMatchesFilter -RelativePath 'sub\deep\x.jsonl' -Filters @('*.jsonl') | Should -BeTrue
        Test-RelativePathMatchesFilter -RelativePath 'memory\note.md' -Filters @('*.jsonl', 'memory/*.md') | Should -BeTrue
        Test-RelativePathMatchesFilter -RelativePath 'code\app.js' -Filters @('*.jsonl') | Should -BeFalse
    }

    It 'Test-SafeSessionId rejects traversal and accepts normal ids' {
        Test-SafeSessionId -Id '01a034d2-641f-7fe2-8508' | Should -BeTrue
        Test-SafeSessionId -Id '..\..\evil' | Should -BeFalse
        Test-SafeSessionId -Id '' | Should -BeFalse
    }

    It 'Test-AppendOnlyName treats jsonl as append-only and db as not' {
        Test-AppendOnlyName -Path 'x\y\file.JSONL' | Should -BeTrue
        Test-AppendOnlyName -Path 'x\y\file.db' | Should -BeFalse
    }
}


Describe 'Housekeeping reach' {

    # Retention, activity pruning and archiving used to walk the project index
    # only. A folder that holds .agent-state but has dropped out of the index
    # was then never swept again, so its backups grew without limit.

    BeforeAll {
        $Script:HousekeepingRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("agentsync-sweep-" + [guid]::NewGuid().ToString('N'))

        $Indexed = Join-Path $Script:HousekeepingRoot 'group\indexed-project'
        $Orphan = Join-Path $Script:HousekeepingRoot 'group'
        $Plain = Join-Path $Script:HousekeepingRoot 'group\no-state-here'
        $Hidden = Join-Path $Script:HousekeepingRoot 'group\node_modules\pkg'

        foreach ($Path in @($Indexed, $Orphan, $Plain, $Hidden)) {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
        }
        foreach ($Path in @($Indexed, $Orphan, $Hidden)) {
            New-Item -ItemType Directory -Path (Join-Path $Path '.agent-state') -Force | Out-Null
        }

        $Script:HousekeepingIndexed = $Indexed
        $Script:HousekeepingOrphan = $Orphan
        $Script:HousekeepingPlain = $Plain
        $Script:HousekeepingHidden = $Hidden

        # Only the nested folder is a known project; the group above it is not.
        function Get-AgentSyncProjects { @(Get-Item -LiteralPath $Script:HousekeepingIndexed) }
        $Script:ProjectsBasePath = $Script:HousekeepingRoot
        $ProjectsBasePath = $Script:HousekeepingRoot
    }

    AfterAll {
        if ($Script:HousekeepingRoot -and (Test-Path -LiteralPath $Script:HousekeepingRoot)) {
            Remove-Item -LiteralPath $Script:HousekeepingRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'sweeps a state folder that is not in the project index' {
        $Swept = @(Get-AgentSyncStateFolders | ForEach-Object { $_.FullName })

        $Swept | Should -Contain $Script:HousekeepingIndexed
        $Swept | Should -Contain $Script:HousekeepingOrphan
    }

    It 'leaves alone folders without state, and never descends into node_modules' {
        $Swept = @(Get-AgentSyncStateFolders | ForEach-Object { $_.FullName })

        $Swept | Should -Not -Contain $Script:HousekeepingPlain
        $Swept | Should -Not -Contain $Script:HousekeepingHidden
    }

    It 'lists every folder once even when the index already names it' {
        $Swept = @(Get-AgentSyncStateFolders | ForEach-Object { $_.FullName })

        ($Swept | Where-Object { $_ -eq $Script:HousekeepingIndexed }).Count | Should -Be 1
    }
}


Describe 'Project guidance updates' {

    # Guidance files used to be written once and never refreshed, so every
    # project stayed on the template it was created with. They now carry a
    # version marker, and pre-marker AgentSync text is recognised by content
    # hash - but a file the project has made its own is never overwritten.

    BeforeAll {
        $Script:GuidanceTemplate = @'
# Multi-agent continuity

Instructions the agents read.

<!-- agentsync-guidance: v4.0.4 | managed -->
'@
        $Script:GuidanceOlder = $Script:GuidanceTemplate -replace 'v4\.0\.4', 'v4.0.1'
        $Script:GuidanceLegacyText = "# Multi-agent continuity`n`nAn old template with no marker at all.`n"
        $Script:GuidanceLegacyHashes = @{
            'AGENTS.md' = @((Get-GuidanceContentHash -Text $Script:GuidanceLegacyText))
        }
    }

    It 'leaves a file that already matches the template' {
        Get-GuidanceAction -FileName 'AGENTS.md' -Existing $Script:GuidanceTemplate -Template $Script:GuidanceTemplate |
            Should -Be 'current'
    }

    It 'ignores line endings and trailing whitespace when comparing' {
        $Noisy = ($Script:GuidanceTemplate -replace "`n", "`r`n") + "`r`n`r`n"
        Get-GuidanceAction -FileName 'AGENTS.md' -Existing $Noisy -Template $Script:GuidanceTemplate |
            Should -Be 'current'
    }

    It 'updates a file whose marker is older than the template' {
        Get-GuidanceAction -FileName 'AGENTS.md' -Existing $Script:GuidanceOlder -Template $Script:GuidanceTemplate |
            Should -Be 'update'
    }

    It 'updates pre-marker AgentSync text that matches a known hash' {
        Get-GuidanceAction -FileName 'AGENTS.md' -Existing $Script:GuidanceLegacyText -Template $Script:GuidanceTemplate |
            Should -Be 'update'
    }

    It 'never overwrites text the project wrote itself' {
        $Own = "# Arbeidsavtale for Codex`n`nDenne filen er min egen.`n"
        Get-GuidanceAction -FileName 'AGENTS.md' -Existing $Own -Template $Script:GuidanceTemplate |
            Should -Be 'keep'
    }

    It 'never overwrites an edit made after AgentSync wrote the file' {
        $Edited = $Script:GuidanceTemplate -replace 'Instructions the agents read.', 'My own rule.'
        Get-GuidanceAction -FileName 'AGENTS.md' -Existing $Edited -Template $Script:GuidanceTemplate |
            Should -Be 'keep'
    }

    It 'stops updating once the project deletes the marker line' {
        $Frozen = $Script:GuidanceOlder -replace '<!-- agentsync-guidance:[^>]*-->', ''
        Get-GuidanceAction -FileName 'AGENTS.md' -Existing $Frozen -Template $Script:GuidanceTemplate |
            Should -Be 'keep'
    }
}


Describe 'Out-of-process Intelligence builder' {

    It 'resolves an explicit PowerShell executable candidate safely' {
        $FakePowerShell = Join-Path $TestDrive 'runtime with spaces\pwsh.exe'
        New-Item -ItemType Directory -Path (Split-Path $FakePowerShell -Parent) -Force | Out-Null
        Set-Content -LiteralPath $FakePowerShell -Value 'test executable placeholder'

        $Resolved = Resolve-AgentSyncPowerShellExecutable -Candidates @(
            (Join-Path $TestDrive 'missing\pwsh.exe')
            $FakePowerShell
            'not-reached'
        )

        $Resolved | Should -Be ([System.IO.Path]::GetFullPath($FakePowerShell))
    }

    It 'constructs a hidden shell-free process with separate arguments' {
        $PowerShellPath = Resolve-AgentSyncPowerShellExecutable
        $ChildScript = Join-Path $TestDrive 'builder with spaces.ps1'
        Set-Content -LiteralPath $ChildScript -Value 'exit 0'
        $ConfigValue = 'P:\A folder\config "live" & safe.json'
        $MarkerValue = 'alpha; beta | gamma'

        $StartInfo = New-AgentSyncPowerShellStartInfo `
            -PowerShellPath $PowerShellPath `
            -ScriptPath $ChildScript `
            -ScriptArguments @('-ConfigFile', $ConfigValue, '-Marker', $MarkerValue) `
            -WorkingDirectory $TestDrive

        $StartInfo.UseShellExecute | Should -BeFalse
        $StartInfo.CreateNoWindow | Should -BeTrue
        $StartInfo.WindowStyle | Should -Be ([System.Diagnostics.ProcessWindowStyle]::Hidden)
        $StartInfo.RedirectStandardOutput | Should -BeTrue
        $StartInfo.RedirectStandardError | Should -BeTrue
        $StartInfo.Arguments | Should -BeNullOrEmpty
        $Expected = @(
            '-NoLogo'
            '-NoProfile'
            '-NonInteractive'
            '-File'
            [System.IO.Path]::GetFullPath($ChildScript)
            '-ConfigFile'
            $ConfigValue
            '-Marker'
            $MarkerValue
        )
        (@($StartInfo.ArgumentList) -join "`n") | Should -Be ($Expected -join "`n")
    }

    It 'preserves spaces quotes and shell metacharacters in child arguments' {
        $PowerShellPath = Resolve-AgentSyncPowerShellExecutable
        $ChildScript = Join-Path $TestDrive 'echo builder arguments.ps1'
        Set-Content -LiteralPath $ChildScript -Encoding utf8 -Value @'
param ([string]$ConfigFile, [string]$Marker)
[Console]::Out.Write((@{ ConfigFile = $ConfigFile; Marker = $Marker } | ConvertTo-Json -Compress))
'@
        $ConfigValue = 'P:\Dropbox\A folder\config "live" & safe.json'
        $MarkerValue = 'alpha; beta | gamma > delta'

        $Result = Invoke-AgentSyncPowerShellScript `
            -PowerShellPath $PowerShellPath `
            -ScriptPath $ChildScript `
            -ScriptArguments @('-ConfigFile', $ConfigValue, '-Marker', $MarkerValue) `
            -WorkingDirectory $TestDrive

        $Result.ExitCode | Should -Be 0
        $Result.StdErr | Should -BeNullOrEmpty
        $Decoded = $Result.StdOut | ConvertFrom-Json
        $Decoded.ConfigFile | Should -BeExactly $ConfigValue
        $Decoded.Marker | Should -BeExactly $MarkerValue
        $Result.DurationMs | Should -BeGreaterOrEqual 0
    }

    It 'returns a nonzero child exit code and stderr to the caller' {
        $PowerShellPath = Resolve-AgentSyncPowerShellExecutable
        $ChildScript = Join-Path $TestDrive 'failing builder.ps1'
        Set-Content -LiteralPath $ChildScript -Encoding utf8 -Value @'
[Console]::Error.Write('synthetic builder failure')
exit 23
'@

        $Result = Invoke-AgentSyncPowerShellScript `
            -PowerShellPath $PowerShellPath `
            -ScriptPath $ChildScript `
            -WorkingDirectory $TestDrive

        $Result.ExitCode | Should -Be 23
        $Result.StdErr | Should -Match 'synthetic builder failure'
    }

    It 'routes the Intelligence refresh through the child-process helper' {
        $Definition = (Get-Command Update-AgentSyncIntelligenceReport -CommandType Function).Definition

        $Definition | Should -Match 'Invoke-AgentSyncPowerShellScript'
        $Definition | Should -Not -Match '&\s*\$BuilderPath'
    }

    It 'times out a hanging builder and returns within a bounded deadline' {
        $ChildScript = Join-Path $TestDrive 'hanging-builder.ps1'
        Set-Content $ChildScript '[Console]::Out.Write("started"); Start-Sleep -Seconds 30'
        $Watch = [Diagnostics.Stopwatch]::StartNew()
        $Result = Invoke-AgentSyncPowerShellScript -ScriptPath $ChildScript -WorkingDirectory $TestDrive -TimeoutSeconds 1
        $Watch.Stop()
        $Result.ExitCode | Should -Not -Be 0
        $Result.TimedOut | Should -BeTrue
        $Watch.Elapsed.TotalSeconds | Should -BeLessThan 8
    }

    It 'drains noisy stdout and stderr while retaining only bounded text' {
        $ChildScript = Join-Path $TestDrive 'noisy-builder.ps1'
        Set-Content $ChildScript '[Console]::Out.Write("o" * 200000); [Console]::Error.Write("e" * 200000)'
        $Info = New-AgentSyncPowerShellStartInfo -PowerShellPath (Resolve-AgentSyncPowerShellExecutable) -ScriptPath $ChildScript -WorkingDirectory $TestDrive
        $Result = Invoke-AgentSyncBoundedProcess -StartInfo $Info -TimeoutSeconds 5 -MaxOutputCharacters 128
        $Result.ExitCode | Should -Be 0
        $Result.StdOut.Length | Should -Be 128
        $Result.StdErr.Length | Should -Be 128
        $Result.OutputTruncated | Should -BeTrue
    }

    It 'ends a Windows child job when the wrapper exits before its descendant' -Skip:(-not $IsWindows) {
        $Grandchild = Join-Path $TestDrive 'grandchild.ps1'
        $ChildScript = Join-Path $TestDrive 'short-lived-wrapper.ps1'
        $ChildIdFile = Join-Path $TestDrive 'grandchild.pid'
        Set-Content $Grandchild 'Start-Sleep -Seconds 30'
        Set-Content $ChildScript @'
param([string]$Grandchild, [string]$ChildIdFile)
$Info=[Diagnostics.ProcessStartInfo]::new()
$Info.FileName=Join-Path $PSHOME 'pwsh.exe'
$Info.UseShellExecute=$false
$Info.CreateNoWindow=$true
foreach($Arg in @('-NoProfile','-File',$Grandchild)){[void]$Info.ArgumentList.Add($Arg)}
$Child=[Diagnostics.Process]::Start($Info)
if ($Child.HasExited) { throw 'Grandchild exited before the wrapper could record it.' }
[IO.File]::WriteAllText($ChildIdFile, [string]$Child.Id)
$Child.Dispose()
'@
        $ChildId = $null
        try {
            $Result = Invoke-AgentSyncPowerShellScript -ScriptPath $ChildScript -ScriptArguments @('-Grandchild', $Grandchild, '-ChildIdFile', $ChildIdFile) -WorkingDirectory $TestDrive -TimeoutSeconds 8
            Test-Path -LiteralPath $ChildIdFile -PathType Leaf | Should -BeTrue -Because "the wrapper must record its descendant PID before exit; stderr: $($Result.StdErr)"
            $ChildId = [int](Get-Content -LiteralPath $ChildIdFile -Raw).Trim()
            $ChildId | Should -BeGreaterThan 0
            $Result.TimedOut | Should -BeTrue -Because 'the descendant deliberately keeps the redirected streams open past the wrapper exit'
            @(Get-Process -Id $ChildId -ErrorAction SilentlyContinue).Count | Should -Be 0
        }
        finally {
            if ($ChildId) {
                Stop-Process -Id $ChildId -Force -ErrorAction SilentlyContinue
            }
        }
    }
}


Describe 'Bounded Antigravity database workspace scan' {

    It 'finds a framed workspace URI split across read-buffer boundaries' {
        $UriText = 'file:///P:/Dropbox/Projects/Boundary-Test'
        $UriBytes = [System.Text.Encoding]::UTF8.GetBytes($UriText)
        $Bytes = [System.Collections.Generic.List[byte]]::new()
        1..13 | ForEach-Object { $Bytes.Add(0x55) }
        $Bytes.Add(0x0A)
        $Bytes.Add([byte]$UriBytes.Length)
        $Bytes.AddRange($UriBytes)
        $Bytes.Add(0x1A)
        $Bytes.Add(0x00)

        $Stream = [System.IO.MemoryStream]::new($Bytes.ToArray(), $false)
        try {
            $Result = Find-AntigravityWorkspaceInStream `
                -Stream $Stream `
                -BufferSize 16 `
                -WorkspacePredicate { param($Workspace) $true }
        }
        finally {
            $Stream.Dispose()
        }

        $Result | Should -Be 'P:\Dropbox\Projects\Boundary-Test'
    }

    It 'ignores an invalid first frame and continues to a later accepted workspace' {
        $RejectedUri = [System.Text.Encoding]::UTF8.GetBytes('file:///P:/Dropbox/Projects/Rejected')
        $AcceptedUri = [System.Text.Encoding]::UTF8.GetBytes('file:///P:/Dropbox/Projects/Accepted')
        $Bytes = [System.Collections.Generic.List[byte]]::new()
        foreach ($UriBytes in @($RejectedUri, $AcceptedUri)) {
            $Bytes.Add(0x0A)
            $Bytes.Add([byte]$UriBytes.Length)
            $Bytes.AddRange($UriBytes)
            $Bytes.Add(0x1A)
            $Bytes.Add(0x00)
        }

        $Stream = [System.IO.MemoryStream]::new($Bytes.ToArray(), $false)
        try {
            $Result = Find-AntigravityWorkspaceInStream `
                -Stream $Stream `
                -BufferSize 17 `
                -WorkspacePredicate { param($Workspace) $Workspace.EndsWith('Accepted') }
        }
        finally {
            $Stream.Dispose()
        }

        $Result | Should -Be 'P:\Dropbox\Projects\Accepted'
    }

    It 'routes database and WAL reads through the bounded scanner' {
        $Definition = (Get-Command Get-AntigravityDatabaseWorkspace -CommandType Function).Definition

        $Definition | Should -Match 'Find-AntigravityWorkspaceInStream'
        $Definition | Should -Not -Match 'MemoryStream|CopyTo\(|ToArray\(|ReadAllBytes|ReadAllText'
    }
}

Describe 'Daemon memory maintenance' {

    It 'trims a Windows full cycle through the injectable native boundary' {
        $Calls = [System.Collections.Generic.List[System.IntPtr]]::new()
        $Result = Invoke-AgentSyncMemoryMaintenance `
            -FullCycle $true `
            -WorkingSetThresholdBytes ([long]::MaxValue) `
            -CurrentPlatform 'windows' `
            -WorkingSetTrimAction {
                param ([System.IntPtr]$Handle)
                $Calls.Add($Handle)
                return $true
            }

        $Calls.Count | Should -Be 1
        $Calls[0] | Should -Not -Be ([System.IntPtr]::Zero)
        $Result.TrimAttempted | Should -BeTrue
        $Result.TrimSucceeded | Should -BeTrue
        $Result.TrimState | Should -Be 'succeeded'
        $Result.WorkingSetMB | Should -BeGreaterThan 0
        $Result.PrivateMB | Should -BeGreaterThan 0
        $Result.ManagedMB | Should -BeGreaterThan 0
    }

    It 'does not trim a small Windows incremental cycle' {
        $Calls = [System.Collections.Generic.List[int]]::new()
        $Result = Invoke-AgentSyncMemoryMaintenance `
            -FullCycle $false `
            -WorkingSetThresholdBytes ([long]::MaxValue) `
            -CurrentPlatform 'windows' `
            -WorkingSetTrimAction {
                param ($Handle)
                $Calls.Add(1)
                return $true
            }

        $Calls.Count | Should -Be 0
        $Result.TrimAttempted | Should -BeFalse
        $Result.TrimState | Should -Be 'not-needed'
    }

    It 'never invokes the Windows trim boundary on another platform' {
        $Calls = [System.Collections.Generic.List[int]]::new()
        $Result = Invoke-AgentSyncMemoryMaintenance `
            -FullCycle $true `
            -WorkingSetThresholdBytes 1 `
            -CurrentPlatform 'linux' `
            -WorkingSetTrimAction {
                param ($Handle)
                $Calls.Add(1)
                return $true
            }

        $Calls.Count | Should -Be 0
        $Result.TrimAttempted | Should -BeFalse
        $Result.TrimState | Should -Be 'unsupported'
    }

    It 'connects cycle type to memory maintenance without trimming every small event' {
        $Definition = (Get-Command Invoke-AgentSyncCycle -CommandType Function).Definition

        $Definition | Should -Match 'Invoke-AgentSyncMemoryMaintenance\s+-FullCycle:\(-not \$Incremental\)'
        $Definition | Should -Match 'workingSetBeforeMB='
        $Definition | Should -Match 'privateMB='
        $Definition | Should -Match 'managedMB='
    }
}

Describe 'Completed-cycle status diagnostics' {

    It 'times each full-cycle manifest and continues after a project failure' {
        $Durations = [ordered]@{}
        Mock Get-AgentSyncProjects { @([pscustomobject]@{FullName='fixture-one'}, [pscustomobject]@{FullName='fixture-two'}) }
        Mock Update-ProjectManifest { [Threading.Thread]::Sleep(10); if($ProjectRoot -eq 'fixture-one'){throw 'unreadable fixture'} }
        Mock Write-AgentSyncError {}
        Update-AllProjectManifests -ProjectDurations $Durations
        $Durations.Count | Should -Be 2
        $Durations['fixture-one'] | Should -BeGreaterThan 0
        $Durations['fixture-two'] | Should -BeGreaterThan 0
        Should -Invoke Update-ProjectManifest -Exactly 2
        Should -Invoke Write-AgentSyncError -Exactly 1
    }

    It 'never replaces a manifest with a partial unreadable inventory' {
        $Project=Join-Path $TestDrive 'unreadable-manifest'
        $State=Join-Path $Project '.agent-state'
        $AgentRoot=Join-Path $State 'codex'
        [void][IO.Directory]::CreateDirectory($AgentRoot)
        $Manifest=Join-Path $State 'manifest.json'
        [IO.File]::WriteAllText($Manifest,'{"original":true}')
        Mock Get-ChildItem { throw [UnauthorizedAccessException]::new('fixture unreadable subtree') } -ParameterFilter {$LiteralPath -eq $AgentRoot}
        {Update-ProjectManifest -ProjectRoot $Project} | Should -Throw
        Should -Invoke Get-ChildItem -Exactly 1 -ParameterFilter {$LiteralPath -eq $AgentRoot -and $ErrorAction -eq 'Stop'}
        [IO.File]::ReadAllText($Manifest) | Should -BeExactly '{"original":true}'
    }

    It 'counts failed manifest publication as a health error' {
        $Project=Join-Path $TestDrive 'failed-manifest'
        [void][IO.Directory]::CreateDirectory((Join-Path $Project '.agent-state'))
        Mock Write-Utf8TextAtomic {throw 'fixture publication denied'}
        Mock Write-AgentSyncError {}
        Update-ProjectManifest -ProjectRoot $Project
        Should -Invoke Write-AgentSyncError -Exactly 1 -ParameterFilter {$Context -eq 'Manifest publication'}
    }

    It 'records bounded phase metadata and preserves adapter failure isolation in a full cycle' {
        $Status = Join-Path $TestDrive 'phase-status.json'
        Set-Content -LiteralPath $Status -Value '{}'
        $PreviousConfig = $Script:Config
        $Script:Config = [PSCustomObject]@{ agents = @(
            [PSCustomObject]@{ name = 'claude'; routingMode = 'claude' }
            [PSCustomObject]@{ name = 'codex'; routingMode = 'codex' }
            [PSCustomObject]@{ name = 'opencode'; routingMode = 'opencode'; enabled = $false }
        ) }
        $Script:TestLog.Clear()
        Mock Get-AgentSyncStatusJsonPath { $Status }
        Mock Test-AgentSyncStatusReportStale { $false }
        Mock Install-ProjectGuidance { [Threading.Thread]::Sleep(10) }
        Mock Quarantine-ConflictCopies {}
        Mock Sync-Claude { [Threading.Thread]::Sleep(10); throw 'synthetic adapter failure' }
        Mock Sync-RoutedFiles { [Threading.Thread]::Sleep(10) }
        Mock Sync-OpenCode { throw 'disabled adapter must not run' }
        Mock Save-AgentSyncProjectIndex {}
        Mock Update-AllProjectManifests {}
        Mock Update-AgentSyncStatusReport {}
        Mock Update-AgentSyncStatusDiagnostics { $true }
        Mock Update-AgentSyncIntelligenceReport {}
        Mock Invoke-ActivityPrune {}
        Mock Invoke-OverwrittenRetention {}
        Mock Invoke-ArchivePolicy {}
        Mock Invoke-AgentSyncMemoryMaintenance { [PSCustomObject]@{ TrimState = 'skipped' } }
        Mock Write-AgentSyncError { $Script:CycleErrorCount++ }
        try {
            Invoke-AgentSyncCycle -Trigger 'phase-fixture'
            $Phases = $Script:LastCycleDiag.phaseDurationsMs
            @($Phases.Keys) | Should -Be @('preflightStatus', 'discoveryIndex', 'agents', 'manifests', 'status', 'intelligence', 'maintenance', 'memoryMaintenance')
            @($Phases.agents.Keys) | Should -Be @('claude', 'codex')
            $Phases.discoveryIndex | Should -BeGreaterThan 0
            $Phases.agents.claude | Should -BeGreaterThan 0
            $Phases.agents.codex | Should -BeGreaterThan 0
            $Durations = @($Phases.GetEnumerator() | Where-Object Key -ne 'agents' | ForEach-Object Value) + @($Phases.agents.Values)
            foreach ($Duration in $Durations) { $Duration | Should -BeGreaterOrEqual 0 }
            ($Durations | Measure-Object -Sum).Sum | Should -BeLessOrEqual $Script:LastCycleDiag.durationMs
            $Script:LastCycleDiag.errors | Should -Be 1
            Should -Invoke Sync-RoutedFiles -Exactly 1
            Should -Invoke Sync-OpenCode -Exactly 0
            Should -Invoke Update-AgentSyncIntelligenceReport -Exactly 1
            Should -Invoke Update-AgentSyncStatusDiagnostics -Exactly 1
            $PhaseLogs = @($Script:TestLog | Where-Object { $_ -match 'CYCLE_PHASE ' })
            $PhaseLogs.Count | Should -Be 1
            $PhaseLogs[0] | Should -Not -Match 'phase-fixture|phase-status|TestDrive|synthetic adapter failure'
        }
        finally { $Script:Config = $PreviousConfig }
    }

    It 'updates only the diagnostic snapshot after a cycle finishes' {
        $Script:LogDirectory = $TestDrive
        $Script:DaemonStartedUtc = [System.DateTimeOffset]::Parse('2026-09-04T20:00:00Z')
        $Script:TotalCycles = 3
        $Script:TotalIncrementalCycles = 2
        $Script:TotalErrorsSinceStart = 0
        $Script:LastCycleDiag = [ordered]@{
            mode = 'full'
            durationMs = 1234
            phaseDurationsMs = [ordered]@{ agents = [ordered]@{ claude = 450L }; status = 20L }
            errors = 0
            completedUtc = '2026-09-04T20:01:00Z'
        }
        $StatusPath = Join-Path $TestDrive 'AgentSync-Status.json'
        [System.IO.File]::WriteAllText(
            $StatusPath,
            '{"generatedUtc":"2026-09-04T19:59:00Z","summary":{"projects":7},"diagnostics":{"cycles":0}}',
            [System.Text.UTF8Encoding]::new($false))

        Update-AgentSyncStatusDiagnostics -JsonReportFile $StatusPath | Should -BeTrue

        $Status = Get-Content -LiteralPath $StatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
        ([System.DateTimeOffset]$Status.generatedUtc).ToUnixTimeSeconds() | Should -Be ([System.DateTimeOffset]::Parse('2026-09-04T19:59:00Z')).ToUnixTimeSeconds()
        $Status.summary.projects | Should -Be 7
        $Status.diagnostics.cycles | Should -Be 3
        $Status.diagnostics.incrementalCycles | Should -Be 2
        $Status.diagnostics.lastCycle.mode | Should -Be 'full'
        $Status.diagnostics.lastCycle.durationMs | Should -Be 1234
        $Status.diagnostics.lastCycle.phaseDurationsMs.agents.claude | Should -Be 450
        $Status.diagnostics.lastCycle.phaseDurationsMs.status | Should -Be 20
    }

    It 'publishes every completed cycle without requiring a full status rebuild' {
        $Definition = (Get-Command Invoke-AgentSyncCycle -CommandType Function).Definition

        $Definition | Should -Not -Match 'if\s*\(\$StatusReportRan\)\s*\{\s*\[void\]\(Update-AgentSyncStatusDiagnostics\)'
        $Definition | Should -Match '\[void\]\(Update-AgentSyncStatusDiagnostics\)'
    }

    It 'uses report generation time even after diagnostic-only writes touch the file' {
        $StatusPath = Join-Path $TestDrive 'stale-metrics.json'
        $Generated = [datetimeoffset]::UtcNow.AddHours(-1).ToString('o')
        [IO.File]::WriteAllText($StatusPath, (@{generatedUtc=$Generated;diagnostics=@{}} | ConvertTo-Json))
        Test-AgentSyncStatusReportStale -JsonReportFile $StatusPath | Should -BeTrue
        [IO.File]::WriteAllText($StatusPath, (@{generatedUtc=[datetimeoffset]::UtcNow.ToString('o')} | ConvertTo-Json))
        Test-AgentSyncStatusReportStale -JsonReportFile $StatusPath | Should -BeFalse
        [IO.File]::WriteAllText($StatusPath, '{}')
        Test-AgentSyncStatusReportStale -JsonReportFile $StatusPath | Should -BeTrue
    }
}

Describe 'Incremental dispatch regression checks' {
    It 'runs only the Aider project manifest through the actual cycle' {
        $Project = Join-Path $TestDrive 'aider-dispatch'
        New-Item -ItemType Directory -Path (Join-Path $Project '.agent-state\aider') -Force | Out-Null
        $Status = Join-Path $TestDrive 'dispatch-status.json'
        Set-Content -LiteralPath $Status -Value '{}'
        $PreviousConfig = $Script:Config
        $Script:Config = [PSCustomObject]@{ agents = @(
            [PSCustomObject]@{ name = 'claude'; routingMode = 'claude' }
            [PSCustomObject]@{ name = 'opencode'; routingMode = 'opencode' }
        ) }
        Mock Get-AgentSyncStatusJsonPath { $Status }
        Mock Test-AgentSyncStatusReportStale { $false }
        Mock Save-AgentSyncProjectIndex {}
        Mock Update-ProjectManifest {}
        Mock Sync-Claude { throw 'Aider must not dispatch Claude' }
        Mock Sync-OpenCode { throw 'Aider must not dispatch OpenCode' }
        Mock Update-AllProjectManifests {}
        Mock Install-ProjectGuidance {}
        Mock Update-AgentSyncStatusDiagnostics { $true }
        Mock Invoke-AgentSyncMemoryMaintenance { [PSCustomObject]@{ TrimState = 'skipped' } }
        try {
            $Event = New-FakeEvent (Join-Path $Project '.agent-state\aider\work.chat.md')
            Test-RelevantWatcherEvent $Event | Should -Be 'relevant'
            $Scope = Get-EventScope $Event
            $Plan = Get-AgentSyncDispatchPlan -AgentScope $Scope.Agents -ProjectScope @($Scope.ProjectRoot)
            $Plan.RunFull | Should -BeFalse
            Invoke-AgentSyncCycle -AgentScope $Scope.Agents -ProjectScope @($Scope.ProjectRoot) -Trigger $Plan.Trigger
            Should -Invoke Update-ProjectManifest -Exactly 1 -ParameterFilter { $ProjectRoot -eq $Project }
            Should -Invoke Sync-Claude -Exactly 0
            Should -Invoke Sync-OpenCode -Exactly 0
            Should -Invoke Update-AllProjectManifests -Exactly 0
            Should -Invoke Install-ProjectGuidance -Exactly 0
            $Script:LastCycleDiag.mode | Should -Be 'incremental'
            $Script:LastCycleDiag.phaseDurationsMs.agents.Count | Should -Be 0
            $Script:LastCycleDiag.phaseDurationsMs.intelligence | Should -BeNullOrEmpty
            $Script:LastCycleDiag.phaseDurationsMs.maintenance | Should -BeNullOrEmpty
            $Script:LastCycleDiag.phaseDurationsMs.discoveryIndex | Should -BeGreaterOrEqual 0
            Should -Invoke Update-AgentSyncStatusDiagnostics -Exactly 1
        }
        finally { $Script:Config = $PreviousConfig }
    }

    It 'still forces safety, unknown and explicitly disabled incremental scans' {
        (Get-AgentSyncDispatchPlan -ProjectScope @('P:\A') -SafetyScanReady $true).RunFull | Should -BeTrue
        (Get-AgentSyncDispatchPlan -ProjectScope @('P:\A') -DirtyFull $true).RunFull | Should -BeTrue
        (Get-AgentSyncDispatchPlan -ProjectScope @('P:\A') -IncrementalSyncEnabled $false).RunFull | Should -BeTrue
        (Get-AgentSyncDispatchPlan).RunFull | Should -BeTrue
    }
}

Describe 'Watcher refresh and provider event diagnostics' {
    BeforeEach {
        $Script:WatchAgentByPath = @{ 'C:\Users\t\.local\share\opencode' = 'opencode' }
        $Script:WatchEventLogTimes = @{}
        $Script:TestLog.Clear()
    }

    It 'keeps OpenCode DB and WAL work but ignores only the known log subtree' {
        foreach ($Name in @('opencode.db', 'opencode.db-wal', 'storage\session\s1.json')) {
            Test-RelevantWatcherEvent (New-FakeEvent "C:\Users\t\.local\share\opencode\$Name" 'AgentSyncWatcher-1-1-A-Changed') | Should -Be 'relevant'
        }
        foreach ($Name in @('log\20260907.log', 'logs\child\x.txt', 'opencode.log')) {
            Test-RelevantWatcherEvent (New-FakeEvent "C:\Users\t\.local\share\opencode\$Name" 'AgentSyncWatcher-1-1-A-Changed') | Should -Be 'ignore'
        }
        Test-RelevantWatcherEvent (New-FakeEvent 'P:\Dropbox\logs\.agent-state\claude\x.jsonl') | Should -Be 'relevant'
    }

    It 'logs file category, decision and provider once without full paths or content' {
        $Event = New-FakeEvent 'C:\Users\t\.local\share\opencode\opencode.db-wal' 'AgentSyncWatcher-1-1-A-Changed'
        Write-AgentSyncWatchEventDiagnostic $Event 'relevant'
        Write-AgentSyncWatchEventDiagnostic $Event 'relevant'
        $Script:TestLog.Count | Should -Be 1
        $Script:TestLog[0] | Should -Match 'provider=opencode kind=database-wal change=Changed file=opencode.db-wal'
        $Script:TestLog[0] | Should -Not -Match 'Users|share'
    }

    It 'adds new project roots without replacing unchanged registrations and cleans obsolete ones' {
        $Keep = [PSCustomObject]@{ Path = 'P:\A\.agent-state'; Identity = 'keep' }
        $Old = [PSCustomObject]@{ Path = 'P:\gone\.agent-state'; Identity = 'remove' }
        Mock Get-AgentWatchPaths { @('P:\A\.agent-state', 'P:\new\.agent-state') }
        Mock Start-AgentSyncWatchers {
            foreach ($Path in $Paths) { [PSCustomObject]@{ Path = $Path; Identity = 'new' } }
        }
        Mock Stop-AgentSyncWatchers {}
        $Result = Update-AgentSyncWatchers -Registrations @($Keep, $Old)
        @($Result).Count | Should -Be 2
        [object]::ReferenceEquals($Result[0], $Keep) | Should -BeTrue
        Should -Invoke Start-AgentSyncWatchers -Exactly 1 -ParameterFilter { @($Paths).Count -eq 1 -and $Paths[0] -eq 'P:\new\.agent-state' }
        Should -Invoke Stop-AgentSyncWatchers -Exactly 1 -ParameterFilter { @($Registrations).Count -eq 1 -and $Registrations[0].Path -eq $Old.Path }
        $Again = Update-AgentSyncWatchers -Registrations $Result
        @($Again).Count | Should -Be 2
        Should -Invoke Start-AgentSyncWatchers -Exactly 1
        Should -Invoke Stop-AgentSyncWatchers -Exactly 1
    }
}

Describe 'OpenCode routing cache preserves real change signals' {
    BeforeEach {
        $Script:OpenCodeDiscoveryCache = $null
        $Script:ForceOpenCodeDiscovery = $false
        $Script:OpenCodeUnavailableWarned = $false
        $Script:CacheRoot = Join-Path $TestDrive 'opencode-cache'
        New-Item -ItemType Directory -Path $Script:CacheRoot -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Script:CacheRoot 'opencode.db') -Value 'fixture metadata'
        $Agent = [PSCustomObject]@{ commandTimeoutSeconds = 5 }
        Mock Get-PlatformConfiguredPath { $Script:CacheRoot }
        Mock Get-OpenCodeCommandPath { 'fixture-cli' }
        Mock Invoke-OpenCodeCli {
            [PSCustomObject]@{ ExitCode = 0; StdErr = ''; StdOut = '[{"id":"ses_test123","directory":"P:\\A","title":"fixture","created":10,"updated":20}]' }
        }
    }

    It 'reuses unchanged metadata without launching the CLI again' {
        @(Get-OpenCodeSessionList $Agent).Count | Should -Be 1
        $Script:OpenCodeSessionListCache = $null
        @(Get-OpenCodeSessionList $Agent).Count | Should -Be 1
        Should -Invoke Invoke-OpenCodeCli -Exactly 1
    }

    It 'refreshes on WAL appearance and on DB metadata change' {
        [void](Get-OpenCodeSessionList $Agent)
        Set-Content -LiteralPath (Join-Path $Script:CacheRoot 'opencode.db-wal') -Value 'new work'
        [void](Get-OpenCodeSessionList $Agent)
        Add-Content -LiteralPath (Join-Path $Script:CacheRoot 'opencode.db') -Value 'more work'
        [void](Get-OpenCodeSessionList $Agent)
        Should -Invoke Invoke-OpenCodeCli -Exactly 3
    }

    It 'expires the bounded cache and bypasses it on full safety scans and import refresh' {
        [void](Get-OpenCodeSessionList $Agent)
        $Script:OpenCodeDiscoveryCache.CreatedUtc = [DateTimeOffset]::UtcNow.AddSeconds(-61)
        [void](Get-OpenCodeSessionList $Agent)
        $Script:ForceOpenCodeDiscovery = $true
        [void](Get-OpenCodeSessionList $Agent)
        $Script:ForceOpenCodeDiscovery | Should -BeFalse
        [void](Get-OpenCodeSessionList $Agent -Force)
        Should -Invoke Invoke-OpenCodeCli -Exactly 4
    }

    It 'does not cache failed or invalid discovery as successful metadata' {
        Mock Invoke-OpenCodeCli { [PSCustomObject]@{ ExitCode = 0; StdErr = ''; StdOut = 'bad data' } }
        @(Get-OpenCodeSessionList $Agent).Count | Should -Be 0
        @(Get-OpenCodeSessionList $Agent).Count | Should -Be 0
        $Script:OpenCodeDiscoveryCache | Should -BeNullOrEmpty
        Should -Invoke Invoke-OpenCodeCli -Exactly 2
    }
}
