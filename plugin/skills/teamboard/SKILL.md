---
name: teamboard
description: |
  Experimental: a shared team board. Claim a work item, hand it over, finish it; the claim is a git-ref
  lock, so two people cannot take the same item.
metadata:
  experimental: "true"
---

# Team Board (shared claims + shared item memory)

<!-- routing-eval reads the next line; why it sits in the body: AGENT_TEMPLATE.md -->
Trigger phrases: "team board", "who is working on", "claim", "take this item", "pick up a task", "sprint item", "release the item", "hand the item over", "is anyone on", "board", "of us are working", "stepping on each other", "who is doing what", "who else is working"

## The problem this closes
Every teammate runs Crewforth **locally**. `docs/PLAN.md` and `docs/SESSION_STATE.md` are gitignored, so the fact
that Ali started item #1 two hours ago exists nowhere the other sessions can see. Two people start the same item;
a blocked item gets picked up before its dependency lands; whoever inherits half-finished work rebuilds the
context from scratch. The board makes those three facts shared.

## The engine (all commands go through it, with the Bash tool, not PowerShell)
`bash "${CLAUDE_PLUGIN_ROOT}/hooks/board.sh" <cmd>` — `status` · `show <id>` · `claim <id>` · `done <id> [note]` ·
`drop <id> <note>` · `note <id> <text>` · `add <id> <title> [deps] [external]` · `init` · `sync`.
Never hand-edit the board; every write must go through the engine or it loses its atomicity.

## Why a claim is a real lock, not a convention
The board lives on a git ref (`refs/crew/board`), not in the worktree. A claim is a commit pushed to that ref, and
`git push` is fast-forward-only: when two people claim the same item from the same base, **one push is rejected**
and that session re-reads the board and refuses. This is an atomic compare-and-swap with no server, no token and
no daemon. The engine builds its commits with git plumbing, so claiming **never touches your working tree,
index, branch or stash** — you can claim mid-feature with dirty files.

## Off by default; on when a team asks for it
A repo that never ran `init` **has no board and no gates** — no claim, no commit gate, no edit gate, nothing at
session start. Solo work is unchanged, and so is every project that installed Crewforth before this existed. Do not
create a board because a repo merely has more than one contributor; create one when the user says the team keeps
colliding. Creating one, choosing between its three levels and the ref-namespace fallback: **`references/setup.md`**
— one person runs it once, and everybody else configures nothing.

Already have a board and want it out of the way? `/crew-board off` (add `--global` for every repo) releases **all
three** gates and leaves the board itself intact; `/crew-board on` restores it. `CREW_NO_BOARD=1` does the same for
one session. This half stays here on purpose: someone a gate has just stopped needs the answer without opening a
second file.

## The rules
1. **Claim before you touch code.** `claim <id>` fails if someone else holds it, if it is done, or if a
   dependency is unfinished — with the reason and the list of what *is* claimable. Do not argue with a refusal;
   take a free item.
2. **Two gates, not one, and the early one is the point.** The first file edit is refused while you hold no item
   (`guard-write.sh`) — unclaimed work is caught at minute one, not at commit time after an afternoon of it. The
   commit then has to carry `[#<id>]` for an item you hold and that is `in_progress`, or `[chore]` for work
   belonging to no item. In a repo with no board neither gate exists. `CREW_NO_BOARD=1` disables both for a
   session; say so out loud if you set it.
3. **Never release silently.** `drop` REQUIRES a handover note, because the whole cost of a handover is the
   context the next person does not have: where exactly it stands, which files, and *why* the rejected approach
   was rejected. `done` takes a completion note (what shipped, commit/PR).
4. **Never steal a stale claim.** A claim with no heartbeat for `stale_hours` (default 8) is reported as STALE.
   Stale means *ask the owner*, not *take it*. Surface it to the user and let them decide.
5. **Read before you plan.** At session start the board summary is injected automatically. Before proposing what
   to work on, run `status` — recommending an item somebody already holds is the failure this exists to prevent.

## Redaction — the board is shared
Everything written here is pushed to a remote the whole team reads. `handoff`'s `<private>…</private>` rule
applies unchanged: strip secrets, tokens, credentials and personal notes, leave `[redacted]`, and point at
*where* a value lives (env var, secret manager, the person to ask) rather than the value.

## Filling the board
Items come from either direction, and both end at `add`:
- **From a plan:** `crew-planner` + `spec-planning` produce the plan for `docs/PLAN.md` with measurable acceptance
  criteria and a dependency order; each task becomes one `add <id> <title> <deps>`. Keep the plan's dependency edges — they
  are what makes `claim` able to refuse blocked work.
- **By hand:** the user dictates the items.

## Tracker link (honest boundary)
Teams use Jira, Trello, Linear, GitHub Issues or nothing, so Crewforth **binds to none of them**. An item carries an
optional `external:` field, which is a link and nothing more — no sync, no import, no write-back. A team that
wants two-way sync writes an executable `.crew/board-adapter.sh` answering two verbs: `import` (emit
`<id>|<title>|<deps>|<external>` lines to be fed to `add`) and `export <id> <status>` (push the state outward).
Crewforth ships no adapter; do not claim integration Crewforth does not have.

## When the remote is unreachable
Claims stay local and are labelled `UNSHARED` — meaning **the team cannot see them**, so the lock is not in force.
Say that plainly rather than reporting success, and re-run `sync` once the network is back.

## DoD
- Work started only on an item held by this user; the board shows it `in_progress`.
- An item left for any reason carries a handover note a stranger could resume from.
- `done` recorded with what shipped, and the dependents it unblocked named to the user.
