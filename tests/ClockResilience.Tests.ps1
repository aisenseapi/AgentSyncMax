# Load actual production functions without starting the engine or touching
# provider history. All files below are isolated Pester TestDrive fixtures.
BeforeAll {
    $Tokens = $null
    $Errors = $null
    $EnginePath = Join-Path $PSScriptRoot '..\Sync-AgentState.ps1'
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile($EnginePath, [ref]$Tokens, [ref]$Errors)
    if ($Errors.Count) { throw $Errors[0].Message }
    $WatcherLoop = @($Ast.FindAll({ param($Node)
        $Node -is [System.Management.Automation.Language.WhileStatementAst] -and
            $Node.Extent.Text.StartsWith('while ($true)')
    }, $true))
    if ($WatcherLoop.Count -ne 1) { throw 'Expected exactly one daemon watcher loop.' }
    $WatcherLoopText = $WatcherLoop[0].Extent.Text
    $Definitions = $Ast.FindAll({ param($Node)
        $Node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $false).Extent.Text -join "`n"
    $Definitions += @'

function Set-ClockStateForTest {
    param([string]$Name, $Value)
    Set-Variable -Scope Script -Name $Name -Value $Value
}
function Get-ClockStateForTest {
    param([string]$Name)
    (Get-Variable -Scope Script -Name $Name).Value
}
function Reset-ClockStateForTest {
    param([string]$Root)
    $Script:PlatformName = 'windows'
    $Script:PathComparison = [StringComparison]::OrdinalIgnoreCase
    $Script:MachineId = 'CLOCK-TEST'
    $Script:ToolkitRoot = $Root
    $Script:AgentSyncVersion = 'test'
    $Script:ProjectsBasePath = Join-Path $Root 'projects'
    $Script:LogPath = Join-Path $Root 'not-created.log'
    $Script:ConfigFile = Join-Path $Root 'config.json'
    $Script:Config = [pscustomobject]@{
        agents = @()
        projectIndex = [pscustomobject]@{ directory = (Join-Path $Root 'index'); refreshSeconds = 60 }
        statusReport = [pscustomobject]@{
            file = (Join-Path $Root 'status.html'); dataFile = (Join-Path $Root 'status.json'); refreshSeconds = 300
        }
        intelligenceReport = [pscustomobject]@{
            enabled = $true; dataFile = (Join-Path $Root 'intelligence.json'); refreshSeconds = 300; commandTimeoutSeconds = 10
        }
    }
    $Script:KnownProjectRoots = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $Script:LocalProjectRoots = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $Script:ProjectIndexLastReadUtc = [DateTimeOffset]::MinValue
    $Script:LocalAgentAuditCache = $null
    $Script:ClaudeWorkspaceMapCache = @{}
    $Script:SessionCwdCache = @{}
    $Script:UnreadableWarned = @{}
    $Script:MetadataReadLines = 100
    $Script:OpenCodeDiscoveryCache = $null
    $Script:OpenCodeUnavailableWarned = $false
    $Script:ForceOpenCodeDiscovery = $false
    $Script:StatusReportLastWriteUtc = [DateTimeOffset]::MinValue
    $Script:StatusReportCoreHash = $null
    $Script:StatusAuditIssueHash = $null
    $Script:IntelligenceReportLastRunUtc = [DateTimeOffset]::MinValue
    $Script:SelfWrittenPaths = @{}
    $Script:WatchAgentByPath = @{}
    $Script:DryRun = $false
}
function Write-AgentSyncLog { param($Level, $Message, [switch]$Console) }
'@
    $FixtureEngineRoot = Join-Path $TestDrive 'engine'
    [void][IO.Directory]::CreateDirectory($FixtureEngineRoot)
    $FixtureEngine = Join-Path $FixtureEngineRoot 'functions.ps1'
    [IO.File]::WriteAllText($FixtureEngine, $Definitions)
    # The child boundary is mocked; this file only satisfies existence checks.
    [IO.File]::WriteAllText((Join-Path $FixtureEngineRoot 'Build-AgentSync-Intelligence.ps1'), 'throw "must not execute"')
    . $FixtureEngine
}

Describe 'Local wall-clock freshness guards' {
    BeforeEach {
        $FixtureRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory((Join-Path $FixtureRoot 'projects'))
        [void][IO.Directory]::CreateDirectory((Join-Path $FixtureRoot 'index'))
        Reset-ClockStateForTest $FixtureRoot
    }

    It 'accepts only nonnegative ages strictly below the window' {
        $Now = [DateTimeOffset]::Parse('2026-10-24T19:27:54Z')
        Test-AgentSyncRecentTimestamp -Since $Now -WindowSeconds 60 -Now $Now | Should -BeTrue
        Test-AgentSyncRecentTimestamp -Since $Now.AddSeconds(-59) -WindowSeconds 60 -Now $Now | Should -BeTrue
        Test-AgentSyncRecentTimestamp -Since $Now.AddSeconds(-60) -WindowSeconds 60 -Now $Now | Should -BeFalse
        Test-AgentSyncRecentTimestamp -Since $Now.AddHours(6) -WindowSeconds 60 -Now $Now | Should -BeFalse
        Test-AgentSyncRecentTimestamp -Since $Now.AddHours(-6) -WindowSeconds 60 -Now $Now | Should -BeFalse
    }

    It 'discovers projects after a backwards clock correction and still throttles normal repeats' {
        $Project = Join-Path $FixtureRoot 'projects/Example'
        [void][IO.Directory]::CreateDirectory($Project)
        [IO.File]::WriteAllText((Join-Path $FixtureRoot 'index/host.json'), '{"projects":["Example"]}')
        Set-ClockStateForTest ProjectIndexLastReadUtc ([DateTimeOffset]::UtcNow.AddHours(6))

        Update-AgentSyncProjectIndex

        (Get-ClockStateForTest KnownProjectRoots).Contains($Project) | Should -BeTrue
        $FirstRead = Get-ClockStateForTest ProjectIndexLastReadUtc
        Update-AgentSyncProjectIndex
        Get-ClockStateForTest ProjectIndexLastReadUtc | Should -Be $FirstRead
    }

    It 'does not reuse a matching audit cached in the future' {
        Mock Get-AgentSyncProjects { @() }
        Set-ClockStateForTest LocalAgentAuditCache ([pscustomobject]@{
            ReportSignature = ''; CreatedUtc = [DateTimeOffset]::UtcNow.AddHours(6)
            Rows = @([pscustomobject]@{ Agent = 'stale sentinel' })
        })

        $Rows = @(Get-LocalAgentProjectAudit -ReportRows @())

        $Rows.Count | Should -Be 6
        $Rows.Agent | Should -Not -Contain 'stale sentinel'
        $Rows.Agent | Should -Contain 'Claude'
    }

    It 'rebuilds the Claude workspace map from actual metadata after rollback' {
        $Native = Join-Path $FixtureRoot 'claude'
        $Project = Join-Path $FixtureRoot 'projects/Example'
        [void][IO.Directory]::CreateDirectory($Native)
        [void][IO.Directory]::CreateDirectory($Project)
        [IO.File]::WriteAllText((Join-Path $Native 'session.jsonl'), ((@{ type = 'user'; cwd = $Project } | ConvertTo-Json -Compress) + "`n"))
        Set-ClockStateForTest ClaudeWorkspaceMapCache @{
            $Native = @{ CreatedUtc = [DateTimeOffset]::UtcNow.AddHours(6); Map = @{ stale = 'old' } }
        }

        $Map = Get-ClaudeKnownWorkspaceMap -LocalRoot $Native

        $Map.ContainsKey('stale') | Should -BeFalse
        $Map[(ConvertTo-ClaudeProjectSlug $Project)] | Should -Be $Project
    }

    It 'queries OpenCode metadata rather than trusting a future-dated matching cache' {
        Mock Get-OpenCodeSourceFingerprint { 'same-source' }
        Mock Get-OpenCodeCommandPath { 'not-executed.exe' }
        Mock Invoke-OpenCodeCli {
            @{ ExitCode = 0; StdErr = ''; StdOut = '[{"id":"fresh","directory":"C:/fixture","created":1,"updated":2}]' }
        }
        Set-ClockStateForTest OpenCodeDiscoveryCache ([pscustomobject]@{
            Fingerprint = 'same-source'; CreatedUtc = [DateTimeOffset]::UtcNow.AddHours(6)
            Sessions = @([pscustomobject]@{ Id = 'stale' })
        })

        $Sessions = @(Get-OpenCodeSessionList -Agent ([pscustomobject]@{ commandTimeoutSeconds = 1 }))

        $Sessions.Count | Should -Be 1
        $Sessions[0].Id | Should -Be 'fresh'
        Should -Invoke Invoke-OpenCodeCli -Exactly 1
        @(Get-OpenCodeSessionList -Agent ([pscustomobject]@{ commandTimeoutSeconds = 1 }))[0].Id | Should -Be 'fresh'
        Should -Invoke Invoke-OpenCodeCli -Exactly 1
    }

    It 'refreshes Intelligence after rollback without retrying repeatedly against a future file mtime' {
        $Report = Join-Path $FixtureRoot 'intelligence.json'
        [IO.File]::WriteAllText($Report, '{"oldCompleteReport":true}')
        [IO.File]::SetLastWriteTimeUtc($Report, [DateTime]::UtcNow.AddHours(6))
        Set-ClockStateForTest IntelligenceReportLastRunUtc ([DateTimeOffset]::UtcNow.AddHours(6))
        Mock Invoke-AgentSyncPowerShellScript {
            @{ ExitCode = 0; StdOut = 'INTELLIGENCE pending: fixture'; StdErr = ''; DurationMs = 1 }
        }

        Update-AgentSyncIntelligenceReport
        Update-AgentSyncIntelligenceReport

        Should -Invoke Invoke-AgentSyncPowerShellScript -Exactly 1 -ParameterFilter {
            $TimeoutSeconds -eq 10 -and ($ScriptArguments -join '|') -match 'WorkBudgetSeconds\|5$'
        }
        (Get-Content -LiteralPath $Report -Raw | ConvertFrom-Json).oldCompleteReport | Should -BeTrue
        Get-ClockStateForTest IntelligenceReportLastRunUtc | Should -BeLessOrEqual ([DateTimeOffset]::UtcNow)
    }

    It 'rewrites a future-dated unchanged status report, then honors its refresh interval' {
        Mock Get-AgentDerivedStatusData { @{ Rows = @(); Conflicts = 0; UnresolvedFiles = 0 } }
        Mock Get-LocalAgentProjectAudit { @() }
        Mock Get-AgentSyncDiagnosticsSnapshot { @{ fixture = $true } }
        $Html = Join-Path $FixtureRoot 'status.html'
        $Json = Join-Path $FixtureRoot 'status.json'
        Update-AgentSyncStatusReport
        $Initial = (Get-Content -LiteralPath $Json -Raw | ConvertFrom-Json).generatedUtc
        Set-ClockStateForTest StatusReportLastWriteUtc ([DateTimeOffset]::UtcNow.AddHours(6))
        [IO.File]::WriteAllText($Html, 'stale sentinel')

        Update-AgentSyncStatusReport

        (Get-Content -LiteralPath $Html -Raw) | Should -Not -Be 'stale sentinel'
        (Get-Content -LiteralPath $Json -Raw | ConvertFrom-Json).generatedUtc | Should -BeGreaterOrEqual $Initial
        $Hash = (Get-FileHash -LiteralPath $Json).Hash
        $Stamp = Get-ClockStateForTest StatusReportLastWriteUtc
        Update-AgentSyncStatusReport
        (Get-FileHash -LiteralPath $Json).Hash | Should -Be $Hash
        Get-ClockStateForTest StatusReportLastWriteUtc | Should -Be $Stamp
    }

    It 'treats a future generation time as stale regardless of fresh file writes' {
        $Json = Join-Path $FixtureRoot 'status.json'
        [IO.File]::WriteAllText($Json, (@{ generatedUtc = [DateTimeOffset]::UtcNow.AddHours(6).ToString('o') } | ConvertTo-Json))
        Test-AgentSyncStatusReportStale -JsonReportFile $Json | Should -BeTrue
    }

    It 'does not hide native watcher changes behind a future self-write timestamp' {
        $Path = Join-Path $FixtureRoot 'projects/Example/.agent-state/claude/sessions/session.jsonl'
        $Key = Get-AgentSyncWatcherPathKey $Path
        Set-ClockStateForTest SelfWrittenPaths @{ $Key = [DateTimeOffset]::UtcNow.AddHours(6) }
        $Event = [pscustomobject]@{
            SourceIdentifier = 'AgentSyncWatcher-1-0-P-Changed'
            SourceEventArgs = [pscustomobject]@{ FullPath = $Path }
        }

        Test-RelevantWatcherEvent -WatcherEvent $Event | Should -Be 'relevant'
        (Get-ClockStateForTest SelfWrittenPaths).ContainsKey($Key) | Should -BeFalse
        Register-AgentSyncSelfWrite -Path $Path
        Test-RelevantWatcherEvent -WatcherEvent $Event | Should -Be 'ignore'
    }
}

Describe 'Monotonic watcher scheduling' {
    It 'does not dispatch before the quiet-period boundary and accepts a zero tick' {
        $Timing = Get-AgentSyncWatcherReadiness -DirtySinceMs 0 -DirtyFirstMs 0 -LastFullScanMs 0 -DebounceMs 30000 -MaxDirtyWaitSeconds 120 -SafetyScanSeconds 900 -NowMs 29999
        $Timing.DebounceReady | Should -BeFalse
        $Timing.MaxWaitReady | Should -BeFalse
        $Timing.SafetyScanReady | Should -BeFalse
        (Get-AgentSyncWatcherReadiness -DirtySinceMs 0 -DirtyFirstMs 0 -LastFullScanMs 0 -DebounceMs 30000 -MaxDirtyWaitSeconds 120 -SafetyScanSeconds 900 -NowMs 30000).DebounceReady | Should -BeTrue
    }

    It 'dispatches continuous activity at the max-wait boundary without waiting for a quiet period' {
        $Timing = Get-AgentSyncWatcherReadiness -DirtySinceMs 119999 -DirtyFirstMs 0 -LastFullScanMs 0 -DebounceMs 30000 -MaxDirtyWaitSeconds 120 -SafetyScanSeconds 900 -NowMs 120000
        $Timing.DebounceReady | Should -BeFalse
        $Timing.MaxWaitReady | Should -BeTrue
        $Plan = Get-AgentSyncDispatchPlan -AgentScope @('claude') -MaxWaitReady $Timing.MaxWaitReady -SafetyScanReady $Timing.SafetyScanReady
        $Plan.RunFull | Should -BeFalse
        $Plan.Trigger | Should -Be 'max-wait'
    }

    It 'runs an idle safety scan from monotonic time without any UTC clock input' {
        Mock Get-AgentSyncMonotonicMilliseconds { 900000 }
        $Timing = Get-AgentSyncWatcherReadiness -LastFullScanMs 0 -DebounceMs 30000 -MaxDirtyWaitSeconds 120 -SafetyScanSeconds 900
        $Timing.DebounceReady | Should -BeFalse
        $Timing.MaxWaitReady | Should -BeFalse
        $Timing.SafetyScanReady | Should -BeTrue
        (Get-AgentSyncDispatchPlan -AgentScope @('claude') -SafetyScanReady $Timing.SafetyScanReady).RunFull | Should -BeTrue
    }

    It 'immediately dispatches a watcher error timestamp already aged by the debounce interval' {
        $Timing = Get-AgentSyncWatcherReadiness -DirtySinceMs 70000 -LastFullScanMs 0 -DebounceMs 30000 -MaxDirtyWaitSeconds 120 -SafetyScanSeconds 900 -NowMs 100000
        $Timing.DebounceReady | Should -BeTrue
        (Get-AgentSyncDispatchPlan -DirtyFull $true -SafetyScanReady $Timing.SafetyScanReady).RunFull | Should -BeTrue
    }

    It 'runs the actual watcher loop from a queued event to incremental dispatch on the monotonic boundary' {
        $FixtureRoot = Join-Path $TestDrive 'watcher-loop'
        Reset-ClockStateForTest $FixtureRoot
        Set-ClockStateForTest ClockLoopTick 0
        Set-ClockStateForTest ClockLoopWaits 0
        Set-ClockStateForTest ClockLoopEvent ([pscustomobject]@{
            EventIdentifier = 1
            SourceIdentifier = 'AgentSyncWatcher-1-0-P-Changed'
            SourceEventArgs = [pscustomobject]@{
                FullPath = (Join-Path $FixtureRoot 'projects/Example/.agent-state/claude/sessions/session.jsonl')
            }
        })
        Mock Ensure-AgentSyncActiveMemoryWorker {}
        Mock Get-AgentSyncMonotonicMilliseconds { Get-ClockStateForTest ClockLoopTick }
        Mock Wait-Event {
            $Attempt = (Get-ClockStateForTest ClockLoopWaits) + 1
            Set-ClockStateForTest ClockLoopWaits $Attempt
            if ($Attempt -eq 1) { return (Get-ClockStateForTest ClockLoopEvent) }
            if ($Attempt -eq 2) { Set-ClockStateForTest ClockLoopTick 30000; return $null }
            throw 'bounded-clock-loop-complete'
        }
        Mock Get-Event { @() }
        Mock Remove-Event {}
        Mock Write-AgentSyncWatchEventDiagnostic {}
        Mock Invoke-AgentSyncCycle {}
        Mock Update-AgentSyncWatchers { @() }
        $LastFullScanMs = 0
        $DirtySince = $null
        $DirtyFirst = $null
        $DirtyFull = $false
        $DirtyAgents = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $DirtyProjects = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $FailureStreak = 0
        $Watchers = @()
        $DebounceMs = 30000
        $MaxDirtyWaitSeconds = 120
        $SafetyScanSeconds = 900
        $IncrementalSyncEnabled = $true
        $BoundedLoop = [scriptblock]::Create($WatcherLoopText)

        { . $BoundedLoop } | Should -Throw '*bounded-clock-loop-complete*'

        Should -Invoke Invoke-AgentSyncCycle -Exactly 1 -ParameterFilter {
            $Trigger -eq 'debounce' -and @($AgentScope).Count -eq 1 -and $AgentScope[0] -eq 'claude'
        }
        Should -Invoke Wait-Event -Exactly 3
        Should -Invoke Update-AgentSyncWatchers -Exactly 1
    }
}
