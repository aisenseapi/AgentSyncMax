# Optional, local Rust companion. Loading this file starts nothing.
#requires -Version 7.0
. (Join-Path $PSScriptRoot 'AgentSync.Desktop.ps1')

function Get-AgentSyncActiveMemoryLaunchPlan {
    param(
        [Parameter(Mandatory)][string]$ToolkitRoot,
        [string]$LocalRoot = (Get-AgentSyncDesktopLocalRoot)
    )
    # The release pointer, source hash and C: runtime copy are checked by the
    # normal publisher/launcher. Never fall back to a guessed executable.
    $Plan = Get-AgentSyncDesktopLaunchPlan -ToolkitRoot $ToolkitRoot -LocalRoot $LocalRoot
    $Name = [IO.Path]::GetFileName($Plan.Source)
    if ($Name -notmatch '^AgentSync-Max-(?<version>.+)-[a-fA-F0-9]{12}\.exe$' -or
        (Compare-AgentSyncSemanticVersion $Matches.version '4.26.1') -lt 0) {
        throw 'Bakgrunnsminne krever publisert MAX 4.26.1 eller nyere. Ingen eldre app startes uten vindu.'
    }
    return $Plan
}

function New-AgentSyncActiveMemoryStartInfo {
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$ParentProcessId
    )
    $StartInfo = New-AgentSyncDesktopStartInfo -Plan $Plan
    $StartInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    [void]$StartInfo.ArgumentList.Add('--active-memory-worker')
    [void]$StartInfo.ArgumentList.Add('--parent-pid')
    [void]$StartInfo.ArgumentList.Add([string]$ParentProcessId)
    return $StartInfo
}

function Start-AgentSyncActiveMemoryWorker {
    param(
        [Parameter(Mandatory)][string]$ToolkitRoot,
        [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$ParentProcessId,
        [string]$LocalRoot = (Get-AgentSyncDesktopLocalRoot)
    )
    if (-not $IsWindows) { return $null }
    # Rust also pins the live parent's creation identity, holds a worker lock,
    # and exits when that parent dies. This check catches invalid launch input.
    $ParentProcess = Get-Process -Id $ParentProcessId -ErrorAction Stop
    if ($ParentProcess.HasExited) { throw 'Synkemotoren har allerede stoppet.' }
    $Plan = Get-AgentSyncActiveMemoryLaunchPlan -ToolkitRoot $ToolkitRoot -LocalRoot $LocalRoot
    return [Diagnostics.Process]::Start((New-AgentSyncActiveMemoryStartInfo -Plan $Plan -ParentProcessId $ParentProcessId))
}
