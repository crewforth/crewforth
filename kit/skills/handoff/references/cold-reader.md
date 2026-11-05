# The cold-reader pass

Loaded on demand. SKILL.md's DoD says a new session can resume by reading only the handover file. This is how
that sentence is checked instead of asserted — and it is the only part of the handover that can fail silently:
a file that reads well to its author reads well *because* the author remembers what it leaves out.

## The rule the pass exists to enforce

**Write the questions before you write the file, from the work — not from the file.** An answer key derived
from the handover only proves the handover is self-consistent. Derived from the session, it proves the handover
carries the session.

## Procedure

1. **Before writing the handover**, list 5–8 questions the next session must be able to answer to continue. Take
   them from the work itself: what was decided and why, what is half-finished and exactly where, what was ruled
   out, what breaks if it is touched, what the next action is. Write the expected answers down beside them.
2. **Write the handover** as usual.
3. **Answer the questions from the handover alone.** The consumer may open only the paths the file itself names
   — the template requires a file-pointers section, so following those pointers *is* the file working. It may
   not use the session's memory, search the repository for context the file never mentions, or ask.
4. **Score each question**: answered · partly answered · not answerable. Any "not answerable" is a gap in the
   handover, not in the reader.
5. **Fix the file and re-answer** the failed questions. The pass closes when every question is answerable.

## Phrasing that keeps the test honest

- **Do not reuse the handover's own words in the question.** "What did we decide about the cache?" is answerable
  by keyword-matching the heading; "What happens to a request that arrives while the cache is rebuilding?" is
  not. A question a reader can answer by lifting a phrase has measured the search, not the content.
- **Ask for the reason, not the label.** "Which approach was chosen" is a lookup. "Why was the other one
  rejected" is what a resuming session actually needs, and it is what handovers most often drop.
- **Ask at least one question whose answer is a location** — a file, a branch, a command. Handovers routinely
  describe a state that nothing points at.
- **Ask the two questions that guard against repeating the past:** "Which approach must not be tried again,
  and why?" (could a fresh agent walk back into a failed one from this file?) and "What did the previous handover
  leave open, and where does it stand now?" (a decision carried in silence is lost).

## Who runs it

Wherever the handover is written — usually inside `crew-session-manager`, which the discipline routes this
through, sometimes the main thread. No Crewforth agent holds the delegation tool (every shipped agent declares an
explicit allowlist and none contains it), so an agent that writes the handover answers its own questions: the
same context that wrote the file reads it, and the discipline is entirely in step 1 (questions from the work,
written first) and step 3 (answer from the file only).

**The main thread does hold it, and that is the stronger pass.** When the main thread wrote the file (or holds it
after the agent returns), it can hand a fresh `general-purpose` subagent the file path and the questions, and
nothing else: no summary, no hint of the answers. What that reader cannot answer, the file does not carry. The same
pass fits any document written for a later reader — `docs/PLAN.md` (`spec-planning`), an ADR (`adr`). Another
session, a teammate or a fresh window opened at the file serve too; the procedure is unchanged.

## What a failure looks like

The common ones, in the order they occur: the "in progress" entry names a task but not the line it stopped at;
a decision is recorded without the alternative it beat; a blocker is described without who or what unblocks it;
and the next step is a category ("continue the refactor") rather than an action. Each of those passes a reading
by its author and fails a cold reader.
