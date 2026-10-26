#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# fake-docker-registry.sh: a docker stand-in for tests/test_ci_images.sh.
#
# WHAT: records every invocation to a log and answers the docker
# subcommands scripts/ci/images and a stand-in ./build issue, from a local
# image list, a fake registry and a label file. Any other subcommand is
# recorded and exits 1, so a script that starts doing something unexpected
# fails loudly instead of passing.
#
# WHY a separate shim: tests/fake-docker.sh answers the launcher's
# container subcommands and has no registry; the image cache checks need a
# registry (push, remote digests), image labels that travel with an image
# from build to push to pull, and failures on demand.
#
# Files and switches (environment):
#   FAKE_DOCKER_LOG      every invocation, one line: the arguments joined by spaces
#   FAKE_LOCAL_IMAGES    local images, lines "<reference> <image id>"
#   FAKE_REGISTRY        registry contents, lines "<repository>:<tag> <digest>"
#   FAKE_LABELS          image labels, lines "<image id or digest> <key>=<value>",
#                        one line per label; written by build (for the new
#                        image id, parsed from separate --label arguments)
#                        and by push (copied to the pushed digest)
#   FAKE_PUSH_DIGEST     digest a successful push stores (default sha256:a...a)
#   FAKE_PUSH_FAILS      number of pushes that fail before one succeeds (default 0)
#   FAKE_PUSH_COUNT      counter file for FAKE_PUSH_FAILS
#   FAKE_BUILD_FAIL=1    make `docker build` fail
#   FAKE_INSPECT_ERROR_ON=<ref>  make `imagetools inspect <ref>` fail the way
#                        an authentication error does (a 403, not "not found")
#   FAKE_INSPECT_ERROR_MSG   the message of that failure (default: a 403 line)
#   FAKE_NO_REPO_DIGESTS=1  make images report no repository digests
#
# Answers:
#   build ... -t <ref> [<context>]   new image id; <ref> names it; each
#                                    "--label k=v" pair becomes a label line
#   tag <src> <dst>                  exit 1 unless <src> is local; <dst>
#                                    names the same image id
#   push <ref>                       fails FAKE_PUSH_FAILS times, then stores
#                                    <ref> at FAKE_PUSH_DIGEST and copies the
#                                    image's labels to that digest
#   pull <repo>@<digest>             exit 1 unless the registry has it; the
#                                    reference becomes local with image id
#                                    <digest>
#   image inspect --format '{{.Id}}' <ref>        prints the image id
#   image inspect --format '{{join .RepoDigests " "}}' <ref>
#                                    prints the <repo>@<digest> references
#                                    naming the same image (what a pull by
#                                    digest records), or nothing with
#                                    FAKE_NO_REPO_DIGESTS=1
#   image inspect --format '{{index .Config.Labels "<key>"}}' <ref>
#                                    prints the label (empty when absent)
#   buildx imagetools inspect --format '{{printf "%s" .Manifest.Digest}}' <ref>
#                                    prints the digest (no newline, as docker
#                                    does) of <repo>:<tag> or <repo>@<digest>;
#                                    exit 1 with "ERROR: <ref>: not found" when
#                                    the registry has no such image, as buildx
#                                    prints it
#   login ...                        records, exit 0
#   anything else                    records, exit 1
#
# LLM-FRIENDLY NOTE: the checks assert on the recorded argument lines, on
# the registry, local image and label files after a script ran (what was
# pushed or tagged, from which digest, with which labels, in which order).
# They never read script source.
# ---------------------------------------------------------------------------
set -u

: "${FAKE_DOCKER_LOG:?FAKE_DOCKER_LOG must be set}"
: "${FAKE_LOCAL_IMAGES:?FAKE_LOCAL_IMAGES must be set}"
: "${FAKE_REGISTRY:?FAKE_REGISTRY must be set}"
FAKE_LABELS="${FAKE_LABELS:-$FAKE_REGISTRY.labels}"
FAKE_PUSH_DIGEST="${FAKE_PUSH_DIGEST:-sha256:$(printf 'a%.0s' $(seq 1 64))}"
FAKE_PUSH_FAILS="${FAKE_PUSH_FAILS:-0}"
FAKE_PUSH_COUNT="${FAKE_PUSH_COUNT:-$FAKE_REGISTRY.pushcount}"

printf '%s\n' "$*" >> "$FAKE_DOCKER_LOG"
touch "$FAKE_LOCAL_IMAGES" "$FAKE_REGISTRY" "$FAKE_LABELS"

# local_id <ref>: print the image id a local reference names, or return 1.
local_id() {
    local id
    id="$(awk -v r="$1" '$1 == r { i = $2 } END { if (i != "") print i }' "$FAKE_LOCAL_IMAGES")"
    [ -n "$id" ] || return 1
    printf '%s\n' "$id"
}

# registry_digest <ref>: print the digest a <repo>:<tag> or <repo>@<digest>
# reference names, or return 1 when the registry holds no such image.
registry_digest() {
    local ref="$1" repo digest name d line
    if [[ "$ref" == *@sha256:* ]]; then
        repo="${ref%@*}"
        digest="${ref#*@}"
        while read -r name d; do
            [ "$d" = "$digest" ] && [ "${name%:*}" = "$repo" ] || continue
            printf '%s' "$digest"
            return 0
        done < "$FAKE_REGISTRY"
        return 1
    fi
    # The last line for a reference wins, as a pushed tag replaces the old one.
    line="$(awk -v r="$ref" '$1 == r { d = $2 } END { if (d != "") print d }' "$FAKE_REGISTRY")"
    [ -n "$line" ] || return 1
    printf '%s' "$line"
}

case "${1:-}" in
    build)
        [ "${FAKE_BUILD_FAIL:-0}" = 1 ] && exit 1
        id="sha256:local-$(wc -l < "$FAKE_LOCAL_IMAGES")-$$"
        ref=""; labels=()
        shift
        while [ $# -gt 0 ]; do
            case "$1" in
                -t) ref="${2:-}"; shift 2 ;;
                --label) labels+=("${2:-}"); shift 2 ;;
                *) shift ;;
            esac
        done
        [ -n "$ref" ] && printf '%s %s\n' "$ref" "$id" >> "$FAKE_LOCAL_IMAGES"
        for l in ${labels[@]+"${labels[@]}"}; do printf '%s %s\n' "$id" "$l" >> "$FAKE_LABELS"; done
        exit 0
        ;;
    tag)
        id="$(local_id "${2:-}")" || exit 1
        printf '%s %s\n' "${3:-}" "$id" >> "$FAKE_LOCAL_IMAGES"
        exit 0
        ;;
    push)
        n="$(cat "$FAKE_PUSH_COUNT" 2>/dev/null || echo 0)"
        echo $((n + 1)) > "$FAKE_PUSH_COUNT"
        if [ "$n" -lt "$FAKE_PUSH_FAILS" ]; then
            echo "fake push failure $((n + 1))" >&2
            exit 1
        fi
        id="$(local_id "${2:-}")" || exit 1
        printf '%s %s\n' "$2" "$FAKE_PUSH_DIGEST" >> "$FAKE_REGISTRY"
        awk -v i="$id" -v d="$FAKE_PUSH_DIGEST" '$1 == i { $1 = d; print }' "$FAKE_LABELS" >> "$FAKE_LABELS.new"
        cat "$FAKE_LABELS.new" >> "$FAKE_LABELS" 2>/dev/null; rm -f "$FAKE_LABELS.new"
        exit 0
        ;;
    pull)
        [[ "${2:-}" == *@sha256:* ]] || exit 1
        d="$(registry_digest "$2")" || { echo "Error: ${2}: not found" >&2; exit 1; }
        printf '%s %s\n' "$2" "$d" >> "$FAKE_LOCAL_IMAGES"
        exit 0
        ;;
    image)
        [ "${2:-}" = inspect ] && [ "${3:-}" = --format ] || exit 1
        id="$(local_id "${5:-}")" || { echo "Error: No such image: ${5:-}" >&2; exit 1; }
        case "${4:-}" in
            '{{.Id}}') printf '%s\n' "$id" ;;
            '{{join .RepoDigests " "}}')
                [ "${FAKE_NO_REPO_DIGESTS:-0}" = 1 ] || awk -v i="$id" '$2 == i && $1 ~ /@sha256:/ { printf "%s%s", s, $1; s = " " } END { print "" }' "$FAKE_LOCAL_IMAGES"
                ;;
            '{{index .Config.Labels "'*'"}}')
                key="${4#\{\{index .Config.Labels \"}"; key="${key%\"\}\}}"
                awk -v i="$id" -v k="$key" '$1 == i && index($2, k "=") == 1 { v = substr($0, length(i) + length(k) + 3) } END { print v }' "$FAKE_LABELS"
                ;;
            *) exit 1 ;;
        esac
        exit 0
        ;;
    buildx)
        [ "${2:-}" = imagetools ] && [ "${3:-}" = inspect ] || exit 1
        [ "${4:-}" = --format ] && [ "${5:-}" = '{{printf "%s" .Manifest.Digest}}' ] || exit 1
        if [ -n "${FAKE_INSPECT_ERROR_ON:-}" ] && [ "${6:-}" = "$FAKE_INSPECT_ERROR_ON" ]; then
            echo "${FAKE_INSPECT_ERROR_MSG:-ERROR: unexpected status from HEAD request to https://registry.invalid/v2/manifests: 403 Forbidden}" >&2
            exit 1
        fi
        registry_digest "${6:-}" || { echo "ERROR: ${6:-}: not found" >&2; exit 1; }
        exit 0
        ;;
    login)
        exit 0
        ;;
esac
exit 1
