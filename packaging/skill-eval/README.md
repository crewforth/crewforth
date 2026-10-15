# Skill selection eval

Does Claude pick a skill from its description? `routing-eval.sh` cannot say: it matches trigger phrases, the way the
routing hook does. This runs the real thing, `claude plugin eval`, on the plugin edition, and holds a changed
description to what it measured.

| | |
|---|---|
| `node packaging/skill-eval/run.mjs` | measure the skills whose description changed against `origin/next` (**spends tokens**) |
| `node packaging/skill-eval/run.mjs --skill NAME --dry-run` | write the cases and print the command, call no model |
| `node packaging/skill-eval/run.mjs --baseline` | measure, and raise each case's floor to its worst run (never lowers it) |
| `node packaging/skill-eval/check.mjs` | the gate (`verify.sh skilleval`): free, reads `results.tsv` |
| `node packaging/skill-eval/selftest.mjs` | the gate's own cases, in a repository it builds |

**The cases** are the rows of the two routing sets whose target is the skill: a positive row must invoke it, a `!`
row must not. `kit/eval/golden-holdout.txt` was written without reading the triggers, so it is the honest measure of
a description reaching a request; the working set's negatives ask whether a widened description now takes a
neighbour's work. A skill that no row reaches cannot be measured, and the gate says to add a held-out row. A command
(`metadata.kind: command`) is called by name and is not held.

**Fixed:** Sonnet, three runs a case, a $5 ceiling per run (`--max-cost-usd`: what had not run by then is not
measured), and `--no-publish` (the tool's default is to publish the report to claude.ai). The plugin under test is a
copy of `plugin/` with the cases added, hooks on: what is measured is what a user gets.

**What it cost, measured:** one run of the six `adr` cases on Sonnet, $0.43 at list price, about $0.07 a case. The
baseline (`--all --source holdout --baseline`: the 18 held-out cases, three runs each) cost $3.75.

**The baseline, measured:** 16 of the 18 held-out cases picked their skill in all three runs. `api-design` ("this
endpoint returns different shapes depending on the caller") and `incident-runbook` ("we keep discovering the same
outage twice a month") were picked in none, with no run ending in an error: their floor is 0.000 until a description
reaches them.

**The grader, calibrated:** one run of a case whose prompt picks `adr` every time, with three graders: `adr` invoked
(passed, 1x), `adr` must not be invoked (failed, 1x), and `deploy` invoked (failed, 0x). Score 1/3, as predicted, so
a wrong skill and an unwanted one are both caught.
