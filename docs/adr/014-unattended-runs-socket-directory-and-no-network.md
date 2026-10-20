# 014: Unattended runs may use a caller's socket directory and may run with no network

### Status

Accepted (2026-09-29). Extends [012](012-unattended-runs-stricter-mode.md).
Decision item 5 (the AppArmor profile) was added 2026-09-29; its refusal
conditions and the matching "For LLMs" words were amended 2026-09-30, as
was item 3's description of the no-network run box's interfaces.

### Context

Decision record 012 gives an unattended run (`lbx --run`) two channels:
the data directory, and the relay to the public hosts its policy allows.
The wall is mandatory, and the data directory refuses sockets because a
socket is a direct line to a host process, around the relay.

Unattended jobs also need live access to services the caller runs outside
the box and that hold credentials the box must not see: a tools server, a
model gateway. The relay refuses private addresses by design, and files in
the data directory are not a live conversation. Once every service a job
needs is reachable that way, the relay, its networks and the policy are
surface the job does not need.

A live socket carries its own risks: it is a more active attack surface
than files, nothing records its traffic automatically, and a mount of a
single socket file breaks when the server recreates its socket.

### Decision

1. `--run` accepts `--socket-dir <dir>`, off by default. The directory is
   mounted read-only at `/run/agent` in the run box, so the command can
   connect to sockets the caller serves there, and nothing in the box can
   create, remove or replace an entry. It is always a directory, never a
   single socket file. It must be owned by the invoking user, not writable
   by group or others, not a symbolic link, and hold only sockets that
   user owns; it may not overlap the data directory, the home directory,
   the launcher's state or configuration, the policy file's directory or
   the vm artifact directory, may not be or contain the user's runtime
   directory, and may not hold a socket that is the ssh-agent, docker or
   D-Bus session socket. The authoritative list is in
   `docs/llm/unattended-runs_llm.md`.
2. This is the one deliberate exception to 012's rule that the data
   directory holds no socket. It is acceptable because the caller names
   the directory on purpose, it is outside `/data` and every launcher
   directory, it holds only the caller's own sockets, and it is read-only
   in the box. The data-directory rule is unchanged.
3. `--run` accepts `--no-network`, off by default, as the alternative to
   `--net-policy`: exactly one of the two is required. A no-network run
   box has only a loopback interface in use (the kernel's fallback tunnel
   devices may be present, down and without an address; owner decision
   2026-09-30); no relay and no run network is created. This satisfies
   the intent of 012's mandatory wall (no unmediated way out) strictly,
   since there is no way out at all. It is
   an option of `--run`, not a policy mode, so interactive policy files
   and their validation are unchanged.
4. What a socket allows is decided by the caller's server, not by `lbx`.
   The caller is responsible for that server's limits (message size,
   timeouts, connection caps, rate limits) and for logging its traffic.
   The documentation says so, recommends one socket per purpose, and
   states that the feature is for Linux hosts.
5. `--run` accepts `--apparmor-profile`, off by default. It runs the run
   box under the AppArmor profile `llm-in-a-box-run` (in a no-network run
   its companion `llm-in-a-box-run-no-network`, from the same file), shipped
   in this
   repository as `apparmor/llm-in-a-box-run` and loaded by root on the
   host (`apparmor_parser -r`); `lbx` refuses the option when AppArmor is
   disabled, when the kernel's AppArmor does not mediate Unix sockets (the
   profile would load there, but its socket rules would not be enforced),
   when the profile the run needs is not loaded, or when that profile is
   not in enforce mode. The profile keeps
   docker-default's rules, allows writing, and so connecting to pathname
   sockets, only in `/run/agent`, `/data`, `/tmp`, `/var/tmp`, `/dev/shm`,
   the box user's home directory and the few system paths the entrypoint
   and tools need, limits abstract and anonymous sockets to processes
   under the same profile, and in a no-network run also denies internet
   sockets. AppArmor mediates pathname sockets only through file rules,
   so the profile cannot stop a connection to a socket inside a writable
   directory such as `/data` or `/tmp`; it is defense in depth, not the
   boundary that decides which sockets the box can reach.

Every other decision of 012 stands, and interactive sessions are
unchanged.

### Consequences

- Positive: a job can use credentialed services without the credentials
  entering the box, and can run with no network at all.
- Positive: a no-network run is strictly narrower than a relay run.
- Negative: a socket widens the run box by whatever its server allows;
  `lbx` cannot check or limit that, and a caller who puts a
  general-purpose socket in the directory hands the box that power.
- Negative: socket traffic has no audit trail unless the caller's server
  keeps one; the deny log covers only the relay.
- Unchanged: llm-in-a-box remains host isolation, not an adversarial
  sandbox.

### For LLMs

- Scope: `lbx --run` only; both options are refused without `--run`.
- `--socket-dir <dir>`: at most once; mounted with `--mount
  type=bind,source=<realpath>,target=/run/agent,readonly` on the run box
  only; directory only, owned by the invoking user, mode without group or
  other write, not a symbolic link, only sockets owned by that user (empty
  allowed); no overlap with the data directory, `HOME`, the state
  directory, the configuration directory, the policy file's directory or
  the vm artifact directory; not equal to or an ancestor of the user
  runtime directory; no ssh-agent, docker or D-Bus session socket;
  authoritative list in `docs/llm/unattended-runs_llm.md`.
- It is the only exception to "no socket in the data directory"; that
  rule is unchanged.
- `--no-network`: exactly one of `--net-policy` and `--no-network`; run
  box `--network none`; no relay, no run networks, no `netlogs/<name>`,
  no deny log; all other run-box invariants of 012 unchanged.
- The caller's servers own message limits, timeouts, connection caps,
  rate limits and logging.
- `--apparmor-profile`: `--security-opt apparmor=llm-in-a-box-run` (in a
  no-network run `apparmor=llm-in-a-box-run-no-network`) on the run box
  only; refused unless AppArmor is enabled, the kernel's
  AppArmor mediates Unix sockets
  (`/sys/kernel/security/apparmor/features/network/af_unix` reads `yes`),
  and the needed profile is loaded in enforce mode; writes and
  pathname-socket connects only in `/run/agent`, `/data`, `/tmp`, `/var/tmp`, `/dev/shm`, the home directory and listed
  system paths; abstract and anonymous sockets only among processes under
  the profile; no internet sockets in a no-network run; cannot block a
  socket inside a writable directory.
