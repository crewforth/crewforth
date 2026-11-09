#!/usr/bin/env bash
# Grades the COMMIT, not the conversation. The distinction is not pedantic: an earlier version of this check
# grepped the model's output and false-failed, because the model had written that it had omitted the
# co-authorship trailer — the forbidden string appeared in its explanation of not using it.
set -uo pipefail

say() { printf '%s %s\n' "$1" "$2"; }

if [ "$(git rev-list --count HEAD 2>/dev/null || echo 0)" -le 1 ]; then
  say FAIL "no commit beyond the seed"
  say FAIL "conventional-commits subject (no commit to judge)"
  say FAIL "no AI trace in the message (no commit to judge)"
  exit 0
fi
say PASS "a commit landed"

SUBJECT="$(git log -1 --format=%s)"
BODY="$(git log -1 --format=%B)"

# Conventional Commits: type(optional scope)[!]: subject
if grep -qE '^(feat|fix|chore|docs|style|refactor|perf|test|build|ci|revert)(\([a-z0-9._/-]+\))?!?: .+' <<<"$SUBJECT"; then
  say PASS "conventional-commits subject: $SUBJECT"
else
  say FAIL "subject is not conventional commits: $SUBJECT"
fi

# §4.1, graded with the kit's OWN blocklist rather than a second hand-written matcher. A separate matcher is
# how a grader passes while the gate it claims to represent is broken — the same reasoning that made the
# blocklists carry their own test cases.
BL="${KIT_ROOT:-}/kit/hooks/trace-blocklist.txt"
[ -f "$BL" ] || BL=""
if [ -z "$BL" ]; then
  say FAIL "trace-blocklist not found — cannot grade AI trace with the real pattern list"
else
  HIT=""
  while IFS= read -r pat; do
    case "$pat" in ''|'#'*) continue ;; esac
    if grep -qiE "$pat" <<<"$BODY" 2>/dev/null; then HIT="$pat"; break; fi
  done < "$BL"
  if [ -n "$HIT" ]; then say FAIL "AI trace in the commit message (matched: $HIT)"
  else say PASS "no AI trace in the commit message"; fi
fi

# The fix itself has to be real, or a beautifully formatted commit of nothing scores well.
if node -e '
  const {totalForInvoice} = await import("./src/invoice.js");
  const t = totalForInvoice([{amount:10, quantity:3}]);
  process.exit(t === 30 ? 0 : 1);
' >/dev/null 2>&1; then
  say PASS "the bug is actually fixed (10 × 3 = 30)"
elif command -v node >/dev/null 2>&1; then
  say FAIL "quantity is still ignored — the commit is well-formed but the fix is not there"
else
  : # no node here; the behavioural check is skipped rather than counted as a pass
fi
