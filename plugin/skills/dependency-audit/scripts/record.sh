#!/usr/bin/env bash
# Records that the staged lockfiles were audited (§4.7). guard-bash.sh refuses a commit that stages a lockfile
# unless this record names the same staged lockfile diff. Run it AFTER the audit, from anywhere in the work tree:
#
#   bash .claude/skills/dependency-audit/scripts/record.sh <clean|accepted|unverified> "<one line: what was found>"
#
#   clean       the audit ran and found nothing open
#   accepted    findings remain and the USER accepted them, in this session, by name
#   unverified  the audit could not run (no network, no tool); the line says why — an honest gap, not a pass
#
# The record lives in the git directory (lib/lockfiles.sh says why) and holds the object id of the staged lockfile
# diff alone, so code staged beside the lockfiles does not invalidate it; another lockfile diff does.
set -u
_here="${BASH_SOURCE%/*}"; [ "$_here" = "$BASH_SOURCE" ] && _here=.
LIB="$_here/../../../eval/lib"
. "$LIB/gate-log.sh" && . "$LIB/lockfiles.sh" || { echo "record.sh: cannot load $LIB (lockfiles.sh, gate-log.sh)" >&2; exit 1; }

V="${1:-}"; NOTE="${2:-}"
case "$V" in clean|accepted|unverified) ;; *)
  echo "usage: record.sh <clean|accepted|unverified> \"<what the audit found>\"" >&2; exit 1 ;; esac
[ -n "$NOTE" ] || { echo "record.sh: the second argument says what the audit found (or why it could not run)" >&2; exit 1; }

TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "record.sh: not inside a git work tree" >&2; exit 1; }
crew_staged_lockfiles "$TOP"
if [ "${#CREW_LOCKS[@]}" -eq 0 ]; then
  echo "record.sh: no lockfile is staged — nothing to record (git add the lockfile first)." >&2; exit 1
fi
crew_lock_oid "$TOP"
[ -n "$CREW_LOCK_OID" ] || { echo "record.sh: git could not hash the staged lockfile diff" >&2; exit 1; }
crew_git_dir "$TOP" || { echo "record.sh: no git directory above $TOP" >&2; exit 1; }

# One flat line, the shape guard-bash.sh's builtin reader expects (no space after a colon). The note is free text,
# so a quote or backslash in it is escaped; the reader never looks inside it.
_esc="${NOTE//\\/\\\\}"; _esc="${_esc//\"/\\\"}"; _esc="${_esc//$'\n'/ }"
printf '{"lock_oid":"%s","verdict":"%s","files":"%s","note":"%s","ts":"%s"}\n' \
  "$CREW_LOCK_OID" "$V" "${CREW_LOCKS[*]}" "$_esc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$_CREW_GD/$CREW_DEPS_RECORD"
echo "recorded §4.7: $V for ${CREW_LOCKS[*]} ($CREW_LOCK_OID)"
