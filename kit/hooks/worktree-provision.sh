#!/usr/bin/env bash
# PreToolUse + PostToolUse on EnterWorktree — a worktree the session enters carries Crewforth with it.
#
# Why: `.claude/` is gitignored in a fresh install, so a worktree made with `git worktree add ../x` has none. While
# the session that entered it lives, its hooks keep running from the main checkout. But Claude Code records the
# session under the worktree once it enters one, and a session resumed there reads its settings from the worktree:
# with no `.claude/settings.json` there, NO hook is registered — no commit approval, no write gate, no fill line.
# Measured on Claude Code 2.1.309: a resumed session in such a worktree ran no project hook (0 of 1), the same
# worktree with `.claude/` copied in ran it (1 of 1). A field session ran four and a half hours that way, printing a
# fill it had made up. A worktree Claude Code creates under `.claude/worktrees/` is not affected (measured: the
# resumed session there still ran the main checkout's hooks), so it is left alone.
#
# What it does: before the move (PreToolUse, when the call names an existing path) and after it (PostToolUse, the
# path the tool reports), a linked worktree of THIS repository with no `.claude/settings.json` gets a copy of this
# checkout's `.claude/`, minus what belongs to one checkout only (`worktrees/`, `state/`, the review record, the
# gate log). If the copy cannot be made, the PreToolUse call is refused (exit 2) with the reason, and the
# PostToolUse call tells the user and the model, since the move already happened.
set -uo pipefail
# ---- CREW-FAILCLOSED ---------------------------------------------------------------------------------------
# A gate that stops on an error of its own must refuse the call, not let it through. Claude Code blocks a tool call
# on exit 2 only; a hook that dies with 1, or runs on past the rule that broke, has allowed it. Both happened in
# one defect (measured, bash 5): a local array declared and not set is "unbound" under `set -u`, the rule that read
# it was abandoned in the middle, the script went on with the NEXT top-level command and left with 0, and
# `rm .claude/hooks/pre-commit` passed. bash does one of two things with such an error, by the kind of error:
#   * it leaves the shell with a status that is neither 0 nor 2  -> the EXIT trap below turns that into a refusal;
#   * it abandons the top-level command it was in and continues -> the whole gate IS one top-level command,
#     _gate_main, which only ever ends by `exit`. If it RETURNS, it was abandoned, and the line after it refuses.
# Not covered, and said so: an error inside a command substitution (only that subshell ends), and a command
# that is not found (status 127, the script continues inside the same command).
# Byte-identical in every PreToolUse gate; the suite pins it. No process is started.
_crew_stop(){  # $1 = what happened
  declare -F gatelog >/dev/null 2>&1 && gatelog BLOCK 4.5 "the gate stopped on an error of its own"
  echo "GUARD (§4.5): this gate stopped on an error of its own ($1) before it finished judging the call, so the call is refused." >&2
  echo "Nothing about the call itself was found. The error is the line above these two; it is a defect in Crewforth, not in what you ran. Run the doctor (bash .claude/eval/doctor.sh, Bash tool, not PowerShell) and report it." >&2
  exit 2
}
trap '_crew_rc=$?; trap - EXIT; case "$_crew_rc" in 0|2) exit "$_crew_rc" ;; esac; _crew_stop "exit status $_crew_rc"' EXIT
# ---- /CREW-FAILCLOSED
unq(){ local p="${1#\"}"; p="${p%\"}"; p="${p//\\\\//}"; p="${p//\\//}"; printf '%s' "$p"; }   # JSON string -> path; \ -> /
_gate_main(){
local IN HERE SRC READER V EV P_IN P_OUT T MINE THEIRS TOP ERR e WHY SAFE
IFS= read -r -d '' IN || true
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "$HERE/.." && pwd)"                      # this checkout's .claude/
READER="$SRC/eval/lib/settings-json.awk"
[ -f "$READER" ] || exit 0                         # no reader, nothing to read the payload with: fail open

V="$(printf '%s' "$IN" | awk -v op=gets -v path='hook_event_name|tool_input.path|tool_response.worktreePath' -f "$READER" - 2>/dev/null)"
EV="${V%%$'\t'*}"; V="${V#*$'\t'}"; P_IN="${V%%$'\t'*}"; V="${V#*$'\t'}"; P_OUT="${V%%$'\t'*}"
EV="$(unq "$EV")"
case "$EV" in
  PreToolUse)  T="$(unq "$P_IN")" ;;
  PostToolUse) T="$(unq "$P_OUT")" ;;
  *) exit 0 ;;
esac
[ -n "$T" ] && [ -d "$T" ] || exit 0              # no path (Claude creates one under .claude/worktrees/) or none yet

# Only a linked worktree of THIS repository, asked of git rather than compared as spelled (C:/ against /c/).
MINE="$(git -C "$SRC/.." rev-parse --git-common-dir 2>/dev/null)" || exit 0
THEIRS="$(git -C "$T" rev-parse --git-common-dir 2>/dev/null)" || exit 0
case "$MINE" in /*|?:*) ;; *) MINE="$SRC/../$MINE" ;; esac
case "$THEIRS" in /*|?:*) ;; *) THEIRS="$T/$THEIRS" ;; esac
[ "$MINE" -ef "$THEIRS" ] || exit 0
TOP="$(git -C "$T" rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ "$TOP" -ef "$SRC/.." ] && exit 0                 # the main checkout itself
case "$(cd "$TOP" && pwd -P)/" in "$(cd "$SRC" && pwd -P)/worktrees/"*) exit 0 ;; esac   # Claude Code's own: unaffected
[ -f "$TOP/.claude/settings.json" ] && exit 0      # already carries it (or .claude/ is tracked)

ERR=""
mkdir -p "$TOP/.claude" 2>/dev/null || ERR="could not create $TOP/.claude"
if [ -z "$ERR" ]; then
  for e in "$SRC"/* "$SRC"/.[!.]*; do
    [ -e "$e" ] || continue
    case "${e##*/}" in worktrees|state|review-pass.json|gate-log.tsv) continue ;; esac
    cp -R "$e" "$TOP/.claude/" 2>/dev/null || { ERR="could not copy ${e##*/}"; break; }
  done
fi
[ -z "$ERR" ] && { [ -f "$TOP/.claude/settings.json" ] && [ -d "$TOP/.claude/hooks" ] || ERR="the copy has no settings.json or hooks/"; }
[ -z "$ERR" ] && exit 0

WHY="Crewforth could not put its .claude/ into the worktree $TOP ($ERR). A session resumed there would load no Crewforth hook: no commit approval, no write gate, no fill reading."
if [ "$EV" = PreToolUse ]; then
  echo "$WHY Fix the cause above, then enter the worktree again." >&2
  exit 2
fi
SAFE="${WHY//\\/\\\\}"; SAFE="${SAFE//\"/\\\"}"
printf '{"systemMessage":"⚠️ %s","hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s Tell the user, and do not resume this session in that worktree until it is fixed."}}\n' "$SAFE" "$SAFE"
exit 0
}
_gate_main "$@"
_crew_stop "a command of the gate was abandoned"
