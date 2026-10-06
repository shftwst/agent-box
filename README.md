# agent-box

Run coding agents inside a Docker sandbox that feels like running them natively. The agent gets broad, permission-skipped authority over your project; the sandbox keeps that authority off the rest of your machine.

One shared isolation boundary, the cage, hosts four boxes: `claude-box` (Claude Code), `codex-box` (OpenAI Codex), `deepseek-box` (DeepSeek Harness), and `pi-box` (the Pi coding agent). Each box preserves exact project paths, git/SSH integration, and persistent per-harness state, with per-project overrides via `.env.<box>` files.

## Why

A coding agent earns its keep once you stop approving every action. Claude Code's `--dangerously-skip-permissions`, Codex's full-auto mode, and their equivalents let the agent read, write, and run commands without a prompt. Granted on the host, that is authority over the whole machine: every file your user account can touch, your shell, your saved credentials, your network.

The obvious fix, a plain container, takes the ergonomics with it. Inside a bare box the agent loses the `~/.claude` skills you rely on (including ones symlinked into other repos), MCP servers stop resolving, git identity and SSH signing break, host credentials are gone, and a session started in the container can't be resumed on the host.

agent-box gives you both. Each agent runs in its own box on a shared cage. The cage keeps the agent off the host; the box wires through exactly the parts that make the agent feel native: skills resolved (symlinks included), MCP servers reachable, `.gitconfig` and the SSH agent forwarded, macOS Keychain credentials still valid, sessions resumable across container and host. `.env.<box>` lets each project layer its own forwarded env vars and extra mounts on top, so there are no global config edits and no guessing which API key belongs to which workspace.

## The boxes

Four boxes share one cage. Each adds a single agent and its own persistent state; nothing agent-specific leaks into the cage.

| Box | Agent | State dir | Status |
| --- | --- | --- | --- |
| `claude-box` | Claude Code | `~/.claude-box/state/` | Proven |
| `codex-box` | OpenAI Codex CLI | `~/.codex-box/state/` | Proven |
| `deepseek-box` | DeepSeek Harness (`dsh`) | `~/.deepseek-box/state/` | Proven; upstream Harness is itself a developer preview |
| `pi-box` | Pi coding agent | `~/.pi-box/state/` | Unverified, not yet exercised in anger |

## What the cage isolates

The boundary is deliberately tight by default. The safety posture in one view:

| Concern | Default posture |
| --- | --- |
| Host filesystem | Only the project dir (at its exact host path) and any explicit extra mounts are visible. Nothing else. |
| Host docker socket | Never mounted. The box refuses to start if one is present, since a host socket is root-equivalent control of the host. |
| `~/.claude` skills, plugins, hooks, `.mcp.json` | Mounted read-only, so the container reflects your local setup but cannot alter it. |
| `~/.agents` | Mounted read-only in every box when it exists, with the folders its linked skills point to. `~/.agents/AGENTS.md` shows the global file merged with the project's `AGENTS.md` chain; the host file is never written. Workers see an empty `skills` folder. |
| `~/.ssh` | Mounted read-only; the SSH agent is forwarded. Drop both with `--no-ssh`. |
| Published services | Bind host loopback (`127.0.0.1`) only, never the LAN. |
| Nested containers | Run on an engine inside the box whose authority is bounded by the cage. No host root. |
| Persistent state | Each box keeps its own state dir; delete it to reset that box. |

The rest of this document explains how each of those is wired, and how to widen the boundary deliberately when a project needs it.

## How it works

- The project dir is bind-mounted at its exact host path, so skill symlinks resolve correctly.
- `~/.claude-box/state/` persists Claude Code state (settings, conversation history) across runs. Delete it to reset.
- `~/.claude` skills, plugins, hooks, and `.mcp.json` are bind-mounted read-only, so your local setup is always reflected.
- Symlinked skills that point outside `~/.claude/` have their parent dirs auto-mounted.
- Sessions for the current project are written back to `~/.claude/projects/<slug>/` on the host, so a conversation started in a box is resumable from host Claude, and the reverse. Session-keyed satellite state (todos, plan-mode drafts, file-edit history) is shared too.
- macOS Keychain credentials are extracted at launch and written to the state dir.
- `settings.json` is synced on first run (stripping sandbox/hooks, rewriting macOS-specific paths).
- A nested container engine runs inside the box (rootless dockerd by default), so `docker` and `docker compose` work in-session without ever exposing the host's docker socket.

## Architecture: the cage

agent-box is four payloads on a shared cage. The cage is the isolation boundary: it owns the outer container, its security posture, the bounded nested engine, uid mapping, the ssh/colima relays, the image build, the exit-status contract, and the `docker run` assembly. It knows nothing about which agent runs inside it. A payload owns one thing: which agent command runs, and which host state it syncs.

```
                 ┌────────────────────────────┐
                 │ cage                        │
                 │  libcage.sh                 │
                 │  Dockerfile.cage            │
                 │  entrypoint-cage.sh         │
                 │  isolation, nested engine,  │
                 │  relays, docker run         │
                 └─────────────┬──────────────┘
                               │ FROM cage-base
         ┌───────────┬─────────┴────────┬───────────┐
     claude-box   codex-box       deepseek-box     pi-box
     Claude Code  Codex CLI       DeepSeek dsh     Pi agent
      (proven)    (proven)        (proven)       (unverified)
```

- `libcage.sh` is the cage as a sourced shell library. The engine block, the userns probe ladder, env forwarding, and the `docker run` invocation live here exactly once.
- `Dockerfile.cage` builds `cage-base`: git, gh, the nested docker engine, and the generic dev tooling, with no agent baked in. `entrypoint-cage.sh` is its entrypoint (create the host user, start the engine, wire the relays, then exec whatever command the launcher hands it).
- A payload is a thin wrapper plus a Dockerfile `FROM cage-base`. `claude-box` and `Dockerfile.claude` add Claude Code; `codex-box` and `Dockerfile.codex` add the OpenAI Codex CLI; `deepseek-box` and `Dockerfile.deepseek` add the official DeepSeek Harness; `pi-box` and `Dockerfile.pi` add the Pi coding agent. Each wrapper sets a handful of `BOX_*` variables and may define payload hooks for its own arguments, state, or published ports, then calls `cage_run "$@"`.

The four payloads keep the boundary honest: anything agent-specific that leaked into the cage would break another payload. To verify the boundary and the nested engine, run [docs/cage-engine-acceptance.md](docs/cage-engine-acceptance.md).

## Requirements

- Docker Desktop, or Docker Engine on Linux
- Node.js (the settings sync script just needs `node` in PATH)
- macOS or Linux

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/shftwst/agent-box/main/install.sh | bash
```

The script clones agent-box to `~/.agent-box` and symlinks the four box wrappers onto PATH (`/usr/local/bin` if writable, otherwise `~/.local/bin`). Re-running it updates an existing checkout in place. Override the defaults with env vars: `AGENT_BOX_DIR` (install dir), `AGENT_BOX_BIN` (symlink target), `AGENT_BOX_REF` (branch or tag).

If you'd rather not pipe a script to your shell, do the same by hand:

```bash
git clone https://github.com/shftwst/agent-box ~/.agent-box
for box in claude-box codex-box deepseek-box pi-box; do
  ln -sf "$HOME/.agent-box/$box" "/usr/local/bin/$box"
done
chmod +x ~/.agent-box/{claude-box,codex-box,deepseek-box,pi-box}
```

The images build automatically on first run: a shared `cage-base` first, then the selected payload image on top of it. Each rebuilds when its own inputs change (see [Architecture](#architecture-the-cage)).

## Usage

Every box runs in the current directory (the project root), so `cd` into your project first.

### Claude Code

```bash
claude-box                  # interactive session
claude-box -c               # continue most recent session
claude-box --resume         # pick a session to resume (interactive picker)
claude-box -r <id>          # resume a specific session by ID
claude-box -p "..."         # non-interactive prompt (pipe-friendly)
```

Every argument is passed directly to `claude`. Use `--` to force everything after it to `claude`, so a `claude` flag that shares a name with a box flag can still be passed (e.g. `claude-box -- --engine foo`).

These box flags are consumed by the wrapper before `claude` sees them, and are position-free (they can appear anywhere on the command line):

- `--upgrade`: `git pull` the install dir and exit. See [Updating](#updating).
- `--no-ssh`: skip mounting `~/.ssh` and forwarding the SSH agent. Disables git-over-SSH and commit signing inside the container; useful for sessions that don't touch git remotes.
- `--ollama <model>`: point Claude Code at an Ollama server instead of the Anthropic API. See [Ollama](#ollama).
- `--engine <mode>`: nested container engine posture: `auto` (default), `sysbox`, `rootless`, `privileged-dind`, `none`. See [Nested container engine](#nested-container-engine).
- `--name <name>`: name the box's container (default `claude-box-<project>-<pid>`), so a caller can address it with `docker stop` / `docker exec`. Must match docker's charset `[a-zA-Z0-9][a-zA-Z0-9_.-]*`.
- `--name-file <path>`: write the resolved container name to `<path>` just before launch (removed on exit), so a headless supervisor can discover the box and stop it.
- `--sessions <n>`: on colima, copy only the `n` most-recent session transcripts of the current project into the box instead of its whole history. `0` copies none. See [Session history on colima](#session-history-on-colima).
- `--no-sync`: on colima, copy no session history into the box and none back to the host on exit. See [Session history on colima](#session-history-on-colima).
- `--image <tag>`: run a project-built image instead of the default box image, so a project can bake its own dependencies (a JDK, a toolchain) into a layer. Also settable as `CLAUDE_BOX_IMAGE` (typically in `.env.claude-box`). The image must be built `FROM claude-box` so the cage entrypoint and env contract still hold. See [Baking project dependencies](#baking-project-dependencies).

#### Baking project dependencies

The box image carries the agent and generic tooling, not per-project SDKs. If a project needs something baked in (a specific JDK, a language toolchain), the project builds its own image `FROM claude-box` and tells the box to run that image instead of the default. The box supplies the base image and runs whatever you point it at; building and rebuilding the project image is the project's job.

Three steps, run from the project's own directory:

**1. Add a Dockerfile to the project** (anywhere in the project; `.claude-box/Dockerfile` is a tidy spot). It must start `FROM claude-box` so it inherits the cage entrypoint, the nested engine, and the whole launch contract, then add whatever the project needs:

```dockerfile
# my-java-project/.claude-box/Dockerfile
FROM claude-box
RUN apt-get update && apt-get install -y --no-install-recommends openjdk-21-jdk \
    && rm -rf /var/lib/apt/lists/*
```

The base `claude-box` image has to exist first; it is built the first time you ever run `claude-box`. If you have never launched the box on this machine, run `claude-box` once (in any directory) before step 2.

**2. Build the project image**, giving it a tag of your choosing:

```bash
docker build -f .claude-box/Dockerfile -t claude-box-myproj .
```

**3. Launch the box on that image.** Either set it once for the project in `.env.claude-box` so you can then run `claude-box` normally:

```bash
# my-java-project/.env.claude-box
CLAUDE_BOX_IMAGE=claude-box-myproj
```

or pass it per-run:

```bash
claude-box --image claude-box-myproj
```

Inside the box the JDK is now on `PATH`, and everything else (mounts, auth, sessions) works exactly as usual.

If the tag doesn't exist, the box refuses to launch and tells you to build it first, rather than silently falling back to the default image.

**Rebuild after upgrades.** `claude-box --upgrade` rebuilds the base `claude-box` image, which leaves your project image built on top of the old base. Re-run step 2 after an upgrade to pick up the new base. The box can't do this for you, because it doesn't own the project's Dockerfile.

The same applies to `codex-box` and `pi-box`: build `FROM codex-box` / `FROM pi-box` and use `--image` or `CODEX_BOX_IMAGE` / `PI_BOX_IMAGE`.

### Codex

`codex-box` passes arguments directly to Codex and uses the same cage flags:

```bash
codex-box                         # interactive session
codex-box "fix the flaky test"    # start with a prompt
codex-box resume --last           # resume the latest session
```

Codex state persists in `~/.codex-box/state/`. A host `codex login` is seeded into the box, and refreshed account authentication is synced back on exit. Host sessions are seeded too; `--sessions` and `--no-sync` work as in `claude-box` (see [Session history on colima](#session-history-on-colima)).

### DeepSeek Harness

`deepseek-box` installs the official `@deepseek-ai/dsh` package. Because the Harness currently ships a browser UI rather than a terminal UI, a bare launch starts `dsh web` and publishes it on host loopback only:

```bash
deepseek-box                                      # http://127.0.0.1:3080
deepseek-box --port 3081                          # choose another local port
deepseek-box --profile headless "fix the tests"   # one headless task
deepseek-box --version                            # any explicit dsh mode passes through
```

The Harness stays bound to container loopback, as its safety policy requires. A cage-local bridge makes it reachable through Docker, which publishes only `127.0.0.1:<port>` on the host; it is not exposed on your LAN. Set `DEEPSEEK_BOX_PORT` (also supported in `.env.deepseek-box`) to change the default. Open the tokenized loopback URL that `dsh` prints at startup; the token establishes the browser session before the Harness serves the UI.

`DEEPSEEK_API_KEY`, `DEEPSEEK_BASE_URL`, and `DEEPSEEK_SEARCH_BASE_URL` are forwarded when set. You can instead save the API key in the web UI; the Harness stores it under `$DSH_HOME`, which persists at `~/.deepseek-box/state/` on the host.

DeepSeek Harness is itself a developer preview upstream and may make breaking changes.

### Pi

`pi-box` installs the official [Pi coding agent](https://pi.dev/) (`@earendil-works/pi-coding-agent`) and passes arguments directly to its terminal UI or non-interactive modes:

```bash
pi-box                             # interactive TUI
pi-box -c                          # continue the latest session
pi-box -r                          # browse previous sessions
pi-box -p "review this repository" # one-shot print mode
```

Pi deliberately relies on its runtime environment for isolation, so the shared cage supplies the filesystem and nested-engine boundary. Pi state persists in `~/.pi-box/state/`, mounted as `~/.pi/agent`; `/login`, settings, extensions, skills, packages, and sessions therefore survive container replacement.

The documented provider API keys and cloud-provider variables are forwarded when set, including `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `DEEPSEEK_API_KEY`, and `GEMINI_API_KEY`. Use `PI_BOX_EXTRA_VARS` for a custom provider variable, or put project-specific values in `.env.pi-box`.

Note: `pi-box` is not yet verified to the standard of the other three. Treat it as experimental and check its behaviour before relying on it.

## Ollama

Run Claude Code against a local (or remote) Ollama server that exposes the Anthropic-compatible API, mirroring `ollama launch claude --model <model>`:

```bash
claude-box --ollama qwen3-coder:30b-a3b-q4_K_M
claude-box --ollama qwen3-coder:30b-a3b-q4_K_M -c   # combine with other flags
```

The flag is a command-line override (nothing is baked into `.env.claude-box`) and wires up, inside the container:

- `ANTHROPIC_BASE_URL` from `OLLAMA_HOST` (adding `http://` if the scheme is missing), falling back to `http://localhost:11434`
- `ANTHROPIC_AUTH_TOKEN=ollama` (a dummy token Ollama ignores but Claude Code requires)
- `ANTHROPIC_MODEL` and `ANTHROPIC_SMALL_FAST_MODEL`, both set to the model you pass

Because the base URL follows `OLLAMA_HOST`, pointing it at a Tailscale peer just works: set `OLLAMA_HOST=100.x.y.z:11434` (as your `ollama` CLI already does) and the container reaches it over the normal bridge network. No `--network host` is needed, since a container can already route to any address the host can reach, including the tailnet.

## Nested container engine

The box ships its own container engine inside the cage: `docker` and `docker compose` work in-session, but their authority is bounded by the cage. The host's docker socket is never mounted; the entrypoint refuses to start if one is present, because a host socket is root-equivalent control of the host and would void the sandbox entirely.

Engine postures, selected with `--engine` (or `CLAUDE_BOX_ENGINE_MODE` in `.env.claude-box`):

- `auto` (default): `sysbox` if the host docker has the sysbox-runc runtime, else `rootless`.
- `sysbox`: rootful dockerd inside a [sysbox](https://github.com/nestybox/sysbox) container. Strongest posture; requires sysbox installed on the host/VM.
- `rootless`: rootless dockerd (rootlesskit) running as the unprivileged in-box user. The cage stays non-privileged; the relaxations it needs are `seccomp=unconfined` plus `systempaths=unconfined` (rootlesskit must create user namespaces and write `net.ipv4.ip_forward` in its own detached netns), the `/dev/net/tun` and `/dev/fuse` devices, and on apparmor hosts either `apparmor=unconfined` or a tiny `claude-box-engine` profile granting the `userns` permission.
- `privileged-dind`: rootful dockerd in a `--privileged` cage. This is the weakest option, so it is explicit opt-in only, the launcher warns, and it should be a last resort.
- `none`: no engine.

On first launch (per docker host) the `rootless` posture probes for the weakest working relaxation set and caches it in `~/.claude-box/.userns-strategy-*`:

- `plain`: the relaxations above suffice (typical for Docker Desktop / OrbStack).
- `profile` / `profile-cap`: Ubuntu-lineage kernels (Colima VMs, Ubuntu 23.10+) restrict unprivileged user namespaces via apparmor. The launcher loads the `claude-box-engine` apparmor profile into the VM kernel through a privileged one-shot helper (host-altitude setup by the human-run wrapper; the cage itself never gets that authority), and `profile-cap` additionally adds `CAP_SYS_ADMIN` to the cage's bounding set, which the kernel demands for the setuid `newuidmap` helpers there. The cap is latent: unprivileged in-box processes only reach it through those helpers.
- `cap`: `CAP_SYS_ADMIN` alone (restricted kernel without apparmor mediation).

Delete `~/.claude-box/.userns-strategy-*` to force a re-probe (e.g. after changing docker runtimes).

Engine storage is an anonymous volume, removed when the session ends, so nested images don't persist across sessions. To keep a warm image cache, mount a named volume at the engine's data root (one box at a time, since concurrent daemons on one data root won't start):

```bash
CLAUDE_BOX_EXTRA_MOUNTS=("claude-box-engine-cache:/var/lib/claude-box-engine") claude-box
```

Verification: run the four checks in [docs/cage-engine-acceptance.md](docs/cage-engine-acceptance.md) inside the box. Expect `docker info --format '{{.SecurityOptions}}'` to contain `name=rootless` under the default posture, and `/var/run/docker.sock` to be absent (rootless) or owned by the nested daemon (rootful).

## Extra env vars

The default forwarded vars are `ANTHROPIC_API_KEY`, `GITHUB_TOKEN`, `GITHUB_PERSONAL_ACCESS_TOKEN`, and `LINEAR_API_KEY`.

To forward additional vars without modifying the script:

```bash
CLAUDE_BOX_EXTRA_VARS=(TURSO_AUTH_TOKEN MY_API_KEY) claude-box
```

Or set it in your shell profile:

```bash
export CLAUDE_BOX_EXTRA_VARS=(TURSO_AUTH_TOKEN NETLIFY_AUTH_TOKEN)
```

### Per-project values via `.env.claude-box`

Drop a `.env.claude-box` file in a project root to supply project-specific values for any of the forwarded vars. It's sourced just before the env lookup, so values here override whatever's in your shell, which is useful when each project is backed by a different API key (e.g. a different `LINEAR_API_KEY` per workspace).

```bash
# .env.claude-box (in your project root, gitignored)
LINEAR_API_KEY=lin_proj_specific_xxx
TURSO_AUTH_TOKEN=ey...
```

Plain `KEY=value` lines work, with no `export` needed. These files hold secrets, so keep them out of git: a single `.env.*-box` line in `.gitignore` (or your global `.env.*` ignore) covers every box file. Each box reads its own `.env.<box>` the same way (`.env.codex-box`, `.env.deepseek-box`, `.env.pi-box`), plus the shared `.env.agent-box` described below.

#### Shared values across boxes via `.env.agent-box`

Each box reads only its own `.env.<box>` file, so a key in `.env.claude-box` is invisible to codex-box. To share one set of values across every box in a project, put them in `.env.agent-box`. Every box sources it, then sources its own `.env.<box>` on top, so a box-specific value overrides the shared one:

```bash
# .env.agent-box (shared by all boxes in this project, gitignored)
OPENROUTER_API_KEY=sk-or-...
GEMINI_API_KEY=...
AGENT_BOX_EXTRA_VARS=(OPENROUTER_API_KEY GEMINI_API_KEY)   # forwarded by every box

# .env.codex-box (codex only; wins on conflict)
OPENROUTER_API_KEY=sk-or-codex-specific-...
```

`AGENT_BOX_EXTRA_VARS` (and `AGENT_BOX_EXTRA_MOUNTS`) work like the per-box `*_EXTRA_VARS` / `*_EXTRA_MOUNTS`, but apply to all boxes. They're additive with the per-box arrays, so a box gets both. In a per-box file, use that box's prefixed array name (`CODEX_BOX_EXTRA_VARS`), not `AGENT_BOX_EXTRA_VARS` again, or you'll replace the shared list instead of extending it.

`AGENT_BOX_EXTRA_RUN_ARGS` passes extra arguments straight to `docker run` for every box, for one-off settings specific to your machine or network. For example, to resolve a Tailscale MagicDNS name that the container's DNS doesn't know:

```bash
# .env.agent-box
AGENT_BOX_EXTRA_RUN_ARGS=(--add-host agentgateway.example.internal:100.80.160.4)
```

These arguments can widen the cage (for example `--privileged` or `--network host`), so use them only for settings you'd accept on any box in that project.

### Running multiple boxes at once (Claude auth)

By default the box authenticates from your macOS Keychain subscription login, whose OAuth refresh token is single-use and rotating. That's fine for one box, but two concurrent boxes each refresh it independently: the auth server sees the same token spent twice, treats it as a leak, and revokes the whole lineage, silently logging every box (and often host Claude) out. Re-running `/login` in any one box heals them all, because the credential file is a shared mount, but the logout keeps recurring.

To run boxes concurrently, mint a long-lived OAuth token once and let every box share it. Claude Code uses this token as-is and never refreshes it, so there's nothing to race on:

```bash
# 1. Generate a long-lived token (opens the same browser flow as /login; ~1yr).
claude setup-token

# 2. Store it in the Keychain under this exact service name (one time).
security add-generic-password -U -s "Claude Code-oauth-token" -a "$USER" -w "<token-from-step-1>"
```

From then on the launcher picks it up automatically and injects it as `CLAUDE_CODE_OAUTH_TOKEN` (you'll see `using static OAuth token` in the launch log). An already-exported `CLAUDE_CODE_OAUTH_TOKEN` takes priority over the Keychain item. If neither is present, the box falls back to the rotating subscription credential, so single-box use needs no setup and is unchanged. The shared credential mount stays in place either way, so `/login` still propagates across boxes. Re-mint and re-store when the token eventually expires.

### Cloud CLI auth

The image bundles several deploy/cloud CLIs (`aws`, `flyctl`, `netlify`, `wrangler`, `gh`). Each authenticates non-interactively from a precise env var name, so forward the ones you need via `CLAUDE_BOX_EXTRA_VARS` (or set them per-project in `.env.claude-box`). Each CLI reads its own exact name, and the launcher forwards them verbatim, so don't rename them.

| CLI | Env var(s) | Notes |
| --- | --- | --- |
| `aws` (AWS CLI v2) | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` | Session token only for temporary creds. `AWS_DEFAULT_REGION` (or `AWS_REGION`) sets the region; `AWS_PROFILE` selects a named profile. |
| `flyctl` (Fly.io) | `FLY_API_TOKEN` | From `flyctl auth token`. `FLY_ACCESS_TOKEN` is also honoured. |
| `netlify` | `NETLIFY_AUTH_TOKEN` | Personal access token. `NETLIFY_SITE_ID` targets a site without a linked repo. |
| `wrangler` (Cloudflare) | `CLOUDFLARE_API_TOKEN` | Add `CLOUDFLARE_ACCOUNT_ID` when the token spans multiple accounts. Legacy `CLOUDFLARE_API_KEY` plus `CLOUDFLARE_EMAIL` global-key auth also works, but prefer a scoped token. |
| `gh` (GitHub) | `GH_TOKEN` or `GITHUB_TOKEN` | `GITHUB_TOKEN` / `GITHUB_PERSONAL_ACCESS_TOKEN` are already in the default forwarded set. |

Example, forwarding AWS and Cloudflare creds for a project:

```bash
# .env.claude-box
CLAUDE_BOX_EXTRA_VARS=(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID)
```

Note: `flyctl` and `wrangler` also fall back to on-disk config (`~/.fly/`, `~/.wrangler/` or `~/.config/.wrangler/`) when the env var is absent. Those paths aren't in the default mount set, so nothing leaks in unless you mount them explicitly. Prefer forwarding a scoped token over mounting host credential dirs.

## Extra mounts

By default the container sees the project dir, `~/.ssh` (read-only), and `~/.claude` skills/plugins/hooks/`.mcp.json` (read-only), and never the host docker socket (a mount at `/var/run/docker.sock` makes the box refuse to start). To expose additional host paths inside the container, set `CLAUDE_BOX_EXTRA_MOUNTS` to an array of `host:container[:opts]` specs:

```bash
CLAUDE_BOX_EXTRA_MOUNTS=("$HOME/.aws:$HOME/.aws:ro" "/data:/data") claude-box
```

Or per-project in `.env.claude-box`:

```bash
# .env.claude-box
CLAUDE_BOX_EXTRA_MOUNTS=("$HOME/.config/gcloud:$HOME/.config/gcloud:ro")
```

Each entry is passed straight to `docker run -v`, so the standard `:ro` / `:rw` / propagation suffixes all work. Use this when a project needs cloud credentials, a shared dataset, or any other host directory that isn't part of the default mount set.

## State

Each payload owns a separate persistent state directory:

- Claude Code: `~/.claude-box/state/` mounts at `~/.claude`.
- Codex: `~/.codex-box/state/` mounts at `~/.codex`.
- DeepSeek Harness: `~/.deepseek-box/state/` mounts at `~/.dsh`.
- Pi: `~/.pi-box/state/` mounts at `~/.pi/agent`.

Conversation history, project memories, settings, and harness-managed credentials survive container replacement. To reset one payload completely, remove its state directory. For example:

```bash
rm -rf ~/.claude-box/state/
```

### Session history on colima

On colima, each launch copies host files into the box's state directory and flushes them into the VM, and exit copies new sessions back. Only files that changed since the last launch go in, and only files written during the run come back. When the VM shares the state directory with the host (colima's default home mount), exit skips the copy because the files are already there.

Every box takes the same controls:

| Control | Effect |
|---|---|
| `--sessions <n>` or `<PREFIX>_MAX_SESSIONS=<n>` | Copy in only the `n` newest sessions of the current project. `0` copies none. Older sessions already in the box stay resumable. |
| `--no-sync` or `<PREFIX>_NO_SYNC=1` | Copy no session history in and none back. The session stays in the box (`claude-box -c` resumes it). |
| Neither | Copy in all history. |

`<PREFIX>` is the box's env prefix (`CLAUDE_BOX`, `CODEX_BOX`, `PI_BOX`, `DEEPSEEK_BOX`), and the variables also work in `.env.agent-box` and `.env.<box>`. A flag wins over a variable, and `--no-sync` wins over `--sessions`. Workers started by the broker default to `--sessions 0` but still copy their own sessions back.

What counts as history differs by box:

- `claude-box`: this project's transcripts in `~/.claude/projects/`, plus the file history, tasks and session env keyed to them. They are copied back to the host on exit.
- `codex-box`: rollouts in `~/.codex/sessions/`. All history copies every host rollout, because Codex stores them by date rather than by project; `--sessions <n>` picks the newest `n` whose recorded working directory is the current project. Sessions written in the box stay in the box.
- `pi-box` and `deepseek-box`: their history lives only in the box's state directory, so nothing is copied and the controls have no effect.

## Updating

```bash
claude-box --upgrade       # or codex-box / deepseek-box / pi-box
```

This runs `git pull --ff-only` on the install dir and exits. The images rebuild automatically on the next regular run: `cage-base` when its inputs changed, and each payload image when its Dockerfile, payload inputs, or `cage-base` changed.

On startup, a box does a backgrounded `git fetch` against the install dir at most once every 24 hours. When the check finds you're behind upstream, the next launch prints a single hint line:

```
[claude-box] update available — run 'claude-box --upgrade' to pull latest
```

The check runs detached and adds no perceptible latency to launch; the hint disappears the next time `--upgrade` succeeds.

## Licence

MIT. See [LICENSE](LICENSE).
