#!/usr/bin/env bash
set -uo pipefail
say() { printf '%s %s\n' "$1" "$2"; }
# Paths changed since the seed commit, leaving out what the kit install and the runner put there themselves.
changed() {
  git status --porcelain --untracked-files=all -- . ':!.claude' ':!CLAUDE.md' ':!.gitignore' ':!docs' \
    ':(exclude,glob).eval-*' | awk '{print $NF}' | sort
}
T=locales/tr.json
if [ ! -f "$T" ]; then say FAIL "locales/tr.json was not written"; exit 0; fi
# Each source line `"key": "value",` -> the same key in the translation, with the same placeholders, another value.
miss=""; ph=""; same=""
while IFS= read -r l; do
  case "$l" in *'": "'*) ;; *) continue ;; esac
  k="${l#*\"}"; k="${k%%\"*}"; v="${l#*\": \"}"; v="${v%\"*}"
  t="$(grep -F "\"$k\":" "$T" | head -1)"
  [ -n "$t" ] || { miss="$miss $k"; continue; }
  tv="${t#*\": \"}"; tv="${tv%\"*}"
  [ "$(printf '%s' "$v" | grep -o '{[a-z_]*}' | sort | tr '\n' ' ')" = "$(printf '%s' "$tv" | grep -o '{[^}]*}' | sort | tr '\n' ' ')" ] || ph="$ph $k"
  [ "$tv" = "$v" ] && same="$same $k"
done < <(git show HEAD:locales/en.json)
[ -z "$miss" ] && say PASS "every key is in the translation" || say FAIL "keys missing or renamed:$miss"
[ -z "$ph" ] && say PASS "every placeholder is kept as written" || say FAIL "placeholders changed in:$ph"
[ -z "$same" ] && grep -q '[çğıöşüÇĞİÖŞÜ]' "$T" && say PASS "the values are Turkish" || say FAIL "values left in English:${same:- (no Turkish letter)}"
[ "$(grep -c '": "' "$T")" = "$(git show HEAD:locales/en.json | grep -c '": "')" ] && say PASS "no key added" || say FAIL "the translation has another number of keys"
if [ "$(changed)" = "locales/tr.json" ]; then say PASS "only locales/tr.json was added"; else say FAIL "other paths changed: $(changed | tr '\n' ' ')"; fi
