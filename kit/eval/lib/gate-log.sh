# Sourced, not run. The ONE rule for where the gate log is, for the gates that write it and everything that reads it
# (the status line, gate-report, doctor). Studio's reader (server/lib/kit-telemetry.js) follows the same order.
#
#   1. CREW_GATE_LOG, when set: used as given (/dev/null turns recording off).
#   2. .claude/gate-log.tsv, outside a git repository or where git ignores it (a full install ignores .claude/).
#   3. Otherwise <git dir>/crewforth-gate-log.tsv: inside the repository's own .git, which is never committed.
#      Before 3.2.0 the log was simply not written there, so a project that tracks .claude/ had no record of a
#      refusal, no 🛡 on its status line and no note of a model the gate lowered (seen on a real project).
#
# Builtins only on the reading side, which the status line runs every few seconds. The writing side asks git
# (one or two processes), and only when a decision is being logged.

# The repository's git directory, from the project root up, without a process: _CREW_GD, or rc 1.
crew_git_dir(){
  local d="${1:-.}" n=0 l
  _CREW_GD=""
  while [ "$n" -lt 12 ]; do
    if [ -d "$d/.git" ]; then _CREW_GD="$d/.git"; return 0; fi
    if [ -f "$d/.git" ]; then
      IFS= read -r l < "$d/.git" 2>/dev/null || l=""
      case "$l" in "gitdir: "*) l="${l#gitdir: }"; l="${l%$'\r'}"
        case "$l" in /*|[A-Za-z]:*) ;; *) l="$d/$l" ;; esac
        [ -d "$l" ] && { _CREW_GD="$l"; return 0; } ;; esac
      return 1
    fi
    [ "$d" = / ] && return 1
    d="$d/.."; n=$((n+1))
  done
  return 1
}

# Where a gate writes: _CREW_GL ("" = nowhere). Run from the project root.
crew_gate_log_write(){
  _CREW_GL=""
  if [ -n "${CREW_GATE_LOG:-}" ]; then _CREW_GL="$CREW_GATE_LOG"; return 0; fi
  [ -d .claude ] || return 0
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1 || git check-ignore -q .claude/gate-log.tsv 2>/dev/null; then
    _CREW_GL=.claude/gate-log.tsv; return 0
  fi
  local g; g="$(git rev-parse --absolute-git-dir 2>/dev/null)" || g=""
  [ -n "$g" ] && [ -d "$g" ] && _CREW_GL="$g/crewforth-gate-log.tsv"
  return 0
}

# Where a reader finds it: _CREW_GL ("" = none yet). No process.
crew_gate_log_read(){
  _CREW_GL=""
  if [ -n "${CREW_GATE_LOG:-}" ]; then _CREW_GL="$CREW_GATE_LOG"; return 0; fi
  if [ -f .claude/gate-log.tsv ]; then _CREW_GL=.claude/gate-log.tsv; return 0; fi
  crew_git_dir . && [ -f "$_CREW_GD/crewforth-gate-log.tsv" ] && _CREW_GL="$_CREW_GD/crewforth-gate-log.tsv"
  return 0
}
