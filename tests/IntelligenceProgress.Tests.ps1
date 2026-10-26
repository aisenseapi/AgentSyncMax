BeforeAll {
    $Builder = Join-Path $PSScriptRoot '..\Build-AgentSync-Intelligence.ps1'
    $Tokens = $null; $Errors = $null
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Builder, [ref]$Tokens, [ref]$Errors)
    if ($Errors.Count) { throw $Errors[0].Message }
    $Definitions = $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
    . ([scriptblock]::Create(($Definitions.Extent.Text -join "`n")))
    $Script:ParserVersion = 5
}

Describe 'Resumable Intelligence metadata cache' {
    It 'accepts only matching roots and parser versions and tolerates a damaged cache' {
        $Path = Join-Path $TestDrive 'cache.json'
        $Record = [pscustomobject]@{ storageKey = 'p|claude|s'; sourceFingerprint = 'abc'; parserVersion = 5 }
        Save-IntelligenceProgress $Path 'root-a' @($Record) 3
        @(Read-IntelligenceProgress $Path 'root-a').Count | Should -Be 1
        @(Read-IntelligenceProgress $Path 'root-b').Count | Should -Be 0
        $Record.parserVersion = 4
        Save-IntelligenceProgress $Path 'root-a' @($Record) 3
        @(Read-IntelligenceProgress $Path 'root-a').Count | Should -Be 0
        Set-Content $Path '{incomplete'
        @(Read-IntelligenceProgress $Path 'root-a').Count | Should -Be 0
    }

    It 'resumes inside one large JSONL source across bounded passes without publishing partial counts' {
        $Root = Join-Path $TestDrive 'projects'
        $Project = Join-Path $Root 'Example'
        $Sessions = Join-Path $Project '.agent-state/claude/sessions/bucket'
        $Index = Join-Path $TestDrive 'project-index'
        New-Item -ItemType Directory $Sessions, $Index -Force | Out-Null
        @{ projects = @('Example') } | ConvertTo-Json | Set-Content (Join-Path $Index 'claude.json')
        $Config = Join-Path $TestDrive 'config.json'
        @{
            sharedProjectsDir = $Root; version = 'test'; projectIndex = @{ directory = $Index }
            agents = @(@{ enabled = $true; routingMode = 'claude'; targetSubDir = '.agent-state/claude/sessions' })
        } | ConvertTo-Json -Depth 8 | Set-Content $Config
        $First = Join-Path $Sessions 'a.jsonl'
        $Line = @{ type = 'assistant'; cwd = $Project; sessionId = 'a'; timestamp = '2026-10-01T00:00:00Z'; message = @{ model = 'test-model'; content = @(@{ type = 'text'; text = 'SENSITIVE_FIXTURE_TEXT' }) } } | ConvertTo-Json -Depth 8 -Compress
        [IO.File]::WriteAllText($First, (($Line + "`n") * 15000))
        $Second = Join-Path $Sessions 'b.jsonl'
        [IO.File]::WriteAllText($Second, ($Line.Replace('"sessionId":"a"', '"sessionId":"b"') + "`n"))
        $Data = Join-Path $TestDrive 'report.json'
        $Html = Join-Path $TestDrive 'report.html'
        @{ generatedUtc = '2026-09-01T00:00:00Z'; projectsRoot = $Root; sourceRecords = @() } | ConvertTo-Json | Set-Content $Data
        Set-Content $Html '<html>previous complete report</html>'
        $OldDataHash = (Get-FileHash $Data).Hash
        $OldHtmlHash = (Get-FileHash $Html).Hash
        & $Builder -ConfigFile $Config -DataFile $Data -OutputFile $Html -WorkBudgetSeconds 1
        (Get-FileHash $Data).Hash | Should -Be $OldDataHash
        (Get-FileHash $Html).Hash | Should -Be $OldHtmlHash
        $Progress = Get-Content ($Data + '.progress.json') -Raw | ConvertFrom-Json
        $Progress.pendingGroups | Should -Be 2
        $Progress.records.Count | Should -Be 0
        $Progress.partial.nextLine | Should -BeGreaterThan 0
        $Progress.partial.nextLine | Should -BeLessThan 15000
        $FirstCursor = $Progress.partial.nextLine
        Get-Content ($Data + '.progress.json') -Raw | Should -Not -Match 'SENSITIVE_FIXTURE_TEXT'
        & $Builder -ConfigFile $Config -DataFile $Data -OutputFile $Html -WorkBudgetSeconds 1
        (Get-FileHash $Data).Hash | Should -Be $OldDataHash
        (Get-FileHash $Html).Hash | Should -Be $OldHtmlHash
        $Progress = Get-Content ($Data + '.progress.json') -Raw | ConvertFrom-Json
        $Progress.partial.nextLine | Should -BeGreaterThan $FirstCursor
        & $Builder -ConfigFile $Config -DataFile $Data -OutputFile $Html
        $Report = Get-Content $Data -Raw | ConvertFrom-Json
        $Report.cache.misses | Should -Be 2
        $Report.summary.sessions | Should -Be 2
        ($Report.sessions | Where-Object id -eq 'a').assistantMessages | Should -Be 15000
        $Report.phaseMs.parsing | Should -BeGreaterOrEqual 0
        Test-Path $Html | Should -BeTrue
        (Get-Content ($Data + '.progress.json') -Raw | ConvertFrom-Json).records.Count | Should -Be 0
        Get-Content $Data -Raw | Should -Not -Match 'SENSITIVE_FIXTURE_TEXT'
        # Same cache file is not authority when a native file has changed.
        Add-Content $Second $Line.Replace('"sessionId":"a"', '"sessionId":"b"')
        & $Builder -ConfigFile $Config -DataFile $Data -OutputFile $Html
        $Updated = Get-Content $Data -Raw | ConvertFrom-Json
        $Updated.cache.hits | Should -Be 1
        $Updated.cache.misses | Should -Be 1
        ($Updated.sessions | Where-Object id -eq 'b').assistantMessages | Should -Be 2
    }

    It 'discards a partial cursor and its counts when the native input changes' {
        $Root = Join-Path $TestDrive 'changed-projects'
        $Project = Join-Path $Root 'Changed'
        $Sessions = Join-Path $Project '.agent-state/codex/sessions'
        $Index = Join-Path $TestDrive 'changed-index'
        New-Item -ItemType Directory $Sessions, $Index -Force | Out-Null
        @{ projects = @('Changed') } | ConvertTo-Json | Set-Content (Join-Path $Index 'codex.json')
        $Config = Join-Path $TestDrive 'changed-config.json'
        @{
            sharedProjectsDir = $Root; version = 'test'; projectIndex = @{ directory = $Index }
            agents = @(@{ enabled = $true; routingMode = 'codex'; targetSubDir = '.agent-state/codex/sessions' })
        } | ConvertTo-Json -Depth 8 | Set-Content $Config
        $Source = Join-Path $Sessions 'large.jsonl'
        $Line = @{ type = 'response_item'; timestamp = '2026-10-01T00:00:00Z'; payload = @{ type = 'message'; role = 'assistant'; content = @(@{ text = 'PRIVATE_NORWEGIAN_æøå_文' }) } } | ConvertTo-Json -Depth 8 -Compress
        [IO.File]::WriteAllText($Source, (($Line + "`n") * 15000))
        $Data = Join-Path $TestDrive 'changed-report.json'
        $Html = Join-Path $TestDrive 'changed-report.html'
        & $Builder -ConfigFile $Config -DataFile $Data -OutputFile $Html -WorkBudgetSeconds 1
        Test-Path $Data | Should -BeFalse
        Test-Path $Html | Should -BeFalse
        $Progress = Get-Content ($Data + '.progress.json') -Raw | ConvertFrom-Json
        $Progress.partial.nextLine | Should -BeGreaterThan 0
        Get-Content ($Data + '.progress.json') -Raw | Should -Not -Match 'PRIVATE_NORWEGIAN'
        [IO.File]::WriteAllText($Source, ($Line + "`n"))
        & $Builder -ConfigFile $Config -DataFile $Data -OutputFile $Html
        $Report = Get-Content $Data -Raw | ConvertFrom-Json
        $Report.summary.sessions | Should -Be 1
        $Report.sessions[0].assistantMessages | Should -Be 1
        $Report.sessions[0].records | Should -Be 1
    }

    It 'preserves all derived metadata across serialized cursors, Unicode and source file boundaries' {
        $Project = Join-Path $TestDrive 'cursor-project'
        New-Item -ItemType Directory $Project -Force | Out-Null
        $Group = New-SourceGroup -StorageKey 'cursor|codex|one' -Agent codex -Id one -ProjectRelative cursor -ProjectPath $Project -Surface active
        $A = Join-Path $Project 'a.jsonl'
        $B = Join-Path $Project 'b.jsonl'
        $First = @{ type = 'session_meta'; timestamp = '2026-10-01T01:00:00Z'; payload = @{ id = 'native-id'; cwd = $Project; model_provider = 'test-provider' } } | ConvertTo-Json -Depth 8 -Compress
        $Second = @{ type = 'turn_context'; timestamp = '2026-10-01T02:00:00Z'; payload = @{ model = 'test-model'; cwd = $Project } } | ConvertTo-Json -Depth 8 -Compress
        $Third = @{ type = 'response_item'; timestamp = '2026-10-01T03:00:00Z'; payload = @{ type = 'function_call'; name = 'edit_file'; arguments = (@{ path = (Join-Path $Project 'øvelse文.md'); content = 'NEVER_IN_CACHE' } | ConvertTo-Json -Compress) } } | ConvertTo-Json -Depth 8 -Compress
        [IO.File]::WriteAllText($A, ($First + "`n"))
        [IO.File]::WriteAllText($B, ($Second + "`n" + $Third + "`n"))
        # Deliberately reversed enumeration; continuation orders files by path.
        $Group.files.Add((Get-Item $B))
        $Group.files.Add((Get-Item $A))
        $Fingerprint = Get-SourceFingerprint $Group
        $Expected = Read-JsonlGroup $Group $Fingerprint
        $Watch = [Diagnostics.Stopwatch]::StartNew()
        Start-Sleep -Milliseconds 1100
        $Cache = Join-Path $TestDrive 'cursor-cache.json'
        $Partial = $null
        $Pending = 0
        do {
            $Actual = Read-JsonlGroup $Group $Fingerprint -Continuation $Partial -WorkWatch $Watch -BudgetSeconds 1
            if ($Actual.intelligencePending) {
                $Pending++
                Save-IntelligenceProgress $Cache $Project @() 1 -Partial $Actual.continuation
                $Partial = Read-IntelligencePartial $Cache $Project
                if ($Pending -eq 1) { $Partial.fileIndex | Should -Be 1; $Partial.nextLine | Should -Be 0 }
                Get-Content $Cache -Raw | Should -Not -Match 'NEVER_IN_CACHE'
            }
        } while ($Actual.intelligencePending -and $Pending -lt 10)
        $Pending | Should -Be 2
        ($Actual | ConvertTo-Json -Depth 10 -Compress) | Should -Be ($Expected | ConvertTo-Json -Depth 10 -Compress)
    }
}
