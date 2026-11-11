#!/usr/bin/env bash
# turn-check.sh — UserPromptSubmit + Stop: the files the main thread changed in a turn get the project's own fast
# check once, before the turn ends.
#
# WHY. A crew agent's work is checked when it stops (agent-outcome.sh runs its card's `verify`). The main thread's
# own edits, which the discipline allows for small changes, had nothing: the turn ended, the user read "done", and
# a lint error waited for the next commit or the next person. This closes that gap with the command the project
# already declared for it, and only that one.
#
# WHAT RUNS. The `Fast check (files):` line of ./CLAUDE.md (## Verify). `<file>` in it becomes the turn's changed files,
# each in single quotes; a command with no `<file>` runs as written. No line, the template's placeholder, or `none`:
# nothing runs, nothing is written, no process starts. The command is judged exactly as agent-outcome.sh judges a
# verify command before it runs it (_am_verify_ok in guard-agent-model.sh: permission rules, the shell gate, the
# mode); one it may not run is said to the user once per session and not run.
#
# WHICH FILES ARE THE TURN'S. At UserPromptSubmit a snapshot goes into the git directory (never committed): HEAD, the
# time, and the content id of every file that was already dirty. At Stop the turn's set is
#   * a dirty file whose content differs from the snapshot (one dirty before the turn and untouched is not the
#     turn's, it is earlier work);
#   * the files of commits the turn made (commit, amend, cherry-pick, revert), as `git diff <snapshot HEAD> HEAD`;
#     an amend therefore counts only what it changed. When the turn moved HEAD any other way (pull, merge, reset,
#     checkout, rebase), the commits are not counted at all: someone else's code is not this turn's to check.
# Deleted files are left out. An empty set is silence.
#
# RED. Exit 2 with the end of the check's output, which Claude Code hands back to the model so the turn goes on to
# fix it. Once per turn: Claude Code marks the next Stop of the same turn `stop_hook_active`, and that Stop passes.
#
# MODES: CREW_TURN_CHECK=off  nothing runs. CREW_TURN_CHECK_TIMEOUT  seconds the check may take (default 120, at
# most 170, under the hook's own 180). NOT A GATE ON ITS OWN FAILURE: an error of this script is silence (exit 0);
# the only exit 2 is a check that ran and failed.
set -uo pipefail
case "${CREW_TURN_CHECK:-on}" in off|OFF|0|false) exit 0 ;; esac
trap 'exit 0' EXIT
export LC_ALL=C
IN=""; IFS= read -r -d '' -t "${CREW_STDIN_TIMEOUT:-2}" IN 2>/dev/null; [ "$?" -gt 128 ] && exit 0

_TC_HERE="${BASH_SOURCE//\\//}"; _TC_HERE="${_TC_HERE%/*}"; [ "$_TC_HERE" = "${BASH_SOURCE//\\//}" ] && _TC_HERE=.
P="${CLAUDE_PROJECT_DIR:-$PWD}"; cd "$P" 2>/dev/null || exit 0

# The declared command, read with the builtin `read`: a project that declared none pays no process at all.
FC=""
if [ -f CLAUDE.md ]; then
  while IFS= read -r _l || [ -n "$_l" ]; do
    case "$_l" in "Fast check (files):"*) FC="${_l#Fast check (files):}"; break ;; esac
  done < CLAUDE.md
fi
FC="${FC%$'\r'}"; FC="${FC#"${FC%%[![:space:]]*}"}"; FC="${FC%"${FC##*[![:space:]]}"}"
case "$FC" in '`'*'`') FC="${FC#\`}"; FC="${FC%\`}" ;; esac
case "$FC" in ''|'<'*|none|None|NONE) exit 0 ;; esac

_field(){  # $1 = key -> _F, the payload's string value (letters, digits, - and _ only), "" when absent
  local r="${IN#*\"$1\"}"; _F=""
  [ "$r" = "$IN" ] && return 0
  r="${r#"${r%%[![:space:]:]*}"}"; r="${r#\"}"; _F="${r%%\"*}"
  case "$_F" in *[!A-Za-z0-9_-]*) _F="" ;; esac
}
_field hook_event_name; EV="$_F"
_field session_id; SID="$_F"; [ -n "$SID" ] || exit 0

GD="$(git rev-parse --absolute-git-dir 2>/dev/null)" || exit 0
SNAPD="$GD/crewforth-turn"; SNAP="$SNAPD/$SID"
_now(){ if [ "${BASH_VERSINFO[0]}" -ge 5 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then printf -v NOW '%(%s)T' -1; else NOW="$(date +%s)"; fi; }

# LINEAR IN THE NUMBER OF DIRTY FILES. Measured on Windows (Git Bash 5.3) in a project with 10 000 untracked files and
# no ignore rule for them: the Stop took 60-198 s (10 of 10 over 60 s), the prompt 6-90 s, and on macOS the Stop took
# 30 s. Three costs, all in bash: each dirty file looked up with `case "$BEFORE" in *…*` in a string that grew by being
# copied on every line, the same for the turn's own list, and `read -d ''` from a pipe, which bash reads one byte at a
# time. Now every list is a file: git writes it, awk joins and dedupes it (one pass each), and bash reads only what it
# needs, from a regular file (read in blocks).
TCT="$SNAPD/$SID.tmp"
_dirty_file(){  # -> "$TCT.cur": one "<content id>\t<path>" line per dirty regular file (a rename's old name and a deleted
                #    file dropped)
  mkdir -p "$SNAPD" 2>/dev/null || return 1
  git -c core.fsmonitor= status --porcelain=v1 -z --untracked-files=all 2>/dev/null | tr '\0' '\n' \
    | awk 'skip { skip = 0; next } { st = substr($0, 1, 2); p = substr($0, 4) }
           st ~ /^[RC]/ { skip = 1 } st ~ /D/ { next } { print p }' > "$TCT.paths"
  : > "$TCT.files"
  local p
  while IFS= read -r p; do [ -f "$p" ] && printf '%s\n' "$p"; done < "$TCT.paths" > "$TCT.files"
  if [ -s "$TCT.files" ]; then
    git hash-object --stdin-paths < "$TCT.files" > "$TCT.ids" 2>/dev/null || : > "$TCT.ids"
    awk 'NR == FNR { id[FNR] = $0; next } { print (FNR in id ? id[FNR] : "-") "\t" $0 }' "$TCT.ids" "$TCT.files" > "$TCT.cur"
  else : > "$TCT.cur"; fi
}

if [ "$EV" = UserPromptSubmit ]; then
  HEAD="$(git rev-parse -q --verify HEAD 2>/dev/null)"; _now
  _dirty_file || exit 0
  { printf 'head\t%s\ntime\t%s\n' "${HEAD:--}" "$NOW"; awk '{ print "f\t" $0 }' "$TCT.cur"; } > "$SNAP.tmp" 2>/dev/null \
    && mv -f "$SNAP.tmp" "$SNAP" 2>/dev/null
  rm -f "$TCT".* 2>/dev/null
  exit 0
fi

[ "$EV" = Stop ] || exit 0
case "$IN" in *'"stop_hook_active":true'*|*'"stop_hook_active": true'*) exit 0 ;; esac
[ -f "$SNAP" ] || exit 0

# ---- the turn's files -----------------------------------------------------------------------------------------
SH="-"; ST=0
{ IFS=$'\t' read -r k SH; IFS=$'\t' read -r k ST; } < "$SNAP" 2>/dev/null
[ -n "$SH" ] || SH="-"
case "$ST" in ''|*[!0-9]*) ST=0 ;; esac
_dirty_file || { rm -f "$SNAP"; exit 0; }
# a dirty file whose "<content id>\t<path>" the snapshot does not hold changed in this turn
awk 'NR == FNR { if (substr($0, 1, 2) == "f\t") had[substr($0, 3)] = 1; next }
     !($0 in had) { print substr($0, index($0, "\t") + 1) }' "$SNAP" "$TCT.cur" > "$TCT.turn"
rm -f "$SNAP" 2>/dev/null

HEAD="$(git rev-parse -q --verify HEAD 2>/dev/null)"
if [ -n "$HEAD" ] && [ "$SH" != - ] && [ "$HEAD" != "$SH" ]; then
  # Only a turn whose every move of HEAD was a commit of its own counts its commits.
  OURS=1; N=0
  while IFS=$'\t' read -r sel subj; do
    t="${sel#*@\{}"; t="${t%\}}"; case "$t" in *[!0-9]*|'') continue ;; esac
    [ "$t" -ge "$ST" ] || break
    N=$((N+1))
    case "$subj" in "commit:"*|"commit (amend):"*|"commit (initial):"*|"cherry-pick:"*|"revert:"*) ;; *) OURS=0 ;; esac
  done < <(git log -g --date=unix --format='%gd%x09%gs' -n 50 HEAD 2>/dev/null)
  if [ "$OURS" = 1 ] && [ "$N" -gt 0 ]; then
    git -c core.fsmonitor= diff --name-only -z --no-renames --diff-filter=d --no-ext-diff "$SH" "$HEAD" -- 2>/dev/null \
      | tr '\0' '\n' >> "$TCT.turn"
  fi
fi
# once each, in order, and only what is a file now; the command names at most 50, so 200 lines are read at most
FILES=()
while IFS= read -r p; do [ -n "$p" ] && [ -f "$p" ] && FILES+=("$p"); done < <(awk '!seen[$0]++' "$TCT.turn" | head -n 200)
rm -f "$TCT".* 2>/dev/null
[ "${#FILES[@]}" -gt 0 ] || exit 0

# ---- the command ---------------------------------------------------------------------------------------------
CMD="$FC"
case "$FC" in *'<file>'*)
  Q=""; n=0
  for p in "${FILES[@]}"; do
    case "$p" in *"'"*|*[\;\&\|\<\>\`\$]*|-*) continue ;; esac
    Q="${Q:+$Q }'$p'"; n=$((n+1)); [ "$n" -ge 50 ] && break
  done
  [ -n "$Q" ] || exit 0
  CMD="${FC//<file>/$Q}" ;;
esac

[ -f "$_TC_HERE/guard-agent-model.sh" ] || exit 0
. "$_TC_HERE/guard-agent-model.sh"
declare -F _am_verify_ok >/dev/null 2>&1 || exit 0
_am_state
_field permission_mode; PM="${_F:-default}"
if ! _am_verify_ok "$CMD" "$PM"; then
  # Said once per session: a check that never runs must not look like one that passes.
  if mkdir -p "$SNAPD" 2>/dev/null && [ ! -e "$SNAPD/$SID.said" ] && : > "$SNAPD/$SID.said" 2>/dev/null; then
    W="${_AMVW//\\/\\\\}"; W="${W//\"/\\\"}"
    printf '{"systemMessage":"crew: the fast check of this turn was not run: %s. CLAUDE.md declares it under Fast check (files)."}\n' "$W"
  fi
  exit 0
fi

LIM="${CREW_TURN_CHECK_TIMEOUT:-120}"; case "$LIM" in ''|*[!0-9]*) LIM=120 ;; esac; [ "$LIM" -le 170 ] || LIM=170
OUTF="$SNAPD/$SID.out"; mkdir -p "$SNAPD" 2>/dev/null || exit 0
if command -v setsid >/dev/null 2>&1; then ( exec setsid bash -c "$CMD" ) > "$OUTF" 2>&1 </dev/null &
else set -m; ( exec bash -c "$CMD" ) > "$OUTF" 2>&1 </dev/null & set +m; fi
VPID=$!; W=0; RC=""; Q0=0
# Polled every 0.1 s for its first second, then every second: a check that ends at once no longer waits a full second
# (each Stop paid ~1 s for it, measured on Windows).
while kill -0 "$VPID" 2>/dev/null; do
  if [ "$W" -ge "$LIM" ]; then
    kill -TERM -- "-$VPID" 2>/dev/null; kill -TERM "$VPID" 2>/dev/null; sleep 1
    kill -KILL -- "-$VPID" 2>/dev/null; kill -KILL "$VPID" 2>/dev/null; RC=timeout; break
  fi
  if [ "$Q0" -lt 10 ]; then sleep 0.1; Q0=$((Q0+1)); [ "$Q0" = 10 ] && W=$((W+1)); else sleep 1; W=$((W+1)); fi
done
if [ "$RC" = timeout ]; then
  wait "$VPID" 2>/dev/null; rm -f "$OUTF" 2>/dev/null
  printf '{"systemMessage":"crew: the fast check of this turn did not finish in %ss and was stopped; nothing is concluded from it."}\n' "$LIM"
  exit 0
fi
wait "$VPID" 2>/dev/null; RC=$?
TAIL="$(tail -n 20 "$OUTF" 2>/dev/null | cut -c1-300)"; rm -f "$OUTF" 2>/dev/null
[ "$RC" = 0 ] && exit 0
{
  printf 'The fast check this project declares failed on the files this turn changed (exit %s): %s\n' "$RC" "$CMD"
  printf 'The end of its output:\n%s\n' "$TAIL"
  printf 'Fix what it reports in those files, or say to the user why it stays red. This is said once per turn.\n'
} >&2
trap - EXIT
exit 2
