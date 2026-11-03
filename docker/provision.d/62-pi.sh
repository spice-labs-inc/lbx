#!/usr/bin/env bash
# Pi, and everything Pi owns: the binary plus its extensions.
#
# Pi's extensions are installed BY Pi (`pi install npm:<pkg>`), not by the image
# and not by the launcher — that is the same command you would run in a box, so
# `pi update --extensions` and this step cannot disagree:
#   pi-provider-umans   the `umans` provider with live model discovery
#   @cortexkit/aft-pi   AFT tools (read/write/edit/grep) + the `aft` binary
#   pi-web-access       web search, URL fetch, repo clone, PDF/video extraction
#
# `pi install` registers the spec in ~/.pi/agent/settings.json and installs into
# ~/.pi/agent/npm/node_modules (not the npm global tree), so the extensions run
# as the box user and need no chown afterwards. Unpinned on purpose.
#
# aft-pi's platform package (@cortexkit/aft-linux-x64) ships the `aft` binary,
# but npm only links bins of TOP-LEVEL packages, so `aft` is symlinked into
# /usr/local/bin explicitly; the smoke test proves it executes (no first-run
# download at session time).
set -euo pipefail
# shellcheck source=/dev/null
. "${LBX_PROVISION_LIB:-/opt/llm-in-a-box/provision-lib.sh}"

log "installing @earendil-works/pi-coding-agent (latest)"
as_root_npm install -g @earendil-works/pi-coding-agent

for spec in npm:pi-provider-umans npm:@cortexkit/aft-pi npm:pi-web-access; do
    log "pi install ${spec#npm:}"
    as_box pi install "$spec"
done

$SUDO ln -sfn \
    "$BOX_HOME/.pi/agent/npm/node_modules/@cortexkit/aft-linux-x64/bin/aft" \
    /usr/local/bin/aft

# Never ship or keep a pi credential file: auth is per-user at runtime
# (/login umans | UMANS_API_KEY). A stale key in auth.json shadows the user's
# login and breaks model discovery (observed 2026-09-06). The `test ! -e`
# makes this fail loudly if a credential would survive.
$SUDO rm -f "$BOX_HOME/.pi/agent/auth.json" /root/.pi/agent/auth.json
if [ -e "$BOX_HOME/.pi/agent/auth.json" ] || [ -e /root/.pi/agent/auth.json ]; then
    echo "ERROR: a pi credential file survived the purge; refusing to continue." >&2
    exit 1
fi

if ! as_box pi --version || ! as_box pi list || ! aft --version; then
    echo "ERROR: the pi/aft smoke test above failed." >&2
    exit 1
fi

record pi
log "pi ready"
