#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_build_vm.sh — behavioral tests for `./build vm` (the KVM VM runtime
# image + base-disk build, ADR-008).
#
# WHAT: Exercises the `--check` prereq gate, the "scripts test and tell"
#       mandate, and the transient-storage placement rule:
#       - when a build prerequisite is missing, `./build vm --check` must
#         report it as [FAIL], print the exact install command, and exit
#         non-zero; on a complete host it must print [PASS] and exit 0
#         WITHOUT building;
#       - the vm base-disk build must stage its transient disk artifacts
#         where the placement rule says: the rootfs.tar export under
#         $STATE_DIR/tmp, and the container's /work scratch (the 30G base.raw
#         and the mkfs writes) in a scratch directory of its own, /tmp by
#         default and movable with LBX_VM_BUILD_WORK. ($STATE_DIR is the
#         launcher's state directory, ADR 013, 2026-09-29. The 2026-09-02
#         directive that everything must live under the state directory was
#         overtaken by a measured constraint: the ownership-critical work
#         cannot run on the 9p export, which refuses chown-to-root, and the
#         state directory may be that export, so the scratch is separate, and
#         the two checks below pin both halves.)
#       - the resulting base images land in that same state directory
#         (bases/<timestamp>/ + bases/latest), one set per machine, and
#         nothing is derived from the working directory (ADR 013).
#
# WHY: The user requirement (2026-08-29): prerequisites can be documented in
#       the README, but the scripts themselves must test the host and tell
#       the user what to install. It also pins down the ownership-preserving,
#       sudo-free design: the disk build runs inside a root Docker container
#       (llm-in-a-box:vm), so docker is the ONLY host build prerequisite —
#       qemu-img/mkfs.ext4 on the host are deliberately NOT required by the
#       build (they are enforced at runtime by lbx, not the build).
#       The transient-storage rule exists because a real ./build vm run
#       filled this dev VM's 30G root disk (image ~14G + /tmp rootfs.tar
#       ~4G + container base.raw/mkfs ~5G): the docker CLI invocations are
#       the build's observable interface, so the test proves placement
#       through them (behavioral, no source grep — invariant 12). The
#       full build+boot path is verified host-side by
#       tests/verify-vm-e2e.sh (skip-not-fail without /dev/kvm) — behavioral
#       proof for the Dockerfile vm branch.
#
# LLM-FRIENDLY NOTE: Uses BUILD_VM_MISSING (a test-only env override in the
# build script) to force a tool to report missing, so the failure path is
# deterministic on any host.
# ---------------------------------------------------------------------------
set -uo pipefail

# A plain umask (2026-10-25): fixtures that write config files the launcher
# reads must not inherit a group-writable umask — `lbx` refuses a config that
# group or others can write. See tests/run-all-suites.sh for the measurement.
umask 022

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="${SCRIPT_DIR}/../build"

PASS=0
FAIL=0
SKIP=0

check() {
    local description="$1"
    local condition="$2"
    if eval "$condition"; then
        echo "[PASS] $description"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $description"
        FAIL=$((FAIL + 1))
    fi
}

skip() {
    echo "[SKIP] $1"
    SKIP=$((SKIP + 1))
}

# A leftover fake qemu from the sessions suite (`qshim`) is harmless for
# THIS suite now that the running-session advisory reads the launcher's own
# qemu.pid records instead of `pgrep -f qemu-system-x86_64` — but a real,
# unrelated qemu on the host must still not trip the advisory (pinned by the
# dead-pidfile check below).

# Requirement: --check must not build, must print a PASS/FAIL status for the
# vm build prereqs, and must exit 0 when they are all present. The ONLY host
# build prereq is docker (the disk build is container-based).
check "build vm --check exits 0 and reports the docker prereq" \
    "bash '$BUILD' vm --check >/tmp/llm-in-a-box-bc.log 2>&1 \
        && grep -q '\[PASS\] docker' /tmp/llm-in-a-box-bc.log \
        && ! grep -q '\[FAIL\]' /tmp/llm-in-a-box-bc.log"

# Requirement: missing docker is reported with the exact install command.
check "missing docker fails with the get.docker.com guidance" \
    "BUILD_VM_MISSING=docker bash '$BUILD' vm --check >/tmp/llm-in-a-box-bc2.log 2>&1; [ \$? -ne 0 ] \
        && grep -q '\[FAIL\] docker' /tmp/llm-in-a-box-bc2.log \
        && grep -q 'get.docker.com' /tmp/llm-in-a-box-bc2.log"

# Requirement: the build does NOT require host qemu-img/mkfs.ext4/sudo —
# those live inside the container that builds the disk (sudo-free design,
# user objection 2026-08-29: no host password). Theory: if the build script
# demanded them, a host with only docker would be blocked from building.
check "build vm --check does not require host qemu-img/mkfs/sudo" \
    "BUILD_VM_MISSING='qemu-img mkfs.ext4 sudo' bash '$BUILD' vm --check >/tmp/llm-in-a-box-bc3.log 2>&1; [ \$? -eq 0 ] \
        && grep -q '\[PASS\] docker' /tmp/llm-in-a-box-bc3.log \
        && ! grep -q '\[FAIL\]' /tmp/llm-in-a-box-bc3.log"

# Requirement: --check is not valid for non-vm runtimes (nothing to check).
check "--check is rejected for non-vm runtimes" \
    "bash '$BUILD' sysbox --check >/tmp/llm-in-a-box-bc4.log 2>&1; [ \$? -ne 0 ]"

# Requirement: an unknown runtime still errors (validation list is now
# sysbox|docker|vm).
check "unknown runtime is rejected" \
    "bash '$BUILD' bogus >/tmp/llm-in-a-box-bc5.log 2>&1; [ \$? -ne 0 ]"

# Requirement: the vm image variant carries the disk-build tooling (qemu-utils
# + e2fsprogs), so the builder container is self-hosting. Guarded by the host
# integration test tests/verify-vm-e2e.sh (behavioral; no source grep).
echo "[INFO] qemu-utils/e2fsprogs-in-image claim is verified host-side by"
echo "       tests/verify-vm-e2e.sh — not by source grep."

# ── Transient-storage placement (2026-09-02 user directive) ────────────────
# WHAT: ./build vm stages its transient disk artifacts in two tiers:
#         (a) `docker export -o <path>` targets $LLMBOX_STATE_DIR/tmp/...
#             (bulk rootfs.tar on the state directory's filesystem),
#         (b) `docker run` mounts a LOCAL scratch dir as /work (the
#             ownership-critical tar extraction + 30G base.raw + mkfs),
#             because a state directory exported over a network share may
#             refuse chown-to-root (verified with a 9p export: even the vm
#             root gets EPERM) and a guest rootfs with wrong ownership does
#             not boot; ownership correctness is proven by the real boot in
#             tests/verify-vm-e2e.sh, and
#         (c) `docker run` mounts $LLMBOX_STATE_DIR as /state (outputs).
# WHY: behavioral proof (invariant 12) through the build's observable
#       docker interface; no source grep.
# BOUNDARY: covers placement wiring only; the actual in-container disk
#       work runs for real in tests/verify-vm-e2e.sh's ./build vm step.
SHIMDIR=/tmp/llm-in-a-box-dkshim
rm -rf "$SHIMDIR" && mkdir -p "$SHIMDIR"
SHIMLOG=/tmp/llm-in-a-box-dkshim.log
rm -f "$SHIMLOG"
cat > "$SHIMDIR/docker" <<'SHIMEOF'
#!/usr/bin/env bash
cmd="$1"; shift
case "$cmd" in
    build) printf 'BUILD %s\n' "$*" >> "$SHIMLOG"; exit 0 ;;
    create) echo cid123 ;;
    rm) exit 0 ;;
    image)
        # SHIM_INSPECT_FAIL=1 simulates "docker build exited 0 but the
        # tag never landed" (seen for real on 2026-09-02 — buildkit
        # failure swallowed by the set -e || trap).
        if [ "${SHIM_INSPECT_FAIL:-0}" = "1" ]; then exit 1; fi
        exit 0 ;;
    export)
        printf 'EXPORT %s\n' "$*" >> "$SHIMLOG"
        prev=""
        for a in "$@"; do
            if [ "$prev" = "-o" ]; then touch "$a"; fi
            prev="$a"
        done
        exit 0 ;;
    run)
        printf 'RUN %s\n' "$*" >> "$SHIMLOG"
        # Produce the artifacts the real container writes to /state, so
        # the build's artifact guard and the GC phase see a real base dir
        # (the build now stages into bases/<ts>.tmp/ and refuses to flip
        # `latest` when base.qcow2 is missing — 2026-09-03).
        prev=""
        for a in "$@"; do
            if [ "$prev" = "-v" ]; then
                case "$a" in
                    *:/state)
                        staging="${a%%:/state}"
                        mkdir -p "$staging"
                        touch "$staging/base.qcow2" "$staging/vmlinuz" "$staging/initrd.img"
                        # Box-user era stamp (2026-09-20): the container
                        # writes /state/built-user; lbx refuses unmarked
                        # bases. The shim materializes it like the other
                        # artifacts.
                        printf 'claude\n' > "$staging/built-user"
                        ;;
                esac
            fi
            prev="$a"
        done
        exit 0 ;;
    *) exit 0 ;;
esac
SHIMEOF
chmod +x "$SHIMDIR/docker"
FIXTMP=/tmp/llm-in-a-box-buildwork
rm -rf "$FIXTMP"
mkdir -p "$FIXTMP/proj"

check "vm base-disk build stages transient work per the two-tier storage rule" \
    "cd $FIXTMP/proj && LLMBOX_STATE_DIR=$FIXTMP/state SHIMLOG=$SHIMLOG PATH=$SHIMDIR:\$PATH bash '$BUILD' vm >/tmp/llm-in-a-box-bd.log 2>&1 \
        && grep -q \"EXPORT .*-o $FIXTMP/state/tmp/llm-in-a-box-vmdisk\" $SHIMLOG \
        && grep -qE 'RUN .*-v /tmp/llm-in-a-box-work\\.[^ ]+:/work ' $SHIMLOG \
        && grep -qE 'RUN .*-v $FIXTMP/state/bases/[^ ]+\\.tmp:/state ' $SHIMLOG"

# Requirement (2026-10-18, owner directive): the vm build's scratch directory
# must be movable off the root filesystem. The scratch is where the ownership-
# critical work happens (the rootfs extraction and the 30G base.raw that
# mkfs.ext4 -d fills with it), so it needs roughly twice the rootfs size, and
# on a small root disk the build fills the filesystem and dies. Measured
# 2026-10-18: a 6.9G rootfs plus its raw disk against 12G free; the mkfs output
# is suppressed and the script runs under set -euo pipefail, so the log simply
# stopped with no error at all.
#
# Theory: LBX_VM_BUILD_WORK names the scratch directory. When it is set, the
# container's /work volume must mount from there instead of a /tmp scratch, and
# the build must still stage its outputs under the state directory and use no
# /tmp scratch at all. The seam exists because the scratch must NOT be the 9p
# export (that refuses chown-to-root, and a guest rootfs with wrong ownership
# does not boot) while the STATE directory may be, so a host whose root disk is
# small can put the scratch on a real local filesystem of its own choosing.
#
# The default is unchanged, so the check above still pins the /tmp form: this
# adds a location, it does not move the default.
BD2LOG=/tmp/llm-in-a-box-dkshim2.log
rm -f "$BD2LOG"
FIXWORK="$FIXTMP/work-alt"
mkdir -p "$FIXWORK"

check "the vm build's scratch directory can be moved off the root filesystem" \
    "cd $FIXTMP/proj && LBX_STATE_DIR=$FIXTMP/state LBX_VM_BUILD_WORK=$FIXWORK SHIMLOG=$BD2LOG PATH=$SHIMDIR:\$PATH bash '$BUILD' vm >/tmp/llm-in-a-box-bd-alt.log 2>&1 \
        && grep -qE 'RUN .*-v $FIXWORK:/work ' $BD2LOG \
        && grep -qE 'RUN .*-v $FIXTMP/state/bases/[^ ]+\.tmp:/state ' $BD2LOG \
        && ! grep -qE 'RUN .*-v /tmp/llm-in-a-box-work' $BD2LOG"
rm -rf "$FIXWORK"

# Hostile-review gap (2026-10-18): the check above proves the scratch is USED
# where the variable points, but nothing proved the build does not DELETE a
# directory the caller supplied. A scratch under a shared path is exactly what
# the seam invites, and a build that removed it would destroy the caller's
# files. Theory: point the variable at a directory holding a sentinel, run the
# build, and the sentinel must still be there afterwards.
FIXKEEP="$FIXTMP/keep-scratch"
mkdir -p "$FIXKEEP"
printf 'kept\n' > "$FIXKEEP/sentinel"

check "the vm build does not delete a caller-supplied scratch directory" \
    "cd $FIXTMP/proj && LBX_STATE_DIR=$FIXTMP/state LBX_VM_BUILD_WORK=$FIXKEEP SHIMLOG=/tmp/llm-in-a-box-dkshim3.log PATH=$SHIMDIR:\$PATH bash '$BUILD' vm >/tmp/llm-in-a-box-bd-keep.log 2>&1 \
        && [ -f $FIXKEEP/sentinel ]"
rm -rf "$FIXKEEP"

# Requirement (ADR 013, 2026-09-29): ./build vm derives nothing from the
# working directory — the base images are machine-wide host-side VM state.
# Theory: run the build with a state directory OUTSIDE the working directory
# and with no project artifact directory present; the build must succeed,
# write the base under the state directory, and leave the working directory
# untouched (nothing created there at all).
check "build vm derives nothing from the working directory (ADR 013)" \
    "[ -f \$(readlink -f $FIXTMP/state/bases/latest)/base.qcow2 ] \
        && [ ! -e $FIXTMP/proj/vms_and_docker_from_llm_box ] \
        && [ -z \"\$(ls -A $FIXTMP/proj)\" ]"

# Requirement (2026-09-20): every staged base carries the box-user era
# stamp (built-user) that lbx requires before booting it; a base without
# it is refused as an OLD base.
check "staged base carries the box-user era stamp (built-user)" \
    "[ -f \$(readlink -f $FIXTMP/state/bases/latest)/built-user ] \
        && [ -s \$(readlink -f $FIXTMP/state/bases/latest)/built-user ]"

# Requirement (2026-09-02, real incident): a failed docker build must not
# print "Built ..." and continue into the base-disk stage. The caller's
# `|| return` disables set -e for the whole function body (bash trap), so
# build_docker_image captures docker build's exit AND verifies the tag
# landed. Shim: docker build exits 0 but image inspect fails.
check "a docker build that reports success but leaves no image fails with a clear error" \
    "cd $FIXTMP/proj && LLMBOX_STATE_DIR=$FIXTMP/state SHIMLOG=$SHIMLOG SHIM_INSPECT_FAIL=1 PATH=$SHIMDIR:\$PATH bash '$BUILD' vm >/tmp/llm-in-a-box-bd2.log 2>&1; [ \$? -ne 0 ] \
        && grep -q 'reported success but' /tmp/llm-in-a-box-bd2.log \
        && grep -q 'llm-in-a-box:vm' /tmp/llm-in-a-box-bd2.log \
        && ! grep -q 'Building base disk' /tmp/llm-in-a-box-bd2.log"

# Requirement (2026-09-03, versioned bases): a running vm session no
# longer BLOCKS the build — the new base lands under a fresh timestamped
# directory and `latest` moves; running sessions keep their old base. The
# build prints an advisory instead of failing (the old in-place rebuild
# conflicted with qemu's write lock; versioned bases remove the conflict).
# AMENDED 2026-10-24: "running" is the launcher's own record
# (sessions/<name>/qemu.pid with a live pid), not `pgrep -f
# qemu-system-x86_64`, which matched any qemu on the host. The fixture is
# therefore a pidfile, and the pid is probed for liveness: a stale pidfile
# (what `lbx --shutdown` leaves behind) must NOT print the advisory.
rm -rf "$FIXTMP"
mkdir -p "$FIXTMP/proj" "$FIXTMP/state/sessions/guard"
sleep 30 &
GUARD_PID=$!
printf '%s\n' "$GUARD_PID" > "$FIXTMP/state/sessions/guard/qemu.pid"
check "a running vm session no longer blocks the build (advisory + new base staged)" \
    "cd $FIXTMP/proj && LLMBOX_STATE_DIR=$FIXTMP/state SHIMLOG=$SHIMLOG PATH=$SHIMDIR:\$PATH bash '$BUILD' vm >/tmp/llm-in-a-box-bd3.log 2>&1; [ \$? -eq 0 ] \
        && grep -q 'vm session is running' /tmp/llm-in-a-box-bd3.log \
        && grep -q 'keep using' /tmp/llm-in-a-box-bd3.log \
        && grep -q 'guard' /tmp/llm-in-a-box-bd3.log \
        && [ -L $FIXTMP/state/bases/latest ] \
        && [ -f \$(readlink -f $FIXTMP/state/bases/latest)/base.qcow2 ]"
kill "$GUARD_PID" 2>/dev/null || true
wait "$GUARD_PID" 2>/dev/null || true
# A dead pid in qemu.pid is a session that is NOT running: no advisory. This
# is also the proof that an unrelated qemu process can no longer trip it.
DEAD_PID=$GUARD_PID
printf '%s\n' "$DEAD_PID" > "$FIXTMP/state/sessions/guard/qemu.pid"
check "a stale qemu.pid (dead session) prints no running-session advisory" \
    "cd $FIXTMP/proj && LLMBOX_STATE_DIR=$FIXTMP/state SHIMLOG=$SHIMLOG PATH=$SHIMDIR:\$PATH bash '$BUILD' vm >/tmp/llm-in-a-box-bd3b.log 2>&1; [ \$? -eq 0 ] \
        && ! grep -q 'vm session is running' /tmp/llm-in-a-box-bd3b.log"

# Requirement (2026-09-03, GC phase): after a successful build, old base
# directories that NO session overlay references are removed; referenced
# bases and the newest base are kept; staging leftovers are swept. Overlays
# and bases share the state directory (ADR 013), so the fixture builds both
# under $dir/state.
make_base_fixture() {
    local dir="$1"
    mkdir -p "$dir/state/bases/old1" "$dir/state/bases/old2" "$dir/state/bases/unreferenced"
    qemu-img create -f qcow2 "$dir/state/bases/old1/base.qcow2" 1M >/dev/null
    qemu-img create -f qcow2 "$dir/state/bases/old2/base.qcow2" 1M >/dev/null
    qemu-img create -f qcow2 "$dir/state/bases/unreferenced/base.qcow2" 1M >/dev/null
    touch "$dir/state/bases/old1/vmlinuz" "$dir/state/bases/old2/vmlinuz" "$dir/state/bases/unreferenced/vmlinuz"
    ln -sfn old2 "$dir/state/bases/latest"
    mkdir -p "$dir/state/sessions/foo"
    qemu-img create -f qcow2 -F qcow2 -b "$dir/state/bases/old1/base.qcow2" "$dir/state/sessions/foo/overlay.qcow2" >/dev/null
}

if command -v qemu-img >/dev/null 2>&1; then
    FIXGC=/tmp/llm-in-a-box-build-gc
    rm -rf "$FIXGC"
    make_base_fixture "$FIXGC"
    check "GC removes unreferenced bases, keeps referenced + newest, and flips latest" \
        "cd $FIXGC && LLMBOX_STATE_DIR=$FIXGC/state SHIMLOG=$SHIMLOG PATH=$SHIMDIR:\$PATH bash '$BUILD' vm >/tmp/llm-in-a-box-bd4.log 2>&1 \
            && [ \$? -eq 0 ] \
            && [ ! -d $FIXGC/state/bases/unreferenced ] \
            && [ -d $FIXGC/state/bases/old1 ] \
            && [ ! -d $FIXGC/state/bases/old2 ] \
            && [ -L $FIXGC/state/bases/latest ] \
            && grep -q 'GC:' /tmp/llm-in-a-box-bd4.log"
    rm -rf "$FIXGC"

    # Fail-safe GC: a corrupt (unreadable) overlay must make GC SKIP
    # deletions rather than risk removing an in-use base.
    FIXGC2=/tmp/llm-in-a-box-build-gc2
    rm -rf "$FIXGC2"
    make_base_fixture "$FIXGC2"
    echo "this is not a qcow2" > "$FIXGC2/state/sessions/foo/overlay.qcow2"
    check "GC skips deletions when an overlay is unreadable (fail-safe)" \
        "cd $FIXGC2 && LLMBOX_STATE_DIR=$FIXGC2/state SHIMLOG=$SHIMLOG PATH=$SHIMDIR:\$PATH bash '$BUILD' vm >/tmp/llm-in-a-box-bd5.log 2>&1 \
            && [ \$? -eq 0 ] \
            && grep -q 'GC: skipped' /tmp/llm-in-a-box-bd5.log \
            && [ -d $FIXGC2/state/bases/unreferenced ]"
    rm -rf "$FIXGC2"

    # Regression (2026-10-24, owner report): a RUNNING session holds a write
    # lock on its overlay. A plain read-only `qemu-img info` asks the lock
    # manager for a shared lock and fails
    # ("Failed to get shared \"write\" lock"), which was indistinguishable
    # from a damaged overlay — so every rebuild with a vm session running
    # printed "GC: skipped" and collected nothing. Real lock, no shim:
    # qemu-io (same qemu-utils package as qemu-img) holds the image write-
    # locked while its stdin stays open. The precondition inside the check
    # proves the lock is really held, so this cannot pass vacuously.
    if command -v qemu-io >/dev/null 2>&1; then
        FIXGC3=/tmp/llm-in-a-box-build-gc3
        rm -rf "$FIXGC3"
        make_base_fixture "$FIXGC3"
        sleep 15 | qemu-io -f qcow2 "$FIXGC3/state/sessions/foo/overlay.qcow2" >/dev/null 2>&1 &
        LOCK_PID=$!
        sleep 1
        check "a locked (running-session) overlay does not disable GC" \
            "cd $FIXGC3 && ! qemu-img info $FIXGC3/state/sessions/foo/overlay.qcow2 >/dev/null 2>&1 \
                && LLMBOX_STATE_DIR=$FIXGC3/state SHIMLOG=$SHIMLOG PATH=$SHIMDIR:\$PATH bash '$BUILD' vm >/tmp/llm-in-a-box-bd6.log 2>&1 \
                && [ ! -d $FIXGC3/state/bases/unreferenced ] \
                && [ -d $FIXGC3/state/bases/old1 ] \
                && [ ! -d $FIXGC3/state/bases/old2 ] \
                && ! grep -q 'GC: skipped' /tmp/llm-in-a-box-bd6.log \
                && grep -q 'GC: removed 2' /tmp/llm-in-a-box-bd6.log"
        kill "$LOCK_PID" 2>/dev/null || true
        pkill -f "qemu-io -f qcow2 $FIXGC3" 2>/dev/null || true
        rm -rf "$FIXGC3"
    else
        echo "[INFO] locked-overlay GC check not run: qemu-io not installed"
    fi
else
    skip "GC checks (qemu-img not installed)"
fi

# Requirement (2026-10-24): `all` is the "this machine is ready" command and
# its help text says "all of the above". That must include the netwall relay
# (it used to stop at sysbox+docker+vm, so a fresh host had no relay image and
# the netwall path failed at runtime), and it must REBUILD the vm image
# instead of reusing whatever tag happens to exist: a base disk is only as new
# as the rootfs it was built from, while the other three builds here run
# --no-cache. `./build vm` alone keeps the cheap reuse path.
ALLLOG=/tmp/llm-in-a-box-ball.log
rm -rf /tmp/llm-in-a-box-build-all && mkdir -p /tmp/llm-in-a-box-build-all/proj
: > "$SHIMLOG"
check "./build all builds the relay and rebuilds the reusable vm image" \
    "cd /tmp/llm-in-a-box-build-all/proj && LLMBOX_STATE_DIR=/tmp/llm-in-a-box-build-all/state SHIMLOG=$SHIMLOG PATH=$SHIMDIR:\$PATH bash '$BUILD' all >$ALLLOG 2>&1; [ \$? -eq 0 ] \
        && grep -q 'BUILD .*-t llm-in-a-box:sysbox ' $SHIMLOG \
        && grep -q 'BUILD .*-t llm-in-a-box:docker ' $SHIMLOG \
        && grep -q 'BUILD .*-t llm-in-a-box-relay:latest' $SHIMLOG \
        && grep -q 'BUILD .*-t llm-in-a-box:vm ' $SHIMLOG \
        && [ -f /tmp/llm-in-a-box-build-all/state/bases/\$(readlink /tmp/llm-in-a-box-build-all/state/bases/latest)/base.qcow2 ]"

# ... and `./build vm` on its own still reuses the image (no 40-minute rebuild
# for someone who only wants a fresh base disk).
: > "$SHIMLOG"
check "./build vm alone still reuses an existing vm image (no image build)" \
    "cd /tmp/llm-in-a-box-build-all/proj && LLMBOX_STATE_DIR=/tmp/llm-in-a-box-build-all/state SHIMLOG=$SHIMLOG PATH=$SHIMDIR:\$PATH bash '$BUILD' vm >/tmp/llm-in-a-box-bvm-reuse.log 2>&1; [ \$? -eq 0 ] \
        && ! grep -q 'BUILD .*-t llm-in-a-box:vm ' $SHIMLOG \
        && grep -q 'image build skipped' /tmp/llm-in-a-box-bvm-reuse.log"
rm -rf /tmp/llm-in-a-box-build-all

echo ""
echo "test_build_vm.sh: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
[ "$FAIL" -eq 0 ]