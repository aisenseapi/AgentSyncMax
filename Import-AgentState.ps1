#requires -Version 7.0
<#
.SYNOPSIS
    Plans a conservative manual restore of verified native session files.
.DESCRIPTION
    The sync engine already has provider-specific restore paths. This manual
    tool is narrower: Claude/Codex JSONL with a verified current project
    identity, missing destinations only. Existing divergent files, unknown
    identities and providers needing their own import protocol are blocked.
    No writes without -Apply. A blocked plan writes nothing. During Apply,
    each file is verified and published without replacement. If a later file
    fails, earlier successful copies are reported and retained.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory=$true)][string]$ProjectRoot,
    [string]$Agent,
    [string]$ConfigFile,
    [switch]$Apply
)
$ErrorActionPreference = 'Stop'

function Expand-AgentSyncPath {
    param ([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $Expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ($Expanded -eq '~' -or $Expanded.StartsWith('~/') -or $Expanded.StartsWith('~\')) {
        $Profile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
        $Expanded = Join-Path $Profile $Expanded.Substring(1).TrimStart('/', '\')
    }
    if (-not [IO.Path]::IsPathFullyQualified($Expanded)) { throw 'Import paths must be absolute.' }
    return [IO.Path]::GetFullPath($Expanded)
}

function Get-PlatformPath {
    param ($AgentConfig)
    $Candidates = if ($IsWindows) { @('localPathWindows','localPath') } elseif ($IsMacOS) { @('localPathMacOS','localPath') } else { @('localPathLinux','localPath') }
    foreach ($Name in $Candidates) {
        $Value = $AgentConfig.PSObject.Properties[$Name]
        if ($Value -and -not [string]::IsNullOrWhiteSpace([string]$Value.Value)) { return Expand-AgentSyncPath ([string]$Value.Value) }
    }
    return $null
}

function Assert-AgentSyncImportPath {
    param ([string]$Path, [switch]$KeepDirectoryLeases)
    # Metadata-only OPEN_REPARSE_POINT handles distinguish Cloud Files from
    # junctions without hydrating payloads. Windows directory read leases deny
    # rename/deletion during publication. Other platforms support planning only.
    if ($IsWindows -and -not ('AgentSyncImportPathHandle' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class AgentSyncImportPathHandle {
    public static bool IsCloudTag(uint tag) { return (tag & 0xFFFF0FFFu) == 0x9000001Au; }
    [StructLayout(LayoutKind.Sequential)] struct TagInfo { public uint Attributes, Tag; }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetFileInformationByHandleEx(SafeFileHandle handle, int kind, out TagInfo info, uint size);
    public static SafeFileHandle Open(string path, bool directoryLease) {
        // Zero-access metadata handles do not enforce delete sharing. A real
        // directory read lease is needed to prevent replacement/rename.
        var h = CreateFileW(path, directoryLease ? 1u : 0u, directoryLease ? 3u : 7u, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
        if (h.IsInvalid) { int e=Marshal.GetLastWin32Error(); h.Dispose(); throw new Win32Exception(e, "Cannot verify import path: " + path); }
        TagInfo info;
        if (!GetFileInformationByHandleEx(h, 9, out info, 8)) { int e=Marshal.GetLastWin32Error(); h.Dispose(); throw new Win32Exception(e); }
        if ((info.Attributes & 0x400) != 0 && !IsCloudTag(info.Tag)) {
            h.Dispose(); throw new System.IO.IOException("Import refuses a symlink, junction or unverified reparse point.");
        }
        return h;
    }
}
'@ -ErrorAction Stop
    }
    $Full = [IO.Path]::GetFullPath($Path)
    $Ancestors = [Collections.Generic.Stack[string]]::new()
    $Current = $Full
    while ($Current) { $Ancestors.Push($Current); $Current = [IO.Path]::GetDirectoryName($Current) }
    $Leases = [Collections.Generic.List[IDisposable]]::new()
    try {
        foreach ($Part in $Ancestors) {
            try { $Item = Get-Item -LiteralPath $Part -Force -ErrorAction Stop }
            catch [Management.Automation.ItemNotFoundException] { continue }
            if ($IsWindows) {
                $Handle = [AgentSyncImportPathHandle]::Open($Part, ($KeepDirectoryLeases -and $Item.PSIsContainer))
                if ($KeepDirectoryLeases -and $Item.PSIsContainer) { $Leases.Add($Handle) } else { $Handle.Dispose() }
            }
            elseif (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $Item.LinkType) { throw 'Import refuses symlinks.' }
        }
        return ,$Leases
    }
    catch { foreach ($Lease in $Leases) { $Lease.Dispose() }; throw }
}

function Get-AgentSyncImportFiles {
    param ([string]$Root)
    # Reject a junction before traversing it; access errors are not empty data.
    $null = Assert-AgentSyncImportPath $Root
    foreach ($Item in Get-ChildItem -LiteralPath $Root -Force -ErrorAction Stop) {
        $null = Assert-AgentSyncImportPath $Item.FullName
        if ($Item.PSIsContainer) { Get-AgentSyncImportFiles $Item.FullName } else { $Item }
    }
}

function Get-AgentSyncImportFileState {
    param ([string]$Path, [switch]$ValidateJsonl)
    $null = Assert-AgentSyncImportPath $Path
    $Stream = [IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $Hash = [Security.Cryptography.SHA256]::Create()
    $Reader = $null
    try {
        if ($Stream.Length -gt 256MB) { throw 'File exceeds the bounded manual import validation.' }
        $Digest = [Convert]::ToHexString($Hash.ComputeHash($Stream))
        $Cwd = $null
        if ($ValidateJsonl) {
            if ($Stream.Length -eq 0 -or $Stream.Length -gt 256MB) { throw 'JSONL is empty or exceeds the manual import validation bound.' }
            $Stream.Position = 0
            $Reader = [IO.StreamReader]::new($Stream,[Text.UTF8Encoding]::new($false,$true),$true,65536,$true)
            $Lines = 0
            while (-not $Reader.EndOfStream) {
                $Line = $Reader.ReadLine()
                if ([string]::IsNullOrWhiteSpace($Line)) { continue }
                if ($Line.Length -gt 8MB) { throw 'JSONL record exceeds the manual import validation bound.' }
                try { $Object = $Line | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
                catch { throw 'INVALID_JSONL' }
                $Lines++
                if (-not $Cwd -and $Lines -le 100) {
                    if ($Object.cwd) { $Cwd = [string]$Object.cwd }
                    elseif ($Object.type -eq 'session_meta' -and $Object.payload.cwd) { $Cwd = [string]$Object.payload.cwd }
                }
            }
            if ($Lines -eq 0) { throw 'JSONL contains no records.' }
        }
        return [pscustomobject]@{Hash=$Digest;Length=$Stream.Length;Cwd=$Cwd}
    }
    finally { if ($Reader) {$Reader.Dispose()}; $Hash.Dispose(); $Stream.Dispose() }
}

function Get-AgentSyncImportPlan {
    param ([string]$ProjectRoot, $Config, [string]$Agent)
    $Project = Expand-AgentSyncPath $ProjectRoot
    $State = Join-Path $Project '.agent-state'
    $null = Assert-AgentSyncImportPath $State
    if (-not (Test-Path -LiteralPath $State -PathType Container)) { throw 'Project has no .agent-state directory.' }
    $Copies = [Collections.Generic.List[object]]::new()
    $Problems = [Collections.Generic.List[string]]::new()
    $Identical=0; $PreservedElsewhere=0; $Files=0; $Selected=0
    $Comparison = if ($IsWindows) {[StringComparison]::OrdinalIgnoreCase} else {[StringComparison]::Ordinal}
    foreach ($Entry in @($Config.agents)) {
        $Name = [string]$Entry.name
        if ($Agent -and $Name -ne $Agent) { continue }
        $Selected++
        $SubDir = [string]$Entry.targetSubDir
        if ([string]::IsNullOrWhiteSpace($SubDir) -or [IO.Path]::IsPathRooted($SubDir) -or @($SubDir -split '[\\/]' | Where-Object {$_ -in @('..','.')}).Count) { throw 'Unsafe or missing targetSubDir.' }
        $Source = [IO.Path]::GetFullPath((Join-Path $Project $SubDir))
        if (-not $Source.StartsWith($State+[IO.Path]::DirectorySeparatorChar,$Comparison)) { throw 'Source must remain inside project .agent-state.' }
        $null = Assert-AgentSyncImportPath $Source
        if (-not (Test-Path -LiteralPath $Source -PathType Container)) { continue }
        if ($Entry.enabled -eq $false) { $Problems.Add("$Name : AGENT_DISABLED"); continue }
        if ([string]$Entry.routingMode -notin @('claude','codex')) {
            $Problems.Add("$Name : PROVIDER_RESTORE_UNSUPPORTED (requires its provider-specific restore path; roots configuration is not a missing-path error)")
            continue
        }
        $Target = Get-PlatformPath $Entry
        if (-not $Target) { $Problems.Add("$Name : LOCAL_PATH_MISSING"); continue }
        if ($Target.Equals($Project,$Comparison) -or $Target.StartsWith($Project+[IO.Path]::DirectorySeparatorChar,$Comparison) -or $Project.StartsWith($Target.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar,$Comparison)) { throw 'Native target and project must not contain one another.' }
        $null = Assert-AgentSyncImportPath $Target
        $SkipFiles = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($Configured in @($Entry.skipRestoreIfPresentIn)) {
            if (-not $Configured) { continue }
            $SkipRoot = Expand-AgentSyncPath ([string]$Configured)
            $null = Assert-AgentSyncImportPath $SkipRoot
            if (Test-Path -LiteralPath $SkipRoot -PathType Container) {
                foreach ($Saved in @(Get-AgentSyncImportFiles $SkipRoot)) {
                    if (-not $SkipFiles.ContainsKey($Saved.Name)) { $SkipFiles[$Saved.Name] = [Collections.Generic.List[string]]::new() }
                    $SkipFiles[$Saved.Name].Add($Saved.FullName)
                }
            }
        }
        foreach ($File in @(Get-AgentSyncImportFiles $Source)) {
            $Files++
            if ($File.Extension -ne '.jsonl' -or $File.Name -match '(?i)conflict') { $Problems.Add("$Name : UNVERIFIED_FILE_FORMAT"); continue }
            try {
                $Info = Get-AgentSyncImportFileState $File.FullName -ValidateJsonl
                if (-not $Info.Cwd -or -not ([IO.Path]::GetFullPath($Info.Cwd).TrimEnd('\','/')).Equals($Project.TrimEnd('\','/'),$Comparison)) { throw 'PROJECT_IDENTITY_UNVERIFIED' }
                $Relative = [IO.Path]::GetRelativePath($Source,$File.FullName)
                if ($Entry.routingMode -eq 'claude') {
                    $Segments = @($Relative -split '[\\/]')
                    $Slug = $Project.TrimEnd('\','/') -replace '[^A-Za-z0-9]','-'
                    if ($Segments.Count -lt 2 -or $Segments[0] -ne $Slug) { throw 'CLAUDE_BUCKET_UNVERIFIED' }
                }
                $Destination = [IO.Path]::GetFullPath((Join-Path $Target $Relative))
                if (-not $Destination.StartsWith($Target.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar,$Comparison)) { throw 'TARGET_OUTSIDE_ROOT' }
                $null = Assert-AgentSyncImportPath $Destination
                if ($SkipFiles.ContainsKey($File.Name)) {
                    # A filename preserves the user's archive choice, not proof
                    # of content. Require one verified identical candidate.
                    $ArchiveIdentical = $false
                    foreach ($SavedPath in $SkipFiles[$File.Name]) {
                        try {
                            if ((Get-AgentSyncImportFileState $SavedPath).Hash -eq $Info.Hash) { $ArchiveIdentical = $true; break }
                        }
                        catch { } # An unreadable candidate is never a match.
                    }
                    if ($ArchiveIdentical) { $PreservedElsewhere++ }
                    else { $Problems.Add("$Name : ARCHIVED_CONTENT_UNVERIFIED") }
                    continue
                }
                if (Test-Path -LiteralPath $Destination) {
                    $Existing = Get-AgentSyncImportFileState $Destination
                    if ($Existing.Hash -eq $Info.Hash) { $Identical++ } else { $Problems.Add("$Name : EXISTING_CONTENT_DIFFERS") }
                    continue
                }
                $Copies.Add([pscustomobject]@{Agent=$Name;Source=$File.FullName;Destination=$Destination;Hash=$Info.Hash;Length=$Info.Length})
            }
            catch {
                # Parser exceptions may contain source text. Only fixed reason
                # codes leave this boundary, never a raw JSONL excerpt.
                $Reason = [string]$_.Exception.Message
                if ($Reason -notmatch '^[A-Z_]+$') { $Reason = 'READ_OR_VALIDATION_FAILED' }
                $Problems.Add("$Name : FILE_UNVERIFIED ($Reason)")
            }
        }
    }
    if ($Agent -and $Selected -eq 0) { $Problems.Add('AGENT_NOT_CONFIGURED') }
    return [pscustomobject]@{ProjectRoot=$Project;Files=$Files;ToCopy=$Copies.Count;Identical=$Identical;PreservedElsewhere=$PreservedElsewhere;Blocked=$Problems.Count;Problems=$Problems.ToArray();Copies=$Copies.ToArray()}
}

function Copy-AgentSyncImportFile {
    param ($File)
    if (-not $IsWindows) { throw 'Apply requires verified Windows directory leases; this platform supports planning only.' }
    $SourceLeases=$null; $TargetLeases=$null; $SourceStream=$null; $StageStream=$null; $Hash=$null; $Stage=$null
    try {
        $SourceLeases = Assert-AgentSyncImportPath $File.Source -KeepDirectoryLeases
        $Parent = [IO.Path]::GetDirectoryName($File.Destination)
        $TargetLeases = Assert-AgentSyncImportPath $Parent -KeepDirectoryLeases
        [void][IO.Directory]::CreateDirectory($Parent)
        $Additional = Assert-AgentSyncImportPath $Parent -KeepDirectoryLeases
        foreach ($Lease in $Additional) { $TargetLeases.Add($Lease) }
        if (Test-Path -LiteralPath $File.Destination) { throw 'Destination appeared after the plan; nothing replaced.' }
        $SourceStream=[IO.FileStream]::new($File.Source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $Hash=[Security.Cryptography.SHA256]::Create()
        if ([Convert]::ToHexString($Hash.ComputeHash($SourceStream)) -ne $File.Hash) { throw 'Source changed after the plan.' }
        $SourceStream.Position=0
        $Stage=Join-Path $Parent ('.agentsync-import-'+[guid]::NewGuid().ToString('N')+'.tmp')
        $StageStream=[IO.FileStream]::new($Stage,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $SourceStream.CopyTo($StageStream); $StageStream.Flush($true); $StageStream.Position=0
        if ($StageStream.Length -ne $File.Length -or [Convert]::ToHexString($Hash.ComputeHash($StageStream)) -ne $File.Hash) { throw 'Staged import failed verification.' }
        $StageStream.Dispose(); $StageStream=$null
        [IO.File]::SetLastWriteTimeUtc($Stage,[IO.File]::GetLastWriteTimeUtc($File.Source))
        [IO.File]::Move($Stage,$File.Destination,$false)
        $Stage=$null
    }
    finally {
        if($StageStream){$StageStream.Dispose()}; if($SourceStream){$SourceStream.Dispose()}; if($Hash){$Hash.Dispose()}
        if($Stage -and [IO.File]::Exists($Stage)){[IO.File]::Delete($Stage)}
        foreach($Lease in $TargetLeases){$Lease.Dispose()}; foreach($Lease in $SourceLeases){$Lease.Dispose()}
    }
}

function Invoke-AgentSyncImportPlan {
    param ($Plan)
    if ($Plan.Blocked -gt 0) { throw "Import blocked: $($Plan.Blocked) unresolved item(s). No files copied." }
    $Copied=0
    foreach ($File in $Plan.Copies) {
        try { Copy-AgentSyncImportFile $File; $Copied++ }
        catch { throw "Import stopped after $Copied verified file(s); earlier copies retained. $($_.Exception.Message)" }
    }
    return $Copied
}

if (-not $ConfigFile) {
    $Local=Join-Path $PSScriptRoot 'config.local.json'
    $ConfigFile=if(Test-Path -LiteralPath $Local){$Local}else{Join-Path $PSScriptRoot 'config.json'}
}
$Config=Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
$Plan=Get-AgentSyncImportPlan -ProjectRoot $ProjectRoot -Config $Config -Agent $Agent
Write-Host "Prosjekt: $($Plan.ProjectRoot)"
Write-Host "Plan: $($Plan.ToCopy) manglende filer, $($Plan.Identical) innholdslike, $($Plan.PreservedElsewhere) bevart annet sted, $($Plan.Blocked) uavklarte."
foreach($Problem in $Plan.Problems){Write-Host $Problem -ForegroundColor Yellow}
if($Apply){$Copied=Invoke-AgentSyncImportPlan $Plan; Write-Host "Kopierte og verifiserte $Copied filer. Dette er ikke en test av at agenten kan gjenoppta oektene."}
elseif($Plan.Blocked){Write-Host 'Ingen filer skrevet. Uavklarte punkter maa avklares foer -Apply.' -ForegroundColor Yellow}
else{Write-Host 'Ingen filer skrevet. -Apply oppretter bare verifiserte, manglende filer; eksisterende innhold erstattes aldri.'}
