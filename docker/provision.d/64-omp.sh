#!/usr/bin/env bash
# OMP (Oh My Pi), installed globally and deliberately unpinned — and the
# Bun/OMP smoke gate, because OMP is the one agent whose breakage is a *runtime
# floor* rather than a failed install.
#
# The gate: `env -i PATH=<system PATH> omp --version` resolves bun ONLY via the
# /usr/local/bin symlink, which is the exact context the vm guest's
# non-interactive ssh probes use (2026-09-02). A broken Bun/OMP pair must not
# pass silently as done.
#
# `omp` alone is enough: when Bun is missing this step runs 60-bun.sh first,
# so there is no "run step X first" to remember.
set -euo pipefail
# shellcheck source=/dev/null
. "${LBX_PROVISION_LIB:-/opt/llm-in-a-box/provision-lib.sh}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -e /usr/local/bin/bun ] && ! have bun; then
    log "bun is missing (OMP is Bun-only); running 60-bun.sh first"
    bash "$HERE/60-bun.sh"
fi
if [ ! -e /usr/local/bin/bun ] && ! have bun; then
    echo "ERROR: bun is still missing after 60-bun.sh." >&2
    exit 1
fi

log "installing @oh-my-pi/pi-coding-agent (latest)"
as_root_npm install -g @oh-my-pi/pi-coding-agent

if ! bun --version || ! omp --version \
    || ! env -i PATH="$SYS_PATH" omp --version; then
    echo "ERROR: the Bun/OMP smoke test above failed. If it says the Bun runtime" >&2
    echo "       is too old, BUN_VERSION is below omp's engines.bun floor: check" >&2
    echo "       'npm view @oh-my-pi/pi-coding-agent engines.bun' and raise it." >&2
    exit 1
fi

record omp
log "omp ready"
