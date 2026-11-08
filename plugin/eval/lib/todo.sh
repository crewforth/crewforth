#!/usr/bin/env bash
# todo.sh — the plan's to-do panel: what is done (✓), what is not (☐), and the phase and the task in work (▸), read
# from the plan file (docs/PLAN.md unless /crew-todo named another). The drawing is todo.awk; this file keeps the
# panel's two bits of state and serves both its readers.
#
#   bash .claude/eval/lib/todo.sh             open the panel if it is closed, close it if it is open
#   bash .claude/eval/lib/todo.sh on [FILE]   open it (and read FILE from now on)        · off: close it
#   bash .claude/eval/lib/todo.sh FILE        the same as `on FILE`
#   bash .claude/eval/lib/todo.sh show [FILE] print the panel here, once (no status line needed)
#   bash .claude/eval/lib/todo.sh status      one line: open or closed, which file, how far
#
# The status line sources this file and calls crew_todo_read: open, the panel is drawn under the line; closed, the
# line carries only the count ("📋 7/12"). Nothing here decides or blocks anything, and the plan is never written:
# the plan's own boxes are the record ([ ] open · [x] done · [~] in work), ticked by whoever does the work.
#
# State, per project, under .claude/state/todo/: `open` (present = the panel is open) and `path` (the plan file, when
# it is not docs/PLAN.md); `view` is a cache of the drawing, made again only when the plan, todo.awk or the settings
# changed, so a status line refresh costs no process at all while the plan stands still.
# Settings: CREW_TODO_LINES (the panel's height, default 14) · NO_COLOR (set: no colours).

_CREW_TODO_LIB="${BASH_SOURCE%[/\\]*}"; [ "$_CREW_TODO_LIB" = "${BASH_SOURCE}" ] && _CREW_TODO_LIB=.
_CREW_TODO_DIR=.claude/state/todo

# The plan file this project's panel reads: _CREW_TODO_PLAN. Run from the project root.
crew_todo_plan(){
  _CREW_TODO_PLAN=""
  [ -s "$_CREW_TODO_DIR/path" ] && { IFS= read -r _CREW_TODO_PLAN < "$_CREW_TODO_DIR/path"; _CREW_TODO_PLAN="${_CREW_TODO_PLAN%$'\r'}"; }
  [ -n "$_CREW_TODO_PLAN" ] || _CREW_TODO_PLAN=docs/PLAN.md
}

# The drawing: _CREW_TODO_HINT (the count, "" when the plan has no task) and _CREW_TODO_PANEL (its lines, joined with
# newlines). $1 = color (1/0). From the cache when the cache still matches; one awk when it does not.
crew_todo_read(){
  local col="${1:-1}" maxl="${CREW_TODO_LINES:-14}" v="$_CREW_TODO_DIR/view" key l first=1
  _CREW_TODO_HINT=""; _CREW_TODO_PANEL=""
  case "$maxl" in ''|*[!0-9]*) maxl=14 ;; esac
  crew_todo_plan
  if [ ! -f "$_CREW_TODO_PLAN" ]; then
    _CREW_TODO_PANEL="📋 no plan at $_CREW_TODO_PLAN yet: /crew-plan writes one, /crew-todo <file> reads another"
    return 0
  fi
  key="k=$col/$maxl/$_CREW_TODO_PLAN"
  # The cache holds when it is newer than the plan and than the drawing code, and was drawn with these settings.
  if [ -f "$v" ] && [ "$v" -nt "$_CREW_TODO_PLAN" ] && ! [ "$_CREW_TODO_LIB/todo.awk" -nt "$v" ]; then
    IFS= read -r l < "$v" 2>/dev/null || l=""
    [ "$l" = "$key" ] || l=""
  else l=""; fi
  if [ -z "$l" ]; then
    [ -d "$_CREW_TODO_DIR" ] || mkdir -p "$_CREW_TODO_DIR" 2>/dev/null
    { printf '%s\n' "$key"; LC_ALL=C awk -v color="$col" -v maxl="$maxl" -v name="$_CREW_TODO_PLAN" -f "$_CREW_TODO_LIB/todo.awk" "$_CREW_TODO_PLAN" 2>/dev/null; } > "$v" 2>/dev/null || return 0
  fi
  {
    IFS= read -r l                                     # the key
    IFS= read -r _CREW_TODO_HINT
    while IFS= read -r l; do
      if [ "$first" = 1 ]; then _CREW_TODO_PANEL="$l"; first=0; else _CREW_TODO_PANEL="$_CREW_TODO_PANEL"$'\n'"$l"; fi
    done
  } < "$v"
  return 0
}

# Sourced: the functions only.
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

set -u
[ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR/.claude" ] && cd "$CLAUDE_PROJECT_DIR" 2>/dev/null
if [ ! -d .claude ]; then echo "todo: no .claude/ here: run it from the project root of a Crewforth install" >&2; exit 1; fi

cmd="${1:-toggle}"; file="${2:-}"
case "$cmd" in on|off|toggle|show|status) ;; -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  -*) echo "todo: unknown option $cmd (on · off · show · status · a plan file)" >&2; exit 2 ;;
  *) file="$cmd"; cmd=on ;;
esac
case "$file" in *$'\n'*|*$'\r'*) echo "todo: a file name with a line break is not read" >&2; exit 2 ;; esac

if [ "$cmd" = show ]; then
  # Drawn here, not from the cache, and coloured only on a terminal: this may go to a chat that does not take colour.
  crew_todo_plan; [ -n "$file" ] && _CREW_TODO_PLAN="$file"
  if [ ! -f "$_CREW_TODO_PLAN" ]; then echo "📋 no plan at $_CREW_TODO_PLAN yet: /crew-plan writes one"; exit 0; fi
  c=0; [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && c=1
  LC_ALL=C awk -v color="$c" -v maxl=999 -v name="$_CREW_TODO_PLAN" -f "$_CREW_TODO_LIB/todo.awk" "$_CREW_TODO_PLAN" | sed 1d
  exit 0
fi

mkdir -p "$_CREW_TODO_DIR" 2>/dev/null || { echo "todo: cannot write $_CREW_TODO_DIR" >&2; exit 1; }
if [ -n "$file" ]; then
  [ -f "$file" ] || echo "todo: $file does not exist yet; the panel will read it once it does"
  if [ "$file" = docs/PLAN.md ]; then rm -f "$_CREW_TODO_DIR/path"; else printf '%s\n' "$file" > "$_CREW_TODO_DIR/path"; fi
fi
[ "$cmd" = toggle ] && { if [ -e "$_CREW_TODO_DIR/open" ]; then cmd=off; else cmd=on; fi; }
case "$cmd" in
  on) : > "$_CREW_TODO_DIR/open" ;;
  off) rm -f "$_CREW_TODO_DIR/open" ;;
esac

crew_todo_read 0
st=closed; [ -e "$_CREW_TODO_DIR/open" ] && st=open
how=""
if [ -n "$_CREW_TODO_HINT" ]; then
  how="${_CREW_TODO_HINT#📋 } done"
  inwork="$(printf '%s\n' "$_CREW_TODO_PANEL" | grep '▸ ' | tail -n 1 | sed 's/^ *▸ //')"
  [ -n "$inwork" ] && how="$how, in work: $inwork"
elif [ -f "$_CREW_TODO_PLAN" ]; then how="no task with a box in it yet"
else how="the file does not exist yet"; fi
if [ "$st" = open ]; then echo "plan panel: open · $_CREW_TODO_PLAN · $how"
else echo "plan panel: closed · $_CREW_TODO_PLAN · $how (the status line keeps the count)"; fi

# Shown under Crewforth's status line only. Say so when this project's status line is another one, or none.
sl=""
for f in .claude/settings.local.json .claude/settings.json "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"; do
  [ -f "$f" ] && [ -f "$_CREW_TODO_LIB/settings-json.awk" ] || continue
  sl="$(awk -v op=get -v path=statusLine.command -f "$_CREW_TODO_LIB/settings-json.awk" "$f" 2>/dev/null)" || sl=""
  [ -n "$sl" ] && break
done
case "$sl" in
  *eval/lib/statusline.sh*) ;;
  ?*) [ "$st" = open ] && echo "note: this project's status line is not Crewforth's, so the panel does not show there; /crew-todo show prints it here" ;;
  *) [ "$st" = open ] && echo "note: no status line is set; bash .claude/eval/lib/statusline.sh --install (Bash tool, not PowerShell) sets Crewforth's (only where none is set), or /crew-todo show prints the panel here" ;;
esac
exit 0
