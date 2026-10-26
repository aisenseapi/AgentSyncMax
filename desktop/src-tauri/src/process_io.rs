//! Bounded supervised subprocess I/O. No provider-specific parsing lives here.
use std::io::{Read, Write};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

const MAX_LINE: usize = 256 * 1024;
const QUEUE_LINES: usize = 32;

pub(crate) struct OutputLine {
    pub stderr: bool,
    pub text: String,
    pub truncated: bool,
}

pub(crate) struct RunResult {
    pub status: ExitStatus,
    pub canceled: bool,
    pub timed_out: bool,
    pub input_error: Option<String>,
    pub output_truncated: bool,
}

#[cfg(windows)]
struct ProcessGroup(windows_sys::Win32::Foundation::HANDLE);

#[cfg(windows)]
impl ProcessGroup {
    fn new() -> Result<Self, String> {
        use windows_sys::Win32::System::JobObjects::*;
        let job = unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) };
        if job.is_null() {
            return Err(format!(
                "Kan ikke opprette prosessgruppen: {}",
                std::io::Error::last_os_error()
            ));
        }
        let result = Self(job);
        let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = unsafe { std::mem::zeroed() };
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if unsafe {
            SetInformationJobObject(
                job,
                JobObjectExtendedLimitInformation,
                &info as *const _ as *const _,
                std::mem::size_of_val(&info) as u32,
            )
        } == 0
        {
            return Err(format!(
                "Kan ikke sikre prosessgruppens levetid: {}",
                std::io::Error::last_os_error()
            ));
        }
        Ok(result)
    }
    fn attach_and_resume(&self, child: &Child) -> Result<(), String> {
        use std::os::windows::io::AsRawHandle;
        use windows_sys::Win32::Foundation::{CloseHandle, INVALID_HANDLE_VALUE};
        use windows_sys::Win32::System::Diagnostics::ToolHelp::*;
        use windows_sys::Win32::System::JobObjects::AssignProcessToJobObject;
        use windows_sys::Win32::System::Threading::{
            OpenThread, ResumeThread, THREAD_SUSPEND_RESUME,
        };
        if unsafe { AssignProcessToJobObject(self.0, child.as_raw_handle() as _) } == 0 {
            return Err(format!(
                "Kan ikke knytte barnet til den sikre prosessgruppen: {}",
                std::io::Error::last_os_error()
            ));
        }
        // The child was created suspended, so it cannot spawn unsupervised
        // descendants before assignment to its kill-on-close job.
        let snapshot = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0) };
        if snapshot == INVALID_HANDLE_VALUE {
            return Err("Kan ikke finne oppstartstråden til prosessen.".into());
        }
        let mut entry: THREADENTRY32 = unsafe { std::mem::zeroed() };
        entry.dwSize = std::mem::size_of_val(&entry) as u32;
        let mut found = false;
        let mut next = unsafe { Thread32First(snapshot, &mut entry) };
        while next != 0 {
            if entry.th32OwnerProcessID == child.id() {
                let handle = unsafe { OpenThread(THREAD_SUSPEND_RESUME, 0, entry.th32ThreadID) };
                if !handle.is_null() {
                    found |= unsafe { ResumeThread(handle) } != u32::MAX;
                    unsafe { CloseHandle(handle) };
                }
            }
            next = unsafe { Thread32Next(snapshot, &mut entry) };
        }
        unsafe { CloseHandle(snapshot) };
        if found {
            Ok(())
        } else {
            Err("Kunne ikke fortsette den sikrede agentprosessen.".into())
        }
    }
    fn terminate(&self) {
        unsafe { windows_sys::Win32::System::JobObjects::TerminateJobObject(self.0, 1) };
    }
}

#[cfg(windows)]
impl Drop for ProcessGroup {
    fn drop(&mut self) {
        unsafe { windows_sys::Win32::Foundation::CloseHandle(self.0) };
    }
}

#[cfg(not(windows))]
struct ProcessGroup;
#[cfg(not(windows))]
impl ProcessGroup {
    fn new() -> Result<Self, String> {
        Ok(Self)
    }
    fn attach_and_resume(&self, _child: &Child) -> Result<(), String> {
        Ok(())
    }
}

fn terminate_group(group: &ProcessGroup, child: &mut Child) {
    #[cfg(windows)]
    group.terminate();
    #[cfg(unix)]
    {
        let _ = group;
        extern "C" {
            fn kill(pid: i32, signal: i32) -> i32;
        }
        // Child is in its own group, established before exec below.
        unsafe { kill(-(child.id() as i32), 9) };
    }
    let _ = child.kill();
}

fn reader<R: Read + Send + 'static>(
    mut input: R,
    stderr: bool,
    sender: mpsc::SyncSender<OutputLine>,
    stop: Arc<AtomicBool>,
) -> JoinHandle<()> {
    thread::spawn(move || {
        let mut block = [0u8; 8192];
        let mut line = Vec::new();
        let mut oversized = false;
        loop {
            if stop.load(Ordering::Relaxed) {
                break;
            }
            let count = match input.read(&mut block) {
                Ok(0) => break,
                Ok(count) => count,
                Err(error) => {
                    if !stop.load(Ordering::Relaxed) {
                        let _ = sender.send(OutputLine {
                            stderr: true,
                            text: format!("AgentSync: kunne ikke lese prosessutdata: {error}"),
                            truncated: false,
                        });
                    }
                    break;
                }
            };
            for byte in &block[..count] {
                if *byte == b'\n' {
                    let text = if oversized {
                        "AgentSync: En svært stor utdatalinje ble hoppet over for å beskytte minnet. Se agentens originalhistorikk.".into()
                    } else {
                        String::from_utf8_lossy(&line)
                            .trim_end_matches('\r')
                            .to_string()
                    };
                    if sender
                        .send(OutputLine {
                            stderr: stderr || oversized,
                            text,
                            truncated: oversized,
                        })
                        .is_err()
                    {
                        return;
                    }
                    line.clear();
                    oversized = false;
                } else if line.len() < MAX_LINE {
                    line.push(*byte);
                } else {
                    oversized = true;
                }
            }
        }
        if !stop.load(Ordering::Relaxed) && (!line.is_empty() || oversized) {
            let text = if oversized {
                "AgentSync: En svært stor utdatalinje ble hoppet over; originalhistorikken er ikke endret.".into()
            } else {
                String::from_utf8_lossy(&line).into_owned()
            };
            let _ = sender.send(OutputLine {
                stderr: stderr || oversized,
                text,
                truncated: oversized,
            });
        }
    })
}

fn finish_workers(workers: Vec<JoinHandle<()>>, stop: &AtomicBool) -> bool {
    stop.store(true, Ordering::Relaxed);
    #[cfg(windows)]
    for worker in &workers {
        use std::os::windows::io::AsRawHandle;
        unsafe { windows_sys::Win32::System::IO::CancelSynchronousIo(worker.as_raw_handle() as _) };
    }
    let deadline = Instant::now() + Duration::from_secs(2);
    while workers.iter().any(|worker| !worker.is_finished()) && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(5));
    }
    let all_finished = workers.iter().all(JoinHandle::is_finished);
    for worker in workers {
        if worker.is_finished() {
            let _ = worker.join();
        }
        // A failed OS cancellation must not freeze the control path forever.
        // Channels are disconnected and process-group handles closed first.
    }
    all_finished
}

pub(crate) fn run<F: FnMut(OutputLine)>(
    command: &mut Command,
    input: Vec<u8>,
    timeout: Duration,
    cancel: &AtomicBool,
    mut emit: F,
) -> Result<RunResult, String> {
    let started = Instant::now();
    let group = ProcessGroup::new()?;
    command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x0800_0000 | 0x0000_0004);
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    let mut child = command
        .spawn()
        .map_err(|error| format!("Kunne ikke starte prosessen: {error}"))?;
    if let Err(error) = group.attach_and_resume(&child) {
        terminate_group(&group, &mut child);
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline {
            if !matches!(child.try_wait(), Ok(None)) {
                break;
            }
            thread::sleep(Duration::from_millis(10));
        }
        return Err(error);
    }
    let stop = Arc::new(AtomicBool::new(false));
    let (sender, receiver) = mpsc::sync_channel(QUEUE_LINES);
    let mut workers = Vec::new();
    if let Some(stdout) = child.stdout.take() {
        workers.push(reader(stdout, false, sender.clone(), stop.clone()));
    }
    if let Some(stderr) = child.stderr.take() {
        workers.push(reader(stderr, true, sender.clone(), stop.clone()));
    }
    drop(sender);
    let (input_sender, input_receiver) = mpsc::sync_channel(1);
    if let Some(mut stdin) = child.stdin.take() {
        workers.push(thread::spawn(move || {
            let _ = input_sender.send(stdin.write_all(&input).map_err(|error| error.to_string()));
        }));
    }
    let mut input_error = None;
    let mut input_confirmed = false;
    let mut canceled = false;
    let mut timed_out = false;
    let mut truncated = false;
    let mut termination_started = None;
    let status = loop {
        if cancel.load(Ordering::Relaxed) {
            canceled = true;
            terminate_group(&group, &mut child);
        } else if started.elapsed() >= timeout {
            timed_out = true;
            terminate_group(&group, &mut child);
        }
        if let Ok(result) = input_receiver.try_recv() {
            input_confirmed = true;
            if let Err(error) = result {
                input_error = Some(error);
                terminate_group(&group, &mut child);
            }
        }
        if canceled || timed_out || input_error.is_some() {
            let termination = termination_started.get_or_insert_with(Instant::now);
            if termination.elapsed() >= Duration::from_secs(2) {
                break Err("Operativsystemet bekreftet ikke prosessavslutningen innen fristen. Kontroller prosessene før du fortsetter.".into());
            }
        }
        // Bound the work per turn, so an endless output flood cannot starve
        // cancellation and timeout checks even when the queue remains full.
        for _ in 0..QUEUE_LINES {
            let Ok(line) = receiver.try_recv() else {
                break;
            };
            truncated |= line.truncated;
            emit(line);
            if started.elapsed() >= timeout || cancel.load(Ordering::Relaxed) {
                break;
            }
        }
        match child.try_wait() {
            Ok(Some(status)) => break Ok(status),
            Ok(None) => {}
            Err(error) => break Err(error.to_string()),
        }
        thread::sleep(Duration::from_millis(10));
    };
    // A mission's descendants belong to its lifecycle. Inherited open pipes
    // cannot keep the mission alive once its supervising CLI has exited.
    terminate_group(&group, &mut child);
    let drain_deadline = Instant::now() + Duration::from_millis(500);
    let mut drained = false;
    while Instant::now() < drain_deadline {
        match receiver.recv_timeout(Duration::from_millis(10)) {
            Ok(line) => {
                truncated |= line.truncated;
                emit(line);
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                drained = true;
                break;
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {
                if workers.iter().all(JoinHandle::is_finished) {
                    drained = true;
                    break;
                }
            }
        }
    }
    drop(receiver);
    if !drained {
        truncated = true;
        emit(OutputLine {stderr:true,text:"AgentSync: Resten av prosessutdata rakk ikke å tømmes innen avslutningsfristen. Originalhistorikken er ikke endret.".into(),truncated:true});
    }
    if !finish_workers(workers, &stop) {
        emit(OutputLine {stderr:true,text:"AgentSync: Operativsystemet bekreftet ikke at alle I/O-trådene avsluttet. Appen er responsiv, men en omstart bør vurderes etter at aktive oppdrag er ferdige.".into(),truncated:false});
    }
    if !input_confirmed {
        input_error = match input_receiver.try_recv() {
            Ok(Ok(())) => None,
            Ok(Err(error)) => Some(error),
            Err(_) => Some("Leveringen av prosessens inndata ble ikke bekreftet.".into()),
        };
    }
    Ok(RunResult {
        status: status?,
        canceled,
        timed_out,
        input_error,
        output_truncated: truncated,
    })
}

pub(crate) struct Capture {
    pub status: ExitStatus,
    pub stdout: String,
    pub stderr: String,
    pub truncated: bool,
}

pub(crate) fn capture(
    command: &mut Command,
    timeout: Duration,
    limit: usize,
) -> Result<Capture, String> {
    capture_with_input(command, Vec::new(), timeout, limit)
}

pub(crate) fn capture_with_input(
    command: &mut Command,
    input: Vec<u8>,
    timeout: Duration,
    limit: usize,
) -> Result<Capture, String> {
    let mut stdout = String::new();
    let mut stderr = String::new();
    let mut truncated = false;
    let result = run(command, input, timeout, &AtomicBool::new(false), |line| {
        truncated |= line.truncated;
        let target = if line.stderr {
            &mut stderr
        } else {
            &mut stdout
        };
        let remaining = limit.saturating_sub(target.len());
        if line.text.len() + 1 > remaining {
            truncated = true;
        }
        let mut end = line.text.len().min(remaining);
        while !line.text.is_char_boundary(end) {
            end -= 1;
        }
        target.push_str(&line.text[..end]);
        if target.len() < limit {
            target.push('\n');
        }
    })?;
    if result.timed_out {
        return Err(format!(
            "Prosessen brukte mer enn {} sekunder og ble stoppet.",
            timeout.as_secs()
        ));
    }
    if let Some(error) = result.input_error {
        return Err(format!("Prosessens inndata feilet: {error}"));
    }
    Ok(Capture {
        status: result.status,
        stdout,
        stderr,
        truncated: truncated || result.output_truncated,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture_command(kind: &str) -> Command {
        let mut command = Command::new(std::env::current_exe().unwrap());
        command
            .args([
                "process_io::tests::subprocess_fixture",
                "--exact",
                "--ignored",
                "--nocapture",
            ])
            .env("PROCESS_IO_FIXTURE", kind);
        command
    }
    #[test]
    #[ignore = "Synthetic child entry point only, never invoke against a provider"]
    // This fixture deliberately exits before its descendant; the outer test
    // verifies that our process group terminates the inherited pipe owner.
    #[allow(clippy::zombie_processes)]
    fn subprocess_fixture() {
        match std::env::var("PROCESS_IO_FIXTURE")
            .unwrap_or_default()
            .as_str()
        {
            "duplex" => {
                let block = vec![b'x'; 8192];
                for _ in 0..256 {
                    std::io::stdout().write_all(&block).unwrap();
                    std::io::stdout().write_all(b"\n").unwrap();
                }
                let mut input = Vec::new();
                std::io::stdin().read_to_end(&mut input).unwrap();
                println!("received={}", input.len());
            }
            "wait" => thread::sleep(Duration::from_secs(20)),
            "exit-without-reading" => {}
            "line" => {
                std::io::stdout()
                    .write_all(&vec![b'x'; MAX_LINE * 4])
                    .unwrap();
                println!();
            }
            "descendant" => {
                let mut child = fixture_command("wait");
                child.stdout(Stdio::inherit()).stderr(Stdio::inherit());
                let _ = child.spawn().unwrap();
            }
            _ => panic!("Missing synthetic fixture kind"),
        }
    }
    #[test]
    fn stdin_and_stdout_drain_concurrently() {
        let mut lines = Vec::new();
        let result = run(
            &mut fixture_command("duplex"),
            vec![b'a'; 2 * 1024 * 1024],
            Duration::from_secs(10),
            &AtomicBool::new(false),
            |line| {
                if line.text.starts_with("received=") {
                    lines.push(line.text);
                }
            },
        )
        .unwrap();
        assert!(result.status.success());
        assert!(lines.iter().any(|line| line == "received=2097152"));
        assert!(!result.timed_out);
    }
    #[test]
    fn blocked_input_obeys_deadline() {
        let started = Instant::now();
        let result = run(
            &mut fixture_command("wait"),
            vec![b'a'; 2 * 1024 * 1024],
            Duration::from_millis(250),
            &AtomicBool::new(false),
            |_| {},
        )
        .unwrap();
        assert!(result.timed_out);
        assert!(started.elapsed() < Duration::from_secs(4));
    }
    #[test]
    fn blocked_input_obeys_cancellation() {
        let cancel = Arc::new(AtomicBool::new(false));
        let signal = cancel.clone();
        let worker = thread::spawn(move || {
            thread::sleep(Duration::from_millis(100));
            signal.store(true, Ordering::Relaxed);
        });
        let result = run(
            &mut fixture_command("wait"),
            vec![b'a'; 2 * 1024 * 1024],
            Duration::from_secs(10),
            &cancel,
            |_| {},
        )
        .unwrap();
        worker.join().unwrap();
        assert!(result.canceled);
    }
    #[test]
    fn oversized_lines_are_flagged_and_bounded() {
        let mut longest = 0;
        let result = run(
            &mut fixture_command("line"),
            Vec::new(),
            Duration::from_secs(5),
            &AtomicBool::new(false),
            |line| {
                longest = longest.max(line.text.len());
            },
        )
        .unwrap();
        assert!(result.output_truncated);
        assert!(longest <= MAX_LINE);
    }
    #[test]
    fn inherited_pipe_does_not_keep_a_completed_parent_alive() {
        let started = Instant::now();
        let result = run(
            &mut fixture_command("descendant"),
            Vec::new(),
            Duration::from_secs(5),
            &AtomicBool::new(false),
            |_| {},
        )
        .unwrap();
        assert!(result.status.success());
        assert!(started.elapsed() < Duration::from_secs(4));
    }

    #[test]
    fn successful_exit_does_not_hide_unconsumed_input() {
        let result = run(
            &mut fixture_command("exit-without-reading"),
            vec![b'a'; 2 * 1024 * 1024],
            Duration::from_secs(5),
            &AtomicBool::new(false),
            |_| {},
        )
        .unwrap();
        assert!(result.input_error.is_some());
        assert!(!result.timed_out);
    }
}
