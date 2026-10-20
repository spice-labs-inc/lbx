#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# interactive-baseline-lib.sh — shared scenarios for the interactive
# baseline (sourced; defines functions only, no side effects).
#
# WHAT: runs a fixed matrix of interactive `lbx` operations against the fake
# docker (tests/fake-docker-run.sh in front of tests/fake-docker.sh) and
# writes, per scenario, the normalized docker argument log, standard output,
# standard error and exit code. Both the capture script
# (tests/capture-interactive-baseline.sh) and the regression checks in
# tests/test_llm_in_a_box_run.sh use these exact functions, so the stored
# baseline and a later run are produced the same way.
#
# WHY: the unattended mode must not change anything an interactive user
# sees. Comparing the launcher's recorded docker calls, output and exit code
# against a baseline captured from the launcher before the change is a
# behavioral comparison of program output, not of source text.
#
# Normalization replaces values that differ per run and per host with
# placeholders: the fixture root, the host user name and ids, the fake
# container ids, and the host ports chosen by --ports (the first free port
# from a fixed list, which depends on the host). Lines of the usage screen never occur in these scenarios.
#
# LLM-FRIENDLY NOTE: scenario names are the keys; `baseline_scenarios`
# lists them. `baseline_run <launcher> <scenario> <outdir> <workroot>`
# writes <outdir>/<scenario>.{argv,out,err,rc}.
# ---------------------------------------------------------------------------

baseline_scenarios() {
    printf '%s\n' docker-create docker-create-policy sysbox-create \
        docker-create-gh-token docker-create-ports docker-attach \
        docker-start dashdash-without-run \
        run-as-policy-value run-as-policy-value-after-name run-as-denied-value
}

# Build an isolated fixture: fake docker first on PATH, private HOME, state
# directory, configuration file, and the images the scenarios need.
baseline_fixture() {
    local root="$1"
    mkdir -p "$root/bin" "$root/home" "$root/state" "$root/cwd" "$root/wrap"
    ln -sf "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/fake-docker-run.sh" "$root/bin/docker"
    : > "$root/table"
    : > "$root/log"
    : > "$root/argv"
    printf '%s\n' llm-in-a-box:docker llm-in-a-box:sysbox llm-in-a-box-relay:latest > "$root/exist"
    printf '{"mode":"enforce","allow":["api.anthropic.com"],"block":[]}\n' > "$root/policy.json"
}

# Run the launcher inside a fixture. Arguments after the fixture root are
# passed to the launcher unchanged.
baseline_invoke() {
    local launcher="$1" root="$2"; shift 2
    (
        cd "$root/cwd" || exit 99
        env PATH="$root/bin:$PATH" HOME="$root/home" \
            LLMBOX_STATE_DIR="$root/state" LLMBOX_CONFIG="$root/home/.config/llm_in_a_box/config" \
            FAKE_DOCKER_LOG="$root/log" FAKE_EXISTING_FILE="$root/exist" \
            FAKE_CONTAINER_TABLE="$root/table" FAKE_ARGV_LOG="$root/argv" \
            FAKE_WRAP_STATE="$root/wrap" \
            "$launcher" "$@" </dev/null >"$root/out" 2>"$root/err"
        echo $? > "$root/rc"
    )
}

# Replace the fixture root in free text (standard output and error),
# reading standard input. Host identity values never appear there.
baseline_normalize() {
    local root="$1"
    sed -e "s#${root}#<FIXTURE>#g" \
        -e 's#(forwarding host [0-9]* -> container \([0-9]*\))#(forwarding host <HOSTPORT> -> container \1)#'
}

# Replace per-run values inside ONE argument: the fixture root wherever it
# occurs, and host identity values and fake container ids only when they
# are the whole argument (or the whole value of HOST_*=). Whole-field
# matching keeps a user name such as `runtime` from rewriting unrelated
# text such as the label `llm-in-a-box.runtime`.
baseline_field() {
    local root="$1" f="$2" u uid gid
    u="$(id -un)"; uid="$(id -u)"; gid="$(id -g)"
    f="${f//"$root"/<FIXTURE>}"
    case "$f" in
        "$u") f="<USER>" ;;
        "$uid:$gid") f="<UID>:<GID>" ;;
        "HOST_USER=$u") f="HOST_USER=<USER>" ;;
        "HOST_UID=$uid") f="HOST_UID=<UID>" ;;
        "HOST_GID=$gid") f="HOST_GID=<GID>" ;;
        fake-cid-*|fake-create-cid-*) f="<CID>" ;;
    esac
    # --ports picks the first free host port from a fixed list, which
    # depends on what else the host is running; keep the box port.
    if [[ "$f" =~ ^[0-9]+:(8080|3000)$ ]]; then
        f="<HOSTPORT>:${BASH_REMATCH[1]}"
    fi
    printf '%s' "$f"
}

# Convert the zero-byte argument log to readable text that keeps element
# boundaries: each call starts with a line `docker`, followed by one line
# per argument indented by four spaces, and calls are separated by a blank
# line. An argument containing a space stays on its own single line.
baseline_argv_lines() {
    local file="$1" root="$2" field first=1
    while IFS= read -r -d '' field; do
        if [ "$field" = "CALL" ]; then
            [ "$first" = 1 ] || printf '\n'
            printf 'docker\n'
            first=0
        else
            printf '    %s\n' "$(baseline_field "$root" "$field")"
        fi
    done < "$file"
}

baseline_run() {
    local launcher="$1" scenario="$2" outdir="$3" work="$4"
    local root="$work/$scenario"
    rm -rf "$root"
    baseline_fixture "$root"
    case "$scenario" in
        docker-create)
            baseline_invoke "$launcher" "$root" --runtime docker s1 ;;
        docker-create-policy)
            baseline_invoke "$launcher" "$root" --runtime docker --net-policy "$root/policy.json" s1 ;;
        sysbox-create)
            baseline_invoke "$launcher" "$root" --runtime sysbox s1 ;;
        docker-create-gh-token)
            GH_TOKEN=baseline-token-value baseline_invoke "$launcher" "$root" --runtime docker s1 ;;
        docker-create-ports)
            baseline_invoke "$launcher" "$root" --runtime docker --ports s1 ;;
        docker-attach)
            printf 's1|llm-in-a-box.runtime|docker|llm-in-a-box:docker|running||||%s\n' "$(id -un)" > "$root/table"
            baseline_invoke "$launcher" "$root" --runtime docker s1 ;;
        docker-start)
            # A stopped current-era session: lbx starts it, then attaches.
            printf 's1|llm-in-a-box.runtime|docker|llm-in-a-box:docker|exited||||%s\n' "$(id -un)" > "$root/table"
            baseline_invoke "$launcher" "$root" --runtime docker s1 ;;
        dashdash-without-run)
            baseline_invoke "$launcher" "$root" --runtime docker s1 -- true ;;
        # `--run` given as the value of an option that takes one is that
        # value, not a request for an unattended run.
        run-as-policy-value)
            baseline_invoke "$launcher" "$root" --runtime docker --net-policy --run s1 ;;
        run-as-policy-value-after-name)
            baseline_invoke "$launcher" "$root" --runtime docker s1 --net-policy --run ;;
        run-as-denied-value)
            baseline_invoke "$launcher" "$root" --denied --run ;;
        *) echo "unknown scenario $scenario" >&2; return 1 ;;
    esac
    mkdir -p "$outdir"
    baseline_argv_lines "$root/argv" "$root" > "$outdir/$scenario.argv"
    baseline_normalize "$root" < "$root/out" > "$outdir/$scenario.out"
    if [ "$scenario" = dashdash-without-run ]; then
        # Only the first line: the rest is the usage screen, which the
        # regression check does not compare.
        head -1 "$root/err" | baseline_normalize "$root" > "$outdir/$scenario.err"
    else
        baseline_normalize "$root" < "$root/err" > "$outdir/$scenario.err"
    fi
    cp "$root/rc" "$outdir/$scenario.rc"
}
