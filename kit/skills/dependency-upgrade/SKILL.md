---
name: dependency-upgrade
description: |
  Bring dependencies current without breaking the build: find what is vulnerable, deprecated or behind,
  classify each target version by risk, apply what is safe, verify, and roll back what is not.
---

# Dependency Upgrade

<!-- routing-eval reads the next line; why it sits in the body: AGENT_TEMPLATE.md -->
Trigger phrases: "upgrade dependencies", "outdated packages", "bump versions", "update packages", "keep dependencies current", "dependabot PRs", "renovate PRs"

## When
Staying on current versions as an ongoing practice, or reacting to a CVE. [[dependency-audit]] tells you what is
wrong; this decides what to do about it and does it. It **mutates the manifest and the lockfile**, so it carries
the same shape as [[db-migration]]: detect the tool, classify by risk, gate the dangerous class behind approval,
apply, verify, roll back on red.

## 1 — Ask the three separate questions
They are three different problems with three different answers, and the tooling keeps them separate too.

| Question | Node | .NET | Python |
|---|---|---|---|
| What has a **known CVE**? | `npm audit --json` | `dotnet list package --vulnerable` | `pip-audit` |
| What is **deprecated**? | `npm view <pkg> deprecated` | `dotnet list package --deprecated` | registry / project notes |
| What is simply **behind**? | `npm outdated --json` | `dotnet list package --outdated` | `pip list --outdated` |

> The three `dotnet list package` flags **cannot be combined** — it is three separate runs, not one.

**A failed lookup answers nothing.** A registry or CLI error (404, 403, a timeout, no credentials) is reported as
`could not check` for that package, never as "not deprecated" or "up to date".

**Deprecated is not an upgrade.** No version bump fixes it; the package needs a replacement, which is a design
change with its own review — never fold it into a routine bump.

## 2 — Classify every target version before touching anything
The risk is not "how old is it", it is "how far does the jump go".

| Class | Rule | Approval |
|---|---|---|
| **Security patch** | fixes a known CVE, within the current major | Do it first, on its own commit — it is the one upgrade whose delay has a cost |
| **Patch** (`x.y.Z`) | bugfix only | Apply, batched |
| **Minor** (`x.Y.z`) | additive, backward compatible **by promise** | Apply, batched, only if the suite is green afterwards |
| **Major** (`X.y.z`) | breaking by definition | **Never automatic.** Read the changelog/migration guide, one package per commit, and say what breaks |
| **Pinned / transitive-only** | pinned deliberately, or not a direct dependency | Leave it. Find out *why* it is pinned before unpinning |

Semver is a promise, not a guarantee: a minor that breaks you is a bug in the package, and your suite is the
only thing that will tell you. That is why the verify step below is not optional.

## 3 — Apply
- **Group by class, one commit per group** — a patch batch and a major are not the same change and must not
  share a commit. A single commit mixing forty bumps is unreviewable and unrevertable.
- **Preview first.** `npm audit fix --dry-run` before `npm audit fix`. Never reach for `npm audit fix --force`
  without saying so out loud: it installs **semver-major** upgrades, which is precisely how this task breaks a
  build while claiming to be a security fix.
- **The lockfile is part of the change.** Commit it with the manifest; a manifest bump without its lockfile is
  a change nobody else reproduces ([[dependency-audit]] axis 5).
- Never hand-edit a lockfile. Let the tool regenerate it.
- **A new or unfamiliar package is installed with its scripts off first** (`npm install --ignore-scripts`, the
  ecosystem's equivalent), so its install-time code does not run before [[dependency-audit]] axis 7 has looked at it.

## 4 — Verify, then decide
Nothing counts as upgraded until it is observed working — install, build, full test suite, and the project's
quality gate. Run the app's real entry path if the change touches runtime, not just unit tests ([[testing]]).

- Green → keep it.
- Red → **roll back this group** (`git checkout -- <manifest> <lockfile>` then reinstall), then either pin, split
  the batch to find the culprit, or move that package to its own major-upgrade task. Do not "fix forward" a
  routine bump; that turns maintenance into an unplanned feature.
- Re-run [[dependency-audit]] afterwards: an upgrade can introduce a new transitive CVE.

## 5 — Continuous, without an autonomous loop
"Always current" is a **cadence**, not an agent that runs by itself — Crewforth has no timed or self-triggering
loops, because every mutation here needs an approval a loop cannot give. Continuity comes from somewhere that
already has a human gate at the end:
- A scheduled CI job running the step-1 commands and failing on HIGH/CRITICAL ([[ci-pipeline]]).
- Or a bot (Renovate / Dependabot) opening one PR per group — Crewforth does not reimplement it; the value added
  is the policy above deciding which PRs merge on green and which need a human to read a changelog.
- Either way the PR passes through the ordinary gates: build, tests, [[security-scan]], review, approval.

## 6 — Landing bot PRs
When the work is a stack of Renovate or Dependabot PRs, sort them before touching any:

| Bucket | What it means | What happens |
|---|---|---|
| green | every check passes, patch or minor | merged on the user's word, as one group |
| mechanical | red for a reason the bump explains (a renamed import, a snapshot) | the fix is in the bump's own files |
| needs diagnosis | red, and the cause is not obvious | its own task; read the changelog first |
| conflicting | does not merge with the base | see the rebase rule below |
| superseded | a newer PR bumps the same package | closed, with the newer one named |

- One AskUserQuestion per bucket, listing its PRs: that answer is the plan approval. A merge still needs the user's
  "merge" (§4.4); the bucket question does not give it.
- A major, and a minor of a `0.x` package, is its own PR and its own decision, never part of a bucket.
- **Pre-existing** means the same check fails on the base branch's head too: say so and do not fix it inside a bump.
- A failure that looks flaky is re-run once; failing again, it goes to needs diagnosis. Unrelated code is never
  patched to make a bump green.
- A bot branch nobody else has pushed to: ask the bot to rebase (its own command). One with our commits on it:
  `git rebase` plus `git push --force-with-lease`, both gated (§4.5), then compare `git diff --stat` with the
  bot's original so nothing was lost.
- The report is three lines: merged, waiting on the user, and left with the reason.

## DoD
- Vulnerable, deprecated and outdated were asked as three separate questions, with the command output shown.
- Every applied upgrade is classed patch / minor / major, and no major went in automatically or unexplained.
- Security fixes landed first and separately.
- Manifest and lockfile moved together; no lockfile was hand-edited.
- Build + full suite were observed green after the change, or the group was rolled back and named.
- Deprecated packages are reported as replacement work, not silently bumped.
- A lookup that failed is reported as `could not check`, never as a clean answer.
