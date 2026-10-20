#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-vm-e2e.sh — host integration test: does the vm runtime really boot,
# auto-detect as default, and carry the Phase-3 Pi plugins end to end?
#
# WHAT (skip-not-fail without /dev/kvm + kvm group, mirrors the established
# verify-* pattern):
#   1. Asserts auto-detection picks vm (via the --shutdown path, which runs
#      detection but no preflight/boot — "Auto-detected runtime: vm").
#   2. Builds the vm image + base disk via ./build vm when missing.
#   3. Boots a REAL KVM VM through `lbx --runtime vm <sess>`
#      (backgrounded; the interactive ssh attach is expected to fail in a
#      script context — the boot + wait-for-ssh completes first).
#   4. Probes the guest directly over ssh: in-guest dockerd, /data mount,
#      claude --version, pi --version + pi list (the three ADR-010 plugins),
#      aft --version, magic-context.jsonc, omp --version, opencode --version.
#   5. Graceful --shutdown, resume (relaunch on same overlay; regression
#      for the 2026-09-02 docker-group-remap bug — see the in-guest checks
#      below), and --destroy cleanup.
#
# WHY: Phase 1 made "built ⇒ vm" the default and Phase 3 baked plugins into
#      the image. Both claims must be proven on a real KVM boot (HS-3: the
#      preflight passing is not the runtime working; the plugins existing in
#      the image is not the plugins working in a session). The user's dev VM
#      has /dev/kvm and sudo specifically so this can run for real.
#
# USAGE:
#   tests/verify-vm-e2e.sh
#
# REQUIRES: /dev/kvm, kvm group membership, qemu-system-x86_64, qemu-img,
# ssh, an ssh public key (auto-generated when missing), and docker for the
# ./build vm step. Skips with guidance when a hard prerequisite is absent.
# ---------------------------------------------------------------------------
set -uo pipefail

# Nested-run resources: lbx defaults to 16 GiB RAM / 8 vCPUs, which
# exceeds typical dev-VM capacity (this VM has 15 GiB). Cap the guest to
# modest values unless the caller overrides — a nested e2e must fit inside
# its parent VM, or qemu fails to allocate memory.
export LLMBOX_VM_MEM="${LLMBOX_VM_MEM:-4096}"
export LLMBOX_VM_CPUS="${LLMBOX_VM_CPUS:-4}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
BOC="${LBX_BIN:-$REPO_ROOT/target/debug/lbx}"
export LLMBOX_SCRIPT_DIR="$REPO_ROOT"
BUILD="$REPO_ROOT/build"
# Storage split (ADR 013, 2026-09-29): HOST-SIDE VM STATE (base disks,
# session overlays, session metadata) lives in a GLOBAL, configurable
# LLMBOX_STATE_DIR (default ~/.llm-in-a-box); PER-PROJECT ARTIFACTS (the
# box's Docker store image and the first-reader README) live in a
# vms_and_docker_from_llm_box subdirectory of the PROJECT directory. The e2e
# runs from the repo root and creates its session there, so the project dir
# is the repo root: <repo>/vms_and_docker_from_llm_box.
ARTIFACT_DIR="$(cd . && pwd)/vms_and_docker_from_llm_box"
STATE_DIR="${LLMBOX_STATE_DIR:-$HOME/.llm-in-a-box}"
SESSION="llm-in-a-box-e2e-$$"
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

# ── Host prerequisites (skip-not-fail, "scripts test and tell") ───────────
missing=0
# LLMBOX_VM_ACCEL=tcg runs qemu without KVM, so /dev/kvm and the kvm group
# are not prerequisites in that mode (the launcher preflight skips the
# same two checks under tcg — the gate must match, or the TCG run can
# never execute).
if [ "${LLMBOX_VM_ACCEL:-kvm}" = "tcg" ]; then
    echo "  LLMBOX_VM_ACCEL=tcg: skipping the /dev/kvm and kvm-group checks"
else
    if [ ! -e /dev/kvm ]; then echo "  missing: /dev/kvm — enable CPU virtualization + KVM module"; missing=1; fi
    if ! id -nG | grep -w >/dev/null kvm; then echo "  missing: kvm group: sudo usermod -aG kvm \$USER && newgrp kvm"; missing=1; fi
fi
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then echo "  missing: qemu-system-x86_64 — sudo apt-get install -y qemu-system-x86"; missing=1; fi
if ! command -v qemu-img >/dev/null 2>&1; then echo "  missing: qemu-img — sudo apt-get install -y qemu-utils"; missing=1; fi
if ! command -v ssh >/dev/null 2>&1; then echo "  missing: ssh — sudo apt-get install -y openssh-client"; missing=1; fi
if [ "$missing" -ne 0 ]; then
    echo "[SKIP] verify-vm-e2e.sh: host prerequisites missing (see above)"
    exit 0
fi

# An ssh public key is required for attach; generate one if none exists.
if ! ls "$HOME"/.ssh/*.pub >/dev/null 2>&1; then
    echo "==> Generating an ssh key for the e2e attach ($HOME/.ssh/id_ed25519) ..."
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N '' -q
fi

# Versioned bases (2026-09-03): bases/latest/base.qcow2 is the newest
# successful build; the legacy flat layout (base.qcow2 + vmlinuz) is still
# accepted. Both live in the state directory (ADR 013). Defined before
# section 1 — it is called there.
base_built() {
    local l
    l=$(readlink "$STATE_DIR/bases/latest" 2>/dev/null || true)
    if [ -n "$l" ] && [ -f "$STATE_DIR/bases/$l/base.qcow2" ] && [ -f "$STATE_DIR/bases/$l/vmlinuz" ]; then
        return 0
    fi
    [ -f "$STATE_DIR/base.qcow2" ] && [ -f "$STATE_DIR/vmlinuz" ]
}

# ── 1. auto-detection: built ⇒ vm ────────────────────────────────────────
# Detection now runs on the CREATE path (--shutdown/--stop resolve
# per-name cross-runtime and no longer run detection — 2026-09-03). Force
# a fast preflight failure with LLMBOX_VM_MISSING so no real vm boots: the
# log must show the detected runtime before the guided failure.
if base_built; then
    DETECT_OUT=$(LLMBOX_VM_MISSING='qemu-system-x86_64' "$BOC" "$SESSION" 2>&1 || true)
    check "auto-detect picks vm when the vm image is built" \
        "echo '$DETECT_OUT' | grep >/dev/null 'Auto-detected runtime: vm'"
else
    skip "auto-detect picks vm when the vm image is built (vm image not built yet — built below)"
fi

# ── 2. build the vm image + base disk when missing ────────────────────────
if ! base_built; then
    echo "==> Building the vm image + base disk (./build vm) ..."
    bash "$BUILD" vm || { echo "[FAIL] ./build vm failed" >&2; exit 1; }
fi
check "vm image artifacts exist (newest base: base.qcow2 + vmlinuz)" \
    "base_built"

# Re-run the auto-detection assertion now that the image is definitely built.
DETECT_OUT=$(LLMBOX_VM_MISSING='qemu-system-x86_64' "$BOC" "$SESSION" 2>&1 || true)
check "auto-detect picks vm when the vm image is built" \
    "echo '$DETECT_OUT' | grep >/dev/null 'Auto-detected runtime: vm'"

# ── 3. boot a real KVM VM through lbx ────────────────────────────
echo "==> Booting vm session '$SESSION' (KVM) ..."
timeout 600 "$BOC" --runtime vm "$SESSION" </dev/null >/tmp/llm-in-a-box-e2e-boot.log 2>&1 || true
# The command "fails" at the interactive ssh attach in a script context —
# that is expected; the boot + wait-for-ssh must have completed first.
SSH_PORT=$(cat "$STATE_DIR/sessions/$SESSION/ssh_port" 2>/dev/null || true)
check "vm booted and recorded an ssh port" \
    "[ -n '$SSH_PORT' ] && grep -q 'Booting vm' /tmp/llm-in-a-box-e2e-boot.log"

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null -p "$SSH_PORT")
GUEST="$(whoami)@127.0.0.1"

guest_run() {
    ssh "${SSH_OPTS[@]}" "$GUEST" "$1" 2>&1 || true
}

# The vm runs on a 9p-backed overlay: first boot can exceed the script's
# 240s ssh-wait. Poll for ssh readiness ourselves (up to $1 seconds,
# default 900) so slow nested boots do not flake the probe checks.
wait_guest() {
    local deadline=$((SECONDS + ${1:-900}))
    while [ $SECONDS -lt $deadline ]; do
        if ssh "${SSH_OPTS[@]}" "$GUEST" 'true' >/dev/null 2>&1; then
            return 0
        fi
        sleep 5
    done
    return 1
}

wait_guest 900 || echo "[WARN] guest ssh did not come up within 900s"

# ── 4. in-guest probes (the vm runtime + Phase-3 plugins, end to end) ──────
check "in-guest dockerd works (docker info)" \
    "guest_run 'docker info' | grep >/dev/null 'Server Version'"
# Regression (2026-09-02 e2e bug): the first-boot uid/gid remap deleted the
# docker group (gid collision with the nested seed's TARGET_GID), so
# docker.socket failed with 216/GROUP on the resumed boot. The user must
# actually be in the docker group, and the resume check below proves the
# group survives a reboot.
check "in-guest user belongs to the docker group" \
    "guest_run 'id -nG' | grep >/dev/null docker"
check "in-guest /data project mount exists" \
    "guest_run 'test -d /data && echo ok' | grep >/dev/null ok"
check "in-guest claude --version runs" \
    "guest_run 'claude --version' | grep -E >/dev/null '[0-9]+\\.[0-9]+'"
check "in-guest pi --version >= 0.74.0" \
    "V=\$(guest_run 'pi --version' | grep -oE '[0-9]+\\.[0-9]+\\.[0-9]+' | head -1); awk -v v=\"\$V\" 'BEGIN{exit !(v+0>=0.74)}'"
PI_LIST_GUEST=$(guest_run 'pi list')
check "in-guest pi list shows pi-provider-umans" \
    "echo '$PI_LIST_GUEST' | grep >/dev/null 'pi-provider-umans'"
check "in-guest pi list shows @cortexkit/aft-pi" \
    "echo '$PI_LIST_GUEST' | grep >/dev/null '@cortexkit/aft-pi'"
check "in-guest pi list shows pi-web-access" \
    "echo '$PI_LIST_GUEST' | grep >/dev/null 'pi-web-access'"
check "in-guest aft --version runs" \
    "guest_run 'aft --version' | grep -E >/dev/null '[0-9]+\\.[0-9]+'"
check "in-guest magic-context.jsonc present" \
    "guest_run 'test -f ~/.config/cortexkit/magic-context.jsonc && echo ok' | grep >/dev/null ok"
check "in-guest omp --version runs" \
    "guest_run 'omp --version' | grep -E >/dev/null '[0-9]+\\.[0-9]+'"
check "in-guest opencode --version runs" \
    "guest_run 'opencode --version' | grep -E >/dev/null '[0-9]+\\.[0-9]+'"

# ── 4b. store image (2026-09-10 image-store remediation) ───────────────────
# Docker/containerd live in a sparse ext4 image on the host, attached to
# the VM as an NVMe device; the guest formats it on first use, mounts it
# at /srv/docker-store, and keeps both roots inside. E1-E7 prove the
# attachment, the filesystem, the daemons, host-side data placement, the
# boot ordering, boot health, and persistence.
# The launcher records the resolved image path by writing $STORE_IMG to
# $VM_SESSION_DIR/store-img after vm_store_image_prepare; an empty record
# is a test failure, never a silently skipped host-side comparison (E7
# compares inodes, so an empty path would compare empty/zero and pass
# vacuously).
#
# E1's two device assertions were corrected for the same reason the guest
# wiring was: the launcher asks QEMU for serial `llm-in-a-box-docker-store` (25
# characters) but the NVMe serial field holds 20, so the guest's by-id entry is
# `nvme-QEMU_NVMe_Ctrl_llm-in-a-box-docker-` and the word "store" appears
# nowhere in the device's identity. Matching the full serial in the by-id
# listing can therefore never succeed. The source is asserted as an NVMe device
# rather than a by-id path for a second reason: the wiring mounts the by-id
# path, but util-linux resolves the source before calling mount(2), so the
# mount table records the resolved name (`/dev/nvme0n1`). E1b pins that the
# root device is a different disk, so together they show the store is not root.
E2E_STORE_IMG=$(cat "$STATE_DIR/sessions/$SESSION/store-img" 2>/dev/null || true)
check "E1: the guest sees the NVMe device and mounts ext4 at /srv/docker-store" \
    "guest_run 'ls /dev/disk/by-id/ | grep -E >/dev/null 'lbx-docker-store|llm-in-a-box-docker|boc-docker-store' && findmnt -no FSTYPE /srv/docker-store' | grep -x >/dev/null ext4 && guest_run 'findmnt -no SOURCE /srv/docker-store' | grep -E >/dev/null '^/dev/nvme'"
check "E1b: the root device is still /dev/vda" \
    "guest_run 'findmnt -no SOURCE /' | grep -x >/dev/null /dev/vda"
guest_run "cat > /tmp/llm-in-a-box-mmap-probe.py" <<'PROBEEOF' >/dev/null
import os, mmap
p = "/srv/docker-store/mmap-probe"
fd = os.open(p, os.O_RDWR | os.O_CREAT, 0o644)
os.write(fd, b"x" * 4096)
m = mmap.mmap(fd, 4096)
print("MMAP-OK")
m.close()
os.close(fd)
os.unlink(p)
PROBEEOF
check "E2: memory mapping works inside the store (probe runs under sudo)" \
    "guest_run 'sudo python3 /tmp/llm-in-a-box-mmap-probe.py' | grep >/dev/null MMAP-OK"
check "E3a: containerd healthy and docker uses the overlayfs snapshotter" \
    "guest_run 'sudo ctr plugins list' | grep -w leases | grep -w >/dev/null ok && guest_run 'docker info' | grep -i >/dev/null 'Storage Driver: overlayfs'"
check "E3b: pull+run busybox and redis (non-root files)" \
    "guest_run 'timeout 300 docker pull busybox:latest >/dev/null 2>&1 && docker run --rm busybox:latest true && timeout 600 docker pull redis:alpine >/dev/null 2>&1 && docker run --rm redis:alpine redis-server --version' | grep -i >/dev/null 'redis'"
guest_run 'sync'
sleep 2
E2E_BLOCKS=$(stat -c %b "$E2E_STORE_IMG" 2>/dev/null || echo 0)
check "E4a: the host image is regular, user-owned, mode 0600 and holds data" \
    "[ -n '$E2E_STORE_IMG' ] && [ -f '$E2E_STORE_IMG' ] && [ ! -L '$E2E_STORE_IMG' ] && [ \"\$(stat -c %U '$E2E_STORE_IMG')\" = \"\$(whoami)\" ] && [ \"\$(stat -c %a '$E2E_STORE_IMG')\" = '600' ] && [ \"$E2E_BLOCKS\" -gt 1024 ]"
check "E4b: the recorded store image is the one directory's docker-store.img" \
    "[ -n \"$E2E_STORE_IMG\" ] && [ \"$E2E_STORE_IMG\" = \"$ARTIFACT_DIR/docker-store.img\" ]"
check "E5: setup ordering and daemon drop-ins (unit Before=, both daemons After=/Wants=)" \
    "guest_run 'systemctl show llm-in-a-box-setup.service -p Before' | grep -q containerd.service && guest_run 'systemctl show llm-in-a-box-setup.service -p Before' | grep -q docker.service && guest_run 'systemctl show docker.service -p After,Wants' | grep -q 'llm-in-a-box-setup.service' && guest_run 'systemctl show containerd.service -p After,Wants' | grep -q 'llm-in-a-box-setup.service'"
check "E6: boot health, no chown/Lchown errors" \
    "for _ in \$(seq 1 30); do [ \"\$(guest_run 'systemctl is-active containerd docker' | grep -cx active)\" = 2 ] && break; sleep 3; done; guest_run 'systemctl is-active containerd docker' | grep -cx active | grep -qx 2 && ! guest_run 'sudo journalctl -b -u docker -u containerd --no-pager' | grep -qE 'Lchown|daemon root permissions'"
# E7 is asserted after the section-5 resume (persistence across a reboot
# and reuse of the SAME host image file); capture the image identity now.
E7_IMG_INODE=$(stat -c %i "$E2E_STORE_IMG" 2>/dev/null || echo 0)

# ── 5. shutdown → resume → destroy ─────────────────────────────────────────
"$BOC" --runtime vm --shutdown "$SESSION" >/tmp/llm-in-a-box-e2e-stop.log 2>&1 || true
check "graceful --shutdown stops the vm" \
    "grep -qE 'stopped|Shutting down' /tmp/llm-in-a-box-e2e-stop.log"

echo "==> Resuming vm session '$SESSION' (relaunch on the same overlay) ..."
timeout 600 "$BOC" --runtime vm "$SESSION" </dev/null >/tmp/llm-in-a-box-e2e-resume.log 2>&1 || true
SSH_PORT=$(cat "$STATE_DIR/sessions/$SESSION/ssh_port" 2>/dev/null || true)
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null -p "$SSH_PORT")
wait_guest 300 || echo "[WARN] guest ssh did not come up within 300s after resume"
check "resumed vm accepts ssh and runs docker info" \
    "RESUMED_OK=0; for i in \$(seq 1 30); do if guest_run 'docker info' | grep >/dev/null 'Server Version'; then RESUMED_OK=1; break; fi; sleep 10; done; [ \$RESUMED_OK -eq 1 ]"
check "in-guest user still in the docker group after resume" \
    "guest_run 'id -nG' | grep >/dev/null docker"
# E7 requirement: the store image is persistent state — after shutdown and
# resume the same host file must be reused (same inode, not re-created) and
# an image pulled before the shutdown must still be present. Theory: the
# busybox image pulled in E3b is listed by the resumed guest and the host
# image inode captured before the shutdown is unchanged.
check "E7: a pulled image survives shutdown/resume and the store image is reused, not recreated" \
    "[ -n '$E2E_STORE_IMG' ] && guest_run 'docker images --format {{.Repository}}' | grep >/dev/null busybox && [ \"\$(stat -c %i '$E2E_STORE_IMG' 2>/dev/null)\" = '$E7_IMG_INODE' ]"

"$BOC" --runtime vm --destroy "$SESSION" >/tmp/llm-in-a-box-e2e-rm.log 2>&1 || true
check "--destroy removes the session" \
    "[ ! -d '$STATE_DIR/sessions/$SESSION' ] && grep -q 'Removed vm session' /tmp/llm-in-a-box-e2e-rm.log"

# ── 5b. store fallback and recovery (E8) ───────────────────────────────────
# E8 requirement: the store is optional and recoverable — LLMBOX_VM_STORE_DISABLE=1
# must keep the guest usable on local Docker (with the fallback marker), a
# lost image must heal by reformatting on the next boot, and discard must
# return freed blocks to the host. Theory: boot a second session disabled
# (local Docker + marker), stop it, delete the store image, relaunch (fresh
# image → guest mkfs + mount + working Docker), then fill and delete a file
# inside the store, fstrim, and compare host allocated blocks.
ESESS="llm-in-a-box-e2e-store-$$"
echo "==> Booting store-disabled vm session '$ESESS' (E8) ..."
LLMBOX_VM_STORE_DISABLE=1 timeout 600 "$BOC" --runtime vm "$ESESS" </dev/null >/tmp/llm-in-a-box-e2e-e8.log 2>&1 || true
E8_PORT=$(cat "$STATE_DIR/sessions/$ESESS/ssh_port" 2>/dev/null || true)
E8_SSHOPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -p "$E8_PORT")
e8_run() { ssh "${E8_SSHOPTS[@]}" "$(whoami)@127.0.0.1" "$1" 2>&1 || true; }
for i in $(seq 1 180); do
    ssh "${E8_SSHOPTS[@]}" "$(whoami)@127.0.0.1" 'true' >/dev/null 2>&1 && break
    sleep 5
done
check "E8: LLMBOX_VM_STORE_DISABLE=1 boots with local Docker and the fallback marker" \
    "e8_run 'docker info' | grep -q 'Server Version' && e8_run 'test -f /run/llm-in-a-box-store-fallback && echo marker-ok' | grep -q marker-ok"
"$BOC" --runtime vm --shutdown "$ESESS" >/tmp/llm-in-a-box-e2e-e8stop.log 2>&1 || true

# Lose the image: the next boot must create and format a fresh one.
rm -f "$E2E_STORE_IMG"
echo "==> Relaunching '$ESESS' with the store image deleted (E8) ..."
timeout 600 "$BOC" --runtime vm "$ESESS" </dev/null >/tmp/llm-in-a-box-e2e-e8b.log 2>&1 || true
E8_PORT=$(cat "$STATE_DIR/sessions/$ESESS/ssh_port" 2>/dev/null || true)
E8_SSHOPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -p "$E8_PORT")
for i in $(seq 1 180); do
    ssh "${E8_SSHOPTS[@]}" "$(whoami)@127.0.0.1" 'true' >/dev/null 2>&1 && break
    sleep 5
done
check "E8b: deleting the store image makes the next boot reformat it and Docker work" \
    "e8_run 'findmnt -no FSTYPE /srv/docker-store' | grep -x >/dev/null ext4 && e8_run 'timeout 300 docker pull busybox:latest >/dev/null 2>&1 && docker run --rm busybox:latest true && echo docker-ok' | grep >/dev/null docker-ok"

# Discard path: measure the host's allocated blocks, fill the store as
# root (the mount root is root-owned, so a plain user dd can fail and the
# old before/after comparison then watched unrelated churn), prove the
# fill grew the host allocation, then delete + fstrim and prove the host
# allocation fell. Both assertions are required: without the growth
# assertion the reclaim comparison could pass from an unrelated fstrim.
E8_BLOCKS_BASELINE=$(stat -c %b "$E2E_STORE_IMG" 2>/dev/null || echo 0)
e8_run 'sudo dd if=/dev/urandom of=/srv/docker-store/e8-fill bs=1M count=256 2>/dev/null; sync'
sleep 2
E8_BLOCKS_FILLED=$(stat -c %b "$E2E_STORE_IMG" 2>/dev/null || echo 0)
check "E8c: filling the store grows the host image allocation" \
    "[ \"$E8_BLOCKS_FILLED\" -gt \"$E8_BLOCKS_BASELINE\" ]"
e8_run 'sudo rm -f /srv/docker-store/e8-fill; sync; sudo fstrim -v /srv/docker-store'
# the host file system frees punched blocks asynchronously (ZFS: at the next
# transaction group sync, about 4 s here); poll instead of a fixed wait
E8_BLOCKS_AFTER=$E8_BLOCKS_FILLED
for _ in $(seq 1 15); do
    sleep 2
    E8_BLOCKS_AFTER=$(stat -c %b "$E2E_STORE_IMG" 2>/dev/null || echo 0)
    [ "$E8_BLOCKS_AFTER" -lt "$E8_BLOCKS_FILLED" ] && break
done
check "E8d: guest fstrim returns the discarded blocks to the host" \
    "[ \"$E8_BLOCKS_AFTER\" -lt \"$E8_BLOCKS_FILLED\" ]"

"$BOC" --runtime vm --destroy "$ESESS" >/tmp/llm-in-a-box-e2e-e8rm.log 2>&1 || true

# ── 6. netwall under vm (2026-09-03): the wall lives OUTSIDE the guest ──────
# restrict=on (no route, no DNS) + one door (guestfwd → per-session relay).
# Probes: the deny/allow pair, the boundary proof (in-guest iptables -F +
# a new default route must change NOTHING), dig timeout, inner busybox wget
# through the door, and wall persistence across shutdown/resume (T14).
NWPOL=/tmp/llm-in-a-box-e2e-netpol.json
cat > "$NWPOL" <<'EOF'
{"mode": "enforce", "allow": ["api.anthropic.com","registry-1.docker.io","auth.docker.io","production.cloudflare.docker.com","production.cloudfront.docker.com"], "block": []}
EOF
NWSESS="llm-in-a-box-e2e-nw-$$"
echo "==> Booting netwalled vm session '$NWSESS' (KVM) ..."
timeout 600 "$BOC" --net-policy "$NWPOL" --runtime vm "$NWSESS" </dev/null >/tmp/llm-in-a-box-e2e-nw.log 2>&1 || true
NW_PORT=$(cat "$STATE_DIR/sessions/$NWSESS/ssh_port" 2>/dev/null || true)
NW_SSHOPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -p "$NW_PORT")
# Scalar form for eval'd check strings: the array expands UNQUOTED there and
# each "-o BatchMode=yes" element word-splits in half — the joined scalar
# reproduces the original token stream safely.
NW_SSHOPTS_STR="${NW_SSHOPTS[*]}"
for i in $(seq 1 120); do
    ssh "${NW_SSHOPTS[@]}" "$(whoami)@127.0.0.1" 'true' >/dev/null 2>&1 && break
    sleep 5
done
nw_run() { ssh "${NW_SSHOPTS[@]}" "$(whoami)@127.0.0.1" "$1" 2>&1 || true; }

check "netwall vm: allowlisted host succeeds in-guest" \
    "nw_run 'curl -s --max-time 25 -o /dev/null -w %{http_code} https://api.anthropic.com' | grep -v >/dev/null 000"
check "netwall vm: non-listed host is denied in-guest" \
    "nw_run 'curl -s --max-time 20 -o /dev/null -w %{http_code} https://example.com' | grep -vE >/dev/null '2[0-9][0-9]|3[0-9][0-9]'"
check "netwall vm: no DNS / no route (dig @8.8.8.8 times out)" \
    "ssh $NW_SSHOPTS_STR "$(whoami)@127.0.0.1" 'timeout 8 dig @8.8.8.8 example.com +short; echo rc=\$?' >/tmp/llm-in-a-box-e2e-nw-dig.out 2>&1; [ \$? -ne 0 ] || grep >/dev/null 'rc=124' /tmp/llm-in-a-box-e2e-nw-dig.out"
check "netwall vm: ssh attach works under restrict=on" \
    "for i in 1 2 3 4 5; do nw_run 'echo ok' 2>/dev/null | grep >/dev/null ok && break; sleep 3; done; nw_run 'echo ok' 2>/dev/null | grep >/dev/null ok"

# Boundary proof: sabotage the in-guest firewall + routing — the wall is
# OUTSIDE the guest (qemu restrict=on), so the pair must be unchanged.
nw_run 'sudo iptables -F 2>/dev/null; sudo ip route add default via 10.0.2.2 2>/dev/null; true' >/dev/null
check "netwall vm boundary proof: after iptables -F + a new route, deny/allow unchanged" \
    "nw_run 'curl -s --max-time 20 -o /dev/null -w %{http_code} https://example.com' | grep -vE >/dev/null '2[0-9][0-9]|3[0-9][0-9]' \
        && nw_run 'curl -s --max-time 25 -o /dev/null -w %{http_code} https://api.anthropic.com' | grep -v >/dev/null 000"

check "netwall vm: inner busybox wget reaches the allowlisted host through the door" \
    "nw_run 'timeout 180 bash -lc \"docker pull busybox:latest >/dev/null 2>&1 && docker run --rm -e HTTP_PROXY=\$HTTP_PROXY -e HTTPS_PROXY=\$HTTPS_PROXY busybox wget -O /dev/null https://api.anthropic.com\"' >/tmp/llm-in-a-box-e2e-nw-inner.log 2>&1; [ \$? -eq 0 ]"

# T14: the wall persists across shutdown/resume.
"$BOC" --runtime vm --shutdown "$NWSESS" >/tmp/llm-in-a-box-e2e-nwstop.log 2>&1 || true
timeout 600 "$BOC" --net-policy "$NWPOL" --runtime vm "$NWSESS" </dev/null >/tmp/llm-in-a-box-e2e-nw2.log 2>&1 || true
NW_PORT=$(cat "$STATE_DIR/sessions/$NWSESS/ssh_port" 2>/dev/null || true)
NW_SSHOPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -p "$NW_PORT")
# Scalar form for eval'd check strings: the array expands UNQUOTED there and
# each "-o BatchMode=yes" element word-splits in half — the joined scalar
# reproduces the original token stream safely.
NW_SSHOPTS_STR="${NW_SSHOPTS[*]}"
for i in $(seq 1 120); do
    ssh "${NW_SSHOPTS[@]}" "$(whoami)@127.0.0.1" 'true' >/dev/null 2>&1 && break
    sleep 5
done
check "netwall vm: the wall persists across resume (T14)" \
    "nw_run 'curl -s --max-time 20 -o /dev/null -w %{http_code} https://example.com' | grep -vE >/dev/null '2[0-9][0-9]|3[0-9][0-9]' \
        && nw_run 'curl -s --max-time 25 -o /dev/null -w %{http_code} https://api.anthropic.com' | grep -v >/dev/null 000"

"$BOC" --runtime vm --destroy "$NWSESS" >/tmp/llm-in-a-box-e2e-nwrm.log 2>&1 || true
check "netwall vm: --destroy removes the session and its relay" \
    "[ ! -d '$STATE_DIR/sessions/$NWSESS' ] \
        && ! docker container inspect llm-in-a-box-relay-$NWSESS >/dev/null 2>&1"
rm -f "$NWPOL"

echo ""
echo "verify-vm-e2e.sh: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
[ "$FAIL" -eq 0 ]
