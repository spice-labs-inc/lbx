## ---------------------------------------------------------------------------
## llm-in-a-box — isolated, batteries-included dev container for
## running coding agents in --dangerously-skip-permissions mode.
##
## Supports multiple isolation runtimes via RUNTIME_TYPE build arg:
##   sysbox  — Sysbox (user namespaces + syscall virtualization)
##   docker  — Plain Docker (--privileged DinD, for Docker/Rancher Desktop)
##   vm      — KVM virtual machine rootfs
##
## Two image modes, one Dockerfile, one set of provisioning steps:
##
##   slim  (llm-in-a-box:<runtime>-slim)   OS, box user, entrypoint, docker,
##                                         node, gh, CLI tools, and the
##                                         provisioning steps themselves.
##                                         lbx-setup installs capabilities on
##                                         demand, from inside the box.
##   full  (llm-in-a-box:<runtime>)        FROM the slim image + every
##                                         provisioning step run at build time.
##                                         Identical to what shipped before.
##
## The full image is built FROM the slim image (not from ubuntu), so "the
## scripts are the same scripts" is structural, and both modes cost one
## toolchain download: with --no-cache there is no layer cache to share, but a
## parent image is not a cache.
##
## Build (./build does this for you):
##   docker build --build-arg RUNTIME_TYPE=sysbox --target slim -t llm-in-a-box:sysbox-slim .
##   docker build --build-arg RUNTIME_TYPE=sysbox --target full \
##       --build-arg SLIM_IMAGE=llm-in-a-box:sysbox-slim -t llm-in-a-box:sysbox .
## ---------------------------------------------------------------------------
# Global ARGs: both are needed before the first FROM so the `full` stage's
# `FROM ${SLIM_IMAGE}` resolves (BuildKit validates every stage's base, even
# for `--target slim`).
ARG RUNTIME_TYPE=sysbox
ARG SLIM_IMAGE=llm-in-a-box:sysbox-slim

FROM ubuntu:24.04 AS slim

ARG DEBIAN_FRONTEND=noninteractive
# Re-declare so the value is in scope for RUN in this stage.
ARG RUNTIME_TYPE

# ── Validate RUNTIME_TYPE ────────────────────────────────────────────────────
RUN case "$RUNTIME_TYPE" in \
        sysbox|docker|vm) ;; \
        *) echo "ERROR: RUNTIME_TYPE must be sysbox, docker, or vm (got: $RUNTIME_TYPE)" >&2; exit 1;; \
    esac

# ── Reliable apt mirror + force IPv4 (avoids flaky Canonical CDN nodes) ─────
# Ubuntu 24.04 uses DEB822 format in ubuntu.sources; archive.ubuntu.com has
# many CDN nodes that are unreachable from some networks — OSUOSL is stable.
RUN echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4 \
    && sed -i 's|http://archive.ubuntu.com|http://ubuntu.osuosl.org|g' \
        /etc/apt/sources.list.d/ubuntu.sources

# ── Locale + slim system packages (one apt run) ─────────────────────────────
# One apt layer, not two: every `apt-get update` here is ~3 s of index fetching
# and a separate layer, and a slim image is built often. `--no-install-recommends`
# is deliberate — the Recommends of this set are desktop/suggested extras
# (documentation, extra fonts, python3-dev) that a box does not need, and they
# are a third of the download.
#
# Contents: a shell, git, an editor that is always there, the CLI tools agents
# reach for, a C toolchain (npm native modules and anything you compile by
# hand), python3 (most CLIs are python), and `dialog` for lbx-setup. Language
# toolchains, Emacs, Ansible and the agents are provisioning steps
# (docker/provision.d/), installed on demand in a slim box.
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
RUN apt-get update && apt-get install -y --no-install-recommends \
    locales \
    # essentials
    git curl wget unzip zip sudo ca-certificates gnupg lsb-release \
    software-properties-common apt-transport-https \
    # C toolchain (npm native modules, hand-built tools)
    build-essential pkg-config libssl-dev \
    # CLI tools agents reach for
    ripgrep fd-find bat tree htop jq tmux \
    # editors (vim provides /usr/bin/vi via alternatives)
    vim \
    # python3 interpreter only; pip/venv/ansible are a provisioning step
    python3 \
    # lbx-setup's checklist UI, and the terminal definitions it needs on
    # terminals beyond xterm/vt100 (kitty, wezterm, foot, alacritty).
    dialog ncurses-term \
    # gosu for entrypoint user switching
    gosu \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

# ── Symlinks for Ubuntu-renamed tools ───────────────────────────────────────
RUN ln -sf /usr/bin/batcat /usr/local/bin/bat \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd

# ── yq (not in Ubuntu repos) ────────────────────────────────────────────────
RUN ARCH=$(dpkg --print-architecture) \
    && curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${ARCH}" \
        -o /usr/local/bin/yq \
    && chmod +x /usr/local/bin/yq


# ── Container engine: Docker CE (inner DinD via the host runtime's isolation)
#
# Sysbox CE does not yet fully support containerd 2.x, but current Docker CE
# (28.x/29.x) depends on containerd.io >= 2.1.5. Installing the latest Docker
# CE and then downgrading containerd.io causes apt to silently remove docker-ce
# to resolve the version conflict, leaving the sysbox image without dockerd.
#
# For sysbox we therefore pin the last Docker CE line known to work with
# containerd 1.7.x and install them together in a single transaction. The
# plain-docker and vm images use the current stable versions.
ARG SYSBOX_DOCKER_CE_VERSION=5:27.5.1-1~ubuntu.24.04~noble
ARG SYSBOX_DOCKER_CLI_VERSION=5:27.5.1-1~ubuntu.24.04~noble
ARG SYSBOX_DOCKER_ROOTLESS_VERSION=5:27.5.1-1~ubuntu.24.04~noble
ARG SYSBOX_CONTAINERD_VERSION=1.7.28-1~ubuntu.24.04~noble
ARG SYSBOX_BUILDX_VERSION=0.20.0-1~ubuntu.24.04~noble
ARG SYSBOX_COMPOSE_VERSION=2.32.4-1~ubuntu.24.04~noble
# ── Node.js 24, Docker CE and gh: one apt layer ─────────────────────────────
# All three need a third-party repository, and each repository otherwise costs
# its own `apt-get update` (~3 s of index fetching) and its own layer commit.
# Registering every repository first and running a single update+install keeps
# the slim build near its download time, which is the whole point of it.
#
# Node is in the slim image because the agents (a provisioning step) need it and
# lbx-setup shells out to npm; gh is core to agent work (PRs, issues).
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) \
        signed-by=/etc/apt/keyrings/docker.asc] \
        https://download.docker.com/linux/ubuntu \
        $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) \
        signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] \
        https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && if [ "$RUNTIME_TYPE" = "sysbox" ]; then \
        apt-get update \
        && apt-get install -y --no-install-recommends --allow-downgrades \
            nodejs gh \
            docker-ce="${SYSBOX_DOCKER_CE_VERSION}" \
            docker-ce-cli="${SYSBOX_DOCKER_CLI_VERSION}" \
            docker-ce-rootless-extras="${SYSBOX_DOCKER_ROOTLESS_VERSION}" \
            docker-buildx-plugin="${SYSBOX_BUILDX_VERSION}" \
            docker-compose-plugin="${SYSBOX_COMPOSE_VERSION}" \
            containerd.io="${SYSBOX_CONTAINERD_VERSION}" \
        && apt-mark hold \
            docker-ce docker-ce-cli docker-ce-rootless-extras \
            docker-buildx-plugin docker-compose-plugin containerd.io; \
    else \
        apt-get update && apt-get install -y --no-install-recommends \
            nodejs gh \
            docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin; \
    fi \
    && rm -rf /var/lib/apt/lists/*

# ── QEMU tooling, TCG-only (sysbox variant only) ────────────────────────────
# sysbox's user-namespace GID mapping cannot grant /dev/kvm access (confirmed
# empirically), so no device is
# passed through and no -accel kvm is available. qemu here runs in TCG
# (software-emulated) mode only. Scoped to sysbox only: the plain-docker image
# does not carry it, and the vm runtime has KVM on the host.
RUN if [ "$RUNTIME_TYPE" = "sysbox" ]; then \
        apt-get update && apt-get install -y \
            qemu-system-x86 qemu-utils \
        && rm -rf /var/lib/apt/lists/*; \
    fi

# ── Bridged VM networking tooling (sysbox variant only) ─────────────────────
# This grants access via
# a Linux *capability* (CAP_NET_ADMIN) and the world-writable /dev/net/tun
# device — not via host-GID device ownership — so it does not hit the
# sysbox user-namespace mapping wall that killed /dev/kvm passthrough.
# linux-image-virtual + cpio are
# used to build a minimal bootable test-VM image (kernel + busybox
# initramfs) so tests/verify-vm-bridged-network.sh can boot a real guest
# and serve HTTP over the bridge, not just check plumbing.
RUN if [ "$RUNTIME_TYPE" = "sysbox" ]; then \
        apt-get update && apt-get install -y \
            bridge-utils iproute2 iptables dnsmasq cpio \
            linux-image-virtual busybox-static \
        && rm -rf /var/lib/apt/lists/*; \
    fi

COPY docker/vm-test-init.sh /opt/vm-test/rootfs/init
RUN if [ "$RUNTIME_TYPE" = "sysbox" ]; then \
        set -e \
        && KVER=$(ls /lib/modules | head -1) \
        && mkdir -p /opt/vm-test/rootfs/bin /opt/vm-test/rootfs/www \
            /opt/vm-test/rootfs/proc /opt/vm-test/rootfs/sys \
            "/opt/vm-test/rootfs/lib/modules/${KVER}" \
        && cp /bin/busybox /opt/vm-test/rootfs/bin/busybox \
        && ( cd /opt/vm-test/rootfs/bin && ./busybox --install -s . ) \
        && echo 'llm-in-a-box VM network test OK' > /opt/vm-test/rootfs/www/index.html \
        && chmod +x /opt/vm-test/rootfs/init \
        && if [ -d "/lib/modules/${KVER}/kernel/drivers/virtio" ]; then \
               mkdir -p "/opt/vm-test/rootfs/lib/modules/${KVER}/kernel/drivers/virtio" \
                   "/opt/vm-test/rootfs/lib/modules/${KVER}/kernel/drivers/net" \
               && cp -a "/lib/modules/${KVER}/kernel/drivers/virtio/." \
                   "/opt/vm-test/rootfs/lib/modules/${KVER}/kernel/drivers/virtio/" \
               && cp -a "/lib/modules/${KVER}/kernel/drivers/net/virtio_net.ko"* \
                   "/opt/vm-test/rootfs/lib/modules/${KVER}/kernel/drivers/net/" 2>/dev/null || true \
               && cp "/lib/modules/${KVER}/modules.order" "/lib/modules/${KVER}/modules.builtin" \
                   "/opt/vm-test/rootfs/lib/modules/${KVER}/" 2>/dev/null || true \
               && depmod -b /opt/vm-test/rootfs "${KVER}" || true; \
           fi \
        && ( cd /opt/vm-test/rootfs && find . | cpio -o -H newc 2>/dev/null | gzip -9 > /opt/vm-test/initramfs.cpio.gz ) \
        && ln -s "$(ls /boot/vmlinuz-* | head -1)" /opt/vm-test/vmlinuz; \
    fi

COPY docker/vm-net-attach.sh /usr/local/bin/vm-net-attach
RUN chmod +x /usr/local/bin/vm-net-attach

# ── Default user (UID/GID adjusted at runtime by entrypoint) ───────────────
# Ubuntu 24.04 may already have a user/group at UID/GID 1000 (e.g. "ubuntu").
# Remove any existing occupants, then create our user cleanly.
RUN existing_user=$(getent passwd 1000 | cut -d: -f1) \
    && [ -n "$existing_user" ] && userdel -r "$existing_user" 2>/dev/null || true \
    && existing_group=$(getent group 1000 | cut -d: -f1) \
    && [ -n "$existing_group" ] && groupdel "$existing_group" 2>/dev/null || true \
    && groupadd -g 1000 agent \
    && useradd -m -u 1000 -g agent -s /bin/bash agent \
    && echo "agent ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/agent \
    && chmod 0440 /etc/sudoers.d/agent

# Add user to docker group
RUN usermod -aG docker agent

# ── Box identity: agent settings and the prompt's runtime tag ───────────────
# These belong to the box, not to a toolchain: a slim box that installs Claude
# Code later must still get the deny rules, and the prompt shows the runtime
# in every mode.
RUN mkdir -p /home/agent/.claude /home/agent/.config/cortexkit \
    && chown agent:agent /home/agent/.claude /home/agent/.config \
        /home/agent/.config/cortexkit
COPY --chown=agent:agent claude-settings.json /home/agent/.claude/settings.json
COPY --chown=agent:agent docker/magic-context.jsonc \
    /home/agent/.config/cortexkit/magic-context.jsonc
RUN echo "PS1='[${RUNTIME_TYPE}] \\u@\\h:\\w\\$ '" >> /home/agent/.bashrc

# ── Provisioning steps (the definition of "installed") ─────────────────────
# The fat image runs them at build time; a slim box runs them with lbx-setup.
# Shipping them in BOTH modes is what keeps the two from drifting.
COPY docker/provision-lib.sh /opt/llm-in-a-box/provision-lib.sh
COPY docker/provision.d/ /opt/llm-in-a-box/provision.d/
COPY docker/optional.d/ /opt/llm-in-a-box/optional.d/
# The vm-only tier is copied to a scratch path and kept ONLY for RUNTIME_TYPE=vm:
# a docker/sysbox slim box must not even list a GUI step it could never run.
COPY docker/optional-vm.d/ /tmp/optional-vm.d/
COPY docker/lbx-setup /usr/local/bin/lbx-setup
RUN chmod +x /usr/local/bin/lbx-setup \
    && find /opt/llm-in-a-box /tmp/optional-vm.d -name '*.sh' -exec chmod +x {} + \
    && if [ "$RUNTIME_TYPE" = "vm" ]; then \
        mv /tmp/optional-vm.d /opt/llm-in-a-box/optional-vm.d; \
    else \
        rm -rf /tmp/optional-vm.d; \
    fi \
    && install -d -o agent -g agent /home/agent/.lbx

# ── VM runtime variant (RUNTIME_TYPE=vm) ─────────────────────────────────────
# The exported rootfs of this variant boots as a KVM VM: systemd is PID 1
# (not entrypoint.sh),
# so it needs a kernel + initramfs, sshd for attach, iptables for the
# in-guest dockerd, and the llm-in-a-box-setup service (user remap,
# user-net networking, 9p project mount, ssh key/seed). The ssh and docker
# services are enabled with manual symlinks because apt cannot rely on a
# running systemd during a container build.
# sshd runs as a plain service (not socket-activated): socket activation
# would require the setup service to order Before=ssh.socket, which creates
# a systemd ordering cycle (ssh.socket -> setup -> ... -> sockets.target ->
# ssh.socket) that systemd breaks by skipping the setup service. The
# package enables ssh.socket by default, so disable it and keep the
# multi-user ssh.service enable.
# NOTE (2026-09-01): this RUN sits at the END of the slim stage (after the
# shared layers) on purpose — when it was earlier in the file, the
# RUNTIME_TYPE=vm build invalidated every later layer (rust, npm, pi
# plugins), forcing full recompiles and re-downloads that also exhausted
# the disk on space-constrained build hosts. Same content, cache-friendly
# order. In the split design the provisioning steps live in the `full`
# stage (FROM this image), so this layer can no longer invalidate them.
USER root
RUN if [ "$RUNTIME_TYPE" = "vm" ]; then \
        apt-get update && apt-get install -y --no-install-recommends \
            openssh-server linux-image-virtual initramfs-tools \
            iptables iproute2 qemu-utils \
            iputils-ping dnsutils telnet netcat-openbsd traceroute \
            # xauth is an openssh-server RECOMMEND, which --no-install-recommends
            # drops: without it `ssh -X` has no cookie helper and the GUI
            # transport silently cannot forward a display.
            xauth \
        && rm -f /etc/systemd/system/sockets.target.wants/ssh.socket \
               /lib/systemd/system/sockets.target.wants/ssh.socket \
        && ln -sf /lib/systemd/system/ssh.service /etc/systemd/system/multi-user.target.wants/ssh.service \
        && ln -sf /lib/systemd/system/docker.socket /etc/systemd/system/sockets.target.wants/docker.socket \
        && (update-initramfs -c -k all 2>/dev/null || true) \
        && rm -rf /var/lib/apt/lists/*; \
    fi

# ── Helper scripts ──────────────────────────────────────────────────────────
USER root
COPY entrypoint.sh   /entrypoint.sh
COPY update-claude-code.sh /usr/local/bin/update-claude-code
COPY docker/vm-setup.sh /usr/local/sbin/vm-setup.sh
COPY docker/vm-docker-store.sh /usr/local/sbin/vm-docker-store.sh
COPY docker/state-dir-message.md /usr/local/sbin/state-dir-message.md
COPY docker/llm-in-a-box-setup.service /etc/systemd/system/llm-in-a-box-setup.service
# Store-ordering drop-ins (2026-09-10): Wants=/After= the setup unit so a
# socket-activated containerd/docker can never start before the store image
# is mounted (the setup unit's own Before= only orders direct pulls).
COPY docker/docker.service.d/llm-in-a-box.conf /etc/systemd/system/docker.service.d/llm-in-a-box.conf
COPY docker/containerd.service.d/llm-in-a-box.conf /etc/systemd/system/containerd.service.d/llm-in-a-box.conf
RUN chmod +x /entrypoint.sh /usr/local/bin/update-claude-code /usr/local/sbin/vm-setup.sh /usr/local/sbin/vm-docker-store.sh \
    && if [ "$RUNTIME_TYPE" = "vm" ]; then \
        ln -sf /etc/systemd/system/llm-in-a-box-setup.service \
            /etc/systemd/system/multi-user.target.wants/llm-in-a-box-setup.service; \
    fi

# ── Store runtime type for entrypoint ───────────────────────────────────────
ENV LBX_RUNTIME_TYPE=${RUNTIME_TYPE} LLMBOX_RUNTIME_TYPE=${RUNTIME_TYPE}
# ... and on disk, because the vm runtime boots this image's rootfs as a guest:
# an exported rootfs carries no container ENV, so every ssh session in a vm box
# saw LBX_RUNTIME_TYPE empty. Provisioning steps read the file instead.
RUN install -d /etc/llm-in-a-box && printf '%s\n' "${RUNTIME_TYPE}" > /etc/llm-in-a-box/runtime

# ── Box user's toolchain home ──────────────────────────────────────────────
# Kept from the pre-split image so a bare `docker exec <box> bash` finds the
# same toolchains: HOME is the box user's, and the per-user toolchain dirs are
# on PATH. In a slim box these paths exist only after the matching lbx-setup
# step — the provisioning steps also symlink their binaries into
# /usr/local/bin, because the vm guest loses this ENV in non-interactive ssh
# sessions (the same reason bun and aft are symlinked).
ENV HOME=/home/agent \
    RUSTUP_HOME=/home/agent/.rustup \
    CARGO_HOME=/home/agent/.cargo \
    BUN_INSTALL=/home/agent/.bun
ENV PATH="/home/agent/.cargo/bin:/home/agent/.bun/bin:${PATH}"

# ── Create /data mount point ───────────────────────────────────────────────
RUN mkdir -p /data && chown agent:agent /data

WORKDIR /data
ENTRYPOINT ["/entrypoint.sh"]
CMD ["sleep", "infinity"]

## ---------------------------------------------------------------------------
## full — the image that ships today: slim + every provisioning step, run in
## order at build time. Nothing about its contents should differ from the
## pre-split image except that the steps now live in provision.d/.
## ---------------------------------------------------------------------------
FROM ${SLIM_IMAGE} AS full

ARG RUNTIME_TYPE=sysbox

# Runs as root (the slim stage ends as USER root). Each step is idempotent and
# carries its own smoke test, so a broken upstream release fails the build here
# exactly as loudly as it did before the split.
RUN for step in /opt/llm-in-a-box/provision.d/*.sh; do \
        echo "==> provision: $(basename "$step")"; \
        bash "$step"; \
    done

# A full image is the preprovisioned set: it must not be able to offer an
# optional tier at all ("never baked into a full build").
RUN rm -rf /opt/llm-in-a-box/optional.d /opt/llm-in-a-box/optional-vm.d

# Ownership is ASSERTED, not repaired. Every step installs as the box user
# (as_box) or as root into /usr/local, so /home/agent is already box-owned —
# measured on a full build, `chown -R /home/agent` took 484 s and changed
# nothing. This fails the build the moment a step starts writing as root, and
# costs milliseconds.
RUN test -f /home/agent/.pi/agent/settings.json \
    && test -z "$(find /home/agent ! -user agent -print -quit)"

# The fat image's build-time gate, kept as one last assertion.
RUN pi --version && omp --version && opencode --version && claude --version \
    && aft --version && pi list
