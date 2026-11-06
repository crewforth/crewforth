---
name: iterate
description: |
  Refine-to-Done loop: repeat until tests green + review clean + nothing deferred; bounded. Not the harness /loop.
---

# Iterate — refine to Done, don't stop at the first attempt

<!-- routing-eval reads the next line; why it sits in the body: AGENT_TEMPLATE.md -->
Trigger phrases: "iterate", "loop until done", "keep going until"

## When
A task has an objective acceptance criterion (tests, a review gate, a spec) and the first attempt may not
meet it. This is a single-session refinement loop — NOT the harness `/loop`, which schedules a prompt on an
interval. Open-ended exploration with no checkable target does not belong here.

## The loop
1. **Name the exit test first** — the concrete, checkable condition that means "done": tests green,
   `crew-review-agent` clean, the spec's acceptance criterion met, zero SonarQube findings. No exit test →
   go to spec-planning first; a loop without a target never terminates.
   **Prefer an external, machine-grounded verifier** — a test exit code, a schema match, a lint/quality gate —
   over an LLM's self-assessment. A model grading its own output inflates; an "it looks done" or even a single
   "review clean" with no objective check is a weak verifier. When the only available check is a judgment call,
   ground it (a second agent with a distinct lens, an explicit rubric) rather than trusting the loop's own say-so.
   For a generative task with no exit code, the `eval-grader` skill *is* that external verifier — a two-layer
   scorecard (code metrics + LLM-judge) over a fixed set, read as signed deltas vs a pinned baseline.
2. **Run one round**: change → verify (drive the real flow, not only tests) → check the exit test. With several
   tasks, build **one slice at a time**: each slice compiles and passes its tests before the next one starts, so a
   failure points at one slice. Something wrong you notice outside the task goes on a "noticed, not touching" list
   in the final report, not into the diff.
3. **Report the gap** every round — state what still fails and why. Never loop silently.
4. **Repeat** until the exit test passes. Stop early and surface it if: two rounds pass with no new
   progress (you are stuck — report, don't spin), the exit test itself is wrong, or a blocker needs a
   decision from the user. **When the exit test is a review**, round 2 and later review only what changed since
   the last round, a finding already disposed of is not raised again unless the change touches it, and after 3
   review rounds you stop and report (`/crew-review` § Rounds).
5. **Close at the DoD gate, not at a commit.** `crew-commit-agent` still proposes and waits for §4.4
   approval. The loop never commits, pushes, or deploys on its own.

## Guardrails
- **Bounded, not infinite.** A fixed exit test plus a no-progress stop is the whole point; "keep trying
  forever" is a bug, not diligence.
- **Token discipline** ([[token-budget]]): each round re-pays for context. Keep a round's output a summary,
  push heavy logs to `docs/*.md`, and don't fan out a subagent per round unless isolation demands it.
- **Don't move the goalposts.** Never weaken the exit test to end the loop — fix the work, or stop and ask.
