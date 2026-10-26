<#
.SYNOPSIS
    Starts AgentSync Max, the native desktop control surface, on Windows.
#>

#requires -Version 7.0

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'AgentSync.Desktop.ps1')

Assert-AgentSyncDesktopCanShowWindow
$Plan = Get-AgentSyncDesktopLaunchPlan -ToolkitRoot $PSScriptRoot
$Process = Start-AgentSyncDesktopProcess -Plan $Plan
if (-not $Process) {
    throw 'AgentSync MAX kunne ikke startes fra den verifiserte lokale runtimekopien.'
}
