#!/usr/bin/env bash
# Bun. A hard dependency, not an option: @oh-my-pi/pi-coding-agent (OMP) ships
# a Bun-only bundle (shebang `#!/usr/bin/env bun`, engines.bun floor, no Node
# fallback), so the omp step cannot work without it.
#
# The pin must stay at or above OMP's current floor —
#   npm view @oh-my-pi/pi-coding-agent engines.bun
# (2026-10-25: omp 18.14.0 raised the floor to >=1.4.4; the pinned 1.4.0 broke
# every image build at "Bun runtime must be >= 1.4.4").
set -euo pipefail
# shellcheck source=/dev/null
. "${LBX_PROVISION_LIB:-/opt/llm-in-a-box/provision-lib.sh}"

BUN_VERSION="${BUN_VERSION:-1.4.4}"

if [ ! -x "$BOX_HOME/.bun/bin/bun" ]; then
    log "installing bun v${BUN_VERSION}"
    as_box bash -c "curl -fsSL https://bun.sh/install | bash -s -- 'bun-v${BUN_VERSION}'"
else
    log "bun already present"
fi

# /usr/local/bin symlinks, not ENV PATH: the image's ENV is lost in the vm
# guest's non-interactive ssh sessions, and omp's shebang resolves bun there.
$SUDO ln -sfn "$BOX_HOME/.bun/bin/bun" /usr/local/bin/bun
$SUDO ln -sfn "$BOX_HOME/.bun/bin/bunx" /usr/local/bin/bunx

if ! bun --version; then
    echo "ERROR: bun did not install or does not run." >&2
    exit 1
fi

record bun
log "bun ready"
