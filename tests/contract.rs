//! The downstream consumer contract (an unattended runner such as a job
//! scheduler) and the `--run` refusal catalog at the binary level, with
//! fake-docker first on PATH (it records every call as JSON and can signal
//! the launcher from inside a call). Snapshots (insta) pin the
//! recorded docker calls with the run id and the temp root redacted.

use assert_cmd::cargo::cargo_bin_cmd;
use predicates::prelude::*;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

struct World {
    _tmp: tempfile::TempDir,
    root: PathBuf,
}

fn world() -> World {
    let tmp = tempfile::Builder::new()
        .prefix("lbxt-")
        .tempdir()
        .unwrap_or_else(|e| panic!("tempdir: {e}"));
    let root = tmp.path().to_path_buf();
    for d in ["bin", "home", "state", "data", "cwd", "sock", "pol"] {
        std::fs::create_dir_all(root.join(d)).unwrap_or_else(|e| panic!("mkdir {d}: {e}"));
    }
    std::fs::set_permissions(root.join("sock"), std::fs::Permissions::from_mode(0o700))
        .unwrap_or_else(|e| panic!("chmod: {e}"));
    std::fs::set_permissions(root.join("data"), std::fs::Permissions::from_mode(0o755))
        .unwrap_or_else(|e| panic!("chmod: {e}"));
    let fake = assert_cmd::cargo::cargo_bin("fake-docker");
    std::os::unix::fs::symlink(&fake, root.join("bin/docker"))
        .unwrap_or_else(|e| panic!("ln: {e}"));
    std::fs::write(
        root.join("exist"),
        "llm-in-a-box:docker\nllm-in-a-box-relay:latest\n",
    )
    .unwrap_or_else(|e| panic!("exist: {e}"));
    std::fs::write(root.join("data/input.txt"), "input\n").unwrap_or_else(|e| panic!("data: {e}"));
    std::fs::write(
        root.join("pol/enforce.json"),
        "{\"mode\":\"enforce\",\"allow\":[\"example.com\"],\"block\":[]}\n",
    )
    .unwrap_or_else(|e| panic!("policy: {e}"));
    std::fs::write(root.join("pol/open.json"), "{\"mode\":\"open\"}\n")
        .unwrap_or_else(|e| panic!("policy: {e}"));
    World { _tmp: tmp, root }
}

impl World {
    fn p(&self, rel: &str) -> String {
        self.root.join(rel).to_string_lossy().into_owned()
    }

    fn calls(&self) -> String {
        std::fs::read_to_string(self.root.join("calls.jsonl")).unwrap_or_default()
    }

    fn status_file(&self, name: &str) -> Option<String> {
        std::fs::read_to_string(self.root.join("state/runs").join(name).join("status")).ok()
    }

    /// The recorded calls as one line each, redacted for snapshots.
    fn calls_redacted(&self) -> String {
        let root = self.p("");
        self.calls()
            .lines()
            .map(|l| {
                let v: serde_json::Value =
                    serde_json::from_str(l).unwrap_or(serde_json::Value::Null);
                let argv: Vec<String> = v["argv"]
                    .as_array()
                    .map(|a| {
                        a.iter()
                            .map(|x| x.as_str().unwrap_or("").to_string())
                            .collect()
                    })
                    .unwrap_or_default();
                argv.join(" ").replace(&root, "[ROOT]/")
            })
            .collect::<Vec<_>>()
            .join("\n")
    }
}

fn lbx(w: &World) -> assert_cmd::Command {
    let mut c = cargo_bin_cmd!("lbx");
    let path = format!(
        "{}:{}",
        w.p("bin"),
        std::env::var("PATH").unwrap_or_default()
    );
    c.env_clear()
        .env("PATH", path)
        .env("HOME", w.p("home"))
        .env("LLMBOX_STATE_DIR", w.p("state"))
        .env("LLMBOX_CONFIG", w.p("home/.config/llm_in_a_box/config"))
        .env("LLMBOX_SCRIPT_DIR", w.p("nowhere"))
        .env("FAKE_DOCKER_JSON", w.p("calls.jsonl"))
        .env("FAKE_EXISTING_FILE", w.p("exist"))
        .env("FAKE_CONTAINER_TABLE", w.p("table"))
        .env("LLMBOX_RUN_READY_SECONDS", "2")
        .current_dir(w.p("cwd"));
    c
}

/// `lbx --run --runtime docker --no-network --data <data> --timeout 5 <name> -- <cmd>`
fn run_cmd(w: &World, name: &str, cmd: &[&str]) -> assert_cmd::Command {
    let mut c = lbx(w);
    c.args(["--run", "--runtime", "docker", "--no-network", "--data"])
        .arg(w.p("data"))
        .args(["--timeout", "5", name, "--"])
        .args(cmd);
    c
}

fn settings() -> insta::Settings {
    let mut s = insta::Settings::clone_current();
    s.add_filter(
        r"llm-in-a-box\.run-id=[0-9a-f]{32}",
        "llm-in-a-box.run-id=[RUN-ID]",
    );
    s.add_filter(r"/tmp/lbxt-[A-Za-z0-9]+/", "[ROOT]/");
    s.add_filter(r"HOST_USER=\S+", "HOST_USER=[USER]");
    s.add_filter(r"HOST_UID=\d+", "HOST_UID=[UID]");
    s.add_filter(r"HOST_GID=\d+", "HOST_GID=[GID]");
    s.add_filter(r"--user \d+:\d+", "--user [UID]:[GID]");
    s.add_filter(r"gosu \S+", "gosu [USER]");
    s
}

// ---- the flag probe and the status line --------------------------------

#[test]
fn run_only_flags_probe_lines() {
    let w = world();
    for (flag, extra) in [
        ("--no-network", vec![]),
        ("--socket-dir", vec!["/x"]),
        ("--data", vec!["/x"]),
        ("--timeout", vec!["5"]),
        ("--env", vec!["X"]),
        ("--apparmor-profile", vec![]),
    ] {
        let mut c = lbx(&w);
        c.arg(flag).args(&extra).arg("probe");
        c.assert().code(1).stderr(
            predicate::str::is_match(format!("^ERROR: {flag} is only valid with --run.\n$"))
                .unwrap_or_else(|e| panic!("{e}")),
        );
    }
    assert_eq!(w.calls(), "", "a probe never calls docker");
}

#[test]
fn refusal_prints_the_status_line_last_and_creates_nothing() {
    let w = world();
    lbx(&w)
        .args([
            "--run",
            "--runtime",
            "docker",
            "--no-network",
            "--timeout",
            "5",
            "job",
            "--",
            "true",
        ])
        .assert()
        .code(125)
        .stderr(predicate::str::ends_with(
            "\nlbx-run: status=refused code=125\n",
        ))
        .stderr(predicate::str::contains(
            "\nERROR: --run needs --data <directory>.\n",
        ));
    assert!(!w.root.join("state/runs").exists());
    assert!(!w.root.join("state").join("netlogs").exists());
}

#[test]
fn unknown_option_under_run_is_a_refusal_with_usage() {
    let w = world();
    lbx(&w)
        .args(["--run", "--bogus", "job", "--", "true"])
        .assert()
        .code(125)
        .stderr(predicate::str::starts_with(
            "ERROR: Unknown option: --bogus\nUsage: lbx",
        ))
        .stderr(predicate::str::ends_with(
            "\nlbx-run: status=refused code=125\n",
        ));
}

// ---- the refusal catalog ------------------------------------------------

/// Each case: extra args, environment, setup, the exact ERROR line.
#[test]
fn refusal_catalog() {
    let w = world();
    let data = w.p("data");
    let state = w.p("state");
    let home = w.p("home");
    std::fs::create_dir_all(w.root.join("home/inside")).unwrap_or_else(|e| panic!("{e}"));
    std::fs::create_dir_all(w.root.join("state/sub")).unwrap_or_else(|e| panic!("{e}"));
    std::fs::create_dir_all(w.root.join("gitty/.git")).unwrap_or_else(|e| panic!("{e}"));
    std::fs::create_dir_all(w.root.join("linky")).unwrap_or_else(|e| panic!("{e}"));
    std::os::unix::fs::symlink("/etc/hostname", w.root.join("linky/l"))
        .unwrap_or_else(|e| panic!("{e}"));
    std::fs::create_dir_all(w.root.join("socky")).unwrap_or_else(|e| panic!("{e}"));
    let _listener = std::os::unix::net::UnixListener::bind(w.root.join("socky/s.sock"))
        .unwrap_or_else(|e| panic!("{e}"));
    std::fs::create_dir_all(w.root.join("fifo")).unwrap_or_else(|e| panic!("{e}"));
    let fifo = std::ffi::CString::new(w.p("fifo/p")).unwrap_or_default();
    // SAFETY: a valid C string path for mkfifo.
    assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);
    std::fs::write(w.root.join("notdir"), "").unwrap_or_else(|e| panic!("{e}"));
    std::fs::create_dir_all(w.root.join("sock-gw")).unwrap_or_else(|e| panic!("{e}"));
    std::fs::set_permissions(
        w.root.join("sock-gw"),
        std::fs::Permissions::from_mode(0o770),
    )
    .unwrap_or_else(|e| panic!("{e}"));
    std::os::unix::fs::symlink(w.p("sock"), w.root.join("sock-link"))
        .unwrap_or_else(|e| panic!("{e}"));
    std::fs::create_dir_all(w.root.join("sock-file")).unwrap_or_else(|e| panic!("{e}"));
    std::fs::set_permissions(
        w.root.join("sock-file"),
        std::fs::Permissions::from_mode(0o700),
    )
    .unwrap_or_else(|e| panic!("{e}"));
    std::fs::write(w.root.join("sock-file/plain"), "").unwrap_or_else(|e| panic!("{e}"));
    std::fs::write(w.root.join("pol/bad.json"), "{nope").unwrap_or_else(|e| panic!("{e}"));

    let base = |w: &World| {
        let mut c = lbx(w);
        c.arg("--run");
        c
    };
    let long = "n".repeat(129);
    type Case = (Vec<String>, Vec<(&'static str, String)>, String);
    let cases: Vec<Case> = vec![
        (
            [
                "--no-network",
                "--data",
                &data,
                "--timeout",
                "5",
                "job",
                "--",
                "true",
            ]
            .iter()
            .map(|s| s.to_string())
            .collect(),
            vec![],
            "--run needs --runtime docker (got: none).".into(),
        ),
        (
            [
                "--runtime",
                "vm",
                "--no-network",
                "--data",
                &data,
                "--timeout",
                "5",
                "job",
                "--",
                "true",
            ]
            .iter()
            .map(|s| s.to_string())
            .collect(),
            vec![],
            "--run needs --runtime docker (got: vm).".into(),
        ),
        (
            [
                "--runtime",
                "docker",
                "--data",
                &data,
                "--timeout",
                "5",
                "job",
                "--",
                "true",
            ]
            .iter()
            .map(|s| s.to_string())
            .collect(),
            vec![],
            "--run needs --net-policy with mode enforce or locked, or --no-network.".into(),
        ),
        (
            [
                "--runtime",
                "docker",
                "--net-policy",
                &w.p("pol/open.json"),
                "--data",
                &data,
                "--timeout",
                "5",
                "job",
                "--",
                "true",
            ]
            .iter()
            .map(|s| s.to_string())
            .collect(),
            vec![],
            "net policy mode must be enforce or locked for --run (got: open).".to_string(),
        ),
        (
            [
                "--runtime",
                "docker",
                "--net-policy",
                &w.p("pol/bad.json"),
                "--data",
                &data,
                "--timeout",
                "5",
                "job",
                "--",
                "true",
            ]
            .iter()
            .map(|s| s.to_string())
            .collect(),
            vec![],
            format!("invalid net policy file: {}", w.p("pol/bad.json")),
        ),
        (
            [
                "--runtime",
                "docker",
                "--no-network",
                "--data",
                &data,
                "job",
                "--",
                "true",
            ]
            .iter()
            .map(|s| s.to_string())
            .collect(),
            vec![],
            "--run needs exactly one --timeout <seconds>.".into(),
        ),
        (
            [
                "--runtime",
                "docker",
                "--no-network",
                "--data",
                &data,
                "--timeout",
                "5",
                "--timeout",
                "6",
                "job",
                "--",
                "true",
            ]
            .iter()
            .map(|s| s.to_string())
            .collect(),
            vec![],
            "--run needs exactly one --timeout <seconds>.".into(),
        ),
        (
            [
                "--runtime",
                "docker",
                "--no-network",
                "--data",
                &data,
                "--timeout",
                "0",
                "job",
                "--",
                "true",
            ]
            .iter()
            .map(|s| s.to_string())
            .collect(),
            vec![],
            "--timeout must be a whole number of seconds from 1 to 604800 (got: 0).".into(),
        ),
        (
            [
                "--runtime",
                "docker",
                "--no-network",
                "--data",
                &data,
                "--timeout",
                "5",
                &long,
                "--",
                "true",
            ]
            .iter()
            .map(|s| s.to_string())
            .collect(),
            vec![],
            "run name is longer than 128 characters.".into(),
        ),
        (
            [
                "--runtime",
                "docker",
                "--no-network",
                "--data",
                &data,
                "--timeout",
                "5",
                "--env",
                "1BAD",
                "job",
                "--",
                "true",
            ]
            .iter()
            .map(|s| s.to_string())
            .collect(),
            vec![],
            "--env name '1BAD' is not a valid variable name.".into(),
        ),
        (
            [
                "--runtime",
                "docker",
                "--no-network",
                "--data",
                &data,
                "--timeout",
                "5",
                "--env",
                "LD_PRELOAD",
                "job",
                "--",
                "true",
            ]
            .iter()
            .map(|s| s.to_string())
            .collect(),
            vec![],
            "--env name LD_PRELOAD is reserved.".into(),
        ),
        (
            [
                "--runtime",
                "docker",
                "--no-network",
                "--data",
                &data,
                "--timeout",
                "5",
                "--env",
                "TOK",
                "--env",
                "TOK",
                "job",
                "--",
                "true",
            ]
            .iter()
            .map(|s| s.to_string())
            .collect(),
            vec![("TOK", "x".into())],
            "--env name TOK is given twice.".into(),
        ),
        (
            [
                "--runtime",
                "docker",
                "--no-network",
                "--data",
                &data,
                "--timeout",
                "5",
                "--env",
                "UNSET_X",
                "job",
                "--",
                "true",
            ]
            .iter()
            .map(|s| s.to_string())
            .collect(),
            vec![],
            "--env name UNSET_X is not set.".into(),
        ),
        (
            [
                "--runtime",
                "docker",
                "--no-network",
                "--data",
                &w.p("missing"),
                "--timeout",
                "5",
                "job",
                "--",
                "true",
            ]
            .iter()
            .map(|s| s.to_string())
            .collect(),
            vec![],
            format!("data directory {} does not exist.", w.p("missing")),
        ),
        (
            [
                "--runtime",
                "docker",
                "--no-network",
                "--data",
                &w.p("notdir"),
                "--timeout",
                "5",
                "job",
                "--",
                "true",
            ]
            .iter()
            .map(|s| s.to_string())
            .collect(),
            vec![],
            format!("data directory {} is not a directory.", w.p("notdir")),
        ),
        (
            [
                "--runtime",
                "docker",
                "--no-network",
                "--data",
                &home,
                "--timeout",
                "5",
                "job",
                "--",
                "true",
            ]
            .iter()
            .map(|s| s.to_string())
            .collect(),
            vec![],
            format!("data directory {home} is the home directory."),
        ),
        (
            [
                "--runtime",
                "docker",
                "--no-network",
                "--data",
                &w.p(""),
                "--timeout",
                "5",
                "job",
                "--",
                "true",
            ]
            .iter()
            .map(|s| s.to_string())
            .collect(),
            vec![],
            format!(
                "data directory {} is an ancestor of the home directory.",
                w.p("").trim_end_matches('/')
            ),
        ),
        (
            [
                "--runtime",
                "docker",
                "--no-network",
                "--data",
                &w.p("home/inside"),
                "--timeout",
                "5",
                "job",
                "--",
                "true",
            ]
            .iter()
            .map(|s| s.to_string())
            .collect(),
            vec![],
            format!(
                "data directory {} is inside the home directory.",
                w.p("home/inside")
            ),
        ),
        (
            [
                "--runtime",
                "docker",
                "--no-network",
                "--data",
                &w.p("state/sub"),
                "--timeout",
                "5",
                "job",
                "--",
                "true",
            ]
            .iter()
            .map(|s| s.to_string())
            .collect(),
            vec![],
            format!(
                "data directory {} overlaps the state directory ({state}).",
                w.p("state/sub")
            ),
        ),
        (
            [
                "--runtime",
                "docker",
                "--no-network",
                "--data",
                &w.p("gitty"),
                "--timeout",
                "5",
                "job",
                "--",
                "true",
            ]
            .iter()
            .map(|s| s.to_string())
            .collect(),
            vec![],
            format!(
                "data directory {} contains .git ({}).",
                w.p("gitty"),
                w.p("gitty/.git")
            ),
        ),
        (
            [
                "--runtime",
                "docker",
                "--no-network",
                "--data",
                &w.p("linky"),
                "--timeout",
                "5",
                "job",
                "--",
                "true",
            ]
            .iter()
            .map(|s| s.to_string())
            .collect(),
            vec![],
            format!(
                "data directory {} contains a symbolic link ({}).",
                w.p("linky"),
                w.p("linky/l")
            ),
        ),
        (
            [
                "--runtime",
                "docker",
                "--no-network",
                "--data",
                &w.p("socky"),
                "--timeout",
                "5",
                "job",
                "--",
                "true",
            ]
            .iter()
            .map(|s| s.to_string())
            .collect(),
            vec![],
            format!(
                "data directory {} contains a socket ({}).",
                w.p("socky"),
                w.p("socky/s.sock")
            ),
        ),
        (
            [
                "--runtime",
                "docker",
                "--no-network",
                "--data",
                &w.p("fifo"),
                "--timeout",
                "5",
                "job",
                "--",
                "true",
            ]
            .iter()
            .map(|s| s.to_string())
            .collect(),
            vec![],
            format!(
                "data directory {} contains a named pipe ({}).",
                w.p("fifo"),
                w.p("fifo/p")
            ),
        ),
        (
            [
                "--runtime",
                "docker",
                "--no-network",
                "--data",
                &data,
                "--timeout",
                "5",
                "--socket-dir",
                &w.p("sock"),
                "--socket-dir",
                &w.p("sock"),
                "job",
                "--",
                "true",
            ]
            .iter()
            .map(|s| s.to_string())
            .collect(),
            vec![],
            "socket directory: --socket-dir is given more than once.".into(),
        ),
        (
            [
                "--runtime",
                "docker",
                "--no-network",
                "--data",
                &data,
                "--timeout",
                "5",
                "--socket-dir",
                &w.p("sock-link"),
                "job",
                "--",
                "true",
            ]
            .iter()
            .map(|s| s.to_string())
            .collect(),
            vec![],
            format!(
                "socket directory {} is a symbolic link (give the directory it points to).",
                w.p("sock-link")
            ),
        ),
        (
            [
                "--runtime",
                "docker",
                "--no-network",
                "--data",
                &data,
                "--timeout",
                "5",
                "--socket-dir",
                &w.p("nosock"),
                "job",
                "--",
                "true",
            ]
            .iter()
            .map(|s| s.to_string())
            .collect(),
            vec![],
            format!("socket directory {} does not exist.", w.p("nosock")),
        ),
        (
            [
                "--runtime",
                "docker",
                "--no-network",
                "--data",
                &data,
                "--timeout",
                "5",
                "--socket-dir",
                &w.p("notdir"),
                "job",
                "--",
                "true",
            ]
            .iter()
            .map(|s| s.to_string())
            .collect(),
            vec![],
            format!("socket directory {} is not a directory.", w.p("notdir")),
        ),
        (
            [
                "--runtime",
                "docker",
                "--no-network",
                "--data",
                &data,
                "--timeout",
                "5",
                "--socket-dir",
                &w.p("sock-gw"),
                "job",
                "--",
                "true",
            ]
            .iter()
            .map(|s| s.to_string())
            .collect(),
            vec![],
            format!(
                "socket directory {} is writable by group or others (mode 770).",
                w.p("sock-gw")
            ),
        ),
        (
            [
                "--runtime",
                "docker",
                "--no-network",
                "--data",
                &data,
                "--timeout",
                "5",
                "--socket-dir",
                &data,
                "job",
                "--",
                "true",
            ]
            .iter()
            .map(|s| s.to_string())
            .collect(),
            vec![],
            format!("socket directory {data} overlaps the data directory ({data})."),
        ),
        (
            [
                "--runtime",
                "docker",
                "--no-network",
                "--data",
                &data,
                "--timeout",
                "5",
                "--socket-dir",
                &w.p("sock-file"),
                "job",
                "--",
                "true",
            ]
            .iter()
            .map(|s| s.to_string())
            .collect(),
            vec![],
            format!(
                "socket directory {} holds an entry that is not a socket ({}).",
                w.p("sock-file"),
                w.p("sock-file/plain")
            ),
        ),
        (
            [
                "--runtime",
                "docker",
                "--no-network",
                "--data",
                &data,
                "--timeout",
                "5",
                "--apparmor-profile",
                "job",
                "--",
                "true",
            ]
            .iter()
            .map(|s| s.to_string())
            .collect(),
            vec![("LLMBOX_SYSFS", w.p("nosys"))],
            "--apparmor-profile: AppArmor is not enabled on this host.".into(),
        ),
        (
            [
                "--runtime",
                "docker",
                "--no-network",
                "--data",
                &data,
                "--timeout",
                "5",
                "job",
                "--",
                "true",
            ]
            .iter()
            .map(|s| s.to_string())
            .collect(),
            vec![("PATH", "/nonexistent".into())],
            "docker is not installed or not on PATH.".into(),
        ),
    ];
    for (args, env, want) in cases {
        let mut c = base(&w);
        c.args(&args);
        for (k, v) in env {
            c.env(k, v);
        }
        let out = c.output().unwrap_or_else(|e| panic!("{e}"));
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert_eq!(out.status.code(), Some(125), "{args:?}: {stderr}");
        assert!(
            stderr.contains(&format!("ERROR: {want}\n")),
            "{args:?}\nwant: {want}\ngot: {stderr}"
        );
        assert!(
            stderr.ends_with("\nlbx-run: status=refused code=125\n"),
            "{stderr}"
        );
        assert!(
            !w.root.join("state/runs").exists(),
            "{args:?} created runs/"
        );
    }
}

#[test]
fn refusals_for_names_already_in_use() {
    let w = world();
    // A container of that name.
    std::fs::write(w.root.join("table"), "job||||running||||\n").unwrap_or_else(|e| panic!("{e}"));
    run_cmd(&w, "job", &["true"])
        .assert()
        .code(125)
        .stderr(predicate::str::contains(
            "\nERROR: a container named job already exists.\n",
        ));
    std::fs::write(
        w.root.join("table"),
        "llm-in-a-box-relay-job||||running||||\n",
    )
    .unwrap_or_else(|e| panic!("{e}"));
    run_cmd(&w, "job", &["true"])
        .assert()
        .code(125)
        .stderr(predicate::str::contains(
            "\nERROR: a container named llm-in-a-box-relay-job already exists.\n",
        ));
    std::fs::write(w.root.join("table"), "").unwrap_or_else(|e| panic!("{e}"));
    // A vm session of that name.
    std::fs::create_dir_all(w.root.join("state/sessions/job")).unwrap_or_else(|e| panic!("{e}"));
    run_cmd(&w, "job", &["true"])
        .assert()
        .code(125)
        .stderr(predicate::str::contains(
            "\nERROR: a vm session named job already exists.\n",
        ));
    std::fs::remove_dir_all(w.root.join("state/sessions")).unwrap_or_else(|e| panic!("{e}"));
    // A previous run's directory (even an empty one, even a file).
    std::fs::create_dir_all(w.root.join("state/runs/job")).unwrap_or_else(|e| panic!("{e}"));
    run_cmd(&w, "job", &["true"])
        .assert()
        .code(125)
        .stderr(predicate::str::contains(format!(
            "\nERROR: run name job was used before: {} already exists (use a new run name, or remove it).\n",
            w.p("state/runs/job")
        )));
    std::fs::remove_dir_all(w.root.join("state/runs")).unwrap_or_else(|e| panic!("{e}"));
    std::fs::create_dir_all(w.root.join("state/netlogs")).unwrap_or_else(|e| panic!("{e}"));
    std::fs::write(w.root.join("state/netlogs/job"), "").unwrap_or_else(|e| panic!("{e}"));
    run_cmd(&w, "job", &["true"])
        .assert()
        .code(125)
        .stderr(predicate::str::contains(format!(
            "\nERROR: run name job was used before: {} already exists (use a new run name, or remove it).\n",
            w.p("state/netlogs/job")
        )));
    std::fs::remove_dir_all(w.root.join("state/netlogs")).unwrap_or_else(|e| panic!("{e}"));
    // The images.
    std::fs::write(w.root.join("exist"), "llm-in-a-box-relay:latest\n")
        .unwrap_or_else(|e| panic!("{e}"));
    run_cmd(&w, "job", &["true"])
        .assert()
        .code(125)
        .stderr(predicate::str::contains("\nERROR: image llm-in-a-box:docker is not present locally (build it with ./build docker).\n"));
    std::fs::write(w.root.join("exist"), "llm-in-a-box:docker\n").unwrap_or_else(|e| panic!("{e}"));
    lbx(&w)
        .args(["--run", "--runtime", "docker", "--net-policy"])
        .arg(w.p("pol/enforce.json"))
        .arg("--data")
        .arg(w.p("data"))
        .args(["--timeout", "5", "job", "--", "true"])
        .assert()
        .code(125)
        .stderr(predicate::str::contains("\nERROR: image llm-in-a-box-relay:latest is not present locally (build it with ./build relay).\n"));
}

#[test]
fn a_configured_image_is_the_run_image() {
    let w = world();
    std::fs::create_dir_all(w.root.join("home/.config/llm_in_a_box"))
        .unwrap_or_else(|e| panic!("{e}"));
    std::fs::write(
        w.root.join("home/.config/llm_in_a_box/config"),
        "image.docker=ghcr.io/x/box:7\n",
    )
    .unwrap_or_else(|e| panic!("{e}"));
    std::fs::set_permissions(
        w.root.join("home/.config/llm_in_a_box/config"),
        std::fs::Permissions::from_mode(0o644),
    )
    .unwrap_or_else(|e| panic!("{e}"));
    std::fs::write(w.root.join("exist"), "ghcr.io/x/box:7\n").unwrap_or_else(|e| panic!("{e}"));
    run_cmd(&w, "job", &["true"]).assert().code(0);
    assert!(
        w.calls().contains("\"ghcr.io/x/box:7\",\"sleep\""),
        "{}",
        w.calls()
    );
    lbx(&w)
        .arg("--print-images")
        .assert()
        .code(0)
        .stdout("sysbox=llm-in-a-box:sysbox docker=ghcr.io/x/box:7 vm=llm-in-a-box:vm\n");
    lbx(&w)
        .arg("--print-state-dir")
        .assert()
        .code(0)
        .stdout(format!("{}\n", w.p("state")));
}

// ---- runs that go through ---------------------------------------------

#[test]
fn no_network_run_end_to_end() {
    let w = world();
    run_cmd(&w, "job1", &["sh", "-c", "echo hi"])
        .assert()
        .code(0)
        .stderr(predicate::str::ends_with(
            "\nlbx-run: status=exited code=0\n",
        ))
        .stderr(predicate::str::contains("deny-log").not());
    assert_eq!(
        w.status_file("job1").as_deref(),
        Some("status=exited code=0\n")
    );
    assert!(!w.root.join("state/runs/job1/.claim").exists());
    assert!(
        !w.root.join("state/netlogs").exists(),
        "no deny log without a relay"
    );
    settings().bind(|| insta::assert_snapshot!("no_network_run_calls", w.calls_redacted()));
    // A second run of the same name is refused: the name was used.
    let _ = std::fs::write(w.root.join("table"), "");
    run_cmd(&w, "job1", &["true"])
        .assert()
        .code(125)
        .stderr(predicate::str::contains("run name job1 was used before"));
    assert_eq!(
        w.status_file("job1").as_deref(),
        Some("status=exited code=0\n"),
        "the refusal leaves the old outcome alone"
    );
}

#[test]
fn relay_run_end_to_end() {
    let w = world();
    lbx(&w)
        .args(["--run", "--runtime", "docker", "--net-policy"])
        .arg(w.p("pol/enforce.json"))
        .arg("--data")
        .arg(w.p("data"))
        .args([
            "--timeout",
            "5",
            "--env",
            "TOK",
            "job2",
            "--",
            "curl",
            "https://example.com",
        ])
        .env("TOK", "secret")
        .assert()
        .code(0)
        .stderr(predicate::str::ends_with(format!(
            "\nlbx-run: deny-log={}/deny.log\n\nlbx-run: status=exited code=0\n",
            w.p("state/netlogs/job2")
        )));
    assert_eq!(
        w.status_file("job2").as_deref(),
        Some("status=exited code=0\n")
    );
    settings().bind(|| insta::assert_snapshot!("relay_run_calls", w.calls_redacted()));
}

#[test]
fn socket_dir_is_one_read_only_mount() {
    let w = world();
    let _l = std::os::unix::net::UnixListener::bind(w.root.join("sock/model.sock"))
        .unwrap_or_else(|e| panic!("{e}"));
    lbx(&w)
        .args(["--run", "--runtime", "docker", "--no-network", "--data"])
        .arg(w.p("data"))
        .args(["--timeout", "5", "--socket-dir"])
        .arg(w.p("sock"))
        .args(["job3", "--", "true"])
        .assert()
        .code(0);
    let run_line = w
        .calls()
        .lines()
        .find(|l| l.contains("\"--rm\""))
        .unwrap_or("")
        .to_string();
    assert_eq!(run_line.matches("\"--mount\"").count(), 1, "{run_line}");
    assert!(
        run_line.contains(&format!(
            "\"type=bind,source={},target=/run/agent,readonly\"",
            w.p("sock")
        )),
        "{run_line}"
    );
    assert!(run_line.contains("\"--network\",\"none\""), "{run_line}");
}

#[test]
fn the_command_exit_code_is_the_run_exit_code() {
    let w = world();
    run_cmd(&w, "job4", &["false"])
        .env("FAKE_EXEC_RC", "3")
        .assert()
        .code(3)
        .stderr(predicate::str::ends_with(
            "\nlbx-run: status=exited code=3\n",
        ));
    assert_eq!(
        w.status_file("job4").as_deref(),
        Some("status=exited code=3\n")
    );
}

#[test]
fn timeout_ends_the_run_as_124() {
    let w = world();
    let started = std::time::Instant::now();
    lbx(&w)
        .args(["--run", "--runtime", "docker", "--no-network", "--data"])
        .arg(w.p("data"))
        .args(["--timeout", "1", "job5", "--", "sleep", "30"])
        .env("FAKE_EXEC_SLEEP_MS", "20000")
        .assert()
        .code(124)
        .stderr(predicate::str::ends_with(
            "\nlbx-run: status=timeout code=124\n",
        ));
    assert!(
        started.elapsed().as_secs() < 15,
        "the command was killed with the run"
    );
    assert_eq!(
        w.status_file("job5").as_deref(),
        Some("status=timeout code=124\n")
    );
    assert!(
        w.calls().contains("\"rm\",\"-f\",\"job5\""),
        "{}",
        w.calls()
    );
}

#[test]
fn setup_failure_is_125_with_cleanup() {
    let w = world();
    run_cmd(&w, "job6", &["true"])
        .env("FAKE_FAIL_ON", "run -d --rm")
        .assert()
        .code(125)
        .stderr(predicate::str::contains(
            "\nERROR: could not start the run box job6.\n",
        ))
        .stderr(predicate::str::ends_with(
            "\nlbx-run: status=setup-failed code=125\n",
        ));
    assert_eq!(
        w.status_file("job6").as_deref(),
        Some("status=setup-failed code=125\n")
    );
    settings().bind(|| insta::assert_snapshot!("setup_failed_calls", w.calls_redacted()));
}

#[test]
fn cleanup_incomplete_turns_exit_0_into_125() {
    let w = world();
    run_cmd(&w, "job7", &["true"])
        .env("FAKE_LEFTOVER", "job7")
        .assert()
        .code(125)
        .stderr(predicate::str::contains(
            "\nERROR: cleanup incomplete: container job7 of this run is still there; remove it with: docker rm -f job7\n",
        ))
        .stderr(predicate::str::ends_with("\nlbx-run: status=exited code=0 cleanup=incomplete\n"));
    assert_eq!(
        w.status_file("job7").as_deref(),
        Some("status=exited code=0 cleanup=incomplete\n")
    );
}

#[test]
fn a_planted_status_file_is_never_the_outcome() {
    let w = world();
    std::fs::create_dir_all(w.root.join("state/runs/job8")).unwrap_or_else(|e| panic!("{e}"));
    std::fs::write(
        w.root.join("state/runs/job8/status"),
        "status=exited code=0\n",
    )
    .unwrap_or_else(|e| panic!("{e}"));
    run_cmd(&w, "job8", &["true"])
        .assert()
        .code(125)
        .stderr(predicate::str::contains("was used before"));
    assert_eq!(
        w.status_file("job8").as_deref(),
        Some("status=exited code=0\n")
    );
}

// ---- signals, from inside a docker call --------------------------------

#[test]
fn a_signal_during_the_checks_is_that_signal_and_creates_nothing() {
    for (sig, code) in [("TERM", 143), ("INT", 130), ("HUP", 129), ("USR1", 138)] {
        let w = world();
        run_cmd(&w, "sig", &["true"])
            .env("FAKE_SIGNAL_ON", "container inspect")
            .env("FAKE_SIGNAL", sig)
            .assert()
            .code(code)
            .stderr(predicate::str::ends_with(format!(
                "\nlbx-run: status=signal code={code}\n"
            )))
            .stderr(predicate::str::contains("ERROR").not());
        assert!(
            !w.root.join("state/runs").exists(),
            "{sig}: nothing is created"
        );
        assert!(
            !w.calls().contains("\"run\",\"-d\""),
            "{sig}: no box is started"
        );
    }
}

#[test]
fn a_signal_while_the_box_starts_removes_it() {
    let w = world();
    run_cmd(&w, "sig2", &["true"])
        .env("FAKE_SIGNAL_ON", "run -d --rm")
        .env("FAKE_SIGNAL", "INT")
        .assert()
        .code(130)
        .stderr(predicate::str::ends_with(
            "\nlbx-run: status=signal code=130\n",
        ));
    assert_eq!(
        w.status_file("sig2").as_deref(),
        Some("status=signal code=130\n")
    );
    assert!(
        w.calls().contains("\"rm\",\"-f\",\"sig2\""),
        "{}",
        w.calls()
    );
}

#[test]
fn a_signal_while_the_command_runs_ends_it_as_the_signal() {
    let w = world();
    let started = std::time::Instant::now();
    lbx(&w)
        .args(["--run", "--runtime", "docker", "--no-network", "--data"])
        .arg(w.p("data"))
        .args(["--timeout", "60", "sig3", "--", "sleep", "30"])
        .env("FAKE_SIGNAL_ON", "exec -i -w /data")
        .env("FAKE_SIGNAL", "TERM")
        .env("FAKE_EXEC_SLEEP_MS", "20000")
        .assert()
        .code(143)
        .stderr(predicate::str::ends_with(
            "\nlbx-run: status=signal code=143\n",
        ));
    assert!(started.elapsed().as_secs() < 15);
    assert_eq!(
        w.status_file("sig3").as_deref(),
        Some("status=signal code=143\n")
    );
}

#[test]
fn sigusr1_while_the_command_runs_is_a_timeout() {
    let w = world();
    lbx(&w)
        .args(["--run", "--runtime", "docker", "--no-network", "--data"])
        .arg(w.p("data"))
        .args(["--timeout", "60", "sig4", "--", "sleep", "30"])
        .env("FAKE_SIGNAL_ON", "exec -i -w /data")
        .env("FAKE_SIGNAL", "USR1")
        .env("FAKE_EXEC_SLEEP_MS", "20000")
        .assert()
        .code(124)
        .stderr(predicate::str::ends_with(
            "\nlbx-run: status=timeout code=124\n",
        ));
}

// ---- the deny log and the list ------------------------------------------

#[test]
fn denied_refuses_to_follow_a_link_for_a_run() {
    let w = world();
    std::fs::create_dir_all(w.root.join("state/runs/r1")).unwrap_or_else(|e| panic!("{e}"));
    std::fs::create_dir_all(w.root.join("state/netlogs/r1")).unwrap_or_else(|e| panic!("{e}"));
    std::os::unix::fs::symlink("/etc/hostname", w.root.join("state/netlogs/r1/deny.log"))
        .unwrap_or_else(|e| panic!("{e}"));
    lbx(&w)
        .args(["--denied", "r1"])
        .assert()
        .code(1)
        .stderr("ERROR: the deny log of run 'r1' is a symbolic link; refusing to follow it.\n");
    std::fs::remove_file(w.root.join("state/netlogs/r1/deny.log"))
        .unwrap_or_else(|e| panic!("{e}"));
    std::fs::write(
        w.root.join("state/netlogs/r1/deny.log"),
        "DENY example.org\n",
    )
    .unwrap_or_else(|e| panic!("{e}"));
    lbx(&w)
        .args(["--denied", "r1"])
        .assert()
        .code(0)
        .stdout("DENY example.org\n");
    lbx(&w)
        .args(["--denied", "r2"])
        .assert()
        .code(0)
        .stdout("No deny log for session 'r2' (it ran without a net policy).\n");
}

#[test]
fn list_is_sorted_bytewise_with_fixed_columns() {
    let w = world();
    std::fs::write(
        w.root.join("table"),
        "zed|llm-in-a-box.runtime|docker|llm-in-a-box:docker|running||||\nBox|llm-in-a-box.runtime|sysbox|llm-in-a-box:sysbox|exited||llm-in-a-box.net-policy|/p/enforce.json|\nold|box-of-claude.runtime|docker|box-of-claude:latest|exited||||\nother|||nginx:1|running||||\n",
    )
    .unwrap_or_else(|e| panic!("{e}"));
    std::fs::create_dir_all(w.root.join("state/sessions/avm")).unwrap_or_else(|e| panic!("{e}"));
    std::fs::write(w.root.join("state/sessions/avm/ssh_port"), "2222\n")
        .unwrap_or_else(|e| panic!("{e}"));
    let out = lbx(&w)
        .arg("--list")
        .assert()
        .code(0)
        .get_output()
        .stdout
        .clone();
    settings().bind(|| insta::assert_snapshot!("list_table", String::from_utf8_lossy(&out)));
}

#[test]
fn an_old_box_without_the_user_stamp_is_not_started() {
    let w = world();
    std::fs::write(
        w.root.join("table"),
        "oldbox|llm-in-a-box.runtime|docker|llm-in-a-box:docker|exited||||\n",
    )
    .unwrap_or_else(|e| panic!("{e}"));
    lbx(&w)
        .args(["--runtime", "docker", "oldbox"])
        .assert()
        .code(1)
        .stderr(predicate::str::contains(
            "ERROR: container 'oldbox' is an OLD box (created by a previous version of",
        ))
        .stderr(predicate::str::contains(
            "recreate it:  lbx --destroy --runtime docker oldbox",
        ));
    assert!(!w.calls().contains("\"start\""), "{}", w.calls());
}

#[test]
fn a_run_box_cannot_be_attached_to() {
    let w = world();
    std::fs::write(
        w.root.join("table"),
        "rb|llm-in-a-box.runtime|docker|llm-in-a-box:docker|running||||\n",
    )
    .unwrap_or_else(|e| panic!("{e}"));
    std::fs::write(
        w.root.join("table.labels"),
        "container rb llm-in-a-box.mode=run\n",
    )
    .unwrap_or_else(|e| panic!("{e}"));
    lbx(&w)
        .args(["--runtime", "docker", "rb"])
        .assert()
        .code(1)
        .stderr(predicate::str::contains("ERROR: 'rb' is a run box of an unattended run (lbx --run); it cannot be attached to or started."));
}

#[test]
fn status_grammar_tables() {
    use lbx::status::Outcome;
    for ok in [
        "status=exited code=3",
        "status=signal code=143",
        "status=setup-failed code=125 cleanup=incomplete",
    ] {
        assert!(Outcome::parse(ok).is_some(), "{ok}");
    }
    for bad in [
        "status=exited code=",
        "status=exited  code=0",
        "code=0 status=exited",
    ] {
        assert!(Outcome::parse(bad).is_none(), "{bad}");
    }
}

#[test]
fn the_shipped_policies_are_written_on_first_use() {
    let w = world();
    lbx(&w).arg("--list").assert().code(0);
    for p in ["open", "enforce", "locked"] {
        let f = w
            .root
            .join("home/.config/llm_in_a_box")
            .join(format!("{p}.json"));
        assert!(f.is_file(), "{p}");
        assert!(Path::new(&f).metadata().is_ok_and(|m| m.len() > 10));
    }
}

// ---- interactive sessions through fake-docker ---------------------------

#[test]
fn attach_execs_docker_exec_with_the_agent_home() {
    let w = world();
    std::fs::write(
        w.root.join("table"),
        "s1|llm-in-a-box.runtime|docker|llm-in-a-box:docker|running||||agent\n",
    )
    .unwrap_or_else(|e| panic!("{e}"));
    lbx(&w)
        .arg("s1")
        .assert()
        .code(0)
        .stdout(predicate::str::contains(
            "==> Found existing docker session 's1' (running).",
        ))
        .stdout(predicate::str::contains(
            "==> Attaching to running container 's1' (docker) ...",
        ));
    let calls = w.calls_redacted();
    let user = whoami();
    assert!(
        calls.contains("exec s1 test -f /tmp/.user-ready\n"),
        "{calls}"
    );
    assert!(calls.contains(&format!("exec s1 id {user}\n")), "{calls}");
    assert!(
        calls.ends_with(&format!(
            "exec -it -e HOME=/home/agent -w /data s1 gosu {user} bash"
        )),
        "{calls}"
    );
}

#[test]
fn create_then_destroy_a_docker_session() {
    let w = world();
    lbx(&w)
        .args(["--runtime", "docker", "fresh"])
        .assert()
        .code(0)
        .stdout(predicate::str::contains(
            "==> Creating new container 'fresh' (docker) ...",
        ));
    let run_line = w
        .calls_redacted()
        .lines()
        .find(|l| l.starts_with("run -d"))
        .unwrap_or("")
        .to_string();
    settings().bind(|| insta::assert_snapshot!("interactive_create_call", run_line));
    let _ = std::fs::remove_file(w.root.join("calls.jsonl"));
    lbx(&w)
        .args(["--destroy", "fresh"])
        .assert()
        .code(0)
        .stdout(predicate::str::contains("==> Removed container 'fresh'."));
    settings().bind(|| insta::assert_snapshot!("destroy_calls", w.calls_redacted()));
}

#[test]
fn stop_and_force_stop() {
    let w = world();
    std::fs::write(
        w.root.join("table"),
        "a|llm-in-a-box.runtime|docker|llm-in-a-box:docker|running||||agent\n",
    )
    .unwrap_or_else(|e| panic!("{e}"));
    lbx(&w)
        .args(["--stop", "a", "b"])
        .assert()
        .code(1)
        .stderr("Session 'b' does not exist.\n");
    assert!(
        w.calls_redacted().contains("\nstop a\n"),
        "{}",
        w.calls_redacted()
    );
    lbx(&w)
        .args(["--stop", "--force", "a"])
        .assert()
        .code(0)
        .stdout(predicate::str::contains("force-stopped"));
    assert!(w.calls_redacted().contains("\nkill a\n"));
    lbx(&w)
        .args(["--force", "a"])
        .assert()
        .code(1)
        .stderr("ERROR: --force requires --stop or --shutdown.\n");
}

fn whoami() -> String {
    String::from_utf8_lossy(
        &std::process::Command::new("id")
            .arg("-un")
            .output()
            .map(|o| o.stdout)
            .unwrap_or_default(),
    )
    .trim()
    .to_string()
}

/// A state directory whose ancestor is a file: refused with only the
/// status line (no message of its own), and nothing is created.
#[test]
fn unmakeable_state_directory_refuses_with_only_the_status_line() {
    let w = world();
    std::fs::write(
        w.root.join("blocker"),
        "a file where a directory should be\n",
    )
    .unwrap_or_else(|e| panic!("{e}"));
    run_cmd(&w, "r97", &["true"])
        .env("LLMBOX_STATE_DIR", w.p("blocker/sub/state"))
        .assert()
        .code(125)
        .stderr("\nlbx-run: status=refused code=125\n");
    assert!(w.root.join("blocker").is_file());
    assert!(!w.calls().contains("\"run\",\"-d\""));
}
