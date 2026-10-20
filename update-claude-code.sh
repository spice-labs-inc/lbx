#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# update-claude-code — update Claude Code to the latest version inside
#                      the running llm-in-a-box container.
#
# Usage:  update-claude-code
# ---------------------------------------------------------------------------
set -euo pipefail

echo "==> Current Claude Code version:"
claude --version 2>/dev/null || echo "    (not found or not on PATH)"

echo ""
echo "==> Updating Claude Code via npm …"
sudo npm install -g @anthropic-ai/claude-code@latest

echo ""
echo "==> Updated Claude Code version:"
claude --version
