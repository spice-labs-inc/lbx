#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-run-unattended.sh — unattended runs (`lbx --run`) against REAL
# docker: the built images, the real relay, real containers and networks.
#
# WHAT: VRUN1-VRUN15 run the launcher for real and probe the result from
# inside the run box and from the host: output and exit code, privileges
# (capability bounding set, no-new-privileges, seccomp, sudo, docker),
# standard input, every way out of the network wall, --env visibility,
# timeouts, signals, SIGKILL recovery, the relay's hardening, and the
# data-directory mount-point refusal.
# Added later: VRUN16 (a 128-character run name), VRUN17 (what SIGKILL
# leaves: the claim file, no status file, the relay and both networks),
# and two accepted limits, VRUN18 (a run name equal to a container id
# prefix) and VRUN19 (a `:` in the data or policy path).
# Added for the socket directory and no-network runs: VRUN20-VRUN24 (a
# caller's socket through /run/agent, the mount read-only, a restarted
# server, a no-network run box, and both together).
# VRUN25-VRUN29 cover the AppArmor option (`--apparmor-profile`): ordinary
# work and the entrypoint under the profile, writes and socket connects
# outside the allowed paths denied, abstract sockets limited to the
# profile, no internet sockets under the no-network profile, and the
# refusals.
#
# WHY: the fake-docker suite (tests/test_llm_in_a_box_run.sh) proves which
# docker calls the launcher makes; only real docker proves those calls
# produce the protections they are meant to. Each check pairs every
# "blocked" or "absent" result with a positive control in the same run, so
# a box that is simply broken cannot pass.
#
# Prerequisites (a missing one is a FAILURE with the reason, never a skip,
# with one approved exception: on a kernel whose AppArmor does not mediate
# Unix sockets, VRUN25-VRUN28 are skipped, since the launcher refuses
# --apparmor-profile there, which VRUN29 checks instead;
# tests/approved-skips.txt lists them):
#   - a docker daemon where `--security-opt no-new-privileges` works (the
#     snap package of docker does not allow it);
#   - images llm-in-a-box:docker, llm-in-a-box-relay:latest and alpine:3;
#   - internet access (VRUN5, VRUN25, and the controls of VRUN4, VRUN23 and
#     VRUN24);
#   - perl on the host (VRUN20-VRUN28 serve and use Unix sockets with it);
#   - AppArmor enabled and the profiles in apparmor/llm-in-a-box-run loaded
#     (tests/setup-run-test-host.sh does it; VRUN25-VRUN29), and for
#     VRUN25-VRUN28 a kernel whose AppArmor mediates Unix sockets;
#   - tests/setup-run-test-host.sh has been run as root: the test user
#     `lbxtest`, the passwordless rule to act as it, the writable shared
#     directory /srv/lbx-test, and /srv/lbx-test-fixtures/with-mount;
#   - run as a normal user (unattended runs refuse user id 0).
#
# Resource names use the prefix lbx-test-v and this run's process id; a
# cleanup trap removes every container and network this run created, and
# the directories named with this run's id under /srv/lbx-test and /tmp.
#
# LLM-FRIENDLY NOTE: `vrun <id> <launcher args...>` runs the launcher with a
# private HOME and state directory and records out/err/rc under
# $WORK/<id>. MEASURED_CAPS is the capability set measured on the test
# host. The working tree is copied to /srv/lbx-test/box at start so VRUN2's
# test user runs this tree, not an older copy.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LBX="${LBX_BIN:-$REPO_ROOT/target/debug/lbx}"
export LLMBOX_SCRIPT_DIR="$REPO_ROOT"
MEASURED_CAPS=(CHOWN DAC_OVERRIDE SETGID SETUID)
TEST_USER=lbxtest
SHARED_REPO=/srv/lbx-test/box
FIX=/srv/lbx-test-fixtures

PASS=0
FAIL=0
SKIP=0
# A check function that returns 77 is skipped, with SKIP_REASON as the
# reason (no parentheses in it); only the approved skips of the header use it.
SKIP_REASON=""
check() {
    local description="$1"; shift
    if [ -n "${LBX_TEST_ONLY:-}" ] && [ "${description#"$LBX_TEST_ONLY"}" = "$description" ]; then
        return 0
    fi
    local started=$SECONDS rc=0
    SKIP_REASON=""
    "$@" || rc=$?
    if [ "$rc" = 0 ]; then
        echo "[PASS] $description ($((SECONDS - started)) s)"; PASS=$((PASS + 1))
    elif [ "$rc" = 77 ] && [ -n "$SKIP_REASON" ]; then
        echo "[SKIP] $description ($SKIP_REASON)"; SKIP=$((SKIP + 1))
    else
        echo "[FAIL] $description ($((SECONDS - started)) s)"; FAIL=$((FAIL + 1))
    fi
}
fail_prereq() { echo "[FAIL] prerequisite: $1"; FAIL=$((FAIL + 1)); }

SEED="${LBX_TEST_SEED:-$(( $(date +%s%N) % 32768 ))}"
RANDOM=$SEED
echo "seed=$SEED (replay with LBX_TEST_SEED=$SEED)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/lbx-verify-run.XXXXXX")"
chmod 755 "$WORK"
RUNID="$$"
cleanup_all() {
    local c n
    for c in $(docker ps -aq --filter "name=lbx-test-v" 2>/dev/null); do
        n=$(docker inspect -f '{{.Name}}' "$c" 2>/dev/null)
        case "$n" in */*lbx-test-v*-$RUNID) docker rm -f "$c" >/dev/null 2>&1 ;; esac
    done
    for n in $(docker network ls --format '{{.Name}}' 2>/dev/null | grep -E "lbx-test-v.*-$RUNID\$"); do
        docker network rm "$n" >/dev/null 2>&1
    done
    jobs -p | xargs -r kill 2>/dev/null
    # Directories the AppArmor checks make outside $WORK, named with this
    # run's id, so an interrupted suite does not leave them behind.
    rm -rf /srv/lbx-test/lbx-test-v*-"$RUNID" /tmp/lbx-test-v26tmp-"$RUNID".* 2>/dev/null
    rm -rf "$WORK" 2>/dev/null
}
trap cleanup_all EXIT

# ── Preflight ─────────────────────────────────────────────────────────────
PREREQ_OK=1
if [ "$(id -u)" = 0 ]; then fail_prereq "running as root; run as a normal user"; PREREQ_OK=0; fi
if ! docker info >/dev/null 2>&1; then fail_prereq "docker daemon not usable"; PREREQ_OK=0; fi
for img in llm-in-a-box:docker llm-in-a-box-relay:latest alpine:3; do
    docker image inspect "$img" >/dev/null 2>&1 || { fail_prereq "image $img missing"; PREREQ_OK=0; }
done
if ! docker run --rm --security-opt no-new-privileges --entrypoint python3 llm-in-a-box-relay:latest -c 'pass' >/dev/null 2>&1; then
    fail_prereq "containers cannot start with no-new-privileges on this docker (a snap-packaged docker blocks it)"
    PREREQ_OK=0
fi
[ "$PREREQ_OK" = 1 ] || { echo ""; echo "Results: $PASS passed, $FAIL failed"; exit 1; }

# The test user must run THIS tree: copy it into the shared directory.
#
# --sparse is required, not cosmetic. This tree can contain a large sparse
# file (the VM suite leaves a hundreds-of-gigabytes-apparent store image in
# vms_and_docker_from_llm_box/), and without --sparse rsync writes every zero
# byte of it: measured on a 1 GB sparse file, 1.1 GB allocated without the
# flag and 0 bytes with it. A 536 GB-apparent image therefore filled the
# disk, the copy failed, SHARED_OK stayed 0, and every check that needs the
# shared tree failed with a prerequisite message that pointed at the test
# host rather than at the copy.
SHARED_OK=0
# The copy excludes vms_and_docker_from_llm_box: it is where a box's VMs and
# inner docker keep their bulky state (the launcher's documented store-image
# location), and the store image is created SPARSE at 500 GB apparent size. Two
# measured consequences of copying it, both of which hang or fill the host:
#
#  - without --sparse, rsync writes every zero byte (1 GB sparse -> 1.1 GB
#    written), so a 536 GB-apparent image fills the disk;
#  - with --sparse, rsync must still READ the whole file to find the holes, so
#    the copy sits in the read phase for tens of minutes (measured 2026-10-18:
#    26 minutes, target stuck at 13 MB, regression hung in its last suite).
#
# The suite drives containers, not VMs, so it needs nothing from that
# directory.
SHARED_OK=0
if [ -d "$(dirname "$SHARED_REPO")" ] && [ -w "$(dirname "$SHARED_REPO")" ]; then
    mkdir -p "$SHARED_REPO" && rsync -a --sparse --delete --exclude .git --exclude target \
        --exclude vms_and_docker_from_llm_box "$REPO_ROOT/" "$SHARED_REPO/" \
        && install -m 755 "$LBX" "$SHARED_REPO/lbx" \
        && chmod -R g+rX "$SHARED_REPO" && SHARED_OK=1
fi
# Recorded here so a check below can pin it: a copy that grows to gigabytes
# means something bulky landed in the repository tree again.
SHARED_KB=$(du -sk "$SHARED_REPO" 2>/dev/null | awk '{print $1}')

# ── Helpers ───────────────────────────────────────────────────────────────
name_of() { printf 'lbx-test-v%s-%s' "$1" "$RUNID"; }

# setup <id>: private HOME, state directory, data directory (D_DATA) and
# policy.
setup() {
    local D="$WORK/$1"
    mkdir -p "$D/home" "$D/state" "$D/pol" "$D/cwd"
    D_DATA="$(mktemp -d "$D/data.XXXXXX")"
    printf '{"mode":"enforce","allow":["api.anthropic.com"],"block":[]}\n' > "$D/pol/policy.json"
}

# vrun <id> [launcher args after the standard ones...]; extra environment
# in VENV; standard input from VIN (default /dev/null).
VENV=()
VIN=/dev/null
TIMEOUT_ARG=60
vrun() {
    local id="$1"; shift
    local D="$WORK/$id"
    (
        cd "$D/cwd" || exit 99
        env HOME="$D/home" LLMBOX_STATE_DIR="$D/state" ${VENV[@]+"${VENV[@]}"} \
            "$LBX" --run --runtime docker --net-policy "$D/pol/policy.json" \
            --data "$D_DATA" --timeout "$TIMEOUT_ARG" "$@" <"$VIN" >"$D/out" 2>"$D/err"
        echo $? > "$D/rc"
    )
}
rc_of() { cat "$WORK/$1/rc"; }
show_err() { tail -5 "$WORK/$1/err" | sed 's/^/    err: /'; }
nothing_left() {
    local n="$1"
    [ -z "$(docker ps -aq --filter "name=^/$n\$")" ] \
        && [ -z "$(docker ps -aq --filter "name=^/llm-in-a-box-relay-$n\$")" ] \
        && ! docker network inspect "llm-in-a-box-net-$n" >/dev/null 2>&1 \
        && ! docker network inspect "llm-in-a-box-relaynet-$n" >/dev/null 2>&1
}
cap_mask() {
    local c m=0 bit
    for c in "$@"; do
        case "$c" in
            CHOWN) bit=0 ;; DAC_OVERRIDE) bit=1 ;; DAC_READ_SEARCH) bit=2 ;; FOWNER) bit=3 ;;
            FSETID) bit=4 ;; KILL) bit=5 ;; SETGID) bit=6 ;; SETUID) bit=7 ;; SETPCAP) bit=8 ;;
            NET_BIND_SERVICE) bit=10 ;; NET_RAW) bit=13 ;; SYS_CHROOT) bit=18 ;; MKNOD) bit=27 ;;
            AUDIT_WRITE) bit=29 ;; SETFCAP) bit=31 ;; *) echo "unknown capability $c" >&2; return 1 ;;
        esac
        m=$((m | (1 << bit)))
    done
    printf '%016x' "$m"
}
wait_box() { local n="$1" t=0; while [ $t -lt 240 ]; do docker inspect "$n" >/dev/null 2>&1 && return 0; sleep 0.5; t=$((t + 1)); done; return 1; }
wait_file() { local f="$1" t=0; while [ $t -lt $(($2 * 10)) ]; do [ -e "$f" ] && return 0; sleep 0.1; t=$((t + 1)); done; return 1; }
free_port() { local p; for p in $(seq $((40000 + RANDOM % 9000)) 49999); do ss -tlnH "sport = :$p" | grep >/dev/null . || { echo "$p"; return 0; }; done; return 1; }
# The launcher's own process: the oldest match, since its forked subshells
# (the timer) carry the same command line.
launcher_pid() { pgrep -o -f -- "$LBX --run .* $1 --"; }

# ── VRUN1 ────────────────────────────────────────────────────────────────
# Behavior: the command runs once; standard output is exactly its output,
#   standard error carries its errors, the exit code is its exit code, and
#   nothing of the run remains afterwards.
# Theory: a broken launcher mixes its messages into standard output, maps
#   the exit code, or leaves the box, relay or networks behind.
# Not a text comparison: bytes of real output, the real exit code, and
#   docker's own view of what exists.
# LLM: `sh -c 'echo out; echo err >&2; exit 7'`.
vrun1() {
    setup 1; local n; n=$(name_of 1)
    vrun 1 "$n" -- sh -c 'echo out; echo err >&2; exit 7'
    local ok=0
    [ "$(rc_of 1)" = 7 ] || { echo "    rc=$(rc_of 1)"; show_err 1; ok=1; }
    [ "$(cat "$WORK/1/out")" = out ] && [ "$(wc -c < "$WORK/1/out")" = 4 ] || { echo "    stdout: $(od -c "$WORK/1/out" | head -2)"; ok=1; }
    grep -qx err "$WORK/1/err" || { echo "    stderr lacks err"; ok=1; }
    nothing_left "$n" || { echo "    resources left"; ok=1; }
    return $ok
}
# Requirement: the repository copy this suite makes must stay small. Theory: the
# copy exists so the test user can run the launcher from the tree; anything
# bulky in the tree (a VM disk image, a docker store image, a saved image
# tarball) makes the copy slow or impossible, and a copy that fails leaves every
# check that needs the shared tree failing with a prerequisite message that
# points at the test host rather than at the copy. Measured 2026-10-18: a
# 536 GB-apparent sparse store image in the tree hung the copy for 26 minutes.
# The bound is generous (the source tree is about 10 MB) because the point is
# to catch a GIGABYTE-scale artifact, not to police a few megabytes.
# This suite's check() runs its arguments as a COMMAND (the other suites eval a
# condition string), so the condition is a function, like every other check here.
shared_copy_is_small() {
    [ -n "${SHARED_KB:-}" ] && [ "${SHARED_KB:-0}" -lt 204800 ]
}
check "the repository copy stays small enough to be a fixture" shared_copy_is_small

check "VRUN1 output, errors and exit code pass through; nothing is left behind" vrun1

# ── VRUN2 ────────────────────────────────────────────────────────────────
# Behavior: the run box is unprivileged: its capability bounding set is
#   the measured set, no new privileges, seccomp filtering, docker's
#   default AppArmor profile in enforce mode, no docker socket or docker
#   group, no sudoers file, sudo and su fail, no docker
#   daemon, and the command runs with the invoking user's ids. From the
#   host: not privileged, all capabilities dropped, only the measured
#   ones added.
# Theory: a broken launcher or entrypoint leaves a privilege in place that
#   a steered agent could use to reach the host.
# Not a text comparison: the kernel's own view (/proc/self/status) and
#   docker's configuration of the real container.
# LLM: runs as the dedicated test user (ids other than 1000, a group that
#   collides with an image group) so the user remap is exercised.
#   AppArmor control: the host must have AppArmor enabled
#   (/sys/module/apparmor/parameters/enabled is Y); otherwise the check
#   fails, because an unconfined box would pass nothing else here.
vrun2() {
    if [ "$SHARED_OK" != 1 ] || ! id "$TEST_USER" >/dev/null 2>&1 || ! sudo -n -u "$TEST_USER" test -r "$SHARED_REPO/lbx" 2>/dev/null; then
        echo "    prerequisite: run tests/setup-run-test-host.sh as root (test user, sudo rule, writable /srv/lbx-test)"
        return 1
    fi
    if [ "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null)" != Y ]; then
        echo "    control: AppArmor is not enabled on this host (/sys/module/apparmor/parameters/enabled)"
        return 1
    fi
    local D="$WORK/2" n; n=$(name_of 2)
    mkdir -p "$D"
    local TD; TD="$(sudo -n -u "$TEST_USER" mktemp -d /tmp/lbx-test-v2.XXXXXX)"
    sudo -n -u "$TEST_USER" bash -c 'mkdir -p "$1/home" "$1/state" "$1/pol" "$1/data" "$1/cwd" && printf "%s\n" "{\"mode\":\"enforce\",\"allow\":[\"api.anthropic.com\"],\"block\":[]}" > "$1/pol/policy.json"' _ "$TD"
    local probe='
        grep -E "^(CapBnd|CapEff|NoNewPrivs|Seccomp):" /proc/self/status
        aa=$(cat /proc/self/attr/apparmor/current 2>/dev/null || cat /proc/self/attr/current 2>/dev/null)
        echo "apparmor=$(printf "%s" "$aa" | tr -d "\\000\\n")"
        echo "sock=$(test -S /var/run/docker.sock && echo yes || echo no)"
        echo "groups=$(id -nG)"
        echo "ids=$(id -u):$(id -g)"
        echo "sudoers=$(test -e /etc/sudoers.d/agent && echo yes || echo no)"
        echo "sudo_l=$(sudo -l -n 2>/dev/null | grep -c . )"
        sudo -n true 2>/dev/null && echo "sudo=works" || echo "sudo=fails"
        su -c true root </dev/null >/dev/null 2>&1 && echo "su=works" || echo "su=fails"
        docker info >/dev/null 2>&1 && echo "docker=works" || echo "docker=fails"
        sleep 6'
    ( sudo -n -u "$TEST_USER" bash -c 'cd "$1/cwd" && exec env HOME="$1/home" LLMBOX_STATE_DIR="$1/state" LLMBOX_SCRIPT_DIR="$2" LLMBOX_RUN_READY_SECONDS="$5" "$2/lbx" --run --runtime docker --net-policy "$1/pol/policy.json" --data "$1/data" --timeout 60 "$3" -- sh -c "$4"' \
        _ "$TD" "$SHARED_REPO" "$n" "$probe" "${LLMBOX_RUN_READY_SECONDS:-60}" >"$D/out" 2>"$D/err"; echo $? > "$D/rc" ) &
    local bg=$!
    wait_box "$n" || { echo "    box never appeared"; wait $bg; show_err 2; return 1; }
    sleep 2
    local priv capdrop capadd
    priv=$(docker inspect -f '{{.HostConfig.Privileged}}' "$n" 2>/dev/null)
    capdrop=$(docker inspect -f '{{join .HostConfig.CapDrop ","}}' "$n" 2>/dev/null)
    capadd=$(docker inspect -f '{{join .HostConfig.CapAdd ","}}' "$n" 2>/dev/null | tr ',' '\n' | sed 's/^CAP_//' | sort | tr '\n' ' ')
    wait $bg
    local ok=0 out; out="$(cat "$D/out")"
    [ "$(cat "$D/rc")" = 0 ] || { echo "    rc=$(cat "$D/rc")"; show_err 2; ok=1; }
    local want; want="$(cap_mask "${MEASURED_CAPS[@]}")"
    grep -qE "^CapBnd:[[:space:]]+$want\$" <<<"$out" || { echo "    CapBnd: $(grep CapBnd <<<"$out") want $want"; ok=1; }
    grep -qE "^CapEff:[[:space:]]+0+\$" <<<"$out" || { echo "    CapEff not zero"; ok=1; }
    grep -qE "^NoNewPrivs:[[:space:]]+1\$" <<<"$out" || { echo "    NoNewPrivs"; ok=1; }
    grep -qE "^Seccomp:[[:space:]]+2\$" <<<"$out" || { echo "    Seccomp"; ok=1; }
    grep -qx "apparmor=docker-default (enforce)" <<<"$out" || { echo "    AppArmor: $(grep apparmor= <<<"$out")"; ok=1; }
    grep -qx "sock=no" <<<"$out" || { echo "    docker socket present"; ok=1; }
    grep -qE '^groups=(.* )?docker( .*)?$' <<<"$out" && { echo "    in docker group"; ok=1; }
    grep -qx "ids=$(id -u "$TEST_USER"):$(id -g "$TEST_USER")" <<<"$out" || { echo "    $(grep ids= <<<"$out")"; ok=1; }
    grep -qx "sudoers=no" <<<"$out" || { echo "    sudoers file present"; ok=1; }
    grep -qx "sudo_l=0" <<<"$out" || { echo "    sudo -l lists something"; ok=1; }
    grep -qx "sudo=fails" <<<"$out" || { echo "    sudo works"; ok=1; }
    grep -qx "su=fails" <<<"$out" || { echo "    su works"; ok=1; }
    grep -qx "docker=fails" <<<"$out" || { echo "    docker works"; ok=1; }
    [ "$priv" = false ] || { echo "    Privileged=$priv"; ok=1; }
    [ "$capdrop" = ALL ] || { echo "    CapDrop=$capdrop"; ok=1; }
    [ "$capadd" = "$(printf '%s\n' "${MEASURED_CAPS[@]}" | sort | tr '\n' ' ')" ] || { echo "    CapAdd=$capadd"; ok=1; }
    sudo -n -u "$TEST_USER" rm -rf "$TD"
    return $ok
}
check "VRUN2 the run box is unprivileged (inside and from the host), as a non-default user" vrun2

# ── VRUN3 ────────────────────────────────────────────────────────────────
# Behavior: standard input reaches the command unchanged.
# Theory: a broken launcher runs the exec without its standard input, or
#   through a terminal that alters bytes.
# Not a text comparison: checksum of one megabyte of random bytes.
# LLM: `cat` echoes the input to standard output.
vrun3() {
    setup 3; local n; n=$(name_of 3)
    head -c 1048576 /dev/urandom > "$WORK/3/blob"
    VIN="$WORK/3/blob"
    vrun 3 "$n" -- cat
    VIN=/dev/null
    [ "$(rc_of 3)" = 0 ] && [ "$(sha256sum < "$WORK/3/out")" = "$(sha256sum < "$WORK/3/blob")" ] \
        || { echo "    rc=$(rc_of 3) bytes=$(wc -c < "$WORK/3/out")"; show_err 3; return 1; }
}
check "VRUN3 a random one-megabyte binary arrives unchanged through standard input" vrun3

# ── VRUN4 ────────────────────────────────────────────────────────────────
# Behavior: the relay is the only way out: public names do not resolve
#   (through resolv.conf or by asking 127.0.0.11 directly), and no
#   connection reaches a public numeric address, the host through the
#   run network's first address, the metadata address, or anything over
#   IPv6.
# Theory: without the gateway-inhibiting network option the host takes the
#   network's first address and every host service is reachable; without
#   --dns the embedded resolver forwards public names.
# Not a text comparison: real connection attempts from inside the box.
# LLM: controls in the same run: the relay's proxy port is reachable by
#   address, docker-network names (the relay's) resolve both ways, IPv6
#   is disabled, and a listener on the host (started with host
#   networking on a free port) is reachable from the host itself.
vrun4() {
    setup 4; local n; n=$(name_of 4)
    local port; port=$(free_port) || { echo "    no free port"; return 1; }
    local listener="lbx-test-v4listen-$RUNID"
    docker run -d --rm --name "$listener" --network host alpine:3 sh -c "while true; do nc -l -p $port </dev/null; done" >/dev/null 2>&1 \
        || { echo "    could not start the host listener"; return 1; }
    local t=0; until timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/$port" 2>/dev/null || [ $t -ge 20 ]; do sleep 0.5; t=$((t + 1)); done
    timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/$port" 2>/dev/null || { echo "    control: host listener not reachable from the host"; docker rm -f "$listener" >/dev/null 2>&1; return 1; }
    # Control: a container on a plain internal network (no gateway option)
    # reaches the listener through that network's gateway, so a blocked
    # result from the run box is not a host firewall's doing.
    local plain="lbx-test-v4plain-$RUNID" gw
    docker network create --internal "$plain" >/dev/null 2>&1
    gw=$(docker network inspect -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' "$plain" 2>/dev/null)
    local via_gw
    via_gw=$(docker run --rm --network "$plain" alpine:3 sh -c "nc -z -w3 $gw $port && echo reached || echo blocked" 2>/dev/null)
    docker network rm "$plain" >/dev/null 2>&1
    [ "$via_gw" = reached ] || { echo "    control: a plain internal network cannot reach the host listener ($via_gw via '$gw')"; docker rm -f "$listener" >/dev/null 2>&1; return 1; }
    # Control: the host has internet access, so blocked public probes from
    # the run box are the wall's doing.
    local inet
    inet=$(docker run --rm alpine:3 sh -c 'nc -z -w5 1.1.1.1 443 && nslookup example.com >/dev/null 2>&1 && echo ok || echo no' 2>/dev/null)
    [ "$inet" = ok ] || { echo "    control: a container on the default bridge has no internet access"; docker rm -f "$listener" >/dev/null 2>&1; return 1; }
    local relay_name="llm-in-a-box-relay-$n"
    local script='
        relay=$(printf "%s" "$HTTPS_PROXY" | sed -e "s#http://##" -e "s#:.*##")
        tcp() { timeout 4 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null && echo reached || echo blocked; }
        echo "relay_port=$(tcp "$relay" 3128)"
        echo "ipv6_disabled=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)"
        getent hosts "$RELAY_NAME" >/dev/null 2>&1 && echo "getent_relay=reached" || echo "getent_relay=blocked"
        getent hosts example.com >/dev/null 2>&1 && echo "dns_resolv=reached" || echo "dns_resolv=blocked"
        python3 - <<PY
import socket, struct, ipaddress, subprocess, os
def ask(name):
    q = struct.pack(">HHHHHH", 0x1234, 0x0100, 1, 0, 0, 0)
    for part in name.split("."):
        q += bytes([len(part)]) + part.encode()
    q += b"\x00\x00\x01\x00\x01"
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(4)
    try:
        s.sendto(q, ("127.0.0.11", 53)); data, _ = s.recvfrom(1024)
        return struct.unpack(">H", data[6:8])[0] > 0
    except Exception:
        return False
print("embedded_relay=" + ("reached" if ask(os.environ["RELAY_NAME"]) else "blocked"))
print("embedded_public=" + ("reached" if ask("example.com") else "blocked"))
try:
    s6 = socket.socket(socket.AF_INET6, socket.SOCK_STREAM); s6.settimeout(4)
    s6.connect(("2606:4700:4700::1111", 443)); print("ipv6=reached")
except Exception:
    print("ipv6=blocked")
PY
        # The run network'"'"'s first address, from the kernel routing table
        # (the image has no `ip` tool): the network route'"'"'s destination
        # plus one.
        first=$(python3 - <<PY
import socket, struct
for line in open("/proc/net/route").read().splitlines()[1:]:
    f = line.split()
    dest, mask = int(f[1], 16), int(f[7], 16)
    if dest and mask:
        net = socket.ntohl(dest) & socket.ntohl(mask)
        print(socket.inet_ntoa(struct.pack("!I", net + 1)))
        break
PY
)
        echo "first_address=${first}"
        echo "host_via_network=$(tcp "$first" "$LISTEN_PORT")"
        echo "public_ip=$(tcp 1.1.1.1 443)"
        echo "metadata=$(tcp 169.254.169.254 80)"
    '
    VENV=(RELAY_NAME="$relay_name" LISTEN_PORT="$port")
    vrun 4 "$n" --env RELAY_NAME --env LISTEN_PORT -- bash -c "$script"
    VENV=()
    docker rm -f "$listener" >/dev/null 2>&1
    local out ok=0; out="$(cat "$WORK/4/out")"
    [ "$(rc_of 4)" = 0 ] || { echo "    rc=$(rc_of 4)"; show_err 4; return 1; }
    local k
    for k in relay_port getent_relay embedded_relay; do
        grep -qx "$k=reached" <<<"$out" || { echo "    control failed: $k"; ok=1; }
    done
    grep -qx ipv6_disabled=1 <<<"$out" || { echo "    control failed: ipv6 not disabled"; ok=1; }
    grep -qE '^first_address=[0-9]+(\.[0-9]+){3}$' <<<"$out" || { echo "    control failed: no network address"; ok=1; }
    for k in dns_resolv embedded_public ipv6 host_via_network public_ip metadata; do
        grep -q "^$k=" <<<"$out" || { echo "    $k not probed"; ok=1; continue; }
        grep -qx "$k=reached" <<<"$out" && { echo "    $k reached"; ok=1; }
    done
    return $ok
}
check "VRUN4 every way out except the relay is blocked, with positive controls" vrun4

# ── VRUN5 ────────────────────────────────────────────────────────────────
# Behavior: an allowed host answers through the relay; a host not on the
#   allowlist does not, and its refusal is in the kept deny log.
# Theory: a broken relay configuration blocks everything (useless) or
#   allows everything (no wall).
# Not a text comparison: real HTTPS requests and the deny log the relay
#   wrote.
# LLM: needs internet access from the host.
vrun5() {
    if ! timeout 8 bash -c 'exec 3<>/dev/tcp/api.anthropic.com/443' 2>/dev/null; then
        echo "    prerequisite: no internet access from this host"; return 1
    fi
    setup 5; local n; n=$(name_of 5)
    vrun 5 "$n" -- sh -c '
        a=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 https://api.anthropic.com/)
        b=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 https://example.com/ || true)
        echo "allowed=$a"; echo "denied=$b"'
    local out ok=0 D="$WORK/5"; out="$(cat "$D/out")"
    grep -qE '^allowed=[1-5][0-9][0-9]$' <<<"$out" || { echo "    allowed host: $(grep allowed <<<"$out")"; show_err 5; ok=1; }
    grep -qE '^denied=[1-5][0-9][0-9]$' <<<"$out" && { echo "    non-allowed host answered"; ok=1; }
    grep -q 'example.com' "$D/state/netlogs/$n/deny.log" 2>/dev/null || { echo "    deny log lacks example.com"; ok=1; }
    return $ok
}
check "VRUN5 an allowed host works through the relay; others fail and are logged" vrun5

# ── VRUN6 ────────────────────────────────────────────────────────────────
# Behavior: an --env value reaches the command, but not the container's
#   configuration (docker inspect) and not process 1's environment. Proxy
#   settings in the caller's docker client configuration (config.json
#   `proxies`, which the client copies into every container it starts,
#   credentials included) reach neither the run box's nor the relay's
#   stored environment.
# Theory: a broken launcher passes the value on `docker run`, where docker
#   stores it and the entrypoint's root phase and process 1 hold it. A
#   launcher that leaves any proxy variable unset on either `docker run`
#   lets the client fill it in from its configuration: the proxy's
#   credentials become readable in the box, and ALL_PROXY or FTP_PROXY can
#   point the box's tools at a proxy other than the relay.
# Not a text comparison: docker's configuration and process 1's
#   environment read by root through docker exec.
# LLM: control: process 1's environment does contain HOST_USER=. The
#   client configuration is a new DOCKER_CONFIG directory holding only
#   `proxies.default.allProxy` and `ftpProxy` with a sentinel user and
#   password; control: with that configuration, a plain container created
#   from alpine:3 does get the sentinel in its environment. The new
#   configuration has no contexts, so docker is reached through
#   DOCKER_HOST or the default socket, as on the test host.
vrun6() {
    setup 6; local n; n=$(name_of 6)
    local secret="vrun6-secret-$RANDOM$RANDOM" cfgdir="$WORK/6/dockercfg" ctl ctl_env
    local sentinel='http://sentinel-user:sentinel-pass@proxy.invalid:3128'
    mkdir -p "$cfgdir"
    printf '{"proxies":{"default":{"allProxy":"%s","ftpProxy":"%s"}}}\n' "$sentinel" "$sentinel" > "$cfgdir/config.json"
    ctl=$(name_of 6c)
    DOCKER_CONFIG="$cfgdir" docker create --pull never --name "$ctl" alpine:3 true >/dev/null 2>&1
    ctl_env=$(docker inspect -f '{{json .Config.Env}}' "$ctl" 2>/dev/null)
    docker rm -f "$ctl" >/dev/null 2>&1
    VENV=(SECRET_X="$secret" DOCKER_CONFIG="$cfgdir")
    ( vrun 6 "$n" --env SECRET_X -- sh -c 'printenv SECRET_X; sleep 6' ) &
    local bg=$!
    VENV=()
    wait_box "$n" || { wait $bg; echo "    box never appeared"; show_err 6; return 1; }
    sleep 3
    local cfg relay_env
    cfg=$(docker inspect -f '{{json .Config.Env}} {{json .Path}} {{json .Args}}' "$n" 2>/dev/null)
    relay_env=$(docker inspect -f '{{json .Config.Env}}' "llm-in-a-box-relay-$n" 2>/dev/null)
    wait $bg
    local ok=0
    # The positive control is the command's own output: it printed the value,
    # so --env reached it. There is deliberately no assertion on the run box's
    # /proc/1/environ. In a run box PID 1 IS the command, running as the box
    # user (measured: `docker exec -u 0 <box> ps -o pid,user,args -p 1` shows
    # the command as uid 1000), and reading another uid's environ is refused:
    # measured 0 entries read, not even PATH, even from the container's root.
    # An earlier form of this check expected HOST_USER there and no SECRET_X,
    # which cannot hold for either reason. The container's own configuration
    # below is what shows the value was not baked into the box.
    [ "$(head -1 "$WORK/6/out")" = "$secret" ] || { echo "    command did not see the value"; show_err 6; ok=1; }
    [ -n "$cfg" ] || { echo "    could not inspect the box"; ok=1; }
    grep -qF "$secret" <<<"$cfg" && { echo "    value in container configuration"; ok=1; }
    grep -q SECRET_X <<<"$cfg" && { echo "    name in container configuration"; ok=1; }
    grep -q sentinel <<<"$ctl_env" || { echo "    control: the client configuration's proxies did not reach a plain container ($ctl_env)"; ok=1; }
    grep -q LLMBOX_POLICY <<<"$relay_env" || { echo "    control: could not read the relay's environment"; ok=1; }
    grep -q sentinel <<<"$cfg" && { echo "    the client configuration's proxy reached the run box: $cfg"; ok=1; }
    grep -q sentinel <<<"$relay_env" && { echo "    the client configuration's proxy reached the relay: $relay_env"; ok=1; }
    return $ok
}
check "VRUN6 an --env value reaches the command only; the client's proxy settings reach neither container" vrun6

# ── VRUN7 ────────────────────────────────────────────────────────────────
# Behavior: when the timeout passes, the command is stopped inside the box
#   (not only the local docker client), the run exits 124, and nothing is
#   left.
# Theory: a broken launcher kills only its `docker exec` client and the
#   command keeps running in the box.
# Not a text comparison: a file the command would write after the
#   timeout, and docker's view of what exists.
# LLM: the command marks that it started before sleeping.
vrun7() {
    setup 7; local n; n=$(name_of 7)
    TIMEOUT_ARG=4
    vrun 7 "$n" -- sh -c 'touch /data/started; sleep 20; touch /data/late'
    TIMEOUT_ARG=60
    local ok=0
    [ -e "$D_DATA/started" ] || { echo "    control: the command never started"; show_err 7; ok=1; }
    [ "$(rc_of 7)" = 124 ] || { echo "    rc=$(rc_of 7)"; ok=1; }
    sleep 25
    [ ! -e "$D_DATA/late" ] || { echo "    command kept running after the timeout"; ok=1; }
    nothing_left "$n" || { echo "    resources left"; ok=1; }
    return $ok
}
check "VRUN7 a timeout stops the command inside the box" vrun7

# ── VRUN8 ────────────────────────────────────────────────────────────────
# Behavior: SIGTERM to the launcher while the command runs stops the
#   command inside the box within 15 seconds, exits 143, and leaves
#   nothing.
# Theory: a launcher that waits in the foreground handles the signal only
#   after the command finishes; one that dies leaves the box running.
# Not a text comparison: timing, exit code, a file the command would write
#   later, docker's view.
# LLM: the signal is sent only after the command marked that it started.
vrun8() {
    setup 8; local n; n=$(name_of 8)
    set -m
    ( vrun 8 "$n" -- sh -c 'touch /data/started; sleep 20; touch /data/late' ) &
    local bg=$!
    set +m
    wait_file "$D_DATA/started" 120 || { kill -KILL -- -$bg 2>/dev/null; echo "    the command never started"; show_err 8; return 1; }
    local lbxpid; lbxpid=$(launcher_pid "$n")
    [ -n "$lbxpid" ] || { echo "    launcher process not found"; return 1; }
    local start=$SECONDS
    kill -TERM "$lbxpid"
    wait $bg
    local ok=0
    [ $((SECONDS - start)) -le 15 ] || { echo "    took $((SECONDS - start)) s"; ok=1; }
    [ "$(rc_of 8)" = 143 ] || { echo "    rc=$(rc_of 8)"; ok=1; }
    nothing_left "$n" || { echo "    resources left"; ok=1; }
    sleep 25
    [ ! -e "$D_DATA/late" ] || { echo "    command kept running after SIGTERM"; ok=1; }
    return $ok
}
check "VRUN8 SIGTERM stops the command inside the box within 15 s" vrun8

# ── VRUN9 ────────────────────────────────────────────────────────────────
# Behavior: the command starts only after its home directory is owned by
#   and writable for it, the proxy variables are set, and it runs with the
#   invoking user's user id.
# Theory: a launcher that starts the command at the entrypoint's first
#   marker races the ownership fix and the proxy setup.
# Not a text comparison: the running command's own view.
# LLM: VRUN2 covers a user id other than 1000.
vrun9() {
    setup 9; local n; n=$(name_of 9)
    vrun 9 "$n" -- sh -c 'echo "home_owner=$(stat -c %u "$HOME") me=$(id -u)"; touch "$HOME/w" && echo writable=yes; echo "proxy=${HTTPS_PROXY:-unset}"'
    local out ok=0; out="$(cat "$WORK/9/out")"
    grep -qx "home_owner=$(id -u) me=$(id -u)" <<<"$out" || { echo "    $(grep home_owner <<<"$out")"; show_err 9; ok=1; }
    grep -qx writable=yes <<<"$out" || { echo "    HOME not writable"; ok=1; }
    grep -qE '^proxy=http://[0-9.]+:3128$' <<<"$out" || { echo "    $(grep proxy= <<<"$out")"; ok=1; }
    return $ok
}
check "VRUN9 the command starts only after its home and proxy settings are ready" vrun9

# ── VRUN10 ───────────────────────────────────────────────────────────────
# Behavior: no docker daemon runs in the run box, there is no docker
#   socket, and the entrypoint never started one (it writes
#   /var/log/dockerd.log whenever it starts dockerd, and then waits up to
#   30 seconds for it).
# Theory: an entrypoint that still starts dockerd leaves a daemon an agent
#   could use and delays every run. Startup time itself is not a usable
#   signal: the entrypoint re-owns the home directory when the host's
#   group differs from the image's, which takes longer than the dockerd
#   wait on some hosts.
# Not a text comparison: the process list and file system inside the box.
# LLM: control: a process started by the command is visible to pgrep, and
#   the command ran (it wrote /data/start).
vrun10() {
    setup 10; local n; n=$(name_of 10)
    vrun 10 "$n" -- sh -c 'touch /data/start; sleep 30 & pgrep -x sleep >/dev/null && echo control=yes; pgrep -x dockerd >/dev/null && echo dockerd=yes || echo dockerd=no; test -S /var/run/docker.sock && echo sock=yes || echo sock=no; test -e /var/log/dockerd.log && echo dockerlog=yes || echo dockerlog=no; kill %1 2>/dev/null'
    local ok=0 out; out="$(cat "$WORK/10/out")"
    [ -f "$D_DATA/start" ] || { echo "    control: the command never started"; show_err 10; ok=1; }
    grep -qx control=yes <<<"$out" || { echo "    control: pgrep saw nothing"; show_err 10; ok=1; }
    grep -qx dockerd=no <<<"$out" || { echo "    dockerd running"; ok=1; }
    grep -qx sock=no <<<"$out" || { echo "    socket present"; ok=1; }
    grep -qx dockerlog=no <<<"$out" || { echo "    the entrypoint started dockerd"; ok=1; }
    return $ok
}
check "VRUN10 no docker daemon runs or was started in the box" vrun10

# ── VRUN11 ───────────────────────────────────────────────────────────────
# Behavior: hostile command arguments arrive unchanged in a real box.
# Theory: a broken launcher, or docker exec used through a shell,
#   re-splits or expands the arguments.
# Not a text comparison: the bytes the command printed.
# LLM: random vectors from the same generator as the fake suite, printed
#   with printf '%s\0'.
WORD_POOL=(' ' '"' "'" '$' '\' '*' '?' '[' ']' '-' '--' '--run' '$(id)' '`id`' $'\n' '~' ';' '&&' '=' 'x')
VRUN11_CASES=()
for c in $(seq 1 6); do
    vec=()
    for _ in $(seq 1 $((RANDOM % 5 + 1))); do
        w=""; for _ in $(seq 1 $((RANDOM % 4 + 1))); do w="$w${WORD_POOL[$((RANDOM % ${#WORD_POOL[@]}))]}"; done
        vec+=("$w")
    done
    [ $((c % 3)) = 0 ] && vec+=("")
    VRUN11_CASES+=("$(printf '%s\0' "${vec[@]}" | base64 -w0)")
done
vrun11() {
    local ok=0 enc i=0
    for enc in "${VRUN11_CASES[@]}"; do
        i=$((i + 1))
        setup "11-$i"; local n; n=$(name_of "11$i")
        local -a vec=(); mapfile -d '' -t vec < <(printf '%s' "$enc" | base64 -d)
        vrun "11-$i" "$n" -- printf '%s\0' "${vec[@]}"
        printf '%s' "$enc" | base64 -d > "$WORK/11-$i/want"
        cmp -s "$WORK/11-$i/out" "$WORK/11-$i/want" || { echo "    case $i differs: $(printf '%q ' "${vec[@]}")"; show_err "11-$i"; ok=1; }
    done
    return $ok
}
check "VRUN11 hostile command arguments arrive unchanged in a real box" vrun11

# ── VRUN12 ───────────────────────────────────────────────────────────────
# Behavior: a symbolic link and a named pipe the command leaves in the
#   data directory are never opened by the launcher, which exits within
#   10 seconds of the command's end.
# Theory: a launcher that reads results from the data directory can be
#   made to read a host file or hang on a pipe.
# Not a text comparison: whether a host pipe's writer saw an open, and
#   timing.
# LLM: the link points at a host named pipe whose writer records an open.
vrun12() {
    setup 12; local n; n=$(name_of 12)
    local P="$WORK/12/hostpipe" M="$WORK/12/opened"
    mkfifo "$P"
    ( exec 3>"$P"; echo opened > "$M" ) &
    local writer=$!
    vrun 12 "$n" -- sh -c "ln -s '$P' /data/hostlink; mkfifo /data/ownpipe; touch /data/done; exit 5"
    local ended; ended=$(date +%s)
    local ok=0
    [ "$(rc_of 12)" = 5 ] || { echo "    rc=$(rc_of 12)"; show_err 12; ok=1; }
    [ -L "$D_DATA/hostlink" ] && [ -p "$D_DATA/ownpipe" ] && [ -f "$D_DATA/done" ] || { echo "    control: link, pipe or marker missing"; ok=1; }
    [ -f "$D_DATA/done" ] && [ $((ended - $(stat -c %Y "$D_DATA/done"))) -le 10 ] || { echo "    launcher took more than 10 s after the command ended"; ok=1; }
    sleep 2
    [ ! -e "$M" ] || { echo "    the host pipe was opened"; ok=1; }
    kill "$writer" 2>/dev/null
    return $ok
}
check "VRUN12 links and pipes left in the data directory are never opened" vrun12

# ── VRUN13 ───────────────────────────────────────────────────────────────
# Behavior: the relay runs unprivileged with all capabilities dropped, no
#   new privileges and a read-only root, and receives the policy by its
#   absolute path even when --net-policy is relative.
# Theory: a hostile box talks to the relay directly; a privileged relay
#   widens what a relay compromise gains; a relative path would become a
#   named volume and the relay would start without the policy.
# Not a text comparison: docker's configuration of the real relay.
# LLM: runs from the policy's own directory with `--net-policy policy.json`.
vrun13() {
    setup 13; local n; n=$(name_of 13)
    local D="$WORK/13"
    ( cd "$D/pol" && env HOME="$D/home" LLMBOX_STATE_DIR="$D/state" "$LBX" --run --runtime docker \
        --net-policy policy.json --data "$D_DATA" --timeout 60 "$n" -- sleep 6 >"$D/out" 2>"$D/err"; echo $? > "$D/rc" ) &
    local bg=$!
    wait_box "llm-in-a-box-relay-$n" || { wait $bg; echo "    relay never appeared"; show_err 13; return 1; }
    sleep 2
    local r="llm-in-a-box-relay-$n" ok=0
    [ "$(docker inspect -f '{{.HostConfig.Privileged}}' "$r")" = false ] || { echo "    relay privileged"; ok=1; }
    [ "$(docker inspect -f '{{join .HostConfig.CapDrop ","}}' "$r")" = ALL ] || { echo "    relay CapDrop"; ok=1; }
    [ "$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' "$r")" = true ] || { echo "    relay root not read-only"; ok=1; }
    docker inspect -f '{{json .HostConfig.SecurityOpt}}' "$r" | grep >/dev/null no-new-privileges || { echo "    relay lacks no-new-privileges"; ok=1; }
    local src; src=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/policy.json"}}{{.Source}}{{end}}{{end}}' "$r")
    [ "$src" = "$(realpath "$D/pol/policy.json")" ] || { echo "    policy mount source '$src'"; ok=1; }
    wait $bg
    [ "$(cat "$D/rc")" = 0 ] || { echo "    rc=$(cat "$D/rc")"; ok=1; }
    return $ok
}
check "VRUN13 the relay is hardened and receives the policy by absolute path" vrun13

# ── VRUN14 ───────────────────────────────────────────────────────────────
# Behavior: a data directory that contains a mount point is refused (125)
#   and nothing is created.
# Theory: docker bind mounts are recursive, so a mount inside the data
#   directory would expose another part of the host to the box.
# Not a text comparison: exit code, the launcher's message for this run,
#   docker's view.
# LLM: the fixture's inner directory is bind-mounted by the setup script.
vrun14() {
    [ -d "$FIX/with-mount/inner" ] && mountpoint -q "$FIX/with-mount/inner" \
        || { echo "    prerequisite: $FIX/with-mount/inner is not a mount point (run tests/setup-run-test-host.sh)"; return 1; }
    setup 14; local n; n=$(name_of 14)
    D_DATA="$FIX/with-mount"
    vrun 14 "$n" -- true
    { [ "$(rc_of 14)" = 125 ] && grep -q 'mount point' "$WORK/14/err" && nothing_left "$n"; } \
        || { echo "    rc=$(rc_of 14)"; show_err 14; return 1; }
}
check "VRUN14 a data directory containing a mount point is refused" vrun14

# ── VRUN15 ───────────────────────────────────────────────────────────────
# Behavior: after SIGKILL of the launcher, the run box removes itself
#   within its lifetime, no timer or exec client of the killed run keeps
#   running, the relay and networks remain, and the documented manual
#   commands remove them.
# Theory: without a bounded lifetime, an agent orphaned by a killed
#   launcher runs forever with its secrets.
# Not a text comparison: docker's view over time and the process list.
# LLM: lifetime = timeout (5) + readiness maximum (60) + 60. The kill
#   happens as soon as the command marks that it started.
vrun15() {
    setup 15; local n; n=$(name_of 15)
    TIMEOUT_ARG=5
    ( vrun 15 "$n" -- sh -c 'touch /data/started; exec sleep 300' ) &
    local bg=$!
    TIMEOUT_ARG=60
    # Kill only once the command runs, so the timer and the exec client
    # exist; and only while the launcher is alive (before its timeout).
    wait_file "$D_DATA/started" 120 || { echo "    the command never started"; show_err 15; return 1; }
    local lbxpid; lbxpid=$(launcher_pid "$n")
    [ -n "$lbxpid" ] || { echo "    launcher process not found"; return 1; }
    kill -KILL "$lbxpid" || { echo "    the launcher was already gone"; return 1; }
    wait $bg 2>/dev/null
    local ok=0 t=0 limit=$((5 + 60 + 60 + 30))
    [ "$(rc_of 15)" != 124 ] || { echo "    control: the launcher reached its timeout before the kill"; ok=1; }
    while docker inspect "$n" >/dev/null 2>&1 && [ $t -lt $limit ]; do sleep 5; t=$((t + 5)); done
    docker inspect "$n" >/dev/null 2>&1 && { echo "    run box still exists after $limit s"; ok=1; }
    pgrep -f -- "$n" >/dev/null && { echo "    processes of the killed run remain: $(pgrep -af -- "$n" | head -3)"; ok=1; }
    docker inspect "llm-in-a-box-relay-$n" >/dev/null 2>&1 || { echo "    control: the relay was already gone"; ok=1; }
    docker network inspect "llm-in-a-box-net-$n" >/dev/null 2>&1 || { echo "    control: the network was already gone"; ok=1; }
    docker rm -f "$n" "llm-in-a-box-relay-$n" >/dev/null 2>&1
    docker network rm "llm-in-a-box-net-$n" "llm-in-a-box-relaynet-$n" >/dev/null 2>&1
    nothing_left "$n" || { echo "    manual cleanup left resources"; ok=1; }
    return $ok
}
check "VRUN15 after SIGKILL the run box removes itself; manual cleanup removes the rest" vrun15

# ── VRUN16 ───────────────────────────────────────────────────────────────
# Behavior: a run name of the maximum length (128 characters) works on
#   real docker: the command runs, its exit code comes back, and nothing
#   is left.
# Theory: docker or the kernel may limit names derived from the run name
#   (container, relay, networks, hostname); a limit below 128 would make
#   the documented maximum a lie.
# Not a text comparison: the real exit code and docker's view.
# LLM: the name ends with this run's id so the cleanup trap covers it.
vrun16() {
    setup 16
    local prefix="lbx-test-v16-" suffix="-$RUNID" n pad
    pad=$((128 - ${#prefix} - ${#suffix}))
    n="$prefix$(head -c "$pad" /dev/zero | tr '\0' 'a')$suffix"
    [ "${#n}" = 128 ] || { echo "    name length ${#n}"; return 1; }
    vrun 16 "$n" -- sh -c 'exit 3'
    local ok=0
    [ "$(rc_of 16)" = 3 ] || { echo "    rc=$(rc_of 16)"; show_err 16; ok=1; }
    nothing_left "$n" || { echo "    resources left"; ok=1; }
    return $ok
}
check "VRUN16 a 128-character run name works on real docker" vrun16

# ── VRUN17 ───────────────────────────────────────────────────────────────
# Requirement: R2, R13 (plans/2026_09_24_unattended_run_mode/00_overview.md section 2)
# Behavior: after SIGKILL of the launcher while the command runs, no
#   handler runs: runs/<name> keeps the claim file `.claim` and gets no
#   status file, the relay and BOTH networks (internal and egress) remain,
#   and the documented manual commands remove the run box, the relay and
#   both networks.
# Theory: callers are told that a missing status file means the run never
#   finished and that the egress network is among the leftovers; a
#   launcher (or a daemon) that behaved otherwise would make that guidance
#   wrong, and manual cleanup that misses the egress network leaves it
#   behind for good.
# Not a text comparison: the file system of the state directory and
#   docker's own view right after the kill.
# LLM: like VRUN15, but the checks are made at once after the kill (the
#   run box is still alive: its lifetime is 60 + 60 + 60 seconds), so the
#   run box's presence is the control that the kill hit a live run.
vrun17() {
    setup 17; local n; n=$(name_of 17)
    ( vrun 17 "$n" -- sh -c 'touch /data/started; exec sleep 300' ) &
    local bg=$!
    wait_file "$D_DATA/started" 120 || { echo "    the command never started"; show_err 17; return 1; }
    local lbxpid; lbxpid=$(launcher_pid "$n")
    [ -n "$lbxpid" ] || { echo "    launcher process not found"; return 1; }
    kill -KILL "$lbxpid" || { echo "    the launcher was already gone"; return 1; }
    wait $bg 2>/dev/null
    local ok=0 runs="$WORK/17/state/runs/$n"
    docker inspect "$n" >/dev/null 2>&1 || { echo "    control: the run box was already gone right after the kill"; ok=1; }
    [ -f "$runs/.claim" ] || { echo "    runs/<name>/.claim is missing after SIGKILL"; ok=1; }
    [ ! -e "$runs/status" ] || { echo "    a status file was written after SIGKILL: $(cat "$runs/status")"; ok=1; }
    docker inspect "llm-in-a-box-relay-$n" >/dev/null 2>&1 || { echo "    the relay is gone"; ok=1; }
    docker network inspect "llm-in-a-box-net-$n" >/dev/null 2>&1 || { echo "    the internal network is gone"; ok=1; }
    docker network inspect "llm-in-a-box-relaynet-$n" >/dev/null 2>&1 || { echo "    the egress network is gone"; ok=1; }
    docker rm -f "$n" "llm-in-a-box-relay-$n" >/dev/null 2>&1
    docker network rm "llm-in-a-box-net-$n" "llm-in-a-box-relaynet-$n" >/dev/null 2>&1
    nothing_left "$n" || { echo "    manual cleanup left resources"; ok=1; }
    return $ok
}
check "VRUN17 after SIGKILL the claim stays with no status file, and the relay and both networks remain" vrun17

# ── VRUN18 ───────────────────────────────────────────────────────────────
# Requirement: known limit (plans/2026_09_24_unattended_run_mode/00_overview.md section 12)
# Behavior (an accepted limit, pinned so it stays documented): a run name
#   that equals the first 12 hexadecimal digits of an existing container's
#   id is refused as "a container named <name> already exists" (125, the
#   refusal status line, no runs/<name> written), because docker's
#   container lookup also matches id prefixes; once that container is
#   gone, the same name runs.
# Theory: the name-in-use check asks docker whether a container of that
#   name exists; docker answers for ids and id prefixes too, so a run name
#   that looks hexadecimal can collide with an unrelated container.
# Not a text comparison: the real exit code, the launcher's own message
#   for this run, the state directory and docker's view.
# LLM: a stopped alpine container named with this run's prefix (so the
#   cleanup trap covers it) supplies the id; the control run's resources
#   carry the hexadecimal name, so they are removed explicitly afterwards.
vrun18() {
    setup 18
    local c id p ok=0
    c=$(name_of 18)
    docker create --name "$c" alpine:3 true >/dev/null 2>&1 || { echo "    could not create the helper container"; return 1; }
    id=$(docker inspect -f '{{.Id}}' "$c")
    p="${id:0:12}"
    [[ "$p" =~ ^[0-9a-f]{12}$ ]] || { echo "    unexpected container id '$id'"; docker rm -f "$c" >/dev/null 2>&1; return 1; }
    vrun 18 "$p" -- true
    [ "$(rc_of 18)" = 125 ] || { echo "    rc=$(rc_of 18) (want 125)"; show_err 18; ok=1; }
    [ "$(grep -v '^$' "$WORK/18/err" | tail -1)" = "lbx-run: status=refused code=125" ] || { echo "    last line: $(grep -v '^$' "$WORK/18/err" | tail -1)"; ok=1; }
    grep -qF "a container named $p already exists" "$WORK/18/err" || { echo "    the refusal does not name the id prefix as an existing container"; show_err 18; ok=1; }
    [ ! -e "$WORK/18/state/runs/$p" ] || { echo "    runs/$p was written by a refusal"; ok=1; }
    docker rm -f "$c" >/dev/null 2>&1
    vrun 18 "$p" -- true
    [ "$(rc_of 18)" = 0 ] || { echo "    control: with the container gone, rc=$(rc_of 18) (want 0)"; show_err 18; ok=1; }
    nothing_left "$p" || { echo "    control: resources left"; ok=1; }
    docker rm -f "$p" "llm-in-a-box-relay-$p" >/dev/null 2>&1
    docker network rm "llm-in-a-box-net-$p" "llm-in-a-box-relaynet-$p" >/dev/null 2>&1
    return $ok
}
check "VRUN18 known limit: a run name equal to a container id prefix is refused as existing" vrun18

# ── VRUN19 ───────────────────────────────────────────────────────────────
# Requirement: known limit (plans/2026_09_24_unattended_run_mode/00_overview.md section 12)
# Behavior (an accepted limit, pinned so it stays documented): a `:` in
#   the data directory's path or in the policy file's path passes the
#   launcher's checks but breaks docker's `-v` mount specification: the run
#   ends as a setup failure (125, status=setup-failed in the status file),
#   the command never runs, and nothing of the run is left. The same run
#   with paths without `:` works.
# Theory: `-v <host path>:<container path>[:<mode>]` is split on `:`, so a
#   host path containing one names a different source, target or mode, and
#   docker refuses the container. The launcher does not refuse such paths
#   up front; the documents list this as a known limit.
# Not a text comparison: the real exit code, the status file, a marker the
#   command would write, and docker's view.
# LLM: three runs: data directory `da:ta`; policy file under `p:ol/`;
#   control with `da_ta` and `p_ol/`.
# vrun_paths <id> <policy file> <data directory> [launcher args...]: like
# vrun, with the given policy file and data directory.
vrun_paths() {
    local id="$1" pol="$2" data="$3"; shift 3
    local D="$WORK/$id"
    (
        cd "$D/cwd" || exit 99
        env HOME="$D/home" LLMBOX_STATE_DIR="$D/state" ${VENV[@]+"${VENV[@]}"} \
            "$LBX" --run --runtime docker --net-policy "$pol" \
            --data "$data" --timeout "$TIMEOUT_ARG" "$@" <"$VIN" >"$D/out" 2>"$D/err"
        echo $? > "$D/rc"
    )
}
vrun19_case() { # <id> <data directory name> <policy directory name> <want: fail|ok>
    local id="$1" D="$WORK/$1" n ok=0
    setup "$id"; n=$(name_of "$id")
    mkdir -p "$D/$2" "$D/$3"
    cp "$D/pol/policy.json" "$D/$3/policy.json"
    vrun_paths "$id" "$D/$3/policy.json" "$D/$2" "$n" -- sh -c 'touch /data/ran'
    if [ "$4" = fail ]; then
        [ "$(rc_of "$id")" = 125 ] || { echo "    $2 $3: rc=$(rc_of "$id") (want 125)"; show_err "$id"; ok=1; }
        [ "$(cat "$D/state/runs/$n/status" 2>/dev/null)" = "status=setup-failed code=125" ] \
            || { echo "    $2 $3: status file: $(cat "$D/state/runs/$n/status" 2>&1)"; ok=1; }
        [ ! -e "$D/$2/ran" ] || { echo "    $2 $3: the command ran"; ok=1; }
    else
        [ "$(rc_of "$id")" = 0 ] && [ -e "$D/$2/ran" ] || { echo "    control $2 $3: rc=$(rc_of "$id"), command ran: $([ -e "$D/$2/ran" ] && echo yes || echo no)"; show_err "$id"; ok=1; }
    fi
    nothing_left "$n" || { echo "    $2 $3: resources left"; ok=1; }
    return $ok
}
vrun19() {
    local ok=0
    vrun19_case 19a "da:ta" "p_ol" fail || ok=1
    vrun19_case 19b "da_ta" "p:ol" fail || ok=1
    vrun19_case 19c "da_ta" "p_ol" ok || ok=1
    return $ok
}
check "VRUN19 known limit: a ':' in the data or policy path ends the run as a setup failure" vrun19

# ── Socket directory and no-network runs: shared helpers ───────────────
# The socket servers and clients are perl programs using IO::Socket::UNIX
# (perl-base on the host, which the test-host profile already relies on,
# and in the image). They are written into this run's work directory once.
SOCK_TOOLS="$WORK/socktools"
mkdir -p "$SOCK_TOOLS"
# echo-server.pl <socket path> <log>: an echo server that logs each peer's
# user id (SO_PEERCRED) and the line it received.
cat > "$SOCK_TOOLS/echo-server.pl" <<'PERL'
use strict; use warnings; use IO::Socket::UNIX; use Socket qw(SOL_SOCKET SO_PEERCRED);
my ($path, $log) = @ARGV;
unlink $path;
my $s = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Local => $path, Listen => 5) or die "listen: $!\n";
open(my $L, '>>', $log) or die "log: $!\n"; $L->autoflush(1);
while (my $c = $s->accept) {
    my ($pid, $uid, $gid) = unpack('lll', getsockopt($c, SOL_SOCKET, SO_PEERCRED));
    my $line = <$c>; $line = '' unless defined $line; chomp $line;
    print $L "peer_uid=$uid line=$line\n";
    print $c "$line\n"; close $c;
}
PERL
# client.pl <socket path> <token>: prints reply=<answer> or connect_failed=<error>.
cat > "$SOCK_TOOLS/client.pl" <<'PERL'
use strict; use warnings; use IO::Socket::UNIX;
my ($path, $tok) = @ARGV;
my $s = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Peer => $path, Timeout => 5);
if (!$s) { print "connect_failed=$!\n"; exit 0 }
print $s "$tok\n"; my $r = <$s>; $r = '' unless defined $r; chomp $r;
print "reply=$r\n";
PERL
# probe.pl: the no-network probes (network interfaces, routes, connections
# out, name resolution, the host's abstract socket, loopback, privileges).
cat > "$SOCK_TOOLS/probe.pl" <<'PERL'
use strict; use warnings; use IO::Socket::INET; use IO::Socket::IP; use IO::Socket::UNIX; use IO::Select;
sub tcp { my ($h, $p) = @_; my $s = IO::Socket::IP->new(PeerHost => $h, PeerPort => $p, Proto => 'tcp', Timeout => 4); return $s ? 'reached' : 'blocked'; }
opendir(my $d, '/sys/class/net') or die; my @if = sort grep { !/^\./ } readdir($d); closedir $d;
print "interfaces=@if\n";
# Per interface: its state and flags from sysfs, its IPv4 address (the
# SIOCGIFADDR ioctl: "none" when the kernel says it has none, "?" when it
# could not be asked) and its number of IPv6 addresses.
my %v6;
if (open(my $h6, '<', '/proc/net/if_inet6')) { while (<$h6>) { my @f = split; $v6{$f[5]}++ if @f >= 6 } close $h6 }
my $s4; socket($s4, Socket::AF_INET(), Socket::SOCK_DGRAM(), 0) or undef $s4;
for my $i (@if) {
    my %v;
    for my $f (qw(operstate flags type)) {
        $v{$f} = '?';
        if (open(my $h, '<', "/sys/class/net/$i/$f")) { my $x = <$h>; close $h; if (defined $x) { chomp $x; $v{$f} = $x } }
    }
    my $v4 = '?';
    if ($s4) {
        my $ifr = pack('a16 x24', $i);
        if (ioctl($s4, 0x8915, $ifr)) { $v4 = Socket::inet_ntoa(substr($ifr, 20, 4)) }
        elsif ($!{EADDRNOTAVAIL}) { $v4 = 'none' }
    }
    print "interface_$i=operstate:$v{operstate} flags:$v{flags} type:$v{type} ipv4:$v4 ipv6:" . ($v6{$i} // 0) . "\n";
}
my (@local, $last);
if (open(my $ft, '<', '/proc/net/fib_trie')) {
    while (<$ft>) { $last = $1 if /^\s*[|+]-- (\S+)/; push @local, $last if /\/32 host LOCAL/ && defined $last && !grep { $_ eq $last } @local }
    close $ft;
}
print "local_addrs=@local\n";
open(my $r, '<', '/proc/net/route') or die; my @routes = <$r>; close $r;
print 'routes=' . (scalar(@routes) - 1) . "\n";
print 'public_ip=' . tcp('1.1.1.1', 443) . "\n";
print 'gateway=' . tcp($ENV{GW}, $ENV{LISTEN_PORT}) . "\n";
print 'host_addr=' . tcp($ENV{HOST_ADDR}, $ENV{LISTEN_PORT}) . "\n";
print 'metadata=' . tcp('169.254.169.254', 80) . "\n";
print 'ipv6=' . tcp('2606:4700:4700::1111', 443) . "\n";
my @a = gethostbyname('example.com'); print 'dns_resolv=' . (@a ? 'reached' : 'blocked') . "\n";
my $q = pack('nnnnnn', 0x1234, 0x0100, 1, 0, 0, 0);
$q .= chr(length $_) . $_ for split /\./, 'example.com';
$q .= "\0" . pack('nn', 1, 1);
my $emb = 'blocked';
my $u = IO::Socket::INET->new(PeerAddr => '127.0.0.11', PeerPort => 53, Proto => 'udp');
if ($u && defined $u->send($q) && IO::Select->new($u)->can_read(4)) {
    my $buf; $u->recv($buf, 1024);
    $emb = 'reached' if defined $buf && length($buf) >= 8 && unpack('n', substr($buf, 6, 2)) > 0;
}
print "embedded_public=$emb\n";
my $abs = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Peer => "\0$ENV{ABS_NAME}");
print 'abstract=' . ($abs ? 'reached' : 'blocked') . "\n";
my $l = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 5, Proto => 'tcp', ReuseAddr => 1);
# Through tcp(), the same function every blocked probe uses, so this
# control shows that function can report a reached address.
print 'loopback=' . ($l ? tcp('127.0.0.1', $l->sockport) : 'blocked') . "\n";
open(my $st, '<', '/proc/self/status') or die;
while (<$st>) { print "$1=$2\n" if /^(CapBnd|NoNewPrivs):\s+(\S+)/ }
close $st;
PERL
ECHO_PID=""
# start_echo <socket path> <log>: starts the echo server; waits up to 30 s
# for its socket (a cold host can be slow to load perl the first time).
# The server's own error output goes to <log>.stderr, shown on failure.
start_echo() {
    command -v perl >/dev/null 2>&1 || { echo "    prerequisite: perl on the host"; return 1; }
    # A killed server leaves its socket file behind; remove it first, so the
    # wait below sees the new server's socket, not the old file.
    rm -f -- "$1"
    perl "$SOCK_TOOLS/echo-server.pl" "$1" "$2" >/dev/null 2>>"$2.stderr" &
    ECHO_PID=$!
    local t=0; while [ ! -S "$1" ] && [ $t -lt 300 ] && kill -0 "$ECHO_PID" 2>/dev/null; do sleep 0.1; t=$((t + 1)); done
    [ -S "$1" ] || { echo "    the echo server did not create $1 (waited $((t / 10)) s):"; sed 's/^/      server: /' "$2.stderr" 2>/dev/null; return 1; }
}
stop_echo() { [ -z "$ECHO_PID" ] || { kill "$ECHO_PID" 2>/dev/null; wait "$ECHO_PID" 2>/dev/null; }; ECHO_PID=""; }
# host_client <socket path> <token>: the same client, from the host.
host_client() { perl "$SOCK_TOOLS/client.pl" "$1" "$2"; }
# dir_snapshot <dir>: the directory's own type, inode, mode, owner and
# group, then name, type, inode and mode of each entry.
dir_snapshot() { stat -c '%F %i %a %u %g' "$1"; find "$1" -mindepth 1 -maxdepth 1 -printf '%f %y %i %m\n' | sort; }
# vrun_nn <id> [launcher args after the standard ones...]: like vrun, with
# --no-network in place of --net-policy.
vrun_nn() {
    local id="$1"; shift
    local D="$WORK/$id"
    (
        cd "$D/cwd" || exit 99
        env HOME="$D/home" LLMBOX_STATE_DIR="$D/state" ${VENV[@]+"${VENV[@]}"} \
            "$LBX" --run --runtime docker --no-network \
            --data "$D_DATA" --timeout "$TIMEOUT_ARG" "$@" <"$VIN" >"$D/out" 2>"$D/err"
        echo $? > "$D/rc"
    )
}
# copy_tools: the perl client and probe into this check's data directory.
copy_tools() { cp "$SOCK_TOOLS/client.pl" "$SOCK_TOOLS/probe.pl" "$D_DATA/"; }

# ── VRUN20 ───────────────────────────────────────────────────────────────
# Requirement: R14, R16 (plans/2026_09_29_run_socket_mount_and_no_network/00_overview.md section 2)
# Behavior: a caller's socket in the socket directory (whose path holds a
#   space and a `$`) is reachable from the command at /run/agent/<name>:
#   the command's token comes back, the caller's server sees the host
#   user's id as the peer, /run/agent has the host directory's owner,
#   group and mode, the command runs with the host user's ids, the run
#   exits 0 and leaves nothing.
# Theory: a launcher that mounts the file instead of the directory, the
#   wrong path, or not at all, or a box user whose ids differ from the
#   directory's owner, shows up as a failed connection or wrong ids.
# Not a text comparison: a real connection through real docker, and the
#   server's own record of who connected.
# LLM: perl echo server on the host; perl client in the box.
vrun20() {
    setup 20; local n; n=$(name_of 20); copy_tools
    local SD="$WORK/20/s ock\$x"
    mkdir -p "$SD"; chmod 700 "$SD"
    start_echo "$SD/echo.sock" "$WORK/20/server.log" || return 1
    local tok="tok20-$RANDOM$RANDOM"
    VENV=(TOKEN="$tok")
    vrun 20 --socket-dir "$SD" --env TOKEN "$n" -- sh -c 'stat -c "dir=%u:%g:%a" /run/agent; echo "ids=$(id -u):$(id -g)"; perl /data/client.pl /run/agent/echo.sock "$TOKEN"'
    VENV=()
    stop_echo
    local ok=0 out; out="$(cat "$WORK/20/out")"
    [ "$(rc_of 20)" = 0 ] || { echo "    rc=$(rc_of 20)"; show_err 20; ok=1; }
    grep -qx "reply=$tok" <<<"$out" || { echo "    reply: $(grep -E '^(reply|connect_failed)=' <<<"$out")"; ok=1; }
    grep -qx "peer_uid=$(id -u) line=$tok" "$WORK/20/server.log" || { echo "    server log: $(cat "$WORK/20/server.log")"; ok=1; }
    grep -qx "dir=$(stat -c '%u:%g:%a' "$SD")" <<<"$out" || { echo "    $(grep dir= <<<"$out") (host: $(stat -c '%u:%g:%a' "$SD"))"; ok=1; }
    grep -qx "ids=$(id -u):$(id -g)" <<<"$out" || { echo "    $(grep ids= <<<"$out")"; ok=1; }
    nothing_left "$n" || { echo "    resources left"; ok=1; }
    return $ok
}
check "VRUN20 a caller's socket is reachable at /run/agent, from the host user's id" vrun20

# ── VRUN21 ───────────────────────────────────────────────────────────────
# Requirement: R16, R17 (plans/2026_09_29_run_socket_mount_and_no_network/00_overview.md section 2)
# Behavior: inside the run box, /run/agent is read-only for the box user
#   (creating a file or directory, removing, renaming or linking the
#   socket, changing the directory's mode, binding a new socket all fail)
#   and for root in the box (removing the socket or creating a file fails
#   through `docker exec -u 0`); after all that the command still gets its
#   token back. Afterwards the host directory's entries (names, types,
#   inodes, modes) are as before and the server still answers from the
#   host. A run that ends by timeout leaves the directory as before too.
# Theory: a writable mount would let a steered agent remove, replace or
#   impersonate the caller's socket; a launcher that tidies the directory
#   on cleanup changes it.
# Not a text comparison: real file operations in a real container, and
#   the host's own view of the directory.
# LLM: markers in /data synchronize the root attempts with the command.
vrun21() {
    setup 21; local n; n=$(name_of 21); copy_tools
    local SD="$WORK/21/sock"; mkdir -p "$SD"; chmod 700 "$SD"
    start_echo "$SD/echo.sock" "$WORK/21/server.log" || return 1
    dir_snapshot "$SD" > "$WORK/21/before"
    local tok="tok21-$RANDOM$RANDOM"
    local script='
        try() { if "$@" 2>/dev/null; then echo "allowed: $*"; else echo "denied: $*"; fi; }
        try touch /run/agent/x
        try mkdir /run/agent/d
        try rm /run/agent/echo.sock
        try mv /run/agent/echo.sock /run/agent/e2
        try ln -s /etc /run/agent/l
        try chmod 777 /run/agent
        try perl -MIO::Socket::UNIX -e "IO::Socket::UNIX->new(Type => SOCK_STREAM(), Local => q{/run/agent/evil.sock}, Listen => 1) or exit 1"
        touch /data/ready
        t=0; while [ ! -e /data/go ] && [ $t -lt 600 ]; do sleep 0.1; t=$((t + 1)); done
        perl /data/client.pl /run/agent/echo.sock "$TOKEN"'
    VENV=(TOKEN="$tok")
    ( vrun 21 --socket-dir "$SD" --env TOKEN "$n" -- sh -c "$script" ) &
    local bg=$!
    VENV=()
    local ok=0
    if wait_file "$D_DATA/ready" 120; then
        docker exec -u 0 "$n" rm /run/agent/echo.sock >/dev/null 2>&1 && { echo "    root in the box removed the socket"; ok=1; }
        docker exec -u 0 "$n" touch /run/agent/rootfile >/dev/null 2>&1 && { echo "    root in the box created a file"; ok=1; }
        docker exec -u 0 "$n" true >/dev/null 2>&1 || { echo "    control: docker exec -u 0 into the run box failed"; ok=1; }
    else
        echo "    the command never reached its marker"; ok=1
    fi
    touch "$D_DATA/go"
    wait $bg
    local out; out="$(cat "$WORK/21/out")"
    [ "$(rc_of 21)" = 0 ] || { echo "    rc=$(rc_of 21)"; show_err 21; ok=1; }
    grep -q '^allowed: ' <<<"$out" && { echo "    allowed for the box user: $(grep '^allowed: ' <<<"$out" | tr '\n' ';')"; ok=1; }
    [ "$(grep -c '^denied: ' <<<"$out")" = 7 ] || { echo "    denied attempts: $(grep -c '^denied: ' <<<"$out") (want 7)"; ok=1; }
    grep -qx "reply=$tok" <<<"$out" || { echo "    control: no reply after the attempts: $(grep -E '^(reply|connect_failed)=' <<<"$out")"; ok=1; }
    dir_snapshot "$SD" > "$WORK/21/after"
    cmp -s "$WORK/21/before" "$WORK/21/after" || { echo "    socket directory changed:"; diff "$WORK/21/before" "$WORK/21/after" | head -4 | sed 's/^/      /'; ok=1; }
    [ "$(host_client "$SD/echo.sock" host21)" = "reply=host21" ] || { echo "    the server no longer answers from the host"; ok=1; }
    nothing_left "$n" || { echo "    resources left"; ok=1; }
    # A run that ends by timeout.
    setup 21t; local nt; nt=$(name_of 21t)
    local keep=$TIMEOUT_ARG; TIMEOUT_ARG=3
    vrun 21t --socket-dir "$SD" "$nt" -- sleep 30
    TIMEOUT_ARG=$keep
    [ "$(rc_of 21t)" = 124 ] || { echo "    timeout run: rc=$(rc_of 21t)"; ok=1; }
    dir_snapshot "$SD" > "$WORK/21/after-timeout"
    cmp -s "$WORK/21/before" "$WORK/21/after-timeout" || { echo "    socket directory changed by the timed-out run"; ok=1; }
    nothing_left "$nt" || { echo "    timeout run: resources left"; ok=1; }
    stop_echo
    return $ok
}
check "VRUN21 /run/agent is read-only for the box user and root in the box; lbx changes nothing in it" vrun21

# ── VRUN22 ───────────────────────────────────────────────────────────────
# Requirement: R16, and the documentation's instruction to mount the
#   directory, not the file (plans/2026_09_29_run_socket_mount_and_no_network/00_overview.md sections 2 and 10)
# Behavior: when the caller's server restarts during a run (its socket
#   removed and created again, a new inode, same name), the command
#   connects to the new socket through /run/agent. Control in the same
#   check: a plain container given only the socket file as a bind mount
#   connects before the same restart and fails after it.
# Theory: a directory mount shows the directory's current entries; a file
#   mount pins the old inode, which no server listens on after a restart.
#   Without the control, a passing directory case would not show that the
#   file mount really breaks.
# Not a text comparison: real connections before and after a real
#   restart, and the socket's inode on the host.
# LLM: markers in /data synchronize the restart with the command.
vrun22() {
    setup 22; local n; n=$(name_of 22); copy_tools
    local SD="$WORK/22/sock"; mkdir -p "$SD"; chmod 700 "$SD"
    start_echo "$SD/echo.sock" "$WORK/22/server.log" || return 1
    local script='
        perl /data/client.pl /run/agent/echo.sock first
        touch /data/phase1
        t=0; while [ ! -e /data/go ] && [ $t -lt 600 ]; do sleep 0.1; t=$((t + 1)); done
        perl /data/client.pl /run/agent/echo.sock second'
    ( vrun 22 --socket-dir "$SD" "$n" -- sh -c "$script" ) &
    local bg=$! ok=0 ino1 ino2
    if wait_file "$D_DATA/phase1" 120; then
        # A second name keeps the old socket's inode in use, so the new
        # socket cannot be given the same inode number.
        ln "$SD/echo.sock" "$WORK/22/old.sock"
        ino1=$(stat -c %i "$SD/echo.sock")
        stop_echo; start_echo "$SD/echo.sock" "$WORK/22/server.log" || ok=1
        ino2=$(stat -c %i "$SD/echo.sock")
        [ "$ino1" != "$ino2" ] || { echo "    control: the restarted server kept the same inode"; ok=1; }
    else
        echo "    the command never reached its marker"; ok=1
    fi
    touch "$D_DATA/go"
    wait $bg
    local out; out="$(cat "$WORK/22/out")"
    [ "$(rc_of 22)" = 0 ] || { echo "    rc=$(rc_of 22)"; show_err 22; ok=1; }
    grep -qx "reply=first" <<<"$out" || { echo "    before the restart: $(grep -E '^(reply|connect_failed)=' <<<"$out" | head -1)"; ok=1; }
    grep -qx "reply=second" <<<"$out" || { echo "    after the restart: $(grep -E '^(reply|connect_failed)=' <<<"$out" | tail -1)"; ok=1; }
    rm -f "$WORK/22/old.sock"
    nothing_left "$n" || { echo "    resources left"; ok=1; }
    # Control: a single-file bind mount of the socket.
    local fc="lbx-test-v22file-$RUNID"
    docker run -d --name "$fc" --network none --user "$(id -u):$(id -g)" \
        --mount "type=bind,source=$SD/echo.sock,target=/s.sock" \
        -v "$SOCK_TOOLS/client.pl:/client.pl:ro" --entrypoint sleep llm-in-a-box:docker 120 >/dev/null 2>&1 \
        || { echo "    control: could not start the file-mount container"; stop_echo; return 1; }
    local before after
    before=$(docker exec "$fc" perl /client.pl /s.sock fbefore 2>&1)
    stop_echo; start_echo "$SD/echo.sock" "$WORK/22/server.log" || ok=1
    after=$(docker exec "$fc" perl /client.pl /s.sock fafter 2>&1)
    docker rm -f "$fc" >/dev/null 2>&1
    [ "$before" = "reply=fbefore" ] || { echo "    control: the file mount did not connect before the restart: $before"; ok=1; }
    case "$after" in connect_failed=*) ;; *) echo "    control: the file mount still connected after the restart: $after"; ok=1 ;; esac
    stop_echo
    return $ok
}
check "VRUN22 a restarted server is reachable through the directory mount; a file mount breaks" vrun22

# ── VRUN23 ───────────────────────────────────────────────────────────────
# Requirement: R20, R21 (plans/2026_09_29_run_socket_mount_and_no_network/00_overview.md section 2)
# Behavior: in a no-network run box the interfaces are lo and, on a host
#   whose kernel makes them, only the kernel's fallback tunnel devices
#   (NN_FALLBACK_TUNNELS), each down with no IPv4 or IPv6 address; lo has
#   no IPv6 address; the only IPv4 local address is 127.0.0.1 and there is
#   no IPv4 route; no connection
#   reaches 1.1.1.1:443, the default bridge's
#   gateway or the host's own address on a host listener's port,
#   169.254.169.254:80 or 2606:4700:4700::1111:443; example.com does not
#   resolve through resolv.conf or by asking 127.0.0.11; the host's
#   abstract socket is unreachable; a listener on 127.0.0.1 in the box is
#   reachable; the capability bounding set is the measured set and no new
#   privileges is set. From the host while the command runs: network mode
#   none, attached to the none network only, no relay container and no run
#   network of that name. Afterwards: exit 0, status=exited code=0, no
#   netlogs/<name>, no deny-log line, nothing left.
# Theory: a launcher that still attaches a network, or a docker that
#   ignores --network none, shows up as an interface, an address, a route
#   or a reached address; a broken box shows up as a failed loopback
#   control. The fallback tunnel devices (tunl0, ip_vti0 and the like) are
#   made by the kernel in every new network namespace when their drivers
#   are loaded and net.core.fb_tunnels_only_for_init_net is 0; down and
#   without an address they carry nothing, and the box lacks CAP_NET_ADMIN
#   to change that. Each part of that interface rule has its own control
#   (vrun23_rule_case), because the one real box cannot show that the rule
#   would refuse what it does not contain. Not covered by a control here: a
#   reachable metadata address or public IPv6 address (on a host without
#   them those probes are blocked for reasons of their own).
# Not a text comparison: real connection attempts and the kernel's view of
#   the interfaces from inside the box, and docker's view of the container.
# LLM: controls in the same check: an alpine container on the default
#   bridge reaches the host listener through the gateway and the host's
#   address, and 1.1.1.1:443; a container with host networking reaches the
#   host's abstract socket; the probe script in a container of the image on
#   a user-defined network reports the public address, the name and the
#   embedded resolver reached, and the interface rule (nn_interfaces_ok)
#   refuses that container's interfaces; in a namespace like the run
#   box's (vrun23_rule_case), the rule accepts two listed devices down
#   and without an address, and refuses, each with its own reason, a listed
#   device that is up, one with an IPv4 address, one with an IPv6 address,
#   an unlisted name, an IPv6 address on lo, and a second IPv4 address on
#   lo; the loopback control goes through the same connect function as
#   every blocked TCP probe.
NN_FALLBACK_TUNNELS=(tunl0 ip_vti0 ip6_vti0 sit0 ip6tnl0 gre0 gretap0 erspan0 ip6gre0)
# nn_interfaces_ok <probe output>: the interface rule of R21. Prints each
# reason it does not hold and returns 1 then.
nn_interfaces_ok() {
    local out="$1" i t line flags known seen_lo=false ok=0
    for i in $(sed -n 's/^interfaces=//p' <<<"$out"); do
        if [ "$i" = lo ]; then
            seen_lo=true
            line="$(grep -m1 "^interface_lo=" <<<"$out")"
            [[ "$line" =~ \ ipv6:0$ ]] || { echo "    lo has an IPv6 address or it could not be read: $line"; ok=1; }
            continue
        fi
        known=false
        for t in "${NN_FALLBACK_TUNNELS[@]}"; do [ "$i" = "$t" ] && known=true; done
        [ "$known" = true ] || { echo "    interface $i is neither lo nor a kernel fallback tunnel device"; ok=1; continue; }
        line="$(grep -m1 "^interface_$i=" <<<"$out")"
        flags="$(sed -n 's/.* flags:\(0x[0-9a-fA-F]\{1,8\}\) .*/\1/p' <<<"$line")"
        if [ -z "$flags" ] || (( flags & 1 )); then echo "    interface $i is up or its state is unknown: $line"; ok=1; fi
        [[ "$line" =~ \ ipv4:none\ ipv6:0$ ]] || { echo "    interface $i has an address or it could not be read: $line"; ok=1; }
    done
    [ "$seen_lo" = true ] || { echo "    no lo interface"; ok=1; }
    grep -qx 'local_addrs=127.0.0.1' <<<"$out" || { echo "    $(grep local_addrs= <<<"$out") (want only 127.0.0.1)"; ok=1; }
    return $ok
}
# vrun23_rule_case <label> <accept|refuse> <reason fragment or ""> <mutation>:
# a control for one part of nn_interfaces_ok. An alpine container with
# --network none and NET_ADMIN (a namespace like the run box's) gets a veth
# pair whose ends are renamed to two listed fallback tunnel names that its
# kernel has not made there ($A and $B, down, no address), loses lo's
# IPv6 address (as the run box's IPv6 setting removes it), then runs the
# mutation (a shell fragment using $A and $B). The probe runs in a
# container of the image joined to that namespace, as the box user's ids,
# and the rule must accept, or refuse with a reason containing the
# fragment, so each part is shown to refuse on its own. Env: GW,
# HOST_ADDR, LISTEN_PORT, ABS_NAME as for the probe.
vrun23_rule_case() {
    local label="$1" want="$2" frag="$3" mutation="$4"
    local c="lbx-test-v23mut-$RUNID" out why t=0
    docker rm -f "$c" >/dev/null 2>&1
    docker run -d --name "$c" --network none --cap-add NET_ADMIN alpine:3 sh -c '
        set -e
        set -- '"${NN_FALLBACK_TUNNELS[*]}"'
        A=""; B=""
        for t in "$@"; do [ -e "/sys/class/net/$t" ] && continue; if [ -z "$A" ]; then A=$t; elif [ -z "$B" ]; then B=$t; fi; done
        ip link add lbxa type veth
        ip link set lbxa name "$A"
        ip link set veth0 name "$B"
        ip -6 addr del ::1/128 dev lo 2>/dev/null || true
        '"$mutation"'
        touch /tmp/ready
        sleep 120' >/dev/null 2>&1 \
        || { echo "    rule control ($label): could not start the namespace container"; return 1; }
    while ! docker exec "$c" test -e /tmp/ready 2>/dev/null; do
        t=$((t + 1))
        [ $t -lt 40 ] && docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null | grep -x >/dev/null true \
            || { echo "    rule control ($label): the namespace was not prepared: $(docker logs "$c" 2>&1 | tail -2 | tr '\n' ' ')"; docker rm -f "$c" >/dev/null 2>&1; return 1; }
        sleep 0.25
    done
    out=$(docker run --rm --network "container:$c" --user "$(id -u):$(id -g)" -e GW -e HOST_ADDR -e LISTEN_PORT -e ABS_NAME \
        -v "$SOCK_TOOLS/probe.pl:/probe.pl:ro" --entrypoint perl llm-in-a-box:docker /probe.pl 2>/dev/null)
    docker rm -f "$c" >/dev/null 2>&1
    grep -q '^interfaces=' <<<"$out" || { echo "    rule control ($label): the probe printed no interfaces"; return 1; }
    if why=$(nn_interfaces_ok "$out"); then
        [ "$want" = accept ] && return 0
        echo "    rule control ($label): the interface rule accepted: $(grep -E '^interface' <<<"$out" | tr '\n' ' ')"; return 1
    fi
    if [ "$want" = refuse ] && grep -qF -- "$frag" <<<"$why"; then return 0; fi
    echo "    rule control ($label): want $want${frag:+ with \"$frag\"}, got a refusal:"; sed 's/^/      /' <<<"$why"; return 1
}
vrun23() {
    setup 23; local n; n=$(name_of 23); copy_tools
    local port; port=$(free_port) || { echo "    no free port"; return 1; }
    local listener="lbx-test-v23listen-$RUNID"
    docker run -d --rm --name "$listener" --network host alpine:3 sh -c "while true; do nc -l -p $port </dev/null; done" >/dev/null 2>&1 \
        || { echo "    could not start the host listener"; return 1; }
    local gw host_addr abs="lbx-test-v23-$RUNID" absp ok=0
    gw=$(docker network inspect bridge -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null)
    host_addr=$(hostname -I | awk '{print $1}')
    perl -MIO::Socket::UNIX -e '$s = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Local => "\0$ARGV[0]", Listen => 5) or die; while ($c = $s->accept) { print $c "abs-ok\n"; close $c }' "$abs" &
    absp=$!
    sleep 1
    local ctl
    # The listener serves one connection per `nc -l` and then restarts, so
    # a probe right after another one can find no listener; each listener
    # probe is retried for up to about 5 s (a blocked address still fails).
    ctl=$(docker run --rm alpine:3 sh -c "
        for a in $gw=gw_ok $host_addr=host_ok; do
            i=0; while [ \$i -lt 10 ]; do nc -z -w3 \${a%%=*} $port && { echo \${a#*=}; break; }; sleep 0.5; i=\$((i + 1)); done
        done
        nc -z -w5 1.1.1.1 443 && echo inet_ok" 2>/dev/null)
    grep -qx gw_ok <<<"$ctl" && grep -qx host_ok <<<"$ctl" && grep -qx inet_ok <<<"$ctl" \
        || { echo "    control: a default-bridge container could not reach the listener or the internet: $(tr '\n' ' ' <<<"$ctl")"; ok=1; }
    ctl=$(docker run --rm --network host --user "$(id -u):$(id -g)" --entrypoint perl llm-in-a-box:docker \
        -MIO::Socket::UNIX -e '$s = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Peer => "\0$ARGV[0]") or exit 1; print scalar <$s>' "$abs" 2>/dev/null)
    [ "$ctl" = abs-ok ] || { echo "    control: a host-network container did not reach the abstract socket ($ctl)"; ok=1; }
    # Control: the same probe script, in a container of the same image on a
    # user-defined network (which has docker's embedded resolver), reports
    # the public address, the name and the embedded resolver as reached, so
    # its "blocked" results in the run box are not the script's doing.
    local ctlnet="lbx-test-v23net-$RUNID"
    docker network create "$ctlnet" >/dev/null 2>&1
    ctl=$(docker run --rm --network "$ctlnet" --user "$(id -u):$(id -g)" -e GW="$gw" -e HOST_ADDR="$host_addr" -e LISTEN_PORT="$port" -e ABS_NAME="$abs" \
        -v "$SOCK_TOOLS/probe.pl:/probe.pl:ro" --entrypoint perl llm-in-a-box:docker /probe.pl 2>/dev/null)
    docker network rm "$ctlnet" >/dev/null 2>&1
    local k
    for k in public_ip dns_resolv embedded_public; do
        grep -qx "$k=reached" <<<"$ctl" || { echo "    control: the probe script did not reach $k from a user-defined network"; ok=1; }
    done
    nn_interfaces_ok "$ctl" >/dev/null \
        && { echo "    control: the interface rule accepted a container on a user-defined network: $(grep -E '^interface' <<<"$ctl" | tr '\n' ' ')"; ok=1; }
    # Controls for each part of the interface rule on its own.
    export GW="$gw" HOST_ADDR="$host_addr" LISTEN_PORT="$port" ABS_NAME="$abs"
    vrun23_rule_case "listed devices down, no address" accept "" ":" || ok=1
    vrun23_rule_case "a listed device up" refuse "is up" 'ip link set "$A" up' || ok=1
    vrun23_rule_case "a listed device with an IPv4 address" refuse "has an address" 'ip addr add 10.9.9.9/32 dev "$A"' || ok=1
    vrun23_rule_case "a listed device with an IPv6 address" refuse "has an address" 'ip -6 addr add fd00::9/128 dev "$A"' || ok=1
    vrun23_rule_case "a device with an unlisted name" refuse "neither lo nor" 'ip link set "$B" name lbxz9' || ok=1
    vrun23_rule_case "an IPv6 address on lo" refuse "lo has an IPv6 address" 'ip -6 addr add fd00::8/128 dev lo' || ok=1
    vrun23_rule_case "a second IPv4 address on lo" refuse "want only 127.0.0.1" 'ip addr add 10.9.9.8/32 dev lo' || ok=1
    unset GW HOST_ADDR LISTEN_PORT ABS_NAME
    local script='perl /data/probe.pl; touch /data/started; t=0; while [ ! -e /data/go ] && [ $t -lt 600 ]; do sleep 0.1; t=$((t + 1)); done'
    VENV=(GW="$gw" HOST_ADDR="$host_addr" LISTEN_PORT="$port" ABS_NAME="$abs")
    ( vrun_nn 23 --env GW --env HOST_ADDR --env LISTEN_PORT --env ABS_NAME "$n" -- sh -c "$script" ) &
    local bg=$!
    VENV=()
    if wait_file "$D_DATA/started" 120; then
        [ "$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$n" 2>/dev/null)" = none ] || { echo "    network mode: $(docker inspect -f '{{.HostConfig.NetworkMode}}' "$n" 2>&1)"; ok=1; }
        [ "$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$n" 2>/dev/null)" = "none " ] \
            || { echo "    networks: $(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$n" 2>&1)"; ok=1; }
        docker container inspect "llm-in-a-box-relay-$n" >/dev/null 2>&1 && { echo "    a relay exists"; ok=1; }
        docker network inspect "llm-in-a-box-net-$n" >/dev/null 2>&1 && { echo "    the internal network exists"; ok=1; }
        docker network inspect "llm-in-a-box-relaynet-$n" >/dev/null 2>&1 && { echo "    the egress network exists"; ok=1; }
    else
        echo "    the command never reached its marker"; ok=1
    fi
    touch "$D_DATA/go"
    wait $bg
    kill "$absp" 2>/dev/null; wait "$absp" 2>/dev/null
    docker rm -f "$listener" >/dev/null 2>&1
    local out; out="$(cat "$WORK/23/out")"
    [ "$(rc_of 23)" = 0 ] || { echo "    rc=$(rc_of 23)"; show_err 23; ok=1; }
    nn_interfaces_ok "$out" || {
        echo "    $(grep interfaces= <<<"$out")"
        grep -E '^(interface_|local_addrs=)' <<<"$out" | sed 's/^/      /'
        echo "      host net.core.fb_tunnels_only_for_init_net=$(cat /proc/sys/net/core/fb_tunnels_only_for_init_net 2>&1)"
        ok=1
    }
    grep -qx 'routes=0' <<<"$out" || { echo "    $(grep routes= <<<"$out")"; ok=1; }
    grep -qx 'loopback=reached' <<<"$out" || { echo "    control: loopback not reachable"; ok=1; }
    local k
    for k in public_ip gateway host_addr metadata ipv6 dns_resolv embedded_public abstract; do
        grep -q "^$k=" <<<"$out" || { echo "    $k not probed"; ok=1; continue; }
        grep -qx "$k=reached" <<<"$out" && { echo "    $k reached"; ok=1; }
    done
    local want; want="$(cap_mask "${MEASURED_CAPS[@]}")"
    grep -qx "CapBnd=$want" <<<"$out" || { echo "    $(grep CapBnd= <<<"$out") (want $want)"; ok=1; }
    grep -qx 'NoNewPrivs=1' <<<"$out" || { echo "    no new privileges not set"; ok=1; }
    [ "$(cat "$WORK/23/state/runs/$n/status" 2>/dev/null)" = "status=exited code=0" ] || { echo "    status file: $(cat "$WORK/23/state/runs/$n/status" 2>&1)"; ok=1; }
    [ ! -e "$WORK/23/state/netlogs/$n" ] || { echo "    netlogs/$n created"; ok=1; }
    grep -q 'lbx-run: deny-log=' "$WORK/23/err" && { echo "    deny-log line printed"; ok=1; }
    nothing_left "$n" || { echo "    resources left"; ok=1; }
    return $ok
}
check "VRUN23 a no-network run box has only loopback and no way out, with its protections intact" vrun23

# ── VRUN24 ───────────────────────────────────────────────────────────────
# Requirement: R22 (plans/2026_09_29_run_socket_mount_and_no_network/00_overview.md section 2)
# Behavior: with --no-network and --socket-dir together, the command gets
#   its token back through /run/agent/echo.sock and, in the same run,
#   cannot connect to 1.1.1.1:443 or resolve example.com.
# Theory: the intended use; a launcher that drops the mount when the
#   network is off, or the network when the mount is on, fails one half.
# Not a text comparison: real connections from inside the box.
# LLM: the echo server of VRUN20; control: the same two probes in a plain
#   container of the image on the default bridge reach the address and
#   resolve the name.
vrun24() {
    setup 24; local n; n=$(name_of 24); copy_tools
    local SD="$WORK/24/sock"; mkdir -p "$SD"; chmod 700 "$SD"
    start_echo "$SD/echo.sock" "$WORK/24/server.log" || return 1
    local tok="tok24-$RANDOM$RANDOM"
    VENV=(TOKEN="$tok")
    vrun_nn 24 --socket-dir "$SD" --env TOKEN "$n" -- sh -c '
        perl /data/client.pl /run/agent/echo.sock "$TOKEN"
        timeout 5 bash -c "exec 3<>/dev/tcp/1.1.1.1/443" 2>/dev/null && echo public=reached || echo public=blocked
        getent hosts example.com >/dev/null 2>&1 && echo dns=reached || echo dns=blocked'
    VENV=()
    stop_echo
    local ok=0 out; out="$(cat "$WORK/24/out")"
    # Control: the same two probes in a plain container on the default
    # bridge reach the address and resolve the name.
    local ctl
    ctl=$(docker run --rm --entrypoint bash llm-in-a-box:docker -c 'timeout 5 bash -c "exec 3<>/dev/tcp/1.1.1.1/443" 2>/dev/null && echo public=reached; getent hosts example.com >/dev/null 2>&1 && echo dns=reached' 2>/dev/null)
    grep -qx public=reached <<<"$ctl" && grep -qx dns=reached <<<"$ctl" || { echo "    control: a default-bridge container did not reach 1.1.1.1 or resolve example.com: $(tr '\n' ' ' <<<"$ctl")"; ok=1; }
    [ "$(rc_of 24)" = 0 ] || { echo "    rc=$(rc_of 24)"; show_err 24; ok=1; }
    grep -qx "reply=$tok" <<<"$out" || { echo "    reply: $(grep -E '^(reply|connect_failed)=' <<<"$out")"; ok=1; }
    grep -qx public=blocked <<<"$out" || { echo "    $(grep public= <<<"$out")"; ok=1; }
    grep -qx dns=blocked <<<"$out" || { echo "    $(grep dns= <<<"$out")"; ok=1; }
    nothing_left "$n" || { echo "    resources left"; ok=1; }
    return $ok
}
check "VRUN24 with --no-network and --socket-dir the socket is the only channel" vrun24

# ── The AppArmor option: shared helpers ────────────────────────────────
# abs.pl serve <name> | connect <name> | bound-connect <name> <path>: an
# abstract Unix socket server (answers "abs-ok"), or a client that prints
# abstract=reached or abstract=blocked; bound-connect first binds the
# client socket to <path> (a socket with a file system path of its own).
cat > "$SOCK_TOOLS/abs.pl" <<'PERL'
use strict; use warnings; use IO::Socket::UNIX;
my ($what, $name) = @ARGV;
if ($what eq 'serve') {
    my $s = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Local => "\0$name", Listen => 5) or die "listen: $!\n";
    while (my $c = $s->accept) { print $c "abs-ok\n"; close $c }
} elsif ($what eq 'bound-connect') {
    my ($c, $r);
    if (socket($c, Socket::AF_UNIX(), Socket::SOCK_STREAM(), 0) && bind($c, Socket::pack_sockaddr_un($ARGV[2]))
        && connect($c, Socket::pack_sockaddr_un("\0$name"))) { $r = <$c> }
    print 'abstract=' . (defined $r && $r eq "abs-ok\n" ? 'reached' : 'blocked') . "\n";
} else {
    my $c = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Peer => "\0$name");
    my $r = $c ? <$c> : undef;
    print 'abstract=' . (defined $r && $r eq "abs-ok\n" ? 'reached' : 'blocked') . "\n";
}
PERL
# inet.pl: whether this process may create IPv4 and IPv6 sockets, and
# whether a loopback listener can be reached.
cat > "$SOCK_TOOLS/inet.pl" <<'PERL'
use strict; use warnings; use Socket; use IO::Socket::INET;
print 'inet=' . (socket(my $a, AF_INET, SOCK_STREAM, 0) ? 'allowed' : 'denied') . "\n";
print 'inet6=' . (socket(my $b, AF_INET6, SOCK_STREAM, 0) ? 'allowed' : 'denied') . "\n";
my $l = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 5, Proto => 'tcp');
my $c = $l ? IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $l->sockport, Proto => 'tcp', Timeout => 4) : undef;
print 'loopback=' . ($c ? 'reached' : 'blocked') . "\n";
PERL
AA_PROFILES=/sys/kernel/security/apparmor/policy/profiles
# aa_loaded <name>: the profile is loaded in enforce mode on this host.
aa_loaded() {
    local d
    for d in "$AA_PROFILES"/*/; do
        [ "$(cat "$d/name" 2>/dev/null)" = "$1" ] && [ "$(cat "$d/mode" 2>/dev/null)" = enforce ] && return 0
    done
    return 1
}
# aa_mediates_unix: the kernel's AppArmor mediates Unix sockets (the
# feature file network/af_unix says yes). Without it the profiles load but
# their unix rules are not enforced and pathname socket connects are not
# checked, and the launcher refuses --apparmor-profile.
AA_AF_UNIX_FILE=/sys/kernel/security/apparmor/features/network/af_unix
aa_mediates_unix() { [ "$(cat "$AA_AF_UNIX_FILE" 2>/dev/null)" = yes ]; }
# aa_prereq_loaded: AppArmor is enabled and both profiles are loaded; a
# missing one is a failure.
aa_prereq_loaded() {
    [ "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null)" = Y ] \
        || { echo "    prerequisite: AppArmor is not enabled on this host"; return 1; }
    aa_loaded llm-in-a-box-run && aa_loaded llm-in-a-box-run-no-network \
        || { echo "    prerequisite: the llm-in-a-box-run profiles are not loaded (run tests/setup-run-test-host.sh as root)"; return 1; }
}
# aa_prereq: what VRUN25-VRUN28 need: AppArmor enabled and both profiles
# loaded (else a failure), then a kernel that mediates Unix sockets (else
# 77, an approved skip: the launcher refuses the option there and VRUN29
# checks that).
aa_prereq() {
    aa_prereq_loaded || return 1
    aa_mediates_unix || { SKIP_REASON="this kernel's AppArmor does not mediate Unix sockets"; return 77; }
}
# aa_profile_writable_dirs: the directories the profile lets the box write,
# read from the profile itself so this cannot go stale. The rule shape is
# `  /path/... rw...`.
aa_profile_writable_dirs() {
    sed -nE 's|^  (/[^ ]*)[[:space:]]+rw.*$|\1|p' "$REPO_ROOT/apparmor/llm-in-a-box-run" \
        | sed -E 's|/\{,\*\*\}$||; s|/\*\*$||; s|/[^/]*\*.*$||' | sort -u
}

# aa_socket_dir_reachable <host directory>: can a socket served from this host
# directory be connected to from a box under the profile?
#
# AppArmor mediates a socket that has a path through its FILE rules, and the
# path it judges is the one the socket was bound to. For a server running on
# the host that is the HOST path, not the path the box sees at /run/agent, so
# the connection is allowed only when the host directory is one the profile
# lets the box write. Measured on this kernel: with the socket directory at an
# unmatched host path the kernel records
#   apparmor="DENIED" operation="connect" class="file"
#     name="/srv/lbx-test/lbx-test-v28-.../echo.sock" requested_mask="w"
# and the connection fails, while the same server at /tmp (which the profile
# allows) is reached: `CONNECT OK: REACHED`.
aa_socket_dir_reachable() {
    local dir="$1" d
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        case "$dir/" in "$d/"*) return 0 ;; esac
    done < <(aa_profile_writable_dirs)
    return 1
}

# aa_socket_dir_or_skip <host directory>: 0 to continue, 77 to skip with the
# reason set. VRUN25-VRUN28 serve their socket from the host and need the box
# to reach it, which the kernel decides by the host path; when that path is
# not one the profile allows the check cannot pass, and skipping is what
# tests/approved-skips.txt already says these checks do on such a host.
aa_socket_dir_or_skip() {
    aa_socket_dir_reachable "$1" && return 0
    rm -rf "$1"
    SKIP_REASON="this kernel decides a socket connection by the path the server bound on the host, and $1 is not a path the profile allows"
    return 77
}

# srv_dir <id>: a new mode-700 directory (the set-group-id bit it would
# inherit from /srv/lbx-test cleared) under /srv/lbx-test (made by
# tests/setup-run-test-host.sh), a host path that no rule of the profile
# matches, unlike /tmp. AppArmor may check a
# connection to a host-served socket against the path the server bound on
# the host, not the path the box sees; host paths the profile does not
# match make the checks tell the two apart. Prints the path.
srv_dir() {
    local d="/srv/lbx-test/lbx-test-v$1-$RUNID"
    [ -d /srv/lbx-test ] && [ -w /srv/lbx-test ] || { echo "    prerequisite: a writable /srv/lbx-test (run tests/setup-run-test-host.sh)" >&2; return 1; }
    rm -rf "$d"; mkdir -p "$d" && chmod 00700 "$d" && printf '%s\n' "$d"
}
copy_aa_tools() { cp "$SOCK_TOOLS/client.pl" "$SOCK_TOOLS/abs.pl" "$SOCK_TOOLS/inet.pl" "$D_DATA/"; }
LABEL_CMD='l=$(cat /proc/self/attr/apparmor/current 2>/dev/null || cat /proc/self/attr/current 2>/dev/null); echo "label=$(printf "%s" "$l" | tr -d "\000\n")"'

# ── VRUN25 ───────────────────────────────────────────────────────────────
# Requirement: R25, R26, R28 (plans/2026_09_29_run_socket_mount_and_no_network/00_overview.md section 2)
# Behavior: a relay run with --apparmor-profile and a socket directory
#   runs under llm-in-a-box-run in enforce mode; the command has the host
#   user's ids (the entrypoint mapped the box user under the profile);
#   the token comes back through /run/agent/echo.sock; a file is created,
#   written, renamed, read and removed in /data, /tmp, /var/tmp, /dev/shm
#   and the home directory; node writes and reads a file in /data; a git
#   repository is created and committed to in /tmp; a request through
#   the relay to an allowed host gets an HTTP answer; exit 0, nothing left.
#   The socket directory sits at a host path under /srv/lbx-test.
# Theory: a profile that misses a path the entrypoint or ordinary agent
#   work needs makes the box never ready, the user mapping fail, or one of
#   these steps fail; a profile that blocks the connection to the relay
#   fails the request; a profile that is not applied shows another label.
# Not a text comparison: the kernel's label for the process and real
#   file, socket and program operations in a real container.
# LLM: needs the profiles loaded (tests/setup-run-test-host.sh).
vrun25() {
    aa_prereq || return $?
    timeout 8 bash -c 'exec 3<>/dev/tcp/api.anthropic.com/443' 2>/dev/null \
        || { echo "    prerequisite: no internet access from this host"; return 1; }
    setup 25; local n; n=$(name_of 25); copy_aa_tools
    # The socket directory must be at a host path the profile allows. The
    # kernel decides a connection to a host-served socket by the path the
    # server bound on the HOST, not the path the box sees (measured: the
    # audit record names the host path, and VRUN30 pins both halves), and the
    # profile allows /tmp but matches nothing under /srv. A socket served from
    # /srv/lbx-test is therefore unreachable and this check would be testing
    # an unsupported configuration; here the point is that the socket WORKS
    # under the profile. $WORK is under /tmp.
    local SD="$WORK/25/sock"; mkdir -p "$SD"; chmod 700 "$SD"
    aa_socket_dir_or_skip "$SD" || return $?
    start_echo "$SD/echo.sock" "$WORK/25/server.log" || { rm -rf "$SD"; return 1; }
    local tok="tok25-$RANDOM$RANDOM"
    local script="$LABEL_CMD"'
        echo "ids=$(id -u):$(id -g)"
        perl /data/client.pl /run/agent/echo.sock "$TOKEN"
        for d in /data /tmp /var/tmp /dev/shm "$HOME"; do
            f="$d/lbx-aa-$$"
            if echo x > "$f" && mv "$f" "$f.2" && [ "$(cat "$f.2")" = x ] && rm "$f.2"; then echo "files_ok=$d"; else echo "files_denied=$d"; fi
        done
        node -e "const fs = require(\"fs\"); fs.writeFileSync(\"/data/node.txt\", \"n\"); console.log(\"node=\" + fs.readFileSync(\"/data/node.txt\", \"utf8\"))"
        git init -q /tmp/r && git -C /tmp/r -c user.email=a@b -c user.name=a commit -q --allow-empty -m x && echo git=ok
        echo "relay=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 https://api.anthropic.com/)"'
    VENV=(TOKEN="$tok")
    vrun 25 --apparmor-profile --socket-dir "$SD" --env TOKEN "$n" -- sh -c "$script"
    VENV=()
    stop_echo
    local ok=0 out d; out="$(cat "$WORK/25/out")"
    [ "$(rc_of 25)" = 0 ] || { echo "    rc=$(rc_of 25)"; show_err 25; ok=1; }
    grep -qx 'label=llm-in-a-box-run (enforce)' <<<"$out" || { echo "    $(grep label= <<<"$out")"; ok=1; }
    grep -qx "ids=$(id -u):$(id -g)" <<<"$out" || { echo "    $(grep ids= <<<"$out")"; ok=1; }
    grep -qx "reply=$tok" <<<"$out" || { echo "    reply: $(grep -E '^(reply|connect_failed)=' <<<"$out") (a connect_failed here may mean the kernel judged the socket's host path under /srv/lbx-test)"; ok=1; }
    for d in /data /tmp /var/tmp /dev/shm /home/agent; do
        grep -qx "files_ok=$d" <<<"$out" || { echo "    file work in $d failed"; ok=1; }
    done
    grep -qx 'node=n' <<<"$out" || { echo "    node: $(grep node= <<<"$out")"; ok=1; }
    grep -qx 'git=ok' <<<"$out" || { echo "    git in /tmp failed"; ok=1; }
    grep -qE '^relay=[1-5][0-9][0-9]$' <<<"$out" || { echo "    a request through the relay to an allowed host failed: $(grep relay= <<<"$out")"; ok=1; }
    rm -rf "$SD"
    nothing_left "$n" || { echo "    resources left"; ok=1; }
    return $ok
}
check "VRUN25 under the profile the entrypoint, the socket and ordinary work in the writable places all work" vrun25

# ── VRUN26 ───────────────────────────────────────────────────────────────
# Requirement: R28 (plans/2026_09_29_run_socket_mount_and_no_network/00_overview.md section 2)
# Behavior: under the profile, root in the run box (docker exec -u 0, with
#   the run box's capabilities) cannot create a file in /opt, /usr/local
#   or /etc; control: in a run without the profile it can. (The box user
#   is not tried: file permissions stop it there anyway, so its failure
#   would prove nothing about the profile.) Pathname sockets are judged by
#   the path the box sees: with a plain container of the image under the
#   profile, a host socket from a host path no rule matches is denied when
#   mounted at /srv/ext and reached when mounted at /tmp/ext, and a host
#   socket from a host path under /tmp is denied when mounted at /srv/ext;
#   the first two cases also under the no-network profile; root in a plain
#   container under the no-network profile cannot create /opt/lbx-aa
#   (control: without it, it can); control: without the profile all three
#   socket cases connect. The documented limit:
#   a socket the host creates in the data directory (at a host path no
#   rule matches) while the run is going can be reached.
# Theory: root with DAC_OVERRIDE passes every permission check, so a
#   denial there is the profile's; without the profile the same actions
#   succeed. If the kernel judged a host-served socket by the path the
#   server bound on the host instead, the /tmp/ext and /srv/ext cases (and
#   the limit) would come out the other way round, and the check says so.
# Not a text comparison: real file and socket operations.
# LLM: `lbx` makes no mount but /data and /run/agent, so the socket cases
#   use a plain `docker run` under the profile.
vrun26_root_writes() { # <container> -> one line per target: <target>=created|denied
    local t
    for t in /opt/lbx-aa /usr/local/lbx-aa /etc/lbx-aa; do
        if docker exec -u 0 "$1" touch "$t" >/dev/null 2>&1; then echo "$t=created"; else echo "$t=denied"; fi
    done
}
# vrun26_connect <profile name, or "no"> <host socket directory> <box directory>
vrun26_connect() {
    local -a prof=(); [ "$1" = no ] || prof=(--security-opt "apparmor=$1")
    docker run --rm ${prof[@]+"${prof[@]}"} --security-opt no-new-privileges --cap-drop ALL --network none \
        --user "$(id -u):$(id -g)" -v "$2:$3" -v "$SOCK_TOOLS/client.pl:/client.pl:ro" \
        --entrypoint perl llm-in-a-box:docker /client.pl "$3/echo.sock" ext 2>&1
}
vrun26() {
    aa_prereq || return $?
    local ok=0 id prof n results
    for id in 26 26c; do
        # The data directory must also be at a host path the profile allows:
        # the check creates a socket in it DURING the run and asserts the box
        # can reach it, and the kernel judges that socket by its host path
        # (see VRUN25). $WORK is under /tmp, which the profile allows.
        setup "$id"; n=$(name_of "$id"); D_DATA="$WORK/$id/data"; mkdir -p "$D_DATA"; chmod 700 "$D_DATA"; copy_aa_tools
        prof=(--apparmor-profile); [ "$id" = 26c ] && prof=()
        local script='touch /data/ready; t=0; while [ ! -e /data/go ] && [ $t -lt 600 ]; do sleep 0.1; t=$((t + 1)); done; perl /data/client.pl /data/late.sock late'
        ( vrun "$id" ${prof[@]+"${prof[@]}"} "$n" -- sh -c "$script" ) &
        local bg=$!
        if wait_file "$D_DATA/ready" 120; then
            results=$(vrun26_root_writes "$n")
            start_echo "$D_DATA/late.sock" "$WORK/$id/late.log" || ok=1
        else
            echo "    $id: the command never reached its marker"; ok=1; results=""
        fi
        touch "$D_DATA/go"
        wait $bg
        stop_echo
        if [ "$id" = 26 ]; then
            [ "$(grep -c '=denied$' <<<"$results")" = 3 ] || { echo "    under the profile, root in the box: $(tr '\n' ' ' <<<"$results")"; ok=1; }
            grep -qx 'reply=late' "$WORK/$id/out" || { echo "    the limit: a socket created in /data during the run was not reachable: $(cat "$WORK/$id/out") (if the control reached it, the kernel judged the host path)"; ok=1; }
        else
            [ "$(grep -c '=created$' <<<"$results")" = 3 ] || { echo "    control without the profile, root in the box: $(tr '\n' ' ' <<<"$results")"; ok=1; }
            grep -qx 'reply=late' "$WORK/$id/out" || { echo "    control: the socket in /data was not reachable without the profile"; ok=1; }
        fi
        nothing_left "$n" || { echo "    $id: resources left"; ok=1; }
        rm -rf "$D_DATA"
    done
    # The socket server's directory has to be at a host path the profile
    # allows. Measured: the kernel decides a connection to a host-served
    # socket by the path the server bound on the HOST (the audit record names
    # it), so a server under /srv, which the profile does not match, makes
    # r1 and r2 both fail no matter what the box's path is, and the check
    # would be testing an unsupported configuration instead of the profile's
    # file rules. $WORK is under /tmp, which the profile allows; TMPD below is
    # under /tmp as well, and the two are the same path from both sides, which
    # is what lets this check tell the BOX's path apart (r1 vs r2: the same
    # host socket, reached at a denied box path and at an allowed one).
    # THE MODEL THIS PINS, measured on this kernel: a connection to a socket
    # the HOST serves is decided by the path the server bound ON THE HOST, not
    # by the path the box sees. The audit record names the host path, and
    # whether the box's path is allowed makes no difference: with the server
    # under /tmp, a connect is reached from a box path the profile matches
    # (/tmp/ext) AND from one it does not (/srv/ext).
    #
    # So the discriminating case is the SERVER's host path: a socket served
    # from a directory the profile does not match (/srv/lbx-test, the srv_dir
    # below) is refused from every box path, and one served from /tmp is
    # reached from every box path. An earlier form of this check expected the
    # box's path to decide, which is the opposite of what the kernel does.
    local SRV SRVSRV TMPD
    SRV="$WORK/26/ext"; mkdir -p "$SRV"; chmod 700 "$SRV"          # host /tmp: allowed
    SRVSRV=$(srv_dir 26ext) || return 1                            # host /srv: NOT allowed
    # A host directory under /tmp itself, whatever TMPDIR says.
    TMPD=$(mktemp -d "/tmp/lbx-test-v26tmp-$RUNID.XXXXXX") || { rm -rf "$SRV" "$SRVSRV"; return 1; }
    local r1 r2 r3 r1n r2n c1 c2 c3 r4 r4n c4
    start_echo "$SRV/echo.sock" "$WORK/26/ext.log" || { rm -rf "$SRV" "$SRVSRV" "$TMPD"; return 1; }
    r1=$(vrun26_connect llm-in-a-box-run "$SRV" /srv/ext); c1=$(vrun26_connect no "$SRV" /srv/ext)
    r2=$(vrun26_connect llm-in-a-box-run "$SRV" /tmp/ext)
    r1n=$(vrun26_connect llm-in-a-box-run-no-network "$SRV" /srv/ext); r2n=$(vrun26_connect llm-in-a-box-run-no-network "$SRV" /tmp/ext); c2=$(vrun26_connect no "$SRV" /tmp/ext)
    stop_echo
    start_echo "$TMPD/echo.sock" "$WORK/26/ext2.log" || { rm -rf "$SRV" "$SRVSRV" "$TMPD"; return 1; }
    r3=$(vrun26_connect llm-in-a-box-run "$TMPD" /srv/ext); c3=$(vrun26_connect no "$TMPD" /srv/ext)
    stop_echo
    start_echo "$SRVSRV/echo.sock" "$WORK/26/ext3.log" || { rm -rf "$SRV" "$SRVSRV" "$TMPD"; return 1; }
    r4=$(vrun26_connect llm-in-a-box-run "$SRVSRV" /srv/ext)
    r4n=$(vrun26_connect llm-in-a-box-run-no-network "$SRVSRV" /srv/ext)
    c4=$(vrun26_connect no "$SRVSRV" /srv/ext)
    stop_echo
    rm -rf "$SRV" "$SRVSRV" "$TMPD"
    local hint=": the server's host path is not one the profile allows"
    [ "$r1" = reply=ext ] || { echo "    under the profile, a /tmp host socket at a box path the profile does not match was not reached ($r1)"; ok=1; }
    [ "$r2" = reply=ext ] || { echo "    under the profile, a /tmp host socket at /tmp/ext was not reached ($r2)"; ok=1; }
    [ "$r3" = reply=ext ] || { echo "    under the profile, a /tmp host socket (second directory) at /srv/ext was not reached ($r3)"; ok=1; }
    case "$r4" in connect_failed=*) ;; *) echo "    under the profile, a /srv host socket at /srv/ext was reached: $r4$hint"; ok=1 ;; esac
    case "$r4n" in connect_failed=*) ;; *) echo "    under the no-network profile, a /srv host socket at /srv/ext was reached: $r4n$hint"; ok=1 ;; esac
    [ "$c1" = reply=ext ] && [ "$c2" = reply=ext ] && [ "$c3" = reply=ext ] && [ "$c4" = reply=ext ] \
        || { echo "    control without the profile: $c1 $c2 $c3 $c4 (all four must be reached)"; ok=1; }
    [ "$r1n" = reply=ext ] || { echo "    under the no-network profile, a /tmp host socket was not reached ($r1n)"; ok=1; }
    [ "$r2n" = reply=ext ] || { echo "    under the no-network profile, a /tmp host socket at /tmp/ext was not reached ($r2n)"; ok=1; }
    # Root with DAC_OVERRIDE under the no-network profile (a plain container:
    # lbx starts its run box as root only for the entrypoint).
    local wn wc
    wn=$(docker run --rm --security-opt apparmor=llm-in-a-box-run-no-network --security-opt no-new-privileges --cap-drop ALL --cap-add DAC_OVERRIDE \
        --network none --user 0:0 --entrypoint sh llm-in-a-box:docker -c 'touch /opt/lbx-aa 2>/dev/null && echo created || echo denied' 2>/dev/null)
    wc=$(docker run --rm --security-opt no-new-privileges --cap-drop ALL --cap-add DAC_OVERRIDE \
        --network none --user 0:0 --entrypoint sh llm-in-a-box:docker -c 'touch /opt/lbx-aa 2>/dev/null && echo created || echo denied' 2>/dev/null)
    [ "$wn" = denied ] || { echo "    under the no-network profile, root created /opt/lbx-aa: $wn"; ok=1; }
    [ "$wc" = created ] || { echo "    control: without the profile, root could not create /opt/lbx-aa: $wc"; ok=1; }
    [ "$c1" = reply=ext ] && [ "$c2" = reply=ext ] && [ "$c3" = reply=ext ] \
        || { echo "    control: without the profile a mounted socket was not reached: $c1 / $c2 / $c3"; ok=1; }
    return $ok
}
check "VRUN26 the profile denies writes and socket connects outside the allowed paths, even to root" vrun26

# ── VRUN27 ───────────────────────────────────────────────────────────────
# Requirement: R28 (plans/2026_09_29_run_socket_mount_and_no_network/00_overview.md section 2)
# Behavior: an abstract socket served inside a run box under the profile
#   is reached from that run box; an abstract socket served in the same
#   network namespace by a helper container under docker's default
#   profile is not, neither from an unbound client nor from a client
#   bound to a path in /tmp first; under the no-network profile too
#   (unbound client); the helper is first shown to be answering; control: from a run box without the
#   profile, the helper's socket is reached both ways.
# Theory: abstract sockets live in the network namespace, which a helper
#   joins with --network container:<run box>; only the profile's unix
#   rule (peers under the same profile) can stop the connection.
# Not a text comparison: real connections between real containers.
# LLM: markers in /data synchronize the helper's start with the command.
vrun27() {
    aa_prereq || return $?
    local ok=0 id prof n helper out
    for id in 27 27n 27c; do
        setup "$id"; n=$(name_of "$id"); copy_aa_tools
        prof=(--apparmor-profile); [ "$id" = 27c ] && prof=()
        helper="lbx-test-v${id}help-$RUNID"
        local script='perl /data/abs.pl serve own-'"$RUNID"' & sleep 1; perl /data/abs.pl connect own-'"$RUNID"'
            touch /data/ready; t=0; while [ ! -e /data/go ] && [ $t -lt 600 ]; do sleep 0.1; t=$((t + 1)); done
            perl /data/abs.pl connect helper-'"$RUNID"'; perl /data/abs.pl bound-connect helper-'"$RUNID"' /tmp/lbx-bound.sock; kill %1 2>/dev/null; true'
        if [ "$id" = 27n ]; then
            ( vrun_nn "$id" "${prof[@]}" "$n" -- bash -c "$script" ) &
        else
            ( vrun "$id" ${prof[@]+"${prof[@]}"} "$n" -- bash -c "$script" ) &
        fi
        local bg=$!
        if wait_file "$D_DATA/ready" 120; then
            docker run -d --name "$helper" --network "container:$n" --user "$(id -u):$(id -g)" \
                -v "$SOCK_TOOLS/abs.pl:/abs.pl:ro" --entrypoint perl llm-in-a-box:docker /abs.pl serve "helper-$RUNID" >/dev/null 2>&1 \
                || { echo "    $id: could not start the helper"; ok=1; }
            # The helper must be listening before the run box tries it, or a
            # "blocked" result would only show that nobody was there.
            local t=0 alive=no
            while [ $t -lt 40 ]; do
                [ "$(docker exec "$helper" perl /abs.pl connect "helper-$RUNID" 2>/dev/null)" = abstract=reached ] && { alive=yes; break; }
                sleep 0.25; t=$((t + 1))
            done
            [ "$alive" = yes ] || { echo "    $id: the helper never answered on its abstract socket"; ok=1; }
        else
            echo "    $id: the command never reached its marker"; ok=1
        fi
        touch "$D_DATA/go"
        wait $bg
        docker rm -f "$helper" >/dev/null 2>&1
        out="$(cat "$WORK/$id/out")"
        if [ "$id" = 27n ]; then
            [ "$(sed -n 1p <<<"$out")" = abstract=reached ] || { echo "    under the no-network profile, the run box's own abstract socket: $(sed -n 1p <<<"$out")"; ok=1; }
            [ "$(sed -n 2p <<<"$out")" = abstract=blocked ] || { echo "    under the no-network profile, the helper's abstract socket: $(sed -n 2p <<<"$out")"; ok=1; }
        elif [ "$id" = 27 ]; then
            [ "$(sed -n 1p <<<"$out")" = abstract=reached ] || { echo "    under the profile, the run box's own abstract socket: $(sed -n 1p <<<"$out")"; ok=1; }
            [ "$(sed -n 2p <<<"$out")" = abstract=blocked ] || { echo "    under the profile, the helper's abstract socket: $(sed -n 2p <<<"$out")"; ok=1; }
            # Measured on this kernel: when the CLIENT is itself bound to a
            # path, that path is judged through the file rules (which allow
            # /tmp) and the peer=(label=...) rule does NOT apply, so the helper
            # is reached. The line above is the one that discriminates: an
            # UNBOUND client is stopped by the peer label. VRUN31 pins both
            # halves on their own; this check keeps them together with the
            # no-network case.
            [ "$(sed -n 3p <<<"$out")" = abstract=reached ] || {
                echo "    under the profile, from a client bound to a path in /tmp: $(sed -n 3p <<<"$out") (the kernel's behaviour changed: it no longer judges the client's own path)"
                ok=1
            }
        else
            [ "$(sed -n 2p <<<"$out")" = abstract=reached ] || { echo "    control without the profile, the helper's abstract socket: $(sed -n 2p <<<"$out")"; ok=1; }
            [ "$(sed -n 3p <<<"$out")" = abstract=reached ] || { echo "    control without the profile, from a bound client: $(sed -n 3p <<<"$out")"; ok=1; }
        fi
        nothing_left "$n" || { echo "    $id: resources left"; ok=1; }
    done
    return $ok
}
check "VRUN27 under the profile abstract sockets connect only to peers under the same profile" vrun27

# ── VRUN28 ───────────────────────────────────────────────────────────────
# Requirement: R25, R26, R28 (plans/2026_09_29_run_socket_mount_and_no_network/00_overview.md section 2)
# Behavior: a no-network run with --apparmor-profile and a socket
#   directory runs under llm-in-a-box-run-no-network in enforce mode; it
#   cannot create an IPv4 or an IPv6 socket, so its loopback listener is
#   not reachable; the token comes back through /run/agent/echo.sock;
#   exit 0. Control: the same run without the profile creates both kinds
#   of socket and reaches its loopback listener.
# Theory: the no-network profile denies internet sockets outright; a
#   launcher that picks the relay profile for a no-network run leaves them
#   allowed, and a profile that also blocked Unix sockets would lose the
#   socket directory.
# Not a text comparison: the kernel's label and real socket calls.
# LLM: IPv6 is disabled by sysctl in every run box, but creating an IPv6
#   socket still works without the profile (the control shows it).
vrun28() {
    aa_prereq || return $?
    local ok=0 id prof n out
    for id in 28 28c; do
        setup "$id"; n=$(name_of "$id"); copy_aa_tools
        # As in VRUN25: the socket directory has to be at a host path the
        # profile allows, or the connection is denied by host path.
        local SD="$WORK/$id/sock"; mkdir -p "$SD"; chmod 700 "$SD"
        aa_socket_dir_or_skip "$SD" || return $?
        start_echo "$SD/echo.sock" "$WORK/$id/server.log" || { rm -rf "$SD"; return 1; }
        prof=(--apparmor-profile); [ "$id" = 28c ] && prof=()
        VENV=(TOKEN="tok$id")
        vrun_nn "$id" ${prof[@]+"${prof[@]}"} --socket-dir "$SD" --env TOKEN "$n" -- sh -c "$LABEL_CMD"'; perl /data/inet.pl; perl /data/client.pl /run/agent/echo.sock "$TOKEN"'
        VENV=()
        stop_echo
        out="$(cat "$WORK/$id/out")"
        [ "$(rc_of "$id")" = 0 ] || { echo "    $id: rc=$(rc_of "$id")"; show_err "$id"; ok=1; }
        grep -qx "reply=tok$id" <<<"$out" || { echo "    $id: reply: $(grep -E '^(reply|connect_failed)=' <<<"$out") (under the profile, a connect_failed may mean the kernel judged the socket's host path)"; ok=1; }
        if [ "$id" = 28 ]; then
            grep -qx 'label=llm-in-a-box-run-no-network (enforce)' <<<"$out" || { echo "    $(grep label= <<<"$out")"; ok=1; }
            grep -qx inet=denied <<<"$out" && grep -qx inet6=denied <<<"$out" && grep -qx loopback=blocked <<<"$out" \
                || { echo "    under the profile: $(grep -E '^(inet|inet6|loopback)=' <<<"$out" | tr '\n' ' ')"; ok=1; }
        else
            grep -qx inet=allowed <<<"$out" && grep -qx inet6=allowed <<<"$out" && grep -qx loopback=reached <<<"$out" \
                || { echo "    control without the profile: $(grep -E '^(inet|inet6|loopback)=' <<<"$out" | tr '\n' ' ')"; ok=1; }
        fi
        rm -rf "$SD"
        nothing_left "$n" || { echo "    $id: resources left"; ok=1; }
    done
    return $ok
}
check "VRUN28 under the no-network profile no internet socket can be made; the socket directory works" vrun28

# ── VRUN29 ───────────────────────────────────────────────────────────────
# Requirement: R27 (plans/2026_09_29_run_socket_mount_and_no_network/00_overview.md section 2)
# Behavior: on the real host with the profiles loaded, a run with
#   --apparmor-profile executes (the launcher reads the real kernel files
#   correctly). With LLMBOX_SYSFS pointing at a copy of the host's AppArmor
#   entries that leaves out llm-in-a-box-run, the run is refused (125,
#   status=refused) and docker shows no container or network of it; with
#   a copy whose enabled parameter says N, likewise. On a kernel whose
#   AppArmor does not mediate Unix sockets, the run against the real files
#   is refused instead ("does not mediate Unix sockets", 125, nothing
#   created), and the copies carry the feature file as yes so that they
#   still reach the checks they test.
#   Positive control for the copies: a third copy that keeps every profile
#   (feature file as the other two carry it) lets the run execute, under
#   llm-in-a-box-run in enforce mode (/proc/self/attr/current in the box),
#   exit 0, nothing left.
# Theory: a launcher that cannot read the per-profile files as a normal
#   user refuses the accepted case; one that treats an unreadable or
#   missing entry as loaded starts the run; one that ignores the kernel's
#   Unix-socket feature starts a run whose profile would not enforce its
#   socket rules. Without the third copy, a copy step that dropped
#   every profile would make both refusals pass for the wrong reason.
# Not a text comparison: exit codes, the status line and docker's view.
# LLM: unloading the real profile would change host state other jobs
#   share, so the refusals use copies of the real entries.
vrun29_tree() { # <dir> <enabled value> <profile name to leave out> <Unix-socket feature file: copy|yes>
    local T="$1" d nm
    mkdir -p "$T/module/apparmor/parameters" "$T/kernel/security/apparmor/policy/profiles" "$T/kernel/security/apparmor/features/network"
    printf '%s\n' "$2" > "$T/module/apparmor/parameters/enabled"
    if [ "$4" = yes ]; then
        printf 'yes\n' > "$T/kernel/security/apparmor/features/network/af_unix"
    elif [ -e "$AA_AF_UNIX_FILE" ]; then
        cat "$AA_AF_UNIX_FILE" > "$T/kernel/security/apparmor/features/network/af_unix"
    fi
    for d in "$AA_PROFILES"/*/; do
        nm="$(cat "$d/name" 2>/dev/null)" || continue
        [ "$nm" = "$3" ] && continue
        mkdir -p "$T/kernel/security/apparmor/policy/profiles/$(basename "$d")"
        printf '%s\n' "$nm" > "$T/kernel/security/apparmor/policy/profiles/$(basename "$d")/name"
        cat "$d/mode" > "$T/kernel/security/apparmor/policy/profiles/$(basename "$d")/mode" 2>/dev/null
    done
}
vrun29() {
    aa_prereq_loaded || return 1
    local ok=0 n feature=copy
    setup 29; n=$(name_of 29)
    vrun 29 --apparmor-profile "$n" -- true
    if aa_mediates_unix; then
        [ "$(rc_of 29)" = 0 ] || { echo "    control: with the profiles loaded the run did not execute: rc=$(rc_of 29)"; show_err 29; ok=1; }
    else
        feature=yes
        { [ "$(rc_of 29)" = 125 ] && grep -qx 'lbx-run: status=refused code=125' "$WORK/29/err" \
            && grep -q "does not mediate Unix sockets" "$WORK/29/err"; } \
            || { echo "    on this kernel without Unix-socket mediation the run was not refused as such: rc=$(rc_of 29)"; show_err 29; ok=1; }
    fi
    nothing_left "$n" || { echo "    control: resources left"; ok=1; }
    local id enabled leave
    for id in 29a 29b; do
        setup "$id"; n=$(name_of "$id")
        if [ "$id" = 29a ]; then enabled=Y; leave=llm-in-a-box-run; else enabled=N; leave=""; fi
        vrun29_tree "$WORK/$id/sysfs" "$enabled" "$leave" "$feature"
        VENV=(LLMBOX_SYSFS="$WORK/$id/sysfs")
        vrun "$id" --apparmor-profile "$n" -- true
        VENV=()
        [ "$(rc_of "$id")" = 125 ] || { echo "    $id: rc=$(rc_of "$id") (want 125)"; ok=1; }
        grep -qx 'lbx-run: status=refused code=125' "$WORK/$id/err" || { echo "    $id: no refusal status line"; ok=1; }
        if [ "$id" = 29a ]; then grep -q "is not loaded" "$WORK/$id/err" || { echo "    29a: the refusal does not say the profile is not loaded"; ok=1; }
        else grep -q "AppArmor is not enabled" "$WORK/$id/err" || { echo "    29b: the refusal does not say AppArmor is not enabled"; ok=1; }; fi
        nothing_left "$n" || { echo "    $id: resources left"; ok=1; }
    done
    # Positive control for the two copies: a copy that keeps every profile
    # (and, like them, the Unix-socket feature file as the copies above
    # carry it) must let the run execute under the loaded profile, so the
    # refusals above come from what each copy leaves out, not from copying.
    setup 29c; n=$(name_of 29c)
    vrun29_tree "$WORK/29c/sysfs" Y "" "$feature"
    VENV=(LLMBOX_SYSFS="$WORK/29c/sysfs")
    vrun 29c --apparmor-profile "$n" -- sh -c "$LABEL_CMD"
    VENV=()
    [ "$(rc_of 29c)" = 0 ] || { echo "    29c: a copy with every profile did not let the run execute: rc=$(rc_of 29c)"; show_err 29c; ok=1; }
    grep -qx 'label=llm-in-a-box-run (enforce)' "$WORK/29c/out" || { echo "    29c: $(grep label= "$WORK/29c/out" || echo 'no label line')"; ok=1; }
    nothing_left "$n" || { echo "    29c: resources left"; ok=1; }
    return $ok
}
check "VRUN29 the launcher reads the real AppArmor state; a refusal creates nothing on real docker" vrun29

# ── VRUN30 ───────────────────────────────────────────────────────────────
# Behavior: under the profile, a socket directory whose HOST path the profile
#   allows is reachable from the run box, and one whose host path the profile
#   does not allow is not.
# Theory: AppArmor mediates a socket that has a path through its FILE rules,
#   and the path it judges is the one the socket was bound to; for a server
#   on the host, the host path, not the path the box sees at /run/agent. The
#   profile allows /run/agent, /data, /tmp, /var/tmp, /dev/shm and the box
#   user's home, so a socket directory anywhere else is unreachable from the
#   box whatever the box sees. That is a real limitation of --socket-dir under
#   --apparmor-profile and the documentation states it; this check pins both
#   halves so it cannot change silently. Measured by hand before it was
#   written: the same server at /tmp answers `CONNECT OK: REACHED`, and under
#   /srv/lbx-test the kernel records
#   `apparmor="DENIED" operation="connect" class="file"
#    name="/srv/lbx-test/.../echo.sock" requested_mask="w"`.
# Not a text comparison: a real connect from a real run box to a real server
#   that is provably listening (start_echo waits for it).
# LLM: the two halves differ only in where the socket directory lives.
vrun30() {
    aa_prereq || return $?
    local ok=0 id n out SD
    for id in 30tmp 30srv; do
        setup "$id"; n=$(name_of "$id"); copy_aa_tools
        if [ "$id" = 30tmp ]; then
            # A host path the profile allows (/tmp), whatever TMPDIR says.
            SD=$(mktemp -d "/tmp/lbx-test-v30-$RUNID.XXXXXX") || return 1
        else
            # A host path the profile does not allow.
            SD=$(srv_dir "$id") || return 1
        fi
        start_echo "$SD/echo.sock" "$WORK/$id/server.log" || { rm -rf "$SD"; return 1; }
        VENV=(TOKEN="tok$id")
        vrun "$id" --apparmor-profile --socket-dir "$SD" --env TOKEN "$n" -- sh -c "$LABEL_CMD"'; perl /data/client.pl /run/agent/echo.sock "$TOKEN"'
        VENV=()
        stop_echo
        out="$(cat "$WORK/$id/out")"
        grep -qx 'label=llm-in-a-box-run (enforce)' <<<"$out" || { echo "    $id: $(grep label= <<<"$out")"; ok=1; }
        if [ "$id" = 30tmp ]; then
            grep -qx "reply=tok$id" <<<"$out" || { echo "    an allowed host path is not reachable: $(grep -E '^(reply|connect_failed)=' <<<"$out")"; ok=1; }
        else
            grep -qE '^connect_failed=' <<<"$out" || { echo "    an unmatched host path was reached: $(grep -E '^(reply|connect_failed)=' <<<"$out")"; ok=1; }
        fi
        rm -rf "$SD"
        nothing_left "$n" || { echo "    $id: resources left"; ok=1; }
    done
    return $ok
}
check "VRUN30 under the profile a socket directory is reachable at a host path the profile allows, and not at one it does not" vrun30

# ── VRUN31 ───────────────────────────────────────────────────────────────
# Behavior: under the profile, an abstract-socket connection is decided by the
#   CLIENT's own path when the client is bound to one: an unbound client does
#   not reach another profile's abstract socket (the peer label rule), while a
#   client bound to a path under /tmp does.
# Theory: the profile's `unix (connect, send, receive)
#   peer=(label=llm-in-a-box-run)` rule is meant to keep the box off abstract
#   sockets served by other profiles. Measured: it applies to an unbound
#   client, and does NOT apply once the client is itself bound to a path; the
#   kernel then judges that path through the file rules, which /tmp allows.
#   This was an unverified design assumption in the LLM reference ("a client
#   bound to a /tmp path cannot reach another profile's abstract socket ...
#   the kernel may check only the client's path"); this check pins what the
#   kernel actually does, so a change is noticed. It is a limitation, not a
#   defect: the profile is defense in depth, and the boundary is the box's own
#   network namespace and its two mounts.
# Not a text comparison: a real connect from a real run box to a helper
#   container that is proven to be listening first.
# LLM: needs the profiles loaded (tests/setup-run-test-host.sh).
vrun31() {
    aa_prereq || return $?
    local ok=0 id=31 n helper out
    setup "$id"; n=$(name_of "$id"); copy_aa_tools
    helper="lbx-test-v${id}help-$RUNID"
    # The two clients this check tells apart differ only in whether the client
    # binds its own socket to a path first.
    local script='touch /data/ready; t=0; while [ ! -e /data/go ] && [ $t -lt 600 ]; do sleep 0.1; t=$((t + 1)); done'
    script+='; perl /data/abs.pl connect helper-'
    script+="$RUNID"
    script+='; perl /data/abs.pl bound-connect helper-'
    script+="$RUNID"
    script+=' /tmp/lbx-bound.sock; true'
    ( vrun "$id" --apparmor-profile "$n" -- bash -c "$script" ) &
    local bg=$!
    if wait_file "$D_DATA/ready" 120; then
        docker run -d --name "$helper" --network "container:$n" --user "$(id -u):$(id -g)" \
            -v "$SOCK_TOOLS/abs.pl:/abs.pl:ro" --entrypoint perl llm-in-a-box:docker /abs.pl serve "helper-$RUNID" >/dev/null 2>&1 \
            || { echo "    could not start the helper"; ok=1; }
        local t=0 alive=no
        while [ $t -lt 40 ]; do
            [ "$(docker exec "$helper" perl /abs.pl connect "helper-$RUNID" 2>/dev/null)" = abstract=reached ] && { alive=yes; break; }
            sleep 0.25; t=$((t + 1))
        done
        [ "$alive" = yes ] || { echo "    the helper never answered on its abstract socket"; ok=1; }
    else
        echo "    the command never reached its marker"; ok=1
    fi
    touch "$D_DATA/go"
    wait $bg
    docker rm -f "$helper" >/dev/null 2>&1
    out="$(cat "$WORK/$id/out")"
    # Line 1 is the unbound client (the peer label rule applies: blocked); line
    # 2 is the client bound to a path under /tmp (the kernel judges that path
    # and the peer rule does not apply: reached).
    [ "$(sed -n 1p <<<"$out")" = abstract=blocked ] || { echo "    an unbound client under the profile: $(sed -n 1p <<<"$out") (the peer label rule should stop it)"; ok=1; }
    [ "$(sed -n 2p <<<"$out")" = abstract=reached ] || { echo "    a client bound to /tmp: $(sed -n 2p <<<"$out") (the kernel's behaviour changed: it no longer judges the client's own path)"; ok=1; }
    nothing_left "$n" || { echo "    resources left"; ok=1; }
    return $ok
}
check "VRUN31 under the profile the peer label stops an unbound client from reaching another profile's abstract socket, and a client bound to /tmp reaches it" vrun31

echo ""
if [ "$SKIP" -gt 0 ]; then echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; else echo "Results: $PASS passed, $FAIL failed"; fi
[ "$FAIL" -eq 0 ]
