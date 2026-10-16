#!/usr/bin/env bash
# What did the gates actually DO? — reads CREW_GATE_LOG and reports it against the rule inventory.
#
# Crewforth's claim is that rules are enforced at the tool level rather than remembered. That claim is only worth
# what its evidence is worth, and until now the evidence was a green test suite: proof the gates CAN fire, never
# a record that they DID. This reads the other half.
#
# Two failure modes it is built around, both learned here the hard way:
#   1. "0 firings" and "never measured" leave identical artifacts. So a rule is reported as `not observed`, never
#      as dead, and a missing log is reported as NOT MEASURED — never as zero.
#   2. A hand-maintained rule list drifts from the rules. So the inventory is DERIVED from the installed hooks
#      on every run: a rule added to guard-bash.sh shows up here without anyone remembering to add it.
#
# Usage:  gate-report.sh [--log <path>] [--json]
# Exit:   0 report produced · 3 no log to read (not an error: logging is opt-in) · 4 hooks not found
set -u
# The 2.x names of the variables a user can set still work (one helper: eval/lib/crew-env.sh).
_crew_d="${BASH_SOURCE%/*}"; [ "$_crew_d" = "${BASH_SOURCE}" ] && _crew_d=.
[ -f "$_crew_d/lib/crew-env.sh" ] && . "$_crew_d/lib/crew-env.sh"; unset _crew_d

LOG="${CREW_GATE_LOG:-}"; JSON=0
while [ $# -gt 0 ]; do case "$1" in
  --log) LOG="${2:-}"; shift 2 ;;
  --json) JSON=1; shift ;;
  *) echo "gate-report.sh: unknown argument '$1'" >&2; exit 64 ;;
esac; done

HOOKS="./.claude/hooks"; [ -d "$HOOKS" ] || HOOKS="./hooks"
[ -f "$HOOKS/guard-bash.sh" ] || { echo "gate-report: guard-bash.sh not found (run from the project root)" >&2; exit 4; }

# Default log location, so `--log` is not required once logging is on.
# The same rule the gates write by (eval/lib/gate-log.sh): .claude/gate-log.tsv, or the repository's .git.
if [ -z "$LOG" ] && [ -f ./.claude/eval/lib/gate-log.sh ]; then . ./.claude/eval/lib/gate-log.sh; crew_gate_log_read; LOG="$_CREW_GL"; fi
[ -z "$LOG" ] && [ -f "./.claude/gate-log.tsv" ] && LOG="./.claude/gate-log.tsv"

TMP="${TMPDIR:-/tmp}/crew-gate-$$"; mkdir -p "$TMP"; trap 'rm -rf "$TMP"' EXIT

# Match on a KEY, display the full label. A rule label can carry a trailing parenthetical, and one of them
# interpolates a shell variable ("… that cannot prompt (${PERM_MODE:-unknown})"): the inventory reads the
# source, the log holds the expanded value, so the two never compare equal and the rule is reported as never
# observed forever — a false negative in the one direction that matters. Both sides drop the trailing (...).
key(){ printf '%s' "$1" | sed 's/[[:space:]]*([^()]*)[[:space:]]*$//'; }

# ---- inventory: derived from the hooks, one awk pass per file (no per-rule subprocess: Windows forks cost 62-135 ms)
awk '
  # 23 rules of the form:  … && block "RULE" "SECTION"
  match($0, /&& *block +"[^"]*" +"[^"]*"/) {
    s=substr($0,RSTART,RLENGTH); n=split(s,q,"\"");  print q[4] "\t" q[2]; next
  }
  # direct calls:  gatelog VERDICT SECTION "RULE"
  /^[[:space:]]*gatelog +[A-Z]+ +[0-9.]+ +"/ {
    n=split($0,q,"\""); split($0,f," "); print f[3] "\t" q[2]; next
  }
' "$HOOKS/guard-bash.sh" > "$TMP/inv"
# guard-write.sh emits its one line inline rather than through a helper, so read the label out of the printf
# arguments the same way — the earlier version skipped the very line it needed (it matched CREW_GATE_LOG first)
# and the rule silently never appeared in the inventory, which reads exactly like a rule that never fires.
# guard-write.sh emits its one line inline rather than through a helper, so read the label out of the printf
# arguments. Two traps here, both hit on the way: the line also mentions CREW_GATE_LOG (skipping on that name
# skipped the rule itself), and the FIRST quoted field on the line is `${CREW_GATE_LOG:-}`, not the label — so
# take the last quoted field that is not a variable reference.
[ -f "$HOOKS/guard-write.sh" ] && awk '
  /printf .BLOCK\\t/ {
    n=split($0,q,"\""); lab=""
    for (i=2; i<=n; i+=2) if (q[i] !~ /^\$/ && q[i] != "") lab=q[i]
    if (lab != "") print "4.5\t" lab
  }' "$HOOKS/guard-write.sh" >> "$TMP/inv"

sort -u "$TMP/inv" -o "$TMP/inv"
NRULES=$(grep -c . "$TMP/inv" 2>/dev/null); NRULES=$(( ${NRULES:-0} + 0 ))

# ---- no log. Since 2.5.0 recording is ON by default, so the absence of a file means one of two DIFFERENT
# things and the report must not blur them:
#   .claude/ exists  -> recording had somewhere to go and nothing has tripped a gate yet. That is a real
#                       measurement of zero, and it is the healthy reading.
#   .claude/ missing -> there was nowhere to write. Nothing was measured; zero would be a lie.
if [ -z "$LOG" ] || [ ! -f "$LOG" ]; then
  if [ -d "./.claude" ]; then
    if [ "$JSON" = 1 ]; then printf '{"measured":true,"rules":%s,"decisions":0}\n' "$NRULES"; else
      echo "== gate report =="
      echo "  ✅ no gate has fired in this project yet — $NRULES rules wired, recording on,"
      echo "     nothing has tripped one. (Recording writes .claude/gate-log.tsv, which is gitignored;"
      echo "     rule names and verdicts only, never the command — CREW_GATE_LOG_CMD=1 adds it for debugging.)"
    fi
    exit 0
  fi
  if [ "$JSON" = 1 ]; then printf '{"measured":false,"rules":%s,"reason":"nowhere to record"}\n' "$NRULES"; else
    echo "== gate report =="
    echo "  ·  NOT MEASURED — no .claude/ to record into. $NRULES rules are wired; how often they fire is unknown."
    echo "     ↳ point it somewhere:  export CREW_GATE_LOG=\"\$PWD/gate-log.tsv\""
  fi
  exit 3
fi

# ---- read the log: VERDICT \t §SECTION \t RULE \t COMMAND
awk -F'\t' 'NF>=3 { k=$3; sub(/[[:space:]]*\([^()]*\)[[:space:]]*$/,"",k); c[k]++; lab[k]=$3; v[$1]++; tot++ } END {
  print "TOTAL\t" tot+0
  for (k in v) print "VERDICT\t" k "\t" v[k]
  for (k in c) print "RULE\t" k "\t" c[k] "\t" lab[k]
}' "$LOG" > "$TMP/agg"

TOT=$(awk -F'\t' '$1=="TOTAL"{print $2}' "$TMP/agg"); TOT="${TOT:-0}"
FIRST=$(head -1 "$LOG" 2>/dev/null | cut -f3); LINES=$(grep -c . "$LOG" 2>/dev/null); LINES=$(( ${LINES:-0} + 0 ))

if [ "$JSON" = 1 ]; then
  awk -F'\t' -v n="$NRULES" -v t="$TOT" '
    $1=="RULE" { r=r sep "{\"rule\":\"" $4 "\",\"count\":" $3 "}"; sep="," }
    END { printf "{\"measured\":true,\"rules\":%s,\"decisions\":%s,\"fired\":[%s]}\n", n, t, r }' "$TMP/agg"
  exit 0
fi

echo "== gate report =="
echo "  log: $LOG  ($LINES line(s), $TOT decision(s))"
echo
echo "  verdicts:"
awk -F'\t' '$1=="VERDICT"{printf "    %-6s %s\n",$2,$3}' "$TMP/agg" | sort
echo
echo "  rules that fired:"
awk -F'\t' '$1=="RULE"{printf "    %5s  %s\n",$3,$4}' "$TMP/agg" | sort -rn || true
[ "$TOT" = 0 ] && echo "    (none)"
echo
# One awk over both files instead of sort|comm|join: that chain compared a two-field inventory line against a
# one-field fired list, so a rule could land in BOTH lists at once (it did — `chmod world-writable` showed as
# fired and as unseen in the same report). It also spawned four processes per run, which is real cost on
# Windows. Here the fired set and the inventory meet in one pass, keyed the same way.
UNSEEN="$(awk -F'\t' '
  FILENAME==f1 && $1=="RULE" { fired[$2]=1; next }
  FILENAME==f2 {
    lbl=$2; k=lbl; sub(/[[:space:]]*\([^()]*\)[[:space:]]*$/,"",k)
    if (!(k in fired) && !(k in seen)) { seen[k]=1; printf "    \302\267 %s\n", lbl }
  }' f1="$TMP/agg" f2="$TMP/inv" "$TMP/agg" "$TMP/inv")"
NUNSEEN=$(printf '%s' "$UNSEEN" | grep -c . 2>/dev/null || true); NUNSEEN="${NUNSEEN:-0}"
echo "  wired but not observed in this log ($NUNSEEN of $NRULES):"
[ -n "$UNSEEN" ] && printf '%s\n' "$UNSEEN"

echo
echo "  Not observed is NOT dead. It means one of: nobody attempted it, the model never reached for that"
echo "  command, or the rule cannot match. Only the first two are healthy, and this report cannot tell them"
echo "  apart — smoke-test is what proves a rule CAN fire; this shows whether anything tripped it."
