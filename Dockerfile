## ---------------------------------------------------------------------------
## llm-in-a-box — isolated, batteries-included dev container for
## running Claude Code in --dangerously-skip-permissions mode.
##
## Supports multiple isolation runtimes via RUNTIME_TYPE build arg:
##   sysbox  — Sysbox (user namespaces + syscall virtualization)
##   docker  — Plain Docker (--privileged DinD, for Docker/Rancher Desktop)
##
## Build:  docker build --build-arg RUNTIME_TYPE=sysbox -t llm-in-a-box:sysbox .
## ---------------------------------------------------------------------------
FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG RUNTIME_TYPE=sysbox

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

# ── Locale ───────────────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y locales \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# ── Core system packages ────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y \
    # essentials
    git curl wget unzip zip sudo ca-certificates gnupg lsb-release \
    software-properties-common apt-transport-https \
    # build tools
    build-essential cmake pkg-config libssl-dev protobuf-compiler \
    # CLI tools Claude Code reaches for
    ripgrep fd-find bat tree htop jq tmux \
    # editors (vim provides /usr/bin/vi via alternatives)
    vim emacs-nox \
    # Python
    python3 python3-pip python3-venv python3-full \
    # Java
    openjdk-21-jdk maven \
    # Ansible
    ansible \
    # gosu for entrypoint user switching
    gosu \
    && rm -rf /var/lib/apt/lists/*

# ── Symlinks for Ubuntu-renamed tools ───────────────────────────────────────
RUN ln -sf /usr/bin/batcat /usr/local/bin/bat \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd

# ── yq (not in Ubuntu repos) ────────────────────────────────────────────────
RUN ARCH=$(dpkg --print-architecture) \
    && curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${ARCH}" \
        -o /usr/local/bin/yq \
    && chmod +x /usr/local/bin/yq

# ── Gradle ──────────────────────────────────────────────────────────────────
ARG GRADLE_VERSION=9.7.1
RUN curl -fsSL "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip" \
        -o /tmp/gradle.zip \
    && unzip -q /tmp/gradle.zip -d /opt \
    && ln -s "/opt/gradle-${GRADLE_VERSION}" /opt/gradle \
    && rm /tmp/gradle.zip
ENV PATH="/opt/gradle/bin:${PATH}"

# ── SBT ─────────────────────────────────────────────────────────────────────
RUN curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x2EE0EA64E40A89B84B2DF73499E82A75642AC823" \
        | gpg --dearmor -o /etc/apt/trusted.gpg.d/sbt.gpg \
    && echo "deb https://repo.scala-sbt.org/scalasbt/debian all main" \
        > /etc/apt/sources.list.d/sbt.list \
    && apt-get update && apt-get install -y sbt \
    && rm -rf /var/lib/apt/lists/*

# ── Node.js 24 LTS (via NodeSource) ────────────────────────────────────────
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

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
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) \
        signed-by=/etc/apt/keyrings/docker.asc] \
        https://download.docker.com/linux/ubuntu \
        $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list \
    && if [ "$RUNTIME_TYPE" = "sysbox" ]; then \
        apt-get update \
        && apt-get install -y --allow-downgrades \
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
        apt-get update && apt-get install -y \
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

# ── GitHub CLI (gh) ─────────────────────────────────────────────────────────
# Installed on all runtime variants so GH_TOKEN forwarded by lbx
# (when set on the host) is immediately usable inside the container.
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) \
        signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] \
        https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

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

# ── Rust toolchain (as the agent user) ─────────────────────────────────────────
USER agent
ENV RUSTUP_HOME=/home/agent/.rustup
ENV CARGO_HOME=/home/agent/.cargo
ENV PATH="/home/agent/.cargo/bin:${PATH}"

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain stable \
    && rustup target add wasm32-unknown-unknown \
    && rustup component add rustfmt clippy rust-analyzer \
    && cargo install \
        wasm-pack \
        cargo-watch \
        cargo-edit \
        cargo-expand \
        cargo-audit \
        cargo-outdated \
        cargo-deny \
        sccache \
    && rustup component remove rust-docs 2>/dev/null || true \
    && rm -rf "$RUSTUP_HOME/downloads" "$RUSTUP_HOME/tmp" "$CARGO_HOME/registry" "$CARGO_HOME/git"

# ── Bun runtime (required by OMP) ───────────────────────────────────────────
# @oh-my-pi/pi-coding-agent (the `omp` binary) ships a Bun-only bundle:
# dist/cli.js has shebang `#!/usr/bin/env bun` and package.json declares an
# engines.bun floor with no Node fallback. Without Bun, `omp` cannot execute at
# all — this is a hard runtime dependency, not an optional one.
#
# THE PIN MUST SATISFY omp'S CURRENT FLOOR, and the floor moves with upstream
# because the agent packages are installed unpinned. It was >=1.3.14 (Bun
# 1.4.0 here), and on 2026-10-25 omp 18.14.0 raised it to >=1.4.4: the pinned
# 1.4.0 made `omp --version` fail and took down EVERY image build (sysbox,
# docker and vm) at step 25/47 with "Bun runtime must be >= 1.4.4". Check the
# floor when this pin ages, and bump it when it does:
#   npm view @oh-my-pi/pi-coding-agent engines.bun
ARG BUN_VERSION=1.4.4
ENV BUN_INSTALL=/home/agent/.bun
ENV PATH="${BUN_INSTALL}/bin:${PATH}"
RUN curl -fsSL https://bun.sh/install | bash -s -- "bun-v${BUN_VERSION}"
# The ENV above is docker-runtime-only and is LOST in the extracted vm
# rootfs; without a system-PATH symlink, `omp` (shebang
# `#!/usr/bin/env bun`) fails in the vm guest's non-interactive ssh
# sessions. Bake bun onto the system
# PATH like the aft symlink below. (USER is agent at this point —
# /usr/local/bin needs root.)
USER root
RUN ln -s /home/agent/.bun/bin/bun /usr/local/bin/bun \
    && ln -s /home/agent/.bun/bin/bunx /usr/local/bin/bunx
USER agent

# ── Claude Code + Pi + OpenCode + OMP (global npm install, as root) ────────────
# Unpinned on purpose: images pick up the latest at rebuild time.
# Pi is @earendil-works/pi-coding-agent — the @mariozechner scope was
# renamed at 0.74.0 and is deprecated.
USER root
RUN npm install -g \
        @anthropic-ai/claude-code \
        @earendil-works/pi-coding-agent \
        opencode-ai \
        @oh-my-pi/pi-coding-agent

# ── Build-time smoke test: fail the build if Bun/OMP is broken ─────────────
# (a broken `omp` install must not pass silently as done)
# The env -i run resolves bun ONLY via the system-PATH symlink — the exact
# context the vm guest's ssh-exec probes use (2026-09-02).
# The trailing message matters: without it the operator sees a wall of build
# log and one buried upstream line ("Bun runtime must be >= 1.4.4 …"), which
# is how the 2026-10-25 breakage read. It names the pin and the command that
# reports the floor.
RUN bun --version && omp --version \
    && env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin omp --version \
    || { echo "ERROR: the Bun/OMP smoke test above failed. If it says the Bun runtime is too old, the pinned BUN_VERSION is below omp's engines.bun floor: check 'npm view @oh-my-pi/pi-coding-agent engines.bun' and raise the pin. (2026-10-25: omp 18.14.0 raised the floor to >=1.4.4 and the pinned 1.4.0 broke every image build.)" >&2; exit 1; }

# ── umans.ai CLI (managed LLM endpoint for Claude Code) ──────────────────
RUN curl -fsSL https://api.code.umans.ai/cli/install.sh | bash \
    && chmod a+rx /usr/local/bin/umans

# ── Pi plugins: umans provider, AFT, web-access ───────────────────────────
# `pi install npm:<pkg>` registers the spec in ~/.pi/agent/settings.json and
# runs `npm install -g <pkg>`; unpinned so `pi update` refreshes them.
# HOME is the agent profile so settings land there; the npm cache is kept
# out of /home/agent (a root-owned cache would break the agent user's npm).
# `pi install` (pi >= 0.74) installs npm packages into the pi agent tree
# (~/.pi/agent/npm/node_modules), NOT the npm global tree — the symlink
# below points at that tree. aft-pi's optional platform dependency
# (@cortexkit/aft-linux-x64) ships the `aft` binary, but npm only links bins
# of TOP-LEVEL installed packages, not of their dependencies — so the aft
# bin is symlinked explicitly. The smoke test below proves it executes (no
# first-run download at session time).
# pi-web-access (web search,
# URL fetch, repo clone, PDF/YouTube/video extraction). It is a plain pi
# extension with no extra runtime deps (verified against npm).
USER root
ENV HOME=/home/agent
RUN NPM_CONFIG_CACHE=/root/.npm pi install npm:pi-provider-umans \
    && NPM_CONFIG_CACHE=/root/.npm pi install npm:@cortexkit/aft-pi \
    && NPM_CONFIG_CACHE=/root/.npm pi install npm:pi-web-access \
    && ln -sf /home/agent/.pi/agent/npm/node_modules/@cortexkit/aft-linux-x64/bin/aft /usr/local/bin/aft \
    && rm -rf /root/.npm

# ── Magic Context default config — historian on the cheapest
# Umans model; per-user Umans auth at runtime (/login umans | UMANS_API_KEY) ─
# /home/agent/.config must be agent-owned: COPY creates missing parent
# dirs as root, which would leave the agent user unable to create its own
# agent config dirs (e.g. opencode's ~/.config/opencode — caught by
# tests/verify-no-thinking-config.sh).
RUN mkdir -p /home/agent/.config/cortexkit \
    && chown agent:agent /home/agent/.config /home/agent/.config/cortexkit
COPY --chown=agent:agent docker/magic-context.jsonc /home/agent/.config/cortexkit/magic-context.jsonc
RUN chown -R agent:agent /home/agent/.pi

# ── Build-time smoke test: fail the build if pi or the plugins are broken ──
# (no silent "looks done" states)
RUN pi --version && pi list && aft --version

# -- Credential purge ------------------------------
# Never ship a pi credential file: auth is per-user at runtime (/login umans
# | UMANS_API_KEY). A build env exporting UMANS_API_KEY would leak a key into
# the image via pi init; a stale key then shadows the user's login and breaks
# model discovery (observed 2026-09-06). Removes both the agent profile and
# the root profile; runs AFTER the smoke test so the last credential-writing
# build step is always followed by the purge. test ! -e fails the build if a
# credential would still ship. Runtime gate: tests/verify-pi-plugins.sh
# "image ships no key-bearing pi auth.json".
RUN rm -f /home/agent/.pi/agent/auth.json /root/.pi/agent/auth.json \
    && test ! -e /home/agent/.pi/agent/auth.json \
    && test ! -e /root/.pi/agent/auth.json \
    && chown -R agent:agent /home/agent/.pi

# ── Claude Code settings: deny mutating git operations ─────────────────────
USER agent
RUN mkdir -p /home/agent/.claude
COPY --chown=agent:agent claude-settings.json /home/agent/.claude/settings.json

# ── Shell prompt showing runtime type ───────────────────────────────────────
RUN echo "PS1='[${RUNTIME_TYPE}] \\u@\\h:\\w\\$ '" >> /home/agent/.bashrc


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
# NOTE (2026-09-01): this RUN sits at the END of the Dockerfile (after the
# toolchain/agent layers) on purpose — when it was earlier in the file, the
# RUNTIME_TYPE=vm build invalidated every later layer (rust, npm, pi
# plugins), forcing full recompiles and re-downloads that also exhausted
# the disk on space-constrained build hosts. Same content, cache-friendly
# order: the docker and vm variants now share all toolchain/agent layers.
USER root
RUN if [ "$RUNTIME_TYPE" = "vm" ]; then \
        apt-get update && apt-get install -y \
            openssh-server linux-image-virtual initramfs-tools \
            iptables iproute2 qemu-utils \
            iputils-ping dnsutils telnet netcat-openbsd traceroute \
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

# ── Create /data mount point ───────────────────────────────────────────────
RUN mkdir -p /data && chown agent:agent /data

WORKDIR /data
ENTRYPOINT ["/entrypoint.sh"]
CMD ["sleep", "infinity"]
