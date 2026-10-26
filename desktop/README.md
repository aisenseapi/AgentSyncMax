# AgentSync MAX desktop

Windows-first source preview, version 4.26.2. Built with Rust, Tauri 2 and the
operating system's WebView. The frontend is plain JavaScript/CSS under `src/`
and is embedded at build time. Some labels and messages remain Norwegian.

Read [installation](../INSTALLASJON.md) and [security](../SECURITY.md) before
running the app with real projects. A local binary or passing unit tests do
not establish compatibility with every provider CLI or production workflow.

## Build and launch

From the repository root on Windows:

```powershell
pwsh -NoProfile -File ./Build-AgentSync-Max.ps1 -Publish
pwsh -NoProfile -File ./Start-AgentSync-Max.ps1
```

The normal build gate runs Pester 5+, Node's test runner, and locked Cargo
tests before building. Rust MSVC, Microsoft C++ Build Tools, PowerShell 7+,
Node.js and WebView2 are required for their respective build/runtime steps.
Git is needed for Git tests and optional Git-based facilities, not for every
mission folder. Dependencies must be downloadable or already cached.

Cargo output lives in `%LOCALAPPDATA%\AgentSyncMax\cargo-target` by default.
The build's `-Publish` flag creates a verified local file under `desktop/dist`
and atomically updates `current-release.json`. It does not publish to GitHub.
The launcher validates that pointer and runs a hash-specific local runtime
copy. No prebuilt executable or signed installer is promised by this snapshot.

## Mission boundary

MAX invokes each installed provider CLI in the selected project. Provider
authentication, permissions, model availability and billing remain the
provider's responsibility. The app checks required CLI arguments, but that
cannot guarantee future CLI compatibility or a correct model response.

A clean Git baseline can be used for change inspection. A dirty worktree or
non-Git folder uses a checkpoint instead. Existing changes are not permission
to discard work. Checkpoints are operational rollback data with retention
limits, not a complete long-term backup.

Mission records under `missions/` may include prompts, output, paths and diffs.
They are private operational data and must stay out of public Git. The final
response and recorded file changes should both be reviewed. A successful
process exit is not proof that the requested task was completed correctly.

## Optional validation

The validator switch starts off with each desktop process. When enabled, a
qualifying completed writer mission with changes can trigger a control using
another configured agent/model. Turning it off stops validation, not the writer.

Blind controls use a temporary copy without selected history, Git metadata,
dependency folders and recognized secret files. This reduces supplied context;
it does not sandbox the CLI or guarantee model independence. Unknown secrets
can still appear in ordinary source files. Review findings before forwarding or
acting on them. See [the evaluation register](../docs/FUNN-OG-AVKLARING.md).

## Active project memory

The Minne panel exposes a bounded navigation entry under
`%LOCALAPPDATA%\AgentSyncMax\active-memory\<project-key-hash>\START-HERE.md`.
Use the displayed path rather than guessing the hash. It links recent mission,
finding and native-session metadata to source records; it is not an authoritative
summary of decisions or a copy of all conversation content.

Settings control whether it is used and the per-process RAM-cache budget.
Zero cache budget means disk-only; disabling it prevents refresh and automatic
use without deleting previously derived files. The budget does not cap the
entire application's memory usage.

Eligible writer missions may receive a prepared, integrity-checked entry no
older than five minutes when context sharing is enabled. Blind/control missions
do not receive it. Missing or invalid memory does not block the mission. Agents
started outside MAX do not automatically discover this machine-local entry.

On Windows, the continuous sync engine can own a headless Rust helper that
refreshes already registered entries while the window is closed. It does not
discover every sync project automatically. It makes no model or network calls
and never rewrites native history. `worker-status.json` is last-observed data;
check the process and advancing timestamps before concluding it is alive.

## Network and operational limits

Local sync and the active-memory helper do not need a model service. Missions,
model suggestions and provider metadata may need the endpoints you configure.
The optional AI Sense external watch is a separate liveness feature with an
independent preference and local state. That preference is enabled by default
on a fresh profile and can be switched off. Disabled sync adapters do not
disable it. Review [SECURITY.md](../SECURITY.md) before first launch.
An external-watch failure must not block local missions or sync.

This snapshot is not a fleet-management service. Filesystem synchronization,
multi-machine access, backups and provider credentials still require deliberate
setup. An OS-level sandbox, guaranteed session portability and universal restore
support are not included.
