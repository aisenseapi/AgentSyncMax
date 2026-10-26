# Changelog

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
