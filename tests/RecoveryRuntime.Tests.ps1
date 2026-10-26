BeforeAll {
    . (Join-Path $PSScriptRoot '..\AgentSync.Process.ps1')
    $Tokens = $null; $Errors = $null
    $Ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\Test-AgentSync-Recovery.ps1'), [ref]$Tokens, [ref]$Errors)
    if ($Errors.Count) { throw $Errors[0].Message }
    $Definitions = $Ast.FindAll({ param($Node) $Node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)
    . ([scriptblock]::Create(($Definitions.Extent.Text -join [Environment]::NewLine)))
    $Script:Config = [pscustomobject]@{agents=@([pscustomobject]@{name='opencode';routingMode='opencode';commandWindows=(Join-Path $PSHOME 'pwsh.exe')})}
}

Describe 'Recovery runtime checks are bounded and optional' {
    It 'builds a direct hidden version command with a five-second deadline' {
        Mock Invoke-AgentSyncBoundedProcess {
            $StartInfo.UseShellExecute | Should -BeFalse
            $StartInfo.CreateNoWindow | Should -BeTrue
            (@($StartInfo.ArgumentList) -join ' ') | Should -Be '--version --pure'
            $TimeoutSeconds | Should -Be 5
            $MaxOutputCharacters | Should -Be 4096
            [pscustomobject]@{ExitCode=0;StdOut='1.2.3';StdErr='';TimedOut=$false}
        }
        (Get-RecoveryCliVersion -Command (Join-Path $PSHOME 'pwsh.exe')).ExitCode | Should -Be 0
    }

    It 'does not call any executable when runtime version checks are skipped' {
        $Script:SkipRuntimeVersionCheck = $true
        Mock Get-RecoveryCliVersion { throw 'must not run' }
        $Rows = @(Get-AgentRuntimeChecks -Config $Script:Config)
        $Row = $Rows | Where-Object agent -EQ 'opencode'
        $Row.message | Should -Match 'ikke kjørt'
        Should -Invoke Get-RecoveryCliVersion -Times 0
        $Script:SkipRuntimeVersionCheck = $false
    }

    It 'does not report a timed out executable as a verified healthy runtime' {
        $Script:SkipRuntimeVersionCheck = $false
        Mock Get-RecoveryCliVersion { [pscustomobject]@{ExitCode=-1;StdOut='';StdErr='timed out';TimedOut=$true} }
        $Row = Get-AgentRuntimeChecks -Config $Script:Config | Where-Object agent -EQ 'opencode'
        $Row.status | Should -Be 'warning'
        $Row.message | Should -Match 'tidsgrensen'
    }
}
