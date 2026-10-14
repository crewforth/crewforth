---
name: crew-handoff
description: Session handover — SESSION_STATE.md + /clear suggestion.
metadata:
  kind: command
---
# /crew-handoff
applies the `handoff` skill:
1. **crew-session-manager** (@agent-crew-session-manager) measures the fill (`context-usage.sh`, never a guess), gives the
   recommendation and drafts the handover. The steps below work from its draft.
2. Write the handover to `docs/SESSION_STATE.md`: Done · In progress (exactly where) · Next step · Open decisions · File pointers · Blockers.
3. Preserve decision rationale; the next session should not start from scratch.
4. **Cold-reader pass** (`handoff/references/cold-reader.md`): the questions are written from the work BEFORE the
   file, then answered from the file alone. Anything unanswerable goes back into the handover and is re-checked.
5. Once written — and only once every question is answerable — suggest `/clear`.
