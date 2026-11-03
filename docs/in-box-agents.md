# What the image installs

The box image (`Dockerfile`, one image per runtime through the
`RUNTIME_TYPE` build argument) is an Ubuntu 24.04 development environment
with several coding agents preinstalled. This page lists what is there and
how to authenticate each agent inside a box. The in-box user is `agent`
(uid 1000), remapped to your host user at start.

There are **two modes** of the same image, and this page describes both:

The checklist needs a terminal `dialog` can use. If the terminal's terminfo is
missing (`TERM=xterm-kitty` and friends) or `TERM` is unset, `dialog` cannot
initialise and `lbx-setup` falls back to a plain numbered menu — the same
selection, no curses — rather than reporting a cancel. `export
TERM=xterm-256color` restores the TUI.

| Mode | Image | What it means |
|---|---|---|
| `full` | `llm-in-a-box:<runtime>` | every toolchain and agent installed at build time (this is what shipped before the split, and the default) |
| `slim` | `llm-in-a-box:<runtime>-slim` | OS, box identity, docker, node, gh and CLI tools only; the same provisioning steps install the rest on demand with `lbx-setup` |

Optional tiers, on top of the provisioning set:

| Tier | Directory | Shipped in | `--all` | Example |
|---|---|---|---|---|
| optional | `docker/optional.d/` | every slim image | no | `pnpm` |
| optional-vm | `docker/optional-vm.d/` | the vm slim image only | no | `design` (Open CoDesign, needs X11 forwarding) |

Neither tier is ever run by the full image, and the full image does not carry
them at all.

`docker/provision.d/` is the single definition of "installed": the `full`
image runs those steps at build time, a `slim` box runs them when you ask.
Nothing about an installed tool differs between the modes — only when it
arrived.

## Toolchains and tools

| Category | Contents | Mode |
|---|---|---|
| Base | Ubuntu 24.04, git/curl/wget, ripgrep, fd, bat, tree, htop, jq, tmux, vim, build-essential, pkg-config, libssl-dev, python3, dialog | both |
| Infrastructure | Docker CE with Compose and Buildx (the inner docker of an interactive session), gh, yq | both |
| Languages | Rust (stable, `wasm32`, rustfmt/clippy/rust-analyzer), OpenJDK 21 + Maven + Gradle + sbt, Node.js 24, Python 3 (pip/venv/full), Ansible | `full`, or `lbx-setup rust,jvm,python` |
| Rust add-ons | wasm-pack, cargo-watch, cargo-edit, cargo-expand, cargo-audit, cargo-outdated, cargo-deny, sccache — compiled from source, ~10 min, not needed day to day | `full`, or `lbx-setup rust-extras` (opt-in step of its own) |
| Extras | Emacs | `full`, or `lbx-setup editors` |
| Agents | Claude Code, Pi (with its plugins), OpenCode, OMP (with Bun) — one provisioning step each | `full`, or `lbx-setup claude pi opencode omp` (+ `bun` for OMP) |

If `GH_TOKEN` is set on the host, interactive sessions forward it, so `gh`
works without further setup.

## Agents

Agent versions are deliberately unpinned: an image build installs the
latest release of each, so rebuilding the image picks up fixes. The few
pins (Bun, Gradle, the sysbox image's docker-ce and containerd) are
explained in the Dockerfile. In `slim` mode the same is true of
`lbx-setup claude` / `pi` / `opencode` / `omp`: they install the current
release, which is also what `pi update` and `pi update --extensions` do
inside a running box. Pi's extensions belong to Pi's step, installed with
`pi install`, so the two paths cannot disagree.

### The first entry into a slim box

A slim box has nothing installed, so the first attach says so — once:

```
  This box has nothing installed yet (slim image).
    lbx-setup            tick what to install (checklist)
    lbx-setup --list     what is available, what is installed
```

A hint rather than a prompt: attach is scriptable (`lbx s && claude -p …`), and
a blocking TUI there would break that. The condition is the provisioning log
the steps write, so a configured box is never nagged again, and a full image
(which has the log from build time) never sees it.

### Optional steps that need a display (vm only)

`lbx-setup design` installs Open CoDesign: it resolves the latest GitHub
release for the box's architecture (`LBX_DESIGN_VERSION` pins one), downloads
the `.deb`, verifies the archive magic, installs the Electron libraries and the
package, and writes `~/.lbx/gui` (`transport=x11`). Then it tells you to exit
and re-run `lbx <name>`: the display transport is chosen per attach, so the
session you install in cannot have one. After the re-attach the launcher prints
`==> GUI app in this box: forwarding x11`, and the marker survives a
`--shutdown`/resume.

### Model credentials from the host

`lbx` forwards the host variables named in `env.forward` (default `GH_TOKEN`)
into an interactive box, and `--env NAME` adds or replaces one for a session.
Only the names are printed, never the values. The values are passed at
**attach** time — `docker exec` on containers, `~/.lbx/env` over ssh on the vm
— so `docker inspect` never contains a token and a rotated key takes effect on
the next `lbx`.

The agents read those variables from the environment, so no in-box
configuration file is generated: Claude Code takes `ANTHROPIC_API_KEY`, Pi and
OMP take `ANTHROPIC_API_KEY` / `UMANS_API_KEY` / `ZAI_API_KEY`, OpenCode reads
its provider environment, and `gh` uses `GH_TOKEN`. A variable that is unset on
the host is skipped, so a box that logs in with OAuth inside is unaffected.
The one exception is OMP's Umans provider, which needs a `models.yml` block;
that is written by `docker/provision.d/60-bun-agents.sh`, not by the launcher.

| Agent | Command | Package |
|---|---|---|
| Claude Code | `claude` | `@anthropic-ai/claude-code` |
| Pi | `pi` | `@earendil-works/pi-coding-agent` |
| OpenCode | `opencode` | `opencode-ai` |
| OMP (Oh My Pi) | `omp` | `@oh-my-pi/pi-coding-agent` |

### Claude Code

Claude Code authenticates with OAuth against a Claude.ai subscription or
with `ANTHROPIC_API_KEY`. The box ships `~/.claude/settings.json` (from
`claude-settings.json` in this repository) with deny rules for the git
commands that mutate a repository (commit, push, merge, rebase, reset, tag,
stash, cherry-pick, revert, am, apply, branch delete or rename, new
branches). Run `update-claude-code` inside the box to update Claude Code
in place (`sudo npm install -g @anthropic-ai/claude-code@latest`).

```bash
claude                                      # interactive
claude --dangerously-skip-permissions       # no permission prompts
claude --dangerously-skip-permissions -p "explain this codebase"
```

### Pi

Pi is a multi-provider terminal coding agent. Three plugins are installed
with `pi install npm:<package>` (they live under
`~/.pi/agent/npm/node_modules`, not in the npm global tree):

| Plugin | What it does |
|---|---|
| `pi-provider-umans` | the `umans` provider (Anthropic Messages API against `https://api.code.umans.ai`) with live model discovery |
| `@cortexkit/aft-pi` | AFT: tree-sitter and LSP backed replacements for `read`, `write`, `edit` and `grep`, plus the `aft_*` tools; the `aft` binary is on `PATH` |
| `pi-web-access` | web search, URL fetching, repository cloning, PDF and video extraction |

The image ships no Pi credential file: `~/.pi/agent/auth.json` is purged
at build time, and the build fails if one survives. Authenticate inside the
box:

```bash
pi
/login            # Claude Pro or Max (OAuth), stored in ~/.pi/agent/auth.json
/login umans      # paste a Umans API key
```

or export `ANTHROPIC_API_KEY`, `UMANS_API_KEY` or `ZAI_API_KEY` before
starting `pi`, then pick a model with `/model`. `pi update` refreshes Pi
and its plugins inside a box. A default Magic Context configuration is
copied to `~/.config/cortexkit/magic-context.jsonc` (from
`docker/magic-context.jsonc`); the Magic Context plugin itself is not
installed, so the file only matters if you install it.

### OpenCode and OMP

Both run from their built-in provider lists; the image ships no provider
configuration for them. OMP is a Bun-only build, so Bun is installed next
to Node.js (the build fails if `omp --version` does not run). The Bun pin
(`ARG BUN_VERSION`) must stay at or above the `engines.bun` floor that the
installed `@oh-my-pi/pi-coding-agent` declares — the agents are installed
unpinned, so upstream can raise that floor and break the image build until the
pin is bumped (`npm view @oh-my-pi/pi-coding-agent engines.bun`; 2026-10-25:
floor 1.4.4, pin raised from 1.4.0). Authenticate
with `ANTHROPIC_API_KEY` or `/login` inside the agent; OMP also takes
`ZAI_API_KEY` and `/login kimi-code`. For Umans models in OMP, write your
own `~/.omp/agent/models.yml` with a provider block pointing at
`https://api.code.umans.ai/v1` (API `openai-completions`).

### The Umans CLI

`umans` (installed from `https://api.code.umans.ai/cli/install.sh`)
authenticates on first run and provides a managed model endpoint for the
agents above.

## Further reading

- Claude Code: https://docs.anthropic.com/en/docs/claude-code/overview
- Pi: https://pi.dev/docs
- OpenCode: https://opencode.ai
- OMP: https://github.com/can1357/oh-my-pi
- AFT: https://github.com/cortexkit/aft
- Umans: https://umans.ai
