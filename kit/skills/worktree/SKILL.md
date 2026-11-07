---
name: worktree
description: |
  Isolate risky or parallel file-mutating work in a git worktree so the main tree's uncommitted changes are never
  clobbered. For fan-out agents that edit files, throwaway experiments, or any change you may want to discard cleanly.
---

# Worktree Isolation

<!-- routing-eval reads the next line; why it sits in the body: AGENT_TEMPLATE.md -->
Trigger phrases: "worktree", "git worktree", "isolate the changes", "sandbox this work", "parallel file edits"

One rule: **never let risky or parallel work run on top of uncommitted changes in the shared tree.** A git worktree
gives a second working copy of the same repo on its own branch — you experiment or fan out agents there, and the main
tree (with your in-progress edits) is physically untouched. Throw the worktree away and nothing you cared about is lost.

> **Crewforth adaptation (local, .claude/):** this exists because verification/fan-out subagents have discarded a session's
> **uncommitted** work by running a destructive git command over the shared tree. Those commands (`reset --hard`,
> `clean -f`, `checkout -- .`, `restore`) are §4.5-gated — but the real fix is to not put them near unsaved work.
> The Agent tool's `isolation: "worktree"` does this automatically for parallel mutating agents; reach for it there.

## When to isolate
- **Fan-out that writes files** — two+ agents editing the same repo in parallel would collide; give each its own worktree.
- **A throwaway experiment** — you might keep it or bin it; a worktree makes "bin it" a one-liner, not a `reset --hard`.
- **A dirty tree you can't commit yet** — you have unsaved work but need to try something risky; isolate rather than stash-and-pray.
- Skip it for a single, in-place edit on a clean tree — a worktree is overhead there.

## How
1. **Detect** — are you already in a worktree? `[ "$(git rev-parse --git-dir)" != "$(git rev-parse --git-common-dir)" ]` is true inside one; don't nest. A submodule answers true as well: when `git rev-parse --show-superproject-working-tree` prints a path, you are in a submodule, not a worktree.
2. **Create** — `git worktree add ../wt-<name> -b <branch>` (new branch) or `git worktree add ../wt-<name> <existing>`. It shares the object store, so it's cheap. Before `-b <branch>`, check `git show-ref --verify --quiet refs/heads/<branch>`: if the branch exists, do not reuse the name silently; ask whether to work on that existing branch. A branch you adopted that way is the user's, and cleanup never deletes it.
3. **Work there** — cd into it; edits, builds, and agent runs stay local to that copy. Run the project's test command once before the first edit and note the result, so a failure you see later is yours or was already there. `.claude/` is gitignored in most installs, so a worktree made with `git worktree add` has none: entering it with the EnterWorktree tool copies it in, and `/crew-doctor` names a worktree that still lacks it.
4. **Fold back or discard** — keep: commit on its branch, then merge. Discard: first look at what would be lost, `git -C ../wt-<name> status --porcelain` and `git log <upstream-or-base>..<branch> --oneline`. Uncommitted files or commits that exist nowhere else mean you list them and ask the user; `git worktree remove ../wt-<name>` only when both are empty, and `--force` only after the user has seen that list and said to drop it.
5. **Clean up** — `git worktree prune` removes stale entries. Never leave orphaned worktrees around. Delete only a branch you created for the worktree (`git branch -d`, which refuses an unmerged one), never one you adopted in step 2.

## Shared services
A database, dev server or queue the worktrees all use is shared state, not part of your copy.
- Reuse a service that is already up and healthy; start one only when none answers.
- Never stop or kill a process you did not start. Two worktrees share one machine, so the other one may be using it.
- Read the port the tool reports when it starts; don't assume the default, since the other worktree may already hold it.
- A test that destroys data (drops tables, clears a queue) gets its own database or namespace, never the shared one.

## Invariant rules
1. **Isolate before risk, don't revert after** — a worktree replaces "run `checkout -- .` to undo"; the undo is `worktree remove`.
2. **One worktree per parallel writer** — never two agents mutating the same tree at once.
3. **Don't nest** — creating a worktree from inside a worktree; detect first.
4. **Commit or isolate before delegating file-mutating work** — a subagent must never be able to discard the main tree's unsaved changes.
5. **Remove what you add** — no orphaned worktrees; `remove` + `prune` when done.
6. **Never remove what you have not looked at** — dirty files or unpushed commits in a worktree are the user's to drop, not yours; no `--force` and no `branch -D` without their word.
