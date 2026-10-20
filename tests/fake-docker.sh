#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# fake-docker.sh — deterministic docker shim for the test suites.
#
# WHAT: a stand-in for the docker CLI that records every invocation to a
# log file and answers the exact subcommands the launcher and build
# script issue, from per-test fixture files. It exists because the
# launcher's container paths (create/attach/destroy/list) and the build's
# image pipeline cannot be driven deterministically against a real docker
# daemon (this box's daemon is dead; other hosts may lack images or
# sysbox-runc).
#
# Fixtures (env):
#   FAKE_DOCKER_LOG      file: every invocation appended as one line
#   FAKE_EXISTING_FILE   file: image refs that "exist" (one per line);
#                        a ref just docker-built is appended by this shim
#   FAKE_CONTAINER_TABLE file: lines
#     "name|runtime_label_name|runtime_label_value|image|state|
#      hostconfig_runtime|netpolicy_label_name|netpolicy_label_value"
#     (empty fields allowed). A label value is reported ONLY when the
#     queried label NAME matches the table's label name — mirroring
#     docker, where each label is queried independently.
#
# Behavior contract (exact-match on the -f format strings the launcher
# uses; anything unknown is recorded and exits 1 so surprises fail
# loudly instead of silently passing):
#   image inspect <ref>              exit 0 iff <ref> in FAKE_EXISTING_FILE
#   info --format '{{json .Runtimes}}'  prints {"sysbox-runc":{}}
#   run -d ... <ref>                 records argv, prints a fake cid
#   run --rm --entrypoint /bin/sh <ref> -c '<probe>'   toolchain probe:
#                                    records, exit 0
#   run --rm --entrypoint bash ... -v <src>:/state ... inner base-disk
#                                    run: records, materializes
#                                    base.qcow2 + vmlinuz in <src>
#   inspect -f '{{.State.Status}}' <name>       prints the table state
#   container inspect -f <fmt> <name>           label/image/state,
#                                    HostConfig.Runtime, or net-policy
#                                    per the format string
#   container inspect <name>         exit 0 iff in the table
#   ps -a --format '{{.Names}}'      prints the table's names
#   exec <name> ...                  exit 0 (user-ready probe, id, attach)
#   stop|start|logs|kill|rm          records, exit 0
#   network create|network rm        records, exit 0
#   build ...                        records, adds the -t ref to the
#                                    existence set (mirrors
#                                    build_docker_image's post-build
#                                    image inspect)
#   create <ref>                     records, prints a fake cid
#   export <cid> -o <file>           records, writes a minimal tar
#   *                                records, exit 1
#
# WHY: the CFG/LG/ST checks assert on the RECORDED argv (which image was
# run, which labels were written, which relay/network names were cleaned
# up) and on exit codes — never on source text (invariant 12).
# ---------------------------------------------------------------------------
set -u

FAKE_DOCKER_LOG="${FAKE_DOCKER_LOG:-/tmp/fake-docker.log}"
FAKE_EXISTING_FILE="${FAKE_EXISTING_FILE:-/tmp/fake-existing.txt}"
FAKE_CONTAINER_TABLE="${FAKE_CONTAINER_TABLE:-/tmp/fake-containers.txt}"

mkdir -p "$(dirname "$FAKE_DOCKER_LOG")" "$(dirname "$FAKE_EXISTING_FILE")"
printf '%s\n' "$*" >> "$FAKE_DOCKER_LOG"

table_lookup() {
    local name="$1" line
    [ -f "$FAKE_CONTAINER_TABLE" ] || return 1
    while IFS='|' read -r tname tlblname tlblval timg tstate thrt tpolname tpolval tuser; do
        [ "$tname" = "$name" ] || continue
        printf '%s|%s|%s|%s|%s|%s|%s|%s' "$tlblname" "$tlblval" "$timg" "$tstate" "$thrt" "$tpolname" "$tpolval" "$tuser"
        return 0
    done < "$FAKE_CONTAINER_TABLE"
    return 1
}

image_exists() {
    local ref="$1"
    [ -f "$FAKE_EXISTING_FILE" ] || return 1
    grep -qxF "$ref" "$FAKE_EXISTING_FILE" >/dev/null 2>&1
}

case "$1" in
    image)
        case "$2" in
            inspect)
                if [ "${3:-}" = "--format" ] && [ "${4:-}" = '{{.RepoDigests}}' ]; then
                    # FAKE_DIGEST (optional): a repo digest; empty by
                    # default (locally built images), which makes the
                    # build fall back to the resolved ref.
                    printf '%s\n' "${FAKE_DIGEST:-[]}"
                else
                    image_exists "$3"; exit $?
                fi
                ;;
            *) exit 1 ;;
        esac
        ;;
    info)
        # FAKE_NO_SYSBOX_RUNTIME=1 models a host whose docker has no sysbox
        # runtime, which is a real host (the CI virtual machines are one). It
        # exists so the launcher's "sysbox-runc runtime not found" refusal can
        # be checked on a host that HAS sysbox installed: without the seam the
        # only way to reach that refusal is to run the suite on a host without
        # it, so the check could never run where the project is developed.
        if [ -n "${FAKE_NO_SYSBOX_RUNTIME:-}" ]; then
            printf '{}\n'
        else
            printf '{"sysbox-runc":{}}\n'
        fi
        ;;
    run)
        if [ "${2:-}" = "-d" ]; then
            # docker run -d ... --name <name> ... <ref>: register the
            # container (state=running) so wait_for_running and the
            # attach path resolve it, and echo a fake cid. The box-user
            # stamp (llm-in-a-box.user) is kept so era checks see it.
            name=""; prev=""; userlabel=""; prevlabel=""
            for a in "$@"; do
                [ "$prev" = "--name" ] && name="$a"
                if [ "$prevlabel" = "--label" ]; then
                    case "$a" in
                        llm-in-a-box.user=*) userlabel="${a#llm-in-a-box.user=}" ;;
                    esac
                fi
                prev="$a"; prevlabel="$a"
            done
            if [ -n "$name" ]; then
                printf '%s||||running|||%s\n' "$name" "$userlabel" >> "$FAKE_CONTAINER_TABLE"
            fi
            echo "fake-cid-$$"
        elif [ "${2:-}" = "--rm" ]; then
            # Toolchain probe vs base-disk inner run:
            #   probe:      --entrypoint /bin/sh <ref> -c '<probe>'
            #   inner run:  --entrypoint bash ... -v <src>:/state <ref> -c '<script>'
            if [[ "$*" == *"--entrypoint /bin/sh"* ]]; then
                # FAKE_PROBE_FAIL=1 makes the toolchain probe FAIL so
                # the build's precise toolchain error is testable
                # (CFG33).
                [ "${FAKE_PROBE_FAIL:-0}" = "1" ] && exit 1
            elif [[ "$*" == *"--entrypoint bash"* && "$*" == *":/state"* ]]; then
                # Materialize the base-disk artifacts the host-side build
                # checks for: base.qcow2 + vmlinuz in the /state source dir.
                src=""
                for a in "$@"; do
                    case "$a" in
                        *:/state) src="${a%:/state}" ;;
                    esac
                done
                if [ -n "$src" ]; then
                    touch "$src/base.qcow2" "$src/vmlinuz"
                fi
            else
                : # any other run --rm: record only
            fi
        else
            :
        fi
        ;;
    inspect)
        # $ENGINE inspect -f '{{.State.Status}}' <name>
        if [ "${2:-}" = "-f" ] && [ "${3:-}" = '{{.State.Status}}' ]; then
            line=""
            line=$(table_lookup "${4:-}" 2>/dev/null) || exit 1
            printf '%s\n' "$(echo "$line" | cut -d'|' -f4)"
        else
            exit 1
        fi
        ;;
    container)
        case "$2" in
            inspect)
                if [ "${3:-}" = "-f" ]; then
                    line=""
                    line=$(table_lookup "${5:-}" 2>/dev/null) || exit 1
                    lblname=""; lblval=""; img=""; st=""; hrt=""; polname=""; polval=""; tuser=""
                    lblname=$(echo "$line" | cut -d'|' -f1)
                    lblval=$(echo "$line" | cut -d'|' -f2)
                    img=$(echo "$line" | cut -d'|' -f3)
                    st=$(echo "$line" | cut -d'|' -f4)
                    hrt=$(echo "$line" | cut -d'|' -f5)
                    polname=$(echo "$line" | cut -d'|' -f6)
                    polval=$(echo "$line" | cut -d'|' -f7)
                    tuser=$(echo "$line" | cut -d'|' -f8)
                    case "${4:-}" in
                        '{{index .Config.Labels "box-of-claude.runtime"}}|{{.Config.Image}}|{{.State.Status}}')
                            if [ "$lblname" = "box-of-claude.runtime" ]; then printf '%s|%s|%s\n' "$lblval" "$img" "$st"; else printf '|%s|%s\n' "$img" "$st"; fi ;;
                        '{{index .Config.Labels "llm-in-a-box.runtime"}}|{{.Config.Image}}|{{.State.Status}}')
                            if [ "$lblname" = "llm-in-a-box.runtime" ]; then printf '%s|%s|%s\n' "$lblval" "$img" "$st"; else printf '|%s|%s\n' "$img" "$st"; fi ;;
                        '{{.HostConfig.Runtime}}')
                            printf '%s\n' "$hrt" ;;
                        '{{index .Config.Labels "llm-in-a-box.runtime"}}')
                            if [ "$lblname" = "llm-in-a-box.runtime" ]; then printf '%s\n' "$lblval"; else printf '\n'; fi ;;
                        '{{index .Config.Labels "llm-in-a-box.user"}}')
                            # Column 8 of the table is the box-user stamp
                            # (llm-in-a-box.user); empty for old-era rows.
                            printf '%s\n' "$tuser" ;;
                        '{{index .Config.Labels "box-of-claude.runtime"}}')
                            if [ "$lblname" = "box-of-claude.runtime" ]; then printf '%s\n' "$lblval"; else printf '\n'; fi ;;
                        '{{.Config.Image}}')
                            printf '%s\n' "$img" ;;
                        '{{index .Config.Labels "box-of-claude.net-policy"}}')
                            if [ "$polname" = "box-of-claude.net-policy" ]; then printf '%s\n' "$polval"; else printf '\n'; fi ;;
                        '{{index .Config.Labels "llm-in-a-box.net-policy"}}')
                            if [ "$polname" = "llm-in-a-box.net-policy" ]; then printf '%s\n' "$polval"; else printf '\n'; fi ;;
                        *) exit 1 ;;
                    esac
                else
                    # bare `docker container inspect <name>`: existence probe
                    table_lookup "${3:-}" >/dev/null 2>&1
                    exit $?
                fi
                ;;
            *) exit 1 ;;
        esac
        ;;
    ps)
        if [ "${2:-}" = "-a" ] && [ "${3:-}" = "--format" ] && [ "${4:-}" = '{{.Names}}' ]; then
            [ -f "$FAKE_CONTAINER_TABLE" ] || exit 0
            cut -d'|' -f1 "$FAKE_CONTAINER_TABLE"
        else
            exit 1
        fi
        ;;
    exec)
        exit 0
        ;;
    stop|logs|kill)
        exit 0
        ;;
    start)
        # docker start <name>: flip the row's state field to running
        # (docker parity) so wait_for_running can observe the start.
        if [ -n "${2:-}" ] && [ -f "$FAKE_CONTAINER_TABLE" ]; then
            sed -i "s/^\(${2}|[^|]*|\([^|]*|\)\{2\}\)exited/\1running/" "$FAKE_CONTAINER_TABLE" 2>/dev/null || true
        fi
        exit 0
        ;;
    rm)
        exit 0
        ;;
    network)
        case "${2:-}" in
            create|rm) exit 0 ;;
            *) exit 1 ;;
        esac
        ;;
    build)
        # docker build ... -t <ref> <context>: register the tag so the
        # post-build `docker image inspect` in build_docker_image passes.
        ref=""
        prev=""
        for a in "$@"; do
            [ "$prev" = "-t" ] && ref="$a"
            prev="$a"
        done
        if [ -n "$ref" ]; then
            printf '%s\n' "$ref" >> "$FAKE_EXISTING_FILE"
        fi
        ;;
    create)
        echo "fake-create-cid-$$"
        ;;
    export)
        # docker export <cid> -o <file>
        out=""
        prev=""
        for a in "$@"; do
            [ "$prev" = "-o" ] && out="$a"
            prev="$a"
        done
        if [ -n "$out" ]; then
            printf 'fake rootfs tar\n' > "$out"
        fi
        ;;
    *)
        exit 1
        ;;
esac
exit 0