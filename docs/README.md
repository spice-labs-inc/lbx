# llm-in-a-box documentation

| Document | Contents |
|----------|----------|
| [../README.md](../README.md) | Project overview: what lbx is, the ten-minute docker path, the sysbox and vm paths, unattended runs, net policies, sessions, configuration, the old-launcher compatibility note, testing, license |
| [testing.md](testing.md) | Running the test suites, what a local run needs, how continuous integration judges them, approved skips |
| [in-box-agents.md](in-box-agents.md) | What the image installs: Claude Code, Pi and its plugins, OpenCode, OMP, the Umans CLI, the toolchains; provider setup inside a box |
| [session-removal-disambiguation.md](session-removal-disambiguation.md) | Removing or stopping one instance of a legacy duplicate name |
| [sysbox-runtime.md](sysbox-runtime.md) | The sysbox runtime: version and package requirements (0.7.1, fuse3), how ownership works inside a fake-root box, the daemon-restart failure that makes sudo report `uid 65534`, the remedy, and what `lbx` detects |
| [sysbox-migration.md](sysbox-migration.md) | Migrating sysbox boxes onto a usable stack (`lbx --migrate`): when it is needed and the order to do it in, what survives (agent sessions) and what does not (hand-installed packages), how to verify a migration, notes on running it under sudo, and the test map |
| [unattended-runs.md](unattended-runs.md) | Unattended runs (`lbx --run`): command line, how a run executes, run box compared with an interactive session, data-directory rules, the socket directory (`--socket-dir`) and its downsides, runs with no network (`--no-network`), the AppArmor profile (`--apparmor-profile`), refusals and fixes, reading results (status file, exit codes, deny log, deny reasons, relay idle timeout and request time limit), cleanup and SIGKILL recovery, `--env`, caller contract, residual risks, known limits |
| [releasing.md](releasing.md) | Cutting a release: the tag, what release.yml builds and attaches, the release notes block a consumer parses, verifying a release |
| [adr/](adr/) | Decision records 012 (unattended runs), 013 (VM images in the state directory), 014 (socket directory, no-network runs, AppArmor profile) |
| [llm/README_llm.md](llm/README_llm.md) | LLM reference: key files, VM runtime mechanics, unattended runs summary, VM storage design, config-file image selection, legacy detection, environment seams, glossary |
| [llm/session-removal-disambiguation_llm.md](llm/session-removal-disambiguation_llm.md) | LLM reference for session-removal disambiguation |
| [llm/sysbox-runtime_llm.md](llm/sysbox-runtime_llm.md) | LLM reference for the sysbox runtime: requirement enforcement points, ownership model, the daemon-restart state machine, the detection predicate's design constraints and call sites, entrypoint idempotency, test map, environment seams |
| [llm/sysbox-migration_llm.md](llm/sysbox-migration_llm.md) | LLM reference for sysbox box migration: the `--migrate` interface and refusals, the invariants the implementation must hold, the measured constraints (export path, why not `docker commit`, the box's-view health test, `docker cp` traps, the box-user identity), failure modes with their checks, environment seams, test map |
| [llm/unattended-runs_llm.md](llm/unattended-runs_llm.md) | LLM reference for unattended runs: grammar, full refusal list, data-directory and socket-directory rules, AppArmor checks, argument vectors (relay and no-network), entrypoint changes, outcome and cleanup contracts, test map |
| [llm/releasing_llm.md](llm/releasing_llm.md) | LLM reference for releasing: workflow steps, artifact names, the release notes block format and parser |

Behavior claims in the human documents name the test that verifies them
(a `tests/…` check label, or a `tests/verify-…` check for behavior that
requires real docker or a host with hardware virtualization); statements
that are operational guidance rather than verified behavior are marked as
such.
