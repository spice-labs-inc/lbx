#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# vm-setup.sh — in-guest setup service for the llm-in-a-box VM runtime
# (RUNTIME_TYPE=vm). Runs once per boot via llm-in-a-box-setup.service.
#
# Responsibilities (idempotent):
#   0. Load the seed (HOST_USER/UID/GID, GH_TOKEN, SSH_PUBKEY) — from the
#      9p "seed0" share (primary, same mechanism as /data) or qemu fw_cfg
#      (fallback)
#   1. Bring up user-net networking (10.0.2.15/24, gw 10.0.2.2)
#   2. Remap the "agent" user to the host user/UID/GID (same logic as
#      entrypoint.sh)
#   3. Mount the 9p project share (host0) at /data when present
#   4. Seed sshd authorized_keys + GH_TOKEN into the user's environment
#   5. Touch /run/llm-in-a-box-ready
#
# Every step logs to /dev/ttyS0 so the session console.log is self-diagnosing.
#
# Environment (from the seed): HOST_USER, HOST_UID, HOST_GID, GH_TOKEN,
# SSH_PUBKEY
# ---------------------------------------------------------------------------
set -uo pipefail

log() { echo "vm-setup: $*" > /dev/ttyS0 2>/dev/null || echo "vm-setup: $*"; }

SEED_FILE=""
FWCFG_SEED=/sys/firmware/qemu_fw_cfg/by_name/opt/llm-in-a-box/seed/raw
SEED9P=/run/llm-in-a-box-seed/seed.fw_cfg
READY=/run/llm-in-a-box-ready

log "starting"

# ── 0. Seed: 9p share first, fw_cfg fallback ─────────────────────────────
modprobe 9pnet_virtio 2>/dev/null || true
mkdir -p /run/llm-in-a-box-seed
if mount -t 9p -o trans=virtio,version=9p2000.L,msize=512k seed0 /run/llm-in-a-box-seed 2>/dev/null; then
    log "seed share: mounted seed0"
    [ -r "$SEED9P" ] && SEED_FILE="$SEED9P" && log "seed: read from 9p share"
fi
if [ -z "$SEED_FILE" ] && [ -r "$FWCFG_SEED" ]; then
    SEED_FILE="$FWCFG_SEED"
    log "seed: read from fw_cfg"
fi
if [ -n "$SEED_FILE" ]; then
    if . "$SEED_FILE" 2>/dev/null; then
        log "seed: sourced ok"
    else
        log "seed: SOURCE FAILED ($SEED_FILE)"
    fi
else
    log "seed: NOT FOUND (no seed0 9p share, no fw_cfg)"
fi

TARGET_USER="${HOST_USER:-agent}"
TARGET_UID="${HOST_UID:-1000}"
TARGET_GID="${HOST_GID:-1000}"
log "target user: ${TARGET_USER} (${TARGET_UID}:${TARGET_GID})"

# ── Hostname: session name + sane /etc/hosts (fixes sudo's
# "unable to resolve host" warning and gives a nicer prompt) ───────────────
if [ -n "${HOSTNAME:-}" ]; then
    hostnamectl set-hostname "$HOSTNAME" 2>/dev/null || true
fi
cat > /etc/hosts <<'EOF'
127.0.0.1 localhost
::1 localhost ip6-localhost ip6-loopback
EOF
if [ -n "${HOSTNAME:-}" ]; then
    echo "127.0.1.1 ${HOSTNAME}" >> /etc/hosts
fi

# ── 1. Networking (user-net static config; idempotent) ─────────────────────
# The NIC may be eth0 or a predictable name (enp0s3); pick the first non-lo
# interface regardless, then assign the qemu user-net static IP.
modprobe virtio_net 2>/dev/null || true
ip link set lo up 2>/dev/null || true
IFACE="$(ls /sys/class/net 2>/dev/null | grep -v '^lo$' | head -1 || true)"
IFACE="${IFACE:-eth0}"
ip link set "$IFACE" up 2>/dev/null || true
if ! ip addr show "$IFACE" 2>/dev/null | grep -q "10.0.2.15"; then
    ip addr add 10.0.2.15/24 dev "$IFACE" 2>/dev/null || true
    ip route add default via 10.0.2.2 2>/dev/null || true
    log "net: assigned 10.0.2.15 on $IFACE"
else
    log "net: already configured on $IFACE"
fi
# DNS: qemu user-net serves DNS at 10.0.2.3. Write a plain resolv.conf
# (removing systemd-resolved's stub symlink) so glibc resolves directly —
# resolvectl alone proved unreliable for this static-config VM.
rm -f /etc/resolv.conf
printf 'nameserver 10.0.2.3\n' > /etc/resolv.conf
log "net: resolv.conf -> 10.0.2.3"
if ! getent hosts api.code.umans.ai >/dev/null 2>&1; then
    log "net: WARNING name resolution still failing"
fi

# ── 2. User remap (mirrors entrypoint.sh) ─────────────────────────────────
current_gid=$(id -g agent 2>/dev/null || echo "")
if [ -n "$current_gid" ] && [ "$current_gid" != "$TARGET_GID" ]; then
    existing_group=$(getent group "$TARGET_GID" 2>/dev/null | cut -d: -f1 || true)
    if [ -n "$existing_group" ] && [ "$existing_group" != "agent" ]; then
        groupdel "$existing_group" 2>/dev/null || true
    fi
    groupmod -g "$TARGET_GID" agent 2>/dev/null || true
fi

current_uid=$(id -u agent 2>/dev/null || echo "")
if [ -n "$current_uid" ] && [ "$current_uid" != "$TARGET_UID" ]; then
    existing_user=$(getent passwd "$TARGET_UID" 2>/dev/null | cut -d: -f1 || true)
    if [ -n "$existing_user" ] && [ "$existing_user" != "agent" ]; then
        userdel "$existing_user" 2>/dev/null || true
    fi
    usermod -u "$TARGET_UID" agent 2>/dev/null || true
fi

if [ "$TARGET_USER" != "agent" ]; then
    if ! usermod -l "$TARGET_USER" agent 2>/dev/null; then
        sed -i "s/^agent:/${TARGET_USER}:/" /etc/passwd
    fi
    if ! id "$TARGET_USER" >/dev/null 2>&1; then
        useradd -o -u "$TARGET_UID" -g "$TARGET_GID" -d /home/agent -s /bin/bash "$TARGET_USER" 2>/dev/null || true
    fi
fi

# The remap above can delete a group whose gid collides with TARGET_GID
# (2026-09-02 e2e bug: the image's docker group gid collided with the
# nested seed's target gid, so groupdel removed docker and docker.socket
# failed with 216/GROUP on the resumed boot — dockerd never started).
# Recreate the group so docker works on every boot.
getent group docker >/dev/null 2>&1 || groupadd -r docker 2>/dev/null || true
for u in agent "$TARGET_USER"; do
    [ "$u" = agent ] && [ "$TARGET_USER" != agent ] && continue
    usermod -aG docker "$u" 2>/dev/null || true
done
# passwordless sudo for the remapped user (mirrors entrypoint.sh) — the
# image's sudoers.d/agent rule names "agent", which no longer matches
# after the rename.
echo "${TARGET_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/agent
chmod 0440 /etc/sudoers.d/agent
if id "$TARGET_USER" >/dev/null 2>&1; then
    log "user: ${TARGET_USER} exists (passwordless sudo)"
else
    log "user: ${TARGET_USER} MISSING (remap failed)"
fi

# ── 3. 9p project share -> /data ───────────────────────────────────────────
if [ -d /sys/module/9pnet_virtio ] || modprobe 9pnet_virtio 2>/dev/null; then
    mkdir -p /data
    if ! mountpoint -q /data; then
        if mount -t 9p -o trans=virtio,version=9p2000.L,msize=512k host0 /data 2>/dev/null; then
            log "data: mounted host0 at /data"
        else
            log "data: 9p MOUNT FAILED"
        fi
    else
        log "data: already mounted"
    fi
else
    log "data: 9pnet_virtio unavailable"
fi

# ── 4. ssh keys + environment ──────────────────────────────────────────────
SSH_DIR=/home/agent/.ssh
mkdir -p "$SSH_DIR"
if [ -n "${SSH_PUBKEY:-}" ]; then
    printf '%s\n' "$SSH_PUBKEY" >> "$SSH_DIR/authorized_keys"
    sort -u "$SSH_DIR/authorized_keys" -o "$SSH_DIR/authorized_keys"
    log "keys: wrote ssh pubkeys to $SSH_DIR/authorized_keys"
else
    log "keys: none in seed (SSH_PUBKEY unset)"
fi
chown -R "$TARGET_UID":"$TARGET_GID" "$SSH_DIR" /home/agent 2>/dev/null || true
chmod 700 "$SSH_DIR" 2>/dev/null || true

if [ -n "${GH_TOKEN:-}" ]; then
    grep -q '^export GH_TOKEN=' /home/agent/.bashrc 2>/dev/null \
        || echo "export GH_TOKEN=${GH_TOKEN}" >> /home/agent/.bashrc
    log "env: GH_TOKEN exported in .bashrc"
fi

# ── Netwall proxy plumbing (2026-09-03): with restrict=on the guest has no
# route or DNS; the seed carries proxy settings pointing at the guestfwd
# door (10.0.2.100:3128). Persist them everywhere tools read: PAM
# (/etc/environment — ssh exec), login shells (profile.d), interactive
# shells (.bashrc), apt, and the inner dockerd (daemon.json + config.json;
# restart the daemon so pulls/builds use the door). Idempotent per boot.
if [ -n "${HTTP_PROXY:-}" ]; then
    if ! grep -q '^HTTP_PROXY=' /etc/environment 2>/dev/null; then
        cat >> /etc/environment <<EOF
HTTP_PROXY="${HTTP_PROXY}"
HTTPS_PROXY="${HTTPS_PROXY}"
http_proxy="${HTTP_PROXY}"
https_proxy="${HTTPS_PROXY}"
NO_PROXY="${NO_PROXY:-localhost,127.0.0.1}"
no_proxy="${NO_PROXY:-localhost,127.0.0.1}"
EOF
    fi
    cat > /etc/profile.d/box-proxy.sh <<EOF
export HTTP_PROXY="${HTTP_PROXY}"
export HTTPS_PROXY="${HTTPS_PROXY}"
export http_proxy="${HTTP_PROXY}"
export https_proxy="${HTTPS_PROXY}"
export NO_PROXY="${NO_PROXY:-localhost,127.0.0.1}"
export no_proxy="\${NO_PROXY}"
EOF
    if ! grep -q '^export HTTP_PROXY=' /home/agent/.bashrc 2>/dev/null; then
        cat >> /home/agent/.bashrc <<EOF
export HTTP_PROXY="${HTTP_PROXY}"
export HTTPS_PROXY="${HTTPS_PROXY}"
export http_proxy="${HTTP_PROXY}"
export https_proxy="${HTTPS_PROXY}"
export NO_PROXY="${NO_PROXY:-localhost,127.0.0.1}"
export no_proxy="\${NO_PROXY}"
EOF
    fi
    mkdir -p /etc/apt/apt.conf.d
    cat > /etc/apt/apt.conf.d/95box-proxy <<EOF
Acquire::http::Proxy "${HTTP_PROXY}";
Acquire::https::Proxy "${HTTPS_PROXY}";
EOF
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<EOF
{
  "proxies": {
    "http-proxy": "${HTTP_PROXY}",
    "https-proxy": "${HTTPS_PROXY}",
    "no-proxy": "${NO_PROXY:-localhost,127.0.0.1}"
  }
}
EOF
    mkdir -p /home/agent/.docker
    cat > /home/agent/.docker/config.json <<EOF
{
  "proxies": {
    "default": {
      "httpProxy": "${HTTP_PROXY}",
      "httpsProxy": "${HTTPS_PROXY}",
      "noProxy": "${NO_PROXY:-localhost,127.0.0.1}"
    }
  }
}
EOF
    chown -R "${TARGET_UID}:${TARGET_GID}" /home/agent/.docker 2>/dev/null || true
    if systemctl is-active docker >/dev/null 2>&1; then
        systemctl restart docker 2>/dev/null || true
        log "netwall: proxy configured; docker restarted"
    fi
fi

# ── 4b. Docker store on the attached host image ──────────────────────────
# Docker + containerd data lives in a single sparse ext4 image the host
# launcher creates and attaches to this VM as an NVMe device (serial
# lbx-docker-store; a base built by the older launcher carries the longer
# llm-in-a-box-docker-store, which the 20-character NVMe serial field cuts
# to llm-in-a-box-docker-, so the finder in vm-docker-store.sh matches that
# truncated prefix as well). This step finds that device, formats it only when it
# carries no filesystem, mounts it at /srv/docker-store, and points
# containerd's root and docker's data-root inside — so the small guest disk
# is never exhausted by image builds, and container file ownership works
# (unlike plain 9p files, which containerd cannot chown/Lchown). Every
# daemon action is --no-block: the setup unit is ordered Before=
# containerd/docker, so a synchronous start would deadlock it. The wiring is
# idempotent, migrates the values earlier versions of this project wrote,
# and plants the first-reader README on the host0 share. Placed AFTER the
# netwall daemon.json rewrite above so the merge preserves the proxies.
# See docker/vm-docker-store.sh (test: tests/test_vm_docker_store.sh).
if [ -f /usr/local/sbin/vm-docker-store.sh ]; then
    # shellcheck source=/dev/null
    . /usr/local/sbin/vm-docker-store.sh
    run_vm_docker_store
fi

# ── 5. Ready marker ────────────────────────────────────────────────────────
touch "$READY"
log "done"