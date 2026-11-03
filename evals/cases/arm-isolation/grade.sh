#!/usr/bin/env bash
# The kit arm (it has .claude/agents/) must name a crew- component (else the listing cannot be trusted to show one); the bare
# arm has none and must name nothing of Crewforth. A reply that lists almost nothing is not a reading.
set -uo pipefail
say() { printf '%s %s\n' "$1" "$2"; }
F=".eval-stdout.txt"
[ -s "$F" ] || { say NOT_MEASURED "no reply text to read"; exit 0; }
n="$(grep -c '[[:alnum:]]' "$F" | tr -d ' ')"
[ "${n:-0}" -ge 3 ] || { say NOT_MEASURED "the reply lists $n line(s): too few to show what the session could see"; exit 0; }
hits="$(grep -oiE '(^|[^[:alnum:]-])crew-[a-z-]+|crewforth' "$F" | sed 's/^[^[:alnum:]]//' | sort -u | head -5 | tr '\n' ' ')"
if [ -d .claude/agents ]; then   # what the install writes; a CLI run never creates it
  [ -n "$hits" ] && say PASS "the kit arm sees Crewforth (${hits% })" || say FAIL "the kit arm lists no Crewforth component: the listing does not show what is installed"
else
  [ -z "$hits" ] && say PASS "the control arm sees no Crewforth component ($n lines listed)" || say FAIL "the control arm can see Crewforth: ${hits% }"
fi
