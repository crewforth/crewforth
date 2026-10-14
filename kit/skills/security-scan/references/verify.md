# Verify before you report — the adversarial pass

Discovery and verification want opposite things. **Discovery is recall-biased** — when unsure whether something is
real, surface it (a low-confidence finding beats a missed bug). **Verification is precision-biased** — a separate,
adversarial pass that tries to *disprove* each finding. Keeping them separate is the single biggest lever on false
positives. (This is the same two-stage-verdict discipline `crew-code-review` uses — reused here for security findings.)

Run this pass on every candidate before it reaches the report.

## The verifier stance
For each finding, run **N independent verifiers** (default **3**; 1 for a quick scan, 5 for a release/high-stakes
audit). Each verifier:
- **Starts from the code at the cited `file:line`, not the finding's summary.** If you start from the summary you
  inherit its misreading.
- Is stanced **"find any reason this finding is wrong."** Actively hunt for why it is *not* exploitable.
- Is **blind to the other verifiers' reasoning** — shared context propagates the same blind spot.

### "Independent" means a separate context, or it means nothing
Three passes inside one context window are not three verifiers. The second pass has already read the first one's
reasoning; the blindness above is then a wish, not a property, and the agreement it produces is one argument
counted three times. So:
- **Each verifier is its own `crew-refuter` call** (one call per verifier and lens, run in parallel). A subagent
  has its own context window: it cannot see what the others concluded, which is the whole point. Read-only work,
  so no `worktree` is needed — nothing is being written. Its task is the card, then `finding:`, `lens:`, `cite:`
  and `claim:` (its agent file has the exact form); when it stops, `hooks/refuter-ledger.sh` records the verdict
  in the refuter ledger, and `findings.sh write --verified` refuses a `medium`-or-higher finding whose verifiers
  are not there. The ledger is the gate; the prompt that carries no reasoning is still discipline.
- **Give it the finding and the file:line, never your reasoning.** Not "I think X is exploitable because Y" —
  just "claim: X at file:line. Try to refute it."
- **If you did not isolate, say so.** Write `verifiers: 1 (single pass, not isolated)` in the verdict block. A
  single honest pass is useful; three passes labelled as independent when they were not is worse than one,
  because it launders confidence.

**Cost gate, because isolation is not free** — each subagent re-pays for its own context (see `token-budget`), so
N×findings gets expensive fast. Isolate by stake, not by default:
- **critical / high severity, or anything heading for a release** → isolate, N=3 (N=5 for a release audit).
- **medium** → isolate, N=1. One genuinely independent pass beats three entangled ones.
- **low** → single inline pass, labelled as such. Do not spend a subagent proving a `low`.

### The verifiers must not be three copies of one method
Independent is still not uncorrelated. Three verifiers running the same four steps fail in the same place, and
their agreement then reads as confirmation when it is only repetition. Assign each a **different attack**:
- **Reachability** — can untrusted input actually arrive here? Quote the first call-site as evidence.
- **Protection** — does something on every path already stop it? Try to break each guard.
- **Reproduction** — what input, in what state, actually triggers it? If you cannot name one, that is
  `CANNOT_VERIFY`, not agreement with the others.

At N=5 add **exclusion rules** (does this match a known FALSE_POSITIVE class below?) and **blast radius** (if it
is real, what does it actually reach?). Record which lens produced which verdict — a verdict whose lens is
unnamed cannot be weighed.

### Unanimity is a signal to check, not a verdict to trust
If every verifier returns the same verdict **for the same reason**, that is one argument counted N times. Before
accepting it, run one counterfactual pass: *"assume this verdict is wrong — what would have to be true, and what
evidence would show it?"* Record the answer beside the verdict. Unanimity with N distinct reasons is strong;
unanimity with one reason is a monoculture, and it is exactly how a whole panel misses the same guard.

## The 4-step verify procedure (each step kills a specific false-positive class)
1. **Read the cited code yourself** — do not trust the description.
2. **Trace reachability backward from the sink.** Can untrusted input actually reach it? **Quote the first
   call-site `file:line`** as evidence. *Unreachable code is the single largest source of false positives* — a
   plausible-sounding chain is not enough.
3. **Hunt for protections** on every path: validation, parameterization, auto-escaping, type/length bounds, an
   auth/scope gate, or the code being dead/test-only.
4. **Stress-test each protection on every path** — a guard that holds on one route but not another is not a guard.

## Verdict — three outcomes, never a forced binary
- **TRUE_POSITIVE** — requires ALL of: reachable + protections insufficient + exploitation feasible.
- **FALSE_POSITIVE** — fails one of the above, or matches an exclusion rule below.
- **CANNOT_VERIFY** — static reasoning hit its limit (needs a running system / data you don't have). Report it
  honestly as `needs_manual_test`; never inflate uncertainty into a confident verdict.
  - It carries **no severity**. It is a specific, source-grounded hypothesis that one missing fact blocks — not a
    low-confidence confirmed vulnerability — and a severity on it would be read as a rating it has not earned.
  - Name the missing fact exactly, and the check that would settle it.
  - Controls that live outside the repository — a proxy, a WAF, provider settings, identity policy, network
    topology, how a renderer sanitizes — are real controls. When a verdict depends on one that the source does not
    show, do not assume it is **present**, and do not assume it is **absent**: that is what CANNOT_VERIFY is for.

"I couldn't write a working PoC" is **weak** evidence of non-exploitability — do not downgrade on that alone.

## Exclusion rules — FALSE_POSITIVE even if technically accurate
1. Volumetric/rate DoS with no amplification (just "many requests").
2. Test, fixture, example, or provably dead/unreachable code.
3. Intended, documented design (a stated, accepted risk).
4. Memory-safety issue in a memory-safe language/runtime.
5. Input that only a trusted operator controls (a local CLI flag, an ops-only env var).
6. "Outdated dependency" with no reachable vulnerable call path.
7. Weak randomness used somewhere non-security (a cache key, a test seed).
8. XSS auto-neutralised by the framework's default escaping.
9. Traversal blocked one layer up (a gateway/service the reasoning didn't read).
10. A theoretical-only TOCTOU with no realistic race window.
11. "Missing hardening" with no concrete exploit (a nice-to-have header).
12. Low-impact nuisance with no security consequence.

Add project-specific rules as you confirm them.

## Structured verdict block (one per finding, parseable)
```
VERDICT: TRUE_POSITIVE | FALSE_POSITIVE | CANNOT_VERIFY
CONFIDENCE: 0-10
VERIFIERS: <N, isolated | N, single pass not isolated>
LENSES: <reachability, protection, reproduction — which ones actually ran>
AGREEMENT: <unanimous-same-reason | unanimous-distinct-reasons | split N-M>
REACHABILITY: <first untrusted call-site file:line, or "unreachable">
EXCLUSION_RULE: <number, or none>
RATIONALE: <cites concrete file:line, not prose>
```
`VERIFIERS` and `AGREEMENT` exist so the reader can discount the verdict without re-doing the work. "3, single
pass not isolated" and "unanimous-same-reason" together mean one argument wearing three hats — still worth
reporting, not worth treating as three. Leaving these fields out is how a weak verdict passes for a strong one.

## Tally
Verdict = majority of the N verifiers; confidence = mean of the agreeing votes. **Tie → the operator's noise
tolerance:** precision → drop; recall → keep as `needs_manual_test`; ask → one batched question. Never silently
drop a finding — a dropped finding is recorded (with its verdict) in the report's "Ruled out" section.

## Severity is a SEPARATE judgment from verification
"This is real" must not inflate into "this is critical." Derive severity from **preconditions × access level**, not
from the vulnerability category:

| access ↓ / preconditions → | 0 preconditions | 1–2 | 3+ |
|---|---|---|---|
| **unauthenticated / remote** | CRITICAL–HIGH | MEDIUM | LOW |
| **authenticated** | MEDIUM | MEDIUM | LOW |
| **local / operator** | LOW | LOW | INFO |

- Take the **lower** of the two axes. If the precondition list has **3+ items, HIGH is almost certainly wrong.**
- **HIGH or MEDIUM? Ask one question:** does the demonstrated result fully **defeat** an explicit control for an
  action with real consequences, or only **weaken** it? Defeat is HIGH territory; weaken is MEDIUM at most. If you
  cannot state the concrete damage in a sentence, the severity is lower than it feels.
- Severity never exceeds the impact actually demonstrated.
- A `threat-model` match may raise severity by **at most one step** — never two (a stated threat can't re-inflate a LOW to HIGH).
- Record `severity_alignment` (**-5..+5**): judged from the stance of a reviewer who has seen two hundred inflated
  scanner findings this week — how over- or under-stated is the raw claim? Negative = deflate it.
