BeforeAll {
    . (Join-Path $PSScriptRoot '..\AgentSync.ActiveMemory.ps1')
    function New-MemoryTestRelease {
        param([string]$Version)
        $Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $Dist = Join-Path $Root 'desktop/dist'
        [void][IO.Directory]::CreateDirectory($Dist)
        $Source = Join-Path $Root 'built.exe'
        [IO.File]::WriteAllText($Source, 'fixture only, never execute')
        [void](Publish-AgentSyncDesktopBuild -Source $Source -ToolkitRoot $Root -Version $Version -SkipLegacyAliases)
        return $Root
    }
}

Describe 'Optional active-memory companion launch' {
    It 'uses verified C-runtime launch routing and a separate argument list' {
        $Root = New-MemoryTestRelease '4.26.1'
        $Plan = Get-AgentSyncActiveMemoryLaunchPlan -ToolkitRoot $Root -LocalRoot (Join-Path $TestDrive 'runtime')
        $Info = New-AgentSyncActiveMemoryStartInfo -Plan $Plan -ParentProcessId 1234
        $Info.FileName | Should -Be $Plan.Executable
        $Info.WorkingDirectory | Should -Be $Plan.WorkingDirectory
        $Info.Environment['AGENTSYNC_HOME'] | Should -Be $Root
        $Info.UseShellExecute | Should -BeFalse
        $Info.CreateNoWindow | Should -BeTrue
        $Info.WindowStyle | Should -Be ([Diagnostics.ProcessWindowStyle]::Hidden)
        ($Info.ArgumentList -join '|') | Should -Be '--active-memory-worker|--parent-pid|1234'
    }

    It 'does not start a legacy release with a headless flag it cannot understand' {
        $Root = New-MemoryTestRelease '4.26.0'
        { Get-AgentSyncActiveMemoryLaunchPlan -ToolkitRoot $Root -LocalRoot (Join-Path $TestDrive 'old-runtime') } |
            Should -Throw '*4.26.1*'
    }

    It 'fails closed if the published executable was changed' {
        $Root = New-MemoryTestRelease '4.26.1'
        $Release = Get-Content -LiteralPath (Join-Path $Root 'desktop/dist/current-release.json') -Raw | ConvertFrom-Json
        [IO.File]::AppendAllText((Join-Path $Root ('desktop/dist/' + $Release.executable)), 'changed')
        { Get-AgentSyncActiveMemoryLaunchPlan -ToolkitRoot $Root -LocalRoot (Join-Path $TestDrive 'bad-runtime') } |
            Should -Throw '*SHA-256*'
    }

    It 'rejects an invalid parent id before any executable launch' {
        { New-AgentSyncActiveMemoryStartInfo -Plan @{} -ParentProcessId 0 } | Should -Throw
    }

    It 'keeps the companion behind the engine mutex and out of non-daemon modes' {
        $Source = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Sync-AgentState.ps1') -Raw
        $Source.IndexOf('$Script:ActiveMemoryCompanionAllowed = ($PlatformName') |
            Should -BeGreaterThan $Source.IndexOf('if (-not $MutexAcquired)')
        $Source | Should -Match 'ActiveMemoryCompanionAllowed = \(\$PlatformName -eq ''windows'' -and -not \$Once -and -not \$Script:DryRun\)'
        $Source | Should -Match 'if \(-not \$Script:ActiveMemoryCompanionAllowed\) \{ return \}'
    }
}

Describe 'Engine active-memory companion lifecycle' {
    BeforeAll {
        $Tokens = $null
        $Errors = $null
        $EnginePath = Join-Path $PSScriptRoot '..\Sync-AgentState.ps1'
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($EnginePath, [ref]$Tokens, [ref]$Errors)
        if ($Errors.Count -gt 0) { throw "Engine does not parse: $($Errors[0].Message)" }
        $Definition = @($Ast.FindAll({
            param($Node)
            $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $Node.Name -in @('Ensure-AgentSyncActiveMemoryWorker', 'Test-AgentSyncRecentTimestamp')
        }, $false))
        if ($Definition.Count -ne 2) { throw 'Expected companion lifecycle and timestamp guard functions.' }

        # Keep the engine function unchanged, but give its $PSScriptRoot a
        # fixture containing only a fake launcher. The daemon is never loaded.
        $FixtureRoot = Join-Path $TestDrive 'companion-engine'
        [void][IO.Directory]::CreateDirectory($FixtureRoot)
        $Helpers = @'

function Reset-MemoryWorkerForTest {
    param([bool]$Allowed = $true, $Process = $null)
    $Script:ActiveMemoryCompanionAllowed = $Allowed
    $Script:ActiveMemoryWorkerProcess = $Process
    $Script:ActiveMemoryWorkerLastAttempt = [DateTimeOffset]::MinValue
    $Script:MemoryWorkerLaunchProcess = $null
    $Script:MemoryWorkerLaunchError = $null
    $Script:MemoryWorkerLaunches = [Collections.Generic.List[object]]::new()
    $Script:MemoryWorkerLogs = [Collections.Generic.List[object]]::new()
}
function Set-MemoryWorkerLaunchForTest {
    param($Process = $null, [string]$ErrorMessage = '')
    $Script:MemoryWorkerLaunchProcess = $Process
    $Script:MemoryWorkerLaunchError = $ErrorMessage
}
function Set-MemoryWorkerAttemptForTest {
    param([DateTimeOffset]$Value)
    $Script:ActiveMemoryWorkerLastAttempt = $Value
}
function Invoke-MemoryWorkerLaunchForTest {
    param([string]$ToolkitRoot, [int]$ParentProcessId)
    $Script:MemoryWorkerLaunches.Add([pscustomobject]@{ Root = $ToolkitRoot; ParentId = $ParentProcessId })
    if ($Script:MemoryWorkerLaunchError) { throw $Script:MemoryWorkerLaunchError }
    return $Script:MemoryWorkerLaunchProcess
}
function Write-AgentSyncLog {
    param([string]$Level, [string]$Message)
    $Script:MemoryWorkerLogs.Add([pscustomobject]@{ Level = $Level; Message = $Message })
}
function Get-MemoryWorkerStateForTest {
    [pscustomobject]@{
        Process = $Script:ActiveMemoryWorkerProcess
        LastAttempt = $Script:ActiveMemoryWorkerLastAttempt
        Launches = $Script:MemoryWorkerLaunches.ToArray()
        Logs = $Script:MemoryWorkerLogs.ToArray()
    }
}
'@
        $FixtureEngine = Join-Path $FixtureRoot 'engine-functions.ps1'
        [IO.File]::WriteAllText($FixtureEngine, ($Definition.Extent.Text -join "`n") + "`n" + $Helpers)
        [IO.File]::WriteAllText((Join-Path $FixtureRoot 'AgentSync.ActiveMemory.ps1'), @'
function Start-AgentSyncActiveMemoryWorker {
    param([string]$ToolkitRoot, [int]$ParentProcessId)
    Invoke-MemoryWorkerLaunchForTest -ToolkitRoot $ToolkitRoot -ParentProcessId $ParentProcessId
}
'@)
        . $FixtureEngine

        function New-MemoryWorkerProcessForTest {
            param([bool]$HasExited = $false, [int]$ProcessId = 12345)
            $Process = [pscustomobject]@{ HasExited = $HasExited; Id = $ProcessId; DisposeCount = 0 }
            $Process | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.DisposeCount++ }
            return $Process
        }
    }

    BeforeEach {
        Reset-MemoryWorkerForTest
    }

    It 'does nothing when the daemon companion is not allowed' {
        $Exited = New-MemoryWorkerProcessForTest -HasExited $true
        Reset-MemoryWorkerForTest -Allowed $false -Process $Exited

        Ensure-AgentSyncActiveMemoryWorker

        $State = Get-MemoryWorkerStateForTest
        $State.Launches.Count | Should -Be 0
        $State.Logs.Count | Should -Be 0
        $State.LastAttempt | Should -Be ([DateTimeOffset]::MinValue)
        [object]::ReferenceEquals($State.Process, $Exited) | Should -BeTrue
        $Exited.DisposeCount | Should -Be 0
    }

    It 'retains a live companion without attempting another launch' {
        $Live = New-MemoryWorkerProcessForTest
        Reset-MemoryWorkerForTest -Process $Live

        Ensure-AgentSyncActiveMemoryWorker

        $State = Get-MemoryWorkerStateForTest
        [object]::ReferenceEquals($State.Process, $Live) | Should -BeTrue
        $State.Launches.Count | Should -Be 0
        $State.Logs.Count | Should -Be 0
        $State.LastAttempt | Should -Be ([DateTimeOffset]::MinValue)
        $Live.DisposeCount | Should -Be 0
    }

    It 'disposes an exited companion and records its replacement' {
        $Exited = New-MemoryWorkerProcessForTest -HasExited $true
        $Replacement = New-MemoryWorkerProcessForTest -ProcessId 23456
        Reset-MemoryWorkerForTest -Process $Exited
        Set-MemoryWorkerLaunchForTest -Process $Replacement
        $Before = [DateTimeOffset]::UtcNow

        Ensure-AgentSyncActiveMemoryWorker

        $State = Get-MemoryWorkerStateForTest
        $Exited.DisposeCount | Should -Be 1
        [object]::ReferenceEquals($State.Process, $Replacement) | Should -BeTrue
        $State.Launches.Count | Should -Be 1
        $State.Launches[0].Root | Should -Be $FixtureRoot
        $State.Launches[0].ParentId | Should -Be $PID
        $State.LastAttempt | Should -BeGreaterOrEqual $Before
        $State.LastAttempt | Should -BeLessOrEqual ([DateTimeOffset]::UtcNow)
        $State.Logs.Count | Should -Be 1
        $State.Logs[0].Level | Should -Be 'INFO'
        $State.Logs[0].Message | Should -Match 'worker-launched pid=23456'
    }

    It 'contains launch failures and clears the dead process reference' {
        $Exited = New-MemoryWorkerProcessForTest -HasExited $true
        Reset-MemoryWorkerForTest -Process $Exited
        Set-MemoryWorkerLaunchForTest -ErrorMessage 'fixture launch unavailable'
        $Before = [DateTimeOffset]::UtcNow

        { Ensure-AgentSyncActiveMemoryWorker } | Should -Not -Throw

        $State = Get-MemoryWorkerStateForTest
        $Exited.DisposeCount | Should -Be 1
        $State.Process | Should -BeNullOrEmpty
        $State.Launches.Count | Should -Be 1
        $State.LastAttempt | Should -BeGreaterOrEqual $Before
        $State.Logs.Count | Should -Be 1
        $State.Logs[0].Level | Should -Be 'WARN'
        $State.Logs[0].Message | Should -Be 'ACTIVE_MEMORY unavailable: fixture launch unavailable'
    }

    It 'throttles a failed launch and retries after the sixty-second interval' {
        Set-MemoryWorkerLaunchForTest -ErrorMessage 'fixture launch unavailable'
        Ensure-AgentSyncActiveMemoryWorker
        $FirstAttempt = (Get-MemoryWorkerStateForTest).LastAttempt
        $Replacement = New-MemoryWorkerProcessForTest
        Set-MemoryWorkerLaunchForTest -Process $Replacement

        Ensure-AgentSyncActiveMemoryWorker

        $Throttled = Get-MemoryWorkerStateForTest
        $Throttled.Launches.Count | Should -Be 1
        $Throttled.Logs.Count | Should -Be 1
        $Throttled.LastAttempt | Should -Be $FirstAttempt
        $Throttled.Process | Should -BeNullOrEmpty

        Set-MemoryWorkerAttemptForTest -Value ([DateTimeOffset]::UtcNow.AddSeconds(-61))
        Ensure-AgentSyncActiveMemoryWorker

        $Retried = Get-MemoryWorkerStateForTest
        $Retried.Launches.Count | Should -Be 2
        $Retried.Logs.Count | Should -Be 2
        [object]::ReferenceEquals($Retried.Process, $Replacement) | Should -BeTrue
        $Retried.Logs[1].Level | Should -Be 'INFO'
        $Retried.LastAttempt | Should -BeGreaterOrEqual $FirstAttempt
    }

    It 'retries after a backwards clock correction instead of waiting for the old future time' {
        $Replacement = New-MemoryWorkerProcessForTest
        Set-MemoryWorkerLaunchForTest -Process $Replacement
        Set-MemoryWorkerAttemptForTest -Value ([DateTimeOffset]::UtcNow.AddHours(6))

        Ensure-AgentSyncActiveMemoryWorker

        $State = Get-MemoryWorkerStateForTest
        $State.Launches.Count | Should -Be 1
        [object]::ReferenceEquals($State.Process, $Replacement) | Should -BeTrue
        $State.LastAttempt | Should -BeLessOrEqual ([DateTimeOffset]::UtcNow)
        Ensure-AgentSyncActiveMemoryWorker
        (Get-MemoryWorkerStateForTest).Launches.Count | Should -Be 1
    }
}
