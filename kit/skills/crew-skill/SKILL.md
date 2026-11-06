---
name: crew-skill
description: Author or change a Crewforth component (skill / agent / command) against the template and its gates.
disable-model-invocation: true
metadata:
  kind: command
---
# /crew-skill

`AGENT_TEMPLATE.md` states the contract for a component. Full installs carry it (refreshed on `update`); the
plugin edition does not. No gate routes to it, so this command is the route, and it ends in the gates.

**A component is not finished when it is written. It is finished when the suite says so.**

## 1. Decide the shape before writing anything
Read `.claude/AGENT_TEMPLATE.md`. Then answer, in one line each:

- **What is the smallest form that works?** A rule in an existing skill's body beats a new skill; a new skill beats
  a new agent. Every new skill costs its NAME in every session, forever, for every user — and its description too,
  until the listing overflows its budget, at which point descriptions start being dropped from the skills you
  invoke least. Say what that buys.
- **Who reaches it?** An agent, a command, or the discipline's trigger map. If the answer is "the model will notice
  the description", stop — that is the dark component §3b exists to catch.
- **Read or write?** A component that reports and a component that changes files do not belong together: different
  risk, different done-criterion. Split them.
- **Is it stack-neutral?** Anything shipped to every profile names no language, framework or vendor as *the* case.
  The example you have in mind is not the scope.

## 2. Write it
- Skill: `.claude/skills/<name>/SKILL.md` — the directory name and the `name:` field must match. Keep the body
  lean; depth goes to `references/*.md` and is loaded on demand.
- Agent: a thin trigger — *who and when*. The *how* lives in the skill it applies; do not copy the method in.
- The `description` says **when to reach for this**, not what its author knows. A description that summarises the
  method gets acted on instead of the body.
- A step that sends the reader to `references/<file>.md`: if that file is missing or unreadable, the skill says to
  stop that step and name the path. It does not let the reader improvise the content.
- How a rule is worded decides whether it holds:

  | Form | How it fails | Write instead |
  |---|---|---|
  | A nuance clause ("unless clearly needed", "where sensible") | Read as permission; the exit gets taken | The rule, plus the one exception named by its test |
  | An exemption clause ("except for X") | Does not stay scoped; it spreads to cases that look like X | The exception as its own rule, with its own check |
  | A rule nothing can see broken | Broken silently | Name what a reviewer sees when it is broken |

- A discipline skill ends with a **Before you finish** table: left column a pattern you can detect in the diff or
  the output, right column what to do about it. Pruning test for every sentence: if it could appear unchanged in
  another project's docs, it says nothing here. Cut it.

## 3. Register it — the cascade, in this order
Skipping one of these is how a component ships half-installed:
1. **Route it.** Name it in an agent body, a command, or the trigger map. §3b checks exactly this.
2. **Golden case.** Add a positive line to `.claude/eval/golden-routing.txt` — and a **negative** one
   (`prompt|!target`) for a neighbour it must NOT steal.
3. **Catalog + counts** *(Crewforth repository only — `packaging/` is not installed anywhere)*.
   Add the Turkish summary line (`packaging/skill-summaries.tr.tsv`; agents and commands have their own `.tr.tsv`),
   which the site build requires (`cd site && npm ci && npm run build`), and the diagrams if the component set changed:
   `node packaging/gen-diagrams.mjs` writes `assets/`, and smoke fails while any of them is stale.
4. **Plugin edition** *(Crewforth repository only)*. `bash packaging/build-plugin.sh` — in the same commit, or the
   release stops at the sync gate.
5. **Budget.** A new skill moves `BUDGET_SKILL_LISTING` (the skill listing in characters, counted like Claude Code
   counts it; `/crew-doctor` reports the same number). Raise it in the same commit with the justification comment the
   file's convention requires. Never raise it to make a red gate green without saying why.

## 4. Prove it — run all four, in this order, with the Bash tool, not PowerShell
```
bash .claude/eval/scan-skill.sh .claude/skills/<name>    # supply-chain: SAFE, and rc=3 means NOT scanned
bash .claude/eval/routing-eval.sh                        # the golden case, positive and negative
bash .claude/eval/smoke-test.sh                          # structure, budget, §3b routed, cross-links
CREW_NO_STAR=1 bash .claude/eval/doctor.sh               # the live install still healthy (star line off here)
```

**Rule text.** A change to the discipline file or to an agent's rule text ships a measured A/B: `evals/run.sh` with
the two arms of `CREW_EVAL_ARMS` (the second set by `CREW_EVAL_DISCIPLINE_B`, `CREW_EVAL_OVERLAY_B`), at least 3 runs per arm, on one case the
change should move and one it could break *(Crewforth repository only)*. When you probe wording by hand: one fresh
session per sample, a control with no guidance, 5 or more repetitions, and report the spread, not only the mean.

**Descriptions.** In the Crewforth repository a changed `description` needs
`node packaging/skill-eval/run.mjs` before CI: `check.mjs` refuses a description it has no measurement for.

**A new model.** Re-run `skill-eval --all` and the A/B evals before touching wording. Delete a rule only with a
before/after probe that shows it no longer changes the outcome.

In the plugin edition none of the four commands above exist — it ships no `eval/` scripts — so there the proof is
the Crewforth repository's own suite, not a local run.

**Do not finish while §3b is red.** "It works when I invoke it by name" is not the claim being tested — the claim
is that something reaches it without being told to. If the suite skips a case, that is not a pass: chase why.
