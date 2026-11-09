# Sourced, not run. The project's own test, lint and type-check commands, read from the files that declare them, so
# the installer can let an agent's verify command run them from the first card on.
#
# WHY. A verify command runs in a hook, past Claude Code's permission prompt, so it runs only when a rule allows it.
# On a real project (3.5.0-rc.2) 22 of 56 agents finished with their verify not run, and the only way to allow one
# was a command the user had to know about. The commands a project declares for itself (`npm test`, `uv run pytest`)
# are the ones its verify commands use; the installer adds them to .claude/crew-model-rules as `verify` lines, says
# so in one line, and the user takes one back by deleting its line. An agent cannot add one: the rules file is closed
# to it (guard-write.sh, guard-bash.sh), and this file only reads.
#
# WHAT IS READ. package.json at the root and one folder down (not node_modules): its scripts test, lint, typecheck /
# type-check, build, run with the package manager its lock file names; with npm, the tools of its devDependencies
# that have a check form (vitest, jest, tsc, eslint) through npx. pyproject.toml: pytest, ruff, mypy when the file
# names them, run through uv or poetry when their lock file is there, else pytest as `python3 -m pytest`. go.mod,
# Cargo.toml, a .sln or .csproj, pubspec.yaml: the toolchain's own test command. Every rule is a prefix
# (guard-agent-model.sh _am_starts): `verify uv run pytest` also allows `uv run pytest tests/test_a.py -q`. A rule
# that would let the hook run any command (crew_verify_open_ended) is never produced.

_vd_add(){  # $1 = command -> appended to _VD_CMDS once
  case "$_VD_NL$_VD_CMDS" in *"$_VD_NL$1$_VD_NL"*) return 0 ;; esac
  if declare -F crew_verify_open_ended >/dev/null 2>&1 && crew_verify_open_ended "$1"; then return 0; fi
  _VD_CMDS="$_VD_CMDS$1$_VD_NL"
}
_vd_node(){  # $1 = folder holding package.json, $2 = the JSON reader
  local d="$1" sj="$2" pm=npm k keys deps
  if [ -f "$d/pnpm-lock.yaml" ]; then pm=pnpm; elif [ -f "$d/yarn.lock" ]; then pm=yarn; elif [ -f "$d/bun.lockb" ] || [ -f "$d/bun.lock" ]; then pm=bun; fi
  keys="$(awk -v op=keys -v path=scripts -f "$sj" "$d/package.json" 2>/dev/null)" || keys=""
  while IFS= read -r k; do
    k="${k%$'\r'}"
    case "$k" in
      test) case "$pm" in bun) _vd_add "bun run test" ;; *) _vd_add "$pm test" ;; esac ;;
      lint|typecheck|type-check|build) case "$pm" in yarn) _vd_add "yarn $k" ;; *) _vd_add "$pm run $k" ;; esac ;;
    esac
  done <<< "$keys"
  [ "$pm" = npm ] || return 0
  deps="$(awk -v op=keys -v path=devDependencies -f "$sj" "$d/package.json" 2>/dev/null; awk -v op=keys -v path=dependencies -f "$sj" "$d/package.json" 2>/dev/null)"
  while IFS= read -r k; do
    case "${k%$'\r'}" in
      vitest) _vd_add "npx vitest run" ;;
      jest) _vd_add "npx jest" ;;
      typescript) _vd_add "npx tsc --noEmit" ;;
      eslint) _vd_add "npx eslint" ;;
    esac
  done <<< "$deps"
}
_vd_python(){  # $1 = folder holding pyproject.toml
  local d="$1" run="" t
  if [ -f "$d/uv.lock" ]; then run="uv run "; elif [ -f "$d/poetry.lock" ]; then run="poetry run "; fi
  t="$(tr -d '\r' < "$d/pyproject.toml" 2>/dev/null)" || t=""
  case "$t" in *pytest*)
    if [ -n "$run" ]; then _vd_add "${run}pytest"; else _vd_add "python3 -m pytest"; fi ;;
  esac
  [ -n "$run" ] || return 0
  case "$t" in *ruff*) _vd_add "${run}ruff check" ;; esac
  case "$t" in *mypy*) _vd_add "${run}mypy" ;; esac
}
# $1 = project root -> _VD_CMDS: the commands, one per line, ending in a newline ("" = none found)
crew_verify_detect(){
  local root="${1:-.}" sj d f
  _VD_NL='
'
  _VD_CMDS=""
  sj="${CREW_SJ_AWK:-}"
  [ -n "$sj" ] || { [ -f "$root/.claude/eval/lib/settings-json.awk" ] && sj="$root/.claude/eval/lib/settings-json.awk"; }
  for d in "$root" "$root"/*; do
    [ -d "$d" ] || continue
    case "${d##*/}" in node_modules|.*|vendor|dist|build|target) [ "$d" = "$root" ] || continue ;; esac
    if [ -f "$d/package.json" ] && [ -n "$sj" ] && [ -f "$sj" ]; then _vd_node "$d" "$sj"; fi
    [ -f "$d/pyproject.toml" ] && _vd_python "$d"
    [ -f "$d/go.mod" ] && _vd_add "go test"
    [ -f "$d/Cargo.toml" ] && _vd_add "cargo test"
    if [ -f "$d/pubspec.yaml" ]; then
      if grep -q 'sdk: *flutter' "$d/pubspec.yaml" 2>/dev/null; then _vd_add "flutter test"; _vd_add "flutter analyze"
      else _vd_add "dart test"; _vd_add "dart analyze"; fi
    fi
    for f in "$d"/*.sln "$d"/*.csproj; do [ -f "$f" ] && { _vd_add "dotnet test"; _vd_add "dotnet build"; break; }; done
  done
  return 0
}

# The installer's step: the detected commands that are not yet `verify` lines, and were never added before, are
# appended to .claude/crew-model-rules. What was added once is remembered in .claude/state/verify-detected, so a line
# the user deleted is not put back by the next update. Prints the one line the installer shows (nothing when nothing
# was added). $1 = project root.
crew_verify_detect_apply(){
  local root="${1:-.}" rules seen c l have added="" n=0 nl='
'
  _VD_ADDED=""
  rules="$root/.claude/crew-model-rules"; seen="$root/.claude/state/verify-detected"
  [ -L "$rules" ] && return 0                     # a link is not written through (the same rule as /crew-allow-verify)
  crew_verify_detect "$root"
  [ -n "$_VD_CMDS" ] || return 0
  have="$nl"
  if [ -f "$rules" ]; then
    while IFS= read -r l || [ -n "$l" ]; do l="${l%$'\r'}"; case "$l" in 'verify '*) have="$have${l#verify }$nl" ;; esac; done < "$rules"
  fi
  if [ -f "$seen" ]; then
    while IFS= read -r l || [ -n "$l" ]; do have="$have${l%$'\r'}$nl"; done < "$seen"
  fi
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    case "$have" in *"$nl$c$nl"*) continue ;; esac
    added="$added$c$nl"; n=$((n+1))
  done <<< "$_VD_CMDS"
  [ "$n" -gt 0 ] || return 0
  mkdir -p "$root/.claude/state" 2>/dev/null
  if [ -f "$rules" ] && [ -s "$rules" ]; then
    l="$(tail -c 1 "$rules" 2>/dev/null)"; [ -z "$l" ] || printf '\n' >> "$rules"
  fi
  { printf '# The project'"'"'s own commands, added by the installer: an agent'"'"'s verify command may run them. Delete a line to take it back.\n'
    while IFS= read -r c; do if [ -n "$c" ]; then printf 'verify %s\n' "$c"; fi; done <<< "$added"
  } >> "$rules" 2>/dev/null || return 0
  while IFS= read -r c; do if [ -n "$c" ]; then printf '%s\n' "$c"; fi; done <<< "$added" >> "$seen" 2>/dev/null
  _VD_ADDED="${added%$nl}"; _VD_ADDED="${_VD_ADDED//$nl/, }"
  return 0
}
