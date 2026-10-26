<#
.SYNOPSIS
    Starts AgentSync Toolkit from the chosen tool folder.
    Works on Windows, macOS and Linux (requires PowerShell 7+ / pwsh).
#>

#requires -Version 7.0

$ErrorActionPreference = "Stop"

# Locate the AgentSync home. AGENTSYNC_HOME overrides the default.
$AgentSyncHome = $env:AGENTSYNC_HOME

if ([string]::IsNullOrWhiteSpace($AgentSyncHome)) {
    # First choice is the folder the bootstrap script itself lives in.
    $LocalMainScript = Join-Path $PSScriptRoot "Sync-AgentState.ps1"
    $LocalConfigFile = Join-Path $PSScriptRoot "config.json"

    if ((Test-Path -LiteralPath $LocalMainScript) -and (Test-Path -LiteralPath $LocalConfigFile)) {
        $AgentSyncHome = $PSScriptRoot
    }
    else {
        # Backward-compatible fallback for earlier installations.
        $AgentSyncHome = Join-Path $HOME "Dropbox" "Tools" "AgentSync"
    }
}

$MainScript = Join-Path $AgentSyncHome "Sync-AgentState.ps1"
$ProcessHelpers = Join-Path $AgentSyncHome 'AgentSync.Process.ps1'
$ConfigFile = Join-Path $AgentSyncHome "config.json"

# Wait until the files are synchronized (useful when the tool folder lives in Dropbox/OneDrive/Syncthing)
$Waited = 0
$MaxWaitSeconds = 120
while ((-not (Test-Path -LiteralPath $MainScript)) -or (-not (Test-Path -LiteralPath $ConfigFile)) -or
       (-not (Test-Path -LiteralPath $ProcessHelpers -PathType Leaf))) {
    if ($Waited -ge $MaxWaitSeconds) {
        Write-Error "AgentSync files not found after $MaxWaitSeconds seconds: $AgentSyncHome"
        exit 1
    }
    Write-Warning "Waiting for the AgentSync files to become available... ($Waited s)"
    Start-Sleep -Seconds 3
    $Waited += 3
}

# A machine-specific config.local.json overrides the shared config.json.
$LocalConfigFile = Join-Path $AgentSyncHome "config.local.json"
if (Test-Path -LiteralPath $LocalConfigFile) {
    $ConfigFile = $LocalConfigFile
}

try {
    $Config = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
}
catch {
    Write-Error "Could not read the AgentSync configuration: $($_.Exception.Message)"
    exit 1
}

Write-Host "Starting AgentSync Toolkit..." -ForegroundColor Green
Write-Host "  Home: $AgentSyncHome"
Write-Host "  Config: $ConfigFile"
Write-Host "  Platform: $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)"

& $MainScript -ConfigFile $ConfigFile @args
