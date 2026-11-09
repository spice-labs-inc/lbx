#!/usr/bin/env bash
# Claude Code, installed globally and deliberately unpinned: a rebuild (full
# image) or a re-run of this step (slim box) picks up the current release.
#
# Its settings (`~/.claude/settings.json`, the deny rules for mutating git
# commands) are part of the slim image's box identity, not of this step, so
# they are already in place before the binary arrives.
set -euo pipefail
# shellcheck source=/dev/null
. "${LBX_PROVISION_LIB:-/opt/llm-in-a-box/provision-lib.sh}"

log "installing @anthropic-ai/claude-code (latest)"
as_root_npm install -g @anthropic-ai/claude-code

if ! as_box claude --version; then
    echo "ERROR: claude did not install or does not run." >&2
    exit 1
fi

record claude
log "claude ready"
