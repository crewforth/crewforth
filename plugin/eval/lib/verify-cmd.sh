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

# A verify command of several steps joined by ` && `: `cd web && npm run lint && npm test`, `uv run ruff check . &&
# uv run pytest -q`. Measured on a real project (3.5.0-rc.2): 21 of the 22 verify commands the hook did not run were
# chains like these, refused whole for their `&&`. Each step is one command, judged alone as before; a `cd <folder>`
# step moves to a folder inside the project (`cd ..` goes back up, never above the root). Only ` && ` joins steps:
# `;`, `||`, `|` and a lone `&` stay inside a step, which the gate then refuses as a chain. Running the steps one
# after another, each only when the one before passed, is what `a && b` does: nothing runs that the steps alone
# would not.
crew_verify_steps(){  # $1 = command, $2 = project root -> 0: _VS_N steps, _VS_D[i] the folder ("" = root), _VS_C[i]
                      # the command; 1: _VS_WHY says why the command is not steps a hook can run
  local s="$1" root="${2:-.}" step cur="" d p last=0 nl='
'
  _VS_N=0; _VS_D=(); _VS_C=(); _VS_WHY=""
  case "$s" in *"$nl"*|*$'\r'*) _VS_WHY="it is more than one line"; return 1 ;; esac
  while [ "$last" = 0 ]; do
    case "$s" in *' && '*) step="${s%% && *}"; s="${s#* && }" ;; *) step="$s"; last=1 ;; esac
    while :; do case "$step" in ' '*) step="${step# }" ;; *' ') step="${step% }" ;; *) break ;; esac; done
    [ -n "$step" ] || { _VS_WHY="it has an empty step"; return 1; }
    case "$step" in
      'cd '*)
        d="${step#cd }"; while :; do case "$d" in ' '*) d="${d# }" ;; *) break ;; esac; done
        case "$d" in ''|/*|~*|-*|*[!A-Za-z0-9._/-]*) _VS_WHY="'$step' does not move to a folder inside the project by a plain relative name"; return 1 ;; esac
        while [ -n "$d" ]; do
          p="${d%%/*}"; if [ "$p" = "$d" ]; then d=""; else d="${d#*/}"; fi
          case "$p" in
            ''|.) ;;
            ..) [ -n "$cur" ] || { _VS_WHY="'$step' leaves the project"; return 1; }
                case "$cur" in */*) cur="${cur%/*}" ;; *) cur="" ;; esac ;;
            *) cur="${cur:+$cur/}$p" ;;
          esac
        done
        [ -d "$root/${cur:-.}" ] || { _VS_WHY="'$step' names a folder that is not there"; return 1; } ;;
      *) _VS_D[_VS_N]="$cur"; _VS_C[_VS_N]="$step"; _VS_N=$((_VS_N+1)) ;;
    esac
  done
  [ "$_VS_N" -gt 0 ] || { _VS_WHY="it only changes folder"; return 1; }
  return 0
}

# The verify commands the hook was refused for want of a rule, read from the record of results: one definition, for
# doctor, which lists them, and for /crew-allow-verify (hooks/prompt-approval.sh), which adds the one the user names.
# Two lists, one entry per line: a command (the one a `verify <command>` line would allow, without its cd), and a line
# that is no command at all: a parenthesis or ` + `, or a first word that is no path, no assignment and nothing this
# machine runs ("measured numbers"). A command a `verify` line of crew-model-rules already allows is left out: it was
# refused before the user allowed it. Each is counted every time it was refused, and listed once.
crew_verify_blocked(){  # $1 = project root -> _VB_N _VB_CMDS, _VB_PN _VB_SENT (lists end in a newline)
  local root="${1:-.}" f l vb vw vc vst v1 vs nl='
' allowed=""
  _VB_N=0; _VB_CMDS=""; _VB_PN=0; _VB_SENT=""
  if [ -f "$root/.claude/crew-model-rules" ]; then
    while IFS= read -r l || [ -n "$l" ]; do l="${l%$'\r'}"; case "$l" in 'verify '*) allowed="$allowed${l#verify }$nl" ;; esac; done < "$root/.claude/crew-model-rules"
  fi
  for f in "$root"/.claude/state/crew-model/results/*; do
    [ -f "$f" ] || continue
    vb=0; vw=""; vc=""; vst=""
    while IFS= read -r l || [ -n "$l" ]; do
      case "$l" in verify=blocked) vb=1 ;; whynot=*) vw="${l#whynot=}" ;; cmd=*) vc="${l#cmd=}" ;; step=*) vst="${l#step=}" ;; esac
    done < "$f"
    # A command of several steps names the step that was refused (crew_verify_steps): that is what a rule allows.
    [ -n "$vst" ] && vc="$vst"
    [ "$vb" = 1 ] || continue
    # Both ways of saying "nothing allows it": in auto/bypassPermissions (not on the runner list) and in the other
    # modes (Claude Code itself would not run it unallowed). Measured on Windows: the second was not listed at all.
    case "$vw" in *"not a test or build command on this hook's list"*|*"does not run a command the user has not allowed"*) ;; *) continue ;; esac
    # A rule names the command alone: `cd sub && ./check.sh` is allowed by `verify ./check.sh` (measured on Windows:
    # the line with the cd in it did not allow it).
    crew_verify_split "$vc" "$root"; vc="$_AMVC"
    [ -n "$vc" ] || continue
    case "$nl$allowed" in *"$nl$vc$nl"*) continue ;; esac
    v1="${vc%% *}"; vs=0
    case "$vc" in *'('*|*' + '*) vs=1 ;; esac
    case "$v1" in */*|*=*) ;; *) command -v -- "$v1" >/dev/null 2>&1 || vs=1 ;; esac
    # A rule that would allow any command is not offered at all (see crew_verify_open_ended below).
    [ "$vs" = 0 ] && declare -F crew_verify_open_ended >/dev/null && crew_verify_open_ended "$vc" && continue
    # Offered as the rule that also allows the next card's other file: `uv run pytest`, not one test file's run.
    [ "$vs" = 0 ] && { crew_verify_rule_of "$vc"; [ -n "$_VR_RULE" ] && vc="$_VR_RULE"; }
    case "$nl$allowed" in *"$nl$vc$nl"*) continue ;; esac
    if [ "$vs" = 1 ]; then
      # Whole for a command (a rule cut short allows nothing); a sentence is shortened, at a word.
      [ "${#vc}" -gt 80 ] && { vc="${vc:0:80}"; vc="${vc% *} …"; }
      _VB_PN=$((_VB_PN+1)); case "$nl$_VB_SENT" in *"$nl$vc$nl"*) ;; *) _VB_SENT="$_VB_SENT$vc$nl" ;; esac
    else
      _VB_N=$((_VB_N+1)); case "$nl$_VB_CMDS" in *"$nl$vc$nl"*) ;; *) _VB_CMDS="$_VB_CMDS$vc$nl" ;; esac
    fi
  done
  return 0
}

# A rule that would let the hook run ANY command. A `verify` rule allows its command and the same command with more
# words after it (guard-agent-model.sh `_am_starts`), so `verify bash` allows `bash evil.sh` and `verify node -e`
# allows any script (found in review). Such a rule is neither offered nor written by /crew-allow-verify: an
# interpreter, a shell, a wrapper that runs what follows it, or a package runner that fetches what it runs, when
# nothing after it names the file or the task, or when what follows is an option (`bash -c`, `node -e`).
crew_verify_open_ended(){  # $1 = command -> 0 when the rule would allow any command
  local c="$1" w1 w2 w3 rest
  # Leading assignments and `env` decide nothing about what runs: `env FOO=1 python3` is `python3` (found in review).
  while :; do
    w1="${c%% *}"
    case "$w1" in env|*/env) [ "$c" = "$w1" ] && return 0; c="${c#"$w1" }" ;; [A-Za-z_]*=*) [ "$c" = "$w1" ] && return 0; c="${c#"$w1" }" ;; *) break ;; esac
  done
  rest="${c#"$w1"}"; rest="${rest# }"; w2="${rest%% *}"; rest="${rest#"$w2"}"; rest="${rest# }"; w3="${rest%% *}"
  case "${w1##*/}" in
    python|python2|python3)
      [ -z "$w2" ] && return 0
      # `python3 -m pytest` names the module it runs; `-c`, `-` or a bare `-m` do not.
      case "$w2" in -m) [ -z "$w3" ] && return 0; case "$w3" in -*) return 0 ;; esac; return 1 ;; -*) return 0 ;; esac ;;
    bash|sh|zsh|dash|ksh|fish|pwsh|powershell|cmd|xargs|sudo|doas|nice|nohup|timeout|command|exec|eval|time|watch|node|deno|bun|ruby|perl|php|lua|osascript|npx|pnpx|bunx|curl|wget|rm|git|make|ssh|docker|kubectl)
      [ -z "$w2" ] && return 0
      case "$w2" in -*) return 0 ;; esac ;;
    npm|pnpm|yarn)
      [ -z "$w2" ] && return 0
      case "$w2" in -*|exec|x|dlx|install|i|add|ci|create|init) return 0 ;; esac ;;
    uvx|pipx)
      [ -z "$w2" ] && return 0
      case "$w2" in -*|run) return 0 ;; esac ;;
    # `uv run pytest` names its tool; `uv run` alone, `uv run -…`, or `uv run python` / a shell runs anything.
    uv|poetry|pdm|hatch|rye)
      [ -z "$w2" ] && return 0
      case "$w2" in
        -*|tool|x|exec) return 0 ;;
        run) [ -z "$w3" ] && return 0
             case "${w3##*/}" in -*|python|python2|python3|bash|sh|zsh|node|env) return 0 ;; esac ;;
      esac ;;
  esac
  return 1
}

# The rule to offer for a refused command: its leading words up to the first that is an option, a path, a file or a
# placeholder, so `uv run pytest tests/test_a.py -q` offers `verify uv run pytest`, which also allows the next card's
# other test file, and `npm run lint` offers itself. A rule allows its command and the same command with more words
# (guard-agent-model.sh _am_starts). When the short form would allow any command, the whole command is offered; when
# that would too, nothing (_VR_RULE empty).
crew_verify_rule_of(){  # $1 = command -> _VR_RULE
  local w r="" n=0 g=0
  _VR_RULE=""
  case "$-" in *f*) ;; *) g=1; set -f ;; esac      # the words as written, never a file name a glob matches
  for w in $1; do
    case "$w" in -*|*/*|*.*|*[!A-Za-z0-9_:@+-]*) [ "$n" -gt 0 ] && break ;; esac
    r="${r:+$r }$w"; n=$((n+1))
  done
  [ "$g" = 1 ] && set +f
  if [ -n "$r" ] && ! crew_verify_open_ended "$r"; then _VR_RULE="$r"
  elif ! crew_verify_open_ended "$1"; then _VR_RULE="$1"; fi
  return 0
}
