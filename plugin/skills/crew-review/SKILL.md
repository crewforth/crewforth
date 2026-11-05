---
name: crew-review
description: Review pass — review + security + quality gates.
metadata:
  kind: command
---
# /crew-review
Run the change set through the review trio (read-only). **The audits go out in parallel; the reviewer closes.**
1. **At once, in ONE message** — several `Agent` calls, because none of these writes code and so there is
   nothing to serialise:
   - @agent-crew-security-expert (security-scan) — auth/IDOR/injection/secret; findings with severity.
     Each `medium`-or-higher one then goes to **crew-refuter** (@agent-crew-refuter; claim + `file:line`, one call per lens, in
     parallel) before it is reported; `findings.sh write --verified` refuses one its ledger does not back.
   - @agent-crew-performance-expert (`performance`) — hot path, query/loop, render, payload. Reports
     **candidates** (reasoned) and **findings** (measured) separately; an unmeasured claim is never a verdict.
   - @agent-crew-privacy-agent (`privacy-compliance`) — **when the diff touches personal data**: legal basis,
     minimisation, retention, transfer.
2. **Quality and dependencies**, beside the audits:
   - **sonarqube-check** as `## Stack` → `Quality analysis:` says (the DoD's quality line): `sonarqube-*` → the
     0/0/0/0 gate; `declined` → "no analysis ran — unverified" in the report; empty → ask once and write the answer.
   - **A lockfile in the diff** → **dependency-audit** on what it changed, then its record (§4.7 refuses the
     commit without one).
3. **Last, once 1-2 leave no blocker:** @agent-crew-review-agent (crew-code-review) — it starts from the
   deterministic pre-pass (`.crewforth/review-prepass.json`) and writes `.crewforth/review.json`; "does it improve overall
   code health": the plan (what changed, the risks), then findings with a severity and a category. "Clean" means
   what crew-code-review means by it: **no critical or high finding open**. A medium or low audit finding does not
   hold the reviewer back; hand it over in the reviewer's prompt and keep it in the report. A critical or high one
   stops here: report it, leave the fix to its owner, and run the reviewer on the fixed diff. It is the closing
   reviewer in every writing agent's Coordination ("at closure, report findings to crew-review-agent"), so it
   reads a diff the audits have already cleared of blockers — not the other way round.

**Which lanes, by what the diff touches.** A diff of only docs, prose, comments, translations' text or styles
(`*.md`, `*.css`, …) goes to crew-review-agent alone — unless a file in it is on a critical path (legal, privacy, terms
or consent text, a store listing: the list in `.claude/hooks/guard-agent-model.sh`), which keeps its lanes. Security runs when the diff touches input handling, auth, data
access, secrets, egress or a critical path (the list in `.claude/hooks/guard-agent-model.sh`); performance on a hot
path, a query or a migration, rendering or payload; privacy on personal data; test on new behaviour. When in doubt,
run the lane: a missed audit costs more than one more agent.

## Rounds
A **round** is one pass of the lanes above over the diff. Number them, and open each report with
`round N · new: <critical>/<high>/<medium>/<low>`. Real findings arrive early; the cost of a review sits in the late
rounds, where each fix of a minor finding opens a new minor finding.
- **After a fix, re-check only what the fix touched.** A `critical`/`high` fix, or a fix that touches a critical path,
  runs every lane again; otherwise only the lane that raised the finding re-checks, on the fix diff, and answers per
  finding: addressed / not addressed. A change to tests alone does not bring security or performance back.
- **A low finding never starts a round by itself.** Collect the lows; they go to the user once, as one list, with a
  recommended disposition each (fix now · accept · track) — never silently dropped.
- **Stop when a round adds nothing above low.** That round is the last.
- **At most 3 rounds.** If a `medium`-or-higher finding is still open after the third, stop and ask the user
  (`AskUserQuestion`): each open finding, what was tried, and the choices — one more round one model up, fix it in its
  own change, track; accept only for a `medium` (a blocker is fixed or tracked, crew-code-review § Triage).
- **A fix that adds a dependency, a column or migration, or shared infrastructure is its own change**, reviewed on its
  own, not a round of this one: it is new surface, not a fix.
- Run `/simplify` once, on the final diff, not in every round.

Each agent returns a **short summary** to the main thread; raw output goes to `docs/` if needed. Do NOT modify code;
collect findings in severity order, and leave the fix to the relevant expert.

**Every lane reports how it ended, before any finding.** One state per launched lane: `ran` · `ran-partial` (what it
did not reach) · `failed` (the error) · `timed-out` · `not-run (why)`. A lane that did not finish is **not reviewed**,
never "no findings" — an empty answer from an agent that died reads exactly like a clean one. The report opens with
the lane table, and **"clean" requires every launched lane to be `ran`**; otherwise say which part was not reviewed.
