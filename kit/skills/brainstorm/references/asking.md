# Asking the user — what is worth a question, and how to put it

The discipline says to ask at every decision point with `AskUserQuestion`. This file says what a decision point
is, and how to put one so the answer settles something.

## Facts are yours, decisions are theirs
- **Never ask for a fact the workspace, the docs or the web can answer**: the ORM, the test runner, the Node
  version, where a file lives. Read it, then state it.
- If the options differ only in how the code does it, and a user would see the same behaviour either way, it is
  not their decision. Pick, and say what you picked.
- A decision is theirs when it changes what someone sees or pays: scope, behaviour, data kept or shown, cost, risk,
  a trade-off between two things they want.

## Is it worth asking?
A question earns its place when all three hold:
1. **The answer changes the outcome.** If every answer leads to the same next step, do not ask.
2. **It is about this work**, not a principle ("do you value maintainability?").
3. **It is not asked already.** Never ask again what was answered in this session or recorded in the project.

Where to look for the questions that matter: the empty state, the error state, two people at once, existing data
when the shape changes, and the default when nobody chooses. When two things the user said pull against each
other, quote both and ask which wins.

## Putting the question
- **One `AskUserQuestion` call, at most 4 questions, and only questions that do not depend on each other.** A
  question whose options depend on another answer waits for the next call.
- **Options are behaviour, not mechanics.** "A saved draft survives closing the tab" beats "use localStorage".
- **Recommended option first**, marked as recommended, with a one-line reason. The user should be able to agree
  in one click.
- A concrete case beats an abstract choice: "a refund on an order shipped in two parts" is answerable;
  "refund granularity" is not.

## Confirming an inference
When you can infer the answer, do not ask an open question: state the inference and let the user confirm it.
The statement is the question: "Looks right" / "Off base" (and what to change). Read the answer four ways: a
yes, a no, a correction (take the correction, not your inference), or a new constraint (add it, then re-check
what it changes).

## When the answer does not come
- **A skipped question becomes a recorded assumption.** Write it down where the plan or brief keeps its
  assumptions, so it can be revisited, and go on.
- **A whole round skipped means stop asking.** Proceed on the recorded assumptions and say so.
- **"I don't know"** means the question was framed wrong. Re-ask it from what the user would see, not from how it
  is built.
- **No one can answer** (`auto` mode with no person attending, `/loop`, a scheduled or headless run): do not
  interview. Take the recommended option for each open decision, record it as an assumption, and list the
  assumptions at the top of what you hand over.
