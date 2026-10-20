//! fake-docker: a recording stand-in for the docker CLI for the crate's own
//! tests. Every call is appended to `$FAKE_DOCKER_JSON` as one JSON line
//! (`{"argv": [...]}`); the answers mirror the subset of
//! tests/fake-docker.sh that `lbx` needs. Unknown calls exit 1.
//!
//! Fixtures (env): FAKE_DOCKER_JSON (call log), FAKE_EXISTING_FILE (image
//! refs that exist, one per line), FAKE_CONTAINER_TABLE (the same
//! pipe-separated rows as the bash shim), FAKE_IMAGE_USER (the answer to
//! `image inspect --format {{.Config.User}}`).
//!
//! Test seams, each matched against the start of the argv joined by
//! spaces: FAKE_SIGNAL_ON + FAKE_SIGNAL (TERM, INT, HUP, USR1): send that
//! signal to the parent (the launcher) from inside the matching call, once;
//! FAKE_FAIL_ON: the matching call exits 1; FAKE_EXEC_RC: the exit code of
//! the `exec -i ... gosu` command call; FAKE_EXEC_SLEEP_MS: how long that
//! call takes; FAKE_LEFTOVER: a container name the by-label listing after
//! cleanup still reports; FAKE_RELAY_IP: the relay address answer;
//! FAKE_USER_READY_AFTER: how many `test -f /tmp/.user-ready` probes fail
//! before one succeeds; FAKE_ATTACH_REPL: the interactive `exec -it ...
//! gosu <user> bash` call runs a small line REPL (`id -un`, `echo $HOME`,
//! `pwd`, `exit`) instead of exiting, for the PTY tests.

use std::io::Write;

fn record(args: &[String]) {
    let Some(path) = std::env::var_os("FAKE_DOCKER_JSON") else {
        return;
    };
    let line = serde_json::json!({ "argv": args }).to_string();
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .append(true)
        .create(true)
        .open(path)
    {
        let _ = writeln!(f, "{line}");
    }
}

fn image_exists(image: &str) -> bool {
    let Some(p) = std::env::var_os("FAKE_EXISTING_FILE") else {
        return false;
    };
    std::fs::read_to_string(p)
        .map(|t| t.lines().any(|l| l == image))
        .unwrap_or(false)
}

struct Row {
    name: String,
    label_name: String,
    label_value: String,
    image: String,
    state: String,
    host_runtime: String,
    user: String,
}

fn table() -> Vec<Row> {
    let Some(p) = std::env::var_os("FAKE_CONTAINER_TABLE") else {
        return Vec::new();
    };
    std::fs::read_to_string(p)
        .map(|t| {
            t.lines()
                .map(|l| {
                    let f: Vec<&str> = l.split('|').collect();
                    let g = |i: usize| f.get(i).copied().unwrap_or("").to_string();
                    Row {
                        name: g(0),
                        label_name: g(1),
                        label_value: g(2),
                        image: g(3),
                        state: g(4),
                        host_runtime: g(5),
                        user: g(8),
                    }
                })
                .collect()
        })
        .unwrap_or_default()
}

fn add_row(line: &str) {
    if let Some(p) = std::env::var_os("FAKE_CONTAINER_TABLE")
        && let Ok(mut f) = std::fs::OpenOptions::new()
            .append(true)
            .create(true)
            .open(p)
    {
        let _ = writeln!(f, "{line}");
    }
}

/// Labels of containers and networks this fake created, as
/// `kind name label=value...` lines in `.labels`.
fn labels_path() -> Option<std::path::PathBuf> {
    std::env::var_os("FAKE_CONTAINER_TABLE")
        .map(|p| std::path::PathBuf::from(format!("{}.labels", p.to_string_lossy())))
}

fn remember_labels(kind: &str, name: &str, args: &[&str]) {
    let Some(p) = labels_path() else { return };
    let mut line = format!("{kind} {name}");
    for w in args.windows(2) {
        if w[0] == "--label" {
            line.push(' ');
            line.push_str(w[1]);
        }
    }
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .append(true)
        .create(true)
        .open(p)
    {
        let _ = writeln!(f, "{line}");
    }
}

fn label_of(kind: &str, name: &str, key: &str) -> Option<String> {
    let p = labels_path()?;
    let text = std::fs::read_to_string(p).ok()?;
    let line = text
        .lines()
        .rev()
        .find(|l| l.starts_with(&format!("{kind} {name} ")) || *l == format!("{kind} {name}"))?;
    Some(
        line.split(' ')
            .skip(2)
            .find_map(|kv| kv.strip_prefix(&format!("{key}=")))
            .unwrap_or("")
            .to_string(),
    )
}

fn forget(kind: &str, name: &str) {
    let Some(p) = labels_path() else { return };
    let Ok(text) = std::fs::read_to_string(&p) else {
        return;
    };
    let kept: Vec<&str> = text
        .lines()
        .filter(|l| !(l.starts_with(&format!("{kind} {name} ")) || *l == format!("{kind} {name}")))
        .collect();
    let _ = std::fs::write(p, format!("{}\n", kept.join("\n")));
}

fn matches_seam(var: &str, joined: &str) -> bool {
    std::env::var(var).is_ok_and(|p| !p.is_empty() && joined.starts_with(&p))
}

fn seams(args: &[String]) -> Option<i32> {
    let joined = args.join(" ");
    if matches_seam("FAKE_SIGNAL_ON", &joined) {
        let sig = match std::env::var("FAKE_SIGNAL").as_deref() {
            Ok("INT") => libc::SIGINT,
            Ok("HUP") => libc::SIGHUP,
            Ok("USR1") => libc::SIGUSR1,
            _ => libc::SIGTERM,
        };
        // Once: the marker file keeps a retried call from signalling again.
        let marker = std::env::var("FAKE_DOCKER_JSON")
            .map(|p| format!("{p}.signalled"))
            .unwrap_or_default();
        if !marker.is_empty() && !std::path::Path::new(&marker).exists() {
            let _ = std::fs::write(&marker, "");
            // SAFETY: a plain kill of the parent process with a valid signal.
            unsafe {
                libc::kill(libc::getppid(), sig);
            }
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
    }
    if matches_seam("FAKE_FAIL_ON", &joined) {
        return Some(1);
    }
    None
}

/// The user-ready probe: the first FAKE_USER_READY_AFTER probes fail (the
/// box is still starting), every later one succeeds.
fn user_ready() -> i32 {
    let after: usize = std::env::var("FAKE_USER_READY_AFTER")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    let probes = std::env::var("FAKE_DOCKER_JSON")
        .ok()
        .and_then(|p| std::fs::read_to_string(p).ok())
        .map(|t| t.lines().filter(|l| l.contains("/tmp/.user-ready")).count())
        .unwrap_or(1);
    if probes <= after { 1 } else { 0 }
}

/// A stand-in for the shell inside the box: one command per line.
fn attach_repl(home: &str, workdir: &str, user: &str) -> i32 {
    use std::io::BufRead;
    let home = home.strip_prefix("HOME=").unwrap_or(home);
    let stdin = std::io::stdin();
    let mut out = std::io::stdout();
    loop {
        let _ = write!(out, "fake-box:{user}$ ");
        let _ = out.flush();
        let mut line = String::new();
        match stdin.lock().read_line(&mut line) {
            Ok(0) | Err(_) => return 0,
            Ok(_) => {}
        }
        let answer = match line.trim() {
            "id -un" => user.to_string(),
            "echo $HOME" => home.to_string(),
            "pwd" => workdir.to_string(),
            "exit" => return 0,
            "" => continue,
            other => format!("fake-box: {other}: command not found"),
        };
        let _ = writeln!(out, "{answer}");
        let _ = out.flush();
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    record(&args);
    if let Some(code) = seams(&args) {
        std::process::exit(code);
    }
    let a: Vec<&str> = args.iter().map(String::as_str).collect();
    let code = match a.as_slice() {
        ["image", "inspect", "--format", "{{.Config.User}}", _] => {
            match std::env::var("FAKE_IMAGE_USER") {
                Ok(u) => {
                    println!("{u}");
                    0
                }
                Err(_) => 1,
            }
        }
        ["image", "inspect", image] => {
            if image_exists(image) {
                0
            } else {
                1
            }
        }
        ["info", ..] => {
            // FAKE_NO_SYSBOX_RUNTIME=1 models a host whose docker has no
            // sysbox runtime, so the "sysbox-runc runtime not found" refusal
            // can be checked on a host that has sysbox installed.
            if std::env::var("FAKE_NO_SYSBOX_RUNTIME").is_ok_and(|v| !v.is_empty()) {
                println!("{{}}");
            } else {
                println!("{{\"sysbox-runc\":{{}}}}");
            }
            0
        }
        ["run", "-d", rest @ ..] => {
            let mut name = "";
            let mut user = "";
            let mut runtime = "";
            for w in rest.windows(2) {
                if w[0] == "--name" {
                    name = w[1];
                }
                if w[0] == "--label"
                    && let Some(u) = w[1].strip_prefix("llm-in-a-box.user=")
                {
                    user = u;
                }
                if w[0] == "--label"
                    && let Some(r) = w[1].strip_prefix("llm-in-a-box.runtime=")
                {
                    runtime = r;
                }
            }
            // The image is the last argument before an optional command.
            let image = rest
                .iter()
                .find(|a| {
                    a.starts_with("llm-in-a-box")
                        || a.contains(':') && !a.contains('=') && !a.starts_with('/')
                })
                .copied()
                .unwrap_or("");
            if !name.is_empty() {
                let label = if runtime.is_empty() {
                    ""
                } else {
                    "llm-in-a-box.runtime"
                };
                add_row(&format!(
                    "{name}|{label}|{runtime}|{image}|running||||{user}"
                ));
                remember_labels("container", name, rest);
            }
            println!("fake-cid-{}", std::process::id());
            0
        }
        ["inspect", "-f", "{{.State.Status}}", name] => {
            match table().into_iter().find(|r| r.name == *name) {
                Some(r) => {
                    println!("{}", r.state);
                    0
                }
                None => 1,
            }
        }
        ["container", "inspect", "-f", fmt, name] => {
            if *fmt == "{{index .Config.Labels \"llm-in-a-box.run-id\"}}" {
                match label_of("container", name, "llm-in-a-box.run-id") {
                    Some(v) => {
                        println!("{v}");
                        std::process::exit(0)
                    }
                    None => {
                        eprintln!("Error: No such container: {name}");
                        std::process::exit(1)
                    }
                }
            }
            let Some(r) = table().into_iter().find(|r| r.name == *name) else {
                std::process::exit(1);
            };
            match *fmt {
                "{{index .Config.Labels \"llm-in-a-box.runtime\"}}|{{.Config.Image}}|{{.State.Status}}" =>
                {
                    let v = if r.label_name == "llm-in-a-box.runtime" {
                        r.label_value.as_str()
                    } else {
                        ""
                    };
                    println!("{v}|{}|{}", r.image, r.state);
                }
                "{{.HostConfig.Runtime}}" => println!("{}", r.host_runtime),
                "{{index .Config.Labels \"llm-in-a-box.runtime\"}}" => {
                    println!(
                        "{}",
                        if r.label_name == "llm-in-a-box.runtime" {
                            r.label_value.as_str()
                        } else {
                            ""
                        }
                    )
                }
                "{{index .Config.Labels \"box-of-claude.runtime\"}}" => {
                    println!(
                        "{}",
                        if r.label_name == "box-of-claude.runtime" {
                            r.label_value.as_str()
                        } else {
                            ""
                        }
                    )
                }
                "{{index .Config.Labels \"llm-in-a-box.user\"}}" => println!("{}", r.user),
                "{{index .Config.Labels \"llm-in-a-box.mode\"}}" => println!(
                    "{}",
                    label_of("container", name, "llm-in-a-box.mode").unwrap_or_default()
                ),
                "{{.Config.Image}}" => println!("{}", r.image),
                _ => std::process::exit(1),
            }
            0
        }
        ["container", "inspect", name] => {
            if table().iter().any(|r| r.name == *name) {
                0
            } else {
                1
            }
        }
        ["ps", "-a", "--format", "{{.Names}}"] => {
            for r in table() {
                println!("{}", r.name);
            }
            0
        }
        [
            "network",
            "inspect",
            "-f",
            "{{index .Labels \"llm-in-a-box.run-id\"}}",
            name,
        ] => match label_of("network", name, "llm-in-a-box.run-id") {
            Some(v) => {
                println!("{v}");
                0
            }
            None => {
                eprintln!("Error: No such network: {name}");
                1
            }
        },
        ["network", "inspect", _] => 1,
        ["ps", "-a", "--filter", _, "--format", "{{.Names}}"] => {
            if let Ok(left) = std::env::var("FAKE_LEFTOVER")
                && !left.is_empty()
            {
                println!("{left}");
            }
            0
        }
        ["network", "ls", "--filter", _, "--format", "{{.Name}}"] => 0,
        ["rm", "-f", name] | ["rm", name] => {
            forget("container", name);
            0
        }
        ["network", "create", rest @ ..] => {
            if let Some(name) = rest
                .iter()
                .rev()
                .find(|a| !a.starts_with("--") && !a.contains('='))
            {
                remember_labels("network", name, rest);
            }
            0
        }
        ["network", "rm", name] => {
            forget("network", name);
            0
        }
        ["exec", _, "test", "-f", "/tmp/.user-ready"] => user_ready(),
        [
            "exec",
            "-it",
            "-e",
            home,
            "-w",
            workdir,
            _,
            "gosu",
            user,
            "bash",
        ] if std::env::var_os("FAKE_ATTACH_REPL").is_some() => attach_repl(home, workdir, user),
        ["exec", "-i", "-w", "/data", ..] if a.contains(&"gosu") => {
            if let Ok(ms) = std::env::var("FAKE_EXEC_SLEEP_MS")
                && let Ok(ms) = ms.parse::<u64>()
            {
                std::thread::sleep(std::time::Duration::from_millis(ms));
            }
            std::env::var("FAKE_EXEC_RC")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(0)
        }
        ["inspect", "-f", fmt, _] if fmt.contains(".IPAddress") => {
            println!(
                "{}",
                std::env::var("FAKE_RELAY_IP").unwrap_or_else(|_| "172.18.0.2".into())
            );
            0
        }
        ["exec", ..] | ["stop", ..] | ["logs", ..] | ["kill", ..] | ["start", ..] => 0,
        _ => 1,
    };
    std::process::exit(code);
}
