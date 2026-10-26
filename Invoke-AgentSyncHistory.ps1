<#
.SYNOPSIS
    Long-term history ("varig historikk") from the command line.

.DESCRIPTION
    Takes snapshots of AgentSync projects into one Git repository per project,
    kept outside the projects. Projects are only read. With no action switch
    the script prints the status of every project and changes nothing.

    -Initialize   First snapshot (the baseline). Can take minutes per project.
    -Snapshot     Snapshot projects that already have a baseline.
    -Sweep        Snapshot as many projects as the time budget allows, the one
                  that has waited longest first. This is what the daemon runs.
    -VerifyLedger Check that no ledger line was changed or removed.

    Design and limits: docs/VARIG-HISTORIKK.md

.EXAMPLE
    .\Invoke-AgentSyncHistory.ps1
    .\Invoke-AgentSyncHistory.ps1 -Initialize -Project 'C:\Projects\example'
    .\Invoke-AgentSyncHistory.ps1 -Initialize -All
    .\Invoke-AgentSyncHistory.ps1 -Snapshot -Project . -Trigger mission-end -MissionId mission-123 -Json
#>
[CmdletBinding()]
param (
    [switch]$Initialize,
    [switch]$Snapshot,
    [switch]$Sweep,
    [switch]$VerifyLedger,
    [string[]]$Project = @(),
    [switch]$All,
    [ValidateSet('manual', 'mission-start', 'mission-end', 'session-quiet', 'sweep', 'recovery')]
    [string]$Trigger = 'manual',
    [string]$MissionId = '',
    [string[]]$ObservedSession = @(),
    [ValidateRange(10, 1700)][int]$TimeBudgetSeconds = 0,
    [string]$ConfigFile = '',
    # Where project-index, logs and the default export folder live. Tests point
    # this at a fixture so the real toolkit is never read.
    [string]$ToolkitRoot = '',
    [switch]$DryRun,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AgentSync.Process.ps1')
. (Join-Path $PSScriptRoot 'AgentSync.History.ps1')

function Write-AgentSyncLog {
    param ([string]$Level, [string]$Message, [switch]$Console)

    # The daemon has its own log. Run by hand, the terminal is the log; run
    # with -Json, stdout belongs to the caller and only the file gets the line.
    $Stamp = [System.DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    try {
        if ($Script:HistoryLogFile) {
            [System.IO.File]::AppendAllText($Script:HistoryLogFile, "$Stamp $Level $Message`n")
        }
    }
    catch { }
    if (-not $Json) {
        Write-Host "$Level $Message"
    }
}

function Get-AgentSyncHistoryMachineId {
    # Same order as the engine, so both write to the same per-machine folders.
    foreach ($Candidate in $env:COMPUTERNAME, $env:HOSTNAME) {
        if ($Candidate) { return $Candidate }
    }
    try { $Name = [System.Net.Dns]::GetHostName(); if ($Name) { return $Name } } catch { }
    if ([System.Environment]::MachineName) { return [System.Environment]::MachineName }
    return 'unknown-host'
}

function Get-AgentSyncHistoryKnownProjects {
    param ([string]$ToolkitRoot, [string]$ProjectsBasePath)

    # The engine's own lists: the project index every machine writes, and the
    # status report, which also knows folders that fell out of the index.
    # Never a walk of the shared folder.
    $Paths = [System.Collections.Generic.List[string]]::new()
    $IndexDirectory = Join-Path $ToolkitRoot 'project-index'
    if (Test-Path -LiteralPath $IndexDirectory) {
        foreach ($File in (Get-ChildItem -LiteralPath $IndexDirectory -Filter '*.json' -File)) {
            try {
                $Index = Get-Content -LiteralPath $File.FullName -Raw | ConvertFrom-Json
                foreach ($Relative in @($Index.projects)) {
                    if ($Relative) { $Paths.Add((Join-Path $ProjectsBasePath ($Relative -replace '/', '\'))) }
                }
            }
            catch {
                Write-AgentSyncLog -Level 'WARN' -Message "HISTORY_INDEX_UNREADABLE $($File.Name): $($_.Exception.Message)"
            }
        }
    }
    $StatusFile = Join-Path $ToolkitRoot 'AgentSync-Status.json'
    if (Test-Path -LiteralPath $StatusFile) {
        try {
            $Report = Get-Content -LiteralPath $StatusFile -Raw | ConvertFrom-Json
            foreach ($Row in @($Report.projects)) {
                if ($Row.ProjectPath) { $Paths.Add([string]$Row.ProjectPath) }
            }
        }
        catch {
            Write-AgentSyncLog -Level 'WARN' -Message "HISTORY_STATUS_UNREADABLE $($_.Exception.Message)"
        }
    }
    return @($Paths | Sort-Object -Unique)
}

function Select-AgentSyncHistoryUnits {
    param ($Units, [string[]]$Paths)

    # A path names the unit it lies in: the project itself, or the repository
    # around it. A folder above several units names all of them.
    $Selected = [System.Collections.Generic.List[object]]::new()
    foreach ($Path in $Paths) {
        $Full = Get-AgentSyncHistoryNormalizedPath -Path (Resolve-Path -LiteralPath $Path).ProviderPath
        $Owner = $Units |
            Where-Object { $_.Path -eq $Full -or (Test-AgentSyncHistoryPathInside -Child $Full -Parent $_.Path) } |
            Sort-Object { $_.Path.Length } -Descending |
            Select-Object -First 1
        if ($Owner) { $Selected.Add($Owner) }
        foreach ($Below in ($Units | Where-Object { Test-AgentSyncHistoryPathInside -Child $_.Path -Parent $Full })) { $Selected.Add($Below) }
        if (-not $Owner -and -not ($Units | Where-Object { Test-AgentSyncHistoryPathInside -Child $_.Path -Parent $Full })) {
            throw "No AgentSync project at or around: $Path"
        }
    }
    return @($Selected | Sort-Object Id -Unique)
}

if (-not $ToolkitRoot) {
    $ToolkitRoot = $PSScriptRoot
}
if (-not $ConfigFile) {
    # Same rule as the engine: a local file replaces the shared one, it is not merged.
    $Local = Join-Path $ToolkitRoot 'config.local.json'
    $ConfigFile = if (Test-Path -LiteralPath $Local) { $Local } else { Join-Path $ToolkitRoot 'config.json' }
}
if (-not (Test-Path -LiteralPath $ConfigFile)) {
    Write-Error "Configuration not found: $ConfigFile"
    exit 1
}
$Config = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json
$BaseSetting = if ($Config.sharedProjectsDir) { $Config.sharedProjectsDir } else { $Config.dropboxProjectsDir }
$ProjectsBasePath = Expand-AgentSyncHistoryPath -Path $BaseSetting
if (-not $ProjectsBasePath -or -not (Test-Path -LiteralPath $ProjectsBasePath)) {
    Write-Error "The shared projects folder does not exist: $BaseSetting"
    exit 1
}

$MachineId = Get-AgentSyncHistoryMachineId
$Settings = Get-AgentSyncHistorySettings -Config $Config -ToolkitRoot $ToolkitRoot -MachineId $MachineId
if ($TimeBudgetSeconds -gt 0) { $Settings.TimeBudgetSeconds = $TimeBudgetSeconds }
$LogDirectory = Join-Path $ToolkitRoot 'logs'
if (Test-Path -LiteralPath $LogDirectory) {
    $Script:HistoryLogFile = Join-Path $LogDirectory "history-$MachineId.log"
}

$Known = Get-AgentSyncHistoryKnownProjects -ToolkitRoot $ToolkitRoot -ProjectsBasePath $ProjectsBasePath
$ExplicitPaths = @($Project | ForEach-Object { (Resolve-Path -LiteralPath $_).ProviderPath })
$Units = Get-AgentSyncHistoryUnits -ProjectPaths (@($Known) + $ExplicitPaths) -ProjectsBasePath $ProjectsBasePath -Settings $Settings
$Chosen = if ($Project.Count -gt 0) { Select-AgentSyncHistoryUnits -Units $Units -Paths $Project } else { $Units }

$Output = [ordered]@{ machine = $MachineId; store = $Settings.StoreDirectory; export = $Settings.ExportDirectory; action = 'status'; results = @() }
$ExitCode = 0

if ($VerifyLedger) {
    $Output.action = 'verify-ledger'
    $Check = Test-AgentSyncHistoryLedger -Settings $Settings
    $Output.results = @($Check)
    if (-not $Json) {
        if ($Check.Ok) { Write-Host "Ledger intact: $($Check.Lines) lines." }
        else { $Check.Broken | ForEach-Object { Write-Host "BROKEN $($_.file):$($_.line) $($_.reason)" } }
    }
    if (-not $Check.Ok) { $ExitCode = 3 }
}
elseif ($Initialize -or $Snapshot) {
    if ($Project.Count -eq 0 -and -not $All) {
        Write-Error 'Name the projects with -Project, or pass -All.'
        exit 1
    }
    $Output.action = if ($Initialize) { 'initialize' } else { 'snapshot' }
    $UseTrigger = if ($Initialize -and $Trigger -eq 'manual') { 'baseline' } else { $Trigger }
    $Number = 0
    $Results = foreach ($Unit in $Chosen) {
        $Number++
        if (-not $Json) { Write-Host ("[{0}/{1}] {2}" -f $Number, @($Chosen).Count, $Unit.RelativePath) }
        $UnitResults = Invoke-AgentSyncHistoryUnitSnapshot -Unit $Unit -Settings $Settings -Trigger $UseTrigger -MissionId $MissionId -ObservedSessions $ObservedSession -AllowBaseline:$Initialize -DryRun:$DryRun
        foreach ($Result in $UnitResults) {
            if (-not $Json) {
                $Detail = if ($Result.Outcome -eq 'committed') { "+$($Result.Added) ~$($Result.Modified) -$($Result.Deleted), $($Result.Completeness)" } else { $Result.Reason }
                Write-Host ("        {0,-14} {1,-11} {2,6} s  {3}" -f $Result.Line, $Result.Outcome, $Result.Seconds, $Detail)
            }
            $Result
        }
    }
    $Output.results = @($Results)
    if ($Results | Where-Object { $_.Outcome -eq 'failed' }) { $ExitCode = 3 }
}
elseif ($Sweep) {
    $Output.action = 'sweep'
    $SweepMutexName = Get-AgentSyncHistoryMutexName -Kind Sweep -Path $Settings.StoreDirectory
    $SweepMutex = [System.Threading.Mutex]::new($false, $SweepMutexName)
    $Held = $false
    try {
        try { $Held = $SweepMutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $Held = $true }
        if (-not $Held) {
            if (-not $Json) { Write-Host 'A sweep is already running.' }
            exit 2
        }
        $Timer = [System.Diagnostics.Stopwatch]::StartNew()
        # Longest-waiting first, so a short budget still reaches every project in turn.
        $Order = $Chosen | Sort-Object {
            $Marker = Join-Path $_.RepositoryPath 'agentsync\last-sweep-utc.txt'
            if (Test-Path -LiteralPath $Marker) { (Get-Item -LiteralPath $Marker).LastWriteTimeUtc } else { [System.DateTime]::MinValue }
        }
        $Counts = [ordered]@{ committed = 0; unchanged = 0; partial = 0; failed = 0; busy = 0; noBaseline = 0; notReached = 0 }
        $Results = foreach ($Unit in $Order) {
            if ($Timer.Elapsed.TotalSeconds -ge $Settings.TimeBudgetSeconds) { $Counts.notReached++; continue }
            $UnitResults = Invoke-AgentSyncHistoryUnitSnapshot -Unit $Unit -Settings $Settings -Trigger 'sweep' -DryRun:$DryRun
            foreach ($Result in $UnitResults) {
                switch ($Result.Outcome) {
                    'committed' { $Counts.committed++ }
                    'unchanged' { $Counts.unchanged++ }
                    'busy' { $Counts.busy++ }
                    'no-baseline' { $Counts.noBaseline++ }
                    'failed' { $Counts.failed++ }
                }
                if ($Result.Completeness -eq 'partial') { $Counts.partial++ }
                $Result
            }
            $Marker = Join-Path $Unit.RepositoryPath 'agentsync\last-sweep-utc.txt'
            if (-not $DryRun -and (Test-Path -LiteralPath (Split-Path -Parent $Marker))) {
                Write-AgentSyncHistoryText -Path $Marker -Text ([System.DateTime]::UtcNow.ToString('o') + "`n")
            }
        }
        $Output.results = @($Results | Where-Object { $_.Outcome -notin @('unchanged', 'no-baseline') })
        $Output['counts'] = $Counts
        if (-not $DryRun) {
            $Entry = [ordered]@{ event = 'sweep'; units = @($Order).Count; seconds = [math]::Round($Timer.Elapsed.TotalSeconds, 1) }
            foreach ($Key in $Counts.Keys) { $Entry[$Key] = $Counts[$Key] }
            [void](Add-AgentSyncHistoryLedgerEntry -Settings $Settings -Entry $Entry)
        }
        if (-not $Json) {
            Write-Host ("Sweep: {0} projects in {1:N0} s - {2} new snapshots, {3} unchanged, {4} partial, {5} failed, {6} without baseline, {7} not reached." -f @($Order).Count, $Timer.Elapsed.TotalSeconds, $Counts.committed, $Counts.unchanged, $Counts.partial, $Counts.failed, $Counts.noBaseline, $Counts.notReached)
        }
        if ($Counts.failed -gt 0) { $ExitCode = 3 }
    }
    finally {
        if ($Held) { $SweepMutex.ReleaseMutex() }
        $SweepMutex.Dispose()
    }
}
else {
    $Rows = foreach ($Unit in $Chosen) { Get-AgentSyncHistoryUnitStatus -Unit $Unit }
    $Output.results = @($Rows)
    if (-not $Json) {
        Write-Host "History store : $($Settings.StoreDirectory)"
        Write-Host "Export folder : $($Settings.ExportDirectory)"
        Write-Host "Automatic     : $(if ($Settings.Enabled) { 'on' } else { 'off (history.enabled is false)' })"
        Write-Host ''
        foreach ($Row in $Rows) {
            $Newest = @($Row.Lines | Sort-Object LastSnapshot -Descending | Select-Object -First 1).LastSnapshot
            $State = if ($Row.Baseline) { "last snapshot $Newest" } elseif ($Row.Lines.Count -gt 0) { "missing: $($Row.MissingLines -join ', ')" } else { 'no baseline' }
            Write-Host ("{0,-7} {1,-70} {2}" -f $Row.Kind, $Row.RelativePath, $State)
        }
        $Without = @($Rows | Where-Object { -not $_.Baseline }).Count
        Write-Host ''
        Write-Host "$(@($Rows).Count) projects, $Without without a complete baseline."
    }
}

if ($Json) {
    [pscustomobject]$Output | ConvertTo-Json -Depth 8 -Compress
}
exit $ExitCode
