#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_ci_images.sh: behavioral checks for scripts/ci/images, which makes
# the test images present on a continuous integration runner, pulling them
# from the image cache when their inputs have not changed.
#
# WHAT: each check runs a copy of the script in a throwaway tree against
# tests/fake-docker-registry.sh (a docker stand-in with a fake registry,
# local image list and image labels) and a stand-in lbx, and judges what
# the script DID: its exit status, the "image <name>: ..." lines it
# printed, the docker calls it made, and the fake registry and local
# images afterwards. No daemon, no network, no token.
#
#   IC1  a fingerprint is stable, 64 hex digits, the hash of --inputs
#   IC2  the inputs are exactly the files COPY and ADD copy in
#   IC3  changing any input changes the fingerprint; other files do not
#        (property check on a copy of this repository)
#   IC4  what the parser cannot account for makes the fingerprint
#        unavailable: a pull run builds, a push run fails without building
#   IC5  a push run on a miss pins the base, builds, labels, pushes and
#        reports the digest
#   IC6  a pull run on a hit pulls by digest, checks the label and the
#        repository digests, tags the local name, never builds or pushes
#   IC7  a pull run on a miss, a changed input, a registry error, a wrong
#        label or a missing repository digest builds and never pushes
#   IC8  a push run on a hit neither builds, pulls nor pushes
#   IC9  --fresh builds even on a hit; with --push it replaces the cache
#   IC10 without LBX_IMAGE_CACHE it only builds and never reads the registry
#   IC11 --push without a cache repository and a failed build fail
#   IC12 link targets, the .dockerignore, blank continuation lines and
#        nested files are inputs
#
# WHY: a pulled image stands in for a build of the pull request's own
# inputs. If the fingerprint missed an input, a pull request would be
# tested against an image that does not contain its change; if a pull
# request run could push, unreviewed code could plant an image that later
# runs trust.
#
# No check reads a script, workflow or documentation file. The checks run
# the script and inspect its effects.
#
# LLM-FRIENDLY NOTE: fixture <name> makes a tree with a fake ./build (it
# calls docker build like the real one), the script under test, and a
# Dockerfile that exercises the parser; a fake lbx answers --print-images;
# ic_run runs the script there with the fakes first on PATH and the
# LBX_IMAGE_* variables of the calling environment removed. IC3 prints its
# seed; set IC3_SEED=<n> to replay the same sample of non-input files.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

# check <description> <function>: run the function; exit 0 is a pass. Its
# output is indented, so quoted script output never looks like a result line.
check() {
    local description="$1" fn="$2" rc
    "$fn" > "$WORK/check.out" 2>&1
    rc=$?
    sed 's/^/    /' "$WORK/check.out"
    if [ "$rc" = 0 ]; then
        echo "[PASS] $description"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $description"
        FAIL=$((FAIL + 1))
    fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/lbx-ci-images-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

CACHE_REPO="ghcr.io/example-org/lbx-cache"
LABEL=lbx.ci-fingerprint
UBUNTU_A="sha256:$(printf '1%.0s' $(seq 1 64))"
UBUNTU_B="sha256:$(printf '2%.0s' $(seq 1 64))"
DIGEST_A="sha256:$(printf 'a%.0s' $(seq 1 64))"
DIGEST_B="sha256:$(printf 'b%.0s' $(seq 1 64))"
DIGEST_C="sha256:$(printf 'c%.0s' $(seq 1 64))"
RELAY_BASE="python@sha256:$(printf '3%.0s' $(seq 1 64))"

# install_script <tree>: the script under test.
install_script() {
    mkdir -p "$1/scripts/ci"
    cp "$REPO/scripts/ci/images" "$1/scripts/ci/images"
}

# fake_state <dir>: empty docker log, local images, labels; a registry
# holding only the ubuntu:24.04 base (digest UBUNTU_A); a fake docker and
# a fake lbx (it answers --print-images with the default image names).
fake_state() {
    mkdir -p "$1/bin" "$1/home"
    ln -sf "$SCRIPT_DIR/fake-docker-registry.sh" "$1/bin/docker"
    printf '%s\n' '#!/usr/bin/env bash' \
        '[ "$1" = --print-images ] && echo "sysbox=llm-in-a-box:sysbox docker=llm-in-a-box:docker vm=llm-in-a-box:vm"' > "$1/bin/lbx"
    chmod +x "$1/bin/lbx"
    : > "$1/docker.log"
    : > "$1/local"
    : > "$1/labels"
    printf 'ubuntu:24.04 %s\n' "$UBUNTU_A" > "$1/registry"
}

# fixture <name>: a fresh tree T with state F (the same directory).
fixture() {
    F="$WORK/$1"
    T="$F/tree"
    rm -rf "$F"
    mkdir -p "$T/docker/relay" "$T/docker/conf.d/sub" "$T/tests" "$T/docs"
    fake_state "$F"
    install_script "$T"
    cat > "$T/build" <<'EOB'
#!/usr/bin/env bash
# A stand-in for ./build: the same docker build calls, no prerequisites.
case "$1" in
    relay) docker build -t llm-in-a-box-relay:latest docker/relay ;;
    docker|sysbox) docker build --no-cache --build-arg "RUNTIME_TYPE=$1" -t "llm-in-a-box:$1" . ;;
    *) exit 1 ;;
esac
EOB
    chmod +x "$T/build"
    cat > "$T/Dockerfile" <<'EOD'
# a comment
FROM ubuntu:24.04 AS tools
FROM ubuntu:24.04
RUN --mount=type=bind,from=tools,source=/bin,target=/t true
ARG RUNTIME_TYPE=sysbox
RUN apt-get update && apt-get install -y \
    # a comment inside a continuation
    curl
COPY entrypoint.sh /entrypoint.sh
COPY --chown=agent:agent a.json \
     ./b.md /home/agent/
COPY docker/conf.d /etc/conf.d
COPY docker/*.service /etc/systemd/system/
ADD --chmod=755 tool.sh /usr/local/bin/tool
RUN --mount=type=cache,target=/root/.cache --mount=TYPE=Cache,target=/c true
COPY c1.txt \

     c2.txt /dst/
COPY link.sh /usr/local/bin/link
EOD
    printf 'FROM %s\nCOPY relay.py /relay.py\n' "$RELAY_BASE" > "$T/docker/relay/Dockerfile"
    echo 'print("relay")' > "$T/docker/relay/relay.py"
    for f in entrypoint.sh a.json b.md docker/conf.d/one.conf docker/conf.d/sub/two.conf \
        docker/a.service docker/b.service tool.sh README.md tests/test_x.sh docs/guide.md docker/c.timer \
        c1.txt c2.txt link-target.sh .dockerignore; do
        echo "content of $f" > "$T/$f"
    done
    chmod +x "$T/entrypoint.sh"
    ln -s link-target.sh "$T/link.sh"
}

# ic_run <command...>: run in the tree with the fakes first on PATH, the
# fake lbx as the launcher, and the calling environment's cache variables
# removed (continuous integration sets them for the real run).
ic_run() {
    (cd "$T" && env -u LBX_IMAGE_CACHE -u LBX_IMAGE_CACHE_PUSH -u LBX_IMAGE_FRESH \
        -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY \
        PATH="$F/bin:$PATH" HOME="$F/home" LBX_BIN="$F/bin/lbx" \
        FAKE_DOCKER_LOG="$F/docker.log" FAKE_LOCAL_IMAGES="$F/local" FAKE_REGISTRY="$F/registry" \
        FAKE_LABELS="$F/labels" LBX_IMAGE_RETRY_DELAY=0 "$@")
}

# images <args...>: run the script under test in the fixture tree.
images() { ic_run scripts/ci/images "$@"; }

# cached <args...>: run it with the cache configured.
cached() { ic_run env LBX_IMAGE_CACHE="$CACHE_REPO" scripts/ci/images "$@"; }

# new_machine: forget local images and the docker log, as on a fresh runner.
new_machine() { : > "$F/local"; : > "$F/docker.log"; }

# docker_called <regex>: some recorded docker call matches.
docker_called() { grep -qE "$1" "$F/docker.log"; }

# local_is <ref> <id>: the local reference names that image id.
local_is() { [ "$(awk -v r="$1" '$1 == r { i = $2 } END { print i }' "$F/local")" = "$2" ]; }

# registry_of <ref>: the fake registry's digest for a reference.
registry_of() { awk -v r="$1" '$1 == r { d = $2 } END { print d }' "$F/registry"; }

# label_of <digest>: the fingerprint label the registry holds for a digest.
label_of() { awk -v i="$1" -v k="$LABEL" '$1 == i && index($2, k "=") == 1 { v = substr($2, length(k) + 2) } END { print v }' "$F/labels"; }

say() { echo "case: $*"; }

# ═══ IC1: stable fingerprint ═════════════════════════════════════════════
# Requirement: the tag is the fingerprint, so two runs on the same tree
# must agree, or no run would ever hit.
# Theory: compute each image's fingerprint twice and compare, check the
# format (a tag of 64 hex digits), and check that it is the sha256 of what
# --inputs prints, so the logged inputs explain the tag. The docker and
# sysbox images share the Dockerfile and differ only in the build
# argument, so they must not share a fingerprint either.
ic1() {
    fixture ic1
    local image a b inputs
    for image in docker sysbox relay; do
        a="$(images --fingerprint "$image")" || { say "$image: --fingerprint failed"; return 1; }
        b="$(images --fingerprint "$image")" || return 1
        [ "$a" = "$b" ] || { say "$image: $a then $b"; return 1; }
        [[ "$a" =~ ^[0-9a-f]{64}$ ]] || { say "$image: not 64 hex digits: $a"; return 1; }
        inputs="$(images --inputs "$image")" || return 1
        [ "$(printf '%s\n' "$inputs" | sha256sum | cut -d' ' -f1)" = "$a" ] || { say "$image: not the hash of --inputs"; return 1; }
    done
    [ "$(images --fingerprint docker)" != "$(images --fingerprint relay)" ] || { say "docker and relay share a fingerprint"; return 1; }
    [ "$(images --fingerprint docker)" != "$(images --fingerprint sysbox)" ] || { say "docker and sysbox share a fingerprint"; return 1; }
}
check "IC1 a fingerprint is stable, 64 hex digits and the hash of the listed inputs" ic1

# ═══ IC2: the inputs are the copied files ════════════════════════════════
# Requirement: the fingerprint covers every file the build copies in.
# Theory: the fixture Dockerfile copies through the forms the parser must
# handle (a continuation with a comment line inside it, another with a
# blank line inside it, --chown with two sources and a ./ prefix, a
# directory with a subdirectory, a glob, ADD with --chmod, a symbolic link
# named as a source, whose target docker copies, a RUN cache mount, which
# reads no context file (also spelled in upper case, as BuildKit accepts),
# and a RUN bind mount from an earlier stage). The listed files must be
# exactly the ones docker would copy plus the .dockerignore: nothing
# missing (a missed input is a stale image) and nothing the instructions
# do not name (docker/c.timer, README.md, tests/, docs/). The architecture
# is listed too: an image only fits hosts of the architecture it was
# built on.
ic2() {
    fixture ic2
    local got want dinputs rinputs sinputs
    dinputs="$(images --inputs docker)" || return 1
    sinputs="$(images --inputs sysbox)" || return 1
    rinputs="$(images --inputs relay)" || return 1
    got="$(awk '$1 == "file" { print $2 }' <<< "$dinputs" | LC_ALL=C sort)"
    want="$(printf '%s\n' build Dockerfile entrypoint.sh a.json b.md docker/conf.d/one.conf \
        docker/conf.d/sub/two.conf docker/a.service docker/b.service tool.sh c1.txt c2.txt link-target.sh \
        .dockerignore | LC_ALL=C sort)"
    [ "$got" = "$want" ] || { say "docker inputs:"; printf '%s\n' "$got"; say "expected:"; printf '%s\n' "$want"; return 1; }
    grep -qx "base ubuntu:24.04 $UBUNTU_A" <<< "$dinputs" || { say "base image not resolved to its digest"; return 1; }
    grep -qx "build-args RUNTIME_TYPE=docker" <<< "$dinputs" || { say "build arguments missing"; return 1; }
    grep -qx "arch $(uname -m)" <<< "$dinputs" || { say "architecture missing"; return 1; }
    [ "$(grep -v '^build-args \|^image ' <<< "$sinputs")" = "$(grep -v '^build-args \|^image ' <<< "$dinputs")" ] \
        || { say "the sysbox and docker inputs differ beyond the image name and build arguments"; return 1; }
    grep -qx "build-args RUNTIME_TYPE=sysbox" <<< "$sinputs" || { say "sysbox build arguments missing"; return 1; }
    got="$(awk '$1 == "file" { print $2 }' <<< "$rinputs" | LC_ALL=C sort)"
    want="$(printf '%s\n' build docker/relay/Dockerfile relay.py | LC_ALL=C sort)"
    [ "$got" = "$want" ] || { say "relay inputs: $got"; return 1; }
    grep -qx "base $RELAY_BASE" <<< "$rinputs" || { say "pinned relay base not listed as pinned"; return 1; }
    ! docker_called '^buildx imagetools inspect .*python@' || { say "a base pinned by digest was looked up"; return 1; }
}
check "IC2 the inputs are exactly the Dockerfile, ./build, the base digest and the files COPY and ADD copy in" ic2

# ═══ IC3: every input matters, nothing else does (property) ══════════════
# Requirement: touching an input changes the fingerprint, and reuse only
# pays off if unrelated changes (the launcher, the tests, the docs) keep it.
# Theory: on a copy of THIS repository (its real Dockerfile and ./build),
# change each listed input file in turn and require a new fingerprint;
# flip the executable bit of one; move the base image tag to another
# digest. Then change a random sample of the other files and require the
# same fingerprint. The seed is printed; IC3_SEED replays the sample.
IC3_SEED="${IC3_SEED:-$RANDOM}"
ic3() {
    echo "IC3 seed: $IC3_SEED"
    RANDOM=$IC3_SEED
    F="$WORK/ic3"
    T="$F/tree"
    rm -rf "$F"
    mkdir -p "$T"
    fake_state "$F"
    (cd "$REPO" && git ls-files -z 2>/dev/null | xargs -0 -I{} cp --parents -P {} "$T/") \
        || (cd "$REPO" && tar --exclude=.git --exclude=target --exclude=test-logs -cf - . | tar -xf - -C "$T")
    install_script "$T"
    local image base now f inputs others=() n bad=0
    for image in docker relay; do
        base="$(images --fingerprint "$image")" || { say "$image: no fingerprint for this repository"; return 1; }
        inputs="$(images --inputs "$image" | awk '$1 == "file" { print $2 }')"
        local ctx=.
        [ "$image" = relay ] && ctx=docker/relay
        while IFS= read -r f; do
            local p="$T/$ctx/$f"
            [ "$f" = build ] || [ "${f#docker/relay/Dockerfile}" = "" ] && p="$T/$f"
            cp -p "$p" "$p.orig"
            echo "# changed" >> "$p"
            now="$(images --fingerprint "$image")"
            [ "$now" != "$base" ] || { say "$image: changing $f kept the fingerprint"; bad=1; }
            mv "$p.orig" "$p"
        done <<< "$inputs"
        [ "$(images --fingerprint "$image")" = "$base" ] || { say "$image: restoring the inputs did not restore the fingerprint"; bad=1; }
    done
    base="$(images --fingerprint docker)"
    chmod a-x "$T/entrypoint.sh"
    [ "$(images --fingerprint docker)" != "$base" ] || { say "the executable bit of entrypoint.sh is not an input"; bad=1; }
    chmod a+x "$T/entrypoint.sh"
    printf 'ubuntu:24.04 %s\n' "$UBUNTU_B" >> "$F/registry"
    [ "$(images --fingerprint docker)" != "$base" ] || { say "a new ubuntu:24.04 digest kept the fingerprint"; bad=1; }
    printf 'ubuntu:24.04 %s\n' "$UBUNTU_A" >> "$F/registry"
    inputs="$( (images --inputs docker | awk '$1 == "file" { print $2 }'; images --inputs relay | awk '$1 == "file" { print ($2 == "build" || index($2, "docker/relay/") == 1) ? $2 : "docker/relay/" $2 }') | sort -u)"
    while IFS= read -r f; do
        [ -f "$T/$f" ] && [ ! -L "$T/$f" ] || continue
        grep -qxF "$f" <<< "$inputs" || others+=("$f")
    done < <(cd "$T" && find . -type f ! -path './scripts/ci/*' | sed 's|^\./||' | LC_ALL=C sort)
    local dbase rbase
    dbase="$(images --fingerprint docker)"
    rbase="$(images --fingerprint relay)"
    n=${#others[@]}
    [ "$n" -gt 20 ] || { say "only $n non-input files to sample"; return 1; }
    for _ in $(seq 1 12); do
        f="${others[$((RANDOM % n))]}"
        cp -p "$T/$f" "$T/$f.orig"
        echo "# changed" >> "$T/$f"
        [ "$(images --fingerprint docker)" = "$dbase" ] || { say "changing $f (not an input) changed the docker fingerprint"; bad=1; }
        [ "$(images --fingerprint relay)" = "$rbase" ] || { say "changing $f (not an input) changed the relay fingerprint"; bad=1; }
        mv "$T/$f.orig" "$T/$f"
    done
    return "$bad"
}
check "IC3 changing any input of this repository's images changes the fingerprint; other files keep it" ic3

# ═══ IC4: unparseable instructions ═══════════════════════════════════════
# Requirement: the fingerprint must cover every input; an instruction the
# parser cannot account for could copy an input it does not see.
# Theory: each variant adds one such instruction (a RUN bind mount from
# the context, with and without type=, in upper case, or from an image by
# tag; a link whose target is missing; a base image the registry does not
# know); --fingerprint must fail, a pull run must build (and say why)
# without touching the cache, and a push run must fail without building,
# so the main-branch job shows the problem.
ic4() {
    local variant bad=0 out
    # shellcheck disable=SC2016 # the variable must reach the Dockerfile unexpanded
    local variants=(
        'COPY --from=builder /x /x'
        'ADD https://example.invalid/x.tar /x'
        'COPY $SRC /x'
        'COPY ["a.json", "/x"]'
        'COPY <<EOF /x'
        'COPY missing.txt /x'
        'COPY ../outside /x'
        'COPY nomatch*.zzz /x'
        'RUN --mount=type=bind,source=a.json,target=/x cat /x'
        'RUN --mount=source=a.json,target=/x cat /x'
        'RUN --mount=type=bind,from=alpine:3,target=/x cat /x'
        'RUN --mount=type=BIND,source=a.json,target=/x cat /x'
        'COPY dangling.sh /x'
        'FROM alpine:3'
        'escape'
    )
    for variant in "${variants[@]}"; do
        fixture ic4
        ln -s does-not-exist "$T/dangling.sh"
        if [ "$variant" = escape ]; then
            { echo '# escape=`'; cat "$T/Dockerfile"; } > "$T/Dockerfile.new" && mv "$T/Dockerfile.new" "$T/Dockerfile"
        else
            echo "$variant" >> "$T/Dockerfile"
        fi
        if images --fingerprint docker > "$F/out" 2>&1; then say "[$variant] fingerprint computed: $(cat "$F/out")"; bad=1; continue; fi
        out="$(cached docker 2>&1)" || { say "[$variant] pull run failed"; bad=1; continue; }
        grep -q '^image docker: built (fingerprint unavailable' <<< "$out" || { say "[$variant] pull run printed: $out"; bad=1; }
        docker_called '^build .*-t llm-in-a-box:docker' || { say "[$variant] pull run did not build"; bad=1; }
        ! docker_called "^(pull|push) $CACHE_REPO" || { say "[$variant] pull run touched the cache"; bad=1; }
        new_machine
        if cached --push docker > "$F/out" 2>&1; then say "[$variant] push run succeeded"; bad=1; fi
        ! docker_called '^(build|push) ' || { say "[$variant] push run built or pushed"; bad=1; }
    done
    return "$bad"
}
check "IC4 an instruction the fingerprint cannot account for: pull runs build, push runs fail without building" ic4

# ═══ IC5: push run on a miss ═════════════════════════════════════════════
# Requirement: the main-branch job fills the cache: build on a miss, push
# as <cache>:<fingerprint>, record the digest in the log.
# Theory: an empty cache; each image is pushed in its own run with its own
# push digest (A relay, B docker, C sysbox), so each label check below can
# only pass for that image's own digest. Each run must build, push under
# the fingerprint, leave that fingerprint as the label of the pushed digest
# (what pullers check), print "built and pushed <digest>", and keep the
# local name pointing at the pushed image. Before building the docker
# image it must pull ubuntu at the digest the fingerprint recorded and tag
# it ubuntu:24.04, so the build starts from that base.
ic5() {
    fixture ic5
    local out fp image local_name digest pin build_line
    for image in relay docker sysbox; do
        case "$image" in
            relay) digest="$DIGEST_A"; local_name=llm-in-a-box-relay:latest ;;
            docker) digest="$DIGEST_B"; local_name=llm-in-a-box:docker ;;
            sysbox) digest="$DIGEST_C"; local_name=llm-in-a-box:sysbox ;;
        esac
        out="$(FAKE_PUSH_DIGEST="$digest" cached --push "$image" 2>&1)" || { say "$image: run failed: $out"; return 1; }
        fp="$(images --fingerprint "$image")"
        [ "$(registry_of "$CACHE_REPO:$fp")" = "$digest" ] || { say "$image: $CACHE_REPO:$fp not in the registry"; return 1; }
        [ "$(label_of "$digest")" = "$fp" ] || { say "$image: the pushed digest's label is '$(label_of "$digest")', not $fp"; return 1; }
        grep -qx "image $image: built and pushed $digest ($CACHE_REPO:$fp)" <<< "$out" || { say "$image line missing: $out"; return 1; }
        local_is "$local_name" "$(awk -v r="$CACHE_REPO:$fp" '$1 == r { i = $2 } END { print i }' "$F/local")" \
            || { say "$image: $local_name is not the pushed image"; return 1; }
    done
    pin="$(grep -nx "tag ubuntu@$UBUNTU_A ubuntu:24.04" "$F/docker.log" | head -1 | cut -d: -f1)"
    build_line="$(grep -n '^build .*-t llm-in-a-box:docker' "$F/docker.log" | head -1 | cut -d: -f1)"
    docker_called "^pull ubuntu@$UBUNTU_A\$" || { say "ubuntu not pulled at the recorded digest"; return 1; }
    [ -n "$pin" ] && [ -n "$build_line" ] && [ "$pin" -lt "$build_line" ] || { say "ubuntu:24.04 not tagged from the recorded digest before the build"; return 1; }
}
check "IC5 a push run on a miss pins the base, builds, pushes <cache>:<fingerprint> with its label and reports the digest" ic5

# seed_cache: fill the fake registry the way the main-branch job does, then
# start a fresh machine. Each image gets its own digest (A relay, B docker).
seed_cache() {
    FAKE_PUSH_DIGEST="$DIGEST_A" cached --push relay > "$F/seed.out" 2>&1 || return 1
    FAKE_PUSH_DIGEST="$DIGEST_B" cached --push docker >> "$F/seed.out" 2>&1 || return 1
    new_machine
}

# ═══ IC6: pull run on a hit ══════════════════════════════════════════════
# Requirement: pull by fingerprint; build only on a miss; a pulled image
# must be verified to be the one expected; the log says "pulled <digest>".
# Theory: after a seed, a fresh machine's run must read the tag's digest,
# pull <cache>@<digest>, find the fingerprint label, tag the local names
# with the pulled images, print "pulled <digest>", and never build or push.
ic6() {
    fixture ic6
    seed_cache || { say "seed failed"; cat "$F/seed.out"; return 1; }
    local out fpd fpr
    out="$(cached relay docker 2>&1)" || { say "run failed: $out"; return 1; }
    fpd="$(images --fingerprint docker)"
    fpr="$(images --fingerprint relay)"
    grep -qx "image docker: pulled $DIGEST_B ($CACHE_REPO:$fpd)" <<< "$out" || { say "docker line: $out"; return 1; }
    grep -qx "image relay: pulled $DIGEST_A ($CACHE_REPO:$fpr)" <<< "$out" || { say "relay line: $out"; return 1; }
    docker_called "^pull $CACHE_REPO@$DIGEST_B\$" || { say "docker not pulled by digest"; return 1; }
    local_is llm-in-a-box:docker "$DIGEST_B" || { say "llm-in-a-box:docker is not the pulled image"; return 1; }
    local_is llm-in-a-box-relay:latest "$DIGEST_A" || { say "llm-in-a-box-relay:latest is not the pulled image"; return 1; }
    ! docker_called '^(build|push) ' || { say "built or pushed on a hit"; return 1; }
}
check "IC6 a pull run on a hit pulls by digest, verifies the label and digest, tags the local names, never builds or pushes" ic6

# ═══ IC7: pull runs that must build ══════════════════════════════════════
# Requirement: pull requests only pull; on a miss they build locally and
# do not push.
# Theory: five ways to miss, each on a fresh machine after a seed: an
# input changed since the seed (a new fingerprint), an empty cache, a
# registry error that is not "not found" (an authentication failure, as
# on a pull request whose token cannot read the package), a cached image
# whose label names another fingerprint (a tag that points at the wrong
# image), and a pulled image whose repository digests do not include the
# digest asked for. Each must build, print "built (<reason>", and never push.
ic7() {
    local bad=0 out fp pin build_line
    fixture ic7
    seed_cache || return 1
    echo "changed" >> "$T/entrypoint.sh"
    out="$(cached docker 2>&1)" || { say "changed input: run failed"; bad=1; }
    grep -q '^image docker: built (cache miss' <<< "$out" || { say "changed input: $out"; bad=1; }
    ! docker_called "^(pull|push) $CACHE_REPO" || { say "changed input: pulled or pushed"; bad=1; }

    fixture ic7
    out="$(cached docker 2>&1)" || { say "empty cache: run failed"; bad=1; }
    grep -q '^image docker: built (cache miss' <<< "$out" || { say "empty cache: $out"; bad=1; }
    ! docker_called '^push ' || { say "empty cache: pushed"; bad=1; }
    pin="$(grep -nx "tag ubuntu@$UBUNTU_A ubuntu:24.04" "$F/docker.log" | head -1 | cut -d: -f1)"
    build_line="$(grep -n '^build .*-t llm-in-a-box:docker' "$F/docker.log" | head -1 | cut -d: -f1)"
    { docker_called "^pull ubuntu@$UBUNTU_A\$" && [ -n "$pin" ] && [ -n "$build_line" ] && [ "$pin" -lt "$build_line" ]; } \
        || { say "empty cache: ubuntu not pulled and tagged at the recorded digest before the build"; bad=1; }

    fixture ic7
    seed_cache || return 1
    fp="$(images --fingerprint docker)"
    out="$(FAKE_INSPECT_ERROR_ON="$CACHE_REPO:$fp" cached docker 2>&1)" || { say "registry error: run failed"; bad=1; }
    grep -q '^image docker: built (cache unreadable' <<< "$out" || { say "registry error: $out"; bad=1; }
    ! docker_called "^(pull|push) $CACHE_REPO" || { say "registry error: pulled or pushed"; bad=1; }

    fixture ic7
    fp="$(images --fingerprint docker)"
    printf '%s %s\n' "$CACHE_REPO:$fp" "$DIGEST_B" >> "$F/registry"
    printf '%s %s=%s\n' "$DIGEST_B" "$LABEL" "$(printf '0%.0s' $(seq 1 64))" >> "$F/labels"
    out="$(cached docker 2>&1)" || { say "wrong label: run failed"; bad=1; }
    grep -q "^image docker: built (the pulled image's fingerprint label is '0" <<< "$out" || { say "wrong label: $out"; bad=1; }
    local_is llm-in-a-box:docker "$DIGEST_B" && { say "wrong label: the local name points at the refused image"; bad=1; }
    docker_called '^build .*-t llm-in-a-box:docker' || { say "wrong label: not built"; bad=1; }
    ! docker_called '^push ' || { say "wrong label: pushed"; bad=1; }

    fixture ic7
    seed_cache || return 1
    out="$(FAKE_NO_REPO_DIGESTS=1 cached docker 2>&1)" || { say "no repository digest: run failed"; bad=1; }
    grep -q "^image docker: built (the pulled image's digests () do not include $DIGEST_B" <<< "$out" || { say "no repository digest: $out"; bad=1; }
    local_is llm-in-a-box:docker "$DIGEST_B" && { say "no repository digest: the local name points at the refused image"; bad=1; }
    ! docker_called '^push ' || { say "no repository digest: pushed"; bad=1; }
    return "$bad"
}
check "IC7 a pull run builds and never pushes on a changed input, an empty cache, a registry error, a wrong label or a missing digest" ic7

# ═══ IC8: push run on a hit ══════════════════════════════════════════════
# Requirement: build only on a miss; a merge that does not change the
# images must not spend most of an hour rebuilding them.
# Theory: after a seed, a second push run must report "cached <digest>"
# and make no build, pull or push call.
ic8() {
    fixture ic8
    seed_cache || return 1
    local out
    out="$(cached --push relay docker 2>&1)" || { say "run failed: $out"; return 1; }
    grep -qx "image docker: cached $DIGEST_B ($CACHE_REPO:$(images --fingerprint docker)); not rebuilt" <<< "$out" || { say "$out"; return 1; }
    grep -q "^image relay: cached $DIGEST_A " <<< "$out" || { say "$out"; return 1; }
    ! docker_called '^(build|pull|push) ' || { say "built, pulled or pushed on a hit"; return 1; }
}
check "IC8 a push run on a hit neither builds, pulls nor pushes" ic8

# ═══ IC9: forced fresh build ═════════════════════════════════════════════
# Requirement: a switch to force a fresh build.
# Theory: after a seed, --fresh (and LBX_IMAGE_FRESH=true, the form a
# workflow input takes) must build without pulling; a pull run still must
# not push; a push run must push the new build over the cached tag.
ic9() {
    fixture ic9
    seed_cache || return 1
    local out fp
    out="$(cached --fresh docker 2>&1)" || { say "run failed"; return 1; }
    grep -q '^image docker: built (fresh build requested; not pushed)' <<< "$out" || { say "$out"; return 1; }
    ! docker_called "^(pull|push) $CACHE_REPO" || { say "--fresh pulled or pushed"; return 1; }
    new_machine
    out="$(ic_run env LBX_IMAGE_CACHE="$CACHE_REPO" LBX_IMAGE_FRESH=true scripts/ci/images docker 2>&1)" || return 1
    grep -q '^image docker: built (fresh build requested' <<< "$out" || { say "LBX_IMAGE_FRESH=true: $out"; return 1; }
    new_machine
    fp="$(images --fingerprint docker)"
    out="$(FAKE_PUSH_DIGEST="$DIGEST_A" ic_run env LBX_IMAGE_CACHE="$CACHE_REPO" LBX_IMAGE_CACHE_PUSH=1 scripts/ci/images --fresh docker 2>&1)" || { say "push run failed: $out"; return 1; }
    [ "$(registry_of "$CACHE_REPO:$fp")" = "$DIGEST_A" ] || { say "the fresh build did not replace the cached tag"; return 1; }
    grep -qx "image docker: built and pushed $DIGEST_A ($CACHE_REPO:$fp)" <<< "$out" || { say "$out"; return 1; }
}
check "IC9 --fresh and LBX_IMAGE_FRESH build on a hit; with --push the build replaces the cached tag" ic9

# ═══ IC10: no cache configured ═══════════════════════════════════════════
# Requirement: local runs and anything that does not opt in keep the old
# behavior: ./build relay, ./build docker, ./build sysbox.
# Theory: without LBX_IMAGE_CACHE (even with a seeded registry) the run
# must build all three images, print "built (no cache configured)", and
# make no registry call at all.
ic10() {
    fixture ic10
    seed_cache || return 1
    local out
    out="$(images relay docker sysbox 2>&1)" || { say "run failed"; return 1; }
    [ "$(grep -c '^image .*: built (no cache configured)$' <<< "$out")" = 3 ] || { say "$out"; return 1; }
    docker_called '^build .*-t llm-in-a-box-relay:latest' || { say "relay not built"; return 1; }
    docker_called '^build .*-t llm-in-a-box:docker' || { say "docker not built"; return 1; }
    docker_called '^build .*RUNTIME_TYPE=sysbox .*-t llm-in-a-box:sysbox' || { say "sysbox not built"; return 1; }
    ! docker_called '^(pull|push|buildx) ' || { say "the registry was used"; return 1; }
}
check "IC10 without LBX_IMAGE_CACHE the images are built and the registry is never used" ic10

# ═══ IC11: refusals and failures ═════════════════════════════════════════
# Requirement: a push needs a cache repository; a failed build must fail
# the run (the suites would otherwise test a missing or old image) and
# must push nothing.
# Theory: --push without LBX_IMAGE_CACHE exits 2 before building; with
# the fake's build failing, pull and push runs exit 1 and push nothing.
ic11() {
    fixture ic11
    local rc
    images --push docker > "$F/out" 2>&1
    rc=$?
    [ "$rc" = 2 ] || { say "--push without a cache: exit $rc"; return 1; }
    ! docker_called '^build ' || { say "built without a cache to push to"; return 1; }
    FAKE_BUILD_FAIL=1 cached docker > "$F/out" 2>&1 && { say "failed build: pull run succeeded"; return 1; }
    grep -qx 'image docker: failed' "$F/out" || { say "$(cat "$F/out")"; return 1; }
    FAKE_BUILD_FAIL=1 cached --push docker > "$F/out" 2>&1 && { say "failed build: push run succeeded"; return 1; }
    ! docker_called '^push ' || { say "pushed after a failed build"; return 1; }
}
check "IC11 --push without a cache repository and a failed build fail, pushing nothing" ic11

# ═══ IC12: inputs that are not plain named files ═════════════════════════
# Requirement: touching an input changes the fingerprint, including the
# inputs IC3's copy of this repository does not exercise.
# Theory: in the fixture, change the target of a symbolic link named as a
# source, the .dockerignore, the second source of a continuation that has
# a blank line inside it, and a file inside a copied subdirectory; each
# must change the fingerprint. Changing a file no instruction names
# (docker/c.timer, next to the globbed .service files) must not.
ic12() {
    fixture ic12
    local base f bad=0
    base="$(images --fingerprint docker)" || return 1
    for f in link-target.sh .dockerignore c2.txt docker/conf.d/sub/two.conf; do
        cp -p "$T/$f" "$T/$f.orig"
        echo "changed" >> "$T/$f"
        [ "$(images --fingerprint docker)" != "$base" ] || { say "changing $f kept the fingerprint"; bad=1; }
        mv "$T/$f.orig" "$T/$f"
    done
    echo "changed" >> "$T/docker/c.timer"
    [ "$(images --fingerprint docker)" = "$base" ] || { say "changing docker/c.timer changed the fingerprint"; bad=1; }
    return "$bad"
}
check "IC12 a link target, the .dockerignore, a source after a blank continuation line and a nested file are inputs" ic12

echo ""
echo "test_ci_images.sh: ${PASS} passed, ${FAIL} failed, 0 skipped"
[ "$FAIL" = 0 ]
