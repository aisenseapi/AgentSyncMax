use serde::Serialize;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};
use walkdir::{DirEntry, WalkDir};

const MAX_CHECKPOINT_FILES: usize = 50_000;
const MAX_CHECKPOINT_FILE_BYTES: u64 = 32 * 1024 * 1024;
const MAX_CHECKPOINT_TOTAL_BYTES: u64 = 512 * 1024 * 1024;
const MAX_INLINE_DIFF_FILE_BYTES: u64 = 512 * 1024;
const MAX_DIFF_BYTES: usize = 500_000;

const EXCLUDED_DIRECTORIES: &[&str] = &[
    ".git",
    ".agent-state",
    ".cache",
    ".next",
    ".venv",
    "node_modules",
    "target",
    "venv",
];

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CheckpointSummary {
    pub(crate) mode: String,
    pub(crate) directory: String,
    pub(crate) file_count: usize,
    pub(crate) total_bytes: u64,
    pub(crate) complete: bool,
    pub(crate) skipped_files: usize,
    pub(crate) changed_files: usize,
    pub(crate) warning: Option<String>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct CheckpointFile {
    path: String,
    size: u64,
    modified_unix_ms: Option<u64>,
    sha256: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct CheckpointManifest<'a> {
    project_path: String,
    created_unix_ms: u64,
    complete: bool,
    total_bytes: u64,
    skipped_files: usize,
    // Backup files linked to content that was already present and verified.
    linked_files: usize,
    skipped_examples: &'a [String],
    files: Vec<&'a CheckpointFile>,
}

#[derive(Clone)]
pub(crate) struct WorkspaceCheckpoint {
    pub(crate) summary: CheckpointSummary,
    project: PathBuf,
    directory: PathBuf,
    backup_directory: PathBuf,
    files: BTreeMap<String, CheckpointFile>,
    skipped_paths: BTreeSet<String>,
}

pub(crate) struct CheckpointDelta {
    pub(crate) status: String,
    pub(crate) diff_stat: String,
    pub(crate) diff: String,
    pub(crate) changed_files: usize,
    pub(crate) diff_truncated: bool,
    pub(crate) summary: CheckpointSummary,
}

struct Capture {
    files: BTreeMap<String, CheckpointFile>,
    total_bytes: u64,
    complete: bool,
    skipped_files: usize,
    // Backup files linked to content that was already present and verified.
    linked_files: usize,
    backup_error: Option<String>,
    skipped_paths: BTreeSet<String>,
    skipped_examples: Vec<String>,
}

fn path_text(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

fn now_unix_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()
        .and_then(|duration| u64::try_from(duration.as_millis()).ok())
        .unwrap_or(0)
}

fn modified_unix_ms(metadata: &fs::Metadata) -> Option<u64> {
    metadata
        .modified()
        .ok()?
        .duration_since(UNIX_EPOCH)
        .ok()
        .and_then(|duration| u64::try_from(duration.as_millis()).ok())
}

fn relative_text(project: &Path, path: &Path) -> Option<String> {
    let relative = path.strip_prefix(project).ok()?;
    Some(relative.to_string_lossy().replace('\\', "/"))
}

fn is_excluded_entry(entry: &DirEntry, project: &Path, checkpoint_directory: &Path) -> bool {
    if entry.depth() == 0 {
        return false;
    }
    let checkpoint_store = checkpoint_directory
        .parent()
        .unwrap_or(checkpoint_directory);
    if checkpoint_store.starts_with(project) && entry.path().starts_with(checkpoint_store) {
        return true;
    }
    if !entry.file_type().is_dir() {
        return false;
    }
    let name = entry.file_name().to_string_lossy();
    EXCLUDED_DIRECTORIES
        .iter()
        .any(|excluded| name.eq_ignore_ascii_case(excluded))
}

// Three of the checkpoints on this machine were 233 MB each, and most of a
// project is identical from one run to the next. Every backup file is stored
// once under its own hash, and each checkpoint holds a hard link to it.
//
// The link is always between two backups, never to the live project. Linking a
// backup to the working copy would be worse than useless: an agent that writes
// a file in place would change the "backup" at the same moment, and the
// checkpoint would silently hold the new content instead of the old.
fn content_store(checkpoint_directory: &Path) -> Option<PathBuf> {
    Some(checkpoint_directory.parent()?.join(".content"))
}

// Only files newly created by this operation are ever removed by the guard.
// Existing pool entries may belong to older checkpoints and must be preserved,
// even if corruption is detected. Staging names are unique across concurrent runs.
struct TemporaryBackup(PathBuf, bool);

impl TemporaryBackup {
    fn retain(mut self) {
        self.1 = true;
    }
}

impl Drop for TemporaryBackup {
    fn drop(&mut self) {
        if !self.1 {
            let _ = fs::remove_file(&self.0);
        }
    }
}

fn verified_copy_new(source: &Path, destination: &Path, expected: &str) -> Result<(), String> {
    let input = File::open(source).map_err(|error| error.to_string())?;
    let mut output = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(destination)
        .map_err(|error| error.to_string())?;
    let guard = TemporaryBackup(destination.to_path_buf(), false);
    let copied = std::io::copy(&mut input.take(MAX_CHECKPOINT_FILE_BYTES + 1), &mut output)
        .map_err(|error| error.to_string())?;
    output.sync_all().map_err(|error| error.to_string())?;
    drop(output);
    if copied > MAX_CHECKPOINT_FILE_BYTES || sha256_file(destination)? != expected {
        return Err("Checkpoint-integritet feilet: filen endret seg under kopiering".to_string());
    }
    // Retain this verified file. The caller now owns its lifetime.
    guard.retain();
    Ok(())
}

fn link_verified_or_copy(
    source: &Path,
    destination: &Path,
    expected: &str,
) -> Result<bool, String> {
    match fs::hard_link(source, destination) {
        Ok(()) => {
            let guard = TemporaryBackup(destination.to_path_buf(), false);
            if sha256_file(destination)? != expected {
                return Err("Checkpoint-integritet feilet: lagret innhold er endret".to_string());
            }
            guard.retain();
            Ok(true)
        }
        Err(_) => {
            // Unsupported hard links are safe: copy the verified snapshot, never
            // reopen the mutable working file as an unchecked fallback.
            verified_copy_new(source, destination, expected)?;
            Ok(false)
        }
    }
}

fn store_backup(
    source: &Path,
    destination: &Path,
    sha256: &str,
    store: Option<&Path>,
) -> Result<bool, String> {
    let kept = store.map(|store| store.join(&sha256[..2]).join(&sha256[2..]));
    if let Some(kept) = &kept {
        if kept.exists() {
            if sha256_file(kept)? != sha256 {
                return Err(
                    "Checkpoint-integritet feilet: innholdspoolens kontrollsum stemmer ikke"
                        .to_string(),
                );
            }
            return link_verified_or_copy(kept, destination, sha256);
        }
    }

    let staging_parent = kept
        .as_deref()
        .and_then(Path::parent)
        .or_else(|| destination.parent())
        .ok_or("Checkpointet mangler målmappe")?;
    fs::create_dir_all(staging_parent).map_err(|error| error.to_string())?;
    static SEQUENCE: AtomicU64 = AtomicU64::new(0);
    let staging = staging_parent.join(format!(
        ".snapshot-{}-{}-{}.tmp",
        std::process::id(),
        now_unix_ms(),
        SEQUENCE.fetch_add(1, Ordering::Relaxed)
    ));
    verified_copy_new(source, &staging, sha256)?;
    let staging_guard = TemporaryBackup(staging, false);

    let mut reused = false;
    let verified_source = if let Some(kept) = &kept {
        // Hard-link publication is atomic and never overwrites a concurrent
        // winner, unlike rename on some platforms. The whole snapshot is already
        // durable and verified before its content-addressed name becomes visible.
        match fs::hard_link(&staging_guard.0, kept) {
            Ok(()) => kept.as_path(),
            Err(_) if kept.exists() => {
                if sha256_file(kept)? != sha256 {
                    return Err(
                        "Checkpoint-integritet feilet: konkurrerende lagring har feil kontrollsum"
                            .to_string(),
                    );
                }
                reused = true;
                kept.as_path()
            }
            // A filesystem without hard links still gets a verified private
            // checkpoint. No partially published shared file is left behind.
            Err(_) => staging_guard.0.as_path(),
        }
    } else {
        staging_guard.0.as_path()
    };
    let linked = link_verified_or_copy(verified_source, destination, sha256)?;
    Ok(reused && linked)
}

fn sha256_file(path: &Path) -> Result<String, String> {
    let mut file =
        File::open(path).map_err(|error| format!("Kan ikke lese {}: {error}", path_text(path)))?;
    let mut digest = Sha256::new();
    let mut total_bytes = 0_u64;
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let read = file
            .read(&mut buffer)
            .map_err(|error| format!("Kan ikke lese {}: {error}", path_text(path)))?;
        if read == 0 {
            break;
        }
        total_bytes += read as u64;
        if total_bytes > MAX_CHECKPOINT_FILE_BYTES {
            return Err("Checkpointfilen vokste over grensen på 32 MB".to_string());
        }
        digest.update(&buffer[..read]);
    }
    Ok(format!("{:x}", digest.finalize()))
}

fn remember_skip(capture: &mut Capture, path: String, reason: &str) {
    capture.complete = false;
    capture.skipped_files += 1;
    if capture.skipped_examples.len() < 20 {
        capture.skipped_examples.push(format!("{path}: {reason}"));
    }
    if capture.skipped_paths.len() < 2_000 {
        capture.skipped_paths.insert(path);
    }
}

fn collect_workspace(
    project: &Path,
    checkpoint_directory: &Path,
    backup_directory: Option<&Path>,
) -> Capture {
    let mut capture = Capture {
        files: BTreeMap::new(),
        total_bytes: 0,
        complete: true,
        skipped_files: 0,
        linked_files: 0,
        backup_error: None,
        skipped_paths: BTreeSet::new(),
        skipped_examples: Vec::new(),
    };
    let entries = WalkDir::new(project)
        .follow_links(false)
        .into_iter()
        .filter_entry(|entry| !is_excluded_entry(entry, project, checkpoint_directory));

    for result in entries {
        let entry = match result {
            Ok(entry) => entry,
            Err(error) => {
                remember_skip(&mut capture, "<mappe>".to_string(), &error.to_string());
                continue;
            }
        };
        if entry.file_type().is_dir() {
            continue;
        }
        let Some(relative) = relative_text(project, entry.path()) else {
            continue;
        };
        if !entry.file_type().is_file() {
            remember_skip(&mut capture, relative, "ikke en vanlig fil");
            continue;
        }
        if capture.files.len() >= MAX_CHECKPOINT_FILES {
            remember_skip(&mut capture, relative, "grensen på 50 000 filer er nådd");
            break;
        }
        let metadata = match entry.metadata() {
            Ok(metadata) => metadata,
            Err(error) => {
                remember_skip(&mut capture, relative, &error.to_string());
                continue;
            }
        };
        let mut size = metadata.len();
        if size > MAX_CHECKPOINT_FILE_BYTES {
            remember_skip(&mut capture, relative, "filen er større enn 32 MB");
            continue;
        }
        if capture.total_bytes.saturating_add(size) > MAX_CHECKPOINT_TOTAL_BYTES {
            remember_skip(
                &mut capture,
                relative,
                "samlet checkpointgrense på 512 MB er nådd",
            );
            continue;
        }
        let sha256 = match sha256_file(entry.path()) {
            Ok(value) => value,
            Err(error) => {
                remember_skip(&mut capture, relative, &error);
                continue;
            }
        };
        if let Some(backup_root) = backup_directory {
            let destination = backup_root.join(Path::new(&relative));
            if let Some(parent) = destination.parent() {
                if let Err(error) = fs::create_dir_all(parent) {
                    capture.backup_error = Some(format!("{relative}: {error}"));
                    remember_skip(&mut capture, relative, &error.to_string());
                    break;
                }
            }
            let store = content_store(checkpoint_directory);
            match store_backup(entry.path(), &destination, &sha256, store.as_deref()) {
                Ok(linked) => {
                    if linked {
                        capture.linked_files += 1;
                    }
                }
                Err(error) => {
                    capture.backup_error = Some(format!("{relative}: {error}"));
                    remember_skip(&mut capture, relative, &error);
                    break;
                }
            }
            // Manifest size describes the secured bytes, not metadata sampled
            // before a concurrent writer changed the working file.
            match fs::metadata(&destination) {
                Ok(saved) => size = saved.len(),
                Err(error) => {
                    capture.backup_error = Some(format!("{relative}: {error}"));
                    break;
                }
            }
            if capture.total_bytes.saturating_add(size) > MAX_CHECKPOINT_TOTAL_BYTES {
                capture.backup_error =
                    Some("filen vokste over samlet checkpointgrense".to_string());
                break;
            }
        }
        capture.total_bytes = capture.total_bytes.saturating_add(size);
        capture.files.insert(
            relative.clone(),
            CheckpointFile {
                path: relative,
                size,
                modified_unix_ms: modified_unix_ms(&metadata),
                sha256,
            },
        );
    }
    capture
}

fn checkpoint_warning(capture: &Capture) -> Option<String> {
    if capture.complete {
        None
    } else {
        let examples = capture.skipped_examples.join(" | ");
        Some(format!(
            "Checkpointet hoppet over {} filer. Missionen kan kjøre, men disse filene er ikke fullt beskyttet. {}",
            capture.skipped_files, examples
        ))
    }
}

fn write_manifest(path: &Path, project: &Path, capture: &Capture) -> Result<(), String> {
    let manifest = CheckpointManifest {
        project_path: path_text(project),
        created_unix_ms: now_unix_ms(),
        complete: capture.complete,
        total_bytes: capture.total_bytes,
        skipped_files: capture.skipped_files,
        linked_files: capture.linked_files,
        skipped_examples: &capture.skipped_examples,
        files: capture.files.values().collect(),
    };
    let data = serde_json::to_vec_pretty(&manifest)
        .map_err(|error| format!("Kan ikke serialisere checkpointmanifestet: {error}"))?;
    write_checkpoint_evidence(path, &data)
        .map_err(|error| format!("Kan ikke skrive checkpointmanifestet: {error}"))
}

fn write_checkpoint_evidence(path: &Path, data: &[u8]) -> Result<(), String> {
    let parent = path.parent().ok_or("Checkpointbeviset mangler målmappe")?;
    fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    static EVIDENCE_SEQUENCE: AtomicU64 = AtomicU64::new(0);
    let temporary = parent.join(format!(
        ".evidence-{}-{}-{}.tmp",
        std::process::id(),
        now_unix_ms(),
        EVIDENCE_SEQUENCE.fetch_add(1, Ordering::Relaxed)
    ));
    let guard = TemporaryBackup(temporary, false);
    let mut output = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&guard.0)
        .map_err(|error| error.to_string())?;
    output.write_all(data).map_err(|error| error.to_string())?;
    output.sync_all().map_err(|error| error.to_string())?;
    drop(output);
    fs::rename(&guard.0, path).map_err(|error| error.to_string())?;
    guard.retain();
    Ok(())
}

pub(crate) fn create_workspace_checkpoint(
    project: &Path,
    directory: PathBuf,
) -> Result<WorkspaceCheckpoint, String> {
    let result = (|| {
        let backup_directory = directory.join("before");
        fs::create_dir_all(&backup_directory)
            .map_err(|error| format!("Kan ikke opprette AgentSync-checkpoint: {error}"))?;
        let capture = collect_workspace(project, &directory, Some(&backup_directory));
        if let Some(error) = &capture.backup_error {
            return Err(format!(
                "AgentSync-checkpoint kunne ikke sikres. Oppdraget starter ikke: {error}"
            ));
        }
        write_manifest(&directory.join("before-manifest.json"), project, &capture)?;
        let warning = checkpoint_warning(&capture);
        let summary = CheckpointSummary {
            mode: "agentsync-checkpoint".to_string(),
            directory: path_text(&directory),
            file_count: capture.files.len(),
            total_bytes: capture.total_bytes,
            complete: capture.complete,
            skipped_files: capture.skipped_files,
            changed_files: 0,
            warning,
        };
        Ok(WorkspaceCheckpoint {
            summary,
            project: project.to_path_buf(),
            directory: directory.clone(),
            backup_directory,
            files: capture.files,
            skipped_paths: capture.skipped_paths,
        })
    })();
    if result.is_err() {
        let _ = fs::remove_dir_all(&directory);
    }
    result
}

fn read_small_text(path: &Path, size: u64) -> Option<String> {
    if size > MAX_INLINE_DIFF_FILE_BYTES {
        return None;
    }
    let bytes = fs::read(path).ok()?;
    if bytes.contains(&0) {
        return None;
    }
    String::from_utf8(bytes).ok()
}

fn append_lines(output: &mut String, prefix: char, lines: &[&str]) {
    for line in lines {
        output.push(prefix);
        output.push_str(line);
        output.push('\n');
    }
}

fn append_text_delta(output: &mut String, before: &str, after: &str) {
    let old_lines: Vec<&str> = before.lines().collect();
    let new_lines: Vec<&str> = after.lines().collect();
    let mut prefix = 0;
    while prefix < old_lines.len()
        && prefix < new_lines.len()
        && old_lines[prefix] == new_lines[prefix]
    {
        prefix += 1;
    }
    let mut suffix = 0;
    while suffix < old_lines.len().saturating_sub(prefix)
        && suffix < new_lines.len().saturating_sub(prefix)
        && old_lines[old_lines.len() - 1 - suffix] == new_lines[new_lines.len() - 1 - suffix]
    {
        suffix += 1;
    }
    let context_start = prefix.saturating_sub(3);
    let old_change_end = old_lines.len().saturating_sub(suffix);
    let new_change_end = new_lines.len().saturating_sub(suffix);
    let old_context_end = old_lines.len().min(old_change_end.saturating_add(3));
    let new_context_end = new_lines.len().min(new_change_end.saturating_add(3));
    output.push_str(&format!(
        "@@ -{},{} +{},{} @@\n",
        context_start + 1,
        old_context_end.saturating_sub(context_start),
        context_start + 1,
        new_context_end.saturating_sub(context_start)
    ));
    append_lines(output, ' ', &old_lines[context_start..prefix]);
    append_lines(output, '-', &old_lines[prefix..old_change_end]);
    append_lines(output, '+', &new_lines[prefix..new_change_end]);
    append_lines(output, ' ', &new_lines[new_change_end..new_context_end]);
}

fn append_file_delta(
    output: &mut String,
    relative: &str,
    before: Option<(&Path, &CheckpointFile)>,
    after: Option<(&Path, &CheckpointFile)>,
) {
    output.push_str(&format!("diff --agentsync a/{relative} b/{relative}\n"));
    if before.is_some() {
        output.push_str(&format!("--- a/{relative}\n"));
    } else {
        output.push_str("--- /dev/null\n");
    }
    if after.is_some() {
        output.push_str(&format!("+++ b/{relative}\n"));
    } else {
        output.push_str("+++ /dev/null\n");
    }
    match (before, after) {
        (Some((before_path, before_file)), Some((after_path, after_file))) => {
            match (
                read_small_text(before_path, before_file.size),
                read_small_text(after_path, after_file.size),
            ) {
                (Some(old), Some(new)) => append_text_delta(output, &old, &new),
                _ => output.push_str("Binary or large file changed\n"),
            }
        }
        (None, Some((after_path, after_file))) => {
            if let Some(text) = read_small_text(after_path, after_file.size) {
                let lines: Vec<&str> = text.lines().collect();
                output.push_str(&format!("@@ -0,0 +1,{} @@\n", lines.len()));
                append_lines(output, '+', &lines);
            } else {
                output.push_str("Binary or large file added\n");
            }
        }
        (Some((before_path, before_file)), None) => {
            if let Some(text) = read_small_text(before_path, before_file.size) {
                let lines: Vec<&str> = text.lines().collect();
                output.push_str(&format!("@@ -1,{} +0,0 @@\n", lines.len()));
                append_lines(output, '-', &lines);
            } else {
                output.push_str("Binary or large file deleted\n");
            }
        }
        (None, None) => {}
    }
    output.push('\n');
}

fn truncate_diff(value: String) -> (String, bool) {
    if value.len() <= MAX_DIFF_BYTES {
        return (value, false);
    }
    let mut end = MAX_DIFF_BYTES;
    while end > 0 && !value.is_char_boundary(end) {
        end -= 1;
    }
    let omitted = value.len().saturating_sub(end);
    (
        format!("{}\n\n[AgentSync forkortet {omitted} byte]", &value[..end]),
        true,
    )
}

pub(crate) fn compare_workspace_checkpoint(
    checkpoint: &WorkspaceCheckpoint,
) -> Result<CheckpointDelta, String> {
    let after_capture = collect_workspace(&checkpoint.project, &checkpoint.directory, None);
    let mut all_paths: BTreeSet<String> = checkpoint.files.keys().cloned().collect();
    all_paths.extend(after_capture.files.keys().cloned());
    let mut status_lines = Vec::new();
    let mut diff = String::new();
    let mut added = 0;
    let mut modified = 0;
    let mut deleted = 0;

    for relative in all_paths {
        if checkpoint.skipped_paths.contains(&relative)
            || after_capture.skipped_paths.contains(&relative)
        {
            continue;
        }
        let before = checkpoint.files.get(&relative);
        let after = after_capture.files.get(&relative);
        if (before.is_some() && after.is_none() && !after_capture.complete)
            || (before.is_none() && after.is_some() && !checkpoint.summary.complete)
        {
            continue;
        }
        if before.map(|file| &file.sha256) == after.map(|file| &file.sha256) {
            continue;
        }
        let code = match (before, after) {
            (None, Some(_)) => {
                added += 1;
                "A"
            }
            (Some(_), None) => {
                deleted += 1;
                "D"
            }
            _ => {
                modified += 1;
                "M"
            }
        };
        status_lines.push(format!("{code}  {relative}"));
        let before_path = checkpoint.backup_directory.join(Path::new(&relative));
        let after_path = checkpoint.project.join(Path::new(&relative));
        append_file_delta(
            &mut diff,
            &relative,
            before.map(|file| (before_path.as_path(), file)),
            after.map(|file| (after_path.as_path(), file)),
        );
    }

    write_manifest(
        &checkpoint.directory.join("after-manifest.json"),
        &checkpoint.project,
        &after_capture,
    )?;
    let changed_files = status_lines.len();
    let diff_stat = format!(
        "{changed_files} filer endret: {added} lagt til, {modified} endret, {deleted} slettet"
    );
    let (diff, diff_truncated) = truncate_diff(diff);
    write_checkpoint_evidence(
        &checkpoint.directory.join("mission-diff.txt"),
        diff.as_bytes(),
    )
    .map_err(|error| format!("Kan ikke skrive checkpointdiffen: {error}"))?;

    let complete = checkpoint.summary.complete && after_capture.complete;
    let skipped_files = checkpoint
        .summary
        .skipped_files
        .saturating_add(after_capture.skipped_files);
    let warning = match (
        &checkpoint.summary.warning,
        checkpoint_warning(&after_capture),
    ) {
        (Some(before), Some(after)) => Some(format!("{before} {after}")),
        (Some(before), None) => Some(before.clone()),
        (None, Some(after)) => Some(after),
        (None, None) => None,
    };
    let summary = CheckpointSummary {
        mode: checkpoint.summary.mode.clone(),
        directory: checkpoint.summary.directory.clone(),
        file_count: checkpoint.summary.file_count,
        total_bytes: checkpoint.summary.total_bytes,
        complete,
        skipped_files,
        changed_files,
        warning,
    };
    Ok(CheckpointDelta {
        status: status_lines.join("\n"),
        diff_stat,
        diff,
        changed_files,
        diff_truncated,
        summary,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temporary_directory(label: &str) -> PathBuf {
        std::env::temp_dir().join(format!("agentsync-{label}-{}", now_unix_ms()))
    }

    #[test]
    fn a_second_checkpoint_reuses_stored_content_without_endangering_the_first() {
        // Two checkpoints of the same project share one copy of every file that
        // did not change. What must never happen is a link to the live project:
        // an agent writing a file in place would then alter the backup too.
        let root = temporary_directory("checkpoint-store");
        let project = root.join("project");
        fs::create_dir_all(&project).expect("prosjektmappen skal opprettes");
        fs::write(project.join("stable.txt"), "uendret innhold\n").expect("filen skal skrives");

        let first = create_workspace_checkpoint(&project, root.join("checkpoints").join("one"))
            .expect("første checkpoint skal opprettes");
        let second = create_workspace_checkpoint(&project, root.join("checkpoints").join("two"))
            .expect("andre checkpoint skal opprettes");

        assert!(first.summary.file_count >= 1);
        assert!(second.summary.file_count >= 1);

        let shared = root.join("checkpoints").join(".content");
        assert!(shared.is_dir(), "innholdspoolen skal deles mellom oppdrag");
        assert!(!first.directory.join(".content").exists());
        assert!(!second.directory.join(".content").exists());
        let first_manifest: serde_json::Value = serde_json::from_slice(
            &fs::read(first.directory.join("before-manifest.json")).unwrap(),
        )
        .unwrap();
        let second_manifest: serde_json::Value = serde_json::from_slice(
            &fs::read(second.directory.join("before-manifest.json")).unwrap(),
        )
        .unwrap();
        assert_eq!(
            first_manifest["linkedFiles"], 0,
            "første kopi er ikke gjenbruk"
        );
        assert_eq!(
            second_manifest["linkedFiles"], 1,
            "andre checkpoint gjenbruker innhold"
        );

        let backup = root
            .join("checkpoints")
            .join("one")
            .join("before")
            .join("stable.txt");
        assert!(backup.is_file(), "førtilstanden skal ligge i checkpointet");

        // The agent rewrites the working copy in place, the way an editor does.
        fs::write(project.join("stable.txt"), "agenten skrev over\n").expect("skriving skal gå");

        assert_eq!(
            fs::read_to_string(&backup).expect("backupen skal kunne leses"),
            "uendret innhold\n",
            "backupen må holde førtilstanden selv når arbeidskopien skrives over"
        );

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn changed_source_is_not_published_under_a_stale_hash() {
        let root = temporary_directory("checkpoint-source-race");
        fs::create_dir_all(&root).unwrap();
        let source = root.join("source.txt");
        let destination = root.join("backup.txt");
        let store = root.join("pool");
        fs::write(&source, "before").unwrap();
        let expected = sha256_file(&source).unwrap();
        // Deterministic interleaving of a writer between the two old read passes.
        fs::write(&source, "after!").unwrap();
        assert!(store_backup(&source, &destination, &expected, Some(&store)).is_err());
        assert!(
            !destination.exists(),
            "en uverifisert backup må ikke publiseres"
        );
        assert!(!store.join(&expected[..2]).join(&expected[2..]).exists());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn corrupted_stored_content_is_never_reused_or_silently_replaced() {
        let root = temporary_directory("checkpoint-corrupt-pool");
        fs::create_dir_all(&root).unwrap();
        let source = root.join("source.txt");
        let destination = root.join("backup.txt");
        let store = root.join("pool");
        fs::write(&source, "correct").unwrap();
        let expected = sha256_file(&source).unwrap();
        let kept = store.join(&expected[..2]).join(&expected[2..]);
        fs::create_dir_all(kept.parent().unwrap()).unwrap();
        fs::write(&kept, "damaged").unwrap();
        assert!(store_backup(&source, &destination, &expected, Some(&store)).is_err());
        assert!(!destination.exists());
        assert_eq!(fs::read_to_string(kept).unwrap(), "damaged");
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn failed_backup_stops_checkpoint_creation() {
        let root = temporary_directory("checkpoint-write-failure");
        let project = root.join("project");
        let directory = root.join("checkpoints").join("one");
        fs::create_dir_all(&project).unwrap();
        fs::create_dir_all(directory.join("before")).unwrap();
        fs::write(project.join("file.txt"), "keep this").unwrap();
        // A directory at the target is an actual failed write, not a mock.
        fs::create_dir_all(directory.join("before").join("file.txt")).unwrap();
        assert!(create_workspace_checkpoint(&project, directory.clone()).is_err());
        assert!(
            !directory.exists(),
            "et checkpoint som ikke kunne sikres skal ryddes helt"
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn failed_after_evidence_is_reported_instead_of_marked_complete() {
        let root = temporary_directory("checkpoint-after-evidence-failure");
        let project = root.join("project");
        let checkpoint_directory = root.join("checkpoints/one");
        fs::create_dir_all(&project).unwrap();
        fs::write(project.join("file.txt"), "before\n").unwrap();
        let checkpoint = create_workspace_checkpoint(&project, checkpoint_directory.clone())
            .expect("førbeviset skal opprettes");
        fs::write(project.join("file.txt"), "after\n").unwrap();
        // A directory at the evidence filename makes the durable publication
        // fail without depending on platform-specific permission behavior.
        fs::create_dir(checkpoint_directory.join("after-manifest.json")).unwrap();

        let error = match compare_workspace_checkpoint(&checkpoint) {
            Ok(_) => panic!("manglende ettermanifest må være en synlig feil"),
            Err(error) => error,
        };

        assert!(error.contains("checkpointmanifestet"));
        assert!(!checkpoint_directory.join("mission-diff.txt").exists());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn verified_copy_fallback_preserves_existing_destinations() {
        let root = temporary_directory("checkpoint-copy-fallback");
        fs::create_dir_all(&root).unwrap();
        let source = root.join("source.txt");
        let destination = root.join("backup.txt");
        fs::write(&source, "original").unwrap();
        let expected = sha256_file(&source).unwrap();
        verified_copy_new(&source, &destination, &expected).unwrap();
        fs::write(&source, "new text").unwrap();
        assert!(verified_copy_new(&source, &destination, &expected).is_err());
        assert_eq!(fs::read_to_string(&destination).unwrap(), "original");
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn concurrent_checkpoints_publish_only_verified_content_without_staging_collisions() {
        let root = temporary_directory("checkpoint-concurrent");
        let project = root.join("project");
        fs::create_dir_all(&project).unwrap();
        fs::write(project.join("shared.txt"), "same verified bytes").unwrap();
        let expected = sha256_file(&project.join("shared.txt")).unwrap();
        let barrier = std::sync::Arc::new(std::sync::Barrier::new(8));
        let workers: Vec<_> = (0..8)
            .map(|index| {
                let project = project.clone();
                let directory = root.join("checkpoints").join(index.to_string());
                let barrier = barrier.clone();
                std::thread::spawn(move || {
                    barrier.wait();
                    create_workspace_checkpoint(&project, directory).unwrap()
                })
            })
            .collect();
        for worker in workers {
            let checkpoint = worker.join().unwrap();
            assert!(checkpoint.summary.complete);
            assert_eq!(
                sha256_file(&checkpoint.backup_directory.join("shared.txt")).unwrap(),
                expected
            );
            assert_eq!(checkpoint.files["shared.txt"].sha256, expected);
        }
        let pool_files: Vec<_> = WalkDir::new(root.join("checkpoints/.content"))
            .into_iter()
            .map(Result::unwrap)
            .filter(|entry| entry.file_type().is_file())
            .collect();
        assert_eq!(
            pool_files.len(),
            1,
            "én innholdskopi og ingen midlertidige restfiler"
        );
        assert_eq!(sha256_file(pool_files[0].path()).unwrap(), expected);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn checkpoint_reports_only_changes_after_capture() {
        let root = temporary_directory("checkpoint-project");
        let project = root.join("project");
        let checkpoint_directory = root.join("checkpoints/one");
        fs::create_dir_all(&project).expect("prosjektmappen skal opprettes");
        fs::write(project.join("existing.txt"), "brukerens arbeid\n")
            .expect("førtilstanden skal skrives");
        let checkpoint = create_workspace_checkpoint(&project, checkpoint_directory.clone())
            .expect("checkpointet skal opprettes");

        fs::write(
            project.join("existing.txt"),
            "brukerens arbeid\nmissionens tillegg\n",
        )
        .expect("missionendringen skal skrives");
        fs::write(project.join("new.txt"), "ny fil\n").expect("ny fil skal skrives");
        let delta = compare_workspace_checkpoint(&checkpoint).expect("etterbevis skal skrives");

        assert_eq!(delta.changed_files, 2);
        assert!(delta.status.contains("M  existing.txt"));
        assert!(delta.status.contains("A  new.txt"));
        assert!(delta.diff.contains("+missionens tillegg"));
        assert!(checkpoint_directory.join("before/existing.txt").is_file());
        assert!(checkpoint_directory.join("after-manifest.json").is_file());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn checkpoint_captures_deleted_files() {
        let root = temporary_directory("checkpoint-delete-project");
        let project = root.join("project");
        let checkpoint_directory = root.join("checkpoints/one");
        fs::create_dir_all(&project).expect("prosjektmappen skal opprettes");
        fs::write(project.join("delete-me.txt"), "bevar meg\n")
            .expect("førtilstanden skal skrives");
        let checkpoint = create_workspace_checkpoint(&project, checkpoint_directory.clone())
            .expect("checkpointet skal opprettes");
        fs::remove_file(project.join("delete-me.txt")).expect("testfilen skal slettes");
        let delta = compare_workspace_checkpoint(&checkpoint).expect("etterbevis skal skrives");

        assert_eq!(delta.changed_files, 1);
        assert!(delta.status.contains("D  delete-me.txt"));
        assert!(delta.diff.contains("-bevar meg"));
        assert!(checkpoint_directory.join("before/delete-me.txt").is_file());
        let _ = fs::remove_dir_all(root);
    }
}
