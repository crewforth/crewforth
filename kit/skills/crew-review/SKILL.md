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

Each agent returns a **short summary** to the main thread; raw output goes to `docs/` if needed. Do NOT modify code;
collect findings in severity order, and leave the fix to the relevant expert.
