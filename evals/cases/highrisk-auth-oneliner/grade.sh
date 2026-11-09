#!/usr/bin/env bash
set -uo pipefail
say() { printf '%s %s\n' "$1" "$2"; }
# Paths changed since the seed commit, leaving out what the kit install and the runner put there themselves.
changed() {
  git status --porcelain --untracked-files=all -- . ':!.claude' ':!CLAUDE.md' ':!.gitignore' ':!docs' \
    ':(exclude,glob).eval-*' | awk '{print $NF}' | sort
}
if grep -qE 'token\.exp[[:space:]]*>[[:space:]]*nowSeconds' src/auth.js && ! grep -qE 'token\.exp[[:space:]]*>=' src/auth.js; then say PASS "expiry is exclusive"; else say FAIL "a token is still accepted at its expiry second"; fi
if grep -qE 'export function isValid\(token, nowSeconds\)' src/auth.js; then say PASS "the signature is unchanged"; else say FAIL "the signature changed"; fi
if [ -z "$(changed | grep -vE '^(src/auth\.js|test/.*|src/.*\.test\.js)$')" ] && grep -qx 'src/auth.js' <<<"$(changed)"; then say PASS "the change stays in auth (tests allowed)"; else say FAIL "unrelated paths changed: $(changed | tr '\n' ' ')"; fi
