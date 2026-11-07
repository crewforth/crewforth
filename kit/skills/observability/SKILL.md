---
name: observability
description: |
  Stack-agnostic observability: structured logs, correlation ids, metrics and traces; no PII or secrets in logs.
  Makes a production issue traceable to why it happened.
  Use when adding a log line, an error path, a metric, or when an incident could not be traced.
---

# Observability

<!-- routing-eval reads the next line; why it sits in the body: AGENT_TEMPLATE.md -->
Trigger phrases: "observability", "structured logging", "structured log", "add a trace", "add a metric", "add metrics", "correlation id", "add logging"

Goal: to be able to answer "what happened, where, why" during a production incident **by looking at the logs**.
It is stack-agnostic; when you need a framework-specific library/format, do a web search.

## Three signals
- **Log** — event record (structured/JSON, leveled).
- **Metric** — numeric time series (request count, latency, error rate, resource usage).
- **Trace** — a request's journey across services (spans + correlation id).

## Checklist
- [ ] Logs are **structured** (JSON/key-value), not string interpolation
- [ ] Every log line carries a **correlation id** (request/trace id)
- [ ] Levels are correct: the DEBUG/INFO/WARN/ERROR distinction is meaningful
- [ ] **No PII/secret is logged** (password, token, card, national/ID number, email body)
- [ ] Error logs carry context (input summary, user/resource id — not PII); the stack trace does not leak to the user
- [ ] Critical business metric + infrastructure metric are emitted (where applicable)
- [ ] The correlation id is **propagated** across service-to-service calls (header/propagation)

## How
0. **The questions first.** Write the 2-4 questions on-call will ask when this breaks ("which tenant's payments are
   failing?", "is it us or the provider?"). Every log field, metric and alert added here answers one of them; a
   signal that answers none is noise (invariant 4).
1. **Structured logger** — set up/use one whose output is machine-readable (JSON). Search for the library the framework recommends.
2. **Correlation id**: generate it at the entry point (HTTP middleware / message consumer) or take it from the incoming `X-Request-Id`/trace header; put it in the log context; **propagate** it to downstream calls.
3. **Level discipline**: INFO = business event, WARN = expected-but-noteworthy, ERROR = needs intervention. DEBUG is off/sampled in production.
4. **Context fields**: `event`, `correlation_id`, `user_id` (not PII, an opaque id), `duration_ms`, `outcome`. Do not embed them in free text.
5. **Metrics**: at minimum RED (Rate, Errors, Duration) or USE; plus business-critical counters. Search for the framework's metrics library.
6. **Trace** (in a distributed system): start/end spans, bind the correlation id to the trace id.

## PII / secret leakage (critical)
**Never** to the log: password, token, API key, card number, national/ID number, full email/phone body, raw request body.
- Mask: `user@***`, card `**** 1234`, token `sk-p…789`.
- When needed, log an **opaque id** (hash/uuid), not the raw value.
- This axis overlaps with `security-scan` (sensitive data in logs) and `privacy-compliance` (KVKK/GDPR) — if personal data is involved, trigger those too.

## Invariant rules
1. **Structured > free text** — greppable, parseable.
2. **Correlation id on every line** — without it, a distributed error is untraceable.
3. **No PII/secret is logged** — mask it or use an opaque id.
4. **Do not make noise** — every line must answer a question; do not add meaningless spam logs.
5. **Match the existing format** — if the repo has a logger, follow its pattern; do not impose a new one.
6. **Metric labels stay low-cardinality** — no user id, email, request id, raw URL or free text as a label: each
   distinct value is a new series, and the bill and the query time grow with them. Those values go in logs and
   traces; a label holds a route template (`/orders/:id`), a status class, a region.

## DoD
- Each question from step 0 can be answered from the signals added.
- One failure was induced on purpose and found again by its correlation id, from the entry point to the failing call.
- Every new alert was test-fired once and reached the place it pages.
- No PII or secret in any line, label or span attribute.
