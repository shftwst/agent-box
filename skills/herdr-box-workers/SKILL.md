---
name: herdr-box-workers
description: "Open and drive caged agent-box worker boxes (claude-box, codex-box, pi-box) in Herdr panes. Use when the user asks to spawn, delegate to, or run workers, worker boxes or caged sub-agents in Herdr, or to point a worker at a particular model, endpoint, profile or effort. Never start these workers with `herdr agent start`, which runs the uncaged host harness."
---

# Herdr box workers

A worker is a full agent running in its own agent-box cage, in a Herdr pane beside yours. A host-side broker opens each worker pane, runs the box wrapper for the requested kind, and relays your prompts. You talk to it with the `box-worker` verbs.

Never use `herdr agent start --kind claude|codex|pi` or `herdr pane run <pane> claude` for these workers. Herdr resolves a kind to the host harness, so the worker would run uncaged.

## Pick your entry point

| Where you are | Check | Command |
|---|---|---|
| Inside a box launched with `--workers` | `CAGE_WORKER_SOCKET` is set | `box-worker <verb> ...` (already on PATH) |
| On the host, in a Herdr pane | `HERDR_ENV=1` and `CAGE_WORKER_SOCKET` unset | `scripts/host-workers <verb> ...` from this skill |
| Anywhere else | | Workers are unavailable. Say so and stop. |

Inside a box without `CAGE_WORKER_SOCKET`, the box was launched without `--workers`. Tell the user to relaunch it with `claude-box --workers` (or `--workers=claude,codex,pi` for more kinds) from a Herdr pane.

On the host, start a broker for your pane once, and stop it when you are done:

```bash
scripts/host-workers start                 # kinds claude,codex,pi; the first is the default
scripts/host-workers start claude,codex    # or choose the kinds
scripts/host-workers stop                  # closes every worker pane it opened
```

`host-workers` takes the same verbs as `box-worker`. Resolve `scripts/` relative to this skill's directory. The broker needs local socket access; if a verb reports "connection refused" while the broker is running, your own sandbox is blocking unix sockets.

## Verbs

```bash
box-worker spawn <name> [--kind K] [--model M] [--small-fast-model M] [--base-url URL]
                        [--auth-token T] [--effort L] [--profile P]
box-worker ask   <name> "<text>" [--timeout MS]   # blocks until the worker goes idle
box-worker read  <name> [--lines N]               # the worker's screen
box-worker poll  <name>                           # status only
box-worker close <name>
box-worker list
```

Names match `[a-z][a-z0-9_-]{0,31}` and refer only to workers this broker opened. Every reply is JSON with `"ok": true` or an `"error"`.

## Choose the model and provider

| Kind | How to choose the model | Example |
|---|---|---|
| `claude` (default) | `--model`, `--base-url`, `--auth-token` set `ANTHROPIC_MODEL`, `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`. Omit them for the user's normal Claude account. `--effort low\|medium\|high\|xhigh\|max` sets Claude's effort. | `spawn qa --model <model-id> --base-url https://<host>/<path> --auth-token local` |
| `codex` | `--profile <name>` selects `~/.codex/<name>.config.toml` on the host, which fixes model, provider and effort. Without it, Codex uses its default config. | `spawn rev --kind codex --profile <name>` |
| `pi` | No per-spawn option. Pi uses the providers in `~/.pi-box/state/models.json`. | `spawn scout --kind pi` |

Rules for the `claude` kind:

- `--base-url` is the API root without `/v1`; Claude Code appends `/v1/messages`. The endpoint must speak the Anthropic Messages API.
- With `--model` set, the small background model defaults to the same model. Set `--small-fast-model` to change it.
- For a model whose name contains `qwen`, the broker caps effort at `medium` (and pins it when you pass none), because that gateway rejects higher levels.

If `~/.config/agent-box/worker-models.md` exists, it lists the user's local endpoints and ready-made spawn commands. Read it before choosing a model. An endpoint may be down; check `<base-url>/v1/models` before relying on it.

## Work with workers

1. Spawn once and reuse. A cold spawn can take minutes; later asks to the same worker are fast.
2. Give each `ask` a self-contained task. The worker starts with no session history and none of the user's skills, so include the context it needs.
3. Ask for results in a file in the project directory (for example `docs/worker-<name>.md`), then read the file. Workers share the project folder with you, and a file is more complete than a scraped screen.
4. `ask` returns when the worker goes idle. The status JSON does not contain the answer; read the file you asked for, or use `read` for a short reply.
5. Use `--timeout` on long tasks (milliseconds, capped at 30 minutes). A timeout does not cancel the work; check with `poll` and `read` before asking again.
6. Close workers you no longer need. On the host, `host-workers stop` closes them all.

## What a worker gets

- The same project directory, at the same path, as its working directory.
- `BOX_WORKER=1`, which gives it no seeded session history and an empty skills folder. A Claude worker also skips the global `AGENTS.md` startup hook.
- Its own cage: it cannot reach Herdr, your pane, or other workers except through files in the project.

## Limits

- The broker caps workers (4 by default), prompt size (8 KB) and `ask` time (30 minutes), and refuses past a cap.
- One broker per orchestrator pane. A second `host-workers start` in the same pane reuses the running one.
- Herdr cannot see a caged worker's state directly, so `poll` can report `idle` while the worker is busy. Trust `ask`'s return, files and `read` over a single `poll`.
