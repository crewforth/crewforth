#!/usr/bin/env bash
# agent-outcome.sh - what became of a crew agent's work: verified, fixed once, recorded, and told to the session.
#
# WHY. Whether a model was enough for a piece of work cannot be known before the work; it can be measured after it.
# The card a crew agent is called with (hooks/guard-agent-model.sh) names a verify command. This hook runs it when
# the agent stops, so a cheap model that was not enough costs one more run and not broken code, and the record of
# what happened is what the next choice is made from.
#
# FOUR EVENTS, one script (the wiring is in settings.json / hooks.json):
#   SubagentStart        the call's record, written by the gate when it allowed the call, is matched to the agent
#                        that has just started: from here on the agent's id names its model, card and class.
#   SubagentStop         the verify command is run in the project.
#                          green                    -> pass.
#                          red, the first time      -> the agent is kept running, once, with the failing command and
#                                                      the end of its output as its next instruction.
#                          red, the second time     -> the agent ends; the result is fail, and the card is marked so
#                                                      the gate refuses it on the same or a lower model.
#                          not a command a hook may run (it chains, or the shell gate would refuse or ask)
#                                                   -> blocked: not run, nothing concluded.
#                          not finished in CREW_VERIFY_TIMEOUT seconds (540)
#                                                   -> timeout: stopped, nothing concluded.
#                        Then one line is added to .claude/state/model-outcomes.tsv, and the class is looked at:
#                        where the first try failed too often, its floor goes one model up (crew-model-floors.auto).
#                        Only ever up: lowering a floor is the user's decision and nothing here does it.
#   PostToolUse (Agent)  a foreground call has come back. If its verify failed, or its report closed with
#                        confidence: low, the session is told to repeat the task once, one model up, and to ask
#                        the user if that fails too. A background call comes back before its agent has finished,
#                        so nothing is said then; the record and the gate still hold.
#   SessionStart, --scan the project's critical paths are listed in .claude/state/crew-critical-paths.auto, when the
#                        list of files has changed. A generated file: the gate does not read it, it reads the paths.
#
# Measured on Claude Code 2.1.294 before this was written: an agent's Edit carries its agent_id, and it is the id
# SubagentStart was given and the one PostToolUse(Agent) returns as agentId; a SubagentStop that answers "block"
# keeps the agent working and the agent acts on the reason; PostToolUse's additionalContext reaches the session.
#
# THIS IS NOT A GATE. It cannot undo what an agent wrote, and when it fails it fails OPEN: a stop hook that refused
# on its own error would keep an agent running for ever. What stops broken work is the repeat one model up and the
# review before a commit. CREW_MODEL_ROUTING=off: nothing here does anything.
#
# THE VERIFY COMMAND comes from the card, which the session wrote, and would run here where no PreToolUse gate sees
# it. So it is one command with nothing chained to it, and it is handed to hooks/guard-bash.sh first, as the Bash
# call it would be: what that gate refuses, or would ask the user about, is not run (_am_verify_ok, one function,
# asked by the gate when the agent is called and here again when the command would start).
set -uo pipefail
export LC_ALL=C
[ "${CREW_MODEL_ROUTING:-}" = off ] && exit 0
_ao_here="${BASH_SOURCE%/*}"; [ "$_ao_here" = "${BASH_SOURCE}" ] && _ao_here=.
[ -f "$_ao_here/guard-agent-model.sh" ] || exit 0
. "$_ao_here/guard-agent-model.sh"
declare -F _am_state >/dev/null 2>&1 || exit 0
_am_state

_ao_now(){ if [ "${BASH_VERSINFO[0]}" -ge 5 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then printf -v _AON '%(%Y-%m-%dT%H:%M:%SZ)T' -1; else _AON="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; fi; }
_ao_json(){  # $1 = text -> _AOJ, safe inside a JSON string
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\t'/ }"; s="${s//$'\r'/}"
  _AOJ="$(printf '%s' "$s" | tr -d '\000-\010\013-\037\177')"
}

# ---- the list of critical paths (SessionStart, or `--scan` from the installers) ----------------------------------
_ao_scan(){
  local out="$_AMS/crew-critical-paths.auto" stamp="$_AMS/crew-critical-paths.stamp" list sum old="" f rest seg pre n=0
  [ -d "$_AMP/.claude" ] || return 0
  if git -C "$_AMP" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    list="$(git -C "$_AMP" ls-files -co --exclude-standard 2>/dev/null)" || return 0
  else
    list="$(cd "$_AMP" 2>/dev/null && find . \( -name .git -o -name node_modules -o -name .claude \) -prune -o -type f -print 2>/dev/null | sed 's|^\./||')" || return 0
  fi
  sum="$(printf '%s\n' "$list" | cat - "$_AMP/.claude/crew-model-rules" 2>/dev/null | cksum)"; sum="${sum%% *}"
  [ -f "$stamp" ] && IFS= read -r old < "$stamp"
  [ "$1" != force ] && [ "$old" = "$sum" ] && [ -f "$out" ] && return 0
  mkdir -p "$_AMS" 2>/dev/null || return 0
  {
    echo "# Generated by Crewforth (hooks/agent-outcome.sh). Do not edit: it is written again when the files change."
    echo "# The paths of this project that are critical for model routing: work that touches one runs on opus."
    echo "# To add or remove a path, write .claude/crew-model-rules ('+ <glob>' adds, '- <glob>' removes)."
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      case "$f" in .claude/*|.git/*) continue ;; esac          # Crewforth's own files and git's are not the project's work
      n=$((n+1)); [ "$n" -le 20000 ] || { echo "# stopped after 20000 files: the rest was not read"; break; }
      _am_crit_path "$f" || continue
      # The shortest leading part of the path that is critical by itself: a folder is listed once, not per file.
      pre=""; rest="$f"
      while :; do
        seg="${rest%%/*}"; pre="${pre:+$pre/}$seg"
        [ "$seg" = "$rest" ] && break
        rest="${rest#*/}"
        if _am_crit_path "$pre"; then pre="$pre/"; break; fi
      done
      printf '%s\n' "$pre"
    done <<< "$list" | sort -u
  } > "$out.tmp" 2>/dev/null && mv "$out.tmp" "$out" 2>/dev/null && printf '%s\n' "$sum" > "$stamp" 2>/dev/null
  return 0
}
case "${1:-}" in --scan) _ao_scan force; exit 0 ;; esac

IFS= read -r -d '' INPUT || true
_json_slice "$INPUT" hook_event_name >/dev/null; EV="$_JS"

# ---- the class's floor, after a result (tightening only) --------------------------------------------------------
# A class is agent x change x risk. Where at least CREW_MODEL_CAL_N (5) of its calls on one model had a verify
# command, and more than CREW_MODEL_CAL_PCT (20) percent of them did not pass on the first try, the class is held
# one model up. Both numbers are a starting point that has not been measured.
_ao_calibrate(){  # $1 agent, $2 change, $3 risk
  local tsv="$_AMS/model-outcomes.tsv" fl="$_AMS/crew-model-floors.auto" want cur="" a b c t rest keep=""
  [ -f "$tsv" ] || return 0
  want="$(awk -F'\t' -v A="$1" -v C="$2" -v R="$3" -v N="${CREW_MODEL_CAL_N:-5}" -v P="${CREW_MODEL_CAL_PCT:-20}" '
    NR > 1 && $3 == A && $4 == C && $5 == R && ($8 == "pass" || $8 == "fail") { n[$7]++; if ($8 == "fail" || $9 + 0 > 0) bad[$7]++ }
    END { r["haiku"] = 1; r["sonnet"] = 2; r["opus"] = 3; nm[2] = "sonnet"; nm[3] = "opus"; best = 0
          for (m in n) if (r[m] > 0 && r[m] < 3 && n[m] >= N && bad[m] * 100 > P * n[m] && r[m] + 1 > best) { best = r[m] + 1; bn = n[m]; bb = bad[m] + 0 }
          if (best) printf "%s\t%d\t%d", nm[best], bn, bb }' "$tsv" 2>/dev/null)" || return 0
  [ -n "$want" ] || return 0
  if [ -f "$fl" ]; then
    while IFS=$'\t' read -r a b c t rest || [ -n "$a" ]; do
      case "$a" in ''|'#'*) continue ;; esac
      if [ "$a" = "$1" ] && [ "$b" = "$2" ] && [ "$c" = "$3" ]; then cur="$t"; else keep="$keep$a"$'\t'"$b"$'\t'"$c"$'\t'"$t"$'\t'"$rest"$'\n'; fi
    done < "$fl"
  fi
  _am_rank "$cur"; a="$_AMR"; _am_rank "${want%%$'\t'*}"
  [ "$_AMR" -gt "$a" ] || return 0
  _ao_now
  { echo "# Generated by Crewforth (hooks/agent-outcome.sh) from model-outcomes.tsv. A class held above its usual model"
    echo "# because its first try failed too often one model down. agent, change, risk, model, calls, not-first-try, when."
    echo "# Nothing lowers a line here but the user."
    printf '%s' "$keep"
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$want" "$_AON"; } > "$fl.tmp" 2>/dev/null && mv "$fl.tmp" "$fl" 2>/dev/null
  return 0
}

case "$EV" in
  SessionStart) _ao_scan auto; exit 0 ;;

  SubagentStart)
    _json_slice "$INPUT" agent_id >/dev/null; AID="$_JS"
    _json_slice "$INPUT" agent_type >/dev/null; AT="${_JS##*:}"
    case "$AID" in ''|*[!A-Za-z0-9._-]*) exit 0 ;; esac
    case "$AT" in crew-*) ;; *) exit 0 ;; esac
    [ -d "$_AMD/pending" ] || exit 0
    # The oldest call of this agent type that no agent has taken yet. Two calls of one type made together can start
    # in either order; where they ask for different models the agent is recorded on the LOWER one, so the check at
    # write time errs towards refusing.
    # A call the gate allowed and nothing started (another hook refused it, the user did) leaves its record behind.
    # An agent starts within moments of its call, so a record older than five minutes is nobody's and is dropped.
    pick=""; low=9; if [ "${BASH_VERSINFO[0]}" -ge 5 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then printf -v NOWS '%(%s)T' -1; else NOWS="$(date +%s)"; fi
    for f in "$_AMD/pending"/*; do
      [ -f "$f" ] || continue
      t="${f##*/}"; t="${t%%-*}"; case "$t" in ''|*[!0-9]*) ;; *) if [ $((NOWS - t)) -gt 300 ]; then rm -f "$f" 2>/dev/null; continue; fi ;; esac
      _am_rec_get "$f" agent || continue; [ "$_AMV" = "$AT" ] || continue
      [ -n "$pick" ] || pick="$f"
      _am_rec_get "$f" tier && { _am_rank "$_AMV"; [ "$_AMR" -lt "$low" ] && low="$_AMR"; }
    done
    [ -n "$pick" ] || exit 0
    mkdir -p "$_AMD/agents" 2>/dev/null || exit 0
    _am_rec_get "$pick" tier; _am_rank "$_AMV"
    if [ "$low" -lt "$_AMR" ]; then _am_name "$low"
      { grep -v '^tier=' "$pick"; printf 'asked=%s\ntier=%s\nambiguous=1\n' "$_AMV" "$_AMN"; } > "$_AMD/agents/$AID" 2>/dev/null
    else { cat "$pick"; printf 'asked=%s\n' "$_AMV"; } > "$_AMD/agents/$AID" 2>/dev/null; fi
    rm -f "$pick" 2>/dev/null
    exit 0 ;;

  SubagentStop)
    _json_slice "$INPUT" agent_id >/dev/null; AID="$_JS"
    case "$AID" in ''|*[!A-Za-z0-9._-]*) exit 0 ;; esac
    REC="$_AMD/agents/$AID"
    [ -f "$REC" ] || exit 0
    [ -f "$_AMD/results/$AID" ] && exit 0            # an agent that is resumed stops again: its work was judged once
    _am_rec_get "$REC" verify; VCMD="$_AMV"
    _am_rec_get "$REC" agent; AG="$_AMV"; _am_rec_get "$REC" change; CH="$_AMV"; _am_rec_get "$REC" risk; RK="$_AMV"
    _am_rec_get "$REC" card; CID="$_AMV"; _am_rec_get "$REC" asked; ASK="$_AMV"; _am_rec_get "$REC" esc; ESC="${_AMV:--}"
    mkdir -p "$_AMD/results" "$_AMD/tries" "$_AMD/fails" 2>/dev/null || exit 0
    TRIES=0; [ -f "$_AMD/tries/$AID" ] && IFS= read -r TRIES < "$_AMD/tries/$AID"; case "$TRIES" in ''|*[!0-9]*) TRIES=0 ;; esac
    RES=none; WHYNOT=""
    if [ -n "$VCMD" ] && [ "$VCMD" != none ]; then
      _json_slice "$INPUT" permission_mode >/dev/null; PM="$_JS"; _json_slice "$INPUT" session_id >/dev/null; SID="$_JS"
      if ! _am_verify_ok "$VCMD" "$PM" "$SID"; then
        # Judged again here, at the moment it would run: the gate judged it when the agent was called, and this
        # is the place the command actually starts. Not run; nothing is concluded about the work.
        RES=blocked; WHYNOT="$_AMVW"; VRC=0
      else
        # A time limit of its own, below the hook's: a hook killed at its timeout records nothing, and a verify
        # that hangs must not read as a pass or as a fail.
        LIM="${CREW_VERIFY_TIMEOUT:-540}"; case "$LIM" in ''|*[!0-9]*) LIM=540 ;; esac
        VF="$_AMD/tries/$AID.out"
        ( cd "$_AMP" 2>/dev/null && exec bash -c "$VCMD" ) > "$VF" 2>&1 </dev/null &
        VPID=$!; WAITED=0; VRC=""
        while kill -0 "$VPID" 2>/dev/null; do
          if [ "$WAITED" -ge "$LIM" ]; then pkill -P "$VPID" 2>/dev/null; kill "$VPID" 2>/dev/null; VRC=timeout; break; fi
          sleep 1; WAITED=$((WAITED+1))
        done
        if [ "$VRC" = timeout ]; then wait "$VPID" 2>/dev/null; RES=timeout; WHYNOT="it did not finish in ${LIM}s"; VRC=0
        else wait "$VPID" 2>/dev/null; VRC=$?; fi
        VOUT="$(tail -n 15 "$VF" 2>/dev/null)"; rm -f "$VF" 2>/dev/null
      fi
      if [ "$RES" = blocked ] || [ "$RES" = timeout ]; then :
      elif [ "$VRC" = 0 ]; then RES=pass
      elif [ "$TRIES" = 0 ]; then
        printf '1\n' > "$_AMD/tries/$AID" 2>/dev/null
        TAILV="$(printf '%s\n' "$VOUT" | tail -n 15)"; TAILV="${TAILV:0:1500}"
        _ao_json "The verify command of your task failed (exit $VRC): $VCMD"$'\n'"The end of its output:"$'\n'"$TAILV"$'\n'"Fix the work so that the command passes, then finish. This is asked once: if it fails again your report is taken as it is."
        printf '{"decision":"block","reason":"%s"}\n' "$_AOJ"
        exit 0
      else RES=fail; fi
    fi
    # The report's last line, and the model the agent's own transcript names.
    _json_slice "$INPUT" last_assistant_message >/dev/null; LAST="$_JS"; [ "${#LAST}" -gt 400 ] && LAST="${LAST:${#LAST}-400}"
    _json_unescape "$LAST" >/dev/null; LAST="$_JU"
    while :; do case "$LAST" in *[$' \t\n\r']) LAST="${LAST%?}" ;; *) break ;; esac; done
    ESCL=0; case $'\n'"$LAST" in *$'\n'"escalate:"*) ESCL=1 ;; esac      # a write to a critical path was refused
    LAST="${LAST##*$'\n'}"
    case "$LAST" in "confidence: high") CONF=high ;; "confidence: low") CONF=low ;; *) CONF=- ;; esac
    _json_slice "$INPUT" agent_transcript_path >/dev/null; _json_unescape "$_JS" >/dev/null; ATP="${_JU//\\//}"
    RAN=-; if [ -f "$ATP" ]; then RAN="$(grep -m1 -o '"model":"[^"]*"' "$ATP" 2>/dev/null)" || RAN=""; RAN="${RAN#\"model\":\"}"; RAN="${RAN%\"}"; case "$RAN" in ''|*[!A-Za-z0-9._:\[\]-]*) RAN=- ;; esac; fi
    [ "$RES" = fail ] && printf '%s\n' "$ASK" >> "$_AMD/fails/$CID" 2>/dev/null
    printf 'verify=%s\nfixes=%s\nconfidence=%s\ntier=%s\nesc=%s\nescalate=%s\nwhynot=%s\ncmd=%s\n' "$RES" "$TRIES" "$CONF" "$ASK" "$ESC" "$ESCL" "$WHYNOT" "$VCMD" > "$_AMD/results/$AID" 2>/dev/null
    TSV="$_AMS/model-outcomes.tsv"
    [ -s "$TSV" ] || printf 'ts\tagent_id\tagent\tchange\trisk\tcard\tmodel\tverify\tfixes\tescalated_from\tran_on\tconfidence\n' > "$TSV" 2>/dev/null
    _ao_now
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$_AON" "$AID" "$AG" "$CH" "$RK" "$CID" "$ASK" "$RES" "$TRIES" "$ESC" "$RAN" "$CONF" >> "$TSV" 2>/dev/null
    case "$RES" in pass|fail) _ao_calibrate "$AG" "$CH" "$RK" ;; esac
    exit 0 ;;

  PostToolUse)
    _json_slice "$INPUT" tool_name >/dev/null; case "$_JS" in Agent|Task) ;; *) exit 0 ;; esac
    _json_slice "$INPUT" agentId >/dev/null; AID="$_JS"
    case "$AID" in ''|*[!A-Za-z0-9._-]*) exit 0 ;; esac
    R="$_AMD/results/$AID"; [ -f "$R" ] || exit 0
    _am_rec_get "$R" verify; RES="$_AMV"; _am_rec_get "$R" confidence; CONF="$_AMV"; _am_rec_get "$R" tier; TI="$_AMV"
    _am_rec_get "$R" esc; ESC="$_AMV"; _am_rec_get "$R" cmd; VCMD="$_AMV"
    case "$RES" in fail|blocked|timeout) ;; *) [ "$CONF" = low ] || exit 0 ;; esac
    if [ "$RES" = blocked ] || [ "$RES" = timeout ]; then
      # Nothing is known about the work, so nothing is escalated: the session runs the command where a gate sees it.
      _am_rec_get "$R" whynot; WN="$_AMV"
      _ao_json "Crewforth: the agent's verify command was NOT run by the hook ($VCMD): $WN. Nothing is concluded about the work. Run the verify command yourself with the Bash tool and judge the result; do not repeat the task on another model for this."
      printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "$_AOJ"
      exit 0
    fi
    _am_rank "$TI"; _am_name $((_AMR+1)); UP="$_AMN"
    _am_rec_get "$R" escalate; ESCL="$_AMV"
    if [ "$RES" = fail ]; then MSG="verify failed after one in-agent fix ($VCMD)."; TAILM="The work the agent left is in the tree and has NOT passed its verify command."
    else MSG="the agent closed its report with confidence: low."; TAILM="What the agent left is in the tree; read its report for what it could not do."; fi
    # A write refused on a critical path is not helped by one model up: that file takes opus.
    if [ "$ESCL" = 1 ] && [ "$TI" != opus ] && [ "$TI" != fable ]; then UP=opus; MSG="$MSG It was refused a write to a critical path, which only an agent on opus may make; name that file in the card."; fi
    if [ "$ESC" != - ] && [ -n "$ESC" ]; then MSG="$MSG This was already the repeat one model up (first run: $ESC). Do not run it a third time: ask the user what to do (AskUserQuestion), with what failed and on which models."
    elif [ -z "$UP" ] || [ "$UP" = fable ]; then MSG="$MSG It ran on $TI and there is no model above it to repeat on: ask the user what to do (AskUserQuestion)."
    else MSG="$MSG Re-run this task once with $UP: the same card, the same agent, model $UP. If that also fails, ask the user."; fi
    _ao_json "Crewforth: $MSG $TAILM"
    printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "$_AOJ"
    exit 0 ;;
esac
exit 0
