# 013: The box's own VM images live in the launcher's state directory, not in the project directory

### Status

Accepted (2026-09-29). This record supersedes the earlier storage
placement rules, which put the box's own VM files in the project directory.

### Context

The project directory that a session mounts into the guest as `/data` has a
subdirectory, `vms_and_docker_from_llm_box`, whose purpose is to hold the
bulky state that things **running inside a box** create: nested VM disk
images the agent builds, and Docker/containerd data. That was the whole of
the directive, and that purpose is unchanged.

The agent generalized it into a rule about **host-side** artifacts, and moved
the box's own VM files into the project directory: base images built by
`./build vm` were repointed from the state directory to
`$PWD/vms_and_docker_from_llm_box` (in `build`, and with them the transient
staging and the base garbage collection), and the per-session overlay was
repointed to `$PWD/vms_and_docker_from_llm_box/sessions/<name>/overlay.qcow2`
while the liveness and stop paths kept resolving the same overlay through the
session's recorded origin.

That made every host-side artifact path depend on the working directory,
with these results: a base built in one project directory is invisible to
`lbx` run in another, and there is no discovery, registry or override to
find it; relaunching an existing session from another directory finds the
base record (session metadata is global, keyed by session name) but not the
base file, and fails with `records base image '<timestamp>', but it no longer
exists`, which is false; the agent inside a box can read and write the image
its own VM booted from, and its live overlay, through the `/data` mount; and
every project pays for its own multi-gigabyte base rebuild.

### Decision

1. **Base images are host-wide.** `./build vm` writes
   `bases/<timestamp>/{base.qcow2,vmlinuz,initrd.img,built-user,from-image}`
   and moves the `bases/latest` symbolic link, under the launcher's state
   directory: `LBX_STATE_DIR` if set, otherwise the configuration file's
   `state.dir`, otherwise `$HOME/.llm-in-a-box`. The build does not read the
   working directory at all. `build` and the launcher resolve this path from
   one single source of truth — the launcher — in the same way they already
   resolve image names, so a configuration change can never split them.
2. **Session overlays live beside session metadata.** The host-side overlay
   is `sessions/<name>/overlay.qcow2` inside that same state directory, as it
   was before. Every session-scoped path — metadata, base record, seed,
   process identifier file, overlay — is derived from the session name in one
   root, never from the working directory.
3. **The project directory holds only the box's project artifacts.** In
   `<project>/vms_and_docker_from_llm_box`: the Docker store image (the guest
   sees it as an attached block device, never as a file), the first-reader
   message, and the bulky state created inside the box. `<project>` is the
   session's recorded first-launch directory for an existing session and the
   launch directory for a new one — the same rule that decides what `/data`
   mounts, so the mount and the artifacts can no longer disagree.
4. **One box per project directory.** The store image keeps its single-writer
   lock; a second box in the same project is refused with a message naming
   the image. This limitation is accepted.
5. **Transient build staging stays two-tier:** the bulk root filesystem
   archive under the state directory's `tmp`, the ownership-critical work
   (extraction, the raw base disk, filesystem creation) on local scratch,
   because some state directories may be exported over a share that refuses
   ownership changes to root.

### Consequences

- Positive: one base image serves every project on the machine.
- Positive: the box agent can no longer reach the image its own VM booted
  from, or its live overlay, through the `/data` mount.
- Positive: launching, attaching, stopping and destroying are independent of
  the shell's working directory, and the "built elsewhere" failure and its
  false error message disappear.
- Negative: existing tests that pin the old placement must change; that
  change requires explicit operator approval under project invariant 4.
- Negative: the store image's single-writer lock now limits one box per
  project directory; concurrent boxes in one project are refused.
- Unchanged: the unattended-run refusals. A run's data directory is already
  refused when it overlaps the state directory or the project artifact
  directory, and base images now sit inside the state directory, so that
  refusal continues to cover them; no refused-overlap set grows or shrinks.
- Unchanged: base image garbage collection still removes only bases that no
  session overlay references and that are not `latest`, with the fail-safe
  skip when an overlay's backing file cannot be read; it now inspects
  overlays and bases in the same root.
- Amended (2026-10-24): the reference scan reads each overlay with
  `qemu-img info -U` (`--force-share`). A RUNNING session's qemu holds a
  write lock on its overlay, and a plain read-only open asks for a shared
  lock and fails — which was indistinguishable from a damaged overlay, so
  the fail-safe skipped every rebuild while a vm session ran and no base was
  ever collected. The fail-safe still covers a genuinely unreadable
  overlay, and the log line now carries `qemu-img`'s reason. The
  `bases/*.tmp` staging sweep runs before the scan, so a failed build's
  leftovers are cleaned even when the scan gives up.
- Amended (2026-10-24): `from-image` records the image **id** next to the
  ref, and the vm preflight compares ids when both are known, so a rebuild
  under the same tag is no longer invisible. Two consequences: identical
  content under a renamed ref is not reported (it is not a difference), and
  the ref comparison — used only for bases without an id line — resolves a
  recorded repo digest against the configured image's own digest. That
  second part exists because Docker 29 reports a repo digest even for a
  locally BUILT image, so the earlier "RepoDigests is empty for local
  builds" assumption produced a spurious "built from a different image"
  warning on every launch (measured against docker 29.9.2).
- Not migrated: base images and overlays already written into project
  directories are left where they are, for the operator to remove.

### For LLMs

- One root for host-side VM state: the launcher's state directory. Base
  images, session overlays, session metadata, transient build staging and
  the base garbage collection all resolve from it.
- One root per project for in-box artifacts:
  `<project>/vms_and_docker_from_llm_box` holds the Docker store image, the
  first-reader message and what the box creates inside itself. `<project>` is
  the recorded origin for an existing session, the launch directory for a new
  one.
- Never derive a base image, overlay or store image path from the current
  working directory for an existing session.
- `build` and the launcher must never resolve the state directory by
  different rules; the launcher's resolved value is authoritative.
- The two-tier transient staging rule is independent of this decision and
  stays.
