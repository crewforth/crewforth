---
name: crew-board
description: "Experimental: team board — claim an item, hand it over, complete it."
argument-hint: "[claim <id> | done <id> | drop <id> | add <id> <title> | init | sync]"
disable-model-invocation: true
metadata:
  kind: command
  experimental: "true"
---
# /crew-board
Argument: $ARGUMENTS

Apply the `teamboard` skill. The engine is `bash .claude/hooks/board.sh` (Bash tool, not PowerShell); never hand-edit the board.

**Never make the user learn the syntax.** They should be able to run `/crew-board` and answer questions from
there; `claim 3` and `done 3` are yours to type, not theirs. Every step below ends in a question with explicit
options, not an instruction to go and type something.

- **no argument** → `board.sh status`, plus `board.sh decisions` when the session-start line says decisions are
  unread. Report: who holds what and for how long, what is claimable, what is blocked by which item, any STALE
  claim, and any unread team decision. Then **ask which item to take, as options** (the claimable ones, each
  labelled with its title and why it is a sensible next pick, plus "just looking"). On their answer, claim it —
  do not tell them to run a claim command. If nothing is claimable, say what would unblock what, and stop.
- **`claim <id>`** → `board.sh claim <id>`. A refusal is an answer, not an error: name who holds it and offer the
  claimable alternatives. Never work around a refusal. On success it prints the **connected work** — what each
  dependency actually delivered, and which items are waiting on this one. Read that back to the user before
  writing anything; it is the context the previous person had and you do not.
- **`done <id>`** → ask for what shipped (commit/PR), then `board.sh done <id> "<note>"`, tell the user which
  items this unblocked, and **immediately offer the next item as options** — closing one and picking the next is
  one movement, not two commands to remember.
- **`decide "<what>"`** → `board.sh decide`. Anything that changes how OTHER work must be done — a contract, a
  rejected approach, a constraint discovered the hard way — goes here the moment it is settled, while the reason
  is still in the session. It reaches every teammate's next session opening; a decision that stays in this chat
  reaches nobody. Write what was decided, why, and what it means for other items; name the items it affects.
- **`decisions`** → list them, or read one. Read these before planning anything.
- **`drop <id>`** → write the handover note FIRST — exactly where it stands, which files, and why the discarded
  approach was discarded — then `board.sh drop <id> "<note>"`. The engine refuses an empty note.
- **`add <id> <title> [deps]`** → add items. From `docs/PLAN.md`, carry each task's dependency edges across.
- **no board in this repo yet** → do not tell the user to run `init`; that is the syntax they should never have to
  learn. Say plainly what a board is for (a teammate's in-progress work is invisible without one) and **ask, with
  options**: set one up on this repo's own remote · set one up in a separate repository (they give the URL — for a
  board shared across repos, or people who cannot push to the code) · not now, this is solo work. On "not now",
  drop it and do not raise it again unprompted. On a yes, run `init` yourself, then offer to fill it from
  `docs/PLAN.md` if one exists, or ask for the items. Report what the server accepted (custom ref namespace or the
  orphan-branch fallback) in one line — the user should know where their board lives without having to ask.
- **`init`** → the same thing when asked for directly. `init --remote <url>` puts the board in a separate
  repository. Run by ONE person, once — everyone else configures nothing and the board reaches them on its own.
  If a board already exists this fetches it rather than creating a second.
- **`sync`** → fetch and re-read; use it when the board looks stale or a gate message disagrees with reality.
- **`off` / `on`** → release every board gate for this repo (`off --global` for all of them) and put them back.
  The board is untouched either way. A repo that never ran `init` has no gates to begin with — never imply the
  user must turn something off to work alone.

Before writing any code for an item, confirm this user holds it. Commits are gated: `[#<id>]` for a held item,
`[chore]` otherwise. Strip secrets from anything written to the board — it is pushed to the whole team.
