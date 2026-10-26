# Regression coverage for Antigravity's fixed-size transcript fragments.
# Files below logs/chunks are byte slices of one JSONL stream. A slice can
# begin or end in the middle of a JSON record, or even in the middle of a
# UTF-8 code point, and must never be validated as an independent JSONL file.

BeforeAll {
    $RecoveryPath = Join-Path $PSScriptRoot '..\Test-AgentSync-Recovery.ps1'
    $IntelligencePath = Join-Path $PSScriptRoot '..\Build-AgentSync-Intelligence.ps1'

    $Tokens = $null
    $Errors = $null
    $RecoveryAst = [System.Management.Automation.Language.Parser]::ParseFile($RecoveryPath, [ref]$Tokens, [ref]$Errors)
    if ($Errors.Count -gt 0) { throw "Recovery script does not parse: $($Errors[0].Message)" }
    $RequiredRecoveryFunctions = @('New-Finding', 'Get-SharedReadStream', 'Test-AntigravityJsonlChunkFile', 'Test-JsonlChunkSet')
    $RecoveryDefinitions = @($RecoveryAst.FindAll({
        param($Node)
        $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $RequiredRecoveryFunctions -contains $Node.Name
    }, $false) | ForEach-Object { $_.Extent.Text }) -join "`n"
    . ([scriptblock]::Create($RecoveryDefinitions))

    $Tokens = $null
    $Errors = $null
    $IntelligenceAst = [System.Management.Automation.Language.Parser]::ParseFile($IntelligencePath, [ref]$Tokens, [ref]$Errors)
    if ($Errors.Count -gt 0) { throw "Intelligence script does not parse: $($Errors[0].Message)" }
    $IntelligencePredicate = @($IntelligenceAst.FindAll({
        param($Node)
        $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $Node.Name -eq 'Test-AntigravityJsonlChunkFile'
    }, $false) | Select-Object -First 1)
    $IntelligenceReader = @($IntelligenceAst.FindAll({
        param($Node)
        $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $Node.Name -eq 'Read-JsonlGroup'
    }, $false) | Select-Object -First 1)
    if ($IntelligencePredicate.Count -ne 1 -or $IntelligenceReader.Count -ne 1) {
        throw 'Intelligence chunk predicate or JSONL reader is missing.'
    }
    $Script:IntelligencePredicate = [scriptblock]::Create("param(`$File)`n$($IntelligencePredicate[0].Extent.Text)`nTest-AntigravityJsonlChunkFile -File `$File")
    $Script:IntelligenceReaderText = $IntelligenceReader[0].Extent.Text
}

Describe 'Antigravity transcript chunks' {

    BeforeEach {
        $SessionName = 'session-' + [guid]::NewGuid().ToString('N')
        $Script:ChunkRoot = Join-Path $TestDrive "$SessionName\brain\.system_generated\logs\chunks\transcript"
        New-Item -ItemType Directory -Path $Script:ChunkRoot -Force | Out-Null
    }

    It 'classifies a numbered chunk in both Recovery and Intelligence, but not the complete transcript' {
        $ChunkPath = Join-Path $Script:ChunkRoot '00000000.jsonl'
        Set-Content -LiteralPath $ChunkPath -Value '{}'
        $CompletePath = Join-Path (Split-Path (Split-Path $Script:ChunkRoot -Parent) -Parent) 'transcript.jsonl'
        Set-Content -LiteralPath $CompletePath -Value '{}'
        $Chunk = Get-Item -LiteralPath $ChunkPath
        $Complete = Get-Item -LiteralPath $CompletePath

        (Test-AntigravityJsonlChunkFile -File $Chunk) | Should -BeTrue
        (Test-AntigravityJsonlChunkFile -File $Complete) | Should -BeFalse
        (& $Script:IntelligencePredicate $Chunk) | Should -BeTrue
        (& $Script:IntelligencePredicate $Complete) | Should -BeFalse
        $Script:IntelligenceReaderText | Should -Match '-not \(Test-AntigravityJsonlChunkFile -File \$_\)'
    }

    It 'reassembles JSON records split across files and inside a UTF-8 code point' {
        $Text = "{`"type`":`"USER_INPUT`",`"text`":`"første`"}`n{`"type`":`"RESPONSE`",`"text`":`"andre`"}`n"
        $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $Utf8Lead = [Array]::IndexOf($Bytes, [byte]0xC3)
        $Split = $Utf8Lead + 1
        [System.IO.File]::WriteAllBytes((Join-Path $Script:ChunkRoot '00000000.jsonl'), [byte[]]$Bytes[0..($Split - 1)])
        [System.IO.File]::WriteAllBytes((Join-Path $Script:ChunkRoot '00000001.jsonl'), [byte[]]$Bytes[$Split..($Bytes.Length - 1)])

        $Check = Test-JsonlChunkSet -Files @(Get-ChildItem -LiteralPath $Script:ChunkRoot -File)

        @($Check.findings).Count | Should -Be 0
        $Check.lines | Should -Be 2
    }

    It 'still reports a genuinely malformed logical tail after reassembly' {
        [System.IO.File]::WriteAllText(
            (Join-Path $Script:ChunkRoot '00000000.jsonl'),
            "{`"ok`":1}`n{`"broken`":`n",
            [System.Text.UTF8Encoding]::new($false))

        $Check = Test-JsonlChunkSet -Files @(Get-ChildItem -LiteralPath $Script:ChunkRoot -File)

        @($Check.findings.code) | Should -Contain 'JSONL_CHUNK_TAIL_INVALID'
    }
}

Describe 'Sync engine fragment detection covers both real layouts' {
    BeforeAll {
        # The engine's own predicate, loaded without starting the daemon.
        $Tokens = $null
        $Errors = $null
        $EnginePath = Join-Path $PSScriptRoot '..\Sync-AgentState.ps1'
        $EngineAst = [System.Management.Automation.Language.Parser]::ParseFile($EnginePath, [ref]$Tokens, [ref]$Errors)
        if ($Errors.Count -gt 0) { throw "Engine does not parse: $($Errors[0].Message)" }
        $Wanted = @('Test-AntigravityJsonlChunkPath', 'Test-AppendOnlyName')
        $Definitions = @($EngineAst.FindAll({
                param($Node)
                $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Wanted -contains $Node.Name
            }, $false) | ForEach-Object { $_.Extent.Text })
        if ($Definitions.Count -ne 2) { throw "Expected both chunk predicates in the engine, found $($Definitions.Count)." }
        . ([scriptblock]::Create(($Definitions -join [Environment]::NewLine)))
    }

    # The two layouts are not cosmetic. Copy-FileSafe applies the guard to the
    # SOURCE path, and the source is the native one, where the session id sits
    # between brain/ and .system_generated/. A fixture built from the project
    # copy's shape passes while the real file is still refused. That happened:
    # seven project fragments stayed missing, and the engine logged fourteen
    # JSONL_INCOMPLETE refusals after the fix was already loaded.
    It 'recognises a fragment in the native source layout, where the session id follows brain' {
        $Native = 'C:\Users\x\.gemini\antigravity-cli\brain\8ab15f55-d6eb-4631-aa66-1b111c71d170\.system_generated\logs\chunks\transcript\00000000.jsonl'
        Test-AntigravityJsonlChunkPath -Path $Native | Should -BeTrue
        Test-AppendOnlyName -Path $Native | Should -BeFalse
    }

    It 'recognises a fragment in the project copy layout' {
        $Copy = 'P:\p\.agent-state\antigravity\cli\sessions\8ab15f55\brain\.system_generated\logs\chunks\transcript_full\00000004.jsonl'
        Test-AntigravityJsonlChunkPath -Path $Copy | Should -BeTrue
        Test-AppendOnlyName -Path $Copy | Should -BeFalse
    }

    It 'keeps append-only protection for everything that is not a numbered fragment' {
        $Protected = @(
            'P:\p\.agent-state\antigravity\cli\sessions\s\brain\.system_generated\logs\transcript.jsonl'
            'C:\Users\x\.codex\sessions\2026\09\19\rollout-abc.jsonl'
            'C:\Users\x\.gemini\antigravity-cli\brain\s\.system_generated\logs\chunks\other\00000000.jsonl'
            'C:\Users\x\.gemini\antigravity-cli\brain\s\.system_generated\logs\chunks\transcript\0000000.jsonl'
        )
        foreach ($Path in $Protected) {
            Test-AntigravityJsonlChunkPath -Path $Path | Should -BeFalse
            Test-AppendOnlyName -Path $Path | Should -BeTrue
        }
    }
}
