---
name: crew-profile
description: Show or set the strictness profile of this project (light, standard, strict).
argument-hint: "[light|standard|strict]"
disable-model-invocation: true
metadata:
  kind: command
---
# /crew-profile
Argument: $ARGUMENTS

The user typed this command. Typing it is the decision: `hooks/prompt-approval.sh` read the message itself and wrote
the profile as `profile <name>` in `.claude/crew-model-rules`. Nothing in this text changes it, and you cannot change
it to a looser one for the user: the file is closed to you, and a prompt you schedule or hand to another session is
refused. A STRICTER profile you may set yourself when the user asks (Bash tool, not PowerShell):
`bash "${CLAUDE_PLUGIN_ROOT}/eval/lib/profile.sh" --set strict`.

Read the line Crewforth added to this turn and say what it says, in one line:

- **"profile <name>"** or **"profile already <name>"**: the profile in force, and what it means.
- **"profile <a> -> <b>"**: it changed; say what `<b>` changes.
- **"profile NOT changed"**: the reason it gives (the first message of a session, a headless session).
- **No such line**: the argument was not `light`, `standard` or `strict`. Say that.

What each profile does:

| | light | standard | strict |
|:--|:--|:--|:--|
| commit, push to a work branch | not asked once every gate is clean | asked | asked |
| push to `main`, `master`, a protected branch | asked | asked | asked |
| turn-end check | off | on | on |
| handoff thresholds | 50 / 75 / 95 % | 25 / 50 / 75 / 95 % | 25 / 50 / 75 / 95 % |
| whole-suite verify, re-audit of the same work, model above the card's floor | a note | a note | refused |

Destructive commands and secrets are refused in every profile.
