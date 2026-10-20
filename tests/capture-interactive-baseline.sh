#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# capture-interactive-baseline.sh — record the interactive baseline.
#
# WHAT: runs every scenario in tests/interactive-baseline-lib.sh against the
# launcher in this working tree and writes the results to
# tests/fixtures/interactive_baseline/. The regression checks REG1 and REG2
# in tests/test_llm_in_a_box_run.sh compare later launchers against it.
#
# WHY: the baseline must come from running the launcher as it was before
# the unattended mode existed, so it is captured once, from that launcher,
# and checked in. Recapturing after the launcher changes would defeat the
# comparison; the commit it was captured at is recorded alongside it.
#
# Usage: tests/capture-interactive-baseline.sh
#
# LLM-FRIENDLY NOTE: needs no docker daemon (fake docker only). Writes
# scratch fixtures under a temporary directory it removes afterwards.
# ---------------------------------------------------------------------------
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/interactive-baseline-lib.sh
. "$SCRIPT_DIR/interactive-baseline-lib.sh"

OUT="$SCRIPT_DIR/fixtures/interactive_baseline"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lbx-baseline.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

rm -rf "$OUT"
mkdir -p "$OUT"
while read -r scenario; do
    baseline_run "${LBX_BIN:-$SCRIPT_DIR/../target/debug/lbx}" "$scenario" "$OUT" "$WORK" || exit 1
    echo "captured: $scenario (exit $(cat "$OUT/$scenario.rc"))"
done < <(baseline_scenarios)
commit="$(git -C "$SCRIPT_DIR/.." rev-parse --short HEAD 2>/dev/null || echo unknown)"
printf 'captured-at-commit=%s\n' "$commit" > "$OUT/CAPTURED_AT"
echo "baseline written to $OUT (commit $commit)"
