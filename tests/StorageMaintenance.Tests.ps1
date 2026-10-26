BeforeAll {
    $Script:MaintenanceScript = Join-Path $PSScriptRoot '..\Fix-AgentSync-Storage.ps1'
    $Tokens = $null
    $Errors = $null
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Script:MaintenanceScript, [ref]$Tokens, [ref]$Errors)
    if ($Errors.Count) { throw $Errors[0].Message }
    # Load definitions only. Never invoke the default real-toolkit target.
    $Definitions = $Ast.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
    . ([scriptblock]::Create(($Definitions.Extent.Text -join [Environment]::NewLine)))
}

Describe 'Local Dropbox storage split on isolated fixtures' {
    BeforeEach {
        $Root = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        $Missions = Join-Path $Root 'missions'
        $Checkpoints = Join-Path $Missions 'checkpoints'
        New-Item -ItemType Directory -Path $Checkpoints -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Root 'Sync-AgentState.ps1') -Value '# fixture'
        Set-Content -LiteralPath (Join-Path $Root 'config.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $Missions 'mission-123.json') -Value '{"prompt":"preserve me"}'
        Set-Content -LiteralPath (Join-Path $Checkpoints 'backup.txt') -Value 'unchanged backup'
        Set-Content -LiteralPath $Missions -Stream com.dropbox.ignored -Value 1
    }

    It 'defaults to a read-only plan with exact paths' {
        $Plan = & $Script:MaintenanceScript -ToolkitPath $Root
        $Plan.Applied | Should -BeFalse
        $Plan.NeedsChange | Should -BeTrue
        $Plan.DurableFiles | Should -Be 1
        Get-AgentSyncDropboxIgnored $Missions | Should -BeTrue
        Get-AgentSyncDropboxIgnored $Checkpoints | Should -BeFalse
    }

    It 'marks checkpoints before enabling durable records and is idempotent' {
        $Result = & $Script:MaintenanceScript -ToolkitPath $Root -Apply -Confirm:$false
        $Result.Applied | Should -BeTrue
        Get-AgentSyncDropboxIgnored $Missions | Should -BeFalse
        Get-AgentSyncDropboxIgnored $Checkpoints | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $Missions 'mission-123.json') -Raw).Trim() | Should -Be '{"prompt":"preserve me"}'
        (Get-Content -LiteralPath (Join-Path $Checkpoints 'backup.txt') -Raw).Trim() | Should -Be 'unchanged backup'
        (& $Script:MaintenanceScript -ToolkitPath $Root -Apply -Confirm:$false).NeedsChange | Should -BeFalse
    }

    It 'keeps evaluation revisions and conflict JSON copies intact' {
        New-Item -ItemType Directory -Path (Join-Path $Missions 'evaluations\case-1') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Missions 'evaluations\case-1\revision-1.json') -Value '{"verdict":"unknown"}'
        Set-Content -LiteralPath (Join-Path $Missions 'mission-123 (conflicted copy).json') -Value '{"prompt":"other original"}'
        $Plan = Set-AgentSyncStorageSplit $Root
        $Plan.DurableFiles | Should -Be 3
        @($Plan.ConflictFilesRetained).Count | Should -Be 1
        Test-Path -LiteralPath $Plan.ConflictFilesRetained[0] | Should -BeTrue
    }

    It 'retains unfamiliar checkpoint/archive conflict directories and keeps parent ignored' {
        $Unknown = Join-Path $Missions 'checkpoints (conflicted copy)'
        New-Item -ItemType Directory -Path $Unknown | Out-Null
        { Set-AgentSyncStorageSplit $Root } | Should -Throw '*Unclassified mission directory*'
        Get-AgentSyncDropboxIgnored $Missions | Should -BeTrue
        Test-Path -LiteralPath $Unknown | Should -BeTrue
    }

    It 'does not release the parent if checkpoint protection fails' {
        Mock Set-Content { throw 'fixture ADS failure' } -ParameterFilter { $Stream -eq 'com.dropbox.ignored' }
        { Set-AgentSyncStorageSplit $Root } | Should -Throw '*fixture ADS failure*'
        Get-AgentSyncDropboxIgnored $Missions | Should -BeTrue
    }

    It 'preserves parent ignore when a checkpoint is online-only' {
        $Backup = Join-Path $Checkpoints 'backup.txt'
        $OriginalAttributes = [System.IO.File]::GetAttributes($Backup)
        try {
            [System.IO.File]::SetAttributes($Backup, ($OriginalAttributes -bor [System.IO.FileAttributes]::Offline))
            { Set-AgentSyncStorageSplit $Root } | Should -Throw '*not fully local*'
            Get-AgentSyncDropboxIgnored $Missions | Should -BeTrue
            Get-AgentSyncDropboxIgnored $Checkpoints | Should -BeFalse
        }
        finally { [System.IO.File]::SetAttributes($Backup, $OriginalAttributes) }
    }

    It 'refuses to introduce a new cloud exclusion outside the previous ignored boundary' {
        Clear-Content -LiteralPath $Missions -Stream com.dropbox.ignored
        { Set-AgentSyncStorageSplit $Root } | Should -Throw '*Refusing a new cloud exclusion*'
        Get-AgentSyncDropboxIgnored $Checkpoints | Should -BeFalse
    }

    It 'rejects a junction pointing outside the exact store' {
        $Outside = Join-Path $TestDrive 'outside'
        New-Item -ItemType Directory -Path $Outside -Force | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $Missions 'evaluations') -Target $Outside | Out-Null
        { Set-AgentSyncStorageSplit $Root } | Should -Throw '*Linked target*'
        Get-AgentSyncDropboxIgnored $Missions | Should -BeTrue
    }

    It 'accepts cloud placeholder tags but rejects symlink and junction tags' {
        Test-AgentSyncCloudReparseTag ([Convert]::ToUInt32('9000201A', 16)) | Should -BeTrue
        Test-AgentSyncCloudReparseTag ([Convert]::ToUInt32('9000F01A', 16)) | Should -BeTrue
        Test-AgentSyncCloudReparseTag ([Convert]::ToUInt32('A000000C', 16)) | Should -BeFalse
        Test-AgentSyncCloudReparseTag ([Convert]::ToUInt32('A0000003', 16)) | Should -BeFalse
    }
}
