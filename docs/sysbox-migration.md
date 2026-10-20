| **Images in the box's own docker** | **Not carried across.** The inner docker daemon keeps its images and containers in a volume of the box's own, which is removed with the old box; the replacement starts with an empty one. Pull or build them again. |
# Migrating sysbox boxes onto a usable stack

`lbx --migrate` rebuilds an existing sysbox box on the current stack and carries
its home directory across, so the agent sessions inside it survive.

It exists because of the failure described in
[sysbox-runtime.md](sysbox-runtime.md): a sysbox box whose ID mapping has been
lost cannot be repaired in place, and rebuilding it by hand loses everything the
box accumulated outside `/data`.

## When you need it

Two situations, and they usually arrive together:

1. **Your sysbox is too old for your Docker.** sysbox-ce 0.6.x and 0.7.0 do not
   declare the `time` Linux namespace, which containerd 2.x (Docker 28+)
   requires, so no box can be created at all. `lbx` refuses and says so
   (MIG2).
2. **Your existing boxes are damaged.** Installing or upgrading sysbox restarts
   its daemons, and that silently breaks the ID mapping of every sysbox box that
   already exists: `sudo` inside them reports
   `owned by uid 65534, should be 0`, and they cannot be repaired in place.

So the order is:

```
1. upgrade sysbox   (this is what damages the existing boxes)
2. migrate them     (this is what carries their contents across)
```

**Upgrading first is not optional.** The replacement box is built on the current
stack, so migrating before upgrading fails immediately, and `lbx` says so
(MIG2). If you have already upgraded, the boxes are damaged but their data is
intact; that is the normal case `--migrate` is built for.

## What it does

```
lbx --migrate --dry-run <session>...   report what would happen; change nothing
lbx --migrate <session>...             migrate the named boxes
lbx --migrate --all                    migrate every sysbox box
```

`--all` is never implied: the operation removes containers, so you name what to
migrate or ask for everything explicitly (MIG5).

For each box:

1. **Export** its home directory (`/home/agent`) through the host's view of the
   container's filesystem. This is the only path that works on a damaged box,
   and it is why the migration does not depend on `docker exec`.
2. **Build a replacement** from the configured image, under a temporary name, as
   the same user the original box was created as.
3. **Restore** the home directory into it and re-own it to the box user. The
   payload is piped into the container rather than placed with `docker cp`:
   every box has a volume mounted at `/var/lib/docker`, and the daemon walks the
   container's filesystem to resolve a `docker cp` destination, which fails on
   that mountpoint (`mkdirat var/lib/docker: directory not empty`). A pipe has no
   destination path for the daemon to walk, and its exit status is the
   extractor's, so a silent no-op copy cannot pass unnoticed (MIG6, MIG12: both
   restore a payload into a box that has the volume mounted).
4. **Write a notice** for the agent, at the three paths the agents read.
5. **Verify** the replacement: its ID mapping is applied, `sudo` works, and the
   payload is present and readable by the box user.
6. **Only then** remove the original and rename the replacement into place.

Steps 5 and 6 are the important ordering. The original box is the only copy of
your work until the replacement has been proven good, so a migration that fails
anywhere leaves it untouched and discards the partial replacement (MIG8).

`--dry-run` reports the boxes it would migrate and changes nothing at all: it
creates no container and removes none (MIG1), and it works on a host where the
runtime cannot run at all, because that is exactly when you need it (MIG3).

## What survives, and what does not

| | |
|---|---|
| **`/data`** | **Untouched.** It is a host bind mount, not part of the container, so it is neither copied nor modified (MIG10). |
| **Agent sessions** | **Carried across.** pi sessions (`~/.pi/agent/sessions/`), Claude Code (`~/.claude/`) and opencode (`~/.config/opencode/`) all live in the home directory, which is what the migration moves (MIG6, MIG12, MIG14). |
| **Other files in the home directory** | **Carried across**, with their ownership (MIG12, MIG14). |
| **Packages installed by hand** | **Not carried across.** Anything installed with apt, pip, `npm -g`, `cargo install`, or by hand is gone, because it lives in the container's root filesystem and not in the home directory (MIG6, the packages check: a marker planted outside the home directory before the migration is absent afterwards). |
| **Images in the box's own docker** | **Not carried across.** The inner docker daemon keeps its images and containers in a volume of the box's own, which is removed with the old box; the replacement starts with an empty one. Pull or build them again. |

The agent is told about those last two rows. The migration writes a notice to
`~/.pi/agent/AGENTS.md`, `~/.claude/CLAUDE.md` and
`~/.config/opencode/AGENTS.md`, the paths each agent reads, owned by the box
user and readable by it. The notice lists what to reinstall and tells the agent
to delete it once it has (MIG11).

The notice is a file the agent removes, not state `lbx` tracks, so there is
nothing to go stale: as long as it exists it is telling the truth.

## Verifying a migration

In the box, these should hold:

```bash
stat -c '%u %g %a' /etc/sudo.conf     # 0 0 644
sudo -n true && echo "sudo works"
ls ~/.pi/agent/sessions/              # your sessions are here
cat ~/.pi/agent/AGENTS.md             # the migration notice
```

The `0 0 644` is the point: it means the ID mapping is applied. On a damaged box
that same file reads `65534 65534` **from inside the box** while the host still
sees `0 0`. The box's own view is the one that matters, and it is what the
migration's verification checks (MIG6).

## Notes on running it

**It needs root.** The export reads the box's filesystem through
`/proc/<pid>/root`, which belongs to the container's owning user rather than to
you. `lbx` uses root directly or passwordless `sudo`, and refuses with an
explanation if neither is available.

**Use `sudo -E`, not plain `sudo`.** `sudo` resets `HOME`, so the launcher would
resolve its state directory under `/root` and find none of your sessions. If
that happens, `lbx` says so rather than reporting that your box does not exist.
`sudo -E lbx --migrate <session>` preserves your environment and works; setting
`LBX_STATE_DIR` explicitly does too.

**The replacement is created as your user, not as root.** The box user is
derived from the user that runs the launcher, so creating the replacement as
root would leave the box user unrenamed and point its `sudo` rule at the wrong
account. `lbx` reads the original box's identity and reproduces it.

**Migrating is not instant.** The payload is the box's home directory, which is
about 1.2 GB for a box with a few sessions.

## Where this sits relative to a reboot

A host reboot restarts the sysbox daemons, so boxes that were running before a
reboot come back damaged. Their data is intact, so `lbx --migrate` recovers them
the same way; recreating them by hand does not.

## Test map

The checks are in `tests/test_llm_in_a_box_migrate.sh`. The ones that drive real
containers and restart the real sysbox daemons need docker, `sysbox-runc`, the
`llm-in-a-box:sysbox` image, and root or passwordless `sudo`; they skip with a
message naming what is missing, and skip rather than fail on a host without
those.

| Check | What it verifies |
|---|---|
| MIG1 | `--dry-run` creates and destroys nothing |
| MIG2 | A real run on an unusable runtime refuses, names the cause, states that upgrading comes first, and creates nothing |
| MIG3 | `--dry-run` works with no usable sysbox runtime: it reports rather than failing |
| MIG4 | A `docker`-runtime box is reported as skipped, not migrated |
| MIG5 | A bare `--migrate` refuses and names the two ways to say what to migrate |
| MIG6 | End to end on a real damaged box: it is damaged first (ground truth), then after the migration the ID mapping is applied, the box user owns its files, the user namespace is active, `sudo` works, and the session file is unchanged |
| MIG7 | A box in the worst damage state still migrates: the host reads its filesystem and the migration succeeds from there |
| MIG8 | A migration that cannot complete reports failure, leaves the original box untouched, and leaves no partial replacement |
| MIG9 | Over several boxes, the good one is migrated, the failure is reported, and the exit status is non-zero |
| MIG10 | `/data` is neither read nor written: a sentinel file is unchanged, and nothing is staged inside it |
| MIG11 | The notice exists at all three agent paths, is owned by and readable by the box user, says packages must be reinstalled, and tells the agent to delete it |
| MIG12 | A file the box user owned before the migration is still owned by it and readable after: the failure that copying with `docker cp` alone produces, and the reason the restore pipes the payload instead |
| MIG13 | A name that cannot be migrated is reported rather than crashing |
| MIG14 | Property check: across generated session trees of varying depth and file count, every file keeps its relative path and its box-user ownership |
| MIG15 | The create-path refusal on an unusable runtime names the sysbox boxes that already exist and the migration command, and creates nothing |
