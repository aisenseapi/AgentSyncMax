# Count actual identity resolution, without replacing routing or filesystem
# checks. These fixtures exercise status collection, not the sync write path.
BeforeAll {
    $EnginePath = Join-Path $PSScriptRoot '..\Sync-AgentState.ps1'
    $Tokens = $null
    $ParseErrors = $null
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile($EnginePath, [ref]$Tokens, [ref]$ParseErrors)
    if ($ParseErrors.Count -gt 0) { throw $ParseErrors[0].Message }
    $Names = @(
        'Expand-PortablePath', 'Expand-ConfiguredPath', 'Test-PathInside',
        'Get-RelativeChildPath', 'Test-SamePath', 'Remove-AgentInternalWorkspaceSuffix',
        'Resolve-StatusAgentProject', 'Test-CanonicalStorageProject',
        'ConvertTo-StatusTime', 'New-StatusAgentMetric', 'Add-StatusAgentFiles'
    )
    foreach ($Function in $Ast.FindAll({
        param($Node)
        $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Names -contains $Node.Name
    }, $false)) {
        $Definition = $Function.Extent.Text
        if ($Function.Name -eq 'Resolve-StatusAgentProject') {
            $Definition = $Definition -replace '^function Resolve-StatusAgentProject', 'function Invoke-ActualStatusIdentityResolution'
        }
        . ([scriptblock]::Create($Definition))
    }
    function Resolve-StatusAgentProject {
        param ([string]$Cwd, [string]$StorageProjectRoot)
        $Script:ResolutionCalls++
        Invoke-ActualStatusIdentityResolution -Cwd $Cwd -StorageProjectRoot $StorageProjectRoot
    }
    function Add-FixtureStatusFile {
        param ([string]$Cwd, [string]$StorageProjectRoot)
        Add-StatusAgentFiles -ProjectMap $Script:ProjectMap -Cwd $Cwd -StorageProjectRoot $StorageProjectRoot `
            -AgentName 'claude' -Files @($Script:FixtureFile) -Machines @('TESTHOST') -SessionId 'test-session'
    }
}

Describe 'Status identity reuse' {
    BeforeEach {
        $Script:ProjectsBasePath = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $Script:ProjectsBasePath)
        $Script:PathComparison = [System.StringComparison]::OrdinalIgnoreCase
        $Script:Config = [PSCustomObject]@{ projectAliases = $null }
        $Script:ProjectMap = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $Script:ResolutionCalls = 0
        $FilePath = Join-Path $TestDrive 'synthetic-status-session.jsonl'
        [System.IO.File]::WriteAllText($FilePath, '{}')
        $Script:FixtureFile = Get-Item -LiteralPath $FilePath
    }

    It 'resolves a same-project file once and preserves its metrics' {
        $Project = Join-Path $Script:ProjectsBasePath 'Project'
        [void](New-Item -ItemType Directory -Path $Project)

        Add-FixtureStatusFile -Cwd $Project -StorageProjectRoot $Project | Should -BeTrue

        $Script:ResolutionCalls | Should -Be 1
        $Script:ProjectMap.Count | Should -Be 1
        $Row = $Script:ProjectMap['Project']
        $Row.ProjectPath | Should -Be $Project
        $Row.Claude.Files | Should -Be 1
        $Row.Claude.Bytes | Should -Be $Script:FixtureFile.Length
        $Row.Claude.SessionIds.Contains('test-session') | Should -BeTrue
        $Row.MachineSet.Contains('TESTHOST') | Should -BeTrue
    }

    It 'keeps an exact nested project distinct from its parent' {
        $Parent = Join-Path $Script:ProjectsBasePath 'Project'
        $Child = Join-Path $Parent 'backend'
        [void](New-Item -ItemType Directory -Path $Child -Force)

        Add-FixtureStatusFile -Cwd $Parent -StorageProjectRoot $Parent | Should -BeTrue
        Add-FixtureStatusFile -Cwd $Child -StorageProjectRoot $Child | Should -BeTrue

        $Script:ResolutionCalls | Should -Be 2
        $Script:ProjectMap.Count | Should -Be 2
        $Script:ProjectMap['Project\backend'].ProjectPath | Should -Be $Child
        $Script:ProjectMap['Project\backend'].Claude.Files | Should -Be 1
    }

    It 'preserves a legacy fallback until exact nested state exists' {
        $Parent = Join-Path $Script:ProjectsBasePath 'Project'
        $Child = Join-Path $Parent 'backend'
        [void](New-Item -ItemType Directory -Path $Child -Force)

        Add-FixtureStatusFile -Cwd $Child -StorageProjectRoot $Parent | Should -BeTrue
        $Script:ProjectMap['Project\backend'].Claude.Files | Should -Be 1

        [void](New-Item -ItemType Directory -Path (Join-Path $Child '.agent-state'))
        Add-FixtureStatusFile -Cwd $Child -StorageProjectRoot $Parent | Should -BeTrue

        $Script:ResolutionCalls | Should -Be 2
        $Script:ProjectMap.Count | Should -Be 1
        $Script:ProjectMap['Project\backend'].Claude.Files | Should -Be 1
    }

    It 'resolves an outside alias and preserves its exact nested suffix' {
        $Canonical = Join-Path $Script:ProjectsBasePath 'Canonical'
        $Child = Join-Path $Canonical 'backend'
        $Outside = Join-Path $TestDrive 'outside-alias'
        [void](New-Item -ItemType Directory -Path $Child -Force)
        $Script:Config.projectAliases = [PSCustomObject]@{ Canonical = @($Outside) }

        Add-FixtureStatusFile -Cwd (Join-Path $Outside 'backend') -StorageProjectRoot $Child | Should -BeTrue

        $Script:ResolutionCalls | Should -Be 1
        $Script:ProjectMap.Count | Should -Be 1
        $Script:ProjectMap['Canonical\backend'].ProjectPath | Should -Be $Child
        $Script:ProjectMap['Canonical\backend'].Claude.Files | Should -Be 1
    }

    It 'retains resolution for standalone canonical checks without an identity argument' {
        $Parent = Join-Path $Script:ProjectsBasePath 'Project'
        $Child = Join-Path $Parent 'backend'
        [void](New-Item -ItemType Directory -Path (Join-Path $Child '.agent-state') -Force)

        Test-CanonicalStorageProject -Cwd $Child -StorageProjectRoot $Parent | Should -BeFalse
        Test-CanonicalStorageProject -Cwd $Child -StorageProjectRoot $Child | Should -BeTrue

        $Script:ResolutionCalls | Should -Be 2
    }

    It 'does not add an unresolvable outside project' {
        $Outside = Join-Path $TestDrive 'unmapped-outside-project'

        Add-FixtureStatusFile -Cwd $Outside -StorageProjectRoot '' | Should -BeFalse

        $Script:ResolutionCalls | Should -Be 1
        $Script:ProjectMap.Count | Should -Be 0
    }
}
