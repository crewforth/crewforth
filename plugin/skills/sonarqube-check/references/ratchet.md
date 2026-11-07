# A ratchet when no analysis can run

Loaded on demand from SKILL.md branch (c). It does not replace an analysis and never produces a rating: it keeps
the numbers the project CAN measure from getting worse while no server is available.

## The rule
Record today's value of each number the project measures without a server, commit it, and fail only when a change
makes it worse by more than its tolerance. Improving it moves the baseline; worsening it needs a decision.

| Number | Where it comes from | Usual tolerance |
|---|---|---|
| line coverage | the test runner's report (lcov, cobertura, coverage.xml) | 0.5 points |
| lint findings | the local rule engine (`references/local-engines.md`), by rule id | 0 new |
| bundle or binary size | the build output | 2 % |
| build warnings | the compiler | 0 new |

## The baseline file
One committed file (for example `.quality-baseline.json`) holds, per number: the value, the command that measured it,
and the commit it was measured at. A number nobody can re-measure with the command written there is not a baseline.

## Exceptions
A regression the team accepts is written into the same file with an owner and an expiry date, and the reason. An
exception past its date fails like the regression it covered. There is no exception without an owner.

## What it is worth, said out loud
"Coverage 81.2 % against a baseline of 81.0 %, 0 new lint findings: no regression. No SonarQube analysis ran; the
gate and the ratings were not produced." A ratchet that passes is not a clean analysis, and the report says so.

## At least one check from outside
A ratchet only compares the project with itself. At least one check that does not come from the project's own
tooling still runs: the CI's own build, a dependency audit, or the local rule engine, so a number that drifted in
the baseline file is not the only witness.
