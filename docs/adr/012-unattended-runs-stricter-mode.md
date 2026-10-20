# 012: Unattended runs are a separate mode with stricter defaults

### Status

Accepted (2026-09-24).

Extended by [014](014-unattended-runs-socket-directory-and-no-network.md):
`--no-network` is an alternative to the mandatory wall of decision 1, and a
caller's socket directory is the one exception to the socket rule of
decision 5.

### Context

`lbx` was designed for an operator at a terminal working on their own
code. Its defaults reflect that: the network wall is optional, `GH_TOKEN`
is forwarded automatically, the docker runtime is privileged and runs an
inner dockerd, the current directory is mounted, and every launch ends in
an interactive attach.

Unattended jobs are different. Nobody watches them, they are created for
one task, and their input includes text the operator does not control
(repository contents, log lines, chat messages), which can steer the
agent into running any command in the box. Applying the interactive
defaults to them would give such an agent a privileged container, an
open network, the operator's working tree and whatever credential happens
to be in the environment.

### Decision

`lbx` gains an unattended mode, `--run`, with its own, stricter defaults.
In summary (the full list of refusals is in `docs/llm/unattended-runs_llm.md`):

1. The network wall is mandatory and must be in `enforce` or `locked`
   mode; names outside the docker network do not resolve in the run
   box, and its connections to public addresses, to the host through
   its network, to the metadata address and to public IPv6 addresses
   fail, so the relay is its way out; the relay itself runs with dropped
   capabilities.
2. No host variable reaches the box unless named with `--env`, and named
   variables reach only the command, never the container's configuration.
3. The docker runtime runs unprivileged: capabilities dropped to the
   entrypoint's measured minimum, no new privileges, default seccomp and
   AppArmor, no inner dockerd, no docker group, no sudoers file. Host user
   id 0 and group id 0 are refused.
4. Only the docker runtime is accepted, named explicitly.
5. A dedicated data directory is mounted, never the current directory. It
   may not contain, anywhere in its tree, a `.git` entry, a symbolic link,
   a mount point, an entry owned by someone else, a socket, a named pipe,
   a device file, or a regular file with a hard link outside the tree; it
   must be readable in full; and it may not overlap the home directory,
   the launcher's own state or configuration, the policy file's directory
   or the vm artifact directory. The authoritative list is in
   `docs/llm/unattended-runs_llm.md`.
6. The run box, relay and networks are removed when the run ends,
   whatever the cause, except when docker refuses a removal, which the
   run reports as `cleanup=incomplete` with the command that removes
   what is left, and except when `lbx` itself is killed with SIGKILL or
   the host is lost; then the run box still removes itself when its
   lifetime ends.
7. Host-exposing features (devices, published ports, filesystem in
   userspace) are refused.

Interactive sessions keep every existing default.

### Consequences

- Positive: unattended use gets a posture strictly narrower than an
  interactive docker session, without weakening or complicating
  interactive use.
- Positive: every unattended run is self-contained. It leaves behind only
  its deny log and its status file; after SIGKILL of `lbx`, the relay and
  networks also remain until removed with the documented commands.
- Negative: two security postures in one launcher. Documentation must
  make the difference obvious, and tests must pin both.
- Negative: a job that needs an inner docker daemon, sysbox or the vm
  runtime cannot use `--run` as decided here.
- Unchanged: llm-in-a-box remains host isolation, not an adversarial
  sandbox. Jobs processing untrusted input should still run inside a
  disposable virtual machine that holds only what the job needs.

### For LLMs

- Scope: `lbx --run` only. Interactive defaults unchanged; never apply run
  defaults to interactive paths or the reverse.
- Invariants of a run box: `--net-policy` mode in {enforce, locked};
  internal network only; `--dns 127.0.0.1` (outside names do not
  resolve); proxy by the relay's numeric address; IPv6 disabled with the
  `all` setting; connections to public addresses, to the host through
  the run's network, to the metadata address and to public IPv6
  addresses fail; relay `--cap-drop ALL`, `no-new-privileges`, read-only
  root.
- Invariants of privilege: no `--privileged`; `--cap-drop ALL` plus the
  measured set; `no-new-privileges`; default seccomp and AppArmor;
  `LBX_NO_INNER_DOCKER=1` (no dockerd, no docker group, no sudoers
  entry).
- Invariants of data: `--data` required; mounted at `/data`; refused if
  its tree has a `.git` entry, a symbolic link, a mount point, a
  foreign-owned entry, a socket, a named pipe, a device file or a
  regular file with a hard link outside the tree, if any part of it
  cannot be read, or if it overlaps `HOME`, the state directory, the
  configuration directory, the policy file's directory or the vm artifact
  directory in either direction; the authoritative list is in
  `docs/llm/unattended-runs_llm.md`.
- Invariants of variables: only `--env` names; passed on the command's
  `docker exec`; never on `docker run`; reserved names refused.
- Invariants of lifetime: `--timeout` required; cleanup on every exit
  path except SIGKILL or host loss, and a removal docker refuses is
  reported as `cleanup=incomplete` with the command that removes what is
  left; process 1 is a sleep of timeout plus the readiness maximum plus
  60 seconds (timeout plus 120 seconds with the default readiness
  maximum of 60) with `--rm`, so an orphaned run box removes itself; the
  status file in `runs/<name>` (never mounted) is the authoritative
  outcome.
- Runtime: docker only, explicit.

