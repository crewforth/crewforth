---
name: testing
description: |
  The how of testing: pyramid, AAA, isolation, risk coverage, determinism. Guarantees the DoD's "tests are
  green". crew-test-expert applies it.
  Use when writing or changing tests, or when a suite is flaky, slow or green for the wrong reason.
---

# Testing Discipline

<!-- routing-eval reads the next line; why it sits in the body: AGENT_TEMPLATE.md -->
Trigger phrases: "write a test", "run the tests", "coverage", "are the tests green", "unit test", "integration test", "tests pass locally", "flaky test", "test is flaky"

Goal: **behavior correctness** — test real behavior without breaking product code just to make a test pass.

## Principles
- **Pyramid:** many unit, fewer integration, few end-to-end (e2e). Limit e2e to critical flows.
- **AAA:** Arrange-Act-Assert; **one test = one behavior**.
- **Isolation & determinism:** external dependencies are mocked/faked; time and randomness are fixed; test order is independent.
- **Risk-coverage:** risk, not metrics. Critical path + **boundary** + **negative** + **authorization (IDOR/404)** scenarios.
- **Naming:** `what_it_tests_under_which_condition_what_it_expects` — on failure it is clear what broke.
- **Red-green:** first a failing test, then the implementation.

## Watch out
- **Flaky = bug:** an occasionally failing test is not tolerated; it is fixed at the root.
- In snapshot/golden-file tests, avoid needless brittleness (assert only the meaningful output).

## Tests that cannot fail

Green is evidence only if the test could have gone red. Shapes that check nothing:
- **Assertion restates the code:** it recomputes the implementation's own expression, so it moves with every change.
- **Setup guarantees the result:** arrange plants the value the assert reads back; it holds even if the act never ran.
- **Expected value derived the way the code derives it:** same formula, query or parser — the same wrong assumption on
  both sides still matches.
- **A double asserted against its own stub:** the fake is told to return X and the test asserts X; only the fake runs.
- **No assertion:** it passes because nothing threw. If *not throwing* is the behavior under test, assert that.
- **Synthetic input:** the test hands the function a value its real callers never produce, so it passes on a path the
  bug never takes. Reproduce through the entry point the bug came in by (the CLI, the handler, the parser's output).

**Prove it can fail:** break what the test covers — invert a condition, return a wrong constant — confirm it goes red,
then restore. Still green means the test is documentation, not a gate: fix it or delete it, never count it as coverage.
For a bug fix the same proof is the fix itself: the new test fails with the fix reverted and passes with it.
- Before writing a test, name the production change that would make it fail. If only a deliberate edit of the test's
  own expectation can fail it, it is a change detector, not a test.
- A fake mirrors the real thing's whole shape (fields, errors, ordering), not only the part this test reads.
- Cleanup and setup used only by tests live in test helpers, not as test-only branches in production code.

## Flaky triage
An intermittent failure gets exactly one outcome, decided the day it is seen: **fix** it, **quarantine** it (out of
the gating lane, never out of the suite, with an owner and a date), or **escalate** it as the product defect it
signals. Infrastructure flakes may get a bounded, logged retry; product flakes never do. Classifying them, the retry
rule, and what a quarantine entry must carry: **`references/flaky-triage.md`**.

## DoD (this skill's contribution)
- The project's own test command is green — read it off the manifest/CI (`dotnet test` · `npm test` · `pytest` ·
  `go test ./...`), don't assume one; critical paths are covered; no empty/meaningless tests.
