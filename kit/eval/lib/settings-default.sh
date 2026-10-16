#!/usr/bin/env bash
# settings-default.sh — put one of Crewforth's defaults into the project's .claude/settings.json, only where nothing
# sets it yet. The project's settings win over the user's, so writing a default over a user's own choice would
# silently replace it: a value set in the project's settings, its local settings or the user's own is kept.
#
#   bash settings-default.sh --install <path> <defaults.json> [ENV_VAR]     from the project root
#     <path>           the setting, as a dot path: statusLine, env.CLAUDE_CODE_SUBAGENT_MODEL
#     <defaults.json>  a JSON object holding just that setting (data beside the caller: one definition)
#     ENV_VAR          also kept when this variable is set in the environment (a value exported in the shell)
#
# Prints one word: installed · kept (it is set) · none (no settings.json) · failed (the file is left as it was).
# A managed settings layer is not read. The merge is Crewforth's own JSON reader.
set -u
_here="${BASH_SOURCE%[/\\]*}"; [ "$_here" = "${BASH_SOURCE}" ] && _here=.

[ "${1:-}" = --install ] && [ -n "${2:-}" ] && [ -n "${3:-}" ] || { echo "usage: settings-default.sh --install <path> <defaults.json> [ENV_VAR]" >&2; exit 2; }
KEY="$2"; K="$3"; VAR="${4:-}"
P=".claude/settings.json"; SJ="$_here/settings-json.awk"
[ -f "$P" ] && [ -f "$SJ" ] || { echo none; exit 0; }
case "$VAR" in '') ;; [A-Za-z_]*) case "$VAR" in *[!A-Za-z0-9_]*) echo failed; exit 0 ;; esac; [ -n "${!VAR:-}" ] && { echo kept; exit 0; } ;; *) echo failed; exit 0 ;; esac
for f in "$P" ".claude/settings.local.json" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"; do
  [ -f "$f" ] && awk -v op=get -v path="$KEY" -f "$SJ" "$f" >/dev/null 2>&1 && { echo kept; exit 0; }
done
[ -f "$K" ] || { echo failed; exit 0; }
t="$P.default.$$"
r=failed
# The project's file goes FIRST: the merge refreshes the first file's .claude/hooks/ entries from the first file,
# so put second it would lose every Crewforth hook (measured: the installed project's own smoke failed 30 checks).
# The second file holds only the default, which the first lacks: that is the one change (an object such as env is
# merged member by member, the project's own members kept). Written through the file, so a symlink and its mode
# survive.
if awk -v op=merge -v retired= -f "$SJ" "$P" "$K" > "$t" 2>/dev/null && [ -s "$t" ] \
   && awk -v op=validate -f "$SJ" "$t" 2>/dev/null && awk -v op=get -v path="$KEY" -f "$SJ" "$t" >/dev/null 2>&1; then
  cat "$t" > "$P" && r=installed
fi
rm -f "$t"; echo "$r"
