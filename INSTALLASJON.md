# Installation and first run

This guide describes the source preview: MAX 4.26.2 and engine 4.25.1.
Some interface messages remain Norwegian. Start with disposable data, not your
only copy of a project or provider profile.

## 1. Understand the two components

The PowerShell engine discovers project identity from agent metadata and
synchronizes the associated state. It supports platform-specific paths for
Windows, macOS and Linux. The Rust/Tauri desktop app is Windows-first in this
snapshot and launches provider CLIs for missions.

Installing AgentSync does not install or authenticate those CLIs. An IDE
extension alone is not necessarily a mission runner. Providers can change
their command-line and storage formats independently of AgentSync.

## 2. Create your local configuration

Copy `config.json` to `config.local.json`, then edit the copy. The bootstrap and
desktop prefer that local file. **It replaces the shared configuration; it is
not a partial overlay.** Keep a complete configuration and do not commit it.

The public template disables all sync adapters. Before enabling one:

1. Set `sharedProjectsDir` to an explicit absolute directory you control.
2. Review that adapter's local paths, target directory and command settings.
3. Enable only the selected adapter. Keep the other adapters disabled.
4. Keep optional archive/history/guidance features disabled while learning the
   system. Enabling project guidance can create project instruction files.

The shared root is a boundary, not the identity of every project below it.
Projects are found from actual agent workspace/cwd metadata. A parent project
and a separately used child directory can both be projects. An empty folder
does not acquire agent history merely because it is inside the root.

For the first test, use a disposable root and isolated copies of provider
state. Redirect all enabled adapter paths to those copies. Do not put existing
production `.agent-state` directories into this test. An empty root with all
adapters disabled is useful for checking configuration, but proves no sync.

## 3. Inspect before copying

PowerShell 7+ (`pwsh`) is required; Windows PowerShell 5.1 is not supported.
From the repository root:

```powershell
pwsh -NoProfile -File ./Sync-AgentState.ps1 -ConfigFile ./config.local.json -DryRun
```

A dry run implies one cycle. It can read metadata, invoke discovery helpers and
write diagnostic logs; it is not a promise of zero filesystem activity. Inspect
the proposed source, destination, project and direction before a real run.

**Normal sync is bidirectional where the adapter supports restore.** Claude
and Codex copies can be routed back into provider-local storage. Other adapters
use their own merge/import boundaries. Junie currently collects history without
restoring it into the IDE. Do not treat normal sync as a backup-only command.

After a satisfactory dry run, while still using isolated copies:

```powershell
pwsh -NoProfile -File ./Sync-AgentState.ps1 -ConfigFile ./config.local.json -Once
```

Review the generated status report and files. Only then configure your real
paths, take an independent backup, and deliberately start continuous sync:

```powershell
pwsh -NoProfile -File ./Start-AgentSync-Bootstrap.ps1
```

The foreground process can be stopped with Ctrl+C. On macOS/Linux,
`bash ./agentsync.sh` invokes the bootstrap through `pwsh`. This preview does
not automatically install an OS service or scheduled task for you.

## 4. Build and open the Windows desktop

Required for the normal build/test workflow:

- PowerShell 7+, Rust/Cargo with a supported stable MSVC toolchain.
- Microsoft C++ Build Tools and the Windows SDK required by that toolchain.
- Microsoft Edge WebView2 Runtime for the app.
- Node.js with the built-in test runner and Pester 5+ for the build gates.
- Git for Git-based tracking, the optional history tool and Git-related tests.
  Ordinary project missions can instead use checkpoints.

```powershell
pwsh -NoProfile -File ./Build-AgentSync-Max.ps1 -Publish
pwsh -NoProfile -File ./Start-AgentSync-Max.ps1
```

The build defaults to two Cargo jobs and stores build output under
`%LOCALAPPDATA%\AgentSyncMax\cargo-target`, outside the checkout. `-Publish`
updates only the local `desktop/dist` distribution. It does not create a GitHub
Release, install a background service or start the app. `-Offline` requires
dependencies already present locally. Do not use `-SkipTests` as evidence of a
verified build.

The launcher verifies the local release hash and runs a copied executable under
`%LOCALAPPDATA%\AgentSyncMax\runtime`. Launch from this checkout so the toolkit
location is supplied correctly. An older app's settings and local caches may
already exist on the machine; a new source checkout does not reset them.

The desktop's AI Sense external-watch preference is enabled by default on a
fresh profile and may contact its service after launch. It has a separate
off switch; disabled sync adapters do not disable it. Review [SECURITY.md](SECURITY.md)
before first launch if this network behavior is not suitable for your environment.

Select a disposable project before trying a mission. Review the selected agent,
model, provider permissions and external-service preferences. Start with a
small request such as summarizing a sample README. Check the final result and
diff, not just the process exit code.

## 5. Recovery is a separate test

```powershell
pwsh -NoProfile -File ./Test-AgentSync-Recovery.ps1 -ConfigFile ./config.local.json
```

This audits readable copies and restore routing without applying a restore. It
writes derived HTML/JSON reports and may inspect installed provider versions.
`-Deep` performs a more extensive content check. Passing an audit is not proof
that the cloud uploaded everything or that a provider can successfully reopen
the session on a new machine.

`Import-AgentState.ps1` is a narrower manual tool. Without `-Apply` it plans
restoration of verified Claude/Codex JSONL into missing destinations. Other
providers, divergent destinations and ambiguous identities can be blocked.
Applying that manual import uses Windows-specific path safeguards; do not
assume the same apply capability on other platforms.

Keep separate backups of provider state, project state and any local-only
checkpoint/history stores you need. Restore into an isolated profile or test
machine, compare the files, and test opening the restored session before
depending on the process. Do not assume placing a path inside Dropbox or
another synchronized folder proves successful upload.

See [SECURITY.md](SECURITY.md) for sensitive data and network behavior, and
[local history](docs/VARIG-HISTORIKK.md) for storage that does not automatically
survive loss of this machine.
