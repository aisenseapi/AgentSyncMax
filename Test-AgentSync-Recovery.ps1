#requires -Version 7.0

[CmdletBinding()]
param (
    [string]$ConfigFile,
    [string]$ReportFile = (Join-Path $PSScriptRoot 'AgentSync-Recovery.html'),
    [string]$JsonFile = (Join-Path $PSScriptRoot 'AgentSync-Recovery.json'),
    [switch]$Deep,
    [switch]$SkipRuntimeVersionCheck
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AgentSync.Process.ps1')

function Get-CurrentPlatformName {
    if ($IsWindows) { return 'windows' }
    if ($IsMacOS) { return 'macos' }
    return 'linux'
}

function Expand-AgentSyncPath {
    param ([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    $HomePath = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    if ([string]::IsNullOrWhiteSpace($HomePath)) {
        $HomePath = $env:USERPROFILE
    }
    if ([string]::IsNullOrWhiteSpace($HomePath)) {
        $HomePath = $env:HOME
    }

    $Expanded = $Path
    if ($Expanded -eq '~') {
        $Expanded = $HomePath
    }
    elseif ($Expanded.StartsWith('~/') -or $Expanded.StartsWith('~\')) {
        $Expanded = Join-Path $HomePath $Expanded.Substring(2)
    }

    if (-not [string]::IsNullOrWhiteSpace($HomePath)) {
        $Expanded = $Expanded.Replace('${HOME}', $HomePath).Replace('$HOME', $HomePath)
        $Expanded = $Expanded.Replace('%USERPROFILE%', $HomePath)
    }
    $Expanded = [System.Environment]::ExpandEnvironmentVariables($Expanded)

    try {
        return [System.IO.Path]::GetFullPath($Expanded).TrimEnd('\', '/')
    }
    catch {
        return $Expanded
    }
}

function Get-ObjectPropertyValue {
    param (
        $Object,
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }
    if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) {
        return $Object[$Name]
    }
    $Property = $Object.PSObject.Properties[$Name]
    if ($Property) {
        return $Property.Value
    }
    return $null
}

function Get-PlatformConfiguredPath {
    param ($Object)

    $Platform = Get-CurrentPlatformName
    $PropertyName = switch ($Platform) {
        'windows' { 'localPathWindows' }
        'macos' { 'localPathMacOS' }
        default { 'localPathLinux' }
    }
    $Candidate = [string](Get-ObjectPropertyValue -Object $Object -Name $PropertyName)
    if ([string]::IsNullOrWhiteSpace($Candidate)) {
        $Candidate = [string](Get-ObjectPropertyValue -Object $Object -Name 'localPath')
    }
    return Expand-AgentSyncPath -Path $Candidate
}

function Resolve-ConfiguredCommand {
    param ([string]$Command)

    if ([string]::IsNullOrWhiteSpace($Command)) { return $null }
    if ([System.IO.Path]::IsPathRooted($Command) -or $Command.StartsWith('~') -or $Command -match '[\\/]') {
        return Expand-AgentSyncPath -Path $Command
    }
    return $Command
}

function Test-PathInside {
    param (
        [string]$ChildPath,
        [string]$ParentPath
    )

    try {
        $Child = [System.IO.Path]::GetFullPath($ChildPath).TrimEnd('\', '/')
        $Parent = [System.IO.Path]::GetFullPath($ParentPath).TrimEnd('\', '/')
        if ($Child.Equals($Parent, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
        $Prefix = $Parent + [System.IO.Path]::DirectorySeparatorChar
        return $Child.StartsWith($Prefix, [System.StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        return $false
    }
}

function Test-SafeSessionId {
    param ([string]$Id)
    return -not [string]::IsNullOrWhiteSpace($Id) -and $Id -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
}

function New-Finding {
    param (
        [ValidateSet('info', 'warning', 'error')]
        [string]$Severity,
        [string]$Code,
        [string]$Message
    )

    return [PSCustomObject]@{
        severity = $Severity
        code = $Code
        message = $Message
    }
}

function Get-WorstStatus {
    param ([object[]]$Findings)

    if (@($Findings | Where-Object severity -eq 'error').Count -gt 0) {
        return 'error'
    }
    if (@($Findings | Where-Object severity -eq 'warning').Count -gt 0) {
        return 'warning'
    }
    return 'ready'
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

function Write-AtomicUtf8File {
    param (
        [string]$Path,
        [string]$Text
    )

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
        if (Test-Path -LiteralPath $Temporary) {
            Remove-Item -LiteralPath $Temporary -Force
        }
    }
}

function Assert-SafeReportDestination {
    param (
        [string]$Path,
        $Config,
        [string]$IndexDirectory,
        [string]$ConfigFile
    )

    $Resolved = [System.IO.Path]::GetFullPath($Path)
    $Segments = @($Resolved -split '[\\/]')
    if (@($Segments | Where-Object { $_.Equals('.agent-state', [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
        throw "Recovery reports cannot be written inside .agent-state: $Resolved"
    }
    if (Test-PathInside -ChildPath $Resolved -ParentPath $IndexDirectory) {
        throw "Recovery reports cannot be written inside project-index: $Resolved"
    }
    if ($Resolved.Equals([System.IO.Path]::GetFullPath($ConfigFile), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Recovery report path cannot overwrite the active config file: $Resolved"
    }

    foreach ($Agent in @($Config.agents | Where-Object { $_.enabled -ne $false })) {
        $Roots = [System.Collections.Generic.List[string]]::new()
        $LocalPath = Get-PlatformConfiguredPath -Object $Agent
        if ($LocalPath) { $Roots.Add($LocalPath) }
        foreach ($RootConfig in @($Agent.roots)) {
            $RootPath = Get-PlatformConfiguredPath -Object $RootConfig
            if ($RootPath) { $Roots.Add($RootPath) }
        }
        foreach ($Root in $Roots) {
            if (Test-PathInside -ChildPath $Resolved -ParentPath $Root) {
                throw "Recovery reports cannot be written inside a local agent root: $Resolved"
            }
        }
    }
    return $Resolved
}

function Get-SharedReadStream {
    param ([string]$Path)
    return [System.IO.FileStream]::new(
        $Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite)
}

function Get-JsonlMetadata {
    param (
        [string]$Path,
        [int]$MaxLines = 100
    )

    $Reader = $null
    $FirstObject = $null
    $MetadataPath = $null
    $ValidObjects = 0
    try {
        $Reader = [System.IO.StreamReader]::new((Get-SharedReadStream -Path $Path), [System.Text.Encoding]::UTF8, $true, 65536)
        $LineNumber = 0
        while (-not $Reader.EndOfStream -and $LineNumber -lt $MaxLines) {
            $Line = $Reader.ReadLine()
            $LineNumber++
            if ([string]::IsNullOrWhiteSpace($Line)) { continue }
            try {
                $Object = $Line | ConvertFrom-Json -AsHashtable
                $ValidObjects++
                if ($null -eq $FirstObject) { $FirstObject = $Object }
                foreach ($Candidate in @(
                    (Get-ObjectPropertyValue -Object $Object -Name 'cwd'),
                    (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $Object -Name 'payload') -Name 'cwd'),
                    (Get-ObjectPropertyValue -Object $Object -Name 'projectPath'),
                    (Get-ObjectPropertyValue -Object $Object -Name 'workspacePath'),
                    (Get-ObjectPropertyValue -Object $Object -Name 'workspaceFolder')
                )) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$Candidate)) {
                        $MetadataPath = [string]$Candidate
                        break
                    }
                }
                if ($MetadataPath) { break }
            }
            catch {
            }
        }
    }
    finally {
        if ($Reader) { $Reader.Dispose() }
    }

    return [PSCustomObject]@{
        firstObject = $FirstObject
        metadataPath = $MetadataPath
        validObjects = $ValidObjects
    }
}

function Get-LastJsonlLine {
    param ([string]$Path)

    $Stream = $null
    try {
        $Stream = Get-SharedReadStream -Path $Path
        if ($Stream.Length -eq 0) { return $null }

        $ReadLength = [Math]::Min([long]65536, $Stream.Length)
        $Maximum = [Math]::Min([long](8MB), $Stream.Length)
        while ($true) {
            [void]$Stream.Seek(-$ReadLength, [System.IO.SeekOrigin]::End)
            $Buffer = [byte[]]::new([int]$ReadLength)
            $Read = $Stream.Read($Buffer, 0, $Buffer.Length)
            $Text = [System.Text.Encoding]::UTF8.GetString($Buffer, 0, $Read)
            if ($ReadLength -lt $Stream.Length) {
                $FirstBreak = $Text.IndexOf("`n")
                if ($FirstBreak -ge 0) {
                    $Text = $Text.Substring($FirstBreak + 1)
                }
                else {
                    $Text = ''
                }
            }
            $Lines = @($Text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($Lines.Count -gt 0) {
                return [string]$Lines[-1]
            }
            if ($ReadLength -ge $Maximum) {
                return $null
            }
            $ReadLength = [Math]::Min($ReadLength * 2, $Maximum)
        }
    }
    finally {
        if ($Stream) { $Stream.Dispose() }
    }
}

function Test-JsonlFile {
    param (
        [System.IO.FileInfo]$File,
        [switch]$ValidateEveryLine
    )

    $Findings = [System.Collections.Generic.List[object]]::new()
    $Metadata = $null
    $LineCount = 0L
    try {
        if ($File.Length -eq 0) {
            $Findings.Add((New-Finding -Severity error -Code 'JSONL_EMPTY' -Message 'JSONL-filen er tom.'))
            return [PSCustomObject]@{ findings = $Findings.ToArray(); metadataPath = $null; lines = 0L }
        }

        $Metadata = Get-JsonlMetadata -Path $File.FullName -MaxLines $Script:MetadataReadLines
        if ($Metadata.validObjects -eq 0) {
            $Findings.Add((New-Finding -Severity error -Code 'JSONL_HEAD_INVALID' -Message 'Ingen gyldig JSON-post ble funnet i starten av filen.'))
        }

        if ($ValidateEveryLine) {
            $Reader = $null
            try {
                $Reader = [System.IO.StreamReader]::new((Get-SharedReadStream -Path $File.FullName), [System.Text.Encoding]::UTF8, $true, 65536)
                while (-not $Reader.EndOfStream) {
                    $Line = $Reader.ReadLine()
                    if ([string]::IsNullOrWhiteSpace($Line)) { continue }
                    $LineCount++
                    # -AsHashtable accepts every valid JSON property name,
                    # including an empty string. PSCustomObject conversion does
                    # not, and previously produced false corruption findings.
                    try { $null = $Line | ConvertFrom-Json -AsHashtable }
                    catch {
                        $Findings.Add((New-Finding -Severity error -Code 'JSONL_LINE_INVALID' -Message "Ugyldig JSON på linje $LineCount."))
                        break
                    }
                }
            }
            finally {
                if ($Reader) { $Reader.Dispose() }
            }
        }
        else {
            $LastLine = Get-LastJsonlLine -Path $File.FullName
            if ([string]::IsNullOrWhiteSpace($LastLine)) {
                $Findings.Add((New-Finding -Severity warning -Code 'JSONL_TAIL_UNVERIFIED' -Message 'Siste post kunne ikke avgrenses innen 8 MB.'))
            }
            else {
                try { $null = $LastLine | ConvertFrom-Json -AsHashtable }
                catch { $Findings.Add((New-Finding -Severity error -Code 'JSONL_TAIL_INVALID' -Message 'Siste JSONL-post er ufullstendig eller ugyldig.')) }
            }
        }
    }
    catch {
        $Findings.Add((New-Finding -Severity error -Code 'FILE_UNREADABLE' -Message "Filen kunne ikke leses: $($_.Exception.Message)"))
    }

    return [PSCustomObject]@{
        findings = $Findings.ToArray()
        metadataPath = if ($Metadata) { $Metadata.metadataPath } else { $null }
        lines = $LineCount
    }
}

function Test-AntigravityJsonlChunkFile {
    param ([System.IO.FileInfo]$File)

    if ($null -eq $File -or $File.Name -notmatch '^\d{8}\.jsonl$') {
        return $false
    }
    $NormalizedDirectory = $File.DirectoryName -replace '\\', '/'
    return $NormalizedDirectory -match '(?i)/brain/\.system_generated/logs/chunks/(?:transcript|transcript_full)$'
}

function Test-JsonlChunkSet {
    param (
        [System.IO.FileInfo[]]$Files,
        [switch]$ValidateEveryLine
    )

    $Findings = [System.Collections.Generic.List[object]]::new()
    $OrderedFiles = @($Files | Sort-Object Name)
    if ($OrderedFiles.Count -eq 0) {
        $Findings.Add((New-Finding -Severity error -Code 'JSONL_CHUNK_SET_EMPTY' -Message 'Fragmentsettet inneholder ingen filer.'))
        return [PSCustomObject]@{ findings = $Findings.ToArray(); lines = 0L }
    }

    for ($Index = 0; $Index -lt $OrderedFiles.Count; $Index++) {
        $ExpectedName = '{0:D8}.jsonl' -f $Index
        if (-not $OrderedFiles[$Index].Name.Equals($ExpectedName, [System.StringComparison]::OrdinalIgnoreCase)) {
            $Findings.Add((New-Finding -Severity error -Code 'JSONL_CHUNK_SEQUENCE_INVALID' -Message "Forventet $ExpectedName, fant $($OrderedFiles[$Index].Name)."))
            break
        }
    }

    $Combined = [System.IO.MemoryStream]::new()
    $Reader = $null
    try {
        foreach ($File in $OrderedFiles) {
            $Source = $null
            try {
                $Source = Get-SharedReadStream -Path $File.FullName
                $Source.CopyTo($Combined)
            }
            catch {
                $Findings.Add((New-Finding -Severity error -Code 'JSONL_CHUNK_UNREADABLE' -Message "$($File.Name) kunne ikke leses: $($_.Exception.Message)"))
                return [PSCustomObject]@{ findings = $Findings.ToArray(); lines = 0L }
            }
            finally {
                if ($Source) { $Source.Dispose() }
            }
        }

        if ($Combined.Length -eq 0) {
            $Findings.Add((New-Finding -Severity error -Code 'JSONL_CHUNK_SET_EMPTY' -Message 'Det sammenhengende fragmentsettet er tomt.'))
            return [PSCustomObject]@{ findings = $Findings.ToArray(); lines = 0L }
        }

        $Combined.Position = 0
        $Reader = [System.IO.StreamReader]::new($Combined, [System.Text.Encoding]::UTF8, $true, 65536, $true)
        $FirstLine = $null
        $LastLine = $null
        $LineCount = 0L
        while (-not $Reader.EndOfStream) {
            $Line = $Reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($Line)) { continue }
            $LineCount++
            if ($null -eq $FirstLine) { $FirstLine = $Line }
            $LastLine = $Line
            if ($ValidateEveryLine) {
                try { $null = $Line | ConvertFrom-Json -AsHashtable }
                catch {
                    $Findings.Add((New-Finding -Severity error -Code 'JSONL_CHUNK_LINE_INVALID' -Message "Ugyldig JSON på logisk linje $LineCount etter sammensetting av fragmentene."))
                    break
                }
            }
        }

        if ($LineCount -eq 0) {
            $Findings.Add((New-Finding -Severity error -Code 'JSONL_CHUNK_SET_EMPTY' -Message 'Ingen JSONL-poster ble funnet etter sammensetting av fragmentene.'))
        }
        elseif (-not $ValidateEveryLine) {
            try { $null = $FirstLine | ConvertFrom-Json -AsHashtable }
            catch { $Findings.Add((New-Finding -Severity error -Code 'JSONL_CHUNK_HEAD_INVALID' -Message 'Første logiske JSONL-post er ugyldig etter sammensetting av fragmentene.')) }
            if ($LineCount -gt 1) {
                try { $null = $LastLine | ConvertFrom-Json -AsHashtable }
                catch { $Findings.Add((New-Finding -Severity error -Code 'JSONL_CHUNK_TAIL_INVALID' -Message 'Siste logiske JSONL-post er ugyldig etter sammensetting av fragmentene.')) }
            }
        }
        return [PSCustomObject]@{ findings = $Findings.ToArray(); lines = $LineCount }
    }
    finally {
        if ($Reader) { $Reader.Dispose() }
        $Combined.Dispose()
    }
}

function Test-SqliteFile {
    param ([System.IO.FileInfo]$File)

    $Findings = [System.Collections.Generic.List[object]]::new()
    $Stream = $null
    try {
        if ($File.Length -lt 100) {
            $Findings.Add((New-Finding -Severity error -Code 'SQLITE_TOO_SMALL' -Message 'SQLite-filen er for liten til å være en gyldig database.'))
        }
        else {
            $Stream = Get-SharedReadStream -Path $File.FullName
            $Header = [byte[]]::new(16)
            if ($Stream.Read($Header, 0, 16) -ne 16 -or [System.Text.Encoding]::ASCII.GetString($Header) -ne "SQLite format 3`0") {
                $Findings.Add((New-Finding -Severity error -Code 'SQLITE_HEADER_INVALID' -Message 'SQLite-signaturen er ugyldig.'))
            }
        }
    }
    catch {
        $Findings.Add((New-Finding -Severity error -Code 'FILE_UNREADABLE' -Message "Databasen kunne ikke leses: $($_.Exception.Message)"))
    }
    finally {
        if ($Stream) { $Stream.Dispose() }
    }
    return $Findings.ToArray()
}

function Get-ProjectMappingKind {
    param (
        [string]$MetadataPath,
        [string]$ProjectRelative,
        [string]$ProjectPath
    )

    if ([string]::IsNullOrWhiteSpace($MetadataPath)) { return 'unknown' }
    $Normalized = $MetadataPath -replace '^file:///?', '' -replace '\\', '/'
    try { $Normalized = [System.Uri]::UnescapeDataString($Normalized) } catch { }
    $Normalized = $Normalized.TrimEnd('/')
    $Normalized = [regex]::Replace($Normalized, '(?i)/\.claude/worktrees/[^/]+(?:/.*)?$', '')
    $Current = ($ProjectPath -replace '\\', '/').TrimEnd('/')
    if ($Normalized.Equals($Current, [System.StringComparison]::OrdinalIgnoreCase)) { return 'exact' }
    $Relative = ($ProjectRelative -replace '\\', '/').Trim('/')
    if ($Normalized.EndsWith('/' + $Relative, [System.StringComparison]::OrdinalIgnoreCase)) { return 'portable' }
    return 'fallback'
}

function New-AgentResult {
    param (
        [string]$Name,
        [string]$Target
    )

    return [PSCustomObject]@{
        name = $Name
        status = 'absent'
        sessions = 0
        files = 0
        bytes = 0L
        newestUtc = $null
        target = $Target
        mapping = [ordered]@{ exact = 0; portable = 0; fallback = 0; unknown = 0 }
        integrityHash = $null
        findings = [System.Collections.Generic.List[object]]::new()
        inventory = [System.Collections.Generic.List[string]]::new()
    }
}

function Add-AgentFiles {
    param (
        $Result,
        [System.IO.FileInfo[]]$Files,
        [string]$BasePath
    )

    foreach ($File in @($Files)) {
        $Result.files++
        $Result.bytes += $File.Length
        if ($null -eq $Result.newestUtc -or $File.LastWriteTimeUtc -gt [datetime]$Result.newestUtc) {
            $Result.newestUtc = $File.LastWriteTimeUtc.ToString('o')
        }
        if ($Deep) {
            try {
                $Relative = [System.IO.Path]::GetRelativePath($BasePath, $File.FullName).Replace('\', '/')
                $Hash = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash
                $Result.inventory.Add("$Relative|$($File.Length)|$Hash")
            }
            catch {
                $Result.findings.Add((New-Finding -Severity error -Code 'HASH_FAILED' -Message "SHA-256 kunne ikke beregnes for $($File.Name)."))
            }
        }
    }
}

function Complete-AgentResult {
    param ($Result)

    if ($Result.files -eq 0) {
        $Result.status = if ($Result.findings.Count -gt 0) { Get-WorstStatus -Findings $Result.findings } else { 'absent' }
        return $Result
    }
    if ($Deep -and $Result.inventory.Count -gt 0) {
        $Text = ($Result.inventory | Sort-Object) -join "`n"
        $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $Result.integrityHash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($Bytes))
    }
    $Result.inventory.Clear()
    $Result.status = Get-WorstStatus -Findings $Result.findings
    return $Result
}

function Get-AgentConfig {
    param ([string]$RoutingMode)
    return @($Script:Config.agents | Where-Object { $_.enabled -ne $false -and ([string]$_.routingMode).Equals($RoutingMode, [System.StringComparison]::OrdinalIgnoreCase) })
}

function Test-ClaudeState {
    param (
        [string]$ProjectPath,
        [string]$ProjectRelative,
        $Agent
    )

    $LocalRoot = Get-PlatformConfiguredPath -Object $Agent
    $Result = New-AgentResult -Name 'claude' -Target "$LocalRoot (bucket bygges fra sesjonens cwd)"
    $Root = Join-Path $ProjectPath ([string]$Agent.targetSubDir)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $Result }

    $Files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
        $_.Extension -eq '.jsonl' -or ($_.Extension -eq '.md' -and $_.Directory.Name -eq 'memory')
    })
    Add-AgentFiles -Result $Result -Files $Files -BasePath $Root
    $SessionIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Bucket in @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)) {
        $SessionFiles = @(Get-ChildItem -LiteralPath $Bucket.FullName -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue)
        $Checks = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $ParentCwds = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $DefaultCwd = $null

        foreach ($File in $SessionFiles) {
            $Check = Test-JsonlFile -File $File -ValidateEveryLine:$Deep
            $Checks[$File.FullName] = $Check
            foreach ($Finding in @($Check.findings)) {
                $Result.findings.Add((New-Finding -Severity $Finding.severity -Code $Finding.code -Message "$($File.Name): $($Finding.message)"))
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$Check.metadataPath)) {
                $Relative = [System.IO.Path]::GetRelativePath($Bucket.FullName, $File.FullName)
                if ($Relative -notmatch '[\\/]') {
                    $ParentCwds[[System.IO.Path]::GetFileNameWithoutExtension($Relative)] = [string]$Check.metadataPath
                }
                if ([string]::IsNullOrWhiteSpace($DefaultCwd)) {
                    $DefaultCwd = [string]$Check.metadataPath
                }
            }
        }

        foreach ($File in $SessionFiles) {
            $Relative = [System.IO.Path]::GetRelativePath($Bucket.FullName, $File.FullName)
            $FirstSegment = @($Relative -split '[\\/]')[0]
            [void]$SessionIds.Add([System.IO.Path]::GetFileNameWithoutExtension($FirstSegment))
            $MetadataPath = [string]$Checks[$File.FullName].metadataPath
            if ([string]::IsNullOrWhiteSpace($MetadataPath) -and $ParentCwds.ContainsKey($FirstSegment)) {
                $MetadataPath = [string]$ParentCwds[$FirstSegment]
            }
            if ([string]::IsNullOrWhiteSpace($MetadataPath)) {
                $MetadataPath = $DefaultCwd
            }
            $Kind = Get-ProjectMappingKind -MetadataPath $MetadataPath -ProjectRelative $ProjectRelative -ProjectPath $ProjectPath
            $Result.mapping[$Kind]++
        }
    }
    $Result.sessions = $SessionIds.Count
    if ($Result.mapping.fallback -gt 0) {
        $Result.findings.Add((New-Finding -Severity warning -Code 'CLAUDE_FALLBACK_STATE' -Message "$($Result.mapping.fallback) fil(er) peker mot en annen prosjektidentitet og beholdes som fallback."))
    }
    if ($Result.mapping.unknown -gt 0) {
        $Result.findings.Add((New-Finding -Severity warning -Code 'CLAUDE_CWD_UNKNOWN' -Message "$($Result.mapping.unknown) fil(er) mangler lesbar cwd i de første $Script:MetadataReadLines postene."))
    }
    return Complete-AgentResult -Result $Result
}

function Test-CodexState {
    param (
        [string]$ProjectPath,
        [string]$ProjectRelative,
        [object[]]$Agents
    )

    $Targets = @($Agents | ForEach-Object { Get-PlatformConfiguredPath -Object $_ } | Where-Object { $_ })
    $Result = New-AgentResult -Name 'codex' -Target ($Targets -join ' + ')
    $SeenPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Agent in $Agents) {
        $Root = Join-Path $ProjectPath ([string]$Agent.targetSubDir)
        if (-not (Test-Path -LiteralPath $Root -PathType Container)) { continue }
        $Files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue | Where-Object { $SeenPaths.Add($_.FullName) })
        Add-AgentFiles -Result $Result -Files $Files -BasePath (Join-Path $ProjectPath '.agent-state/codex')
        $Result.sessions += $Files.Count
        foreach ($File in $Files) {
            $Check = Test-JsonlFile -File $File -ValidateEveryLine:$Deep
            foreach ($Finding in @($Check.findings)) {
                $Result.findings.Add((New-Finding -Severity $Finding.severity -Code $Finding.code -Message "$($File.Name): $($Finding.message)"))
            }
            $Kind = Get-ProjectMappingKind -MetadataPath $Check.metadataPath -ProjectRelative $ProjectRelative -ProjectPath $ProjectPath
            $Result.mapping[$Kind]++
        }
    }
    if ($Result.mapping.fallback -gt 0) {
        $Result.findings.Add((New-Finding -Severity warning -Code 'CODEX_FALLBACK_STATE' -Message "$($Result.mapping.fallback) fil(er) peker mot en annen prosjektidentitet og beholdes som fallback."))
    }
    if ($Result.mapping.unknown -gt 0) {
        $Result.findings.Add((New-Finding -Severity warning -Code 'CODEX_CWD_UNKNOWN' -Message "$($Result.mapping.unknown) fil(er) mangler lesbar cwd i de første $Script:MetadataReadLines postene."))
    }
    return Complete-AgentResult -Result $Result
}

function Test-AntigravityState {
    param (
        [string]$ProjectPath,
        [string]$ProjectRelative,
        $Agent
    )

    $Targets = @($Agent.roots | ForEach-Object { "$(Get-PlatformConfiguredPath -Object $_) [$([string]$_.surface)]" })
    $Result = New-AgentResult -Name 'antigravity' -Target ($Targets -join ' + ')
    $Root = Join-Path $ProjectPath ([string]$Agent.targetSubDir)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $Result }

    $Files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue)
    Add-AgentFiles -Result $Result -Files $Files -BasePath $Root
    foreach ($Surface in @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)) {
        $SessionRoot = Join-Path $Surface.FullName 'sessions'
        if (-not (Test-Path -LiteralPath $SessionRoot -PathType Container)) { continue }
        foreach ($Session in @(Get-ChildItem -LiteralPath $SessionRoot -Directory -ErrorAction SilentlyContinue)) {
            $Result.sessions++
            if (-not (Test-SafeSessionId -Id $Session.Name)) {
                $Result.findings.Add((New-Finding -Severity error -Code 'ANTIGRAVITY_ID_UNSAFE' -Message "Ugyldig conversation-ID i $($Surface.Name)."))
                continue
            }

            $NativeFiles = @(Get-ChildItem -LiteralPath $Session.FullName -Recurse -File -ErrorAction SilentlyContinue)
            if ($NativeFiles.Count -eq 0) {
                $Result.findings.Add((New-Finding -Severity error -Code 'ANTIGRAVITY_SESSION_EMPTY' -Message "$($Surface.Name)/$($Session.Name) mangler native filer."))
            }
            foreach ($Database in @($NativeFiles | Where-Object Extension -eq '.db')) {
                foreach ($Finding in @(Test-SqliteFile -File $Database)) {
                    $Result.findings.Add((New-Finding -Severity $Finding.severity -Code $Finding.code -Message "$($Database.Name): $($Finding.message)"))
                }
            }
            $JsonlFiles = @($NativeFiles | Where-Object Extension -eq '.jsonl')
            $ChunkFiles = @($JsonlFiles | Where-Object { Test-AntigravityJsonlChunkFile -File $_ })
            foreach ($Jsonl in @($JsonlFiles | Where-Object { -not (Test-AntigravityJsonlChunkFile -File $_) })) {
                $Check = Test-JsonlFile -File $Jsonl -ValidateEveryLine:$Deep
                foreach ($Finding in @($Check.findings)) {
                    $Result.findings.Add((New-Finding -Severity $Finding.severity -Code $Finding.code -Message "$($Jsonl.Name): $($Finding.message)"))
                }
            }
            foreach ($ChunkSet in @($ChunkFiles | Group-Object DirectoryName)) {
                $Check = Test-JsonlChunkSet -Files @($ChunkSet.Group) -ValidateEveryLine:$Deep
                $ChunkLabel = [System.IO.Path]::GetRelativePath($Session.FullName, [string]$ChunkSet.Name).Replace('\', '/')
                foreach ($Finding in @($Check.findings)) {
                    $Result.findings.Add((New-Finding -Severity $Finding.severity -Code $Finding.code -Message "${ChunkLabel}: $($Finding.message)"))
                }
            }

            $IndexPath = Join-Path $ProjectPath ".agent-state/index/antigravity-workspaces/$($Surface.Name)/$($Session.Name).json"
            if (-not (Test-Path -LiteralPath $IndexPath -PathType Leaf)) {
                $Result.mapping.unknown++
                $Result.findings.Add((New-Finding -Severity warning -Code 'ANTIGRAVITY_WORKSPACE_INDEX_MISSING' -Message "$($Surface.Name)/$($Session.Name) mangler avledet workspace-indeks."))
            }
            else {
                try {
                    $Index = Get-Content -LiteralPath $IndexPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ([string]$Index.conversationId -ne $Session.Name -or [string]$Index.surface -ne $Surface.Name) {
                        $Result.findings.Add((New-Finding -Severity error -Code 'ANTIGRAVITY_WORKSPACE_INDEX_MISMATCH' -Message "$($Surface.Name)/$($Session.Name) har feil ID eller surface i workspace-indeksen."))
                    }
                    $Kind = Get-ProjectMappingKind -MetadataPath ([string]$Index.workspace) -ProjectRelative $ProjectRelative -ProjectPath $ProjectPath
                    $Result.mapping[$Kind]++
                }
                catch {
                    $Result.mapping.unknown++
                    $Result.findings.Add((New-Finding -Severity error -Code 'ANTIGRAVITY_WORKSPACE_INDEX_INVALID' -Message "$($Surface.Name)/$($Session.Name) har ugyldig workspace-indeks."))
                }
            }
        }
    }
    if ($Result.mapping.fallback -gt 0) {
        $Result.findings.Add((New-Finding -Severity warning -Code 'ANTIGRAVITY_FALLBACK_STATE' -Message "$($Result.mapping.fallback) samtale(r) peker mot en annen prosjektidentitet og beholdes som fallback."))
    }
    if ($Result.files -gt 0 -and $Result.sessions -eq 0) {
        $Result.findings.Add((New-Finding -Severity error -Code 'ANTIGRAVITY_LAYOUT_INVALID' -Message 'Antigravity-state finnes, men ingen native session-mappe kunne identifiseres.'))
    }
    return Complete-AgentResult -Result $Result
}

function Test-OpenCodeState {
    param (
        [string]$ProjectPath,
        [string]$ProjectRelative,
        $Agent
    )

    $CommandSetting = if ($IsWindows -and (Get-ObjectPropertyValue -Object $Agent -Name 'commandWindows')) {
        [string](Get-ObjectPropertyValue -Object $Agent -Name 'commandWindows')
    }
    else {
        [string](Get-ObjectPropertyValue -Object $Agent -Name 'command')
    }
    $CommandPath = Resolve-ConfiguredCommand -Command $CommandSetting
    $Result = New-AgentResult -Name 'opencode' -Target "$CommandPath import <export> i den lokale prosjektmappen"
    $Root = Join-Path $ProjectPath ([string]$Agent.targetSubDir)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $Result }

    $Files = @(Get-ChildItem -LiteralPath $Root -File -Filter '*.json' -ErrorAction SilentlyContinue)
    Add-AgentFiles -Result $Result -Files $Files -BasePath $Root
    foreach ($File in $Files) {
        try {
            $Export = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $Info = Get-ObjectPropertyValue -Object $Export -Name 'info'
            $MessagesProperty = $Export.PSObject.Properties['messages']
            $Id = [string](Get-ObjectPropertyValue -Object $Info -Name 'id')
            $Directory = [string](Get-ObjectPropertyValue -Object $Info -Name 'directory')
            if (-not $Info -or -not (Test-SafeSessionId -Id $Id)) {
                $Result.findings.Add((New-Finding -Severity error -Code 'OPENCODE_EXPORT_ID_INVALID' -Message "$($File.Name) mangler en trygg session-ID."))
                continue
            }
            $Result.sessions++
            if ([System.IO.Path]::GetFileNameWithoutExtension($File.Name) -ne $Id) {
                $Result.findings.Add((New-Finding -Severity error -Code 'OPENCODE_EXPORT_NAME_MISMATCH' -Message "$($File.Name) samsvarer ikke med session-ID-en i eksporten."))
            }
            if ([string]::IsNullOrWhiteSpace($Directory)) {
                $Result.mapping.unknown++
                $Result.findings.Add((New-Finding -Severity error -Code 'OPENCODE_DIRECTORY_MISSING' -Message "$($File.Name) mangler prosjektets directory."))
            }
            else {
                $Kind = Get-ProjectMappingKind -MetadataPath $Directory -ProjectRelative $ProjectRelative -ProjectPath $ProjectPath
                $Result.mapping[$Kind]++
            }
            if (-not $MessagesProperty) {
                $Result.findings.Add((New-Finding -Severity error -Code 'OPENCODE_MESSAGES_MISSING' -Message "$($File.Name) mangler messages-feltet fra den native eksporten."))
            }
        }
        catch {
            $Result.findings.Add((New-Finding -Severity error -Code 'OPENCODE_EXPORT_INVALID' -Message "$($File.Name) er ikke en gyldig OpenCode-eksport."))
        }
    }
    if ($Result.mapping.fallback -gt 0) {
        $Result.findings.Add((New-Finding -Severity warning -Code 'OPENCODE_FALLBACK_STATE' -Message "$($Result.mapping.fallback) eksport(er) peker mot en annen prosjektidentitet og beholdes som fallback."))
    }
    return Complete-AgentResult -Result $Result
}

function Test-ClineState {
    param (
        [string]$ProjectPath,
        [string]$ProjectRelative,
        $Agent
    )

    $Targets = @($Agent.roots | ForEach-Object { "$(Get-PlatformConfiguredPath -Object $_) [$([string]$_.surface)]" })
    $Result = New-AgentResult -Name 'cline' -Target ($Targets -join ' + ')
    $Root = Join-Path $ProjectPath ([string]$Agent.targetSubDir)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $Result }

    $AllFiles = @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue)
    Add-AgentFiles -Result $Result -Files $AllFiles -BasePath $Root
    foreach ($Surface in @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)) {
        $RootConfig = @($Agent.roots | Where-Object { ([string]$_.surface).Equals($Surface.Name, [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1)
        $Format = if ($RootConfig.Count -gt 0) { [string]$RootConfig[0].format } else { '' }
        $SessionsRoot = Join-Path $Surface.FullName 'sessions'
        if (-not (Test-Path -LiteralPath $SessionsRoot -PathType Container)) { continue }
        foreach ($Session in @(Get-ChildItem -LiteralPath $SessionsRoot -Directory -ErrorAction SilentlyContinue)) {
            if (-not (Test-SafeSessionId -Id $Session.Name)) {
                $Result.findings.Add((New-Finding -Severity error -Code 'CLINE_ID_UNSAFE' -Message "Ugyldig session-ID i $($Surface.Name)."))
                continue
            }
            $NativeRoot = Join-Path $Session.FullName 'native'
            $NativeFiles = @(
                if (Test-Path -LiteralPath $NativeRoot -PathType Container) {
                    Get-ChildItem -LiteralPath $NativeRoot -Recurse -File -ErrorAction SilentlyContinue
                }
            )
            $HistoryItem = Join-Path $Session.FullName 'task-history-item.json'
            $HasLegacyMessages = (Test-Path -LiteralPath (Join-Path $NativeRoot 'api_conversation_history.json') -PathType Leaf) -or
                (Test-Path -LiteralPath (Join-Path $NativeRoot 'ui_messages.json') -PathType Leaf)
            $SettingsOnlyLegacyArtifact = $Format.Equals('legacy', [System.StringComparison]::OrdinalIgnoreCase) -and
                -not (Test-Path -LiteralPath $HistoryItem -PathType Leaf) -and
                -not $HasLegacyMessages -and
                $NativeFiles.Count -gt 0 -and
                @($NativeFiles | Where-Object Name -ne 'settings.json').Count -eq 0
            if ($SettingsOnlyLegacyArtifact) { continue }

            $Result.sessions++
            if ($NativeFiles.Count -eq 0) {
                $Result.findings.Add((New-Finding -Severity error -Code 'CLINE_SESSION_EMPTY' -Message "$($Surface.Name)/$($Session.Name) mangler native oppgavefiler."))
            }

            if ($Format.Equals('legacy', [System.StringComparison]::OrdinalIgnoreCase)) {
                if (-not (Test-Path -LiteralPath $HistoryItem -PathType Leaf)) {
                    $Result.findings.Add((New-Finding -Severity warning -Code 'CLINE_HISTORY_ITEM_MISSING' -Message "$($Surface.Name)/$($Session.Name) mangler taskHistory-elementet som viser oppgaven i eldre Cline."))
                }
                if (-not $HasLegacyMessages) {
                    $Result.findings.Add((New-Finding -Severity error -Code 'CLINE_LEGACY_MESSAGES_MISSING' -Message "$($Surface.Name)/$($Session.Name) mangler begge eldre meldingsfilene."))
                }
            }
            else {
                $ManifestPath = Join-Path $NativeRoot "$($Session.Name).json"
                if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
                    $Result.findings.Add((New-Finding -Severity error -Code 'CLINE_MANIFEST_MISSING' -Message "$($Surface.Name)/$($Session.Name) mangler native sesjonsmanifest."))
                }
            }

            foreach ($JsonFile in @($NativeFiles + @(Get-ChildItem -LiteralPath $Session.FullName -File -Filter '*.json' -ErrorAction SilentlyContinue))) {
                try { $null = Get-Content -LiteralPath $JsonFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json }
                catch {
                    $Result.findings.Add((New-Finding -Severity error -Code 'CLINE_JSON_INVALID' -Message "$($Surface.Name)/$($Session.Name)/$($JsonFile.Name) er ikke gyldig JSON."))
                }
            }

            $IndexPath = Join-Path $ProjectPath ".agent-state/index/cline-workspaces/$($Surface.Name)/$($Session.Name).json"
            if (-not (Test-Path -LiteralPath $IndexPath -PathType Leaf)) {
                $Result.mapping.unknown++
                $Result.findings.Add((New-Finding -Severity warning -Code 'CLINE_WORKSPACE_INDEX_MISSING' -Message "$($Surface.Name)/$($Session.Name) mangler avledet workspace-indeks."))
            }
            else {
                try {
                    $Index = Get-Content -LiteralPath $IndexPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ([string]$Index.sessionId -ne $Session.Name -or [string]$Index.surface -ne $Surface.Name) {
                        $Result.findings.Add((New-Finding -Severity error -Code 'CLINE_WORKSPACE_INDEX_MISMATCH' -Message "$($Surface.Name)/$($Session.Name) har feil ID eller surface i workspace-indeksen."))
                    }
                    $Kind = Get-ProjectMappingKind -MetadataPath ([string]$Index.workspace) -ProjectRelative $ProjectRelative -ProjectPath $ProjectPath
                    $Result.mapping[$Kind]++
                }
                catch {
                    $Result.mapping.unknown++
                    $Result.findings.Add((New-Finding -Severity error -Code 'CLINE_WORKSPACE_INDEX_INVALID' -Message "$($Surface.Name)/$($Session.Name) har ugyldig workspace-indeks."))
                }
            }
        }
    }
    if ($Result.mapping.fallback -gt 0) {
        $Result.findings.Add((New-Finding -Severity warning -Code 'CLINE_FALLBACK_STATE' -Message "$($Result.mapping.fallback) økt(er) peker mot en annen prosjektidentitet og beholdes som fallback."))
    }
    return Complete-AgentResult -Result $Result
}

function Test-AiderState {
    param (
        [string]$ProjectPath,
        [string]$ProjectRelative
    )

    $Root = Join-Path $ProjectPath '.agent-state\aider'
    $Result = New-AgentResult -Name 'aider' -Target 'Prosjektlokal .agent-state/aider (ingen separat restore-adapter)'
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $Result }

    $Files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue)
    Add-AgentFiles -Result $Result -Files $Files -BasePath $Root
    $SessionParts = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($File in $Files) {
        if ($File.Length -eq 0) {
            $Result.findings.Add((New-Finding -Severity warning -Code 'AIDER_HISTORY_EMPTY' -Message "$($File.Name) er tom; økten kan ha blitt avbrutt før historikk ble skrevet."))
        }
        if ($File.Name -notmatch '^(?<id>[A-Za-z0-9][A-Za-z0-9._-]{0,127})\.(?<kind>chat|llm)\.md$') {
            $Result.findings.Add((New-Finding -Severity warning -Code 'AIDER_HISTORY_NAME_UNKNOWN' -Message "$($File.Name) følger ikke AgentSync-formatet <session>.chat.md eller <session>.llm.md."))
            continue
        }

        $Id = [string]$Matches.id
        if (-not (Test-SafeSessionId -Id $Id)) {
            $Result.findings.Add((New-Finding -Severity error -Code 'AIDER_ID_UNSAFE' -Message "$($File.Name) har en ugyldig session-ID."))
            continue
        }
        if (-not $SessionParts.ContainsKey($Id)) {
            $SessionParts[$Id] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        }
        [void]$SessionParts[$Id].Add([string]$Matches.kind)
    }

    foreach ($Entry in $SessionParts.GetEnumerator()) {
        $Result.sessions++
        $Result.mapping.exact++
        if (-not $Entry.Value.Contains('chat')) {
            $Result.findings.Add((New-Finding -Severity warning -Code 'AIDER_CHAT_MISSING' -Message "$($Entry.Key) mangler chat-historikken."))
        }
        if (-not $Entry.Value.Contains('llm')) {
            $Result.findings.Add((New-Finding -Severity warning -Code 'AIDER_LLM_MISSING' -Message "$($Entry.Key) mangler LLM-historikken."))
        }
    }
    return Complete-AgentResult -Result $Result
}

function Get-RecoveryCliVersion {
    param ([string]$Command)
    $StartInfo = [Diagnostics.ProcessStartInfo]::new()
    $StartInfo.FileName = $Command
    $StartInfo.UseShellExecute = $false
    $StartInfo.CreateNoWindow = $true
    $StartInfo.RedirectStandardOutput = $true
    $StartInfo.RedirectStandardError = $true
    $StartInfo.Environment['NO_COLOR'] = '1'
    [void]$StartInfo.ArgumentList.Add('--version')
    [void]$StartInfo.ArgumentList.Add('--pure')
    return Invoke-AgentSyncBoundedProcess -StartInfo $StartInfo -TimeoutSeconds 5 -MaxOutputCharacters 4096
}

function Get-AgentRuntimeChecks {
    param ($Config)

    $Checks = [System.Collections.Generic.List[object]]::new()
    foreach ($Agent in @(Get-AgentConfig -RoutingMode 'claude')) {
        $Path = Get-PlatformConfiguredPath -Object $Agent
        $Checks.Add([PSCustomObject]@{
            agent = 'claude'; label = 'Claude lokal state'; target = $Path
            status = if (Test-Path -LiteralPath $Path -PathType Container) { 'ready' } else { 'warning' }
            message = if (Test-Path -LiteralPath $Path -PathType Container) { 'Lokal målmappe finnes på denne maskinen.' } else { 'Installer/start Claude før restore slik at målmappen opprettes.' }
        })
    }

    $CodexPaths = @(Get-AgentConfig -RoutingMode 'codex' | ForEach-Object { Get-PlatformConfiguredPath -Object $_ } | Where-Object { $_ })
    $ExistingCodex = @($CodexPaths | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
    $Checks.Add([PSCustomObject]@{
        agent = 'codex'; label = 'Codex lokal state'; target = ($CodexPaths -join ' + ')
        status = if ($ExistingCodex.Count -gt 0) { 'ready' } else { 'warning' }
        message = if ($ExistingCodex.Count -gt 0) { 'Minst én lokal målmappe finnes på denne maskinen.' } else { 'Installer/start Codex før restore slik at målmappene opprettes.' }
    })

    foreach ($Agent in @(Get-AgentConfig -RoutingMode 'antigravity')) {
        $Paths = @($Agent.roots | ForEach-Object { Get-PlatformConfiguredPath -Object $_ } | Where-Object { $_ })
        $Existing = @($Paths | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
        $Checks.Add([PSCustomObject]@{
            agent = 'antigravity'; label = 'Antigravity lokal state'; target = ($Paths -join ' + ')
            status = if ($Existing.Count -gt 0) { 'ready' } else { 'warning' }
            message = if ($Existing.Count -gt 0) { "$($Existing.Count) av $($Paths.Count) konfigurerte surface-mapper finnes." } else { 'Installer/start Antigravity før restore slik at minst én surface-mappe opprettes.' }
        })
    }

    foreach ($Agent in @(Get-AgentConfig -RoutingMode 'opencode')) {
        $Setting = if ($IsWindows -and (Get-ObjectPropertyValue -Object $Agent -Name 'commandWindows')) { [string]$Agent.commandWindows } else { [string]$Agent.command }
        $Expanded = Resolve-ConfiguredCommand -Command $Setting
        $Command = $null
        if (Test-Path -LiteralPath $Expanded -PathType Leaf) { $Command = $Expanded }
        elseif (-not [string]::IsNullOrWhiteSpace($Setting)) { $Command = (Get-Command $Setting -ErrorAction SilentlyContinue).Source }
        $Version = $null
        $VersionWarning = $null
        if ($Command -and -not $SkipRuntimeVersionCheck) {
            try {
                $Probe = Get-RecoveryCliVersion -Command $Command
                if ($Probe.TimedOut) { $VersionWarning = 'Versjonskontrollen overskred tidsgrensen på fem sekunder.' }
                elseif ($Probe.ExitCode -ne 0) { $VersionWarning = 'Versjonskontrollen feilet; CLI-filen finnes, men kjørbarhet er ikke bekreftet.' }
                else { $Version = ([string]$Probe.StdOut -split '\r?\n' | Select-Object -First 1).Trim() }
            }
            catch { $VersionWarning = 'Versjonskontrollen kunne ikke startes; kjørbarhet er ikke bekreftet.' }
        }
        $Checks.Add([PSCustomObject]@{
            agent = 'opencode'; label = 'OpenCode CLI'; target = $Expanded
            status = if ($Command -and -not $VersionWarning) { 'ready' } else { 'warning' }
            message = if ($VersionWarning) { $VersionWarning }
                elseif ($Command -and $SkipRuntimeVersionCheck) { 'CLI-filen finnes. Versjonskontroll er ikke kjørt; ingen CLI ble startet.' }
                elseif ($Command) { "CLI er tilgjengelig$(if ($Version) { " (v$Version)" })." }
                else { 'OpenCode-eksporter er intakte, men CLI må installeres før import.' }
        })
    }
    foreach ($Agent in @(Get-AgentConfig -RoutingMode 'cline')) {
        $Paths = @($Agent.roots | ForEach-Object { Get-PlatformConfiguredPath -Object $_ } | Where-Object { $_ })
        $Existing = @($Paths | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
        $Checks.Add([PSCustomObject]@{
            agent = 'cline'; label = 'Cline lokal state'; target = ($Paths -join ' + ')
            status = if ($Existing.Count -gt 0) { 'ready' } else { 'warning' }
            message = if ($Existing.Count -gt 0) { "$($Existing.Count) av $($Paths.Count) Cline-lagringer finnes; manifest-fallback støttes." } else { 'Start Cline i VS Code minst én gang før restore, slik at lokal lagring opprettes.' }
        })
    }
    return $Checks.ToArray()
}

function Get-AgentDisplayName {
    param ([string]$Name)
    switch ($Name) {
        'claude' { return 'Claude' }
        'codex' { return 'Codex' }
        'antigravity' { return 'Antigravity' }
        'opencode' { return 'OpenCode' }
        'cline' { return 'Cline' }
        'aider' { return 'Aider' }
        default { return $Name }
    }
}

function Get-StatusLabel {
    param ([string]$Status)
    switch ($Status) {
        'ready' { return 'Klar' }
        'warning' { return 'Kontroller' }
        'error' { return 'Feil' }
        default { return 'Ingen state' }
    }
}

function New-RecoveryHtml {
    param ($Audit)

    $ProjectRows = [System.Text.StringBuilder]::new()
    foreach ($Project in @($Audit.projects)) {
        $AgentTags = [System.Text.StringBuilder]::new()
        $AgentDetails = [System.Text.StringBuilder]::new()
        foreach ($Agent in @($Project.agents)) {
            $Display = Get-AgentDisplayName -Name $Agent.name
            [void]$AgentTags.Append("<span class=`"agent-tag $($Agent.name) $($Agent.status)`"><span class=`"agent-dot`"></span>$(Get-HtmlEncoded $Display)<small>$(Get-HtmlEncoded (Get-StatusLabel $Agent.status))</small></span>")
            $FindingsHtml = if (@($Agent.findings).Count -eq 0) {
                '<span class="muted">Ingen avvik.</span>'
            }
            else {
                (@($Agent.findings) | ForEach-Object { "<div class=`"finding $($_.severity)`"><code>$(Get-HtmlEncoded $_.code)</code> $(Get-HtmlEncoded $_.message)</div>" }) -join ''
            }
            $HashHtml = if ($Agent.integrityHash) { "<div><b>SHA-256 inventory:</b> <code>$(Get-HtmlEncoded $Agent.integrityHash)</code></div>" } else { '' }
            [void]$AgentDetails.Append(@"
<section class="agent-detail $($Agent.status)">
  <h4>$(Get-HtmlEncoded $Display) <span class="status-pill $($Agent.status)">$(Get-HtmlEncoded (Get-StatusLabel $Agent.status))</span></h4>
  <div class="detail-grid">
    <div><b>Sesjoner</b><span>$($Agent.sessions)</span></div>
    <div><b>Filer</b><span>$($Agent.files)</span></div>
    <div><b>Data</b><span>$(Get-HtmlEncoded (Format-ByteSize $Agent.bytes))</span></div>
    <div><b>Mapping</b><span>$($Agent.mapping.exact) eksakt · $($Agent.mapping.portable) portabel · $($Agent.mapping.fallback) fallback · $($Agent.mapping.unknown) ukjent</span></div>
  </div>
  <div class="target"><b>Gjenopprettes til:</b> <code>$(Get-HtmlEncoded $Agent.target)</code></div>
  $HashHtml
  <div class="findings">$FindingsHtml</div>
</section>
"@)
        }

        $ProjectFindings = if (@($Project.findings).Count -gt 0) {
            (@($Project.findings) | ForEach-Object { "<div class=`"finding $($_.severity)`"><code>$(Get-HtmlEncoded $_.code)</code> $(Get-HtmlEncoded $_.message)</div>" }) -join ''
        }
        else { '' }
        $SearchText = "$($Project.relative) $($Project.path) " + (($Project.agents | ForEach-Object name) -join ' ')
        [void]$ProjectRows.Append(@"
<article class="project $($Project.status)" data-search="$(Get-HtmlEncoded $SearchText)">
  <details>
    <summary>
      <span class="project-main"><span class="status-light $($Project.status)"></span><span><b>$(Get-HtmlEncoded ($Project.relative -replace '[\\/]', ' / '))</b><small>$(Get-HtmlEncoded $Project.path)</small></span></span>
      <span class="project-agents">$AgentTags</span>
      <span class="project-total">$(Format-ByteSize $Project.bytes)</span>
    </summary>
    <div class="project-body">
      $ProjectFindings
      $AgentDetails
    </div>
  </details>
</article>
"@)
    }

    $RuntimeCards = (@($Audit.runtime) | ForEach-Object {
        "<article class=`"runtime-card $($_.status)`"><div class=`"runtime-title`"><span class=`"agent-dot $($_.agent)`"></span><b>$(Get-HtmlEncoded $_.label)</b><span class=`"status-pill $($_.status)`">$(Get-HtmlEncoded (Get-StatusLabel $_.status))</span></div><p>$(Get-HtmlEncoded $_.message)</p><code>$(Get-HtmlEncoded $_.target)</code></article>"
    }) -join "`n"

    $GlobalFindings = if (@($Audit.findings).Count -eq 0) {
        '<div class="empty">Ingen globale avvik.</div>'
    }
    else {
        (@($Audit.findings) | ForEach-Object { "<div class=`"finding $($_.severity)`"><code>$(Get-HtmlEncoded $_.code)</code> $(Get-HtmlEncoded $_.message)</div>" }) -join ''
    }

    $ModeText = if ($Audit.deep) { 'Dyp kontroll: alle JSONL-poster + SHA-256' } else { 'Rask kontroll: start/slutt, schema og routing' }
    $GeneratedLocal = ([datetimeoffset]$Audit.generatedUtc).ToLocalTime().ToString('dd.MM.yyyy HH:mm:ss zzz')

    return @"
<!doctype html>
<html lang="no">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>AgentSync – gjenopprettingsrevisjon</title>
<style>
:root{color-scheme:dark;--bg:#0d131a;--panel:#151e28;--line:#293746;--text:#edf4fb;--muted:#90a4b8;--green:#35c27c;--yellow:#f4b942;--red:#f06464;--claude:#d97757;--codex:#fff;--antigravity:#4285f4;--opencode:#7dd3fc;--cline:#9aa4ae;--aider:#74e6a7}*{box-sizing:border-box}body{margin:0;background:radial-gradient(circle at 15% -5%,#203246 0,transparent 34%),var(--bg);font:14px/1.45 Inter,Segoe UI,system-ui,sans-serif;color:var(--text)}main{max-width:1500px;margin:auto;padding:34px 22px 70px}h1{font-size:30px;margin:0 0 7px}.eyebrow{color:#7dd3fc;text-transform:uppercase;letter-spacing:.13em;font-weight:800;font-size:11px}.subtitle{color:var(--muted);max-width:900px;margin:0 0 24px}.summary{display:grid;grid-template-columns:repeat(6,minmax(120px,1fr));gap:10px;margin:20px 0}.metric,.runtime-card,.panel,.project{background:rgba(21,30,40,.92);border:1px solid var(--line);border-radius:13px}.metric{padding:15px}.metric b{display:block;font-size:24px}.metric span{color:var(--muted);font-size:12px}.metric.ready{border-color:#267d59}.metric.warning{border-color:#8c6823}.metric.error{border-color:#8d3737}.toolbar{display:flex;gap:10px;align-items:center;margin:20px 0 12px;position:sticky;top:0;z-index:5;background:rgba(13,19,26,.94);padding:10px 0;backdrop-filter:blur(8px)}input{width:min(520px,100%);border:1px solid var(--line);border-radius:10px;background:#0c1218;color:var(--text);padding:11px 13px;font:inherit}.mode{color:var(--muted);font-size:12px;margin-left:auto}.runtime{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:10px}.runtime-card{padding:14px;min-width:0}.runtime-card.ready{border-left:4px solid var(--green)}.runtime-card.warning{border-left:4px solid var(--yellow)}.runtime-title{display:flex;gap:8px;align-items:center}.runtime-title .status-pill{margin-left:auto}.runtime-card p{color:var(--muted);min-height:40px}.runtime-card code,.target code{display:block;overflow-wrap:anywhere}.panel{padding:17px;margin:16px 0}.panel h2{font-size:17px;margin:0 0 12px}.project{margin:8px 0;overflow:hidden}.project.ready{border-left:4px solid var(--green)}.project.warning{border-left:4px solid var(--yellow)}.project.error{border-left:4px solid var(--red)}summary{display:grid;grid-template-columns:minmax(320px,1fr) minmax(350px,auto) 90px;gap:14px;align-items:center;padding:14px 16px;cursor:pointer;list-style:none}summary::-webkit-details-marker{display:none}.project-main{display:flex;gap:11px;align-items:flex-start;min-width:0}.project-main b,.project-main small{display:block;overflow-wrap:anywhere}.project-main small{color:var(--muted);margin-top:3px;font-size:11px}.status-light{width:10px;height:10px;border-radius:50%;margin-top:5px;flex:0 0 auto;background:var(--muted)}.status-light.ready{background:var(--green);box-shadow:0 0 10px #35c27c66}.status-light.warning{background:var(--yellow)}.status-light.error{background:var(--red)}.project-agents{display:flex;gap:6px;flex-wrap:wrap}.agent-tag{display:inline-flex;align-items:center;gap:5px;border:1px solid #455564;border-radius:999px;padding:5px 8px 5px 5px;font-size:11px;font-weight:750}.agent-tag small{opacity:.72}.agent-tag.absent{opacity:.42}.agent-tag.error{box-shadow:inset 0 0 0 1px var(--red)}.agent-tag.warning{box-shadow:inset 0 0 0 1px var(--yellow)}.agent-dot{width:11px;height:11px;border-radius:50%;display:inline-block;background:var(--muted)}.agent-tag.claude .agent-dot,.agent-dot.claude{background:var(--claude)}.agent-tag.codex .agent-dot,.agent-dot.codex{background:var(--codex)}.agent-tag.antigravity .agent-dot,.agent-dot.antigravity{background:var(--antigravity)}.agent-tag.opencode .agent-dot,.agent-dot.opencode{background:var(--opencode)}.agent-tag.cline .agent-dot,.agent-dot.cline{background:var(--cline)}.agent-tag.aider .agent-dot,.agent-dot.aider{background:var(--aider)}.project-total{text-align:right;color:var(--muted)}.project-body{padding:0 16px 16px;border-top:1px solid var(--line)}.agent-detail{margin-top:12px;padding:13px;background:#0f171f;border:1px solid var(--line);border-radius:10px}.agent-detail h4{display:flex;gap:9px;align-items:center;margin:0 0 10px}.status-pill{font-size:10px;text-transform:uppercase;letter-spacing:.05em;padding:3px 7px;border-radius:999px;background:#304052;color:#dce7f2}.status-pill.ready{background:#174d38;color:#8ff0bb}.status-pill.warning{background:#59451b;color:#ffd977}.status-pill.error{background:#592828;color:#ffaaaa}.status-pill.absent{background:#2c3946;color:#a8b8c8}.detail-grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:7px;margin-bottom:9px}.detail-grid div{background:#121d27;padding:9px;border-radius:7px}.detail-grid b,.detail-grid span{display:block}.detail-grid b{color:var(--muted);font-size:10px;text-transform:uppercase}.target{margin:8px 0;color:var(--muted)}.finding{padding:8px 10px;margin:7px 0;border-radius:7px;background:#17222d}.finding.warning{border-left:3px solid var(--yellow)}.finding.error{border-left:3px solid var(--red)}.finding.info{border-left:3px solid #6ba5e7}.finding code{color:#b7cee4}.muted,.empty{color:var(--muted)}code{font:11px/1.4 Consolas,ui-monospace,monospace}footer{color:var(--muted);margin-top:20px;font-size:12px}@media(max-width:1100px){.runtime{grid-template-columns:repeat(3,1fr)}}@media(max-width:980px){.summary{grid-template-columns:repeat(3,1fr)}.runtime{grid-template-columns:repeat(2,1fr)}summary{grid-template-columns:1fr}.project-total{text-align:left}.detail-grid{grid-template-columns:repeat(2,1fr)}}@media(max-width:600px){main{padding:24px 12px 50px}.summary{grid-template-columns:repeat(2,1fr)}.runtime{grid-template-columns:1fr}.toolbar{align-items:stretch;flex-direction:column}.mode{margin-left:0}.detail-grid{grid-template-columns:1fr}.agent-tag small{display:none}}
</style>
</head>
<body>
<main>
  <div class="eyebrow">AgentSync Toolkit v$(Get-HtmlEncoded $Audit.agentSyncVersion)</div>
  <h1>Gjenopprettingsrevisjon</h1>
  <p class="subtitle">Beviser hvilke prosjektbundne kopier som kan leses og knyttes til riktig prosjekt, og hvilke som kan føres tilbake til en agents native lagring. Aider-historikk er prosjektlokal og har ingen separat restore-adapter. Kontrollen skriver aldri til <code>.agent-state</code> eller agentmappene.</p>
  <section class="summary">
    <div class="metric"><b>$($Audit.summary.projects)</b><span>prosjekter fra agentindeks</span></div>
    <div class="metric ready"><b>$($Audit.summary.ready)</b><span>klare prosjekter</span></div>
    <div class="metric warning"><b>$($Audit.summary.warnings)</b><span>må kontrolleres</span></div>
    <div class="metric error"><b>$($Audit.summary.errors)</b><span>feil</span></div>
    <div class="metric"><b>$($Audit.summary.sessions)</b><span>agentøkter</span></div>
    <div class="metric"><b>$(Get-HtmlEncoded (Format-ByteSize $Audit.summary.bytes))</b><span>gjenopprettbar state</span></div>
  </section>
  <section class="panel">
    <h2>Denne maskinens mottakere</h2>
    <div class="runtime">$RuntimeCards</div>
  </section>
  <section class="panel">
    <h2>Kontrollnivå og globale funn</h2>
    <p class="muted">$(Get-HtmlEncoded $ModeText). Prosjektlisten kommer bare fra <code>project-index/*.json</code>, som igjen er avledet fra agentenes cwd/workspace/directory – synkeroten er ikke skannet etter tilfeldige mapper.</p>
    $GlobalFindings
  </section>
  <div class="toolbar"><input id="search" type="search" placeholder="Søk etter prosjekt, sti eller agent"><span id="shown"></span><span class="mode">Generert $GeneratedLocal · $($Audit.durationSeconds) s</span></div>
  <section id="projects">$ProjectRows</section>
  <footer>Grønn betyr at den prosjektbundne state-kopien bestod kontrollen. Gul betyr at fallback, manglende lokal app/mappe eller et annet avvik bør vurderes. Rød betyr at en nødvendig fil, identitet eller struktur ikke kunne valideres. Rapporten inneholder metadata, ikke samtaleinnhold.</footer>
</main>
<script>
const q=document.getElementById('search'),rows=[...document.querySelectorAll('.project')],shown=document.getElementById('shown');
function filter(){const s=q.value.trim().toLocaleLowerCase('nb');let n=0;for(const row of rows){const ok=!s||row.dataset.search.toLocaleLowerCase('nb').includes(s);row.hidden=!ok;if(ok)n++}shown.textContent=n+' av '+rows.length+' prosjekter'}
q.addEventListener('input',filter);filter();
</script>
</body>
</html>
"@
}

$Started = [datetimeoffset]::UtcNow
if ([string]::IsNullOrWhiteSpace($ConfigFile)) {
    $LocalConfig = Join-Path $PSScriptRoot 'config.local.json'
    $ConfigFile = if (Test-Path -LiteralPath $LocalConfig -PathType Leaf) { $LocalConfig } else { Join-Path $PSScriptRoot 'config.json' }
}
$ConfigFile = [System.IO.Path]::GetFullPath($ConfigFile)
if (-not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) {
    throw "Config file not found: $ConfigFile"
}

$Script:Config = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
$Script:MetadataReadLines = if ($Script:Config.metadataReadLines) { [Math]::Max(10, [int]$Script:Config.metadataReadLines) } else { 100 }
$ProjectsSetting = if ($Script:Config.sharedProjectsDir) { [string]$Script:Config.sharedProjectsDir } else { [string]$Script:Config.dropboxProjectsDir }
$ProjectsRoot = Expand-AgentSyncPath -Path $ProjectsSetting
if (-not (Test-Path -LiteralPath $ProjectsRoot -PathType Container)) {
    throw "Shared projects root not found: $ProjectsRoot"
}

$IndexSetting = 'project-index'
if ($Script:Config.projectIndex -and $Script:Config.projectIndex.directory) {
    $IndexSetting = [string]$Script:Config.projectIndex.directory
}
$IndexDirectory = if ([System.IO.Path]::IsPathRooted($IndexSetting)) { [System.IO.Path]::GetFullPath($IndexSetting) } else { [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot $IndexSetting)) }
$ReportFile = Assert-SafeReportDestination -Path $ReportFile -Config $Script:Config -IndexDirectory $IndexDirectory -ConfigFile $ConfigFile
$JsonFile = Assert-SafeReportDestination -Path $JsonFile -Config $Script:Config -IndexDirectory $IndexDirectory -ConfigFile $ConfigFile
if ($ReportFile.Equals($JsonFile, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'ReportFile and JsonFile must be different files.'
}
$GlobalFindings = [System.Collections.Generic.List[object]]::new()
$ProjectMap = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
$IndexFiles = @()

if (-not (Test-Path -LiteralPath $IndexDirectory -PathType Container)) {
    $GlobalFindings.Add((New-Finding -Severity error -Code 'PROJECT_INDEX_MISSING' -Message "Prosjektindeksen finnes ikke: $IndexDirectory"))
}
else {
    $IndexFiles = @(Get-ChildItem -LiteralPath $IndexDirectory -File -Filter '*.json' -ErrorAction SilentlyContinue)
    if ($IndexFiles.Count -eq 0) {
        $GlobalFindings.Add((New-Finding -Severity error -Code 'PROJECT_INDEX_EMPTY' -Message 'Prosjektindeksen inneholder ingen maskinfiler.'))
    }
    foreach ($File in $IndexFiles) {
        try {
            $Index = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([int]$Index.format -ne 1 -or -not $Index.projects) {
                $GlobalFindings.Add((New-Finding -Severity error -Code 'PROJECT_INDEX_FORMAT' -Message "$($File.Name) har ukjent eller manglende format."))
                continue
            }
            foreach ($RawRelative in @($Index.projects)) {
                $Relative = ([string]$RawRelative).Trim().Replace('/', [System.IO.Path]::DirectorySeparatorChar)
                if ([string]::IsNullOrWhiteSpace($Relative) -or [System.IO.Path]::IsPathRooted($Relative)) {
                    $GlobalFindings.Add((New-Finding -Severity error -Code 'PROJECT_PATH_UNSAFE' -Message "$($File.Name) inneholder en absolutt eller tom prosjektsti."))
                    continue
                }
                $Candidate = [System.IO.Path]::GetFullPath((Join-Path $ProjectsRoot $Relative)).TrimEnd('\', '/')
                if (-not (Test-PathInside -ChildPath $Candidate -ParentPath $ProjectsRoot) -or $Candidate.Equals($ProjectsRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $GlobalFindings.Add((New-Finding -Severity error -Code 'PROJECT_PATH_ESCAPE' -Message "$($File.Name) inneholder en sti utenfor synkeroten."))
                    continue
                }
                $CanonicalRelative = [System.IO.Path]::GetRelativePath($ProjectsRoot, $Candidate)
                if (-not $ProjectMap.ContainsKey($CanonicalRelative)) {
                    $ProjectMap[$CanonicalRelative] = [PSCustomObject]@{ relative = $CanonicalRelative; path = $Candidate }
                }
            }
        }
        catch {
            $GlobalFindings.Add((New-Finding -Severity error -Code 'PROJECT_INDEX_INVALID' -Message "$($File.Name) kunne ikke leses som JSON."))
        }
    }
}

$Runtime = @(Get-AgentRuntimeChecks -Config $Script:Config)
$ClaudeAgent = @(Get-AgentConfig -RoutingMode 'claude' | Select-Object -First 1)
$CodexAgents = @(Get-AgentConfig -RoutingMode 'codex')
$AntigravityAgent = @(Get-AgentConfig -RoutingMode 'antigravity' | Select-Object -First 1)
$OpenCodeAgent = @(Get-AgentConfig -RoutingMode 'opencode' | Select-Object -First 1)
$ClineAgent = @(Get-AgentConfig -RoutingMode 'cline' | Select-Object -First 1)
$Projects = [System.Collections.Generic.List[object]]::new()

foreach ($Entry in @($ProjectMap.Values | Sort-Object relative)) {
    $ProjectFindings = [System.Collections.Generic.List[object]]::new()
    $Agents = [System.Collections.Generic.List[object]]::new()
    $StateRoot = Join-Path $Entry.path '.agent-state'
    $Manifest = $null
    $ManifestPath = $null

    if (-not (Test-Path -LiteralPath $Entry.path -PathType Container)) {
        $ProjectFindings.Add((New-Finding -Severity error -Code 'PROJECT_DIRECTORY_MISSING' -Message 'Prosjektet finnes i agentindeksen, men mappen er ikke tilgjengelig på denne maskinen.'))
    }
    elseif (-not (Test-Path -LiteralPath $StateRoot -PathType Container)) {
        $ProjectFindings.Add((New-Finding -Severity error -Code 'STATE_ROOT_MISSING' -Message 'Prosjektet finnes i agentindeksen, men mangler .agent-state.'))
    }
    else {
        $ManifestPath = Join-Path $StateRoot 'manifest.json'
        if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
            $ProjectFindings.Add((New-Finding -Severity warning -Code 'MANIFEST_MISSING' -Message 'Kontrollmanifestet mangler; prosjektbundet state kontrolleres likevel direkte.'))
        }
        else {
            try {
                $Manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ([int]$Manifest.format -ne 1) {
                    $ProjectFindings.Add((New-Finding -Severity warning -Code 'MANIFEST_FORMAT' -Message 'Manifestet har et ukjent format.'))
                }
                if (-not $Manifest.agents) {
                    $ProjectFindings.Add((New-Finding -Severity warning -Code 'MANIFEST_AGENTS_MISSING' -Message 'Manifestet mangler agentinventar.'))
                }
            }
            catch {
                $ProjectFindings.Add((New-Finding -Severity error -Code 'MANIFEST_INVALID' -Message 'Manifestet er ikke gyldig JSON.'))
            }
        }
        $ConflictRoot = Join-Path $StateRoot 'conflicts'
        if (Test-Path -LiteralPath $ConflictRoot -PathType Container) {
            $ConflictCount = @(Get-ChildItem -LiteralPath $ConflictRoot -Recurse -File -ErrorAction SilentlyContinue).Count
            if ($ConflictCount -gt 0) {
                $ProjectFindings.Add((New-Finding -Severity warning -Code 'CONFLICT_COPIES_PRESENT' -Message "$ConflictCount bevarte konfliktkopi(er) krever eventuell manuell vurdering."))
            }
        }
    }

    if ($ClaudeAgent.Count -gt 0) { $Agents.Add((Test-ClaudeState -ProjectPath $Entry.path -ProjectRelative $Entry.relative -Agent $ClaudeAgent[0])) }
    if ($CodexAgents.Count -gt 0) { $Agents.Add((Test-CodexState -ProjectPath $Entry.path -ProjectRelative $Entry.relative -Agents $CodexAgents)) }
    if ($AntigravityAgent.Count -gt 0) { $Agents.Add((Test-AntigravityState -ProjectPath $Entry.path -ProjectRelative $Entry.relative -Agent $AntigravityAgent[0])) }
    if ($OpenCodeAgent.Count -gt 0) { $Agents.Add((Test-OpenCodeState -ProjectPath $Entry.path -ProjectRelative $Entry.relative -Agent $OpenCodeAgent[0])) }
    if ($ClineAgent.Count -gt 0) { $Agents.Add((Test-ClineState -ProjectPath $Entry.path -ProjectRelative $Entry.relative -Agent $ClineAgent[0])) }
    $Agents.Add((Test-AiderState -ProjectPath $Entry.path -ProjectRelative $Entry.relative))

    $PresentAgents = @($Agents | Where-Object status -ne 'absent')
    if ($PresentAgents.Count -eq 0 -and (Test-Path -LiteralPath $StateRoot -PathType Container)) {
        $ProjectFindings.Add((New-Finding -Severity warning -Code 'NO_PROVIDER_STATE' -Message 'Ingen agenthistorikk ble funnet under .agent-state.'))
    }

    $ManifestSnapshots = [System.Collections.Generic.List[object]]::new()
    if ($Manifest) { $ManifestSnapshots.Add($Manifest) }
    if ($ManifestPath -and (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        try {
            $FreshManifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $ManifestSnapshots.Add($FreshManifest)
        }
        catch {
        }
    }
    if ($ManifestSnapshots.Count -gt 0) {
        foreach ($AgentResult in $PresentAgents) {
            $FoundInManifest = $false
            $InventoryMatched = $false
            foreach ($ManifestSnapshot in $ManifestSnapshots) {
                if (-not $ManifestSnapshot.agents) { continue }
                $ManifestAgentProperty = $ManifestSnapshot.agents.PSObject.Properties[$AgentResult.name]
                if (-not $ManifestAgentProperty) { continue }
                $FoundInManifest = $true
                $ManifestAgent = $ManifestAgentProperty.Value
                if ([long]$ManifestAgent.files -eq [long]$AgentResult.files -and [long]$ManifestAgent.bytes -eq [long]$AgentResult.bytes) {
                    $InventoryMatched = $true
                    break
                }
            }
            if (-not $FoundInManifest) {
                $ProjectFindings.Add((New-Finding -Severity warning -Code 'MANIFEST_AGENT_MISSING' -Message "Manifestet mangler $($AgentResult.name), men prosjektbundet state finnes."))
                continue
            }
            if (-not $InventoryMatched) {
                $ProjectFindings.Add((New-Finding -Severity warning -Code 'MANIFEST_INVENTORY_CHANGED' -Message "$($AgentResult.name): manifestet og den nåværende filkopien har ulikt antall eller størrelse. Aktiv synk kan være årsaken."))
            }
        }
    }

    $CombinedFindings = @($ProjectFindings) + @($Agents | ForEach-Object { @($_.findings) })
    $Status = Get-WorstStatus -Findings $CombinedFindings
    $Projects.Add([PSCustomObject]@{
        relative = $Entry.relative
        path = $Entry.path
        status = $Status
        bytes = [long](($PresentAgents | Measure-Object bytes -Sum).Sum)
        sessions = [int](($PresentAgents | Measure-Object sessions -Sum).Sum)
        findings = $ProjectFindings.ToArray()
        agents = $Agents.ToArray()
    })
}

$ProjectArray = $Projects.ToArray()
$Audit = [ordered]@{
    format = 1
    report = 'AgentSync recovery audit'
    agentSyncVersion = [string]$Script:Config.version
    generatedUtc = [datetimeoffset]::UtcNow.ToString('o')
    durationSeconds = 0
    machine = [Environment]::MachineName
    platform = Get-CurrentPlatformName
    configFile = $ConfigFile
    projectsRoot = $ProjectsRoot
    projectIndexDirectory = $IndexDirectory
    projectIndexFiles = @($IndexFiles | ForEach-Object Name)
    deep = [bool]$Deep
    runtimeVersionCheckSkipped = [bool]$SkipRuntimeVersionCheck
    readOnlyScope = @('.agent-state', 'configured local agent roots')
    writes = @([System.IO.Path]::GetFullPath($ReportFile), [System.IO.Path]::GetFullPath($JsonFile))
    summary = [ordered]@{
        projects = $ProjectArray.Count
        ready = @($ProjectArray | Where-Object status -eq 'ready').Count
        warnings = @($ProjectArray | Where-Object status -eq 'warning').Count
        errors = @($ProjectArray | Where-Object status -eq 'error').Count
        sessions = [int](($ProjectArray | Measure-Object sessions -Sum).Sum)
        bytes = [long](($ProjectArray | Measure-Object bytes -Sum).Sum)
    }
    runtime = $Runtime
    findings = $GlobalFindings.ToArray()
    projects = $ProjectArray
}
$Audit.durationSeconds = [Math]::Round(([datetimeoffset]::UtcNow - $Started).TotalSeconds, 2)

$Json = $Audit | ConvertTo-Json -Depth 20
Write-AtomicUtf8File -Path $JsonFile -Text $Json
$Html = New-RecoveryHtml -Audit ([PSCustomObject]$Audit)
Write-AtomicUtf8File -Path $ReportFile -Text $Html

$OverallErrors = [int]$Audit.summary.errors + @($Audit.findings | Where-Object severity -eq 'error').Count
$OverallWarnings = [int]$Audit.summary.warnings + @($Audit.findings | Where-Object severity -eq 'warning').Count
Write-Host "AgentSync recovery audit: $($Audit.summary.ready) ready, $($Audit.summary.warnings) warning, $($Audit.summary.errors) error project(s)." -ForegroundColor $(if ($OverallErrors -gt 0) { 'Red' } elseif ($OverallWarnings -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "HTML: $([System.IO.Path]::GetFullPath($ReportFile))"
Write-Host "JSON: $([System.IO.Path]::GetFullPath($JsonFile))"
if (-not $Deep) {
    Write-Host 'Run with -Deep for full JSONL validation and SHA-256 inventory fingerprints.' -ForegroundColor DarkGray
}
[Environment]::ExitCode = if ($OverallErrors -gt 0) { 1 } else { 0 }
