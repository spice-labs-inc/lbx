# In-box agents and capabilities — LLM reference

Machine-oriented companion of `docs/in-box-agents.md`. Claims are followed by
the check that verifies them, in the form `suite: "check name"`.

## Two modes, one set of steps

- The image is built in two modes from one `Dockerfile`: `slim` (operating
  system, box identity, docker, node, gh, command line tools) and `full`
  (`FROM ${SLIM_IMAGE}`, runs `docker/provision.d/*.sh` at build time).
- `docker/provision.d/` is the only definition of "installed". `lbx-setup` runs
  the same steps inside a slim box.
- Optional tiers: `docker/optional.d/` (any runtime) and
  `docker/optional-vm.d/` (the virtual machine runtime only). Neither is run by,
  or present in, a full image.
- `full` remains the default and `--run` refuses a slim image: a run box has no
  sudo and no inner docker, so it cannot provision itself —
  `tests/test_llm_in_a_box_run.sh` (the `--run` refusal catalog).

## First entry

- A slim box with no provisioning log prints one hint at attach, once. The
  decision uses the probe's answer, and falls back to the image mode the
  launcher resolved when the probe cannot answer.
  Verified: `tests/verify-vm-slim-e2e.sh`: "a fresh slim box is told how to set
  it up", "and names the command to run", "a configured box is not nagged
  again".
- `lbx-setup` with no arguments is a checklist; `--list`, `--status`, `--all`
  and `<step>[,<step>...]` are the non-interactive forms.
  Verified: `tests/test_lbx_setup_ui.sh` ("dialog cannot init: falls back to a
  menu", "the numbered menu is shown", "the chosen step runs", "plain menu
  accepts a step name", "plain menu refuses an out-of-range number", "--list
  works with TERM unset", "no TTY: refuses with guidance").

## Credentials

- `env.forward` defaults to `GH_TOKEN`; `--env NAME` adds or replaces one for a
  session and is valid for interactive sessions and for `--run`.
  Verified: `tests/test_llm_in_a_box_vm_gui.sh`: "the default forward list
  carries GH_TOKEN", "and carries no model key unless one is asked for",
  "--env NAME reaches the box over the attach probe".
- Values are passed at attach time as `~/.lbx/env` (0600, box-user owned):
  over `docker exec -i` stdin for a container, over ssh for the virtual machine,
  sourced by the box user's shell hook in both. Never on `docker run` or in any
  `docker exec` argv, so `docker inspect` does not carry a token and `ps` does
  not show one. Verified by the same suite: "--env NAME is not printed", and by
  the interactive baseline (`tests/test_llm_in_a_box_run.sh`, `REG1`), which
  pins the docker calls of a create.

## Display transport (virtual machine only)

- A step writes `~/.lbx/gui` (`transport=x11` or `wayland`); the launcher reads
  it over the ssh connection it already opens, forwards the display
  (`ssh -X`, `ssh -Y` only when asked, `waypipe ssh` for wayland), prints one
  line, caches the value for `--list`, and degrades to a plain shell with an
  explanation when the host has no display.
  Verified: `tests/test_llm_in_a_box_vm_gui.sh` ("x11 marker + display: ssh -X",
  "--x11=trusted uses ssh -Y", "wayland marker + waypipe + $WAYLAND_DISPLAY:
  waypipe ssh", "wayland app, no waypipe: falls back to ssh -X", "x11 marker, no
  $DISPLAY: attaches anyway (rc 0)", "x11 marker, no $DISPLAY: explains why").
- The transport rides ssh, so the network wall is unaffected and the box gets no
  route to the host display; nothing in the qemu argument vector changes.

## Open CoDesign (virtual machine only, optional tier)

- `lbx-setup design` resolves the release for the box architecture
  (`LBX_DESIGN_VERSION` pins one), downloads the Debian package, verifies its
  archive magic, installs Google Chrome stable (the exporters drive a system
  browser), installs the application, and writes a launcher wrapper supplying a
  session bus, an unlocked login keyring and the libsecret backend.
  Verified: `tests/verify-vm-design-e2e.sh` ("the step resolved a release
  asset", "the step reports success", "the step installed a package", "a browser
  the app will find is installed", "it is a real Chrome, not the chromium snap
  stub", "headless PDF export works with the app's arguments").
- `safeStorage` is available through the installed wrapper (measured with the
  application's own Electron build and `tests/fixtures/electron-safestorage-probe`).
  Verified: "safeStorage is available through the installed wrapper (probe:
  available=true)", "and the probe round-trips a secret", "with the libsecret
  backend".
- Persistence: after `--shutdown` and a resume the application is still
  installed, the graphical marker is intact, the attach forwards again and the
  window renders again — "the app is still installed after the restart", "the
  GUI marker survived the restart", "the attach says it is forwarding X11",
  "the app connects again after the restart".
