# An unattended agent job in CI

A coding agent run by the pipeline (fix a failing check, update a snapshot, triage an issue) works with nobody
watching. It reads text from the PR and the logs that anyone can influence, and its output lands back in the repo.
Treat it as an untrusted contributor with a fast keyboard.

## The run
- **Pinned.** The agent CLI and every action around it are pinned to an exact version (an action to a full SHA). An
  unpinned CLI changes behaviour between two runs of the same commit.
- **Few tools.** Allow only the tools the task needs: read, edit inside the allowed paths, run the named test
  command. No network fetch, no shell beyond that command, no package install unless the task is the install.
- **An isolated copy.** Run it in a fresh checkout or worktree, not in the job's main workspace, with no
  credentials beyond the model key. The environment is reduced to the key, `PATH` and `HOME`; the job's other secrets
  never reach it.
- **Keep the project's gates on.** Crewforth's hooks still run inside the agent's session in CI. Restrict tools and
  output paths instead of disabling hooks to make the run quieter.
- **Untrusted input stays a file.** A failure log, PR body or issue text is given as a read-only file the prompt names
  as data, never pasted into the prompt as instructions.

## Bringing the result back
- **An allowlist of paths.** Copy back only files under the paths the task may change. Refuse a symlink, a new
  executable, a mode change, a path with `..`, and anything under `.github/`, `.claude/` or the hooks folder.
- **The caller validates meaning, not the exit code.** The agent saying it succeeded is not a result. Re-run the
  check it was asked to fix, and diff what changed against what it was allowed to change.
- **A cap on repair commits.** One or two attempts per run, then stop and report. A loop of agent commits on a PR is
  a cost and a review burden.
- **A deterministic fallback.** When the agent fails or times out, the job does the plain thing (leave the check
  red, post the log link). It never merges, approves or retries forever.

## Never
- Give the job a token that can push to a protected branch, approve, or merge.
- Run it on `pull_request_target` with the PR's code checked out.
- Let it edit the workflow that runs it.
