#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_llm_in_a_box_config.sh — behavioral tests for the config-file image
# selection (plan 2026_09_14_rename_to_lbx_and_configurable_images,
# "Using your own images" decision).
#
# WHAT (no source grep — AGENTS.md rule 10): drives the launcher and
# ./build against a fake `docker` shim (tests/fake-docker.sh) that records
# every invocation and answers from fixture files, then asserts on the
# RECORDED ARGV (which image was run/built, which labels were written),
# on exit codes, and on stderr messages. CFG1-CFG31:
#   CFG1  no config file -> default image names used (docker + sysbox)
#   CFG2  full config -> configured refs used on launch
#   CFG3  partial config -> unset keys keep defaults
#   CFG4  comment lines + blank lines ignored
#   CFG5  whitespace around key/value trimmed
#   CFG6  malformed line (no '=') -> warning + default for that key only
#   CFG7  unknown key -> warning, ignored, other keys apply
#   CFG8  empty value -> warning + default
#   CFG9  existing-but-unreadable config -> create path hard-errors
#   CFG10 LLMBOX_CONFIG env seam selects the fixture path
#   CFG11 ./build docker tags the configured name
#   CFG12 ./build vm with an EXISTING configured image -> no image build,
#         pipeline runs against the configured image
#   CFG13a ./build vm with a missing configured DEFAULT image -> builds it
#   CFG13b ./build vm with a missing configured NON-default image ->
#         error with docker pull guidance, nothing built
#   CFG14 create with configured image missing and no :latest fallback ->
#         guided error naming the RESOLVED image
#   CFG15 create with configured image missing but :latest present ->
#         falls back AND warns naming the skipped image
#   CFG16 image.relay key -> warning "not configurable"; relay build
#         still tags llm-in-a-box-relay:latest
#   CFG17 --list with unusable config -> warning + proceeds
#   CFG18 ./build docker with unusable config -> fails, no build recorded
#   CFG19 --destroy with unusable config -> warning + destroy proceeds
#   CFG20 default-path resolution: config at
#         $HOME/.config/llm_in_a_box/config used with no env override
#   CFG21 auto-detect uses CONFIG-RESOLVED image names (docker leg,
#         sysbox leg, guided-error leg)
#   CFG22 injection/validation: $(...)/backtick/pipe/space/--privileged
#         values -> warning + default; default arrives as ONE argv token;
#         no marker file created (parser is a reader); warning does not
#         echo the raw payload (sanitized)
#   CFG23 file trust: symlink / directory / foreign-owned / group-writable
#         at the config path -> unusable handling
#   CFG24 duplicate keys -> LAST wins
#   CFG25 value containing '=' or '#' -> invalid ref -> warning + default
#   CFG26 --print-images contract: exact stdout + exit 0; unusable
#         config -> non-zero + stderr naming the file
#   CFG27 attach of an EXISTING session with unusable config -> warning +
#         attach proceeds (image is never resolved on the attach path)
#   CFG28 mixed valid + invalid keys in one file -> per-key behavior
#   CFG29 sourced warn-class contract: llm_box_load_config called with no
#         operation flags never hard-errors
#   CFG30 vm provenance: ./build vm writes the configured ref to the
#         base dir's from-image record; vm preflight warns when a
#         session's base record differs from the configured image
#   CFG31 config path under a non-searchable parent -> unusable (only
#         ENOENT is "missing")
#
# WHY: the config file controls which image runs as the session — the
# single most security-relevant user input in the launcher. Each check
# pins one contract clause (defaults, overrides, syntax, validation,
# trust, severity-by-operation-class, build parity, provenance) so the
# contract in the plan section 5 cannot silently drift. The fake docker
# makes every assertion deterministic on any host (this box's docker
# daemon is dead; other hosts may lack sysbox-runc or the images).
#
# RED-PHASE HISTORY: this suite was written against the old
# launcher (the old bash launcher) using the old seams (BOX_STATE_DIR), so
# phase 1 could prove every check red without touching the real
# ~/.box-of-claude; phase 2 renamed the fixture plumbing (seams,
# launcher path) with the launcher. The assertions are the spec.
#
# LLM-FRIENDLY NOTE: the fake docker (tests/fake-docker.sh) answers
# exactly the subcommands the launcher/build issue (see its header). The
# FAKE_EXISTING_FILE holds image refs that "exist"; FAKE_CONTAINER_TABLE
# holds containers in `name|runtime_label|image|state|hostconfig|policy`
# form; FAKE_DOCKER_LOG receives one line per docker invocation. Launch
# checks assert on the docker `run` line: it ends with the image ref as
# the LAST argv token. Message-string assertions use the contract's
# stable texts (documented in the execution state file):
#   WARNING:.../ ERROR: cannot read config '<path>'. /
#   ERROR: Image '<ref>' not found. / Build it first: ./build <rt> /
#   No llm-in-a-box image found and no suitable runtime detected. /
#   WARNING: configured image '<ref>' is missing; falling back to
#   '<legacy>'. / ERROR: configured vm image '<ref>' is not present
#   locally; pull it first: / docker pull <ref> /
#   note: session '<name>' is a old (legacy) session — consider
#   re-creating it with lbx. /
#   WARNING: session base was built from image '<old>', but the
#   configured vm image is '<new>'.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOC="${LBX_BIN:-${SCRIPT_DIR}/../target/debug/lbx}"
export LLMBOX_SCRIPT_DIR="$SCRIPT_DIR/.."
BUILD="${SCRIPT_DIR}/../build"

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

# ── Fake docker fixture helpers ─────────────────────────────────────────────
# Each check gets a fresh bin dir (docker symlink), log, existence set,
# container table, HOME fixture and state fixture. Names carry the check
# id so stray files are attributable.
CFGROOT=/tmp/llmcfg
mkdir -p "$CFGROOT"
rm -rf "$CFGROOT"/*

fake_docker() {
    # usage: fake_docker <tag>  — fresh bin dir (docker symlink), log,
    # existence set, container table, HOME fixture and state fixture.
    local tag="$1"
    rm -rf "/tmp/llmcfg-bin-$tag" "/tmp/llmcfg-home-$tag" "/tmp/llmcfg-state-$tag"
    mkdir -p "/tmp/llmcfg-bin-$tag" "/tmp/llmcfg-home-$tag" "/tmp/llmcfg-state-$tag"
    ln -sf "$SCRIPT_DIR/fake-docker.sh" "/tmp/llmcfg-bin-$tag/docker"
    : > "/tmp/llmcfg-log-$tag"
    : > "/tmp/llmcfg-exist-$tag"
    : > "/tmp/llmcfg-table-$tag"
    rm -f "/tmp/llmcfg-cfg-$tag"
}

# Seed the existence set with BOTH the current defaults (so the OLD
# launcher reaches the docker run and fails red for the RIGHT reason —
# wrong image name / missing label) and the NEW defaults (so phase 2
# needs no fixture-content change, only seam renames).
seed_defaults() {
    local tag="$1"
    printf 'box-of-claude:sysbox\nbox-of-claude:docker\nbox-of-claude:vm\nbox-of-claude:latest\nllm-in-a-box:sysbox\nllm-in-a-box:docker\nllm-in-a-box:vm\nllm-in-a-box:latest\n' >> "/tmp/llmcfg-exist-$tag"
}

seed_refs() {
    local tag="$1" refs="$2"
    printf '%b\n' "$refs" >> "/tmp/llmcfg-exist-$tag"
}

write_cfg() {
    local tag="$1" content="$2"
    printf '%b' "$content" > "/tmp/llmcfg-cfg-$tag"
}

# The env prefix used inside check strings (evaluated by eval at check
# time; the unquoted $PATH must EXPAND at eval time, so the prefix is
# emitted unquoted — fixture paths contain no spaces).
EV() {
    echo "PATH=/tmp/llmcfg-bin-$1:\$PATH FAKE_DOCKER_LOG=/tmp/llmcfg-log-$1 FAKE_EXISTING_FILE=/tmp/llmcfg-exist-$1 FAKE_CONTAINER_TABLE=/tmp/llmcfg-table-$1 HOME=/tmp/llmcfg-home-$1"
}

# ── CFG1: no config file -> defaults ───────────────────────────────────────
# Requirement: a missing config file is not an error; the launcher uses
# the default image names (llm-in-a-box:<runtime>). Theory: the default
# names are the contract's baseline — every other CFG check compares
# against them, so this check pins them via the docker run argv.
# Why not a source grep: asserts the RECORDED docker argv, the behavior.
fake_docker c1
seed_defaults c1
check "CFG1 docker leg: no config -> default image llm-in-a-box:docker on launch" \
    "cd '/tmp/llmcfg-state-c1' && $(EV c1) '$BOC' --runtime docker cfg1sess </dev/null >/tmp/llmcfg-c1.log 2>&1; \
        grep -q ' llm-in-a-box:docker\$' /tmp/llmcfg-log-c1"

check "CFG1 sysbox leg: no config -> default image llm-in-a-box:sysbox on launch" \
    "cd '/tmp/llmcfg-state-c1' && $(EV c1) '$BOC' --runtime sysbox cfg1b </dev/null >/tmp/llmcfg-c1b.log 2>&1; \
        grep -q ' llm-in-a-box:sysbox\$' /tmp/llmcfg-log-c1"

# ── CFG2: full config -> configured refs ───────────────────────────────────
# Requirement: all three keys override the defaults. Theory: the run argv
# is the observable interface — the launcher can only run what it
# resolved, so the argv proves the resolution.
fake_docker c2
seed_defaults c2
seed_refs c2 'myorg/d2:1\nmyorg/s2:1\n'
write_cfg c2 'image.docker=myorg/d2:1\nimage.sysbox=myorg/s2:1\nimage.vm=myorg/v2:1\n'
check "CFG2 docker leg: configured ref reaches the docker run argv" \
    "cd '/tmp/llmcfg-state-c2' && $(EV c2) LLMBOX_CONFIG='/tmp/llmcfg-cfg-c2' '$BOC' --runtime docker cfg2sess </dev/null >/tmp/llmcfg-c2.log 2>&1; \
        grep -q ' myorg/d2:1\$' /tmp/llmcfg-log-c2"

check "CFG2 sysbox leg: configured sysbox ref reaches the docker run argv" \
    "cd '/tmp/llmcfg-state-c2' && $(EV c2) LLMBOX_CONFIG='/tmp/llmcfg-cfg-c2' '$BOC' --runtime sysbox cfg2b </dev/null >/tmp/llmcfg-c2b.log 2>&1; \
        grep -q ' myorg/s2:1\$' /tmp/llmcfg-log-c2"

# ── CFG3: partial config -> unset keys keep defaults ───────────────────────
# Requirement: a missing key means "use the built-in default" for THAT
# key; other keys apply. Theory: partial overrides are the common real
# use (one custom image, rest default).
fake_docker c3
seed_defaults c3
seed_refs c3 'myorg/d3:1\n'
write_cfg c3 'image.docker=myorg/d3:1\n'
check "CFG3 docker leg: configured ref used" \
    "cd '/tmp/llmcfg-state-c3' && $(EV c3) LLMBOX_CONFIG='/tmp/llmcfg-cfg-c3' '$BOC' --runtime docker cfg3sess </dev/null >/tmp/llmcfg-c3.log 2>&1; \
        grep -q ' myorg/d3:1\$' /tmp/llmcfg-log-c3"

check "CFG3 sysbox leg: unset key keeps the default llm-in-a-box:sysbox" \
    "cd '/tmp/llmcfg-state-c3' && $(EV c3) LLMBOX_CONFIG='/tmp/llmcfg-cfg-c3' '$BOC' --runtime sysbox cfg3b </dev/null >/tmp/llmcfg-c3b.log 2>&1; \
        grep -q ' llm-in-a-box:sysbox\$' /tmp/llmcfg-log-c3"

# ── CFG4: comment lines + blank lines ignored ──────────────────────────────
# Requirement: '#' at line start and empty lines are not parsed. Theory:
# the file is hand-written by users; comments are the documentation of
# the file itself.
fake_docker c4
seed_defaults c4
seed_refs c4 'myorg/d4:1\n'
write_cfg c4 '# user images\n\n   \nimage.docker=myorg/d4:1\n'
check "CFG4 comment and blank lines are ignored, key still applies" \
    "cd '/tmp/llmcfg-state-c4' && $(EV c4) LLMBOX_CONFIG='/tmp/llmcfg-cfg-c4' '$BOC' --runtime docker cfg4sess </dev/null >/tmp/llmcfg-c4.log 2>&1; \
        grep -q ' myorg/d4:1\$' /tmp/llmcfg-log-c4"

# ── CFG5: whitespace trimmed ───────────────────────────────────────────────
# Requirement: spaces around the '=' and trailing spaces are trimmed.
# Theory: hand-edited files accumulate stray spaces; a strict parser
# would turn them into "unknown key" warnings for no reason.
fake_docker c5
seed_defaults c5
seed_refs c5 'myorg/d5:1\n'
write_cfg c5 'image.docker = myorg/d5:1   \n'
check "CFG5 whitespace around key and value is trimmed" \
    "cd '/tmp/llmcfg-state-c5' && $(EV c5) LLMBOX_CONFIG='/tmp/llmcfg-cfg-c5' '$BOC' --runtime docker cfg5sess </dev/null >/tmp/llmcfg-c5.log 2>&1; \
        grep -q ' myorg/d5:1\$' /tmp/llmcfg-log-c5"

# ── CFG6: malformed line -> warning + default for that key only ───────────
# Requirement: a line without '=' warns and that key keeps its default;
# other keys still apply. Theory: one broken line must not break the
# whole file (per-key granularity is the contract).
fake_docker c6
seed_defaults c6
seed_refs c6 'myorg/d6:1\n'
write_cfg c6 'image.docker myorg/d6:1\nimage.sysbox=myorg/s6:1\n'
check "CFG6 malformed line warns and defaults; other keys still apply" \
    "cd '/tmp/llmcfg-state-c6' && $(EV c6) LLMBOX_CONFIG='/tmp/llmcfg-cfg-c6' '$BOC' --runtime sysbox cfg6sess </dev/null >/tmp/llmcfg-c6.log 2>&1; \
        grep -q 'WARNING' /tmp/llmcfg-c6.log \
        && grep -q ' myorg/s6:1\$' /tmp/llmcfg-log-c6"

# ── CFG7: unknown key -> warning, ignored, other keys apply ────────────────
# Requirement: unknown keys (typos, future keys) warn and are ignored.
fake_docker c7
seed_defaults c7
seed_refs c7 'myorg/d7:1\n'
write_cfg c7 'image.dockr=myorg/typo:1\nimage.docker=myorg/d7:1\n'
check "CFG7 unknown key warns, is ignored, valid keys apply" \
    "cd '/tmp/llmcfg-state-c7' && $(EV c7) LLMBOX_CONFIG='/tmp/llmcfg-cfg-c7' '$BOC' --runtime docker cfg7sess </dev/null >/tmp/llmcfg-c7.log 2>&1; \
        grep -q 'WARNING' /tmp/llmcfg-c7.log \
        && grep -q ' myorg/d7:1\$' /tmp/llmcfg-log-c7"

# ── CFG8: empty value -> warning + default ─────────────────────────────────
fake_docker c8
seed_defaults c8
write_cfg c8 'image.docker=\n'
check "CFG8 empty value warns and keeps the default" \
    "cd '/tmp/llmcfg-state-c8' && $(EV c8) LLMBOX_CONFIG='/tmp/llmcfg-cfg-c8' '$BOC' --runtime docker cfg8sess </dev/null >/tmp/llmcfg-c8.log 2>&1; \
        grep -q 'WARNING' /tmp/llmcfg-c8.log \
        && grep -q ' llm-in-a-box:docker\$' /tmp/llmcfg-log-c8"

# ── CFG9: existing-but-unreadable config -> hard error on create ──────────
# Requirement (read-failure rule): a config that exists but cannot be
# READ is unusable, and the CREATE path hard-errors naming the file
# before running anything. Theory: silently using defaults the user did
# not choose would run the wrong image. Chmod-000 is the fixture; it
# requires a non-root run (root can read anything).
if [ "$(id -u)" = 0 ]; then
    skip "CFG9 unreadable config hard-errors on create, naming the file, and runs nothing (chmod-000 fixture requires a non-root run)"
else
    fake_docker c9
    seed_defaults c9
    write_cfg c9 'image.docker=myorg/d9:1\n'
    chmod 000 "/tmp/llmcfg-cfg-c9"
    check "CFG9 unreadable config hard-errors on create, naming the file, and runs nothing" \
        "cd '/tmp/llmcfg-state-c9' && $(EV c9) LLMBOX_CONFIG='/tmp/llmcfg-cfg-c9' '$BOC' --runtime docker cfg9sess </dev/null >/tmp/llmcfg-c9.log 2>&1; [ \$? -ne 0 ] \
            && grep -q 'cannot read config' /tmp/llmcfg-c9.log \
            && ! grep -q '^run ' /tmp/llmcfg-log-c9"
    chmod 600 "/tmp/llmcfg-cfg-c9"
fi

# ── CFG10: LLMBOX_CONFIG env seam selects the fixture path ─────────────────
# Requirement: the config path resolves from $LLMBOX_CONFIG. Theory: the
# seam is the test/CI hook; without it tests could not point at fixtures
# without clobbering a real user's file.
fake_docker c10
seed_defaults c10
seed_refs c10 'myorg/seam:9\n'
write_cfg c10 'image.docker=myorg/seam:9\n'
check "CFG10 LLMBOX_CONFIG seam selects the fixture config" \
    "cd '/tmp/llmcfg-state-c10' && $(EV c10) LLMBOX_CONFIG='/tmp/llmcfg-cfg-c10' '$BOC' --runtime docker cfg10sess </dev/null >/tmp/llmcfg-c10.log 2>&1; \
        grep -q ' myorg/seam:9\$' /tmp/llmcfg-log-c10"

# ── CFG11: ./build docker tags the configured name ─────────────────────────
# Requirement (build parity): ./build tags the CONFIGURED docker image
# name, so build and launch cannot silently disagree. Theory: the docker
# build -t flag is the build's observable interface.
fake_docker c11
write_cfg c11 'image.docker=myorg/b11:1\n'
check "CFG11 build docker tags the configured name" \
    "cd '/tmp/llmcfg-state-c11' && $(EV c11) LLMBOX_CONFIG='/tmp/llmcfg-cfg-c11' bash '$BUILD' docker >/tmp/llmcfg-c11.log 2>&1; \
        grep -q '\-t myorg/b11:1 ' /tmp/llmcfg-log-c11"

# ── CFG12: ./build vm with an EXISTING configured image ────────────────────
# Requirement: when the configured vm image is already present, the image
# build is SKIPPED and the base-disk pipeline (probe + create/export/run)
# runs against the configured image. Theory: the skip is proven by an
# EMPTY docker build log; the pipeline image is proven by the create/run
# argv carrying the configured ref.
fake_docker c12
seed_refs c12 'myorg/vm12:1\n'
write_cfg c12 'image.vm=myorg/vm12:1\n'
check "CFG12 build vm with existing configured image: no docker build, pipeline uses the configured image" \
    "cd '/tmp/llmcfg-state-c12' && $(EV c12) LLMBOX_CONFIG='/tmp/llmcfg-cfg-c12' bash '$BUILD' vm >/tmp/llmcfg-c12.log 2>&1; \
        ! grep -q '^build ' /tmp/llmcfg-log-c12 \
        && grep -q 'create myorg/vm12:1' /tmp/llmcfg-log-c12 \
        && grep -q 'myorg/vm12:1' /tmp/llmcfg-c12.log"

# ── CFG13a: ./build vm with a missing configured DEFAULT image ─────────────
# Requirement: only the DEFAULT names are auto-built; the missing default
# vm image is built (tagged with the default name), then probed, then the
# base disk is built from it.
fake_docker c13a
write_cfg c13a 'image.vm=llm-in-a-box:vm\n'
check "CFG13a build vm with missing DEFAULT image builds it tagged with the default name" \
    "cd '/tmp/llmcfg-state-c13a' && $(EV c13a) LLMBOX_CONFIG='/tmp/llmcfg-cfg-c13a' bash '$BUILD' vm >/tmp/llmcfg-c13a.log 2>&1; \
        grep -q '\-t llm-in-a-box:vm ' /tmp/llmcfg-log-c13a \
        && grep -q 'Built llm-in-a-box:vm successfully' /tmp/llmcfg-c13a.log"

# ── CFG13b: ./build vm with a missing configured NON-default image ─────────
# Requirement: a missing non-default configured ref is an ERROR with
# docker pull guidance — the project image is NEVER built under the
# user's tag (silent wrong-image substitution). Theory: the error must
# appear before any docker build.
fake_docker c13b
write_cfg c13b 'image.vm=myorg/customvm:1\n'
check "CFG13b build vm with missing non-default image errors with pull guidance, nothing built" \
    "cd '/tmp/llmcfg-state-c13b' && $(EV c13b) LLMBOX_CONFIG='/tmp/llmcfg-cfg-c13b' bash '$BUILD' vm >/tmp/llmcfg-c13b.log 2>&1; [ \$? -ne 0 ] \
        && grep -q 'pull it first' /tmp/llmcfg-c13b.log \
        && ! grep -q '^build ' /tmp/llmcfg-log-c13b"

# ── CFG14: create, configured image missing, no :latest fallback ──────────
# Requirement: the guided error names the RESOLVED image and tells the
# user to build it. Theory: the message must be actionable; the image
# NAME in the message is what pins the resolution (red-phase history:
# the old message named box-of-claude:docker).
fake_docker c14
check "CFG14 missing configured image (no fallback) errors naming the RESOLVED image" \
    "cd '/tmp/llmcfg-state-c14' && $(EV c14) LLMBOX_CONFIG='/tmp/llmcfg-cfg-c14' '$BOC' --runtime docker cfg14sess </dev/null >/tmp/llmcfg-c14.log 2>&1; [ \$? -ne 0 ] \
        && grep -q \"Image 'llm-in-a-box:docker' not found\" /tmp/llmcfg-c14.log \
        && grep -q 'Build it first:  ./build docker' /tmp/llmcfg-c14.log"

# ── CFG15: create, configured image missing, :latest present -> fallback ──
# Requirement: the IMAGE_LEGACY fallback semantics are preserved AND the
# fallback warns naming the skipped configured image (a silent fallback
# could run the wrong image unnoticed).
fake_docker c15
seed_refs c15 'llm-in-a-box:latest\n'
write_cfg c15 'image.docker=myorg/gone15:1\n'
check "CFG15 missing configured image falls back to llm-in-a-box:latest WITH a warning naming it" \
    "cd '/tmp/llmcfg-state-c15' && $(EV c15) LLMBOX_CONFIG='/tmp/llmcfg-cfg-c15' '$BOC' --runtime docker cfg15sess </dev/null >/tmp/llmcfg-c15.log 2>&1; \
        grep -q 'falling back to llm-in-a-box:latest' /tmp/llmcfg-c15.log \
        && grep -q 'WARNING' /tmp/llmcfg-c15.log \
        && grep -q 'myorg/gone15:1' /tmp/llmcfg-c15.log \
        && grep -q ' llm-in-a-box:latest\$' /tmp/llmcfg-log-c15"

# ── CFG16: image.relay is not configurable ─────────────────────────────────
# Requirement: the relay image is an internal implementation detail; a
# config key for it warns and is ignored; the relay build still tags
# llm-in-a-box-relay:latest.
fake_docker c16
seed_defaults c16
seed_refs c16 'myorg/d16:1\n'
write_cfg c16 'image.relay=evil/relay:1\nimage.docker=myorg/d16:1\n'
check "CFG16 relay key warns and is ignored; session image still applies" \
    "cd '/tmp/llmcfg-state-c16' && $(EV c16) LLMBOX_CONFIG='/tmp/llmcfg-cfg-c16' '$BOC' --runtime docker cfg16sess </dev/null >/tmp/llmcfg-c16.log 2>&1; \
        grep -q 'not configurable' /tmp/llmcfg-c16.log \
        && grep -q ' myorg/d16:1\$' /tmp/llmcfg-log-c16"

check "CFG16 relay build still tags llm-in-a-box-relay:latest" \
    "cd '/tmp/llmcfg-state-c16' && $(EV c16) LLMBOX_CONFIG='/tmp/llmcfg-cfg-c16' bash '$BUILD' relay >/tmp/llmcfg-c16r.log 2>&1; \
        grep -q '\-t llm-in-a-box-relay:latest ' /tmp/llmcfg-log-c16"

# ── CFG17: --list with unusable config -> warning + proceeds ───────────────
# Requirement (recovery lockout): cleanup/state operations must never be
# blocked by a broken config — they warn loudly and proceed.
if [ "$(id -u)" = 0 ]; then
    skip "CFG17 --list with unusable config warns and proceeds (chmod-000 fixture requires a non-root run)"
else
    fake_docker c17
    write_cfg c17 'image.docker=myorg/x:1\n'
    chmod 000 "/tmp/llmcfg-cfg-c17"
    check "CFG17 --list with unusable config warns and proceeds" \
        "cd '/tmp/llmcfg-state-c17' && $(EV c17) LLMBOX_CONFIG='/tmp/llmcfg-cfg-c17' '$BOC' --list >/tmp/llmcfg-c17.log 2>&1; [ \$? -eq 0 ] \
            && grep -q 'WARNING' /tmp/llmcfg-c17.log \
            && grep -q 'NAME' /tmp/llmcfg-c17.log"
    chmod 600 "/tmp/llmcfg-cfg-c17"
fi

# ── CFG17b: the env-parity keys are accepted (whitelist) ────────────────────
# Requirement (2026-09-20): state.dir / vm.mem / vm.cpus / vm.accel /
# vm.store.size / vm.store.disable / vm.missing / runtime.default are
# valid config keys (env-var parity); none may warn as "unknown key".
# Theory: a config carrying all of them plus a valid image ref is loaded
# silently for a cleanup op (--list).
fake_docker c17b
write_cfg c17b 'image.docker=myorg/x:1\nstate.dir=/tmp/cfg17b-statedir\nvm.mem=2048\nvm.cpus=2\nvm.accel=tcg\nvm.store.size=64M\nvm.store.disable=1\nvm.missing=ssh\nruntime.default=docker\n'
check "CFG17b all env-parity config keys are accepted without warning" \
    "cd '/tmp/llmcfg-state-c17b' && $(EV c17b) LLMBOX_CONFIG='/tmp/llmcfg-cfg-c17b' '$BOC' --list >/tmp/llmcfg-c17b.log 2>&1; [ \$? -eq 0 ] \
        && ! grep -q 'unknown key' /tmp/llmcfg-c17b.log \
        && grep -q 'NAME' /tmp/llmcfg-c17b.log"

# ── CFG18: ./build with unusable config -> fails via --print-images ────────
# Requirement: the build consumes the config through the launcher's
# --print-images; an unusable config must abort the build BEFORE any
# docker build (build/launch must never silently disagree).
if [ "$(id -u)" = 0 ]; then
    skip "CFG18 build docker with unusable config fails, no docker build recorded (chmod-000 fixture requires a non-root run)"
else
    fake_docker c18
    write_cfg c18 'image.docker=myorg/x:1\n'
    chmod 000 "/tmp/llmcfg-cfg-c18"
    check "CFG18 build docker with unusable config fails, no docker build recorded" \
        "cd '/tmp/llmcfg-state-c18' && $(EV c18) LLMBOX_CONFIG='/tmp/llmcfg-cfg-c18' bash '$BUILD' docker >/tmp/llmcfg-c18.log 2>&1; [ \$? -ne 0 ] \
            && grep -q 'cannot read config' /tmp/llmcfg-c18.log \
            && ! grep -q '^build ' /tmp/llmcfg-log-c18"
    chmod 600 "/tmp/llmcfg-cfg-c18"
fi

# ── CFG19: --destroy with unusable config -> warning + destroy proceeds ────
# Requirement: destroy must never be locked out by a broken config — the
# one operation a user needs to recover a session.
if [ "$(id -u)" = 0 ]; then
    skip "CFG19 --destroy with unusable config warns and destroys (chmod-000 fixture requires a non-root run)"
else
    fake_docker c19
    printf 'cfg19sess|box-of-claude.runtime|docker|box-of-claude:docker|running|||\n' > /tmp/llmcfg-table-c19
    write_cfg c19 'image.docker=myorg/x:1\n'
    chmod 000 "/tmp/llmcfg-cfg-c19"
    check "CFG19 --destroy with unusable config warns and destroys" \
        "cd '/tmp/llmcfg-state-c19' && $(EV c19) LLMBOX_CONFIG='/tmp/llmcfg-cfg-c19' '$BOC' --destroy cfg19sess </dev/null >/tmp/llmcfg-c19.log 2>&1; [ \$? -eq 0 ] \
            && grep -q 'WARNING' /tmp/llmcfg-c19.log \
            && grep -q 'Removing container' /tmp/llmcfg-c19.log"
    chmod 600 "/tmp/llmcfg-cfg-c19"
fi

# ── CFG20: default-path resolution (no env override) ───────────────────────
# Requirement: with no LLMBOX_CONFIG, the config is read from
# $HOME/.config/llm_in_a_box/config. Theory: this pins the documented
# location claim (phase 3 maps the docs claim to this check).
fake_docker c20
seed_defaults c20
seed_refs c20 'myorg/defpath:1\n'
mkdir -p /tmp/llmcfg-home-c20/.config/llm_in_a_box
printf 'image.docker=myorg/defpath:1\n' > /tmp/llmcfg-home-c20/.config/llm_in_a_box/config
check "CFG20 config at the default path is used with no env override" \
    "cd '/tmp/llmcfg-state-c20' && $(EV c20) '$BOC' --runtime docker cfg20sess </dev/null >/tmp/llmcfg-c20.log 2>&1; \
        grep -q ' myorg/defpath:1\$' /tmp/llmcfg-log-c20"

# ── CFG21: auto-detect uses the configured image names ─────────────────────
# Requirement: auto-detection keys on the CONFIG-RESOLVED images (default
# llm-in-a-box:*); the README claim "checks which configured images
# exist" is pinned here.
fake_docker c21
write_cfg c21 'image.docker=myorg/ad21:1\n'
seed_refs c21 'myorg/ad21:1\n'
check "CFG21 auto-detect docker leg: configured docker image present -> docker selected" \
    "cd '/tmp/llmcfg-state-c21' && $(EV c21) LLMBOX_CONFIG='/tmp/llmcfg-cfg-c21' '$BOC' cfg21sess </dev/null >/tmp/llmcfg-c21.log 2>&1; \
        grep -q 'Auto-detected runtime: docker' /tmp/llmcfg-c21.log"

fake_docker c21b
write_cfg c21b 'image.sysbox=myorg/as21:1\n'
seed_refs c21b 'myorg/as21:1\n'
check "CFG21 auto-detect sysbox leg: configured sysbox image present -> sysbox selected" \
    "cd '/tmp/llmcfg-state-c21b' && $(EV c21b) LLMBOX_CONFIG='/tmp/llmcfg-cfg-c21b' '$BOC' cfg21bsess </dev/null >/tmp/llmcfg-c21b.log 2>&1; \
        grep -q 'Auto-detected runtime: sysbox' /tmp/llmcfg-c21b.log"

fake_docker c21c
write_cfg c21c 'image.docker=myorg/missing21:1\n'
check "CFG21 auto-detect guided error: no configured image -> error naming llm-in-a-box" \
    "cd '/tmp/llmcfg-state-c21c' && $(EV c21c) LLMBOX_CONFIG='/tmp/llmcfg-cfg-c21c' '$BOC' cfg21csess </dev/null >/tmp/llmcfg-c21c.log 2>&1; [ \$? -ne 0 ] \
        && grep -q 'No llm-in-a-box image found' /tmp/llmcfg-c21c.log"

# ── CFG22: injection / validation — the parser is a reader ─────────────────
# Requirement: values outside the reference charset (whitespace, control
# chars, shell metacharacters, leading dashes) warn and fall back to the
# default; the parser never executes config content; the value arrives as
# exactly ONE argv token; the warning does not echo the raw payload.
# Theory: a config file is a trust boundary (the value selects the image
# that runs); a reader-only parser plus charset validation closes command
# injection and flag-shape injection. The marker file proves nothing was
# evaluated; the single-token argv proves nothing was word-split.
fake_docker c22
seed_defaults c22
write_cfg c22 'image.docker=\$(touch /tmp/llmcfg-pwned-22); touch /tmp/llmcfg-pwned2-22\nimage.sysbox=\`touch /tmp/llmcfg-pwned-22\`\nimage.vm=evil --privileged\n'
rm -f /tmp/llmcfg-pwned-22 /tmp/llmcfg-pwned2-22
check "CFG22 injection values warn, default ref arrives as one argv token, nothing executed, warning sanitized" \
    "cd '/tmp/llmcfg-state-c22' && $(EV c22) LLMBOX_CONFIG='/tmp/llmcfg-cfg-c22' '$BOC' --runtime docker cfg22sess </dev/null >/tmp/llmcfg-c22.log 2>&1; \
        grep -q 'WARNING' /tmp/llmcfg-c22.log \
        && grep -q ' llm-in-a-box:docker\$' /tmp/llmcfg-log-c22 \
        && [ ! -e /tmp/llmcfg-pwned-22 ] && [ ! -e /tmp/llmcfg-pwned2-22 ] \
        && ! grep -q 'pwned' /tmp/llmcfg-c22.log"

# ── CFG23: file trust ──────────────────────────────────────────────────────
# Requirement: the config path must be a regular file, not a symlink, not
# a directory, owned by the invoking user, not group/world-writable —
# mirroring the store-image hardening. Violations are unusable (hard
# error on create, warning on cleanup). Theory: a hostile process (or the
# box's guest, which can write the HOME-ish areas) must not be able to
# redirect the config.
fake_docker c23a
seed_defaults c23a
printf 'image.docker=myorg/real:1\n' > /tmp/llmcfg-cfg-real-c23a
ln -sf /tmp/llmcfg-cfg-real-c23a /tmp/llmcfg-cfg-c23a
check "CFG23 symlink config path is refused (hard error on create)" \
    "cd '/tmp/llmcfg-state-c23a' && $(EV c23a) LLMBOX_CONFIG='/tmp/llmcfg-cfg-c23a' '$BOC' --runtime docker cfg23sess </dev/null >/tmp/llmcfg-c23a.log 2>&1; [ \$? -ne 0 ] \
        && grep -q 'cannot read config' /tmp/llmcfg-c23a.log"

fake_docker c23b
mkdir -p /tmp/llmcfg-cfg-c23b
check "CFG23 directory at the config path is refused (hard error on create)" \
    "cd '/tmp/llmcfg-state-c23b' && $(EV c23b) LLMBOX_CONFIG='/tmp/llmcfg-cfg-c23b' '$BOC' --runtime docker cfg23sess </dev/null >/tmp/llmcfg-c23b.log 2>&1; [ \$? -ne 0 ] \
        && grep -q 'cannot read config' /tmp/llmcfg-c23b.log"

fake_docker c23c
printf 'image.docker=myorg/x:1\n' > /tmp/llmcfg-cfg-c23c
chmod 664 /tmp/llmcfg-cfg-c23c
check "CFG23 group-writable config is refused (hard error on create)" \
    "cd '/tmp/llmcfg-state-c23c' && $(EV c23c) LLMBOX_CONFIG='/tmp/llmcfg-cfg-c23c' '$BOC' --runtime docker cfg23sess </dev/null >/tmp/llmcfg-c23c.log 2>&1; [ \$? -ne 0 ] \
        && grep -q 'cannot read config' /tmp/llmcfg-c23c.log"
chmod 600 /tmp/llmcfg-cfg-c23c

# "Foreign" means owned by anyone but the invoking user: root when the
# suite runs as a normal user, nobody (65534) when it runs as root.
c23_foreign=0
[ "$(id -u)" = 0 ] && c23_foreign=65534
if chown "$c23_foreign:$c23_foreign" /tmp/llmcfg-cfg-c23c 2>/dev/null; then
    check "CFG23 foreign-owned config is refused (hard error on create)" \
        "cd '/tmp/llmcfg-state-c23c' && $(EV c23c) LLMBOX_CONFIG='/tmp/llmcfg-cfg-c23c' '$BOC' --runtime docker cfg23sess </dev/null >/tmp/llmcfg-c23c2.log 2>&1; [ \$? -ne 0 ] \
            && grep -q 'cannot read config' /tmp/llmcfg-c23c2.log"
    chown "$(id -u):$(id -g)" /tmp/llmcfg-cfg-c23c 2>/dev/null || true
else
    skip "CFG23 foreign-owned config is refused (hard error on create) (cannot give the config to another user in this run)"
fi

# ── CFG24: duplicate keys -> LAST wins ─────────────────────────────────────
fake_docker c24
seed_defaults c24
seed_refs c24 'first24:1\nsecond24:2\n'
write_cfg c24 'image.docker=first24:1\nimage.docker=second24:2\n'
check "CFG24 duplicate keys: last occurrence wins" \
    "cd '/tmp/llmcfg-state-c24' && $(EV c24) LLMBOX_CONFIG='/tmp/llmcfg-cfg-c24' '$BOC' --runtime docker cfg24sess </dev/null >/tmp/llmcfg-c24.log 2>&1; \
        grep -q ' second24:2\$' /tmp/llmcfg-log-c24"

# ── CFG25: value with '=' or '#' is invalid -> warning + default ───────────
# Requirement (charset): '=' and '#' are outside the reference charset;
# such values warn and fall back to the default (docker refs never
# contain them).
fake_docker c25
seed_defaults c25
write_cfg c25 'image.docker=myorg/bad=eq:1\n'
check "CFG25 value containing '=' is invalid -> warning + default" \
    "cd '/tmp/llmcfg-state-c25' && $(EV c25) LLMBOX_CONFIG='/tmp/llmcfg-cfg-c25' '$BOC' --runtime docker cfg25sess </dev/null >/tmp/llmcfg-c25.log 2>&1; \
        grep -q 'WARNING' /tmp/llmcfg-c25.log \
        && grep -q ' llm-in-a-box:docker\$' /tmp/llmcfg-log-c25"

fake_docker c25b
seed_defaults c25b
write_cfg c25b 'image.docker=myorg/bad#hash:1\n'
check "CFG25 value containing '#' is invalid -> warning + default" \
    "cd '/tmp/llmcfg-state-c25b' && $(EV c25b) LLMBOX_CONFIG='/tmp/llmcfg-cfg-c25b' '$BOC' --runtime docker cfg25bsess </dev/null >/tmp/llmcfg-c25b.log 2>&1; \
        grep -q 'WARNING' /tmp/llmcfg-c25b.log \
        && grep -q ' llm-in-a-box:docker\$' /tmp/llmcfg-log-c25b"

# ── CFG26: --print-images contract ─────────────────────────────────────────
# Requirement: the hidden subcommand prints EXACTLY
# "sysbox=<ref> docker=<ref> vm=<ref>" on stdout (nothing else — the
# build parses it), exits 0; unusable config -> non-zero + stderr naming
# the file. Theory: this is the seam that keeps build and launch on the
# same parser; stdout purity is what makes the build-side parsing safe.
fake_docker c26
write_cfg c26 'image.sysbox=myorg/s26:1\nimage.docker=myorg/d26:1\nimage.vm=myorg/v26:1\n'
check "CFG26 --print-images prints exactly the three resolved refs" \
    "out=\$(PATH=/tmp/llmcfg-bin-c26:\$PATH HOME=/tmp/llmcfg-home-c26 LLMBOX_CONFIG=/tmp/llmcfg-cfg-c26 '$BOC' --print-images 2>/tmp/llmcfg-c26.log); rc=\$?; \
        [ \$rc -eq 0 ] && [ \"\$out\" = 'sysbox=myorg/s26:1 docker=myorg/d26:1 vm=myorg/v26:1' ]"

if [ "$(id -u)" = 0 ]; then
    skip "CFG26 --print-images with unusable config exits non-zero naming the file (chmod-000 fixture requires a non-root run)"
else
    fake_docker c26b
    write_cfg c26b 'image.docker=myorg/x:1\n'
    chmod 000 /tmp/llmcfg-cfg-c26b
    check "CFG26 --print-images with unusable config exits non-zero naming the file" \
        "PATH=/tmp/llmcfg-bin-c26b:\$PATH HOME=/tmp/llmcfg-home-c26b LLMBOX_CONFIG=/tmp/llmcfg-cfg-c26b '$BOC' --print-images >/tmp/llmcfg-c26b.out 2>/tmp/llmcfg-c26b.log; [ \$? -ne 0 ] \
            && [ ! -s /tmp/llmcfg-c26b.out ] \
            && grep -q 'cannot read config' /tmp/llmcfg-c26b.log"
    chmod 600 /tmp/llmcfg-cfg-c26b
fi

# ── CFG27: attach of an EXISTING session with unusable config ──────────────
# Requirement (verified against the dispatch): the image is resolved ONLY
# on the create path; attaching an existing session with a broken config
# must warn and proceed — a hard error would lock the user out of a live
# session.
if [ "$(id -u)" = 0 ]; then
    skip "CFG27 attach of existing session with unusable config warns and attaches (chmod-000 fixture requires a non-root run)"
else
    fake_docker c27
    printf 'cfg27sess|llm-in-a-box.runtime|docker|llm-in-a-box:docker|running|||\n' > /tmp/llmcfg-table-c27
    write_cfg c27 'image.docker=myorg/x:1\n'
    chmod 000 /tmp/llmcfg-cfg-c27
    check "CFG27 attach of existing session with unusable config warns and attaches" \
        "cd '/tmp/llmcfg-state-c27' && $(EV c27) LLMBOX_CONFIG='/tmp/llmcfg-cfg-c27' '$BOC' cfg27sess </dev/null >/tmp/llmcfg-c27.log 2>&1; \
            grep -q 'WARNING' /tmp/llmcfg-c27.log \
            && grep -q 'Attaching to running container' /tmp/llmcfg-c27.log"
    chmod 600 /tmp/llmcfg-cfg-c27
fi

# ── CFG28: mixed valid + invalid keys -> per-key behavior ──────────────────
# Requirement: an invalid key must not poison the file — valid keys
# still apply (an all-or-nothing abort is a failure).
fake_docker c28
seed_defaults c28
seed_refs c28 'myorg/good28:1\n'
write_cfg c28 'image.docker=myorg/good28:1\nimage.sysbox=bad value here\n'
check "CFG28 mixed file: valid key applies, invalid key warns and defaults" \
    "cd '/tmp/llmcfg-state-c28' && $(EV c28) LLMBOX_CONFIG='/tmp/llmcfg-cfg-c28' '$BOC' --runtime docker cfg28sess </dev/null >/tmp/llmcfg-c28.log 2>&1; \
        grep -q ' myorg/good28:1\$' /tmp/llmcfg-log-c28 \
        && grep -q 'WARNING' /tmp/llmcfg-c28.log"

check "CFG28 sysbox leg: invalid sysbox value defaults to llm-in-a-box:sysbox" \
    "cd '/tmp/llmcfg-state-c28' && $(EV c28) LLMBOX_CONFIG='/tmp/llmcfg-cfg-c28' '$BOC' --runtime sysbox cfg28b </dev/null >/tmp/llmcfg-c28b.log 2>&1; \
        grep -q ' llm-in-a-box:sysbox\$' /tmp/llmcfg-log-c28"

# ── CFG29: sourced warn-class contract ─────────────────────────────────────
# Requirement: llm_box_load_config called from a sourced copy (no
# operation flags) classifies as warn-class — it never hard-errors —
# preserving the "sourcing has no side effects" invariant.
skip "CFG29 sourced warn-class: llm_box_load_config with no flags does not hard-error (moved to the Rust crate's unit tests)"

# ── CFG30: vm provenance ───────────────────────────────────────────────────
# Requirement: the base dir records the image the base disk was built
# from; the vm preflight warns when a session's base came from a
# different image than the currently configured one. Theory: without the
# record, a config change silently boots sessions from stale bases. Bases
# live in the state directory (ADR 013), at $LLMBOX_STATE_DIR/bases/<ts>/.
fake_docker c30
seed_refs c30 'myorg/vm30:1\n'
write_cfg c30 'image.vm=myorg/vm30:1\n'
check "CFG30 build vm writes the configured ref into the base dir from-image record" \
    "cd '/tmp/llmcfg-state-c30' && $(EV c30) LLMBOX_STATE_DIR='/tmp/llmcfg-state-c30' LLMBOX_CONFIG='/tmp/llmcfg-cfg-c30' bash '$BUILD' vm >/tmp/llmcfg-c30.log 2>&1; \
        [ -f /tmp/llmcfg-state-c30/bases/\$(readlink /tmp/llmcfg-state-c30/bases/latest)/from-image ] \
        && grep -q 'myorg/vm30:1' /tmp/llmcfg-state-c30/bases/\$(readlink /tmp/llmcfg-state-c30/bases/latest)/from-image"

fake_docker c30b
mkdir -p /tmp/llmcfg-state-c30b/bases/20260101-000000-1
printf 'oldorg/img:9\n' > /tmp/llmcfg-state-c30b/bases/20260101-000000-1/from-image
touch /tmp/llmcfg-state-c30b/bases/20260101-000000-1/base.qcow2 /tmp/llmcfg-state-c30b/bases/20260101-000000-1/vmlinuz
ln -sfn 20260101-000000-1 /tmp/llmcfg-state-c30b/bases/latest
write_cfg c30b 'image.vm=myorg/custom30:2\n'
check "CFG30 vm preflight warns when the session base came from a different image" \
    "cd '/tmp/llmcfg-state-c30b' && $(EV c30b) LLMBOX_STATE_DIR='/tmp/llmcfg-state-c30b' LLMBOX_VM_MISSING='qemu-system-x86_64 ssh' LLMBOX_CONFIG='/tmp/llmcfg-cfg-c30b' '$BOC' --runtime vm cfg30sess </dev/null >/tmp/llmcfg-c30b.log 2>&1; \
        grep -q 'different image' /tmp/llmcfg-c30b.log"

# ── CFG31: config under a non-searchable parent -> unusable ────────────────
# Requirement (missing-vs-unusable): only ENOENT is "missing"; any other
# failure on an existing path (stat failure via a non-searchable parent)
# is unusable — silent default-fallback would ignore the user's config.
if [ "$(id -u)" = 0 ]; then
    skip "CFG31 config under a non-searchable parent is unusable (hard error on create) (chmod-000 parent fixture requires a non-root run)"
else
    fake_docker c31
    seed_defaults c31
    mkdir -p /tmp/llmcfg-home-c31/.config/llm_in_a_box
    printf 'image.docker=myorg/x31:1\n' > /tmp/llmcfg-home-c31/.config/llm_in_a_box/config
    chmod 000 /tmp/llmcfg-home-c31/.config/llm_in_a_box
    check "CFG31 config under a non-searchable parent is unusable (hard error on create)" \
        "cd '/tmp/llmcfg-state-c31' && $(EV c31) '$BOC' --runtime docker cfg31sess </dev/null >/tmp/llmcfg-c31.log 2>&1; [ \$? -ne 0 ] \
            && grep -q 'cannot read config' /tmp/llmcfg-c31.log \
            && ! grep -q '^run ' /tmp/llmcfg-log-c31"
    chmod 700 /tmp/llmcfg-home-c31/.config/llm_in_a_box
fi

# ── CFG32: explicit --runtime vm with unusable config is warn-class ─────────
# Requirement (amendment 12): the vm runtime never resolves an image at
# launch (image.vm is build-time only), so an explicit --runtime vm with
# an unusable config warns and proceeds like every other vm operation —
# it must NOT hard-error. Theory: the severity contract is by ACTUAL
# image need; the hard-error class is create-of-new-docker/sysbox,
# auto-detect, --print-images. The preflight still runs (and fails on
# the missing base here) — the assertion is on the config handling.
if [ "$(id -u)" = 0 ]; then
    skip "CFG32 --runtime vm with unusable config warns and proceeds (no config hard error) (chmod-000 fixture requires a non-root run)"
else
    fake_docker c32
    write_cfg c32 'image.docker=myorg/x:1\n'
    chmod 000 /tmp/llmcfg-cfg-c32
    check "CFG32 --runtime vm with unusable config warns and proceeds (no config hard error)" \
        "cd '/tmp/llmcfg-state-c32' && $(EV c32) LLMBOX_CONFIG='/tmp/llmcfg-cfg-c32' '$BOC' --runtime vm cfg32sess </dev/null >/tmp/llmcfg-c32.log 2>&1; \
            grep -q 'WARNING' /tmp/llmcfg-c32.log \
            && ! grep -q 'cannot read config' /tmp/llmcfg-c32.log"
    chmod 600 /tmp/llmcfg-cfg-c32
fi

# ── CFG33: toolchain probe failure -> precise error, nothing else ─────────
# Requirement: the base-disk toolchain probe fails with a precise
# message BEFORE the export pipeline when the configured image lacks the
# tools. Theory: the failure leg must be pinned — the success leg alone
# (CFG12/CFG13a) could mask a deleted probe. The shim's FAKE_PROBE_FAIL
# mode fails the exact probe invocation.
fake_docker c33
seed_refs c33 'myorg/vm33:1\n'
write_cfg c33 'image.vm=myorg/vm33:1\n'
check "CFG33 toolchain probe failure errors precisely and runs no pipeline" \
    "cd '/tmp/llmcfg-state-c33' && FAKE_PROBE_FAIL=1 $(EV c33) LLMBOX_CONFIG='/tmp/llmcfg-cfg-c33' bash '$BUILD' vm >/tmp/llmcfg-c33.log 2>&1; [ \$? -ne 0 ] \
        && grep -q 'lacks the base-disk toolchain' /tmp/llmcfg-c33.log \
        && ! grep -q '^create ' /tmp/llmcfg-log-c33"

# ── CFG34: repo-digest branch of the from-image record ────────────
# Requirement: when the image has a repo digest, the base dir records
# the DIGEST (not just the ref). Theory: the record is the provenance
# data the preflight warning compares; the digest branch (registry-
# pulled images) must not silently record the tag.
fake_docker c34
seed_refs c34 'myorg/vm34:1\n'
write_cfg c34 'image.vm=myorg/vm34:1\n'
check "CFG34 from-image records the repo digest when one exists" \
    "cd '/tmp/llmcfg-state-c34' && FAKE_DIGEST='[myorg/vm34@sha256:deadbeef]' $(EV c34) LLMBOX_STATE_DIR='/tmp/llmcfg-state-c34' LLMBOX_CONFIG='/tmp/llmcfg-cfg-c34' bash '$BUILD' vm >/tmp/llmcfg-c34.log 2>&1; \
        [ -f /tmp/llmcfg-state-c34/bases/\$(readlink /tmp/llmcfg-state-c34/bases/latest)/from-image ] \
        && grep -q 'myorg/vm34@sha256:deadbeef' /tmp/llmcfg-state-c34/bases/\$(readlink /tmp/llmcfg-state-c34/bases/latest)/from-image"


# ── CFG35: the permission rule reads the file mode as octal ────────────────
# Requirement: a config is unusable when the group or others can write it,
# and usable otherwise, whatever the other permission bits are. Theory:
# `stat -c %a` prints the mode as octal digits; treating them as a decimal
# number would refuse the private mode 600 and accept group-writable 620.
# Every mode below is checked through --print-images (exit 0 and the
# configured ref when usable; non-zero and "cannot read config" when not).
fake_docker c35
cfg35_bad=""
for m in 400 600 604 640 644 700 750 755; do
    write_cfg c35 'image.docker=myorg/m35:1\n'
    chmod "$m" /tmp/llmcfg-cfg-c35
    out=$(PATH=/tmp/llmcfg-bin-c35:$PATH HOME=/tmp/llmcfg-home-c35 LLMBOX_CONFIG=/tmp/llmcfg-cfg-c35 "$BOC" --print-images 2>/dev/null) \
        && case "$out" in *docker=myorg/m35:1*) ;; *) cfg35_bad="$cfg35_bad accepted-$m" ;; esac \
        || cfg35_bad="$cfg35_bad accepted-$m"
done
for m in 602 606 620 622 660 664 666 670 707 720; do
    write_cfg c35 'image.docker=myorg/m35:1\n'
    chmod "$m" /tmp/llmcfg-cfg-c35
    if PATH=/tmp/llmcfg-bin-c35:$PATH HOME=/tmp/llmcfg-home-c35 LLMBOX_CONFIG=/tmp/llmcfg-cfg-c35 "$BOC" --print-images >/dev/null 2>/tmp/llmcfg-c35.log \
        || ! grep -q 'cannot read config' /tmp/llmcfg-c35.log; then
        cfg35_bad="$cfg35_bad refused-$m"
    fi
done
chmod 600 /tmp/llmcfg-cfg-c35
[ -z "$cfg35_bad" ] || echo "CFG35 wrong outcomes:$cfg35_bad"
check "CFG35 group- or other-writable config modes are refused, all others accepted" "[ -z '$cfg35_bad' ]"

echo ""
echo "test_llm_in_a_box_config.sh: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
[ "$FAIL" -eq 0 ]
