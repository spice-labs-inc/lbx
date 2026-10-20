//! The `lbx` binary: a thin shell over the library, in the bash's order.

use lbx::cli::{self, CliError, Options, USAGE};
use lbx::config::{self, ConfigState};
use lbx::docker::Docker;
use lbx::session;
use lbx::util::{err, out, path_str};
use std::path::PathBuf;

/// The launcher's own directory (net-policies, apparmor live next to it).
fn script_dir() -> PathBuf {
    if let Some(d) = lbx::util::lbx_env("SCRIPT_DIR") {
        return PathBuf::from(d);
    }
    std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|d| d.to_path_buf()))
        .unwrap_or_else(|| PathBuf::from("."))
}

fn usage_err(msg: Option<&str>, fail_rc: i32) -> ! {
    if let Some(m) = msg {
        err(m);
    }
    let stderr = std::io::stderr();
    let mut h = stderr.lock();
    let _ = std::io::Write::write_all(&mut h, USAGE.as_bytes());
    let _ = std::io::Write::flush(&mut h);
    finish(fail_rc, fail_rc == 125)
}

/// Every exit: in the refusal stage the status line is printed last.
fn finish(code: i32, refusal_stage: bool) -> ! {
    if refusal_stage {
        lbx::run::refusal_status_exit();
    }
    std::process::exit(code)
}

fn main() {
    // The directory lbx was invoked from. It becomes the box's /data, so a
    // migration that builds a replacement box must run from the same place:
    // the replacement would otherwise be created with a different /data
    // mount than the box it replaces.
    let invoke_dir = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    let args: Vec<String> = std::env::args().skip(1).collect();
    let run_mode = cli::prescan_run(&args);
    let fail_rc = if run_mode { 125 } else { 1 };
    if run_mode {
        lbx::run::install_signal_handlers();
    }
    let o: Options = match cli::parse(&args, run_mode) {
        Ok(o) => o,
        Err(CliError::Usage(m)) => usage_err(m.as_deref(), fail_rc),
        Err(CliError::HelpOk) => {
            let stdout = std::io::stdout();
            let mut h = stdout.lock();
            let _ = std::io::Write::write_all(&mut h, USAGE.as_bytes());
            let _ = std::io::Write::flush(&mut h);
            std::process::exit(0)
        }
        Err(CliError::VersionOk) => {
            println!("lbx {}", env!("CARGO_PKG_VERSION"));
            std::process::exit(0)
        }
        Err(CliError::Plain(m, code)) => {
            err(&m);
            finish(code, run_mode)
        }
        Err(CliError::Refuse(m)) => lbx::run::refusal_exit(&lbx::run::refuse(&m)),
    };

    // Config: parse first, then the operation-class severity.
    let cfg = config::load();
    for w in &cfg.warnings {
        err(w);
    }
    if cfg.state == ConfigState::Unusable {
        let cleanup_op = o.list || o.destroy || o.stop || o.shutdown || o.denied.is_some();
        let hard = o.print_images
            || o.print_state_dir
            || (!cleanup_op && o.runtime != "vm" && !config_session_exists(&cfg, &o.session));
        if hard {
            err(&cfg.error);
            finish(fail_rc, run_mode);
        }
        err("WARNING: the config file is unusable; proceeding with defaults.");
    }
    if o.print_images {
        out(&format!(
            "sysbox={} docker={} vm={}",
            cfg.image_sysbox, cfg.image_docker, cfg.image_vm
        ));
        std::process::exit(0);
    }
    if o.print_state_dir {
        out(&path_str(&cfg.state_dir));
        std::process::exit(0);
    }

    // Shipped policies are copied on first use (never for a run).
    let sdir = script_dir();
    if !o.run {
        let home = lbx::util::home_dir();
        let target = home.join(".config/llm_in_a_box");
        let _ = std::fs::create_dir_all(&target);
        for p in lbx::assets::POLICY_NAMES {
            let dst = target.join(format!("{p}.json"));
            if dst.is_file() {
                continue;
            }
            let shipped = sdir.join("net-policies").join(format!("{p}.json"));
            if shipped.is_file() {
                let _ = std::fs::copy(&shipped, &dst);
            } else if let Some(text) = lbx::assets::policy(p) {
                let _ = std::fs::write(&dst, text);
            }
        }
    }
    if !o.net_policy.is_empty() {
        let p = std::path::Path::new(&o.net_policy);
        if !p.is_file() {
            err(&format!(
                "ERROR: net policy file not found: {}",
                o.net_policy
            ));
            finish(fail_rc, run_mode);
        }
        if let Err(e) = lbx::netpolicy::validate(p) {
            err(&format!("invalid net policy file: {e}"));
            err(&format!("ERROR: invalid net policy file: {}", o.net_policy));
            finish(fail_rc, run_mode);
        }
    }

    let needs_session = !o.list && !o.stop && !o.shutdown && o.denied.is_none() && !o.migrate;
    if needs_session {
        if o.session.is_empty() {
            usage_err(Some("ERROR: <session_name> is required"), fail_rc);
        }
        if !cli::valid_session_name(&o.session) {
            err(&format!(
                "ERROR: Invalid session name '{}' (allowed: letters, digits, '.', '_', '-'; must start with a letter or digit).",
                o.session
            ));
            finish(fail_rc, run_mode);
        }
    }
    if o.stop || o.shutdown {
        if o.sessions.is_empty() {
            usage_err(
                Some("ERROR: --stop/--shutdown requires at least one session name"),
                fail_rc,
            );
        }
        for name in &o.sessions {
            if !cli::valid_session_name(name) {
                err(&format!(
                    "ERROR: Invalid session name '{name}' (allowed: letters, digits, '.', '_', '-'; must start with a letter or digit)."
                ));
                std::process::exit(1);
            }
        }
    }
    if let Err(CliError::Plain(m, code)) = cli::validate_migrate(&o) {
        err(&m);
        std::process::exit(code);
    }
    if !o.vm_web_port.is_empty() && !o.vm_web_port.contains(':') {
        err(&format!(
            "ERROR: --vm-web-port requires <hostport>:<vmport> (got: {})",
            o.vm_web_port
        ));
        std::process::exit(1);
    }
    for p in &o.publish {
        if !p.contains(':') {
            err(&format!(
                "ERROR: --publish requires <hostport>:<boxport> (got: {p})"
            ));
            std::process::exit(1);
        }
    }
    let host_uid = lbx::util::host_uid();
    let host_gid = lbx::util::host_gid();
    let host_user = lbx::util::whoami();

    if o.list {
        if !o.session.is_empty() {
            err("ERROR: --list takes no session name.");
            std::process::exit(1);
        }
        for line in session::list_sessions(&cfg) {
            out(&line);
        }
        std::process::exit(0);
    }

    // An operation on its own, like --list: session names are arguments, and
    // no single session is involved. Reporting (--dry-run) deliberately runs
    // without the runtime preflight, because the operator needs it precisely
    // when the runtime is unusable.
    if o.migrate {
        let ok = lbx::migrate::migrate_main(
            &cfg,
            &o.sessions,
            o.migrate_all,
            o.migrate_dry_run,
            &invoke_dir,
        );
        std::process::exit(if ok { 0 } else { fail_rc });
    }

    if let Some(name) = &o.denied {
        denied(&cfg, name);
    }

    if o.run {
        lbx::run::refusal_exit(&lbx::run::run_main(
            &cfg, &o, &host_user, host_uid, host_gid, &sdir,
        ));
    }

    // Runtime resolution.
    let mut runtime = o.runtime.clone();
    if o.destroy || o.stop || o.shutdown {
        if !runtime.is_empty() && !matches!(runtime.as_str(), "sysbox" | "docker" | "vm") {
            err(&format!(
                "ERROR: Unknown runtime: {runtime} (must be sysbox, docker, or vm)"
            ));
            std::process::exit(1);
        }
    } else if !runtime.is_empty() {
        if !matches!(runtime.as_str(), "sysbox" | "docker" | "vm") {
            err(&format!(
                "ERROR: Unknown runtime: {runtime} (must be sysbox, docker, or vm)"
            ));
            std::process::exit(1);
        }
        match session::session_lookup(&cfg, &o.session) {
            session::Lookup::Ambiguous(rts) => {
                if !rts.contains(&runtime) {
                    err(&format!(
                        "ERROR: session '{}' exists in multiple runtimes ({}); --runtime {runtime} is not one of them.",
                        o.session,
                        rts.join(",")
                    ));
                    for rt in rts {
                        err(&format!("       Instead: lbx --runtime {rt} {}", o.session));
                    }
                    std::process::exit(1);
                }
            }
            session::Lookup::Missing => {}
            session::Lookup::Found(c) => {
                if runtime != c.runtime {
                    let rt = c.runtime;
                    err(&format!(
                        "ERROR: session '{}' already exists as a {rt} instance.",
                        o.session
                    ));
                    err(&format!(
                        "       Attach:  lbx [--runtime {rt}] {}",
                        o.session
                    ));
                    err(&format!(
                        "       Remove:  lbx --destroy [--runtime {rt}] {}",
                        o.session
                    ));
                    std::process::exit(1);
                }
            }
        }
    } else {
        match session::session_lookup(&cfg, &o.session) {
            session::Lookup::Ambiguous(rts) => {
                err(&format!(
                    "ERROR: session '{}' exists in multiple runtimes ({}).",
                    o.session,
                    rts.join(",")
                ));
                err("       Disambiguate with --runtime, e.g.:");
                for rt in rts {
                    err(&format!("         lbx --runtime {rt} {}", o.session));
                }
                std::process::exit(1);
            }
            session::Lookup::Missing => {
                runtime = session::detect_runtime(&cfg);
                if runtime.is_empty() {
                    err("ERROR: No llm-in-a-box image found and no suitable runtime detected.");
                    err("");
                    err("  Build an image first:");
                    err("    ./build sysbox   # requires Docker + sysbox");
                    err("    ./build docker   # requires Docker");
                    err("    ./build vm       # requires Docker (auto-selected when built)");
                    std::process::exit(1);
                }
                out(&format!("==> Auto-detected runtime: {runtime}"));
            }
            session::Lookup::Found(c) => {
                runtime = c.runtime.clone();
                if c.legacy {
                    err(&format!(
                        "note: session '{}' is an old (legacy) session — consider re-creating it with lbx.",
                        o.session
                    ));
                }
                out(&format!(
                    "==> Found existing {runtime} session '{}' ({}).",
                    o.session, c.state
                ));
            }
        }
    }

    if o.destroy {
        std::process::exit(session::destroy(&cfg, &o.session, &runtime));
    }
    if o.stop || o.shutdown {
        std::process::exit(session::stop(
            &cfg,
            &o.sessions,
            &runtime,
            o.force,
            &host_user,
        ));
    }
    if runtime == "vm" {
        let _ = lbx::vm::preflight(&cfg, &o.session, &sdir);
        let state = session::vm_state_for(&cfg, &o.session);
        let la = lbx::vm::LaunchArgs {
            cfg: &cfg,
            session: &o.session,
            host_user: &host_user,
            host_uid,
            host_gid,
            ports: o.ports,
            publish: &o.publish,
            vm_web_port: &o.vm_web_port,
            devices: &o.devices,
            net_policy: &o.net_policy,
        };
        match state.as_str() {
            "running" => {
                out(&format!("==> Attaching to running vm '{}' ...", o.session));
                std::process::exit(lbx::vm::attach(&cfg, &o.session, &host_user));
            }
            "exited" => {
                if session::vm_live_pid_for(&cfg, &o.session).is_some() {
                    out(&format!(
                        "==> vm '{}' is running (stale state files) — attaching ...",
                        o.session
                    ));
                    std::process::exit(lbx::vm::attach(&cfg, &o.session, &host_user));
                }
                out(&format!("==> Restarting stopped vm '{}' ...", o.session));
            }
            _ => out(&format!("==> Creating new vm '{}' ...", o.session)),
        }
        lbx::vm::launch(&la);
        if !lbx::vm::wait_ssh(&cfg, &o.session, &host_user) {
            std::process::exit(1);
        }
        std::process::exit(lbx::vm::attach(&cfg, &o.session, &host_user));
    }
    let code = session::launch(&session::Launch {
        cfg: &cfg,
        session: o.session.clone(),
        runtime,
        host_user,
        host_uid,
        host_gid,
        fuse: o.fuse,
        ports: o.ports,
        publish: o.publish.clone(),
        vm_web_port: o.vm_web_port.clone(),
        devices: o.devices.clone(),
        net_policy: o.net_policy.clone(),
    });
    std::process::exit(code);
}

/// The existing-session probe for the unusable-config severity decision.
fn config_session_exists(cfg: &config::Resolved, name: &str) -> bool {
    if cfg.state_dir.join("sessions").join(name).is_dir() {
        return true;
    }
    if !Docker::available() || !Docker::container_exists(name) {
        return false;
    }
    if !Docker::container_label(name, "llm-in-a-box.runtime").is_empty() {
        return true;
    }
    if !Docker::container_label(name, "box-of-claude.runtime").is_empty() {
        return true;
    }
    let img = Docker::container_fmt(name, "{{.Config.Image}}").unwrap_or_default();
    img.starts_with("llm-in-a-box:") || img.starts_with("box-of-claude:")
}

/// `--denied <name>`: print the session's deny log.
fn denied(cfg: &config::Resolved, name: &str) -> ! {
    if !cli::valid_session_name(name) {
        err(&format!("ERROR: Invalid session name '{name}'."));
        std::process::exit(1);
    }
    let logf = cfg.state_dir.join("netlogs").join(name).join("deny.log");
    let is_link = std::fs::symlink_metadata(&logf).is_ok_and(|m| m.file_type().is_symlink());
    let mut is_run = cfg.state_dir.join("runs").join(name).is_dir();
    if !is_run && is_link && Docker::container_label(name, "llm-in-a-box.mode") == "run" {
        is_run = true;
    }
    if is_run {
        if is_link {
            err(&format!(
                "ERROR: the deny log of run '{name}' is a symbolic link; refusing to follow it."
            ));
            std::process::exit(1);
        }
        if logf.is_file() {
            // Open without following links and without blocking.
            use std::os::unix::fs::OpenOptionsExt;
            let f = std::fs::OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
                .open(&logf);
            match f.and_then(|mut f| {
                let mut buf = Vec::new();
                std::io::Read::read_to_end(&mut f, &mut buf).map(|_| buf)
            }) {
                Ok(bytes) => {
                    let stdout = std::io::stdout();
                    let mut h = stdout.lock();
                    let _ = std::io::Write::write_all(&mut h, &bytes);
                }
                Err(_) => {
                    err(&format!(
                        "ERROR: could not read the deny log of run '{name}' without following a link."
                    ));
                    std::process::exit(1);
                }
            }
        } else {
            out(&format!("No deny log for run '{name}'."));
        }
        std::process::exit(0);
    }
    if logf.is_file() {
        if let Ok(bytes) = std::fs::read(&logf) {
            let stdout = std::io::stdout();
            let mut h = stdout.lock();
            let _ = std::io::Write::write_all(&mut h, &bytes);
        }
    } else {
        out(&format!(
            "No deny log for session '{name}' (it ran without a net policy)."
        ));
    }
    std::process::exit(0);
}
