---
name: crew-update
description: Check for a newer version, update, report what changed, then prompt /clear to reload.
metadata:
  kind: command
---
# /crew-update
Bring the Crewforth install up to the latest published version:
1. **Detect install type.** If `.claude/VERSION` exists → a full install (steps below). If Crewforth runs as a
   **plugin** (no `.claude/VERSION`), it updates through the plugin system: run
   `claude plugin update crewforth@crewforth`, tell the user it applies when they restart Claude Code, and stop here.
2. **Current version:** read `.claude/VERSION`.
3. **Latest version:** `npm view crewforth version` (needs network). If it can't be reached,
   say so and stop — don't guess.
4. **Compare.** Already on the latest → report "up to date (vX)" and stop. Otherwise show **old → new**.
5. **Before:** run `bash .claude/eval/update-guard.sh pre` (Bash tool, not PowerShell). It records what is on disk (in `.claude/.state/`, nothing
   else) and prints one of three verdicts:
   - `clean` → nothing to report, go on.
   - `UNCOMMITTED:` with the changed paths in `.claude/` and `CLAUDE.md` → show the user that list and **ask** —
     with your question tool — whether to go ahead (the update rewrites Crewforth-owned files under `.claude/`), commit
     or stash first, or stop. Continue only on their yes.
   - `NOT IN GIT:` (a private install gitignores `.claude/` and `CLAUDE.md`, so edits there cannot be detected) →
     pass its two lines to the user and go on; there is nothing to commit.
6. **Update** — this rewrites Crewforth-owned files under `.claude/` (your `./CLAUDE.md` and project skills are
   preserved). **Show this plan first, then run:** `npx --yes crewforth@latest update --here --yes`.
   Two DIFFERENT `--yes` flags, both required for a non-interactive run: the one **before** the package name is
   **npx's own** — it auto-confirms npx's `Ok to proceed?` install prompt, which reads the real TTY and IGNORES piped
   input, so without it the command hangs before Crewforth even starts. The `--here --yes` **after** the package go to
   the updater (`--here` = apply on the current branch, `--yes` = accept the smart defaults). Together they let it run
   to completion instead of blocking on a prompt your shell can't answer.
   If you'd rather review each handover decision yourself, tell the user to run `npx crewforth@latest update`
   (no flags) in **their own terminal**, where both the npx and the interactive prompts work.
7. **After:** run `bash .claude/eval/update-guard.sh post` (Bash tool, not PowerShell) and show the user its lists — added, changed, moved,
   removed.
8. **Verify:** run `CREW_NO_STAR=1 bash .claude/eval/doctor.sh` (Bash tool, not PowerShell) so a bad/partial update surfaces immediately; the updater has already shown the star line, if it was due.
   If the updater's or doctor's output contains a line starting with ⭐, pass it to the user verbatim as the LAST
   line of your summary — it prints once per Crewforth version, and it is meant for the user, not for you.
9. **Report** old → new + the headline changes. Take them from `.claude/.state/whats-new.md` — the updater writes
   there the installed package's own CHANGELOG sections between the old and the new version. Do not fetch release
   notes from the network. No file → say no release notes were included.
10. **Reload (manual — a command can't do it itself):** the discipline in the running session is still the OLD one.
   Tell the user to run **`/clear`** (or quit and relaunch Claude Code): a new session loads the updated
   `.claude/DISCIPLINE.md`.
