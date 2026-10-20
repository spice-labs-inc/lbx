# The sysbox runtime

`--runtime sysbox` runs the box in a **system container** provided by
[Sysbox](https://github.com/nestybox/sysbox). The box has its own user
namespace, its own Docker daemon (Docker-in-Docker) and its own init, so it
behaves much more like a small machine than a plain container does — without
needing KVM, which is what the `vm` runtime needs.

This document covers what is specific to sysbox: the version and package
requirements, how ownership works inside a fake-root box, and the one failure
mode that is easy to mistake for a permissions problem.

Behavior claims here name the check that verifies them
(`tests/test_llm_in_a_box_sysbox.sh`, labels `SYS1`-`SYS8`). Statements that
are operational guidance rather than verified behavior are marked as such.

## Requirements

| Requirement | Why |
|---|---|
| Sysbox CE **0.7.1 or later** | Below it, sysbox cannot run on current Docker (SYS1) |
| The **fuse3** package (`fusermount3`) | `sysbox-fs` is a FUSE filesystem and needs the helper; the `sysbox-ce` package does not install it (SYS2) |
| Any current Docker | The version that matters is sysbox's, not Docker's (SYS8) |
| On Ubuntu 25.04 and later: the **fusermount3 AppArmor override** in `apparmor/fusermount3-sysboxfs` | Those releases confine `fusermount3`; the shipped profile denies FUSE mounts under `/var/lib/sysboxfs`, so no box can be created until it is allowed |

Install:

```bash
wget https://downloads.nestybox.com/sysbox/releases/v0.7.1/sysbox-ce_0.7.1-0.linux_amd64.deb
sudo dpkg -i sysbox-ce_0.7.1-0.linux_amd64.deb
sudo apt-get install -y fuse3
sudo install -m 644 apparmor/fusermount3-sysboxfs /etc/apparmor.d/local/fusermount3
sudo apparmor_parser -r /etc/apparmor.d/fusermount3
docker info | grep sysbox
```

The two AppArmor lines are needed on Ubuntu 25.04 and later and harmless
elsewhere: they fail with "No such file" on a host without the profile and
change nothing.

### Why 0.7.1 is the minimum

containerd 2.x (Docker 28+) asks the runtime which Linux namespaces it
supports, and strips from the container specification any namespace the
runtime does not declare. `sysbox-runc` 0.7.0 does not declare `time`, so
every container create fails:

```
OCI runtime create failed: namespace {"time" ""} does not exist
```

0.7.1 declares it. `lbx` checks the declaration rather than a version string —
it is the actual cause, and the check holds for any build that declares it
(SYS1). The launcher refuses a runtime that does not declare it, with a
message naming the minimum version.

### Why `fusermount3` is needed

`sysbox-fs` is a FUSE filesystem, and FUSE needs a mount helper. The
`sysbox-ce` package declares a dependency on `fuse` — version 2 — but
`sysbox-fs` calls `fusermount3`, which the **fuse3** package provides. Without
it, every container create fails with

```
failed to pre-register with sysbox-fs: rpc error: code = Internal
desc = Initialization error for container-id <id>
```

and `sysbox-fs` logs the real cause:

```
level=error msg="fusermount: exec: \"fusermount3\": executable file not found in $PATH"
```

`lbx` checks for the binary before creating a container and refuses with a
message naming the package (SYS2), so this appears as a clear error instead of
a cryptic OCI failure.

### Why the fusermount3 AppArmor override is needed

Ubuntu 25.04 and later ship an AppArmor profile for `fusermount3` with the
fuse3 package. It allows FUSE mounts only under user-facing paths (the home
directory, `/mnt`, `/media`, `/tmp`, the user runtime directory). `sysbox-fs`
mounts its filesystem under `/var/lib/sysboxfs/<container id>/`, so every
box creation fails with the same `failed to pre-register with sysbox-fs`
error as a missing `fusermount3`, `sysbox-fs` logs

```
mount helper error: fusermount3: mount failed: Permission denied
```

and the kernel audit log names the profile:

```
apparmor="DENIED" operation="mount" info="failed mntpnt match" profile="fusermount3" name="/var/lib/sysboxfs/<id>/" fstype="fuse" srcname="sysboxfs"
```

The shipped profile ends with `include if exists <local/fusermount3>`, so
the fix is a local override that allows mounts and unmounts under
`/var/lib/sysboxfs` only, installed as `/etc/apparmor.d/local/fusermount3`
and kept across fuse3 package updates. `apparmor/fusermount3-sysboxfs` is
that file. `lbx` cannot see the denial before creating the container, so
when a create fails with the pre-registration error it prints the
`sysbox-fs` log command and these install lines (a unit test holds the
message to the error text).


## How ownership works inside a sysbox box

A sysbox box is **fake root**: the box's user id 0 maps to an unprivileged
host id (for example 165536), and the box's files are owned by that host id on
disk. Sysbox applies a **filesystem ID mapping** to the box's rootfs so that
host uid 0 appears as container uid 0. This is what lets a fake-root box have
root-owned, setuid binaries that work.

If that mapping is absent, host uid 0 falls outside the box's mapped range
(the box can only translate its own range, e.g. 165536-231071) and the kernel
reports the **overflow id 65534**, which is `nobody`. Files that are really
root-owned then read as owned by `nobody`.

## The daemon-restart failure

This is the failure mode to know about, because it looks like a permissions
problem and is not one.

### Symptom

Inside the box, sudo refuses to run:

```
sudo: /etc/sudo.conf is owned by uid 65534, should be 0
sudo: /usr/bin/sudo must be owned by uid 0 and have the setuid bit set
```

### What is actually wrong

Nothing is wrong with the files. From the host, the same files are owned by
uid 0 with their setuid bits intact; only the box's view is wrong, because the
ID mapping is not in effect. Confirm it:

```bash
S=<session>
# The host's view (0 = correct)
sudo stat -c '%u %g %a' /proc/$(docker inspect -f '{{.State.Pid}}' $S)/root/etc/sudo.conf
# The box's view (65534 = the mapping is missing)
docker exec -u 0 $S stat -c '%u %g %a' /etc/sudo.conf
```

### Cause

`sysbox-mgr` and `sysbox-fs` keep per-container state **in memory**, including
the ID mapping. Restarting them — `systemctl restart sysbox`, a host reboot, a
package upgrade — wipes that state for containers that already exist, and the
box's next start comes up without its mapping. `sysbox-fs` records the moment
it happens:

```
level=warning msg="Received seccompNotifMsg generated by unknown container: <id>"
```

The damage is **latent**: the box keeps working until it is restarted, and the
failure appears on the *next* start. That is why it looks as though
re-entering the box broke it, when in fact something restarted the daemons
while the box was running.

### Remedy

The box cannot be repaired in place: nothing inside it can restore the missing
ID mapping, because the container's uid 0 maps to an unprivileged host uid that
does not own the files. The container has to be rebuilt.

**Rebuilding loses nothing, because `lbx --migrate` carries the box's home
directory across.** That is where the agent sessions live (pi, Claude Code,
opencode), so a migrated box resumes them:

```bash
sudo -E lbx --migrate <session>          # or --all, or --dry-run first
```

Migrating by hand means `lbx --destroy` followed by a fresh `lbx --runtime
sysbox`, which does lose everything the box accumulated outside `/data`. See
[sysbox-migration.md](sysbox-migration.md) for what a migration carries, what it
cannot carry, and the ordering (upgrade sysbox first, then migrate).

Verified: the recreated box has correct ownership (`0 0 644` for
`/etc/sudo.conf`) and a working sudo (SYS4). A healthy box is never reported
as damaged, across plain stop/start and kill/start cycles (SYS5).

### What `lbx` does about it

`lbx` detects the condition when you attach to a running box or start a
stopped one, and refuses with an explanation naming the cause and the remedy,
instead of handing over a terminal whose sudo cannot work (SYS3). The
detection reads one file's owner as the box sees it — it needs no privileges,
parses no sysbox logs, and is a no-op for the `docker` and `vm` runtimes,
which have no ID mapping to lose.

## Operational guidance (not tested claims)

- **Do not restart the sysbox daemons on a host with running boxes** unless
  you intend to recreate them. If you must (a package upgrade, a wedged
  daemon), **migrate** every box afterwards; that preserves their home
  directories. Recreating them by hand does not.
- A host reboot restarts the daemons, so boxes that were running before a
  reboot should be migrated rather than restarted.
- The `sysbox-mgr` startup cleanup can keep sysbox down for a long time on a
  host with heavy in-box Docker use; that is a separate failure, described in
  the project README's Troubleshooting section.

## Test map

| Check | What it verifies |
|---|---|
| SYS1 | The installed `sysbox-runc` declares the `time` namespace (why 0.7.1 is the minimum) |
| SYS2 | The launcher refuses to launch without `fusermount3`, naming the package; and does not report it when present |
| SYS3 | The reproduction: a daemon restart plus a box restart damages the box, and the launcher refuses to attach, naming the cause and the remedy |
| SYS4 | The remedy works, and the launcher does not report a freshly recreated box as damaged |
| SYS5 | A healthy box is not reported as damaged after stop/start and kill/start cycles |
| SYS6 | A second start leaves `/etc/passwd`, `/etc/group` and `/etc/sudoers.d/agent` byte-identical and logs no rename failure |
| SYS7 | Over repeated start/stop cycles no cycle re-runs the user rename, and the identity state stays intact |
| SYS8 | A box launches with the host's current Docker (why no Docker pin is needed) |
