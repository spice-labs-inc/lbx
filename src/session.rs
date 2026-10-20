//! Interactive sessions: cross-runtime lookup, `--list`, `--destroy`,
//! `--stop`/`--shutdown`, runtime auto-detection, and the container
//! create / start / attach path. The vm runtime is only looked up here
//! (its session directory), never launched (not ported in the spike).

use crate::config::{IMAGE_LEGACY, Resolved};
use crate::docker::{
    Docker, InteractiveRun, Netwall, interactive_relay_argv, interactive_run_argv,
    relay_container_name, relay_egress_network_name, relay_network_name,
};
use crate::util::{err, out, path_str};
use std::path::PathBuf;

pub fn vm_sessions_dir(cfg: &Resolved) -> PathBuf {
    cfg.state_dir.join("sessions")
}

/// vm liveness: pgrep for a qemu holding the overlay path, else the pidfile.
pub fn vm_live_pid_for(cfg: &Resolved, name: &str) -> Option<u32> {
    let overlay = cfg
        .state_dir
        .join("sessions")
        .join(name)
        .join("overlay.qcow2");
    let overlay_re: String = path_str(&overlay)
        .chars()
        .map(|c| {
            if c == '^' {
                "\\^".to_string()
            } else {
                format!("[{c}]")
            }
        })
        .collect();
    if let Ok(o) = std::process::Command::new("pgrep")
        .arg("-f")
        .arg(format!("qemu-system-x86_64.*{overlay_re}"))
        .output()
        && let Some(first) = String::from_utf8_lossy(&o.stdout).lines().next()
        && let Ok(p) = first.trim().parse::<u32>()
    {
        return Some(p);
    }
    let pidfile = vm_sessions_dir(cfg).join(name).join("qemu.pid");
    let p: u32 = std::fs::read_to_string(pidfile).ok()?.trim().parse().ok()?;
    // SAFETY: kill with signal 0 only probes for the process.
    if unsafe { libc::kill(p as libc::pid_t, 0) } == 0 {
        Some(p)
    } else {
        None
    }
}

pub fn vm_state_for(cfg: &Resolved, name: &str) -> String {
    if !vm_sessions_dir(cfg).join(name).is_dir() {
        "missing".into()
    } else if vm_live_pid_for(cfg, name).is_some() {
        "running".into()
    } else {
        "exited".into()
    }
}

/// A container's session classification: runtime, state, legacy marker.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContainerSession {
    pub runtime: String,
    pub state: String,
    pub legacy: bool,
}

pub fn container_session_state(name: &str) -> Option<ContainerSession> {
    if !Docker::available() {
        return None;
    }
    let out = Docker::container_fmt(
        name,
        "{{index .Config.Labels \"llm-in-a-box.runtime\"}}|{{.Config.Image}}|{{.State.Status}}",
    )?;
    if out.is_empty() {
        return None;
    }
    let mut parts = out.splitn(3, '|');
    let mut rt = parts.next().unwrap_or("").to_string();
    let img = parts.next().unwrap_or("").to_string();
    let state = parts.next().unwrap_or("").to_string();
    let mut legacy = false;
    if rt.is_empty() {
        let lrt = Docker::container_label(name, "box-of-claude.runtime");
        if !lrt.is_empty() {
            rt = lrt;
            legacy = true;
        } else if img.starts_with("llm-in-a-box:") {
            rt = "image-primary".into();
        } else if img.starts_with("box-of-claude:") {
            rt = "legacy".into();
        } else {
            return None;
        }
    }
    if rt == "legacy" || rt == "image-primary" {
        if rt == "legacy" {
            legacy = true;
        }
        let hrt = Docker::container_fmt(name, "{{.HostConfig.Runtime}}").unwrap_or_default();
        rt = if hrt == "sysbox-runc" {
            "sysbox".into()
        } else {
            "docker".into()
        };
    }
    Some(ContainerSession {
        runtime: rt,
        state,
        legacy,
    })
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Lookup {
    Missing,
    Ambiguous(Vec<String>),
    Found(ContainerSession),
}

impl Lookup {
    pub fn runtimes_joined(&self) -> String {
        match self {
            Lookup::Ambiguous(v) => v.join(","),
            _ => String::new(),
        }
    }
}

pub fn session_lookup(cfg: &Resolved, name: &str) -> Lookup {
    let vm = if vm_sessions_dir(cfg).join(name).is_dir() {
        Some(ContainerSession {
            runtime: "vm".into(),
            state: vm_state_for(cfg, name),
            legacy: false,
        })
    } else {
        None
    };
    let c = container_session_state(name);
    match (vm, c) {
        (Some(v), Some(c)) => Lookup::Ambiguous(vec![v.runtime, c.runtime]),
        (Some(v), None) => Lookup::Found(v),
        (None, Some(c)) => Lookup::Found(c),
        (None, None) => Lookup::Missing,
    }
}

/// The runtime that is not the target inside an ambiguous pair.
pub fn sibling_of_target(lookup: &Lookup, target: &str) -> String {
    match lookup {
        Lookup::Ambiguous(v) => v
            .iter()
            .rfind(|r| r.as_str() != target)
            .cloned()
            .unwrap_or_default(),
        _ => String::new(),
    }
}

/// Which instance a destructive operation acts on; `Err` means the error
/// was already printed.
pub fn select_target_runtime(
    name: &str,
    lookup: &Lookup,
    runtime: &str,
    destroy: bool,
) -> Option<String> {
    let verb = if destroy { "--destroy" } else { "--stop" };
    match lookup {
        Lookup::Missing => Some("missing".into()),
        Lookup::Ambiguous(rts) => {
            let joined = rts.join(",");
            if runtime.is_empty() {
                err(&format!(
                    "ERROR: session '{name}' exists in multiple runtimes ({joined})."
                ));
                err("       --runtime is required so the operation never guesses an instance:");
                for rt in rts {
                    err(&format!("         lbx {verb} --runtime {rt} {name}"));
                }
                return None;
            }
            if rts.iter().any(|r| r == runtime) {
                return Some(runtime.to_string());
            }
            err(&format!(
                "ERROR: session '{name}' exists in multiple runtimes ({joined}); --runtime {runtime} is not one of them."
            ));
            for rt in rts {
                err(&format!("         lbx {verb} --runtime {rt} {name}"));
            }
            None
        }
        Lookup::Found(c) => {
            if !runtime.is_empty() && runtime != c.runtime {
                let rt = &c.runtime;
                err(&format!(
                    "ERROR: session '{name}' already exists as a {rt} instance (--runtime {runtime} conflicts)."
                ));
                err(&format!("       Attach:  lbx [--runtime {rt}] {name}"));
                if destroy {
                    err(&format!(
                        "       Remove:  lbx --destroy --runtime {rt} {name}"
                    ));
                } else {
                    err(&format!("       Stop:    lbx --stop --runtime {rt} {name}"));
                }
                return None;
            }
            Some(c.runtime.clone())
        }
    }
}

/// `--list`: one table across all runtimes.
pub fn list_sessions(cfg: &Resolved) -> Vec<String> {
    let mut rows: Vec<String> = Vec::new();
    let vms = vm_sessions_dir(cfg);
    if vms.is_dir() {
        let mut names: Vec<String> = std::fs::read_dir(&vms)
            .map(|rd| {
                rd.filter_map(Result::ok)
                    .filter(|e| e.path().is_dir())
                    .map(|e| e.file_name().to_string_lossy().into_owned())
                    .collect()
            })
            .unwrap_or_default();
        names.sort();
        for name in names {
            let state = vm_state_for(cfg, &name);
            let port = read_trim(&vms.join(&name).join("ssh_port")).unwrap_or_else(|| "-".into());
            let policy =
                read_trim(&vms.join(&name).join("net-policy")).unwrap_or_else(|| "-".into());
            rows.push(format!("{name}|vm|{state}|{port}|{policy}"));
        }
    }
    if Docker::available() {
        for cname in Docker::ps_names() {
            if cname.is_empty() {
                continue;
            }
            let Some(c) = container_session_state(&cname) else {
                continue;
            };
            let mut policy = Docker::container_label(&cname, "llm-in-a-box.net-policy");
            if policy.is_empty() {
                policy = Docker::container_label(&cname, "box-of-claude.net-policy");
            }
            if policy.is_empty() {
                policy = "-".into();
            }
            rows.push(format!("{cname}|{}|{}|-|{policy}", c.runtime, c.state));
        }
    }
    format_list(rows)
}

/// The `--list` table from `name|runtime|state|port|policy` rows: sorted
/// bytewise by the whole row (name first), fixed column widths.
pub fn format_list(mut rows: Vec<String>) -> Vec<String> {
    rows.sort();
    let mut lines = vec![format!(
        "{:<24} {:<8} {:<10} {:<6} {}",
        "NAME", "RUNTIME", "STATE", "PORT", "NET-POLICY"
    )];
    for row in rows {
        let f: Vec<&str> = row.split('|').collect();
        let g = |i: usize| f.get(i).copied().unwrap_or("");
        lines.push(format!(
            "{:<24} {:<8} {:<10} {:<6} {}",
            g(0),
            g(1),
            g(2),
            g(3),
            g(4)
        ));
    }
    lines
}

fn read_trim(p: &std::path::Path) -> Option<String> {
    let s = std::fs::read_to_string(p).ok()?;
    let t = s.trim_end_matches('\n').to_string();
    if t.is_empty() { None } else { Some(t) }
}

/// Auto-detect: vm when built, sysbox (image + runtime), docker; legacy
/// fallback; runtime.default tried first when usable.
pub fn detect_runtime(cfg: &Resolved) -> String {
    let mut available: Vec<&str> = Vec::new();
    if vm_built(cfg) {
        available.push("vm");
    }
    if Docker::image_exists(&cfg.image_sysbox) && Docker::has_runtime("sysbox-runc") {
        available.push("sysbox");
    }
    if Docker::image_exists(&cfg.image_docker) && Docker::available() {
        available.push("docker");
    }
    if available.is_empty() && Docker::image_exists(IMAGE_LEGACY) {
        if Docker::has_runtime("sysbox-runc") {
            available.push("sysbox");
        } else {
            available.push("docker");
        }
    }
    let (chosen, warnings) = choose_runtime(&available, &cfg.runtime_default);
    for w in warnings {
        err(&w);
    }
    chosen
}

/// The preference rule given what is available (in auto-detect order) and
/// the configured default: the default when usable, else the first
/// available; the warnings in the bash's wording.
pub fn choose_runtime(available: &[&str], preferred: &str) -> (String, Vec<String>) {
    let mut warnings = Vec::new();
    if !preferred.is_empty() {
        if !matches!(preferred, "sysbox" | "docker" | "vm") {
            warnings.push(format!(
                "WARNING: invalid runtime.default '{preferred}'; ignoring it."
            ));
        } else if available.contains(&preferred) {
            return (preferred.to_string(), warnings);
        } else {
            warnings.push(format!(
                "WARNING: runtime.default '{preferred}' is not usable here; using the auto-detected runtime."
            ));
        }
    }
    (
        available.first().map(|s| s.to_string()).unwrap_or_default(),
        warnings,
    )
}

pub fn vm_built(cfg: &Resolved) -> bool {
    let bases = cfg.state_dir.join("bases");
    if let Ok(l) = std::fs::read_link(bases.join("latest")) {
        let d = bases.join(l);
        if d.join("base.qcow2").is_file() && d.join("vmlinuz").is_file() {
            return true;
        }
    }
    cfg.state_dir.join("base.qcow2").is_file() && cfg.state_dir.join("vmlinuz").is_file()
}

fn legacy_note(name: &str) {
    err(&format!(
        "note: session '{name}' is an old (legacy) session — consider re-creating it with lbx."
    ));
}

/// `--destroy`. Returns the exit code.
pub fn destroy(cfg: &Resolved, name: &str, runtime: &str) -> i32 {
    let lookup = session_lookup(cfg, name);
    let Some(target) = select_target_runtime(name, &lookup, runtime, true) else {
        return 1;
    };
    match target.as_str() {
        "missing" => {
            err(&format!("Session '{name}' does not exist."));
            return 0;
        }
        "vm" => {
            vm_destroy(cfg, name);
            let _ = Docker::quiet(&["rm", "-f", &relay_container_name(name)]);
            let _ = std::fs::remove_dir_all(cfg.state_dir.join("netlogs").join(name));
        }
        "sysbox" | "docker" => {
            out(&format!("==> Removing container '{name}' ..."));
            if let Lookup::Found(c) = &lookup
                && c.legacy
            {
                legacy_note(name);
            }
            // The session's inner-docker storage volume goes with the
            // container, so a destroy does not leave the images the box
            // pulled behind. It is read from the mount table before the
            // container goes: a migrated box keeps the volume of the
            // replacement it was built from, not one named after the session.
            let mut volumes = vec![format!("{name}-docker")];
            if Docker::container_exists(name) {
                volumes.extend(Docker::store_volumes(name));
                let _ = Docker::quiet(&["rm", "-f", name]);
            }
            let _ = Docker::quiet(&["rm", "-f", &relay_container_name(name)]);
            volumes.dedup();
            for v in &volumes {
                let _ = Docker::quiet(&["volume", "rm", v]);
            }
            let _ = Docker::quiet(&["rm", "-f", &format!("boc-relay-{name}")]);
            for net in [
                relay_network_name(name),
                relay_egress_network_name(name),
                format!("boc-net-{name}"),
                format!("boc-relaynet-{name}"),
            ] {
                for _ in 0..5 {
                    if Docker::quiet(&["network", "rm", &net]) {
                        break;
                    }
                    std::thread::sleep(std::time::Duration::from_secs(1));
                }
            }
            let _ = std::fs::remove_dir_all(cfg.state_dir.join("netlogs").join(name));
            out(&format!("==> Removed container '{name}'."));
        }
        other => {
            err(&format!(
                "internal error: unexpected destroy target '{other}' for session '{name}'."
            ));
            return 1;
        }
    }
    let sibling = sibling_of_target(&lookup, &target);
    if !sibling.is_empty() {
        err(&format!(
            "note: session '{name}' still exists as a {sibling} instance — remove it with: lbx --destroy --runtime {sibling} {name}"
        ));
    }
    0
}

/// `--stop` / `--shutdown`. Returns the exit code.
pub fn stop(cfg: &Resolved, names: &[String], runtime: &str, force: bool, host_user: &str) -> i32 {
    let mut failed = false;
    let mut stopped_any = false;
    let mut missing_any = false;
    for name in names {
        let lookup = session_lookup(cfg, name);
        let Some(target) = select_target_runtime(name, &lookup, runtime, false) else {
            failed = true;
            continue;
        };
        match target.as_str() {
            "missing" => {
                err(&format!("Session '{name}' does not exist."));
                missing_any = true;
            }
            "vm" => {
                stopped_any = true;
                if force {
                    vm_force_stop(cfg, name);
                } else {
                    vm_shutdown(cfg, name, host_user);
                }
                let relay = relay_container_name(name);
                if Docker::container_exists(&relay) {
                    let _ = Docker::quiet(&["stop", &relay]);
                }
            }
            "sysbox" | "docker" => {
                stopped_any = true;
                if force {
                    out(&format!("==> Force-stopping container '{name}' ..."));
                    if !Docker::quiet(&["kill", name]) {
                        return 1;
                    }
                    out(&format!("==> Container '{name}' force-stopped."));
                } else {
                    out(&format!("==> Stopping container '{name}' ..."));
                    if !Docker::quiet(&["stop", name]) {
                        return 1;
                    }
                    out(&format!("==> Stopped container '{name}'."));
                }
                let relay = relay_container_name(name);
                if Docker::container_exists(&relay) {
                    let _ = Docker::quiet(&["stop", &relay]);
                }
                let old = format!("boc-relay-{name}");
                if Docker::container_exists(&old) {
                    let _ = Docker::quiet(&["stop", &old]);
                }
            }
            other => {
                err(&format!(
                    "internal error: unexpected stop target '{other}' for session '{name}'."
                ));
                failed = true;
                continue;
            }
        }
        if target != "missing" {
            let sibling = sibling_of_target(&lookup, &target);
            if !sibling.is_empty() {
                err(&format!(
                    "note: session '{name}' still exists as a {sibling} instance — stop it with: lbx --stop --runtime {sibling} {name}"
                ));
            }
        }
    }
    if failed {
        return 1;
    }
    if missing_any && stopped_any {
        return 1;
    }
    0
}

/// What the launch path needs beyond the config.
pub struct Launch<'a> {
    pub cfg: &'a Resolved,
    pub session: String,
    pub runtime: String,
    pub host_user: String,
    pub host_uid: u32,
    pub host_gid: u32,
    pub fuse: bool,
    pub ports: bool,
    pub publish: Vec<String>,
    pub vm_web_port: String,
    pub devices: Vec<String>,
    pub net_policy: String,
}

fn wait_for_running(session: &str) -> bool {
    for _ in 0..30 {
        if Docker::state(session).as_deref() == Some("running") {
            return true;
        }
        std::thread::sleep(std::time::Duration::from_secs(1));
    }
    err(&format!(
        "ERROR: Container '{session}' did not reach 'running' state within 30s."
    ));
    err(&format!("       Check logs: docker logs {session}"));
    false
}

fn sysbox_box_damaged(session: &str, runtime: &str) -> bool {
    if runtime != "sysbox" {
        return false;
    }
    if Docker::state(session).as_deref() != Some("running") {
        return false;
    }
    let owner = Docker::line(&[
        "exec",
        "-u",
        "0",
        session,
        "stat",
        "-c",
        "%u",
        "/etc/sudo.conf",
    ])
    .map(|s| s.lines().next().unwrap_or("").to_string())
    .unwrap_or_default();
    if owner.is_empty() {
        return false;
    }
    owner != "0"
}

fn sysbox_box_damage_report(session: &str) {
    err(&format!(
        "ERROR: container '{session}' is damaged: its filesystem id mapping is missing."
    ));
    err("       Inside the box, files the host owns as uid 0 appear as uid 65534");
    err("       (nobody), so sudo refuses to run:");
    err("         sudo: /etc/sudo.conf is owned by uid 65534, should be 0");
    err("       The files are correct on disk; the id mapping that translates them");
    err("       was not applied. This happens when the sysbox daemons (sysbox-mgr,");
    err("       sysbox-fs) are restarted while the box exists: the daemons lose");
    err("       their state for existing containers, and the box's next start comes");
    err("       up without its id mapping. The box cannot be repaired in place.");
    err("       Migrate it: that rebuilds the box on the current stack and carries");
    err("       its home directory, your agent sessions, across:");
    err(&format!("         lbx --migrate {session}"));
    err("       Recreating it by hand also works, but loses everything the box");
    err("       accumulated outside /data:");
    err(&format!(
        "         lbx --destroy --runtime sysbox {session}"
    ));
    err(&format!("         lbx --runtime sysbox {session}"));
}

/// Attach: exec into the box (replaces this process on success).
fn attach_session(session: &str, host_user: &str) -> i32 {
    use std::os::unix::process::CommandExt;
    for _ in 0..30 {
        if Docker::quiet(&["exec", session, "test", "-f", "/tmp/.user-ready"]) {
            break;
        }
        std::thread::sleep(std::time::Duration::from_secs(1));
    }
    let mut exec_user = host_user.to_string();
    if !Docker::quiet(&["exec", session, "id", host_user]) {
        err(&format!(
            "WARNING: user '{host_user}' not found in container, falling back to 'agent'"
        ));
        exec_user = "agent".into();
    }
    out("");
    out("  Welcome to llm in a box... where agents are constrained");
    out("");
    let e = std::process::Command::new("docker")
        .args([
            "exec",
            "-it",
            "-e",
            "HOME=/home/agent",
            "-w",
            "/data",
            session,
            "gosu",
            &exec_user,
            "bash",
        ])
        .exec();
    err(&format!("ERROR: could not exec docker: {e}"));
    1
}

fn find_free_port(candidates: &[u16]) -> Option<u16> {
    for p in candidates {
        if std::net::TcpListener::bind(("0.0.0.0", *p)).is_ok() {
            return Some(*p);
        }
    }
    None
}

/// The interactive dispatch on a container runtime. Returns an exit code.
pub fn launch(l: &Launch) -> i32 {
    let _ = l.cfg;
    let session = l.session.as_str();
    let runtime = l.runtime.as_str();
    if !Docker::available() {
        err("ERROR: docker is not installed or not on PATH.");
        return 1;
    }
    if l.fuse {
        match runtime {
            "sysbox" => {
                err("ERROR: FUSE is not compatible with sysbox.");
                err(
                    "       sysbox-fs uses FUSE internally, which conflicts with user FUSE mounts.",
                );
                return 1;
            }
            "docker" => out("    (FUSE available via --privileged mode)"),
            _ => {}
        }
    }
    let state = Docker::state(session).unwrap_or_else(|| "missing".into());
    if state != "missing" && Docker::container_label(session, "llm-in-a-box.mode") == "run" {
        err(&format!(
            "ERROR: '{session}' is a run box of an unattended run (lbx --run); it cannot be attached to or started."
        ));
        err(&format!("       Remove it with:  lbx --destroy {session}"));
        return 1;
    }
    match state.as_str() {
        "running" => {
            if sysbox_box_damaged(session, runtime) {
                sysbox_box_damage_report(session);
                return 1;
            }
            out(&format!(
                "==> Attaching to running container '{session}' ({runtime}) ..."
            ));
            attach_session(session, &l.host_user)
        }
        "exited" | "created" => {
            let stamp = Docker::container_label(session, "llm-in-a-box.user");
            if stamp.is_empty() {
                err(&format!(
                    "ERROR: container '{session}' is an OLD box (created by a previous version of"
                ));
                err("       the tooling, without the box-user stamp).");
                err("       lbx only starts boxes created by the current tooling.");
                err("       Use the previous llm_in_a_box script for this box, or destroy and");
                err(&format!(
                    "       recreate it:  lbx --destroy --runtime {runtime} {session}"
                ));
                return 1;
            }
            out(&format!(
                "==> Starting stopped container '{session}' ({runtime}) ..."
            ));
            let relay = relay_container_name(session);
            if Docker::container_exists(&relay) && !Docker::quiet(&["start", &relay]) {
                return 1;
            }
            if !Docker::quiet(&["start", session]) {
                return 1;
            }
            if !wait_for_running(session) {
                return 1;
            }
            if sysbox_box_damaged(session, runtime) {
                sysbox_box_damage_report(session);
                return 1;
            }
            attach_session(session, &l.host_user)
        }
        "missing" => create(l),
        other => {
            err(&format!(
                "ERROR: Session '{session}' is in unexpected state: {other}"
            ));
            err(&format!(
                "       You may need to remove it:  lbx --destroy {session}"
            ));
            1
        }
    }
}

fn create(l: &Launch) -> i32 {
    let cfg = l.cfg;
    let _ = cfg.state_dir.as_path();
    let session = l.session.as_str();
    let runtime = l.runtime.as_str();
    out(&format!(
        "==> Creating new container '{session}' ({runtime}) ..."
    ));
    let mut image = match runtime {
        "sysbox" => cfg.image_sysbox.clone(),
        _ => cfg.image_docker.clone(),
    };
    if !Docker::image_exists(&image) {
        if Docker::image_exists(IMAGE_LEGACY) {
            err(&format!(
                "WARNING: configured image '{image}' is missing; falling back to '{IMAGE_LEGACY}'."
            ));
            out(&format!(
                "    (image {image} not found, falling back to {IMAGE_LEGACY})"
            ));
            image = IMAGE_LEGACY.to_string();
        } else {
            err(&format!("ERROR: Image '{image}' not found."));
            err(&format!("       Build it first:  ./build {runtime}"));
            return 1;
        }
    }
    if runtime == "sysbox" {
        if !Docker::has_runtime("sysbox-runc") {
            err("ERROR: sysbox-runc runtime not found in Docker.");
            err("       Install sysbox first — see README.md for instructions.");
            return 1;
        }
        if crate::util::lbx_env("TEST_FUSERMOUNT3_MISSING").is_some()
            || crate::util::which("fusermount3").is_none()
        {
            err("ERROR: sysbox needs 'fusermount3', which was not found.");
            err("       sysbox-fs is a FUSE filesystem; without this helper every");
            err("       container create fails with 'failed to pre-register with");
            err("       sysbox-fs'. The sysbox-ce package depends on fuse (version 2)");
            err("       but does not install the fuse3 package that provides it.");
            err("       Install it:  sudo apt-get install -y fuse3");
            return 1;
        }
        // Docker 28+ (containerd 2.x) requires the runtime to declare the
        // `time` namespace; sysbox-runc 0.7.0 does not, 0.7.1 does. The
        // declaration is read out of the JSON's linux.namespaces list rather
        // than matched as text: the output also contains the mount options
        // atime, diratime, lazytime and noatime. A parse that fails, or a
        // list without `time`, is the unusable case.
        if crate::util::which("sysbox-runc").is_some()
            && crate::migrate::sysbox_runc_declares_time() != Some(true)
        {
            err("ERROR: this sysbox-runc cannot run on the installed Docker.");
            err("       It does not declare the 'time' Linux namespace, which");
            err("       containerd 2.x (Docker 28+) requires; every container create");
            err("       fails with: namespace {\"time\" \"\"} does not exist");
            err("       Upgrade sysbox to 0.7.1 or later — see README.md.");
            // Name the boxes that already exist, and the order that matters
            // for them: installing sysbox restarts its daemons, which damages
            // the id mapping of existing boxes, and migrating afterwards is
            // what carries their contents across.
            let boxes = crate::migrate::list_sysbox_sessions();
            if !boxes.is_empty() {
                err("");
                err(&format!(
                    "       {} sysbox box(es) already exist:",
                    boxes.len()
                ));
                for b in &boxes {
                    err(&format!("         {b}"));
                }
                err("       Upgrade sysbox FIRST, then migrate them: the upgrade is what");
                err("       damages their id mapping, and the migration is what carries");
                err("       their contents, your agent sessions, across.");
                err("         lbx --migrate --all");
                err("       Their /data directories are untouched either way.");
            }
            return 1;
        }
    }
    let mut netwall = None;
    if !l.net_policy.is_empty() {
        let relay_name = relay_container_name(session);
        let net_name = relay_network_name(session);
        let relaynet_name = relay_egress_network_name(session);
        let netlogs = cfg.state_dir.join("netlogs").join(session);
        let _ = std::fs::create_dir_all(&netlogs);
        out(&format!(
            "    (netwall: --internal network '{net_name}' + relay '{relay_name}'; policy {})",
            l.net_policy
        ));
        if !Docker::quiet(&["network", "create", "--internal", &net_name]) {
            err("ERROR: could not create the per-session internal network.");
            return 1;
        }
        if !Docker::quiet(&["network", "create", &relaynet_name]) {
            err("ERROR: could not create the relay egress network.");
            let _ = Docker::quiet(&["network", "rm", &net_name]);
            return 1;
        }
        let argv = interactive_relay_argv(
            &relay_name,
            l.host_uid,
            l.host_gid,
            &l.net_policy,
            &path_str(&netlogs),
            &net_name,
            &relaynet_name,
        );
        if !Docker::quiet_owned(&argv) {
            err(
                "ERROR: could not start the netwall relay (is the relay image built? ./build relay).",
            );
            let _ = Docker::quiet(&["network", "rm", &net_name, &relaynet_name]);
            return 1;
        }
        netwall = Some(Netwall {
            relay_name,
            net_name,
            policy: l.net_policy.clone(),
        });
    }
    let mut devices = Vec::new();
    for dev in &l.devices {
        if !std::path::Path::new(dev).exists() {
            err(&format!(
                "WARNING: Device '{dev}' does not exist on the host — skipping."
            ));
        } else {
            devices.push(dev.clone());
            out(&format!("    (passing through device {dev})"));
        }
    }
    let gh_token = std::env::var("GH_TOKEN").ok().filter(|t| !t.is_empty());
    if gh_token.is_some() {
        out("    (forwarding GH_TOKEN from host environment)");
    }
    if runtime == "sysbox" {
        out("    (granting NET_ADMIN + /dev/net/tun — sysbox runtime; enables");
        out("     bridged VM networking.)");
    }
    let mut ports = Vec::new();
    for pub_ in &l.publish {
        ports.push(pub_.clone());
        let host = pub_.split(':').next().unwrap_or("");
        let boxp = pub_.rsplit(':').next().unwrap_or("");
        out(&format!(
            "    (publishing host {host} -> container {boxp} via --publish)"
        ));
    }
    if !l.vm_web_port.is_empty() {
        let host = l.vm_web_port.split(':').next().unwrap_or("");
        ports.push(format!("{host}:{host}"));
        out(&format!(
            "    (forwarding host port {host} -> VM via --vm-web-port {})",
            l.vm_web_port
        ));
    }
    if l.ports {
        match find_free_port(&[8080, 18080, 28080]) {
            Some(p) => {
                ports.push(format!("{p}:8080"));
                out(&format!("    (forwarding host {p} -> container 8080)"));
            }
            None => {
                err("WARNING: No free port found for container 8080 (tried 8080, 18080, 28080).")
            }
        }
        match find_free_port(&[3000, 13000, 23000]) {
            Some(p) => {
                ports.push(format!("{p}:3000"));
                out(&format!("    (forwarding host {p} -> container 3000)"));
            }
            None => {
                err("WARNING: No free port found for container 3000 (tried 3000, 13000, 23000).")
            }
        }
    }
    let box_user = crate::docker::box_user(&image);
    let cwd = std::env::current_dir()
        .map(|p| path_str(&p))
        .unwrap_or_default();
    let argv = interactive_run_argv(&InteractiveRun {
        runtime: runtime.into(),
        session: session.into(),
        image,
        box_user,
        host_user: l.host_user.clone(),
        host_uid: l.host_uid,
        host_gid: l.host_gid,
        gh_token,
        vm_web_port: l.vm_web_port.clone(),
        netwall,
        devices,
        ports,
        data_dir: cwd,
    });
    let o = Docker::run_owned(&argv);
    if !o.ok {
        if !o.stderr.is_empty() {
            err(o.stderr.trim_end_matches('\n'));
        }
        for line in create_failure_hint(&o.stderr) {
            err(line);
        }
        return 1;
    }
    if !wait_for_running(session) {
        return 1;
    }
    attach_session(session, &l.host_user)
}

/// Extra lines for a failed `docker run` of a new box, keyed on the daemon's
/// error text. Empty when the text is not one we know a cause for.
///
/// "failed to pre-register with sysbox-fs" is sysbox-fs refusing the
/// container; its own log holds the reason. The one seen on current Ubuntu
/// (25.04 and later) is the fusermount3 AppArmor profile denying the FUSE
/// mount under /var/lib/sysboxfs, which the shipped override fixes.
pub fn create_failure_hint(stderr: &str) -> Vec<&'static str> {
    if stderr.contains("pre-register with sysbox-fs") {
        return vec![
            "       sysbox-fs refused to pre-register the container. Its log has the",
            "       cause:  journalctl -u sysbox-fs -n 20",
            "       On Ubuntu 25.04 and later the fusermount3 AppArmor profile denies",
            "       FUSE mounts under /var/lib/sysboxfs (\"fusermount3: mount failed:",
            "       Permission denied\" in that log). Allow them with the override",
            "       shipped in this repository:",
            "         sudo install -m 644 apparmor/fusermount3-sysboxfs /etc/apparmor.d/local/fusermount3",
            "         sudo apparmor_parser -r /etc/apparmor.d/fusermount3",
        ];
    }
    Vec::new()
}

/// vm destroy: kill the live qemu, remove the session directory.
pub fn vm_destroy(cfg: &Resolved, name: &str) -> bool {
    let sdir = vm_sessions_dir(cfg).join(name);
    if !sdir.is_dir() {
        err(&format!("vm session '{name}' does not exist."));
        return false;
    }
    if let Some(pid) = vm_live_pid_for(cfg, name) {
        out(&format!("==> Stopping vm '{name}' ..."));
        // SAFETY: a plain kill of a pid this user owns.
        unsafe {
            libc::kill(pid as libc::pid_t, libc::SIGTERM);
        }
        std::thread::sleep(std::time::Duration::from_secs(1));
    }
    let _ = std::fs::remove_dir_all(&sdir);
    out(&format!("==> Removed vm session '{name}'."));
    true
}

/// vm --force stop: SIGKILL the live qemu, clear the pidfile.
pub fn vm_force_stop(cfg: &Resolved, name: &str) {
    let Some(pid) = vm_live_pid_for(cfg, name) else {
        err(&format!("vm '{name}' is not running."));
        return;
    };
    out(&format!("==> Force-stopping vm '{name}' (SIGKILL) ..."));
    // SAFETY: a plain kill of a pid this user owns.
    unsafe {
        libc::kill(pid as libc::pid_t, libc::SIGKILL);
    }
    std::thread::sleep(std::time::Duration::from_secs(1));
    let _ = std::fs::remove_file(vm_sessions_dir(cfg).join(name).join("qemu.pid"));
    out(&format!("==> vm '{name}' force-stopped."));
}

fn pid_alive(pid: u32) -> bool {
    // SAFETY: signal 0 only probes.
    unsafe { libc::kill(pid as libc::pid_t, 0) == 0 }
}

/// vm graceful shutdown: ssh poweroff when a port is recorded, wait, then
/// force. The monitor-socket step is not ported.
pub fn vm_shutdown(cfg: &Resolved, name: &str, host_user: &str) -> bool {
    let sdir = vm_sessions_dir(cfg).join(name);
    if !sdir.is_dir() {
        err(&format!("vm session '{name}' does not exist."));
        return false;
    }
    let Some(pid) = vm_live_pid_for(cfg, name) else {
        err(&format!("vm '{name}' is not running."));
        return true;
    };
    if let Some(port) = read_trim(&sdir.join("ssh_port")) {
        out(&format!(
            "==> Shutting down vm '{name}' via ssh (sudo poweroff) ..."
        ));
        let ok = std::process::Command::new("timeout")
            .args([
                "15",
                "ssh",
                "-o",
                "BatchMode=yes",
                "-o",
                "ConnectTimeout=5",
                "-o",
                "StrictHostKeyChecking=no",
                "-o",
                "UserKnownHostsFile=/dev/null",
                "-p",
                &port,
                &format!("{host_user}@127.0.0.1"),
                "nohup sh -c 'sleep 2; sudo -n poweroff' >/dev/null 2>&1 & exit 0",
            ])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .is_ok_and(|s| s.success());
        if ok {
            out("    (poweroff requested)");
        }
    }
    for _ in 0..60 {
        if !pid_alive(pid) {
            out(&format!("==> vm '{name}' stopped."));
            return true;
        }
        std::thread::sleep(std::time::Duration::from_secs(1));
    }
    err(&format!(
        "ERROR: vm '{name}' did not shut down cleanly; force-stopping qemu."
    ));
    // SAFETY: a plain kill of a pid this user owns.
    unsafe {
        libc::kill(pid as libc::pid_t, libc::SIGTERM);
    }
    std::thread::sleep(std::time::Duration::from_secs(1));
    let _ = std::fs::remove_file(sdir.join("qemu.pid"));
    out(&format!("==> vm '{name}' force-stopped."));
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn create_failure_hint_names_the_apparmor_cause_for_sysbox_fs_preregistration() {
        let daemon = "docker: Error response from daemon: failed to create task for container: \
            failed to create shim task: OCI runtime create failed: failed to pre-register \
            with sysbox-fs: failed to pre-register container with sysbox-fs: rpc error: \
            code = Internal desc = Initialization error for container-id 872d6d: unknown";
        let hint = create_failure_hint(daemon).join("\n");
        assert!(hint.contains("journalctl -u sysbox-fs"));
        assert!(hint.contains("/etc/apparmor.d/local/fusermount3"));
        assert!(hint.contains("apparmor_parser -r /etc/apparmor.d/fusermount3"));
        assert!(
            create_failure_hint("docker: Error response from daemon: No such image: x").is_empty()
        );
        assert!(create_failure_hint("").is_empty());
    }

    #[test]
    fn list_rows_sort_bytewise_by_name_with_fixed_columns() {
        let rows = vec![
            "zeta|docker|running|-|-".to_string(),
            "Beta|vm|exited|2222|/p/enforce.json".to_string(),
            "alpha|sysbox|exited|-|-".to_string(),
        ];
        let lines = format_list(rows);
        assert_eq!(
            lines,
            vec![
                "NAME                     RUNTIME  STATE      PORT   NET-POLICY".to_string(),
                "Beta                     vm       exited     2222   /p/enforce.json".to_string(),
                "alpha                    sysbox   exited     -      -".to_string(),
                "zeta                     docker   running    -      -".to_string(),
            ]
        );
        assert_eq!(format_list(Vec::new()).len(), 1);
    }

    #[test]
    fn runtime_choice_prefers_the_usable_default_else_auto_order() {
        let all = ["vm", "sysbox", "docker"];
        assert_eq!(choose_runtime(&all, ""), ("vm".to_string(), vec![]));
        assert_eq!(
            choose_runtime(&all, "docker"),
            ("docker".to_string(), vec![])
        );
        let (r, w) = choose_runtime(&["docker"], "vm");
        assert_eq!(r, "docker");
        assert_eq!(
            w,
            vec![
                "WARNING: runtime.default 'vm' is not usable here; using the auto-detected runtime."
            ]
        );
        let (r, w) = choose_runtime(&["sysbox", "docker"], "lxc");
        assert_eq!(r, "sysbox");
        assert_eq!(
            w,
            vec!["WARNING: invalid runtime.default 'lxc'; ignoring it."]
        );
        assert_eq!(choose_runtime(&[], "docker").0, "");
    }

    #[test]
    fn sibling_and_lookup_helpers() {
        let l = Lookup::Ambiguous(vec!["vm".into(), "docker".into()]);
        assert_eq!(sibling_of_target(&l, "vm"), "docker");
        assert_eq!(sibling_of_target(&l, "docker"), "vm");
        assert_eq!(sibling_of_target(&Lookup::Missing, "vm"), "");
        assert_eq!(l.runtimes_joined(), "vm,docker");
        assert_eq!(
            select_target_runtime("s", &Lookup::Missing, "", true),
            Some("missing".into())
        );
        assert_eq!(
            select_target_runtime("s", &l, "docker", true),
            Some("docker".into())
        );
    }
}
