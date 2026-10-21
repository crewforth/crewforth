#!/usr/bin/env bash
# Team board engine — a distributed claim lock and shared item memory for a team sharing one repository.
#
# WHY THIS EXISTS
#   Every kit install is local: docs/PLAN.md and docs/SESSION_STATE.md are gitignored, so item #1 being taken
#   is invisible to everyone else and two people start the same work. This engine puts the item list, the
#   claims and the per-item handover notes on a git ref that the whole team pushes to.
#
# WHY A GIT REF IS THE LOCK (measured, not assumed)
#   `git push` to a ref is fast-forward-only unless forced. Two clones that build a claim commit on the SAME
#   base and push it: the first wins, the second is rejected non-fast-forward (exit 1) and must re-read the
#   board. That is an atomic compare-and-swap with zero infrastructure — no server, no token, no daemon.
#   Verified against a bare remote: loser exit=1, remote kept the winner's claim.
#
# WHY PLUMBING AND NOT A CHECKOUT
#   Commits are built with hash-object/read-tree/write-tree/commit-tree against a private index file. The
#   working tree, the index, the current branch and any stash are untouched — you can claim an item in the
#   middle of a feature branch with dirty files and nothing moves.
#
# NO NETWORK ON THE HOT PATH
#   Only claim/done/drop/sync/probe talk to the remote, because those are the operations whose whole point is
#   being atomic — reporting "you own it" without a confirmed push would be a lie. Session start and the
#   commit gate read a local cache / the local ref and never open a socket.
#
# PORTABILITY
#   No jq (Windows Git Bash has none). No `date -d` / `date -j` (GNU and BSD disagree) — timestamps are stored
#   as BOTH an ISO string for humans and an epoch integer for arithmetic, so nothing ever has to be re-parsed.
set -uo pipefail

# ---------------------------------------------------------------- repo primitives

_die(){ printf 'board: %s\n' "$1" >&2; exit "${2:-1}"; }

_git_dir(){ git rev-parse --git-common-dir 2>/dev/null; }

# Ref namespace. Default is a custom namespace so the board never shows up in `git branch` and never enters the
# code history. Some servers refuse refs outside refs/heads|refs/tags; `probe` detects that and records the
# fallback here, per clone.
_ref(){ git config --get csk.boardRef 2>/dev/null || echo 'refs/csk/board'; }
_remote(){ git config --get csk.boardRemote 2>/dev/null || echo 'origin'; }

# ---- network git: never block, never prompt ------------------------------------------------------------
# Every git call that reaches a REMOTE goes through here, because a remote is where a hook stops being slow
# and starts being infinite. Three ways that happens, all silent:
#   * git asks for a username on the terminal. A hook has no terminal, so it waits — forever.
#   * Git Credential Manager, the DEFAULT helper on Windows, opens a GUI dialog. In a hook nobody is looking
#     at that window, and it waits forever too. This is the one that hurts: it looks like a frozen commit.
#   * the remote accepts the connection and then stalls, which no prompt setting covers.
# GIT_TERMINAL_PROMPT=0 turns the first into an immediate failure, GCM_INTERACTIVE=never disables the second,
# and `timeout` bounds the third. Where timeout is absent the first two still apply.
#
# Bounding these is safe precisely because failure is ALREADY the graceful path: a non-zero _fetch means
# "remote unreachable — showing the last known state", and a non-zero _commit_push means "kept locally, the
# team cannot see it yet". So this converts a hang into a sentence the user can act on, and never into data
# loss. CSK_NET_TIMEOUT overrides the bound for a slow link.
_TMO="$(command -v timeout 2>/dev/null || true)"
_gitnet(){
  if [ -n "$_TMO" ]; then
    GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never "$_TMO" "${CSK_NET_TIMEOUT:-15}" git "$@"
  else
    GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never git "$@"
  fi
}

# Identity. The email is the claim owner; it is already configured in every clone that can commit.
_me(){
  local m; m="$(git config --get user.email 2>/dev/null)"
  [ -n "$m" ] || m="$(git config --get user.name 2>/dev/null)"
  [ -n "$m" ] || _die "no git identity: set user.email before claiming"
  printf '%s' "$m"
}

_have_board(){ git rev-parse --verify -q "$(_ref)" >/dev/null 2>&1; }

# The board is OFF until somebody creates one — a repo with no board ref has no gates at all, which is what
# every solo project and every pre-existing install stays. This is the separate question of switching it off
# in a repo that HAS one: someone working alone on a shared repo for an afternoon, or a team pausing it.
#   git config csk.board off            this clone
#   git config --global csk.board off   every repo you touch
#   CSK_NO_BOARD=1                      this session only
# Honoured by every entry point, including the commit gate — a switch that turns off two of three gates is a
# trap, not a switch.
_enabled(){
  [ -n "${CSK_NO_BOARD:-}" ] && return 1
  case "$(git config --get csk.board 2>/dev/null)" in off|false|0|no) return 1 ;; esac
  return 0
}

# Fetch the board ref. Forced (+) on purpose: local board state is never authoritative and is never worth
# keeping — every mutation re-derives itself from the fetched state (see _mutate).
_fetch(){
  local ref remote; ref="$(_ref)"; remote="$(_remote)"
  _gitnet fetch -q "$remote" "+$ref:$ref" 2>/dev/null && return 0
  # Only the teammate who ran `init` runs `probe`, so only that clone learns the team fell back to the orphan
  # branch. Everyone else would look for refs/csk/board forever and see no board at all. When nothing is
  # recorded here and the default namespace turns up empty, try the fallback and record the answer — one extra
  # fetch, once per clone.
  if [ -z "$(git config --get csk.boardRef 2>/dev/null)" ] \
     && _gitnet fetch -q "$remote" '+refs/heads/csk-board:refs/heads/csk-board' 2>/dev/null; then
    git config csk.boardRef 'refs/heads/csk-board'
    return 0
  fi
  return 1
}

_cat(){ git cat-file -p "$(_ref):$1" 2>/dev/null; }
_item_paths(){ git ls-tree --name-only "$(_ref)" items/ 2>/dev/null; }

_now_iso(){ date -u +%Y-%m-%dT%H:%M:%SZ; }
_now_epoch(){ date -u +%s; }

_age(){ # _age <epoch> -> "3h" / "12m" / "2d" / "-"   (how long a claim has been held)
  local e="${1:-0}" now d
  case "$e" in ''|*[!0-9]*) printf '%s' '-'; return 0 ;; esac
  [ "$e" -gt 0 ] || { printf '%s' '-'; return 0; }
  now="$(_now_epoch)"; d=$(( now - e )); [ "$d" -lt 0 ] && d=0
  if   [ "$d" -lt 3600 ];  then printf '%dm' $(( d / 60 ))
  elif [ "$d" -lt 172800 ];then printf '%dh' $(( d / 3600 ))
  else                          printf '%dd' $(( d / 86400 )); fi
}

# ---------------------------------------------------------------- item format
#
#   id: 001
#   title: Login API endpoint
#   status: todo | in_progress | blocked | done
#   deps: 001,002          (or "-")
#   external: PROJ-142     (or "-")  — link only; the board never depends on a tracker
#   owner: ali@example.com (or "-")
#   since: <iso>           (or "-")
#   since_epoch: <int>     (or 0)
#   beat_epoch: <int>      (or 0)
#   --
#   ## Handover
#   <free text: exactly where it was left, and why>
#   ## Completion
#   <free text: what shipped, commit/PR>

_field(){ # _field <content> <key>
  printf '%s\n' "$1" | sed -n '1,/^--$/p' | grep -m1 "^$2: " | cut -d' ' -f2-
}
_body(){ printf '%s\n' "$1" | sed -n '/^--$/,$p' | sed '1d'; }

_section(){ # _section <content> <SectionName> -> text under "## Name" up to the next "## "
  _body "$1" | awk -v s="## $2" 'BEGIN{p=0} $0==s{p=1;next} /^## /{p=0} p{print}'
}

_path_for(){ # _path_for <id> -> items/<id>-<slug>.md  (resolved from the tree; ids are unique)
  _item_paths | grep -m1 "^items/$1-" || _item_paths | grep -m1 "^items/$1\.md$"
}

_load(){ # _load <id> -> item content on stdout, 1 if absent
  local p; p="$(_path_for "$1")"; [ -n "$p" ] || return 1; _cat "$p"
}

_render_item(){ # _render_item <id> <title> <status> <deps> <external> <owner> <since> <since_epoch> <beat> <handover> <completion>
  printf 'id: %s\ntitle: %s\nstatus: %s\ndeps: %s\nexternal: %s\nowner: %s\nsince: %s\nsince_epoch: %s\nbeat_epoch: %s\n--\n## Handover\n%s\n## Completion\n%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}"
}

# ---------------------------------------------------------------- config (team-wide, stored IN the ref)

_conf(){ # _conf <key> <default>
  local v; v="$(_cat config 2>/dev/null | grep -m1 "^$1: " | cut -d' ' -f2-)"
  [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$2"
}

# ---------------------------------------------------------------- tree building (never touches the worktree)

_blob(){ git hash-object -w --stdin; }

_tree_with(){ # _tree_with <path> <blob>  [<path2> <blob2> ...] -> tree sha, based on the current board tree
  local idx; idx="$(_git_dir)/csk-index.$$"
  rm -f "$idx"
  local rc=0
  if _have_board; then
    GIT_INDEX_FILE="$idx" git read-tree "$(_ref)^{tree}" 2>/dev/null || rc=1
  fi
  while [ $# -ge 2 ]; do
    GIT_INDEX_FILE="$idx" git update-index --add --cacheinfo "100644,$2,$1" 2>/dev/null || rc=1
    shift 2
  done
  local t; t="$(GIT_INDEX_FILE="$idx" git write-tree 2>/dev/null)" || rc=1
  rm -f "$idx"
  [ "$rc" = 0 ] || return 1
  printf '%s' "$t"
}

_commit_push(){ # _commit_push <tree> <message> -> 0 pushed · 2 rejected (retry) · 3 unshared (offline/denied)
  local tree="$1" msg="$2" sha
  if _have_board; then sha="$(git commit-tree "$tree" -p "$(_ref)" -m "$msg")"
  else                 sha="$(git commit-tree "$tree" -m "$msg")"; fi
  [ -n "$sha" ] || return 1
  local err; err="$(_gitnet push --quiet "$(_remote)" "$sha:$(_ref)" 2>&1)"; local rc=$?
  if [ $rc -eq 0 ]; then
    git update-ref "$(_ref)" "$sha"
    return 0
  fi
  # Non-fast-forward means somebody else claimed in between: that is the lock working, retry on fresh state.
  case "$err" in
    *non-fast-forward*|*fetch\ first*|*rejected*) return 2 ;;
  esac
  # Anything else (offline, no push rights, server refuses the namespace) is not a race. Keep the change
  # locally so work is not lost, and say plainly that the team cannot see it.
  git update-ref "$(_ref)" "$sha"
  printf '%s\n' "$err" > "$(_git_dir)/csk-board-lasterror"
  return 3
}

# ---------------------------------------------------------------- mutation with CAS retry
#
# The loop re-reads the board from the remote on every attempt and re-checks the precondition there, so a
# claim can never be granted against a stale view. Three attempts is not a timeout: each rejection means a
# real competing push landed, and re-evaluating usually turns the second attempt into a clean refusal
# ("someone else owns it") rather than a retry.

_mutate(){ # _mutate <action> <id> [note]
  local action="$1" id="$2" note="${3:-}" attempt=1 rc
  while [ "$attempt" -le 3 ]; do
    _fetch || true                       # offline: fall through on the local ref, _commit_push reports unshared
    _apply_once "$action" "$id" "$note"; rc=$?
    case $rc in
      0) return 0 ;;
      1) return 1 ;;                     # precondition refused — not a race, do not retry
      3) return 3 ;;                     # unshared
      2) attempt=$((attempt+1)) ;;       # lost the race — re-read and re-decide
    esac
  done
  printf 'board: the board changed under three consecutive attempts; run `/board-csk` and retry\n' >&2
  return 1
}

_apply_once(){ # -> 0 ok · 1 refused · 2 race · 3 unshared
  local action="$1" id="$2" note="${3:-}" me c path
  me="$(_me)"
  c="$(_load "$id")" || { printf 'board: no item #%s (run `/board-csk` to list)\n' "$id" >&2; return 1; }
  path="$(_path_for "$id")"

  local title status deps external owner since since_ep beat hand comp
  title="$(_field "$c" title)"; status="$(_field "$c" status)"; deps="$(_field "$c" deps)"
  external="$(_field "$c" external)"; owner="$(_field "$c" owner)"
  since="$(_field "$c" since)"; since_ep="$(_field "$c" since_epoch)"; beat="$(_field "$c" beat_epoch)"
  hand="$(_section "$c" Handover)"; comp="$(_section "$c" Completion)"

  case "$action" in
    claim)
      if [ "$status" = done ]; then printf 'board: #%s is already done\n' "$id" >&2; return 1; fi
      if [ -n "$owner" ] && [ "$owner" != "-" ] && [ "$owner" != "$me" ]; then
        printf 'board: #%s belongs to %s since %s. Free: %s\n' "$id" "$owner" "$since" "$(_free_ids)" >&2
        _log_refusal "$id" held "$owner"
        return 1
      fi
      local blocked; blocked="$(_unmet_deps "$deps")"
      if [ -n "$blocked" ]; then
        printf 'board: #%s is blocked by #%s (not done). Free: %s\n' "$id" "$blocked" "$(_free_ids)" >&2
        _log_refusal "$id" blocked "#$blocked"
        return 1
      fi
      if [ "$owner" = "$me" ] && [ "$status" = in_progress ]; then
        # Re-claiming what you already hold must NOT restart the clock. It used to rewrite `since`, so an item
        # held since morning read as freshly started — which breaks the two things that age is for: telling a
        # teammate how long it has been held, and letting a claim go stale when its owner has walked away.
        # Only the heartbeat moves: re-claiming is evidence you are still on it, not that you just began.
        beat="$(_now_epoch)"
      else
        status=in_progress; owner="$me"; since="$(_now_iso)"; since_ep="$(_now_epoch)"; beat="$since_ep"
      fi
      ;;
    done)
      if [ "$owner" != "$me" ]; then printf 'board: #%s is not yours (%s)\n' "$id" "${owner:--}" >&2; return 1; fi
      status=done; owner='-'; beat="$(_now_epoch)"
      [ -n "$note" ] && comp="$note"
      ;;
    drop)
      if [ "$owner" != "$me" ]; then printf 'board: #%s is not yours (%s)\n' "$id" "${owner:--}" >&2; return 1; fi
      # A drop without a handover note is the exact failure this board exists to prevent: the next person
      # inherits the item with none of the context that made it hard.
      [ -n "$note" ] || { printf 'board: drop needs a handover note (where it stands, and why)\n' >&2; return 1; }
      status=todo; owner='-'; since='-'; since_ep=0; beat="$(_now_epoch)"; hand="$note"
      ;;
    beat)
      [ "$owner" = "$me" ] || return 1
      beat="$(_now_epoch)"
      ;;
    note)
      if [ "$owner" != "$me" ]; then printf 'board: #%s is not yours (%s)\n' "$id" "${owner:--}" >&2; return 1; fi
      hand="$note"; beat="$(_now_epoch)"
      ;;
    *) _die "unknown action '$action'" ;;
  esac

  local blob tree
  blob="$(_render_item "$id" "$title" "$status" "$deps" "$external" "$owner" "$since" "$since_ep" "$beat" "$hand" "$comp" | _blob)"
  tree="$(_tree_with "$path" "$blob")" || return 1
  _commit_push "$tree" "board: $action #$id by $me"
}

_unmet_deps(){ # -> comma list of dependency ids that are not done
  local deps="$1" out="" d dc
  [ -n "$deps" ] && [ "$deps" != "-" ] || return 0
  for d in $(printf '%s' "$deps" | tr ',' ' '); do
    dc="$(_load "$d")" || continue
    [ "$(_field "$dc" status)" = done ] || out="${out:+$out,}$d"
  done
  printf '%s' "$out"
}

_free_ids(){ # claimable right now: unowned, not done, no unmet dependency
  local p c out="" id
  for p in $(_item_paths); do
    c="$(_cat "$p")"; id="$(_field "$c" id)"
    [ "$(_field "$c" status)" = done ] && continue
    local o; o="$(_field "$c" owner)"; [ -n "$o" ] && [ "$o" != "-" ] && continue
    [ -n "$(_unmet_deps "$(_field "$c" deps)")" ] && continue
    out="${out:+$out }#$id"
  done
  printf '%s' "${out:-none}"
}

# ---------------------------------------------------------------- commands

cmd_add(){ # add <id> <title> [deps] [external]
  local id="$1" title="$2" deps="${3:--}" ext="${4:--}" attempt=1 rc
  case "$id" in ''|*[!0-9]*) _die "id must be numeric (e.g. 003)";; esac
  local slug; slug="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//' | cut -c1-40)"
  while [ "$attempt" -le 3 ]; do
    _fetch || true
    if _load "$id" >/dev/null 2>&1; then _die "#$id already exists"; fi
    local blob tree
    blob="$(_render_item "$id" "$title" "$([ "$deps" != "-" ] && echo blocked || echo todo)" "$deps" "$ext" '-' '-' 0 0 '' '' | _blob)"
    tree="$(_tree_with "items/$id-$slug.md" "$blob")" || _die "could not build the board tree"
    _commit_push "$tree" "board: add #$id"; rc=$?
    case $rc in 0) printf '+ #%s %s\n' "$id" "$title"; return 0;; 3) printf '+ #%s %s  [UNSHARED — remote unreachable]\n' "$id" "$title"; return 0;; esac
    attempt=$((attempt+1))
  done
  _die "the board kept changing; retry"
}

_related(){ # _related <id> — the work this item is connected to, in the words of the people who did it.
  # Storing a handover note is not the same as delivering it. Whoever picks up #3 has no reason to go and read
  # #1, so the moment they take #3 is when what #1 actually delivered has to arrive on its own.
  local id="$1" c deps d dc out="" body who
  c="$(_load "$id")" || return 0
  deps="$(_field "$c" deps)"
  if [ -n "$deps" ] && [ "$deps" != "-" ]; then
    for d in $(printf '%s' "$deps" | tr ',' ' '); do
      dc="$(_load "$d")" || continue
      body="$(_section "$dc" Completion | head -6)"; [ -n "$body" ] || body="$(_section "$dc" Handover | head -6)"
      who="$(_field "$dc" owner)"; [ "$who" = "-" ] && who="$(_field "$dc" status)"
      out="$out
  #$d \"$(_field "$dc" title)\" [$(_field "$dc" status)] — depends-on
${body:+$(printf '%s' "$body" | sed 's/^/      /')}"
    done
  fi
  # Who is waiting on YOU: work that will be affected by what you are about to do, so it can be told.
  local p pc pd
  for p in $(_item_paths); do
    pc="$(_cat "$p")"; pd="$(_field "$pc" deps)"
    case ",$pd," in *",$id,"*)
      out="$out
  #$(_field "$pc" id) \"$(_field "$pc" title)\" [$(_field "$pc" status)$([ "$(_field "$pc" owner)" != "-" ] && printf ', %s' "$(_field "$pc" owner)")] — waits on this one" ;;
    esac
  done
  # What everyone ELSE is mid-flight on, with whatever they last said about it. The dependency graph only knows
  # the edges somebody declared; two items can collide without one. "What is Ali doing right now" is a question
  # people ask out loud, so it is answered here without being asked, at the one moment it changes what you do.
  local me ow st note
  me="$(_me)"
  for p in $(_item_paths); do
    pc="$(_cat "$p")"; ow="$(_field "$pc" owner)"; st="$(_field "$pc" status)"
    [ "$st" = in_progress ] && [ -n "$ow" ] && [ "$ow" != "-" ] && [ "$ow" != "$me" ] || continue
    [ "$(_field "$pc" id)" = "$id" ] && continue
    note="$(_section "$pc" Handover | head -2)"
    out="$out
  #$(_field "$pc" id) \"$(_field "$pc" title)\" — $ow is on this now ($(_age "$(_field "$pc" since_epoch)"))${note:+
$(printf '%s' "$note" | sed 's/^/      /')}"
  done

  # Decisions this user has not read. Announcing them only at session start meant an item claimed later in the
  # same session could be started against a constraint the team had already settled — which is the failure the
  # decision was recorded to prevent. Starting work is the last honest moment to say it.
  local dtotal dseen dnew
  dtotal="$(_decision_paths | wc -l | tr -d ' ')"; dseen="$(_seen_count)"
  dnew=$(( dtotal - dseen )); [ "$dnew" -lt 0 ] && dnew=0
  if [ "$dnew" -gt 0 ]; then
    for p in $(_decision_paths | tail -"$dnew"); do
      c="$(_cat "$p")"
      out="$out
  DECISION $(_field "$c" id) \"$(_field "$c" title)\" — $(_field "$c" author), unread by you
$(_body "$c" | head -4 | sed 's/^/      /')"
    done
  fi

  [ -n "$out" ] && printf 'Connected work — read this before you start, and update it when you finish:%s\n' "$out"
  return 0
}

# A refusal is the only proof the lock ever did anything, and it was the one event leaving no trace: the message
# went to stderr and nowhere else. Nothing on the board, nothing in the history — so "how often did this actually
# stop a collision?" was unanswerable, and would still be unanswerable after a trial, because the data would
# never have existed. Measurement has to be installed BEFORE the thing it measures.
#
# Appended to the board so the count is the TEAM's, not one clone's. Refusals are rare by construction — they
# happen only on real contention — so a push per refusal costs little, and it rides the same CAS retry as every
# other write. Failure here is swallowed: a refusal that cannot be logged is still a refusal, and turning it
# into an error would punish the user for the bookkeeping.
_log_refusal(){ # _log_refusal <id> <reason> <holder>
  _enabled || return 0
  _have_board || return 0
  local id="$1" reason="$2" holder="$3" attempt=1 prev line blob tree
  line="$(_now_iso)|$id|$reason|$(_me)|${holder:--}"
  while [ "$attempt" -le 3 ]; do
    prev="$(_cat refusals.log 2>/dev/null)"
    blob="$(printf '%s%s\n' "${prev:+$prev$NLR}" "$line" | _blob)"
    tree="$(_tree_with refusals.log "$blob")" || return 0
    _commit_push "$tree" "board: refusal #$id ($reason)" && return 0
    _fetch >/dev/null 2>&1 || return 0
    attempt=$((attempt+1))
  done
  return 0
}
NLR='
'

cmd_claim(){
  _mutate claim "$1"; local rc=$?
  case $rc in
    0) printf '#%s is yours (%s)\n' "$1" "$(_me)"; _related "$1" ;;
    3) # "Unshared" has two very different causes and one alarming message served both. A repo with no remote
       # is a deliberate local board, not a failure, and telling that user their team cannot see it is noise
       # about a team that does not exist.
       if git remote get-url "$(_remote)" >/dev/null 2>&1; then
         printf '#%s claimed LOCALLY ONLY — the remote is unreachable, your team cannot see it.\n   Run `/board-csk sync` before you rely on it.\n' "$1"
       else
         printf '#%s is yours (%s) — local board, no remote configured.\n' "$1" "$(_me)"
         _related "$1"
       fi ;;
    *) return $rc ;;
  esac
  cmd_cache >/dev/null
}

cmd_done(){ _mutate done "$1" "${2:-}" || return $?; printf '#%s done. Now claimable: %s\n' "$1" "$(_free_ids)"; cmd_cache >/dev/null; }
cmd_drop(){ _mutate drop "$1" "${2:-}" || return $?; printf '#%s released with a handover note.\n' "$1"; cmd_cache >/dev/null; }
cmd_note(){ _mutate note "$1" "${2:-}" || return $?; printf '#%s handover note updated.\n' "$1"; }

cmd_status(){
  # This view fetches before it prints, and that is a deliberate reversal. It used to fetch only when there was
  # no board at all, to keep the network off the foreground — and the result was a board that lied: caught in a
  # real session, it showed an item as blocked while its dependency had already landed, and only the claim that
  # followed corrected it. The "no network in the foreground" rule is about hooks that run on EVERY turn, not
  # about a view a person asked for by name. A stale answer to "who has what" is worse than a slow one, because
  # the next thing the reader does is decide what to work on.
  #
  # Fails open: an unreachable remote falls through to whatever is local, so the view still appears offline.
  _fetch >/dev/null 2>&1 || true
  _have_board || { echo "No board in this repo yet (and none on '$(_remote)'). Create one: /board-csk init"; return 0; }
  local me p c id st ow ti dep bl now stale_h
  me="$(_me)"; now="$(_now_epoch)"; stale_h="$(_conf stale_hours 8)"
  # HELD is not decoration: "who holds it" without "for how long" is the question a teammate actually asks, and
  # without it the only age signal was the STALE marker — i.e. nothing at all until 8 hours had passed.
  echo "ITEM  STATUS         OWNER                 HELD  TITLE"
  for p in $(_item_paths); do
    c="$(_cat "$p")"; id="$(_field "$c" id)"; st="$(_field "$c" status)"; ow="$(_field "$c" owner)"; ti="$(_field "$c" title)"
    # Blockedness is DERIVED from the dependency graph, never read from the stored field: an item added with a
    # dependency is stored as `blocked` and nothing rewrites that field when the dependency lands, so trusting
    # it printed "blocked" for items the same view was simultaneously listing as claimable.
    dep="$(_unmet_deps "$(_field "$c" deps)")"
    if [ "$st" != done ]; then
      if [ -n "$dep" ];              then st="blocked(#$dep)"
      elif [ -n "$ow" ] && [ "$ow" != "-" ]; then st="in_progress"
      else                                st="todo"; fi
    fi
    bl=""
    if [ "$ow" = "$me" ]; then bl=" <- you"; fi
    if [ -n "$ow" ] && [ "$ow" != "-" ]; then
      local b; b="$(_field "$c" beat_epoch)"; case "$b" in ''|*[!0-9]*) b=0;; esac
      [ "$b" -gt 0 ] && [ $(( (now - b) / 3600 )) -ge "$stale_h" ] && bl="$bl [STALE $(( (now-b)/3600 ))h]"
    fi
    local age='-'
    { [ -n "$ow" ] && [ "$ow" != "-" ]; } && age="$(_age "$(_field "$c" since_epoch)")"
    printf '#%-4s %-14s %-21s %-5s %s%s\n' "$id" "$st" "${ow:--}" "$age" "$ti" "$bl"
  done
  echo
  echo "Claimable now: $(_free_ids)"
  [ -f "$(_git_dir)/csk-board-lasterror" ] && echo "Last sync error: $(cat "$(_git_dir)/csk-board-lasterror")"
  return 0
}

cmd_show(){ # show <id> — the shared memory for one item
  local c; c="$(_load "$1")" || _die "no item #$1"
  printf '%s\n' "$c"
}

# ---------------------------------------------------------------- cache (what the session-start hook reads)

cmd_cache(){ # rebuild the local cache; NEVER called on the foreground path with the network
  # Switched off -> leave nothing behind for the other two gates to read. The write guard tests for the flag
  # file and the session hook prints the cache file; removing both is what makes "off" cost exactly zero
  # instead of merely suppressing the output of work still being done.
  # The timestamp is written on EVERY path, including the two that produce no cache. It is what the session-start
  # hook throttles on, and without it a repo that has no board (every solo project, and every install that
  # upgraded into this feature) re-spawned a background fetch at every single session opening — looking, forever,
  # for a ref nobody is ever going to create.
  if ! _enabled; then rm -f "$(_git_dir)/csk-board-guard" "$(_git_dir)/csk-board-cache"; _now_epoch > "$(_git_dir)/csk-board-cache.at" 2>/dev/null; return 0; fi
  _have_board || { _now_epoch > "$(_git_dir)/csk-board-cache.at" 2>/dev/null; return 0; }
  local out me p c id st ow ti now stale_h b
  me="$(_me)"; now="$(_now_epoch)"; stale_h="$(_conf stale_hours 8)"
  local mine="" others="" free="" stale=""
  for p in $(_item_paths); do
    c="$(_cat "$p")"; id="$(_field "$c" id)"; st="$(_field "$c" status)"; ow="$(_field "$c" owner)"; ti="$(_field "$c" title)"
    [ "$st" = done ] && continue
    if [ "$ow" = "$me" ]; then mine="${mine:+$mine; }#$id $ti"
    elif [ -n "$ow" ] && [ "$ow" != "-" ]; then
      others="${others:+$others; }#$id $ow ($(_age "$(_field "$c" since_epoch)"))"
      b="$(_field "$c" beat_epoch)"; case "$b" in ''|*[!0-9]*) b=0;; esac
      [ "$b" -gt 0 ] && [ $(( (now - b) / 3600 )) -ge "$stale_h" ] && stale="${stale:+$stale, }#$id ($ow, $(( (now-b)/3600 ))h)"
    fi
  done
  free="$(_free_ids)"
  out="Team board — held by others: ${others:-none} · yours: ${mine:-none} · claimable: ${free}"

  # Decisions the user has not looked at yet. A decision nobody reads is the same as one nobody wrote, and
  # session start is the only moment it can arrive before the work it would have changed.
  local dtotal dseen dnew p c
  dtotal="$(_decision_paths | wc -l | tr -d ' ')"; dseen="$(_seen_count)"
  dnew=$(( dtotal - dseen )); [ "$dnew" -lt 0 ] && dnew=0
  if [ "$dnew" -gt 0 ]; then
    out="$out
$dnew team decision(s) recorded since you last looked — read them before planning: /board-csk decisions"
    for p in $(_decision_paths | tail -"$dnew"); do
      c="$(_cat "$p")"
      out="$out
  · $(_field "$c" id) $(_field "$c" title) — $(_field "$c" author)"
    done
  fi

  # An open claim you have stopped feeding. Not a block — the damage from a forgotten claim is that the team
  # reads the item as actively held, so it has to be said out loud rather than enforced.
  local om ob
  for p in $(_item_paths); do
    c="$(_cat "$p")"; [ "$(_field "$c" owner)" = "$me" ] || continue
    [ "$(_field "$c" status)" = in_progress ] || continue
    ob="$(_field "$c" since_epoch)"; case "$ob" in ''|*[!0-9]*) ob=0;; esac
    [ "$ob" -gt 0 ] && [ $(( (now - ob) / 3600 )) -ge 8 ] || continue
    om="$(_section "$c" Handover)"
    [ -n "$om" ] && continue
    out="$out
You have held #$(_field "$c" id) for $(_age "$ob") with an empty handover note. If you are still on it, say where it stands (/board-csk note); if not, release it (/board-csk drop)."
  done
  [ -n "$stale" ] && out="$out
Stale claims (no activity for ${stale_h}h+): $stale — ask the owner before taking one over; never steal silently."
  out="$out
Claim before you start: /board-csk claim <id>. Commits are gated on a live claim."
  printf '%s\n' "$out" > "$(_git_dir)/csk-board-cache"
  _now_epoch > "$(_git_dir)/csk-board-cache.at"

  # One-bit flag for the PreToolUse write guard. The guard runs before EVERY file edit, so it must not shell out
  # to this script — on Windows a process costs 62-135 ms and a hot-path fork loop is a freeze. It tests for this
  # file and nothing else: present means "a board exists, it requires a claim, and this user holds none", which
  # is the only state that blocks. Recomputed here, i.e. at session start and after every board command.
  if [ -z "$mine" ] && [ "$(_conf require_item all)" = all ]; then
    : > "$(_git_dir)/csk-board-guard"
  else
    rm -f "$(_git_dir)/csk-board-guard"
  fi
  printf '%s\n' "$out"
}

cmd_sync(){ _fetch && rm -f "$(_git_dir)/csk-board-lasterror" || echo "board: remote unreachable — showing the last known state"; cmd_cache; }

# ---------------------------------------------------------------- decisions
#
# The board carried per-item memory and nothing else, so a decision that shaped the whole project — "refresh
# tokens travel in a header, mobile drops cookies" — reached the person who made it and nobody else. The `adr`
# skill wrote to docs/adr/, and installs gitignore docs/, so those records never left the machine that made
# them. That is the exact failure this board exists to close, one level up from an item.
#
# They live on the same ref as the items, so they travel with the board — including when the board is a
# separate repository. A decision is append-only: superseding one writes a new record that names it.

_decision_paths(){ git ls-tree --name-only "$(_ref)" decisions/ 2>/dev/null; }

_next_decision_id(){
  local last; last="$(_decision_paths | sed -n 's#decisions/\([0-9][0-9]*\)-.*#\1#p' | sort -n | tail -1)"
  printf '%04d' $(( 10#${last:-0} + 1 ))
}

cmd_decide(){ # decide <title> [body] [items]
  local title="${1:-}" body="${2:-}" items="${3:--}" attempt=1 rc
  [ -n "$title" ] || _die 'decide needs a title: board.sh decide "<what was decided>" "<why + what it means for other work>"'
  _enabled || _die "the board is off in this repo (/board-csk on)"
  while [ "$attempt" -le 3 ]; do
    _fetch || true
    _have_board || _die "no board here yet (/board-csk init)"
    local id slug blob tree
    id="$(_next_decision_id)"
    slug="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//' | cut -c1-48)"
    blob="$(printf 'id: %s\ntitle: %s\nauthor: %s\ndate: %s\nepoch: %s\nitems: %s\n--\n%s\n' \
             "$id" "$title" "$(_me)" "$(_now_iso)" "$(_now_epoch)" "$items" "$body" | _blob)"
    tree="$(_tree_with "decisions/$id-$slug.md" "$blob")" || _die "could not build the board tree"
    _commit_push "$tree" "board: decision $id by $(_me)"; rc=$?
    case $rc in
      0) printf 'Decision %s recorded and shared: %s\n' "$id" "$title"; cmd_cache >/dev/null; return 0 ;;
      3) printf 'Decision %s recorded LOCALLY ONLY (remote unreachable) — the team cannot see it yet.\n' "$id"; return 0 ;;
    esac
    attempt=$((attempt+1))   # somebody else recorded one first: re-read so the ids do not collide
  done
  _die "the board kept changing; retry"
}

cmd_decisions(){ # decisions [id]
  _have_board || { echo "No board here (/board-csk init)."; return 0; }
  local p c
  if [ -n "${1:-}" ]; then
    p="$(_decision_paths | grep -m1 "^decisions/$1-")" || true
    [ -n "$p" ] || _die "no decision $1"
    _cat "$p"; _seen_now; return 0
  fi
  local n=0
  for p in $(_decision_paths); do
    c="$(_cat "$p")"
    printf '%s  %s\n    %s · %s\n' "$(_field "$c" id)" "$(_field "$c" title)" "$(_field "$c" author)" "$(_field "$c" date)"
    n=$((n+1))
  done
  [ "$n" = 0 ] && echo "No decisions recorded yet. Record one: /board-csk decide \"<what was decided>\""
  _seen_now
  return 0
}

# "New" means "recorded since you last looked at the board" — the marker moves when the user actually views
# them, not when the cache is rebuilt, or a decision would be announced once to a session nobody was reading.
_seen_now(){ local d; d="$(_git_dir)"; [ -n "$d" ] || return 0
  _decision_paths | wc -l | tr -d ' ' > "$d/csk-board-seen" 2>/dev/null || true; }
# Tested with [ -f ] rather than a redirect plus 2>/dev/null: bash applies redirections left to right, so an
# input redirect from a missing file fails BEFORE stderr is silenced and the complaint reaches the terminal —
# which is how a first-run read leaked an error line into a session-start hook.
_seen_count(){ local d s=""; d="$(_git_dir)"
  [ -n "$d" ] && [ -f "$d/csk-board-seen" ] && s="$(tr -cd '0-9' < "$d/csk-board-seen" 2>/dev/null)"
  printf '%s' "${s:-0}"; }

cmd_off(){ # off [--global]
  git config ${1:+--global} csk.board off
  cmd_cache >/dev/null
  echo "Board OFF${1:+ (global: every repo)}. No claim needed, no commit gate, no edit gate; the board itself is untouched."
  echo "Back on: /board-csk on${1:+ --global}"
}
cmd_on(){
  git config ${1:+--global} --unset csk.board 2>/dev/null || true
  # A --global off would otherwise keep overriding a repo that just turned itself back on, and the user would
  # see "on" printed while nothing changed.
  [ -z "${1:-}" ] && case "$(git config --global --get csk.board 2>/dev/null)" in
    off|false|0|no) git config csk.board on ;;
  esac
  cmd_cache >/dev/null
  _enabled && echo "Board ON. Claim before you start: /board-csk" \
           || echo "Still off — CSK_NO_BOARD is set in this session's environment; unset it."
}

cmd_beat(){
  # "Still on it." A claim with no heartbeat eventually reads as abandoned, and the team is told to ask before
  # taking it over — so an active owner has to publish liveness. Publishing costs a push, so this only ever runs
  # from the DETACHED half of the session-start hook, and only once the mark is half-way to stale: without that
  # guard every session start would add a commit per claim to a ref nobody reads.
  _have_board || return 0
  local me now half p c id ow b
  me="$(_me)"; now="$(_now_epoch)"; half=$(( $(_conf stale_hours 8) * 3600 / 2 ))
  for p in $(_item_paths); do
    c="$(_cat "$p")"; ow="$(_field "$c" owner)"; [ "$ow" = "$me" ] || continue
    [ "$(_field "$c" status)" = in_progress ] || continue
    b="$(_field "$c" beat_epoch)"; case "$b" in ''|*[!0-9]*) b=0;; esac
    [ $(( now - b )) -ge "$half" ] || continue
    id="$(_field "$c" id)"
    _mutate beat "$id" >/dev/null 2>&1 || true
  done
}

# ---------------------------------------------------------------- capability probe + init

cmd_probe(){
  # Some servers refuse refs outside refs/heads|refs/tags (they reserve their own internal namespaces and may
  # reject unknown ones). Rather than assume what a given GitHub/GitLab/Bitbucket install allows, push a tiny
  # throwaway ref and read the answer from the server. On refusal, fall back to an orphan branch, which every
  # server accepts and which enforces the same fast-forward rule the lock depends on.
  #
  # Measured 2026-08-09 against github.com: refs/csk/* ACCEPTED, and the probe ref deleted cleanly afterwards
  # (0 refs left). That is one server on one day, not a guarantee for every host and every org policy — which
  # is why this stays a probe rather than becoming a hard-coded assumption.
  local remote empty probe
  remote="$(_remote)"
  empty="$(git hash-object -w -t tree /dev/null)"
  probe="$(git commit-tree "$empty" -m 'board: capability probe')"
  if _gitnet push --quiet "$remote" "$probe:refs/csk/probe" 2>/dev/null; then
    _gitnet push --quiet "$remote" ":refs/csk/probe" 2>/dev/null
    git config csk.boardRef 'refs/csk/board'
    echo "probe: custom ref namespace accepted -> refs/csk/board (invisible to git branch)"
  else
    git config csk.boardRef 'refs/heads/csk-board'
    echo "probe: server refused refs/csk/* -> falling back to the orphan branch refs/heads/csk-board"
    echo "       (same fast-forward lock; it will appear in the branch list — do not merge it)"
  fi
}

cmd_init(){ # init [--remote <name|url>] [all|referenced]
  # The board defaults to the code repo's own `origin`, which is the case that needs no decision at all: the
  # team already shares it and already has push rights. `--remote` covers the two real reasons to separate them
  # — a board shared across several repos, and members who may read the code repo but not push to it — without
  # anybody having to know that the setting is a git config key.
  if [ "${1:-}" = "--remote" ]; then
    local target="${2:-}"; shift 2 2>/dev/null || true
    [ -n "$target" ] || _die "init --remote needs a remote name or a URL"
    # An existing remote NAME wins; anything else is treated as a location. Deciding by shape alone was wrong:
    # `https://…` and `git@host:org/x.git` were recognised but a filesystem path (a self-hosted mirror, a share,
    # a test fixture) was not, and it failed with "no remote named /srv/board.git" — which reads as a bug.
    if git remote get-url "$target" >/dev/null 2>&1; then
      git config csk.boardRemote "$target"
      echo "board remote: $target"
    else
      if git remote get-url csk-board >/dev/null 2>&1; then git remote set-url csk-board "$target"
      else git remote add csk-board "$target"; fi
      git config csk.boardRemote csk-board
      echo "board remote: csk-board -> $target"
    fi
  fi
  if _have_board; then echo "board already initialised at $(_ref)"; return 0; fi
  # No remote at all is a legitimate solo setup, not an error — a local board still gives you the item list,
  # the dependency order and the commit gate. Say which one you are getting instead of failing at push time
  # with "the remote refused", which reads as a broken tool.
  if ! git remote get-url "$(_remote)" >/dev/null 2>&1; then
    printf 'No remote named "%s" in this repo — creating a LOCAL board.\n' "$(_remote)"
    printf 'It gives you the item list, dependency order and the commit gate, but nothing is shared.\n'
    printf 'To share it later: add a remote, then /board-csk sync. To point elsewhere now: /board-csk init --remote <url>.\n'
    local lblob ltree
    lblob="$(printf 'require_item: %s\nstale_hours: 8\n' "${1:-all}" | _blob)"
    ltree="$(_tree_with config "$lblob")" || _die "could not build the board tree"
    git update-ref "$(_ref)" "$(git commit-tree "$ltree" -m 'board: initialise (local)')"
    cmd_cache >/dev/null
    echo "local board created at $(_ref)"
    return 0
  fi
  _fetch && { echo "board already exists on the remote; fetched it"; cmd_cache >/dev/null; return 0; }
  cmd_probe
  local blob tree
  blob="$(printf 'require_item: %s\nstale_hours: 8\n' "${1:-all}" | _blob)"
  tree="$(_tree_with config "$blob")" || _die "could not build the board tree"
  _commit_push "$tree" "board: initialise"
  case $? in
    0) echo "board initialised at $(_ref) on $(_remote)" ;;
    3) echo "board created LOCALLY ONLY — the remote refused or is unreachable:"; cat "$(_git_dir)/csk-board-lasterror" ;;
  esac
}

# ---------------------------------------------------------------- commit gate (called from commit-msg)

cmd_gate(){ # gate <commit-msg-file>
  local f="${1:-}"; [ -n "$f" ] && [ -f "$f" ] || return 0
  # No board in this repo -> this gate does not exist. Solo users and repos that never ran init are untouched.
  _enabled || return 0
  _have_board || return 0
  # Strip comments git adds to the message template before matching.
  local msg; msg="$(grep -v '^#' "$f" 2>/dev/null)"
  local id; id="$(printf '%s' "$msg" | grep -oE '\[#[0-9]+\]' | head -1 | tr -dc '0-9')"
  if [ -z "$id" ]; then
    printf '%s' "$msg" | grep -qE '\[chore\]' && return 0
    [ "$(_conf require_item all)" = referenced ] && return 0
    cat >&2 <<'MSG'
BOARD GATE: this commit names no board item.
  Put [#<id>] in the message for the item you are working on, or [chore] for work that
  belongs to no item (it is recorded, not blocked).
  See what is claimable: /board-csk
MSG
    return 1
  fi
  local c owner status
  c="$(_load "$id")" || { printf 'BOARD GATE: no item #%s on the board (stale board? run /board-csk sync)\n' "$id" >&2; return 1; }
  owner="$(_field "$c" owner)"; status="$(_field "$c" status)"
  local me; me="$(_me)"
  if [ "$owner" != "$me" ]; then
    printf 'BOARD GATE: #%s is held by %s, not you. Claim it or pick another: /board-csk\n' "$id" "${owner:--}" >&2
    printf '            (if you believe this is stale, run /board-csk sync first)\n' >&2
    return 1
  fi
  [ "$status" = in_progress ] || { printf 'BOARD GATE: #%s is "%s", not in_progress. Run: /board-csk claim %s\n' "$id" "$status" "$id" >&2; return 1; }
  # Deliberately no heartbeat refresh here: publishing one costs a push, and a commit must work offline and
  # must not be slowed by the network. The heartbeat is advanced by the board commands and at session start.
  return 0
}

# ---------------------------------------------------------------- dispatch

usage(){ cat <<'U'
board.sh <command>
  status                    board view: who holds what, what is claimable, what is blocked
  show <id>                 one item with its shared handover / completion memory
  claim <id>                atomic claim (fetch -> verify -> push; a lost race refuses, it never overwrites)
  done <id> [note]          complete, record the note, unblock dependents
  drop <id> <note>          release; the handover note is REQUIRED
  note <id> <text>          update the item's handover memory without releasing it
  add <id> <title> [deps] [external]
  init [--remote <name|url>] [all|referenced]
                            create the board (probes ref support first). Defaults to `origin`; --remote points
                            it at a separate board repository (a URL gets its own `csk-board` remote).
  probe                     ask the server whether it accepts the custom ref namespace
  off [--global] / on       switch every board gate off (or back on) for this repo, or for every repo.
                            A repo that never ran `init` has no gates in the first place.
  decide "<what>" "<why + what it means for other work>" [items]
                            record a team decision on the board so it reaches everyone, not just this machine
  decisions [id]            list them, or read one
  sync                      fetch the board and refresh the local cache
  cache                     rebuild the local cache (no network)
  gate <msgfile>            commit-msg claim gate
U
}

git rev-parse --git-dir >/dev/null 2>&1 || _die "not a git repository"
CMD="${1:-status}"; shift 2>/dev/null || true
case "$CMD" in
  status) cmd_status ;;
  show)   cmd_show "$@" ;;
  claim)  cmd_claim "$@" ;;
  done)   cmd_done "$@" ;;
  drop)   cmd_drop "$@" ;;
  note)   cmd_note "$@" ;;
  add)    cmd_add "$@" ;;
  init)   cmd_init "$@" ;;
  probe)  cmd_probe ;;
  decide) cmd_decide "$@" ;;
  decisions) cmd_decisions "$@" ;;
  sync)   cmd_sync ;;
  cache)  cmd_cache ;;
  beat)   cmd_beat ;;
  off)    cmd_off "$@" ;;
  on)     cmd_on "$@" ;;
  gate)   cmd_gate "$@" ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
