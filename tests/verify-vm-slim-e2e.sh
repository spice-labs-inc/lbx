#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-vm-slim-e2e.sh — the scenario a user actually runs, end to end, on a
# real host: build the slim vm image + base disk, boot a guest, and configure
# it from inside.
#
# WHAT THIS PINS (each of these failed for a user at least once):
#   1. `./build --slim vm` BUILDS the image. It must not reuse an existing
#      `:vm-slim` tag, because that is how a base disk ends up built from an
#      image that predates the scripts just edited — the new box then
#      reproduces the old bug.
#   2. the base it produces records the CURRENT image id and the `core` mode,
#      so a slim session picks it and the provenance warning stays quiet;
#   3. the guest boots and `lbx-setup --list` works there (no curses);
#   4. `lbx-setup` on a terminal whose terminfo is missing (TERM=xterm-kitty)
#      falls back to the plain menu and installs what was picked;
#   5. a step that cannot run reports a USEFUL error (the design step without a
#      package names the release page and the exact command), instead of a
#      generic failure.
#
# Needs: docker (to build), qemu-system-x86_64, qemu-img, ssh + a public key.
# KVM is used when usable, otherwise tcg (slow but real). Skips with guidance
# and a non-failing exit when a hard prerequisite is missing.
#
# Usage: bash tests/verify-vm-slim-e2e.sh [--no-build] [--keep]
#   --no-build  reuse an existing :vm-slim image and base (fast, weaker)
#   --keep      leave the session and the temp dir for inspection
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LBX="${LBX_BIN:-$ROOT/target/debug/lbx}"
BUILD="$ROOT/build"
DO_BUILD=1
KEEP=0
for arg in "$@"; do
    case "$arg" in
        --no-build) DO_BUILD=0 ;;
        --keep) KEEP=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

PASS=0
FAIL=0
SKIP=0
check() {
    local description="$1" condition="$2"
    if eval "$condition"; then
        echo "[PASS] $description"; PASS=$((PASS + 1))
    else
        echo "[FAIL] $description"; FAIL=$((FAIL + 1))
    fi
}
skip() { echo "[SKIP] $1"; SKIP=$((SKIP + 1)); }

[ -x "$LBX" ] || { echo "ERROR: no lbx binary at $LBX (cargo build first)." >&2; exit 1; }
for tool in docker qemu-system-x86_64 qemu-img ssh; do
    command -v "$tool" >/dev/null || { echo "SKIP: $tool is not installed"; exit 0; }
done
ls "$HOME"/.ssh/*.pub >/dev/null 2>&1 || { echo "SKIP: no ssh public key in ~/.ssh"; exit 0; }

# KVM when we can actually open it, tcg otherwise.
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    export LBX_VM_ACCEL="${LBX_VM_ACCEL:-kvm}"
    export LBX_VM_CPUS="${LBX_VM_CPUS:-8}" LBX_VM_MEM="${LBX_VM_MEM:-16384}"
else
    export LBX_VM_ACCEL="${LBX_VM_ACCEL:-tcg}"
    export LBX_VM_CPUS="${LBX_VM_CPUS:-4}" LBX_VM_MEM="${LBX_VM_MEM:-8192}"
fi

W="$(mktemp -d /tmp/lbx-vm-slim-e2e.XXXXXX)"
NAME="e2e-slim-$$"
cleanup() {
    if [ "$KEEP" = 1 ]; then
        echo "kept: $W (session $NAME)"
        return
    fi
    ( cd "$W/proj" 2>/dev/null && "$LBX" --destroy --runtime vm "$NAME" >/dev/null 2>&1 )
    rm -rf "$W"
}
trap cleanup EXIT

mkdir -p "$W/proj" "$W/state"
export LBX_STATE_DIR="$W/state"
export LLMBOX_STATE_DIR="$W/state"       # what ./build reads
export LBX_CONFIG="$W/config"            # absent: defaults
export LLMBOX_CONFIG="$W/config"

echo ""
echo "== 1. ./build --slim vm (accel=$LBX_VM_ACCEL, state=$W/state)"
BUILD_T0=$(date +%s)
if [ "$DO_BUILD" = 1 ]; then
    ( cd "$W/proj" && LBX_BIN="$LBX" bash "$BUILD" --slim vm ) >"$W/build.log" 2>&1
    BUILD_RC=$?
    check "./build --slim vm succeeds" "[ $BUILD_RC -eq 0 ]"
    check "./build --slim vm BUILDS the image (does not reuse the tag)" \
        "grep -q 'Building llm-in-a-box:vm-slim' $W/build.log"
    check "./build --slim vm does not skip the image build" \
        "! grep -q 'image build skipped' $W/build.log"
    check "./build --slim vm produces a base disk" \
        "grep -q 'Base image .* staged' $W/build.log"
    BUILD_SECONDS=$(( $(date +%s) - BUILD_T0 ))
    IMAGE_SECONDS=$(awk '/Building llm-in-a-box:vm-slim/{f=1} f&&/^\(=> \)?Built llm-in-a-box:vm-slim|Built llm-in-a-box:vm-slim successfully/{print; exit}' "$W/build.log" >/dev/null 2>&1; echo "")
    echo "   (image + base disk took ${BUILD_SECONDS}s; the image alone is ~2-3 min, the 30 GB base disk the rest)"
else
    skip "image build (--no-build)"
fi

BASE="$(readlink -f "$W/state/bases/latest" 2>/dev/null)"
check "a base disk exists" "[ -n '$BASE' ] && [ -f '$BASE/base.qcow2' ]"

# ── 2. the base records the image it came from, and its mode ───────────────
IMG_ID="$(docker image inspect --format '{{.Id}}' llm-in-a-box:vm-slim 2>/dev/null | head -1)"
BASE_ID="$(awk '/^image-id /{print $2}' "$BASE/from-image" 2>/dev/null)"
check "the base records the CURRENT :vm-slim image id" \
    "[ -n '$IMG_ID' ] && [ '$BASE_ID' = '$IMG_ID' ]"
check "the base is stamped core (slim)" "[ \"\$(cat '$BASE/provision' 2>/dev/null)\" = core ]"

# ── 3. boot a real guest ──────────────────────────────────────────────────
echo ""
echo "== 2. booting the guest (this is the slow part under tcg)"
BOOT_T0=$(date +%s)
( cd "$W/proj" && "$LBX" --slim --runtime vm "$NAME" ) </dev/null >"$W/boot.log" 2>&1
BOOT_RC=$?
echo "   (boot + attach took $(( $(date +%s) - BOOT_T0 ))s)"
if [ "$BOOT_RC" -ne 0 ]; then
    echo "---- boot log ----"; tail -20 "$W/boot.log"; echo "-----------------"
fi
check "the vm boots and attaches (rc 0)" "[ $BOOT_RC -eq 0 ]"
PORT="$(cat "$W/state/sessions/$NAME/ssh_port" 2>/dev/null)"
check "the session records an ssh port" "[ -n '$PORT' ]"
check "no provenance warning when the base matches the image" \
    "! grep -q 'session base was built from' $W/boot.log"
if [ -z "$PORT" ]; then
    echo "no ssh port; cannot continue"; exit 1
fi

sshc() { ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
             -o ConnectTimeout=10 -p "$PORT" "$USER@127.0.0.1" "$@"; }

# ── 4. lbx-setup works inside the guest ───────────────────────────────────
sshc 'lbx-setup --list' >"$W/list.out" 2>&1
check "lbx-setup --list runs in the guest" "grep -q 'build-tools' $W/list.out"
check "the vm-only tier is listed in a vm box" "grep -q 'design' $W/list.out"
sshc 'command -v dialog && command -v xauth' >/dev/null 2>&1
TOOLS_RC=$?
check "the guest has dialog + xauth (the pieces lbx-setup needs)" "[ $TOOLS_RC -eq 0 ]"

# ── 5. a terminal dialog CANNOT use: plain menu takes over ────────────────
# `12` is pnpm: ~3 s, and it proves the selection actually executed a step.
# `script` allocates the terminal INSIDE the guest, so ssh itself needs no tty
# (the earlier `ssh -tt` + piped stdin combination hung waiting for EOF).
# The pipe lives INSIDE the remote command: `script` allocates the terminal,
# and its stdin carries the menu answer. (Feeding ssh's stdin instead hung.)
timeout 120 ssh -T -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 -p "$PORT" "$USER@127.0.0.1" \
    "printf '12\\n' | script -qec 'env TERM=xterm-kitty lbx-setup' /dev/null" \
    >"$W/menu.out" 2>&1
check "no curses: lbx-setup falls back instead of failing" \
    "grep -q 'using a plain menu' $W/menu.out"
check "the plain menu lists the steps" "grep -q 'build-tools' $W/menu.out"
check "a step picked from the plain menu runs" "grep -q 'provision: pnpm ready' $W/menu.out"
timeout 60 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$PORT" "$USER@127.0.0.1" 'pnpm --version' >"$W/pnpm.out" 2>&1
check "the installed tool is really there" "grep -Eq '^[0-9]+\.' $W/pnpm.out"

# ── 5b. the first-entry hint: once, and only while nothing is installed ───
check "a fresh slim box is told how to set it up" \
    "grep -q 'This box has nothing installed yet' $W/boot.log"
check "and names the command to run" "grep -q 'lbx-setup            tick what to install' $W/boot.log"
# The pnpm step above wrote ~/.lbx/provisioned.log, so a second attach is quiet.
( cd "$W/proj" && "$LBX" --slim --runtime vm "$NAME" ) </dev/null >"$W/second.log" 2>&1
check "a configured box is not nagged again" \
    "! grep -q 'This box has nothing installed yet' $W/second.log"

# ── 6. a step that cannot run says what to do ─────────────────────────────
timeout 120 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 -p "$PORT" "$USER@127.0.0.1" 'lbx-setup design' >"$W/design.out" 2>&1
DESIGN_RC=$?
check "design without a package fails" "[ $DESIGN_RC -ne 0 ]"
check "and names the release page" "grep -q 'OpenCoworkAI/open-codesign/releases' $W/design.out"
# Either escape hatch is a valid "here is how to fix it": a local file or a
# pinned version (the step otherwise resolves the release itself).
check "and names how to fix it" "grep -qE 'LBX_DESIGN_DEB=|LBX_DESIGN_VERSION=' $W/design.out"
timeout 60 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$PORT" "$USER@127.0.0.1" 'lbx-setup no-such-step' >"$W/unknown.out" 2>&1
check "unknown steps still refuse clearly" "grep -q \"unknown step 'no-such-step'\" $W/unknown.out"

echo ""
echo "verify-vm-slim-e2e.sh: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
