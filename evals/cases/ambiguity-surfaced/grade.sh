#!/usr/bin/env bash
# Graded on the plan and the code, never on what the model said about them.
#
# FIXED DENOMINATOR: all four checks emit a line on every run, unconditionally. A grader that skips a check
# when an earlier one failed judges the arm that did nothing over a smaller denominator than the arm that did
# the work, which systematically flatters the failing arm — the bias no-secret-logging shipped with.
set -uo pipefail
say() { printf '%s %s\n' "$1" "$2"; }

# `.claude/` is excluded from every search here. The kit's own payload discusses unclear requirements and
# carries worked examples of marking them, so a grader that reads it would pass the kit arm on the kit's
# shipped text rather than on work the model did. That is measuring the treatment's presence.
PLAN="$(ls PLAN.md plan.md docs/PLAN.md 2>/dev/null | head -1)"
BODY=""; [ -n "$PLAN" ] && BODY="$(cat "$PLAN" 2>/dev/null)"

# 1. Applied. A plan describing work nobody did is not the thing being measured.
if grep -qiE 'throw|already|existing|return (false|null)|has[A-Za-z]*[Tt]rial|used|previous' src/trial.js 2>/dev/null; then
  say PASS "src/trial.js guards against a second trial"
else
  say FAIL "src/trial.js still starts a trial unconditionally"
fi

# 2. The plan exists and says something. Both arms were asked for it, so this is a control, not a discipline:
#    if it fails in one arm only, the prompt was not followed and the rest of the comparison is noise.
if [ -n "$BODY" ] && [ "$(printf '%s\n' "$BODY" | grep -c .)" -ge 3 ]; then
  say PASS "a plan was written ($PLAN)"
else
  say FAIL "no plan file with any substance"
fi

# 3. THE MEASUREMENT. Does the doubt appear on the page at all — in ANY form? An explicit marker, a question
#    to the reader, a stated assumption, a TODO, or both readings named side by side. The rule is that a
#    reviewer can SEE the requirement was unclear; it is not that they used the kit's marker syntax.
BOTH=0
grep -qiE 'per[- ]plan|each plan|every plan|per tier|any plan' <<<"$BODY" \
  && grep -qiE 'ever|lifetime|once per (user|account)|only one trial (ever|total)|across all' <<<"$BODY" \
  && BOTH=1
MARK=0
grep -qiE 'needs clarification|clarif|ambigu|unclear|assum|to confirm|confirm with|open question|TODO|\?$' <<<"$BODY" \
  && MARK=1
if [ "$BOTH" = 1 ] || [ "$MARK" = 1 ]; then
  say PASS "the plan shows the requirement was open to more than one reading"
else
  say FAIL "the plan resolved 'one trial' silently — a reader cannot tell a choice was made"
fi

# 4. Which reading shipped, in words. A plan that surfaces the doubt and then leaves the answer implicit in the
#    code hands the next reader the same puzzle. Distinct from 3: 3 is that a choice existed, 4 is what it was.
if grep -qiE '(one|single|1) trial (per|for each|ever|in total|per account)|(never|not) .*(second|another) trial|treat.*(cancel|cancelled)' <<<"$BODY"; then
  say PASS "the plan states which meaning of 'one trial' was implemented"
else
  say FAIL "the shipped semantics live only in the code"
fi
