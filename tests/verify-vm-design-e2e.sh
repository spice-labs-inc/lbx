#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-vm-design-e2e.sh — the full optional-GUI-app cycle in a real vm box:
#
#   1. build a slim vm image + base, boot it;
#   2. `lbx-setup design` installs Open CoDesign from its GitHub release
#      (download resolved by the step itself — no hand-supplied .deb);
#   3. the app actually opens a window on the HOST's X server through the
#      attach's X11 forwarding (proved with xlsclients, not by argv);
#   4. `lbx --shutdown`, then `lbx` again: the app is still installed, the GUI
#      marker survived, the attach says it is forwarding, and the app connects
#      again after the reboot.
#
# Everything the user reported is an assertion here: the package installs
# unattended, the marker survives a stop/start, and X11 really carries pixels.
#
# Needs: docker, qemu-system-x86_64, qemu-img, ssh + key, Xvfb, xlsclients.
# Uses tcg when KVM is not usable (slow). Skips with guidance if a hard
# prerequisite is missing.
#
# Usage: bash tests/verify-vm-design-e2e.sh [--keep] [--no-build]
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LBX="${LBX_BIN:-$ROOT/target/debug/lbx}"
BUILD="$ROOT/build"
KEEP=0
DO_BUILD=1
for arg in "$@"; do
    case "$arg" in
        --keep) KEEP=1 ;;
        --no-build) DO_BUILD=0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

PASS=0
FAIL=0
check() {
    local description="$1" condition="$2"
    if eval "$condition"; then echo "[PASS] $description"; PASS=$((PASS + 1));
    else echo "[FAIL] $description"; FAIL=$((FAIL + 1)); fi
}
skip() { echo "[SKIP] $1"; }

[ -x "$LBX" ] || { echo "ERROR: no lbx binary at $LBX (cargo build first)." >&2; exit 1; }
for tool in docker qemu-system-x86_64 qemu-img ssh Xvfb xlsclients; do
    command -v "$tool" >/dev/null || { echo "SKIP: $tool is not installed"; exit 0; }
done
ls "$HOME"/.ssh/*.pub >/dev/null 2>&1 || { echo "SKIP: no ssh public key in ~/.ssh"; exit 0; }

if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    export LBX_VM_ACCEL=kvm LBX_VM_CPUS=8 LBX_VM_MEM=16384
else
    export LBX_VM_ACCEL=tcg LBX_VM_CPUS=4 LBX_VM_MEM=8192
fi

W="$(mktemp -d /tmp/lbx-vm-design-e2e.XXXXXX)"
NAME="e2e-design-$$"
DISPLAY_NUM=99
XVFB_PID=""
cleanup() {
    [ -n "$XVFB_PID" ] && kill "$XVFB_PID" 2>/dev/null
    if [ "$KEEP" = 1 ]; then echo "kept: $W (session $NAME)"; return; fi
    ( cd "$W/proj" 2>/dev/null && "$LBX" --destroy --runtime vm "$NAME" >/dev/null 2>&1 )
    rm -rf "$W"
}
trap cleanup EXIT

mkdir -p "$W/proj" "$W/state"
export LBX_STATE_DIR="$W/state" LLMBOX_STATE_DIR="$W/state"
export LBX_CONFIG="$W/config" LLMBOX_CONFIG="$W/config"

Xvfb ":$DISPLAY_NUM" -screen 0 1280x900x24 >"$W/xvfb.log" 2>&1 &
XVFB_PID=$!
sleep 2
DISPLAY=":$DISPLAY_NUM" xdpyinfo >/dev/null 2>&1 && echo "host X server :$DISPLAY_NUM up" || { echo "ERROR: Xvfb failed"; exit 1; }

echo ""
if [ "$DO_BUILD" = 1 ]; then
    echo "== 1. build + boot (image, base disk, guest)"
    ( cd "$W/proj" && LBX_BIN="$LBX" bash "$BUILD" --slim vm ) >"$W/build.log" 2>&1
    check "the slim vm image + base build" "[ $? -eq 0 ] || grep -q 'staged' $W/build.log"
else
    skip "image build (--no-build)"
fi
BOOT_T0=$(date +%s)
( cd "$W/proj" && "$LBX" --slim --runtime vm "$NAME" ) </dev/null >"$W/boot.log" 2>&1
echo "   (boot took $(( $(date +%s) - BOOT_T0 ))s)"
PORT="$(cat "$W/state/sessions/$NAME/ssh_port" 2>/dev/null)"
check "the guest boots" "[ -n '$PORT' ]"
[ -n "$PORT" ] || { echo "no ssh port"; exit 1; }

# A single command STRING, not an array: the checks below pass the whole
# command as one argument to `check`/`eval`, and an array expansion silently
# gave it only the first word ("ssh"), which produced ssh usage errors instead
# of results.
SSH_CMD="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p $PORT $USER@127.0.0.1"

echo ""
echo "== 2. lbx-setup design (downloads the release, installs it, writes the marker)"
# `lbx-setup design` is a named step, so it needs no menu answer and no tty:
# a plain non-interactive ssh run. (Large installs take minutes; the guest's
# apt and the 66-90 MB .deb dominate.)
$SSH_CMD 'timeout 1500 lbx-setup design' >"$W/design.log" 2>&1
DESIGN_RC=$?
check "the step resolved a release asset" "grep -qE 'release asset: https' $W/design.log"
check "the step reports success (rc 0)" "[ $DESIGN_RC -eq 0 ]"
check "the step installed a package" "grep -q 'provision: installing open-codesign' $W/design.log || grep -q 'already installed' $W/design.log"
check "the app binary exists in the box" "$SSH_CMD 'test -x /opt/open-codesign/open-codesign || command -v open-codesign'"
check "the marker is written" "$SSH_CMD 'grep -q transport= \$HOME/.lbx/gui'"
check "the provisioning log records the step" "$SSH_CMD 'grep -q design \$HOME/.lbx/provisioned.log'"

echo ""
echo "== 2b. the OS keychain (safeStorage) really works"
# Electron's safeStorage needs a running secret service with an unlocked
# collection; `secret-tool` is the same libsecret path, so a round-trip here is
# the assertion that the app will not fail with
# "OS keychain (secure storage) is not available".
# The wrapper is what the app runs through, so assert ITS contract: it hands
# Electron a store that does not refuse to save keys. `--password-store=basic`
# is Chromium's documented fallback when no OS keychain is usable (a headless
# box cannot unlock one: gnome-keyring activates a GTK prompter and leaves the
# collection locked — measured).
$SSH_CMD 'grep -q -- "--password-store=gnome-libsecret" /usr/local/bin/open-codesign && echo STORE_ARG_OK' >"$W/keyring.out" 2>&1
check "the wrapper names the libsecret backend" "grep -q STORE_ARG_OK $W/keyring.out"
# The real assertion: the SAME Electron build, running a minimal safeStorage
# probe (tests/fixtures/electron-safestorage-probe), must report a usable store
# inside this VM — that is exactly what the app needs to save an API key.
# Use the INSTALLED app's own Electron build, with resources/app.asar swapped
# for the probe, and the wrapper's bootstrap (a tty-less ssh session has no
# DBUS_SESSION_BUS_ADDRESS; the daemon and the client must share the bus the
# wrapper creates — measured: without it, available=false even when the backend
# is selected).
cat >"$W/probe-run.sh" <<'PROBE_SCRIPT'
set -e
APP=$(readlink -f /usr/bin/open-codesign)
DIR=$(dirname "$APP")
D=/tmp/ocd-probe
rm -rf "$D"; cp -a "$DIR/." "$D/"
rm -rf "$D/resources/app.asar" "$D/resources/app"
cp -a /tmp/safestorage-probe "$D/resources/app"
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    exec dbus-run-session -- sh "$0"
fi
eval "$(printf '\n' | gnome-keyring-daemon --unlock --components=secrets 2>/dev/null)" || true
exec "$D/$(basename "$APP")" --no-sandbox --password-store=gnome-libsecret
PROBE_SCRIPT
scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P "$PORT" -r \
    "$ROOT/tests/fixtures/electron-safestorage-probe" "$USER@127.0.0.1:/tmp/safestorage-probe" >/dev/null 2>&1
scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P "$PORT" \
    "$W/probe-run.sh" "$USER@127.0.0.1:/tmp/probe-run.sh" >/dev/null 2>&1
DISPLAY=":$DISPLAY_NUM" timeout 240 $SSH_CMD -X 'sh /tmp/probe-run.sh 2>/dev/null | grep PROBE' >"$W/probe.out" 2>&1
echo "   probe: $(cat "$W/probe.out" 2>/dev/null | head -1)"
check "safeStorage is available in the box (probe: available=true)" "grep -q 'available=true' $W/probe.out"
check "and the probe round-trips a secret" "grep -q 'roundtrip=true' $W/probe.out"
check "with the libsecret backend" "grep -q 'backend=gnome_libsecret' $W/probe.out"
check "the wrapper is installed in /usr/local/bin" "$SSH_CMD 'test -x /usr/local/bin/open-codesign'"
check "the wrapper names a real app binary" "$SSH_CMD 'grep -q \"/opt/open-codesign\|open-codesign\" /usr/local/bin/open-codesign && ! grep -q \"exec /usr/local/bin\" /usr/local/bin/open-codesign'"

echo ""
echo "== 2c. the system browser the exporters need"
# The app's own rule: google-chrome-stable | google-chrome | chromium-browser |
# chromium | microsoft-edge, or CODESIGN_CHROME_PATH. Ubuntu's chromium-browser
# is a snap stub, so a *real* Chrome must be what `which` finds.
$SSH_CMD 'for b in google-chrome-stable google-chrome chromium-browser chromium microsoft-edge; do p=$(command -v "$b" 2>/dev/null) && echo "FOUND $b=$p"; done' >"$W/chrome.out" 2>&1
check "a browser the app will find is installed" "grep -q '^FOUND ' $W/chrome.out"
check "it is a real Chrome, not the chromium snap stub" \
    "grep -qE '^FOUND (google-chrome-stable|google-chrome)=' $W/chrome.out"
# And the capability the app uses: a headless PDF print, with the app's own
# puppeteer args (note: it does NOT pass --no-sandbox, so the setuid helper has
# to work — that is part of what this asserts).
# Read the magic into a variable: `head | grep -q` is a SIGPIPE trap under
# `set -o pipefail` (it once reported a valid 66 MB .deb as "not a package").
$SSH_CMD 'B=$(command -v google-chrome-stable || command -v google-chrome)
    cd /tmp; rm -f probe.pdf
    timeout 120 "$B" --headless=new --disable-dev-shm-usage --disable-gpu \
        --no-first-run --no-default-browser-check \
        --print-to-pdf=/tmp/probe.pdf about:blank >/dev/null 2>&1
    magic="$(head -c 5 /tmp/probe.pdf 2>/dev/null || true)"
    [ "$magic" = "%PDF-" ] && echo PDF_OK' >"$W/chrome-pdf.out" 2>&1
check "headless PDF export works with the app's arguments" "grep -q PDF_OK $W/chrome-pdf.out"

echo ""
echo "== 3. it renders on the HOST's X server through ssh -X"
# Launch the app inside an X-forwarded session and look at the host's X server
# while that session is still open (the X channel dies with the ssh session).
# The remote command must END: while the app holds the forwarded X channel,
# ssh does not return even after the shell exits (measured: the first version
# hung here forever). So: bound the session with `timeout`, and kill the app
# from inside once the client has been observed.
APP_CMD='cd /data; (nohup env LIBGL_ALWAYS_SOFTWARE=1 open-codesign --no-sandbox >/tmp/ocd.log 2>&1 &); for i in $(seq 1 25); do sleep 1; done; pkill -f "opt/open-codesign" 2>/dev/null; true'
DISPLAY=":$DISPLAY_NUM" timeout 60 $SSH_CMD -X "$APP_CMD" >"$W/app.log" 2>&1 &
APP_SSH=$!
sleep 14
CLIENTS="$(DISPLAY=":$DISPLAY_NUM" xlsclients 2>/dev/null)"
echo "   xlsclients: ${CLIENTS:-<none>}"
check "the app opened a window on the host's X server" "[ -n '$CLIENTS' ]"
wait $APP_SSH 2>/dev/null || true
[ -n "$CLIENTS" ] || { echo "   (guest app log)"; $SSH_CMD 'tail -15 /tmp/ocd.log' 2>&1 | sed 's/^/     /'; }
check "the app did not report a missing keychain" \
    "! $SSH_CMD 'grep -qi \"keychain\" /tmp/ocd.log' 2>/dev/null"

echo ""
echo "== 4. stop the vm, start it again, and check the app survived and still works"
( cd "$W/proj" && "$LBX" --shutdown "$NAME" ) >"$W/shutdown.log" 2>&1
check "the vm shuts down cleanly" "grep -qE 'shut ?down|Removed|poweroff' $W/shutdown.log || [ $? -eq 0 ]"
BOOT2_T0=$(date +%s)
( cd "$W/proj" && DISPLAY=":$DISPLAY_NUM" "$LBX" --slim --runtime vm "$NAME" ) </dev/null >"$W/reboot.log" 2>&1
echo "   (resume took $(( $(date +%s) - BOOT2_T0 ))s)"
PORT2="$(cat "$W/state/sessions/$NAME/ssh_port" 2>/dev/null)"
check "it comes back on an ssh port" "[ -n '$PORT2' ]"
SSH2_CMD="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p ${PORT2:-$PORT} $USER@127.0.0.1"
check "the app is still installed after the restart" \
    "$SSH2_CMD 'test -x /opt/open-codesign/open-codesign || command -v open-codesign'"
check "the GUI marker survived the restart" "$SSH2_CMD 'grep -q transport= \$HOME/.lbx/gui'"
check "the attach says it is forwarding X11" "grep -q 'forwarding x11' $W/reboot.log"
APP2_CMD='cd /data; (nohup env LIBGL_ALWAYS_SOFTWARE=1 open-codesign --no-sandbox >/tmp/ocd2.log 2>&1 &); for i in $(seq 1 25); do sleep 1; done; pkill -f "opt/open-codesign" 2>/dev/null; true'
DISPLAY=":$DISPLAY_NUM" timeout 60 $SSH2_CMD -X "$APP2_CMD" >"$W/app2.log" 2>&1 &
APP2_SSH=$!
sleep 14
CLIENTS2="$(DISPLAY=":$DISPLAY_NUM" xlsclients 2>/dev/null)"
echo "   xlsclients after restart: ${CLIENTS2:-<none>}"
check "the app connects again after the restart" "[ -n '$CLIENTS2' ]"
wait $APP2_SSH 2>/dev/null || true

echo ""
echo "verify-vm-design-e2e.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
