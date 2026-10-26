//! Optional, anonymous external liveness evidence. Never in the mission path.
//! The service's bearer links and preference stay on this machine, not in Git
//! or the synchronized project. No prompts, paths, models or names are sent.
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{fs, io::Write, path::{Path, PathBuf}, sync::Mutex, time::Duration};

const BASE: &str = "https://aisenseapi.com/services/v1";
// Stop extending deadlines before the first-request inbox expires. Reserve
// the seven-minute absence window plus a minute for delivery; availability
// still depends on the service, so this is not a delivery guarantee.
const EXPIRY_MARGIN_SECONDS: u64 = 480;
static SERIAL: Mutex<()> = Mutex::new(());

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Watch {
    enabled: bool,
    state: String,
    capture_id: Option<String>,
    heartbeat_id: Option<String>,
    expires_at: u64,
    last_confirmed: u64,
    next_attempt: u64,
    note: String,
}

impl Default for Watch {
    fn default() -> Self {
        Self { enabled: true, state: "ready".into(), capture_id: None, heartbeat_id: None,
            expires_at: 0, last_confirmed: 0, next_attempt: 0,
            note: "Klar for en anonym ekstern 24-timersvakt. Ingen prosjektdata sendes.".into() }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct View {
    enabled: bool,
    state: String,
    note: String,
    expires_at: u64,
    last_confirmed: u64,
    read_url: Option<String>,
    status_url: Option<String>,
}

fn now() -> u64 { super::now_unix_ms() / 1000 }
fn capture_id(id: &str) -> bool {
    id.len() == 36 && id.bytes().enumerate().all(|(i,b)| {
        if [8,13,18,23].contains(&i) { b == b'-' } else { b.is_ascii_hexdigit() }
    })
}
fn heartbeat_id(id: &str) -> bool { id.len() == 64 && id.bytes().all(|b| b.is_ascii_hexdigit()) }
fn state_path() -> Result<PathBuf, String> {
    let root = std::env::var_os("LOCALAPPDATA").map(PathBuf::from)
        .filter(|p| p.is_absolute()).ok_or("Lokal appmappe mangler. Ekstern vakt er ikke startet.")?;
    Ok(root.join("AgentSyncMax").join("external-watch.json"))
}

fn load(path: &Path) -> Result<Watch, String> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(m) => m,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Watch::default()),
        Err(_) => return Err("Kan ikke lese driftsvaktens lokale innstilling. Ingen nettaktivitet.".into()),
    };
    super::storage_safety::validate_stored_path(path, &metadata, true)?;
    if !metadata.is_file() || metadata.len() > 16_384 { return Err("Ugyldig lokal driftsvaktfil.".into()); }
    let watch: Watch = serde_json::from_slice(&fs::read(path).map_err(|_| "Kan ikke lese driftsvaktfilen.")?)
        .map_err(|_| "Skadet driftsvaktfil. Filen er bevart og ingen nettaktivitet startet.")?;
    if watch.capture_id.as_deref().is_some_and(|id| !capture_id(id))
        || watch.heartbeat_id.as_deref().is_some_and(|id| !heartbeat_id(id)) {
        return Err("Ugyldig driftsvaktidentifikator. Ingen nettaktivitet.".into());
    }
    Ok(watch)
}

fn save(path: &Path, watch: &Watch) -> Result<(), String> {
    let parent = path.parent().ok_or("Lokal appmappe mangler.")?;
    fs::create_dir_all(parent).map_err(|_| "Kan ikke opprette lokal driftsvaktmappe.")?;
    if let Ok(metadata) = fs::symlink_metadata(path) {
        super::storage_safety::validate_stored_path(path, &metadata, true)?;
    }
    let temp = path.with_extension(format!("{}.tmp", std::process::id()));
    // Only clean up a temporary file this invocation actually created. A stale
    // file or another writer's file must never be deleted after create_new fails.
    let mut file = fs::OpenOptions::new().write(true).create_new(true).open(&temp)
        .map_err(|_| "Kan ikke sikre lokal driftsvaktfil.")?;
    let result: Result<(), String> = (|| {
        file.write_all(&serde_json::to_vec(watch).map_err(|_| "Kan ikke kode driftsvaktfil.")?)
            .and_then(|_| file.sync_all()).map_err(|_| "Kan ikke lagre driftsvaktfil.")?;
        drop(file);
        fs::rename(&temp, path).map_err(|_| "Kan ikke publisere driftsvaktfil.".into())
    })();
    if result.is_err() { let _ = fs::remove_file(&temp); }
    result
}

fn view(watch: Watch, time: u64) -> View {
    let expired = watch.expires_at > 0 && time >= watch.expires_at;
    let stale = watch.state == "active"
        && (watch.last_confirmed == 0 || time.saturating_sub(watch.last_confirmed) > 420);
    View {
        enabled: watch.enabled,
        state: if !watch.enabled { "disabled".into() } else if expired { "expired".into() } else if stale { "offline".into() } else { watch.state },
        note: if !watch.enabled {
            "Av lokalt. Ingen nye kall. En allerede opprettet ekstern vakt kan fortsatt registrere fravær frem til den utløper.".into()
        } else if expired { "24-timersvinduet er utløpt. Start en ny vakt hvis du ønsker en ny delbar lenke.".into() }
        else if stale { "Ingen fersk bekreftelse av prosessens livstegn. Aktiv ekstern vakt er ikke bekreftet. Lokal drift fortsetter.".into() }
        else { watch.note },
        expires_at: watch.expires_at, last_confirmed: watch.last_confirmed,
        read_url: watch.capture_id.map(|id| format!("{BASE}/webhook_capture/{id}")),
        status_url: watch.heartbeat_id.map(|id| format!("{BASE}/heartbeat/{id}")),
    }
}

pub(crate) fn status() -> Result<View, String> { Ok(view(load(&state_path()?)?, now())) }

pub(crate) fn configure(enabled: bool, new_window: bool) -> Result<View, String> {
    let _guard = SERIAL.lock().map_err(|_| "Driftsvakten er opptatt.")?;
    let path = state_path()?;
    configure_in(&path, now(), enabled, new_window)
}

fn configure_in(path: &Path, time: u64, enabled: bool, new_window: bool) -> Result<View, String> {
    let mut watch = load(path)?;
    // Changing the preference is not authority to silently replace a live
    // window or lose its bearer link. Restart is an explicit, separate action.
    if new_window {
        if watch.state == "active" && time < watch.expires_at {
            return Err("En vakt er fortsatt aktiv. Behold den til vinduet er utløpt.".into());
        }
        watch = Watch::default();
    }
    watch.enabled = enabled;
    save(path, &watch)?;
    Ok(view(watch, time))
}

// Restrict every URL to our fixed service and validated identifiers. Tokens go
// through stdin, never argv or an error message. No curlrc, redirects or retry.
#[derive(Debug)]
enum RequestError {
    Unavailable(String),
    Terminal(u16),
}

impl RequestError {
    fn message(&self) -> String {
        match self {
            Self::Unavailable(message) => message.clone(),
            Self::Terminal(code) => format!("AI Sense svarte HTTP {code}. Denne vakten kan ikke fortsette. Lokal drift fortsetter."),
        }
    }
}

impl From<&str> for RequestError {
    fn from(message: &str) -> Self { Self::Unavailable(message.into()) }
}

fn parse_response(stdout: &str) -> Result<Value, RequestError> {
    let (body, code) = stdout.rsplit_once("\nASMAX_HTTP:").ok_or("Ufullstendig svar fra AI Sense.")?;
    let code: u16 = code.trim().parse().map_err(|_| "Ugyldig HTTP-status fra AI Sense.")?;
    if matches!(code, 404 | 409 | 410) { return Err(RequestError::Terminal(code)); }
    if !matches!(code, 200 | 201) {
        return Err(RequestError::Unavailable(format!("AI Sense svarte HTTP {code}. Lokal drift fortsetter.")));
    }
    let value: Value = serde_json::from_str(body).map_err(|_| "Uleselig svar fra AI Sense.")?;
    if value.get("ok").and_then(Value::as_bool) != Some(true) { return Err("AI Sense bekreftet ikke handlingen.".into()); }
    Ok(value)
}

fn request(path: &str, data: Option<Value>) -> Result<Value, RequestError> {
    let url = format!("{BASE}/{path}");
    let method = if data.is_some() { "POST" } else { "GET" };
    let mut input = format!("url = {}\nrequest = \"{method}\"\n", serde_json::to_string(&url).unwrap());
    if let Some(data) = data {
        input.push_str("header = \"Content-Type: application/json\"\n");
        input.push_str(&format!("data = {}\n", serde_json::to_string(&data.to_string()).unwrap()));
    }
    let mut cmd = super::curl_command();
    cmd.args(["-q", "--silent", "--show-error", "--proto", "=https", "--connect-timeout", "2", "--max-time", "5", "--max-filesize", "65536", "--config", "-", "--write-out", "\nASMAX_HTTP:%{http_code}"]);
    let output = super::process_io::capture_with_input(&mut cmd, input.into_bytes(), Duration::from_secs(7), 65_536)
        .map_err(|_| "AI Sense svarer ikke. Lokal drift fortsetter.")?;
    if !output.status.success() || output.truncated { return Err("AI Sense svarer ikke brukbart. Lokal drift fortsetter.".into()); }
    parse_response(&output.stdout)
}

fn tick_with(path: &Path, time: u64, mut call: impl FnMut(&str, Option<Value>) -> Result<Value, RequestError>) -> Result<(), String> {
    let mut watch = load(path)?;
    if !watch.enabled || time < watch.next_attempt || (watch.expires_at > 0 && time >= watch.expires_at) { return Ok(()); }
    if matches!(watch.state.as_str(), "creating" | "uncertain" | "attention") { return Ok(()); }
    if watch.heartbeat_id.is_none() {
        // Write intent first. If the server accepts a POST but its reply or our
        // final save is lost, a restart must not provision duplicate monitors.
        watch.state = "creating".into();
        watch.note = "Oppretter ekstern vakt. Ved ukjent utfall må du velge et nytt forsøk selv.".into();
        save(path, &watch)?;
        let result = (|| {
            let capture = call("webhook_capture", Some(json!({}))).map_err(|error| error.message())?;
            let id = capture.get("capture_id").and_then(Value::as_str).filter(|id| capture_id(id)).ok_or("Ugyldig mottakersvar.")?;
            let capture_expiry = capture.get("expire_timestamp").and_then(Value::as_u64).filter(|t| *t > time + 600).ok_or("Mottakeren har ingen brukbar levetid.")?;
            watch.capture_id = Some(id.into());
            watch.expires_at = capture_expiry;
            save(path, &watch)?;
            let heartbeat = call("heartbeat", Some(json!({
                "expect_every_seconds": 300, "grace_seconds": 120,
                "on_miss": { "url": format!("{BASE}/webhook_capture/{id}/update"),
                    "payload": { "event": "max_check_in_missing", "meaning": "No MAX check-in; the app may be closed or disconnected. Not proof of a crash." } }
            }))).map_err(|error| error.message())?;
            let id = heartbeat.get("heartbeat_id").and_then(Value::as_str).filter(|id| heartbeat_id(id)).ok_or("Ugyldig vaktsvar.")?;
            if heartbeat.get("status").and_then(Value::as_str) != Some("armed") { return Err("Vakttjenesten er ikke armert.".into()); }
            watch.heartbeat_id = Some(id.into());
            watch.expires_at = watch.expires_at.min(heartbeat.get("expires_at_timestamp").and_then(Value::as_u64).filter(|t| *t > time + 600).ok_or("Vakten har ingen brukbar levetid.")?).saturating_sub(EXPIRY_MARGIN_SECONDS);
            watch.last_confirmed = time;
            watch.state = "active".into();
            watch.note = "AI Sense mottar livstegn fra prosessen, ikke en helsesjekk av vinduet eller synkemotoren. Manglende kontakt kan registreres eksternt etter omtrent 7 minutter; det kan også bety at appen er lukket.".into();
            Ok::<_, String>(())
        })();
        if let Err(error) = result {
            watch.state = "uncertain".into();
            watch.note = format!("{error} Opprettelsen er ikke bekreftet. Ingen automatisk gjentakelse.");
        }
    } else {
        let id = watch.heartbeat_id.as_deref().unwrap();
        match call(&format!("heartbeat/{id}/ping"), Some(json!({}))) {
            Ok(reply) if reply.get("heartbeat_id").and_then(Value::as_str) == Some(id)
                && reply.get("status").and_then(Value::as_str) == Some("armed") => {
                watch.last_confirmed = time;
                watch.state = "active".into();
                watch.note = "Prosessens siste livstegn er bekreftet av AI Sense. Dette bekrefter ikke helsen til vinduet eller synkemotoren. Lokal drift er uavhengig av vakten.".into();
            }
            Ok(_) => { watch.state = "attention".into(); watch.note = "Ekstern vakt er ikke lenger bekreftet aktiv. Les hendelseslenken før du oppretter en ny.".into(); }
            Err(error @ RequestError::Terminal(_)) => {
                // A missed deadline is terminal in the service, even when this
                // machine is online again. Preserve both links for inspection;
                // only an explicit new-window action may provision a replacement.
                watch.state = "attention".into();
                watch.note = format!("{} Les hendelseslenken før du oppretter en ny vakt.", error.message());
            }
            Err(error) => { watch.state = "offline".into(); watch.note = error.message(); }
        }
    }
    watch.next_attempt = time.saturating_add(60);
    save(path, &watch)
}

pub(crate) fn start() {
    std::thread::spawn(|| loop {
        // Isolated worker: startup, missions, UI and local Spark never await it.
        std::thread::sleep(Duration::from_secs(30));
        let Ok(_guard) = SERIAL.try_lock() else { continue; };
        if let Ok(path) = state_path() { let _ = tick_with(&path, now(), request); }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("asmax-watch-{}-{}-{name}", std::process::id(), super::super::now_unix_ms()));
        fs::create_dir_all(&dir).unwrap(); dir.join("watch.json")
    }
    const CAPTURE: &str = "12345678-1234-1234-1234-123456789abc";
    const HEART: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    fn active_watch() -> Watch {
        Watch { state: "active".into(), capture_id: Some(CAPTURE.into()),
            heartbeat_id: Some(HEART.into()), expires_at: 5000, last_confirmed: 100,
            ..Watch::default() }
    }

    #[test]
    fn http_parser_requires_confirmation_and_keeps_terminal_codes_without_server_details() {
        for code in [404, 409, 410] {
            let reply = format!("{{\"error\":\"private_url_token\"}}\nASMAX_HTTP:{code}\n");
            let error = parse_response(&reply).unwrap_err();
            assert!(matches!(error, RequestError::Terminal(actual) if actual == code));
            assert!(!error.message().contains("private_url_token"));
        }
        assert!(matches!(parse_response("unavailable\nASMAX_HTTP:503\n"), Err(RequestError::Unavailable(_))));
        for body in ["{}", "{\"ok\":false}", "{\"ok\":\"true\"}", "not-json"] {
            assert!(parse_response(&format!("{body}\nASMAX_HTTP:200\n")).is_err());
        }
        let created = json!({"ok":true,"capture_id":CAPTURE,"status":"pending","expire_timestamp":5000});
        assert_eq!(parse_response(&format!("{created}\nASMAX_HTTP:200\n")).unwrap(), created);
        let armed = json!({"ok":true,"heartbeat_id":HEART,"status":"armed","expires_at_timestamp":5100});
        for code in [200, 201] {
            assert_eq!(parse_response(&format!("{armed}\nASMAX_HTTP:{code}\n")).unwrap(), armed);
        }
    }

    #[test]
    fn terminal_ping_keeps_links_and_stops_calls_until_explicit_restart() {
        for code in [404, 409, 410] {
            let path = fixture(&format!("terminal-{code}"));
            save(&path, &active_watch()).unwrap();
            // The service rejects pings after seven minutes without a check-in.
            tick_with(&path, 600, |_,_| parse_response(&format!("{{\"error\":\"missed\"}}\nASMAX_HTTP:{code}\n"))).unwrap();
            let stopped = load(&path).unwrap();
            assert_eq!(stopped.state, "attention");
            assert_eq!(stopped.heartbeat_id.as_deref(), Some(HEART));
            assert_eq!(stopped.capture_id.as_deref(), Some(CAPTURE));
            assert_eq!(stopped.last_confirmed, 100);
            tick_with(&path, 700, |_,_| panic!("terminal monitor must not be pinged again")).unwrap();
            configure_in(&path, 710, false, false).unwrap();
            configure_in(&path, 720, true, false).unwrap();
            tick_with(&path, 730, |_,_| panic!("off/on is not authority for a replacement")).unwrap();
            let reset = configure_in(&path, 740, true, true).unwrap();
            assert_eq!(reset.state, "ready");
            assert!(reset.read_url.is_none());
            let mut calls = 0;
            tick_with(&path, 750, |_,_| { calls += 1; Err("offline".into()) }).unwrap();
            assert_eq!(calls, 1);
            fs::remove_dir_all(path.parent().unwrap()).unwrap();
        }
    }

    #[test]
    fn stale_confirmation_is_never_reported_as_current_activity() {
        assert_eq!(view(active_watch(), 520).state, "active");
        let stale = view(active_watch(), 521);
        assert_eq!(stale.state, "offline");
        assert_eq!(stale.last_confirmed, 100);
        assert!(stale.note.contains("ikke bekreftet"));
        let mut watch = active_watch(); watch.enabled = false;
        assert_eq!(view(watch, 1000).state, "disabled");
        assert_eq!(view(active_watch(), 6000).state, "expired");
    }

    #[test]
    fn temp_collision_preserves_both_existing_files() {
        let path = fixture("temp-owner");
        save(&path, &active_watch()).unwrap();
        let previous = fs::read(&path).unwrap();
        let temp = path.with_extension(format!("{}.tmp", std::process::id()));
        fs::write(&temp, b"retained foreign temporary data").unwrap();
        assert!(save(&path, &Watch::default()).is_err());
        assert_eq!(fs::read(&path).unwrap(), previous);
        assert_eq!(fs::read(&temp).unwrap(), b"retained foreign temporary data");
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn default_is_available_but_disabled_and_corrupt_state_never_make_network_calls() {
        let path = fixture("off");
        assert!(load(&path).unwrap().enabled);
        save(&path, &Watch { enabled: false, ..Watch::default() }).unwrap();
        tick_with(&path, 100, |_,_| panic!("disabled must be inert")).unwrap();
        fs::write(&path, b"broken").unwrap();
        assert!(tick_with(&path, 100, |_,_| panic!("corrupt must fail closed")).is_err());
        assert_eq!(fs::read(&path).unwrap(), b"broken");
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn unknown_creation_outcome_is_durable_and_never_retried_automatically() {
        let path = fixture("uncertain"); let mut calls = 0;
        tick_with(&path, 100, |_,_| { calls += 1; Err("timeout".into()) }).unwrap();
        tick_with(&path, 200, |_,_| panic!("no duplicate POST")).unwrap();
        assert_eq!(calls, 1); assert_eq!(load(&path).unwrap().state, "uncertain");
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn create_ping_outage_recovery_and_expiry_keep_honest_state() {
        let path = fixture("life");
        tick_with(&path, 100, |url, payload| {
            if url == "webhook_capture" { Ok(json!({"capture_id": CAPTURE, "expire_timestamp": 5000})) }
            else { assert_eq!(url, "heartbeat"); let data = payload.unwrap();
                assert_eq!(data["on_miss"]["url"], format!("{BASE}/webhook_capture/{CAPTURE}/update"));
                assert!(!data.to_string().contains("project"));
                Ok(json!({"heartbeat_id": HEART, "status": "armed", "expires_at_timestamp": 5100})) }
        }).unwrap();
        assert_eq!(load(&path).unwrap().state, "active");
        assert_eq!(load(&path).unwrap().expires_at, 5000 - EXPIRY_MARGIN_SECONDS);
        tick_with(&path, 110, |_,_| panic!("backoff")).unwrap();
        tick_with(&path, 200, |_,_| Err("offline".into())).unwrap();
        let offline = load(&path).unwrap(); assert_eq!(offline.state, "offline"); assert_eq!(offline.last_confirmed, 100);
        tick_with(&path, 270, |url,_| { assert!(url.ends_with("/ping")); Ok(json!({"heartbeat_id": HEART, "status": "armed"})) }).unwrap();
        assert_eq!(load(&path).unwrap().last_confirmed, 270);
        let last_possible_ping = load(&path).unwrap().expires_at - 1;
        assert!(last_possible_ping + 420 < 5000, "the last deadline must precede inbox expiry");
        tick_with(&path, 5000 - EXPIRY_MARGIN_SECONDS, |_,_| panic!("do not extend beyond the receiver lifetime")).unwrap();
        tick_with(&path, 6000, |_,_| panic!("no automatic renewal or extra monitor")).unwrap();
        assert_eq!(view(load(&path).unwrap(), 6000).state, "expired");
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }
}
