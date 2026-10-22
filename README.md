# lbx (llm-in-a-box)

lbx runs coding agents such as Claude Code, Pi, OpenCode and OMP inside
locked-down boxes, so an agent in `--dangerously-skip-permissions` mode can
work on your project without touching your host. A box is a plain docker
container, a sysbox system container or a KVM virtual machine, with your
project mounted at `/data`, an optional network wall with a per-session
allowlist, and an unattended mode for scheduled jobs. It is host isolation,
not an adversarial sandbox: it keeps an agent working on code you trust off
your host, and it does not make untrusted inputs safe.

Supports three isolation runtimes:

| Runtime | Isolation | FUSE | Inner containers | Host requirements |
|---------|-----------|------|------------------|-------------------|
| **docker** | `--privileged` container | Yes | docker (DinD) | docker |
| **sysbox** | user namespace + syscall virtualization | No | docker (DinD) | docker + sysbox-ce 0.7.1+ |
| **vm** | full VM (KVM) | Yes (in-guest) | docker (in-guest daemon) | qemu + KVM + ssh (docker to build) |

## Ten minutes on a plain Ubuntu host with docker

Docker, if you do not have it:

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker
```

1. Install the launcher. Either build it from a checkout (needs a Rust
   toolchain, https://rustup.rs):

   ```bash
   cargo install --path .
   ```

   or download the release binary from the GitHub releases page and put it
   on your `PATH`:

   ```bash
   gh release download --pattern 'lbx-x86_64-unknown-linux-musl*'
   sha256sum -c lbx-x86_64-unknown-linux-musl.sha256
   install -m 755 lbx-x86_64-unknown-linux-musl ~/.local/bin/lbx
   ```

2. Build the docker image. This builds `llm-in-a-box:docker` from the
   `Dockerfile`: Ubuntu 24.04 with Rust, Java, Node, Python, docker, Claude
   Code, Pi, OpenCode and OMP (see [docs/in-box-agents.md](docs/in-box-agents.md)).
   The first build takes about 30 to 40 minutes and several gigabytes;
   `./build` uses `--no-cache`, so every build is a full one.

   ```bash
   ./build docker
   ```

3. Launch a session from your project directory and start an agent inside
   it. The current directory is mounted at `/data`; the in-box user is your
   host user, remapped to your uid and gid; the prompt shows the runtime.

   ```bash
   cd /path/to/your/project
   lbx --runtime docker my_session
   claude --dangerously-skip-permissions
   ```

   `lbx my_session` later re-attaches to the same box, or restarts it if it
   was stopped.

The `docker` runtime also works with Docker Desktop and Rancher Desktop on
macOS and Windows, where the VM layer provides the isolation boundary.

## The sysbox path

[Sysbox](https://github.com/nestybox/sysbox) gives the box its own user
namespace, its own docker daemon and its own init, without KVM. Install
sysbox-ce 0.7.1 or later (below it, sysbox cannot run on current docker)
and the `fuse3` package, which sysbox-fs needs and the sysbox package does
not install:

```bash
# If sysbox is already installed, remove it first. sysbox's own installation
# guide requires this, and it matters here for a second reason: installing
# restarts the sysbox daemons, which silently damages every existing box.
# Upgrading over existing boxes does not lose their work: `lbx --migrate`
# carries each box's home directory (where the agent sessions live) across.
# Upgrade first, then migrate: the replacement box is built on the new stack.
sudo apt-get remove --purge -y sysbox-ce
sudo rm -rf /var/lib/sysbox

wget https://downloads.nestybox.com/sysbox/releases/v0.7.1/sysbox-ce_0.7.1-0.linux_amd64.deb
sudo dpkg -i sysbox-ce_0.7.1-0.linux_amd64.deb
sudo apt-get install -y fuse3
sudo install -m 644 apparmor/fusermount3-sysboxfs /etc/apparmor.d/local/fusermount3
sudo apparmor_parser -r /etc/apparmor.d/fusermount3
docker info | grep sysbox
sysbox-runc --version
```

The two `apparmor` lines matter on Ubuntu 25.04 and later, whose
`fusermount3` AppArmor profile otherwise denies the FUSE mounts sysbox-fs
makes under `/var/lib/sysboxfs`; see docs/sysbox-runtime.md.

Then:

```bash
./build sysbox
lbx --runtime sysbox my_session
```

Sysbox conflicts with FUSE; `--fuse` is an error there. Restarting the
sysbox daemons (a host reboot, a package upgrade) damages every existing
box: its ID mapping is gone and `sudo` inside it reports `owned by uid
65534`. `lbx` refuses to attach to such a box and names the remedy, which
is to migrate it: `sudo -E lbx --migrate <session>` (or `--all`, or
`--dry-run` first) rebuilds the box on the current stack and carries its
home directory, with the agent sessions, across. Recreating it by hand with
`lbx --destroy <session>` and a new launch also works but loses everything
the box accumulated outside `/data`. After a sysbox upgrade the order is:
upgrade sysbox, then `sudo -E lbx --migrate --all`. Details and the failure
modes: [docs/sysbox-runtime.md](docs/sysbox-runtime.md) and
[docs/sysbox-migration.md](docs/sysbox-migration.md).

## The vm path

The `vm` runtime runs each session as a KVM virtual machine with its own
kernel and its own docker daemon. Host prerequisites:

| Requirement | Check | Install if missing |
|---|---|---|
| qemu-system-x86_64 | `command -v qemu-system-x86_64` | `sudo apt-get install -y qemu-system-x86` |
| qemu-img | `command -v qemu-img` | `sudo apt-get install -y qemu-utils` |
| KVM device | `ls -l /dev/kvm` | enable CPU virtualization and the KVM module; on a cloud instance, nested virtualization |
| kvm group | `id -nG \| grep kvm` | `sudo usermod -aG kvm $USER && newgrp kvm` |
| ssh client | `command -v ssh` | `sudo apt-get install -y openssh-client` |
| ssh key | `ls ~/.ssh/*.pub` | `ssh-keygen` |
| docker (build only) | `command -v docker` | see above |

`./build vm` builds the `llm-in-a-box:vm` image and then a bootable base
disk from it, inside a root docker container (no host sudo, no host
`mkfs`), into the launcher's state directory
(`~/.llm-in-a-box/bases/<timestamp>/`, with `bases/latest`). Base disks are
immutable and versioned; a rebuild never touches a running session. The
build's scratch directory, where the root filesystem is unpacked and the
30 GB base disk is filled with it, needs roughly twice the rootfs size and
is a `/tmp` scratch by default. Set `LBX_VM_BUILD_WORK` to put it on another
real local filesystem when the root disk is small: a 15 GB root disk with a
7 GB rootfs fills up and the build dies (the `mkfs` output is suppressed and
the script runs under `set -euo pipefail`, so the log simply stops). It must
not be the 9p project export, which refuses `chown` to root, and the state
directory may be that export, which is why the scratch is separate from it;
a directory you supply is never deleted by the build (tests/test_build_vm.sh,
the scratch-directory checks).

```bash
./build vm
lbx --runtime vm my_session
```

Each VM defaults to 16 GiB of memory and 8 vCPUs (`vm.mem`, `vm.cpus`
below). Sessions persist: `lbx --shutdown my_session` powers the guest off
and keeps its disk, `lbx my_session` resumes it, `--destroy` discards it.
Docker data inside the guest lives on a sparse image at
`<project>/vms_and_docker_from_llm_box/docker-store.img`, attached as a
block device, so the small guest disk never fills up with images. The
launcher attaches it as an NVMe device with serial `lbx-docker-store`, which
fits the 20-character NVMe serial field; a base built by the older launcher
asked for `llm-in-a-box-docker-store`, which the kernel truncates to
`llm-in-a-box-docker-`, so the guest's device finder matches that truncated
prefix as well as the pre-rename `boc-docker-store`, in the by-id glob, the
sysfs serial scan and the identity check (tests/test_vm_docker_store.sh S20,
S21, S21b, S22). Once the vm image is built, auto-detection prefers it:
`lbx <name>` without `--runtime` picks vm, then sysbox, then docker.

## Unattended runs

`lbx --run` runs one command, once, with no terminal, in a new box that is
removed when the command ends, and returns the command's exit code. The run
box is narrower than an interactive session: not privileged, four
capabilities, no inner docker, no sudo; it mounts only the data directory
you name (never the current directory), reaches the network only through
the relay of an `enforce` or `locked` policy, or has no network at all with
`--no-network`; only the host variables named with `--env` reach the
command. The outcome is in `~/.llm-in-a-box/runs/<name>/status`; exit code
124 means timeout and 125 a refusal or setup failure.

```bash
data="$(mktemp -d)"; cp ./inputs/*.md "$data/"
[ -f ~/.config/llm_in_a_box/locked.json ] || install -D -m 644 net-policies/locked.json ~/.config/llm_in_a_box/locked.json
lbx --run --runtime docker --net-policy ~/.config/llm_in_a_box/locked.json \
    --data "$data" --timeout 1800 --env ANTHROPIC_API_KEY \
    job-42 -- claude --dangerously-skip-permissions -p "Summarize /data into /data/summary.md"
cat ~/.llm-in-a-box/runs/job-42/status     # status=exited code=0
```

The options `--socket-dir <dir>` (your Unix sockets, read-only at
`/run/agent`), `--no-network` and `--apparmor-profile` (root loads
`apparmor/llm-in-a-box-run` first) are explained with their downsides in
[docs/unattended-runs.md](docs/unattended-runs.md).

## Network policies

Without `--net-policy` a session has no wall. With one, the box has no
route and no DNS, and exactly one door: a per-session relay outside the box
that matches hostnames against the policy and logs every refusal. Policies
are JSON files (`{"mode": "open|enforce|locked", "allow": [...], "block":
[...]}`) and live under `~/.config/llm_in_a_box/` on the host, where the
box cannot write. Three ship in `net-policies/` and are copied there on the
first interactive use:

| Policy | Mode | What it does |
|---|---|---|
| `open.json` | open | allow everything, log every connection |
| `enforce.json` | enforce | deny by default; a starter allowlist (Anthropic, GitHub, crates.io, Maven Central, Gradle, sbt, npm, PyPI, apt mirrors, Docker Hub, Umans, DeepSeek) |
| `locked.json` | locked | deny by default; only the three model endpoints (Anthropic, Umans, DeepSeek) |

```bash
lbx --net-policy ~/.config/llm_in_a_box/enforce.json my_session
lbx --denied my_session                        # print the session's deny log
```

Deny beats allow, names that resolve to private addresses are refused even
when allowed, and a malformed policy fails closed. An optional key
`idle_timeout_seconds` (30 to 3600, default 300) sets how long a silent
tunnel stays open. Deny reasons: [docs/unattended-runs.md](docs/unattended-runs.md#deny-reasons).

## Sessions

A session name maps to at most one instance across all runtimes, and
`lbx <name>` always finds the existing one. Names match
`[A-Za-z0-9][A-Za-z0-9._-]*`.

```bash
lbx --list                          # NAME RUNTIME STATE PORT, all runtimes
lbx --shutdown foo bar              # graceful stop, keeps the sessions for resume
lbx --stop --force foo              # same, but docker kill / qemu SIGKILL
lbx --destroy foo                   # remove the session, any runtime
lbx --destroy --runtime vm foo      # remove only the vm instance of a duplicate name
sudo -E lbx --migrate --dry-run foo # report what migrating a sysbox box would do
sudo -E lbx --migrate foo bar       # rebuild sysbox boxes on the current stack, keeping /home/agent
sudo -E lbx --migrate --all         # every sysbox box; upgrade sysbox BEFORE migrating
```

Every interactive box (docker and sysbox runtimes) gets a docker volume of
its own, `<session>-docker`, mounted at `/var/lib/docker`, so the inner
docker daemon has a filesystem of its own instead of the container's
overlay (an overlay cannot hold another overlay, so `docker pull` would fail
there); `--destroy` removes the volume with the container, and a migration
removes the old box's volume along with the old box (the replacement has one
of its own, so images the inner docker had pulled are not carried across).

Other launch options: `--device <path>` (repeatable), `--fuse` (docker
only), `--ports` (8080 and 3000, with fallbacks), `--publish
<hostport>:<boxport>` (repeatable), `--vm-web-port <hostport>:<vmport>` for a
qemu VM running inside the box. `lbx --help` prints the full usage.

## Configuration

Precedence: command line flag, then environment variable, then the config
file, then the default. The config file is `$LBX_CONFIG` (default
`~/.config/llm_in_a_box/config`): `key=value` lines, `#` comments allowed.
It must be a regular file owned by you and not writable by others; an
unusable file is a hard error when a new session needs an image and a
warning for `--list`, `--destroy`, `--stop`, `--shutdown` and `--denied`.

| Config key | Environment variable | Default |
|---|---|---|
| `image.sysbox` / `image.docker` / `image.vm` | (none) | `llm-in-a-box:sysbox` / `:docker` / `:vm` |
| `state.dir` | `LBX_STATE_DIR` | `~/.llm-in-a-box` (sessions, base disks, run status, deny logs) |
| `vm.mem` | `LBX_VM_MEM` | `16384` (MiB) |
| `vm.cpus` | `LBX_VM_CPUS` | `8` |
| `vm.accel` | `LBX_VM_ACCEL` | `kvm` (`tcg` = software emulation) |
| `vm.store.size` | `LBX_VM_STORE_IMG_SIZE` | `500G` (sparse; fixed at creation) |
| `vm.store.disable` | `LBX_VM_STORE_DISABLE` | unset (`1` skips the store image) |
| `vm.missing` | `LBX_VM_MISSING` | unset (test only: pretend named vm prerequisites are missing) |
| `runtime.default` | `LBX_RUNTIME_DEFAULT` | unset (auto-detect: vm if built, else sysbox, else docker) |

`./build` reads the same images through `lbx --print-images` and the same
state directory through `lbx --print-state-dir`, so a build and a launch
never disagree. A configured `image.vm` must carry `bash`, `qemu-utils`,
`e2fsprogs`, `tar` and a kernel in `/boot`, because the base disk is built
inside it. If `GH_TOKEN` is set on the host, interactive sessions forward
it so `gh` works inside the box.

## Boxes created by the old launcher

Boxes created by the old launcher carry `box-of-claude.*` docker labels or
`box-of-claude:*` image names, and their in-box user is `claude` (the
current image's user is `agent`). The new launcher lists them, attaches to
a running one, and stops or destroys them, but it does not start a stopped
old box: a box without the box-user stamp (the `llm-in-a-box.user` label on
containers, `bases/<timestamp>/built-user` on vm bases) is refused with the
recommendation to destroy it and create it again. VM sessions in the old
state directory `~/.box-of-claude` are not seen at all.

## Testing

The launcher's own tests run with cargo and need no docker:

```bash
cargo test --locked
```

They are unit tests with exact argument vectors for every docker and qemu
call the launcher builds, property tests (proptest) for names, config lines
and hostile command vectors, binary-level tests against a recording
`fake-docker` (the `--run` refusal catalog, signals, timeouts, cleanup),
snapshots of the recorded docker calls (insta) and transcripts of the usage
and error screens (trycmd). The bash suites in `tests/` drive the binary
against a fake docker, real docker, qemu and sysbox:

```bash
tests/run-all-suites.sh --logs test-logs
```

runs every suite in `tests/` in passes (as your user, then as root), builds
the relay and docker images first unless `--no-build`, and judges every
check across passes; the launcher under test is `--lbx <path>` or the
`LBX_BIN` variable. The docker suites need docker and passwordless sudo;
`test_llm_in_a_box_vm.sh` and `verify-vm-e2e.sh` need qemu, `/dev/kvm` and
the `kvm` group; `test_llm_in_a_box_sysbox.sh` and
`test_llm_in_a_box_migrate.sh` need sysbox installed and the right to
restart its daemons (the migrate suite also needs root or passwordless sudo,
so the runner repeats it in the root pass). A check that skips without being
listed in `tests/approved-skips.txt` fails the run. CI runs `cargo fmt`,
`cargo clippy` and `cargo test`, then builds the images with the classic
docker builder and runs the docker, sysbox and migrate suites, all on
GitHub-hosted runners; the vm suite needs KVM and skips there.
See [docs/testing.md](docs/testing.md).

## Documentation

[docs/README.md](docs/README.md) is the table of contents: testing,
unattended runs, the sysbox runtime and the migration of sysbox boxes,
session removal, what the image installs,
releasing, the decision records in `docs/adr/`, and machine-oriented
copies of each page under `docs/llm/`.

## License

Apache License 2.0; see [LICENSE](LICENSE).
