#!/usr/bin/env bash
# todo.sh — the plan's to-do panel: what is done (✓), what is in work (◐), what is not (☐), and the next task when
# none is in work, read from the plan file (docs/PLAN.md unless /crew-todo named another). The drawing is todo.awk;
# this file keeps the panel's two bits of state and serves both its readers.
#
#   bash .claude/eval/lib/todo.sh             open the panel if it is closed, close it if it is open
#   bash .claude/eval/lib/todo.sh on [FILE]   open it (and read FILE from now on)        · off: close it
#   bash .claude/eval/lib/todo.sh FILE        the same as `on FILE`
#   bash .claude/eval/lib/todo.sh show [FILE] print the panel here, once (no status line needed)
#   bash .claude/eval/lib/todo.sh status      one line: open or closed, which file, how far
#   bash .claude/eval/lib/todo.sh pause [F]   mark the plan as not the work in progress (`status: paused` in its head)
#   bash .claude/eval/lib/todo.sh resume [F]  mark it as the work in progress again (`status: active`)
#
# The status line sources this file and calls crew_todo_read: open, the panel is drawn under the line; closed, the
# line carries only the count ("📋 7/12"). Nothing here decides or blocks anything. The plan's own boxes are the record
# ([ ] open · [x] done · [~] in work), ticked by whoever does the work, and its `status:` line says whether it is the
# work in progress: a paused, dropped or done plan gives no count and no tasks, so a stopped plan does not stand in for
# the work that replaced it. The plan is written only by pause and resume, and only that one line, and created when it
# is missing: on, show and the toggle write an empty one (a title, `status: active`, a `## Tasks` heading with no task
# under it), so the file the panel and Studio read is there for the plan's tasks to go into.
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

# The drawing: _CREW_TODO_HINT (the count, "" when the plan has no task or is not active), _CREW_TODO_NOW (one fact,
# tab-separated: work/next + the task · done · inactive + the status · none) and _CREW_TODO_PANEL (its lines, joined
# with newlines). $1 = color (1/0). From the cache when the cache still matches; one awk when it does not.
crew_todo_read(){
  local col="${1:-1}" maxl="${CREW_TODO_LINES:-14}" v="$_CREW_TODO_DIR/view" key l first=1
  _CREW_TODO_HINT=""; _CREW_TODO_NOW=""; _CREW_TODO_PANEL=""
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
    IFS= read -r _CREW_TODO_NOW
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
case "$cmd" in on|off|toggle|show|status|pause|resume) ;; -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  -*) echo "todo: unknown option $cmd (on · off · show · status · pause · resume · a plan file)" >&2; exit 2 ;;
  *) file="$cmd"; cmd=on ;;
esac
case "$file" in *$'\n'*|*$'\r'*) echo "todo: a file name with a line break is not read" >&2; exit 2 ;; esac

# The plan file, written when it is missing: the head spec-planning's plans start with and a Tasks heading with no task
# under it, for whoever holds the plan to fill. Its directory is made too. Says so in one line on stdout.
crew_todo_create(){
  [ -e "$1" ] && return 0
  case "$1" in */*) mkdir -p "${1%/*}" 2>/dev/null ;; esac
  printf '%s\n' '# Plan' 'status: active' '## Tasks (order)' \
    'Progress: tick a task [x] when its check passes, mark the one in work [~]; status: paused above when this work stops.' \
    > "$1" 2>/dev/null || { echo "todo: cannot write $1" >&2; return 1; }
  echo "todo: created $1, with no task in it yet"
}

if [ "$cmd" = show ]; then
  # Drawn here, not from the cache, and coloured only on a terminal: this may go to a chat that does not take colour.
  crew_todo_plan; [ -n "$file" ] && _CREW_TODO_PLAN="$file"
  crew_todo_create "$_CREW_TODO_PLAN" || exit 1
  c=0; [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && c=1
  LC_ALL=C awk -v color="$c" -v maxl=999 -v name="$_CREW_TODO_PLAN" -f "$_CREW_TODO_LIB/todo.awk" "$_CREW_TODO_PLAN" | sed 1,2d
  exit 0
fi

if [ "$cmd" = pause ] || [ "$cmd" = resume ]; then
  # The one line this script writes in a plan: `status:` in its head (above the first ## heading), replaced where it
  # is, else put under the `commit:` line, else under the title, else on top. Line endings follow the file's.
  crew_todo_plan; [ -n "$file" ] && _CREW_TODO_PLAN="$file"
  if [ ! -f "$_CREW_TODO_PLAN" ]; then echo "todo: no plan at $_CREW_TODO_PLAN to $cmd (/crew-todo writes one)" >&2; exit 1; fi
  w=paused; [ "$cmd" = resume ] && w=active
  # The line ending is read here, not in awk: Git Bash's awk drops the CR of a CRLF line as it reads it, so it would
  # neither see one nor write one back, and the whole plan would come out LF.
  cr=0; IFS= read -r l < "$_CREW_TODO_PLAN" && case "$l" in *$'\r') cr=1 ;; esac
  awk -v w="$w" -v crlf="$cr" '
    { sub(/\r$/, ""); L[NR] = $0 }
    END {
      cr = crlf ? "\r" : ""; at = 0; after = 0; fence = 0
      for (i = 1; i <= NR; i++) {
        if (L[i] ~ /^[ ]*(```|~~~)/) fence = !fence
        if (fence) continue
        if (L[i] ~ /^##/) break
        if (L[i] ~ /^[ ]*\**[Ss][Tt][Aa][Tt][Uu][Ss]\**:/) { at = i; break }
        if (L[i] ~ /^commit:/) after = i
        else if (!after && L[i] ~ /^#[ \t]/) after = i
      }
      for (i = 1; i <= NR; i++) {
        if (i == at) { print "status: " w cr; continue }
        if (!at && after == 0 && i == 1) print "status: " w cr
        print L[i] cr
        if (!at && i == after) print "status: " w cr
      }
      if (NR == 0) print "status: " w
    }' "$_CREW_TODO_PLAN" > "$_CREW_TODO_PLAN.todo-tmp" 2>/dev/null && mv "$_CREW_TODO_PLAN.todo-tmp" "$_CREW_TODO_PLAN" \
    || { rm -f "$_CREW_TODO_PLAN.todo-tmp"; echo "todo: cannot write $_CREW_TODO_PLAN" >&2; exit 1; }
  # A named file is set and left at that: the panel keeps the plan it reads.
  [ -n "$file" ] && { echo "$file: status: $w"; exit 0; }
  cmd=status
fi

mkdir -p "$_CREW_TODO_DIR" 2>/dev/null || { echo "todo: cannot write $_CREW_TODO_DIR" >&2; exit 1; }
if [ -n "$file" ]; then
  if [ "$file" = docs/PLAN.md ]; then rm -f "$_CREW_TODO_DIR/path"; else printf '%s\n' "$file" > "$_CREW_TODO_DIR/path"; fi
fi
case "$cmd" in on|toggle) crew_todo_plan; crew_todo_create "$_CREW_TODO_PLAN" || exit 1 ;; esac
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
  case "$_CREW_TODO_NOW" in
    work$'\t'*) how="$how, in work: ${_CREW_TODO_NOW#*$'\t'}" ;;
    next$'\t'*) how="$how, nothing marked in work, next: ${_CREW_TODO_NOW#*$'\t'}" ;;
  esac
elif [ "${_CREW_TODO_NOW%%$'\t'*}" = inactive ]; then how="${_CREW_TODO_NOW#*$'\t'}: not the work in progress, so no count and no tasks (/crew-todo resume shows them again)"
elif [ -f "$_CREW_TODO_PLAN" ]; then how="no task with a box in it yet"
else how="the file does not exist yet"; fi
if [ "$st" = open ]; then echo "plan panel: open · $_CREW_TODO_PLAN · $how"
elif [ -n "$_CREW_TODO_HINT" ]; then echo "plan panel: closed · $_CREW_TODO_PLAN · $how (the status line keeps the count)"
else echo "plan panel: closed · $_CREW_TODO_PLAN · $how"; fi

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
