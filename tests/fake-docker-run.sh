#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# fake-docker-run.sh — docker shim for the unattended-run suite.
#
# WHAT: a thin wrapper in front of tests/fake-docker.sh. It answers the
# docker calls an unattended run (`lbx --run`) makes that the base shim
# does not model, and hands every other call, unchanged, to
# tests/fake-docker.sh (which is never modified). Tests install it as
# `docker` on PATH exactly like the base shim.
#
# WHY a wrapper and not an edit to the base shim: the existing suites run
# against tests/fake-docker.sh; leaving it byte-for-byte unchanged is the
# simplest proof that those suites still see the same docker.
#
# Every call is appended to FAKE_ARGV_LOG (when set) as one record:
# the word CALL followed by each argument, every field terminated by a
# zero byte, written with a single printf so concurrent runs do not
# interleave. Checks that compare argument vectors element by element
# read this log; tests/fake-docker.sh keeps its own space-joined log.
#
# Controls (environment; all optional, all off by default):
#   FAKE_WRAP_STATE        directory for the wrapper's own state
#                          (network table, mode table, counters, relay log
#                          directories). Required for the calls below.
#   FAKE_ARGV_LOG          zero-byte-separated argument log (see above).
#   FAKE_FAIL_ON           a name or image: `run -d`, `network create`
#                          and `network rm` whose target equals it exit 1.
#   FAKE_NETRM_FAILS       `network rm` fails this many times first.
#   FAKE_SETUP_STARTED     file touched when a `network create` begins.
#   FAKE_NETCREATE_SLEEP   seconds each `network create` takes.
#   FAKE_RELAY_IP          address reported for a container on a network
#                          (default 172.30.0.1).
#   FAKE_HEALTH_EXIT       exit of the relay health probe (default 0).
#   FAKE_READY_EXIT        exit of the run-ready probe (default 0).
#   FAKE_READY_AFTER       the run-ready probe fails until this many seconds
#                          after its first call (slow start).
#   FAKE_EXEC_STARTED      file touched when the command's exec begins.
#   FAKE_EXEC_SLEEP        seconds the command's exec takes (interruptible).
#   FAKE_EXEC_STDOUT       file whose bytes the command writes to stdout.
#   FAKE_EXEC_STDERR       file whose bytes the command writes to stderr.
#   FAKE_EXEC_STDIN_CAPTURE file receiving the command's standard input.
#   FAKE_EXEC_EXIT         exit of the command's exec (default 0).
#   FAKE_DENY_MARKER       a line the "relay" appends to its deny log
#                          while the command runs.
#   FAKE_STATUS_PLANT      a path: while the command runs, a symbolic link
#                          named `status` pointing at this path is planted
#                          in FAKE_STATUS_PLANT_DIR.
#   FAKE_STATUS_PLANT_DIR  the directory for FAKE_STATUS_PLANT.
#   FAKE_CREATE_THEN_FAIL  a container name: `run -d --name <it>` creates the
#                          container (it is registered like any other) and
#                          then exits 1, as docker does when a container is
#                          created but cannot be started.
#   FAKE_RM_STARTED        file touched when an `rm` begins.
#   FAKE_RM_SLEEP          seconds each `rm` takes.
#   FAKE_BARRIER_DIR       with FAKE_BARRIER_COUNT (default 2): the relay
#                          image lookup (`image inspect
#                          llm-in-a-box-relay:latest`) waits, up to 10 s,
#                          until that many callers have reached it, so
#                          concurrent launchers pass their checks together.
#   FAKE_NAME_TAKEN        a container or network name: just before `run -d
#                          --name <it>` or `network create ... <it>`,
#                          another container or network of that name
#                          appears (registered like any other) and the call
#                          fails as docker does on a name conflict.
#   FAKE_NAME_TAKEN_LABELS none (default): that other container has no
#                          labels; other: it has every label key of the
#                          failed call, each with a different value.
#   FAKE_NAME_TAKEN_STARTED file touched once that other container exists,
#                          while the failing call is still running.
#   FAKE_NAME_TAKEN_SLEEP  seconds the failing call then takes before it
#                          fails, so a signal can land while it runs.
#   FAKE_OWNS_FAILS        the run-id label queries (container and network,
#                          one shared count) fail this many times first, as
#                          docker does when its daemon cannot be reached.
#   FAKE_OWNS_FAILS_KIND   container or network: only that kind's run-id
#                          queries fail (and count); default both.
#   FAKE_RM_FAILS_ON       a container name: every `rm` naming it fails and
#                          removes nothing (the container stays, with its
#                          labels).
#   FAKE_LEFTOVER_FAILS    1: the label-filtered listings (`ps -a --filter
#                          label=...` and `network ls --filter label=...`)
#                          fail, as docker does when its daemon cannot be
#                          reached.
#   FAKE_CALL_TIMES        a file: every call appends one line, the time
#                          it began in microseconds since the epoch, a
#                          space, and its arguments joined by spaces, so
#                          checks can measure the waits between calls.
#   FAKE_HEALTH_FAILS      the relay health probe fails this many times
#                          first; after that FAKE_HEALTH_EXIT applies.
#   FAKE_RELAY_IP_FAIL     empty: the relay address query prints an empty
#                          line and exits 0 (a container with no address on
#                          that network); error: it prints docker's error
#                          and exits 1.
#   FAKE_IMAGE_USER        the answer to `image inspect --format
#                          '{{.Config.User}}' <image>` (the image's
#                          configured user); unset, the base shim answers
#                          as before (nothing, exit 1).
#   FAKE_EXEC_ENV_CAPTURE  a file: the command's exec appends, for every
#                          `-e NAME` it carries without a value, the line
#                          NAME=<value> from its own environment, or
#                          `NAME unset`, which is the value docker's client
#                          would pass (it reads such a name from its own
#                          environment, the launcher's).
#
# Every `run -d --name <n>` records its labels in the wrapper's label
# table; the query `container inspect -f '{{index .Config.Labels
# "llm-in-a-box.run-id"}}' <n>` answers from it (an empty line for a
# container without that label; for no container of that name, docker's
# "No such container" message and exit 1).
#
# Every `network create` records its labels in the wrapper's network label
# table; the query `network inspect -f '{{index .Labels
# "llm-in-a-box.run-id"}}' <n>` answers from it (an empty line for a
# network without that label; for no network of that name, docker's
# "network <n> not found" message and exit 1).
#
# `ps -a --filter label=llm-in-a-box.run-id=<v> --format '{{.Names}}'` and
# `network ls --filter label=llm-in-a-box.run-id=<v> --format '{{.Name}}'`
# list, from the same tables, the containers and networks that still carry
# exactly that label value.
#
# `rm` also forgets the removed names in the wrapper's mode and label
# tables, and `network rm` in its network label table, so the label
# queries of a removed container or network answer nothing, as docker
# does.
#
# LLM-FRIENDLY NOTE: which call is which is decided by exact shape, never
# by substring: the command's exec is `exec -i` (second word exactly -i)
# with `gosu` in its vector; the run-ready probe is
# `exec <box> test -f /tmp/.run-ready`; the relay health probe is
# `exec <relay> python3 -c <code>`. Anything else goes to the base shim,
# whose behavior for those calls is therefore exactly as before.
# ---------------------------------------------------------------------------
set -u

BASE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/fake-docker.sh"
STATE="${FAKE_WRAP_STATE:-}"

if [ -n "${FAKE_ARGV_LOG:-}" ]; then
    printf '%s\0' CALL "$@" >> "$FAKE_ARGV_LOG"
fi
if [ -n "${FAKE_CALL_TIMES:-}" ]; then
    # EPOCHREALTIME (bash 5) needs no extra process; its decimal separator
    # follows the locale, so both are removed to leave microseconds.
    if [ -n "${EPOCHREALTIME:-}" ]; then now_us="${EPOCHREALTIME/[.,]/}"; else now_us="$(date +%s%6N)"; fi
    printf '%s %s\n' "$now_us" "$*" >> "$FAKE_CALL_TIMES"
fi

# Record a call the wrapper answers itself in the base shim's text log
# too, so that log still lists every call.
note() {
    [ -n "${FAKE_DOCKER_LOG:-}" ] && printf '%s\n' "$*" >> "$FAKE_DOCKER_LOG"
    return 0
}

fails_on() {
    [ -n "${FAKE_FAIL_ON:-}" ] && [ "$1" = "$FAKE_FAIL_ON" ]
}

net_table() { printf '%s/networks' "$STATE"; }
mode_table() { printf '%s/modes' "$STATE"; }
label_table() { printf '%s/labels' "$STATE"; }
net_label_table() { printf '%s/network-labels' "$STATE"; }

# record_labels <name> <suffix> <table> <call arguments...>: every
# `--label k=v` of the call, as "name|k|v<suffix>" in the given table.
record_labels() {
    local n="$1" suffix="$2" table="$3" prev="" a
    shift 3
    for a in "$@"; do
        if [ "$prev" = "--label" ]; then
            printf '%s|%s|%s%s\n' "$n" "${a%%=*}" "${a#*=}" "$suffix" >> "$table"
        fi
        prev="$a"
    done
}

# forget_names <table> <names...>: drop every row of the table whose first
# field is one of the names.
forget_names() {
    local t="$1" a
    shift
    [ -f "$t" ] || return 0
    for a in "$@"; do
        case "$a" in -*) continue ;; esac
        awk -F'|' -v n="$a" '$1 != n' "$t" > "$t.new$$"
        mv "$t.new$$" "$t"
    done
}

# answer_run_id <table> <name>: the llm-in-a-box.run-id label of <name>
# from the table, on one line; returns 1 when the table has none for it.
answer_run_id() {
    [ -f "$1" ] && awk -F'|' -v n="$2" '$1 == n && $2 == "llm-in-a-box.run-id" { found = 1 } END { exit !found }' "$1" \
        || return 1
    awk -F'|' -v n="$2" '$1 == n && $2 == "llm-in-a-box.run-id" { sub(/^[^|]*\|[^|]*\|/, ""); print; exit }' "$1"
}

# daemon_unreachable: docker's answer when its daemon cannot be reached.
daemon_unreachable() {
    echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" >&2
    exit 1
}

# owns_query_fails <container|network>: true for the first FAKE_OWNS_FAILS
# run-id label queries (one count shared by containers and networks, or
# only the kind FAKE_OWNS_FAILS_KIND names).
owns_query_fails() {
    [ -n "${FAKE_OWNS_FAILS:-}" ] && [ -n "$STATE" ] || return 1
    [ -z "${FAKE_OWNS_FAILS_KIND:-}" ] || [ "$FAKE_OWNS_FAILS_KIND" = "$1" ] || return 1
    local count=0
    [ -f "$STATE/owns-count" ] && count=$(cat "$STATE/owns-count")
    count=$((count + 1))
    printf '%s\n' "$count" > "$STATE/owns-count"
    [ "$count" -le "$FAKE_OWNS_FAILS" ]
}

# names_with_run_id <table> <value>: every name in the table whose
# llm-in-a-box.run-id label is exactly the value, once each.
names_with_run_id() {
    [ -f "$1" ] || return 0
    awk -F'|' -v v="$2" '$2 == "llm-in-a-box.run-id" { val = $0; sub(/^[^|]*\|[^|]*\|/, "", val); if (val == v && !seen[$1]++) print $1 }' "$1"
}

# The value following a flag in the argument vector (first occurrence).
arg_after() {
    local flag="$1"; shift
    local prev=""
    for a in "$@"; do
        [ "$prev" = "$flag" ] && { printf '%s' "$a"; return 0; }
        prev="$a"
    done
    return 1
}

case "${1:-}" in
    network)
        case "${2:-}" in
            create)
                note "$@"
                # The network's name is the one argument that is neither an
                # option nor an option's value (docker reads options on
                # either side of it).
                name=""; skip=false
                for a in "${@:3}"; do
                    if [ "$skip" = true ]; then skip=false; continue; fi
                    case "$a" in
                        -o|--opt|--label|-d|--driver|--subnet|--gateway|--ip-range|--ipam-driver|--ipam-opt|--aux-address|--scope|--config-from) skip=true ;;
                        -*) ;;
                        *) [ -z "$name" ] && name="$a" ;;
                    esac
                done
                [ -n "${FAKE_SETUP_STARTED:-}" ] && touch "$FAKE_SETUP_STARTED"
                if [ -n "${FAKE_NAME_TAKEN:-}" ] && [ "$name" = "$FAKE_NAME_TAKEN" ]; then
                    [ -n "$STATE" ] && printf '%s\n' "$name" >> "$(net_table)"
                    if [ "${FAKE_NAME_TAKEN_LABELS:-none}" = other ] && [ -n "$STATE" ]; then
                        record_labels "$name" "-other" "$(net_label_table)" "$@"
                    fi
                    [ -n "${FAKE_NAME_TAKEN_STARTED:-}" ] && touch "$FAKE_NAME_TAKEN_STARTED"
                    if [ -n "${FAKE_NAME_TAKEN_SLEEP:-}" ]; then
                        sleep "$FAKE_NAME_TAKEN_SLEEP" </dev/null >/dev/null 2>&1 & wait $!
                    fi
                    echo "Error response from daemon: network with name $name already exists" >&2
                    exit 1
                fi
                if [ -n "${FAKE_NETCREATE_SLEEP:-}" ]; then
                    sleep "$FAKE_NETCREATE_SLEEP" & wait $!
                fi
                fails_on "$name" && exit 1
                if [ -n "$STATE" ]; then
                    printf '%s\n' "$name" >> "$(net_table)"
                    record_labels "$name" "" "$(net_label_table)" "$@"
                fi
                exit 0
                ;;
            rm)
                note "$@"
                if [ -n "${FAKE_NETRM_FAILS:-}" ] && [ -n "$STATE" ]; then
                    count=0
                    [ -f "$STATE/netrm-count" ] && count=$(cat "$STATE/netrm-count")
                    count=$((count + 1))
                    printf '%s\n' "$count" > "$STATE/netrm-count"
                    [ "$count" -le "$FAKE_NETRM_FAILS" ] && exit 1
                fi
                shift 2
                for name in "$@"; do
                    fails_on "$name" && exit 1
                    if [ -n "$STATE" ] && [ -f "$(net_table)" ]; then
                        grep -vxF "$name" "$(net_table)" > "$(net_table).new" || true
                        mv "$(net_table).new" "$(net_table)"
                        forget_names "$(net_label_table)" "$name"
                    fi
                done
                exit 0
                ;;
            inspect)
                note "$@"
                name="${!#}"
                owns=false
                [ "${3:-}" = -f ] && [ "${4:-}" = '{{index .Labels "llm-in-a-box.run-id"}}' ] && owns=true
                [ "$owns" = true ] && owns_query_fails network && daemon_unreachable
                if ! { [ -n "$STATE" ] && [ -f "$(net_table)" ] && grep -qxF "$name" "$(net_table)"; }; then
                    echo "Error response from daemon: network $name not found" >&2
                    exit 1
                fi
                # The run-id label query: the recorded value, or an empty
                # line for a network without that label.
                if [ "$owns" = true ]; then
                    answer_run_id "$(net_label_table)" "$name" || printf '\n'
                fi
                exit 0
                ;;
            ls)
                note "$@"
                if [ "${3:-}" = --filter ] && [ "${4#label=llm-in-a-box.run-id=}" != "${4:-}" ] \
                        && [ "${5:-}" = --format ] && [ "${6:-}" = '{{.Name}}' ]; then
                    [ "${FAKE_LEFTOVER_FAILS:-}" = 1 ] && daemon_unreachable
                    [ -n "$STATE" ] && names_with_run_id "$(net_label_table)" "${4#label=llm-in-a-box.run-id=}"
                    exit 0
                fi
                exit 1
                ;;
            connect)
                note "$@"
                exit 0
                ;;
        esac
        ;;
    run)
        if [ "${2:-}" = "-d" ]; then
            name=$(arg_after --name "$@") || name=""
            if [ -n "$name" ] && fails_on "$name"; then note "$@"; exit 1; fi
            for a in "$@"; do
                if fails_on "$a"; then note "$@"; exit 1; fi
            done
            if [ -n "$name" ] && [ -n "${FAKE_NAME_TAKEN:-}" ] && [ "$name" = "$FAKE_NAME_TAKEN" ]; then
                note "$@"
                printf '%s||||running||||\n' "$name" >> "$FAKE_CONTAINER_TABLE"
                if [ "${FAKE_NAME_TAKEN_LABELS:-none}" = other ] && [ -n "$STATE" ]; then
                    record_labels "$name" "-other" "$(label_table)" "$@"
                fi
                [ -n "${FAKE_NAME_TAKEN_STARTED:-}" ] && touch "$FAKE_NAME_TAKEN_STARTED"
                if [ -n "${FAKE_NAME_TAKEN_SLEEP:-}" ]; then
                    sleep "$FAKE_NAME_TAKEN_SLEEP" </dev/null >/dev/null 2>&1 & wait $!
                fi
                echo "docker: Error response from daemon: Conflict. The container name \"/$name\" is already in use." >&2
                exit 125
            fi
            if [ -n "$STATE" ] && [ -n "$name" ]; then
                record_labels "$name" "" "$(label_table)" "$@"
                prev=""
                for a in "$@"; do
                    if [ "$prev" = "--label" ] && [ "$a" = "llm-in-a-box.mode=run" ]; then
                        printf '%s|run\n' "$name" >> "$(mode_table)"
                    fi
                    if [ "$prev" = "-v" ] && [ "${a%:/log}" != "$a" ]; then
                        printf '%s\n' "${a%:/log}" > "$STATE/relay-log-dir"
                    fi
                    prev="$a"
                done
            fi
            if [ -n "$name" ] && [ -n "${FAKE_CREATE_THEN_FAIL:-}" ] && [ "$name" = "$FAKE_CREATE_THEN_FAIL" ]; then
                "$BASE" "$@" >/dev/null
                exit 1
            fi
        fi
        exec "$BASE" "$@"
        ;;
    rm)
        [ -n "${FAKE_RM_STARTED:-}" ] && touch "$FAKE_RM_STARTED"
        if [ -n "${FAKE_RM_SLEEP:-}" ]; then
            sleep "$FAKE_RM_SLEEP" & wait $!
        fi
        if [ -n "${FAKE_RM_FAILS_ON:-}" ]; then
            for a in "${@:2}"; do
                if [ "$a" = "$FAKE_RM_FAILS_ON" ]; then
                    note "$@"
                    echo "Error response from daemon: cannot remove container \"/$a\": could not kill: permission denied" >&2
                    exit 1
                fi
            done
        fi
        if [ -n "$STATE" ]; then
            forget_names "$(mode_table)" "${@:2}"
            forget_names "$(label_table)" "${@:2}"
        fi
        exec "$BASE" "$@"
        ;;
    image)
        if [ "${2:-}" = inspect ] && [ "${3:-}" = --format ] && [ "${4:-}" = '{{.Config.User}}' ] && [ -n "${FAKE_IMAGE_USER:-}" ]; then
            note "$@"
            printf '%s\n' "$FAKE_IMAGE_USER"
            exit 0
        fi
        if [ "${2:-}" = inspect ] && [ "${3:-}" = "llm-in-a-box-relay:latest" ] && [ -n "${FAKE_BARRIER_DIR:-}" ]; then
            touch "$FAKE_BARRIER_DIR/$$"
            waited=0
            while [ "$(find "$FAKE_BARRIER_DIR" -mindepth 1 -maxdepth 1 | wc -l)" -lt "${FAKE_BARRIER_COUNT:-2}" ] && [ "$waited" -lt 100 ]; do
                sleep 0.1
                waited=$((waited + 1))
            done
        fi
        exec "$BASE" "$@"
        ;;
    inspect|container)
        # The relay's numeric address on a network.
        fmt=""
        [ "${1}" = "inspect" ] && [ "${2:-}" = "-f" ] && fmt="${3:-}"
        [ "${1}" = "container" ] && [ "${2:-}" = "inspect" ] && [ "${3:-}" = "-f" ] && fmt="${4:-}"
        case "$fmt" in
            *'.IPAddress'*)
                note "$@"
                case "${FAKE_RELAY_IP_FAIL:-}" in
                    empty) printf '\n'; exit 0 ;;
                    error) echo "Error response from daemon: No such container: ${!#}" >&2; exit 1 ;;
                esac
                printf '%s\n' "${FAKE_RELAY_IP:-172.30.0.1}"
                exit 0
                ;;
            '{{index .Config.Labels "llm-in-a-box.mode"}}')
                note "$@"
                name="${!#}"
                if [ -n "$STATE" ] && [ -f "$(mode_table)" ]; then
                    grep -F "$name|" "$(mode_table)" | while IFS='|' read -r n m; do
                        [ "$n" = "$name" ] && printf '%s\n' "$m"
                    done
                fi
                exit 0
                ;;
            '{{index .Config.Labels "llm-in-a-box.run-id"}}')
                note "$@"
                name="${!#}"
                owns_query_fails container && daemon_unreachable
                if [ -n "$STATE" ] && answer_run_id "$(label_table)" "$name"; then
                    exit 0
                fi
                if [ -f "$FAKE_CONTAINER_TABLE" ] && cut -d'|' -f1 "$FAKE_CONTAINER_TABLE" | grep -xF >/dev/null -- "$name"; then
                    printf '\n'
                    exit 0
                fi
                echo "Error response from daemon: No such container: $name" >&2
                exit 1
                ;;
        esac
        exec "$BASE" "$@"
        ;;
    ps)
        # This run's leftover containers: those still carrying its run-id.
        if [ "${2:-}" = -a ] && [ "${3:-}" = --filter ] && [ "${4#label=llm-in-a-box.run-id=}" != "${4:-}" ] \
                && [ "${5:-}" = --format ] && [ "${6:-}" = '{{.Names}}' ]; then
            note "$@"
            [ "${FAKE_LEFTOVER_FAILS:-}" = 1 ] && daemon_unreachable
            [ -n "$STATE" ] && names_with_run_id "$(label_table)" "${4#label=llm-in-a-box.run-id=}"
            exit 0
        fi
        exec "$BASE" "$@"
        ;;
    exec)
        # The command's exec: second word exactly -i, gosu in the vector.
        if [ "${2:-}" = "-i" ]; then
            is_cmd=0
            for a in "$@"; do [ "$a" = "gosu" ] && is_cmd=1; done
            if [ "$is_cmd" = 1 ]; then
                note "$@"
                if [ -n "${FAKE_EXEC_STDIN_CAPTURE:-}" ]; then
                    cat > "$FAKE_EXEC_STDIN_CAPTURE"
                fi
                if [ -n "${FAKE_EXEC_ENV_CAPTURE:-}" ]; then
                    prev=""
                    for a in "$@"; do
                        [ "$a" = gosu ] && break
                        if [ "$prev" = -e ] && [ "${a#*=}" = "$a" ]; then
                            if printenv -- "$a" >/dev/null; then
                                printf '%s=%s\n' "$a" "$(printenv -- "$a")" >> "$FAKE_EXEC_ENV_CAPTURE"
                            else
                                printf '%s unset\n' "$a" >> "$FAKE_EXEC_ENV_CAPTURE"
                            fi
                        fi
                        prev="$a"
                    done
                fi
                [ -n "${FAKE_EXEC_STARTED:-}" ] && touch "$FAKE_EXEC_STARTED"
                if [ -n "${FAKE_DENY_MARKER:-}" ] && [ -n "$STATE" ] && [ -f "$STATE/relay-log-dir" ]; then
                    printf '%s\n' "$FAKE_DENY_MARKER" >> "$(cat "$STATE/relay-log-dir")/deny.log"
                fi
                if [ -n "${FAKE_STATUS_PLANT:-}" ] && [ -n "${FAKE_STATUS_PLANT_DIR:-}" ]; then
                    ln -sfn "$FAKE_STATUS_PLANT" "$FAKE_STATUS_PLANT_DIR/status"
                fi
                # The real exec client is one process; the helper sleep
                # holds none of its streams, so killing this fake client
                # closes them exactly as killing the real one would.
                if [ -n "${FAKE_EXEC_SLEEP:-}" ]; then
                    sleep "$FAKE_EXEC_SLEEP" </dev/null >/dev/null 2>&1 & wait $!
                fi
                [ -n "${FAKE_EXEC_STDOUT:-}" ] && cat "$FAKE_EXEC_STDOUT"
                [ -n "${FAKE_EXEC_STDERR:-}" ] && cat "$FAKE_EXEC_STDERR" >&2
                exit "${FAKE_EXEC_EXIT:-0}"
            fi
        fi
        # The run-ready probe and the relay health probe.
        if [ "${3:-}" = "test" ] && [ "${4:-}" = "-f" ] && [ "${5:-}" = "/tmp/.run-ready" ]; then
            note "$@"
            if [ -n "${FAKE_READY_AFTER:-}" ] && [ -n "$STATE" ]; then
                now=$(date +%s)
                [ -f "$STATE/ready-first" ] || printf '%s\n' "$now" > "$STATE/ready-first"
                first=$(cat "$STATE/ready-first")
                [ $((now - first)) -ge "$FAKE_READY_AFTER" ] || exit 1
            fi
            exit "${FAKE_READY_EXIT:-0}"
        fi
        if [ "${3:-}" = "python3" ] && [ "${4:-}" = "-c" ]; then
            note "$@"
            if [ -n "${FAKE_HEALTH_FAILS:-}" ] && [ -n "$STATE" ]; then
                count=0
                [ -f "$STATE/health-count" ] && count=$(cat "$STATE/health-count")
                count=$((count + 1))
                printf '%s\n' "$count" > "$STATE/health-count"
                [ "$count" -le "$FAKE_HEALTH_FAILS" ] && exit 1
            fi
            exit "${FAKE_HEALTH_EXIT:-0}"
        fi
        exec "$BASE" "$@"
        ;;
esac

exec "$BASE" "$@"
