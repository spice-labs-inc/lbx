# Testing

## The launcher's own tests

`cargo test --locked` runs the Rust tests; they need no docker, qemu or
root and finish in a few seconds. Four layers:

- Unit tests in `src/*.rs`: every docker argument vector (interactive box,
  relay, run box, exec) and the qemu vector compared whole against the
  expected `Vec<String>`; the option grammar; config parsing and
  precedence; the status grammar; the refusal shape; the run-name claim.
- Property tests in `tests/props.rs` (proptest): hostile command vectors
  after `--`, session and variable names against their grammars, timeouts,
  config text, status lines.
- Binary-level tests in `tests/contract.rs` (assert_cmd) with the crate's
  `fake-docker` first on `PATH`: it records every docker call as JSON and
  can fail a call, delay the command, report a leftover container or send
  the launcher a signal from inside a call (`FAKE_SIGNAL_ON`,
  `FAKE_SIGNAL`). The recorded calls of a run are pinned as insta snapshots
  in `tests/snapshots/` with the run id, the temp root and the host user
  redacted; `cargo insta review` (or `INSTA_UPDATE=always cargo test`)
  accepts an intended change.
- Transcripts in `tests/cmd/*.toml` (trycmd): the usage screen, the usage
  errors and the `--<flag> is only valid with --run.` lines, byte for byte.

A few checks of the bash suites that sourced the old bash launcher and
called its functions (config loading, the deny-log printer, the vm store
helpers) live in these Rust tests now and are listed as approved skips in
the suites.

## Run everything

```
tests/run-all-suites.sh --logs test-logs
```

A full run needs docker (not the snap package), passwordless sudo, qemu
(`qemu-system-x86`, `qemu-utils`), `/dev/kvm`, membership of the `kvm`
group, sysbox for the sysbox suite, and internet access. On a host that
lacks any of these, checks skip, and a skip fails the run (see below), so a
local run on a laptop is expected to be red. The launcher under test is
named with `--lbx <path>` or the `LBX_BIN` variable (default: the `lbx` on
`PATH`).

Continuous integration (`.github/workflows/ci.yml`) runs on GitHub-hosted
`ubuntu-24.04` runners: `cargo fmt --check`, `cargo clippy`, `cargo test`,
then it installs sysbox (the `fuse3` package and sysbox-ce 0.7.1 from
downloads.nestybox.com, waiting until docker lists the `sysbox-runc`
runtime), builds the relay, docker and sysbox images, and runs every suite
in `tests/` through `tests/run-all-suites.sh --no-build`, the sysbox suite
and the migrate suite included (the hosted runner has passwordless sudo, so
the root pass and the daemon restarts run there). The suites that need KVM
(`test_llm_in_a_box_vm.sh`, `verify-vm-e2e.sh`) run in a second job on a
self-hosted runner labeled `kvm`, only when the repository variable
`LBX_SELF_HOSTED` is `true`; otherwise that job is skipped. The job frees the
preinstalled toolchains it does not use before the builds, because a
hosted runner starts with about 13 GB free and each box image is about
9 GB. The image builds take about half an hour each on a hosted runner;
the repository variable `LBX_SKIP_IMAGE_BUILD=true` skips the sysbox
install, the builds and the suites when that is too long.

A single suite still runs on its own, for example
`bash tests/test_llm_in_a_box_sessions.sh`.

### Before a local run

Two things are **per boot** and are not installed anywhere, so a host that has
run the suites before can still be missing them:

- `sudo bash tests/setup-run-test-host.sh <your user>`: the fixtures under
  `/srv/lbx-test-fixtures`, the sudo rule for the test user, and the AppArmor
  profiles. The profiles are loaded with `apparmor_parser` from this tree, not
  installed into `/etc/apparmor.d`, so they are gone after a reboot. The script
  is idempotent; it also puts you in the `kvm` group when `/dev/kvm` exists
  (which needs a new login to take effect) and reports whether
  `qemu-system-x86_64` is installed; `qemu-img` alone is not enough for the
  session suites' virtual-machine checks.

  **Take the `kvm` group from a new login, not from `sg` or `newgrp`.** Those
  set the effective group id to that group for the command, so `id -g` stops
  returning your own group id, and `lbx` builds a box's user from the invoking
  user's ids. Measured: plain `id -g` is 1000, `sg kvm -c 'id -g'` is 990, and
  a regression started that way creates boxes whose group is 990, which fails
  the migration suite's ownership checks. `sudo -u <you> -i` gives you the
  group with your own ids.
- The sysbox daemons running (`sysbox`, `sysbox-mgr`, `sysbox-fs`), if the
  migrate suite is to run its real-container checks: it gates on `docker info`
  listing `sysbox-runc`, and the sysbox suite, the one that restarts the
  daemons, runs *after* it.

### Launching a long run

Launch a full run as:

```
setsid env --default-signal=INT --default-signal=QUIT bash tests/run-all-suites.sh [--no-build]
```

**Never with `nohup`, and never as a plain background job.** `nohup` sets
SIGHUP to `SIG_IGN`, and bash sets SIGINT to `SIG_IGN` for a background job; a
signal ignored at startup cannot be trapped, so the launcher's own handlers
do not run and checks like RUN18, RUN72, RUN84 and RUN85 fail for a reason that
has nothing to do with the launcher. `setsid` is what detaches the run from the
invoking shell's process group; `--default-signal` restores what detaching
through a background job costs. The run suite's `run_lbx` also resets INT, so
those checks no longer depend on the caller getting this right, but the suites
as a whole still expect the dispositions above.

`tests/test_relay_resolution.sh` checks the relay image alone and needs
only docker; once the relay image exists it needs no internet access (it
builds the image when missing, which pulls the base image): its relays
run with no network (or on an internal network with no route out). `LBX_TEST_RELAY_IMAGE` selects
the relay image it (and the relay-only checks of
`tests/test_llm_in_a_box_netwall.sh`) use; `LBX_TEST_SEED` replays its
property check. After changing `docker/relay`, run `./build relay` (or
point `LBX_TEST_RELAY_IMAGE` at a fresh build) first: an existing
`llm-in-a-box-relay:latest` is used as it is.

`tests/test_llm_in_a_box_sysbox.sh` covers the sysbox runtime: its
version and package requirements, the damage a sysbox daemon restart
causes to an existing box, and the launcher's report of it. It needs
sysbox installed (`sysbox-runc` registered with docker, sysbox 0.7.1 or
later, the `fuse3` package, and on Ubuntu 25.04 and later the fusermount3
AppArmor override from `apparmor/fusermount3-sysboxfs`), the
`llm-in-a-box:sysbox` image, and the
ability to restart the sysbox daemons (`sudo systemctl restart sysbox`),
because its central check reproduces that restart. Checks that need a real
box skip-not-fail when a prerequisite is absent. `LBX_TEST_SYSBOX_IMAGE`
selects the image; `LBX_TEST_SEED` replays the repeated-cycle property
check. See [sysbox-runtime.md](sysbox-runtime.md).

`tests/test_llm_in_a_box_migrate.sh` covers migrating sysbox boxes onto a
usable stack (`lbx --migrate`): that a damaged box migrates end to end with
its ID mapping applied again, that the agent sessions in its home directory
survive with their ownership, that the agent notice is delivered at all
three context paths, that `/data` is never touched, and that a migration
which cannot complete leaves the original box untouched. It needs the same
prerequisites as the sysbox suite (docker, `sysbox-runc`, the
`llm-in-a-box:sysbox` image, and the ability to restart the sysbox daemons)
plus root or passwordless `sudo`, because the export reads a box's
filesystem through `/proc/<pid>/root`; the runner therefore runs it again in
the root pass. The sysbox daemons must also be running when the suite
starts: it gates its real-container checks on `docker info` listing
`sysbox-runc`, and the sysbox suite, the one that restarts the daemons, runs
after it in the alphabetical suite order, so the first run after a boot
reports `MIG1` as an unapproved skip and the second passes it. Checks that
need a real box skip-not-fail when a prerequisite is absent. See
[sysbox-migration.md](sysbox-migration.md).

## Passes

Each suite prints one `[PASS]`, `[FAIL]` or `[SKIP]` line per check. The
runner runs them in passes (tests/test_run_all_suites.sh RS6, RS7):

1. **before-images**: `test_llm_in_a_box_vm.sh`, only when no
   llm-in-a-box image exists yet, because one of its checks needs a host
   without images.
2. Builds the images (`./build relay`, `./build docker`), unless
   `--no-build`. If the build fails, the run stops there and `summary.md`
   says so.
3. **user**: every `tests/test_*.sh` suite as the invoking user, then
   `tests/verify-run-unattended.sh` (unattended runs on real docker; it
   refuses root, so it runs only here). Continuous integration first runs
   `tests/setup-run-test-host.sh` as root to create the test user and the
   fixtures these suites need, and to load the run box's AppArmor
   profiles. `tests/verify-run-unattended.sh` also needs perl on the host
   (its socket servers), a writable `/srv/lbx-test` (the setup script
   makes it) and AppArmor enabled with those profiles loaded; its
   AppArmor profile checks VRUN25-VRUN28 run only on a kernel whose
   AppArmor mediates Unix sockets (see "Approved skips"). Directories its
   checks make under `/srv/lbx-test` (`lbx-test-v*-<process id>`) and
   `/tmp/lbx-test-v26tmp-<process id>.*` are removed by the suite's exit
   handling, also when it is interrupted, though not after SIGKILL (not
   tested). `/tmp/lbx-test-v2.*`, made by VRUN2
   as the test user, stays behind when the suite is interrupted; remove
   it by hand.
4. **root**: `test_llm_in_a_box_config.sh`, `test_llm_in_a_box_migrate.sh`
   and `test_vm_docker_store.sh` again as root, because some of their checks
   can only run as root (or with passwordless sudo) and others only as a
   normal user.

After each suite, new entries at the top of `/tmp` whose names match what
the suites use (`llm*`, `lbx*`, `netwall*`, `cfg17b*`,
`vm-docker-store-test*`) are removed; nothing else in `/tmp` is touched.
So the root pass never trips over files the user pass left behind
(tests/test_run_all_suites.sh RS5).

## How results are judged

A check is judged across all passes of its suite
(tests/test_run_all_suites.sh RS1):

- failed in any pass: **failed**
- passed in at least one pass and failed in none: **passed**
- skipped in every pass: **skipped**

A skip's reason in brackets at the end of its line is ignored when
matching, so a check that skips as root and passes as the user counts as
one passed check.

The run fails when any check failed, any suite exited non-zero, any suite
printed no result lines (RS3), or any check was skipped in every pass
without being on the approved list (RS2).

## Approved skips

`tests/approved-skips.txt` lists the only checks allowed to skip
everywhere, one `<suite file>|<check name prefix>` per line. Adding a line
needs the owner's approval, and matching is a prefix match, so a line
covers every check whose name starts with it. It holds: T18 of the sessions
suite (no sysbox runtime on a test host without sysbox); VRUN25-VRUN28 of
`tests/verify-run-unattended.sh`, the AppArmor profile checks, which skip on
a kernel whose AppArmor does not mediate Unix sockets (there `lbx` refuses
`--apparmor-profile`, and VRUN29 checks that refusal instead), and on a
kernel that decides a socket connection by the server's host path they skip
for that reason instead (VRUN30 and VRUN31 pin the two measured behaviors
those checks cannot reach); the vm suite's inverted gate, which asserts what
happens when no llm-in-a-box image exists and so cannot run on a host that
has just built the images; and the checks that sourced the old bash launcher
and now live in the crate's Rust tests. Each line says why.

## Where results appear

- The workflow's job summary (`summary.md`): a table per suite and pass,
  the judged totals, and every failed or unapproved-skipped check by name.
- `test-logs/junit.xml`: one test case per judged check (RS4).
- The `test-logs` artifact: every pass's full log, `build.log`,
  `summary.md`, `junit.xml`, and the raw `results.tsv`/`judged.tsv`.

