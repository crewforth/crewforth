#!/usr/bin/env bash
# Records what the last SonarQube analysis said, and of WHICH code. /crew-ship reads it back (scripts/freshness.sh)
# and stops when the code changed since. Run it right after the analysis is read (step 2) and again after the final
# re-scan (step 4), from anywhere in the work tree:
#
#   bash .claude/skills/sonarqube-check/scripts/record.sh <clean|unverified> "<gate status + analysis date, or why no analysis ran>"
#
#   clean       an analysis ran and its gate is OK (or every remaining finding has a user-approved suppression)
#   unverified  no analysis could run (no server, the user declined an install); the line says why — an honest gap
#
# A failing gate is not recorded: it is the step-3 work list, not a result to ship.
# The record holds the id of the tree the work tree would commit (scripts/tree.sh), so an edit after the analysis
# makes it stale whether or not anything was committed.
set -u
_here="${BASH_SOURCE//\\//}"; _here="${_here%/*}"; [ "$_here" = "${BASH_SOURCE//\\//}" ] && _here=.   # a Windows path has no `/` to cut at
LIB="$_here/../../../eval/lib"
. "$LIB/gate-log.sh" && . "$_here/tree.sh" || { echo "record.sh: cannot load $LIB/gate-log.sh or $_here/tree.sh" >&2; exit 1; }

V="${1:-}"; NOTE="${2:-}"
case "$V" in clean|unverified) ;; *)
  echo "usage: record.sh <clean|unverified> \"<gate status and analysis date, or why no analysis ran>\"" >&2; exit 1 ;; esac
[ -n "$NOTE" ] || { echo "record.sh: the second argument says what the analysis reported (or why none ran)" >&2; exit 1; }

TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "record.sh: not inside a git work tree" >&2; exit 1; }
crew_sonar_tree "$TOP" || { echo "record.sh: git could not name the work tree's content" >&2; exit 1; }
crew_git_dir "$TOP" || { echo "record.sh: no git directory above $TOP" >&2; exit 1; }

# One flat line, read back with builtins (no space after a colon). The note is free text: quotes and backslashes are escaped.
_esc="${NOTE//\\/\\\\}"; _esc="${_esc//\"/\\\"}"; _esc="${_esc//$'\n'/ }"
printf '{"tree":"%s","verdict":"%s","note":"%s","ts":"%s"}\n' \
  "$CREW_SONAR_TREE" "$V" "$_esc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$_CREW_GD/$CREW_SONAR_RECORD"
echo "recorded: SonarQube $V for the work tree as it stands ($CREW_SONAR_TREE)"
