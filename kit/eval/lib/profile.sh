#!/usr/bin/env bash
# profile.sh — the strictness profile of this project: light · standard · strict.
#
#   . profile.sh; crew_profile <project root>    sets CREW_PROFILE (standard when nothing says otherwise); builtins only
#   bash profile.sh --show                        prints it, from the project root
#   bash profile.sh --set <profile>               a STRICTER profile only, appended; a looser one is the user's /crew-profile
#
# Where it lives: a `profile <name>` line in .claude/crew-model-rules, the file the session cannot write (guard-write.sh
# and guard-bash.sh close every `crew-model…` name to it), so a session cannot loosen its own gates. The last such
# line wins, as with every line of that file. What each profile changes (DECISIONS, 2026-11-15):
#   light     no question for a commit, or for a push to a branch that is not main, master or protected, once every
#             gate is clean; no turn-end check; handoff at 50 / 75 / 95 %
#   standard  what Crewforth did before profiles: every commit and push asked; handoff at 25 / 50 / 75 / 95 %
#   strict    standard, and what is otherwise a note refuses: a verify that runs the whole suite, an auditor called
#             again on the same work, a model above the card's floor with no `above:` line
# Destructive commands and secrets are refused in every profile.
crew_profile(){  # $1 = project root -> CREW_PROFILE
  local f="${1:-.}/.claude/crew-model-rules" l p=standard
  if [ -f "$f" ]; then
    while IFS= read -r l || [ -n "$l" ]; do
      l="${l%$'\r'}"
      case "$l" in "profile light"|"profile standard"|"profile strict") p="${l#profile }" ;; esac
    done < "$f"
  fi
  CREW_PROFILE="$p"
}
# $1 = the repository's common git directory, $2 = the project root, $3 = a branch -> 0 when a push to it is asked even
# under the light profile: main, master, origin's default branch as the last fetch recorded it, or the CLAUDE.md
# `Base branch:`. Builtins only (the push gate is at its process ceiling). One reader for the gate (guard-bash.sh) and
# for what the session is told when a commit message is asked for (agent-outcome.sh).
crew_push_asked(){
  local t="$3" ob="" b="" l=""
  case "$t" in main|master) return 0 ;; esac
  if [ -f "$1/refs/remotes/origin/HEAD" ]; then
    IFS= read -r ob < "$1/refs/remotes/origin/HEAD"; ob="${ob%$'\r'}"; ob="${ob#ref: refs/remotes/origin/}"; [ "$t" = "$ob" ] && return 0
  fi
  if [ -f "$2/CLAUDE.md" ]; then
    while IFS= read -r l || [ -n "$l" ]; do case "$l" in *"Base branch:"*) b="${l#*Base branch:}"; b="${b//[\` $'\r'$'\t']/}"; break ;; esac; done < "$2/CLAUDE.md"
    [ -n "$b" ] && [ "$t" = "$b" ] && return 0
  fi
  return 1
}
crew_profile_rank(){ case "$1" in light) echo 1 ;; standard) echo 2 ;; strict) echo 3 ;; *) echo 0 ;; esac; }
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    --show) crew_profile .; echo "$CREW_PROFILE"; exit 0 ;;
    --set)
      case "${2:-}" in light|standard|strict) ;; *) echo "usage: profile.sh --set light|standard|strict" >&2; exit 2 ;; esac
      [ -d .claude ] || { echo "profile: no .claude/ here; run it from the root of a project Crewforth is installed in" >&2; exit 1; }
      crew_profile .
      if [ "$(crew_profile_rank "$2")" -lt "$(crew_profile_rank "$CREW_PROFILE")" ]; then
        echo "profile: $CREW_PROFILE -> $2 loosens the gates, and only the user does that: the user can type /crew-profile $2." >&2
        exit 1
      fi
      [ "$2" = "$CREW_PROFILE" ] && { echo "profile: already $2"; exit 0; }
      # APPENDED, never rewritten: the last line wins, and this file holds no function that writes any profile, so a
      # session that sources it gets nothing that loosens. The user's /crew-profile (hooks/prompt-approval.sh) writes both ways.
      printf 'profile %s\n' "$2" >> .claude/crew-model-rules 2>/dev/null || { echo "profile: .claude/crew-model-rules could not be written" >&2; exit 1; }
      crew_profile .; [ "$CREW_PROFILE" = "$2" ] || { echo "profile: written, but the file still reads $CREW_PROFILE" >&2; exit 1; }
      echo "profile: $2"; exit 0 ;;
    *) echo "usage: profile.sh --show | --set light|standard|strict" >&2; exit 2 ;;
  esac
fi
