//! Unattended runs (`lbx --run`): every check before anything is created,
//! the name claim, two networks and a relay (or no network), the run box,
//! readiness, the command, cleanup of exactly what this run created, and
//! the outcome in `runs/<name>/status`.

use crate::cli::Options;
use crate::config::Resolved;
use crate::docker::{
    Docker, RUN_RELAY_IMAGE, RunBox, RunRelay, empty_proxy_env, relay_container_name,
    relay_egress_network_name, relay_network_name, run_box_argv, run_exec_argv, run_proxy_env,
    run_relay_argv,
};
use crate::status::{Outcome, RunStatus};
use crate::util::{err, path_str, path_within, realpath_e, realpath_m};
use std::collections::HashMap;
use std::os::unix::fs::{FileTypeExt, MetadataExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};

pub const RUN_NAME_MAX: usize = 128;
pub const RUN_TIMEOUT_MAX: u64 = 604_800;
const RESERVED: [&str; 30] = [
    "HOST_USER",
    "HOST_UID",
    "HOST_GID",
    "HOME",
    "PATH",
    "SHELL",
    "USER",
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "http_proxy",
    "https_proxy",
    "NO_PROXY",
    "no_proxy",
    "ALL_PROXY",
    "all_proxy",
    "FTP_PROXY",
    "ftp_proxy",
    "JAVA_TOOL_OPTIONS",
    "VM_WEB_PORT",
    "BASH_ENV",
    "ENV",
    "SHELLOPTS",
    "BASHOPTS",
    "PS4",
    "PROMPT_COMMAND",
    "GCONV_PATH",
    "LD_PRELOAD",
    "LD_LIBRARY_PATH",
    "LLMBOX_STATE_DIR",
    "LBX_STATE_DIR",
];

/// The first signal's exit code (130/143/129/138), 0 for none.
pub static SIGNAL: AtomicI32 = AtomicI32::new(0);
/// The run's own timer fired.
pub static TIMER: AtomicBool = AtomicBool::new(false);

extern "C" fn on_signal(sig: libc::c_int) {
    let code = match sig {
        libc::SIGINT => 130,
        libc::SIGTERM => 143,
        libc::SIGHUP => 129,
        libc::SIGUSR1 => 138,
        _ => return,
    };
    let _ = SIGNAL.compare_exchange(0, code, Ordering::SeqCst, Ordering::SeqCst);
}

/// Install the handlers the moment `--run` is seen.
pub fn install_signal_handlers() {
    for sig in [libc::SIGINT, libc::SIGTERM, libc::SIGHUP, libc::SIGUSR1] {
        // SAFETY: the handler only touches atomics.
        unsafe {
            let handler: extern "C" fn(libc::c_int) = on_signal;
            libc::signal(sig, handler as usize as libc::sighandler_t);
        }
    }
}

fn ignore_signals() {
    for sig in [libc::SIGINT, libc::SIGTERM, libc::SIGHUP, libc::SIGUSR1] {
        // SAFETY: SIG_IGN is a valid disposition.
        unsafe {
            libc::signal(sig, libc::SIG_IGN);
        }
    }
}

pub fn pending_signal() -> i32 {
    SIGNAL.load(Ordering::SeqCst)
}

/// What the name claim created, so a signal removes exactly that.
#[derive(Default)]
pub struct Claim {
    pub own_state: bool,
    pub own_runs: bool,
    pub own_claim_dir: Option<PathBuf>,
    pub own_claim: Option<PathBuf>,
}

impl Claim {
    /// Remove exactly what the claim created (a signal during the claim).
    pub fn release(&self, state_dir: &Path) {
        if let Some(c) = &self.own_claim {
            let _ = std::fs::remove_file(c);
        }
        if let Some(d) = &self.own_claim_dir {
            let _ = std::fs::remove_dir(d);
        }
        if self.own_runs {
            let _ = std::fs::remove_dir(state_dir.join("runs"));
        }
        if self.own_state {
            let _ = std::fs::remove_dir(state_dir);
        }
    }
}

/// How the refusal stage ends: nothing was created, nothing is written.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refusal {
    /// `ERROR: <message>` then `lbx-run: status=refused code=125`.
    Refused(String),
    /// A signal arrived during the checks: only `status=signal code=N`.
    Signal(i32),
}

impl Refusal {
    pub fn message(&self) -> Option<&str> {
        match self {
            Refusal::Refused(m) => Some(m),
            Refusal::Signal(_) => None,
        }
    }

    /// The outcome line.
    pub fn outcome(&self) -> Outcome {
        match self {
            Refusal::Refused(_) => Outcome {
                status: RunStatus::Refused,
                code: 125,
                cleanup_incomplete: false,
            },
            Refusal::Signal(code) => Outcome {
                status: RunStatus::Signal,
                code: *code,
                cleanup_incomplete: false,
            },
        }
    }

    pub fn exit_code(&self) -> i32 {
        self.outcome().code
    }
}

/// A refusal, unless a signal already decided the outcome.
pub fn refuse(msg: &str) -> Refusal {
    let sig = pending_signal();
    if sig != 0 {
        return Refusal::Signal(sig);
    }
    Refusal::Refused(msg.to_string())
}

/// Checked after every docker call during the checks: a signal ends the
/// run as that signal.
fn poll_refusal_signal() -> Result<(), Refusal> {
    let sig = pending_signal();
    if sig != 0 {
        return Err(Refusal::Signal(sig));
    }
    Ok(())
}

/// The status line for a refusal whose message was already printed.
pub fn refusal_status_exit() -> ! {
    refusal_exit(&refuse(""))
}

/// The refusal stage's exit: the message, then the status line last.
pub fn refusal_exit(r: &Refusal) -> ! {
    ignore_signals();
    if let Some(m) = r.message().filter(|m| !m.is_empty()) {
        err(&format!("\nERROR: {m}"));
    }
    err(&format!("\nlbx-run: {}", r.outcome().format()));
    std::process::exit(r.exit_code());
}
pub struct Checked {
    pub timeout: u64,
    pub data_abs: String,
    pub socket_abs: String,
    pub apparmor_profile: String,
}

struct Walked {
    entries: Vec<(PathBuf, std::fs::Metadata)>,
    first_error: Option<String>,
}

fn walk(root: &Path, max_depth: Option<usize>) -> Walked {
    let mut w = Walked {
        entries: Vec::new(),
        first_error: None,
    };
    let mut stack: Vec<(PathBuf, usize)> = vec![(root.to_path_buf(), 1)];
    while let Some((dir, depth)) = stack.pop() {
        if max_depth.is_some_and(|m| depth > m) {
            continue;
        }
        let rd = match std::fs::read_dir(&dir) {
            Ok(rd) => rd,
            Err(e) => {
                if w.first_error.is_none() {
                    w.first_error = Some(format!("find: '{}': {}", path_str(&dir), os_msg(&e)));
                }
                continue;
            }
        };
        let mut items: Vec<_> = rd.collect();
        items.sort_by_key(|r| r.as_ref().ok().map(|e| e.file_name()));
        for item in items {
            let entry = match item {
                Ok(e) => e,
                Err(e) => {
                    if w.first_error.is_none() {
                        w.first_error = Some(format!("find: '{}': {}", path_str(&dir), os_msg(&e)));
                    }
                    continue;
                }
            };
            let p = entry.path();
            match std::fs::symlink_metadata(&p) {
                Ok(m) => {
                    if m.is_dir() {
                        stack.push((p.clone(), depth + 1));
                    }
                    w.entries.push((p, m));
                }
                Err(e) => {
                    if w.first_error.is_none() {
                        w.first_error = Some(format!("find: '{}': {}", path_str(&p), os_msg(&e)));
                    }
                }
            }
        }
    }
    w.entries.sort_by(|a, b| a.0.cmp(&b.0));
    w
}

fn os_msg(e: &std::io::Error) -> String {
    let s = e.to_string();
    match s.find(" (os error") {
        Some(i) => s[..i].to_string(),
        None => s,
    }
}

/// The launcher's own directories, "<label>|<path>" (empty path = none).
pub fn launcher_dirs(cfg: &Resolved, net_policy: &str) -> Vec<(String, String)> {
    let home = crate::util::home_dir();
    let mut v = vec![(
        "state directory".to_string(),
        path_str(&realpath_m(&cfg.state_dir)),
    )];
    let cfg_dir = cfg
        .path
        .parent()
        .map(|p| path_str(&realpath_m(p)))
        .unwrap_or_default();
    v.push(("configuration directory".into(), cfg_dir));
    let shipped = home.join(".config/llm_in_a_box");
    v.push((
        "configuration directory".into(),
        if shipped.is_dir() {
            realpath_e(&shipped)
                .map(|p| path_str(&p))
                .unwrap_or_default()
        } else {
            String::new()
        },
    ));
    v.push((
        "policy file's directory".into(),
        if !net_policy.is_empty() {
            realpath_e(Path::new(net_policy))
                .and_then(|p| p.parent().map(path_str))
                .unwrap_or_default()
        } else {
            String::new()
        },
    ));
    let artifact = std::env::current_dir()
        .unwrap_or_default()
        .join("vms_and_docker_from_llm_box");
    v.push((
        "vm artifact directory".into(),
        if artifact.is_dir() {
            realpath_e(&artifact)
                .map(|p| path_str(&p))
                .unwrap_or_default()
        } else {
            String::new()
        },
    ));
    v
}

fn mountinfo_points() -> Vec<String> {
    let text = std::fs::read_to_string("/proc/self/mountinfo").unwrap_or_default();
    text.lines()
        .filter_map(|l| l.split(' ').nth(4).map(unescape_octal))
        .collect()
}

fn unescape_octal(s: &str) -> String {
    let b = s.as_bytes();
    let mut outb = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'\\'
            && i + 3 < b.len()
            && i + 3 <= b.len() - 1 + 1
            && let (Some(a), Some(c), Some(d)) = (b.get(i + 1), b.get(i + 2), b.get(i + 3))
            && a.is_ascii_digit()
            && c.is_ascii_digit()
            && d.is_ascii_digit()
        {
            let v = (a - b'0') * 64 + (c - b'0') * 8 + (d - b'0');
            outb.push(v);
            i += 4;
            continue;
        }
        outb.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&outb).into_owned()
}

/// The data-directory rules.
pub fn data_checks(
    cfg: &Resolved,
    given: &str,
    net_policy: &str,
    host_uid: u32,
) -> Result<String, Refusal> {
    let gp = Path::new(given);
    if !gp.exists() {
        return Err(refuse(&format!("data directory {given} does not exist.")));
    }
    if !gp.is_dir() {
        return Err(refuse(&format!(
            "data directory {given} is not a directory."
        )));
    }
    let d = match realpath_e(gp) {
        Some(p) => path_str(&p),
        None => return Err(refuse(&format!("data directory {given} cannot be read."))),
    };
    let meta = match std::fs::metadata(&d) {
        Ok(m) => m,
        Err(_) => return Err(refuse(&format!("data directory {d} cannot be read."))),
    };
    if meta.uid() != host_uid {
        return Err(refuse(&format!(
            "data directory {d} is not owned by the invoking user."
        )));
    }
    let home = path_str(&realpath_m(&crate::util::home_dir()));
    if d == home {
        return Err(refuse(&format!(
            "data directory {d} is the home directory."
        )));
    }
    if path_within(&home, &d) {
        return Err(refuse(&format!(
            "data directory {d} is an ancestor of the home directory."
        )));
    }
    for (label, target) in launcher_dirs(cfg, net_policy) {
        if target.is_empty() {
            continue;
        }
        if path_within(&d, &target) || path_within(&target, &d) {
            return Err(refuse(&format!(
                "data directory {d} overlaps the {label} ({target})."
            )));
        }
    }
    if path_within(&d, &home) {
        return Err(refuse(&format!(
            "data directory {d} is inside the home directory."
        )));
    }
    let w = walk(Path::new(&d), None);
    if let Some(e) = &w.first_error {
        return Err(refuse(&format!(
            "data directory {d} has entries that cannot be read ({e})."
        )));
    }
    if let Some((p, _)) = w
        .entries
        .iter()
        .find(|(p, _)| p.file_name().is_some_and(|n| n == ".git"))
    {
        return Err(refuse(&format!(
            "data directory {d} contains .git ({}).",
            path_str(p)
        )));
    }
    if let Some((p, _)) = w.entries.iter().find(|(_, m)| m.file_type().is_symlink()) {
        return Err(refuse(&format!(
            "data directory {d} contains a symbolic link ({}).",
            path_str(p)
        )));
    }
    if let Some((p, _)) = w.entries.iter().find(|(_, m)| m.uid() != host_uid) {
        return Err(refuse(&format!(
            "data directory {d} contains an entry owned by another user ({}).",
            path_str(p)
        )));
    }
    for (p, m) in &w.entries {
        let ft = m.file_type();
        if ft.is_socket() {
            return Err(refuse(&format!(
                "data directory {d} contains a socket ({}).",
                path_str(p)
            )));
        }
        if ft.is_fifo() {
            return Err(refuse(&format!(
                "data directory {d} contains a named pipe ({}).",
                path_str(p)
            )));
        }
        if ft.is_block_device() || ft.is_char_device() {
            return Err(refuse(&format!(
                "data directory {d} contains a device file ({}).",
                path_str(p)
            )));
        }
    }
    // Hard links out of the tree.
    let mut names_in: HashMap<(u64, u64), (u64, u64, PathBuf)> = HashMap::new();
    for (p, m) in &w.entries {
        if m.is_file() && m.nlink() > 1 {
            let e = names_in
                .entry((m.dev(), m.ino()))
                .or_insert((0, m.nlink(), p.clone()));
            e.0 += 1;
        }
    }
    let mut keys: Vec<_> = names_in.values().collect();
    keys.sort_by(|a, b| a.2.cmp(&b.2));
    for (count, nlink, first) in keys {
        if count < nlink {
            return Err(refuse(&format!(
                "data directory {d} contains a file with a hard link outside it ({}).",
                path_str(first)
            )));
        }
    }
    // Mount points: device numbers and mountinfo.
    let dev = meta.dev();
    for (p, m) in &w.entries {
        if m.is_dir() && m.dev() != dev {
            return Err(refuse(&format!(
                "data directory {d} contains a mount point ({}).",
                path_str(p)
            )));
        }
    }
    for mp in mountinfo_points() {
        if mp != d && path_within(&mp, &d) {
            return Err(refuse(&format!(
                "data directory {d} contains a mount point ({mp})."
            )));
        }
    }
    Ok(d)
}

/// The socket-directory rules (`--socket-dir`).
pub fn socket_dir_checks(
    cfg: &Resolved,
    dirs: &[String],
    data_abs: &str,
    net_policy: &str,
    host_uid: u32,
) -> Result<String, Refusal> {
    if dirs.len() > 1 {
        return Err(refuse(
            "socket directory: --socket-dir is given more than once.",
        ));
    }
    let mut given = dirs.first().cloned().unwrap_or_default();
    if !given.is_empty() {
        while given.len() > 1 {
            if let Some(s) = given.strip_suffix('/') {
                given = s.to_string();
            } else if let Some(s) = given.strip_suffix("/.") {
                given = s.to_string();
            } else {
                break;
            }
        }
        if given.is_empty() {
            given = "/".into();
        }
    }
    let gp = Path::new(&given);
    if std::fs::symlink_metadata(gp).is_ok_and(|m| m.file_type().is_symlink()) {
        return Err(refuse(&format!(
            "socket directory {given} is a symbolic link (give the directory it points to)."
        )));
    }
    if !gp.exists() {
        return Err(refuse(&format!("socket directory {given} does not exist.")));
    }
    if !gp.is_dir() {
        return Err(refuse(&format!(
            "socket directory {given} is not a directory."
        )));
    }
    let d = match realpath_e(gp) {
        Some(p) => path_str(&p),
        None => {
            return Err(refuse(&format!(
                "socket directory {given} cannot be read (its resolved path)."
            )));
        }
    };
    if d.contains(',') || d.contains('"') || d.contains('\n') {
        return Err(refuse(&format!(
            "socket directory {d} cannot be mounted: docker's --mount cannot carry a comma, a double quote or a newline in a path."
        )));
    }
    let meta = match std::fs::metadata(&d) {
        Ok(m) => m,
        Err(_) => return Err(refuse(&format!("socket directory {d} cannot be read."))),
    };
    if meta.uid() != host_uid {
        return Err(refuse(&format!(
            "socket directory {d} is not owned by the invoking user."
        )));
    }
    let mode = meta.mode() & 0o7777;
    if mode & 0o022 != 0 {
        return Err(refuse(&format!(
            "socket directory {d} is writable by group or others (mode {mode:o})."
        )));
    }
    if path_within(&d, data_abs) || path_within(data_abs, &d) {
        return Err(refuse(&format!(
            "socket directory {d} overlaps the data directory ({data_abs})."
        )));
    }
    let home = path_str(&realpath_m(&crate::util::home_dir()));
    if d == home {
        return Err(refuse(&format!(
            "socket directory {d} is the home directory."
        )));
    }
    if path_within(&home, &d) {
        return Err(refuse(&format!(
            "socket directory {d} is an ancestor of the home directory."
        )));
    }
    for (label, target) in launcher_dirs(cfg, net_policy) {
        if target.is_empty() {
            continue;
        }
        if path_within(&d, &target) || path_within(&target, &d) {
            return Err(refuse(&format!(
                "socket directory {d} overlaps the {label} ({target})."
            )));
        }
    }
    if path_within(&d, &home) {
        return Err(refuse(&format!(
            "socket directory {d} is inside the home directory."
        )));
    }
    let xdg = std::env::var("XDG_RUNTIME_DIR").unwrap_or_default();
    let run_user = format!("/run/user/{host_uid}");
    for runtime in [xdg.as_str(), run_user.as_str()] {
        if runtime.is_empty() {
            continue;
        }
        if runtime == run_user && !Path::new(runtime).is_dir() {
            continue;
        }
        let r = path_str(&realpath_m(Path::new(runtime)));
        if path_within(&r, &d) {
            return Err(refuse(&format!(
                "socket directory {d} is or contains the user runtime directory ({r}); use a directory inside it."
            )));
        }
    }
    // Readable and searchable.
    if std::fs::read_dir(&d).is_err()
        || !std::path::Path::new(&d).join(".").exists()
        || (mode & 0o500) != 0o500
    {
        return Err(refuse(&format!(
            "socket directory {d} cannot be read (it must be readable and searchable)."
        )));
    }
    let w = walk(Path::new(&d), Some(1));
    if let Some(e) = &w.first_error {
        return Err(refuse(&format!(
            "socket directory {d} cannot be read ({e})."
        )));
    }
    if let Some((p, _)) = w.entries.iter().find(|(_, m)| !m.file_type().is_socket()) {
        return Err(refuse(&format!(
            "socket directory {d} holds an entry that is not a socket ({}).",
            path_str(p)
        )));
    }
    if let Some((p, _)) = w.entries.iter().find(|(_, m)| m.uid() != host_uid) {
        return Err(refuse(&format!(
            "socket directory {d} holds a socket owned by another user ({}).",
            path_str(p)
        )));
    }
    let mut creds: HashMap<(u64, u64), String> = HashMap::new();
    let mut docker_sock = "/var/run/docker.sock".to_string();
    if let Ok(h) = std::env::var("DOCKER_HOST")
        && let Some(p) = h.strip_prefix("unix://")
    {
        docker_sock = p.to_string();
    }
    let mut cands = vec![
        std::env::var("SSH_AUTH_SOCK").unwrap_or_default(),
        docker_sock,
    ];
    if !xdg.is_empty() {
        cands.push(format!("{xdg}/docker.sock"));
        cands.push(format!("{xdg}/bus"));
    }
    for c in cands {
        if c.is_empty() {
            continue;
        }
        if let Ok(m) = std::fs::metadata(&c)
            && m.file_type().is_socket()
        {
            creds.insert((m.dev(), m.ino()), c);
        }
    }
    for (p, m) in &w.entries {
        if let Some(c) = creds.get(&(m.dev(), m.ino())) {
            return Err(refuse(&format!(
                "socket directory {d} holds a credential socket ({} is {c}).",
                path_str(p)
            )));
        }
    }
    Ok(d)
}

pub fn apparmor_checks(no_network: bool, script_dir: &Path) -> Result<String, Refusal> {
    let sys = crate::util::lbx_env("SYSFS").unwrap_or_else(|| "/sys".into());
    let want = if no_network {
        "llm-in-a-box-run-no-network"
    } else {
        "llm-in-a-box-run"
    };
    let read = |p: String| {
        std::fs::read_to_string(p)
            .unwrap_or_default()
            .trim_end_matches('\n')
            .to_string()
    };
    if read(format!("{sys}/module/apparmor/parameters/enabled")) != "Y" {
        return Err(refuse(
            "--apparmor-profile: AppArmor is not enabled on this host.",
        ));
    }
    if read(format!(
        "{sys}/kernel/security/apparmor/features/network/af_unix"
    )) != "yes"
    {
        return Err(refuse(
            "--apparmor-profile: this kernel's AppArmor does not mediate Unix sockets, so the profile's socket rules would not be enforced.",
        ));
    }
    let mut found = false;
    let mut enforced = false;
    if let Ok(rd) = std::fs::read_dir(format!("{sys}/kernel/security/apparmor/policy/profiles")) {
        let mut dirs: Vec<PathBuf> = rd.filter_map(Result::ok).map(|e| e.path()).collect();
        dirs.sort();
        for p in dirs {
            let name = std::fs::read_to_string(p.join("name"))
                .unwrap_or_default()
                .lines()
                .next()
                .unwrap_or("")
                .to_string();
            if name != want {
                continue;
            }
            found = true;
            let mode = std::fs::read_to_string(p.join("mode"))
                .unwrap_or_default()
                .lines()
                .next()
                .unwrap_or("")
                .to_string();
            if mode == "enforce" {
                enforced = true;
            }
        }
    }
    if !found {
        // The profile file sits next to a checkout's launcher; a release
        // binary on PATH has no such neighbor.
        let shipped = script_dir.join("apparmor/llm-in-a-box-run");
        let hint = if shipped.is_file() {
            path_str(&shipped)
        } else {
            "apparmor/llm-in-a-box-run (in a checkout of lbx)".to_string()
        };
        return Err(refuse(&format!(
            "--apparmor-profile: the AppArmor profile {want} is not loaded (as root: apparmor_parser -r {hint})."
        )));
    }
    if !enforced {
        return Err(refuse(&format!(
            "--apparmor-profile: the AppArmor profile {want} is not in enforce mode."
        )));
    }
    Ok(want.to_string())
}

/// Every refusal, before anything is created or written.
pub fn validate(
    cfg: &Resolved,
    o: &Options,
    host_uid: u32,
    host_gid: u32,
    script_dir: &Path,
) -> Result<Checked, Refusal> {
    if o.runtime != "docker" {
        let got = if o.runtime.is_empty() {
            "none"
        } else {
            o.runtime.as_str()
        };
        return Err(refuse(&format!(
            "--run needs --runtime docker (got: {got})."
        )));
    }
    if !o.run_no_network {
        if o.net_policy.is_empty() {
            return Err(refuse(
                "--run needs --net-policy with mode enforce or locked, or --no-network.",
            ));
        }
        if std::fs::File::open(&o.net_policy).is_err() {
            return Err(refuse(&format!(
                "net policy file {} is not readable.",
                o.net_policy
            )));
        }
        let mode = match crate::netpolicy::mode_of(Path::new(&o.net_policy)) {
            Some(m) => m,
            None => {
                return Err(refuse(&format!(
                    "net policy file {} is not valid JSON.",
                    o.net_policy
                )));
            }
        };
        if mode != "enforce" && mode != "locked" {
            let got = if mode.is_empty() {
                "none".to_string()
            } else {
                mode
            };
            return Err(refuse(&format!(
                "net policy mode must be enforce or locked for --run (got: {got})."
            )));
        }
    }
    if o.run_timeouts.len() != 1 {
        return Err(refuse("--run needs exactly one --timeout <seconds>."));
    }
    let t = &o.run_timeouts[0];
    let Some(timeout) = parse_timeout(t) else {
        return Err(refuse(&format!(
            "--timeout must be a whole number of seconds from 1 to {RUN_TIMEOUT_MAX} (got: {t})."
        )));
    };
    if o.session.len() > RUN_NAME_MAX {
        return Err(refuse(&format!(
            "run name is longer than {RUN_NAME_MAX} characters."
        )));
    }
    if host_uid == 0 {
        return Err(refuse("--run refuses host user id 0."));
    }
    if host_gid == 0 {
        return Err(refuse("--run refuses host group id 0."));
    }
    let mut seen: Vec<&str> = Vec::new();
    for name in &o.run_envs {
        if !valid_var_name(name) {
            return Err(refuse(&format!(
                "--env name '{name}' is not a valid variable name."
            )));
        }
        if RESERVED.contains(&name.as_str())
            || name.starts_with("LD_")
            || name.starts_with("LLMBOX_")
            || name.starts_with("llmbox_")
            || name.starts_with("LBX_")
            || name.starts_with("lbx_")
        {
            return Err(refuse(&format!("--env name {name} is reserved.")));
        }
        if seen.contains(&name.as_str()) {
            return Err(refuse(&format!("--env name {name} is given twice.")));
        }
        seen.push(name);
        if std::env::var_os(name).is_none() {
            return Err(refuse(&format!("--env name {name} is not set.")));
        }
    }
    if !o.run_data_set {
        return Err(refuse("--run needs --data <directory>."));
    }
    let data_abs = data_checks(cfg, &o.run_data, &o.net_policy, host_uid)?;
    let socket_abs = if o.run_socket_dirs.is_empty() {
        String::new()
    } else {
        socket_dir_checks(cfg, &o.run_socket_dirs, &data_abs, &o.net_policy, host_uid)?
    };
    let apparmor_profile = if o.run_apparmor {
        apparmor_checks(o.run_no_network, script_dir)?
    } else {
        String::new()
    };
    if !Docker::available() {
        return Err(refuse("docker is not installed or not on PATH."));
    }
    let setpriv_ok = std::process::Command::new("setpriv")
        .args(["--pdeathsig", "KILL", "true"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|s| s.success());
    if !setpriv_ok {
        return Err(refuse(
            "setpriv (util-linux) with --pdeathsig is needed for --run.",
        ));
    }
    let n = o.session.as_str();
    for what in [n.to_string(), relay_container_name(n)] {
        if Docker::container_exists(&what) {
            return Err(refuse(&format!("a container named {what} already exists.")));
        }
        poll_refusal_signal()?;
    }
    for what in [relay_network_name(n), relay_egress_network_name(n)] {
        if Docker::quiet(&["network", "inspect", &what]) {
            return Err(refuse(&format!("a network named {what} already exists.")));
        }
        poll_refusal_signal()?;
    }
    if cfg.state_dir.join("sessions").join(n).exists() {
        return Err(refuse(&format!("a vm session named {n} already exists.")));
    }
    for what in [
        cfg.state_dir.join("netlogs").join(n),
        cfg.state_dir.join("runs").join(n),
    ] {
        if std::fs::symlink_metadata(&what).is_ok() {
            return Err(refuse(&format!(
                "run name {n} was used before: {} already exists (use a new run name, or remove it).",
                path_str(&what)
            )));
        }
    }
    if !Docker::image_exists(&cfg.image_docker) {
        return Err(refuse(&format!(
            "image {} is not present locally (build it with ./build docker).",
            cfg.image_docker
        )));
    }
    poll_refusal_signal()?;
    if !o.run_no_network && !Docker::image_exists(RUN_RELAY_IMAGE) {
        return Err(refuse(&format!(
            "image {RUN_RELAY_IMAGE} is not present locally (build it with ./build relay)."
        )));
    }
    poll_refusal_signal()?;
    Ok(Checked {
        timeout,
        data_abs,
        socket_abs,
        apparmor_profile,
    })
}

pub fn parse_timeout(t: &str) -> Option<u64> {
    let b = t.as_bytes();
    if b.is_empty() || b.len() > 6 || b[0] == b'0' || !b.iter().all(u8::is_ascii_digit) {
        return None;
    }
    let v: u64 = t.parse().ok()?;
    (1..=RUN_TIMEOUT_MAX).contains(&v).then_some(v)
}

pub fn valid_var_name(n: &str) -> bool {
    let mut c = n.chars();
    match c.next() {
        Some(x) if x.is_ascii_alphabetic() || x == '_' => {}
        _ => return false,
    }
    n.chars().all(|x| x.is_ascii_alphanumeric() || x == '_')
}

/// Resources this run created, in creation order.
pub struct Live {
    pub state_dir: PathBuf,
    pub session: String,
    pub run_id: String,
    pub nets: Vec<String>,
    pub relay: String,
    pub run_box: String,
    pub netlogs: String,
    pub child: Option<std::process::Child>,
    pub status: Option<RunStatus>,
    pub rc: Option<i32>,
}

fn run_msg(s: &str) {
    err(&format!("\n{s}"));
}

fn owns(kind: &str, name: &str, run_id: &str) -> bool {
    if name.is_empty() || run_id.is_empty() {
        return false;
    }
    let fmt = if kind == "network" {
        "{{index .Labels \"llm-in-a-box.run-id\"}}"
    } else {
        "{{index .Config.Labels \"llm-in-a-box.run-id\"}}"
    };
    for delay in [Some(0.5), Some(1.0), Some(2.0), None] {
        let o = Docker::run(&[kind, "inspect", "-f", fmt, name]);
        if o.ok {
            return o.stdout.trim_end_matches('\n') == run_id;
        }
        let e = format!("{}{}", o.stdout, o.stderr);
        if e.contains("No such container")
            || e.contains("No such network")
            || e.contains("No such object")
            || e.contains("not found")
        {
            return false;
        }
        if let Some(d) = delay {
            std::thread::sleep(std::time::Duration::from_secs_f64(d));
        }
    }
    false
}

fn report_leftovers(run_id: &str) -> bool {
    let filter = format!("label=llm-in-a-box.run-id={run_id}");
    let mut ok_c = true;
    let mut ok_n = true;
    let mut left_c = String::new();
    let mut left_n = String::new();
    for round in 1..=5 {
        let c = Docker::run(&["ps", "-a", "--filter", &filter, "--format", "{{.Names}}"]);
        ok_c = c.ok;
        left_c = c.stdout.clone();
        let n = Docker::run(&[
            "network",
            "ls",
            "--filter",
            &filter,
            "--format",
            "{{.Name}}",
        ]);
        ok_n = n.ok;
        left_n = n.stdout.clone();
        if ok_c && ok_n && left_c.trim().is_empty() && left_n.trim().is_empty() {
            return false;
        }
        if round != 5 {
            std::thread::sleep(std::time::Duration::from_secs(1));
        }
    }
    if ok_c {
        for l in left_c.lines().filter(|l| !l.is_empty()) {
            run_msg(&format!(
                "ERROR: cleanup incomplete: container {l} of this run is still there; remove it with: docker rm -f {l}"
            ));
        }
    } else {
        run_msg(&format!(
            "ERROR: cleanup could not be checked: listing this run's containers failed; list them with: docker ps -a --filter {filter}"
        ));
    }
    if ok_n {
        for l in left_n.lines().filter(|l| !l.is_empty()) {
            run_msg(&format!(
                "ERROR: cleanup incomplete: network {l} of this run is still there; remove it with: docker network rm {l}"
            ));
        }
    } else {
        run_msg(&format!(
            "ERROR: cleanup could not be checked: listing this run's networks failed; list them with: docker network ls --filter {filter}"
        ));
    }
    true
}

/// The exit once the run has started creating things.
pub fn on_exit(live: &mut Live) -> ! {
    ignore_signals();
    let status = live.status.unwrap_or(RunStatus::SetupFailed);
    let mut rc = live.rc.unwrap_or(125);
    if live.status.is_none() {
        rc = 125;
    }
    if let Some(c) = live.child.as_mut() {
        // SAFETY: a plain kill of our own child's pid.
        unsafe {
            libc::kill(c.id() as libc::pid_t, libc::SIGTERM);
        }
    }
    if owns("container", &live.run_box, &live.run_id) {
        let _ = Docker::quiet(&["rm", "-f", &live.run_box]);
    }
    if owns("container", &live.relay, &live.run_id) {
        let _ = Docker::quiet(&["rm", "-f", &live.relay]);
    }
    for net in live.nets.clone() {
        if !owns("network", &net, &live.run_id) {
            continue;
        }
        for _ in 0..5 {
            if Docker::quiet(&["network", "rm", &net]) {
                break;
            }
            std::thread::sleep(std::time::Duration::from_secs(1));
        }
    }
    let incomplete = report_leftovers(&live.run_id);
    if let Some(mut c) = live.child.take() {
        let _ = c.wait();
    }
    let outcome = Outcome {
        status,
        code: rc,
        cleanup_incomplete: incomplete,
    };
    let mut exit_rc = rc;
    if incomplete && exit_rc == 0 {
        exit_rc = 125;
    }
    let dir = live.state_dir.join("runs").join(&live.session);
    if dir.is_dir() {
        let tmp = dir.join(format!(".status.{}", std::process::id()));
        if std::fs::write(&tmp, format!("{}\n", outcome.format())).is_ok() {
            let _ = std::fs::rename(&tmp, dir.join("status"));
        }
    }
    let _ = std::fs::remove_file(dir.join(".claim"));
    if !live.netlogs.is_empty() {
        err(&format!("\nlbx-run: deny-log={}/deny.log", live.netlogs));
    }
    err(&format!("\nlbx-run: {}", outcome.format()));
    std::process::exit(exit_rc);
}

fn setup_failed(live: &mut Live, msg: &str) -> ! {
    // A signal that landed during the failed call decides the outcome.
    poll_running(live);
    run_msg(&format!("ERROR: {msg}"));
    live.status = Some(RunStatus::SetupFailed);
    live.rc = Some(125);
    on_exit(live)
}

/// A signal or the timer during the running stage ends the run.
fn poll_running(live: &mut Live) {
    let sig = pending_signal();
    if sig == 138 || TIMER.load(Ordering::SeqCst) {
        live.status = Some(RunStatus::Timeout);
        live.rc = Some(124);
        on_exit(live);
    }
    if sig != 0 {
        live.status = Some(RunStatus::Signal);
        live.rc = Some(sig);
        on_exit(live);
    }
}

/// A refusal during the claim: whatever the claim created is removed first.
fn claim_refuse(msg: &str, claim: &Claim, state_dir: &Path) -> Refusal {
    claim.release(state_dir);
    refuse(msg)
}

/// Claim the run name: exactly one of two same-named runs goes on.
pub fn claim_name(state_dir: &Path, n: &str) -> Result<Claim, Refusal> {
    let mut claim = Claim::default();
    let runs = state_dir.join("runs");
    let claim_dir = runs.join(n);
    let used = format!(
        "run name {n} was used before: {} already exists (use a new run name, or remove it).",
        path_str(&claim_dir)
    );
    if let Some(parent) = state_dir.parent()
        && !parent.is_dir()
    {
        let _ = std::fs::create_dir_all(parent);
    }
    if std::fs::create_dir(state_dir).is_ok() {
        claim.own_state = true;
    }
    if std::fs::create_dir(&runs).is_ok() {
        claim.own_runs = true;
    }
    if !runs.is_dir() {
        let own_state = claim.own_state;
        claim.own_runs = false;
        claim.own_state = false;
        if own_state {
            let _ = std::fs::remove_dir(state_dir);
        }
        // Only the status line, like the bash (the ancestors could not be made).
        return Err(claim_refuse("", &claim, state_dir));
    }
    if std::fs::create_dir(&claim_dir).is_err() {
        if std::fs::symlink_metadata(&claim_dir).is_ok() {
            return Err(claim_refuse(&used, &claim, state_dir));
        }
        let (own_runs, own_state) = (claim.own_runs, claim.own_state);
        claim.own_runs = false;
        claim.own_state = false;
        if own_runs {
            let _ = std::fs::remove_dir(&runs);
        }
        if own_state {
            let _ = std::fs::remove_dir(state_dir);
        }
        return Err(claim_refuse(
            &format!("could not create {}.", path_str(&claim_dir)),
            &claim,
            state_dir,
        ));
    }
    claim.own_claim_dir = Some(claim_dir.clone());
    let claim_file = claim_dir.join(".claim");
    if std::fs::symlink_metadata(&claim_file).is_ok() {
        return Err(claim_refuse(&used, &claim, state_dir));
    }
    let created = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&claim_file)
        .is_ok();
    if !created {
        if std::fs::symlink_metadata(&claim_file).is_ok() {
            return Err(claim_refuse(&used, &claim, state_dir));
        }
        let (own_runs, own_state) = (claim.own_runs, claim.own_state);
        claim.own_claim_dir = None;
        claim.own_runs = false;
        claim.own_state = false;
        let _ = std::fs::remove_dir(&claim_dir);
        if own_runs {
            let _ = std::fs::remove_dir(&runs);
        }
        if own_state {
            let _ = std::fs::remove_dir(state_dir);
        }
        return Err(claim_refuse(
            &format!(
                "could not claim run name {n}: creating {} failed.",
                path_str(&claim_file)
            ),
            &claim,
            state_dir,
        ));
    }
    claim.own_claim = Some(claim_file.clone());
    if std::fs::symlink_metadata(claim_dir.join("status")).is_ok() {
        let _ = std::fs::remove_file(&claim_file);
        claim = Claim::default();
        return Err(claim_refuse(&used, &claim, state_dir));
    }
    let sig = pending_signal();
    if sig != 0 {
        claim.release(state_dir);
        return Err(Refusal::Signal(sig));
    }
    Ok(claim)
}

/// The whole unattended run. Never returns.
pub fn run_main(
    cfg: &Resolved,
    o: &Options,
    host_user: &str,
    host_uid: u32,
    host_gid: u32,
    script_dir: &Path,
) -> Refusal {
    let checked = match validate(cfg, o, host_uid, host_gid, script_dir) {
        Ok(c) => c,
        Err(r) => return r,
    };
    let n = o.session.clone();
    let sd = cfg.state_dir.clone();
    let ready_max: u64 = crate::util::lbx_env("RUN_READY_SECONDS")
        .filter(|s| !s.is_empty() && !s.starts_with('0') && s.bytes().all(|b| b.is_ascii_digit()))
        .and_then(|s| s.parse().ok())
        .unwrap_or(60);
    let lifetime = checked.timeout + ready_max + 60;
    let run_id = match crate::util::random_hex16() {
        Some(id) if id.len() == 32 => id,
        _ => return refuse("could not read random bytes for the run's identity label."),
    };
    let _claim = match claim_name(&sd, &n) {
        Ok(c) => c,
        Err(r) => return r,
    };
    // From here on every exit goes through on_exit.
    let mut live = Live {
        state_dir: sd.clone(),
        session: n.clone(),
        run_id: run_id.clone(),
        nets: Vec::new(),
        relay: String::new(),
        run_box: String::new(),
        netlogs: String::new(),
        child: None,
        status: None,
        rc: None,
    };
    let mut net_args: Vec<String> = vec!["--network".into(), "none".into()];
    let mut proxy_env: Vec<String> = empty_proxy_env();
    if !o.run_no_network {
        let net = relay_network_name(&n);
        let egress = relay_egress_network_name(&n);
        live.nets.push(net.clone());
        poll_running(&mut live);
        if !Docker::quiet(&[
            "network",
            "create",
            "--internal",
            "-o",
            "com.docker.network.bridge.inhibit_ipv4=true",
            &net,
            "--label",
            &format!("llm-in-a-box.run-id={run_id}"),
        ]) {
            live.nets.clear();
            setup_failed(&mut live, &format!("could not create network {net}."));
        }
        poll_running(&mut live);
        live.nets.push(egress.clone());
        if !Docker::quiet(&[
            "network",
            "create",
            &egress,
            "--label",
            &format!("llm-in-a-box.run-id={run_id}"),
        ]) {
            live.nets = vec![net.clone()];
            setup_failed(&mut live, &format!("could not create network {egress}."));
        }
        poll_running(&mut live);
        let netlogs = path_str(&realpath_m(&sd.join("netlogs").join(&n)));
        live.netlogs = netlogs.clone();
        let _ = std::fs::create_dir_all(&netlogs);
        let policy_abs = realpath_e(Path::new(&o.net_policy))
            .map(|p| path_str(&p))
            .unwrap_or_default();
        let relay = relay_container_name(&n);
        live.relay = relay.clone();
        let argv = run_relay_argv(&RunRelay {
            relay: relay.clone(),
            run_id: run_id.clone(),
            uid: host_uid,
            gid: host_gid,
            policy_abs,
            netlogs: netlogs.clone(),
            net: net.clone(),
            egress: egress.clone(),
        });
        if !Docker::quiet_owned(&argv) {
            setup_failed(&mut live, &format!("could not start the relay {relay}."));
        }
        poll_running(&mut live);
        let mut healthy = false;
        for _ in 0..10 {
            if Docker::quiet(&[
                "exec",
                &relay,
                "python3",
                "-c",
                "import socket; socket.create_connection((\"127.0.0.1\", 3128), 2).close()",
            ]) {
                healthy = true;
                break;
            }
            poll_running(&mut live);
            std::thread::sleep(std::time::Duration::from_secs(1));
            poll_running(&mut live);
        }
        if !healthy {
            setup_failed(
                &mut live,
                &format!("the relay {relay} did not start listening."),
            );
        }
        let relay_ip = Docker::line(&[
            "inspect",
            "-f",
            &format!("{{{{(index .NetworkSettings.Networks \"{net}\").IPAddress}}}}"),
            &relay,
        ])
        .unwrap_or_default();
        poll_running(&mut live);
        if relay_ip.is_empty() {
            setup_failed(&mut live, "could not read the relay's address.");
        }
        net_args = vec!["--network".into(), net.clone()];
        proxy_env = run_proxy_env(&relay_ip);
    }
    let box_user = crate::docker::box_user(&cfg.image_docker);
    poll_running(&mut live);
    live.run_box = n.clone();
    let argv = run_box_argv(&RunBox {
        name: n.clone(),
        run_id: run_id.clone(),
        box_user,
        apparmor_profile: checked.apparmor_profile.clone(),
        host_user: host_user.into(),
        host_uid,
        host_gid,
        proxy_env,
        net_args,
        data_abs: checked.data_abs.clone(),
        socket_abs: checked.socket_abs.clone(),
        image: cfg.image_docker.clone(),
        lifetime,
    });
    if !Docker::quiet_owned(&argv) {
        setup_failed(&mut live, &format!("could not start the run box {n}."));
    }
    poll_running(&mut live);
    let started = std::time::Instant::now();
    let mut ready = false;
    while started.elapsed().as_secs() < ready_max {
        if Docker::quiet(&["exec", &n, "test", "-f", "/tmp/.run-ready"]) {
            ready = true;
            break;
        }
        poll_running(&mut live);
        std::thread::sleep(std::time::Duration::from_secs(1));
        poll_running(&mut live);
    }
    if !ready {
        setup_failed(
            &mut live,
            &format!("the run box {n} did not become ready within {ready_max} seconds."),
        );
    }
    // The timer starts with the command.
    let timeout = checked.timeout;
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_secs(timeout));
        TIMER.store(true, Ordering::SeqCst);
    });
    let exec_argv = run_exec_argv(&n, &o.run_envs, host_user, &o.run_cmd);
    let child = {
        use std::os::unix::process::CommandExt;
        let mut c = std::process::Command::new("docker");
        c.args(&exec_argv)
            .stdin(std::process::Stdio::inherit())
            .stdout(std::process::Stdio::inherit())
            .stderr(std::process::Stdio::inherit());
        // SAFETY: prctl in the child before exec only sets the parent-death
        // signal; it is async-signal-safe.
        unsafe {
            c.pre_exec(|| {
                libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL);
                Ok(())
            });
        }
        c.spawn()
    };
    let mut child = match child {
        Ok(c) => c,
        Err(e) => setup_failed(&mut live, &format!("could not start the command: {e}")),
    };
    loop {
        match child.try_wait() {
            Ok(Some(st)) => {
                use std::os::unix::process::ExitStatusExt;
                let rc = st
                    .code()
                    .or_else(|| st.signal().map(|s| 128 + s))
                    .unwrap_or(1);
                live.status = Some(RunStatus::Exited);
                live.rc = Some(rc);
                on_exit(&mut live);
            }
            Ok(None) => {}
            Err(_) => {
                live.status = Some(RunStatus::Exited);
                live.rc = Some(1);
                on_exit(&mut live);
            }
        }
        live.child = Some(child);
        poll_running(&mut live);
        child = match live.child.take() {
            Some(c) => c,
            None => on_exit(&mut live),
        };
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timeouts() {
        assert_eq!(parse_timeout("1"), Some(1));
        assert_eq!(parse_timeout("604800"), Some(604_800));
        assert_eq!(parse_timeout("604801"), None);
        assert_eq!(parse_timeout("0"), None);
        assert_eq!(parse_timeout("01"), None);
        assert_eq!(parse_timeout("1000000"), None);
        assert_eq!(parse_timeout(""), None);
    }

    #[test]
    fn octal_unescape() {
        assert_eq!(unescape_octal("/a\\040b"), "/a b");
        assert_eq!(unescape_octal("/plain"), "/plain");
    }
}

#[cfg(test)]
mod wording_tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    /// The unreadable-entry wording is pinned: `find: '<path>': <OS text>`
    /// with plain single quotes and the OS error text without the errno.
    #[test]
    fn unreadable_directory_wording_is_pinned() {
        let tmp = tempfile::tempdir().unwrap_or_else(|e| panic!("{e}"));
        let locked = tmp.path().join("locked");
        std::fs::create_dir(&locked).unwrap_or_else(|e| panic!("{e}"));
        std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o000))
            .unwrap_or_else(|e| panic!("{e}"));
        let w = walk(tmp.path(), None);
        let _ = std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o700));
        // Root reads everything; the wording test needs a plain user.
        if crate::util::host_uid() == 0 {
            return;
        }
        assert_eq!(
            w.first_error.as_deref(),
            Some(format!("find: '{}': Permission denied", path_str(&locked)).as_str())
        );
        assert_eq!(
            os_msg(&std::io::Error::from_raw_os_error(libc::ENOENT)),
            "No such file or directory"
        );
    }

    #[test]
    fn refusal_shape() {
        let r = refuse("no.");
        assert_eq!(r, Refusal::Refused("no.".into()));
        assert_eq!(r.outcome().format(), "status=refused code=125");
        assert_eq!(r.exit_code(), 125);
        let s = Refusal::Signal(143);
        assert_eq!(s.message(), None);
        assert_eq!(s.outcome().format(), "status=signal code=143");
        assert_eq!(s.exit_code(), 143);
    }

    #[test]
    fn claim_then_release_leaves_nothing_behind() {
        let tmp = tempfile::tempdir().unwrap_or_else(|e| panic!("{e}"));
        let state = tmp.path().join("state");
        let claim = claim_name(&state, "job").unwrap_or_else(|e| panic!("{e:?}"));
        assert!(claim.own_state && claim.own_runs);
        assert!(state.join("runs/job/.claim").is_file());
        // The same name again is refused with the used-before wording.
        let again = claim_name(&state, "job");
        assert_eq!(
            again.err().and_then(|r| r.message().map(str::to_string)),
            Some(format!(
                "run name job was used before: {} already exists (use a new run name, or remove it).",
                path_str(&state.join("runs/job"))
            ))
        );
        claim.release(&state);
        assert!(
            !state.exists(),
            "release removes exactly what the claim created"
        );
        // With a pre-existing state directory only the claim is removed.
        std::fs::create_dir_all(state.join("runs")).unwrap_or_else(|e| panic!("{e}"));
        let claim = claim_name(&state, "job2").unwrap_or_else(|e| panic!("{e:?}"));
        assert!(!claim.own_state && !claim.own_runs);
        claim.release(&state);
        assert!(state.join("runs").is_dir());
        assert!(!state.join("runs/job2").exists());
    }

    #[test]
    fn launcher_directory_overlap_rule() {
        assert!(path_within("/a/b", "/a"));
        assert!(path_within("/a", "/a"));
        assert!(!path_within("/ab", "/a"));
        assert!(!path_within("/a", "/a/b"));
    }
}
