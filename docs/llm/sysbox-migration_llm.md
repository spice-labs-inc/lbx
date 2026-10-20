# LLM reference: sysbox box migration (`lbx --migrate`)

Companion to [../sysbox-migration.md](../sysbox-migration.md). This file is the
dense reference: interfaces, invariants, implementation constraints, failure
modes, and the test map. Read it before changing the migration code in the
launcher.

## Interface

| Surface | Meaning |
|---|---|
| `lbx --migrate <name>...` | Migrate the named sessions |
| `lbx --migrate --all` | Migrate every sysbox session. Never implied by a bare `--migrate` |
| `lbx --migrate --dry-run [<name>...]` | Report only; creates and destroys nothing |
| `--all` / `--dry-run` without `--migrate` | Refused, naming the mistake |
| `--migrate` with no names and no `--all` | Refused, naming both ways to say what to migrate |
| `--migrate` combined with `--run` | Refused (a `--run` is unattended and must not be preceded by a destroy) |

`--migrate` is a cleanup/state-class operation like `--list` and `--destroy`: it
does not require a session name, does not need a working runtime to *report*,
and takes names as arguments. Names are validated by the same session-name
grammar as every other operation.

Exit status: 0 when every requested session migrated (or was legitimately
skipped), non-zero when any failed. Each session is attempted even if an earlier
one failed, so the operator learns which are done and which are not.

## Invariants the implementation must hold

1. **The original box is never removed before its replacement is verified.**
   Steps: export, create replacement (temporary name), restore, write notice,
   verify, destroy original, rename replacement into place. Any failure
   before the destroy leaves the original untouched and removes the partial
   replacement.
2. **`/data` is never read or written.** It is a host bind mount; it is not part
   of the container and must not be copied. The export targets
   `/home/agent` only.
3. **The replacement is created as the box's own user**, read from the box's
   `HOST_USER`/`HOST_UID`/`HOST_GID` environment. Not as the invoking user.
4. **The export must not depend on `docker exec`.** Exec may be broken entirely
   in the states that most need migrating.
5. **`docker cp` alone is never used to place files.** See the constraints below.
6. **The old box's inner-docker volume goes with the old box.** The images it
   held were the old box's; the replacement has a volume of its own, and
   `--destroy` removes whichever volume a box mounts at `/var/lib/docker`,
   read from the container's mount table rather than from its name.

## Implementation constraints (each measured, not assumed)

### The restore path

The payload is piped into the container (`docker exec -i ... tar -xf -`), never
placed with `docker cp`. Measured: every box has a volume mounted at
`/var/lib/docker`, and the daemon walks the container's filesystem to resolve a
`docker cp` destination, which fails there with
`mkdirat var/lib/docker: directory not empty`. A pipe has no destination path for
the daemon to walk, and its exit status is the extractor's, so the silent-copy
trap below cannot occur in the migration itself.

### The export path

The export reads through `/proc/<pid>/root/home/agent` with
`tar --numeric-owner`. This is the only path that works on a damaged box:
reading through the container's own view would record the overflow uid instead
of the real owner. It needs root, because `/proc/<pid>/root` belongs to the
container's owning user.

The recorded IDs are **host-side** IDs. Every sysbox box on a host shares one ID
range (from `/etc/subuid`, e.g. `sysbox:165536:65536`), so extracting inside the
replacement container maps them back to the same in-box IDs. This is why the tar
is extracted *inside* the container rather than unpacked on the host.

### Why `docker commit` is not used

Committing a **damaged** box corrupts the result. The commit reads ownership
through the broken mapping and writes the overflow uid into the image for every
path owned by the box user, and the result cannot be repaired from inside (`uid
0` in the container cannot `chown` a file it does not own: `Operation not
permitted`). Measured: a box-user file reads `1000:1000` in the box and
`166536:166536` on the host, but `65534:65534` in a container started from the
commit. The migration therefore moves the *data*, not the container.

### The box's own view is the health test

The verification checks the box's **own** view of `/etc/sudo.conf`:

| | box's view | host's view |
|---|---|---|
| healthy | `0 0` | `165536 165536` |
| damaged | `65534 65534` | `0 0` |

An applied ID mapping means the container's uid 0 is a *mapped, unprivileged*
host uid, so the two views **disagree on a healthy box**, and disagree in the
opposite direction when damaged. Requiring them to agree rejects every correct
migration. This is why the verification reads only the box's view, and why
`box_is_damaged` in the test suite asserts both halves explicitly.

### The payload must be verified, not assumed

Verification also confirms the payload landed: the box user owns
`/home/agent`, can list it, and the box holds at least as many entries as the
tar did. Without this, a restore that silently did nothing would pass
verification (the replacement's own health is independent of the payload) and
the original, the only copy, would be removed. The comparison is `>=` because
the box legitimately holds more: the notice adds files and the entrypoint
creates its own.

### `docker cp` traps (both measured)

- A file placed with `docker cp` arrives owned by the **overflow uid**, and the
  container cannot fix it afterwards (`chown` as the container's uid 0 fails
  with `Operation not permitted`).
- Reusing one destination path across several `docker cp` calls fails from the
  second call on with **`stale file handle`**.
- `docker cp` into `/home/agent` has been observed to **report success while
  copying nothing** (exit 0, file absent).

Consequences: the payload is copied as a tar and extracted *inside* the
container, and the notice is written through **stdin** (`docker exec -i ... sh -c
'cat > path'`) as the box user: no destination path to go stale, and no
`chown` needed because the writing user is the owner.

### The box user is derived from the invoking user

`lbx` passes `HOST_USER`, `HOST_UID` and `HOST_GID` (the invoking user's name
and ids) to the container; `entrypoint.sh` creates that user and writes
`${TARGET_USER} ALL=(ALL) NOPASSWD:ALL` to `/etc/sudoers.d/agent`. So a
replacement created as the wrong user comes up with the box user unrenamed and
its `sudo` rule pointing at someone else, and `sudo` inside it demands a
password.

Because `--migrate` needs root, the nested launcher invocation that creates the
replacement drops to the box user's uid and gid with that user's full
supplementary group set: clearing the groups would drop the docker group and
the nested launcher could not reach the docker socket. `HOME` is set from the
box user's passwd entry, because `sudo` resets it to `/root` and the nested
launcher would then look for its config and state directory there.

### Other guards

- The replacement is created under a temporary name derived from the session
  name; if a container of that name already exists the creation is treated as
  a failure.
- The wait for the replacement's `/tmp/.user-ready` is a **failure** if it times
  out, not something to carry on from: restoring into a box whose user does not
  exist yet would leave the files owned by the wrong IDs.
- A box that is not running is started before the export (the export needs a
  live PID).
- Non-sysbox sessions are skipped, not failed; a name that is not a
  llm-in-a-box session is reported.
- When a session is not found and `SUDO_USER` is set, the error adds a note that
  `sudo` resets `HOME` and suggests `sudo -E`; otherwise the failure reads as
  "your box does not exist".

## Notice paths

| Path | Read by |
|---|---|
| `~/.pi/agent/AGENTS.md` | pi: its agent directory, read regardless of working directory |
| `~/.claude/CLAUDE.md` | Claude Code: its global memory file |
| `~/.config/opencode/AGENTS.md` | opencode: its config directory |

pi's context-file names are `AGENTS.override.md`, `AGENTS.md`, `AGENTS.MD`,
`CLAUDE.md`, `CLAUDE.MD`; it loads them from the agent directory **and** from the
working directory and its ancestors. The box user normally works in `/data`,
whose only ancestor is `/`, so a notice placed in the home directory alone would
be missed; hence the agent-directory copy.

The notice is a task list the agent deletes; `lbx` tracks no state about it.

## Failure modes and their checks

| Failure | Behavior | Check |
|---|---|---|
| Runtime cannot create containers (`time` namespace absent) | Refuse before touching anything, naming the cause and the order | MIG2 |
| Export impossible (no live PID, no home directory) | Fail before creating anything | MIG8 |
| Replacement cannot be created | Fail; remove any partial replacement; original untouched | MIG8 |
| Replacement never becomes ready | Fail rather than restore into it | (none) |
| Restore fails | Fail; remove the replacement; original untouched | (none) |
| Verification fails | Fail; remove the replacement; original untouched | MIG8 |
| One box fails among several | Migrate the others, report the failure, exit non-zero | MIG9 |
| Box already migrated | Skipped | MIG13 |

## Environment seams

| Variable | Effect |
|---|---|
| `LBX_STATE_DIR` | Where the launcher looks for sessions. Set explicitly when running under `sudo` without `-E` |
| `SUDO_USER` / `SUDO_UID` | Detected to explain a state-directory mismatch, and to decide whether privilege dropping is needed |

## Test map

`tests/test_llm_in_a_box_migrate.sh`: MIG1 to MIG15. The checks that drive real
containers and restart the real sysbox daemons require docker, `sysbox-runc`,
`llm-in-a-box:sysbox`, and root or passwordless `sudo`; they `skip` (never
`fail`) with a message naming what is missing. Per-check descriptions are in the
file's header and in [../sysbox-migration.md](../sysbox-migration.md).

Two test-harness facts that are easy to get wrong:

- The real-migration checks call `migrate_real`, which wraps the launcher in
  `as_root`. The reporting checks call `migrate`, unprivileged, because `sudo`
  resets `PATH` and would break the PATH seam MIG2 uses to stand in an old
  `sysbox-runc`.
- When the suite runs as root the scratch tree is root-owned, but the migration
  creates the replacement as the box user, so the suite chowns its scratch tree
  to that user first. Production never sees this: the state directory belongs to
  the invoking user.
