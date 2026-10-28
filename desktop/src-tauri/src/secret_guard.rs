//! Local, bounded checks at MAX's explicit outgoing-data boundaries.
//! This is a detector, not an exhaustive secret inventory or an OS sandbox.
//! Native agents and independently synchronized history are outside this module.
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::{hash_map::RandomState, VecDeque},
    fs::{self, File, OpenOptions},
    hash::{BuildHasher, Hasher},
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicU64, Ordering},
        Mutex, OnceLock,
    },
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

const MAX_SETTINGS: usize = 4_096;
const MAX_FILE_BYTES: usize = 1_048_576;
const MAX_TRANSFER_BYTES: usize = 8_388_608;
const MAX_FILES: usize = 128;
const MAX_TEXTS: usize = 64;
const MAX_FINDINGS: usize = 32;
const MAX_CHALLENGES: usize = 64;
const PERMIT_TTL: Duration = Duration::from_secs(300);
static SERIAL: OnceLock<Mutex<GuardState>> = OnceLock::new();
static UNIQUE: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Settings {
    pub(crate) enabled: bool,
    pub(crate) warning: Option<String>,
}

#[derive(Debug)]
pub(crate) struct TransferApproval {
    // None means the user disabled the extra check. Otherwise hashes are in
    // files-input order and belong to the exact bytes inspected above.
    pub(crate) file_hashes: Option<Vec<Vec<u8>>>,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct StoredSettings {
    enabled: bool,
}

#[derive(Debug, Serialize)]
struct Finding {
    source: String,
    kind: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    line: Option<usize>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Block {
    code: &'static str,
    token: String,
    can_allow_once: bool,
    operation: String,
    recipient: String,
    findings: Vec<Finding>,
    findings_truncated: bool,
    message: &'static str,
}

struct Challenge {
    token: String,
    fingerprint: [u8; 32],
    created: Instant,
    allowed: bool,
}

#[derive(Default)]
struct GuardState {
    challenges: VecDeque<Challenge>,
}

impl GuardState {
    fn prune(&mut self, now: Instant) {
        self.challenges
            .retain(|p| now.saturating_duration_since(p.created) < PERMIT_TTL);
    }

    fn approve(&mut self, token: &str, now: Instant) -> Result<(), String> {
        self.prune(now);
        if token.len() != 64 || !token.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err("Unntaket er ugyldig. Kontroller sendingen på nytt.".into());
        }
        let pending = self
            .challenges
            .iter_mut()
            .find(|p| p.token == token)
            .ok_or("Unntaket er utløpt eller brukt. Kontroller sendingen på nytt.")?;
        pending.allowed = true;
        Ok(())
    }

    fn consume(&mut self, fingerprint: &[u8; 32], now: Instant) -> bool {
        self.prune(now);
        if let Some(index) = self
            .challenges
            .iter()
            .position(|p| p.allowed && &p.fingerprint == fingerprint)
        {
            self.challenges.remove(index);
            return true;
        }
        false
    }

    fn challenge(&mut self, fingerprint: [u8; 32], now: Instant) -> String {
        self.prune(now);
        // A repeated UI retry replaces the pending request, never creates a
        // stockpile of permissions for the same data.
        self.challenges.retain(|p| p.fingerprint != fingerprint);
        while self.challenges.len() >= MAX_CHALLENGES {
            self.challenges.pop_front();
        }
        let token = nonce();
        self.challenges.push_back(Challenge {
            token: token.clone(),
            fingerprint,
            created: now,
            allowed: false,
        });
        token
    }
}

fn serial() -> Result<std::sync::MutexGuard<'static, GuardState>, String> {
    SERIAL
        .get_or_init(|| Mutex::new(GuardState::default()))
        .lock()
        .map_err(|_| "Hemmelighetsvernet kunne ikke låses. Sendingen er stoppet.".into())
}

// RandomState supplies per-instance random seeds. A process-local counter and
// timestamp prevent accidental reuse. These opaque handles are not credentials
// or a substitute for the application's command authorization boundary.
fn nonce() -> String {
    let mut random = RandomState::new().build_hasher();
    random.write_u64(UNIQUE.fetch_add(1, Ordering::Relaxed));
    random.write_u32(std::process::id());
    let mut digest = Sha256::new();
    digest.update(random.finish().to_le_bytes());
    digest.update(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
            .to_le_bytes(),
    );
    digest.update(UNIQUE.fetch_add(1, Ordering::Relaxed).to_le_bytes());
    format!("{:x}", digest.finalize())
}

fn settings_path() -> Result<PathBuf, String> {
    #[cfg(windows)]
    let base = std::env::var_os("LOCALAPPDATA").map(PathBuf::from);
    #[cfg(target_os = "macos")]
    let base =
        std::env::var_os("HOME").map(|p| PathBuf::from(p).join("Library/Application Support"));
    #[cfg(all(not(windows), not(target_os = "macos")))]
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .or_else(|| std::env::var_os("HOME").map(|p| PathBuf::from(p).join(".config")));
    base.filter(|p| p.is_absolute())
        .map(|p| p.join("AgentSyncMax/secret-guard.json"))
        .ok_or_else(|| "Lokal innstillingsmappe mangler. Hemmelighetsvernet er på.".into())
}

fn default_settings(warning: Option<String>) -> Settings {
    Settings {
        enabled: true,
        warning,
    }
}

fn safe_path(path: &Path, local_file: bool) -> Result<(), String> {
    // Check the ancestors as well: a harmless basename inside a junction must
    // not silently redirect the check or the local preference to another place.
    for (index, ancestor) in path.ancestors().enumerate() {
        if ancestor.as_os_str().is_empty() {
            continue;
        }
        match fs::symlink_metadata(ancestor) {
            Ok(metadata) => super::storage_safety::validate_stored_path(
                ancestor,
                &metadata,
                local_file && index == 0,
            )
            .map_err(|_| "Utrygg eller utilgjengelig lokal filsti.".to_string())?,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(_) => return Err("Filstien kunne ikke kontrolleres.".into()),
        }
    }
    Ok(())
}

fn read_bounded(path: &Path, limit: usize) -> Result<Vec<u8>, &'static str> {
    safe_path(path, true).map_err(|_| "Filstien kunne ikke kontrolleres")?;
    let before = fs::symlink_metadata(path).map_err(|_| "Filen kunne ikke leses")?;
    if !before.is_file() {
        return Err("Bare vanlige tekstfiler kan kontrolleres");
    }
    if before.len() > limit as u64 {
        return Err("Filen er større enn kontrollgrensen");
    }
    let mut file = File::open(path).map_err(|_| "Filen kunne ikke leses")?;
    let mut bytes = Vec::with_capacity((before.len() as usize).min(limit));
    (&mut file)
        .take(limit as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "Filen kunne ikke leses")?;
    let after = file
        .metadata()
        .map_err(|_| "Filen kunne ikke kontrolleres")?;
    let current = fs::symlink_metadata(path).map_err(|_| "Filen ble endret under kontrollen")?;
    if bytes.len() > limit {
        return Err("Filen er større enn kontrollgrensen");
    }
    if before.len() != after.len()
        || before.len() != bytes.len() as u64
        || before.modified().ok() != after.modified().ok()
        || current.len() != after.len()
        || current.modified().ok() != after.modified().ok()
        || safe_path(path, true).is_err()
    {
        return Err("Filen ble endret under kontrollen");
    }
    Ok(bytes)
}

fn load(path: &Path) -> Settings {
    let result = (|| {
        safe_path(path, true)?;
        match fs::symlink_metadata(path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(true),
            Err(_) => return Err("Kunne ikke lese innstillingen.".to_string()),
            Ok(_) => {}
        }
        let bytes = read_bounded(path, MAX_SETTINGS).map_err(str::to_string)?;
        serde_json::from_slice::<StoredSettings>(&bytes)
            .map(|s| s.enabled)
            .map_err(|_| "Ugyldig innstilling.".into())
    })();
    match result {
        Ok(enabled) => Settings {
            enabled,
            warning: None,
        },
        Err(_) => default_settings(Some(
            "Innstillingen kunne ikke leses sikkert. Hemmelighetsvernet er på; filen er bevart."
                .into(),
        )),
    }
}

fn save(path: &Path, enabled: bool) -> Result<Settings, String> {
    safe_path(path, true)?;
    let parent = path.parent().ok_or("Lokal innstillingsmappe mangler.")?;
    fs::create_dir_all(parent).map_err(|_| "Kunne ikke opprette lokal innstillingsmappe.")?;
    safe_path(path, true)?;
    if fs::symlink_metadata(path).is_ok_and(|m| !m.is_file()) {
        return Err("Innstillingen er ikke en vanlig fil. Den er bevart.".into());
    }
    let temp = parent.join(format!(".secret-guard-{}.tmp", nonce()));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temp)
        .map_err(|_| "Kunne ikke opprette innstillingens midlertidige fil.")?;
    let result = (|| {
        let bytes = serde_json::to_vec(&StoredSettings { enabled })
            .map_err(|_| "Kunne ikke kode innstillingen.")?;
        file.write_all(&bytes)
            .and_then(|_| file.sync_all())
            .map_err(|_| "Kunne ikke sikre innstillingen på disk.")?;
        drop(file);
        safe_path(path, true)?;
        fs::rename(&temp, path).map_err(|_| "Kunne ikke lagre innstillingen atomisk.")?;
        Ok(Settings {
            enabled,
            warning: None,
        })
    })();
    if result.is_err() {
        let _ = fs::remove_file(temp);
    }
    result
}

pub(crate) fn settings() -> Result<Settings, String> {
    let _guard = serial()?;
    Ok(match settings_path() {
        Ok(path) => load(&path),
        Err(message) => default_settings(Some(message)),
    })
}

pub(crate) fn configure(enabled: bool) -> Result<Settings, String> {
    let mut guard = serial()?;
    let result = save(&settings_path()?, enabled)?;
    guard.challenges.clear();
    Ok(result)
}

pub(crate) fn allow_once(token: String) -> Result<(), String> {
    serial()?.approve(&token, Instant::now())
}

/// Conservative filename policy; examples remain eligible for content checks.
pub(crate) fn sensitive_path(path: &Path) -> bool {
    let path = path.to_string_lossy().to_ascii_lowercase();
    let parts: Vec<&str> = path
        .split(['/', '\\'])
        .filter(|part| !part.is_empty())
        .collect();
    if parts.iter().any(|p| {
        [
            ".aws",
            ".ssh",
            ".gnupg",
            ".kube",
            ".docker",
            "secrets",
            "credentials",
        ]
        .contains(p)
    }) {
        return true;
    }
    let Some(name) = parts.last().copied() else {
        return false;
    };
    if [".env.example", ".env.sample", ".env.template"].contains(&name) {
        return false;
    }
    if name == ".env" || name.starts_with(".env.") || name == ".envrc" {
        return true;
    }
    if [
        ".npmrc",
        ".pypirc",
        ".netrc",
        ".dockercfg",
        ".htpasswd",
        "auth.json",
        "token.json",
        "config.local.json",
        "settings.local.json",
        "credentials.json",
        ".credentials.json",
        ".git-credentials",
        ".pgpass",
        "service-account.json",
        "service_account.json",
        "application_default_credentials.json",
        "secrets.json",
        "secrets.yaml",
        "secrets.yml",
        "id_rsa",
        "id_ed25519",
        "id_ecdsa",
        "id_dsa",
    ]
    .contains(&name)
    {
        return true;
    }
    if [
        ".pem",
        ".key",
        ".p12",
        ".pfx",
        ".kdbx",
        ".jks",
        ".keystore",
        ".ppk",
        ".asc",
        ".gpg",
        ".token",
    ]
    .iter()
    .any(|suffix| name.ends_with(suffix))
    {
        return true;
    }
    // Keep ordinary source/docs such as tokens.css and password-policy.md.
    if [
        ".rs", ".js", ".ts", ".tsx", ".jsx", ".py", ".ps1", ".php", ".md", ".css", ".html", ".svg",
        ".sql",
    ]
    .iter()
    .any(|suffix| name.ends_with(suffix))
    {
        return false;
    }
    name.split(|c: char| !c.is_ascii_alphanumeric())
        .any(|word| {
            [
                "token",
                "secret",
                "secrets",
                "credential",
                "credentials",
                "password",
                "passwd",
                "apikey",
                "privatekey",
            ]
            .contains(&word)
        })
}

fn placeholder(value: &str) -> bool {
    let value = value.trim();
    let lower = value.to_ascii_lowercase();
    if value.is_empty()
        || value.strip_prefix('$').is_some_and(identifier)
        || value
            .strip_prefix("${")
            .and_then(|v| v.strip_suffix('}'))
            .is_some_and(identifier)
        || lower.strip_prefix("$env:").is_some_and(identifier)
        || (value.starts_with('<') && value.ends_with('>'))
        || (value.starts_with("{{") && value.ends_with("}}"))
        || lower.starts_with("process.env.")
        || lower.starts_with("os.environ")
        || lower.starts_with("getenv(")
        || lower.starts_with("env(")
        || lower.starts_with("env::")
        || lower.starts_with("std::env")
        || lower.starts_with("your_")
        || lower.starts_with("your-")
        || lower.starts_with("replace_")
        || lower.starts_with("replace-")
        || lower.starts_with("example_")
        || lower.starts_with("example-")
        || value.chars().all(|c| c.is_ascii_digit())
        || value
            .chars()
            .all(|c| matches!(c, '*' | 'x' | 'X' | '.' | '-'))
    {
        return true;
    }
    [
        "true",
        "false",
        "null",
        "none",
        "undefined",
        "changeme",
        "change-me",
        "change_me",
        "replace-me",
        "replace_me",
        "your-api-key",
        "your-token",
        "example",
        "placeholder",
        "dummy",
        "test",
        "redacted",
        "masked",
        "secret",
        "password",
        "token",
    ]
    .contains(&lower.as_str())
}

fn substantive(value: &str) -> bool {
    if value.len() < 10 || placeholder(value) {
        return false;
    }
    let mut seen = [false; 256];
    for byte in value.bytes() {
        seen[byte as usize] = true;
    }
    seen.iter().filter(|present| **present).count() >= 5
}

fn key_is_sensitive(key: &str) -> bool {
    let key = key.to_ascii_lowercase();
    let compact: String = key.chars().filter(|c| c.is_ascii_alphanumeric()).collect();
    [
        "password",
        "passwd",
        "pwd",
        "secret",
        "token",
        "apikey",
        "clientsecret",
        "privatekey",
        "authorization",
        "accesstoken",
        "refreshtoken",
        "authtoken",
        "bearertoken",
        "awsaccesskeyid",
        "awssecretaccesskey",
        "accesskey",
        "secretkey",
        "githubtoken",
        "gh_token",
        "credential",
    ]
    .contains(&compact.as_str())
        || [
            "_password",
            "_passwd",
            "_secret",
            "_token",
            "_api_key",
            "-api-key",
            "-token",
            "-secret",
            "-password",
        ]
        .iter()
        .any(|suffix| key.ends_with(suffix))
}

fn assignment_value(tail: &str) -> &str {
    let tail = tail.trim_start();
    if let Some(quote) = tail
        .chars()
        .next()
        .filter(|c| *c == '\'' || *c == '"' || *c == '`')
    {
        let tail = &tail[quote.len_utf8()..];
        return tail.split(quote).next().unwrap_or("");
    }
    // The closing brace belongs to an unquoted shell reference, rather than
    // the surrounding JSON/object delimiter. Preserve it only when the whole
    // RHS token is that reference; appended literals must still be checked.
    if tail.starts_with("${") {
        if let Some(close) = tail.find('}') {
            let after = &tail[close + 1..];
            if after.is_empty()
                || after
                    .chars()
                    .next()
                    .is_some_and(|c| c.is_whitespace() || matches!(c, ',' | '}' | ']' | ';'))
            {
                return &tail[..close + 1];
            }
        }
    }
    tail.split(|c: char| c.is_whitespace() || matches!(c, ',' | '}' | ']' | ';'))
        .next()
        .unwrap_or("")
}

fn identifier(value: &str) -> bool {
    value
        .bytes()
        .next()
        .is_some_and(|b| b.is_ascii_alphabetic() || b == b'_')
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_')
}

fn clear_code_expression(value: &str, line: &str) -> bool {
    // Only unquoted RHS values reach here. Do not confuse getters, property
    // access and type annotations with a literal secret embedded in source.
    if let Some((call, _)) = value.split_once('(') {
        let call = call.trim_end_matches(['!', '?']);
        if !call.is_empty()
            && call
                .split(['.', ':'])
                .filter(|part| !part.is_empty())
                .all(identifier)
        {
            return true;
        }
    }
    if let Some((base, _)) = value.split_once('[') {
        if identifier(base) {
            return true;
        }
    }
    if value.contains("::") && value.split("::").all(identifier) {
        return true;
    }
    if let Some((base, _)) = value.split_once('.') {
        if [
            "state",
            "config",
            "settings",
            "credentials",
            "self",
            "this",
            "opts",
            "options",
            "provider",
            "process",
            "env",
        ]
        .contains(&base)
            && value.split('.').all(identifier)
        {
            return true;
        }
    }
    if let Some((base, _)) = value.split_once('<') {
        if identifier(base) && base.bytes().next().is_some_and(|b| b.is_ascii_uppercase()) {
            return true;
        }
    }
    let line = line.trim_start();
    ["let ", "const ", "var ", "static "]
        .iter()
        .any(|prefix| line.starts_with(prefix))
        && identifier(value)
}

fn assignment_secret(line: &str) -> bool {
    for (at, character) in line.char_indices().filter(|(_, c)| matches!(c, '=' | ':')) {
        let before = line[..at].trim_end().trim_end_matches(['\'', '"']);
        let start = before
            .rfind(|c: char| !(c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.')))
            .map_or(0, |i| i + before[i..].chars().next().unwrap().len_utf8());
        let key = &before[start..];
        if key_is_sensitive(key) {
            let tail = line[at + character.len_utf8()..].trim_start();
            let quoted = tail.starts_with(['\'', '"', '`']);
            let value = assignment_value(tail);
            if substantive(value) && (quoted || !clear_code_expression(value, line)) {
                return true;
            }
        }
    }
    false
}

fn credential_url(line: &str) -> bool {
    let mut rest = line;
    while let Some(start) = rest.find("://") {
        rest = &rest[start + 3..];
        let authority = rest
            .split(|c: char| {
                c.is_whitespace() || matches!(c, '/' | '?' | '#' | '\'' | '"' | '<' | '>')
            })
            .next()
            .unwrap_or("");
        if let Some((userinfo, host)) = authority.rsplit_once('@') {
            if let Some((user, password)) = userinfo.split_once(':') {
                if !host.is_empty()
                    && !user.is_empty()
                    && !password.is_empty()
                    && !placeholder(password)
                {
                    return true;
                }
            }
        }
    }
    false
}

fn token_kind(line: &str) -> Option<&'static str> {
    const PREFIXES: &[(&str, usize, &str)] = &[
        ("github_pat_", 35, "GitHub-token"),
        ("ghp_", 30, "GitHub-token"),
        ("gho_", 30, "GitHub-token"),
        ("ghu_", 30, "GitHub-token"),
        ("ghs_", 30, "GitHub-token"),
        ("ghr_", 30, "GitHub-token"),
        ("sk-ant-", 24, "Anthropic-nøkkel"),
        ("sk-proj-", 24, "OpenAI-nøkkel"),
        ("sk-", 32, "API-nøkkel"),
        ("xoxb-", 20, "Slack-token"),
        ("xoxp-", 20, "Slack-token"),
        ("xoxa-", 20, "Slack-token"),
        ("xoxr-", 20, "Slack-token"),
        ("xapp-", 20, "Slack-token"),
    ];
    for (prefix, minimum, kind) in PREFIXES {
        for (index, _) in line.match_indices(prefix) {
            if index > 0 && line.as_bytes()[index - 1].is_ascii_alphanumeric() {
                continue;
            }
            let tail = &line[index + prefix.len()..];
            let length = tail
                .bytes()
                .take_while(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-'))
                .count();
            if length >= *minimum && !placeholder(&tail[..length]) {
                return Some(kind);
            }
        }
    }
    for prefix in ["AKIA", "ASIA"] {
        for (index, _) in line.match_indices(prefix) {
            let token = &line.as_bytes()[index + 4..];
            if token.len() >= 16
                && token[..16]
                    .iter()
                    .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit())
                && (token.len() == 16 || !token[16].is_ascii_alphanumeric())
                && (index == 0 || !line.as_bytes()[index - 1].is_ascii_alphanumeric())
            {
                return Some("AWS-tilgangsnøkkel");
            }
        }
    }
    None
}

fn scan_text(text: &str, mut found: impl FnMut(&'static str, usize)) {
    for (index, line) in text.lines().enumerate() {
        let number = index + 1;
        if line.contains("-----BEGIN ") && line.contains("PRIVATE KEY-----") {
            found("Privat nøkkel", number);
        }
        if let Some(kind) = token_kind(line) {
            found(kind, number);
        }
        if credential_url(line) {
            found("URL med brukernavn og passord", number);
        }
        if assignment_secret(line) {
            found("Mulig hemmelighet i innstilling", number);
        }
    }
}

fn safe_label(value: &str, fallback: &str) -> String {
    if value.len() > 240
        || value.chars().any(|c| {
            c.is_control() || matches!(c, '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}')
        })
    {
        return fallback.into();
    }
    let mut suspicious = false;
    scan_text(value, |_, _| suspicious = true);
    if suspicious {
        return fallback.into();
    }
    value.chars().take(120).collect()
}

fn file_label(path: &Path) -> String {
    let name = path.to_string_lossy();
    safe_label(name.rsplit(['/', '\\']).next().unwrap_or("Fil"), "Fil")
}

fn hash_field(hash: &mut Sha256, bytes: &[u8]) {
    hash.update((bytes.len() as u64).to_le_bytes());
    hash.update(bytes);
}

struct Inspection {
    hash: Sha256,
    findings: Vec<Finding>,
    truncated: bool,
    fully_checked: bool,
    total_bytes: usize,
    file_hashes: Vec<Vec<u8>>,
}

impl Inspection {
    fn finding(&mut self, source: &str, kind: &'static str, line: Option<usize>) {
        if self.findings.len() < MAX_FINDINGS {
            self.findings.push(Finding {
                source: source.into(),
                kind,
                line,
            });
        } else {
            self.truncated = true;
        }
    }

    fn reject(&mut self, source: &str, kind: &'static str) {
        self.fully_checked = false;
        self.finding(source, kind, None);
    }

    fn inspect_text(&mut self, label: &str, text: &str) {
        if text.len() > MAX_TRANSFER_BYTES.saturating_sub(self.total_bytes) {
            self.reject(label, "Sendingen er større enn kontrollgrensen på 8 MiB");
            return;
        }
        self.total_bytes += text.len();
        hash_field(&mut self.hash, text.as_bytes());
        scan_text(text, |kind, line| self.finding(label, kind, Some(line)));
    }
}

fn inspect(
    operation: &str,
    recipient: &str,
    texts: &[(&str, &str)],
    files: &[PathBuf],
) -> Inspection {
    let mut inspection = Inspection {
        hash: Sha256::new(),
        findings: vec![],
        truncated: false,
        fully_checked: true,
        total_bytes: 0,
        file_hashes: vec![],
    };
    hash_field(&mut inspection.hash, b"MAX-secret-guard-v1");
    hash_field(&mut inspection.hash, operation.as_bytes());
    hash_field(&mut inspection.hash, recipient.as_bytes());
    if operation.len() > 4_096
        || recipient.len() > 4_096
        || texts.len() > MAX_TEXTS
        || files.len() > MAX_FILES
    {
        inspection.reject("Sending", "For mange elementer til en sikker kontroll");
        return inspection;
    }
    hash_field(&mut inspection.hash, &(texts.len() as u64).to_le_bytes());
    for (label, content) in texts {
        if label.len() > 4_096 {
            inspection.reject("Tekst", "Ugyldig tekstetikett");
            continue;
        }
        hash_field(&mut inspection.hash, label.as_bytes());
        inspection.inspect_text(&safe_label(label, "Tekst"), content);
    }
    hash_field(&mut inspection.hash, &(files.len() as u64).to_le_bytes());
    for path in files {
        let label = file_label(path);
        // Lossy display is never used as the permission binding.
        #[cfg(windows)]
        {
            use std::os::windows::ffi::OsStrExt;
            let path_bytes: Vec<u8> = path
                .as_os_str()
                .encode_wide()
                .flat_map(u16::to_le_bytes)
                .collect();
            hash_field(&mut inspection.hash, &path_bytes);
        }
        #[cfg(not(windows))]
        {
            use std::os::unix::ffi::OsStrExt;
            hash_field(&mut inspection.hash, path.as_os_str().as_bytes());
        }
        if sensitive_path(path) {
            inspection.finding(&label, "Beskyttet filnavn eller mappe", None);
        }
        let remaining = MAX_TRANSFER_BYTES.saturating_sub(inspection.total_bytes);
        match read_bounded(path, MAX_FILE_BYTES.min(remaining)) {
            Err(kind) => inspection.reject(&label, kind),
            Ok(bytes) => {
                inspection.file_hashes.push(Sha256::digest(&bytes).to_vec());
                match std::str::from_utf8(&bytes) {
                    Ok(text) if !text.contains('\0') => inspection.inspect_text(&label, text),
                    _ => inspection.reject(
                        &label,
                        "Binærfil eller ukjent tekstkoding kunne ikke kontrolleres",
                    ),
                }
            }
        }
    }
    inspection
}

fn check_enabled(
    state: &mut GuardState,
    enabled: bool,
    operation: &str,
    recipient: &str,
    texts: &[(&str, &str)],
    files: &[PathBuf],
    now: Instant,
) -> Result<TransferApproval, String> {
    // Off is a real bypass, including IO and size policy.
    if !enabled {
        return Ok(TransferApproval { file_hashes: None });
    }
    let inspection = inspect(operation, recipient, texts, files);
    if inspection.findings.is_empty() {
        return Ok(TransferApproval {
            file_hashes: Some(inspection.file_hashes),
        });
    }
    let fingerprint: [u8; 32] = inspection.hash.finalize().into();
    if inspection.fully_checked && state.consume(&fingerprint, now) {
        return Ok(TransferApproval {
            file_hashes: Some(inspection.file_hashes),
        });
    }
    let token = if inspection.fully_checked {
        state.challenge(fingerprint, now)
    } else {
        String::new()
    };
    let block = Block {
        code: "SECRET_GUARD",
        can_allow_once: inspection.fully_checked,
        token,
        operation: safe_label(operation, "Sending"),
        recipient: safe_label(recipient, "Valgt mottaker"),
        findings: inspection.findings,
        findings_truncated: inspection.truncated,
        message: if inspection.fully_checked {
            "Mulige hemmeligheter ble funnet. Sendingen er stoppet. Et engangsunntak gjelder bare dette innholdet til denne mottakeren i fem minutter."
        } else {
            "Alt innhold kunne ikke kontrolleres sikkert. Sendingen er stoppet. Reduser eller fjern elementet før du prøver igjen."
        },
    };
    Err(format!(
        "SECRET_GUARD:{}",
        serde_json::to_string(&block).map_err(|_| "Kunne ikke beskrive sikkerhetskontrollen.")?
    ))
}

pub(crate) fn check_transfer(
    operation: &str,
    recipient: &str,
    texts: &[(&str, &str)],
    files: &[PathBuf],
) -> Result<TransferApproval, String> {
    let mut state = serial()?;
    let enabled = settings_path()
        .map(|path| load(&path).enabled)
        .unwrap_or(true);
    check_enabled(
        &mut state,
        enabled,
        operation,
        recipient,
        texts,
        files,
        Instant::now(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!("asmax-secret-guard-test-{}", nonce()));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
        fn write(&self, name: &str, bytes: impl AsRef<[u8]>) -> PathBuf {
            let path = self.0.join(name);
            fs::write(&path, bytes).unwrap();
            path
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            // Only the unique fixture created above, inside the resolved temp
            // directory, may be recursively removed by this test helper.
            if let (Ok(path), Ok(parent)) =
                (self.0.canonicalize(), std::env::temp_dir().canonicalize())
            {
                if path.parent() == Some(parent.as_path())
                    && path
                        .file_name()
                        .unwrap()
                        .to_string_lossy()
                        .starts_with("asmax-secret-guard-test-")
                {
                    let _ = fs::remove_dir_all(path);
                }
            }
        }
    }
    fn key() -> String {
        format!("ghp_{}", "SyntheticOnlyAbc0123456789".repeat(2))
    }
    fn error_value<T: std::fmt::Debug>(result: Result<T, String>) -> serde_json::Value {
        serde_json::from_str(result.unwrap_err().strip_prefix("SECRET_GUARD:").unwrap()).unwrap()
    }
    fn token<T: std::fmt::Debug>(result: Result<T, String>) -> String {
        error_value(result)["token"].as_str().unwrap().into()
    }
    fn scan(text: &str) -> Vec<(&'static str, usize)> {
        let mut result = vec![];
        scan_text(text, |kind, line| result.push((kind, line)));
        result
    }

    #[test]
    fn preference_defaults_on_and_round_trips_off_then_on() {
        let fixture = Fixture::new();
        let path = fixture.0.join("secret-guard.json");
        assert!(load(&path).enabled);
        assert!(load(&path).warning.is_none());
        assert!(!save(&path, false).unwrap().enabled);
        assert!(!load(&path).enabled);
        assert!(save(&path, true).unwrap().enabled);
        assert!(load(&path).enabled);
        assert_eq!(fs::read_dir(&fixture.0).unwrap().count(), 1);
    }

    #[test]
    fn invalid_oversized_and_unreadable_preferences_fail_closed_without_rewriting() {
        let fixture = Fixture::new();
        for bytes in [
            b"{broken".to_vec(),
            br#"{"enabled":"false"}"#.to_vec(),
            br#"{"enabled":false,"surprise":1}"#.to_vec(),
            vec![b' '; MAX_SETTINGS + 1],
        ] {
            let path = fixture.write("secret-guard.json", &bytes);
            let settings = load(&path);
            assert!(settings.enabled && settings.warning.is_some());
            assert_eq!(fs::read(path).unwrap(), bytes);
        }
        assert!(load(&fixture.0).enabled);
        assert!(load(&fixture.0).warning.is_some());
    }

    #[test]
    fn disabled_skips_checks_and_file_io() {
        assert!(check_enabled(
            &mut GuardState::default(),
            false,
            "Send",
            "Agent",
            &[("Prompt", &key())],
            &[PathBuf::from("does-not-exist/.env")],
            Instant::now()
        )
        .is_ok());
    }

    #[test]
    fn protected_names_include_nested_and_provider_credentials() {
        for path in [
            ".env",
            ".env.production.json",
            "folder/.env.local",
            "auth.json",
            "token.json",
            "crates-io.token",
            ".m2m-token",
            ".git-credentials",
            "config.local.json",
            "nested/secrets/app.py",
            "C:\\work\\.aws\\config",
            "id_rsa",
            "key.PEM",
        ] {
            assert!(sensitive_path(Path::new(path)), "{path}");
        }
        for path in [
            ".env.example",
            ".env.sample",
            ".env.template",
            "tokens.css",
            "tokenizer.py",
            "password-policy.md",
            "monkey.png",
            "app.rs",
        ] {
            assert!(!sensitive_path(Path::new(path)), "{path}");
        }
    }

    #[test]
    fn detects_token_families_pem_urls_and_assignments_with_line_numbers() {
        for prefix in ["ghp_", "github_pat_", "sk-proj-", "sk-ant-", "sk-", "xoxb-"] {
            assert!(
                !scan(&format!("{prefix}{}", "Synthetic1234567890Abc".repeat(3))).is_empty(),
                "{prefix}"
            );
        }
        for value in [
            "AKIA1234567890ABCDEF",
            "-----BEGIN OPENSSH PRIVATE KEY-----",
            "https://user:localpass@host.invalid/repo",
            "database_password=syntheticOnlyValue123",
            r#"{"api_key":"syntheticOnlyValue123"}"#,
            "Authorization: 'Bearer syntheticOnlyValue123'",
        ] {
            let findings = scan(&format!("plain\n{value}"));
            assert!(!findings.is_empty(), "{value}");
            assert!(findings.iter().all(|(_, line)| *line == 2));
        }
    }

    #[test]
    fn ignores_empty_placeholders_environment_references_and_normal_code() {
        for text in [
            "API_KEY=",
            "TOKEN=YOUR_API_KEY_HERE",
            "secret=replace-me",
            "password=changeme",
            "TOKEN=${MY_LONG_TOKEN}",
            "token=process.env.API_TOKEN",
            "token=getenv('API_TOKEN')",
            "password=false",
            "max_tokens=40000",
            "token_count=9876543210",
            "https://user:${PASSWORD}@host.invalid/repo",
            "let secret = std::env::var(\"SECRET\");",
        ] {
            assert!(scan(text).is_empty(), "{text}");
        }
    }

    #[test]
    fn code_expressions_are_not_literal_secrets_but_quoted_values_still_are() {
        for text in [
            "token = state.session_token();",
            "secret = credentials.get();",
            "pub token: Option<String>,",
            "token = config.session_token",
            "secret = settings[\"password\"]",
            "secret = Config::credential",
            "let token = configured_token;",
            "const password = configuredPassword;",
            "token = get_token!();",
        ] {
            assert!(scan(text).is_empty(), "{text}");
        }
        for text in [
            "token = 'state.session_token()'",
            "secret = \"credentials.get()\"",
            "token = 'Option<String>'",
            "API_KEY=syntheticOnlyValue123",
            "const password = 'syntheticOnlyValue123';",
        ] {
            assert!(!scan(text).is_empty(), "{text}");
        }
    }

    #[test]
    fn braced_environment_references_preserve_their_closing_delimiter() {
        for text in [
            "TOKEN=${MY_LONG_TOKEN}",
            "TOKEN=${MY_LONG_TOKEN};",
            "TOKEN=${MY_LONG_TOKEN} # reference",
            "TOKEN='${MY_LONG_TOKEN}'",
        ] {
            assert!(scan(text).is_empty(), "{text}");
        }
        for text in [
            "TOKEN=${MY_LONG_TOKEN",
            "TOKEN=${MY_LONG_TOKEN}suffix",
            "TOKEN=${MY_LONG_TOKEN:-SyntheticDefault123}",
            "password=$SyntheticOnly!Password123",
        ] {
            assert!(!scan(text).is_empty(), "{text}");
        }
    }

    #[test]
    fn enabled_receipt_contains_exact_file_bytes_and_disabled_receipt_has_none() {
        let fixture = Fixture::new();
        let first = fixture.write("first.txt", b"first\r\n");
        let second = fixture.write("second.txt", b"second\n");
        let mut state = GuardState::default();
        let approval = check_enabled(
            &mut state,
            true,
            "Send",
            "Agent",
            &[],
            &[first, second],
            Instant::now(),
        )
        .unwrap();
        assert_eq!(
            approval.file_hashes.unwrap(),
            vec![
                Sha256::digest(b"first\r\n").to_vec(),
                Sha256::digest(b"second\n").to_vec()
            ]
        );
        let approval = check_enabled(
            &mut state,
            false,
            "Send",
            "Agent",
            &[],
            &[fixture.0.join("missing")],
            Instant::now(),
        )
        .unwrap();
        assert!(approval.file_hashes.is_none());
    }

    #[test]
    fn examples_are_content_checked_and_blocked_file_bytes_bind_exception() {
        let fixture = Fixture::new();
        let file = fixture.write(".env.example", "API_KEY=YOUR_API_KEY_HERE\n");
        let now = Instant::now();
        let mut state = GuardState::default();
        assert!(
            check_enabled(&mut state, true, "Send", "Agent", &[], &[file.clone()], now).is_ok()
        );
        fs::write(&file, format!("API_KEY={}\n", key())).unwrap();
        let permit = token(check_enabled(
            &mut state,
            true,
            "Send",
            "Agent",
            &[],
            &[file.clone()],
            now,
        ));
        state.approve(&permit, now).unwrap();
        fs::write(&file, format!("API_KEY={}changed\n", key())).unwrap();
        assert!(
            check_enabled(&mut state, true, "Send", "Agent", &[], &[file.clone()], now).is_err()
        );
        let protected = fixture.write(".env", "harmless");
        let permit = token(check_enabled(
            &mut state,
            true,
            "Send",
            "Agent",
            &[],
            &[protected.clone()],
            now,
        ));
        state.approve(&permit, now).unwrap();
        assert!(check_enabled(&mut state, true, "Send", "Agent", &[], &[protected], now).is_ok());
    }

    #[test]
    fn findings_never_contain_secret_values_or_unsafe_labels() {
        let secret = key();
        let mut state = GuardState::default();
        let value = error_value(check_enabled(
            &mut state,
            true,
            &secret,
            &format!("https://user:{secret}@host.invalid"),
            &[(&secret, &secret)],
            &[],
            Instant::now(),
        ));
        let serialized = serde_json::to_string(&value).unwrap();
        assert!(!serialized.contains(&secret));
        assert_eq!(value["findings"][0]["source"], "Tekst");
        assert_eq!(value["operation"], "Sending");
        assert_eq!(value["recipient"], "Valgt mottaker");
        assert!(!serialized.contains("https://"));
    }

    #[test]
    fn approval_is_exactly_one_use_and_bound_to_all_context() {
        let now = Instant::now();
        let secret = key();
        let mut state = GuardState::default();
        let permit = token(check_enabled(
            &mut state,
            true,
            "Mission",
            "Agent/model",
            &[("Prompt", &secret)],
            &[],
            now,
        ));
        state.approve(&permit, now).unwrap();
        for (operation, recipient, label, content) in [
            ("Review", "Agent/model", "Prompt", secret.as_str()),
            ("Mission", "Other/model", "Prompt", secret.as_str()),
            ("Mission", "Agent/model", "Other label", secret.as_str()),
            (
                "Mission",
                "Agent/model",
                "Prompt",
                "password=DifferentSyntheticValue123",
            ),
        ] {
            assert!(check_enabled(
                &mut state,
                true,
                operation,
                recipient,
                &[(label, content)],
                &[],
                now
            )
            .is_err());
        }
        assert!(check_enabled(
            &mut state,
            true,
            "Mission",
            "Agent/model",
            &[("Prompt", &secret)],
            &[],
            now
        )
        .is_ok());
        assert!(state.approve(&permit, now).is_err());
        assert!(check_enabled(
            &mut state,
            true,
            "Mission",
            "Agent/model",
            &[("Prompt", &secret)],
            &[],
            now
        )
        .is_err());
    }

    #[test]
    fn expired_permits_and_repeated_approval_do_not_multiply_permissions() {
        let now = Instant::now();
        let mut state = GuardState::default();
        let permit = state.challenge([1; 32], now);
        state.approve(&permit, now).unwrap();
        state.approve(&permit, now).unwrap();
        assert!(state.consume(&[1; 32], now));
        assert!(!state.consume(&[1; 32], now));
        let permit = state.challenge([2; 32], now);
        state.approve(&permit, now).unwrap();
        assert!(!state.consume(&[2; 32], now + PERMIT_TTL));
        assert!(state.approve(&permit, now + PERMIT_TTL).is_err());
    }

    #[test]
    fn pending_permissions_and_findings_are_bounded() {
        let now = Instant::now();
        let mut state = GuardState::default();
        for i in 0..200 {
            state.challenge([i; 32], now);
        }
        assert_eq!(state.challenges.len(), MAX_CHALLENGES);
        let value = error_value(check_enabled(
            &mut state,
            true,
            "Send",
            "Agent",
            &[("Prompt", &format!("{}\n", key()).repeat(100))],
            &[],
            now,
        ));
        assert_eq!(value["findings"].as_array().unwrap().len(), MAX_FINDINGS);
        assert_eq!(value["findingsTruncated"], true);
    }

    #[test]
    fn unknown_unreadable_oversized_and_binary_inputs_cannot_be_permitted() {
        let fixture = Fixture::new();
        let paths = [
            fixture.0.join("missing.txt"),
            fixture.0.clone(),
            fixture.write("large.txt", vec![b'a'; MAX_FILE_BYTES + 1]),
            fixture.write("binary.dat", [0xff, 0x00, 0xfe]),
            fixture.write("nul.txt", b"hello\0world"),
        ];
        for path in paths {
            let value = error_value(check_enabled(
                &mut GuardState::default(),
                true,
                "Send",
                "Agent",
                &[],
                &[path],
                Instant::now(),
            ));
            assert_eq!(value["canAllowOnce"], false);
            assert_eq!(value["token"], "");
        }
        let value = error_value(check_enabled(
            &mut GuardState::default(),
            true,
            "Send",
            "Agent",
            &[("Prompt", &"a".repeat(MAX_TRANSFER_BYTES + 1))],
            &[],
            Instant::now(),
        ));
        assert_eq!(value["canAllowOnce"], false);
    }

    #[cfg(unix)]
    #[test]
    fn symlink_files_and_parent_directories_are_rejected() {
        let fixture = Fixture::new();
        let original = fixture.write("original.txt", "plain");
        let link = fixture.0.join("link.txt");
        std::os::unix::fs::symlink(original, &link).unwrap();
        assert!(read_bounded(&link, MAX_FILE_BYTES).is_err());
        let directory = fixture.0.join("alias");
        std::os::unix::fs::symlink(&fixture.0, &directory).unwrap();
        assert!(read_bounded(&directory.join("original.txt"), MAX_FILE_BYTES).is_err());
    }
}
