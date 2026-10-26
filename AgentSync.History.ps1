# Long-term history ("varig historikk"). Loading this file starts no process.
#
# One bare Git repository per project, kept outside the projects and outside
# Dropbox, plus an append-only ledger and a readable per-project log in the
# export folder. Nothing in this file writes into a project, its .git or its
# .agent-state: projects are only ever read, as a Git work tree of a repository
# that lives somewhere else.
#
# Requires AgentSync.Process.ps1 (Invoke-AgentSyncBoundedProcess) to be loaded.
# Design, measurements and what this does not prove: docs/VARIG-HISTORIKK.md.

function Expand-AgentSyncHistoryPath {
    param ([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    $Expanded = [System.Environment]::ExpandEnvironmentVariables($Path.Trim())
    if ($Expanded -eq '~' -or $Expanded.StartsWith('~/') -or $Expanded.StartsWith('~\')) {
        $UserHome = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
        $Expanded = Join-Path $UserHome $Expanded.Substring(1).TrimStart('/', '\')
    }
    return [System.IO.Path]::GetFullPath($Expanded)
}

function Get-AgentSyncHistorySettings {
    param (
        $Config,
        [string]$ToolkitRoot,
        [string]$MachineId
    )

    $Node = $null
    if ($Config -and $Config.history) {
        $Node = $Config.history
    }
    $Read = {
        param ($Name, $Default)
        if ($null -ne $Node -and $null -ne $Node.$Name) { return $Node.$Name }
        return $Default
    }

    $DefaultStore = if ($env:LOCALAPPDATA) {
        Join-Path $env:LOCALAPPDATA 'AgentSyncMax\history-store'
    }
    else {
        '~/.local/share/agentsync-max/history-store'
    }

    $ExportSetting = & $Read 'exportDirectory' ''
    $ExportDirectory = if ($ExportSetting) {
        Expand-AgentSyncHistoryPath -Path $ExportSetting
    }
    else {
        Join-Path (Join-Path $ToolkitRoot 'history') $MachineId
    }

    # The same directory names the mission checkpoint leaves out: caches and
    # dependency trees that a build recreates. Everything else is history.
    $DefaultExcludedDirectories = @('.cache', '.next', '.nuxt', '.venv', 'venv', 'node_modules', 'target', '__pycache__')

    # Mirrors blind_copy_excluded in desktop/src-tauri/src/main.rs (the
    # environment_secret and credential_file groups). A history that outlives
    # the project must not be the place a key is found in ten years.
    $DefaultSecretNames = @(
        '.envrc', '.npmrc', '.pypirc', '.netrc', '.dockercfg', '.htpasswd', 'auth.json', 'token.json',
        'config.local.json', 'settings.local.json', 'credentials.json', '.credentials.json',
        '.git-credentials', '.pgpass', 'service-account.json', 'service_account.json',
        'application_default_credentials.json', 'secrets.json', 'secrets.yaml', 'secrets.yml',
        'id_rsa', 'id_ed25519', 'id_ecdsa', 'id_dsa', '.aws', '.ssh', '.gnupg', '.kube', '.docker'
    )
    $DefaultSecretSuffixes = @('.pem', '.key', '.p12', '.pfx', '.kdbx', '.jks', '.keystore', '.ppk', '.asc', '.gpg')

    # A list of exact names always loses. Real credential files are named
    # freely: crates-io.token, .m2m-token, gh-token.txt, access_token.json,
    # .aws-credentials. So a word in the name is enough, and the word is bounded
    # so that tokenizer.py, keyboard.css and passwordless.md are not swept up.
    $DefaultSecretPattern = '(^|[^a-z])(tokens?|secrets?|credentials?|passwords?|passwd|apikeys?|api[-_]keys?|privatekeys?|private[-_]keys?)([^a-z]|$)'

    # A word match alone must not swallow a file whose extension says it is
    # content. tokens.css is a design-token stylesheet and belongs in history;
    # access_token.json does not. Exact names and secret suffixes still apply
    # regardless of extension, so secrets.json stays out either way.
    $DefaultSecretWordSafeExtensions = @(
        '.css', '.scss', '.sass', '.less', '.html', '.htm', '.md', '.markdown', '.txt.example',
        '.rs', '.py', '.js', '.mjs', '.cjs', '.ts', '.tsx', '.jsx', '.java', '.kt', '.php', '.go',
        '.c', '.h', '.cpp', '.hpp', '.cs', '.rb', '.swift', '.sql', '.ps1', '.psm1', '.sh',
        '.png', '.jpg', '.jpeg', '.gif', '.svg', '.webp', '.ico', '.pdf'
    )

    # A folder the project's own ignore rules hide, but that is history all the
    # same. Nothing is here by default, and that is deliberate: `missions/` was a
    # default until the control on 19 September 2026 pointed out that it puts raw
    # prompts and agent answers into Git, which AGENT_CONTEXT.md forbids for those
    # paths. Adding it back is a choice to make once a record can be taken out
    # again, not a default that quietly grows. Checkpoints are rollback copies of
    # the project, never a record, and belong nowhere near this list.
    $ExtraLines = @()
    foreach ($Extra in @(& $Read 'extraLines' @())) {
        if ($Extra.line -and $Extra.path) {
            $ExtraLines += [pscustomobject]@{ line = [string]$Extra.line; path = (Expand-AgentSyncHistoryPath -Path $Extra.path); exclude = @($Extra.exclude) }
        }
    }

    return [pscustomobject]@{
        Enabled                = [bool](& $Read 'enabled' $false)
        MachineId              = $MachineId
        ToolkitRoot            = $ToolkitRoot
        StoreDirectory         = Expand-AgentSyncHistoryPath -Path (& $Read 'storeDirectory' $DefaultStore)
        ExportDirectory        = $ExportDirectory
        LargeFileBytes         = [long]([double](& $Read 'largeFileMB' 50) * 1MB)
        StateLargeFileBytes    = [long]([double](& $Read 'stateLargeFileMB' 512) * 1MB)
        StoreLargeFiles        = [bool](& $Read 'storeLargeFiles' $true)
        GitScanDepth           = [int](& $Read 'gitScanDepth' 3)
        MinFreeBytes           = [long]([double](& $Read 'minFreeGB' 20) * 1GB)
        QuietMinutes           = [int](& $Read 'quietMinutes' 10)
        MaxDirtyMinutes        = [int](& $Read 'maxDirtyMinutes' 60)
        TimeBudgetSeconds      = [int](& $Read 'timeBudgetSeconds' 120)
        SnapshotTimeoutSeconds = [int](& $Read 'snapshotTimeoutSeconds' 600)
        BaselineTimeoutSeconds = [int](& $Read 'baselineTimeoutSeconds' 1800)
        ExcludedDirectories    = @(& $Read 'excludedDirectories' $DefaultExcludedDirectories)
        SecretNames            = @(& $Read 'secretNames' $DefaultSecretNames)
        SecretSuffixes         = @(& $Read 'secretSuffixes' $DefaultSecretSuffixes)
        SecretPattern          = [string](& $Read 'secretPattern' $DefaultSecretPattern)
        SecretWordSafeExtensions = @(& $Read 'secretWordSafeExtensions' $DefaultSecretWordSafeExtensions)
        ExtraLines             = $ExtraLines
    }
}

function ConvertTo-AgentSyncHistoryUnitId {
    param ([string]$RelativePath)

    $Normalized = ($RelativePath -replace '\\', '/').Trim('/').ToLowerInvariant()
    $Slug = $Normalized.Replace('æ', 'ae').Replace('ø', 'o').Replace('å', 'a')
    $Slug = ($Slug -replace '[^a-z0-9]+', '-').Trim('-')
    # The tail is the specific part of a path; the head is usually a shared
    # folder. Cut at a word, so a folder name never starts in the middle of one.
    if ($Slug.Length -gt 48) {
        $Cut = $Slug.Length - 48
        if ($Slug[$Cut - 1] -ne '-') {
            $Next = $Slug.IndexOf('-', $Cut)
            if ($Next -ge 0 -and $Next -lt $Slug.Length - 1) { $Cut = $Next + 1 }
        }
        $Slug = $Slug.Substring($Cut).TrimStart('-')
    }
    if (-not $Slug) {
        $Slug = 'unit'
    }

    $Sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $Bytes = $Sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Normalized))
    }
    finally {
        $Sha.Dispose()
    }
    $Hash = [System.BitConverter]::ToString($Bytes).Replace('-', '').ToLowerInvariant()
    return "$Slug-$($Hash.Substring(0, 8))"
}

function Get-AgentSyncHistoryNormalizedPath {
    param ([string]$Path)

    $Full = [System.IO.Path]::GetFullPath($Path)
    if ($Full.StartsWith('\\?\')) {
        $Full = $Full.Substring(4)
    }
    return $Full.TrimEnd('\', '/')
}

function Test-AgentSyncHistoryPathInside {
    param ([string]$Child, [string]$Parent)

    $ChildPath = (Get-AgentSyncHistoryNormalizedPath -Path $Child) + [System.IO.Path]::DirectorySeparatorChar
    $ParentPath = (Get-AgentSyncHistoryNormalizedPath -Path $Parent) + [System.IO.Path]::DirectorySeparatorChar
    return $ChildPath.StartsWith($ParentPath, [System.StringComparison]::OrdinalIgnoreCase) -and $ChildPath.Length -gt $ParentPath.Length
}

function Get-AgentSyncHistoryMutexName {
    param (
        [ValidateSet('Unit', 'Ledger', 'Readable', 'Sweep')][string]$Kind,
        [Parameter(Mandatory)][string]$Path
    )

    # Lock the resource being written, not its display ID or machine label.
    # Independent stores may contain the same IDs; different callers may name
    # the same store differently. No path text is exposed in the mutex name.
    if ($Path.StartsWith('\\?\UNC\', [System.StringComparison]::OrdinalIgnoreCase)) {
        $Path = '\\' + $Path.Substring(8)
    }
    $Canonical = Get-AgentSyncHistoryNormalizedPath -Path $Path
    if ([System.IO.Path]::DirectorySeparatorChar -eq '\') {
        $Canonical = $Canonical.Replace('/', '\').ToUpperInvariant()
    }
    $Hash = Get-AgentSyncHistoryLineHash -Line $Canonical
    return "AgentSyncHistory.$Kind.$Hash"
}

function Test-AgentSyncHistoryGitRoot {
    param ([string]$Path)

    # A worktree or submodule has a .git *file*; both mark a repository root.
    return (Test-Path -LiteralPath (Join-Path $Path '.git'))
}

function Find-AgentSyncHistoryGitRootAbove {
    param ([string]$Path, [string]$ProjectsBasePath)

    $Current = Get-AgentSyncHistoryNormalizedPath -Path $Path
    $Base = Get-AgentSyncHistoryNormalizedPath -Path $ProjectsBasePath
    while ($Current -and (Test-AgentSyncHistoryPathInside -Child $Current -Parent $Base)) {
        if (Test-AgentSyncHistoryGitRoot -Path $Current) {
            return $Current
        }
        $Current = Split-Path -Parent $Current
    }
    return $null
}

function Find-AgentSyncHistoryGitRootsBelow {
    param ([string]$Path, [int]$Depth, [string[]]$ExcludedDirectories)

    # Bounded on purpose: a project folder may hold a synced archive of
    # anything, and discovery must never turn into a walk of all of Dropbox.
    $Found = [System.Collections.Generic.List[string]]::new()
    $Queue = [System.Collections.Generic.Queue[object]]::new()
    $Queue.Enqueue(@($Path, 0))
    while ($Queue.Count -gt 0) {
        $Item = $Queue.Dequeue()
        $Directory = $Item[0]
        $Level = [int]$Item[1]
        if ($Level -ge $Depth) {
            continue
        }
        try {
            $Children = @([System.IO.Directory]::EnumerateDirectories($Directory))
        }
        catch {
            continue
        }
        foreach ($Child in $Children) {
            $Name = [System.IO.Path]::GetFileName($Child)
            if ($Name -eq '.git' -or $Name -eq '.agent-state' -or ($ExcludedDirectories -contains $Name)) {
                continue
            }
            if (Test-AgentSyncHistoryGitRoot -Path $Child) {
                $Found.Add((Get-AgentSyncHistoryNormalizedPath -Path $Child))
                continue
            }
            $Queue.Enqueue(@($Child, ($Level + 1)))
        }
    }
    return $Found.ToArray()
}

function Get-AgentSyncHistoryUnits {
    param (
        [string[]]$ProjectPaths,
        [string]$ProjectsBasePath,
        $Settings
    )

    $Base = Get-AgentSyncHistoryNormalizedPath -Path $ProjectsBasePath
    $Projects = @(
        $ProjectPaths |
            Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } |
            ForEach-Object { Get-AgentSyncHistoryNormalizedPath -Path $_ } |
            Sort-Object -Unique
    )

    $Roots = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Project in $Projects) {
        $GitRoot = Find-AgentSyncHistoryGitRootAbove -Path $Project -ProjectsBasePath $Base
        if ($GitRoot) {
            $Roots[$GitRoot] = 'git'
        }
        else {
            $Roots[$Project] = 'folder'
        }
        foreach ($Nested in (Find-AgentSyncHistoryGitRootsBelow -Path $Project -Depth $Settings.GitScanDepth -ExcludedDirectories $Settings.ExcludedDirectories)) {
            $Roots[$Nested] = 'git'
        }
    }

    $RootPaths = @($Roots.Keys)
    $Units = foreach ($Root in ($RootPaths | Sort-Object)) {
        $Relative = if (Test-AgentSyncHistoryPathInside -Child $Root -Parent $Base) {
            $Root.Substring($Base.Length).TrimStart('\', '/')
        }
        else {
            $Root -replace ':', ''
        }
        $Id = ConvertTo-AgentSyncHistoryUnitId -RelativePath $Relative

        # Units below this one carry their own history; the prescan leaves them out.
        $NestedUnits = @($RootPaths | Where-Object { Test-AgentSyncHistoryPathInside -Child $_ -Parent $Root })

        $StateLines = [System.Collections.Generic.List[object]]::new()
        $OwnState = Join-Path $Root '.agent-state'
        if (Test-Path -LiteralPath $OwnState -PathType Container) {
            $StateLines.Add([pscustomobject]@{ Line = 'state'; Path = $OwnState })
        }
        # A project inside this unit (a subfolder of a repository) keeps its
        # state beside itself, not at the repository root.
        foreach ($Project in $Projects) {
            if (-not (Test-AgentSyncHistoryPathInside -Child $Project -Parent $Root)) { continue }
            if ($NestedUnits | Where-Object { $_ -eq $Project -or (Test-AgentSyncHistoryPathInside -Child $Project -Parent $_) }) { continue }
            $NestedState = Join-Path $Project '.agent-state'
            if (Test-Path -LiteralPath $NestedState -PathType Container) {
                $Inner = $Project.Substring($Root.Length).TrimStart('\', '/')
                $Suffix = (($Inner.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-'))
                $StateLines.Add([pscustomobject]@{ Line = "state-$Suffix"; Path = $NestedState })
            }
        }

        # An extra line belongs to the innermost unit around its folder.
        $ExtraLines = @(
            foreach ($Extra in @($Settings.ExtraLines)) {
                if (-not (Test-Path -LiteralPath $Extra.path -PathType Container)) { continue }
                if (-not (Test-AgentSyncHistoryPathInside -Child $Extra.path -Parent $Root)) { continue }
                if ($NestedUnits | Where-Object { Test-AgentSyncHistoryPathInside -Child $Extra.path -Parent $_ }) { continue }
                [pscustomobject]@{ Line = $Extra.line; Path = (Get-AgentSyncHistoryNormalizedPath -Path $Extra.path); Exclude = @($Extra.exclude | Where-Object { $_ }) }
            }
        )

        [pscustomobject]@{
            Id             = $Id
            Path           = $Root
            RelativePath   = ($Relative -replace '\\', '/')
            Kind           = $Roots[$Root]
            NestedUnits    = $NestedUnits
            StateLines     = $StateLines.ToArray()
            ExtraLines     = $ExtraLines
            RepositoryPath = Join-Path $Settings.StoreDirectory "$Id.git"
            ExportPath     = Join-Path $Settings.ExportDirectory $Id
        }
    }
    return @($Units)
}

function Write-AgentSyncHistoryLog {
    param ([string]$Level, [string]$Message)

    # Inside the daemon the engine's log is the one place to look; the
    # command-line runner supplies its own sink through the same name. Whoever
    # owns that name owns its failures too: a snapshot is never lost because a
    # log line could not be written, and a test harness that replaces the
    # function with its own stub cannot make a snapshot fail.
    try {
        if (Get-Command -Name Write-AgentSyncLog -ErrorAction SilentlyContinue) {
            Write-AgentSyncLog -Level $Level -Message $Message
        }
    }
    catch { }
}

function Get-AgentSyncHistoryGitExecutable {
    if (-not $Script:AgentSyncHistoryGitPath) {
        $Command = Get-Command -Name git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $Command) {
            throw 'Git was not found on PATH. The history store needs the git command line.'
        }
        $Script:AgentSyncHistoryGitPath = $Command.Source
    }
    return $Script:AgentSyncHistoryGitPath
}

function Invoke-AgentSyncHistoryGit {
    param (
        [string]$Repository,
        [string[]]$Arguments,
        [string]$WorkTree,
        [string]$IndexFile,
        [int]$TimeoutSeconds = 120,
        [int]$MaxOutputCharacters = 4194304,
        # A file name may contain * or [. Commands that are handed paths from
        # the project must take them as names; check-ignore refuses the option.
        [switch]$LiteralPathspecs
    )

    $Info = [System.Diagnostics.ProcessStartInfo]::new()
    $Info.FileName = Get-AgentSyncHistoryGitExecutable
    $Info.UseShellExecute = $false
    $Info.CreateNoWindow = $true
    $Info.RedirectStandardOutput = $true
    $Info.RedirectStandardError = $true
    $Info.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $Info.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    if ($WorkTree) {
        $Info.WorkingDirectory = $WorkTree
    }

    # A caller's Git environment must never redirect a history command into
    # the project's own repository.
    foreach ($Name in 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_NAMESPACE', 'GIT_PREFIX', 'GIT_COMMON_DIR', 'GIT_LITERAL_PATHSPECS', 'GIT_GLOB_PATHSPECS', 'GIT_NOGLOB_PATHSPECS', 'GIT_ICASE_PATHSPECS') {
        [void]$Info.Environment.Remove($Name)
    }
    if ($IndexFile) {
        $Info.Environment['GIT_INDEX_FILE'] = $IndexFile
    }
    $Info.Environment['GIT_AUTHOR_NAME'] = 'AgentSync History'
    $Info.Environment['GIT_AUTHOR_EMAIL'] = 'history@agentsync.invalid'
    $Info.Environment['GIT_COMMITTER_NAME'] = 'AgentSync History'
    $Info.Environment['GIT_COMMITTER_EMAIL'] = 'history@agentsync.invalid'
    $Info.Environment['GIT_TERMINAL_PROMPT'] = '0'
    # stderr is parsed; it has to be in one language.
    $Info.Environment['LC_ALL'] = 'C'
    $Info.Environment['LANG'] = 'C'

    $Info.ArgumentList.Add("--git-dir=$Repository")
    if ($WorkTree) {
        $Info.ArgumentList.Add("--work-tree=$WorkTree")
    }
    if ($LiteralPathspecs) {
        $Info.ArgumentList.Add('--literal-pathspecs')
    }
    foreach ($Fixed in '-c', 'safe.directory=*', '-c', 'core.quotepath=false', '-c', 'core.fsmonitor=false') {
        $Info.ArgumentList.Add($Fixed)
    }
    foreach ($Argument in $Arguments) {
        $Info.ArgumentList.Add($Argument)
    }

    return Invoke-AgentSyncBoundedProcess -StartInfo $Info -TimeoutSeconds $TimeoutSeconds -MaxOutputCharacters $MaxOutputCharacters
}

function Write-AgentSyncHistoryText {
    param ([string]$Path, [string]$Text)

    # No byte order mark: Git reads the first line of an exclude file literally.
    $Directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $Directory)) {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

function Initialize-AgentSyncHistoryRepository {
    param ($Unit, $Settings)

    $Repository = $Unit.RepositoryPath
    # Bump when the settings below change; an existing repository is then
    # brought up to date once instead of being reconfigured for every snapshot.
    $SettingsRevision = '1'
    $RevisionFile = Join-Path $Repository 'agentsync\settings-revision.txt'
    if ((Test-Path -LiteralPath $RevisionFile) -and ((Get-Content -LiteralPath $RevisionFile -Raw).Trim() -eq $SettingsRevision)) {
        return
    }

    if (-not (Test-Path -LiteralPath (Join-Path $Repository 'HEAD'))) {
        New-Item -ItemType Directory -Path $Repository -Force | Out-Null
        $Init = Invoke-AgentSyncHistoryGit -Repository $Repository -Arguments @('init', '--bare', '--quiet', $Repository)
        if ($Init.ExitCode -ne 0) {
            throw "Could not create the history repository for $($Unit.RelativePath): $($Init.StdErr.Trim())"
        }
    }

    $Wanted = [ordered]@{
        # Without this a path over 260 characters is skipped with exit code 0.
        'core.longpaths'   = 'true'
        'core.autocrlf'    = 'false'
        'core.safecrlf'    = 'false'
        'core.fsmonitor'   = 'false'
        'core.symlinks'    = 'false'
        # History is never pruned behind the user's back, and a repack never
        # starts in the middle of a snapshot.
        'gc.auto'          = '0'
        'gc.pruneExpire'   = 'never'
        'gc.reflogExpire'  = 'never'
        'commit.gpgsign'   = 'false'
    }
    foreach ($Key in $Wanted.Keys) {
        $Set = Invoke-AgentSyncHistoryGit -Repository $Repository -Arguments @('config', $Key, $Wanted[$Key])
        if ($Set.ExitCode -ne 0) {
            throw "Could not configure the history repository ($Key): $($Set.StdErr.Trim())"
        }
    }

    # info/attributes outranks any .gitattributes in the project, so the bytes
    # stored are the bytes on disk: no line-ending conversion, no LFS pointer.
    Write-AgentSyncHistoryText -Path (Join-Path $Repository 'info\attributes') -Text "* -text -filter -ident`n"

    $UnitFile = Join-Path $Repository 'agentsync\unit.json'
    if (-not (Test-Path -LiteralPath $UnitFile)) {
        $Record = [ordered]@{
            format       = 1
            id           = $Unit.Id
            path         = $Unit.Path
            relativePath = $Unit.RelativePath
            kind         = $Unit.Kind
            machine      = $Settings.MachineId
            createdUtc   = [System.DateTime]::UtcNow.ToString('o')
        }
        Write-AgentSyncHistoryText -Path $UnitFile -Text (($Record | ConvertTo-Json -Depth 4) + "`n")
    }
    Write-AgentSyncHistoryText -Path $RevisionFile -Text "$SettingsRevision`n"
}

function Get-AgentSyncHistoryLineTip {
    param ($Unit, [string]$Line)

    # The newest snapshot of one line and its tree, or nothing before the baseline.
    if (-not (Test-Path -LiteralPath (Join-Path $Unit.RepositoryPath 'HEAD'))) {
        return $null
    }
    $Ref = Invoke-AgentSyncHistoryGit -Repository $Unit.RepositoryPath -Arguments @('rev-parse', "refs/heads/$Line^{commit}", "refs/heads/$Line^{tree}")
    $Ids = @($Ref.StdOut -split "`r?`n" | Where-Object { $_ -match '^[0-9a-f]{40,64}$' })
    if ($Ref.ExitCode -ne 0 -or $Ids.Count -ne 2) {
        return $null
    }
    return [pscustomobject]@{ Commit = $Ids[0]; Tree = $Ids[1] }
}

function ConvertTo-AgentSyncHistoryIgnorePattern {
    param ([string]$RelativePath, [switch]$Directory)

    # Anchored and escaped: the path is a literal, never a glob.
    $Path = ($RelativePath -replace '\\', '/').Trim('/')
    $Escaped = [System.Text.RegularExpressions.Regex]::Replace($Path, '([\\*?\[\]])', '\$1')
    if ($Escaped.EndsWith(' ')) {
        $Escaped = $Escaped.Substring(0, $Escaped.Length - 1) + '\ '
    }
    $Pattern = "/$Escaped"
    if ($Directory) {
        $Pattern += '/'
    }
    return $Pattern
}

function Test-AgentSyncHistorySecretName {
    param ([string]$Name, $Settings)

    $Lower = $Name.ToLowerInvariant()
    if ($Lower -eq '.env' -or $Lower.StartsWith('.env.')) {
        return ($Lower -notin @('.env.example', '.env.sample', '.env.template'))
    }
    if ($Settings.SecretNames -contains $Lower) {
        return $true
    }
    foreach ($Suffix in $Settings.SecretSuffixes) {
        if ($Lower.EndsWith($Suffix)) { return $true }
    }
    if ($Settings.SecretPattern -and $Lower -match $Settings.SecretPattern) {
        $Extension = [System.IO.Path]::GetExtension($Lower)
        if (-not ($Extension -and ($Settings.SecretWordSafeExtensions -contains $Extension))) {
            return $true
        }
    }
    return ($Lower.Contains('service-account') -or $Lower.Contains('service_account'))
}

function Get-AgentSyncHistoryPrescan {
    param (
        [string]$Root,
        [string]$Line,
        [string[]]$NestedUnits = @(),
        # Folders this line leaves out by policy. They are not walked at all:
        # a manifest that named what was never in scope would mislead the reader.
        [string[]]$ExcludedRoots = @(),
        $Settings
    )

    # One walk answers everything Git cannot be trusted with on its own:
    # links that lead out of the project, files that exist only in the cloud,
    # files too large for a Git object, and repositories inside the project.
    $IsState = $Line.StartsWith('state')
    $Threshold = if ($IsState) { $Settings.StateLargeFileBytes } else { $Settings.LargeFileBytes }
    $NotLocalMask = 0x1000 -bor 0x40000 -bor 0x400000   # OFFLINE, RECALL_ON_OPEN, RECALL_ON_DATA_ACCESS
    $RootPath = Get-AgentSyncHistoryNormalizedPath -Path $Root

    $Patterns = [System.Collections.Generic.List[string]]::new()
    $Skipped = [System.Collections.Generic.List[object]]::new()
    $Unreadable = [System.Collections.Generic.List[object]]::new()
    $Large = [System.Collections.Generic.List[object]]::new()
    $FileCount = 0
    $OutOfScope = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Excluded in $ExcludedRoots) {
        $Name = ($Excluded -replace '\\', '/').Trim('/')
        if ($Name -and -not $Name.Contains('/')) { [void]$OutOfScope.Add($Name) }
    }

    $Stack = [System.Collections.Generic.Stack[string]]::new()
    $Stack.Push($RootPath)
    while ($Stack.Count -gt 0) {
        $Directory = $Stack.Pop()
        try {
            $Entries = @([System.IO.DirectoryInfo]::new($Directory).EnumerateFileSystemInfos())
        }
        catch {
            $Relative = $Directory.Substring($RootPath.Length).TrimStart('\', '/')
            $Unreadable.Add([pscustomobject]@{ path = ($Relative -replace '\\', '/'); reason = 'directory could not be listed' })
            continue
        }

        foreach ($Entry in $Entries) {
            $Relative = $Entry.FullName.Substring($RootPath.Length).TrimStart('\', '/')
            $RelativeSlash = $Relative -replace '\\', '/'
            $IsDirectory = [bool]($Entry.Attributes -band [System.IO.FileAttributes]::Directory)

            # A cloud placeholder is a reparse point too, but it has no link
            # target. Only a real link can lead out of the project.
            if (($Entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -and $Entry.LinkTarget) {
                $Patterns.Add((ConvertTo-AgentSyncHistoryIgnorePattern -RelativePath $Relative -Directory:$IsDirectory))
                $Skipped.Add([pscustomobject]@{ path = $RelativeSlash; reason = 'link' })
                continue
            }

            if ($IsDirectory) {
                if ($Entry.Name -eq '.git') { continue }
                if (-not $IsState -and $Entry.Name -eq '.agent-state') { continue }
                if ($Settings.ExcludedDirectories -contains $Entry.Name) { continue }
                if ($Directory -eq $RootPath -and $OutOfScope.Contains($Entry.Name)) { continue }
                if (Test-AgentSyncHistorySecretName -Name $Entry.Name -Settings $Settings) {
                    $Patterns.Add((ConvertTo-AgentSyncHistoryIgnorePattern -RelativePath $Relative -Directory))
                    $Skipped.Add([pscustomobject]@{ path = $RelativeSlash; reason = 'secret' })
                    continue
                }
                if (Test-AgentSyncHistoryGitRoot -Path $Entry.FullName) {
                    $Known = [bool]($NestedUnits | Where-Object { $_ -eq (Get-AgentSyncHistoryNormalizedPath -Path $Entry.FullName) })
                    $Patterns.Add((ConvertTo-AgentSyncHistoryIgnorePattern -RelativePath $Relative -Directory))
                    $Skipped.Add([pscustomobject]@{ path = $RelativeSlash; reason = 'nested-repository'; ownHistory = $Known })
                    continue
                }
                if ($NestedUnits | Where-Object { $_ -eq (Get-AgentSyncHistoryNormalizedPath -Path $Entry.FullName) }) {
                    $Patterns.Add((ConvertTo-AgentSyncHistoryIgnorePattern -RelativePath $Relative -Directory))
                    $Skipped.Add([pscustomobject]@{ path = $RelativeSlash; reason = 'nested-project'; ownHistory = $true })
                    continue
                }
                $Stack.Push($Entry.FullName)
                continue
            }

            $FileCount++
            if (Test-AgentSyncHistorySecretName -Name $Entry.Name -Settings $Settings) {
                $Patterns.Add((ConvertTo-AgentSyncHistoryIgnorePattern -RelativePath $Relative))
                $Skipped.Add([pscustomobject]@{ path = $RelativeSlash; reason = 'secret' })
                continue
            }
            if (([int]$Entry.Attributes -band $NotLocalMask) -ne 0) {
                # Reading it would download it. It is named as missing instead.
                $Patterns.Add((ConvertTo-AgentSyncHistoryIgnorePattern -RelativePath $Relative))
                $Unreadable.Add([pscustomobject]@{ path = $RelativeSlash; reason = 'not local (online-only)' })
                continue
            }
            if ($Entry.Length -gt $Threshold) {
                $Large.Add([pscustomobject]@{ Relative = $Relative; RelativeSlash = $RelativeSlash; FullName = $Entry.FullName; Bytes = [long]$Entry.Length; ModifiedTicks = $Entry.LastWriteTimeUtc.Ticks })
            }
        }
    }

    return [pscustomobject]@{
        Patterns   = $Patterns
        Skipped    = $Skipped
        Unreadable = $Unreadable
        Large      = $Large
        FileCount  = $FileCount
    }
}

function Get-AgentSyncHistoryFileSha256 {
    param ([string]$Path)

    # ReadWrite sharing: a file an agent holds open for writing must still hash.
    $Stream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $Sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            return [System.BitConverter]::ToString($Sha.ComputeHash($Stream)).Replace('-', '').ToLowerInvariant()
        }
        finally {
            $Sha.Dispose()
        }
    }
    finally {
        $Stream.Dispose()
    }
}

function Save-AgentSyncHistoryLargeFile {
    param ($Unit, $File, [hashtable]$HashCache, $Settings)

    # Returns the manifest entry. A large file is kept once per content, as a
    # plain copy: a link to the live project would change when the project does.
    $Key = $File.RelativeSlash.ToLowerInvariant()
    $Cached = $HashCache[$Key]
    if ($Cached -and [long]$Cached.bytes -eq $File.Bytes -and [long]$Cached.modifiedTicks -eq $File.ModifiedTicks) {
        $Hash = [string]$Cached.sha256
    }
    else {
        $Hash = Get-AgentSyncHistoryFileSha256 -Path $File.FullName
        $HashCache[$Key] = [pscustomobject]@{ bytes = $File.Bytes; modifiedTicks = $File.ModifiedTicks; sha256 = $Hash }
    }

    $Stored = $false
    if ($Settings.StoreLargeFiles) {
        $Target = Join-Path $Unit.RepositoryPath ("agentsync\large\{0}\{1}" -f $Hash.Substring(0, 2), $Hash)
        if (-not (Test-Path -LiteralPath $Target)) {
            $Temporary = "$Target.$PID.tmp"
            New-Item -ItemType Directory -Path (Split-Path -Parent $Target) -Force | Out-Null
            $Source = [System.IO.FileStream]::new($File.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                $Destination = [System.IO.FileStream]::new($Temporary, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                try {
                    $Source.CopyTo($Destination)
                    $Destination.Flush($true)
                }
                finally {
                    $Destination.Dispose()
                }
            }
            finally {
                $Source.Dispose()
            }
            # The copy is only history if it is the content that was hashed.
            if ((Get-AgentSyncHistoryFileSha256 -Path $Temporary) -ne $Hash) {
                Remove-Item -LiteralPath $Temporary -Force -ErrorAction SilentlyContinue
                throw "The large file changed while it was copied: $($File.RelativeSlash)"
            }
            [System.IO.File]::Move($Temporary, $Target, $false)
        }
        $Stored = $true
    }

    return [pscustomobject]@{ path = $File.RelativeSlash; reason = 'large'; bytes = $File.Bytes; sha256 = $Hash; stored = $Stored }
}

function ConvertFrom-AgentSyncHistoryAddErrors {
    param ([string]$StdErr)

    # git add --ignore-errors keeps going and says what it could not read.
    # The exit code alone is not enough: an over-long path is only a warning.
    $Unreadable = [System.Collections.Generic.List[object]]::new()
    $Nested = [System.Collections.Generic.List[string]]::new()
    $Other = [System.Collections.Generic.List[string]]::new()
    $Fatal = $null
    $Seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($RawLine in ($StdErr -split "`r?`n")) {
        $TextLine = $RawLine.Trim()
        if (-not $TextLine -or $TextLine.StartsWith('hint:')) { continue }
        if ($TextLine -match '^error: open\("(?<path>.+)"\): (?<why>.+)$') {
            if ($Seen.Add($Matches.path)) { $Unreadable.Add([pscustomobject]@{ path = $Matches.path; reason = $Matches.why }) }
        }
        elseif ($TextLine -match "^error: unable to index file '(?<path>.+)'$") {
            if ($Seen.Add($Matches.path)) { $Unreadable.Add([pscustomobject]@{ path = $Matches.path; reason = 'could not be read' }) }
        }
        elseif ($TextLine -match "^warning: unable to access '(?<path>.+)': (?<why>.+)$") {
            if ($Seen.Add($Matches.path)) { $Unreadable.Add([pscustomobject]@{ path = $Matches.path; reason = $Matches.why }) }
        }
        elseif ($TextLine -match "^error: '(?<path>.+?)/?' does not have a commit checked out$") {
            $Nested.Add($Matches.path)
        }
        elseif ($TextLine -match '^warning: adding embedded git repository: (?<path>.+)$') {
            $Nested.Add($Matches.path)
        }
        elseif ($TextLine -match '^fatal: (?<why>.+)$') {
            $Fatal = $Matches.why
        }
        elseif ($TextLine -ne 'error: unable to index file') {
            $Other.Add($TextLine)
        }
    }

    return [pscustomobject]@{ Unreadable = $Unreadable; Nested = $Nested; Other = $Other; Fatal = $Fatal }
}

function Get-AgentSyncHistoryNullSeparated {
    param ([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return @()
    }
    return @($Text.Split([char]0, [System.StringSplitOptions]::RemoveEmptyEntries))
}

function New-AgentSyncHistorySnapshot {
    param (
        $Unit,
        [string]$Line = 'work',
        [string]$WorkTree,
        $Settings,
        [string]$Trigger = 'manual',
        [string]$MissionId = '',
        [string[]]$ObservedSessions = @(),
        [switch]$AllowBaseline,
        [switch]$DryRun
    )

    $ManifestPath = '.agentsync-history/manifest.json'
    $Timer = [System.Diagnostics.Stopwatch]::StartNew()
    $Result = [ordered]@{
        Unit = $Unit.Id; RelativePath = $Unit.RelativePath; Line = $Line; Trigger = $Trigger
        Outcome = 'failed'; Completeness = $null; Reason = $null
        Commit = $null; Parent = $null; Added = 0; Modified = 0; Deleted = 0
        Skipped = 0; Unreadable = 0; ChangedPaths = @(); Seconds = 0
        MissionId = $MissionId; ObservedSessions = @($ObservedSessions)
    }
    $Finish = {
        param ([string]$Outcome, [string]$Reason)
        $Result.Outcome = $Outcome
        $Result.Reason = if ($Reason) { $Reason } else { $null }
        $Result.Seconds = [math]::Round($Timer.Elapsed.TotalSeconds, 1)
        return [pscustomobject]$Result
    }

    $ExtraLine = @($Unit.ExtraLines) | Where-Object Line -EQ $Line | Select-Object -First 1
    if (-not $WorkTree) {
        $WorkTree = if ($Line -eq 'work') { $Unit.Path }
        elseif ($ExtraLine) { $ExtraLine.Path }
        else { (@($Unit.StateLines) | Where-Object Line -EQ $Line | Select-Object -First 1).Path }
    }
    if (-not $WorkTree -or -not (Test-Path -LiteralPath $WorkTree -PathType Container)) {
        return (& $Finish 'failed' 'the folder to snapshot does not exist')
    }

    $ExcludedRoots = @(if ($ExtraLine) { $ExtraLine.Exclude })
    if ($DryRun) {
        $Scan = Get-AgentSyncHistoryPrescan -Root $WorkTree -Line $Line -NestedUnits $Unit.NestedUnits -ExcludedRoots $ExcludedRoots -Settings $Settings
        Write-AgentSyncHistoryLog -Level 'INFO' -Message "DRYRUN HISTORY_SNAPSHOT unit=$($Unit.Id) line=$Line trigger=$Trigger files=$($Scan.FileCount) large=$($Scan.Large.Count) skipped=$($Scan.Skipped.Count)"
        $Result.Skipped = $Scan.Skipped.Count + $Scan.Large.Count
        $Result.Unreadable = $Scan.Unreadable.Count
        return (& $Finish 'dry-run' $null)
    }

    $MutexName = Get-AgentSyncHistoryMutexName -Kind Unit -Path $Unit.RepositoryPath
    $Mutex = [System.Threading.Mutex]::new($false, $MutexName)
    $Held = $false
    try {
        try { $Held = $Mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $Held = $true }
        if (-not $Held) {
            return (& $Finish 'busy' 'another snapshot of this project is running')
        }

        # Read the parent under the same lock as the write. A competing first
        # snapshot must not turn a stale "no parent" read into a new root commit.
        $Tip = Get-AgentSyncHistoryLineTip -Unit $Unit -Line $Line
        $HasBaseline = ($null -ne $Tip)
        if (-not $HasBaseline -and -not $AllowBaseline) {
            # The first snapshot can take minutes and is always deliberate.
            return (& $Finish 'no-baseline' 'run -Initialize for this project first')
        }

        New-Item -ItemType Directory -Path $Settings.StoreDirectory -Force | Out-Null
        $Drive = [System.IO.DriveInfo]::new([System.IO.Path]::GetPathRoot($Settings.StoreDirectory))
        if ($Drive.AvailableFreeSpace -lt $Settings.MinFreeBytes) {
            return (& $Finish 'failed' ("the history drive has {0:N1} GB free; the limit is {1:N0} GB" -f ($Drive.AvailableFreeSpace / 1GB), ($Settings.MinFreeBytes / 1GB)))
        }

        Initialize-AgentSyncHistoryRepository -Unit $Unit -Settings $Settings
        $Repository = $Unit.RepositoryPath
        $Control = Join-Path $Repository 'agentsync'
        $IndexFile = Join-Path $Control "$Line.index"
        $ExcludeFile = Join-Path $Control "$Line.exclude"
        $Timeout = if ($HasBaseline) { $Settings.SnapshotTimeoutSeconds } else { $Settings.BaselineTimeoutSeconds }

        # A killed Git leaves its lock behind. The unit mutex says nobody else
        # is writing this index, so the lock can only be stale.
        Remove-Item -LiteralPath "$IndexFile.lock" -Force -ErrorAction SilentlyContinue

        $Scan = Get-AgentSyncHistoryPrescan -Root $WorkTree -Line $Line -NestedUnits $Unit.NestedUnits -ExcludedRoots $ExcludedRoots -Settings $Settings

        $Patterns = [System.Collections.Generic.List[string]]::new()
        $Patterns.Add('# Generated by AgentSync for every snapshot. Edits are overwritten.')
        if ($Line -eq 'work') {
            $Patterns.Add('.agent-state/')
        }
        elseif ($ExtraLine) {
            $Patterns.Add('*.tmp')
            foreach ($Pattern in $ExtraLine.Exclude) { $Patterns.Add($Pattern) }
        }
        else {
            # Control plane that changes every cycle, and SQLite sidecars that
            # only mean something beside the process that wrote them.
            foreach ($Pattern in '/activity/', '/conflicts/overwritten/', '/manifest.json', '*.tmp', '*.db-wal', '*.db-shm', '*.db-journal') { $Patterns.Add($Pattern) }
        }
        foreach ($Name in $Settings.ExcludedDirectories) { $Patterns.Add("$Name/") }
        foreach ($Pattern in '.env', '.env.*', '!.env.example', '!.env.sample', '!.env.template') { $Patterns.Add($Pattern) }
        foreach ($Name in $Settings.SecretNames) { $Patterns.Add($Name) }
        foreach ($Suffix in $Settings.SecretSuffixes) { $Patterns.Add("*$Suffix") }
        foreach ($Pattern in '*service-account*', '*service_account*') { $Patterns.Add($Pattern) }
        $Patterns.AddRange($Scan.Patterns)

        # Large files: decided against the project's own ignore rules first, so
        # an ignored build artifact is not copied just because it is big.
        $EmptyExclude = Join-Path $Control 'empty.exclude'
        if (-not (Test-Path -LiteralPath $EmptyExclude)) { Write-AgentSyncHistoryText -Path $EmptyExclude -Text '' }
        $HashCacheFile = Join-Path $Control "$Line.large-index.json"
        $HashCache = @{}
        if (Test-Path -LiteralPath $HashCacheFile) {
            try {
                $Loaded = Get-Content -LiteralPath $HashCacheFile -Raw | ConvertFrom-Json
                foreach ($Property in $Loaded.PSObject.Properties) { $HashCache[$Property.Name] = $Property.Value }
            }
            catch { $HashCache = @{} }
        }
        $Skipped = [System.Collections.Generic.List[object]]::new()
        $Skipped.AddRange($Scan.Skipped)
        $Unreadable = [System.Collections.Generic.List[object]]::new()
        $Unreadable.AddRange($Scan.Unreadable)
        $Warnings = [System.Collections.Generic.List[string]]::new()
        foreach ($File in $Scan.Large) {
            $Ignored = Invoke-AgentSyncHistoryGit -Repository $Repository -WorkTree $WorkTree -IndexFile $IndexFile -Arguments @('-c', "core.excludesFile=$EmptyExclude", 'check-ignore', '--quiet', '--no-index', '--', $File.RelativeSlash)
            if ($Ignored.ExitCode -eq 0) { continue }
            if ($Ignored.ExitCode -ne 1) {
                # Not knowing is not a reason to drop it: the file is kept, and the doubt is recorded.
                $Warnings.Add("could not ask the project's ignore rules about $($File.RelativeSlash): $($Ignored.StdErr.Trim())")
            }
            $Patterns.Add((ConvertTo-AgentSyncHistoryIgnorePattern -RelativePath $File.Relative))
            try {
                $Skipped.Add((Save-AgentSyncHistoryLargeFile -Unit $Unit -File $File -HashCache $HashCache -Settings $Settings))
            }
            catch {
                $Unreadable.Add([pscustomobject]@{ path = $File.RelativeSlash; reason = "large file could not be kept: $($_.Exception.Message)" })
            }
        }
        Write-AgentSyncHistoryText -Path $HashCacheFile -Text (([pscustomobject]$HashCache | ConvertTo-Json -Depth 4) + "`n")
        Write-AgentSyncHistoryText -Path $ExcludeFile -Text (($Patterns -join "`n") + "`n")

        # A .gitignore negation outranks core.excludesFile, and tracked files
        # bypass ignore rules entirely. Remove previously indexed secrets before
        # add can read their new contents; explicit exclude pathspecs also keep
        # them out of Git's object database on the first snapshot.
        $SecretPaths = @($Scan.Skipped | Where-Object reason -EQ 'secret' | ForEach-Object { $_.path } | Sort-Object -Unique)
        if ($SecretPaths.Count -gt 0 -and (Test-Path -LiteralPath $IndexFile)) {
            $SecretFile = Join-Path $Control "$Line.secrets.tmp"
            try {
                Write-AgentSyncHistoryText -Path $SecretFile -Text (($SecretPaths -join [char]0) + [char]0)
                # Only the private history index is changed. Force is needed
                # when its old contents differ from the current working file.
                $RemoveSecrets = Invoke-AgentSyncHistoryGit -Repository $Repository -WorkTree $WorkTree -IndexFile $IndexFile -LiteralPathspecs -Arguments @('rm', '--cached', '--force', '-r', '--quiet', '--ignore-unmatch', "--pathspec-from-file=$SecretFile", '--pathspec-file-nul')
                if ($RemoveSecrets.TimedOut -or $RemoveSecrets.ExitCode -ne 0) {
                    return (& $Finish 'failed' 'classified secrets could not be removed from the history index; no files were added')
                }
            }
            finally {
                Remove-Item -LiteralPath $SecretFile -Force -ErrorAction SilentlyContinue
            }
        }
        if ($SecretPaths.Count -gt 0) {
            # File transport avoids Windows command-line size limits. Each
            # exclusion is literal, including names with brackets or glob chars.
            $AddPaths = @('.') + @($SecretPaths | ForEach-Object { ":(top,literal,exclude)$_" })
            $AddPathsFile = Join-Path $Control "$Line.paths.tmp"
            try {
                Write-AgentSyncHistoryText -Path $AddPathsFile -Text (($AddPaths -join [char]0) + [char]0)
                $Add = Invoke-AgentSyncHistoryGit -Repository $Repository -WorkTree $WorkTree -IndexFile $IndexFile -TimeoutSeconds $Timeout -Arguments @('-c', "core.excludesFile=$ExcludeFile", 'add', '--all', '--ignore-errors', "--pathspec-from-file=$AddPathsFile", '--pathspec-file-nul')
            }
            finally {
                Remove-Item -LiteralPath $AddPathsFile -Force -ErrorAction SilentlyContinue
            }
        }
        else {
            $Add = Invoke-AgentSyncHistoryGit -Repository $Repository -WorkTree $WorkTree -IndexFile $IndexFile -TimeoutSeconds $Timeout -LiteralPathspecs -Arguments @('-c', "core.excludesFile=$ExcludeFile", 'add', '--all', '--ignore-errors', '--', '.')
        }
        if ($Add.TimedOut) {
            return (& $Finish 'failed' "git add did not finish within $Timeout seconds")
        }
        $Problems = ConvertFrom-AgentSyncHistoryAddErrors -StdErr $Add.StdErr
        if ($Problems.Fatal) {
            return (& $Finish 'failed' "git add: $($Problems.Fatal)")
        }
        $Unreadable.AddRange($Problems.Unreadable)
        $Warnings.AddRange($Problems.Other)
        if ($Add.OutputTruncated) {
            $Warnings.Add('git reported more problems than were kept; the list above is incomplete')
        }

        # Ignore rules do not apply to a path that is already in the index.
        # Removing what the rules now exclude keeps them authoritative: a file
        # that grew past the limit, or that the project started to ignore.
        $Tracked = Invoke-AgentSyncHistoryGit -Repository $Repository -WorkTree $WorkTree -IndexFile $IndexFile -Arguments @('-c', "core.excludesFile=$ExcludeFile", 'ls-files', '--cached', '--ignored', '--exclude-standard', '-z')
        $Stale = [System.Collections.Generic.List[string]]::new()
        foreach ($Path in (Get-AgentSyncHistoryNullSeparated -Text $Tracked.StdOut)) {
            if ($Path -ne $ManifestPath) { $Stale.Add($Path) }
        }

        # The prescan leaves out every repository it finds inside the project.
        # One that appears between the scan and the add arrives as a gitlink: a
        # commit id with none of the content. Git says so when it adds it, and
        # it is taken out again and named, never kept as if it were history.
        foreach ($Path in ($Problems.Nested | Sort-Object -Unique)) {
            $Stale.Add($Path.TrimEnd('/'))
            if (-not ($Skipped | Where-Object { $_.path -eq $Path.TrimEnd('/') })) {
                $Unreadable.Add([pscustomobject]@{ path = $Path.TrimEnd('/'); reason = 'a repository inside the project that has no history of its own yet' })
            }
        }
        if ($Stale.Count -gt 0) {
            $StaleFile = Join-Path $Control "$Line.stale.tmp"
            [System.IO.File]::WriteAllText($StaleFile, (($Stale | Sort-Object -Unique) -join [char]0), [System.Text.UTF8Encoding]::new($false))
            $Remove = Invoke-AgentSyncHistoryGit -Repository $Repository -WorkTree $WorkTree -IndexFile $IndexFile -LiteralPathspecs -Arguments @('rm', '--cached', '-r', '--quiet', '--ignore-unmatch', "--pathspec-from-file=$StaleFile", '--pathspec-file-nul')
            Remove-Item -LiteralPath $StaleFile -Force -ErrorAction SilentlyContinue
            if ($Remove.ExitCode -ne 0) {
                $Warnings.Add("excluded paths could not be removed from the snapshot: $($Remove.StdErr.Trim())")
            }
        }

        # The manifest travels inside the snapshot, as an index entry with no
        # file behind it: nothing is written into the project. It holds no time
        # and no trigger, so an unchanged project gives an unchanged tree.
        $Manifest = [ordered]@{
            schema     = 1
            line       = $Line
            policy     = [ordered]@{ largeFileBytes = $(if ($Line -eq 'work') { $Settings.LargeFileBytes } else { $Settings.StateLargeFileBytes }); largeFilesStored = $Settings.StoreLargeFiles }
            skipped    = @($Skipped | Sort-Object path)
            unreadable = @($Unreadable | Sort-Object path)
            warnings   = @($Warnings | Sort-Object)
        }
        $ManifestFile = Join-Path $Control "$Line.manifest.tmp"
        Write-AgentSyncHistoryText -Path $ManifestFile -Text (($Manifest | ConvertTo-Json -Depth 6) + "`n")
        $Blob = Invoke-AgentSyncHistoryGit -Repository $Repository -Arguments @('hash-object', '-w', '--no-filters', '--', $ManifestFile)
        Remove-Item -LiteralPath $ManifestFile -Force -ErrorAction SilentlyContinue
        if ($Blob.ExitCode -ne 0) {
            return (& $Finish 'failed' "the manifest could not be stored: $($Blob.StdErr.Trim())")
        }
        $Entry = Invoke-AgentSyncHistoryGit -Repository $Repository -IndexFile $IndexFile -Arguments @('update-index', '--add', '--cacheinfo', "100644,$($Blob.StdOut.Trim()),$ManifestPath")
        if ($Entry.ExitCode -ne 0) {
            return (& $Finish 'failed' "the manifest could not be added: $($Entry.StdErr.Trim())")
        }

        $Tree = Invoke-AgentSyncHistoryGit -Repository $Repository -IndexFile $IndexFile -Arguments @('write-tree')
        if ($Tree.ExitCode -ne 0) {
            return (& $Finish 'failed' "write-tree: $($Tree.StdErr.Trim())")
        }
        $TreeId = $Tree.StdOut.Trim()

        $Result.Skipped = $Skipped.Count
        $Result.Unreadable = $Unreadable.Count
        # Complete means: everything the rules say belongs in the snapshot is
        # in it. One unread file is enough to make it partial.
        $Result.Completeness = if ($Unreadable.Count -eq 0 -and $Warnings.Count -eq 0) { 'complete' } else { 'partial' }

        $Ref = "refs/heads/$Line"
        $Parent = $null
        if ($HasBaseline) {
            $Parent = $Tip.Commit
            $Result.Parent = $Parent
            if ($Tip.Tree -eq $TreeId) {
                $Result.Commit = $Parent
                return (& $Finish 'unchanged' $null)
            }
        }

        $Message = [System.Collections.Generic.List[string]]::new()
        $Message.Add("snapshot $Line $Trigger")
        $Message.Add('')
        $Message.Add("Trigger: $Trigger")
        $Message.Add("Machine: $($Settings.MachineId)")
        $Message.Add("Status: $($Result.Completeness)")
        if ($MissionId) { $Message.Add("Mission: $MissionId") }
        # Observed, not authored: a session was active when the snapshot was
        # taken. Who changed which file is not something a snapshot can know.
        if ($ObservedSessions.Count -gt 0) { $Message.Add("Observed-Sessions: $($ObservedSessions -join ', ')") }
        $MessageFile = Join-Path $Control "$Line.message.tmp"
        Write-AgentSyncHistoryText -Path $MessageFile -Text (($Message -join "`n") + "`n")
        $CommitArguments = @('commit-tree', $TreeId, '--no-gpg-sign', '-F', $MessageFile)
        if ($Parent) { $CommitArguments += @('-p', $Parent) }
        $Commit = Invoke-AgentSyncHistoryGit -Repository $Repository -Arguments $CommitArguments
        Remove-Item -LiteralPath $MessageFile -Force -ErrorAction SilentlyContinue
        if ($Commit.ExitCode -ne 0) {
            return (& $Finish 'failed' "commit-tree: $($Commit.StdErr.Trim())")
        }
        $CommitId = $Commit.StdOut.Trim()

        $UpdateArguments = @('update-ref', $Ref, $CommitId)
        if ($Parent) { $UpdateArguments += $Parent }
        $Update = Invoke-AgentSyncHistoryGit -Repository $Repository -Arguments $UpdateArguments
        if ($Update.ExitCode -ne 0) {
            return (& $Finish 'failed' "update-ref: $($Update.StdErr.Trim())")
        }
        $Result.Commit = $CommitId

        $ChangedPaths = [System.Collections.Generic.List[string]]::new()
        if ($Parent) {
            $Diff = Invoke-AgentSyncHistoryGit -Repository $Repository -Arguments @('diff-tree', '-r', '--no-commit-id', '--name-status', '-z', $Parent, $CommitId)
            $Fields = Get-AgentSyncHistoryNullSeparated -Text $Diff.StdOut
            for ($Index = 0; $Index + 1 -lt $Fields.Count; $Index += 2) {
                $Path = $Fields[$Index + 1]
                if ($Path -eq $ManifestPath) { continue }
                switch ($Fields[$Index].Substring(0, 1)) {
                    'A' { $Result.Added++ }
                    'D' { $Result.Deleted++ }
                    default { $Result.Modified++ }
                }
                $ChangedPaths.Add($Path)
            }
        }
        else {
            $Listing = Invoke-AgentSyncHistoryGit -Repository $Repository -Arguments @('ls-tree', '-r', '--name-only', '-z', $CommitId)
            $Result.Added = @(Get-AgentSyncHistoryNullSeparated -Text $Listing.StdOut | Where-Object { $_ -ne $ManifestPath }).Count
        }
        $Result.ChangedPaths = @($ChangedPaths)
        return (& $Finish 'committed' $null)
    }
    catch {
        return (& $Finish 'failed' $_.Exception.Message)
    }
    finally {
        if ($Held) { $Mutex.ReleaseMutex() }
        $Mutex.Dispose()
    }
}

function Get-AgentSyncHistoryLineHash {
    param ([string]$Line)

    $Sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [System.BitConverter]::ToString($Sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Line))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $Sha.Dispose()
    }
}

function Get-AgentSyncHistoryLastLine {
    param ([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    $Stream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $Take = [math]::Min([long]262144, $Stream.Length)
        if ($Take -le 0) { return $null }
        [void]$Stream.Seek(-$Take, [System.IO.SeekOrigin]::End)
        $Buffer = [byte[]]::new($Take)
        $Read = 0
        while ($Read -lt $Take) {
            $Count = $Stream.Read($Buffer, $Read, $Take - $Read)
            if ($Count -le 0) { break }
            $Read += $Count
        }
        $Lines = [System.Text.Encoding]::UTF8.GetString($Buffer, 0, $Read) -split "`n" | Where-Object { $_.Trim() }
        if (-not $Lines) { return $null }
        return @($Lines)[-1].TrimEnd("`r")
    }
    finally {
        $Stream.Dispose()
    }
}

function Add-AgentSyncHistoryLedgerEntry {
    param ($Settings, [System.Collections.IDictionary]$Entry)

    # One writer per machine folder, one line per event, each line carrying the
    # hash of the line before it. Metadata only: no prompt, no code, no command.
    $Directory = Join-Path $Settings.ExportDirectory 'ledger'
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $Now = [System.DateTime]::UtcNow
    $File = Join-Path $Directory ("{0:yyyy-MM}.jsonl" -f $Now)

    $MutexName = Get-AgentSyncHistoryMutexName -Kind Ledger -Path $Directory
    $Mutex = [System.Threading.Mutex]::new($false, $MutexName)
    $Held = $false
    try {
        try { $Held = $Mutex.WaitOne(30000) } catch [System.Threading.AbandonedMutexException] { $Held = $true }
        if (-not $Held) {
            throw 'The history ledger is held by another process.'
        }

        $Previous = Get-AgentSyncHistoryLastLine -Path $File
        if (-not $Previous) {
            $Earlier = Get-ChildItem -LiteralPath $Directory -Filter '*.jsonl' -File | Where-Object { $_.FullName -ne $File } | Sort-Object Name | Select-Object -Last 1
            if ($Earlier) { $Previous = Get-AgentSyncHistoryLastLine -Path $Earlier.FullName }
        }

        # A backward hash chain proves nothing about the end of the ledger: drop
        # the newest lines and every remaining link still matches. So each entry
        # also carries a number, and the tip is anchored in its own file. A gap
        # in the numbers or a tip that does not match the last line is a removal.
        $Sequence = 1
        if ($Previous) {
            $PreviousSequence = $null
            try { $PreviousSequence = ($Previous | ConvertFrom-Json).seq } catch { $PreviousSequence = $null }
            if ($null -ne $PreviousSequence) {
                $Sequence = [long]$PreviousSequence + 1
            }
            else {
                # Entries written before numbering existed. Continue past them by
                # counting, and never renumber what is already on disk.
                $Sequence = 1 + [long](@(Get-ChildItem -LiteralPath $Directory -Filter '*.jsonl' -File | ForEach-Object { [System.IO.File]::ReadAllLines($_.FullName) } | Where-Object { $_.Trim() }).Count)
            }
        }

        $Record = [ordered]@{ v = 1; seq = $Sequence; t = $Now.ToString('o'); machine = $Settings.MachineId }
        foreach ($Key in $Entry.Keys) { $Record[$Key] = $Entry[$Key] }
        $Record['prev'] = if ($Previous) { Get-AgentSyncHistoryLineHash -Line $Previous } else { $null }
        $Text = $Record | ConvertTo-Json -Compress -Depth 6

        $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Text + "`n")
        $Attempt = 0
        while ($true) {
            try {
                $Stream = [System.IO.FileStream]::new($File, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
                try {
                    $Stream.Write($Bytes, 0, $Bytes.Length)
                    $Stream.Flush($true)
                }
                finally {
                    $Stream.Dispose()
                }
                break
            }
            catch [System.IO.IOException] {
                # The sync client opens a file briefly while it uploads it.
                $Attempt++
                if ($Attempt -ge 5) { throw }
                Start-Sleep -Milliseconds 300
            }
        }
        $Hash = Get-AgentSyncHistoryLineHash -Line $Text
        # Written after the line is durable. A crash between the two leaves the
        # anchor one behind, which verification reports rather than hides.
        $Anchor = [ordered]@{ v = 1; seq = $Sequence; sha256 = $Hash; file = [System.IO.Path]::GetFileName($File); updatedUtc = $Now.ToString('o') }
        Write-AgentSyncHistoryText -Path (Join-Path $Directory 'tip.json') -Text (($Anchor | ConvertTo-Json -Depth 4) + "`n")
        return $Hash
    }
    finally {
        if ($Held) { $Mutex.ReleaseMutex() }
        $Mutex.Dispose()
    }
}

function Test-AgentSyncHistoryLedger {
    param ($Settings)

    # What this proves, and what it does not. The backward hash chain catches a
    # changed or reordered line. It cannot catch a removal at either end, since
    # every remaining link still matches, so two more checks are needed: the
    # numbers must run unbroken from 1, and the last line must match the anchor
    # written beside the ledger. Entries from before numbering existed cannot be
    # covered by the first of those, and are counted separately rather than
    # quietly included in a clean answer.
    $Directory = Join-Path $Settings.ExportDirectory 'ledger'
    $Lines = 0
    $Unsequenced = 0
    $Broken = [System.Collections.Generic.List[object]]::new()
    $PreviousHash = $null
    $PreviousSequence = $null
    $LastHash = $null
    $LastSequence = $null
    $LastFile = $null
    $First = $true
    $Files = @()
    if (Test-Path -LiteralPath $Directory) {
        $Files = @(Get-ChildItem -LiteralPath $Directory -Filter '*.jsonl' -File | Sort-Object Name)
    }

    foreach ($File in $Files) {
        $Number = 0
        foreach ($Line in [System.IO.File]::ReadAllLines($File.FullName)) {
            $Number++
            if (-not $Line.Trim()) { continue }
            $Lines++
            $Record = $null
            try { $Record = $Line | ConvertFrom-Json }
            catch {
                $Broken.Add([pscustomobject]@{ file = $File.Name; line = $Number; reason = 'not valid JSON' })
                $PreviousHash = Get-AgentSyncHistoryLineHash -Line $Line
                $PreviousSequence = $null
                $First = $false
                continue
            }

            if (-not $First -and $Record.prev -ne $PreviousHash) {
                $Broken.Add([pscustomobject]@{ file = $File.Name; line = $Number; reason = 'does not follow the line before it' })
            }

            $Sequence = $Record.seq
            if ($null -eq $Sequence) {
                $Unsequenced++
            }
            else {
                $Sequence = [long]$Sequence
                if ($null -ne $PreviousSequence -and $Sequence -ne ($PreviousSequence + 1)) {
                    $Broken.Add([pscustomobject]@{ file = $File.Name; line = $Number; reason = "number jumps from $PreviousSequence to $Sequence, so an entry is missing" })
                }
                $PreviousSequence = $Sequence
                $LastSequence = $Sequence
            }

            $PreviousHash = Get-AgentSyncHistoryLineHash -Line $Line
            $LastHash = $PreviousHash
            $LastFile = $File.Name
            $First = $false
        }
    }

    # The anchor is the only thing that can show the newest entries were removed.
    $AnchorPath = Join-Path $Directory 'tip.json'
    $AnchorState = 'missing'
    $Anchor = $null
    if (Test-Path -LiteralPath $AnchorPath) {
        try { $Anchor = Get-Content -LiteralPath $AnchorPath -Raw | ConvertFrom-Json; $AnchorState = 'read' }
        catch { $AnchorState = 'unreadable' }
    }

    if ($AnchorState -eq 'read') {
        if ($Lines -eq 0) {
            $Broken.Add([pscustomobject]@{ file = 'tip.json'; line = 0; reason = 'the anchor names an entry but the ledger is empty' })
        }
        elseif ($Anchor.sha256 -ne $LastHash) {
            $Reason = if ($null -ne $Anchor.seq -and $null -ne $LastSequence -and [long]$Anchor.seq -gt [long]$LastSequence) {
                "the anchor names entry $($Anchor.seq) but the ledger ends at $LastSequence, so the newest entries were removed"
            }
            else {
                'the last entry does not match the anchor'
            }
            $Broken.Add([pscustomobject]@{ file = $LastFile; line = $Lines; reason = $Reason })
        }
    }
    elseif ($Lines -gt 0) {
        # No anchor means truncation at the end cannot be ruled out. An unreadable
        # check is not a clean check, so this is a finding and not a footnote.
        $Broken.Add([pscustomobject]@{ file = 'tip.json'; line = 0; reason = "the anchor is $AnchorState, so removal of the newest entries cannot be ruled out" })
    }

    # Only the very first entry of the whole ledger can say whether the start is
    # intact. If that one predates numbering there is nothing to compare, and a
    # later numbered entry must not be mistaken for the beginning.
    $FirstLineSequence = $null
    $FirstLineFound = $false
    foreach ($File in $Files) {
        foreach ($Line in [System.IO.File]::ReadAllLines($File.FullName)) {
            if (-not $Line.Trim()) { continue }
            try { $FirstLineSequence = ($Line | ConvertFrom-Json).seq } catch { $FirstLineSequence = $null }
            $FirstLineFound = $true
            break
        }
        if ($FirstLineFound) { break }
    }
    if ($FirstLineFound -and $null -ne $FirstLineSequence -and [long]$FirstLineSequence -ne 1) {
        $Broken.Add([pscustomobject]@{ file = $Files[0].Name; line = 1; reason = "the ledger starts at entry $FirstLineSequence, so earlier entries were removed" })
    }

    return [pscustomobject]@{
        Lines       = $Lines
        Broken      = $Broken.ToArray()
        Ok          = ($Broken.Count -eq 0)
        Unsequenced = $Unsequenced
        Anchor      = $AnchorState
        # What a clean answer actually covered, so it is never read as more.
        Checked     = "hash chain over $Lines entries, numbering on $($Lines - $Unsequenced), anchor $AnchorState"
    }
}

function Add-AgentSyncHistoryReadableEntry {
    param ($Settings, $Unit, $Result)

    # The ledger is for machines. This is the same event as one Norwegian line
    # a person can read in any editor, kept beside the project's export.
    $Now = [System.DateTime]::Now
    $File = Join-Path $Unit.ExportPath ("HISTORIKK-{0:yyyy-MM}.md" -f $Now)
    $Culture = [System.Globalization.CultureInfo]::GetCultureInfo('nb-NO')

    $TriggerText = switch ($Result.Trigger) {
        'baseline' { 'grunnlinje' }
        'mission-start' { 'oppdrag start' }
        'mission-end' { 'oppdrag slutt' }
        'session-quiet' { 'økt stilnet' }
        'sweep' { 'feiing' }
        'recovery' { 'gjenopptatt etter avbrudd' }
        default { 'manuelt' }
    }
    $LineText = if ($Result.Line -eq 'work') { 'arbeidsfiler' }
    elseif ($Result.Line.StartsWith('state')) { 'øktlogger' }
    elseif ($Result.Line -eq 'records') { 'oppdragsposter' }
    else { $Result.Line }

    $Parts = [System.Collections.Generic.List[string]]::new()
    $Parts.Add($Now.ToString('HH:mm'))
    $Parts.Add($LineText)
    $Parts.Add($TriggerText)
    if ($Result.Outcome -eq 'committed') {
        if (-not $Result.Parent) {
            $Parts.Add("$($Result.Added) filer")
        }
        elseif ($Result.Added -eq 0 -and $Result.Modified -eq 0 -and $Result.Deleted -eq 0) {
            # Only the manifest moved: what the snapshot leaves out changed, the
            # files did not. Saying "0 endret" would read as if nothing happened.
            $Parts.Add('ingen filendring, men reglene for hva som tas med er endret')
        }
        else {
            $Parts.Add("$($Result.Modified) endret, $($Result.Added) nye, $($Result.Deleted) slettet")
        }
        if ($Result.Completeness -eq 'partial') {
            $Parts.Add("**ufullstendig**: $($Result.Unreadable) kunne ikke leses")
        }
        if ($Result.Skipped -gt 0) { $Parts.Add("$($Result.Skipped) holdt utenfor etter reglene") }
        if ($Result.MissionId) { $Parts.Add("oppdrag $($Result.MissionId)") }
        if (@($Result.ObservedSessions).Count -gt 0) { $Parts.Add("observert: $(@($Result.ObservedSessions) -join ', ')") }
        $Parts.Add("bilde $($Result.Commit.Substring(0, 10))")
        $Shown = @($Result.ChangedPaths | Select-Object -First 8)
        if ($Shown.Count -gt 0) {
            $More = @($Result.ChangedPaths).Count - $Shown.Count
            $Parts.Add(($Shown -join ', ') + $(if ($More -gt 0) { " (+$More flere)" } else { '' }))
        }
    }
    else {
        $Parts.Add("**ikke tatt**: $($Result.Reason)")
        if ($Result.MissionId) { $Parts.Add("oppdrag $($Result.MissionId)") }
    }
    $Entry = '- ' + ($Parts -join ' · ')

    $MutexName = Get-AgentSyncHistoryMutexName -Kind Readable -Path $Unit.ExportPath
    $Mutex = [System.Threading.Mutex]::new($false, $MutexName)
    $Held = $false
    try {
        try { $Held = $Mutex.WaitOne(30000) } catch [System.Threading.AbandonedMutexException] { $Held = $true }
        if (-not $Held) { throw 'The readable history log is held by another process.' }

        New-Item -ItemType Directory -Path $Unit.ExportPath -Force | Out-Null
        # Line feeds only: the folder is synced to machines that are not Windows.
        $New = [System.Collections.Generic.List[string]]::new()
        $Heading = "## $($Now.ToString('yyyy-MM-dd'))"
        $Existing = if (Test-Path -LiteralPath $File) { @([System.IO.File]::ReadAllLines($File)) } else { @() }
        if ($Existing.Count -eq 0) {
            $New.Add("# Historikk for $($Unit.RelativePath) – $($Now.ToString('MMMM yyyy', $Culture))")
            $New.Add('')
            $New.Add("Skrevet av AgentSync på $($Settings.MachineId). Én linje per øyeblikksbilde.")
            $New.Add('«Observert» betyr at økten var aktiv da bildet ble tatt, ikke at den laget endringene.')
            $New.Add('Bilde-id er en git-commit i prosjektets historikklager; to bilder kan sammenlignes med `git diff`.')
        }
        $LastHeading = $Existing | Where-Object { $_.StartsWith('## ') } | Select-Object -Last 1
        if ($LastHeading -ne $Heading) {
            $New.Add('')
            $New.Add($Heading)
            $New.Add('')
        }
        $New.Add($Entry)
        [System.IO.File]::AppendAllText($File, (($New -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
    }
    finally {
        if ($Held) { $Mutex.ReleaseMutex() }
        $Mutex.Dispose()
    }
}

function Write-AgentSyncHistoryRecord {
    param ($Settings, $Unit, $Result)

    # An unchanged project is not an event. A sweep that finds a project busy
    # or without a baseline is not one either; the sweep summary counts those.
    # Everything else is written down, including the snapshot that was not taken.
    if ($Result.Outcome -eq 'unchanged' -or $Result.Outcome -eq 'dry-run') {
        return
    }
    if ($Result.Trigger -eq 'sweep' -and $Result.Outcome -in @('busy', 'no-baseline')) {
        return
    }

    $Entry = [ordered]@{
        event      = 'snapshot'
        unit       = $Result.Unit
        path       = $Result.RelativePath
        line       = $Result.Line
        trigger    = $Result.Trigger
        outcome    = $Result.Outcome
        status     = $Result.Completeness
        reason     = $Result.Reason
        commit     = $Result.Commit
        parent     = $Result.Parent
        added      = $Result.Added
        modified   = $Result.Modified
        deleted    = $Result.Deleted
        skipped    = $Result.Skipped
        unreadable = $Result.Unreadable
        mission    = $(if ($Result.MissionId) { $Result.MissionId } else { $null })
        observed   = @($Result.ObservedSessions)
        seconds    = $Result.Seconds
    }
    [void](Add-AgentSyncHistoryLedgerEntry -Settings $Settings -Entry $Entry)
    Add-AgentSyncHistoryReadableEntry -Settings $Settings -Unit $Unit -Result $Result
}

function Invoke-AgentSyncHistoryUnitSnapshot {
    param (
        $Unit,
        $Settings,
        [string]$Trigger = 'manual',
        [string]$MissionId = '',
        [string[]]$ObservedSessions = @(),
        [string[]]$Lines = @(),
        [switch]$AllowBaseline,
        [switch]$DryRun
    )

    # All lines of one project: the work files, each state folder, then any
    # folder the project ignores but that is history all the same.
    $Wanted = @('work') + @($Unit.StateLines | ForEach-Object { $_.Line }) + @($Unit.ExtraLines | ForEach-Object { $_.Line })
    if ($Lines.Count -gt 0) {
        $Wanted = @($Wanted | Where-Object { $Lines -contains $_ })
    }

    $Results = foreach ($Line in $Wanted) {
        $Result = New-AgentSyncHistorySnapshot -Unit $Unit -Line $Line -Settings $Settings -Trigger $Trigger -MissionId $MissionId -ObservedSessions $ObservedSessions -AllowBaseline:$AllowBaseline -DryRun:$DryRun
        try {
            Write-AgentSyncHistoryRecord -Settings $Settings -Unit $Unit -Result $Result
        }
        catch {
            # The snapshot exists even if the line about it could not be written.
            Write-AgentSyncHistoryLog -Level 'WARN' -Message "HISTORY_RECORD_FAILED unit=$($Unit.Id) line=$Line $($_.Exception.Message)"
        }
        $Result
    }
    return @($Results)
}

function Get-AgentSyncHistoryUnitStatus {
    param ($Unit)

    $Lines = @()
    $HasRepository = Test-Path -LiteralPath (Join-Path $Unit.RepositoryPath 'HEAD')
    if ($HasRepository) {
        $Refs = Invoke-AgentSyncHistoryGit -Repository $Unit.RepositoryPath -Arguments @('for-each-ref', '--format=%(refname:short)|%(committerdate:iso-strict)|%(objectname)', 'refs/heads')
        $Lines = @(
            $Refs.StdOut -split "`r?`n" | Where-Object { $_ } | ForEach-Object {
                $Fields = $_.Split('|')
                [pscustomobject]@{ Line = $Fields[0]; LastSnapshot = $Fields[1]; Commit = $Fields[2] }
            }
        )
    }
    $Expected = @('work') + @($Unit.StateLines | ForEach-Object { $_.Line }) + @($Unit.ExtraLines | ForEach-Object { $_.Line })
    return [pscustomobject]@{
        Unit         = $Unit.Id
        RelativePath = $Unit.RelativePath
        Kind         = $Unit.Kind
        Baseline     = ($HasRepository -and -not ($Expected | Where-Object { $_ -notin @($Lines | ForEach-Object Line) }))
        Lines        = $Lines
        MissingLines = @($Expected | Where-Object { $_ -notin @($Lines | ForEach-Object Line) })
    }
}
