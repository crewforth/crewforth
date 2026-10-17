# Sourced, not run. What a risky command would have touched, in one line, for the gate that stops or asks about it:
# the user reads "it would delete 7 uncommitted changes", not only "git reset --hard".
#
#   crew_preview <kind> <command>   -> _CREW_PV ("" when there is nothing to say)
#     reset    git reset --hard: the uncommitted changes to tracked files it discards, and the commits it drops
#              from the branch when it names a target (git reset --hard HEAD~3)
#     clean    git clean -f…: the same command as a dry run (-n, with its -d / -x / -X), and how many paths it lists
#     push     git push --force: the commits on the remote branch the local one does not have, as of the last fetch
#     rm       rm -r…: the files under each named target inside the project; a target outside it, or a pattern, is
#              not counted and the line says so
#     commit   an approved commit: the files and lines it takes (the staged ones, the tracked changes too for -a)
#     push-ask an approved push: the commits it sends, the first three by subject
#
# READ ONLY. Every command here only reads (status, diff --stat, rev-list, log, clean -n, find), nothing fetches,
# and a count of files stops at 10 000. The caller runs this in a subshell and prints what comes back: a preview
# that fails, or ends the shell, leaves the gate's decision as it was. It never decides anything.

_PV_MAX=10000

# Is this a repository, without a process where the gate log's helper is loaded (it is, in the gates).
_pv_repo(){ if declare -F crew_git_dir >/dev/null 2>&1; then crew_git_dir .; else git rev-parse --is-inside-work-tree >/dev/null 2>&1; fi; }

# The current branch's upstream as remote/branch, read from HEAD and the config with builtins: _PV_UP ("" = none).
# A push is asked about on the hot path of a gate whose cost is pinned per call, so the common case (no upstream
# yet) opens no process at all. A linked worktree keeps HEAD in its own git dir and the config in the common one.
_pv_upstream(){
  _PV_UP=""; local gd="" cd l br="" sec="" rem="" mer=""
  declare -F crew_git_dir >/dev/null 2>&1 && crew_git_dir . && gd="$_CREW_GD"
  [ -n "$gd" ] && [ -f "$gd/HEAD" ] || return 1
  IFS= read -r l < "$gd/HEAD" || return 1; l="${l%$'\r'}"
  case "$l" in "ref: refs/heads/"*) br="${l#ref: refs/heads/}" ;; *) return 1 ;; esac
  cd="$gd"; if [ -f "$gd/commondir" ]; then IFS= read -r l < "$gd/commondir"; l="${l%$'\r'}"; case "$l" in /*|[A-Za-z]:*) cd="$l" ;; *) cd="$gd/$l" ;; esac; fi
  [ -f "$cd/config" ] || return 1
  while IFS= read -r l || [ -n "$l" ]; do
    l="${l%$'\r'}"; l="${l#"${l%%[![:space:]]*}"}"
    case "$l" in
      "[branch \"$br\"]") sec=1 ;;
      "["*) sec="" ;;
      remote*=*) [ -n "$sec" ] && { rem="${l#*=}"; rem="${rem#"${rem%%[![:space:]]*}"}"; } ;;
      merge*=*) [ -n "$sec" ] && { mer="${l#*=}"; mer="${mer#"${mer%%[![:space:]]*}"}"; } ;;
    esac
  done < "$cd/config"
  [ -n "$rem" ] && [ -n "$mer" ] && [ "$rem" != . ] && _PV_UP="$rem/${mer#refs/heads/}"
  return 0
}

_pv_words(){  # $1 = command -> _PV_W (the words after the git subcommand $2, quotes dropped)
  local s="$1" sub="$2"
  s="${s#*git}"; s="${s#*"$sub"}"; s="${s%%[;&|]*}"; s="${s//\"/}"; s="${s//\'/}"
  _PV_W="$s"
}

crew_preview(){
  _CREW_PV=""
  local kind="$1" cmd="$2" n t w a flags line
  case "$kind" in
    reset|clean|push|commit|push-ask)
      _pv_repo || { _CREW_PV="Preview: not a git work tree here, nothing counted."; return 0; } ;;
  esac
  case "$kind" in
    reset)
      n="$(git status --porcelain --untracked-files=no 2>/dev/null | wc -l)"; n="${n//[!0-9]/}"
      _pv_words "$cmd" reset; t=""
      for w in $_PV_W; do case "$w" in -*) ;; *) t="$w"; break ;; esac; done
      a=""
      if [ -n "$t" ] && git rev-parse -q --verify "$t^{commit}" >/dev/null 2>&1; then
        a="$(git rev-list --count "$t..HEAD" 2>/dev/null)"; a="${a//[!0-9]/}"
      fi
      _CREW_PV="Preview: it would discard ${n:-0} uncommitted change(s) to tracked files${a:+ and drop $a commit(s) from the branch (back to $t)}."
      ;;
    clean)
      _pv_words "$cmd" clean; flags="-n"
      for w in $_PV_W; do case "$w" in
        --) break ;;
        -*) case "$w" in --*) ;; *) case "$w" in *d*) flags="$flags -d" ;; esac; case "$w" in *x*) flags="$flags -x" ;; *X*) flags="$flags -X" ;; esac ;; esac ;;
      esac; done
      # shellcheck disable=SC2086 # the flags are words of our own
      n="$(git clean $flags 2>/dev/null | wc -l)"; n="${n//[!0-9]/}"
      _CREW_PV="Preview: a dry run (git clean $flags) lists ${n:-0} path(s) it would delete."
      ;;
    push)
      _pv_words "$cmd" push; local rem="" ref="" up=""
      for w in $_PV_W; do case "$w" in -*) ;; *) if [ -z "$rem" ]; then rem="$w"; elif [ -z "$ref" ]; then ref="$w"; fi ;; esac; done
      ref="${ref#+}"; ref="${ref##*:}"
      if [ -n "$rem" ] && [ -n "$ref" ]; then up="refs/remotes/$rem/$ref"
      else up="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"; fi
      if [ -n "$up" ] && git rev-parse -q --verify "$up^{commit}" >/dev/null 2>&1; then
        n="$(git rev-list --count "HEAD..$up" 2>/dev/null)"; n="${n//[!0-9]/}"; up="${up#refs/remotes/}"
        if [ "${n:-0}" -gt 0 ]; then _CREW_PV="Preview: $up has $n commit(s) this branch does not, as of the last fetch; a forced push would overwrite them."
        else _CREW_PV="Preview: as of the last fetch, $up has no commit this branch lacks; a fetch now could show otherwise."; fi
      else
        _CREW_PV="Preview: no remote branch known for it here (nothing fetched), so what it would overwrite is not counted."
      fi
      ;;
    rm)
      local root out="" one c
      root="$(pwd -P 2>/dev/null)"
      _pv_words "x $cmd" rm
      for w in $_PV_W; do
        case "$w" in -*|'') continue ;; *'*'*|*'?'*|'~'*|'$'*) out="${out:+$out; }$w: a pattern, not counted"; continue ;; esac
        # A drive-letter path (D:/x, as Git Bash passes it) is absolute too: measured on Windows, it read as relative
        # and the line said "not there" for a folder that was.
        one="$w"; case "$one" in /*|[A-Za-z]:[/\\]*) ;; *) one="$root/$one" ;; esac
        if [ ! -e "$one" ]; then out="${out:+$out; }$w: not there"; continue; fi
        c="$(cd "$one" 2>/dev/null && pwd -P)" || c="$(cd "$(dirname "$one")" 2>/dev/null && pwd -P)/${one##*/}"
        case "$c/" in "$root"/*) ;; *) out="${out:+$out; }$w: outside the project, not counted"; continue ;; esac
        n="$(find "$one" -type f 2>/dev/null | head -n $((_PV_MAX + 1)) | wc -l)"; n="${n//[!0-9]/}"
        [ "${n:-0}" -gt "$_PV_MAX" ] && n="more than $_PV_MAX"
        out="${out:+$out; }$w: ${n:-0} file(s)"
      done
      [ -n "$out" ] && _CREW_PV="Preview: $out."
      ;;
    commit)
      case " $cmd " in *' -a'*|*' --all'*|*' -[A-Za-z]*a'*) line="$(git diff HEAD --shortstat 2>/dev/null)" ;; *) line="$(git diff --cached --shortstat 2>/dev/null)" ;; esac
      line="${line# }"
      _CREW_PV="Preview: ${line:-nothing staged}."
      ;;
    push-ask)
      local subj="" k=0 rem="" ref=""
      # A push that names its remote and branch (git push origin feat/x) sends to that branch, not the upstream.
      _pv_words "$cmd" push
      for w in $_PV_W; do case "$w" in -*) ;; *) if [ -z "$rem" ]; then rem="$w"; elif [ -z "$ref" ]; then ref="$w"; fi ;; esac; done
      ref="${ref#+}"; ref="${ref##*:}"
      if [ -n "$rem" ] && [ -n "$ref" ] && [ "$ref" != HEAD ]; then
        if [ -f "${_CREW_GD:-.git}/refs/remotes/$rem/$ref" ] || git rev-parse -q --verify "refs/remotes/$rem/$ref" >/dev/null 2>&1; then _PV_UP="$rem/$ref"
        else _CREW_PV="Preview: $rem/$ref is not known here; the push would create it on the remote."; return 0; fi
      else _pv_upstream; fi
      if [ -n "$_PV_UP" ]; then
        # One process: the subjects of what it sends, counted here and the first three named.
        while IFS= read -r line; do k=$((k+1)); [ "$k" -le 3 ] && subj="${subj:+$subj; }${line:0:72}"; done < <(git log --format=%s "$_PV_UP..HEAD" 2>/dev/null)
        [ "$k" -gt 3 ] && subj="$subj …"
        _CREW_PV="Preview: it sends $k commit(s) to $_PV_UP${subj:+ — $subj}."
      else
        _CREW_PV="Preview: the branch has no upstream set here; what it sends is not counted."
      fi
      ;;
  esac
  return 0
}
