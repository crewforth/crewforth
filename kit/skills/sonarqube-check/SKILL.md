---
name: sonarqube-check
description: |
  SonarQube quality gate, any language, no company server needed: run SonarQube Community Build locally (Docker),
  read the real gate + issues, fix by rule id, re-scan and diff. A linter's green build is a pre-check, never the gate.
---

# SonarQube quality gate — produce the real report, locally

<!-- routing-eval reads the next line; why it sits in the body: AGENT_TEMPLATE.md -->
Trigger phrases: "sonarqube", "quality gate", "code smell", "sonar scan", "sonar rapor", "A rating"

**Only a SonarQube analysis can say "rating A, 0 findings".** A clean `build` says the compiler was happy — a
different claim, about a different rule set. Passing one off as the other is how a team is told the code is clean
and then opens a report full of findings.

You do **not** need a company server or someone else's token to get the real thing: **SonarQube Community Build is
free, needs no licence key, and runs in one Docker container on this machine.** That is the default path here — the
gate is produced locally, offline, and it is a genuine SonarQube verdict, not a proxy for one.

Language-agnostic on purpose: SonarQube covers 20+ languages plus IaC (Terraform, Kubernetes, Dockerfile). Detect
what the project actually uses; never assume a stack.

## Step 1 — get a real analysis (pick the first that applies)

**a) The project already has a SonarQube** → use it, and skip to step 2.

**b) It does not → stand one up locally.** Docker one-liner, the Docker-free server zip, the first login and the
token: **`references/stand-up-server.md`**. No licence, no external account, nothing leaves the machine.

> **Restarting is not installing.** Bringing an already-approved service back up on this machine — the same
> image, the same volumes — is resuming what the user already said yes to, and this skill's own advice to keep
> a named volume assumes exactly that. A NEW image, a new volume, or a tool this machine does not have is an
> install, and needs the answer below.
>
> **Nothing here is installed without the user saying so.** Docker, Java, a scanner, a linter — each is a proposal
> with its cost stated, and the user picks. If they decline all of them, that is a valid answer: go to (c) and
> report "unverified" rather than installing anything to make a number appear.

Scan with whatever runner the project's stack uses — the scanner is the same product for every language:

| Project | Scan command |
|---|---|
| Any stack (generic) | `sonar-scanner -Dsonar.projectKey=app -Dsonar.sources=. -Dsonar.host.url=http://localhost:9000 -Dsonar.token=$T` |
| Maven / Gradle | `mvn sonar:sonar -Dsonar.host.url=… -Dsonar.token=$T` · `gradle sonarqube …` |
| .NET | `dotnet sonarscanner begin /k:app /d:sonar.host.url=… /d:sonar.token=$T` → `dotnet build` → `dotnet sonarscanner end /d:sonar.token=$T` |
| JS/TS, Python, Go, PHP, Ruby | the generic `sonar-scanner` above, with the coverage report below |

**Coverage first: SonarQube runs no tests, it reads a report.** Produce one before the scan and pass its path, or
the analysis counts every line uncovered and prints 0.0%:

| Stack | Produce | Pass to the scanner |
|---|---|---|
| Python | `pytest --cov=<package> --cov-report=xml` (needs `pytest-cov`) | `-Dsonar.python.coverage.reportPaths=coverage.xml` |
| JS/TS | `vitest run --coverage --coverage.reporter=lcov` · `jest --coverage` | `-Dsonar.javascript.lcov.reportPaths=coverage/lcov.info` |
| .NET | coverlet, OpenCover format | `/d:sonar.cs.opencover.reportsPaths=…` (*reports*, with an s) |
| Java | JaCoCo XML report | `-Dsonar.coverage.jacoco.xmlReportPaths=…` |
| Go | `go test -coverprofile=coverage.out ./...` | `-Dsonar.go.coverage.reportPaths=coverage.out` |

**No report, no coverage figure.** When none was produced (or `lines_to_cover` equals `uncovered_lines`), write
*"coverage: not measured — no report was passed to the analysis"*, never "0%": a 0 there says the tests were not
read, not that there are none. Installing the coverage plugin is a proposal like any other tool.

**c) No server is possible at all** (no Docker, no Java, no permission to run one) → run the language's Sonar-rule
engine locally as a pre-check (**`references/local-engines.md`** — which engine per language, and how close it is
to Sonar's own rules) and **say what that is worth**, in these words rather than a
rating: *"the local rule engine reports N issues, none open; the SonarQube rating and the gate were not produced —
no analysis ran."* Then list what stays unverified: taint/injection, hotspot review state, coverage, duplication,
files outside the compiled language, and the project's own quality profile. Offer branch (b) — a local server, with
or without Docker — as the way to close it.

**Never invent the verdict.** A rating exists only where an analysis produced one; without it the honest output is
"unverified", and that is the sentence that saves the user from promising a clean report they cannot back.

## Step 2 — read the verdict, don't infer it

```bash
S=http://localhost:9000; K=app          # or the project's own host/key
curl -sfu "$T:" "$S/api/qualitygates/project_status?projectKey=$K"     # pass / fail, and which condition failed
curl -sfu "$T:" "$S/api/issues/search?componentKeys=$K&resolved=false&ps=500"   # rule id + file + line per finding
curl -sfu "$T:" "$S/api/hotspots/search?projectKey=$K&status=TO_REVIEW"          # hotspots are a SEPARATE endpoint
curl -sfu "$T:" "$S/api/measures/component?component=$K&metricKeys=alert_status,bugs,vulnerabilities,security_hotspots,code_smells,coverage,duplicated_lines_density,reliability_rating,security_rating,sqale_rating"
```

Also read the gate's definition (`/api/qualitygates/show`): most gates judge **new code**, not the whole project.
Chasing overall counts while the gate measures new code burns days and still fails; the reverse leaves real debt.
Know which one applies before planning the work.

**An empty new-code period makes "Passed" mean nothing.** On a first analysis, or under `PREVIOUS_VERSION` while
the version has not changed, `project_status` returns `"period": null` and every `new_*` condition comes back
`actualValue: null`, `status: OK` — the gate passes because there is no new code to judge, while the project may
carry an E rating. When that is what you read:
- report the **overall** ratings and counts (the `measures` call above) as the verdict, and say the gate had no new
  code to evaluate — never "the gate passed";
- propose a baseline so the next analysis has new code to judge: `curl -sfu "$T:" -X POST
  "$S/api/new_code_periods/set?project=$K&type=NUMBER_OF_DAYS&value=30"` (or `REFERENCE_BRANCH` with the main branch).
  It changes the project's settings, so it is the user's yes, like any other change.

## Step 3 — fix by rule, never by impression

Group findings by `rule` (`csharpsquid:S1481`, `typescript:S3776`, `python:S5852`, …) and take one rule at a time,
all occurrences together. Read what the rule actually asks, fix the cause, cite the rule id in the change. The
domain owner does the fixing — a security rule is `crew-security-expert`'s, a query/index rule is
`crew-database-expert`'s.

**Never close a finding by silencing it.** `#pragma warning disable`, `// NOSONAR`, `eslint-disable`, an exclusion in
`sonar-project.properties` — each one changes the report without changing the code. It needs a written reason and
the user's approval, every time.

**Security Hotspots do not close by editing code.** Each is reviewed in the UI and marked *safe* (with a rationale)
or *fixed*. Code changes alone leave it `TO_REVIEW` and the gate keeps failing.

## Step 4 — re-scan and diff. The loop is the deliverable

Re-run step 1's scan, re-read step 2, and report the **difference**: counts before → after, which rule ids
disappeared, which remain, which are new. "It should be clean now" is not a result — a second analysis is.
Repeat until the gate says `OK`, or every remaining finding has a user-approved suppression. Nothing here closes on a first pass.

## What even a local SonarQube cannot see

Community Build has no **taint/injection analysis** (data flow from user input to a dangerous sink — SQLi, XSS,
command injection); that engine is in the paid editions. It also has no branch/PR analysis. So a clean local gate
is not proof of injection safety: cover that with the **`security-scan`** and **`threat-model`** skills plus a
`crew-security-expert` review, and say which of the two verdicts you are reporting.

## DoD
- The verdict is quoted **from an analysis**: gate status, counts by severity, ratings, analysis date, and where it
  ran (project server or local container).
- Every finding closed by a code change, or by a suppression the user explicitly approved with a written reason.
- Hotspots reviewed in the UI, not merely edited around.
- A re-scan ran after the fixes and the before → after diff by rule id is reported.
- Injection risk stated separately (taint analysis is not in Community Build).
- Coverage is a measured figure from a report passed to the analysis, or written "not measured" — never a bare 0%.
- A gate read with `"period": null` is reported by its overall ratings, not as "passed".
- The project's `## Stack` → `Quality analysis:` line says which path ran (`sonarqube-local`, `sonarqube-server`,
  or `declined`); an empty one is asked once and written there.
- Anything not done is said plainly — never implied clean.
