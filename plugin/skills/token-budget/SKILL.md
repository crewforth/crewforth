---
name: token-budget
description: |
  Context/token discipline: subagent isolation, output = summary, move-to-file, delegation threshold, lean skills.
---

# Token & Context Discipline

<!-- routing-eval reads the next line; why it sits in the body: AGENT_TEMPLATE.md -->
Trigger phrases: "token budget", "token cost", "context window", "context management", "context is full", "clear context", "running out of context"

A subagent exists for context management: it runs in its own window and returns **only its summary**
to the main thread — intermediate noise (file reads, searches, logs) never enters the main context.

**Warning — measured, not guessed.** Each subagent re-pays its **full context from scratch**: in a real
transcript the first turn was `cache_read=0`, every token `cache_creation` — nothing is shared with the main
thread's cache. A **no-op** subagent (task = "reply DONE") already cost **~10k tokens with restricted tools and
~16k with full tool access**; that floor is base system prompt + tool schemas, paid fresh every time. Of the
always-on material only the **skill listing (~2.5–3k tokens) is inherited** by a subagent — the discipline
(`DISCIPLINE.md`/CLAUDE.md) and the agent descriptions are **not** injected into it. (A crew agent is given one ~600-byte block of
the rules it cites at SubagentStart, by `agent-outcome.sh`; nothing else.) So a delegation is worth it
for **isolation / parallelism / a clean window**, or when the isolated work would otherwise cost the main thread
**more than that ~10–16k floor** — never by default.

## Rules
1. **Output = summary.** The agent returns a short, structured summary to the main thread; it does **not** return raw logs / file dumps / long code.
2. **Move to a file.** Heavy output (a plan, scan report, inventory) is written to `docs/*.md`; a **summary + pointer** comes back. (local, in gitignore)
3. **Delegation threshold.** Noisy/heavy work (reading many files, scanning, research) → subagent. A single tool-call / small work → **main thread**. Concretely: if the isolated work won't save the main thread more than the **~10–16k fresh-context floor** a subagent costs, keep it on the main thread — delegate for isolation, not to shave a few reads.
4. **A RESUMED agent re-pays its GROWN context, not its floor.** Continuing an agent that already ran keeps its
   whole history, so the next turn starts from wherever it got to. Measured across four turns of one agent:
   167k → 187k → 207k → **211k tokens**, and that last turn was a single word of seed text. The floor in rule 3
   is the cost of a FRESH agent; a long-running one passes it many times over. Continue it for the context it
   holds — a running verification, a migration it is mid-way through — and open a fresh one, or stay on the main
   thread, for a small correction that does not need any of that history.
5. **Built-in agents are on this budget too.** `Explore`, `general-purpose` and the rest cost exactly what a Crewforth
   agent costs; one repo-mapping `Explore` measured 520 s and ~150k tokens. Crewforth owns no search agent, so
   reaching for a built-in is correct — just size the request the way rule 3 sizes any other delegation.
6. **Least tooling.** An agent holds only the tools it needs; extras accidentally pollute the context + burn the limit.
7. **Lean SKILL.md.** Skills load into the main context; heavy reference goes to a separate file, only when needed.
8. **Targeted reading.** Instead of reading a whole file, pinpoint with Grep/Glob.
9. **Measure fill, don't guess.** `bash "${CLAUDE_PLUGIN_ROOT}/hooks/context-usage.sh"` (Bash tool, not PowerShell) reads it from the transcript; crew-session-manager recommends continue or handoff+clear; the user runs `/clear` at a phase boundary.
10. **Bound what a command hands back.** All of the rules above govern the context's own footprint; none of them
   govern what a single `Bash` call dumps into it. A `find` over a monorepo, an unfiltered log, a full test run —
   each returns everything to the main thread whether or not any of it is read. Ask for the answer, not the
   corpus: `grep -c` over `grep`, `| tail -20` over the whole file, `--quiet`/`--porcelain` where the tool has
   one, and a redirect to a file plus a pointer when the output is genuinely needed later (rule 2).
11. **Cut what nothing reaches — with evidence, not a hunch.** Every installed skill spends its name and
   description in EVERY session, forever. `bash .claude/eval/utilization.sh` (Bash tool, not PowerShell; a file install only) reports which skills actually fired
   in this project's transcripts and how many bytes the cold ones cost, which is the list `doctor.sh` §4a's
   `skillOverrides: name-only` advice needs and never had. Read it as evidence, not a verdict: a skill that only
   fires during an incident is doing its job by existing. `--all-projects` widens the scope; by default it reads
   this project only and prints names and counts, never paths or content.
