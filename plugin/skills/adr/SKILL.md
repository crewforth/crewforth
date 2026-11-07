---
name: adr
description: |
  Architecture Decision Record: context-decision-consequences, for decisions that are expensive to reverse.
---

# Architecture Decision Record (ADR)

<!-- routing-eval reads the next line; why it sits in the body: AGENT_TEMPLATE.md -->
Trigger phrases: "adr", "architecture decision", "decision record", "why this approach", "why we chose", "why we went with", "nobody remembers why", "why we picked"

## When
On an architecture/technology choice that is expensive to reverse, long-lived, or contested
(database selection, auth strategy, critical pattern). Small/reversible decisions do not require an ADR.

**Most of these are never announced as decisions, and that is how they get missed.** The examples above all
sound like a question someone asked — "Redis or Postgres?" — so they are easy to recognise. The ones that
actually escape arrive inside ordinary build work: you are asked to add a feature, and along the way you settle
what an entity owns, what a session is bound to, what makes a row unique, which layer holds a rule. Nobody said
"decide"; you decided anyway, and the next person inherits it with no idea it was a choice. Measured in the
field: one infrastructure task settled four such questions and produced no record of any of them, in a session
where this skill was installed and its trigger read every turn.

So the test is not "was I asked to choose". It is: **would a maintainer six months from now, wanting to do this
differently, need to know why it is this way?** If yes, it is an ADR, however undramatic it felt while writing
it. Cheap tell: you rejected an alternative in your head and moved on without writing it down.

## On a team, the record ALSO goes on the board
`docs/` is gitignored in an install, so an ADR written there reaches the machine that wrote it and nobody else —
which is the opposite of what a decision record is for. When a `teamboard` exists, record it with
`board.sh decide "<title>" "<context + decision + consequences>"` as well: the board is shared, so it arrives at
every teammate's next session opening, and it travels even when the board lives in its own repository. The local
file stays the long form; the board entry is the part that has to reach people, so it must be readable on its
own — a title nobody can act on ("auth decided") is not a record.

## Where it goes: the project's scheme first
Before writing, look for records that already exist: a decisions folder (`docs/adr/`, `doc/adr/`,
`docs/decisions/`, `Documentation/Decisions/`, `architecture/decisions/`), an `.adr-dir` file (adr-tools), or files
named like `ADR-004-…` or `0004-…`. Found: continue it, same folder, extension (.md, .rst, .adoc), numbering and
heading style, next number. Not found: `docs/adr/NNNN-short-title.md` below. Never start a second scheme beside one
that exists; two numbering lines make every "see ADR 12" ambiguous.

## Format (fallback: docs/adr/NNNN-short-title.md, ~1 page)
```
# NNNN. <Decision title>
Status: proposed | accepted | rejected | superseded (by NNNN)
## Context
Which problem/constraint requires this decision?
## Decision
What was decided (clear, one sentence + rationale)?
## Consequences
Pros / cons / accepted trade-offs.
## Alternatives considered
Why were they not chosen?
Verified against: <package>@<version> · <docs or source> · <date> — or "none" (no external fact relied on)
```

## Principles
- **Invariant:** a new decision marks the old ADR as `superseded`; an ADR is **never deleted** (decision history is preserved).
- Numbered and dated; keep it short.
- **A number a test enforces moves with its ADR.** When a test or gate pins a figure an ADR set (a cap, a count, a
  budget), the change that moves the figure amends that ADR in the same commit; a figure that drifts from its record
  leaves the next reader two answers.

## Deliberately bypassing a rule is a decision too
A gate the user knowingly overrode — a deferred DoD item, an accepted known gap, a trimmed scope — belongs here
whenever its effect outlives the task. It is not a lesser kind of decision: choosing *not* to apply a rule shapes
the codebase exactly as choosing a database does, and it is the one class of decision that leaves no trace in the
code at all. Six months on, a rule that was weighed and overridden is indistinguishable from one that was never
noticed, and the second is the one you would want to fix.

Record it in the same file as any other decision, with the fields that make it reversible:

```
## Bypassed
- <gate/rule> — why: <reason> — asked by: <who> — revisit: <condition or date>
```

`revisit` is the load-bearing field. A bypass with no condition attached is permanent by default, and nobody
chose permanence. See [[confidence-check]], which is where most bypasses surface. A recorded bypass is the user's decision, not a
deferral (`CLAUDE.md`, "No deferral").

## DoD
- Decision + rationale + rejected alternatives recorded; status current.
- Any deliberately bypassed rule is recorded with its reason, who asked, and what would reverse it.
