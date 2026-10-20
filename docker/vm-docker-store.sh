#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# vm-docker-store.sh — guest wiring for the host-backed Docker store image.
#
# WHAT: finds the NVMe device the launcher attached (serial
# `lbx-docker-store`; a base built by the older launcher carries the
# 25-character `llm-in-a-box-docker-store`, which the kernel truncates to
# `llm-in-a-box-docker-`, see the truncation note at the seams below), and
# formats it exactly once (only when it carries no
# filesystem at all), mounts it at /srv/docker-store, and points containerd's
# root and Docker's data-root inside. The image is a real ext4 filesystem, so
# container file ownership and overlayfs work — unlike the 9p share it
# replaces (containerd's unpacker cannot chown/Lchown under
# security_model=none, and mapped-* breaks d_type). The image lives on the
# host, OUTSIDE every guest export; the guest only sees it as a block device.
#
# SAFETY:
#   - never formats a device that carries ANY signature (blkid exit 2 with
#     empty output AND a clean wipefs -n are both required);
#   - never mounts the guest root device, a non-block device, or a device
#     that does not carry the expected serial;
#   - never overrides a genuine user-set containerd root, Docker data-root,
#     storage driver, or snapshotter; only the exact values this project's
#     earlier wiring wrote are migrated away;
#   - every blocking operation (device probe, mkfs, mount, e2fsck) runs under
#     `timeout`, and the device wait is bounded by LLMBOX_STORE_WAIT_ITERS, so a
#     missing device can never hang the boot;
#   - on any fallback the store roots are removed (daemons return to local
#     defaults) and /run/llm-in-a-box-store-fallback is created so the
#     degraded boot is visible; a successful run clears it.
#
# DEADLOCK FIX (F1): the setup unit is ordered Before=containerd/docker, so
# every daemon action taken here is `systemctl --no-block` — a synchronous
# start/restart would deadlock the unit against its own ordering.
#
# README: first boot plants a first-reader message in the host0 store
# directory, only when /data is mounted, and never clobbers an existing file.
#
# Usage: sourced by vm-setup.sh (VM guest first-boot service) and runnable
# directly for tests. All paths and commands are environment-overridable
# (test seams):
#   LBX_STORE_DEV, LBX_STORE_MNT, LBX_STORE_DOCKER_ETC,
#   LBX_STORE_CONTAINERD_CFG, LBX_STORE_MSG, LBX_STORE_DIR,
#   LBX_STORE_WAIT_ITERS, LBX_STORE_DEV_TEST, LBX_STORE_FALLBACK_MARKER,
#   LBX_STORE_SYSTEMCTL, LBX_STORE_TIMEOUT, LBX_STORE_DEVROOT,
#   LBX_STORE_SYSFS_DIR, LBX_STORE_IDENTITY_TEST
# Test: tests/test_vm_docker_store.sh
# ---------------------------------------------------------------------------

# ── Configuration seams ───────────────────────────────────────────────────
# The device is the NVMe by-id path derived from serial=lbx-docker-store (an
# NVMe serial is at most 20 bytes; the older 25-byte name arrives truncated).
# Each knob is LBX_STORE_<name>; the LLMBOX_STORE_<name> spelling an earlier
# launcher used is still read (LBX_ wins when both are set). The variables
# keep their LLMBOX_ names inside this script.
#
# THE OLDER SERIAL IS TRUNCATED, SO ITS EXACT PATH CANNOT EXIST. The older
# launcher requested `llm-in-a-box-docker-store` (25 characters), but the NVMe
# serial-number field holds 20, so the kernel reports `llm-in-a-box-docker-`
# and the by-id link is nvme-QEMU_NVMe_Ctrl_llm-in-a-box-docker-. The word
# "store" survives nowhere in that device's identity. Every match below
# therefore uses the PREFIX `llm-in-a-box-docker` for that serial rather than
# the full name: matching the full name rejects the real device, and the guest
# silently falls back to its small local disk, which is the whole failure this
# file exists to prevent.
LLMBOX_STORE_DEV="${LBX_STORE_DEV:-${LLMBOX_STORE_DEV:-/dev/disk/by-id/nvme-QEMU_NVMe_Ctrl_lbx-docker-store}}"
# Where the device nodes and the by-id directory live. Overridable so the
# finder's fallbacks can be exercised without reaching a real block device.
LLMBOX_STORE_DEVROOT="${LBX_STORE_DEVROOT:-${LLMBOX_STORE_DEVROOT:-/dev}}"
# Where block devices' sysfs attributes live: the serial/model the finder
# scans and the identity check reads. Overridable for the same reason.
LLMBOX_STORE_SYSFS_DIR="${LBX_STORE_SYSFS_DIR:-${LLMBOX_STORE_SYSFS_DIR:-/sys}}"
# Mount point of the store filesystem inside the guest.
LLMBOX_STORE_MNT="${LBX_STORE_MNT:-${LLMBOX_STORE_MNT:-/srv/docker-store}}"
LLMBOX_STORE_DOCKER_ETC="${LBX_STORE_DOCKER_ETC:-${LLMBOX_STORE_DOCKER_ETC:-/etc/docker}}"
LLMBOX_STORE_CONTAINERD_CFG="${LBX_STORE_CONTAINERD_CFG:-${LLMBOX_STORE_CONTAINERD_CFG:-/etc/containerd/config.toml}}"
# First-reader message source (baked image copy first, live repo as fallback
# for pre-rebuild guests, then silently skip).
LLMBOX_STORE_MSG="${LBX_STORE_MSG:-${LLMBOX_STORE_MSG:-/usr/local/sbin/state-dir-message.md}}"
# The host0 share store directory: README planting target and the historical
# path the legacy migration recognizes.
LLMBOX_STORE_DIR="${LBX_STORE_DIR:-${LLMBOX_STORE_DIR:-/data/vms_and_docker_from_llm_box}}"
# Bounded device wait: at most this many 1-second sleeps (never an unbounded
# poll — the boot must not hang on a missing device).
LLMBOX_STORE_WAIT_ITERS="${LBX_STORE_WAIT_ITERS:-${LLMBOX_STORE_WAIT_ITERS:-30}}"
# Test seam: "1" accepts a regular file in place of a block device and skips
# the udev/sysfs serial confirmation. Production never sets this.
LLMBOX_STORE_DEV_TEST="${LBX_STORE_DEV_TEST:-${LLMBOX_STORE_DEV_TEST:-0}}"
# Test seam: "1" runs the udev/sysfs identity confirmation even when
# LBX_STORE_DEV_TEST has relaxed the block-device requirement, so the
# matching logic itself can be tested rather than bypassed. Production never
# sets this.
LLMBOX_STORE_IDENTITY_TEST="${LBX_STORE_IDENTITY_TEST:-${LLMBOX_STORE_IDENTITY_TEST:-0}}"
LLMBOX_STORE_FALLBACK_MARKER="${LBX_STORE_FALLBACK_MARKER:-${LLMBOX_STORE_FALLBACK_MARKER:-/run/llm-in-a-box-store-fallback}}"
# systemd action seam; resolved with `command -v` so an absent systemctl is a
# clean no-op (configs are still written).
LLMBOX_STORE_SYSTEMCTL="${LBX_STORE_SYSTEMCTL:-${LLMBOX_STORE_SYSTEMCTL:-systemctl}}"
# Per-operation timeout (seconds) for the blocking external calls.
LLMBOX_STORE_TIMEOUT="${LBX_STORE_TIMEOUT:-${LLMBOX_STORE_TIMEOUT:-60}}"

# Global change flag: set to 1 by the wiring/revert helpers when a config
# file was modified, so the restart block knows whether to queue daemon
# actions. Reset at the start of every run.
VM_STORE_CHANGED=0

vm_store_log() { echo "vm-docker-store: $*"; }

# Run a blocking external command under the configured timeout. The tests
# assert blkid/mkfs/mount/e2fsck all appear in the timeout log, so every one
# of them must go through here.
vm_store_timeout() {
    timeout "$LLMBOX_STORE_TIMEOUT" "$@"
}

# Locate the store device. Loads the nvme module, waits up to
# LLMBOX_STORE_WAIT_ITERS seconds for the configured path to appear, then tries
# a by-id glob and a sysfs serial scan before giving up. Prints the path and
# returns 0 when found; returns 1 when absent.
vm_store_find_device() {
    local dev="$LLMBOX_STORE_DEV"
    modprobe nvme 2>/dev/null || true

    local iters="$LLMBOX_STORE_WAIT_ITERS"
    case "$iters" in ''|*[!0-9]*) iters=30 ;; esac
    local i=0
    while [ "$i" -lt "$iters" ]; do
        [ -e "$dev" ] && break
        sleep 1
        i=$((i + 1))
    done

    if [ ! -e "$dev" ]; then
        # by-id glob fallback: the serial is embedded in the name. The pattern
        # matches the truncated serial (see the truncation note above), so it
        # accepts both the truncated `...docker-` and a full `...docker-store`.
        local cand
        for cand in "$LLMBOX_STORE_DEVROOT"/disk/by-id/nvme-*lbx-docker-store* \
                    "$LLMBOX_STORE_DEVROOT"/disk/by-id/nvme-*llm-in-a-box-docker* \
                    "$LLMBOX_STORE_DEVROOT"/disk/by-id/nvme-*boc-docker-store*; do
            if [ -e "$cand" ]; then
                dev="$cand"
                break
            fi
        done
    fi
    if [ ! -e "$dev" ]; then
        # sysfs serial fallback: find the block device whose serial matches.
        local serial_file serial block
        for serial_file in "$LLMBOX_STORE_SYSFS_DIR"/block/*/device/serial; do
            [ -r "$serial_file" ] || continue
            serial=$(cat "$serial_file" 2>/dev/null || true)
            case "$serial" in
                *lbx-docker-store*|*llm-in-a-box-docker*|*boc-docker-store*)
                    block=$(basename "$(dirname "$(dirname "$serial_file")")")
                    if [ -e "$LLMBOX_STORE_DEVROOT/$block" ]; then
                        dev="$LLMBOX_STORE_DEVROOT/$block"
                        break
                    fi
                    ;;
            esac
        done
    fi

    if [ ! -e "$dev" ]; then
        return 1
    fi
    printf '%s\n' "$dev"
    return 0
}

# Validate the resolved device before anything writes to it. In production
# mode the path must resolve to a block device whose udev/sysfs identity
# carries a box store serial (lbx-docker-store, or the older truncated
# llm-in-a-box-docker- or boc-docker-store), and it must never be the guest
# root device. LBX_STORE_DEV_TEST=1 relaxes the block-device requirement,
# and LBX_STORE_IDENTITY_TEST=1 keeps the identity
# confirmation running anyway so the matching logic is testable (both are test
# seams only); the root-device guard always applies.
vm_store_validate_device() {
    local dev="$1"
    local real
    real=$(realpath "$dev" 2>/dev/null || true)
    [ -n "$real" ] || real="$dev"

    if [ "$LLMBOX_STORE_DEV_TEST" != "1" ] && [ ! -b "$real" ]; then
        vm_store_log "device $dev is not a block device; refusing"
        return 1
    fi
    # The block-device requirement and the identity confirmation are separate
    # concerns with separate seams: LLMBOX_STORE_DEV_TEST=1 stands a regular
    # file in for the device, and LLMBOX_STORE_IDENTITY_TEST=1 keeps the
    # identity confirmation running anyway so the matching logic is exercised
    # rather than bypassed. Production sets neither.
    if [ "$LLMBOX_STORE_DEV_TEST" != "1" ] || [ "$LLMBOX_STORE_IDENTITY_TEST" = "1" ]; then
        # The identity check deliberately does NOT match on $dev: the default
        # by-id path always contains the serial, so matching it would let a
        # spoofed symlink at that path pass. Only the resolved device, the
        # udev properties, and the sysfs serial/model count.
        local udev_info sysname serial model serial_file model_file
        udev_info=""
        if command -v udevadm >/dev/null 2>&1; then
            udev_info=$(timeout "$LLMBOX_STORE_TIMEOUT" udevadm info --query=property --name "$real" 2>/dev/null || true)
        fi
        sysname=$(basename "$real")
        serial=""
        model=""
        serial_file="$LLMBOX_STORE_SYSFS_DIR/block/$sysname/device/serial"
        model_file="$LLMBOX_STORE_SYSFS_DIR/block/$sysname/device/model"
        [ -r "$serial_file" ] && serial=$(cat "$serial_file" 2>/dev/null || true)
        [ -r "$model_file" ] && model=$(cat "$model_file" 2>/dev/null || true)
        # The prefix, not the full serial: see the truncation note at the top.
        case "$real $udev_info $serial $model" in
            *lbx-docker-store*|*llm-in-a-box-docker*|*boc-docker-store*) ;;
            *)
                vm_store_log "device $dev does not carry a box store serial (lbx-docker-store, or the older llm-in-a-box-docker- / boc-docker-store); refusing"
                return 1
                ;;
        esac
    fi

    # Never the root device: formatting it would destroy the running VM.
    local root_src root_real
    root_src=$(findmnt -no SOURCE / 2>/dev/null || true)
    if [ -n "$root_src" ]; then
        root_real=$(realpath -m "$root_src" 2>/dev/null || true)
        if [ "$real" = "$root_real" ]; then
            vm_store_log "device $dev is the root device; refusing"
            return 1
        fi
    fi
    return 0
}

# Decide what to do with the device's filesystem. Prints "format" when the
# device carries no filesystem at all, "ext4" when it carries an ext4
# filesystem, and prints nothing (return 1) when it must not be touched.
#
# Truth table (never format anything with a signature):
#   blkid exit 2 + empty  AND wipefs -n exit 0 + empty  -> format
#   blkid exit 0 + "ext4"                               -> use
#   anything else (any signature, any other exit, wipefs error/signature)
#                                                       -> refuse
vm_store_format_decision() {
    local dev="$1"
    local blkid_out blkid_rc wipefs_out wipefs_rc
    blkid_out=$(vm_store_timeout blkid -p -o value -s TYPE "$dev" 2>/dev/null) \
        && blkid_rc=0 || blkid_rc=$?
    if [ "$blkid_rc" -eq 2 ] && [ -z "$blkid_out" ]; then
        wipefs_out=$(vm_store_timeout wipefs -n "$dev" 2>/dev/null) \
            && wipefs_rc=0 || wipefs_rc=$?
        if [ "$wipefs_rc" -eq 0 ] && [ -z "$wipefs_out" ]; then
            printf '%s\n' "format"
            return 0
        fi
        return 1
    fi
    if [ "$blkid_rc" -eq 0 ] && [ "$blkid_out" = "ext4" ]; then
        printf '%s\n' "ext4"
        return 0
    fi
    return 1
}

# Mount the device at LLMBOX_STORE_MNT (idempotent). Returns 0 when the mount
# point is mounted afterwards (already mounted or mounted now), 1 otherwise.
# Sets VM_STORE_MOUNTED_THIS_RUN=1 only when this call performed the mount.
VM_STORE_MOUNTED_THIS_RUN=0
vm_store_mount_device() {
    local dev="$1"
    if mountpoint -q "$LLMBOX_STORE_MNT" 2>/dev/null; then
        return 0
    fi
    mkdir -p "$LLMBOX_STORE_MNT" 2>/dev/null || true
    if vm_store_timeout mount "$dev" "$LLMBOX_STORE_MNT" 2>/dev/null; then
        VM_STORE_MOUNTED_THIS_RUN=1
        return 0
    fi
    return 1
}

# Point containerd's root inside the mounted store. Only these transitions
# are made: no active root -> wire; the legacy value earlier wiring wrote ->
# migrate; the current value -> leave. A genuine user root is preserved. The
# stale top-level `snapshotter = "native"` line is removed (invalid for
# containerd) and no snapshotter key is ever written.
vm_store_wire_containerd() {
    local cfg="$LLMBOX_STORE_CONTAINERD_CFG"
    [ -f "$cfg" ] || return 0
    local current=""
    current=$(grep -E '^root = ' "$cfg" 2>/dev/null | head -1 || true)
    if [ -z "$current" ]; then
        if grep -q '^#root = ' "$cfg" 2>/dev/null; then
            sed -i "s|^#root = .*|root = \"$LLMBOX_STORE_MNT/containerd\"|" "$cfg"
            VM_STORE_CHANGED=1
        else
            printf 'root = "%s/containerd"\n' "$LLMBOX_STORE_MNT" >> "$cfg"
            VM_STORE_CHANGED=1
        fi
    elif [ "$current" = "root = \"$LLMBOX_STORE_MNT/containerd\"" ]; then
        : # already wired
    else
        case "$current" in
            "root = \"$LLMBOX_STORE_DIR/containerd\""|\
            "root = \"/data/vms_and_docker_from_llm_box/containerd\"")
                sed -i "s|^root = .*|root = \"$LLMBOX_STORE_MNT/containerd\"|" "$cfg"
                VM_STORE_CHANGED=1
                ;;
        esac
    fi
    if grep -q '^snapshotter = "native"$' "$cfg" 2>/dev/null; then
        sed -i '/^snapshotter = "native"$/d' "$cfg"
        VM_STORE_CHANGED=1
    fi
}

# Remove the store root this wiring wrote so containerd returns to its stock
# local default (fallback path).
vm_store_revert_containerd() {
    local cfg="$LLMBOX_STORE_CONTAINERD_CFG"
    [ -f "$cfg" ] || return 0
    if grep -Fq "root = \"$LLMBOX_STORE_MNT/containerd\"" "$cfg" 2>/dev/null; then
        sed -i "s|^root = \"$LLMBOX_STORE_MNT/containerd\"$|#root = \"/var/lib/containerd\"|" "$cfg"
        VM_STORE_CHANGED=1
    fi
}

# Merge Docker's data-root into daemon.json, preserving every other key
# (netwall proxies, genuine user values) exactly. Legacy data-root values
# written by earlier wiring are migrated; the vfs storage-driver sentinel is
# removed; storage-driver/snapshotter are never written. A malformed file is
# always backed up to daemon.json.bak before any rewrite; an earlier backup
# is overwritten so the backup always reflects the most recent malformed
# content (never silently discard user content).
vm_store_wire_daemon_json() {
    local path="$LLMBOX_STORE_DOCKER_ETC/daemon.json"
    mkdir -p "$LLMBOX_STORE_DOCKER_ETC" 2>/dev/null || true
    # Python exits 0 when it changed the file, 1 when it did not (so the
    # heredoc stays on a plain command line — no parse warning — and the
    # caller learns the outcome from the status).
    local rc=0
    python3 - "$path" "$LLMBOX_STORE_MNT" "$LLMBOX_STORE_DIR" "/data/vms_and_docker_from_llm_box" <<'PYEOF' || rc=$?
import json, os, shutil, sys

path, mnt, store_dir, legacy_dir = sys.argv[1:5]
current = mnt + "/docker"
legacy_values = {store_dir + "/docker", legacy_dir + "/docker"}

changed = False
try:
    with open(path) as f:
        cfg = json.load(f)
    if not isinstance(cfg, dict):
        raise ValueError("daemon.json is not a JSON object")
except FileNotFoundError:
    cfg = {}
    changed = True
except ValueError:
    backup = path + ".bak"
    try:
        shutil.copy2(path, backup)
    except OSError:
        pass
    cfg = {}
    changed = True

if "data-root" not in cfg:
    cfg["data-root"] = current
    changed = True
elif cfg["data-root"] in legacy_values:
    cfg["data-root"] = current
    changed = True

if cfg.get("storage-driver") == "vfs":
    del cfg["storage-driver"]
    changed = True

if changed:
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
    sys.exit(0)
sys.exit(1)
PYEOF
    if [ "$rc" -eq 0 ]; then
        VM_STORE_CHANGED=1
    fi
}

# Remove the store data-root this wiring wrote so Docker returns to its stock
# local default (fallback path); also drops the vfs sentinel. Malformed or
# non-object files are left untouched. Python exits 0 when it changed the
# file, 1 otherwise.
vm_store_revert_daemon_json() {
    local path="$LLMBOX_STORE_DOCKER_ETC/daemon.json"
    [ -f "$path" ] || return 0
    local rc=0
    python3 - "$path" "$LLMBOX_STORE_MNT" <<'PYEOF' || rc=$?
import json, sys

path, mnt = sys.argv[1:3]
current = mnt + "/docker"
try:
    with open(path) as f:
        cfg = json.load(f)
    if not isinstance(cfg, dict):
        sys.exit(1)
except (OSError, ValueError):
    sys.exit(1)

changed = False
if cfg.get("data-root") == current:
    del cfg["data-root"]
    changed = True
if cfg.get("storage-driver") == "vfs":
    del cfg["storage-driver"]
    changed = True

if changed:
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
    sys.exit(0)
sys.exit(1)
PYEOF
    if [ "$rc" -eq 0 ]; then
        VM_STORE_CHANGED=1
    fi
}

# Queue daemon actions. F1 contract: reset-failed first (escape the start
# limit), then every start/restart with --no-block so the oneshot setup unit
# never blocks on a job ordered after itself. Skips silently when the
# configured systemctl binary is absent — the configs are already written.
vm_store_restart_daemons() {
    local systemctl_bin="$LLMBOX_STORE_SYSTEMCTL"
    command -v "$systemctl_bin" >/dev/null 2>&1 || return 0
    "$systemctl_bin" reset-failed containerd docker docker.socket 2>/dev/null || true
    local containerd_state docker_state
    containerd_state=$("$systemctl_bin" is-active containerd 2>/dev/null || true)
    if [ "$containerd_state" = "active" ] || [ "$containerd_state" = "activating" ]; then
        "$systemctl_bin" --no-block restart containerd 2>/dev/null || true
    fi
    docker_state=$("$systemctl_bin" is-active docker 2>/dev/null || true)
    if [ "$docker_state" = "active" ] || [ "$docker_state" = "activating" ]; then
        "$systemctl_bin" --no-block restart docker 2>/dev/null || true
    else
        "$systemctl_bin" --no-block start docker 2>/dev/null || true
    fi
    vm_store_log "daemon actions queued (reset-failed + --no-block)"
}

# Degraded-boot path: remove our store roots (local defaults), make the
# fallback visible with the marker file, and queue a non-blocking restart
# when a config changed.
vm_store_fallback() {
    local reason="${1:-store unavailable}"
    vm_store_log "$reason; falling back to local Docker storage"
    vm_store_revert_containerd
    vm_store_revert_daemon_json
    mkdir -p "$(dirname "$LLMBOX_STORE_FALLBACK_MARKER")" 2>/dev/null || true
    touch "$LLMBOX_STORE_FALLBACK_MARKER" 2>/dev/null || true
    if [ "$VM_STORE_CHANGED" -eq 1 ]; then
        vm_store_restart_daemons
    fi
}

# ── Entry point ───────────────────────────────────────────────────────────
run_vm_docker_store() {
    VM_STORE_CHANGED=0
    VM_STORE_MOUNTED_THIS_RUN=0
    vm_store_log "starting (device=$LLMBOX_STORE_DEV, mount=$LLMBOX_STORE_MNT)"

    # First-reader message: plant once on the host0 share, only when /data is
    # mounted (a missing mount means writing there would hit the guest disk),
    # and never clobber a reader's edit. Failures are tolerated — the config
    # wiring below is the critical path.
    if mountpoint -q /data 2>/dev/null; then
        mkdir -p "$LLMBOX_STORE_DIR" 2>/dev/null || true
        if [ ! -e "$LLMBOX_STORE_DIR/README.md" ]; then
            local msg_src
            for msg_src in "$LLMBOX_STORE_MSG" "/data/docker/state-dir-message.md"; do
                if [ -f "$msg_src" ]; then
                    cp "$msg_src" "$LLMBOX_STORE_DIR/README.md" 2>/dev/null && break
                fi
            done
        fi
    else
        vm_store_log "/data not mounted; README not planted"
    fi

    # 1. Device discovery + validation.
    local dev=""
    dev=$(vm_store_find_device) || dev=""
    if [ -z "$dev" ] || ! vm_store_validate_device "$dev"; then
        vm_store_fallback "store device not found or invalid"
        vm_store_log "done (fallback)"
        return 0
    fi

    # 2. Format only a device with no filesystem at all.
    local fs=""
    fs=$(vm_store_format_decision "$dev") || fs=""
    if [ -z "$fs" ]; then
        vm_store_fallback "device $dev carries a signature this wiring must not touch (or the probe failed)"
        vm_store_log "done (fallback)"
        return 0
    fi
    if [ "$fs" = "format" ]; then
        if ! vm_store_timeout mkfs.ext4 -F -L lbx-docker-store "$dev" 2>/dev/null; then
            vm_store_fallback "mkfs.ext4 failed on $dev"
            vm_store_log "done (fallback)"
            return 0
        fi
        fs="ext4"
    fi

    # 3. Mount (idempotent), with one bounded e2fsck repair attempt for a
    # dirty ext4 filesystem before giving up.
    if ! vm_store_mount_device "$dev"; then
        if [ "$fs" = "ext4" ]; then
            vm_store_timeout e2fsck -p "$dev" 2>/dev/null || true
            if ! vm_store_mount_device "$dev"; then
                vm_store_fallback "the store filesystem could not be mounted after e2fsck"
                vm_store_log "done (fallback)"
                return 0
            fi
        else
            vm_store_fallback "the store filesystem could not be mounted"
            vm_store_log "done (fallback)"
            return 0
        fi
    fi

    # 4. Wire both daemons inside the mounted store.
    vm_store_wire_containerd
    vm_store_wire_daemon_json

    # Success: clear any stale fallback marker from an earlier boot.
    rm -f "$LLMBOX_STORE_FALLBACK_MARKER" 2>/dev/null || true

    if [ "$VM_STORE_CHANGED" -eq 1 ] || [ "$VM_STORE_MOUNTED_THIS_RUN" -eq 1 ]; then
        vm_store_restart_daemons
    fi
    vm_store_log "done (device=$dev, mounted=$LLMBOX_STORE_MNT, changed=$VM_STORE_CHANGED)"
    return 0
}
