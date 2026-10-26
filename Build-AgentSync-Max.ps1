<#
.SYNOPSIS
    Builds the desktop app into the local disk cache, optionally publishing verified backups.
.DESCRIPTION
    Source stays in the toolkit folder. Cargo output stays in LOCALAPPDATA\AgentSyncMax\cargo-target.
    Does not start/stop the app, move records, or change global Cargo configuration.
#>
#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Release', 'Debug')][string]$Configuration = 'Release',
    [ValidateRange(1, 64)][int]$Jobs = 2,
    [switch]$Offline,
    [switch]$Publish,
    [switch]$SkipLegacyAliases,
    [switch]$SkipTests
)
$ErrorActionPreference = 'Stop'
if ($Publish -and $Configuration -ne 'Release') { throw 'Bare release-bygg kan publiseres som vanlig app.' }

. (Join-Path $PSScriptRoot 'AgentSync.Desktop.ps1')
$LocalRoot = Get-AgentSyncDesktopLocalRoot
$TargetDirectory = Join-Path $LocalRoot 'cargo-target'
$CargoCommand = Get-Command cargo.exe -ErrorAction SilentlyContinue
$CargoExecutable = if ($CargoCommand) { $CargoCommand.Source } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cargo\bin\cargo.exe' }
if (-not (Test-Path -LiteralPath $CargoExecutable -PathType Leaf)) { throw 'Fant ikke cargo.exe. Installer Rust, eller gjør eksisterende Cargo tilgjengelig i PATH.' }
$Manifest = Join-Path $PSScriptRoot 'desktop\src-tauri\Cargo.toml'

# The gate. All three suites run before Cargo builds anything, so a broken rule
# stops the build instead of being noticed after a release. Rust reuses the
# build's own target directory: a second tree would cost gigabytes on a disk
# that does not have them. A runner that cannot run is a failure, never a pass.
if (-not $SkipTests) {
    $TestsPath = Join-Path $PSScriptRoot 'tests'
    if (-not (Test-Path -LiteralPath $TestsPath -PathType Container)) { throw "Fant ikke testmappen $TestsPath. Porten kan ikke kjoere, og da er den ikke bestaatt." }
    if (-not (Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -ge [version]'5.0' })) {
        throw 'Fant ikke Pester 5 eller nyere. En port som ikke kan kjoere er ikke en bestaatt port. Installer Pester, eller velg -SkipTests bevisst.'
    }
    Write-Host "Port 1 av 3, Pester: $TestsPath"
    $TestRun = Invoke-Pester -Path $TestsPath -Output Normal -PassThru
    if (-not $TestRun) { throw 'Pester returnerte ingenting. Bygget stoppes, for et ukjent resultat er ikke et bestaatt resultat.' }
    if ($TestRun.FailedCount -gt 0 -or $TestRun.Result -ne 'Passed') {
        throw "Pester feilet: $($TestRun.FailedCount) av $($TestRun.TotalCount) tester. Den publiserte appen er ikke endret."
    }
    Write-Host "  $($TestRun.PassedCount) Pester-tester bestaatt."

    $NodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
    if (-not $NodeCommand) { $NodeCommand = Get-Command node -ErrorAction SilentlyContinue }
    if (-not $NodeCommand) { throw 'Fant ikke node. Frontend-testene kan ikke kjoere, og da er porten ikke bestaatt.' }
    # node --test on a directory tries to load it as a module; the files must be named.
    $NodeTests = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'desktop\dev') -Filter '*.test.cjs' -File | ForEach-Object { $_.FullName })
    if ($NodeTests.Count -eq 0) { throw 'Fant ingen *.test.cjs i desktop\dev. Porten kan ikke kjoere.' }
    Write-Host "Port 2 av 3, node: $($NodeTests.Count) filer"
    & $NodeCommand.Source '--test' @NodeTests
    if ($LASTEXITCODE -ne 0) { throw "Node-testene feilet (status $LASTEXITCODE). Den publiserte appen er ikke endret." }
    Write-Host '  node-testene bestaatt.'

    Write-Host "Port 3 av 3, Rust: $TargetDirectory"
    $RustArguments = @('test', '--locked', '--manifest-path', $Manifest, '--target-dir', $TargetDirectory, '--jobs', [string]$Jobs)
    if ($Offline) { $RustArguments += '--offline' }
    & $CargoExecutable @RustArguments
    if ($LASTEXITCODE -ne 0) { throw "Rust-testene feilet (status $LASTEXITCODE). Den publiserte appen er ikke endret." }
    Write-Host '  Rust-testene bestaatt.'
}
$CargoArguments = @('build', '--locked', '--manifest-path', $Manifest, '--target-dir', $TargetDirectory, '--jobs', [string]$Jobs)
if ($Configuration -eq 'Release') { $CargoArguments += '--release' }
if ($Offline) { $CargoArguments += '--offline' }
Write-Host "Bygger lokalt: $TargetDirectory"
Push-Location $PSScriptRoot
try {
    & $CargoExecutable @CargoArguments
    if ($LASTEXITCODE -ne 0) { throw "Rust-bygget feilet (status $LASTEXITCODE). Den publiserte appen er ikke endret." }
}
finally { Pop-Location }
$Executable = Join-Path $TargetDirectory ($Configuration.ToLowerInvariant() + '\agentsync-desktop.exe')
if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) { throw 'Cargo avsluttet uten forventet Windows-programfil.' }
if ($Publish) {
    $Config = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'desktop\src-tauri\tauri.conf.json') -Raw | ConvertFrom-Json
    $BuiltVersion = (Get-Item -LiteralPath $Executable).VersionInfo.FileVersion
    if ($BuiltVersion -ne $Config.version) { throw "Bygget versjon '$BuiltVersion' avviker fra '$($Config.version)'. Ingen publisering." }
    $Backup = Publish-AgentSyncDesktopBuild -Source $Executable -ToolkitRoot $PSScriptRoot -Version $Config.version -SkipLegacyAliases:$SkipLegacyAliases
    Write-Host "Verifisert reservekopi: $Backup"
}
Write-Host "Bygget: $Executable"
Write-Host 'Appen er ikke startet eller restartet.'
