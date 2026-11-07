---
name: performance
description: |
  Stack-agnostic performance: measure first, find the bottleneck, then optimise. N+1, needless allocation, wrong
  async boundary, missing index/cache, heavy payload. No premature optimisation.
  Use when something is slow, before optimising anything, and when a change touches a hot path.
---

# Performance

<!-- routing-eval reads the next line; why it sits in the body: AGENT_TEMPLATE.md -->
Trigger phrases: "performance", "slow", "optimization", "profiling", "N+1", "latency", "memory leak", "leaked memory", "load test", "seconds to open", "seconds to respond", "anything slower", "make it slower"

Core rule: **measure first, optimize later.** Optimization without measurement is a guess; it usually speeds up the
wrong place and adds complexity. Stack-agnostic; do a web search when you need the profiling tool/library.

## Method (in order)
1. **Set a target** — what is "acceptable"? (p95 latency, throughput, memory ceiling). Numeric.
2. **Measure** — find the real bottleneck with a profiler/APM/benchmark; don't start from a guess.
3. **Fix the single most expensive thing** — Amdahl: speeding up a 5% path by 2x is wasted; target the hot path.
4. **Measure again** — did it actually improve, is there a regression. Run each side enough times to see the
   run-to-run noise, then decide:

   | Result against the noise | Decision |
   |---|---|
   | Better by more than the noise | Keep |
   | Within the noise | Revert: no measured gain is no gain |
   | Worse, or a test went red | Revert |

   A reverted attempt is written down (in the PR, or the doc that holds the measurements) with its number, so a
   discarded idea stays discarded.
   **4b. Same answers before same speed.** An optimisation of a pure function is kept only after a differential
   check: the original and the new version run on generated inputs (empty, one item, repeated values, sorted,
   reverse-sorted, extreme sizes, typical) and return the same results. Then time the new one on its own worst input
   shape, not only the benchmark's.
5. **Stop** — once you hit the target, finish; no endless micro-optimization.

## Common bottlenecks

Catalog of common bottlenecks + fixes to consult: **`references/bottlenecks.md`**.

## Measurement tips
- Measure **under load** (a single request misleads); with a realistic data volume.
- **Not p50, but p95/p99** — tail latency is what burns the user.
- Don't trust micro-benchmarks; an end-to-end profile is more honest.
- A web page: the Core Web Vitals thresholds, field against lab data, and what makes up LCP: `references/web-vitals.md`.

## Symptom → cause → fix
| Symptom | Usual cause | Fix |
|---|---|---|
| List page gets slower as data grows | N+1 queries, or no pagination | one query with a join or batch load; paginate |
| Fast locally, slow in production | the data volume, or a missing index | measure with production-sized data; `EXPLAIN` the query |
| Typing or scrolling stutters | work on every keystroke or render | debounce, memoize, virtualize long lists |
| Memory grows until a restart | listeners, timers or caches never released | remove them on teardown; bound every cache |
| First load slow, later loads fine | a large bundle or an unoptimised hero image | split the bundle, lazy-load below the fold, size the image |

## Invariant rules
1. **Don't optimize without measuring** — a change without a profile = a guess.
2. **Target the hot path** — don't speed up the small share.
3. **Don't break correctness** — don't sacrifice behavior/edge cases for speed.
4. **Complexity budget** — make an optimization that seriously hurts readability only if there is a measured gain; comment it.
5. **Stop once you hit the target** — YAGNI; no premature/excessive optimization.
