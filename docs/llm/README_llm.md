# llm-in-a-box — LLM Reference

## What This Project Is

A Docker container image + host launch script for running Claude Code (and
Pi/OpenCode/OMP) in `--dangerously-skip-permissions` mode with configurable
host isolation. Three runtimes:

| Runtime | Isolation | When used |
|---|---|---|
| `vm` | Full KVM VM (qemu, own kernel, own dockerd) | **Default — auto-selected whenever the vm image is built** |
| `sysbox` | User-namespace + syscall virtualization | Linux hosts without KVM |
| `docker` | `--privileged` DinD container | macOS/Windows (Docker/Rancher Desktop), or FUSE needs |

Exception: unattended runs (`lbx --run`, docker runtime only, explicit)
use an unprivileged run box with no inner docker, not the privileged DinD
container (tests/test_llm_in_a_box_run.sh RUN2, RUN12;
tests/verify-run-unattended.sh VRUN2, VRUN10). See
[unattended-runs_llm.md](unattended-runs_llm.md).

## Key Files and Their Roles

| File | Purpose |
|------|---------|
| `lbx` | The launcher (a Rust binary, built from the crate at the repository root). `--runtime sysbox\|docker\|vm` or auto-detect. Creates/starts/attaches sessions. vm lifecycle: qemu launch, ssh attach (lands in `/data`), `--shutdown` (graceful, resume-able), `--destroy`. Cross-runtime session management: a name maps to one instance across runtimes; existing instance wins over auto-detect; explicit conflicting `--runtime` errors; `--stop`/`--shutdown` accept multiple names (graceful; `--force` kills); `--list` prints NAME/RUNTIME/STATE/PORT; names validated `[A-Za-z0-9][A-Za-z0-9._-]*`; vm sessions record their origin directory and reuse it for the `/data` mount on relaunch. Legacy-duplicate removal: `--runtime` selects the instance for `--destroy`/`--stop`/`--shutdown` of ambiguous names, with sibling notes, conflict guards, and up-front runtime validation — see docs/llm/session-removal-disambiguation_llm.md. Unattended runs: `--run` (one command in a fresh, unprivileged, walled run box, then cleanup; exit code = command's; 125 refusal/setup failure, 124 timeout; outcome in `$LBX_STATE_DIR/runs/<name>/status`; tests/test_llm_in_a_box_run.sh RUN12, RUN14, RUN16, RUN17) and its flags `--data`, `--env`, `--timeout`, plus the opt-in `--socket-dir` (read-only `/run/agent` mount of a caller socket directory: RUN98, RUN99), `--no-network` (instead of `--net-policy`: `--network none`, no relay: RUN103, RUN104) and `--apparmor-profile` (llm-in-a-box AppArmor profile on the run box: RUN109, RUN110) — see docs/llm/unattended-runs_llm.md. Migration: `--migrate [--all] [--dry-run] <name>...` rebuilds existing sysbox boxes on the current stack, carrying `/home/agent` across (needs root or `sudo -E`; tests/test_llm_in_a_box_migrate.sh MIG1-MIG15); see docs/llm/sysbox-migration_llm.md. |
| `docker/vm-docker-store.sh` | Guest first-boot wiring, sourced by `docker/vm-setup.sh`: finds the attached NVMe device (serial `lbx-docker-store`; a base built by the older launcher was given `llm-in-a-box-docker-store`, which is longer than the NVMe serial field holds, so the kernel reports the truncated `llm-in-a-box-docker-` and the finder matches that prefix in the by-id glob, the sysfs serial scan and the identity check: S21, S21b, S22; S20 pins the older `boc-docker-store` serial), formats it only when it carries no filesystem, mounts it at `/srv/docker-store`, points containerd's root and Docker's data-root inside, self-heals this project's earlier config values, uses `--no-block` daemon actions, plants the first-reader README, and marks a fallback. Behavioral checks: tests/test_vm_docker_store.sh S1, S2, S4, S7, S10, S16, S20, S21, S21b, S22. |
| `docker/docker.service.d/llm-in-a-box.conf`, `docker/containerd.service.d/llm-in-a-box.conf` | systemd drop-ins (`After=`/`Wants=llm-in-a-box-setup.service`) so socket-activated daemons cannot start before the store is mounted; the ordering is asserted by tests/verify-vm-e2e.sh E5 (KVM host; deferred here). |
| `build` | Builds images. `./build vm` also produces the bootable base disk + kernel, in the launcher's state directory (`$LBX_STATE_DIR/bases/<timestamp>/`, with `bases/latest`), which it resolves through the launcher's hidden `--print-state-dir` subcommand (ADR 013) — never through the working directory (test_build_vm.sh, "build vm derives nothing from the working directory"; the resolution seam is pinned by the `--print-state-dir resolves env > config file > default` check in test_llm_in_a_box_vm.sh). The rootfs.tar export is staged under `$LBX_STATE_DIR/tmp`. The SCRATCH directory (where the rootfs is unpacked and the 30G base.raw is filled with it) is a `/tmp` scratch by default and `LBX_VM_BUILD_WORK` moves it to another real local filesystem: it needs roughly twice the rootfs size, and a small root disk fills up and kills the build (measured: a 7G rootfs against 12G free; the mkfs output is suppressed under `set -euo pipefail`, so the log simply stops). It must not be the 9p project export (that refuses `chown` to root) while the state directory may be, hence the separation; a caller-supplied scratch is never deleted (test_build_vm.sh, the scratch-directory and placement checks). `./build relay [--label KEY=VALUE]...` adds image labels to the relay build (relay only; the unlabeled call is unchanged). |
| `Dockerfile` | Unified image, `RUNTIME_TYPE` build arg. vm variant adds sshd/kernel/initramfs/iptables + a systemd setup service (`docker/vm-setup.sh`). Installs agents unpinned-latest. |
| `entrypoint.sh` | PID 1 in containers (sysbox/docker). Remaps UID/GID, starts dockerd, drops to user via gosu. With `LBX_NO_INNER_DOCKER=1` (run boxes of unattended runs only): no dockerd, box user removed from the docker group, `/etc/sudoers.d/agent` deleted, `/tmp/.run-ready` written just before the final exec (tests/verify-run-unattended.sh VRUN2, VRUN9, VRUN10; tests/test_llm_in_a_box_run.sh RUN12). |
| `docker/vm-setup.sh` | In-guest systemd oneshot: UID/GID remap from seed, 9p `/data` mount, ssh keys, GH_TOKEN, DNS, sudoers, and the store wiring call. |
| `docker/magic-context.jsonc` | Shipped Magic Context config (historian = `umans/umans-deepseek-v4-flash-0731`, local embeddings), copied to `~/.config/cortexkit/`; the plugin itself is not installed (docs/in-box-agents.md). |
| `tests/` | Behavioral suites (test_*.sh) + runtime integration (verify-*.sh: build-or-reuse image, probe the real artifact); the launcher under test is `LBX_BIN` (or `--lbx` of the suite runner). |
| `tests/test_llm_in_a_box_run.sh` | Unattended runs against a fake docker: refusals, exact docker calls, exit codes and status, cleanup and ownership, name claim, `--env`, signals and timeout, retry schedules, accepted limits (RUN checks), and interactive regression against a stored baseline (REG checks). |
| `tests/verify-run-unattended.sh` | Unattended runs against real docker and the built images: privileges, network wall, `--env` visibility, timeout, signals, SIGKILL recovery and what it leaves, relay hardening, mount-point refusal, accepted limits, the socket directory, no-network run boxes and the AppArmor profile (VRUN checks). Refuses root; a missing prerequisite is a failure, except VRUN25-VRUN28 on a kernel whose AppArmor does not mediate Unix sockets (approved skips, `tests/approved-skips.txt`). |
| `docker/relay/relay.py` | The netwall relay (stdlib Python CONNECT and plain-HTTP proxy): policy matching, deny-by-resolution, SNI check, idle timeout, request read timeout, forwarding of bytes read with the request head, 64-connection cap, deny log; reasons and grammar in docs/llm/unattended-runs_llm.md. |
| `tests/test_relay_resolution.sh` | The relay image alone, with no network (or an internal network with no route out): refused address ranges (seeded property), deny reasons and status codes, lookup failures, idle timeout, connection cap, request read timeout, bytes after the request head (RES1-RES31). Needs docker only once the image exists; `LBX_TEST_RELAY_IMAGE` selects the image. |
| `tests/fake-docker-run.sh` | Wrapper in front of `tests/fake-docker.sh` (unchanged) that models the docker calls of `lbx --run` and injects failures, delays and races. |
| `tests/setup-run-test-host.sh` | Run as root on a test host: creates the test user `lbxtest` and the root-made fixtures under `/srv/lbx-test-fixtures` the unattended-run suites need, and loads the AppArmor profiles of `apparmor/llm-in-a-box-run` (`apparmor_parser -r`, never fatal). |
| `apparmor/llm-in-a-box-run` | Two AppArmor profiles for the run box, loaded by root: `llm-in-a-box-run` (relay runs) and `llm-in-a-box-run-no-network` (no internet sockets). Intended: docker-default's rules with writes (and so pathname-socket connects) only in `/run/agent`, `/data`, `/tmp`, `/var/tmp`, `/dev/shm`, the home directory and listed system paths, and abstract and unnamed Unix sockets only among processes under the same profile; to be verified by tests/verify-run-unattended.sh VRUN25-VRUN28, which run only on kernels that mediate Unix sockets (no real-docker evidence yet; two design assumptions doubted, see unattended-runs_llm.md known limits). `lbx` never calls `apparmor_parser` (tests/test_llm_in_a_box_run.sh RUN109). |
| `tests/capture-interactive-baseline.sh`, `tests/interactive-baseline-lib.sh`, `tests/fixtures/interactive_baseline/` | Capture and stored results of interactive scenarios from the launcher before unattended runs existed; REG1, REG2 and RUN38 compare against them, and REG3 runs the same scenarios to count label queries. |
| `claude-settings.json`, `update-claude-code.sh` | Claude Code settings copied to the box user's `~/.claude/settings.json` (deny rules for mutating git commands), and the in-box `update-claude-code` command. What the image installs: docs/in-box-agents.md. |

## Installed Agents & Plugins

- **Claude Code** — `@anthropic-ai/claude-code` (unpinned)
- **Pi** — `@earendil-works/pi-coding-agent` (unpinned; `@mariozechner/...`
  was renamed at 0.74.0 and is deprecated). Plugins baked in via
  `pi install npm:<pkg>` (live under `~/.pi/agent/npm/node_modules`, not
  the npm global tree): `pi-provider-umans` (dynamic Umans model catalog),
  `@cortexkit/aft-pi` (hoists read/write/edit/grep; `aft` binary from
  `@cortexkit/aft-linux-x64`, symlinked to /usr/local/bin),
  `pi-web-access` (web search/fetch/extraction).
- **OpenCode** — `opencode-ai` (unpinned); **OMP** — `@oh-my-pi/pi-coding-agent`
  (Bun-only runtime; Bun installed).
- **No pre-config**: the thinking-mode provider configs
  (opencode-config.json / omp-models.yml / omp-config.yml) were removed.
  Agents run from their own defaults.
- `umans` CLI for Umans.ai auth.

## Auto-Detection Logic

When `--runtime` not specified:
1. **vm image built** (`$LBX_STATE_DIR/bases/latest`
   with base.qcow2 + vmlinuz; the legacy flat layout at the state directory
   root, `$LBX_STATE_DIR/base.qcow2` + `vmlinuz`, is still accepted) → **vm**
   (readiness NOT checked here; `vm_preflight` is the single source of
   truth and fails with fix-it guidance + an override hint if the host
   cannot run it)
2. The CONFIG-RESOLVED sysbox image (default `llm-in-a-box:sysbox`;
   see "User-supplied images" below) + sysbox-runc → sysbox
3. The CONFIG-RESOLVED docker image (default `llm-in-a-box:docker`) +
   docker → docker
4. Fallback: `llm-in-a-box:latest`; else error with build instructions

Precedence: vm > sysbox > docker. Explicit `--runtime` always wins.
Auto-detection keys on the CONFIG-RESOLVED image names:
tests/test_llm_in_a_box_config.sh CFG21 (docker leg, sysbox leg,
guided-error leg).
Detection and guided-failure behavior: tests/test_llm_in_a_box_vm.sh
("auto-detect selects vm when the vm image is built, then fails with
guidance when prereqs are missing", "auto-detect never selects vm when
the vm image is NOT built").

## VM Runtime Mechanics (LLM summary)

- Session = qemu process on a COW overlay of the shared base disk; both the
  box-state session dir and the overlay are under
  `$LBX_STATE_DIR/sessions/<name>/` (`bases/<timestamp>/base.qcow2` holds
  the shared base; ADR 013). The base disk and the overlay are
  plain host files opened by qemu as the invoking user; the launcher
  creates the overlay with `qemu-img` (tests/test_llm_in_a_box_vm.sh L9
  runs the real launcher and records the qemu argv; L9d asserts the
  overlay is a regular file owned by the invoking user, that it lands in
  the state directory and not in the project directory, and that qemu runs
  as that user).
- Liveness = `pgrep -f` on the overlay path (pidfile pid is fallback only;
  qemu -daemonize can leave stale pidfiles → "Cannot lock pid file" was a
  real bug, fixed 2026-09-01). Live qemu ⇒ attach, never relaunch.
- Boot: `-enable-kvm -cpu host -kernel/-initrd`, user-net hostfwd for ssh
  (2222-2321) / `--ports` / `--publish` / `--vm-web-port` (vm runtime:
  hostfwd to the box VM; sysbox/docker: `docker -p` + in-guest DNAT); 9p
  `host0` → `/data`; seed via
  9p `seed0` + fw_cfg fallback; the Docker store image attached as an NVMe
  device (see VM Storage and Boot).
- Host configurables have env-key parity: `LBX_*` env vars and the
  config file keys (`state.dir`, `vm.mem`, `vm.cpus`, `vm.accel`,
  `vm.store.size`, `vm.store.disable`, `vm.missing`, `runtime.default` —
  see `lbx --help` / README); precedence CLI > env > config > default
  (pinned by tests/test_llm_in_a_box_vm.sh L9f, LG10a-c).
- Attach: `ssh -t ... "cd /data 2>/dev/null || true; exec bash"`.
- Shutdown: detached `sudo -n poweroff` with delay + `timeout`-bounded ssh
  (inline poweroff hung the client — qemu user-net drops without FIN),
  then ACPI via monitor socket, then force-kill.
- Preflight validates qemu-system-x86_64 (and fails with upgrade guidance
  below the 5.0 floor required by `-device nvme` — tests/test_llm_in_a_box_vm.sh,
  "a qemu below the 5.0 floor fails the preflight with upgrade guidance"),
  qemu-img, /dev/kvm, kvm group (the last two skipped under
  `LBX_VM_ACCEL=tcg`; tests/test_llm_in_a_box_vm.sh L7 and L7c, the
  latter through the real launcher), ssh, base disk
  (+ qcow2 format — `qemu-img info` prints lowercase `qcow2`; match
  case-insensitively), kernel, ssh pubkey.
- Test-only override `LBX_VM_MISSING` (mirrors `BUILD_VM_MISSING`): forces
  prereqs to report missing; can never weaken the preflight.
- **Remap hazard (2026-09-02 bug, fixed)**: the first-boot uid/gid remap
  (`docker/vm-setup.sh`, mirrors `entrypoint.sh`) deletes any group whose
  gid equals the seed's TARGET_GID. The image's docker group gid collided
  with a nested seed's target gid, so the docker group was deleted and
  `docker.socket` failed with 216/GROUP on the resumed boot (dockerd
  never started). Both scripts now recreate the docker group after the
  remap; regressed by verify-vm-e2e.sh (first-boot + post-resume
  `id -nG` and docker-info checks).
- **Base images (2026-09-03)**: immutable, versioned, GC'd — `bases/<ts>/`
  triples staged by ./build vm with a `latest` symlink; sessions record
  their base and relaunch on it (never rebase); GC removes bases no
  overlay references (fail-safe on unreadable overlays); running sessions
  keep their base across rebuilds; the legacy flat layout still works.
  tests/test_build_vm.sh covers the GC checks.

## VM Storage and Boot

Storage is split into two deliberate concerns (ADR 013, 2026-09-29):

- **HOST-SIDE VM STATE** — base disks (`$LBX_STATE_DIR/bases/<timestamp>/
  base.qcow2`), session overlays (`$LBX_STATE_DIR/sessions/<name>/
  overlay.qcow2`), and the session metadata — lives in the launcher's
  state directory (`LBX_STATE_DIR` > `state.dir` config key >
  `~/.llm-in-a-box`), keyed by session name and machine-wide: one base
  serves every project, and a relaunch from any directory resolves the same
  base and overlay (T6; L10 resolves a base with cwd=/; L11 relaunches from
  another directory; L12 refuses a session whose overlay is still in the old
  project-directory location rather than booting it on a fresh disk).

- **PER-PROJECT ARTIFACTS** live in **one fixed, NON-CONFIGURABLE
  subdirectory of the project directory** (the directory mounted into the
  guest as `/data`): `vms_and_docker_from_llm_box`. It holds
  `docker-store.img` and the first-reader README telling the in-box agent why
  it exists, plus the bulky state created INSIDE the box (nested VM images).
  A global location would collide across projects, so these are per-project (L4
  asserts the store path; L6b asserts two project roots get independent
  images and locks). The launcher creates the overlay with `qemu-img`
  (tests/test_llm_in_a_box_vm.sh L9 runs the real launcher with a recording
  fake qemu; L9d asserts the overlay's user ownership and qemu's invoking
  uid).

- **PRE-ADR-013 SESSIONS ARE REFUSED, NEVER SILENTLY REPLACED:** if a
  session's overlay (L12) or the base it recorded (L13) is still under the
  project directory, the launch stops, names the old file, and prints the
  move command. Files are never migrated automatically.

- **PROJECT DIRECTORY:** the directory mounted as `/data`. For an existing
  session it is the session's recorded first-launch directory; for a new
  session it is the launch directory. The mount and the per-project artifacts
  therefore always agree (L11). The recorded origin is stored in
  `$LBX_STATE_DIR/sessions/<name>/origin`.
- **Attachment:** the image is attached to the guest as an NVMe device
  with serial `lbx-docker-store` (`-drive ...,if=none,id=store0` plus
  `-device nvme,drive=store0,serial=lbx-docker-store`;
  tests/test_llm_in_a_box_vm.sh L1). A base built by the older launcher was
  given `llm-in-a-box-docker-store`, and the NVMe serial field holds 20
  characters, so such a guest sees the truncated `llm-in-a-box-docker-` and
  the word `store` appears nowhere in the device's identity; the finder
  matches that truncated prefix too (tests/test_vm_docker_store.sh S21,
  S21b, S22). There is no `store0` 9p export (L2).
  A second virtio-blk was rejected because it steals `/dev/vda` and breaks
  `root=/dev/vda`; tests/verify-vm-e2e.sh E1b asserts the root device is
  still `/dev/vda` (KVM host; deferred here).
- **First-boot format:** inside the guest, `docker/vm-docker-store.sh`
  finds the device with a bounded wait and `modprobe nvme` (by-id glob
  and sysfs serial fallbacks), validates it (it must be a block device
  and must never be the guest root device; tests/test_vm_docker_store.sh
  S13), and formats it with ext4 only when `blkid` reports no filesystem
  and `wipefs -n` finds no signature (S1, S17; bounded probes S19). An
  existing ext4 filesystem is never reformatted (S2); any other
  signature is never formatted (S17). The default device path carries
  the `lbx-docker-store` serial (tests/test_llm_in_a_box_vm.sh L1 pins the
  request); the by-id glob and the sysfs serial scan also accept the
  truncated `llm-in-a-box-docker-` of a base built by the older launcher and
  the pre-rename `boc-docker-store` (S20, S21, S21b), and the identity check
  accepts the truncated form while still refusing an unrelated disk (S22).
- **Mount and roots:** the filesystem is mounted at `/srv/docker-store`
  (`LBX_STORE_MNT`), and containerd's `root` and Docker's `data-root`
  point at `/srv/docker-store/containerd` and `/srv/docker-store/docker`
  (S1, S7). A dirty ext4 filesystem gets one bounded `e2fsck -p` retry
  before fallback (S6). The `daemon.json` merge preserves every other key
  (netwall proxies, user values) and never writes
  `storage-driver`/`snapshotter` (S7, S8, S11, S18); a malformed
  `daemon.json` is backed up before any rewrite (S9, S9b); the earlier
  plain-directory values this project wrote are self-healed and genuine
  user values are preserved (S8).
- **Ordering:** every daemon start/restart from the setup unit is
  `systemctl --no-block` after `reset-failed` (S3, S10), and the two
  drop-ins order docker/containerd after the setup unit so a
  socket-activated daemon cannot start before the store is mounted.
  tests/verify-vm-e2e.sh E5 asserts the unit and drop-in ordering on a
  real boot (KVM host; deferred here).
- **Fallback:** if the device is missing, invalid, or unmountable, the
  wiring removes its own root lines, leaves the daemons on local
  defaults, and touches `/run/llm-in-a-box-store-fallback` (S4, S5,
  S14); `LBX_VM_STORE_DISABLE=1` skips the store entirely (L4b). A
  disabled boot keeps local Docker and shows the marker
  (tests/verify-vm-e2e.sh E8, KVM host; deferred here). A successful run
  clears a stale marker (S3).

**Verified only on a KVM host** (tests/verify-vm-e2e.sh; deferred here):
E1 (by-id device, ext4 mounted at `/srv/docker-store`), E1b (root stays
`/dev/vda`), E2 (memory mapping inside the store), E3a/E3b (containerd
healthy, Docker on the overlayfs snapshotter, pull+run busybox and redis
with non-root files), E4a (host image regular, user-owned, mode 0600,
holds data), E5 (ordering),
E6 (boot health, no chown/Lchown errors), E7 (a pulled image survives
shutdown/resume and the same image file is reused), E8/E8b/E8c/E8d
(disabled boot falls back to local Docker with the marker; deleting the
image makes the next boot reformat it and Docker work; filling the store
grows the host allocation; `fstrim` returns the blocks).

## VM Storage Operations and Troubleshooting

- **Verify a new box:** in the guest,
  `findmnt -no FSTYPE,SOURCE /srv/docker-store` must show ext4 from the
  store NVMe device (the source reads as the resolved device name such as
  `/dev/nvme0n1`, not as a by-id path: util-linux resolves the source before
  mounting; tests/verify-vm-e2e.sh E1), `docker info` must show
  `Docker Root Dir: /srv/docker-store/docker`, and
  `/run/llm-in-a-box-store-fallback` must be absent (the success path
  clears a stale marker: tests/test_vm_docker_store.sh S3; a real boot
  asserts it: tests/verify-vm-e2e.sh E1, E3a, E6; KVM host, deferred
  here). On the host, the image path is recorded at
  `$LBX_STATE_DIR/sessions/<name>/store-img`
  (tests/test_llm_in_a_box_vm.sh L3d, L9b); `stat -c '%U %a'` shows the
  invoking user and `600` (tests/verify-vm-e2e.sh E4a; KVM host, deferred
  here).
- **Device missing:** the guest journal shows "store device not found or
  invalid" and the fallback marker exists; the box runs on local Docker
  (tests/test_vm_docker_store.sh S4). Check that qemu was launched with
  the NVMe drive/device (tests/test_llm_in_a_box_vm.sh L1) and that the
  launcher did not refuse the image (image refusals L3b/L3c/L3e/L5,
  single-writer lock L6).
- **Mount or fsck failure:** the wiring runs one bounded `e2fsck -p` and
  falls back if the retry fails (tests/test_vm_docker_store.sh S6).
  Persistent failure: stop the VM, move the image aside if its data
  matters, delete it, and relaunch — the guest formats a fresh image
  (tests/verify-vm-e2e.sh E8b; KVM host, deferred here).
- **Image full (operational guidance):** Docker reports ENOSPC inside
  the guest. Free space in the guest (`docker system prune`) or enlarge
  the store: stop the VM,
  delete the image, and relaunch with a larger `LBX_VM_STORE_IMG_SIZE`
  (this discards the Docker data). The 500G default is a default, not an
  enforced boundary (tests/test_llm_in_a_box_vm.sh L3, L3f).
- **Fallback marker:** `/run/llm-in-a-box-store-fallback` means the
  guest is on local Docker (`Docker Root Dir: /var/lib/docker`); the next
  successful store boot clears the marker (tests/test_vm_docker_store.sh
  S3, S4).
- **Read the journals (operational guidance):** in the guest,
  `journalctl -u llm-in-a-box-setup -u containerd -u docker -b`; the
  setup wiring also logs to ttyS0, captured at
  `$LBX_STATE_DIR/sessions/<name>/console.log`. Host-side launcher and
  qemu failures are printed by the launcher and on qemu's stderr.
- **Obsolete state (operational guidance; no automated check asserts
  it):** after the image rebuild and a verified boot, the old
  `containerd/` and `docker/` trees under the host0 store directory are
  unused and safe to delete.

## Host-side sysbox failures (operational reference)

Applies to the `sysbox` runtime only, and **no check in `tests/` asserts any of
it**: it describes sysbox and Docker on the host, not `lbx` or the box. It is
recorded because this failure mode looks like an `lbx` bug and dead-ends the
operator. Host-level sysbox checks are an approved skip in the session suite
(`tests/approved-skips.txt`: `test_llm_in_a_box_sessions.sh|T18 destroy`),
because the continuous-integration hosts have no sysbox runtime. The human
counterpart is README.md "Troubleshooting" → *"failed to register with
sysbox-mgr"*.

- **Symptom.** A box will not start; Docker reports `OCI runtime create failed:
  failed to register with sysbox-mgr: failed to invoke Register via grpc: ...
  dial unix /run/sysbox/sysmgr.sock: connect: no such file or directory`.
  `/run/sysbox` is tmpfs and each boot wipes it, so *no such file or directory*
  means `sysbox-mgr` has not run since boot; *connection refused* would mean a
  stale socket file with a dead daemon behind it.
- **The misleading check.** Registration is all `docker info` reports (the
  `Runtimes` map), and in this state the runtime *is* registered: the error text
  is emitted by `sysbox-runc` itself, which Docker dispatched the container to.
  So `docker info | grep sysbox` passes, and the operator sees Docker's error
  rather than a runtime-selection message.
- **Diagnose (host).** `systemctl status sysbox-mgr sysbox-fs`;
  `journalctl -u sysbox-mgr -b --no-pager | tail -50`.
- **Case 1 — daemons stopped.** `sudo systemctl restart sysbox`; upstream
  documents `sysbox.service` as the top-level unit that starts, stops and
  restarts Sysbox (`sysbox-mgr.service` carries `PartOf=sysbox.service`).
  Success = `Active: active (running)`, `Ready ...` in the journal,
  `/run/sysbox/sysmgr.sock` present.
- **Case 2 — killed mid-cleanup (the one that recurs).** `systemctl status`
  shows `Active: failed (Result: timeout)`, `start operation timed out`, and a
  large CPU/memory peak (observed on sysbox-ce 0.6.7: ~32 s CPU and ~600 MB
  against `TimeoutStartSec=45`). Mechanism, from the sysbox-mgr source at the
  commit its binary reports (`main.go` → `mgr.go:newSysboxMgr` →
  `utils.go:setupWorkDirs` → `utils.go:cleanupWorkDirs`): the startup path
  unmounts anything left mounted under the data root and then
  `os.RemoveAll(<data root>)`s the entire tree — the volumes backing every
  box's inner `/var/lib/docker`, `/var/lib/buildkit`, `/var/lib/kubelet`,
  `/var/lib/containerd`, and the k8s flavours. A long uptime with heavy in-box
  Docker use grows that tree without bound (one host: 208 GB / 8.1 M inodes,
  190 GB of it a single volume whose container no longer existed), so the wipe
  cannot fit in the start timeout; systemd SIGTERMs the daemon and each retry
  clears only another 45-second slice, so the box stays unstartable for as long
  as the tree takes to clear.
- **Confirm it read-only (host).** `du -sh /var/lib/sysbox`;
  `du -s --inodes /var/lib/sysbox/docker /var/lib/sysbox/buildkit`;
  `findmnt -R /var/lib/sysbox` (a manual wipe is only safe when nothing is
  mounted there and no sysbox box is running — `docker ps` shows them all
  `exited`).
- **Remediation.** Both variants destroy the inner Docker/BuildKit state of
  every sysbox box on that host (their own filesystems, bind-mounted project
  directories such as `/data`, and the host's `/var/lib/docker` are untouched).
  A: a drop-in with `[Service]` `TimeoutStartSec=infinity` on `sysbox-mgr`,
  `systemctl daemon-reload`, `systemctl restart sysbox-mgr`, then wait for the
  wipe. B: `systemctl stop sysbox sysbox-fs sysbox-mgr`, `rm -rf
  /var/lib/sysbox`, `systemctl start sysbox`. Post-conditions: the data root
  holds only the per-volume directories (`buildkit/`, `containerd/`, `docker/`,
  `k0s/`, `kubelet/`, `rancher-k3s/`, `rancher-rke2/`, `shiftfs/`) with no
  per-container volumes inside, `sysbox-mgr` is `active (running)`, and both
  sockets exist.
- **Recurrence.** The wipe runs on every `sysbox-mgr` start, so the same
  failure returns after any reboot that lands on a large data root; hosts with
  long uptimes and heavy in-box Docker use should keep variant A's drop-in.

## User Model

- Image user `agent` (1000/1000); entrypoint remaps to host UID/GID (boxes created by the old launcher carry the user `claude`, see README.md "Boxes created by the old launcher").
- Passwordless sudo; docker group; prompt shows runtime. Except in a run
  box (unattended runs): no sudo, not in the docker group
  (tests/verify-run-unattended.sh VRUN2).

## Build Arg Behavior

`RUNTIME_TYPE` controls: docker-ce pinning (sysbox only), qemu/
bridge tooling (sysbox only), vm boot packages + setup unit (vm only),
`LBX_RUNTIME_TYPE` env + PS1. Agents/plugins are unpinned-latest;
deliberate pins: Bun (OMP dep), Gradle, sysbox docker-ce/containerd.

## Network access control (netwall)

The wall lives OUTSIDE the box (the agent is root inside it): containers
on a per-session `--internal` network, vms with qemu `restrict=on`; one
door — a per-session unprivileged CONNECT relay (hostname matching, SNI
== CONNECT host, deny-by-resolution for private space, no IP literals).
Deny-by-resolution refuses every non-public address, including
100.64.0.0/10 (tailnet), 192.0.0.0/24 and fec0::/10 explicitly (RES3-RES9);
a failed lookup is `resolve-failed:<EAI name>` (or `bad-name`, or an errno
name for a system error) with 503, looked up once (RES1, RES2, RES17); reasons are one token (RES11); optional policy key
`idle_timeout_seconds` (30-3600; default 300, not measured exactly;
validated by lbx for sessions and runs: RUN111, RUN112) sets the
idle timeout: one timer per tunnel, restarted by a byte in either
direction (RES13, RES16, RES18), both directions flowing at once (RES20),
and for the plain-HTTP wait (RES14); the
relay refuses to start on a bad value (RES15). At most 64 concurrent
connections, each holding its slot until it closes; past that 503
`too-many-connections` (RES19). A request head not complete 30 s after
connecting (env `LLMBOX_REQUEST_TIMEOUT` for the relay's checks, not a
policy key; bad value: relay exits, RES24): 408 `request-timeout`, closed,
slot freed (RES21, RES22, RES25); one deadline for the whole head
(RES28); the limit ends with the head (RES23). Bytes read with the head
are forwarded first, in order (CONNECT: RES26; the first TLS record is
read whole for the SNI check: RES29); plain HTTP forwards exactly
`Content-Length` body bytes, nothing past them (RES27), and relays an
early upstream answer at once (RES30, RES31).
Full grammar and test map: docs/llm/unattended-runs_llm.md (deny log);
checks in tests/test_relay_resolution.sh (RES1-RES31, no internet).
Policy JSONs under `~/.config/llm_in_a_box/` on the host
(`--net-policy <file>`; no file = no wall, for interactive sessions;
unattended runs require a policy in mode enforce or locked:
tests/test_llm_in_a_box_run.sh RUN1, or `--no-network`, no network at
all: tests/test_llm_in_a_box_run.sh RUN103, RUN104;
tests/verify-run-unattended.sh VRUN23). Modes: open/enforce/locked
(shipped in net-policies/). Tools: HTTP_PROXY/HTTPS_PROXY, one
JAVA_TOOL_OPTIONS line, apt conf, inner dockerd daemon.json +
~/.docker/config.json. Deny log → `lbx --denied SESSION`.
Boundary proof: `iptables -F` + a new route inside the box changes
nothing (tested both runtimes). Gotchas: no in-guest DNS in walled
sessions; ssh-git/UDP unsupported; container-runtime nested containers
hit overlayfs-on-overlayfs (inner-container probes live in the vm e2e).
The store wiring runs after the netwall `daemon.json` rewrite, so the
merge preserves the proxies (tests/test_vm_docker_store.sh S7).

## Design History

Decision records 012 to 014 are in docs/adr/. Earlier decisions survive
as prose here and in the code comments: multi-runtime support; sysbox
docker pinning; qemu-in-sysbox TCG and bridged networking;
the qemu/KVM vm runtime with vm auto-selected when built; thinking-mode
provider config removal; the Pi package rename and plugin set with the
unpinned-latest policy; and the host-side network access control (netwall).

The VM store-image design is an implementation choice, not an
architectural decision: its rationale lives in the code comments in
`lbx` (self-contained; the host-side store helpers are inlined
in the launcher) and `docker/vm-docker-store.sh`.


## User-supplied images (config file)

Sessions can run the user's own images. The launcher reads
`~/.config/llm_in_a_box/config` (`$LBX_CONFIG` overrides the path;
test/CI seam, part of the trust boundary) — `key=value` lines with
`#` comments, blank lines ignored, whitespace trimmed, duplicate keys
last-wins. Keys: `image.sysbox`, `image.docker`, `image.vm`. Defaults:
`llm-in-a-box:sysbox`, `llm-in-a-box:docker`, `llm-in-a-box:vm`.
Missing file or key = default for that key.

Validation: charset `[A-Za-z0-9._:/@+-]`; malformed/unknown/empty/
invalid entries warn per key and use the default (per-key granularity
— an all-or-nothing abort is a failure). Parser is a reader (no
source/eval; injection attempts produce no side effects). Trust: the
path must be a regular file, not a symlink, not a directory, owned by
the invoking uid, not group/world-writable, readable; ONLY ENOENT is
"missing" (any other failure on an existing path is unusable).

Severity by ACTUAL image need (verified against the dispatch — the
image is resolved only on the create path and in auto-detect):
unusable config = HARD error for create/auto-detect/`--print-images`;
WARNING + proceed with defaults for `--list`/`--destroy`/`--stop`/
`--shutdown`/`--denied` and for attaching an EXISTING session
(recovery is never locked out).

`./build` consumes the same config through the launcher's hidden
`--print-images` subcommand (stdout is exactly
`sysbox=<ref> docker=<ref> vm=<ref>`; explicit exit check). Build and
launch cannot silently disagree. `./build vm` skips the image build
when the configured vm image exists, probes the toolchain
(bash/qemu-img/mkfs.ext4/tar//boot/vmlinuz-*) with a `/bin/sh`
entrypoint, auto-builds ONLY the default `llm-in-a-box:vm` when
missing, and errors with `docker pull` guidance for a missing
NON-default ref. The base dir records the image (`from-image`,
RepoDigests parsed, ref fallback for locally built images); the vm
preflight warns on mismatch with the currently configured vm image.

The relay image is NOT configurable. Tests:
tests/test_llm_in_a_box_config.sh CFG1-CFG31 (full contract map in the
suite header).

Operational guidance — not a tested claim: a custom `image.vm` must
carry the project's guest wiring (vm-setup service, docker-store
wiring, ready marker) or sessions will lack first-boot/docker-store
functionality.

## Boxes created by the old launcher (compatibility)

Boxes created by the old launcher carry `box-of-claude.runtime` /
`box-of-claude.net-policy` labels or `box-of-claude:*` images, and their
in-box user is `claude`. The launcher recognizes them for attach, destroy,
stop, shutdown and list, with an "old (legacy) session" note on attach and
destroy; classification is exact-prefix (`llm-in-a-box:` primary,
`box-of-claude:` legacy; lookalike images and the relay image are never
sessions), and destroying one also cleans its old-prefix relay and network
names. Starting a STOPPED old box is refused: `./build vm` stamps every base
with its box user (`bases/<ts>/built-user`) and the launcher stamps every
container with the `llm-in-a-box.user` label; a box without the stamp is
refused on the start paths only (vm boot: tests/test_llm_in_a_box_vm.sh
L9e; container start: tests/test_llm_in_a_box_sessions.sh LG9, stamped
start LG9b), with the recommendation to destroy and recreate it. Cleanup
and attach-to-running are never gated. VM sessions in the old state
directory (`~/.box-of-claude`) are not seen at all. Tests:
tests/test_llm_in_a_box_sessions.sh LG1-LG9b, ST1-ST2.

## Security model

Security model statement — not a tested claim: a configured `image.vm`
delegates kernel/rootfs trust to that image's author; the vm runtime
grants the guest `/dev/kvm`, a writable host store image, and write
access to the host project dir. Custom `image.docker`/`image.sysbox`
images run inside the session privilege envelope (`--privileged` for
docker; sysbox-runc + NET_ADMIN + `/dev/net/tun` for sysbox) with the
host project dir and any forwarded `GH_TOKEN`. `./build vm` executes
the custom image's own tools as root in a container on the build host
(probe + pipeline).

Unattended runs narrow this for `image.docker`: the image then runs in a
run box (not privileged, `--cap-drop ALL` plus CHOWN, DAC_OVERRIDE,
SETGID, SETUID, no-new-privileges, no inner docker, no sudo), with only
the data directory mounted and only `--env`-named variables on the
command's exec, never `GH_TOKEN` implicitly (tests/test_llm_in_a_box_run.sh
RUN12, RUN23, RUN26; tests/verify-run-unattended.sh VRUN2, VRUN10).
Opt-in: a caller socket directory, read-only at `/run/agent`, the one
exception to "no socket in the data directory" (tests/test_llm_in_a_box_run.sh
RUN98, RUN99; tests/verify-run-unattended.sh VRUN20, VRUN21);
`--no-network` (tests/verify-run-unattended.sh VRUN23); the llm-in-a-box
AppArmor profile (tests/test_llm_in_a_box_run.sh RUN109, RUN110).
Security model statement — not a tested claim: the run box still shares
the host kernel with no user namespace; it is host isolation, not an
adversarial sandbox; a socket widens it by whatever the server behind it
allows.

The config file is a trust boundary: file trust rules + validation are
test-backed (CFG9/CFG10/CFG22/CFG23/CFG27/CFG31).

## Naming

Three name forms, one per domain: `lbx` (underscores) for
shell-facing names (launcher, repo/dir name, config dir);
`llm-in-a-box` (dashes) for docker-facing names (image tags, labels,
units, markers, docker resource names);
`LBX_` for environment variables (mnemonic, not an acronym). Do not
normalize between them.

## Session removal disambiguation

Legacy-duplicate names (one name in the vm registry AND in docker) are
removable/stop-able one instance at a time via
`--runtime <vm|sysbox|docker>` on `--destroy`/`--stop`/`--shutdown`;
without `--runtime` they error with the working command forms; a
conflicting or non-member `--runtime` errors instead of acting on the
wrong instance; invalid runtime values are rejected before any side
effect. Reference: [session-removal-disambiguation_llm.md](session-removal-disambiguation_llm.md).

## Unattended runs

`lbx --run --runtime docker (--net-policy <file> | --no-network) --data
<dir> --timeout <s> [--socket-dir <dir>] [--apparmor-profile] [--env
NAME]... <name> -- <command...>`: one command, once, no terminal, in
a fresh run box (exactly one of `--net-policy` and `--no-network`:
tests/test_llm_in_a_box_run.sh RUN103; a no-network run has no relay,
no networks and no deny log: RUN104; `--socket-dir` mounts a caller
socket directory read-only at `/run/agent`: RUN98, RUN99;
`--apparmor-profile` adds the llm-in-a-box AppArmor profile, refused
unless AppArmor is enabled, mediates Unix sockets and has the profile
loaded in enforce mode: RUN109, RUN110); exit code is the command's (124 timeout, 125 refusal or
setup failure, 129/130/143 signal, and 138 for SIGUSR1 during the checks or the name claim
(124 once setup has begun: tests/test_llm_in_a_box_run.sh RUN72); a signal
during the checks or the claim writes no status file:
tests/test_llm_in_a_box_run.sh RUN83, RUN84); outcome in
`$LBX_STATE_DIR/runs/<name>/status`; deny log kept in
`netlogs/<name>/deny.log`; box, relay and networks removed on every exit
(tests/test_llm_in_a_box_run.sh RUN12, RUN14, RUN16, RUN17, RUN18, RUN20)
except a removal docker fails (outcome gets `cleanup=incomplete`, leftover
named: tests/test_llm_in_a_box_run.sh RUN55) and SIGKILL (run box ends by its lifetime; relay, both
networks and `runs/<name>/.claim` stay: tests/verify-run-unattended.sh
VRUN15, VRUN17). Linux hosts only (no `setpriv --pdeathsig` = refused:
tests/test_llm_in_a_box_run.sh RUN39). Interactive behavior, in the baseline scenarios (docker and
sysbox create, with a policy, with `GH_TOKEN`, with `--ports`, attach,
start), unchanged apart from two read-only label queries
(tests/test_llm_in_a_box_run.sh REG1, REG3, REG4). Full contract, refusal
list, argument vectors and test map:
[unattended-runs_llm.md](unattended-runs_llm.md).

## Releases

A release is a tag `vX.Y.Z` on main. `.github/workflows/release.yml` builds
the launcher (`cargo build --release --locked --target
x86_64-unknown-linux-musl`), attaches `lbx-x86_64-unknown-linux-musl` and
its `.sha256` to the GitHub release, and writes a fenced block with the tag,
the commit and the binary name into the release body. Nothing is pushed to
an image registry; the images are built locally with `./build`. Full
reference: [releasing_llm.md](releasing_llm.md).

## Glossary

| Term | Meaning |
|------|---------|
| **project artifact directory** | The project directory's `vms_and_docker_from_llm_box` subdirectory — where what belongs to the box's PROJECT lives: the `docker-store.img` store image, the first-reader README telling the in-box agent why it exists (L0 asserts the README is planted), and the bulky state created INSIDE the box (nested VM images). NON-CONFIGURABLE. The project directory is the session's recorded first-launch directory (else the launch directory), so the guest sees this at `/data/vms_and_docker_from_llm_box` through host0. Host-side VM images (base disks, session overlays) are NOT here. |
| **box state directory** | `$LBX_STATE_DIR` (configurable: env var > `state.dir` config key > default `~/.llm-in-a-box`): the GLOBAL home of host-side VM state and box metadata — `sessions/<name>/` (origin, ssh_port, qemu.pid, seed, base record, net-policy, store-img, relay-port, and the `overlay.qcow2` disk), `bases/<timestamp>/` with `bases/latest` (the base images `./build vm` writes; `--print-state-dir` is the resolution seam `./build vm` uses), `tmp/` (transient build staging), `netlogs/`, and `runs/<name>/status` with the outcome of each unattended run (tests/test_llm_in_a_box_run.sh RUN53). Keyed by session name so boxes don't collide and a relaunch from any directory resolves the same base and overlay (L11). No first-reader README. |
| **store image file** | `docker-store.img`: the single sparse raw image the launcher creates and attaches to the guest; it holds the ext4 filesystem with containerd and Docker data. It lives at exactly `<project-directory>/vms_and_docker_from_llm_box/docker-store.img` (L4 asserts this exact path), and is guest-visible by design. Seam `LBX_VM_STORE_IMG_SIZE`. |
| **store device** | The guest's NVMe device for that image: `/dev/disk/by-id/nvme-QEMU_NVMe_Ctrl_lbx-docker-store`, serial `lbx-docker-store`. A base built by the older launcher requested `llm-in-a-box-docker-store`, which is longer than the NVMe serial field holds, so its guest sees `/dev/disk/by-id/nvme-QEMU_NVMe_Ctrl_llm-in-a-box-docker-` and the finder matches that truncated prefix (tests/test_vm_docker_store.sh S21, S21b, S22). Guest seams `LBX_STORE_DEV`, `LBX_STORE_DEVROOT`. |
| **store mount point** | `/srv/docker-store` in the guest, where the store filesystem is mounted and where containerd's root and Docker's data-root live. Guest seam `LBX_STORE_MNT`. |
| **base disk** | The immutable, versioned `bases/<timestamp>/base.qcow2` build artifact every session overlay chains to; a plain host file under the box state directory. |
| **container image** | A Docker image pulled or built inside the guest; it lives in the store image (under `/srv/docker-store/docker`), not as host files. |
| **`LBX_VM_STORE_IMG_SIZE`** | Store image creation size (default 500G; `N`/`NG` and other unit suffixes accepted; fixed at creation). |
| **`LBX_VM_STORE_DISABLE`** | `1` skips store creation/attachment; the guest falls back to local Docker. |
| **`LBX_VM_ACCEL`** | `kvm` (default) or `tcg` (software emulation; skips the `/dev/kvm` and kvm-group preflight checks). |
| **`LBX_STORE_*`** | Guest-side wiring seams: `LBX_STORE_DEV`, `LBX_STORE_MNT`, `LBX_STORE_DIR`, `LBX_STORE_DOCKER_ETC`, `LBX_STORE_CONTAINERD_CFG`, `LBX_STORE_MSG`, `LBX_STORE_WAIT_ITERS`, `LBX_STORE_FALLBACK_MARKER`, `LBX_STORE_SYSTEMCTL`, `LBX_STORE_TIMEOUT`, `LBX_STORE_DEVROOT`, `LBX_STORE_SYSFS_DIR` (plus the test-only `LBX_STORE_DEV_TEST` and `LBX_STORE_IDENTITY_TEST`). |
| **`LBX_VM_BUILD_WORK`** | The `./build vm` scratch directory (rootfs extraction and the 30G base.raw); a `/tmp` scratch by default, never the 9p project export; a caller-supplied directory is never deleted. |
| **unattended run** | One invocation of `lbx --run` (see unattended-runs_llm.md). |
| **session docker volume** | Every interactive box gets a per-session docker volume, `<session>-docker`, mounted at `/var/lib/docker` (an overlay cannot hold another overlay, so the inner `docker pull` fails on the container's own overlay); `--destroy` removes it with the container (tests/test_llm_in_a_box_netwall.sh, the inner-dockerd check). |
| **run box** | The container an unattended run creates; exists only while the run's command runs; unprivileged, relay-only network, or loopback only in a no-network run (plus, on some hosts, the kernel's fallback tunnel devices, down and without an address), plus the sockets of a socket directory when `--socket-dir` is given (tests/verify-run-unattended.sh VRUN2, VRUN4, VRUN20, VRUN23). |
| **box user** | Account in the run box: host user name, remapped to the host user id and group id; the command runs as it via gosu (tests/test_llm_in_a_box_run.sh RUN12; tests/verify-run-unattended.sh VRUN2). |
| **data directory** | Host directory from `--data`, mounted at `/data`; the run box's only host mount besides a socket directory; data-directory rules apply (tests/test_llm_in_a_box_run.sh RUN3, RUN12). |
| **socket directory** | Host directory from `--socket-dir`, mounted read-only at `/run/agent`; only the caller's Unix sockets; the one exception to "no socket in the data directory"; rules in unattended-runs_llm.md (tests/test_llm_in_a_box_run.sh RUN98, RUN99; tests/verify-run-unattended.sh VRUN20, VRUN21). |
| **no-network run** | Unattended run with `--no-network` instead of `--net-policy`: `--network none`, no relay, no run networks, no deny log (tests/test_llm_in_a_box_run.sh RUN104; tests/verify-run-unattended.sh VRUN23). |
| **run name** | `<name>` of an unattended run; must not have been used before on that host (tests/test_llm_in_a_box_run.sh RUN4, RUN22). |
| **`LBX_NO_INNER_DOCKER`** | `1` only on a run box's `docker run` (tests/test_llm_in_a_box_run.sh RUN12), never on the interactive creates the baseline records (tests/test_llm_in_a_box_run.sh REG1): the entrypoint skips dockerd, removes docker group membership and the sudoers file, writes `/tmp/.run-ready` last (tests/test_llm_in_a_box_run.sh RUN12; tests/verify-run-unattended.sh VRUN2, VRUN9, VRUN10). |
| **`LBX_RUN_READY_SECONDS`** | TEST-ONLY seam: readiness maximum for unattended runs (default 60); also enters the run box lifetime (timeout + readiness maximum + 60) (tests/test_llm_in_a_box_run.sh RUN12, RUN28 with the seam; RUN31, RUN33 without it). Any value that is not a positive whole number means 60; known limit: honored outside tests too, with no upper bound (tests/test_llm_in_a_box_run.sh RUN77). |
