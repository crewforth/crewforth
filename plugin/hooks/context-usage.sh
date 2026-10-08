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
# The script's own directory without `dirname`: an external a stripped PATH may lack, and a process on a hook that
# runs before every prompt. The JSON reader is found relative to it (../eval/lib).
case "$0" in */*) HERE="${0%/*}" ;; *) HERE=. ;; esac
HERE="$(cd "$HERE" && pwd)"
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
#
# `cat` on a pipe blocks until EOF, and "not a tty" does not mean "data is coming". Claude Code always writes
# the event JSON and closes, so this is invisible in normal use — but any wrapper that leaves stdin open and
# silent (a background shell, a CI runner, Crewforth's own suite launched as a job) hangs the hook forever, and
# it is a UserPromptSubmit hook: a hang here is a hang on every turn. Measured 2026-08-24: real JSON stdin 0s,
# closed stdin 0s, open-and-silent pipe still running after 20 minutes.
#
# So bound the wait. `read -t` on the first line costs nothing when the data is already there (the common case
# by far) and gives up otherwise; the rest is drained without a timeout because a producer that sent a first
# line is sending the whole object. Timeout is deliberately short — this runs before every prompt.
if [ -z "$TR" ] && [ ! -t 0 ]; then
  # `read` returns NON-ZERO when it hits EOF without a trailing newline — and it still assigns what it read.
  # Claude Code sends the event JSON with no trailing newline, so gating on the exit status alone throws the
  # whole payload away and every measurement reports "unmeasurable". Measured the wrong way once already: the
  # first version of this fix was timed, not checked for output, so it looked fine and was silently blind.
  _first=""
  IFS= read -r -t "${CREW_STDIN_TIMEOUT:-2}" _first 2>/dev/null || true
  if [ -n "$_first" ]; then
    IN="$_first
$(cat 2>/dev/null || true)"
  fi
  # Shortest-match parameter expansion, not `sed | head`: same FIRST-occurrence semantics, two processes
  # cheaper, on a hook that runs before every prompt.
  if [ -n "$IN" ]; then
    _r="${IN#*\"transcript_path\"}"
    if [ "$_r" != "$IN" ]; then _r="${_r#*\"}"; TR="${_r%%\"*}"; fi
  fi
fi
# --- Permission mode: say it once, while it still saves a turn -----------------------------------------
# §4.4 already states that the commit gate FAILS CLOSED in auto, dontAsk, plan and bypassPermissions, because
# in those modes software answers the prompt and nothing can prove a person did. What the session had no way to
# know was which mode it was IN. guard-bash.sh reads permission_mode, but only when it is already refusing --
# which is one turn too late. Measured in the field: the user said "commit", the guard refused, the mode was
# switched, and the command ran again. Everything behaved correctly and a turn was still spent on a fact that
# was available from the start.
#
# The published UserPromptSubmit schema carries `permission_mode`, with a JSON example showing it, so this is
# read rather than assumed; if it is ever absent the slice comes back empty and nothing is printed.
#
# ONCE PER SESSION, not once per turn. The model needs this fact, not a reminder of it, and a line repeated
# before every prompt in a mode people leave on all day is pure tax. Keyed by the mode itself, so switching
# modes mid-session announces the new one -- the same marker pattern the stale-discipline gate below uses.
# Modes where the gate does NOT fail closed say nothing at all: there the prompt reaches a person and there is
# no turn to save.
# Placed HERE, before the transcript work, because it must not depend on it. The first version sat further
# down and never ran on a session whose transcript could not be read -- the hook exits early for that, and a
# session with no usable transcript is exactly one that has no other way to learn its own mode. It derives its
# own session id for the same reason: everything below it is allowed to give up.
if [ -n "${IN:-}" ]; then
  PSID="${IN#*\"session_id\"}"
  [ "$PSID" = "$IN" ] && PSID="" || { PSID="${PSID#*:}"; PSID="${PSID#*\"}"; PSID="${PSID%%\"*}"; }
  case "$PSID" in ''|*[!A-Za-z0-9._-]*) PSID="" ;; esac
fi
if [ -n "${IN:-}" ] && [ -n "${PSID:-}" ]; then
  PM="${IN#*\"permission_mode\"}"
  if [ "$PM" != "$IN" ]; then
    PM="${PM#*:}"; PM="${PM#*\"}"; PM="${PM%%\"*}"
    case "$PM" in
      auto|dontAsk|plan|bypassPermissions)
        PMARK="${TMPDIR:-/tmp}/crew-permmode.${PSID}"
        WASM=""
        [ -f "$PMARK" ] && IFS= read -r WASM < "$PMARK" 2>/dev/null
        if [ "$WASM" != "$PM" ]; then
          printf '%s' "$PM" > "$PMARK" 2>/dev/null || true
          # In auto and dontAsk the user's own message is the approval (hooks/prompt-approval.sh); plan and
          # bypassPermissions have no such route.
          case "$PM" in
            auto|dontAsk) PMHOW="stage the change, show the message in ONE code block and under it one line in the user's language, 'If you approve, send only this: /crew-approve commit' (or /crew-approve push, /crew-approve commit+push; the command stays as it is in every language, and only the user can type it); the user approves by sending that command alone. It covers what is staged at that moment, for 30 minutes, until their next message; never write it for them" ;;
            *)            PMHOW="a real yes still comes first, then the user switches mode (or exports CLAUDE_GIT_OK=1 in headless/CI)" ;;
          esac
          echo "🔒 Permission mode: $PM. git commit/push fail closed in this mode (§4.4). Only when a commit or push comes up: say so before you ask for approval; $PMHOW. Otherwise do not mention it."
        fi
        ;;
    esac
  fi
fi


[ -n "$TR" ] && TR="$(unjson_path "$TR")"
# 2) still missing: derive the project dir from pwd.
# ---- CREW-TRANSCRIPT-DIR (kept byte-identical in context-usage.sh and session-stats.sh; smoke-test §6i3 pins it)
# Claude Code stores a session under $HOME/.claude/projects/<cwd encoded as a directory name>. Reproducing that
# encoding is the ONLY way a by-hand call (no hook payload on stdin) can find its own transcript.
crew_project_dirs(){   # candidate directory names for the current cwd, best first, one per line
  local w p
  # Windows first. Claude Code sees the NATIVE cwd (C:\repo\app) while Git Bash's `pwd` reports /c/repo/app, so
  # the drive letter never matched and the by-hand call could not resolve a transcript on Windows AT ALL — the
  # same "transcript not found" was reported from that machine three separate times before the cause was found.
  # `pwd -W` is the MSYS builtin that returns the native form; elsewhere it just fails and is discarded.
  w="$(pwd -W 2>/dev/null || true)"
  # The encoder folds : \ / . AND _ to '-'. The underscore is the one that hides: a project named `report_api`
  # lands in `...-report-api`, so folding only slashes and dots misses every path containing an underscore — on
  # every platform, not just Windows.
  for p in "$w" "$(pwd)"; do
    [ -n "$p" ] && printf '%s\n' "$(printf '%s' "$p" | sed 's#[:\\/._]#-#g')"
  done
  # Legacy shapes, kept so a directory written by an older client still resolves.
  printf '%s\n' "$(pwd | sed 's#[/.]#-#g')" "$(pwd | sed 's#/#-#g')"
}
if [ -z "$TR" ]; then
  while IFS= read -r esc; do
    [ -n "$esc" ] || continue
    cand="$(ls -t "$HOME/.claude/projects/$esc"/*.jsonl 2>/dev/null | head -1)"
    [ -n "$cand" ] && { TR="$cand"; break; }
  done <<CREWEOF
$(crew_project_dirs)
CREWEOF
fi
# ---- /CREW-TRANSCRIPT-DIR
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
# ONE ENGINE on every machine: Crewforth's awk JSON reader (eval/lib/settings-json.awk, op=usage). There used to be a
# jq branch in front of a regex-over-the-line awk scan; the regex matched key names ANYWHERE, so a tool input or
# result holding an object with "input_tokens" or "type":"assistant" could replace the record's own usage — found in
# review, 50% read as 0% or 90% on constructed transcripts (0 of 507 real ones differed). The reader parses each
# candidate record and applies the jq predicate exactly, and it skips the byte window's cut first line.
# `scan` prints the total of the LAST matching record; callers take the last line with `${x##*NL}`, which is
# shell, where `| tail -1` was a process on a hook that runs before every prompt.
last_line() { printf '%s' "${1##*$'\n'}"; }
scan() {   # reads a JSONL tail on stdin, prints the total of the last qualifying record
  # Crewforth's JSON reader, which the plugin also ships at ../eval/lib. Without it there is nothing to read with:
  # print nothing, and the caller reports "usage not found" rather than a number it did not measure.
  [ -f "$HERE/../eval/lib/settings-json.awk" ] || { cat >/dev/null; return 0; }
  awk -v op=usage -f "$HERE/../eval/lib/settings-json.awk" -
}

# Read the TAIL, not the file, and bound it by BYTES not lines. We want the LAST match; a tail hands back the
# bytes closest to EOF, so a match inside the window IS the last match, and too small a window can only come back
# empty, never stale. Bytes beat lines because one pasted payload can make a SINGLE JSONL record tens of MB: a
# line-based `tail -n 200` then drags that whole blob through the scanner (measured: 1.4s for a 60MB paste on a
# fast box; multiply by a slow Windows fork with no jq and it crosses the 10s hook timeout). A byte tail caps the
# work no matter how fat the lines are — the same 60MB case scans in ~12ms. A front-truncated partial first line
# simply fails to match, and since we keep the LAST match that is harmless. Widen once (256 KiB covers even a
# large subagent fan-out of small usage records), then a SIZE-GUARDED whole-file last resort.
#
# The partial first line has to go before the scan, and that is not a tidiness point — it is why the
# window never worked. The comment above reasons that a front-truncated line "simply fails to match",
# which is true of awk and FALSE of jq: measured, jq ABORTS the whole stream on a malformed first
# record and prints nothing, while awk skips the line and carries on. So on every machine that has jq
# — which is most of them, and every developer laptop — both windows returned empty and the hook fell
# through to scanning the ENTIRE transcript, every single turn. On a 45 MB session that is 45 MB read
# per prompt, and the byte bound that this block exists to enforce was never once in force.
#
# Dropped with `tail -n +2`, NOT with `${W#*$'\n'}`. The parameter expansion looks free and is a trap:
# on a window with no newline in it — a malformed transcript that is one enormous line, which the
# suite fixtures on purpose — bash walks every prefix looking for a match it will never find. Measured
# on a 4 MiB single-line file: it had not finished after 20 seconds, and it hung the gate for 36
# minutes before that was noticed. One streaming process is the cheap option here, not the expensive
# one. Only correct to drop when the tail actually truncated, hence the size test.
# The size is asked ONCE, up front, and it pays for itself: it is the only exact way to know whether
# a tail truncated, and knowing that is what lets the window work at all. Comparing the captured
# length against the window does NOT work — `$( )` strips the trailing newline, so the capture is
# never quite the window size and the drop never fires.
SZ="$(wc -c < "$TR" 2>/dev/null)"; SZ="${SZ//[!0-9]/}"; SZ="${SZ:-0}"
TOTAL=""
for B in 262144 4194304; do                         # 256 KiB, then 4 MiB
  if [ "$SZ" -gt "$B" ]; then
    TOTAL="$(tail -c "$B" "$TR" | tail -n +2 | scan)"   # the tail cut a line in half; drop it
  else
    TOTAL="$(tail -c "$B" "$TR" | scan)"                # whole file: the first line is intact
  fi
  TOTAL="$(last_line "$TOTAL")"
  [ -n "$TOTAL" ] && break
done
if [ -z "$TOTAL" ]; then
  # The record is further from EOF than 4 MiB — almost always because the CURRENT turn pasted a huge payload that
  # now sits between EOF and the last assistant record. The whole file WOULD find it, but on a pathologically
  # large transcript that scan is exactly what blows the hook timeout. So bound it: scan the whole file only when
  # it is small enough to finish well inside the timeout (180MB ~= 4.7s under awk, so 200MB is safe under 30s);
  # past the cap, fail OPEN. A missing 🔋 line is recoverable — the model answers "could not measure" — whereas a
  # timed-out hook is just discarded noise.
  CAP="${CREW_CONTEXT_MAX_BYTES:-209715200}"         # 200 MiB; override per-repo
  [ "${SZ:-0}" -le "$CAP" ] && TOTAL="$(last_line "$(scan < "$TR")")"
fi
# Same split as the missing-transcript case above: a hook stays quiet and exits 0, a by-hand call explains
# itself and exits non-zero. Exec-form hook commands carry no `|| true` to swallow a status, so anything that
# exits non-zero here becomes an error banner in the user's session once per turn.
if [ -z "${TOTAL:-}" ]; then
  [ -n "$IN" ] && exit 0
  # Name the missing reader rather than blaming the transcript's size: without it nothing was read at all.
  if [ ! -f "$HERE/../eval/lib/settings-json.awk" ]; then
    echo "context-usage: Crewforth's JSON reader is missing ($HERE/../eval/lib/settings-json.awk) — update Crewforth" >&2
    exit 1
  fi
  echo "context-usage: usage not found in the byte-bounded window (transcript too large to scan within the hook timeout)" >&2
  exit 1
fi

# LC_ALL=C: force a '.' decimal separator regardless of locale (tr_TR etc. would emit '77,2' and could
# mis-parse the percentage). Generation AND every comparison below run under C so they stay consistent.
# Integer arithmetic, not awk, and it ROUNDS rather than truncates — which is the whole reason awk was
# here. `(t*1000 + w/2) / w` is round-half-up on tenths; verified against awk's %.1f across the range
# before the swap, not after. That removes the single most expensive process this hook starts on Git
# Bash (measured there: 57 ms idle, 404 ms under load, against 62 ms for a bare `true`).
PCT_T=$(( (TOTAL * 1000 + WINDOW / 2) / WINDOW ))
PCT="$((PCT_T / 10)).$((PCT_T % 10))"
# The COMPARISONS take the integer part: the thresholds are whole numbers, so nothing below needs the tenth,
# exactly as session-guard.sh already argues for its own two. This paragraph used to end "the DISPLAYED
# percentage stays awk's, because %.1f rounds and shell arithmetic truncates" — a true statement about the
# obvious integer division, and the reason awk survived here for so long. It stopped being true one commit
# ago: the expression above rounds. A comment that describes a tool the code no longer calls is worse than
# no comment, because the next reader trusts it instead of the line.
PCTI="${PCT%%.*}"; case "$PCTI" in ''|*[!0-9]*) PCTI=0 ;; esac
if   [ "$PCTI" -lt 50 ]; then LEVEL="continue"
elif [ "$PCTI" -lt 75 ]; then LEVEL="medium"
else                          LEVEL="handoff+clear"
fi
# The '%<number>' shape is a contract: session-guard.sh reads the percentage back out of this line.
if [ "$VERBOSE" = 1 ]; then
  echo "🔋 Session: %$PCT ($TOTAL/$WINDOW token) → $LEVEL"
else
  echo "🔋 Session %$PCT → $LEVEL"
fi
# >=75%: a short nudge for the model. The USER already gets the full, once-per-threshold warning from the
# Stop hook (session-guard.sh), so repeating the whole sentence here every turn would be pure duplication.
if [ "$PCTI" -ge 75 ]; then
  echo "⚠️ >75% — hand off (handoff skill) then /clear; not automatic."
fi

# --- Stale-discipline gate ---------------------------------------------------------------------------
# CLAUDE.md and the discipline it imports are read ONCE, when the session starts. Update Crewforth while a
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
  printf '%s %s %s %s\n' "$PCT" "$TOTAL" "$WINDOW" "$LEVEL" > "${TMPDIR:-/tmp}/crew-context.${SID}" 2>/dev/null || true
fi

# --- Stale-WIRING gate -------------------------------------------------------------------------------
# A resumed session keeps the hook wiring it was started with. Measured on Windows: settings.json on disk had
# already been corrected, and `--resume` still produced the error naming the OLD, mangled path — while the same
# event under a fresh session was clean. So after a kit update, `--resume` carries the previous wiring, and on
# the release that fixed the Windows path that means the gates are still the broken ones.
#
# The obvious gate cannot work: a hook cannot report its own absence, and under the old wiring on Windows NO
# hook launched at all. What this catches is the other half — a session where the hooks DO run, but not the way
# the file on disk says they should. `$0` is the evidence: Crewforth wires `bash .claude/hooks/<name>.sh`, so a
# correctly-launched hook sees a relative `$0`. Anything else means this session was launched from a different
# settings.json than the one now on disk.
#
# Silent unless settings.json actually carries Crewforth's current shape — a project that rewired its hooks by
# hand is not wrong, and warning it every turn would be noise it cannot fix.
CREWSET="$HERE/../settings.json"
if [ -f "$CREWSET" ] && grep -q 'bash \.claude/hooks/context-usage\.sh' "$CREWSET" 2>/dev/null; then
  case "$0" in
    .claude/hooks/*) ;;                         # launched exactly as the file on disk wires it
    *) echo "⚠️ this session is running OLDER hook wiring than .claude/settings.json on disk (resumed across a Crewforth update). The gates in force are the previous ones — ask the user to quit the CLI and start a NEW session; --resume will not pick up the change." ;;
  esac
fi

# --- Stale-discipline gate ---------------------------------------------------------------------------
KITVER="$HERE/../VERSION"                       # hooks live in .claude/hooks -> .claude/VERSION
[ -f "$KITVER" ] || exit 0
NOW="$(head -1 "$KITVER" 2>/dev/null | tr -cd '0-9A-Za-z.-')"
[ -n "$NOW" ] || exit 0
[ -n "$SID" ] || exit 0                         # computed once, above
MARK="${TMPDIR:-/tmp}/crew-kit-version.${SID}"
if [ ! -e "$MARK" ]; then
  printf '%s' "$NOW" > "$MARK" 2>/dev/null || true   # first turn: remember the version, say nothing
else
  WAS="$(head -1 "$MARK" 2>/dev/null)"
  # Repeated on every turn on purpose: the loaded context stays stale until a new session starts (/clear or a
  # relaunch). /compact re-reads CLAUDE.md but keeps the session id, so this warning would not stop after it.
  [ -n "$WAS" ] && [ "$WAS" != "$NOW" ] && \
    echo "⚠️ Crewforth updated $WAS → $NOW mid-session. The discipline in your context is the OLD one — do not act on it; ask the user to run /clear (or quit and relaunch Claude Code): a new session loads the new one."
fi
exit 0
