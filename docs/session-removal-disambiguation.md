# Session removal disambiguation (legacy duplicates)

Date: 2026-09-06.

## The problem this solves

A session name may exist in TWO runtimes at once — a vm session
session directory under `$LBX_STATE_DIR/sessions/<name>` and a
docker container
named `<name>`. This happens with boxes created before the
one-name-one-instance rule (2026-09-03) or by legacy tools; `--list`
shows two rows with the same NAME. This is a **legacy duplicate**
(ambiguous name).

Before 2026-09-06 such a box could never be removed or stopped: the
destroy/stop/shutdown commands treated the ambiguity as a fatal error
and silently ignored `--runtime`, even though their own error messages
pointed at `--runtime` as the remedy.

## The fix: `--runtime` selects the instance for destructive operations

For an ambiguous name, all of the following now operate on exactly ONE
instance — the one named by `--runtime` — and leave the sibling running:

```bash
lbx --destroy --runtime vm <name>        # remove the vm session
lbx --destroy --runtime sysbox <name>    # remove the sysbox container
lbx --destroy --runtime docker <name>    # remove the docker container
lbx --stop|--shutdown [--force] --runtime <vm|sysbox|docker> <name>
```

(Tested by T16/T17/T18/T18b/T22/T27 in
`tests/test_llm_in_a_box_sessions.sh`.)

After removing or stopping one half of an ambiguous pair, the tool
prints a note naming the sibling that still exists, with the exact
command to remove or stop it. (Tested by T16/T17/T22/T27.)

## Launch and attach select by `--runtime` too

The same fatal error also blocked the DEFAULT action — launching or
attaching: `lbx --runtime vm <name>` on an ambiguous name died
with "exists in multiple runtimes" even though `--runtime` named a
member (reported 2026-09-08). Since then, an explicit `--runtime` that
is a member of the pair selects that instance for launch/attach exactly
as it does for destructive operations: the run proceeds into the
selected instance's own launch path (vm preflight/boot, or container
attach/start) and the sibling is left untouched. (Tested by T32 vm
direction, T33 container direction.)

A valid `--runtime` outside the pair (for example `--runtime sysbox` on
a vm+docker pair) is an error naming the pair's actual runtimes, and
nothing is touched — the same fail-closed guard as the destructive
side, as T25 documents for destroy. (Tested by T34.)

## What happens without `--runtime`

An ambiguous name without `--runtime` still errors and touches nothing —
the tool never guesses which instance you meant. The error names both
runtimes and now shows the WORKING command forms (destroy form for
`--destroy`, stop form for `--stop`/`--shutdown`). (Tested by
T15/T21/T29.)

## New fail-closed guards

- A unique session plus a `--runtime` that names a DIFFERENT runtime is
  an error (`session '<name>' already exists as a <rt> instance`) and
  nothing is touched. Before this change the runtime flag was silently
  ignored, so `--destroy --runtime vm <docker-only-name>` actually
  removed the docker container. This is a deliberate behavior change for
  scripts that passed a canned `--runtime` to destroy/stop — such a call
  now fails loudly instead of acting on the wrong instance. (Tested by
  T19/T20/T23/T28.)
- A `--runtime` that is valid but not one of the two runtimes in an
  ambiguous pair (e.g. `--runtime docker` on a vm+sysbox pair) is an
  error naming the pair's actual runtimes; nothing is touched. (Tested
  by T25.)
- An invalid `--runtime` value with `--destroy`/`--stop`/`--shutdown` is
  rejected with "Unknown runtime" before any side effect — including
  before the missing-name no-op. (Session-name format validation still
  runs first.) (Tested by T24/T24b.)
- A matching `--runtime` on a unique session keeps working normally
  (the guards above never fire for correct use). (Tested by T26/T26b.)

## What "leaves the sibling untouched" covers

The guarantee is bounded to what the tests observe: the sibling's
container keeps running (or exits, for stop operations on it) and the
sibling's vm session directory survives; a destroyed vm's live qemu
process is killed, a stopped vm's is stopped.

Known limitation (unchanged by this fix): netwall components — the relay
container `llm-in-a-box-relay-<name>`, its networks, and `netlogs/<name>` — are
keyed by session NAME, not by instance, and the existing per-runtime
cleanup removes them as it always has. If one side of a legacy pair was
created with `--net-policy`, destroying the other side removes the
shared relay/netlogs. Do not run concurrent destructive operations on
one legacy pair (no locking). (Limitation documented, not changed;
netwall is out of scope for this fix.)

## Related hardening

S6 — a vm session whose name contains a `.` (legal in session names) no
longer risks killing an unrelated qemu process whose overlay path
differs only at that character: the `pgrep` pattern is built from an
escaped path. (Tested by T30 in `tests/test_llm_in_a_box_sessions.sh`.)

Missing names keep their historical behavior: `--destroy <missing>`
prints "does not exist" and exits 0; an all-missing `--stop` stays a
clean no-op. (Tested by T31/T31b.)

## Working example (the reported `waggle` case)

`lbx --list` shows `waggle` twice (vm + sysbox). Remove both,
one at a time:

```bash
lbx --destroy --runtime sysbox waggle
lbx --destroy --runtime vm waggle
```

Each command removes exactly one instance and notes the remaining one.
