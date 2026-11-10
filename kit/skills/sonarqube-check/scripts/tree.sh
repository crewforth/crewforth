# Sourced, not run. The ONE way the SonarQube record and its freshness check name "the code as it stands", so the two
# cannot disagree on what was analysed (the same reason eval/lib/lockfiles.sh is one file for §4.7's two sides).
#
# crew_sonar_tree <top> -> CREW_SONAR_TREE: the id of the tree the WORK TREE would commit — staged, unstaged and
# untracked-but-not-ignored files alike. An analysis date compared with the HEAD commit cannot see the change
# /crew-ship is about to commit; this can, and needs no network.
#   A throwaway index, seeded from the real one, takes `git add -A` and writes the tree; the real index is never
#   touched. The review record (.claude/review-pass.json) is left out: it is written after the analysis, sits in the
#   work tree, and is never part of what was analysed.
#   core.fsmonitor= : a repository's .git/config can name a program for git to run; this reads, it runs nothing.
crew_sonar_tree(){
  local top="${1:-.}" ix tmp
  CREW_SONAR_TREE=""
  ix="$(git -C "$top" rev-parse --git-path index 2>/dev/null)" || return 1
  case "$ix" in /*|[A-Za-z]:*) ;; *) ix="$top/$ix" ;; esac      # relative to <top>; --path-format needs git 2.31
  tmp="$(mktemp "${TMPDIR:-/tmp}/crew-sonar-ix.XXXXXX")" || return 1
  if [ -f "$ix" ]; then cp "$ix" "$tmp" || { rm -f "$tmp"; return 1; }; else rm -f "$tmp"; fi
  if GIT_INDEX_FILE="$tmp" git -C "$top" -c core.fsmonitor= add -A -- . ':(exclude,glob)**/.claude/review-pass.json' >/dev/null 2>&1; then
    CREW_SONAR_TREE="$(GIT_INDEX_FILE="$tmp" git -C "$top" write-tree 2>/dev/null)"
  fi
  rm -f "$tmp"
  [ -n "$CREW_SONAR_TREE" ]
}

# The record's file, inside the git directory (crew_git_dir, eval/lib/gate-log.sh): never committed, no .gitignore
# line needed, and each linked worktree keeps its own.
CREW_SONAR_RECORD=crewforth-sonar.json
