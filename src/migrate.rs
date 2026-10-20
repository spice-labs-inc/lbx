//! `--migrate`: move existing sysbox sessions onto the current stack.
//!
//! WHY THIS EXISTS. An existing sysbox box whose id mapping has been lost
//! cannot be repaired in place: its sudo is broken and nothing inside it can
//! fix that, because uid 0 in the container's user namespace does not map to
//! the host uid that owns the files. The only remedy is to build a fresh box.
//! Doing that by hand means losing everything the box accumulated, which is
//! why this exists: it carries the box's home directory across.
//!
//! WHY NOT `docker commit`. Committing while the id mapping is broken reads
//! ownership THROUGH the broken mapping and writes the overflow uid into the
//! image for every path owned by the box user, and the result cannot be
//! repaired from inside. Measured: a box user's file is 1000:1000 in the box
//! and 166536:166536 on the host, but 65534:65534 in a container started
//! from the commit.
//!
//! WHAT IS ACTUALLY WRONG. The files are not damaged. Only the container's
//! VIEW of them is: the id-mapped mount is missing. Reading through the
//! host's /proc/<pid>/root gives correct content AND correct ownership, which
//! is the export path used below.
//!
//! WHAT SURVIVES. /data is a host bind mount, not part of the container, so
//! it survives untouched and is deliberately NOT copied. Everything else the
//! box accumulated lives in the container's writable layer; this migration
//! carries the box user's home directory, which is where the agent sessions
//! (pi, Claude Code, opencode) are kept. Hand-installed packages are lost,
//! and the replacement box carries a notice saying so.
//!
//! ORDER. The operator must upgrade sysbox BEFORE migrating, because the
//! replacement box is created on the current stack. Installing sysbox is
//! itself what damages the boxes that already exist, so a user who migrated
//! first and upgraded second would gain nothing.

use crate::config::Resolved;
use crate::docker::Docker;
use crate::util::{err, host_uid, out, path_str, which};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// The box's home directory, as the box user sees it, in a box built from
/// this crate's image (the image user is `agent`, renamed to the host user
/// by the entrypoint). This is the migration payload and the place the
/// agent notices are written.
pub const MIGRATE_HOME: &str = "/home/agent";

/// The home directory of a box created by the older launcher, whose image
/// user was `claude`. A box being migrated may be one of those, so the
/// export looks for it when the current home is absent; the replacement is
/// always built from the current image and restored under MIGRATE_HOME.
const LEGACY_HOME: &str = "/home/claude";

/// The agent context files. The agents load context files by exact name, so
/// a free-form name would never be read: pi reads AGENTS.override.md,
/// AGENTS.md, AGENTS.MD, CLAUDE.md, CLAUDE.MD from its agent directory and
/// from the working directory's ancestors; Claude Code reads CLAUDE.md; and
/// opencode reads AGENTS.md from its config directory and from the session
/// directory's ancestors. The box user normally works in /data, whose only
/// ancestor is /, so a notice placed in the home directory alone would be
/// missed. These three paths are read regardless of the working directory.
pub const NOTICE_PATHS: [&str; 3] = [
    ".pi/agent/AGENTS.md",
    ".claude/CLAUDE.md",
    ".config/opencode/AGENTS.md",
];

/// The notice itself. It is a task list the agent retires by deleting it,
/// rather than state the launcher tracks: the file is a permanent context
/// file, so leaving it in place would keep telling the agent that its
/// packages are gone long after it reinstalled them.
pub fn notice_text(session: &str) -> String {
    format!(
        "# Your box was migrated

This box was rebuilt because the sysbox runtime it used can no longer run.
Its old container could not be repaired in place.

## What came across

Your home directory was carried over, so your agent sessions are here:

- pi sessions:       ~/.pi/agent/sessions/
- Claude Code:       ~/.claude/
- opencode:          ~/.config/opencode/

Your `/data` directory was never inside the box, so it is untouched.

## What did NOT come across

Packages you installed by hand inside the old box are GONE. Anything you
installed with apt, pip, npm -g, cargo install, or by hand is missing.
Images the box's own docker daemon had pulled or built are gone too.

## What to do

1. Reinstall anything you were relying on. To find out, try using it, or
   compare against what you remember installing.
2. Once you have handled that, DELETE THIS FILE. It is read at the start of
   every session, so leaving it in place will keep telling you that your
   packages are missing long after you have restored them.

    rm -f ~/.pi/agent/AGENTS.md ~/.claude/CLAUDE.md ~/.config/opencode/AGENTS.md

This file was written by `lbx --migrate` for the session `{session}`.
"
    )
}

/// Whether `sysbox-runc features` output declares the `time` Linux
/// namespace: `Some(true)` when linux.namespaces lists it, `Some(false)`
/// when the JSON parses but does not, `None` when it is not JSON at all.
/// Parsed, not matched as text: the same output contains the mount options
/// atime/diratime/lazytime/noatime, which a text match for "time" would
/// mistake for the namespace.
pub fn features_declare_time(features: &str) -> Option<bool> {
    let v: serde_json::Value = serde_json::from_str(features).ok()?;
    Some(
        v.get("linux")
            .and_then(|l| l.get("namespaces"))
            .and_then(|n| n.as_array())
            .is_some_and(|ns| ns.iter().any(|x| x.as_str() == Some("time"))),
    )
}

/// Run `sysbox-runc features` and parse it (see `features_declare_time`).
pub fn sysbox_runc_declares_time() -> Option<bool> {
    let o = Command::new("sysbox-runc")
        .arg("features")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    features_declare_time(&String::from_utf8_lossy(&o.stdout))
}

/// A command with the privilege needed to read another container's
/// filesystem. Reading /proc/<pid>/root belongs to the container's owning
/// user, which is not the operator, so this needs root; the launcher
/// otherwise never needs it (everything else goes through the docker
/// socket). Root directly, else passwordless sudo, else fail with something
/// the operator can act on.
fn as_root(program: &str) -> Option<Command> {
    if host_uid() == 0 {
        return Some(Command::new(program));
    }
    let sudo_ok = which("sudo").is_some()
        && Command::new("sudo")
            .args(["-n", "true"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|s| s.success());
    if sudo_ok {
        let mut c = Command::new("sudo");
        c.arg("-n").arg(program);
        return Some(c);
    }
    err("ERROR: --migrate needs root (or passwordless sudo) to read a box's filesystem.");
    err("       It reads /proc/<pid>/root of the box being migrated, which belongs to");
    err("       the container's owning user. Re-run this command with sudo.");
    None
}

fn quiet(c: &mut Command) -> bool {
    c.stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

/// First line of a container-inspect answer, empty when it failed.
fn inspect_first(name: &str, fmt: &str) -> String {
    Docker::container_fmt(name, fmt)
        .map(|s| s.lines().next().unwrap_or("").to_string())
        .unwrap_or_default()
}

fn runtime_label(name: &str) -> String {
    Docker::container_label(name, "llm-in-a-box.runtime")
}

/// Print what a migration would do, for one session. Read-only: it must
/// work on a host where the runtime cannot run at all, because that is the
/// situation the operator is in when they need it. Returns 0 (would
/// migrate), 1 (not a session), 2 (not sysbox).
pub fn report_one(name: &str) -> i32 {
    let rt = runtime_label(name);
    if rt.is_empty() {
        out(&format!(
            "  {name:<20} not a llm-in-a-box session (no such container, or no runtime label)"
        ));
        return 1;
    }
    if rt != "sysbox" {
        out(&format!(
            "  {name:<20} skip: {rt} runtime, not sysbox, nothing to migrate"
        ));
        return 2;
    }
    let mut state = inspect_first(name, "{{.State.Status}}");
    if state.is_empty() {
        state = "-".into();
    }
    let image = inspect_first(name, "{{.Config.Image}}");
    out(&format!(
        "  {name:<20} {state:<9} would migrate: export {MIGRATE_HOME}, build a replacement, verify it, then remove this box"
    ));
    out(&format!(
        "  {:<20} from image {image}; /data is untouched and is not copied",
        ""
    ));
    0
}

/// Every sysbox session, by name.
pub fn list_sysbox_sessions() -> Vec<String> {
    if !Docker::available() {
        return Vec::new();
    }
    Docker::ps_names()
        .into_iter()
        .filter(|n| !n.is_empty() && runtime_label(n) == "sysbox")
        .collect()
}

/// Refuse when the installed runtime cannot create the replacement box, and
/// say so in the order the operator must follow. Checked BEFORE any
/// container is created or removed: a migration that refused halfway would
/// have left a mess.
pub fn require_usable_runtime() -> bool {
    if which("sysbox-runc").is_none() {
        err("ERROR: cannot migrate: sysbox-runc is not installed.");
        err("       The replacement box is built on the current stack, so sysbox must");
        err("       be installed and working BEFORE migrating. See README.md.");
        return false;
    }
    match sysbox_runc_declares_time() {
        Some(true) => true,
        None => {
            err("ERROR: cannot migrate: could not read 'sysbox-runc features'.");
            err("       Check that sysbox is installed and working, then try again.");
            false
        }
        Some(false) => {
            err("ERROR: this sysbox-runc cannot run on the installed Docker.");
            err("       It does not declare the 'time' Linux namespace, which containerd 2.x");
            err("       (Docker 28+) requires, so every container create fails with:");
            err("         namespace {\"time\" \"\"} does not exist");
            err("");
            err("       UPGRADE SYSBOX FIRST, THEN MIGRATE. The replacement box is built");
            err("       on the current stack, so upgrading has to come first.");
            err("       Upgrading sysbox restarts its daemons, and that is what damages the");
            err("       boxes that already exist; migrating is what carries their contents");
            err("       across afterwards.");
            err("");
            err("       Upgrade sysbox to 0.7.1 or later, then run this again:");
            err("         sudo apt-get remove --purge -y sysbox-ce && sudo rm -rf /var/lib/sysbox");
            err("         sudo dpkg -i sysbox-ce_0.7.1-0.linux_amd64.deb");
            err("         sudo apt-get install -y fuse3");
            err("         sysbox-runc --version   # expect 0.7.1");
            err("");
            err("       See README.md, section \"Sysbox\".");
            false
        }
    }
}

/// Export one box's home directory to a tar, through the HOST's view of its
/// filesystem. This is the only path that works on a damaged box: exec may
/// be broken, and reading through the container would corrupt the
/// ownership.
fn export_box(name: &str, out_tar: &Path) -> bool {
    let pid = Docker::line(&["inspect", "-f", "{{.State.Pid}}", name])
        .map(|s| s.lines().next().unwrap_or("").to_string())
        .unwrap_or_default();
    if pid.is_empty() || pid == "0" {
        err(&format!(
            "    cannot read the box's filesystem: it is not running (pid {pid})"
        ));
        return false;
    }
    // The filesystem must be readable from the host side, which is true
    // even when exec into the box has stopped working. The box may have been
    // created by the older launcher, whose home was LEGACY_HOME, so both are
    // tried, the current one first.
    let mut home = "";
    for candidate in [MIGRATE_HOME, LEGACY_HOME] {
        let Some(mut c) = as_root("test") else {
            return false;
        };
        c.arg("-d").arg(format!("/proc/{pid}/root{candidate}"));
        if quiet(&mut c) {
            home = candidate;
            break;
        }
    }
    if home.is_empty() {
        err(&format!(
            "    cannot read /proc/{pid}/root{MIGRATE_HOME} from the host"
        ));
        return false;
    }
    // --numeric-owner records the host-side ids. Every sysbox box on a host
    // shares one id range (from /etc/subuid), so those ids restore to the
    // same in-box ids in the replacement box.
    let Some(mut c) = as_root("tar") else {
        return false;
    };
    c.args(["--numeric-owner", "-C"])
        .arg(format!("/proc/{pid}/root{home}"))
        .arg("-cf")
        .arg(out_tar)
        .arg(".");
    quiet(&mut c)
}

/// Restore the payload into the replacement, as the container's root, then
/// give it to the box user.
///
/// The payload goes through a PIPE, not `docker cp`. Two measured reasons:
/// `docker cp` into a container that has a volume mounted fails while the
/// daemon walks the container's filesystem to resolve the destination
/// ("mkdirat var/lib/docker: directory not empty"), and every box has a
/// per-session volume at /var/lib/docker; and `docker cp` has been observed
/// reporting success while copying nothing. A pipe has no destination path
/// for the daemon to walk, and its exit status is the extractor's, so a
/// failure cannot pass unnoticed.
fn restore_box(name: &str, tar: &Path, uid: &str, gid: &str) -> bool {
    let Ok(payload) = std::fs::File::open(tar) else {
        return false;
    };
    Command::new("docker")
        .args(["exec", "-i", "-u", "0", name, "bash", "-c"])
        .arg(format!(
            "cd {MIGRATE_HOME} && tar -xf - --no-same-owner && chown -R {uid}:{gid} {MIGRATE_HOME}"
        ))
        .stdin(Stdio::from(payload))
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

/// Write the notice into a box, at every path an agent reads, owned by the
/// box user and readable by it. False if any of them could not be written.
///
/// Everything is done AS THE BOX USER, which is what makes the ownership
/// right without a chown: a file placed by the container's root cannot be
/// re-owned afterwards (uid 0 inside maps to an unprivileged host uid), and
/// a directory created by it could not be written into by the box user
/// either. Writing through stdin uses no destination path, so there is
/// nothing to go stale between calls.
fn write_notice(name: &str, uid: &str, gid: &str) -> bool {
    use std::io::Write;
    let user = format!("{uid}:{gid}");
    let mut ok = true;
    for rel in NOTICE_PATHS {
        let dir = Path::new(rel).parent().map(path_str).unwrap_or_default();
        if !Docker::quiet(&[
            "exec",
            "-u",
            &user,
            name,
            "mkdir",
            "-p",
            &format!("{MIGRATE_HOME}/{dir}"),
        ]) {
            ok = false;
            continue;
        }
        let child = Command::new("docker")
            .args(["exec", "-i", "-u", &user, name, "sh", "-c"])
            .arg(format!("cat > {MIGRATE_HOME}/{rel}"))
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();
        let Ok(mut child) = child else {
            ok = false;
            continue;
        };
        let written = child
            .stdin
            .take()
            .is_some_and(|mut w| w.write_all(notice_text(name).as_bytes()).is_ok());
        if !written || !child.wait().is_ok_and(|s| s.success()) {
            ok = false;
        }
    }
    ok
}

/// Verify a replacement box before the old one is removed. Every one of
/// these must hold; a migration that half-worked would otherwise destroy
/// the only copy of the operator's work.
///
/// The decisive test is that the box's id mapping is APPLIED, which is what
/// makes sudo work. The box's OWN view of /etc/sudo.conf is that test:
/// a healthy box sees `0 0` (the host sees 165536 165536), a damaged box
/// sees `65534 65534` (the host sees 0 0). The host's view is not usable
/// here, since the two views disagree on a healthy box by design.
fn verify_box(name: &str, uid: &str, payload: &Path) -> bool {
    let box_view = Docker::line(&[
        "exec",
        "-u",
        "0",
        name,
        "stat",
        "-c",
        "%u %g",
        "/etc/sudo.conf",
    ])
    .map(|s| s.lines().next().unwrap_or("").to_string())
    .unwrap_or_default();
    if box_view != "0 0" {
        return false;
    }
    let user = format!("{uid}:{uid}");
    // sudo must actually work as the box user.
    if !Docker::quiet(&["exec", "-u", &user, name, "sudo", "-n", "true"]) {
        return false;
    }
    // The payload must actually be there, and belong to the box user. The
    // restore re-owns everything it restores, so a restore that silently did
    // nothing would otherwise pass and let the original, the only copy of
    // the operator's work, be removed. The box may legitimately hold MORE
    // entries than the payload (the notice, the entrypoint's own files).
    let home_owner = Docker::line(&["exec", "-u", "0", name, "stat", "-c", "%u", MIGRATE_HOME])
        .map(|s| s.lines().next().unwrap_or("").to_string())
        .unwrap_or_default();
    if home_owner != uid {
        return false;
    }
    if !Docker::quiet(&["exec", "-u", &user, name, "ls", "-A", MIGRATE_HOME]) {
        return false;
    }
    let want = Command::new("tar")
        .arg("-tf")
        .arg(payload)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).lines().count())
        .unwrap_or(0);
    let got = Docker::run(&[
        "exec",
        "-u",
        "0",
        name,
        "find",
        MIGRATE_HOME,
        "-mindepth",
        "1",
    ])
    .stdout
    .lines()
    .count();
    got >= want
}

/// Read the identity a box was created with, from its environment. The
/// launcher passes `-e HOST_USER`, `-e HOST_UID` and `-e HOST_GID`, and the
/// entrypoint creates that user and writes its NOPASSWD rule to
/// /etc/sudoers.d/agent. The replacement must be created as the SAME user
/// the original was, and the original box's own environment is the only
/// reliable source: `--migrate` needs root, so the invoking user is usually
/// NOT the box's user.
pub fn box_identity(name: &str, var: &str) -> String {
    Docker::line(&[
        "inspect",
        "-f",
        "{{range .Config.Env}}{{println .}}{{end}}",
        name,
    ])
    .and_then(|s| {
        s.lines()
            .find_map(|l| l.strip_prefix(&format!("{var}=")).map(str::to_string))
    })
    .unwrap_or_default()
}

/// `mktemp -d "${TMPDIR:-/tmp}/lbx-migrate.XXXXXX"`.
fn make_work_dir() -> Option<PathBuf> {
    let base = std::env::var_os("TMPDIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    for _ in 0..10 {
        let suffix = crate::util::random_hex16()?;
        let dir = base.join(format!("lbx-migrate.{}", &suffix[..6]));
        if std::fs::create_dir(&dir).is_ok() {
            return Some(dir);
        }
    }
    None
}

/// The home of the box user on this host (`getent passwd <uid>`).
fn passwd_home(uid: &str) -> String {
    Command::new("getent")
        .args(["passwd", uid])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()
        .and_then(|o| {
            String::from_utf8_lossy(&o.stdout)
                .lines()
                .next()
                .and_then(|l| l.split(':').nth(5).map(str::to_string))
        })
        .unwrap_or_default()
}

/// Create the replacement box by re-running this launcher from the
/// directory the operator started in. It is created AS THE BOX'S OWN USER:
/// the box user is derived from the user that runs the launcher, so running
/// the nested launcher as root (under sudo) would give the replacement the
/// wrong box user. `--init-groups` keeps the supplementary groups, the
/// docker group among them, which the nested launcher needs.
fn create_replacement(cfg: &Resolved, replacement: &str, uid: &str, gid: &str, invoke_dir: &Path) {
    let Ok(exe) = std::env::current_exe() else {
        return;
    };
    let mut home = crate::util::home_dir();
    let mut cmd;
    if host_uid() == 0 && uid != "0" {
        cmd = Command::new("setpriv");
        cmd.args(["--reuid", uid, "--regid", gid, "--init-groups"])
            .arg(&exe);
        // `sudo` resets HOME to root's home, so the nested launcher would
        // look for its configuration under /root. Give it the box user's own
        // home, which is where that user's configuration actually lives.
        let h = passwd_home(uid);
        if !h.is_empty() {
            home = PathBuf::from(h);
        }
    } else {
        cmd = Command::new(&exe);
    }
    let _ = cmd
        .args(["--runtime", "sysbox", replacement])
        .current_dir(invoke_dir)
        .env("HOME", &home)
        .env("LBX_STATE_DIR", &cfg.state_dir)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

/// Remove a container and the inner-docker volume the launcher gave it. The
/// volume is read from the mount table first and the session-named volume is
/// tried as well, so neither a discarded replacement nor a replaced original
/// leaves its storage behind.
fn remove_box_and_volume(name: &str) {
    let mut volumes = Docker::store_volumes(name);
    volumes.push(format!("{name}-docker"));
    let _ = Docker::quiet(&["rm", "-f", name]);
    volumes.dedup();
    for v in &volumes {
        let _ = Docker::quiet(&["volume", "rm", v]);
    }
}

fn discard(replacement: &str, work: &Path) {
    remove_box_and_volume(replacement);
    let _ = std::fs::remove_dir_all(work);
}

/// Migrate one session. Every step that can fail is checked, and the old
/// box is removed only after the replacement has been verified.
fn migrate_one(cfg: &Resolved, name: &str, dry: bool, invoke_dir: &Path) -> bool {
    let rt = runtime_label(name);
    if rt.is_empty() {
        err(&format!(
            "  {name}: cannot migrate: not a llm-in-a-box session"
        ));
        // A session that cannot be found is often in a different state
        // directory: `sudo` resets HOME, so `sudo lbx --migrate` resolves the
        // state directory under /root and sees none of the invoking user's
        // sessions. Without this note the error looks like the box does not
        // exist, which is misleading.
        if let Ok(su) = std::env::var("SUDO_USER")
            && !su.is_empty()
            && su != "root"
        {
            err(&format!(
                "       note: sudo resets HOME, so the launcher looked in '{}'.",
                path_str(&cfg.state_dir)
            ));
            err(&format!(
                "             Re-run as 'sudo -E lbx --migrate {name}' (or set LBX_STATE_DIR) to use"
            ));
            err("             your own state directory, which is where your sessions are.");
        }
        return false;
    }
    if rt != "sysbox" {
        out(&format!("  {name}: skipped: {rt} runtime, not sysbox"));
        return true;
    }
    let state = inspect_first(name, "{{.State.Status}}");
    let image = inspect_first(name, "{{.Config.Image}}");
    if dry {
        report_one(name);
        return true;
    }
    out(&format!(
        "  {name}: migrating (state {state}, image {image})"
    ));

    // The box must be running to export it through /proc/<pid>/root.
    if state != "running" {
        let _ = Docker::quiet(&["start", name]);
        std::thread::sleep(std::time::Duration::from_secs(2));
    }

    let Some(work) = make_work_dir() else {
        err(&format!("  {name}: cannot create a work directory"));
        return false;
    };
    let tar = work.join("home.tar");
    let replacement = format!("{name}-migrating{}", std::process::id());

    if !export_box(name, &tar) {
        err(&format!(
            "  {name}: FAILED: could not export the box's home directory"
        ));
        let _ = std::fs::remove_dir_all(&work);
        return false;
    }
    if std::fs::metadata(&tar).map(|m| m.len()).unwrap_or(0) == 0 {
        err(&format!("  {name}: FAILED: the export is empty"));
        let _ = std::fs::remove_dir_all(&work);
        return false;
    }

    // The identity the replacement must reproduce, read from the box itself.
    let mut box_uid = box_identity(name, "HOST_UID");
    let mut box_gid = box_identity(name, "HOST_GID");
    if box_uid.is_empty() {
        box_uid = "1000".into();
    }
    if box_gid.is_empty() {
        box_gid = "1000".into();
    }

    // Create the replacement under a temporary name, so the original is
    // untouched until the replacement has been proven good. The replacement
    // uses the CONFIGURED image (image.sysbox), not the old box's image: the
    // whole point is to move onto the current stack.
    create_replacement(cfg, &replacement, &box_uid, &box_gid, invoke_dir);
    if !Docker::container_exists(&replacement) {
        err(&format!(
            "  {name}: FAILED: could not create the replacement box"
        ));
        discard(&replacement, &work);
        return false;
    }

    // Wait for the replacement's entrypoint to finish setting up its user. A
    // replacement that never becomes ready is a failure: restoring into a
    // box whose user does not exist yet would leave the files owned by the
    // wrong ids.
    let mut ready = false;
    for _ in 0..90 {
        if Docker::quiet(&["exec", &replacement, "test", "-f", "/tmp/.user-ready"]) {
            ready = true;
            break;
        }
        std::thread::sleep(std::time::Duration::from_secs(1));
    }
    if !ready {
        err(&format!(
            "  {name}: FAILED: the replacement box did not finish starting"
        ));
        discard(&replacement, &work);
        return false;
    }

    if !restore_box(&replacement, &tar, &box_uid, &box_gid) {
        err(&format!(
            "  {name}: FAILED: could not restore the home directory into the replacement"
        ));
        discard(&replacement, &work);
        return false;
    }

    // The notice is written before verification: it is part of what the
    // replacement must contain.
    if !write_notice(&replacement, &box_uid, &box_gid) {
        err(&format!(
            "  {name}: warning: could not write the agent notice into every location"
        ));
    }

    if !verify_box(&replacement, &box_uid, &tar) {
        err(&format!(
            "  {name}: FAILED: the replacement did not verify; the original box is untouched"
        ));
        discard(&replacement, &work);
        return false;
    }

    // Verified. Replace the original. Its inner-docker volume goes with it:
    // the images it held were the old box's, the replacement has a volume of
    // its own, and nothing would ever mount the old one again.
    remove_box_and_volume(name);
    if !Docker::quiet(&["rename", &replacement, name]) {
        err(&format!(
            "  {name}: FAILED: the replacement verified but could not be renamed into place"
        ));
        err(&format!(
            "  {name}: the replacement is called '{replacement}'"
        ));
        let _ = std::fs::remove_dir_all(&work);
        return false;
    }
    let _ = std::fs::remove_dir_all(&work);
    out(&format!("  {name}: migrated"));
    true
}

/// Run the migration over the requested sessions. Every session is
/// attempted even if an earlier one failed: the operator needs to know
/// which boxes are done and which are not. Returns true when every session
/// was handled.
pub fn migrate_main(
    cfg: &Resolved,
    sessions: &[String],
    all: bool,
    dry: bool,
    invoke_dir: &Path,
) -> bool {
    let names: Vec<String> = if all {
        let names = list_sysbox_sessions();
        if names.is_empty() {
            out("No sysbox sessions to migrate.");
            return true;
        }
        names
    } else {
        sessions.to_vec()
    };

    if dry {
        out("Sessions to migrate:");
    } else {
        // The replacement is built on the current stack, so the stack has
        // to work before anything is touched.
        if !require_usable_runtime() {
            return false;
        }
        out("Migrating:");
    }

    let mut failed = false;
    for name in &names {
        if !migrate_one(cfg, name, dry, invoke_dir) {
            failed = true;
        }
    }

    if dry {
        out("");
        out("Nothing was changed. To do it: lbx --migrate <name>...");
        out("Upgrade sysbox BEFORE migrating: the replacement box is built on the current stack.");
        return !failed;
    }
    if failed {
        err("");
        err("ERROR: at least one session could not be migrated. Sessions that reported");
        err("       'migrated' are done; the others are untouched.");
        return false;
    }
    out("");
    out("Done. /data was not touched. Each migrated box carries a notice at");
    out("~/.pi/agent/AGENTS.md, ~/.claude/CLAUDE.md and ~/.config/opencode/AGENTS.md");
    out("listing what to reinstall; the agent deletes it when it has handled that.");
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn features_are_parsed_as_json_not_matched_as_text() {
        // Mount options named *time must not count as the namespace.
        let old = r#"{"linux":{"namespaces":["cgroup","ipc","mount","network","pid","user","uts"],"mountOptions":["atime","lazytime"]}}"#;
        assert_eq!(features_declare_time(old), Some(false));
        let new = r#"{"linux":{"namespaces":["cgroup","ipc","mount","network","pid","user","uts","time"]}}"#;
        assert_eq!(features_declare_time(new), Some(true));
        assert_eq!(features_declare_time(""), None);
        assert_eq!(features_declare_time("not json \"time\""), None);
        assert_eq!(features_declare_time("{}"), Some(false));
        assert_eq!(
            features_declare_time(r#"{"linux":{"namespaces":"time"}}"#),
            Some(false)
        );
    }

    #[test]
    fn notice_names_the_session_and_tells_the_agent_to_delete_it() {
        let t = notice_text("box-7");
        assert!(t.contains("for the session `box-7`."));
        assert!(t.contains("DELETE THIS FILE"));
        assert!(t.contains("Reinstall"));
        for rel in NOTICE_PATHS {
            assert!(t.contains(&format!("~/{rel}")), "{rel}");
        }
    }
}
