# Sourced, not run. How a card's verify command is read: one definition, for the gate that runs it
# (hooks/guard-agent-model.sh) and for doctor, which offers the line that would allow it.
#
# A verify command in a sub-folder: `cd apps/mobile && flutter test`, the usual shape in a repository of several
# projects (measured on one: 41 of 71 refused verify commands had it). Split into the folder and the one command,
# so the command is judged alone and run in that folder with no chain; a `verify <command>` rule names the command
# alone. Only a relative folder inside the project, with no .. step, that exists; anything else is left whole, and
# is refused as a chain.
crew_verify_split(){  # $1 = the command, $2 = the project root -> _AMVD the folder ("" = the root), _AMVC the command
  local c="$1" d r root="${2:-.}"
  _AMVD=""; _AMVC="$c"
  case "$c" in 'cd '*' && '*) ;; *) return 0 ;; esac
  d="${c#cd }"; d="${d%% && *}"; r="${c#cd "$d" && }"
  case "$d" in ''|/*|~*|*[!A-Za-z0-9._/-]*|..|../*|*/..|*/../*) return 0 ;; esac
  [ -n "$r" ] && [ -d "$root/$d" ] || return 0
  _AMVD="$d"; _AMVC="$r"
}
