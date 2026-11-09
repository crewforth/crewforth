---
name: crew-todo
description: Open or close the plan's to-do panel under the status line — done tasks ticked, the one in work marked ◐, open ones boxed; pause or resume the plan.
argument-hint: "[on | off | show | status | pause | resume | <plan file>]  (nothing: open it if closed, close it if open)"
disable-model-invocation: true
metadata:
  kind: command
---
# /crew-todo
Argument: $ARGUMENTS

The user wants to see where the plan stands. Run one command and pass on what it prints; change nothing else.

The script is `${CLAUDE_PLUGIN_ROOT}/eval/lib/todo.sh` if that names a real path (the plugin), else
`.claude/eval/lib/todo.sh`. From the project root, with the Bash tool (not PowerShell):

```
bash <script> $ARGUMENTS
```

- **Nothing, `on`, `off`, or a file name**: it opens or closes the panel (a file name also makes the panel read that
  plan from now on, instead of `docs/PLAN.md`) and prints one line: open or closed, which file, how far. Say that
  line. The panel shows at the status line's next refresh, under Crewforth's status line; when the script adds a
  `note:` that this project's status line is another one, or none, say the note too.
- **`show`**: it prints the panel once. Show its lines in a code block, exactly as printed.
- **`status`**: say the one line.
- **`pause`** / **`resume`**: it sets the plan's `status:` line to `paused` / `active` (the only line it ever writes in
  the plan) and prints the one line. Paused, the plan is not the work in progress: the status line drops its count
  and the panel shows one line saying so, instead of a task nobody is working on.

What the panel reads is the plan's own boxes: `- [ ]` open (☐), `- [x]` done (✓), `- [~]` in work (◐), grouped under the
plan's headings as phases (only what is under its `## Tasks` heading, when it has one). With no task marked `[~]`, the
first open one is shown as `← next`, never as in work. A `status:` line in the plan's head that says `paused`,
`dropped` or `done` (and their synonyms) takes the plan off the panel. When the
plan's tasks carry no box, say that the panel counts only tasks with one, and that ticking them as the work goes is
the plan's rule (`spec-planning`).
