#requires -Version 7.0
<#
.SYNOPSIS
Plans or applies the local Dropbox ignore split for mission records/checkpoints.
.DESCRIPTION
Default is read-only. -Apply first protects the exact existing checkpoints
directory, verifies that marker, then removes ONLY the parent's ignore stream.
No files, archives, conflict copies or directories are deleted or moved.
Stop writers first when applying. This is not a transaction with Dropbox and
does not confirm upload: check the Dropbox client after the local change.
#>
[CmdletBinding(SupportsShouldProcess)]
param (
    [string]$ToolkitPath = $PSScriptRoot,
    [switch]$Apply
)

function Test-AgentSyncCloudReparseTag {
    param ([uint32]$Tag)
    # Microsoft's CLOUD..CLOUD_F family, not name-surrogate links.
    return (($Tag -band [Convert]::ToUInt32('FFFF0FFF', 16)) -eq [Convert]::ToUInt32('9000001A', 16))
}

function Assert-AgentSyncStorageItem {
    param ([string]$Path)
    $Item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($Item.LinkType -or $Item.Target) { throw "Linked target is not allowed: $Path" }
    if (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        $Output = @(& fsutil.exe reparsepoint query $Item.FullName 2>&1)
        $Exit = $LASTEXITCODE
        $Match = [regex]::Match(($Output -join [Environment]::NewLine), '(?i)0x[0-9a-f]{8}')
        if ($Exit -ne 0 -or -not $Match.Success) { throw "Cannot verify reparse tag: $Path" }
        $Tag = [Convert]::ToUInt32($Match.Value.Substring(2), 16)
        if (-not (Test-AgentSyncCloudReparseTag -Tag $Tag)) { throw "Unsupported reparse target: $Path" }
    }
    return $Item
}

function Get-AgentSyncDropboxIgnored {
    param ([string]$Path)
    $Streams = @(Get-Item -LiteralPath $Path -Stream '*' -ErrorAction Stop)
    $Marker = @($Streams | Where-Object Stream -EQ 'com.dropbox.ignored')
    if ($Marker.Count -eq 0) { return $false }
    $Value = Get-Content -LiteralPath $Path -Stream 'com.dropbox.ignored' -Raw -ErrorAction Stop
    # Dropbox documents clearing the stream to make the directory sync again.
    if ([string]::IsNullOrEmpty($Value)) { return $false }
    $Value = $Value.Trim()
    if ($Value -ne '1') { throw "Unrecognized Dropbox ignore marker on: $Path" }
    return $true
}

function Assert-AgentSyncCheckpointsAvailable {
    param ([string]$Path)
    # Metadata only; never hydrate backup contents merely to change a marker.
    $Queue = [System.Collections.Generic.Queue[string]]::new()
    $Queue.Enqueue($Path)
    $Count = 0
    while ($Queue.Count -gt 0) {
        $Directory = $Queue.Dequeue()
        [void](Assert-AgentSyncStorageItem -Path $Directory)
        foreach ($Entry in Get-ChildItem -LiteralPath $Directory -Force -ErrorAction Stop) {
            if (++$Count -gt 50000) { throw 'Checkpoint availability audit exceeds 50000 entries; inspect separately.' }
            if ($Entry.LinkType -or $Entry.Target) { throw "Linked checkpoint entry retained: $($Entry.FullName)" }
            # OFFLINE, RECALL_ON_OPEN and RECALL_ON_DATA_ACCESS.
            if (([long]$Entry.Attributes -band 0x441000) -ne 0) {
                throw "Checkpoint entry is not fully local; make it available offline first: $($Entry.FullName)"
            }
            if ($Entry.PSIsContainer) { $Queue.Enqueue($Entry.FullName) }
        }
    }
}

function Get-AgentSyncStoragePlan {
    param ([string]$ToolkitPath)
    if (-not $IsWindows) { throw 'This maintenance script is for Dropbox on Windows.' }
    if (-not [System.IO.Path]::IsPathFullyQualified($ToolkitPath)) { throw 'An absolute toolkit path is required.' }
    $Root = [System.IO.Path]::GetFullPath($ToolkitPath).TrimEnd('\', '/')
    if ($Root -eq [System.IO.Path]::GetPathRoot($Root).TrimEnd('\', '/') -or
        $Root -eq [Environment]::GetFolderPath('UserProfile').TrimEnd('\', '/')) {
        throw 'A drive root or user profile cannot be a maintenance target.'
    }
    # Resolve and check every existing ancestor without following junctions.
    $Ancestor = $Root
    while ($Ancestor) {
        [void](Assert-AgentSyncStorageItem -Path $Ancestor)
        $Parent = [System.IO.Directory]::GetParent($Ancestor)
        $Ancestor = if ($Parent) { $Parent.FullName } else { $null }
    }
    foreach ($Marker in @('Sync-AgentState.ps1', 'config.json')) {
        $MarkerItem = Assert-AgentSyncStorageItem -Path (Join-Path $Root $Marker)
        if ($MarkerItem.PSIsContainer) { throw "Toolkit marker is not a file: $Marker" }
    }
    $Missions = Join-Path $Root 'missions'
    $MissionItem = Assert-AgentSyncStorageItem -Path $Missions
    if (-not $MissionItem.PSIsContainer) { throw 'missions must be a directory.' }
    $Checkpoints = Join-Path $Missions 'checkpoints'
    $CheckpointExists = Test-Path -LiteralPath $Checkpoints
    if ($CheckpointExists -and -not (Assert-AgentSyncStorageItem -Path $Checkpoints).PSIsContainer) {
        throw 'checkpoints must be a directory.'
    }

    # Inspect metadata before allowing uploads. Preserve conflict leftovers but
    # refuse unfamiliar directories/large files, rather than guessing them local.
    $Queue = [System.Collections.Generic.Queue[string]]::new()
    $Queue.Enqueue($Missions)
    $Files = 0
    $Entries = 0
    [long]$Bytes = 0
    $Conflicts = [System.Collections.Generic.List[string]]::new()
    while ($Queue.Count -gt 0) {
        $Directory = $Queue.Dequeue()
        foreach ($Entry in Get-ChildItem -LiteralPath $Directory -Force -ErrorAction Stop) {
            $Entries++
            [void](Assert-AgentSyncStorageItem -Path $Entry.FullName)
            if ($Entry.FullName.Equals($Checkpoints, [StringComparison]::OrdinalIgnoreCase)) { continue }
            if ($Entry.PSIsContainer) {
                if ($Directory -eq $Missions -and $Entry.Name -ne 'evaluations') {
                    throw "Unclassified mission directory retained; inspect before enabling sync: $($Entry.FullName)"
                }
                $Queue.Enqueue($Entry.FullName)
            }
            else {
                $Files++
                $Bytes += $Entry.Length
                if ($Entry.Name -match '(?i)conflict|conflicted|kopi|copy') { $Conflicts.Add($Entry.FullName) }
                if ($Entry.Length -gt 16MB) { throw "Large mission file retained; inspect before enabling sync: $($Entry.FullName)" }
                if ($Entry.Extension -notin @('.json', '.jsonl', '.tmp')) {
                    throw "Unclassified mission file retained; inspect before enabling sync: $($Entry.FullName)"
                }
            }
            if ($Entries -gt 10000 -or $Bytes -gt 256MB) {
                throw 'Mission metadata exceeds the bounded maintenance audit; inspect manually.'
            }
        }
    }
    $ParentIgnored = Get-AgentSyncDropboxIgnored -Path $Missions
    $CheckpointIgnored = if ($CheckpointExists) { Get-AgentSyncDropboxIgnored -Path $Checkpoints } else { $false }
    return [PSCustomObject]@{
        ToolkitPath = $Root; MissionsPath = $Missions; CheckpointsPath = $Checkpoints
        CheckpointsExist = $CheckpointExists
        MissionsIgnored = $ParentIgnored; CheckpointsIgnored = $CheckpointIgnored
        DurableFiles = $Files; DurableBytes = $Bytes; ConflictFilesRetained = $Conflicts.ToArray()
        NeedsChange = ($ParentIgnored -or ($CheckpointExists -and -not $CheckpointIgnored))
        Applied = $false
    }
}

function Set-AgentSyncStorageSplit {
    param ([string]$ToolkitPath)
    $Plan = Get-AgentSyncStoragePlan -ToolkitPath $ToolkitPath
    if ($Plan.CheckpointsExist -and -not $Plan.CheckpointsIgnored -and -not $Plan.MissionsIgnored) {
        throw 'Refusing a new cloud exclusion: neither missions nor checkpoints is currently ignored. Review backup policy separately.'
    }
    if ($Plan.MissionsIgnored -and -not $Plan.CheckpointsExist) {
        throw 'No existing checkpoints directory to protect. The parent remains unchanged; review storage setup separately.'
    }
    if ($Plan.CheckpointsExist) {
        if (-not $Plan.CheckpointsIgnored) {
            Assert-AgentSyncCheckpointsAvailable -Path $Plan.CheckpointsPath
            Set-Content -LiteralPath $Plan.CheckpointsPath -Stream 'com.dropbox.ignored' -Value 1 -ErrorAction Stop
        }
        if (-not (Get-AgentSyncDropboxIgnored -Path $Plan.CheckpointsPath)) {
            throw 'Checkpoint ignore verification failed. The parent remains unchanged.'
        }
    }
    # Recheck paths and unfamiliar entries immediately before releasing parent.
    # No distributed atomicity is claimed. Run while mission writers are stopped.
    $Verified = Get-AgentSyncStoragePlan -ToolkitPath $Plan.ToolkitPath
    if ($Verified.CheckpointsExist -and -not $Verified.CheckpointsIgnored) {
        throw 'Checkpoints changed during maintenance. The parent remains unchanged.'
    }
    if ($Verified.MissionsIgnored) {
        Clear-Content -LiteralPath $Verified.MissionsPath -Stream 'com.dropbox.ignored' -ErrorAction Stop
    }
    $Result = Get-AgentSyncStoragePlan -ToolkitPath $Plan.ToolkitPath
    if ($Result.MissionsIgnored -or ($Result.CheckpointsExist -and -not $Result.CheckpointsIgnored)) {
        throw 'Local ignore verification did not match the planned split.'
    }
    $Result.Applied = $true
    return $Result
}

$Plan = Get-AgentSyncStoragePlan -ToolkitPath $ToolkitPath
if ($Apply -and $PSCmdlet.ShouldProcess($Plan.MissionsPath, 'Keep exact checkpoints local and enable durable mission records for Dropbox sync')) {
    Set-AgentSyncStorageSplit -ToolkitPath $Plan.ToolkitPath
}
else { $Plan }
