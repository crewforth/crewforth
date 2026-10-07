#!/usr/bin/env bash
# Reads changed paths on stdin, one per line, and prints `docs` when EVERY one of them is documentation, `code`
# otherwise. ci.yml uses it to skip the macOS and Windows jobs on a documentation-only pull request: those legs
# measure how bash, git and the installers behave on another OS, and a README edit cannot change that.
#
# The list is deliberately short and pinned by smoke-test.sh. A pattern that could match a script, a hook or
# anything under kit/ would let a real change skip the only platforms where it can break, so smoke goes red if
# one appears. An empty list is `code`: no diff to read means nothing is known, and unknown runs everything.
#
#
# A third answer, `text`: every path is documentation or the TEXT of a skill, an agent or a command (a .md under
# those directories, in kit/ or in its generated plugin/ copy), and at least one is such a text. ci.yml then skips
# the Linux verify job as well. What that gives up, knowingly: the listing budget, the reference pointers, the
# routing triggers and the plugin copy are checked by smoke, and for such a pull request they are first checked by
# the run of the push to next or main, which always runs everything. A hook, a script, a blocklist, kit/CLAUDE.md
# and anything else under kit/ is still `code`.
#
#   git diff --name-only BASE HEAD | bash packaging/ci-docs-only.sh
set -uo pipefail

# DOCS-PATTERNS-START
is_doc() {
  case "$1" in
    README*.md)         return 0 ;;
    site/content/*)     return 0 ;;
    evals/README.md)    return 0 ;;
    evals/results/*)    return 0 ;;
    CHANGELOG.md)       return 0 ;;
  esac
  return 1
}
# DOCS-PATTERNS-END

# TEXT-PATTERNS-START
is_text() {
  case "$1" in
    kit/skills/*.md)       return 0 ;;
    kit/agents/*.md)       return 0 ;;
    kit/commands/*.md)     return 0 ;;
    plugin/skills/*.md)    return 0 ;;
    plugin/agents/*.md)    return 0 ;;
    plugin/commands/*.md)  return 0 ;;
  esac
  return 1
}
# TEXT-PATTERNS-END

seen=0; text=0
while IFS= read -r f || [ -n "$f" ]; do
  f="${f%$'\r'}"
  [ -n "$f" ] || continue
  seen=1
  is_doc "$f" && continue
  is_text "$f" && { text=1; continue; }
  echo code; exit 0
done
if [ "$seen" != 1 ]; then echo code; elif [ "$text" = 1 ]; then echo text; else echo docs; fi
