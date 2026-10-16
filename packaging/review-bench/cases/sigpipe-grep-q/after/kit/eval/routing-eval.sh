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

# Turkish diacritics -> ascii, lowercase, then every run of non-alphanumerics becomes ONE space and the whole
# string is space-padded. That padding is what makes the match word-bounded: a bare substring test routed "the
# build fails on CI" to the frontend expert, because `build` contains `ui` and `UI` is one of its triggers.
# Every short trigger has that failure mode (ui · api · e2e), and it points the wrong way — a CI failure sent to
# the frontend agent is worse than no routing at all, because it looks like Crewforth worked.
norm() {
  printf '%s' "$1" | sed \
    -e 's/Ç/c/g' -e 's/ç/c/g' -e 's/Ğ/g/g' -e 's/ğ/g/g' -e 's/İ/i/g' -e 's/ı/i/g' \
    -e 's/Ö/o/g' -e 's/ö/o/g' -e 's/Ş/s/g' -e 's/ş/s/g' -e 's/Ü/u/g' -e 's/ü/u/g' \
    | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]\{1,\}/ /g' -e 's/^/ /' -e 's/$/ /'
}

triggers_of() {  # $1 = target name; prints its trigger phrases line by line (exit 1 if none)
  local n="$1" f=""
  if   [ -f "$AGENTS/$n.md" ];      then f="$AGENTS/$n.md"
  elif [ -f "$SKILLS/$n/SKILL.md" ]; then f="$SKILLS/$n/SKILL.md"
  else return 1; fi
  grep -i "Trigger phrases:" "$f" | head -1 | grep -oE '"[^"]+"' | sed 's/"//g'
}

# The working set and the held-out set are read by the SAME matcher on purpose: if the holdout were scored more
# leniently, its failures would stop meaning anything. What differs is only where the prompts came from.
GOLD_SETS="$GOLD"
[ -f "$(dirname "$GOLD")/golden-holdout.txt" ] && GOLD_SETS="$GOLD $(dirname "$GOLD")/golden-holdout.txt"
echo "== 1) Golden routing (prompt -> expected target) =="
[ -f "$GOLD" ] || { fail "golden-routing.txt missing"; }
while IFS='|' read -r prompt expected; do
  case "$prompt" in ''|\#*) continue ;; esac
  # `[:space:]` includes CR, and that is the ONLY thing standing between this suite and a CRLF golden file.
  # The Crewforth repo pins `*.txt text eol=lf` in .gitattributes, but these files are also INSTALLED into a user's
  # project, where nothing pins them and Git for Windows sets core.autocrlf=true by default — so a Windows user
  # who commits .claude/ and re-clones gets CRLF here. Measured on Windows with the golden files converted to
  # CRLF byte for byte: 151 passes, 0 failures, identical to the LF run. Without this strip `expected` carries a
  # trailing CR, matches no installed component, and every row fails as "target not installed".
  expected="$(printf '%s' "$expected" | tr -d '[:space:]')"
  [ -n "$expected" ] || continue
  neg=0; case "$expected" in '!'*) neg=1; expected="${expected#!}" ;; esac   # !target = must NOT route here
  # Pre-2.0 this skipped when the target was pruned by profile. Profiles are gone: every install carries every
  # agent and skill, so an absent target is a missing component or a stale golden row — both real failures.
  # (Until 3.0 the .NET pattern skill was the one exception; 3.0 ships one install shape, so there is none.)
  if ! trs="$(triggers_of "$expected")"; then
    fail "\"$prompt\" -> $expected: target not installed — every install ships every component"
    continue
  fi
  np="$(norm "$prompt")"
  hit=0
  while IFS= read -r ph; do
    [ -n "$ph" ] || continue
    nph="$(norm "$ph")"
    case "$np" in *"$nph"*) hit=1; break ;; esac
  done <<EOF
$trs
EOF
  if [ "$neg" = 1 ]; then
    if [ "$hit" = 0 ]; then pass "\"$prompt\" -/-> $expected (correctly not matched)"
    else fail "\"$prompt\" -/-> $expected (over-broad trigger — matched a prompt it should not route)"; fi
  else
    if [ "$hit" = 1 ]; then pass "\"$prompt\" -> $expected"
    else fail "\"$prompt\" -> $expected (no trigger matched — routing gap)"; fi
  fi
done < <(cat $GOLD_SETS)

echo "== 1b) Routing COVERAGE — every installed component has at least one positive case =="
# The golden set proves that the cases in it route. It never proved that every component HAS a case, and an audit
# found 12 skills and one agent with none — including security-scan, code-review, testing and spec-planning. A
# component with no case is a component whose reachability is nobody's job to check, which is exactly how
# crew-frontend-expert stayed unreachable for a whole class of request while every gate reported green. Adding a
# component now means adding the sentence that must reach it.
MISSING_CASE=""
for f in "$AGENTS"/*.md "$SKILLS"/*/SKILL.md; do
  [ -e "$f" ] || continue
  case "$f" in */SKILL.md) n="$(basename "$(dirname "$f")")" ;; *) n="$(basename "$f" .md)" ;; esac
  # A slash command (a skill marked `metadata: kind: command` since 3.0) is typed as /name, never routed to.
  case "$f" in */SKILL.md) grep -q '^  kind: command' "$f" && continue ;; esac
  grep -qE "^[^#]*\|$n\$" $GOLD_SETS || MISSING_CASE="$MISSING_CASE $n"
done
[ -z "$MISSING_CASE" ] && pass "every installed agent/skill has a positive routing case" \
  || fail "no positive golden case for:$MISSING_CASE — add the sentence a user would type to reach it"

echo "== 1c) Routing WINNER — what the real hook names, not only whether a trigger is present =="
# Section 1 asks whether the expected target's trigger APPEARS in the prompt. That never asked whether the target
# WINS: a prompt can carry its owner's trigger and still be routed somewhere else, because a louder word from a
# rival scored higher. Measured, with every golden prompt run through the real route-hint.sh: two working-set
# prompts routed to the wrong owner while section 1 reported both green. "the app feels laggy after the last
# release" went to `release`; "is this endpoint fast enough on the hot path" went to the backend agent.
#
# So this section feeds every golden case through the REAL hook — not a second matcher, which would be the same
# rule written twice and free to drift from the one that actually routes. It counts a positive as a hit when the
# hook names the expected target, or names the agent whose body applies that expected skill: by design the hook
# prefers an agent over a skill, and the agent carries the skill with it (the same notion §3b uses to call a
# skill routed). A negative (`!target`) must never be what the hook names.
#
# KNOWN MISSES ARE A RATCHET, NOT A TOLERANCE. They are listed below by exact prompt. A wrong route that is not
# on the list fails the suite; a listed one that starts routing correctly asks for its line to be removed, so the
# number can only get better. The scorer itself is deliberately untouched: whether a single loud keyword should
# be allowed to win is an open decision recorded in the roadmap, and this is the measurement that decision waits on.
#
# Rank the target among all rivals, not just check that it could match — scored by Crewforth's own scorer, the one
# the hook runs, rather than a TF-IDF approximation.
RH="$ROOT/hooks/route-hint.sh"
KNOWN_MISSES='the app feels laggy after the last release
is this endpoint fast enough on the hot path'
if [ -f "$RH" ]; then
  # CLAUDE_PLUGIN_ROOT points the hook at $ROOT/agents and $ROOT/skills directly, which is the same layout in
  # Crewforth's own repo (kit/) and in an installed project (.claude/). No copy, no second tree to drift.
  rh_names(){ printf '{"hook_event_name":"UserPromptSubmit","prompt":"%s"}' "$1" \
      | CLAUDE_PROJECT_DIR=/nonexistent CLAUDE_PLUGIN_ROOT="$ROOT" bash "$RH" 2>/dev/null \
      | sed -n -e 's/.*Use the \([a-z][a-z0-9-]*\) subagent.*/\1/p' -e 's/.*Use the .\([a-z][a-z0-9-]*\). skill.*/\1/p'; }
  # Calibrate before trusting a single verdict: a prompt the hook is known to route must come back named. An
  # extractor that silently returns nothing makes EVERY positive read as "silent" — measured, the first version
  # of this section did exactly that, with a `\|` that BSD sed does not support, and reported 0 of 82.
  if [ "$(rh_names 'add an endpoint that returns unpaid invoices')" != "crew-backend-expert" ]; then
    fail "winner check cannot read the hook's answer (calibration prompt came back unnamed) — the measurement is broken, not the routing"
  else
    WIN_HIT=0; WIN_N=0; NEG_N=0; NEW_MISS=""; FIXED_MISS=""; NEG_BAD=""
    while IFS='|' read -r prompt expected; do
      case "$prompt" in ''|\#*) continue ;; esac
      expected="$(printf '%s' "$expected" | tr -d '[:space:]')"
      [ -n "$expected" ] || continue
      got="$(rh_names "$prompt")"
      case "$expected" in
        '!'*)
          NEG_N=$((NEG_N+1))
          [ "$got" = "${expected#!}" ] && NEG_BAD="$NEG_BAD
     ↳ named '$got' for: $prompt" ;;
        *)
          WIN_N=$((WIN_N+1))
          ok=0
          if [ -n "$got" ] && [ "$got" = "$expected" ]; then ok=1
          elif [ -n "$got" ] && [ -f "$AGENTS/$got.md" ] && [ -f "$SKILLS/$expected/SKILL.md" ] \
               && grep -qE "\`$expected\`|\*\*$expected\*\*" "$AGENTS/$got.md"; then ok=1
          fi
          known=0; printf '%s\n' "$KNOWN_MISSES" | grep -qxF -- "$prompt" && known=1
          if [ "$ok" = 1 ]; then
            WIN_HIT=$((WIN_HIT+1))
            [ "$known" = 1 ] && FIXED_MISS="$FIXED_MISS
     ↳ now routes correctly, remove it from KNOWN_MISSES: $prompt"
          elif [ "$known" = 0 ]; then
            NEW_MISS="$NEW_MISS
     ↳ expected $expected, hook named '${got:-nothing}': $prompt"
          fi ;;
      esac
    done <<EOF_GOLD
$(cat $GOLD_SETS)
EOF_GOLD
    [ -z "$NEW_MISS" ] && pass "winner: $WIN_HIT of $WIN_N positive prompts routed to their owner by the real hook (known misses: $(printf '%s\n' "$KNOWN_MISSES" | grep -c .))" \
                       || { fail "winner: a prompt is routed to the wrong owner and is not a known miss"; printf '%s\n' "$NEW_MISS"; }
    [ -z "$FIXED_MISS" ] || { fail "winner: a known miss now routes correctly — tighten the ratchet"; printf '%s\n' "$FIXED_MISS"; }
    # A known miss that is not a golden prompt is never evaluated, so it would sit on the list forever and inflate
    # the count shown above. Measured: a stray line reported "known misses: 3" in a green run. A ratchet entry
    # nothing checks is the same defect as a blocklist pattern nothing matches.
    STALE=""
    while IFS= read -r km; do
      [ -n "$km" ] || continue
      cat $GOLD_SETS | cut -d'|' -f1 | grep -qxF -- "$km" || STALE="$STALE
     ↳ not a golden prompt: $km"
    done <<EOF_KM
$KNOWN_MISSES
EOF_KM
    [ -z "$STALE" ] || { fail "winner: a KNOWN_MISSES line is not in any golden set, so nothing ever checks it"; printf '%s\n' "$STALE"; }
    [ -z "$NEG_BAD" ] && pass "winner: none of the $NEG_N negative cases is named by the real hook" \
                      || { fail "winner: the real hook named a target a negative case forbids"; printf '%s\n' "$NEG_BAD"; }
  fi
else
  skip "winner check skipped: $RH not present in this layout"
fi

echo "== 2) Agent-agent trigger collision =="
# NOTE: Only AGENT-AGENT collisions matter (routing ambiguity lives here). An agent sharing a trigger
# with the skill it OWNS (crew-backend-expert<->backend-architecture, crew-security-expert<->security-scan,
# crew-devops-expert<->incident-runbook ...) is EXPECTED: the skill is the agent's internal "how"
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
