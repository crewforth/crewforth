#!/usr/bin/env bash
# statusline.sh — Crewforth's status line: one line, from what Claude Code hands it on stdin and what the hooks
# have already written. It decides nothing and blocks nothing; it only says.
#
#   🛡 BLOCK §4.2 · ✓ commit approved 24m · ⚙ 2 crew agents · 🔋 34% · ~$1.20
#
# Each part is shown only when there is something to say, and only for THIS session:
#   🛡  the gate's last word in this session: the last line of the gate log, if it was written after the session's
#       first status line (the log carries no time, so a line from last week must not read as now)
#   ✓   an approval the user gave for a commit or a push that still holds (the record prompt-approval.sh keeps in
#       the git directory, 30 minutes, emptied at the user's next message)
#   ⚙   crew agents started in this session that have not stopped yet (model routing's records)
#   🔋  the context fill Claude Code measured (context_window.used_percentage), never an estimate
#   ~$  what Claude Code puts the session's cost at (cost.total_cost_usd), at API list price
#
# Wired by the installers only where no status line is set already (theirs is never replaced), from
# statusline.settings.json beside this file.
# COST. Claude Code runs this after every change, debounced at 300 ms. Measured: awk (the stdin JSON) and tail (the
# gate log), and on bash older than 4.2 one date; the rest is builtins. No git, no jq, no python.
set -u
_here="${BASH_SOURCE%[/\\]*}"; [ "$_here" = "${BASH_SOURCE}" ] && _here=.

# --install, from the project root: put this status line into .claude/settings.json only where NO status line is
# set (the project's settings, its local settings, or the user's own); a user's line is never replaced, because
# the project's setting would win over it. Prints one word: installed · kept (one is set) · none (no settings.json)
# · failed (the file is left as it was). A managed settings layer is not read. The merge is Crewforth's own JSON reader.
if [ "${1:-}" = --install ]; then
  # The setting itself is data beside this file (statusline.settings.json); the rule for putting a default in is
  # one helper, shared with the subagent model's default.
  exec bash "$_here/settings-default.sh" --install statusLine "$_here/statusline.settings.json"
fi

IFS= read -r -d '' IN || true
[ -n "$IN" ] || exit 0
# One read of the four values the line needs.
F="$(printf '%s' "$IN" | awk -v op=gets -v 'path=session_id|context_window.used_percentage|cost.total_cost_usd|workspace.project_dir' -f "$_here/settings-json.awk" - 2>/dev/null)" || F=""
IFS=$'\t' read -r SID PCT COST PDIR <<< "$F"
# The reader prints a string with its quotes; taken off by expansion, not a subshell (this runs every few seconds).
SID="${SID:-}"; SID="${SID#\"}"; SID="${SID%\"}"; PDIR="${PDIR:-}"; PDIR="${PDIR#\"}"; PDIR="${PDIR%\"}"
case "$SID" in ''|*[!A-Za-z0-9._-]*) SID="" ;; esac
[ -n "$PDIR" ] && [ -d "$PDIR/.claude" ] && cd "$PDIR" 2>/dev/null

OUT=()
# The session's baseline: made on its first status line. What is newer than it happened in this session.
BASE=""
if [ -n "$SID" ] && [ -d .claude ]; then
  BASE=".claude/state/statusline/$SID"
  if [ ! -e "$BASE" ]; then
    mkdir -p .claude/state/statusline 2>/dev/null
    : > "$BASE" 2>/dev/null || BASE=""
  fi
fi

# 🛡 The gate's last word in this session.
GL="${CREW_GATE_LOG:-.claude/gate-log.tsv}"
if [ -n "$BASE" ] && [ -f "$GL" ] && [ "$GL" -nt "$BASE" ]; then
  last="$(tail -n 1 "$GL" 2>/dev/null)"
  IFS=$'\t' read -r verdict section _ <<< "$last"
  case "$verdict" in BLOCK|ASK|ALLOW|NOTE) OUT+=("🛡 $verdict ${section:-}") ;; esac
fi

# ✓ An approval that still holds: the record is in the git directory (a worktree's .git is a file naming it).
G=""
if [ -d .git ]; then G=".git"
elif [ -f .git ]; then IFS= read -r l < .git 2>/dev/null; case "$l" in "gitdir: "*) G="${l#gitdir: }"; G="${G%$'\r'}" ;; esac; fi
if [ -n "$G" ] && [ -s "$G/crewforth-approval" ]; then
  op=""; ts=""
  while IFS='=' read -r k v; do v="${v%$'\r'}"; case "$k" in op) op="$v" ;; ts) ts="$v" ;; esac; done < "$G/crewforth-approval"
  if [ "${BASH_VERSINFO[0]}" -ge 5 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then printf -v now '%(%s)T' -1; else now="$(date +%s)"; fi
  case "$ts" in ''|*[!0-9]*) ;; *)
    left=$(( (1800 - (now - ts)) / 60 ))
    case "$op" in commit|push|commit+push) [ "$left" -ge 0 ] && [ "$((now - ts))" -le 1800 ] && OUT+=("✓ $op approved ${left}m") ;; esac ;;
  esac
fi

# ⚙ Crew agents started in this session and not stopped: a record under agents/ with no result beside it.
if [ -n "$BASE" ] && [ -d .claude/state/crew-model/agents ]; then
  n=0
  for a in .claude/state/crew-model/agents/*; do
    [ -f "$a" ] || continue
    case "$a" in *.claim|*.used) continue ;; esac
    [ "$a" -nt "$BASE" ] || continue
    [ -e ".claude/state/crew-model/results/${a##*/}" ] && continue
    n=$((n + 1))
  done
  pl=s; [ "$n" -eq 1 ] && pl=""
  [ "$n" -gt 0 ] && OUT+=("⚙ $n crew agent$pl")
fi

# 🔋 and ~$: Claude Code's own numbers, shown as they are.
case "${PCT:-}" in ''|null|*[!0-9.]*) ;; *) OUT+=("🔋 ${PCT%%.*}%") ;; esac
case "${COST:-}" in ''|null|*[!0-9.]*) ;; *)
  printf -v c '%.2f' "$COST" 2>/dev/null && OUT+=("~\$$c") ;;
esac

[ "${#OUT[@]}" -gt 0 ] || exit 0
line="${OUT[0]}"
for p in "${OUT[@]:1}"; do line="$line · $p"; done
printf '%s\n' "$line"
exit 0
