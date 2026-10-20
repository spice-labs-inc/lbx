# What the image installs

The box image (`Dockerfile`, one image per runtime through the
`RUNTIME_TYPE` build argument) is an Ubuntu 24.04 development environment
with several coding agents preinstalled. This page lists what is there and
how to authenticate each agent inside a box. The in-box user is `agent`
(uid 1000), remapped to your host user at start.

## Toolchains and tools

| Category | Contents |
|---|---|
| Languages | Rust (stable plus `wasm32-unknown-unknown`), Python 3, OpenJDK 21, Node.js 24 |
| Build tools | Cargo, Maven, Gradle, SBT, npm, cmake, pkg-config, protoc |
| Rust extras | wasm-pack, cargo-watch, cargo-edit, cargo-expand, cargo-audit, cargo-outdated, cargo-deny, sccache, rustfmt, clippy, rust-analyzer |
| Infrastructure | Ansible, Docker CE with Compose and Buildx (the inner docker of an interactive session) |
| Command line | ripgrep, fd, bat, tree, htop, jq, yq, tmux, git, curl, wget, gh, vim, emacs |

If `GH_TOKEN` is set on the host, interactive sessions forward it, so `gh`
works without further setup.

## Agents

Agent versions are deliberately unpinned: an image build installs the
latest release of each, so rebuilding the image picks up fixes. The few
pins (Bun, Gradle, the sysbox image's docker-ce and containerd) are
explained in the Dockerfile.

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
to Node.js (the build fails if `omp --version` does not run). Authenticate
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
