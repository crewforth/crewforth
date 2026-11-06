---
name: crew-interview
description: Interview me before we plan — one question at a time, a recommended answer first, until the goal, the user and what done means are agreed.
argument-hint: "[the idea or request to pin down]"
disable-model-invocation: true
metadata:
  kind: command
---
# /crew-interview
Argument: $ARGUMENTS

For an ask that is still fuzzy ("grill me on this", "I'm not sure what I want"), pin it down before anything is
planned or built. **Do not write code here.** How to ask, what is worth asking and what never is:
`brainstorm/references/asking.md`. If that file is missing or unreadable, say so and name the path, then stop:
do not improvise the rules.

1. **Read first.** Look at the code, the docs, the Crew Map (`.crewforth/crew-map.json`, if there is one) and the
   project's CLAUDE.md for everything the request touches. Every fact found there is stated, never asked.
2. **Interview, one decision per turn.** Each turn is one `AskUserQuestion` call. Its first option is your best
   guess, marked as recommended, with a one-line reason. Ask in this order, skipping what you already know:
   - **Outcome:** what is different for someone when this is done?
   - **User:** who is that someone, and what are they doing when they need it?
   - **Why now:** what happens if this waits?
   - **Success:** what would you check to say it worked? A number or an observable behaviour, not "it works".
   - **Constraint:** what must not change, and what it may not cost (time, money, a dependency, data)?
   - **Out of scope:** what is it NOT, so the plan does not grow?
   Then the decisions this request raises: the empty and error states, existing data, two people at once, the
   default when nobody chooses.
3. **Stop when the answer is clear, not when the list runs out.** Clear means you could write the brief below
   without a guess in it. A skipped question becomes a recorded assumption; a skipped round ends the interview.
4. **Restate and get a yes.** Show the brief and ask, as the last question, "Is this what we are building?"
   ("Yes" first). A correction goes back into the brief and the question is asked again. Only an explicit yes
   ends the interview.
5. **Hand over.** Write the agreed brief to `docs/BRIEF.md`:
   - Outcome, User, Why now, Success, Constraint, Out of scope, each in one or two lines;
   - the decisions made, each with the option the user picked;
   - the assumptions, each marked as one.
   Then offer `/crew-plan` on it. A choice between real directions still open goes to `/crew-brainstorm` first.

**Nobody to answer** (`auto` with no one attending, `/loop`, a scheduled or headless run): do not interview.
Write the brief from what you read, take the recommended option for every open decision, mark each as an
assumption, and list them at the top.
