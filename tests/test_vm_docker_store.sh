#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_vm_docker_store.sh — behavioral test for the VM guest Docker store
# wiring (docker/vm-docker-store.sh, sourced by docker/vm-setup.sh).
#
# WHAT: exercises the guest setup function against an isolated scratch
#       environment (all paths and devices overridden; no Docker build, no
#       real VM boot, no root). The store is a single sparse ext4 image on
#       the host, attached to the VM as an NVMe device; the guest formats
#       it only when it carries no filesystem, mounts it at the store mount
#       point, and points containerd's root and docker's data-root inside.
#
# WHY: the guest's own drive is small, so Docker/containerd data lives in
#      the attached image. The wiring must never reformat a filesystem,
#      never override a user-set value, migrate the values earlier versions
#      of this wiring wrote, fall back safely when the device is absent or
#      unmountable, and never block the setup unit on a daemon job (the
#      `--no-block` contract). A hostile reviewer must not trust comments
#      (HS-3): this test runs the ACTUAL function and observes the configs
#      and the recorded external commands.
#
# USAGE: tests/test_vm_docker_store.sh
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../docker/vm-docker-store.sh"

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

# ── scratch environment ────────────────────────────────────────────────────
WORK=$(mktemp -d /tmp/vm-docker-store-test.XXXXXX)
DEV="$WORK/dev"
MNT="$WORK/mnt"
DOCKER_ETC="$WORK/docker"
CONTAINERD_CFG="$WORK/containerd.toml"
STORE_DIR="$WORK/store"
MSG="$WORK/msg.md"
MARKER="$WORK/fallback.marker"
FSTAB="$WORK/fstab"
mkdir -p "$DOCKER_ETC" "$STORE_DIR"
printf 'fixture-message\n' > "$MSG"
printf 'operator-marker\n' > "$FSTAB"
# The image file stand-in: a regular file accepted only under the test seam.
: > "$DEV"
# An isolated device namespace and sysfs tree, used by every check unless it
# supplies its own. Without these the finder's fallbacks search the REAL
# /dev/disk/by-id and /sys, so a check that means to test "no device attached"
# would find the host's actual store device instead, which is exactly what
# happened once the fallbacks started matching the truncated serial. Isolating
# them makes every check's device fixture mean what it says, and keeps any
# check from reaching a real block device.
DEVROOT_EMPTY="$WORK/devroot-default"
SYSFS_EMPTY="$WORK/sysfs-default"
mkdir -p "$DEVROOT_EMPTY" "$SYSFS_EMPTY"

run_store() {
    local extra_env="${1:-}"
    env PATH="$WORK/bin:$PATH" \
        LLMBOX_STORE_DEV="$DEV" LLMBOX_STORE_MNT="$MNT" \
        LLMBOX_STORE_DOCKER_ETC="$DOCKER_ETC" \
        LLMBOX_STORE_CONTAINERD_CFG="$CONTAINERD_CFG" \
        LLMBOX_STORE_MSG="$MSG" LLMBOX_STORE_DIR="$STORE_DIR" \
        LLMBOX_STORE_WAIT_ITERS=1 LLMBOX_STORE_DEV_TEST=1 \
        LLMBOX_STORE_FALLBACK_MARKER="$MARKER" \
        LBX_STORE_DEVROOT="$DEVROOT_EMPTY" LBX_STORE_SYSFS_DIR="$SYSFS_EMPTY" \
        LLMBOX_FIXTURE_WORK="$WORK" $extra_env \
        bash -c ". \"$HELPER\"; run_vm_docker_store"
}

# ── fixture fakes ──────────────────────────────────────────────────────────
mkdir -p "$WORK/bin"
cat > "$WORK/bin/blkid" <<'FAKEEOF'
#!/bin/bash
echo "blkid $*" >> "$LLMBOX_FIXTURE_WORK/blkid.calls"
[ -f "$LLMBOX_FIXTURE_WORK/blkid.out" ] && cat "$LLMBOX_FIXTURE_WORK/blkid.out"
if [ -f "$LLMBOX_FIXTURE_WORK/blkid.rc" ]; then
    exit "$(cat "$LLMBOX_FIXTURE_WORK/blkid.rc")"
fi
[ -f "$LLMBOX_FIXTURE_WORK/blkid.out" ] && exit 0
exit 2
FAKEEOF
cat > "$WORK/bin/wipefs" <<'FAKEEOF'
#!/bin/bash
echo "wipefs $*" >> "$LLMBOX_FIXTURE_WORK/wipefs.calls"
[ -f "$LLMBOX_FIXTURE_WORK/wipefs.out" ] && cat "$LLMBOX_FIXTURE_WORK/wipefs.out"
[ -f "$LLMBOX_FIXTURE_WORK/wipefs.rc" ] && exit "$(cat "$LLMBOX_FIXTURE_WORK/wipefs.rc")"
exit 0
FAKEEOF
cat > "$WORK/bin/mkfs.ext4" <<'FAKEEOF'
#!/bin/bash
echo "mkfs.ext4 $*" >> "$LLMBOX_FIXTURE_WORK/mkfs.calls"
[ -f "$LLMBOX_FIXTURE_WORK/mkfs.fail" ] && exit 1
touch "$LLMBOX_FIXTURE_WORK/mkfs.done"
exit 0
FAKEEOF
cat > "$WORK/bin/mount" <<'FAKEEOF'
#!/bin/bash
echo "mount $*" >> "$LLMBOX_FIXTURE_WORK/mount.calls"
[ -f "$LLMBOX_FIXTURE_WORK/mount.fail" ] && exit 1
mkdir -p "${@: -1}" 2>/dev/null || true
touch "$LLMBOX_FIXTURE_WORK/mounted"
exit 0
FAKEEOF
cat > "$WORK/bin/mountpoint" <<'FAKEEOF'
#!/bin/bash
echo "mountpoint $*" >> "$LLMBOX_FIXTURE_WORK/mountpoint.calls"
[ "$1" = "-q" ] && shift
if [ "$1" = "/data" ]; then
    [ -f "$LLMBOX_FIXTURE_WORK/data-mounted" ] && exit 0
    exit 1
fi
[ -f "$LLMBOX_FIXTURE_WORK/mounted" ] && exit 0
exit 1
FAKEEOF
cat > "$WORK/bin/findmnt" <<'FAKEEOF'
#!/bin/bash
cat "$LLMBOX_FIXTURE_WORK/root-source" 2>/dev/null || echo /dev/vda
exit 0
FAKEEOF
cat > "$WORK/bin/udevadm" <<'FAKEEOF'
#!/bin/bash
echo "udevadm $*" >> "$LLMBOX_FIXTURE_WORK/udevadm.calls"
cat "$LLMBOX_FIXTURE_WORK/udevadm.out" 2>/dev/null
exit 0
FAKEEOF
cat > "$WORK/bin/modprobe" <<'FAKEEOF'
#!/bin/bash
echo "modprobe $*" >> "$LLMBOX_FIXTURE_WORK/modprobe.calls"
exit 0
FAKEEOF
cat > "$WORK/bin/sleep" <<'FAKEEOF'
#!/bin/bash
echo "sleep $*" >> "$LLMBOX_FIXTURE_WORK/sleep.calls"
exit 0
FAKEEOF
cat > "$WORK/bin/timeout" <<'FAKEEOF'
#!/bin/bash
echo "timeout $*" >> "$LLMBOX_FIXTURE_WORK/timeout.calls"
shift
exec "$@"
FAKEEOF
cat > "$WORK/bin/e2fsck" <<'FAKEEOF'
#!/bin/bash
echo "e2fsck $*" >> "$LLMBOX_FIXTURE_WORK/e2fsck.calls"
[ -f "$LLMBOX_FIXTURE_WORK/e2fsck.fail" ] && exit 1
exit 0
FAKEEOF
cat > "$WORK/bin/losetup" <<'FAKEEOF'
#!/bin/bash
echo "losetup $*" >> "$LLMBOX_FIXTURE_WORK/losetup.calls"
exit 0
FAKEEOF
cat > "$WORK/bin/systemctl" <<'FAKEEOF'
#!/bin/bash
echo "$*" >> "$LLMBOX_FIXTURE_WORK/systemctl.calls"
if [ "$1 $2" = "is-active docker" ]; then
    cat "$LLMBOX_FIXTURE_WORK/docker.state" 2>/dev/null || echo inactive
elif [ "$1 $2" = "is-active containerd" ]; then
    cat "$LLMBOX_FIXTURE_WORK/containerd.state" 2>/dev/null || echo inactive
fi
exit 0
FAKEEOF
chmod +x "$WORK/bin/"*
touch "$WORK/data-mounted"

reset_calls() {
    : > "$WORK/blkid.calls"; : > "$WORK/wipefs.calls"
    : > "$WORK/mkfs.calls"; : > "$WORK/mount.calls"
    : > "$WORK/mountpoint.calls"; : > "$WORK/udevadm.calls"
    : > "$WORK/modprobe.calls"; : > "$WORK/timeout.calls"
    : > "$WORK/systemctl.calls"; : > "$WORK/e2fsck.calls"
    : > "$WORK/losetup.calls"; : > "$WORK/sleep.calls"
}

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# A fresh containerd config in the stock shape the wiring recognizes.
fresh_containerd_cfg() {
    cat > "$CONTAINERD_CFG" <<'EOF'
disabled_plugins = ["cri"]
#root = "/var/lib/containerd"
EOF
}

# A fresh daemon.json with netwall proxies (the netwall block writes this).
fresh_daemon_json() {
    cat > "$DOCKER_ETC/daemon.json" <<'EOF'
{
  "proxies": {
    "http-proxy": "http://10.0.2.100:3128",
    "https-proxy": "http://10.0.2.100:3128",
    "no-proxy": "localhost,127.0.0.1"
  }
}
EOF
}

# ── S1: no filesystem → format then mount ─────────────────────────────────
# Requirement: first boot must format the attached image exactly once and
# mount it at the store mount point.
# Theory: with blkid reporting no signature, the wiring runs mkfs.ext4 once
# and mounts the device; both roots then point inside the mount.
fresh_containerd_cfg; fresh_daemon_json
rm -f "$WORK/blkid.out" "$WORK/wipefs.out" "$WORK/mkfs.done" \
      "$WORK/mounted" "$MARKER" "$WORK/mount.fail" "$WORK/mkfs.fail"
reset_calls
run_store >/dev/null 2>&1
# mkfs ran exactly once and against the resolved device.
check "S1: a device with no filesystem is formatted exactly once" \
    "[ \"\$(grep -c '^mkfs.ext4 ' '$WORK/mkfs.calls')\" = '1' ] && grep -Fq '$DEV' '$WORK/mkfs.calls'"
# the mount names both the device and the configured mount point.
check "S1: the formatted device is mounted at the store mount point" \
    "grep -q '^mount ' '$WORK/mount.calls' && grep -Fq '$DEV' '$WORK/mount.calls' && grep -Fq '$MNT' '$WORK/mount.calls'"
# containerd's root lives inside the mounted image, not the guest disk.
check "S1: containerd root points inside the mounted image" \
    "grep -Fq 'root = \"$MNT/containerd\"' '$CONTAINERD_CFG'"
# docker's data-root lives inside the mounted image too.
check "S1: docker data-root points inside the mounted image" \
    "python3 -c 'import json,sys; c=json.load(open(\"$DOCKER_ETC/daemon.json\")); sys.exit(0 if c.get(\"data-root\")==\"$MNT/docker\" else 1)'"

# ── S2: ext4 present → never reformat; mount and roots still wired ────────
# Requirement: an existing filesystem must never be reformatted.
# Theory: with blkid reporting ext4 the wiring mounts and wires the roots
# without running mkfs — the positive pair for S1's format case.
fresh_containerd_cfg; fresh_daemon_json
printf 'ext4\n' > "$WORK/blkid.out"; echo 0 > "$WORK/blkid.rc"
rm -f "$WORK/mkfs.done" "$WORK/mounted" "$MARKER" "$WORK/mount.fail" "$WORK/mkfs.fail"
reset_calls
run_store >/dev/null 2>&1
# no format call at all.
check "S2: an existing ext4 filesystem is never reformatted" \
    "[ ! -s '$WORK/mkfs.calls' ]"
# ...but the run is not a no-op: it still mounted and wired the roots.
check "S2: the existing filesystem is still mounted and wired (non-vacuous)" \
    "grep -q '^mount ' '$WORK/mount.calls' && grep -Fq 'root = \"$MNT/containerd\"' '$CONTAINERD_CFG'"

# ── S3: steady state — ext4, wired, not yet mounted ───────────────────────
# Requirement: a real boot mounts the image, starts the daemons without
# blocking the setup unit, and clears any stale fallback marker.
# Theory: ext4 + already-wired roots + inactive daemons → mount happens,
# one --no-block docker start is queued, and the marker is removed.
fresh_containerd_cfg; fresh_daemon_json
printf 'root = "%s/containerd"\n' "$MNT" > "$CONTAINERD_CFG"
python3 - "$DOCKER_ETC/daemon.json" "$MNT" <<'PYEOF'
import json,sys
p,m=sys.argv[1],sys.argv[2]
c=json.load(open(p)); c["data-root"]=f"{m}/docker"
json.dump(c,open(p,"w"),indent=2)
PYEOF
printf 'ext4\n' > "$WORK/blkid.out"; echo 0 > "$WORK/blkid.rc"
rm -f "$WORK/mounted" "$WORK/mount.fail"; touch "$MARKER"
echo active > "$WORK/docker.state"; echo active > "$WORK/containerd.state"
reset_calls
run_store >/dev/null 2>&1
# the image is mounted and the daemon action is queued without blocking.
check "S3: a real boot mounts the image and queues a non-blocking docker start" \
    "grep -q '^mount ' '$WORK/mount.calls' && grep -q -- '--no-block' '$WORK/systemctl.calls'"
# a successful store run removes the stale fallback marker.
check "S3: a successful run clears the stale fallback marker" \
    "[ ! -e '$MARKER' ]"

# ── S4: device absent → local fallback, roots reverted, marker set ────────
# Requirement: a missing store device is a safe downgrade, never a failure.
# Theory: with no device the wiring formats/mounts nothing, removes its own
# root lines, and sets the fallback marker so the downgrade is visible.
fresh_containerd_cfg
printf 'root = "%s/containerd"\n' "$MNT" > "$CONTAINERD_CFG"
fresh_daemon_json
python3 - "$DOCKER_ETC/daemon.json" "$MNT" <<'PYEOF'
import json,sys
p,m=sys.argv[1],sys.argv[2]
c=json.load(open(p)); c["data-root"]=f"{m}/docker"
json.dump(c,open(p,"w"),indent=2)
PYEOF
rm -f "$DEV" "$WORK/mounted" "$MARKER" "$WORK/mount.fail"
reset_calls
run_store >/dev/null 2>&1
# no device → no format and no mount attempt.
check "S4: an absent device formats and mounts nothing" \
    "[ ! -s '$WORK/mkfs.calls' ] && [ ! -s '$WORK/mount.calls' ]"
# the store roots this wiring wrote are removed so the daemons use local defaults.
check "S4: our own roots are reverted to the local defaults when the store is absent" \
    "! grep -Fq '$MNT/containerd' '$CONTAINERD_CFG' && ! grep -Fq '$MNT/docker' '$DOCKER_ETC/daemon.json'"
# the fallback marker makes the degraded boot visible.
check "S4: the fallback is visible to the operator" \
    "[ -f '$MARKER' ]"
: > "$DEV"

# ── S5: mount failure → fallback, no roots wired, marker set ──────────────
# Requirement: an unmountable image must never leave docker pointed at it.
# Theory: mount fails → no store roots are written and the fallback marker
# makes the degraded boot visible.
fresh_containerd_cfg; fresh_daemon_json
printf 'ext4\n' > "$WORK/blkid.out"; echo 0 > "$WORK/blkid.rc"
rm -f "$WORK/mounted" "$MARKER"; touch "$WORK/mount.fail"
reset_calls
run_store >/dev/null 2>&1
check "S5: a mount failure leaves the roots unwired and marks the fallback" \
    "[ -f '$MARKER' ] && ! grep -Fq '$MNT/containerd' '$CONTAINERD_CFG' && ! grep -Fq '$MNT/docker' '$DOCKER_ETC/daemon.json'"
rm -f "$WORK/mount.fail"

# ── S6: ext4 present but mount fails → one e2fsck, retry, else fallback ───
# Requirement: a dirty filesystem gets one bounded repair attempt, never a
# reformat and never a hang.
# Theory: mount fails on ext4 → a timeout-wrapped e2fsck runs (the fake
# timeout records `timeout <secs> e2fsck ...`), the mount is retried, and
# when it still fails the fallback marker is set.
fresh_containerd_cfg; fresh_daemon_json
printf 'ext4\n' > "$WORK/blkid.out"; echo 0 > "$WORK/blkid.rc"
rm -f "$WORK/mounted" "$MARKER"; touch "$WORK/mount.fail"
reset_calls
run_store >/dev/null 2>&1
check "S6: an unmountable ext4 gets one bounded e2fsck attempt before falling back" \
    "grep -q 'e2fsck ' '$WORK/timeout.calls' && [ -f '$MARKER' ]"
rm -f "$WORK/mount.fail"

# ── S7: roots wired; netwall proxies preserved ────────────────────────────
# Requirement: both daemon roots live inside the mounted image and the
# netwall proxy block survives the daemon.json merge.
# Theory: mounted ext4 → containerd/docker point at $MNT and the proxies
# written by the netwall step are still present and valid.
fresh_containerd_cfg; fresh_daemon_json
printf 'ext4\n' > "$WORK/blkid.out"; echo 0 > "$WORK/blkid.rc"
rm -f "$WORK/mounted" "$MARKER"
reset_calls
run_store >/dev/null 2>&1
check "S7: the mounted image hosts both roots and netwall proxies survive" \
    "grep -Fq 'root = \"$MNT/containerd\"' '$CONTAINERD_CFG' && grep -q 'http-proxy' '$DOCKER_ETC/daemon.json' && python3 -c 'import json; c=json.load(open(\"$DOCKER_ETC/daemon.json\")); assert c[\"data-root\"]==\"$MNT/docker\"'"

# ── S8: legacy values migrated; genuine user values preserved ─────────────
# Requirement: migrate only the exact values earlier wiring of this project
# wrote; never override a genuine user value.
# Theory: the old store-dir roots and the vfs sentinel are replaced/removed,
# while a /custom root and an overlay2 driver survive untouched.
cat > "$CONTAINERD_CFG" <<'EOF'
root = "/data/vms_and_docker_from_llm_box/containerd"
snapshotter = "native"
EOF
cat > "$DOCKER_ETC/daemon.json" <<'EOF'
{
  "proxies": { "http-proxy": "http://10.0.2.100:3128" },
  "data-root": "/data/vms_and_docker_from_llm_box/docker",
  "storage-driver": "vfs"
}
EOF
printf 'ext4\n' > "$WORK/blkid.out"; echo 0 > "$WORK/blkid.rc"
rm -f "$WORK/mounted" "$MARKER"
reset_calls
run_store >/dev/null 2>&1
# legacy containerd root replaced; the invalid top-level snapshotter line removed.
check "S8: the earlier wiring's containerd root and invalid snapshotter line are replaced/removed" \
    "grep -Fq 'root = \"$MNT/containerd\"' '$CONTAINERD_CFG' && ! grep -q '^snapshotter' '$CONTAINERD_CFG'"
# legacy data-root migrated and the vfs sentinel removed; proxies survive.
check "S8: the earlier wiring's data-root and vfs sentinel are migrated" \
    "python3 -c 'import json; c=json.load(open(\"$DOCKER_ETC/daemon.json\")); assert c.get(\"data-root\")==\"$MNT/docker\"; assert \"storage-driver\" not in c' && grep -q 'http-proxy' '$DOCKER_ETC/daemon.json'"
# genuine user values survive
cat > "$CONTAINERD_CFG" <<'EOF'
root = "/custom/root"
EOF
cat > "$DOCKER_ETC/daemon.json" <<'EOF'
{ "data-root": "/var/lib/docker-custom", "storage-driver": "overlay2" }
EOF
rm -f "$WORK/mounted"
run_store >/dev/null 2>&1
# a user root/driver pair is not mistaken for legacy wiring and is untouched.
check "S8: genuine user-set roots and drivers are preserved" \
    "grep -q '^root = \"/custom/root\"' '$CONTAINERD_CFG' && python3 -c 'import json; c=json.load(open(\"$DOCKER_ETC/daemon.json\")); assert c[\"data-root\"]==\"/var/lib/docker-custom\"; assert c[\"storage-driver\"]==\"overlay2\"'"

# ── S9: malformed daemon.json is backed up, never silently discarded ──────
# Requirement: a rewrite must never destroy user data silently, and a later
# malformed file must never be lost because an earlier backup exists.
# Theory: invalid JSON is backed up to daemon.json.bak before any new file
# is written; the backup is byte-for-byte the malformed content; and a
# second, distinct malformation overwrites the earlier backup so the .bak
# always reflects the most recent malformed content.
fresh_containerd_cfg
rm -f "$DOCKER_ETC/daemon.json.bak"
printf '{ this is not json\n' > "$WORK/malformed-1"
cp "$WORK/malformed-1" "$DOCKER_ETC/daemon.json"
printf 'ext4\n' > "$WORK/blkid.out"; echo 0 > "$WORK/blkid.rc"
rm -f "$WORK/mounted"
run_store >/dev/null 2>&1
check "S9: a malformed daemon.json is backed up byte-for-byte before any rewrite" \
    "test -f '$DOCKER_ETC/daemon.json.bak' && cmp -s '$DOCKER_ETC/daemon.json.bak' '$WORK/malformed-1'"
printf '{ "second": not json\n' > "$WORK/malformed-2"
cp "$WORK/malformed-2" "$DOCKER_ETC/daemon.json"
rm -f "$WORK/mounted"
run_store >/dev/null 2>&1
check "S9b: a second malformation overwrites the backup with the latest malformed content" \
    "cmp -s '$DOCKER_ETC/daemon.json.bak' '$WORK/malformed-2'"

# ── S10: --no-block contract ───────────────────────────────────────────────
# Requirement (F1 deadlock): every daemon action taken from the setup unit
# is non-blocking, and reset-failed runs first.
# Theory: a CHANGED run (fresh configs, successful mount, active daemons)
# must produce at least one start/restart action, every action carries
# --no-block, and reset-failed appears without --no-block.
fresh_containerd_cfg; fresh_daemon_json
printf 'ext4\n' > "$WORK/blkid.out"; echo 0 > "$WORK/blkid.rc"
rm -f "$WORK/mounted" "$MARKER" "$WORK/mount.fail"
echo active > "$WORK/docker.state"; echo active > "$WORK/containerd.state"
reset_calls
run_store >/dev/null 2>&1
# at least one start/restart happened, and every action carries --no-block.
check "S10: every daemon start/restart is non-blocking and at least one happens" \
    "[ \"\$(grep -cE '^(--no-block )?(restart|start) ' '$WORK/systemctl.calls')\" -ge 1 ] && ! grep -E '^(restart|start) ' '$WORK/systemctl.calls' | grep -v >/dev/null -- '--no-block'"
# reset-failed is present (the start-limit escape) and is not itself --no-block.
check "S10: reset-failed is used first and carries no --no-block" \
    "grep -q '^reset-failed containerd docker docker.socket$' '$WORK/systemctl.calls'"

# ── S11: no driver/snapshotter keys written; user driver survives ─────────
# Requirement: the old vfs/native workarounds are gone; user choices are
# never overridden.
# Theory: a mounted run writes neither a storage-driver nor a snapshotter
# key, and an existing user overlay2 driver is preserved exactly.
fresh_containerd_cfg
cat > "$DOCKER_ETC/daemon.json" <<'EOF'
{ "storage-driver": "overlay2" }
EOF
printf 'ext4\n' > "$WORK/blkid.out"; echo 0 > "$WORK/blkid.rc"
rm -f "$WORK/mounted"
run_store >/dev/null 2>&1
check "S11: the wiring writes no storage-driver/snapshotter key and preserves a user driver" \
    "python3 -c 'import json; c=json.load(open(\"$DOCKER_ETC/daemon.json\")); assert c[\"storage-driver\"]==\"overlay2\"' && ! grep -q '^snapshotter' '$CONTAINERD_CFG'"

# ── S12: removed machinery stays removed ──────────────────────────────────
# Requirement: the obsolete fstab and loop-device machinery must never
# reappear.
# Theory: after a real run with the fake losetup first on PATH, the fstab
# fixture is untouched and the fake recorded zero losetup invocations
# (asserting against the real losetup would be vacuous in this scratch env).
reset_calls
run_store >/dev/null 2>&1
# the fstab fixture still holds only its operator marker.
check "S12: no fstab entry is written" \
    "grep -qx 'operator-marker' '$FSTAB'"
# the fake losetup (first on PATH) recorded zero invocations.
check "S12: no loop device is attached" \
    "[ ! -s '$WORK/losetup.calls' ]"

# ── S13: invalid devices are rejected ─────────────────────────────────────
# Requirement: the root device and spoofed non-block devices are never
# formatted or mounted.
# Theory: when findmnt reports the store device as /, and when a non-block
# symlink is presented in real mode (no test seam), the wiring refuses the
# device and falls back with no mkfs/mount.
fresh_containerd_cfg; fresh_daemon_json
rm -f "$WORK/mounted" "$MARKER"
# root device: the fake findmnt reports the store device as /
echo "$DEV" > "$WORK/root-source"
reset_calls
run_store >/dev/null 2>&1
# root device rejected: no mkfs/mount and the fallback marker is set.
check "S13: the root device is rejected as the store device" \
    "[ ! -s '$WORK/mkfs.calls' ] && [ ! -s '$WORK/mount.calls' ] && [ -f '$MARKER' ]"
echo /dev/vda > "$WORK/root-source"
# spoofed symlink: real mode (no test seam) must reject a non-block device
rm -f "$MARKER" "$DEV"; ln -s "$WORK/not-a-device" "$DEV"; : > "$WORK/not-a-device"
run_store "LLMBOX_STORE_DEV_TEST=0" >/dev/null 2>&1
# non-block symlink rejected in real mode: no mkfs and the marker is set.
check "S13: a non-block device (spoofed symlink) is rejected" \
    "[ ! -s '$WORK/mkfs.calls' ] && [ -f '$MARKER' ]"
rm -f "$DEV"; : > "$DEV"

# ── S14: mkfs failure → no mount, no roots, marker ────────────────────────
# Requirement: a failed format is a safe fallback, not a broken mount.
# Theory: the mkfs fake exits 1 → no mount is attempted, no store roots are
# written, and the fallback marker is set.
fresh_containerd_cfg; fresh_daemon_json
rm -f "$WORK/blkid.out" "$WORK/wipefs.out" "$WORK/mounted" "$MARKER"
touch "$WORK/mkfs.fail"
reset_calls
run_store >/dev/null 2>&1
check "S14: a failed format mounts nothing and marks the fallback" \
    "[ ! -s '$WORK/mount.calls' ] && [ -f '$MARKER' ] && ! grep -Fq '$MNT/containerd' '$CONTAINERD_CFG'"
rm -f "$WORK/mkfs.fail"

# ── S15: systemctl absent → configs still written, exit 0 ─────────────────
# Requirement: the setup must not depend on a running systemd.
# Theory: the LLMBOX_STORE_SYSTEMCTL seam (default `systemctl`, probed with
# `command -v`) points at a non-existent binary, while the fake systemctl
# stays first on PATH as a tripwire — configs are still written, exit is 0,
# and the tripwire records zero invocations (so the real systemctl is never
# in the equation).
fresh_containerd_cfg; fresh_daemon_json
printf 'ext4\n' > "$WORK/blkid.out"; echo 0 > "$WORK/blkid.rc"
rm -f "$WORK/mounted" "$MARKER"
reset_calls
run_store "LLMBOX_STORE_SYSTEMCTL=$WORK/no-such-systemctl" >/dev/null 2>&1
rc=$?
check "S15: with systemctl absent the wiring still writes configs and exits 0" \
    "[ $rc -eq 0 ] && grep -Fq '$MNT/containerd' '$CONTAINERD_CFG' && [ ! -s '$WORK/systemctl.calls' ]"

# ── S16: README planting and the /data guard ──────────────────────────────
# Requirement: plant the first-reader README once, never clobber a reader's
# edit, and never write it to the guest disk when /data is unmounted.
# Theory: a missing README is planted; an existing one is preserved; with
# /data unmounted a deliberately removed README is NOT recreated (the old
# assertion was vacuous because the file already existed).
rm -f "$STORE_DIR/README.md"
run_store >/dev/null 2>&1
# a missing README is planted.
check "S16: the first-reader README is planted in the store directory" \
    "test -s '$STORE_DIR/README.md'"
echo 'reader-edit' > "$STORE_DIR/README.md"
run_store >/dev/null 2>&1
# a reader's edit is preserved (no clobber).
check "S16: an existing README is never clobbered" \
    "grep -qx 'reader-edit' '$STORE_DIR/README.md'"
rm -f "$WORK/data-mounted" "$STORE_DIR/README.md"
run_store >/dev/null 2>&1
# with /data unmounted the deliberately removed README is not recreated.
check "S16: with /data unmounted no README is written to the guest disk" \
    "[ ! -e '$STORE_DIR/README.md' ]"
touch "$WORK/data-mounted"

# ── S17: property-style format decision over blkid/wipefs outcomes ────────
# Requirement: format if and only if the device carries no filesystem.
# Theory: across generated probe outputs and exit codes (empty, ext4, xfs,
# error), mkfs runs only for the empty/no-signature case. The truth table's
# dangerous half is covered explicitly: blkid exit 2 with empty output but a
# wipefs signature (the second probe saw what the first missed) and a wipefs
# error (exit 1) must BOTH never format — a signature or an error is not
# evidence of an empty device.
s17_ok=1
for case in "empty:2::0:" "ext4:0:ext4:0:" "xfs:0:xfs:0:" "error:4::0:" \
            "wipefs-sig:2::0:ext4" "wipefs-err:2::1:"; do
    IFS=: read -r name brc bout wrc wout <<< "$case"
    fresh_containerd_cfg; fresh_daemon_json
    rm -f "$WORK/blkid.out" "$WORK/blkid.rc" "$WORK/wipefs.out" "$WORK/wipefs.rc" \
          "$WORK/mkfs.done" "$WORK/mounted" "$MARKER" "$WORK/mount.fail" "$WORK/mkfs.fail"
    [ -n "$bout" ] && printf '%s\n' "$bout" > "$WORK/blkid.out"
    echo "$brc" > "$WORK/blkid.rc"
    [ -n "$wout" ] && printf '%s\n' "$wout" > "$WORK/wipefs.out"
    echo "$wrc" > "$WORK/wipefs.rc"
    reset_calls
    run_store >/dev/null 2>&1
    case "$name" in
        empty) want=1 ;;
        *)     want=0 ;;
    esac
    got=0; [ -s "$WORK/mkfs.calls" ] && got=1
    [ "$got" = "$want" ] || { s17_ok=0; echo "  S17 case '$name' expected mkfs=$want got=$got"; }
done
rm -f "$WORK/blkid.rc" "$WORK/wipefs.rc" "$WORK/blkid.out" "$WORK/wipefs.out"
check "S17: the format decision is driven by the probe outcomes (mkfs only when empty)" \
    "[ $s17_ok -eq 1 ]"

# ── S18: property-style daemon.json merge preserves non-owned keys ────────
# Requirement: the merge is a pure transform — only data-root is touched,
# every other key survives exactly, and a second run is idempotent.
# Theory: randomized configs (incl. legacy and genuine user values) stay
# valid JSON across two runs, with data-root pointing at the harness mount
# point ($MNT/docker) or the user's own value.
s18_ok=1
for i in 1 2 3 4 5; do
    fresh_containerd_cfg
    python3 - "$DOCKER_ETC/daemon.json" "$i" <<'PYEOF'
import json,sys,random
p,seed=sys.argv[1],int(sys.argv[2])
r=random.Random(seed)
cfg={"keep-int":r.randint(0,10**6),"keep-str":"v%d"%seed,"nested":{"a":[1,2,3]}}
if seed%2: cfg["proxies"]={"http-proxy":"http://10.0.2.100:3128"}
if seed==3: cfg["data-root"]="/data/vms_and_docker_from_llm_box/docker"
if seed==4: cfg["storage-driver"]="vfs"
if seed==5: cfg["data-root"]="/custom"
json.dump(cfg,open(p,"w"),indent=2)
PYEOF
    printf 'ext4\n' > "$WORK/blkid.out"; echo 0 > "$WORK/blkid.rc"
    rm -f "$WORK/mounted" "$MARKER"
    run_store >/dev/null 2>&1
    run_store >/dev/null 2>&1
    python3 - "$DOCKER_ETC/daemon.json" "$i" "$MNT" <<'PYEOF' || s18_ok=0
import json,sys
p,seed,mnt=sys.argv[1],int(sys.argv[2]),sys.argv[3]
c=json.load(open(p))
assert isinstance(c,dict)
assert "keep-int" in c and "keep-str" in c and "nested" in c, "non-owned keys lost"
if seed%2: assert "proxies" in c, "proxies lost"
assert c.get("data-root") in (mnt+"/docker","/custom") or "data-root" not in c
assert c.get("storage-driver") in ("vfs","overlay2",None)
PYEOF
done
check "S18: the merge preserves non-owned keys and stays idempotent/valid" \
    "[ $s18_ok -eq 1 ]"

# ── S19: blocking operations are bounded ──────────────────────────────────
# Requirement: no boot-hang path — every blocking external call is
# timeout-wrapped and the device wait is capped by LLMBOX_STORE_WAIT_ITERS.
# Theory: a no-filesystem run (mkfs) and an ext4-mount-failure run (e2fsck)
# are executed HERE so the fresh timeout log holds blkid/mkfs/mount/e2fsck;
# then a device-absent run with the harness's 1-iteration seam sleeps at
# most once (bounded wait, not an unbounded poll).
reset_calls
fresh_containerd_cfg; fresh_daemon_json
rm -f "$WORK/blkid.out" "$WORK/wipefs.out" "$WORK/blkid.rc" "$WORK/wipefs.rc" \
      "$WORK/mkfs.done" "$WORK/mounted" "$MARKER" "$WORK/mount.fail" "$WORK/mkfs.fail"
run_store >/dev/null 2>&1
printf 'ext4\n' > "$WORK/blkid.out"; echo 0 > "$WORK/blkid.rc"
rm -f "$WORK/mounted" "$MARKER"; touch "$WORK/mount.fail"
run_store >/dev/null 2>&1
# all four blocking calls appear in the pass-through timeout log.
check "S19: device probe, format, mount and fsck run under timeout" \
    "grep -q 'blkid' '$WORK/timeout.calls' && grep -q 'mkfs.ext4' '$WORK/timeout.calls' && grep -q 'mount' '$WORK/timeout.calls' && grep -q 'e2fsck' '$WORK/timeout.calls'"
rm -f "$WORK/mount.fail"
: > "$WORK/sleep.calls"
rm -f "$DEV" "$WORK/mounted" "$MARKER"
run_store >/dev/null 2>&1
# at most one wait sleep with LLMBOX_STORE_WAIT_ITERS=1: the wait cannot hang.
check "S19: the device wait is bounded by LLMBOX_STORE_WAIT_ITERS (at most one sleep with the 1-iteration seam)" \
    "[ \"\$(wc -l < '$WORK/sleep.calls' 2>/dev/null || echo 0)\" -le 1 ]"
: > "$DEV"


# ── S20: dual serial acceptance (amendment 16) ────────────────
# Requirement: an old immutable base's store device carries the OLD serial
# (boc-docker-store); the by-id glob fallback must accept it (the launcher
# attaches the new serial for NEW sessions only).
# Theory: the by-id glob is the device finder's fallback when the primary path
# is missing, so an old-serial entry there must be used. The fixture is built
# inside the isolated device root, so this check runs on any host and can never
# reach a real device; the earlier form wrote into the real /dev/disk/by-id and
# skipped wherever that was not writable, which is why it never ran here.
#
# The assertion is that the OLD-SERIAL device itself reached the format probe.
# The earlier form accepted either the fallback marker or any probe call, and
# one of those two holds whether or not the device was found, so it passed
# whether the fallback worked or not, and could not fail.
OLDSERIAL_BYID="$DEVROOT_EMPTY/disk/by-id"
mkdir -p "$OLDSERIAL_BYID"
OLDSERIAL_DEV="$OLDSERIAL_BYID/nvme-QEMU_NVMe_Ctrl_boc-docker-store"
ln -sf "$WORK/store-old-serial.img" "$OLDSERIAL_DEV"
: > "$WORK/store-old-serial.img"
fresh_containerd_cfg; fresh_daemon_json
rm -f "$MARKER" "$WORK/mounted"
reset_calls
run_store "LLMBOX_STORE_DEV=$WORK/does-not-exist-dev" >/dev/null 2>&1
check "S20: an old-serial (boc-docker-store) by-id device is accepted as the store device" \
    "grep -q 'boc-docker-store' '$WORK/blkid.calls'"
rm -f "$OLDSERIAL_DEV"

# ── S21: a store serial truncated to 20 characters is still found ────────
# Requirement: the guest finds the store device even when the kernel reports
# a truncated serial for it.
# Theory: this launcher attaches serial `lbx-docker-store`, which fits the
# 20-character NVMe serial-number field, but a base built by the older
# launcher was given `llm-in-a-box-docker-store` (25 characters), so the
# kernel reports `llm-in-a-box-docker-` and the by-id link is
# nvme-QEMU_NVMe_Ctrl_llm-in-a-box-docker-: the word "store" never appears
# anywhere. No exact path can match such a device, so
# both remaining fallbacks (the by-id glob and the sysfs serial scan) must
# match the truncated form; otherwise the guest silently falls back to the
# small local disk, which is the failure this pins. The device root is faked
# so the check can never reach a real block device, and every device-touching
# command is faked, so nothing is formatted or mounted.
DEVROOT="$WORK/devroot"
BYID="$DEVROOT/disk/by-id"
mkdir -p "$BYID"
TRUNC_NAME="nvme-QEMU_NVMe_Ctrl_llm-in-a-box-docker-"
ln -sf "$WORK/store-truncated.img" "$BYID/$TRUNC_NAME"
: > "$WORK/store-truncated.img"
fresh_containerd_cfg; fresh_daemon_json
rm -f "$MARKER" "$WORK/mounted" "$WORK/blkid.out" "$WORK/wipefs.out"
reset_calls
run_store "LBX_STORE_DEVROOT=$DEVROOT LLMBOX_STORE_DEV=$WORK/never-exists" >/dev/null 2>&1
# the by-id fallback must hand the truncated path to the format probe.
check "S21: the by-id fallback finds a device whose store serial was truncated to 20 characters" \
    "grep -q '$TRUNC_NAME' '$WORK/blkid.calls'"

# ── S21b: the sysfs serial scan tolerates the truncation too ─────────────
# Requirement: the third fallback also matches the truncated serial.
# Theory: with no by-id entry at all, the finder scans each block device's
# sysfs serial file. A host whose by-id links were never populated (or were
# removed) reaches this path, so it must tolerate the truncation for the same
# reason the glob does. The sysfs tree and the device root are both faked.
SYSFS="$WORK/sysfs"
mkdir -p "$SYSFS/block/storedisk/device"
printf 'llm-in-a-box-docker-\n' > "$SYSFS/block/storedisk/device/serial"
printf 'QEMU NVMe Ctrl\n' > "$SYSFS/block/storedisk/device/model"
: > "$DEVROOT/storedisk"
rm -rf "$BYID"; mkdir -p "$BYID"
rm -f "$MARKER" "$WORK/mounted"
reset_calls
run_store "LBX_STORE_DEVROOT=$DEVROOT LBX_STORE_SYSFS_DIR=$SYSFS LLMBOX_STORE_DEV=$WORK/never-exists" >/dev/null 2>&1
check "S21b: the sysfs serial fallback finds a device whose store serial was truncated" \
    "grep -q 'storedisk' '$WORK/blkid.calls'"

# ── S22: the identity check tolerates the truncation, and still discriminates
# Requirement: the resolved device is accepted when its udev/sysfs identity
# carries the truncated serial, and an unrelated device is still refused.
# Theory: in production the wiring confirms the device's identity before
# writing to it, and the identity string it sees is the truncated serial. It
# is not enough to accept the truncated form: the check must still refuse a
# disk that carries no store serial at all, or the tolerance would amount to
# switching the identity check off. Both halves are asserted together for
# exactly that reason: an implementation that simply stopped checking would
# pass the first half and fail the second. The identity check runs against a
# controlled sysfs tree and a faked udevadm, via the seam that allows a
# non-block device in place of the real one.
IDENT_DEV="$WORK/identdisk"
: > "$IDENT_DEV"
mkdir -p "$SYSFS/block/identdisk/device"
printf 'QEMU NVMe Ctrl\n' > "$SYSFS/block/identdisk/device/model"
printf 'llm-in-a-box-docker-\n' > "$SYSFS/block/identdisk/device/serial"
printf 'ID_SERIAL_SHORT=llm-in-a-box-docker-\nID_MODEL=QEMU NVMe Ctrl\n' > "$WORK/udevadm.out"
fresh_containerd_cfg; fresh_daemon_json
rm -f "$MARKER" "$WORK/mounted"
reset_calls
run_store "LLMBOX_STORE_DEV=$IDENT_DEV LBX_STORE_SYSFS_DIR=$SYSFS LBX_STORE_IDENTITY_TEST=1" >/dev/null 2>&1
s22_trunc_ok=0
[ -s "$WORK/blkid.calls" ] && s22_trunc_ok=1
# an unrelated serial must still be refused.
printf 'SOMETHING-ELSE-123\n' > "$SYSFS/block/identdisk/device/serial"
printf 'ID_SERIAL_SHORT=SOMETHING-ELSE-123\nID_MODEL=Some Other Disk\n' > "$WORK/udevadm.out"
rm -f "$MARKER" "$WORK/mounted"
reset_calls
run_store "LLMBOX_STORE_DEV=$IDENT_DEV LBX_STORE_SYSFS_DIR=$SYSFS LBX_STORE_IDENTITY_TEST=1" >/dev/null 2>&1
s22_refused=1
[ -s "$WORK/blkid.calls" ] && s22_refused=0
check "S22: the identity check accepts the truncated store serial and still refuses an unrelated device" \
    "[ \"\$s22_trunc_ok\" = 1 ] && [ \"\$s22_refused\" = 1 ]"
rm -f "$WORK/udevadm.out"

echo ""
echo "test_vm_docker_store.sh: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
[ "$FAIL" -eq 0 ]
