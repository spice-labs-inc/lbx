#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# setup-run-test-host.sh — prepare a host for the unattended-run suites.
#
# WHAT: creates, idempotently, the fixtures that the unattended-run suites
# need and a normal user cannot create:
#   1. the dedicated test user `lbxtest` (user id 2345, primary group id 100,
#      which collides with the image's `users` group), in the docker group;
#   2. /srv/lbx-test, owned by the invoking user and group `lbxtest`,
#      mode 2775, as a place both users can read the repository from;
#   3. /srv/lbx-test-fixtures/root-owned: an empty root-owned directory (the
#      "not owned by the invoking user" data-directory fixture; empty so it
#      breaks no other data-directory rule);
#   4. /srv/lbx-test-fixtures/foreign-entry: a directory owned by the
#      invoking user holding one root-owned regular file (the "entry owned
#      by someone else" fixture);
#   5. /etc/sudoers.d/lbx-test: the invoking user may run commands as
#      `lbxtest` (only as that user) without a password;
#   6. /srv/lbx-test-fixtures/with-mount: a directory owned by the invoking
#      user with a bind-mounted subdirectory `inner` (the mount-point
#      fixture), backed by /srv/lbx-test-fixtures/mount-source;
#   7. /srv/lbx-test-fixtures/with-socket: a directory owned by the invoking
#      user holding one socket, `sock`, also owned by that user (the
#      "socket inside" fixture; made with a perl one-liner, since no
#      standard command creates a socket file);
#   8. /srv/lbx-test-fixtures/with-device: a directory owned by the invoking
#      user holding one character device, `null` (major 1, minor 3, the
#      same device as /dev/null), also owned by that user (the "device file
#      inside" fixture; only root may create device files).
#   9. /srv/lbx-test-fixtures/with-foreign-socket: a mode-0700 directory
#      owned by the invoking user holding one socket, `sock`, owned by root
#      (the "socket owned by another user" socket-directory fixture: the
#      directory breaks no other socket-directory rule, and only root can
#      give a socket to another owner).
#  10. /run/user/<uid of the invoking user>: exists, owned by that user,
#      mode 0700 (systemd-logind creates it for a login session; a runner
#      without one lacks it). The socket-directory rules refuse this
#      directory, and that rule needs it to exist to be tested.
#  11. The AppArmor profiles llm-in-a-box-run and llm-in-a-box-run-no-network
#      (apparmor/llm-in-a-box-run in this repository), loaded with
#      `apparmor_parser -r` when AppArmor is enabled and apparmor_parser is
#      installed (skipped, or reported as failed, with a message otherwise,
#      never fatal; the checks that need them then fail on their
#      prerequisite).
#  12. The invoking user in the `kvm` group, when /dev/kvm exists (the
#      sessions suite's VM checks need /dev/kvm and that group; a group set
#      is fixed at login, so the membership has to be added here and the
#      user has to log in again). The qemu-system-x86_64 binary is reported
#      but never installed: this script installs no packages.
#
# WHY: the data-directory rules refuse foreign ownership, mount points,
# sockets and device files;
# testing them honestly needs fixtures only root can make, and the
# capability checks need a user whose ids differ from 1000.
#
# Usage: sudo tests/setup-run-test-host.sh <invoking-user>
#   <invoking-user> is the normal user who runs the suites (for example
#   `runtime`). Installs nothing. Prints every action.
#
# LLM-FRIENDLY NOTE: safe to rerun; each step checks before acting. The
# bind mount and the loaded AppArmor profiles do not survive a reboot (the
# profiles are loaded from this tree, not installed in /etc/apparmor.d);
# rerun after one.
# ---------------------------------------------------------------------------
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run with sudo (root is needed to create users, root-owned fixtures and a bind mount)." >&2
    exit 1
fi
OWNER="${1:?usage: sudo $0 <invoking-user>}"
id "$OWNER" >/dev/null 2>&1 || { echo "ERROR: no such user: $OWNER" >&2; exit 1; }
OWNER_GROUP="$(id -gn "$OWNER")"

TEST_USER=lbxtest
TEST_UID=2345
TEST_GID=100

if id "$TEST_USER" >/dev/null 2>&1; then
    echo "ok: user $TEST_USER exists ($(id "$TEST_USER"))"
else
    getent group "$TEST_GID" >/dev/null || { echo "ERROR: group id $TEST_GID does not exist on this host" >&2; exit 1; }
    useradd -m -u "$TEST_UID" -g "$TEST_GID" -s /bin/bash "$TEST_USER"
    echo "created: user $TEST_USER ($(id "$TEST_USER"))"
fi
if id -nG "$TEST_USER" | tr ' ' '\n' | grep -x >/dev/null docker; then
    echo "ok: $TEST_USER is in the docker group"
else
    usermod -aG docker "$TEST_USER"
    echo "added: $TEST_USER to the docker group"
fi

# The invoking user may run commands as the test user (and only as it)
# without a password, so the suite can run VRUN2 as that user. The test
# user has no more access than the invoking user (both are in the docker
# group), so this grants nothing new.
SUDOERS=/etc/sudoers.d/lbx-test
printf '%s ALL=(%s) NOPASSWD: ALL\n' "$OWNER" "$TEST_USER" > "$SUDOERS.new"
chmod 440 "$SUDOERS.new"
if visudo -cf "$SUDOERS.new" >/dev/null; then
    mv "$SUDOERS.new" "$SUDOERS"
    echo "ok: $SUDOERS lets $OWNER run commands as $TEST_USER"
else
    rm -f "$SUDOERS.new"
    echo "ERROR: sudoers rule failed validation" >&2
    exit 1
fi

getent group "$TEST_USER" >/dev/null || { groupadd "$TEST_USER"; echo "created: group $TEST_USER"; }
usermod -aG "$TEST_USER" "$OWNER"
mkdir -p /srv/lbx-test
chown "$OWNER:$TEST_USER" /srv/lbx-test
chmod 2775 /srv/lbx-test
usermod -aG "$TEST_USER" "$TEST_USER"
echo "ok: /srv/lbx-test ($(stat -c '%U:%G %a' /srv/lbx-test))"

F=/srv/lbx-test-fixtures
mkdir -p "$F"
chmod 755 "$F"

mkdir -p "$F/root-owned"
find "$F/root-owned" -mindepth 1 -delete
chown root:root "$F/root-owned"
chmod 755 "$F/root-owned"
echo "ok: $F/root-owned ($(stat -c '%U:%G' "$F/root-owned"))"

mkdir -p "$F/foreign-entry"
chown "$OWNER:$OWNER_GROUP" "$F/foreign-entry"
printf 'fixture\n' > "$F/foreign-entry/root-file.txt"
chown root:root "$F/foreign-entry/root-file.txt"
echo "ok: $F/foreign-entry (dir $(stat -c '%U' "$F/foreign-entry"), entry $(stat -c '%U' "$F/foreign-entry/root-file.txt"))"

mkdir -p "$F/mount-source" "$F/with-mount/inner"
chown "$OWNER:$OWNER_GROUP" "$F/mount-source" "$F/with-mount" "$F/with-mount/inner"
if mountpoint -q "$F/with-mount/inner"; then
    echo "ok: $F/with-mount/inner is a mount point"
else
    mount --bind "$F/mount-source" "$F/with-mount/inner"
    echo "mounted: $F/mount-source on $F/with-mount/inner"
fi

# Each special-file fixture breaks exactly one data-directory rule: the
# directory and the file are owned by the invoking user, so only the file's
# type is wrong.
mkdir -p "$F/with-socket"
chown "$OWNER:$OWNER_GROUP" "$F/with-socket"
if [ ! -S "$F/with-socket/sock" ]; then
    rm -f "$F/with-socket/sock"
    perl -MIO::Socket::UNIX -e 'IO::Socket::UNIX->new(Type => SOCK_STREAM(), Local => $ARGV[0], Listen => 1) or die "socket: $!\n"' "$F/with-socket/sock"
    echo "created: socket $F/with-socket/sock"
fi
chown -h "$OWNER:$OWNER_GROUP" "$F/with-socket/sock"
echo "ok: $F/with-socket (dir $(stat -c '%U' "$F/with-socket"), entry $(stat -c '%F %U' "$F/with-socket/sock"))"

mkdir -p "$F/with-device"
chown "$OWNER:$OWNER_GROUP" "$F/with-device"
if [ ! -c "$F/with-device/null" ]; then
    rm -f "$F/with-device/null"
    mknod "$F/with-device/null" c 1 3
    echo "created: character device $F/with-device/null"
fi
chown "$OWNER:$OWNER_GROUP" "$F/with-device/null"
chmod 600 "$F/with-device/null"
echo "ok: $F/with-device (dir $(stat -c '%U' "$F/with-device"), entry $(stat -c '%F %U' "$F/with-device/null"))"

# The socket-directory fixture: the directory is the invoking user's and
# closed to others, so only the socket's owner is wrong.
mkdir -p "$F/with-foreign-socket"
chown "$OWNER:$OWNER_GROUP" "$F/with-foreign-socket"
chmod 700 "$F/with-foreign-socket"
if [ ! -S "$F/with-foreign-socket/sock" ]; then
    rm -f "$F/with-foreign-socket/sock"
    perl -MIO::Socket::UNIX -e 'IO::Socket::UNIX->new(Type => SOCK_STREAM(), Local => $ARGV[0], Listen => 1) or die "socket: $!\n"' "$F/with-foreign-socket/sock"
    echo "created: socket $F/with-foreign-socket/sock"
fi
chown -h root:root "$F/with-foreign-socket/sock"
echo "ok: $F/with-foreign-socket (dir $(stat -c '%U %a' "$F/with-foreign-socket"), entry $(stat -c '%F %U' "$F/with-foreign-socket/sock"))"

# The user runtime directory, as systemd-logind would create it.
OWNER_UID="$(id -u "$OWNER")"
if [ -d "/run/user/$OWNER_UID" ]; then
    echo "ok: /run/user/$OWNER_UID exists ($(stat -c '%U %a' "/run/user/$OWNER_UID"))"
else
    mkdir -p "/run/user/$OWNER_UID"
    chown "$OWNER:$OWNER_GROUP" "/run/user/$OWNER_UID"
    chmod 700 "/run/user/$OWNER_UID"
    echo "created: /run/user/$OWNER_UID ($(stat -c '%U %a' "/run/user/$OWNER_UID"))"
fi

# The run box's AppArmor profiles, loaded (or replaced) from this tree.
PROFILE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)/apparmor/llm-in-a-box-run"
# Never fatal: a host without AppArmor or without apparmor_parser still
# gets every other fixture, and the checks that need the profiles fail on
# their own prerequisite.
if [ "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null)" != Y ]; then
    echo "skipped: AppArmor is not enabled on this host; the profiles in $PROFILE were not loaded"
elif ! command -v apparmor_parser >/dev/null 2>&1; then
    echo "skipped: apparmor_parser is not installed (package apparmor); the profiles in $PROFILE were not loaded"
elif apparmor_parser -r "$PROFILE"; then
    echo "loaded: AppArmor profiles from $PROFILE"
else
    echo "failed: apparmor_parser could not load $PROFILE (see its message above)"
fi

# The kvm group, for the sessions suite's VM checks. They need /dev/kvm and
# the invoking user in the kvm group, and a group set is fixed at login: adding
# the membership here is what makes the checks runnable after the next login.
# Never fatal, and never guessed: a host without /dev/kvm has no VM checks to
# run, and the binary is reported rather than installed (this script installs
# nothing).
if [ ! -e /dev/kvm ]; then
    echo "skipped: /dev/kvm does not exist on this host; $OWNER was not added to the kvm group (the sessions suite's VM checks need it)"
elif id -nG "$OWNER" | tr ' ' '\n' | grep -x >/dev/null kvm; then
    echo "present: $OWNER is already in the kvm group"
else
    usermod -aG kvm "$OWNER" && echo "added: $OWNER to the kvm group"
fi
command -v qemu-system-x86_64 >/dev/null 2>&1 \
    && echo "present: qemu-system-x86_64" \
    || echo "missing: qemu-system-x86_64 (install the package qemu-system-x86 for the sessions suite's VM checks; qemu-img alone is not enough)"

echo "done. $OWNER must log in again for the new group to apply."
