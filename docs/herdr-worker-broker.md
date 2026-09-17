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
box (caged)                          host
┌──────────────┐  spawn NAME         ┌────────────────────────────┐
│ orchestrator │────────────────────►│ broker: holds the socket,  │
│              │  ask NAME "text"    │ owns the pane registry,    │
│              │◄────────────────────│ composes every command     │
└──────────────┘  reply / status     └─────────────┬──────────────┘
                                                   │ agent start/prompt/wait/read
                                                   ▼
                                      worker pane = codex-box (also caged)
```

## The verbs

| Box asks | Broker runs | Returns |
|---|---|---|
| `spawn <name>` | `pane split` against the registry's dock tail, then `agent start <name> --kind <kind> --pane <new>` | pane id, or a refusal |
| `ask <name> <text>` | `agent prompt <pane> <text> --wait --until idle --timeout <cap>` | final status |
| `read <name> [lines]` | `agent read <pane> --lines <n>` | pane text |
| `poll <name>` | `agent get <pane>` | status only |
| `close <name>` | `pane close <pane>` | ok |
| `list` | registry contents | names, panes, statuses |

Transport is a unix socket on the host, reached from the box the same way the ssh agent
already is: `cage_relay_unix_socket` onto a loopback TCP port, socat back to a socket
inside. That helper is already generalised for this on the bridge branch and is the one
piece of that branch worth keeping. One JSON object per line in each direction, so a
session can be logged and read back later.

## Refusal rules

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

A client named for the job, on PATH in the image, speaking the line protocol. Nothing
Herdr-shaped is installed in the box and no `HERDR_*` variable is forwarded, so an agent
in the box cannot mistake itself for a Herdr-managed process.

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
