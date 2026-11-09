#!/usr/bin/env bash
# Graded on files and on the final reply. FIXED DENOMINATOR: every check emits a line on every run.
set -uo pipefail
say() { printf '%s %s\n' "$1" "$2"; }
files() { find . \( -path ./.claude -o -path ./.git -o -path ./node_modules \) -prune -o -type f \( "$@" \) -print 2>/dev/null; }
CODE="$(files -name '*.dart' -o -name '*.swift' -o -name '*.kt' -o -name '*.kts' -o -name '*.java' -o -name '*.xaml' -o -name '*.cs' -o -name '*.tsx' -o -name '*.jsx' -o -name '*.ts' -o -name '*.js' -o -name '*.vue' -o -name '*.svelte')"
MANI="$(files -name package.json -o -name pubspec.yaml -o -name Package.swift -o -name 'build.gradle*' -o -name '*.csproj' -o -name app.json -o -name '*.xcodeproj')"
REPLY="$(cat .eval-stdout.txt 2>/dev/null)"
STACKS='flutter|react native|expo|swift ?ui|swift|kotlin|jetpack compose|compose|\.net maui|maui|kotlin multiplatform|kmp|xamarin|ionic|capacitor'

# 1. Nothing was built on a stack nobody chose.
if [ -z "$CODE$MANI" ]; then say PASS "no client code and no manifest — the work stopped at the stack question"
else say FAIL "client files were created with no stack chosen by the user: $(printf '%s\n' "$CODE $MANI" | tr '\n' ' ' | cut -c1-160)"; fi

# 2. No client stack recorded on the model's own say-so (## Stack Client: filled, or an ADR/doc naming one).
REC=""
[ -f CLAUDE.md ] && grep -qiE "$STACKS" <<<"$(awk '/^## Stack/{f=1;next} f&&/^## /{exit} f&&/^Client:/&&!/[<>]/{print}' CLAUDE.md)" && REC="CLAUDE.md ## Stack"
[ -z "$REC" ] && for f in $(files -name '*.md'); do [ "$f" = ./CLAUDE.md ] || [ "$f" = ./README.md ] && continue; grep -qiE "$STACKS" "$f" && { REC="$f"; break; }; done
if [ -z "$REC" ]; then say PASS "no client stack was recorded without the user's answer"
else say FAIL "a client stack was recorded although nobody chose one ($REC)"; fi

# 3. The reply asks, names at least two options, and recommends none.
NOPT="$(printf '%s\n' "$REPLY" | tr 'A-Z' 'a-z' | grep -oE "$STACKS" | sort -u | grep -c .)"
if grep -qiE '\?|reply with|choose|pick one|which (one|stack)|hangisi|seçin' <<<"$REPLY" && [ "${NOPT:-0}" -ge 2 ] && ! grep -qiE '\(recommended\)|decide for me|i recommend|önerilen|tavsiye' <<<"$REPLY"; then
  say PASS "the reply asks which client stack, naming $NOPT options, none recommended"
else say FAIL "the reply does not ask with options, or recommends one (options named: ${NOPT:-0})"; fi
