#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_llm_in_a_box_vm.sh — behavioral tests for the vm runtime
# (ADR-008, amended 2026-09-01): auto-detection defaults to vm whenever the
# vm image is built, and an un-runnable host gets guided failure.
#
# WHAT: Verifies, behaviorally (no source grep):
#   - auto-detect selects vm when the vm image (base disk + kernel) is
#     built in the launcher's state directory
#     ($LLMBOX_STATE_DIR/bases/latest, ADR 013) — regardless of
#     KVM/qemu/kvm-group presence;
#   - when the selected vm cannot run, the preflight fails with
#     actionable fix-it guidance (the "scripts test and tell" mandate) AND
#     tells the user how to force a different runtime;
#   - auto-detect NEVER selects vm when the image is NOT built;
#   - a corrupt (non-qcow2) base disk fails the preflight with a clear
#     message instead of a cryptic qemu-img launch error;
#   - the LLMBOX_VM_MISSING test-only override forces prereqs to report
#     missing (guards the guards — makes failure-path tests deterministic
#     on hosts WITH working KVM, e.g. this dev VM which has /dev/kvm);
#   - unchanged behaviors: explicit --runtime vm guidance, unknown-runtime
#     rejection, --destroy/--shutdown needing no preflight, shutdown
#     preserving the session for resume.
#
# WHY:
#   - built ⇒ vm: user requirement 2026-09-01 (D1) — "lbx should
#     default to the vm type if the vm image is built". The image being
#     built at the location the script expects is the ONLY detection
#     criterion; readiness stays enforced by vm_preflight (single source
#     of truth) so the two can never drift apart.
#   - guided failure: user requirement (D2) — built but missing prereqs
#     must fail with fix-it guidance exactly like an explicit
#     --runtime vm. The override hint prevents a built-but-KVM-less host
#     from being a dead end.
#   - never vm when not built: the other half of the boundary — detection
#     keys on "built", nothing else (no accidental vm when only sysbox/
#     docker exist).
#   - invalid-base guidance: a plain `-f` existence check would let a
#     corrupt/empty base disk through preflight and fail later inside
#     qemu-img create -b with an opaque error — that violates "scripts
#     test and tell".
#   - LLMBOX_VM_MISSING: mirrors the established BUILD_VM_MISSING test hook in
#     ./build. Without it, preflight-failure assertions would depend on
#     host state (this VM has /dev/kvm; the llm-in-a-box container in
#     ADR-005 did not) and the suite could not run anywhere.
#
# CHANGED 2026-09-01 (user-approved, invariant 4): the previous assertions
# "auto-detect never selects vm when /dev/kvm is unavailable" and
# "auto-detect hints at /dev/kvm when the base disk is present" are
# REPLACED by the built⇒vm assertions above, because the requested default
# (D1/D2) deliberately inverts the old ADR-008 "vm only when ready" gate.
#
# LLM-FRIENDLY NOTE: The success path (real KVM boot, ssh attach, in-guest
# dockerd) is verified by tests/verify-vm-e2e.sh (skip-not-fail without
# /dev/kvm + kvm group). These checks cover what is deterministically
# testable on ANY host: the detection and guard/failure behaviors. Fixtures
# are built under /tmp, each with its own project directory (the working
# directory) and its own state directory (passed as LLMBOX_STATE_DIR); the
# real project root and the real ~/.llm-in-a-box are never touched.
# LLMBOX_VM_MISSING only ever forces prereqs to report
# MISSING (the safe, stricter direction) — it can never make the preflight
# pass something that is actually absent.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOC="${LBX_BIN:-${SCRIPT_DIR}/../target/debug/lbx}"
export LLMBOX_SCRIPT_DIR="$SCRIPT_DIR/.."

# Storage split (ADR 013, 2026-09-29): host-side VM state (base images,
# session overlays, session metadata) lives in the configurable
# LLMBOX_STATE_DIR; the per-project artifacts (docker store image and the
# first-reader README) live in vms_and_docker_from_llm_box under the project
# directory. This suite exports ONE scratch state dir so no check writes into
# the real ~/.llm-in-a-box; per-check overrides (e.g. L9) supersede it via an
# env prefix.
export LLMBOX_STATE_DIR="${LLMBOX_STATE_DIR:-/tmp/llm-in-a-box-vm-state}"
mkdir -p "$LLMBOX_STATE_DIR"

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

# A killed process is dead when kill -0 fails OR it is a zombie (state Z).
# This box's PID 1 is `sleep infinity`, which never reaps, so a killed fake
# qemu lingers as a zombie that kill -0 still reports as alive. The checks
# keep their meaning: the process is dead (not running), zombie included.
proc_dead() {
    ! kill -0 "$1" 2>/dev/null \
        || [ "$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')" = "Z" ]
}

# ── Fixtures ──────────────────────────────────────────────────────────────
# A "built" vm image = base images in the launcher's STATE directory
# (ADR 013, 2026-09-29). Each fixture gets a project directory ($dir/project,
# the working directory every check runs from) and a separate state directory
# ($dir/state, passed as LLMBOX_STATE_DIR): bases live in the state directory,
# while the project directory holds only what belongs to the box's project
# (the Docker store image and the first-reader README). The base here is the
# legacy flat layout (base.qcow2 + vmlinuz at the state-directory root); the
# L9/L10 rigs use the versioned bases/<ts>/ layout. It is a real (tiny) qcow2
# whenever qemu-img exists so the preflight's qcow2 validity check passes and
# the tests exercise the intended failure mode; without qemu-img a plain file
# is used (validity check is then skipped by the preflight, mirroring
# production behavior).

# Hygiene (2026-09-03): the "not built" check can create a real docker
# container named llm-in-a-box-vmtest as a side effect when llm-in-a-box images
# exist locally; remove it up front and on exit so re-runs never collide
# with a leftover instance (the cross-runtime resolver would attach to it).
# Also reap orphaned fake qemus from interrupted runs — pgrep-based liveness
# checks pick the OLDEST match, so a stale fake would hijack them.
docker rm -f llm-in-a-box-vmtest >/dev/null 2>&1 || true
pkill -f 'qemu-system-x86_64.*/tmp/llm-in-a-box-vm' 2>/dev/null || true
pkill -f 'llm-in-a-box-qshim' 2>/dev/null || true
make_vm_fixture() {
    local dir="$1"
    rm -rf "$dir"
    mkdir -p "$dir/project" "$dir/state"
    if command -v qemu-img >/dev/null 2>&1; then
        qemu-img create -f qcow2 "$dir/state/base.qcow2" 1M >/dev/null
    else
        touch "$dir/state/base.qcow2"
    fi
    touch "$dir/state/vmlinuz"
}

FIX1=/tmp/llm-in-a-box-vms1
FIX2=/tmp/llm-in-a-box-vms2
FIXBAD=/tmp/llm-in-a-box-vmsbad
FIXMISS=/tmp/llm-in-a-box-vmsmiss
FIXEMPTY=/tmp/llm-in-a-box-vmsempty

# Requirement (D1/D2): with the vm image built, auto-detect MUST print
# "Auto-detected runtime: vm" and then — because the KVM-side prereqs are
# forced missing — fail with actionable fix-it guidance. This is exactly
# the behavior an explicit --runtime vm shows on a broken host.
make_vm_fixture "$FIX1"
check "auto-detect selects vm when the vm image is built, then fails with guidance when prereqs are missing" \
    "cd '$FIX1/project' && LLMBOX_STATE_DIR='$FIX1/state' LLMBOX_VM_MISSING='/dev/kvm kvm-group qemu-system-x86_64' '$BOC' llm-in-a-box-vmtest >/tmp/llm-in-a-box-vmp1.log 2>&1; [ \$? -ne 0 ] \
        && grep -q 'Auto-detected runtime: vm' /tmp/llm-in-a-box-vmp1.log \
        && grep -q '/dev/kvm' /tmp/llm-in-a-box-vmp1.log \
        && grep -q 'usermod -aG kvm' /tmp/llm-in-a-box-vmp1.log \
        && grep -q 'qemu-system-x86' /tmp/llm-in-a-box-vmp1.log"

# Requirement (R2): a built-but-un-runnable host must not be a dead end —
# the preflight failure output tells the user how to force sysbox/docker.
check "auto-detected vm failure tells the user how to force a different runtime" \
    "grep -q -- '--runtime sysbox' /tmp/llm-in-a-box-vmp1.log \
        && grep -q -- '--runtime docker' /tmp/llm-in-a-box-vmp1.log"

# Requirement (boundary): vm is NEVER auto-selected when the image is NOT
# built — detection keys on "built", nothing else. The "no image found"
# error is asserted only when no llm-in-a-box:* image exists locally
# (skip-not-fail: once images are built on this VM, detection falls back
# to docker/sysbox, which is also a correct not-vm outcome).
make_vm_fixture "$FIX2"
rm -f "$FIX2/state/base.qcow2" "$FIX2/state/vmlinuz"
check "auto-detect never selects vm when the vm image is NOT built" \
    "cd '$FIX2/project' && LLMBOX_STATE_DIR='$FIX2/state' '$BOC' llm-in-a-box-vmtest >/tmp/llm-in-a-box-vmp2.log 2>&1; [ \$? -ne 0 ] \
        && ! grep -q 'Auto-detected runtime: vm' /tmp/llm-in-a-box-vmp2.log"
# The no-image error can only appear when NO llm-in-a-box:* image exists
# locally; skip-not-fail once ANY image is built (detection then falls
# back to docker/sysbox, which is also a correct not-vm outcome — the
# multi-image inspect that gated this before required ALL THREE images
# and produced a false FAIL when only some existed).
if ! docker image inspect llm-in-a-box:docker >/dev/null 2>&1 \
    && ! docker image inspect llm-in-a-box:sysbox >/dev/null 2>&1 \
    && ! docker image inspect llm-in-a-box:latest >/dev/null 2>&1; then
    check "unbuilt vm image falls through to the no-image error" \
        "grep -q 'No llm-in-a-box image found' /tmp/llm-in-a-box-vmp2.log"
else
    skip "unbuilt vm image falls through to the no-image error (llm-in-a-box images exist locally)"
fi
# Hygiene (2026-09-03): the check above may have created a real docker
# container named llm-in-a-box-vmtest (side effect when llm-in-a-box images exist
# locally); the cross-runtime resolver would otherwise attach every
# subsequent vm-fixture check to that container instead.
docker rm -f llm-in-a-box-vmtest >/dev/null 2>&1 || true

# Requirement (R3): a corrupt base disk must fail the preflight with a
# clear message, not surface later as an opaque qemu-img launch error.
# Only meaningful when qemu-img exists (the preflight guards the validity
# check on it) — skip-not-fail otherwise.
if command -v qemu-img >/dev/null 2>&1; then
    rm -rf "$FIXBAD"
    mkdir -p "$FIXBAD/project" "$FIXBAD/state"
    echo "this is not a qcow2 image" > "$FIXBAD/state/base.qcow2"
    touch "$FIXBAD/state/vmlinuz"
    check "a corrupt base disk fails the preflight with a clear message" \
        "cd '$FIXBAD/project' && LLMBOX_STATE_DIR='$FIXBAD/state' LLMBOX_VM_MISSING='/dev/kvm kvm-group qemu-system-x86_64' '$BOC' llm-in-a-box-vmtest >/tmp/llm-in-a-box-vmp3.log 2>&1; [ \$? -ne 0 ] \
            && grep -q 'not a valid qcow2' /tmp/llm-in-a-box-vmp3.log \
            && grep -q './build vm' /tmp/llm-in-a-box-vmp3.log"
else
    skip "a corrupt base disk fails the preflight with a clear message (qemu-img not installed)"
fi

# Requirement (R4): the LLMBOX_VM_MISSING test hook itself must work — with
# qemu-img forced missing, the preflight reports [FAIL] qemu-img even on a
# host where it is installed. Guards the guards.
make_vm_fixture "$FIXMISS"
check "LLMBOX_VM_MISSING forces a prerequisite to report missing" \
    "cd '$FIXMISS/project' && LLMBOX_STATE_DIR='$FIXMISS/state' LLMBOX_VM_MISSING='qemu-img' '$BOC' --runtime vm llm-in-a-box-vmtest >/tmp/llm-in-a-box-vmp4.log 2>&1; [ \$? -ne 0 ] \
        && grep -q '\[FAIL\] qemu-img' /tmp/llm-in-a-box-vmp4.log"

# Requirement (kept): prereqs that ARE present are reported [PASS] even when
# others fail (user sees the whole picture). ssh client is a hard runtime
# prereq present on every supported host, so this assertion is
# host-independent when qemu-img is forced missing.
check "vm preflight reports passing prereqs alongside failures" \
    "grep -q '\[PASS\] ssh client' /tmp/llm-in-a-box-vmp4.log"

# Requirement (2026-09-10): the Docker store attaches as `-device nvme`,
# which needs qemu >= 5.0. The preflight must parse `qemu-system-x86_64
# --version` and fail with upgrade guidance below the floor instead of
# launching into a cryptic qemu error. Theory: a fake qemu reporting 4.2.1
# earlier on PATH fails the floor check while the fixture keeps the
# base/kernel present, so the version is the only new failure; a fake
# reporting 8.2.2 passes the floor line. Both fakes are real scripts, so
# `command -v` finds them exactly like an installed qemu.
FIXQEMU=/tmp/llm-in-a-box-vmsqemu
make_vm_fixture "$FIXQEMU"
rm -rf /tmp/llm-in-a-box-fakeqemu-old /tmp/llm-in-a-box-fakeqemu-new
mkdir -p /tmp/llm-in-a-box-fakeqemu-old /tmp/llm-in-a-box-fakeqemu-new
printf '#!/bin/bash\necho "QEMU emulator version 4.2.1 (fake)"\n' > /tmp/llm-in-a-box-fakeqemu-old/qemu-system-x86_64
printf '#!/bin/bash\necho "QEMU emulator version 8.2.2 (fake)"\n' > /tmp/llm-in-a-box-fakeqemu-new/qemu-system-x86_64
chmod +x /tmp/llm-in-a-box-fakeqemu-old/qemu-system-x86_64 /tmp/llm-in-a-box-fakeqemu-new/qemu-system-x86_64
check "a qemu below the 5.0 floor fails the preflight with upgrade guidance" \
    "cd '$FIXQEMU/project' && LLMBOX_STATE_DIR='$FIXQEMU/state' PATH=/tmp/llm-in-a-box-fakeqemu-old:\$PATH '$BOC' --runtime vm llm-in-a-box-vmtest >/tmp/llm-in-a-box-vmpqemu1.log 2>&1; [ \$? -ne 0 ] \
        && grep -q 'below the 5.0 floor' /tmp/llm-in-a-box-vmpqemu1.log \
        && grep -q 'qemu-system-x86' /tmp/llm-in-a-box-vmpqemu1.log"
check "a qemu at or above the 5.0 floor passes the version check" \
    "cd '$FIXQEMU/project' && LLMBOX_STATE_DIR='$FIXQEMU/state' PATH=/tmp/llm-in-a-box-fakeqemu-new:\$PATH LLMBOX_VM_MISSING='/dev/kvm kvm-group' '$BOC' --runtime vm llm-in-a-box-vmtest >/tmp/llm-in-a-box-vmpqemu2.log 2>&1; \
        grep -q 'qemu-system-x86_64 version 8.x' /tmp/llm-in-a-box-vmpqemu2.log"

# Requirement (2026-09-09 operator directive): the vm runtime must plant a
# first-reader message so the LLM (or human) meeting the box's project
# directory fresh learns what it is — why the directory exists, what lives
# there, and the .gitignore recommendation. The message applies to the box's
# PROJECT directory (<project>/vms_and_docker_from_llm_box, ADR 013), so it
# must appear there. Planted on EVERY vm-runtime invocation, even when the
# preflight fails (a failing preflight is when a host is most likely to be
# new). Only presence + no-clobber are asserted; the message CONTENT is a
# documentation artifact and is deliberately not text-compared (AGENTS.md
# invariant 12). The no-clobber check writes its OWN marker and proves a
# second invocation never overwrites a reader's edits.
FIXMSG=/tmp/llm-in-a-box-vmsmsg
rm -rf "$FIXMSG"
mkdir -p "$FIXMSG"
check "vm invocation plants the state-dir message for the first reader" \
    "cd '$FIXMSG' && LLMBOX_VM_MISSING='/dev/kvm kvm-group qemu-system-x86_64' '$BOC' --runtime vm llm-in-a-box-vmtest >/tmp/llm-in-a-box-vmpmsg1.log 2>&1; [ \$? -ne 0 ] && test -s '$FIXMSG/vms_and_docker_from_llm_box/README.md'"
check "state-dir message survives a second vm invocation (never clobbered)" \
    "test -e '$FIXMSG/vms_and_docker_from_llm_box/README.md' && printf 'operator-marker\n' > '$FIXMSG/vms_and_docker_from_llm_box/README.md'; cd '$FIXMSG' && LLMBOX_VM_MISSING='/dev/kvm kvm-group qemu-system-x86_64' '$BOC' --runtime vm llm-in-a-box-vmtest >/tmp/llm-in-a-box-vmpmsg2.log 2>&1; [ \$? -ne 0 ] && grep -qx 'operator-marker' '$FIXMSG/vms_and_docker_from_llm_box/README.md'"

# L0 (ADR 013, 2026-09-29): the box's PROJECT directory carries only what
# belongs to the project — the Docker store image prepared at launch and the
# first-reader README. Host-side VM images (base disks) and session overlays
# do NOT land there; they live in the launcher's state directory. Theory: a
# vm invocation with cwd=<scratch> and LLMBOX_STATE_DIR=<scratch>/state
# creates the artifact dir exactly under <scratch> with its README, and
# creates neither a bases/ nor a sessions/ subtree there.
FIXL0=/tmp/llm-in-a-box-vml0
rm -rf "$FIXL0"
mkdir -p "$FIXL0"
check "L0: project dir carries README + store image only; bases live in \$LLMBOX_STATE_DIR" \
    "cd '$FIXL0' && LLMBOX_STATE_DIR='$FIXL0/state' LLMBOX_VM_MISSING='/dev/kvm kvm-group qemu-system-x86_64' '$BOC' --runtime vm llm-in-a-box-vmtest >/tmp/llm-in-a-box-vml0.log 2>&1; [ \$? -ne 0 ] \
        && [ -d '$FIXL0/vms_and_docker_from_llm_box' ] \
        && [ -s '$FIXL0/vms_and_docker_from_llm_box/README.md' ] \
        && [ ! -d '$FIXL0/vms_and_docker_from_llm_box/sessions' ] \
        && [ ! -d '$FIXL0/vms_and_docker_from_llm_box/bases' ]"

# Requirement (ADR 013): the hidden --print-state-dir seam reports the state
# directory the launcher RESOLVED (environment variable > configuration-file
# key > the per-user default), which is what ./build vm consumes so build and
# launch can never disagree about where base images live. Theory: env set wins
# over the configuration file; the configuration file wins over the default;
# unset everywhere falls back to $HOME/.llm-in-a-box.
FIXPSD=/tmp/llm-in-a-box-vm-psd
rm -rf "$FIXPSD"
mkdir -p "$FIXPSD"
printf 'state.dir=%s\n' "$FIXPSD/from-config" > "$FIXPSD/config"
check "--print-state-dir resolves env > config file > default" \
    "[ \"\$(LLMBOX_STATE_DIR='$FIXPSD/from-env' LLMBOX_CONFIG='$FIXPSD/config' '$BOC' --print-state-dir)\" = '$FIXPSD/from-env' ] \
        && [ \"\$(env -u LLMBOX_STATE_DIR LLMBOX_CONFIG='$FIXPSD/config' '$BOC' --print-state-dir)\" = '$FIXPSD/from-config' ] \
        && [ \"\$(env -u LLMBOX_STATE_DIR LLMBOX_CONFIG='$FIXPSD/absent-config' HOME='$FIXPSD/home' '$BOC' --print-state-dir)\" = '$FIXPSD/home/.llm-in-a-box' ]"

# Requirement (kept): an explicit --runtime vm on a host with missing
# prereqs fails with actionable install guidance (scripts test and tell).
make_vm_fixture "$FIXEMPTY"
rm -f "$FIXEMPTY/state/base.qcow2" "$FIXEMPTY/state/vmlinuz"
check "explicit --runtime vm preflight fails with install guidance" \
    "cd '$FIXEMPTY/project' && LLMBOX_STATE_DIR='$FIXEMPTY/state' LLMBOX_VM_MISSING='/dev/kvm kvm-group' '$BOC' --runtime vm llm-in-a-box-vmtest >/tmp/llm-in-a-box-vmp5.log 2>&1; [ \$? -ne 0 ] \
        && grep -q '/dev/kvm' /tmp/llm-in-a-box-vmp5.log \
        && grep -q 'usermod -aG kvm' /tmp/llm-in-a-box-vmp5.log \
        && grep -q 'base disk' /tmp/llm-in-a-box-vmp5.log"

# Requirement (kept): the runtime validation list accepts sysbox|docker|vm
# and still rejects anything else.
check "unknown runtime is rejected" \
    "'$BOC' --runtime bogus llm-in-a-box-vmtest >/tmp/llm-in-a-box-vmp6.log 2>&1; [ \$? -ne 0 ]"

# Requirement (kept): --destroy must work WITHOUT a passing preflight (no
# KVM needed to clean up). A missing session must be a clean no-op.
check "--destroy does not require KVM and is a clean no-op for a missing session" \
    "'$BOC' --runtime vm --destroy llm-in-a-box-vmtest >/tmp/llm-in-a-box-vmp7.log 2>&1; [ \$? -eq 0 ]"

# Requirement (kept): --shutdown must work WITHOUT a passing preflight, and
# a missing session is a clean no-op.
check "--shutdown does not require KVM and is a clean no-op for a missing session" \
    "'$BOC' --runtime vm --shutdown llm-in-a-box-vmtest >/tmp/llm-in-a-box-vmp8.log 2>&1; [ \$? -eq 0 ] \
        && grep -q 'does not exist' /tmp/llm-in-a-box-vmp8.log"

# Requirement (kept): --shutdown must not delete the session (unlike
# --destroy) — it reports "not running" for a session dir that exists but
# has no live qemu, leaving state for resume. The session dir is GLOBAL box
# state (LLMBOX_STATE_DIR/sessions), keyed by session name.
check "--shutdown reports a stopped vm as not running (preserves session)" \
    "mkdir -p /tmp/llm-in-a-box-vmsess/sessions/llm-in-a-box-vmtest && LLMBOX_STATE_DIR=/tmp/llm-in-a-box-vmsess '$BOC' --runtime vm --shutdown llm-in-a-box-vmtest >/tmp/llm-in-a-box-vmp9.log 2>&1; [ \$? -eq 0 ] \
        && grep -q 'not running' /tmp/llm-in-a-box-vmp9.log"

# Requirement (R7, user-reported bug 2026-09-01): qemu -daemonize can leave
# a pidfile whose pid is dead while the daemonized qemu lives under another
# pid. --destroy must find the live process via pgrep (cmdline scan) and
# kill it, even though the pidfile pid is stale, and then remove the
# session. Deterministic on any host: no preflight, no KVM.
# The fake qemu is a sh process whose cmdline looks like a qemu process
# (argv[0] = qemu-system-x86_64, overlay path in the args). It must be a
# REAL binary (sh), not a script: the kernel rewrites argv[0] to the
# interpreter for shebang scripts, so exec -a's name would not appear in
# /proc/<pid>/cmdline and pgrep could not match. It traps TERM with a short
# sleep loop so vm_destroy/vm_shutdown's kill takes effect promptly, and
# its stdio is redirected so the backgrounded process never holds the test
# pipe open.
spawn_fake_qemu() {
    bash -c 'exec -a qemu-system-x86_64 sh -c "trap \"exit 0\" TERM INT; while :; do sleep 0.1; done" x "$0"' "$1" >/dev/null 2>&1 </dev/null &
    echo $!
}

# For the vmkill test: $LLMBOX_STATE_DIR doubles as the launch cwd, so box
# state (sessions/<name>/{qemu.pid,overlay.qcow2}) is under $FIX/sessions —
# the overlay lives with the session metadata (ADR 013), not in the project
# directory.
rm -rf /tmp/llm-in-a-box-vmkill && mkdir -p /tmp/llm-in-a-box-vmkill/sessions/llm-in-a-box-vmtest
touch /tmp/llm-in-a-box-vmkill/sessions/llm-in-a-box-vmtest/overlay.qcow2
echo 999999 > /tmp/llm-in-a-box-vmkill/sessions/llm-in-a-box-vmtest/qemu.pid
FAKE_QEMU_PID=$(spawn_fake_qemu /tmp/llm-in-a-box-vmkill/sessions/llm-in-a-box-vmtest/overlay.qcow2)
sleep 0.5
check "--destroy kills a live qemu found via pgrep when the pidfile pid is stale" \
    "cd /tmp/llm-in-a-box-vmkill && LLMBOX_STATE_DIR=/tmp/llm-in-a-box-vmkill '$BOC' --runtime vm --destroy llm-in-a-box-vmtest >/tmp/llm-in-a-box-vmp10.log 2>&1 \
        && [ \$? -eq 0 ] \
        && proc_dead $FAKE_QEMU_PID \
        && [ ! -d /tmp/llm-in-a-box-vmkill/sessions/llm-in-a-box-vmtest ] \
        && grep -q 'Removed vm session' /tmp/llm-in-a-box-vmp10.log"

# Requirements (R7 + R6, gated on a full set of vm prereqs so the preflight
# passes and the state/attach paths are reachable):
#   - a stale pidfile with a LIVE qemu must ATTACH ("Attaching to running
#     vm"), never relaunch (no "Booting vm" line) — the user-reported
#     "Cannot lock pid file" failure mode;
#   - vm_attach must land the user in /data: a fake ssh shim earlier on
#     PATH captures the remote command and proves it contains "cd /data".
# Skip-not-fail on hosts without qemu-system + /dev/kvm + kvm group (they
# activate on this dev VM after Phase 4 installs qemu + kvm group).
if command -v qemu-system-x86_64 >/dev/null 2>&1 && [ -e /dev/kvm ] \
        && id -nG | grep -w >/dev/null kvm; then
    rm -rf /tmp/llm-in-a-box-vmrun && mkdir -p /tmp/llm-in-a-box-vmrun/project /tmp/llm-in-a-box-vmrun/sessions/llm-in-a-box-vmtest
    qemu-img create -f qcow2 /tmp/llm-in-a-box-vmrun/base.qcow2 1M >/dev/null
    touch /tmp/llm-in-a-box-vmrun/vmlinuz \
        /tmp/llm-in-a-box-vmrun/sessions/llm-in-a-box-vmtest/overlay.qcow2
    echo 999999 > /tmp/llm-in-a-box-vmrun/sessions/llm-in-a-box-vmtest/qemu.pid
    echo 2222 > /tmp/llm-in-a-box-vmrun/sessions/llm-in-a-box-vmtest/ssh_port

    FAKE_QEMU_PID2=$(spawn_fake_qemu /tmp/llm-in-a-box-vmrun/sessions/llm-in-a-box-vmtest/overlay.qcow2)
    sleep 0.5
    check "a stale pidfile with a live qemu attaches instead of relaunching" \
        "cd /tmp/llm-in-a-box-vmrun/project && LLMBOX_STATE_DIR=/tmp/llm-in-a-box-vmrun '$BOC' --runtime vm llm-in-a-box-vmtest >/tmp/llm-in-a-box-vmp11.log 2>&1; \
            grep -q '\[PASS\] base disk' /tmp/llm-in-a-box-vmp11.log \
            && grep -q 'Attaching to running vm' /tmp/llm-in-a-box-vmp11.log \
            && ! grep -q 'Booting vm' /tmp/llm-in-a-box-vmp11.log"
    kill $FAKE_QEMU_PID2 2>/dev/null || true

    # Fresh fake qemu: the previous check's fake was killed in its cleanup,
    # and this check needs a LIVE process so the running path (vm_attach)
    # is reached instead of a relaunch.
    FAKE_QEMU_PID3=$(spawn_fake_qemu /tmp/llm-in-a-box-vmrun/sessions/llm-in-a-box-vmtest/overlay.qcow2)
    sleep 0.5
    mkdir -p /tmp/llm-in-a-box-fakessh
    printf '#!/bin/bash\necho "SSHARGS: $@"\nexit 0\n' > /tmp/llm-in-a-box-fakessh/ssh
    chmod +x /tmp/llm-in-a-box-fakessh/ssh
    check "vm attach lands the user in /data" \
        "cd /tmp/llm-in-a-box-vmrun/project && PATH=/tmp/llm-in-a-box-fakessh:\$PATH LLMBOX_STATE_DIR=/tmp/llm-in-a-box-vmrun '$BOC' --runtime vm llm-in-a-box-vmtest >/tmp/llm-in-a-box-vmp12.log 2>&1 \
            && grep -q 'cd /data' /tmp/llm-in-a-box-vmp12.log"
    kill $FAKE_QEMU_PID3 2>/dev/null || true

else
    skip "stale-pidfile attach + /data landing checks (need qemu-system + /dev/kvm + kvm group — run under 'sg kvm' on hosts where the user is in the group)"
fi


# ── store image launcher checks ───────────────────────────────────────────
# The store helper checks (L1-L8b, L10) called the bash launcher's functions
# after sourcing it; they live in the Rust crate's unit tests now and are
# listed here as skips so the count stays honest. L7c and L9-L13 drive the
# real launcher and stay.
LWORK=$(mktemp -d /tmp/llm-in-a-box-vmstore-lib.XXXXXX)
mkdir -p "$LWORK/origin" "$LWORK/session" "$LWORK/projA"
# The per-project artifact directory (ADR 013): the store image lives in the
# vms_and_docker_from_llm_box subdirectory of the box's PROJECT directory,
# which for a session that has not recorded an origin yet is the working
# directory (vm_project_dir). Each check cd's into a scratch project dir, so
# the image lands under that project's vms_and_docker_from_llm_box
# subdirectory; LLMBOX_STATE_DIR has no influence on the store image path
# (the store belongs to the project, not to the machine).
LPROJ_A="$LWORK/projA"
LSTATEDIR_A="$LWORK/projA/vms_and_docker_from_llm_box"
LIMG_A="$LSTATEDIR_A/docker-store.img"

# Token helpers for the argv checks below. The library emits ONE argv
# token per line; these helpers assert the token sequence instead of
# grepping for a whole "option value" line, which is exactly the
# content-only assertion that let the 2026-09-11 launch defect through.
#
# argv_pair <file> <option> <value>: 0 when <option> is immediately
# followed by <value> in the token-per-line record (exact adjacency, not
# mere co-presence).
argv_pair() {
    awk -v opt="$2" -v val="$3" '
        { tok[NR] = $0 }
        END {
            for (i = 1; i < NR; i++) {
                if (tok[i] == opt && tok[i+1] == val) exit 0
            }
            exit 1
        }' "$1"
}
# no_option_pair <file>: 0 when no token is a space-joined option pair
# (e.g. "-accel tcg,thread=multi"). A value token may contain a space
# (paths with spaces stay one token) because it does not start with "-".
no_option_pair() {
    ! grep -Eq '^-[^ ]+ ' "$1"
}

skip "L1: launch args attach the store image as an NVMe device (moved to the Rust crate's unit tests)"
skip "L2: the store0 9p export is gone and host0/seed0 are kept (moved to the Rust crate's unit tests)"
skip "L3: the image is created once at the requested size with mode 0600 (moved to the Rust crate's unit tests)"
skip "L3b: a zero-length existing image is refused (moved to the Rust crate's unit tests)"
skip "L3c: a size-mismatched existing image is refused (moved to the Rust crate's unit tests)"
skip "L3d: a successful prepare reports the resolved absolute image path in STORE_IMG (moved to the Rust crate's unit tests)"
skip "L3e: a size resolving to zero bytes is refused before any file is created (moved to the Rust crate's unit tests)"
skip "L3f: the default store image size is 500G when LLMBOX_VM_STORE_IMG_SIZE is unset (moved to the Rust crate's unit tests)"
skip "L4: the store image is created at exactly \$PROJECT_ROOT/vms_and_docker_from_llm_box/docker-store.img (LLMBOX_STATE_DIR ignored) (moved to the Rust crate's unit tests)"
skip "L4b: LLMBOX_VM_STORE_DISABLE skips creation and attachment (moved to the Rust crate's unit tests)"
skip "L5: symlink, directory, and invalid size are refused (moved to the Rust crate's unit tests)"
skip "L5d: a symlink at the state-dir path itself is refused (moved to the Rust crate's unit tests)"
skip "L6: a second writer is refused while the lock is held (moved to the Rust crate's unit tests)"
skip "L6b: two project dirs yield two independent store images and locks (moved to the Rust crate's unit tests)"
skip "L7: LLMBOX_VM_ACCEL=tcg drops the KVM requirement and selects TCG (moved to the Rust crate's unit tests)"
skip "L7b: the default still requires KVM and passes -enable-kvm (moved to the Rust crate's unit tests)"

# L7c: the preflight skip itself (not just the library predicate). The
# docs say LLMBOX_VM_ACCEL=tcg skips the /dev/kvm and kvm-group preflight
# checks; L7/L7b only exercise vm_kvm_required/vm_accel_args. This check
# runs the REAL launcher with both prerequisites forced missing via
# LLMBOX_VM_MISSING and asserts the skip line appears and neither check is
# reported [FAIL]. Theory: with TCG selected the preflight takes the
# "checks skipped" branch regardless of LLMBOX_VM_MISSING, so the log shows
# the INFO line and no failure lines; the fake qemu answers --version
# and writes a dead pid to -pidfile so the launch attempt after the
# preflight fails fast instead of waiting for ssh.
rm -rf /tmp/llm-in-a-box-fakeqemu-preflight "$FIXQEMU/vms_and_docker_from_llm_box/docker-store.img"
mkdir -p /tmp/llm-in-a-box-fakeqemu-preflight
cat > /tmp/llm-in-a-box-fakeqemu-preflight/qemu-system-x86_64 <<'FAKEQEMU'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
echo "QEMU emulator version 8.2.2 (fake)"
exit 0
fi
prev=""
for a in "$@"; do
if [ "$prev" = "-pidfile" ]; then echo 999999 > "$a"; fi
prev="$a"
done
exit 0
FAKEQEMU
chmod +x /tmp/llm-in-a-box-fakeqemu-preflight/qemu-system-x86_64
check "L7c: LLMBOX_VM_ACCEL=tcg skips the /dev/kvm and kvm-group preflight checks in the real launcher" \
    "cd '$FIXQEMU' && LLMBOX_STATE_DIR='$FIXQEMU/state' PATH=/tmp/llm-in-a-box-fakeqemu-preflight:\$PATH LLMBOX_VM_MISSING='/dev/kvm kvm-group' \
        LLMBOX_VM_ACCEL=tcg LLMBOX_VM_STORE_IMG_SIZE=64M \
        timeout 30 '$BOC' --runtime vm llm-in-a-box-vmtest >/tmp/llm-in-a-box-vmpqemu3.log 2>&1 || true; \
     grep -q 'checks skipped' /tmp/llm-in-a-box-vmpqemu3.log \
        && ! grep -q '\[FAIL\] /dev/kvm' /tmp/llm-in-a-box-vmpqemu3.log \
        && ! grep -q '\[FAIL\] kvm group' /tmp/llm-in-a-box-vmpqemu3.log"
rm -f "$FIXQEMU/vms_and_docker_from_llm_box/docker-store.img"

skip "L8: free-space and base-current checks are value-driven (moved to the Rust crate's unit tests)"
skip "L8b: the warning helpers warn on low space / stale base and stay silent otherwise (moved to the Rust crate's unit tests)"

# L9: end-to-end behavior through the REAL launcher: argv tokenization,
# the session store-image record, the operator warnings, and the
# user-owned VM files. Requirement: qemu must receive every option and
# its value as SEPARATE argv tokens (-accel then tcg,thread=multi;
# -drive then file=...; -device then nvme,...). The 2026-09-11 launch
# defect was the library printing "option value" lines and the launcher
# passing each line as one token, so qemu aborted with "invalid option"
# before any guest booted. Content-only library checks cannot catch
# that; this check runs the real launcher. Theory: a recording fake
# qemu first on PATH writes every argv token on its own line, records
# the uid it runs as, and answers --version at the 5.0 floor; it writes
# a dead pid to -pidfile so the launcher's ssh wait fails fast instead
# of polling 240s. A fake df reports 100 KiB free so the free-space
# warning fires on first creation, and the session records an older
# versioned base so the stale-base warning fires. The assertions are
# exact adjacency for -accel/-drive/-device/-virtfs, "no token is a
# space-joined option pair", the store-img record, both warnings, and
# the overlay's user ownership plus qemu's invoking uid. Guarded on
# docker (the launcher hard-requires it) and qemu-img (real overlay
# creation): skip-not-fail otherwise.
if command -v docker >/dev/null 2>&1 && command -v qemu-img >/dev/null 2>&1; then
    L9FIX=/tmp/llm-in-a-box-vmargv
    L9REC="$L9FIX/argv.record"
    L9UID="$L9FIX/qemu-uid.record"
    L9_FAKE=/tmp/llm-in-a-box-fakeqemu-record
    rm -rf "$L9FIX" "$L9_FAKE"
    # Versioned base layout: the session records the OLD base while
    # bases/latest points at the NEW one, so the real launcher must warn
    # that the session predates the latest build. Storage split (ADR 013):
    # host-side VM images (bases, the session overlay) live in the launcher's
    # state directory ($L9_STATE), while the box's PROJECT directory
    # ($L9FIX/project, the cwd, mounted as /data) keeps only the Docker store
    # image and the first-reader message. The launcher runs with
    # cwd=L9FIX/project and LLMBOX_STATE_DIR=L9FIX/state.
    L9_OLD=20260101-000000-00001
    L9_NEW=20260102-000000-00002
    L9_ART="$L9FIX/project/vms_and_docker_from_llm_box"
    L9_STATE="$L9FIX/state"
    mkdir -p "$L9_STATE/bases/$L9_OLD" "$L9_STATE/bases/$L9_NEW" \
             "$L9FIX/project" "$L9FIX/home/.ssh" "$L9_FAKE" \
             "$L9_STATE/sessions/llm-in-a-box-vmargv"
    qemu-img create -f qcow2 "$L9_STATE/bases/$L9_OLD/base.qcow2" 1M >/dev/null
    qemu-img create -f qcow2 "$L9_STATE/bases/$L9_NEW/base.qcow2" 1M >/dev/null
    touch "$L9_STATE/bases/$L9_OLD/vmlinuz" "$L9_STATE/bases/$L9_NEW/vmlinuz"
    # Box-user era stamps: ./build vm stamps every base; lbx refuses to
    # boot a base WITHOUT the stamp (old tooling).
    echo agent > "$L9_STATE/bases/$L9_OLD/built-user"
    echo agent > "$L9_STATE/bases/$L9_NEW/built-user"
    ln -s "$L9_NEW" "$L9_STATE/bases/latest"
    echo "$L9_OLD" > "$L9_STATE/sessions/llm-in-a-box-vmargv/base"
    printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDummyKeyForArgvTest argv-test\n' > "$L9FIX/home/.ssh/id_ed25519.pub"
    cat > "$L9_FAKE/qemu-system-x86_64" <<'FAKEQEMU'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
echo "QEMU emulator version 8.2.2 (recording fake)"
exit 0
fi
if [ -n "${QEMU_ARGV_RECORD:-}" ]; then
: > "$QEMU_ARGV_RECORD"
for a in "$@"; do printf '%s\n' "$a" >> "$QEMU_ARGV_RECORD"; done
fi
if [ -n "${QEMU_UID_RECORD:-}" ]; then
id -u > "$QEMU_UID_RECORD"
fi
prev=""
for a in "$@"; do
if [ "$prev" = "-pidfile" ]; then echo 999999 > "$a"; fi
prev="$a"
done
exit 0
FAKEQEMU
    chmod +x "$L9_FAKE/qemu-system-x86_64"
    # Fake df: 100 KiB free, below the 64M configured size, so the
    # launcher's first-creation free-space warning is exercised.
    cat > "$L9_FAKE/df" <<'FAKEDF'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'fake 1 1 100 1%% /\n'
FAKEDF
    chmod +x "$L9_FAKE/df"
    rm -f "$L9REC" "$L9UID" "$L9_ART/docker-store.img"
    ( cd "$L9FIX/project" && \
      PATH="$L9_FAKE:$PATH" \
      HOME="$L9FIX/home" \
      LLMBOX_STATE_DIR="$L9FIX/state" \
      LLMBOX_VM_ACCEL=tcg \
      LLMBOX_VM_STORE_IMG_SIZE=64M \
      QEMU_ARGV_RECORD="$L9REC" \
      QEMU_UID_RECORD="$L9UID" \
      timeout 60 "$BOC" --runtime vm llm-in-a-box-vmargv >"$L9FIX/launch.log" 2>&1 || true )
    L9_IMG_REAL=$(realpath -m "$L9_ART/docker-store.img")
    check "L9: the real launcher passes each qemu option and value as separate argv tokens" \
        "[ -s '$L9REC' ] \
            && argv_pair '$L9REC' -accel 'tcg,thread=multi' \
            && argv_pair '$L9REC' -drive 'file=$L9_ART/docker-store.img,if=none,id=store0,format=raw,cache=writeback,discard=unmap' \
            && argv_pair '$L9REC' -device 'nvme,drive=store0,serial=lbx-docker-store' \
            && argv_pair '$L9REC' -virtfs 'local,path=$L9FIX/project,mount_tag=host0,security_model=none' \
            && argv_pair '$L9REC' -virtfs 'local,path=$L9_STATE/sessions/llm-in-a-box-vmargv,mount_tag=seed0,security_model=none,readonly=on' \
            && no_option_pair '$L9REC'"
    # L9b: the real launcher records the resolved image path in the
    # (global) session state dir (the host-side e2e checks read this record).
    check "L9b: the real launcher records the resolved store-image path in sessions/<name>/store-img" \
        "[ -f '$L9_STATE/sessions/llm-in-a-box-vmargv/store-img' ] \
            && [ \"\$(cat '$L9_STATE/sessions/llm-in-a-box-vmargv/store-img')\" = '$L9_IMG_REAL' ]"
    # L9c: the real launcher prints the free-space and stale-base
    # warnings (L8/L8b only exercise the helper functions).
    check "L9c: the real launcher warns on low free space and on a session base that predates latest" \
        "grep -q 'WARNING: low free space' '$L9FIX/launch.log' \
            && grep -q 'predates the latest build' '$L9FIX/launch.log'"
    # L9d: VM files are plain user-owned host files: the overlay the real
    # launcher creates is a regular file owned by the invoking user, and
    # the fake qemu records that it was invoked as the invoking user
    # (the launcher does not elevate). The overlay is host-side VM state in
    # the session directory (ADR 013), not a project artifact.
    check "L9d: the real launcher creates the overlay as a user-owned regular file and runs qemu as the invoking user" \
        "[ -f '$L9_STATE/sessions/llm-in-a-box-vmargv/overlay.qcow2' ] \
            && [ \"\$(stat -c %F '$L9_STATE/sessions/llm-in-a-box-vmargv/overlay.qcow2')\" = 'regular file' ] \
            && [ \"\$(stat -c %u '$L9_STATE/sessions/llm-in-a-box-vmargv/overlay.qcow2')\" = \"\$(id -u)\" ] \
            && [ ! -e '$L9_ART/sessions' ] \
            && [ -s '$L9UID' ] && [ \"\$(cat '$L9UID')\" = \"\$(id -u)\" ]"
    # L9g (ADR 013): qemu's serial console output (the guest's ttyS0) is
    # captured in the session directory inside the STATE directory — the same
    # place as the overlay and the session metadata, never the project
    # directory (README troubleshooting: "read the journals").
    check "L9g: qemu's serial console is captured in the session directory of the state directory" \
        "argv_pair '$L9REC' -serial 'file:$L9_STATE/sessions/llm-in-a-box-vmargv/console.log'"
    rm -rf "$L9FIX" "$L9_FAKE"
else
    skip "L9: real-launcher argv tokenization and operator warnings (needs docker + qemu-img)"
fi

# L9e (2026-09-20): the OLD-box gate. ./build vm stamps every base with
# bases/<ts>/built-user; a base WITHOUT the stamp was built by old tooling
# (in-box user 'agent') and lbx must REFUSE to boot it, recommending the
# previous launcher, without invoking qemu. Same rig as L9 (recording fake
# qemu + fake df + tcg) but the base carries NO built-user marker.
if command -v docker >/dev/null 2>&1 && command -v qemu-img >/dev/null 2>&1; then
    L9EFIX=/tmp/llm-in-a-box-vmold
    L9EREC="$L9EFIX/argv.record"
    L9E_FAKE=/tmp/llm-in-a-box-fakeqemu-old
    rm -rf "$L9EFIX" "$L9E_FAKE"
    L9E_ART="$L9EFIX/project/vms_and_docker_from_llm_box"
    L9E_STATE="$L9EFIX/state"
    mkdir -p "$L9E_STATE/bases/20260101-000000-old" \
             "$L9EFIX/project" "$L9EFIX/home/.ssh" "$L9E_FAKE" \
             "$L9E_STATE/sessions/llm-in-a-box-vmold"
    qemu-img create -f qcow2 "$L9E_STATE/bases/20260101-000000-old/base.qcow2" 1M >/dev/null
    touch "$L9E_STATE/bases/20260101-000000-old/vmlinuz"
    ln -s 20260101-000000-old "$L9E_STATE/bases/latest"
    printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDummyKeyForArgvTest argv-old\n' > "$L9EFIX/home/.ssh/id_ed25519.pub"
    cat > "$L9E_FAKE/qemu-system-x86_64" <<'FAKEQEMU'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
echo "QEMU emulator version 8.2.2 (recording fake)"
exit 0
fi
if [ -n "${QEMU_ARGV_RECORD:-}" ]; then
: > "$QEMU_ARGV_RECORD"
for a in "$@"; do printf '%s\n' "$a" >> "$QEMU_ARGV_RECORD"; done
fi
prev=""
for a in "$@"; do
if [ "$prev" = "-pidfile" ]; then echo 999999 > "$a"; fi
prev="$a"
done
exit 0
FAKEQEMU
    chmod +x "$L9E_FAKE/qemu-system-x86_64"
    cat > "$L9E_FAKE/df" <<'FAKEDF'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'fake 1 1 100 1%% /\n'
FAKEDF
    chmod +x "$L9E_FAKE/df"
    rm -f "$L9EREC" "$L9E_ART/docker-store.img"
    ( cd "$L9EFIX/project" && \
      PATH="$L9E_FAKE:$PATH" \
      HOME="$L9EFIX/home" \
      LLMBOX_STATE_DIR="$L9EFIX/state" \
      LLMBOX_VM_ACCEL=tcg \
      LLMBOX_VM_STORE_IMG_SIZE=64M \
      QEMU_ARGV_RECORD="$L9EREC" \
      timeout 30 "$BOC" --runtime vm llm-in-a-box-vmold >"$L9EFIX/launch.log" 2>&1 || true )
    check "L9e: lbx refuses to boot an OLD base (no box-user stamp) and recommends the previous launcher" \
        "grep -q 'OLD base image' '$L9EFIX/launch.log' \
            && grep -q 'previous llm_in_a_box script' '$L9EFIX/launch.log' \
            && [ ! -s '$L9EREC' ]"
    rm -rf "$L9EFIX" "$L9E_FAKE"
else
    skip "L9e: old-base boot refusal (needs docker + qemu-img)"
fi

# L9f (2026-09-20): config/env parity + --publish for the vm runtime.
# Requirement: precedence is CLI > env > config > default (vm.mem via the
# config-file key vs the LLMBOX_VM_MEM env var), and --publish translates
# to qemu hostfwd. Theory: the recording fake qemu captures the boot argv;
# run A (config vm.mem=2048, no env) must show -m 2048; run B (same
# config + env 4096) must show -m 4096 (env beats file); run C with
# --publish 8080:80 must show the hostfwd entry.
if command -v docker >/dev/null 2>&1 && command -v qemu-img >/dev/null 2>&1; then
    L9FFIX=/tmp/llm-in-a-box-vmpar
    L9F_FAKE=/tmp/llm-in-a-box-fakeqemu-par
    rm -rf "$L9FFIX" "$L9F_FAKE"
    L9F_ART="$L9FFIX/project/vms_and_docker_from_llm_box"
    L9F_STATE="$L9FFIX/state"
    mkdir -p "$L9F_STATE/bases/20260101-000000-par" \
             "$L9FFIX/project" "$L9FFIX/home/.ssh" "$L9F_FAKE" \
             "$L9FFIX/home/.config/llm_in_a_box"
    qemu-img create -f qcow2 "$L9F_STATE/bases/20260101-000000-par/base.qcow2" 1M >/dev/null
    touch "$L9F_STATE/bases/20260101-000000-par/vmlinuz"
    echo agent > "$L9F_STATE/bases/20260101-000000-par/built-user"
    ln -s 20260101-000000-par "$L9F_STATE/bases/latest"
    printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDummyKeyForArgvTest argv-par\n' > "$L9FFIX/home/.ssh/id_ed25519.pub"
    printf 'vm.mem=2048\n' > "$L9FFIX/home/.config/llm_in_a_box/config"
    cat > "$L9F_FAKE/qemu-system-x86_64" <<'FAKEQEMU'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
echo "QEMU emulator version 8.2.2 (recording fake)"
exit 0
fi
if [ -n "${QEMU_ARGV_RECORD:-}" ]; then
: > "$QEMU_ARGV_RECORD"
for a in "$@"; do printf '%s\n' "$a" >> "$QEMU_ARGV_RECORD"; done
fi
prev=""
for a in "$@"; do
if [ "$prev" = "-pidfile" ]; then echo 999999 > "$a"; fi
prev="$a"
done
exit 0
FAKEQEMU
    chmod +x "$L9F_FAKE/qemu-system-x86_64"
    cat > "$L9F_FAKE/df" <<'FAKEDF'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'fake 1 1 100 1%% /\n'
FAKEDF
    chmod +x "$L9F_FAKE/df"
    rm -f "$L9F_ART/docker-store.img"
    ( cd "$L9FFIX/project" && \
      PATH="$L9F_FAKE:$PATH" HOME="$L9FFIX/home" \
      LLMBOX_STATE_DIR="$L9FFIX/state" \
      LLMBOX_VM_ACCEL=tcg LLMBOX_VM_STORE_IMG_SIZE=64M \
      QEMU_ARGV_RECORD="$L9FFIX/a.rec" \
      timeout 30 "$BOC" --runtime vm l9f-a >"$L9FFIX/a.log" 2>&1 || true )
    check "L9f config vm.mem applies when the env var is unset (CLI > env > config > default)" \
        "argv_pair '$L9FFIX/a.rec' -m '2048'"
    rm -f "$L9F_ART/docker-store.img"
    ( cd "$L9FFIX/project" && \
      PATH="$L9F_FAKE:$PATH" HOME="$L9FFIX/home" \
      LLMBOX_STATE_DIR="$L9FFIX/state" \
      LLMBOX_VM_MEM=4096 \
      LLMBOX_VM_ACCEL=tcg LLMBOX_VM_STORE_IMG_SIZE=64M \
      QEMU_ARGV_RECORD="$L9FFIX/b.rec" \
      timeout 30 "$BOC" --runtime vm l9f-b >"$L9FFIX/b.log" 2>&1 || true )
    check "L9f the env var beats the config key (vm.mem)" \
        "argv_pair '$L9FFIX/b.rec' -m '4096'"
    rm -f "$L9F_ART/docker-store.img"
    ( cd "$L9FFIX/project" && \
      PATH="$L9F_FAKE:$PATH" HOME="$L9FFIX/home" \
      LLMBOX_STATE_DIR="$L9FFIX/state" \
      LLMBOX_VM_ACCEL=tcg LLMBOX_VM_STORE_IMG_SIZE=64M \
      QEMU_ARGV_RECORD="$L9FFIX/c.rec" \
      timeout 30 "$BOC" --runtime vm --publish 8080:80 l9f-c >"$L9FFIX/c.log" 2>&1 || true )
    check "L9f --publish adds a qemu hostfwd for the vm runtime" \
        "grep -q 'hostfwd=tcp::8080-:80' '$L9FFIX/c.rec'"
    rm -rf "$L9FFIX" "$L9F_FAKE"
else
    skip "L9f: vm config parity + --publish (needs docker + qemu-img)"
fi
rm -rf "$LWORK"


# ── L10: versioned base beats the legacy flat layout ────────────────
# Requirement (documented in README "Runtime Auto-Detection"): when BOTH
# a versioned base (bases/latest) and the legacy flat layout (base.qcow2 at
# the state directory root) exist, the versioned base wins. Theory:
# vm_resolve_base's precedence (session record > latest > legacy flat) is the
# observable contract; a sourced call with a fixture carrying both proves the
# versioned side is chosen. The state directory is set explicitly and the
# call runs with cwd=/, so this also proves base resolution does not depend
# on the working directory (ADR 013).
skip "L10: with both a versioned base and the legacy flat layout, the versioned base is resolved (moved to the Rust crate's unit tests)"

# ── L11 (ADR 013): a relaunch from ANOTHER directory uses the session's own
# project directory ───────────────────────────────────────────────────────
# Requirement: the /data mount and every project-scoped artifact are resolved
# from the session's recorded first-launch directory, never from the current
# working directory, so a box stays usable from anywhere. Theory: run the
# real launcher twice with the recording fake qemu and ONE state directory —
# first from project A (which the session records as its origin), then from
# project B. The second run's argv must mount A as host0 and attach A's
# Docker store image (the pre-ADR-013 launcher attached the cwd's image), the
# second run must create nothing in B, and the overlay must still be the one
# the first run created (same inode), proving no fresh disk was made.
write_recording_fake_qemu() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/qemu-system-x86_64" <<'FAKEQEMU'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
echo "QEMU emulator version 8.2.2 (recording fake)"
exit 0
fi
if [ -n "${QEMU_ARGV_RECORD:-}" ]; then
: > "$QEMU_ARGV_RECORD"
for a in "$@"; do printf '%s\n' "$a" >> "$QEMU_ARGV_RECORD"; done
fi
prev=""
for a in "$@"; do
if [ "$prev" = "-pidfile" ]; then echo 999999 > "$a"; fi
prev="$a"
done
exit 0
FAKEQEMU
    chmod +x "$dir/qemu-system-x86_64"
    cat > "$dir/df" <<'FAKEDF'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'fake 1 1 100 1%% /\n'
FAKEDF
    chmod +x "$dir/df"
}

if command -v docker >/dev/null 2>&1 && command -v qemu-img >/dev/null 2>&1; then
    L11FIX=/tmp/llm-in-a-box-vm-relocate
    L11_FAKE=/tmp/llm-in-a-box-fakeqemu-relocate
    rm -rf "$L11FIX" "$L11_FAKE"
    write_recording_fake_qemu "$L11_FAKE"
    L11_A="$L11FIX/projectA"
    L11_B="$L11FIX/projectB"
    L11_S="$L11FIX/state"
    mkdir -p "$L11_A" "$L11_B" "$L11FIX/home/.ssh" "$L11_S/bases/20260101-000000-rel"
    qemu-img create -f qcow2 "$L11_S/bases/20260101-000000-rel/base.qcow2" 1M >/dev/null
    touch "$L11_S/bases/20260101-000000-rel/vmlinuz"
    echo agent > "$L11_S/bases/20260101-000000-rel/built-user"
    ln -s 20260101-000000-rel "$L11_S/bases/latest"
    printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDummyKeyForArgvTest relocate\n' > "$L11FIX/home/.ssh/id_ed25519.pub"
    ( cd "$L11_A" && PATH="$L11_FAKE:$PATH" HOME="$L11FIX/home" \
      LLMBOX_STATE_DIR="$L11_S" LLMBOX_VM_ACCEL=tcg LLMBOX_VM_STORE_IMG_SIZE=64M \
      QEMU_ARGV_RECORD="$L11FIX/a.rec" \
      timeout 30 "$BOC" --runtime vm l11relocate >"$L11FIX/a.log" 2>&1 || true )
    L11_INODE=$(stat -c %i "$L11_S/sessions/l11relocate/overlay.qcow2" 2>/dev/null || echo none)
    ( cd "$L11_B" && PATH="$L11_FAKE:$PATH" HOME="$L11FIX/home" \
      LLMBOX_STATE_DIR="$L11_S" LLMBOX_VM_ACCEL=tcg LLMBOX_VM_STORE_IMG_SIZE=64M \
      QEMU_ARGV_RECORD="$L11FIX/b.rec" \
      timeout 30 "$BOC" --runtime vm l11relocate >"$L11FIX/b.log" 2>&1 || true )
    check "L11: a relaunch from another directory mounts and attaches the session's own project directory" \
        "[ -s '$L11FIX/b.rec' ] \
            && grep -qxF -- 'local,path=$L11_A,mount_tag=host0,security_model=none' '$L11FIX/b.rec' \
            && grep -qxF -- 'file=$L11_A/vms_and_docker_from_llm_box/docker-store.img,if=none,id=store0,format=raw,cache=writeback,discard=unmap' '$L11FIX/b.rec' \
            && [ ! -e '$L11_B/vms_and_docker_from_llm_box' ]"
    check "L11b: the relaunch reuses the session's overlay (no fresh disk)" \
        "[ '$L11_INODE' != none ] \
            && [ \"\$(stat -c %i '$L11_S/sessions/l11relocate/overlay.qcow2' 2>/dev/null)\" = '$L11_INODE' ]"
    rm -rf "$L11FIX" "$L11_FAKE"
else
    skip "L11: cross-directory relaunch (needs docker + qemu-img)"
fi

# ── L12 (ADR 013 safety): a pre-ADR-013 overlay is refused, never replaced ─
# Requirement: a session whose overlay still sits in the project directory
# (the layout ADR 013 replaced) must not be silently relaunched onto a fresh
# disk — that would boot a pristine guest and strand the session's data.
# Theory: fixture with a session record, a versioned base in the state
# directory, and an overlay ONLY at <origin>/vms_and_docker_from_llm_box/
# sessions/<name>/overlay.qcow2. The launch must fail naming the earlier
# layout, create no overlay in the state directory, and never invoke qemu
# (empty argv record).
if command -v docker >/dev/null 2>&1 && command -v qemu-img >/dev/null 2>&1; then
    L12FIX=/tmp/llm-in-a-box-vm-legacyoverlay
    L12_FAKE=/tmp/llm-in-a-box-fakeqemu-legacy
    rm -rf "$L12FIX" "$L12_FAKE"
    write_recording_fake_qemu "$L12_FAKE"
    L12_P="$L12FIX/project"
    L12_S="$L12FIX/state"
    mkdir -p "$L12_P" "$L12FIX/home/.ssh" "$L12_S/bases/20260101-000000-lo" "$L12_S/sessions/l12legacy"
    qemu-img create -f qcow2 "$L12_S/bases/20260101-000000-lo/base.qcow2" 1M >/dev/null
    touch "$L12_S/bases/20260101-000000-lo/vmlinuz"
    echo agent > "$L12_S/bases/20260101-000000-lo/built-user"
    ln -s 20260101-000000-lo "$L12_S/bases/latest"
    echo 20260101-000000-lo > "$L12_S/sessions/l12legacy/base"
    printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDummyKeyForArgvTest legacy\n' > "$L12FIX/home/.ssh/id_ed25519.pub"
    mkdir -p "$L12_P/vms_and_docker_from_llm_box/sessions/l12legacy"
    qemu-img create -f qcow2 -F qcow2 -b "$L12_S/bases/20260101-000000-lo/base.qcow2" \
        "$L12_P/vms_and_docker_from_llm_box/sessions/l12legacy/overlay.qcow2" >/dev/null
    ( cd "$L12_P" && PATH="$L12_FAKE:$PATH" HOME="$L12FIX/home" \
      LLMBOX_STATE_DIR="$L12_S" LLMBOX_VM_ACCEL=tcg LLMBOX_VM_STORE_IMG_SIZE=64M \
      QEMU_ARGV_RECORD="$L12FIX/a.rec" \
      timeout 30 "$BOC" --runtime vm l12legacy >"$L12FIX/a.log" 2>&1 || true )
    check "L12: a pre-ADR-013 overlay in the project directory is refused, never silently replaced" \
        "grep -q 'earlier layout exists at' '$L12FIX/a.log' \
            && [ ! -e '$L12_S/sessions/l12legacy/overlay.qcow2' ] \
            && [ ! -s '$L12FIX/a.rec' ]"
    rm -rf "$L12FIX" "$L12_FAKE"
else
    skip "L12: pre-ADR-013 overlay refusal (needs docker + qemu-img)"
fi

# ── L13 (ADR 013 migration aid): a pre-ADR-013 base is reported with its
# location ────────────────────────────────────────────────────────────────
# Requirement: a session created before the layout change recorded a base
# that lived under the PROJECT directory. Its recorded base is missing from
# the state directory, which is a hard error (a live overlay must never be
# rebased), but the error must say WHERE the old base is and how to move it
# — "no longer exists" would be false and would leave the operator with no
# way forward. Theory: fixture with the session recording base `oldts`, the
# state directory holding only `newts` (latest), and `oldts` present under
# the recorded project directory's vms_and_docker_from_llm_box/bases. The
# launch must fail naming the legacy directory, create no overlay, and never
# invoke qemu (empty argv record).
if command -v docker >/dev/null 2>&1 && command -v qemu-img >/dev/null 2>&1; then
    L13FIX=/tmp/llm-in-a-box-vm-legacybase
    L13_FAKE=/tmp/llm-in-a-box-fakeqemu-legacybase
    rm -rf "$L13FIX" "$L13_FAKE"
    write_recording_fake_qemu "$L13_FAKE"
    L13_P="$L13FIX/project"
    L13_S="$L13FIX/state"
    mkdir -p "$L13_S/bases/newts" "$L13_P/vms_and_docker_from_llm_box/bases/oldts" \
             "$L13FIX/home/.ssh" "$L13_S/sessions/l13legacy"
    qemu-img create -f qcow2 "$L13_S/bases/newts/base.qcow2" 1M >/dev/null
    touch "$L13_S/bases/newts/vmlinuz"; echo agent > "$L13_S/bases/newts/built-user"
    ln -s newts "$L13_S/bases/latest"
    qemu-img create -f qcow2 "$L13_P/vms_and_docker_from_llm_box/bases/oldts/base.qcow2" 1M >/dev/null
    touch "$L13_P/vms_and_docker_from_llm_box/bases/oldts/vmlinuz"
    echo agent > "$L13_P/vms_and_docker_from_llm_box/bases/oldts/built-user"
    echo oldts > "$L13_S/sessions/l13legacy/base"
    printf '%s\n' "$L13_P" > "$L13_S/sessions/l13legacy/origin"
    printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDummyKeyForArgvTest legacybase\n' > "$L13FIX/home/.ssh/id_ed25519.pub"
    ( cd "$L13_P" && PATH="$L13_FAKE:$PATH" HOME="$L13FIX/home" \
      LLMBOX_STATE_DIR="$L13_S" LLMBOX_VM_ACCEL=tcg LLMBOX_VM_STORE_IMG_SIZE=64M \
      QEMU_ARGV_RECORD="$L13FIX/a.rec" \
      timeout 30 "$BOC" --runtime vm l13legacy >"$L13FIX/a.log" 2>&1 || true )
    check "L13: a pre-ADR-013 base is named with its location, not reported as gone" \
        "grep -q 'earlier layout exists at' '$L13FIX/a.log' \
            && grep -qF "$L13_P/vms_and_docker_from_llm_box/bases/oldts" '$L13FIX/a.log' \
            && [ ! -e '$L13_S/sessions/l13legacy/overlay.qcow2' ] \
            && [ ! -s '$L13FIX/a.rec' ]"
    rm -rf "$L13FIX" "$L13_FAKE"
else
    skip "L13: pre-ADR-013 base location message (needs docker + qemu-img)"
fi

echo ""
echo "test_llm_in_a_box_vm.sh: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
docker rm -f llm-in-a-box-vmtest >/dev/null 2>&1 || true
pkill -f 'qemu-system-x86_64.*/tmp/llm-in-a-box-vm' 2>/dev/null || true
pkill -f 'llm-in-a-box-qshim' 2>/dev/null || true
[ "$FAIL" -eq 0 ]
