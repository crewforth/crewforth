---
name: crew-ship
description: DoD gate + commit proposal (waits for approval).
metadata:
  kind: command
---
# /crew-ship
Closure flow — in order:
1. **DoD gate:** was `/simplify` applied · are tests green (@agent-crew-test-expert) · (if SonarQube is used) `sonarqube-check` 0/0/0/0.
   If any one is red, **STOP**, report what is missing; no deferral.
2. If clean, @agent-crew-commit-agent (commit-message) **proposes** an atomic Conventional Commit from the staged diff.
3. Commit runs ONLY if the user says "commit" (§4.4). "Done" is not approval. In `auto`, Crewforth hands the session the
   one-click approval question when crew-commit-agent is called: ask it with the message; the typed `/crew-approve` is
   for when no question is offered.
4. **Close the board item too** (`teamboard`), when one is held. Closing work is one movement: ask what shipped,
   run `board.sh done <id> "<note>"`, name the items it unblocked, and offer the next one as options. Do not
   leave this to the user to remember — a claim nobody closes reads to the whole team as still in progress, and
   the items behind it stay unclaimable. If a decision came out of this work that changes how other items must
   be done, record it with `board.sh decide` in the same breath; it is worthless in a session nobody else reads.

No destructive operations (§4.5). No AI trace / vendor name in the message (§4.1/§4.2 — the hook already scans).
