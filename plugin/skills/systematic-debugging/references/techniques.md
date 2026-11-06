# Debugging techniques by symptom

Loaded on demand — the SKILL.md loop is the method; this is the toolbox for a specific kind of bug.

## Isolation: how to shrink the surface (step 2)

- **git bisect** — a regression that "used to work". `git bisect start; git bisect bad; git bisect good <rev>` then let it binary-search the commit that introduced it. Automate with `git bisect run <cmd>` where `<cmd>` exits 0 on good, non-zero on bad.
- **Binary-search the input** — halve the failing input until the smallest reproducing case remains. A 10k-row file that fails narrows to the one row; a 500-line config to the one key.
- **Halve the system** — disable half the middleware / feature flags / plugins. Failure gone → it's in the disabled half. Repeat.
- **Minimal repro** — rebuild the failure in isolation (a scratch script, a single failing unit test). If it won't reproduce in isolation, the cause is in the *environment/state* you left out — that's a finding, not a dead end.

## Instrumentation vs. debugger

- **Logging/print** — best for intermittent, timing, production, and "can't attach" cases; leaves a trace across runs. Log the *hypothesis-relevant* value, not everything. Remove or gate the probes before committing.
- **Debugger/breakpoint** — best for a reliable, local repro where you want to inspect live state and step. Conditional breakpoints (`x == badValue`) skip the noise.
- **Assertions/invariants** — add a check that *should* always hold; the point it fires is upstream of the symptom.
- **Bisect on values** — binary-search *when* a value goes wrong: log at start/middle/end of the pipeline, then narrow.
- **Boundary logging** — when a value crosses several layers (config → loader → service → handler), log what enters and what leaves each layer, run once, and read where the value first differs from what was sent. The layer where it changes owns the bug.

## Intermittent / heisenbugs (can't reliably reproduce)

The cause is almost always one of:
- **Timing / races** — order of concurrent operations; add delays/logging to widen the window and expose it. A bug that vanishes when you add a log is a timing bug (the log changed the timing).
- **Shared/leaked state** — a previous test/run left state behind; run the case in full isolation and in a different order (`--shuffle`).
- **Ordering dependence** — passes alone, fails in the suite → cross-test coupling. Bisect the test order.
- **Resource / environment** — memory pressure, disk, clock, locale, network flake, an unpinned dependency version. Pin and compare.
- **Uninitialized / nondeterministic** — reads of uninitialized memory, map iteration order, unseeded randomness, `Date.now()`.

Make it reproducible *first* (loop the case 100×, add stress, shuffle). An intermittent bug you can't trigger on demand can't be confirmed fixed.

## The hypothesis log

For a bug that resists a few rounds, write it down — it stops you from re-testing the same dead hypothesis and reveals patterns:

```
Symptom: <exact observable failure>
Repro:   <steps / input / env>
H1: <cause> → test: <observation> → RESULT: disproved (saw X, not Y)
H2: <cause> → test: <observation> → RESULT: CONFIRMED (toggles bug)
Root cause: <the confirmed chain>  Fix: <change at cause>  Test: <regression test>
```

## When to stop and get a second pair of eyes

**Three fixes that each moved the failure somewhere else** is a different stop: the defect is in the design, not in
any one line. Stop patching and put the design question to the user with AskUserQuestion, with the log of the three
fixes and where each one moved the failure.

After ~3 disproved hypotheses with no new information, or when you've been staring at the same 20 lines — you likely hold a wrong assumption you can't see. Escalate: hand over the hypothesis log (not "it's broken") so the next person starts from what's *already ruled out*, not from zero. In Crewforth, that handover is the `handoff` skill.
