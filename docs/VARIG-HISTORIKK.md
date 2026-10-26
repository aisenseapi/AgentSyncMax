# Local history and durable recovery

The included history module records project file snapshots outside the
projects. It is **local history**, not a complete off-machine backup service.
The public configuration leaves it disabled. The module and standalone CLI
exist; do not infer a running scheduled sweep from a configuration flag or the
presence of these files. This source snapshot does not hook the history CLI
into the continuous sync cycle.

## Three different stores

1. **Provider-native history** under each project's `.agent-state/` preserves
   agent sessions in their own representations.
2. **Mission checkpoints** preserve selected before/after file state for MAX
   missions, with retention limits. They are not permanent project history.
3. **The standalone history store** uses separate bare Git repositories and
   large-file storage outside project repositories. Projects are read; the
   module does not commit to their own `.git` directories.

On Windows, the default standalone store is under
`%LOCALAPPDATA%\AgentSyncMax\history-store`; other platforms use a local user
data directory. A configurable export directory holds a ledger and readable
logs, normally under `history/<machine>/` in the toolkit. Moving those metadata
files to another machine does not move the snapshot payloads automatically.

## Inspecting the standalone tool

From the repository root, with a reviewed local configuration:

```powershell
pwsh -NoProfile -File ./Invoke-AgentSyncHistory.ps1 -ConfigFile ./config.local.json
```

With no action switch, this reports known project history. `-Initialize` creates
a baseline, `-Snapshot` updates a selected project with a baseline, and `-Sweep`
works through eligible projects within a budget. Those are write operations to
the history store and should first be tested on disposable projects with
`-DryRun`. Prefer an explicit `-Project` over `-All` during evaluation.

The module requires Git even when the source project is not a Git repository.
It has its own storage rules, minimum-free-space checks and snapshot timeouts.
Review `history.storeDirectory`, `history.exportDirectory`, exclusions and
`history.extraLines` before enabling it. Extra lines are empty by default;
do not casually add raw mission records or credential-bearing directories.

## What the ledger proves

The append-only ledger contains sequence information, a hash chain and a tip
anchor. Verification can identify certain changes, missing entries and
inconsistencies. It does not prove every source file was captured, that content
is safe, or that an attacker could not replace both a local ledger and its
anchor. Read incomplete/partial results as incomplete, not as successful backup.

```powershell
pwsh -NoProfile -File ./Invoke-AgentSyncHistory.ps1 -ConfigFile ./config.local.json -VerifyLedger
```

This checks ledger integrity, not an actual restore or a remote replica.

## Recovery still needs an independent copy

The history store and large-file payloads can be lost with the machine unless
you back them up separately. A ledger, a checksum or a readable log is not a
substitute for those payloads. No automatic off-machine bundle/export pipeline
or universal restore guarantee is promised in this preview.

Keep independent backups and periodically restore them to an isolated location.
Confirm file completeness and readability, then exercise provider-native session
opening where that is part of your recovery requirement. The manual import tool
has a narrower scope than the normal adapter-specific restore paths.

Secret-name filtering is only a safeguard. Source files and native sessions can
still contain credentials or confidential content. Treat all snapshots and
exports as sensitive, and do not commit generated history into this public
source repository.
