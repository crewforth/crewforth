---
name: systematic-debugging
description: |
  Use when a bug's cause is unknown: something is broken, crashes, or fails only sometimes, or a few fixes
  have already been tried. Use before changing code to make a failure go away.
---

# Systematic Debugging

<!-- routing-eval reads the next line; why it sits in the body: AGENT_TEMPLATE.md -->
Trigger phrases: "debug", "root cause", "why is this failing", "intermittent bug", "can't reproduce", "is broken", "crashes"

One rule holds the whole skill together: **no fix without a confirmed root cause.** A patch that makes the symptom
disappear without a proven cause is not a fix — it's a coin flip that hides the bug until it returns somewhere worse.
This skill is the discipline that turns "try things until it works" into "understand, then change one thing."

> **Crewforth adaptation (local, .claude/):** Distinct from `iterate` (a self-correction loop over a *task*) and `reflect`
> (meta-review of an approach) — this skill is for a *defect*. §4 Prohibitions apply; a fix still goes through the
> project's review/test gates. Don't disable a test or a gate to make a symptom pass (that is masking, not fixing).

## The loop (do them in order — skipping a step is why bugs come back)
0. **Settle intent** — is the expected behaviour written down? Check the ADRs, the README and the tests: *documented*
   (it is a bug, go on), *contradicted* (it was never meant to work this way: a feature request, back to
   **crew-planner**), or *silent* (ask the user with AskUserQuestion before changing anything).
1. **Reproduce** — a reliable, minimal repro. Can't reproduce → that IS the first problem; see `references/techniques.md` (intermittent/heisenbug).
2. **Isolate** — shrink the surface until the failure is in the smallest possible slice (bisect commits, halve the input, disable half the system).
3. **Hypothesize** — state ONE falsifiable cause: "X fails because Y." Write it down. A vague hunch is not a hypothesis. (`hooks/loop-guard.sh` points back here when a turn repeats one failure.)
4. **Test the hypothesis** — the cheapest observation that would *disprove* it (a log, a breakpoint, a probe). If it survives, you have the cause; if not, back to 3.
5. **Confirm the root cause** — you can explain the full chain symptom←…←cause, and you can turn the bug on and off by touching the cause.
6. **Fix** — the smallest change at the cause (not the symptom). Consider what else shares that cause: grep every
   caller of the function you fix, and fix it once in the shared code rather than at each caller.
7. **Verify** — the original repro now passes, a regression test locks it, and nothing nearby broke. The regression
   test is shown **failing with the fix reverted and passing with it**: one that is green on both sides proves
   nothing. Reproduce through the entry point the bug came in by (the CLI, the handler, the parser's real output),
   not by handing a function a value its callers never produce.

## Checklist
- [ ] Reliable repro captured (exact steps/input/env)
- [ ] Failure isolated to the smallest slice
- [ ] One falsifiable hypothesis written down
- [ ] Hypothesis tested by observation (not by applying a fix and seeing)
- [ ] Root cause confirmed (can toggle the bug via the cause; full chain explained)
- [ ] Fix at the cause + regression test added, seen red without the fix and green with it
- [ ] Original repro passes; no new failures

## Anti-patterns (each is guess-driven patching wearing a disguise)
- **Shotgun debugging** — changing several things at once; now you can't tell what mattered. One change at a time.
- **Symptom patching** — a `try/catch`, a null-guard, a retry that swallows the failure without explaining it.
- **"It works now"** without knowing *why* it broke — the bug is dormant, not dead.
- **Blaming the environment/flake** before isolating — sometimes true, but only *after* step 2, never as the first move.
- **Deleting/skipping the failing test** to go green — that is masking; the gate exists to catch exactly this.

---

## Techniques by symptom
Bisecting (git + input + system), instrumentation vs. debugger, intermittent/heisenbugs (timing, state, ordering,
resource), the hypothesis log, and when to stop and ask for a second pair of eyes: **`references/techniques.md`**.

## Invariant rules
1. **No fix without a confirmed root cause** — the one rule; everything else serves it.
2. **One change at a time** — isolate cause and effect; never shotgun.
3. **Fix the cause, not the symptom** — a guard that hides the failure is not a fix.
4. **Lock it with a regression test** — the repro becomes a test so it can't silently return, and it was seen failing
   with the fix reverted.
5. **Never mask to go green** — don't disable a test/gate/assertion to make the symptom pass.
