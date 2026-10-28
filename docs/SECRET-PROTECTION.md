# Local secret protection

AgentSync MAX 4.27.0 checks data it prepares for models before sending it.
This check runs locally and is enabled by default. It does not need another
model or network service and does not modify original project files.

## Settings and one-use exceptions

Open **Brytere → Hemmelighetsvern**. The switch persists locally across restarts.
When it is disabled, the app displays an off indicator. On Windows the setting
lives in `%LOCALAPPDATA%\AgentSyncMax\secret-guard.json`.
Missing settings mean enabled. Invalid or unreadable settings fail closed with
a warning, preserving the existing file.

A finding stops the action and shows its source, category and recipient without
the detected value. Cancel and edit the source, or explicitly allow that one
transfer. The exception expires after five minutes, is consumed once, and is
bound to the exact checked content and recipient. Changed data, a different
model or a subsequent transfer can require another decision.

Unreadable, oversized, unsafe or unsupported input is not treated as clean and
cannot receive a one-use exception. Automatic validation stops with a safe
explanation rather than repeatedly opening dialogs. Switching projects cancels
an open decision dialog and preserves the unsent draft.

## Covered transfers

| Transfer | Checked content |
| --- | --- |
| Agent mission | Prepared prompt, including supplied recent mission context and active-memory text |
| Aider startup attachments | Files explicitly selected and attached by MAX |
| Ollama code review | The outgoing diff and relevant request context |
| Model-based intent and scope resolution | System and user text supplied by MAX |

Mission checks happen before the new journal, checkpoint, blind copy or prompt
file is created. The worker uses the prepared prompt and attachment selection.
When protection is enabled, selected attachment bytes are compared again before
agent launch. Changed bytes require a new check. Project files are not locked,
so this is not an atomic guarantee about later native-agent reads.

Secret findings do not enter model retry/fallback as ordinary service errors.
Normal connection failures retain their existing fallback behavior.
Model-error diagnostics omit raw response excerpts that could echo input.

## Detection limits and exclusions

Recognized patterns include private key blocks, common provider tokens,
credential-bearing URLs and substantive password/token assignments.
File rules include `.env` variants and common credential/key paths. Conventional
example filenames are still content-checked when attached.

The scan allows up to 1 MiB per file, 8 MiB per transfer, 128 files and 64 text
parts. Unsupported binary data, invalid UTF-8, unavailable files and unsafe
redirects fail closed. Validated locally available Cloud Files are supported.
Individual agent adapters can impose stricter attachment-selection limits.

Patterns can produce false positives and can miss unknown, encoded or split
secrets. A successful check is not proof that data contains no secrets.
The following are outside this guard:

- A native agent's independent file reads, tools and network access, including
  Aider's later project reads and repository map.
- The complete blind workspace, which retains its separate exclusion rules.
- Native history, mission output, prior logs, checkpoints and other backups.
- Filesystem sync, Git pushes, publishing and export files.
- Credentials intentionally used by provider clients for authentication.

Keep provider permissions, ignore rules and independent backups in place.
Enabling this guard does not turn MAX into an operating-system sandbox.

## Verification

Synthetic tests cover default/on-off persistence, malformed settings, known
patterns, environment references, exact one-use binding and expiry, changed
attachments, incomplete scans and safe diagnostics. Frontend tests cover
confirmed state, cancellation, project changes, preserved drafts and retry
limits. The dialog was also checked in both themes at desktop and 360 × 640.
No real secrets or live model submissions are required by these tests.
