---
name: crew-audit
description: Audit the whole project, not a diff — start from the Crew Map, go deep where a mistake costs most, and say what was not read.
disable-model-invocation: true
metadata:
  kind: command
---
# /crew-audit

A review checks a change; this checks what is already there. **Read-only:** no file outside `.crewforth/` changes,
nothing is committed, and every fix goes to its owner afterwards. An audit that says what it did not read is worth
more than one that sounds complete.

1. **The map.** Resolve `MAP` exactly as `/crew-map` step 1 does. No `.crewforth/crew-map.json` → run the scanner
   yourself (`bash MAP`, /crew-map step 2; `/crew-map` is the user's to type) and say the map has no descriptions
   yet, because without the map this is a guess at where the risk is. Then `bash MAP --check`
   (Bash tool, not PowerShell): rc 0 → the map matches the tree; rc 1 → say "the map differs from the tree" in the
   report and treat its module facts as leads, not facts; rc 3 → say the check did not run.

2. **Choose where to go deep.** Read the map's `overview`, its `tour` and each module's `entryPoint` first. Then
   rank the modules by what a mistake there costs, highest first:
   - money: payments, billing, prices, refunds;
   - access: authentication, sessions, permissions, tenancy;
   - data writes: persistence, migrations, deletes, imports, anything that changes stored data;
   - secrets and egress: keys, tokens, outbound calls, webhooks;
   - then entry points and everything a user's input reaches.
   Between two of equal cost, go first where the map says more happened: a higher `commits` count, and `markers`
   (the code's own WHY/HACK/FIXME lines) point at a debt someone already admitted.
   Take at most **8 modules** for the deep pass and list the rest by name. Say which rank put each one in.

3. **Read deep modules whole.** A Read returns at most 2000 lines and does not say it stopped: page a longer file
   with offset/limit to its last line, and note the line count you read. A file you did not finish is not read.

4. **Run the lenses, in ONE message** (several `Agent` calls; nothing here writes code). Each lane gets the module
   list and its files, never "the whole repo":
   - @agent-crew-security-expert (`security-scan`): access, input handling, data writes, secrets, egress.
   - @agent-crew-review-agent (`crew-code-review`): bugs and maintainability in the deep modules, in its severity
     table and finding format.
   - @agent-crew-performance-expert (`performance`): only where the map shows a hot path, a query or a job.
   - @agent-crew-privacy-agent (`privacy-compliance`): only where a deep module holds personal data.
   Every lane reports how it ended before any finding: `ran` · `ran-partial` (what it did not reach) · `failed` ·
   `timed-out` · `not-run (why)`, as in `/crew-review`. A lane that did not finish is **not audited**, never clean.

5. **Hold every finding to a case.** Each one names a concrete input or state and the wrong result it leads to;
   without that it is a note, not a finding. Code called unused is checked first for dynamic references (a name
   in a string, a route or config table, reflection, a plugin registry); the grep you ran goes in the finding.
   **Verification comes before breadth.** Send a `critical` or `high` candidate to crew-refuter as soon as a lane
   returns it, before any further reading; when the run may not cover both, read fewer modules rather than skip
   the check, and list the modules left out under coverage. A finding the refuter did not see is reported as
   **not verified**, never as a finding.
   Each `medium`-or-higher finding goes to **crew-refuter** (@agent-crew-refuter; claim + `file:line`, one call per
   lens, in parallel) before it is reported. Store them with
   `bash <findings dir>/findings.sh write --verified audit <file>` (`eval/lib/findings/` in either edition): rule
   `audit-<category>`, the `crewforth.findings/1` shape `crew-code-review` uses.

6. **Report**, in this order:
   - the map line (step 1) and the lane table (step 4);
   - **at most 20 findings**, most severe first, in `crew-code-review`'s format; then "N more not shown" with
     their count per severity;
   - **coverage**: the modules read deep, the ones only skimmed, and the ones not read, each with the reason.
     "Not read" is never "no findings".

   End by offering `/crew-plan` on the blockers. Fixing them is a separate change, reviewed on its own.
