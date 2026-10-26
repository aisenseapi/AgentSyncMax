# AgentSync MAX

Keep the project together when you work with more than one coding agent.

AgentSync MAX combines a Windows desktop workspace with a project-aware history
sync engine. It connects agent sessions to the project they belong to, keeps
provider-native history, and brings missions, output, file changes and review
findings into one place.

**Source preview:** desktop 4.26.2, sync engine 4.25.1. This repository is a
source snapshot, not a promise of a signed installer, hosted service or supported
binary release. The interface still contains Norwegian text. It has been used
in a single-owner workflow; that is not validation across arbitrary machines,
teams or provider versions.

## What is here

- Project-linked history for Claude Code, Codex, Antigravity, OpenCode, Cline
  and Junie. Formats and restore capabilities differ by provider; Junie is
  collection-only. Aider can write its history directly into the project.
- A desktop mission workspace for installed, authenticated coding-agent CLIs,
  with live output, activity, mission history and file differences.
- Git-based change tracking when a suitable baseline exists, or local
  checkpoints for ordinary folders and dirty worktrees. Git is not required
  for every project or mission.
- Optional validation with another agent/model in a context-reduced copy,
  followed by a human finding register. A reported fix is not automatically a
  verified fix.
- Status, recovery-audit and session-metadata reports that can also be opened
  without the desktop app.
- An optional, bounded local index of recent project sources, with disk storage
  and an in-process RAM cache. This is not a RAM disk or a backup.

The project is the organizing unit, not a particular vendor's chat window.
This does **not** mean one provider can natively resume another provider's
session, or that every agent automatically reads all history.

## Start safely

Read [installation and first-run steps](INSTALLASJON.md) before starting the
engine. The public configuration has agents disabled. Set an explicit shared
project root and deliberately enable only the adapters you want.

Start with a disposable project and isolated provider paths, inspect a dry run,
then test one real cycle against copies. Normal synchronization includes
provider-specific restore paths: it is not a one-way archival command.

The sync engine uses PowerShell 7+ and contains Windows, macOS and Linux paths.
The desktop build and launch workflow in this preview is **Windows-first**.
Other platforms do not have an equivalent verified desktop release here.

For the Windows desktop build, install Rust/Cargo with the MSVC toolchain,
Microsoft C++ Build Tools, WebView2, PowerShell 7+, Node.js and Pester 5+.
From the repository root:

```powershell
pwsh -NoProfile -File ./Build-AgentSync-Max.ps1 -Publish
```

This runs the test gates and builds locally. `-Publish` means copying a verified
executable into local `desktop/dist` and updating its local release pointer.
**It does not upload anything to GitHub.** See [desktop details](desktop/README.md).

## Important boundaries

Native history can contain prompts, source code, terminal output and secrets.
It is intentionally not included in this repository. Keep `.agent-state/`,
missions, checkpoints, local settings and generated reports out of public Git.
Review access to whatever filesystem transport you choose.

A synchronized copy is not proof of a recoverable backup. Maintain an
independent backup and test restoration into an isolated environment. AgentSync
does not supply encryption, a cloud-sync service or a guarantee of recovery.

Blind validation reduces supplied context; it is **not an operating-system
sandbox**. Agent CLIs retain their own permissions, authentication and network
behavior. Findings remain claims until checked.

AI Sense external-watch integration uses a third-party HTTPS service for
process-liveness evidence. **Its desktop preference is enabled by default**
on a fresh profile and can be switched off; disabling sync adapters in
`config.json` does not disable this separate preference. It is separate from
local sync, memory and missions and does not make them depend on that service. Read
[security and network boundaries](SECURITY.md) before enabling external features.

## Documentation

- [Installation and first-run safety](INSTALLASJON.md)
- [Desktop architecture and development](desktop/README.md)
- [Storage model and agent boundaries](AGENT_CONTEXT.md)
- [Finding evaluations](docs/FUNN-OG-AVKLARING.md)
- [Local history and backup limitations](docs/VARIG-HISTORIKK.md)
- [Security](SECURITY.md)
- [Source-preview changelog](CHANGELOG.md)

Bug reports are welcome with a minimal, sanitized reproduction, platform,
AgentSync version and relevant provider CLI version. Do not attach complete
agent sessions or private project data. The code is licensed under [MIT](LICENSE).
