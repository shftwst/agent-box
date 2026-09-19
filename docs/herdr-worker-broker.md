a host-side broker lets a caged agent open and drive Herdr workers without holding the Herdr socket

Type: design / spec, cage-side (shftwst/agent-box) work. Written 2026-09-16 from the
codex-box orchestration conversation. Supersedes the `--herdr` socket bridge on
`feat/herdr-control-bridge`, which is left unmerged as the rejected alternative.

## Why

An agent inside a box cannot drive Herdr. The Herdr socket is local to the host, and
virtiofs carries files, not sockets, so a colima box cannot reach it at all.

The obvious fix is to relay the socket in. That works, and it is built and tested on
`feat/herdr-control-bridge`, but it hands the box the whole Herdr CLI, and two of those
commands together are arbitrary host execution: `herdr pane split` opens a pane running
a shell, and `herdr pane send-text <pane> "<anything>"` types into it. `pane split --env`
and `agent start -- <args>` are further routes to the same place. A box that can run
host commands is not a cage. It is the same access ADR-0041 decision 3 refuses for the
docker socket, and `entrypoint-cage.sh` still treats a mounted docker socket as fatal.
Shipping the bridge as the answer would mean the cage refuses one root-equivalent hole
at startup while offering an equivalent one behind a flag.

With the bridge there is nothing between the agent and the server:

```
   THE BOX                                        |   THE HOST
  +----------------------+                        |  +------------------+
  | orchestrator agent   |   full Herdr CLI       |  |   Herdr server   |
  | permissions off      |------------------------|->|                  |
  | + herdr binary       |   pane split, then     |  |  opens a shell,  |
  | + HERDR_* variables  |   pane send-text       |  |  types into it   |
  +----------------------+                        |  +------------------+
```

The delegation surface Herdr actually needs is much smaller than the socket:

```
herdr agent prompt <target> <text> [--wait] [--until STATUS] [--timeout MS]
herdr agent read   <target> [--source visible|recent|detection] [--lines N]
herdr agent wait   <target> [--until STATUS] [--timeout MS]
herdr agent get    <target>
```

None of those is command execution. `prompt` puts text into an agent, the rest read
state. Only spawning needs a command, and the command it needs is always the same one.
That asymmetry is what makes a narrow broker possible: the box never needs to say what
to execute, only which worker to talk to.

## What it is

A small program on the host that holds the Herdr socket and exposes a fixed set of
verbs to the box. The box gets a client on its PATH and never sees Herdr.

```
   THE BOX  (caged, Linux container in the colima VM)  |  THE HOST  (your Mac)
  -----------------------------------------------------|------------------------------
                                                       |
   +----------------------+                            |  +-----------------------+
   | orchestrator agent   |                            |  |        BROKER         |
   | permissions off      |     (2) JSON lines         |  | holds the socket      |
   |                      |----------------------------|->| owns the pane registry|
   |  +----------------+  |                            |  | composes every command|
   |  | cbw client     |  |<---- responses only -------|--|                       |
   |  +----------------+  |                            |  +-----------+-----------+
   +----------------------+                            |              | (1) unix socket
                                                       |              v
    x no herdr binary in the image                     |  +-----------------------+
    x no HERDR_* variables forwarded                   |  |     Herdr server      |
    x no Herdr socket reachable                        |  |     TUI + panes       |
                                                       |  +-----------+-----------+
                                                       |              | (3) starts
   +----------------------+                            |              v
   |  worker box (caged)  |<---------------------------|--- new pane runs codex-box
   +----------+-----------+                            |
              +--------- (4) project dir, virtiofs, shared both ways --------------
```

The broker sits on the Mac, between the box and Herdr. It is an ordinary host program,
not a container and not part of Herdr, and it is the only thing here that talks to Herdr.

| Hop | Transport | Who dials | What crosses |
|---|---|---|---|
| (1) broker to Herdr | unix socket, macOS-local (`~/.config/herdr/herdr.sock`) | broker | the full Herdr CLI, composed by the broker alone |
| (2) box to broker | unix socket on the host, relayed onto loopback TCP, socat back to a unix socket in the box | the box | one JSON object per line, each way |
| (3) Herdr to worker | Herdr starts the pane itself | Herdr | the box wrapper, never a raw harness |
| (4) box to worker | virtiofs project mount, already present | either side | files |

Hop (2) is a chain because a container cannot reach a macOS unix socket: virtiofs carries
files, not sockets. `cage_relay_unix_socket` already does exactly this for the ssh agent.

The box is always the client and never a server. Nothing on the host can open a
connection into it, and a reply only travels back down a connection the box opened.
Workers report through files on hop (4), not by connecting to the orchestrator.

## The verbs

| Box asks | Broker runs | Returns |
|---|---|---|
| `spawn <name> [kind]` | `pane split` against the registry's dock tail, then `pane run <new> <launcher>` for the box wrapper the allowlist fixes for the kind, then wait for the harness prompt to render | pane id and kind, or a refusal |
| `ask <name> <text>` | `agent prompt <pane> <text>`, then poll `agent get <pane>` for a working-then-idle transition, bounded by the timeout cap | final status |
| `read <name> [lines]` | `pane read <pane> --lines <n>` | pane text |
| `poll <name>` | `agent get <pane>` | status only |
| `close <name>` | `pane close <pane>` | ok |
| `list` | registry contents | names, panes, statuses |

`spawn` runs the box wrapper directly with `pane run`, not `agent start --kind`. Herdr
resolves `--kind claude` to its own canonical host `claude` and ignores the pane PATH, so
`agent start` would launch an uncaged host harness, defeating the point. Running the
wrapper as the pane command keeps every worker a cage.

Herdr cannot read the state of an agent whose TUI runs behind a container tty: detection
has no rule for it and falls back to idle. So `spawn` waits on `pane wait-output` for the
harness prompt instead of trusting `agent get`, `ask` watches for a working-then-idle
transition rather than a single idle sample (a lone idle sample is the pre-work state, not
completion), and `read` uses `pane read` because `agent read` is empty until the harness
is fully up. Readiness patterns are per kind (claude, codex and pi have built-in defaults);
`--ready-regex KIND=REGEX` overrides or adds one. The codex default matches its composer
placeholder ("Ask Codex to do anything") and the pi default its composer footer, so
readiness fires past each harness's startup screens rather than on a bare prompt marker.

### Worker model and endpoint

`spawn` takes optional `model`, `small_fast_model`, `base_url` and `auth_token` fields.
The box orchestrates and knows the task, so it chooses these freely; the broker only
refuses a value it could not carry safely (empty, over 8192 bytes, or control
characters). They are set on the worker with `pane split --env` as `ANTHROPIC_MODEL`,
`ANTHROPIC_SMALL_FAST_MODEL`, `ANTHROPIC_BASE_URL` and `ANTHROPIC_AUTH_TOKEN`, which
`claude-box` forwards into the cage (`libcage.sh` `FORWARD_VARS`). This is the same set
`claude-box --ollama` presets, so a worker can point at any Anthropic-compatible endpoint,
including a local one. When `model` is set and `small_fast_model` is not, the small model
defaults to the same value, because a local-only endpoint has no Claude model for the
background calls. `base_url` is the API root without `/v1`; Claude Code appends
`/v1/messages`. The value never reaches a shell, so it cannot become a command.

`spawn` also takes an optional `effort` (Claude's `--effort`: low, medium, high, xhigh,
max), carried as `CLAUDE_BOX_EFFORT`, which `claude-box` turns into the launch flag. The
box passes its usual level and the broker adjusts it for the model. A claude worker
reaches qwen over the Anthropic route (`output_config.effort`), whose shim currently
serves only low and medium, so minimal folds to low, high/xhigh/max fold to medium, and
the broker pins medium even when the box passes no effort (claude's unpinned default, high,
500s the shim). This is a limit of that shim, not the model: the model serves xhigh over
the OpenAI route (`reasoning_effort`) that codex and pi profiles use. Once the shim serves
xhigh, `QWEN_EFFORT_FALLBACK` can fold to xhigh instead.

A codex worker picks its model and endpoint differently: codex configures those through
profiles, not `ANTHROPIC_*`, so `spawn` takes a `profile` field, carried as
`CODEX_BOX_PROFILE`, which `codex-box` turns into `codex -p <profile>`. The named
`$CODEX_HOME/<name>.config.toml` supplies the model, provider and effort. Spawn a codex
worker with `--kind codex` (the launch must allow it: `--workers=claude,codex`).

A pi worker (`--kind pi`, `--workers=claude,pi`) picks its model from pi's own
`~/.pi-box/state/models.json` (mounted to `~/.pi/agent/models.json` in the cage); point it
at any provider pi supports there. There is no per-spawn model field for pi.

Transport is a unix socket on the host, reached from the box the same way the ssh agent
already is: `cage_relay_unix_socket` onto a loopback TCP port, socat back to a socket
inside. That helper is already generalised for this on the bridge branch and is the one
piece of that branch worth keeping. One JSON object per line in each direction, so a
session can be logged and read back later.

## Refusal rules

Two separate barriers do two different jobs.

```
  BARRIER 1: the container wall            BARRIER 2: the protocol
  -----------------------------            -----------------------
  stops the box reaching Herdr at all      stops the box choosing what runs

   x no herdr binary in the image           x no argv field exists in any verb
   x no HERDR_* variables forwarded         x pane ids refused, names only
   x Herdr's socket never relayed           x names must be in the broker's registry
                                            x send-text / send-keys never proxied
   the box cannot form the thought          x --env and --cwd fixed by the broker
                                            x agent start passthrough never accepted

                                            the box can form the thought,
                                            the broker will not carry it
```

A request carrying a command is not stripped or sanitised, it is unrepresentable: the
protocol has no field it could travel in. Filters get bypassed, absent fields do not.

These are the spec. Without all of them the broker is just the socket bridge with extra
steps.

1. No argv from the box, in any verb, ever. The broker composes the whole command line.
   There is no passthrough field in the protocol to abuse.
2. `kind` comes from a broker allowlist and resolves to the box wrapper, never the raw
   host harness. A `codex` worker is `codex-box`, so the worker is caged too. This is
   what makes `ask` safe: prompting a caged agent grants the orchestrator nothing it
   did not already have.
3. Every verb resolves a name through the broker's own registry. A pane id from the box
   is refused, and a name the broker did not create is refused. Without this the box can
   prompt or read the operator's own pane.
4. Never proxied at all: `pane send-text`, `pane send-keys`, `agent send-keys`,
   `pane split` with box-supplied `--env` or `--cwd`, `agent start -- <passthrough>`,
   `agent attach --takeover`. The send verbs are excluded because typing into a pane
   that holds a shell is the same as running a command in it.
5. `cwd` is fixed by the broker to the project it was started for. The box does not
   choose where a worker runs.
6. Caps, refused past the limit rather than queued: worker count, prompt bytes, and
   `--wait` timeout.
7. The broker refuses to start outside a Herdr pane, and refuses a second instance for
   the same orchestrator pane.
8. On broker exit, panes it created are closed and the registry entry is removed.

## Ownership state

Herdr has no first-class dock concept, so the caller keeps it. This is the same gap
discussion 1769 describes, and the same state the existing `herdr-codex-box-worker`
helper keeps.

One registry per orchestrator pane, keyed by `HERDR_PANE_ID`, holding the dock tail pane
and the name-to-pane map. `spawn` splits right off the orchestrator for the first worker
and down off the tail for each one after, which produces the appendable right column.
A registry whose tail is no longer in the tab is stale: refuse and tell the operator to
reset, rather than splitting something that now belongs to someone else.

## What the box gets

`box-worker`, on PATH in the image, speaking the line protocol and printing the reply as
JSON:

```
box-worker spawn <name>              box-worker poll  <name>
box-worker ask   <name> <text>       box-worker close <name>
box-worker read  <name> [--lines N]  box-worker list
```

Nothing Herdr-shaped is installed in the box and no `HERDR_*` variable is forwarded, so
an agent in the box cannot mistake itself for a Herdr-managed process.

So the orchestrator does not have to be told about `box-worker` each session, libcage
injects a worker brief into the box's own harness instructions when workers are active
(`_CAGE_WORKERS_ACTIVE`, set by `cage_setup_workers`). Each box points `BOX_BRIEF_FILE` at
its harness's native global file, claude `CLAUDE.md`, codex and pi `AGENTS.md`, and
`cage_inject_brief` writes the brief there between managed markers: idempotent, removed
when workers are off, and never clobbering surrounding user content. The brief lists the
verbs and available kinds, and includes a curated model catalogue if `WORKER_MODELS_FILE`
(default `~/.config/agent-box/worker-models.md`) exists. It only ever touches the
per-cage state copy, never a source, repo, or the host's global instruction files.

## A reduction worth taking first

If workers write findings to files in the project directory, which box and host already
share through the existing mount, then `read` and `poll` are not needed. The
orchestrator prompts "investigate X, write findings to docs/worker-explorer.md", waits,
and reads the file locally. That leaves `spawn`, `ask` and `close`. Three verbs is a
small enough surface to review properly, and the file trail is better evidence than a
scraped pane buffer. Build that first and add `read` only if something actually needs it.

## What this does and does not protect

It protects the host from the orchestrator. The box cannot choose a command, a pane
outside its own workers, or a working directory, so the worst it can do through the
broker is spawn permitted workers and talk to them.

It does not protect the host from the broker. The broker holds the full socket, so a
flaw in it is a host-execution flaw. It has to stay small enough to read in one sitting,
and it should log every request it accepts and every one it refuses.

It does not sandbox worker behaviour beyond the cage each worker already runs in. A
prompt can tell a worker to do anything that worker could do anyway, which is bounded by
the worker's own box, not by the broker.

## Done-signal

Externally observable, from an orchestrator inside a box:

1. `spawn explorer` opens a caged worker in the right-hand dock, and a second spawn
   appends beneath the first.
2. `ask explorer "..."` returns only after the worker goes idle, and the worker's output
   reflects the prompt.
3. A request naming a pane the broker did not create is refused and logged.
4. A request carrying anything argv-shaped is refused by the protocol, not by a filter.
5. Killing the broker closes its workers and leaves the operator's panes untouched.
6. No `HERDR_*` variable and no `herdr` binary is present inside the box.

## Open

- Whether the broker is a general agent-box component or codex-box's alone. The verbs
  are harness-neutral and `BOX_HERDR_AGENT` already names each box's kind, so general
  looks right, but nothing has needed it except codex-box.
- Cross-OS behaviour of the relayed Herdr socket is unverified against a live server.
  A linux/aarch64 herdr 0.9.0 client runs in the cage and dials `HERDR_SOCKET_PATH`, and
  the relay chain carries a round trip, but no end-to-end run against a real Herdr server
  has happened. The broker sidesteps this entirely by keeping the Herdr client on the
  host, which is a second reason to prefer it.
