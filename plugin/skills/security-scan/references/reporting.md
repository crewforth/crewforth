# Reporting & fix presentation

## Report

**Severity scale:**

| Level | Meaning |
|---|---|
| CRITICAL | Directly exploitable — urgent (SQL injection, hardcoded secret in prod) |
| HIGH | Serious — close before deploy (XSS, command injection, known CVE) |
| MEDIUM | Defense gap — soon (missing CSRF, loose CORS) |
| LOW | Best-practice violation — when convenient (debug mode, missing header) |
| INFO | Observation — no immediate risk |

**Finding format** (ranked by severity):
```
[CRITICAL] SQL Injection — src/api/users.ts:42
  CWE   : CWE-89
  Vuln  : Input concatenated directly into the SQL query
  Impact: DB can be read / modified / deleted
  Fix   : Use a parameterized query
  Depth : Least-privilege DB user for this service (limits the damage if another path is missed)
  Detect: Alert on SQL syntax errors from this endpoint
  Retest: Send `' OR 1=1--` as the id; expect 400 and no rows
```
`CWE` names the weakness class, so findings can be counted and compared across reports. `Fix` closes the hole;
`Depth` (defense in depth) and `Detect` (how an attempt would be seen) are optional and never replace it.
`Retest` is the one check that proves the fix, written so someone else can run it. Several findings of the same
class (ten unescaped outputs) may share one entry with a table of locations instead of ten copies.

**Summary line:**
```
=== Security Scan Summary ===
  CRITICAL: X · HIGH: X · MEDIUM: X · LOW: X · INFO: X · Total: X
```

## Coverage — say what you did NOT look at

A report with no findings is read as "nothing is wrong". It can equally mean "that surface was never opened",
and the two are indistinguishable to the person acting on it — who then ships believing an audit happened. The
`CANNOT_VERIFY` verdict already handles this for an individual finding; coverage handles it for the audit.

Every report ends with a coverage ledger, one row per surface from the threat model ([[threat-model]]):

```
=== Coverage ===
  complete  auth/session handling        — read every route + middleware
  complete  SQL data access              — grepped all query construction sites
  partial   file upload                  — read the handler; storage backend config not available
  unknown   payment webhook              — third-party signature logic, no source access
  unknown   admin client (Blazor)        — out of scope this pass, agreed with the user
```

Rules:
- **`complete` is a claim, not a hope.** Use it only where you can name what you read or ran. If you sampled,
  it is `partial`.
- Every `partial` and `unknown` carries **why** — no access, out of scope, no time, third-party. A bare
  `unknown` is the same silence the ledger exists to remove.
- `unknown` on a surface the threat model calls high-risk is itself a finding: report it at the severity that
  surface would carry, not as a footnote.
- The ledger is written **before** the fixes are proposed. Written afterwards, it gets trimmed to match the
  work that happened to be done.
- "Zero findings, coverage complete" is a strong claim and rare. "Zero findings, half the surface unknown" is
  an honest and much more common one.

### When a previous report exists
Read it before planning, and let it shape priority — never coverage.
- A previous **TRUE_POSITIVE** carries into this report only if the code on its path is unchanged; the verifier
  re-checks it like any other candidate. Changed code makes it a fresh candidate, not an inherited one.
- A previous **FALSE_POSITIVE** rules out that exact claim on that exact unchanged code — nothing more. The surface
  it sat on is still reviewed.
- A previous **CANNOT_VERIFY** is current work, unless the fact it waited on is still unavailable; then it carries
  with that same named blocker.
- A previous `partial` or `unknown` row is never inherited as `complete`, and a previous narrow or quick pass is
  never read as "the rest was fine". Say in this report which rows came from the earlier one and why they still hold.

When this pass closes out earlier findings, add a retest table, one row per finding, each with its `Retest`
result: `fixed-verified` (the retest ran and failed to reproduce) · `partial` (one path closed, another open) ·
`not-fixed` · `accepted-risk` (the user's recorded decision, with where it is recorded). A fix nobody retested
is `not-fixed` until it is.

## Fix presentation
```
How shall we proceed?
  1. Fix everything        2. CRITICAL+HIGH only
  3. Approve one by one    4. Manual (no changes)
```
For each fix: preview the diff → wait for approval → (if a dependency) upgrade command + breaking-change note → re-run the relevant check.
