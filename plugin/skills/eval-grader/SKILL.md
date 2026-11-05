---
name: eval-grader
description: |
  Measure output quality, don't vibe it: score a generative task with a two-layer grader — deterministic code
  metrics + per-dimension LLM-as-judge — over a fixed task set, as signed deltas vs a pinned baseline. Grades
  cost alongside correctness (pass-slow).
---

# Eval Grader

<!-- routing-eval reads the next line; why it sits in the body: AGENT_TEMPLATE.md -->
Trigger phrases: "eval", "grader", "measure output quality", "LLM-as-judge", "score the output"

**Measure every change; don't vibe it.** When you iterate on a prompt, an agent, or any generative output (docs,
slides, UI, a summary, an extraction), a two-layer grader over a fixed task set turns "feels better" into a signed
number you can trust.

This is the **external, machine-grounded verifier** the `iterate` skill asks for — a model grading its *own* output
inflates; a separate grader on a fixed suite does not.

> **Crewforth adaptation (local, .claude/):** use when tuning a generative task; the scorecard goes to `docs/EVAL.md`
> (§4.3). Stack-agnostic — graders are ordinary code + judge calls. §4 Prohibitions apply.

## Two layers
- **Layer 1 — code graders** (deterministic, near-free, run every time): structural metrics over the artifact —
  *did it produce a valid result?* plus counts, sizes, schema validity, "wall-of-text" / clutter flags. They catch
  gross regressions a judge shouldn't be spent on. Ground truth is **computed from the source**, not hand-authored.
- **Layer 2 — LLM-as-judge graders** (semantic): **one call per dimension** (clarity · correctness-vs-source ·
  completeness…), scored on an explicit rubric. Steer against leniency — "use the full 0-5 range, not only 3-5";
  judge with a **different model family** to avoid self-preference; **randomize A/B order** to kill position bias.
  The judge prompt follows a fixed contract (mandatory dimensions, the graded text fenced as data, two samples per
  item, ties unscored): `references/method.md` § Judge prompt contract.

Each grader is one **scorecard column**; adding a metric = appending one grader.

## pass-slow — grade cost alongside correctness
A result is not just right/wrong. An **efficiency grader** downgrades a correct output that ran **over a
turn/token budget** to `pass-slow` — so "correct but too expensive" is visible, not hidden inside a green pass.

## The loop
1. A **fixed task set** (`tasks`), each with an input and a measurable expectation.
2. Run all graders over each task's output → a scorecard.
3. **Pin a baseline** once; every later run shows **signed deltas vs that baseline**, not vs the previous run — so
   re-running the same round shows real movement, not noise.
4. Change one thing, re-run, read the deltas. Keep what moves the number up.

## Critique the eval, not only the output
After each round, two questions about the graders themselves:
- **Which assertion passed in every arm?** It does not discriminate: the control earns it too, so it measures the
  task, not the change. Say so in the scorecard, and either sharpen it or stop counting it toward the delta.
- **What did you see happen that no grader checks?** An outcome a reader noticed and no line scores is an
  outcome the next round will not notice. Write the grader, or write down that it is unmeasured.

## Noise floor
State it. At n=20 tasks, one task ≈ 5 points — deltas smaller than that are not meaningful. If the cheapest option
already hits the ceiling, say so plainly instead of chasing a fractional gain.

## Micro-test before you commit to a wording
Changing an instruction — a skill's phrasing, a rule in the discipline, an agent's trigger — is a change to
behaviour, and the temptation is to reason about whether it reads better. Reading better and working better are
different properties. Test it cheaply first:

1. **Sample it a handful of times**, not once. Same prompt, same conditions.
2. **Against a no-guidance control** — the identical task with the instruction absent. Without the control you
   learn what the model does, not what your wording adds.
3. **Read every result by hand.** At this size there is no statistic to hide behind; a score computed over four
   runs is a number pretending to be evidence.
4. **Treat run-to-run variance as a warning, not noise to average away.** If the same arm swings across runs,
   the wording is not doing reliable work — and any delta you measure is smaller than the variance you have not
   controlled.

The failure this prevents, observed in Crewforth's own evals: a case scored 7/9 against 9/9 — the guidance apparently making
things *worse* — and an identical second round came back 9/9 to 9/9. Two checks of variance inverted the
finding. Had the first round been reported, a good rule would have been removed on noise.

Corollary: a delta smaller than the observed spread between identical runs is not a result. Say "below the
noise floor" and either raise n or accept that the change is unmeasurable at this scale — both are honest;
quoting the number is not.

The grader architecture, a starter grader catalogue, and the judge-bias checklist live in **`references/method.md`**.

## DoD
- A fixed task set + a two-layer grader; a pinned baseline; every change reported as a signed delta with the noise floor stated.
- Any wording change was micro-tested against a no-guidance control, with every run read rather than averaged.
