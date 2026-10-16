---
name: crew-code-review
description: |
  Code review discipline: review only what changed, rank each finding by severity and category, and
  fact-check it first. crew-review-agent applies it.
  Use when reviewing a change set, and when acting on a review someone else wrote.
---

# Code Review

<!-- routing-eval reads the next line; why it sits in the body: AGENT_TEMPLATE.md -->
Trigger phrases: "code-review", "review the code", "review the PR", "review my changes", "do a review"

> **Crewforth adaptation (local, .claude/):** applied by `crew-review-agent` (read-only). §4 applies, and no
> vendor or template name reaches an artifact (§4.2).

A review runs in four steps — **group, plan, review, fact-check** — and reports few findings that are right rather
than many that might be. Every step below says what it produces.

## 0. The pre-pass first, and the findings in one shape
Before reading the diff, run the deterministic pre-pass (`eval/lib/review-prepass/` in either edition):
`bash <dir>/prepass.sh` for the staged change, `--base <ref>` for a branch. It writes
`.crewforth/review-prepass.json`: secret patterns, a debug call or TODO left in code, shellcheck on shell files, a
lock file that moved without its manifest, a very large change. **Carry those over, do not re-derive them**; your
time goes to what a pattern cannot see. rc 3 (no Node) or a `notMeasured` line means that part was NOT checked:
say so in the review, never read it as clean.

Write your own findings in the same shape (`crewforth.findings/1`: `rule` `review-<category>`, `severity`,
`confidence`, `evidence` with `file`, `line` and a `text` quote, `detail` = what to do instead) and store them with
`bash <dir>/../findings/findings.sh write review <file>`. A `critical` or `high` finding first goes to
**crew-refuter** (claim + `file:line`, one call per lens, in parallel) and the document is written with
`--verified`, which then refuses any `medium`-or-higher finding without its verifiers. This is model discipline:
no hook runs the pre-pass or reads `review.json`.

## 1. Scope
- **Review the lines this change adds or edits.** Deleted code is context for understanding them, not a target.
- Code that is correct, or that the change did not touch, gets no comment.
- **An empty result is a result.** Do not invent findings to show the review happened.
- **Be sure before you write.** A finding you are not sure of is not a finding yet: read the surrounding code until
  you are. A false alarm costs more than a small miss — it spends the attention the next real problem needs.

## 2. Group the files
Read together what has to be understood together: an interface and its implementations, the code that produces
something and the code that consumes it, the same resource in its language or environment variants. Look across
each group for a contract that broke between two files, or an update that reached one of them and not the other.
Then look at **every file in the group on its own** — a small or secondary file is where a missed update hides.

## 3. Plan before you comment
Before the first finding, write two things down:
- **What changed**, in one line.
- **The risks**, ordered by severity, each with what you will read to confirm or dismiss it ("the callers of
  `settle()`", "the migration's down step"). No risk worth checking → write `(none)` and say so.

The plan is what keeps the review on the change instead of on whatever the eye lands on first.

## 4. Severity and category
Every finding carries one severity and one category.

| Severity | What it is | Blocks the commit? |
|---|---|---|
| `critical` | a security hole, lost or corrupted data, a crash | **yes** |
| `high` | a core function stops working, or works wrongly | **yes** |
| `medium` | performance, maintainability, an unhandled edge case | no |
| `low` | readability and style | no |

Category: `bug` · `security` · `performance` · `maintainability` · `test` · `style` · `docs`.

**A blocker is a `critical` or `high` finding** — nothing else stops the commit, and the review is clean when none
is left open.

## 5. Style, names and code comments
- Style and naming are `low`, never block, and fit in one sentence.
- **Code comments are out of scope unless asked for**, with one exception: a comment that says something **false**
  about what the code does is a `low` / `docs` finding, because the next reader will believe it.

## 6. Finding format
`file:line · severity · category · what you observed · what to do instead`

What to do instead is the reason the finding exists; a finding without it is an opinion.

## 7. What a change must not quietly do
**Verifier integrity:** flag any change that makes a check pass by *weakening the check* — deleting or loosening
an assertion, lowering a threshold, skipping a test, editing the test instead of the code — rather than fixing
the behavior. A test or gate that grades itself lax is worse than none; a verifier must stay external and grounded.

**Subject integrity:** the inverse case — the check is untouched, but what it checked is gone. Flag a change that
deletes or stubs the code path, so the check passes over behavior that no longer runs; narrows the run to a
subset (fewer cases, one platform, a filtered input set) where the property happens to hold; turns an all-of
requirement into an any-of one; or relaxes the rule the code is there to enforce — a widened type, a dropped
uniqueness or referential constraint, an exception list holding exactly the failing case. Ask not "does it pass
now" but **"does the system still do what this check was protecting"**. Retiring a genuinely obsolete check is
legitimate: say so in the diff and name what covers it now.

## 8. Two-stage verdict (fact-check before you report)
Finding a problem and confirming it are two acts. A first-pass "this looks wrong" is a **candidate**, not a verdict.
Before a finding is reported — especially a blocker — run a second pass that tries to *disprove* it:
- Does it hold on the real code, or did the first read miss context (a guard upstream, a caller that never reaches
  this path, a framework default)? Re-read the surrounding code; do not rank on the snippet alone.
- Is the severity honest, or is a `low` dressed up as a blocker?
- For any **"fixed" / "passes" claim**: the *real* check ran and passed — test exit code, build, lint/quality gate —
  not "I re-read it and it looks fixed". A verifier that is the model's own say-so is not a verifier (§7, Verifier
  integrity). Cite the evidence: which check, what result.

**The disprove pass is asymmetric.**
- **Only evidence removes a finding.** It is dropped when the code shows it is wrong. "I could not confirm it",
  "it seems unlikely" or "it is not worth it" lower its severity; they do not delete it.
- **Some findings are never dropped in this pass:** memory safety; concurrency; a declaration that does not match
  its definition; a change in behaviour or compatibility — a message, field, status or default that callers
  used to get and now silently lose; a parameter that is accepted and then ignored. In these, the model's
  confidence that all is well is the signal least worth trusting.

**"Independent" costs a separate context.** A second pass in the same context has already read the first one's
reasoning, so it cannot be blind to it — and its agreement is the first pass nodding at itself. For a **blocker**,
run the disprove pass as its own subagent, handed the claim and the `file:line` but not your argument. If you did
not isolate it, label the verdict as a single pass rather than calling it independent. The full contract —
isolation, one lens per verifier, and why unanimity for the same reason is a monoculture — lives in
`security-scan/references/verify.md`; it is one discipline, not two.

## 9. Check the history before you call a finding new
A confirmed finding may still not be new, and one that was fixed once and came back needs a different fix. Search
**by code, not by commit message** — a message states intent, not content. The exact git forms (`-S` vs `-G`, the
`merge-base` bound, why `--follow` does not combine): **`references/history-search.md`**.

If a commit removed the guard, check, or test this diff would restore, the finding is a **re-introduced regression** —
the question becomes "what removed the fix, and does that reason still hold", the removing commit is cited in the
finding, and the deleted test is restored rather than a new one written.

## Panel mode (high-stakes decisions only)
For hard-to-reverse calls (architecture, public API, security boundary), run several independent adversarial
lenses then synthesize. Full method: **`references/panel-mode.md`**.

## When you and the author disagree
Settle it with the code's behaviour and a check that can be run. If that does not settle it, take it to the user
rather than blocking in silence.

## Triage — a finding that is only reported is a finding that is lost
Reviewing and *disposing of* what the review found are two acts, and only the first one is habitual. Every finding
that survives the disprove pass leaves the review with an explicit disposition — never an unanswered comment and
never a silent drop:

| Disposition | Means | Where it goes |
|---|---|---|
| **fixed now** | the owning specialist changed the code | the diff; re-review the change |
| **tracked** | real, not for this change | an issue/task with the file:line — cite the id in the review |
| **accepted** | a real cost the team is choosing to carry | an `adr` when it is architectural, a code comment when local |
| **dropped** | disproved by the code | say so; a candidate that vanishes unexplained reads as an oversight |

A blocker (`critical` / `high`) may only be `fixed now` or `tracked`. "Accepted" needs the user's decision — an
agent does not grant it to itself. Close the review by stating the counts per severity and per disposition; an
unreported finding is indistinguishable from one that was never made, which is exactly the state a review exists
to leave behind.

## Receiving a review — an inbound comment is a candidate, not an instruction
When the review is someone else's and the code is yours, **read every item before changing any line**, group by
cause rather than patching per symptom, and give each item the same disprove pass as a finding of your own. The
five questions that decide *answer in the thread* vs *edit the code*: **`references/receiving.md`**. Every inbound
item leaves with a disposition from the triage table above — a reasoned refusal is an answer, silence is not.

## DoD (this skill's contribution)
- The pre-pass ran (or its rc 3 / `notMeasured` is reported as unchecked), and the findings are in `.crewforth/review.json`.
- The plan (what changed, the risks) came before the findings; every file in each group was read.
- Every finding has a severity, a category and a reason, in the finding format above.
- Scope creep and hidden complexity are flagged.
- Each reported blocker survived an independent disprove pass; any "fixed"/"passes" claim is backed by the real check
  having actually run, not self-assessment.
- **Every finding has a disposition** (fixed / tracked / accepted / dropped) and no blocker is left merely reported.
- For a high-stakes decision, multiple independent lenses were applied and their objections synthesized, not averaged.
