---
name: crew-ship
description: DoD gate + commit proposal (waits for approval).
metadata:
  kind: command
---
# /crew-ship
Closure flow — in order:
1. **DoD gate:** was `/simplify` applied · are tests green (@agent-crew-test-expert) · `sonarqube-check` per the DoD quality line (`## Stack` → `Quality analysis:`) · a staged lockfile → `dependency-audit` record (§4.7).
   Run `bash "${CLAUDE_PLUGIN_ROOT}/skills/sonarqube-check/scripts/freshness.sh"` (Bash tool, not PowerShell): rc 1 (no analysis recorded, stale since an edit,
   or an empty `Quality analysis:` line) is red; rc 0 prints the verdict to quote, `unverified` included.
   If any one is red, **STOP**, report what is missing; no deferral.
   A risky change (auth, data, payments, a migration) names its rollback step in the commit proposal before it is
   committed: how it is undone and what that loses.
2. If clean, @agent-crew-commit-agent (commit-message) **proposes** an atomic Conventional Commit from the staged diff.
3. Commit runs ONLY if the user says "commit" (§4.4). "Done" is not approval, and neither is a hedged "looks reasonable" / "probably fine". In `auto`, Crewforth hands the session the
   one-click approval question when crew-commit-agent is called: ask it with the message; the typed `/crew-approve` is
   for when no question is offered.
   A pull request after the commit is `/crew-pr open`: it keeps the repository's template and pushes only on "push".
4. **Close the board item too** (`teamboard`), when one is held. Closing work is one movement: ask what shipped,
   run `board.sh done <id> "<note>"`, name the items it unblocked, and offer the next one as options. Do not
   leave this to the user to remember — a claim nobody closes reads to the whole team as still in progress, and
   the items behind it stay unclaimable. If a decision came out of this work that changes how other items must
   be done, record it with `board.sh decide` in the same breath; it is worthless in a session nobody else reads.

No destructive operations (§4.5). No AI trace / vendor name in the message (§4.1/§4.2 — the hook already scans).
