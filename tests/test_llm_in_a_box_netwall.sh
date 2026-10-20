#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_llm_in_a_box_netwall.sh — behavioral tests for the host-side network
# access control (plan 2026_09_03_network_access_control).
#
# WHAT (no source grep — invariant 12):
#   Phase 1 (relay, T1-T5): the llm-in-a-box-relay container is the ONLY
#   door through the wall. It must:
#     T1: allow a CONNECT to an allowlisted domain and deny a non-listed
#         one (enforce mode), writing the verdict to the deny log;
#     T2: deny when the TLS SNI does not equal the CONNECT host;
#     T3: deny when an allowlisted hostname RESOLVES to a private/
#         link-local address (deny beats allow, checked in the relay);
#     T4: deny IP-literal CONNECT targets (no IP allowlisting — shared
#         CDN edges make IPs meaningless);
#     T5: open mode allows everything (and logs); locked denies
#         non-model hosts and allows the model API;
#     T3b: a name that does not exist is a lookup failure
#         (resolve-failed:EAI_NONAME, 503), not a refusal;
#     T2b: an SNI mismatch is logged as reason=sni-mismatch.
#   LBX_TEST_RELAY_IMAGE selects the relay image for T1-T5, T2b and
#   T3b (default llm-in-a-box-relay:latest; sessions always use that).
#
# WHY: the wall lives OUTSIDE the box because the agent has root inside it
#      (one iptables -F away from gone). The relay takes untrusted input
#      from the box, so its decisions must be verified directly — before
#      any lbx wiring exists (Phase 2/3).
#
# LLM-FRIENDLY NOTE: real egress is required (api.anthropic.com, example.com,
# openssl for the SNI-mismatch case). A short connectivity preflight skips
# the suite when there is no internet, so it degrades to skip-not-fail
# instead of flaking. Each check runs its own throwaway relay container.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RELAY_IMAGE="${LBX_TEST_RELAY_IMAGE:-llm-in-a-box-relay:latest}"
BOC="${LBX_BIN:-${SCRIPT_DIR}/../target/debug/lbx}"
export LLMBOX_SCRIPT_DIR="$SCRIPT_DIR/.."

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

find_free_port() {
    for port in "$@"; do
        if ! ss -tlnH "sport = :$port" | grep >/dev/null .; then
            echo "$port"
            return
        fi
    done
    return 1
}

RELAY_NAME="llm-in-a-box-relay-test-$$"
LOG_BASE=/tmp/llm-in-a-box-netwall-logs
rm -rf "$LOG_BASE" && mkdir -p "$LOG_BASE"

cleanup() {
    docker rm -f "$RELAY_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ── Preflight: docker + internet (skip-not-fail) ───────────────────────────
if ! docker info >/dev/null 2>&1; then
    echo "[SKIP] test_llm_in_a_box_netwall.sh: docker is not usable"
    exit 0
fi
if ! docker image inspect "$RELAY_IMAGE" >/dev/null 2>&1; then
    echo "==> Building $RELAY_IMAGE (docker/relay) ..."
    docker build -t "$RELAY_IMAGE" "$REPO_ROOT/docker/relay" \
        || { echo "[FAIL] relay image build failed" >&2; exit 1; }
fi
if ! curl -s --max-time 10 -o /dev/null https://api.anthropic.com; then
    echo "[SKIP] test_llm_in_a_box_netwall.sh: no internet egress from this host"
    exit 0
fi

# ── Helper: start a throwaway relay with a policy file ─────────────────────
# start_relay <policy> <logdir> [extra docker run options...]
start_relay() {
    local policy="$1" logdir="$2"
    shift 2
    local port
    port=$(find_free_port 4128 14128 24128 34128)
    docker run -d --name "$RELAY_NAME" \
        --user "$(id -u):$(id -g)" \
        -e LLMBOX_POLICY=/policy.json \
        -e LLMBOX_DENY_LOG=/log/deny.log \
        -v "$policy:/policy.json:ro" \
        -v "$logdir:/log" \
        -p "127.0.0.1:${port}:3128" \
        "$@" \
        "$RELAY_IMAGE" >/dev/null
    echo "$port"
}

mkpolicy() {
    local file="$1" mode="$2" allow="$3" block="$4"
    printf '{"mode": "%s", "allow": [%s], "block": [%s]}\n' "$mode" "$allow" "$block" > "$file"
}

# proxy_curl <proxy-port> <url> → http_code or 000; non-zero exit on failure
proxy_curl() {
    curl -s --max-time 25 -x "http://127.0.0.1:$1" -o /dev/null -w '%{http_code}' "$2"
}

# ── T1: enforce — allowlisted domain succeeds, others denied + logged ──────
POL=/tmp/llm-in-a-box-netwall-p1.json
mkpolicy "$POL" enforce '"api.anthropic.com"' ''
LOGD=$LOG_BASE/t1 && mkdir -p "$LOGD"
PORT=$(start_relay "$POL" "$LOGD")
sleep 1
check "enforce: allowlisted CONNECT succeeds through the relay" \
    "[ \"\$(proxy_curl $PORT https://api.anthropic.com)\" != 000 ]"
check "enforce: non-listed domain is denied and logged" \
    "proxy_curl $PORT https://example.com >/dev/null 2>&1; [ \$? -ne 0 ] \
        && sleep 1 && grep -q 'DENY.*example.com' $LOGD/deny.log"
docker rm -f "$RELAY_NAME" >/dev/null 2>&1

# ── T2: SNI must equal the CONNECT host ────────────────────────────────────
POL=/tmp/llm-in-a-box-netwall-p2.json
mkpolicy "$POL" enforce '"api.anthropic.com"' ''
LOGD=$LOG_BASE/t2 && mkdir -p "$LOGD"
PORT=$(start_relay "$POL" "$LOGD")
sleep 1
# CONNECT api.anthropic.com (allowed) but present a different SNI — denied.
check "TLS SNI not equal to the CONNECT host is denied" \
    "openssl s_client -proxy 127.0.0.1:$PORT -servername evil.example \
        -connect api.anthropic.com:443 </dev/null >/dev/null 2>&1; [ \$? -ne 0 ] \
        && sleep 1 && grep -q 'DENY.*api.anthropic.com' $LOGD/deny.log"
docker rm -f "$RELAY_NAME" >/dev/null 2>&1

# ── T3: allowlisted hostname resolving to private space is denied ──────────
# Requirement (RR3, RR4 in plans/2026_09_29_relay_resolution_reasons):
# an allowlisted name that resolves to a refused address is denied as
# resolves-to-private (deny beats allow).
# The test name gets 127.0.0.1 through --add-host, and the check requires
# the deny line for that name to carry reason=resolves-to-private, so it
# proves the refusal came from the resolved address. (A trailing-dot name
# such as `localhost.` is not matched in /etc/hosts by Alpine's resolver:
# it fails its lookup instead, which is a different reason.)
POL=/tmp/llm-in-a-box-netwall-p3.json
mkpolicy "$POL" enforce '"loopback-probe.test"' ''
LOGD=$LOG_BASE/t3 && mkdir -p "$LOGD"
PORT=$(start_relay "$POL" "$LOGD" --add-host loopback-probe.test:127.0.0.1)
sleep 1
check "allowlisted hostname resolving to loopback/private space is denied (deny beats allow)" \
    "proxy_curl $PORT https://loopback-probe.test/ >/dev/null 2>&1; [ \$? -ne 0 ] \
        && sleep 1 && grep -q ' DENY .* host=loopback-probe.test reason=resolves-to-private' $LOGD/deny.log"
docker rm -f "$RELAY_NAME" >/dev/null 2>&1

# ── T4: IP-literal CONNECT targets are denied ──────────────────────────────
POL=/tmp/llm-in-a-box-netwall-p4.json
mkpolicy "$POL" enforce '"1.1.1.1"' ''
LOGD=$LOG_BASE/t4 && mkdir -p "$LOGD"
PORT=$(start_relay "$POL" "$LOGD")
sleep 1
check "IP-literal CONNECT targets are denied (no IP allowlisting)" \
    "proxy_curl $PORT https://1.1.1.1/ >/dev/null 2>&1; [ \$? -ne 0 ] \
        && sleep 1 && grep -q 'DENY' $LOGD/deny.log"
docker rm -f "$RELAY_NAME" >/dev/null 2>&1

# ── T5: open allows everything (and logs); locked allows only model hosts ──
POL=/tmp/llm-in-a-box-netwall-p5a.json
mkpolicy "$POL" open '' ''
LOGD=$LOG_BASE/t5a && mkdir -p "$LOGD"
PORT=$(start_relay "$POL" "$LOGD")
sleep 1
check "open mode allows a non-listed domain and logs it" \
    "[ \"\$(proxy_curl $PORT https://example.com)\" != 000 ] \
        && sleep 1 && grep -q 'ALLOW.*example.com' $LOGD/deny.log"
docker rm -f "$RELAY_NAME" >/dev/null 2>&1

POL=/tmp/llm-in-a-box-netwall-p5b.json
mkpolicy "$POL" locked '"api.anthropic.com"' ''
LOGD=$LOG_BASE/t5b && mkdir -p "$LOGD"
PORT=$(start_relay "$POL" "$LOGD")
sleep 1
check "locked mode denies github.com and allows the model API" \
    "proxy_curl $PORT https://github.com >/dev/null 2>&1; [ \$? -ne 0 ] \
        && [ \"\$(proxy_curl $PORT https://api.anthropic.com)\" != 000 ]"
docker rm -f "$RELAY_NAME" >/dev/null 2>&1

# ── T3b: a name that does not exist is a lookup failure, not a refusal ─────
# Requirement (RR1, RR6 in plans/2026_09_29_relay_resolution_reasons):
# "When getaddrinfo raises socket.gaierror, the relay denies with
# reason=resolve-failed:<code>, never resolves-to-private"; "A lookup
# failure answers 503 Service Unavailable."
# Theory: `.invalid` never resolves (RFC 6761), so a real resolver answers
# "no such name" (EAI_NONAME). This is the one lookup-failure case that
# needs a working resolver; tests/test_relay_resolution.sh covers the
# timeout case (EAI_AGAIN) without one.
# The relay ignores the host's search domains (--dns-search . and
# ndots:1), so the name is looked up exactly as written.
# Rule 10: judges the relay's deny log and curl's view of its answer.
# curl exits non-zero when the proxy refuses the CONNECT (56 with curl
# 8.5.0, 7 with 8.18.0), so the status it printed is judged, not its exit
# code (under pipefail a `curl | grep` pipeline failed whatever the
# status). On failure the check prints the status curl saw and the
# relay's deny line for the name, so a log shows why.
# LLM summary: CONNECT no-such-host.invalid -> resolve-failed:EAI_NONAME, 503.
POL=/tmp/llm-in-a-box-netwall-p3b.json
mkpolicy "$POL" enforce '"no-such-host.invalid"' ''
LOGD=$LOG_BASE/t3b && mkdir -p "$LOGD"
PORT=$(start_relay "$POL" "$LOGD" --dns-search . --dns-option ndots:1)
sleep 1
t3b_check() {
    local code
    code="$(curl -s --max-time 25 -x "http://127.0.0.1:$PORT" -o /dev/null -w '%{http_connect}' https://no-such-host.invalid/ 2>/dev/null)"
    [ "$code" = 503 ] \
        && grep -q ' DENY .* host=no-such-host.invalid reason=resolve-failed:EAI_NONAME$' "$LOGD/deny.log" \
        && return 0
    echo "    curl saw CONNECT status '${code}'; relay deny line: '$(grep -F ' host=no-such-host.invalid ' "$LOGD/deny.log" 2>/dev/null | tail -n 1)'"
    return 1
}
check "T3b a name that does not exist is denied as resolve-failed:EAI_NONAME with 503" t3b_check
docker rm -f "$RELAY_NAME" >/dev/null 2>&1

# ── T2b: an SNI mismatch is logged with its own reason ─────────────────────
# Requirement (RR7 in plans/2026_09_29_relay_resolution_reasons): "Every
# other verdict, reason and status line is unchanged": an SNI mismatch
# keeps its reason sni-mismatch and the SNI seen.
# Theory: T2 proves the refusal but accepts any DENY line; a relay whose
# reason changes for this refusal (or drops the SNI it saw) passes T2 and
# fails here. openssl sends SNI evil.example through a CONNECT to
# api.anthropic.com, which the relay must log as that mismatch.
# Rule 10: judges the relay's deny log only.
# LLM summary: CONNECT api.anthropic.com with SNI evil.example ->
# reason=sni-mismatch sni=evil.example.
POL=/tmp/llm-in-a-box-netwall-p2b.json
mkpolicy "$POL" enforce '"api.anthropic.com"' ''
LOGD=$LOG_BASE/t2b && mkdir -p "$LOGD"
PORT=$(start_relay "$POL" "$LOGD")
sleep 1
check "T2b an SNI mismatch is logged as reason=sni-mismatch with the SNI seen" \
    "openssl s_client -proxy 127.0.0.1:$PORT -servername evil.example \
        -connect api.anthropic.com:443 </dev/null >/dev/null 2>&1; \
        sleep 1 && grep -q ' DENY .* host=api.anthropic.com reason=sni-mismatch sni=evil.example\$' $LOGD/deny.log"
docker rm -f "$RELAY_NAME" >/dev/null 2>&1

# ══ Phase 2 (lbx docker/sysbox wiring, 2026-09-03) ══════════════
# T6-T10, T12, T13, T15, T16: real sessions with real walls. skip-not-fail
# without docker + llm-in-a-box:docker + the relay image + internet.

BOX_IMAGE="llm-in-a-box:docker"
NETFIX=/tmp/llm-in-a-box-netwall-fix
rm -rf "$NETFIX" && mkdir -p "$NETFIX"
NETPOL=$NETFIX/enforce.json
mkpolicy "$NETPOL" enforce '"api.anthropic.com","pypi.org","files.pythonhosted.org","repo1.maven.org","repo.maven.apache.org","registry-1.docker.io","auth.docker.io","production.cloudflare.docker.com","production.cloudfront.docker.com"' ''
SESS="llm-in-a-box-netsess-$$"

if docker image inspect "$BOX_IMAGE" >/dev/null 2>&1 && curl -s --max-time 10 -o /dev/null https://api.anthropic.com; then
    HAVE_SESSIONS=1
else
    HAVE_SESSIONS=0
fi

if [ "$HAVE_SESSIONS" = 1 ]; then
    # ── T6: walled session — deny/allow pair + env + wiring ───────────────
    cd $NETFIX && "$BOC" --net-policy "$NETPOL" "$SESS" </dev/null >/tmp/netwall-t6.log 2>&1 || true
    # The entrypoint renames the box user to the host user (lbx passes
    # HOST_USER=$(whoami) and HOST_UID); wait for its setup to finish, then
    # exec as that user.
    for _ in $(seq 1 60); do
        docker exec "$SESS" test -f /tmp/.user-ready 2>/dev/null && break
        sleep 1
    done
    # Reach the box user by NUMBER, never by name. `docker exec --user <name>`
    # is resolved from the IMAGE's /etc/passwd, not the container's, because the
    # uid has to be known before the container's own filesystem is reachable
    # (moby/moby#640, moby/moby#39261). The image has `claude`; the entrypoint
    # renames that user to the host user in the container's writable layer, so
    # `--user dpp` fails with "unable to find user dpp: no matching entries in
    # passwd file" while `--user claude` still resolves. The numeric form works
    # on every runtime and survives a restart (verified on Docker 29.8.2).
    # These are the ids the box user was created with: lbx passes
    # HOST_UID="$(id -u)" and HOST_GID="$(id -g)".
    SUSER_UID="$(id -u)"
    SUSER_GID="$(id -g)"
    # Give the relay a moment to bind its port before the first probes
    # (the session and its relay start in the same instant).
    sleep 3
    check "walled session starts with a relay + internal network" \
        "docker container inspect llm-in-a-box-relay-$SESS >/dev/null 2>&1 \
            && docker network inspect llm-in-a-box-net-$SESS >/dev/null 2>&1 \
            && [ \"\$(docker network inspect -f '{{.Internal}}' llm-in-a-box-net-$SESS)\" = true ]"
    check "session carries the policy label" \
        "docker container inspect -f '{{index .Config.Labels \"llm-in-a-box.net-policy\"}}' $SESS 2>/dev/null | grep >/dev/null enforce.json"
    check "proxy env is persisted for interactive shells (profile.d)" \
        "docker exec -u "$SUSER_UID:$SUSER_GID" $SESS bash -lc 'echo \$HTTP_PROXY' 2>/dev/null | grep >/dev/null llm-in-a-box-relay-$SESS"
    check "enforce: example.com denied inside the session" \
        "docker exec -u "$SUSER_UID:$SUSER_GID" $SESS bash -lc 'curl -s --max-time 20 -o /dev/null -w %{http_code} https://example.com' >/tmp/netwall-example.out 2>&1; [ \$? -ne 0 ] || ! grep -qE '2[0-9][0-9]|3[0-9][0-9]' /tmp/netwall-example.out"
    check "enforce: api.anthropic.com succeeds inside the session" \
        "docker exec -u "$SUSER_UID:$SUSER_GID" $SESS bash -lc 'curl -s --max-time 25 -o /dev/null -w %{http_code} https://api.anthropic.com' 2>/dev/null | grep -v >/dev/null 000"

    # ── T7: boundary proof — the wall survives in-box sabotage ────────────
    docker exec -u root "$SESS" iptables -F >/dev/null 2>&1 || true
    docker exec -u root "$SESS" ip route add default via 172.16.0.1 >/dev/null 2>&1 || true
    check "after iptables -F + a new route, the deny/allow pair is unchanged (wall is outside)" \
        "docker exec -u "$SUSER_UID:$SUSER_GID" $SESS bash -lc 'curl -s --max-time 20 -o /dev/null -w %{http_code} https://example.com' >/tmp/netwall-b1.out 2>&1; [ \$? -ne 0 ] || ! grep -qE '2[0-9][0-9]|3[0-9][0-9]' /tmp/netwall-b1.out \
            && docker exec -u "$SUSER_UID:$SUSER_GID" $SESS bash -lc 'curl -s --max-time 25 -o /dev/null -w %{http_code} https://api.anthropic.com' >/tmp/netwall-b2.out 2>&1; [ \$? -eq 0 ]"

    # ── T9: no DNS / no route out ─────────────────────────────────────────
    check "dig @8.8.8.8 times out inside the walled session" \
        "docker exec -u "$SUSER_UID:$SUSER_GID" $SESS bash -lc 'timeout 8 dig @8.8.8.8 example.com +short' 2>/dev/null; [ \$? -ne 0 ]"

    # ── T10: JVM tools work with only JAVA_TOOL_OPTIONS (from profile.d) ──
    check "mvn dependency:get succeeds with only the JVM proxy options" \
        "docker exec -u "$SUSER_UID:$SUSER_GID" $SESS bash -lc 'cd /tmp && timeout 240 mvn -q dependency:get -Dartifact=junit:junit:4.13.2' >/tmp/netwall-t10.log 2>&1; [ \$? -eq 0 ]"

    # ── T8: inner dockerd pulls behind the wall ───────────────────────────
    # The entrypoint's full-home ownership fix can delay the inner dockerd
    # for minutes — wait for ITS socket, not just /tmp/.user-ready.
    # NOTE: the inner `docker run` (busybox wget) check lives in the vm
    # e2e (Phase 3): in the CONTAINER runtime the session's /var/lib/docker
    # sits on an overlay layer and nested overlayfs mounts fail with EINVAL
    # (overlay-on-overlay) — the daemon's proxy plumbing is what this check
    # proves, via the pull path.
    # The docker runtime keeps the inner /var/lib/docker on the container's
    # overlay filesystem, which cannot hold another overlay, so this pull
    # fails on every host until the launcher gives it its own storage.
    # The command runs through `sg docker`: `docker exec -u <uid>:<gid>` gives
    # the process those ids and NO supplementary groups, so the box user
    # cannot reach /var/run/docker.sock (mode 660, group docker) without it;
    # measured: "permission denied while trying to connect to the Docker
    # daemon socket". A user's own shell has the group; this reproduces that.
    #
    # The launcher mounts a per-session docker volume at /var/lib/docker,
    # so the inner daemon has a filesystem of its own rather than the
    # container's overlay (which cannot hold another overlay). The check
    # therefore runs on every host now; LBX_TEST_INNER_DOCKER=0 forces
    # the old skip for a host that cannot pull.
    if [ "${LBX_TEST_INNER_DOCKER:-1}" = 1 ]; then
        check "inner dockerd pulls busybox through the door (daemon proxy plumbing)" \
            "docker exec -u "$SUSER_UID:$SUSER_GID" $SESS bash -lc 'for i in \$(seq 1 180); do docker info >/dev/null 2>&1 && break; sleep 1; done; sg docker -c \"docker pull busybox:latest\" >/dev/null 2>&1' >/tmp/netwall-t8.log 2>&1; [ \$? -eq 0 ]"
    else
        skip "inner dockerd pulls busybox through the door (daemon proxy plumbing) (LBX_TEST_INNER_DOCKER=0 forces the skip on a host that cannot pull)"
    fi

    # ── T15: --denied prints the deny log ─────────────────────────────────
    check "--denied prints the session deny log" \
        "cd $NETFIX && '$BOC' --denied $SESS >/tmp/netwall-t15.log 2>&1; [ \$? -eq 0 ] \
            && grep -q 'DENY' /tmp/netwall-t15.log \
            && grep -q 'example.com' /tmp/netwall-t15.log"

    # ── T16: --destroy removes relay + network + log state ────────────────
    cd $NETFIX && "$BOC" --destroy "$SESS" >/tmp/netwall-t16.log 2>&1
    check "--destroy removes the relay container and the internal network" \
        "! docker container inspect llm-in-a-box-relay-$SESS >/dev/null 2>&1 \
            && ! docker network inspect llm-in-a-box-net-$SESS >/dev/null 2>&1 \
            && ! docker network inspect llm-in-a-box-relaynet-$SESS >/dev/null 2>&1"
else
    skip "walled container-session checks (need docker + llm-in-a-box:docker + internet)"
fi

# ── T12: no policy = no wall (D3 default) ─────────────────────────────────
if [ "$HAVE_SESSIONS" = 1 ]; then
    SESS2="llm-in-a-box-netsess2-$$"
    cd $NETFIX && "$BOC" "$SESS2" </dev/null >/tmp/netwall-t12.log 2>&1 || true
    for _ in $(seq 1 30); do
        [ "$(docker container inspect -f '{{.State.Status}}' "$SESS2" 2>/dev/null)" = running ] && break
        sleep 1
    done
    check "no-policy session: direct egress works and no relay/network exists" \
        "docker exec -u "$SUSER_UID:$SUSER_GID" $SESS2 bash -lc 'curl -s --max-time 20 -o /dev/null -w %{http_code} https://example.com' 2>/dev/null | grep -v >/dev/null 000 \
            && docker exec -u "$SUSER_UID:$SUSER_GID" $SESS2 bash -lc 'curl -s --max-time 25 -o /dev/null -w %{http_code} https://api.anthropic.com' 2>/dev/null | grep -v >/dev/null 000 \
            && ! docker container inspect llm-in-a-box-relay-$SESS2 >/dev/null 2>&1 \
            && ! docker network inspect llm-in-a-box-net-$SESS2 >/dev/null 2>&1"
    check "no-policy session: no proxy env is set" \
        "docker exec -u "$SUSER_UID:$SUSER_GID" $SESS2 bash -lc 'echo \$HTTP_PROXY' 2>/dev/null | grep -v >/dev/null 'llm-in-a-box-relay'"
    cd $NETFIX && "$BOC" --destroy "$SESS2" >/dev/null 2>&1
    check "--denied for a policy-less session reports no deny log" \
        "cd $NETFIX && '$BOC' --denied $SESS2 2>&1 | grep -i >/dev/null 'no deny log'"
else
    skip "no-policy session checks (need docker + llm-in-a-box:docker + internet)"
fi

# ── T13: malformed policy fails closed ────────────────────────────────────
echo '{"mode": "enforce"' > /tmp/llm-in-a-box-netwall-bad.json
check "malformed policy file refuses to start the session (fail closed)" \
    "cd $NETFIX && '$BOC' --net-policy /tmp/llm-in-a-box-netwall-bad.json llm-in-a-box-netsess-bad </dev/null >/tmp/netwall-t13.log 2>&1; [ \$? -ne 0 ] \
        && grep -qi 'invalid net policy' /tmp/netwall-t13.log \
        && ! docker container inspect llm-in-a-box-netsess-bad >/dev/null 2>&1"
rm -f /tmp/llm-in-a-box-netwall-bad.json

echo ""
echo "test_llm_in_a_box_netwall.sh: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
[ "$FAIL" -eq 0 ]
