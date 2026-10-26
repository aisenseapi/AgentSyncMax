#requires -Version 7.0

[CmdletBinding()]
param (
    [string]$ConfigFile,
    [string]$OutputFile,
    [string]$DataFile,
    [int]$MaxTimelineSessions = 0,
    [ValidateRange(0, 1800)][int]$WorkBudgetSeconds = 0,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$Script:ParserVersion = 5

function Get-CurrentPlatformName {
    if ($IsWindows) { return 'windows' }
    if ($IsMacOS) { return 'macos' }
    return 'linux'
}

function Get-ObjectPropertyValue {
    param ($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $Property = $Object.PSObject.Properties[$Name]
    if ($Property) { return $Property.Value }
    return $null
}

function Expand-AgentSyncPath {
    param ([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $HomePath = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    if ([string]::IsNullOrWhiteSpace($HomePath)) { $HomePath = $env:USERPROFILE }
    if ([string]::IsNullOrWhiteSpace($HomePath)) { $HomePath = $env:HOME }
    $Expanded = $Path
    if ($Expanded -eq '~') { $Expanded = $HomePath }
    elseif ($Expanded.StartsWith('~/') -or $Expanded.StartsWith('~\')) { $Expanded = Join-Path $HomePath $Expanded.Substring(2) }
    if ($HomePath) {
        $Expanded = $Expanded.Replace('${HOME}', $HomePath).Replace('$HOME', $HomePath).Replace('%USERPROFILE%', $HomePath)
    }
    $Expanded = [System.Environment]::ExpandEnvironmentVariables($Expanded)
    try { return [System.IO.Path]::GetFullPath($Expanded).TrimEnd('\', '/') }
    catch { return $Expanded }
}

function Test-PathInside {
    param ([string]$ChildPath, [string]$ParentPath)
    try {
        $Child = [System.IO.Path]::GetFullPath($ChildPath).TrimEnd('\', '/')
        $Parent = [System.IO.Path]::GetFullPath($ParentPath).TrimEnd('\', '/')
        if ($Child.Equals($Parent, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        return $Child.StartsWith($Parent + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
    }
    catch { return $false }
}

function Test-SafeSessionId {
    param ([string]$Id)
    return -not [string]::IsNullOrWhiteSpace($Id) -and $Id -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
}

function Test-IsConflictCopyName {
    param ([string]$Name)
    return -not [string]::IsNullOrWhiteSpace($Name) -and (
        $Name -match '(?i)conflicted copy' -or
        $Name -match '(?i)sync-conflict' -or
        $Name -match '(?i)conflict copy'
    )
}

function Test-AntigravityJsonlChunkFile {
    param ([System.IO.FileInfo]$File)

    if ($null -eq $File -or $File.Name -notmatch '^\d{8}\.jsonl$') {
        return $false
    }
    $NormalizedDirectory = $File.DirectoryName -replace '\\', '/'
    return $NormalizedDirectory -match '(?i)/brain/\.system_generated/logs/chunks/(?:transcript|transcript_full)$'
}

function Get-SharedReader {
    param ([string]$Path)
    $Stream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    return [System.IO.StreamReader]::new($Stream, [System.Text.Encoding]::UTF8, $true, 65536)
}

function Write-AtomicUtf8File {
    param ([string]$Path, [string]$Text)
    $Resolved = [System.IO.Path]::GetFullPath($Path)
    $Directory = Split-Path $Resolved -Parent
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    }
    $Temporary = Join-Path $Directory ('.' + [System.IO.Path]::GetFileName($Resolved) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [System.IO.File]::WriteAllText($Temporary, $Text, [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $Temporary -Destination $Resolved -Force
    }
    finally {
        if (Test-Path -LiteralPath $Temporary) { Remove-Item -LiteralPath $Temporary -Force }
    }
}

function Assert-SafeOutputPath {
    param ([string]$Path, $Config, [string]$IndexDirectory, [string]$ConfigFile)

    $Resolved = [System.IO.Path]::GetFullPath($Path)
    if (@($Resolved -split '[\\/]' | Where-Object { $_.Equals('.agent-state', [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
        throw "Intelligence output cannot be written inside .agent-state: $Resolved"
    }
    if (Test-PathInside -ChildPath $Resolved -ParentPath $IndexDirectory) {
        throw "Intelligence output cannot be written inside project-index: $Resolved"
    }
    if ($Resolved.Equals([System.IO.Path]::GetFullPath($ConfigFile), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Intelligence output cannot overwrite the active config: $Resolved"
    }
    foreach ($Agent in @($Config.agents | Where-Object { $_.enabled -ne $false })) {
        $Candidates = [System.Collections.Generic.List[object]]::new()
        $Candidates.Add($Agent)
        foreach ($Root in @($Agent.roots)) { if ($Root) { $Candidates.Add($Root) } }
        foreach ($Candidate in $Candidates) {
            foreach ($Name in @('localPath', 'localPathWindows', 'localPathMacOS', 'localPathLinux')) {
                $Setting = [string](Get-ObjectPropertyValue -Object $Candidate -Name $Name)
                if (-not $Setting) { continue }
                $RootPath = Expand-AgentSyncPath -Path $Setting
                if ($RootPath -and (Test-PathInside -ChildPath $Resolved -ParentPath $RootPath)) {
                    throw "Intelligence output cannot be written inside a local agent root: $Resolved"
                }
            }
        }
    }
    return $Resolved
}

function Get-Sha256Text {
    param ([string]$Text)
    return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($Text)))
}

# A timed-out builder used to lose every cache miss it had already parsed.
# Persist only completed metadata records, never transcript text. Resume data
# is a cache, not a report: the previous complete report keeps its original age.
function Read-IntelligenceProgress {
    param ([string]$Path, [string]$ProjectsRoot)
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
        $Progress = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($Progress.parserVersion -ne $Script:ParserVersion -or $Progress.projectsRoot -cne $ProjectsRoot) { return @() }
        return @($Progress.records | Where-Object { $_.storageKey -and $_.sourceFingerprint -and $_.parserVersion -eq $Script:ParserVersion })
    }
    catch { return @() } # A lost cache costs work; it must never cost history.
}

function Save-IntelligenceProgress {
    param ([string]$Path, [string]$ProjectsRoot, $Records, [int]$Remaining = 0, $Partial = $null)
    $Progress = [ordered]@{
        parserVersion = $Script:ParserVersion
        projectsRoot = $ProjectsRoot
        updatedUtc = [datetimeoffset]::UtcNow.ToString('o')
        pendingGroups = $Remaining
        records = @($Records)
        partial = $Partial
    }
    Write-AtomicUtf8File -Path $Path -Text ($Progress | ConvertTo-Json -Depth 20 -Compress)
}

function Read-IntelligencePartial {
    param ([string]$Path, [string]$ProjectsRoot)
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        $Progress = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($Progress.parserVersion -ne $Script:ParserVersion -or $Progress.projectsRoot -cne $ProjectsRoot) { return $null }
        $Partial = $Progress.partial
        if ($Partial.format -ne 1 -or -not $Partial.storageKey -or -not $Partial.sourceFingerprint -or
            $Partial.fileIndex -lt 0 -or $Partial.nextLine -lt 0 -or -not $Partial.state) { return $null }
        return $Partial
    }
    catch { return $null }
}

function New-IntelligencePartial {
    param ($State, [string]$ResolvedId, [int]$FileIndex, [long]$NextLine)
    # Explicit whitelist: never serialize the reader, Group, a native record,
    # message/command text, or other objects reachable from the parsing scope.
    return [pscustomobject]@{
        format = 1
        storageKey = $State.Group.storageKey
        sourceFingerprint = $State.Fingerprint
        resolvedId = $ResolvedId
        fileIndex = $FileIndex
        nextLine = $NextLine
        state = [ordered]@{
            startedUtc = if ($State.Time.Start) { $State.Time.Start.ToString('o') } else { $null }
            updatedUtc = if ($State.Time.End) { $State.Time.End.ToString('o') } else { $null }
            paths = @($State.Paths)
            metadataPaths = @($State.MetadataPaths)
            tools = $State.Tools
            userMessages = $State.UserMessages
            assistantMessages = $State.AssistantMessages
            toolCalls = $State.ToolCalls
            parseErrors = $State.ParseErrors
            records = $State.Records
            title = Protect-DisplayText -Text $State.Title
            model = Protect-DisplayText -Text $State.Model
            provider = Protect-DisplayText -Text $State.Provider
        }
    }
}

function Restore-IntelligencePartialState {
    param ($Group, [string]$Fingerprint, $Partial)
    if (-not $Partial -or $Partial.format -ne 1 -or $Partial.storageKey -cne $Group.storageKey -or
        $Partial.sourceFingerprint -cne $Fingerprint) { return $null }
    try {
        $State = Get-BaseSessionState -Group $Group -Fingerprint $Fingerprint
        $Saved = $Partial.state
        foreach ($Name in @('UserMessages', 'AssistantMessages', 'ToolCalls', 'ParseErrors', 'Records')) {
            $Value = Get-ObjectPropertyValue -Object $Saved -Name $Name
            if ($null -eq $Value -or [long]$Value -lt 0) { return $null }
            $State.$Name = [long]$Value
        }
        foreach ($Path in @($Saved.paths)) { if ($Path -is [string]) { [void]$State.Paths.Add($Path) } }
        foreach ($Path in @($Saved.metadataPaths)) { if ($Path -is [string]) { [void]$State.MetadataPaths.Add($Path) } }
        foreach ($Tool in $Saved.tools.PSObject.Properties) {
            if ([long]$Tool.Value -lt 0) { return $null }
            $State.Tools[$Tool.Name] = [long]$Tool.Value
        }
        $State.Time.Start = ConvertTo-TimeValue -Value $Saved.startedUtc
        $State.Time.End = ConvertTo-TimeValue -Value $Saved.updatedUtc
        $State.Title = [string]$Saved.title
        $State.Model = [string]$Saved.model
        $State.Provider = [string]$Saved.provider
        return $State
    }
    catch { return $null }
}

function ConvertTo-TimeValue {
    param ($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetimeoffset]) { return $Value.ToUniversalTime() }
    if ($Value -is [datetime]) { return ([datetimeoffset]$Value).ToUniversalTime() }
    if ($Value -is [ValueType] -and $Value -isnot [bool]) {
        try {
            $Number = [double]$Value
            if ($Number -gt 100000000000) { return [datetimeoffset]::FromUnixTimeMilliseconds([long]$Number) }
            if ($Number -gt 1000000000) { return [datetimeoffset]::FromUnixTimeSeconds([long]$Number) }
        }
        catch { }
    }
    try { return [datetimeoffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture).ToUniversalTime() }
    catch { return $null }
}

function Update-TimeRange {
    param ($State, $Value)
    $Time = ConvertTo-TimeValue -Value $Value
    if ($null -eq $Time) { return }
    if ($null -eq $State.Start -or $Time -lt $State.Start) { $State.Start = $Time }
    if ($null -eq $State.End -or $Time -gt $State.End) { $State.End = $Time }
}

function Protect-DisplayText {
    param ([string]$Text, [int]$MaximumLength = 140)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $Clean = [regex]::Replace($Text, '\s+', ' ').Trim()
    $Clean = [regex]::Replace($Clean, '(?i)\b(?:sk|api|token|key)[-_][A-Za-z0-9_-]{12,}\b', '[skjult]')
    $Clean = [regex]::Replace($Clean, '(?i)\b(?:password|passwd|token|secret|api[_-]?key)\s*[:=]\s*\S+', '$1=[skjult]')
    if ($Clean.Length -gt $MaximumLength) { $Clean = $Clean.Substring(0, $MaximumLength - 1).TrimEnd() + '…' }
    return $Clean
}

function Get-ProjectMappingKind {
    param ([string[]]$MetadataPaths, [string]$ProjectRelative, [string]$ProjectPath)

    $Kinds = [System.Collections.Generic.List[string]]::new()
    foreach ($Raw in @($MetadataPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $Normalized = [string]$Raw -replace '^file:///?', '' -replace '\\', '/'
        try { $Normalized = [System.Uri]::UnescapeDataString($Normalized) } catch { }
        $Normalized = [regex]::Replace($Normalized.TrimEnd('/'), '(?i)/\.claude/worktrees/[^/]+(?:/.*)?$', '')
        $Current = ($ProjectPath -replace '\\', '/').TrimEnd('/')
        $Relative = ($ProjectRelative -replace '\\', '/').Trim('/')
        if ($Normalized.Equals($Current, [System.StringComparison]::OrdinalIgnoreCase)) { $Kinds.Add('exact'); continue }
        if ($Normalized.EndsWith('/' + $Relative, [System.StringComparison]::OrdinalIgnoreCase)) { $Kinds.Add('portable'); continue }
        $Kinds.Add('fallback')
    }
    if ($Kinds.Contains('exact')) { return 'exact' }
    if ($Kinds.Contains('portable')) { return 'portable' }
    if ($Kinds.Contains('fallback')) { return 'fallback' }
    return 'unknown'
}

function Get-SafeProjectReference {
    param ([string]$Candidate, [string]$ProjectPath)

    if ([string]::IsNullOrWhiteSpace($Candidate) -or $Candidate.Length -gt 600 -or $Candidate -match "[`r`n]" -or $Candidate -match '^(?i:https?|data):') { return $null }
    $Value = $Candidate.Trim(' ', '"', "'")
    if ($Value -match '[*?<>|]') { return $null }
    if ($Value -match '^file://') {
        try { $Value = ([uri]$Value).LocalPath } catch { return $null }
    }
    try {
        $Full = if ([System.IO.Path]::IsPathRooted($Value)) { [System.IO.Path]::GetFullPath($Value) } else { [System.IO.Path]::GetFullPath((Join-Path $ProjectPath $Value)) }
        if (-not (Test-PathInside -ChildPath $Full -ParentPath $ProjectPath)) { return $null }
        $Relative = [System.IO.Path]::GetRelativePath($ProjectPath, $Full).Replace('\', '/')
        if ([string]::IsNullOrWhiteSpace($Relative) -or $Relative -eq '.' -or $Relative.Equals('.agent-state', [System.StringComparison]::OrdinalIgnoreCase) -or $Relative.StartsWith('.agent-state/', [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
        return $Relative
    }
    catch { return $null }
}

function Add-StructuredPathReferences {
    param ($Object, [System.Collections.Generic.HashSet[string]]$Paths, [string]$ProjectPath, [int]$Depth = 0)

    if ($null -eq $Object -or $Depth -gt 9 -or $Object -is [string] -or $Object -is [ValueType]) { return }
    if ($Object -is [System.Collections.IEnumerable] -and $Object -isnot [pscustomobject] -and $Object -isnot [hashtable]) {
        foreach ($Item in $Object) { Add-StructuredPathReferences -Object $Item -Paths $Paths -ProjectPath $ProjectPath -Depth ($Depth + 1) }
        return
    }
    foreach ($Property in $Object.PSObject.Properties) {
        $Name = [string]$Property.Name
        $Value = $Property.Value
        if ($Name -match '^(?i:file_path|filePath|notebook_path|notebookPath|absolutePath|AbsolutePath|target_file|targetFile|source_file|sourceFile|path)$') {
            foreach ($Candidate in @($Value)) {
                if ($Candidate -isnot [string]) { continue }
                $Reference = Get-SafeProjectReference -Candidate $Candidate -ProjectPath $ProjectPath
                if ($Reference) { [void]$Paths.Add($Reference) }
            }
        }
        elseif ($Name -match '^(?i:patch|arguments)$' -and $Value -is [string]) {
            foreach ($Match in [regex]::Matches($Value, '(?m)^\*\*\* (?:Add|Update|Delete) File: (?<path>[^\r\n]+)$')) {
                $Reference = Get-SafeProjectReference -Candidate ([string]$Match.Groups['path'].Value) -ProjectPath $ProjectPath
                if ($Reference) { [void]$Paths.Add($Reference) }
            }
            if ($Value.TrimStart().StartsWith('{')) {
                try { Add-StructuredPathReferences -Object ($Value | ConvertFrom-Json) -Paths $Paths -ProjectPath $ProjectPath -Depth ($Depth + 1) } catch { }
            }
        }
        elseif ($Value -isnot [string] -and $Value -isnot [ValueType]) {
            Add-StructuredPathReferences -Object $Value -Paths $Paths -ProjectPath $ProjectPath -Depth ($Depth + 1)
        }
    }
}

function Add-ToolCount {
    param ([hashtable]$Tools, [string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return }
    $Normalized = Protect-DisplayText -Text $Name -MaximumLength 60
    if (-not $Tools.ContainsKey($Normalized)) { $Tools[$Normalized] = 0 }
    $Tools[$Normalized]++
}

function Get-SourceFingerprint {
    param ($Group)
    $Lines = foreach ($File in @($Group.files | Sort-Object FullName)) {
        $Relative = [System.IO.Path]::GetRelativePath($Group.projectPath, $File.FullName).Replace('\', '/')
        "$Relative|$($File.Length)|$($File.LastWriteTimeUtc.Ticks)"
    }
    return Get-Sha256Text -Text ($Lines -join "`n")
}

function New-SourceGroup {
    param ([string]$StorageKey, [string]$Agent, [string]$Id, [string]$ProjectRelative, [string]$ProjectPath, [string]$Surface)
    return [PSCustomObject]@{
        storageKey = $StorageKey
        agent = $Agent
        id = $Id
        project = $ProjectRelative
        projectPath = $ProjectPath
        surface = $Surface
        metadataPath = $null
        files = [System.Collections.Generic.List[object]]::new()
    }
}

function Get-BaseSessionState {
    param ($Group, [string]$Fingerprint)

    $Time = [PSCustomObject]@{ Start = $null; End = $null }
    $Bytes = 0L
    foreach ($File in @($Group.files)) {
        $Bytes += $File.Length
        Update-TimeRange -State $Time -Value ([datetimeoffset]$File.LastWriteTimeUtc)
    }
    $State = [PSCustomObject]@{
        Group = $Group
        Fingerprint = $Fingerprint
        Time = $Time
        Paths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        MetadataPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        Tools = @{}
        UserMessages = 0
        AssistantMessages = 0
        ToolCalls = 0
        ParseErrors = 0
        Records = 0
        Title = $null
        Model = $null
        Provider = $null
        Bytes = $Bytes
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Group.metadataPath)) {
        [void]$State.MetadataPaths.Add([string]$Group.metadataPath)
    }
    return $State
}

function Complete-SessionRecord {
    param ($State, [string]$Id)

    $Group = $State.Group
    $PathArray = @($State.Paths | Sort-Object | Select-Object -First 200)
    $ToolArray = @($State.Tools.GetEnumerator() | Sort-Object @{ Expression = 'Value'; Descending = $true }, @{ Expression = 'Name'; Descending = $false } | Select-Object -First 20 | ForEach-Object {
        [PSCustomObject]@{ name = $_.Name; count = [int]$_.Value }
    })
    $Subject = Protect-DisplayText -Text ([string]$State.Title)
    if (-not $Subject -and $PathArray.Count -gt 0) {
        $Names = @($PathArray | Select-Object -First 3 | ForEach-Object { Split-Path $_ -Leaf })
        $Subject = 'Arbeid med ' + ($Names -join ', ')
    }
    if (-not $Subject) { $Subject = "$(switch ($Group.agent) { 'claude' {'Claude'} 'codex' {'Codex'} 'antigravity' {'Antigravity'} 'opencode' {'OpenCode'} 'cline' {'Cline'} 'aider' {'Aider'} })-økt" }
    $Start = if ($State.Time.Start) { $State.Time.Start.ToString('o') } else { $null }
    $End = if ($State.Time.End) { $State.Time.End.ToString('o') } else { $Start }
    return [PSCustomObject]@{
        parserVersion = $Script:ParserVersion
        storageKey = $Group.storageKey
        sourceFingerprint = $State.Fingerprint
        agent = $Group.agent
        id = $Id
        project = $Group.project
        projectPath = $Group.projectPath
        surface = $Group.surface
        subject = $Subject
        subjectSource = if ($State.Title) { 'native-title' } elseif ($PathArray.Count -gt 0) { 'structured-paths' } else { 'provider-metadata' }
        startedUtc = $Start
        updatedUtc = $End
        model = if ($State.Model) { [string]$State.Model } else { 'Ikke registrert' }
        provider = if ($State.Provider) { [string]$State.Provider } else { '' }
        mapping = Get-ProjectMappingKind -MetadataPaths @($State.MetadataPaths) -ProjectRelative $Group.project -ProjectPath $Group.projectPath
        paths = $PathArray
        pathCount = $State.Paths.Count
        tools = $ToolArray
        userMessages = $State.UserMessages
        assistantMessages = $State.AssistantMessages
        toolCalls = $State.ToolCalls
        records = $State.Records
        parseErrors = $State.ParseErrors
        sourceFiles = $Group.files.Count
        sourceBytes = $State.Bytes
        recovery = 'unknown'
    }
}

function Read-JsonlGroup {
    param ($Group, [string]$Fingerprint, $Continuation = $null, [Diagnostics.Stopwatch]$WorkWatch = $null, [int]$BudgetSeconds = 0)

    $State = Restore-IntelligencePartialState -Group $Group -Fingerprint $Fingerprint -Partial $Continuation
    $ResolvedId = $Group.id
    $StartFile = 0
    $StartLine = 0L
    $Files = @($Group.files | Where-Object {
        $_.Extension -eq '.jsonl' -and -not (Test-AntigravityJsonlChunkFile -File $_)
    } | Sort-Object FullName)
    if ($State -and $Continuation.fileIndex -lt $Files.Count -and $Continuation.fileIndex -ge 0 -and $Continuation.nextLine -ge 0) {
        $StartFile = [int]$Continuation.fileIndex
        $StartLine = [long]$Continuation.nextLine
        if (Test-SafeSessionId -Id $Continuation.resolvedId) { $ResolvedId = [string]$Continuation.resolvedId }
    }
    else { $State = Get-BaseSessionState -Group $Group -Fingerprint $Fingerprint }
    $ProcessedInPass = 0L
    for ($FileIndex = $StartFile; $FileIndex -lt $Files.Count; $FileIndex++) {
        $File = $Files[$FileIndex]
        $Reader = $null
        try {
            $Reader = Get-SharedReader -Path $File.FullName
            $LineNumber = 0L
            # Replaying lines without JSON conversion is cheap and avoids using
            # StreamReader.BaseStream.Position, which points past buffered data
            # and would silently skip records (including multibyte UTF-8).
            if ($FileIndex -eq $StartFile) {
                while ($LineNumber -lt $StartLine -and -not $Reader.EndOfStream) {
                    $null = $Reader.ReadLine()
                    $LineNumber++
                }
                if ($LineNumber -ne $StartLine) {
                    # A damaged continuation must not turn unread data into a
                    # complete record. Retry this group once without the cache.
                    return Read-JsonlGroup -Group $Group -Fingerprint $Fingerprint -WorkWatch $WorkWatch -BudgetSeconds $BudgetSeconds
                }
            }
            while (-not $Reader.EndOfStream) {
                if ($ProcessedInPass -gt 0 -and $BudgetSeconds -gt 0 -and $WorkWatch -and $WorkWatch.Elapsed.TotalSeconds -ge $BudgetSeconds) {
                    return [pscustomobject]@{
                        intelligencePending = $true
                        continuation = New-IntelligencePartial -State $State -ResolvedId $ResolvedId -FileIndex $FileIndex -NextLine $LineNumber
                    }
                }
                $Line = $Reader.ReadLine()
                $LineNumber++
                $ProcessedInPass++
                if ([string]::IsNullOrWhiteSpace($Line)) { continue }
                try { $Object = $Line | ConvertFrom-Json }
                catch { $State.ParseErrors++; continue }
                $State.Records++
                Update-TimeRange -State $State.Time -Value (Get-ObjectPropertyValue -Object $Object -Name 'timestamp')
                Update-TimeRange -State $State.Time -Value (Get-ObjectPropertyValue -Object $Object -Name 'created_at')
                switch ($Group.agent) {
                    'claude' {
                        $Cwd = [string](Get-ObjectPropertyValue -Object $Object -Name 'cwd')
                        if ($Cwd) { [void]$State.MetadataPaths.Add($Cwd) }
                        $SessionId = [string](Get-ObjectPropertyValue -Object $Object -Name 'sessionId')
                        if (Test-SafeSessionId -Id $SessionId) { $ResolvedId = $SessionId }
                        $Type = [string](Get-ObjectPropertyValue -Object $Object -Name 'type')
                        if ($Type -eq 'user') { $State.UserMessages++ }
                        elseif ($Type -eq 'assistant') { $State.AssistantMessages++ }
                        elseif ($Type -eq 'ai-title') { $State.Title = [string](Get-ObjectPropertyValue -Object $Object -Name 'aiTitle') }
                        elseif ($Type -eq 'custom-title') { $State.Title = [string](Get-ObjectPropertyValue -Object $Object -Name 'customTitle') }
                        $Message = Get-ObjectPropertyValue -Object $Object -Name 'message'
                        Add-StructuredPathReferences -Object (Get-ObjectPropertyValue -Object $Message -Name 'content') -Paths $State.Paths -ProjectPath $Group.projectPath
                        $Model = [string](Get-ObjectPropertyValue -Object $Message -Name 'model')
                        if ($Model) { $State.Model = $Model; $State.Provider = 'anthropic' }
                        foreach ($Part in @((Get-ObjectPropertyValue -Object $Message -Name 'content'))) {
                            if ([string](Get-ObjectPropertyValue -Object $Part -Name 'type') -eq 'tool_use') {
                                $State.ToolCalls++
                                Add-ToolCount -Tools $State.Tools -Name ([string](Get-ObjectPropertyValue -Object $Part -Name 'name'))
                            }
                        }
                    }
                    'codex' {
                        $Payload = Get-ObjectPropertyValue -Object $Object -Name 'payload'
                        $OuterType = [string](Get-ObjectPropertyValue -Object $Object -Name 'type')
                        $InnerType = [string](Get-ObjectPropertyValue -Object $Payload -Name 'type')
                        if ($OuterType -eq 'session_meta') {
                            $CandidateId = [string](Get-ObjectPropertyValue -Object $Payload -Name 'id')
                            if (-not $CandidateId) { $CandidateId = [string](Get-ObjectPropertyValue -Object $Payload -Name 'session_id') }
                            if (Test-SafeSessionId -Id $CandidateId) { $ResolvedId = $CandidateId }
                            $Cwd = [string](Get-ObjectPropertyValue -Object $Payload -Name 'cwd')
                            if ($Cwd) { [void]$State.MetadataPaths.Add($Cwd) }
                            $State.Provider = [string](Get-ObjectPropertyValue -Object $Payload -Name 'model_provider')
                        }
                        if ($OuterType -eq 'turn_context') {
                            $Cwd = [string](Get-ObjectPropertyValue -Object $Payload -Name 'cwd')
                            if ($Cwd) { [void]$State.MetadataPaths.Add($Cwd) }
                            $Model = [string](Get-ObjectPropertyValue -Object $Payload -Name 'model')
                            if ($Model) { $State.Model = $Model }
                        }
                        if ($InnerType -eq 'user_message' -or ($InnerType -eq 'message' -and [string]$Payload.role -eq 'user')) { $State.UserMessages++ }
                        if ($InnerType -eq 'agent_message' -or ($InnerType -eq 'message' -and [string]$Payload.role -eq 'assistant')) { $State.AssistantMessages++ }
                        if ($InnerType -match 'function_call|custom_tool_call') {
                            $State.ToolCalls++
                            Add-ToolCount -Tools $State.Tools -Name ([string](Get-ObjectPropertyValue -Object $Payload -Name 'name'))
                            Add-StructuredPathReferences -Object $Payload -Paths $State.Paths -ProjectPath $Group.projectPath
                        }
                    }
                    'antigravity' {
                        $Type = [string](Get-ObjectPropertyValue -Object $Object -Name 'type')
                        if ($Type -eq 'USER_INPUT') { $State.UserMessages++ }
                        elseif ($Type -match 'RESPONSE$') { $State.AssistantMessages++ }
                        foreach ($Tool in @((Get-ObjectPropertyValue -Object $Object -Name 'tool_calls'))) {
                            $State.ToolCalls++
                            Add-ToolCount -Tools $State.Tools -Name ([string](Get-ObjectPropertyValue -Object $Tool -Name 'name'))
                            Add-StructuredPathReferences -Object $Tool -Paths $State.Paths -ProjectPath $Group.projectPath
                        }
                    }
                }
            }
        }
        catch { $State.ParseErrors++ }
        finally { if ($Reader) { $Reader.Dispose() } }
    }
    foreach ($File in @($Group.files)) { $File.Refresh() }
    $CurrentFingerprint = Get-SourceFingerprint -Group $Group
    if ($CurrentFingerprint -cne $Fingerprint) {
        # The native source changed while it was read. Neither a partial state
        # nor a completed report may claim that mixed snapshot as current.
        $FreshState = Get-BaseSessionState -Group $Group -Fingerprint $CurrentFingerprint
        return [pscustomobject]@{
            intelligencePending = $true
            continuation = New-IntelligencePartial -State $FreshState -ResolvedId $Group.id -FileIndex 0 -NextLine 0
        }
    }
    return Complete-SessionRecord -State $State -Id $ResolvedId
}

function Read-OpenCodeGroup {
    param ($Group, [string]$Fingerprint)

    $State = Get-BaseSessionState -Group $Group -Fingerprint $Fingerprint
    $ResolvedId = $Group.id
    foreach ($File in @($Group.files)) {
        try {
            $Export = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $Info = Get-ObjectPropertyValue -Object $Export -Name 'info'
            $CandidateId = [string](Get-ObjectPropertyValue -Object $Info -Name 'id')
            if (Test-SafeSessionId -Id $CandidateId) { $ResolvedId = $CandidateId }
            $Directory = [string](Get-ObjectPropertyValue -Object $Info -Name 'directory')
            if ($Directory) { [void]$State.MetadataPaths.Add($Directory) }
            $State.Title = [string](Get-ObjectPropertyValue -Object $Info -Name 'title')
            $ModelObject = Get-ObjectPropertyValue -Object $Info -Name 'model'
            $State.Model = [string](Get-ObjectPropertyValue -Object $ModelObject -Name 'id')
            $State.Provider = [string](Get-ObjectPropertyValue -Object $ModelObject -Name 'providerID')
            $InfoTime = Get-ObjectPropertyValue -Object $Info -Name 'time'
            Update-TimeRange -State $State.Time -Value (Get-ObjectPropertyValue -Object $InfoTime -Name 'created')
            Update-TimeRange -State $State.Time -Value (Get-ObjectPropertyValue -Object $InfoTime -Name 'updated')
            foreach ($Message in @((Get-ObjectPropertyValue -Object $Export -Name 'messages'))) {
                $MessageInfo = Get-ObjectPropertyValue -Object $Message -Name 'info'
                $Role = [string](Get-ObjectPropertyValue -Object $MessageInfo -Name 'role')
                if ($Role -eq 'user') { $State.UserMessages++ }
                elseif ($Role -eq 'assistant') { $State.AssistantMessages++ }
                $MessageTime = Get-ObjectPropertyValue -Object $MessageInfo -Name 'time'
                Update-TimeRange -State $State.Time -Value (Get-ObjectPropertyValue -Object $MessageTime -Name 'created')
                Update-TimeRange -State $State.Time -Value (Get-ObjectPropertyValue -Object $MessageTime -Name 'completed')
                $Model = [string](Get-ObjectPropertyValue -Object $MessageInfo -Name 'modelID')
                $Provider = [string](Get-ObjectPropertyValue -Object $MessageInfo -Name 'providerID')
                if ($Model) { $State.Model = $Model }
                if ($Provider) { $State.Provider = $Provider }
                foreach ($Part in @((Get-ObjectPropertyValue -Object $Message -Name 'parts'))) {
                    Add-StructuredPathReferences -Object $Part -Paths $State.Paths -ProjectPath $Group.projectPath
                    if ([string](Get-ObjectPropertyValue -Object $Part -Name 'type') -eq 'tool') {
                        $State.ToolCalls++
                        Add-ToolCount -Tools $State.Tools -Name ([string](Get-ObjectPropertyValue -Object $Part -Name 'tool'))
                    }
                }
            }
        }
        catch { $State.ParseErrors++ }
    }
    return Complete-SessionRecord -State $State -Id $ResolvedId
}

function Get-ClineNestedValue {
    param ($Object, [string[]]$Paths)
    foreach ($Path in @($Paths)) {
        $Current = $Object
        foreach ($Segment in @($Path -split '\.')) {
            if ($null -eq $Current) { break }
            $Current = Get-ObjectPropertyValue -Object $Current -Name $Segment
        }
        if ($null -ne $Current -and -not [string]::IsNullOrWhiteSpace([string]$Current)) { return $Current }
    }
    return $null
}

function Read-ClineGroup {
    param ($Group, [string]$Fingerprint)

    $State = Get-BaseSessionState -Group $Group -Fingerprint $Fingerprint
    $ResolvedId = $Group.id
    $MetadataFiles = @($Group.files | Where-Object {
        $_.Name -eq 'task-history-item.json' -or
        ($_.Name -eq "$($Group.id).json")
    })
    foreach ($File in $MetadataFiles) {
        try {
            $Object = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $CandidateId = [string](Get-ClineNestedValue -Object $Object -Paths @('session_id', 'sessionId', 'id'))
            if (Test-SafeSessionId -Id $CandidateId) { $ResolvedId = $CandidateId }
            $Workspace = [string](Get-ClineNestedValue -Object $Object -Paths @('cwdOnTaskInitialization', 'cwd', 'workspaceRoot', 'workspace_root'))
            if ($Workspace) { [void]$State.MetadataPaths.Add($Workspace) }
            $Title = [string](Get-ClineNestedValue -Object $Object -Paths @('metadata.title', 'title', 'task', 'prompt'))
            if ($Title) { $State.Title = $Title }
            $Model = [string](Get-ClineNestedValue -Object $Object -Paths @('modelId', 'model', 'model_id', 'metadata.modelId', 'metadata.model'))
            $Provider = [string](Get-ClineNestedValue -Object $Object -Paths @('provider', 'providerId', 'provider_id', 'metadata.provider'))
            if ($Model) { $State.Model = $Model }
            if ($Provider) { $State.Provider = $Provider }
            foreach ($TimeField in @('ts', 'started_at', 'startedAt', 'ended_at', 'endedAt', 'updated_at', 'updatedAt')) {
                Update-TimeRange -State $State.Time -Value (Get-ObjectPropertyValue -Object $Object -Name $TimeField)
            }
        }
        catch { $State.ParseErrors++ }
    }

    $MessageFiles = @($Group.files | Where-Object { $_.Name -like '*.messages.json' })
    if ($MessageFiles.Count -eq 0) { $MessageFiles = @($Group.files | Where-Object Name -eq 'ui_messages.json') }
    if ($MessageFiles.Count -eq 0) { $MessageFiles = @($Group.files | Where-Object Name -eq 'api_conversation_history.json') }
    foreach ($File in $MessageFiles) {
        try {
            $Messages = @(Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8 | ConvertFrom-Json)
            foreach ($Message in $Messages) {
                $State.Records++
                Update-TimeRange -State $State.Time -Value (Get-ObjectPropertyValue -Object $Message -Name 'ts')
                Update-TimeRange -State $State.Time -Value (Get-ObjectPropertyValue -Object $Message -Name 'timestamp')
                $Role = [string](Get-ObjectPropertyValue -Object $Message -Name 'role')
                $Type = [string](Get-ObjectPropertyValue -Object $Message -Name 'type')
                $Say = [string](Get-ObjectPropertyValue -Object $Message -Name 'say')
                $Ask = [string](Get-ObjectPropertyValue -Object $Message -Name 'ask')
                if ($Role -eq 'user' -or ($Type -eq 'say' -and $Say -in @('task', 'user_feedback'))) { $State.UserMessages++ }
                elseif ($Role -eq 'assistant' -or $Type -in @('assistant', 'agent')) { $State.AssistantMessages++ }
                elseif ($Type -eq 'say' -and $Say -in @('text', 'completion_result', 'reasoning')) { $State.AssistantMessages++ }

                $ModelInfo = Get-ObjectPropertyValue -Object $Message -Name 'modelInfo'
                $Model = [string](Get-ClineNestedValue -Object $ModelInfo -Paths @('modelId', 'model', 'id'))
                $Provider = [string](Get-ClineNestedValue -Object $ModelInfo -Paths @('providerId', 'provider'))
                if ($Model) { $State.Model = $Model }
                if ($Provider) { $State.Provider = $Provider }

                foreach ($Tool in @((Get-ObjectPropertyValue -Object $Message -Name 'toolCalls'))) {
                    $State.ToolCalls++
                    Add-ToolCount -Tools $State.Tools -Name ([string](Get-ClineNestedValue -Object $Tool -Paths @('name', 'tool', 'function.name')))
                    Add-StructuredPathReferences -Object $Tool -Paths $State.Paths -ProjectPath $Group.projectPath
                }
                if ($Ask -match 'tool|command|browser|mcp' -or $Say -match 'tool|command|browser|mcp') {
                    $State.ToolCalls++
                    Add-ToolCount -Tools $State.Tools -Name $(if ($Ask) { $Ask } else { $Say })
                }
            }
        }
        catch { $State.ParseErrors++ }
    }
    return Complete-SessionRecord -State $State -Id $ResolvedId
}

function Read-AiderGroup {
    param ($Group, [string]$Fingerprint)

    $State = Get-BaseSessionState -Group $Group -Fingerprint $Fingerprint
    foreach ($File in @($Group.files | Where-Object Name -Like '*.chat.md')) {
        $Reader = $null
        try {
            $Reader = Get-SharedReader -Path $File.FullName
            while (-not $Reader.EndOfStream) {
                $Line = $Reader.ReadLine()
                $State.Records++

                # Only provider metadata is derived. Prompts, answers, code and
                # command output in the same Markdown file are never copied to
                # the Intelligence index.
                if ($Line -match '^# aider chat started at (?<time>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\s*$') {
                    try {
                        $StartedLocal = [datetime]::ParseExact(
                            [string]$Matches.time,
                            'yyyy-MM-dd HH:mm:ss',
                            [Globalization.CultureInfo]::InvariantCulture,
                            [Globalization.DateTimeStyles]::AssumeLocal)
                        Update-TimeRange -State $State.Time -Value ([datetimeoffset]$StartedLocal)
                    }
                    catch { $State.ParseErrors++ }
                    continue
                }
                if ($Line -match '^\s*>\s*Model:\s*(?<model>.+?)(?:\s+with\s+.+)?\s*$') {
                    $State.Model = [string]$Matches.model
                    if ($State.Model -match '^(?<provider>[^/]+)/') { $State.Provider = [string]$Matches.provider }
                    continue
                }
                if ($Line -match '^\s*>\s*Cur working dir:\s*(?<path>.+?)\s*$') {
                    [void]$State.MetadataPaths.Add([string]$Matches.path)
                }
            }
        }
        catch { $State.ParseErrors++ }
        finally { if ($Reader) { $Reader.Dispose() } }
    }
    return Complete-SessionRecord -State $State -Id $Group.id
}

function Get-StatusModelMap {
    param ([string]$StatusPath)

    $Map = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if (-not (Test-Path -LiteralPath $StatusPath -PathType Leaf)) { return $Map }
    try {
        $Status = Get-Content -LiteralPath $StatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($ProjectRecord in @($Status.projects)) {
            $Project = ([string](Get-ObjectPropertyValue -Object $ProjectRecord -Name 'Project')).Trim() -replace ' / ', [System.IO.Path]::DirectorySeparatorChar
            if (-not $Project) { continue }

            foreach ($AgentName in @('Claude', 'Codex', 'Antigravity', 'OpenCode', 'Cline', 'Aider')) {
                $Metric = Get-ObjectPropertyValue -Object $ProjectRecord -Name $AgentName
                if (-not $Metric) { continue }

                $Model = ([string](Get-ObjectPropertyValue -Object $Metric -Name 'Model')).Trim()
                $Provider = ([string](Get-ObjectPropertyValue -Object $Metric -Name 'Provider')).Trim()
                if ($Model -and $Model -ne 'Ikke registrert') {
                    $Agent = $AgentName.ToLowerInvariant()
                    $Map["$Project|$Agent"] = [PSCustomObject]@{ model = $Model; provider = if ($Provider -eq '-') { '' } else { $Provider } }
                }
            }
        }
    }
    catch { }
    return $Map
}

function Get-RecoveryMap {
    param ([string]$RecoveryPath)

    $Map = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if (-not (Test-Path -LiteralPath $RecoveryPath -PathType Leaf)) { return $Map }
    try {
        $Recovery = Get-Content -LiteralPath $RecoveryPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($Project in @($Recovery.projects)) {
            foreach ($Agent in @($Project.agents)) {
                $Map["$([string]$Project.relative)|$([string]$Agent.name)"] = [string]$Agent.status
            }
        }
    }
    catch { }
    return $Map
}

function Get-HtmlEncoded {
    param ([AllowNull()][object]$Value)
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Format-ByteSize {
    param ([long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Get-AgentDisplayName {
    param ([string]$Agent)
    switch ($Agent) {
        'claude' { return 'Claude' }
        'codex' { return 'Codex' }
        'antigravity' { return 'Antigravity' }
        'opencode' { return 'OpenCode' }
        'cline' { return 'Cline' }
        'aider' { return 'Aider' }
        default { return $Agent }
    }
}

function Get-RelativeOutputPath {
    param ([string]$FromFile, [string]$ToFile)
    try {
        $FromDir = Split-Path ([System.IO.Path]::GetFullPath($FromFile)) -Parent
        return [System.IO.Path]::GetRelativePath($FromDir, [System.IO.Path]::GetFullPath($ToFile)).Replace('\', '/')
    }
    catch { return $null }
}

function Add-SourceFile {
    param (
        [System.Collections.Generic.Dictionary[string, object]]$Groups,
        [string]$StorageKey,
        [string]$Agent,
        [string]$Id,
        [string]$ProjectRelative,
        [string]$ProjectPath,
        [string]$Surface,
        [System.IO.FileInfo]$File
    )

    if (-not $Groups.ContainsKey($StorageKey)) {
        $Groups[$StorageKey] = New-SourceGroup -StorageKey $StorageKey -Agent $Agent -Id $Id -ProjectRelative $ProjectRelative -ProjectPath $ProjectPath -Surface $Surface
    }
    $Groups[$StorageKey].files.Add($File)
    return $Groups[$StorageKey]
}

$Started = [datetimeoffset]::UtcNow
$WorkWatch = [Diagnostics.Stopwatch]::StartNew()
if ([string]::IsNullOrWhiteSpace($ConfigFile)) {
    $LocalConfig = Join-Path $PSScriptRoot 'config.local.json'
    $ConfigFile = if (Test-Path -LiteralPath $LocalConfig -PathType Leaf) { $LocalConfig } else { Join-Path $PSScriptRoot 'config.json' }
}
$ConfigFile = [System.IO.Path]::GetFullPath($ConfigFile)
if (-not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) { throw "Config file not found: $ConfigFile" }
$Config = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json

$IntelligenceConfig = Get-ObjectPropertyValue -Object $Config -Name 'intelligenceReport'
if (-not $PSBoundParameters.ContainsKey('OutputFile') -or [string]::IsNullOrWhiteSpace($OutputFile)) {
    $OutputFile = [string](Get-ObjectPropertyValue -Object $IntelligenceConfig -Name 'file')
    if (-not $OutputFile) { $OutputFile = 'AgentSync-Intelligence.html' }
}
if (-not $PSBoundParameters.ContainsKey('DataFile') -or [string]::IsNullOrWhiteSpace($DataFile)) {
    $DataFile = [string](Get-ObjectPropertyValue -Object $IntelligenceConfig -Name 'dataFile')
    if (-not $DataFile) { $DataFile = 'AgentSync-Intelligence.json' }
}
if ($MaxTimelineSessions -le 0) {
    $ConfiguredMaximum = Get-ObjectPropertyValue -Object $IntelligenceConfig -Name 'maxTimelineSessions'
    $MaxTimelineSessions = if ($ConfiguredMaximum) { [int]$ConfiguredMaximum } else { 1000 }
}
$MaxTimelineSessions = [Math]::Max(100, [Math]::Min(10000, $MaxTimelineSessions))

$ProjectsSetting = if ($Config.sharedProjectsDir) { [string]$Config.sharedProjectsDir } else { [string]$Config.dropboxProjectsDir }
$ProjectsRoot = Expand-AgentSyncPath -Path $ProjectsSetting
if (-not (Test-Path -LiteralPath $ProjectsRoot -PathType Container)) { throw "Shared projects root not found: $ProjectsRoot" }

$IndexSetting = 'project-index'
if ($Config.projectIndex -and $Config.projectIndex.directory) { $IndexSetting = [string]$Config.projectIndex.directory }
$IndexDirectory = if ([System.IO.Path]::IsPathRooted($IndexSetting)) { [System.IO.Path]::GetFullPath($IndexSetting) } else { [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot $IndexSetting)) }
if (-not [System.IO.Path]::IsPathRooted($OutputFile)) { $OutputFile = Join-Path $PSScriptRoot $OutputFile }
if (-not [System.IO.Path]::IsPathRooted($DataFile)) { $DataFile = Join-Path $PSScriptRoot $DataFile }
$OutputFile = Assert-SafeOutputPath -Path $OutputFile -Config $Config -IndexDirectory $IndexDirectory -ConfigFile $ConfigFile
$DataFile = Assert-SafeOutputPath -Path $DataFile -Config $Config -IndexDirectory $IndexDirectory -ConfigFile $ConfigFile
$ProgressFile = Assert-SafeOutputPath -Path ($DataFile + '.progress.json') -Config $Config -IndexDirectory $IndexDirectory -ConfigFile $ConfigFile
if ($OutputFile.Equals($DataFile, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'OutputFile and DataFile must be different files.' }

$MutexName = 'AgentSyncIntelligence-' + (Get-Sha256Text -Text $DataFile).Substring(0, 24)
$Mutex = [System.Threading.Mutex]::new($false, $MutexName)
$MutexAcquired = $false
try {
    try { $MutexAcquired = $Mutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $MutexAcquired = $true }
    if (-not $MutexAcquired) {
        Write-Host 'AgentSync intelligence is already being refreshed by another process.' -ForegroundColor DarkGray
        return
    }

$ProjectMap = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
if (-not (Test-Path -LiteralPath $IndexDirectory -PathType Container)) { throw "Project index not found: $IndexDirectory" }
foreach ($IndexFile in @(Get-ChildItem -LiteralPath $IndexDirectory -File -Filter '*.json' -ErrorAction SilentlyContinue)) {
    try {
        $Index = Get-Content -LiteralPath $IndexFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($RawRelative in @($Index.projects)) {
            $Relative = ([string]$RawRelative).Trim().Replace('/', [System.IO.Path]::DirectorySeparatorChar)
            if (-not $Relative -or [System.IO.Path]::IsPathRooted($Relative)) { continue }
            $Candidate = [System.IO.Path]::GetFullPath((Join-Path $ProjectsRoot $Relative)).TrimEnd('\', '/')
            if (-not (Test-PathInside -ChildPath $Candidate -ParentPath $ProjectsRoot) -or $Candidate.Equals($ProjectsRoot, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            if (-not (Test-Path -LiteralPath $Candidate -PathType Container)) { continue }
            $CanonicalRelative = [System.IO.Path]::GetRelativePath($ProjectsRoot, $Candidate)
            if (-not $ProjectMap.ContainsKey($CanonicalRelative)) {
                $ProjectMap[$CanonicalRelative] = [PSCustomObject]@{ relative = $CanonicalRelative; path = $Candidate }
            }
        }
    }
    catch { }
}
if ($ProjectMap.Count -eq 0) { throw 'The agent-derived project index did not contain any available projects.' }

$StatusSetting = 'AgentSync-Status.json'
if ($Config.statusReport -and $Config.statusReport.jsonFile) { $StatusSetting = [string]$Config.statusReport.jsonFile }
$StatusPath = if ([System.IO.Path]::IsPathRooted($StatusSetting)) { $StatusSetting } else { Join-Path $PSScriptRoot $StatusSetting }
$ModelMap = Get-StatusModelMap -StatusPath $StatusPath
$RecoveryMap = Get-RecoveryMap -RecoveryPath (Join-Path $PSScriptRoot 'AgentSync-Recovery.json')

$CachedMap = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
if (-not $Force -and (Test-Path -LiteralPath $DataFile -PathType Leaf)) {
    try {
        $Previous = Get-Content -LiteralPath $DataFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $PreviousRecords = if ($Previous.PSObject.Properties['sourceRecords']) { @($Previous.sourceRecords) } else { @($Previous.sessions) }
        foreach ($Session in $(if ($Previous.projectsRoot -ceq $ProjectsRoot) { $PreviousRecords } else { @() })) {
            if ([int]$Session.parserVersion -eq $Script:ParserVersion -and $Session.storageKey) { $CachedMap[[string]$Session.storageKey] = $Session }
        }
    }
    catch { }
}
if (-not $Force) {
    foreach ($Record in @(Read-IntelligenceProgress -Path $ProgressFile -ProjectsRoot $ProjectsRoot)) {
        $CachedMap[[string]$Record.storageKey] = $Record
    }
}
$Partial = if ($Force) { $null } else { Read-IntelligencePartial -Path $ProgressFile -ProjectsRoot $ProjectsRoot }
$ResumeMap = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($Key in $CachedMap.Keys) { $ResumeMap[$Key] = $CachedMap[$Key] }
$PhaseWatch = [Diagnostics.Stopwatch]::StartNew()

$Groups = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
$ClaudeAgent = @($Config.agents | Where-Object { $_.enabled -ne $false -and [string]$_.routingMode -eq 'claude' } | Select-Object -First 1)
$CodexAgents = @($Config.agents | Where-Object { $_.enabled -ne $false -and [string]$_.routingMode -eq 'codex' })
$AntigravityAgent = @($Config.agents | Where-Object { $_.enabled -ne $false -and [string]$_.routingMode -eq 'antigravity' } | Select-Object -First 1)
$OpenCodeAgent = @($Config.agents | Where-Object { $_.enabled -ne $false -and [string]$_.routingMode -eq 'opencode' } | Select-Object -First 1)
$ClineAgent = @($Config.agents | Where-Object { $_.enabled -ne $false -and [string]$_.routingMode -eq 'cline' } | Select-Object -First 1)

foreach ($Project in @($ProjectMap.Values | Sort-Object relative)) {
    if ($ClaudeAgent.Count -gt 0) {
        $Root = Join-Path $Project.path ([string]$ClaudeAgent[0].targetSubDir)
        if (Test-Path -LiteralPath $Root -PathType Container) {
            foreach ($File in @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue)) {
                $Relative = [System.IO.Path]::GetRelativePath($Root, $File.FullName)
                $Segments = @($Relative -split '[\\/]')
                if ($Segments.Count -lt 2) { continue }
                $Bucket = $Segments[0]
                $SessionId = [System.IO.Path]::GetFileNameWithoutExtension($Segments[1])
                if (-not (Test-SafeSessionId -Id $SessionId)) { continue }
                $Key = "$($Project.relative)|claude|$Bucket|$SessionId"
                $null = Add-SourceFile -Groups $Groups -StorageKey $Key -Agent 'claude' -Id $SessionId -ProjectRelative $Project.relative -ProjectPath $Project.path -Surface '' -File $File
            }
        }
    }
    foreach ($Agent in $CodexAgents) {
        $Root = Join-Path $Project.path ([string]$Agent.targetSubDir)
        if (-not (Test-Path -LiteralPath $Root -PathType Container)) { continue }
        $Surface = if ([string]$Agent.targetSubDir -match 'archived') { 'archived' } else { 'active' }
        foreach ($File in @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue)) {
            $FileId = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
            $Key = "$($Project.relative)|codex|$Surface|$FileId"
            $null = Add-SourceFile -Groups $Groups -StorageKey $Key -Agent 'codex' -Id $FileId -ProjectRelative $Project.relative -ProjectPath $Project.path -Surface $Surface -File $File
        }
    }
    if ($AntigravityAgent.Count -gt 0) {
        $Root = Join-Path $Project.path ([string]$AntigravityAgent[0].targetSubDir)
        if (Test-Path -LiteralPath $Root -PathType Container) {
            foreach ($SurfaceDir in @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)) {
                $SessionsRoot = Join-Path $SurfaceDir.FullName 'sessions'
                if (-not (Test-Path -LiteralPath $SessionsRoot -PathType Container)) { continue }
                foreach ($SessionDir in @(Get-ChildItem -LiteralPath $SessionsRoot -Directory -ErrorAction SilentlyContinue)) {
                    if (-not (Test-SafeSessionId -Id $SessionDir.Name)) { continue }
                    $Key = "$($Project.relative)|antigravity|$($SurfaceDir.Name)|$($SessionDir.Name)"
                    foreach ($File in @(Get-ChildItem -LiteralPath $SessionDir.FullName -Recurse -File -ErrorAction SilentlyContinue)) {
                        $Group = Add-SourceFile -Groups $Groups -StorageKey $Key -Agent 'antigravity' -Id $SessionDir.Name -ProjectRelative $Project.relative -ProjectPath $Project.path -Surface $SurfaceDir.Name -File $File
                    }
                    $WorkspaceIndex = Join-Path $Project.path ".agent-state/index/antigravity-workspaces/$($SurfaceDir.Name)/$($SessionDir.Name).json"
                    if ($Groups.ContainsKey($Key) -and (Test-Path -LiteralPath $WorkspaceIndex -PathType Leaf)) {
                        try { $Groups[$Key].metadataPath = [string](Get-Content -LiteralPath $WorkspaceIndex -Raw -Encoding UTF8 | ConvertFrom-Json).workspace } catch { }
                    }
                }
            }
        }
    }
    if ($OpenCodeAgent.Count -gt 0) {
        $Root = Join-Path $Project.path ([string]$OpenCodeAgent[0].targetSubDir)
        if (Test-Path -LiteralPath $Root -PathType Container) {
            foreach ($File in @(Get-ChildItem -LiteralPath $Root -File -Filter '*.json' -ErrorAction SilentlyContinue)) {
                $Id = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
                if (-not (Test-SafeSessionId -Id $Id)) { continue }
                $Key = "$($Project.relative)|opencode|$Id"
                $null = Add-SourceFile -Groups $Groups -StorageKey $Key -Agent 'opencode' -Id $Id -ProjectRelative $Project.relative -ProjectPath $Project.path -Surface '' -File $File
            }
        }
    }
    if ($ClineAgent.Count -gt 0) {
        $Root = Join-Path $Project.path ([string]$ClineAgent[0].targetSubDir)
        if (Test-Path -LiteralPath $Root -PathType Container) {
            foreach ($SurfaceDir in @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)) {
                $SessionsRoot = Join-Path $SurfaceDir.FullName 'sessions'
                if (-not (Test-Path -LiteralPath $SessionsRoot -PathType Container)) { continue }
                foreach ($SessionDir in @(Get-ChildItem -LiteralPath $SessionsRoot -Directory -ErrorAction SilentlyContinue)) {
                    if (-not (Test-SafeSessionId -Id $SessionDir.Name)) { continue }
                    $Key = "$($Project.relative)|cline|$($SurfaceDir.Name)|$($SessionDir.Name)"
                    foreach ($File in @(Get-ChildItem -LiteralPath $SessionDir.FullName -Recurse -File -ErrorAction SilentlyContinue)) {
                        $null = Add-SourceFile -Groups $Groups -StorageKey $Key -Agent 'cline' -Id $SessionDir.Name -ProjectRelative $Project.relative -ProjectPath $Project.path -Surface $SurfaceDir.Name -File $File
                    }
                    $WorkspaceIndex = Join-Path $Project.path ".agent-state/index/cline-workspaces/$($SurfaceDir.Name)/$($SessionDir.Name).json"
                    if ($Groups.ContainsKey($Key) -and (Test-Path -LiteralPath $WorkspaceIndex -PathType Leaf)) {
                        try { $Groups[$Key].metadataPath = [string](Get-Content -LiteralPath $WorkspaceIndex -Raw -Encoding UTF8 | ConvertFrom-Json).workspace } catch { }
                    }
                }
            }
        }
    }

    # Aider history is created directly in the project by AgentSync. It is
    # indexed as a project-local source, not presented as a native adapter.
    $AiderRoot = Join-Path $Project.path '.agent-state\aider'
    if (Test-Path -LiteralPath $AiderRoot -PathType Container) {
        foreach ($File in @(Get-ChildItem -LiteralPath $AiderRoot -File -ErrorAction SilentlyContinue)) {
            if ((Test-IsConflictCopyName -Name $File.Name) -or
                $File.Name -notmatch '^(?<id>[A-Za-z0-9][A-Za-z0-9._-]{0,127})\.(?:chat|llm)\.md$') {
                continue
            }
            $Id = [string]$Matches.id
            if (-not (Test-SafeSessionId -Id $Id)) { continue }
            $Key = "$($Project.relative)|aider|$Id"
            $Group = Add-SourceFile -Groups $Groups -StorageKey $Key -Agent 'aider' -Id $Id -ProjectRelative $Project.relative -ProjectPath $Project.path -Surface 'project-local' -File $File
            $Group.metadataPath = $Project.path
        }
    }
}

$ParsedSessions = [System.Collections.Generic.List[object]]::new()
$DiscoveryMs = $PhaseWatch.ElapsedMilliseconds
$PhaseWatch.Restart()
$LastCheckpointMs = 0L
$CacheHits = 0
$CacheMisses = 0
foreach ($Group in @($Groups.Values | Sort-Object storageKey)) {
    $DidParse = $false
    $Fingerprint = Get-SourceFingerprint -Group $Group
    $Record = $null
    if (-not $Force -and $CachedMap.ContainsKey($Group.storageKey) -and [string]$CachedMap[$Group.storageKey].sourceFingerprint -eq $Fingerprint) {
        $Record = $CachedMap[$Group.storageKey]
        $CacheHits++
    }
    else {
        $DidParse = $true
        Write-Verbose "Parsing $($Group.agent) $($Group.id), $($Group.files.Count) source file(s)."
        $GroupWatch = [Diagnostics.Stopwatch]::StartNew()
        $Record = switch ($Group.agent) {
            'opencode' { Read-OpenCodeGroup -Group $Group -Fingerprint $Fingerprint; break }
            'cline' { Read-ClineGroup -Group $Group -Fingerprint $Fingerprint; break }
            'aider' { Read-AiderGroup -Group $Group -Fingerprint $Fingerprint; break }
            default { Read-JsonlGroup -Group $Group -Fingerprint $Fingerprint -Continuation $Partial -WorkWatch $WorkWatch -BudgetSeconds $WorkBudgetSeconds }
        }
        if (Get-ObjectPropertyValue -Object $Record -Name 'intelligencePending') {
            $Partial = $Record.continuation
            Save-IntelligenceProgress -Path $ProgressFile -ProjectsRoot $ProjectsRoot -Records @($ResumeMap.Values) -Remaining ($Groups.Count - $ParsedSessions.Count) -Partial $Partial
            Write-Host "INTELLIGENCE pending: $($ParsedSessions.Count)/$($Groups.Count) groups complete; $($Group.agent) parsing saved at source line $($Partial.nextLine). Previous complete report preserved."
            return
        }
        if ($Partial -and $Partial.storageKey -ceq $Group.storageKey) { $Partial = $null }
        $CacheMisses++
        $ResumeMap[$Group.storageKey] = $Record
        Write-Verbose "Parsed $($Group.agent) $($Group.id) in $($GroupWatch.ElapsedMilliseconds) ms."
        if (($PhaseWatch.ElapsedMilliseconds - $LastCheckpointMs) -ge 10000) {
            Save-IntelligenceProgress -Path $ProgressFile -ProjectsRoot $ProjectsRoot -Records @($ResumeMap.Values) -Remaining ($Groups.Count - $ParsedSessions.Count - 1) -Partial $Partial
            $LastCheckpointMs = $PhaseWatch.ElapsedMilliseconds
        }
    }
    $Record.project = $Group.project
    $Record.projectPath = $Group.projectPath
    $ModelKey = "$($Group.project)|$($Group.agent)"
    if (($Record.model -eq 'Ikke registrert' -or $Group.agent -eq 'antigravity') -and $ModelMap.ContainsKey($ModelKey)) {
        $Record.model = [string]$ModelMap[$ModelKey].model
        $Record.provider = [string]$ModelMap[$ModelKey].provider
    }
    $RecoveryKey = "$($Group.project)|$($Group.agent)"
    $Record.recovery = if ($RecoveryMap.ContainsKey($RecoveryKey)) { $RecoveryMap[$RecoveryKey] } else { 'unknown' }
    $ParsedSessions.Add($Record)
    if ($DidParse -and $WorkBudgetSeconds -gt 0 -and $WorkWatch.Elapsed.TotalSeconds -ge $WorkBudgetSeconds -and $ParsedSessions.Count -lt $Groups.Count) {
        Save-IntelligenceProgress -Path $ProgressFile -ProjectsRoot $ProjectsRoot -Records @($ResumeMap.Values) -Remaining ($Groups.Count - $ParsedSessions.Count) -Partial $Partial
        Write-Host "INTELLIGENCE pending: $($ParsedSessions.Count)/$($Groups.Count) groups inspected; completed parsing saved for the next pass. Previous complete report preserved."
        return
    }
}
$ParsingMs = $PhaseWatch.ElapsedMilliseconds
$PhaseWatch.Restart()

$CanonicalSessions = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
$MappingRank = @{ exact = 4; portable = 3; unknown = 2; fallback = 1 }
foreach ($Session in $ParsedSessions) {
    $Key = "$($Session.agent)|$($Session.id)"
    if (-not $CanonicalSessions.ContainsKey($Key)) { $CanonicalSessions[$Key] = $Session; continue }
    $Existing = $CanonicalSessions[$Key]
    $NewRank = [int]$MappingRank[[string]$Session.mapping]
    $OldRank = [int]$MappingRank[[string]$Existing.mapping]
    $Replace = $NewRank -gt $OldRank
    if ($NewRank -eq $OldRank) {
        $NewTime = ConvertTo-TimeValue $Session.updatedUtc
        $OldTime = ConvertTo-TimeValue $Existing.updatedUtc
        if ($NewTime -and $OldTime -and $NewTime -gt $OldTime) { $Replace = $true }
    }
    if ($Replace) { $CanonicalSessions[$Key] = $Session }
}
$Sessions = @($CanonicalSessions.Values | Sort-Object @{ Expression = { ConvertTo-TimeValue $_.updatedUtc }; Descending = $true })

$ProjectSummaries = [System.Collections.Generic.List[object]]::new()
foreach ($Project in @($ProjectMap.Values | Sort-Object relative)) {
    $ProjectSessions = @($Sessions | Where-Object project -eq $Project.relative)
    $ProjectSummaries.Add([PSCustomObject]@{
        project = $Project.relative
        path = $Project.path
        sessions = $ProjectSessions.Count
        agents = @($ProjectSessions.agent | Sort-Object -Unique)
        models = @($ProjectSessions.model | Where-Object { $_ -and $_ -ne 'Ikke registrert' } | Sort-Object -Unique)
        paths = @($ProjectSessions.paths | Sort-Object -Unique).Count
        lastActivityUtc = @($ProjectSessions | Select-Object -First 1).updatedUtc
    })
}

$SharedPathMap = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($Session in $Sessions) {
    foreach ($Path in @($Session.paths)) {
        $Key = "$($Session.project)|$Path"
        if (-not $SharedPathMap.ContainsKey($Key)) {
            $SharedPathMap[$Key] = [PSCustomObject]@{
                project = $Session.project
                path = $Path
                AgentSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                SessionSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                lastActivityUtc = $Session.updatedUtc
            }
        }
        $Item = $SharedPathMap[$Key]
        [void]$Item.AgentSet.Add([string]$Session.agent)
        [void]$Item.SessionSet.Add([string]$Session.id)
        if ((ConvertTo-TimeValue $Session.updatedUtc) -gt (ConvertTo-TimeValue $Item.lastActivityUtc)) { $Item.lastActivityUtc = $Session.updatedUtc }
    }
}
$SharedPaths = @($SharedPathMap.Values | Where-Object { $_.AgentSet.Count -gt 1 } | ForEach-Object {
    [PSCustomObject]@{
        project = $_.project
        path = $_.path
        agents = @($_.AgentSet | Sort-Object)
        sessions = $_.SessionSet.Count
        lastActivityUtc = $_.lastActivityUtc
    }
} | Sort-Object @{ Expression = 'sessions'; Descending = $true }, @{ Expression = { ConvertTo-TimeValue $_.lastActivityUtc }; Descending = $true })

$FlowMap = @{}
foreach ($Project in $ProjectSummaries) {
    $Sequence = @($Sessions | Where-Object project -eq $Project.project | Sort-Object @{ Expression = { ConvertTo-TimeValue $_.updatedUtc } })
    for ($Index = 1; $Index -lt $Sequence.Count; $Index++) {
        $From = $Sequence[$Index - 1]
        $To = $Sequence[$Index]
        if ($From.agent -eq $To.agent) { continue }
        $Gap = (ConvertTo-TimeValue $To.updatedUtc) - (ConvertTo-TimeValue $From.updatedUtc)
        if ($Gap.TotalDays -gt 14) { continue }
        $Key = "$($From.agent)|$($To.agent)"
        if (-not $FlowMap.ContainsKey($Key)) { $FlowMap[$Key] = [PSCustomObject]@{ from = $From.agent; to = $To.agent; count = 0; projects = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase) } }
        $FlowMap[$Key].count++
        [void]$FlowMap[$Key].projects.Add([string]$Project.project)
    }
}
$Flows = @($FlowMap.Values | ForEach-Object { [PSCustomObject]@{ from = $_.from; to = $_.to; count = $_.count; projects = $_.projects.Count } } | Sort-Object count -Descending)

$ModelSummaries = @($Sessions | Where-Object { $_.model -and $_.model -ne 'Ikke registrert' } | Group-Object agent, model, provider | ForEach-Object {
    $Latest = @($_.Group | Sort-Object @{ Expression = { ConvertTo-TimeValue $_.updatedUtc }; Descending = $true } | Select-Object -First 1)[0]
    [PSCustomObject]@{ agent = $Latest.agent; model = $Latest.model; provider = $Latest.provider; sessions = $_.Count; projects = @($_.Group.project | Sort-Object -Unique).Count; lastActivityUtc = $Latest.updatedUtc }
} | Sort-Object sessions -Descending)

$SourceBytes = [long](($ParsedSessions | Measure-Object sourceBytes -Sum).Sum)
$Audit = [ordered]@{
    format = 1
    report = 'AgentSync multi-agent intelligence index'
    parserVersion = $Script:ParserVersion
    agentSyncVersion = [string]$Config.version
    generatedUtc = [datetimeoffset]::UtcNow.ToString('o')
    durationSeconds = 0
    phaseMs = [ordered]@{ discovery = $DiscoveryMs; parsing = $ParsingMs; summary = 0 }
    machine = [Environment]::MachineName
    platform = Get-CurrentPlatformName
    privacy = 'metadata-only; no raw messages, code, terminal output, or commands'
    projectsRoot = $ProjectsRoot
    cache = [ordered]@{ hits = $CacheHits; misses = $CacheMisses; forced = [bool]$Force }
    summary = [ordered]@{
        indexedProjects = $ProjectMap.Count
        activeProjects = @($ProjectSummaries | Where-Object sessions -gt 0).Count
        sessions = $Sessions.Count
        sourceCopies = $ParsedSessions.Count
        duplicateCopies = $ParsedSessions.Count - $Sessions.Count
        agents = @($Sessions.agent | Sort-Object -Unique).Count
        models = @($Sessions.model | Where-Object { $_ -and $_ -ne 'Ikke registrert' } | Sort-Object -Unique).Count
        paths = $SharedPathMap.Count
        sharedPaths = $SharedPaths.Count
        sourceBytes = $SourceBytes
        parseErrors = [int](($Sessions | Measure-Object parseErrors -Sum).Sum)
    }
    projects = $ProjectSummaries.ToArray()
    models = $ModelSummaries
    sharedPaths = $SharedPaths
    flows = $Flows
    sessions = $Sessions
    sourceRecords = $ParsedSessions.ToArray()
}
$Audit.durationSeconds = [Math]::Round(([datetimeoffset]::UtcNow - $Started).TotalSeconds, 2)
$Audit.phaseMs.summary = $PhaseWatch.ElapsedMilliseconds

function New-IntelligenceHtml {
    param ($Data)

    $StatusLink = Get-RelativeOutputPath -FromFile $OutputFile -ToFile $StatusPath
    $RecoveryLink = Get-RelativeOutputPath -FromFile $OutputFile -ToFile (Join-Path $PSScriptRoot 'AgentSync-Recovery.html')
    $ProjectOptions = [System.Text.StringBuilder]::new()
    foreach ($Project in @($Data.projects | Where-Object sessions -gt 0 | Sort-Object project)) {
        [void]$ProjectOptions.Append("<option value=`"$(Get-HtmlEncoded $Project.project)`">$(Get-HtmlEncoded ($Project.project -replace '[\\/]', ' / ')) ($($Project.sessions))</option>")
    }

    $AgentStats = [System.Text.StringBuilder]::new()
    foreach ($Agent in @('claude', 'codex', 'antigravity', 'opencode', 'cline', 'aider')) {
        $AgentSessions = @($Data.sessions | Where-Object agent -eq $Agent)
        $AgentProjects = @($AgentSessions.project | Sort-Object -Unique).Count
        $AgentModels = @($AgentSessions.model | Where-Object { $_ -and $_ -ne 'Ikke registrert' } | Sort-Object -Unique).Count
        [void]$AgentStats.Append(@"
<button type="button" class="agent-stat $Agent" data-agent-filter="$Agent" aria-pressed="false">
  <span class="brand-mark"></span><b>$(Get-HtmlEncoded (Get-AgentDisplayName $Agent))</b>
  <strong>$($AgentSessions.Count)</strong><small>økter · $AgentProjects prosjekter · $AgentModels modeller</small>
</button>
"@)
    }

    $ModelCards = [System.Text.StringBuilder]::new()
    foreach ($Model in @($Data.models | Select-Object -First 30)) {
        $Last = if ($Model.lastActivityUtc) { (ConvertTo-TimeValue $Model.lastActivityUtc).ToLocalTime().ToString('dd.MM.yyyy HH:mm') } else { 'ukjent' }
        [void]$ModelCards.Append(@"
<article class="model-card $($Model.agent)"><span class="brand-mark"></span><div><b>$(Get-HtmlEncoded $Model.model)</b><small>$(Get-HtmlEncoded (Get-AgentDisplayName $Model.agent))$(if ($Model.provider) { ' · ' + (Get-HtmlEncoded $Model.provider) })</small></div><strong>$($Model.sessions)</strong><small>$($Model.projects) prosjekt · sist $Last</small></article>
"@)
    }
    if ($ModelCards.Length -eq 0) { [void]$ModelCards.Append('<div class="empty">Ingen eksplisitte modelldata registrert.</div>') }

    $SharedCards = [System.Text.StringBuilder]::new()
    foreach ($Item in @($Data.sharedPaths | Select-Object -First 60)) {
        $Tags = (@($Item.agents) | ForEach-Object { "<span class=`"mini-agent $_`"><span class=`"brand-mark`"></span>$(Get-HtmlEncoded (Get-AgentDisplayName $_))</span>" }) -join ''
        $Last = if ($Item.lastActivityUtc) { (ConvertTo-TimeValue $Item.lastActivityUtc).ToLocalTime().ToString('dd.MM.yyyy') } else { 'ukjent' }
        [void]$SharedCards.Append(@"
<article class="shared-path" data-search="$(Get-HtmlEncoded "$($Item.project) $($Item.path) $($Item.agents -join ' ')")">
  <div class="shared-head">$Tags<span>$($Item.sessions) økter</span></div>
  <b>$(Get-HtmlEncoded $Item.path)</b><small>$(Get-HtmlEncoded ($Item.project -replace '[\\/]', ' / ')) · sist $Last</small>
</article>
"@)
    }
    if ($SharedCards.Length -eq 0) { [void]$SharedCards.Append('<div class="empty">Ingen strukturerte filstier er foreløpig registrert hos mer enn én agent.</div>') }

    $FlowCards = [System.Text.StringBuilder]::new()
    foreach ($Flow in @($Data.flows | Select-Object -First 12)) {
        [void]$FlowCards.Append(@"
<article class="flow-card"><span class="mini-agent $($Flow.from)"><span class="brand-mark"></span>$(Get-HtmlEncoded (Get-AgentDisplayName $Flow.from))</span><span class="arrow">→</span><span class="mini-agent $($Flow.to)"><span class="brand-mark"></span>$(Get-HtmlEncoded (Get-AgentDisplayName $Flow.to))</span><b>$($Flow.count)</b><small>$($Flow.projects) prosjekt</small></article>
"@)
    }
    if ($FlowCards.Length -eq 0) { [void]$FlowCards.Append('<div class="empty">Ingen agentbytter innenfor 14 dager er registrert.</div>') }

    $Timeline = [System.Text.StringBuilder]::new()
    $VisibleSessions = @($Data.sessions | Select-Object -First $MaxTimelineSessions)
    foreach ($Session in $VisibleSessions) {
        $DisplayAgent = Get-AgentDisplayName $Session.agent
        $Updated = if ($Session.updatedUtc) { (ConvertTo-TimeValue $Session.updatedUtc).ToLocalTime().ToString('dd.MM.yyyy HH:mm') } else { 'Ukjent tid' }
        $StartedText = if ($Session.startedUtc) { (ConvertTo-TimeValue $Session.startedUtc).ToLocalTime().ToString('dd.MM.yyyy HH:mm') } else { 'ukjent' }
        $Duration = ''
        if ($Session.startedUtc -and $Session.updatedUtc) {
            $Span = (ConvertTo-TimeValue $Session.updatedUtc) - (ConvertTo-TimeValue $Session.startedUtc)
            if ($Span.TotalMinutes -ge 1) { $Duration = if ($Span.TotalDays -ge 1) { '{0:N1} døgn' -f $Span.TotalDays } elseif ($Span.TotalHours -ge 1) { '{0:N1} t' -f $Span.TotalHours } else { '{0:N0} min' -f $Span.TotalMinutes } }
        }
        $ToolText = if (@($Session.tools).Count -gt 0) { (@($Session.tools | Select-Object -First 6 | ForEach-Object { "$($_.name) ×$($_.count)" })) -join ' · ' } else { 'Ingen strukturerte verktøydata' }
        $PathChips = if (@($Session.paths).Count -gt 0) {
            (@($Session.paths | Select-Object -First 8 | ForEach-Object { "<span class=`"path-chip`">$(Get-HtmlEncoded $_)</span>" })) -join ''
        }
        else { '<span class="muted">Ingen strukturerte filstier registrert</span>' }
        $MorePaths = if ([int]$Session.pathCount -gt 8) { "<small>+$([int]$Session.pathCount - 8) flere stier</small>" } else { '' }
        $CoverageClass = if ([int]$Session.parseErrors -gt 0) { 'warn' } else { 'ok' }
        $CoverageText = if ([int]$Session.parseErrors -gt 0) { "$($Session.parseErrors) poster kunne ikke tolkes" } else { 'Metadata lest' }
        $MappingText = switch ([string]$Session.mapping) { 'exact' { 'Eksakt prosjekt' } 'portable' { 'Portabel prosjektsti' } 'fallback' { 'Fallback-kopi' } default { 'Ukjent mapping' } }
        $RecoveryText = switch ([string]$Session.recovery) { 'ready' { 'Recovery klar' } 'warning' { 'Recovery må kontrolleres' } 'error' { 'Recovery-feil' } default { 'Ikke revidert' } }
        $Search = "$($Session.subject) $($Session.project) $($Session.projectPath) $DisplayAgent $($Session.model) $($Session.provider) $($Session.id) $($Session.paths -join ' ') $($Session.tools.name -join ' ')"
        [void]$Timeline.Append(@"
<article class="timeline-item $($Session.agent)" data-agent="$($Session.agent)" data-project="$(Get-HtmlEncoded $Session.project)" data-search="$(Get-HtmlEncoded $Search)">
  <div class="timeline-rail"><span class="brand-mark"></span></div>
  <div class="session-card">
    <div class="session-top"><span class="agent-tag $($Session.agent)"><span class="brand-mark"></span>$DisplayAgent</span><time>$(Get-HtmlEncoded $Updated)</time><span class="coverage $CoverageClass">$(Get-HtmlEncoded $CoverageText)</span></div>
    <h3>$(Get-HtmlEncoded $Session.subject)</h3>
    <div class="project-name">$(Get-HtmlEncoded ($Session.project -replace '[\\/]', ' / '))</div>
    <div class="session-meta"><span><b>Modell</b> $(Get-HtmlEncoded $Session.model)$(if ($Session.provider) { ' · ' + (Get-HtmlEncoded $Session.provider) })</span><span><b>Økt</b> $(Get-HtmlEncoded $Session.id)</span><span><b>Tid</b> $StartedText$(if ($Duration) { ' · ' + $Duration })</span></div>
    <div class="signals"><span class="mapping $($Session.mapping)">$(Get-HtmlEncoded $MappingText)</span><span class="recovery $($Session.recovery)">$(Get-HtmlEncoded $RecoveryText)</span><span>$($Session.userMessages) bruker · $($Session.assistantMessages) agent · $($Session.toolCalls) verktøy</span><span>$($Session.sourceFiles) state-filer · $(Get-HtmlEncoded (Format-ByteSize $Session.sourceBytes))</span></div>
    <div class="tool-line">$(Get-HtmlEncoded $ToolText)</div>
    <div class="path-list">$PathChips$MorePaths</div>
  </div>
</article>
"@)
    }

    $Generated = ([datetimeoffset]$Data.generatedUtc).ToLocalTime().ToString('dd.MM.yyyy HH:mm:ss zzz')
    $HiddenByLimit = [Math]::Max(0, [int]$Data.summary.sessions - $VisibleSessions.Count)
    return @"
<!doctype html>
<html lang="no">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>AgentSync Intelligence</title>
<style>
:root{color-scheme:dark;--bg:#0a1016;--panel:#121c26;--panel2:#0e1720;--line:#263646;--text:#eef5fb;--muted:#8ea4b8;--green:#35c27c;--yellow:#f1b747;--red:#ed6565;--blue:#68a9ff;--claude:#d97757;--codex:#fff;--antigravity:#4285f4;--opencode:#7dd3fc}*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;background:radial-gradient(circle at 12% -4%,#213b54 0,transparent 32%),radial-gradient(circle at 90% 12%,#1b3144 0,transparent 25%),var(--bg);color:var(--text);font:14px/1.45 Inter,Segoe UI,system-ui,sans-serif}main{max-width:1540px;margin:auto;padding:32px 22px 80px}.eyebrow{color:var(--blue);font-size:11px;font-weight:800;letter-spacing:.14em;text-transform:uppercase}h1{font-size:34px;line-height:1.1;margin:7px 0}.intro{max-width:950px;color:var(--muted);font-size:15px}.topline{display:flex;align-items:flex-start;justify-content:space-between;gap:20px}.nav{display:flex;gap:8px;flex-wrap:wrap}.nav a{color:#cce2f5;text-decoration:none;border:1px solid var(--line);background:#101a24;border-radius:9px;padding:8px 11px}.summary{display:grid;grid-template-columns:repeat(7,minmax(105px,1fr));gap:9px;margin:22px 0}.metric,.panel,.agent-stat,.model-card,.shared-path,.flow-card,.session-card{background:rgba(18,28,38,.94);border:1px solid var(--line);border-radius:13px}.metric{padding:14px}.metric b{font-size:23px;display:block}.metric span{color:var(--muted);font-size:11px}.privacy{display:flex;gap:10px;align-items:flex-start;background:#10251e;border:1px solid #255d46;padding:12px 14px;border-radius:11px;color:#b9e7d1}.privacy b{color:#79dfa9}.agent-grid{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin:16px 0}.agent-stat{color:var(--text);padding:14px;text-align:left;cursor:pointer;display:grid;grid-template-columns:auto 1fr auto;gap:8px;align-items:center}.agent-stat strong{font-size:22px}.agent-stat small{grid-column:2/4;color:var(--muted)}.agent-stat[aria-pressed=true]{box-shadow:inset 0 0 0 2px var(--blue);background:#17283a}.brand-mark{display:inline-block;width:12px;height:12px;border-radius:50%;background:var(--muted);flex:0 0 auto}.claude .brand-mark,.mini-agent.claude .brand-mark{background:var(--claude)}.codex .brand-mark,.mini-agent.codex .brand-mark{background:var(--codex)}.antigravity .brand-mark,.mini-agent.antigravity .brand-mark{background:var(--antigravity)}.opencode .brand-mark,.mini-agent.opencode .brand-mark{background:var(--opencode)}.panel{padding:17px;margin:16px 0}.panel h2{margin:0 0 4px;font-size:19px}.panel-sub{color:var(--muted);margin:0 0 14px}.two-col{display:grid;grid-template-columns:1.1fr .9fr;gap:16px}.model-grid,.shared-grid,.flow-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:8px}.model-card{display:grid;grid-template-columns:auto 1fr auto;gap:7px;align-items:center;padding:11px}.model-card div small,.model-card>small{display:block;color:var(--muted);font-size:10px}.model-card>small{grid-column:2/4}.shared-path{padding:11px;min-width:0}.shared-path b,.shared-path small{display:block;overflow-wrap:anywhere}.shared-path small{color:var(--muted);margin-top:3px}.shared-head{display:flex;align-items:center;gap:5px;margin-bottom:7px}.shared-head>span:last-child{margin-left:auto;color:var(--muted);font-size:10px}.mini-agent,.agent-tag{display:inline-flex;align-items:center;gap:4px;border:1px solid #3b4d5e;border-radius:999px;padding:3px 7px;font-size:10px}.mini-agent .brand-mark,.agent-tag .brand-mark{width:9px;height:9px}.flow-grid{grid-template-columns:repeat(3,minmax(0,1fr))}.flow-card{padding:10px;display:flex;align-items:center;gap:6px}.flow-card b{margin-left:auto}.flow-card small{color:var(--muted)}.arrow{color:var(--muted)}.toolbar{position:sticky;top:0;z-index:10;display:grid;grid-template-columns:minmax(260px,1fr) minmax(210px,340px) auto;gap:9px;background:rgba(10,16,22,.94);backdrop-filter:blur(9px);padding:11px 0;margin-top:20px}input,select{width:100%;border:1px solid var(--line);border-radius:10px;background:#0c141c;color:var(--text);font:inherit;padding:11px 12px}.shown{align-self:center;color:var(--muted);white-space:nowrap}.timeline{position:relative;margin-top:8px}.timeline-item{display:grid;grid-template-columns:30px 1fr;gap:10px;max-width:1200px}.timeline-rail{position:relative;display:flex;justify-content:center}.timeline-rail:after{content:"";position:absolute;top:26px;bottom:-8px;width:1px;background:var(--line)}.timeline-rail .brand-mark{margin-top:17px;z-index:1;box-shadow:0 0 0 5px var(--bg)}.session-card{padding:14px 16px;margin:7px 0;min-width:0}.session-top{display:flex;align-items:center;gap:8px}.session-top time{color:var(--muted);font-size:11px}.coverage{margin-left:auto;font-size:10px;padding:3px 7px;border-radius:999px}.coverage.ok{background:#173f30;color:#83e8b1}.coverage.warn{background:#554119;color:#ffd878}.session-card h3{font-size:17px;margin:10px 0 2px}.project-name{color:#a9c6df;font-size:12px;overflow-wrap:anywhere}.session-meta,.signals{display:flex;flex-wrap:wrap;gap:7px 14px;color:var(--muted);font-size:11px;margin-top:10px}.session-meta b{color:#c7d7e5}.signals span{padding:3px 7px;border-radius:6px;background:#101a23}.mapping.fallback,.recovery.warning{color:#ffd878;background:#4b3917}.recovery.ready{color:#80e5ad;background:#173f30}.recovery.error{color:#ffaaaa;background:#522626}.tool-line{margin-top:10px;color:#9db5ca;font-size:11px}.path-list{display:flex;gap:5px;flex-wrap:wrap;margin-top:9px;align-items:center}.path-chip{background:#162431;border:1px solid #2b4053;border-radius:6px;padding:3px 7px;font:10px Consolas,ui-monospace,monospace;overflow-wrap:anywhere}.empty,.muted{color:var(--muted)}footer{color:var(--muted);font-size:11px;margin-top:25px}@media(max-width:1100px){.summary{grid-template-columns:repeat(4,1fr)}.two-col{grid-template-columns:1fr}.flow-grid{grid-template-columns:repeat(2,1fr)}}@media(max-width:750px){main{padding:24px 12px 60px}.topline{display:block}.nav{margin-top:14px}.summary{grid-template-columns:repeat(2,1fr)}.agent-grid{grid-template-columns:repeat(2,1fr)}.model-grid,.shared-grid,.flow-grid{grid-template-columns:1fr}.toolbar{grid-template-columns:1fr;position:relative}.session-meta,.signals{display:grid}.coverage{margin-left:0}.timeline-item{grid-template-columns:22px 1fr}.session-card{padding:13px}}
:root{--cline:#9aa4ae}.cline .brand-mark,.mini-agent.cline .brand-mark{background:var(--cline)}
:root{--aider:#74e6a7}.aider .brand-mark,.mini-agent.aider .brand-mark{background:var(--aider)}
.agent-grid{grid-template-columns:repeat(6,minmax(0,1fr))}@media(max-width:1100px){.agent-grid{grid-template-columns:repeat(3,minmax(0,1fr))}}@media(max-width:750px){.agent-grid{grid-template-columns:repeat(2,minmax(0,1fr))}}
</style>
</head>
<body><main>
  <header class="topline"><div><div class="eyebrow">AgentSync Toolkit v$(Get-HtmlEncoded $Data.agentSyncVersion)</div><h1>Multi-agent intelligence</h1><p class="intro">En felles, søkbar tidslinje over prosjekt, agent, modell, verktøy og strukturerte filkoblinger. Kildehistorikken forblir separat og urørt.</p></div><nav class="nav"><a href="$(Get-HtmlEncoded $StatusLink)">Status</a><a href="$(Get-HtmlEncoded $RecoveryLink)">Recovery</a></nav></header>
  <section class="summary"><div class="metric"><b>$($Data.summary.indexedProjects)</b><span>agentoppdagede prosjekter</span></div><div class="metric"><b>$($Data.summary.sessions)</b><span>kanoniske økter</span></div><div class="metric"><b>$($Data.summary.agents)</b><span>agenter</span></div><div class="metric"><b>$($Data.summary.models)</b><span>registrerte modeller</span></div><div class="metric"><b>$($Data.summary.paths)</b><span>strukturerte prosjektstier</span></div><div class="metric"><b>$($Data.summary.sharedPaths)</b><span>stier delt av flere agenter</span></div><div class="metric"><b>$(Get-HtmlEncoded (Format-ByteSize $Data.summary.sourceBytes))</b><span>state analysert</span></div></section>
  <div class="privacy"><b>Metadata-only</b><span>Indeksen lagrer ikke rå meldinger, kode, terminalutskrifter eller kommandoer. Emner kommer bare fra eksplisitte tittelfelt, provider-metadata eller strukturerte filstier.</span></div>
  <section class="agent-grid"><button type="button" class="agent-stat all" data-agent-filter="all" aria-pressed="true"><span class="brand-mark"></span><b>Alle agenter</b><strong>$($Data.summary.sessions)</strong><small>samlet tidslinje</small></button>$AgentStats</section>
  <section class="two-col"><div class="panel"><h2>Modellkart</h2><p class="panel-sub">Eksplisitt registrerte modeller, ikke navn gjettet fra samtaletekst.</p><div class="model-grid">$ModelCards</div></div><div class="panel"><h2>Agentflyt</h2><p class="panel-sub">Når arbeidet fortsetter hos en annen agent i samme prosjekt innen 14 dager.</p><div class="flow-grid">$FlowCards</div></div></section>
  <section class="panel"><h2>Felles arbeidsspor</h2><p class="panel-sub">Prosjektstier som forekommer i strukturerte verktøydata hos minst to forskjellige agenter.</p><div class="shared-grid">$SharedCards</div></section>
  <div class="toolbar"><input id="search" type="search" placeholder="Søk i prosjekt, agent, modell, økt, verktøy eller filsti"><select id="project"><option value="all">Alle prosjekter</option>$ProjectOptions</select><span id="shown" class="shown"></span></div>
  <section><h2>Tidslinje</h2><p class="panel-sub">Nyeste aktivitet først. $HiddenByLimit eldre økter er utelatt av visningsgrensen.</p><div id="timeline" class="timeline">$Timeline</div></section>
  <footer>Generert $Generated på $([System.Net.WebUtility]::HtmlEncode([string]$Data.machine)) på $($Data.durationSeconds) sekunder · cache $($Data.cache.hits) treff / $($Data.cache.misses) nye · $($Data.summary.duplicateCopies) fallback-/duplikatkopier slått sammen · $($Data.summary.parseErrors) parseravvik. JSON-indeksen ligger ved siden av rapporten.</footer>
</main>
<script>
(function(){
  var search=document.getElementById('search'),project=document.getElementById('project'),shown=document.getElementById('shown');
  var rows=Array.from(document.querySelectorAll('.timeline-item')),buttons=Array.from(document.querySelectorAll('[data-agent-filter]')),agent='all';
  function apply(){var q=search.value.trim().toLocaleLowerCase('nb-NO'),p=project.value,n=0;rows.forEach(function(row){var okAgent=agent==='all'||row.dataset.agent===agent;var okProject=p==='all'||row.dataset.project===p;var okText=!q||row.dataset.search.toLocaleLowerCase('nb-NO').includes(q);row.hidden=!(okAgent&&okProject&&okText);if(!row.hidden)n++});shown.textContent=n+' av '+rows.length+' økter'}
  buttons.forEach(function(button){button.addEventListener('click',function(){agent=button.dataset.agentFilter;buttons.forEach(function(x){x.setAttribute('aria-pressed',String(x===button))});apply()})});
  search.addEventListener('input',apply);project.addEventListener('change',apply);apply();
})();
</script>
</body></html>
"@
}

$Json = $Audit | ConvertTo-Json -Depth 20
Write-AtomicUtf8File -Path $DataFile -Text $Json
$Html = New-IntelligenceHtml -Data ([PSCustomObject]$Audit)
Write-AtomicUtf8File -Path $OutputFile -Text $Html
# No need to delete caches after failure. After success the complete index is
# the cache again; keep a tiny valid progress record instead of stale entries.
Save-IntelligenceProgress -Path $ProgressFile -ProjectsRoot $ProjectsRoot -Records @() -Remaining 0
Write-Host "AgentSync intelligence: $($Audit.summary.sessions) sessions, $($Audit.summary.activeProjects) active projects, $($Audit.summary.sharedPaths) shared paths." -ForegroundColor Cyan
Write-Host "HTML: $OutputFile"
Write-Host "JSON: $DataFile"
Write-Host "Cache: $CacheHits hit(s), $CacheMisses parsed source group(s)." -ForegroundColor DarkGray
}
finally {
    if ($MutexAcquired) {
        try { $Mutex.ReleaseMutex() } catch { }
    }
    $Mutex.Dispose()
}
