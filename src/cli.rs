//! Argument handling, mirroring the bash parser exactly: the pre-scan for
//! `--run`, the option loop, and the post-parse rules (run-only flags, the
//! refusals of options that cannot combine with `--run`).

pub const USAGE: &str = r#"Usage: lbx [options] <session_name>

Options:
  --runtime <sysbox|docker|vm>          Choose isolation runtime (default: auto-detect;
                                        see runtime.default in the config file)
  --device <path>                       Pass a host device into the session (repeatable)
  --fuse                                Enable FUSE support
  --ports                               Expose session ports 8080 and 3000 on the host
  --publish <hostport>:<boxport>        Expose any port served by the box on the host
                                        (repeatable)
  --vm-web-port <hostport>:<vmport>     Expose the qemu VM web port on the host
  --destroy                             Remove the session (docker rm -f, or kill+delete the vm)
  --shutdown [--force] <name>...         Gracefully stop one or more sessions (any runtime); --force kills
  --stop [--force] <name>...             Same as --shutdown (alias)
  --list                                List all sessions across all runtimes
  --migrate <name>...                    Move existing sysbox sessions onto the current
                                        stack: export each box's home directory, build
                                        a replacement, verify it, then remove the old
                                        box. Upgrade sysbox BEFORE migrating.
  --all                                 With --migrate: every sysbox session (never implied)
  --dry-run                             With --migrate: report only; change nothing
  --version                             Print the launcher version and exit
  --net-policy <file>                    Host-side network wall policy (JSON: mode/allow/block); default: no wall
  --denied <name>                        Print the session's deny log
  --print-images                        Print the configured image refs (build parity; internal)
  --print-state-dir                     Print the resolved state directory (build parity; internal)
  --run                                 Unattended run: run one command in a new, locked-down box,
                                        then remove the box (see "Unattended runs" below)
  --data <dir>                          Unattended run: host directory mounted at /data
  --env <NAME>                          Unattended run: make host variable NAME available to the
                                        command (repeatable)
  --timeout <seconds>                   Unattended run: stop the command after this many seconds
                                        (1 to 604800)
  --no-network                          Unattended run: no network at all, only loopback, no relay
                                        (instead of --net-policy)
  --socket-dir <dir>                    Unattended run: directory of your Unix sockets, mounted
                                        read-only at /run/agent
  --apparmor-profile                    Unattended run: run the box under the llm-in-a-box AppArmor
                                        profile (root loads apparmor/llm-in-a-box-run first)

Unattended runs:
  lbx --run --runtime docker --net-policy <file> --data <dir> --timeout <seconds>
      [--env NAME]... <name> -- <command> [args...]
  Runs <command> once, with no terminal, in an unprivileged run box that reaches the
  network only through the relay (policy mode enforce or locked), then removes the box.
  <name> must not have been used before. Exit code: the command's own; 124 timeout;
  125 refused or setup failed (also when cleanup is incomplete after exit 0);
  129/130/143 signal (138: SIGUSR1 during the checks or name claim). The outcome is in
  $LBX_STATE_DIR/runs/<name>/status
  (authoritative), the deny log in $LBX_STATE_DIR/netlogs/<name>/deny.log.
  See docs/unattended-runs.md.
  With no network at all (no relay, no deny log), --no-network replaces --net-policy:
  lbx --run --runtime docker --no-network --data <dir> --timeout <seconds>
      [--env NAME]... <name> -- <command> [args...]
  Either form also takes [--socket-dir <dir>] [--apparmor-profile].

Runtime selection: --runtime wins; otherwise auto-detect tries vm (base
built), then sysbox (image + sysbox-runc present), then docker. A
runtime.default config key / LBX_RUNTIME_DEFAULT env var is tried
FIRST (when usable) and falls back to that order with a warning.

Port exposure:
  --publish and --ports expose a port SERVED BY THE BOX itself:
    --runtime vm              qemu hostfwd (host <hostport> -> box vm <boxport>)
    --runtime sysbox/docker   docker -p (host <hostport> -> box <boxport>)
  --vm-web-port exposes a port of a qemu VM RUNNING INSIDE the box
  (you run that VM; it gets the bridged 192.168.200.2):
    --runtime vm              qemu hostfwd (host <hostport> -> vm <vmport>)
    --runtime sysbox/docker   docker -p + in-guest DNAT to the inner VM's
                              bridged IP; that inner-VM mode needs the
                              sysbox tunneling grant (/dev/net/tun + NET_ADMIN)

Configuration (precedence: CLI flag > env var > config file > default):
  File:   $LBX_CONFIG (default ~/.config/llm_in_a_box/config).
          Lines are key=value; # comments allowed.
  Keys:   image.sysbox|image.docker|image.vm   image refs (default llm-in-a-box:*)
          state.dir        LBX_STATE_DIR        global box-state dir (default ~/.llm-in-a-box)
          vm.mem           LBX_VM_MEM           vm memory in MiB (default 16384)
          vm.cpus          LBX_VM_CPUS          vm vCPUs (default 8)
          vm.accel         LBX_VM_ACCEL         kvm (default) or tcg
          vm.store.size    LBX_VM_STORE_IMG_SIZE  docker-store image size (default 500G)
          vm.store.disable LBX_VM_STORE_DISABLE =1 skips the store image (guest falls back to local docker)
          vm.missing       LBX_VM_MISSING       TEST-ONLY: pretend named vm prereqs are missing
          runtime.default  LBX_RUNTIME_DEFAULT  preferred auto-detect runtime (tried first)
  An unreadable/invalid config warns for cleanup ops but hard-errors when
  creating a new docker/sysbox session, on auto-detect, and for
  --print-images.
"#;

/// Every option the launcher knows, as parsed (no validation beyond the
/// parser's own syntax errors).
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Options {
    pub runtime: String,
    pub devices: Vec<String>,
    pub fuse: bool,
    pub ports: bool,
    pub publish: Vec<String>,
    pub vm_web_port: String,
    pub destroy: bool,
    pub shutdown: bool,
    pub stop: bool,
    pub force: bool,
    pub list: bool,
    pub migrate: bool,
    pub migrate_all: bool,
    pub migrate_dry_run: bool,
    pub denied: Option<String>,
    pub print_images: bool,
    pub print_state_dir: bool,
    pub net_policy: String,
    pub net_policy_given: bool,
    pub session: String,
    pub sessions: Vec<String>,
    pub run: bool,
    pub run_data: String,
    pub run_data_set: bool,
    pub run_envs: Vec<String>,
    pub run_timeouts: Vec<String>,
    pub run_cmd: Vec<String>,
    pub run_socket_dirs: Vec<String>,
    pub run_no_network: bool,
    pub run_apparmor: bool,
    pub have_dashdash: bool,
    pub help_requested: bool,
}

/// How the parser wants the launcher to end.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CliError {
    /// A message (optional), then the usage screen on stderr, then exit
    /// with the failure code (1, or 125 under --run).
    Usage(Option<String>),
    /// The usage screen on stdout, exit 0.
    HelpOk,
    /// The version line on stdout, exit 0.
    VersionOk,
    /// A plain message on stderr and an exit code.
    Plain(String, i32),
    /// An unattended-run refusal: `\nERROR: <msg>` and exit 125.
    Refuse(String),
}

/// The pre-scan: `--run` before the first `--`, skipping option values the
/// way the parser consumes them. True means every failure is a refusal.
pub fn prescan_run(args: &[String]) -> bool {
    let mut skip = false;
    for a in args {
        if skip {
            skip = false;
            continue;
        }
        match a.as_str() {
            "--" => return false,
            "--run" => return true,
            "--data" | "--env" | "--timeout" | "--runtime" | "--device" | "--publish"
            | "--vm-web-port" | "--denied" | "--net-policy" | "--socket-dir" => skip = true,
            _ => {}
        }
    }
    false
}

fn need(args: &[String], i: usize, msg: &str) -> Result<String, CliError> {
    match args.get(i + 1) {
        Some(v) => Ok(v.clone()),
        None => Err(CliError::Usage(Some(format!("ERROR: {msg}")))),
    }
}

/// The option loop plus the post-parse rules. `run_mode` is the pre-scan
/// result (it decides how `--help` behaves).
pub fn parse(args: &[String], run_mode: bool) -> Result<Options, CliError> {
    let mut o = Options::default();
    let mut i = 0;
    while i < args.len() {
        let a = args[i].as_str();
        match a {
            "--run" => {
                o.run = true;
                i += 1;
            }
            "--data" => {
                o.run_data = need(args, i, "--data requires a directory")?;
                o.run_data_set = true;
                i += 2;
            }
            "--env" => {
                o.run_envs
                    .push(need(args, i, "--env requires a variable name")?);
                i += 2;
            }
            "--timeout" => {
                o.run_timeouts
                    .push(need(args, i, "--timeout requires a number of seconds")?);
                i += 2;
            }
            "--socket-dir" => {
                o.run_socket_dirs
                    .push(need(args, i, "--socket-dir requires a directory")?);
                i += 2;
            }
            "--no-network" => {
                o.run_no_network = true;
                i += 1;
            }
            "--apparmor-profile" => {
                o.run_apparmor = true;
                i += 1;
            }
            "--" => {
                o.have_dashdash = true;
                o.run_cmd = args[i + 1..].to_vec();
                break;
            }
            "--runtime" => {
                o.runtime = need(args, i, "--runtime requires an argument")?;
                i += 2;
            }
            "--device" => {
                o.devices
                    .push(need(args, i, "--device requires an argument")?);
                i += 2;
            }
            "--fuse" => {
                o.fuse = true;
                i += 1;
            }
            "--ports" => {
                o.ports = true;
                i += 1;
            }
            "--publish" => {
                o.publish
                    .push(need(args, i, "--publish requires <hostport>:<boxport>")?);
                i += 2;
            }
            "--help" | "-h" | "-?" => {
                if run_mode {
                    o.help_requested = true;
                    i += 1;
                } else {
                    return Err(CliError::HelpOk);
                }
            }
            "--version" | "-V" => return Err(CliError::VersionOk),
            "--vm-web-port" => {
                o.vm_web_port = need(args, i, "--vm-web-port requires an argument")?;
                i += 2;
            }
            "--destroy" => {
                o.destroy = true;
                i += 1;
            }
            "--shutdown" => {
                o.shutdown = true;
                i += 1;
            }
            "--stop" => {
                o.stop = true;
                i += 1;
            }
            "--force" => {
                o.force = true;
                i += 1;
            }
            "--list" => {
                o.list = true;
                i += 1;
            }
            "--migrate" => {
                o.migrate = true;
                i += 1;
            }
            "--all" => {
                o.migrate_all = true;
                i += 1;
            }
            "--dry-run" => {
                o.migrate_dry_run = true;
                i += 1;
            }
            "--denied" => {
                o.denied = Some(need(args, i, "--denied requires a session name")?);
                i += 2;
            }
            "--print-images" => {
                o.print_images = true;
                i += 1;
            }
            "--print-state-dir" => {
                o.print_state_dir = true;
                i += 1;
            }
            "--net-policy" => {
                o.net_policy = need(args, i, "--net-policy requires an argument")?;
                o.net_policy_given = true;
                i += 2;
            }
            _ if a.starts_with('-') => {
                return Err(CliError::Usage(Some(format!("ERROR: Unknown option: {a}"))));
            }
            _ => {
                if o.stop || o.shutdown || o.migrate {
                    o.sessions.push(a.to_string());
                } else {
                    if !o.session.is_empty() {
                        return Err(CliError::Usage(Some(
                            "ERROR: Multiple session names given".to_string(),
                        )));
                    }
                    o.session = a.to_string();
                }
                i += 1;
            }
        }
    }
    post_parse(&mut o)?;
    Ok(o)
}

/// The rules the bash applies right after its option loop.
fn post_parse(o: &mut Options) -> Result<(), CliError> {
    if o.have_dashdash && !o.run {
        return Err(CliError::Usage(Some(
            "ERROR: Unknown option: --".to_string(),
        )));
    }
    if !o.run {
        let run_only: [(&str, bool); 6] = [
            ("data", o.run_data_set),
            ("env", !o.run_envs.is_empty()),
            ("timeout", !o.run_timeouts.is_empty()),
            ("socket-dir", !o.run_socket_dirs.is_empty()),
            ("no-network", o.run_no_network),
            ("apparmor-profile", o.run_apparmor),
        ];
        for (flag, given) in run_only {
            if given {
                return Err(CliError::Plain(
                    format!("ERROR: --{flag} is only valid with --run."),
                    1,
                ));
            }
        }
    }
    if o.run {
        let mut refuse_with = "";
        if o.help_requested {
            refuse_with = "--help";
        }
        if o.destroy {
            refuse_with = "--destroy";
        }
        if o.stop {
            refuse_with = "--stop";
        }
        if o.shutdown {
            refuse_with = "--shutdown";
        }
        if o.force {
            refuse_with = "--force";
        }
        if o.list {
            refuse_with = "--list";
        }
        if o.denied.is_some() {
            refuse_with = "--denied";
        }
        if o.migrate {
            refuse_with = "--migrate";
        }
        if o.migrate_all {
            refuse_with = "--all";
        }
        if o.migrate_dry_run {
            refuse_with = "--dry-run";
        }
        if o.print_images {
            refuse_with = "--print-images";
        }
        if o.print_state_dir {
            refuse_with = "--print-state-dir";
        }
        if o.ports {
            refuse_with = "--ports";
        }
        if !o.publish.is_empty() {
            refuse_with = "--publish";
        }
        if !o.vm_web_port.is_empty() {
            refuse_with = "--vm-web-port";
        }
        if !o.devices.is_empty() {
            refuse_with = "--device";
        }
        if o.fuse {
            refuse_with = "--fuse";
        }
        if !refuse_with.is_empty() {
            return Err(CliError::Refuse(format!(
                "{refuse_with} cannot be combined with --run."
            )));
        }
        if o.run_no_network && o.net_policy_given {
            return Err(CliError::Refuse(
                "--no-network cannot be combined with --net-policy.".to_string(),
            ));
        }
        if !(o.have_dashdash && !o.run_cmd.is_empty()) {
            return Err(CliError::Refuse(
                "--run needs a command after -- (lbx --run ... <name> -- <command> [args...])."
                    .to_string(),
            ));
        }
    }
    if (o.stop || o.shutdown || o.migrate) && !o.session.is_empty() && o.sessions.is_empty() {
        o.sessions.push(std::mem::take(&mut o.session));
    }
    if o.force && !o.stop && !o.shutdown {
        return Err(CliError::Plain(
            "ERROR: --force requires --stop or --shutdown.".to_string(),
            1,
        ));
    }
    Ok(())
}

/// The `--migrate` argument rules, applied where the bash applies them:
/// after the session-name checks, before the operation runs. `--all` is
/// never implied, because the operation removes containers; `--dry-run`
/// and `--all` mean nothing without `--migrate`, and saying so is friendlier
/// than silently ignoring them.
pub fn validate_migrate(o: &Options) -> Result<(), CliError> {
    if o.migrate {
        if !o.migrate_all && o.sessions.is_empty() {
            return Err(CliError::Plain(
                "ERROR: --migrate requires at least one session name, or --all.\n       Run 'lbx --list' to see the sessions, or 'lbx --migrate --dry-run <name>' to see what would happen.".to_string(),
                1,
            ));
        }
        if o.migrate_all && !o.sessions.is_empty() {
            return Err(CliError::Plain(
                "ERROR: --all takes no session names.".to_string(),
                1,
            ));
        }
        for name in &o.sessions {
            if !valid_session_name(name) {
                return Err(CliError::Plain(
                    format!(
                        "ERROR: Invalid session name '{name}' (allowed: letters, digits, '.', '_', '-'; must start with a letter or digit)."
                    ),
                    1,
                ));
            }
        }
        return Ok(());
    }
    if o.migrate_all {
        return Err(CliError::Plain(
            "ERROR: --all is only valid with --migrate.".to_string(),
            1,
        ));
    }
    if o.migrate_dry_run {
        return Err(CliError::Plain(
            "ERROR: --dry-run is only valid with --migrate.".to_string(),
            1,
        ));
    }
    Ok(())
}

/// Session names flow into state paths and docker --name.
pub fn valid_session_name(name: &str) -> bool {
    if name.is_empty() || name == "." || name == ".." {
        return false;
    }
    let mut chars = name.chars();
    match chars.next() {
        Some(c) if c.is_ascii_alphanumeric() => {}
        _ => return false,
    }
    name.chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == '-')
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(a: &[&str]) -> Vec<String> {
        a.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn run_only_flags_without_run_fail_with_the_probe_line() {
        for flag in [
            "--data x",
            "--env X",
            "--timeout 3",
            "--socket-dir x",
            "--no-network",
            "--apparmor-profile",
        ] {
            let args: Vec<String> = flag.split(' ').map(|s| s.to_string()).collect();
            let name = flag
                .split(' ')
                .next()
                .unwrap_or("")
                .trim_start_matches("--");
            let r = parse(&args, prescan_run(&args));
            assert_eq!(
                r,
                Err(CliError::Plain(
                    format!("ERROR: --{name} is only valid with --run."),
                    1
                ))
            );
        }
    }

    #[test]
    fn version_flag_prints_the_version_in_either_mode() {
        assert_eq!(parse(&v(&["--version"]), false), Err(CliError::VersionOk));
        assert_eq!(parse(&v(&["-V"]), false), Err(CliError::VersionOk));
    }

    #[test]
    fn prescan_skips_option_values() {
        assert!(!prescan_run(&v(&["--net-policy", "--run", "x"])));
        assert!(prescan_run(&v(&["--data", "d", "--run"])));
        assert!(!prescan_run(&v(&["x", "--", "--run"])));
    }

    #[test]
    fn stop_collects_names_before_and_after_the_flag() {
        let o = parse(&v(&["foo", "--stop"]), false).unwrap_or_default();
        assert_eq!(o.sessions, v(&["foo"]));
        let o = parse(&v(&["--stop", "a", "b"]), false).unwrap_or_default();
        assert_eq!(o.sessions, v(&["a", "b"]));
    }

    #[test]
    fn migrate_collects_names_before_and_after_the_flag() {
        let o = parse(&v(&["foo", "--migrate"]), false).unwrap_or_default();
        assert!(o.migrate);
        assert_eq!(o.sessions, v(&["foo"]));
        assert_eq!(o.session, "");
        let o = parse(&v(&["--migrate", "a", "b"]), false).unwrap_or_default();
        assert_eq!(o.sessions, v(&["a", "b"]));
        let o = parse(&v(&["--migrate", "--dry-run", "a"]), false).unwrap_or_default();
        assert!(o.migrate_dry_run && !o.migrate_all);
        assert_eq!(o.sessions, v(&["a"]));
        assert_eq!(validate_migrate(&o), Ok(()));
        let o = parse(&v(&["--migrate", "--all"]), false).unwrap_or_default();
        assert!(o.migrate_all);
        assert_eq!(validate_migrate(&o), Ok(()));
    }

    #[test]
    fn migrate_grammar_refusals_carry_the_upstream_messages() {
        let o = parse(&v(&["--migrate"]), false).unwrap_or_default();
        assert_eq!(
            validate_migrate(&o),
            Err(CliError::Plain(
                "ERROR: --migrate requires at least one session name, or --all.\n       Run 'lbx --list' to see the sessions, or 'lbx --migrate --dry-run <name>' to see what would happen.".to_string(),
                1
            ))
        );
        let o = parse(&v(&["--migrate", "--all", "a"]), false).unwrap_or_default();
        assert_eq!(
            validate_migrate(&o),
            Err(CliError::Plain(
                "ERROR: --all takes no session names.".to_string(),
                1
            ))
        );
        let o = parse(&v(&["--migrate", "-bad"]), false);
        assert!(matches!(o, Err(CliError::Usage(_))), "{o:?}");
        let o = parse(&v(&["--migrate", "a", "b c"]), false).unwrap_or_default();
        assert!(
            matches!(validate_migrate(&o), Err(CliError::Plain(m, 1)) if m.starts_with("ERROR: Invalid session name 'b c'"))
        );
        let o = parse(&v(&["--all", "a"]), false).unwrap_or_default();
        assert_eq!(
            validate_migrate(&o),
            Err(CliError::Plain(
                "ERROR: --all is only valid with --migrate.".to_string(),
                1
            ))
        );
        let o = parse(&v(&["--dry-run", "a"]), false).unwrap_or_default();
        assert_eq!(
            validate_migrate(&o),
            Err(CliError::Plain(
                "ERROR: --dry-run is only valid with --migrate.".to_string(),
                1
            ))
        );
    }

    #[test]
    fn migrate_flags_are_refused_under_run() {
        for flag in ["--migrate", "--all", "--dry-run"] {
            let args = v(&["--run", flag, "j", "--", "true"]);
            assert_eq!(
                parse(&args, prescan_run(&args)),
                Err(CliError::Refuse(format!(
                    "{flag} cannot be combined with --run."
                )))
            );
        }
    }

    #[test]
    fn session_names() {
        assert!(valid_session_name("a.b_c-9"));
        assert!(!valid_session_name("-a"));
        assert!(!valid_session_name(".."));
        assert!(!valid_session_name("a b"));
    }
}
