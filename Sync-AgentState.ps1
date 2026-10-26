<#
.SYNOPSIS
    Project-routed synchronization of agent history inside a shared root.

.DESCRIPTION
    Routes each session to the exact project it belongs to, based on cwd or
    workspace metadata. sharedProjectsDir is a synchronization boundary; both
    parent folders and nested folders can be independent agent projects.
#>

#requires -Version 7.0

param (
    [string]$ConfigFile = (Join-Path $PSScriptRoot "config.json"),
    [switch]$Once,
    [switch]$DryRun,
    [switch]$StatusOnly
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot 'AgentSync.Process.ps1')

$AgentSyncVersion = "4.25.1"

# A dry run always implies a single cycle.
if ($DryRun) { $Once = $true }
if ($StatusOnly) { $Once = $true }
$Script:DryRun = [bool]$DryRun

$Script:SessionCwdCache = @{}
$Script:HeartbeatSeen = @{}
$Script:TouchedProjects = @{}
$Script:WatchAgentByPath = @{}
$Script:CycleErrorCount = 0
$Script:CycleDeferredCopies = 0
$Script:CycleContentConflicts = 0
$Script:CycleNewContentConflicts = 0
$Script:SilentFailures = @{}
$Script:ScopeEscalationWarned = @{}
$Script:DaemonStartedUtc = [System.DateTimeOffset]::UtcNow
$Script:LastCycleDiag = $null
$Script:TotalCycles = 0
$Script:TotalIncrementalCycles = 0
$Script:TotalErrorsSinceStart = 0
$Script:WalDeferralLoggedUtc = @{}
$Script:SelfWrittenPaths = @{}
$Script:UnsafeIdWarned = @{}
$Script:UnreadableWarned = @{}
$Script:RestoreSkipLogged = @{}
$Script:GuidanceSourceWarned = @{}
$Script:GuidanceKeptLogged = @{}
$Script:StatusReportCoreHash = $null
$Script:StatusReportLastWriteUtc = [System.DateTimeOffset]::MinValue
$Script:StatusAuditIssueHash = $null
$Script:IntelligenceReportLastRunUtc = [System.DateTimeOffset]::MinValue
$Script:ClaudeWorkspaceMapCache = @{}
$Script:LocalAgentAuditCache = $null
$Script:KnownProjectRoots = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$Script:LocalProjectRoots = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$Script:ProjectIndexLastReadUtc = [System.DateTimeOffset]::MinValue
$Script:ProjectIndexDirty = $false
$Script:OpenCodeSessionListCache = $null
$Script:OpenCodeDiscoveryCache = $null
$Script:ForceOpenCodeDiscovery = $false
$Script:ToolkitRoot = $PSScriptRoot
$Script:WatcherSequence = 0
$Script:WatchEventLogTimes = @{}
$Script:OpenCodeUnavailableWarned = $false
$Script:OpenCodeRemoteNewerWarned = @{}
$Script:StatusModelCache = @{}
$Script:ActiveMemoryCompanionAllowed = $false
$Script:ActiveMemoryWorkerProcess = $null
$Script:ActiveMemoryWorkerLastAttempt = [System.DateTimeOffset]::MinValue

# A machine-specific config.local.json can override the distributed config
# without having to edit the shared config.json per machine.
if (-not $PSBoundParameters.ContainsKey('ConfigFile')) {
    $LocalConfigFile = Join-Path $PSScriptRoot "config.local.json"
    if (Test-Path -LiteralPath $LocalConfigFile) {
        $ConfigFile = $LocalConfigFile
    }
}

if (-not (Test-Path -LiteralPath $ConfigFile)) {
    Write-Error "Configuration file not found: $ConfigFile"
    exit 1
}

try {
    $Config = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json
}
catch {
    Write-Error "Could not read config.json: $($_.Exception.Message)"
    exit 1
}

$ProjectsDirSetting = [string]$Config.sharedProjectsDir
if ([string]::IsNullOrWhiteSpace($ProjectsDirSetting)) {
    $ProjectsDirSetting = [string]$Config.dropboxProjectsDir
}

if ([string]::IsNullOrWhiteSpace($ProjectsDirSetting)) {
    Write-Error "Missing sharedProjectsDir in config.json."
    exit 1
}

# Stable machine ID on Windows, macOS and Linux
$MachineId = $env:COMPUTERNAME
if ([string]::IsNullOrWhiteSpace($MachineId)) {
    $MachineId = $env:HOSTNAME
}
if ([string]::IsNullOrWhiteSpace($MachineId)) {
    try {
        $MachineId = [System.Net.Dns]::GetHostName()
    }
    catch {
        $MachineId = [System.Environment]::MachineName
    }
}
if ([string]::IsNullOrWhiteSpace($MachineId)) {
    $MachineId = "unknown-host"
}

$PlatformName = "unknown"
if ($IsWindows -or $env:OS -eq "Windows_NT") {
    $PlatformName = "windows"
}
elseif ($IsMacOS) {
    $PlatformName = "macos"
}
elseif ($IsLinux) {
    $PlatformName = "linux"
}
# Fallback when the automatic variables are missing (older pwsh)
elseif ($env:OSTYPE -match "darwin") {
    $PlatformName = "macos"
}
elseif ($env:OSTYPE -match "linux") {
    $PlatformName = "linux"
}

$PathComparison = [System.StringComparison]::OrdinalIgnoreCase
if ($PlatformName -eq "linux") {
    $PathComparison = [System.StringComparison]::Ordinal
}

$MetadataReadLines = 100
if ($Config.metadataReadLines) {
    $MetadataReadLines = [int]$Config.metadataReadLines
}

# Per-machine log file. With the tool folder in Dropbox, a shared log would
# produce conflict copies and rotation races between machines.
$LogDirectory = Join-Path $PSScriptRoot "logs"
$LogPath = Join-Path $LogDirectory "agentsync-$MachineId.log"
$MaxLogBytes = 5MB
$MaxLogFiles = 5
if ($Config.logging) {
    if ($Config.logging.directory) {
        $LogDirectory = [string]$Config.logging.directory
        if (-not [System.IO.Path]::IsPathRooted($LogDirectory)) {
            $LogDirectory = Join-Path $PSScriptRoot $LogDirectory
        }
        $LogPath = Join-Path $LogDirectory "agentsync-$MachineId.log"
    }
    if ($Config.logging.maxBytes) { $MaxLogBytes = [long]$Config.logging.maxBytes }
    if ($Config.logging.maxFiles) { $MaxLogFiles = [int]$Config.logging.maxFiles }
}

function Expand-PortablePath {
    param ([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    $Expanded = [string]$Path
    if ($Expanded -eq "~") {
        $Expanded = $HOME
    }
    elseif ($Expanded.StartsWith("~/") -or $Expanded.StartsWith("~\")) {
        $Expanded = Join-Path $HOME $Expanded.Substring(2)
    }
    $Expanded = $Expanded.Replace('${HOME}', $HOME)
    # Word boundary so that e.g. $HOMEBREW is not mangled.
    $Expanded = [regex]::Replace($Expanded, '\$HOME(?![A-Za-z0-9_])', $HOME.Replace('$', '$$'))
    if ($env:USERPROFILE) {
        $Expanded = $Expanded.Replace('%USERPROFILE%', $env:USERPROFILE)
    }
    $Expanded = [System.Environment]::ExpandEnvironmentVariables($Expanded)
    return [System.IO.Path]::GetFullPath($Expanded).TrimEnd('\', '/')
}

$ProjectsBasePath = Expand-PortablePath -Path $ProjectsDirSetting

if (-not (Test-Path -LiteralPath $ProjectsBasePath)) {
    Write-Error "Shared projects folder not found: $ProjectsBasePath"
    exit 1
}

function Expand-ConfiguredPath {
    param ([string]$Path)
    return Expand-PortablePath -Path $Path
}

function Get-PlatformConfiguredPath {
    param ($Object)

    $Candidate = $null
    switch ($PlatformName) {
        "windows" { if ($Object.localPathWindows) { $Candidate = [string]$Object.localPathWindows } }
        "macos"   { if ($Object.localPathMacOS)   { $Candidate = [string]$Object.localPathMacOS } }
        "linux"   { if ($Object.localPathLinux)   { $Candidate = [string]$Object.localPathLinux } }
    }

    if ([string]::IsNullOrWhiteSpace($Candidate) -and $Object.localPath) {
        $Candidate = [string]$Object.localPath
    }

    if ([string]::IsNullOrWhiteSpace($Candidate)) {
        return $null
    }

    return Expand-ConfiguredPath -Path $Candidate
}

function Get-AgentFileFilters {
    param ($Agent)

    $Filters = @()
    if ($Agent.fileFilters) {
        $Filters = @($Agent.fileFilters | ForEach-Object { [string]$_ })
    }
    elseif ($Agent.fileFilter) {
        $Filters = @([string]$Agent.fileFilter)
    }

    if ($Filters.Count -eq 0) {
        $Filters = @("*")
    }

    return $Filters
}

function Test-RelativePathMatchesFilter {
    param (
        [string]$RelativePath,
        [string[]]$Filters
    )

    $Normalized = $RelativePath.Replace('\', '/')
    foreach ($Filter in $Filters) {
        if ($Normalized -like $Filter) {
            return $true
        }
        # Simple name filters like *.jsonl match regardless of subdirectory.
        if ($Filter.IndexOf('/') -lt 0 -and ([System.IO.Path]::GetFileName($Normalized) -like $Filter)) {
            return $true
        }
    }

    return $false
}


function Rotate-LogIfNeeded {
    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath $LogPath)) {
        return
    }

    try {
        $Length = (Get-Item -LiteralPath $LogPath).Length
        if ($Length -lt $MaxLogBytes) {
            return
        }

        for ($Index = $MaxLogFiles - 1; $Index -ge 1; $Index--) {
            $From = "$LogPath.$Index"
            $To = "$LogPath.$($Index + 1)"
            if (Test-Path -LiteralPath $From) {
                Move-Item -LiteralPath $From -Destination $To -Force
            }
        }

        Move-Item -LiteralPath $LogPath -Destination "$LogPath.1" -Force
    }
    catch {
    }
}

function Write-AgentSyncLog {
    param (
        [ValidateSet("DEBUG", "INFO", "WARN", "ERROR")]
        [string]$Level,
        [string]$Message,
        [switch]$Console
    )

    Rotate-LogIfNeeded
    $Timestamp = [System.DateTimeOffset]::Now.ToString("yyyy-MM-dd HH:mm:ss.fff zzz")
    $Line = "$Timestamp $Level [$MachineId/$PlatformName] $Message"

    try {
        Add-Content -LiteralPath $LogPath -Value $Line -Encoding UTF8
    }
    catch {
    }

    if ($Console) {
        switch ($Level) {
            "ERROR" { Write-Host $Message -ForegroundColor Red }
            "WARN"  { Write-Host $Message -ForegroundColor Yellow }
            default { Write-Host $Message }
        }
    }
}

function Get-AgentSyncWatcherPathKey {
    param ([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    $Key = [string]$Path
    if ($Key.StartsWith('\\?\')) {
        $Key = $Key.Substring(4)
    }
    try {
        $Key = [System.IO.Path]::GetFullPath($Key)
    }
    catch {
    }
    $Key = $Key.TrimEnd('\', '/')
    if ($PlatformName -eq 'windows') {
        $Key = $Key.ToLowerInvariant()
    }
    return $Key
}

function Test-AgentSyncRecentTimestamp {
    param (
        [System.DateTimeOffset]$Since,
        [double]$WindowSeconds,
        [System.DateTimeOffset]$Now = [System.DateTimeOffset]::UtcNow
    )

    # Wall-clock corrections must expire local caches/throttles, not make a
    # future timestamp suppress discovery or retries for hours. This helper
    # is not used for multi-machine ownership or source-integrity decisions.
    $AgeSeconds = ($Now - $Since).TotalSeconds
    return ($AgeSeconds -ge 0 -and $AgeSeconds -lt $WindowSeconds)
}

function Get-AgentSyncMonotonicMilliseconds {
    return ([System.Diagnostics.Stopwatch]::GetTimestamp() * 1000.0 / [System.Diagnostics.Stopwatch]::Frequency)
}

function Get-AgentSyncWatcherReadiness {
    param (
        [Nullable[double]]$DirtySinceMs,
        [Nullable[double]]$DirtyFirstMs,
        [double]$LastFullScanMs,
        [double]$DebounceMs,
        [double]$MaxDirtyWaitSeconds,
        [double]$SafetyScanSeconds,
        [double]$NowMs = (Get-AgentSyncMonotonicMilliseconds)
    )

    # Only in-process monotonic timestamps belong here. UTC is still used in
    # logs, but changing the system clock cannot postpone or accelerate work.
    return [PSCustomObject]@{
        DebounceReady = ($null -ne $DirtySinceMs -and ($NowMs - $DirtySinceMs) -ge $DebounceMs)
        MaxWaitReady = ($null -ne $DirtyFirstMs -and ($NowMs - $DirtyFirstMs) -ge ($MaxDirtyWaitSeconds * 1000))
        SafetyScanReady = (($NowMs - $LastFullScanMs) -ge ($SafetyScanSeconds * 1000))
    }
}

function Register-AgentSyncSelfWrite {
    param ([string]$Path)

    $Key = Get-AgentSyncWatcherPathKey -Path $Path
    if ([string]::IsNullOrWhiteSpace($Key)) {
        return
    }

    # FileSystemWatcher events are handled after the current sync cycle. Keep
    # a short-lived record so our own copies do not schedule another full run.
    $Script:SelfWrittenPaths[$Key] = [System.DateTimeOffset]::UtcNow
    if ($Script:SelfWrittenPaths.Count -gt 10000) {
        $Now = [System.DateTimeOffset]::UtcNow
        foreach ($StoredKey in @($Script:SelfWrittenPaths.Keys)) {
            if (-not (Test-AgentSyncRecentTimestamp -Since $Script:SelfWrittenPaths[$StoredKey] -WindowSeconds 300 -Now $Now)) {
                $Script:SelfWrittenPaths.Remove($StoredKey)
            }
        }
    }
}

function Test-AgentSyncOwnMissionPath {
    param ([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Script:ToolkitRoot)) { return $false }
    $Root = Join-Path $Script:ToolkitRoot 'missions'
    return Test-PathInside -ChildPath $Path -ParentPath $Root
}

function Write-AgentSyncError {
    param (
        [string]$Context,
        $ErrorRecord,
        [ValidateSet("WARN", "ERROR")]
        [string]$Level = "ERROR",
        [switch]$Console
    )

    # One standardized line with everything a debugging session needs:
    # exception type, message, script position and flattened stack. The bare
    # Exception.Message alone has repeatedly forced manual hunts for the
    # failing line.
    $Exception = $ErrorRecord.Exception
    $TypeName = if ($Exception) { $Exception.GetType().Name } else { "UnknownException" }
    $Message = if ($Exception) { $Exception.Message } else { [string]$ErrorRecord }

    $Position = ""
    try {
        if ($ErrorRecord.InvocationInfo -and $ErrorRecord.InvocationInfo.ScriptLineNumber) {
            $Position = " at line $($ErrorRecord.InvocationInfo.ScriptLineNumber)"
        }
    }
    catch {
    }

    $StackFlat = ""
    try {
        if ($ErrorRecord.ScriptStackTrace) {
            $StackFlat = " | " + ([string]$ErrorRecord.ScriptStackTrace -replace "\r?\n", " <- ")
        }
    }
    catch {
    }

    $Line = "$($Context): $($TypeName): $Message$Position$StackFlat"
    Write-AgentSyncLog -Level $Level -Message $Line -Console:$Console
    $Script:CycleErrorCount++
    $Script:TotalErrorsSinceStart++

    # Errors also go to a long-lived journal so they survive the main log's
    # rotation - the raw material for improving AgentSync over time.
    try {
        $ErrorLogPath = Join-Path $LogDirectory "errors-$MachineId.log"
        if ((Test-Path -LiteralPath $ErrorLogPath) -and (Get-Item -LiteralPath $ErrorLogPath).Length -gt 10MB) {
            Move-Item -LiteralPath $ErrorLogPath -Destination "$ErrorLogPath.1" -Force
        }
        $Timestamp = [System.DateTimeOffset]::Now.ToString("yyyy-MM-dd HH:mm:ss.fff zzz")
        Add-Content -LiteralPath $ErrorLogPath -Value "$Timestamp $Level [$MachineId/$PlatformName] $Line" -Encoding UTF8
    }
    catch {
    }
}

function Add-AgentSyncSilentFailure {
    param ([string]$Category)

    # Deliberately quiet per-item failures (one corrupt line among thousands)
    # stay quiet individually, but are counted so a systematic problem becomes
    # visible in the CYCLE summary instead of vanishing into empty catches.
    $Script:SilentFailures[$Category] = 1 + [int]$Script:SilentFailures[$Category]
}

function Write-Utf8TextAtomic {
    param (
        [string]$Path,
        [string]$Text
    )

    if ($Script:DryRun) {
        Write-AgentSyncLog -Level "DEBUG" -Message "DRYRUN write skipped: $Path"
        return
    }

    $DestDir = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $DestDir)) {
        New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
    }

    $Encoding = New-Object System.Text.UTF8Encoding($false)
    $TempPath = "$Path.agentsync-$MachineId-$PID.tmp"

    try {
        [System.IO.File]::WriteAllText($TempPath, $Text, $Encoding)
        Move-Item -LiteralPath $TempPath -Destination $Path -Force
        Register-AgentSyncSelfWrite -Path $Path
    }
    finally {
        if (Test-Path -LiteralPath $TempPath) {
            Remove-Item -LiteralPath $TempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function New-SharedStreamReader {
    param ([string]$Path)

    # FileShare.ReadWrite is required, not cosmetic: a plain
    # StreamReader($Path) requests FileShare.Read and therefore throws on any
    # file the agent currently holds open for writing. That is exactly the
    # live session - the one whose history is most worth protecting.
    $Stream = New-Object System.IO.FileStream(
        $Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite)

    return (New-Object System.IO.StreamReader($Stream))
}

function Test-IsConflictCopyName {
    param ([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    return (
        $Name -match '(?i)conflicted copy' -or
        $Name -match '(?i)sync-conflict' -or
        $Name -match '(?i)conflict copy'
    )
}

function Quarantine-ConflictCopies {
    $Projects = Get-AgentSyncStateFolders

    foreach ($Project in $Projects) {
        $StateRoot = Join-Path $Project.FullName ".agent-state"
        if (-not (Test-Path -LiteralPath $StateRoot)) {
            continue
        }

        $ConflictRoot = Join-Path $StateRoot "conflicts"
        $Files = Get-ChildItem -LiteralPath $StateRoot -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object {
                -not (Test-PathInside -ChildPath $_.FullName -ParentPath $ConflictRoot) -and
                (Test-IsConflictCopyName -Name $_.Name)
            }

        foreach ($File in $Files) {
            $Relative = Get-RelativeChildPath -BasePath $StateRoot -FullPath $File.FullName
            if ($null -eq $Relative) {
                continue
            }

            $Stamp = [System.DateTimeOffset]::Now.ToString("yyyyMMdd-HHmmssfff")
            $Destination = Join-Path $ConflictRoot (Join-Path $Stamp $Relative)

            if ($Script:DryRun) {
                Write-AgentSyncLog -Level "WARN" -Message "DRYRUN CONFLICT_QUARANTINE project=$($Project.Name) source=$($File.FullName)" -Console
                continue
            }

            $DestinationDir = Split-Path -Path $Destination -Parent
            New-Item -ItemType Directory -Path $DestinationDir -Force | Out-Null

            try {
                Move-Item -LiteralPath $File.FullName -Destination $Destination -Force
                Write-AgentSyncLog -Level "WARN" -Message "CONFLICT_QUARANTINE project=$($Project.Name) source=$($File.FullName) destination=$Destination" -Console
            }
            catch {
                Write-AgentSyncLog -Level "ERROR" -Message "Could not quarantine conflict file $($File.FullName): $($_.Exception.Message)" -Console
            }
        }
    }
}

function Get-SessionIdFromDisplayPath {
    param ([string]$DisplayPath)

    if ([string]::IsNullOrWhiteSpace($DisplayPath)) {
        return "unknown"
    }

    # Memory files are not sessions. Group them under a shared activity key
    # instead of one "session" per file.
    if ($DisplayPath -match '[\\/]memory[\\/][^\\/]+\.md$') {
        return "memory"
    }

    $Parts = $DisplayPath -split '[\\/]'
    foreach ($Part in $Parts) {
        if ($Part -match '^[0-9a-fA-F-]{16,}$') {
            return $Part
        }
        if ($Part -match '\.jsonl$') {
            return [System.IO.Path]::GetFileNameWithoutExtension($Part)
        }
        if ($Part -match '^ses_[A-Za-z0-9._-]+\.json$') {
            return [System.IO.Path]::GetFileNameWithoutExtension($Part)
        }
    }

    return (($Parts | Select-Object -Last 1) -replace '[^A-Za-z0-9._-]', '_')
}

function Write-ActivityHeartbeat {
    param (
        [string]$ProjectRoot,
        [string]$AgentName,
        [string]$SessionId,
        [string]$Direction
    )

    if ([string]::IsNullOrWhiteSpace($ProjectRoot) -or $Script:DryRun) {
        return
    }

    $SafeSession = $SessionId -replace '[^A-Za-z0-9._-]', '_'

    # At most one heartbeat per project/agent/session/direction per cycle. On
    # the first sync of a large history this saves thousands of writes.
    $ThrottleKey = "$ProjectRoot|$AgentName|$SafeSession|$Direction"
    if ($Script:HeartbeatSeen.ContainsKey($ThrottleKey)) {
        return
    }
    $Script:HeartbeatSeen[$ThrottleKey] = $true

    $ActivityRoot = Join-Path (Join-Path (Join-Path (Join-Path $ProjectRoot ".agent-state") "activity") $AgentName) $SafeSession

    $HeartbeatPath = Join-Path $ActivityRoot "$MachineId.json"
    $Payload = [ordered]@{
        machine = $MachineId
        platform = $PlatformName
        agent = $AgentName
        session = $SessionId
        direction = $Direction
        lastSeenUtc = [System.DateTimeOffset]::UtcNow.ToString("o")
        processId = $PID
    }

    try {
        Write-Utf8TextAtomic -Path $HeartbeatPath -Text ($Payload | ConvertTo-Json -Depth 5)
    }
    catch {
        Write-AgentSyncLog -Level "WARN" -Message "Could not write heartbeat: $($_.Exception.Message)"
        return
    }

    # Only local agent writes count as activity. Receiving (project-to-local)
    # caused false parallel warnings in v3.2.3: a passive machine that merely
    # received changes looked like it was working in parallel.
    if ($Direction -ne "local-to-project") {
        return
    }

    $WindowSeconds = 120
    if ($Config.activity -and $Config.activity.parallelWarningSeconds) {
        $WindowSeconds = [int]$Config.activity.parallelWarningSeconds
    }

    $Now = [System.DateTimeOffset]::UtcNow
    $Others = Get-ChildItem -LiteralPath $ActivityRoot -File -Filter "*.json" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne "$MachineId.json" }

    foreach ($Other in $Others) {
        try {
            $OtherState = Get-Content -LiteralPath $Other.FullName -Raw | ConvertFrom-Json
            if ([string]$OtherState.direction -ne "local-to-project") {
                continue
            }
            # ConvertFrom-Json in pwsh turns ISO strings into [datetime].
            # Handle both types, and never via culture-dependent string parsing.
            $RawSeen = $OtherState.lastSeenUtc
            if ($RawSeen -is [datetime]) {
                $OtherSeen = [System.DateTimeOffset]$RawSeen
            }
            else {
                $OtherSeen = [System.DateTimeOffset]::Parse([string]$RawSeen, [System.Globalization.CultureInfo]::InvariantCulture)
            }
            if (($Now - $OtherSeen).TotalSeconds -le $WindowSeconds) {
                Write-AgentSyncLog -Level "WARN" -Message "PARALLEL_ACTIVITY project=$(Split-Path $ProjectRoot -Leaf) agent=$AgentName session=$SessionId local=$MachineId other=$($OtherState.machine)" -Console
            }
        }
        catch {
            Add-AgentSyncSilentFailure -Category 'heartbeat-parse'
        }
    }
}

function Update-ProjectManifest {
    param ([string]$ProjectRoot)

    $StateRoot = Join-Path $ProjectRoot ".agent-state"
    if (-not (Test-Path -LiteralPath $StateRoot)) {
        return
    }

    $Agents = [ordered]@{}
    foreach ($Name in @("claude", "codex", "antigravity", "opencode", "cline", "aider", "junie")) {
        $AgentRoot = Join-Path $StateRoot $Name
        if (-not (Test-Path -LiteralPath $AgentRoot)) {
            continue
        }

        $Files = @(Get-ChildItem -LiteralPath $AgentRoot -Recurse -File -ErrorAction Stop)
        $Agents[$Name] = [ordered]@{
            files = $Files.Count
            bytes = [long](($Files | Measure-Object -Property Length -Sum).Sum)
            newestUtc = if ($Files.Count -gt 0) { ($Files | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).LastWriteTimeUtc.ToString("o") } else { $null }
        }
    }

    $Machines = [ordered]@{}
    $MachineSeen = @{}
    $ActivityRoot = Join-Path $StateRoot "activity"
    if (Test-Path -LiteralPath $ActivityRoot) {
        $Heartbeats = Get-ChildItem -LiteralPath $ActivityRoot -Recurse -File -Filter "*.json" -ErrorAction Stop
        foreach ($Heartbeat in $Heartbeats) {
            try {
                $State = Get-Content -LiteralPath $Heartbeat.FullName -Raw | ConvertFrom-Json
                $Key = [string]$State.machine
                if ([string]::IsNullOrWhiteSpace($Key)) {
                    continue
                }

                # ConvertFrom-Json in pwsh turns ISO strings into [datetime].
                # Compare as points in time, not culture-dependent strings.
                $RawSeen = $State.lastSeenUtc
                if ($RawSeen -is [datetime]) {
                    $SeenUtc = ([System.DateTimeOffset]$RawSeen).ToUniversalTime()
                }
                else {
                    $SeenUtc = [System.DateTimeOffset]::Parse([string]$RawSeen, [System.Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()
                }

                if (-not $Machines.Contains($Key) -or $SeenUtc -gt $MachineSeen[$Key]) {
                    $MachineSeen[$Key] = $SeenUtc
                    $Machines[$Key] = [ordered]@{
                        platform = [string]$State.platform
                        lastSeenUtc = $SeenUtc.ToString("o")
                    }
                }
            }
            catch {
                Add-AgentSyncSilentFailure -Category 'manifest-heartbeat-parse'
            }
        }
    }

    $CoreManifest = [ordered]@{
        format = 1
        agentSyncVersion = $AgentSyncVersion
        project = Split-Path $ProjectRoot -Leaf
        agents = $Agents
        machines = $Machines
    }

    $ManifestPath = Join-Path $StateRoot "manifest.json"
    $CoreJson = $CoreManifest | ConvertTo-Json -Depth 10 -Compress

    # Change detection via a stored hash of the core content. A JSON round trip
    # (read, parse, re-serialize) is not stable enough because pwsh
    # auto-converts date strings to [datetime] while parsing.
    $Sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $CoreHash = ([System.BitConverter]::ToString($Sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($CoreJson)))).Replace("-", "")
    }
    finally {
        $Sha.Dispose()
    }

    $NeedsWrite = $true
    if (Test-Path -LiteralPath $ManifestPath) {
        try {
            $Existing = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
            $NeedsWrite = ([string]$Existing.coreHash -ne $CoreHash)
        }
        catch {
            $NeedsWrite = $true
        }
    }

    if (-not $NeedsWrite) {
        return
    }

    $Manifest = [ordered]@{
        format = $CoreManifest.format
        agentSyncVersion = $CoreManifest.agentSyncVersion
        project = $CoreManifest.project
        coreHash = $CoreHash
        updatedUtc = [System.DateTimeOffset]::UtcNow.ToString("o")
        agents = $CoreManifest.agents
        machines = $CoreManifest.machines
    }

    try {
        Write-Utf8TextAtomic -Path $ManifestPath -Text ($Manifest | ConvertTo-Json -Depth 10)
    }
    catch {
        Write-AgentSyncError -Context 'Manifest publication' -ErrorRecord $_ -Console
    }
}

function Update-AllProjectManifests {
    param ([System.Collections.IDictionary]$ProjectDurations)
    $Projects = Get-AgentSyncProjects
    foreach ($Project in $Projects) {
        $Timer = [Diagnostics.Stopwatch]::StartNew()
        try { Update-ProjectManifest -ProjectRoot $Project.FullName }
        catch { Write-AgentSyncError -Context 'Project manifest update' -ErrorRecord $_ -Console }
        finally {
            $Timer.Stop()
            if ($null -ne $ProjectDurations) { $ProjectDurations[$Project.FullName] = $Timer.ElapsedMilliseconds }
        }
    }
}

function Invoke-ActivityPrune {
    $PruneAfterDays = 14
    if ($Config.activity -and $null -ne $Config.activity.pruneAfterDays) {
        $PruneAfterDays = [int]$Config.activity.pruneAfterDays
    }
    if ($PruneAfterDays -le 0) {
        return
    }

    $Cutoff = [System.DateTime]::UtcNow.AddDays(-$PruneAfterDays)
    $Projects = Get-AgentSyncStateFolders

    foreach ($Project in $Projects) {
        $ActivityRoot = Join-Path (Join-Path $Project.FullName ".agent-state") "activity"
        if (-not (Test-Path -LiteralPath $ActivityRoot)) {
            continue
        }

        $Stale = Get-ChildItem -LiteralPath $ActivityRoot -Recurse -File -Filter "*.json" -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTimeUtc -lt $Cutoff }

        foreach ($File in $Stale) {
            if ($Script:DryRun) {
                Write-AgentSyncLog -Level "DEBUG" -Message "DRYRUN ACTIVITY_PRUNE $($File.FullName)"
                continue
            }
            Remove-Item -LiteralPath $File.FullName -Force -ErrorAction SilentlyContinue
        }

        if ($Script:DryRun) {
            continue
        }

        # Heartbeats are control plane, not native state, so pruning does not
        # violate the no-deletion policy for agent history.
        $EmptyDirs = Get-ChildItem -LiteralPath $ActivityRoot -Recurse -Directory -ErrorAction SilentlyContinue |
            Sort-Object { $_.FullName.Length } -Descending |
            Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue) }
        foreach ($Dir in $EmptyDirs) {
            Remove-Item -LiteralPath $Dir.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-OverwrittenRetention {
    # conflicts/overwritten holds pre-overwrite backups from the equal-time
    # tie branch. They are a safety net, not history: without retention they
    # grew to 7+ GB (dominated by growth snapshots of active sessions).
    # Policy: per original file name, keep the newest KeepPerFile backups,
    # and drop everything older than RetentionDays - but never the newest one.
    $RetentionDays = 7
    $KeepPerFile = 3
    if ($Config.safety) {
        if ($null -ne $Config.safety.overwrittenRetentionDays) { $RetentionDays = [int]$Config.safety.overwrittenRetentionDays }
        if ($null -ne $Config.safety.overwrittenKeepPerFile) { $KeepPerFile = [int]$Config.safety.overwrittenKeepPerFile }
    }
    if ($RetentionDays -le 0 -and $KeepPerFile -le 0) {
        return
    }
    if ($KeepPerFile -le 0) { $KeepPerFile = [int]::MaxValue }

    $Cutoff = [System.DateTime]::UtcNow.AddDays(-[math]::Max(1, $RetentionDays))
    $Removed = 0
    $FreedBytes = [long]0

    foreach ($Project in Get-AgentSyncStateFolders) {
        $OverwrittenRoot = Join-Path (Join-Path (Join-Path $Project.FullName ".agent-state") "conflicts") "overwritten"
        if (-not (Test-Path -LiteralPath $OverwrittenRoot)) {
            continue
        }

        $Groups = Get-ChildItem -LiteralPath $OverwrittenRoot -Recurse -File -ErrorAction SilentlyContinue |
            Group-Object Name

        foreach ($Group in $Groups) {
            $Sorted = @($Group.Group | Sort-Object LastWriteTimeUtc -Descending)
            for ($Index = 0; $Index -lt $Sorted.Count; $Index++) {
                $File = $Sorted[$Index]
                $TooMany = ($Index -ge $KeepPerFile)
                $TooOld = ($Index -ge 1 -and $RetentionDays -gt 0 -and $File.LastWriteTimeUtc -lt $Cutoff)
                if (-not ($TooMany -or $TooOld)) {
                    continue
                }

                if ($Script:DryRun) {
                    Write-AgentSyncLog -Level "DEBUG" -Message "DRYRUN OVERWRITTEN_PRUNE $($File.FullName)"
                    continue
                }

                $Size = $File.Length
                Remove-Item -LiteralPath $File.FullName -Force -ErrorAction SilentlyContinue
                if (-not (Test-Path -LiteralPath $File.FullName)) {
                    $Removed++
                    $FreedBytes += [long]$Size
                }
            }
        }

        if ($Script:DryRun) {
            continue
        }

        $EmptyDirs = Get-ChildItem -LiteralPath $OverwrittenRoot -Recurse -Directory -ErrorAction SilentlyContinue |
            Sort-Object { $_.FullName.Length } -Descending |
            Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue) }
        foreach ($Dir in $EmptyDirs) {
            Remove-Item -LiteralPath $Dir.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    if ($Removed -gt 0) {
        Write-AgentSyncLog -Level "INFO" -Message "OVERWRITTEN_PRUNE removed=$Removed freedMB=$([math]::Round($FreedBytes/1MB,1))" -Console
    }
}

function Invoke-ArchivePolicy {
    if (-not $Config.archive -or $Config.archive.enabled -ne $true) {
        return
    }

    $AfterDays = 90
    if ($Config.archive.archiveAfterDays) {
        $AfterDays = [int]$Config.archive.archiveAfterDays
    }
    if ($AfterDays -le 0) {
        return
    }

    $Cutoff = [System.DateTime]::UtcNow.AddDays(-$AfterDays)
    $Projects = Get-AgentSyncStateFolders

    foreach ($Project in $Projects) {
        $StateRoot = Join-Path $Project.FullName ".agent-state"
        if (-not (Test-Path -LiteralPath $StateRoot)) {
            continue
        }

        $ArchiveRoot = Join-Path $StateRoot "archive"
        if (-not $Script:DryRun) {
            New-Item -ItemType Directory -Path $ArchiveRoot -Force | Out-Null
        }

        $Candidates = Get-ChildItem -LiteralPath $StateRoot -Recurse -ErrorAction SilentlyContinue |
            Where-Object {
                -not (Test-PathInside -ChildPath $_.FullName -ParentPath $ArchiveRoot) -and
                (
                    ($_.PSIsContainer -and $_.Parent -and $_.Parent.Name -eq "sessions") -or
                    (-not $_.PSIsContainer -and $_.Directory -and $_.Directory.Name -eq "sessions")
                )
            }

        foreach ($Candidate in $Candidates) {
            if ($Candidate.PSIsContainer) {
                $Newest = Get-ChildItem -LiteralPath $Candidate.FullName -Recurse -File -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTimeUtc -Descending |
                    Select-Object -First 1
                if (-not $Newest -or $Newest.LastWriteTimeUtc -ge $Cutoff) {
                    continue
                }
            }
            elseif ($Candidate.LastWriteTimeUtc -ge $Cutoff) {
                continue
            }

            $Relative = Get-RelativeChildPath -BasePath $StateRoot -FullPath $Candidate.FullName
            if ($null -eq $Relative) {
                continue
            }

            $SafeName = ($Relative -replace '[\\/]', '__') + ".zip"
            $ArchivePath = Join-Path $ArchiveRoot $SafeName
            if (Test-Path -LiteralPath $ArchivePath) {
                continue
            }

            if ($Script:DryRun) {
                Write-AgentSyncLog -Level "INFO" -Message "DRYRUN ARCHIVE_SNAPSHOT project=$($Project.Name) source=$Relative"
                continue
            }

            try {
                Compress-Archive -LiteralPath $Candidate.FullName -DestinationPath $ArchivePath -CompressionLevel Optimal -ErrorAction Stop
                Write-AgentSyncLog -Level "INFO" -Message "ARCHIVE_SNAPSHOT project=$($Project.Name) source=$Relative destination=$ArchivePath"
            }
            catch {
                Write-AgentSyncLog -Level "WARN" -Message "Could not create archive snapshot of $($Candidate.FullName): $($_.Exception.Message)"
            }
        }
    }
}

function Test-PathInside {
    param (
        [string]$ChildPath,
        [string]$ParentPath
    )

    if ([string]::IsNullOrWhiteSpace($ChildPath) -or [string]::IsNullOrWhiteSpace($ParentPath)) {
        return $false
    }

    try {
        $Child = [System.IO.Path]::GetFullPath($ChildPath).TrimEnd('\', '/')
        $Parent = [System.IO.Path]::GetFullPath($ParentPath).TrimEnd('\', '/')
    }
    catch {
        return $false
    }

    if ($Child.Equals($Parent, $PathComparison)) {
        return $true
    }

    $Prefix = $Parent + [System.IO.Path]::DirectorySeparatorChar
    return $Child.StartsWith($Prefix, $PathComparison)
}

function Get-RelativeChildPath {
    param (
        [string]$BasePath,
        [string]$FullPath
    )

    $Base = [System.IO.Path]::GetFullPath($BasePath).TrimEnd('\', '/')
    $Full = [System.IO.Path]::GetFullPath($FullPath)

    if (-not (Test-PathInside -ChildPath $Full -ParentPath $Base)) {
        return $null
    }

    if ($Full.Length -eq $Base.Length) {
        return ""
    }

    return $Full.Substring($Base.Length).TrimStart('\', '/')
}

function Test-SamePath {
    param (
        [string]$Left,
        [string]$Right
    )

    if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) {
        return $false
    }

    try {
        $LeftFull = [System.IO.Path]::GetFullPath($Left).TrimEnd('\', '/')
        $RightFull = [System.IO.Path]::GetFullPath($Right).TrimEnd('\', '/')
        return $LeftFull.Equals($RightFull, $PathComparison)
    }
    catch {
        return $false
    }
}

function Register-AgentSyncProjectRoot {
    param (
        [string]$ProjectRoot,
        [switch]$FromIndex
    )

    if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
        return $null
    }

    try {
        $Resolved = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\', '/')
    }
    catch {
        return $null
    }

    # Guard the registry itself, not just cwd resolution: index files from
    # other machines may still carry historical roots inside .agent-state.
    # Clip such entries to the owning project on the way in.
    $Resolved = [regex]::Replace($Resolved, '(?i)[\\/]\.agent-state(?:[\\/].*)?$', '')
    if ([string]::IsNullOrWhiteSpace($Resolved)) {
        return $null
    }

    if (-not (Test-PathInside -ChildPath $Resolved -ParentPath $ProjectsBasePath) -or
        (Test-SamePath -Left $Resolved -Right $ProjectsBasePath) -or
        -not (Test-Path -LiteralPath $Resolved -PathType Container)) {
        return $null
    }

    [void]$Script:KnownProjectRoots.Add($Resolved)
    if (-not $FromIndex -and $Script:LocalProjectRoots.Add($Resolved)) {
        $Script:ProjectIndexDirty = $true
    }
    return $Resolved
}

function Get-AgentSyncProjectIndexDirectory {
    $Directory = 'project-index'
    if ($Config.projectIndex -and -not [string]::IsNullOrWhiteSpace([string]$Config.projectIndex.directory)) {
        $Directory = [string]$Config.projectIndex.directory
    }
    if (-not [System.IO.Path]::IsPathRooted($Directory)) {
        $Directory = Join-Path $PSScriptRoot $Directory
    }
    return [System.IO.Path]::GetFullPath($Directory).TrimEnd('\', '/')
}

function Update-AgentSyncProjectIndex {
    $RefreshSeconds = 60
    if ($Config.projectIndex -and $Config.projectIndex.refreshSeconds) {
        $RefreshSeconds = [Math]::Max(10, [int]$Config.projectIndex.refreshSeconds)
    }

    $Now = [System.DateTimeOffset]::UtcNow
    if (Test-AgentSyncRecentTimestamp -Since $Script:ProjectIndexLastReadUtc -WindowSeconds $RefreshSeconds -Now $Now) {
        return
    }

    # Project paths come from agent cwd/workspace metadata. Per-machine index
    # files only carry those relative paths to other computers; Dropbox folders
    # are never scanned or promoted to projects merely because they exist.
    $Script:ProjectIndexLastReadUtc = $Now
    $Before = $Script:KnownProjectRoots.Count
    $IndexDirectory = Get-AgentSyncProjectIndexDirectory
    if (Test-Path -LiteralPath $IndexDirectory -PathType Container) {
        foreach ($File in @(Get-ChildItem -LiteralPath $IndexDirectory -File -Filter '*.json' -ErrorAction SilentlyContinue)) {
            try {
                $Index = Get-Content -LiteralPath $File.FullName -Raw | ConvertFrom-Json
                foreach ($Relative in @($Index.projects)) {
                    if ([string]::IsNullOrWhiteSpace([string]$Relative) -or [System.IO.Path]::IsPathRooted([string]$Relative)) {
                        continue
                    }
                    $Candidate = [System.IO.Path]::GetFullPath((Join-Path $ProjectsBasePath ([string]$Relative))).TrimEnd('\', '/')
                    if (Test-PathInside -ChildPath $Candidate -ParentPath $ProjectsBasePath) {
                        [void](Register-AgentSyncProjectRoot -ProjectRoot $Candidate -FromIndex)
                    }
                }
            }
            catch {
                Write-AgentSyncLog -Level 'WARN' -Message "Could not read project index $($File.FullName): $($_.Exception.Message)"
            }
        }
    }

    foreach ($Known in @($Script:KnownProjectRoots)) {
        if (-not (Test-Path -LiteralPath $Known -PathType Container)) {
            [void]$Script:KnownProjectRoots.Remove($Known)
        }
    }

    Write-AgentSyncLog -Level 'INFO' -Message "PROJECT_INDEX_READ root=$ProjectsBasePath projects=$($Script:KnownProjectRoots.Count) added=$($Script:KnownProjectRoots.Count - $Before)"
}

function Save-AgentSyncProjectIndex {
    if (-not $Script:ProjectIndexDirty -or $Script:DryRun) {
        return
    }

    $IndexDirectory = Get-AgentSyncProjectIndexDirectory
    $RelativeProjects = @(
        foreach ($ProjectRoot in @($Script:LocalProjectRoots | Sort-Object)) {
            $Relative = Get-RelativeChildPath -BasePath $ProjectsBasePath -FullPath $ProjectRoot
            if (-not [string]::IsNullOrWhiteSpace($Relative)) {
                $Relative -replace '\\', '/'
            }
        }
    )
    $Payload = [ordered]@{
        format = 1
        machine = $MachineId
        root = $ProjectsDirSetting
        updatedUtc = [System.DateTimeOffset]::UtcNow.ToString('o')
        projects = $RelativeProjects
    } | ConvertTo-Json -Depth 5

    $IndexPath = Join-Path $IndexDirectory "$MachineId.json"
    Write-Utf8TextIfChanged -Path $IndexPath -Text $Payload
    $Script:ProjectIndexDirty = $false
    Write-AgentSyncLog -Level 'INFO' -Message "PROJECT_INDEX_WRITE path=$IndexPath projects=$($RelativeProjects.Count)"
}

function Get-AgentSyncStateFolders {
    # Housekeeping has to reach every folder that HOLDS state, not only the
    # folders the index calls projects. A folder leaves the index when the agent
    # metadata that named it ages out, but its .agent-state keeps growing, so
    # retention, activity pruning and archiving would never visit it again -
    # the writer and the cleaner were walking different lists.
    #
    # This is deliberately not a project source: an unindexed folder is swept,
    # never promoted to a project, never synced to and never reported as one.
    $Depth = 6
    if ($Config.projectIndex -and $null -ne $Config.projectIndex.maintenanceScanDepth) {
        $Depth = [Math]::Max(1, [int]$Config.projectIndex.maintenanceScanDepth)
    }

    $Seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $Folders = [System.Collections.Generic.List[object]]::new()

    foreach ($Project in Get-AgentSyncProjects) {
        if (Test-AgentSyncOwnMissionPath -Path $Project.FullName) { continue }
        if ($Seen.Add($Project.FullName.TrimEnd([char]92, [char]47))) {
            [void]$Folders.Add($Project)
        }
    }

    if (-not $ProjectsBasePath -or -not (Test-Path -LiteralPath $ProjectsBasePath -PathType Container)) {
        return @($Folders)
    }

    # Breadth-first, bounded, and never descending into .agent-state itself.
    $Queue = [System.Collections.Generic.Queue[object]]::new()
    $Queue.Enqueue([pscustomobject]@{ Path = $ProjectsBasePath; Level = 0 })
    while ($Queue.Count -gt 0) {
        $Current = $Queue.Dequeue()

        $Children = @()
        try {
            $Children = @([System.IO.Directory]::EnumerateDirectories($Current.Path))
        }
        catch {
            continue
        }

        foreach ($Child in $Children) {
            $Name = [System.IO.Path]::GetFileName($Child)
            if ($Name -eq '.agent-state') {
                $Owner = $Current.Path.TrimEnd([char]92, [char]47)
                if ($Seen.Add($Owner)) {
                    $Item = Get-Item -LiteralPath $Owner -ErrorAction SilentlyContinue
                    if ($Item -and $Item.PSIsContainer) {
                        [void]$Folders.Add($Item)
                    }
                }
                continue
            }
            # Only this toolkit's missions store is local control data, never
            # provider history. Other projects named missions remain eligible.
            if ($Name.StartsWith('.') -or $Name -eq 'node_modules' -or $Name -eq 'target' -or
                (Test-AgentSyncOwnMissionPath -Path $Child)) {
                continue
            }
            if ($Current.Level + 1 -lt $Depth) {
                $Queue.Enqueue([pscustomobject]@{ Path = $Child; Level = $Current.Level + 1 })
            }
        }
    }

    return @($Folders)
}

function Get-AgentSyncProjects {
    Update-AgentSyncProjectIndex

    $Projects = foreach ($Known in @($Script:KnownProjectRoots | Sort-Object)) {
        Get-Item -LiteralPath $Known -ErrorAction SilentlyContinue
    }
    return @($Projects | Where-Object { $_ -and $_.PSIsContainer })
}

function Remove-AgentInternalWorkspaceSuffix {
    param ([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    # Claude creates temporary Git worktrees below the real project. They are
    # implementation details, unlike an ordinary nested workspace selected by
    # the user. Attribute the session to the project before .claude/worktrees.
    $Clipped = [regex]::Replace(
        $Path,
        '(?i)[\\/]\.claude[\\/]worktrees[\\/][^\\/]+(?:[\\/].*)?$',
        '')

    # A session started inside an .agent-state tree belongs to the project
    # that owns the state - never to the control plane itself. Without this,
    # a session could register example-project\.agent-state as its own
    # project, nesting state inside state.
    $Clipped = [regex]::Replace(
        $Clipped,
        '(?i)[\\/]\.agent-state(?:[\\/].*)?$',
        '')

    return $Clipped
}

function Get-PreferredKnownAncestor {
    param ([string]$Path)

    $Prefer = $true
    if ($Config.projectResolution -and $null -ne $Config.projectResolution.preferExistingAncestor) {
        $Prefer = [bool]$Config.projectResolution.preferExistingAncestor
    }
    if (-not $Prefer) {
        return $Path
    }

    try {
        $Full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    }
    catch {
        return $Path
    }

    # A path that is already a known project keeps its identity.
    if ($Script:KnownProjectRoots.Contains($Full)) {
        return $Full
    }

    # A brand-new root below an existing project fragments history (Forlike\code
    # and Forlike\code\php ended up as separate projects). Attribute the session
    # to the deepest known ancestor instead; genuinely new projects with no
    # known ancestor are unaffected. Disable via
    # projectResolution.preferExistingAncestor = false.
    $Best = $null
    foreach ($Known in $Script:KnownProjectRoots) {
        if ((Test-PathInside -ChildPath $Full -ParentPath $Known) -and -not (Test-SamePath -Left $Full -Right $Known)) {
            if (-not $Best -or $Known.Length -gt $Best.Length) {
                $Best = $Known
            }
        }
    }

    if ($Best) {
        return $Best
    }
    return $Path
}

function Get-ProjectRootFromCwd {
    param ([string]$Cwd)

    if ([string]::IsNullOrWhiteSpace($Cwd)) {
        return $null
    }

    $CwdPath = $Cwd

    if ($Cwd -match '^file://') {
        try {
            $CwdPath = ([System.Uri]$Cwd).LocalPath
        }
        catch {
            $CwdPath = $Cwd
        }
    }

    $CwdPath = Remove-AgentInternalWorkspaceSuffix -Path $CwdPath

    try {
        $ResolvedCwd = Expand-ConfiguredPath -Path $CwdPath
    }
    catch {
        return $null
    }

    # The configured root is only an allowed synchronization boundary. The
    # agent's exact cwd/workspace is the project identity, including when both
    # a parent folder and one of its subfolders are separate agent projects.
    if (Test-PathInside -ChildPath $ResolvedCwd -ParentPath $ProjectsBasePath) {
        $Relative = Get-RelativeChildPath -BasePath $ProjectsBasePath -FullPath $ResolvedCwd
        if (-not [string]::IsNullOrWhiteSpace($Relative) -and (Test-Path -LiteralPath $ResolvedCwd -PathType Container)) {
            return (Register-AgentSyncProjectRoot -ProjectRoot (Get-PreferredKnownAncestor -Path $ResolvedCwd))
        }
    }

    # Optional: local repos outside the shared projects folder can be mapped to a shared project.
    if ($Config.projectAliases) {
        foreach ($Property in $Config.projectAliases.PSObject.Properties) {
            $ProjectName = [string]$Property.Name
            $Aliases = @($Property.Value)

            foreach ($Alias in $Aliases) {
                try {
                    $AliasPath = Expand-ConfiguredPath -Path ([string]$Alias)
                }
                catch {
                    continue
                }

                if (Test-PathInside -ChildPath $ResolvedCwd -ParentPath $AliasPath) {
                    $AliasRelative = Get-RelativeChildPath -BasePath $AliasPath -FullPath $ResolvedCwd
                    $ProjectRoot = Join-Path $ProjectsBasePath $ProjectName
                    if (-not [string]::IsNullOrWhiteSpace($AliasRelative)) {
                        $ProjectRoot = Join-Path $ProjectRoot $AliasRelative
                    }
                    if (Test-Path -LiteralPath $ProjectRoot) {
                        return (Register-AgentSyncProjectRoot -ProjectRoot (Get-PreferredKnownAncestor -Path $ProjectRoot))
                    }
                }
            }
        }
    }

    return $null
}

function Get-FastJsonMetadataPath {
    param ([string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $null
    }

    # Agent JSONL records can contain multi-megabyte conversation payloads.
    # Workspace metadata is emitted near the beginning of the native record,
    # so inspect only a bounded prefix before considering full JSON parsing.
    $PrefixLength = [Math]::Min($Line.Length, 65536)
    $Prefix = $Line.Substring(0, $PrefixLength)
    $Match = [regex]::Match(
        $Prefix,
        '(?<!\\)"(?:cwd|projectPath|workspacePath|workspaceFolder)"\s*:\s*"(?<value>(?:\\.|[^"\\])*)"',
        [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
    )
    if (-not $Match.Success) {
        return $null
    }

    $Document = $null
    try {
        # Decode JSON escapes without materializing the surrounding record.
        $Document = [System.Text.Json.JsonDocument]::Parse('"' + $Match.Groups['value'].Value + '"')
        return [string]$Document.RootElement.GetString()
    }
    catch {
        return $null
    }
    finally {
        if ($Document) {
            $Document.Dispose()
        }
    }
}

function Get-SessionCwd {
    param ([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    # The result is cached per (path, size, mtime) so each cycle does not
    # re-read the first lines of every session file.
    $Item = $null
    try {
        $Item = Get-Item -LiteralPath $Path
        $Cached = $Script:SessionCwdCache[$Path]
        if ($Cached -and $Cached.Length -eq $Item.Length -and $Cached.Ticks -eq $Item.LastWriteTimeUtc.Ticks) {
            return $Cached.Cwd
        }
    }
    catch {
        $Item = $null
    }

    $Reader = $null
    $Result = $null
    $ReadFailed = $false

    try {
        $Reader = New-SharedStreamReader -Path $Path
        $LineNumber = 0
        $LargeContentLines = 0

        while (-not $Reader.EndOfStream -and $LineNumber -lt $MetadataReadLines) {
            $Line = $Reader.ReadLine()
            $LineNumber++

            if ([string]::IsNullOrWhiteSpace($Line)) {
                continue
            }

            $FastResult = Get-FastJsonMetadataPath -Line $Line
            if (-not [string]::IsNullOrWhiteSpace($FastResult)) {
                $Result = $FastResult
                break
            }

            # A large line without early workspace metadata is conversation
            # content. Fully deserializing it is both expensive and irrelevant
            # to project routing. Smaller records retain the compatibility path.
            if ($Line.Length -gt 262144) {
                $LargeContentLines++
                if ($LargeContentLines -ge 3) {
                    break
                }
                continue
            }

            try {
                $Object = $Line | ConvertFrom-Json
            }
            catch {
                continue
            }

            if ($Object.cwd) {
                $Result = [string]$Object.cwd
                break
            }

            if ($Object.payload -and $Object.payload.cwd) {
                $Result = [string]$Object.payload.cwd
                break
            }

            if ($Object.projectPath) {
                $Result = [string]$Object.projectPath
                break
            }

            if ($Object.workspacePath) {
                $Result = [string]$Object.workspacePath
                break
            }

            if ($Object.workspaceFolder) {
                $Result = [string]$Object.workspaceFolder
                break
            }
        }
    }
    catch {
        # Never fail silently here. An unreadable file is skipped by the
        # routing that follows, and without a log line that skip is invisible.
        $ReadFailed = $true
        $Result = $null
        if (-not $Script:UnreadableWarned.ContainsKey($Path)) {
            $Script:UnreadableWarned[$Path] = $true
            Write-AgentSyncLog -Level "WARN" -Message "METADATA_UNREADABLE not routed, skipping: $Path ($($_.Exception.Message))" -Console
        }
    }
    finally {
        if ($Reader) {
            $Reader.Dispose()
        }
    }

    if ($Item -and -not $ReadFailed) {
        # Clear any earlier warning state so a file that gets locked again later
        # is reported again instead of being suppressed forever.
        $Script:UnreadableWarned.Remove($Path)

        if ($Script:SessionCwdCache.Count -gt 20000) {
            $Script:SessionCwdCache.Clear()
        }
        $Script:SessionCwdCache[$Path] = @{ Length = $Item.Length; Ticks = $Item.LastWriteTimeUtc.Ticks; Cwd = $Result }
    }

    return $Result
}

function Get-FileHashSafe {
    param ([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $Stream = $null
    try {
        # A candidate read may coexist with the native agent's open writer.
        # Copy-FileSafe revalidates the captured bytes before publication.
        $Stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        return Get-AgentSyncStreamHash -Stream $Stream
    }
    catch {
        return $null
    }
    finally { if ($Stream) { $Stream.Dispose() } }
}

function Get-AgentSyncStreamHash {
    param ([System.IO.Stream]$Stream, [long]$Length = -1)
    $Stream.Position = 0
    $Hash = [System.Security.Cryptography.SHA256]::Create()
    try {
        if ($Length -lt 0) { return [Convert]::ToHexString($Hash.ComputeHash($Stream)) }
        $Buffer = [byte[]]::new(65536)
        $Remaining = $Length
        while ($Remaining -gt 0) {
            $Read = $Stream.Read($Buffer, 0, [int][Math]::Min($Buffer.Length, $Remaining))
            if ($Read -le 0) { throw [IO.EndOfStreamException]::new('File changed during prefix verification.') }
            [void]$Hash.TransformBlock($Buffer, 0, $Read, $Buffer, 0)
            $Remaining -= $Read
        }
        [void]$Hash.TransformFinalBlock([byte[]]::new(0), 0, 0)
        return [Convert]::ToHexString($Hash.Hash)
    }
    finally { $Hash.Dispose() }
}

function Test-AgentSyncJsonlTail {
    param ([string]$Path)
    $Stream = $null
    try {
        $Stream = [IO.File]::OpenRead($Path)
        if ($Stream.Length -eq 0) { return $false }
        $Count = [int][Math]::Min(8MB, $Stream.Length)
        [void]$Stream.Seek(-$Count, [IO.SeekOrigin]::End)
        $Buffer = [byte[]]::new($Count)
        $Offset = 0
        while ($Offset -lt $Count) {
            $Read = $Stream.Read($Buffer, $Offset, $Count - $Offset)
            if ($Read -le 0) { return $false }
            $Offset += $Read
        }
        $Text = [Text.Encoding]::UTF8.GetString($Buffer)
        if ($Stream.Length -gt $Count) {
            $Break = $Text.IndexOf("`n")
            if ($Break -lt 0) { return $false }
            $Text = $Text.Substring($Break + 1)
        }
        $Last = @($Text -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) | Select-Object -Last 1
        if (-not $Last) { return $false }
        $null = $Last | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        return $true
    }
    catch { return $false }
    finally { if ($Stream) { $Stream.Dispose() } }
}

function Copy-FileSafe {
    param (
        [string]$Source,
        [string]$Destination,
        [string]$ExpectedSourceHash,
        [string]$ExpectedDestinationHash,
        [string]$ProjectRoot,
        [string]$AgentName,
        [string]$DisplayPath
    )

    if ($Script:DryRun) {
        Write-Host "[DRYRUN COPY] $Source -> $Destination" -ForegroundColor DarkGray
        Write-AgentSyncLog -Level "INFO" -Message "DRYRUN COPY $Source -> $Destination"
        return $false
    }

    $DestDir = Split-Path -Path $Destination -Parent
    $MaxRetries = 5
    if ($Config.maxRetryCount) { $MaxRetries = [int]$Config.maxRetryCount }
    $MaxRetries = [Math]::Max(1, $MaxRetries)
    $DelayMs = 300
    if ($Config.fileLockRetryDelayMs) { $DelayMs = [int]$Config.fileLockRetryDelayMs }
    $Attempts = 0

    while ($Attempts -lt $MaxRetries) {
        $StagePath = "$Destination.agentsync-$PID-$([guid]::NewGuid().ToString('N')).tmp"
        $SourceStream = $null
        $StageStream = $null
        $TargetStream = $null
        $Backup = $null
        $WriteStarted = $false
        $OriginalLength = 0L
        try {
            if (-not (Test-Path -LiteralPath $DestDir)) {
                New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
            }
            # A shared source read permits active agents. Only a stable, complete
            # snapshot may be published; a growing/changing source is retried.
            $Before = Get-Item -LiteralPath $Source -ErrorAction Stop
            $SourceStream = [IO.FileStream]::new($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            $StageStream = [IO.FileStream]::new($StagePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $SourceStream.CopyTo($StageStream)
            $StageStream.Flush($true)
            $StageHash = Get-AgentSyncStreamHash -Stream $StageStream
            $SourceHash = Get-AgentSyncStreamHash -Stream $SourceStream
            $After = Get-Item -LiteralPath $Source -ErrorAction Stop
            if ($Before.Length -ne $After.Length -or $Before.LastWriteTimeUtc -ne $After.LastWriteTimeUtc -or
                $StageHash -ne $SourceHash -or ($ExpectedSourceHash -and $StageHash -ne $ExpectedSourceHash)) {
                throw [IO.InvalidDataException]::new('SOURCE_CHANGED: deferred until the next sync decision.')
            }
            $SourceStream.Dispose(); $SourceStream = $null
            $StageLength = $StageStream.Length
            $StageStream.Dispose(); $StageStream = $null
            if ((Test-AppendOnlyName -Path $Source) -and -not (Test-AgentSyncJsonlTail -Path $StagePath)) {
                throw [IO.InvalidDataException]::new('JSONL_INCOMPLETE: last record is not yet complete or exceeds the bounded tail check.')
            }
            $StageStream = [IO.File]::OpenRead($StagePath)
            $TargetExists = Test-Path -LiteralPath $Destination -PathType Leaf
            if ($ExpectedDestinationHash -and -not $TargetExists) {
                throw [IO.InvalidDataException]::new('DESTINATION_CHANGED: target disappeared after the sync decision.')
            }
            # Deny competing writers and renames until validation and publication
            # finish. An already-open writer defers this file, never gets replaced.
            $Mode = if ($TargetExists) { [IO.FileMode]::Open } else { [IO.FileMode]::CreateNew }
            $Sharing = if ($TargetExists -and (Test-AppendOnlyName -Path $Destination)) { [IO.FileShare]::Read } else { [IO.FileShare]::None }
            $TargetStream = [IO.FileStream]::new($Destination, $Mode, [IO.FileAccess]::ReadWrite, $Sharing)
            $OriginalLength = $TargetStream.Length
            if ($TargetExists) {
                if (-not $ExpectedDestinationHash) {
                    throw [IO.InvalidDataException]::new('DESTINATION_CHANGED: target appeared without a verified baseline.')
                }
                $TargetHash = Get-AgentSyncStreamHash -Stream $TargetStream
                if ($TargetHash -ne $ExpectedDestinationHash) {
                    throw [IO.InvalidDataException]::new('DESTINATION_CHANGED: target content changed after the sync decision.')
                }
                if (Test-AppendOnlyName -Path $Destination) {
                    if ($StageLength -le $OriginalLength -or
                        (Get-AgentSyncStreamHash -Stream $StageStream -Length $OriginalLength) -ne $TargetHash) {
                        throw [IO.InvalidDataException]::new('CONTENT_CONFLICT: JSONL branches are not a verified prefix extension; both retained.')
                    }
                    # Existing bytes are never rewritten for append-only growth.
                    $TargetStream.Position = $OriginalLength
                    $StageStream.Position = $OriginalLength
                }
                else {
                    $Backup = Save-OverwrittenCopy -ProjectRoot $ProjectRoot -AgentName $AgentName -LoserPath $Destination -SourceStream $TargetStream -ExpectedHash $TargetHash
                    if (-not $Backup -or -not $Backup.Path) { throw 'Verified backup is required before replacing existing content.' }
                    $TargetStream.Position = 0
                    $StageStream.Position = 0
                }
            }
            $WriteStarted = $true
            $StageStream.CopyTo($TargetStream)
            $TargetStream.SetLength($StageLength)
            $TargetStream.Flush($true)
            if ((Get-AgentSyncStreamHash -Stream $TargetStream) -ne $StageHash) {
                throw [IO.IOException]::new('Published copy failed SHA-256 verification.')
            }
            $TargetStream.Dispose(); $TargetStream = $null
            try { [IO.File]::SetLastWriteTimeUtc($Destination, $After.LastWriteTimeUtc) } catch { }
            Register-AgentSyncSelfWrite -Path $Destination
            return $true
        }
        catch {
            $LastError = $_
            if ($WriteStarted -and $TargetStream) {
                try {
                    if ($Backup) {
                        $Restore = [IO.File]::OpenRead($Backup.Path)
                        try { $TargetStream.Position = 0; $Restore.CopyTo($TargetStream) } finally { $Restore.Dispose() }
                    }
                    $TargetStream.SetLength($OriginalLength)
                    $TargetStream.Flush($true)
                }
                catch { Write-AgentSyncError -Context 'Copy rollback failed; verified backup retained' -ErrorRecord $_ -Console }
            }
            $Attempts++
            if ($_.Exception.GetBaseException() -is [IO.InvalidDataException]) { break }
            if ($Attempts -lt $MaxRetries) {
                Start-Sleep -Milliseconds $DelayMs
            }
        }
        finally {
            foreach ($Stream in @($TargetStream, $SourceStream, $StageStream)) { if ($Stream) { $Stream.Dispose() } }
            if (Test-Path -LiteralPath $StagePath) { Remove-Item -LiteralPath $StagePath -Force -ErrorAction SilentlyContinue }
        }
    }

    $FailureMessage = [string]$LastError.Exception.GetBaseException().Message
    if ($FailureMessage -match '^(SOURCE_CHANGED|DESTINATION_CHANGED):') {
        # Expected concurrent activity is neither successful backup nor a
        # broken provider. Preserve the old copy and expose the deferral.
        $Script:CycleDeferredCopies++
        Write-AgentSyncLog -Level 'INFO' -Message "COPY_DEFERRED reason=$($Matches[1]) attempts=$Attempts"
        return $false
    }
    if ($FailureMessage -match '^CONTENT_CONFLICT:' -and $ProjectRoot -and $AgentName -and $DisplayPath -and $StageHash -and $TargetHash) {
        try {
            $Conflict = Register-AgentSyncContentConflict -ProjectRoot $ProjectRoot -AgentName $AgentName -DisplayPath $DisplayPath -FirstHash $StageHash -SecondHash $TargetHash
            $Script:CycleContentConflicts++
            if ($Conflict.Created) {
                $Script:CycleNewContentConflicts++
                Write-AgentSyncLog -Level 'WARN' -Message "CONTENT_CONFLICT preserved id=$($Conflict.Id) path=$DisplayPath" -Console
            }
            else {
                Write-AgentSyncLog -Level 'DEBUG' -Message "CONTENT_CONFLICT known id=$($Conflict.Id)"
            }
        }
        catch {
            Write-AgentSyncError -Context 'Recording preserved content conflict' -ErrorRecord $_ -Console
        }
        return $false
    }
    Write-AgentSyncError -Context "Copy failed after $Attempts attempt(s): $Source" -ErrorRecord $LastError -Console
    return $false
}


function Record-SyncSuccess {
    param (
        [string]$AgentName,
        [string]$Direction,
        [string]$DisplayPath,
        [string]$ProjectRoot
    )

    Write-AgentSyncLog -Level "INFO" -Message "SYNC agent=$AgentName direction=$Direction path=$DisplayPath"
    if ($ProjectRoot) {
        # Incremental cycles update manifests only for projects that actually
        # saw sync activity; this set records them as it happens.
        $Script:TouchedProjects[$ProjectRoot] = $true
        $SessionId = Get-SessionIdFromDisplayPath -DisplayPath $DisplayPath
        Write-ActivityHeartbeat -ProjectRoot $ProjectRoot -AgentName $AgentName -SessionId $SessionId -Direction $Direction
    }
}

# Guidance files carry a version marker as their last line. It lets AgentSync
# recognise its own text and replace it when the template moves on, without
# ever touching a file the project has made its own. A project that wants to
# freeze its instructions deletes the marker line.
# Content hashes of superseded AgentSync templates that predate the marker.
# A file matching one of these is provably untouched boilerplate, so it can be
# migrated. Anything else is left alone, whatever it looks like.
$Script:GuidanceLegacyHashes = @{
    'AGENTS.md' = @(
        'A950E2D9B981BB196FBE125FC36BD7D6142220914D7C772E66795A126534F032'  # git 3a191ee
        'F17F61AB0B593F2F48687B2C85A0AF294B3360D8EA9FB5BF0D42FD14D9EEB21D'  # git 87b55d0
        '98253DD7711D3AB286A040ECCF4C9ECBD32C10CE2660415FECE22204867F9677'  # git 9348c01
        'A923F146CE6C8CAD5143955EC72AFE02C8C9C3BCC84A79B969293570FCD58771'  # verified aisense-free-public-rest-apis
    )
    'AGENT_CONTEXT.md' = @(
        '3B54DBDF49A3D267B333E36071A064B89ED049B8F1B6F8796700E9F31D22835B'  # git 6d42998
        '6B482E6293C2A4B6E62ECBE0AE997333C2D4DFA77E0E507DAE53212903A2FFE3'  # git 3a191ee
        'ABD5BA248557ECD7FF458851F2356D3B7927D6DD67A7ADB0EE46181E67323241'  # git 87b55d0
        'FF24447DE6E12854908584C7912C84B004EE9F56467941B3CF56017059318CAA'  # git 9348c01
        '8AE5E1F22F3A3FBA24AA3CAA6E9D06951A748B07820AA8E8F56A707420BC37E2'  # git be02d6a
        '1B5F96C106019DEA9562B1AE855D8D79AB8C2BE62BCD3A3D123D4B16A9ABB9CE'  # verified aisense-free-public-rest-apis-main
        'BBA0D526BA55333D3EE092168DF1FB11A1CBDFE45B1975EB9A0F4182F46B005B'  # verified BatterySwapAiBatterySwap
    )
}

function Get-GuidanceContentHash {
    param ([string]$Text)

    if ($null -eq $Text) {
        return ''
    }

    $Normalised = $Text -replace "^\uFEFF", '' -replace "`r`n", "`n"
    $Normalised = $Normalised.Trim()
    $Sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $Bytes = $Sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Normalised))
        return (($Bytes | ForEach-Object { $_.ToString('X2') }) -join '')
    }
    finally {
        $Sha.Dispose()
    }
}

function Get-GuidanceMarkerVersion {
    param ([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return $null
    }

    $Match = [regex]::Match($Text, '<!--\s*agentsync-guidance:\s*v([0-9]+(?:\.[0-9]+)*)')
    if (-not $Match.Success) {
        return $null
    }
    return $Match.Groups[1].Value
}

function Get-GuidanceAction {
    param (
        [string]$FileName,
        [string]$Existing,
        [string]$Template
    )

    if ((Get-GuidanceContentHash -Text $Existing) -eq (Get-GuidanceContentHash -Text $Template)) {
        return 'current'
    }

    $ExistingVersion = Get-GuidanceMarkerVersion -Text $Existing
    if ($ExistingVersion) {
        $TemplateVersion = Get-GuidanceMarkerVersion -Text $Template
        if (-not $TemplateVersion) {
            return 'keep'
        }
        try {
            if ([version]$ExistingVersion -lt [version]$TemplateVersion) {
                return 'update'
            }
        }
        catch {
            return 'keep'
        }
        # Same or newer marker with different content means the project edited
        # it after AgentSync wrote it. That edit wins.
        return 'keep'
    }

    $Known = @()
    if ($Script:GuidanceLegacyHashes.ContainsKey($FileName)) {
        $Known = @($Script:GuidanceLegacyHashes[$FileName])
    }
    if ($Known -contains (Get-GuidanceContentHash -Text $Existing)) {
        return 'update'
    }

    return 'keep'
}

function Install-ProjectGuidance {
    $Enabled = $true
    if ($Config.projectGuidance -and $null -ne $Config.projectGuidance.enabled) {
        $Enabled = [bool]$Config.projectGuidance.enabled
    }
    if (-not $Enabled) {
        return
    }

    # These files are active project instructions, not native agent state.
    # AgentSync creates them when missing and refreshes its own superseded text,
    # but a file the project has made its own is never overwritten.
    $GuidanceFiles = @("AGENTS.md", "AGENT_CONTEXT.md")
    $Projects = @(Get-AgentSyncProjects)
    $Created = 0
    $Updated = 0
    $Kept = 0

    foreach ($FileName in $GuidanceFiles) {
        $Source = Join-Path $PSScriptRoot $FileName
        if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
            if (-not $Script:GuidanceSourceWarned.ContainsKey($FileName)) {
                Write-AgentSyncLog -Level "WARN" -Message "Project guidance file missing from the tool folder: $Source" -Console
                $Script:GuidanceSourceWarned[$FileName] = $true
            }
            continue
        }

        $Template = $null
        try {
            $Template = Get-Content -LiteralPath $Source -Raw -ErrorAction Stop
        }
        catch {
            Write-AgentSyncLog -Level "WARN" -Message "Could not read project guidance template ${Source}: $($_.Exception.Message)" -Console
            continue
        }

        foreach ($Project in $Projects) {
            $Destination = Join-Path $Project.FullName $FileName

            if (-not (Test-Path -LiteralPath $Destination)) {
                if ($Script:DryRun) {
                    Write-AgentSyncLog -Level "INFO" -Message "DRYRUN CREATE guidance=$Destination"
                    $Created++
                    continue
                }
                try {
                    # overwrite=false guards against a race where the project
                    # itself creates the file after the Test-Path check.
                    [System.IO.File]::Copy($Source, $Destination, $false)
                    $Created++
                }
                catch {
                    if (-not (Test-Path -LiteralPath $Destination)) {
                        Write-AgentSyncLog -Level "WARN" -Message "Could not create project guidance ${Destination}: $($_.Exception.Message)" -Console
                    }
                }
                continue
            }

            $Existing = $null
            try {
                $Existing = Get-Content -LiteralPath $Destination -Raw -ErrorAction Stop
            }
            catch {
                continue
            }

            switch (Get-GuidanceAction -FileName $FileName -Existing $Existing -Template $Template) {
                'update' {
                    if ($Script:DryRun) {
                        Write-AgentSyncLog -Level "INFO" -Message "DRYRUN UPDATE guidance=$Destination"
                        $Updated++
                        break
                    }
                    try {
                        [System.IO.File]::Copy($Source, $Destination, $true)
                        $Updated++
                    }
                    catch {
                        Write-AgentSyncLog -Level "WARN" -Message "Could not update project guidance ${Destination}: $($_.Exception.Message)" -Console
                    }
                }
                'keep' {
                    $Kept++
                    if (-not $Script:GuidanceKeptLogged.ContainsKey($Destination)) {
                        Write-AgentSyncLog -Level "INFO" -Message "GUIDANCE_KEPT the project made this file its own, so AgentSync leaves it: $Destination"
                        $Script:GuidanceKeptLogged[$Destination] = $true
                    }
                }
            }
        }
    }

    if ($Created -gt 0 -or $Updated -gt 0) {
        Write-AgentSyncLog -Level "INFO" -Message "GUIDANCE created=$Created updated=$Updated kept=$Kept" -Console
    }
}

function ConvertTo-StatusHtml {
    param ($Value)

    if ($null -eq $Value) {
        return ""
    }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Format-StatusBytes {
    param ([long]$Bytes)

    if ($Bytes -le 0) {
        return "0 B"
    }

    $Units = @("B", "KB", "MB", "GB", "TB")
    $Value = [double]$Bytes
    $Index = 0
    while ($Value -ge 1024 -and $Index -lt ($Units.Count - 1)) {
        $Value /= 1024
        $Index++
    }

    if ($Index -eq 0) {
        return ("{0:N0} {1}" -f $Value, $Units[$Index])
    }
    return ("{0:N1} {1}" -f $Value, $Units[$Index])
}

function ConvertTo-StatusTime {
    param ($Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return [PSCustomObject]@{ Display = "-"; Sort = [long]0; Iso = "" }
    }

    try {
        $Parsed = [System.DateTimeOffset]::Parse(
            [string]$Value,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind
        )
        return [PSCustomObject]@{
            Display = $Parsed.ToLocalTime().ToString("dd.MM.yyyy HH:mm")
            Sort = $Parsed.UtcTicks
            Iso = $Parsed.ToUniversalTime().ToString("o")
        }
    }
    catch {
        return [PSCustomObject]@{ Display = "Ukjent"; Sort = [long]0; Iso = "" }
    }
}

function New-StatusAgentMetric {
    return [PSCustomObject]@{
        Files = 0
        Sessions = 0
        Bytes = [long]0
        NewestUtc = $null
        Newest = ConvertTo-StatusTime -Value $null
        Model = ''
        Provider = ''
        ModelSeenUtc = $null
        SessionIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        ModelCandidates = New-Object 'System.Collections.Generic.List[object]'
    }
}

function Get-StatusNestedValue {
    param (
        $Object,
        [string[]]$Paths
    )

    foreach ($Path in @($Paths)) {
        $Current = $Object
        foreach ($Segment in @($Path -split '\.')) {
            if ($null -eq $Current) {
                break
            }
            $Property = $Current.PSObject.Properties[$Segment]
            if (-not $Property) {
                $Current = $null
                break
            }
            $Current = $Property.Value
        }
        if ($null -ne $Current -and -not [string]::IsNullOrWhiteSpace([string]$Current)) {
            $Text = [string]$Current
            if ($Text -notmatch '^@\{' -and $Text -notmatch '^\d+$') {
                return $Text
            }
        }
    }
    return $null
}

function Get-BoundedUtf8TailLines {
    param (
        [string]$Path,
        [int]$MaxBytes = 4194304
    )

    $Stream = $null
    try {
        $Share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $Stream = [System.IO.FileStream]::new(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            $Share
        )
        $ReadLength = [int][Math]::Min([long]$MaxBytes, $Stream.Length)
        if ($ReadLength -le 0) {
            return @()
        }

        $Start = $Stream.Length - $ReadLength
        [void]$Stream.Seek($Start, [System.IO.SeekOrigin]::Begin)
        $Buffer = [byte[]]::new($ReadLength)
        $TotalRead = 0
        while ($TotalRead -lt $ReadLength) {
            $Read = $Stream.Read($Buffer, $TotalRead, $ReadLength - $TotalRead)
            if ($Read -le 0) {
                break
            }
            $TotalRead += $Read
        }

        $Text = [System.Text.Encoding]::UTF8.GetString($Buffer, 0, $TotalRead)
        $Lines = @($Text -split "`r?`n")
        if ($Start -gt 0 -and $Lines.Count -gt 1) {
            # The first line starts at an arbitrary byte boundary and may be a
            # partial JSON record. Only complete native records are useful.
            return @($Lines[1..($Lines.Count - 1)])
        }
        return $Lines
    }
    catch {
        return @()
    }
    finally {
        if ($Stream) {
            $Stream.Dispose()
        }
    }
}

function Get-StatusJsonlModelInfo {
    param (
        [string]$Path,
        [string]$AgentName
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        $File = Get-Item -LiteralPath $Path -ErrorAction Stop
        $AttributeText = [string]$File.Attributes
        if ($AttributeText -match 'Offline|RecallOnDataAccess|RecallOnOpen') {
            return $null
        }
        $CacheKey = $File.FullName
        if ($Script:StatusModelCache.ContainsKey($CacheKey)) {
            $Cached = $Script:StatusModelCache[$CacheKey]
            if ($Cached.Length -eq $File.Length -and $Cached.LastWriteTicks -eq $File.LastWriteTimeUtc.Ticks) {
                return $(if ([string]::IsNullOrWhiteSpace([string]$Cached.Info.Model)) { $null } else { $Cached.Info })
            }
        }

        # Field-name regexes only match JSON object keys. Quotes copied into a
        # prompt are escaped, so conversation text is not interpreted as model
        # metadata. Read at most 4 MB from the physical tail. Get-Content -Tail
        # can materialize several enormous JSONL records and previously allowed
        # optional model detection to block the entire status report.
        $ModelRegex = [regex]'"(?:model|modelID|modelId|modelName)"\s*:\s*"(?<value>[^"\\]+)"'
        $ProviderRegex = [regex]'"(?:provider|providerID|providerId|model_provider_id)"\s*:\s*"(?<value>[^"\\]+)"'
        $Lines = @(Get-BoundedUtf8TailLines -Path $Path)
        $Result = [PSCustomObject]@{ Model = ''; Provider = '' }
        for ($Index = $Lines.Count - 1; $Index -ge 0; $Index--) {
            $Line = [string]$Lines[$Index]
            if ($AgentName.Equals('claude', [System.StringComparison]::OrdinalIgnoreCase) -and
                $Line -notmatch '"type"\s*:\s*"assistant"') {
                continue
            }
            if ($AgentName.Equals('codex', [System.StringComparison]::OrdinalIgnoreCase) -and
                $Line -notmatch '"type"\s*:\s*"turn_context"') {
                continue
            }
            $ModelMatches = $ModelRegex.Matches($Line)
            if ($ModelMatches.Count -eq 0) {
                continue
            }
            # The event's own model field precedes nested tool-call arguments.
            # Choosing the first match avoids reporting a model mentioned by a
            # tool invocation as the model that ran the session.
            $Result.Model = [string]$ModelMatches[0].Groups['value'].Value
            $ProviderMatches = $ProviderRegex.Matches($Line)
            if ($ProviderMatches.Count -gt 0) {
                $Result.Provider = [string]$ProviderMatches[0].Groups['value'].Value
            }
            break
        }
        $Script:StatusModelCache[$CacheKey] = [PSCustomObject]@{
            Length = [long]$File.Length
            LastWriteTicks = [long]$File.LastWriteTimeUtc.Ticks
            Info = $Result
        }
        return $(if ([string]::IsNullOrWhiteSpace([string]$Result.Model)) { $null } else { $Result })
    }
    catch {
    }

    return $null
}

function Initialize-AgentSyncNativeSqlite {
    if ('AgentSyncNativeSqlite' -as [type]) {
        return $true
    }

    try {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class AgentSyncNativeSqlite
{
    private const int SQLITE_OK = 0;
    private const int SQLITE_ROW = 100;
    private const int SQLITE_DONE = 101;
    private const int SQLITE_OPEN_READONLY = 0x00000001;

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int OpenV2(IntPtr filename, out IntPtr database, int flags, IntPtr vfs);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int PrepareV2(IntPtr database, IntPtr sql, int bytes, out IntPtr statement, IntPtr tail);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int Step(IntPtr statement);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate IntPtr ColumnBlob(IntPtr statement, int column);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int ColumnBytes(IntPtr statement, int column);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int FinalizeStatement(IntPtr statement);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int CloseV2(IntPtr database);

    private static IntPtr AllocateUtf8(string value)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(value + "\0");
        IntPtr pointer = Marshal.AllocHGlobal(bytes.Length);
        Marshal.Copy(bytes, 0, pointer, bytes.Length);
        return pointer;
    }

    private static IntPtr LoadSqlite()
    {
        string[] names;
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            names = new[] { "winsqlite3.dll", "sqlite3.dll" };
        else if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX))
            names = new[] { "libsqlite3.dylib", "/usr/lib/libsqlite3.dylib" };
        else
            names = new[] { "libsqlite3.so.0", "libsqlite3.so" };

        foreach (string name in names)
        {
            IntPtr library;
            if (NativeLibrary.TryLoad(name, out library))
                return library;
        }
        throw new DllNotFoundException("A native SQLite library was not available.");
    }

    public static byte[][] QueryBlobsReadOnly(string databasePath, string sql)
    {
        IntPtr library = IntPtr.Zero;
        IntPtr database = IntPtr.Zero;
        IntPtr statement = IntPtr.Zero;
        IntPtr pathPointer = IntPtr.Zero;
        IntPtr sqlPointer = IntPtr.Zero;
        try
        {
            library = LoadSqlite();
            OpenV2 open = (OpenV2)Marshal.GetDelegateForFunctionPointer(
                NativeLibrary.GetExport(library, "sqlite3_open_v2"), typeof(OpenV2));
            PrepareV2 prepare = (PrepareV2)Marshal.GetDelegateForFunctionPointer(
                NativeLibrary.GetExport(library, "sqlite3_prepare_v2"), typeof(PrepareV2));
            Step step = (Step)Marshal.GetDelegateForFunctionPointer(
                NativeLibrary.GetExport(library, "sqlite3_step"), typeof(Step));
            ColumnBlob columnBlob = (ColumnBlob)Marshal.GetDelegateForFunctionPointer(
                NativeLibrary.GetExport(library, "sqlite3_column_blob"), typeof(ColumnBlob));
            ColumnBytes columnBytes = (ColumnBytes)Marshal.GetDelegateForFunctionPointer(
                NativeLibrary.GetExport(library, "sqlite3_column_bytes"), typeof(ColumnBytes));
            FinalizeStatement finalize = (FinalizeStatement)Marshal.GetDelegateForFunctionPointer(
                NativeLibrary.GetExport(library, "sqlite3_finalize"), typeof(FinalizeStatement));
            CloseV2 close = (CloseV2)Marshal.GetDelegateForFunctionPointer(
                NativeLibrary.GetExport(library, "sqlite3_close_v2"), typeof(CloseV2));

            pathPointer = AllocateUtf8(databasePath);
            int result = open(pathPointer, out database, SQLITE_OPEN_READONLY, IntPtr.Zero);
            if (result != SQLITE_OK || database == IntPtr.Zero)
                throw new InvalidOperationException("SQLite read-only open failed with code " + result + ".");

            sqlPointer = AllocateUtf8(sql);
            result = prepare(database, sqlPointer, -1, out statement, IntPtr.Zero);
            if (result != SQLITE_OK || statement == IntPtr.Zero)
                throw new InvalidOperationException("SQLite prepare failed with code " + result + ".");

            List<byte[]> values = new List<byte[]>();
            while ((result = step(statement)) == SQLITE_ROW)
            {
                int length = columnBytes(statement, 0);
                IntPtr blob = columnBlob(statement, 0);
                if (length <= 0 || blob == IntPtr.Zero)
                    continue;
                byte[] value = new byte[length];
                Marshal.Copy(blob, value, 0, length);
                values.Add(value);
            }
            if (result != SQLITE_DONE)
                throw new InvalidOperationException("SQLite step failed with code " + result + ".");

            finalize(statement);
            statement = IntPtr.Zero;
            close(database);
            database = IntPtr.Zero;
            return values.ToArray();
        }
        finally
        {
            if (statement != IntPtr.Zero && library != IntPtr.Zero)
            {
                try
                {
                    FinalizeStatement finalize = (FinalizeStatement)Marshal.GetDelegateForFunctionPointer(
                        NativeLibrary.GetExport(library, "sqlite3_finalize"), typeof(FinalizeStatement));
                    finalize(statement);
                }
                catch { }
            }
            if (database != IntPtr.Zero && library != IntPtr.Zero)
            {
                try
                {
                    CloseV2 close = (CloseV2)Marshal.GetDelegateForFunctionPointer(
                        NativeLibrary.GetExport(library, "sqlite3_close_v2"), typeof(CloseV2));
                    close(database);
                }
                catch { }
            }
            if (pathPointer != IntPtr.Zero) Marshal.FreeHGlobal(pathPointer);
            if (sqlPointer != IntPtr.Zero) Marshal.FreeHGlobal(sqlPointer);
            if (library != IntPtr.Zero) NativeLibrary.Free(library);
        }
    }
}
'@ -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Get-StatusAntigravityDatabaseModelInfo {
    param ([string]$DatabasePath)

    if (-not (Test-Path -LiteralPath $DatabasePath -PathType Leaf)) {
        return $null
    }

    try {
        $File = Get-Item -LiteralPath $DatabasePath -ErrorAction Stop
        if ([string]$File.Attributes -match 'Offline|RecallOnDataAccess|RecallOnOpen') {
            return $null
        }
        $CacheKey = "antigravity-model|$($File.FullName)"
        if ($Script:StatusModelCache.ContainsKey($CacheKey)) {
            $Cached = $Script:StatusModelCache[$CacheKey]
            if ($Cached.Length -eq $File.Length -and $Cached.LastWriteTicks -eq $File.LastWriteTimeUtc.Ticks) {
                return $(if ([string]::IsNullOrWhiteSpace([string]$Cached.Info.Model)) { $null } else { $Cached.Info })
            }
        }

        $Result = [PSCustomObject]@{ Model = ''; Provider = '' }
        if (Initialize-AgentSyncNativeSqlite) {
            $Blobs = [AgentSyncNativeSqlite]::QueryBlobsReadOnly(
                $File.FullName,
                'SELECT data FROM executor_metadata ORDER BY idx DESC')
            $ModelPattern = [regex]'(?i)(?<model>(?:gemini|claude|gpt|deepseek|kimi|llama|qwen|mistral)[-_/][A-Za-z0-9._/-]{2,80})'
            foreach ($Blob in @($Blobs)) {
                $Text = [System.Text.Encoding]::Latin1.GetString($Blob)
                foreach ($Match in $ModelPattern.Matches($Text)) {
                    $Candidate = [string]$Match.Groups['model'].Value
                    if ($Candidate -notmatch '\d') {
                        continue
                    }
                    $Result.Model = $Candidate
                    $Result.Provider = switch -Regex ($Candidate) {
                        '^gemini[-_/]' { 'google'; break }
                        '^claude[-_/]' { 'anthropic'; break }
                        '^gpt[-_/]' { 'openai'; break }
                        default { '' }
                    }
                    break
                }
                if ($Result.Model) {
                    break
                }
            }
        }

        $Script:StatusModelCache[$CacheKey] = [PSCustomObject]@{
            Length = [long]$File.Length
            LastWriteTicks = [long]$File.LastWriteTimeUtc.Ticks
            Info = $Result
        }
        return $(if ([string]::IsNullOrWhiteSpace([string]$Result.Model)) { $null } else { $Result })
    }
    catch {
        # Stable fallback: model metadata is optional. If Antigravity changes
        # its schema or SQLite is unavailable, keep today's "Ikke registrert".
        return $null
    }
}

function Complete-StatusAgentMetric {
    param (
        $Metric,
        [string]$AgentName
    )

    $Metric.Sessions = $Metric.SessionIds.Count
    if ([string]::IsNullOrWhiteSpace([string]$Metric.Model)) {
        foreach ($Candidate in @($Metric.ModelCandidates | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 2)) {
            $Info = Get-StatusJsonlModelInfo -Path ([string]$Candidate.Path) -AgentName $AgentName
            if (-not $Info -or [string]::IsNullOrWhiteSpace([string]$Info.Model)) {
                continue
            }
            $Metric.Model = [string]$Info.Model
            $Metric.Provider = [string]$Info.Provider
            $Metric.ModelSeenUtc = [System.DateTimeOffset]$Candidate.LastWriteTimeUtc
            break
        }
    }

    $Metric.Newest = ConvertTo-StatusTime -Value $(if ($Metric.NewestUtc) { $Metric.NewestUtc.ToString('o') } else { $null })
    $Metric.PSObject.Properties.Remove('SessionIds')
    $Metric.PSObject.Properties.Remove('ModelCandidates')
}

function Get-ConfiguredAgent {
    param ([string]$Name)

    return @(
        $Config.agents |
            Where-Object { ([string]$_.name).Equals($Name, [System.StringComparison]::OrdinalIgnoreCase) }
    ) | Select-Object -First 1
}

function Resolve-StatusAgentProject {
    param (
        [string]$Cwd,
        [string]$StorageProjectRoot
    )

    if ([string]::IsNullOrWhiteSpace($Cwd)) {
        return $null
    }

    $CwdPath = $Cwd
    if ($Cwd -match '^file://') {
        try {
            $CwdPath = ([System.Uri]$Cwd).LocalPath
        }
        catch {
            $CwdPath = $Cwd
        }
    }

    try {
        $CwdPath = [System.Uri]::UnescapeDataString($CwdPath)
    }
    catch {
    }
    $CwdPath = Remove-AgentInternalWorkspaceSuffix -Path $CwdPath

    $Resolved = $null
    try {
        $Resolved = Expand-ConfiguredPath -Path $CwdPath
    }
    catch {
    }

    $ProjectPath = $null
    if ($Resolved -and (Test-PathInside -ChildPath $Resolved -ParentPath $ProjectsBasePath)) {
        $ProjectPath = [System.IO.Path]::GetFullPath($Resolved).TrimEnd('\', '/')
    }

    # An alias points at a local clone outside Dropbox, or at what a folder
    # was called before it was renamed. A path that resolved inside the tree
    # but no longer exists is therefore worth a second look. Preserve any
    # subdirectory below the alias when mapping it back to the shared tree.
    if ($Resolved -and $Config.projectAliases -and
        (-not $ProjectPath -or -not (Test-Path -LiteralPath $ProjectPath -PathType Container))) {
        foreach ($Property in $Config.projectAliases.PSObject.Properties) {
            foreach ($Alias in @($Property.Value)) {
                try {
                    $AliasPath = Expand-ConfiguredPath -Path ([string]$Alias)
                }
                catch {
                    continue
                }

                if (-not (Test-PathInside -ChildPath $Resolved -ParentPath $AliasPath)) {
                    continue
                }

                $AliasRelative = Get-RelativeChildPath -BasePath $AliasPath -FullPath $Resolved
                $SharedAliasRoot = Join-Path $ProjectsBasePath ([string]$Property.Name)
                $ProjectPath = if ([string]::IsNullOrWhiteSpace($AliasRelative)) {
                    $SharedAliasRoot
                }
                else {
                    Join-Path $SharedAliasRoot $AliasRelative
                }
                break
            }
            if ($ProjectPath) {
                break
            }
        }
    }

    # State copied from another operating system may contain a path that cannot
    # be expanded on this machine. The enclosing state project is still known,
    # so recover the exact suffix below that project (including subprojects).
    if (-not $ProjectPath -and -not [string]::IsNullOrWhiteSpace($StorageProjectRoot)) {
        try {
            $StorageRoot = [System.IO.Path]::GetFullPath($StorageProjectRoot).TrimEnd('\', '/')
            $StorageName = Split-Path $StorageRoot -Leaf
            $Segments = @($CwdPath -replace '\\', '/' -split '/' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $StorageIndex = -1
            for ($Index = 0; $Index -lt $Segments.Count; $Index++) {
                if ($Segments[$Index].Equals($StorageName, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $StorageIndex = $Index
                }
            }

            if ($StorageIndex -ge 0) {
                $ProjectPath = $StorageRoot
                for ($Index = $StorageIndex + 1; $Index -lt $Segments.Count; $Index++) {
                    $ProjectPath = Join-Path $ProjectPath $Segments[$Index]
                }
            }
        }
        catch {
            $ProjectPath = $null
        }
    }

    if (-not $ProjectPath -or -not (Test-PathInside -ChildPath $ProjectPath -ParentPath $ProjectsBasePath)) {
        return $null
    }

    $Relative = Get-RelativeChildPath -BasePath $ProjectsBasePath -FullPath $ProjectPath
    if ([string]::IsNullOrWhiteSpace($Relative)) {
        return $null
    }

    $NormalizedRelative = $Relative -replace '/', '\'
    return [PSCustomObject]@{
        Key = $NormalizedRelative
        Project = $NormalizedRelative -replace '\\', ' / '
        ProjectPath = [System.IO.Path]::GetFullPath($ProjectPath).TrimEnd('\', '/')
    }
}

function Get-StatusStorageMachines {
    param ([string]$StateRoot)

    $ManifestPath = Join-Path $StateRoot 'manifest.json'
    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        return @()
    }

    try {
        $Manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
        if ($Manifest.machines) {
            return @($Manifest.machines.PSObject.Properties.Name)
        }
    }
    catch {
    }

    return @()
}

function Test-CanonicalStorageProject {
    param (
        [string]$Cwd,
        [string]$StorageProjectRoot,
        $Identity
    )

    if ([string]::IsNullOrWhiteSpace($Cwd) -or [string]::IsNullOrWhiteSpace($StorageProjectRoot)) {
        return $true
    }

    # The status collector has already resolved this exact pair. Reuse that
    # result for this call only; standalone callers still resolve as before.
    if (-not $PSBoundParameters.ContainsKey('Identity')) {
        $Identity = Resolve-StatusAgentProject -Cwd $Cwd -StorageProjectRoot $StorageProjectRoot
    }
    if (-not $Identity -or (Test-SamePath -Left $Identity.ProjectPath -Right $StorageProjectRoot)) {
        return $true
    }

    # v3.2 and older grouped state in a direct child of sharedProjectsDir.
    # Keep that data untouched as a fallback, but ignore the legacy duplicate
    # after the same agent data has reached its exact cwd-based project root.
    $CanonicalStateRoot = Join-Path $Identity.ProjectPath '.agent-state'
    return -not (Test-Path -LiteralPath $CanonicalStateRoot -PathType Container)
}

function Add-StatusAgentFiles {
    param (
        $ProjectMap,
        [string]$Cwd,
        [string]$StorageProjectRoot,
        [string]$AgentName,
        [System.Collections.IEnumerable]$Files,
        [string[]]$Machines,
        [string]$SessionId,
        $ModelInfo
    )

    $FileArray = @($Files)
    if ($FileArray.Count -eq 0) {
        return $false
    }

    $Identity = Resolve-StatusAgentProject -Cwd $Cwd -StorageProjectRoot $StorageProjectRoot
    if (-not $Identity) {
        return $false
    }

    if (-not (Test-CanonicalStorageProject -Cwd $Cwd -StorageProjectRoot $StorageProjectRoot -Identity $Identity)) {
        return $true
    }

    if (-not $ProjectMap.ContainsKey($Identity.Key)) {
        $ProjectMap[$Identity.Key] = [PSCustomObject]@{
            Project = $Identity.Project
            ProjectPath = $Identity.ProjectPath
            Claude = New-StatusAgentMetric
            Codex = New-StatusAgentMetric
            Antigravity = New-StatusAgentMetric
            OpenCode = New-StatusAgentMetric
            Cline = New-StatusAgentMetric
            Aider = New-StatusAgentMetric
            MachineSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        }
    }

    $Row = $ProjectMap[$Identity.Key]
    $Metric = switch ($AgentName.ToLowerInvariant()) {
        'claude' { $Row.Claude; break }
        'codex' { $Row.Codex; break }
        'antigravity' { $Row.Antigravity; break }
        'opencode' { $Row.OpenCode; break }
        'cline' { $Row.Cline; break }
        'aider' { $Row.Aider; break }
        default { $null }
    }
    if (-not $Metric) {
        return $false
    }

    if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
        [void]$Metric.SessionIds.Add($SessionId)
    }

    foreach ($File in $FileArray) {
        $Metric.Files++
        $Metric.Bytes += [long]$File.Length
        $FileTime = [System.DateTimeOffset]$File.LastWriteTimeUtc
        if ($null -eq $Metric.NewestUtc -or $FileTime -gt $Metric.NewestUtc) {
            $Metric.NewestUtc = $FileTime
        }

        $IsModelCandidate = switch ($AgentName.ToLowerInvariant()) {
            'claude' { $File.Extension.Equals('.jsonl', [System.StringComparison]::OrdinalIgnoreCase); break }
            'codex' { $File.Extension.Equals('.jsonl', [System.StringComparison]::OrdinalIgnoreCase); break }
            'antigravity' { $false; break }
            'cline' { $false; break }
            default { $false }
        }
        if ($IsModelCandidate) {
            [void]$Metric.ModelCandidates.Add([PSCustomObject]@{
                Path = $File.FullName
                LastWriteTimeUtc = $FileTime
            })
        }
    }

    if ($ModelInfo -and -not [string]::IsNullOrWhiteSpace([string]$ModelInfo.Model)) {
        $ModelTime = @($FileArray | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).LastWriteTimeUtc
        if ($null -eq $Metric.ModelSeenUtc -or [System.DateTimeOffset]$ModelTime -ge $Metric.ModelSeenUtc) {
            $Metric.Model = [string]$ModelInfo.Model
            $Metric.Provider = [string]$ModelInfo.Provider
            $Metric.ModelSeenUtc = [System.DateTimeOffset]$ModelTime
        }
    }

    foreach ($Machine in @($Machines)) {
        if (-not [string]::IsNullOrWhiteSpace($Machine)) {
            [void]$Row.MachineSet.Add($Machine)
        }
    }

    return $true
}

function Get-StatusAntigravityWorkspace {
    param (
        [string]$SessionRoot,
        [string]$WorkspaceIndexPath
    )

    if (-not [string]::IsNullOrWhiteSpace($WorkspaceIndexPath) -and (Test-Path -LiteralPath $WorkspaceIndexPath)) {
        try {
            $Index = Get-Content -LiteralPath $WorkspaceIndexPath -Raw | ConvertFrom-Json
            if (-not [string]::IsNullOrWhiteSpace([string]$Index.workspace)) {
                return [string]$Index.workspace
            }
        }
        catch {
        }
    }

    $HistoryPath = Join-Path $SessionRoot 'history.jsonl'
    if (-not (Test-Path -LiteralPath $HistoryPath)) {
        return $null
    }

    $Reader = $null
    $Workspace = $null
    $LatestTimestamp = [long]::MinValue
    try {
        $Reader = New-SharedStreamReader -Path $HistoryPath
        while (-not $Reader.EndOfStream) {
            $Line = $Reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($Line)) {
                continue
            }

            try {
                $Object = $Line | ConvertFrom-Json
            }
            catch {
                continue
            }

            $Candidate = [string]$Object.workspace
            if ([string]::IsNullOrWhiteSpace($Candidate)) {
                continue
            }

            $Timestamp = Get-AntigravityTimestamp -Object $Object
            if ($null -eq $Workspace -or $Timestamp -ge $LatestTimestamp) {
                $Workspace = $Candidate
                $LatestTimestamp = $Timestamp
            }
        }
    }
    catch {
        return $null
    }
    finally {
        if ($Reader) {
            $Reader.Dispose()
        }
    }

    return $Workspace
}

function Get-StatusAiderModelInfo {
    param ([string]$ChatPath)

    if ([string]::IsNullOrWhiteSpace($ChatPath) -or -not (Test-Path -LiteralPath $ChatPath -PathType Leaf)) {
        return $null
    }

    $Reader = $null
    try {
        $Reader = New-SharedStreamReader -Path $ChatPath
        $LinesRead = 0
        while (-not $Reader.EndOfStream -and $LinesRead -lt 128) {
            $Line = $Reader.ReadLine()
            $LinesRead++
            if ($Line -notmatch '^\s*>\s*Model:\s*(?<model>.+?)(?:\s+with\s+.+)?\s*$') {
                continue
            }

            $Model = [string]$Matches.model
            $Provider = if ($Model -match '^(?<provider>[^/]+)/') { [string]$Matches.provider } else { '' }
            return [PSCustomObject]@{ Model = $Model; Provider = $Provider }
        }
    }
    catch {
        return $null
    }
    finally {
        if ($Reader) { $Reader.Dispose() }
    }
    return $null
}

function Write-AgentSyncStatusTrace {
    param ([string]$Message)

    if ($env:AGENTSYNC_STATUS_TRACE -eq '1') {
        Write-Host ("{0:HH:mm:ss.fff} STATUS_TRACE {1}" -f (Get-Date), $Message) -ForegroundColor DarkGray
    }
}

function Get-AgentDerivedStatusData {
    $StatusPhaseWatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-AgentSyncStatusTrace -Message 'derived-start'
    $ProjectMap = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $ConflictCount = 0
    $UnresolvedFiles = 0
    $StorageProjects = @(Get-AgentSyncProjects)
    Write-AgentSyncStatusTrace -Message "storage-projects=$($StorageProjects.Count)"

    $ClaudeAgent = Get-ConfiguredAgent -Name 'claude'
    $CodexAgents = @(
        $Config.agents |
            Where-Object { ([string]$_.routingMode).Equals('codex', [System.StringComparison]::OrdinalIgnoreCase) }
    )
    $AntigravityAgent = Get-ConfiguredAgent -Name 'antigravity'
    $OpenCodeAgent = Get-ConfiguredAgent -Name 'opencode'
    $ClineAgent = Get-ConfiguredAgent -Name 'cline'
    $ClaudeKnownWorkspaces = $null
    if ($ClaudeAgent) {
        $LocalClaudeRoot = Get-PlatformConfiguredPath -Object $ClaudeAgent
        $ClaudeKnownWorkspaces = Get-ClaudeKnownWorkspaceMap -LocalRoot $LocalClaudeRoot
        Write-AgentSyncStatusTrace -Message "claude-workspace-map=$($ClaudeKnownWorkspaces.Count)"
    }
    $LocalAntigravityWorkspaces = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # Antigravity may know a workspace only through last_conversations.json.
    # Include that native index so a conversation with no history lines is not
    # omitted from the status report.
    if ($AntigravityAgent) {
        foreach ($RootConfig in @($AntigravityAgent.roots)) {
            $SurfaceName = [string]$RootConfig.surface
            $LocalRoot = Get-PlatformConfiguredPath -Object $RootConfig
            if (-not $LocalRoot -or -not (Test-Path -LiteralPath $LocalRoot)) {
                continue
            }

            foreach ($Group in @(Get-AntigravityHistoryGroups -LocalRoot $LocalRoot)) {
                if ([string]::IsNullOrWhiteSpace([string]$Group.ConversationId) -or
                    [string]::IsNullOrWhiteSpace([string]$Group.Workspace)) {
                    continue
                }
                $LocalAntigravityWorkspaces["$SurfaceName|$($Group.ConversationId)"] = [string]$Group.Workspace
            }
        }
    }
    Write-AgentSyncStatusTrace -Message "antigravity-workspace-map=$($LocalAntigravityWorkspaces.Count)"
    Write-AgentSyncLog -Level 'DEBUG' -Message "STATUS_PHASE phase=discovery durationMs=$($StatusPhaseWatch.ElapsedMilliseconds) projects=$($StorageProjects.Count)"
    $StatusPhaseWatch.Restart()

    foreach ($StorageProject in $StorageProjects) {
        $ProjectStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        Write-AgentSyncStatusTrace -Message "project-start path=$($StorageProject.FullName)"
        $StateRoot = Join-Path $StorageProject.FullName '.agent-state'
        if (-not (Test-Path -LiteralPath $StateRoot)) {
            continue
        }

        $Machines = @(Get-StatusStorageMachines -StateRoot $StateRoot)
        $ConflictRoot = Join-Path $StateRoot 'conflicts'
        if (Test-Path -LiteralPath $ConflictRoot) {
            $ConflictCount += @(Get-ChildItem -LiteralPath $ConflictRoot -Recurse -File -ErrorAction SilentlyContinue).Count
        }

        if ($ClaudeAgent) {
            $ClaudeRoot = Join-Path $StorageProject.FullName ([string]$ClaudeAgent.targetSubDir)
            $ClaudeFilters = Get-AgentFileFilters -Agent $ClaudeAgent
            if (Test-Path -LiteralPath $ClaudeRoot) {
                foreach ($Bucket in Get-ChildItem -LiteralPath $ClaudeRoot -Directory -ErrorAction SilentlyContinue) {
                    $Files = @(
                        Get-ChildItem -LiteralPath $Bucket.FullName -Recurse -File -ErrorAction SilentlyContinue |
                            Where-Object {
                                -not (Test-IsConflictCopyName -Name $_.Name) -and
                                (Test-RelativePathMatchesFilter -RelativePath (Get-RelativeChildPath -BasePath $Bucket.FullName -FullPath $_.FullName) -Filters $ClaudeFilters)
                            }
                    )

                    # Attribute every Claude session/subagent to its own cwd.
                    # One native Claude bucket can contain subagents working in
                    # several exact subfolders, which must become separate rows.
                    $FileCwds = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                    $ParentSessionCwds = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                    $DefaultCwd = $null
                    foreach ($File in @($Files | Where-Object { $_.Extension.Equals('.jsonl', [System.StringComparison]::OrdinalIgnoreCase) })) {
                        $Cwd = Get-SessionCwd -Path $File.FullName
                        if ([string]::IsNullOrWhiteSpace($Cwd)) {
                            continue
                        }
                        $FileCwds[$File.FullName] = $Cwd
                        $Relative = Get-RelativeChildPath -BasePath $Bucket.FullName -FullPath $File.FullName
                        if ($Relative -and $Relative -notmatch '[\\/]') {
                            $ParentSessionCwds[[System.IO.Path]::GetFileNameWithoutExtension($Relative)] = $Cwd
                            if ([string]::IsNullOrWhiteSpace($DefaultCwd)) {
                                $DefaultCwd = $Cwd
                            }
                        }
                        elseif ([string]::IsNullOrWhiteSpace($DefaultCwd)) {
                            $DefaultCwd = $Cwd
                        }
                    }

                    if ($ClaudeKnownWorkspaces -and $ClaudeKnownWorkspaces.ContainsKey($Bucket.Name)) {
                        $DefaultCwd = [string]$ClaudeKnownWorkspaces[$Bucket.Name]
                    }

                    foreach ($File in $Files) {
                        $Cwd = $null
                        if ($FileCwds.ContainsKey($File.FullName)) {
                            $Cwd = [string]$FileCwds[$File.FullName]
                        }
                        else {
                            $Relative = Get-RelativeChildPath -BasePath $Bucket.FullName -FullPath $File.FullName
                            $FirstSegment = if ($Relative) { @($Relative -split '[\\/]')[0] } else { $null }
                            if ($FirstSegment -and $ParentSessionCwds.ContainsKey($FirstSegment)) {
                                $Cwd = [string]$ParentSessionCwds[$FirstSegment]
                            }
                            else {
                                $Cwd = $DefaultCwd
                            }
                        }

                        $SessionId = $null
                        if ($File.Extension.Equals('.jsonl', [System.StringComparison]::OrdinalIgnoreCase)) {
                            $SessionRelative = Get-RelativeChildPath -BasePath $Bucket.FullName -FullPath $File.FullName
                            $SessionFirstSegment = @($SessionRelative -split '[\\/]')[0]
                            $SessionId = [System.IO.Path]::GetFileNameWithoutExtension($SessionFirstSegment)
                        }
                        if (-not (Add-StatusAgentFiles -ProjectMap $ProjectMap -Cwd $Cwd -StorageProjectRoot $StorageProject.FullName -AgentName 'claude' -Files @($File) -Machines $Machines -SessionId $SessionId)) {
                            $UnresolvedFiles++
                        }
                    }
                }
            }
        }

        foreach ($CodexAgent in $CodexAgents) {
            $CodexRoot = Join-Path $StorageProject.FullName ([string]$CodexAgent.targetSubDir)
            $CodexFilters = Get-AgentFileFilters -Agent $CodexAgent
            if (Test-Path -LiteralPath $CodexRoot) {
                $Files = Get-ChildItem -LiteralPath $CodexRoot -Recurse -File -ErrorAction SilentlyContinue |
                    Where-Object {
                        -not (Test-IsConflictCopyName -Name $_.Name) -and
                        (Test-RelativePathMatchesFilter -RelativePath (Get-RelativeChildPath -BasePath $CodexRoot -FullPath $_.FullName) -Filters $CodexFilters)
                    }
                foreach ($File in $Files) {
                    $Cwd = Get-SessionCwd -Path $File.FullName
                    $SessionId = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
                    if (-not (Add-StatusAgentFiles -ProjectMap $ProjectMap -Cwd $Cwd -StorageProjectRoot $StorageProject.FullName -AgentName 'codex' -Files @($File) -Machines $Machines -SessionId $SessionId)) {
                        $UnresolvedFiles++
                    }
                }
            }
        }

        if ($AntigravityAgent) {
            $AntigravityRoot = Join-Path $StorageProject.FullName ([string]$AntigravityAgent.targetSubDir)
            if (Test-Path -LiteralPath $AntigravityRoot) {
                foreach ($Surface in Get-ChildItem -LiteralPath $AntigravityRoot -Directory -ErrorAction SilentlyContinue) {
                    $SessionsRoot = Join-Path $Surface.FullName 'sessions'
                    if (-not (Test-Path -LiteralPath $SessionsRoot)) {
                        continue
                    }

                    foreach ($Session in Get-ChildItem -LiteralPath $SessionsRoot -Directory -ErrorAction SilentlyContinue) {
                        $WorkspaceIndexPath = Join-Path (Join-Path (Join-Path $StateRoot 'index\antigravity-workspaces') $Surface.Name) "$($Session.Name).json"
                        $Workspace = Get-StatusAntigravityWorkspace -SessionRoot $Session.FullName -WorkspaceIndexPath $WorkspaceIndexPath
                        if ([string]::IsNullOrWhiteSpace($Workspace)) {
                            $WorkspaceKey = "$($Surface.Name)|$($Session.Name)"
                            if ($LocalAntigravityWorkspaces.ContainsKey($WorkspaceKey)) {
                                $Workspace = $LocalAntigravityWorkspaces[$WorkspaceKey]
                            }
                        }
                        $Files = @(
                            Get-ChildItem -LiteralPath $Session.FullName -Recurse -File -ErrorAction SilentlyContinue |
                                Where-Object { -not (Test-IsConflictCopyName -Name $_.Name) }
                        )
                        $Database = @($Files | Where-Object {
                            $_.Extension.Equals('.db', [System.StringComparison]::OrdinalIgnoreCase) -and
                            [System.IO.Path]::GetFileNameWithoutExtension($_.Name).Equals($Session.Name, [System.StringComparison]::OrdinalIgnoreCase)
                        } | Select-Object -First 1)
                        $ModelInfo = if ($Database.Count -gt 0) {
                            Get-StatusAntigravityDatabaseModelInfo -DatabasePath $Database[0].FullName
                        }
                        else {
                            $null
                        }
                        if (-not (Add-StatusAgentFiles -ProjectMap $ProjectMap -Cwd $Workspace -StorageProjectRoot $StorageProject.FullName -AgentName 'antigravity' -Files @($Files) -Machines $Machines -SessionId $Session.Name -ModelInfo $ModelInfo)) {
                            $UnresolvedFiles += $Files.Count
                        }
                    }
                }
            }
        }

        if ($ClineAgent) {
            $ClineRoot = Join-Path $StorageProject.FullName ([string]$ClineAgent.targetSubDir)
            if (Test-Path -LiteralPath $ClineRoot -PathType Container) {
                foreach ($Surface in @(Get-ChildItem -LiteralPath $ClineRoot -Directory -ErrorAction SilentlyContinue)) {
                    $SessionsRoot = Join-Path $Surface.FullName 'sessions'
                    if (-not (Test-Path -LiteralPath $SessionsRoot -PathType Container)) { continue }
                    foreach ($Session in @(Get-ChildItem -LiteralPath $SessionsRoot -Directory -ErrorAction SilentlyContinue)) {
                        if (-not (Test-SafeSessionId -Id $Session.Name)) { continue }
                        $WorkspaceIndexPath = Join-Path $StateRoot "index/cline-workspaces/$($Surface.Name)/$($Session.Name).json"
                        $Info = Get-ClineStoredSessionInfo -SessionRoot $Session.FullName -WorkspaceIndexPath $WorkspaceIndexPath -SessionId $Session.Name
                        $Files = @(Get-ChildItem -LiteralPath $Session.FullName -Recurse -File -ErrorAction SilentlyContinue |
                            Where-Object { -not (Test-IsConflictCopyName -Name $_.Name) })
                        $ModelInfo = if ($Info) { [PSCustomObject]@{ Model = $Info.Model; Provider = $Info.Provider } } else { $null }
                        if (-not (Add-StatusAgentFiles -ProjectMap $ProjectMap -Cwd $(if ($Info) { $Info.Workspace } else { $null }) -StorageProjectRoot $StorageProject.FullName -AgentName 'cline' -Files @($Files) -Machines $Machines -SessionId $Session.Name -ModelInfo $ModelInfo)) {
                            $UnresolvedFiles += $Files.Count
                        }
                    }
                }
            }
        }

        if ($OpenCodeAgent) {
            $OpenCodeRoot = Join-Path $StorageProject.FullName ([string]$OpenCodeAgent.targetSubDir)
            if (Test-Path -LiteralPath $OpenCodeRoot -PathType Container) {
                foreach ($File in @(Get-ChildItem -LiteralPath $OpenCodeRoot -File -Filter '*.json' -ErrorAction SilentlyContinue |
                    Where-Object { -not (Test-IsConflictCopyName -Name $_.Name) })) {
                    $Info = Get-OpenCodeExportInfo -Path $File.FullName
                    $Cwd = if ($Info) { [string]$Info.Directory } else { $null }
                    $SessionId = if ($Info) { [string]$Info.Id } else { [System.IO.Path]::GetFileNameWithoutExtension($File.Name) }
                    if (-not (Add-StatusAgentFiles -ProjectMap $ProjectMap -Cwd $Cwd -StorageProjectRoot $StorageProject.FullName -AgentName 'opencode' -Files @($File) -Machines $Machines -SessionId $SessionId -ModelInfo $Info)) {
                        $UnresolvedFiles++
                    }
                }
            }
        }

        # Aider has no separate native state adapter. AgentSync starts it with
        # project-local chat/LLM history files, so those files already belong
        # to this exact storage project.
        $AiderRoot = Join-Path $StateRoot 'aider'
        if (Test-Path -LiteralPath $AiderRoot -PathType Container) {
            $AiderFiles = @(Get-ChildItem -LiteralPath $AiderRoot -File -ErrorAction SilentlyContinue |
                Where-Object {
                    -not (Test-IsConflictCopyName -Name $_.Name) -and
                    $_.Name -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.(?:chat|llm)\.md$'
                })
            foreach ($Group in @($AiderFiles | Group-Object {
                if ($_.Name -match '^(?<id>.+?)\.(?:chat|llm)\.md$') { $Matches.id }
            })) {
                if (-not (Test-SafeSessionId -Id ([string]$Group.Name))) { continue }
                $ChatFile = @($Group.Group | Where-Object Name -Like '*.chat.md' | Select-Object -First 1)
                $ModelInfo = if ($ChatFile.Count -gt 0) { Get-StatusAiderModelInfo -ChatPath $ChatFile[0].FullName } else { $null }
                if (-not (Add-StatusAgentFiles -ProjectMap $ProjectMap -Cwd $StorageProject.FullName -StorageProjectRoot $StorageProject.FullName -AgentName 'aider' -Files @($Group.Group) -Machines $Machines -SessionId ([string]$Group.Name) -ModelInfo $ModelInfo)) {
                    $UnresolvedFiles += @($Group.Group).Count
                }
            }
        }
        $ProjectStopwatch.Stop()
        Write-AgentSyncStatusTrace -Message "project-done elapsedMs=$($ProjectStopwatch.ElapsedMilliseconds) path=$($StorageProject.FullName)"
    }

    Write-AgentSyncStatusTrace -Message "project-scan-done rows=$($ProjectMap.Count)"
    Write-AgentSyncLog -Level 'DEBUG' -Message "STATUS_PHASE phase=project-scan durationMs=$($StatusPhaseWatch.ElapsedMilliseconds) rows=$($ProjectMap.Count)"
    $StatusPhaseWatch.Restart()
    $Rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($Row in @($ProjectMap.Values | Sort-Object Project)) {
        Complete-StatusAgentMetric -Metric $Row.Claude -AgentName 'claude'
        Complete-StatusAgentMetric -Metric $Row.Codex -AgentName 'codex'
        Complete-StatusAgentMetric -Metric $Row.Antigravity -AgentName 'antigravity'
        Complete-StatusAgentMetric -Metric $Row.OpenCode -AgentName 'opencode'
        Complete-StatusAgentMetric -Metric $Row.Cline -AgentName 'cline'
        Complete-StatusAgentMetric -Metric $Row.Aider -AgentName 'aider'

        $AgentCount = @(@($Row.Claude, $Row.Codex, $Row.Antigravity, $Row.OpenCode, $Row.Cline, $Row.Aider) | Where-Object { $_.Files -gt 0 }).Count
        $TotalFiles = [int]($Row.Claude.Files + $Row.Codex.Files + $Row.Antigravity.Files + $Row.OpenCode.Files + $Row.Cline.Files + $Row.Aider.Files)
        $TotalBytes = [long]($Row.Claude.Bytes + $Row.Codex.Bytes + $Row.Antigravity.Bytes + $Row.OpenCode.Bytes + $Row.Cline.Bytes + $Row.Aider.Bytes)
        $Latest = @($Row.Claude.Newest, $Row.Codex.Newest, $Row.Antigravity.Newest, $Row.OpenCode.Newest, $Row.Cline.Newest, $Row.Aider.Newest) |
            Sort-Object Sort -Descending |
            Select-Object -First 1
        [void]$Rows.Add([PSCustomObject]@{
            Project = $Row.Project
            ProjectPath = $Row.ProjectPath
            AgentCount = $AgentCount
            Claude = $Row.Claude
            Codex = $Row.Codex
            Antigravity = $Row.Antigravity
            OpenCode = $Row.OpenCode
            Cline = $Row.Cline
            Aider = $Row.Aider
            TotalFiles = $TotalFiles
            TotalBytes = $TotalBytes
            Latest = $Latest
            Machines = if ($Row.MachineSet.Count -gt 0) { @($Row.MachineSet | Sort-Object) -join ', ' } else { '-' }
        })
    }

    Write-AgentSyncStatusTrace -Message "derived-done rows=$($Rows.Count)"
    Write-AgentSyncLog -Level 'DEBUG' -Message "STATUS_PHASE phase=summarize durationMs=$($StatusPhaseWatch.ElapsedMilliseconds) rows=$($Rows.Count)"
    return [PSCustomObject]@{
        Rows = $Rows.ToArray()
        Conflicts = $ConflictCount
        UnresolvedFiles = $UnresolvedFiles
    }
}

function Get-StatusCoreHash {
    param ($Value)

    # Pipeline enumeration produces no JSON for an empty audit/project array.
    $Json = ConvertTo-Json -InputObject $Value -Depth 8 -Compress
    $Hasher = [System.Security.Cryptography.SHA256]::Create()
    try {
        $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
        return [System.Convert]::ToHexString($Hasher.ComputeHash($Bytes))
    }
    finally {
        $Hasher.Dispose()
    }
}

function ConvertTo-StatusDetailPayload {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Title,
        [string]$Subtitle,
        [string]$Description,
        [System.Collections.IEnumerable]$Rows
    )

    $NormalizedRows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($Row in @($Rows)) {
        if ($null -eq $Row) {
            continue
        }
        [void]$NormalizedRows.Add([ordered]@{
            label = [string]$Row.Label
            value = [string]$Row.Value
        })
    }

    $Payload = [ordered]@{
        title = $Title
        subtitle = $Subtitle
        description = $Description
        rows = $NormalizedRows.ToArray()
    }
    return ConvertTo-StatusHtml ($Payload | ConvertTo-Json -Depth 5 -Compress)
}

function ConvertTo-StatusAgentDetailPayload {
    param (
        [string]$AgentName,
        $Metric,
        [string]$Machines,
        [string]$ProjectName
    )

    $Model = if ([string]::IsNullOrWhiteSpace([string]$Metric.Model)) { 'Ikke registrert' } else { [string]$Metric.Model }
    $Provider = if ([string]::IsNullOrWhiteSpace([string]$Metric.Provider)) { '-' } else { [string]$Metric.Provider }
    $Rows = New-Object 'System.Collections.Generic.List[object]'
    [void]$Rows.Add([PSCustomObject]@{ Label = 'Sist registrerte modell'; Value = $Model })
    if ($Provider -ne '-') {
        [void]$Rows.Add([PSCustomObject]@{ Label = 'Leverandør'; Value = $Provider })
    }
    [void]$Rows.Add([PSCustomObject]@{ Label = 'Siste aktivitet'; Value = [string]$Metric.Newest.Display })
    [void]$Rows.Add([PSCustomObject]@{ Label = 'Sesjoner'; Value = [string]$Metric.Sessions })
    [void]$Rows.Add([PSCustomObject]@{ Label = 'State-filer'; Value = [string]$Metric.Files })
    [void]$Rows.Add([PSCustomObject]@{ Label = 'Datamengde'; Value = (Format-StatusBytes -Bytes ([long]$Metric.Bytes)) })
    [void]$Rows.Add([PSCustomObject]@{ Label = 'Maskiner i state'; Value = $(if ([string]::IsNullOrWhiteSpace($Machines)) { '-' } else { $Machines }) })

    $Description = if ($AgentName.Equals('Aider', [System.StringComparison]::OrdinalIgnoreCase)) {
        'Prosjektlokal Aider-historikk skrevet direkte av AgentSync. Detaljvisningen viser bare avledet metadata, ikke samtaleinnhold.'
    }
    else {
        'Prosjektkoblet, provider-native historikk. Detaljvisningen viser bare avledet metadata, ikke samtaleinnhold.'
    }

    return ConvertTo-StatusDetailPayload `
        -Title $AgentName `
        -Subtitle $ProjectName `
        -Description $Description `
        -Rows $Rows.ToArray()
}

function ConvertTo-StatusAgentCell {
    param (
        $Metric,
        [string]$AgentName,
        [string]$ProjectName,
        [string]$Machines
    )

    if (-not $Metric -or $Metric.Files -le 0) {
        return '<span class="zero">-</span>'
    }

    $Size = ConvertTo-StatusHtml (Format-StatusBytes -Bytes $Metric.Bytes)
    $DetailPayload = ConvertTo-StatusAgentDetailPayload -AgentName $AgentName -Metric $Metric -Machines $Machines -ProjectName $ProjectName
    $Label = ConvertTo-StatusHtml "Vis $AgentName-detaljer for $ProjectName"
    return "<button type=`"button`" class=`"cell-detail-trigger detail-trigger`" aria-label=`"$Label`" aria-expanded=`"false`" aria-controls=`"detailPopover`" data-detail=`"$DetailPayload`"><strong>$($Metric.Files)</strong><span>$Size</span></button>"
}

function Get-LocalAgentProjectAudit {
    param ([System.Collections.IEnumerable]$ReportRows)

    $ReportSignature = @($ReportRows | ForEach-Object {
        "$($_.ProjectPath)|$($_.Claude.Files -gt 0)|$($_.Codex.Files -gt 0)|$($_.Antigravity.Files -gt 0)|$($_.OpenCode.Files -gt 0)|$($_.Cline.Files -gt 0)|$($_.Aider.Files -gt 0)"
    }) -join "`n"
    $AuditNow = [System.DateTimeOffset]::UtcNow
    if ($Script:LocalAgentAuditCache -and
        $Script:LocalAgentAuditCache.ReportSignature -eq $ReportSignature -and
        (Test-AgentSyncRecentTimestamp -Since $Script:LocalAgentAuditCache.CreatedUtc -WindowSeconds 30 -Now $AuditNow)) {
        return @($Script:LocalAgentAuditCache.Rows)
    }

    $Names = @('Claude', 'Codex', 'Antigravity', 'OpenCode', 'Cline', 'Aider')
    $LocalProjects = @{}
    $ReportProjects = @{}
    $OutsideProjects = @{}
    $UnavailableProjects = @{}
    $NoMetadata = @{}
    foreach ($Name in $Names) {
        $LocalProjects[$Name] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $ReportProjects[$Name] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $OutsideProjects[$Name] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $UnavailableProjects[$Name] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $NoMetadata[$Name] = 0
    }

    foreach ($Row in @($ReportRows)) {
        foreach ($Name in $Names) {
            if ($Row.$Name.Files -le 0) {
                continue
            }
            $Identity = Resolve-StatusAgentProject -Cwd ([string]$Row.ProjectPath) -StorageProjectRoot $null
            if ($Identity) {
                [void]$ReportProjects[$Name].Add([string]$Identity.Key)
            }
        }
    }

    $ClaudeAgent = Get-ConfiguredAgent -Name 'claude'
    if ($ClaudeAgent) {
        $ClaudeRoot = Get-PlatformConfiguredPath -Object $ClaudeAgent
        if ($ClaudeRoot -and (Test-Path -LiteralPath $ClaudeRoot)) {
            $ClaudeKnownWorkspaces = Get-ClaudeKnownWorkspaceMap -LocalRoot $ClaudeRoot
            foreach ($Bucket in @(Get-ChildItem -LiteralPath $ClaudeRoot -Directory -ErrorAction SilentlyContinue)) {
                $JsonlFiles = @(Get-ChildItem -LiteralPath $Bucket.FullName -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue |
                    Where-Object { -not (Test-IsConflictCopyName -Name $_.Name) })
                $BucketHasMetadata = $false
                foreach ($File in $JsonlFiles) {
                    $Cwd = Get-SessionCwd -Path $File.FullName
                    if ([string]::IsNullOrWhiteSpace($Cwd)) {
                        continue
                    }
                    $BucketHasMetadata = $true
                    $Identity = Resolve-StatusAgentProject -Cwd $Cwd -StorageProjectRoot $null
                    if ($Identity) {
                        if (Test-Path -LiteralPath $Identity.ProjectPath -PathType Container) {
                            [void]$LocalProjects['Claude'].Add([string]$Identity.Key)
                        }
                        else {
                            [void]$UnavailableProjects['Claude'].Add([string]$Identity.Key)
                        }
                    }
                    else {
                        try { $OutsideKey = Expand-ConfiguredPath -Path $Cwd } catch { $OutsideKey = $Cwd }
                        [void]$OutsideProjects['Claude'].Add([string]$OutsideKey)
                    }
                }

                # Subagent JSONL files without cwd inherit their parent
                # session/bucket and are not metadata failures. A non-empty
                # artifact-only bucket is resolved through the global slug map.
                if (-not $BucketHasMetadata) {
                    $OtherFiles = @(Get-ChildItem -LiteralPath $Bucket.FullName -Recurse -File -ErrorAction SilentlyContinue |
                        Where-Object { -not (Test-IsConflictCopyName -Name $_.Name) })
                    if ($OtherFiles.Count -gt 0) {
                        $BucketName = [string]$Bucket.Name
                        if ($ClaudeKnownWorkspaces.ContainsKey($BucketName)) {
                            $Cwd = [string]$ClaudeKnownWorkspaces[$BucketName]
                            $Identity = Resolve-StatusAgentProject -Cwd $Cwd -StorageProjectRoot $null
                            if ($Identity) {
                                if (Test-Path -LiteralPath $Identity.ProjectPath -PathType Container) {
                                    [void]$LocalProjects['Claude'].Add([string]$Identity.Key)
                                }
                                else {
                                    [void]$UnavailableProjects['Claude'].Add([string]$Identity.Key)
                                }
                            }
                            else {
                                try { $OutsideKey = Expand-ConfiguredPath -Path $Cwd } catch { $OutsideKey = $Cwd }
                                [void]$OutsideProjects['Claude'].Add([string]$OutsideKey)
                            }
                        }
                        else {
                            $NoMetadata['Claude']++
                        }
                    }
                }
            }
        }
    }

    $CodexAgents = @(
        $Config.agents |
            Where-Object { ([string]$_.routingMode).Equals('codex', [System.StringComparison]::OrdinalIgnoreCase) }
    )
    foreach ($Agent in $CodexAgents) {
        $CodexRoot = Get-PlatformConfiguredPath -Object $Agent
        if (-not $CodexRoot -or -not (Test-Path -LiteralPath $CodexRoot)) {
            continue
        }
        foreach ($File in @(Get-ChildItem -LiteralPath $CodexRoot -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue |
            Where-Object { -not (Test-IsConflictCopyName -Name $_.Name) })) {
            $Cwd = Get-SessionCwd -Path $File.FullName
            if ([string]::IsNullOrWhiteSpace($Cwd)) {
                $NoMetadata['Codex']++
                continue
            }
            $Identity = Resolve-StatusAgentProject -Cwd $Cwd -StorageProjectRoot $null
            if ($Identity) {
                if (Test-Path -LiteralPath $Identity.ProjectPath -PathType Container) {
                    [void]$LocalProjects['Codex'].Add([string]$Identity.Key)
                }
                else {
                    [void]$UnavailableProjects['Codex'].Add([string]$Identity.Key)
                }
            }
            else {
                try { $OutsideKey = Expand-ConfiguredPath -Path $Cwd } catch { $OutsideKey = $Cwd }
                [void]$OutsideProjects['Codex'].Add([string]$OutsideKey)
            }
        }
    }

    $AntigravityAgent = Get-ConfiguredAgent -Name 'antigravity'
    if ($AntigravityAgent) {
        foreach ($RootConfig in @($AntigravityAgent.roots)) {
            $AntigravityRoot = Get-PlatformConfiguredPath -Object $RootConfig
            if (-not $AntigravityRoot -or -not (Test-Path -LiteralPath $AntigravityRoot)) {
                continue
            }

            $KnownConversationIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($Group in @(Get-AntigravityHistoryGroups -LocalRoot $AntigravityRoot)) {
                [void]$KnownConversationIds.Add([string]$Group.ConversationId)
                $Workspace = [string]$Group.Workspace
                if ([string]::IsNullOrWhiteSpace($Workspace)) {
                    $NoMetadata['Antigravity']++
                    continue
                }
                $Identity = Resolve-StatusAgentProject -Cwd $Workspace -StorageProjectRoot $null
                if ($Identity) {
                    if (Test-Path -LiteralPath $Identity.ProjectPath -PathType Container) {
                        [void]$LocalProjects['Antigravity'].Add([string]$Identity.Key)
                    }
                    else {
                        [void]$UnavailableProjects['Antigravity'].Add([string]$Identity.Key)
                    }
                }
                else {
                    try { $OutsideKey = Expand-ConfiguredPath -Path $Workspace } catch { $OutsideKey = $Workspace }
                    [void]$OutsideProjects['Antigravity'].Add([string]$OutsideKey)
                }
            }

            # Detect orphaned IDE databases or brain folders even when their
            # workspace metadata could not be decoded into a history group.
            $OrphanIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $ConversationsRoot = Join-Path $AntigravityRoot 'conversations'
            if (Test-Path -LiteralPath $ConversationsRoot) {
                foreach ($Database in @(Get-ChildItem -LiteralPath $ConversationsRoot -File -Filter '*.db' -ErrorAction SilentlyContinue)) {
                    $Id = [System.IO.Path]::GetFileNameWithoutExtension($Database.Name)
                    if (-not $KnownConversationIds.Contains($Id)) {
                        [void]$OrphanIds.Add($Id)
                    }
                }
            }
            $BrainRoot = Join-Path $AntigravityRoot 'brain'
            if (Test-Path -LiteralPath $BrainRoot) {
                foreach ($BrainDirectory in @(Get-ChildItem -LiteralPath $BrainRoot -Directory -ErrorAction SilentlyContinue)) {
                    if ($BrainDirectory.Name.Equals('tempmediaStorage', [System.StringComparison]::OrdinalIgnoreCase)) {
                        continue
                    }
                    if ((Test-SafeSessionId -Id $BrainDirectory.Name) -and -not $KnownConversationIds.Contains($BrainDirectory.Name)) {
                        [void]$OrphanIds.Add($BrainDirectory.Name)
                    }
                }
            }
            $NoMetadata['Antigravity'] += $OrphanIds.Count
        }
    }

    $OpenCodeAgent = Get-ConfiguredAgent -Name 'opencode'
    if ($OpenCodeAgent) {
        foreach ($Session in @(Get-OpenCodeSessionList -Agent $OpenCodeAgent)) {
            $Directory = [string]$Session.Directory
            if ([string]::IsNullOrWhiteSpace($Directory)) {
                $NoMetadata['OpenCode']++
                continue
            }
            $Identity = Resolve-StatusAgentProject -Cwd $Directory -StorageProjectRoot $null
            if ($Identity) {
                if (Test-Path -LiteralPath $Identity.ProjectPath -PathType Container) {
                    [void]$LocalProjects['OpenCode'].Add([string]$Identity.Key)
                }
                else {
                    [void]$UnavailableProjects['OpenCode'].Add([string]$Identity.Key)
                }
            }
            else {
                try { $OutsideKey = Expand-ConfiguredPath -Path $Directory } catch { $OutsideKey = $Directory }
                [void]$OutsideProjects['OpenCode'].Add([string]$OutsideKey)
            }
        }
    }

    $ClineAgent = Get-ConfiguredAgent -Name 'cline'
    if ($ClineAgent) {
        foreach ($Session in @(Get-ClineLocalSessions -Agent $ClineAgent)) {
            $Workspace = [string]$Session.Workspace
            if ([string]::IsNullOrWhiteSpace($Workspace)) {
                $NoMetadata['Cline']++
                continue
            }
            $Identity = Resolve-StatusAgentProject -Cwd $Workspace -StorageProjectRoot $null
            if ($Identity) {
                if (Test-Path -LiteralPath $Identity.ProjectPath -PathType Container) {
                    [void]$LocalProjects['Cline'].Add([string]$Identity.Key)
                }
                else {
                    [void]$UnavailableProjects['Cline'].Add([string]$Identity.Key)
                }
            }
            else {
                try { $OutsideKey = Expand-ConfiguredPath -Path $Workspace } catch { $OutsideKey = $Workspace }
                [void]$OutsideProjects['Cline'].Add([string]$OutsideKey)
            }
        }
    }

    # Aider is deliberately audited from its project-local history rather than
    # from a configured native provider directory: there is no restore adapter
    # or second source of truth for these records.
    foreach ($StorageProject in @(Get-AgentSyncProjects)) {
        $AiderRoot = Join-Path $StorageProject.FullName '.agent-state\aider'
        if (-not (Test-Path -LiteralPath $AiderRoot -PathType Container)) { continue }
        $AiderFiles = @(Get-ChildItem -LiteralPath $AiderRoot -File -ErrorAction SilentlyContinue |
            Where-Object {
                -not (Test-IsConflictCopyName -Name $_.Name) -and
                $_.Name -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.(?:chat|llm)\.md$'
            })
        if ($AiderFiles.Count -eq 0) { continue }
        $Identity = Resolve-StatusAgentProject -Cwd $StorageProject.FullName -StorageProjectRoot $StorageProject.FullName
        if ($Identity) { [void]$LocalProjects['Aider'].Add([string]$Identity.Key) }
    }

    $Result = New-Object 'System.Collections.Generic.List[object]'
    foreach ($Name in $Names) {
        $Missing = @($LocalProjects[$Name] | Where-Object { -not $ReportProjects[$Name].Contains($_) } | Sort-Object)
        $Unavailable = @($UnavailableProjects[$Name] | Sort-Object)
        $Outside = @($OutsideProjects[$Name] | Sort-Object)
        # Missing state is our fault and unavailable projects are actionable.
        # A session the provider never gave a workspace for is neither: it is
        # reported with its count, but it must not hold the card at warn.
        $StatusClass = if ($Missing.Count -gt 0) { 'error' } elseif ($Unavailable.Count -gt 0) { 'warn' } else { 'ok' }
        [void]$Result.Add([PSCustomObject]@{
            Agent = $Name
            LocalProjects = $LocalProjects[$Name].Count
            ReportProjects = $ReportProjects[$Name].Count
            MissingProjects = $Missing
            MissingCount = $Missing.Count
            OutsideProjects = $Outside.Count
            OutsideProjectPaths = $Outside
            UnavailableProjects = $Unavailable
            UnavailableCount = $Unavailable.Count
            NoMetadata = [int]$NoMetadata[$Name]
            StatusClass = $StatusClass
        })
    }

    $ResultRows = $Result.ToArray()
    $Script:LocalAgentAuditCache = [PSCustomObject]@{
        ReportSignature = $ReportSignature
        CreatedUtc = $AuditNow
        Rows = $ResultRows
    }
    return $ResultRows
}

function Get-StatusBrandIconDataUri {
    param (
        [ValidateSet('Claude', 'Codex', 'Antigravity', 'OpenCode', 'Cline', 'Aider')]
        [string]$AgentName
    )

    # Prefer the official icon installed with each desktop app. The selected
    # image is embedded as a data URI, so the generated report remains offline.
    $CandidatePaths = New-Object 'System.Collections.Generic.List[string]'
    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        if ($AgentName -eq 'Cline') {
            $UserProfile = [System.Environment]::GetFolderPath('UserProfile')
            $ExtensionsRoot = if ([string]::IsNullOrWhiteSpace($UserProfile)) { $null } else { Join-Path $UserProfile '.vscode\extensions' }
            if ($ExtensionsRoot -and (Test-Path -LiteralPath $ExtensionsRoot -PathType Container)) {
                foreach ($ExtensionDirectory in @(Get-ChildItem -LiteralPath $ExtensionsRoot -Directory -Filter 'saoudrizwan.claude-dev-*' -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)) {
                    [void]$CandidatePaths.Add((Join-Path $ExtensionDirectory.FullName 'assets\icons\icon.svg'))
                }
            }
        }
        elseif ($AgentName -eq 'Antigravity') {
            $LocalAppData = [System.Environment]::GetFolderPath('LocalApplicationData')
            if (-not [string]::IsNullOrWhiteSpace($LocalAppData)) {
                [void]$CandidatePaths.Add((Join-Path $LocalAppData 'Programs\Antigravity IDE\resources\app\resources\win32\code_70x70.png'))
            }
        }
        elseif ($AgentName -eq 'OpenCode') {
            $LocalAppData = [System.Environment]::GetFolderPath('LocalApplicationData')
            if (-not [string]::IsNullOrWhiteSpace($LocalAppData)) {
                [void]$CandidatePaths.Add((Join-Path $LocalAppData 'Programs\@opencode-aidesktop\OpenCode.exe'))
            }
        }
        else {
            $ProgramFiles = [System.Environment]::GetFolderPath('ProgramFiles')
            $WindowsApps = if ([string]::IsNullOrWhiteSpace($ProgramFiles)) { $null } else { Join-Path $ProgramFiles 'WindowsApps' }
            if ($WindowsApps -and (Test-Path -LiteralPath $WindowsApps)) {
                try {
                    if ($AgentName -eq 'Claude') {
                        foreach ($AppDirectory in @(Get-ChildItem -LiteralPath $WindowsApps -Directory -Filter 'Claude_*' -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)) {
                            [void]$CandidatePaths.Add((Join-Path $AppDirectory.FullName 'app\resources\ion-dist\images\claude_app_icon.png'))
                        }
                    }
                    elseif ($AgentName -eq 'Codex') {
                        foreach ($AppDirectory in @(Get-ChildItem -LiteralPath $WindowsApps -Directory -Filter 'OpenAI.Codex_*' -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)) {
                            [void]$CandidatePaths.Add((Join-Path $AppDirectory.FullName 'assets\Square44x44Logo.targetsize-16_altform-unplated.png'))
                        }
                    }
                }
                catch {
                    # Fall through to the built-in vector below.
                }
            }
        }
    }

    foreach ($CandidatePath in $CandidatePaths) {
        if (-not (Test-Path -LiteralPath $CandidatePath -PathType Leaf)) {
            continue
        }
        try {
            $Extension = [System.IO.Path]::GetExtension($CandidatePath).ToLowerInvariant()
            if ($Extension -eq '.exe') {
                Add-Type -AssemblyName System.Drawing -ErrorAction Stop
                $Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($CandidatePath)
                if ($null -eq $Icon) {
                    continue
                }
                $Stream = [System.IO.MemoryStream]::new()
                try {
                    $Bitmap = $Icon.ToBitmap()
                    try {
                        $Bitmap.Save($Stream, [System.Drawing.Imaging.ImageFormat]::Png)
                        return "data:image/png;base64,$([System.Convert]::ToBase64String($Stream.ToArray()))"
                    }
                    finally {
                        $Bitmap.Dispose()
                    }
                }
                finally {
                    $Stream.Dispose()
                    $Icon.Dispose()
                }
            }
            $MimeType = if ($Extension -eq '.svg') { 'image/svg+xml' } else { 'image/png' }
            $Base64 = [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($CandidatePath))
            return "data:$MimeType;base64,$Base64"
        }
        catch {
            # Try the next candidate, then use the built-in vector.
        }
    }

    $FallbackSvg = switch ($AgentName) {
        'Claude' {
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><g stroke="#D97757" stroke-width="3" stroke-linecap="round"><path d="M12 2v20M2 12h20M4.9 4.9l14.2 14.2M19.1 4.9L4.9 19.1"/><path d="M7.7 2.8l8.6 18.4M21.2 7.7L2.8 16.3M16.3 2.8L7.7 21.2M21.2 16.3L2.8 7.7"/></g></svg>'
        }
        'Codex' {
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><g fill="none" stroke="#fff" stroke-width="2.4"><circle cx="12" cy="7" r="4.5"/><circle cx="16.3" cy="9.5" r="4.5"/><circle cx="16.3" cy="14.5" r="4.5"/><circle cx="12" cy="17" r="4.5"/><circle cx="7.7" cy="14.5" r="4.5"/><circle cx="7.7" cy="9.5" r="4.5"/></g></svg>'
        }
        'Antigravity' {
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><defs><linearGradient id="a" x1="2" y1="20" x2="20" y2="2" gradientUnits="userSpaceOnUse"><stop stop-color="#4285F4"/><stop offset=".35" stop-color="#34A853"/><stop offset=".65" stop-color="#FBBC05"/><stop offset="1" stop-color="#EA4335"/></linearGradient></defs><path d="M3 19c5.2-3.2 5.1-14 9-14s3.8 10.8 9 14" fill="none" stroke="url(#a)" stroke-width="3.6" stroke-linecap="round"/></svg>'
        }
        'OpenCode' {
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><rect x="2" y="2" width="20" height="20" rx="4" fill="#d9d9d9"/><path d="M8 7h8v10H8z" fill="#171717"/><path d="M11 10h2v4h-2z" fill="#d9d9d9"/></svg>'
        }
        'Cline' {
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><g fill="#24292f"><circle cx="12" cy="4" r="2.6"/><path d="M6.2 6.5h11.6a4 4 0 0 1 4 4v7a4 4 0 0 1-4 4H6.2a4 4 0 0 1-4-4v-7a4 4 0 0 1 4-4zm2.2 5.2v5.1h2v-5.1h-2zm5.2 0v5.1h2v-5.1h-2z"/></g></svg>'
        }
        'Aider' {
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><rect x="2" y="2" width="20" height="20" rx="5" fill="#173b2b"/><path d="M7 17l4.1-10h2L17 17h-2.4l-.8-2.2H10L9.2 17H7zm3.8-4.3h2.3L12 9.5l-1.2 3.2z" fill="#74e6a7"/></svg>'
        }
    }
    $FallbackBytes = [System.Text.Encoding]::UTF8.GetBytes($FallbackSvg)
    return "data:image/svg+xml;base64,$([System.Convert]::ToBase64String($FallbackBytes))"
}

function ConvertTo-StatusBrandTag {
    param (
        [ValidateSet('Claude', 'Codex', 'Antigravity', 'OpenCode', 'Cline', 'Aider')]
        [string]$AgentName,
        [hashtable]$IconUris,
        $Metric,
        [string]$Machines,
        [string]$ProjectName
    )

    $CssName = $AgentName.ToLowerInvariant()
    $IconUri = ConvertTo-StatusHtml $IconUris[$AgentName]
    if ($Metric) {
        $Label = "$AgentName-detaljer for $ProjectName"
        $DetailPayload = ConvertTo-StatusAgentDetailPayload -AgentName $AgentName -Metric $Metric -Machines $Machines -ProjectName $ProjectName
        return @"
<button type="button" class="agent-tag $CssName detail-trigger" aria-label="$(ConvertTo-StatusHtml $Label)" aria-expanded="false" aria-controls="detailPopover" data-detail="$DetailPayload"><img class="agent-logo" src="$IconUri" alt="" aria-hidden="true">$AgentName</button>
"@
    }
    return "<span class=`"agent-tag $CssName`"><img class=`"agent-logo`" src=`"$IconUri`" alt=`"`" aria-hidden=`"true`">$AgentName</span>"
}

function ConvertTo-StatusAgentTags {
    param (
        $Row,
        [hashtable]$IconUris
    )

    $Tags = New-Object 'System.Collections.Generic.List[string]'
    foreach ($AgentName in @('Claude', 'Codex', 'Antigravity', 'OpenCode', 'Cline', 'Aider')) {
        if ($Row.$AgentName.Files -le 0) {
            continue
        }
        [void]$Tags.Add((ConvertTo-StatusBrandTag -AgentName $AgentName -IconUris $IconUris -Metric $Row.$AgentName -Machines $Row.Machines -ProjectName $Row.Project))
    }

    return "<span class=`"agent-tags`">$([string]::Join('', $Tags.ToArray()))</span>"
}

function Get-AgentSyncStatusJsonPath {
    $HtmlPath = 'AgentSync-Status.html'
    if ($Config.statusReport -and -not [string]::IsNullOrWhiteSpace([string]$Config.statusReport.file)) {
        $HtmlPath = [string]$Config.statusReport.file
    }
    if (-not [System.IO.Path]::IsPathRooted($HtmlPath)) {
        $HtmlPath = Join-Path $PSScriptRoot $HtmlPath
    }

    $JsonPath = [System.IO.Path]::ChangeExtension($HtmlPath, '.json')
    if ($Config.statusReport -and -not [string]::IsNullOrWhiteSpace([string]$Config.statusReport.jsonFile)) {
        $JsonPath = [string]$Config.statusReport.jsonFile
        if (-not [System.IO.Path]::IsPathRooted($JsonPath)) {
            $JsonPath = Join-Path $PSScriptRoot $JsonPath
        }
    }
    return [System.IO.Path]::GetFullPath($JsonPath)
}

function Get-AgentSyncDiagnosticsSnapshot {
    $ErrorJournalPath = Join-Path $LogDirectory "errors-$MachineId.log"
    return [PSCustomObject][ordered]@{
        daemonPid = $PID
        daemonStartedUtc = $Script:DaemonStartedUtc.ToString('o')
        runState = $(if ($Script:TotalCycles -gt 0) { 'running' } else { 'initializing' })
        cycles = $Script:TotalCycles
        incrementalCycles = $Script:TotalIncrementalCycles
        errorsSinceStart = $Script:TotalErrorsSinceStart
        lastCycle = $Script:LastCycleDiag
        errorJournal = $ErrorJournalPath
        errorJournalBytes = [long]$(if (Test-Path -LiteralPath $ErrorJournalPath -PathType Leaf) { (Get-Item -LiteralPath $ErrorJournalPath).Length } else { 0 })
    }
}

function Update-AgentSyncStatusDiagnostics {
    param ([string]$JsonReportFile = (Get-AgentSyncStatusJsonPath))

    if ($Script:DryRun -or -not (Test-Path -LiteralPath $JsonReportFile -PathType Leaf)) {
        return $false
    }

    try {
        $Status = Get-Content -LiteralPath $JsonReportFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $Diagnostics = Get-AgentSyncDiagnosticsSnapshot
        if ($Status.PSObject.Properties['diagnostics']) {
            $Status.diagnostics = $Diagnostics
        }
        else {
            $Status | Add-Member -NotePropertyName diagnostics -NotePropertyValue $Diagnostics
        }
        Write-Utf8TextAtomic -Path $JsonReportFile -Text ($Status | ConvertTo-Json -Depth 12)
        return $true
    }
    catch {
        Write-AgentSyncLog -Level 'WARN' -Message "Could not refresh status diagnostics: $($_.Exception.Message)"
        return $false
    }
}

function Test-AgentSyncStatusReportStale {
    param ([string]$JsonReportFile = (Get-AgentSyncStatusJsonPath))

    if (-not (Test-Path -LiteralPath $JsonReportFile -PathType Leaf)) {
        return $true
    }

    $RefreshSeconds = 300
    if ($Config.statusReport -and $Config.statusReport.refreshSeconds) {
        $RefreshSeconds = [int]$Config.statusReport.refreshSeconds
    }
    $RefreshSeconds = [math]::Max(60, [math]::Min(3600, $RefreshSeconds))
    # Diagnostic-only writes must not indefinitely postpone the expensive
    # inventory refresh. Its own generation timestamp is authoritative.
    try {
        $Status = Get-Content -LiteralPath $JsonReportFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $Status.generatedUtc) { return $true }
        $Generated = [System.DateTimeOffset]$Status.generatedUtc
        $AgeSeconds = ([System.DateTimeOffset]::UtcNow - $Generated).TotalSeconds
        return ($AgeSeconds -lt 0 -or $AgeSeconds -ge $RefreshSeconds)
    }
    catch { return $true }
}

function Initialize-AgentSyncStatusJsonFromRecovery {
    param ([string]$JsonReportFile = (Get-AgentSyncStatusJsonPath))

    if (Test-Path -LiteralPath $JsonReportFile -PathType Leaf) {
        return $false
    }

    $RecoveryJsonPath = Join-Path $PSScriptRoot 'AgentSync-Recovery.json'
    if (-not (Test-Path -LiteralPath $RecoveryJsonPath -PathType Leaf)) {
        return $false
    }

    try {
        $Recovery = Get-Content -LiteralPath $RecoveryJsonPath -Raw | ConvertFrom-Json
        $Rows = New-Object 'System.Collections.Generic.List[object]'
        foreach ($Project in @($Recovery.projects)) {
            $Metrics = [ordered]@{}
            foreach ($AgentName in @('Claude', 'Codex', 'Antigravity', 'OpenCode', 'Cline', 'Aider')) {
                $AgentData = @($Project.agents | Where-Object {
                    ([string]$_.name).Equals($AgentName, [System.StringComparison]::OrdinalIgnoreCase)
                }) | Select-Object -First 1
                if ($AgentData) {
                    $Metrics[$AgentName] = [PSCustomObject]@{
                        Files = [int]$AgentData.files
                        Sessions = [int]$AgentData.sessions
                        Bytes = [long]$AgentData.bytes
                        NewestUtc = [string]$AgentData.newestUtc
                        Newest = ConvertTo-StatusTime -Value ([string]$AgentData.newestUtc)
                        Model = ''
                        Provider = ''
                        ModelSeenUtc = $null
                    }
                }
                else {
                    $Metrics[$AgentName] = [PSCustomObject]@{
                        Files = 0
                        Sessions = 0
                        Bytes = [long]0
                        NewestUtc = $null
                        Newest = ConvertTo-StatusTime -Value $null
                        Model = ''
                        Provider = ''
                        ModelSeenUtc = $null
                    }
                }
            }

            $MetricValues = @($Metrics.Claude, $Metrics.Codex, $Metrics.Antigravity, $Metrics.OpenCode, $Metrics.Cline, $Metrics.Aider)
            $Latest = @($MetricValues.Newest | Sort-Object Sort -Descending | Select-Object -First 1)
            [void]$Rows.Add([PSCustomObject]@{
                Project = [string]$(if ($Project.relative) { $Project.relative } else { $Project.path })
                ProjectPath = [string]$Project.path
                AgentCount = @($MetricValues | Where-Object { $_.Files -gt 0 }).Count
                Claude = $Metrics.Claude
                Codex = $Metrics.Codex
                Antigravity = $Metrics.Antigravity
                OpenCode = $Metrics.OpenCode
                Cline = $Metrics.Cline
                Aider = $Metrics.Aider
                TotalFiles = [int](($MetricValues | Measure-Object Files -Sum).Sum)
                TotalBytes = [long](($MetricValues | Measure-Object Bytes -Sum).Sum)
                Latest = $(if ($Latest.Count -gt 0) { $Latest[0] } else { ConvertTo-StatusTime -Value $null })
                Machines = $(if ($Recovery.machine) { [string]$Recovery.machine } else { $MachineId })
            })
        }

        $RowArray = $Rows.ToArray()
        $Now = [System.DateTimeOffset]::UtcNow
        $Fallback = [ordered]@{
            format = 'agentsync-status'
            schemaVersion = 1
            agentSyncVersion = $AgentSyncVersion
            generatedUtc = $Now.ToString('o')
            machine = $MachineId
            platform = $PlatformName
            projectsRoot = $ProjectsBasePath
            fallback = [ordered]@{
                source = 'AgentSync-Recovery.json'
                sourceGeneratedUtc = [string]$Recovery.generatedUtc
            }
            privacy = [ordered]@{
                containsConversationContent = $false
                containsDerivedMetadataOnly = $true
            }
            refreshSeconds = 300
            staleAfterSeconds = 900
            summary = [ordered]@{
                projects = $RowArray.Count
                singleAgent = @($RowArray | Where-Object { $_.AgentCount -eq 1 }).Count
                multiAgent = @($RowArray | Where-Object { $_.AgentCount -gt 1 }).Count
                files = [long](($RowArray | Measure-Object TotalFiles -Sum).Sum)
                bytes = [long](($RowArray | Measure-Object TotalBytes -Sum).Sum)
                conflicts = 0
                unresolved = 0
                auditMissing = 0
                auditUnavailable = 0
                auditNoMetadata = 0
            }
            reports = [ordered]@{
                statusHtml = Join-Path $PSScriptRoot 'AgentSync-Status.html'
                statusJson = $JsonReportFile
                recoveryHtml = Join-Path $PSScriptRoot 'AgentSync-Recovery.html'
                recoveryJson = $RecoveryJsonPath
                intelligenceHtml = Join-Path $PSScriptRoot 'AgentSync-Intelligence.html'
                intelligenceJson = Join-Path $PSScriptRoot 'AgentSync-Intelligence.json'
            }
            selfAudit = @()
            recentIssues = @()
            projects = $RowArray
        }
        Write-Utf8TextAtomic -Path $JsonReportFile -Text ($Fallback | ConvertTo-Json -Depth 12)
        Write-AgentSyncLog -Level 'INFO' -Message "STATUS_FALLBACK json=$JsonReportFile projects=$($RowArray.Count) source=$RecoveryJsonPath"
        return $true
    }
    catch {
        Write-AgentSyncLog -Level 'WARN' -Message "Could not initialize status JSON from recovery: $($_.Exception.Message)"
        return $false
    }
}

function Update-AgentSyncStatusReport {
    $Enabled = $true
    if ($Config.statusReport -and $null -ne $Config.statusReport.enabled) {
        $Enabled = [bool]$Config.statusReport.enabled
    }
    if (-not $Enabled) {
        return
    }
    $ReportStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    $ReportFile = "AgentSync-Status.html"
    if ($Config.statusReport -and -not [string]::IsNullOrWhiteSpace([string]$Config.statusReport.file)) {
        $ReportFile = [string]$Config.statusReport.file
    }
    if (-not [System.IO.Path]::IsPathRooted($ReportFile)) {
        $ReportFile = Join-Path $PSScriptRoot $ReportFile
    }
    $ReportFile = [System.IO.Path]::GetFullPath($ReportFile)
    $JsonReportFile = Get-AgentSyncStatusJsonPath
    $ReportDirectory = Split-Path $ReportFile -Parent
    $IntelligenceSetting = 'AgentSync-Intelligence.html'
    if ($Config.intelligenceReport -and -not [string]::IsNullOrWhiteSpace([string]$Config.intelligenceReport.file)) {
        $IntelligenceSetting = [string]$Config.intelligenceReport.file
    }
    $IntelligencePath = if ([System.IO.Path]::IsPathRooted($IntelligenceSetting)) { [System.IO.Path]::GetFullPath($IntelligenceSetting) } else { [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot $IntelligenceSetting)) }
    $IntelligenceHref = ConvertTo-StatusHtml ([System.IO.Path]::GetRelativePath($ReportDirectory, $IntelligencePath).Replace('\', '/'))
    $RecoveryPath = Join-Path $PSScriptRoot 'AgentSync-Recovery.html'
    $RecoveryHref = ConvertTo-StatusHtml ([System.IO.Path]::GetRelativePath($ReportDirectory, $RecoveryPath).Replace('\', '/'))

    $RefreshSeconds = 300
    if ($Config.statusReport -and $Config.statusReport.refreshSeconds) {
        $RefreshSeconds = [int]$Config.statusReport.refreshSeconds
    }
    $RefreshSeconds = [Math]::Max(60, [Math]::Min(3600, $RefreshSeconds))

    $StatusData = Get-AgentDerivedStatusData
    $Rows = @($StatusData.Rows)

    $ProjectCount = $Rows.Count
    $SingleAgentCount = @($Rows | Where-Object { $_.AgentCount -eq 1 }).Count
    $MultiAgentCount = @($Rows | Where-Object { $_.AgentCount -gt 1 }).Count
    $TotalFilesAll = [long](($Rows | Measure-Object -Property TotalFiles -Sum).Sum)
    $TotalBytesAll = [long](($Rows | Measure-Object -Property TotalBytes -Sum).Sum)
    $ConflictCount = [long]$StatusData.Conflicts
    $UnresolvedFiles = [long]$StatusData.UnresolvedFiles
    $AuditStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $AuditRows = @(Get-LocalAgentProjectAudit -ReportRows $Rows)
    Write-AgentSyncLog -Level 'DEBUG' -Message "STATUS_PHASE phase=local-audit durationMs=$($AuditStopwatch.ElapsedMilliseconds) agents=$($AuditRows.Count)"
    $PublishStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $AuditMissingCount = [int](($AuditRows | Measure-Object -Property MissingCount -Sum).Sum)
    $AuditNoMetadataCount = [int](($AuditRows | Measure-Object -Property NoMetadata -Sum).Sum)
    $AuditUnavailableCount = [int](($AuditRows | Measure-Object -Property UnavailableCount -Sum).Sum)

    # Log only when the set of actual audit problems changes. This makes a
    # missing project durable and visible without repeating the same warning on
    # every filesystem event.
    $AuditIssueCore = @($AuditRows | Select-Object Agent, MissingProjects, UnavailableProjects, NoMetadata)
    $AuditIssueHash = Get-StatusCoreHash -Value $AuditIssueCore
    if ($Script:StatusAuditIssueHash -ne $AuditIssueHash) {
        if ($AuditMissingCount -gt 0 -or $AuditNoMetadataCount -gt 0 -or $AuditUnavailableCount -gt 0) {
            foreach ($AuditRow in $AuditRows) {
                if ($AuditRow.MissingCount -gt 0 -or $AuditRow.NoMetadata -gt 0 -or $AuditRow.UnavailableCount -gt 0) {
                    $MissingText = @($AuditRow.MissingProjects) -join ','
                    $UnavailableText = @($AuditRow.UnavailableProjects) -join ','

                    # Match the card. A session the provider never gave a
                    # workspace is the source's nature, not our failure, so it
                    # stays green there - and a WARN here would say otherwise
                    # to anyone reading the log.
                    $AuditLevel = 'INFO'
                    if ($AuditRow.MissingCount -gt 0 -or $AuditRow.UnavailableCount -gt 0) {
                        $AuditLevel = 'WARN'
                    }
                    Write-AgentSyncLog -Level $AuditLevel -Message "STATUS_AUDIT agent=$($AuditRow.Agent) missing=$($AuditRow.MissingCount) unavailable=$($AuditRow.UnavailableCount) noMetadata=$($AuditRow.NoMetadata) projects=$MissingText unavailableProjects=$UnavailableText"
                }
            }
        }
        elseif ($null -ne $Script:StatusAuditIssueHash) {
            Write-AgentSyncLog -Level 'INFO' -Message 'STATUS_AUDIT_RECOVERED all locally discovered projects are present in the report'
        }
        $Script:StatusAuditIssueHash = $AuditIssueHash
    }

    $Core = [ordered]@{
        version = $AgentSyncVersion
        projects = $Rows
        projectCount = $ProjectCount
        singleAgentCount = $SingleAgentCount
        multiAgentCount = $MultiAgentCount
        totalFiles = $TotalFilesAll
        totalBytes = $TotalBytesAll
        conflicts = $ConflictCount
        unresolvedFiles = $UnresolvedFiles
        selfAudit = $AuditRows
    }
    $CoreHash = Get-StatusCoreHash -Value $Core
    $Now = [System.DateTimeOffset]::UtcNow
    $NeedsWrite = (
        -not (Test-Path -LiteralPath $ReportFile) -or
        -not (Test-Path -LiteralPath $JsonReportFile) -or
        $Script:StatusReportCoreHash -ne $CoreHash -or
        -not (Test-AgentSyncRecentTimestamp -Since $Script:StatusReportLastWriteUtc -WindowSeconds $RefreshSeconds -Now $Now)
    )
    if (-not $NeedsWrite) {
        Write-AgentSyncLog -Level 'DEBUG' -Message "STATUS_PHASE phase=publish durationMs=$($PublishStopwatch.ElapsedMilliseconds) outcome=unchanged totalMs=$($ReportStopwatch.ElapsedMilliseconds)"
        return
    }

    $BrandIconUris = @{
        Claude = Get-StatusBrandIconDataUri -AgentName 'Claude'
        Codex = Get-StatusBrandIconDataUri -AgentName 'Codex'
        Antigravity = Get-StatusBrandIconDataUri -AgentName 'Antigravity'
        OpenCode = Get-StatusBrandIconDataUri -AgentName 'OpenCode'
        Cline = Get-StatusBrandIconDataUri -AgentName 'Cline'
        Aider = Get-StatusBrandIconDataUri -AgentName 'Aider'
    }
    $AuditMarkup = New-Object 'System.Collections.Generic.List[string]'
    foreach ($AuditRow in $AuditRows) {
        $BrandTag = ConvertTo-StatusBrandTag -AgentName ([string]$AuditRow.Agent) -IconUris $BrandIconUris
        $StateText = switch ([string]$AuditRow.StatusClass) {
            'error' { 'Mangler prosjekt' }
            'warn' { if ($AuditRow.UnavailableCount -gt 0) { 'Gammel prosjektsti' } else { 'Mangler metadata' } }
            default { 'Alt stemmer' }
        }
        $MissingDetail = if ($AuditRow.MissingCount -gt 0) {
            $MissingNames = ConvertTo-StatusHtml (@($AuditRow.MissingProjects) -join ', ')
            "<span class=`"audit-problem`">Mangler: $MissingNames</span>"
        }
        else {
            '<span>Ingen prosjektkoblinger mangler</span>'
        }
        $UnavailableDetail = if ($AuditRow.UnavailableCount -gt 0) {
            $UnavailableNames = ConvertTo-StatusHtml (@($AuditRow.UnavailableProjects) -join ', ')
            "<span>Tidligere registrert mappe finnes ikke: $UnavailableNames</span>"
        }
        else {
            '<span>Ingen utdaterte prosjektstier</span>'
        }
        $MissingDetailValue = if ($AuditRow.MissingCount -gt 0) { @($AuditRow.MissingProjects) -join ' · ' } else { '0' }
        $UnavailableDetailValue = if ($AuditRow.UnavailableCount -gt 0) { @($AuditRow.UnavailableProjects) -join ' · ' } else { '0' }
        $OutsideDetailValue = if ($AuditRow.OutsideProjects -gt 0) { @($AuditRow.OutsideProjectPaths) -join ' · ' } else { '0' }
        $AuditDetailDescription = switch ([string]$AuditRow.StatusClass) {
            'error' { 'Agenten har lokalt oppdagede prosjektkoblinger som ikke vises som egne rader i rapporten.' }
            'warn' { 'Koblingene vises, men minst én tidligere registrert prosjektmappe eller metadataoppføring trenger oppmerksomhet.' }
            default { 'Alle lokalt oppdagede prosjektkoblinger for agenten er representert i rapporten.' }
        }
        $AuditDetailPayload = ConvertTo-StatusDetailPayload `
            -Title "$($AuditRow.Agent)-kontroll" `
            -Subtitle $StateText `
            -Description $AuditDetailDescription `
            -Rows @(
                [PSCustomObject]@{ Label = 'Lokalt oppdaget'; Value = [string]$AuditRow.LocalProjects }
                [PSCustomObject]@{ Label = 'Vist i rapporten'; Value = [string]$AuditRow.ReportProjects }
                [PSCustomObject]@{ Label = 'Mangler i rapporten'; Value = $MissingDetailValue }
                [PSCustomObject]@{ Label = 'Gamle prosjektstier'; Value = $UnavailableDetailValue }
                [PSCustomObject]@{ Label = 'Utenfor synkeroten'; Value = $OutsideDetailValue }
                [PSCustomObject]@{ Label = 'Uten workspace/cwd'; Value = [string]$AuditRow.NoMetadata }
            )
        $AuditAriaLabel = ConvertTo-StatusHtml "Vis selvkontroll for $($AuditRow.Agent)"
        [void]$AuditMarkup.Add(@"
<button type="button" class="audit-card $($AuditRow.StatusClass) detail-trigger" aria-label="$AuditAriaLabel" aria-expanded="false" aria-controls="detailPopover" data-detail="$AuditDetailPayload">
  <span class="audit-head">$BrandTag<span class="audit-state">$StateText</span></span>
  <strong>$($AuditRow.LocalProjects) / $($AuditRow.ReportProjects)</strong>
  <span class="audit-caption">lokalt oppdaget / vist i rapporten</span>
  <span class="audit-meta">$MissingDetail$UnavailableDetail<span>Utenfor synkeroten: $($AuditRow.OutsideProjects)</span><span>Uten workspace/cwd: $($AuditRow.NoMetadata)</span></span>
</button>
"@)
    }
    $AuditHtml = [string]::Join([System.Environment]::NewLine, $AuditMarkup.ToArray())
    $AuditUnavailableLinks = @(
        foreach ($AuditRow in @($AuditRows | Where-Object { $_.UnavailableCount -gt 0 })) {
            foreach ($UnavailableProject in @($AuditRow.UnavailableProjects)) {
                [PSCustomObject]@{
                    Agent = [string]$AuditRow.Agent
                    Project = [string]$UnavailableProject
                }
            }
        }
    )
    $AuditOverallClass = if ($AuditMissingCount -gt 0) { 'error' } elseif ($AuditNoMetadataCount -gt 0 -or $AuditUnavailableCount -gt 0) { 'warn' } else { 'ok' }
    $AuditOverallTextRaw = if ($AuditMissingCount -gt 0) {
        "$AuditMissingCount prosjektkoblinger mangler"
    }
    elseif ($AuditNoMetadataCount -gt 0) {
        "$AuditNoMetadataCount lokale elementer mangler metadata"
    }
    elseif ($AuditUnavailableCount -gt 0) {
        if ($AuditUnavailableLinks.Count -eq 1) {
            $Link = $AuditUnavailableLinks[0]
            "$($Link.Agent) peker på en mappe som ikke finnes: $($Link.Project)"
        }
        else {
            $VisibleLinks = @($AuditUnavailableLinks | Select-Object -First 3 | ForEach-Object { "$($_.Agent): $($_.Project)" })
            $UnavailableSummary = [string]::Join(' · ', $VisibleLinks)
            if ($AuditUnavailableLinks.Count -gt $VisibleLinks.Count) {
                $UnavailableSummary += " · +$($AuditUnavailableLinks.Count - $VisibleLinks.Count) flere"
            }
            "$AuditUnavailableCount agentkoblinger peker på mapper som ikke finnes: $UnavailableSummary"
        }
    }
    else {
        'Alle oppdagede prosjektkoblinger vises'
    }
    $AuditOverallText = ConvertTo-StatusHtml $AuditOverallTextRaw
    $AuditOverallDetail = ConvertTo-StatusDetailPayload `
        -Title 'Fast selvkontroll' `
        -Subtitle $AuditOverallTextRaw `
        -Description 'Sammenligner prosjektene som hver lokal agent faktisk peker på, med prosjektmapper på disken og radene i denne rapporten.' `
        -Rows @(
            [PSCustomObject]@{ Label = 'Mangler i rapporten'; Value = [string]$AuditMissingCount }
            [PSCustomObject]@{ Label = 'Gamle prosjektstier'; Value = [string]$AuditUnavailableCount }
            [PSCustomObject]@{ Label = 'Uten metadata'; Value = [string]$AuditNoMetadataCount }
            [PSCustomObject]@{ Label = 'Kontrollerte agenter'; Value = 'Claude · Codex · Antigravity · OpenCode · Cline · Aider' }
        )
    $RowMarkup = New-Object 'System.Collections.Generic.List[string]'
    foreach ($Row in $Rows) {
        $ProjectName = ConvertTo-StatusHtml $Row.Project
        $ProjectPath = ConvertTo-StatusHtml $Row.ProjectPath
        $AgentTags = ConvertTo-StatusAgentTags -Row $Row -IconUris $BrandIconUris
        $MachineText = ConvertTo-StatusHtml $Row.Machines
        $TotalSize = ConvertTo-StatusHtml (Format-StatusBytes -Bytes $Row.TotalBytes)
        $LatestText = ConvertTo-StatusHtml $Row.Latest.Display
        $ClaudeCell = ConvertTo-StatusAgentCell -Metric $Row.Claude -AgentName 'Claude' -ProjectName $Row.Project -Machines $Row.Machines
        $CodexCell = ConvertTo-StatusAgentCell -Metric $Row.Codex -AgentName 'Codex' -ProjectName $Row.Project -Machines $Row.Machines
        $AntigravityCell = ConvertTo-StatusAgentCell -Metric $Row.Antigravity -AgentName 'Antigravity' -ProjectName $Row.Project -Machines $Row.Machines
        $OpenCodeCell = ConvertTo-StatusAgentCell -Metric $Row.OpenCode -AgentName 'OpenCode' -ProjectName $Row.Project -Machines $Row.Machines
        $ClineCell = ConvertTo-StatusAgentCell -Metric $Row.Cline -AgentName 'Cline' -ProjectName $Row.Project -Machines $Row.Machines
        $AiderCell = ConvertTo-StatusAgentCell -Metric $Row.Aider -AgentName 'Aider' -ProjectName $Row.Project -Machines $Row.Machines
        $IsSynced = if ($Row.TotalFiles -gt 0) { "true" } else { "false" }
        $RowMetrics = @($Row.Claude, $Row.Codex, $Row.Antigravity, $Row.OpenCode, $Row.Cline, $Row.Aider)
        $ActiveAgentNames = @('Claude', 'Codex', 'Antigravity', 'OpenCode', 'Cline', 'Aider') | Where-Object { $Row.PSObject.Properties[$_].Value.Files -gt 0 }
        $TotalSessionsForRow = [long](($RowMetrics | Measure-Object -Property Sessions -Sum).Sum)
        $ProjectDetailPayload = ConvertTo-StatusDetailPayload `
            -Title ([string]$Row.Project) `
            -Subtitle ([string]$Row.ProjectPath) `
            -Description 'Dette er den eksakte prosjektidentiteten utledet fra agentenes cwd/workspace/directory-metadata. En undermappe kan derfor være et eget prosjekt.' `
            -Rows @(
                [PSCustomObject]@{ Label = 'Agenter'; Value = ($ActiveAgentNames -join ' · ') }
                [PSCustomObject]@{ Label = 'Agentkoblinger'; Value = [string]$Row.AgentCount }
                [PSCustomObject]@{ Label = 'Sesjoner'; Value = [string]$TotalSessionsForRow }
                [PSCustomObject]@{ Label = 'State-filer'; Value = [string]$Row.TotalFiles }
                [PSCustomObject]@{ Label = 'Datamengde'; Value = (Format-StatusBytes -Bytes ([long]$Row.TotalBytes)) }
                [PSCustomObject]@{ Label = 'Siste data'; Value = [string]$Row.Latest.Display }
                [PSCustomObject]@{ Label = 'Maskiner i manifest'; Value = [string]$Row.Machines }
            )
        $LatestDetailPayload = ConvertTo-StatusDetailPayload `
            -Title 'Siste data' `
            -Subtitle ([string]$Row.Project) `
            -Description 'Det nyeste registrerte filtidspunktet blant AgentSync-administrerte state-filer som inngår i denne prosjektraden.' `
            -Rows @(
                [PSCustomObject]@{ Label = 'Lokal tid'; Value = [string]$Row.Latest.Display }
                [PSCustomObject]@{ Label = 'ISO-tid'; Value = $(if ([string]::IsNullOrWhiteSpace([string]$Row.Latest.Iso)) { '-' } else { [string]$Row.Latest.Iso }) }
            )
        $MachinesDetailPayload = ConvertTo-StatusDetailPayload `
            -Title 'Maskiner i state' `
            -Subtitle ([string]$Row.Project) `
            -Description 'Maskin-ID-er registrert i prosjektets AgentSync-manifest. Dette er spor av synkronisert state, ikke en liste over maskiner som nødvendigvis er pålogget nå.' `
            -Rows @(
                [PSCustomObject]@{ Label = 'Registrert'; Value = [string]$Row.Machines }
                [PSCustomObject]@{ Label = 'Gjeldende maskin'; Value = [string]$MachineId }
            )
        $ProjectAriaLabel = ConvertTo-StatusHtml "Vis prosjektdetaljer for $($Row.Project)"
        $LatestAriaLabel = ConvertTo-StatusHtml "Forklar siste data for $($Row.Project)"
        $MachinesAriaLabel = ConvertTo-StatusHtml "Vis maskindetaljer for $($Row.Project)"

        [void]$RowMarkup.Add(@"
<tr data-synced="$IsSynced">
  <td class="project"><button type="button" class="project-detail-trigger detail-trigger" aria-label="$ProjectAriaLabel" aria-expanded="false" aria-controls="detailPopover" data-detail="$ProjectDetailPayload"><strong>$ProjectName</strong><span class="project-path">$ProjectPath</span></button>$AgentTags</td>
  <td class="agent">$ClaudeCell</td>
  <td class="agent">$CodexCell</td>
  <td class="agent">$AntigravityCell</td>
  <td class="agent">$OpenCodeCell</td>
  <td class="agent">$ClineCell</td>
  <td class="agent">$AiderCell</td>
  <td class="total"><button type="button" class="cell-detail-trigger detail-trigger" aria-label="$ProjectAriaLabel" aria-expanded="false" aria-controls="detailPopover" data-detail="$ProjectDetailPayload"><strong>$($Row.TotalFiles)</strong><span>$TotalSize</span></button></td>
  <td data-sort="$($Row.Latest.Sort)"><button type="button" class="cell-detail-trigger detail-trigger" aria-label="$LatestAriaLabel" aria-expanded="false" aria-controls="detailPopover" data-detail="$LatestDetailPayload">$LatestText</button></td>
  <td><button type="button" class="cell-detail-trigger detail-trigger" aria-label="$MachinesAriaLabel" aria-expanded="false" aria-controls="detailPopover" data-detail="$MachinesDetailPayload">$MachineText</button></td>
</tr>
"@)
    }
    $RowsHtml = [string]::Join([System.Environment]::NewLine, $RowMarkup.ToArray())

    $RecentIssues = @()
    if (Test-Path -LiteralPath $LogPath) {
        $RecentIssues = @(
            Get-Content -LiteralPath $LogPath -Tail 1000 -ErrorAction SilentlyContinue |
                Where-Object { $_ -match ' ERROR | WARN ' } |
                Select-Object -Last 10
        )
    }
    if ($RecentIssues.Count -eq 0) {
        $IssuesHtml = '<p class="muted">Ingen nylige advarsler eller feil i gjeldende logg.</p>'
    }
    else {
        $IssueItems = @($RecentIssues | ForEach-Object { "<li>$(ConvertTo-StatusHtml $_)</li>" })
        $IssuesHtml = "<ul class=`"issues`">$([string]::Join('', $IssueItems))</ul>"
    }

    $GeneratedIso = $Now.ToString("o")
    $GeneratedLocal = $Now.ToLocalTime().ToString("dd.MM.yyyy HH:mm:ss")
    $TotalSizeAll = Format-StatusBytes -Bytes $TotalBytesAll
    $StaleSeconds = ($RefreshSeconds * 2) + 60
    $MachineHtml = ConvertTo-StatusHtml $MachineId
    $ProjectsPathHtml = ConvertTo-StatusHtml $ProjectsBasePath
    $SingleAgentShare = if ($ProjectCount -gt 0) { '{0:N1} %' -f (($SingleAgentCount * 100.0) / $ProjectCount) } else { '0,0 %' }
    $MultiAgentShare = if ($ProjectCount -gt 0) { '{0:N1} %' -f (($MultiAgentCount * 100.0) / $ProjectCount) } else { '0,0 %' }

    $StatusJsonData = [ordered]@{
        format = 'agentsync-status'
        schemaVersion = 1
        agentSyncVersion = $AgentSyncVersion
        generatedUtc = $GeneratedIso
        machine = $MachineId
        platform = $PlatformName
        projectsRoot = $ProjectsBasePath
        privacy = [ordered]@{
            containsConversationContent = $false
            containsDerivedMetadataOnly = $true
        }
        refreshSeconds = $RefreshSeconds
        staleAfterSeconds = $StaleSeconds
        summary = [ordered]@{
            projects = $ProjectCount
            singleAgent = $SingleAgentCount
            multiAgent = $MultiAgentCount
            files = $TotalFilesAll
            bytes = $TotalBytesAll
            conflicts = $ConflictCount
            unresolved = $UnresolvedFiles
            auditMissing = $AuditMissingCount
            auditUnavailable = $AuditUnavailableCount
            auditNoMetadata = $AuditNoMetadataCount
        }
        reports = [ordered]@{
            statusHtml = $ReportFile
            statusJson = $JsonReportFile
            recoveryHtml = $RecoveryPath
            recoveryJson = [System.IO.Path]::ChangeExtension($RecoveryPath, '.json')
            intelligenceHtml = $IntelligencePath
            intelligenceJson = [System.IO.Path]::ChangeExtension($IntelligencePath, '.json')
        }
        diagnostics = Get-AgentSyncDiagnosticsSnapshot
        selfAudit = $AuditRows
        recentIssues = $RecentIssues
        projects = $Rows
    }
    $StatusJson = $StatusJsonData | ConvertTo-Json -Depth 12

    $VersionDetail = ConvertTo-StatusDetailPayload `
        -Title "AgentSync Toolkit v$AgentSyncVersion" `
        -Subtitle 'Prosjektet er den varige enheten' `
        -Description 'AgentSync bevarer prosjektkoblet økthistorikk per eksakte prosjektmappe og gjør den tilgjengelig på tvers av agent, modell, maskin og synkroniseringstransport.' `
        -Rows @(
            [PSCustomObject]@{ Label = 'Agenter'; Value = 'Claude · Codex · Antigravity · OpenCode · Cline · Aider' }
            [PSCustomObject]@{ Label = 'Gjeldende maskin'; Value = $MachineId }
            [PSCustomObject]@{ Label = 'Synkroniseringsrot'; Value = $ProjectsBasePath }
            [PSCustomObject]@{ Label = 'Samtaleinnhold i rapporten'; Value = 'Nei' }
        )
    $ServiceDetail = ConvertTo-StatusDetailPayload `
        -Title 'Statusrapport' `
        -Subtitle "Sist generert $GeneratedLocal" `
        -Description 'Grønn status betyr at rapportfilen er nyere enn grensen for foreldet status. Det er en ferskhetskontroll, ikke en nettverksping.' `
        -Rows @(
            [PSCustomObject]@{ Label = 'Rapportintervall'; Value = "$RefreshSeconds sekunder" }
            [PSCustomObject]@{ Label = 'Regnes som foreldet etter'; Value = "$StaleSeconds sekunder" }
            [PSCustomObject]@{ Label = 'Nettsiden laster på nytt'; Value = 'Hvert 60. sekund' }
            [PSCustomObject]@{ Label = 'Generert av'; Value = $MachineId }
        )
    $IntelligenceDetail = ConvertTo-StatusDetailPayload `
        -Title 'AgentSync Intelligence' `
        -Subtitle 'Provider-uavhengig metadataindeks' `
        -Description 'Åpner en avledet tidslinje med eksplisitt modellmetadata, verktøynavn og prosjektkoblinger uten å kopiere rå meldinger, kildekode eller terminalinnhold.' `
        -Rows @([PSCustomObject]@{ Label = 'Fil'; Value = $IntelligencePath })
    $RecoveryDetail = ConvertTo-StatusDetailPayload `
        -Title 'Recovery audit' `
        -Subtitle 'Lesebasert gjenopprettingskontroll' `
        -Description 'Åpner kontrollen av prosjektkoblet state og restore-ruting der en separat adapter finnes. Audit endrer ikke agenthistorikken.' `
        -Rows @([PSCustomObject]@{ Label = 'Fil'; Value = $RecoveryPath })

    $AgentProjectsDetail = ConvertTo-StatusDetailPayload `
        -Title 'Agentprosjekter' -Subtitle ([string]$ProjectCount) `
        -Description 'Antall unike, eksakte prosjektmapper som minst én agent har knyttet state til. En mappe og en agentregistrert undermappe kan være to separate prosjekter.' `
        -Rows @(
            [PSCustomObject]@{ Label = 'Kilde'; Value = 'cwd / workspace / directory i agentmetadata' }
            [PSCustomObject]@{ Label = 'Synkeroten bestemmer identitet'; Value = 'Nei' }
        )
    $SingleAgentDetail = ConvertTo-StatusDetailPayload `
        -Title 'Kun én agent' -Subtitle ([string]$SingleAgentCount) `
        -Description 'Prosjekter som akkurat nå har state fra bare én av de seks støttede agentene.' `
        -Rows @(
            [PSCustomObject]@{ Label = 'Andel av prosjektene'; Value = $SingleAgentShare }
            [PSCustomObject]@{ Label = 'Beregning'; Value = 'AgentCount = 1' }
        )
    $MultiAgentDetail = ConvertTo-StatusDetailPayload `
        -Title 'Flere agenter' -Subtitle ([string]$MultiAgentCount) `
        -Description 'Prosjekter der minst to forskjellige agenter har prosjektkoblet state. Dette er de tydeligste fleragent-prosjektene i oversikten.' `
        -Rows @(
            [PSCustomObject]@{ Label = 'Andel av prosjektene'; Value = $MultiAgentShare }
            [PSCustomObject]@{ Label = 'Beregning'; Value = 'AgentCount > 1' }
        )
    $AgentFilesDetail = ConvertTo-StatusDetailPayload `
        -Title 'Agentfiler' -Subtitle ([string]$TotalFilesAll) `
        -Description 'Summen av AgentSync-administrerte state-filer som inngår i de synlige prosjektradene. Tallet er ikke det samme som antall samtaler eller sesjoner.' `
        -Rows @([PSCustomObject]@{ Label = 'Samtaleinnhold vist her'; Value = 'Nei' })
    $TotalSizeDetail = ConvertTo-StatusDetailPayload `
        -Title 'Samlet størrelse' -Subtitle $TotalSizeAll `
        -Description 'Samlet filstørrelse for AgentSync-administrert state som er knyttet til de synlige prosjektene. Konfliktarkiv og andre kontrollfiler kan telles separat.' `
        -Rows @([PSCustomObject]@{ Label = 'Bytegrunnlag'; Value = [string]$TotalBytesAll })
    $UnresolvedDetail = ConvertTo-StatusDetailPayload `
        -Title 'Uten prosjektsti' -Subtitle ([string]$UnresolvedFiles) `
        -Description 'State-filer der AgentSync ikke fant en eksplisitt cwd, workspace eller directory som kunne brukes til sikker prosjektruting.' `
        -Rows @([PSCustomObject]@{ Label = 'Ønsket verdi'; Value = '0' })
    $ConflictDetail = ConvertTo-StatusDetailPayload `
        -Title 'Konfliktfiler' -Subtitle ([string]$ConflictCount) `
        -Description 'Bevarte konflikt- eller overskrivingskopier under prosjektenes .agent-state/conflicts-mapper. De er sikkerhetskopier og blir ikke automatisk aktiv agenthistorikk.' `
        -Rows @(
            [PSCustomObject]@{ Label = 'Aktiveres automatisk'; Value = 'Nei' }
            [PSCustomObject]@{ Label = 'Formål'; Value = 'Unngå stille tap av historikk' }
        )

    $ProjectColumnDetail = ConvertTo-StatusDetailPayload `
        -Title 'Prosjektmappe' -Subtitle 'Eksakt agentoppdaget identitet' `
        -Description 'Prosjektet kommer fra agentmetadata, ikke fra en vilkårlig skanning av alle Dropbox-mapper. Trykk på et prosjektnavn for samlet prosjektdetalj.' `
        -Rows @([PSCustomObject]@{ Label = 'Nested projects'; Value = 'Bevares som egne rader når agentmetadata peker dit' })
    $AgentColumnDetails = @{}
    foreach ($AgentName in @('Claude', 'Codex', 'Antigravity', 'OpenCode', 'Cline', 'Aider')) {
        $StateKind = if ($AgentName -eq 'Aider') { 'prosjektlokale' } else { 'provider-native' }
        $AgentColumnDetails[$AgentName] = ConvertTo-StatusDetailPayload `
            -Title "$AgentName-kolonnen" -Subtitle 'State-filer og datamengde' `
            -Description "Viser antall $StateKind $AgentName-filer og størrelsen deres per prosjekt. Trykk på tallet eller agenttaggen for modell, sesjoner, aktivitet og maskiner." `
            -Rows @([PSCustomObject]@{ Label = 'Bindestrek'; Value = 'Ingen prosjektkoblet state for denne agenten' })
    }
    $TotalColumnDetail = ConvertTo-StatusDetailPayload `
        -Title 'Totalt' -Subtitle 'Summen per prosjekt' `
        -Description 'Summerer state-filer og datamengde fra alle agentkolonnene i raden. Trykk på et totaltall for samlet prosjektmetadata.' `
        -Rows @([PSCustomObject]@{ Label = 'Inkluderer'; Value = 'Claude · Codex · Antigravity · OpenCode · Cline · Aider' })
    $LatestColumnDetail = ConvertTo-StatusDetailPayload `
        -Title 'Siste data' -Subtitle 'Nyeste state-filtid' `
        -Description 'Det nyeste registrerte tidspunktet blant state-filene i prosjektraden. Det er ikke nødvendigvis tidspunktet for siste menneskelige melding.' `
        -Rows @([PSCustomObject]@{ Label = 'Tidssone i tabellen'; Value = 'Lokal tid' })
    $MachinesColumnDetail = ConvertTo-StatusDetailPayload `
        -Title 'Maskiner' -Subtitle 'Registrert i prosjektmanifestet' `
        -Description 'Maskin-ID-er som har bidratt til prosjektets AgentSync-state. De viser historisk tilstedeværelse, ikke nødvendigvis hvem som er online.' `
        -Rows @([PSCustomObject]@{ Label = 'Gjeldende maskin'; Value = $MachineId })
    $IssuesDetail = ConvertTo-StatusDetailPayload `
        -Title 'Nylige advarsler og feil' -Subtitle "$($RecentIssues.Count) vist" `
        -Description 'Viser opptil de ti siste WARN/ERROR-linjene fra de siste 1000 linjene i denne maskinens AgentSync-logg.' `
        -Rows @([PSCustomObject]@{ Label = 'Loggfil'; Value = $LogPath })
    $GeneratedDetail = ConvertTo-StatusDetailPayload `
        -Title 'Rapportgenerering' -Subtitle $GeneratedLocal `
        -Description 'Tidspunkt og maskin som skrev denne konkrete HTML-filen.' `
        -Rows @(
            [PSCustomObject]@{ Label = 'Maskin'; Value = $MachineId }
            [PSCustomObject]@{ Label = 'UTC'; Value = $GeneratedIso }
        )
    $RootDetail = ConvertTo-StatusDetailPayload `
        -Title 'Synkroniseringsrot' -Subtitle $ProjectsBasePath `
        -Description 'Ytre grense for synkronisering og prosjektaliaser. Den bestemmer ikke alene hva som er et prosjekt; eksakt identitet kommer fra agentmetadata.' `
        -Rows @([PSCustomObject]@{ Label = 'Transport'; Value = 'Synkronisert lokal filstruktur' })

    $Html = @"
<!doctype html>
<html lang="no">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="refresh" content="60">
  <title>AgentSync status</title>
  <style>
    :root { color-scheme: light dark; --bg:#f4f6f8; --panel:#fff; --text:#17202a; --muted:#657381; --line:#dfe5ea; --accent:#2563eb; --good:#0f9d67; --warn:#c47700; --bad:#c33c3c; --empty:#7b8794; }
    @media (prefers-color-scheme: dark) { :root { --bg:#11161c; --panel:#19212a; --text:#edf2f7; --muted:#9aa8b6; --line:#2d3945; --accent:#6ea8ff; --good:#45c993; --warn:#f0b34d; --bad:#ff7b7b; --empty:#95a1ad; } }
    * { box-sizing:border-box; }
    body { margin:0; background:var(--bg); color:var(--text); font:14px/1.45 system-ui,-apple-system,"Segoe UI",sans-serif; }
    main { width:calc(100% - 32px); max-width:1500px; margin:28px auto 48px; }
    header { display:flex; justify-content:space-between; gap:24px; align-items:flex-start; margin-bottom:22px; }
    .header-actions { display:flex; align-items:center; gap:8px; flex-wrap:wrap; justify-content:flex-end; }
    .report-action { display:inline-flex; align-items:stretch; }
    .report-link { display:inline-flex; min-height:34px; align-items:center; padding:6px 10px; border:1px solid var(--line); border-radius:9px; background:var(--panel); color:var(--text); text-decoration:none; font-size:12px; font-weight:700; }
    .report-action .report-link { border-radius:9px 0 0 9px; }
    .report-help { appearance:none; display:inline-grid; width:30px; min-height:34px; place-items:center; margin-left:-1px; padding:0; border:1px solid var(--line); border-radius:0 9px 9px 0; background:var(--panel); color:var(--muted); font:800 12px/1 system-ui,-apple-system,"Segoe UI",sans-serif; }
    .report-link:hover,.report-link:focus-visible { border-color:var(--accent); outline:none; }
    h1 { margin:2px 0 4px; font-size:clamp(26px,4vw,42px); letter-spacing:-.03em; }
    h2 { margin:0 0 14px; font-size:18px; }
    p { margin:0; }
    .eyebrow { color:var(--accent); font-weight:700; text-transform:uppercase; letter-spacing:.08em; font-size:12px; }
    button.eyebrow { appearance:none; display:inline-block; margin:0; padding:0; border:0; background:none; font-family:inherit; }
    .muted { color:var(--muted); }
    .interaction-hint { margin-top:7px; color:var(--muted); font-size:11px; }
    .detail-trigger { cursor:help; }
    .detail-trigger:focus-visible { outline:3px solid color-mix(in srgb,var(--accent) 42%,transparent); outline-offset:2px; }
    .service { display:flex; align-items:center; gap:10px; padding:11px 14px; background:var(--panel); border:1px solid var(--line); border-radius:999px; white-space:nowrap; box-shadow:0 8px 24px rgba(20,30,40,.06); }
    button.service { appearance:none; color:var(--text); font:inherit; }
    .dot { width:10px; height:10px; border-radius:50%; background:var(--good); box-shadow:0 0 0 4px color-mix(in srgb,var(--good) 18%,transparent); }
    .service.stale .dot { background:var(--warn); box-shadow:0 0 0 4px color-mix(in srgb,var(--warn) 18%,transparent); }
    .cards { display:grid; grid-template-columns:repeat(auto-fit,minmax(150px,1fr)); gap:12px; margin-bottom:18px; }
    .card,.panel { background:var(--panel); border:1px solid var(--line); border-radius:16px; box-shadow:0 8px 28px rgba(20,30,40,.05); }
    .card { position:relative; padding:16px 18px; }
    button.card { appearance:none; width:100%; color:var(--text); text-align:left; font:inherit; }
    button.card::after,button.audit-card::after { content:"i"; position:absolute; top:9px; right:10px; display:grid; width:17px; height:17px; place-items:center; border:1px solid var(--line); border-radius:50%; color:var(--muted); font:800 10px/1 system-ui,-apple-system,"Segoe UI",sans-serif; }
    button.card:hover,button.audit-card:hover { border-color:color-mix(in srgb,var(--accent) 55%,var(--line)); }
    .card span { display:block; color:var(--muted); font-size:12px; font-weight:650; text-transform:uppercase; letter-spacing:.06em; }
    .card strong { display:block; margin-top:5px; font-size:25px; }
    .panel { overflow:hidden; margin-bottom:18px; }
    .toolbar { display:flex; gap:14px; align-items:center; padding:14px 16px; border-bottom:1px solid var(--line); }
    input[type="search"] { flex:1; min-width:180px; padding:10px 12px; border:1px solid var(--line); border-radius:10px; background:var(--bg); color:var(--text); font:inherit; }
    label { display:flex; gap:7px; align-items:center; color:var(--muted); white-space:nowrap; }
    .table-wrap { overflow:auto; }
    table { width:100%; border-collapse:collapse; min-width:1260px; }
    th,td { padding:12px 14px; border-bottom:1px solid var(--line); text-align:left; vertical-align:middle; }
    th { position:sticky; top:0; background:var(--panel); color:var(--muted); font-size:11px; text-transform:uppercase; letter-spacing:.06em; }
    .column-help { appearance:none; padding:0; border:0; border-bottom:1px dotted currentColor; background:none; color:inherit; font:inherit; text-transform:inherit; letter-spacing:inherit; }
    tr:last-child td { border-bottom:0; }
    tr:hover td { background:color-mix(in srgb,var(--accent) 4%,transparent); }
    td.project { min-width:240px; }
    .project-detail-trigger { appearance:none; display:block; width:100%; margin:0 0 6px; padding:0; border:0; background:none; color:inherit; text-align:left; font:inherit; }
    .project-detail-trigger>strong { display:block; margin-bottom:5px; }
    .project-path { display:block; max-width:420px; margin:0 0 6px; color:var(--muted); font-size:11px; overflow-wrap:anywhere; }
    .cell-detail-trigger { appearance:none; display:block; min-width:100%; margin:0; padding:0; border:0; background:none; color:inherit; text-align:left; font:inherit; }
    td.agent strong,td.total strong { display:block; }
    td.agent span,td.total span { display:block; color:var(--muted); font-size:12px; white-space:nowrap; }
    .zero { color:var(--empty); }
    .agent-tags { display:flex; flex-wrap:wrap; gap:5px; }
    .agent-tag { display:inline-flex; align-items:center; gap:5px; min-height:23px; margin:0; padding:3px 8px 3px 5px; border:1px solid transparent; border-radius:999px; font:750 11px/1 system-ui,-apple-system,"Segoe UI",sans-serif; letter-spacing:.01em; }
    button.agent-tag { appearance:none; cursor:pointer; }
    button.agent-tag:focus-visible { outline:3px solid color-mix(in srgb,var(--accent) 42%,transparent); outline-offset:2px; }
    .detail-trigger { cursor:pointer; }
    .detail-trigger[aria-expanded="true"] { outline:2px solid color-mix(in srgb,var(--accent) 65%,transparent); outline-offset:2px; }
    .agent-logo { display:block; width:15px; height:15px; flex:0 0 15px; border-radius:3px; object-fit:contain; }
    .agent-tag.claude { background:#f7eadf; border-color:#d97757; color:#8f3f24; }
    .agent-tag.codex { padding:7px 9px 7px 5px; background:#111; border:1px solid #666; color:#fff; }
    .agent-tag.antigravity { background:#e8f0fe; border-color:#4285f4; color:#174ea6; }
    .agent-tag.opencode { background:#e5e5e5; border-color:#777; color:#171717; }
    .agent-tag.cline { background:#eef1f4; border-color:#24292f; color:#24292f; }
    .agent-tag.aider { background:#e4f8ec; border-color:#2f9b62; color:#173b2b; }
    .detail-popover { position:fixed; z-index:1000; display:none; width:min(390px,calc(100vw - 24px)); max-height:min(70vh,620px); overflow:auto; padding:14px; border:2px solid #2f8cff; border-radius:12px; background:var(--panel); color:var(--text); box-shadow:0 18px 55px #000b,0 0 0 1px #2f8cff24; animation:detail-border-pulse 1.8s ease-in-out infinite; }
    .detail-popover.open { display:block; }
    @keyframes detail-border-pulse {
      0%,100% { border-color:#2f8cff; box-shadow:0 18px 55px #000b,0 0 0 1px #2f8cff2e; }
      50% { border-color:#fff; box-shadow:0 18px 55px #000b,0 0 0 3px #ffffff42; }
    }
    .detail-head { display:flex; align-items:center; gap:9px; margin-bottom:9px; padding-right:28px; }
    .detail-head .agent-logo { width:22px; height:22px; flex-basis:22px; }
    .detail-head .agent-logo[hidden] { display:none; }
    .detail-head strong { display:block; font-size:14px; }
    .detail-close { appearance:none; position:absolute; top:8px; right:8px; display:grid; width:28px; height:28px; place-items:center; padding:0; border:1px solid var(--line); border-radius:8px; background:var(--bg); color:var(--text); font:500 20px/1 system-ui,-apple-system,"Segoe UI",sans-serif; cursor:pointer; }
    .detail-close:hover,.detail-close:focus-visible { border-color:var(--accent); outline:none; }
    .detail-subtitle { display:block; max-width:315px; color:var(--muted); font-size:11px; overflow-wrap:anywhere; }
    .detail-description { margin:0 0 11px; color:var(--muted); font-size:12px; overflow-wrap:anywhere; }
    .detail-grid { display:grid; grid-template-columns:max-content minmax(0,1fr); gap:6px 12px; margin:0; }
    .detail-grid dt { color:var(--muted); font-size:11px; }
    .detail-grid dd { margin:0; font-size:12px; font-weight:650; overflow-wrap:anywhere; }
    @media(max-width:700px) {
      .detail-popover { inset:auto 12px 12px!important; width:auto; max-height:65vh; }
    }
    @media(prefers-reduced-motion:reduce) {
      .detail-popover { animation:none; }
    }
    .audit-panel { padding:18px; }
    .audit-title { display:flex; align-items:flex-start; justify-content:space-between; gap:18px; margin-bottom:14px; }
    .audit-title h2 { margin-bottom:3px; }
    .audit-overall { appearance:none; display:inline-flex; align-items:center; min-height:30px; max-width:min(100%,760px); padding:5px 10px; border:0; border-radius:999px; font-family:inherit; font-size:12px; font-weight:750; line-height:1.35; text-align:left; white-space:normal; overflow-wrap:anywhere; }
    .audit-overall.ok { background:color-mix(in srgb,var(--good) 13%,transparent); color:var(--good); }
    .audit-overall.warn { background:color-mix(in srgb,var(--warn) 14%,transparent); color:var(--warn); }
    .audit-overall.error { background:color-mix(in srgb,var(--bad) 13%,transparent); color:var(--bad); }
    .audit-grid { display:grid; grid-template-columns:repeat(6,minmax(0,1fr)); align-items:stretch; gap:12px; }
    .audit-card { position:relative; display:flex; min-width:0; height:100%; flex-direction:column; float:none; padding:14px; border:1px solid var(--line); border-left-width:4px; border-radius:12px; background:color-mix(in srgb,var(--bg) 45%,transparent); box-shadow:none; transform:none; }
    button.audit-card { appearance:none; width:100%; color:var(--text); text-align:left; font:inherit; }
    .audit-card.ok { border-left-color:var(--good); }
    .audit-card.warn { border-left-color:var(--warn); }
    .audit-card.error { border-left-color:var(--bad); }
    .audit-head { display:flex; align-items:center; justify-content:space-between; gap:8px; margin-bottom:10px; }
    .audit-state { color:var(--muted); font-size:11px; font-weight:750; text-transform:uppercase; letter-spacing:.04em; }
    .audit-card>strong { display:block; font-size:25px; line-height:1.1; }
    .audit-caption { display:block; margin:3px 0 10px; color:var(--muted); font-size:11px; }
    .audit-meta { display:flex; flex-direction:column; gap:2px; margin-top:auto; color:var(--muted); font-size:11px; overflow-wrap:anywhere; }
    .audit-problem { color:var(--bad); font-weight:700; }
    .conflicts { font-weight:700; }
    .details { padding:18px; }
    .details-heading { appearance:none; margin:0 0 14px; padding:0; border:0; border-bottom:1px dotted var(--muted); background:none; color:var(--text); text-align:left; font:750 18px/1.2 system-ui,-apple-system,"Segoe UI",sans-serif; }
    .issues { margin:0; padding-left:22px; color:var(--muted); }
    .issues li { margin:7px 0; overflow-wrap:anywhere; }
    footer { color:var(--muted); display:flex; justify-content:space-between; gap:20px; flex-wrap:wrap; font-size:12px; }
    .footer-detail { appearance:none; margin:0; padding:0; border:0; border-bottom:1px dotted currentColor; background:none; color:inherit; text-align:left; font:inherit; overflow-wrap:anywhere; }
    @media (max-width:900px) { header { flex-direction:column; } .cards { grid-template-columns:repeat(2,1fr); } .service { align-self:flex-start; } .audit-grid { grid-template-columns:1fr; } }
    @media (max-width:560px) { main { width:calc(100% - 20px); margin-top:16px; } .cards { grid-template-columns:repeat(2,minmax(0,1fr)); } .card:last-child { grid-column:span 2; } .toolbar { align-items:stretch; flex-direction:column; } .audit-title { align-items:stretch; flex-direction:column; } .audit-overall { align-self:flex-start; white-space:normal; } }
  </style>
</head>
<body data-generated-utc="$GeneratedIso">
<main>
  <header>
    <div>
      <button type="button" class="eyebrow detail-trigger" aria-label="Vis informasjon om AgentSync Toolkit v$AgentSyncVersion" aria-expanded="false" aria-controls="detailPopover" data-detail="$VersionDetail">AgentSync Toolkit v$AgentSyncVersion</button>
      <h1>Synkroniseringsoversikt</h1>
      <p class="muted">Prosjekter oppdaget i Claude, Codex, Antigravity, OpenCode, Cline og Aider — uten samtaleinnhold</p>
      <p class="interaction-hint">Hold pekeren over for en rask titt, eller klikk/trykk for å feste detaljene. Bruk samme felt eller × for å lukke.</p>
    </div>
    <div class="header-actions">
      <span class="report-action"><a class="report-link" href="$IntelligenceHref" title="Åpne AgentSync Intelligence">Intelligence</a><button type="button" class="report-help detail-trigger" aria-label="Hva er AgentSync Intelligence?" aria-expanded="false" aria-controls="detailPopover" data-detail="$IntelligenceDetail">i</button></span>
      <span class="report-action"><a class="report-link" href="$RecoveryHref" title="Åpne recovery audit">Recovery</a><button type="button" class="report-help detail-trigger" aria-label="Hva er recovery audit?" aria-expanded="false" aria-controls="detailPopover" data-detail="$RecoveryDetail">i</button></span>
      <button type="button" class="service detail-trigger" id="serviceStatus" aria-label="Vis detaljer om rapportstatus" aria-expanded="false" aria-controls="detailPopover" data-detail="$ServiceDetail"><span class="dot"></span><strong id="serviceText">AgentSync kjører</strong></button>
    </div>
  </header>

  <section class="cards" aria-label="Nøkkeltall">
    <button type="button" class="card detail-trigger" aria-label="Forklar agentprosjekter" aria-expanded="false" aria-controls="detailPopover" data-detail="$AgentProjectsDetail"><span>Agentprosjekter</span><strong>$ProjectCount</strong></button>
    <button type="button" class="card detail-trigger" aria-label="Forklar prosjekter med én agent" aria-expanded="false" aria-controls="detailPopover" data-detail="$SingleAgentDetail"><span>Kun én agent</span><strong>$SingleAgentCount</strong></button>
    <button type="button" class="card detail-trigger" aria-label="Forklar prosjekter med flere agenter" aria-expanded="false" aria-controls="detailPopover" data-detail="$MultiAgentDetail"><span>Flere agenter</span><strong>$MultiAgentCount</strong></button>
    <button type="button" class="card detail-trigger" aria-label="Forklar agentfiler" aria-expanded="false" aria-controls="detailPopover" data-detail="$AgentFilesDetail"><span>Agentfiler</span><strong>$TotalFilesAll</strong></button>
    <button type="button" class="card detail-trigger" aria-label="Forklar samlet størrelse" aria-expanded="false" aria-controls="detailPopover" data-detail="$TotalSizeDetail"><span>Samlet størrelse</span><strong>$TotalSizeAll</strong></button>
    <button type="button" class="card detail-trigger" aria-label="Forklar state uten prosjektsti" aria-expanded="false" aria-controls="detailPopover" data-detail="$UnresolvedDetail"><span>Uten prosjektsti</span><strong>$UnresolvedFiles</strong></button>
    <button type="button" class="card detail-trigger" aria-label="Forklar konfliktfiler" aria-expanded="false" aria-controls="detailPopover" data-detail="$ConflictDetail"><span>Konfliktfiler</span><strong>$ConflictCount</strong></button>
  </section>

  <section class="panel audit-panel" aria-labelledby="auditHeading">
    <div class="audit-title">
      <div><h2 id="auditHeading">Fast selvkontroll</h2><p class="muted">Sammenligner lokale agentprosjekter med radene som faktisk vises.</p></div>
      <button type="button" class="audit-overall $AuditOverallClass detail-trigger" aria-label="Vis detaljer om fast selvkontroll" aria-expanded="false" aria-controls="detailPopover" data-detail="$AuditOverallDetail">$AuditOverallText</button>
    </div>
    <div class="audit-grid">
$AuditHtml
    </div>
  </section>

  <section class="panel">
    <div class="toolbar">
      <input type="search" id="projectSearch" placeholder="Søk etter prosjekt, mappe eller maskin" aria-label="Søk i agentprosjekter">
    </div>
    <div class="table-wrap">
      <table>
        <thead><tr>
          <th><button type="button" class="column-help detail-trigger" aria-label="Forklar prosjektmappe-kolonnen" aria-expanded="false" aria-controls="detailPopover" data-detail="$ProjectColumnDetail">Prosjektmappe</button></th>
          <th><button type="button" class="column-help detail-trigger" aria-label="Forklar Claude-kolonnen" aria-expanded="false" aria-controls="detailPopover" data-detail="$($AgentColumnDetails['Claude'])">Claude</button></th>
          <th><button type="button" class="column-help detail-trigger" aria-label="Forklar Codex-kolonnen" aria-expanded="false" aria-controls="detailPopover" data-detail="$($AgentColumnDetails['Codex'])">Codex</button></th>
          <th><button type="button" class="column-help detail-trigger" aria-label="Forklar Antigravity-kolonnen" aria-expanded="false" aria-controls="detailPopover" data-detail="$($AgentColumnDetails['Antigravity'])">Antigravity</button></th>
          <th><button type="button" class="column-help detail-trigger" aria-label="Forklar OpenCode-kolonnen" aria-expanded="false" aria-controls="detailPopover" data-detail="$($AgentColumnDetails['OpenCode'])">OpenCode</button></th>
          <th><button type="button" class="column-help detail-trigger" aria-label="Forklar Cline-kolonnen" aria-expanded="false" aria-controls="detailPopover" data-detail="$($AgentColumnDetails['Cline'])">Cline</button></th>
          <th><button type="button" class="column-help detail-trigger" aria-label="Forklar Aider-kolonnen" aria-expanded="false" aria-controls="detailPopover" data-detail="$($AgentColumnDetails['Aider'])">Aider</button></th>
          <th><button type="button" class="column-help detail-trigger" aria-label="Forklar totalt-kolonnen" aria-expanded="false" aria-controls="detailPopover" data-detail="$TotalColumnDetail">Totalt</button></th>
          <th><button type="button" class="column-help detail-trigger" aria-label="Forklar siste data-kolonnen" aria-expanded="false" aria-controls="detailPopover" data-detail="$LatestColumnDetail">Siste data</button></th>
          <th><button type="button" class="column-help detail-trigger" aria-label="Forklar maskiner-kolonnen" aria-expanded="false" aria-controls="detailPopover" data-detail="$MachinesColumnDetail">Maskiner</button></th>
        </tr></thead>
        <tbody id="projectRows">
$RowsHtml
        </tbody>
      </table>
    </div>
  </section>

  <section class="panel details">
    <button type="button" class="details-heading detail-trigger" aria-label="Forklar nylige advarsler og feil" aria-expanded="false" aria-controls="detailPopover" data-detail="$IssuesDetail">Nylige advarsler og feil</button>
    $IssuesHtml
  </section>

  <footer>
    <button type="button" class="footer-detail detail-trigger" aria-label="Vis detaljer om rapportgenereringen" aria-expanded="false" aria-controls="detailPopover" data-detail="$GeneratedDetail">Oppdatert $GeneratedLocal av $MachineHtml</button>
    <button type="button" class="footer-detail detail-trigger" aria-label="Forklar synkroniseringsroten" aria-expanded="false" aria-controls="detailPopover" data-detail="$RootDetail">Synkroniseringsrot: $ProjectsPathHtml</button>
  </footer>
  <div id="detailHome">
    <div class="detail-popover" id="detailPopover" role="region" aria-labelledby="detailTitle" aria-hidden="true">
      <div class="detail-head">
        <img class="agent-logo" id="detailIcon" alt="" aria-hidden="true" hidden>
        <div><strong id="detailTitle"></strong><span class="detail-subtitle" id="detailSubtitle"></span></div>
        <button type="button" class="detail-close" id="detailClose" aria-label="Lukk detaljvisningen">×</button>
      </div>
      <p class="detail-description" id="detailDescription"></p>
      <dl class="detail-grid" id="detailGrid"></dl>
    </div>
  </div>
</main>
<script>
(function () {
  var generated = Date.parse(document.body.getAttribute('data-generated-utc'));
  var staleAfterMs = $StaleSeconds * 1000;
  var status = document.getElementById('serviceStatus');
  var statusText = document.getElementById('serviceText');
  function updateServiceStatus() {
    var age = Date.now() - generated;
    if (!Number.isFinite(age) || age > staleAfterMs) {
      status.classList.add('stale');
      statusText.textContent = 'Rapporten er utdatert';
    } else {
      status.classList.remove('stale');
      statusText.textContent = 'AgentSync kjører';
    }
  }
  var detailPopover = document.getElementById('detailPopover');
  var detailHome = document.getElementById('detailHome');
  var detailClose = document.getElementById('detailClose');
  var detailTriggers = Array.from(document.querySelectorAll('.detail-trigger'));
  var activeDetailTrigger = null;
  function readDetailData(trigger) {
    try {
      var parsed = JSON.parse(trigger.getAttribute('data-detail') || '{}');
      return {
        title: parsed.title || 'Informasjon',
        subtitle: parsed.subtitle || '',
        description: parsed.description || '',
        rows: Array.isArray(parsed.rows) ? parsed.rows : []
      };
    } catch (error) {
      return { title: 'Informasjon', subtitle: '', description: 'Detaljene kunne ikke leses.', rows: [] };
    }
  }
  function renderDetailPopover(trigger) {
    var detail = readDetailData(trigger);
    var icon = trigger.querySelector('.agent-logo');
    var detailIcon = document.getElementById('detailIcon');
    if (icon) {
      detailIcon.src = icon.src;
      detailIcon.hidden = false;
    } else {
      detailIcon.removeAttribute('src');
      detailIcon.hidden = true;
    }
    document.getElementById('detailTitle').textContent = detail.title;
    var subtitle = document.getElementById('detailSubtitle');
    subtitle.textContent = detail.subtitle;
    subtitle.hidden = !detail.subtitle;
    var description = document.getElementById('detailDescription');
    description.textContent = detail.description;
    description.hidden = !detail.description;
    var grid = document.getElementById('detailGrid');
    grid.replaceChildren();
    detail.rows.forEach(function (row) {
      var term = document.createElement('dt');
      term.textContent = row.label || '-';
      var value = document.createElement('dd');
      value.textContent = row.value || '-';
      grid.append(term, value);
    });
    grid.hidden = detail.rows.length === 0;
  }
  function resetDetailPlacement() {
    detailPopover.className = 'detail-popover';
    detailPopover.style.left = '';
    detailPopover.style.top = '';
    if (detailPopover.parentElement !== detailHome) {
      detailHome.appendChild(detailPopover);
    }
  }
  function positionDetailPopover(trigger) {
    if (!trigger || window.matchMedia('(max-width: 700px)').matches) return;
    var gap = 12;
    var triggerRect = trigger.getBoundingClientRect();
    var popoverRect = detailPopover.getBoundingClientRect();
    var maxLeft = Math.max(gap, window.innerWidth - popoverRect.width - gap);
    var maxTop = Math.max(gap, window.innerHeight - popoverRect.height - gap);
    var left;
    var top;
    if (window.innerWidth - triggerRect.right >= popoverRect.width + gap) {
      left = triggerRect.right + gap;
      top = triggerRect.top;
    } else if (triggerRect.left >= popoverRect.width + gap) {
      left = triggerRect.left - popoverRect.width - gap;
      top = triggerRect.top;
    } else {
      left = Math.min(Math.max(triggerRect.left, gap), maxLeft);
      if (window.innerHeight - triggerRect.bottom >= popoverRect.height + gap) {
        top = triggerRect.bottom + gap;
      } else {
        top = triggerRect.top - popoverRect.height - gap;
      }
    }
    detailPopover.style.left = Math.round(Math.min(Math.max(left, gap), maxLeft)) + 'px';
    detailPopover.style.top = Math.round(Math.min(Math.max(top, gap), maxTop)) + 'px';
  }
  function closeDetailPopover() {
    if (activeDetailTrigger) activeDetailTrigger.setAttribute('aria-expanded', 'false');
    activeDetailTrigger = null;
    detailPopover.setAttribute('aria-hidden', 'true');
    resetDetailPlacement();
  }
  function showDetailPopover(trigger) {
    if (activeDetailTrigger && activeDetailTrigger !== trigger) {
      activeDetailTrigger.setAttribute('aria-expanded', 'false');
    }
    resetDetailPlacement();
    activeDetailTrigger = trigger;
    renderDetailPopover(trigger);
    detailPopover.classList.add('open');
    detailPopover.setAttribute('aria-hidden', 'false');
    trigger.setAttribute('aria-expanded', 'true');
    positionDetailPopover(trigger);
  }
  detailTriggers.forEach(function (trigger) {
    trigger.addEventListener('click', function (event) {
      event.stopPropagation();
      if (activeDetailTrigger === trigger && detailPopover.getAttribute('aria-hidden') === 'false') {
        closeDetailPopover();
      } else {
        showDetailPopover(trigger);
      }
    });
    trigger.addEventListener('keydown', function (event) {
      if (event.key === 'Escape') {
        closeDetailPopover();
        trigger.blur();
      }
    });
  });
  document.addEventListener('click', function (event) {
    if (activeDetailTrigger && !detailPopover.contains(event.target) && !activeDetailTrigger.contains(event.target)) {
      closeDetailPopover();
    }
  });
  detailClose.addEventListener('click', function (event) {
    event.stopPropagation();
    var trigger = activeDetailTrigger;
    closeDetailPopover();
    if (trigger) trigger.focus();
  });
  document.addEventListener('keydown', function (event) {
    if (event.key === 'Escape' && activeDetailTrigger) closeDetailPopover();
  });
  window.addEventListener('resize', function () {
    if (activeDetailTrigger) positionDetailPopover(activeDetailTrigger);
  });
  window.addEventListener('scroll', function () {
    if (activeDetailTrigger) positionDetailPopover(activeDetailTrigger);
  }, true);
  var search = document.getElementById('projectSearch');
  var rows = Array.from(document.querySelectorAll('#projectRows tr'));
  function filterRows() {
    var query = search.value.trim().toLocaleLowerCase('nb-NO');
    rows.forEach(function (row) {
      var matchesText = !query || row.textContent.toLocaleLowerCase('nb-NO').includes(query);
      row.hidden = !matchesText;
    });
    var activeRow = activeDetailTrigger ? activeDetailTrigger.closest('tr') : null;
    if (activeRow && activeRow.hidden) closeDetailPopover();
  }
  search.addEventListener('input', filterRows);
  updateServiceStatus();
  window.setInterval(updateServiceStatus, 30000);
})();
</script>
</body>
</html>
"@

    Write-Utf8TextAtomic -Path $JsonReportFile -Text $StatusJson
    Write-Utf8TextAtomic -Path $ReportFile -Text $Html
    $Script:StatusReportCoreHash = $CoreHash
    $Script:StatusReportLastWriteUtc = $Now
    Write-AgentSyncLog -Level 'DEBUG' -Message "STATUS_PHASE phase=publish durationMs=$($PublishStopwatch.ElapsedMilliseconds) outcome=written totalMs=$($ReportStopwatch.ElapsedMilliseconds)"
    Write-AgentSyncLog -Level "INFO" -Message "STATUS report=$ReportFile json=$JsonReportFile projects=$ProjectCount singleAgent=$SingleAgentCount multiAgent=$MultiAgentCount files=$TotalFilesAll unresolved=$UnresolvedFiles auditMissing=$AuditMissingCount auditUnavailable=$AuditUnavailableCount auditNoMetadata=$AuditNoMetadataCount"
}

function Resolve-AgentSyncPowerShellExecutable {
    param ([string[]]$Candidates)

    if ($PSBoundParameters.ContainsKey('Candidates')) {
        $CandidateList = @($Candidates)
    }
    else {
        $CandidateList = [System.Collections.Generic.List[string]]::new()
        try {
            $CurrentProcessPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            if (-not [string]::IsNullOrWhiteSpace($CurrentProcessPath)) {
                $CandidateList.Add($CurrentProcessPath)
            }
        }
        catch {
        }

        $PowerShellNames = if ($PlatformName -eq 'windows') {
            @('pwsh.exe', 'powershell.exe')
        }
        else {
            @('pwsh', 'powershell')
        }
        if (-not [string]::IsNullOrWhiteSpace($PSHOME)) {
            foreach ($Name in $PowerShellNames) {
                $CandidateList.Add((Join-Path $PSHOME $Name))
            }
        }
        foreach ($Name in @('pwsh', 'powershell')) {
            $CandidateList.Add($Name)
        }
    }

    foreach ($Candidate in @($CandidateList)) {
        if ([string]::IsNullOrWhiteSpace([string]$Candidate)) {
            continue
        }
        $CandidateText = [string]$Candidate
        if ([System.IO.Path]::IsPathRooted($CandidateText) -or $CandidateText -match '[\\/]') {
            if (Test-Path -LiteralPath $CandidateText -PathType Leaf) {
                return [System.IO.Path]::GetFullPath($CandidateText)
            }
            continue
        }
        $Command = Get-Command $CandidateText -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($Command -and -not [string]::IsNullOrWhiteSpace([string]$Command.Source)) {
            return [System.IO.Path]::GetFullPath([string]$Command.Source)
        }
    }

    throw 'Could not find pwsh or powershell for the Intelligence builder.'
}

function New-AgentSyncPowerShellStartInfo {
    param (
        [string]$PowerShellPath,
        [string]$ScriptPath,
        [string[]]$ScriptArguments = @(),
        [string]$WorkingDirectory
    )

    if ([string]::IsNullOrWhiteSpace($PowerShellPath) -or -not (Test-Path -LiteralPath $PowerShellPath -PathType Leaf)) {
        throw "PowerShell executable not found: $PowerShellPath"
    }
    if ([string]::IsNullOrWhiteSpace($ScriptPath) -or -not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        throw "PowerShell script not found: $ScriptPath"
    }
    if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $WorkingDirectory = Split-Path -Path $ScriptPath -Parent
    }
    if (-not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
        throw "PowerShell working directory not found: $WorkingDirectory"
    }

    $StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $StartInfo.FileName = [System.IO.Path]::GetFullPath($PowerShellPath)
    $StartInfo.WorkingDirectory = [System.IO.Path]::GetFullPath($WorkingDirectory)
    $StartInfo.UseShellExecute = $false
    $StartInfo.CreateNoWindow = $true
    if ($PlatformName -eq 'windows') {
        $StartInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    }
    $StartInfo.RedirectStandardOutput = $true
    $StartInfo.RedirectStandardError = $true
    $StartInfo.Environment['NO_COLOR'] = '1'
    foreach ($Argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', [System.IO.Path]::GetFullPath($ScriptPath))) {
        [void]$StartInfo.ArgumentList.Add([string]$Argument)
    }
    foreach ($Argument in @($ScriptArguments)) {
        [void]$StartInfo.ArgumentList.Add([string]$Argument)
    }
    return $StartInfo
}

function Invoke-AgentSyncPowerShellScript {
    param (
        [string]$ScriptPath,
        [string[]]$ScriptArguments = @(),
        [string]$WorkingDirectory,
        [string]$PowerShellPath,
        [ValidateRange(1, 1800)][int]$TimeoutSeconds = 120
    )

    if ([string]::IsNullOrWhiteSpace($PowerShellPath)) {
        $PowerShellPath = Resolve-AgentSyncPowerShellExecutable
    }
    $StartInfo = New-AgentSyncPowerShellStartInfo -PowerShellPath $PowerShellPath -ScriptPath $ScriptPath -ScriptArguments $ScriptArguments -WorkingDirectory $WorkingDirectory
    return Invoke-AgentSyncBoundedProcess -StartInfo $StartInfo -TimeoutSeconds $TimeoutSeconds
}

function Update-AgentSyncIntelligenceReport {
    if (-not $Config.intelligenceReport -or $Config.intelligenceReport.enabled -eq $false -or $Script:DryRun) {
        return
    }

    $BuilderPath = Join-Path $PSScriptRoot 'Build-AgentSync-Intelligence.ps1'
    if (-not (Test-Path -LiteralPath $BuilderPath -PathType Leaf)) {
        Write-AgentSyncLog -Level 'WARN' -Message "INTELLIGENCE builder missing: $BuilderPath"
        return
    }

    $DataFile = 'AgentSync-Intelligence.json'
    if (-not [string]::IsNullOrWhiteSpace([string]$Config.intelligenceReport.dataFile)) {
        $DataFile = [string]$Config.intelligenceReport.dataFile
    }
    if (-not [System.IO.Path]::IsPathRooted($DataFile)) {
        $DataFile = Join-Path $PSScriptRoot $DataFile
    }
    $DataFile = [System.IO.Path]::GetFullPath($DataFile)

    $RefreshSeconds = 900
    if ($Config.intelligenceReport.refreshSeconds) {
        $RefreshSeconds = [int]$Config.intelligenceReport.refreshSeconds
    }
    $RefreshSeconds = [Math]::Max(300, [Math]::Min(86400, $RefreshSeconds))
    $Now = [System.DateTimeOffset]::UtcNow
    $ReferenceTime = $Script:IntelligenceReportLastRunUtc
    if ($ReferenceTime -gt $Now) { $ReferenceTime = [System.DateTimeOffset]::MinValue }
    if (Test-Path -LiteralPath $DataFile -PathType Leaf) {
        try {
            $FileTime = [System.DateTimeOffset](Get-Item -LiteralPath $DataFile -ErrorAction Stop).LastWriteTimeUtc
            # A file written before a backwards clock correction is not a
            # future refresh deadline. Keep a valid last-attempt throttle.
            if ($FileTime -le $Now -and $FileTime -gt $ReferenceTime) { $ReferenceTime = $FileTime }
        }
        catch {
        }
    }
    if (Test-AgentSyncRecentTimestamp -Since $ReferenceTime -WindowSeconds $RefreshSeconds -Now $Now) {
        return
    }

    # Mark the attempt before launching so a provider-format failure cannot
    # trigger a costly retry on every filesystem event. The builder has its own
    # cross-process mutex and writes both derived files atomically.
    $Script:IntelligenceReportLastRunUtc = $Now
    try {
        $BuilderConfigFile = [System.IO.Path]::GetFullPath($ConfigFile)
        $BuilderTimeout = 120
        if ($Config.intelligenceReport.commandTimeoutSeconds) { $BuilderTimeout = [Math]::Max(1, [Math]::Min(1800, [int]$Config.intelligenceReport.commandTimeoutSeconds)) }
        $WorkBudget = [Math]::Max(1, [int]($BuilderTimeout / 2))
        $BuilderResult = Invoke-AgentSyncPowerShellScript -ScriptPath $BuilderPath -ScriptArguments @('-ConfigFile', $BuilderConfigFile, '-WorkBudgetSeconds', [string]$WorkBudget) -WorkingDirectory $PSScriptRoot -TimeoutSeconds $BuilderTimeout
        foreach ($Line in @(([string]$BuilderResult.StdOut -split '\r?\n'))) {
            if (-not [string]::IsNullOrWhiteSpace($Line)) {
                Write-AgentSyncLog -Level 'DEBUG' -Message "INTELLIGENCE builder stdout: $Line"
            }
        }
        foreach ($Line in @(([string]$BuilderResult.StdErr -split '\r?\n'))) {
            if (-not [string]::IsNullOrWhiteSpace($Line)) {
                Write-AgentSyncLog -Level 'WARN' -Message "INTELLIGENCE builder stderr: $Line"
            }
        }
        if ($BuilderResult.ExitCode -ne 0) {
            $FailureText = ((@($BuilderResult.StdErr, $BuilderResult.StdOut) -join ' ') -replace '\s+', ' ').Trim()
            if ($FailureText.Length -gt 2000) {
                $FailureText = $FailureText.Substring($FailureText.Length - 2000)
            }
            if ([string]::IsNullOrWhiteSpace($FailureText)) {
                $FailureText = 'The builder did not return an error message.'
            }
            throw "Intelligence builder exited with code $($BuilderResult.ExitCode): $FailureText"
        }
        if ([string]$BuilderResult.StdOut -match 'INTELLIGENCE pending:') {
            Write-AgentSyncLog -Level 'WARN' -Message "INTELLIGENCE pending; completed metadata parsing saved, previous report retained. durationMs=$($BuilderResult.DurationMs)"
        }
        else {
            Write-AgentSyncLog -Level 'INFO' -Message "INTELLIGENCE report=$DataFile refreshSeconds=$RefreshSeconds durationMs=$($BuilderResult.DurationMs) process=child"
        }
    }
    catch {
        Write-AgentSyncError -Context 'Intelligence report' -ErrorRecord $_ -Console
    }
}

function Test-AntigravityJsonlChunkPath {
    param ([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not ([System.IO.Path]::GetFileName($Path) -match '^\d{8}\.jsonl$')) {
        return $false
    }

    $NormalizedDirectory = ([System.IO.Path]::GetDirectoryName($Path)) -replace '\\', '/'
    # Two layouts hold the same chunks: the native source keeps the session id
    # under brain/ (brain/<session>/.system_generated/...), while the project
    # copy has already moved it into the session folder (brain/.system_generated/
    # ...). The guard runs against the source path, so it must accept both or
    # the native fragment is still refused as an incomplete JSONL file.
    return $NormalizedDirectory -match '(?i)/brain/(?:[^/]+/)?\.system_generated/logs/chunks/(?:transcript|transcript_full)$'
}

function Test-AppendOnlyName {
    param ([string]$Path)

    # Antigravity's numbered transcript files are fixed-size byte slices of
    # one logical JSONL stream. A slice may begin or end inside a JSON record
    # or a UTF-8 code point, so it must be copied and hashed as opaque bytes.
    # Complete provider JSONL files retain the append-only tail protection.
    return -not (Test-AntigravityJsonlChunkPath -Path $Path) -and
        ([System.IO.Path]::GetExtension($Path)).Equals(".jsonl", [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-AgentSyncContentConflictRecord {
    param (
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$AgentName,
        [Parameter(Mandatory)][string]$DisplayPath,
        [Parameter(Mandatory)][string]$FirstHash,
        [Parameter(Mandatory)][string]$SecondHash
    )

    if ($FirstHash -notmatch '^[A-Fa-f0-9]{64}$' -or $SecondHash -notmatch '^[A-Fa-f0-9]{64}$') {
        throw 'Konfliktpost krever to gyldige SHA-256-verdier.'
    }
    $Hashes = @($FirstHash.ToLowerInvariant(), $SecondHash.ToLowerInvariant()) | Sort-Object
    $Record = [ordered]@{
        schemaVersion = 1
        type = 'content-conflict'
        agent = $AgentName.ToLowerInvariant()
        path = ($DisplayPath -replace '\\', '/')
        hashes = @($Hashes)
        state = 'preserved'
    }
    $Json = $Record | ConvertTo-Json -Compress -Depth 4
    $Sha = [Security.Cryptography.SHA256]::Create()
    try {
        $Id = [Convert]::ToHexString($Sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Json))).ToLowerInvariant()
    }
    finally { $Sha.Dispose() }
    return [pscustomobject]@{
        Id = $Id
        Json = $Json
        Path = Join-Path (Join-Path (Join-Path (Join-Path $ProjectRoot '.agent-state') 'conflicts') 'content') "$Id.json"
    }
}

function Test-AgentSyncContentConflictKnown {
    param (
        [string]$ProjectRoot,
        [string]$AgentName,
        [string]$DisplayPath,
        [string]$FirstHash,
        [string]$SecondHash
    )

    if ([string]::IsNullOrWhiteSpace($ProjectRoot) -or [string]::IsNullOrWhiteSpace($DisplayPath)) { return $false }
    $Record = Get-AgentSyncContentConflictRecord @PSBoundParameters
    if (-not (Test-Path -LiteralPath $Record.Path -PathType Leaf)) { return $false }
    $Existing = [IO.File]::ReadAllText($Record.Path, [Text.Encoding]::UTF8)
    if ($Existing -ne $Record.Json) {
        throw "Innholdsadressert konfliktpost har uventet innhold: $($Record.Path)"
    }
    return $true
}

function Register-AgentSyncContentConflict {
    param (
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$AgentName,
        [Parameter(Mandatory)][string]$DisplayPath,
        [Parameter(Mandatory)][string]$FirstHash,
        [Parameter(Mandatory)][string]$SecondHash
    )

    $Record = Get-AgentSyncContentConflictRecord @PSBoundParameters
    if (Test-AgentSyncContentConflictKnown @PSBoundParameters) {
        return [pscustomobject]@{ Id = $Record.Id; Path = $Record.Path; Created = $false }
    }
    if ($Script:DryRun) {
        return [pscustomobject]@{ Id = $Record.Id; Path = $Record.Path; Created = $false }
    }

    $Directory = [IO.Path]::GetDirectoryName($Record.Path)
    [void][IO.Directory]::CreateDirectory($Directory)
    $Temporary = Join-Path $Directory ('.agentsync-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($Temporary, $Record.Json, [Text.UTF8Encoding]::new($false))
        try { [IO.File]::Move($Temporary, $Record.Path, $false) }
        catch [IO.IOException] {
            # Another machine may have recorded the same content-addressed
            # conflict first. Accept it only when the bytes are identical.
            if (-not (Test-AgentSyncContentConflictKnown @PSBoundParameters)) { throw }
        }
        if (-not (Test-AgentSyncContentConflictKnown @PSBoundParameters)) {
            throw "Konfliktposten kunne ikke verifiseres etter publisering: $($Record.Path)"
        }
        Register-AgentSyncSelfWrite -Path $Record.Path
        return [pscustomobject]@{ Id = $Record.Id; Path = $Record.Path; Created = $true }
    }
    finally {
        if (Test-Path -LiteralPath $Temporary -PathType Leaf) { [IO.File]::Delete($Temporary) }
    }
}

function Save-OverwrittenCopy {
    param (
        [string]$ProjectRoot,
        [string]$AgentName,
        [string]$LoserPath,
        [System.IO.Stream]$SourceStream,
        [string]$ExpectedHash
    )

    if ($Script:DryRun) { return $null }
    if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { throw 'Backup project root is required.' }
    $OwnedSource = $null
    $BackupStream = $null
    try {
        $Stamp = [System.DateTimeOffset]::Now.ToString("yyyyMMdd-HHmmssfff") + '-' + [guid]::NewGuid().ToString('N')
        $Destination = Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $ProjectRoot ".agent-state") "conflicts") "overwritten") $Stamp) (Join-Path $AgentName (Split-Path $LoserPath -Leaf))
        $DestinationDir = Split-Path -Path $Destination -Parent
        New-Item -ItemType Directory -Path $DestinationDir -Force | Out-Null
        if (-not $SourceStream) {
            $OwnedSource = [IO.FileStream]::new($LoserPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            $SourceStream = $OwnedSource
        }
        $SourceHash = Get-AgentSyncStreamHash -Stream $SourceStream
        if ($ExpectedHash -and $SourceHash -ne $ExpectedHash) { throw 'Backup source changed before capture.' }
        $SourceLength = $SourceStream.Length
        $SourceStream.Position = 0
        $BackupStream = [IO.FileStream]::new($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
        $SourceStream.CopyTo($BackupStream)
        $BackupStream.Flush($true)
        if ($BackupStream.Length -ne $SourceLength -or (Get-AgentSyncStreamHash -Stream $BackupStream) -ne $SourceHash) {
            throw 'Backup failed SHA-256 verification; original must not be overwritten.'
        }
        Write-AgentSyncLog -Level "INFO" -Message "OVERWRITE_BACKUP source=$LoserPath backup=$Destination"
        return [PSCustomObject]@{ Path = $Destination; Hash = $SourceHash; Length = $SourceLength }
    }
    finally {
        if ($BackupStream) { $BackupStream.Dispose() }
        if ($OwnedSource) { $OwnedSource.Dispose() }
    }
}

function Sync-FilePair {
    param (
        [string]$LocalPath,
        [string]$CloudPath,
        [string]$AgentName,
        [string]$DisplayPath,
        [string]$ProjectRoot
    )

    $LocalExists = Test-Path -LiteralPath $LocalPath
    $CloudExists = Test-Path -LiteralPath $CloudPath

    if (-not $LocalExists -and -not $CloudExists) {
        return
    }

    if ($LocalExists -and -not $CloudExists) {
        if (Copy-FileSafe -Source $LocalPath -Destination $CloudPath -ProjectRoot $ProjectRoot -AgentName $AgentName -DisplayPath $DisplayPath) {
            Write-Host "[$($AgentName.ToUpper()) LOCAL -> PROJECT] $DisplayPath" -ForegroundColor Green
            Record-SyncSuccess -AgentName $AgentName -Direction "local-to-project" -DisplayPath $DisplayPath -ProjectRoot $ProjectRoot
        }
        return
    }

    if ($CloudExists -and -not $LocalExists) {
        if (Copy-FileSafe -Source $CloudPath -Destination $LocalPath -ProjectRoot $ProjectRoot -AgentName $AgentName -DisplayPath $DisplayPath) {
            Write-Host "[$($AgentName.ToUpper()) PROJECT -> LOCAL] $DisplayPath" -ForegroundColor Cyan
            Record-SyncSuccess -AgentName $AgentName -Direction "project-to-local" -DisplayPath $DisplayPath -ProjectRoot $ProjectRoot
        }
        return
    }

    $LocalInfo = Get-Item -LiteralPath $LocalPath
    $CloudInfo = Get-Item -LiteralPath $CloudPath

    # Size and timestamps are hints, never proof of equality or ancestry.
    # These hashes are rechecked under the destination lease before writing.
    $LocalHash = Get-FileHashSafe -Path $LocalPath
    $CloudHash = Get-FileHashSafe -Path $CloudPath
    if (-not $LocalHash -or -not $CloudHash) {
        try { throw [IO.IOException]::new('Could not verify both sync candidates.') }
        catch { Write-AgentSyncError -Context "Hashing sync candidates: $DisplayPath" -ErrorRecord $_ -Console }
        return
    }
    if ($LocalHash -eq $CloudHash) { return }
    if (Test-AppendOnlyName -Path $CloudPath) {
        try {
            if (Test-AgentSyncContentConflictKnown -ProjectRoot $ProjectRoot -AgentName $AgentName -DisplayPath $DisplayPath -FirstHash $LocalHash -SecondHash $CloudHash) {
                $Script:CycleContentConflicts++
                Write-AgentSyncLog -Level 'DEBUG' -Message 'CONTENT_CONFLICT known; unchanged branches skipped'
                return
            }
        }
        catch {
            Write-AgentSyncError -Context 'Reading content-conflict marker' -ErrorRecord $_ -Console
        }
    }
    if ($LocalInfo.Length -eq $CloudInfo.Length -and (Test-AppendOnlyName -Path $CloudPath)) {
        try {
            $Conflict = Register-AgentSyncContentConflict -ProjectRoot $ProjectRoot -AgentName $AgentName -DisplayPath $DisplayPath -FirstHash $LocalHash -SecondHash $CloudHash
            $Script:CycleContentConflicts++
            if ($Conflict.Created) {
                $Script:CycleNewContentConflicts++
                Write-AgentSyncLog -Level 'WARN' -Message "CONTENT_CONFLICT preserved id=$($Conflict.Id) path=$DisplayPath" -Console
            }
        }
        catch { Write-AgentSyncError -Context 'Recording equal-size content conflict' -ErrorRecord $_ -Console }
        return
    }

    $ProtectAppendOnly = $true
    if ($Config.safety -and $null -ne $Config.safety.protectAppendOnly) {
        $ProtectAppendOnly = [bool]$Config.safety.protectAppendOnly
    }

    if ($LocalInfo.LastWriteTimeUtc -gt $CloudInfo.LastWriteTimeUtc) {
        # Append guard: a newer but smaller jsonl never silently overwrites a
        # larger copy. It may be clock skew or truncation, and the session
        # formats normally only grow.
        if ($ProtectAppendOnly -and $LocalInfo.Length -lt $CloudInfo.Length -and (Test-AppendOnlyName -Path $CloudPath)) {
            Write-AgentSyncLog -Level "WARN" -Message "APPEND_GUARD newer but smaller file, skipping: $DisplayPath (local=$($LocalInfo.Length)B project=$($CloudInfo.Length)B)" -Console
            return
        }
        if (Copy-FileSafe -Source $LocalPath -Destination $CloudPath -ExpectedSourceHash $LocalHash -ExpectedDestinationHash $CloudHash -ProjectRoot $ProjectRoot -AgentName $AgentName -DisplayPath $DisplayPath) {
            Write-Host "[$($AgentName.ToUpper()) LOCAL -> PROJECT] $DisplayPath" -ForegroundColor Green
            Record-SyncSuccess -AgentName $AgentName -Direction "local-to-project" -DisplayPath $DisplayPath -ProjectRoot $ProjectRoot
        }
        return
    }

    if ($CloudInfo.LastWriteTimeUtc -gt $LocalInfo.LastWriteTimeUtc) {
        if ($ProtectAppendOnly -and $CloudInfo.Length -lt $LocalInfo.Length -and (Test-AppendOnlyName -Path $LocalPath)) {
            Write-AgentSyncLog -Level "WARN" -Message "APPEND_GUARD newer but smaller file, skipping: $DisplayPath (project=$($CloudInfo.Length)B local=$($LocalInfo.Length)B)" -Console
            return
        }
        if (Copy-FileSafe -Source $CloudPath -Destination $LocalPath -ExpectedSourceHash $CloudHash -ExpectedDestinationHash $LocalHash -ProjectRoot $ProjectRoot -AgentName $AgentName -DisplayPath $DisplayPath) {
            Write-Host "[$($AgentName.ToUpper()) PROJECT -> LOCAL] $DisplayPath" -ForegroundColor Cyan
            Record-SyncSuccess -AgentName $AgentName -Direction "project-to-local" -DisplayPath $DisplayPath -ProjectRoot $ProjectRoot
        }
        return
    }

    # Equal-time length is only a candidate direction. Copy-FileSafe proves
    # JSONL prefix growth or verifies a backup before replacing other formats.
    if ($LocalInfo.Length -gt $CloudInfo.Length) {
        if (Copy-FileSafe -Source $LocalPath -Destination $CloudPath -ExpectedSourceHash $LocalHash -ExpectedDestinationHash $CloudHash -ProjectRoot $ProjectRoot -AgentName $AgentName -DisplayPath $DisplayPath) {
            Write-Host "[$($AgentName.ToUpper()) LOCAL -> PROJECT] $DisplayPath" -ForegroundColor Green
            Record-SyncSuccess -AgentName $AgentName -Direction "local-to-project" -DisplayPath $DisplayPath -ProjectRoot $ProjectRoot
        }
    }
    elseif ($CloudInfo.Length -gt $LocalInfo.Length) {
        if (Copy-FileSafe -Source $CloudPath -Destination $LocalPath -ExpectedSourceHash $CloudHash -ExpectedDestinationHash $LocalHash -ProjectRoot $ProjectRoot -AgentName $AgentName -DisplayPath $DisplayPath) {
            Write-Host "[$($AgentName.ToUpper()) PROJECT -> LOCAL] $DisplayPath" -ForegroundColor Cyan
            Record-SyncSuccess -AgentName $AgentName -Direction "project-to-local" -DisplayPath $DisplayPath -ProjectRoot $ProjectRoot
        }
    }
    else {
        Write-AgentSyncLog -Level "WARN" -Message "Conflict with no safe winner, skipping: $DisplayPath" -Console
    }
}

function Get-PreferredLocalProjectPath {
    param ([string]$ProjectRoot)

    $ProjectName = Split-Path $ProjectRoot -Leaf
    $ProjectRelative = Get-RelativeChildPath -BasePath $ProjectsBasePath -FullPath $ProjectRoot
    if ($ProjectRelative) {
        $ProjectRelative = $ProjectRelative -replace '\\', '/'
    }

    if ($Config.projectAliases) {
        $Property = $Config.projectAliases.PSObject.Properties |
            Where-Object {
                $AliasKey = ([string]$_.Name) -replace '\\', '/'
                $AliasKey.Equals($ProjectRelative, [System.StringComparison]::OrdinalIgnoreCase) -or
                ($AliasKey.IndexOf('/') -lt 0 -and $AliasKey.Equals($ProjectName, [System.StringComparison]::OrdinalIgnoreCase))
            } |
            Select-Object -First 1

        if ($Property) {
            foreach ($Alias in @($Property.Value)) {
                try {
                    $AliasPath = Expand-ConfiguredPath -Path ([string]$Alias)
                }
                catch {
                    continue
                }

                if (Test-Path -LiteralPath $AliasPath) {
                    return $AliasPath
                }
            }
        }
    }

    return $ProjectRoot
}

function ConvertTo-ClaudeProjectSlug {
    param ([string]$ProjectPath)

    $Full = [System.IO.Path]::GetFullPath($ProjectPath).TrimEnd('\', '/')
    return ($Full -replace '[^A-Za-z0-9]', '-')
}

function Get-ClaudeKnownWorkspaceMap {
    param ([string]$LocalRoot)

    $Workspaces = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ([string]::IsNullOrWhiteSpace($LocalRoot) -or -not (Test-Path -LiteralPath $LocalRoot)) {
        return ,$Workspaces
    }

    $CacheKey = [System.IO.Path]::GetFullPath($LocalRoot).TrimEnd('\', '/')
    $Now = [System.DateTimeOffset]::UtcNow
    $Cached = $Script:ClaudeWorkspaceMapCache[$CacheKey]
    if ($Cached -and (Test-AgentSyncRecentTimestamp -Since $Cached.CreatedUtc -WindowSeconds 30 -Now $Now)) {
        return ,$Cached.Map
    }

    # Claude subagents may run in a subfolder and create a separate artifact-only
    # bucket for that exact cwd. Build a reversible slug -> cwd index from all
    # session metadata so those buckets are not silently skipped.
    foreach ($File in @(Get-ChildItem -LiteralPath $LocalRoot -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue |
        Where-Object { -not (Test-IsConflictCopyName -Name $_.Name) })) {
        $Cwd = Get-SessionCwd -Path $File.FullName
        if ([string]::IsNullOrWhiteSpace($Cwd)) {
            continue
        }
        try {
            $Resolved = Expand-ConfiguredPath -Path $Cwd
            $Slug = ConvertTo-ClaudeProjectSlug -ProjectPath $Resolved
            if (-not $Workspaces.ContainsKey($Slug)) {
                $Workspaces[$Slug] = $Cwd
            }
        }
        catch {
        }
    }

    $Script:ClaudeWorkspaceMapCache[$CacheKey] = [PSCustomObject]@{
        CreatedUtc = $Now
        Map = $Workspaces
    }
    return ,$Workspaces
}

function Get-ClaudeBucketProject {
    param (
        [string]$BucketPath,
        $KnownWorkspaces
    )

    $Candidates = Get-ChildItem -LiteralPath $BucketPath -File -Filter "*.jsonl" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 10

    if (-not $Candidates) {
        $Candidates = Get-ChildItem -LiteralPath $BucketPath -Recurse -File -Filter "*.jsonl" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 10
    }

    foreach ($File in $Candidates) {
        $Cwd = Get-SessionCwd -Path $File.FullName
        $ProjectRoot = Get-ProjectRootFromCwd -Cwd $Cwd
        if ($ProjectRoot) {
            return $ProjectRoot
        }
    }

    if ($KnownWorkspaces -and $KnownWorkspaces.ContainsKey((Split-Path $BucketPath -Leaf))) {
        return (Get-ProjectRootFromCwd -Cwd ([string]$KnownWorkspaces[(Split-Path $BucketPath -Leaf)]))
    }

    return $null
}

function Get-ClaudeBucketFileRoutes {
    param (
        [string]$BucketPath,
        $Files,
        $KnownWorkspaces,
        [string]$StorageProjectRoot
    )

    $FileArray = @($Files)
    $FileCwds = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $ParentSessionCwds = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $DefaultCwd = $null

    foreach ($File in @($FileArray | Where-Object { $_.Extension.Equals('.jsonl', [System.StringComparison]::OrdinalIgnoreCase) })) {
        $Cwd = Get-SessionCwd -Path $File.FullName
        if ([string]::IsNullOrWhiteSpace($Cwd)) {
            continue
        }

        $FileCwds[$File.FullName] = $Cwd
        $Relative = Get-RelativeChildPath -BasePath $BucketPath -FullPath $File.FullName
        if ($Relative -and $Relative -notmatch '[\\/]') {
            $ParentSessionCwds[[System.IO.Path]::GetFileNameWithoutExtension($Relative)] = $Cwd
        }
        if ([string]::IsNullOrWhiteSpace($DefaultCwd)) {
            $DefaultCwd = $Cwd
        }
    }

    $BucketName = Split-Path $BucketPath -Leaf
    if ($KnownWorkspaces -and $KnownWorkspaces.ContainsKey($BucketName)) {
        $DefaultCwd = [string]$KnownWorkspaces[$BucketName]
    }

    $Routes = foreach ($File in $FileArray) {
        $Relative = Get-RelativeChildPath -BasePath $BucketPath -FullPath $File.FullName
        if ($null -eq $Relative) {
            continue
        }

        $Cwd = $null
        if ($FileCwds.ContainsKey($File.FullName)) {
            $Cwd = [string]$FileCwds[$File.FullName]
        }
        else {
            $FirstSegment = if ($Relative) { @($Relative -split '[\\/]')[0] } else { $null }
            if ($FirstSegment -and $ParentSessionCwds.ContainsKey($FirstSegment)) {
                $Cwd = [string]$ParentSessionCwds[$FirstSegment]
            }
            else {
                $Cwd = $DefaultCwd
            }
        }

        $ProjectRoot = Get-ProjectRootFromCwd -Cwd $Cwd
        if (-not $ProjectRoot -and -not [string]::IsNullOrWhiteSpace($StorageProjectRoot)) {
            $Identity = Resolve-StatusAgentProject -Cwd $Cwd -StorageProjectRoot $StorageProjectRoot
            if ($Identity -and (Test-Path -LiteralPath $Identity.ProjectPath -PathType Container)) {
                $ProjectRoot = Register-AgentSyncProjectRoot -ProjectRoot $Identity.ProjectPath
            }
        }
        if (-not $ProjectRoot -and [string]::IsNullOrWhiteSpace($Cwd) -and -not [string]::IsNullOrWhiteSpace($StorageProjectRoot)) {
            $ProjectRoot = $StorageProjectRoot
        }

        [PSCustomObject]@{
            File = $File
            Relative = $Relative
            Cwd = $Cwd
            ProjectRoot = $ProjectRoot
        }
    }

    return @($Routes)
}

function Convert-CwdToLocalPath {
    param ([string]$Cwd)

    if ([string]::IsNullOrWhiteSpace($Cwd)) {
        return $null
    }

    try {
        $Resolved = Expand-ConfiguredPath -Path (Remove-AgentInternalWorkspaceSuffix -Path $Cwd)
    }
    catch {
        return $null
    }

    # Same machine, or an identical shared path across machines.
    if (Test-PathInside -ChildPath $Resolved -ParentPath $ProjectsBasePath) {
        return $Resolved
    }

    # Local aliases are by definition local paths.
    if ($Config.projectAliases) {
        foreach ($Property in $Config.projectAliases.PSObject.Properties) {
            foreach ($Alias in @($Property.Value)) {
                try {
                    $AliasPath = Expand-ConfiguredPath -Path ([string]$Alias)
                }
                catch {
                    continue
                }
                if (Test-PathInside -ChildPath $Resolved -ParentPath $AliasPath) {
                    return $Resolved
                }
            }
        }
    }

    return $null
}

function Resolve-ClaudeLocalBucketPath {
    param (
        [string]$LocalRoot,
        $CloudBucketDir
    )

    # 1. A local bucket with the same name is an exact round trip on the same machine.
    $SameName = Join-Path $LocalRoot $CloudBucketDir.Name
    if (Test-Path -LiteralPath $SameName) {
        return $SameName
    }

    # 2. Translate the cwd from the session content into a local path and rebuild the slug.
    $Candidates = Get-ChildItem -LiteralPath $CloudBucketDir.FullName -Recurse -File -Filter "*.jsonl" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 5

    foreach ($File in $Candidates) {
        $Cwd = Get-SessionCwd -Path $File.FullName
        $LocalCwd = Convert-CwdToLocalPath -Cwd $Cwd
        if ($LocalCwd) {
            return (Join-Path $LocalRoot (ConvertTo-ClaudeProjectSlug -ProjectPath $LocalCwd))
        }
    }

    # 3. Fallback: keep the bucket name from the project state.
    return $SameName
}

function New-AgentSyncFilePairPass {
    # Scoped to one adapter invocation, never cached across cycles. Keep the
    # original copy order: canonical storage created by the local pass must be
    # visible to routing and restore guards during the project pass.
    $Comparer = if ($Script:PathComparison -eq [StringComparison]::OrdinalIgnoreCase) {
        [StringComparer]::OrdinalIgnoreCase
    }
    else { [StringComparer]::Ordinal }
    return [pscustomobject]@{
        Keys = [Collections.Generic.HashSet[string]]::new($Comparer)
        Candidates = 0
    }
}

function Sync-AgentSyncFilePairOnce {
    param ($Pass, [string]$LocalPath, [string]$CloudPath, [string]$AgentName, [string]$DisplayPath, [string]$ProjectRoot)

    # Include both full paths, not a basename or session ID. The same native
    # name can legitimately occur in distinct projects or storage locations.
    $Key = [IO.Path]::GetFullPath($LocalPath) + [char]0 + [IO.Path]::GetFullPath($CloudPath)
    $Pass.Candidates++
    if ($Pass.Keys.Add($Key)) {
        Sync-FilePair -LocalPath $LocalPath -CloudPath $CloudPath -AgentName $AgentName -DisplayPath $DisplayPath -ProjectRoot $ProjectRoot
    }
}

function Write-AgentSyncFilePairPassSummary {
    param ($Pass, [string]$AgentName)

    Write-AgentSyncLog -Level 'DEBUG' -Message "PAIR_PASS agent=$AgentName candidates=$($Pass.Candidates) unique=$($Pass.Keys.Count) duplicates=$($Pass.Candidates - $Pass.Keys.Count)"
}

function Sync-Claude {
    param ($Agent)

    $LocalRoot = Get-PlatformConfiguredPath -Object $Agent
    $TargetSubDir = [string]$Agent.targetSubDir
    $Filters = Get-AgentFileFilters -Agent $Agent
    $KnownWorkspaces = Get-ClaudeKnownWorkspaceMap -LocalRoot $LocalRoot
    $PairPass = New-AgentSyncFilePairPass

    # Local -> project. Route every session/subagent artifact by its own cwd.
    # A single Claude bucket can contain files for both a parent project and a
    # nested project, so bucket-level routing is not precise enough.
    if (Test-Path -LiteralPath $LocalRoot) {
        $Buckets = Get-ChildItem -LiteralPath $LocalRoot -Directory -ErrorAction SilentlyContinue

        foreach ($Bucket in $Buckets) {
            $Files = Get-ChildItem -LiteralPath $Bucket.FullName -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { -not (Test-IsConflictCopyName -Name $_.Name) }

            foreach ($Route in @(Get-ClaudeBucketFileRoutes -BucketPath $Bucket.FullName -Files @($Files) -KnownWorkspaces $KnownWorkspaces)) {
                if (-not $Route.ProjectRoot -or -not (Test-RelativePathMatchesFilter -RelativePath $Route.Relative -Filters $Filters)) {
                    continue
                }

                $CloudRoot = Join-Path (Join-Path $Route.ProjectRoot $TargetSubDir) $Bucket.Name
                $CloudPath = Join-Path $CloudRoot $Route.Relative
                $Display = "$(Split-Path $Route.ProjectRoot -Leaf)\$($Bucket.Name)\$($Route.Relative)"
                Sync-AgentSyncFilePairOnce -Pass $PairPass -LocalPath $Route.File.FullName -CloudPath $CloudPath -AgentName ([string]$Agent.name) -DisplayPath $Display -ProjectRoot $Route.ProjectRoot
            }
        }
    }

    # Project -> local, per bucket subdirectory in the project state.
    $Projects = Get-AgentSyncProjects
    foreach ($Project in $Projects) {
        $CloudRoot = Join-Path $Project.FullName $TargetSubDir
        if (-not (Test-Path -LiteralPath $CloudRoot)) {
            continue
        }

        $CloudBuckets = Get-ChildItem -LiteralPath $CloudRoot -Directory -ErrorAction SilentlyContinue
        foreach ($CloudBucket in $CloudBuckets) {
            $LocalBucket = Resolve-ClaudeLocalBucketPath -LocalRoot $LocalRoot -CloudBucketDir $CloudBucket
            $Files = Get-ChildItem -LiteralPath $CloudBucket.FullName -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { -not (Test-IsConflictCopyName -Name $_.Name) }

            foreach ($Route in @(Get-ClaudeBucketFileRoutes -BucketPath $CloudBucket.FullName -Files @($Files) -KnownWorkspaces $KnownWorkspaces -StorageProjectRoot $Project.FullName)) {
                if (-not (Test-RelativePathMatchesFilter -RelativePath $Route.Relative -Filters $Filters) -or
                    -not (Test-CanonicalStorageProject -Cwd $Route.Cwd -StorageProjectRoot $Project.FullName)) {
                    continue
                }

                $LocalPath = Join-Path $LocalBucket $Route.Relative
                $Display = "$($Project.Name)\$($CloudBucket.Name)\$($Route.Relative)"
                Sync-AgentSyncFilePairOnce -Pass $PairPass -LocalPath $LocalPath -CloudPath $Route.File.FullName -AgentName ([string]$Agent.name) -DisplayPath $Display -ProjectRoot $Project.FullName
            }
        }
    }
    Write-AgentSyncFilePairPassSummary -Pass $PairPass -AgentName ([string]$Agent.name)
}

function Get-RestoreSkipNameSet {
    param ($Agent)

    # Names of sessions the agent has moved elsewhere locally (Codex archives
    # into archived_sessions/). Restoring our project copy into the live
    # sessions folder would silently undo the user's archive action.
    $Names = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($Configured in @($Agent.skipRestoreIfPresentIn)) {
        if ([string]::IsNullOrWhiteSpace([string]$Configured)) {
            continue
        }

        $Root = Expand-ConfiguredPath -Path ([string]$Configured)
        if (-not $Root -or -not (Test-Path -LiteralPath $Root)) {
            continue
        }

        foreach ($File in Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue) {
            [void]$Names.Add($File.Name)
        }
    }

    return $Names
}

function Sync-RoutedFiles {
    param ($Agent)

    $LocalRoot = Get-PlatformConfiguredPath -Object $Agent
    $TargetSubDir = [string]$Agent.targetSubDir
    $Filters = Get-AgentFileFilters -Agent $Agent
    $PairPass = New-AgentSyncFilePairPass

    # Local -> project
    if (Test-Path -LiteralPath $LocalRoot) {
        $Files = Get-ChildItem -LiteralPath $LocalRoot -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { -not (Test-IsConflictCopyName -Name $_.Name) }

        foreach ($File in $Files) {
            $Relative = Get-RelativeChildPath -BasePath $LocalRoot -FullPath $File.FullName
            if ($null -eq $Relative -or -not (Test-RelativePathMatchesFilter -RelativePath $Relative -Filters $Filters)) {
                continue
            }

            $Cwd = Get-SessionCwd -Path $File.FullName
            $ProjectRoot = Get-ProjectRootFromCwd -Cwd $Cwd
            if (-not $ProjectRoot) {
                continue
            }

            $CloudRoot = Join-Path $ProjectRoot $TargetSubDir
            $CloudPath = Join-Path $CloudRoot $Relative
            $Display = "$(Split-Path $ProjectRoot -Leaf)\$Relative"
            Sync-AgentSyncFilePairOnce -Pass $PairPass -LocalPath $File.FullName -CloudPath $CloudPath -AgentName ([string]$Agent.name) -DisplayPath $Display -ProjectRoot $ProjectRoot
        }
    }

    # Project -> local
    $RestoreSkipNames = Get-RestoreSkipNameSet -Agent $Agent
    $Projects = Get-AgentSyncProjects
    foreach ($Project in $Projects) {
        $CloudRoot = Join-Path $Project.FullName $TargetSubDir
        if (-not (Test-Path -LiteralPath $CloudRoot)) {
            continue
        }

        $Files = Get-ChildItem -LiteralPath $CloudRoot -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { -not (Test-IsConflictCopyName -Name $_.Name) }
        foreach ($File in $Files) {
            $Relative = Get-RelativeChildPath -BasePath $CloudRoot -FullPath $File.FullName
            if ($null -eq $Relative -or -not (Test-RelativePathMatchesFilter -RelativePath $Relative -Filters $Filters)) {
                continue
            }

            $StoredCwd = Get-SessionCwd -Path $File.FullName
            if (-not (Test-CanonicalStorageProject -Cwd $StoredCwd -StorageProjectRoot $Project.FullName)) {
                continue
            }

            $LocalPath = Join-Path $LocalRoot $Relative

            # Only a missing local file would be a re-creation. If the session
            # sits in the archive instead, leave it archived.
            if ($RestoreSkipNames.Count -gt 0 -and
                -not (Test-Path -LiteralPath $LocalPath) -and
                $RestoreSkipNames.Contains([System.IO.Path]::GetFileName($Relative))) {

                $SkipKey = "$($Agent.name)|$LocalPath"
                if (-not $Script:RestoreSkipLogged.ContainsKey($SkipKey)) {
                    $Script:RestoreSkipLogged[$SkipKey] = $true
                    Write-AgentSyncLog -Level "INFO" -Message "ARCHIVE_RESPECTED not restored, archived locally: $($Project.Name)\$Relative"
                }
                continue
            }

            $Display = "$($Project.Name)\$Relative"
            Sync-AgentSyncFilePairOnce -Pass $PairPass -LocalPath $LocalPath -CloudPath $File.FullName -AgentName ([string]$Agent.name) -DisplayPath $Display -ProjectRoot $Project.FullName
        }
    }
    Write-AgentSyncFilePairPassSummary -Pass $PairPass -AgentName ([string]$Agent.name)
}

function Get-ClineObjectValue {
    param (
        $Object,
        [string[]]$Paths
    )

    foreach ($Path in @($Paths)) {
        $Current = $Object
        foreach ($Segment in @($Path -split '\.')) {
            if ($null -eq $Current) { break }
            $Property = $Current.PSObject.Properties[$Segment]
            if (-not $Property) {
                $Current = $null
                break
            }
            $Current = $Property.Value
        }
        if ($null -ne $Current -and -not [string]::IsNullOrWhiteSpace([string]$Current)) {
            return $Current
        }
    }
    return $null
}

function Get-ClineSessionInfo {
    param (
        $Object,
        [string]$FallbackId
    )

    if ($null -eq $Object) { return $null }
    $Id = [string](Get-ClineObjectValue -Object $Object -Paths @('session_id', 'sessionId', 'id'))
    if ([string]::IsNullOrWhiteSpace($Id)) { $Id = $FallbackId }
    if (-not (Test-SafeSessionId -Id $Id)) { return $null }

    $Workspace = [string](Get-ClineObjectValue -Object $Object -Paths @(
        'cwdOnTaskInitialization', 'cwd', 'workspace', 'workspaceRoot', 'workspace_root',
        'workspacePath', 'projectPath', 'metadata.cwd', 'metadata.workspaceRoot',
        'metadata.workspace_root'
    ))
    $Model = [string](Get-ClineObjectValue -Object $Object -Paths @(
        'modelId', 'model', 'model_id', 'metadata.modelId', 'metadata.model'
    ))
    $Provider = [string](Get-ClineObjectValue -Object $Object -Paths @(
        'provider', 'providerId', 'provider_id', 'metadata.provider', 'metadata.providerId'
    ))
    $Updated = Get-ClineObjectValue -Object $Object -Paths @(
        'updatedAt', 'updated_at', 'endedAt', 'ended_at', 'ts', 'startedAt', 'started_at'
    )
    return [PSCustomObject]@{
        Id = $Id
        Workspace = $Workspace
        Model = $Model
        Provider = $Provider
        Updated = $Updated
        Object = $Object
    }
}

function Get-ClineLegacyHistoryItems {
    param ([string]$RootPath)

    $ById = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($HistoryPath in @(
        (Join-Path $RootPath 'taskHistory.json'),
        (Join-Path $RootPath 'state\taskHistory.json')
    )) {
        if (-not (Test-Path -LiteralPath $HistoryPath -PathType Leaf)) { continue }
        try {
            $Items = @(Get-Content -LiteralPath $HistoryPath -Raw -Encoding UTF8 | ConvertFrom-Json)
            foreach ($Item in $Items) {
                $Info = Get-ClineSessionInfo -Object $Item -FallbackId $null
                if (-not $Info) { continue }
                $NewTime = ConvertTo-OpenCodeUnixMilliseconds -Value $Info.Updated
                $OldTime = if ($ById.ContainsKey($Info.Id)) {
                    ConvertTo-OpenCodeUnixMilliseconds -Value (Get-ClineSessionInfo -Object $ById[$Info.Id] -FallbackId $Info.Id).Updated
                }
                else { [long]::MinValue }
                if (-not $ById.ContainsKey($Info.Id) -or $NewTime -ge $OldTime) {
                    $ById[$Info.Id] = $Item
                }
            }
        }
        catch {
            Write-AgentSyncLog -Level 'WARN' -Message "CLINE_HISTORY_UNREADABLE not routed from $HistoryPath ($($_.Exception.Message))" -Console
        }
    }
    return @($ById.Values)
}

function Get-ClineLocalSessions {
    param ($Agent)

    $Sessions = New-Object 'System.Collections.Generic.List[object]'
    foreach ($RootConfig in @($Agent.roots)) {
        $Surface = [string]$RootConfig.surface
        if ([string]::IsNullOrWhiteSpace($Surface)) { $Surface = 'default' }
        $Format = [string]$RootConfig.format
        $RootPath = Get-PlatformConfiguredPath -Object $RootConfig
        if (-not $RootPath -or -not (Test-Path -LiteralPath $RootPath -PathType Container)) { continue }

        if ($Format.Equals('legacy', [System.StringComparison]::OrdinalIgnoreCase)) {
            $HistoryById = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($Item in @(Get-ClineLegacyHistoryItems -RootPath $RootPath)) {
                $Info = Get-ClineSessionInfo -Object $Item -FallbackId $null
                if ($Info) { $HistoryById[$Info.Id] = $Item }
            }
            $TasksRoot = Join-Path $RootPath 'tasks'
            if (-not (Test-Path -LiteralPath $TasksRoot -PathType Container)) { continue }
            foreach ($Task in @(Get-ChildItem -LiteralPath $TasksRoot -Directory -ErrorAction SilentlyContinue)) {
                if (-not (Test-SafeSessionId -Id $Task.Name)) { continue }
                $Item = if ($HistoryById.ContainsKey($Task.Name)) { $HistoryById[$Task.Name] } else { $null }
                $Info = if ($Item) { Get-ClineSessionInfo -Object $Item -FallbackId $Task.Name } else { $null }
                if (-not $Info) {
                    foreach ($MetadataName in @('task_metadata.json', 'session.json')) {
                        $MetadataPath = Join-Path $Task.FullName $MetadataName
                        if (-not (Test-Path -LiteralPath $MetadataPath -PathType Leaf)) { continue }
                        try {
                            $Info = Get-ClineSessionInfo -Object (Get-Content -LiteralPath $MetadataPath -Raw -Encoding UTF8 | ConvertFrom-Json) -FallbackId $Task.Name
                        }
                        catch { }
                        if ($Info) { break }
                    }
                }
                $HasLegacySessionData = @(
                    'api_conversation_history.json',
                    'ui_messages.json',
                    'task_metadata.json',
                    'session.json'
                ) | Where-Object { Test-Path -LiteralPath (Join-Path $Task.FullName $_) -PathType Leaf }
                if (-not $Item -and -not $Info -and $HasLegacySessionData.Count -eq 0) {
                    continue
                }
                [void]$Sessions.Add([PSCustomObject]@{
                    Id = $Task.Name; Surface = $Surface; Format = 'legacy'; RootPath = $RootPath
                    SessionRoot = $Task.FullName; Workspace = if ($Info) { $Info.Workspace } else { $null }
                    Model = if ($Info) { $Info.Model } else { $null }; Provider = if ($Info) { $Info.Provider } else { $null }
                    Updated = if ($Info) { $Info.Updated } else { $Task.LastWriteTimeUtc }; HistoryItem = $Item
                })
            }
            continue
        }

        foreach ($Session in @(Get-ChildItem -LiteralPath $RootPath -Directory -ErrorAction SilentlyContinue)) {
            if (-not (Test-SafeSessionId -Id $Session.Name)) { continue }
            $ManifestPath = Join-Path $Session.FullName "$($Session.Name).json"
            $Info = $null
            if (Test-Path -LiteralPath $ManifestPath -PathType Leaf) {
                try {
                    $Info = Get-ClineSessionInfo -Object (Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json) -FallbackId $Session.Name
                }
                catch { }
            }
            [void]$Sessions.Add([PSCustomObject]@{
                Id = $Session.Name; Surface = $Surface; Format = 'manifest'; RootPath = $RootPath
                SessionRoot = $Session.FullName; Workspace = if ($Info) { $Info.Workspace } else { $null }
                Model = if ($Info) { $Info.Model } else { $null }; Provider = if ($Info) { $Info.Provider } else { $null }
                Updated = if ($Info) { $Info.Updated } else { $Session.LastWriteTimeUtc }; HistoryItem = $null
            })
        }
    }
    $SessionArray = @($Sessions.ToArray())
    $KnownById = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Session in $SessionArray) {
        if ([string]::IsNullOrWhiteSpace([string]$Session.Workspace)) { continue }
        if (-not $KnownById.ContainsKey($Session.Id) -or
            [string]$Session.Format -eq 'manifest') {
            $KnownById[$Session.Id] = $Session
        }
    }
    foreach ($Session in $SessionArray) {
        if (-not [string]::IsNullOrWhiteSpace([string]$Session.Workspace) -or
            -not $KnownById.ContainsKey($Session.Id)) {
            continue
        }
        $Known = $KnownById[$Session.Id]
        $Session.Workspace = [string]$Known.Workspace
        if ([string]::IsNullOrWhiteSpace([string]$Session.Model)) { $Session.Model = [string]$Known.Model }
        if ([string]::IsNullOrWhiteSpace([string]$Session.Provider)) { $Session.Provider = [string]$Known.Provider }
    }
    return $SessionArray
}

function Sync-ClineSessionTree {
    param (
        [string]$LocalRoot,
        [string]$ProjectRoot,
        [string]$AgentName,
        [string]$DisplayPrefix,
        [string]$StorageProjectRoot
    )

    $RelativePaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Root in @($LocalRoot, $ProjectRoot)) {
        if (-not (Test-Path -LiteralPath $Root -PathType Container)) { continue }
        foreach ($File in @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { -not (Test-IsConflictCopyName -Name $_.Name) })) {
            $Relative = Get-RelativeChildPath -BasePath $Root -FullPath $File.FullName
            if ($null -ne $Relative) { [void]$RelativePaths.Add($Relative) }
        }
    }
    foreach ($Relative in @($RelativePaths | Sort-Object)) {
        Sync-FilePair -LocalPath (Join-Path $LocalRoot $Relative) -CloudPath (Join-Path $ProjectRoot $Relative) -AgentName $AgentName -DisplayPath "$DisplayPrefix\$Relative" -ProjectRoot $StorageProjectRoot
    }
}

function Write-ClineWorkspaceIndex {
    param (
        [string]$ProjectRoot,
        $Session
    )

    if ($Script:DryRun) { return }
    $IndexPath = Join-Path $ProjectRoot ".agent-state/index/cline-workspaces/$($Session.Surface)/$($Session.Id).json"
    $Index = [ordered]@{
        format = 1
        sessionId = [string]$Session.Id
        surface = [string]$Session.Surface
        sourceFormat = [string]$Session.Format
        workspace = [string]$Session.Workspace
        model = [string]$Session.Model
        provider = [string]$Session.Provider
        updated = $Session.Updated
    }
    Write-Utf8TextIfChanged -Path $IndexPath -Text ($Index | ConvertTo-Json -Depth 8)
}

function Get-ClineStoredSessionInfo {
    param (
        [string]$SessionRoot,
        [string]$WorkspaceIndexPath,
        [string]$SessionId
    )

    if (Test-Path -LiteralPath $WorkspaceIndexPath -PathType Leaf) {
        try {
            $Index = Get-Content -LiteralPath $WorkspaceIndexPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $Info = Get-ClineSessionInfo -Object $Index -FallbackId $SessionId
            if ($Info) { return $Info }
        }
        catch { }
    }
    $NativeRoot = Join-Path $SessionRoot 'native'
    foreach ($Candidate in @(
        (Join-Path $NativeRoot "$SessionId.json"),
        (Join-Path $SessionRoot 'task-history-item.json'),
        (Join-Path $NativeRoot 'task_metadata.json')
    )) {
        if (-not (Test-Path -LiteralPath $Candidate -PathType Leaf)) { continue }
        try {
            $Info = Get-ClineSessionInfo -Object (Get-Content -LiteralPath $Candidate -Raw -Encoding UTF8 | ConvertFrom-Json) -FallbackId $SessionId
            if ($Info) { return $Info }
        }
        catch { }
    }
    return $null
}

function Merge-ClineLegacyHistoryItem {
    param (
        [string]$RootPath,
        $IncomingItem,
        [string]$LocalWorkspace
    )

    if ($null -eq $IncomingItem) { return }
    $IncomingInfo = Get-ClineSessionInfo -Object $IncomingItem -FallbackId $null
    if (-not $IncomingInfo) { return }

    $HistoryPath = @(
        (Join-Path $RootPath 'taskHistory.json'),
        (Join-Path $RootPath 'state\taskHistory.json')
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $HistoryPath) { $HistoryPath = Join-Path $RootPath 'taskHistory.json' }

    $Items = @()
    if (Test-Path -LiteralPath $HistoryPath -PathType Leaf) {
        try { $Items = @(Get-Content -LiteralPath $HistoryPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { $Items = @() }
    }
    $Copy = $IncomingItem | ConvertTo-Json -Depth 30 | ConvertFrom-Json
    if (-not [string]::IsNullOrWhiteSpace($LocalWorkspace)) {
        if ($Copy.PSObject.Properties['cwdOnTaskInitialization']) {
            $Copy.cwdOnTaskInitialization = $LocalWorkspace
        }
        else {
            $Copy | Add-Member -NotePropertyName cwdOnTaskInitialization -NotePropertyValue $LocalWorkspace
        }
    }
    $Merged = New-Object 'System.Collections.Generic.List[object]'
    $Replaced = $false
    foreach ($Item in $Items) {
        $Info = Get-ClineSessionInfo -Object $Item -FallbackId $null
        if ($Info -and $Info.Id.Equals($IncomingInfo.Id, [System.StringComparison]::OrdinalIgnoreCase)) {
            $OldTime = ConvertTo-OpenCodeUnixMilliseconds -Value $Info.Updated
            $NewTime = ConvertTo-OpenCodeUnixMilliseconds -Value $IncomingInfo.Updated
            [void]$Merged.Add($(if ($NewTime -ge $OldTime) { $Copy } else { $Item }))
            $Replaced = $true
        }
        else { [void]$Merged.Add($Item) }
    }
    if (-not $Replaced) { [void]$Merged.Add($Copy) }
    if ($Script:DryRun) {
        Write-AgentSyncLog -Level 'INFO' -Message "DRYRUN CLINE_HISTORY_MERGE session=$($IncomingInfo.Id) target=$HistoryPath"
        return
    }
    $Sorted = @($Merged.ToArray() | Sort-Object { ConvertTo-OpenCodeUnixMilliseconds -Value (Get-ClineSessionInfo -Object $_ -FallbackId $null).Updated } -Descending)
    Write-Utf8TextIfChanged -Path $HistoryPath -Text ($Sorted | ConvertTo-Json -Depth 30)
}

function Update-ClineLocalManifestWorkspace {
    param (
        [string]$ManifestPath,
        [string]$Workspace
    )

    if ($Script:DryRun -or -not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { return }
    try {
        $Manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($Name in @('cwd', 'workspace_root')) {
            if ($Manifest.PSObject.Properties[$Name]) { $Manifest.$Name = $Workspace }
            else { $Manifest | Add-Member -NotePropertyName $Name -NotePropertyValue $Workspace }
        }
        Write-Utf8TextIfChanged -Path $ManifestPath -Text ($Manifest | ConvertTo-Json -Depth 30)
    }
    catch {
        Write-AgentSyncLog -Level 'WARN' -Message "CLINE_MANIFEST_REMAP_FAILED path=$ManifestPath ($($_.Exception.Message))" -Console
    }
}

function Sync-Cline {
    param ($Agent)

    $TargetSubDir = [string]$Agent.targetSubDir
    foreach ($Session in @(Get-ClineLocalSessions -Agent $Agent)) {
        if ([string]::IsNullOrWhiteSpace([string]$Session.Workspace)) { continue }
        $ProjectRoot = Get-ProjectRootFromCwd -Cwd ([string]$Session.Workspace)
        if (-not $ProjectRoot) { continue }
        $CloudSessionRoot = Join-Path (Join-Path (Join-Path (Join-Path $ProjectRoot $TargetSubDir) $Session.Surface) 'sessions') $Session.Id
        $CloudNativeRoot = Join-Path $CloudSessionRoot 'native'
        Sync-ClineSessionTree -LocalRoot $Session.SessionRoot -ProjectRoot $CloudNativeRoot -AgentName ([string]$Agent.name) -DisplayPrefix "$(Split-Path $ProjectRoot -Leaf)\$($Session.Surface)\$($Session.Id)" -StorageProjectRoot $ProjectRoot

        if ($Session.HistoryItem) {
            $HistoryItemPath = Join-Path $CloudSessionRoot 'task-history-item.json'
            $WriteHistory = $true
            if (Test-Path -LiteralPath $HistoryItemPath -PathType Leaf) {
                try {
                    $ExistingInfo = Get-ClineSessionInfo -Object (Get-Content -LiteralPath $HistoryItemPath -Raw -Encoding UTF8 | ConvertFrom-Json) -FallbackId $Session.Id
                    $WriteHistory = (ConvertTo-OpenCodeUnixMilliseconds -Value $Session.Updated) -ge (ConvertTo-OpenCodeUnixMilliseconds -Value $ExistingInfo.Updated)
                }
                catch { }
            }
            if ($WriteHistory -and -not $Script:DryRun) {
                Write-Utf8TextIfChanged -Path $HistoryItemPath -Text ($Session.HistoryItem | ConvertTo-Json -Depth 30)
            }
        }
        Write-ClineWorkspaceIndex -ProjectRoot $ProjectRoot -Session $Session
    }

    foreach ($Project in @(Get-AgentSyncProjects)) {
        $CloudRoot = Join-Path $Project.FullName $TargetSubDir
        if (-not (Test-Path -LiteralPath $CloudRoot -PathType Container)) { continue }
        foreach ($SurfaceDir in @(Get-ChildItem -LiteralPath $CloudRoot -Directory -ErrorAction SilentlyContinue)) {
            $RootConfig = @($Agent.roots | Where-Object { ([string]$_.surface).Equals($SurfaceDir.Name, [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1)
            if ($RootConfig.Count -eq 0) { continue }
            $LocalRoot = Get-PlatformConfiguredPath -Object $RootConfig[0]
            if (-not $LocalRoot) { continue }
            $Format = [string]$RootConfig[0].format
            $SessionsRoot = Join-Path $SurfaceDir.FullName 'sessions'
            if (-not (Test-Path -LiteralPath $SessionsRoot -PathType Container)) { continue }
            foreach ($CloudSession in @(Get-ChildItem -LiteralPath $SessionsRoot -Directory -ErrorAction SilentlyContinue)) {
                if (-not (Test-SafeSessionId -Id $CloudSession.Name)) { continue }
                $IndexPath = Join-Path $Project.FullName ".agent-state/index/cline-workspaces/$($SurfaceDir.Name)/$($CloudSession.Name).json"
                $Info = Get-ClineStoredSessionInfo -SessionRoot $CloudSession.FullName -WorkspaceIndexPath $IndexPath -SessionId $CloudSession.Name
                if (-not $Info -or -not (Test-CanonicalStorageProject -Cwd $Info.Workspace -StorageProjectRoot $Project.FullName)) { continue }
                $LocalSessionRoot = if ($Format.Equals('legacy', [System.StringComparison]::OrdinalIgnoreCase)) {
                    Join-Path (Join-Path $LocalRoot 'tasks') $CloudSession.Name
                }
                else { Join-Path $LocalRoot $CloudSession.Name }
                $CloudNativeRoot = Join-Path $CloudSession.FullName 'native'
                Sync-ClineSessionTree -LocalRoot $LocalSessionRoot -ProjectRoot $CloudNativeRoot -AgentName ([string]$Agent.name) -DisplayPrefix "$($Project.Name)\$($SurfaceDir.Name)\$($CloudSession.Name)" -StorageProjectRoot $Project.FullName

                if ($Format.Equals('legacy', [System.StringComparison]::OrdinalIgnoreCase)) {
                    $HistoryItemPath = Join-Path $CloudSession.FullName 'task-history-item.json'
                    if (Test-Path -LiteralPath $HistoryItemPath -PathType Leaf) {
                        try {
                            $Item = Get-Content -LiteralPath $HistoryItemPath -Raw -Encoding UTF8 | ConvertFrom-Json
                            Merge-ClineLegacyHistoryItem -RootPath $LocalRoot -IncomingItem $Item -LocalWorkspace $Project.FullName
                        }
                        catch { }
                    }
                }
                else {
                    Update-ClineLocalManifestWorkspace -ManifestPath (Join-Path $LocalSessionRoot "$($CloudSession.Name).json") -Workspace $Project.FullName
                }
            }
        }
    }
}

# --- Junie (JetBrains) --------------------------------------------------------
# Junie keeps its sessions inside each JetBrains IDE's system directory, one
# folder per project: <system>/<IDE><version>/projects/<name>.<hash>/matterhorn/
# .matterhorn/. The folder name is the IDE's project name plus Java's
# String.hashCode of the project path. The hash is the only reliable link back
# to the project: two projects can share a name, and the IDE can rename one.
#
# Capture runs one way, IDE to project. Writing back into a live IDE system
# directory is a separate decision and is deliberately not made here.

function Get-JavaStringHash {
    param ([string]$Text)
    # String.hashCode over UTF-16 code units, kept as the unsigned 32-bit value
    # Integer.toHexString prints.
    [uint64]$Hash = 0
    foreach ($Char in $Text.ToCharArray()) {
        $Hash = (($Hash * 31) + [uint64][int]$Char) % 4294967296
    }
    return [uint32]$Hash
}

function Split-JunieProjectFolderName {
    param ([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name -notmatch '^(?<name>.+)\.(?<hash>[0-9A-Fa-f]{1,8})$') {
        return $null
    }
    return [PSCustomObject]@{
        Name = $Matches['name']
        Hash = [Convert]::ToUInt32($Matches['hash'], 16)
    }
}

function Get-JunieOptionsRoot {
    param ($RootConfig)
    $Candidate = $null
    switch ($PlatformName) {
        'windows' { if ($RootConfig.optionsPathWindows) { $Candidate = [string]$RootConfig.optionsPathWindows } }
        'macos'   { if ($RootConfig.optionsPathMacOS)   { $Candidate = [string]$RootConfig.optionsPathMacOS } }
        'linux'   { if ($RootConfig.optionsPathLinux)   { $Candidate = [string]$RootConfig.optionsPathLinux } }
    }
    if ([string]::IsNullOrWhiteSpace($Candidate) -and $RootConfig.optionsPath) {
        $Candidate = [string]$RootConfig.optionsPath
    }
    if ([string]::IsNullOrWhiteSpace($Candidate)) { return $null }
    try { return Expand-ConfiguredPath -Path $Candidate } catch { return $null }
}

function Get-JunieRecentProjectPaths {
    param (
        [string]$OptionsRoot,
        [string]$IdeDirName
    )
    if ([string]::IsNullOrWhiteSpace($OptionsRoot) -or [string]::IsNullOrWhiteSpace($IdeDirName)) { return @() }
    $XmlPath = Join-Path (Join-Path (Join-Path $OptionsRoot $IdeDirName) 'options') 'recentProjects.xml'
    if (-not (Test-Path -LiteralPath $XmlPath -PathType Leaf)) { return @() }
    try {
        $Document = [System.Xml.XmlDocument]::new()
        $Document.XmlResolver = $null
        $Document.Load($XmlPath)
    }
    catch {
        Write-AgentSyncLog -Level 'WARN' -Message "JUNIE_RECENT_UNREADABLE ide=$IdeDirName ($($_.Exception.Message))"
        return @()
    }
    # The IDE writes paths under the home folder with a macro, but hashes the
    # real path. The macro has to be expanded before the hash can match.
    $UserHome = ([Environment]::GetFolderPath('UserProfile')).Replace('\', '/').TrimEnd('/')
    $Paths = [System.Collections.Generic.List[string]]::new()
    foreach ($Node in @($Document.SelectNodes('//entry[@key]'))) {
        $Key = [string]$Node.GetAttribute('key')
        if ($Key.StartsWith('$USER_HOME$', [System.StringComparison]::Ordinal)) {
            $Key = $UserHome + $Key.Substring('$USER_HOME$'.Length)
        }
        if ($Key -match '^[A-Za-z]:/' -or $Key.StartsWith('/')) { [void]$Paths.Add($Key) }
    }
    return @($Paths)
}

function Resolve-JunieProjectPath {
    param (
        [string]$FolderName,
        [string[]]$Candidates
    )
    $Folder = Split-JunieProjectFolderName -Name $FolderName
    if (-not $Folder) { return $null }
    $Seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $Hits = [System.Collections.Generic.List[string]]::new()
    foreach ($Candidate in @($Candidates)) {
        if ([string]::IsNullOrWhiteSpace($Candidate) -or -not $Seen.Add($Candidate)) { continue }
        if ((Get-JavaStringHash -Text $Candidate) -eq $Folder.Hash) { [void]$Hits.Add($Candidate) }
    }
    if ($Hits.Count -eq 1) { return $Hits[0] }
    if ($Hits.Count -gt 1) {
        # A 32-bit hash can collide. The IDE's project name breaks the tie; if
        # it cannot, the sessions are left where they are rather than placed in
        # the wrong project.
        $Named = @($Hits | Where-Object { ($_.TrimEnd('/') -split '/')[-1] -ceq $Folder.Name })
        if ($Named.Count -eq 1) { return $Named[0] }
    }
    return $null
}

function Get-JunieChainFiles {
    param (
        [string]$MatterhornRoot,
        [string]$ChainId
    )
    $Files = [System.Collections.Generic.List[string]]::new()
    $IssuesRoot = Join-Path $MatterhornRoot 'issues'
    $ChainName = "chain-$ChainId"
    if (Test-Path -LiteralPath (Join-Path $IssuesRoot "$ChainName.json") -PathType Leaf) {
        [void]$Files.Add((Join-Path 'issues' "$ChainName.json"))
    }
    $ChainRoot = Join-Path $IssuesRoot $ChainName
    if (Test-Path -LiteralPath $ChainRoot -PathType Container) {
        foreach ($File in @(Get-ChildItem -LiteralPath $ChainRoot -Recurse -File -ErrorAction SilentlyContinue)) {
            if (Test-IsConflictCopyName -Name $File.Name) { continue }
            $Relative = Get-RelativeChildPath -BasePath $MatterhornRoot -FullPath $File.FullName
            if ($Relative) { [void]$Files.Add($Relative) }
        }
    }
    $ExitRoot = Join-Path $MatterhornRoot 'exit_status'
    if (Test-Path -LiteralPath $ExitRoot -PathType Container) {
        foreach ($File in @(Get-ChildItem -LiteralPath $ExitRoot -File -ErrorAction SilentlyContinue)) {
            # One status file per task, named "<chain id> <task index>.status".
            if ($File.Name.StartsWith("$ChainId ", [System.StringComparison]::OrdinalIgnoreCase)) {
                [void]$Files.Add((Join-Path 'exit_status' $File.Name))
            }
        }
    }
    return @($Files | Sort-Object)
}

function Get-JunieLocalSessions {
    param ($Agent)

    if ($null -eq $Script:JunieUnresolvedReported) { $Script:JunieUnresolvedReported = @{} }
    $Sessions = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $KnownProjects = $null
    foreach ($RootConfig in @($Agent.roots)) {
        if (-not ([string]$RootConfig.surface).Equals('ide', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $SystemRoot = Get-PlatformConfiguredPath -Object $RootConfig
        if (-not $SystemRoot -or -not (Test-Path -LiteralPath $SystemRoot -PathType Container)) { continue }
        $OptionsRoot = Get-JunieOptionsRoot -RootConfig $RootConfig
        foreach ($IdeDir in @(Get-ChildItem -LiteralPath $SystemRoot -Directory -ErrorAction SilentlyContinue)) {
            $ProjectsDir = Join-Path $IdeDir.FullName 'projects'
            if (-not (Test-Path -LiteralPath $ProjectsDir -PathType Container)) { continue }
            $Recent = $null
            foreach ($ProjectDir in @(Get-ChildItem -LiteralPath $ProjectsDir -Directory -ErrorAction SilentlyContinue)) {
                $MatterhornRoot = Join-Path (Join-Path $ProjectDir.FullName 'matterhorn') '.matterhorn'
                $IssuesRoot = Join-Path $MatterhornRoot 'issues'
                if (-not (Test-Path -LiteralPath $IssuesRoot -PathType Container)) { continue }

                # The IDE's own recent-project list names the paths it hashed.
                # AgentSync's known projects cover anything that fell off it.
                if ($null -eq $Recent) { $Recent = @(Get-JunieRecentProjectPaths -OptionsRoot $OptionsRoot -IdeDirName $IdeDir.Name) }
                $Workspace = Resolve-JunieProjectPath -FolderName $ProjectDir.Name -Candidates $Recent
                if (-not $Workspace) {
                    if ($null -eq $KnownProjects) {
                        $KnownProjects = @(Get-AgentSyncProjects | ForEach-Object { ([string]$_.FullName).Replace('\', '/') })
                    }
                    $Workspace = Resolve-JunieProjectPath -FolderName $ProjectDir.Name -Candidates $KnownProjects
                }
                if (-not $Workspace) {
                    $Key = "$($IdeDir.Name)|$($ProjectDir.Name)"
                    if (-not $Script:JunieUnresolvedReported.ContainsKey($Key)) {
                        $Script:JunieUnresolvedReported[$Key] = $true
                        Write-AgentSyncLog -Level 'WARN' -Message "JUNIE_PROJECT_UNRESOLVED ide=$($IdeDir.Name) folder=$($ProjectDir.Name): no known project path has this hash; sessions left in place"
                    }
                    continue
                }
                if ($PlatformName -eq 'windows') { $Workspace = $Workspace.Replace('/', '\') }

                foreach ($ChainFile in @(Get-ChildItem -LiteralPath $IssuesRoot -File -Filter 'chain-*.json' -ErrorAction SilentlyContinue)) {
                    $Id = $ChainFile.BaseName.Substring('chain-'.Length)
                    if (-not (Test-SafeSessionId -Id $Id)) { continue }
                    $Created = $null
                    $State = $null
                    try {
                        $Chain = Get-Content -LiteralPath $ChainFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                        $Created = [string]$Chain.created
                        $State = [string]$Chain.state
                    }
                    catch { }
                    $Session = [PSCustomObject]@{
                        Id = $Id
                        Surface = 'ide'
                        Ide = $IdeDir.Name
                        ProjectFolder = $ProjectDir.Name
                        Workspace = $Workspace
                        MatterhornRoot = $MatterhornRoot
                        Files = @(Get-JunieChainFiles -MatterhornRoot $MatterhornRoot -ChainId $Id)
                        Created = $Created
                        State = $State
                        Updated = $ChainFile.LastWriteTimeUtc
                    }
                    # The same conversation under two IDE directories, as after
                    # an upgrade, would overwrite itself every cycle if both
                    # were captured. The newest copy is the one that is kept.
                    if ($Sessions.ContainsKey($Id) -and $Session.Updated -le $Sessions[$Id].Updated) { continue }
                    $Sessions[$Id] = $Session
                }
            }
        }
    }
    return @($Sessions.Values)
}

function Copy-JunieFileToProject {
    param (
        [string]$Source,
        [string]$Destination,
        [string]$AgentName,
        [string]$DisplayPath,
        [string]$ProjectRoot
    )
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { return $false }
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        $SourceHash = Get-FileHashSafe -Path $Source
        $DestinationHash = Get-FileHashSafe -Path $Destination
        if (-not $SourceHash -or -not $DestinationHash -or $SourceHash -eq $DestinationHash) { return $false }
        # One direction only: the IDE's file is the record and the project copy
        # follows it. Copy-FileSafe keeps the replaced version as a backup.
        $Copied = Copy-FileSafe -Source $Source -Destination $Destination -ExpectedSourceHash $SourceHash -ExpectedDestinationHash $DestinationHash -ProjectRoot $ProjectRoot -AgentName $AgentName -DisplayPath $DisplayPath
    }
    else {
        $Copied = Copy-FileSafe -Source $Source -Destination $Destination -ProjectRoot $ProjectRoot -AgentName $AgentName -DisplayPath $DisplayPath
    }
    if ($Copied) {
        Write-Host "[$($AgentName.ToUpper()) LOCAL -> PROJECT] $DisplayPath" -ForegroundColor Green
        Record-SyncSuccess -AgentName $AgentName -Direction 'local-to-project' -DisplayPath $DisplayPath -ProjectRoot $ProjectRoot
    }
    return [bool]$Copied
}

function Write-JunieWorkspaceIndex {
    param (
        [string]$ProjectRoot,
        $Session
    )
    if ($Script:DryRun) { return }
    # Where the session came from. The IDE folder and its hash belong to this
    # machine's path, which is what a later restore would have to recompute.
    $IndexPath = Join-Path $ProjectRoot ".agent-state/index/junie-workspaces/$($Session.Surface)/$($Session.Id).json"
    $Index = [ordered]@{
        format = 1
        sessionId = [string]$Session.Id
        surface = [string]$Session.Surface
        ide = [string]$Session.Ide
        projectFolder = [string]$Session.ProjectFolder
        workspace = [string]$Session.Workspace
        machine = [string]$Script:MachineId
        created = $Session.Created
        state = $Session.State
    }
    Write-Utf8TextIfChanged -Path $IndexPath -Text ($Index | ConvertTo-Json -Depth 5)
}

function Sync-Junie {
    param ($Agent)

    $TargetSubDir = [string]$Agent.targetSubDir
    $AgentName = [string]$Agent.name
    foreach ($Session in @(Get-JunieLocalSessions -Agent $Agent)) {
        $ProjectRoot = Get-ProjectRootFromCwd -Cwd ([string]$Session.Workspace)
        if (-not $ProjectRoot) { continue }
        $NativeRoot = Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $ProjectRoot $TargetSubDir) $Session.Surface) 'sessions') $Session.Id) 'native'
        $DisplayPrefix = "$(Split-Path $ProjectRoot -Leaf)\$($Session.Surface)\$($Session.Id)"
        foreach ($Relative in @($Session.Files)) {
            [void](Copy-JunieFileToProject -Source (Join-Path $Session.MatterhornRoot $Relative) -Destination (Join-Path $NativeRoot $Relative) -AgentName $AgentName -DisplayPath "$DisplayPrefix\$Relative" -ProjectRoot $ProjectRoot)
        }
        Write-JunieWorkspaceIndex -ProjectRoot $ProjectRoot -Session $Session
    }
}

function Get-JunieWatchPaths {
    param ($Agent)
    # One watcher per project folder Junie has written to. The IDE system
    # folder above it also holds indexes, caches and logs that change all the
    # time; watching it would wake the engine constantly, and a watcher that
    # overflows its buffer forces a full cycle. A project where Junie is used
    # for the first time is found by the next cycle, which refreshes this list.
    $Paths = [System.Collections.Generic.List[string]]::new()
    foreach ($RootConfig in @($Agent.roots)) {
        if (-not ([string]$RootConfig.surface).Equals('ide', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $SystemRoot = Get-PlatformConfiguredPath -Object $RootConfig
        if (-not $SystemRoot -or -not (Test-Path -LiteralPath $SystemRoot -PathType Container)) { continue }
        foreach ($IdeDir in @(Get-ChildItem -LiteralPath $SystemRoot -Directory -ErrorAction SilentlyContinue)) {
            $ProjectsDir = Join-Path $IdeDir.FullName 'projects'
            if (-not (Test-Path -LiteralPath $ProjectsDir -PathType Container)) { continue }
            foreach ($ProjectDir in @(Get-ChildItem -LiteralPath $ProjectsDir -Directory -ErrorAction SilentlyContinue)) {
                $MatterhornRoot = Join-Path (Join-Path $ProjectDir.FullName 'matterhorn') '.matterhorn'
                if (Test-Path -LiteralPath $MatterhornRoot -PathType Container) { [void]$Paths.Add($MatterhornRoot) }
            }
        }
    }
    return @($Paths)
}

function ConvertTo-OpenCodeUnixMilliseconds {
    param ($Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return [long]0
    }

    try {
        return [long]$Value
    }
    catch {
        try {
            return ([System.DateTimeOffset]::Parse(
                [string]$Value,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind)).ToUnixTimeMilliseconds()
        }
        catch {
            return [long]0
        }
    }
}

function Get-OpenCodeCommandPath {
    param ($Agent)

    $Configured = [string]$Agent.command
    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT -and
        -not [string]::IsNullOrWhiteSpace([string]$Agent.commandWindows)) {
        $Configured = [string]$Agent.commandWindows
    }
    elseif ($PlatformName -eq 'macOS' -and -not [string]::IsNullOrWhiteSpace([string]$Agent.commandMacOS)) {
        $Configured = [string]$Agent.commandMacOS
    }
    elseif ($PlatformName -eq 'Linux' -and -not [string]::IsNullOrWhiteSpace([string]$Agent.commandLinux)) {
        $Configured = [string]$Agent.commandLinux
    }

    if ([string]::IsNullOrWhiteSpace($Configured)) {
        $Configured = 'opencode'
    }

    if ([System.IO.Path]::IsPathRooted($Configured) -or $Configured.StartsWith('~') -or $Configured -match '[\\/]') {
        try {
            $Resolved = Expand-ConfiguredPath -Path $Configured
            if (Test-Path -LiteralPath $Resolved -PathType Leaf) {
                return $Resolved
            }
        }
        catch {
        }
        return $null
    }

    $Command = Get-Command $Configured -CommandType Application, ExternalScript -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($Command) {
        return [string]$Command.Source
    }
    return $null
}

function Invoke-OpenCodeCli {
    param (
        [string]$CommandPath,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [int]$TimeoutSeconds = 120
    )

    if ([string]::IsNullOrWhiteSpace($WorkingDirectory) -or -not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
        $WorkingDirectory = $ProjectsBasePath
    }

    $StartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $StartInfo.FileName = $CommandPath
    $StartInfo.WorkingDirectory = $WorkingDirectory
    $StartInfo.UseShellExecute = $false
    $StartInfo.CreateNoWindow = $true
    $StartInfo.RedirectStandardOutput = $true
    $StartInfo.RedirectStandardError = $true
    $StartInfo.Environment['NO_COLOR'] = '1'
    foreach ($Argument in @($Arguments)) {
        [void]$StartInfo.ArgumentList.Add([string]$Argument)
    }

    $Process = New-Object System.Diagnostics.Process
    $Process.StartInfo = $StartInfo
    try {
        if (-not $Process.Start()) {
            throw 'The process did not start.'
        }
        $StdOutTask = $Process.StandardOutput.ReadToEndAsync()
        $StdErrTask = $Process.StandardError.ReadToEndAsync()
        if (-not $Process.WaitForExit([Math]::Max(1, $TimeoutSeconds) * 1000)) {
            try { $Process.Kill($true) } catch {}
            return [PSCustomObject]@{
                ExitCode = -1
                StdOut = $StdOutTask.GetAwaiter().GetResult()
                StdErr = "OpenCode command timed out after $TimeoutSeconds seconds."
            }
        }
        return [PSCustomObject]@{
            ExitCode = $Process.ExitCode
            StdOut = $StdOutTask.GetAwaiter().GetResult()
            StdErr = $StdErrTask.GetAwaiter().GetResult()
        }
    }
    catch {
        return [PSCustomObject]@{
            ExitCode = -1
            StdOut = ''
            StdErr = $_.Exception.Message
        }
    }
    finally {
        $Process.Dispose()
    }
}

function Get-OpenCodeSourceFingerprint {
    param ($Agent)
    $Root = Get-PlatformConfiguredPath -Object $Agent
    if ([string]::IsNullOrWhiteSpace($Root)) { return $null }
    $Parts = @([System.IO.Path]::GetFullPath($Root))
    foreach ($Name in @('opencode.db', 'opencode.db-wal')) {
        $Path = Join-Path $Root $Name
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            try {
                $File = Get-Item -LiteralPath $Path -ErrorAction Stop
                $Parts += "$Name|$($File.Length)|$($File.LastWriteTimeUtc.Ticks)"
            }
            catch { return $null }
        }
        else { $Parts += "$Name|absent" }
    }
    return $Parts -join ';'
}

function Get-OpenCodeSessionList {
    param (
        $Agent,
        [switch]$Force
    )

    $Fingerprint = Get-OpenCodeSourceFingerprint -Agent $Agent
    $Now = [System.DateTimeOffset]::UtcNow
    # Cache only routing metadata, never a global database copy. A forced full
    # safety scan bypasses this, and the short lifetime covers lazy mtime and a
    # concurrent writer updating the DB while the CLI query is finishing.
    if (-not $Force -and -not $Script:ForceOpenCodeDiscovery -and $Fingerprint -and
        $Script:OpenCodeDiscoveryCache -and
        $Script:OpenCodeDiscoveryCache.Fingerprint -eq $Fingerprint -and
        (Test-AgentSyncRecentTimestamp -Since $Script:OpenCodeDiscoveryCache.CreatedUtc -WindowSeconds 60 -Now $Now)) {
        $Script:OpenCodeSessionListCache = $Script:OpenCodeDiscoveryCache.Sessions
        return @($Script:OpenCodeSessionListCache)
    }

    $Script:OpenCodeDiscoveryCache = $null
    $CommandPath = Get-OpenCodeCommandPath -Agent $Agent
    if (-not $CommandPath) {
        $Script:OpenCodeSessionListCache = @()
        return @()
    }

    $TimeoutSeconds = if ($Agent.commandTimeoutSeconds) { [int]$Agent.commandTimeoutSeconds } else { 120 }
    # `session list` is scoped to the current project. AgentSync must discover
    # projects from the agent, so use OpenCode's own read-only database command
    # to obtain only routing metadata across every local session.
    $Query = 'SELECT id, title, directory, time_created AS created, time_updated AS updated FROM session ORDER BY time_updated DESC'
    $Result = Invoke-OpenCodeCli -CommandPath $CommandPath -Arguments @('db', $Query, '--format', 'json', '--pure') -WorkingDirectory $ProjectsBasePath -TimeoutSeconds $TimeoutSeconds
    if ($Result.ExitCode -ne 0) {
        if (-not $Script:OpenCodeUnavailableWarned) {
            $ErrorText = ([string]$Result.StdErr).Trim()
            Write-AgentSyncLog -Level 'WARN' -Message "OPENCODE_DISCOVERY_FAILED exit=$($Result.ExitCode) error=$ErrorText" -Console
            $Script:OpenCodeUnavailableWarned = $true
        }
        $Script:OpenCodeSessionListCache = @()
        return @()
    }

    $Text = ([string]$Result.StdOut).Trim()
    if ([string]::IsNullOrWhiteSpace($Text)) {
        $Script:OpenCodeSessionListCache = @()
        return @()
    }

    try {
        $FirstBracket = $Text.IndexOf('[')
        $LastBracket = $Text.LastIndexOf(']')
        if ($FirstBracket -lt 0 -or $LastBracket -lt $FirstBracket) {
            throw 'OpenCode did not return a JSON array.'
        }
        $RawSessions = @(($Text.Substring($FirstBracket, $LastBracket - $FirstBracket + 1)) | ConvertFrom-Json)
    }
    catch {
        if (-not $Script:OpenCodeUnavailableWarned) {
            Write-AgentSyncLog -Level 'WARN' -Message "OPENCODE_DISCOVERY_INVALID_JSON $($_.Exception.Message)" -Console
            $Script:OpenCodeUnavailableWarned = $true
        }
        $Script:OpenCodeSessionListCache = @()
        return @()
    }

    $Sessions = New-Object 'System.Collections.Generic.List[object]'
    foreach ($Raw in $RawSessions) {
        $Id = [string]$Raw.id
        $Directory = [string]$Raw.directory
        if (-not (Test-SafeSessionId -Id $Id) -or [string]::IsNullOrWhiteSpace($Directory)) {
            continue
        }
        [void]$Sessions.Add([PSCustomObject]@{
            Id = $Id
            Directory = $Directory
            Updated = ConvertTo-OpenCodeUnixMilliseconds -Value $Raw.updated
            Created = ConvertTo-OpenCodeUnixMilliseconds -Value $Raw.created
            Title = [string]$Raw.title
            ProjectId = if ($Raw.projectId) { [string]$Raw.projectId } else { [string]$Raw.projectID }
        })
    }

    if ($Script:OpenCodeUnavailableWarned) {
        Write-AgentSyncLog -Level 'INFO' -Message 'OPENCODE_RECOVERED CLI session discovery works again.'
        $Script:OpenCodeUnavailableWarned = $false
    }
    $Script:OpenCodeSessionListCache = $Sessions.ToArray()
    $Script:ForceOpenCodeDiscovery = $false
    $Script:OpenCodeDiscoveryCache = [PSCustomObject]@{
        Fingerprint = Get-OpenCodeSourceFingerprint -Agent $Agent
        CreatedUtc = [System.DateTimeOffset]::UtcNow
        Sessions = $Script:OpenCodeSessionListCache
    }
    return @($Script:OpenCodeSessionListCache)
}

function Get-OpenCodeExportInfo {
    param ([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    try {
        $Export = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $Export.info -or -not (Test-SafeSessionId -Id ([string]$Export.info.id))) {
            return $null
        }
        $Model = $null
        $Provider = $null
        $Messages = @($Export.messages)
        for ($Index = $Messages.Count - 1; $Index -ge 0; $Index--) {
            $Model = Get-StatusNestedValue -Object $Messages[$Index] -Paths @('info.modelID', 'info.model.modelID', 'info.model.id')
            if ($Model) {
                $Provider = Get-StatusNestedValue -Object $Messages[$Index] -Paths @('info.providerID', 'info.model.providerID', 'info.model.providerId')
                break
            }
        }
        if (-not $Model) {
            $Model = Get-StatusNestedValue -Object $Export.info -Paths @('modelID', 'model.modelID', 'model.id')
            $Provider = Get-StatusNestedValue -Object $Export.info -Paths @('providerID', 'model.providerID', 'model.providerId')
        }
        return [PSCustomObject]@{
            Id = [string]$Export.info.id
            Directory = [string]$Export.info.directory
            Updated = ConvertTo-OpenCodeUnixMilliseconds -Value $Export.info.time.updated
            Model = [string]$Model
            Provider = [string]$Provider
        }
    }
    catch {
        return $null
    }
}

function Sync-OpenCode {
    param ($Agent)

    $CommandPath = Get-OpenCodeCommandPath -Agent $Agent
    if (-not $CommandPath) {
        if (-not $Script:OpenCodeUnavailableWarned) {
            Write-AgentSyncLog -Level 'WARN' -Message 'OPENCODE_CLI_MISSING Desktop data was found, but the OpenCode CLI companion is not installed at the configured path.' -Console
            $Script:OpenCodeUnavailableWarned = $true
        }
        return
    }

    $TimeoutSeconds = if ($Agent.commandTimeoutSeconds) { [int]$Agent.commandTimeoutSeconds } else { 120 }
    $TargetSubDir = [string]$Agent.targetSubDir
    $LocalSessions = @(Get-OpenCodeSessionList -Agent $Agent)
    $LocalIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Session in $LocalSessions) {
        [void]$LocalIds.Add([string]$Session.Id)
    }

    # Project -> local. OpenCode's official import command keeps the session ID
    # and rewrites the project/directory fields for the receiving machine. We
    # only import missing IDs; existing SQLite rows are never edited directly.
    $ImportedAny = $false
    foreach ($Project in @(Get-AgentSyncProjects)) {
        $CloudRoot = Join-Path $Project.FullName $TargetSubDir
        if (-not (Test-Path -LiteralPath $CloudRoot -PathType Container)) {
            continue
        }
        foreach ($File in @(Get-ChildItem -LiteralPath $CloudRoot -File -Filter '*.json' -ErrorAction SilentlyContinue |
            Where-Object { -not (Test-IsConflictCopyName -Name $_.Name) })) {
            $Info = Get-OpenCodeExportInfo -Path $File.FullName
            if (-not $Info) {
                Write-AgentSyncLog -Level 'WARN' -Message "OPENCODE_EXPORT_INVALID path=$($File.FullName)" -Console
                continue
            }
            if (-not (Test-CanonicalStorageProject -Cwd $Info.Directory -StorageProjectRoot $Project.FullName) -or $LocalIds.Contains($Info.Id)) {
                continue
            }

            $LocalProject = Get-PreferredLocalProjectPath -ProjectRoot $Project.FullName
            if (-not $LocalProject -or -not (Test-Path -LiteralPath $LocalProject -PathType Container)) {
                continue
            }
            $Display = "$($Project.Name)\$($File.Name)"
            if ($Script:DryRun) {
                Write-AgentSyncLog -Level 'DEBUG' -Message "DRYRUN OPENCODE_IMPORT $Display"
                continue
            }

            $Result = Invoke-OpenCodeCli -CommandPath $CommandPath -Arguments @('import', $File.FullName, '--pure') -WorkingDirectory $LocalProject -TimeoutSeconds $TimeoutSeconds
            if ($Result.ExitCode -ne 0) {
                $ErrorText = ([string]$Result.StdErr).Trim()
                Write-AgentSyncLog -Level 'WARN' -Message "OPENCODE_IMPORT_FAILED session=$($Info.Id) exit=$($Result.ExitCode) error=$ErrorText" -Console
                continue
            }
            [void]$LocalIds.Add($Info.Id)
            $ImportedAny = $true
            Write-Host "[OPENCODE PROJECT -> LOCAL] $Display" -ForegroundColor Cyan
            Record-SyncSuccess -AgentName 'opencode' -Direction 'project-to-local' -DisplayPath $Display -ProjectRoot $Project.FullName
        }
    }

    if ($ImportedAny) {
        $Script:OpenCodeSessionListCache = $null
        $LocalSessions = @(Get-OpenCodeSessionList -Agent $Agent -Force)
    }

    # Local -> project. Session metadata supplies the exact directory, while
    # the full native export is produced by OpenCode itself. The global DB,
    # WAL files, logs and auth.json never enter project state.
    foreach ($Session in $LocalSessions) {
        $ProjectRoot = Get-ProjectRootFromCwd -Cwd ([string]$Session.Directory)
        if (-not $ProjectRoot) {
            continue
        }

        $CloudRoot = Join-Path $ProjectRoot $TargetSubDir
        $CloudPath = Join-Path $CloudRoot "$($Session.Id).json"
        $CloudInfo = Get-OpenCodeExportInfo -Path $CloudPath
        if ($CloudInfo -and $CloudInfo.Updated -gt $Session.Updated) {
            $WarnKey = "$CloudPath|$($CloudInfo.Updated)|$($Session.Updated)"
            if (-not $Script:OpenCodeRemoteNewerWarned.ContainsKey($WarnKey)) {
                $Script:OpenCodeRemoteNewerWarned[$WarnKey] = $true
                Write-AgentSyncLog -Level 'WARN' -Message "OPENCODE_REMOTE_NEWER session=$($Session.Id) project=$(Split-Path $ProjectRoot -Leaf); automatic merge skipped." -Console
            }
            continue
        }
        if ($CloudInfo -and $CloudInfo.Updated -eq $Session.Updated) {
            continue
        }

        $Display = "$(Split-Path $ProjectRoot -Leaf)\$($Session.Id).json"
        $Result = Invoke-OpenCodeCli -CommandPath $CommandPath -Arguments @('export', [string]$Session.Id, '--pure') -WorkingDirectory ([string]$Session.Directory) -TimeoutSeconds $TimeoutSeconds
        if ($Result.ExitCode -ne 0) {
            $ErrorText = ([string]$Result.StdErr).Trim()
            Write-AgentSyncLog -Level 'WARN' -Message "OPENCODE_EXPORT_FAILED session=$($Session.Id) exit=$($Result.ExitCode) error=$ErrorText" -Console
            continue
        }

        $ExportText = ([string]$Result.StdOut).Trim()
        try {
            $ExportObject = $ExportText | ConvertFrom-Json
            if ([string]$ExportObject.info.id -ne [string]$Session.Id) {
                throw 'The exported session ID did not match the requested ID.'
            }
        }
        catch {
            Write-AgentSyncLog -Level 'WARN' -Message "OPENCODE_EXPORT_INVALID session=$($Session.Id) error=$($_.Exception.Message)" -Console
            continue
        }

        if ($Script:DryRun) {
            Write-AgentSyncLog -Level 'DEBUG' -Message "DRYRUN OPENCODE_EXPORT $Display"
            continue
        }
        if ((Test-Path -LiteralPath $CloudPath) -and -not $CloudInfo) {
            [void](Save-OverwrittenCopy -ProjectRoot $ProjectRoot -AgentName 'opencode' -LoserPath $CloudPath)
        }
        Write-Utf8TextAtomic -Path $CloudPath -Text $ExportText
        if ($Session.Updated -gt 0) {
            try {
                (Get-Item -LiteralPath $CloudPath).LastWriteTimeUtc = [System.DateTimeOffset]::FromUnixTimeMilliseconds($Session.Updated).UtcDateTime
            }
            catch {
            }
        }
        Write-Host "[OPENCODE LOCAL -> PROJECT] $Display" -ForegroundColor Green
        Record-SyncSuccess -AgentName 'opencode' -Direction 'local-to-project' -DisplayPath $Display -ProjectRoot $ProjectRoot
    }
}


function Test-SafeSessionId {
    param ([string]$Id)

    if ([string]::IsNullOrWhiteSpace($Id)) {
        return $false
    }

    # IDs are used in Join-Path. Without validation, a corrupt or hostile ID
    # containing ..\ could point outside the intended root in both directions.
    if ($Id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') {
        if (-not $Script:UnsafeIdWarned.ContainsKey($Id)) {
            $Script:UnsafeIdWarned[$Id] = $true
            Write-AgentSyncLog -Level "WARN" -Message "Skipping unsafe session ID: $Id" -Console
        }
        return $false
    }

    return $true
}

function Get-AntigravityConversationId {
    param ($Object)

    if ($Object.conversationId) {
        return [string]$Object.conversationId
    }

    if ($Object.conversation_id) {
        return [string]$Object.conversation_id
    }

    return $null
}

function Get-AntigravityTimestamp {
    param ($Object)

    if (-not $Object.timestamp) {
        return [long]0
    }

    try {
        return [long]$Object.timestamp
    }
    catch {
        try {
            return ([System.DateTimeOffset]::Parse([string]$Object.timestamp)).ToUnixTimeMilliseconds()
        }
        catch {
            return [long]0
        }
    }
}

function Initialize-AgentSyncAntigravityStreamScanner {
    if ('AgentSyncAntigravityStreamScanner' -as [type]) {
        return $true
    }

    try {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

public static class AgentSyncAntigravityStreamScanner
{
    public static IEnumerator<string> CreateFileUriEnumerator(Stream stream, int bufferSize)
    {
        return EnumerateFileUris(stream, bufferSize).GetEnumerator();
    }

    private static IEnumerable<string> EnumerateFileUris(Stream stream, int bufferSize)
    {
        if (stream == null) throw new ArgumentNullException(nameof(stream));
        if (!stream.CanRead) yield break;
        if (bufferSize < 1 || bufferSize > 32768)
            throw new ArgumentOutOfRangeException(nameof(bufferSize));

        // A one-byte protobuf length caps the URI at 127 bytes. A complete
        // frame is therefore at most 131 bytes; retaining 130 catches every
        // possible frame that crosses a read boundary.
        const int maximumUriBytes = 127;
        const int carryCapacity = maximumUriBytes + 3;
        byte[] buffer = new byte[bufferSize + carryCapacity];
        int carryCount = 0;

        while (true)
        {
            int previousCarryCount = carryCount;
            int readCount = stream.Read(buffer, carryCount, bufferSize);
            if (readCount <= 0) yield break;
            int totalCount = carryCount + readCount;

            for (int offset = 0; offset <= totalCount - 4; offset++)
            {
                if (buffer[offset] != 0x0A) continue;
                int declaredLength = buffer[offset + 1];
                // file:///C:/x is the shortest shape accepted by the former
                // regex. Longer paths remain bounded by the protobuf length.
                if (declaredLength < 12 || declaredLength > maximumUriBytes) continue;

                int recordEnd = offset + 2 + declaredLength + 2;
                if (recordEnd > totalCount) continue;
                if (recordEnd <= previousCarryCount) continue;

                int uriOffset = offset + 2;
                int terminatorOffset = uriOffset + declaredLength;
                if (buffer[terminatorOffset] != 0x1A || buffer[terminatorOffset + 1] != 0x00)
                    continue;
                if (buffer[uriOffset] != (byte)'f' || buffer[uriOffset + 1] != (byte)'i' ||
                    buffer[uriOffset + 2] != (byte)'l' || buffer[uriOffset + 3] != (byte)'e' ||
                    buffer[uriOffset + 4] != (byte)':' || buffer[uriOffset + 5] != (byte)'/' ||
                    buffer[uriOffset + 6] != (byte)'/' || buffer[uriOffset + 7] != (byte)'/' ||
                    !IsAsciiLetter(buffer[uriOffset + 8]) || buffer[uriOffset + 9] != (byte)':' ||
                    buffer[uriOffset + 10] != (byte)'/')
                    continue;

                bool printableAscii = true;
                for (int index = uriOffset + 11; index < terminatorOffset; index++)
                {
                    byte value = buffer[index];
                    if (value < 0x20 || value > 0x7E)
                    {
                        printableAscii = false;
                        break;
                    }
                }
                if (!printableAscii) continue;

                yield return Encoding.ASCII.GetString(buffer, uriOffset, declaredLength);
            }

            carryCount = Math.Min(carryCapacity, totalCount);
            if (carryCount > 0)
                Buffer.BlockCopy(buffer, totalCount - carryCount, buffer, 0, carryCount);
        }
    }

    private static bool IsAsciiLetter(byte value)
    {
        return (value >= (byte)'A' && value <= (byte)'Z') ||
               (value >= (byte)'a' && value <= (byte)'z');
    }
}
'@ -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Find-AntigravityWorkspaceInStream {
    param (
        [Parameter(Mandatory)]
        [System.IO.Stream]$Stream,
        [scriptblock]$WorkspacePredicate,
        [ValidateRange(1, 32768)]
        [int]$BufferSize = 32768
    )

    if (-not $Stream.CanRead -or -not (Initialize-AgentSyncAntigravityStreamScanner)) {
        return $null
    }

    $Enumerator = $null
    try {
        # Drive the iterator directly instead of sending it through the
        # PowerShell pipeline, which would first materialize every candidate.
        $Enumerator = [AgentSyncAntigravityStreamScanner]::CreateFileUriEnumerator($Stream, $BufferSize)
        while ($Enumerator.MoveNext()) {
            $UriText = [string]$Enumerator.Current
            try {
                $FileUri = [Uri]$UriText
                if (-not $FileUri.IsFile) {
                    continue
                }
                $Workspace = [Uri]::UnescapeDataString($FileUri.LocalPath)
                if ([string]::IsNullOrWhiteSpace($Workspace)) {
                    continue
                }

                # The injected predicate makes the bounded scanner testable
                # without weakening production validation of project roots.
                $Accepted = if ($null -ne $WorkspacePredicate) {
                    [bool](& $WorkspacePredicate $Workspace)
                }
                else {
                    [bool](Get-ProjectRootFromCwd -Cwd $Workspace)
                }
                if ($Accepted) {
                    return $Workspace
                }
            }
            catch {
                continue
            }
        }
    }
    finally {
        if ($null -ne $Enumerator -and $Enumerator -is [System.IDisposable]) {
            $Enumerator.Dispose()
        }
    }

    return $null
}

function Get-AntigravityDatabaseWorkspace {
    param ([string]$DatabasePath)

    # Antigravity IDE stores the workspace in the small protobuf value held by
    # trajectory_metadata_blob. Scan the SQLite file and its WAL in bounded
    # blocks while allowing the IDE to keep writing. No conversation text is
    # decoded or retained, and no whole database is copied into managed memory.
    foreach ($SourcePath in @($DatabasePath, "$DatabasePath-wal")) {
        if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
            continue
        }

        $Stream = $null
        try {
            $Stream = [System.IO.FileStream]::new(
                $SourcePath,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::ReadWrite)
            $Workspace = Find-AntigravityWorkspaceInStream -Stream $Stream
            if (-not [string]::IsNullOrWhiteSpace($Workspace)) {
                return $Workspace
            }
        }
        catch {
        }
        finally {
            if ($Stream) {
                $Stream.Dispose()
            }
        }
    }

    return $null
}

function Get-AntigravityHistoryGroups {
    param ([string]$LocalRoot)

    $Groups = @{}
    $HistoryPath = Join-Path $LocalRoot "history.jsonl"

    if (Test-Path -LiteralPath $HistoryPath) {
        $Reader = $null

        try {
            $Reader = New-SharedStreamReader -Path $HistoryPath

            while (-not $Reader.EndOfStream) {
                $Line = $Reader.ReadLine()

                if ([string]::IsNullOrWhiteSpace($Line)) {
                    continue
                }

                try {
                    $Object = $Line | ConvertFrom-Json
                }
                catch {
                    Add-AgentSyncSilentFailure -Category 'antigravity-history-parse'
                    continue
                }

                $ConversationId = Get-AntigravityConversationId -Object $Object
                $Workspace = [string]$Object.workspace

                if ([string]::IsNullOrWhiteSpace($ConversationId)) {
                    continue
                }

                if (-not $Groups.ContainsKey($ConversationId)) {
                    $Groups[$ConversationId] = [PSCustomObject]@{
                        ConversationId = $ConversationId
                        Workspace = $Workspace
                        LatestTimestamp = [long]0
                        Lines = New-Object 'System.Collections.Generic.List[string]'
                    }
                }

                $Group = $Groups[$ConversationId]
                [void]$Group.Lines.Add($Line)

                $Timestamp = Get-AntigravityTimestamp -Object $Object
                if (-not [string]::IsNullOrWhiteSpace($Workspace) -and $Timestamp -ge $Group.LatestTimestamp) {
                    $Group.Workspace = $Workspace
                    $Group.LatestTimestamp = $Timestamp
                }
            }
        }
        catch {
            Write-Warning "Could not read Antigravity history.jsonl: $($_.Exception.Message)"
        }
        finally {
            if ($Reader) {
                $Reader.Dispose()
            }
        }
    }

    # Fallback for the latest conversation per workspace. This helps when the
    # history file is missing some conversations but Antigravity still holds an
    # active pointer to them.
    $LastPath = Join-Path (Join-Path $LocalRoot "cache") "last_conversations.json"
    if (Test-Path -LiteralPath $LastPath) {
        try {
            $LastObject = Get-Content -LiteralPath $LastPath -Raw | ConvertFrom-Json

            foreach ($Property in $LastObject.PSObject.Properties) {
                $Workspace = [string]$Property.Name
                $ConversationId = [string]$Property.Value

                if ([string]::IsNullOrWhiteSpace($ConversationId)) {
                    continue
                }

                if (-not $Groups.ContainsKey($ConversationId)) {
                    $Groups[$ConversationId] = [PSCustomObject]@{
                        ConversationId = $ConversationId
                        Workspace = $Workspace
                        LatestTimestamp = [long]0
                        Lines = New-Object 'System.Collections.Generic.List[string]'
                    }
                }
                elseif ([string]::IsNullOrWhiteSpace([string]$Groups[$ConversationId].Workspace)) {
                    $Groups[$ConversationId].Workspace = $Workspace
                }
            }
        }
        catch {
            Write-Warning "Could not read Antigravity last_conversations.json: $($_.Exception.Message)"
        }
    }

    # Antigravity IDE keeps some conversations only as SQLite databases and
    # does not necessarily write history.jsonl or last_conversations.json.
    # trajectory_metadata_blob still contains the authoritative workspace.
    $ConversationsPath = Join-Path $LocalRoot 'conversations'
    if (Test-Path -LiteralPath $ConversationsPath) {
        foreach ($Database in @(Get-ChildItem -LiteralPath $ConversationsPath -File -Filter '*.db' -ErrorAction SilentlyContinue)) {
            $ConversationId = [System.IO.Path]::GetFileNameWithoutExtension($Database.Name)
            if (-not (Test-SafeSessionId -Id $ConversationId)) {
                continue
            }

            $Workspace = Get-AntigravityDatabaseWorkspace -DatabasePath $Database.FullName
            if ([string]::IsNullOrWhiteSpace($Workspace)) {
                continue
            }

            if (-not $Groups.ContainsKey($ConversationId)) {
                $Groups[$ConversationId] = [PSCustomObject]@{
                    ConversationId = $ConversationId
                    Workspace = $Workspace
                    LatestTimestamp = ([System.DateTimeOffset]$Database.LastWriteTimeUtc).ToUnixTimeMilliseconds()
                    Lines = New-Object 'System.Collections.Generic.List[string]'
                }
            }
            else {
                $Groups[$ConversationId].Workspace = $Workspace
            }
        }
    }

    return @($Groups.Values)
}

function Write-Utf8TextIfChanged {
    param (
        [string]$Text,
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path) {
        try {
            if ([System.IO.File]::ReadAllText($Path) -eq $Text) {
                return
            }
        }
        catch {
        }
    }

    Write-Utf8TextAtomic -Path $Path -Text $Text
}

function Write-Utf8LinesIfChanged {
    param (
        [System.Collections.IEnumerable]$Lines,
        [string]$Path
    )

    $LineArray = @($Lines)
    $Text = ""

    if ($LineArray.Count -gt 0) {
        # Always LF for jsonl. With Environment.NewLine, Windows and Unix
        # machines kept rewriting each other's files in an endless loop.
        $Text = ($LineArray -join "`n") + "`n"
    }

    if (Test-Path -LiteralPath $Path) {
        try {
            $Existing = [System.IO.File]::ReadAllText($Path)
            if ($Existing -eq $Text) {
                return
            }
        }
        catch {
        }
    }

    Write-Utf8TextAtomic -Path $Path -Text $Text
}


function Merge-AntigravityHistoryToProject {
    param (
        [System.Collections.IEnumerable]$Lines,
        [string]$Path
    )

    $Records = @{}
    $Order = 0

    $AllSources = New-Object 'System.Collections.Generic.List[string]'

    if (Test-Path -LiteralPath $Path) {
        try {
            foreach ($Line in [System.IO.File]::ReadAllLines($Path)) {
                [void]$AllSources.Add($Line)
            }
        }
        catch {
        }
    }

    foreach ($Line in @($Lines)) {
        [void]$AllSources.Add([string]$Line)
    }

    foreach ($Line in $AllSources) {
        if ([string]::IsNullOrWhiteSpace($Line)) {
            continue
        }

        $Order++
        $Key = "raw|$Line"
        $Timestamp = [long]0

        try {
            $Object = $Line | ConvertFrom-Json
            $HistoryKey = Get-AntigravityHistoryKey -Object $Object
            if ($HistoryKey) {
                $Key = $HistoryKey
                $Timestamp = Get-AntigravityTimestamp -Object $Object
            }
        }
        catch {
        }

        if (-not $Records.ContainsKey($Key)) {
            $Records[$Key] = [PSCustomObject]@{
                Line = $Line
                Timestamp = $Timestamp
                Order = $Order
            }
        }
    }

    $MergedLines = @(
        $Records.Values |
            Sort-Object Timestamp, Order |
            ForEach-Object { $_.Line }
    )

    Write-Utf8LinesIfChanged -Lines $MergedLines -Path $Path
}

function Sync-TreePair {
    param (
        [string]$LocalRoot,
        [string]$CloudRoot,
        [string]$AgentName,
        [string]$DisplayPrefix,
        [string]$ProjectRoot
    )

    $RelativePaths = @{}

    if (Test-Path -LiteralPath $LocalRoot) {
        $Files = Get-ChildItem -LiteralPath $LocalRoot -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { -not (Test-IsConflictCopyName -Name $_.Name) }
        foreach ($File in $Files) {
            $Relative = Get-RelativeChildPath -BasePath $LocalRoot -FullPath $File.FullName
            if ($null -ne $Relative) {
                $RelativePaths[$Relative.ToLowerInvariant()] = $Relative
            }
        }
    }

    if (Test-Path -LiteralPath $CloudRoot) {
        $Files = Get-ChildItem -LiteralPath $CloudRoot -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { -not (Test-IsConflictCopyName -Name $_.Name) }
        foreach ($File in $Files) {
            $Relative = Get-RelativeChildPath -BasePath $CloudRoot -FullPath $File.FullName
            if ($null -ne $Relative -and -not $RelativePaths.ContainsKey($Relative.ToLowerInvariant())) {
                $RelativePaths[$Relative.ToLowerInvariant()] = $Relative
            }
        }
    }

    foreach ($Relative in $RelativePaths.Values) {
        $LocalPath = Join-Path $LocalRoot $Relative
        $CloudPath = Join-Path $CloudRoot $Relative
        $Display = "$DisplayPrefix\$Relative"
        Sync-FilePair -LocalPath $LocalPath -CloudPath $CloudPath -AgentName $AgentName -DisplayPath $Display -ProjectRoot $ProjectRoot
    }
}

function Sync-AntigravityNamedFiles {
    param (
        [string]$LocalDir,
        [string]$CloudDir,
        [string]$ConversationId,
        [string]$AgentName,
        [string]$DisplayPrefix,
        [string]$ProjectRoot
    )

    $Names = @{}

    if (Test-Path -LiteralPath $LocalDir) {
        $Files = Get-ChildItem -LiteralPath $LocalDir -File -ErrorAction SilentlyContinue
        foreach ($File in $Files) {
            if ($File.Name.EndsWith(".db-shm", [System.StringComparison]::OrdinalIgnoreCase) -or
                $File.Name.EndsWith(".db-wal", [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }

            if (Test-IsConflictCopyName -Name $File.Name) {
                continue
            }

            # A SQLite database with a fresh WAL may be mid-checkpoint. Defer
            # the sync until writing has settled, so the copy is consistent.
            if ($File.Name.EndsWith(".db", [System.StringComparison]::OrdinalIgnoreCase)) {
                $WalPath = "$($File.FullName)-wal"
                if (Test-Path -LiteralPath $WalPath) {
                    $WalAge = ([System.DateTime]::UtcNow - (Get-Item -LiteralPath $WalPath).LastWriteTimeUtc).TotalSeconds
                    if ($WalAge -lt 30) {
                        $WalLogKey = $File.FullName.ToLowerInvariant()
                        $WalLogNow = [System.DateTime]::UtcNow
                        $WalLastLogged = $Script:WalDeferralLoggedUtc[$WalLogKey]
                        if ($null -eq $WalLastLogged -or ($WalLogNow - [System.DateTime]$WalLastLogged).TotalSeconds -ge 30) {
                            Write-AgentSyncLog -Level "DEBUG" -Message "WAL_ACTIVE deferring sync of $($File.FullName)"
                            $Script:WalDeferralLoggedUtc[$WalLogKey] = $WalLogNow
                        }
                        continue
                    }
                }
            }

            if ($File.Name.StartsWith($ConversationId, [System.StringComparison]::OrdinalIgnoreCase)) {
                $Names[$File.Name.ToLowerInvariant()] = $File.Name
            }
        }
    }

    if (Test-Path -LiteralPath $CloudDir) {
        $Files = Get-ChildItem -LiteralPath $CloudDir -File -ErrorAction SilentlyContinue
        foreach ($File in $Files) {
            if ($File.Name.EndsWith(".db-shm", [System.StringComparison]::OrdinalIgnoreCase) -or
                $File.Name.EndsWith(".db-wal", [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }

            if (Test-IsConflictCopyName -Name $File.Name) {
                continue
            }

            if ($File.Name.StartsWith($ConversationId, [System.StringComparison]::OrdinalIgnoreCase) -and -not $Names.ContainsKey($File.Name.ToLowerInvariant())) {
                $Names[$File.Name.ToLowerInvariant()] = $File.Name
            }
        }
    }

    foreach ($Name in $Names.Values) {
        $LocalPath = Join-Path $LocalDir $Name
        $CloudPath = Join-Path $CloudDir $Name
        $Display = "$DisplayPrefix\$Name"
        Sync-FilePair -LocalPath $LocalPath -CloudPath $CloudPath -AgentName $AgentName -DisplayPath $Display -ProjectRoot $ProjectRoot
    }
}

function Sync-AntigravitySessionArtifacts {
    param (
        [string]$LocalRoot,
        [string]$SessionCloudRoot,
        [string]$ConversationId,
        [string]$AgentName,
        [string]$DisplayPrefix,
        [string]$ProjectRoot
    )

    $LocalConversations = Join-Path $LocalRoot "conversations"
    $CloudConversations = Join-Path $SessionCloudRoot "conversations"
    Sync-AntigravityNamedFiles -LocalDir $LocalConversations -CloudDir $CloudConversations -ConversationId $ConversationId -AgentName $AgentName -DisplayPrefix "$DisplayPrefix\conversations" -ProjectRoot $ProjectRoot

    $LocalBrain = Join-Path (Join-Path $LocalRoot "brain") $ConversationId
    $CloudBrain = Join-Path $SessionCloudRoot "brain"
    Sync-TreePair -LocalRoot $LocalBrain -CloudRoot $CloudBrain -AgentName $AgentName -DisplayPrefix "$DisplayPrefix\brain" -ProjectRoot $ProjectRoot

    # Older and some newer Antigravity versions may keep extra per-conversation
    # data under implicit. We include both a directory named after the
    # conversationId and files starting with the conversationId when present.
    $LocalImplicitRoot = Join-Path $LocalRoot "implicit"
    $CloudImplicitRoot = Join-Path $SessionCloudRoot "implicit"

    $LocalImplicitSession = Join-Path $LocalImplicitRoot $ConversationId
    $CloudImplicitSession = Join-Path $CloudImplicitRoot $ConversationId
    Sync-TreePair -LocalRoot $LocalImplicitSession -CloudRoot $CloudImplicitSession -AgentName $AgentName -DisplayPrefix "$DisplayPrefix\implicit\$ConversationId" -ProjectRoot $ProjectRoot

    Sync-AntigravityNamedFiles -LocalDir $LocalImplicitRoot -CloudDir $CloudImplicitRoot -ConversationId $ConversationId -AgentName $AgentName -DisplayPrefix "$DisplayPrefix\implicit" -ProjectRoot $ProjectRoot
}

function Get-AntigravityHistoryKey {
    param ($Object)

    $ConversationId = Get-AntigravityConversationId -Object $Object
    $Timestamp = Get-AntigravityTimestamp -Object $Object
    $Type = [string]$Object.type
    $Display = [string]$Object.display

    if ([string]::IsNullOrWhiteSpace($ConversationId)) {
        return $null
    }

    return "$ConversationId|$Timestamp|$Type|$Display"
}

function Merge-AntigravityHistoryFragment {
    param (
        [string]$FragmentPath,
        [string]$LocalHistoryPath,
        [string]$LocalWorkspace
    )

    if (-not (Test-Path -LiteralPath $FragmentPath)) {
        return
    }

    $Seen = @{}

    if (Test-Path -LiteralPath $LocalHistoryPath) {
        $Reader = $null
        try {
            $Reader = New-SharedStreamReader -Path $LocalHistoryPath
            while (-not $Reader.EndOfStream) {
                $Line = $Reader.ReadLine()
                if ([string]::IsNullOrWhiteSpace($Line)) {
                    continue
                }

                try {
                    $Object = $Line | ConvertFrom-Json
                    $Key = Get-AntigravityHistoryKey -Object $Object
                    if ($Key) {
                        $Seen[$Key] = $true
                    }
                }
                catch {
                }
            }
        }
        finally {
            if ($Reader) {
                $Reader.Dispose()
            }
        }
    }

    $Pending = New-Object 'System.Collections.Generic.List[string]'
    $Reader = $null

    try {
        $Reader = New-SharedStreamReader -Path $FragmentPath
        while (-not $Reader.EndOfStream) {
            $Line = $Reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($Line)) {
                continue
            }

            try {
                $Object = $Line | ConvertFrom-Json
            }
            catch {
                continue
            }

            $Key = Get-AntigravityHistoryKey -Object $Object
            if (-not $Key -or $Seen.ContainsKey($Key)) {
                continue
            }

            if ($Object.PSObject.Properties.Name -contains "workspace") {
                $Object.workspace = $LocalWorkspace
            }
            else {
                $Object | Add-Member -NotePropertyName "workspace" -NotePropertyValue $LocalWorkspace
            }

            $NormalizedLine = $Object | ConvertTo-Json -Compress -Depth 30
            [void]$Pending.Add($NormalizedLine)
            $Seen[$Key] = $true
        }
    }
    finally {
        if ($Reader) {
            $Reader.Dispose()
        }
    }

    if ($Pending.Count -eq 0) {
        return
    }

    if ($Script:DryRun) {
        Write-AgentSyncLog -Level "INFO" -Message "DRYRUN HISTORY_MERGE $($Pending.Count) lines -> $LocalHistoryPath"
        return
    }

    $DestDir = Split-Path -Path $LocalHistoryPath -Parent
    if (-not (Test-Path -LiteralPath $DestDir)) {
        New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
    }

    $Encoding = New-Object System.Text.UTF8Encoding($false)
    $Writer = New-Object System.IO.StreamWriter($LocalHistoryPath, $true, $Encoding)
    try {
        foreach ($Line in $Pending) {
            $Writer.WriteLine($Line)
        }
    }
    finally {
        $Writer.Dispose()
    }
}

function Update-AntigravityLastConversations {
    param ([string]$LocalRoot)

    $HistoryPath = Join-Path $LocalRoot "history.jsonl"
    if (-not (Test-Path -LiteralPath $HistoryPath)) {
        return
    }

    $Latest = @{}
    $Reader = $null

    try {
        $Reader = New-SharedStreamReader -Path $HistoryPath
        while (-not $Reader.EndOfStream) {
            $Line = $Reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($Line)) {
                continue
            }

            try {
                $Object = $Line | ConvertFrom-Json
            }
            catch {
                continue
            }

            $ConversationId = Get-AntigravityConversationId -Object $Object
            $Workspace = [string]$Object.workspace
            $Timestamp = Get-AntigravityTimestamp -Object $Object

            if ([string]::IsNullOrWhiteSpace($ConversationId) -or [string]::IsNullOrWhiteSpace($Workspace)) {
                continue
            }

            $Key = $Workspace.ToLowerInvariant()
            if (-not $Latest.ContainsKey($Key) -or $Timestamp -ge $Latest[$Key].Timestamp) {
                $Latest[$Key] = [PSCustomObject]@{
                    Workspace = $Workspace
                    ConversationId = $ConversationId
                    Timestamp = $Timestamp
                }
            }
        }
    }
    finally {
        if ($Reader) {
            $Reader.Dispose()
        }
    }

    if ($Latest.Count -eq 0) {
        return
    }

    $CachePath = Join-Path (Join-Path $LocalRoot "cache") "last_conversations.json"
    $Map = @{}

    if (Test-Path -LiteralPath $CachePath) {
        try {
            $Existing = Get-Content -LiteralPath $CachePath -Raw | ConvertFrom-Json
            foreach ($Property in $Existing.PSObject.Properties) {
                $PropertyName = [string]$Property.Name
                $Map[$PropertyName] = [string]$Property.Value
            }
        }
        catch {
        }
    }

    foreach ($Item in $Latest.Values) {
        $Map[$Item.Workspace] = $Item.ConversationId
    }

    $Json = $Map | ConvertTo-Json -Depth 10
    Write-Utf8TextAtomic -Path $CachePath -Text $Json
}

function Sync-Antigravity {
    param ($Agent)

    $TargetSubDir = [string]$Agent.targetSubDir
    $AgentName = [string]$Agent.name

    foreach ($RootConfig in @($Agent.roots)) {
        $Surface = [string]$RootConfig.surface
        $LocalRoot = Get-PlatformConfiguredPath -Object $RootConfig

        # Local -> project. history.jsonl is the stable link between
        # conversationId and workspace. The conversation data itself stays native.
        if (Test-Path -LiteralPath $LocalRoot) {
            $Groups = Get-AntigravityHistoryGroups -LocalRoot $LocalRoot

            foreach ($Group in $Groups) {
                if ([string]::IsNullOrWhiteSpace([string]$Group.Workspace)) {
                    continue
                }

                if (-not (Test-SafeSessionId -Id ([string]$Group.ConversationId))) {
                    continue
                }

                $ProjectRoot = Get-ProjectRootFromCwd -Cwd ([string]$Group.Workspace)
                if (-not $ProjectRoot) {
                    continue
                }

                $ProjectName = Split-Path $ProjectRoot -Leaf
                $SessionCloudRoot = Join-Path (Join-Path (Join-Path (Join-Path $ProjectRoot $TargetSubDir) $Surface) "sessions") ([string]$Group.ConversationId)
                $DisplayPrefix = "$ProjectName\$Surface\$($Group.ConversationId)"

                # Some Antigravity conversations are known only through
                # last_conversations.json and therefore have no history lines.
                # Persist the agent's workspace mapping in a derived index so
                # the exact parent/subfolder project remains discoverable on
                # every machine without modifying Antigravity's native files.
                $WorkspaceIndexPath = Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $ProjectRoot '.agent-state') 'index') 'antigravity-workspaces') $Surface) "$($Group.ConversationId).json"
                $WorkspaceIndex = [ordered]@{
                    format = 1
                    agent = 'antigravity'
                    surface = $Surface
                    conversationId = [string]$Group.ConversationId
                    workspace = [string]$Group.Workspace
                } | ConvertTo-Json -Depth 5
                if ($Script:DryRun) {
                    Write-AgentSyncLog -Level 'DEBUG' -Message "DRYRUN ANTIGRAVITY_WORKSPACE_INDEX $WorkspaceIndexPath"
                }
                else {
                    Write-Utf8TextIfChanged -Path $WorkspaceIndexPath -Text $WorkspaceIndex
                }

                Sync-AntigravitySessionArtifacts -LocalRoot $LocalRoot -SessionCloudRoot $SessionCloudRoot -ConversationId ([string]$Group.ConversationId) -AgentName $AgentName -DisplayPrefix $DisplayPrefix -ProjectRoot $ProjectRoot

                if ($Group.Lines.Count -gt 0) {
                    $HistoryFragment = Join-Path $SessionCloudRoot "history.jsonl"
                    Merge-AntigravityHistoryToProject -Lines $Group.Lines -Path $HistoryFragment
                }
            }
        }

        # Project -> local. We rebuild the local history.jsonl with this
        # machine's workspace and let Antigravity keep its native session format.
        $Projects = Get-AgentSyncProjects
        foreach ($Project in $Projects) {
            $CloudSessionsRoot = Join-Path (Join-Path (Join-Path $Project.FullName $TargetSubDir) $Surface) "sessions"
            if (-not (Test-Path -LiteralPath $CloudSessionsRoot)) {
                continue
            }

            $LocalWorkspace = Get-PreferredLocalProjectPath -ProjectRoot $Project.FullName
            $Sessions = Get-ChildItem -LiteralPath $CloudSessionsRoot -Directory -ErrorAction SilentlyContinue

            foreach ($Session in $Sessions) {
                $ConversationId = [string]$Session.Name

                if (-not (Test-SafeSessionId -Id $ConversationId)) {
                    continue
                }

                $WorkspaceIndexPath = Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $Project.FullName '.agent-state') 'index') 'antigravity-workspaces') $Surface) "$ConversationId.json"
                $StoredWorkspace = Get-StatusAntigravityWorkspace -SessionRoot $Session.FullName -WorkspaceIndexPath $WorkspaceIndexPath
                if (-not (Test-CanonicalStorageProject -Cwd $StoredWorkspace -StorageProjectRoot $Project.FullName)) {
                    continue
                }

                $DisplayPrefix = "$($Project.Name)\$Surface\$ConversationId"

                Sync-AntigravitySessionArtifacts -LocalRoot $LocalRoot -SessionCloudRoot $Session.FullName -ConversationId $ConversationId -AgentName $AgentName -DisplayPrefix $DisplayPrefix -ProjectRoot $Project.FullName

                $HistoryFragment = Join-Path $Session.FullName "history.jsonl"
                $LocalHistoryPath = Join-Path $LocalRoot "history.jsonl"
                Merge-AntigravityHistoryFragment -FragmentPath $HistoryFragment -LocalHistoryPath $LocalHistoryPath -LocalWorkspace $LocalWorkspace
            }
        }

        if (Test-Path -LiteralPath $LocalRoot) {
            Update-AntigravityLastConversations -LocalRoot $LocalRoot
        }
    }
}

function Invoke-AgentSyncWindowsWorkingSetTrim {
    param ([System.IntPtr]$ProcessHandle)

    $NativeType = 'AgentSyncWorkingSetNativeMethods' -as [type]
    if ($null -eq $NativeType) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class AgentSyncWorkingSetNativeMethods
{
    [DllImport("psapi.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool EmptyWorkingSet(IntPtr processHandle);
}
'@ -ErrorAction Stop
        $NativeType = 'AgentSyncWorkingSetNativeMethods' -as [type]
    }

    if (-not $NativeType::EmptyWorkingSet($ProcessHandle)) {
        $ErrorCode = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw [System.ComponentModel.Win32Exception]::new($ErrorCode)
    }
    return $true
}

function Invoke-AgentSyncMemoryMaintenance {
    param (
        [bool]$FullCycle = $false,
        [long]$WorkingSetThresholdBytes = 512MB,
        [string]$CurrentPlatform = $PlatformName,
        [scriptblock]$WorkingSetTrimAction
    )

    # Collection releases unreachable managed objects. EmptyWorkingSet is a
    # separate, Windows-only request that lets the OS reclaim their resident
    # pages; it does not hide or repair a growing managed/private heap.
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    [System.GC]::Collect()

    $CurrentProcess = [System.Diagnostics.Process]::GetCurrentProcess()
    $CurrentProcess.Refresh()
    $WorkingSetBeforeBytes = [long]$CurrentProcess.WorkingSet64
    $TrimAttempted = $false
    $TrimSucceeded = $false
    $TrimError = $null
    $MinimumWorkingSetBytes = [Math]::Max([long]1, [long]$WorkingSetThresholdBytes)
    $ShouldTrim = $CurrentPlatform -eq 'windows' -and
        ($FullCycle -or $WorkingSetBeforeBytes -ge $MinimumWorkingSetBytes)

    if ($ShouldTrim) {
        $TrimAttempted = $true
        try {
            if ($null -ne $WorkingSetTrimAction) {
                $TrimSucceeded = [bool](& $WorkingSetTrimAction $CurrentProcess.Handle)
            }
            else {
                $TrimSucceeded = [bool](Invoke-AgentSyncWindowsWorkingSetTrim -ProcessHandle $CurrentProcess.Handle)
            }
        }
        catch {
            $TrimError = $_.Exception.Message
        }
        $CurrentProcess.Refresh()
    }

    $WorkingSetAfterBytes = [long]$CurrentProcess.WorkingSet64
    $PrivateBytes = [long]$CurrentProcess.PrivateMemorySize64
    $ManagedBytes = [long][System.GC]::GetTotalMemory($false)
    $TrimState = if ($TrimSucceeded) {
        'succeeded'
    }
    elseif ($TrimAttempted) {
        'failed'
    }
    elseif ($CurrentPlatform -ne 'windows') {
        'unsupported'
    }
    else {
        'not-needed'
    }

    return [PSCustomObject]@{
        WorkingSetBeforeMB = [math]::Round($WorkingSetBeforeBytes / 1MB, 1)
        WorkingSetMB = [math]::Round($WorkingSetAfterBytes / 1MB, 1)
        PrivateMB = [math]::Round($PrivateBytes / 1MB, 1)
        ManagedMB = [math]::Round($ManagedBytes / 1MB, 1)
        TrimAttempted = $TrimAttempted
        TrimSucceeded = $TrimSucceeded
        TrimState = $TrimState
        TrimError = $TrimError
    }
}

function Invoke-AgentSyncCycle {
    param (
        # Empty/null = full cycle (startup, safety scan, unattributable events).
        # Non-empty = incremental: run only these agents' adapters, update only
        # the implicated project manifests, and defer housekeeping and reports
        # to the periodic full cycle.
        [string[]]$AgentScope = @(),
        [string[]]$ProjectScope = @(),
        [string]$Trigger = "startup"
    )

    # Project-local providers such as Aider need a manifest/status refresh, not
    # an adapter pass. A nonempty project scope is still incremental work.
    $Incremental = (@($AgentScope).Count -gt 0 -or @($ProjectScope).Count -gt 0)
    $CycleStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    # Reuse the cycle clock; measurements do not add scans or change cadence.
    # Adapter-internal discovery remains part of that adapter's duration.
    # Null means a full-cycle-only phase was not run, not a zero-cost scan.
    $PhaseDurationsMs = [ordered]@{
        preflightStatus = 0L
        discoveryIndex = 0L
        agents = [ordered]@{}
        manifests = 0L
        status = 0L
        intelligence = $null
        maintenance = $null
        memoryMaintenance = 0L
    }
    $Script:HeartbeatSeen = @{}
    $Script:TouchedProjects = @{}
    $Script:CycleErrorCount = 0
    $Script:CycleDeferredCopies = 0
    $Script:CycleContentConflicts = 0
    $Script:CycleNewContentConflicts = 0
    $Script:SilentFailures = @{}
    $Script:OpenCodeSessionListCache = $null
    $Script:ForceOpenCodeDiscovery = -not $Incremental

    # The desktop control center must not wait for a potentially long initial
    # provider sync before it gets its first machine-readable snapshot.
    $PhaseStartedMs = $CycleStopwatch.ElapsedMilliseconds
    $ConfiguredStatusFile = Get-AgentSyncStatusJsonPath
    if (-not (Test-Path -LiteralPath $ConfiguredStatusFile -PathType Leaf)) {
        [void](Initialize-AgentSyncStatusJsonFromRecovery -JsonReportFile $ConfiguredStatusFile)
    }
    elseif (Test-AgentSyncStatusReportStale -JsonReportFile $ConfiguredStatusFile) {
        try {
            Update-AgentSyncStatusReport
        }
        catch {
            Write-AgentSyncError -Context "Preflight status report" -ErrorRecord $_ -Console
        }
    }
    $PhaseDurationsMs.preflightStatus = $CycleStopwatch.ElapsedMilliseconds - $PhaseStartedMs

    if (-not $Incremental) {
        $PhaseStartedMs = $CycleStopwatch.ElapsedMilliseconds
        try {
            Install-ProjectGuidance
        }
        catch {
            Write-AgentSyncError -Context "Project guidance install" -ErrorRecord $_ -Console
        }
        finally { $PhaseDurationsMs.discoveryIndex += $CycleStopwatch.ElapsedMilliseconds - $PhaseStartedMs }

        $PhaseStartedMs = $CycleStopwatch.ElapsedMilliseconds
        try {
            Quarantine-ConflictCopies
        }
        catch {
            Write-AgentSyncError -Context "Conflict quarantine" -ErrorRecord $_ -Console
        }
        finally { $PhaseDurationsMs.maintenance = $CycleStopwatch.ElapsedMilliseconds - $PhaseStartedMs }
    }

    $AgentPhaseIndex = 0
    foreach ($Agent in $Config.agents) {
        if ($Agent.enabled -eq $false) {
            continue
        }

        if ($Incremental -and ($AgentScope -notcontains [string]$Agent.name)) {
            continue
        }

        $AgentPhaseIndex++
        # Only known provider labels enter diagnostics, never arbitrary config
        # text or paths. Unexpected adapters get a harmless ordinal identifier.
        $AgentPhaseKey = if ([string]$Agent.name -in @('claude', 'codex', 'codex-archived', 'antigravity', 'opencode', 'cline', 'junie')) { [string]$Agent.name } else { "adapter$AgentPhaseIndex" }
        if (-not $PhaseDurationsMs.agents.Contains($AgentPhaseKey)) { $PhaseDurationsMs.agents[$AgentPhaseKey] = 0L }
        $PhaseStartedMs = $CycleStopwatch.ElapsedMilliseconds
        try {
            switch ([string]$Agent.routingMode) {
                "claude" {
                    Sync-Claude -Agent $Agent
                }
                "codex" {
                    Sync-RoutedFiles -Agent $Agent
                }
                "json-cwd" {
                    Sync-RoutedFiles -Agent $Agent
                }
                "antigravity" {
                    Sync-Antigravity -Agent $Agent
                }
                "opencode" {
                    Sync-OpenCode -Agent $Agent
                }
                "cline" {
                    Sync-Cline -Agent $Agent
                }
                "junie" {
                    Sync-Junie -Agent $Agent
                }
                default {
                    Write-AgentSyncLog -Level "WARN" -Message "Unknown routingMode for $($Agent.name): $($Agent.routingMode)" -Console
                }
            }
        }
        catch {
            Write-AgentSyncError -Context "Syncing $($Agent.name)" -ErrorRecord $_ -Console
        }
        finally { $PhaseDurationsMs.agents[$AgentPhaseKey] += $CycleStopwatch.ElapsedMilliseconds - $PhaseStartedMs }
    }

    $PhaseStartedMs = $CycleStopwatch.ElapsedMilliseconds
    try {
        Save-AgentSyncProjectIndex
    }
    catch {
        Write-AgentSyncError -Context "Project index write" -ErrorRecord $_ -Console
    }
    finally { $PhaseDurationsMs.discoveryIndex += $CycleStopwatch.ElapsedMilliseconds - $PhaseStartedMs }

    $ProjectDurations = [ordered]@{}
    $PhaseStartedMs = $CycleStopwatch.ElapsedMilliseconds
    try {
        if ($Incremental) {
            # Only the manifests the events or the actual sync work implicated.
            $ManifestTargets = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($Root in @($ProjectScope)) {
                if (-not [string]::IsNullOrWhiteSpace($Root)) { [void]$ManifestTargets.Add($Root) }
            }
            foreach ($Root in @($Script:TouchedProjects.Keys)) {
                [void]$ManifestTargets.Add($Root)
            }
            foreach ($Root in $ManifestTargets) {
                if (Test-Path -LiteralPath $Root -PathType Container) {
                    # This measures manifest work only, not adapter sync time.
                    $ProjectStartedMs = $CycleStopwatch.ElapsedMilliseconds
                    try { Update-ProjectManifest -ProjectRoot $Root }
                    catch { Write-AgentSyncError -Context 'Project manifest update' -ErrorRecord $_ -Console }
                    finally { $ProjectDurations[$Root] = $CycleStopwatch.ElapsedMilliseconds - $ProjectStartedMs }
                }
            }
        }
        else {
            Update-AllProjectManifests -ProjectDurations $ProjectDurations
        }
    }
    catch {
        Write-AgentSyncError -Context "Manifest update" -ErrorRecord $_ -Console
    }
    finally { $PhaseDurationsMs.manifests = $CycleStopwatch.ElapsedMilliseconds - $PhaseStartedMs }

    $PhaseStartedMs = $CycleStopwatch.ElapsedMilliseconds
    try {
        # Incremental cycles refresh the dashboard on its own cadence instead
        # of paying the full metrics scan on every small sync; the periodic
        # full cycle always refreshes it.
        $RunStatusReport = $true
        if ($Incremental) {
            $RunStatusReport = Test-AgentSyncStatusReportStale
        }
        if ($RunStatusReport) {
            Update-AgentSyncStatusReport
        }
    }
    catch {
        Write-AgentSyncError -Context "Status report" -ErrorRecord $_ -Console
    }
    finally { $PhaseDurationsMs.status = $CycleStopwatch.ElapsedMilliseconds - $PhaseStartedMs }

    if (-not $Incremental) {
        $PhaseStartedMs = $CycleStopwatch.ElapsedMilliseconds
        try {
            Update-AgentSyncIntelligenceReport
        }
        catch {
            Write-AgentSyncError -Context "Intelligence report" -ErrorRecord $_ -Console
        }
        finally { $PhaseDurationsMs.intelligence = $CycleStopwatch.ElapsedMilliseconds - $PhaseStartedMs }

        $PhaseStartedMs = $CycleStopwatch.ElapsedMilliseconds
        try {
            Invoke-ActivityPrune
        }
        catch {
            Write-AgentSyncError -Context "Activity pruning" -ErrorRecord $_ -Console
        }

        try {
            Invoke-OverwrittenRetention
        }
        catch {
            Write-AgentSyncError -Context "Overwritten-backup retention" -ErrorRecord $_ -Console
        }

        try {
            Invoke-ArchivePolicy
        }
        catch {
            Write-AgentSyncError -Context "Archive policy" -ErrorRecord $_ -Console
        }
        finally { $PhaseDurationsMs.maintenance += $CycleStopwatch.ElapsedMilliseconds - $PhaseStartedMs }
    }

    # Incremental scans can also leave a large resident working set. Trim only
    # after full cycles or when a smaller cycle crosses 512 MB, so ordinary
    # low-memory events keep their hot pages.
    $PhaseStartedMs = $CycleStopwatch.ElapsedMilliseconds
    $MemoryDiag = Invoke-AgentSyncMemoryMaintenance -FullCycle:(-not $Incremental)
    $PhaseDurationsMs.memoryMaintenance = $CycleStopwatch.ElapsedMilliseconds - $PhaseStartedMs
    $CycleStopwatch.Stop()
    try {
        $WorkingSetMb = $MemoryDiag.WorkingSetMB
        $ModeLabel = if ($Incremental) { "incremental agents=$((@($AgentScope) | Sort-Object) -join ',')" } else { "full" }
        $DiagSuffix = " workingSetBeforeMB=$($MemoryDiag.WorkingSetBeforeMB) privateMB=$($MemoryDiag.PrivateMB) managedMB=$($MemoryDiag.ManagedMB) trim=$($MemoryDiag.TrimState) trigger=$Trigger errors=$($Script:CycleErrorCount) deferredCopies=$($Script:CycleDeferredCopies) contentConflicts=$($Script:CycleContentConflicts) newContentConflicts=$($Script:CycleNewContentConflicts)"
        if ($Script:SilentFailures.Count -gt 0) {
            $DiagSuffix += " silentFailures=" + (($Script:SilentFailures.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Key):$($_.Value)" }) -join ',')
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$MemoryDiag.TrimError)) {
            Write-AgentSyncLog -Level 'WARN' -Message "MEMORY working-set trim failed: $($MemoryDiag.TrimError)"
        }
        Write-AgentSyncLog -Level "DEBUG" -Message "CYCLE mode=$ModeLabel durationMs=$($CycleStopwatch.ElapsedMilliseconds) workingSetMB=$WorkingSetMb$DiagSuffix"

        # These are attention thresholds, not measured latency guarantees.
        # The 2026-09-08 audit found incremental cycles commonly taking tens of
        # seconds. Use phase durations to distinguish ordinary work from a
        # changed workload, stalled provider, or watcher storm before tuning.
        $SlowCycleMs = if ($Incremental) { 60000 } else { 300000 }
        $AgentScopeText = (@($AgentScope) -join ', ')
        if ($CycleStopwatch.ElapsedMilliseconds -gt $SlowCycleMs) {
            Write-AgentSyncLog -Level "WARN" -Message "CYCLE_SLOW mode=$ModeLabel durationMs=$($CycleStopwatch.ElapsedMilliseconds) limitMs=$SlowCycleMs agents=$AgentScopeText"
        }

        # Snapshot for the status JSON so the desktop app can show cycle and
        # error health without parsing logs.
        $Script:TotalCycles++
        if ($Incremental) { $Script:TotalIncrementalCycles++ }
        $Script:LastCycleDiag = [ordered]@{
            mode = if ($Incremental) { 'incremental' } else { 'full' }
            agents = @(if ($Incremental) { @($AgentScope) | Sort-Object } else { @() })
            # Bounded manifest timings, not total per-project sync timings.
            projectTimingScope = 'manifest'
            projectsMeasured = $ProjectDurations.Count
            projectsTruncated = ($ProjectDurations.Count -gt 10)
            projects = @(
                $ProjectDurations.GetEnumerator() |
                    Sort-Object -Property Value -Descending |
                    Select-Object -First 10 |
                    ForEach-Object {
                        [ordered]@{
                            project = Split-Path -Path $_.Key -Leaf
                            path = [string]$_.Key
                            durationMs = [long]$_.Value
                            measurement = 'manifest'
                        }
                    }
            )
            trigger = $Trigger
            durationMs = $CycleStopwatch.ElapsedMilliseconds
            phaseDurationsMs = $PhaseDurationsMs
            workingSetMB = $WorkingSetMb
            workingSetBeforeMB = $MemoryDiag.WorkingSetBeforeMB
            privateMB = $MemoryDiag.PrivateMB
            managedMB = $MemoryDiag.ManagedMB
            workingSetTrim = $MemoryDiag.TrimState
            errors = $Script:CycleErrorCount
            deferredCopies = $Script:CycleDeferredCopies
            contentConflicts = $Script:CycleContentConflicts
            newContentConflicts = $Script:CycleNewContentConflicts
            silentFailures = $Script:SilentFailures.Clone()
            completedUtc = [System.DateTimeOffset]::UtcNow.ToString('o')
        }
        $PhaseMode = if ($Incremental) { 'incremental' } else { 'full' }
        Write-AgentSyncLog -Level 'DEBUG' -Message "CYCLE_PHASE mode=$PhaseMode durationsMs=$($PhaseDurationsMs | ConvertTo-Json -Compress -Depth 4)"
        [void](Update-AgentSyncStatusDiagnostics)
    }
    catch {
    }
}

function Ensure-AgentSyncActiveMemoryWorker {
    # Never run a companion during tests, dry-run, one-shot, or status-only.
    if (-not $Script:ActiveMemoryCompanionAllowed) { return }
    if ($Script:ActiveMemoryWorkerProcess -and -not $Script:ActiveMemoryWorkerProcess.HasExited) { return }
    $Now = [System.DateTimeOffset]::UtcNow
    if (Test-AgentSyncRecentTimestamp -Since $Script:ActiveMemoryWorkerLastAttempt -WindowSeconds 60 -Now $Now) { return }
    $Script:ActiveMemoryWorkerLastAttempt = $Now
    try {
        if ($Script:ActiveMemoryWorkerProcess) { $Script:ActiveMemoryWorkerProcess.Dispose() }
        . (Join-Path $PSScriptRoot 'AgentSync.ActiveMemory.ps1')
        $Script:ActiveMemoryWorkerProcess = Start-AgentSyncActiveMemoryWorker -ToolkitRoot $PSScriptRoot -ParentProcessId $PID
        if ($Script:ActiveMemoryWorkerProcess) {
            Write-AgentSyncLog -Level 'INFO' -Message "ACTIVE_MEMORY worker-launched pid=$($Script:ActiveMemoryWorkerProcess.Id) parent=$PID"
        }
    }
    catch {
        $Script:ActiveMemoryWorkerProcess = $null
        # Optional derived memory must never block copying native agent data.
        Write-AgentSyncLog -Level 'WARN' -Message "ACTIVE_MEMORY unavailable: $($_.Exception.Message)"
    }
}

function Get-AgentWatchPaths {
    $Paths = New-Object 'System.Collections.Generic.List[string]'

    # Rebuilt alongside the watch list: native agent roots map to the agent
    # whose adapter an event under them implicates. Project-state paths are
    # not registered here - they carry both project and agent in the path
    # itself and are parsed by Get-EventScope.
    $Script:WatchAgentByPath = @{}

    # Watch only known .agent-state trees, not every ordinary file below the
    # potentially broad Dropbox synchronization boundary. The small shared
    # project index discovers brand-new remote project states.
    foreach ($Project in @(Get-AgentSyncProjects)) {
        if (Test-AgentSyncOwnMissionPath -Path $Project.FullName) { continue }
        $StateRoot = Join-Path $Project.FullName '.agent-state'
        if (Test-Path -LiteralPath $StateRoot -PathType Container) {
            [void]$Paths.Add($StateRoot)
        }
    }
    $IndexDirectory = Get-AgentSyncProjectIndexDirectory
    if (Test-Path -LiteralPath $IndexDirectory -PathType Container) {
        [void]$Paths.Add($IndexDirectory)
        # Index changes announce remote project discovery; only a full cycle
        # can pick up a brand-new project safely.
        $Script:WatchAgentByPath[$IndexDirectory] = '*full*'
    }

    foreach ($Agent in $Config.agents) {
        if ($Agent.enabled -eq $false) {
            continue
        }

        if ([string]$Agent.routingMode -eq "junie") {
            foreach ($Path in @(Get-JunieWatchPaths -Agent $Agent)) {
                [void]$Paths.Add($Path)
                $Script:WatchAgentByPath[$Path] = [string]$Agent.name
            }
        }
        elseif ([string]$Agent.routingMode -in @("antigravity", "cline")) {
            foreach ($RootConfig in @($Agent.roots)) {
                $Path = Get-PlatformConfiguredPath -Object $RootConfig
                if ($Path -and (Test-Path -LiteralPath $Path)) {
                    [void]$Paths.Add($Path)
                    $Script:WatchAgentByPath[$Path] = [string]$Agent.name
                }
            }
        }
        else {
            $Path = Get-PlatformConfiguredPath -Object $Agent
            if ($Path -and (Test-Path -LiteralPath $Path)) {
                [void]$Paths.Add($Path)
                $Script:WatchAgentByPath[$Path] = [string]$Agent.name
            }
        }
    }

    return @($Paths | Sort-Object -Unique)
}

function Start-AgentSyncWatchers {
    param ([string[]]$Paths = @())
    $Registrations = New-Object 'System.Collections.Generic.List[object]'

    if (-not $PSBoundParameters.ContainsKey('Paths')) { $Paths = @(Get-AgentWatchPaths) }
    foreach ($Path in $Paths) {
        $Watcher = $null
        $Subscriptions = [System.Collections.Generic.List[object]]::new()
        try {
            # Project-state watchers (P) ignore AgentSync control-plane writes;
            # native agent-folder watchers (A) are relevant in their entirety.
            $Role = "A"
            if ((Split-Path $Path -Leaf).Equals('.agent-state', [System.StringComparison]::OrdinalIgnoreCase) -and
                (Test-PathInside -ChildPath $Path -ParentPath $ProjectsBasePath)) {
                $Role = "P"
            }

            $Watcher = New-Object System.IO.FileSystemWatcher
            $Watcher.Path = $Path
            $Watcher.IncludeSubdirectories = $true
            $Watcher.NotifyFilter = [System.IO.NotifyFilters]'FileName, DirectoryName, LastWrite, Size'
            $Watcher.InternalBufferSize = 65536
            $Watcher.EnableRaisingEvents = $false

            $Index = $Script:WatcherSequence++
            $BaseId = "AgentSyncWatcher-$PID-$Index-$Role"
            $Changed = Register-ObjectEvent -InputObject $Watcher -EventName Changed -SourceIdentifier "$BaseId-Changed"
            [void]$Subscriptions.Add($Changed)
            $Created = Register-ObjectEvent -InputObject $Watcher -EventName Created -SourceIdentifier "$BaseId-Created"
            [void]$Subscriptions.Add($Created)
            $Deleted = Register-ObjectEvent -InputObject $Watcher -EventName Deleted -SourceIdentifier "$BaseId-Deleted"
            [void]$Subscriptions.Add($Deleted)
            $Renamed = Register-ObjectEvent -InputObject $Watcher -EventName Renamed -SourceIdentifier "$BaseId-Renamed"
            [void]$Subscriptions.Add($Renamed)
            $ErrorRegistration = Register-ObjectEvent -InputObject $Watcher -EventName Error -SourceIdentifier "$BaseId-Error"
            [void]$Subscriptions.Add($ErrorRegistration)
            $Watcher.EnableRaisingEvents = $true

            [void]$Registrations.Add([PSCustomObject]@{
                Watcher = $Watcher
                Subscriptions = @($Changed, $Created, $Deleted, $Renamed, $ErrorRegistration)
                Path = $Path
            })

            Write-AgentSyncLog -Level "INFO" -Message "WATCH path=$Path"
        }
        catch {
            Stop-AgentSyncWatchers -Registrations @([PSCustomObject]@{
                Watcher = $Watcher; Subscriptions = $Subscriptions.ToArray()
            })
            Write-AgentSyncError -Context "Watcher registration for $Path" -ErrorRecord $_ -Level WARN -Console
        }
    }

    # Comma return without pipeline enumeration. In pwsh 7.6, @($Registrations)
    # throws ArgumentException when the elements carry PSEventSubscriber references.
    return ,($Registrations.ToArray())
}

function Update-AgentSyncWatchers {
    param ([System.Collections.IEnumerable]$Registrations)
    # Refresh the native-root routing map as well as the subscriptions. Keep
    # unchanged watchers alive; rebuilding all of them would drop burst events.
    $Desired = @(Get-AgentWatchPaths)
    $Wanted = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Path in $Desired) { [void]$Wanted.Add($Path) }
    $Existing = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $Kept = [System.Collections.Generic.List[object]]::new()
    $Removed = [System.Collections.Generic.List[object]]::new()
    foreach ($Registration in $Registrations) {
        if ($Wanted.Contains([string]$Registration.Path)) {
            [void]$Existing.Add([string]$Registration.Path)
            [void]$Kept.Add($Registration)
        }
        else { [void]$Removed.Add($Registration) }
    }
    $Added = @($Desired | Where-Object { -not $Existing.Contains($_) })
    if ($Added.Count -gt 0) {
        foreach ($Registration in (Start-AgentSyncWatchers -Paths $Added)) {
            [void]$Kept.Add($Registration)
        }
    }
    if ($Removed.Count -gt 0) { Stop-AgentSyncWatchers -Registrations $Removed.ToArray() }
    return ,($Kept.ToArray())
}

function Stop-AgentSyncWatchers {
    param ([System.Collections.IEnumerable]$Registrations)

    foreach ($Registration in $Registrations) {
        foreach ($Subscription in $Registration.Subscriptions) {
            try {
                Unregister-Event -SubscriptionId $Subscription.Id -ErrorAction SilentlyContinue
            }
            catch {
            }
        }
        try {
            $Registration.Watcher.EnableRaisingEvents = $false
            $Registration.Watcher.Dispose()
        }
        catch {
        }
    }
}

function Test-RelevantWatcherEvent {
    param ($WatcherEvent)

    $Identifier = [string]$WatcherEvent.SourceIdentifier

    if ($Identifier -like "*-Error") {
        return "error"
    }

    $FullPath = $null
    try {
        $FullPath = [string]$WatcherEvent.SourceEventArgs.FullPath
    }
    catch {
    }

    if ([string]::IsNullOrWhiteSpace($FullPath)) {
        return "relevant"
    }

    if (Test-AgentSyncOwnMissionPath -Path $FullPath) { return "ignore" }

    # Only provider logs are disposable notifications. Keep database and WAL
    # changes observable: they may carry the only signal of real new work.
    foreach ($Entry in $Script:WatchAgentByPath.GetEnumerator()) {
        if ($Entry.Value -eq 'opencode' -and (Test-PathInside -ChildPath $FullPath -ParentPath $Entry.Key)) {
            $Relative = Get-RelativeChildPath -BasePath $Entry.Key -FullPath $FullPath
            if ($Relative -match '^(log|logs)([\\/]|$)' -or $Relative -eq 'opencode.log') {
                return "ignore"
            }
            if ($FullPath.EndsWith('.db-wal', [System.StringComparison]::OrdinalIgnoreCase)) {
                return "relevant"
            }
        }
    }

    # Our own temporary writes and the control plane (heartbeats, manifest,
    # quarantine, archive) must not echo-trigger new sync cycles.
    if ($FullPath.EndsWith(".tmp", [System.StringComparison]::OrdinalIgnoreCase)) {
        return "ignore"
    }
    if ($FullPath.EndsWith(".db-wal", [System.StringComparison]::OrdinalIgnoreCase) -or
        $FullPath.EndsWith(".db-shm", [System.StringComparison]::OrdinalIgnoreCase) -or
        $FullPath.EndsWith(".db-journal", [System.StringComparison]::OrdinalIgnoreCase)) {
        return "ignore"
    }

    $WatcherPathKey = Get-AgentSyncWatcherPathKey -Path $FullPath
    if (-not [string]::IsNullOrWhiteSpace($WatcherPathKey) -and $Script:SelfWrittenPaths.ContainsKey($WatcherPathKey)) {
        $WrittenUtc = [System.DateTimeOffset]$Script:SelfWrittenPaths[$WatcherPathKey]
        if (Test-AgentSyncRecentTimestamp -Since $WrittenUtc -WindowSeconds 120) {
            return "ignore"
        }
        $Script:SelfWrittenPaths.Remove($WatcherPathKey)
    }
    if ($FullPath -match '[\\/]\.agent-state[\\/](activity|conflicts|archive)([\\/]|$)') {
        return "ignore"
    }
    if ($FullPath -match '[\\/]\.agent-state[\\/]manifest\.json$') {
        return "ignore"
    }

    # Project-state watchers only care about native state and index data. Our
    # own control-plane writes were filtered above to avoid echo cycles.
    if ($Identifier -like "AgentSyncWatcher-*-P-*") {
        if ($FullPath -notmatch '[\\/]\.agent-state([\\/]|$)') {
            return "ignore"
        }
    }

    return "relevant"
}

function Get-EventScope {
    param ($WatcherEvent)

    # Classifies a relevant watcher event into the smallest sync scope that is
    # guaranteed to cover it: which agent adapters must run, and which project
    # manifest is affected. Anything unattributable escalates to a full cycle,
    # so a scoping mistake costs at most one safety-scan interval of delay -
    # never a missed file.
    $Result = [PSCustomObject]@{
        Agents = @()
        ProjectRoot = $null
        Full = $false
    }

    $FullPath = $null
    try {
        $FullPath = [string]$WatcherEvent.SourceEventArgs.FullPath
    }
    catch {
    }

    if ([string]::IsNullOrWhiteSpace($FullPath)) {
        $Result.Full = $true
        return $Result
    }

    # This exact toolkit-owned store is not provider state. A user's project
    # named "missions" elsewhere must retain its own agent scope.
    if (Test-AgentSyncOwnMissionPath -Path $FullPath) {
        return $Result
    }

    # Project-state paths carry both the project and the agent in the path.
    # Greedy match resolves to the deepest .agent-state, which is the owner.
    $StateMatch = [regex]::Match($FullPath, '^(?<proj>.+)[\\/]\.agent-state(?:[\\/](?<seg>[^\\/]+))?(?:[\\/](?<sub>[^\\/]+))?', 'IgnoreCase')
    if ($StateMatch.Success) {
        $Result.ProjectRoot = $StateMatch.Groups['proj'].Value
        $Segment = $StateMatch.Groups['seg'].Value
        $SubSegment = $StateMatch.Groups['sub'].Value

        switch ($Segment.ToLowerInvariant()) {
            'claude'      { $Result.Agents = @('claude'); return $Result }
            'codex'       {
                if ($SubSegment -and $SubSegment.Equals('archived_sessions', [System.StringComparison]::OrdinalIgnoreCase)) {
                    $Result.Agents = @('codex-archived')
                }
                else {
                    $Result.Agents = @('codex')
                }
                return $Result
            }
            'antigravity' { $Result.Agents = @('antigravity'); return $Result }
            'opencode'    { $Result.Agents = @('opencode'); return $Result }
            'cline'       { $Result.Agents = @('cline'); return $Result }
            'junie'       {
                # Junie is captured one way, from the IDE into the project, so a
                # change here has nothing to copy back. Without this branch the
                # unknown segment below would escalate every change to a full
                # cycle. The project is still marked dirty, as for aider.
                $Result.Agents = @()
                return $Result
            }
            'aider'       {
                # Aider writes its history straight into the project, so there
                # is nothing to copy from a native root. The project is still
                # marked dirty, which is what refreshes manifests and status.
                $Result.Agents = @()
                return $Result
            }
            'index'       {
                if ($FullPath -match '(?i)[\\/]([a-z0-9]+)-workspaces([\\/]|$)') {
                    $IndexAgent = $Matches[1].ToLowerInvariant()
                    if (@('claude', 'codex', 'antigravity', 'opencode', 'cline', 'aider') -contains $IndexAgent) {
                        $Result.Agents = @($IndexAgent)
                        return $Result
                    }
                    if ($IndexAgent -eq 'junie') {
                        # Capture-only, as for the junie segment above.
                        $Result.Agents = @()
                        return $Result
                    }
                }
            }
        }

        # A state write we do not recognize (new agent folder, changed layout)
        # must never be silently skipped - and it is worth telling the log
        # once, because it usually means a provider changed its on-disk layout.
        if (-not [string]::IsNullOrWhiteSpace($Segment) -and -not $Script:ScopeEscalationWarned.ContainsKey("seg|$Segment")) {
            $Script:ScopeEscalationWarned["seg|$Segment"] = $true
            Write-AgentSyncLog -Level "WARN" -Message "EVENT_SCOPE_FULL unknown state segment '$Segment' escalates to full cycles: $FullPath"
        }
        $Result.Full = $true
        return $Result
    }

    # Native agent roots were registered with their owning agent. Prefer the
    # longest matching root so nested roots resolve to the closest owner.
    $BestAgent = $null
    $BestLength = -1
    foreach ($Entry in $Script:WatchAgentByPath.GetEnumerator()) {
        if ($Entry.Key.Length -gt $BestLength -and (Test-PathInside -ChildPath $FullPath -ParentPath $Entry.Key)) {
            $BestAgent = [string]$Entry.Value
            $BestLength = $Entry.Key.Length
        }
    }

    if ($BestAgent -and $BestAgent -ne '*full*') {
        $Result.Agents = @($BestAgent)
        return $Result
    }

    if ($BestAgent -ne '*full*') {
        $ParentKey = "root|" + [string](Split-Path $FullPath -Parent)
        if (-not $Script:ScopeEscalationWarned.ContainsKey($ParentKey)) {
            $Script:ScopeEscalationWarned[$ParentKey] = $true
            Write-AgentSyncLog -Level "DEBUG" -Message "EVENT_SCOPE_FULL unmatched path escalates to full cycles: $FullPath"
        }
    }
    $Result.Full = $true
    return $Result
}

function Get-AgentSyncDispatchPlan {
    param (
        [string[]]$AgentScope = @(),
        [string[]]$ProjectScope = @(),
        [bool]$DirtyFull = $false,
        [bool]$SafetyScanReady = $false,
        [bool]$IncrementalSyncEnabled = $true,
        [bool]$MaxWaitReady = $false
    )
    $RunFull = (-not $IncrementalSyncEnabled) -or $DirtyFull -or $SafetyScanReady -or
        (@($AgentScope).Count -eq 0 -and @($ProjectScope).Count -eq 0)
    $Trigger = if ($SafetyScanReady) { 'safety-scan' }
        elseif ($DirtyFull) { 'unattributable' }
        elseif (-not $IncrementalSyncEnabled) { 'incremental-disabled' }
        elseif ($MaxWaitReady) { 'max-wait' }
        else { 'debounce' }
    return [PSCustomObject]@{ RunFull = $RunFull; Trigger = $Trigger }
}

function Write-AgentSyncWatchEventDiagnostic {
    param ($WatcherEvent, [string]$Decision)
    $Path = [string]$WatcherEvent.SourceEventArgs.FullPath
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $Name = [System.IO.Path]::GetFileName($Path)
    $Category = if ($Name -match '\.db-wal$') { 'database-wal' }
        elseif ($Name -match '\.db$') { 'database' }
        elseif ($Name -match '\.log$' -or $Path -match '[\\/](log|logs)[\\/]') { 'log' }
        else { [System.IO.Path]::GetExtension($Name) }
    $Provider = 'project-state'
    foreach ($Entry in $Script:WatchAgentByPath.GetEnumerator()) {
        if (Test-PathInside -ChildPath $Path -ParentPath $Entry.Key) { $Provider = [string]$Entry.Value; break }
    }
    # A bounded, throttled diagnostic records metadata only, never file content.
    $SafeName = ($Name -replace '[\r\n\t]', ' ')
    if ($SafeName.Length -gt 120) { $SafeName = $SafeName.Substring(0, 120) }
    $Key = "$Decision|$Provider|$Category|$SafeName"
    $Now = [System.DateTimeOffset]::UtcNow
    if ($Script:WatchEventLogTimes.ContainsKey($Key) -and
        ($Now - $Script:WatchEventLogTimes[$Key]).TotalSeconds -lt 60) { return }
    if ($Script:WatchEventLogTimes.Count -ge 256) { $Script:WatchEventLogTimes.Clear() }
    $Script:WatchEventLogTimes[$Key] = $Now
    $Change = ([string]$WatcherEvent.SourceIdentifier -split '-')[-1]
    Write-AgentSyncLog -Level 'DEBUG' -Message "WATCH_EVENT decision=$Decision provider=$Provider kind=$Category change=$Change file=$SafeName"
}

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " AgentSync Toolkit v$AgentSyncVersion" -ForegroundColor Green
Write-Host " Machine: $MachineId" -ForegroundColor Yellow
Write-Host " Platform: $PlatformName" -ForegroundColor Yellow
Write-Host " Projects: $ProjectsBasePath" -ForegroundColor Yellow
Write-Host " Config: $ConfigFile" -ForegroundColor Yellow
if ($DryRun) {
    Write-Host " Mode: DRY RUN (no changes are written)" -ForegroundColor Magenta
}
elseif ($StatusOnly) {
    Write-Host " Mode: Status report only" -ForegroundColor Yellow
}
elseif ($Once) {
    Write-Host " Mode: One-shot sync" -ForegroundColor Yellow
}
else {
    Write-Host " Mode: FileSystemWatcher + safety scan" -ForegroundColor Yellow
}
Write-Host "==========================================" -ForegroundColor Cyan

if ($StatusOnly) {
    try {
        $StatusJsonFile = Get-AgentSyncStatusJsonPath
        if (-not (Initialize-AgentSyncStatusJsonFromRecovery -JsonReportFile $StatusJsonFile)) {
            Update-AgentSyncStatusReport
        }
        Write-AgentSyncLog -Level "INFO" -Message "Status-only report finished."
        exit 0
    }
    catch {
        Write-AgentSyncLog -Level "ERROR" -Message "Status-only report failed: $($_.Exception.Message)" -Console
        throw
    }
}

# Only one instance per machine. Two concurrent engines would duplicate work
# and fight over the same files.
$InstanceMutex = New-Object System.Threading.Mutex($false, "AgentSyncToolkit.Engine")
$MutexAcquired = $false
try {
    $MutexAcquired = $InstanceMutex.WaitOne(0)
}
catch [System.Threading.AbandonedMutexException] {
    $MutexAcquired = $true
}
if (-not $MutexAcquired) {
    Write-Host "Another AgentSync instance is already running on this machine. Stop it first." -ForegroundColor Red
    Write-AgentSyncLog -Level "WARN" -Message "Start refused: another instance holds the mutex."
    exit 2
}

Write-AgentSyncLog -Level "INFO" -Message "START version=$AgentSyncVersion projects=$ProjectsBasePath once=$Once dryRun=$($Script:DryRun)"
# Retain the inventory's generation time, but never attribute the previous
# process's cycle/error counters to this run while its first scan is pending.
[void](Update-AgentSyncStatusDiagnostics)

$DebounceMs = 30000
$SafetyScanSeconds = 900
$MaxDirtyWaitSeconds = 120
$IncrementalSyncEnabled = $true
if ($Config.watcher) {
    if ($Config.watcher.debounceMs) { $DebounceMs = [int]$Config.watcher.debounceMs }
    if ($Config.watcher.safetyScanSeconds) { $SafetyScanSeconds = [int]$Config.watcher.safetyScanSeconds }
    if ($Config.watcher.maxDirtyWaitSeconds) { $MaxDirtyWaitSeconds = [int]$Config.watcher.maxDirtyWaitSeconds }
    if ($null -ne $Config.watcher.incrementalSync) { $IncrementalSyncEnabled = [bool]$Config.watcher.incrementalSync }
}

$Watchers = @()
try {
    $Script:ActiveMemoryCompanionAllowed = ($PlatformName -eq 'windows' -and -not $Once -and -not $Script:DryRun)
    Ensure-AgentSyncActiveMemoryWorker
    try {
        Invoke-AgentSyncCycle
    }
    catch {
        Write-AgentSyncError -Context "First sync cycle" -ErrorRecord $_ -Console
        if ($Once) {
            throw
        }
    }

    if ($Once) {
        Write-AgentSyncLog -Level "INFO" -Message "One-shot sync finished."
    }
    else {
        $Watchers = Start-AgentSyncWatchers
        $LastFullScanMs = Get-AgentSyncMonotonicMilliseconds
        $DirtySince = $null
        $DirtyFirst = $null
        $DirtyFull = $false
        $DirtyAgents = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $DirtyProjects = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $FailureStreak = 0

        while ($true) {
            Ensure-AgentSyncActiveMemoryWorker
            $AllEvents = @()

            $FirstEvent = Wait-Event -Timeout 1
            if ($FirstEvent) {
                Remove-Event -EventIdentifier $FirstEvent.EventIdentifier -ErrorAction SilentlyContinue
                $AllEvents += $FirstEvent
            }

            # Drain the rest of the queue in one go. The old one-by-one drain
            # was O(n^2) and could stall during event floods.
            $PendingEvents = @(Get-Event -ErrorAction SilentlyContinue | Where-Object { [string]$_.SourceIdentifier -like "AgentSyncWatcher-*" })
            foreach ($PendingEvent in $PendingEvents) {
                Remove-Event -EventIdentifier $PendingEvent.EventIdentifier -ErrorAction SilentlyContinue
            }
            $AllEvents += $PendingEvents

            foreach ($QueuedEvent in $AllEvents) {
                if ([string]$QueuedEvent.SourceIdentifier -notlike "AgentSyncWatcher-*") {
                    continue
                }

                $EventDecision = Test-RelevantWatcherEvent -WatcherEvent $QueuedEvent
                Write-AgentSyncWatchEventDiagnostic -WatcherEvent $QueuedEvent -Decision $EventDecision
                switch ($EventDecision) {
                    "error" {
                        Write-AgentSyncLog -Level "WARN" -Message "FileSystemWatcher reported an error. Forcing a full safety scan." -Console
                        $DirtySince = (Get-AgentSyncMonotonicMilliseconds) - $DebounceMs
                        $DirtyFull = $true
                    }
                    "relevant" {
                        # Debounce from the most recent relevant write, so an
                        # agent's active write burst can settle before a scan
                        # starts.
                        $DirtySince = Get-AgentSyncMonotonicMilliseconds
                        if ($null -eq $DirtyFirst) {
                            $DirtyFirst = $DirtySince
                        }

                        if (-not $DirtyFull) {
                            $Scope = Get-EventScope -WatcherEvent $QueuedEvent
                            if ($Scope.Full) {
                                $DirtyFull = $true
                            }
                            else {
                                foreach ($ScopedAgent in @($Scope.Agents)) {
                                    [void]$DirtyAgents.Add($ScopedAgent)
                                }
                                if ($Scope.ProjectRoot) {
                                    [void]$DirtyProjects.Add($Scope.ProjectRoot)
                                }
                            }
                        }
                    }
                }
            }

            # Quiet-period debounce alone never fires while agents write
            # continuously - which is exactly when fast backup matters most.
            # In practice that degraded sync to the 15-minute safety scan.
            # The max-wait valve guarantees a cycle once the oldest unsynced
            # change reaches this age, quiet or not.
            $Timing = Get-AgentSyncWatcherReadiness -DirtySinceMs $DirtySince -DirtyFirstMs $DirtyFirst -LastFullScanMs $LastFullScanMs -DebounceMs $DebounceMs -MaxDirtyWaitSeconds $MaxDirtyWaitSeconds -SafetyScanSeconds $SafetyScanSeconds
            $DebounceReady = $Timing.DebounceReady
            $MaxWaitReady = $Timing.MaxWaitReady
            $SafetyScanReady = $Timing.SafetyScanReady

            if ($DebounceReady -or $MaxWaitReady -or $SafetyScanReady) {
                # Incremental cycles handle only the agents and projects the
                # events implicated. The periodic safety scan - and anything we
                # could not attribute - still runs the unscoped full cycle, so
                # a scoping mistake costs at most one scan interval of delay.
                $Plan = Get-AgentSyncDispatchPlan -AgentScope @($DirtyAgents) -ProjectScope @($DirtyProjects) -DirtyFull $DirtyFull -SafetyScanReady $SafetyScanReady -IncrementalSyncEnabled $IncrementalSyncEnabled -MaxWaitReady ([bool]$MaxWaitReady)
                $RunFull = $Plan.RunFull
                $Trigger = $Plan.Trigger
                try {
                    if ($RunFull) {
                        Invoke-AgentSyncCycle -Trigger $Trigger
                    }
                    else {
                        Invoke-AgentSyncCycle -AgentScope @($DirtyAgents) -ProjectScope @($DirtyProjects) -Trigger $Trigger
                    }
                    $Watchers = Update-AgentSyncWatchers -Registrations $Watchers
                    $FailureStreak = 0
                }
                catch {
                    # A single failure must not kill the daemon. Short backoff on
                    # repeated failures so we do not spin against the same problem.
                    $FailureStreak++
                    Write-AgentSyncError -Context "Sync cycle ($FailureStreak in a row)" -ErrorRecord $_ -Console
                    Start-Sleep -Seconds ([math]::Min(60, 5 * $FailureStreak))
                }
                if ($RunFull) {
                    # Only a genuine full cycle satisfies the safety-scan clock;
                    # incremental work must never postpone the full sweep.
                    $LastFullScanMs = Get-AgentSyncMonotonicMilliseconds
                }
                $DirtySince = $null
                $DirtyFirst = $null
                $DirtyFull = $false
                $DirtyAgents.Clear()
                $DirtyProjects.Clear()
            }
        }
    }
}
catch {
    # Fatal errors must always end up in the log with a position, not just in
    # a console window that gets closed.
    $StackFlat = [string]$_.ScriptStackTrace -replace "\r?\n", " <- "
    Write-AgentSyncLog -Level "ERROR" -Message "FATAL $($_.Exception.GetType().Name): $($_.Exception.Message) | $StackFlat" -Console
    throw
}
finally {
    Stop-AgentSyncWatchers -Registrations $Watchers
    try {
        if ($MutexAcquired) { [void]$InstanceMutex.ReleaseMutex() }
        $InstanceMutex.Dispose()
    }
    catch {
    }
    Write-AgentSyncLog -Level "INFO" -Message "STOP"
}
