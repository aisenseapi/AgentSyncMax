# Shared Windows desktop build/launch helpers. Loading this file starts nothing.
#requires -Version 7.0

function Get-AgentSyncDesktopLocalRoot {
    param([string]$LocalAppData = [Environment]::GetFolderPath('LocalApplicationData'))
    if ([string]::IsNullOrWhiteSpace($LocalAppData) -or -not [IO.Path]::IsPathFullyQualified($LocalAppData)) {
        throw 'Fant ikke en absolutt lokal appmappe. Ingen programfiler er flyttet eller startet.'
    }
    return Join-Path ([IO.Path]::GetFullPath($LocalAppData)) 'AgentSyncMax'
}

function Copy-AgentSyncVerifiedDesktopFile {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [string]$ExpectedSha256,
        [switch]$Replace
    )
    $Source = (Resolve-Path -LiteralPath $Source -ErrorAction Stop).Path
    $Destination = [IO.Path]::GetFullPath($Destination)
    $ExpectedHash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256 -ErrorAction Stop).Hash
    if ($ExpectedSha256 -and $ExpectedHash -ne $ExpectedSha256) { throw 'Programfilen stemmer ikke med forventet SHA-256. Ingen kopiering.' }
    if (Test-Path -LiteralPath $Destination) {
        if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) { throw "Programbanen er ikke en fil: $Destination" }
        if ((Get-FileHash -LiteralPath $Destination -Algorithm SHA256 -ErrorAction Stop).Hash -eq $ExpectedHash) { return $Destination }
        if (-not $Replace) { throw "Eksisterende programkopi har annet innhold og blir ikke overskrevet: $Destination" }
    }
    $Directory = [IO.Path]::GetDirectoryName($Destination)
    [void][IO.Directory]::CreateDirectory($Directory)
    $Temporary = Join-Path $Directory ('.agentsync-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::Copy($Source, $Temporary, $false)
        if ((Get-FileHash -LiteralPath $Temporary -Algorithm SHA256 -ErrorAction Stop).Hash -ne $ExpectedHash -or
            (Get-FileHash -LiteralPath $Source -Algorithm SHA256 -ErrorAction Stop).Hash -ne $ExpectedHash) {
            throw 'Programfilen endret seg under kopiering. Den tidligere kopien beholdes.'
        }
        try { [IO.File]::Move($Temporary, $Destination, [bool]$Replace) }
        catch {
            # Another launcher may have completed the same immutable copy first.
            if ($Replace -or -not (Test-Path -LiteralPath $Destination -PathType Leaf) -or
                (Get-FileHash -LiteralPath $Destination -Algorithm SHA256 -ErrorAction Stop).Hash -ne $ExpectedHash) { throw }
        }
        if ((Get-FileHash -LiteralPath $Destination -Algorithm SHA256 -ErrorAction Stop).Hash -ne $ExpectedHash) {
            throw "Programkopien kunne ikke verifiseres: $Destination"
        }
        return $Destination
    }
    finally {
        # This is only the unique temporary file created by this invocation.
        if (Test-Path -LiteralPath $Temporary -PathType Leaf) { [IO.File]::Delete($Temporary) }
    }
}

function Get-AgentSyncDesktopSource {
    param([Parameter(Mandatory)][string]$ToolkitRoot, [ref]$ExpectedSha256)
    if ($ExpectedSha256) { $ExpectedSha256.Value = $null }
    $Dist = Join-Path $ToolkitRoot 'desktop\dist'
    $Pointer = Join-Path $Dist 'current-release.json'
    if (Test-Path -LiteralPath $Pointer) {
        $PointerInfo = Get-Item -LiteralPath $Pointer -ErrorAction Stop
        # Dropbox cloud placeholders carry ReparsePoint without being path redirects.
        if ($PointerInfo.PSIsContainer -or $PointerInfo.Length -gt 4096 -or $PointerInfo.LinkType) { throw 'Ugyldig current-release.json. Ingen reservefil startes automatisk.' }
        try { $Release = Get-Content -LiteralPath $Pointer -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
        catch { throw 'Kan ikke lese current-release.json. Ingen reservefil startes automatisk.' }
        if ($Release -isnot [pscustomobject] -or $Release.schemaVersion -isnot [long] -or $Release.schemaVersion -ne 1 -or
            $Release.executable -isnot [string] -or $Release.executable -notmatch '^AgentSync-Max-[0-9A-Za-z.+-]+-[a-fA-F0-9]{12}\.exe$' -or
            $Release.sha256 -isnot [string] -or $Release.sha256 -notmatch '^[a-fA-F0-9]{64}$') {
            throw 'Ugyldig release-peker (skjema, filnavn eller SHA-256). Ingen reservefil startes automatisk.'
        }
        $Candidate = [IO.Path]::GetFullPath((Join-Path $Dist $Release.executable))
        if ([IO.Path]::GetDirectoryName($Candidate) -ne [IO.Path]::GetFullPath($Dist)) { throw 'Release-filen ligger utenfor desktop/dist.' }
        $CandidateInfo = Get-Item -LiteralPath $Candidate -ErrorAction Stop
        if ($CandidateInfo.PSIsContainer -or $CandidateInfo.LinkType) { throw 'Release-filen må være en vanlig fil, ikke en lenke.' }
        if ((Get-FileHash -LiteralPath $Candidate -Algorithm SHA256 -ErrorAction Stop).Hash -ne $Release.sha256) { throw 'Release-filens SHA-256 stemmer ikke. Ingen reservefil startes automatisk.' }
        if ($ExpectedSha256) { $ExpectedSha256.Value = $Release.sha256 }
        return $Candidate
    }
    $Candidates = @(
        'desktop\dist\AgentSync-Max.exe',
        'desktop\dist\AgentSync-Desktop.exe'
    )
    foreach ($Candidate in $Candidates) {
        $Path = Join-Path $ToolkitRoot $Candidate
        if (Test-Path -LiteralPath $Path -PathType Leaf) { return $Path }
    }
    throw 'AgentSync Max er ikke publisert. Kjør Build-AgentSync-Max.ps1 -Publish først. Ingen eldre lokal kopi startes automatisk.'
}

function Get-AgentSyncDesktopLaunchPlan {
    param(
        [Parameter(Mandatory)][string]$ToolkitRoot,
        [string]$LocalRoot = (Get-AgentSyncDesktopLocalRoot)
    )
    $ToolkitRoot = (Resolve-Path -LiteralPath $ToolkitRoot -ErrorAction Stop).Path
    $ReleaseHash = $null
    $Source = Get-AgentSyncDesktopSource -ToolkitRoot $ToolkitRoot -ExpectedSha256 ([ref]$ReleaseHash)
    $Hash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    if ($ReleaseHash -and $Hash -ne $ReleaseHash) { throw 'Release-filen endret seg etter integritetskontrollen. Ingen oppstart.' }
    $RuntimeDirectory = Join-Path $LocalRoot ('runtime\' + $Hash)
    $RuntimeExecutable = Copy-AgentSyncVerifiedDesktopFile -Source $Source -Destination (Join-Path $RuntimeDirectory 'AgentSync-Max.exe') -ExpectedSha256 $Hash
    # Never infer the data home from the local executable's parent directory.
    return [pscustomobject]@{
        Source = $Source
        Executable = $RuntimeExecutable
        WorkingDirectory = $RuntimeDirectory
        ToolkitRoot = $ToolkitRoot
        Sha256 = $Hash
    }
}

function New-AgentSyncDesktopStartInfo {
    param([Parameter(Mandatory)]$Plan)
    $StartInfo = [Diagnostics.ProcessStartInfo]::new()
    $StartInfo.FileName = $Plan.Executable
    $StartInfo.WorkingDirectory = $Plan.WorkingDirectory
    $StartInfo.UseShellExecute = $false
    $StartInfo.CreateNoWindow = $true
    $StartInfo.Environment['AGENTSYNC_HOME'] = $Plan.ToolkitRoot
    # The GUI is visible; no terminal is opened and the caller's environment is untouched.
    return $StartInfo
}

function Start-AgentSyncDesktopProcess {
    param([Parameter(Mandatory)]$Plan)
    return [Diagnostics.Process]::Start((New-AgentSyncDesktopStartInfo -Plan $Plan))
}

function ConvertTo-AgentSyncSemanticVersion {
    param([Parameter(Mandatory)][string]$Version)

    if ($Version -notmatch '^(?<major>0|[1-9]\d*)\.(?<minor>0|[1-9]\d*)\.(?<patch>0|[1-9]\d*)(?:-(?<pre>[0-9A-Za-z.-]+))?(?:\+(?<build>[0-9A-Za-z.-]+))?$') {
        throw "Ugyldig appversjon: $Version"
    }
    return [pscustomobject]@{
        Major = [uint64]$Matches.major
        Minor = [uint64]$Matches.minor
        Patch = [uint64]$Matches.patch
        Prerelease = [string]$Matches.pre
        Original = $Version
    }
}

function Compare-AgentSyncSemanticVersion {
    param(
        [Parameter(Mandatory)][string]$Left,
        [Parameter(Mandatory)][string]$Right
    )

    $LeftVersion = ConvertTo-AgentSyncSemanticVersion -Version $Left
    $RightVersion = ConvertTo-AgentSyncSemanticVersion -Version $Right
    foreach ($Part in @('Major', 'Minor', 'Patch')) {
        if ($LeftVersion.$Part -lt $RightVersion.$Part) { return -1 }
        if ($LeftVersion.$Part -gt $RightVersion.$Part) { return 1 }
    }
    if (-not $LeftVersion.Prerelease -and -not $RightVersion.Prerelease) { return 0 }
    if (-not $LeftVersion.Prerelease) { return 1 }
    if (-not $RightVersion.Prerelease) { return -1 }

    $LeftParts = @($LeftVersion.Prerelease -split '\.')
    $RightParts = @($RightVersion.Prerelease -split '\.')
    for ($Index = 0; $Index -lt [Math]::Max($LeftParts.Count, $RightParts.Count); $Index++) {
        if ($Index -ge $LeftParts.Count) { return -1 }
        if ($Index -ge $RightParts.Count) { return 1 }
        $LeftNumeric = $LeftParts[$Index] -match '^\d+$'
        $RightNumeric = $RightParts[$Index] -match '^\d+$'
        if ($LeftNumeric -and $RightNumeric) {
            $LeftNumber = [uint64]$LeftParts[$Index]
            $RightNumber = [uint64]$RightParts[$Index]
            if ($LeftNumber -lt $RightNumber) { return -1 }
            if ($LeftNumber -gt $RightNumber) { return 1 }
            continue
        }
        if ($LeftNumeric -ne $RightNumeric) { return $(if ($LeftNumeric) { -1 } else { 1 }) }
        $Comparison = [string]::CompareOrdinal($LeftParts[$Index], $RightParts[$Index])
        if ($Comparison -lt 0) { return -1 }
        if ($Comparison -gt 0) { return 1 }
    }
    return 0
}

function Get-AgentSyncDesktopReleaseVersion {
    param([Parameter(Mandatory)][string]$ExecutableName)

    if ($ExecutableName -notmatch '^AgentSync-Max-(?<version>\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)-[a-fA-F0-9]{12}\.exe$') {
        throw "Kan ikke lese appversjonen fra releasefilen: $ExecutableName"
    }
    [void](ConvertTo-AgentSyncSemanticVersion -Version $Matches.version)
    return $Matches.version
}

function Assert-AgentSyncDesktopCanShowWindow {
    param(
        [string]$WindowsIdentity = ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
    )
    # Codex command tools run on an isolated Windows desktop. A GUI launched
    # there is healthy but invisible on the user's desktop, and its mutex then
    # blocks the visible copy. Fail clearly instead of leaving a hidden app.
    if ($WindowsIdentity -match '(?i)(^|\\)CodexSandbox(?:Offline)?$') {
        throw 'AgentSync MAX kan ikke åpnes synlig fra Codex-verktøyshellet. Start Start-AgentSync-Max.ps1 fra din vanlige PowerShell eller Windows Utforsker.'
    }
}

function Publish-AgentSyncDesktopBuild {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$ToolkitRoot,
        [Parameter(Mandatory)][string]$Version,
        [switch]$SkipLegacyAliases
    )
    [void](ConvertTo-AgentSyncSemanticVersion -Version $Version)
    $Dist = Join-Path $ToolkitRoot 'desktop\dist'
    $Hash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    $Pointer = Join-Path $Dist 'current-release.json'
    if (Test-Path -LiteralPath $Pointer -PathType Leaf) {
        $CurrentSource = Get-AgentSyncDesktopSource -ToolkitRoot $ToolkitRoot
        $CurrentVersion = Get-AgentSyncDesktopReleaseVersion -ExecutableName ([IO.Path]::GetFileName($CurrentSource))
        $VersionOrder = Compare-AgentSyncSemanticVersion -Left $Version -Right $CurrentVersion
        $CurrentHash = (Get-FileHash -LiteralPath $CurrentSource -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if ($VersionOrder -lt 0) {
            throw "Nedgradering er blokkert: gjeldende release er $CurrentVersion, bygget er $Version."
        }
        if ($VersionOrder -eq 0 -and $Hash -ne $CurrentHash) {
            throw "Release $Version finnes allerede med annet innhold. Øk versjonen før publisering."
        }
    }
    # A changed build with the same version retains a separate, immutable backup.
    $Backup = Join-Path $Dist "AgentSync-Max-$Version-$($Hash.Substring(0,12)).exe"
    [void](Copy-AgentSyncVerifiedDesktopFile -Source $Source -Destination $Backup -ExpectedSha256 $Hash)
    $TemporaryPointer = Join-Path $Dist ('.release-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $PointerBytes = [Text.UTF8Encoding]::new($false).GetBytes((@{
            schemaVersion = 1
            version = $Version
            executable = [IO.Path]::GetFileName($Backup)
            sha256 = $Hash
        } | ConvertTo-Json -Compress))
        $PointerStream = [IO.File]::Open($TemporaryPointer, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $PointerStream.Write($PointerBytes, 0, $PointerBytes.Length); $PointerStream.Flush($true) }
        finally { $PointerStream.Dispose() }
        [IO.File]::Move($TemporaryPointer, $Pointer, $true)
    }
    finally { if (Test-Path -LiteralPath $TemporaryPointer -PathType Leaf) { [IO.File]::Delete($TemporaryPointer) } }
    # Distribution is complete now. The launcher follows the verified immutable file,
    # even if an older Dropbox executable is mapped by a still-running app.
    [void](Get-AgentSyncDesktopSource -ToolkitRoot $ToolkitRoot)
    if ($SkipLegacyAliases) { return $Backup }
    foreach ($Name in @('AgentSync-Max.exe', 'AgentSync-Desktop.exe')) {
        $Destination = Join-Path $Dist $Name
        try {
            if (Test-Path -LiteralPath $Destination -PathType Leaf) {
                $PreviousHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
                if ($PreviousHash -eq $Hash) { continue }
                # A mapped/running Windows executable cannot be opened for writing.
                # Do not rename it out from under its running process either.
                $AliasProbe = [IO.File]::Open($Destination, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
                $AliasProbe.Dispose()
                $Previous = Join-Path $Dist "AgentSync-Max-previous-$($PreviousHash.Substring(0,12)).exe"
                [void](Copy-AgentSyncVerifiedDesktopFile -Source $Destination -Destination $Previous -ExpectedSha256 $PreviousHash)
            }
            [void](Copy-AgentSyncVerifiedDesktopFile -Source $Backup -Destination $Destination -ExpectedSha256 $Hash -Replace)
        }
        catch {
            Write-Warning "Ny release er publisert via current-release.json. Eldre '$Name' beholdes fordi den er i bruk eller ikke kunne oppdateres: $($_.Exception.Message)"
        }
    }
    return $Backup
}
