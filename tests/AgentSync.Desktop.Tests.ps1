BeforeAll {
    . (Join-Path $PSScriptRoot '..\AgentSync.Desktop.ps1')

    function New-TestRelease {
        param([string]$Version, [string]$Content)
        $Temporary = Join-Path $TestDrive 'built.exe'
        [IO.File]::WriteAllText($Temporary, $Content)
        $Hash = (Get-FileHash -LiteralPath $Temporary -Algorithm SHA256).Hash.ToLowerInvariant()
        $Name = "AgentSync-Max-$Version-$($Hash.Substring(0, 12)).exe"
        Copy-Item -LiteralPath $Temporary -Destination (Join-Path $Script:Dist $Name)
        @{
            schemaVersion = 1
            version = $Version
            executable = $Name
            sha256 = $Hash
        } | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $Script:Dist 'current-release.json') -NoNewline
        return [pscustomobject]@{ Path = $Temporary; Hash = $Hash; Name = $Name }
    }
}

Describe 'Verified AgentSync MAX desktop release chain' {
    BeforeEach {
        $Script:Toolkit = Join-Path $TestDrive 'toolkit'
        $Script:Dist = Join-Path $Script:Toolkit 'desktop\dist'
        $Script:LocalRoot = Join-Path $TestDrive 'local-runtime'
        New-Item -ItemType Directory -Path $Script:Dist, $Script:LocalRoot -Force | Out-Null
    }

    It 'copies the pointed release to a hash-addressed local runtime' {
        $Release = New-TestRelease -Version '4.23.1' -Content 'verified release bytes'

        $Plan = Get-AgentSyncDesktopLaunchPlan -ToolkitRoot $Script:Toolkit -LocalRoot $Script:LocalRoot

        $Plan.Source | Should -Be (Join-Path $Script:Dist $Release.Name)
        $Plan.Executable | Should -Be (Join-Path $Script:LocalRoot "runtime\$($Release.Hash)\AgentSync-Max.exe")
        (Get-FileHash -LiteralPath $Plan.Executable -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $Release.Hash
        $Plan.WorkingDirectory | Should -Not -Be $Script:Toolkit
        $StartInfo = New-AgentSyncDesktopStartInfo -Plan $Plan
        $StartInfo.Environment['AGENTSYNC_HOME'] | Should -Be $Plan.ToolkitRoot
    }

    It 'blocks a downgrade without changing the current pointer' {
        $Current = New-TestRelease -Version '4.23.1' -Content 'current release'
        $Pointer = Join-Path $Script:Dist 'current-release.json'
        $Before = Get-Content -Raw -LiteralPath $Pointer
        $Older = Join-Path $TestDrive 'older.exe'
        [IO.File]::WriteAllText($Older, 'older release')

        { Publish-AgentSyncDesktopBuild -Source $Older -ToolkitRoot $Script:Toolkit -Version '4.22.0' -SkipLegacyAliases } |
            Should -Throw '*Nedgradering er blokkert*'
        (Get-Content -Raw -LiteralPath $Pointer) | Should -BeExactly $Before
        Test-Path -LiteralPath (Join-Path $Script:Dist 'AgentSync-Max-4.22.0-*.exe') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $Script:Dist $Current.Name) | Should -BeTrue
    }

    It 'requires a version bump when bytes change' {
        New-TestRelease -Version '4.23.1' -Content 'current release'
        $Changed = Join-Path $TestDrive 'changed.exe'
        [IO.File]::WriteAllText($Changed, 'changed release')

        { Publish-AgentSyncDesktopBuild -Source $Changed -ToolkitRoot $Script:Toolkit -Version '4.23.1' -SkipLegacyAliases } |
            Should -Throw '*annet innhold*'
    }

    It 'publishes a newer verified release and records its version' {
        New-TestRelease -Version '4.23.1' -Content 'current release'
        $Newer = Join-Path $TestDrive 'newer.exe'
        [IO.File]::WriteAllText($Newer, 'new release')

        $Published = Publish-AgentSyncDesktopBuild -Source $Newer -ToolkitRoot $Script:Toolkit -Version '4.24.0' -SkipLegacyAliases
        $Pointer = Get-Content -Raw -LiteralPath (Join-Path $Script:Dist 'current-release.json') | ConvertFrom-Json

        $Pointer.version | Should -Be '4.24.0'
        $Pointer.executable | Should -Be ([IO.Path]::GetFileName($Published))
        (Get-FileHash -LiteralPath $Published -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $Pointer.sha256
    }

    It 'keeps the public launcher on the verified helper path' {
        $Launcher = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\Start-AgentSync-Max.ps1')

        $Launcher | Should -Match 'Get-AgentSyncDesktopLaunchPlan'
        $Launcher | Should -Match 'Start-AgentSyncDesktopProcess'
        $Launcher | Should -Not -Match 'desktop\\dist\\AgentSync-Max\.exe'
        $Launcher | Should -Not -Match 'Start-Process'
    }

    It 'orders stable and prerelease semantic versions correctly' {
        Compare-AgentSyncSemanticVersion '4.24.0' '4.23.1' | Should -Be 1
        Compare-AgentSyncSemanticVersion '4.24.0-rc.2' '4.24.0-rc.10' | Should -Be -1
        Compare-AgentSyncSemanticVersion '4.24.0' '4.24.0-rc.10' | Should -Be 1
        Compare-AgentSyncSemanticVersion '4.24.0+build.2' '4.24.0+build.1' | Should -Be 0
    }
}
