# Agent Template Contract (Claude Code)

All expert agents conform to this skeleton. Canonical reference: **`crew-backend-expert`**.
Principle: **agent = thin trigger** ("who / when"), **skill = "how"**. Knowledge lives in the skill, the trigger in the agent.

## Frontmatter (required fields)
- `name`: kebab-case, exactly matching the file name.
- `description`: Claude Code makes its delegation decision **by looking at this**. It must say two things:
  (1) what it does, (2) **WHEN** it kicks in.
- **The `Trigger phrases:` line (English key phrases) sits in the BODY**, right under the frontmatter, marked by a one-line
  `<!-- routing-eval reads the next line … -->`; routing-eval reads it there. Why not in the description: a skill's
  description is in the always-on listing, which has a budget (1% of the context window by default), and an
  overflowing listing loses descriptions and with them the keywords a match depends on; an agent's description
  stays focused on WHEN to delegate, the field Claude reads. Keep the rationale here, not in every file — the
  comment is loaded with the body on every invocation.
- `tools`: least-privilege principle. Read-only auditor → `Read, Grep, Glob (+Bash)`; writing expert → `+ Edit, Write`.
- `model`: normally ABSENT. The caller names the model on each call (section "Model routing" below); a field here is for an agent whose every task is one tier.

## Body sections (fixed order)
1. **When** — triggering context.
2. **Expertise stance — recommended.** 3-5 **role-specific** concrete behaviors that the best in that role does differently (not a generic "be an expert"). It raises the decision/stance; the mechanical "how" stays in the skill.
3. **How (follow its skill)** — which skill + that skill's exit points specific to this agent. The skill is the **single source of truth**; do not copy the "how" into the agent — at most a quick reminder, and on conflict the skill wins (§2 "no repetition").
3b. **Before writing any of it — writing experts only.** Two pre-flight checks, both **model discipline**; no hook enforces either:
    - `confidence-check` — the only check in Crewforth that comes BEFORE implementation. Any "no" is a stop, not a caveat.
    - **A design summary, when the change carries architecture** — a new or changed data model/schema, a new or changed API contract, or 2+ domains touched. Three to five lines (which table/endpoint/integration point moves · which pattern · what the alternative was), put to the user with `AskUserQuestion` before the first line of code. Trivial single-domain work skips it: RISK decides, not size.
4. **Coordination (cross-agent) — recommended for writing experts.** Whom this work is delegated to: security→crew-security-expert, schema→crew-database-expert, tests→crew-test-expert, messages→i18n, personal data→crew-privacy-agent, hot path/query/render/payload→crew-performance-expert, findings at closure→crew-review-agent. It turns the agent into an orchestrator; usually unnecessary for read-only auditors.
    - **The read-only audits go out in parallel** — several `Agent` calls in ONE message. None of them writes product code, so there is nothing to serialise (discipline Workflow §3).
    - **No unbounded ping-pong.** More than 3 handovers between the SAME two agents on one task (e.g. `crew-backend-expert` ↔ `crew-database-expert`) is a loop, not coordination: stop before the fourth, summarise what each round changed and what is still open, and put it to the user with `AskUserQuestion`. Model discipline — nothing counts the hops for you.
5. **DoD** — closure responsibility: `/simplify` + tests green + `sonarqube-check` (0/0/0/0, build 0/0).
6. **Output & context (token)** — what returns to the main thread: a **short summary**, not raw logs/dumps; heavy output goes to `docs/*.md` (token-budget skill).
7. **Errors/escalation** — when stuck/unsure, **stop and report** or hand off to the relevant expert; do not proceed on a guess.
8. **Example delegation** — 1 ✅ triggers / 1 ❌ does-not-trigger line (delegation accuracy).
9. **Constraints** — read-only or not, what it does not do, platform/policy limits.

## Model routing (chosen per call, by the task's card)
The model is chosen **when the agent is called**, by the risk of the task. The caller opens the task with a card and
names `model`; `hooks/guard-agent-model.sh` reads both and refuses a call it cannot place. So an agent file carries
**no `model` field** as a rule: a pin in the file would be one answer for every task the agent is given.

**The card** is the first three lines of the task:

```
files:  src/orders/**, test/orders/**
change: feature
verify: npm test -- orders
```

`change` is one of `text` · `feature` · `fix-known` · `fix-unknown` · `refactor` · `migration` · `security` ·
`architecture` · `test-run` · `test-write` · `audit`. `verify` is the command that proves the work, or `none`.

**Risk class.** `critical` when the change is `migration`, `security`, `architecture` or `fix-unknown`, or a file is
on a critical path (auth, payments, billing, migrations, security, crypto, secrets, `*.sql`, `schema.prisma`; the
project's own are listed in `.claude/state/crew-critical-paths.auto`, and `.claude/crew-model-rules` adds or removes).
Otherwise `normal`.

| What the gate holds | `normal` | `critical` |
|---|---|---|
| any work | by the table in `CLAUDE.md` | `opus` |
| `test-run` | `haiku` | `haiku` (running the tests is objective) |
| `test-write`, `audit` | `sonnet` or above | `opus` |
| `crew-review-agent`, `crew-privacy-agent`, `crew-planner`, `crew-database-expert` | `sonnet` or above | `opus` |
| `crew-security-expert` | `opus` | `opus` |
| `verify: none` | `sonnet` or above | `opus` |

- **The referee follows the risk, not the author.** Tests, audits and reviews are what the work is judged by, so
  their model is set by the risk of the work. In normal work an author on Opus does not pull the review up to Opus;
  in critical work the review is on Opus whoever wrote the code.
- **Verify, then escalate.** When the agent stops, `hooks/agent-outcome.sh` runs the card's `verify` command. Red
  once: the agent is kept running and told to fix it. Red again: the agent ends, the session is told to repeat the
  task once, one model up, and the gate refuses the same card on the same or a lower model. Red there too: the user
  is asked; there is no third run.
- **At write time.** An agent that is not on Opus cannot write to a critical path, whatever its card said. When that
  refusal comes, stop and say so (the lines below).
- **Use a tier ALIAS** (`haiku`/`sonnet`/`opus`), not a dated model ID. `fable` is refused for a crew agent unless
  the user set `CREW_ALLOW_FABLE=1`. `CREW_MODEL_ROUTING=off` turns all of this off.
- **A frontmatter `model` is the exception**, for an agent whose every task is the same tier (`crew-commit-agent`:
  `haiku`). The call's own `model` is still required and is what runs.
- **The last line of every report is exactly `confidence: high` or exactly `confidence: low`** (lower case, nothing
  else on the line, nothing after it; the Studio panel reads it). `low` means the agent guessed, could not verify,
  or the task was above the model it ran on. When a write was refused for the model, the line before it is
  `escalate: <the file>`.

## Placement
- Project-local (10): `./.claude/agents/` — crew-session-manager, backend/database/security/test/crew-frontend-expert, crew-review-agent, crew-commit-agent, crew-planner, crew-privacy-agent. Everything stays inside the repo; no dependency on home (`~/.claude`) (handover §3).
- No extra agent is needed; stack-specific "hows" live under `./.claude/skills/` (the frontend's "how" is in the project's frontend skill / CLAUDE.md).

## Decompose along the cost axis (tool < skill < subagent)
A monolithic prompt is a smell. Move each responsibility to the **cheapest primitive that suffices**:

```
cheaper, weaker  ◀──────────────────────────────▶  more power, more cost
 TOOL / code-exec         SKILL                  SUBAGENT
 one call, stateless,     instructions read      its own context window
 deterministic            on demand              & its own goal
```

Smell tests:
- A tool that dumps **>2k tokens** into context → replace it with **code execution** over the data (compute over context, not a data dump).
- Writing **"always do X before Y"** into an agent prompt → that belongs in a **skill**, not copied prose.
- A **subagent whose output is one number/line** → it shouldn't be a subagent; inline it. Delegate for *isolation*, not by default (see `token-budget`).

**Typed contract between stages.** A prose handoff drops data — a confidence number gets lost when the orchestrator
re-parses a paragraph. Require a **typed contract** at every stage boundary (e.g. `{value, confidence, method,
flags}`) and **validate-and-clamp** it before trusting it (known fields only, enums constrained, list lengths
capped). *Anchor the number, not just the narrative.*

## Test-first (add the eval before the skill/agent)
Treat a new skill/agent like code under TDD: write the checkable expectation **first**, watch it fail, then build
until it passes. Crewforth's evals ARE those tests.
1. **Golden routing** — add a line to `eval/golden-routing.txt` (`<a realistic prompt>|<this target>`) *before* writing
   the skill. Run `routing-eval.sh`: it FAILS (target missing / no trigger). That failure defines the trigger phrases
   you must choose — you're designing the description against a concrete prompt, not guessing.
2. **Negative guard** — if a trigger risks over-firing (a generic word like "design", "review", "model"), add a
   `<prompt>|!<target>` line so an over-broad trigger fails the eval. This is how a trim stays trimmed.
3. **Budget & spec** — `smoke-test.sh` gates name==dir, description ≤1024, and the always-on byte budget; a verbose
   description fails the suite rather than quietly taxing every session. Add the Turkish summary line
   (`packaging/skill-summaries.tr.tsv`; agents and commands have their own `.tr.tsv`) — the site build fails without it.
4. **Only then** write `SKILL.md` (+ `references/` for depth) until all three go green. Red → green, never green-by-assertion-weakening (that's the Verifier-integrity anti-pattern the review skill itself flags).

## Reference example
`crew-backend-expert.md` is this contract applied verbatim; when creating a new agent, copy it and fill it in.
