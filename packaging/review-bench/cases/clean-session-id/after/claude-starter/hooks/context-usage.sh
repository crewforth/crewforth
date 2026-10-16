#!/usr/bin/env bash
# Measures session context fill for REAL (NOT a guess): reads the API usage of the last main-context
# turn in the transcript JSONL -> input + cache_read + cache_creation = tokens in the context window.
# This is the number /context shows; since the assistant cannot run /context, it reads directly from here.
#
# Usage:
#   bash context-usage.sh [transcript.jsonl]            # if no arg is given, auto-finds from pwd
#   bash context-usage.sh --verbose [transcript.jsonl]  # long form, with the raw token counts
#   echo '{"transcript_path":"..."}' | bash context-usage.sh   # also accepts hook stdin JSON
# Window size: CONTEXT_WINDOW env (default 1000000).
#
# The default output is COMPACT on purpose. The UserPromptSubmit hook injects this line into the model's
# context on EVERY turn, and it stays there for the rest of the session — a long line is a per-turn tax that
# compounds through cache reads. The percentage carries all the signal; the raw counts are for humans, so they
# live behind --verbose (which is what session-guard.sh uses for its once-per-threshold user warning).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WINDOW="${CONTEXT_WINDOW:-1000000}"
VERBOSE=0
case "${1:-}" in --verbose|-v) VERBOSE=1; shift ;; esac
TR="${1:-}"

# A path that arrived inside the hook's stdin JSON is JSON-ENCODED, and on Windows that matters: the real value
# `C:\Users\me\.claude\projects\p\a.jsonl` is transmitted as `C:\\Users\\me\\...`. Slicing it out with sed hands
# back the doubled backslashes verbatim, so every `[ -f "$TR" ]` failed and the hook reported "transcript not
# found" on every single turn — on Windows CLI and on Claude Desktop alike. It read like the hook was being
# called without stdin; it was being called correctly and then throwing the answer away.
#
# So: undo the JSON escaping, then fold the separators. `\\` -> `/` first (the encoded form), then any lone `\`
# (a value that was never encoded, e.g. an argument typed by hand). Forward slashes resolve on every platform
# including Git Bash. A POSIX path contains neither, so this is a no-op there.
unjson_path(){ p="${1//\\\\//}"; p="${p//\\//}"; printf '%s' "$p"; }

IN=""
# 1) transcript_path from hook stdin (if present)
if [ -z "$TR" ] && [ ! -t 0 ]; then
  IN="$(cat 2>/dev/null || true)"
  [ -n "$IN" ] && TR="$(printf '%s' "$IN" | sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
fi
[ -n "$TR" ] && TR="$(unjson_path "$TR")"
# 2) still missing: find the project transcript dir from pwd (client: / and . -> -)
if [ -z "$TR" ]; then
  for esc in "$(pwd | sed 's#[/.]#-#g')" "$(pwd | sed 's#/#-#g')"; do
    cand="$(ls -t "$HOME/.claude/projects/$esc"/*.jsonl 2>/dev/null | head -1)"
    [ -n "$cand" ] && { TR="$cand"; break; }
  done
fi
# Cannot measure. The two call sites want opposite things here, so they get opposite answers.
#
# Called BY HAND (a transcript passed as an argument): complain on stderr and exit non-zero. A person who typed a
# path wants to know it was wrong, and the suite asserts this — "never invent a fill" is checked by watching for
# a non-zero exit rather than by trusting the absence of output.
#
# Called AS A HOOK (payload on stdin, no argument): stay silent and exit 0. Nothing downstream reads the status —
# session-guard.sh parses the line and falls open without it — while a non-zero exit is a visible error in the
# user's session, once per turn, for a condition the discipline already handles (no 🔋 line, say so once, drop
# it). It also stops depending on the `|| true` in the hook command to hide it, which exec-form hooks cannot use.
if [ -z "$TR" ] || [ ! -f "$TR" ]; then
  [ -n "$IN" ] && exit 0                          # hook payload on stdin -> quiet
  echo "context-usage: transcript not found (pass an arg or use hook stdin)" >&2
  exit 1
fi

# Sum of usage for the last main-context turn: a non-sidechain ASSISTANT record that has a cache_read.
#
# Both engines require `"type":"assistant"`. When a subagent returns, its tool_result lands in the MAIN context
# (`isSidechain:false`) as a `type:"user"` record whose `toolUseResult.usage` is raw, unescaped JSON. jq is
# anchored at `.message.usage` and never saw it, but awk only sees text: it read the SUBAGENT's tokens as the
# session's. A 92.2%-full context reported 0.9% — "continue" — so the handoff gate stayed silent exactly when it
# was needed. Reachable by interrupting a subagent, which leaves that record last. The same predicate now guards
# both engines so they cannot drift; if a record ever lacks `.type` both go quiet, and a hook that says nothing
# is recoverable in a way that a hook confidently reporting 0.9% is not.
HAVE_JQ=0; command -v jq >/dev/null 2>&1 && HAVE_JQ=1
scan() {                                             # reads JSONL on stdin, prints the total (or nothing)
  if [ "$HAVE_JQ" = 1 ]; then
    jq -r 'select((.isSidechain // false) == false)
      | select(.type == "assistant")
      | select(.message.usage.cache_read_input_tokens != null)
      | (.message.usage.input_tokens
         + (.message.usage.cache_read_input_tokens // 0)
         + (.message.usage.cache_creation_input_tokens // 0))' 2>/dev/null | tail -1
  else
    # No jq: parse the JSONL line-by-line — same predicate, same number.
    awk '
      /"isSidechain": *true/  { next }
      !/"type": *"assistant"/ { next }
      /"cache_read_input_tokens"/ {
        i=0; r=0; c=0
        if (match($0, /"input_tokens": *[0-9]+/))                 { s=substr($0,RSTART,RLENGTH); gsub(/[^0-9]/,"",s); i=s }
        if (match($0, /"cache_read_input_tokens": *[0-9]+/))      { s=substr($0,RSTART,RLENGTH); gsub(/[^0-9]/,"",s); r=s }
        if (match($0, /"cache_creation_input_tokens": *[0-9]+/))  { s=substr($0,RSTART,RLENGTH); gsub(/[^0-9]/,"",s); c=s }
        total=i+r+c
      }
      END { if (total!="") print total }'
  fi
}

# Read the TAIL, not the file, and bound it by BYTES not lines. We want the LAST match; a tail hands back the
# bytes closest to EOF, so a match inside the window IS the last match, and too small a window can only come back
# empty, never stale. Bytes beat lines because one pasted payload can make a SINGLE JSONL record tens of MB: a
# line-based `tail -n 200` then drags that whole blob through the scanner (measured: 1.4s for a 60MB paste on a
# fast box; multiply by a slow Windows fork with no jq and it crosses the 10s hook timeout). A byte tail caps the
# work no matter how fat the lines are — the same 60MB case scans in ~12ms. A front-truncated partial first line
# simply fails to match, and since we keep the LAST match that is harmless. Widen once (256 KiB covers even a
# large subagent fan-out of small usage records), then a SIZE-GUARDED whole-file last resort.
TOTAL=""
for B in 262144 4194304; do                         # 256 KiB, then 4 MiB
  TOTAL="$(tail -c "$B" "$TR" | scan)"
  [ -n "$TOTAL" ] && break
done
if [ -z "$TOTAL" ]; then
  # The record is further from EOF than 4 MiB — almost always because the CURRENT turn pasted a huge payload that
  # now sits between EOF and the last assistant record. The whole file WOULD find it, but on a pathologically
  # large transcript that scan is exactly what blows the hook timeout. So bound it: scan the whole file only when
  # it is small enough to finish well inside the timeout (180MB ~= 4.7s under awk, so 200MB is safe under 30s);
  # past the cap, fail OPEN. A missing 🔋 line is recoverable — the model answers "could not measure" — whereas a
  # timed-out hook is just discarded noise.
  SZ="$(wc -c < "$TR" 2>/dev/null | tr -cd '0-9')"; SZ="${SZ:-0}"
  CAP="${CSK_CONTEXT_MAX_BYTES:-209715200}"         # 200 MiB; override per-repo
  [ "${SZ:-0}" -le "$CAP" ] && TOTAL="$(scan < "$TR")"
fi
# Same split as the missing-transcript case above: a hook stays quiet and exits 0, a by-hand call explains
# itself and exits non-zero. Exec-form hook commands carry no `|| true` to swallow a status, so anything that
# exits non-zero here becomes an error banner in the user's session once per turn.
if [ -z "${TOTAL:-}" ]; then
  [ -n "$IN" ] && exit 0
  echo "context-usage: usage not found in the byte-bounded window (transcript too large to scan within the hook timeout)" >&2
  exit 1
fi

# LC_ALL=C: force a '.' decimal separator regardless of locale (tr_TR etc. would emit '77,2' and could
# mis-parse the percentage). Generation AND every comparison below run under C so they stay consistent.
PCT="$(LC_ALL=C awk -v t="$TOTAL" -v w="$WINDOW" 'BEGIN{printf "%.1f", (t/w)*100}')"
LEVEL="$(LC_ALL=C awk -v p="$PCT" 'BEGIN{ if(p+0<50) print "continue"; else if(p+0<75) print "medium"; else print "handoff+clear" }')"
# The '%<number>' shape is a contract: session-guard.sh reads the percentage back out of this line.
if [ "$VERBOSE" = 1 ]; then
  echo "🔋 Session: %$PCT ($TOTAL/$WINDOW token) → $LEVEL"
else
  echo "🔋 Session %$PCT → $LEVEL"
fi
# >=75%: a short nudge for the model. The USER already gets the full, once-per-threshold warning from the
# Stop hook (session-guard.sh), so repeating the whole sentence here every turn would be pure duplication.
if LC_ALL=C awk -v p="$PCT" 'BEGIN{exit !(p+0>=75)}'; then
  echo "⚠️ >75% — hand off (handoff skill) then /clear; not automatic."
fi

# --- Stale-discipline gate ---------------------------------------------------------------------------
# CLAUDE.md and the discipline it imports are read ONCE, when the session starts. Update the kit while a
# session is running and every file on disk changes while the rules already in the model's context stay at
# the old version — it keeps quoting rules that no longer exist, and nothing says so. This does.
#
# Only meaningful on the UserPromptSubmit call: session-guard.sh pipes a Stop payload through this same
# script, and a by-hand run has no stdin at all. Fails open — no stdin, no session_id, no VERSION: silent.
case "$IN" in *'"hook_event_name"'*UserPromptSubmit*) ;; *) exit 0 ;; esac

# The session id is used twice below; computing it once is not a tidiness question. Measured on a corporate
# Windows machine: a process costs ~290ms there against ~2ms on Linux, so every spawn removed from a hook that
# runs on EVERY turn is a third of a second the user waits before the model has even started.
SID=""
case "$IN" in *'"session_id"'*)
  # Extracted with parameter expansion, not `printf | sed | head | tr`. Four spawns, on every turn, to lift a
  # UUID out of a string the shell already holds. It reads worse and costs ~1.2s a turn on a machine where a
  # process is 290ms. Handles both `"session_id":"x"` and `"session_id": "x"` — the cut is at the next quote
  # after the colon either way.
  SID="${IN#*\"session_id\"}"; SID="${SID#*:}"; SID="${SID#*\"}"; SID="${SID%%\"*}"
  # It becomes a filename, so it is VALIDATED rather than trusted. Anything unexpected falls back to the old
  # scrub — correctness first, and the fallback costs nothing in the normal case because it never runs.
  case "$SID" in
    ''|*[!A-Za-z0-9._-]*) SID="$(printf '%s' "$IN" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 | tr -cd 'A-Za-z0-9._-')" ;;
  esac ;;
esac

# --- Publish the measurement so the Stop hook does not have to repeat it ------------------------------
# session-guard.sh needs the same number, and it used to get it by running THIS script again as a nested
# `bash context-usage.sh --verbose` — a second shell startup plus a second full transcript scan, at the end of
# every single turn. On the machine above that pair costs seconds per turn, to recompute a figure that was
# already sitting in memory one hook earlier.
#
# The honest cost of sharing it: this reading is taken at the START of the turn, so the Stop hook sees a fill
# that does not include the turn's own output. It can therefore cross a threshold one turn later than a fresh
# measurement would. That is acceptable for an advisory warning and is NOT acceptable silently — session-guard
# falls back to measuring for itself whenever this file is missing, so the accurate path always exists.
if [ -n "$SID" ]; then
  printf '%s %s %s %s\n' "$PCT" "$TOTAL" "$WINDOW" "$LEVEL" > "${TMPDIR:-/tmp}/csk-context.${SID}" 2>/dev/null || true
fi

# --- Stale-WIRING gate -------------------------------------------------------------------------------
# A resumed session keeps the hook wiring it was started with. Measured on Windows: settings.json on disk had
# already been corrected, and `--resume` still produced the error naming the OLD, mangled path — while the same
# event under a fresh session was clean. So after a kit update, `--resume` carries the previous wiring, and on
# the release that fixed the Windows path that means the gates are still the broken ones.
#
# The obvious gate cannot work: a hook cannot report its own absence, and under the old wiring on Windows NO
# hook launched at all. What this catches is the other half — a session where the hooks DO run, but not the way
# the file on disk says they should. `$0` is the evidence: the kit wires `bash .claude/hooks/<name>.sh`, so a
# correctly-launched hook sees a relative `$0`. Anything else means this session was launched from a different
# settings.json than the one now on disk.
#
# Silent unless settings.json actually carries the kit's current shape — a project that rewired its hooks by
# hand is not wrong, and warning it every turn would be noise it cannot fix.
CSKSET="$HERE/../settings.json"
if [ -f "$CSKSET" ] && grep -q 'bash \.claude/hooks/context-usage\.sh' "$CSKSET" 2>/dev/null; then
  case "$0" in
    .claude/hooks/*) ;;                         # launched exactly as the file on disk wires it
    *) echo "⚠️ this session is running OLDER hook wiring than .claude/settings.json on disk (resumed across a kit update). The gates in force are the previous ones — ask the user to quit the CLI and start a NEW session; --resume will not pick up the change." ;;
  esac
fi

# --- Stale-discipline gate ---------------------------------------------------------------------------
KITVER="$HERE/../VERSION"                       # hooks live in .claude/hooks -> .claude/VERSION
[ -f "$KITVER" ] || exit 0
NOW="$(head -1 "$KITVER" 2>/dev/null | tr -cd '0-9A-Za-z.-')"
[ -n "$NOW" ] || exit 0
[ -n "$SID" ] || exit 0                         # computed once, above
MARK="${TMPDIR:-/tmp}/csk-kit-version.${SID}"
if [ ! -e "$MARK" ]; then
  printf '%s' "$NOW" > "$MARK" 2>/dev/null || true   # first turn: remember the version, say nothing
else
  WAS="$(head -1 "$MARK" 2>/dev/null)"
  # Repeated on every turn on purpose: the loaded context stays stale until the session is restarted.
  [ -n "$WAS" ] && [ "$WAS" != "$NOW" ] && \
    echo "⚠️ kit updated $WAS → $NOW mid-session. The discipline in your context is the OLD one — do not act on it; ask the user to run /compact (or /clear) to reload it from disk — no restart needed."
fi
exit 0
