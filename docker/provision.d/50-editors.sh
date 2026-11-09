#!/usr/bin/env bash
# Emacs, for people who edit in Emacs. vim is in the slim image (a box without
# an editor at all is not a box).
set -euo pipefail
# shellcheck source=/dev/null
. "${LBX_PROVISION_LIB:-/opt/llm-in-a-box/provision-lib.sh}"

if have emacs; then
    log "emacs already present"
    exit 0
fi
apt_install emacs-nox
record editors
log "emacs installed"
