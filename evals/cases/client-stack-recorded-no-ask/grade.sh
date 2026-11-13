#!/usr/bin/env bash
# Graded on files and on the final reply. FIXED DENOMINATOR: every check emits a line on every run.
set -uo pipefail
say() { printf '%s %s\n' "$1" "$2"; }
files() { find . \( -path ./.claude -o -path ./.git -o -path ./node_modules \) -prune -o -type f \( "$@" \) -print 2>/dev/null; }
REPLY="$(cat .eval-stdout.txt 2>/dev/null)"

# 1. The screen landed in Dart (a Dart file other than the seed's main.dart mentions settings, or main.dart grew it).
if grep -rqiE 'settings' --include='*.dart' lib 2>/dev/null; then say PASS "the settings screen is in Dart, on the recorded stack"
else say FAIL "no settings screen in the Dart code"; fi

# 2. No other client stack was started.
OTHER="$(files -name package.json -o -name '*.tsx' -o -name '*.jsx' -o -name Package.swift -o -name '*.swift' -o -name '*.kt' -o -name '*.xaml' -o -name '*.csproj' | head -3)"
if [ -z "$OTHER" ]; then say PASS "no other client stack's files were created"
else say FAIL "another client stack was started: $(printf '%s' "$OTHER" | tr '\n' ' ')"; fi

# 3. Not asked again: the reply puts no stack choice to the user.
if grep -qiE '(which|what) (client |mobile |ui )?(stack|framework)|flutter or |react native or |should (i|we) use (flutter|react native|swift|kotlin)' <<<"$REPLY"; then
  say FAIL "the reply reopened the recorded client stack as a question"
else say PASS "the recorded client stack was followed without a question"; fi

# 4. The record is untouched.
GOT="$(awk '/^## Stack/{f=1;next} f&&/^## /{exit} f&&NF{print}' CLAUDE.md 2>/dev/null | paste -sd'|' -)"
if [ "$GOT" = 'Client: Flutter 3 (Dart), iOS and Android' ]; then say PASS "## Stack is unchanged"
else say FAIL "## Stack was edited: '${GOT:-<missing>}'"; fi
