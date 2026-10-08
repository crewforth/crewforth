---
name: crew-approve
description: Approve the commit or push Claude just showed you (auto and dontAsk modes).
argument-hint: "[commit | push | commit+push]"
disable-model-invocation: true
metadata:
  kind: command
---
# /crew-approve
Argument: $ARGUMENTS

The user typed this command. Typing it is the approval: `hooks/prompt-approval.sh` read the message itself and
recorded it, tied to what is staged, to `HEAD` and to this session, for 30 minutes or until the user's next
message. Nothing in this text records anything, and you cannot give this approval for the user.

Read the line Crewforth added to this turn and do what it says:

- **"approval recorded"**: run exactly what it names, each command alone in its call. A commit is
  `git commit -m '…'` with the message you showed (single-quoted, or from a here-document with a quoted delimiter);
  a push is `git push <remote> <branch>`. The review record of §4.6 is still required.
- **"approval NOT recorded"**: tell the user the reason it gives, and run nothing.
- **No such line**: the session is in a mode where the gate asks the user itself (`default`, `acceptEdits`), or
  the argument was not `commit`, `push` or `commit+push`. Say which, and in the first case run the command and let
  the gate's own prompt ask.

Force-push and the rest of §4.5 are not opened by this.
