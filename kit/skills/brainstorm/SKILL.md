---
name: brainstorm
description: |
  Use when the ask is still fuzzy and no direction is chosen yet: "not sure what we want", several ways to go,
  or a scope to settle before any plan is written.
---

# Brainstorm — diverge before you converge

<!-- routing-eval reads the next line; why it sits in the body: AGENT_TEMPLATE.md -->
Trigger phrases: "brainstorm", "explore options", "not sure what we want", "help me scope", "ideate"

## When
The ask is **under-defined**: the goal, the users, or the shape of the solution aren't clear yet, so jumping
straight to `spec-planning` would just plan the wrong thing. This is the front-end of planning, not a
replacement — brainstorm *diverges* (widens the option space), spec-planning *converges* (breaks the chosen
option into tasks). If scope is already clear, skip this and go straight to [[spec-planning]].

## The loop
1. **Frame the real problem** — restate the request as the underlying need in one sentence ("the user wants
   X so that Y"). Separate the stated solution from the goal; often the solution is negotiable, the goal isn't.
2. **Diverge — generate distinct directions.** Produce **2–4 genuinely different** approaches, not variations
   of one. For each: the core idea, who it serves, the main trade-off. Include a deliberately cheap/minimal
   option (fight gold-plating early).
3. **Surface the unknowns** — list assumptions and open questions that would change the answer. Mark which are
   **blocking** (must resolve before planning) vs. deferrable.
4. **Converge — ask, don't guess.** Present the directions as **explicit numbered options** and let the user
   choose (CLAUDE.md discipline: a decision point = multiple choice, never a prose either/or). Record the
   chosen direction + the rejected ones with the one-line reason they lost.
   How to put a question, what is worth asking and what to do when no answer comes:
   `references/asking.md`; `/crew-interview` runs the whole round of questions as a command.
5. **Hand off.** The chosen direction + resolved constraints flow into `spec-planning`; a lasting
   architectural choice made here is recorded with [[adr]].

## Guardrails
- **Bounded, not open-ended.** Divergence has a stop: 2–4 options, then converge. Endless ideation with no
  decision is the failure mode, not thoroughness.
- **No premature convergence either.** Don't collapse to the first idea to look decisive — the point is that
  the option space was actually explored before a direction was picked.
- **Evidence over invention.** Read the existing code/data and state assumptions explicitly; a plausible guess
  presented as fact is worse than a named unknown.
- **Token discipline** ([[token-budget]]): the options + the decision are a short summary to the main thread;
  push a long exploration to `docs/DISCOVERY.md` and return the option headings + the choice.

## DoD (this skill's contribution)
- The real goal is stated separately from the requested solution.
- 2–4 distinct directions exist, each with its trade-off, including a minimal option.
- Blocking unknowns are named and were asked as explicit options — nothing ambiguous was filled by guessing.
- A direction is chosen and ready to enter [[spec-planning]] (rejected options logged with their reason).
