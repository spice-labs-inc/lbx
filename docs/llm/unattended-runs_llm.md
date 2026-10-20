| `invalid net policy file` | RUN1, RUN57 |# Unattended runs (`lbx --run`) — LLM reference

Human copy: `docs/unattended-runs.md`. Decision records:
`docs/adr/012-unattended-runs-stricter-mode.md` (it points here for the
full refusal list) and
`docs/adr/014-unattended-runs-socket-directory-and-no-network.md`
(`--socket-dir`, `--no-network`, `--apparmor-profile`; it points here for
the authoritative socket-directory rules). Test files: `tests/test_llm_in_a_box_run.sh` (RUN*,
REG*; real launcher, fake docker `tests/fake-docker-run.sh`) and
`tests/verify-run-unattended.sh` (VRUN*; real docker, built images).
Below, a bare `RUNn`/`REGn` is in `tests/test_llm_in_a_box_run.sh` and a
bare `VRUNn` is in `tests/verify-run-unattended.sh`.

## Domain

- **unattended run**: one invocation of `lbx --run`.
- **run box**: the container an unattended run creates; exists only while
  the run's command runs. Container name = run name.
- **box user**: account in the run box, host user name + host user id +
  host group id (entrypoint remap); the command runs as it via `gosu`.
- **data directory**: host directory from `--data`, mounted read-write at
  `/data`; the only host mount of the run box besides a socket directory.
- **run name**: `<name>` of the run; must be new on the host.
- **socket directory**: host directory from `--socket-dir`, mounted
  read-only at `/run/agent`; holds only Unix sockets the caller serves.
  The one deliberate exception to "no socket in the data directory".
- **no-network run**: an unattended run started with `--no-network`
  (instead of `--net-policy`): run box `--network none` (only `lo` in use; kernel fallback tunnel
  devices may be present, down and without an address), no relay, no
  run networks.

Security model statement — not a tested claim: a run box is narrower than
an interactive docker session, but llm-in-a-box is still host isolation,
not an adversarial sandbox (shared kernel, no user namespace).

Host: Linux only. A host without `setpriv --pdeathsig` (util-linux,
Linux-only; so any macOS or Windows host) is refused (RUN39). Operational guidance — not a tested
claim: the data-directory checks also rely on `/proc/self/mountinfo` and
GNU `find`, `stat` and `realpath`.

Interactive behavior, in the scenarios the baseline covers (docker and
sysbox create, create with a policy, with `GH_TOKEN` set, with `--ports`,
attach, start of a stopped session), is byte-identical to the launcher
before unattended runs except for two documented read-only label queries
(REG1, REG3, REG4; see "Interactive paths"). vm sessions, `--device`,
`--fuse`, `--publish` and `--vm-web-port` are not in that baseline.

Code: `lbx` functions `run_refuse`, `run_refusal_exit`, `run_data_checks`,
`run_launcher_dirs`, `run_socket_dir_checks`, `run_apparmor_checks`,
`run_validate`, `run_owns`, `run_report_leftovers`, `run_on_exit`,
`run_on_signal`, `run_on_timeout`, `run_timer`, `run_setup_failed`,
`run_unclaim`, `run_refusal_signal`, `run_claim_tool`, `run_claim_refuse`,
`run_main`, `run_print_deny_log`; `entrypoint.sh` branches
on `LBX_NO_INNER_DOCKER=1`.

## Grammar

```
lbx --run --runtime docker (--net-policy <file> | --no-network) --data <dir> --timeout <seconds> [--socket-dir <dir>] [--apparmor-profile] [--env NAME]... <name> -- <command> [args...]
```

- Exactly one of `--net-policy` and `--no-network`; checked right after
  parsing, before the configuration and the policy are read: both (either
  order; an empty `--net-policy ''` counts as given) -> `--no-network
  cannot be combined with --net-policy.`; neither -> `--run needs
  --net-policy with mode enforce or locked, or --no-network.` (RUN103).
- `--socket-dir <dir>`: at most once (the checks refuse a second), takes
  a value; `--no-network`, `--apparmor-profile`: no value (RUN103,
  RUN110: `--no-network --run` / `--apparmor-profile --run` followed by an
  unknown option is a 125 refusal, so the pre-scan does not skip the
  argument after them).

- Everything after the first `--` is the command vector, element for
  element, never re-parsed; `--run`, flags, `--`, empty strings, newlines
  inside it are plain arguments (RUN15; VRUN11).
- Pre-scan: before parsing, `lbx` scans arguments up to the first `--`
  for `--run`, skipping the value of each option that takes one
  (`--data --env --timeout --runtime --device --publish --vm-web-port
  --denied --net-policy --socket-dir`; RUN101: `--socket-dir --run`,
  before or after the name, with or without `--force`, stays interactive,
  same exit code and output as another value). If found: failure exit code becomes 125, INT,
  TERM, HUP and USR1 traps are installed, then an EXIT trap; until the run
  has claimed its name, an exit prints `lbx-run: status=refused code=125`
  (a refusal) or, after a signal, `lbx-run: status=signal code=<n>`
  (RUN83, RUN84). So an unknown option before `--run` is a refusal (RUN11); a
  literal `--run` as an option value leaves the invocation interactive:
  byte-identical to the launcher before unattended runs in the recorded
  baseline scenarios (RUN38), and never an unattended run (no status line,
  never 125, same result as another value) for every option that takes a
  value (RUN42).
- Without `--run`: `--` fails as `ERROR: Unknown option: --` + usage,
  exit 1; `--data`, `--env`, `--timeout` exit 1; nothing created or
  written (REG2). `--socket-dir`, `--no-network`, `--apparmor-profile`:
  `ERROR: --<flag> is only valid with --run.`, exit 1, nothing created or
  written, read-only docker calls only (RUN101 for the first two, RUN110
  for the third). Operational guidance — not a tested claim: `--socket-dir` with no value: `ERROR: --socket-dir
  requires a directory` + usage (exit 1, or 125 in a `--run` invocation;
  untested, like `--data`'s).

## Refusals (exit 125, nothing created, nothing written)

Every refusal: exit 125; reason on standard error; last standard error
line `lbx-run: status=refused code=125`; no status file written; an
existing status file is untouched (RUN22). Refusal checks snapshot the
whole fixture (state directory, HOME with the configuration directory,
data directory, working directory, policy directory) before and after and
allow only read-only docker calls (`image inspect`, `container inspect`,
`inspect`, `network inspect`, `ps`, `info`). Exception: the claim (rows
30-33) creates the state directory, `runs/` and `runs/<name>` when they
are missing (missing ancestors of the state directory too, which stay:
RUN94), and on a refusal removes those three it created only while they
are empty (RUN92, RUN96); another process's `.claim` or status file (rows 31, 33: RUN44,
RUN45, RUN53 check the planted entry, not a snapshot) or a concurrent
run's entry in `runs/` or `runs/<name>` (RUN88, RUN90) keeps them.

In launcher order. The fragment column quotes the launcher's messages.
The checks named in the test column assert the fragment in rows 2, 5,
7-11, 13, 14, 16, 18 ("reserved"), 19-21, 23, 24 (VRUN18), 27, 29 (fewer
bytes only), 30 (the message, or for the parent and `runs/` its absence), 31-33 (the `runs/<name>` or `netlogs/<name>` path for the reuse
refusals); for the other rows they pin the refusal itself.

| # | Condition | Message fragment | Test |
|---|---|---|---|
| 1 | unknown option; option missing its value | `Unknown option` / `requires ...` + usage | RUN11 (unknown option before `--run`), RUN9 (`--timeout` without value) |
| 2 | `--help`/`-h`/`-?` with `--run`, either order | `--help cannot be combined with --run.` | RUN29 (`--help`), RUN81 (`-h`, `-?`, with the message) |
| 3 | `--run` with `--destroy --stop --shutdown --force --list --denied --print-images --ports --publish --vm-web-port --device --fuse`, either order | `<flag> cannot be combined with --run.` | RUN10 (nothing listed, printed, stopped or destroyed; standard output empty) |
| 4 | no `--`, or nothing after `--` | `--run needs a command after --` | RUN6 |
| 5 | configuration file unusable (for example itself a symbolic link) | `cannot read config` | RUN3 |
| 7 | policy path not a regular file (a directory, a named pipe: never opened) | `net policy file not found` | RUN57 |
| 8 | policy unreadable or not valid JSON (the interactive validator refuses it, before the run's own readability check) | `invalid net policy file` | RUN1, RUN57 |
| 8a | policy `idle_timeout_seconds` present and not a JSON integer 30-3600 (string, fraction, `1e3`, `true`, `null`, list, out of range); same shared validator, so interactive sessions exit 1 the same way (RUN112) | `idle_timeout_seconds must be a whole number from 30 to 3600` + `invalid net policy file` | RUN111 (property: random in-range and both ends run; random out-of-range and 29/3601/0/-1 refused) |
| 9 | run name empty | `<session_name> is required` + usage | RUN7, RUN58 |
| 10 | run name starting with `-` (parsed as an option) | `Unknown option: -x` + usage | RUN7, RUN58 |
| 11 | run name invalid (`[A-Za-z0-9][A-Za-z0-9._-]*`) | `Invalid session name` | RUN7 (`../x`, `a/b`, non-English letters, `.hidden`, `a b`, `a:b`, random bad characters), RUN58 (`a/b`) |
| 12 | `--runtime` missing or not `docker` | `--run needs --runtime docker` | RUN2 |
| 13 | `--net-policy` missing | `--run needs --net-policy` | RUN1, RUN57 |
| 14 | policy mode not `enforce`/`locked` | `net policy mode must be enforce or locked` | RUN1 (`open` refused; `locked` runs), RUN57 |
| 15 | `--timeout` missing or repeated; not `^[1-9][0-9]{0,5}$`; > 604800 | `--run needs exactly one --timeout`, `--timeout must be a whole number of seconds from 1 to 604800` | RUN9 (`0 -1 08 1.5 5s ''` 604801, twenty nines; 604800 runs) |
| 16 | run name > 128 characters | `run name is longer than 128 characters.` | RUN7 (129 refused, 128 runs), RUN58; VRUN16 (128 works on real docker) |
| 17 | host user id 0 / group id 0 | `refuses host user id 0` / `group id 0` | RUN8 (`id` stub) |
| 18 | `--env` name invalid / reserved / duplicate / not set on host | `not a valid variable name` / `reserved` / `given twice` / `not set` | RUN24, RUN25, RUN74 |
| 19 | `--data` missing | `--run needs --data <directory>.` | RUN56 |
| 20 | data directory rules (next section) | rule phrase | RUN3, RUN40, RUN52; VRUN14 |
| 21 | no `docker` on `PATH` | `docker is not installed or not on PATH` | RUN59 |
| 22 | `setpriv --pdeathsig` unusable | `setpriv (util-linux) with --pdeathsig is needed` | RUN39 |
| 24 | container `<name>` or `llm-in-a-box-relay-<name>` exists (any kind: plain, session, legacy; docker also matches a container id prefix, VRUN18) | `a container named ... already exists` | RUN4 |
| 25 | network `llm-in-a-box-net-<name>` or `llm-in-a-box-relaynet-<name>` exists | `a network named ... already exists` | RUN4 |
| 26 | vm session `$LBX_STATE_DIR/sessions/<name>` exists | `a vm session named ... already exists` | RUN4 |
| 27 | `$LBX_STATE_DIR/netlogs/<name>` or `runs/<name>` exists | `run name <name> was used before: <path> already exists` | RUN4, RUN22, RUN70 (either one alone) |
| 28 | configured docker image (`image.docker`, default `llm-in-a-box:docker`) or `llm-in-a-box-relay:latest` not local; no legacy fallback, no pull | `image ... is not present locally` | RUN5 |
| 29 | 16 random bytes for the run identity not readable (`od` fails, or delivers fewer) | `could not read random bytes` for fewer bytes; a failing `od` stops `lbx` at once (errexit, pipefail) with only the status line | RUN60 |
| 30 | the state directory's missing parent not creatable, or runs/ missing and not creatable (its `mkdir` fails and it still does not exist), or `mkdir runs/<name>` fails with nothing of that name there | the first two: no message of its own (standard error holds only the status line), the state directory removed when this run created it (RUN96); the third: `could not create` (never "used before"), `runs/` and the state directory removed when this run's own `mkdir` created them and they are empty | RUN97 (parent), RUN80, RUN96 (runs/), RUN61, RUN88 (`runs/<name>`) |
| 31 | claim: `runs/<name>/.claim` exists (any kind) before or appears during the exclusive create | same "was used before" message naming `runs/<name>` | RUN37, RUN44, RUN45 |
| 32 | claim create fails with nothing in the way | `could not claim run name` (never "used before"); `runs/<name>`, and `runs/` and the state directory when this run's own `mkdir` created them, removed, each only while empty | RUN50, RUN88, RUN90, RUN92 |
| 33 | claim succeeds but `runs/<name>/status` exists (same-name run finished in between) | "was used before"; own `.claim` removed | RUN53 |

Added by `--no-network`, `--socket-dir` and `--apparmor-profile` (lettered,
so the row numbers above, which other text cites, stay):

| # | Place | Condition | Message fragment | Test |
|---|---|---|---|---|
| A | between rows 3 and 4 | `--no-network` together with `--net-policy` (either order, also `--net-policy ''`); before the configuration and the policy are read, so an invalid policy or an unusable configuration file yields this message, not theirs | `--no-network cannot be combined with --net-policy.` | RUN103 |
| B | row 13 | neither `--net-policy` nor `--no-network` | `--run needs --net-policy with mode enforce or locked, or --no-network.` (still contains row 13's fragment) | RUN103, RUN57 |
| C | after row 20 | socket-directory rules (next sections) | `socket directory <path> ...` + rule phrase | RUN99, RUN108 |
| D | after C | `--apparmor-profile` checks (section "AppArmor checks") | `--apparmor-profile: ...` + phrase | RUN110 (all four); VRUN29 (not enabled, not loaded, and on an unmediated kernel does not mediate) |

In a no-network run rows 7, 8, 8a, 13 and 14 do not apply (no policy:
RUN104), row 28 does not require the relay image (RUN104),
and rows 24, 25 and 27 still refuse a container named like the relay, a
network of either run network name and an existing `netlogs/<name>`
(RUN105), so run names stay unique across both kinds of run.

The run's own readability and JSON checks (`net policy file ... is not
readable`, `... is not valid JSON`) are never reached: row 8 refuses those
policies first (RUN57: an unreadable policy gets row 8's message).

The shipped-policy copy into `~/.config/llm_in_a_box/` is skipped when
`--run` is present: a refusal writes nothing there (every refusal check's
HOME snapshot), and a successful run leaves HOME unchanged (RUN68, whose
control shows `lbx --list` in the same fixture does copy the three
policies).

## Data-directory rules (`run_data_checks`)

`d = realpath -e <dir>`. Refused (phrase) when:

- missing ("does not exist"), not a directory ("not a directory"), owner
  not the host user id ("not owned by") — RUN3;
- `d` is HOME ("home directory"), an ancestor of HOME ("ancestor of the
  home directory"), inside HOME ("inside the home directory") — RUN3;
- `d` equals, contains or is inside (both directions, `path_within`):
  the state directory; the configuration directory
  (`realpath -m $(dirname $LBX_CONFIG)`, plus
  `~/.config/llm_in_a_box` if it exists); the policy file's directory;
  the vm artifact directory `<cwd>/vms_and_docker_from_llm_box` (the box's
  Docker store image) if it
  exists — phrases "state directory", "configuration directory", "policy
  file", "vm artifact directory" — RUN3 (each target, each direction;
  `LBX_CONFIG` outside HOME; reached through a directory link). The
  overlap checks precede the inside-HOME check, so a configuration
  directory under HOME is named as such;
- any entry below `d` cannot be read (a `find` pass with any error
  output) — "cannot be read" — RUN3 (mode-000 subdirectory);
- `.git` at any depth — ".git" — RUN3 (top level, three levels down);
- a symbolic link at any depth — "symbolic link" — RUN3;
- an entry not owned by the host user id — "owned by another user" —
  RUN3 (root-made fixture);
- a socket / named pipe / block or character device — "socket", "named
  pipe", "device file" — RUN3 (socket and device made by
  `tests/setup-run-test-host.sh`);
- a regular file with `link count > names inside d`, keyed by
  `%D:%i` over `find -type f -links +1` — "hard link outside" — RUN3
  (one inside + one outside; two inside + one outside; hard link to the
  net policy file). Control: two names both inside run (RUN3). A
  link-count scan with any error output or non-zero exit refuses as
  "cannot be read" (RUN3, `find` stand-in, message+exit and exit only);
- a directory at any depth whose `stat %d` differs from `d`'s — "mount
  point" (RUN40, `stat` stand-in, depths 1-3, mountinfo lists nothing).
  Device-number scan with any error output or non-zero exit (or `d`'s
  own `stat` failing) — "cannot be read" (RUN52: message+exit, exit only,
  message only);
- a `/proc/self/mountinfo` mount point inside `d` — "mount point"
  (VRUN14, real bind mount).

## Socket-directory rules (`run_socket_dir_checks`)

Authoritative list (ADR 014 points here). Runs in `run_validate` after
`run_data_checks`, only with `--socket-dir`; every refusal is a row C
refusal (125, nothing created or written) whose message starts `socket
directory` and contains the phrase. RUN99 breaks each rule on its own,
requires the phrase and "socket directory", and compares a stat snapshot
of the socket directory (owner, mode, device, inode, nanosecond times of
it and each entry) before and after. Order (the launcher's; a case
pins only these parts of it: HOME is refused as "is the home directory"
and by no other home rule, and a directory under
`~/.config/llm_in_a_box` is refused as the configuration directory, not
as inside HOME; every other order is untested):

1. `--socket-dir` given twice: "more than once".
2. The given value (a non-empty value first loses trailing `/` and `/.`,
   so `link/` and `link/.` are still links) is a symbolic link:
   "symbolic link" (RUN99: `link`, `link/`, `link/.`).
3. Missing: "does not exist"; not a directory: "not a directory".
4. `d = realpath -e` (kept whole when it ends in a newline; not tested); `d` holds
   `,`, `"` or a newline: "cannot be mounted" (RUN99: each character,
   and a path whose resolved form alone holds `,`).
5. `stat -c '%u %a' d`: owner not the host user id: "not owned by"
   (root-owned fixture); mode & 022: "writable by group or others"
   (0720, 0702; controls 0750, 0755 run).
6. `d` equals, contains or is inside the data directory: "overlaps the
   data directory".
7. `d` is HOME: "is the home directory" (and no other home phrase); an
   ancestor of HOME: "ancestor of the home directory".
8. `d` equals, contains or is inside a launcher directory
   (`run_launcher_dirs`: state directory, configuration directory in both
   forms, the policy file's directory (empty in a no-network run), vm
   artifact directory): the data-directory phrases (each target, each
   direction; the shipped-policy directory with `LBX_CONFIG` moved
   outside HOME).
9. `d` inside HOME: "inside the home directory" (after 8, so a
   directory under `~/.config/llm_in_a_box` is named as the configuration
   directory).
10. `d` equals or is an ancestor of `$XDG_RUNTIME_DIR` (when set) or
    `/run/user/<uid>` (when it exists): "user runtime directory"
    (both forms; control: a directory inside `$XDG_RUNTIME_DIR` runs).
11. `d` not readable or not searchable (`-r`, `-x`), or `find d
    -mindepth 1 -maxdepth 1 -printf ''` fails or writes an error (that `find` branch is not tested):
    "cannot be read" (RUN99: modes 0300 and 0600).
12. An entry `! -type s`: "not a socket" (regular file, directory,
    symbolic link, named pipe, device fixture).
13. A socket `! -uid <uid>`: "owned by another user" (root-owned socket
    fixture).
14. A socket whose `%d:%i` equals that of an existing credential socket:
    `$SSH_AUTH_SOCK`; the docker client's socket (`DOCKER_HOST` path when
    `unix://...`, else `/var/run/docker.sock`); `$XDG_RUNTIME_DIR/docker.sock`;
    `$XDG_RUNTIME_DIR/bus`: "credential socket" (RUN99: the first two by
    path and as hard links, the runtime-directory two as hard links; the
    `/var/run/docker.sock` default has no case).

Sets `RUN_SOCKET_ABS = d`. Accepted (RUN99 controls): empty mode-0700
directory; two user sockets; modes 0750 and 0755; a directory inside
`$XDG_RUNTIME_DIR`. Only direct entries are checked (a subdirectory is
refused). A socket in the data directory is still refused with a socket
directory given (RUN108: "contains a socket").

## AppArmor checks (`run_apparmor_checks`)

Runs in `run_validate` after the socket-directory checks, only with
`--apparmor-profile`. `sys = ${LBX_SYSFS:-/sys}` (test seam, honored
outside tests too). Needed profile: `llm-in-a-box-run`, or
`llm-in-a-box-run-no-network` for `--no-network`. Row D refusals, in this
order (RUN110; each order pinned by a case):

1. `sys/module/apparmor/parameters/enabled` not `Y` (missing, `N`):
   "AppArmor is not enabled".
2. `sys/kernel/security/apparmor/features/network/af_unix` not `yes`
   (missing, `no`): "does not mediate Unix sockets" (the profile would
   load but its unix rules and pathname socket checks would not be
   enforced).
3. No directory under `sys/kernel/security/apparmor/policy/profiles/`
   whose `name` file reads exactly the needed profile (directory names
   unused; `llm-in-a-box-run-x` does not count; only the needed profile
   matters): "is not loaded" (message includes the `apparmor_parser -r`
   command).
4. That profile's `mode` file not `enforce` (for example `complain`):
   "not in enforce mode".

Controls (RUN110): both profiles loaded, relay and no-network runs
execute; a run with only its own profile loaded, or with the other
profile in complain mode, executes. Real host (VRUN29): with the profiles
loaded on a kernel that mediates Unix sockets, a run executes (asserted, no real-docker evidence yet: see known limits); copies of
the host's entries without `llm-in-a-box-run`, or with `enabled` `N`,
refuse with nothing on docker; on a kernel without the feature the real
files refuse with "does not mediate Unix sockets" (the copies then carry
the feature file as `yes`); a third copy that keeps every profile (feature
file as the other two) lets the run execute under `llm-in-a-box-run
(enforce)`, the positive control for the two refusals. `lbx` never runs
`apparmor_parser` (RUN109).

## Run-name claim

`mkdir -p <parent of the state dir>` when that parent is missing (the
ancestors it creates are never owned and stay: RUN93, RUN94); `mkdir
<state dir>` and `mkdir runs` (each owned only when that mkdir succeeds;
an existing or concurrently created directory is not owned, RUN91; a
runs/ that still does not exist: refused with only the status line,
RUN80, the owned state directory removed, RUN96); plain `mkdir runs/<name>` (fails with nothing there:
refused `could not create`, owned runs/ and state directory removed while
empty; RUN61, RUN88); refuse if `.claim` exists (`-e` or `-L`); `runs/<name>/.claim` is
opened once with `O_CREAT|O_EXCL` (fails on any existing entry, never
follows a link, never opens a named pipe)|O_EXCL)`: fails on any existing entry, never follows a
link, never opens a named pipe); refuse if `status` exists. Exactly one
of two concurrent same-name runs proceeds (RUN37, repeated rounds behind
a barrier at the last check). `.claim` is removed by cleanup after the
status file is written; a finished run's `runs/<name>` holds exactly
`status` (RUN53: exit 0, exit 3, setup failure, timeout, SIGTERM).
`runs/<name>` is never mounted (RUN12: no docker call mentions
`state/runs`). A signal during the claim is recorded and acted on once
the claim step is done: `.claim`, `runs/<name>`, and the owned `runs/`
and state directory are removed (each directory only while empty), exit
128+n, `status=signal code=<n>`, no status file; a `runs/` that already
existed or held other entries is untouched (RUN84, also for a signal
right after `mkdir runs/<name>`, before `.claim`; RUN91, RUN92).

## Resource sequence and argument vectors

Order (RUN12): internal network, egress network, relay `run -d`, relay
health `exec`, relay address `inspect`, run box `run -d`, readiness
`exec` polling, exactly one command `exec`; then cleanup.

Identity: `RUN_ID` = 16 bytes of `/dev/urandom` as 32 lowercase
hexadecimal digits, drawn after the checks, before the claim; label
`llm-in-a-box.run-id=$RUN_ID` on both networks, the relay and the run box
(same value; RUN12); differs per run (RUN48). Unreadable bytes: refusal
row 29 (RUN60).

Networks (RUN12):

```
docker network create --internal -o com.docker.network.bridge.inhibit_ipv4=true llm-in-a-box-net-<name> --label llm-in-a-box.run-id=<id>
docker network create llm-in-a-box-relaynet-<name> --label llm-in-a-box.run-id=<id>
```

`inhibit_ipv4=true` keeps the host off the internal network's gateway
address; without it the box reaches host services (VRUN4 control: a plain
`--internal` network does reach a host listener through its gateway; the
run box does not).

Relay `docker run -d` — elements RUN12 asserts: `--pull never`, `--name
llm-in-a-box-relay-<name>`, `--cap-drop ALL`, `--security-opt
no-new-privileges`, `--read-only`, run-id label, `-v
<realpath policy>:/policy.json:ro` (absolute even when `--net-policy` is
relative), `-v <realpath netlogs/<name>>:/log`, and `-e` values exactly
`LLMBOX_POLICY=/policy.json`, `LLMBOX_DENY_LOG=/log/deny.log`, and the
ten client proxy variables empty (`HTTP_PROXY http_proxy HTTPS_PROXY
https_proxy NO_PROXY no_proxy FTP_PROXY ftp_proxy ALL_PROXY all_proxy`,
`RUN_CLIENT_PROXY_VARS`). Elements RUN67 asserts: `--user <host user
id>:<host group id>`, `--tmpfs /tmp`, and `--network` exactly the internal
and the egress network. Real docker (VRUN13): `Privileged=false`,
`CapDrop=[ALL]`, `ReadonlyRootfs=true`, no-new-privileges, absolute policy
mount source for a relative `--net-policy`.

Relay health: `docker exec llm-in-a-box-relay-<name> python3 -c <connect
127.0.0.1:3128>`, up to 10 attempts, 1 s apart (RUN63: exactly 10 probes
with 1 s waits, then setup failure `the relay ... did not start
listening`, no run box; an answer on the 10th attempt proceeds; RUN16
"relay health"). Relay address: `docker inspect -f '{{(index
.NetworkSettings.Networks "<internal net>").IPAddress}}'`; the proxies use
it numerically (RUN12 with `FAKE_RELAY_IP`; VRUN9 sees
`http://<digits>:3128`). An empty answer is a setup failure `could not
read the relay's address`; a failing query stops `lbx` at once (errexit)
into the same setup failure without that message; either way no run box,
relay then both networks removed (RUN62).

Run box `docker run -d` — elements RUN12 asserts: `--rm`, `--pull never`,
`--name <name>`, no `--hostname`/`-h` equal to the name, `--cap-drop ALL`,
`--cap-add` exactly `CHOWN DAC_OVERRIDE SETGID SETUID` (`RUN_CAPS`),
`--security-opt` exactly `no-new-privileges`, `--dns 127.0.0.1`,
`--sysctl net.ipv6.conf.all.disable_ipv6=1`, `--network` exactly the
internal network (and no later `network connect`), labels
`llm-in-a-box.runtime=docker`, `llm-in-a-box.mode=run`, run-id; `-v`
exactly `<realpath data>:/data`; every `-e` name within `HOST_USER
HOST_UID HOST_GID LBX_NO_INNER_DOCKER HTTP_PROXY HTTPS_PROXY http_proxy
https_proxy NO_PROXY no_proxy JAVA_TOOL_OPTIONS ALL_PROXY all_proxy
FTP_PROXY ftp_proxy`; `LBX_NO_INNER_DOCKER=1`; `HTTP_PROXY HTTPS_PROXY
http_proxy https_proxy = http://<relay ip>:3128`; exactly one each of
`ALL_PROXY= all_proxy= FTP_PROXY= ftp_proxy=` (empty); no
`--privileged*`, `--cap-add=*`, `--security-opt=*`, `--mount*`,
`--volume*`, `--env*`, `--env-file*`, `--net`/`--net=*`/`--network=*`,
`--volumes-from*`, `--pid*`, `--ipc*`, `--userns*`, `--device*`; image
then `sleep <lifetime>`. Elements RUN67 asserts: exactly one label
`llm-in-a-box.user=<the image's Config.User>` (`claude` when the image
reports none); exactly one each of `NO_PROXY=localhost,127.0.0.1` and
`no_proxy=localhost,127.0.0.1`; exactly one
`JAVA_TOOL_OPTIONS=-Dhttp.proxyHost=<relay ip> -Dhttp.proxyPort=3128
-Dhttps.proxyHost=<relay ip> -Dhttps.proxyPort=3128
-Dhttp.nonProxyHosts=localhost|127.0.0.1` (one value, shown wrapped).

Additions to the run box `docker run` only (no other call; RUN98,
RUN109):

- `--socket-dir`: exactly one `--mount
  type=bind,source=<realpath dir>,target=/run/agent,readonly`; `-v` stays
  exactly the data directory; the relay has no `--mount`; no other call
  names the directory (given or resolved); vector minus the `--mount`
  pair, readiness exec, command exec and standard error equal a run
  without it (RUN98, also relative path, linked parent, names with
  space `$ ' = :` leading `-` and non-English letters). Mount failure at
  `docker run` -> `status=setup-failed code=125` (RUN100, `FAKE_FAIL_ON`
  on the `--mount` value).
- `--apparmor-profile`: `--security-opt apparmor=llm-in-a-box-run` (no-network:
  `apparmor=llm-in-a-box-run-no-network`) right after `--security-opt
  no-new-privileges`; relay keeps exactly `no-new-privileges`; vector
  minus the pair equals the run without the option, for relay,
  no-network and no-network with `--socket-dir` (RUN109).

No-network run (RUN104): order = run box `run -d`, readiness `exec`,
exactly one command `exec`, cleanup; no `network create`, no relay `run`,
health `exec`, `rm` or address query, no `image inspect` of the relay
image (the refusal-stage `container inspect` of `llm-in-a-box-relay-<name>`
stays). Run box vector: the one above, with these differences only (RUN104:
the whole vector equals the reference relay run's once the `--network`
pair and the `-e` pairs of the ten proxy variables and
`JAVA_TOOL_OPTIONS` are left out of both, `run104_core`): `--network none` and no
other network form; `-e` exactly one each of `HTTP_PROXY= http_proxy=
HTTPS_PROXY= https_proxy= NO_PROXY= no_proxy= FTP_PROXY= ftp_proxy=
ALL_PROXY= all_proxy=` (all empty; `RUN_CLIENT_PROXY_VARS`); no
`JAVA_TOOL_OPTIONS`; keeps `--dns 127.0.0.1`, the IPv6 sysctl, `--rm`,
`--pull never`, `--cap-drop ALL` + `RUN_CAPS`, `--security-opt` exactly
`no-new-privileges`, the three labels, `-v` exactly the data directory,
`LBX_NO_INNER_DOCKER=1`, `sleep <lifetime>`, no hostname. No
`netlogs/<name>`, no deny-log line; standard error = a relay run's minus
the deny-log line and the empty line before it (RUN104, with the relay
image absent too). With `--socket-dir`:
`--network none` and the one `--mount` together (RUN106).

Real docker, no-network (VRUN23): `/sys/class/net` `lo` plus at most
the kernel fallback tunnel devices `tunl0`, `ip_vti0`, `ip6_vti0`,
`sit0`, `ip6tnl0`, `gre0`, `gretap0`, `erspan0`, `ip6gre0` (created in
every new netns when their drivers are loaded and
`net.core.fb_tunnels_only_for_init_net` is 0; docker cannot drop them),
each down (no IFF_UP) with no IPv4 address (SIOCGIFADDR) and no IPv6
address (`/proc/net/if_inet6`); `lo` no IPv6 address; only IPv4 local address 127.0.0.1
(`/proc/net/fib_trie`); control: the same rule refuses the interfaces
of a container on a user-defined network; per-part controls
(`vrun23_rule_case`, alpine `--network none --cap-add NET_ADMIN` with a
veth pair renamed to two listed names, probe joined as the box user):
accepted down and address-less, refused with its own reason when up,
with an IPv4 or IPv6 address, renamed to an unlisted name, with an IPv6
address on `lo`, with a second IPv4 address on `lo`;
`/proc/net/route` no IPv4 route; blocked: 1.1.1.1:443, default bridge gateway
and host address on a host listener's port, 169.254.169.254:80,
2606:4700:4700::1111:443, `example.com` via resolv.conf and via
127.0.0.11, a host abstract-namespace socket; reached: a 127.0.0.1
listener in the box (same connect function); `CapBnd` measured,
`NoNewPrivs` 1; host view `.HostConfig.NetworkMode` = `none`, networks
only `none`, no relay container or run network; afterwards exit 0,
`status=exited code=0`, no `netlogs/<name>`, no deny-log line, nothing
left; controls: alpine on the default bridge reaches the host listener
and 1.1.1.1, `--network host` reaches the abstract socket, the probe on a
user-defined network reaches the public address, the name and 127.0.0.11.
With `--socket-dir` too (VRUN24): token back through
`/run/agent/echo.sock`, 1.1.1.1:443 and `example.com` fail in the same
run (control: a plain container on the default bridge reaches both).

Real docker, socket directory: VRUN20 (mode-0700 directory, path with a
space and `$`: token echoed; the server's `SO_PEERCRED` = host user id;
`/run/agent` owner, group, mode = the host directory's; `id -u -g` = host
user's; exit 0, nothing left); VRUN21 (as the box user `touch`, `mkdir`,
`rm`, `mv`, `ln -s`, `chmod 777 /run/agent`, binding a new socket fail;
as root via `docker exec -u 0` removing the socket and creating a file
fail; the command then connects again; host directory entries (names,
types, inodes, modes) unchanged and the server answers; unchanged after a
timeout too); VRUN22 (server socket removed and recreated mid-run, new
inode: connect through `/run/agent` works; control: a plain container
with only the socket file bind-mounted connects before and fails after).

Real docker, AppArmor, only on a kernel whose AppArmor mediates Unix
sockets (else approved skips, `tests/approved-skips.txt`; what follows is what the checks assert, with no real-docker evidence until they pass on such a kernel): VRUN25
(`/proc/self/attr/current` = `llm-in-a-box-run (enforce)`; host user's
ids; token through `/run/agent`; create, write, rename, read, remove in
`/data`, `/tmp`, `/var/tmp`, `/dev/shm`, home; `node` in `/data`; git in
`/tmp`; relay request to an allowed host answers; socket directory under
`/srv/lbx-test`, a host path no rule matches); VRUN26 (root in the box
cannot create in `/opt`, `/usr/local`, `/etc`, control without the
profile can; plain `docker run` under the profile: a host socket from an
unmatched host path is denied at `/srv/ext` and reached at `/tmp/ext`, a
host socket from under `/tmp` is denied at `/srv/ext`, the first two also
under the no-network profile; root under the no-network profile cannot
create `/opt/lbx-aa`; without the profile all connect; a socket the host
creates in the data directory mid-run is reached: the documented limit);
VRUN27 (abstract socket of a docker-default helper joined with
`--network container:<run box>` not reached from an unbound client nor
from a client bound to a `/tmp` path, and under the no-network profile
from an unbound client; an abstract socket served inside the run box is
reached; control without the profile reaches the helper both ways);
VRUN28 (`llm-in-a-box-run-no-network (enforce)`; IPv4 and IPv6 socket
creation fail, so no loopback listener or connection; token through
`/run/agent`; control without the profile reaches its loopback listener).

Lifetime = timeout + readiness maximum + 60 (RUN12 with the seam; RUN28);
default readiness maximum 60, so `sleep <timeout + 120>` (RUN31: 150 for
`--timeout 30`).

Real docker, run box (VRUN2, as test user `lbxtest`, user id 2345, group
id 100 which collides with an image group): `CapBnd` = mask of the four
capabilities, `CapEff` = 0, `NoNewPrivs: 1`, `Seccomp: 2`, AppArmor
`docker-default (enforce)` (host AppArmor must be enabled, else FAIL), no
`/var/run/docker.sock`, not in group docker, no `/etc/sudoers.d/agent`,
`sudo -l -n` empty, `sudo -n true` and `su` fail, `docker info` fails,
`id` = test user's ids; host view `Privileged=false`, `CapDrop=[ALL]`,
`CapAdd` = the four.

Network wall on real docker (VRUN4, with controls): relay port reachable
by numeric address; relay name resolves via `getent` and via 127.0.0.11;
IPv6 disabled; blocked: public name via resolv.conf and via 127.0.0.11,
1.1.1.1:443, the run network's first address on a host listener's port,
169.254.169.254:80, a public IPv6 address (2606:4700:4700::1111:443); not checked: link-local IPv6 and the interface's own IPv6 setting (known limit). VRUN5: allowed host answers through
the relay; `example.com` fails and appears in the kept deny log.

Client proxy configuration (VRUN6): with `DOCKER_CONFIG` holding
`proxies.default.allProxy` and `ftpProxy` = a sentinel URL with user and
password, neither the run box's nor the relay's `.Config.Env` contains
it (control: a plain alpine container created with that configuration
does).

## Readiness and entrypoint (`LBX_NO_INNER_DOCKER=1`)

Entrypoint changes, only when `LBX_NO_INNER_DOCKER=1` (set only on the
run box's `docker run`, RUN12; the interactive creates in the baseline
(docker, docker with a policy, sysbox, with `GH_TOKEN`, with `--ports`)
never set it: REG1 requires their argument vectors to equal the
pre-change baseline, which has no such variable):

- box user removed from group `docker` (`gpasswd -d`) and
  `/etc/sudoers.d/agent` deleted instead of adding docker membership
  (VRUN2);
- dockerd start and its 30-second wait skipped (VRUN10: no dockerd
  process, no socket, no `/var/log/dockerd.log`, with controls);
- `touch /tmp/.run-ready` immediately before the final `exec gosu`.

`lbx` polls `docker exec <name> test -f /tmp/.run-ready` once a second
until the readiness maximum; the command exec comes after (RUN12). At
command start HOME is owned by and writable for the box user and
`HTTPS_PROXY` names the relay (VRUN9). Never ready: setup failure with
no command exec, 55-70 s after start with the default maximum (RUN33).

`LBX_RUN_READY_SECONDS`: test-only seam for the readiness maximum
(positive integer, else 60: empty, `0`, `-5`, `abc` give lifetime
timeout + 120, RUN77); it also enters the lifetime formula (RUN12, RUN28
use it; RUN31 and RUN33 run without it). Known limit: honored outside
tests too, with no upper bound (RUN77: 1000000 gives `sleep <timeout +
1000060>`).

## Command execution, timer, signals

```
setpriv --pdeathsig KILL docker exec -i -w /data [-e NAME]... <name> gosu <host user name> <command...>
```

RUN12: exactly one such exec; `-i`, no `-t`/`-it`, `-w /data`, container
name right before `gosu`, then the host user name, then the vector.
Runs in the background with standard input handed over (`exec 3<&0`,
`<&3 &`) and `wait`; standard input reaches it unchanged (RUN32: 64 KiB;
VRUN3: 1 MiB checksum). Standard output of `lbx` = command's standard
output only (RUN13 byte-exact; VRUN1). `lbx` lines on standard error are
each preceded by a newline (RUN30).

Timer: `exec {fd}> >(run_timer $$)` started with the command exec; waits
`read -t <timeout>` on a pipe only `lbx` holds; on expiry sends SIGUSR1
to `lbx` if `/proc/<self>/stat` still names it as parent; if `lbx` dies
the pipe closes and the timer exits silently. Timeout = 124,
`status=timeout` (RUN17 part 1, RUN28); the command is stopped inside the
box, not only the local client (VRUN7: `late` never written).

SIGKILL of `lbx`: the exec client dies with it (`setpriv --pdeathsig
KILL`), the timer ends; a pipe reading `lbx`'s output sees end of input
within 5 s and no process with `lbx`'s command line remains (RUN17 part
2); on real docker no timer or exec client of the killed run remains, the
run box removes itself within lifetime + 30 s (VRUN15); right after the
kill `runs/<name>` holds `.claim` and no status file, and the relay and
both networks (internal and egress) remain (VRUN17); `docker rm -f <name>
llm-in-a-box-relay-<name>` plus `docker network rm llm-in-a-box-net-<name>
llm-in-a-box-relaynet-<name>` clean up (VRUN15, VRUN17); guidance, not
tested: a no-network run leaves only the self-removing run box and
`.claim` (no relay, no networks). Without
`setpriv --pdeathsig` the run is refused (RUN39).

Traps from the moment the pre-scan sees `--run` until the claim is done
(`run_refusal_signal`): INT 130, TERM 143, HUP 129, USR1 138 (no timer
exists yet, so USR1 counts as an outside signal); the run ends with that
code and `lbx-run: status=signal code=<n>` as the last standard error
line, creates no docker resource and writes no status file (RUN83: during
the checks, snapshot unchanged; RUN84: during the claim, the claim's own
entries removed). During the claim a signal is recorded and acted on when
the claim step ends; the claim tools (`mkdir -p` of missing ancestors,
`mkdir <state dir>`, `mkdir runs`, `mkdir runs/<name>`, `dd` of `.claim`)
run with these signals ignored, so a
signal to the whole process group cannot stop them after their create
(RUN85 for `runs/<name>` and `.claim`; RUN89 for `runs/` and SIGHUP,
SIGUSR1; RUN95 for the state directory and its ancestors). During the claim the
first signal decides and a later one changes nothing; during the checks
two signals give exactly one status line whose code is the exit code
(RUN86). Entries a failed claim already removed are not removed again,
and a failed clean-up of the claim does not cut the refusal short (RUN87,
RUN88, RUN90). With a signal recorded, a claim refusal prints no message
of its own; the run ends as the signal.
The few statements between the end of the claim and the run's own
signal traps are under the known limits. Traps after the claim: INT 130, TERM
143, HUP 129, USR1 124; each
handler first ignores INT TERM HUP USR1, records status, exits; the EXIT
handler (`run_on_exit`) ignores them too, so a SIGTERM during cleanup
after the command exited on its own (3) or timed out (124) leaves the
outcome and the full removal intact (RUN79). SIGINT/SIGTERM/SIGHUP during
the command: exit within 10 s with 130/143/129, `status=signal`, full
cleanup (RUN18; VRUN8 on real docker: 143 within 15 s, command stopped in
the box). During setup: SIGTERM 143 (RUN18), SIGINT 130 and SIGHUP 129
with `status=signal`, SIGUSR1 124 with `status=timeout`; nothing further
created, what exists removed (RUN72). A second signal during cleanup does
not interrupt it and the first signal's outcome stands (RUN36 TERM then
TERM; RUN73 INT then INT, HUP then HUP, TERM then INT, TERM then HUP,
TERM then USR1). Known consequence: a docker daemon hanging during
cleanup is only escapable by SIGKILL.

## Outcome contract

Status file `$LBX_STATE_DIR/runs/<name>/status` (authoritative), one
line, written via `mktemp` in that directory + `mv -T -f` (a planted link
is replaced, never followed; RUN20); also the last standard error line
as `lbx-run: <outcome>` (informational; a status-shaped line from the
command does not change the file, RUN20).

```
status=<setup-failed|timeout|signal|exited> code=<n>[ cleanup=incomplete]
```

| Case | Exit | Outcome | Test |
|---|---|---|---|
| refusal | 125 | none written; standard error `status=refused code=125` | every refusal check |
| signal before the run has claimed its name (checks or claim): SIGINT / SIGTERM / SIGHUP / SIGUSR1 | 130 / 143 / 129 / 138 | none written; standard error `status=signal code=<n>`; the claim's own `.claim`, `runs/<name>`, `runs/`, state directory removed, each directory only while empty | RUN83, RUN84, RUN85, RUN86, RUN87, RUN92, RUN94, RUN95 |
| failure after first resource (internal network, egress network, relay, relay health, relay address, run box, readiness) | 125 | `status=setup-failed code=125` | RUN16 (each step but the relay address), RUN62 (relay address), RUN63 (relay health), RUN33 |
| timeout | 124 | `status=timeout code=124` | RUN17, RUN28; VRUN7 |
| SIGINT / SIGTERM / SIGHUP | 130 / 143 / 129 | `status=signal code=<n>` | RUN18, RUN36, RUN72, RUN73; VRUN8 |
| SIGUSR1 (the timer's signal) during setup | 124 | `status=timeout code=124` | RUN72 |
| command ended | its code (0-255, 124/125/129/130/143 included, unchanged) | `status=exited code=<n>` | RUN14; VRUN1, VRUN16 |
| cleanup left something | 125 if `<n>`=0, else `<n>` | the above + ` cleanup=incomplete` | RUN55, RUN64, RUN65, RUN66 |

Deny log `$LBX_STATE_DIR/netlogs/<name>/deny.log`: fresh per run
(`netlogs/<name>` must not exist before), kept after cleanup (RUN20). The
line `lbx-run: deny-log=<absolute path>` precedes the status line exactly
when this run created `netlogs/<name>` (after both networks exist)
(RUN16, RUN20, RUN62). Callers compute the path, never parse it, and open
it with no link following (guidance). A no-network run creates no
`netlogs/<name>` and prints no deny-log line (RUN104; VRUN23); `lbx
--denied <name>` then prints `No deny log for run '<name>'.`, exit 0,
read-only calls only (RUN107). No status value, exit code or standard
error line is added by `--socket-dir` or `--no-network` (RUN98, RUN104,
RUN105), nor by `--apparmor-profile` (RUN109: standard error equal to the
same run without the option, for a relay run, a no-network run and a
no-network run with `--socket-dir`).

The relay paragraphs below (deny lines, idle timeout, connection cap,
request time limit) do not apply to a no-network run, which has no relay
(RUN104).

Relay deny line grammar (`tests/test_relay_resolution.sh`, RES* checks
mapped in "Tests"):
`<UTC time> DENY <src> host=<host> reason=<token>[ addr=<address>| sni=<name>]`;
reason and addr are one token each (RES11); `sni` is client-chosen text
(control characters become `?`, spaces possible; not checked). Reasons:
`ip-literal`, `blocked`, `not-allowed`, `bad-target`, `unsupported-request`
(all 403; RES12); `too-many-connections` with `host=-` (503, request
unread, connection closed; RES19); `request-timeout` with `host=-` (408, then
close: no complete request head within the limit; RES21, RES22, RES25); `resolve-failed:<EAI name>` (503; `EAI_AGAIN`
RES1/RES10, `EAI_NONAME` netwall T3b; one lookup per request, RES2 for the
timeout case; untested: the number form for an unnamed error, and
`resolve-failed:<errno name>` when getaddrinfo raises a plain OSError for
EAI_SYSTEM); `resolve-failed:bad-name` (503; internationalized domain name
encoding refused: empty label, label > 63 characters; RES17);
`resolve-failed:no-address` (503; unreachable with musl, untested);
`resolves-to-private addr=<first refused address as resolved>` (403;
RES3, RES5, RES6, RES7, RES9, RES10, netwall T3); `connect-failed:<errno
name>` (403; exact `ENETUNREACH` RES4/RES7; any code RES6/RES8; one token
RES11); `sni-mismatch sni=<name>` (sent after the 200; `sni=-` when no
server name is readable from the greeting within 5 s, e.g. not TLS; netwall T2, T2b; the `-` form and the
200 untested). Refused address:
`is_private|is_loopback|is_link_local|is_multicast|is_unspecified|
is_reserved|is_site_local|not is_global`, or in 100.64.0.0/10,
192.0.0.0/24, fec0::/10 (explicit, independent of the Python patch level;
RES3-RES5, RES7, RES8 seeded property over every refused range and public
control blocks); `::ffff:a.b.c.d` judged as IPv4 (RES6, RES8); any refused
address refuses the name (RES9). Idle timeout: policy
`idle_timeout_seconds` (lbx: 30-3600, RUN111/RUN112; default 300, not
measured exactly; relay accepts 1-3600, exits on anything else, RES15)
is one timer per tunnel (`pipe()`: one thread per direction on
non-blocking sockets, `select()` with a 1 s wake-up, a shared last-byte
time), restarted by any byte received or sent either way; the tunnel
closes (both sockets shut down) after that long with no byte either way
(RES13, RES18: upstream sees EOF after 3-6 s and the relay's client side
is closed); a one-way stream to a silent client keeps it open and the
client's direction toward the server is not ended while it runs (RES16); full duplex: 8 MiB
each way with an upstream that writes before it reads (RES20); a
direction reaching end of stream is half-closed toward the peer (not
checked on its own); also
the plain-HTTP upstream read (RES14); read at relay start (guidance);
docker sessions and runs hand the relay the same policy file (REG1,
RUN12; sysbox and vm session relays not pinned). Connection cap:
`MAX_CONCURRENCY` = 64 slots, taken without blocking in
`Server.process_request` and released in `process_request_thread`'s
`finally` (after the handler and the close); past the cap: 503,
`too-many-connections`, close (RES19: 10 tunnels + 53 silent holders ->
served, one more -> 503 in < 2 s, one closed -> served); listen backlog
128 so a burst past the cap is answered rather than left to kernel
connection-request retries (not checked). Request read timeout: `request_timeout` (default 30 s; env
`LLMBOX_REQUEST_TIMEOUT`, whole seconds 1-3600, never set by lbx, not a
policy key; any other value: relay exits, RES24) runs from the handler's
start (accept) to the end of the head (`\r\n\r\n`), as a deadline over
the head's `recv` calls (`Handler._read_head`; one deadline, not a timer
per read: RES28, one byte every 0.5 s with limit 2 -> 408 after 2-5 s);
on expiry (408 carries `Connection: close`, not checked): 408, DENY
`host=- reason=request-timeout`, close, slot freed (RES21: limit 2, silent,
partial CONNECT and partial GET, 408 after 2-5 s, relay side closed by
6 s; RES22: 64 silent connections fill the cap, freed at the limit, then
403 again; RES25: default 408 after 29-40 s). The socket goes back to no
timeout after the head, so the limit covers neither the SNI wait (5 s),
the tunnel nor the plain-HTTP exchange (RES23: head dribbled over 1.6 s
with limit 3 served, ClientHello 3.5 s after the head; tunnel silent 5 s still echoes; slow plain answer
after 5 s arrives). Bytes after the head: `Handler._read_hello(rest)` reads
until the first TLS record is whole (length from the record header;
stops early when byte 0 is not 0x16, not checked on its own; SNI_WAIT 5 s
deadline; the SNI parser does not check the record length, so a
record that declares more than it sends is judged on what arrived
within the 5 s; RES29: a
4074-byte ClientHello in one write with the head, or split after 100
bytes, allowed and echoed exactly), and everything read is passed to
`pipe(client, upstream, first=hello)` and sent by the
client-to-upstream copy thread before its first `recv`, so it is in
order and inside the full-duplex copy and the idle timer (RES26: head +
ClientHello + 2000 bytes in one write, echoed exactly; head + 20 bytes of
the ClientHello, then 50, echoed exactly). Plain HTTP
(`Handler._forward_body`): after the rewritten HTTP/1.0 head, exactly
`Content-Length` body bytes, `rest` first, then client `recv`s (idle
one `select` over the upstream (readable: an early
answer ends the body; writable while bytes are pending) and the client
(readable while none are pending), timeout `idle_timeout` (no progress:
`socket.timeout`, the exchange is dropped); a failed send also ends the
body; the answer is then relayed (RES30: 413 and close during a 32 MiB
body; RES31: 401 without close, while the relay waits for the body or
the upstream stops reading, reaches the client in < 3 s); bytes past the body dropped (one request per
upstream connection, `Connection: close`) (RES27: 8 + 8 bytes with 11
extra, 8 bytes with 5 extra, upstream sees the body and nothing extra);
no body forwarded with `Transfer-Encoding` (the header is still passed
on) or a `Content-Length` that is not 1-18 digits (known limit, not
checked).

## Cleanup (`run_on_exit`)

Order: stop timer (close its pipe, kill) and exec client; run box; relay;
networks; leftover report; status file; remove `.claim`; deny-log line;
status line; exit (RUN12, RUN14, RUN16, RUN17, RUN18 removal order: box,
relay, then both networks).

- Ownership (`run_owns <container|network> <name>`): removed only when
  `docker container inspect -f '{{index .Config.Labels
  "llm-in-a-box.run-id"}}'` (networks: `docker network inspect -f
  '{{index .Labels "llm-in-a-box.run-id"}}'`) prints `RUN_ID`. Resources
  are recorded before their create call, so a signal during the create
  still covers them; a network whose create fails is unrecorded. Someone
  else's same-named relay, run box or network (no label, or other label
  values; plain failure or SIGTERM during the failing create) is never
  removed (RUN43, RUN46, RUN47); this run's own created-but-not-started
  relay or run box is removed (RUN35, RUN46).
- Query retries: a query failing without "No such container", "No such
  network", "No such object" or "not found" is asked again: at most four
  queries, waiting 0.5, 1 and 2 s in between (RUN65: exactly four
  queries with those waits; an answer on the fourth still removes; four
  failures leave the container unremoved and reported as a leftover).
  RUN54: normal removal after two daemon-unreachable failures; a missing
  object gets exactly one query.
- `docker network rm`: at most five attempts per network, 1 s apart
  (RUN64: the fifth attempt's success removes it; five failures leave it,
  reported, with no sixth attempt; RUN19: success after two failures).
- Leftovers (`run_report_leftovers`): `docker ps -a --filter
  label=llm-in-a-box.run-id=<id> --format '{{.Names}}'` and `docker
  network ls --filter label=llm-in-a-box.run-id=<id> --format
  '{{.Name}}'`, repeated, 1 s apart, until both succeed empty, at most
  five rounds (RUN66: one round when nothing is left; five when something
  stays or the listings keep failing). Each leftover: `ERROR: cleanup
  incomplete: container <n> of this run is still there; remove it with:
  docker rm -f <n>` (network: `docker network rm <n>`); failed listing:
  `ERROR: cleanup could not be checked: ...` with the listing command;
  sets `cleanup=incomplete` (RUN55: box `rm` failing with exit 0 -> 125
  and the relay not named; every `network rm` failing with exit 3 -> 3;
  readiness failure + box `rm` failing -> `setup-failed code=125
  cleanup=incomplete`; listings failing -> 125, both commands printed).
- Name isolation: runs `a` and `a-b` overlapping touch only their own
  names (RUN21).
- No-network run: only the run box is recorded, so only it is removed,
  then the leftover listings (RUN104); exit-code property, timeout,
  SIGINT/SIGTERM/SIGHUP, run box and readiness failures: usual outcomes,
  no network or relay call (RUN105).
- Socket directory: never created, removed or changed on any exit path
  (RUN100: exit 0, exit 3, a setup failure at each step including the
  mount, timeout, SIGTERM; nanosecond stat snapshot; property 0-5
  sockets; VRUN21 on real docker incl. a timeout).

## Interactive paths

- Attach/start of an existing docker/sysbox container: one read-only
  `docker container inspect -f '{{index .Config.Labels
  "llm-in-a-box.mode"}}' <name>`; value `run` -> `ERROR: '<name>' is a
  run box of an unattended run (lbx --run); it cannot be attached to or
  started.`, exit 1, no `start`, no `exec -it` (RUN27 with `--runtime
  docker`, RUN71 without `--runtime`; running and exited). Creating a new
  session makes no such query; attach and start make exactly one (REG3).
  Everything else in the baseline scenarios (docker and sysbox create,
  create with a policy, with `GH_TOKEN`, with `--ports`, attach, start) is
  byte-identical to the baseline captured from the launcher before
  unattended runs (REG1; capture script
  `tests/capture-interactive-baseline.sh`, scenarios in
  `tests/interactive-baseline-lib.sh`, fixtures in
  `tests/fixtures/interactive_baseline/`).
- `--list`: a run box shows the same fields as a plain docker session
  (RUN27).
- `--destroy <name>` (run box exists): removes run box, relay, both
  networks (in that order) and `netlogs/<name>` (RUN27), never
  `runs/<name>` (RUN70). For a missing name (the run box already gone) it
  keeps its old behavior: `Session '<name>' does not exist.`, exit 0,
  read-only docker calls only, relay, networks, `netlogs/<name>` and
  `runs/<name>` untouched (RUN69); the relay and networks then need the
  manual commands.
- `runs/<name>` and `netlogs/<name>` are removed only by the caller; the
  name stays taken while either exists and is usable again once both are
  gone (RUN70).
- Live no-network run box (RUN107) and live `--socket-dir` run box
  (RUN108): `--list` shows it (runtime docker), attach exits 1,
  `--destroy` removes it and leaves `runs/<name>`. `--denied` exits 0
  for the live `--socket-dir` run box (RUN108) and, printing `No deny log
  for run '<name>'.`, after a finished no-network run (RUN107).
  RUN108 also: consecutive and concurrent runs (sharing the state
  directory) use one socket directory; timeout 0, an invalid and a reused
  run name are still refused with `--socket-dir`. Guidance: `--destroy`
  of a no-network run box still tries the relay and four network names
  with retries (existing behavior for any docker session without a wall).
- Interactive invocations: the only visible changes are that the three
  new flags without `--run` are refused with "only valid with --run"
  instead of `Unknown option` (exit 1 either way; RUN101, RUN110), and
  that `--socket-dir --run` now names `--run` as the directory, so it is
  no longer an unattended run's refusal (125 and the status line) but an
  interactive invocation that ends exactly as the same command with any
  other value (RUN101: never 125, no `lbx-run:` line, the same exit code,
  output and error as with `--not-run`, and exit 1 with "--socket-dir is
  only valid with --run"). Operational guidance — not a
  tested claim: the usage text gains lines and keeps its existing ones.
- `--denied <name>`: the name is a run's when `runs/<name>` is a
  directory, or when `deny.log` is a symbolic link and the container's
  mode label is `run` (the query is made only in that case: REG4). For a
  run: a linked `deny.log` -> exit 1, nothing of the target printed
  (RUN27 live box, RUN34 finished run); a regular file is read with `dd
  iflag=nofollow,nonblock` (`run_print_deny_log`: regular file printed
  exactly, link fails with nothing printed, named pipe with no writer
  returns within 5 s: RUN41); a link swapped in after the checks is not
  followed (RUN49). Interactive sessions keep `cat` and print a linked log
  as before (REG4).

## `--env`

- Name `^[A-Za-z_][A-Za-z0-9_]*$`, set on the host (empty allowed and
  forwarded), no duplicates (RUN24, RUN25).
- Reserved (message contains "reserved"; RUN25, RUN74): `HOST_USER
  HOST_UID HOST_GID HOME PATH SHELL USER HTTP_PROXY HTTPS_PROXY
  http_proxy https_proxy NO_PROXY no_proxy ALL_PROXY all_proxy FTP_PROXY
  ftp_proxy JAVA_TOOL_OPTIONS VM_WEB_PORT BASH_ENV ENV SHELLOPTS BASHOPTS
  PS4 PROMPT_COMMAND GCONV_PATH`, and prefixes `LD_`, `LBX_`,
  `llmbox_` (bare prefixes too). Accepted near misses: `ld_x`, `LDX`,
  `LLMBOXX` (RUN25), `FTP_PROXY_X`, `ftp_proxyx` (RUN74).
- Passed as `-e NAME` (value taken by docker from `lbx`'s environment) on
  the command exec only; never on `docker run`; the value is in no
  recorded argument vector and no `lbx` output (RUN23, byte search with
  random secret-shaped values); real docker: not in `.Config.Env`,
  `.Path`, `.Args`, nor process 1's environment (VRUN6).
- No implicit forwarding: `GH_TOKEN` on the host is absent unless named;
  named, it is on the exec only (RUN26).
- Guidance: the value is visible to the host operator via docker exec
  inspection while the command runs.

## Known limits (accepted)

Pinned by tests so they stay documented:

- `docker container inspect` matches id prefixes: a run name equal to an
  existing container's 12-digit id prefix is refused as existing
  (VRUN18).
- `--denied` follows a linked deny log once the caller has deleted
  `runs/<name>` (with no live run box); delete `netlogs/<name>` first
  (RUN75).
- `--env NAME` for a variable `lbx` assigns (and the host exports)
  passes the launcher's value, not the host's (docker's client reads `-e
  NAME` from `lbx`'s environment). Tested: `SESSION`, `RUNTIME`, `RUN_ID`
  (run name, `docker`, run identity; RUN76); `NET_POLICY`, `RUN_TIMEOUT`,
  `RUN_DATA`, `IMAGE_DOCKER`, `RUN`, `RUN_STATUS` (arguments as given,
  configured image, `true`, empty; RUN82). Other assigned variables:
  same mechanism, not individually tested.
- `LBX_RUN_READY_SECONDS` honored with no upper bound (RUN77).
- `:` in the data or policy path breaks `-v`: setup failure, nothing left
  (VRUN19).
- `--apparmor-profile` is refused on a kernel without Unix-socket
  mediation (RUN110, VRUN29).

**Both design assumptions below are measured, not assumed**, and each is
pinned by a check that runs on a kernel that mediates Unix sockets:

1. **A host-served socket is judged by the HOST path, not the path the box
   sees.** Measured: the kernel records
   `apparmor="DENIED" operation="connect" class="file"
   name="/srv/lbx-test/.../echo.sock" requested_mask="w"`, and the same server
   at `/tmp` is reached. Consequence: `--socket-dir` with
   `--apparmor-profile` connects only when the socket directory's host path is
   one the profile allows (`/tmp`, `/var/tmp`, `/dev/shm`, `/data`,
   `/run/agent`, or the box user's home; `aa_profile_writable_dirs` reads that
   set from the profile itself). VRUN30 pins both halves. VRUN25-VRUN28 serve
   from `/srv/lbx-test`, a path the profile does not allow, so they skip with
   that reason on such a kernel.
2. **A client bound to a path under /tmp DOES reach another profile's abstract
   socket.** Measured: the kernel judges the client's own path through the file
   rules (which allow /tmp) and does not apply the `peer=(label=...)` rule; an
   unbound client is still stopped by it. VRUN31 pins both. The profile is
   defense in depth, and the boundary remains the box's own network namespace
   and its two mounts.

Not pinned, no-network (VRUN23): the metadata and public IPv6 probes have
no positive control.

Guidance, socket directory and AppArmor (not tested): the credential rule
knows only its four sockets (not a rootless podman socket, gnupg agent
sockets, a docker context endpoint without `DOCKER_HOST`, or any other
powerful socket, also as a hard link); its `/var/run/docker.sock` default
has no fake-docker case; entries added after the checks are unchecked;
the daemon resolves the mount in its own mount namespace; a non-runc
default runtime (gVisor `runsc`) blocks connections undetected; socket
paths must fit 107 bytes (`/run/agent/<name>`); the profile is checked by
name and mode, not content; `LBX_SYSFS` is honored outside tests (a
tree claiming a profile that is not loaded ends the run as a setup
failure at `docker run`; a tree claiming the feature on an unmediated
kernel bypasses the refusal); the profile lists the entrypoint's paths
and `/home/agent`; it includes `<abstractions/base>` (e.g. `/dev/log`
writable); neither `--socket-dir` nor `--no-network` relies on AppArmor
(their checks ran under docker-default only); upstream kernels before
6.17 without Ubuntu's patches lack Unix-socket mediation.

Caller obligations with a socket directory (guidance, human copy
"Downsides of a socket directory"): what a socket allows is decided by
the caller's server, and the read-only mount does not limit a
connection; the server enforces maximum message size, read and idle
timeouts, a connection cap and a rate limit, and treats every request as
untrusted; nothing records socket traffic, so the server logs requests
and answers; one socket per purpose (tools, model gateway); never a
general-purpose socket (docker, ssh-agent, gpg-agent, D-Bus); Linux only
(Docker Desktop file sharing does not carry sockets reliably); mount the
directory, never the file (VRUN22). The exception to "no socket in the
data directory" is acceptable only because the directory is caller-owned,
outside `/data` and every launcher directory, holds only the caller's
sockets, and is read-only in the box (RUN99, VRUN21).

Operational guidance — not a tested claim: label check then removal by
name (two calls; a resource replaced in between would be removed);
`gosu` by user name (a host user named like an image system account runs
as that account's id; testing it needs such a host user); data checks run
in `lbx`'s mount namespace while the daemon resolves `-v` in its own (a
remote `DOCKER_HOST`, a private `/tmp`); seccomp/AppArmor profiles are not
checked at run time; VRUN4 checks the `all` IPv6 sysctl and a public IPv6
address only; a signal that arrives before the pre-scan has installed its
signal traps (from the launcher's start through the argument scan up to
`--run`, and between the four trap installations) ends `lbx` by the
signal's default action with no status line; a signal inherited as
ignored (`nohup` for SIGHUP, a non-interactive `cmd &` for SIGINT) cannot
be trapped, so its documented code does not apply; a signal that stops a
claim step before the step has shielded itself leaves bash's
"Terminated" notice on standard error (outcome still `status=signal`, no
claim-failure message; checked by hand on a launcher copy with an
injected signal); the few shell
statements after the claim and before the run's own signal traps (no
external command, so no check can place a signal there): until
`RUN_STAGE=running` a signal has the pre-start outcome (no status file,
the claim removed); from `RUN_STAGE=running` until the run's traps,
`run_on_exit` writes `status=signal code=<128+n>` to a status file,
SIGUSR1 included (code 138, not a timeout), and `runs/<name>` keeps it,
so the name stays taken (checked by hand on launcher copies with an
injected signal).

## Tests

`tests/test_llm_in_a_box_run.sh` (fake docker; run as a normal user;
root-made fixtures from `sudo tests/setup-run-test-host.sh <user>`; seed
printed, `LBX_TEST_SEED` replays): RUN1 policy · RUN2 runtime · RUN3
data-directory rules · RUN4 names in use · RUN5 images local · RUN6
command required · RUN7 names (property, 128/129) · RUN8 id 0 · RUN9
timeout · RUN10 refused flag combinations · RUN11 unknown option before
`--run` · RUN12 exact happy-path calls · RUN13 standard
output exact · RUN14 exit codes (property) · RUN15 command vector
(property) · RUN16 setup failure at each step · RUN17 timeout; SIGKILL
releases the caller's pipe · RUN18 signals, setup signal · RUN19 network
rm retried · RUN20 deny log kept; status unforgeable · RUN21 prefix-sharing
overlapping runs · RUN22 name reuse · RUN23 `--env` value never leaks
(property) · RUN24 unset/empty/duplicate `--env` · RUN25 invalid/reserved
`--env` (property) · RUN26 `GH_TOKEN` · RUN27 attach/destroy/denied/list
on a run box · RUN28 slow start then timeout · RUN29 `--help` · RUN30
newline before launcher lines · RUN31 default lifetime · RUN32 standard
input · RUN33 default readiness wait · RUN34 `--denied` finished run link
· RUN35 created-not-started relay removed · RUN36 second signal · RUN37
concurrent same name · RUN38 `--run` as option value vs baseline · RUN39
setpriv · RUN40 device-number mount point · RUN41 no-follow reader ·
RUN42 `--run` as every option's value · RUN43 foreign relay kept · RUN44
existing `.claim` · RUN45 racing `.claim` · RUN46 foreign run box kept,
own removed · RUN47 foreign network kept · RUN48 random run-id · RUN49
`--denied` swap · RUN50 failed claim leaves nothing · RUN52 failing device-number scan · RUN53 only status left,
name stays taken · RUN54 ownership query retries · RUN55 incomplete
cleanup reported · RUN56 `--data` required · RUN57 policy refusal
messages, policy not a file · RUN58 run-name refusal messages · RUN59 no
`docker` on `PATH` · RUN60 unreadable random bytes · RUN61 `runs/<name>`
not creatable · RUN62 unreadable relay address · RUN63 relay health: 10
probes 1 s apart · RUN64 network removal: 5 attempts 1 s apart · RUN65
ownership query: 4 attempts, 0.5/1/2 s · RUN66 leftover listing: up to 5
rounds 1 s apart · RUN67 relay user, tmpfs, networks; run box user label,
`NO_PROXY`, `JAVA_TOOL_OPTIONS` · RUN68 successful run leaves HOME
unchanged · RUN69 `--destroy` after the run box is gone · RUN70
`runs/<name>` left for the caller; name free only when both directories
are gone · RUN71 attach without `--runtime` refused · RUN72 SIGINT,
SIGHUP, SIGUSR1 during setup · RUN73 second signal of any kind during
cleanup · RUN74 `FTP_PROXY`/`ftp_proxy` reserved · RUN75 known limit:
`--denied` after `runs/<name>` deleted · RUN76 known limit: `--env` of a
launcher variable · RUN77 known limit: readiness seam unbounded · RUN79 cleanup ignores
signals after an ordinary end or a timeout · RUN80 `runs/` not creatable
(bare refusal) · RUN81 `-h`, `-?` with `--run` · RUN82 known limit:
`--env` of any launcher-assigned variable · RUN83 signal during the
checks: status=signal, nothing written · RUN84 signal during the claim:
claim entries removed · RUN85 process-group signal during the claim ·
RUN86 second signal before the run starts · RUN87 failed claim with a
signal pending removes nothing twice · RUN88 failed claim clean-up meets
a concurrent run · RUN89 process-group signal while runs/ is created,
SIGHUP, SIGUSR1 · RUN90 failed claim with a non-empty runs/<name> · RUN91 concurrently
created runs/ not owned · RUN92 state directory created for the claim
removed · RUN93 missing state-directory parent created · RUN94 failed or
signalled claim below a missing parent leaves only the ancestors · RUN95
process-group signal while the state directory or its ancestors are
created · RUN96 runs/ not creatable in a new state directory · RUN97 the state
directory's parent not creatable · RUN98 `--socket-dir` mount exact
(property) · RUN99 each socket-directory rule · RUN100 socket directory
unchanged on every exit (property) · RUN101 new flags need `--run`;
`--socket-dir --run` stays interactive · RUN102 `--env` with
`--socket-dir` · RUN103 exactly one of `--net-policy`/`--no-network` ·
RUN104 no-network exact calls and standard error · RUN105 no-network
outcomes and cleanup (property), names unique across modes · RUN106
`--no-network --socket-dir` · RUN107 list/attach/destroy/denied on a
no-network run box · RUN108 shared socket directory, operations, existing
refusals · RUN109 `--apparmor-profile` vector, never loads a profile ·
RUN110 AppArmor refusals and their order · RUN111 `idle_timeout_seconds`
range for runs (property) · RUN112 same validation for interactive
sessions · REG1 interactive
baseline ·
REG2 `--` and run-only
flags without `--run` · REG3 no label query on create · REG4 `--denied`
label query.

`tests/verify-run-unattended.sh` (real docker, not the snap package;
images `llm-in-a-box:docker`, `llm-in-a-box-relay:latest`, `alpine:3`;
internet for VRUN5, VRUN25 and several controls; perl on the host; AppArmor
enabled with both profiles loaded for VRUN25-VRUN29; setup script run;
normal user; a missing prerequisite is a FAIL, never a skip, except
VRUN25-VRUN28 on a kernel whose AppArmor does not mediate Unix sockets:
`[SKIP] ... (this kernel's AppArmor does not mediate Unix sockets)`,
listed in `tests/approved-skips.txt`, and the results line adds `, N
skipped`): VRUN1 output/exit/nothing left ·
VRUN2 privileges as test user · VRUN3 1 MiB standard input · VRUN4 every
way out but the relay blocked · VRUN5 allowed vs denied host, deny log ·
VRUN6 `--env` not in configuration or process 1; client proxy
configuration kept out · VRUN7 timeout stops the command in the box ·
VRUN8 SIGTERM · VRUN9 home and proxy ready · VRUN10 no dockerd · VRUN11
hostile vectors · VRUN12 links and pipes in `/data` never opened · VRUN13
relay hardening · VRUN14 bind mount refused · VRUN15 SIGKILL recovery and
manual cleanup · VRUN16 128-character name · VRUN17 after SIGKILL:
`.claim`, no status, relay and both networks left · VRUN18 known limit:
container id prefix as run name · VRUN19 known limit: `:` in the data or
policy path · VRUN20 socket reached at `/run/agent`, peer id · VRUN21
`/run/agent` read-only for box user and root, directory unchanged ·
VRUN22 restarted server reached; file mount breaks · VRUN23 no-network:
only loopback in use (kernel fallback tunnels down, no address), no way out · VRUN24 no-network with socket directory ·
VRUN25 work under the profile · VRUN26 writes and socket connects denied
outside allowed paths; the data-directory limit · VRUN27 abstract sockets
only within the profile · VRUN28 no internet sockets under the no-network
profile · VRUN29 real AppArmor state read; refusals create nothing.

Support: `tests/fake-docker-run.sh` wraps `tests/fake-docker.sh`
(unchanged) and adds the controls documented in its header (failure
injection `FAKE_FAIL_ON`, `FAKE_HEALTH_EXIT`, `FAKE_READY_EXIT`,
`FAKE_CREATE_THEN_FAIL`, `FAKE_NAME_TAKEN*`, `FAKE_OWNS_FAILS*`,
`FAKE_RM_FAILS_ON`, `FAKE_NETRM_FAILS`, `FAKE_LEFTOVER_FAILS`,
`FAKE_HEALTH_FAILS`, `FAKE_RELAY_IP_FAIL`; answers `FAKE_RELAY_IP`,
`FAKE_IMAGE_USER`; captures `FAKE_EXEC_ENV_CAPTURE`, per-call start times
`FAKE_CALL_TIMES`; timing
markers `FAKE_*_STARTED`, `FAKE_*_SLEEP`; the concurrency barrier
`FAKE_BARRIER_DIR`; a zero-byte argument log `FAKE_ARGV_LOG`).
`tests/setup-run-test-host.sh` (root) creates `lbxtest` (user id 2345,
group id 100, docker group), `/srv/lbx-test`, the sudo rule to act as
`lbxtest`, and the fixtures under `/srv/lbx-test-fixtures` (`root-owned`,
`foreign-entry`, `with-socket`, `with-device`, `with-mount`,
`with-foreign-socket`; the bind mount does not survive a reboot), makes
sure `/run/user/<uid>` of the invoking user exists (mode 0700), and loads
`apparmor/llm-in-a-box-run` with `apparmor_parser -r` when AppArmor is
enabled (never fatal; not persistent across a reboot). Both suites run in continuous
integration's user pass (`docs/testing.md`).

`tests/test_relay_resolution.sh` (relay image only; `--network none`
relays, hosts lines appended as root, clients BusyBox `nc`/`wget` inside
the relay container; an `--internal` network in 11.0.0.0/8 for the idle
checks; seed printed, `LBX_TEST_SEED` replays; image from
`LBX_TEST_RELAY_IMAGE`, default `llm-in-a-box-relay:latest`, built only
when missing): RES1 lookup timeout, 503, `resolve-failed:EAI_AGAIN` ·
RES2 one lookup (timing) · RES3 `addr=` · RES4 100.64.0.0/10 edges and
neighbors (`connect-failed:ENETUNREACH`) · RES5 fec0::/10 · RES6
`::ffff:` mapping · RES7 192.0.0.9/10 and the /24 edges · RES8 seeded
property over the refused ranges and public controls · RES9 mixed and
double answers name the first refused address · RES10 plain HTTP · RES11
one-token reasons · RES12 policy reasons · RES13 tunnel idle timeout ·
RES14 plain-HTTP wait · RES15 relay refuses bad idle values · RES16
one-way stream keeps the tunnel open · RES17 `resolve-failed:bad-name` ·
RES18 silent tunnel closes at the timeout · RES19 64-connection cap
(tunnels included) · RES20 full duplex · RES21 request read timeout, 408
`request-timeout` · RES22 timed-out connections free their slots ·
RES23 slow but complete head served, limit ends with the head · RES24
relay refuses bad `LLMBOX_REQUEST_TIMEOUT` · RES25 default request limit
30 s · RES26 bytes read with the CONNECT head forwarded first · RES27
plain-HTTP body forwarded by `Content-Length` · RES28 one deadline for
the whole head · RES29 ClientHello larger than one read · RES30 early
upstream answer during a body relayed · RES31 early answer relayed at
once while waiting for the body or a blocked upstream.
`tests/test_llm_in_a_box_netwall.sh` (internet): T3 refusal by resolved
address (`--add-host` 127.0.0.1) · T3b `resolve-failed:EAI_NONAME`, 503 ·
T2b `sni-mismatch sni=evil.example`.
