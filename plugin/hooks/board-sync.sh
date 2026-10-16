#!/usr/bin/env bash
# SessionStart hook — put the TEAM's state into a session that would otherwise only know its own.
#
# The problem it closes: every teammate runs Crewforth locally, so "Ali took item #1 two hours ago" exists
# nowhere this session can see. This hook injects the board summary at the start of every session, which is the
# one moment the answer changes what happens next: which item to pick up, which one is blocked, which claim has
# gone quiet.
#
# Deliberate scope:
#   - Same event and channel as session-rehydrate.sh: SessionStart + hookSpecificOutput.additionalContext is the
#     documented way to put text into the model's context.
#   - Matched on startup|resume|clear|compact. Unlike the handover hook this DOES include `startup`: a stale
#     handover nags, but "who holds what right now" is exactly what a fresh session is missing.
#   - NO NETWORK IN THE FOREGROUND. The visible half reads one cache file and exits. When that cache is older
#     than CREW_BOARD_MAX_AGE the hook starts a DETACHED refresher (fetch + heartbeat) whose result is used by the
#     NEXT session. On an unreachable remote the session-start cost stays at zero.
#   - Fails OPEN and SILENT: no repo, no board, no cache -> no output, exit 0. It never blocks a session.
set -uo pipefail
# The 2.x names of the variables a user can set still work (one helper: eval/lib/crew-env.sh).
_crew_d="${BASH_SOURCE%/*}"; [ "$_crew_d" = "${BASH_SOURCE}" ] && _crew_d=.
[ -f "$_crew_d/../eval/lib/crew-env.sh" ] && . "$_crew_d/../eval/lib/crew-env.sh"; unset _crew_d

# Two intervals, because two very different repos run this hook. Where a board exists, 15 minutes keeps the view
# worth acting on. Where none does — every solo project, and every install that upgraded into this feature — the
# only thing a refresh can do is ask the remote for a ref nobody has created, so it backs off to once a day.
# Without that split, a repo that will never have a board opened a background fetch at every session start.
MAX_AGE="${CREW_BOARD_MAX_AGE:-900}"
MAX_AGE_NOBOARD="${CREW_BOARD_MAX_AGE_NOBOARD:-86400}"

HERE="$(cd "$(dirname "$0")" && pwd)"
SELF="$HERE/$(basename "$0")"

# ---- detached half: the only place this hook is allowed to touch the network -----------------------------------
if [ "${1:-}" = "--refresh" ]; then
  cd "${2:-.}" 2>/dev/null || exit 0
  bash "$HERE/board.sh" sync >/dev/null 2>&1 || exit 0
  bash "$HERE/board.sh" beat >/dev/null 2>&1 || true
  exit 0
fi

# ---- foreground half: one file read, then a decision -----------------------------------------------------------
[ -n "${CREW_NO_BOARD:-}" ] && exit 0

IN=""
[ ! -t 0 ] && IN="$(cat 2>/dev/null || true)"
ROOT="${CLAUDE_PROJECT_DIR:-}"
[ -n "$ROOT" ] || ROOT="$(printf '%s' "$IN" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
[ -n "$ROOT" ] || ROOT="$PWD"
# Windows hands this over as a native path and the stdin copy arrives JSON-encoded on top (`C:\\Repos\\app`).
# Undo the escaping, then fold the separators; both are no-ops on POSIX.
ROOT="${ROOT//\\\\//}"; ROOT="${ROOT//\\//}"

cd "$ROOT" 2>/dev/null || exit 0
GITDIR="$(git rev-parse --git-common-dir 2>/dev/null)" || exit 0
[ -n "$GITDIR" ] || exit 0

CACHE="$GITDIR/crew-board-cache"
STAMP=0
[ -f "$CACHE.at" ] && STAMP="$(tr -cd '0-9' < "$CACHE.at" 2>/dev/null)"
[ -n "$STAMP" ] || STAMP=0

# A non-empty cache means a board was found here; an absent or empty one means there is nothing to keep fresh.
# Costs no extra process: the same test decides, below, whether there is anything to say.
[ -s "$CACHE" ] || MAX_AGE="$MAX_AGE_NOBOARD"

NOW="$(date -u +%s 2>/dev/null || echo 0)"
if [ "$NOW" -gt 0 ] && [ "$((NOW - STAMP))" -gt "$MAX_AGE" ]; then
  # stdin/stdout/stderr all detached: an inherited stdout keeps the hook's pipe open after it exits, and the
  # caller then waits to EOF on a fetch that has nothing to do with it.
  bash "$SELF" --refresh "$ROOT" </dev/null >/dev/null 2>&1 &
fi

# Never invent a board state. No cache (no board here, or every refresh so far failed) -> stay silent.
[ -s "$CACHE" ] || exit 0

# /crew-board is user-only, so the command Claude can run itself comes first (the plugin's copy names its path).
if [ -f "$HERE/../.claude-plugin/plugin.json" ]; then _BS="bash \"$HERE/board.sh\" sync"; else _BS='bash .claude/hooks/board.sh sync'; fi
MSG="$(cat "$CACHE")
Board state above is a cached snapshot; $_BS (Bash tool, not PowerShell — or the user can type /crew-board sync) refreshes it."

# ONE PATH, no jq. The JSON is built here on every machine, so a Mac with jq and a Windows box without it emit the
# same bytes, through Crewforth's one escaper (eval/lib/json-string.awk: jq-identical, measured; why, in its header).
ESC="$(printf '%s\n' "$MSG" | LC_ALL=C awk -f "$HERE/../eval/lib/json-string.awk")"
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$ESC"
exit 0
