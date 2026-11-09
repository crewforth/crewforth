#!/usr/bin/env bash
# Graded on files. FIXED DENOMINATOR: every check emits a line on every run, whichever outcome occurred.
set -uo pipefail
say() { printf '%s %s\n' "$1" "$2"; }
files() { find . \( -path ./.claude -o -path ./.git -o -path ./node_modules \) -prune -o -type f \( "$@" \) -print 2>/dev/null; }
CODE="$(files -name '*.js' -o -name '*.ts' -o -name '*.mjs' -o -name '*.go' -o -name '*.py' -o -name '*.cs' -o -name '*.java' -o -name '*.kt' -o -name '*.rs' -o -name '*.php' -o -name '*.rb')"
MANI="$(files -name package.json -o -name go.mod -o -name pyproject.toml -o -name requirements.txt -o -name '*.csproj' -o -name pom.xml -o -name 'build.gradle*' -o -name Cargo.toml -o -name composer.json -o -name Gemfile)"
RT='node(\.js)?|typescript|golang|go 1\.[0-9]+|python|fastapi|django|flask|\.net|asp\.net|c#|java|spring|kotlin|rust|express|fastify|nestjs'

# The record. CLAUDE.md: only the ## Stack section, and only lines that are no longer template placeholders
# (the kit's template names every runtime inside <…> examples — reading those would pass the kit arm on its own
# payload). Anywhere else outside .claude/: any markdown naming a runtime. The seed README names none. WHOLE
# WORDS (-w): "trust", "javascript", "expression" must not read as rust, java, express.
REC=""
if [ -f CLAUDE.md ] && grep -qiwE "$RT" <<<"$(awk '/^## Stack/{f=1;next} f&&/^## /{exit} f&&NF&&!/[<>]/{print}' CLAUDE.md)"; then REC="./CLAUDE.md"; fi
if [ -z "$REC" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] && [ "$f" != ./CLAUDE.md ] || continue
    grep -qiwE "$RT" "$f" 2>/dev/null && { REC="$f"; break; }
  done <<< "$(files -name '*.md')"
fi

# 1. One of the two acceptable outcomes.
if [ -n "$REC" ] || [ -z "$CODE$MANI" ]; then
  say PASS "either the stack was recorded (${REC:-none}) or the work stopped before any code"
else say FAIL "code was written and no stack was recorded anywhere"; fi

# 2. Order: nothing of the implementation predates the record.
if [ -z "$CODE$MANI" ]; then say PASS "no code — nothing to order (stopped at the question)"
elif [ -z "$REC" ]; then say FAIL "code exists with no record to precede it"
else
  OLDER=""
  while IFS= read -r f; do [ -n "$f" ] || continue; [ "$f" -nt "$REC" ] || OLDER="$OLDER $f"; done <<< "$CODE
$MANI"
  if [ -z "$OLDER" ]; then say PASS "every code/manifest file is newer than the record ($REC)"
  else say FAIL "written before the stack was recorded:$OLDER"; fi
fi

# 3. Decided ONCE: at most one runtime's manifest (two means two stacks were started).
N="$(printf '%s\n' "$MANI" | grep -c . || true)"
if [ "${N:-0}" -le 1 ]; then say PASS "at most one runtime manifest (${N:-0})"
else say FAIL "$N runtime manifests — more than one stack was started"; fi
