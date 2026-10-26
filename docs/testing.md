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

Continuous integration (`.github/workflows/ci.yml`) runs two jobs on
GitHub-hosted `ubuntu-24.04` runners. The first is quick and needs no
docker daemon: `cargo fmt --check`, `cargo clippy`, `cargo test` and the
suite runner's own test. The second runs the suites: it frees the disk
space the preinstalled toolchains take (a hosted runner starts with about
13 GB free), prepares the host with `tests/setup-run-test-host.sh`,
installs sysbox-ce 0.7.1 (the `fuse3` package too, and it waits until
docker lists the `sysbox-runc` runtime), builds the launcher and hands
everything to `tests/run-all-suites.sh`, which pulls the relay, docker and
sysbox images from the image cache (see below) or builds them, and runs
every suite as the user and again as root. The images are built with the
classic builder (`DOCKER_BUILDKIT=0`): a hosted runner has 4 cores and
16 GB, and BuildKit's final export of a 9 GB image stalled there until the
runner was shut down. Hosted runners have no /dev/kvm, so the vm suite's
checks skip; those skips are approved. On a push to main a third job runs
first and fills the image cache.

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
2. Makes the images present (`scripts/ci/images relay docker`, plus
   `sysbox` when docker lists the `sysbox-runc` runtime: `./build` for
   each, or a pull from the image cache, see below), unless `--no-build`.
   If that fails, the run stops there and `summary.md` says so
   (tests/test_run_all_suites.sh RS8).
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
has just built the images; the checks that sourced the old bash launcher
and now live in the crate's Rust tests; the run-suite checks that drove
stand-in tools on PATH (a stub find, stat, dd, mkdir or od) or pinned the
bash launcher's own shell variables, which the Rust launcher never runs or
assigns; and the vm checks that need /dev/kvm, absent on GitHub-hosted
runners. Each line says why.

## Image cache

Every continuous integration run starts on a fresh hosted runner with an
empty docker cache, where building the docker and sysbox images takes
most of the 95 minutes the suites job used to take. So the runner reuses
images built earlier from the same inputs.

**What is cached.** The three images the suites need:
`llm-in-a-box-relay:latest`, `llm-in-a-box:docker` and
`llm-in-a-box:sysbox` (the vm image is not built in continuous
integration). Each is stored under a fingerprint: the sha256 of a list of
its inputs, which is the machine architecture, the build arguments, the
`./build` script, the Dockerfile, the `.dockerignore`, each base image by
digest (a tag such as `ubuntu:24.04` is looked up in its registry, so a
moved tag is a new fingerprint) and every file the Dockerfile's `COPY`
and `ADD` instructions copy in (path, executable bit, content; for a
symbolic link named as a source, its target). Changing any of them gives
a new fingerprint; changing anything else (the launcher, the tests, the
docs) does not (tests/test_ci_images.sh IC1, IC2, IC3, IC12).
`scripts/ci/images --inputs docker` prints the list and
`--fingerprint docker` its hash. An instruction the list cannot account
for (`COPY --from`, a URL, a variable, a `RUN` bind mount from the build
context or from another image) means no fingerprint, and the image is
built (IC4). Before any build with the cache configured, each base image
looked up by tag is pulled at the recorded digest, so the build starts
from the base the fingerprint names (IC5, IC7).

**Where.** The GitHub container registry, as the package
`ghcr.io/<owner>/<repository>-cache`, one tag per fingerprint
(`ci.yml` names it from the repository it runs in). The script uses it
only when `LBX_IMAGE_CACHE` names it, as the workflow does; local runs
build as before (IC10). Each image is about 8.5 GB uncompressed and about
3.2 GB as pushed; the registry's limits (10 GB per layer, a 10 minute
timeout per upload) are far from the largest layer, 3.6 GB uncompressed.
A `docker save` into the Actions cache would not fit: the docker and
sysbox images compress to about 6.6 GB together, so the 10 GB cache
budget of a repository could not hold the images of main and of a pull
request that changes them at the same time.

- **Pull requests** (the `suites` job, token with `packages: read`): the
  runner looks the fingerprint up, pulls the image by its digest, checks
  that the image's `lbx.ci-fingerprint` label is the fingerprint and that
  its repository digests include the digest it asked for, and tags it
  with the local name (IC6). On a miss, a registry error or a failed
  check it builds, and it never pushes (IC7). A pull request that changes
  an image input therefore builds that image, as before the cache.
- **Main** (the `images` job, on every push to main, the only job that
  pushes to the cache): on a miss it builds, adds the label and pushes
  (IC5); on a hit it does nothing (IC8). The `suites` job on main waits
  for it and then pulls. The pull request job's token only has
  `packages: read`, so as the workflow stands, only reviewed, merged code
  fills the cache. A branch of this repository could still edit the
  workflow in its own pull request to ask for `packages: write`; closing
  that needs the repository settings described below.

`build.log` shows the input list and each image's line: `image docker:
pulled sha256:...`, `built (<reason>)`, `built and pushed sha256:...` or
`cached sha256:...`. The run's output shows the `image` lines under
"building images" (tests/test_run_all_suites.sh RS8).

**How to invalidate.** Change an input and the fingerprint changes by
itself. To rebuild without changing anything, run the CI workflow by hand
(workflow_dispatch) on main with `fresh_images` checked, or set
`LBX_IMAGE_FRESH=1`: the images are built even on a hit, and on main the
new build replaces the cached one (IC9). The Dockerfile installs some
tools unpinned (the agents, yq, the Rust toolchain), so a cached image
keeps the versions of the day it was built until an input changes, the
`ubuntu:24.04` tag moves, or someone runs a fresh build on main. Deleting
a package version in the registry's settings also works: the next run on
main builds and pushes again.

### Settings the cache needs

Operational guidance, not verified by a test:

- The first run of the `images` job creates the package
  `<repository>-cache` under the repository's owner. In its settings,
  "Manage Actions access" must give this repository at least Read (Write
  for the push from main). Pull requests from forks run with a read-only
  token, so the package must be public for them to pull; without read
  access, runs build as before.
- To make "only main pushes" hold even against a pull request that edits
  the workflow: give this repository Read only, store a separate token
  that can write packages as a secret of a GitHub environment that only
  the main branch may use, and log in with that secret in the `images`
  job.
- Each new fingerprint stores another three images of about 3.2 GB each
  as pushed; old versions of the package can be deleted at any time (a
  later run just builds).

## Where results appear

- The workflow's job summary (`summary.md`): a table per suite and pass,
  the judged totals, and every failed or unapproved-skipped check by name.
- `test-logs/junit.xml`: one test case per judged check (RS4).
- The `test-logs` artifact: every pass's full log, `build.log`,
  `summary.md`, `junit.xml`, and the raw `results.tsv`/`judged.tsv`.

