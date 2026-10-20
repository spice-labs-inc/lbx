#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-qemu-tcg-sysbox.sh — runtime integration test: does qemu actually
# boot (software-emulated, TCG) inside a sysbox llm-in-a-box container,
# launched the way a real user would launch it (via lbx, not a
# hand-rolled `docker run`)?
#
# WHAT:
#   1. Builds (or reuses) llm-in-a-box:sysbox.
#   2. Launches a session via the real `lbx` script, so the actual
#      device/env-passthrough logic under test actually runs.
#   3. Confirms /dev/kvm is NOT passed through (superseded design decision —
#      sysbox's user-namespace GID mapping cannot make it usable, so it is
#      no longer attempted at all).
#   4. Confirms `qemu-system-x86_64` boots in TCG (software-emulated) mode
#      without any device/permission error.
#
# WHY: The original bug report was "VMs don't work (e.g. qemu) inside the
#      container." KVM-accelerated qemu was investigated and found
#      impossible to fix under sysbox without a host-level permission change
#      the user did not approve (the /dev/kvm passthrough design was
#      investigated and superseded). TCG-mode qemu needs no device access at all,
#      so it is the actual working claim this test verifies.
#
# REQUIRES: docker and sysbox-runc registered with the docker daemon. Unlike
# the superseded KVM test, this does NOT require /dev/kvm on the host — TCG
# mode has no such dependency, which is the point.
#
# USAGE: tests/verify-qemu-tcg-sysbox.sh
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
IMAGE="llm-in-a-box:sysbox"
SESSION="verify-tcg-$$"

cleanup() {
    docker rm -f "$SESSION" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ── Preflight: skip (not fail) on hosts that can't run this test ──────────
if ! command -v docker >/dev/null 2>&1; then
    echo "SKIP: docker not installed."
    exit 0
fi
if ! docker info --format '{{json .Runtimes}}' 2>/dev/null | grep >/dev/null sysbox-runc; then
    echo "SKIP: sysbox-runc not registered with the docker daemon."
    exit 0
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "==> Building $IMAGE (image not found locally) ..."
    docker build --build-arg RUNTIME_TYPE=sysbox -t "$IMAGE" "$REPO_ROOT"
fi

wait_for_ready() {
    local name="$1"
    for _ in $(seq 1 30); do
        docker exec "$name" test -f /tmp/.user-ready 2>/dev/null && return 0
        sleep 1
    done
    echo "FAIL: container $name never reached user-ready state" >&2
    return 1
}

FAIL_COUNT=0
check() {
    local desc="$1"; shift
    if "$@"; then
        echo "[PASS] $desc"
    else
        echo "[FAIL] $desc"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

echo "==> Launching via lbx --runtime sysbox ..."
( cd "$REPO_ROOT" && ./lbx --runtime sysbox "$SESSION" </dev/null >/tmp/verify-tcg-launch.log 2>&1 & )
for _ in $(seq 1 30); do
    [ "$(docker inspect -f '{{.State.Status}}' "$SESSION" 2>/dev/null)" = "running" ] && break
    sleep 1
done
wait_for_ready "$SESSION"

check "/dev/kvm is NOT passed through (superseded — TCG-only)" \
    bash -c '! docker exec '"$SESSION"' test -e /dev/kvm'

check "qemu-system-x86_64 is installed" \
    docker exec -u claude "$SESSION" which qemu-system-x86_64

check "qemu-system-x86_64 boots in TCG (software) mode without error" \
    bash -c 'docker exec -u claude '"$SESSION"' timeout 10 qemu-system-x86_64 \
        -accel tcg -M isapc -m 32 -nographic -serial none -display none \
        -no-reboot 2>&1 | tee /tmp/verify-tcg-qemu.log \
        | grep -vE >/dev/null "Permission denied|Operation not permitted|error"'

echo ""
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "[PASS] verify-qemu-tcg-sysbox.sh: all checks passed"
    exit 0
else
    echo "[FAIL] verify-qemu-tcg-sysbox.sh: ${FAIL_COUNT} check(s) failed"
    exit 1
fi
