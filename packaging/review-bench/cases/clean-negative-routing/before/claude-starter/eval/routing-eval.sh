#!/usr/bin/env bash
# Behavioral eval: does a golden prompt route to the expected target via a trigger (deterministic)?
# Does NOT run Claude Code; it statically proxies the routing correctness of the trigger design:
#   1) Golden routing  — each example prompt must contain (as a substring) one trigger of its expected target.
#   2) Agent collision  — two DIFFERENT agents must not share the same trigger phrase (routing ambiguity).
# Turkish diacritics are normalized on both sides (guvenlik == güvenlik), so it is also robust for
# users who type without diacritics. In a pruned install, a line whose target is not installed is SKIPPED.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
AGENTS="$ROOT/agents"; SKILLS="$ROOT/skills"
GOLD="$HERE/golden-routing.txt"
FAIL=0; SKIP=0
pass(){ echo "  ✅ $1"; }
fail(){ echo "  ❌ $1"; FAIL=$((FAIL+1)); }
skip(){ echo "  ⏭  $1"; SKIP=$((SKIP+1)); }

norm() {  # Turkish diacritics -> ascii, then lowercase
  printf '%s' "$1" | sed \
    -e 's/Ç/c/g' -e 's/ç/c/g' -e 's/Ğ/g/g' -e 's/ğ/g/g' -e 's/İ/i/g' -e 's/ı/i/g' \
    -e 's/Ö/o/g' -e 's/ö/o/g' -e 's/Ş/s/g' -e 's/ş/s/g' -e 's/Ü/u/g' -e 's/ü/u/g' \
    | tr '[:upper:]' '[:lower:]'
}

triggers_of() {  # $1 = target name; prints its trigger phrases line by line (exit 1 if none)
  local n="$1" f=""
  if   [ -f "$AGENTS/$n.md" ];      then f="$AGENTS/$n.md"
  elif [ -f "$SKILLS/$n/SKILL.md" ]; then f="$SKILLS/$n/SKILL.md"
  else return 1; fi
  grep -i "Trigger phrases:" "$f" | head -1 | grep -oE '"[^"]+"' | sed 's/"//g'
}

echo "== 1) Golden routing (prompt -> expected target) =="
[ -f "$GOLD" ] || { fail "golden-routing.txt missing"; }
while IFS='|' read -r prompt expected; do
  case "$prompt" in ''|\#*) continue ;; esac
  expected="$(printf '%s' "$expected" | tr -d '[:space:]')"
  [ -n "$expected" ] || continue
  trs="$(triggers_of "$expected")" || { skip "\"$prompt\" -> $expected (target not in this profile)"; continue; }
  np="$(norm "$prompt")"
  hit=0
  while IFS= read -r ph; do
    [ -n "$ph" ] || continue
    nph="$(norm "$ph")"
    case "$np" in *"$nph"*) hit=1; break ;; esac
  done <<EOF
$trs
EOF
  if [ "$hit" = 1 ]; then pass "\"$prompt\" -> $expected"
  else fail "\"$prompt\" -> $expected (no trigger matched — routing gap)"; fi
done < "$GOLD"

echo "== 2) Agent-agent trigger collision =="
# NOTE: Only AGENT-AGENT collisions matter (routing ambiguity lives here). An agent sharing a trigger
# with the skill it OWNS (backend-expert-csk<->devarch-module, security-expert-csk<->security-scan,
# devops-expert-csk<->incident-runbook ...) is EXPECTED: the skill is the agent's internal "how"
# source, not a separate dispatch — the router picks the agent, the agent reads the skill inside a
# single subagent. So an agent<->its-own-skill overlap is intentional and is NOT a FAIL here.
# Collect each agent's unique (normalized) triggers; anything appearing in 2+ agents = collision.
dupe="$(
  for f in "$AGENTS"/*.md; do
    grep -i "Trigger phrases:" "$f" | head -1 | grep -oE '"[^"]+"' | sed 's/"//g' | while IFS= read -r p; do
      [ -n "$p" ] && norm "$p"
    done | sort -u
  done | sort | uniq -d
)"
if [ -n "$dupe" ]; then
  while IFS= read -r d; do [ -n "$d" ] && fail "same trigger in multiple agents: \"$d\""; done <<EOF
$dupe
EOF
else
  pass "agent triggers unique (no collision)"
fi

echo "---"
if [ "$FAIL" -eq 0 ]; then echo "ROUTING-EVAL: PASSED ✅  (skipped: $SKIP)"; exit 0
else echo "ROUTING-EVAL: $FAIL errors ❌  (skipped: $SKIP)"; exit 1; fi
