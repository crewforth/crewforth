#!/usr/bin/env bash
# Reads a pull request's title and body on stdin and exits 1 when they carry an assistant's signature line: a
# tool's "generated" footer, a co-author trailer naming Claude or Anthropic, a claude.ai/code link, or a hosted
# session's attribution block (its hidden marker comment and the italic "Requested by **name**" line). Nothing in
# this repository is signed by a tool, in a commit, a PR description or a comment, and the rule has no exception.
# The patterns are written with [-] and [ ] so that this file's own lines do not trip the commit trace scan.
#
# ci.yml runs it on pull_request events and hands the text over through env, never through ${{ }} in the script,
# so what a description says is read as data and never run. It reads only the event payload; no request leaves.
# smoke-test.sh drives it on a fixture that must fail and on one that must pass.
#
#   printf '%s\n%s\n' "$PR_TITLE" "$PR_BODY" | bash packaging/check-attribution.sh
set -uo pipefail

text="$(cat)"
hits="$(printf '%s\n' "$text" | grep -nE '(^|[^[:alpha:]])Generated[ ]with|claude\.ai/code|claude[-]projects[-]attribution|^_Requested[ ]by[ ]\*\*' ;
        printf '%s\n' "$text" | grep -niE 'co-authored[-]by:.*(claude|anthropic)')"
if [ -n "$hits" ]; then
  printf 'attribution: this text carries a signature line, and none is allowed here:\n'
  printf '%s\n' "$hits" | sed 's/^/  line /'
  exit 1
fi
printf 'attribution: no signature line\n'
exit 0
