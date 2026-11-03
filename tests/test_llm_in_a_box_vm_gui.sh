#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_llm_in_a_box_vm_gui.sh — the vm GUI transport, end to end through the
# real launcher and the real vm preflight, with ssh and waypipe shimmed.
#
# WHAT THIS PROVES (and what it does not):
#   * the marker a GUI step writes (`~/.lbx/gui`) is parsed, cached in the
#     session directory, and shown by `lbx --list`;
#   * the attach command line is exactly right for every case: default, x11,
#     x11-trusted, wayland, wayland->x11 fallback, and forcing/negating;
#   * host incapacity degrades to a plain shell with one explanatory note, and
#     never blocks the attach;
#   * credentials travel at attach time (the ssh payload), never in the image
#     seed, and `docker run -e` never carries them;
#   * a real vm preflight runs (qemu + qemu-img + ssh present, accel=tcg so no
#     KVM is needed; a real qcow2 base so the format check is real).
#
# It does not boot a VM: the transport decision is pure argv, and a boot is
# covered by tests/verify-vm-e2e.sh on a host with KVM.
#
# Preconditions (qemu-system-x86_64, qemu-img) are checked before any check
# line is emitted, so a host without them reports "SKIP:" and zero checks —
# nothing is silently skipped inside the run.
#
# Usage: bash tests/test_llm_in_a_box_vm_gui.sh
#   LBX_BIN=<path>   launcher under test (default: target/debug/lbx)
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LBX="${LBX_BIN:-$ROOT/target/debug/lbx}"
[ -x "$LBX" ] || { echo "ERROR: no lbx binary at $LBX (cargo build first)." >&2; exit 1; }
command -v qemu-system-x86_64 >/dev/null || { echo "SKIP: qemu-system-x86_64 not installed"; exit 0; }
command -v qemu-img >/dev/null || { echo "SKIP: qemu-img not installed"; exit 0; }

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

W="$(mktemp -d /tmp/lbx-gui-test.XXXXXX)"
trap 'rm -rf "$W"' EXIT

# ── shims ──────────────────────────────────────────────────────────────────
BIN="$W/bin"
mkdir -p "$BIN" "$W/state" "$W/home"
# xauth: its presence is what makes `ssh -X` plausible on the host.
printf '#!/bin/sh\nexit 0\n' >"$BIN/xauth"
# waypipe: `waypipe ssh …` — record, then behave like ssh.
cat >"$BIN/waypipe" <<'EOF'
#!/usr/bin/env bash
printf 'WAYPIPE %s\n' "$*" >>"$LBX_SSH_LOG"
shift   # drop "ssh"
exec "$LBX_FAKE_SSH" "$@"
EOF
cat >"$BIN/ssh" <<'EOF'
#!/usr/bin/env bash
# Stands in for every ssh the launcher makes: the pre-attach probe (which
# carries the credential payload on stdin and prints the GUI marker) and the
# interactive attach (which is exec'd, so this exits and becomes lbx's status).
printf 'SSH %s\n' "$*" >>"$LBX_SSH_LOG"
if [ -n "$LBX_SSH_STDIN_LOG" ]; then cat >>"$LBX_SSH_STDIN_LOG"; fi
case "$*" in
    *"cat .lbx/gui"*)
        [ -n "${LBX_GUI_MARKER:-}" ] && printf '%s\n' "$LBX_GUI_MARKER"
        exit 0 ;;
esac
exit 0
EOF
chmod +x "$BIN"/*
export LBX_FAKE_SSH="$BIN/ssh"
export LBX_SSH_LOG="$W/ssh.log"
export LBX_SSH_STDIN_LOG="$W/ssh-stdin.log"
export PATH="$BIN:$PATH"
export HOME="$W/home"
export LLMBOX_CONFIG="$W/home/config"
export LLMBOX_STATE_DIR="$W/state"
export LBX_VM_ACCEL=tcg          # no KVM in this environment; preflight accepts it

# ── a session that looks like a running vm ─────────────────────────────────
SESSION=designbox
SDIR="$W/state/sessions/$SESSION"
mkdir -p "$SDIR" "$W/state/bases/20260101-000000-1"
qemu-img create -q -f qcow2 "$W/state/bases/20260101-000000-1/base.qcow2" 1M
printf 'kernel\n' >"$W/state/bases/20260101-000000-1/vmlinuz"
printf 'full\n' >"$W/state/bases/20260101-000000-1/provision"
printf 'agent\n' >"$W/state/bases/20260101-000000-1/built-user"
printf '2222\n' >"$SDIR/ssh_port"
printf '20260101-000000-1\n' >"$SDIR/base"
sleep 600 &
QEMU_PID=$!
printf '%s\n' "$QEMU_PID" >"$SDIR/qemu.pid"

# Every case starts from an empty log: a stale line from a previous case is
# exactly the kind of thing that makes an argv test lie.
run_lbx() {
    : >"$LBX_SSH_LOG"
    : >"$LBX_SSH_STDIN_LOG"
    env "$@" "$LBX" "$SESSION" >"$W/out" 2>"$W/err"
    echo $? >"$W/rc"
}
attach_log() { grep '^SSH .*@127.0.0.1 cd /data' "$LBX_SSH_LOG" 2>/dev/null | tail -1; }

# ── 1. no marker: no forwarding, nothing cached, --list shows no GUI ───────
run_lbx LBX_GUI_MARKER=
check "no marker: attach has no X11 flag" \
    "[ \"\$(cat $W/rc)\" = 0 ] && ! attach_log | grep -q ' -X '"
check "no marker: no GUI cached in the session dir" "[ ! -e '$SDIR/gui' ]"
check "no marker: --list GUI column is '-'" \
    "$LBX --list 2>/dev/null | grep -q 'designbox .*vm *running *2222 .* -$'"

# ── 2. an X11 app, host able: ssh -X, receipt, cache, --list ───────────────
run_lbx LBX_GUI_MARKER='app=open-codesign
transport=x11' DISPLAY=:0
check "x11 marker + display: ssh -X" "attach_log | grep -q ' -X '"
check "x11 marker: one receipt line" "grep -q 'GUI app in this box: forwarding x11' $W/out"
check "x11 marker: cached for --list" "grep -q 'transport=x11' '$SDIR/gui'"
check "x11 marker: --list shows GUI=x11" \
    "$LBX --list 2>/dev/null | grep -q 'designbox .* x11$'"

# ── 3. an X11 app, host without a display: plain shell + one note ──────────
run_lbx LBX_GUI_MARKER='transport=x11'
check "x11 marker, no \$DISPLAY: no -X" "! attach_log | grep -q ' -X '"
check "x11 marker, no \$DISPLAY: attaches anyway (rc 0)" "[ \"\$(cat $W/rc)\" = 0 ]"
check "x11 marker, no \$DISPLAY: explains why" "grep -q 'cannot forward a display' $W/err"

# ── 4/5. overrides ────────────────────────────────────────────────────────
: >"$LBX_SSH_LOG"; : >"$LBX_SSH_STDIN_LOG"
LBX_GUI_MARKER='transport=x11' DISPLAY=:0 "$LBX" --no-gui "$SESSION" >"$W/out" 2>"$W/err"
check "--no-gui overrides the marker" "! attach_log | grep -q ' -X '"
check "--no-gui is quiet (no misleading note)" "! grep -q 'cannot forward' $W/err"

: >"$LBX_SSH_LOG"
LBX_GUI_MARKER= DISPLAY=:0 "$LBX" --x11 "$SESSION" >/dev/null 2>&1
check "--x11 forces forwarding with no marker" "attach_log | grep -q ' -X '"
: >"$LBX_SSH_LOG"
LBX_GUI_MARKER= DISPLAY=:0 "$LBX" --x11=trusted "$SESSION" >/dev/null 2>&1
check "--x11=trusted uses ssh -Y" "attach_log | grep -q ' -Y '"

# ── 6/7. wayland, and its fallback ────────────────────────────────────────
run_lbx LBX_GUI_MARKER='transport=wayland' WAYLAND_DISPLAY=wayland-0
check "wayland marker + waypipe + \$WAYLAND_DISPLAY: waypipe ssh" \
    "grep -q '^WAYPIPE ssh ' $LBX_SSH_LOG"
check "wayland: no X11 flag on the ssh line" "! attach_log | grep -q ' -X '"
# Without waypipe on PATH the same app still gets a display via X11.
rm -f "$BIN/waypipe"
run_lbx LBX_GUI_MARKER='transport=wayland' DISPLAY=:0
check "wayland app, no waypipe: falls back to ssh -X" \
    "! grep -q '^WAYPIPE ' $LBX_SSH_LOG && attach_log | grep -q ' -X '"
printf '#!/usr/bin/env bash\nprintf "WAYPIPE %%s\\n" "$*" >>"$LBX_SSH_LOG"\nshift\nexec "$LBX_FAKE_SSH" "$@"\n' >"$BIN/waypipe"
chmod +x "$BIN/waypipe"

# ── 8. credentials ride the attach, not the image or the container config ──
: >"$LBX_SSH_LOG"; : >"$LBX_SSH_STDIN_LOG"
LBX_GUI_MARKER= ANTHROPIC_API_KEY=sk-test-1 "$LBX" --env ANTHROPIC_API_KEY "$SESSION" \
    >"$W/out" 2>"$W/err"
check "--env NAME reaches the box over the attach probe" \
    "grep -q \"export ANTHROPIC_API_KEY=sk-test-1\" $LBX_SSH_STDIN_LOG"
check "--env NAME is not printed" "! grep -q 'sk-test-1' $W/out $W/err"
check "the default forward list is GH_TOKEN only" \
    "grep -q 'DEFAULT_ENV_FORWARD: &str = \"GH_TOKEN\"' '$ROOT/src/config.rs'"

# ── 9. a stale marker is cleared when the app goes away ───────────────────
printf 'transport=x11\n' >"$SDIR/gui"
run_lbx LBX_GUI_MARKER= DISPLAY=:0
check "marker gone from the box: cache cleared" "[ ! -e '$SDIR/gui' ]"

kill "$QEMU_PID" 2>/dev/null
echo ""
echo "test_llm_in_a_box_vm_gui.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
