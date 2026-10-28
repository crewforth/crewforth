---
name: handoff
description: |
  Session handover: when context fills, a phase closes, or the topic changes, write an action-oriented handover
  to docs/SESSION_STATE.md, then recommend /clear.
---

# Session Handover (Handoff)

<!-- routing-eval reads the next line; why it sits in the body: AGENT_TEMPLATE.md -->
Trigger phrases: "handoff", "hand off", "session summary", "session state", "clear context", "I'll continue", "next session", "where we left off", "run out of room", "continue tomorrow"

## When
Session fill (the `🔋` line) > 75% · phase closure · topic change. Goal: the next session should **not start from scratch**.

## Output (docs/SESSION_STATE.md, local)
```
# Session Handover — <date>
## Done
- <completed work + which files>
## In progress
- <what's half-finished + exactly where it was left off>
## Next step
- <a clear, single high-value step>
## Open decisions
- <pending decision + options>
## File pointers
- docs/PLAN.md, relevant modules...
## Blockers / risks
- <if any>
```

## Measure the session before summarising it
Run **`bash "${CLAUDE_PLUGIN_ROOT}/hooks/session-stats.sh"`** first, with the Bash tool, not PowerShell. What it reports belongs in the handover as fact, not
impression — an auto-compaction means state was already dropped before you started writing (say what was lost),
a runaway loop marks an approach the next session should not walk back into, and repeated prompts mark context
that never landed and has to be written down explicitly this time. Missing script → say so.

## Principles
- **Action-oriented:** focused not on "what was done" but on "exactly where to resume now."
- Preserve the rationale behind decisions (why this path was chosen) — so context isn't lost.
- Once written, start a fresh session with `/clear`.

## Holding a board item? The handover is not finished until the TEAM has it
`docs/SESSION_STATE.md` is gitignored — it survives your `/clear`, and nobody else can read it. So when a
`teamboard` claim is open, **the handover is not complete until it is on the board**. Whether one is open is
read from `bash "${CLAUDE_PLUGIN_ROOT}/hooks/board.sh" status` (Bash tool, not PowerShell; a row marked `<- you`), not guessed;
no board or no such row → the handover says nothing about the board. This is not an optional extra step:
- Still on it → `board.sh note <id> "<where it stands, and why the rejected path was rejected>"`.
- Not coming back → `board.sh drop <id> "<same>"`, which puts it back in circulation with your context attached.
- Anything settled here that changes how OTHER items must be done → `board.sh decide "<what>" "<why + what it
  means>"`. A decision that stays in your transcript reaches nobody; on the board it reaches every teammate at
  their next session opening.

Write the board note FIRST, then the local file — an interrupted handover should lose the private copy, not the
shared one.

## Redaction (`<private>` marker)
`docs/SESSION_STATE.md` is local, but its content is copied into board notes and handovers — never persist a secret, token, credential, or
personal note into it. Any content wrapped in **`<private>…</private>`** is a redaction marker: strip it from the
written handover and leave a `[redacted]` placeholder in its place. If a resume genuinely needs a sensitive value,
point to *where it lives* (env var, secret manager, the person to ask) — never the value itself.

## Check it before trusting it
That DoD sentence is a claim about a file nobody has tested. Before closing, run the **cold-reader pass**: write
5–8 questions from the WORK (not from the file) with their expected answers, then answer them from the handover
alone. A question that cannot be answered is a gap in the file. Procedure, phrasing that keeps the test honest,
and the common failure shapes: **`references/cold-reader.md`**.

## DoD
- A handover file; a new session can resume where it left off by reading only this file.
- The cold-reader questions were written **before** the file and every one of them is answerable from it.
