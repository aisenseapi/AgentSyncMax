# Findings and human evaluations

MAX can record what a validation agent claimed, what a person checked, and
what happened after a finding was forwarded. The register is not an automatic
truth engine, a training dataset authorization or a guarantee of code quality.

## Separate questions

Each occurrence is identified by its source control mission and finding index.
A similar title in a later run does not inherit an earlier verdict.

- **Verdict:** unreviewed, unresolved, confirmed, partially correct or false
  positive. The human's evidence and revisions remain part of the record.
- **Remediation:** open, reported fixed but not rechecked, or rechecked.
  A writer saying “fixed” or changing a file does not settle the verdict.
- **Optional ratings:** usefulness, actionability and novelty, each 1–10.
  Unrated fields remain empty. Each average has its own response count; there
  is no composite quality score.

Forwarding a finding can link it to a specific follow-up mission. That link
shows the follow-up attempt, not successful remediation. Later-discovered issues
are tracked separately rather than silently added to a validator's hit rate.

## Interpretation limits

A requested or configured model name is not necessarily an observed runtime
model identity. The source of the model name matters. Another agent can use the
same provider or model family, so agent diversity alone is not proof of
independent reasoning.

Blind-copy mode reduces the supplied context. It is not an OS sandbox and is
not a controlled experiment by itself. A failure, empty answer or unreadable
output must not be presented as a clean code review.

The register describes selected findings from actual use. It cannot count
unknown defects no agent found, establish recall, or rank models causally when
their projects and assignments differ. A human verdict is recorded evidence,
not automatically verified ground truth.

## Storage and sharing

Records live under `missions/evaluations/` and do not rewrite provider-native
history. Mission records and evaluation files are sensitive operational data
and must remain outside public Git. Their actual backup coverage depends on
the filesystem transport and local exclusions.

The local dataset can contain finding text, file paths, notes and evidence.
The separate redacted export removes selected free text and replaces paths,
but timestamps, model names and identifiers can still identify a workflow.
Review every export before sharing it. Redaction is not an anonymity guarantee.

The register starts no training job. Possession of the records does not grant
permission to publish them or use private project material for model training.
