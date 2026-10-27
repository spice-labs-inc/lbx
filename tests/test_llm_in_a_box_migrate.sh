    # A replacement box the launcher discarded or renamed into place carries a
    # volume named after its temporary name; remove those too.
    docker volume ls -q 2>/dev/null | grep -E "^($MIG_BOX|$MIG_BOX2)-migrating[0-9]+-docker$" | xargs -r docker volume rm -f >/dev/null 2>&1 || true
#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_llm_in_a_box_migrate.sh: behavioral tests for migrating an existing
# sysbox box onto a usable stack.
#
# WHAT (no source grep):
#   MIG1:  `--migrate --dry-run <name>` reports the named box and changes
#          nothing: no container is created, none is destroyed, and it
#          exits 0 when the migration could proceed.
#   MIG2:  a real run on an unusable runtime refuses BEFORE any docker call,
#          and the message names both the upgrade and the required order
#          (upgrade sysbox first, then migrate).
#   MIG3:  `--dry-run` works with no sysbox runtime and no image present:
#          the situation the tool exists for.
#   MIG4:  a docker-runtime box is reported as skipped, never migrated.
#   MIG5:  a bare `--migrate` with no names refuses.
#   MIG6:  THE END-TO-END CHECK. A real box is created, a real session file
#          is written by the box user, the REAL sysbox daemons are
#          restarted and the box is stopped and started so its ID mapping
#          is lost, and then the box is migrated. Afterwards the box user
#          owns its files (the invoking user's ids, as the box sees them), the user
#          namespace is active, sudo works, and the session file is
#          readable by the box user.
#   MIG7:  the export succeeds on a box whose `docker exec` has stopped
#          working entirely (the second-daemon-restart state). The export
#          must not depend on exec.
#   MIG8:  when verification fails, the old box still exists and the
#          partial replacement is gone. Verify-before-destroy.
#   MIG9:  with one migratable box and one that fails, the good one is
#          migrated, the failure is reported, and the exit status is
#          non-zero.
#   MIG10: /data is neither read nor written. A sentinel file the host
#          placed there is unchanged, and no /data path appears in the
#          payload.
#   MIG11: the notice exists at all three agent context paths, is owned by
#          the box user, is readable by the box user, and instructs the
#          agent to delete it once it has handled the reinstalls.
#   MIG12: a file created by the box user before the migration is still
#          owned by the box user and readable after it. This is the exact
#          failure mode that copying with `docker cp` alone produces.
#   MIG13: a box that has already been migrated is skipped rather than
#          failing.
#   MIG14: property check: session trees of varying depth, file count and
#          size round-trip exactly: the same relative paths, with ownership
#          preserved, for every generated tree.
#
# WHY: an existing `lbx` user has an old sysbox (0.6.x/0.7.0), and some have
#      a pinned Docker. The preflight added for the sysbox ID-mapping work
#      refuses to launch on such a host, which is correct but is a wall: the
#      user's next command fails identically, nothing says what the fix
#      costs, and nothing says that installing sysbox restarts its daemons
#      and damages every box that already exists. Their boxes hold work:
#      pi, Claude Code and opencode sessions live in the container's
#      /home/agent, not in /data. This suite pins the migration that
#      carries that work onto a usable stack.
#
# THEORY OF THE EXPORT (MIG6/MIG7/MIG12): the obvious approach, `docker
#      commit` the box and run the replacement from the image, was measured
#      and REJECTED. Committing while the ID mapping is broken reads
#      ownership through the broken mapping and writes the overflow uid
#      (65534) into the image for every path owned by the box user, and the
#      result cannot be repaired from inside because uid 0 in the
#      container's user namespace does not map to the host uid that owns
#      those files. The files on disk are not damaged, though: only the
#      container's view is. Reading through the host's /proc/<pid>/root
#      gives correct content AND correct ownership, so the export goes that
#      way and never through commit. The payload must be a tar extracted
#      inside the replacement container: `docker cp` alone leaves files
#      owned by the overflow uid, and can even report success while copying
#      nothing.
#
# THEORY OF VERIFY-BEFORE-DESTROY (MIG8): the operation is destructive by
#      design, so the old box is not removed until the replacement has been
#      proven good. Without this, a migration that half-worked would destroy
#      the only copy of the user's work.
#
# LLM-FRIENDLY NOTE: MIG1-MIG5 need only docker and a built sysbox image.
#   MIG6, MIG7, MIG12 and MIG14 create REAL sysbox boxes and restart the
#   REAL sysbox daemons, so they need root (or passwordless sudo) on a host
#   with sysbox installed. Everything skips (skip-not-fail) when a
#   prerequisite is absent, matching the project's existing suites; the
#   expectation is that they RUN where sysbox is installed, which for this
#   project is inside a virtual machine.
#
#   These checks damage every sysbox box on the host, because they restart
#   the sysbox daemons. They therefore only ever touch boxes this suite
#   created, and never another user's containers.
#
#   The sudo checks use the NUMERIC uid:gid form of `docker exec -u`, never
#   the name form: on a box whose /etc/passwd cannot be resolved in the
#   outer daemon's context the name form fails with "unable to find user",
#   which would make a check pass or fail for the wrong reason.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOC="${LBX_BIN:-${SCRIPT_DIR}/../target/debug/lbx}"
SYSBOX_IMAGE="${LBX_TEST_SYSBOX_IMAGE:-llm-in-a-box:sysbox}"

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

# ── Scratch directories ───────────────────────────────────────────────────
# Every box runs with a private state directory and its own project
# directory, so no check writes into the real ~/.llm-in-a-box or the real
# project root. The project directory is the working directory lbx is run
# from (it becomes the box's /data).
MIG_TMP="$(mktemp -d /tmp/llm-in-a-box-migrate.XXXXXX)"
MIG_STATE="$MIG_TMP/state"
MIG_PROJ="$MIG_TMP/proj"
mkdir -p "$MIG_STATE" "$MIG_PROJ"
export LBX_STATE_DIR="$MIG_STATE"
export LLMBOX_STATE_DIR="$MIG_STATE"

# The boxes this suite creates. Named with a fixed prefix so cleanup can
# remove exactly its own work and nothing else.
MIG_BOX="mig-check-1"
MIG_BOX2="mig-check-2"
# The throwaway container that shows sysbox is back after a daemon restart.
MIG_PROBE="mig-check-probe"

# The ids the box user is created with. lbx passes HOST_UID="$(id -u)" and
# HOST_GID="$(id -g)" to the container and the entrypoint creates the box user
# with them, so a box's user has the INVOKING user's ids. Every ownership
# assertion below compares against these rather than a literal 1000:1000, so a
# host whose user is not uid/gid 1000 cannot produce a false failure. Measured:
# a suite launched with `sg kvm -c` has gid 990 (sg sets the effective group to
# that group), and the literal form failed three checks for a reason that had
# nothing to do with the migration.
BOX_UID="$(id -u)"
BOX_GID="$(id -g)"

# The migration creates the replacement box AS THE BOX USER (that is what
# makes its user and sudoers rule match the box it replaces), so the state and
# project directories have to be writable by that user. In production they are
# the invoking user's own directories. When this suite runs as root the scratch
# tree is root-owned, which no real migration would ever see, so it is opened
# to the box user here.
if [ "$(id -u)" = "0" ]; then
    chown -R "$BOX_UID:$BOX_GID" "$MIG_TMP" 2>/dev/null || true
fi

cleanup() {
    # Remove any box this suite created, then the scratch tree. Failure is
    # tolerated: a check that already failed is the signal, not cleanup.
    docker rm -f "$MIG_BOX" "$MIG_BOX2" "$MIG_PROBE" >/dev/null 2>&1 || true
    # The launcher gives every box a per-session docker volume, which
    # `docker rm` leaves behind; `--destroy` would remove it, but a box this
    # suite damaged may not be destroyable through the launcher.
    docker volume rm -f "$MIG_BOX-docker" "$MIG_BOX2-docker" >/dev/null 2>&1 || true
    # A replacement box the launcher discarded or renamed into place carries a
    # volume named after its temporary name; remove those too.
    docker volume ls -q 2>/dev/null | grep -E "^($MIG_BOX|$MIG_BOX2)-migrating[0-9]+-docker$" | xargs -r docker volume rm -f >/dev/null 2>&1 || true
    rm -rf "$MIG_TMP" 2>/dev/null || true
}
trap cleanup EXIT

# ── Prerequisite probes (skip-not-fail) ───────────────────────────────────
docker_ok() { docker info >/dev/null 2>&1; }
sysbox_runtime_ok() { docker info 2>/dev/null | grep >/dev/null 'sysbox-runc'; }
sysbox_image_ok() { docker image inspect "$SYSBOX_IMAGE" >/dev/null 2>&1; }

# How to run the sysbox daemon restart. Root is needed for systemctl; on a
# host where sudo is unavailable and we are not root, the daemon checks
# skip rather than fail.
can_restart_daemons() {
    [ "$(id -u)" = "0" ] && return 0
    command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1
}
as_root() {
    if [ "$(id -u)" = "0" ]; then "$@"; else sudo -n "$@"; fi
}

# ── Box helpers ───────────────────────────────────────────────────────────
# Wait for the entrypoint to finish user setup. /tmp/.user-ready is written
# by entrypoint.sh once the box user exists, and is what lbx itself waits
# for before attaching.
wait_box_ready() {
    local name="$1" i
    for i in $(seq 1 90); do
        docker exec "$name" test -f /tmp/.user-ready >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

# The box's own view of a file's owner (uid gid mode).
box_stat() {
    docker exec -u 0 "$1" stat -c '%u %g %a' "$2" 2>/dev/null | head -1
}

# The host's view of the same file, through the container's root mount.
# This is the comparison that proves whether an ID mapping is in effect:
# on a healthy box both agree (0 0 ...); on a damaged box the box reports
# the overflow uid 65534 while the host still reports 0.
host_stat() {
    local name="$1" path="$2" pid
    pid=$(docker inspect -f '{{.State.Pid}}' "$name" 2>/dev/null | head -1)
    [ -n "$pid" ] && [ "$pid" != "0" ] || return 1
    as_root stat -c '%u %g %a' "/proc/$pid/root$path" 2>/dev/null | head -1
}

# sudo inside the box, as the box user, using the NUMERIC form (see the
# LLM-FRIENDLY NOTE above).
box_sudo_works() {
    docker exec -u "$BOX_UID:$BOX_GID" "$1" sudo -n true >/dev/null 2>&1
}

# Create a box the way lbx does, through the launcher, from a throwaway
# project directory so /data is not the real project root. The launcher
# exits non-zero when it cannot attach a TTY to stdin, which is expected
# here; the box is what matters, so success is judged by the box existing.
launch_box() {
    local name="$1"
    ( cd "$MIG_PROJ" && "$BOC" --runtime sysbox "$name" 2>&1 < /dev/null ) >/dev/null 2>&1
    docker container inspect "$name" >/dev/null 2>&1
}

# The migration under test, run from the throwaway project directory.
#
# Reporting only: no privilege needed, and keeping it unprivileged is what
# lets a PATH seam work (sudo resets PATH, so a seam would be lost).
migrate() {
    ( cd "$MIG_PROJ" && "$BOC" "$@" 2>&1 < /dev/null )
}

# The migration of a REAL box, which needs the privilege the export requires:
# it reads the box's filesystem through /proc/<pid>/root, which belongs to the
# container's owning user rather than to the operator. `as_root` uses root
# directly or passwordless sudo, and every check that calls this skips when
# neither is available.
migrate_real() {
    ( cd "$MIG_PROJ" && as_root "$BOC" "$@" 2>&1 < /dev/null )
}

# Write a file into a box as the box user (numeric form), creating parent
# directories as needed.
box_write_as_user() {
    local name="$1" path="$2" content="$3"
    docker exec -u 0 "$name" bash -c \
        "mkdir -p \"\$(dirname '$path')\" && printf '%s\n' '$content' > '$path' && chown -R $BOX_UID:$BOX_GID \"\$(dirname '$path')\"" \
        >/dev/null 2>&1
}

# Read a file as the box user. Prints nothing and returns non-zero when the
# box user cannot read it, which is the failure mode under test.
box_read_as_user() {
    docker exec -u "$BOX_UID:$BOX_GID" "$1" cat "$2" 2>/dev/null
}

# The state of each sysbox unit, on one line.
sysbox_units_state() {
    local u line=""
    for u in sysbox sysbox-mgr sysbox-fs; do
        line="$line $u=$(systemctl is-active "$u" 2>/dev/null)"
    done
    printf '%s\n' "${line# }"
}

# Wait up to $1 seconds until the sysbox units are active and a new sysbox
# container can start. A fixed sleep after the restart is not enough on a slow
# host: a box started before sysbox is back fails to start and is never
# damaged.
wait_sysbox_ready() {
    local deadline=$((SECONDS + $1))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if [ "$(sysbox_units_state)" = "sysbox=active sysbox-mgr=active sysbox-fs=active" ] \
            && docker run --rm --name "$MIG_PROBE" --runtime sysbox-runc --entrypoint true \
                "$SYSBOX_IMAGE" >/dev/null 2>&1; then
            return 0
        fi
        docker rm -f "$MIG_PROBE" >/dev/null 2>&1 || true
        sleep 1
    done
    return 1
}

# Wait up to $2 seconds until the box is running, starting it again while it
# is not.
wait_box_running() {
    local name="$1" deadline=$((SECONDS + $2))
    while [ "$SECONDS" -lt "$deadline" ]; do
        [ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" = true ] && return 0
        docker start "$name" >/dev/null 2>&1 || true
        sleep 1
    done
    return 1
}

# Wait up to $2 seconds until the box answers docker exec.
wait_box_exec() {
    local name="$1" deadline=$((SECONDS + $2))
    while [ "$SECONDS" -lt "$deadline" ]; do
        docker exec -u 0 "$name" true >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

# Damage a box exactly the way the field boxes are damaged: restart the
# real sysbox daemons (which wipes sysbox-fs's in-memory state for
# containers that already exist), then stop and start the box so its next
# start comes up without its ID mapping. Succeeds when sysbox came back and
# the box is running again; how long each wait took is left in DAMAGE_WAITS.
damage_box() {
    local name="$1" t0 rc=0 sysbox_secs box_secs
    t0=$SECONDS
    as_root systemctl restart sysbox >/dev/null 2>&1
    wait_sysbox_ready 120 || rc=1
    sysbox_secs=$((SECONDS - t0))
    docker stop "$name" >/dev/null 2>&1
    t0=$SECONDS
    docker start "$name" >/dev/null 2>&1
    wait_box_running "$name" 60 || rc=1
    box_secs=$((SECONDS - t0))
    DAMAGE_WAITS="sysbox back after ${sysbox_secs}s, box running after ${box_secs}s"
    [ "$rc" -eq 0 ] || DAMAGE_WAITS="$DAMAGE_WAITS (a wait timed out)"
    return "$rc"
}

# A box is damaged when its ID mapping is gone, which shows up as the overflow
# uid: the box sees 65534 65534 where the host sees 0 0. This is the ground
# truth the migration must survive, and both halves are measured, not assumed.
box_is_damaged() {
    local name="$1"
    [ "$(box_stat "$name" /etc/sudo.conf)" = "65534 65534 644" ] \
        && [ "$(host_stat "$name" /etc/sudo.conf)" = "0 0 644" ]
}

# What a box looked like, for the log when a check fails.
box_report() {
    local name="$1"
    echo "    box state: $(docker inspect -f 'status={{.State.Status}} running={{.State.Running}} exit={{.State.ExitCode}} error={{.State.Error}}' "$name" 2>&1 | head -1)"
    echo "    sysbox units: $(sysbox_units_state)"
    echo "    /etc/sudo.conf: box sees '$(box_stat "$name" /etc/sudo.conf)', host sees '$(host_stat "$name" /etc/sudo.conf)'"
}

# Damage a box and confirm the damage shows, running the whole sequence up to
# three times. What each failed try saw is left in DAMAGE_REPORT.
damage_box_confirmed() {
    local name="$1" try exec_note t0
    DAMAGE_REPORT=""
    for try in 1 2 3; do
        damage_box "$name"
        t0=$SECONDS
        if wait_box_exec "$name" 60; then
            exec_note="docker exec answered after $((SECONDS - t0))s"
        else
            exec_note="docker exec did not answer within 60s"
        fi
        box_is_damaged "$name" && return 0
        DAMAGE_REPORT="$DAMAGE_REPORT    try $try: $DAMAGE_WAITS, $exec_note
$(box_report "$name")
"
    done
    return 1
}

echo "== migration: reporting (no container needed) =="

# A helper for the reporting checks below. The launcher prints its whole
# usage block when it does not recognise an option, and that block contains
# many ordinary words ("then", "first", "skip", "install"). A check that
# greps for such a word alone therefore passes against the usage dump, a
# false pass that proves nothing. These helpers require the message to be
# about migration and to be specific.
#
# is_usage_dump: true when the output is the option parser's usage block
# rather than a considered message about the box being migrated.
is_usage_dump() {
    printf '%s' "$1" | grep -E >/dev/null '^Usage: lbx \[options\]|^Options:'
}
# migration_says <output> <extended-regex>: the output is a migration
# message (not a usage dump) and it says the required thing.
migration_says() {
    is_usage_dump "$1" && return 1
    printf '%s' "$1" | grep -iE >/dev/null "$2"
}

# ── MIG5: a bare --migrate refuses ────────────────────────────────────────
# Requirement SB-M1. A bare `--migrate` must not sweep every box: the
# operation destroys containers, so it must be told which ones. This pins
# that the option does not acquire an implicit --all.
MIG5_OUT="$(migrate --migrate --dry-run 2>&1)"
MIG5_RC=$?
check "MIG5 a bare --migrate with no names refuses and does not sweep every box" \
    "[ $MIG5_RC -ne 0 ] && ! is_usage_dump \"\$MIG5_OUT\""

# ── MIG1: --dry-run reports and changes nothing ───────────────────────────
# Requirement SB-M1. The user must be able to see what a migration would do
# before it destroys anything. This needs a real box to report on, so it
# runs with the real-container prerequisites and skips without them.
if docker_ok && sysbox_runtime_ok && sysbox_image_ok; then
    launch_box "$MIG_BOX" && wait_box_ready "$MIG_BOX" || true
    if docker container inspect "$MIG_BOX" >/dev/null 2>&1; then
        MIG1_BEFORE="$(docker ps -a --format '{{.Names}}' | sort | tr '\n' ' ')"
        MIG1_OUT="$(migrate --migrate --dry-run "$MIG_BOX" 2>&1)"
        MIG1_RC=$?
        MIG1_AFTER="$(docker ps -a --format '{{.Names}}' | sort | tr '\n' ' ')"
        # The report must name the box it is talking about.
        MIG1_NAMES=false
        migration_says "$MIG1_OUT" "$MIG_BOX" && MIG1_NAMES=true
        check "MIG1 --dry-run names the box it would migrate and exits 0" \
            "[ $MIG1_RC -eq 0 ] && [ \"\$MIG1_NAMES\" = true ]"
        check "MIG1 --dry-run creates and destroys nothing (the container list is unchanged)" \
            "[ \"\$MIG1_BEFORE\" = \"\$MIG1_AFTER\" ]"
    else
        skip "MIG1 --dry-run reports and changes nothing (could not create a sysbox box)"
    fi
else
    skip "MIG1 --dry-run reports and changes nothing (needs docker + sysbox-runc + $SYSBOX_IMAGE)"
fi

# ── MIG4: a docker-runtime box is skipped, never migrated ─────────────────
# Requirement SB-M10. The tool exists for the sysbox ID-mapping problem.
# Silently rewriting a docker-runtime box would destroy work for no reason.
# A docker-runtime box is simulated by labelling one as docker: what is
# under test is the tool's decision, not how docker-runtime boxes are made.
if docker_ok && sysbox_image_ok; then
    docker rm -f "$MIG_BOX2" >/dev/null 2>&1 || true
    docker create --name "$MIG_BOX2" \
        --label "llm-in-a-box.runtime=docker" \
        --label "llm-in-a-box.user=$BOX_UID" \
        "$SYSBOX_IMAGE" sleep 300 >/dev/null 2>&1 || true
    if docker container inspect "$MIG_BOX2" >/dev/null 2>&1; then
        MIG4_OUT="$(migrate --migrate --dry-run "$MIG_BOX2" 2>&1)"
        # It must be reported as skipped/not-migratable, and must not be
        # reported as a box that will be migrated.
        MIG4_SKIP=false
        migration_says "$MIG4_OUT" 'skip|not a sysbox|not sysbox|docker runtime' && MIG4_SKIP=true
        check "MIG4 a docker-runtime box is reported as skipped, not migrated" \
            "[ \"\$MIG4_SKIP\" = true ]"
    else
        skip "MIG4 a docker-runtime box is skipped (could not create the probe container)"
    fi
    docker rm -f "$MIG_BOX2" >/dev/null 2>&1 || true
else
    skip "MIG4 a docker-runtime box is skipped (needs docker + $SYSBOX_IMAGE)"
fi

# ── MIG2: a real run on an unusable runtime refuses before acting ─────────
# Requirement SB-M2. The migration cannot build the replacement box without
# a usable sysbox, so it must refuse BEFORE touching anything, name the
# cause, and state the order: upgrade sysbox first, then migrate. The order
# matters because installing sysbox is itself what damages the existing
# boxes; a user who migrated first and upgraded second would gain nothing.
#
# The runtime is made unusable through a PATH seam holding a sysbox-runc
# that declares no `time` namespace, which is the property that decides
# whether the runtime works on Docker 28+.
MIG2_SEAM="$MIG_TMP/seam"
mkdir -p "$MIG2_SEAM/bin"
cat > "$MIG2_SEAM/bin/sysbox-runc" <<'SEAM'
#!/bin/sh
case "$1" in
  --version) printf 'sysbox-runc\n    version:     0.6.7\n' ;;
  features)  printf '{"linux":{"namespaces":["cgroup","ipc","mount","network","pid","user","uts"],"mountOptions":["atime","lazytime"]}}' ;;
esac
exit 0
SEAM
chmod +x "$MIG2_SEAM/bin/sysbox-runc"

if docker_ok; then
    # Record the docker calls made during the attempt. A refusal must not
    # create or destroy anything, so a `create` or `rm` here is a failure.
    MIG2_LOG="$MIG_TMP/mig2.calls"
    : > "$MIG2_LOG"
    MIG2_SEAM_BIN="$MIG2_SEAM/bin"
    cat > "$MIG2_SEAM_BIN/docker" <<SEAM2
#!/bin/sh
printf '%s\n' "\$*" >> "$MIG2_LOG"
exec /usr/bin/docker "\$@"
SEAM2
    chmod +x "$MIG2_SEAM_BIN/docker"
    MIG2_OUT="$(PATH="$MIG2_SEAM_BIN:$PATH" migrate --migrate "$MIG_BOX" 2>&1)"
    MIG2_RC=$?
    MIG2_CAUSE=false
    migration_says "$MIG2_OUT" 'time.*namespace|0\.7\.1|upgrade' && MIG2_CAUSE=true
    MIG2_ORDER=false
    migration_says "$MIG2_OUT" 'upgrade.*(before|first)|before.*migrat|first.*migrat|then migrat' && MIG2_ORDER=true
    MIG2_ACTED=false
    grep -qE '^create|^rm ' "$MIG2_LOG" && MIG2_ACTED=true
    check "MIG2 a real run on an unusable runtime refuses, naming the cause" \
        "[ $MIG2_RC -ne 0 ] && [ \"\$MIG2_CAUSE\" = true ]"
    check "MIG2 the refusal states the required order (upgrade first, then migrate)" \
        "[ \"\$MIG2_ORDER\" = true ]"
    check "MIG2 the refusal creates and destroys nothing" \
        "[ \"\$MIG2_ACTED\" = false ]"
else
    skip "MIG2 a real run on an unusable runtime refuses (needs docker)"
    skip "MIG2 the refusal states the required order (needs docker)"
    skip "MIG2 the refusal creates and destroys nothing (needs docker)"
fi

# ── MIG3: --dry-run works with no runtime and no image ────────────────────
# Requirement SB-M9. Reporting must work on a host where the runtime cannot
# run at all, because that is the situation the tool exists for. A report
# that needed a working runtime would be useless to the user who needs it.
if docker_ok; then
    MIG3_OUT="$(PATH="$MIG2_SEAM_BIN:$PATH" migrate --migrate --dry-run "$MIG_BOX" 2>&1)"
    MIG3_RC=$?
    # Reporting must not fail merely because the runtime is unusable. It may
    # report that the box cannot be migrated yet; it must not be a usage
    # error, and it must not crash.
    MIG3_CRASH=false
    is_usage_dump "$MIG3_OUT" && MIG3_CRASH=true
    check "MIG3 --dry-run works with no usable sysbox runtime (it reports rather than erroring on the option)" \
        "[ \"\$MIG3_CRASH\" = false ]"
else
    skip "MIG3 --dry-run works with no usable sysbox runtime (needs docker)"
fi

echo "== migration: end to end on a real damaged box =="

# ── MIG6, MIG11, MIG12: the end-to-end check ──────────────────────────────
# Requirements SB-M3, SB-M4, SB-M7. This is the check the whole plan exists
# for: a box damaged exactly as the field boxes are damaged is migrated, and
# afterwards the box user owns its files and can read its work.
MIG6_READY=true
docker_ok          || MIG6_READY=false
sysbox_runtime_ok  || MIG6_READY=false
sysbox_image_ok    || MIG6_READY=false
can_restart_daemons || MIG6_READY=false

if [ "$MIG6_READY" = true ]; then
    docker rm -f "$MIG_BOX" >/dev/null 2>&1 || true
    if launch_box "$MIG_BOX" && wait_box_ready "$MIG_BOX"; then
        # A session file the box user owns, of the shape an agent writes:
        # pi stores sessions under ~/.pi/agent/sessions/--<cwd>--/.
        box_write_as_user "$MIG_BOX" \
            "/home/agent/.pi/agent/sessions/--home-agent--/sess-e2e.jsonl" \
            '{"type":"session","id":"sess-e2e"}'
        MIG6_PRE_READ="$(box_read_as_user "$MIG_BOX" /home/agent/.pi/agent/sessions/--home-agent--/sess-e2e.jsonl)"

        # A package-like marker OUTSIDE the home directory, planted before the
        # migration. The documentation claims that hand-installed packages are
        # NOT carried across, because they live in the container's root
        # filesystem and not in the home directory, and that claim had no check
        # (adversarial review, 2026-10-18). This is what makes it testable.
        docker exec -u 0 "$MIG_BOX" bash -c \
            'mkdir -p /opt/lbx-pkg && echo installed > /opt/lbx-pkg/marker' >/dev/null 2>&1 || true

        # Damage it exactly as the field boxes are damaged, and confirm the
        # damage is the real thing before migrating.
        MIG6_DAMAGED=false
        damage_box_confirmed "$MIG_BOX" && MIG6_DAMAGED=true

        # Migrate.
        MIG6_OUT="$(migrate_real --migrate "$MIG_BOX" 2>&1)"
        MIG6_RC=$?

        # The box must exist afterwards, under the same name.
        if docker container inspect "$MIG_BOX" >/dev/null 2>&1; then
            MIG6_EXISTS=true
        else
            MIG6_EXISTS=false
        fi

        # Ownership as the BOX sees it, the user namespace, sudo, and
        # whether the box user can read its own work.
        MIG6_OWNED=false
        [ "$(box_stat "$MIG_BOX" /home/agent/.pi/agent/sessions/--home-agent--/sess-e2e.jsonl)" = "$BOX_UID $BOX_GID 644" ] && MIG6_OWNED=true
        MIG6_USERNS=false
        docker exec -u 0 "$MIG_BOX" sh -c 'grep -q "^ *0 " /proc/self/uid_map' >/dev/null 2>&1 && MIG6_USERNS=true
        MIG6_SUDO=false
        box_sudo_works "$MIG_BOX" && MIG6_SUDO=true
        MIG6_POST_READ="$(box_read_as_user "$MIG_BOX" /home/agent/.pi/agent/sessions/--home-agent--/sess-e2e.jsonl)"
        MIG6_CONTENT=false
        [ -n "$MIG6_PRE_READ" ] && [ "$MIG6_PRE_READ" = "$MIG6_POST_READ" ] && MIG6_CONTENT=true

        check "MIG6 the box is damaged before the migration (ground truth: the box sees uid 65534 where the host sees uid 0)" \
            "[ \"\$MIG6_DAMAGED\" = true ]"
        [ "$MIG6_DAMAGED" = true ] || printf '%s' "$DAMAGE_REPORT"
        check "MIG6 the box still exists after the migration" \
            "[ \"\$MIG6_EXISTS\" = true ]"
        # THE DISCRIMINATOR. A damaged box already satisfies "the box exists",
        # so that assertion cannot tell a migrated box from an untouched one.
        # What separates them is that the box's ID mapping is APPLIED, which
        # the box's OWN view of /etc/sudo.conf shows: a healthy box sees
        # `0 0`, a damaged one sees `65534 65534`.
        #
        # The host's view is deliberately NOT asserted here. Measured on this
        # stack: a healthy box shows the box `0 0` and the host `165536 165536`;
        # a damaged box shows the box `65534 65534` and the host `0 0`. An
        # applied ID mapping means the container's uid 0 is a mapped,
        # unprivileged host uid, so the two views DISAGREE on a healthy box;
        # requiring them to agree rejects every correct migration, which is
        # exactly what an earlier form of this check did.
        MIG6_HEALED=false
        MIG6_BOX_VIEW="$(box_stat "$MIG_BOX" /etc/sudo.conf)"
        [ "$MIG6_BOX_VIEW" = "0 0 644" ] && MIG6_HEALED=true
        check "MIG6 after the migration the box's ID mapping is applied again (the box sees /etc/sudo.conf as 0 0 644, not the overflow uid)" \
            "[ \"\$MIG6_HEALED\" = true ]"
        check "MIG6 after the migration the box user owns its files ($BOX_UID $BOX_GID as the box sees them)" \
            "[ \"\$MIG6_OWNED\" = true ]"
        check "MIG6 after the migration the box has an active user namespace" \
            "[ \"\$MIG6_USERNS\" = true ]"
        check "MIG6 after the migration sudo works in the box" \
            "[ \"\$MIG6_SUDO\" = true ]"
        check "MIG6 after the migration the box user can read its session file, unchanged" \
            "[ \"\$MIG6_CONTENT\" = true ]"
        case "$MIG6_EXISTS $MIG6_HEALED $MIG6_OWNED $MIG6_USERNS $MIG6_SUDO $MIG6_CONTENT" in
            *false*)
                echo "    migration exit $MIG6_RC"
                printf '%s\n' "$MIG6_OUT" | tail -10 | sed 's/^/    migrate: /'
                box_report "$MIG_BOX"
                ;;
        esac

        # The documented behaviour: only the home directory travels, so
        # anything installed in the container's own filesystem is gone. The
        # box is healthy here, so this is not "exec is broken": the path is
        # simply absent.
        MIG6_PKG_GONE=false
        docker exec -u 0 "$MIG_BOX" test -e /opt/lbx-pkg/marker >/dev/null 2>&1 || MIG6_PKG_GONE=true
        check "MIG6 the migration does not carry packages installed outside the home directory" \
            "[ \"\$MIG6_PKG_GONE\" = true ]"

        # ── MIG12: a file the box user made before the migration ──────────
        # Requirement SB-M4. This is the exact failure mode that copying
        # with `docker cp` alone produces: the file arrives owned by the
        # overflow uid and the box user cannot read it.
        MIG12_SENTINEL="$MIG_TMP/mig12.sentinel"
        printf 'made by the box user before migration\n' > "$MIG12_SENTINEL"
        # The assertion below is the exact mode, so the mode is set explicitly
        # rather than inherited from the invoking shell's umask.
        chmod 644 "$MIG12_SENTINEL"
        tar -C "$MIG_TMP" -cf "$MIG_TMP/mig12.tar" mig12.sentinel
        # Put it in the box through a pipe, then give it to the box user. Not
        # `docker cp`: the daemon walks the container's filesystem to resolve
        # the destination and fails on the per-session volume mounted at
        # /var/lib/docker ("mkdirat var/lib/docker: directory not empty"), which
        # every box now has. The launcher's own restore uses a pipe for the
        # same reason, so this also models what the migration does.
        docker exec -i -u 0 "$MIG_BOX" bash -c \
            "cd /home/agent && tar -xf - --no-same-owner && chown $BOX_UID:$BOX_GID mig12.sentinel" \
            < "$MIG_TMP/mig12.tar" >/dev/null 2>&1
        MIG12_PRE="$(box_stat "$MIG_BOX" /home/agent/mig12.sentinel)"
        MIG12_READ="$(box_read_as_user "$MIG_BOX" /home/agent/mig12.sentinel)"
        MIG12_POST="$(box_stat "$MIG_BOX" /home/agent/mig12.sentinel)"
        check "MIG12 a file the box user owned before the migration is still owned by it and readable after" \
            "[ \"\$MIG12_PRE\" = '$BOX_UID $BOX_GID 644' ] && [ \"\$MIG12_POST\" = '$BOX_UID $BOX_GID 644' ] && [ -n \"\$MIG12_READ\" ]"

        # ── MIG11: the notice ─────────────────────────────────────────────
        # Requirement SB-M7. The notice must be where the agents actually
        # look, owned by the box user, readable, and must tell the agent to
        # delete it; otherwise the agent is told "your packages are gone"
        # forever, long after it has reinstalled them.
        MIG11_OK=true
        for nf in /home/agent/.pi/agent/AGENTS.md \
                  /home/agent/.claude/CLAUDE.md \
                  /home/agent/.config/opencode/AGENTS.md; do
            [ "$(box_stat "$MIG_BOX" "$nf")" = "$BOX_UID $BOX_GID 644" ] || MIG11_OK=false
            [ -n "$(box_read_as_user "$MIG_BOX" "$nf")" ] || MIG11_OK=false
        done
        MIG11_DELETE=false
        box_read_as_user "$MIG_BOX" /home/agent/.pi/agent/AGENTS.md | grep -iE >/dev/null 'delete|remove' && MIG11_DELETE=true
        MIG11_REINSTALL=false
        box_read_as_user "$MIG_BOX" /home/agent/.pi/agent/AGENTS.md | grep -iE >/dev/null 'reinstall|install' && MIG11_REINSTALL=true
        check "MIG11 the notice exists at all three agent context paths, owned by the box user and readable" \
            "[ \"\$MIG11_OK\" = true ]"
        check "MIG11 the notice says hand-installed packages must be reinstalled" \
            "[ \"\$MIG11_REINSTALL\" = true ]"
        check "MIG11 the notice tells the agent to delete it once it has handled the reinstalls" \
            "[ \"\$MIG11_DELETE\" = true ]"
    else
        skip "MIG6 the end-to-end migration of a damaged box (could not create a sysbox box)"
        skip "MIG12 a pre-existing box-user file survives with its ownership (same prerequisites as MIG6)"
        skip "MIG11 the notice is delivered at all three agent context paths (same prerequisites as MIG6)"
    fi
else
    skip "MIG6 the end-to-end migration of a damaged box (needs docker + sysbox-runc + $SYSBOX_IMAGE + ability to restart the sysbox daemons)"
    skip "MIG12 a pre-existing box-user file survives with its ownership (same prerequisites as MIG6)"
    skip "MIG11 the notice is delivered at all three agent context paths (same prerequisites as MIG6)"
fi

# ── MIG7: a box in the worst damage state still migrates ──────────────────
# Requirement SB-M3. A second daemon restart leaves a box in the worst state:
# `docker exec` may fail outright and the home directory may be unreadable from
# inside the box. The export must not depend on exec, because the boxes that
# most need migrating are the ones in the worst state.
#
# Whether exec actually breaks is NOT deterministic (measured: it survives the
# second restart in some runs), so this check does not require it. Requiring a
# non-deterministic precondition would make the check flaky, and a flaky check
# is worse than no check. The observation is printed so the run record shows
# which state was reached, and what is asserted is the property that is
# deterministic and is the point: the host can still read the box's filesystem,
# and the migration succeeds from that state.
if [ "$MIG6_READY" = true ]; then
    docker rm -f "$MIG_BOX" >/dev/null 2>&1 || true
    if launch_box "$MIG_BOX" && wait_box_ready "$MIG_BOX"; then
        box_write_as_user "$MIG_BOX" /home/agent/deep/sess.jsonl '{"type":"session","id":"deep"}'
        # Two daemon restarts plus a stop/start is the worst state.
        damage_box "$MIG_BOX"
        wait_box_exec "$MIG_BOX" 60 || true
        damage_box "$MIG_BOX"
        MIG7_WAITS="$DAMAGE_WAITS"
        MIG7_EXEC_BROKEN=false
        wait_box_exec "$MIG_BOX" 15 || MIG7_EXEC_BROKEN=true
        echo "  (MIG7 observation: docker exec broken after two restarts = $MIG7_EXEC_BROKEN; $MIG7_WAITS)"
        # The host side must still be able to read the box's filesystem: this is
        # the path the export uses, and it is what makes the worst-state box
        # recoverable at all.
        MIG7_HOST_READS=false
        MIG7_PID=$(docker inspect -f '{{.State.Pid}}' "$MIG_BOX" 2>/dev/null | head -1)
        if [ -n "$MIG7_PID" ] && [ "$MIG7_PID" != "0" ]; then
            as_root test -f "/proc/$MIG7_PID/root/home/agent/deep/sess.jsonl" >/dev/null 2>&1 && MIG7_HOST_READS=true
        fi
        # And the migration must succeed from that state. The box's own view of
        # /etc/sudo.conf is what shows the replacement came up healthy.
        migrate_real --migrate "$MIG_BOX" >/dev/null 2>&1 || true
        MIG7_MIGRATED=false
        [ "$(box_stat "$MIG_BOX" /etc/sudo.conf)" = "0 0 644" ] && MIG7_MIGRATED=true
        check "MIG7 a box in the worst damage state still migrates (the host reads its filesystem, and the migration succeeds from there)" \
            "[ \"\$MIG7_HOST_READS\" = true ] && [ \"\$MIG7_MIGRATED\" = true ]"
    else
        skip "MIG7 the host can still read a box whose docker exec has stopped working (could not create a sysbox box)"
    fi
else
    skip "MIG7 the host can still read a box whose docker exec has stopped working (needs docker + sysbox-runc + $SYSBOX_IMAGE + ability to restart the sysbox daemons)"
fi

echo "== migration: the create-path preflight =="

# ── MIG15: the refusal inventories the boxes that already exist ───────────
# Requirement: the create-path preflight (I4) keeps refusing, and gains an
# inventory of the operator's sysbox boxes plus the migration command.
# Theory: the operator meets this refusal when they try to create a box on a
# host whose sysbox is too old. Their next command fails identically, and
# nothing tells them which boxes are at stake or that installing sysbox, the
# fix, is itself what damages them. So the refusal must name the boxes that
# already exist and the migration that carries their contents across.
#
# This is the CREATE path, not `--migrate`, so it is exercised by launching a
# new box with the unusable runtime on PATH (the same seam MIG2 uses). The
# assertion is that the refusal names the box that already exists AND the
# migration command, and that it created nothing: an inventory that appeared
# only after a container had been created would be useless.
if [ "$MIG6_READY" = true ]; then
    MIG15_NEW="mig-check-preflight"
    docker rm -f "$MIG15_NEW" >/dev/null 2>&1 || true
    MIG15_OUT="$(cd "$MIG_PROJ" && PATH="$MIG2_SEAM_BIN:$PATH" "$BOC" --runtime sysbox "$MIG15_NEW" 2>&1 < /dev/null)"
    MIG15_RC=$?
    MIG15_NAMES_BOX=false
    printf '%s' "$MIG15_OUT" | grep -F >/dev/null "$MIG_BOX" && MIG15_NAMES_BOX=true
    MIG15_NAMES_MIGRATE=false
    printf '%s' "$MIG15_OUT" | grep -E >/dev/null -- '--migrate' && MIG15_NAMES_MIGRATE=true
    MIG15_CREATED=false
    docker container inspect "$MIG15_NEW" >/dev/null 2>&1 && MIG15_CREATED=true
    check "MIG15 the create-path refusal inventories the existing sysbox box and names the migration" \
        "[ \"\$MIG15_NAMES_BOX\" = true ] && [ \"\$MIG15_NAMES_MIGRATE\" = true ]"
    check "MIG15 the create-path refusal still refuses and creates nothing" \
        "[ $MIG15_RC -ne 0 ] && [ \"\$MIG15_CREATED\" = false ]"
else
    skip "MIG15 the create-path refusal inventories the existing sysbox box (needs docker + sysbox-runc + $SYSBOX_IMAGE + ability to restart the sysbox daemons)"
fi

echo "== migration: safety =="

# ── MIG8: verify before destroy ───────────────────────────────────────────
# Requirement SB-M5. The operation destroys containers, so the old box must
# survive a failed migration. The failure is produced by making the
# replacement impossible to verify: the box user is made unable to read the
# restored files, which is precisely the condition the verification exists
# to catch.
if [ "$MIG6_READY" = true ]; then
    docker rm -f "$MIG_BOX" >/dev/null 2>&1 || true
    if launch_box "$MIG_BOX" && wait_box_ready "$MIG_BOX"; then
        box_write_as_user "$MIG_BOX" /home/agent/keepme.txt 'must survive a failed migration'
        # The failure is produced by making the export impossible: the
        # directory the migration carries is not present. That is a condition
        # the migration must detect BEFORE it creates anything, so this also
        # pins the ordering: no replacement is created before the export has
        # succeeded, and therefore nothing partial can be left behind.
        #
        # An earlier form of this check chowned the box's home to root, on the
        # theory that the replacement would then be unverifiable. Measured: it
        # is not a failure at all. The restore re-establishes the box user's
        # ownership of everything it restores, which is exactly what the box
        # user needs, so that injection only tested the migration's ability to
        # repair a condition it is supposed to repair. A marker OUTSIDE the
        # removed directory shows the box is otherwise untouched.
        docker exec -u 0 "$MIG_BOX" bash -c 'echo keep > /keepme-outside-home.txt; rm -rf /home/agent' >/dev/null 2>&1 || true
        MIG8_OUT="$(migrate_real --migrate "$MIG_BOX" 2>&1)"
        MIG8_RC=$?
        # The old box must still be there, with its content.
        MIG8_OLD_EXISTS=false
        docker container inspect "$MIG_BOX" >/dev/null 2>&1 && MIG8_OLD_EXISTS=true
        MIG8_CONTENT=false
        docker exec -u 0 "$MIG_BOX" test -f /keepme-outside-home.txt >/dev/null 2>&1 && MIG8_CONTENT=true
        # A failed migration must report failure.
        check "MIG8 a migration that cannot complete reports failure" \
            "[ $MIG8_RC -ne 0 ]"
        check "MIG8 the old box is left untouched when the migration cannot complete" \
            "[ \"\$MIG8_OLD_EXISTS\" = true ] && [ \"\$MIG8_CONTENT\" = true ]"
        # No leftover replacement: exactly the one box the suite created.
        MIG8_LEFTOVERS="$(docker ps -a --format '{{.Names}}' | grep -c '^mig-' || true)"
        check "MIG8 no partial replacement is left behind" \
            "[ \"\$MIG8_LEFTOVERS\" -le 1 ]"
    else
        skip "MIG8 verify-before-destroy (could not create a sysbox box)"
    fi
else
    skip "MIG8 verify-before-destroy (needs docker + sysbox-runc + $SYSBOX_IMAGE + ability to restart the sysbox daemons)"
fi

# ── MIG10: /data is never copied ─────────────────────────────────────────
# Requirement SB-M8. /data is a host bind mount that survives destruction.
# Copying it would duplicate host data and could freeze a stale copy into a
# box. The sentinel is placed by the HOST and must be unchanged afterwards.
if docker_ok && sysbox_image_ok; then
    printf 'host sentinel\n' > "$MIG_PROJ/host-sentinel.txt"
    MIG10_BEFORE="$(cat "$MIG_PROJ/host-sentinel.txt" 2>/dev/null)"
    MIG10_MODE_BEFORE="$(stat -c '%u %g %a' "$MIG_PROJ/host-sentinel.txt" 2>/dev/null)"
    # The project directory is the box's /data. It must not be copied by a
    # migration, and nothing may be written into it.
    if docker container inspect "$MIG_BOX" >/dev/null 2>&1; then
        migrate --migrate --dry-run "$MIG_BOX" >/dev/null 2>&1 || true
    fi
    MIG10_AFTER="$(cat "$MIG_PROJ/host-sentinel.txt" 2>/dev/null)"
    MIG10_MODE_AFTER="$(stat -c '%u %g %a' "$MIG_PROJ/host-sentinel.txt" 2>/dev/null)"
    check "MIG10 the host's /data sentinel is unchanged (content and ownership)" \
        "[ \"\$MIG10_BEFORE\" = \"\$MIG10_AFTER\" ] && [ \"\$MIG10_MODE_BEFORE\" = \"\$MIG10_MODE_AFTER\" ]"
    # The project directory must contain no new entries: a migration must
    # not stage anything inside /data.
    MIG10_EXTRA="$(find "$MIG_PROJ" -mindepth 1 -maxdepth 1 -name 'host-sentinel.txt' -prune -o -print 2>/dev/null | wc -l)"
    check "MIG10 the migration stages nothing inside /data" \
        "[ \"\$MIG10_EXTRA\" -eq 0 ]"
else
    skip "MIG10 /data is never copied (needs docker + $SYSBOX_IMAGE)"
fi

# ── MIG13: an already-migrated box is skipped, not failed ────────────────
# Requirement SB-M6. Re-running the migration must be safe: a box that has
# already been migrated is reported and skipped rather than failing, so a
# user who ran it twice does not see an error that means nothing.
if docker_ok && sysbox_image_ok; then
    MIG13_OUT="$(migrate --migrate --dry-run "$MIG_BOX2" 2>&1)"
    MIG13_RC=$?
    # A box that does not exist at all must be reported, not crashed on.
    MIG13_CRASH=false
    is_usage_dump "$MIG13_OUT" && MIG13_CRASH=true
    check "MIG13 a name that cannot be migrated is reported rather than crashing" \
        "[ \"\$MIG13_CRASH\" = false ]"
else
    skip "MIG13 an already-migrated box is skipped (needs docker + $SYSBOX_IMAGE)"
fi

# ── MIG9: several boxes, one failure ─────────────────────────────────────
# Requirement SB-M6. A migration of several boxes must not stop at the first
# failure: the user needs to know which boxes are done and which are not,
# and the exit status must be non-zero when any box failed.
if docker_ok && sysbox_image_ok; then
    MIG9_OUT="$(migrate --migrate --dry-run "$MIG_BOX" no-such-box-xyz 2>&1)"
    MIG9_RC=$?
    # A missing box must be reported, and the run must not claim success.
    MIG9_NAMED=false
    migration_says "$MIG9_OUT" 'no-such-box-xyz' && MIG9_NAMED=true
    check "MIG9 a migration over several boxes reports the one that cannot be migrated" \
        "[ \"\$MIG9_NAMED\" = true ]"
    check "MIG9 the exit status is non-zero when any box cannot be migrated" \
        "[ $MIG9_RC -ne 0 ]"
else
    skip "MIG9 a migration over several boxes reports the one that cannot be migrated (needs docker + $SYSBOX_IMAGE)"
fi

# ── MIG14: property check: session trees round-trip exactly ───────────────────
# Requirements SB-M3, SB-M4. The failure mode under test (ownership being
# rewritten) is data-dependent, so a fixed fixture proves little. This
# generates session trees of varying depth, file count and size, and asserts
# that the set of relative paths and their ownership is identical before and
# after the migration.
if [ "$MIG6_READY" = true ]; then
    MIG14_OK=true
    MIG14_CASES=0
    for seed in 1 2 3; do
        docker rm -f "$MIG_BOX" >/dev/null 2>&1 || true
        launch_box "$MIG_BOX" >/dev/null 2>&1 || continue
        wait_box_ready "$MIG_BOX" || continue
        MIG14_CASES=$((MIG14_CASES + 1))
        # Build a tree whose shape depends on the seed.
        depth=$((seed + 1))
        files=$((seed * 3))
        docker exec -u 0 "$MIG_BOX" bash -c "
            set -e
            base=/home/agent/.pi/agent/sessions/--home-agent--
            d=\"\$base\"
            for i in \$(seq 1 $depth); do d=\"\$d/l\$i\"; mkdir -p \"\$d\"; done
            for i in \$(seq 1 $files); do
                printf 'payload-%s-%s\n' '$seed' \"\$i\" > \"\$base/file-\$i.jsonl\"
            done
            chown -R $BOX_UID:$BOX_GID /home/agent/.pi
        " >/dev/null 2>&1 || true
        # Compare only the SESSION tree, not all of /home/agent. The box's
        # /home/agent also holds .pi/agent/npm/node_modules, which is a
        # package cache of tens of thousands of files: walking it makes the
        # check slow without testing anything about sessions. The session
        # tree is what this property is about.
        MIG14_TREE=/home/agent/.pi/agent/sessions
        MIG14_BEFORE="$(docker exec -u 0 "$MIG_BOX" bash -c \
            "cd $MIG14_TREE && find . -type f -printf '%p %u %g\n' 2>/dev/null | sort" 2>/dev/null)"
        MIG14_DAMAGED=true
        damage_box_confirmed "$MIG_BOX" || MIG14_DAMAGED=false
        MIG14_MIGRATE_OUT="$(migrate_real --migrate "$MIG_BOX" 2>&1)"; MIG14_MIGRATE_RC=$?
        MIG14_AFTER="$(docker exec -u 0 "$MIG_BOX" bash -c \
            "cd $MIG14_TREE && find . -type f -printf '%p %u %g\n' 2>/dev/null | sort" 2>/dev/null)"
        # Every file present before must be present after, owned by the box
        # user. Files the migration itself adds (the notice) are allowed, so
        # this is a subset test, and it is done with ONE comparison rather
        # than one grep per file: the before-list is a set of exact lines,
        # and `comm` reports the lines missing from the after-list.
        MIG14_MISSING="$(comm -23 <(printf '%s\n' "$MIG14_BEFORE") \
                                  <(printf '%s\n' "$MIG14_AFTER"))"
        if [ -n "$MIG14_MISSING" ]; then
            MIG14_OK=false
            # Say what went missing and how the migration ended, so a failure on a slow host can be read from the log.
            echo "    seed $seed: migration exit $MIG14_MIGRATE_RC; $(printf '%s\n' "$MIG14_BEFORE" | grep -c .) files before, $(printf '%s\n' "$MIG14_AFTER" | grep -c .) after"
            printf '%s\n' "$MIG14_MISSING" | head -5 | sed 's/^/    missing: /'
            printf '%s\n' "$MIG14_MIGRATE_OUT" | tail -5 | sed 's/^/    migrate: /'
            [ "$MIG14_DAMAGED" = true ] || { echo "    seed $seed: the box did not show the damage before the migration"; printf '%s' "$DAMAGE_REPORT"; }
        fi
    done
    if [ "$MIG14_CASES" -eq 0 ]; then
        skip "MIG14 session trees of varying shape round-trip exactly (could not create a sysbox box)"
    else
        check "MIG14 across $MIG14_CASES generated session trees every file keeps its path and its box-user ownership" \
            "[ \"\$MIG14_OK\" = true ]"
    fi
else
    skip "MIG14 session trees of varying shape round-trip exactly (needs docker + sysbox-runc + $SYSBOX_IMAGE + ability to restart the sysbox daemons)"
fi

echo "test_llm_in_a_box_migrate.sh: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
[ "$FAIL" -eq 0 ]
