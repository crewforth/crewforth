---
name: confidence-check
description: |
  Readiness gate BEFORE writing implementation code: does this already exist, does it fit the project's
  architecture, is the API claim actually checked, is there a working reference, is the root cause known.
---

# Confidence Check — earn the right to start

<!-- routing-eval reads the next line; why it sits in the body: AGENT_TEMPLATE.md -->
Trigger phrases: "confidence check", "ready to implement", "before I start", "am I sure enough", "readiness"

## When
Right before implementation code gets written for anything beyond a one-line change, and *after* the scope is
clear ([[spec-planning]] / planner). Every other gate in Crewforth fires at the end — review, DoD, the commit
approval. Those catch bad code. None of them catch **good code that should never have been written**: the
duplicate of a helper that already exists, the pattern that fights the project's architecture, the call built
against an API that behaves differently than remembered. That waste is invisible to a reviewer, because what
they see is a clean diff.

## The six checks
Each is answered with **evidence**, not with a feeling. Name what you ran or read.

| # | Check | How it is actually answered |
|---|---|---|
| 1 | **Does it already exist?** | Grep/Glob the codebase for the behaviour *and* its likely other names. A near-duplicate counts. |
| 2 | **Does it fit this project?** | Read `CLAUDE.md` + the relevant project skill. Same stack, same pattern, no new dependency smuggled in. |
| 3 | **Is the external claim verified?** | The API / library / config behaviour you are relying on: read the real docs or the installed source. Recalled API shapes are the single most common wrong assumption. A version or API fact from an ADR, a handover or memory is dated context: re-check it against the installed version and say `current`, `stale`, `contradicted` or `could not verify`. |
| 4 | **Is there a working reference?** | An existing call site in this repo, or a known-good implementation. "It should work like this" is not one. |
| 5 | **Is the root cause known?** | For a fix: the *cause*, not the symptom. Unknown → this is a [[systematic-debugging]] task, not an implementation task. |
| 6 | **Can it be PROVEN when it is done — with what is running right now?** | Name the thing that will show it works — the suite, a migration applied to a real database, a request against a running service — and confirm it is reachable *before* starting, not after. One command. Measured: an agent spent 44 minutes and 167k tokens producing a migration, then found the database daemon was down and returned unverified. A precondition discovered at the end costs the whole run. |

## The verdict is not a score
The tempting form is a weighted score with a threshold. It is theatre: with six checks and any sane bar, a
single failure sinks it anyway, so the weights only decorate a decision that was already binary. So: **any "no"
is a stop.** Say which check failed and do the one thing that answers it — search, read the doc, find the
reference, debug the cause — then start. If the user wants to proceed with a known gap, that is their call to
make explicitly, and it gets written down as an assumption, not swallowed.

Checks 3–6 do not apply to every task (a pure refactor has no external claim and no bug; a change the suite alone
proves needs nothing brought up). Mark those **n/a**
with a reason — n/a is a judgement you are stating, not a check you are skipping.

An ambiguity you cannot resolve is not a failed check — it is a `[NEEDS CLARIFICATION: …]` marker
([[spec-planning]]) carried into the plan. Guessing it and passing check 2 is the failure mode this gate exists
to catch.

## A bypassed gate leaves a record
Gates get bypassed, legitimately: the user accepts a known gap, a DoD item is deferred, scope is trimmed under
time pressure. What must not happen is the bypass being *spoken and forgotten* — three weeks later nobody can
say whether a rule was weighed and overridden or simply missed, and those two are indistinguishable from the
code. That gap is the missing half of "rule → gate": Crewforth enforces the rule at the tool level, and this line is
the record of a human deliberately stepping past it.

So when a gate is knowingly bypassed, write one line where the decision lives — the ADR for anything lasting
([[adr]]), otherwise the plan's assumptions section:

`BYPASSED <gate> — <why> — asked by <who> — revisit: <condition or date>`

The `revisit` field is what separates a decision from a leak: a bypass with no condition attached is permanent
by default, and nobody chose that. Never write this on the model's own authority — a bypass is the user's call,
so the line records *their* decision, and its absence means the gate was not bypassed at all.
A recorded bypass is not a deferral (`CLAUDE.md`, "No deferral"): the user chose the cost, in writing.

## Output
Six lines, one per check: `✅ <what was run/read>` or `❌ <what is missing>` or `n/a — <why>`. Then either
"starting" or the single action that unblocks it. Keep it to the main thread; it is a handful of lines, not a
document.

## Fix the deciding rule before you see the options
When this check ends in a choice — which approach, which library, which of three designs — write down what would
make an option **win**, and what would **disqualify** one, *before* generating or evaluating any. A criterion
chosen after the options exist is a criterion shaped by them: it will quietly favour the one already preferred,
and nothing in the output will show that it did.

Write the **kill criterion** in the same breath: what would make you abandon the whole approach. An option set
with no losing condition is a preference wearing an analysis.

> Honest boundary: this one is discipline, not a gate. Nothing can check whether the rule was written before the
> options or backfilled after them — the value is that the user can see the rule stated first and argue with it,
> which is impossible when the criterion never leaves your head. Treat it as cheap insurance, not as proof.

## DoD (this skill's contribution)
- Every check is answered with a named command, file, or document — never with a recollection.
- Any "no" was resolved before implementation started, or is recorded as a user-accepted assumption.
- Check 1 was answered by an actual search, not by "I don't think we have one".
- A fix with an unknown cause went to [[systematic-debugging]] instead of being implemented on a guess.
