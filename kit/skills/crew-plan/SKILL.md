---
name: crew-plan
description: Spec-first planning for loosely scoped work (crew-planner).
argument-hint: "[task/feature description]"
metadata:
  kind: command
---
# /crew-plan
Argument: $ARGUMENTS

**First, when `.crewforth/crew-map.json` exists, ask the map whether it still matches the tree.** The scanner is
`${CLAUDE_PLUGIN_ROOT}/eval/lib/crew-map/crew-map.sh` if that names a real path (the plugin), else
`.claude/eval/lib/crew-map/crew-map.sh`. Run `bash <scanner> --check` (Bash tool) and put its line in the
planner's task: rc 0 "the map is up to date", rc 1 "the map differs from the tree", rc 3 or any other "the check
did not run". The planner cannot run it (it is read-only).

Delegate to the @agent-crew-planner agent (spec-planning skill). For ambiguously scoped work:
1. Clarify the goal + what's out of scope.
2. Split into vertical slices; give each task a measurable acceptance criterion.
3. Order by dependency + put the riskiest first.
4. Ask about ambiguities with **explicit options**; write down the assumptions.

crew-planner is read-only and returns the plan; you (the main thread) write it to `docs/PLAN.md` and keep only the
summary + file pointer in context (token-budget).
Do NOT write code — this is a planning step.
