#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# run-all-suites.sh: run every tests/test_*.sh suite in the passes a full
# regression needs, and judge the results across passes.
#
# Usage: tests/run-all-suites.sh [options]
#   --logs DIR            per-pass logs, summary.md and junit.xml (default ./test-logs)
#   --no-build            do not build images between the passes (already built,
#                         or a test of this script)
#   --suites-dir DIR      where the suites live (default: this script's directory)
#   --tmp DIR             the shared temporary directory to keep clean (default /tmp)
#   --sudo CMD            how to run a command as root (default: sudo env PATH=$PATH)
#   --docker CMD          the docker command used to look for built images (default: docker)
#   --lbx PATH            the lbx binary the suites drive (exported as LBX_BIN;
#                         default: the suites' own target/debug/lbx fallback)
#   --approved-skips FILE checks allowed to skip in every pass
#                         (default: approved-skips.txt next to the suites)
#
# Passes, in order (each suite prints [PASS]/[FAIL]/[SKIP] <check> lines):
#   before-images  test_llm_in_a_box_vm.sh, as the invoking user, only when no
#                  llm-in-a-box image exists yet: its "unbuilt vm image" check
#                  needs a host without images.
#   (build)        ./build relay and ./build docker, plus ./build sysbox when
#                  docker has the sysbox-runc runtime, unless --no-build.
#   user           every test_*.sh suite except this script's own test, then
#                  verify-run-unattended.sh (real docker, user only).
#   root           the suites with root-only checks (config, migrate, docker
#                  store), run again as root.
#
# Judging, per suite and check across its passes:
#   failed in any pass                         -> failed
#   passed in at least one pass, failed in none -> passed
#   skipped in every pass it appeared in        -> skipped
# A skip line's trailing " (reason)" is dropped before matching, so a check
# that skips as root and passes as the user is judged as one check.
# Exit status is non-zero when any check failed, any suite exited non-zero,
# any suite printed no result lines, or any check was skipped without being
# on the approved list (lines "<suite file>|<check name prefix>").
#
# After each suite, top-level entries it created in the temporary
# directory are removed when their names match what the suites use, so
# a root pass never trips over files a user pass left at fixed names.
#
# The environment variable LBX_TEST_PASS names the current pass for the
# suites (before-images, user or root).
# ---------------------------------------------------------------------------
set -uo pipefail

# A plain umask, for every suite: several fixtures write config files that the
# launcher reads, and `lbx` refuses a config that group or others can write.
# Measured 2026-10-25 on a host whose shell has umask 002: the config suite went
# 58 passed / 0 failed -> 26 / 32 with no code change, and the sessions suite
# lost its four config-key checks. CI already exported this before running us
# ("the runner process starts with a group-writable umask"); doing it here makes
# a local run behave the same as CI, and the suites repeat it so they are also
# correct when run one at a time.
umask 022

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITES_DIR="$HERE"
LOGS="$PWD/test-logs"
TMPROOT=/tmp
BUILD=1
SUDO_CMD="sudo env PATH=$PATH"
DOCKER_CMD=docker
APPROVED=""

while [ $# -gt 0 ]; do
    case "$1" in
        --logs) LOGS="$2"; shift 2 ;;
        --no-build) BUILD=0; shift ;;
        --suites-dir) SUITES_DIR="$(cd "$2" && pwd)"; shift 2 ;;
        --tmp) TMPROOT="$2"; shift 2 ;;
        --sudo) SUDO_CMD="$2"; shift 2 ;;
        --docker) DOCKER_CMD="$2"; shift 2 ;;
        --approved-skips) APPROVED="$2"; shift 2 ;;
        --lbx) export LBX_BIN="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; shift 2 ;;
        -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "run-all-suites.sh: unknown option: $1" >&2; exit 2 ;;
    esac
done
APPROVED="${APPROVED:-$SUITES_DIR/approved-skips.txt}"
mkdir -p "$LOGS"
LOGS="$(cd "$LOGS" && pwd)"
REPO="$(cd "$SUITES_DIR/.." && pwd)"

SELF_TEST="test_run_all_suites.sh"
ROOT_SUITES=(test_llm_in_a_box_config.sh test_llm_in_a_box_migrate.sh test_vm_docker_store.sh)
# Real-docker suites that run once, as the user only (the unattended-run
# suites refuse root by design).
USER_ONLY_SUITES=(verify-run-unattended.sh)
BEFORE_IMAGES_SUITE=test_llm_in_a_box_vm.sh

# results.tsv: pass<TAB>suite<TAB>status<TAB>check  (one line per result line)
# suites.tsv:  pass<TAB>suite<TAB>exit code<TAB>pass count<TAB>fail count<TAB>skip count
: > "$LOGS/results.tsv"
: > "$LOGS/suites.tsv"

# Top-level names the suites create in the temporary directory. Only new
# entries matching these are removed; anything else (other users' files,
# systemd-private-* directories of services that start mid-run) is left alone.
SUITE_TMP_PATTERNS=('llm*' 'lbx*' 'netwall*' 'cfg17b*' 'vm-docker-store-test*')

tmp_listing() { LC_ALL=C ls -A1 "$TMPROOT" 2>/dev/null | LC_ALL=C sort; }

# After each suite, remove the matching entries it added. Docker containers
# can leave root-owned files inside them, so removal falls back to root.
clean_tmp_since() { # <before listing file>
    local before="$1" entry pat
    while IFS= read -r entry; do
        for pat in "${SUITE_TMP_PATTERNS[@]}"; do
            # shellcheck disable=SC2254
            case "$entry" in
                $pat) rm -rf -- "${TMPROOT:?}/$entry" 2>/dev/null || $SUDO_CMD rm -rf -- "${TMPROOT:?}/$entry"; break ;;
            esac
        done
    done < <(LC_ALL=C comm -13 "$before" <(tmp_listing))
}

run_suite() { # <pass> <suite file> <user|root>
    local pass="$1" suite="$2" who="$3" log rc before
    log="$LOGS/$pass-${suite%.sh}.log"
    before="$(mktemp)"
    tmp_listing > "$before"
    printf '==== %s (%s) ====\n' "$suite" "$pass"
    if [ "$who" = root ]; then
        ( cd "$REPO" && $SUDO_CMD LBX_TEST_PASS="$pass" bash "$SUITES_DIR/$suite" ) > "$log" 2>&1
    else
        ( cd "$REPO" && LBX_TEST_PASS="$pass" bash "$SUITES_DIR/$suite" ) > "$log" 2>&1
    fi
    rc=$?
    clean_tmp_since "$before"
    rm -f "$before"
    # Result lines, with a skip's trailing " (reason)" removed.
    sed -n -E 's/^\[(PASS|FAIL|SKIP)\] (.*)$/\1\t\2/p' "$log" \
        | sed -E '/^SKIP\t/ s/ \([^()]*\)$//' \
        | awk -F'\t' -v p="$pass" -v s="$suite" 'BEGIN{OFS="\t"} {print p, s, $1, $2}' >> "$LOGS/results.tsv"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$pass" "$suite" "$rc" \
        "$(grep -c '^\[PASS\] ' "$log")" "$(grep -c '^\[FAIL\] ' "$log")" "$(grep -c '^\[SKIP\] ' "$log")" \
        >> "$LOGS/suites.tsv"
    tail -1 "$log"
}

have_images() {
    local tag
    for tag in docker sysbox latest; do
        $DOCKER_CMD image inspect "llm-in-a-box:$tag" >/dev/null 2>&1 && return 0
    done
    return 1
}

if [ -f "$SUITES_DIR/$BEFORE_IMAGES_SUITE" ] && ! have_images; then
    run_suite before-images "$BEFORE_IMAGES_SUITE" user
fi

if [ "$BUILD" = 1 ]; then
    printf '==== building images ====\n'
    ( cd "$REPO" && ./build relay && ./build docker && { ! $DOCKER_CMD info --format "{{json .Runtimes}}" 2>/dev/null | grep >/dev/null sysbox-runc || ./build sysbox; } ) > "$LOGS/build.log" 2>&1 \
        || { tail -40 "$LOGS/build.log"; echo "Image build failed; no suites ran after it. See build.log." > "$LOGS/summary.md"; cat "$LOGS/summary.md"; exit 1; }
    grep "^image " "$LOGS/build.log"
fi

for f in "$SUITES_DIR"/test_*.sh; do
    s="$(basename "$f")"
    [ "$s" = "$SELF_TEST" ] && continue
    run_suite user "$s" user
done
for s in "${USER_ONLY_SUITES[@]}"; do
    [ -f "$SUITES_DIR/$s" ] && run_suite user "$s" user
done
for s in "${ROOT_SUITES[@]}"; do
    [ -f "$SUITES_DIR/$s" ] && run_suite root "$s" root
done

# ── Judge ───────────────────────────────────────────────────────────────────
# judged.tsv: suite<TAB>verdict<TAB>check, verdict one of passed/failed/
# skipped/skipped-approved.
awk -F'\t' -v approved="$APPROVED" '
BEGIN {
    OFS = "\t"
    while ((getline line < approved) > 0) {
        if (line ~ /^[[:space:]]*(#|$)/) continue
        n++; split(line, a, "|"); asuite[n] = a[1]; aprefix[n] = substr(line, length(a[1]) + 2)
    }
}
{
    k = $2 SUBSEP $4
    if (!(k in seen)) { seen[k] = 1; order[++m] = k }
    if ($3 == "FAIL") f[k] = 1
    else if ($3 == "PASS") p[k] = 1
}
END {
    for (i = 1; i <= m; i++) {
        k = order[i]; split(k, parts, SUBSEP)
        if (k in f) v = "failed"
        else if (k in p) v = "passed"
        else {
            v = "skipped"
            for (j = 1; j <= n; j++)
                if (parts[1] == asuite[j] && index(parts[2], aprefix[j]) == 1) v = "skipped-approved"
        }
        print parts[1], v, parts[2]
    }
}' "$LOGS/results.tsv" > "$LOGS/judged.tsv"

bad_suites="$(awk -F'\t' '$3 != 0 || ($4 + $5 + $6) == 0 {print $1 " " $2 " (exit " $3 ", " ($4+$5+$6) " result lines)"}' "$LOGS/suites.tsv")"
failed="$(awk -F'\t' '$2 == "failed"' "$LOGS/judged.tsv")"
unapproved="$(awk -F'\t' '$2 == "skipped"' "$LOGS/judged.tsv")"

# ── JUnit XML (one test case per judged check) ──────────────────────────────
awk -F'\t' '
function esc(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s); gsub(/\047/, "\\&apos;", s); return s }
{ n[$1]++; row[$1, n[$1]] = $0; if ($2 == "failed") fl[$1]++; if ($2 ~ /^skipped/) sk[$1]++; if (!($1 in seen)) { seen[$1] = 1; ord[++m] = $1 } }
END {
    print "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
    print "<testsuites>"
    for (i = 1; i <= m; i++) {
        s = ord[i]
        printf "  <testsuite name=\"%s\" tests=\"%d\" failures=\"%d\" skipped=\"%d\">\n", esc(s), n[s], fl[s] + 0, sk[s] + 0
        for (j = 1; j <= n[s]; j++) {
            split(row[s, j], r, "\t")
            printf "    <testcase classname=\"%s\" name=\"%s\">", esc(s), esc(r[3])
            if (r[2] == "failed") printf "<failure message=\"failed in at least one pass\"/>"
            else if (r[2] == "skipped") printf "<skipped message=\"skipped in every pass\"/>"
            else if (r[2] == "skipped-approved") printf "<skipped message=\"approved skip\"/>"
            print "</testcase>"
        }
        print "  </testsuite>"
    }
    print "</testsuites>"
}' "$LOGS/judged.tsv" > "$LOGS/junit.xml"

# ── Summary ─────────────────────────────────────────────────────────────────
{
    echo "| Pass | Suite | Exit | Pass | Fail | Skip |"
    echo "|---|---|---|---|---|---|"
    awk -F'\t' '{printf "| %s | %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5, $6}' "$LOGS/suites.tsv"
    echo
    echo "Judged across passes: $(awk -F'\t' '$2=="passed"' "$LOGS/judged.tsv" | wc -l) passed," \
        "$(printf '%s' "$failed" | grep -c .) failed," \
        "$(printf '%s' "$unapproved" | grep -c .) skipped without approval," \
        "$(awk -F'\t' '$2=="skipped-approved"' "$LOGS/judged.tsv" | wc -l) approved skips."
    if [ -n "$bad_suites" ]; then echo; echo "Suites that exited non-zero or printed no results:"; printf '%s\n' "$bad_suites" | sed 's/^/- /'; fi
    if [ -n "$failed" ]; then echo; echo "Failed checks:"; printf '%s\n' "$failed" | awk -F'\t' '{print "- " $1 ": " $3}'; fi
    if [ -n "$unapproved" ]; then echo; echo "Skipped in every pass, not approved:"; printf '%s\n' "$unapproved" | awk -F'\t' '{print "- " $1 ": " $3}'; fi
} > "$LOGS/summary.md"
echo
cat "$LOGS/summary.md"

[ -z "$bad_suites" ] && [ -z "$failed" ] && [ -z "$unapproved" ]
