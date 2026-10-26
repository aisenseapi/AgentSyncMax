# Security and privacy

AgentSync handles powerful local tools and potentially sensitive history.
Treat this source preview as software to evaluate on isolated copies before
using it with valuable projects. No security certification or complete sandbox
is claimed.

## Data boundaries

- Native `.agent-state/` data can contain prompts, source, command output and
  credentials previously exposed to an agent. Preserving a native format does
  not sanitize its contents.
- `missions/`, evaluations, checkpoints, logs and derived reports can contain
  private project information. Generated metadata may still disclose paths,
  filenames, models and activity times even when it excludes raw messages.
- Local configuration, provider databases and authentication must not be
  committed. Review staged changes and shared-folder access, not only ignore rules.
- A filesystem transport such as Dropbox, OneDrive, Syncthing or a NAS has its
  own authentication, retention and privacy behavior. AgentSync does not provide
  encryption or prove the remote copy exists.

Keep independent backups. A hash check detects some integrity problems; it is
not a guarantee of complete collection, authenticity or successful recovery.
Test restores into an isolated profile or machine.

## Agent execution and validation

An agent CLI can read files, run commands, contact services and modify a project
subject to its own configuration and privileges. MAX's prompts are not an OS
security boundary. Review provider permissions and use a restricted user or
separate environment where appropriate.

A blind validation copy omits selected context and recognized secret paths.
It does not block all access outside that directory, detect every embedded
secret, or prove that two model responses are independent. An unreadable or
failed check is not a clean result. Human verdicts and agent claims are recorded
separately; neither is silently promoted into verified truth.

## Network behavior

The core filesystem sync and local active-memory worker do not require a cloud
model. Provider CLIs and optional model features follow their own configured
endpoints and may send prompts or project content there. Installing a local
model client does not prove a selected model runs locally.

The separate external-watch integration contacts
`https://aisenseapi.com/services/v1` for heartbeat and webhook-capture operations.
Its purpose is evidence of missing process heartbeats, not backup or code review.
Requests do not intentionally contain prompts, project paths, model names or
user names. The service can still observe normal network metadata such as the
source IP address, request timing and service-generated identifiers. This is
not a guarantee of anonymity.

**The desktop external-watch preference is enabled by default on a fresh
profile and can make service calls after launch.** It can be switched off in
the app. Disabling sync adapters in `config.json` does not disable this separate
feature. Review this behavior before first launch in a restricted environment.
Its state and
bearer links are stored separately under
`%LOCALAPPDATA%\AgentSyncMax\external-watch.json`, not in the project config.
Treat those links as sensitive. Disabling the feature stops new local requests;
an already created external watch may still record absence until it expires.
The service's availability and delivery are not guaranteed. Internet or service
failure must not stop local sync or missions; cloud provider missions can still
require their own connectivity.

## Reporting a problem

Do not post credentials, full native sessions, private logs or real project
archives in a public issue. For a suspected vulnerability, use GitHub's private
vulnerability reporting on this repository if available. Otherwise, open a
minimal issue requesting a private contact without including exploit details
or sensitive data. No response-time SLA is promised for this preview.

For ordinary bugs, include sanitized steps, platform, component versions and
the provider CLI version. Reproduce with disposable files where possible.
Rotate any credential that was exposed; deleting the visible copy does not
remove it from existing backups or repository history.
