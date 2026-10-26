BeforeAll {
    $Tokens = $null
    $Errors = $null
    $EnginePath = Join-Path $PSScriptRoot '..\Sync-AgentState.ps1'
    $Ast = [Management.Automation.Language.Parser]::ParseFile($EnginePath, [ref]$Tokens, [ref]$Errors)
    if ($Errors.Count) { throw $Errors[0].Message }
    $Definitions = ($Ast.FindAll({ param($Node)
        $Node -is [Management.Automation.Language.FunctionDefinitionAst]
    }, $false) | ForEach-Object { $_.Extent.Text }) -join "`n"
    $FixtureEngine = Join-Path $TestDrive 'status-functions.ps1'
    [IO.File]::WriteAllText($FixtureEngine, $Definitions)
    . $FixtureEngine
}

Describe 'Status phase measurements and process identity' {
    BeforeEach {
        $Script:Config = [pscustomobject]@{
            agents = @()
            statusReport = [pscustomobject]@{
                enabled = $true
                file = (Join-Path $TestDrive 'status.html')
                jsonFile = (Join-Path $TestDrive 'status.json')
                refreshSeconds = 300
            }
        }
        $Script:AgentSyncVersion = 'test'
        $Script:MachineId = 'TESTHOST'
        $Script:PlatformName = 'windows'
        $Script:ProjectsBasePath = $TestDrive
        $Script:LogDirectory = $TestDrive
        $Script:LogPath = Join-Path $TestDrive 'missing.log'
        $Script:DaemonStartedUtc = [DateTimeOffset]::UtcNow
        $Script:TotalCycles = 0
        $Script:TotalIncrementalCycles = 0
        $Script:TotalErrorsSinceStart = 0
        $Script:LastCycleDiag = $null
        $Script:StatusReportLastWriteUtc = [DateTimeOffset]::MinValue
        $Script:StatusReportCoreHash = $null
        $Script:StatusAuditIssueHash = $null
        $Script:DryRun = $false
        $Script:PhaseLog = [Collections.Generic.List[string]]::new()
        Mock Write-AgentSyncLog { param($Level, $Message) $Script:PhaseLog.Add($Message) }
        Mock Get-AgentSyncProjects { @() }
        Mock Get-LocalAgentProjectAudit { @() }
        Mock Write-Utf8TextAtomic { param($Path, $Text) [IO.File]::WriteAllText($Path, $Text) }
    }

    It 'measures each real report stage without adding timings to the content hash' {
        Update-AgentSyncStatusReport
        $First = Get-Content -LiteralPath $Config.statusReport.jsonFile -Raw | ConvertFrom-Json
        Test-Path -LiteralPath $Config.statusReport.file | Should -BeTrue
        foreach ($Phase in @('discovery', 'project-scan', 'summarize', 'local-audit', 'publish')) {
            @($Script:PhaseLog | Where-Object { $_ -match "^STATUS_PHASE phase=$Phase durationMs=\d+" }).Count | Should -Be 1
        }
        $Script:PhaseLog[-2] | Should -Match 'outcome=written totalMs=\d+'
        $Script:PhaseLog.Clear()

        Update-AgentSyncStatusReport

        $Script:PhaseLog[-1] | Should -Match '^STATUS_PHASE phase=publish .*outcome=unchanged totalMs=\d+'
        $Second = Get-Content -LiteralPath $Config.statusReport.jsonFile -Raw | ConvertFrom-Json
        $Second.generatedUtc | Should -Be $First.generatedUtc
    }

    It 'replaces previous-run counters while keeping inventory age and rows untouched' {
        $Path = $Config.statusReport.jsonFile
        $Generated = [DateTimeOffset]::UtcNow.AddHours(-2).ToString('o')
        [IO.File]::WriteAllText($Path, (@{
            generatedUtc = $Generated
            projects = @(@{ ProjectPath = 'fixture-project' })
            diagnostics = @{ daemonPid = -1; cycles = 53; errorsSinceStart = 42 }
        } | ConvertTo-Json -Depth 6))

        Update-AgentSyncStatusDiagnostics -JsonReportFile $Path | Should -BeTrue

        $Status = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        ([DateTimeOffset]$Status.generatedUtc) | Should -Be ([DateTimeOffset]$Generated)
        $Status.projects[0].ProjectPath | Should -Be 'fixture-project'
        $Status.diagnostics.daemonPid | Should -Be $PID
        $Status.diagnostics.runState | Should -Be 'initializing'
        $Status.diagnostics.cycles | Should -Be 0
        $Status.diagnostics.errorsSinceStart | Should -Be 0
        $Status.diagnostics.lastCycle | Should -BeNullOrEmpty
        $Script:TotalCycles = 1
        (Get-AgentSyncDiagnosticsSnapshot).runState | Should -Be 'running'
    }

    It 'refreshes startup identity only after acquiring the singleton guard' {
        $Source = Get-Content -LiteralPath $EnginePath -Raw
        $Start = $Source.IndexOf('Write-AgentSyncLog -Level "INFO" -Message "START version=')
        $Refresh = $Source.IndexOf('[void](Update-AgentSyncStatusDiagnostics)', $Start)
        $Start | Should -BeGreaterThan $Source.IndexOf('if (-not $MutexAcquired)')
        $Refresh | Should -BeGreaterThan $Start
        $Refresh | Should -BeLessThan $Source.IndexOf('Invoke-AgentSyncCycle', $Start)
    }
}
