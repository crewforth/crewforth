---
name: ci-pipeline
description: |
  CI pipeline discipline: lint→build→test→quality→security, fail-fast, deterministic build, secret handling, PR gates.
---

# CI Pipeline

<!-- routing-eval reads the next line; why it sits in the body: AGENT_TEMPLATE.md -->
Trigger phrases: "ci", "pipeline", "github actions", "jenkins", "build pipeline", "pr gate", "pr check", "build fail", "build broke", "ci is failing", "workflow"

## Stages (fail-fast — stop if it breaks early)
1. **Lint / format** — style and static analysis
2. **Build** — 0 warnings / 0 errors
3. **Test** — unit + integration, coverage collected
4. **Quality** — `sonarqube-check` quality gate
5. **Security** — `dependency-audit` + `security-scan` (where applicable)
6. **Artifact / packaging** — (deployment is separate, `deploy`)

## Principles
- **Deterministic:** dependencies pinned, cache keyed correctly; no "it worked on my machine".
- **Actions and the token:** pin every third-party action to a full commit SHA with its version in a comment (a tag
  moves when its owner moves it); `permissions: contents: read` at the top, raised per job only where a step writes;
  `persist-credentials: false` on checkout unless a later step pushes; never put `${{ github.event.* }}` or a matrix
  value inside `run:` — pass it through `env:` and quote it.
- **Secret management:** CI secret store; NO plaintext secrets in the repo/logs (overlaps with trace scan). Log
  masking is a filter on exact strings: an encoded, split or transformed value prints in clear, so a secret never
  reaches a step that echoes its environment. Prefer short-lived OIDC credentials over stored keys and ephemeral
  runners over reused ones; a cache restored into a job is input, so key it on what produced it and never on a
  value a fork controls.
- **PR gate:** quality gate + tests must pass; a red build is not merged.
- **Branch protection:** direct push to main is disabled; PR + review required.

## When a stage fails
1. **Fetch the failing job's log first** — `gh run view --log-failed`, `glab ci trace`, `jenkins-cli console <job>`,
   whichever this project's host provides — and quote the failing lines: a status icon names which job broke, never why.
   Log unreachable (no access, retention expired, the job never started) → report exactly that; never infer the cause.
2. **Reproduce with the exact command the pipeline runs**, copied out of the CI config — same flags, same env, same
   versions. Green locally is not a pass: the environment difference is now the defect, so take it to `systematic-debugging`.
3. **A re-run is not a fix.** Re-running until it passes hides the cause; re-run only to establish that a failure is
   intermittent — and an intermittent failure in this repo's own suite is a bug (`testing`), not a retry.
4. **Say which failures aren't yours.** A required check owned by another change, or an external service that was
   down, is reported out of scope with the job named — silence about it reads as a clean run.

## DoD
- All stages green; PR gates enforced; no secret leakage; build reproducible.
