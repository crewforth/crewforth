#!/usr/bin/env bash
# SessionStart hook — after a context boundary (compact / clear / resume), point the model back at the handover
# so in-progress work survives the boundary. This closes Crewforth's handoff loop: `handoff` writes
# docs/SESSION_STATE.md → the user runs /clear (or context auto-compacts) → a fresh context starts → THIS hook
# re-surfaces the file so the next turn resumes from it instead of from zero.
#
# Deliberate scope (honest, spec-grounded):
#   - SessionStart is the right event: its stdout / hookSpecificOutput.additionalContext is injected into the
#     model's context (docs: "Re-inject context after compaction"). PreCompact is NOT used — it can only block
#     compaction, not add instructions to the summary, and blocking is not what we want.
#   - The HANDOVER is offered on compact|clear|resume|fork only, NOT on startup: those are explicit "continue where I
#     left off" boundaries, while startup fires on every unrelated session open and would keep surfacing a stale
#     handover — that would nag. The hook itself also runs on startup, for the language line below; it reads the
#     payload's `source` to tell the two apart (no `source` -> treated as a boundary, the pre-3.0 payload shape).
#   - THE LANGUAGE LINE. A project installed in Turkish (`lang=tr` in .claude/kit.conf) is told so at every session
#     start: reply in Turkish unless the user writes in another language. The RC-2 rehearsal typed a bare
#     `/crew-doctor` in a Turkish install: the doctor printed Turkish and the summary came back in English, because a
#     bare command has no word to take the language from. An English install adds nothing (English is the default).
#   - CLAUDE.md itself reloads on /compact and /clear on its own, so this hook does NOT re-inject the discipline —
#     only the session-specific state the reload can't recover.
#   - THE GIT HOOKS LINE. Where the hooks are installed but git is not pointed at them, the session is told (below).
#   - Fails OPEN and SILENT: no handover file, no output. It never blocks the session (always exits 0).
set -uo pipefail
IN="$(cat 2>/dev/null || true)"

# Project root: CLAUDE_PROJECT_DIR (set for hooks) → cwd from the stdin JSON → PWD.
ROOT="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$ROOT" ]; then
  ROOT="$(printf '%s' "$IN" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
fi
[ -n "$ROOT" ] || ROOT="$PWD"
# Windows hands both CLAUDE_PROJECT_DIR and the stdin `cwd` over as native paths (`C:\Repos\app`), and the stdin
# one arrives JSON-ENCODED on top of that — `C:\\Repos\\app`. Slicing it out with sed keeps the doubled
# backslashes, so ROOT pointed at a directory that cannot exist and the hook silently rehydrated nothing.
# Undo the JSON escaping first (`\\`), then fold any lone separator. Both are no-ops on a POSIX path.
ROOT="${ROOT//\\\\//}"; ROOT="${ROOT//\\//}"

SRC=""
case "$IN" in *'"source"'*) SRC="${IN#*\"source\"}"; SRC="${SRC#*\"}"; SRC="${SRC%%\"*}" ;; esac

LANGMSG=""
if [ -f "$ROOT/.claude/kit.conf" ]; then
  while IFS= read -r _l || [ -n "$_l" ]; do
    case "${_l%$'\r'}" in lang=tr) LANGMSG="This project was installed in Turkish (lang=tr in .claude/kit.conf). Reply in Turkish unless the user writes in another language, including after a bare command such as /crew-doctor. Commands, paths, file names and identifiers stay as written." ;; esac
  done < "$ROOT/.claude/kit.conf"
fi

MSG=""
STATE="$ROOT/docs/SESSION_STATE.md"
if [ "$SRC" != startup ] && [ -s "$STATE" ]; then
MSG="A session handover from before this context boundary exists at docs/SESSION_STATE.md. If the user's request continues that work, read it first — it holds the in-progress task state, open decisions, and the intended next step — and do not restart from scratch. If the request is about something else, do not bring it up."
fi
[ -n "$LANGMSG" ] && MSG="${MSG:+$MSG }$LANGMSG"

# THE GIT HOOKS ARE NOT CONNECTED. pre-commit and commit-msg run only when core.hooksPath points at them (or at
# .claude/git-shim, which runs them and then the project's own). An install made before `git init`, and every clone of
# a repository that shares .claude/, starts without that setting (measured: a field project, and v3.0.0 again in three
# orders). The tool-level gates still judge a commit made through Claude Code; a commit typed in a terminal is scanned
# by nothing. Crewforth does not change git's configuration by itself, so the session is told, once at each start,
# and the user decides. Only where the hooks are installed and this is a repository; two git calls, at session start.
HOOKMSG=""
if [ -f "$ROOT/.claude/hooks/pre-commit" ] && git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  _hp="$(git -C "$ROOT" config --get core.hooksPath 2>/dev/null || true)"; _hp="${_hp%$'\r'}"; _hp="${_hp//\\//}"
  case "${_hp%/}" in
    .claude/hooks|*/.claude/hooks|.claude/git-shim|*/.claude/git-shim) ;;
    '') HOOKMSG="Crewforth's git hooks are not connected in this repository: core.hooksPath is not set, so a commit made outside Claude Code is not scanned for traces, secrets or size. Tell the user once, in one line. The fix is theirs to run in their own terminal, not yours: git config core.hooksPath .claude/hooks, or the Crewforth update when the repository has hooks of its own. /crew-doctor shows the state." ;;
    *)  HOOKMSG="Crewforth's git hooks are not connected in this repository: core.hooksPath points at another hook directory, so a commit made outside Claude Code is not scanned for traces, secrets or size. Tell the user once, in one line. The fix is theirs to run in their own terminal, not yours: the Crewforth update keeps that directory's hooks and runs Crewforth's before them. /crew-doctor shows the state." ;;
  esac
fi
[ -n "$HOOKMSG" ] && MSG="${MSG:+$MSG }$HOOKMSG"
[ -n "$MSG" ] || exit 0   # no handover to offer and nothing to say about language -> stay silent

# hookSpecificOutput.additionalContext is the documented channel that injects text into the model's context.
# ONE PATH, no jq: MSG is built from fixed constants with no quote, backslash, control character or newline, so it needs no
# escaping and every machine emits the same bytes. If you ever make MSG dynamic, escape it the way board-sync.sh
# does (jq-identical, measured) — a raw quote or tab here makes JSON the CLI silently drops.
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$MSG"
exit 0
