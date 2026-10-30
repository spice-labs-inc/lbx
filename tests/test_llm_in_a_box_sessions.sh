#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_llm_in_a_box_sessions.sh — behavioral tests for cross-runtime
# session management (plan 2026_09_03_session_management_and_cross_runtime_ops).
#
# WHAT (no source grep — invariant 12):
#   Phase 1 — cross-runtime resolution & no parallel instances:
#     T1: an existing docker container named X wins over auto-detection
#         even when the vm image is built (the reported bug: auto-detect
#         picked vm and created a PARALLEL vm session next to a sysbox
#         instance).
#     T2: an existing vm session (live qemu) is attached to, not
#         re-launched, when the vm image is built.
#     T3/T4: an explicit --runtime that conflicts with an existing
#         instance of another runtime errors with guidance instead of
#         creating a parallel instance (both directions).
#     T5: legacy duplicates (same name in vm AND docker) are reported as
#         ambiguous with --runtime disambiguation guidance (D2).
#   Phase 4 (2026-09-08, launch disambiguation R6):
#     T32: launch/attach with --runtime <member> on an ambiguous name
#         selects that instance (the 09-06 fix covered destroy/stop/
#         shutdown only; the default action still died on the ambiguity
#         error even when --runtime named a member — the reported bug,
#         `lbx --runtime vm <name>`).
#     T33: the container direction of the same fix (attach, no error).
#     T34: a valid --runtime OUTSIDE the pair is an error naming the
#         pair (launch mirror of T25), nothing touched.
#     T14: invalid session names are rejected before any side effect.
#
# WHY: a session name must map to at most ONE instance across runtimes
#      (user requirement 2026-09-03). Attach-to-existing logic already
#      worked AFTER runtime selection — the bug was runtime SELECTION
#      never consulting the other runtimes' instance lists. The name
# validation closes a path-traversal foot-gun (names flow into
# $LLMBOX_STATE_DIR/sessions/<name>).
#
# LLM-FRIENDLY NOTE: container-side checks use a real docker daemon and
# the llm-in-a-box:docker image (skip-not-fail when absent); vm-side
# checks use scratch fixture dirs. lbx keeps HOST-SIDE VM STATE in
# $LLMBOX_STATE_DIR (ADR 013): the session dir (origin, ssh_port, qemu.pid,
# base record, seed) AND the overlay disk live under its sessions/ tree,
# while the project directory that the box mounts as /data keeps only the
# Docker store image and the first-reader message. Each vm-side check runs
# lbx with cwd=<fixture> and LLMBOX_STATE_DIR=<fixture>, so both point at the
# same fixture: <fixture>/sessions/<name>/overlay.qcow2. T6/T7 assert on mount
# paths, so their state dir sits beside the fixture instead of inside it.
# Fake qemu processes come from the spawn_fake_qemu pattern in
# test_llm_in_a_box_vm.sh (a real sh process whose cmdline looks like qemu
# so pgrep can find it).
# ---------------------------------------------------------------------------
set -uo pipefail

# A plain umask (2026-10-25): fixtures that write config files the launcher
# reads must not inherit a group-writable umask — `lbx` refuses a config that
# group or others can write. See tests/run-all-suites.sh for the measurement.
umask 022

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOC="${LBX_BIN:-${SCRIPT_DIR}/../target/debug/lbx}"
export LLMBOX_SCRIPT_DIR="$SCRIPT_DIR/.."

# Checks that do not name a fixture still must never read or write the
# invoking user's real box state (~/.llm-in-a-box), so the whole run gets
# a private default that is removed on exit.
SESS_DEFAULT_STATE="$(mktemp -d /tmp/llm-in-a-box-sess-state.XXXXXX)"
export LLMBOX_STATE_DIR="$SESS_DEFAULT_STATE"
trap 'rm -rf "$SESS_DEFAULT_STATE"' EXIT

PASS=0
FAIL=0
SKIP=0

check() {
    local description="$1"
    local condition="$2"
    if eval "$condition"; then
        echo "[PASS] $description"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $description"
        FAIL=$((FAIL + 1))
    fi
}

skip() {
    echo "[SKIP] $1"
    SKIP=$((SKIP + 1))
}

# A killed process is dead when kill -0 fails OR it is a zombie (state Z).
# This box's PID 1 is `sleep infinity`, which never reaps, so a killed fake
# qemu lingers as a zombie that kill -0 still reports as alive. The checks
# keep their meaning: the process is dead (not running), zombie included.
proc_dead() {
    ! kill -0 "$1" 2>/dev/null \
        || [ "$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')" = "Z" ]
}

# A "built" vm image = base.qcow2 + vmlinuz in the launcher's STATE
# directory (ADR 013). $dir doubles as the state directory (the checks pass
# LLMBOX_STATE_DIR=$dir) and as the project directory / cwd, so the base sits
# at $dir/base.qcow2 and the project artifacts ($dir/vms_and_docker_from_llm_box)
# just hold the store image and README. Real (tiny) qcow2 via qemu-img when
# available.
make_vm_fixture() {
    local dir="$1"
    rm -rf "$dir"
    mkdir -p "$dir/vms_and_docker_from_llm_box"
    if command -v qemu-img >/dev/null 2>&1; then
        qemu-img create -f qcow2 "$dir/base.qcow2" 1M >/dev/null
    else
        touch "$dir/base.qcow2"
    fi
    touch "$dir/vmlinuz"
}

make_versioned_fixture() {
    local dir="$1"
    rm -rf "$dir"
    mkdir -p "$dir/bases/ts1" "$dir/bases/ts2" "$dir/vms_and_docker_from_llm_box"
    qemu-img create -f qcow2 "$dir/bases/ts1/base.qcow2" 1M >/dev/null
    qemu-img create -f qcow2 "$dir/bases/ts2/base.qcow2" 1M >/dev/null
    touch "$dir/bases/ts1/vmlinuz" "$dir/bases/ts2/vmlinuz"
    # Box-user era stamps (2026-09-20): ./build vm stamps every base; lbx
    # refuses to boot an unmarked (old) base.
    echo agent > "$dir/bases/ts1/built-user"
    echo agent > "$dir/bases/ts2/built-user"
    ln -sfn ts2 "$dir/bases/latest"
}

# Fake qemu: a REAL binary (sh) whose argv[0] is qemu-system-x86_64 and
# whose argv contains the overlay path — the kernel rewrites argv[0] to the
# interpreter for shebang scripts, so exec -a is required for pgrep to see
# the name. Traps TERM so graceful stops take effect promptly.
spawn_fake_qemu() {
    bash -c 'exec -a qemu-system-x86_64 sh -c "trap \"exit 0\" TERM INT; while :; do sleep 0.1; done" x "$0"' "$1" >/dev/null 2>&1 </dev/null &
    echo $!
}

HAVE_DOCKER_IMAGE=0
docker image inspect llm-in-a-box:docker >/dev/null 2>&1 && HAVE_DOCKER_IMAGE=1

start_test_container() {
    local name="$1"
    docker run -d --name "$name" --hostname "$name" \
        -e HOST_USER="$(whoami)" -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
        -v /tmp:/data \
        llm-in-a-box:docker sleep infinity >/dev/null 2>&1
    # wait for running state
    for _ in $(seq 1 30); do
        [ "$(docker container inspect -f '{{.State.Status}}' "$name" 2>/dev/null)" = "running" ] && return 0
        sleep 1
    done
    return 1
}

CNAME="llm-in-a-box-sess-$$"

# ── T14: name validation (no docker/kvm needed) ─────────────────────────────
# Requirement: names flow into <project>/sessions/
# <name> — reject anything outside [A-Za-z0-9][A-Za-z0-9._-]* BEFORE touching
# the filesystem or docker.
check "path-traversal session name is rejected before any action" \
    "mkdir -p /tmp/llm-in-a-box-sess-fix && cd /tmp/llm-in-a-box-sess-fix && LLMBOX_STATE_DIR=/tmp/llm-in-a-box-sess-fix '$BOC' '../evil' >/tmp/llm-in-a-box-sess-n1.log 2>&1; [ \$? -ne 0 ] \
        && grep -q 'Invalid session name' /tmp/llm-in-a-box-sess-n1.log \
        && [ ! -e /tmp/llm-in-a-box-sess-fix/sessions/../evil ]"

check "name with a slash is rejected" \
    "'$BOC' 'a/b' >/tmp/llm-in-a-box-sess-n2.log 2>&1; [ \$? -ne 0 ] \
        && grep -q 'Invalid session name' /tmp/llm-in-a-box-sess-n2.log"

# ── T1: existing docker container wins over vm auto-detection ──────────────
if [ "$HAVE_DOCKER_IMAGE" = 1 ]; then
    make_vm_fixture /tmp/llm-in-a-box-sess-vmfix
    start_test_container "$CNAME" || { skip "existing-container-wins check (container did not start)"; CNAME_SKIP=1; }
    if [ "${CNAME_SKIP:-0}" = 0 ]; then
        # LLMBOX_VM_MISSING keeps any (wrong) vm attempt failing fast.
        check "existing docker container is attached to instead of creating a parallel vm" \
            "cd /tmp/llm-in-a-box-sess-vmfix && LLMBOX_VM_MISSING='qemu-system-x86_64' LLMBOX_STATE_DIR=/tmp/llm-in-a-box-sess-vmfix '$BOC' '$CNAME' </dev/null >/tmp/llm-in-a-box-sess-t1.log 2>&1 || true; \
                grep -q 'Found existing docker session' /tmp/llm-in-a-box-sess-t1.log \
                && grep -q 'Attaching to running container' /tmp/llm-in-a-box-sess-t1.log \
                && ! grep -q 'Auto-detected runtime: vm' /tmp/llm-in-a-box-sess-t1.log \
                && [ ! -d /tmp/llm-in-a-box-sess-vmfix/sessions/$CNAME ]"
        docker rm -f "$CNAME" >/dev/null 2>&1 || true
    fi
else
    skip "existing docker container is attached to instead of creating a parallel vm (no docker / llm-in-a-box:docker image)"
fi

# ── T2: existing vm session (live qemu) is attached to ─────────────────────
# Skip-not-fail without full vm prerequisites (attach runs vm_preflight,
# which is unchanged by this plan).
if command -v qemu-system-x86_64 >/dev/null 2>&1 && [ -e /dev/kvm ] \
        && id -nG | grep -w >/dev/null kvm && command -v ssh >/dev/null 2>&1; then
    FIXVM=/tmp/llm-in-a-box-sess-vmfix2
    make_vm_fixture "$FIXVM"
    mkdir -p "$FIXVM/sessions/llm-in-a-box-sess-vm" "$FIXVM/sessions/llm-in-a-box-sess-vm"
    touch "$FIXVM/sessions/llm-in-a-box-sess-vm/overlay.qcow2"
    echo 999999 > "$FIXVM/sessions/llm-in-a-box-sess-vm/qemu.pid"
    FAKE_PID=$(spawn_fake_qemu "$FIXVM/sessions/llm-in-a-box-sess-vm/overlay.qcow2")
    sleep 0.5
    check "existing vm session is attached to instead of re-launched" \
        "cd '$FIXVM' && LLMBOX_STATE_DIR='$FIXVM' '$BOC' llm-in-a-box-sess-vm </dev/null >/tmp/llm-in-a-box-sess-t2.log 2>&1 || true; \
            grep -q 'Found existing vm session' /tmp/llm-in-a-box-sess-t2.log \
            && grep -q 'Attaching to running vm' /tmp/llm-in-a-box-sess-t2.log"
    kill "$FAKE_PID" 2>/dev/null || true
    rm -rf "$FIXVM"
else
    skip "existing vm session is attached to instead of re-launched (need qemu + /dev/kvm + kvm group)"
fi

# ── T3/T4: explicit conflicting --runtime errors instead of parallel start ──
if [ "$HAVE_DOCKER_IMAGE" = 1 ]; then
    make_vm_fixture /tmp/llm-in-a-box-sess-vmfix3
    start_test_container "$CNAME" || { skip "explicit-runtime conflict check (container did not start)"; CNAME_SKIP=1; }
    if [ "${CNAME_SKIP:-0}" = 0 ]; then
        check "explicit --runtime vm conflicts with an existing docker instance" \
            "cd /tmp/llm-in-a-box-sess-vmfix3 && LLMBOX_VM_MISSING='qemu-system-x86_64' LLMBOX_STATE_DIR=/tmp/llm-in-a-box-sess-vmfix3 '$BOC' --runtime vm '$CNAME' </dev/null >/tmp/llm-in-a-box-sess-t3.log 2>&1; [ \$? -ne 0 ] \
                && grep -q 'already exists as a docker' /tmp/llm-in-a-box-sess-t3.log \
                && [ ! -d /tmp/llm-in-a-box-sess-vmfix3/sessions/$CNAME ]"
        docker rm -f "$CNAME" >/dev/null 2>&1 || true
    fi
else
    skip "explicit --runtime vm conflicts with an existing docker instance (no docker / image)"
fi

FIXVM4=/tmp/llm-in-a-box-sess-vmfix4
rm -rf "$FIXVM4" && mkdir -p "$FIXVM4/sessions/llm-in-a-box-sess-vm4"
touch "$FIXVM4/sessions/llm-in-a-box-sess-vm4/overlay.qcow2"
check "explicit --runtime docker conflicts with an existing vm instance" \
    "cd '$FIXVM4' && LLMBOX_STATE_DIR='$FIXVM4' '$BOC' --runtime docker llm-in-a-box-sess-vm4 </dev/null >/tmp/llm-in-a-box-sess-t4.log 2>&1; [ \$? -ne 0 ] \
        && grep -q 'already exists as a vm' /tmp/llm-in-a-box-sess-t4.log"
if command -v docker >/dev/null 2>&1; then
    check "explicit conflicting runtime created no container" \
        "! docker container inspect llm-in-a-box-sess-vm4 >/dev/null 2>&1"
    docker rm -f llm-in-a-box-sess-vm4 >/dev/null 2>&1 || true
fi
rm -rf "$FIXVM4"

# ── T5: legacy duplicates are ambiguous, never auto-resolved ───────────────
if [ "$HAVE_DOCKER_IMAGE" = 1 ]; then
    FIXDUP=/tmp/llm-in-a-box-sess-dupf
    make_vm_fixture "$FIXDUP"
    mkdir -p "$FIXDUP/sessions/llm-in-a-box-sess-dup" "$FIXDUP/sessions/llm-in-a-box-sess-dup"
    touch "$FIXDUP/sessions/llm-in-a-box-sess-dup/overlay.qcow2"
    start_test_container llm-in-a-box-sess-dup || { skip "legacy-duplicate ambiguity check (container did not start)"; DUP_SKIP=1; }
    if [ "${DUP_SKIP:-0}" = 0 ]; then
        check "legacy duplicate name errors with --runtime disambiguation guidance" \
            "cd '$FIXDUP' && LLMBOX_STATE_DIR='$FIXDUP' '$BOC' llm-in-a-box-sess-dup </dev/null >/tmp/llm-in-a-box-sess-t5.log 2>&1; [ \$? -ne 0 ] \
                && grep -q 'multiple runtimes' /tmp/llm-in-a-box-sess-t5.log \
                && grep -q -- '--runtime' /tmp/llm-in-a-box-sess-t5.log \
                && grep -q 'vm' /tmp/llm-in-a-box-sess-t5.log \
                && grep -q 'docker' /tmp/llm-in-a-box-sess-t5.log"
        docker rm -f llm-in-a-box-sess-dup >/dev/null 2>&1 || true
    fi
    rm -rf "$FIXDUP"
else
    skip "legacy duplicate name errors with --runtime disambiguation guidance (no docker / image)"
fi

# ══ Phase 2 (plan 2026_09_03): vm origin directory + --list ═══════════════

# T6/T7 need a PATH-shimmed qemu that records its argv (so the test can
# observe the host0 virtfs path) and speaks just enough ssh banner on the
# hostfwd port for vm_wait_ssh to return promptly. The banner loop uses
# nc -l; when nc is absent these two checks skip.
QSHIMDIR=/tmp/llm-in-a-box-qshim
rm -rf "$QSHIMDIR" && mkdir -p "$QSHIMDIR"
QSHIMLOG=/tmp/llm-in-a-box-qshim.log
rm -f "$QSHIMLOG"
cat > "$QSHIMDIR/qemu-system-x86_64" <<'QSHIMEOF'
#!/usr/bin/env bash
# lbx's preflight reads the qemu version (floor 5.0 for -device nvme) and
# refuses to launch when it cannot parse one. Answered before the argv log
# so the checks that require an empty log (no boot attempted) stay valid.
if [ "${1:-}" = "--version" ]; then
    echo "QEMU emulator version 8.2.2 (fake)"
    exit 0
fi
printf 'QEMUARGS %s\n' "$*" >> "${SHIMLOG:?}"
port=$(printf '%s' "$*" | sed -n 's/.*hostfwd=tcp::\([0-9][0-9]*\)-:22.*/\1/p')
if [ -n "$port" ]; then
    # Serve just enough of an ssh banner on the hostfwd port for
    # vm_wait_ssh's banner probe to return promptly. nc proved unreliable
    # for this (backgrounded listeners died with the shim's exit); a small
    # python server is deterministic. Use `python3 -c` (NOT a heredoc-fed
    # backgrounded python — that pattern hung the shim itself) and detach
    # stdin so the orphaned listener never blocks the shim's exit.
    python3 -c '
import socket, sys
try:
    port = int(sys.argv[1])
except (IndexError, ValueError):
    sys.exit(0)
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(5)
while True:
    c, _ = s.accept()
    try:
        c.sendall(b"SSH-2.0-llm-in-a-box-qshim\r\n")
    finally:
        c.close()
' "$port" </dev/null >/dev/null 2>&1 &
fi
exit 0
QSHIMEOF
chmod +x "$QSHIMDIR/qemu-system-x86_64"

have_qshim=0
command -v python3 >/dev/null 2>&1 && have_qshim=1

# T6: a vm session records its launch directory at creation and RELAUNCHES
# with that recorded directory — not the current working directory. Box
# status must live in a stable location so a re-launch from a different
# directory picks up the originally-launched directory (user requirement
# 2026-09-03). Since ADR 013 the state directory (and with it the base and
# the overlay) is resolved from LLMBOX_STATE_DIR alone, so the launcher is
# run from a THIRD directory that is neither the recorded origin nor the
# state directory: host0 must still mount the RECORDED origin. T6 and T7
# boot, so their fixture is the stamped versioned layout ./build vm
# produces: lbx refuses to boot the unstamped flat layout.
if [ "$have_qshim" = 1 ] && command -v qemu-img >/dev/null 2>&1 && [ -e /dev/kvm ] \
        && id -nG | grep -w >/dev/null kvm; then
    FIXO=/tmp/llm-in-a-box-sess-origin
    # The state dir lives outside FIXO (and its name does not start with
    # FIXO): the seed0 mount exports the session state dir, so a state dir
    # under FIXO would put path=FIXO... in the argv whatever host0 mounts.
    STATEO=/tmp/llm-in-a-box-sess-t6state
    rm -rf "$STATEO"
    make_versioned_fixture "$STATEO"
    mkdir -p "$STATEO/sessions/llm-in-a-box-sess-origin" "$FIXO" /tmp/llm-in-a-box-t6-cwd
    touch "$STATEO/sessions/llm-in-a-box-sess-origin/overlay.qcow2"
    mkdir -p /tmp/llm-in-a-box-origin-dir
    echo /tmp/llm-in-a-box-origin-dir > "$STATEO/sessions/llm-in-a-box-sess-origin/origin"
    rm -f "$QSHIMLOG"
    check "vm relaunch mounts the RECORDED origin directory, not the current pwd" \
        "cd /tmp/llm-in-a-box-t6-cwd && SHIMLOG=$QSHIMLOG PATH=$QSHIMDIR:\$PATH LLMBOX_STATE_DIR='$STATEO' '$BOC' --runtime vm llm-in-a-box-sess-origin </dev/null >/tmp/llm-in-a-box-sess-t6.log 2>&1 || true; \
            grep -q 'path=/tmp/llm-in-a-box-origin-dir' $QSHIMLOG \
            && ! grep -q 'path=$FIXO' $QSHIMLOG \
            && ! grep -q 'path=/tmp/llm-in-a-box-t6-cwd' $QSHIMLOG"
    rm -rf "$FIXO" "$STATEO" /tmp/llm-in-a-box-origin-dir /tmp/llm-in-a-box-t6-cwd
else
    skip "vm relaunch mounts the RECORDED origin directory (need python3 + qemu-img + /dev/kvm + kvm group)"
fi

# T7: a legacy session (no origin file) falls back to the current pwd AND
# records it for future relaunches.
if [ "$have_qshim" = 1 ] && command -v qemu-img >/dev/null 2>&1 && [ -e /dev/kvm ] \
        && id -nG | grep -w >/dev/null kvm; then
    FIXL=/tmp/llm-in-a-box-sess-legacy
    # State dir outside FIXL for the same reason as T6: otherwise the seed0
    # mount alone would satisfy the path=FIXL match. The base and the overlay
    # live in the state dir (ADR 013); cwd is still the origin fallback.
    STATEL=/tmp/llm-in-a-box-sess-t7state
    rm -rf "$STATEL"
    make_versioned_fixture "$STATEL"
    mkdir -p "$STATEL/sessions/llm-in-a-box-sess-legacy" "$FIXL"
    touch "$STATEL/sessions/llm-in-a-box-sess-legacy/overlay.qcow2"
    rm -f "$QSHIMLOG"
    check "legacy vm session (no origin file) mounts the current pwd" \
        "cd '$FIXL' && SHIMLOG=$QSHIMLOG PATH=$QSHIMDIR:\$PATH LLMBOX_STATE_DIR='$STATEL' '$BOC' --runtime vm llm-in-a-box-sess-legacy </dev/null >/tmp/llm-in-a-box-sess-t7.log 2>&1 || true; \
            grep -q 'path=$FIXL' $QSHIMLOG"
    rm -rf "$FIXL" "$STATEL"
else
    skip "legacy vm session (no origin file) mounts the current pwd (need python3 + qemu-img + /dev/kvm + kvm group)"
fi

# T8: --list shows one row per instance across runtimes, sorted by name,
# with the NAME/RUNTIME/STATE/PORT columns (D3).
if [ "$HAVE_DOCKER_IMAGE" = 1 ]; then
    FIXLST=/tmp/llm-in-a-box-sess-list
    make_vm_fixture "$FIXLST"
    mkdir -p "$FIXLST/sessions/llm-in-a-box-sess-listvm" "$FIXLST/sessions/llm-in-a-box-sess-listvm"
    touch "$FIXLST/sessions/llm-in-a-box-sess-listvm/overlay.qcow2"
    echo 2222 > "$FIXLST/sessions/llm-in-a-box-sess-listvm/ssh_port"
    start_test_container llm-in-a-box-sess-listc || { skip "--list cross-runtime rows (container did not start)"; LST_SKIP=1; }
    if [ "${LST_SKIP:-0}" = 0 ]; then
        cd $FIXLST && LLMBOX_STATE_DIR=$FIXLST "$BOC" --list >/tmp/llm-in-a-box-sess-t8.log 2>&1
        check "--list shows vm and docker rows with runtime/state/port columns" \
            "grep -qE '^llm-in-a-box-sess-listvm +vm +(exited|running) +2222' /tmp/llm-in-a-box-sess-t8.log \
                && grep -qE '^llm-in-a-box-sess-listc +docker +running +-' /tmp/llm-in-a-box-sess-t8.log"
        check "--list output is sorted by name" \
            "L1=\$(grep -n '^llm-in-a-box-sess-listc' /tmp/llm-in-a-box-sess-t8.log | cut -d: -f1); L2=\$(grep -n '^llm-in-a-box-sess-listvm' /tmp/llm-in-a-box-sess-t8.log | cut -d: -f1); [ \$L1 -lt \$L2 ]"
        docker rm -f llm-in-a-box-sess-listc >/dev/null 2>&1 || true
    fi
    rm -rf "$FIXLST"
else
    skip "--list cross-runtime rows (no docker / image)"
fi

# T9: --list never fails on an empty world, and takes no session name.
check "--list with no instances prints the header and exits 0" \
    "mkdir -p /tmp/llm-in-a-box-sess-empty && cd /tmp/llm-in-a-box-sess-empty &&  LLMBOX_STATE_DIR=/tmp/llm-in-a-box-sess-empty '$BOC' --list >/tmp/llm-in-a-box-sess-t9.log 2>&1; [ \$? -eq 0 ] \
        && grep -q 'NAME' /tmp/llm-in-a-box-sess-t9.log"
check "--list rejects a session name" \
    "mkdir -p /tmp/llm-in-a-box-sess-empty && cd /tmp/llm-in-a-box-sess-empty &&  LLMBOX_STATE_DIR=/tmp/llm-in-a-box-sess-empty '$BOC' --list foo >/tmp/llm-in-a-box-sess-t9b.log 2>&1; [ \$? -ne 0 ] \
        && grep -q 'takes no session name' /tmp/llm-in-a-box-sess-t9b.log"
rm -rf /tmp/llm-in-a-box-sess-empty

# ══ Phase 3 (plan 2026_09_03): multi-name --stop/--shutdown, --force,
#    cross-runtime --destroy ════════════════════════════════════════════════

# T10: --stop stops a container AND a vm in one invocation, gracefully.
if [ "$HAVE_DOCKER_IMAGE" = 1 ]; then
    FIXST=/tmp/llm-in-a-box-sess-stop
    make_vm_fixture "$FIXST"
    mkdir -p "$FIXST/sessions/llm-in-a-box-sess-stopvm" "$FIXST/sessions/llm-in-a-box-sess-stopvm"
    touch "$FIXST/sessions/llm-in-a-box-sess-stopvm/overlay.qcow2"
    echo 999999 > "$FIXST/sessions/llm-in-a-box-sess-stopvm/qemu.pid"
    echo 2231 > "$FIXST/sessions/llm-in-a-box-sess-stopvm/ssh_port"
    FAKE_STOP=$(spawn_fake_qemu "$FIXST/sessions/llm-in-a-box-sess-stopvm/overlay.qcow2")
    start_test_container llm-in-a-box-sess-stopc || { skip "--stop multi-name (container did not start)"; ST_SKIP=1; }
    if [ "${ST_SKIP:-0}" = 0 ]; then
        sleep 0.5
        cd $FIXST && LLMBOX_STATE_DIR=$FIXST "$BOC" --stop llm-in-a-box-sess-stopc llm-in-a-box-sess-stopvm >/tmp/llm-in-a-box-sess-t10.log 2>&1
        RC=$?
        check "--stop stops a container and a vm in one invocation (graceful, exit 0)" \
            "[ $RC -eq 0 ] \
                && grep -q 'Stopping container' /tmp/llm-in-a-box-sess-t10.log \
                && grep -q 'Stopped container' /tmp/llm-in-a-box-sess-t10.log \
                && [ \"\$(docker container inspect -f '{{.State.Status}}' llm-in-a-box-sess-stopc 2>/dev/null)\" = exited ] \
                && ! kill -0 $FAKE_STOP 2>/dev/null"
        docker rm -f llm-in-a-box-sess-stopc >/dev/null 2>&1 || true
    fi
    kill $FAKE_STOP 2>/dev/null || true
    rm -rf "$FIXST"
else
    skip "--stop stops a container and a vm in one invocation (no docker / image)"
fi

# T11: --force is the non-graceful variant for both runtimes.
if [ "$HAVE_DOCKER_IMAGE" = 1 ]; then
    FIXFT=/tmp/llm-in-a-box-sess-force
    make_vm_fixture "$FIXFT"
    mkdir -p "$FIXFT/sessions/llm-in-a-box-sess-forcevm" "$FIXFT/sessions/llm-in-a-box-sess-forcevm"
    touch "$FIXFT/sessions/llm-in-a-box-sess-forcevm/overlay.qcow2"
    echo 999999 > "$FIXFT/sessions/llm-in-a-box-sess-forcevm/qemu.pid"
    echo 2232 > "$FIXFT/sessions/llm-in-a-box-sess-forcevm/ssh_port"
    FAKE_FORCE=$(spawn_fake_qemu "$FIXFT/sessions/llm-in-a-box-sess-forcevm/overlay.qcow2")
    start_test_container llm-in-a-box-sess-forcec || { skip "--force check (container did not start)"; FT_SKIP=1; }
    if [ "${FT_SKIP:-0}" = 0 ]; then
        sleep 0.5
        cd $FIXFT && LLMBOX_STATE_DIR=$FIXFT "$BOC" --shutdown --force llm-in-a-box-sess-forcec llm-in-a-box-sess-forcevm >/tmp/llm-in-a-box-sess-t11.log 2>&1
        RC=$?
        check "--shutdown --force force-stops container and vm (non-graceful)" \
            "[ $RC -eq 0 ] \
                && grep -q 'Force-stopping container' /tmp/llm-in-a-box-sess-t11.log \
                && grep -q 'force-stopped' /tmp/llm-in-a-box-sess-t11.log \
                && [ \"\$(docker container inspect -f '{{.State.Status}}' llm-in-a-box-sess-forcec 2>/dev/null)\" = exited ] \
                && ! kill -0 $FAKE_FORCE 2>/dev/null"
        docker rm -f llm-in-a-box-sess-forcec >/dev/null 2>&1 || true
    fi
    kill $FAKE_FORCE 2>/dev/null || true
    rm -rf "$FIXFT"
else
    skip "--shutdown --force force-stops container and vm (no docker / image)"
fi

# T12: a missing name is reported, the other names are still processed,
# and the exit code signals the partial failure — while an all-missing
# invocation stays a clean no-op (historical single-name behavior).
if [ "$HAVE_DOCKER_IMAGE" = 1 ]; then
    start_test_container llm-in-a-box-sess-partc || { skip "partial-failure check (container did not start)"; PF_SKIP=1; }
    if [ "${PF_SKIP:-0}" = 0 ]; then
        mkdir -p /tmp/llm-in-a-box-sess-partfix && cd /tmp/llm-in-a-box-sess-partfix &&  LLMBOX_STATE_DIR=/tmp/llm-in-a-box-sess-partfix "$BOC" --stop does-not-exist llm-in-a-box-sess-partc >/tmp/llm-in-a-box-sess-t12.log 2>&1
        RC=$?
        check "missing name is reported, others still processed, exit non-zero" \
            "[ $RC -ne 0 ] \
                && grep -q \"does not exist\" /tmp/llm-in-a-box-sess-t12.log \
                && [ \"\$(docker container inspect -f '{{.State.Status}}' llm-in-a-box-sess-partc 2>/dev/null)\" = exited ]"
        docker rm -f llm-in-a-box-sess-partc >/dev/null 2>&1 || true
    fi
    check "all-missing --stop stays a clean no-op (exit 0)" \
        "mkdir -p /tmp/llm-in-a-box-sess-partfix && cd /tmp/llm-in-a-box-sess-partfix &&  LLMBOX_STATE_DIR=/tmp/llm-in-a-box-sess-partfix '$BOC' --stop does-not-exist >/tmp/llm-in-a-box-sess-t12b.log 2>&1; [ \$? -eq 0 ] \
            && grep -q \"does not exist\" /tmp/llm-in-a-box-sess-t12b.log"
else
    skip "partial-failure check (no docker / image)"
    check "all-missing --stop stays a clean no-op (exit 0)" \
        "mkdir -p /tmp/llm-in-a-box-sess-partfix && cd /tmp/llm-in-a-box-sess-partfix &&  LLMBOX_STATE_DIR=/tmp/llm-in-a-box-sess-partfix '$BOC' --stop does-not-exist >/tmp/llm-in-a-box-sess-t12b.log 2>&1; [ \$? -eq 0 ] \
            && grep -q \"does not exist\" /tmp/llm-in-a-box-sess-t12b.log"
fi
rm -rf /tmp/llm-in-a-box-sess-partfix

# T13: --destroy is cross-runtime for the single-name case.
if [ "$HAVE_DOCKER_IMAGE" = 1 ]; then
    make_vm_fixture /tmp/llm-in-a-box-sess-destfix
    start_test_container llm-in-a-box-sess-destc || { skip "cross-runtime --destroy (container did not start)"; DS_SKIP=1; }
    if [ "${DS_SKIP:-0}" = 0 ]; then
        check "--destroy removes a docker instance even when the vm image is built" \
            "cd /tmp/llm-in-a-box-sess-destfix &&  LLMBOX_STATE_DIR=/tmp/llm-in-a-box-sess-destfix '$BOC' --destroy llm-in-a-box-sess-destc >/tmp/llm-in-a-box-sess-t13.log 2>&1; [ \$? -eq 0 ] \
                && grep -q 'Removed container' /tmp/llm-in-a-box-sess-t13.log \
                && ! docker container inspect llm-in-a-box-sess-destc >/dev/null 2>&1"
    fi
    rm -rf /tmp/llm-in-a-box-sess-destfix
else
    skip "cross-runtime --destroy (no docker / image)"
fi

# ══ Phase B (versioned base images, 2026-09-03): newest-for-create,
#    recorded-for-relaunch, legacy fallback ═══════════════════════════════

# Earlier checks cd into fixture dirs and then delete them; anchor back to
# a stable directory so the script's $(pwd) calls cannot fail.
cd "$SCRIPT_DIR"

if [ "$have_qshim" = 1 ] && command -v qemu-img >/dev/null 2>&1 && [ -e /dev/kvm ] \
        && id -nG | grep -w >/dev/null kvm; then
    # T-newest: a NEW session uses the newest base and records it.
    FIXNB=/tmp/llm-in-a-box-sess-newbase
    make_versioned_fixture "$FIXNB"
    rm -f "$QSHIMLOG"
    check "a new vm session uses the newest base image and records it" \
        "cd $FIXNB && SHIMLOG=$QSHIMLOG PATH=$QSHIMDIR:\$PATH LLMBOX_STATE_DIR=$FIXNB '$BOC' llm-in-a-box-sess-newbase </dev/null >/tmp/llm-in-a-box-sess-tnew.log 2>&1 || true; \
            grep -q -- '-kernel $FIXNB/bases/ts2/vmlinuz' $QSHIMLOG \
            && [ \"\$(cat $FIXNB/sessions/llm-in-a-box-sess-newbase/base 2>/dev/null)\" = ts2 ] \
            && qemu-img info $FIXNB/sessions/llm-in-a-box-sess-newbase/overlay.qcow2 2>/dev/null | grep >/dev/null 'backing file: $FIXNB/bases/ts2/base.qcow2'"
    rm -rf "$FIXNB"

    # T-recorded: an existing session RELAUNCHES on its recorded base, not
    # the newest one (the overlay chains to the recorded base — rebasing a
    # live overlay onto a new base would corrupt the session).
    FIXRB=/tmp/llm-in-a-box-sess-recbase
    make_versioned_fixture "$FIXRB"
    mkdir -p "$FIXRB/sessions/llm-in-a-box-sess-recbase" "$FIXRB/sessions/llm-in-a-box-sess-recbase"
    echo ts1 > "$FIXRB/sessions/llm-in-a-box-sess-recbase/base"
    qemu-img create -f qcow2 -F qcow2 -b "$FIXRB/bases/ts1/base.qcow2" "$FIXRB/sessions/llm-in-a-box-sess-recbase/overlay.qcow2" >/dev/null
    rm -f "$QSHIMLOG"
    check "an existing vm session relaunches on its RECORDED base, not the newest" \
        "cd $FIXRB && SHIMLOG=$QSHIMLOG PATH=$QSHIMDIR:\$PATH LLMBOX_STATE_DIR=$FIXRB '$BOC' llm-in-a-box-sess-recbase </dev/null >/tmp/llm-in-a-box-sess-trec.log 2>&1 || true; \
            grep -q -- '-kernel $FIXRB/bases/ts1/vmlinuz' $QSHIMLOG \
            && ! grep -q 'ts2/vmlinuz' $QSHIMLOG"
    rm -rf "$FIXRB"

    # T-missing-record: a session whose recorded base was garbage-collected
    # must fail loud, never silently rebase onto the newest base.
    FIXMB=/tmp/llm-in-a-box-sess-missbase
    make_versioned_fixture "$FIXMB"
    mkdir -p "$FIXMB/sessions/llm-in-a-box-sess-missbase" "$FIXMB/sessions/llm-in-a-box-sess-missbase"
    echo tsX > "$FIXMB/sessions/llm-in-a-box-sess-missbase/base"
    rm -f "$QSHIMLOG"
    check "a session with a missing recorded base errors instead of rebasing" \
        "cd $FIXMB && SHIMLOG=$QSHIMLOG PATH=$QSHIMDIR:\$PATH LLMBOX_STATE_DIR=$FIXMB '$BOC' llm-in-a-box-sess-missbase </dev/null >/tmp/llm-in-a-box-sess-tmiss.log 2>&1; [ \$? -ne 0 ] \
            && grep -q 'no longer exists' /tmp/llm-in-a-box-sess-tmiss.log \
            && [ ! -s $QSHIMLOG ]"
    rm -rf "$FIXMB"
else
    skip "versioned-base session checks (need python3 + qemu-img + /dev/kvm + kvm group)"
fi

echo ""
# ═══════════════════════════════════════════════════════════════════════════
# Phase 1 — gap remediation 2026_09_06: destroy/stop runtime disambiguation
# for legacy-duplicate (ambiguous) sessions. Requirements R1-R5 + S6 of
# plans/2026_09_06_destroy_runtime_disambiguation/. Red-green unless
# marked GUARD (identical behavior before and after the fix — regression
# protection). Red runs are recorded in the plan's execution artifacts.
#
# THEORY (WHAT/WHY): a session name that maps to a vm session dir AND a
# docker container ("legacy duplicate", `waggle` on the user's host)
# cannot be destroyed/stopped today: the resolver reports
# ambiguous:vm,<container-rt> and the destroy/stop branches treat that as
# a fatal error while ignoring --runtime. The fix makes --runtime select
# the instance for destructive operations (R1/R2), keeps ambiguous
# without --runtime an error but with WORKING command forms in the
# guidance (R3), errors when an explicit runtime contradicts a UNIQUE
# instance instead of silently acting on the wrong one (R4), and rejects
# invalid runtime values before any side effect (R5). S6 pins a regex
# escape in vm_live_pid_for (dotted session names must not match an
# unrelated qemu via pgrep).
# ───────────────────────────────────────────────────────────────────────
# Fixture helpers for this section: a sysbox-labeled or sysbox-runc
# container, and sysbox-runc availability detection.
start_test_container_rt() {
    # start_test_container_rt <name> [extra docker-run args ...]
    local name="$1"
    shift
    docker run -d --name "$name" --hostname "$name" \
        -e HOST_USER="$(whoami)" -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
        -v /tmp:/data \
        "$@" \
        llm-in-a-box:docker sleep infinity >/dev/null 2>&1
    for _ in $(seq 1 30); do
        [ "$(docker container inspect -f '{{.State.Status}}' "$name" 2>/dev/null)" = "running" ] && return 0
        sleep 1
    done
    return 1
}

HAVE_SYSBOX_RUNTIME=0
docker info --format '{{json .Runtimes}}' 2>/dev/null | grep >/dev/null sysbox-runc && HAVE_SYSBOX_RUNTIME=1

# make_vm_session_fixture <basefix> <name>: a vm session dir (no live
# qemu) that makes session_lookup report the vm side of a pair. BOX STATE
# (the session dir) lives in the GLOBAL LLMBOX_STATE_DIR; the fixture creates
# the session STATE dir there (keyed by name). An invocation must run with
# LLMBOX_STATE_DIR=$fix so lookup finds it.
make_vm_session_fixture() {
    local fix="$1" name="$2"
    rm -rf "$fix"
    mkdir -p "$fix/sessions/$name" "$fix/sessions/$name"
    touch "$fix/sessions/$name/overlay.qcow2"
}

# T15 (R3): --destroy on an ambiguous name without --runtime errors and
# touches nothing, and the guidance now shows the WORKING destroy forms
# ('--destroy --runtime' — absent from today's attach-only hints, so this
# check is genuinely red pre-fix).
if [ "$HAVE_DOCKER_IMAGE" = 1 ]; then
    make_vm_session_fixture /tmp/llm-in-a-box-sess-t15 llm-in-a-box-sess-amb15
    docker rm -f llm-in-a-box-sess-amb15 >/dev/null 2>&1 || true
    start_test_container llm-in-a-box-sess-amb15 || { skip "T15 destroy-ambiguous-no-runtime (container did not start)"; AMB15_SKIP=1; }
    if [ "${AMB15_SKIP:-0}" = 0 ]; then
        cd /tmp/llm-in-a-box-sess-t15 &&  LLMBOX_STATE_DIR=/tmp/llm-in-a-box-sess-t15 "$BOC" --destroy llm-in-a-box-sess-amb15 >/tmp/llm-in-a-box-sess-t15.log 2>&1
        RC=$?
        check "T15 destroy ambiguous without --runtime errors, shows destroy forms, touches nothing" \
            "[ $RC -ne 0 ] \
                && grep -q 'multiple runtimes' /tmp/llm-in-a-box-sess-t15.log \
                && grep -q 'vm' /tmp/llm-in-a-box-sess-t15.log \
                && grep -q 'docker' /tmp/llm-in-a-box-sess-t15.log \
                && grep -q -- '--destroy --runtime' /tmp/llm-in-a-box-sess-t15.log \
                && [ -d /tmp/llm-in-a-box-sess-t15/sessions/llm-in-a-box-sess-amb15 ] \
                && [ \"\$(docker container inspect -f '{{.State.Status}}' llm-in-a-box-sess-amb15 2>/dev/null)\" = running ]"
        docker rm -f llm-in-a-box-sess-amb15 >/dev/null 2>&1 || true
    fi
    rm -rf /tmp/llm-in-a-box-sess-t15
else
    skip "T15 destroy ambiguous without --runtime (no docker / image)"
fi

# T16 (R1): --destroy --runtime vm on an ambiguous name removes exactly
# the vm side: LIVE qemu killed, session dir gone, container untouched
# and still running, sibling note printed. Red pre-fix (ambiguity error,
# nothing removed, no note).
if [ "$HAVE_DOCKER_IMAGE" = 1 ]; then
    make_vm_session_fixture /tmp/llm-in-a-box-sess-t16 llm-in-a-box-sess-amb16
    docker rm -f llm-in-a-box-sess-amb16 >/dev/null 2>&1 || true
    FAKE16=$(spawn_fake_qemu /tmp/llm-in-a-box-sess-t16/sessions/llm-in-a-box-sess-amb16/overlay.qcow2)
    start_test_container llm-in-a-box-sess-amb16 || { skip "T16 destroy --runtime vm (container did not start)"; AMB16_SKIP=1; }
    if [ "${AMB16_SKIP:-0}" = 0 ]; then
        sleep 0.5
        cd /tmp/llm-in-a-box-sess-t16 &&  LLMBOX_STATE_DIR=/tmp/llm-in-a-box-sess-t16 "$BOC" --destroy --runtime vm llm-in-a-box-sess-amb16 >/tmp/llm-in-a-box-sess-t16.log 2>&1
        RC=$?
        check "T16 destroy ambiguous --runtime vm removes the vm instance only (live qemu killed, container untouched, note shown)" \
            "[ $RC -eq 0 ] \
                && grep -q 'Removed vm session' /tmp/llm-in-a-box-sess-t16.log \
                && ! kill -0 $FAKE16 2>/dev/null \
                && [ ! -d /tmp/llm-in-a-box-sess-t16/sessions/llm-in-a-box-sess-amb16 ] \
                && [ \"\$(docker container inspect -f '{{.State.Status}}' llm-in-a-box-sess-amb16 2>/dev/null)\" = running ] \
                && grep -q 'still exists as a docker instance' /tmp/llm-in-a-box-sess-t16.log \
                && grep -q -- '--destroy --runtime docker' /tmp/llm-in-a-box-sess-t16.log"
        docker rm -f llm-in-a-box-sess-amb16 >/dev/null 2>&1 || true
    fi
    kill $FAKE16 2>/dev/null || true
    rm -rf /tmp/llm-in-a-box-sess-t16
else
    skip "T16 destroy ambiguous --runtime vm (no docker / image)"
fi

# T17 (R1): --destroy --runtime docker on an ambiguous name removes
# exactly the container side: container gone, vm session dir survives,
# sibling note printed. Red pre-fix.
if [ "$HAVE_DOCKER_IMAGE" = 1 ]; then
    make_vm_session_fixture /tmp/llm-in-a-box-sess-t17 llm-in-a-box-sess-amb17
    docker rm -f llm-in-a-box-sess-amb17 >/dev/null 2>&1 || true
    start_test_container llm-in-a-box-sess-amb17 || { skip "T17 destroy --runtime docker (container did not start)"; AMB17_SKIP=1; }
    if [ "${AMB17_SKIP:-0}" = 0 ]; then
        cd /tmp/llm-in-a-box-sess-t17 &&  LLMBOX_STATE_DIR=/tmp/llm-in-a-box-sess-t17 "$BOC" --destroy --runtime docker llm-in-a-box-sess-amb17 >/tmp/llm-in-a-box-sess-t17.log 2>&1
        RC=$?
        check "T17 destroy ambiguous --runtime docker removes the container only (vm session dir survives, note shown)" \
            "[ $RC -eq 0 ] \
                && grep -q 'Removed container' /tmp/llm-in-a-box-sess-t17.log \
                && ! docker container inspect llm-in-a-box-sess-amb17 >/dev/null 2>&1 \
                && [ -d /tmp/llm-in-a-box-sess-t17/sessions/llm-in-a-box-sess-amb17 ] \
                && grep -q 'still exists as a vm instance' /tmp/llm-in-a-box-sess-t17.log \
                && grep -q -- '--destroy --runtime vm' /tmp/llm-in-a-box-sess-t17.log"
    fi
    rm -rf /tmp/llm-in-a-box-sess-t17
else
    skip "T17 destroy ambiguous --runtime docker (no docker / image)"
fi

# T18 (R1, real sysbox inference path): container started on the REAL
# sysbox-runc docker runtime (unlabeled) resolves as runtime sysbox via
# .HostConfig.Runtime inference — the same path production sysbox boxes
# take. --destroy --runtime sysbox removes exactly the container.
# SKIPs where the docker host has no sysbox-runc runtime (documented in
# the plan's skip matrix; executed on the host run).
if [ "$HAVE_SYSBOX_RUNTIME" = 1 ] && [ "$HAVE_DOCKER_IMAGE" = 1 ]; then
    make_vm_session_fixture /tmp/llm-in-a-box-sess-t18 llm-in-a-box-sess-amb18
    docker rm -f llm-in-a-box-sess-amb18 >/dev/null 2>&1 || true
    start_test_container_rt llm-in-a-box-sess-amb18 --runtime sysbox-runc || { skip "T18 destroy --runtime sysbox via sysbox-runc (container did not start)"; AMB18_SKIP=1; }
    if [ "${AMB18_SKIP:-0}" = 0 ]; then
        cd /tmp/llm-in-a-box-sess-t18 &&  LLMBOX_STATE_DIR=/tmp/llm-in-a-box-sess-t18 "$BOC" --destroy --runtime sysbox llm-in-a-box-sess-amb18 >/tmp/llm-in-a-box-sess-t18.log 2>&1
        RC=$?
        check "T18 destroy ambiguous --runtime sysbox removes the sysbox-runc container only (inference path)" \
            "[ $RC -eq 0 ] \
                && ! docker container inspect llm-in-a-box-sess-amb18 >/dev/null 2>&1 \
                && [ -d /tmp/llm-in-a-box-sess-t18/sessions/llm-in-a-box-sess-amb18 ]"
    fi
    rm -rf /tmp/llm-in-a-box-sess-t18
else
    skip "T18 destroy --runtime sysbox via sysbox-runc (no sysbox-runc runtime on this docker host)"
fi

# T18b (R1, label branch): a container carrying the
# llm-in-a-box.runtime=sysbox label resolves as runtime sysbox through
# the label branch of container_session_state. This is the LABEL branch
# only (lbx never sets that label itself); the production
# sysbox path is T18's inference branch.
if [ "$HAVE_DOCKER_IMAGE" = 1 ]; then
    make_vm_session_fixture /tmp/llm-in-a-box-sess-t18b llm-in-a-box-sess-amb18b
    docker rm -f llm-in-a-box-sess-amb18b >/dev/null 2>&1 || true
    start_test_container_rt llm-in-a-box-sess-amb18b --label llm-in-a-box.runtime=sysbox || { skip "T18b destroy --runtime sysbox labeled (container did not start)"; AMB18B_SKIP=1; }
    if [ "${AMB18B_SKIP:-0}" = 0 ]; then
        cd /tmp/llm-in-a-box-sess-t18b &&  LLMBOX_STATE_DIR=/tmp/llm-in-a-box-sess-t18b "$BOC" --destroy --runtime sysbox llm-in-a-box-sess-amb18b >/tmp/llm-in-a-box-sess-t18b.log 2>&1
        RC=$?
        check "T18b destroy ambiguous --runtime sysbox removes the sysbox-labeled container only (label branch)" \
            "[ $RC -eq 0 ] \
                && ! docker container inspect llm-in-a-box-sess-amb18b >/dev/null 2>&1 \
                && [ -d /tmp/llm-in-a-box-sess-t18b/sessions/llm-in-a-box-sess-amb18b ]"
    fi
    rm -rf /tmp/llm-in-a-box-sess-t18b
else
    skip "T18b destroy --runtime sysbox labeled (no docker / image)"
fi

# T19 (R4): --destroy --runtime vm on a UNIQUE docker container errors
# with "already exists as a ..." guidance and destroys NOTHING. Today the
# runtime is silently ignored and the container IS destroyed (exit 0) —
# the misdirection this phase closes. Red pre-fix.
if [ "$HAVE_DOCKER_IMAGE" = 1 ]; then
    docker rm -f llm-in-a-box-sess-amb19 >/dev/null 2>&1 || true
    start_test_container llm-in-a-box-sess-amb19 || { skip "T19 destroy conflict on unique container (container did not start)"; AMB19_SKIP=1; }
    if [ "${AMB19_SKIP:-0}" = 0 ]; then
        mkdir -p /tmp/llm-in-a-box-sess-t19 && cd /tmp/llm-in-a-box-sess-t19 &&  LLMBOX_STATE_DIR=/tmp/llm-in-a-box-sess-t19 "$BOC" --destroy --runtime vm llm-in-a-box-sess-amb19 >/tmp/llm-in-a-box-sess-t19.log 2>&1
        RC=$?
        check "T19 destroy unique container with conflicting --runtime errors and destroys nothing" \
            "[ $RC -ne 0 ] \
                && grep -q 'already exists as a docker instance' /tmp/llm-in-a-box-sess-t19.log \
                && [ \"\$(docker container inspect -f '{{.State.Status}}' llm-in-a-box-sess-amb19 2>/dev/null)\" = running ]"
        docker rm -f llm-in-a-box-sess-amb19 >/dev/null 2>&1 || true
    fi
    rm -rf /tmp/llm-in-a-box-sess-t19
else
    skip "T19 destroy conflict on unique container (no docker / image)"
fi

# T20 (R4): --destroy --runtime docker on a UNIQUE vm session errors with
# guidance naming the vm runtime and leaves the session dir intact. Red
# pre-fix (today the dir is removed). No docker image needed.
make_vm_session_fixture /tmp/llm-in-a-box-sess-t20 llm-in-a-box-sess-amb20
cd /tmp/llm-in-a-box-sess-t20 && LLMBOX_STATE_DIR=/tmp/llm-in-a-box-sess-t20 "$BOC" --destroy --runtime docker llm-in-a-box-sess-amb20 >/tmp/llm-in-a-box-sess-t20.log 2>&1
RC=$?
check "T20 destroy unique vm session with conflicting --runtime errors and destroys nothing" \
    "[ $RC -ne 0 ] \
        && grep -q 'already exists as a vm instance' /tmp/llm-in-a-box-sess-t20.log \
        && [ -d /tmp/llm-in-a-box-sess-t20/sessions/llm-in-a-box-sess-amb20 ]"
rm -rf /tmp/llm-in-a-box-sess-t20

# T21 (R3): --stop on an ambiguous name without --runtime errors, stops
# nothing (live qemu + running container prove it), and the guidance
# shows the WORKING stop forms ('--stop --runtime' — absent pre-fix).
if [ "$HAVE_DOCKER_IMAGE" = 1 ]; then
    make_vm_session_fixture /tmp/llm-in-a-box-sess-t21 llm-in-a-box-sess-amb21
    docker rm -f llm-in-a-box-sess-amb21 >/dev/null 2>&1 || true
    FAKE21=$(spawn_fake_qemu /tmp/llm-in-a-box-sess-t21/sessions/llm-in-a-box-sess-amb21/overlay.qcow2)
    start_test_container llm-in-a-box-sess-amb21 || { skip "T21 stop-ambiguous-no-runtime (container did not start)"; AMB21_SKIP=1; }
    if [ "${AMB21_SKIP:-0}" = 0 ]; then
        sleep 0.5
        cd /tmp/llm-in-a-box-sess-t21 &&  LLMBOX_STATE_DIR=/tmp/llm-in-a-box-sess-t21 "$BOC" --stop llm-in-a-box-sess-amb21 >/tmp/llm-in-a-box-sess-t21.log 2>&1
        RC=$?
        check "T21 stop ambiguous without --runtime errors, shows stop forms, stops nothing" \
            "[ $RC -ne 0 ] \
                && grep -q 'multiple runtimes' /tmp/llm-in-a-box-sess-t21.log \
                && grep -q 'vm' /tmp/llm-in-a-box-sess-t21.log \
                && grep -q 'docker' /tmp/llm-in-a-box-sess-t21.log \
                && grep -q -- '--stop --runtime' /tmp/llm-in-a-box-sess-t21.log \
                && kill -0 $FAKE21 2>/dev/null \
                && [ \"\$(docker container inspect -f '{{.State.Status}}' llm-in-a-box-sess-amb21 2>/dev/null)\" = running ]"
        docker rm -f llm-in-a-box-sess-amb21 >/dev/null 2>&1 || true
    fi
    kill $FAKE21 2>/dev/null || true
    rm -rf /tmp/llm-in-a-box-sess-t21
else
    skip "T21 stop ambiguous without --runtime (no docker / image)"
fi

# T22 (R2): --shutdown --force --runtime docker on an ambiguous name
# force-stops ONLY the container: container exited, vm fake qemu STILL
# alive, note names the remaining vm sibling. Red pre-fix (ambiguity
# error, container untouched).
if [ "$HAVE_DOCKER_IMAGE" = 1 ]; then
    make_vm_session_fixture /tmp/llm-in-a-box-sess-t22 llm-in-a-box-sess-amb22
    docker rm -f llm-in-a-box-sess-amb22 >/dev/null 2>&1 || true
    FAKE22=$(spawn_fake_qemu /tmp/llm-in-a-box-sess-t22/sessions/llm-in-a-box-sess-amb22/overlay.qcow2)
    start_test_container llm-in-a-box-sess-amb22 || { skip "T22 shutdown --force --runtime docker (container did not start)"; AMB22_SKIP=1; }
    if [ "${AMB22_SKIP:-0}" = 0 ]; then
        sleep 0.5
        cd /tmp/llm-in-a-box-sess-t22 &&  LLMBOX_STATE_DIR=/tmp/llm-in-a-box-sess-t22 "$BOC" --shutdown --force --runtime docker llm-in-a-box-sess-amb22 >/tmp/llm-in-a-box-sess-t22.log 2>&1
        RC=$?
        check "T22 shutdown --force --runtime docker stops only the container (vm qemu survives, note shown)" \
            "[ $RC -eq 0 ] \
                && [ \"\$(docker container inspect -f '{{.State.Status}}' llm-in-a-box-sess-amb22 2>/dev/null)\" = exited ] \
                && kill -0 $FAKE22 2>/dev/null \
                && grep -q 'still exists as a vm instance' /tmp/llm-in-a-box-sess-t22.log \
                && grep -q -- '--stop --runtime vm' /tmp/llm-in-a-box-sess-t22.log"
        docker rm -f llm-in-a-box-sess-amb22 >/dev/null 2>&1 || true
    fi
    kill $FAKE22 2>/dev/null || true
    rm -rf /tmp/llm-in-a-box-sess-t22
else
    skip "T22 shutdown --force --runtime docker (no docker / image)"
fi

# T23 (R4): --stop --runtime vm on a UNIQUE docker container errors with
# guidance and does not stop it. Red pre-fix (container stopped today).
if [ "$HAVE_DOCKER_IMAGE" = 1 ]; then
    docker rm -f llm-in-a-box-sess-amb23 >/dev/null 2>&1 || true
    start_test_container llm-in-a-box-sess-amb23 || { skip "T23 stop conflict on unique container (container did not start)"; AMB23_SKIP=1; }
    if [ "${AMB23_SKIP:-0}" = 0 ]; then
        mkdir -p /tmp/llm-in-a-box-sess-t23 && cd /tmp/llm-in-a-box-sess-t23 &&  LLMBOX_STATE_DIR=/tmp/llm-in-a-box-sess-t23 "$BOC" --stop --runtime vm llm-in-a-box-sess-amb23 >/tmp/llm-in-a-box-sess-t23.log 2>&1
        RC=$?
        check "T23 stop unique container with conflicting --runtime errors and does not stop it" \
            "[ $RC -ne 0 ] \
                && grep -q 'already exists as a docker instance' /tmp/llm-in-a-box-sess-t23.log \
                && [ \"\$(docker container inspect -f '{{.State.Status}}' llm-in-a-box-sess-amb23 2>/dev/null)\" = running ]"
        docker rm -f llm-in-a-box-sess-amb23 >/dev/null 2>&1 || true
    fi
    rm -rf /tmp/llm-in-a-box-sess-t23
else
    skip "T23 stop conflict on unique container (no docker / image)"
fi

# T24 (R5): invalid --runtime values with destroy and stop are rejected
# with "Unknown runtime" BEFORE any side effect.
if [ "$HAVE_DOCKER_IMAGE" = 1 ]; then
    make_vm_session_fixture /tmp/llm-in-a-box-sess-t24 llm-in-a-box-sess-amb24
    docker rm -f llm-in-a-box-sess-amb24 >/dev/null 2>&1 || true
    start_test_container llm-in-a-box-sess-amb24 || { skip "T24 invalid --runtime (container did not start)"; AMB24_SKIP=1; }
    if [ "${AMB24_SKIP:-0}" = 0 ]; then
        cd /tmp/llm-in-a-box-sess-t24 &&  LLMBOX_STATE_DIR=/tmp/llm-in-a-box-sess-t24 "$BOC" --destroy --runtime kata llm-in-a-box-sess-amb24 >/tmp/llm-in-a-box-sess-t24.log 2>&1
        RC1=$?
        cd /tmp/llm-in-a-box-sess-t24 &&  LLMBOX_STATE_DIR=/tmp/llm-in-a-box-sess-t24 "$BOC" --stop --runtime kata llm-in-a-box-sess-amb24 >/tmp/llm-in-a-box-sess-t24.log2 2>&1
        RC2=$?
        check "T24 invalid --runtime with destroy/stop is rejected before any side effect" \
            "[ $RC1 -ne 0 ] && [ $RC2 -ne 0 ] \
                && grep -q 'Unknown runtime' /tmp/llm-in-a-box-sess-t24.log \
                && grep -q 'Unknown runtime' /tmp/llm-in-a-box-sess-t24.log2 \
                && [ -d /tmp/llm-in-a-box-sess-t24/sessions/llm-in-a-box-sess-amb24 ] \
                && [ \"\$(docker container inspect -f '{{.State.Status}}' llm-in-a-box-sess-amb24 2>/dev/null)\" = running ]"
        docker rm -f llm-in-a-box-sess-amb24 >/dev/null 2>&1 || true
    fi
    rm -rf /tmp/llm-in-a-box-sess-t24
else
    skip "T24 invalid --runtime with destroy/stop (no docker / image)"
fi

# T24b (R5 ordering): an invalid --runtime with a MISSING name errors on
# the runtime (validation precedes the missing-name no-op). Red pre-fix
# (missing name exits 0 today).
check "T24b invalid --runtime with destroy on a missing name is rejected (validation precedes the no-op)" \
    "mkdir -p /tmp/llm-in-a-box-sess-t24b && cd /tmp/llm-in-a-box-sess-t24b &&  LLMBOX_STATE_DIR=/tmp/llm-in-a-box-sess-t24b '$BOC' --destroy --runtime kata llm-in-a-box-sess-amb24b >/tmp/llm-in-a-box-sess-t24b.log 2>&1; [ \$? -ne 0 ] \
        && grep -q 'Unknown runtime' /tmp/llm-in-a-box-sess-t24b.log"
check "T24b invalid --runtime with stop on a missing name is rejected (validation precedes the no-op)" \
    "mkdir -p /tmp/llm-in-a-box-sess-t24b && cd /tmp/llm-in-a-box-sess-t24b &&  LLMBOX_STATE_DIR=/tmp/llm-in-a-box-sess-t24b '$BOC' --stop --runtime kata llm-in-a-box-sess-amb24b >/tmp/llm-in-a-box-sess-t24b2.log 2>&1; [ \$? -ne 0 ] \
        && grep -q 'Unknown runtime' /tmp/llm-in-a-box-sess-t24b2.log"
rm -rf /tmp/llm-in-a-box-sess-t24b

# T25 (R1/R3): --destroy --runtime docker on an ambiguous vm+sysbox pair
# (valid runtime, but NOT a member of the pair) errors naming the pair's
# actual member runtimes with the working forms and touches nothing. Red
# pre-fix on the forms text.
if [ "$HAVE_DOCKER_IMAGE" = 1 ]; then
    make_vm_session_fixture /tmp/llm-in-a-box-sess-t25 llm-in-a-box-sess-amb25
    docker rm -f llm-in-a-box-sess-amb25 >/dev/null 2>&1 || true
    start_test_container_rt llm-in-a-box-sess-amb25 --label llm-in-a-box.runtime=sysbox || { skip "T25 third-runtime destroy (container did not start)"; AMB25_SKIP=1; }
    if [ "${AMB25_SKIP:-0}" = 0 ]; then
        cd /tmp/llm-in-a-box-sess-t25 &&  LLMBOX_STATE_DIR=/tmp/llm-in-a-box-sess-t25 "$BOC" --destroy --runtime docker llm-in-a-box-sess-amb25 >/tmp/llm-in-a-box-sess-t25.log 2>&1
        RC=$?
        check "T25 destroy ambiguous vm+sysbox pair with the non-member --runtime docker errors and touches nothing" \
            "[ $RC -ne 0 ] \
                && grep -q 'multiple runtimes' /tmp/llm-in-a-box-sess-t25.log \
                && grep -q 'vm' /tmp/llm-in-a-box-sess-t25.log \
                && grep -q 'sysbox' /tmp/llm-in-a-box-sess-t25.log \
                && grep -q -- '--destroy --runtime' /tmp/llm-in-a-box-sess-t25.log \
                && [ -d /tmp/llm-in-a-box-sess-t25/sessions/llm-in-a-box-sess-amb25 ] \
                && [ \"\$(docker container inspect -f '{{.State.Status}}' llm-in-a-box-sess-amb25 2>/dev/null)\" = running ]"
        docker rm -f llm-in-a-box-sess-amb25 >/dev/null 2>&1 || true
    fi
    rm -rf /tmp/llm-in-a-box-sess-t25
else
    skip "T25 third-runtime destroy (no docker / image)"
fi

# T26 (R4 positive branch, GUARD): --stop --force --runtime vm on a
# UNIQUE vm session still works — a matching runtime must not trip the
# conflict check. Passes before and after the fix (guards against
# inverted R4 logic).
make_vm_session_fixture /tmp/llm-in-a-box-sess-t26 llm-in-a-box-sess-amb26
# The overlay is HOST-SIDE VM STATE in the session directory inside
# $LLMBOX_STATE_DIR (ADR 013), so pgrep must find it there;
# liveness greps the qemu cmdline for that path.
mkdir -p /tmp/llm-in-a-box-sess-t26/sessions/llm-in-a-box-sess-amb26 /tmp/llm-in-a-box-sess-t26/sessions/llm-in-a-box-sess-amb26
touch /tmp/llm-in-a-box-sess-t26/sessions/llm-in-a-box-sess-amb26/overlay.qcow2
FAKE26=$(spawn_fake_qemu /tmp/llm-in-a-box-sess-t26/sessions/llm-in-a-box-sess-amb26/overlay.qcow2)
sleep 0.5
cd /tmp/llm-in-a-box-sess-t26 && LLMBOX_STATE_DIR=/tmp/llm-in-a-box-sess-t26 "$BOC" --stop --force --runtime vm llm-in-a-box-sess-amb26 >/tmp/llm-in-a-box-sess-t26.log 2>&1
RC=$?
check "T26 GUARD: stop --force --runtime vm on a unique vm session stops it (matching runtime is allowed)" \
    "[ $RC -eq 0 ] \
        && proc_dead $FAKE26 \
        && grep -q 'force-stopped' /tmp/llm-in-a-box-sess-t26.log"
kill $FAKE26 2>/dev/null || true
rm -rf /tmp/llm-in-a-box-sess-t26

# T26b (R4 positive branch, GUARD): --destroy --runtime docker on a
# UNIQUE docker container removes it (matching runtime allowed).
if [ "$HAVE_DOCKER_IMAGE" = 1 ]; then
    docker rm -f llm-in-a-box-sess-amb26b >/dev/null 2>&1 || true
    start_test_container llm-in-a-box-sess-amb26b || { skip "T26b GUARD destroy matching runtime (container did not start)"; AMB26B_SKIP=1; }
    if [ "${AMB26B_SKIP:-0}" = 0 ]; then
        mkdir -p /tmp/llm-in-a-box-sess-t26b && cd /tmp/llm-in-a-box-sess-t26b &&  LLMBOX_STATE_DIR=/tmp/llm-in-a-box-sess-t26b "$BOC" --destroy --runtime docker llm-in-a-box-sess-amb26b >/tmp/llm-in-a-box-sess-t26b.log 2>&1
        RC=$?
        check "T26b GUARD: destroy --runtime docker on a unique container removes it (matching runtime allowed)" \
            "[ $RC -eq 0 ] \
                && ! docker container inspect llm-in-a-box-sess-amb26b >/dev/null 2>&1"
    fi
    rm -rf /tmp/llm-in-a-box-sess-t26b
else
    skip "T26b GUARD destroy matching runtime (no docker / image)"
fi

# T27 (R2, vm direction — the user's actual waggle need): --stop --force
# --runtime vm on an ambiguous name stops ONLY the vm side: qemu dead,
# container still running, note names the docker sibling. Red pre-fix.
if [ "$HAVE_DOCKER_IMAGE" = 1 ]; then
    make_vm_session_fixture /tmp/llm-in-a-box-sess-t27 llm-in-a-box-sess-amb27
    docker rm -f llm-in-a-box-sess-amb27 >/dev/null 2>&1 || true
    FAKE27=$(spawn_fake_qemu /tmp/llm-in-a-box-sess-t27/sessions/llm-in-a-box-sess-amb27/overlay.qcow2)
    start_test_container llm-in-a-box-sess-amb27 || { skip "T27 stop --force --runtime vm (container did not start)"; AMB27_SKIP=1; }
    if [ "${AMB27_SKIP:-0}" = 0 ]; then
        sleep 0.5
        cd /tmp/llm-in-a-box-sess-t27 &&  LLMBOX_STATE_DIR=/tmp/llm-in-a-box-sess-t27 "$BOC" --stop --force --runtime vm llm-in-a-box-sess-amb27 >/tmp/llm-in-a-box-sess-t27.log 2>&1
        RC=$?
        check "T27 stop --force --runtime vm stops only the vm side (container survives, note shown)" \
            "[ $RC -eq 0 ] \
                && ! kill -0 $FAKE27 2>/dev/null \
                && [ \"\$(docker container inspect -f '{{.State.Status}}' llm-in-a-box-sess-amb27 2>/dev/null)\" = running ] \
                && grep -q 'still exists as a docker instance' /tmp/llm-in-a-box-sess-t27.log \
                && grep -q -- '--stop --runtime docker' /tmp/llm-in-a-box-sess-t27.log"
        docker rm -f llm-in-a-box-sess-amb27 >/dev/null 2>&1 || true
    fi
    kill $FAKE27 2>/dev/null || true
    rm -rf /tmp/llm-in-a-box-sess-t27
else
    skip "T27 stop --force --runtime vm (no docker / image)"
fi

# T28 (R2/R4, multi-name with runtime): --stop --force --runtime docker
# over [ambiguous-docker, unique-vm(LIVE), missing]: the docker half of
# the ambiguous pair is stopped, the unique vm is NOT stopped (conflict
# error, live qemu must survive — pre-fix it is force-stopped, making
# this red), the missing name is reported, exit != 0, and the loop
# processes every name (no abort under set -e).
if [ "$HAVE_DOCKER_IMAGE" = 1 ]; then
    make_vm_session_fixture /tmp/llm-in-a-box-sess-t28 llm-in-a-box-sess-amb28
    rm -rf /tmp/llm-in-a-box-sess-t28/sessions/llm-in-a-box-sess-amb28
    mkdir -p /tmp/llm-in-a-box-sess-t28/sessions/llm-in-a-box-sess-amb28 /tmp/llm-in-a-box-sess-t28/sessions/llm-in-a-box-sess-amb28v /tmp/llm-in-a-box-sess-t28/sessions/llm-in-a-box-sess-amb28v
    touch /tmp/llm-in-a-box-sess-t28/sessions/llm-in-a-box-sess-amb28/overlay.qcow2 /tmp/llm-in-a-box-sess-t28/sessions/llm-in-a-box-sess-amb28v/overlay.qcow2
    docker rm -f llm-in-a-box-sess-amb28 >/dev/null 2>&1 || true
    FAKE28V=$(spawn_fake_qemu /tmp/llm-in-a-box-sess-t28/sessions/llm-in-a-box-sess-amb28v/overlay.qcow2)
    start_test_container llm-in-a-box-sess-amb28 || { skip "T28 multi-name stop with runtime (container did not start)"; AMB28_SKIP=1; }
    if [ "${AMB28_SKIP:-0}" = 0 ]; then
        sleep 0.5
        cd /tmp/llm-in-a-box-sess-t28 &&  LLMBOX_STATE_DIR=/tmp/llm-in-a-box-sess-t28 "$BOC" --stop --force --runtime docker llm-in-a-box-sess-amb28 llm-in-a-box-sess-amb28v llm-in-a-box-sess-amb28missing >/tmp/llm-in-a-box-sess-t28.log 2>&1
        RC=$?
        check "T28 multi-name --stop --force --runtime docker stops the docker half, rejects the unique vm, reports the missing name" \
            "[ $RC -ne 0 ] \
                && [ \"\$(docker container inspect -f '{{.State.Status}}' llm-in-a-box-sess-amb28 2>/dev/null)\" = exited ] \
                && kill -0 $FAKE28V 2>/dev/null \
                && grep -q 'already exists as a vm instance' /tmp/llm-in-a-box-sess-t28.log \
                && grep -q \"does not exist\" /tmp/llm-in-a-box-sess-t28.log"
        docker rm -f llm-in-a-box-sess-amb28 >/dev/null 2>&1 || true
    fi
    kill $FAKE28V 2>/dev/null || true
    rm -rf /tmp/llm-in-a-box-sess-t28
else
    skip "T28 multi-name stop with runtime (no docker / image)"
fi

# T29 (R3, multi-name without runtime): --stop over [ambiguous,
# unique-container] reports the ambiguity WITH the working stop forms,
# still stops the container, exits != 0 — the loop must not abort on the
# first ambiguous name.
if [ "$HAVE_DOCKER_IMAGE" = 1 ]; then
    make_vm_session_fixture /tmp/llm-in-a-box-sess-t29 llm-in-a-box-sess-amb29
    docker rm -f llm-in-a-box-sess-amb29 llm-in-a-box-sess-amb29c >/dev/null 2>&1 || true
    start_test_container llm-in-a-box-sess-amb29 || { skip "T29 multi-name stop without runtime (container did not start)"; AMB29_SKIP=1; }
    start_test_container llm-in-a-box-sess-amb29c || { skip "T29 multi-name stop without runtime (second container did not start)"; AMB29C_SKIP=1; }
    if [ "${AMB29_SKIP:-0}" = 0 ] && [ "${AMB29C_SKIP:-0}" = 0 ]; then
        cd /tmp/llm-in-a-box-sess-t29 &&  LLMBOX_STATE_DIR=/tmp/llm-in-a-box-sess-t29 "$BOC" --stop llm-in-a-box-sess-amb29 llm-in-a-box-sess-amb29c >/tmp/llm-in-a-box-sess-t29.log 2>&1
        RC=$?
        check "T29 multi-name --stop without runtime errors on the ambiguous name, still stops the container, shows stop forms" \
            "[ $RC -ne 0 ] \
                && grep -q 'multiple runtimes' /tmp/llm-in-a-box-sess-t29.log \
                && grep -q -- '--stop --runtime' /tmp/llm-in-a-box-sess-t29.log \
                && [ \"\$(docker container inspect -f '{{.State.Status}}' llm-in-a-box-sess-amb29c 2>/dev/null)\" = exited ]"
        docker rm -f llm-in-a-box-sess-amb29 llm-in-a-box-sess-amb29c >/dev/null 2>&1 || true
    else
        docker rm -f llm-in-a-box-sess-amb29 llm-in-a-box-sess-amb29c >/dev/null 2>&1 || true
    fi
    rm -rf /tmp/llm-in-a-box-sess-t29
else
    skip "T29 multi-name stop without runtime (no docker / image)"
fi

# T30 (S6, dotted-name pgrep escape): a session whose name contains a
# dot must not match an unrelated qemu whose overlay path differs only in
# that one character. Decoy (lower pid, spawned first, argv carries
# llm-in-a-box-sess-amb30AxB) must SURVIVE a --destroy of session
# llm-in-a-box-sess-amb30A.B; the real qemu must die. Red pre-fix (the unescaped
# pgrep regex matches the decoy first and kills it instead). No docker
# needed. Box state (sessions/<name>) lives in the GLOBAL LLMBOX_STATE_DIR;
# the overlays are host-side VM state under the state directory's sessions/.
make_vm_session_fixture /tmp/llm-in-a-box-sess-t30 llm-in-a-box-sess-amb30A.B
mkdir -p /tmp/llm-in-a-box-sess-t30/sessions/llm-in-a-box-sess-amb30A.B /tmp/llm-in-a-box-sess-t30/sessions/llm-in-a-box-sess-amb30A.B
mkdir -p /tmp/llm-in-a-box-sess-t30/sessions/llm-in-a-box-sess-amb30AxB /tmp/llm-in-a-box-sess-t30/sessions/llm-in-a-box-sess-amb30AxB
touch /tmp/llm-in-a-box-sess-t30/sessions/llm-in-a-box-sess-amb30A.B/overlay.qcow2 \
      /tmp/llm-in-a-box-sess-t30/sessions/llm-in-a-box-sess-amb30AxB/overlay.qcow2
DECOY30=$(spawn_fake_qemu /tmp/llm-in-a-box-sess-t30/sessions/llm-in-a-box-sess-amb30AxB/overlay.qcow2)
FAKE30=$(spawn_fake_qemu /tmp/llm-in-a-box-sess-t30/sessions/llm-in-a-box-sess-amb30A.B/overlay.qcow2)
sleep 0.5
cd /tmp/llm-in-a-box-sess-t30 && LLMBOX_STATE_DIR=/tmp/llm-in-a-box-sess-t30 "$BOC" --destroy llm-in-a-box-sess-amb30A.B >/tmp/llm-in-a-box-sess-t30.log 2>&1
RC=$?
check "T30 destroy of a dotted-name session kills its own qemu and NOT the one-character-different decoy" \
    "[ $RC -eq 0 ] \
        && proc_dead $FAKE30 \
        && kill -0 $DECOY30 2>/dev/null \
        && [ ! -d /tmp/llm-in-a-box-sess-t30/sessions/llm-in-a-box-sess-amb30A.B ]"
kill $FAKE30 $DECOY30 2>/dev/null || true
rm -rf /tmp/llm-in-a-box-sess-t30

# T31 (GUARD): destroy of a missing name stays a clean no-op exit 0.
check "T31 GUARD: destroy of a missing name is a clean no-op" \
    "mkdir -p /tmp/llm-in-a-box-sess-t31 && cd /tmp/llm-in-a-box-sess-t31 &&  LLMBOX_STATE_DIR=/tmp/llm-in-a-box-sess-t31 '$BOC' --destroy llm-in-a-box-sess-amb31 >/tmp/llm-in-a-box-sess-t31.log 2>&1; [ \$? -eq 0 ] \
        && grep -q \"does not exist\" /tmp/llm-in-a-box-sess-t31.log"
rm -rf /tmp/llm-in-a-box-sess-t31

# T31b (GUARD): all-missing stop stays a clean no-op exit 0.
check "T31b GUARD: all-missing --stop stays a clean no-op with the new per-name selection" \
    "mkdir -p /tmp/llm-in-a-box-sess-t31b && cd /tmp/llm-in-a-box-sess-t31b &&  LLMBOX_STATE_DIR=/tmp/llm-in-a-box-sess-t31b '$BOC' --stop llm-in-a-box-sess-amb31b >/tmp/llm-in-a-box-sess-t31b.log 2>&1; [ \$? -eq 0 ] \
        && grep -q \"does not exist\" /tmp/llm-in-a-box-sess-t31b.log"
rm -rf /tmp/llm-in-a-box-sess-t31b

# ── Phase 4 (2026-09-08): launch/attach disambiguation (R6) ────────────────
# Reported bug: `lbx --runtime vm <name>` on a legacy-duplicate
# name (vm session dir + container under one name) still failed with
# "exists in multiple runtimes" even though --runtime named a member.
# The 2026-09-06 fix (select_target_runtime) covered
# --destroy/--stop/--shutdown only; the default launch/attach path kept
# treating ambiguous:... as fatal regardless of --runtime.
#
# R6: with an explicit --runtime that IS a member of the ambiguous pair,
# launch/attach acts on exactly that instance (vm preflight / container
# attach start for the selected instance; the sibling is untouched). A
# valid --runtime OUTSIDE the pair is an error naming the pair, nothing
# touched (launch mirror of T25).
#
# LLM-FRIENDLY NOTE: the sibling container carries the
# llm-in-a-box.runtime=docker label (the mechanism session_lookup keys
# on — container_session_state) and uses busybox when the repo image is
# absent, so these checks RUN on any host with a docker daemon instead
# of skipping. Hosts with the repo image behave identically (the label
# short-circuits image-based inference for both).
start_any_session_container() {
    local name="$1"
    local img=busybox
    [ "$HAVE_DOCKER_IMAGE" = 1 ] && img=llm-in-a-box:docker
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -d --name "$name" --hostname "$name" \
        -l llm-in-a-box.runtime=docker \
        "$img" sleep infinity >/dev/null 2>&1
    local i
    for i in $(seq 1 30); do
        [ "$(docker container inspect -f '{{.State.Status}}' "$name" 2>/dev/null)" = "running" ] && break
        sleep 1
    done
    # Pre-create the attach-readiness marker so attach_session's wait loop
    # never spins for its full 30s on images without the entrypoint setup.
    docker exec "$name" touch /tmp/.user-ready >/dev/null 2>&1 || true
    [ "$(docker container inspect -f '{{.State.Status}}' "$name" 2>/dev/null)" = "running" ]
}

AMB_PAIR="llm-in-a-box-sess-amb"

# T32 (R6, vm direction — the reported case): `--runtime vm` on the
# ambiguous pair must select the vm instance: the run reaches the
# vm-specific preflight and never prints the ambiguity error, while the
# sibling container keeps running and the vm session dir survives.
# LLMBOX_VM_MISSING forces the preflight to fail deterministically on ANY
# host — the discriminator is WHERE the run dies: pre-fix it dies at
# the ambiguity error (no preflight output at all).
if command -v docker >/dev/null 2>&1; then
    make_vm_fixture /tmp/llm-in-a-box-sess-t32
    mkdir -p "/tmp/llm-in-a-box-sess-t32/sessions/$AMB_PAIR" "/tmp/llm-in-a-box-sess-t32/sessions/$AMB_PAIR"
    touch "/tmp/llm-in-a-box-sess-t32/sessions/$AMB_PAIR/overlay.qcow2"
    if start_any_session_container "$AMB_PAIR"; then
        cd /tmp/llm-in-a-box-sess-t32 &&  LLMBOX_STATE_DIR=/tmp/llm-in-a-box-sess-t32 LLMBOX_VM_MISSING='qemu-system-x86_64' \
            "$BOC" --runtime vm "$AMB_PAIR" </dev/null >/tmp/llm-in-a-box-sess-t32.log 2>&1
        RC=$?
        check "T32 launch --runtime vm on an ambiguous pair selects the vm instance (preflight reached, no ambiguity error, sibling untouched)" \
            "[ $RC -ne 0 ] \
                && grep -q 'Checking vm runtime prerequisites' /tmp/llm-in-a-box-sess-t32.log \
                && ! grep -q 'multiple runtimes' /tmp/llm-in-a-box-sess-t32.log \
                && [ \"\$(docker container inspect -f '{{.State.Status}}' '$AMB_PAIR' 2>/dev/null)\" = running ] \
                && [ -d /tmp/llm-in-a-box-sess-t32/sessions/$AMB_PAIR ]"
        docker rm -f "$AMB_PAIR" >/dev/null 2>&1 || true
    else
        skip "T32 launch --runtime vm on ambiguous pair (sibling container did not start)"
    fi
    rm -rf /tmp/llm-in-a-box-sess-t32
else
    skip "T32 launch --runtime vm on ambiguous pair (no docker)"
fi

# T33 (R6, container direction): `--runtime docker` on the same pair
# attaches to the container: the attach message prints, the ambiguity
# error does not, and the vm session dir survives untouched.
if command -v docker >/dev/null 2>&1; then
    make_vm_fixture /tmp/llm-in-a-box-sess-t33
    mkdir -p "/tmp/llm-in-a-box-sess-t33/sessions/$AMB_PAIR" "/tmp/llm-in-a-box-sess-t33/sessions/$AMB_PAIR"
    touch "/tmp/llm-in-a-box-sess-t33/sessions/$AMB_PAIR/overlay.qcow2"
    if start_any_session_container "$AMB_PAIR"; then
        cd /tmp/llm-in-a-box-sess-t33 &&  LLMBOX_STATE_DIR=/tmp/llm-in-a-box-sess-t33 "$BOC" --runtime docker "$AMB_PAIR" </dev/null >/tmp/llm-in-a-box-sess-t33.log 2>&1 || true
        check "T33 launch --runtime docker on an ambiguous pair attaches the container, no ambiguity error, vm sibling untouched" \
            "grep -q 'Attaching to running container' /tmp/llm-in-a-box-sess-t33.log \
                && ! grep -q 'multiple runtimes' /tmp/llm-in-a-box-sess-t33.log \
                && [ -d /tmp/llm-in-a-box-sess-t33/sessions/$AMB_PAIR ]"
        docker rm -f "$AMB_PAIR" >/dev/null 2>&1 || true
    else
        skip "T33 launch --runtime docker on ambiguous pair (sibling container did not start)"
    fi
    rm -rf /tmp/llm-in-a-box-sess-t33
else
    skip "T33 launch --runtime docker on ambiguous pair (no docker)"
fi

# T34 (R6 guard, launch mirror of T25): `--runtime sysbox` on a vm+docker
# pair is valid but not a member — an error names the pair's actual
# runtimes; container still runs and the vm session dir survives.
if command -v docker >/dev/null 2>&1; then
    make_vm_fixture /tmp/llm-in-a-box-sess-t34
    mkdir -p "/tmp/llm-in-a-box-sess-t34/sessions/$AMB_PAIR" "/tmp/llm-in-a-box-sess-t34/sessions/$AMB_PAIR"
    touch "/tmp/llm-in-a-box-sess-t34/sessions/$AMB_PAIR/overlay.qcow2"
    if start_any_session_container "$AMB_PAIR"; then
        cd /tmp/llm-in-a-box-sess-t34 &&  LLMBOX_STATE_DIR=/tmp/llm-in-a-box-sess-t34 "$BOC" --runtime sysbox "$AMB_PAIR" </dev/null >/tmp/llm-in-a-box-sess-t34.log 2>&1
        RC=$?
        check "T34 launch --runtime sysbox on a vm+docker pair errors naming the pair, touches nothing" \
            "[ $RC -ne 0 ] \
                && grep -q 'multiple runtimes' /tmp/llm-in-a-box-sess-t34.log \
                && grep -q 'not one of them' /tmp/llm-in-a-box-sess-t34.log \
                && [ \"\$(docker container inspect -f '{{.State.Status}}' '$AMB_PAIR' 2>/dev/null)\" = running ] \
                && [ -d /tmp/llm-in-a-box-sess-t34/sessions/$AMB_PAIR ]"
        docker rm -f "$AMB_PAIR" >/dev/null 2>&1 || true
    else
        skip "T34 launch --runtime sysbox on vm+docker pair (sibling container did not start)"
    fi
    rm -rf /tmp/llm-in-a-box-sess-t34
else
    skip "T34 launch --runtime sysbox on vm+docker pair (no docker)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Legacy (old) detection + rename behavior (2026-09-14 plan:
# rename to lbx). LG1-LG8 (+LG3b) + ST1-ST2.
#
# WHAT (no source grep): drives the launcher against the fake docker
# shim (tests/fake-docker.sh) with a per-check container table, and
# asserts on the recorded argv, exit codes and stderr. Red-phase note:
# these run against the CURRENT launcher with CURRENT seams
# (scratch project dirs as cwd; launcher path ../lbx); phase 2
# renames the fixture plumbing with the launcher — assertions are the
# spec, plumbing is not. LG6's fixture is HOME-based by design and is
# EXEMPT from that blanket rename.
#
# Why: the rename must not strand old sessions (attach/destroy/
# stop/list still work, with a legacy note), must write/read the new
# labels, must not misclassify unrelated images (exact-prefix matching),
# and must not migrate the old vm state dir. ST1/ST2 pin the renamed
# defaults the docs claim.
# ───────────────────────────────────────────────────────────────────────────
LLG=/tmp/llmlg
rm -rf "$LLG"
mkdir -p "$LLG"

lg_fake() {
    local tag="$1"
    mkdir -p "$LLG/bin-$tag" "$LLG/home-$tag" "$LLG/state-$tag"
    ln -sf "$SCRIPT_DIR/fake-docker.sh" "$LLG/bin-$tag/docker"
    : > "$LLG/log-$tag"
    : > "$LLG/exist-$tag"
    : > "$LLG/table-$tag"
}

LGEV() {
    echo "LLMBOX_STATE_DIR= PATH=$LLG/bin-$1:\$PATH FAKE_DOCKER_LOG=$LLG/log-$1 FAKE_EXISTING_FILE=$LLG/exist-$1 FAKE_CONTAINER_TABLE=$LLG/table-$1 HOME=$LLG/home-$1"
}

# ── LG1: legacy attach + note ───────────────────────────────────────────────
# Requirement: a container carrying the old box-of-claude.runtime
# label is recognized as a session (regression guard), AND attach prints
# a legacy note (red-phase history: no note existed before the rename).
lg_fake lg1
printf 'llm-in-a-box-sess-lg1|box-of-claude.runtime|sysbox|box-of-claude:sysbox|running|||\n' > "$LLG/table-lg1"
check "LG1 legacy-labeled sysbox container attaches (regression guard)" \
    "cd $LLG/state-lg1 && $(LGEV lg1) '$BOC' llm-in-a-box-sess-lg1 </dev/null >$LLG/lg1.log 2>&1; \
        grep -q 'Found existing sysbox session' $LLG/lg1.log"

check "LG1 legacy attach emits an old note" \
    "cd $LLG/state-lg1 && $(LGEV lg1) '$BOC' llm-in-a-box-sess-lg1 </dev/null >$LLG/lg1n.log 2>&1; \
        grep -q 'old (legacy) session' $LLG/lg1n.log"

# ── LG2: legacy docker label -> runtime inferred (regression guard) ────────
lg_fake lg2
printf 'llm-in-a-box-sess-lg2|box-of-claude.runtime|docker|llm-in-a-box:docker|running|||\n' > "$LLG/table-lg2"
check "LG2 legacy-labeled docker container resolves runtime docker (regression guard)" \
    "cd $LLG/state-lg2 && $(LGEV lg2) '$BOC' llm-in-a-box-sess-lg2 </dev/null >$LLG/lg2.log 2>&1; \
        grep -q 'Found existing docker session' $LLG/lg2.log"

# ── LG3: no label, box-of-claude: image -> legacy (regression guard) ───────
lg_fake lg3
printf 'llm-in-a-box-sess-lg3|||box-of-claude:docker|running|docker||\n' > "$LLG/table-lg3"
check "LG3 no-label box-of-claude image resolves legacy docker (regression guard)" \
    "cd $LLG/state-lg3 && $(LGEV lg3) '$BOC' llm-in-a-box-sess-lg3 </dev/null >$LLG/lg3.log 2>&1; \
        grep -q 'Found existing docker session' $LLG/lg3.log \
        && grep -q 'old (legacy) session' $LLG/lg3.log"

# ── LG3b: exact-prefix matching — lookalikes are NOT sessions ──────────────
# Requirement: image classification is EXACT-PREFIX only
# (box-of-claude: / llm-in-a-box:). Today's *box-of-claude* substring
# glob wrongly treated a lookalike image as a session (red-phase
# history); the relay image (llm-in-a-box-relay:*) is never a session
# either (regression guard).
lg_fake lg3b
printf 'llm-in-a-box-sess-lg3b|||evil/box-of-claude-backdoor:1|running|docker||\n' > "$LLG/table-lg3b"
check "LG3b lookalike image evil/box-of-claude-backdoor:1 is NOT a session" \
    "cd $LLG/state-lg3b && $(LGEV lg3b) '$BOC' llm-in-a-box-sess-lg3b </dev/null >$LLG/lg3b.log 2>&1; \
        ! grep -q 'Found existing' $LLG/lg3b.log \
        && grep -q 'No .* image found' $LLG/lg3b.log"

lg_fake lg3r
printf 'llm-in-a-box-sess-lg3r|||llm-in-a-box-relay:latest|running|docker||\n' > "$LLG/table-lg3r"
check "LG3b relay image llm-in-a-box-relay:latest is NOT a session (regression guard)" \
    "cd $LLG/state-lg3r && $(LGEV lg3r) '$BOC' llm-in-a-box-sess-lg3r </dev/null >$LLG/lg3r.log 2>&1; \
        ! grep -q 'Found existing' $LLG/lg3r.log"

# ── LG4: destroy/stop/shutdown/list on legacy containers ───────────────────
# Requirement: destructive/state ops work on legacy containers
# (regression guards); the legacy note is asserted on destroy; the
# destroy cleanup records the OLD-prefix
# relay/network names (LG4-cleanup, pins amendment 11 — old
# sessions must not orphan their relays; passes today, must keep
# passing after the rename).
lg_fake lg4
printf 'llm-in-a-box-sess-lg4|box-of-claude.runtime|docker|llm-in-a-box:docker|running|||\n' > "$LLG/table-lg4"
check "LG4 destroy of a legacy container works (regression guard)" \
    "cd $LLG/state-lg4 && $(LGEV lg4) '$BOC' --destroy llm-in-a-box-sess-lg4 </dev/null >$LLG/lg4d.log 2>&1; [ \$? -eq 0 ] \
        && grep -q 'Removing container' $LLG/lg4d.log"

check "LG4 destroy of a legacy container emits an old note" \
    "cd $LLG/state-lg4 && $(LGEV lg4) '$BOC' --destroy llm-in-a-box-sess-lg4 </dev/null >$LLG/lg4dn.log 2>&1; \
        grep -q 'old (legacy) session' $LLG/lg4dn.log"

check "LG4 destroy of a legacy container cleans old-prefix relay/network names (regression guard)" \
    "cd $LLG/state-lg4 && $(LGEV lg4) '$BOC' --destroy llm-in-a-box-sess-lg4 </dev/null >$LLG/lg4c.log 2>&1; \
        grep -q 'rm -f boc-relay-llm-in-a-box-sess-lg4' $LLG/log-lg4 \
        && grep -q 'network rm boc-net-llm-in-a-box-sess-lg4' $LLG/log-lg4"

check "LG4 stop of a legacy container works (regression guard)" \
    "cd $LLG/state-lg4 && $(LGEV lg4) '$BOC' --stop llm-in-a-box-sess-lg4 </dev/null >$LLG/lg4s.log 2>&1; [ \$? -eq 0 ] \
        && grep -q 'Stopping container' $LLG/lg4s.log"

check "LG4 shutdown of a legacy container works (regression guard)" \
    "cd $LLG/state-lg4 && $(LGEV lg4) '$BOC' --shutdown llm-in-a-box-sess-lg4 </dev/null >$LLG/lg4sh.log 2>&1; [ \$? -eq 0 ] \
        && grep -q 'Stopping container' $LLG/lg4sh.log"

check "LG4 list shows a legacy container (regression guard)" \
    "cd $LLG/state-lg4 && $(LGEV lg4) '$BOC' --list >$LLG/lg4l.log 2>&1; \
        grep -q 'llm-in-a-box-sess-lg4' $LLG/lg4l.log"

# ── LG5: new containers carry the NEW runtime label ────────────────────────
# Requirement: sessions created after the rename get
# llm-in-a-box.runtime=<runtime>. Red-phase history: the old
# launcher set no runtime label at creation at all.
lg_fake lg5
printf 'llm-in-a-box:docker\nllm-in-a-box:docker\n' > "$LLG/exist-lg5"
check "LG5 new container carries the llm-in-a-box.runtime label" \
    "cd $LLG/state-lg5 && $(LGEV lg5) '$BOC' --runtime docker llm-sess-lg5 </dev/null >$LLG/lg5.log 2>&1; \
        grep -q -- '--label llm-in-a-box.runtime=docker' $LLG/log-lg5"

# ── LG5b: the NEW label is read back (primary, no legacy note) ─────────────
# Requirement: a container with the new label attaches as a PRIMARY
# session with NO legacy note. Without this check the launcher could
# write LG5's label and never read it and the whole suite would pass.
# Red-phase history: the old launcher read only the old label, so the
# container looks missing.
lg_fake lg5b
printf 'llm-sess-lg5b|llm-in-a-box.runtime|docker|llm-in-a-box:docker|running|||\n' > "$LLG/table-lg5b"
check "LG5b new-label container attaches as primary with no legacy note" \
    "cd $LLG/state-lg5b && $(LGEV lg5b) '$BOC' llm-sess-lg5b </dev/null >$LLG/lg5b.log 2>&1; \
        grep -q 'Found existing docker session' $LLG/lg5b.log \
        && ! grep -q 'old (legacy) session' $LLG/lg5b.log"

# ── LG6: old vm state dir is NOT migrated ──────────────────────────────────
# Requirement (user decision 2026-09-14, Q8): vm sessions in the old
# ~/.box-of-claude are left behind; --destroy of such a name is a clean
# "does not exist" no-op. Fixture is HOME-based ON PURPOSE: session at
# $HOME/.box-of-claude/sessions/<name> with NO state-dir seam, so the
# OLD default found it (red-phase history) and the NEW default
# ($HOME/.llm-in-a-box) does not. Exempt from the phase-2 blanket seam
# rename. Destroy, not launch: a missing name on the launch path
# triggers auto-create.
lg_fake lg6
mkdir -p "$LLG/home-lg6/.box-of-claude/sessions/llm-sess-lg6"
touch "$LLG/home-lg6/.box-of-claude/sessions/llm-sess-lg6/overlay.qcow2"
check "LG6 vm session under the OLD state dir is not found by the renamed launcher" \
    "$(LGEV lg6) '$BOC' --destroy llm-sess-lg6 </dev/null >$LLG/lg6.log 2>&1; [ \$? -eq 0 ] \
        && grep -q 'does not exist' $LLG/lg6.log"

# ── LG7: usage names the new launcher ──────────────────────────────────────
# Requirement: user-facing text names lbx. Red-phase
# history: usage
# says lbx.
check "LG7 usage output names lbx" \
    "'$BOC' --bogus-option </dev/null >$LLG/lg7.log 2>&1; [ \$? -ne 0 ] \
        && grep -q 'lbx' $LLG/lg7.log"

# ── LG7b/c/d: --help / -h / -? are real options ──────────────────────────
# Requirement (2026-09-20): explicit help is SUCCESS — usage to STDOUT,
# exit 0 — while option errors keep usage on STDERR with exit != 0 (LG7
# pins that path). Theory: the help arm must run before any config/session
# side effect, so it must succeed even in a bare environment.
check "LG7b --help prints usage to stdout and exits 0" \
    "'$BOC' --help </dev/null >$LLG/lg7b.log 2>$LLG/lg7b.err; [ \$? -eq 0 ] \
        && grep -q 'Usage: lbx' $LLG/lg7b.log \
        && [ ! -s $LLG/lg7b.err ]"
check "LG7c -? prints usage to stdout and exits 0" \
    "'$BOC' '-?' </dev/null >$LLG/lg7c.log 2>$LLG/lg7c.err; [ \$? -eq 0 ] \
        && grep -q 'Usage: lbx' $LLG/lg7c.log \
        && grep -q -- '--publish' $LLG/lg7c.log"
check "LG7d -h prints usage to stdout and exits 0" \
    "'$BOC' -h </dev/null >$LLG/lg7d.log 2>$LLG/lg7d.err; [ \$? -eq 0 ] \
        && grep -q 'Usage: lbx' $LLG/lg7d.log \
        && grep -q 'runtime.default' $LLG/lg7d.log"

# ── LG10: runtime.default (option A: preferred-first) ─────────────────────
# Requirement (2026-09-20): the config key / LLMBOX_RUNTIME_DEFAULT env is
# tried FIRST by auto-detect when usable; falls back to the standard order
# with a warning otherwise; invalid values warn and are ignored. Theory:
# driving the launcher against the shim with a per-check config file and
# image-existence set: the auto-detect line names the winner.
lg_fake lg10a
mkdir -p "$LLG/home-lg10a/.config/llm_in_a_box"
printf 'llm-in-a-box:sysbox\nllm-in-a-box:docker\n' > "$LLG/exist-lg10a"
printf 'runtime.default=sysbox\n' > "$LLG/home-lg10a/.config/llm_in_a_box/config"
check "LG10a runtime.default is preferred by auto-detect when usable" \
    "cd $LLG/state-lg10a && $(LGEV lg10a) '$BOC' lg10a-sess </dev/null >$LLG/lg10a.log 2>&1; \
        grep -q 'Auto-detected runtime: sysbox' $LLG/lg10a.log \
        && ! grep -q 'unknown key' $LLG/lg10a.log"

lg_fake lg10b
mkdir -p "$LLG/home-lg10b/.config/llm_in_a_box"
printf 'llm-in-a-box:sysbox\n' > "$LLG/exist-lg10b"
printf 'runtime.default=docker\n' > "$LLG/home-lg10b/.config/llm_in_a_box/config"
check "LG10b unusable runtime.default warns and falls back to auto-detect" \
    "cd $LLG/state-lg10b && $(LGEV lg10b) '$BOC' lg10b-sess </dev/null >$LLG/lg10b.log 2>&1; \
        grep -q 'not usable here' $LLG/lg10b.log \
        && grep -q 'Auto-detected runtime: sysbox' $LLG/lg10b.log"

lg_fake lg10c
mkdir -p "$LLG/home-lg10c/.config/llm_in_a_box"
printf 'llm-in-a-box:sysbox\n' > "$LLG/exist-lg10c"
printf 'runtime.default=kata\n' > "$LLG/home-lg10c/.config/llm_in_a_box/config"
check "LG10c invalid runtime.default warns and is ignored" \
    "cd $LLG/state-lg10c && $(LGEV lg10c) '$BOC' lg10c-sess </dev/null >$LLG/lg10c.log 2>&1; \
        grep -q 'invalid runtime.default' $LLG/lg10c.log \
        && grep -q 'Auto-detected runtime: sysbox' $LLG/lg10c.log"

lg_fake lg10d
printf 'llm-in-a-box:docker\nllm-in-a-box:sysbox\n' > "$LLG/exist-lg10d"
check "LG10d an explicit --runtime flag beats runtime.default (CLI > env > config)" \
    "cd $LLG/state-lg10d && $(LGEV lg10d) LLMBOX_RUNTIME_DEFAULT=sysbox '$BOC' --runtime docker lg10d-sess </dev/null >$LLG/lg10d.log 2>&1; \
        ! grep -q 'Auto-detected runtime' $LLG/lg10d.log \
        && grep -q -- '--privileged' $LLG/log-lg10d \
        && grep -q 'Creating new container' $LLG/lg10d.log"

# ── LG11: --publish exposes a box port (container runtime) ────────────────
# Requirement (2026-09-20): --publish <hostport>:<boxport> translates to
# docker -p for sysbox/docker sessions. Theory: the shim records the run
# argv; the published pair must appear verbatim.
lg_fake lg11
printf 'llm-in-a-box:docker\n' > "$LLG/exist-lg11"
check "LG11 --publish adds docker -p for a container session" \
    "cd $LLG/state-lg11 && $(LGEV lg11) '$BOC' --runtime docker --publish 18080:4000 lg11-sess </dev/null >$LLG/lg11.log 2>&1; \
        grep -q -- '-p 18080:4000' $LLG/log-lg11"

# ── LG12: state.dir config key re-homes box state ─────────────────────────
# Requirement (2026-09-20): env/key parity — state.dir in the config file
# puts session metadata under that dir (like LLMBOX_STATE_DIR). Theory: a
# session dir planted under <cfg-dir>/sessions/<name> shows up in --list
# when the config names that dir and no env var overrides it.
lg_fake lg12
mkdir -p "$LLG/home-lg12/.config/llm_in_a_box" "$LLG/cfgstatedir/sessions/lg12-sess"
touch "$LLG/cfgstatedir/sessions/lg12-sess/overlay.qcow2"
printf "state.dir=$LLG/cfgstatedir\n" > "$LLG/home-lg12/.config/llm_in_a_box/config"
check "LG12 state.dir config key re-homes box state" \
    "cd $LLG/state-lg12 && $(LGEV lg12) '$BOC' --list >$LLG/lg12.log 2>&1; \
        [ \$? -eq 0 ] \
        && grep -q 'lg12-sess' $LLG/lg12.log"

# ── LG8: legacy net-policy label is read (regression guard) ────────────────
# Requirement: --list shows the policy column for legacy sessions using
# the old label. Regression guard: the current --list already reads the
# old label; the rename must not drop it.
lg_fake lg8
printf 'llm-in-a-box-sess-lg8|box-of-claude.net-policy|/tmp/llmlg-policy.json|llm-in-a-box:docker|running||box-of-claude.net-policy|/tmp/llmlg-policy.json\n' > "$LLG/table-lg8"
check "LG8 --list shows the policy column for a legacy session (regression guard)" \
    "cd $LLG/state-lg8 && $(LGEV lg8) '$BOC' --list >$LLG/lg8.log 2>&1; \
        grep -q 'llm-in-a-box-sess-lg8' $LLG/lg8.log \
        && grep -q '/tmp/llmlg-policy.json' $LLG/lg8.log"

# ── LG9: the old-box START gate (containers) ─────────────────────────────
# Requirement (2026-09-20): lbx stamps the box-user era (llm-in-a-box.user)
# on every container it CREATES; a stopped container WITHOUT the stamp was
# created by old tooling and lbx REFUSES to start it, pointing at the
# previous launcher (cleanup ops and attach-to-running stay available).
# Theory: a shim table row in 'exited' state with no user stamp must fail
# the start with the refusal message and never invoke `docker start`;
# the mirror row WITH a stamp must start normally.
lg_fake lg9
printf 'llm-sess-lg9|llm-in-a-box.runtime|docker|llm-in-a-box:docker|exited|||\n' > "$LLG/table-lg9"
check "LG9 lbx refuses to start an old container (no box-user stamp) and recommends the previous launcher" \
    "cd $LLG/state-lg9 && $(LGEV lg9) '$BOC' --runtime docker llm-sess-lg9 </dev/null >$LLG/lg9.log 2>&1; [ \$? -ne 0 ] \
        && grep -q 'is an OLD box' $LLG/lg9.log \
        && grep -q 'previous llm_in_a_box script' $LLG/lg9.log \
        && ! grep -q '^start llm-sess-lg9' $LLG/log-lg9"

lg_fake lg9b
printf 'llm-sess-lg9b|llm-in-a-box.runtime|docker|llm-in-a-box:docker|exited||||agent\n' > "$LLG/table-lg9b"
check "LG9b lbx starts a current-era container (has the box-user stamp)" \
    "cd $LLG/state-lg9b && $(LGEV lg9b) '$BOC' --runtime docker llm-sess-lg9b </dev/null >$LLG/lg9b.log 2>&1; [ \$? -eq 0 ] \
        && ! grep -q 'is an OLD box' $LLG/lg9b.log \
        && grep -q '^start llm-sess-lg9b' $LLG/log-lg9b"

# ── ST1: the store image path is the project directory's …/docker-store.img ──
# Requirement (ADR 013): the store image is a PER-PROJECT artifact in the
# NON-CONFIGURABLE vms_and_docker_from_llm_box subdirectory of the box's
# project directory; the store image lives there. HOME must be
# irrelevant (there is no $HOME/.llm-in-a-box fallback), and so must
# LLMBOX_STATE_DIR (the machine-wide state directory holds host-side VM
# images, not the project's store). Theory: sourcing the
# launcher with cwd=<scratch> and a different HOME, the resolved store image
# is exactly <scratch>/vms_and_docker_from_llm_box/docker-store.img.
skip "ST1 store image is the project directory's vms_and_docker_from_llm_box/docker-store.img (HOME irrelevant) (moved to the Rust crate's unit tests)"

# ── ST2: net-policy JSONs copy to the NEW config dir ───────────────────────
# Requirement: shipped policies land in ~/.config/llm_in_a_box/ on
# first use. Behavioral side-effect check: asserts the RESULTING FILE's
# content matches the shipped policy JSON (not a bare existence check).
# Red-phase history: the copy landed in the old launcher's config directory.
if command -v python3 >/dev/null 2>&1; then
    lg_fake st2
    check "ST2 net-policy JSONs copy to $HOME/.config/llm_in_a_box/ with matching content" \
        "cd $LLG/state-st2 && $(LGEV st2) '$BOC' --net-policy '$SCRIPT_DIR/../net-policies/open.json' llm-sess-st2 </dev/null >$LLG/st2.log 2>&1; \
            [ -f $LLG/home-st2/.config/llm_in_a_box/open.json ] \
            && cmp -s '$SCRIPT_DIR/../net-policies/open.json' $LLG/home-st2/.config/llm_in_a_box/open.json"
else
    skip "ST2 net-policy copy target (python3 not found — policy validation requires it)"
fi

# ── T35/T36: the sysbox launch path is unchanged (regression pins) ───────
# Requirement SB8 (plan 2026_10_10_sysbox_idmap_loss): the damaged-box
# detection and the fusermount3 check must not alter the EXISTING sysbox
# launch behavior — neither the refusal when the runtime is absent, nor
# the arguments a successful launch passes to docker.
#
# WHY these exist: the plan adds checks to the launcher's sysbox path. The
# risk is not that the new checks fail, it is that they change a path that
# already works: an extra guard that refuses a valid launch, or an extra
# argument reaching `docker run`. These two checks pin the old behavior so
# the new checks cannot regress it silently.
#
# LLM-FRIENDLY NOTE on the harness: tests/fake-docker.sh ALWAYS reports
# sysbox-runc in its runtimes list (its documented contract), so the
# runtime-ABSENT case cannot be produced through the fake. T35 therefore
# uses the real docker host and skips where sysbox-runc is installed —
# which is exactly the situation on the machine this suite runs on. T36
# uses the fake, because "what arguments did the launch pass" is precisely
# what the fake records.
if ! command -v python3 >/dev/null 2>&1; then
    skip "T35 sysbox launch refuses when sysbox-runc is absent (python3 not found)"
else
    # ── T35: the runtime-missing refusal is unchanged ─────────────────────
    # The fake models a host without sysbox-runc through
    # FAKE_NO_SYSBOX_RUNTIME (tests/fake-docker.sh), so this check runs on
    # every host, including one that has sysbox installed. The seam models a
    # real host rather than changing the launcher: `docker_has_runtime` asks
    # the docker daemon, and a daemon without the runtime is exactly what a
    # host without sysbox has. On a host WITH sysbox the real daemon would
    # answer yes and the refusal could never be reached, which is why the
    # check previously skipped there and, on a host without sysbox, would
    # have asked the fake (which always answered yes).
    lg_fake t35
    printf 'llm-in-a-box:sysbox\n' > "$LLG/exist-t35"
    T35_OUT="$(cd "$LLG/state-t35" && eval "$(LGEV t35)" FAKE_NO_SYSBOX_RUNTIME=1 "$BOC" --runtime sysbox llm-sess-t35 </dev/null 2>&1)"
    T35_STATUS=$?
    check "T35 sysbox launch still refuses when sysbox-runc is absent, with its existing message" \
        "printf '%s' \"\$T35_OUT\" | grep >/dev/null 'sysbox-runc runtime not found' && [ \"\$T35_STATUS\" != 0 ]"
fi

# ── T36: a successful launch passes no new argument to docker run ────────
# THEORY: the fake records every docker invocation, so the `run -d` line
# for a sysbox launch can be inspected directly. The launch must reach
# `docker run`, must carry the sysbox runtime and the runtime label, and
# must pass no argument the launcher did not pass before. Asserting the
# absence of new arguments is what makes "nothing else changes"
# measurable rather than aspirational.
lg_fake t36
printf 'llm-in-a-box:sysbox\n' > "$LLG/exist-t36"
# A container table with no such session, so the launcher takes its CREATE
# path (which is where docker run happens).
: > "$LLG/table-t36"
( cd "$LLG/state-t36" && eval "$(LGEV t36)" "$BOC" --runtime sysbox llm-sess-t36 </dev/null >"$LLG/t36.out" 2>&1 ) || true
T36_RUN="$(grep -m1 '^run ' "$LLG/log-t36" 2>/dev/null || true)"
T36_REACHED=false
[ -n "$T36_RUN" ] && T36_REACHED=true
T36_SHAPE=true
if [ "$T36_REACHED" = true ]; then
    printf '%s' "$T36_RUN" | grep >/dev/null -- '--runtime=sysbox-runc' || T36_SHAPE=false
    printf '%s' "$T36_RUN" | grep >/dev/null 'llm-in-a-box.runtime=sysbox' || T36_SHAPE=false
fi
check "T36 sysbox launch reaches docker run with the same runtime and label shape (no new argument)" \
    "[ \"\$T36_REACHED\" = true ] && [ \"\$T36_SHAPE\" = true ]"

echo ""
echo "test_llm_in_a_box_sessions.sh: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
[ "$FAIL" -eq 0 ]
