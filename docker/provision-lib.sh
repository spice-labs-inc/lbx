#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# provision-lib.sh — shared helpers for docker/provision.d/*.sh.
#
# Sourced by every provisioning step, never executed directly. One step is one
# capability (a toolchain, the agents, the Pi plugins). The SAME steps run in
# both image modes:
#
#   fat image  (llm-in-a-box:<runtime>)       the build runs them, in order
#   slim image (llm-in-a-box:<runtime>-slim)  lbx-setup runs them on demand
#
# so "what is installed" has exactly one definition. Steps are idempotent:
# re-running one is a no-op when its result is already present.
#
# Environment: LBX_PROVISION_LIB is set by lbx-setup when it runs from a
# directory other than /opt/llm-in-a-box.
# ---------------------------------------------------------------------------
set -euo pipefail

PROVISION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The box user is uid 1000 — `agent` at build time, the host user's name after
# entrypoint.sh renames it. Never hardcode `agent`.
BOX_USER="${BOX_USER:-$(getent passwd 1000 | cut -d: -f1)}"
BOX_HOME="$(getent passwd "$BOX_USER" | cut -d: -f6)"
BOX_UID="$(id -u "$BOX_USER")"
BOX_GID="$(id -g "$BOX_USER")"
RUSTUP_HOME_DIR="$BOX_HOME/.rustup"
CARGO_HOME_DIR="$BOX_HOME/.cargo"
SYS_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# The runtime this box runs (vm | sysbox | docker). Prefer the env, fall back to
# the file the image records: a vm guest is the image's exported rootfs, which
# has no container ENV at all.
BOX_RUNTIME="${LBX_RUNTIME_TYPE:-${LLMBOX_RUNTIME_TYPE:-}}"
if [ -z "$BOX_RUNTIME" ] && [ -r /etc/llm-in-a-box/runtime ]; then
    BOX_RUNTIME="$(tr -d '\n' </etc/llm-in-a-box/runtime)"
fi
BOX_RUNTIME="${BOX_RUNTIME:-unknown}"
export BOX_RUNTIME

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

log() { printf 'provision: %s\n' "$*"; }

# Is a command available (to us, which is root at build time)?
have() { command -v "$1" >/dev/null 2>&1; }

apt_install() {
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
    $SUDO rm -rf /var/lib/apt/lists/*
}

# Install a LOCAL .deb with its dependencies. apt_install() clears the package
# lists (Dockerfile style), and a local package still needs them: without an
# update first, every dependency is reported as "not installable" even though
# it exists in the archive (measured with Google Chrome's .deb: libxfixes3,
# libxkbcommon0, libxrandr2, xdg-utils).
apt_install_deb() {
    local deb="$1"
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y "$deb"
    $SUDO rm -rf /var/lib/apt/lists/*
}

# Run a command as the box user, with that user's HOME and a PATH that
# contains the per-user toolchains (the image's ENV PATH is lost in the vm
# guest's non-interactive ssh sessions, so never rely on it).
as_box() {
    local home="$BOX_HOME"
    if [ "$(id -u)" -eq 0 ]; then
        gosu "$BOX_USER" env HOME="$home" \
            RUSTUP_HOME="$RUSTUP_HOME_DIR" CARGO_HOME="$CARGO_HOME_DIR" \
            BUN_INSTALL="$home/.bun" \
            PATH="$CARGO_HOME_DIR/bin:$home/.bun/bin:$SYS_PATH" "$@"
    else
        env HOME="$home" \
            RUSTUP_HOME="$RUSTUP_HOME_DIR" CARGO_HOME="$CARGO_HOME_DIR" \
            BUN_INSTALL="$home/.bun" \
            PATH="$CARGO_HOME_DIR/bin:$home/.bun/bin:$SYS_PATH" "$@"
    fi
}

# npm's global tree is /usr/local/lib/node_modules, so this needs root. HOME is
# ROOT's, not the box user's: a package's postinstall writes `$HOME/.local/…`
# regardless of the XDG variables — measured: opencode's install created
# /home/agent/.local/state/opencode owned by root, which the full image's old
# `chown -R /home/agent` had been masking. Nothing an install creates should
# land in the box user's home; the tools make their own config at first use.
# The box user still gets `pi install` (as_box) for everything that belongs to
# them. Everything an install may create belongs to ROOT, not to the box:
#   * the npm cache, and
#   * the XDG dirs a package's postinstall may write — measured: opencode's
#     install created /home/agent/.local/state/opencode owned by root, which
#     the full image's old `chown -R /home/agent` had been masking. The build
#     now asserts ownership, so this is the cause and not the repair.
as_root_npm() {
    $SUDO env HOME=/root NPM_CONFIG_CACHE=/root/.npm \
        XDG_STATE_HOME=/root/.local/state \
        XDG_CACHE_HOME=/root/.cache \
        XDG_CONFIG_HOME=/root/.config \
        npm "$@"
    $SUDO rm -rf /root/.npm /root/.local /root/.cache/npm /root/.config/npm
}

# Symlink every cargo toolchain binary into /usr/local/bin. The image's ENV
# PATH is lost in the vm guest's non-interactive ssh sessions, so a bare
# `cargo build` there would not resolve; bun, aft and umans use the same fix.
# Called by both rust steps, so the base toolchain binaries and any add-on
# binaries are reachable on the system PATH in every runtime and mode.
link_cargo_bins() {
    local bin
    for bin in "$CARGO_HOME_DIR"/bin/*; do
        [ -e "$bin" ] || continue
        $SUDO ln -sfn "$bin" "/usr/local/bin/$(basename "$bin")"
    done
}

# Record what this step provided, for `lbx-setup --status`.
record() {
    local dir="$BOX_HOME/.lbx"
    $SUDO install -d -o "$BOX_USER" -g "$BOX_GID" -m 755 "$dir" 2>/dev/null \
        || install -d -m 755 "$dir"
    {
        printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1"
    } >>"$dir/provisioned.log"
    chown "$BOX_USER:$BOX_GID" "$dir/provisioned.log" 2>/dev/null || true
}
