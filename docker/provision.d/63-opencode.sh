#!/usr/bin/env bash
# OpenCode, installed globally and deliberately unpinned.
set -euo pipefail
# shellcheck source=/dev/null
. "${LBX_PROVISION_LIB:-/opt/llm-in-a-box/provision-lib.sh}"

log "installing opencode-ai (latest)"
as_root_npm install -g opencode-ai

if ! as_box opencode --version; then
    echo "ERROR: opencode did not install or does not run." >&2
    exit 1
fi

record opencode
log "opencode ready"
