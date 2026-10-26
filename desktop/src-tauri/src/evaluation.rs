//! Local, append-only human adjudication. Provider text and mission records are
//! evidence sources, never a verdict. Repeated titles never inherit truth.
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::SystemTime;

static STORE_LOCK: Mutex<()> = Mutex::new(());
static STORE_REVISION: AtomicU64 = AtomicU64::new(0);
static MISSION_INDEX: Mutex<BTreeMap<PathBuf, IndexedMission>> = Mutex::new(BTreeMap::new());
const MAX_INDEX_ENTRIES: usize = 2_000;
const MAX_INDEX_BYTES: usize = 8 * 1024 * 1024;

#[derive(Clone)]
struct IndexedMission {
    modified: Option<SystemTime>,
    created: Option<SystemTime>,
    bytes: u64,
    value: Value,
    retained_bytes: usize,
}

// Read-only dataset work does not hold the write lock while parsing histories.
// A concurrent mutation (also one that fails part way through) forces a retry.
struct StoreMutation;
impl Drop for StoreMutation {
    fn drop(&mut self) {
        STORE_REVISION.fetch_add(1, Ordering::SeqCst);
    }
}

fn consistent_read<T>(mut read: impl FnMut() -> Result<T, String>) -> Result<T, String> {
    for _ in 0..3 {
        let before = {
            let _guard = STORE_LOCK
                .lock()
                .map_err(|_| "Avklaringslageret er utilgjengelig.".to_string())?;
            STORE_REVISION.load(Ordering::SeqCst)
        };
        let result = read();
        let _guard = STORE_LOCK
            .lock()
            .map_err(|_| "Avklaringslageret er utilgjengelig.".to_string())?;
        if before == STORE_REVISION.load(Ordering::SeqCst) {
            return result;
        }
    }
    Err("Registeret ble endret under lesingen. Prøv å oppdatere på nytt; ingen vurdering er overskrevet.".into())
}

fn read_indexed_mission(path: &Path, budget: &mut u64) -> Result<Value, String> {
    let meta = fs::symlink_metadata(path).map_err(|error| error.to_string())?;
    super::storage_safety::validate_stored_path(path, &meta, true)?;
    if !meta.is_file() || meta.len() > MAX_RECORD_BYTES || meta.len() > *budget {
        return Err(format!(
            "Utrygg eller for stor oppdragspost: {}",
            path.display()
        ));
    }
    let modified = meta.modified().ok();
    let created = meta.created().ok();
    if modified.is_some() {
        if let Some(entry) = MISSION_INDEX
            .lock()
            .ok()
            .and_then(|index| index.get(path).cloned())
        {
            if entry.modified == modified && entry.created == created && entry.bytes == meta.len() {
                *budget -= meta.len();
                return Ok(entry.value);
            }
        }
    }
    let raw = read_json(path, budget)?;
    let mut value = serde_json::Map::new();
    for key in [
        "id",
        "projectPath",
        "agent",
        "model",
        "resolvedModel",
        "modelSource",
        "mode",
        "purpose",
        "sourceMissionId",
        "startedUnixMs",
        "finishedUnixMs",
        "status",
    ] {
        if let Some(field) = raw.get(key) {
            value.insert(key.into(), field.clone());
        }
    }
    for key in ["workspaceBefore", "workspaceAfter"] {
        value.insert(key.into(), workspace_metadata(&raw[key]));
    }
    value.insert("checkpoint".into(), checkpoint_metadata(&raw["checkpoint"]));
    if let Some(report) = raw.get("findings") {
        let mut report = report.clone();
        if let Some(items) = report.get_mut("findings").and_then(Value::as_array_mut) {
            for item in items {
                if let Some(object) = item.as_object_mut() {
                    object.retain(|key, _| {
                        ["title", "detail", "file", "severity"].contains(&key.as_str())
                    });
                }
            }
        }
        if let Some(object) = report.as_object_mut() {
            object.retain(|key, _| ["findings", "resolverModel"].contains(&key.as_str()));
        }
        value.insert("findings".into(), report);
    }
    let value = Value::Object(value);
    // Never cache a snapshot if the writer replaced the file during the read.
    let after = fs::metadata(path).map_err(|error| error.to_string())?;
    if modified.is_some()
        && after.modified().ok() == modified
        && after.len() == meta.len()
        && after.created().ok() == created
    {
        let retained_bytes = serde_json::to_vec(&value)
            .map_err(|error| error.to_string())?
            .len();
        if retained_bytes <= MAX_INDEX_BYTES {
            if let Ok(mut index) = MISSION_INDEX.lock() {
                if index.len() >= MAX_INDEX_ENTRIES
                    || index
                        .values()
                        .map(|entry| entry.retained_bytes)
                        .sum::<usize>()
                        + retained_bytes
                        > MAX_INDEX_BYTES
                {
                    index.clear();
                }
                index.insert(
                    path.to_path_buf(),
                    IndexedMission {
                        modified,
                        created,
                        bytes: meta.len(),
                        value: value.clone(),
                        retained_bytes,
                    },
                );
            }
        }
    }
    Ok(value)
}
const MAX_RECORD_BYTES: u64 = 16 * 1024 * 1024;
const MAX_SCAN_BYTES: u64 = 256 * 1024 * 1024;
const MAX_ENTRIES: usize = 10_000;
const MAX_REVISIONS: usize = 500;

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MissionRequest {
    pub mission_id: String,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ProjectRequest {
    pub project_path: String,
    // Strip the export down to what can leave this machine. One dataset is an
    // anecdote; fifty are a finding, and nobody can send theirs while it
    // carries their project paths, their file names and a person's free-text
    // notes about their own code.
    #[serde(default)]
    pub shareable: bool,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SaveRequest {
    pub mission_id: Option<String>,
    pub finding_index: Option<usize>,
    pub case_id: Option<String>,
    pub expected_revision: u64,
    pub verdict: String,
    pub remediation: String,
    pub evidence: String,
    #[serde(default)]
    pub usefulness: Option<u8>,
    #[serde(default)]
    pub actionability: Option<u8>,
    #[serde(default)]
    pub novelty: Option<u8>,
    #[serde(default)]
    pub notes: String,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct LaterRequest {
    pub project_path: String,
    pub source_mission_id: Option<String>,
    pub title: String,
    pub detail: String,
    pub file: Option<String>,
    pub evidence: String,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct FollowupRequest {
    pub mission_id: String,
    pub finding_index: usize,
    pub followup_mission_id: String,
    // How long the finding sat in front of a person before they acted on it.
    // Agent time is counted everywhere in this register and human time nowhere,
    // and human time is usually the larger of the two. Absent for a link that
    // was retried later, or when the panel never saw the finding appear.
    #[serde(default)]
    pub deliberation_ms: Option<u64>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Seed {
    id: String,
    kind: String,
    mission_id: Option<String>,
    finding_index: Option<usize>,
    project_path: String,
    title: String,
    detail: String,
    file: Option<String>,
    severity: Option<String>,
    provenance: Value,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Assessment {
    revision: u64,
    verdict: String,
    remediation: String,
    evidence: String,
    #[serde(default)]
    usefulness: Option<u8>,
    #[serde(default)]
    actionability: Option<u8>,
    #[serde(default)]
    novelty: Option<u8>,
    notes: String,
    origin: String,
    at_unix_ms: u64,
    kind: String,
    followup: Option<Value>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Case {
    #[serde(flatten)]
    seed: Seed,
    revision: u64,
    verdict: String,
    remediation: String,
    evidence: String,
    usefulness: Option<u8>,
    actionability: Option<u8>,
    novelty: Option<u8>,
    notes: String,
    origin: String,
    updated_unix_ms: Option<u64>,
    history: Vec<Assessment>,
    followups: Vec<Value>,
}

impl Case {
    pub(crate) fn project_path(&self) -> &str {
        &self.seed.project_path
    }

    fn new(seed: Seed, history: Vec<Assessment>) -> Self {
        let latest = history.last();
        Self {
            seed,
            revision: latest.map_or(0, |item| item.revision),
            verdict: latest
                .map_or("unreviewed", |item| &item.verdict)
                .to_string(),
            remediation: latest.map_or("open", |item| &item.remediation).to_string(),
            evidence: latest.map_or("", |item| &item.evidence).to_string(),
            usefulness: latest.and_then(|item| item.usefulness),
            actionability: latest.and_then(|item| item.actionability),
            novelty: latest.and_then(|item| item.novelty),
            notes: latest.map_or("", |item| &item.notes).to_string(),
            origin: latest.map_or("unreviewed", |item| &item.origin).to_string(),
            updated_unix_ms: latest.map(|item| item.at_unix_ms),
            followups: history
                .iter()
                .filter_map(|event| event.followup.clone())
                .collect(),
            history,
        }
    }
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct EventRecord {
    schema_version: u32,
    seed: Seed,
    event: Assessment,
}

#[derive(Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Counts {
    total: usize,
    unreviewed: usize,
    unresolved: usize,
    confirmed: usize,
    partial: usize,
    false_positive: usize,
    later_discovered: usize,
    remediation_fixed: usize,
    remediation_verified: usize,
    adjudicated: usize,
    confirmed_rate: Option<f64>,
    usefulness_rated: usize,
    usefulness_average: Option<f64>,
    #[serde(skip)]
    usefulness_total: usize,
    actionability_rated: usize,
    actionability_average: Option<f64>,
    #[serde(skip)]
    actionability_total: usize,
    novelty_rated: usize,
    novelty_average: Option<f64>,
    #[serde(skip)]
    novelty_total: usize,
}

// Whether a finding named a file the writer had just changed, or one of its
// neighbours. The validation prompt asks for both; this is what separates them.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Focus {
    // "changed": the finding names a file the writer changed.
    // "neighbour": it names a file the writer did not change.
    // "unknown": the finding named no file, or the writer's files were never
    // recorded. Never folded into either of the other two.
    scope: &'static str,
    #[serde(flatten)]
    counts: Counts,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Group {
    validator_agent: String,
    model: String,
    model_source: String,
    context_mode: String,
    #[serde(flatten)]
    counts: Counts,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Dataset {
    schema_version: u32,
    generated_unix_ms: u64,
    project_path: String,
    cases: Vec<Case>,
    summary: Counts,
    groups: Vec<Group>,
    focus: Vec<Focus>,
    truncated: bool,
    rate_definition: &'static str,
    limitations: Vec<&'static str>,
}

#[derive(Serialize)]
pub(crate) struct Cases {
    cases: Vec<Case>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ExportResult {
    path: String,
    case_count: usize,
}

// Names replaced by their order of first appearance. Not a hash: there is
// nothing to reverse and no salt to get wrong. Stable inside one export, which
// is all a single contribution needs, and meaningless outside it.
#[derive(Default)]
struct Names {
    projects: BTreeMap<String, String>,
    files: BTreeMap<String, String>,
    models: BTreeMap<String, String>,
}

impl Names {
    fn project(&mut self, path: &str) -> Value {
        if path.trim().is_empty() {
            return Value::Null;
        }
        let next = self.projects.len() + 1;
        Value::from(
            self.projects
                .entry(path.to_lowercase())
                .or_insert_with(|| format!("prosjekt-{next}"))
                .clone(),
        )
    }

    // Keep known code/document extensions only. An arbitrary custom suffix
    // can itself be a customer name or other private identifier.
    fn file(&mut self, path: &str) -> Value {
        if path.trim().is_empty() {
            return Value::Null;
        }
        let key = path.to_lowercase().replace('\\', "/");
        let extension = key
            .rsplit('/')
            .next()
            .and_then(|name| name.rsplit_once('.'))
            .map(|(_, suffix)| suffix.to_string())
            .filter(|suffix| {
                matches!(
                    suffix.as_str(),
                    "rs" | "js"
                        | "mjs"
                        | "cjs"
                        | "jsx"
                        | "ts"
                        | "tsx"
                        | "php"
                        | "py"
                        | "go"
                        | "java"
                        | "kt"
                        | "swift"
                        | "c"
                        | "h"
                        | "cpp"
                        | "hpp"
                        | "cs"
                        | "rb"
                        | "sh"
                        | "ps1"
                        | "psm1"
                        | "psd1"
                        | "html"
                        | "css"
                        | "scss"
                        | "vue"
                        | "svelte"
                        | "md"
                        | "txt"
                        | "json"
                        | "toml"
                        | "yaml"
                        | "yml"
                        | "xml"
                        | "sql"
                )
            });
        let next = self.files.len() + 1;
        Value::from(
            self.files
                .entry(key)
                .or_insert_with(|| match extension {
                    Some(suffix) => format!("fil-{next}.{suffix}"),
                    None => format!("fil-{next}"),
                })
                .clone(),
        )
    }

    // Kept when it reads as a model name, so contributions can still be
    // compared by model. Replaced by a running name when it does not, so
    // grouping survives without the text riding along.
    fn model(&mut self, value: Option<&Value>) -> Option<Value> {
        // A model name that is not a string is not a model name. Dropped, the
        // same way the allowlist drops any other nested value.
        let name = value
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|name| !name.is_empty())?;
        if !path_shaped(name) && name.chars().count() <= 80 {
            return Some(Value::from(name));
        }
        let next = self.models.len() + 1;
        Some(Value::from(
            self.models
                .entry(name.to_lowercase())
                .or_insert_with(|| format!("modell-{next}"))
                .clone(),
        ))
    }
}

// A model name is read out of an agent's own output, and the only thing asked
// of it there is that it is short and has no spaces. A filesystem path passes
// that, so a record can carry one into a file whose whole promise is that it is
// safe to send. Names shaped like a path are replaced here; the local register
// keeps whatever the agent actually reported.
fn path_shaped(name: &str) -> bool {
    let lower = name.to_lowercase();
    let bytes = lower.as_bytes();
    lower.contains('\\')
        || lower.starts_with('/')
        || lower.starts_with('~')
        || lower.contains("..")
        // A drive letter: one ASCII letter, a colon, then a separator.
        || (bytes.len() > 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':'
            && (bytes[2] == b'/' || bytes[2] == b'\\'))
        // A namespace is one segment deep in practice. Deeper is a path.
        || lower.matches('/').count() > 1
}

// Copy the listed keys and nothing else. An allowlist, because a blocklist
// silently leaks whatever field somebody adds next.
fn only(value: &Value, keys: &[&str]) -> Value {
    let mut result = serde_json::Map::new();
    for key in keys {
        if let Some(field) = value
            .get(*key)
            .filter(|field| !field.is_object() && !field.is_array())
        {
            result.insert((*key).into(), field.clone());
        }
    }
    Value::Object(result)
}

fn shared_workspace(value: &Value, names: &mut Names) -> Value {
    if !value.is_object() {
        return Value::Null;
    }
    // The project path, the branch and the commit each identify a repository.
    let mut result = only(value, &["controlMode", "changedFiles", "diffTruncated"]);
    if let Some(files) = value.get("changedFileNames").and_then(Value::as_array) {
        let mapped: Vec<Value> = files
            .iter()
            .filter_map(Value::as_str)
            .map(|path| names.file(path))
            .collect();
        result["changedFileNames".to_string()] = Value::from(mapped);
    }
    result
}

fn shared_followup(value: &Value, names: &mut Names) -> Value {
    let mut result = only(
        value,
        &[
            "missionId",
            "agent",
            "status",
            "startedUnixMs",
            "finishedUnixMs",
            "durationMs",
            "deliberationMs",
            "recordAvailable",
        ],
    );
    for key in ["requestedModel", "resolvedModel"] {
        if let Some(model) = names.model(value.get(key)) {
            result[key.to_string()] = model;
        }
    }
    result
}

fn shared_provenance(value: &Value, names: &mut Names) -> Value {
    let mut result = only(
        value,
        &[
            "validatorAgent",
            "modelSource",
            "contextMode",
            "missionPurpose",
            "sourceMissionId",
            "sourceRecordAvailable",
            "sourceAgent",
            "sourceModelSource",
            "startedUnixMs",
            "finishedUnixMs",
            "durationMs",
            "assessmentAuthority",
        ],
    );
    for key in [
        "requestedModel",
        "resolvedModel",
        "resolverModel",
        "sourceRequestedModel",
        "sourceResolvedModel",
    ] {
        if let Some(model) = names.model(value.get(key)) {
            result[key.to_string()] = model;
        }
    }
    for key in [
        "workspaceBefore",
        "workspaceAfter",
        "sourceWorkspaceBefore",
        "sourceWorkspaceAfter",
    ] {
        if let Some(workspace) = value.get(key) {
            result[key.to_string()] = shared_workspace(workspace, names);
        }
    }
    for key in ["checkpoint", "sourceCheckpoint"] {
        if let Some(checkpoint) = value.get(key).filter(|item| item.is_object()) {
            // Everything but the directory, which is a path on someone's disk.
            result[key.to_string()] = only(
                checkpoint,
                &[
                    "mode",
                    "complete",
                    "fileCount",
                    "totalBytes",
                    "skippedFiles",
                    "changedFiles",
                ],
            );
            result[key.to_string()]["hasWarning"] = Value::from(
                checkpoint
                    .get("warning")
                    .and_then(Value::as_str)
                    .is_some_and(|text| !text.is_empty()),
            );
        }
    }
    result
}

fn shared_assessment(value: &Value, names: &mut Names) -> Value {
    // Evidence and notes are what a person wrote about their own code. They are
    // the most likely place for something that must not travel, and no count in
    // this dataset is computed from them.
    let mut result = only(
        value,
        &[
            "revision",
            "verdict",
            "remediation",
            "usefulness",
            "actionability",
            "novelty",
            "origin",
            "atUnixMs",
            "kind",
        ],
    );
    if let Some(followup) = value.get("followup").filter(|item| item.is_object()) {
        result["followup".to_string()] = shared_followup(followup, names);
    }
    result
}

fn shared_case(value: &Value, names: &mut Names) -> Value {
    // The claim and the reasoning are dropped: they are written about the
    // contributor's own code and can carry any part of it. What is measured
    // here is the verdict, the arm and the model, and none of that needs prose.
    let mut result = only(
        value,
        &[
            "id",
            "kind",
            "missionId",
            "findingIndex",
            "severity",
            "revision",
            "verdict",
            "remediation",
            "usefulness",
            "actionability",
            "novelty",
            "origin",
            "updatedUnixMs",
        ],
    );
    result["projectPath".to_string()] = names.project(&text(value, "projectPath"));
    result["file".to_string()] = match value.get("file").and_then(Value::as_str) {
        Some(path) => names.file(path),
        None => Value::Null,
    };
    result["provenance".to_string()] = shared_provenance(&value["provenance"], names);
    result["history".to_string()] =
        Value::from(value.get("history").and_then(Value::as_array).map_or_else(
            Vec::new,
            |items| {
                items
                    .iter()
                    .map(|item| shared_assessment(item, names))
                    .collect::<Vec<_>>()
            },
        ));
    result["followups".to_string()] = Value::from(
        value
            .get("followups")
            .and_then(Value::as_array)
            .map_or_else(Vec::new, |items| {
                items
                    .iter()
                    .map(|item| shared_followup(item, names))
                    .collect::<Vec<_>>()
            }),
    );
    result
}

// A dataset that can be sent to someone else. What it loses is listed inside
// the file, so a reader is never left guessing whether a missing field was
// removed or never recorded.
fn shareable_dataset(dataset: &Dataset) -> Result<Value, String> {
    let value = serde_json::to_value(dataset).map_err(|error| error.to_string())?;
    let mut names = Names::default();
    let cases: Vec<Value> =
        value
            .get("cases")
            .and_then(Value::as_array)
            .map_or_else(Vec::new, |items| {
                items
                    .iter()
                    .map(|case| shared_case(case, &mut names))
                    .collect()
            });
    let mut result = only(
        &value,
        &[
            "schemaVersion",
            "generatedUnixMs",
            "truncated",
            "rateDefinition",
        ],
    );
    // These are constructed from typed counters/groups and fixed limitations,
    // never copied from untrusted mission JSON as opaque metadata objects.
    for key in ["summary", "groups", "focus", "limitations"] {
        result[key.to_string()] = value[key].clone();
    }
    result["projectPath".to_string()] = names.project(&text(&value, "projectPath"));
    result["cases".to_string()] = Value::from(cases);
    result["shared".to_string()] = json!({
        "anonymised": false,
        "redacted": true,
        "reviewRequiredBeforeSharing": true,
        "removed": [
            "Prosjektstier og filnavn er erstattet med løpende navn innenfor denne eksporten. Bare kjente kode- og dokumentfilendelser er beholdt.",
            "Funnenes påstand og forklaring er fjernet.",
            "Bevis og notater skrevet av et menneske er fjernet.",
            "Gren, commit, checkpointmappe og fritekst i checkpointvarsler er fjernet."
        ],
        "kept": "Agent, modell, modellkilde, kontekstmodus, dom, rettestatus, vurderinger, tidsbruk og fokus.",
        "reviewWarning": "Dette er en redigert eksport, ikke en garanti om anonymitet. Modellnavn, agentnavn, tidsstempler og oppdrags-ID-er beholdes og kan knyttes til andre data. Les filen før eventuell deling.",
        "namesAreLocalToThisFile": true
    });
    Ok(result)
}

fn text(value: &Value, key: &str) -> String {
    value
        .get(key)
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string()
}

fn optional_text(value: &Value, key: &str) -> Option<String> {
    value
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

pub(super) fn project_key(path: &str) -> Result<String, String> {
    let path = path.trim().replace('\\', "/");
    if path.is_empty() || path.len() > 8192 || path.contains('\0') {
        return Err("Ugyldig prosjektsti i avklaringen.".into());
    }
    // Rust canonicalize() retains the Windows extended-length prefix, whereas
    // the UI normally uses ordinary drive/UNC paths. These denote the same
    // exact project; never use suffix matching to compensate for the prefix.
    let path = path.to_lowercase();
    let path = if let Some(unc) = path.strip_prefix("//?/unc/") {
        format!("//{unc}")
    } else {
        path.strip_prefix("//?/").unwrap_or(&path).to_string()
    };
    Ok(path.trim_end_matches('/').to_string())
}

fn case_id(mission_id: &str, index: usize) -> String {
    format!("finding-{mission_id}-{index}")
}

fn valid_case_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 180 && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

fn digest(value: &str) -> String {
    format!("{:x}", Sha256::digest(value.as_bytes()))
}

fn checked_directory(path: &Path, create: bool) -> Result<(), String> {
    match fs::symlink_metadata(path) {
        Ok(meta) => {
            super::storage_safety::validate_stored_path(path, &meta, false)?;
            if !meta.is_dir() {
                return Err(format!(
                    "Avklaringslageret inneholder en lenke eller ugyldig mappe: {}",
                    path.display()
                ));
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound && create => {
            fs::create_dir(path)
                .map_err(|error| format!("Kan ikke opprette {}: {error}", path.display()))?;
            return checked_directory(path, false);
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(format!("Kan ikke lese {}: {error}", path.display())),
    }
    Ok(())
}

fn root(home: &Path, create: bool) -> Result<PathBuf, String> {
    let missions = home.join("missions");
    checked_directory(&missions, create)?;
    let evaluations = missions.join("evaluations");
    checked_directory(&evaluations, create)?;
    Ok(evaluations)
}

fn read_json(path: &Path, budget: &mut u64) -> Result<Value, String> {
    let meta = fs::symlink_metadata(path)
        .map_err(|error| format!("Kan ikke lese {}: {error}", path.display()))?;
    super::storage_safety::validate_stored_path(path, &meta, true)?;
    if !meta.is_file() || meta.len() > MAX_RECORD_BYTES || meta.len() > *budget {
        return Err(format!(
            "Utrygg eller for stor datapost: {}. Ingen data blir skjult eller overskrevet.",
            path.display()
        ));
    }
    let max_bytes = MAX_RECORD_BYTES.min(*budget);
    let mut bytes = Vec::new();
    fs::File::open(path)
        .map_err(|error| format!("Kan ikke lese {}: {error}", path.display()))?
        .take(max_bytes + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| format!("Kan ikke lese {}: {error}", path.display()))?;
    if bytes.len() as u64 > max_bytes {
        return Err("Dataposten vokste utover lesegrensen; lesingen ble avbrutt.".into());
    }
    *budget -= bytes.len() as u64;
    serde_json::from_slice(&bytes).map_err(|error| {
        format!(
            "Ugyldig JSON i {}: {error}. Bevar filen for reparasjon.",
            path.display()
        )
    })
}

fn mission(home: &Path, id: &str, budget: &mut u64) -> Result<Value, String> {
    if id.len() > 120 || !super::valid_mission_id(id) {
        return Err("Ugyldig oppdrags-ID i avklaringen.".into());
    }
    checked_directory(&home.join("missions"), false)?;
    let value = read_indexed_mission(&home.join("missions").join(format!("{id}.json")), budget)?;
    if text(&value, "id") != id {
        return Err("Oppdragsfilens ID stemmer ikke med filnavnet.".into());
    }
    project_key(&text(&value, "projectPath"))?;
    Ok(value)
}

fn workspace_metadata(value: &Value) -> Value {
    let mut result = serde_json::Map::new();
    for key in [
        "projectPath",
        "controlMode",
        "branch",
        "headCommit",
        "changedFiles",
        "diffTruncated",
        // Carried through on a second pass over an already-reduced record.
        "changedFileNames",
    ] {
        if let Some(field) = value.get(key) {
            result.insert(key.into(), field.clone());
        }
    }
    // Paths, derived from the status, never the status text itself. A file name
    // is already in this store on every finding; the status lines and the diff
    // are not, and must not become so.
    if !result.contains_key("changedFileNames") {
        if let Some(status) = value.get("status").and_then(Value::as_str) {
            let names = super::changed_paths_from_status(status);
            if !names.is_empty() {
                result.insert("changedFileNames".into(), Value::from(names));
            }
        }
    }
    Value::Object(result)
}

fn checkpoint_metadata(value: &Value) -> Value {
    if !value.is_object() {
        return Value::Null;
    }
    let mut result = serde_json::Map::new();
    for key in [
        "directory",
        "mode",
        "complete",
        "fileCount",
        "totalBytes",
        "skippedFiles",
        "changedFiles",
        "warning",
    ] {
        if let Some(field) = value.get(key) {
            result.insert(key.into(), field.clone());
        }
    }
    Value::Object(result)
}

fn provenance(home: &Path, value: &Value, budget: &mut u64) -> Result<Value, String> {
    let source_id = optional_text(value, "sourceMissionId");
    let source = match source_id.as_deref() {
        Some(id) => {
            let source_path = home.join("missions").join(format!("{id}.json"));
            if id.len() > 120 || !super::valid_mission_id(id) {
                return Err("Ugyldig kildeoppdrag i valideringen.".into());
            }
            if source_path.exists() {
                let record = mission(home, id, budget)?;
                if project_key(&text(&record, "projectPath"))?
                    != project_key(&text(value, "projectPath"))?
                {
                    return Err(
                        "Kildeoppdraget tilhører et annet prosjekt. Avklaringen blir ikke koblet."
                            .into(),
                    );
                }
                Some(record)
            } else {
                None
            }
        }
        None => None,
    };
    let started = value.get("startedUnixMs").and_then(Value::as_u64);
    let finished = value.get("finishedUnixMs").and_then(Value::as_u64);
    Ok(json!({
        "validatorAgent": optional_text(value,"agent"),
        "requestedModel": optional_text(value,"model"),
        "resolvedModel": optional_text(value,"resolvedModel"),
        "modelSource": optional_text(value,"modelSource").unwrap_or_else(|| "unknown".into()),
        "resolverModel": value.pointer("/findings/resolverModel").and_then(Value::as_str),
        "contextMode": optional_text(value,"mode").unwrap_or_else(|| "unknown".into()),
        "missionPurpose": optional_text(value,"purpose"),
        "sourceMissionId": source_id,
        "sourceRecordAvailable": source.is_some(),
        "sourceAgent": source.as_ref().and_then(|v|optional_text(v,"agent")),
        "sourceRequestedModel": source.as_ref().and_then(|v|optional_text(v,"model")),
        "sourceResolvedModel": source.as_ref().and_then(|v|optional_text(v,"resolvedModel")),
        "sourceModelSource": source.as_ref().and_then(|v|optional_text(v,"modelSource")),
        "startedUnixMs": started,
        "finishedUnixMs": finished,
        "durationMs": started.zip(finished).map(|(start,end)|end.saturating_sub(start)),
        "workspaceBefore": workspace_metadata(&value["workspaceBefore"]),
        "workspaceAfter": workspace_metadata(&value["workspaceAfter"]),
        "sourceWorkspaceBefore": source.as_ref().map(|v|workspace_metadata(&v["workspaceBefore"])),
        "sourceWorkspaceAfter": source.as_ref().map(|v|workspace_metadata(&v["workspaceAfter"])),
        "checkpoint": checkpoint_metadata(&value["checkpoint"]),
        "sourceCheckpoint":source.as_ref().map(|v|checkpoint_metadata(&v["checkpoint"])),
        "assessmentAuthority": "userRecordedEvidenceNotAutomaticallyVerified"
    }))
}

fn seeds(home: &Path, value: &Value, budget: &mut u64) -> Result<Vec<Seed>, String> {
    let Some(report) = value.get("findings").filter(|report| !report.is_null()) else {
        return Ok(Vec::new());
    };
    let findings = report
        .get("findings")
        .and_then(Value::as_array)
        .ok_or_else(|| "Lagrede valideringsfunn har ugyldig struktur.".to_string())?;
    if findings.len() > 1000 {
        return Err("For mange funn i ett oppdrag.".into());
    }
    let id = text(value, "id");
    if id.len() > 120 || !super::valid_mission_id(&id) {
        return Err("Ugyldig oppdrags-ID.".into());
    }
    let project_path = text(value, "projectPath");
    project_key(&project_path)?;
    let provenance = provenance(home, value, budget)?;
    findings
        .iter()
        .enumerate()
        .map(|(index, item)| {
            let title = text(item, "title");
            let detail = text(item, "detail");
            if title.trim().is_empty() || detail.trim().is_empty() {
                return Err(format!(
                    "Funn {} i {id} mangler påstand eller forklaring.",
                    index + 1
                ));
            }
            Ok(Seed {
                id: case_id(&id, index),
                kind: "validatorFinding".into(),
                mission_id: Some(id.clone()),
                finding_index: Some(index),
                project_path: project_path.clone(),
                title,
                detail,
                file: optional_text(item, "file"),
                severity: optional_text(item, "severity"),
                provenance: provenance.clone(),
            })
        })
        .collect()
}

fn entries(path: &Path, limit: usize) -> Result<Vec<PathBuf>, String> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    let mut items = Vec::new();
    for entry in
        fs::read_dir(path).map_err(|error| format!("Kan ikke lese {}: {error}", path.display()))?
    {
        items.push(entry.map_err(|error| error.to_string())?.path());
        if items.len() > limit {
            return Err(format!("Datagrensen ({limit} poster) er nådd i {}. Oversikten avbrytes uten å skjule eldre poster.",path.display()));
        }
    }
    items.sort();
    Ok(items)
}

fn validate_assessment(
    verdict: &str,
    remediation: &str,
    evidence: &str,
    notes: &str,
) -> Result<(), String> {
    if ![
        "unreviewed",
        "unresolved",
        "confirmed",
        "partial",
        "falsePositive",
    ]
    .contains(&verdict)
    {
        return Err("Ugyldig avklaring.".into());
    }
    if !["open", "fixed", "verified"].contains(&remediation) {
        return Err("Ugyldig rettestatus.".into());
    }
    if evidence.len() > 16_000 || notes.len() > 8_000 {
        return Err("Bevis eller notat er for langt.".into());
    }
    if (["confirmed", "partial", "falsePositive"].contains(&verdict) || remediation == "verified")
        && evidence.trim().is_empty()
    {
        return Err(
            "Beskriv beviset, testen eller reproduksjonen før du lagrer denne avklaringen.".into(),
        );
    }
    if remediation != "open" && !["confirmed", "partial"].contains(&verdict) {
        return Err(
            "Rettet/kontrollert krever at funnet først er bekreftet eller delvis riktig.".into(),
        );
    }
    Ok(())
}

fn validate_ratings(
    usefulness: Option<u8>,
    actionability: Option<u8>,
    novelty: Option<u8>,
) -> Result<(), String> {
    for (label, rating) in [
        ("Nytteverdi", usefulness),
        ("Handlingsklarhet", actionability),
        ("Ny informasjon", novelty),
    ] {
        if rating.is_some_and(|score| !(1..=10).contains(&score)) {
            return Err(format!(
                "{label} må være et heltall fra 1 til 10, eller stå uvurdert."
            ));
        }
    }
    Ok(())
}

fn load_case(directory: &Path, budget: &mut u64) -> Result<Option<Case>, String> {
    checked_directory(directory, false)?;
    let files = entries(directory, MAX_REVISIONS)?;
    let mut seed: Option<Seed> = None;
    let mut history = Vec::new();
    for path in files {
        let record: EventRecord = serde_json::from_value(read_json(&path, budget)?)
            .map_err(|error| format!("Ugyldig avklaringspost {}: {error}", path.display()))?;
        let expected = history.len() as u64 + 1;
        if record.schema_version != 1
            || record.event.revision != expected
            || path.file_name().and_then(|name| name.to_str())
                != Some(&format!("revision-{expected:020}.json"))
            || !valid_case_id(&record.seed.id)
            || directory.file_name().and_then(|name| name.to_str())
                != Some(&digest(&record.seed.id))
            || seed.as_ref().is_some_and(|prior| prior != &record.seed)
            || record.event.origin != "user"
            || record.event.at_unix_ms == 0
        {
            return Err(format!("Avklaringshistorikken er inkonsistent: {}. Ingen automatisk reparasjon eller overskriving.",path.display()));
        }
        project_key(&record.seed.project_path)?;
        validate_assessment(
            &record.event.verdict,
            &record.event.remediation,
            &record.event.evidence,
            &record.event.notes,
        )?;
        validate_ratings(
            record.event.usefulness,
            record.event.actionability,
            record.event.novelty,
        )?;
        if let Some(id) = record.seed.mission_id.as_deref() {
            if !super::valid_mission_id(id)
                || record.seed.kind != "validatorFinding"
                || record
                    .seed
                    .finding_index
                    .map_or(true, |index| case_id(id, index) != record.seed.id)
            {
                return Err("Avklaringen har feil kildeidentitet.".into());
            }
        } else if record.seed.kind != "laterDiscovered"
            || !record.seed.id.starts_with("later-")
            || record.seed.finding_index.is_some()
        {
            return Err("Avklaringen har ukjent opprinnelse.".into());
        }
        if !["assessment", "followupLinked"].contains(&record.event.kind.as_str())
            || (record.event.kind == "followupLinked") != record.event.followup.is_some()
        {
            return Err("Avklaringsposten har en ugyldig hendelsestype.".into());
        }
        if let Some(followup) = &record.event.followup {
            let id = text(followup, "missionId");
            if !super::valid_mission_id(&id)
                || project_key(&text(followup, "projectPath"))?
                    != project_key(&record.seed.project_path)?
            {
                return Err("Oppfølgingen har ugyldig kilde eller prosjekt.".into());
            }
            let prior = history.last();
            if record.event.verdict
                != prior.map_or("unreviewed", |event: &Assessment| event.verdict.as_str())
                || record.event.remediation
                    != prior.map_or("open", |event| event.remediation.as_str())
                || record.event.evidence != prior.map_or("", |event| event.evidence.as_str())
                || record.event.usefulness != prior.and_then(|event| event.usefulness)
                || record.event.actionability != prior.and_then(|event| event.actionability)
                || record.event.novelty != prior.and_then(|event| event.novelty)
                || record.event.notes != prior.map_or("", |event| event.notes.as_str())
            {
                return Err("En videresending kan ikke endre avklaringen.".into());
            }
        }
        seed = Some(record.seed);
        history.push(record.event);
    }
    Ok(seed.map(|seed| Case::new(seed, history)))
}

fn with_history(root: &Path, seed: Seed, budget: &mut u64) -> Result<Case, String> {
    let stored = load_case(&root.join(digest(&seed.id)), budget)?;
    match stored {
        Some(case) => {
            if project_key(&case.seed.project_path)? != project_key(&seed.project_path)?
                || case.seed.title != seed.title
                || case.seed.detail != seed.detail
                || case.seed.file != seed.file
                || case.seed.mission_id != seed.mission_id
                || case.seed.finding_index != seed.finding_index
            {
                return Err("Det opprinnelige funnet er endret siden avklaringen ble lagret. Avklaringen arves ikke av det endrede funnet.".into());
            }
            Ok(case)
        }
        None => Ok(Case::new(seed, Vec::new())),
    }
}

fn append(root: &Path, case: Case, request: &SaveRequest) -> Result<Case, String> {
    append_event(root, case, request, None)
}

fn append_event(
    root: &Path,
    mut case: Case,
    request: &SaveRequest,
    followup: Option<Value>,
) -> Result<Case, String> {
    if case.revision != request.expected_revision {
        return Err(
            "Avklaringen er endret i mellomtiden. Last den inn på nytt før du lagrer.".into(),
        );
    }
    validate_assessment(
        &request.verdict,
        &request.remediation,
        &request.evidence,
        &request.notes,
    )?;
    validate_ratings(request.usefulness, request.actionability, request.novelty)?;
    if case.history.len() >= MAX_REVISIONS {
        return Err(
            "Avklaringen har nådd grensen for revisjoner; ingen historikk er slettet.".into(),
        );
    }
    let directory = root.join(digest(&case.seed.id));
    checked_directory(&directory, true)?;
    let event = Assessment {
        revision: case.revision + 1,
        verdict: request.verdict.clone(),
        remediation: request.remediation.clone(),
        evidence: request.evidence.trim().into(),
        usefulness: request.usefulness,
        actionability: request.actionability,
        novelty: request.novelty,
        notes: request.notes.trim().into(),
        origin: "user".into(),
        at_unix_ms: super::now_unix_ms(),
        kind: if followup.is_some() {
            "followupLinked"
        } else {
            "assessment"
        }
        .into(),
        followup,
    };
    let path = directory.join(format!("revision-{:020}.json", event.revision));
    let bytes = serde_json::to_vec_pretty(&EventRecord {
        schema_version: 1,
        seed: case.seed.clone(),
        event: event.clone(),
    })
    .map_err(|error| error.to_string())?;
    // create_new is an optimistic compare-and-set on this filesystem. Never
    // replace a previous event. It is NOT a distributed Dropbox lock: delayed
    // sync conflicts must be preserved and will fail strict history loading.
    let mut file = OpenOptions::new().write(true).create_new(true).open(&path)
        .map_err(|error|format!("Avklaringen ble ikke lagret. Last inn på nytt; eksisterende historikk er bevart: {error}"))?;
    file.write_all(&bytes).and_then(|()|file.sync_all())
        .map_err(|error|format!("Avklaringen kunne ikke lagres fullstendig: {error}. Filen er bevart for reparasjon; ikke anta at lagring lyktes."))?;
    case.history.push(event);
    Ok(Case::new(case.seed, case.history))
}

fn finding_cases_in(home: &Path, id: &str) -> Result<Cases, String> {
    let mut budget = MAX_SCAN_BYTES;
    let root = root(home, false)?;
    let value = mission(home, id, &mut budget)?;
    let mut cases: Vec<Case> = seeds(home, &value, &mut budget)?
        .into_iter()
        .map(|seed| with_history(&root, seed, &mut budget))
        .collect::<Result<_, _>>()?;
    for case in &mut cases {
        refresh_followups(home, case, &mut budget)?;
    }
    Ok(Cases { cases })
}

fn save_in(home: &Path, request: SaveRequest) -> Result<Case, String> {
    validate_ratings(request.usefulness, request.actionability, request.novelty)?;
    validate_assessment(
        &request.verdict,
        &request.remediation,
        &request.evidence,
        &request.notes,
    )?;
    let mut budget = MAX_SCAN_BYTES;
    let root = root(home, true)?;
    let case = if let Some(id) = request.case_id.as_deref() {
        if request.mission_id.is_some() || request.finding_index.is_some() || !valid_case_id(id) {
            return Err("Oppgi enten funnets ID eller oppdrag og funnnummer, ikke begge.".into());
        }
        let stored = load_case(&root.join(digest(id)), &mut budget)?
            .ok_or_else(|| "Fant ikke den lagrede avklaringen.".to_string())?;
        if let Some(mission_id) = stored.seed.mission_id.as_deref() {
            let source_path = home.join("missions").join(format!("{mission_id}.json"));
            if source_path.exists() {
                let value = mission(home, mission_id, &mut budget)?;
                let seed = seeds(home, &value, &mut budget)?
                    .into_iter()
                    .nth(stored.seed.finding_index.unwrap_or(usize::MAX))
                    .ok_or_else(|| "Det opprinnelige funnet finnes ikke lenger.".to_string())?;
                with_history(&root, seed, &mut budget)?
            } else {
                stored
            }
        } else {
            stored
        }
    } else {
        let id = request
            .mission_id
            .as_deref()
            .ok_or_else(|| "Avklaringen mangler oppdrags-ID.".to_string())?;
        let index = request
            .finding_index
            .ok_or_else(|| "Avklaringen mangler funnnummer.".to_string())?;
        let value = mission(home, id, &mut budget)?;
        let seed = seeds(home, &value, &mut budget)?
            .into_iter()
            .nth(index)
            .ok_or_else(|| "Funnet finnes ikke i oppdraget.".to_string())?;
        with_history(&root, seed, &mut budget)?
    };
    append(&root, case, &request)
}

fn later_in(home: &Path, request: LaterRequest) -> Result<Case, String> {
    project_key(&request.project_path)?;
    if request.title.trim().is_empty()
        || request.detail.trim().is_empty()
        || request.title.len() > 500
        || request.detail.len() > 8000
        || request.file.as_ref().is_some_and(|file| file.len() > 8192)
        || request.evidence.trim().is_empty()
    {
        return Err("Beskriv feilen som ble funnet senere, og legg ved konkret bevis.".into());
    }
    let mut budget = MAX_SCAN_BYTES;
    let source = match request.source_mission_id.as_deref() {
        Some(id) => {
            let value = mission(home, id, &mut budget)?;
            if project_key(&text(&value, "projectPath"))? != project_key(&request.project_path)? {
                return Err("Kildeoppdraget tilhører et annet prosjekt.".into());
            }
            Some(value)
        }
        None => None,
    };
    let root = root(home, true)?;
    let id = format!(
        "later-{}-{}-{}",
        super::now_unix_ms(),
        std::process::id(),
        super::TEMP_PROMPT_COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    );
    let seed = Seed {
        id,
        kind: "laterDiscovered".into(),
        mission_id: None,
        finding_index: None,
        project_path: request.project_path,
        title: request.title.trim().into(),
        detail: request.detail.trim().into(),
        file: request.file,
        severity: None,
        provenance: json!({"sourceMissionId":request.source_mission_id,"sourceRecordAvailable":source.is_some(),
            "sourceAgent":source.as_ref().and_then(|v|optional_text(v,"agent")),
            "sourceRequestedModel":source.as_ref().and_then(|v|optional_text(v,"model")),
            "sourceResolvedModel":source.as_ref().and_then(|v|optional_text(v,"resolvedModel")),
            "sourceWorkspaceBefore":source.as_ref().map(|v|workspace_metadata(&v["workspaceBefore"])),
            "sourceWorkspaceAfter":source.as_ref().map(|v|workspace_metadata(&v["workspaceAfter"])),
            "sourceCheckpoint":source.as_ref().map(|v|checkpoint_metadata(&v["checkpoint"])),
            "contextMode":"laterDiscovered","assessmentAuthority":"userRecordedEvidenceNotAutomaticallyVerified"}),
    };
    append(
        &root,
        Case::new(seed, Vec::new()),
        &SaveRequest {
            case_id: None,
            mission_id: None,
            finding_index: None,
            expected_revision: 0,
            verdict: "unresolved".into(),
            remediation: "open".into(),
            evidence: request.evidence,
            usefulness: None,
            actionability: None,
            novelty: None,
            notes: String::new(),
        },
    )
}

fn followup_metadata(value: &Value) -> Value {
    json!({"missionId":optional_text(value,"id"),"projectPath":optional_text(value,"projectPath"),
        "agent":optional_text(value,"agent"),"requestedModel":optional_text(value,"model"),"resolvedModel":optional_text(value,"resolvedModel"),
        "status":optional_text(value,"status"),"startedUnixMs":value.get("startedUnixMs"),"finishedUnixMs":value.get("finishedUnixMs"),
        "durationMs":value.get("startedUnixMs").and_then(Value::as_u64).zip(value.get("finishedUnixMs").and_then(Value::as_u64)).map(|(start,end)|end.saturating_sub(start)),
        "recordAvailable":true})
}

fn followup_record(home: &Path, id: &str, budget: &mut u64) -> Result<Option<Value>, String> {
    if id.len() > 120 || !super::valid_mission_id(id) {
        return Err("Ugyldig oppfølgings-ID.".into());
    }
    if let Some(active) = super::active_mission_snapshot(id) {
        return serde_json::to_value(active)
            .map(Some)
            .map_err(|error| error.to_string());
    }
    if home.join("missions").join(format!("{id}.json")).exists() {
        return mission(home, id, budget).map(Some);
    }
    Ok(None)
}

fn refresh_followups(home: &Path, case: &mut Case, budget: &mut u64) -> Result<(), String> {
    for followup in &mut case.followups {
        let id = text(followup, "missionId");
        if let Some(current) = followup_record(home, &id, budget)? {
            if project_key(&text(&current, "projectPath"))? != project_key(&case.seed.project_path)?
                || text(&current, "purpose") != "writer"
            {
                return Err("Oppfølgingsoppdraget har endret kildeidentitet.".into());
            }
            *followup = followup_metadata(&current);
        } else {
            followup["recordAvailable"] = json!(false);
        }
    }
    Ok(())
}

fn link_in(home: &Path, request: FollowupRequest) -> Result<Case, String> {
    let mut budget = MAX_SCAN_BYTES;
    let root = root(home, true)?;
    let value = mission(home, &request.mission_id, &mut budget)?;
    let seed = seeds(home, &value, &mut budget)?
        .into_iter()
        .nth(request.finding_index)
        .ok_or_else(|| "Funnet finnes ikke.".to_string())?;
    let case = with_history(&root, seed, &mut budget)?;
    let followup = followup_record(home, &request.followup_mission_id, &mut budget)?
        .ok_or_else(|| "Oppfølgingsoppdraget finnes ikke.".to_string())?;
    // A day is the cap. Longer than that and the panel was left open, which
    // measures the window rather than the decision.
    let deliberation = request
        .deliberation_ms
        .filter(|value| *value > 0 && *value <= 24 * 60 * 60 * 1000);
    if text(&followup, "purpose") != "writer"
        || project_key(&text(&followup, "projectPath"))? != project_key(&case.seed.project_path)?
    {
        return Err("Oppfølgingen må være et skriveoppdrag i nøyaktig samme prosjekt.".into());
    }
    if case
        .followups
        .iter()
        .any(|item| text(item, "missionId") == request.followup_mission_id)
    {
        return Ok(case);
    }
    let save = SaveRequest {
        mission_id: None,
        finding_index: None,
        case_id: None,
        expected_revision: case.revision,
        verdict: case.verdict.clone(),
        remediation: case.remediation.clone(),
        evidence: case.evidence.clone(),
        usefulness: case.usefulness,
        actionability: case.actionability,
        novelty: case.novelty,
        notes: case.notes.clone(),
    };
    let mut metadata = followup_metadata(&followup);
    if let (Some(object), Some(value)) = (metadata.as_object_mut(), deliberation) {
        object.insert("deliberationMs".into(), Value::from(value));
    }
    append_event(&root, case, &save, Some(metadata))
}

fn add_count(counts: &mut Counts, case: &Case) {
    counts.total += 1;
    if case.seed.kind == "laterDiscovered" {
        counts.later_discovered += 1;
        return;
    }
    if let Some(score) = case.usefulness {
        counts.usefulness_rated += 1;
        counts.usefulness_total += score as usize;
        counts.usefulness_average =
            Some(counts.usefulness_total as f64 / counts.usefulness_rated as f64);
    }
    if let Some(score) = case.actionability {
        counts.actionability_rated += 1;
        counts.actionability_total += score as usize;
        counts.actionability_average =
            Some(counts.actionability_total as f64 / counts.actionability_rated as f64);
    }
    if let Some(score) = case.novelty {
        counts.novelty_rated += 1;
        counts.novelty_total += score as usize;
        counts.novelty_average = Some(counts.novelty_total as f64 / counts.novelty_rated as f64);
    }
    match case.verdict.as_str() {
        "confirmed" => counts.confirmed += 1,
        "partial" => counts.partial += 1,
        "falsePositive" => counts.false_positive += 1,
        "unresolved" => counts.unresolved += 1,
        _ => counts.unreviewed += 1,
    }
    if case.remediation == "fixed" {
        counts.remediation_fixed += 1;
    }
    if case.remediation == "verified" {
        counts.remediation_verified += 1;
    }
    counts.adjudicated = counts.confirmed + counts.false_positive;
    counts.confirmed_rate =
        (counts.adjudicated > 0).then(|| counts.confirmed as f64 / counts.adjudicated as f64);
}

fn dataset_in(home: &Path, project_path: String) -> Result<Dataset, String> {
    let wanted = project_key(&project_path)?;
    let root = root(home, false)?;
    let mut budget = MAX_SCAN_BYTES;
    let mut cases = BTreeMap::new();
    // Stored cases survive a subsequently archived/deleted mission. They carry
    // their immutable source snapshot, but never a copied prompt or raw output.
    for directory in entries(&root, MAX_ENTRIES)? {
        if directory.file_name().and_then(|name| name.to_str()) == Some("exports") {
            continue;
        }
        // Project routing comes from the immutable first event. An unrelated
        // project's later history must not be read merely to open this one.
        checked_directory(&directory, false)?;
        let first_path = directory.join("revision-00000000000000000001.json");
        if first_path.exists() {
            let first: EventRecord =
                serde_json::from_value(read_json(&first_path, &mut budget)?)
                    .map_err(|error| format!("Ugyldig avklaringsindeks: {error}"))?;
            if first.schema_version != 1
                || first.event.revision != 1
                || !valid_case_id(&first.seed.id)
                || directory.file_name().and_then(|name| name.to_str())
                    != Some(&digest(&first.seed.id))
            {
                return Err("Avklaringsindeksen har ugyldig kildeidentitet.".into());
            }
            if project_key(&first.seed.project_path)? != wanted {
                continue;
            }
        }
        if let Some(case) = load_case(&directory, &mut budget)? {
            if project_key(&case.seed.project_path)? == wanted {
                cases.insert(case.seed.id.clone(), case);
            }
        }
    }
    for path in entries(&home.join("missions"), MAX_ENTRIES)? {
        if path.extension().and_then(|extension| extension.to_str()) != Some("json") {
            continue;
        }
        let value = read_indexed_mission(&path, &mut budget)?;
        if project_key(&text(&value, "projectPath"))? != wanted {
            continue;
        }
        let id = text(&value, "id");
        if path.file_stem().and_then(|stem| stem.to_str()) != Some(&id) {
            return Err("Oppdragsfilens ID stemmer ikke med filnavnet.".into());
        }
        for seed in seeds(home, &value, &mut budget)? {
            // The append-only history was already loaded above. Reuse it,
            // while checking that the original claim has not been replaced.
            let case = if let Some(case) = cases.remove(&seed.id) {
                if project_key(&case.seed.project_path)? != project_key(&seed.project_path)?
                    || case.seed.title != seed.title
                    || case.seed.detail != seed.detail
                    || case.seed.file != seed.file
                    || case.seed.mission_id != seed.mission_id
                    || case.seed.finding_index != seed.finding_index
                {
                    return Err(
                        "Det opprinnelige funnet er endret siden avklaringen ble lagret.".into(),
                    );
                }
                case
            } else {
                Case::new(seed, Vec::new())
            };
            cases.insert(case.seed.id.clone(), case);
        }
    }
    if cases.len() > MAX_ENTRIES {
        return Err("Datasettet er for stort for en samlet lokal visning. Ingen poster er utelatt i en delvis rapport.".into());
    }
    let mut cases: Vec<_> = cases.into_values().collect();
    for case in &mut cases {
        refresh_followups(home, case, &mut budget)?;
    }
    cases.sort_by(|a, b| {
        b.updated_unix_ms
            .cmp(&a.updated_unix_ms)
            .then_with(|| a.seed.id.cmp(&b.seed.id))
    });
    let mut summary = Counts::default();
    let mut groups = BTreeMap::new();
    let mut focus: BTreeMap<&'static str, Counts> = BTreeMap::new();
    for case in &cases {
        add_count(&mut summary, case);
        if case.seed.kind == "laterDiscovered" {
            continue;
        }
        let provenance = &case.seed.provenance;
        let (model, model_source) = if let Some(model) = optional_text(provenance, "resolvedModel")
            .and_then(|model| super::plausible_model_id(&model))
        {
            let source = match provenance.get("modelSource").and_then(Value::as_str) {
                Some("observed") => "observed",
                Some("configured") => "configured",
                Some("requested") => "requested",
                _ => "legacyUnverified",
            };
            (model, source)
        } else if let Some(model) = optional_text(provenance, "requestedModel")
            .and_then(|model| super::plausible_model_id(&model))
        {
            (model, "requestedOnly")
        } else {
            ("unknown".into(), "unknown")
        };
        let model = super::comparable_model(&model);
        // Never collapse same-named files in different folders. Absolute paths
        // outside the project (including unrecorded blind-copy roots) cannot be
        // mapped reliably and remain unknown. End-status is not authorship.
        let scope = match case
            .seed
            .file
            .as_deref()
            .and_then(|file| super::project_relative_file_key(&case.seed.project_path, file))
        {
            None => "unknown",
            Some(name) => match provenance
                .pointer("/sourceWorkspaceAfter/changedFileNames")
                .and_then(Value::as_array)
            {
                None => "unknown",
                Some(changed) => {
                    let paths: Option<Vec<String>> = changed
                        .iter()
                        .map(|written| {
                            written.as_str().and_then(|path| {
                                super::project_relative_file_key(&case.seed.project_path, path)
                            })
                        })
                        .collect();
                    if paths.as_ref().is_some_and(|paths| paths.contains(&name)) {
                        "changed"
                    } else if paths.is_none()
                        || provenance.pointer("/sourceWorkspaceAfter/diffTruncated")
                            == Some(&Value::Bool(true))
                    {
                        "unknown"
                    } else {
                        "neighbour"
                    }
                }
            },
        };
        add_count(focus.entry(scope).or_default(), case);
        let agent = optional_text(provenance, "validatorAgent").unwrap_or_else(|| "unknown".into());
        let mode = optional_text(provenance, "contextMode").unwrap_or_else(|| "unknown".into());
        let group = groups
            .entry((
                agent.clone(),
                model.clone(),
                model_source.to_string(),
                mode.clone(),
            ))
            .or_insert_with(|| Group {
                validator_agent: agent,
                model,
                model_source: model_source.into(),
                context_mode: mode,
                counts: Counts::default(),
            });
        add_count(&mut group.counts, case);
    }
    Ok(Dataset { schema_version:1,generated_unix_ms:super::now_unix_ms(),project_path,cases,summary,groups:groups.into_values().collect(),
        focus:focus.into_iter().map(|(scope,counts)|Focus{scope,counts}).collect(),truncated:false,
        rate_definition:"confirmed / (confirmed + falsePositive), validator findings only; partial, unresolved, unreviewed and later discoveries excluded",
        limitations:vec!["Human-recorded evidence, not automatically verified ground truth.","No recall estimate: undiscovered errors are unknown.","Different projects, selected warnings and context modes are not a controlled model benchmark.","File focus matches complete project-relative paths in source end-status, not proven authorship; pre-existing or concurrent changes may be included. Unmappable paths remain unknown.","Full prompts and logs are not copied automatically. Finding text, human evidence and metadata may still contain sensitive text or code."] })
}

pub(crate) fn get_finding_evaluations(request: MissionRequest) -> Result<Cases, String> {
    let home = super::resolve_agentsync_home()?;
    consistent_read(|| finding_cases_in(&home, &request.mission_id))
}

pub(crate) fn save_finding_evaluation(request: SaveRequest) -> Result<Case, String> {
    let _guard = STORE_LOCK
        .lock()
        .map_err(|_| "Avklaringslageret er opptatt etter en intern feil.".to_string())?;
    let _revision = StoreMutation;
    save_in(&super::resolve_agentsync_home()?, request)
}

pub(crate) fn record_later_finding(request: LaterRequest) -> Result<Case, String> {
    let _guard = STORE_LOCK
        .lock()
        .map_err(|_| "Avklaringslageret er opptatt etter en intern feil.".to_string())?;
    let _revision = StoreMutation;
    later_in(&super::resolve_agentsync_home()?, request)
}

pub(crate) fn link_finding_followup(request: FollowupRequest) -> Result<Case, String> {
    let _guard = STORE_LOCK
        .lock()
        .map_err(|_| "Avklaringslageret er opptatt etter en intern feil.".to_string())?;
    let _revision = StoreMutation;
    link_in(&super::resolve_agentsync_home()?, request)
}

pub(crate) fn get_evaluation_dataset(request: ProjectRequest) -> Result<Dataset, String> {
    let home = super::resolve_agentsync_home()?;
    consistent_read(|| dataset_in(&home, request.project_path.clone()))
}

pub(crate) fn export_evaluation_dataset(request: ProjectRequest) -> Result<ExportResult, String> {
    let home = super::resolve_agentsync_home()?;
    let dataset = consistent_read(|| dataset_in(&home, request.project_path.clone()))?;
    let shared = request.shareable;
    let _guard = STORE_LOCK
        .lock()
        .map_err(|_| "Avklaringslageret er utilgjengelig.".to_string())?;
    let directory = root(&home, true)?.join("exports");
    checked_directory(&directory, true)?;
    let path = directory.join(format!(
        "evaluations-{}{}-{}-{}.json",
        if shared { "delbar-" } else { "" },
        dataset.generated_unix_ms,
        std::process::id(),
        super::TEMP_PROMPT_COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    ));
    let bytes = if shared {
        serde_json::to_vec_pretty(&shareable_dataset(&dataset)?)
    } else {
        serde_json::to_vec_pretty(&dataset)
    }
    .map_err(|error| error.to_string())?;
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)
        .map_err(|error| format!("Eksporten kunne ikke opprettes: {error}"))?;
    file.write_all(&bytes)
        .and_then(|()| file.sync_all())
        .map_err(|error| format!("Eksporten ble ikke fullført: {error}"))?;
    Ok(ExportResult {
        path: super::path_text(&path),
        case_count: dataset.cases.len(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "evaluation-test-{}-{}-{}",
                super::super::now_unix_ms(),
                std::process::id(),
                super::super::TEMP_PROMPT_COUNTER
                    .fetch_add(1, std::sync::atomic::Ordering::Relaxed)
            ));
            fs::create_dir_all(root.join("missions")).unwrap();
            Self(root)
        }
        fn mission(&self, id: &str, project: &str) {
            let value = json!({"id":id,"projectPath":project,"agent":"codex","model":"requested-model","resolvedModel":"actual-model", "mode":"blind","purpose":"validator","startedUnixMs":10,"finishedUnixMs":30,
                "prompt":"PRIVATE PROMPT", "output":"PRIVATE OUTPUT","finalOutput":"PRIVATE ANSWER",
                "workspaceBefore":{"headCommit":"abc","diff":"PRIVATE CODE"},
                "findings":{"outcome":"findings","resolverModel":"interpreter","findings":[{"title":"Null bug","detail":"Null access","file":"a.js","actedOn":true,"actedOnBy":["claude"]}]}});
            fs::write(
                self.0.join("missions").join(format!("{id}.json")),
                serde_json::to_vec(&value).unwrap(),
            )
            .unwrap();
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn request(id: &str, revision: u64, verdict: &str) -> SaveRequest {
        SaveRequest {
            mission_id: Some(id.into()),
            finding_index: Some(0),
            case_id: None,
            expected_revision: revision,
            verdict: verdict.into(),
            remediation: "open".into(),
            evidence: "Reproduction: null input fails test a".into(),
            usefulness: None,
            actionability: None,
            novelty: None,
            notes: String::new(),
        }
    }
    #[test]
    fn historical_forwarding_is_not_a_verdict_and_repeats_do_not_inherit_truth() {
        let fixture = Fixture::new();
        fixture.mission("mission-1", "P:/repo");
        fixture.mission("mission-2", "P:/repo");
        let cases = finding_cases_in(&fixture.0, "mission-1").unwrap();
        assert_eq!(cases.cases[0].verdict, "unreviewed");
        assert_eq!(cases.cases[0].revision, 0);
        save_in(&fixture.0, request("mission-1", 0, "falsePositive")).unwrap();
        assert_eq!(
            finding_cases_in(&fixture.0, "mission-2").unwrap().cases[0].verdict,
            "unreviewed"
        );
    }
    #[test]
    fn evidence_remediation_revision_and_immutable_history_are_enforced() {
        let fixture = Fixture::new();
        fixture.mission("mission-1", "P:/repo");
        let mut invalid = request("mission-1", 0, "confirmed");
        invalid.evidence.clear();
        assert!(save_in(&fixture.0, invalid).is_err());
        save_in(&fixture.0, request("mission-1", 0, "confirmed")).unwrap();
        assert!(
            save_in(&fixture.0, request("mission-1", 0, "falsePositive"))
                .unwrap_err()
                .contains("mellomtiden")
        );
        let second = save_in(&fixture.0, request("mission-1", 1, "partial")).unwrap();
        assert_eq!(second.history.len(), 2);
        assert_eq!(second.history[0].verdict, "confirmed");
        let mut invalid = request("mission-1", 2, "falsePositive");
        invalid.remediation = "verified".into();
        assert!(save_in(&fixture.0, invalid).is_err());
        assert_eq!(
            finding_cases_in(&fixture.0, "mission-1").unwrap().cases[0].revision,
            2
        );
    }
    #[test]
    fn malformed_storage_fails_loudly_without_overwrite() {
        let fixture = Fixture::new();
        fixture.mission("mission-1", "P:/repo");
        let first = save_in(&fixture.0, request("mission-1", 0, "confirmed")).unwrap();
        let path = root(&fixture.0, false)
            .unwrap()
            .join(digest(&first.seed.id))
            .join("revision-00000000000000000001.json");
        fs::write(&path, "broken").unwrap();
        assert!(finding_cases_in(&fixture.0, "mission-1").is_err());
        assert!(save_in(&fixture.0, request("mission-1", 1, "partial")).is_err());
        assert_eq!(fs::read_to_string(path).unwrap(), "broken");
    }
    #[test]
    fn a_shareable_dataset_carries_no_path_no_prose_and_no_human_note() {
        let fixture = Fixture::new();
        // A writer whose change and file name would identify the project, and a
        // check whose finding text quotes the code.
        let writer = json!({"id":"mission-901","projectPath":"P:/Dropbox/Hemmelig Kunde/kjerne","agent":"claude",
            "prompt":"Rett innloggingen","mode":"shared","purpose":"writer","status":"completed","changedFiles":1,
            "workspaceBefore":{"status":"","controlMode":"checkpoint"},
            "workspaceAfter":{"status":" M src/kundeportal.js","controlMode":"checkpoint","changedFiles":1,
                "branch":"kunde/fiks","headCommit":"deadbeefcafe"}});
        fs::write(
            fixture.0.join("missions").join("mission-901.json"),
            serde_json::to_vec(&writer).unwrap(),
        )
        .unwrap();
        let check = json!({"id":"mission-902","projectPath":"P:/Dropbox/Hemmelig Kunde/kjerne","agent":"codex",
            "model":"m","resolvedModel":"gpt-5.6-sol","modelSource":"observed","mode":"blind","purpose":"validator",
            "sourceMissionId":"mission-901","startedUnixMs":30,"finishedUnixMs":40,
            "checkpoint":{"directory":"C:/Users/noen/.agentsync/checkpoints/mission-902","mode":"full","complete":true,"fileCount":3},
            "findings":{"outcome":"findings","findings":[
                {"title":"KUNDENAVN lekker i loggen","detail":"Linje 42 skriver kundenummeret ut","file":"src/kundeportal.js","severity":"hoy"}]}});
        fs::write(
            fixture.0.join("missions").join("mission-902.json"),
            serde_json::to_vec(&check).unwrap(),
        )
        .unwrap();

        // A human verdict with evidence in their own words.
        save_in(
            &fixture.0,
            SaveRequest {
                mission_id: Some("mission-902".into()),
                finding_index: Some(0),
                case_id: None,
                expected_revision: 0,
                verdict: "confirmed".into(),
                remediation: "open".into(),
                evidence: "Reproduserte med kundenummer 55512 i staging".into(),
                usefulness: Some(9),
                actionability: Some(8),
                novelty: Some(6),
                notes: "Kontakt Hemmelig Kunde før vi lukker".into(),
            },
        )
        .unwrap();

        let dataset = dataset_in(&fixture.0, "P:/Dropbox/Hemmelig Kunde/kjerne".into()).unwrap();
        let shared = shareable_dataset(&dataset).unwrap();
        let text = serde_json::to_string(&shared).unwrap();

        // Nothing that names the project, the file, the branch, the commit, the
        // checkpoint directory, the claim, the evidence or the note.
        for leak in [
            "Hemmelig",
            "Dropbox",
            "kundeportal",
            "KUNDENAVN",
            "kundenummer",
            "55512",
            "deadbeef",
            "kunde/fiks",
            "Users/noen",
            "Linje 42",
        ] {
            assert!(!text.contains(leak), "lekket {leak}: {text}");
        }

        // And everything the measurement is actually made of survives.
        let case = &shared["cases"][0];
        assert_eq!(case["projectPath"], "prosjekt-1");
        assert_eq!(
            case["file"], "fil-1.js",
            "the extension is part of the measurement"
        );
        assert_eq!(case["verdict"], "confirmed");
        assert_eq!(case["usefulness"], 9);
        assert_eq!(case["severity"], "hoy");
        assert_eq!(case["provenance"]["contextMode"], "blind");
        assert_eq!(case["provenance"]["resolvedModel"], "gpt-5.6-sol");
        assert_eq!(case["provenance"]["modelSource"], "observed");
        assert_eq!(case["provenance"]["sourceAgent"], "claude");
        // The checkpoint survives with its counts and without its directory.
        assert_eq!(case["provenance"]["checkpoint"]["fileCount"], 3);
        assert!(case["provenance"]["checkpoint"].get("directory").is_none());
        // The same file named twice inside one export gets the same name.
        assert_eq!(
            case["provenance"]["sourceWorkspaceAfter"]["changedFileNames"][0],
            "fil-1.js"
        );
        assert_eq!(shared["summary"]["confirmed"], 1);
        assert_eq!(shared["shared"]["anonymised"], false);
        assert_eq!(shared["shared"]["redacted"], true);
        assert_eq!(shared["shared"]["reviewRequiredBeforeSharing"], true);
        assert!(
            shared["rateDefinition"].is_string(),
            "a number without its definition is misread"
        );

        // The history is kept as events, without the words a person wrote.
        assert_eq!(case["history"][0]["verdict"], "confirmed");
        assert!(case["history"][0].get("evidence").is_none());
        assert!(case["history"][0].get("notes").is_none());
    }

    // Reading the allowlist is not the same as trying to get past it. These are
    // the values an adversarial record could actually carry into an export that
    // is meant to leave the machine.
    #[test]
    fn hostile_values_cannot_ride_out_in_a_shareable_export() {
        let mut names = Names::default();
        let case = json!({
            "id": "finding-mission-1-0",
            "kind": "validatorFinding",
            "missionId": "mission-1",
            "findingIndex": 0,
            "projectPath": "P:/Dropbox/Hemmelig Kunde/kjerne",
            "title": "KUNDENAVN i loggen",
            "detail": "Linje 42",
            // An extension nobody allowed: a company name in the suffix.
            "file": "src/oppsett.hemmeligkunde",
            "severity": "hoy",
            "verdict": "confirmed",
            "evidence": "Reproduserte med kundenummer 55512",
            "notes": "Ring Hemmelig Kunde",
            "origin": "user",
            "provenance": {
                "contextMode": "blind",
                // No whitespace and under 80 characters, so it passes the model
                // name check and is copied verbatim.
                "resolvedModel": "p:/dropbox/hemmelig-kunde/kjerne",
                "modelSource": "observed",
                // A nested object hidden where a scalar is expected.
                "durationMs": {"skjult": "Hemmelig Kunde"},
                "checkpoint": {"directory": "C:/Users/noen/.agentsync", "mode": "full",
                    "warning": "Hoppet over C:/Users/noen/Hemmelig Kunde/nokkel.pem"},
                "sourceWorkspaceAfter": {"branch": "kunde/fiks", "headCommit": "deadbeefcafe",
                    "changedFileNames": ["src/oppsett.hemmeligkunde", "packages/a/index.ts"]}
            },
            "history": [{"verdict": "confirmed", "evidence": "Kundenummer 55512", "notes": "Ring dem", "atUnixMs": 1}],
            "followups": [{"missionId": "mission-2", "projectPath": "P:/Dropbox/Hemmelig Kunde/kjerne", "agent": "claude"}]
        });
        let shared = shared_case(&case, &mut names);
        let text = serde_json::to_string(&shared).unwrap();

        for leak in [
            "Hemmelig",
            "hemmelig",
            "Dropbox",
            "dropbox",
            "KUNDENAVN",
            "kundenummer",
            "55512",
            "deadbeef",
            "kunde/fiks",
            "Users/noen",
            "nokkel.pem",
            "oppsett",
            "Linje 42",
            "Ring",
            "skjult",
        ] {
            assert!(!text.contains(leak), "lekket {leak}: {text}");
        }

        // An unknown extension is dropped rather than carried through.
        assert_eq!(shared["file"], "fil-1");
        // The same path in the workspace list gets the same running name, and a
        // known extension survives because it is part of the measurement.
        let listed = &shared["provenance"]["sourceWorkspaceAfter"]["changedFileNames"];
        assert_eq!(listed[0], "fil-1");
        assert_eq!(listed[1], "fil-2.ts");
        // The measurement itself is still there.
        assert_eq!(shared["verdict"], "confirmed");
        assert_eq!(shared["provenance"]["contextMode"], "blind");
        assert_eq!(shared["followups"][0]["missionId"], "mission-2");
        assert!(shared["followups"][0].get("projectPath").is_none());
    }

    #[test]
    fn a_field_added_later_does_not_travel_by_default() {
        // The allowlist is the whole point: a case gains a field nobody thought
        // about, and it must not appear in a dataset meant to be sent away.
        let mut names = Names::default();
        let case = json!({"id":"m#0","title":"noe","detail":"noe","file":"a.js",
            "projectPath":"P:/p","verdict":"confirmed","framtidigFelt":"skal ikke ut",
            "provenance":{"contextMode":"blind","framtidigOpphav":"skal heller ikke ut"}});
        let shared = shared_case(&case, &mut names);
        assert!(shared.get("framtidigFelt").is_none());
        assert!(shared["provenance"].get("framtidigOpphav").is_none());
        assert!(shared.get("title").is_none());
        assert_eq!(shared["provenance"]["contextMode"], "blind");
    }

    #[test]
    fn shared_export_removes_checkpoint_warning_prose_and_nested_metadata() {
        let mut names = Names::default();
        let case = json!({"projectPath":"P:/kunde", "file":"login.clientid",
        "provenance":{
            "resolvedModel":{"unexpected":"P:/kunde/hemmelig.txt"},
            "checkpoint":{"fileCount":2,"warning":"Could not read P:/kunde/passord.txt"},
            "workspaceAfter":{"changedFiles":{"unexpected":"sensitive prose"}}
        }});
        let shared = shared_case(&case, &mut names);
        let encoded = serde_json::to_string(&shared).unwrap();
        for secret in ["passord", "hemmelig", "sensitive prose", "clientid"] {
            assert!(!encoded.contains(secret), "leaked {secret}: {encoded}");
        }
        assert_eq!(shared["provenance"]["checkpoint"]["fileCount"], 2);
        assert!(shared["provenance"].get("resolvedModel").is_none());
    }

    #[test]
    fn time_a_person_spent_on_a_finding_is_kept_only_when_it_is_believable() {
        let fixture = Fixture::new();
        fixture.mission("mission-1", "P:/repo");
        // The follow-up has to be a writer mission in the same project.
        let followup = json!({"id":"mission-2","projectPath":"P:/repo","agent":"claude","prompt":"Rett funnet",
            "mode":"shared","purpose":"writer","status":"completed","startedUnixMs":100,"finishedUnixMs":200});
        fs::write(
            fixture.0.join("missions").join("mission-2.json"),
            serde_json::to_vec(&followup).unwrap(),
        )
        .unwrap();

        let link = |ms: Option<u64>| {
            link_in(
                &fixture.0,
                FollowupRequest {
                    mission_id: "mission-1".into(),
                    finding_index: 0,
                    followup_mission_id: "mission-2".into(),
                    deliberation_ms: ms,
                },
            )
        };
        let case = link(Some(45_000)).unwrap();
        assert_eq!(case.followups[0]["deliberationMs"], 45_000);

        // A second link to the same follow-up is a no-op, so a fresh case is
        // needed to check what is refused.
        let other = Fixture::new();
        other.mission("mission-1", "P:/repo");
        fs::write(
            other.0.join("missions").join("mission-2.json"),
            serde_json::to_vec(&followup).unwrap(),
        )
        .unwrap();
        let too_long = link_in(
            &other.0,
            FollowupRequest {
                mission_id: "mission-1".into(),
                finding_index: 0,
                followup_mission_id: "mission-2".into(),
                // Two days: the panel was left open, and that is not a decision.
                deliberation_ms: Some(2 * 24 * 60 * 60 * 1000),
            },
        )
        .unwrap();
        assert!(too_long.followups[0].get("deliberationMs").is_none());
    }

    #[test]
    fn a_finding_is_split_by_whether_the_writer_had_touched_that_file() {
        let fixture = Fixture::new();
        // A writer that changed one file, and a check that found one thing in
        // that file and one thing in a file next to it.
        let writer = json!({"id":"mission-901","projectPath":"P:/p","agent":"claude","prompt":"Rett feilen","mode":"shared","purpose":"writer",
            "startedUnixMs":10,"finishedUnixMs":20,"status":"completed","changedFiles":1,
            "workspaceBefore":{"status":"","controlMode":"checkpoint"},
            "workspaceAfter":{"status":" M src/app.js","controlMode":"checkpoint","changedFiles":1}});
        fs::write(
            fixture.0.join("missions").join("mission-901.json"),
            serde_json::to_vec(&writer).unwrap(),
        )
        .unwrap();
        let check = json!({"id":"mission-902","projectPath":"P:/p","agent":"codex","model":"m","mode":"blind","purpose":"validator",
            "sourceMissionId":"mission-901","startedUnixMs":30,"finishedUnixMs":40,
            "findings":{"outcome":"findings","findings":[
                {"title":"I den endrede filen","detail":"Feil","file":"src/app.js"},
                {"title":"I nabofilen","detail":"Feil","file":"src/other.js"},
                {"title":"Uten fil","detail":"Feil"}]}});
        fs::write(
            fixture.0.join("missions").join("mission-902.json"),
            serde_json::to_vec(&check).unwrap(),
        )
        .unwrap();

        let dataset = dataset_in(&fixture.0, "P:/p".into()).unwrap();
        let by = |scope: &str| {
            dataset
                .focus
                .iter()
                .find(|item| item.scope == scope)
                .map(|item| item.counts.total)
        };
        assert_eq!(by("changed"), Some(1));
        assert_eq!(by("neighbour"), Some(1));
        // A finding without a file is never folded into either half.
        assert_eq!(by("unknown"), Some(1));
    }

    #[test]
    fn exact_project_scope_and_model_provenance_with_no_raw_text() {
        let fixture = Fixture::new();
        fixture.mission("mission-1", "P:/repo");
        fixture.mission("mission-2", "P:/repo/nested");
        fixture.mission("mission-3", "Q:/repo");
        let dataset = dataset_in(&fixture.0, "p:\\repo".into()).unwrap();
        assert_eq!(dataset.cases.len(), 1);
        assert_eq!(dataset.groups[0].model, "actual-model");
        assert_eq!(dataset.groups[0].model_source, "legacyUnverified");
        assert_eq!(
            dataset.cases[0].seed.provenance["requestedModel"],
            "requested-model"
        );
        assert_eq!(dataset.cases[0].seed.provenance["durationMs"], 20);
        assert!(!serde_json::to_string(&dataset).unwrap().contains("PRIVATE"));
    }

    #[test]
    fn selected_health_focus_uses_full_paths_and_keeps_ambiguous_paths_unknown() {
        let fixture = Fixture::new();
        let writer = json!({"id":"mission-901","projectPath":"P:/p","agent":"claude",
            "mode":"shared","purpose":"writer","workspaceAfter":{
                "changedFileNames":["packages/a/index.ts"],"changedFiles":1}});
        let check = json!({"id":"mission-902","projectPath":"P:/p","agent":"codex",
            "mode":"blind","purpose":"validator","sourceMissionId":"mission-901",
            "findings":{"findings":[
                {"title":"Actual changed path","detail":"d","file":"P:/p/packages/a/index.ts"},
                {"title":"Same basename elsewhere","detail":"d","file":"packages/b/index.ts"},
                {"title":"Outside project","detail":"d","file":"Q:/private/index.ts"},
                {"title":"Traversal","detail":"d","file":"../other/index.ts"}]}});
        for (id, value) in [("mission-901", writer), ("mission-902", check)] {
            fs::write(
                fixture.0.join("missions").join(format!("{id}.json")),
                serde_json::to_vec(&value).unwrap(),
            )
            .unwrap();
        }
        let dataset = dataset_in(&fixture.0, "P:/p".into()).unwrap();
        let by = |scope| {
            dataset
                .focus
                .iter()
                .find(|item| item.scope == scope)
                .map(|item| item.counts.total)
        };
        assert_eq!(by("changed"), Some(1));
        assert_eq!(by("neighbour"), Some(1));
        assert_eq!(by("unknown"), Some(2));
    }

    #[test]
    fn selected_health_model_groups_normalize_known_transport_but_preserve_raw_provenance() {
        let fixture = Fixture::new();
        for (id, model) in [
            ("mission-1", "qwen3.5:397b"),
            ("mission-2", "ollama-cloud/qwen3.5:397b"),
        ] {
            fixture.mission(id, "P:/repo");
            let path = fixture.0.join("missions").join(format!("{id}.json"));
            let mut value: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
            value["resolvedModel"] = Value::from(model);
            fs::write(path, serde_json::to_vec(&value).unwrap()).unwrap();
        }
        let dataset = dataset_in(&fixture.0, "P:/repo".into()).unwrap();
        assert_eq!(dataset.groups.len(), 1);
        assert_eq!(dataset.groups[0].model, "qwen3.5:397b");
        assert_eq!(dataset.groups[0].counts.total, 2);
        assert!(dataset
            .cases
            .iter()
            .any(|case| case.seed.provenance["resolvedModel"] == "ollama-cloud/qwen3.5:397b"));
    }

    #[test]
    fn legacy_synthetic_model_is_not_counted_as_an_observed_model() {
        let fixture = Fixture::new();
        fixture.mission("mission-1", "P:/repo");
        let path = fixture.0.join("missions/mission-1.json");
        let mut value: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        value["resolvedModel"] = Value::from("<synthetic>");
        value["modelSource"] = Value::from("observed");
        fs::write(path, serde_json::to_vec(&value).unwrap()).unwrap();
        let dataset = dataset_in(&fixture.0, "P:/repo".into()).unwrap();
        assert_eq!(dataset.groups[0].model, "requested-model");
        assert_eq!(dataset.groups[0].model_source, "requestedOnly");
        assert_eq!(
            dataset.cases[0].seed.provenance["resolvedModel"], "<synthetic>",
            "preserve the raw historical source, do not silently rewrite it"
        );
    }
    #[test]
    fn denominator_excludes_partial_unresolved_unreviewed_and_later_discoveries() {
        let fixture = Fixture::new();
        for n in 1..=5 {
            fixture.mission(&format!("mission-{n}"), "P:/repo");
        }
        for (n, verdict) in [
            (1, "confirmed"),
            (2, "falsePositive"),
            (3, "partial"),
            (4, "unresolved"),
        ] {
            save_in(&fixture.0, request(&format!("mission-{n}"), 0, verdict)).unwrap();
        }
        later_in(
            &fixture.0,
            LaterRequest {
                project_path: "P:/repo".into(),
                source_mission_id: None,
                title: "Later".into(),
                detail: "Reproduced later".into(),
                file: None,
                evidence: "Failing test".into(),
            },
        )
        .unwrap();
        let dataset = dataset_in(&fixture.0, "P:/repo".into()).unwrap();
        assert_eq!(dataset.summary.total, 6);
        assert_eq!(dataset.summary.adjudicated, 2);
        assert_eq!(dataset.summary.confirmed_rate, Some(0.5));
        assert_eq!(dataset.summary.partial, 1);
        assert_eq!(dataset.summary.unresolved, 1);
        assert_eq!(dataset.summary.unreviewed, 1);
        assert_eq!(dataset.summary.later_discovered, 1);
        assert_eq!(dataset.groups[0].counts.total, 5);
    }
    #[test]
    fn cross_project_sources_and_changed_originals_are_rejected() {
        let fixture = Fixture::new();
        fixture.mission("mission-1", "P:/repo");
        fixture.mission("mission-2", "P:/other");
        assert!(later_in(
            &fixture.0,
            LaterRequest {
                project_path: "P:/repo".into(),
                source_mission_id: Some("mission-2".into()),
                title: "Later".into(),
                detail: "d".into(),
                file: None,
                evidence: "test".into()
            }
        )
        .is_err());
        save_in(&fixture.0, request("mission-1", 0, "confirmed")).unwrap();
        let path = fixture.0.join("missions/mission-1.json");
        let mut value: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        value["findings"]["findings"][0]["title"] = json!("Other bug");
        fs::write(path, serde_json::to_vec(&value).unwrap()).unwrap();
        assert!(finding_cases_in(&fixture.0, "mission-1").is_err());
    }
    #[test]
    fn unknown_model_and_empty_denominator_are_not_invented() {
        let mut counts = Counts::default();
        let fixture = Fixture::new();
        fixture.mission("mission-1", "P:/repo");
        let case = finding_cases_in(&fixture.0, "mission-1")
            .unwrap()
            .cases
            .remove(0);
        add_count(&mut counts, &case);
        assert_eq!(counts.confirmed_rate, None);
        let path = fixture.0.join("missions/mission-1.json");
        let mut value: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        value["model"] = Value::Null;
        value["resolvedModel"] = Value::Null;
        fs::write(path, serde_json::to_vec(&value).unwrap()).unwrap();
        let dataset = dataset_in(&fixture.0, "P:/repo".into()).unwrap();
        assert_eq!(dataset.groups[0].model, "unknown");
        assert_eq!(dataset.groups[0].model_source, "unknown");
    }
    #[test]
    fn writes_fail_when_store_is_a_file_and_path_traversal_is_rejected() {
        let fixture = Fixture::new();
        fixture.mission("mission-1", "P:/repo");
        fs::write(fixture.0.join("missions/evaluations"), "preserve").unwrap();
        assert!(save_in(&fixture.0, request("mission-1", 0, "confirmed")).is_err());
        assert!(finding_cases_in(&fixture.0, "../../secret").is_err());
    }

    #[test]
    fn canonical_windows_drive_and_unc_paths_match_without_collapsing_nested_projects() {
        assert_eq!(
            project_key(r"\\?\P:\Dropbox\repo").unwrap(),
            project_key(r"P:\Dropbox\repo\").unwrap()
        );
        assert_eq!(
            project_key(r"\\?\UNC\server\share\repo").unwrap(),
            project_key(r"\\server\share\repo").unwrap()
        );
        assert_ne!(
            project_key(r"P:\repo").unwrap(),
            project_key(r"P:\repo\nested").unwrap()
        );
        let fixture = Fixture::new();
        fixture.mission("mission-1", r"\\?\P:\repo");
        assert_eq!(
            dataset_in(&fixture.0, "P:/repo".into())
                .unwrap()
                .cases
                .len(),
            1
        );
    }

    #[test]
    fn usefulness_is_optional_independent_and_never_inherited_from_a_repeat() {
        let fixture = Fixture::new();
        fixture.mission("mission-1", "P:/repo");
        fixture.mission("mission-2", "P:/repo");
        let mut rating = request("mission-1", 0, "unreviewed");
        rating.evidence.clear();
        rating.usefulness = Some(10);
        let saved = save_in(&fixture.0, rating).unwrap();
        assert_eq!(saved.verdict, "unreviewed");
        assert_eq!(saved.usefulness, Some(10));
        let dataset = dataset_in(&fixture.0, "P:/repo".into()).unwrap();
        assert_eq!(dataset.summary.usefulness_rated, 1);
        assert_eq!(dataset.summary.usefulness_average, Some(10.0));
        assert_eq!(dataset.summary.confirmed_rate, None);
        assert_eq!(
            finding_cases_in(&fixture.0, "mission-2").unwrap().cases[0].usefulness,
            None
        );
        for score in [0, 11, 255] {
            let mut bad = request("mission-1", 1, "unreviewed");
            bad.usefulness = Some(score);
            assert!(save_in(&fixture.0, bad).is_err());
        }
        let cleared = save_in(&fixture.0, request("mission-1", 1, "unreviewed")).unwrap();
        assert_eq!(cleared.usefulness, None);
        assert_eq!(cleared.history[0].usefulness, Some(10));
        assert_eq!(
            dataset_in(&fixture.0, "P:/repo".into())
                .unwrap()
                .summary
                .usefulness_average,
            None
        );
    }

    #[test]
    fn later_discoveries_begin_unresolved_and_never_boost_validator_metrics() {
        let fixture = Fixture::new();
        let case = later_in(
            &fixture.0,
            LaterRequest {
                project_path: "P:/repo".into(),
                source_mission_id: None,
                title: "Later bug".into(),
                detail: "Reproduction".into(),
                file: None,
                evidence: "A regression fails".into(),
            },
        )
        .unwrap();
        assert_eq!(case.verdict, "unresolved");
        let mut update = request("mission-1", 1, "confirmed");
        update.mission_id = None;
        update.finding_index = None;
        update.case_id = Some(case.seed.id);
        update.usefulness = Some(10);
        update.actionability = Some(10);
        update.novelty = Some(10);
        save_in(&fixture.0, update).unwrap();
        let dataset = dataset_in(&fixture.0, "P:/repo".into()).unwrap();
        assert!(dataset.groups.is_empty());
        assert_eq!(dataset.summary.later_discovered, 1);
        assert_eq!(dataset.summary.confirmed, 0);
        assert_eq!(dataset.summary.usefulness_rated, 0);
        assert_eq!(dataset.summary.actionability_rated, 0);
        assert_eq!(dataset.summary.novelty_rated, 0);
        assert_eq!(dataset.summary.confirmed_rate, None);
    }

    #[test]
    fn exact_followup_link_keeps_verdict_score_and_refreshes_status_without_rewriting_history() {
        let fixture = Fixture::new();
        fixture.mission("mission-1", "P:/repo");
        let followup = fixture.0.join("missions/mission-2.json");
        fs::write(&followup,serde_json::to_vec(&json!({"id":"mission-2","projectPath":r"\\?\P:\repo","purpose":"writer","agent":"claude","model":"requested","resolvedModel":"actual","status":"running","startedUnixMs":40})).unwrap()).unwrap();
        let mut rating = request("mission-1", 0, "unreviewed");
        rating.evidence.clear();
        rating.usefulness = Some(7);
        rating.actionability = Some(8);
        rating.novelty = Some(2);
        save_in(&fixture.0, rating).unwrap();
        let linked = link_in(
            &fixture.0,
            FollowupRequest {
                mission_id: "mission-1".into(),
                finding_index: 0,
                followup_mission_id: "mission-2".into(),
                deliberation_ms: None,
            },
        )
        .unwrap();
        assert_eq!(linked.revision, 2);
        assert_eq!(linked.verdict, "unreviewed");
        assert_eq!(linked.usefulness, Some(7));
        assert_eq!(linked.actionability, Some(8));
        assert_eq!(linked.novelty, Some(2));
        assert_eq!(linked.history[1].kind, "followupLinked");
        let duplicate = link_in(
            &fixture.0,
            FollowupRequest {
                mission_id: "mission-1".into(),
                finding_index: 0,
                followup_mission_id: "mission-2".into(),
                deliberation_ms: None,
            },
        )
        .unwrap();
        assert_eq!(duplicate.revision, 2);
        let mut updated: Value = serde_json::from_slice(&fs::read(&followup).unwrap()).unwrap();
        updated["status"] = json!("completed");
        updated["finishedUnixMs"] = json!(60);
        fs::write(&followup, serde_json::to_vec(&updated).unwrap()).unwrap();
        let current = finding_cases_in(&fixture.0, "mission-1")
            .unwrap()
            .cases
            .remove(0);
        assert_eq!(current.followups[0]["status"], "completed");
        assert_eq!(current.followups[0]["durationMs"], 20);
        assert_eq!(
            current.history[1].followup.as_ref().unwrap()["status"],
            "running"
        );
        assert_eq!(current.verdict, "unreviewed");
        assert_eq!(current.actionability, Some(8));
        assert_eq!(current.novelty, Some(2));
        assert_eq!(current.history[1].actionability, Some(8));
        assert_eq!(current.history[1].novelty, Some(2));
        assert!(save_in(&fixture.0, request("mission-1", 1, "confirmed")).is_err());
        updated["projectPath"] = json!("P:/other");
        fs::write(&followup, serde_json::to_vec(&updated).unwrap()).unwrap();
        assert!(finding_cases_in(&fixture.0, "mission-1").is_err());
    }

    #[test]
    fn orphaned_source_keeps_the_assessment_and_metadata_snapshot() {
        let fixture = Fixture::new();
        fixture.mission("mission-1", "P:/repo");
        let case = save_in(&fixture.0, request("mission-1", 0, "confirmed")).unwrap();
        fs::remove_file(fixture.0.join("missions/mission-1.json")).unwrap();
        let dataset = dataset_in(&fixture.0, "P:/repo".into()).unwrap();
        assert_eq!(dataset.cases.len(), 1);
        assert_eq!(
            dataset.cases[0].seed.provenance["resolvedModel"],
            "actual-model"
        );
        let mut update = request("mission-1", 1, "partial");
        update.mission_id = None;
        update.finding_index = None;
        update.case_id = Some(case.seed.id);
        assert_eq!(save_in(&fixture.0, update).unwrap().revision, 2);
    }

    #[test]
    fn checkpoint_source_references_use_the_real_summary_shape() {
        let fixture = Fixture::new();
        fixture.mission("mission-1", "P:/repo");
        fixture.mission("mission-2", "P:/repo");
        let source_path = fixture.0.join("missions/mission-2.json");
        let mut source: Value = serde_json::from_slice(&fs::read(&source_path).unwrap()).unwrap();
        source["checkpoint"] = json!({"directory":"P:/toolkit/missions/checkpoints/mission-2","mode":"checkpoint","complete":false,"fileCount":3,"totalBytes":80,"skippedFiles":1,"changedFiles":1,"warning":"one binary omitted"});
        fs::write(source_path, serde_json::to_vec(&source).unwrap()).unwrap();
        let path = fixture.0.join("missions/mission-1.json");
        let mut value: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        value["sourceMissionId"] = json!("mission-2");
        fs::write(path, serde_json::to_vec(&value).unwrap()).unwrap();
        let case = finding_cases_in(&fixture.0, "mission-1")
            .unwrap()
            .cases
            .remove(0);
        assert_eq!(
            case.seed.provenance["sourceCheckpoint"]["directory"],
            "P:/toolkit/missions/checkpoints/mission-2"
        );
        assert_eq!(case.seed.provenance["sourceCheckpoint"]["fileCount"], 3);
        assert_eq!(case.seed.provenance["sourceCheckpoint"]["complete"], false);
    }

    #[test]
    fn revision_gaps_conflicts_and_reordered_history_fail_loudly() {
        let fixture = Fixture::new();
        fixture.mission("mission-1", "P:/repo");
        let case = save_in(&fixture.0, request("mission-1", 0, "confirmed")).unwrap();
        let directory = root(&fixture.0, false).unwrap().join(digest(&case.seed.id));
        let first = directory.join("revision-00000000000000000001.json");
        let conflict = directory.join("revision-00000000000000000001 conflicted copy.json");
        fs::copy(&first, &conflict).unwrap();
        assert!(finding_cases_in(&fixture.0, "mission-1").is_err());
        fs::remove_file(conflict).unwrap();
        fs::rename(first, directory.join("revision-00000000000000000002.json")).unwrap();
        assert!(finding_cases_in(&fixture.0, "mission-1").is_err());
    }

    #[test]
    fn late_mission_persistence_preserves_the_original_finding_occurrences() {
        let fixture = Fixture::new();
        fixture.mission("mission-1", "P:/repo");
        let mut mission = super::super::polling_tests::sample_mission();
        mission.id = "mission-1".into();
        mission.project_path = "P:/repo".into();
        mission.status = "completed".into();
        super::super::persist_completed_mission_in(&fixture.0.join("missions"), &mission).unwrap();
        let case = finding_cases_in(&fixture.0, "mission-1")
            .unwrap()
            .cases
            .remove(0);
        assert_eq!(case.seed.title, "Null bug");
        assert_eq!(case.seed.finding_index, Some(0));
    }

    #[test]
    fn all_three_rating_dimensions_persist_with_separate_unrated_denominators() {
        let fixture = Fixture::new();
        for index in 1..=4 {
            fixture.mission(&format!("mission-{index}"), "P:/repo");
        }
        let mut first = request("mission-1", 0, "partial");
        first.usefulness = Some(8);
        first.actionability = Some(10);
        first.novelty = Some(4);
        save_in(&fixture.0, first).unwrap();
        let mut second = request("mission-2", 0, "unreviewed");
        second.evidence.clear();
        second.actionability = Some(2);
        save_in(&fixture.0, second).unwrap();
        let mut third = request("mission-3", 0, "falsePositive");
        third.novelty = Some(10);
        save_in(&fixture.0, third).unwrap();
        let stored = finding_cases_in(&fixture.0, "mission-1")
            .unwrap()
            .cases
            .remove(0);
        assert_eq!(
            (stored.usefulness, stored.actionability, stored.novelty),
            (Some(8), Some(10), Some(4))
        );
        assert_eq!(
            (
                stored.history[0].usefulness,
                stored.history[0].actionability,
                stored.history[0].novelty
            ),
            (Some(8), Some(10), Some(4))
        );
        let dataset = dataset_in(&fixture.0, "P:/repo".into()).unwrap();
        assert_eq!(
            (
                dataset.summary.usefulness_rated,
                dataset.summary.usefulness_average
            ),
            (1, Some(8.0))
        );
        assert_eq!(
            (
                dataset.summary.actionability_rated,
                dataset.summary.actionability_average
            ),
            (2, Some(6.0))
        );
        assert_eq!(
            (
                dataset.summary.novelty_rated,
                dataset.summary.novelty_average
            ),
            (2, Some(7.0))
        );
        assert_eq!(dataset.groups[0].counts.actionability_average, Some(6.0));
        assert_eq!(dataset.groups[0].counts.novelty_average, Some(7.0));
        assert_eq!(dataset.summary.adjudicated, 1);
        assert_eq!(dataset.summary.partial, 1);
        assert_eq!(dataset.summary.unreviewed, 2);
        let unrated = finding_cases_in(&fixture.0, "mission-4")
            .unwrap()
            .cases
            .remove(0);
        assert_eq!(
            (unrated.usefulness, unrated.actionability, unrated.novelty),
            (None, None, None)
        );
    }

    #[test]
    fn legacy_records_without_ratings_remain_unrated_and_all_score_fields_are_bounded() {
        let fixture = Fixture::new();
        fixture.mission("mission-1", "P:/repo");
        let initial = save_in(&fixture.0, request("mission-1", 0, "unresolved")).unwrap();
        let path = root(&fixture.0, false)
            .unwrap()
            .join(digest(&initial.seed.id))
            .join("revision-00000000000000000001.json");
        let mut record: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        let event = record["event"].as_object_mut().unwrap();
        for field in ["usefulness", "actionability", "novelty"] {
            event.remove(field);
        }
        fs::write(&path, serde_json::to_vec(&record).unwrap()).unwrap();
        let legacy = finding_cases_in(&fixture.0, "mission-1")
            .unwrap()
            .cases
            .remove(0);
        assert_eq!(
            (legacy.usefulness, legacy.actionability, legacy.novelty),
            (None, None, None)
        );
        let dataset = dataset_in(&fixture.0, "P:/repo".into()).unwrap();
        assert_eq!(
            (
                dataset.summary.usefulness_average,
                dataset.summary.actionability_average,
                dataset.summary.novelty_average
            ),
            (None, None, None)
        );
        for field in ["actionability", "novelty"] {
            for score in [0, 11, 255] {
                let mut invalid = request("mission-1", 1, "unresolved");
                if field == "actionability" {
                    invalid.actionability = Some(score);
                } else {
                    invalid.novelty = Some(score);
                }
                assert!(save_in(&fixture.0, invalid).is_err());
            }
            for score in [json!(-1), json!(1.5), json!("8"), json!(true), json!(256)] {
                let mut invalid = json!({"missionId":"mission-1","findingIndex":0,"expectedRevision":1,"verdict":"unresolved","remediation":"open","evidence":""});
                invalid[field] = score;
                assert!(serde_json::from_value::<SaveRequest>(invalid).is_err());
            }
        }
        assert_eq!(
            finding_cases_in(&fixture.0, "mission-1").unwrap().cases[0].revision,
            1
        );
    }

    #[test]
    fn metadata_index_drops_raw_text_and_invalidates_modified_records() {
        let fixture = Fixture::new();
        fixture.mission("mission-1", "P:/repo");
        let path = fixture.0.join("missions/mission-1.json");
        let mut budget = MAX_SCAN_BYTES;
        let initial = read_indexed_mission(&path, &mut budget).unwrap();
        assert!(initial.get("prompt").is_none());
        assert!(initial.get("output").is_none());
        assert!(initial["workspaceBefore"].get("diff").is_none());
        let cached = read_indexed_mission(&path, &mut budget).unwrap();
        assert_eq!(cached, initial);
        let mut raw: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        raw["modelSource"] = json!("observed");
        fs::write(&path, serde_json::to_vec(&raw).unwrap()).unwrap();
        let changed = read_indexed_mission(&path, &mut budget).unwrap();
        assert_eq!(changed["modelSource"], "observed");
        fs::write(&path, "{broken").unwrap();
        assert!(read_indexed_mission(&path, &mut budget).is_err());
    }

    #[test]
    fn observed_and_legacy_models_are_never_grouped_as_equal_evidence() {
        let fixture = Fixture::new();
        fixture.mission("mission-1", "P:/repo");
        let legacy = dataset_in(&fixture.0, "P:/repo".into()).unwrap();
        assert_eq!(legacy.groups[0].model_source, "legacyUnverified");
        let path = fixture.0.join("missions/mission-1.json");
        let mut raw: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        raw["modelSource"] = json!("observed");
        fs::write(&path, serde_json::to_vec(&raw).unwrap()).unwrap();
        assert_eq!(
            dataset_in(&fixture.0, "P:/repo".into()).unwrap().groups[0].model_source,
            "observed"
        );
        save_in(&fixture.0, request("mission-1", 0, "confirmed")).unwrap();
        assert_eq!(
            dataset_in(&fixture.0, "P:/repo".into()).unwrap().cases[0].revision,
            1
        );
    }

    #[test]
    fn unrelated_project_history_does_not_block_selected_register() {
        let fixture = Fixture::new();
        fixture.mission("mission-1", "P:/repo");
        fixture.mission("mission-2", "P:/other");
        save_in(&fixture.0, request("mission-2", 0, "confirmed")).unwrap();
        let other = root(&fixture.0, false)
            .unwrap()
            .join(digest(&case_id("mission-2", 0)));
        fs::write(other.join("revision-00000000000000000002.json"), "invalid").unwrap();
        assert_eq!(
            dataset_in(&fixture.0, "P:/repo".into())
                .unwrap()
                .cases
                .len(),
            1
        );
        assert!(dataset_in(&fixture.0, "P:/other".into()).is_err());
    }

    #[test]
    fn dataset_read_releases_write_lock_and_retries_a_changed_snapshot() {
        let mut attempts = 0;
        let result = consistent_read(|| {
            attempts += 1;
            let _guard = STORE_LOCK
                .try_lock()
                .expect("reading must not retain the write lock");
            if attempts == 1 {
                STORE_REVISION.fetch_add(1, Ordering::SeqCst);
            }
            Ok(attempts)
        })
        .unwrap();
        assert_eq!(result, 2);
    }

    #[test]
    #[ignore = "Read-only smoke test against the operator-selected real project; no live writes"]
    fn live_evaluation_dataset_read_only_smoke() {
        let home = super::super::resolve_agentsync_home().unwrap();
        let project = std::env::var("EVALUATION_SMOKE_PROJECT")
            .unwrap_or_else(|_| super::super::path_text(&home));
        for sample in 1..=3 {
            let timer = std::time::Instant::now();
            let dataset = dataset_in(&home, project.clone()).unwrap();
            println!("Read-only sample {sample}: {} ms, {} cases, {} validator groups, {} unreviewed, {} user-reviewed; no files written",timer.elapsed().as_millis(),dataset.cases.len(),dataset.groups.len(),dataset.summary.unreviewed,dataset.summary.adjudicated);
        }
    }
}
