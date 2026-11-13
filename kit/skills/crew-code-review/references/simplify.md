# Simplify, when the built-in `/simplify` is shadowed or absent

Loaded on demand. The DoD runs `/simplify` before review; where the host's own command is missing, or a project skill
of the same name hides it, crew-review-agent runs these passes instead.

## The one rule
**Behaviour does not change.** A simpler version that answers differently for any input (an empty list, null, a
negative number, a duplicate, an error path) is a different change, not a simplification. When a rewrite would
change behaviour, either keep the original or name the difference in the report as a behaviour change for the user
to accept.

## What a pass looks for, inside the diff only
- Code the diff duplicates from something that already exists in the project: reuse it.
- A branch, flag or parameter nothing in the diff or its callers can reach.
- A helper used once, whose name says less than its body.
- Nesting that an early return removes; a loop the language's own operation states in one line.
- Comments that repeat the line under them.

## What a pass never does
- **Delete what it cannot explain.** A check, a sleep, a retry or a strange-looking branch may be the fix for a bug
  nobody wrote down. Find why it is there (`git log -L`, the blame, the test that covers it) before removing it;
  if you cannot, leave it and mention it.
- Reach outside the diff: code the change did not touch is a separate task, named, not done.
- Rename public names, change signatures, or reorder output others depend on.

## Report
Per change: `file:line · what was simplified · behaviour: unchanged` (or the exact difference). When a pass found
nothing worth changing, say so in one line; that is a result.
