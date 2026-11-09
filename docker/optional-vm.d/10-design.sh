#!/usr/bin/env bash
# Open CoDesign (OpenCoworkAI/open-codesign): a local-first Electron design
# app, MIT, BYOK. vm-only and slim-only by construction:
#
#   * it lives in docker/optional-vm.d/, which is copied into the VM slim image
#     and nowhere else, so a docker/sysbox box never lists it and the full
#     image never carries it;
#   * this script refuses on any other runtime as a second line of defence.
#
# It is a desktop app with no headless mode: nothing to publish, no web UI. The
# display therefore comes from the launcher's X11 forwarding, which it selects
# after seeing the marker this step writes (~/.lbx/gui).
#
# The package comes from the project's GitHub release (unsigned installers, so
# pin with LBX_DESIGN_VERSION=vX.Y.Z if you care which one):
#   lbx-setup design                         # latest release for this arch
#   LBX_DESIGN_VERSION=v0.2.0 lbx-setup design
#   LBX_DESIGN_DEB=/path/to/open-codesign-x64.deb lbx-setup design   # a local file
#   LBX_DESIGN_DEB_URL=https://…/open-codesign-x64.deb lbx-setup design
# The asset is resolved from the GitHub API and must be a Debian package: the
# installer is verified to be a real .deb before dpkg sees it. LBX_DESIGN_DRY_RUN=1
# (test only) skips the download and install, and exercises the marker/messaging.
set -euo pipefail
# shellcheck source=/dev/null
. "${LBX_PROVISION_LIB:-/opt/llm-in-a-box/provision-lib.sh}"

if [ "$BOX_RUNTIME" != "vm" ]; then
    echo "ERROR: the design app is GUI-only and needs a real display stack." >&2
    echo "       It is vm-runtime only (this box is '$BOX_RUNTIME')." >&2
    echo "       A docker or sysbox box cannot forward X11 here: the display arrives" >&2
    echo "       over the ssh connection the vm runtime provides." >&2
    exit 1
fi

DRY_RUN="${LBX_DESIGN_DRY_RUN:-0}"
DEB="${LBX_DESIGN_DEB:-}"
DEB_URL="${LBX_DESIGN_DEB_URL:-}"

# Electron/Chromium runtime libraries + the display plumbing, and Google
# Chrome itself: PDF (and deck) export runs through puppeteer-core, which the
# app points at a SYSTEM browser. Its own rule (app/out/main/index.js) is
# CODESIGN_CHROME_PATH, else `which` on google-chrome-stable | google-chrome |
# chromium-browser | chromium | microsoft-edge, else "System Chrome not found".
# Ubuntu's `chromium-browser` is a transitional SNAP stub: it satisfies `which`
# and then fails at launch, so Chrome stable (a real .deb) is the install that
# actually works.
GTK_PKGS=(
    libgtk-3-0t64 libnss3 libasound2t64 libgbm1 libxshmfence1 libdrm2
    libatk1.0-0t64 libatk-bridge2.0-0t64 libatspi2.0-0t64 libcups2t64
    fonts-liberation xauth dbus-x11 gnome-keyring libsecret-1-0 libsecret-tools
)

if [ "$DRY_RUN" != "1" ]; then
    # Resolve the package BEFORE the dependency install: a download that cannot
    # be resolved is reported in seconds rather than after a 1-minute apt run.
    if [ ! -x /opt/open-codesign/open-codesign ] && [ ! -x /usr/bin/open-codesign ]; then
        case "$(uname -m)" in
            x86_64) ARCH_TAG=x64 ;;
            aarch64 | arm64) ARCH_TAG=arm64 ;;
            *) ARCH_TAG="" ;;
        esac
        if [ -z "$DEB" ] && [ -z "$DEB_URL" ]; then
            if [ -z "$ARCH_TAG" ]; then
                echo "ERROR: this architecture ($(uname -m)) has no Open CoDesign release." >&2
                echo "       Supported: x64, arm64. Or pass LBX_DESIGN_DEB=<file>." >&2
                exit 1
            fi
            RELEASE_API="https://api.github.com/repos/OpenCoworkAI/open-codesign/releases/latest"
            if [ -n "${LBX_DESIGN_VERSION:-}" ]; then
                RELEASE_API="https://api.github.com/repos/OpenCoworkAI/open-codesign/releases/tags/${LBX_DESIGN_VERSION}"
            fi
            log "resolving the Open CoDesign ${LBX_DESIGN_VERSION:-latest} release (${ARCH_TAG})"
            # .deb for this arch, newest first in the asset list.
            DEB_URL="$(curl -fsSL "$RELEASE_API" 2>/dev/null \
                | jq -r --arg a "$ARCH_TAG" \
                    'first(.assets[]?.browser_download_url | select(test("-" + $a + "\\.deb$"))) // empty' 2>/dev/null)"
            if [ -z "$DEB_URL" ]; then
                echo "ERROR: could not find a ${ARCH_TAG} .deb in the GitHub release." >&2
                echo "       Release page: https://github.com/OpenCoworkAI/open-codesign/releases" >&2
                echo "       Pass one explicitly: LBX_DESIGN_DEB=/data/open-codesign-<ver>-${ARCH_TAG}.deb" >&2
                echo "       (a box under 'locked' or a narrow policy cannot reach api.github.com;" >&2
                echo "        fetch the .deb on the host and pass LBX_DESIGN_DEB instead.)" >&2
                exit 1
            fi
            log "release asset: $DEB_URL"
        fi
        if [ -z "$DEB" ]; then
            DEB="/tmp/open-codesign.deb"
            log "downloading $(basename "$DEB_URL")"
            if ! $SUDO curl -fsSL "$DEB_URL" -o "$DEB"; then
                echo "ERROR: download failed: $DEB_URL" >&2
                exit 1
            fi
            # A 404/HTML error page must never reach dpkg. Read the magic into a
            # variable rather than piping into `grep -q`: grep exits on the
            # match, head dies of SIGPIPE, and `pipefail` (set in
            # provision-lib) then reports this perfectly good file as "not a
            # Debian package" — measured on a real 66 MB .deb.
            magic="$(head -c 7 "$DEB" 2>/dev/null || true)"
            if [ "$magic" != '!<arch>' ]; then
                echo "ERROR: the download is not a Debian package (first bytes: '$magic'): $DEB_URL" >&2
                exit 1
            fi
        fi
    fi

    log "installing Electron runtime libraries"
    apt_install "${GTK_PKGS[@]}"

    # The system browser the app's exporters drive. A real .deb (Chrome
    # stable), not Ubuntu's chromium snap stub.
    if ! command -v google-chrome-stable >/dev/null 2>&1 && ! command -v google-chrome >/dev/null 2>&1; then
        log "installing Google Chrome stable (for PDF/deck export)"
        CHROME_DEB=/tmp/google-chrome.deb
        if ! $SUDO curl -fsSL -o "$CHROME_DEB" \
            https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb; then
            echo "ERROR: could not download Google Chrome. It is what the app's PDF" >&2
            echo "       export drives; a box under a narrow net policy must allow" >&2
            echo "       dl.google.com. Alternatively install any Chromium and set" >&2
            echo "       CODESIGN_CHROME_PATH=/path/to/chrome in the wrapper." >&2
            exit 1
        fi
        apt_install_deb "$CHROME_DEB"
        $SUDO rm -f "$CHROME_DEB"
    else
        log "a system Chrome is already present"
    fi
    if ! command -v google-chrome-stable >/dev/null 2>&1 && ! command -v google-chrome >/dev/null 2>&1; then
        echo "ERROR: Chrome installed but is not on PATH as google-chrome-stable." >&2
        exit 1
    fi

    if [ ! -x /opt/open-codesign/open-codesign ] && [ ! -x /usr/bin/open-codesign ]; then
        log "installing $(basename "$DEB")"
        apt_install_deb "$DEB"
    else
        log "open-codesign already installed"
    fi
fi

# Electron's safeStorage needs a D-Bus secret service with an UNLOCKED
# collection, and Electron does not auto-select the libsecret backend. Measured
# with the app's own Electron build, using a minimal safeStorage probe:
#   no flag                      -> available=false backend=basic_text
#   --password-store=basic       -> available=false backend=basic_text
#   --password-store=gnome-libsecret, keyring unlocked
#                                -> available=true  backend=gnome_libsecret
# Two details make the difference: `--unlock` must be fed a NEWLINE (an empty
# line is the empty password; EOF makes it pop a GTK prompter that cannot open
# a display), and the backend must be named explicitly.
# /usr/local/bin shadows /usr/bin, so plain `open-codesign` gets this.
if [ "$DRY_RUN" != "1" ]; then
    APP_BIN="$(readlink -f /usr/bin/open-codesign 2>/dev/null || true)"
    [ -n "$APP_BIN" ] || APP_BIN=/opt/open-codesign/open-codesign
    $SUDO tee /usr/local/bin/open-codesign >/dev/null <<WRAPPER
#!/bin/sh
# Installed by lbx-setup design. Gives Electron a session bus and a secret
# service for safeStorage before starting the app.
set -e
if [ -z "\${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "/run/user/\$(id -u)/bus" ]; then
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/\$(id -u)/bus"
    export DBUS_SESSION_BUS_ADDRESS
fi
if [ -z "\${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    exec dbus-run-session -- "\$0" "\$@"
fi
# Unlock (creating it on first use) the login keyring. The empty password is
# deliberate: a headless box has no one to type one.
eval "\$(printf '\\n' | gnome-keyring-daemon --unlock --components=secrets 2>/dev/null)" || true
exec "$APP_BIN" --no-sandbox --password-store=gnome-libsecret "\$@"
WRAPPER
    $SUDO chmod +x /usr/local/bin/open-codesign
    log "wrapper: /usr/local/bin/open-codesign (session bus + keyring, then the app)"
fi

# The marker the launcher reads at attach. One screen, one app, X11.
TRANSPORT="${LBX_DESIGN_TRANSPORT:-x11}"
$SUDO install -d -o "$BOX_USER" -g "$BOX_GID" -m 700 "$BOX_HOME/.lbx"
printf 'app=open-codesign\ntransport=%s\nsince=%s\n' \
    "$TRANSPORT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    | $SUDO tee "$BOX_HOME/.lbx/gui" >/dev/null
$SUDO chown "$BOX_USER:$BOX_GID" "$BOX_HOME/.lbx/gui"
$SUDO chmod 600 "$BOX_HOME/.lbx/gui"

# A display cannot appear in a session that was opened without forwarding, so
# say plainly what to do next instead of letting the app fail to start.
if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    log "this session already has a display; run: open-codesign"
else
    log "installed and marked. THIS SESSION HAS NO DISPLAY."
    log "Exit the box and re-run 'lbx <name>' — the launcher reads ~/.lbx/gui"
    log "and forwards X11 automatically (add nothing to the command line)."
    log "If the host has no display, run it under Xvfb and publish a VNC port."
fi

record design
log "design app ready"
