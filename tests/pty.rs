//! Interactive attach under a real pseudo-terminal (expectrl): `lbx <name>`
//! waits for the box's user-ready marker, probes the host user, prints the
//! welcome and replaces itself with `docker exec -it -e HOME=/home/agent -w
//! /data <name> gosu <user> bash`. Against fake-docker the shell is the
//! fake's line REPL; with `LBX_REAL_DOCKER=1` the same flow runs against the
//! real `llm-in-a-box:docker` image and the session is destroyed afterwards.

use expectrl::session::OsSession;
use expectrl::{Eof, Expect, Regex};
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::Command;
use std::time::Duration;

struct World {
    _tmp: tempfile::TempDir,
    root: PathBuf,
}

fn world() -> World {
    let tmp = tempfile::Builder::new()
        .prefix("lbxp-")
        .tempdir()
        .unwrap_or_else(|e| panic!("tempdir: {e}"));
    let root = tmp.path().to_path_buf();
    for d in ["bin", "home", "state", "cwd"] {
        std::fs::create_dir_all(root.join(d)).unwrap_or_else(|e| panic!("mkdir {d}: {e}"));
    }
    std::fs::set_permissions(root.join("cwd"), std::fs::Permissions::from_mode(0o755))
        .unwrap_or_else(|e| panic!("chmod: {e}"));
    World { _tmp: tmp, root }
}

impl World {
    fn p(&self, rel: &str) -> String {
        self.root.join(rel).to_string_lossy().into_owned()
    }

    /// The recorded fake-docker calls, one argv per line.
    fn calls(&self) -> Vec<String> {
        std::fs::read_to_string(self.root.join("calls.jsonl"))
            .unwrap_or_default()
            .lines()
            .map(|l| {
                let v: serde_json::Value =
                    serde_json::from_str(l).unwrap_or(serde_json::Value::Null);
                v["argv"]
                    .as_array()
                    .map(|a| {
                        a.iter()
                            .map(|x| x.as_str().unwrap_or(""))
                            .collect::<Vec<_>>()
                            .join(" ")
                    })
                    .unwrap_or_default()
            })
            .collect()
    }
}

fn whoami() -> String {
    String::from_utf8_lossy(
        &Command::new("id")
            .arg("-un")
            .output()
            .map(|o| o.stdout)
            .unwrap_or_default(),
    )
    .trim()
    .to_string()
}

fn lbx_bin() -> PathBuf {
    assert_cmd::cargo::cargo_bin("lbx")
}

/// The launcher with fake-docker first on PATH, HOME and the state
/// directory inside the temp root, and the fake's seams.
fn fake_lbx(w: &World, args: &[&str]) -> Command {
    let fake = assert_cmd::cargo::cargo_bin("fake-docker");
    if !w.root.join("bin/docker").exists() {
        std::os::unix::fs::symlink(&fake, w.root.join("bin/docker"))
            .unwrap_or_else(|e| panic!("ln: {e}"));
    }
    std::fs::write(w.root.join("exist"), "llm-in-a-box:docker\n")
        .unwrap_or_else(|e| panic!("exist: {e}"));
    let mut c = Command::new(lbx_bin());
    c.env_clear()
        .env(
            "PATH",
            format!(
                "{}:{}",
                w.p("bin"),
                std::env::var("PATH").unwrap_or_default()
            ),
        )
        .env("HOME", w.p("home"))
        .env("TERM", "dumb")
        .env("LLMBOX_STATE_DIR", w.p("state"))
        .env("LLMBOX_CONFIG", w.p("home/.config/llm_in_a_box/config"))
        .env("LLMBOX_SCRIPT_DIR", w.p("nowhere"))
        .env("FAKE_DOCKER_JSON", w.p("calls.jsonl"))
        .env("FAKE_EXISTING_FILE", w.p("exist"))
        .env("FAKE_CONTAINER_TABLE", w.p("table"))
        .env("FAKE_ATTACH_REPL", "1")
        .args(args)
        .current_dir(w.p("cwd"));
    c
}

fn spawn(cmd: Command) -> OsSession {
    let mut s = OsSession::spawn(cmd).unwrap_or_else(|e| panic!("spawn: {e}"));
    s.set_expect_timeout(Some(Duration::from_secs(30)));
    s
}

fn exit_code(s: &OsSession) -> i32 {
    match s.get_process().wait() {
        Ok(expectrl::process::unix::WaitStatus::Exited(_, code)) => code,
        other => panic!("not a plain exit: {other:?}"),
    }
}

fn text(c: &expectrl::Captures) -> String {
    String::from_utf8_lossy(c.as_bytes()).into_owned()
}

#[test]
fn attach_waits_for_user_ready_then_runs_the_box_shell_under_a_pty() {
    let w = world();
    std::fs::write(
        w.root.join("table"),
        "s1|llm-in-a-box.runtime|docker|llm-in-a-box:docker|running||||agent\n",
    )
    .unwrap_or_else(|e| panic!("{e}"));
    let user = whoami();
    let mut cmd = fake_lbx(&w, &["s1"]);
    cmd.env("FAKE_USER_READY_AFTER", "2");
    let started = std::time::Instant::now();
    let mut s = spawn(cmd);
    s.expect("==> Found existing docker session 's1' (running).")
        .unwrap_or_else(|e| panic!("found line: {e}"));
    s.expect("==> Attaching to running container 's1' (docker) ...")
        .unwrap_or_else(|e| panic!("attach line: {e}"));
    s.expect("Welcome to llm in a box... where agents are constrained")
        .unwrap_or_else(|e| panic!("welcome: {e}"));
    s.expect(format!("fake-box:{user}$ ").as_str())
        .unwrap_or_else(|e| panic!("prompt: {e}"));
    // two failed probes, one second apart, before the successful one
    assert!(
        started.elapsed() >= Duration::from_secs(2),
        "the user-ready wait was skipped: {:?}",
        started.elapsed()
    );
    s.send_line("id -un").unwrap_or_else(|e| panic!("{e}"));
    let got = s
        .expect(Regex(format!(r"{user}\r?\n").as_str()))
        .unwrap_or_else(|e| panic!("id -un: {e}"));
    assert!(text(&got).contains(&user));
    s.send_line("echo $HOME").unwrap_or_else(|e| panic!("{e}"));
    s.expect(Regex(r"/home/agent\r?\n"))
        .unwrap_or_else(|e| panic!("HOME: {e}"));
    s.send_line("pwd").unwrap_or_else(|e| panic!("{e}"));
    s.expect(Regex(r"/data\r?\n"))
        .unwrap_or_else(|e| panic!("pwd: {e}"));
    s.send_line("exit").unwrap_or_else(|e| panic!("{e}"));
    s.expect(Eof).unwrap_or_else(|e| panic!("eof: {e}"));
    assert_eq!(exit_code(&s), 0);

    let calls = w.calls();
    let probes = calls
        .iter()
        .filter(|c| *c == "exec s1 test -f /tmp/.user-ready")
        .count();
    assert_eq!(probes, 3, "{calls:?}");
    assert!(calls.contains(&format!("exec s1 id {user}")), "{calls:?}");
    assert_eq!(
        calls.last().map(String::as_str),
        Some(format!("exec -it -e HOME=/home/agent -w /data s1 gosu {user} bash").as_str()),
        "{calls:?}"
    );
    // the launcher's own HOME override: its config lives under the temp HOME
    assert!(
        w.root.join("home/.config/llm_in_a_box/open.json").is_file(),
        "policies were not written under the overridden HOME"
    );
}

#[test]
fn attach_falls_back_to_the_agent_user_when_the_host_user_is_missing() {
    let w = world();
    std::fs::write(
        w.root.join("table"),
        "s2|llm-in-a-box.runtime|docker|llm-in-a-box:docker|running||||agent\n",
    )
    .unwrap_or_else(|e| panic!("{e}"));
    let user = whoami();
    let mut cmd = fake_lbx(&w, &["s2"]);
    cmd.env("FAKE_FAIL_ON", format!("exec s2 id {user}"));
    let mut s = spawn(cmd);
    s.expect(
        format!("WARNING: user '{user}' not found in container, falling back to 'agent'").as_str(),
    )
    .unwrap_or_else(|e| panic!("warning: {e}"));
    s.expect("fake-box:agent$ ")
        .unwrap_or_else(|e| panic!("prompt: {e}"));
    s.send_line("id -un").unwrap_or_else(|e| panic!("{e}"));
    s.expect(Regex(r"agent\r?\n"))
        .unwrap_or_else(|e| panic!("id -un: {e}"));
    s.send_line("exit").unwrap_or_else(|e| panic!("{e}"));
    s.expect(Eof).unwrap_or_else(|e| panic!("eof: {e}"));
    assert_eq!(exit_code(&s), 0);
    assert_eq!(
        w.calls().last().map(String::as_str),
        Some("exec -it -e HOME=/home/agent -w /data s2 gosu agent bash")
    );
}

/// Real docker, real image (`LBX_REAL_DOCKER=1`): create, attach, run
/// commands in the box, exit, destroy. The entrypoint renames the image's
/// `agent` user to the host user, so `id -un` answers the host user name
/// while HOME stays /home/agent.
#[test]
fn real_docker_session_attaches_runs_commands_and_is_destroyed() {
    if std::env::var("LBX_REAL_DOCKER").as_deref() != Ok("1") {
        eprintln!(
            "skipped: set LBX_REAL_DOCKER=1 to run against the real llm-in-a-box:docker image"
        );
        return;
    }
    let w = world();
    let name = format!("lbx-parity-pty-{}", std::process::id());
    let user = whoami();
    let real = |args: &[&str]| {
        let mut c = Command::new(lbx_bin());
        c.env_clear()
            .env("PATH", std::env::var("PATH").unwrap_or_default())
            .env("HOME", w.p("home"))
            .env("TERM", "dumb")
            .env("LLMBOX_STATE_DIR", w.p("state"))
            .env("LLMBOX_CONFIG", w.p("home/.config/llm_in_a_box/config"))
            .env("LLMBOX_SCRIPT_DIR", w.p("nowhere"))
            .args(args)
            .current_dir(w.p("cwd"));
        c
    };
    let mut s = spawn(real(&["--runtime", "docker", &name]));
    s.set_expect_timeout(Some(Duration::from_secs(240)));
    s.expect(format!("==> Creating new container '{name}' (docker) ...").as_str())
        .unwrap_or_else(|e| panic!("create line: {e}"));
    s.expect("Welcome to llm in a box... where agents are constrained")
        .unwrap_or_else(|e| panic!("welcome: {e}"));
    s.send_line("echo \"U=$(id -un) H=$HOME P=$PWD I=$(id -u) END\"")
        .unwrap_or_else(|e| panic!("{e}"));
    let got = s
        .expect(Regex(r"U=\S+ H=/home/agent P=/data I=\d+ END"))
        .unwrap_or_else(|e| panic!("probe line: {e}"));
    let line = text(&got);
    assert!(line.contains(&format!("U={user} ")), "{line}");
    assert!(
        line.contains(&format!("I={} ", unsafe { libc::getuid() })),
        "{line}"
    );
    s.send_line("exit").unwrap_or_else(|e| panic!("{e}"));
    s.expect(Eof).unwrap_or_else(|e| panic!("eof: {e}"));
    assert_eq!(exit_code(&s), 0);

    let destroyed = real(&["--destroy", &name])
        .output()
        .unwrap_or_else(|e| panic!("destroy: {e}"));
    assert!(destroyed.status.success(), "{destroyed:?}");
    let left = Command::new("docker")
        .args(["ps", "-aq", "--filter", &format!("name=^{name}$")])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default();
    assert!(left.is_empty(), "container still present: {left}");
}
