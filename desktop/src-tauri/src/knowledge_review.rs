//! Review-only bridge for locally exported AgentSync metadata proposals.
//!
//! The trusted boundary is deliberately narrow:
//! - the desktop never opens the proposal SQLite database;
//! - it only reads canonical, content-addressed JSON views from the fixed lab path;
//! - user decisions are separate, append-only records under `missions`;
//! - an "approved" decision is local review state, never publication authority.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

const VIEW_TYPE: &str = "MetadataProposalReviewViewV1";
const REVIEW_TYPE: &str = "MetadataProposalReviewV1";
const MAX_VIEW_FILES: usize = 2_000;
const MAX_PROJECT_ITEMS: usize = 200;
const MAX_VIEW_BYTES: u64 = 512 * 1024;
const MAX_VIEW_SCAN_BYTES: u64 = 64 * 1024 * 1024;
const MAX_DECISION_BYTES: u64 = 256 * 1024;
const MAX_DECISION_SCAN_BYTES: u64 = 8 * 1024 * 1024;
const MAX_DECISION_REVISIONS: usize = 500;
const MAX_DECISION_DIRECTORY_ENTRIES: usize = 1_000;
const MAX_EDITED_MARKDOWN_BYTES: usize = 128 * 1024;
const MAX_NOTE_CHARS: usize = 4_000;
const MAX_PROJECT_PATH_CHARS: usize = 1_024;
const MAX_SOURCES: usize = 101;
const MAX_RESULT_CHARS: usize = 8_000;
const MAX_RESULT_WORDS: usize = 150;
const REVIEW_SEED: u64 = 24_051_974;
const REVIEW_NUM_CTX: u64 = 32_768;
const REVIEW_MAX_PREDICT: u64 = 4_096;

static DECISION_WRITE_LOCK: Mutex<()> = Mutex::new(());

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct KnowledgeReviewRequest {
    pub project_path: String,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct SaveKnowledgeReviewDecisionRequest {
    pub project_path: String,
    pub review_id: String,
    pub view_id: String,
    pub expected_revision: u64,
    pub status: String,
    pub edited_markdown: String,
    #[serde(default)]
    pub note: String,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct KnowledgeReviewPayload {
    project_path: String,
    source_available: bool,
    warning: Option<String>,
    items: Vec<KnowledgeReviewItem>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct KnowledgeReviewItem {
    review_id: String,
    view_id: String,
    proposal_id: String,
    page_id: String,
    generated_utc: String,
    model_tag: String,
    model_digest: String,
    result_markdown: String,
    rationale: String,
    preserved_sources: Vec<KnowledgeReviewSource>,
    discarded_sources: Vec<KnowledgeReviewSource>,
    human_review_required: bool,
    semantic_correctness_verified: bool,
    decision: KnowledgeReviewDecision,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct KnowledgeReviewSource {
    #[serde(rename = "ref")]
    reference: String,
    kind: String,
    observed_at: String,
    why: String,
    reason_code: Option<String>,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct KnowledgeReviewDecision {
    revision: u64,
    status: String,
    edited_markdown: String,
    note: String,
    at_unix_ms: Option<u64>,
    conflict: bool,
}

#[derive(Clone)]
struct ParsedView {
    review_id: String,
    view_id: String,
    proposal_id: String,
    project_path: String,
    page_id: String,
    generated_utc: String,
    model_tag: String,
    model_digest: String,
    result_markdown: String,
    rationale: String,
    preserved_sources: Vec<KnowledgeReviewSource>,
    discarded_sources: Vec<KnowledgeReviewSource>,
    human_review_required: bool,
    semantic_correctness_verified: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct DecisionSeed {
    review_id: String,
    view_id: String,
    proposal_id: String,
    project_path: String,
    page_id: String,
    source_markdown_sha256: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct DecisionEvent {
    revision: u64,
    previous_event_sha256: Option<String>,
    status: String,
    edited_markdown: String,
    note: String,
    at_unix_ms: u64,
    origin: String,
    publish_authorized: bool,
    published: bool,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct DecisionRecord {
    schema_version: u32,
    seed: DecisionSeed,
    event: DecisionEvent,
}

struct LoadedDecision {
    decision: KnowledgeReviewDecision,
    latest_event_sha256: Option<String>,
}

fn sha256(value: &[u8]) -> String {
    format!("{:x}", Sha256::digest(value))
}

fn canonical_json(value: &Value) -> Result<Vec<u8>, String> {
    serde_json::to_vec(value).map_err(|error| format!("JSON kunne ikke serialiseres: {error}"))
}

fn canonical_windows_project_path(value: &str) -> Result<String, String> {
    let path = value.trim();
    if path.is_empty()
        || path.chars().count() > MAX_PROJECT_PATH_CHARS
        || path
            .chars()
            .any(|character| character <= '\u{1f}' || character == '\u{7f}')
    {
        return Err("Prosjektstien er tom, for lang eller inneholder kontrolltegn.".into());
    }

    let path = path.replace('/', "\\");
    let raw_parts: Vec<&str> = path.split('\\').collect();
    if raw_parts.iter().any(|part| matches!(*part, "." | "..")) {
        return Err("Prosjektstien inneholder punkttraversering.".into());
    }

    let normalized = if path.as_bytes().get(1) == Some(&b':')
        && path.as_bytes().first().is_some_and(u8::is_ascii_alphabetic)
        && path.as_bytes().get(2) == Some(&b'\\')
    {
        let drive = &path[..2];
        let parts: Vec<&str> = path[3..]
            .split('\\')
            .filter(|part| !part.is_empty())
            .collect();
        if parts.is_empty() {
            format!("{drive}\\")
        } else {
            format!("{drive}\\{}", parts.join("\\"))
        }
    } else if let Some(rest) = path.strip_prefix("\\\\") {
        if rest.starts_with('?') || rest.starts_with('.') {
            return Err("Utvidede Windows-enhetsstier er ikke gyldige prosjektstier.".into());
        }
        let mut parts: Vec<&str> = rest.split('\\').collect();
        while parts.last() == Some(&"") {
            parts.pop();
        }
        if parts.len() < 2 || parts.iter().any(|part| part.is_empty()) {
            return Err("UNC-prosjektstien må inneholde server og delt mappe.".into());
        }
        format!("\\\\{}", parts.join("\\"))
    } else {
        return Err("Prosjektstien må være en absolutt Windows drive- eller UNC-sti.".into());
    };

    let mut folded = String::with_capacity(normalized.len());
    for character in normalized.chars() {
        if character.is_ascii() {
            folded.push(character.to_ascii_lowercase());
        } else if matches!(character, '\u{00b5}' | '\u{00df}') {
            return Err("Prosjektstien inneholder tegn som ikke kan kanoniseres sikkert.".into());
        } else if character.is_alphabetic()
            && !(('\u{00c0}'..='\u{00d6}').contains(&character)
                || ('\u{00d8}'..='\u{00f6}').contains(&character)
                || ('\u{00f8}'..='\u{00ff}').contains(&character))
        {
            return Err(
                "Prosjektstien inneholder bokstaver som ikke kan kanoniseres sikkert.".into(),
            );
        } else {
            folded.extend(character.to_lowercase());
        }
    }
    Ok(folded)
}

fn valid_iso_datetime(value: &str) -> bool {
    fn digits(value: &[u8]) -> Option<u32> {
        value.iter().all(u8::is_ascii_digit).then(|| {
            value
                .iter()
                .fold(0, |number, digit| number * 10 + u32::from(digit - b'0'))
        })
    }

    let bytes = value.as_bytes();
    if bytes.len() < 20
        || bytes.get(4) != Some(&b'-')
        || bytes.get(7) != Some(&b'-')
        || bytes.get(10) != Some(&b'T')
        || bytes.get(13) != Some(&b':')
        || bytes.get(16) != Some(&b':')
    {
        return false;
    }
    let (Some(year), Some(month), Some(day), Some(hour), Some(minute), Some(second)) = (
        digits(&bytes[0..4]),
        digits(&bytes[5..7]),
        digits(&bytes[8..10]),
        digits(&bytes[11..13]),
        digits(&bytes[14..16]),
        digits(&bytes[17..19]),
    ) else {
        return false;
    };
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    let max_day = match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if leap => 29,
        2 => 28,
        _ => return false,
    };
    if day == 0 || day > max_day || hour > 23 || minute > 59 || second > 59 {
        return false;
    }
    let mut cursor = 19;
    if bytes.get(cursor) == Some(&b'.') {
        cursor += 1;
        let start = cursor;
        while bytes.get(cursor).is_some_and(u8::is_ascii_digit) {
            cursor += 1;
        }
        if cursor == start {
            return false;
        }
    }
    if matches!(bytes.get(cursor), Some(b'Z' | b'z')) {
        return cursor + 1 == bytes.len();
    }
    if !matches!(bytes.get(cursor), Some(b'+' | b'-')) || cursor + 6 != bytes.len() {
        return false;
    }
    bytes.get(cursor + 3) == Some(&b':')
        && digits(&bytes[cursor + 1..cursor + 3]).is_some_and(|hours| hours <= 23)
        && digits(&bytes[cursor + 4..cursor + 6]).is_some_and(|minutes| minutes <= 59)
}

fn exact_object<'a>(
    value: &'a Value,
    keys: &[&str],
    label: &str,
) -> Result<&'a Map<String, Value>, String> {
    let object = value
        .as_object()
        .ok_or_else(|| format!("{label} er ikke et JSON-objekt."))?;
    let actual: BTreeSet<&str> = object.keys().map(String::as_str).collect();
    let expected: BTreeSet<&str> = keys.iter().copied().collect();
    if actual != expected {
        return Err(format!("{label} har ukjente eller manglende felt."));
    }
    Ok(object)
}

fn required_text<'a>(
    object: &'a Map<String, Value>,
    key: &str,
    label: &str,
    max: usize,
) -> Result<&'a str, String> {
    let value = object
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("{label}.{key} mangler tekst."))?;
    if value.is_empty()
        || value.chars().count() > max
        || value
            .chars()
            .any(|c| c == '\0' || (c.is_control() && c != '\n' && c != '\t' && c != '\r'))
    {
        return Err(format!("{label}.{key} har ugyldig tekst."));
    }
    Ok(value)
}

fn exact_prefixed_hex(value: &str, prefix: &str, digits: usize) -> bool {
    value.strip_prefix(prefix).is_some_and(|suffix| {
        suffix.len() == digits
            && suffix
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
    })
}

fn valid_page_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 512
        && value == value.trim()
        && !value.starts_with('/')
        && !value.ends_with('/')
        && !value.contains("//")
        && !value.contains('\\')
        && !value.to_ascii_lowercase().ends_with(".md")
        && value
            .as_bytes()
            .first()
            .is_some_and(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit())
        && value.split('/').all(|part| {
            !part.is_empty()
                && part != "."
                && part != ".."
                && part.bytes().all(|byte| {
                    byte.is_ascii_lowercase()
                        || byte.is_ascii_digit()
                        || matches!(byte, b'-' | b'_' | b'.')
                })
        })
}

fn checked_directory(path: &Path, create: bool) -> Result<bool, String> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => {
            super::storage_safety::validate_stored_path(path, &metadata, false)?;
            if !metadata.is_dir() {
                return Err(format!(
                    "Kunnskapslageret har en ugyldig mappe: {}",
                    path.display()
                ));
            }
            Ok(true)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound && create => {
            fs::create_dir(path)
                .map_err(|error| format!("Kan ikke opprette {}: {error}", path.display()))?;
            checked_directory(path, false)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(format!("Kan ikke lese {}: {error}", path.display())),
    }
}

fn read_bounded_canonical_json(
    path: &Path,
    per_file_limit: u64,
    budget: &mut u64,
) -> Result<Value, String> {
    let before = fs::symlink_metadata(path)
        .map_err(|error| format!("Kan ikke lese {}: {error}", path.display()))?;
    super::storage_safety::validate_stored_path(path, &before, true)?;
    if !before.is_file() || before.len() > per_file_limit || before.len() > *budget {
        return Err(format!(
            "JSON-visningen er ikke en vanlig fil innenfor lesegrensen: {}",
            path.display()
        ));
    }
    let available_budget = *budget;
    let mut bytes = Vec::new();
    fs::File::open(path)
        .and_then(|file| {
            file.take(per_file_limit.min(*budget) + 1)
                .read_to_end(&mut bytes)
        })
        .map_err(|error| format!("Kan ikke lese {}: {error}", path.display()))?;
    *budget = (*budget).saturating_sub(bytes.len() as u64);
    if bytes.len() as u64 > per_file_limit || bytes.len() as u64 > available_budget {
        return Err(format!(
            "JSON-visningen vokste forbi lesegrensen: {}",
            path.display()
        ));
    }
    let value: Value = serde_json::from_slice(&bytes)
        .map_err(|error| format!("Ugyldig JSON i {}: {error}", path.display()))?;
    if canonical_json(&value)? != bytes {
        return Err(format!(
            "JSON-visningen er ikke kanonisk eller har duplikate felt: {}",
            path.display()
        ));
    }
    let after = fs::metadata(path).map_err(|error| {
        format!(
            "Kan ikke kontrollere {} etter lesing: {error}",
            path.display()
        )
    })?;
    if after.len() != before.len()
        || after.modified().ok() != before.modified().ok()
        || after.created().ok() != before.created().ok()
    {
        return Err(format!(
            "JSON-visningen ble endret under lesingen: {}",
            path.display()
        ));
    }
    Ok(value)
}

fn parse_sources(
    value: &Value,
) -> Result<(BTreeMap<String, KnowledgeReviewSource>, Vec<String>), String> {
    let array = value
        .as_array()
        .ok_or_else(|| "Visningen mangler en kildeliste.".to_string())?;
    if array.is_empty() || array.len() > MAX_SOURCES {
        return Err("Visningens kildeliste er tom eller for stor.".into());
    }
    let mut result = BTreeMap::new();
    let mut order = Vec::with_capacity(array.len());
    for entry in array {
        let source = exact_object(entry, &["ref", "kind", "observed_at", "content"], "Kilde")?;
        let reference = required_text(source, "ref", "Kilde", 160)?.to_string();
        if reference != reference.trim() {
            return Err("En kildereferanse har innledende eller avsluttende mellomrom.".into());
        }
        let kind = required_text(source, "kind", "Kilde", 120)?.to_string();
        let observed_at = required_text(source, "observed_at", "Kilde", 128)?.to_string();
        if !valid_iso_datetime(&observed_at) || !source.get("content").is_some_and(Value::is_object)
        {
            return Err("En kilde har ugyldig tidspunkt eller innhold.".into());
        }
        let item = KnowledgeReviewSource {
            reference: reference.clone(),
            kind,
            observed_at,
            why: String::new(),
            reason_code: None,
        };
        if result.insert(reference.clone(), item).is_some() {
            return Err("Visningen har samme kildereferanse flere ganger.".into());
        }
        order.push(reference);
    }
    Ok((result, order))
}

fn classified_sources(
    value: &Value,
    source_map: &BTreeMap<String, KnowledgeReviewSource>,
    discarded: bool,
) -> Result<Vec<KnowledgeReviewSource>, String> {
    let entries = value
        .as_array()
        .ok_or_else(|| "Reviewet har en ugyldig kildeklassifisering.".to_string())?;
    if entries.len() > source_map.len()
        || (!discarded && entries.len() > 128)
        || (discarded && entries.len() > 256)
    {
        return Err("Reviewet klassifiserer flere kilder enn visningen inneholder.".into());
    }
    let mut result = Vec::new();
    let mut seen = BTreeSet::new();
    for entry in entries {
        let keys: &[&str] = if discarded {
            &["ref", "reason_code", "why"]
        } else {
            &["ref", "why"]
        };
        let object = exact_object(entry, keys, "Kildeklassifisering")?;
        let reference = required_text(object, "ref", "Kildeklassifisering", 160)?;
        let why = required_text(object, "why", "Kildeklassifisering", 500)?;
        if reference != reference.trim() || !(3..=500).contains(&why.trim().chars().count()) {
            return Err("Reviewets kildebegrunnelse er ugyldig.".into());
        }
        let mut source = source_map
            .get(reference)
            .cloned()
            .ok_or_else(|| format!("Reviewet viser til en ukjent kilde: {reference}"))?;
        if !seen.insert(reference.to_string()) {
            return Err(format!(
                "Reviewet klassifiserer kilden flere ganger: {reference}"
            ));
        }
        source.why = why.to_string();
        source.reason_code = discarded
            .then(|| {
                required_text(object, "reason_code", "Kildeklassifisering", 80).map(str::to_string)
            })
            .transpose()?;
        if source.reason_code.as_deref().is_some_and(|code| {
            !matches!(
                code,
                "redundant"
                    | "noise"
                    | "superseded"
                    | "rejected"
                    | "unverified"
                    | "prompt_injection"
                    | "sensitive"
                    | "out_of_scope"
            )
        }) {
            return Err("Reviewet har en ukjent forkastelsesgrunn.".into());
        }
        result.push(source);
    }
    Ok(result)
}

fn validate_review_input(
    value: &Value,
    sources: &BTreeMap<String, KnowledgeReviewSource>,
    source_order: &[String],
) -> Result<(), String> {
    let input = exact_object(
        value,
        &[
            "source_refs",
            "source_manifest",
            "request_sha256",
            "schema_sha256",
            "generation_schema_sha256",
            "system_prompt_sha256",
            "current_page_read",
            "base_content_hash",
            "selection",
        ],
        "Reviewinput",
    )?;
    for key in [
        "request_sha256",
        "schema_sha256",
        "generation_schema_sha256",
        "system_prompt_sha256",
    ] {
        if !exact_prefixed_hex(required_text(input, key, "Reviewinput", 64)?, "", 64) {
            return Err(format!("Reviewinput.{key} er ugyldig."));
        }
    }
    if input.get("current_page_read") != Some(&Value::Bool(false))
        || !input.get("base_content_hash").is_some_and(Value::is_null)
    {
        return Err("Reviewinput hevder lesing eller grunninnhold som ikke er tillatt.".into());
    }

    let refs = input
        .get("source_refs")
        .and_then(Value::as_array)
        .ok_or_else(|| "Reviewinput.source_refs er ugyldig.".to_string())?;
    let input_refs: Option<Vec<&str>> = refs.iter().map(Value::as_str).collect();
    let input_refs = input_refs
        .ok_or_else(|| "Reviewinput.source_refs inneholder ugyldige verdier.".to_string())?;
    if input_refs.len() != source_order.len()
        || input_refs
            .iter()
            .zip(source_order)
            .any(|(left, right)| *left != right)
        || input_refs.iter().any(|reference| reference.is_empty())
    {
        return Err("Reviewinput.source_refs stemmer ikke med de eksporterte kildene.".into());
    }

    let manifest = input
        .get("source_manifest")
        .and_then(Value::as_array)
        .ok_or_else(|| "Reviewinput.source_manifest er ugyldig.".to_string())?;
    if manifest.len() != source_order.len() {
        return Err("Reviewinput.source_manifest har feil antall kilder.".into());
    }
    for (index, item) in manifest.iter().enumerate() {
        let item = exact_object(item, &["ref", "kind", "evidence_pointer"], "Kildemanifest")?;
        let reference = required_text(item, "ref", "Kildemanifest", 160)?;
        let kind = required_text(item, "kind", "Kildemanifest", 120)?;
        let pointer = required_text(item, "evidence_pointer", "Kildemanifest", 512)?;
        if reference != source_order[index]
            || sources.get(reference).map(|source| source.kind.as_str()) != Some(kind)
            || !pointer.starts_with('/')
            || pointer.split('/').any(|part| part == "..")
        {
            return Err("Kildemanifestet stemmer ikke med de eksporterte kildene.".into());
        }
    }

    let selection = exact_object(
        input.get("selection").unwrap_or(&Value::Null),
        &[
            "available_matching_sessions",
            "exact_project_match",
            "included_sessions",
            "max_sessions",
            "max_paths_per_session",
            "max_tools_per_session",
            "truncated",
        ],
        "Reviewutvalg",
    )?;
    let available = selection
        .get("available_matching_sessions")
        .and_then(Value::as_u64)
        .ok_or_else(|| "Reviewutvalget har ugyldig tilgjengelig antall.".to_string())?;
    let included = selection
        .get("included_sessions")
        .and_then(Value::as_u64)
        .ok_or_else(|| "Reviewutvalget har ugyldig inkludert antall.".to_string())?;
    let max_sessions = selection
        .get("max_sessions")
        .and_then(Value::as_u64)
        .ok_or_else(|| "Reviewutvalget har ugyldig sesjonsgrense.".to_string())?;
    if selection.get("exact_project_match") != Some(&Value::Bool(true))
        || selection
            .get("max_paths_per_session")
            .and_then(Value::as_u64)
            != Some(32)
        || selection
            .get("max_tools_per_session")
            .and_then(Value::as_u64)
            != Some(16)
        || !(1..=100).contains(&max_sessions)
        || included != available.min(max_sessions)
        || source_order.len() as u64 != included + 1
        || selection.get("truncated").and_then(Value::as_bool) != Some(available > included)
    {
        return Err("Reviewutvalget stemmer ikke med de eksporterte kildene.".into());
    }
    Ok(())
}

fn validate_review_model(value: &Value) -> Result<(String, String), String> {
    let model = exact_object(
        value,
        &[
            "tag",
            "digest",
            "ollama_version",
            "local_inference_verified",
            "runtime_digest_verified",
            "unload_verified",
            "runtime",
            "seed",
            "temperature",
            "num_ctx",
            "think",
            "max_predict",
        ],
        "Modell",
    )?;
    let tag = required_text(model, "tag", "Modell", 256)?.to_string();
    let digest = required_text(model, "digest", "Modell", 64)?.to_string();
    required_text(model, "ollama_version", "Modell", 128)?;
    if !exact_prefixed_hex(&digest, "", 64)
        || model.get("local_inference_verified") != Some(&Value::Bool(true))
        || model.get("runtime_digest_verified") != Some(&Value::Bool(true))
        || model.get("unload_verified") != Some(&Value::Bool(true))
        || model.get("think") != Some(&Value::Bool(false))
        || model.get("seed").and_then(Value::as_u64) != Some(REVIEW_SEED)
        || model.get("temperature").and_then(Value::as_f64) != Some(0.0)
        || model.get("num_ctx").and_then(Value::as_u64) != Some(REVIEW_NUM_CTX)
        || model.get("max_predict").and_then(Value::as_u64) != Some(REVIEW_MAX_PREDICT)
    {
        return Err("Reviewets modellbevis er ugyldig.".into());
    }

    let runtime = exact_object(
        model.get("runtime").unwrap_or(&Value::Null),
        &[
            "name",
            "model",
            "size",
            "size_vram",
            "digest",
            "context_length",
            "expires_at",
        ],
        "Modellruntime",
    )?;
    let runtime_name = required_text(runtime, "name", "Modellruntime", 256)?;
    let runtime_model = required_text(runtime, "model", "Modellruntime", 256)?;
    let runtime_digest = required_text(runtime, "digest", "Modellruntime", 64)?;
    let size = runtime.get("size").and_then(Value::as_u64);
    let size_vram = runtime.get("size_vram").and_then(Value::as_u64);
    let context_length = runtime.get("context_length").and_then(Value::as_u64);
    let expires_at = required_text(runtime, "expires_at", "Modellruntime", 128)?;
    if runtime_digest != digest
        || (runtime_name != tag && runtime_model != tag)
        || size.is_none()
        || size_vram.is_none()
        || size_vram
            .zip(size)
            .is_some_and(|(vram, total)| vram > total)
        || context_length.is_none_or(|value| value < REVIEW_NUM_CTX)
        || !valid_iso_datetime(expires_at)
    {
        return Err("Reviewets runtimebevis er ugyldig.".into());
    }
    Ok((tag, digest))
}

fn required_guard(guards: &Map<String, Value>, key: &str, expected: bool) -> Result<bool, String> {
    let actual = guards.get(key).and_then(Value::as_bool);
    if actual != Some(expected) {
        return Err(format!("Reviewets sikkerhetsmarkor {key} stemmer ikke."));
    }
    Ok(expected)
}

fn parse_view(path: &Path, budget: &mut u64) -> Result<ParsedView, String> {
    let value = read_bounded_canonical_json(path, MAX_VIEW_BYTES, budget)?;
    let root = exact_object(
        &value,
        &[
            "view_type",
            "view_format_version",
            "view_id",
            "project_path",
            "exported_utc",
            "proposal",
            "review",
            "sources",
        ],
        "Reviewvisning",
    )?;
    if root.get("view_type").and_then(Value::as_str) != Some(VIEW_TYPE)
        || root.get("view_format_version").and_then(Value::as_u64) != Some(1)
    {
        return Err("Reviewvisningen har en ukjent kontrakt.".into());
    }
    let view_id = required_text(root, "view_id", "Reviewvisning", 80)?.to_string();
    if !exact_prefixed_hex(&view_id, "mpv1-", 64) {
        return Err("Reviewvisningen har ugyldig view_id.".into());
    }
    let project_path = required_text(
        root,
        "project_path",
        "Reviewvisning",
        MAX_PROJECT_PATH_CHARS,
    )?
    .to_string();
    super::evaluation::project_key(&project_path)?;
    let canonical_project_path = canonical_windows_project_path(&project_path)?;
    let generated_utc = required_text(root, "exported_utc", "Reviewvisning", 128)?.to_string();
    if !valid_iso_datetime(&generated_utc) {
        return Err("Reviewvisningen har et ugyldig eksporttidspunkt.".into());
    }

    let mut view_body = value.clone();
    view_body
        .as_object_mut()
        .expect("validated object")
        .remove("view_id");
    let view_hash = sha256(&canonical_json(&view_body)?);
    if view_id != format!("mpv1-{view_hash}") {
        return Err("Reviewvisningens innhold stemmer ikke med view_id.".into());
    }

    let proposal = exact_object(
        root.get("proposal").unwrap_or(&Value::Null),
        &[
            "proposal_id",
            "status",
            "bundle_sha256",
            "source_sha256",
            "page_id_hint",
            "owner_key",
            "created_utc",
        ],
        "Forslag",
    )?;
    let proposal_id = required_text(proposal, "proposal_id", "Forslag", 80)?.to_string();
    let bundle_sha256 = required_text(proposal, "bundle_sha256", "Forslag", 64)?;
    if !exact_prefixed_hex(&proposal_id, "eb1-", 64)
        || proposal_id != format!("eb1-{bundle_sha256}")
        || proposal.get("status").and_then(Value::as_str) != Some("pending")
    {
        return Err("Forslaget har ugyldig identitet eller status.".into());
    }
    for key in ["bundle_sha256", "source_sha256"] {
        if !exact_prefixed_hex(required_text(proposal, key, "Forslag", 64)?, "", 64) {
            return Err(format!("Forslagets {key} er ugyldig."));
        }
    }
    let page_id = required_text(proposal, "page_id_hint", "Forslag", 512)?.to_string();
    if !valid_page_id(&page_id) {
        return Err("Forslaget har en utrygg side-ID.".into());
    }
    let owner_key = required_text(proposal, "owner_key", "Forslag", 96)?;
    let expected_owner_key = format!(
        "project-path-v1:{}",
        sha256(canonical_project_path.as_bytes())
    );
    if !exact_prefixed_hex(owner_key, "project-path-v1:", 64) || owner_key != expected_owner_key {
        return Err("Forslaget har ugyldig eieridentitet.".into());
    }
    let proposal_created = required_text(proposal, "created_utc", "Forslag", 128)?;
    if !valid_iso_datetime(proposal_created) {
        return Err("Forslaget har et ugyldig opprettelsestidspunkt.".into());
    }

    let review_value = root.get("review").unwrap_or(&Value::Null);
    let review = exact_object(
        review_value,
        &[
            "created_utc",
            "format_version",
            "generation_id",
            "guards",
            "input",
            "model",
            "proposal",
            "raw_content_sha256",
            "record",
            "review_id",
            "review_type",
            "state",
        ],
        "Review",
    )?;
    if review.get("review_type").and_then(Value::as_str) != Some(REVIEW_TYPE)
        || review.get("format_version").and_then(Value::as_u64) != Some(1)
        || review.get("state").and_then(Value::as_str) != Some("reviewable")
    {
        return Err("Reviewet er ikke et reviewable MetadataProposalReviewV1.".into());
    }
    let generation_id = required_text(review, "generation_id", "Review", 40)?;
    let raw_content_sha256 = required_text(review, "raw_content_sha256", "Review", 64)?;
    let review_created = required_text(review, "created_utc", "Review", 128)?;
    if !exact_prefixed_hex(generation_id, "gen1-", 32)
        || !exact_prefixed_hex(raw_content_sha256, "", 64)
        || !valid_iso_datetime(review_created)
    {
        return Err("Reviewets generasjonsmetadata er ugyldig.".into());
    }
    let review_id = required_text(review, "review_id", "Review", 80)?.to_string();
    if !exact_prefixed_hex(&review_id, "mpr1-", 64) {
        return Err("Reviewet har ugyldig review_id.".into());
    }
    let mut review_body = review_value.clone();
    review_body
        .as_object_mut()
        .expect("validated object")
        .remove("review_id");
    if review_id != format!("mpr1-{}", sha256(&canonical_json(&review_body)?)) {
        return Err("Reviewets innhold stemmer ikke med review_id.".into());
    }

    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("");
    if file_name != format!("{view_id}.json") {
        return Err("Reviewvisningens filnavn stemmer ikke med identitetene.".into());
    }

    let review_proposal = exact_object(
        review.get("proposal").unwrap_or(&Value::Null),
        &[
            "bundle_sha256",
            "candidate_page_id",
            "owner_key",
            "proposal_id",
            "source_sha256",
        ],
        "Reviewforslag",
    )?;
    for (left, right) in [
        ("proposal_id", "proposal_id"),
        ("bundle_sha256", "bundle_sha256"),
        ("source_sha256", "source_sha256"),
        ("owner_key", "owner_key"),
        ("candidate_page_id", "page_id_hint"),
    ] {
        if review_proposal.get(left) != proposal.get(right) {
            return Err(format!("Reviewet og forslaget er uenige om {left}."));
        }
    }

    let (model_tag, model_digest) =
        validate_review_model(review.get("model").unwrap_or(&Value::Null))?;

    let guards = review
        .get("guards")
        .and_then(Value::as_object)
        .ok_or_else(|| "Reviewet mangler sikkerhetsmarkorer.".to_string())?;
    let expected_guard_keys: BTreeSet<&str> = [
        "all_refs_accounted",
        "contract_validated",
        "git_invoked",
        "http_publish_invoked",
        "human_review_required",
        "publish_authorized",
        "published",
        "semantic_correctness_verified",
        "target_owned",
        "wiki_read",
        "wiki_write",
    ]
    .into_iter()
    .collect();
    if guards.keys().map(String::as_str).collect::<BTreeSet<_>>() != expected_guard_keys {
        return Err("Reviewet har ukjente eller manglende sikkerhetsmarkorer.".into());
    }
    required_guard(guards, "all_refs_accounted", true)?;
    required_guard(guards, "contract_validated", true)?;
    required_guard(guards, "target_owned", true)?;
    for key in [
        "git_invoked",
        "http_publish_invoked",
        "publish_authorized",
        "published",
        "semantic_correctness_verified",
        "wiki_read",
        "wiki_write",
    ] {
        required_guard(guards, key, false)?;
    }
    let human_review_required = required_guard(guards, "human_review_required", true)?;
    let semantic_correctness_verified = false;

    let (source_map, source_order) = parse_sources(root.get("sources").unwrap_or(&Value::Null))?;
    validate_review_input(
        review.get("input").unwrap_or(&Value::Null),
        &source_map,
        &source_order,
    )?;
    let record = exact_object(
        review.get("record").unwrap_or(&Value::Null),
        &[
            "decision",
            "target_page_id",
            "result_markdown",
            "rationale",
            "preserved_refs",
            "discarded_refs",
        ],
        "Reviewresultat",
    )?;
    let result_markdown = record
        .get("result_markdown")
        .and_then(Value::as_str)
        .ok_or_else(|| "Reviewet mangler result_markdown.".to_string())?
        .to_string();
    if result_markdown.chars().count() > MAX_RESULT_CHARS
        || result_markdown.as_bytes().len() > MAX_EDITED_MARKDOWN_BYTES
        || result_markdown.split_whitespace().count() > MAX_RESULT_WORDS
    {
        return Err("Reviewets Markdown overskrider lesegrensen.".into());
    }
    let rationale = required_text(record, "rationale", "Reviewresultat", 2_000)?.to_string();
    if !(8..=2_000).contains(&rationale.trim().chars().count()) {
        return Err("Reviewets begrunnelse har ugyldig lengde.".into());
    }
    let decision = record.get("decision").and_then(Value::as_str);
    match decision {
        Some("propose")
            if record.get("target_page_id").and_then(Value::as_str) == Some(&page_id)
                && !result_markdown.trim().is_empty() => {}
        Some("discard")
            if record.get("target_page_id") == Some(&Value::Null) && result_markdown.is_empty() => {
        }
        _ => return Err("Reviewresultatets beslutning og mål stemmer ikke.".into()),
    }
    let preserved_sources = classified_sources(
        record.get("preserved_refs").unwrap_or(&Value::Null),
        &source_map,
        false,
    )?;
    let discarded_sources = classified_sources(
        record.get("discarded_refs").unwrap_or(&Value::Null),
        &source_map,
        true,
    )?;
    let preserved: BTreeSet<&str> = preserved_sources
        .iter()
        .map(|source| source.reference.as_str())
        .collect();
    let discarded: BTreeSet<&str> = discarded_sources
        .iter()
        .map(|source| source.reference.as_str())
        .collect();
    let all: BTreeSet<&str> = source_map.keys().map(String::as_str).collect();
    if !preserved.is_disjoint(&discarded)
        || preserved
            .union(&discarded)
            .copied()
            .collect::<BTreeSet<_>>()
            != all
    {
        return Err("Reviewets kildeklassifisering er ufullstendig eller overlappende.".into());
    }
    if (decision == Some("propose") && preserved_sources.is_empty())
        || (decision == Some("discard") && !preserved_sources.is_empty())
    {
        return Err("Reviewets beslutning stemmer ikke med de bevarte kildene.".into());
    }

    Ok(ParsedView {
        review_id,
        view_id,
        proposal_id,
        project_path,
        page_id,
        generated_utc,
        model_tag,
        model_digest,
        result_markdown,
        rationale,
        preserved_sources,
        discarded_sources,
        human_review_required,
        semantic_correctness_verified,
    })
}

fn review_views_directory(home: &Path) -> PathBuf {
    home.join("inspiration")
        .join("wikikiki")
        .join("labs")
        .join("agentsync_metadata_proposals")
        .join("inbox")
        .join("review-views")
}

fn load_views_with_limits(
    home: &Path,
    scan_budget: u64,
    entry_limit: usize,
) -> Result<(bool, Vec<ParsedView>, Option<String>), String> {
    let directory = review_views_directory(home);
    if !checked_directory(&directory, false)? {
        return Ok((false, Vec::new(), None));
    }
    let entries = fs::read_dir(&directory)
        .map_err(|error| format!("Kan ikke lese reviewvisningene: {error}"))?;
    let mut paths = Vec::new();
    let mut unreadable = 0usize;
    let mut limited = false;
    let mut entries_seen = 0usize;
    for entry in entries {
        if entries_seen >= entry_limit {
            limited = true;
            break;
        }
        entries_seen += 1;
        let Ok(entry) = entry else {
            unreadable += 1;
            continue;
        };
        let path = entry.path();
        if entry.file_type().is_ok_and(|kind| kind.is_file())
            && path.extension().and_then(|extension| extension.to_str()) == Some("json")
        {
            paths.push(path);
        } else {
            unreadable += 1;
        }
    }
    paths.sort();
    let mut budget = scan_budget;
    let mut views = Vec::new();
    for path in paths {
        if budget == 0 {
            limited = true;
            break;
        }
        match parse_view(&path, &mut budget) {
            Ok(view) => views.push(view),
            Err(_) => unreadable += 1,
        }
    }
    let mut warnings = Vec::new();
    if unreadable > 0 {
        warnings.push(format!(
            "{unreadable} reviewvisninger kunne ikke leses trygt. Filene er bevart, men ikke vist."
        ));
    }
    if limited {
        warnings.push("Reviewvisningene nådde lesegrensen. Oversikten er ufullstendig.".into());
    }
    Ok((
        true,
        views,
        (!warnings.is_empty()).then(|| warnings.join(" ")),
    ))
}

fn load_views_with_budget(
    home: &Path,
    scan_budget: u64,
) -> Result<(bool, Vec<ParsedView>, Option<String>), String> {
    load_views_with_limits(home, scan_budget, MAX_VIEW_FILES)
}

fn load_views(home: &Path) -> Result<(bool, Vec<ParsedView>, Option<String>), String> {
    load_views_with_budget(home, MAX_VIEW_SCAN_BYTES)
}

fn decision_seed(view: &ParsedView) -> DecisionSeed {
    DecisionSeed {
        review_id: view.review_id.clone(),
        view_id: view.view_id.clone(),
        proposal_id: view.proposal_id.clone(),
        project_path: view.project_path.clone(),
        page_id: view.page_id.clone(),
        source_markdown_sha256: sha256(view.result_markdown.as_bytes()),
    }
}

fn decisions_root(home: &Path, create: bool) -> Result<PathBuf, String> {
    let missions = home.join("missions");
    checked_directory(&missions, create)?;
    let root = missions.join("knowledge-review-decisions");
    checked_directory(&root, create)?;
    Ok(root)
}

fn decision_directory(root: &Path, review_id: &str) -> PathBuf {
    root.join(sha256(review_id.as_bytes()))
}

fn default_decision(view: &ParsedView, conflict: bool) -> KnowledgeReviewDecision {
    KnowledgeReviewDecision {
        revision: 0,
        status: "unreviewed".into(),
        edited_markdown: view.result_markdown.clone(),
        note: String::new(),
        at_unix_ms: None,
        conflict,
    }
}

fn default_loaded_decision(view: &ParsedView, conflict: bool) -> LoadedDecision {
    LoadedDecision {
        decision: default_decision(view, conflict),
        latest_event_sha256: None,
    }
}

fn decision_event_sha256(event: &DecisionEvent) -> Result<String, String> {
    let value = serde_json::to_value(event)
        .map_err(|error| format!("Beslutningshendelsen kunne ikke serialiseres: {error}"))?;
    Ok(sha256(&canonical_json(&value)?))
}

fn decision_file_identity(name: &str) -> Option<(u64, String)> {
    let body = name.strip_prefix("revision-")?.strip_suffix(".json")?;
    let (revision, event_sha256) = body.split_once("--")?;
    if revision.len() != 20
        || !revision.bytes().all(|byte| byte.is_ascii_digit())
        || !exact_prefixed_hex(event_sha256, "", 64)
    {
        return None;
    }
    Some((revision.parse().ok()?, event_sha256.to_string()))
}

fn valid_decision_text(status: &str, markdown: &str, note: &str) -> Result<(), String> {
    if !matches!(status, "draft" | "approved" | "rejected") {
        return Err("Beslutningen må være draft, approved eller rejected.".into());
    }
    if markdown.as_bytes().len() > MAX_EDITED_MARKDOWN_BYTES
        || markdown.chars().any(|character| character == '\0')
        || note.chars().count() > MAX_NOTE_CHARS
        || note.chars().any(|character| character == '\0')
    {
        return Err("Beslutningsteksten er ugyldig eller overskrider grensen.".into());
    }
    if status == "approved" && markdown.trim().is_empty() {
        return Err("Et lokalt godkjent utkast kan ikke være tomt.".into());
    }
    Ok(())
}

fn load_decision_with_entry_limit(
    home: &Path,
    view: &ParsedView,
    entry_limit: usize,
) -> Result<LoadedDecision, String> {
    let root = decisions_root(home, false)?;
    let directory = decision_directory(&root, &view.review_id);
    if !checked_directory(&directory, false)? {
        return Ok(default_loaded_decision(view, false));
    }
    let mut indexed = BTreeMap::<u64, Vec<(String, PathBuf)>>::new();
    let mut conflict = false;
    let entries = match fs::read_dir(&directory) {
        Ok(entries) => entries,
        Err(_) => return Ok(default_loaded_decision(view, true)),
    };
    let mut event_count = 0usize;
    let mut entries_seen = 0usize;
    for entry in entries {
        if entries_seen >= entry_limit {
            conflict = true;
            break;
        }
        entries_seen += 1;
        let Ok(entry) = entry else {
            conflict = true;
            continue;
        };
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if name.starts_with(".pending-") && name.ends_with(".tmp") {
            if entry.file_type().is_ok_and(|kind| kind.is_file()) {
                continue;
            }
            conflict = true;
            continue;
        }
        let Some((revision, event_sha256)) = decision_file_identity(&name) else {
            conflict = true;
            continue;
        };
        if !entry.file_type().is_ok_and(|kind| kind.is_file()) {
            conflict = true;
            continue;
        }
        indexed
            .entry(revision)
            .or_default()
            .push((event_sha256, entry.path()));
        event_count += 1;
        if event_count > MAX_DECISION_REVISIONS {
            conflict = true;
            break;
        }
    }
    let expected_seed = decision_seed(view);
    let mut latest = default_loaded_decision(view, conflict);
    let mut budget = MAX_DECISION_SCAN_BYTES;
    for (index, (revision, events)) in indexed.iter().enumerate() {
        let expected_revision = index as u64 + 1;
        if *revision != expected_revision || events.len() != 1 || budget == 0 {
            latest.decision.conflict = true;
            break;
        }
        let (file_event_sha256, path) = &events[0];
        let value = match read_bounded_canonical_json(path, MAX_DECISION_BYTES, &mut budget) {
            Ok(value) => value,
            Err(_) => {
                latest.decision.conflict = true;
                break;
            }
        };
        let record: DecisionRecord = match serde_json::from_value(value) {
            Ok(record) => record,
            Err(_) => {
                latest.decision.conflict = true;
                break;
            }
        };
        let event_sha256 = match decision_event_sha256(&record.event) {
            Ok(value) => value,
            Err(_) => {
                latest.decision.conflict = true;
                break;
            }
        };
        if record.schema_version != 1
            || record.seed != expected_seed
            || record.event.revision != expected_revision
            || event_sha256 != *file_event_sha256
            || record.event.previous_event_sha256 != latest.latest_event_sha256
            || record.event.origin != "user"
            || record.event.publish_authorized
            || record.event.published
            || record.event.at_unix_ms == 0
            || valid_decision_text(
                &record.event.status,
                &record.event.edited_markdown,
                &record.event.note,
            )
            .is_err()
        {
            latest.decision.conflict = true;
            break;
        }
        latest = LoadedDecision {
            decision: KnowledgeReviewDecision {
                revision: expected_revision,
                status: record.event.status,
                edited_markdown: record.event.edited_markdown,
                note: record.event.note,
                at_unix_ms: Some(record.event.at_unix_ms),
                conflict: latest.decision.conflict,
            },
            latest_event_sha256: Some(event_sha256),
        };
    }
    Ok(latest)
}

fn load_decision(home: &Path, view: &ParsedView) -> Result<LoadedDecision, String> {
    load_decision_with_entry_limit(home, view, MAX_DECISION_DIRECTORY_ENTRIES)
}

fn item_from_view(home: &Path, view: ParsedView) -> KnowledgeReviewItem {
    let decision = load_decision(home, &view)
        .map(|loaded| loaded.decision)
        .unwrap_or_else(|_| default_decision(&view, true));
    KnowledgeReviewItem {
        review_id: view.review_id,
        view_id: view.view_id,
        proposal_id: view.proposal_id,
        page_id: view.page_id,
        generated_utc: view.generated_utc,
        model_tag: view.model_tag,
        model_digest: view.model_digest,
        result_markdown: view.result_markdown,
        rationale: view.rationale,
        preserved_sources: view.preserved_sources,
        discarded_sources: view.discarded_sources,
        human_review_required: view.human_review_required,
        semantic_correctness_verified: view.semantic_correctness_verified,
        decision,
    }
}

fn get_knowledge_reviews_in(
    home: &Path,
    request: KnowledgeReviewRequest,
) -> Result<KnowledgeReviewPayload, String> {
    let project_key = canonical_windows_project_path(&request.project_path)?;
    let (source_available, views, mut warning) = load_views(home)?;
    let mut matching_views: Vec<_> = views
        .into_iter()
        .filter(|view| {
            canonical_windows_project_path(&view.project_path)
                .ok()
                .as_ref()
                == Some(&project_key)
        })
        .collect();
    matching_views.sort_by(|left, right| {
        right
            .generated_utc
            .cmp(&left.generated_utc)
            .then_with(|| right.review_id.cmp(&left.review_id))
    });
    if matching_views.len() > MAX_PROJECT_ITEMS {
        let hidden = matching_views.len() - MAX_PROJECT_ITEMS;
        matching_views.truncate(MAX_PROJECT_ITEMS);
        let message = format!(
            "{hidden} eldre reviewvisninger er utelatt fra prosjektvisningen. De {MAX_PROJECT_ITEMS} nyeste vises."
        );
        warning = Some(match warning {
            Some(existing) => format!("{existing} {message}"),
            None => message,
        });
    }
    let items = matching_views
        .into_iter()
        .map(|view| item_from_view(home, view))
        .collect();
    Ok(KnowledgeReviewPayload {
        project_path: request.project_path,
        source_available,
        warning,
        items,
    })
}

fn save_knowledge_review_decision_in(
    home: &Path,
    request: SaveKnowledgeReviewDecisionRequest,
) -> Result<KnowledgeReviewDecision, String> {
    valid_decision_text(&request.status, &request.edited_markdown, &request.note)?;
    if !exact_prefixed_hex(&request.review_id, "mpr1-", 64)
        || !exact_prefixed_hex(&request.view_id, "mpv1-", 64)
    {
        return Err("Review- eller visnings-ID er ugyldig.".into());
    }
    let project_key = canonical_windows_project_path(&request.project_path)?;
    let (source_available, views, warning) = load_views(home)?;
    if !source_available {
        return Err("Ingen avledede reviewvisninger finnes ennå.".into());
    }
    let mut matches = views.into_iter().filter(|view| {
        view.review_id == request.review_id
            && view.view_id == request.view_id
            && canonical_windows_project_path(&view.project_path)
                .ok()
                .as_ref()
                == Some(&project_key)
    });
    let view = matches.next().ok_or_else(|| {
        warning.unwrap_or_else(|| {
            "Reviewet finnes ikke i det valgte prosjektets sikre visninger.".into()
        })
    })?;
    if matches.next().is_some() {
        return Err("Reviewidentiteten finnes flere ganger. Ingen beslutning ble lagret.".into());
    }

    let _guard = DECISION_WRITE_LOCK
        .lock()
        .map_err(|_| "Beslutningslageret er opptatt etter en intern feil.".to_string())?;
    let current = load_decision(home, &view)?;
    if current.decision.conflict {
        return Err(
            "Beslutningshistorikken har en konflikt. Ingen eksisterende data er overskrevet."
                .into(),
        );
    }
    if current.decision.revision != request.expected_revision {
        return Err(
            "Beslutningen er endret i mellomtiden. Last den inn på nytt før du lagrer.".into(),
        );
    }
    if current.decision.revision >= MAX_DECISION_REVISIONS as u64 {
        return Err("Beslutningen har nådd revisjonsgrensen. Ingen historikk er slettet.".into());
    }

    let root = decisions_root(home, true)?;
    let directory = decision_directory(&root, &view.review_id);
    checked_directory(&directory, true)?;
    let revision = current.decision.revision + 1;
    let event = DecisionEvent {
        revision,
        previous_event_sha256: current.latest_event_sha256,
        status: request.status,
        edited_markdown: request.edited_markdown,
        note: request.note.trim().to_string(),
        at_unix_ms: super::now_unix_ms(),
        origin: "user".into(),
        publish_authorized: false,
        published: false,
    };
    let event_sha256 = decision_event_sha256(&event)?;
    let value = serde_json::to_value(DecisionRecord {
        schema_version: 1,
        seed: decision_seed(&view),
        event,
    })
    .map_err(|error| format!("Beslutningen kunne ikke serialiseres: {error}"))?;
    let bytes = canonical_json(&value)?;
    if bytes.len() as u64 > MAX_DECISION_BYTES {
        return Err("Beslutningsposten overskrider lagringsgrensen.".into());
    }
    let path = directory.join(format!("revision-{revision:020}--{event_sha256}.json"));
    let pending_path = directory.join(format!(
        ".pending-{revision:020}-{}-{}.tmp",
        std::process::id(),
        super::now_unix_ms()
    ));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&pending_path)
        .map_err(|error| {
            format!(
                "Beslutningen ble ikke lagret. Last inn på nytt; historikken er bevart: {error}"
            )
        })?;
    if let Err(error) = file.write_all(&bytes).and_then(|()| file.sync_all()) {
        drop(file);
        let _ = fs::remove_file(&pending_path);
        return Err(format!(
            "Beslutningen kunne ikke sikres på disk: {error}. Ingen ny revisjon ble publisert i historikken."
        ));
    }
    drop(file);
    if let Err(error) = fs::hard_link(&pending_path, &path) {
        let _ = fs::remove_file(&pending_path);
        return Err(format!(
            "Beslutningen ble ikke lagt atomisk til i historikken. Last inn på nytt; eksisterende data er bevart: {error}"
        ));
    }
    let _ = fs::remove_file(&pending_path);
    let stored = load_decision(home, &view)?;
    if stored.decision.conflict
        || stored.decision.revision != revision
        || stored.latest_event_sha256.as_deref() != Some(&event_sha256)
    {
        return Err(
            "Den lagrede beslutningen kunne ikke bekreftes. Historikken er bevart for kontroll."
                .into(),
        );
    }
    Ok(stored.decision)
}

pub(crate) fn get_knowledge_reviews(
    request: KnowledgeReviewRequest,
) -> Result<KnowledgeReviewPayload, String> {
    get_knowledge_reviews_in(&super::resolve_agentsync_home()?, request)
}

pub(crate) fn save_knowledge_review_decision(
    request: SaveKnowledgeReviewDecisionRequest,
) -> Result<KnowledgeReviewDecision, String> {
    save_knowledge_review_decision_in(&super::resolve_agentsync_home()?, request)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn fixture_home(label: &str) -> PathBuf {
        let home = std::env::temp_dir().join(format!(
            "agentsync-knowledge-review-{label}-{}-{}",
            std::process::id(),
            super::super::now_unix_ms()
        ));
        fs::create_dir(&home).unwrap();
        home
    }

    fn base_review(project_path: &str) -> Value {
        let proposal_id = format!("eb1-{}", "1".repeat(64));
        let owner_key = format!(
            "project-path-v1:{}",
            sha256(
                canonical_windows_project_path(project_path)
                    .unwrap()
                    .as_bytes()
            )
        );
        let mut review = json!({
            "created_utc":"2026-09-14T17:09:48Z",
            "format_version":1,
            "generation_id":format!("gen1-{}", "2".repeat(32)),
            "guards":{
                "all_refs_accounted":true,"contract_validated":true,"git_invoked":false,
                "http_publish_invoked":false,"human_review_required":true,
                "publish_authorized":false,"published":false,
                "semantic_correctness_verified":false,"target_owned":true,
                "wiki_read":false,"wiki_write":false
            },
            "input":{
                "base_content_hash":null,
                "current_page_read":false,
                "generation_schema_sha256":"7".repeat(64),
                "request_sha256":"8".repeat(64),
                "schema_sha256":"9".repeat(64),
                "selection":{
                    "available_matching_sessions":0,"exact_project_match":true,
                    "included_sessions":0,"max_paths_per_session":32,
                    "max_sessions":40,"max_tools_per_session":16,"truncated":false
                },
                "source_manifest":[{
                    "evidence_pointer":"/project","kind":"derived_project_metadata",
                    "ref":"project/summary"
                }],
                "source_refs":["project/summary"],
                "system_prompt_sha256":"a".repeat(64)
            },
            "model":{
                "digest":"3".repeat(64),"local_inference_verified":true,
                "max_predict":4096,"num_ctx":32768,"ollama_version":"0.32.15",
                "runtime":{
                    "context_length":32768,"digest":"3".repeat(64),
                    "expires_at":"2026-09-14T19:10:17.197569354+02:00",
                    "model":"gemma4:31b","name":"gemma4:31b",
                    "size":20_926_064_230u64,"size_vram":20_926_064_230u64
                },
                "runtime_digest_verified":true,"seed":24051974,
                "tag":"gemma4:31b","temperature":0.0,"think":false,
                "unload_verified":true
            },
            "proposal":{
                "bundle_sha256":"1".repeat(64),"candidate_page_id":"projects/test/activity",
                "owner_key":owner_key,
                "proposal_id":proposal_id,"source_sha256":"5".repeat(64)
            },
            "raw_content_sha256":"6".repeat(64),
            "record":{
                "decision":"propose","target_page_id":"projects/test/activity",
                "result_markdown":"## Kort status\n\nEtt bekreftet punkt.",
                "rationale":"Kilden dekker statusen.",
                "preserved_refs":[{"ref":"project/summary","why":"Direkte prosjektmetadata."}],
                "discarded_refs":[]
            },
            "review_type":REVIEW_TYPE,"state":"reviewable"
        });
        let digest = sha256(&canonical_json(&review).unwrap());
        review
            .as_object_mut()
            .unwrap()
            .insert("review_id".into(), Value::String(format!("mpr1-{digest}")));
        review
    }

    fn write_view(home: &Path, project_path: &str) -> (String, String) {
        let review = base_review(project_path);
        let review_id = review["review_id"].as_str().unwrap().to_string();
        let mut view = json!({
            "view_type":VIEW_TYPE,"view_format_version":1,"project_path":project_path,
            "exported_utc":"2026-09-14T17:09:48Z",
            "proposal":{
                "proposal_id":review["proposal"]["proposal_id"].clone(),"status":"pending",
                "bundle_sha256":review["proposal"]["bundle_sha256"].clone(),
                "source_sha256":review["proposal"]["source_sha256"].clone(),
                "page_id_hint":review["proposal"]["candidate_page_id"].clone(),
                "owner_key":review["proposal"]["owner_key"].clone(),
                "created_utc":"2026-09-14T15:34:06Z"
            },
            "review":review,
            "sources":[{"ref":"project/summary","kind":"derived_project_metadata","observed_at":"2026-09-14T15:00:00Z","content":{"sessions":1}}]
        });
        let digest = sha256(&canonical_json(&view).unwrap());
        let view_id = format!("mpv1-{digest}");
        view.as_object_mut()
            .unwrap()
            .insert("view_id".into(), Value::String(view_id.clone()));
        let directory = review_views_directory(home);
        fs::create_dir_all(&directory).unwrap();
        fs::write(
            directory.join(format!("{view_id}.json")),
            canonical_json(&view).unwrap(),
        )
        .unwrap();
        (review_id, view_id)
    }

    fn rewrite_signed_view(home: &Path, old_path: &Path, mut view: Value) -> (String, String) {
        let review = view["review"].as_object_mut().unwrap();
        review.remove("review_id");
        let review_id = format!(
            "mpr1-{}",
            sha256(&canonical_json(&Value::Object(review.clone())).unwrap())
        );
        review.insert("review_id".into(), Value::String(review_id.clone()));

        let root = view.as_object_mut().unwrap();
        root.remove("view_id");
        let view_id = format!(
            "mpv1-{}",
            sha256(&canonical_json(&Value::Object(root.clone())).unwrap())
        );
        root.insert("view_id".into(), Value::String(view_id.clone()));
        fs::remove_file(old_path).unwrap();
        fs::write(
            review_views_directory(home).join(format!("{view_id}.json")),
            canonical_json(&view).unwrap(),
        )
        .unwrap();
        (review_id, view_id)
    }

    fn decision_path(directory: &Path, revision: u64) -> PathBuf {
        let matches: Vec<_> = fs::read_dir(directory)
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .filter(|path| {
                path.file_name()
                    .and_then(|name| name.to_str())
                    .and_then(decision_file_identity)
                    .is_some_and(|(candidate, _)| candidate == revision)
            })
            .collect();
        assert_eq!(matches.len(), 1);
        matches.into_iter().next().unwrap()
    }

    fn request(project_path: &str) -> KnowledgeReviewRequest {
        KnowledgeReviewRequest {
            project_path: project_path.into(),
        }
    }

    #[test]
    fn valid_view_is_listed_with_local_only_defaults() {
        let home = fixture_home("list");
        write_view(&home, r"P:\Dropbox\Project");
        let path = fs::read_dir(review_views_directory(&home))
            .unwrap()
            .next()
            .unwrap()
            .unwrap()
            .path();
        let mut budget = MAX_VIEW_SCAN_BYTES;
        if let Err(error) = parse_view(&path, &mut budget) {
            panic!("fixture view must parse: {error}");
        }
        let payload = get_knowledge_reviews_in(&home, request("p:/dropbox/project")).unwrap();
        assert!(payload.source_available);
        assert!(payload.warning.is_none());
        assert_eq!(payload.items.len(), 1);
        let item = &payload.items[0];
        assert_eq!(item.model_tag, "gemma4:31b");
        assert!(item.human_review_required);
        assert!(!item.semantic_correctness_verified);
        assert_eq!(item.decision.status, "unreviewed");
        assert_eq!(item.decision.revision, 0);
        assert!(!item.decision.conflict);
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn draft_and_approval_are_append_only_and_never_publish() {
        let home = fixture_home("append");
        fs::create_dir(home.join("missions")).unwrap();
        let project = r"P:\Dropbox\Project";
        let (review_id, view_id) = write_view(&home, project);
        let draft = save_knowledge_review_decision_in(
            &home,
            SaveKnowledgeReviewDecisionRequest {
                project_path: project.into(),
                review_id: review_id.clone(),
                view_id: view_id.clone(),
                expected_revision: 0,
                status: "draft".into(),
                edited_markdown: "## Redigert".into(),
                note: "Les igjen".into(),
            },
        )
        .unwrap();
        assert_eq!(draft.revision, 1);
        let approved = save_knowledge_review_decision_in(
            &home,
            SaveKnowledgeReviewDecisionRequest {
                project_path: project.into(),
                review_id: review_id.clone(),
                view_id,
                expected_revision: 1,
                status: "approved".into(),
                edited_markdown: "## Godkjent lokalt".into(),
                note: String::new(),
            },
        )
        .unwrap();
        assert_eq!(approved.revision, 2);
        assert_eq!(approved.status, "approved");
        let root = decisions_root(&home, false).unwrap();
        let directory = decision_directory(&root, &review_id);
        let first = decision_path(&directory, 1);
        let first_value: Value = serde_json::from_slice(&fs::read(&first).unwrap()).unwrap();
        let first_hash = decision_file_identity(first.file_name().unwrap().to_str().unwrap())
            .unwrap()
            .1;
        let second_value: Value =
            serde_json::from_slice(&fs::read(decision_path(&directory, 2)).unwrap()).unwrap();
        assert_eq!(first_value["event"]["publishAuthorized"], false);
        assert_eq!(first_value["event"]["published"], false);
        assert_eq!(first_value["event"]["previousEventSha256"], Value::Null);
        assert_eq!(second_value["event"]["previousEventSha256"], first_hash);
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn stale_revision_and_wrong_project_cannot_write() {
        let home = fixture_home("stale");
        fs::create_dir(home.join("missions")).unwrap();
        let project = r"P:\Dropbox\Project";
        let (review_id, view_id) = write_view(&home, project);
        let make = |expected_revision, project_path: &str| SaveKnowledgeReviewDecisionRequest {
            project_path: project_path.into(),
            review_id: review_id.clone(),
            view_id: view_id.clone(),
            expected_revision,
            status: "draft".into(),
            edited_markdown: "tekst".into(),
            note: String::new(),
        };
        assert!(save_knowledge_review_decision_in(&home, make(0, r"P:\Dropbox\Other")).is_err());
        save_knowledge_review_decision_in(&home, make(0, project)).unwrap();
        assert!(save_knowledge_review_decision_in(&home, make(0, project))
            .unwrap_err()
            .contains("mellomtiden"));
        let payload = get_knowledge_reviews_in(&home, request(project)).unwrap();
        assert_eq!(payload.items[0].decision.revision, 1);
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn canonical_project_owner_supports_nested_and_norwegian_paths() {
        let home = fixture_home("norwegian-owner");
        let project = r"C:\Projects\Økonomi\Årsoppgjør\Detaljer";
        write_view(&home, project);
        let payload = get_knowledge_reviews_in(
            &home,
            request("c:/projects/øKONOMI/årsoppgjør/detaljer/"),
        )
        .unwrap();
        assert_eq!(payload.items.len(), 1);
        assert_eq!(
            canonical_windows_project_path(r"\\Server\Deling\Mappe\").unwrap(),
            r"\\server\deling\mappe"
        );
        assert!(canonical_windows_project_path(r"P:\Dropbox\Prosjekt\..\Annet").is_err());
        assert!(canonical_windows_project_path(r"Dropbox\Prosjekt").is_err());
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn self_hashed_view_with_wrong_owner_is_rejected() {
        let home = fixture_home("wrong-owner");
        let project = r"P:\Dropbox\Project\Nested";
        write_view(&home, project);
        let old_path = fs::read_dir(review_views_directory(&home))
            .unwrap()
            .next()
            .unwrap()
            .unwrap()
            .path();
        let mut view: Value = serde_json::from_slice(&fs::read(&old_path).unwrap()).unwrap();
        let wrong_owner = format!("project-path-v1:{}", "f".repeat(64));
        view["proposal"]["owner_key"] = Value::String(wrong_owner.clone());
        view["review"]["proposal"]["owner_key"] = Value::String(wrong_owner);
        rewrite_signed_view(&home, &old_path, view);
        let payload = get_knowledge_reviews_in(&home, request(project)).unwrap();
        assert!(payload.items.is_empty());
        assert!(payload.warning.unwrap().contains("1 reviewvisninger"));
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn proposal_id_must_equal_bundle_digest() {
        let home = fixture_home("proposal-bundle-binding");
        let project = r"P:\Dropbox\Project";
        write_view(&home, project);
        let old_path = fs::read_dir(review_views_directory(&home))
            .unwrap()
            .next()
            .unwrap()
            .unwrap()
            .path();
        let mut view: Value = serde_json::from_slice(&fs::read(&old_path).unwrap()).unwrap();
        let wrong_proposal = format!("eb1-{}", "2".repeat(64));
        view["proposal"]["proposal_id"] = Value::String(wrong_proposal.clone());
        view["review"]["proposal"]["proposal_id"] = Value::String(wrong_proposal);
        rewrite_signed_view(&home, &old_path, view);
        let payload = get_knowledge_reviews_in(&home, request(project)).unwrap();
        assert!(payload.items.is_empty());
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn source_content_is_not_serialized_to_the_frontend() {
        let home = fixture_home("redacted-source-content");
        write_view(&home, r"P:\Dropbox\Project");
        let payload = get_knowledge_reviews_in(&home, request(r"P:\Dropbox\Project")).unwrap();
        let serialized = serde_json::to_value(payload).unwrap();
        assert!(serialized["items"][0]["preservedSources"][0]
            .get("content")
            .is_none());
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn malformed_views_consume_the_scan_budget() {
        let home = fixture_home("view-budget");
        let directory = review_views_directory(&home);
        fs::create_dir_all(&directory).unwrap();
        fs::write(
            directory.join("0000.json"),
            vec![b'x'; MAX_VIEW_BYTES as usize + 1],
        )
        .unwrap();
        for index in 1..=100 {
            fs::write(directory.join(format!("{index:04}.json")), b"{").unwrap();
        }
        let (available, views, warning) = load_views_with_budget(&home, 3).unwrap();
        assert!(available);
        assert!(views.is_empty());
        let warning = warning.unwrap();
        assert!(warning.contains("4 reviewvisninger"));
        assert!(warning.contains("lesegrensen"));
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn invalid_directory_entries_are_bounded_too() {
        let home = fixture_home("view-entry-limit");
        let directory = review_views_directory(&home);
        fs::create_dir_all(&directory).unwrap();
        for index in 0..10 {
            fs::write(directory.join(format!("invalid-{index}.tmp")), b"x").unwrap();
        }
        let (available, views, warning) =
            load_views_with_limits(&home, MAX_VIEW_SCAN_BYTES, 3).unwrap();
        assert!(available);
        assert!(views.is_empty());
        let warning = warning.unwrap();
        assert!(warning.contains("3 reviewvisninger"));
        assert!(warning.contains("lesegrensen"));
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn invalid_decision_entries_are_bounded_and_fail_closed() {
        let home = fixture_home("decision-entry-limit");
        fs::create_dir(home.join("missions")).unwrap();
        let (review_id, _) = write_view(&home, r"P:\Dropbox\Project");
        let (_, mut views, _) = load_views(&home).unwrap();
        let view = views.pop().unwrap();
        let root = decisions_root(&home, true).unwrap();
        let directory = decision_directory(&root, &review_id);
        fs::create_dir(&directory).unwrap();
        for index in 0..10 {
            fs::write(directory.join(format!("invalid-{index}.tmp")), b"x").unwrap();
        }
        let loaded = load_decision_with_entry_limit(&home, &view, 3).unwrap();
        assert!(loaded.decision.conflict);
        assert_eq!(loaded.decision.revision, 0);
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn tampered_view_is_preserved_but_not_shown() {
        let home = fixture_home("tampered-view");
        let (_, view_id) = write_view(&home, r"P:\Dropbox\Project");
        let directory = review_views_directory(&home);
        let path = fs::read_dir(&directory)
            .unwrap()
            .next()
            .unwrap()
            .unwrap()
            .path();
        let mut value: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        value["review"]["record"]["result_markdown"] = Value::String("endret".into());
        fs::write(&path, canonical_json(&value).unwrap()).unwrap();
        let payload = get_knowledge_reviews_in(&home, request(r"P:\Dropbox\Project")).unwrap();
        assert!(payload.items.is_empty());
        assert!(payload.warning.unwrap().contains("1 reviewvisninger"));
        assert_eq!(
            path.file_name().unwrap().to_string_lossy(),
            format!("{view_id}.json")
        );
        assert!(path.exists());
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn conflicted_copy_blocks_further_decisions_without_overwrite() {
        let home = fixture_home("conflict");
        fs::create_dir(home.join("missions")).unwrap();
        let project = r"P:\Dropbox\Project";
        let (review_id, view_id) = write_view(&home, project);
        save_knowledge_review_decision_in(
            &home,
            SaveKnowledgeReviewDecisionRequest {
                project_path: project.into(),
                review_id: review_id.clone(),
                view_id: view_id.clone(),
                expected_revision: 0,
                status: "draft".into(),
                edited_markdown: "tekst".into(),
                note: String::new(),
            },
        )
        .unwrap();
        let root = decisions_root(&home, false).unwrap();
        let directory = decision_directory(&root, &review_id);
        let first = decision_path(&directory, 1);
        let mut competing: DecisionRecord =
            serde_json::from_slice(&fs::read(first).unwrap()).unwrap();
        competing.event.note = "Parallell beslutning fra en annen maskin".into();
        competing.event.at_unix_ms += 1;
        let competing_hash = decision_event_sha256(&competing.event).unwrap();
        let competing_value = serde_json::to_value(competing).unwrap();
        fs::write(
            directory.join(format!(
                "revision-00000000000000000001--{competing_hash}.json"
            )),
            canonical_json(&competing_value).unwrap(),
        )
        .unwrap();
        let payload = get_knowledge_reviews_in(&home, request(project)).unwrap();
        assert!(payload.items[0].decision.conflict);
        let before = fs::read_dir(&directory).unwrap().count();
        let error = save_knowledge_review_decision_in(
            &home,
            SaveKnowledgeReviewDecisionRequest {
                project_path: project.into(),
                review_id,
                view_id,
                expected_revision: 1,
                status: "approved".into(),
                edited_markdown: "tekst".into(),
                note: String::new(),
            },
        )
        .unwrap_err();
        assert!(error.contains("konflikt"));
        assert_eq!(fs::read_dir(&directory).unwrap().count(), before);
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    #[ignore = "read-only live backend check; set AGENTSYNC_LIVE_TEST=1"]
    fn live_backend_chain_reads_review_views() {
        if std::env::var("AGENTSYNC_LIVE_TEST").ok().as_deref() != Some("1") {
            eprintln!("Skipped: set AGENTSYNC_LIVE_TEST=1 to read the live AgentSync store.");
            return;
        }

        let home = crate::resolve_agentsync_home().expect("resolve live AgentSync home");
        let project_path = std::env::var("AGENTSYNC_LIVE_PROJECT").unwrap_or_else(|_| {
            let text = home.to_string_lossy();
            if let Some(unc) = text.strip_prefix(r"\\?\UNC\") {
                format!(r"\\{unc}")
            } else {
                text.strip_prefix(r"\\?\").unwrap_or(&text).to_string()
            }
        });
        let payload = get_knowledge_reviews(KnowledgeReviewRequest {
            project_path: project_path.clone(),
        })
        .expect("read live knowledge reviews through the backend entry point");

        assert_eq!(payload.project_path, project_path);
        assert!(
            payload.source_available,
            "review-view source is unavailable"
        );
        assert!(
            !payload.items.is_empty(),
            "no review matched the live project; warning: {:?}",
            payload.warning
        );
    }
}
