#!/usr/bin/env bash
# The one "leave a star" line. Single source of its URL, its text in both languages, and when it stays quiet.
#
#   star.sh --once <project> [doctor]
#                              ONCE PER KIT VERSION per clone and per caller. The installers (first install, and
#                              every update) share one marker; doctor (doctor.sh on a healthy verdict, and the
#                              plugin's /crew-doctor) keeps its own, `doctor`. So a version shows the line at most
#                              twice, once where it was installed and once where it was checked, and never again
#                              until the Crewforth version changes. A marker holds the version it was shown for.
#                              /crew-update runs its doctor with CREW_NO_STAR=1, so one command never shows it twice.
#   star.sh                    unconditional (tests, and anyone who wants to see it).
#
# Nothing else prints it: not a hook, not a session start. Cost: one line (~30 tokens) per version, and only when
# the model relays it — /crew-update and /crew-doctor tell it to pass the line through as the last line.
#
# The marker lives in the git dir (`git rev-parse --git-path`), NOT under .claude/: a project that tracks .claude/
# would otherwise commit it, and one person's "seen" would silence the line for the whole team. Outside a git
# repository it falls back to <project>/.claude/star-shown.
#
# Quiet when CREW_NO_STAR is set to anything but 0, or when CI is defined at all: an unattended run has nobody to
# read it. A silenced run writes NO marker, so the line is still owed to whoever runs it by hand later.
set -u
# The 2.x names of the variables a user can set still work (one helper: eval/lib/crew-env.sh).
_crew_d="${BASH_SOURCE%/*}"; [ "$_crew_d" = "${BASH_SOURCE}" ] && _crew_d=.
[ -f "$_crew_d/./crew-env.sh" ] && . "$_crew_d/./crew-env.sh"; unset _crew_d
CREW_REPO_URL="https://github.com/Crewforth/crewforth"

case "${CREW_NO_STAR:-}" in ''|0) ;; *) exit 0 ;; esac
[ -n "${CI+set}" ] && exit 0

MARK=""; VER=""
if [ "${1:-}" = --once ]; then
  _dir="${2:-.}"
  # Builtin reads, not `head | tr` in a $( ): on Git Bash those two pipelines were 4 of ~11 processes and ~250 ms
  # of ~395 ms per call (measured on stock Windows). `read` takes the first line; the CR is stripped by expansion.
  # The braces matter: a failed `<` reports before a trailing 2>/dev/null applies (measured: 450 bytes of stderr).
  VER=""; { IFS= read -r VER < "$_dir/.claude/VERSION"; } 2>/dev/null; VER="${VER%$'\r'}"
  # The plugin edition has no .claude/VERSION: its version is the manifest's, beside this file at ../../.
  if [ -z "$VER" ]; then
    _here="${BASH_SOURCE%[/\\]*}"; [ "$_here" = "${BASH_SOURCE}" ] && _here=.
    [ -f "$_here/../../.claude-plugin/plugin.json" ] && [ -f "$_here/settings-json.awk" ] && \
      VER="$(awk -v op=get -v path=version -f "$_here/settings-json.awk" "$_here/../../.claude-plugin/plugin.json" 2>/dev/null)"
    VER="${VER#\"}"; VER="${VER%\"}"            # the reader prints a JSON string with its quotes
    case "$VER" in *[!0-9A-Za-z.-]*) VER="" ;; esac
  fi
  VER="${VER:-unknown}"
  _key=crewforth-star; [ "${3:-}" = doctor ] && _key=crewforth-star-doctor
  # GIT_DIR/GIT_WORK_TREE dropped: exported by a caller (a hook), they would point the marker at another repo.
  MARK="$(cd "$_dir" 2>/dev/null && env -u GIT_DIR -u GIT_WORK_TREE git rev-parse --git-path "$_key" 2>/dev/null)" || MARK=""
  case "$MARK" in
    '') MARK="$_dir/.claude/star-shown"; [ "$_key" = crewforth-star ] || MARK="$MARK-doctor" ;;
    /*|[A-Za-z]:*) ;;                          # absolute (POSIX or a Windows drive path from git)
    *) MARK="$_dir/$MARK" ;;                   # git answers relative to the directory it was asked in
  esac
  _seen=""; { IFS= read -r _seen < "$MARK"; } 2>/dev/null; [ "${_seen%$'\r'}" = "$VER" ] && exit 0
fi

# ---- CREW-I18N ------------------------------------------------------------------------------------------
# Same contract as preflight.sh: the installer exports CREW_LANG; run on its own (doctor), the locale decides.
case "${CREW_LANG:-}" in tr|en) ;; *)
  _loc="${LC_ALL:-}"; [ -n "$_loc" ] || _loc="${LC_MESSAGES:-}"; [ -n "$_loc" ] || _loc="${LANG:-}"
  case "$_loc" in tr*|TR*) CREW_LANG=tr ;; *) CREW_LANG=en ;; esac ;;
esac
_mt() {
  [ -n "${1:-}" ] || { _M=""; return 0; }
  local s="$1"; shift
  if [ "$CREW_LANG" = tr ]; then
    case "$s" in
      "⭐ If Crewforth saves you a review round, a star helps others find it: %s") s='⭐ Crewforth bir inceleme turunu kurtardıysa, bir yıldız başkalarının da bulmasına yardım eder: %s' ;;
      *) [ -n "${CREW_I18N_MISS:-}" ] && printf '%s\n' "$s" >> "$CREW_I18N_MISS" ;;
    esac
  fi
  # shellcheck disable=SC2059
  printf -v _M -- "$s" "$@"
}
# ---- /CREW-I18N -----------------------------------------------------------------------------------------

_mt '⭐ If Crewforth saves you a review round, a star helps others find it: %s' "$CREW_REPO_URL"
# The marker only after the line actually went out: a closed stdout must not record "shown".
if printf '%s\n' "$_M" && [ -n "$MARK" ]; then
  # A plugin project may have no .claude/ yet: without one the marker would never be written and the line would
  # come back on every run.
  [ -d "${MARK%/*}" ] || mkdir -p "${MARK%/*}" 2>/dev/null
  { printf '%s\n' "$VER" > "$MARK"; } 2>/dev/null
fi
exit 0
