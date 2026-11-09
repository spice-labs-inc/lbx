#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# entrypoint.sh — llm-in-a-box container entrypoint
#
# Responsibilities:
#   1. Remap the default "agent" user to match the host UID/GID
#   2. Start dockerd (DinD)
#   3. Drop privileges and exec the requested command as that user
#
# Idempotency (important): this script runs on EVERY container start, but
# some of its steps can only be performed once — the login rename in
# particular. After the first start the login is already $HOST_USER and no
# "agent" user remains, so the rename is guarded on the target user's
# absence and a restart becomes a no-op. Without that guard a restart tries
# to rename a user that is not there, and logs a misleading "usermod -l
# failed" line on every start (the box still works, because the block's
# final existence check passes anyway — which is why the noise is easy to
# overlook). Every step added here must be safe to run on a start where the
# previous start already completed; tests/test_llm_in_a_box_sysbox.sh SYS6
# and SYS7 pin that property.
#
# Environment:
#   LBX_RUNTIME_TYPE     — sysbox or docker (set at build time)
#   HOST_USER         — host username to adopt
#   HOST_UID          — host UID to remap to
#   HOST_GID          — host GID to remap to
# ---------------------------------------------------------------------------

# Don't use set -e — we need resilience to individual commands failing
# (e.g., getent on nonexistent users, groupmod no-ops, etc.)
set -uo pipefail

# ── 1. Remap user ──────────────────────────────────────────────────────────
TARGET_USER="${HOST_USER:-agent}"
TARGET_UID="${HOST_UID:-1000}"
TARGET_GID="${HOST_GID:-1000}"

# Adjust the group first
current_gid=$(id -g agent 2>/dev/null || echo "")
if [ -n "$current_gid" ] && [ "$current_gid" != "$TARGET_GID" ]; then
    existing_group=$(getent group "$TARGET_GID" 2>/dev/null | cut -d: -f1 || true)
    if [ -n "$existing_group" ] && [ "$existing_group" != "agent" ]; then
        groupdel "$existing_group" 2>/dev/null || true
    fi
    groupmod -g "$TARGET_GID" agent 2>/dev/null || true
fi

# Adjust UID
current_uid=$(id -u agent 2>/dev/null || echo "")
if [ -n "$current_uid" ] && [ "$current_uid" != "$TARGET_UID" ]; then
    existing_user=$(getent passwd "$TARGET_UID" 2>/dev/null | cut -d: -f1 || true)
    if [ -n "$existing_user" ] && [ "$existing_user" != "agent" ]; then
        userdel "$existing_user" 2>/dev/null || true
    fi
    usermod -u "$TARGET_UID" agent 2>/dev/null || true
fi

# Rename the login to match the host username (home dir stays /home/agent).
#
# IDEMPOTENT (required): this block runs on EVERY container start, but the
# rename can only be done once — after the first start the login is already
# TARGET_USER and no "agent" user exists. Guarding on the target user's
# absence is what makes a restart a no-op. Without the guard, a restart
# tries to rename a user that is not there: usermod fails, the sed fallback
# matches nothing, and the container logs a misleading
# "usermod -l failed, falling back to sed rename" on every start after the
# first (the box still works, because the existence check below passes
# anyway — which is exactly why the noise is easy to overlook).
if [ "$TARGET_USER" != "agent" ] && ! id "$TARGET_USER" >/dev/null 2>&1; then
    # Attempt usermod -l first; if it fails (common under sysbox user namespaces),
    # fall back to directly editing /etc/passwd.
    if ! usermod -l "$TARGET_USER" agent 2>/dev/null; then
        echo "entrypoint: usermod -l failed, falling back to sed rename" >&2
        sed -i "s/^agent:/${TARGET_USER}:/" /etc/passwd
    fi
    # Verify the target user now exists; if neither method worked, create from scratch
    if ! id "$TARGET_USER" >/dev/null 2>&1; then
        echo "entrypoint: rename failed, creating user $TARGET_USER directly" >&2
        useradd -o -u "$TARGET_UID" -g "$TARGET_GID" -d /home/agent -s /bin/bash "$TARGET_USER" 2>/dev/null || true
    fi
fi

# The sudoers entry is written on every start (not only when the rename
# ran), so it is repaired if it was lost, and its content is deterministic
# because the write is unconditional.
if [ "$TARGET_USER" != "agent" ]; then
    echo "${TARGET_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/agent
fi

# Ensure the user is in the docker group. The remap above can delete a
# group whose gid collides with TARGET_GID (2026-09-02 e2e bug: the image's
# docker group gid collided with the nested seed's target gid, so groupdel
# removed docker and docker.socket failed with 216/GROUP on the next
# boot). Recreate the group rather than skip.
# LBX_NO_INNER_DOCKER is the name; LLMBOX_NO_INNER_DOCKER is the spelling an
# earlier launcher passed and is still honored (LBX_ wins when both are set).
if [ "${LBX_NO_INNER_DOCKER:-${LLMBOX_NO_INNER_DOCKER:-}}" = "1" ]; then
    # Run box of an unattended run: no inner docker and no sudo. The image
    # puts the box user in the docker group and gives it passwordless sudo;
    # take both away (no-new-privileges already blocks setuid, this removes
    # the grant itself).
    gpasswd -d "$TARGET_USER" docker >/dev/null 2>&1 || true
    rm -f /etc/sudoers.d/agent
else
    getent group docker >/dev/null 2>&1 || groupadd -r docker 2>/dev/null || true
    usermod -aG docker "$TARGET_USER" 2>/dev/null || true
fi

# ── VM bridge networking (sysbox bridged networking, ADR-006) ──────────────
# Only when /dev/net/tun is present (lbx auto-grants --device
# /dev/net/tun --cap-add NET_ADMIN for sysbox). Capability-gated
# (CAP_NET_ADMIN + a world-writable /dev/net/tun), not host-GID-gated like
# the disproven /dev/kvm attempt in ADR-005 — this works under sysbox's
# user-namespace model. Idempotent: safe to run on every container start.
if [ -e /dev/net/tun ]; then
    if ! ip link show br-vm0 >/dev/null 2>&1; then
        ip link add br-vm0 type bridge 2>/dev/null || true
        ip addr add 192.168.200.1/24 dev br-vm0 2>/dev/null || true
        ip link set br-vm0 up 2>/dev/null || true
    fi
    echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true

    DEFAULT_IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    if [ -n "$DEFAULT_IFACE" ]; then
        iptables -t nat -C POSTROUTING -s 192.168.200.0/24 -o "$DEFAULT_IFACE" -j MASQUERADE 2>/dev/null \
            || iptables -t nat -A POSTROUTING -s 192.168.200.0/24 -o "$DEFAULT_IFACE" -j MASQUERADE 2>/dev/null || true

        # --vm-web-port <hostport>:<vmport> (lbx): DNAT
        # host-reachable traffic arriving on the container's default
        # interface into the VM's static IP, so a web server in the VM is
        # reachable from outside the container, not just from inside its
        # own network namespace.
        if [ -n "${VM_WEB_PORT:-}" ]; then
            web_hostport="${VM_WEB_PORT%%:*}"
            web_vmport="${VM_WEB_PORT##*:}"
            if [ -n "$web_hostport" ] && [ -n "$web_vmport" ]; then
                iptables -t nat -C PREROUTING -i "$DEFAULT_IFACE" -p tcp --dport "$web_hostport" \
                    -j DNAT --to-destination "192.168.200.2:${web_vmport}" 2>/dev/null \
                    || iptables -t nat -A PREROUTING -i "$DEFAULT_IFACE" -p tcp --dport "$web_hostport" \
                        -j DNAT --to-destination "192.168.200.2:${web_vmport}" 2>/dev/null || true
                iptables -C FORWARD -p tcp -d 192.168.200.2 --dport "$web_vmport" -j ACCEPT 2>/dev/null \
                    || iptables -A FORWARD -p tcp -d 192.168.200.2 --dport "$web_vmport" -j ACCEPT 2>/dev/null || true
            fi
        fi
    fi
fi

# Final sanity check: abort early with a clear message if the target user
# still does not exist, rather than letting gosu fail cryptically later.
if ! id "$TARGET_USER" >/dev/null 2>&1; then
    echo "FATAL: could not create or rename user '$TARGET_USER' — check entrypoint logs" >&2
    echo "FATAL: /etc/passwd contents:" >&2
    cat /etc/passwd >&2
    exit 1
fi

# Signal that user setup is complete — attach_session waits for this
touch /tmp/.user-ready

# ── Netwall proxy plumbing (2026-09-03) ─────────────────────────────────────
# The host points tools at the per-session relay via HTTP_PROXY/HTTPS_PROXY
# (docker -e). Persist them so interactive shells, apt, the JVM toolchain,
# and the inner dockerd all use the door. Runs before dockerd starts so
# daemon.json takes effect on first start.
if [ -n "${HTTP_PROXY:-}" ]; then
    cat > /etc/profile.d/box-proxy.sh <<EOF
export HTTP_PROXY="${HTTP_PROXY}"
export HTTPS_PROXY="${HTTPS_PROXY}"
export http_proxy="${HTTP_PROXY}"
export https_proxy="${HTTPS_PROXY}"
export NO_PROXY="${NO_PROXY:-localhost,127.0.0.1}"
export no_proxy="\${NO_PROXY}"
EOF
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
    # Interactive non-login shells (docker exec ... bash) read ~/.bashrc,
    # not /etc/profile.d — persist there too (idempotent).
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
fi

# Fix ownership of home directory if needed (replaces one-time stamp approach
# to handle restarts where UID/GID may have changed or chown was incomplete)
CURRENT_OWNER=$(stat -c '%u:%g' /home/agent 2>/dev/null || echo "")
if [ "$CURRENT_OWNER" != "${TARGET_UID}:${TARGET_GID}" ]; then
    chown -R "${TARGET_UID}:${TARGET_GID}" /home/agent 2>/dev/null || true
fi

# ── 2. Start dockerd (DinD) ────────────────────────────────────────────────
# A run box has no inner docker (it runs without the privileges dockerd
# needs), so it skips this section instead of waiting 30 s for a daemon
# that cannot start.
# Clean stale PID files from previous unclean shutdown
rm -f /var/run/docker.pid /var/run/docker/containerd/containerd.pid 2>/dev/null || true
if [ "${LBX_NO_INNER_DOCKER:-${LLMBOX_NO_INNER_DOCKER:-}}" != "1" ] && ! pgrep -x dockerd > /dev/null 2>&1; then
    nohup dockerd -G docker --log-level=warn > /var/log/dockerd.log 2>&1 &
    disown
    # Wait for dockerd to be ready (up to 30s)
    for i in $(seq 1 30); do
        if docker info >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done
fi

# ── 3. Exec as the target user ─────────────────────────────────────────────
export HOME=/home/agent
cd /data 2>/dev/null || true
# A run box's command may start only now: the user remap, the ownership fix
# and the proxy setup above are all done. lbx --run waits for this marker.
if [ "${LBX_NO_INNER_DOCKER:-${LLMBOX_NO_INNER_DOCKER:-}}" = "1" ]; then
    touch /tmp/.run-ready
fi
exec gosu "$TARGET_USER" "$@"
