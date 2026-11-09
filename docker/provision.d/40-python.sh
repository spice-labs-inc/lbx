#!/usr/bin/env bash
# Python development set and Ansible. python3 itself (the interpreter every
# other tool reaches for) is in the slim image; this adds pip, venv, the -full
# metapackage and Ansible's dependency tree.
set -euo pipefail
# shellcheck source=/dev/null
. "${LBX_PROVISION_LIB:-/opt/llm-in-a-box/provision-lib.sh}"

if have pip3 && have ansible; then
    log "python dev set already present"
    exit 0
fi
apt_install python3-pip python3-venv python3-full ansible
record python
log "python toolchain ready"
