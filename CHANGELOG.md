# Changelog

## Desktop 4.27.0, 2026-10-28

- Add optional local secret protection, enabled by default, before MAX supplies
  prompts, shared context, selected Aider attachments and diffs to models.
- Persist the switch locally, show disabled status, and support an explicit
  five-minute, single-use exception bound to the checked input and recipient.
- Stop blocked missions before creating journals, checkpoints or prompt files;
  prevent secret findings from triggering model fallback.
- Freeze prepared context and attachment selection, and check approved
  attachment bytes again before starting the agent.
- Keep findings and model-error diagnostics free of detected values and raw
  response excerpts. Document detection limits and channels outside this guard.

Sync engine remains 4.25.1. No native history, local configuration, generated
reports, operational records or executables are included.

## Public source preview, 2026-10-26

Initial public source snapshot of AgentSync MAX 4.26.2 and sync engine 4.25.1.
Earlier private development history and machine-specific operational data are
not part of this repository. Version numbers describe the component snapshots,
not a history of public releases.

Included capabilities:

- Provider-native, project-routed history collection and adapter-specific restore.
- Windows mission workspace, streamed output, file differences and checkpoints.
- Optional context-reduced validation and a human finding-evaluation register.
- Derived status, intelligence and recovery-audit reports.
- Bounded local active-memory entries and a headless Windows companion.
- Standalone local history tooling, separate from independent backup.

Recent changes in this snapshot include recovery of derived memory after a
backward clock adjustment, monotonic watcher scheduling, clearer process-start
diagnostics, and finer status-phase timings. These are implementation changes,
not general performance or reliability guarantees.

The public configuration starts with sync adapters disabled. Public onboarding
requires choosing explicit paths and enabling adapters deliberately. No native
sessions, mission records, credentials, generated reports or built executables
are included. Build and test the source on your own supported environment.
