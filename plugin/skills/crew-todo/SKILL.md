---
name: crew-todo
description: Open or close the plan's to-do panel under the status line; writes the plan file when it is missing and syncs it with this conversation's plan; pause or resume the plan.
argument-hint: "[on | off | show | status | pause | resume | <plan file>]  (nothing: open it if closed, close it if open)"
disable-model-invocation: true
metadata:
  kind: command
---
# /crew-todo
Argument: $ARGUMENTS

The user wants to see where the plan stands, and the plan in the file the panel reads. Run the script, bring the file
up to date with the plan made in this conversation, and pass on what the script prints.

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
- **`pause`** / **`resume`**: it sets the plan's `status:` line to `paused` / `active` (the only line it ever changes in
  a plan) and prints the one line. Paused, the plan is not the work in progress: the status line drops its count
  and the panel shows one line saying so, instead of a task nobody is working on.

**The plan file is always there.** When it is missing, the script writes an empty one first (a title, `status: active`,
a `## Tasks (order)` heading with no task under it) and says `todo: created <file>`; `off`, `status`, `pause` and
`resume` never create it.

**Then bring the file up to date with this conversation's plan** — after any argument but `off`, `status`, `pause` and
`resume`. The plan is the one made in this conversation: the plan approved in plan mode, the plan `crew-planner`
returned, or the steps agreed with the user, together with what changed since (a task added, split, dropped, finished,
started). The panel and Studio read only the file, so a plan that lives only in the conversation shows nowhere.

- Write each task as one short line with a box, under the plan's `Tasks` heading: `- [ ] <what>`; `[x]` for one whose
  check has passed, `[~]` for the one in work now (one at most). Keep the plan's phases as `###` headings when it has
  them. A longer note goes after ` — ` on the same line; the panel shows only what stands before it.
- Add the tasks the file is missing and change the boxes that moved. Never delete a task or text that is there: a
  dropped task stays, ticked and struck through with its reason (`- [x] ~~<what>~~ — dropped: <why>`).
- The file the script just created gets the plan's title in place of `# Plan`.
- A file that keeps several plans, one section each, is read at the last `Tasks` heading that holds a task. Add this
  plan as a new section at the bottom with its own `### Tasks` heading, so the panel shows this plan and not an older
  one.
- A file whose open tasks belong to other work is not this plan's to change: say so and ask whether to add this plan
  to it, replace it, or point the panel at a new file (`/crew-todo <file>`), as `spec-planning` does.
- With no plan in this conversation, change nothing: say the file is ready and that `/crew-plan` writes the plan.

When the file changed, run `bash <script> status` again and say its line instead of the first one.

What the panel reads is the plan's own boxes: `- [ ]` open (☐), `- [x]` done (✓), `- [~]` in work (◐), grouped under the
plan's headings as phases (only what is under its `## Tasks` heading, when it has one). With no task marked `[~]`, the
first open one is shown as `← next`, never as in work. A `status:` line in the plan's head that says `paused`,
`dropped` or `done` (and their synonyms) takes the plan off the panel. When the
plan's tasks carry no box, say that the panel counts only tasks with one, and that ticking them as the work goes is
the plan's rule (`spec-planning`).
