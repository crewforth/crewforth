#!/usr/bin/env bash
# Is the last SonarQube verdict about the code /crew-ship is about to commit? Network-free: it compares the record
# scripts/record.sh wrote with the work tree as it stands now (scripts/tree.sh). Run from anywhere in the work tree:
#
#   bash .claude/skills/sonarqube-check/scripts/freshness.sh
#
# What it reads first is the project's own answer, `## Stack` -> `Quality analysis:` in ./CLAUDE.md:
#   declined            rc 0  "no analysis ran — unverified (declined)": the DoD reports that, never "clean"
#   empty / a template  rc 1  ask the user once and write the answer on that line
#   sonarqube-*         the record decides:
#                         none                rc 1  no analysis recorded
#                         another tree        rc 1  stale: the code changed since the analysis
#                         this tree           rc 0  the recorded verdict (an `unverified` one stays unverified)
# A step of /crew-ship, not a commit hook: it holds when the session runs /crew-ship.
set -u
_here="${BASH_SOURCE//\\//}"; _here="${_here%/*}"; [ "$_here" = "${BASH_SOURCE//\\//}" ] && _here=.
LIB="$_here/../../../eval/lib"
. "$LIB/gate-log.sh" && . "$_here/tree.sh" || { echo "freshness.sh: cannot load $LIB/gate-log.sh or $_here/tree.sh" >&2; exit 1; }

TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "freshness.sh: not inside a git work tree" >&2; exit 1; }

QA=""
if [ -f "$TOP/CLAUDE.md" ]; then
  while IFS= read -r _l || [ -n "$_l" ]; do
    _l="${_l%$'\r'}"
    case "$_l" in "Quality analysis:"*) QA="${_l#Quality analysis:}"; break ;; esac
  done < "$TOP/CLAUDE.md"
fi
QA="${QA#"${QA%%[![:space:]]*}"}"; QA="${QA%%[[:space:]]*}"    # the first word: `sonarqube-local (since …)` reads sonarqube-local
case "$QA" in
  declined)
    echo "no analysis ran — unverified (declined)"; exit 0 ;;
  ""|"<"*)
    echo "freshness.sh: CLAUDE.md '## Stack' -> 'Quality analysis:' is empty — ask the user once (sonarqube-local, sonarqube-server or declined) and write the answer on that line." >&2
    exit 1 ;;
  sonarqube-*) ;;
  *)
    echo "freshness.sh: 'Quality analysis: $QA' is not one of sonarqube-local, sonarqube-server, declined — fix that line." >&2
    exit 1 ;;
esac

crew_git_dir "$TOP" || { echo "freshness.sh: no git directory above $TOP" >&2; exit 1; }
REC="$_CREW_GD/$CREW_SONAR_RECORD"
J=""
[ -f "$REC" ] && while IFS= read -r _l || [ -n "$_l" ]; do J="$J${_l%$'\r'}"; done < "$REC"
_f(){ local r="${J#*\"$1\":\"}"; [ "$r" = "$J" ] && return 1; printf '%s' "${r%%\"*}"; }
WANT="$(_f tree || true)"; V="$(_f verdict || true)"; TS="$(_f ts || true)"
if [ -z "$WANT" ]; then
  echo "freshness.sh: no SonarQube analysis is recorded for this work tree — apply sonarqube-check, then record its verdict (scripts/record.sh)." >&2
  exit 1
fi
crew_sonar_tree "$TOP" || { echo "freshness.sh: git could not name the work tree's content, so freshness is not known" >&2; exit 1; }
if [ "$WANT" != "$CREW_SONAR_TREE" ]; then
  echo "freshness.sh: stale — the code changed since the analysis recorded at ${TS:-?} (analysed $WANT, now $CREW_SONAR_TREE). Re-scan, then record again." >&2
  exit 1
fi
_n="${J#*\"note\":\"}"; [ "$_n" = "$J" ] && _n="" || _n="${_n%%\",\"ts\":*}"
case "$V" in
  clean)      echo "SonarQube: clean, for the code as it stands (recorded ${TS:-?}): $_n" ;;
  unverified) echo "SonarQube: no analysis ran — unverified (recorded ${TS:-?}): $_n" ;;
  *)          echo "freshness.sh: the record carries an unknown verdict '$V' — record again with record.sh." >&2; exit 1 ;;
esac
exit 0
