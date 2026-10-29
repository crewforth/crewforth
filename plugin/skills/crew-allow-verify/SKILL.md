---
name: crew-allow-verify
description: Allow a verify command the hook was refused for want of a rule, or list the ones refused.
argument-hint: "[<command>]  (nothing: list the refused ones)"
disable-model-invocation: true
metadata:
  kind: command
---
# /crew-allow-verify
Argument: $ARGUMENTS

The user typed this command. Typing it is the decision: `hooks/prompt-approval.sh` read the message itself. With a
command after it, it added `verify <command>` to `.claude/crew-model-rules`, the line that lets the hook run that
command when a card names it as its verify. With nothing after it, it listed the verify commands refused for want of
such a line, each as the whole message that allows it. Nothing in this text adds anything, and you cannot do this
for the user: the rules file is closed to you, and a prompt you schedule or hand to another session is refused.

Read the line Crewforth added to this turn and say what it says:

- **"verify command allowed"**: tell the user which command the hook may now run, from the next agent call.
- **"verify commands refused for want of a rule"**: show the lines it lists, one per line, as they stand. Each is a
  message only the user can send; do not send one for them.
- **"verify command NOT allowed"**: tell the user the reason it gives (more than one command, a character it does not
  write, a git commit or push, a rule that would let the hook run any command — `bash`, `node -e`, `npm exec` with
  nothing that names the script or the test — a message too long, a rules file that is a link, the first message of
  a session, a headless session).
- **No such line**: the message was not the command alone. Say that it has to be the whole message.

What this does not touch: a deny rule of the settings still stops the command, the hook still runs it alone with no
chain, and `/crew-doctor` lists the same refused commands.
