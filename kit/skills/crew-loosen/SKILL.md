---
name: crew-loosen
description: Lower a model floor that Crewforth raised for a class of work (one model, once).
argument-hint: "<agent> <change> <risk>"
disable-model-invocation: true
metadata:
  kind: command
---
# /crew-loosen
Argument: $ARGUMENTS

The user typed this command. Typing it is the decision: `hooks/prompt-approval.sh` read the message itself and
lowered the calibration floor of that class of work (agent × change × risk) by one model, in
`.claude/state/crew-model-loosened.tsv`. Nothing in this text lowers anything, and you cannot do this for the user:
the file is closed to you, and a prompt you schedule or hand to another session is refused.

Read the line Crewforth added to this turn and say what it says:

- **"floor lowered"**: tell the user from which model to which, and that the class is counted afresh: if its first
  try fails too often again, the floor rises again.
- **"floor NOT lowered"**: tell the user the reason it gives (no raised floor on record for that class, already
  lowered once, the first message of a session, a headless session).
- **No such line**: the arguments were not `<agent> <change> <risk>`: a `crew-…` agent, a kind of change from the
  card (`feature`, `fix-known`, `test-write` …) and `critical` or `normal`. Say that, with the three as they stand
  in `.claude/state/crew-model-floors.auto`.

What this does not touch: critical work still runs on opus, work with no verify command on sonnet or above, and
an agent's own floor stays. Only the floor that the record of outcomes raised is lowered.
