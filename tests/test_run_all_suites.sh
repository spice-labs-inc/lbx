#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Tests for tests/run-all-suites.sh, the script continuous integration uses
# to run every suite and judge the results.
#
# WHAT: each check drives the real runner against a directory of FAKE
# suites. A fake suite prints the [PASS]/[FAIL]/[SKIP] lines and exits with
# the code the test wrote for it (per suite and pass), and records each call
# (pass name, and whether it ran through the root command). Root is
# simulated with --sudo "env FAKE_ROOT=1", the temporary directory with
# --tmp, and image builds are off (--no-build; RS8 puts
# a stub ./build in its place), so no root, docker or
# network is needed, except RS4 which parses the JUnit file with a real XML
# parser in a container.
#
# WHY: the runner decides whether a pull request is green. If its judging
# were wrong, a failing or silently skipped check could pass continuous
# integration, which is how the docker- and kvm-gated checks rotted before.
#
# LLM-FRIENDLY NOTE: RS1 is the property test (fixed seed, printed; set
# RS_SEED to replay). The expected verdicts are computed here independently
# of the runner's awk and compared line for line with its judged.tsv.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$HERE/run-all-suites.sh"
WORK="$(mktemp -d /tmp/lbx-runner-test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
check() {
    if eval "$2"; then echo "[PASS] $1"; PASS=$((PASS + 1)); else echo "[FAIL] $1"; FAIL=$((FAIL + 1)); fi
}

# A fake suite: output from $FAKE/<suite>.<pass>.out, exit code from
# $FAKE/<suite>.<pass>.rc (default 0), extra shell from $FAKE/<suite>.<pass>.sh.
FAKE_SUITE='#!/usr/bin/env bash
s="$(basename "$0")"; p="${LBX_TEST_PASS:-none}"
echo "$p $s ${FAKE_ROOT:-0}" >> "$FAKE/calls"
[ -f "$FAKE/$s.$p.sh" ] && bash "$FAKE/$s.$p.sh"
[ -f "$FAKE/$s.$p.out" ] && cat "$FAKE/$s.$p.out"
exit "$(cat "$FAKE/$s.$p.rc" 2>/dev/null || echo 0)"'

# new_case <suite...>: a fresh fake suites dir, tmp dir and logs dir.
new_case() {
    CASE="$WORK/case$((++CASE_N))"
    export FAKE="$CASE/fake"
    mkdir -p "$CASE/suites" "$FAKE" "$CASE/tmp" "$CASE/logs"
    : > "$CASE/approved"
    local s
    for s in "$@"; do printf '%s\n' "$FAKE_SUITE" > "$CASE/suites/$s"; done
}
CASE_N=0

run_runner() {
    bash "$RUNNER" --no-build --suites-dir "$CASE/suites" --tmp "$CASE/tmp" \
        --logs "$CASE/logs" --sudo "env FAKE_ROOT=1" --docker "${FAKE_DOCKER:-false}" --approved-skips "$CASE/approved" \
        > "$CASE/runner.out" 2>&1
}

CFG=test_llm_in_a_box_config.sh   # runs as user and as root
VM=test_llm_in_a_box_vm.sh        # runs before images and as user
STORE=test_vm_docker_store.sh     # runs as user and as root
OTHER=test_zz_other.sh            # runs as user only

# ── RS1 (property): judging across passes ───────────────────────────────────
# Requirement: failed in any pass -> failed; passed somewhere, failed nowhere
# -> passed; skipped everywhere -> skipped; the run fails exactly when a
# check failed or skipped without approval. Names include XML specials,
# quotes and a trailing "(...)" on PASS/FAIL lines, which must NOT be
# stripped (only skip reasons are).
SEED="${RS_SEED:-4242}"
RANDOM=$SEED
echo "RS1 seed: $SEED"
NAMES=('plain check' 'a & b' 'less < more > x' 'quote " and '"'"' apostrophe' 'ends with (parens)' 'C9 spaced  twice' 'unicode é check' 'dash -x --y')
STATUSES=(PASS FAIL SKIP)
rs1_bad=0
for case_i in $(seq 1 200); do
    new_case "$CFG" "$VM"
    : > "$CASE/expected"
    exp_rc=0
    for suite in "$CFG" "$VM"; do
        if [ "$suite" = "$CFG" ]; then passes=(user root); else passes=(before-images user); fi
        n=$((RANDOM % 3 + 1))
        for k in $(seq 0 $((n - 1))); do
            name="${NAMES[$(( (RANDOM + k) % ${#NAMES[@]} ))]} $case_i-$k"
            anyf=0; anyp=0
            for p in "${passes[@]}"; do
                st="${STATUSES[$((RANDOM % 3))]}"
                if [ "$st" = SKIP ]; then line="[SKIP] $name (reason $RANDOM)"; else line="[$st] $name"; fi
                echo "$line" >> "$FAKE/$suite.$p.out"
                [ "$st" = FAIL ] && { anyf=1; echo 1 > "$FAKE/$suite.$p.rc"; }
                [ "$st" = PASS ] && anyp=1
            done
            if [ $anyf = 1 ]; then v=failed; exp_rc=1
            elif [ $anyp = 1 ]; then v=passed
            else v=skipped; exp_rc=1; fi
            printf '%s\t%s\t%s\n' "$suite" "$v" "$name" >> "$CASE/expected"
        done
    done
    run_runner; rc=$?
    if ! diff <(sort "$CASE/expected") <(sort "$CASE/logs/judged.tsv") > "$CASE/diff" \
        || { [ $exp_rc = 0 ] && [ $rc != 0 ]; } || { [ $exp_rc != 0 ] && [ $rc = 0 ]; }; then
        rs1_bad=$((rs1_bad + 1))
        [ $rs1_bad = 1 ] && { echo "first mismatch (case $case_i, expected rc $exp_rc, got $rc):"; cat "$CASE/diff"; }
    fi
    [ $rs1_bad = 0 ] && rm -rf "$CASE"
done
check "RS1 judged verdicts and exit code match the rule in 200 random cases" "[ $rs1_bad = 0 ]"

# ── RS2: approved skips ─────────────────────────────────────────────────────
# Requirement: a check skipped everywhere is allowed only when its suite and
# name prefix are on the approved list; failing still fails.
new_case "$OTHER"
echo "$OTHER|T18 " > "$CASE/approved"
printf '[PASS] ok\n[SKIP] T18 sysbox thing (no sysbox)\n' > "$FAKE/$OTHER.user.out"
run_runner; rc=$?
check "RS2 an approved check skipped everywhere does not fail the run" \
    "[ $rc = 0 ] && grep -qP '^$OTHER\tskipped-approved\tT18 sysbox thing\$' '$CASE/logs/judged.tsv'"
new_case "$OTHER"
echo "$OTHER|T18 " > "$CASE/approved"
printf '[FAIL] T18 sysbox thing\n' > "$FAKE/$OTHER.user.out"; echo 1 > "$FAKE/$OTHER.user.rc"
run_runner; rc=$?
check "RS2 an approved check that fails still fails the run" "[ $rc != 0 ]"
new_case "$OTHER"
echo "$OTHER|T18 " > "$CASE/approved"
printf '[PASS] ok\n[SKIP] T19 other (no reason)\n' > "$FAKE/$OTHER.user.out"
run_runner; rc=$?
check "RS2 an unapproved check skipped everywhere fails the run and is listed" \
    "[ $rc != 0 ] && grep -q 'T19 other' '$CASE/logs/summary.md'"
new_case "$OTHER" "$CFG"
echo "$OTHER|T18 " > "$CASE/approved"
printf '[SKIP] T18 x (no sysbox)\n' > "$FAKE/$CFG.user.out"
printf '[SKIP] T18 x (no sysbox)\n' > "$FAKE/$CFG.root.out"
printf '[PASS] ok\n' > "$FAKE/$OTHER.user.out"
run_runner; rc=$?
check "RS2 approval is per suite: the same name in another suite is not approved" "[ $rc != 0 ]"

# ── RS3: suites that crash or print nothing ─────────────────────────────────
# Requirement: a suite's own exit code counts, and a suite with no result
# lines is a failure (a crash before the first check must not look green).
new_case "$OTHER"
printf '[PASS] a\n[PASS] b\n' > "$FAKE/$OTHER.user.out"; echo 3 > "$FAKE/$OTHER.user.rc"
run_runner; rc=$?
check "RS3 a suite exiting non-zero with only passes fails the run" \
    "[ $rc != 0 ] && grep -q 'exit 3' '$CASE/logs/summary.md'"
new_case "$OTHER"
: > "$FAKE/$OTHER.user.out"
run_runner; rc=$?
check "RS3 a suite printing no result lines fails the run" \
    "[ $rc != 0 ] && grep -q '0 result lines' '$CASE/logs/summary.md'"

# ── RS4: JUnit XML ──────────────────────────────────────────────────────────
# Requirement: the JUnit file is well-formed with hostile names and holds one
# test case per judged check with matching failure and skip counts.
new_case "$OTHER"
{
    echo '[PASS] a & b < c > "d" '"'"'e'"'"
    echo '[FAIL] fails (with parens)'
    echo '[SKIP] skipped one (because)'
} > "$FAKE/$OTHER.user.out"; echo 1 > "$FAKE/$OTHER.user.rc"
run_runner
XPATHS="count(//testcase) count(//testcase[failure]) count(//testcase[skipped]) string(//testcase[1]/@name) string(//testcase[2]/@name) string(//testcase[3]/@name)"
if command -v docker >/dev/null 2>&1 && docker pull -q alpine:3 >/dev/null; then
    docker run --rm -i alpine:3 sh -c "apk add -q --no-cache libxml2-utils >/dev/null && cat > /j.xml && xmllint --noout /j.xml && for x in $(printf "'%s' " $XPATHS); do xmllint --xpath \"\$x\" /j.xml; echo; done" \
        < "$CASE/logs/junit.xml" > "$CASE/xpath.out" 2>&1
    printf '%s\n' 3 1 1 'a & b < c > "d" '"'"'e'"'" 'fails (with parens)' 'skipped one' > "$CASE/xpath.expected"
    check "RS4 JUnit file parses and matches the judged checks (names, failures, skips)" \
        "diff '$CASE/xpath.expected' <(grep -v '^$' '$CASE/xpath.out')"
else
    check "RS4 JUnit check needs docker and the alpine:3 image to run xmllint (not available)" "false"
fi

# ── RS5: temporary directory hygiene ────────────────────────────────────────
# Requirement: entries a suite creates at the top of the temporary directory
# under the suites' names are removed after it (also for the root pass);
# entries that existed before, and new entries under other names (another
# service's files), stay.
new_case "$CFG"
touch "$CASE/tmp/llm-preexisting"
printf 'touch "%s/llmcfg-user-file"; mkdir -p "%s/llm-user-dir/sub"; touch "%s/systemd-private-x"\n' "$CASE/tmp" "$CASE/tmp" "$CASE/tmp" > "$FAKE/$CFG.user.sh"
printf '[ -e "%s/llmcfg-user-file" ] && echo "[FAIL] leftover seen by root" || echo "[PASS] clean for root"; touch "%s/lbx-root-file"\n' "$CASE/tmp" "$CASE/tmp" > "$FAKE/$CFG.root.sh"
echo '[PASS] x' > "$FAKE/$CFG.user.out"
run_runner; rc=$?
check "RS5 suite-named entries created during a pass are removed; earlier and unrelated entries survive" \
    "[ $rc = 0 ] && [ -e '$CASE/tmp/llm-preexisting' ] && [ -e '$CASE/tmp/systemd-private-x' ] \
        && [ ! -e '$CASE/tmp/llmcfg-user-file' ] && [ ! -e '$CASE/tmp/llm-user-dir' ] && [ ! -e '$CASE/tmp/lbx-root-file' ] \
        && grep -qP '\tpassed\tclean for root\$' '$CASE/logs/judged.tsv'"

# ── RS6: passes and order ───────────────────────────────────────────────────
# Requirement: the vm suite runs once before images; every suite runs as the
# user; config and docker store run again as root (through the root command);
# the runner's own test is never run by the runner; the unattended-run
# real-docker suite (verify-run-unattended.sh) runs once, as the user.
new_case "$CFG" "$VM" "$STORE" "$OTHER" test_run_all_suites.sh verify-run-unattended.sh
for s in "$CFG" "$VM" "$STORE" "$OTHER" verify-run-unattended.sh; do for p in before-images user root; do echo "[PASS] $s $p" > "$FAKE/$s.$p.out"; done; done
run_runner; rc=$?
printf '%s\n' "before-images $VM 0" "user $CFG 0" "user $VM 0" "user $STORE 0" "user $OTHER 0" "user verify-run-unattended.sh 0" "root $CFG 1" "root $STORE 1" > "$CASE/calls.expected"
check "RS6 suites run in the documented passes and order, root passes through the root command" \
    "[ $rc = 0 ] && diff '$CASE/calls.expected' '$FAKE/calls'"


# ── RS7: no before-images pass once images exist ────────────────────────────
# Requirement: the before-images pass runs only when no llm-in-a-box image
# exists (it would only skip its one image-free check otherwise).
new_case "$CFG" "$VM"
for s in "$CFG" "$VM"; do for p in before-images user root; do echo "[PASS] $s $p" > "$FAKE/$s.$p.out"; done; done
FAKE_DOCKER=true run_runner; rc=$?
check "RS7 with images present the vm suite runs only in the user pass" \
    "[ $rc = 0 ] && ! grep -q '^before-images ' '$FAKE/calls' && grep -q '^user $VM ' '$FAKE/calls'"

# ── RS8: the image step ─────────────────────────────────────────────────────
# Requirement: without --no-build the runner makes the images with
# ./build relay and ./build docker, run from the repository root (the parent
# of the suites directory), shows the build's "image ..." lines in its own
# output, and stops before any suite when a build fails. A stub build
# records its arguments and working directory and prints an image line
# among other output.
rs8_stub() { # <exit code>
    # shellcheck disable=SC2016 # the stub expands these when it runs
    printf '%s\n' '#!/usr/bin/env bash' \
        'echo "$PWD $*" >> "$FAKE/images.calls"' \
        'echo "==> noise that stays in build.log"' \
        'echo "image relay: pulled sha256:0123 (cache:abc)"' \
        'echo "image docker: built (cache miss for cache:def; not pushed)"' \
        "exit $1" > "$CASE/build"
    chmod +x "$CASE/build"
}
run_runner_build() {
    bash "$RUNNER" --suites-dir "$CASE/suites" --tmp "$CASE/tmp" \
        --logs "$CASE/logs" --sudo "env FAKE_ROOT=1" --docker true --approved-skips "$CASE/approved" \
        > "$CASE/runner.out" 2>&1
}
new_case "$OTHER"
echo "[PASS] other" > "$FAKE/$OTHER.user.out"
rs8_stub 0
run_runner_build; rc=$?
check "RS8 the image step runs ./build relay and ./build docker from the repository root and shows their image lines" \
    "[ $rc = 0 ] && [ \"\$(cat '$FAKE/images.calls')\" = \"$CASE relay
$CASE docker\" ] \
        && grep -qx 'image relay: pulled sha256:0123 (cache:abc)' '$CASE/runner.out' \
        && grep -qx 'image docker: built (cache miss for cache:def; not pushed)' '$CASE/runner.out' \
        && ! grep -q 'noise' '$CASE/runner.out' && grep -q 'noise' '$CASE/logs/build.log' \
        && grep -q '^user $OTHER ' '$FAKE/calls'"
new_case "$OTHER"
echo "[PASS] other" > "$FAKE/$OTHER.user.out"
rs8_stub 1
run_runner_build; rc=$?
check "RS8 a failed image step stops the run before any suite" \
    "[ $rc != 0 ] && [ ! -s '$FAKE/calls' ] && grep -q 'Image build failed' '$CASE/logs/summary.md'"
echo ""
echo "test_run_all_suites.sh: ${PASS} passed, ${FAIL} failed, 0 skipped"
[ "$FAIL" -eq 0 ]
