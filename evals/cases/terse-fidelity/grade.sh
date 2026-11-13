#!/usr/bin/env bash
# Grades the reply text (.eval-stdout.txt) for the three limits of the rule. Each is read by its meaning-bearing
# word, in either language the reply might use, so a correct paraphrase passes and a dropped limit fails:
#   the number   30
#   the only     yalnız / sadece / only / older than … (a "30 günden eski" that keeps the comparison is the limit)
#   the excepts  invoices and archived records are named as NOT deleted (hariç / silinmez / değil / dışında / except / not)
# Calibrated by hand before it was trusted: a faithful sentence and three sentences each missing one limit.
set -uo pipefail
say() { printf '%s %s\n' "$1" "$2"; }
F=".eval-stdout.txt"
[ -s "$F" ] || { say NOT_MEASURED "no reply text to read"; exit 0; }
t="$(tr '[:upper:]' '[:lower:]' < "$F")"
miss=""
grep -q '30' <<<"$t" || miss="$miss number(30)"
grep -qE 'yalnız|yalniz|sadece|only|günden eski|günden daha eski|gunden daha eski|older than' <<<"$t" || miss="$miss only"
grep -qE 'fatura|invoice' <<<"$t" || miss="$miss invoices-named"
grep -qE 'arşiv|arsiv|archiv' <<<"$t" || miss="$miss archived-named"
grep -qE 'hariç|haric|silinmez|silinmiyor|değil|dışında|dokunulmaz|korunur|except|not |never|excluded' <<<"$t" || miss="$miss negation"
if [ -z "$miss" ]; then say PASS "the summary kept the number, the only and both exceptions"
else say FAIL "the summary dropped:$miss"; fi
