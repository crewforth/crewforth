---
name: spec-planning
description: |
  Use when work needs a plan before code: the user asks how to split it into tasks or what the acceptance
  criteria are, or the scope spans more than one change.
---

# Spec-First Planning

<!-- routing-eval reads the next line; why it sits in the body: AGENT_TEMPLATE.md -->
Trigger phrases: "plan", "spec", "task breakdown", "acceptance criteria", "roadmap", "how do we split this"

Before writing code: what will be done, how it counts as "done", and in what order to proceed become clear.

## Steps
1. **Purpose & scope:** the problem being solved in a single sentence; also write the out-of-scope explicitly (prevent scope creep).
2. **Split into vertical slices:** the smallest end-to-end working pieces (not horizontal layers). Each slice delivers value on its own.
3. **A contract for every task:** input · output · **measurable acceptance criterion** (testable) · estimated risk.
4. **Dependency graph:** which task waits on what; no cycles. **Bring the riskiest/most-unknown to the front** (fail-fast).
5. **Uncertainties:** assumption list + open questions; do not fill ambiguous spots with a guess, ask with explicit options
   (how to ask, and what an unanswered question becomes: `brainstorm/references/asking.md`).

## Output (docs/PLAN.md)
**Before writing:** a `docs/PLAN.md` that still has unchecked tasks for other work is not overwritten. Stop and ask
whether to replace it, add this plan to it, or write this one beside it.
```
# <Feature> — Plan
commit: <HEAD when the plan was written>
status: active
## Acceptance criteria
- [ ] AC-1: <measurable outcome> — proven by: <the one test level: unit · integration · e2e · a named manual check>
- [ ] AC-2: <measurable outcome> — proven by: <…>
## Constraints
- <a value, limit or name copied word for word from the request or spec>
## Tasks (order)
Progress: tick a task [x] when its check passes, mark the one in work [~]; status: paused above when this work stops.
### Phase 1 — <name>                                              (phases only when the work has stages)
1. [ ] <task> — satisfies: AC-1 — size: <S/M/L> — dependency: <none/#n> — risk: <low/medium/high>
   Interfaces: consumes <name: type> · produces <name: type>      (only when a later task uses its output)
   Current code: <a few lines, verbatim, at the place it changes>  (optional)
2. [ ] …
— checkpoint: build and tests green, the criteria so far re-read —  (after every 2-3 tasks)
### Phase 2 — <name>
3. [ ] …
## Not covered by tests
- <an input or case no test reaches> → task <n>                    (five at most)
## Assumptions / Open questions
- ...
```
- **Every task carries a box, and the box is the record.** `[ ]` open, `[x]` done (its check passed, not "written"),
  `[~]` the one in work. Tick it in the same step that finishes the task; the `Progress:` line keeps that rule in the
  plan, where whoever works it reads it. `/crew-todo` draws the boxes under the status line.
- **The `status:` line says whether this plan is the work in progress.** When the user stops, parks or replaces the
  work, set it to `paused` (`dropped` when it will not come back, `done` when it is finished) in that same step; set it
  back to `active` when the work on it resumes. A paused plan gives the panel no count and no tasks, so the work that
  replaced it is not shown as this plan's next task. `/crew-todo pause` and `/crew-todo resume` set the same line.
- **No timeline and no estimate in time.** A size (S/M/L) says how much, never when.
- **No code beyond signatures.** A plan names functions and types; the bodies are the tasks' work. The only code a
  plan quotes is the current code a task changes, word for word.
- **Drift stops the work.** When a task's `Current code` no longer matches the file, or its files changed after the
  plan's `commit:`, the task stops and reports what moved. It does not improvise a new version of the plan.

**Every criterion carries a stable id, and every task names the ids it satisfies.** The id is what makes the plan
checkable later: "AC-2 is only partly built" can be said, argued about and tracked; "the second checkbox" cannot,
and renumbering a list silently re-points every reference to it. Never reuse or renumber an id — a dropped
criterion keeps its id with a strike-through and a one-line reason. A criterion no task satisfies, and a task that
satisfies no criterion, are both findings before a line of code is written: the task is cut, or raised as an open
question.

## Mark what you do not know — do not fill it in
Where a requirement admits more than one reading, write the marker **`[NEEDS CLARIFICATION: <the question>]`** at
that exact spot in the plan. Do not resolve it with the likeliest interpretation and move on.

This is the difference between a discipline and a hope. "Stop and ask when unsure" (§1) depends on noticing the
uncertainty in the moment; a marker survives into the artifact, where the user, a reviewer and a later session
can all see it. A plausible assumption silently written into a spec is indistinguishable from a decision, and
that is exactly how the wrong feature gets built correctly.

Rules that keep it honest:
- The marker carries the **question**, not the label. `[NEEDS CLARIFICATION: does an expired invite count as
  used, or can it be re-sent?]` is actionable; `[NEEDS CLARIFICATION: invites]` is noise.
- A plan may ship with markers — that is the point. It may **not** ship with a marker inside an acceptance
  criterion: a criterion nobody can evaluate is not a criterion.
- Resolve by asking, never by choosing. When the user answers, replace the marker with the answer *and* record
  which reading was rejected — the alternative is what a future reader needs.
- Zero markers on a genuinely ambiguous brief is a smell, not a win.

## Converge — before the work is called done, hold the code up against the plan

Tests prove the code does what the tests say. Nothing so far proves it does what the PLAN said: a criterion can be
quietly half-built with every test green, and code nobody asked for can ride along unremarked. So when a plan
exists, closing the work includes one pass that reads each criterion against the code as it now stands.

Bound the pass to what the plan names — the criteria, the tasks, and the files and components they point at. Do not
widen the audit into the rest of the codebase. For each `AC-n`, look at the code in that scope and record a finding
**only where there is a gap**, classified as exactly one of:

| Gap | Means |
|---|---|
| **missing** | nothing in the code implements the criterion |
| **partial** | something does, but not all of what the criterion states |
| **contradicts** | the code does something that conflicts with the criterion or a plan decision |
| **unrequested** | the code contains work no criterion or task called for |

`unrequested` is the one that is easy to skip and should not be: it is scope creep made visible (principle 3,
"surgical change"). It is surfaced, never deleted by this pass — the user decides whether it stays, and if it
does, it gets a criterion.

Report it as a table — `AC-n | gap | evidence (file/area) | remaining work` — then either:
- **Converged:** zero findings. Say so in one line, with how many criteria were checked.
- **Not converged:** append each remaining item to the plan as a task that names its `AC-n`, and go back to
  producing. Repeat the pass after that work, until it converges or the user accepts a named gap explicitly.

This is model discipline, not a gate: no exit code can judge "partially built". What makes it hold is the table —
a pass that produced no table did not run.

## DoD (this skill's contribution)
- Every task's "done" is testable; ordering and dependencies are visible; the riskiest work has been brought to the front.
- Every unresolved ambiguity carries a `[NEEDS CLARIFICATION: …]` marker; no acceptance criterion contains one.
- Every criterion has a stable `AC-n` id and at least one task that satisfies it; at close, a converge pass
  has run and either reported **Converged** or left its remaining items in the plan as tasks.
