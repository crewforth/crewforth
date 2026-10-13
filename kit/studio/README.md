# Crewforth Studio

A visual orchestration panel for Claude Code: which agent is running, what it is
doing right now, what it has spent, and which gates fired.

Studio **is installed into your project**, because it lives inside the payload:
this directory is `kit/studio/`, and `kit/` is what every
channel already ships. `start.sh` and `adopt.sh` copy it to `.claude/studio/`,
beside `agents`, `skills`, `commands`, `hooks` and `eval` — the sixth of six.

That was the other way round until a real project updated with `/crew-update`,
ran the documented command and got ENOENT: the project had no `package.json`,
and nothing had ever installed the panel into it. Excluding it from every
channel was a decision; a documented command that cannot work is a defect.

## Run

From any project that has Crewforth:

```bash
/crew-studio                                  # the command; probes node, starts it, reports the URL
node .claude/studio/server/index.js --open   # the same thing without the picker
```

**`node` may not be on your PATH, and that is on purpose.** When Crewforth fetched the runtime for you
(`ensure-node.sh --install`), it promised to touch nothing outside `~/.claude/studio-runtime` — no PATH edit,
no shell profile, no admin rights. Measured on a stock Windows 11 machine: after a successful install
`node --version` reports v24.21.0 through the full path while `command -v node` finds nothing, which is the
promise being kept rather than a broken install. So every `node …` line on this page means "the node Crewforth
can find". Ask for it instead of assuming it:

```bash
NODE="$(bash .claude/studio/ensure-node.sh)"   # prints an absolute path, exits 1 if there is none
"$NODE" .claude/studio/server/index.js --open
```

`/crew-studio` does exactly this for you, which is why it is the first line above and not the second.

Other flags, same file:

```bash
node .claude/studio/server/index.js --port 8080
node .claude/studio/server/index.js --selftest     # offline checks, no browser
```

**Started per project, scoped to the machine.** Studio reads
`~/.claude/projects`, which holds every session on this machine. The count is
whatever that directory holds; the panel prints it rather than claiming it here,
because a number measured on one machine describes only that machine. So a
running panel already sees a kit-installed project without being started inside
it, and the working directory only decides which project the panel opens on.
Run it from wherever is convenient, or run it once and leave it up.

`--open` exists so the URL is not copied by hand: the token is generated per run
and the panel refuses requests without it. When a browser cannot be opened — over
SSH, or headless — the server says so rather than looking like it worked, and
`/crew-studio` reports the URL either way.

**Both editions carry the panel, in different places.** A full install has it
at `.claude/studio/`; the plugin edition has it at `studio/` in the plugin's own
root. One `/crew-studio` file serves both, and its first step tells them apart
by reading `${CLAUDE_PLUGIN_ROOT}/studio/server/index.js` literally: Claude Code
replaces that placeholder before the command is read, and only when the command
came from the plugin. A real absolute path is the plugin's panel; the
placeholder left standing means a full install. Neither path on disk means an
install older than the panel, which `/crew-update` brings up to date.
In the plugin the command is namespaced: `/crewforth:crew-studio`.

**What the plugin edition cannot show.** A plugin install puts no
`.claude/VERSION`, `kit.conf` or Crewforth scripts into a project. That project's row
in the list has no version badge, and for the project the panel was opened from, the
inspector's gates, stats and board tabs say "Not measured" with the reason rather
than zero. The gates tab can still list what the gate log observed: the plugin's
Bash guard records its blocks, approval prompts and pre-authorised git actions,
and its gate-file write guard its blocks, in `.claude/gate-log.tsv` when the
project has a `.claude/` directory, the file is git-ignored or the project is
not a repo, and `CREW_GATE_LOG` does not send the log elsewhere.
Everything else — the live
agent graph, owned sessions, the permission bridge — works the same in both
editions.

**The suite is not here.** It lives in `packaging/studio-test/`, beside the
repo's other gates, and asserts things about this *repository* — the root
`package.json`, the payload beside it — which an installed project does not
have. Keeping it under `kit/` would also have shipped 104 KB of test
code through all three channels only for the installer to delete it on arrival.
The installed diagnostic is `--selftest`, which lives in `server/index.js`.

There is no install step. Studio has **zero dependencies** — `node:http` and
`node:child_process` are the whole stack, matching Crewforth's own promise. If
`node_modules` ever appears here, something has gone wrong.

Requires Node 18+. In Crewforth's own repository `bash packaging/verify.sh studio`
runs the same checks CI runs; a machine without node reports a skip rather than a
pass, and a missing `kit/studio/` is a failure rather than a skip.

## What it does

**Watches.** The delegation graph of any session on this machine, live: one node
per agent, what it is doing right now, what it has spent, what it reported.
Nodes are draggable and their positions are remembered; a workflow run is a
container you can fold.

**Talks.** Sessions the panel starts are driven over stdin/stdout, so you can
write to one and watch its agents appear beneath it. They are given a session id
up front, which means their transcripts land where every other session's do and
the graph reads them without a special case.

**Shows every conversation, drives only its own.** Selecting any session opens
what was said in it, read from the transcript. A session the panel did not start
has no channel to write to, so that pane says so and offers the two things that
do work: continue it here, or open it in a real terminal.

**Asks before it acts.** Every tool call in an owned session is parked by a
PreToolUse hook and shown in the panel — the command itself, not just the tool's
name — until you allow it, allow that tool for the session, or deny it.

**Runs several at once.** Each session the panel starts is a tab that keeps its
own stream open whether or not it is on screen, so work continuing in the
background is continuing, not replayed when you look back.

**Hands a session to a real terminal.** The panel cannot drive a session it did
not start, so for an observed one it offers the only thing that is true: a
button that opens it where it can be driven. What it will run is shown before
anything launches.

**Reaches other machines.** Transcripts are local files and nothing enumerates
another machine's sessions, so a peer is another Studio.

## What it reads

| Source | What it gives |
|---|---|
| `claude agents --json` | Live sessions on this machine: name, cwd, busy/waiting/idle, what it is waiting for |
| `<session>.jsonl` and `<session>/subagents/` | The delegation graph, nested workflow runs included |
| `.claude/VERSION` per project | Which projects run an old Crewforth, against the npm dist-tags feed |

That call spawns a process, so it is cached rather than repeated. The browser
polls every 2 s and the server caches for 1 s, which bounds the cost at one
spawn per poll. What the spawn costs is a property of the machine, not of this
file — two machines here measured 131 ms and 164 ms medians — so `--selftest`
measures it wherever it runs and prints that number instead of quoting one.

More sources land in later sprints: the transcript tree (per-agent live JSONL),
the owned-session event stream, `gate-log.tsv`, and the team board.

## Two honesty rules

These are load-bearing, not stylistic.

**"Not measured" is never drawn as zero.** If the `claude` CLI is missing or a
read fails, the panel says so and names the reason. An empty list would read as
a quiet, healthy machine — which is the kind of lie this panel exists to stop
telling.

**Unknown data is never coerced into something familiar.** An unrecognised
status keeps a neutral ring; an unrecognised field is carried through untouched
rather than dropped. Claude Code's event shapes are undocumented and move with
the version, so the panel is built to notice that rather than to guess.

## Sessions on other machines

The fleet lists them under **Reachable elsewhere**, with the time they were
seen. That wording is the whole of it: this is a snapshot, not a feed.

Only a session connected to Remote Control can see peers on other machines.
Measured: a headless session's `ListAgents` returns the local peers where a
connected one returns those plus five remote, and passing `--remote-control` to
a headless session does not change that — the flag starts an *interactive*
session. There is no documented API or non-interactive command that enumerates
them; `/list-agents` is an in-session tool, `--cloud` refuses without a TTY, and
the Claude API's `/v1/sessions` belongs to Managed Agents, a different product.

So the panel does not try to be that session. It reads what one already wrote:
a connected session's `ListAgents` result lands in its transcript as structured
text, and that is where this comes from. When no session here has ever asked,
that is reported as not measured — which is not the same as having no peers.

Listed, not opened. Those sessions' transcripts are on those machines' disks,
so the panel can name them but cannot draw their graphs. For that, run Studio
there too:

## Other machines

```bash
# on the other machine
node .claude/studio/server/index.js

# here — forward its port, then point at the forwarded one
ssh -N -L 7778:127.0.0.1:7777 other-machine
node .claude/studio/server/index.js --peer http://127.0.0.1:7778 --name mac
```

Sessions, projects, graphs and agent reports from a peer appear alongside local
ones, tagged with the machine they came from. A peer that cannot be reached is
reported as unreachable, never as empty.

Nothing listens on a network interface in this arrangement: both Studios stay on
loopback and the tunnel does the crossing.

## Remote viewers

A viewer is a second token that reads and changes nothing, for watching the
panel from another device without handing that device the panel. Add one in the
Machines tab; its link is shown once. The server refuses a viewer's every
request that is not a `GET`, and its reads of `/api/remote`, with 403 before any
handler runs (`server/lib/remote.js`). Revoke ends the token and closes a
stream it holds open. Viewers live in memory and end with the server.

The server still binds to loopback. Reaching it from a phone is a tunnel the
user runs, an ssh forward or `tailscale serve 7777`; Studio starts none.

## What Crewforth already measured

The panel does not recompute any of it. Selecting the session node opens what
Crewforth's own tools say, including when they say they cannot answer:

| Tab | Source |
|---|---|
| gates | `gate-report.sh --json` for the rule inventory, `.claude/gate-log.tsv` for what fired |
| stats | `session-stats.sh --raw` — fifteen metrics over this transcript |
| board | `board.sh status` |

One distinction is carried all the way to the screen. A gate event from a
session the panel started arrives through `--include-hook-events` and carries
the moment it happened, so it is listed under **Happened**. A line in
`gate-log.tsv` does not — that format has no timestamp column — so those are
listed under **Observed**, with the reason written out. Drawing the second as
the first would be the first untrue thing in this panel.

`gate-report.sh` finds the hooks relative to where it runs: `./.claude/hooks`
in an installed project, `./hooks` otherwise. Both layouts are handed what they
expect rather than the script being asked to guess. Where it still cannot
answer — a directory with no Crewforth install, a project with no log — that is reported as
not measured, never as zero.

## The permission gate

A hook injected through `--settings` parks each tool call, writes it into a
spool, and waits for the panel's answer. Exit 0 allows, exit 2 blocks.

It answers at 45 seconds against a 90-second harness timeout, and that gap is
the whole design. Measured here: a hook killed at its timeout emits nothing and
**the tool proceeds** — `permission_denials` came back 0 and the command ran. A
hook the harness never has to kill fails closed instead, so a shut panel is a
denial rather than an opening.

The waiting costs no processes. A bounded read on a fifo held open read-write
blocks for its timeout and never sees EOF; the alternative, a `sleep` per poll,
spends seconds of fork overhead on Git Bash. Both the fifo and the shell's
support for fractional timeouts are probed with exactly what the loop will run —
bash 3.2 ignores a fractional `-t` and turns the poll into a hot spin, which is
how the first version passed while spinning 185,000 times in five seconds.

Interactive prompts have a limit worth stating: `AskUserQuestion`, `ExitPlanMode`
and `EnterPlanMode` are absent from a headless session's 78-tool list, in every
permission mode, while an interactive session has them. So there is no
structured choice to render. When a reply offers options in prose the panel
makes them clickable, which sends that text — a shortcut for typing it, not a
channel that does not exist.

## Security

The server binds to `127.0.0.1` only, and the host is deliberately not
configurable — it reads a developer's live sessions and can start new ones.

A token is always required for `/api/`. Supply one, or let the server generate
one and print it with the URL:

```bash
CREW_STUDIO_TOKEN=$(uuidgen) node .claude/studio/server/index.js
```

Anything that changes state needs, on top of the token, a header no cross-origin
page can attach without a preflight this server never answers. Permission modes
are an allow-list — `plan` (the default), `acceptEdits`, `default` — so a mode
that skips Crewforth's gates cannot be requested, and the panel never has to name
one to refuse it.
