#!/usr/bin/env bash
# verify.sh — run a CI gate locally, from the SAME definition CI runs.
#
# Why this exists. Every gate in this repo was reachable locally except as a set: the suites lived in
# eval/, the catalogue and manifest checks lived only in ci.yml, and "green" locally meant a strictly
# smaller thing than "green" in CI. That gap is not theoretical — a branch was pushed with all three
# eval suites green and CI failed on the one check that had no local runner, because the README
# catalogue is GENERATED and a hand-edited row silently drifts from the skill it describes.
#
# The fix is one definition, not two. ci.yml calls `verify.sh <step>` per step so GitHub still shows a
# named box per gate, and a developer calls `verify.sh` with no argument to run every step this machine
# can run. Writing the commands in both places is the anti-pattern the kit flags elsewhere: two copies
# of one rule drift, and the copy that drifts is always the one nobody runs.
#
#   bash packaging/verify.sh              # every step (cross steps included), stop at the first failure
#   bash packaging/verify.sh syntax       # one step by name
#   bash packaging/verify.sh --list       # the step names, in order
#
# Exit 0 only if every step attempted PASSED. A step whose tool is absent is reported SKIPPED and is
# NOT counted as a pass — the same rule the suites themselves follow, for the same reason: a check that
# did not run must never read like a check that succeeded.
#
# CREW_VERIFY_STRICT=1 turns a skip into a failure. CI sets it, because there a missing tool is a broken
# runner rather than an honest local limitation, and a gate that goes quiet on a broken runner is worse
# than no gate: it reports success for a check nobody performed.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

B=""; D=""; R=""; RD=""; GR=""; YE=""
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; D=$'\033[2m'; R=$'\033[0m'; RD=$'\033[31m'; GR=$'\033[32m'; YE=$'\033[33m'
fi

# The step list is the contract with ci.yml. Adding a gate here is what makes it runnable locally;
# adding it to ci.yml alone is what put this file here in the first place.
STEPS="syntax smoke routing site manifests e2e studio findings map parser i18n subshell skilleval"

step_syntax(){
  bash -n start.sh || return 1
  bash -n adopt.sh || return 1
  local s
  for s in kit/hooks/*.sh kit/eval/*.sh packaging/*.sh packaging/studio-test/*.sh \
           kit/studio/*.sh kit/studio/server/hooks/*.sh kit/eval/lib/findings/*.sh \
           kit/eval/lib/crew-map/*.sh; do
    [ -f "$s" ] || continue
    bash -n "$s" || return 1
  done
  echo "shell syntax ok"
}

step_smoke(){     bash kit/eval/smoke-test.sh; }
step_routing(){   bash kit/eval/routing-eval.sh; }
# The documentation site (site/, Astro + Starlight). Its pages are generated from the repository — the skill
# catalogue, the agents, the commands, the gate inventory, the counts and the cost figures — so a stale catalogue
# is no longer something to check for: it cannot be built. What is checked is what gets built: every page in both
# languages, no old name, no unbacked number, no broken link, no third-party request (scripts/check.mjs), and the
# generator's own twins (scripts/selftest.mjs). It needs node 22.12+ and site/node_modules; this file never
# installs anything, so without them the step says SKIP — CI runs `npm ci` first and turns a skip red.
step_site(){
  [ -f site/package.json ] || { echo "site/ is MISSING"; return 1; }
  command -v node >/dev/null 2>&1 || { echo "SKIP: node is not on PATH"; return 3; }
  node -e 'const [a,b]=process.versions.node.split(".").map(Number); process.exit(a>22||(a===22&&b>=12)?0:1)' 2>/dev/null \
    || { echo "SKIP: the site needs node 22.12+, this is $(node --version 2>/dev/null)"; return 3; }
  [ -d site/node_modules ] || { echo "SKIP: site/node_modules is absent — run: (cd site && npm ci)"; return 3; }
  local log; log="$(mktemp)"
  ( cd site && npm run --silent build ) >"$log" 2>&1 || { tail -n 30 "$log"; rm -f "$log"; return 1; }
  grep -E '^site: generated' "$log"; rm -f "$log"
  ( cd site && node scripts/check.mjs && node scripts/selftest.mjs )
}
step_e2e(){       bash packaging/e2e.sh; }

# The gate must reach the same verdict whichever parser decoded the payload. This is a real step rather than a
# smoke section because it needs a SECOND parser to compare against, and a machine with only one has measured
# nothing — the script answers 3 for that, which is this file's skip, so the rc passes straight through with no
# translation: 0 every case agreed, 1 a divergence, 3 nothing compared. Under CREW_VERIFY_STRICT, which CI sets,
# that skip turns red, and it should: on a runner a missing parser is a broken runner.
#
# It is wired without `CREW_CONFORMANCE_KNOWN_OPEN`, deliberately. That variable exists to let the file land
# while its three findings were still open; all three are closed, so setting it here would mean a gate that
# cannot report the next one. The variable stays in the script and is pinned there to fail if a row it excuses
# starts passing — a safety valve that cleans itself up, not a permanent dispensation.
step_parser(){    bash kit/eval/parser-conformance.sh; }

# The bilingual installer's message tables, audited statically: patterns quoted (an unquoted one is a GLOB, and
# a lot of prose ends in `?`), no colour or raw ESC inside a message, no stray backslash or bare `%` in a string
# that printf takes as its FORMAT, matching `%s` counts across languages, no `''` (bash concatenates it and eats
# the apostrophe, so `.NET''e` prints `.NETe` — valid syntax, silently wrong output), and no stale pattern that
# no longer matches anything in its script.
#
# Its own step rather than folded into `syntax`, because it has its own verdict to report and hiding it inside a
# step whose name says something else is how a gate stops being read. It is pure bash + awk deliberately: a
# python one would SKIP on a stock Windows desktop, where the Store's python3 stub resolves and then fails — the
# platform where the installer matters most, and the exact shape of four incidents this repo has already paid
# for. Whether gawk (Git Bash, ubuntu) and BSD awk (macOS) agree on it is not measurable on one machine, which
# is why it runs on every platform CI covers.
step_i18n(){      bash packaging/i18n-audit.sh; }
# An assertion inside a subshell increments counters in a child, so it PRINTS green while the suite total does
# not move and a failure is invisible — a silently always-green gate. It happened once, in the block added to
# calibrate the evals metric: five rows printed pass while the total rose by one instead of six, and it was
# caught by reading the COUNT rather than the colour. This finds the shape instead of relying on that.
# The scanner runs its own selftest first and refuses to touch real files if it fails, because its failure mode
# is noise rather than silence: two early versions flagged `for` loops and their own fixtures.
step_subshell(){  bash packaging/subshell-audit.sh; }

# The panel IS part of the payload now; it keeps its own step because it is a
# NODE gate, not because it sits outside what ships. Node is the only thing it
# needs, and a machine without one must say SKIPPED rather than quietly pass —
# CI, which has node, turns that skip red.
#
# A missing directory is a FAILURE, not a skip. It was a skip while the panel
# was optional; now that every channel ships it, a botched move would show as a
# yellow "skipped, NOT a pass" that nobody reads as broken.
step_studio(){
  [ -d kit/studio ] || { echo "kit/studio is MISSING — the panel ships in the payload"; return 1; }
  command -v node >/dev/null 2>&1 || { echo "SKIP: node is not on PATH"; return 3; }
  node --version >/dev/null 2>&1 || { echo "SKIP: node is on PATH but does not run"; return 3; }
  node packaging/studio-test/selfcheck.mjs || return 1
  # The panel needs a runtime; ensure-node.sh is what finds or fetches one. Its own
  # cases run here because they need bash, and the branches worth testing are the ones
  # a machine WITH node can never reach on its own.
  bash packaging/studio-test/ensure-node-cases.sh || return 1
  # The plugin edition ships the panel too. It is NOT tested separately, and the entire argument for
  # not testing it is that it is a byte copy of the payload — so that has to be asserted rather than
  # assumed. The release-time sync gate catches drift only at release; this catches it on every run.
  [ -f plugin/studio/server/index.js ] || {
    echo "plugin/studio is MISSING — the plugin edition ships the panel; run packaging/build-plugin.sh"; return 1; }
  diff -r kit/studio plugin/studio >/dev/null 2>&1 || {
    echo "plugin/studio has drifted from kit/studio — run packaging/build-plugin.sh and commit the result"
    diff -rq kit/studio plugin/studio | head -10; return 1; }
}

# The findings core (kit/eval/lib/findings): the document shape and the validator that holds each finding to the
# lines it cites, the review pre-pass that writes into it (kit/eval/lib/review-prepass), and the bench that says how
# right the review is (kit/eval/lib/review-bench: the matcher, and the pre-pass at its floor; no model runs here). A NODE gate like the panel's, with the same rule for a machine without one: SKIPPED, never a
# quiet pass. It ships in eval/lib, the one directory both editions carry, so the plugin copy is asserted to be
# the payload's bytes for the same reason the panel's is.
step_findings(){
  [ -f kit/eval/lib/findings/findings.mjs ] || { echo "kit/eval/lib/findings is MISSING — the findings core ships in the payload"; return 1; }
  command -v node >/dev/null 2>&1 || { echo "SKIP: node is not on PATH"; return 3; }
  node --version >/dev/null 2>&1 || { echo "SKIP: node is on PATH but does not run"; return 3; }
  node packaging/findings-test/selfcheck.mjs || return 1
  node packaging/review-prepass-test/selfcheck.mjs || return 1
  node packaging/review-bench/selfcheck.mjs || return 1
  local d
  for d in findings review-prepass review-bench; do
    diff -r "kit/eval/lib/$d" "plugin/eval/lib/$d" >/dev/null 2>&1 || {
      echo "plugin/eval/lib/$d is missing or has drifted from kit/eval/lib/$d — run packaging/build-plugin.sh and commit the result"
      diff -rq "kit/eval/lib/$d" "plugin/eval/lib/$d" 2>&1 | head -10; return 1; }
  done
}

# Crew Map's scanner (kit/eval/lib/crew-map): planted defects in eight fixture projects found exactly, the same
# bytes on every run, no secret and no absolute path in what it writes, two child processes per scan. A Node gate
# like the findings core it writes through, so the same rule: no Node is SKIPPED, never a quiet pass. It ships in
# eval/lib as well, so the plugin copy must be the payload's bytes.
step_map(){
  [ -f kit/eval/lib/crew-map/scan.mjs ] || { echo "kit/eval/lib/crew-map is MISSING — the Crew Map scanner ships in the payload"; return 1; }
  command -v node >/dev/null 2>&1 || { echo "SKIP: node is not on PATH"; return 3; }
  node --version >/dev/null 2>&1 || { echo "SKIP: node is on PATH but does not run"; return 3; }
  node packaging/crew-map-test/selfcheck.mjs || return 1
  diff -r kit/eval/lib/crew-map plugin/eval/lib/crew-map >/dev/null 2>&1 || {
    echo "plugin/eval/lib/crew-map is missing or has drifted from kit/eval/lib/crew-map — run packaging/build-plugin.sh and commit the result"
    diff -rq kit/eval/lib/crew-map plugin/eval/lib/crew-map 2>&1 | head -10; return 1; }
}

# A skill's description, held to a measurement (K10): only a change that touches a model-picked skill's description
# is judged, and it passes only when packaging/skill-eval/results.tsv measured THAT text, three runs a case, at or
# above the case's floor. Free: the measurement is run.mjs, by hand, on the developer's own session; this step
# reads its file and calls no model. The gate's own cases come first, in a repository it builds for itself.
step_skilleval(){
  command -v node >/dev/null 2>&1 || { echo "SKIP: node is not on PATH"; return 3; }
  node --version >/dev/null 2>&1 || { echo "SKIP: node is on PATH but does not run"; return 3; }
  node packaging/skill-eval/selftest.mjs || return 1
  node packaging/skill-eval/check.mjs
}

# The only step that needs a tool the repo does not carry. CI installs the CLI; a developer machine
# usually already has it, and a machine without it must say SKIPPED rather than quietly pass.
step_manifests(){
  command -v claude >/dev/null 2>&1 || { echo "SKIP: the claude CLI is not on PATH"; return 3; }
  claude plugin validate plugin --strict || return 1
  claude plugin validate .claude-plugin/marketplace.json --strict || return 1
}

case "${1:-}" in
  --list|-l) printf '%s\n' $STEPS; exit 0 ;;
  --help|-h) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

WANT="${1:-}"
if [ -n "$WANT" ]; then
  case " $STEPS " in *" $WANT "*) ;; *) echo "unknown step: $WANT (try --list)" >&2; exit 2 ;; esac
  STEPS="$WANT"
fi

FAILED=""; SKIPPED=""; PASSED=0
for s in $STEPS; do
  printf '%s\n' "${B}── $s ${R}${D}$(printf '%.0s─' $(seq 1 $((60 - ${#s}))))${R}"
  if "step_$s"; then
    PASSED=$((PASSED + 1)); printf '%s\n\n' "${GR}✅ $s${R}"
  else
    rc=$?
    if [ "$rc" = 3 ] && [ "${CREW_VERIFY_STRICT:-0}" != "1" ]; then
      SKIPPED="$SKIPPED $s"; printf '%s\n\n' "${YE}⏭  $s — skipped, NOT a pass${R}"
    elif [ "$rc" = 3 ]; then
      FAILED="$FAILED $s"; printf '%s\n\n' "${RD}❌ $s — skipped under CREW_VERIFY_STRICT, which means the runner is missing a tool it should have${R}"; break
    else FAILED="$FAILED $s"; printf '%s\n\n' "${RD}❌ $s (rc=$rc)${R}"; break
    fi
  fi
done

printf '%s\n' "${B}VERIFY:${R} $PASSED passed${SKIPPED:+ · skipped:$SKIPPED}${FAILED:+ · ${RD}FAILED:$FAILED${R}}"
[ -z "$FAILED" ] || exit 1
