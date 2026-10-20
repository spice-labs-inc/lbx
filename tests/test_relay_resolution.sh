#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_relay_resolution.sh: behavioral tests for how the network relay
# resolves a CONNECT or plain-HTTP host name before it connects: which
# resolved addresses it refuses, and which reason and status it gives for
# a refused address, a failed lookup, and the policy refusals; how it
# applies the policy's idle timeout; its connection cap; how long it waits
# for a request head; and how it forwards bytes that arrive with the head.
# Requirements RR1, RR1a, RR2-RR10, RR12 and RR13:
# plans/2026_09_29_relay_resolution_reasons/00_overview.md section 2.
#
# WHAT: every check starts the real relay image and talks to the running
# relay. Each relay container runs with `--network none`, so no packet can
# leave it: host names get their addresses from lines the suite appends to
# the container's /etc/hosts, and a name that is in no hosts line fails its
# lookup because no resolver is reachable. The client runs inside the relay
# container (BusyBox `nc` for a raw CONNECT, BusyBox `wget` through
# `http_proxy` for plain HTTP). A check judges the status line the relay
# answers and the line it writes to its deny log at run time. An address the
# relay does not refuse reaches its connect step and fails there with
# `connect-failed:ENETUNREACH` (no network), which is how a check sees
# "not refused" without any traffic. Nothing reads or compares the relay's
# source text or any documentation (project rule 10): the deny log is
# output the relay produces while it runs.
#
# WHY: the relay is the only way out of a walled session or run box. A host
# name that resolves to a non-public address (private networks, loopback,
# link-local and the metadata address, the shared address space that
# carries tailnet addresses, site-local IPv6, multicast, reserved space)
# must be refused even when the policy allows the name, and in open mode
# this check is the only guard. A failed lookup is not a refusal of an
# address and must say so, with a status clients retry on.
#
# Conventions:
#   - check "<description>" <function>: runs the function directly (no
#     eval). A check prints why it failed, indented, before its [FAIL] line.
#   - Random values are drawn only in this shell (never inside `$(...)`,
#     where they would not advance the generator), from a seed printed at
#     start; LBX_TEST_SEED=<n> replays a run exactly.
#   - Every "absent" assertion is paired with a positive one proving the
#     path under test was reached.
#   - RELAY_EXTRA (an array, empty unless a check sets it) holds extra
#     `docker run` options for start_relay, for example the relay's
#     LLMBOX_REQUEST_TIMEOUT.
#   - LBX_TEST_RELAY_IMAGE selects the image (default
#     llm-in-a-box-relay:latest, built from docker/relay when missing).
#   - A missing prerequisite (docker, the image) is a failure, not a skip.
#   - Scratch space: a new directory under ${TMPDIR:-/tmp}, removed at exit.
#
# LLM-FRIENDLY NOTE: `start_relay <tag>` starts one relay (policy: enforce,
# allow `*.test`, block `blocked.test`) and sets RELAY (container) and RLOG
# (its deny log on the host). `add_hosts <file>` appends hosts lines as root
# inside the container. `connect_req <host:port>` and `raw_req <line>` set
# STATUS to the relay's status line; `plain_req <url>` does the same through
# `http_proxy`. `reason_of <host>` sets REASON to everything after
# ` reason=` on the last deny line for exactly that host (so for a refused
# address it reads `resolves-to-private addr=<address>`).
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RELAY_IMAGE="${LBX_TEST_RELAY_IMAGE:-llm-in-a-box-relay:latest}"

WORKROOT="$(mktemp -d "${TMPDIR:-/tmp}/llm-relay-resolution.XXXXXX")"
CONTAINERS=()
NETWORKS=()
RELAY_EXTRA=()
cleanup_all() {
    [ "${#CONTAINERS[@]}" -gt 0 ] && docker rm -f "${CONTAINERS[@]}" >/dev/null 2>&1
    [ "${#NETWORKS[@]}" -gt 0 ] && docker network rm "${NETWORKS[@]}" >/dev/null 2>&1
    rm -rf "$WORKROOT"
}
trap cleanup_all EXIT

SEED="${LBX_TEST_SEED:-$(( $(date +%s%N) % 32768 ))}"
RANDOM=$SEED
echo "seed=$SEED (replay with LBX_TEST_SEED=$SEED)"

PASS=0
FAIL=0
check() {
    local description="$1"; shift
    if "$@"; then
        echo "[PASS] $description"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $description"
        FAIL=$((FAIL + 1))
    fi
}

# ── Preflight: docker and the relay image (a missing one is a failure) ────
if ! docker info >/dev/null 2>&1; then
    echo "[FAIL] preflight: docker is not usable by this user"
    exit 1
fi
if ! docker image inspect "$RELAY_IMAGE" >/dev/null 2>&1; then
    echo "==> Building $RELAY_IMAGE (docker/relay) ..."
    if ! docker build -q -t "$RELAY_IMAGE" "$REPO_ROOT/docker/relay" >/dev/null; then
        echo "[FAIL] preflight: the relay image $RELAY_IMAGE could not be built"
        exit 1
    fi
fi

# ── Harness ───────────────────────────────────────────────────────────────

# start_relay <tag> [network] [policy tail]: one relay, with no network
# unless one is named; the policy tail is extra JSON members (for example
# `, "idle_timeout_seconds": 2`). Sets RELAY and RLOG.
start_relay() {
    local tag="$1" net="${2:-none}" tail="${3:-}" dir="$WORKROOT/$1"
    mkdir -p "$dir/log"
    printf '{"mode": "enforce", "allow": ["*.test"], "block": ["blocked.test"]%s}\n' "$tail" > "$dir/policy.json"
    RELAY="llm-relay-res-$$-$tag"
    RLOG="$dir/log/deny.log"
    CONTAINERS+=("$RELAY")
    docker run -d --name "$RELAY" --network "$net" \
        --dns 192.0.2.53 --dns-search . --dns-option timeout:5 \
        --dns-option attempts:2 --dns-option ndots:1 \
        --user "$(id -u):$(id -g)" \
        -e LLMBOX_POLICY=/policy.json \
        -e LLMBOX_DENY_LOG=/log/deny.log \
        -v "$dir/policy.json:/policy.json:ro" \
        -v "$dir/log:/log" \
        "${RELAY_EXTRA[@]}" \
        "$RELAY_IMAGE" >/dev/null || { echo "    relay $tag did not start"; return 1; }
    local _
    for _ in $(seq 1 50); do
        docker exec "$RELAY" nc -z 127.0.0.1 3128 2>/dev/null && return 0
        sleep 0.2
    done
    echo "    relay $tag never listened on 3128"
    return 1
}

# add_hosts <file>: append "<address> <name>" lines to the relay's
# /etc/hosts. Written as root through exec because docker's --add-host
# rewrites some addresses (it stores ::ffff:a.b.c.d as a.b.c.d).
add_hosts() {
    docker exec -u 0 -i "$RELAY" sh -c 'cat >> /etc/hosts' < "$1"
}

# raw_req <request line>: send the line and an empty header block; STATUS
# is the first line of the answer, without the carriage return.
raw_req() {
    STATUS="$(docker exec "$RELAY" sh -c \
        'printf "%s\r\n\r\n" "$1" | nc -w 15 127.0.0.1 3128 | head -n 1' _ "$1" | tr -d '\r')"
}

# connect_req <host:port>
connect_req() {
    raw_req "CONNECT $1 HTTP/1.1"
}

# plain_req <url>: a plain-HTTP absolute-form request through http_proxy.
# STATUS is the status line BusyBox wget reports for an error answer.
plain_req() {
    local out
    out="$(docker exec -e "http_proxy=http://127.0.0.1:3128" "$RELAY" \
        wget -q -T 15 -O /dev/null "$1" 2>&1)"
    STATUS="$(printf '%s\n' "$out" | sed -n 's/.*server returned error: //p' | head -n 1 | tr -d '\r')"
}

# reason_of <host>: REASON from the last deny line for exactly this host.
reason_of() {
    REASON="$(grep -F " DENY " "$RLOG" 2>/dev/null | grep -F " host=$1 reason=" | tail -n 1 | sed 's/.* reason=//')"
}

# expect_refused <host> <address | empty | "*">: the relay answered 403 and
# logged resolves-to-private with the given address (any address when
# empty; with or without an address when "*", for checks about which
# names are refused rather than what the line names).
expect_refused() {
    local host="$1" addr="$2"
    connect_req "$host:443"
    reason_of "$host"
    if [ "$STATUS" != "HTTP/1.1 403 Forbidden" ]; then
        echo "    $host: status '$STATUS', expected 403 Forbidden"; return 1
    fi
    if [ "$addr" = "*" ]; then
        case "$REASON" in resolves-to-private|"resolves-to-private "*) return 0 ;; esac
    elif [ -n "$addr" ]; then
        [ "$REASON" = "resolves-to-private addr=$addr" ] && return 0
    else
        case "$REASON" in "resolves-to-private addr="?*) return 0 ;; esac
    fi
    echo "    $host: reason '$REASON', expected resolves-to-private addr=${addr:-<address>}"
    return 1
}

# expect_not_refused <host> [exact reason]: the address passed resolution,
# the relay tried to connect and failed (no route), answered 403 as before,
# and logged connect-failed: exactly the given reason when one is given
# (IPv4 targets: connect-failed:ENETUNREACH), otherwise any connect-failed
# code (IPv6 errors vary with the runner's IPv6 setup).
expect_not_refused() {
    local host="$1" want="${2:-}"
    connect_req "$host:443"
    reason_of "$host"
    [ "$STATUS" = "HTTP/1.1 403 Forbidden" ] \
        || { echo "    $host: status '$STATUS', expected 403 Forbidden"; return 1; }
    if [ -n "$want" ]; then
        [ "$REASON" = "$want" ] && return 0
    else
        case "$REASON" in connect-failed:*) return 0 ;; esac
    fi
    echo "    $host: reason '$REASON', expected ${want:-the connect step (connect-failed:...)}"
    return 1
}

# ── Address generation (main shell only) ──────────────────────────────────

# rand32: sets R32 to a random 32-bit value.
rand32() {
    R32=$(( ((RANDOM << 17) ^ (RANDOM << 2) ^ RANDOM) & 0xffffffff ))
}

# v4 <int>: sets ADDR to the dotted form of a 32-bit value.
v4() {
    ADDR="$(( ($1 >> 24) & 255 )).$(( ($1 >> 16) & 255 )).$(( ($1 >> 8) & 255 )).$(( $1 & 255 ))"
}

# gen4 <a.b.c.d> <prefix> <first|last|random>: sets ADDR inside the range.
gen4() {
    local IFS=. o
    read -r -a o <<< "$1"
    local base=$(( (o[0] << 24) | (o[1] << 16) | (o[2] << 8) | o[3] ))
    local host=$(( (1 << (32 - $2)) - 1 ))
    base=$(( base & ~host & 0xffffffff ))
    case "$3" in
        first) v4 "$base" ;;
        last) v4 $(( base | host )) ;;
        *) rand32; v4 $(( base | (R32 & host) )) ;;
    esac
}

# gen6 <eight colon-separated hex groups> <prefix> <first|last|random>:
# sets ADDR (all eight groups written out) inside the range.
gen6() {
    local IFS=: g i bits mask out=() r
    read -r -a g <<< "$1"
    for ((i = 0; i < 8; i++)); do
        bits=$(( $2 - 16 * i ))
        (( bits < 0 )) && bits=0
        (( bits > 16 )) && bits=16
        mask=$(( bits == 0 ? 0 : (0xffff << (16 - bits)) & 0xffff ))
        case "$3" in
            first) r=0 ;;
            last) r=0xffff ;;
            *) r=$(( RANDOM ^ ((RANDOM & 1) << 15) )) ;;
        esac
        out+=("$(printf '%x' $(( (0x${g[$i]} & mask) | (r & ~mask & 0xffff) )))")
    done
    ADDR="$(IFS=:; echo "${out[*]}")"
}

# ══ RES1 ══════════════════════════════════════════════════════════════════
# Requirement (RR1, RR6): "When getaddrinfo raises socket.gaierror, the
#   relay denies with reason=resolve-failed:<code>, never
#   resolves-to-private"; "A lookup failure answers 503 Service
#   Unavailable".
# Theory: a name in no hosts line, with no reachable resolver, fails with
#   EAI_AGAIN. A relay that folds lookup failures into refusals logs
#   resolves-to-private and answers 403; a relay that reports the cause
#   logs resolve-failed:EAI_AGAIN and answers 503. The positive
#   precondition is that the deny line for this name exists at all.
# Rule 10: judges the live relay's status line and deny log only.
# LLM summary: lookup timeout -> 503 + resolve-failed:EAI_AGAIN, and no
#   resolves-to-private line for that name.
res1() {
    connect_req "nowhere.test:443"
    reason_of "nowhere.test"
    local ok=0
    [ -n "$REASON" ] || { echo "    no deny line for nowhere.test"; ok=1; }
    [ "$REASON" = "resolve-failed:EAI_AGAIN" ] || { echo "    reason '$REASON', expected resolve-failed:EAI_AGAIN"; ok=1; }
    [ "$STATUS" = "HTTP/1.1 503 Service Unavailable" ] || { echo "    status '$STATUS', expected 503 Service Unavailable"; ok=1; }
    if grep -F " host=nowhere.test reason=resolves-to-private" "$RLOG" >/dev/null 2>&1; then
        echo "    a lookup failure was logged as resolves-to-private"; ok=1
    fi
    return $ok
}

# ══ RES2 ══════════════════════════════════════════════════════════════════
# Requirement (RR5): "A lookup is attempted once per request."
# Theory: one failed lookup takes one resolver timeout (about 5 seconds
#   with musl's defaults); a relay that retried would take 10 seconds or
#   more before answering. The lower bound (3 seconds) proves the request
#   really waited on the resolver, so a fast unrelated refusal cannot pass.
# Rule 10: measures the live relay's answer time.
#   Scope: the timeout case (EAI_AGAIN); a retry after a fast failure such
#   as EAI_NONAME would not show in the timing. The resolver settings are
#   pinned by start_relay (timeout 5 s, 2 attempts), so the host's own
#   resolver options cannot change the timing.
# LLM summary: failed lookup verdict arrives in [3 s, 9 s): one attempt.
res2() {
    local t0 t1 ms
    t0=$(date +%s%N)
    connect_req "nowhere-timed.test:443"
    t1=$(date +%s%N)
    ms=$(( (t1 - t0) / 1000000 ))
    reason_of "nowhere-timed.test"
    case "$REASON" in
        resolves-to-private*|resolve-failed:*) ;;
        *) echo "    no lookup-failure verdict for nowhere-timed.test (reason '$REASON')"; return 1 ;;
    esac
    if [ "$ms" -lt 3000 ] || [ "$ms" -ge 9000 ]; then
        echo "    verdict after ${ms} ms, expected at least 3000 and under 9000"; return 1
    fi
    return 0
}

# ══ RES3 ══════════════════════════════════════════════════════════════════
# Requirement (RR3): "resolves-to-private is logged only when at least one
#   resolved address is refused, and names the first refused address as
#   addr=<address>."
# Theory: a name whose only address is 10.0.0.1 must be refused with 403
#   and the log must name 10.0.0.1, so an operator can tell what the name
#   resolved to.
# Rule 10: judges the live relay's status line and deny log only.
# LLM summary: private.test -> 10.0.0.1 -> 403 + resolves-to-private
#   addr=10.0.0.1.
res3() {
    expect_refused "private.test" "10.0.0.1"
}

# ══ RES4 ══════════════════════════════════════════════════════════════════
# Requirement (RR4): refused addresses include "membership in an explicit
#   floor list ...: 100.64.0.0/10".
# Theory: Python's ipaddress marks nothing in the shared address space as
#   private or reserved, so a relay relying on those flags connects to
#   tailnet addresses (Tailscale nodes, 100.100.100.100). The first
#   address, the tailnet name server address and the last address must be
#   refused; the addresses just outside the range (100.63.255.255,
#   100.128.0.0) are public and must reach the connect step, which pins
#   the range's edges.
# Rule 10: judges the live relay's deny log only.
# LLM summary: 100.64.0.0, 100.100.100.100, 100.127.255.255 refused;
#   100.63.255.255 and 100.128.0.0 reach connect.
res4() {
    local ok=0
    expect_refused "shared-first.test" "100.64.0.0" || ok=1
    expect_refused "shared-magicdns.test" "100.100.100.100" || ok=1
    expect_refused "shared-last.test" "100.127.255.255" || ok=1
    expect_not_refused "shared-below.test" "connect-failed:ENETUNREACH" || ok=1
    expect_not_refused "shared-above.test" "connect-failed:ENETUNREACH" || ok=1
    return $ok
}

# ══ RES5 ══════════════════════════════════════════════════════════════════
# Requirement (RR4): refused addresses include "IPv6 is_site_local" and
#   the floor range fec0::/10.
# Theory: ipaddress marks site-local IPv6 as global, not private, so only
#   an explicit rule refuses it. First, one inside and last address.
# Rule 10: judges the live relay's deny log only.
# LLM summary: fec0::, fec0::1, feff:ffff:...:ffff refused.
res5() {
    local ok=0
    expect_refused "site-first.test" "fec0::" || ok=1
    expect_refused "site-one.test" "fec0::1" || ok=1
    expect_refused "site-last.test" "feff:ffff:ffff:ffff:ffff:ffff:ffff:ffff" || ok=1
    return $ok
}

# ══ RES6 ══════════════════════════════════════════════════════════════════
# Requirement (RR4): "An IPv4-mapped IPv6 address is judged as its IPv4
#   address."
# Theory: ::ffff:100.64.0.1 must be refused like 100.64.0.1. The paired
#   ::ffff:1.1.1.1 must reach the connect step, proving the mapping judges
#   the embedded address instead of refusing every mapped address.
# Rule 10: judges the live relay's deny log only.
# LLM summary: ::ffff:100.64.0.1 refused (logged as resolved:
#   addr=::ffff:100.64.0.1); ::ffff:1.1.1.1 reaches connect.
res6() {
    local ok=0
    expect_refused "mapped-shared.test" "::ffff:100.64.0.1" || ok=1
    expect_not_refused "mapped-public.test" || ok=1
    return $ok
}

# ══ RES7 ══════════════════════════════════════════════════════════════════
# Requirement (RR4): the floor list includes 192.0.0.0/24.
# Theory: since CPython 3.12.4, ipaddress treats 192.0.0.9 and 192.0.0.10
#   as global; the relay refuses the whole /24 anyway. The addresses just
#   outside it (191.255.255.255, 192.0.1.0) must reach the connect step,
#   which pins the block's size.
# Rule 10: judges the live relay's deny log only.
# LLM summary: 192.0.0.9 and 192.0.0.10 refused; 191.255.255.255 and
#   192.0.1.0 reach connect.
res7() {
    local ok=0
    expect_refused "anycast-9.test" "192.0.0.9" || ok=1
    expect_refused "anycast-10.test" "192.0.0.10" || ok=1
    expect_not_refused "ietf-below.test" "connect-failed:ENETUNREACH" || ok=1
    expect_not_refused "ietf-above.test" "connect-failed:ENETUNREACH" || ok=1
    return $ok
}

# ══ RES8 (property) ═══════════════════════════════════════════════════════
# Requirement (RR4): the full refused set, and nothing public refused.
# Theory: for every refused range (the special-purpose ranges from the
#   IANA special-purpose address registries, plus the shared address
#   space and site-local IPv6), the first address, the last address and eight random
#   addresses inside it must all be refused; for public control blocks
#   (including the two blocks on either side of the shared address space
#   and a mapped public block), ten random addresses must all reach the
#   connect step. A relay that misses any part of a range, or refuses
#   public space, fails with the offending names and addresses listed.
# Rule 10: judges the live relay's deny log only; addresses come from the
#   printed seed.
#   A draw that never reached a verdict fails too: public draws must reach
#   the connect step, which needs their hosts lines, so the check cannot
#   pass on lookup failures (which a relay that folds lookup failures
#   into refusals would log as resolves-to-private).
# LLM summary: seeded sample over 31 refused ranges (plus ::1, the
#   Tailscale IPv6 prefix and 100.100.100.100) and 12 public blocks.
REFUSED4=(0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
    172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.168.0.0/16 198.18.0.0/15
    198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4)
REFUSED6=(0:0:0:0:0:0:0:0/96 0:0:0:0:0:ffff:6440:0/106 0:0:0:0:0:ffff:a00:0/104
    64:ff9b:0:0:0:0:0:0/96 64:ff9b:1:0:0:0:0:0/48 100:0:0:0:0:0:0:0/64
    2001:0:0:0:0:0:0:0/32 2001:2:0:0:0:0:0:0/48 2001:10:0:0:0:0:0:0/28
    2001:db8:0:0:0:0:0:0/32 2002:0:0:0:0:0:0:0/16 3fff:0:0:0:0:0:0:0/20
    5f00:0:0:0:0:0:0:0/16 fc00:0:0:0:0:0:0:0/7 fe80:0:0:0:0:0:0:0/10
    fec0:0:0:0:0:0:0:0/10 ff00:0:0:0:0:0:0:0/8)
PUBLIC4=(1.0.0.0/8 8.0.0.0/8 15.0.0.0/8 100.0.0.0/10 100.128.0.0/9
    192.31.196.0/24 192.52.193.0/24 192.88.99.0/24 192.175.48.0/24)
PUBLIC6=(2606:4700:0:0:0:0:0:0/32 2001:4860:0:0:0:0:0:0/32 0:0:0:0:0:ffff:800:0/104)
PROP_NAMES=()
PROP_ADDRS=()
PROP_WANT=()
prop_add() {
    PROP_NAMES+=("prop-${#PROP_NAMES[@]}.test")
    PROP_ADDRS+=("$ADDR")
    PROP_WANT+=("$1")
}
for spec in "${REFUSED4[@]}"; do
    for mode in first last r r r r r r r r; do gen4 "${spec%/*}" "${spec#*/}" "$mode"; prop_add refused; done
done
for spec in "${REFUSED6[@]}"; do
    for mode in first last r r r r r r r r; do gen6 "${spec%/*}" "${spec#*/}" "$mode"; prop_add refused; done
done
for ADDR in ::1 fd7a:115c:a1e0::1 100.100.100.100; do prop_add refused; done
for spec in "${PUBLIC4[@]}"; do
    for mode in r r r r r r r r r r; do gen4 "${spec%/*}" "${spec#*/}" "$mode"; prop_add public; done
done
for spec in "${PUBLIC6[@]}"; do
    for mode in r r r r r r r r r r; do gen6 "${spec%/*}" "${spec#*/}" "$mode"; prop_add public; done
done

res8() {
    local i n="${#PROP_NAMES[@]}" bad=0 shown=0 hosts="$WORKROOT/prop.hosts"
    : > "$hosts"
    for ((i = 0; i < n; i++)); do printf '%s %s\n' "${PROP_ADDRS[$i]}" "${PROP_NAMES[$i]}" >> "$hosts"; done
    add_hosts "$hosts" || { echo "    could not write the hosts lines"; return 1; }
    docker exec "$RELAY" sh -c 'for h in "$@"; do printf "CONNECT %s:443 HTTP/1.1\r\n\r\n" "$h" | nc -w 15 127.0.0.1 3128 >/dev/null; done' _ "${PROP_NAMES[@]}"
    for ((i = 0; i < n; i++)); do
        reason_of "${PROP_NAMES[$i]}"
        case "${PROP_WANT[$i]}:$REASON" in
            "refused:resolves-to-private"|"refused:resolves-to-private "*|"public:connect-failed:"*) continue ;;
        esac
        bad=$((bad + 1))
        if [ "$shown" -lt 12 ]; then
            echo "    ${PROP_ADDRS[$i]} (${PROP_WANT[$i]}): reason '$REASON'"
            shown=$((shown + 1))
        fi
    done
    [ "$bad" -eq 0 ] && return 0
    echo "    $bad of $n sampled addresses judged wrongly"
    return 1
}

# ══ RES9 ══════════════════════════════════════════════════════════════════
# Requirement (RR4, deny-by-resolution): a name is refused when ANY of its
#   addresses is refused.
# Theory: a name with one public and one private address must not be let
#   through by trying the public one; both orders of the hosts lines are
#   checked, and the line must name the refused address, not the public
#   one. A name with two refused addresses (10.0.0.1, then 10.0.0.2) must
#   name the first, as RR3 says, in both orders (10.0.0.2 then 10.0.0.1
#   must name 10.0.0.2), so naming the lowest address cannot pass. (IPv4 only: musl keeps hosts-file order
#   for IPv4 results but sorts IPv6 ones.)
# Rule 10: judges the live relay's deny log only.
# LLM summary: {1.1.1.1, 10.0.0.1} and {10.0.0.1, 1.1.1.1} refused naming
#   10.0.0.1; {10.0.0.1, 10.0.0.2} refused naming 10.0.0.1.
res9() {
    local ok=0
    expect_refused "mixed-public-first.test" "10.0.0.1" || ok=1
    expect_refused "mixed-private-first.test" "10.0.0.1" || ok=1
    expect_refused "two-private.test" "10.0.0.1" || ok=1
    expect_refused "two-private-desc.test" "10.0.0.2" || ok=1
    return $ok
}

# ══ RES10 ═════════════════════════════════════════════════════════════════
# Requirement (RR1, RR3, RR6): the plain-HTTP path gives the same reasons
#   and statuses as CONNECT.
# Theory: a plain-HTTP absolute-form request goes through the same
#   resolution step; a lookup failure must answer 503 with
#   resolve-failed:EAI_AGAIN and a refused address 403 with
#   resolves-to-private.
# Rule 10: judges the live relay's answers (as wget reports them) and
#   deny log only.
# LLM summary: http://nowhere-plain.test/ -> 503 + resolve-failed:EAI_AGAIN;
#   http://private.test/ -> 403 + resolves-to-private addr=10.0.0.1.
res10() {
    local ok=0
    plain_req "http://nowhere-plain.test/"
    reason_of "nowhere-plain.test"
    [ "$STATUS" = "HTTP/1.1 503 Service Unavailable" ] || { echo "    lookup failure: status '$STATUS', expected 503 Service Unavailable"; ok=1; }
    [ "$REASON" = "resolve-failed:EAI_AGAIN" ] || { echo "    lookup failure: reason '$REASON', expected resolve-failed:EAI_AGAIN"; ok=1; }
    plain_req "http://private.test/"
    reason_of "private.test"
    [ "$STATUS" = "HTTP/1.1 403 Forbidden" ] || { echo "    refused address: status '$STATUS', expected 403 Forbidden"; ok=1; }
    [ "$REASON" = "resolves-to-private addr=10.0.0.1" ] || { echo "    refused address: reason '$REASON', expected resolves-to-private addr=10.0.0.1"; ok=1; }
    return $ok
}

# ══ RES17 ═════════════════════════════════════════════════════════════════
# Requirement (RR1a, RR6): a failed lookup is denied with its own reason
#   and 503. A name the resolver library cannot even encode (an empty label, a
#   label over 63 characters) is a failed lookup too.
# Theory: `a..b.test` matches the allow list (`*.test`) but has an empty
#   label, so the lookup raises before any query is sent. A relay that only
#   handles resolver errors drops the connection with no answer and no
#   deny line; it must answer 503 and log resolve-failed:bad-name. The
#   63-character limit is covered by a 64-character label.
# Rule 10: judges the live relay's status line and deny log only.
# LLM summary: a..b.test and a 64-character label -> 503 +
#   resolve-failed:bad-name.
res17() {
    local ok=0 host long
    long="$(printf 'x%.0s' $(seq 64)).test"
    for host in "a..b.test" "$long"; do
        connect_req "$host:443"
        reason_of "$host"
        [ "$STATUS" = "HTTP/1.1 503 Service Unavailable" ] || { echo "    ${host:0:20}...: status '$STATUS', expected 503 Service Unavailable"; ok=1; }
        [ "$REASON" = "resolve-failed:bad-name" ] || { echo "    ${host:0:20}...: reason '$REASON', expected resolve-failed:bad-name"; ok=1; }
    done
    return $ok
}

# ══ RES12 ═════════════════════════════════════════════════════════════════
# Requirement (RR7): the policy reasons are unchanged.
# Theory: each policy refusal must still produce its own reason and 403:
#   an IP-literal target (ip-literal), a blocked name that the allow list
#   also matches (blocked: deny beats allow), a name outside the allow
#   list (not-allowed), a CONNECT target without a port (bad-target) and
#   a request that is neither CONNECT nor absolute-form (unsupported-request).
# Rule 10: judges the live relay's status line and deny log only.
# LLM summary: five policy refusals, five reasons, all 403.
res12() {
    local ok=0 spec line host want
    for spec in \
        "CONNECT 1.1.1.1:443 HTTP/1.1|1.1.1.1|ip-literal" \
        "CONNECT blocked.test:443 HTTP/1.1|blocked.test|blocked" \
        "CONNECT elsewhere.example:443 HTTP/1.1|elsewhere.example|not-allowed" \
        "CONNECT no-port-here HTTP/1.1|no-port-here|bad-target" \
        "GET /relative-path HTTP/1.1|/relative-path|unsupported-request"; do
        IFS='|' read -r line host want <<< "$spec"
        raw_req "$line"
        reason_of "$host"
        [ "$STATUS" = "HTTP/1.1 403 Forbidden" ] || { echo "    $want: status '$STATUS', expected 403 Forbidden"; ok=1; }
        [ "$REASON" = "$want" ] || { echo "    $want: reason '$REASON'"; ok=1; }
    done
    return $ok
}

# ══ RES13-RES20: the idle timeout (RR8, RR9) and the cap (RR10) ═════════════════════════════════════════════
# These checks need an upstream the relay may reach. It lives on an
# --internal docker network (no route out, so nothing leaves the host)
# whose subnet is in public space (inside 11.0.0.0/8, chosen from the
# seed), so the relay's resolution check lets its address through.
IDLE_NET="llm-relay-res-$$-net"
IDLE_B=$((RANDOM % 200 + 20)); IDLE_C=$((RANDOM % 250 + 1))
IDLE_SUBNET="11.$IDLE_B.$IDLE_C.0/24"
IDLE_UP="11.$IDLE_B.$IDLE_C.10"

# idle_setup: the network and five upstreams: an echo server on 8443; a
# plain-HTTP server on 8080 that answers 5 seconds after a request; and a
# streaming server on 8444 that reads the 70-byte ClientHello, then sends
# one line a second for 7 seconds while it also watches its input and
# sends EOF-SEEN when the input ends. (The watcher reads a copy of the
# connection on descriptor 3: a background job's standard input is
# /dev/null in a non-interactive shell.) A fourth, on 8445, never
# answers: it writes to /tmp/idle-close-seconds how many seconds after
# the connection its input ended. A fifth, on 8446, writes 8 MiB before it
# reads the 8 MiB it expects, then sends DONE-UPLOAD.
idle_setup() {
    docker network create --internal --subnet "$IDLE_SUBNET" "$IDLE_NET" >/dev/null \
        || { echo "    could not create network $IDLE_SUBNET"; return 1; }
    NETWORKS+=("$IDLE_NET")
    CONTAINERS+=("$IDLE_NET-up")
    docker run -d --name "$IDLE_NET-up" --network "$IDLE_NET" --ip "$IDLE_UP" \
        --entrypoint sh "$RELAY_IMAGE" -c '
            nc -lk -p 8443 -e cat &
            nc -lk -p 8080 -e sh -c "sleep 5; printf \"HTTP/1.0 200 OK\r\nContent-Length: 11\r\n\r\nslow-answer\"" &
            nc -lk -p 8444 -e sh -c "head -c 70 >/dev/null; exec 3<&0; (cat <&3 >/dev/null; echo EOF-SEEN) & i=0; while [ \$i -lt 7 ]; do i=\$((i + 1)); echo tick\$i; sleep 1; done; wait" &
            nc -lk -p 8445 -e sh -c "t0=\$(date +%s); head -c 70 >/dev/null; cat >/dev/null; echo \$((\$(date +%s) - t0)) > /tmp/idle-close-seconds" &
            nc -lk -p 8446 -e sh -c "head -c 70 >/dev/null; head -c 8388608 /dev/zero; head -c 8388608 >/dev/null; echo DONE-UPLOAD" &
            wait' >/dev/null || { echo "    upstream did not start"; return 1; }
}

# idle_relay <tag> <policy tail>: a relay on the network that knows the
# upstream as echo.test and slow.test.
idle_relay() {
    start_relay "$1" "$IDLE_NET" "$2" || return 1
    printf '%s echo.test\n%s slow.test\n' "$IDLE_UP" "$IDLE_UP" > "$WORKROOT/$1.hosts"
    add_hosts "$WORKROOT/$1.hosts"
}

# A minimal TLS ClientHello (70 bytes) whose server name is echo.test, as
# printf escapes: record and handshake headers, version, 32 zero bytes of
# random, no session id, one cipher suite, no compression, one
# server-name extension.
HELLO='\x16\x03\x01\x00\x41\x01\x00\x00\x3d\x03\x03'
for _ in $(seq 32); do HELLO="$HELLO\\x00"; done
HELLO="$HELLO"'\x00\x00\x02\x13\x01\x01\x00\x00\x12\x00\x00\x00\x0e\x00\x0c\x00\x00\x09echo.test'

# tunnel_idle: CONNECT echo.test:8443, send the ClientHello, stay silent
# for 5 seconds, then send one line. Sets TUNNEL_OUT to what came back.
tunnel_idle() {
    TUNNEL_OUT="$(docker exec "$RELAY" sh -c '{ printf "CONNECT echo.test:8443 HTTP/1.1\r\n\r\n"; sleep 0.5; printf "$1"; sleep 5; printf "LINE-AFTER-IDLE\n"; sleep 1; } | nc -w 20 127.0.0.1 3128' _ "$HELLO" 2>&1 | tr -d '\000')"
}

# ══ RES13 ═════════════════════════════════════════════════════════════════
# Requirement (RR8, RR9): "A policy file may set idle_timeout_seconds ...
#   absent means 300"; "the tunnel closes only after idle_timeout seconds
#   with no byte either way."
# Theory: a tunnel silent in both directions for 5 seconds must be closed
#   when the policy says 2, and must still carry data when it says 8 or
#   says nothing (the default, 300, is far longer). The 8-second and
#   default cases are the positive controls: they prove the tunnel, the
#   SNI check and the echo work, so a missing line in the 2-second case can
#   only come from the timeout. The margins (3 seconds each way) keep the
#   check stable on a loaded runner. It proves the default is longer than
#   5 seconds, not that it is exactly 300.
# Rule 10: judges what comes back through the live relay and its log.
# LLM summary: idle 5 s -> closed at 2, open at 8 and by default.
res13() {
    local ok=0 tag tail want
    for spec in "idle2|, \"idle_timeout_seconds\": 2|closed" \
                "idle8|, \"idle_timeout_seconds\": 8|open" \
                "idledef||open"; do
        IFS='|' read -r tag tail want <<< "$spec"
        idle_relay "$tag" "$tail" || { ok=1; continue; }
        tunnel_idle
        case "$TUNNEL_OUT" in
            *"200 Connection established"*"echo.test"*) ;;
            *) echo "    $tag: the tunnel did not echo the ClientHello (precondition)"; ok=1; continue ;;
        esac
        grep -q " ALLOW .* host=echo.test:8443 sni=echo.test" "$RLOG" \
            || { echo "    $tag: no ALLOW line (precondition)"; ok=1; }
        case "$want:$TUNNEL_OUT" in
            open:*LINE-AFTER-IDLE*) ;;
            closed:*LINE-AFTER-IDLE*) echo "    $tag: the line after 5 s idle came back (tunnel not closed)"; ok=1 ;;
            closed:*) ;;
            *) echo "    $tag: the line after 5 s idle did not come back (tunnel closed)"; ok=1 ;;
        esac
    done
    return $ok
}

# ══ RES16 ═════════════════════════════════════════════════════════════════
# Requirement (RR9): "Both directions share one timer that restarts on any
#   byte in either direction ... a server that streams for longer than the
#   timeout to a silent client keeps the tunnel open."
# Theory: the upstream streams one line a second for 7 seconds while the
#   client, after its ClientHello, sends nothing. With 2 seconds every line
#   must arrive, and the client's silent direction must stay open while the
#   stream runs: the upstream reports the end of its input (EOF-SEEN) only
#   when it happens, so EOF-SEEN must not come before tick7. A relay that
#   times each direction on its own ends the client's direction after 2
#   seconds and EOF-SEEN arrives early; one that ends the whole tunnel on
#   one direction's silence loses lines.
# Rule 10: judges what comes back through the live relay.
# LLM summary: timeout 2, one-way stream 7 s: tick1..tick7 all arrive, and
#   no EOF-SEEN before tick7.
res16() {
    local ok=0 out i
    idle_relay stream2 ', "idle_timeout_seconds": 2' || return 1
    out="$(docker exec "$RELAY" sh -c '{ printf "CONNECT echo.test:8444 HTTP/1.1\r\n\r\n"; sleep 0.5; printf "$1"; sleep 12; } | nc -w 20 127.0.0.1 3128' _ "$HELLO" 2>&1 | tr -d '\000')"
    case "$out" in *"200 Connection established"*) ;; *) echo "    the tunnel was not established (precondition)"; return 1 ;; esac
    for i in 1 2 3 4 5 6 7; do
        case "$out" in *"tick$i"*) ;; *) echo "    tick$i did not arrive (the streaming direction was ended)"; ok=1 ;; esac
    done
    local eof_at tick7_at
    eof_at="$(printf '%s\n' "$out" | grep -n -m1 EOF-SEEN | cut -d: -f1)"
    tick7_at="$(printf '%s\n' "$out" | grep -n -m1 tick7 | cut -d: -f1)"
    if [ -n "$eof_at" ] && { [ -z "$tick7_at" ] || [ "$eof_at" -lt "$tick7_at" ]; }; then
        echo "    EOF-SEEN arrived before tick7 (the client's silent direction was ended while the stream ran)"; ok=1
    fi
    return $ok
}

# ══ RES18 ═════════════════════════════════════════════════════════════════
# Requirement (RR9): "the tunnel closes only after idle_timeout seconds
#   with no byte either way."
# Theory: after the ClientHello, a tunnel to an upstream that never
#   answers carries no byte either way. With 3 seconds the relay must
#   close the whole tunnel about 3 seconds after the last byte: the
#   upstream measures the time from its connection to the end of its input
#   and must see 3 to 6 seconds, and 7 seconds after the start the relay
#   must hold no established connection on its client side, while the
#   client itself stays connected for 12 seconds. A relay that never
#   closed a silent tunnel would show 12 or more; one that only
#   half-closed toward the upstream would still hold the client's side.
# Rule 10: judges the time the upstream saw and the relay's sockets.
# LLM summary: silent both ways, timeout 3 -> upstream input ends after
#   3-6 s and the relay's client side is closed by 7 s (client holds on
#   for 12 s).
res18() {
    local v n ok=0
    idle_relay silent3 ', "idle_timeout_seconds": 3' || return 1
    docker exec "$IDLE_NET-up" rm -f /tmp/idle-close-seconds
    printf '%s\n' "{ printf 'CONNECT echo.test:8445 HTTP/1.1\r\n\r\n'; sleep 0.5; printf '$HELLO'; sleep 12; } | nc -w 20 127.0.0.1 3128 >/dev/null 2>&1" \
        > "$WORKROOT/silent-client.sh"
    docker exec -i "$RELAY" sh -c 'cat > /tmp/silent-client.sh' < "$WORKROOT/silent-client.sh"
    docker exec -d "$RELAY" sh /tmp/silent-client.sh
    sleep 7
    n="$(docker exec "$RELAY" sh -c 'netstat -tn 2>/dev/null | awk "\$4 ~ /:3128\$/ && \$6 == \"ESTABLISHED\"" | wc -l')"
    [ "$n" = 0 ] || { echo "    7 s after the start the relay still holds $n established client connection(s)"; ok=1; }
    v="$(docker exec "$IDLE_NET-up" cat /tmp/idle-close-seconds 2>/dev/null)"
    if [ -z "$v" ]; then
        echo "    the upstream never saw its input end"; ok=1
    elif [ "$v" -lt 3 ] || [ "$v" -gt 6 ]; then
        echo "    the upstream's input ended after ${v} s, expected 3 to 6"; ok=1
    fi
    docker exec "$RELAY" sh -c 'pkill nc; pkill sleep' >/dev/null 2>&1
    return $ok
}

# ══ RES20 ═════════════════════════════════════════════════════════════════
# Requirement (RR9): "Both directions flow at the same time: a peer that
#   writes before it reads must not stall the other direction."
# Theory: the upstream writes 8 MiB before it reads anything, while the
#   client uploads 8 MiB and reads at the same time (writer and reader are
#   separate processes on one connection). A relay that copies both
#   directions in one loop with a blocking send stops reading the upstream
#   while it waits for the upstream to read, so both sides wait on each
#   other until the idle timeout kills the tunnel. A full-duplex relay
#   delivers all 8 MiB down, the upstream receives all 8 MiB up, and then
#   sends DONE-UPLOAD.
# Rule 10: judges the bytes the client received through the live relay.
# LLM summary: simultaneous 8 MiB each way with idle 5 -> all bytes and
#   DONE-UPLOAD arrive (39-byte 200 + 8388608 + 12 = 8388659 bytes).
res20() {
    local got tail
    idle_relay duplex5 ', "idle_timeout_seconds": 5' || return 1
    printf '%s\n' \
        'printf "CONNECT echo.test:8446 HTTP/1.1\r\n\r\n"' \
        'sleep 0.5' \
        "printf '$HELLO'" \
        'head -c 8388608 /dev/zero &' \
        'cat > /tmp/duplex-down' \
        'wait' > "$WORKROOT/duplex-client.sh"
    docker exec -i "$RELAY" sh -c 'cat > /tmp/duplex-client.sh' < "$WORKROOT/duplex-client.sh"
    docker exec "$RELAY" sh -c 'rm -f /tmp/duplex-down; timeout 40 nc 127.0.0.1 3128 -e sh /tmp/duplex-client.sh' >/dev/null 2>&1
    got="$(docker exec "$RELAY" sh -c 'wc -c < /tmp/duplex-down' 2>/dev/null | tr -d ' ')"
    tail="$(docker exec "$RELAY" sh -c 'tail -c 12 /tmp/duplex-down' 2>/dev/null | tr -d '\000')"
    if [ "$got" != 8388659 ] || [ "$tail" != DONE-UPLOAD ]; then
        echo "    received ${got:-0} bytes (want 8388659) ending '${tail}' (want DONE-UPLOAD)"; return 1
    fi
    return 0
}

# ══ RES14 ═════════════════════════════════════════════════════════════════
# Requirement (RR8): the idle timeout also applies "to the wait for a
#   plain-HTTP upstream's answer".
# Theory: the upstream answers 5 seconds after the request. With 2 the
#   relay stops waiting and the client gets no answer; with 8 the answer
#   arrives (positive control). In the 2-second case the relay must also
#   have let the request through (no DENY line for slow.test) and given up
#   after 2 to 5 seconds, so a relay that refused or dropped the request
#   for another reason cannot pass.
# Rule 10: judges what the client receives through the live relay, its
#   timing and the relay's deny log.
# LLM summary: slow plain-HTTP answer -> dropped after 2-5 s at 2 (no DENY),
#   delivered at 8.
res14() {
    local ok=0 out t0 ms
    idle_relay pidle2 ', "idle_timeout_seconds": 2' || return 1
    t0=$(date +%s%N)
    out="$(docker exec -e "http_proxy=http://127.0.0.1:3128" "$RELAY" wget -q -T 15 -O - "http://slow.test:8080/" 2>&1)"
    ms=$(( ($(date +%s%N) - t0) / 1000000 ))
    case "$out" in *slow-answer*) echo "    2: the answer after 5 s arrived"; ok=1 ;; esac
    if grep -F " DENY " "$RLOG" 2>/dev/null | grep -F >/dev/null " host=slow.test "; then
        echo "    2: the relay denied the request instead of waiting"; ok=1
    fi
    if [ "$ms" -lt 2000 ] || [ "$ms" -ge 5000 ]; then
        echo "    2: the relay gave up after ${ms} ms, expected at least 2000 and under 5000"; ok=1
    fi
    idle_relay pidle8 ', "idle_timeout_seconds": 8' || return 1
    out="$(docker exec -e "http_proxy=http://127.0.0.1:3128" "$RELAY" wget -q -T 15 -O - "http://slow.test:8080/" 2>&1)"
    case "$out" in *slow-answer*) ;; *) echo "    8: no answer (got: $out)"; ok=1 ;; esac
    return $ok
}

# ══ RES15 ═════════════════════════════════════════════════════════════════
# Requirement (RR8): "The relay itself accepts 1 to 3600 ... and refuses to
#   start on any other value (fail closed)."
# Theory: a relay that ignores a malformed value runs with a timeout
#   nobody chose; it must exit instead. The same harness starts the
#   controls 1, 2 and 3600, which must keep running and listen, so a
#   harness fault cannot pass as a refusal, and the accepted edges are
#   pinned (null and -1 must not fall back to the default).
# Rule 10: judges whether the relay container keeps running and listens.
# LLM summary: 0, 3601, "300", true, 2.5, null, -1 -> exits; 1, 2, 3600 ->
#   listens.
relay_start_state() { # <tag> <policy tail>: sets STATE to exited|listening|neither
    local dir="$WORKROOT/$1" name="llm-relay-res-$$-$1" _
    mkdir -p "$dir/log"
    printf '{"mode": "enforce", "allow": ["*.test"], "block": []%s}\n' "$2" > "$dir/policy.json"
    CONTAINERS+=("$name")
    STATE=neither
    docker run -d --name "$name" --network none --user "$(id -u):$(id -g)" \
        -e LLMBOX_POLICY=/policy.json -e LLMBOX_DENY_LOG=/log/deny.log \
        -v "$dir/policy.json:/policy.json:ro" -v "$dir/log:/log" "$RELAY_IMAGE" >/dev/null \
        || { echo "    $1: docker run failed"; return 1; }
    for _ in $(seq 1 25); do
        if [ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" = false ]; then
            STATE=exited; return 0
        fi
        if docker exec "$name" nc -z 127.0.0.1 3128 2>/dev/null; then
            STATE=listening; return 0
        fi
        sleep 0.2
    done
    return 0
}
res15() {
    local ok=0 v i=0
    for v in 0 3601 '"300"' true 2.5 null -1; do
        i=$((i + 1))
        relay_start_state "bad$i" ", \"idle_timeout_seconds\": $v" || { ok=1; continue; }
        [ "$STATE" = exited ] || { echo "    idle_timeout_seconds $v: the relay did not exit ($STATE)"; ok=1; }
    done
    for v in 1 2 3600; do
        i=$((i + 1))
        relay_start_state "good$i" ", \"idle_timeout_seconds\": $v" || { ok=1; continue; }
        [ "$STATE" = listening ] || { echo "    idle_timeout_seconds $v: the relay is not listening ($STATE)"; ok=1; }
    done
    return $ok
}

# ══ RES19 ═════════════════════════════════════════════════════════════════
# Requirement (RR10): "At most 64 concurrent client connections; each
#   holds its slot from accept to close (a tunnel for its whole life).
#   Past the cap the relay answers 503 Service Unavailable immediately,
#   logs DENY <source> host=- reason=too-many-connections, and closes the
#   connection. A freed slot is available to the next connection."
# Theory: 10 holders are established tunnels (CONNECT to the echo
#   upstream with a ClientHello, then silent) and the rest are connections
#   that never send a request; both kinds must keep their slots. With 63
#   holders a request still gets its normal verdict (an IP-literal
#   CONNECT: 403 ip-literal), so the cap is not below 64. With a 64th
#   holder the next connection must get 503 within 2 seconds and a
#   too-many-connections line, so the cap is not above 64 and a tunnel is
#   not released when it starts copying. After one holder is closed by
#   its client and the relay has closed its side, the next request gets
#   its normal verdict again. A relay whose cap does nothing serves the
#   65th connection normally. Before each probe the check waits for the
#   relay side to show the expected connections, so a holder still being
#   connected cannot make a probe pass or fail by accident.
#   The silent holders keep their slots only until the request read
#   timeout (RR12; 30 seconds by default, RES25); the check needs about 5
#   seconds, so it finishes well inside that.
# Rule 10: judges the live relay's status lines, timing and deny log.
# LLM summary: 10 tunnels + 53 silent holders -> served; one more -> 503
#   too-many-connections in < 2 s; one closed -> served.
res19() {
    local ok=0 t0 ms _ n
    relay_conns() { # established or closing connections on the relay's side
        docker exec "$RELAY" sh -c 'netstat -tn 2>/dev/null | awk "\$4 ~ /:3128\$/ && (\$6 == \"ESTABLISHED\" || \$6 == \"CLOSE_WAIT\")" | wc -l'
    }
    hold() { # <count>: open that many silent connections, detached
        docker exec -d "$RELAY" sh -c 'i=0; while [ $i -lt "$1" ]; do i=$((i + 1)); sleep 120 | nc 127.0.0.1 3128 >/dev/null 2>&1 & done; wait' _ "$1"
    }
    held() { # <count>: wait until the relay side has that many connections, then 1 s more
        for _ in $(seq 1 50); do
            n="$(relay_conns)"
            [ "$n" -ge "$1" ] && { sleep 1; return 0; }
            sleep 0.2
        done
        echo "    only $n of $1 holder connections established"; return 1
    }
    printf '%s\n' "{ printf 'CONNECT echo.test:8443 HTTP/1.1\r\n\r\n'; sleep 0.5; printf '$HELLO'; sleep 120; } | nc 127.0.0.1 3128 >/dev/null 2>&1" \
        > "$WORKROOT/tunnel-holder.sh"
    docker exec -i "$RELAY" sh -c 'cat > /tmp/tunnel-holder.sh' < "$WORKROOT/tunnel-holder.sh"
    docker exec -d "$RELAY" sh -c 'i=0; while [ $i -lt 10 ]; do i=$((i + 1)); sh /tmp/tunnel-holder.sh & done; wait'
    local tunnels=0
    for _ in $(seq 1 50); do
        tunnels="$(grep -c ' ALLOW .* host=echo.test:8443 ' "$RLOG" 2>/dev/null)"
        [ "${tunnels:-0}" -ge 10 ] && break
        sleep 0.2
    done
    [ "${tunnels:-0}" -eq 10 ] \
        || { echo "    precondition: 10 tunnels were not established"; ok=1; }
    hold 53
    held 63 || ok=1
    raw_req "CONNECT 1.1.1.1:443 HTTP/1.1"
    [ "$STATUS" = "HTTP/1.1 403 Forbidden" ] || { echo "    63 held: status '$STATUS', expected 403 (the cap is below 64)"; ok=1; }
    hold 1
    held 64 || ok=1
    t0=$(date +%s%N)
    raw_req "CONNECT 1.1.1.1:443 HTTP/1.1"
    ms=$(( ($(date +%s%N) - t0) / 1000000 ))
    [ "$STATUS" = "HTTP/1.1 503 Service Unavailable" ] || { echo "    64 held: status '$STATUS', expected 503 Service Unavailable (holders running: $(docker exec "$RELAY" sh -c 'pidof nc | wc -w'))"; ok=1; }
    [ "$ms" -lt 2000 ] || { echo "    64 held: the answer took ${ms} ms, expected under 2000"; ok=1; }
    grep -qE ' DENY [^ ]+ host=- reason=too-many-connections$' "$RLOG" 2>/dev/null \
        || { echo "    64 held: no too-many-connections line"; ok=1; }
    docker exec "$RELAY" sh -c 'kill $(pidof nc | cut -d" " -f1)'
    for _ in $(seq 1 50); do
        n="$(relay_conns)"
        [ "$n" -le 63 ] && break
        sleep 0.2
    done
    sleep 1
    raw_req "CONNECT 1.1.1.1:443 HTTP/1.1"
    [ "$STATUS" = "HTTP/1.1 403 Forbidden" ] || { echo "    one holder closed: status '$STATUS', expected 403 (the slot was not freed)"; ok=1; }
    docker exec "$RELAY" sh -c 'pkill nc; pkill sleep' >/dev/null 2>&1
    return $ok
}

# ══ RES21-RES27: the request read timeout (RR12) and the bytes after the ═══
# request head (RR13). The relays with a short limit get
# LLMBOX_REQUEST_TIMEOUT through RELAY_EXTRA; everything else is the
# harness of RES13-RES20.

# req_relay <tag> <limit> <policy tail>: idle_relay with a request limit.
req_relay() {
    RELAY_EXTRA=(-e "LLMBOX_REQUEST_TIMEOUT=$2")
    idle_relay "$1" "$3"
    local rc=$?
    RELAY_EXTRA=()
    return $rc
}

# client_conns: established or closing connections on the relay's side of
# port 3128 (a connection the relay has closed no longer counts).
client_conns() {
    docker exec "$RELAY" sh -c 'netstat -tn 2>/dev/null | awk "\$4 ~ /:3128\$/ && (\$6 == \"ESTABLISHED\" || \$6 == \"CLOSE_WAIT\")" | wc -l'
}

# The client side of the timing checks, run inside a relay container: it
# sends the printf escapes in $1, keeps its end open for $2 seconds, and
# writes to $3 the first line the relay answers (carriage return removed),
# "|", and the milliseconds from connecting to that line (from
# /proc/uptime, because BusyBox date has no sub-second field). BusyBox nc
# does not end when the relay closes while its input is still open, so a
# closed connection is judged on the relay's side (client_conns), and
# `timeout` bounds a relay that never answers.
TIMED_CLIENT='read u _ < /proc/uptime; t0=${u%.*}${u#*.}
{ printf "$1"; sleep "$2"; } | timeout 50 nc 127.0.0.1 3128 | {
    IFS= read -r l; read u _ < /proc/uptime
    echo "$(printf %s "$l" | tr -d "\r")|$(( (${u%.*}${u#*.} - t0) * 10 ))" > "$3"
}'

# ══ RES21 ═════════════════════════════════════════════════════════════════
# Requirement (RR12): "A client has request_timeout seconds from the moment
#   the relay accepts its connection to send a complete request head ... On
#   expiry the relay answers 408 Request Timeout, logs DENY <source> host=-
#   reason=request-timeout, closes the connection and frees its slot."
# Theory: three clients connect at the same time to a relay with a limit of
#   2 and keep their ends open for 12 seconds: one sends nothing, one sends
#   a CONNECT line with no empty line after it, one a plain-HTTP request
#   line with no empty line after it. Each must get 408 between 2 and 5
#   seconds after connecting, and the relay must have closed all three by
#   6 seconds in (its side holds no connection), while 1 second in it still
#   held all three (the positive control that they were connected and
#   waiting). The log must have exactly three request-timeout lines with
#   host=-. A relay without the limit never answers and keeps all three
#   connections for the full 12 seconds.
# Rule 10: judges the live relay's answers, their timing, its sockets and
#   its deny log.
# LLM summary: limit 2; silent, partial CONNECT, partial GET -> 408 after
#   2-5 s each, all closed by 6 s, three `host=- reason=request-timeout`.
res21() {
    local ok=0 n label line status ms
    req_relay reqto2 2 "" || return 1
    printf '%s\n' "$TIMED_CLIENT" > "$WORKROOT/timed-client.sh"
    docker exec -i "$RELAY" sh -c 'cat > /tmp/timed-client.sh' < "$WORKROOT/timed-client.sh"
    # All three start from one exec, so they connect within milliseconds of
    # each other and the 1-second precondition stays inside the 2-second
    # limit even when each docker exec is slow.
    docker exec -d "$RELAY" sh -c '
        sh /tmp/timed-client.sh "" 12 /tmp/res21-silent &
        sh /tmp/timed-client.sh "CONNECT echo.test:8443 HTTP/1.1\r\n" 12 /tmp/res21-connect &
        sh /tmp/timed-client.sh "GET http://slow.test:8080/ HTTP/1.1\r\n" 12 /tmp/res21-plain &
        wait'
    sleep 1
    n="$(client_conns)"
    [ "$n" = 3 ] || { echo "    1 s in the relay holds $n client connections, expected 3 (precondition)"; ok=1; }
    sleep 5
    n="$(client_conns)"
    [ "$n" = 0 ] || { echo "    6 s in the relay still holds $n client connection(s)"; ok=1; }
    for label in silent connect plain; do
        line="$(docker exec "$RELAY" cat "/tmp/res21-$label" 2>/dev/null)"
        status="${line%|*}"; ms="${line##*|}"
        if [ "$status" != "HTTP/1.1 408 Request Timeout" ]; then
            echo "    $label: answer '${status}', expected HTTP/1.1 408 Request Timeout"; ok=1
        elif [ "$ms" -lt 2000 ] || [ "$ms" -ge 5000 ]; then
            echo "    $label: the 408 came after ${ms} ms, expected 2000 to 4999"; ok=1
        fi
    done
    n="$(grep -cE ' DENY [^ ]+ host=- reason=request-timeout$' "$RLOG" 2>/dev/null)"
    [ "${n:-0}" = 3 ] || { echo "    ${n:-0} request-timeout lines, expected 3"; ok=1; }
    docker exec "$RELAY" sh -c 'pkill nc; pkill sleep' >/dev/null 2>&1
    return $ok
}

# ══ RES22 ═════════════════════════════════════════════════════════════════
# Requirement (RR12): "... closes the connection and frees its slot", so
#   connections that never send a request cannot hold the 64 slots (RR10)
#   for longer than the limit.
# Theory: with a limit of 6, 64 connections that never send anything fill
#   the cap: a 65th gets 503 too-many-connections (the precondition that
#   the cap really was full). Once the relay has timed them out, its side
#   holds no client connection, the next request gets its normal verdict
#   (an IP-literal CONNECT: 403), and the log has one request-timeout line
#   for each of the 64. A relay without the limit keeps answering 503.
# Rule 10: judges the live relay's answers, its sockets and its deny log.
# LLM summary: 64 silent -> 503; after the limit -> none held, 403, 64
#   request-timeout lines.
res22() {
    local ok=0 n _
    req_relay reqcap6 6 "" || return 1
    docker exec -d "$RELAY" sh -c 'i=0; while [ $i -lt 64 ]; do i=$((i + 1)); sleep 60 | nc 127.0.0.1 3128 >/dev/null 2>&1 & done; wait'
    for _ in $(seq 1 25); do
        n="$(client_conns)"
        [ "$n" -ge 64 ] && break
        sleep 0.2
    done
    [ "$n" -ge 64 ] || { echo "    only $n of 64 silent connections established (precondition)"; ok=1; }
    raw_req "CONNECT 1.1.1.1:443 HTTP/1.1"
    [ "$STATUS" = "HTTP/1.1 503 Service Unavailable" ] \
        || { echo "    64 silent: status '$STATUS', expected 503 (precondition: the cap was full)"; ok=1; }
    for _ in $(seq 1 60); do
        n="$(client_conns)"
        [ "$n" = 0 ] && break
        sleep 0.25
    done
    [ "$n" = 0 ] || { echo "    after the limit the relay still holds $n client connection(s)"; ok=1; }
    raw_req "CONNECT 1.1.1.1:443 HTTP/1.1"
    [ "$STATUS" = "HTTP/1.1 403 Forbidden" ] \
        || { echo "    after the limit: status '$STATUS', expected 403 (the slots were not freed)"; ok=1; }
    n="$(grep -cE ' DENY [^ ]+ host=- reason=request-timeout$' "$RLOG" 2>/dev/null)"
    [ "${n:-0}" = 64 ] || { echo "    ${n:-0} request-timeout lines, expected 64"; ok=1; }
    docker exec "$RELAY" sh -c 'pkill nc; pkill sleep' >/dev/null 2>&1
    return $ok
}

# ══ RES23 ═════════════════════════════════════════════════════════════════
# Requirement (RR12): "A client that finishes its head within the limit,
#   however slowly, is served as before. The limit ends when the head is
#   read: it does not cover ... the SNI wait, the tunnel or the plain-HTTP
#   exchange."
# Theory: with a limit of 3 and an idle timeout of 8, a CONNECT head sent
#   in three pieces 0.8 seconds apart must be served (tunnel, echoed
#   ClientHello, ALLOW line), with the ClientHello sent 3.5 seconds after
#   the head, about 5 seconds after connecting: past the limit but inside
#   the SNI wait, so a limit that also covered the SNI wait would refuse
#   it. The tunnel then stays silent for 5 seconds,
#   longer than the limit, and a line sent after that must still come
#   back: a limit that kept running after the head would have closed it.
#   A plain-HTTP head sent the same way to the upstream that answers after
#   5 seconds must get that answer, so the limit does not cover the wait
#   for the upstream either. No request-timeout line may appear. The relay
#   before RR12 passes too; this pins that the limit is not too eager.
# Rule 10: judges what comes back through the live relay and its log.
# LLM summary: limit 3; dribbled CONNECT head, ClientHello 3.5 s later ->
#   tunnel works and survives 5 s idle; dribbled GET head -> answer after 5 s; no request-timeout.
res23() {
    local ok=0 out
    req_relay reqslow3 3 ', "idle_timeout_seconds": 8' || return 1
    out="$(docker exec "$RELAY" sh -c '{ printf "CONNECT echo."; sleep 0.8; printf "test:8443 HTTP/1.1\r\n"; sleep 0.8; printf "\r\n"; sleep 3.5; printf "$1"; sleep 5; printf "LINE-AFTER-LIMIT\n"; sleep 1; } | timeout 20 nc 127.0.0.1 3128' _ "$HELLO" 2>&1 | tr -d '\000')"
    case "$out" in
        *"200 Connection established"*"echo.test"*) ;;
        *) echo "    the slowly sent CONNECT head was not served (got: $(printf %s "$out" | head -c 80))"; ok=1 ;;
    esac
    grep -q " ALLOW .* host=echo.test:8443 sni=echo.test" "$RLOG" \
        || { echo "    no ALLOW line for the tunnel"; ok=1; }
    case "$out" in
        *LINE-AFTER-LIMIT*) ;;
        *) echo "    the line after 5 s of silence did not come back (the limit ran on after the head)"; ok=1 ;;
    esac
    out="$(docker exec "$RELAY" sh -c '{ printf "GET http://slow.test:8080/ HTTP/1.1\r\n"; sleep 0.8; printf "Host: slow.test:8080\r\n"; sleep 0.8; printf "\r\n"; sleep 8; } | timeout 20 nc 127.0.0.1 3128' 2>&1)"
    case "$out" in
        *slow-answer*) ;;
        *) echo "    the slowly sent plain-HTTP head got no answer (got: $(printf %s "$out" | head -c 80))"; ok=1 ;;
    esac
    if grep -q "reason=request-timeout" "$RLOG" 2>/dev/null; then
        echo "    a request-timeout line was logged for a complete head"; ok=1
    fi
    return $ok
}

# ══ RES24 ═════════════════════════════════════════════════════════════════
# Requirement (RR12): "the relay reads an optional LLMBOX_REQUEST_TIMEOUT
#   (whole seconds, 1 to 3600) from its environment ... and refuses to
#   start on any other value (fail closed)."
# Theory: a relay that ignores a malformed limit runs with one nobody
#   chose; it must exit instead. The same harness starts the controls 1
#   and 3600, which must keep running and listen, so a harness fault
#   cannot pass as a refusal and the accepted edges are pinned. Property
#   part, drawn from the printed seed: a whole number above 3600, a
#   negative number and a fraction inside the range are refused, and a
#   whole number from 2 to 3599 is accepted.
# Rule 10: judges whether the relay container keeps running and listens.
# LLM summary: 0, 3601, abc, 2.5, -1, empty, seeded >3600, negative,
#   fraction -> exits; 1, 3600, seeded 2-3599 -> listens.
relay_env_state() { # <tag> <value>: sets STATE to exited|listening|neither
    local dir="$WORKROOT/$1" name="llm-relay-res-$$-$1" _
    mkdir -p "$dir/log"
    printf '{"mode": "enforce", "allow": ["*.test"], "block": []}\n' > "$dir/policy.json"
    CONTAINERS+=("$name")
    STATE=neither
    docker run -d --name "$name" --network none --user "$(id -u):$(id -g)" \
        -e LLMBOX_POLICY=/policy.json -e LLMBOX_DENY_LOG=/log/deny.log \
        -e "LLMBOX_REQUEST_TIMEOUT=$2" \
        -v "$dir/policy.json:/policy.json:ro" -v "$dir/log:/log" "$RELAY_IMAGE" >/dev/null \
        || { echo "    $1: docker run failed"; return 1; }
    for _ in $(seq 1 25); do
        if [ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" = false ]; then
            STATE=exited; return 0
        fi
        if docker exec "$name" nc -z 127.0.0.1 3128 2>/dev/null; then
            STATE=listening; return 0
        fi
        sleep 0.2
    done
    return 0
}
res24() {
    local ok=0 v i=0
    local big=$((3601 + RANDOM * 3)) neg="-$((RANDOM % 3600 + 1))"
    local frac="$((RANDOM % 3599 + 1)).$((RANDOM % 9 + 1))" good=$((RANDOM % 3598 + 2))
    for v in 0 3601 abc 2.5 -1 "" "$big" "$neg" "$frac"; do
        i=$((i + 1))
        relay_env_state "rtbad$i" "$v" || { ok=1; continue; }
        [ "$STATE" = exited ] || { echo "    LLMBOX_REQUEST_TIMEOUT '$v': the relay did not exit ($STATE)"; ok=1; }
    done
    for v in 1 3600 "$good"; do
        i=$((i + 1))
        relay_env_state "rtgood$i" "$v" || { ok=1; continue; }
        [ "$STATE" = listening ] || { echo "    LLMBOX_REQUEST_TIMEOUT '$v': the relay is not listening ($STATE)"; ok=1; }
    done
    return $ok
}

# ══ RES25 ═════════════════════════════════════════════════════════════════
# Requirement (RR12): "Default 30 seconds".
# Theory: a relay started without LLMBOX_REQUEST_TIMEOUT must answer a
#   connection that sends nothing with 408 about 30 seconds after it
#   connected: not before 29 seconds (the limit is not shorter, which the
#   silent holders of RES19 also need) and not after 40 (it exists and is
#   not much longer). res25_start starts that client at the beginning of
#   the suite, detached, and res25 judges it at the end, so the suite does
#   not wait 30 seconds for it; res25 waits only if the suite was faster.
# Rule 10: judges the live relay's answer and its timing.
# LLM summary: default relay, silent client -> 408 after 29-40 s.
res25_start() {
    RELAY_EXTRA=()
    start_relay reqdef || return 1
    RES25_RELAY="$RELAY"
    RES25_LOG="$RLOG"
    printf '%s\n' "$TIMED_CLIENT" > "$WORKROOT/timed-client.sh"
    docker exec -i "$RELAY" sh -c 'cat > /tmp/timed-client.sh' < "$WORKROOT/timed-client.sh"
    docker exec -d "$RELAY" sh /tmp/timed-client.sh "" 45 /tmp/res25
}
res25() {
    local line status ms _
    [ -n "${RES25_RELAY:-}" ] || { echo "    the default relay did not start"; return 1; }
    for _ in $(seq 1 60); do
        line="$(docker exec "$RES25_RELAY" cat /tmp/res25 2>/dev/null)"
        [ -n "$line" ] && break
        sleep 1
    done
    status="${line%|*}"; ms="${line##*|}"
    if [ "$status" != "HTTP/1.1 408 Request Timeout" ]; then
        echo "    answer '${status}' after ${ms:-?} ms, expected HTTP/1.1 408 Request Timeout"; return 1
    fi
    if [ "$ms" -lt 29000 ] || [ "$ms" -gt 40000 ]; then
        echo "    the 408 came after ${ms} ms, expected 29000 to 40000"; return 1
    fi
    grep -qE ' DENY [^ ]+ host=- reason=request-timeout$' "$RES25_LOG" \
        || { echo "    no request-timeout line"; return 1; }
    return 0
}

# ══ RES26 ═════════════════════════════════════════════════════════════════
# Requirement (RR13): "Bytes the relay has already read past the end of a
#   CONNECT request head (a TLS ClientHello sent in the same packet ...
#   and anything after it) are sent upstream first, in order, before
#   anything else the client sends."
# Theory: through the echo upstream, the client gets back exactly what the
#   upstream received. Case one: a single write carries the CONNECT head,
#   the ClientHello and 2000 more bytes ending in END-FIRST, and a line
#   SECOND follows a second later; what comes back must be, byte for byte,
#   the 200 line, the ClientHello, the 2000 bytes, END-FIRST and SECOND. A
#   relay that drops the bytes read with the head returns only SECOND, and
#   one that sends them after later bytes returns them out of order. Case
#   two: the CONNECT head and the first 20 bytes of the ClientHello share
#   one write, the other 50 bytes follow half a second later (the relay
#   waits for them for the SNI check) and then AFTER-SPLIT: the full
#   ClientHello must come back, then AFTER-SPLIT. Both comparisons are
#   exact (cmp), with the expected bytes built from the same pieces.
# Rule 10: judges the bytes the client receives through the live relay.
# LLM summary: CONNECT+ClientHello+2000 bytes in one write, then a line ->
#   echoed exactly and in order; head+20 bytes, then 50 -> full
#   ClientHello echoed.
res26() {
    local ok=0 r
    idle_relay headbytes ', "idle_timeout_seconds": 8' || return 1
    r="$(docker exec "$RELAY" sh -c '
        printf "$1" > /tmp/hello
        head -c 2000 /dev/zero | tr "\000" P > /tmp/payload
        { printf "CONNECT echo.test:8443 HTTP/1.1\r\n\r\n"; cat /tmp/hello /tmp/payload; printf "END-FIRST\n"; } > /tmp/one-write
        { printf "HTTP/1.1 200 Connection established\r\n\r\n"; cat /tmp/hello /tmp/payload; printf "END-FIRST\nSECOND\n"; } > /tmp/want-one
        { cat /tmp/one-write; sleep 1; printf "SECOND\n"; sleep 1; } | timeout 15 nc 127.0.0.1 3128 > /tmp/got-one
        if cmp -s /tmp/want-one /tmp/got-one; then echo one-ok; else echo "one-bad $(wc -c < /tmp/got-one) of $(wc -c < /tmp/want-one) bytes"; fi
        { printf "CONNECT echo.test:8443 HTTP/1.1\r\n\r\n"; head -c 20 /tmp/hello; } > /tmp/split-first
        { printf "HTTP/1.1 200 Connection established\r\n\r\n"; cat /tmp/hello; printf "AFTER-SPLIT\n"; } > /tmp/want-split
        { cat /tmp/split-first; sleep 0.5; tail -c +21 /tmp/hello; sleep 0.5; printf "AFTER-SPLIT\n"; sleep 1; } | timeout 15 nc 127.0.0.1 3128 > /tmp/got-split
        if cmp -s /tmp/want-split /tmp/got-split; then echo split-ok; else echo "split-bad $(wc -c < /tmp/got-split) of $(wc -c < /tmp/want-split) bytes"; fi
    ' _ "$HELLO" 2>&1)"
    case "$r" in *one-ok*) ;; *) echo "    one write: ${r%%$'\n'*} came back (want the head's bytes, then SECOND, exactly)"; ok=1 ;; esac
    case "$r" in *split-ok*) ;; *) echo "    split ClientHello: $(printf '%s\n' "$r" | grep split-) came back (want the whole ClientHello, then AFTER-SPLIT)"; ok=1 ;; esac
    return $ok
}

# ══ RES27 ═════════════════════════════════════════════════════════════════
# Requirement (RR13): "Plain HTTP: a request with a Content-Length body has
#   its body forwarded after the request head, the bytes read with the
#   head first, then the rest from the client, exactly Content-Length
#   bytes ... Bytes past the body (a pipelined next request) are not
#   forwarded, as before."
# Theory: the upstream on 8081 reads the head, then exactly Content-Length
#   bytes one at a time, then whatever else arrives within one second, and
#   answers "body=<body> extra=<the rest>|". Case one: a 16-byte body whose
#   first 8 bytes (PART-ONE) share the head's write and whose last 8
#   (PART-TWO) arrive a second later followed, in the same write, by 11
#   bytes past the body: the answer must be body=PART-ONEPART-TWO with
#   nothing extra. Case two: an 8-byte body sent whole with the head and 5
#   bytes past it: body=ALL-HERE, nothing extra. A relay that forwards no
#   body leaves the upstream waiting, so the client gets no answer; one
#   that forwards past the body shows the extra bytes.
# Rule 10: judges the answer the client receives through the live relay.
# LLM summary: POST bodies through plain HTTP arrive whole and in order;
#   bytes past Content-Length are not forwarded.
BODY_UPSTREAM='n=0
while IFS= read -r l; do
    l=$(printf %s "$l" | tr -d "\r")
    [ -z "$l" ] && break
    case "$l" in [Cc]ontent-[Ll]ength:*) n=$(printf %s "${l#*:}" | tr -d " ") ;; esac
done
body=$(dd bs=1 count="$n" 2>/dev/null)
extra=$(timeout 1 cat)
msg="body=$body extra=$extra|"
printf "HTTP/1.0 200 OK\r\nContent-Length: %d\r\n\r\n%s" "${#msg}" "$msg"'
body_upstream_setup() {
    printf '%s\n' "$BODY_UPSTREAM" > "$WORKROOT/body-upstream.sh"
    docker exec -i "$IDLE_NET-up" sh -c 'cat > /tmp/body-upstream.sh' < "$WORKROOT/body-upstream.sh" \
        && docker exec -d "$IDLE_NET-up" nc -lk -p 8081 -e sh /tmp/body-upstream.sh
}
res27() {
    local ok=0 out
    body_upstream_setup || { echo "    the body upstream did not start"; return 1; }
    idle_relay plainbody ', "idle_timeout_seconds": 6' || return 1
    printf '%s body.test\n' "$IDLE_UP" > "$WORKROOT/plainbody-extra.hosts"
    add_hosts "$WORKROOT/plainbody-extra.hosts"
    out="$(docker exec "$RELAY" sh -c '
        printf "POST http://body.test:8081/echo HTTP/1.1\r\nHost: body.test:8081\r\nContent-Length: 16\r\n\r\nPART-ONE" > /tmp/post-one
        { cat /tmp/post-one; sleep 1; printf "PART-TWOEXTRA-BYTES"; sleep 4; } | timeout 15 nc 127.0.0.1 3128' 2>&1)"
    case "$out" in
        *"body=PART-ONEPART-TWO extra=|"*) ;;
        *) echo "    split body: got '$(printf %s "$out" | tr -d '\r' | tail -n 1)', want body=PART-ONEPART-TWO extra=|"; ok=1 ;;
    esac
    out="$(docker exec "$RELAY" sh -c '
        printf "POST http://body.test:8081/echo HTTP/1.1\r\nHost: body.test:8081\r\nContent-Length: 8\r\n\r\nALL-HEREEXTRA" > /tmp/post-two
        { cat /tmp/post-two; sleep 3; } | timeout 15 nc 127.0.0.1 3128' 2>&1)"
    case "$out" in
        *"body=ALL-HERE extra=|"*) ;;
        *) echo "    whole body: got '$(printf %s "$out" | tr -d '\r' | tail -n 1)', want body=ALL-HERE extra=|"; ok=1 ;;
    esac
    return $ok
}

# ══ RES28 ═════════════════════════════════════════════════════════════════
# Requirement (RR12): "A client has request_timeout seconds from the moment
#   the relay accepts its connection to send a complete request head".
# Theory: one deadline covers the whole head. A client that sends one byte
#   of a CONNECT line every half second, never finishing it, must get 408
#   between 2 and 5 seconds after connecting with a limit of 2. A relay
#   that restarts the limit on every read (the classic slow-header
#   weakness) never times this client out while it keeps sending, so it
#   answers only after the client stops (12 seconds) or not at all.
# Rule 10: judges the live relay's answer and its timing.
# LLM summary: limit 2, one byte every 0.5 s -> 408 after 2-5 s.
res28() {
    local line status ms
    req_relay reqdrip2 2 "" || return 1
    printf '%s\n' 'read u _ < /proc/uptime; t0=${u%.*}${u#*.}
{ for c in C O N N E C T " " e c h o . t e s t : 8 4 4 3 " " H T T P; do printf "%s" "$c"; sleep 0.5; done; } | timeout 30 nc 127.0.0.1 3128 | {
    IFS= read -r l; read u _ < /proc/uptime
    echo "$(printf %s "$l" | tr -d "\r")|$(( (${u%.*}${u#*.} - t0) * 10 ))" > /tmp/res28
}' > "$WORKROOT/drip-client.sh"
    docker exec -i "$RELAY" sh -c 'cat > /tmp/drip-client.sh' < "$WORKROOT/drip-client.sh"
    docker exec "$RELAY" sh /tmp/drip-client.sh
    line="$(docker exec "$RELAY" cat /tmp/res28 2>/dev/null)"
    status="${line%|*}"; ms="${line##*|}"
    if [ "$status" != "HTTP/1.1 408 Request Timeout" ]; then
        echo "    answer '${status}' after ${ms:-?} ms, expected HTTP/1.1 408 Request Timeout"; return 1
    fi
    if [ "$ms" -lt 2000 ] || [ "$ms" -ge 5000 ]; then
        echo "    the 408 came after ${ms} ms, expected 2000 to 4999 (the limit restarted on each byte)"; return 1
    fi
    return 0
}

# ══ RES29 ═════════════════════════════════════════════════════════════════
# Requirement (RR13): "Bytes the relay has already read past the end of a
#   CONNECT request head (a TLS ClientHello sent in the same packet ...)
#   are sent upstream first, in order", together with the SNI check, which
#   reads the first TLS record whole (within its 5-second wait) before it
#   judges the server name.
# Theory: a ClientHello of 4074 bytes (a 4000-byte padding extension
#   before the server name, as large post-quantum greetings are) sent in
#   one write with the CONNECT head arrives at the relay in more than one
#   read. The relay must read the rest of the record, see echo.test, allow
#   the tunnel and forward every byte in order: the echo must return the
#   200 line, the whole ClientHello and a later line, byte for byte. The
#   same ClientHello sent as the head plus its first 100 bytes, then the
#   rest half a second later, must give the same result. A relay that
#   judges only the bytes of its first read refuses both as sni-mismatch.
# Rule 10: judges the bytes the client receives through the live relay
#   and its log.
# LLM summary: 4074-byte ClientHello with the head in one write, or split
#   after 100 bytes -> allowed and echoed exactly.
res29() {
    local ok=0 r
    idle_relay bighello ', "idle_timeout_seconds": 8' || return 1
    r="$(docker exec "$RELAY" sh -c '
        { printf "\026\003\001\017\345\001\000\017\341\003\003"; head -c 32 /dev/zero
          printf "\000\000\002\023\001\001\000\017\266\000\025\017\240"; head -c 4000 /dev/zero
          printf "\000\000\000\016\000\014\000\000\011echo.test"; } > /tmp/big-hello
        { printf "CONNECT echo.test:8443 HTTP/1.1\r\n\r\n"; cat /tmp/big-hello; } > /tmp/big-one
        { printf "HTTP/1.1 200 Connection established\r\n\r\n"; cat /tmp/big-hello; printf "AFTER-HELLO\n"; } > /tmp/big-want
        { cat /tmp/big-one; sleep 1; printf "AFTER-HELLO\n"; sleep 1; } | timeout 15 nc 127.0.0.1 3128 > /tmp/big-got-one
        if cmp -s /tmp/big-want /tmp/big-got-one; then echo one-ok; else echo "one-bad $(wc -c < /tmp/big-got-one) of $(wc -c < /tmp/big-want) bytes"; fi
        { printf "CONNECT echo.test:8443 HTTP/1.1\r\n\r\n"; head -c 100 /tmp/big-hello; } > /tmp/big-first
        { cat /tmp/big-first; sleep 0.5; tail -c +101 /tmp/big-hello; sleep 1; printf "AFTER-HELLO\n"; sleep 1; } | timeout 15 nc 127.0.0.1 3128 > /tmp/big-got-split
        if cmp -s /tmp/big-want /tmp/big-got-split; then echo split-ok; else echo "split-bad $(wc -c < /tmp/big-got-split) of $(wc -c < /tmp/big-want) bytes"; fi
        wc -c < /tmp/big-hello
    ' 2>&1)"
    case "$r" in *4074*) ;; *) echo "    precondition: the ClientHello is not 4074 bytes ($r)"; return 1 ;; esac
    case "$r" in *one-ok*) ;; *) echo "    one write: $(printf '%s\n' "$r" | grep one-) came back; deny log: $(grep -F 'host=echo.test' "$RLOG" | tail -n 1)"; ok=1 ;; esac
    case "$r" in *split-ok*) ;; *) echo "    split after 100 bytes: $(printf '%s\n' "$r" | grep split-) came back"; ok=1 ;; esac
    [ "$(grep -c ' ALLOW .* host=echo.test:8443 sni=echo.test' "$RLOG" 2>/dev/null)" = 2 ] \
        || { echo "    expected 2 ALLOW lines for echo.test"; ok=1; }
    return $ok
}

# ══ RES30 ═════════════════════════════════════════════════════════════════
# Requirement (RR13 with RR7): the body is forwarded, and an upstream that
#   answers before it has the whole body still has its answer relayed, as
#   before RR13 (when no body was sent at all).
# Theory: the upstream on 8082 reads the request head, answers 413 at once
#   and closes without reading the body. The client sends a 32 MiB body,
#   more than the socket buffers between the relay and the upstream hold,
#   so a relay that sends the whole body first must block and then fail. The client must still get the 413 status line. A relay that
#   pushes the whole body before reading anything fails its send on the
#   closed connection and drops the answer.
# Rule 10: judges the answer the client receives through the live relay.
# LLM summary: early 413 from the upstream during a 32 MiB body ->
#   the client gets the 413.
EARLY_UPSTREAM='while IFS= read -r l; do
    l=$(printf %s "$l" | tr -d "\r")
    [ -z "$l" ] && break
done
printf "HTTP/1.0 413 Payload Too Large\r\nContent-Length: 0\r\n\r\n"'
res30() {
    local status
    printf '%s\n' "$EARLY_UPSTREAM" > "$WORKROOT/early-upstream.sh"
    docker exec -i "$IDLE_NET-up" sh -c 'cat > /tmp/early-upstream.sh' < "$WORKROOT/early-upstream.sh" \
        && docker exec -d "$IDLE_NET-up" nc -lk -p 8082 -e sh /tmp/early-upstream.sh \
        || { echo "    the early-answer upstream did not start"; return 1; }
    idle_relay early ', "idle_timeout_seconds": 6' || return 1
    printf '%s early.test\n' "$IDLE_UP" > "$WORKROOT/early-extra.hosts"
    add_hosts "$WORKROOT/early-extra.hosts"
    status="$(docker exec "$RELAY" sh -c '
        { printf "POST http://early.test:8082/up HTTP/1.1\r\nHost: early.test:8082\r\nContent-Length: 33554432\r\n\r\n"; head -c 33554432 /dev/zero; sleep 2; } | timeout 15 nc 127.0.0.1 3128 | head -n 1' 2>&1 | tr -d '\r')"
    [ "$status" = "HTTP/1.0 413 Payload Too Large" ] && return 0
    echo "    status '$status', expected HTTP/1.0 413 Payload Too Large"
    return 1
}

# ══ RES31 ═════════════════════════════════════════════════════════════════
# Requirement (RR13 with RR7): "An upstream that answers before it has the
#   whole body (401, 413) still has its answer relayed: sending stops when
#   the upstream has something to say".
# Theory: the upstream on 8083 reads the request head, answers 401 at once
#   and then neither reads nor closes for 20 seconds. Case one: the client
#   sends a head with Content-Length 10 and no body yet, as a client using
#   `Expect: 100-continue` does. Case two: the client sends a 32 MiB body,
#   which the upstream never reads. In both the 401 must reach the client
#   within 3 seconds, far below the idle timeout of 8. A relay that looks
#   at the upstream only between sends waits on the client (case one) or
#   in a blocked send (case two) until the idle timeout; RES30 cannot see
#   this, because its upstream closes and the failed send ends the body.
# Rule 10: judges the answer the client receives and when.
# LLM summary: early 401 while the relay waits for the body, or while the
#   upstream stops reading -> the client gets it within 3 s.
HOLD_UPSTREAM='while IFS= read -r l; do
    l=$(printf %s "$l" | tr -d "\r")
    [ -z "$l" ] && break
done
printf "HTTP/1.0 401 Unauthorized\r\nContent-Length: 0\r\n\r\n"
sleep 20'
res31() {
    local ok=0 line status ms label
    printf '%s\n' "$HOLD_UPSTREAM" > "$WORKROOT/hold-upstream.sh"
    docker exec -i "$IDLE_NET-up" sh -c 'cat > /tmp/hold-upstream.sh' < "$WORKROOT/hold-upstream.sh" \
        && docker exec -d "$IDLE_NET-up" nc -lk -p 8083 -e sh /tmp/hold-upstream.sh \
        || { echo "    the holding upstream did not start"; return 1; }
    idle_relay earlyhold ', "idle_timeout_seconds": 8' || return 1
    printf '%s hold.test\n' "$IDLE_UP" > "$WORKROOT/earlyhold-extra.hosts"
    add_hosts "$WORKROOT/earlyhold-extra.hosts"
    printf '%s\n' 'read u _ < /proc/uptime; t0=${u%.*}${u#*.}
{ printf "POST http://hold.test:8083/x HTTP/1.1\r\nHost: hold.test:8083\r\nContent-Length: $2\r\nExpect: 100-continue\r\n\r\n"; [ "$3" = send ] && head -c "$2" /dev/zero; sleep 12; } | timeout 20 nc 127.0.0.1 3128 | {
    IFS= read -r l; read u _ < /proc/uptime
    echo "$(printf %s "$l" | tr -d "\r")|$(( (${u%.*}${u#*.} - t0) * 10 ))" > "$1"
}' > "$WORKROOT/hold-client.sh"
    docker exec -i "$RELAY" sh -c 'cat > /tmp/hold-client.sh' < "$WORKROOT/hold-client.sh"
    docker exec "$RELAY" sh -c 'sh /tmp/hold-client.sh /tmp/res31-wait 10 wait & sh /tmp/hold-client.sh /tmp/res31-big 33554432 send & wait'
    for label in wait big; do
        line="$(docker exec "$RELAY" cat "/tmp/res31-$label" 2>/dev/null)"
        status="${line%|*}"; ms="${line##*|}"
        if [ "$status" != "HTTP/1.0 401 Unauthorized" ]; then
            echo "    $label: answer '${status}' after ${ms:-?} ms, expected HTTP/1.0 401 Unauthorized"; ok=1
        elif [ "$ms" -ge 3000 ]; then
            echo "    $label: the 401 came after ${ms} ms, expected under 3000 (the relay did not see the early answer)"; ok=1
        fi
    done
    return $ok
}

# ══ RES11 ═════════════════════════════════════════════════════════════════
# Requirement (RR1): every reason is one token, so a
#   deny log line splits on spaces into fixed fields.
# Theory: after the checks above, the deny logs hold lookup failures,
#   refused addresses, connect failures and policy refusals. Every DENY
#   line must be `<time> DENY <source> host=<host> reason=<token>`
#   optionally followed by ` addr=<address>` or ` sni=<name>`, with no
#   other spaces. The positive precondition is that at least one
#   connect-failed line and a deny line for the lookup-failure name are
#   present to judge.
# Rule 10: judges the deny logs the relays wrote at run time.
# LLM summary: all DENY lines match the one-token grammar.
res11() {
    local all="$WORKROOT/all-deny.log" bad
    cat "$WORKROOT"/*/log/deny.log > "$all" 2>/dev/null
    grep -q ' reason=connect-failed' "$all" || { echo "    no connect-failed line to judge"; return 1; }
    grep -q ' host=nowhere.test reason=' "$all" || { echo "    no lookup-failure line to judge"; return 1; }
    bad="$(grep ' DENY ' "$all" | grep -Ev '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z DENY [^ ]+ host=[^ ]* reason=[^ ]+( addr=[^ ]+| sni=[^ ]+)?$' | head -n 3)"
    [ -z "$bad" ] && return 0
    printf '    not one token: %s\n' "$bad"
    return 1
}

# ── Run ───────────────────────────────────────────────────────────────────
# RES25 is started first and judged at the end (see res25_start).
res25_start || RES25_RELAY=""

if start_relay lookup; then
    check "RES1 lookup failure answers 503 with resolve-failed:EAI_AGAIN, not resolves-to-private" res1
    check "RES2 a failed lookup is tried once (verdict within one resolver timeout)" res2
else
    check "RES1 lookup failure answers 503 with resolve-failed:EAI_AGAIN, not resolves-to-private" false
    check "RES2 a failed lookup is tried once (verdict within one resolver timeout)" false
fi

HOSTS="$WORKROOT/fixed.hosts"
cat > "$HOSTS" <<'EOF'
10.0.0.1 private.test
100.64.0.0 shared-first.test
100.100.100.100 shared-magicdns.test
100.127.255.255 shared-last.test
100.63.255.255 shared-below.test
100.128.0.0 shared-above.test
fec0:: site-first.test
fec0::1 site-one.test
feff:ffff:ffff:ffff:ffff:ffff:ffff:ffff site-last.test
::ffff:100.64.0.1 mapped-shared.test
::ffff:1.1.1.1 mapped-public.test
192.0.0.9 anycast-9.test
192.0.0.10 anycast-10.test
1.1.1.1 mixed-public-first.test
10.0.0.1 mixed-public-first.test
10.0.0.1 mixed-private-first.test
1.1.1.1 mixed-private-first.test
10.0.0.1 two-private.test
10.0.0.2 two-private.test
10.0.0.2 two-private-desc.test
10.0.0.1 two-private-desc.test
191.255.255.255 ietf-below.test
192.0.1.0 ietf-above.test
EOF
if start_relay fixed && add_hosts "$HOSTS"; then
    check "RES3 a private address is refused with 403 and resolves-to-private addr=<address>" res3
    check "RES4 the shared address space 100.64.0.0/10 is refused at both edges, its neighbors are not" res4
    check "RES5 site-local IPv6 fec0::/10 is refused" res5
    check "RES6 an IPv4-mapped address is judged as its IPv4 address" res6
    check "RES7 192.0.0.9 and 192.0.0.10 are refused" res7
    check "RES9 a name with one refused address among public ones is refused" res9
    check "RES10 plain HTTP gives the same statuses and reasons as CONNECT" res10
    check "RES12 policy refusals keep their reasons and 403" res12
    check "RES17 a name that cannot be encoded answers 503 with resolve-failed:bad-name" res17
else
    for d in "RES3 a private address is refused with 403 and resolves-to-private addr=<address>" \
        "RES4 the shared address space 100.64.0.0/10 is refused at both edges, its neighbors are not" \
        "RES5 site-local IPv6 fec0::/10 is refused" \
        "RES6 an IPv4-mapped address is judged as its IPv4 address" \
        "RES7 192.0.0.9 and 192.0.0.10 are refused" \
        "RES9 a name with one refused address among public ones is refused" \
        "RES10 plain HTTP gives the same statuses and reasons as CONNECT" \
        "RES12 policy refusals keep their reasons and 403" \
        "RES17 a name that cannot be encoded answers 503 with resolve-failed:bad-name"; do
        check "$d" false
    done
fi

if start_relay prop; then
    check "RES8 property: sampled addresses in every refused range are refused, public samples are not" res8
else
    check "RES8 property: sampled addresses in every refused range are refused, public samples are not" false
fi

if idle_setup; then
    check "RES13 a tunnel idle longer than idle_timeout_seconds is closed; within it, or by default, it stays open" res13
    check "RES14 a plain-HTTP answer slower than idle_timeout_seconds is dropped; with a longer timeout it arrives" res14
    check "RES16 a one-way stream longer than the timeout keeps the whole tunnel open" res16
    check "RES18 a tunnel silent both ways closes at the timeout" res18
    check "RES20 both tunnel directions flow at once (8 MiB each way, upstream writes before it reads)" res20
    if idle_relay cap ""; then
        check "RES19 at most 64 concurrent connections (tunnels included): the 65th gets 503 too-many-connections, a closed one frees its slot" res19
    else
        check "RES19 at most 64 concurrent connections (tunnels included): the 65th gets 503 too-many-connections, a closed one frees its slot" false
    fi
    check "RES21 a request head not complete within the limit gets 408 and request-timeout, and the connection is closed" res21
    check "RES22 connections that never send a request free their slots at the limit" res22
    check "RES23 a slowly sent but complete head is served, and the limit ends with the head" res23
    check "RES26 bytes read with the CONNECT head are forwarded first, in order" res26
    check "RES27 a plain-HTTP request body is forwarded, exactly Content-Length bytes" res27
    check "RES28 the request limit is one deadline for the whole head" res28
    check "RES29 a ClientHello larger than the first read is read whole, allowed and forwarded in order" res29
    check "RES30 an upstream answer that comes before the whole body is sent still reaches the client" res30
    check "RES31 an early upstream answer is relayed at once while the relay waits for the body or the upstream stops reading" res31
else
    check "RES13 a tunnel idle longer than idle_timeout_seconds is closed; within it, or by default, it stays open" false
    check "RES14 a plain-HTTP answer slower than idle_timeout_seconds is dropped; with a longer timeout it arrives" false
    check "RES16 a one-way stream longer than the timeout keeps the whole tunnel open" false
    check "RES18 a tunnel silent both ways closes at the timeout" false
    check "RES20 both tunnel directions flow at once (8 MiB each way, upstream writes before it reads)" false
    check "RES19 at most 64 concurrent connections (tunnels included): the 65th gets 503 too-many-connections, a closed one frees its slot" false
    for d in "RES21 a request head not complete within the limit gets 408 and request-timeout, and the connection is closed" \
        "RES22 connections that never send a request free their slots at the limit" \
        "RES23 a slowly sent but complete head is served, and the limit ends with the head" \
        "RES26 bytes read with the CONNECT head are forwarded first, in order" \
        "RES27 a plain-HTTP request body is forwarded, exactly Content-Length bytes" \
        "RES28 the request limit is one deadline for the whole head" \
        "RES29 a ClientHello larger than the first read is read whole, allowed and forwarded in order" \
        "RES30 an upstream answer that comes before the whole body is sent still reaches the client" \
        "RES31 an early upstream answer is relayed at once while the relay waits for the body or the upstream stops reading"; do
        check "$d" false
    done
fi
check "RES15 the relay refuses to start with an idle_timeout_seconds outside 1-3600 or not a whole number" res15
check "RES24 the relay refuses to start with an LLMBOX_REQUEST_TIMEOUT outside 1-3600 or not a whole number" res24
check "RES25 by default a request head gets 30 seconds" res25

check "RES11 every deny reason is one token" res11

echo ""
echo "test_relay_resolution.sh: ${PASS} passed, ${FAIL} failed, 0 skipped"
[ "$FAIL" -eq 0 ]
