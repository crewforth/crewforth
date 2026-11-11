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

# Dirty paths, NUL-separated, from `status -z` (a rename's old name is dropped; a deleted file is dropped).
_dirty(){  # -> DIRTY array
  DIRTY=()
  local rec st path skip=0
  while IFS= read -r -d '' rec; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    st="${rec:0:2}"; path="${rec:3}"
    case "$st" in R*|C*) skip=1 ;; esac
    case "$st" in *D*) continue ;; esac
    [ -f "$path" ] && DIRTY+=("$path")
  done < <(git -c core.fsmonitor= status --porcelain=v1 -z --untracked-files=all 2>/dev/null)
}
_hashes(){  # paths in "$@" -> HASH array, one content id per path (git hash-object, one process)
  HASH=()
  [ "$#" -gt 0 ] || return 0
  local h
  while IFS= read -r h; do HASH+=("$h"); done < <(printf '%s\n' "$@" | git hash-object --stdin-paths 2>/dev/null)
}

if [ "$EV" = UserPromptSubmit ]; then
  HEAD="$(git rev-parse -q --verify HEAD 2>/dev/null)"
  _dirty; _hashes ${DIRTY[@]+"${DIRTY[@]}"}; _now
  mkdir -p "$SNAPD" 2>/dev/null || exit 0
  {
    printf 'head\t%s\ntime\t%s\n' "${HEAD:--}" "$NOW"
    i=0; while [ "$i" -lt "${#DIRTY[@]}" ]; do printf 'f\t%s\t%s\n' "${HASH[$i]:--}" "${DIRTY[$i]}"; i=$((i+1)); done
  } > "$SNAP.tmp" 2>/dev/null && mv -f "$SNAP.tmp" "$SNAP" 2>/dev/null
  exit 0
fi

[ "$EV" = Stop ] || exit 0
case "$IN" in *'"stop_hook_active":true'*|*'"stop_hook_active": true'*) exit 0 ;; esac
[ -f "$SNAP" ] || exit 0

# ---- the turn's files -----------------------------------------------------------------------------------------
# No associative arrays: macOS ships bash 3.2. The snapshot's dirty files are one newline-framed string of
# "<content id> <path>" lines, and a lookup is one `case`.
SH="-"; ST=0; BEFORE=$'\n'
while IFS=$'\t' read -r k a b; do
  case "$k" in head) SH="$a" ;; time) ST="$a" ;; f) BEFORE="$BEFORE$a $b"$'\n' ;; esac
done < "$SNAP"
rm -f "$SNAP" 2>/dev/null
case "$ST" in ''|*[!0-9]*) ST=0 ;; esac

SEEN=$'\n'; FILES=()
_add(){
  [ -n "$1" ] && [ -f "$1" ] || return 0
  case "$SEEN" in *$'\n'"$1"$'\n'*) return 0 ;; esac
  SEEN="$SEEN$1"$'\n'; FILES+=("$1")
}

_dirty; _hashes ${DIRTY[@]+"${DIRTY[@]}"}
i=0; while [ "$i" -lt "${#DIRTY[@]}" ]; do
  p="${DIRTY[$i]}"
  case "$BEFORE" in *$'\n'"${HASH[$i]:-x} $p"$'\n'*) ;; *) _add "$p" ;; esac
  i=$((i+1))
done

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
    while IFS= read -r -d '' p; do _add "$p"; done < <(git -c core.fsmonitor= diff --name-only -z --no-renames --diff-filter=d --no-ext-diff "$SH" "$HEAD" -- 2>/dev/null)
  fi
fi
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
VPID=$!; W=0; RC=""
while kill -0 "$VPID" 2>/dev/null; do
  if [ "$W" -ge "$LIM" ]; then
    kill -TERM -- "-$VPID" 2>/dev/null; kill -TERM "$VPID" 2>/dev/null; sleep 1
    kill -KILL -- "-$VPID" 2>/dev/null; kill -KILL "$VPID" 2>/dev/null; RC=timeout; break
  fi
  sleep 1; W=$((W+1))
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
