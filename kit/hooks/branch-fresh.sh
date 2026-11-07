#!/usr/bin/env bash
# SessionStart (startup|resume) — says, when a session opens, that this branch has fallen behind the branch it merges
# into in a way that matters: merging it would conflict, it was cut long ago, or Crewforth's own files changed there.
#
# WHY. A session that starts on a branch cut days ago plans and edits against code the base has since moved. The
# conflict surfaces at merge time, after the work, when it costs the most. git already knows the answer locally; the
# only question is whether anybody asks it before the first edit.
#
# WHAT IT COMPARES. The current branch against `refs/remotes/origin/<base>` AS IT IS ALREADY FETCHED. <base> is the
# `Base branch:` line of ./CLAUDE.md (## Conventions), else origin's default branch (refs/remotes/origin/HEAD). It
# reports only when the branch is behind the base AND at least one of:
#   * merging the base would conflict (`git merge-tree --write-tree`, git 2.38+; older git: this check is skipped);
#   * the fork point is more than CREW_BRANCH_FRESH_DAYS days old (default 3);
#   * the base changed `.claude/` or `CLAUDE.md` since the fork point (this session runs the older rules).
# A rebase left in progress is said on its own, before anything else.
#
# NO NETWORK IN THE FOREGROUND (the rule session-update-check.sh states). When the last fetch is over an hour old a
# DETACHED `git fetch origin <base>` starts for the NEXT session, with no terminal and no prompt (GIT_TERMINAL_PROMPT=0,
# ssh BatchMode unless GIT_SSH_COMMAND is set). Offline, no remote, no credentials: it fails quietly and the hook
# keeps reading what was fetched before. CREW_BRANCH_FRESH_FETCH=off, CI, or CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC
# set: no fetch at all.
#
# NEVER CHANGES THE BRANCH. It names the command (`git merge origin/<base>`) and says the choice is the user's; a
# rebase rewrites history and is §4.5-gated. The merge-tree check writes unreachable objects git's own gc removes; it
# touches no ref, no index and no working file. Its git calls pass `-c core.fsmonitor=` like every hook's, so a cloned
# repository's .git/config cannot name a program for them to run.
#
# MODES: CREW_BRANCH_FRESH=off  nothing runs. NOT A GATE: every path out is exit 0, and a failure of its own is silence.
set -uo pipefail
case "${CREW_BRANCH_FRESH:-on}" in off|OFF|0|false) exit 0 ;; esac
trap 'exit 0' EXIT
export LC_ALL=C
IN=""; IFS= read -r -d '' -t "${CREW_STDIN_TIMEOUT:-2}" IN 2>/dev/null; [ "$?" -gt 128 ] && exit 0

_js(){  # $1 -> JSON string body: backslash, quote, and control characters (tab and newline as escapes, others dropped)
  local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\t'/\\t}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/}"
  printf '%s' "${s//[$'\001'-$'\037']/}"
}
say(){  # $1 = the line for the user, $2 = the note for the model
  printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$(_js "$1")" "$(_js "$2")"
}

GD="$(git rev-parse --git-dir 2>/dev/null)" || exit 0
if [ -d "$GD/rebase-merge" ] || [ -d "$GD/rebase-apply" ]; then
  say "crew: a rebase is in progress in this checkout. It is finished with git rebase --continue or dropped with git rebase --abort." \
      "Branch check: a rebase was left in progress in this checkout before the session started. Finishing it (git rebase --continue) or dropping it (git rebase --abort) is the user's choice; until they say which, no other git work runs here."
  exit 0
fi
BR="$(git symbolic-ref -q --short HEAD 2>/dev/null)" || exit 0   # detached HEAD: no branch to compare

BASE=""
if [ -f CLAUDE.md ]; then
  while IFS= read -r _l || [ -n "$_l" ]; do
    case "$_l" in "- Base branch:"*|"* Base branch:"*|"Base branch:"*) BASE="${_l#*Base branch:}"; break ;; esac
  done < CLAUDE.md
  BASE="${BASE//\`/}"; BASE="${BASE#"${BASE%%[![:space:]]*}"}"; BASE="${BASE%%[[:space:]]*}"; BASE="${BASE#origin/}"
fi
case "$BASE" in ''|*[!A-Za-z0-9._/-]*|-*) BASE="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)"; BASE="${BASE#origin/}" ;; esac
case "$BASE" in ''|*[!A-Za-z0-9._/-]*|-*) exit 0 ;; esac

# The detached refresh for the next session. FETCH_HEAD's age is the throttle, so nothing of Crewforth's is written.
_fetch(){
  case "${CREW_BRANCH_FRESH_FETCH:-on}" in off|OFF|0|false) return 0 ;; esac
  [ -n "${CI:-}" ] || [ -n "${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:-}" ] && return 0
  [ -f "$GD/FETCH_HEAD" ] && [ -n "$(find "$GD/FETCH_HEAD" -mmin -60 2>/dev/null)" ] && return 0
  GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}" \
    git -c gc.auto=0 -c maintenance.auto=false fetch --quiet --no-tags origin "$BASE" </dev/null >/dev/null 2>&1 &
}
_fetch

[ "$BR" = "$BASE" ] && exit 0
B="refs/remotes/origin/$BASE"
git rev-parse -q --verify "$B^{commit}" >/dev/null 2>&1 || exit 0
read -r BEHIND _ahead < <(git rev-list --left-right --count "$B...HEAD" 2>/dev/null) || exit 0
[ "${BEHIND:-0}" -gt 0 ] 2>/dev/null || exit 0
MB="$(git merge-base HEAD "$B" 2>/dev/null)" || exit 0

_list(){  # newline list on stdin -> "a, b, c (+N more)", at most 5 named
  local n=0 out="" l
  while IFS= read -r l; do [ -n "$l" ] || continue; n=$((n + 1)); [ "$n" -le 5 ] && out="${out:+$out, }$l"; done
  [ "$n" -gt 5 ] && out="$out (+$((n - 5)) more)"
  printf '%s' "$out"
}

CONF=""
_mt="$(git -c core.fsmonitor= merge-tree --write-tree --name-only --no-messages HEAD "$B" 2>/dev/null)"
[ "$?" = 1 ] && CONF="$(printf '%s\n' "$_mt" | sed 1d | _list)"
DAYS=0; _days="${CREW_BRANCH_FRESH_DAYS:-3}"; case "$_days" in ''|*[!0-9]*) _days=3 ;; esac
_mbt="$(git log -1 --format=%ct "$MB" 2>/dev/null)"; _now="$(date +%s 2>/dev/null)"
case "$_mbt$_now" in *[!0-9]*|'') ;; *) DAYS=$(( (_now - _mbt) / 86400 )) ;; esac
OWN="$(git -c core.fsmonitor= diff --name-only --no-ext-diff "$MB" "$B" -- .claude CLAUDE.md 2>/dev/null | _list)"

[ -n "$CONF" ] || [ "$DAYS" -gt "$_days" ] || [ -n "$OWN" ] || exit 0

M="$BR is $BEHIND commit(s) behind origin/$BASE as last fetched."
[ -n "$CONF" ] && M="$M Merging origin/$BASE into it would conflict in: $CONF."
[ "$DAYS" -gt "$_days" ] && M="$M It was cut from origin/$BASE $DAYS days ago."
[ -n "$OWN" ] && M="$M Since then origin/$BASE changed Crewforth's rules or project rules ($OWN); this session runs the older copies."
say "crew: $M Bringing origin/$BASE in is your call: git merge origin/$BASE." \
    "Branch check: $M Bringing origin/$BASE in is the user's decision, not part of the task: the command is git merge origin/$BASE (a merge, since a rebase rewrites the branch's commits and is §4.5-gated). Nothing was changed."
exit 0
