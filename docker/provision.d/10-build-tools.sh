#!/usr/bin/env bash
# Extra C/C++ build tooling that the language toolchains want but the box does
# not need to survive on its own (gcc/make/pkg-config live in the slim image).
set -euo pipefail
# shellcheck source=/dev/null
. "${LBX_PROVISION_LIB:-/opt/llm-in-a-box/provision-lib.sh}"

if have cmake && have protoc; then
    log "build tools already present"
    exit 0
fi
apt_install cmake protobuf-compiler
record build-tools
log "build tools installed"
