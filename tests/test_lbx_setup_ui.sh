#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_lbx_setup_ui.sh — the interactive path of lbx-setup, which the capability
# tests never touched:
#
#   * a dialog that cannot initialise curses (a terminal whose terminfo is
#     missing, or TERM unset) must fall back to a plain numbered menu, not
#     report "cancelled; nothing installed" and leave the user with no way in;
#   * a working dialog is still used, and its selection is honoured;
#   * no TTY and no arguments refuses with guidance instead of hanging;
#   * `--list` works with TERM unset.
#
# Runs entirely on the host: lbx-setup is a shell script, the steps are stubs,
# and the box user is whatever uid 1000 is here. No docker, no image.
#
# Usage: bash tests/test_lbx_setup_ui.sh [--lbx-setup <path>]
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LBX_SETUP="${LBX_SETUP:-$ROOT/docker/lbx-setup}"
[ -f "$LBX_SETUP" ] || { echo "ERROR: no lbx-setup at $LBX_SETUP" >&2; exit 1; }
if [ -z "$(getent passwd 1000 | cut -d: -f1)" ]; then
    echo "SKIP: no uid-1000 user here (lbx-setup needs a box user)"
    exit 0
fi

PASS=0
FAIL=0
check() {
    local description="$1" condition="$2"
    if eval "$condition"; then
        echo "[PASS] $description"; PASS=$((PASS + 1))
    else
        echo "[FAIL] $description"; FAIL=$((FAIL + 1))
    fi
}

W="$(mktemp -d /tmp/lbx-setup-ui.XXXXXX)"
trap 'rm -rf "$W"' EXIT
BIN="$W/bin"
STEPS="$W/provision.d"
mkdir -p "$BIN" "$STEPS"
: >"$W/ran"

# Stub the first two REAL steps: the menu numbers map to ALL_STEPS, so a stub
# invented name could never be picked by number. They only record that they ran.
for pair in 10:build-tools 20:rust; do
    num="${pair%%:*}"
    name="${pair##*:}"
    cat >"$STEPS/$num-$name.sh" <<EOF
#!/usr/bin/env bash
echo ran-$name >>"\${LBX_UI_RAN:?}"
EOF
    chmod +x "$STEPS/$num-$name.sh"
done

# The interactive path requires a terminal (lbx-setup checks [ -t 0 ] && [ -t 1 ]),
# so every UI case runs under `script`, which allocates a real pty. Output and
# stderr are merged in $W/out: the assertions are about what the user sees.
run_setup() {  # <dialog-stub-body-or-empty> <stdin-text>
    local stub="$1" input="$2"
    if [ -n "$stub" ]; then
        printf '%s\n' "$stub" >"$BIN/dialog"
        chmod +x "$BIN/dialog"
    else
        rm -f "$BIN/dialog"
    fi
    : >"$W/out"
    printf '%s\n' "$input" | script -qec "env PATH='$BIN:$PATH' HOME='$W/home' LBX_PROVISION_DIR='$STEPS' LBX_OPTIONAL_DIR='$W/none1' LBX_OPTIONAL_VM_DIR='$W/none2' LBX_UI_RAN='$W/ran' bash '$LBX_SETUP'" /dev/null >"$W/out" 2>&1
    echo $? >"$W/rc"
}

# ── 1. dialog fails to initialise: plain menu takes over ───────────────────
run_setup '#!/bin/sh
echo "cannot initialize curses" >&2
exit 2' '1'
check "dialog cannot init: falls back to a menu (no TUI)" \
    "grep -q 'using a plain menu' $W/out"
check "dialog cannot init: the numbered menu is shown" \
    "grep -q '1) build-tools' $W/out"
check "dialog cannot init: the chosen step runs" "grep -qx 'ran-build-tools' $W/ran"
check "dialog cannot init: it does not claim the user cancelled" \
    "! grep -q 'cancelled; nothing installed' $W/out"

# ── 2. dialog works: its selection is honoured ─────────────────────────────
: >"$W/ran"
run_setup '#!/bin/sh
printf "rust\n"
exit 0' ''
check "working dialog: its selection runs" "grep -qx 'ran-rust' $W/ran"
check "working dialog: no plain menu" "! grep -q 'using a plain menu' $W/out"

# ── 3. dialog cancels: nothing runs, and it says so ────────────────────────
: >"$W/ran"
run_setup '#!/bin/sh
exit 1' ''
check "dialog cancel: nothing runs" "[ ! -s '$W/ran' ]"
check "dialog cancel: reported as cancelled" "grep -q 'cancelled; nothing installed' $W/out"

# ── 4. plain menu, by name as well as by number ────────────────────────────
: >"$W/ran"
run_setup '#!/bin/sh
exit 2' 'rust'
check "plain menu accepts a step name" "grep -qx 'ran-rust' $W/ran"
: >"$W/ran"
run_setup '#!/bin/sh
exit 2' '99'
check "plain menu refuses an out-of-range number" \
    "[ \"\$(cat $W/rc)\" -ne 0 ] && grep -q 'no step 99' $W/out"

# ── 5. no TTY and no arguments: guidance, not a hang ───────────────────────
: >"$W/ran"
env PATH="$BIN:$PATH" HOME="$W/home" LBX_PROVISION_DIR="$STEPS" \
    LBX_OPTIONAL_DIR="$W/none1" LBX_OPTIONAL_VM_DIR="$W/none2" \
    bash "$LBX_SETUP" </dev/null >"$W/out" 2>"$W/err"
check "no TTY: refuses with guidance" \
    "grep -q 'no terminal and no steps named' $W/err"

# ── 6. --list with TERM unset must not need curses ────────────────────────
env -u TERM PATH="$BIN:$PATH" HOME="$W/home" LBX_PROVISION_DIR="$STEPS" \
    LBX_OPTIONAL_DIR="$W/none1" LBX_OPTIONAL_VM_DIR="$W/none2" \
    bash "$LBX_SETUP" --list >"$W/out" 2>"$W/err"
check "--list works with TERM unset" "grep -q 'build-tools' $W/out"

echo ""
echo "test_lbx_setup_ui.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
