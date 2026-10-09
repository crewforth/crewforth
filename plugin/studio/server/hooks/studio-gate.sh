#!/usr/bin/env bash
# PreToolUse bridge: park the decision, ask the panel, answer with an exit code.
#
# The harness kills a hook that outruns its timeout and then lets the tool
# proceed — measured on this machine: a hook sleeping past a 3s limit produced
# permission_denials=0 and the command ran. So this never reaches that limit.
# It decides for itself at CREW_GATE_WAIT seconds, well inside the timeout
# configured in the settings file, and a hook the harness never has to kill
# fails CLOSED.
#
# No jq: Crewforth's hooks run on stock Git Bash, which has none. The fields
# needed here are flat strings, and parameter expansion reads them without
# spawning anything.
#
# Usage: studio-gate.sh <spool-dir>
set -u

SPOOL="${1:-}"
[ -n "$SPOOL" ] || exit 0                 # misconfigured: do not stand in the way

WAIT="${CREW_GATE_WAIT:-45}"
POLL_MS=150

IN=""
# Bounded read: an open-but-silent stdin must not hang the session.
while IFS= read -r -t "${CREW_STDIN_TIMEOUT:-5}" line || [ -n "$line" ]; do
  IN="$IN$line"
  line=""
done

# ---- flat-string extraction, no subprocesses -------------------------------
_field() {                                 # _field <key>  -> value on stdout
  local r="${IN#*\"$1\":\"}"
  [ "$r" = "$IN" ] && return 1
  printf '%s' "${r%%\"*}"
}

# ---- what "allowed" says to Claude Code --------------------------------------
# Exit 0 with nothing on stdout is not an approval: the harness reads it as "no
# decision" and sends the call through its own permission flow, and a headless
# session has nobody to ask. Measured in real sessions (Claude Code 2.1.284): in
# `default` mode Edit, Write and a writing Bash were all refused AFTER the viewer
# allowed them here, and in `acceptEdits` the Bash was. So an allowance given in
# the panel is said out loud, as the JSON decision the harness documents.
#
# Never in plan mode. The mode is an allow-list of two, and it has to agree with
# what the harness itself reports for the session: a hook configured for
# `default` that finds the session in `plan` stays silent, and so does one with
# no mode, or with a mode this file does not name. Silence leaves plan's own
# blocks, and every other check the harness makes, exactly where they were.
#
# This approves the call the viewer was shown. It does not unblock anything:
# another hook that exits 2 still blocks, and this hook's own denials are exit 2.
# The mode is the spool's `mode` file when there is one, and the mode the hook was configured with otherwise. The
# file starts as the mode the session started in and changes in exactly one way: the viewer approves a plan, in
# the panel, into acceptEdits or default (permissions.js `decide`). A session that started in plan mode could not
# otherwise ever have an allowance said out loud, plan approved or not. The check against what the harness itself
# reports, below, stays: a file that says `default` approves nothing while the session is still in `plan`.
_grant() {
  local gm="${CREW_GATE_MODE:-}"
  if [ -f "$SPOOL/mode" ]; then
    read -r gm < "$SPOOL/mode" 2>/dev/null || gm=""
  fi
  case "$gm" in
    acceptEdits|default) ;;
    *) exit 0 ;;
  esac
  case "$(_field permission_mode || true)" in
    ''|acceptEdits|default) ;;
    *) exit 0 ;;
  esac
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"allowed in Crewforth Studio"}}'
  exit 0
}

TOOL="$(_field tool_name || true)"
TUID="$(_field tool_use_id || true)"
SID="$(_field session_id || true)"
[ -n "$TOOL" ] || exit 0                   # nothing to ask about

# Ids become filenames; anything unexpected is refused rather than sanitised
# into something that might escape the spool.
case "$TUID" in
  ''|*[!A-Za-z0-9_-]*) TUID="unknown-$$" ;;
esac

REQ="$SPOOL/req"; ANS="$SPOOL/ans"; ALWAYS="$SPOOL/always"

# The two tools that need a person. Claude Code offers them in a headless session only because Studio names a
# permission host for it (studio-host.mjs); what answers them is this hook, from what the viewer chose in the
# panel. A question and a plan take longer to read than one command, so they wait longer before the denial.
ASK=0
case "$TOOL" in
  AskUserQuestion|ExitPlanMode) ASK=1; WAIT="${CREW_GATE_WAIT_ASK:-$WAIT}" ;;
esac
mkdir -p "$REQ" "$ANS" "$ALWAYS" 2>/dev/null || exit 0

# A tool the panel already blanket-approved for this session skips the round trip.
# It is NOT approved out loud: nobody saw this call. The hook stays silent and the
# harness decides as it would have without a panel, so a call it wants a person
# for — a commit, anything a project's settings mark `ask` — is still refused in
# a headless session instead of running unseen. _grant is for a call a person
# answered, and only for that one.
case "$TOOL" in
  *[!A-Za-z0-9_-]*) ;;                     # odd tool name: never treated as approved
  *) [ -f "$ALWAYS/$TOOL" ] && exit 0 ;;
esac

# The request carries the whole hook payload, so the panel can show the command
# itself rather than just the tool's name.
printf '%s' "$IN" > "$REQ/$TUID.json" 2>/dev/null || exit 0

# The wait must not cost a process per poll. On Git Bash a fork is 20-50 ms, so
# a naive `date` + `sleep` loop spends seconds of pure overhead on every prompt
# and freezes the session it is meant to be guarding.
#
#   deadline  -> SECONDS, a shell builtin, instead of `date +%s`
#   the pause -> a bounded read on a fifo held open read-write, which blocks for
#                the timeout and never sees EOF; zero processes per iteration
#
# The fifo is probed rather than assumed: it is emulated on Windows and may
# return immediately. If it does, fall back to sleep at a coarser interval.
FIFO="$SPOOL/.wait.$$"

# Pausing without forking. On Git Bash a fork is 20-50 ms, so a `sleep` per poll
# spends seconds of overhead on a prompt that is supposed to feel instant.
#
# A bounded read on a fifo held open read-write blocks for its timeout and never
# sees EOF, which costs no process at all. Two things about it have to be
# measured rather than assumed:
#
#   - the fifo may be emulated (Windows) and return immediately
#   - bash 3.2, still the system shell on macOS, ignores a FRACTIONAL -t and
#     returns instantly, turning the poll into a hot spin on a whole core
#
# So the probe runs exactly what the loop will run. Probing with a different
# timeout than the loop uses is how the first version of this passed while
# spinning 185,000 times in five seconds.
fifo_fast() { read -r -t 0.15 _ <&9 2>/dev/null || :; }
fifo_slow() { read -r -t 1 _ <&9 2>/dev/null || :; }
sleep_pause() { sleep 1; }

PAUSE=sleep_pause

# The probe costs about a second, and it answers the same question every time
# for a given machine. Measure once per spool and remember.
CACHE="$SPOOL/.pause-mode"
if [ -f "$CACHE" ]; then
  read -r _cached < "$CACHE" 2>/dev/null || _cached=""
  case "$_cached" in
    fifo_fast|fifo_slow|sleep_pause) PAUSE="$_cached" ;;
  esac
fi

_probe() {                                   # _probe <fn> <min-ms>; 0 if it really waited
  local t0 t1
  t0=$SECONDS
  "$1"
  t1=$SECONDS
  [ $(( t1 - t0 )) -ge "$2" ]
}

if [ "$PAUSE" = sleep_pause ] && [ ! -f "$CACHE" ] && mkfifo "$FIFO" 2>/dev/null; then
  # `exec` with redirections and no command rebinds the SHELL's descriptors, so
  # `exec 9<>"$FIFO" 2>/dev/null` silences stderr for the rest of the hook's
  # life — every denial message with it. Save it, then put it back.
  exec 7>&2
  if exec 9<>"$FIFO" 2>/dev/null; then
    exec 2>&7 7>&-
    rm -f "$FIFO" 2>/dev/null               # unlinked; the open descriptor keeps it alive
    # Fractional first. Ten of them must add up to at least a second, or this
    # shell is not honouring the fraction.
    _t0=$SECONDS
    fifo_fast; fifo_fast; fifo_fast; fifo_fast; fifo_fast
    fifo_fast; fifo_fast; fifo_fast; fifo_fast; fifo_fast
    if [ $(( SECONDS - _t0 )) -ge 1 ]; then
      PAUSE=fifo_fast
    elif _probe fifo_slow 1; then
      PAUSE=fifo_slow                        # whole seconds, still no forks
    fi
  else
    exec 2>&7 7>&-
    rm -f "$FIFO" 2>/dev/null
  fi
  printf '%s\n' "$PAUSE" > "$CACHE" 2>/dev/null || :
fi

# A cached fifo mode still needs its descriptor in this process.
case "$PAUSE" in
  fifo_*)
    if [ ! -e /dev/fd/9 ]; then
      if mkfifo "$FIFO" 2>/dev/null; then
        exec 7>&2
        exec 9<>"$FIFO" 2>/dev/null || PAUSE=sleep_pause
        exec 2>&7 7>&-
        rm -f "$FIFO" 2>/dev/null
      else
        PAUSE=sleep_pause
      fi
    fi
    ;;
esac

START=$SECONDS
while :; do
  if [ -f "$ANS/$TUID" ]; then
    VERDICT=deny; OUT=""
    # Two lines at most: the verdict, and for an answered question or an approved plan the output to print.
    { IFS= read -r VERDICT; IFS= read -r OUT; } < "$ANS/$TUID" 2>/dev/null || :
    rm -f "$ANS/$TUID" "$REQ/$TUID.json" 2>/dev/null
    case "$ASK:$VERDICT" in
      0:allow|0:always) _grant ;;
      # The viewer's answers, or their approval of the plan, exactly as the server wrote them: `allow` with the
      # tool's input, which is how the hooks reference says a hook answers these two tools. Printed only for them,
      # and only when there is something to print.
      1:output) [ -n "$OUT" ] || { printf 'studio: the answer could not be read — denied\n' >&2; exit 2; }
                printf '%s\n' "$OUT"; exit 0 ;;
      # A plan approved with a change of mode. The hook cannot change the mode, so it says nothing and the
      # permission host, which can, answers from what the viewer chose.
      1:host) [ "$TOOL" = ExitPlanMode ] && exit 0
              printf 'studio: denied in the panel\n' >&2; exit 2 ;;
      *) printf 'studio: denied in the panel\n' >&2; exit 2 ;;
    esac
  fi
  [ $(( SECONDS - START )) -ge "$WAIT" ] && break
  "$PAUSE"
done

rm -f "$REQ/$TUID.json" 2>/dev/null
printf 'studio: no answer within %ss — denied\n' "$WAIT" >&2
exit 2
