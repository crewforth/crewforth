#!/usr/bin/env bash
# Stop hook — when session fill crosses a threshold it GUARANTEES the handoff recommendation reaches the USER.
# Session management = a gate at the threshold, not a wish. But the gate must not nag or burn tokens:
#   - It surfaces the recommendation as a neutral `systemMessage` (user-facing warning), NOT a hook error.
#     (Claude Code renders a BLOCKING Stop hook — exit 2 — as "Stop hook error: ...". We deliberately never block.)
#   - It fires ONCE PER THRESHOLD per session: once at 75% (warn), once more at 90% (critical). Never every turn,
#     so it never forces an extra assistant continuation — which would burn tokens and fill the context faster,
#     i.e. the gate would cause the very thing it exists to prevent.
#   - It NEVER blocks the stop: every path exits 0. A measurement failure fails open, silently.
# context-usage.sh does the measurement. No automatic /clear — approval is the user's (§4.4).
# The model is nudged separately every turn by context-usage.sh (UserPromptSubmit); this hook is the
# guaranteed USER-facing alert. A new session (or /clear) mints a new session_id and re-arms both thresholds.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
IN="$(cat 2>/dev/null || true)"

# Loop guard: if this Stop is already a Stop-hook continuation, do nothing (defensive; we never block anyway).
case "$IN" in
  *'"stop_hook_active":true'*|*'"stop_hook_active": true'*) exit 0 ;;
esac

# Per-session dedup key: session_id from the Stop stdin JSON (documented field), else the transcript
# filename. Sanitized to a safe filename fragment. Without any key we fall back to a shared marker
# (that degenerate case coincides with a measurement failure, which exits silently below anyway).
#
# Pure parameter expansion, not `sed | head | tr`. This hook runs on EVERY Stop — once per turn — and on Git
# Bash a process costs 60-135 ms (measured on a Windows 11 desktop: this hook was 22 processes and 1,805 ms
# per turn end, of which these three lines were 8). Extraction is shortest-match `#*`, so it takes the FIRST
# occurrence of the key exactly as the sed did; the `[!…]` class strips to the same safe filename fragment
# `tr -cd` produced, and that form works on the bash 3.2 macOS ships.
_slice(){ # $1 = payload, $2 = key -> the value up to the next unescaped-quote-free boundary, "" if absent
  local r="${1#*\"$2\"}"
  [ "$r" != "$1" ] || return 0
  r="${r#*\"}"                      # past `: "` to the value's opening quote
  printf '%s' "${r%%\"*}"
}
TP="$(_slice "$IN" transcript_path)"
# The path arrives JSON-encoded, so on Windows it carries doubled backslashes. Git Bash happens to accept
# `C:\\Users\\…` (Windows collapses repeated separators), which is why this was never noticed here — but
# context-usage.sh already normalises for the same field and does not rely on that, and a check that depends
# on one shell's tolerance is a check that stops running when someone uses another. Free: no process.
TP="${TP//\\\\//}"; TP="${TP//\\//}"
KEY="$(_slice "$IN" session_id)"; KEY="${KEY//[!A-Za-z0-9._-]/}"
if [ -z "$KEY" ]; then KEY="${TP##*[/\\]}"; KEY="${KEY//[!A-Za-z0-9._-]/}"; fi
[ -n "$KEY" ] || KEY="unknown"

# Compaction generation. A `/compact` does NOT mint a new session_id — only a new session or `/clear` does —
# so the per-tier markers below survive it, and that silently disarms this gate exactly where it matters most:
# a session warned at 90% compacts down to ~5%, climbs all the way back, and the user is never told a second
# time. Keying the markers by compaction COUNT gives every generation its own pair of thresholds.
# The boundary record is `"subtype":"compact_boundary"` with `compactMetadata.trigger` (verified against real
# transcripts). grep, not awk: this runs inside a hook timeout on every Stop, and the same size guard
# context-usage.sh uses applies — past the cap we skip the count and fall back to the old single-generation
# behaviour rather than risk the timeout.
COMP=0; AUTOC=0
if [ -n "$TP" ] && [ -f "$TP" ]; then
  # `$(( ))` instead of `| tr -cd '0-9'`: arithmetic already ignores the surrounding whitespace wc and grep
  # emit, and it costs no process where tr costs one each — three of them, on every turn.
  #
  # NO `|| echo 0` on the greps. `grep -c` with zero matches PRINTS "0" AND EXITS 1, so the fallback
  # fired too and the value became two lines — `0\n0` — which `$(( ))` cannot parse. Measured on a real
  # session: "session-guard.sh: line 61: 0\n0 + 0 : arithmetic syntax error". Every transcript that has
  # not been compacted takes that path, which is every fresh session, so the 75/90 warning this hook
  # exists to emit was failing before it could speak. `wc -c` keeps its fallback: it prints nothing when
  # the file cannot be read, so there the `||` supplies a value rather than appending a second one.
  SZ="$(wc -c < "$TP" 2>/dev/null || echo 0)"; SZ=$(( ${SZ:-0} + 0 ))
  if [ "$SZ" -le "${CREW_CONTEXT_MAX_BYTES:-209715200}" ]; then
    COMP="$(grep -c '"subtype": *"compact_boundary"' "$TP" 2>/dev/null)";  COMP=$(( ${COMP:-0} + 0 ))
    AUTOC="$(grep -c '"compact_boundary".*"trigger": *"auto"' "$TP" 2>/dev/null)"; AUTOC=$(( ${AUTOC:-0} + 0 ))
  fi
fi
marker(){ printf '%s/crew-session-guard.%s.c%s.%s' "${TMPDIR:-/tmp}" "$KEY" "$COMP" "$1"; }

# An AUTO compaction is not a milestone, it is a loss: state nobody chose to drop is already gone, and the fill
# reading right after it is reassuringly low precisely because the context was thrown away. Announce it once per
# generation, independently of the fill tier — waiting for 75% would report the loss long after it happened.
if [ "${AUTOC:-0}" -gt 0 ] && [ ! -e "$(marker autocompact)" ]; then
  : > "$(marker autocompact)" 2>/dev/null || true
  printf '{"systemMessage":"⚠️ Auto-compaction has fired %s time(s) this session — context was dropped that nobody chose to drop. Check that docs/SESSION_STATE.md still matches reality, and hand off at the next phase boundary instead of riding the fill up to another one."}\n' "$AUTOC"
  exit 0
fi

# Real context%, from context-usage.sh's measurement. Fail-open on any error.
#
# FAST PATH — read the figure context-usage.sh already published this turn. That hook runs on UserPromptSubmit,
# measures exactly this, and now writes it to a session-keyed file. Re-deriving it here meant a second shell
# startup plus a second full transcript scan at the end of EVERY turn: measured at ~31 processes per Stop, and
# on a corporate Windows machine a process costs ~290ms, so the turn ended with seconds of silence.
#
# Read with `$(<file)` — a builtin, no `cat`. Parsed by word splitting, no `sed`. What it costs: the reading is
# from the start of the turn, so it excludes this turn's own output and can cross a threshold one turn late.
# For a warning that never blocks, one turn of lag is worth seconds a turn, and it is not silent: without the
# file we measure properly below, so the accurate path is always there when the fast one is not.
PCT=""; TOTAL=""; WINDOW=""; LEVEL=""; LINE=""
CACHE="${TMPDIR:-/tmp}/crew-context.${KEY}"
if [ -f "$CACHE" ]; then
  read -r PCT TOTAL WINDOW LEVEL < "$CACHE" 2>/dev/null || true
  case "$PCT" in ''|*[!0-9.]*) PCT="" ;; esac      # anything unexpected -> fall through and measure
  [ -n "$PCT" ] && LINE="🔋 Session: %$PCT ($TOTAL/$WINDOW token) → $LEVEL"
fi

if [ -z "$PCT" ]; then
  # SLOW PATH — no published reading (first turn, a by-hand run, or context-usage silent). Measure for real.
  # --verbose here: this line reaches the USER at most twice per session, so the raw token counts are free.
  LINE="$(printf '%s' "$IN" | bash "$HERE/context-usage.sh" --verbose 2>/dev/null || true)"
  LINE="${LINE%%$'\n'*}"                     # first line, without paying `head` a process for it
  [ -n "$LINE" ] || exit 0
  # Pull the percentage back out of the "🔋 Session: %77.2 (...)" line. context-usage.sh pins LC_ALL=C, so the
  # decimal separator is always '.' whatever the locale. No number -> cannot classify -> stay silent (fail open).
  # Pure expansion rather than `sed | head`: take everything after the first '%', then stop at the first
  # character that is not a digit or a dot. Same first-match semantics as the sed, two processes cheaper, and
  # this runs at the end of every turn.
  PCT="${LINE#*%}"
  [ "$PCT" != "$LINE" ] || PCT=""
  PCT="${PCT%%[!0-9.]*}"
  case "$PCT" in ''|*[!0-9.]*|.*) PCT="" ;; esac
  [ -n "$PCT" ] || exit 0
fi

# The reply's own 🔋 line, held against the reading. The discipline says that figure is copied from the hook's
# line and never guessed, and nothing checked it: a session whose hook line had stopped arriving went on to print
# 45, 51 … 86 while its transcript measured 30.3, and the user handed the session off on that number. A figure
# more than CREW_FILL_TOLERANCE points (default 5) from the measurement is reported to the user, every turn it
# happens. The tolerance covers the one honest gap: a slow-path reading is taken at the END of the turn, so it
# includes output the model had not produced when it copied the start-of-turn line. No 🔋 line, or none with a
# number after its '%' (a quoted template, `%NN`), says nothing. Pure expansion: no process.
WRONG=""
_said="${IN##*🔋}"
if [ "$_said" != "$IN" ]; then
  _said="${_said%%\\n*}"                           # that line only: the payload escapes a newline as \n
  _num="${_said#*%}"
  if [ "$_num" != "$_said" ]; then
    _num="${_num%%[!0-9.,]*}"; _num="${_num/,/.}"  # a Turkish reply writes %30,3
    _si="${_num%%.*}"; _sf="${_num#"$_si"}"; _sf="${_sf#.}"; _sf="${_sf:0:1}"
    _mi="${PCT%%.*}"; _mf="${PCT#"$_mi"}"; _mf="${_mf#.}"; _mf="${_mf:0:1}"
    case "$_si$_sf$_mi$_mf" in ''|*[!0-9]*) ;; *)
      [ -n "$_si" ] && [ -n "$_mi" ] && {
        _d=$(( (10#$_si * 10 + 10#${_sf:-0}) - (10#$_mi * 10 + 10#${_mf:-0}) )); [ "$_d" -lt 0 ] && _d=$(( -_d ))
        [ "$_d" -gt $(( ${CREW_FILL_TOLERANCE:-5} * 10 )) ] && WRONG="%$_num"
      } ;;
    esac
  fi
fi

# Highest threshold crossed. Compared under LC_ALL=C so '77.2' parses identically everywhere.
# Compared on the integer part with shell arithmetic rather than two `awk` calls. Two spawns at the end of every
# turn bought nothing here: the thresholds are whole numbers, so truncating is exactly equivalent — 89.9 is below
# 90 either way — and dropping the decimal also drops the locale hazard the awk calls existed to pin down.
INT="${PCT%%.*}"; INT="${INT:-0}"
case "$INT" in ''|*[!0-9]*) exit 0 ;; esac
TIER=""
[ "$INT" -ge 90 ] && TIER=90
[ -n "$TIER" ] || { [ "$INT" -ge 75 ] && TIER=75; }
MSG=""
# Already warned at this tier this session? Stay silent — one alert per threshold, not one per turn.
if [ -n "$TIER" ] && [ ! -e "$(marker "$TIER")" ]; then
  # Stamp this tier AND every lower one: jumping 60 -> 92 in a single turn must not let the 75 warning fire
  # later (e.g. once /compact drops the fill back under 90).
  for t in 75 90; do
    [ "$t" -le "$TIER" ] && { : > "$(marker "$t")" 2>/dev/null || true; }
  done
  if [ "$TIER" = 90 ]; then
    MSG="CRITICAL >90% — hand off NOW: apply the handoff skill, write docs/SESSION_STATE.md, then /clear. Auto-compaction is close and it will cost you the handover."
  else
    MSG=">75% threshold. Recommended: apply the handoff skill, write docs/SESSION_STATE.md, then /clear. Manual; your call."
  fi
fi
[ -n "$MSG$WRONG" ] || exit 0

# JSON-escape backslash + double-quote in the measured line before embedding it.
SAFE="$(printf '%s' "$LINE" | sed 's/\\/\\\\/g; s/"/\\"/g')"
OUT="${MSG:+$SAFE | $MSG}"
[ -n "$WRONG" ] && OUT="⚠️ The 🔋 line in this reply says $WRONG, but the fill measured from the transcript is: $SAFE. The reply's figure is not a measurement — do not decide a handoff on it.${OUT:+ · $OUT}"
# exit 0 + systemMessage: a neutral, user-facing warning (NOT a hook error, does NOT force an extra turn).
printf '{"systemMessage":"%s"}\n' "$OUT"
exit 0
