# Session removal disambiguation (legacy duplicates) — LLM reference

Date: 2026-09-06. Human copy:
`docs/session-removal-disambiguation.md`.

## Domain

A session name can map to two instances ("legacy duplicate",
`session_lookup` reports `ambiguous:<rt>,<rt>`): a vm session directory
`$LBX_STATE_DIR/sessions/<name>` AND a docker container named `<name>`.
Before 2026-09-06, `--destroy`/`--stop`/`--shutdown` treated
`ambiguous:` as fatal and ignored `--runtime`, so such a box could never
be removed or stopped. The user's `waggle` box (vm + sysbox under one
name) was the reported case.

## Behavior after the fix

### 1. `--runtime` selects the instance for destructive operations (R1/R2)

Ambiguous name + `--runtime <vm|sysbox|docker>` operates on EXACTLY one
instance; the sibling keeps running. Destroy kills a live qemu and
deletes the vm session dir (vm side) or removes the container (container
side, incl. the existing relay/network/netlogs cleanup). Stop/shutdown
[--force] stops one instance only.
Claims map: (Tested by T16/T17/T18/T18b/T22/T27 in
`tests/test_llm_in_a_box_sessions.sh`.)

After acting on one half of an ambiguous pair a note names the remaining
sibling and the exact remove/stop command.
(Tested by T16/T17/T22/T27.)

### 1b. `--runtime` selects the instance for LAUNCH/ATTACH too (R6, 2026-09-08)

The default action (no flag) had the same fatal error: `lbx
--runtime vm <name>` on an ambiguous name died with "exists in multiple
runtimes" even when `--runtime` named a member — the 09-06 fix covered
only destructive operations. Now an explicit `--runtime` that is a
member of the pair selects that instance: the run proceeds into that
instance's own launch path (vm preflight + boot, or container
attach/start) and the sibling is untouched.
Claims map: (Tested by T32 — vm direction, `--runtime vm` on a
vm+docker pair reaches the vm preflight and prints no ambiguity error
while the sibling container keeps running; T33 — container direction,
`--runtime docker` attaches to the container with no ambiguity error
while the vm session dir survives.)

A valid `--runtime` outside the pair is an error naming the pair's
members; nothing is touched (launch mirror of T25).
(Tested by T34.)

### 2. Ambiguous without `--runtime` (R3)

Error "exists in multiple runtimes", exit non-zero, nothing touched;
message now shows the WORKING per-operation command forms (`--destroy
--runtime`, `--stop --runtime`). (Tested by T15/T21/T29.)

### 3. Conflict guards (R4)

Unique instance + conflicting `--runtime` → error "already exists as a
<rt> instance", nothing touched (previously the runtime was silently
ignored and the wrong instance was acted on — deliberate fail-closed
change). Matching `--runtime` on a unique instance still works.
(Tested by T19/T20/T23/T26/T26b/T28.)

### 4. Third-runtime mismatch (R1/R3)

Valid `--runtime` that is a member of NEITHER runtime of an ambiguous
pair (vm+sysbox pair with `--runtime docker`) → error naming the pair's
members + working forms, nothing touched, no note.
(Tested by T25.)

### 5. Invalid runtime (R5)

`--runtime` outside {sysbox,docker,vm} with destroy/stop/shutdown →
"Unknown runtime" before ANY side effect, including before the
missing-name no-op (session-name format validation still runs first).
(Tested by T24/T24b.)

### 6. Bounded "untouched" guarantee and netwall limitation

Guaranteed observable scope: sibling container state and vm session dir
survive; targeted vm's qemu killed/stopped. Netwall components
(`llm-in-a-box-relay-<name>`, networks, `netlogs/<name>`) are name-keyed and
shared by both instances; per-runtime cleanup removes them as today.
Legacy pairs where one side used `--net-policy` are NOT covered by the
untouched guarantee. Concurrent ops on one pair unsupported.

### 7. S6 pgrep escape

`vm_live_pid_for` escapes the overlay path before building the `pgrep
-f` regex, so dotted session names cannot match/kill an unrelated qemu
differing in one character. (Tested by T30.)

### 8. Historical no-ops preserved

`--destroy <missing>` → "does not exist", exit 0; all-missing `--stop`
→ exit 0. (Tested by T31/T31b.)

## Tests (all in tests/test_llm_in_a_box_sessions.sh, appended 2026-09-06)

T15 red-green destroy-ambiguous-no-runtime (forms text) · T16 red-green
destroy --runtime vm on ambiguous (live qemu killed, container kept,
note) · T17 red-green destroy --runtime docker (container gone, dir
kept, note) · T18 red-green destroy --runtime sysbox via real
sysbox-runc runtime (inference path; skips without sysbox-runc) · T18b
red-green destroy --runtime sysbox via label branch · T19 red-green
destroy conflict on unique container · T20 red-green destroy conflict on
unique vm · T21 red-green stop-ambiguous-no-runtime (forms text) · T22
red-green shutdown --force --runtime docker (vm qemu survives) · T23
red-green stop conflict on unique container · T24/T24b red-green invalid
runtime rejected (incl. missing-name ordering) · T25 red-green
third-runtime mismatch on vm+sysbox pair · T26/T26b GUARD matching
runtime on unique instances still works · T27 red-green stop --force
--runtime vm on ambiguous (container survives) · T28 red-green
multi-name stop with runtime (docker half stopped, unique vm rejected &
alive, missing reported, exit != 0) · T29 red-green multi-name stop
without runtime (ambiguous errors, container still stopped) · T30
red-green dotted-name destroy (decoy qemu survives) · T31/T31b GUARD
missing-name no-ops.

T32-T34 (appended 2026-09-08): launch/attach disambiguation (R6). T32
red-green `--runtime vm` on an ambiguous pair reaches the vm preflight
(LBX_VM_MISSING-forced failure), no ambiguity error, sibling container
keeps running, vm dir untouched · T33 red-green `--runtime docker`
attaches the container, no ambiguity error, vm sibling dir untouched ·
T34 red-green `--runtime sysbox` on a vm+docker pair errors naming the
pair, nothing touched. Fixture: sibling container carries the
`llm-in-a-box.runtime=docker` label and uses busybox when the repo
image is absent — the label is the mechanism `session_lookup` keys on,
so these checks run on any docker host instead of skipping.
