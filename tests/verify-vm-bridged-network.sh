#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-vm-bridged-network.sh — runtime integration test: can a qemu VM
# inside a sysbox llm-in-a-box container get its own bridged IP and
# actually host a web server reachable from outside the container?
#
# WHAT:
#   1. Builds (or reuses) llm-in-a-box:sysbox.
#   2. Launches a session via the real `lbx --runtime sysbox
#      --vm-web-port <hostport>:80`, so the actual NET_ADMIN/tun-grant and
#      VM_WEB_PORT-forwarding logic under test actually runs.
#   3. Inside the container: attaches a tap device to br-vm0 via
#      vm-net-attach, boots the minimal baked-in test-VM image (kernel +
#      busybox initramfs, see docker/vm-test-init.sh), and waits for its
#      readiness marker on the serial console.
#   4. Confirms the VM is reachable at its bridged IP (192.168.200.2:80)
#      from *inside* the container's own network namespace.
#   5. Confirms the VM's web server is *also* reachable from OUTSIDE the
#      container, via the forwarded host port — the actual end-to-end claim
#      ("host a web server"), not just internal plumbing.
#
# WHY: A device/capability-presence check alone would not prove a real
#      guest OS can use the bridge, and an internal-only curl would not
#      prove the DNAT/port-forward path actually works from the host's
#      perspective. Both are exercised here against a real VM boot.
#
# REQUIRES: docker and sysbox-runc registered with the docker daemon. Does
# NOT require /dev/kvm — this boots in TCG (software-emulated) mode.
#
# USAGE: tests/verify-vm-bridged-network.sh
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
IMAGE="llm-in-a-box:sysbox"
SESSION="verify-vmnet-$$"
HOST_PORT=$((20000 + ($$ % 10000)))

cleanup() {
    docker exec "$SESSION" pkill -9 qemu-system-x86_64 >/dev/null 2>&1 || true
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

echo "==> Launching via lbx --runtime sysbox --vm-web-port ${HOST_PORT}:80 ..."
( cd "$REPO_ROOT" && ./lbx --runtime sysbox --vm-web-port "${HOST_PORT}:80" "$SESSION" \
    </dev/null >/tmp/verify-vmnet-launch.log 2>&1 & )
for _ in $(seq 1 30); do
    [ "$(docker inspect -f '{{.State.Status}}' "$SESSION" 2>/dev/null)" = "running" ] && break
    sleep 1
done
wait_for_ready "$SESSION"

check "br-vm0 bridge exists inside the container" \
    docker exec "$SESSION" ip link show br-vm0

echo "==> Attaching tap0 and booting the test VM (TCG, this can take ~30-60s) ..."
docker exec -u root "$SESSION" vm-net-attach tap0 >/tmp/verify-vmnet-attach.log 2>&1

# NOTE: -nographic is NOT compatible with -daemonize (qemu refuses to start
# with both). docker exec -d already backgrounds the process for us, so we
# use -display none (headless, no monitor/keyboard) instead of -nographic
# and skip qemu's own -daemonize entirely.
docker exec -d -u root "$SESSION" bash -c '
    qemu-system-x86_64 -M pc -m 256 -accel tcg \
        -kernel /opt/vm-test/vmlinuz \
        -initrd /opt/vm-test/initramfs.cpio.gz \
        -append "console=ttyS0 quiet" \
        -netdev tap,id=net0,ifname=tap0,script=no,downscript=no \
        -device virtio-net-pci,netdev=net0 \
        -display none -serial file:/tmp/vm-console.log -no-reboot
'

VM_READY=false
for _ in $(seq 1 60); do
    if docker exec "$SESSION" grep -q VM-NET-TEST-READY /tmp/vm-console.log 2>/dev/null; then
        VM_READY=true
        break
    fi
    sleep 1
done
check "test VM boots and reaches its readiness marker" bash -c "[ '$VM_READY' = true ]"
docker exec "$SESSION" cat /tmp/vm-console.log > /tmp/verify-vmnet-console.log 2>/dev/null || true

check "VM's web server is reachable from inside the container (192.168.200.2:80)" \
    bash -c "docker exec '$SESSION' curl -fsS --max-time 10 http://192.168.200.2/ | grep >/dev/null 'llm-in-a-box VM network test OK'"

check "VM's web server is reachable from OUTSIDE the container via --vm-web-port" \
    bash -c "curl -fsS --max-time 10 http://127.0.0.1:${HOST_PORT}/ | grep >/dev/null 'llm-in-a-box VM network test OK'"

echo ""
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "[PASS] verify-vm-bridged-network.sh: all checks passed"
    exit 0
else
    echo "[FAIL] verify-vm-bridged-network.sh: ${FAIL_COUNT} check(s) failed"
    echo "       See /tmp/verify-vmnet-*.log for diagnostics."
    exit 1
fi
