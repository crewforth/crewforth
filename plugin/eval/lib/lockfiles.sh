# Sourced, not run. The ONE list of lockfiles, and the ONE way to find the staged ones, for the two sides of §4.7:
# guard-bash.sh (reads the audit record back) and skills/dependency-audit/scripts/record.sh (writes it). Both hash
# what crew_staged_lockfiles returns, so a second copy of the list would let them disagree on which files were
# audited and turn a correct record into a refusal (or the reverse).
#
# Lockfiles, not manifests: a lockfile changes when the RESOLVED set changes, which is what an audit judges. A
# manifest also changes for a script, a description or a version field, and gating those would ask for an audit
# that has nothing new to read. (npm's and uv's lockfiles carry the project's own version, so a release bump does
# trip the gate — the one moment an audit is due anyway.) Left out on purpose: flake.lock and .terraform.lock.hcl,
# which pin no package ecosystem dependency-audit can read, so every commit touching them would be `unverified`.
#
# Every function takes the WORK-TREE TOP. git prints staged paths from the top, and they are handed back to git as
# pathspecs, so the two must agree: run from a subfolder, the pathspecs named nothing and the diff hashed to the
# empty blob (found in review: a valid record refused).

# rc 0 when the path's file name is a lockfile.
crew_is_lockfile(){
  case "${1##*/}" in
    package-lock.json|npm-shrinkwrap.json|yarn.lock|pnpm-lock.yaml|bun.lock|bun.lockb|deno.lock) return 0 ;;
    uv.lock|poetry.lock|Pipfile.lock|pdm.lock|pixi.lock|renv.lock|conan.lock) return 0 ;;
    Cargo.lock|go.sum|Gemfile.lock|composer.lock|mix.lock|pubspec.lock) return 0 ;;
    packages.lock.json|paket.lock|*gradle.lockfile|Package.resolved|Podfile.lock|Cartfile.resolved) return 0 ;;
  esac
  return 1
}

# crew_staged_lockfiles <top> -> CREW_LOCKS: the staged lockfiles, an array in git's order. One git process.
# -z, because without it git QUOTES a path with a non-ASCII byte in it ("\305\237/package-lock.json"): the file name
# then ends in `"` and is not a lockfile, so a lockfile in a folder named in Turkish passed the gate unaudited.
# --diff-filter=d: a deleted lockfile has nothing left to audit (deleting one is §4.5's business).
crew_staged_lockfiles(){
  local p
  CREW_LOCKS=()
  while IFS= read -r -d '' p; do
    crew_is_lockfile "$p" && CREW_LOCKS+=("$p")
  done < <(git -C "${1:-.}" diff --cached --name-only --no-renames --diff-filter=d -z 2>/dev/null)
  return 0
}

# crew_lockfile_pending <top> -> rc 0 when a lockfile differs from HEAD anywhere: staged, changed in the work tree,
# or new and untracked. For a command that stages AND commits in one call (`git add -A && git commit`): the hook
# reads the index before the command runs, so what is staged then is not what lands. One git process.
crew_lockfile_pending(){
  local e
  while IFS= read -r -d '' e; do
    # A porcelain entry is "XY path"; a rename's second field is the bare original path. Both are tested.
    crew_is_lockfile "${e:3}" && return 0
    crew_is_lockfile "$e" && return 0
  done < <(git -C "${1:-.}" status --porcelain=v1 -z --untracked-files=all 2>/dev/null)
  return 1
}

# crew_lock_oid <top> -> CREW_LOCK_OID: the object id of the staged diff of CREW_LOCKS alone, or "" when there is no
# such diff to hash. Code staged beside the lockfiles does not change it, so an audit stays valid while the rest of
# the commit is still being edited.
#   --literal-pathspecs: a lockfile under a folder named `[x]` is a path, not a glob.
#   --full-index: the `index` lines carry full object ids, so core.abbrev or the repository's size cannot change the
#     text, and with it the id, between the audit and the commit.
#   pipefail and the empty blob: a diff that FAILS still hands hash-object empty input, and both sides would then
#     agree on e69de29… (found in review). A staged lockfile change is never an empty diff, so that id means "none".
crew_lock_oid(){
  CREW_LOCK_OID="$( set -o pipefail
    git -C "${1:-.}" --literal-pathspecs diff --cached --full-index --no-ext-diff --no-textconv -- "${CREW_LOCKS[@]}" 2>/dev/null \
      | git hash-object --stdin 2>/dev/null )" || CREW_LOCK_OID=""
  case "$CREW_LOCK_OID" in e69de29bb2d1d6434b8b29ae775ad8c2e48c5391|473a0f4c3be8a93681a267e3b1e9a7dcda1185436fe141f7749120a303721813) CREW_LOCK_OID="" ;; esac   # the empty blob, SHA-1 and SHA-256
  return 0
}

# The record's file: crew_git_dir (gate-log.sh) must be loaded. Inside the git directory, so it is never committed,
# needs no .gitignore line on any install, and each linked worktree keeps its own.
CREW_DEPS_RECORD=crewforth-deps-audit.json
