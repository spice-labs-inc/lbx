#!/usr/bin/env bash
# pnpm, through corepack. Optional (any runtime): Node ships here, but pnpm
# does not, and monorepos that pin a pnpm version (open-codesign, many others)
# will not build without it. Not part of the day-to-day set, hence this tier.
set -euo pipefail
# shellcheck source=/dev/null
. "${LBX_PROVISION_LIB:-/opt/llm-in-a-box/provision-lib.sh}"

if have pnpm; then
    log "pnpm already present"
    exit 0
fi
log "enabling pnpm through corepack"
# corepack asks "Do you want to continue? [Y/n]" before downloading a pnpm it
# has not cached; a provisioning step must never wait for input.
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
$SUDO env COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack enable
$SUDO env COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack prepare pnpm@latest --activate
if ! pnpm --version; then
    echo "ERROR: pnpm did not install." >&2
    exit 1
fi
record pnpm
log "pnpm ready"
