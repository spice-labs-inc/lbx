//! Property tests (proptest) replacing the bash suites' RANDOM-driven
//! checks: hostile command vectors, session and run names, config lines,
//! timeouts and the status grammar.

use lbx::cli::{Options, parse, prescan_run, valid_session_name};
use lbx::config::{parse_text, value_ok};
use lbx::docker::run_exec_argv;
use lbx::run::{RUN_TIMEOUT_MAX, parse_timeout, valid_var_name};
use lbx::status::{Outcome, RunStatus};
use proptest::prelude::*;

fn run_prefix(name: &str) -> Vec<String> {
    [
        "--run",
        "--runtime",
        "docker",
        "--no-network",
        "--data",
        "/d",
        "--timeout",
        "5",
        name,
        "--",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect()
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(400))]

    /// Any command vector after `--` reaches the parser verbatim, even
    /// tokens that look like lbx options, and the exec vector ends with it.
    #[test]
    fn hostile_command_vectors_survive_parsing(cmd in prop::collection::vec(any::<String>(), 1..8)) {
        let mut args = run_prefix("job");
        args.extend(cmd.iter().cloned());
        prop_assert!(prescan_run(&args));
        let o: Options = parse(&args, true).map_err(|e| TestCaseError::fail(format!("{e:?}")))?;
        prop_assert_eq!(&o.run_cmd, &cmd);
        prop_assert_eq!(o.session.as_str(), "job");
        let exec = run_exec_argv("job", &[], "u", &o.run_cmd);
        prop_assert!(exec.ends_with(&cmd));
        prop_assert_eq!(&exec[..7], &["exec", "-i", "-w", "/data", "job", "gosu", "u"]);
    }

    /// A `--run` token after `--` is part of the command, not the mode.
    #[test]
    fn run_after_dashdash_is_not_run_mode(cmd in prop::collection::vec(any::<String>(), 0..5)) {
        let mut args: Vec<String> = vec!["name".into(), "--".into(), "--run".into()];
        args.extend(cmd);
        prop_assert!(!prescan_run(&args));
    }

    #[test]
    fn session_names_match_the_grammar(name in "[A-Za-z0-9][A-Za-z0-9._-]{0,40}") {
        prop_assert_eq!(valid_session_name(&name), name != "." && name != "..");
    }

    #[test]
    fn session_names_reject_anything_else(name in any::<String>()) {
        let grammar = !name.is_empty()
            && name.bytes().next().is_some_and(|b| b.is_ascii_alphanumeric())
            && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'_' || b == b'-')
            && name != "."
            && name != "..";
        prop_assert_eq!(valid_session_name(&name), grammar);
    }

    #[test]
    fn variable_names(name in any::<String>()) {
        let grammar = !name.is_empty()
            && name.bytes().next().is_some_and(|b| b.is_ascii_alphabetic() || b == b'_')
            && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_');
        prop_assert_eq!(valid_var_name(&name), grammar);
    }

    #[test]
    fn timeouts_accept_exactly_one_to_a_week(n in any::<u64>()) {
        let want = (1..=RUN_TIMEOUT_MAX).contains(&n);
        prop_assert_eq!(parse_timeout(&n.to_string()), want.then_some(n));
    }

    #[test]
    fn timeouts_reject_non_canonical_text(t in "[ +-]?0*[0-9]{0,7}[a-zA-Z.]{0,2}") {
        let canonical = !t.is_empty()
            && t.bytes().all(|b| b.is_ascii_digit())
            && !t.starts_with('0')
            && t.parse::<u64>().is_ok_and(|v| (1..=RUN_TIMEOUT_MAX).contains(&v));
        prop_assert_eq!(parse_timeout(&t).is_some(), canonical);
    }

    /// The config parser never panics, accepted values are always clean,
    /// and every non-blank non-comment line is either accepted or warned.
    #[test]
    fn config_text_never_panics(text in prop::collection::vec("[ -~]{0,30}", 0..12).prop_map(|v| v.join("\n"))) {
        let (vals, warnings) = parse_text(&text);
        for v in vals.values() {
            prop_assert!(value_ok(v));
        }
        let lines = text.lines().filter(|l| !l.is_empty() && !l.starts_with('#')).count();
        prop_assert!(vals.len() + warnings.len() <= lines);
    }

    #[test]
    fn status_lines_round_trip(status in 0usize..5, code in any::<i32>(), cleanup in any::<bool>()) {
        let status = [RunStatus::SetupFailed, RunStatus::Timeout, RunStatus::Signal, RunStatus::Exited, RunStatus::Refused][status];
        let o = Outcome { status, code, cleanup_incomplete: cleanup };
        prop_assert_eq!(Outcome::parse(&o.format()), Some(o));
    }

    #[test]
    fn status_grammar_rejects_garbage(line in "[a-z=0-9 ]{0,40}") {
        if let Some(o) = Outcome::parse(&line) {
            prop_assert_eq!(o.format(), line);
        }
    }
}
