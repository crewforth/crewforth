#!/usr/bin/env bash
# Does installing this kit measurably change what the model does? A/B, graded on artifacts.
#
# Everything else in this repo checks that the kit is well-FORMED — components route, counts match, hooks fire
# on fixtures. None of it checks that the kit WORKS, and "the agents feel better" is not a measurement. This
# runs the same prompt twice: once in a project with the kit installed, once in a bare one, and grades what is
# left on disk afterwards.
#
# Two rules this harness exists to enforce on itself:
#
#   GRADE THE ARTIFACT, NEVER THE TRANSCRIPT. An early hand-rolled attempt false-failed because the model's own
#   commentary ("I left out the co-author trailer per §4.1") contained the very words the grader was grepping
#   for. Graders here read git state and file contents. What the model SAYS it did is not evidence.
#
#   BOTH ARMS GET THE SAME TOOL ACCESS. Otherwise the bare arm fails for permission reasons and the delta
#   measures the harness, not the kit. Both run with identical flags; the only difference is whether .claude/
#   and CLAUDE.md exist.
#
# `claude plugin eval --ablation with-without` is the purpose-built version of this and would replace most of
# the file — still early access as of CLI 2.1.220 (2026-07-29). Re-check with `claude plugin eval .`; when it
# opens, keep the cases and graders and drop the runner.
#
# COSTS REAL TOKENS. Never wired into smoke-test, routing-eval or CI — those must stay hermetic and free. Run
# it deliberately.
#
# Usage:
#   bash evals/run.sh                       # every case, 1 run per arm
#   bash evals/run.sh --runs 3              # 3 runs per arm (nondeterminism is real; 1 run is an anecdote)
#   CREW_EVAL_TRACE=1 bash evals/run.sh      # also print the trace summary: main-thread delegations, cost and tokens per arm
#   CREW_EVAL_MODEL=opus bash evals/run.sh   # the model both arms are pinned to (default sonnet); the served one is checked
#   CREW_EVAL_ARMS="kit kitb" CREW_EVAL_DISCIPLINE_B=<a CLAUDE.md with the sentinel> CREW_EVAL_TRACE=1 bash evals/run.sh --runs 3
#                                           # same install in both arms, only the discipline text differs: measures a RULE
#   CREW_EVAL_CASES=<dir>                    # run cases from another directory (a draft set, before it lands here)
#   CREW_EVAL_OVERLAY_B=<dir>                # arm kitb only: files that REPLACE installed ones, mirrored under .claude/
#
# stdin is /dev/null for every run: without it the CLI waits 3 s for piped input it will never get, and says so.
#   bash evals/run.sh --case secret-refused # one case
#   bash evals/run.sh --keep                # keep the scratch projects for inspection
#   bash evals/run.sh --calibrate           # FREE, no model: each case's grader is fed a known-good and a known-bad
#                                           # project (its calibrate.sh) and must pass the first and fail the second.
#                                           # --selftest is the same mode. Combine with --case to calibrate one.
#
# Every run is pinned to one model and loads only the project's own settings (no user settings, plugins, MCP servers or
# auto-memory). Its stream says which model served it and what the session could see; a run served another model, or
# a control arm that could see a crew- component, makes the run exit 3: the comparison did not hold.
#
# A case may declare REQUIRES="tool ..." in its case.env; when one is missing the case is skipped before anything is built.
# `posix-modes` in that list is not a tool: it asks for a filesystem where chmod sets the mode stat reads back.
#
# Exit 0 the report printed · 1 a case is malformed or the CLI is unusable · 3 INCOMPLETE: a run was not measured (a usage
# limit, a stream that ended in an error, or a case skipped for a missing tool), so the totals printed are not a result ·
# 4 CREW_VERIFY_STRICT=1 and a kit-arm workspace was untrusted: stopped, nothing further is spent or reported.
set -uo pipefail
ROOT="${CREW_EVAL_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CASES="${CREW_EVAL_CASES:-$ROOT/evals/cases}"

# A REQUIRES entry is a command on PATH, or `posix-modes`: a filesystem where chmod sets the mode stat reads back. Git
# Bash on NTFS reports a mode chmod did not set, so a case graded on file modes measures nothing there; say so instead.
posix_modes_ok() {
  local d m; d="$(mktemp -d 2>/dev/null)" || return 1
  chmod 700 "$d" 2>/dev/null; m="$(stat -c '%a' "$d" 2>/dev/null || stat -f '%Lp' "$d" 2>/dev/null)"
  rmdir "$d" 2>/dev/null; [ "$m" = 700 ]
}
req_missing() { # REQUIRES words -> the ones this machine lacks, each with a leading space
  local t; for t in "$@"; do
    case "$t" in
      posix-modes) posix_modes_ok || printf ' %s' "$t" ;;
      *) command -v "$t" >/dev/null 2>&1 || printf ' %s' "$t" ;;
    esac
  done
}

RUNS=1; ONLY=""; KEEP=0; CALIB=0
while [ $# -gt 0 ]; do
  case "$1" in
    --calibrate|--selftest) CALIB=1; shift ;;
    --runs) RUNS="${2:-1}"; shift 2 ;;
    --case) ONLY="${2:-}"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d'; exit 0 ;;   # the whole header, not a line count that drifts
    *) echo "run.sh: unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ---- CALIBRATION: the graders, graded. No model, no CLI, no cost. ----------------------------------------------
# A grader that passes everything, or fails everything, produces a delta that looks like a finding. Each case may
# carry calibrate.sh with two functions, `good` and `bad`, run in the seeded project the way a model run would leave
# it: `good` makes the outcome the case asks for (a correct commit, a refusal written in the reply), `bad` the one it
# guards against. The grader must print no FAIL and at least one PASS for `good`, and at least one FAIL for `bad`; a
# NOT_MEASURED from either is a calibration failure too. A case with no calibrate.sh is counted and named: an
# uncalibrated grader is not known to work, so the run is then INCOMPLETE (exit 3), not green.
# Exit: 0 every case calibrated and graded right · 1 a grader misgraded, or a case is malformed · 3 some uncalibrated.
if [ "$CALIB" = 1 ]; then
  CASES_DIR="${CREW_EVAL_CASES:-$ROOT/evals/cases}"
  CW="$(mktemp -d "${TMPDIR:-/tmp}/crew-eval-cal.XXXXXX")" || { echo "run.sh: could not create a scratch dir" >&2; exit 2; }
  trap 'rm -rf "$CW"' EXIT
  cal_one(){ # $1 case dir, $2 good|bad -> grader output on stdout
    local cd="$1" fn="$2" P="$CW/$(basename "$1")-$2"
    mkdir -p "$P"
    ( cd "$P" || exit 1
      unset -f seed post_seed good bad 2>/dev/null
      . "$cd/case.env"; . "$cd/calibrate.sh"
      git init -q . && git config user.email eval@example.invalid && git config user.name "Eval Runner" && git config commit.gpgsign false
      seed; git add -A >/dev/null 2>&1; git commit -q -m seed >/dev/null 2>&1
      command -v post_seed >/dev/null 2>&1 && post_seed
      "$fn" ) >/dev/null 2>&1
    # The grader gets what the paid path gives it: KIT_ROOT, and EVAL_SECRET as the case defines it.
    ( cd "$P" && unset -f seed post_seed 2>/dev/null; EVAL_SECRET=""; . "$cd/case.env" >/dev/null 2>&1
      KIT_ROOT="$ROOT" EVAL_SECRET="${EVAL_SECRET:-}" bash "$cd/grade.sh" 2>/dev/null )
  }
  CAL_OK=0; CAL_BAD=0; CAL_NONE=""; CAL_N=0
  echo "== grader calibration (no model) =="
  for cdir in "$CASES_DIR"/*/; do
    cname="$(basename "$cdir")"; [ -n "$ONLY" ] && [ "$ONLY" != "$cname" ] && continue
    [ -f "$cdir/case.env" ] && [ -f "$cdir/grade.sh" ] || { echo "run.sh: $cname is missing case.env or grade.sh" >&2; exit 1; }
    CAL_N=$((CAL_N+1))
    if [ ! -f "$cdir/calibrate.sh" ]; then CAL_NONE="$CAL_NONE $cname"; continue; fi
    # A case that declares a tool its grader needs is not calibrated without it either: say so, do not guess.
    REQUIRES=""; REQUIRES="$(sed -n 's/^REQUIRES="\(.*\)"/\1/p' "$cdir/case.env" | head -1)"
    # shellcheck disable=SC2086
    miss="$(req_missing $REQUIRES)"
    if [ -n "$miss" ]; then CAL_NONE="$CAL_NONE $cname(needs$miss)"; continue; fi
    og="$(cal_one "$cdir" good)"; ob="$(cal_one "$cdir" bad)"
    why=""
    printf '%s\n' "$og" | grep -q '^NOT_MEASURED ' && why="$why good:NOT_MEASURED"
    printf '%s\n' "$ob" | grep -q '^NOT_MEASURED ' && why="$why bad:NOT_MEASURED"
    printf '%s\n' "$og" | grep -q '^FAIL ' && why="$why good:$(printf '%s\n' "$og" | grep -c '^FAIL ')-FAIL"
    printf '%s\n' "$og" | grep -q '^PASS ' || why="$why good:no-PASS"
    printf '%s\n' "$ob" | grep -q '^FAIL ' || why="$why bad:no-FAIL"
    if [ -z "$why" ]; then
      CAL_OK=$((CAL_OK+1)); printf '   ok    %-32s good %s PASS · bad %s FAIL\n' "$cname" "$(printf '%s\n' "$og" | grep -c '^PASS ')" "$(printf '%s\n' "$ob" | grep -c '^FAIL ')"
    else
      CAL_BAD=$((CAL_BAD+1)); printf '   MISGRADED %-28s%s\n' "$cname" "$why"
      printf '%s\n' "$og" | grep '^FAIL ' | sed 's/^/        good → /' | head -3
    fi
  done
  echo "---"
  printf '   calibrated %s of %s case(s): %s graded right, %s misgraded\n' "$((CAL_OK+CAL_BAD))" "$CAL_N" "$CAL_OK" "$CAL_BAD"
  [ -n "$CAL_NONE" ] && printf '   NOT CALIBRATED:%s\n' "$CAL_NONE"
  [ "$CAL_BAD" -gt 0 ] && exit 1
  [ -n "$CAL_NONE" ] && exit 3
  exit 0
fi

command -v claude >/dev/null 2>&1 || { echo "run.sh: the claude CLI is not on PATH" >&2; exit 1; }
# Probed by running it: on Windows `command -v python3` finds the Store redirector, which resolves and exits 49.
printf '' | python3 -c 'import sys,json' >/dev/null 2>&1 || { echo "run.sh: no working python3 — the event stream every run is read from cannot be parsed" >&2; exit 1; }
CLI="$(claude --version 2>/dev/null | head -1)"
# The model is PINNED, and the one each run was served is read back from its own stream. The header used to print
# the CLI version where the model belonged and no run named one, so the two arms ran whatever each session's
# default was that day — and a later rerun could not say whether a difference was the kit or the model.
EVAL_MODEL="${CREW_EVAL_MODEL:-sonnet}"
# Only a request that names a model can be checked against the stream: an alias of a family or a full id. `default`
# or `opusplan` would pass whatever was served, and the pin would be a word.
case "$(printf '%s' "${EVAL_MODEL%%\[*}" | tr '[:upper:]' '[:lower:]')" in
  sonnet|opus|haiku|fable|claude-*) ;;
  *) echo "run.sh: CREW_EVAL_MODEL='$EVAL_MODEL' names no model the stream can be checked against — use sonnet, opus, haiku, fable or a full claude-… id" >&2; exit 1 ;;
esac
# Both arms run with ONLY the project's own settings. Without these flags the user's settings, plugins, MCP servers,
# hooks and auto-memory loaded into the kit arm and the bare arm alike: on a machine with Crewforth installed as a
# user plugin, the control arm was running Crewforth. The CLAUDE.md files are NOT turned off — the kit arm IS the
# project CLAUDE.md. Whether a user-level CLAUDE.md still loads under these flags is not measured; it is said below.
ISO_FLAGS="--setting-sources project,local --strict-mcp-config --no-session-persistence"

# Where the scratch projects live matters more than it looks: Claude Code trusts a workspace per path, and an
# untrusted one silently drops the `permissions.allow` entry the kit ships. Override with CREW_EVAL_WORK to run
# somewhere already trusted.
# A failed mktemp used to leave WORK EMPTY and the run carried on regardless, so every path became "/<case>-kit-1"
# and the runner started creating scratch projects at the FILESYSTEM ROOT. It only looked harmless because macOS
# mounts / read-only; anywhere else it would have scattered directories across the root and then `rm -rf` them on
# exit. A missing CREW_EVAL_WORK is a typo, not a reason to write to /.
WORKBASE="${CREW_EVAL_WORK:-${TMPDIR:-/tmp}}"
[ -d "$WORKBASE" ] || { echo "run.sh: work dir '$WORKBASE' does not exist (CREW_EVAL_WORK) — create it or unset the variable" >&2; exit 2; }
EVWT=""   # scratch worktrees created this run; removed on exit so the parent does not accumulate them
WORK="$(mktemp -d "$WORKBASE/crew-eval.XXXXXX")" || { echo "run.sh: could not create a scratch dir under '$WORKBASE'" >&2; exit 2; }
[ -n "$WORK" ] && [ -d "$WORK" ] || { echo "run.sh: scratch dir is empty/missing — refusing to run" >&2; exit 2; }
# The prune matters as much as the rm: a worktree whose directory is gone stays REGISTERED in the parent, and
# the registrations accumulate one per case per run until `worktree add` starts refusing paths.
# THE TRUSTED PARENT (see build_project for why there is one). 3.0 named it `~/.crew-eval-parent`, and the rename
# moved nothing on disk: a machine set up under 2.x has only `~/.csk-eval-parent`. Measured on 2026-09-25: that is
# exactly what happened, every kit run fell back to `git init` and ran untrusted, and the report said so only as a
# warning. So 3.x reads the 2.x directory as well, the same rule as the CSK_* variables (crew-env.sh) — REMOVED IN
# 4.0. The 3.0 name wins when both exist; CREW_EVAL_PARENT wins over both.
eval_parent_path(){
  if [ -n "${CREW_EVAL_PARENT:-}" ]; then printf '%s\n' "$CREW_EVAL_PARENT"; return 0; fi
  if [ ! -d "$HOME/.crew-eval-parent/.git" ] && [ -d "$HOME/.csk-eval-parent/.git" ]; then
    printf '%s\n' "$HOME/.csk-eval-parent"; return 0
  fi
  printf '%s\n' "$HOME/.crew-eval-parent"
}
# AN UNTRUSTED KIT WORKSPACE, AND WHAT IT MAY COST THE RESULT. It drops the kit's `permissions.allow` and nothing
# else (measured, see the call site), so outside strict mode it is a warning and the run is still graded. Under
# CREW_VERIFY_STRICT=1 it is an error: a measurement must never complete quietly in a state it did not choose.
# $1 = why (text), $2 = the path to trust. Returns 0 to go on, 1 when the caller must stop.
eval_untrusted(){
  if [ "${CREW_VERIFY_STRICT:-0}" = 1 ]; then
    echo "run.sh: ERROR — $1 (CREW_VERIFY_STRICT=1). Trust $2 once interactively, or set CREW_EVAL_PARENT / CREW_EVAL_WORK to a trusted path." >&2
    return 1
  fi
  echo "   ! workspace untrusted: $1 — permissions.allow is dropped for this run (hooks/gates are NOT affected)." >&2
  echo "     Only matters for cases needing a pre-approved permission. Re-run with CREW_EVAL_WORK=<a trusted path>," >&2
  echo "     or trust $2 once interactively." >&2
  return 0
}
EVPAR="$(eval_parent_path)"
trap '[ "$KEEP" = 1 ] && echo "scratch kept: $WORK" || { rm -rf "$WORK"; _P="$EVPAR"; git -C "$_P" worktree prune >/dev/null 2>&1; git -C "$_P" for-each-ref --format="%(refname:short)" "refs/heads/crew-eval/${WORK##*/}/" 2>/dev/null | while read -r _b; do git -C "$_P" branch -D "$_b" >/dev/null 2>&1; done; }; true' EXIT

# build_project <dir> <arm>  — identical seed in both arms; the kit is the only variable.
build_project() {
  local dir="$1" arm="$2"
  mkdir -p "$dir" || { echo "run.sh: cannot create '$dir'" >&2; return 1; }
  # `cd` MUST be fatal here. It used to sit on its own line, so a failed cd printed an error and the subshell
  # carried straight on IN THE CALLER'S DIRECTORY — which is the kit repo. That is not theoretical: an unset
  # scratch path made this run `git init`, `git config user.email eval@example.invalid`, the case's `seed`
  # (which overwrites README.md) and finally `git add -A && git commit` against the repo itself, committing a
  # working tree of real work under the message "seed". Nothing here may run outside the scratch project.
  # A SCRATCH PROJECT IS A WORKTREE OF A TRUSTED THROWAWAY PARENT, not a fresh `git init`, and the reason is
  # measured rather than stylistic. `git init` makes the directory its OWN project boundary; a new project is
  # untrusted; an untrusted project has its `permissions.allow` DROPPED. Three probes, 2026-09-21:
  #   permissions.allow absent + git init  -> no warning   (this is why an earlier probe read "trust inherited")
  #   permissions.allow present, no git    -> no warning
  #   permissions.allow present + git init -> "has not been trusted"
  # The two cases that need a pre-approved permission (`commit-format`, `secret-refused`) were therefore
  # unmeasurable for a reason that had nothing to do with §4.4: CLAUDE_GIT_OK was being handed over correctly
  # and the permission LAYER was gone underneath it.
  #
  # A worktree inherits its parent's trust, and that inheritance follows the RELATIONSHIP rather than the path
  # (measured: a worktree under TMPDIR is trusted too). The parent is `~/.crew-eval-parent` (or its 2.x name, see eval_parent_path) — created once, no
  # remote, one empty root commit — and NOT this repository: a worktree of the kit repo can see `origin`, all
  # its branches and `origin/main`, and these cases deliberately provoke destructive git commands in an arm
  # that has no gates. Measured before rejecting it: origin = the live GitHub remote, 24 branches visible.
  # With the throwaway parent: 0 files, 0 remotes, no origin/main, no trust warning.
  #
  # Falls back to `git init` when the parent is absent, so the suite still runs; a kit arm then reports
  # `! workspace untrusted` with the cause — and under CREW_VERIFY_STRICT=1 the run stops there instead (exit 4).
  # ORPHAN, not detached at a base commit — and this is a correction of the first version. That one put every
  # scratch project on an empty root commit, so the seed became the SECOND commit and any grader that counts
  # commits was off by one: `commit-format` checks `rev-list --count HEAD -le 1` for "no commit beyond the
  # seed", and with the extra root it PASSED "a commit landed" when the model had committed nothing, read the
  # subject as "seed", and passed "no AI trace" on the seed commit too. Measured: detached worktree + seed ->
  # count 2, grader says a commit landed; orphan worktree + seed -> count 1, grader correctly says none did.
  # An orphan branch has no parent, so the seed is the root exactly as it was under `git init`. Trust is still
  # inherited (re-measured: warning 0) and the branch is deleted on exit with the worktree.
  EVFELL=0
  EVBR="crew-eval/${WORK##*/}/${dir##*/}"
  if [ -d "$EVPAR/.git" ] && git -C "$EVPAR" worktree add -q --orphan -b "$EVBR" "$dir" 2>/dev/null; then
    EVWT="$EVWT $dir"
  else
    # No parent to inherit trust from, so this project will be untrusted. Decided HERE, before any model call:
    # in strict mode the run stops before it spends anything.
    # Only a kit arm carries a `permissions.allow` to lose; a bare project untrusted is the same project.
    if [ "$arm" = kit ] || [ "$arm" = kitb ]; then
      EVFELL=1
      eval_untrusted "no trusted parent at $EVPAR (fell back to git init)" "$dir" || exit 4
    fi
    ( cd "$dir" || exit 1; git init -q )
  fi
  ( cd "$dir" || exit 1
    git config user.email eval@example.invalid
    git config user.name  "Eval Runner"
    git config commit.gpgsign false
    seed                                            # case-supplied, runs in the project dir
    git add -A >/dev/null 2>&1
    git commit -q -m "seed" >/dev/null 2>&1
    # Optional, runs AFTER the seed commit: the only way a case can start with something UNTRACKED, which some
    # behaviours (anything about cleaning a working tree) cannot be posed without.
    command -v post_seed >/dev/null 2>&1 && post_seed
  )
  if [ "$arm" = kit ] || [ "$arm" = kitb ]; then
    cp "$ROOT/start.sh" "$dir/"; cp -R "$ROOT/kit" "$dir/"
    ( cd "$dir" && printf 'yes\n' | bash start.sh --fullstack --generic >/dev/null 2>&1 )
    # A bare-arm project has no .claude/, so a leftover installer would be a second difference between the
    # arms. It removes itself on success; make sure.
    rm -f "$dir/start.sh"; rm -rf "$dir/kit"
    [ -d "$dir/.claude" ] || { echo "run.sh: install failed in $dir" >&2; return 1; }
    # Arm kitb: the same install with ONE difference, the discipline half of CREW_EVAL_DISCIPLINE_B. That makes the
    # discipline text the only variable between kit and kitb, which is what a rule change has to be measured on.
    if [ "$arm" = kitb ]; then
      [ -f "${CREW_EVAL_DISCIPLINE_B:-}" ] || { echo "run.sh: arm kitb needs CREW_EVAL_DISCIPLINE_B=<a CLAUDE.md with the sentinel>" >&2; return 1; }
      grep -qE '^<!-- KIT:DISCIPLINE-END' "$CREW_EVAL_DISCIPLINE_B" || { echo "run.sh: CREW_EVAL_DISCIPLINE_B has no '<!-- KIT:DISCIPLINE-END' sentinel" >&2; return 1; }
      awk '/^<!-- KIT:DISCIPLINE-END/{exit} {print}' "$CREW_EVAL_DISCIPLINE_B" > "$dir/.claude/DISCIPLINE.md"
    fi
    # CREW_EVAL_OVERLAY_B carries the half of a rule that does not live in the discipline file: agent definitions. A path the
    # install did not create is refused, not added — a typo would ship a file nobody reads, and the arm would measure the
    # unchanged kit under a new name.
    if [ "$arm" = kitb ] && [ -n "${CREW_EVAL_OVERLAY_B:-}" ]; then
      [ -d "$CREW_EVAL_OVERLAY_B" ] || { echo "run.sh: CREW_EVAL_OVERLAY_B='$CREW_EVAL_OVERLAY_B' is not a directory" >&2; return 1; }
      local rel applied=0
      while IFS= read -r rel; do
        [ -f "$dir/.claude/$rel" ] || { echo "run.sh: overlay file '$rel' replaces nothing under .claude/ — refusing to add it" >&2; return 1; }
        cp "$CREW_EVAL_OVERLAY_B/$rel" "$dir/.claude/$rel" && applied=$((applied+1))
      done < <(cd "$CREW_EVAL_OVERLAY_B" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)
      [ "$applied" -gt 0 ] || { echo "run.sh: CREW_EVAL_OVERLAY_B='$CREW_EVAL_OVERLAY_B' is empty" >&2; return 1; }
    fi
  fi
}

# run_arm <dir> <arm> — same flags both sides. The kit arm additionally gets CLAUDE_GIT_OK when the case needs
# a commit to actually land: §4.4 gates the git TOOL behind human approval, which headless cannot answer, and
# without the documented escape the kit arm would be unable to commit for reasons that have nothing to do with
# the behaviour under test. The content gates (trace/secret pre-commit) still run — that is the point.
# eval_trace_metrics <stream.jsonl> <stdout.txt> — one TSV line:
#   agent_top agent_all spawned cost in out cache_read cache_create turns bad_lines has_result tests tests_nested turns_top turns_nested is_error limited final_tested parallel_msgs agents_in_one_msg_max
# agents_by_type (appended last): the main thread's Agent calls by subagent_type, "name:count,…" sorted, "-" for none. The
# count alone cannot say WHICH agent ran, and two agents were never started while every delegation count looked healthy.
# The last TWO before it were appended for the parallel-audit rule, which no earlier column could measure: Workflow step
# 3 says the applicable audits are issued as several `Agent` calls in ONE message, because that is what makes
# them concurrent. `agent_top` counts calls and `turns_top` counts messages, so 3-in-3 and 3-in-1 are identical
# in both — and only the second obeys the rule. `parallel_msgs` is the number of main-thread messages carrying
# two or more Agent calls; `agents_in_one_msg_max` is the largest such message. Main thread only: a subagent
# fanning out is not the rule's subject. Calibrated in smoke-test (free — this is a pure function over a file,
# so its own correctness costs no tokens even though running the evals does).
# The last four were appended, not inserted, so every earlier column keeps its position. `tests` counts Bash calls that run a test
# runner or a build/lint tool — main thread and subagents alike, since the stream carries both — deduplicated by tool_use id. The bare
# word "test" is deliberately not a match: measured on real transcripts, the calls it caught alone were echo banners, not runs.
# agent_top counts Agent/Task calls made by the MAIN thread (no parent_tool_use_id); agent_all includes nested ones.
# has_result=0 means the stream is empty or broken: that run says nothing about delegation and must not be counted.
# is_error=1 and limited=1 mean the same thing for a stream that DID end in a result. A usage-limit rejection is exactly that: a
# result event with subtype success, is_error true and api_error_status 429, preceded by a rate_limit_event whose status is
# "rejected". Measured: a 9-session run hit the five-hour limit in its 2nd session and the next 7 returned in ~0.6 s each, with
# a result event and no tool call. has_result alone counted all of them, and the grader scored 7 untouched projects.
# final_tested: 1 when a test/build run comes after the last Edit/Write, in stream order across the main thread and subagents; 0 when
# it does not; empty when nothing was edited. A change that cuts test runs must not cut this one — it is the run that says the code
# that was left behind works. File edits made through Bash (sed -i, redirection) are not seen.
eval_trace_metrics() {
  python3 - "$1" "$2" <<'PYM'
import json, sys, re
src, txt = sys.argv[1], sys.argv[2]
RUNRX = re.compile(r'(^|[\s;&|(])(pytest|jest|vitest|mocha|make|mvn|gradle|tsc|eslint|ruff|flake8|mypy)\b|(dotnet|go|cargo)\s+(test|build)\b|(npm|pnpm|yarn)\s+(run\s+)?(test|build|lint)\b|\bnode\s+--test\b')
top = allc = bad = limited = 0; res = None
tests = tnest = 0; seen_tu = set(); msgs_top = set(); msgs_nest = set(); k = last_edit = last_test = edits = 0
# per_msg: Agent calls PER MAIN-THREAD MESSAGE. `agent_top` and `msgs_top` already existed and cannot answer
# the question the parallel-audit rule asks: 3 calls in 3 messages and 3 calls in ONE message both read as
# agent_top=3, and only the second is concurrent — issuing them in one message is what makes them run at the
# same time. Keyed on the message id, falling back to the line number so messages WITHOUT an id stay separate
# instead of collapsing into one bucket (which is a latent flaw in msgs_top, left alone here rather than
# changed silently).
per_msg = {}; by_type = {}
# Columns 27-29, appended: every tool call of the run, the Reads of a component's references or an agent file (did the
# run open the material the kit points at), and the skills it loaded, in order.
REFRX = re.compile(r'(^|[\\/])(skills[\\/][^\\/]+[\\/]references[\\/]|agents[\\/])[^\\/]+\.md$')
ref_reads = 0; skills = []
# The session's opening event lists what it could see. A control arm that sees a crew- agent, skill, command or
# plugin is not a control: that is the leak a run on a machine with Crewforth as a user plugin produced.
init = None
def names(v):
    out = []
    for x in v or []:
        if isinstance(x, str): out.append(x)
        elif isinstance(x, dict) and isinstance(x.get('name'), str): out.append(x['name'])
    return out
try: lines = open(src, errors='replace').read().splitlines()
except OSError: lines = []
for ln, line in enumerate(lines):
    line = line.strip()
    if not line: continue
    try: e = json.loads(line)
    except Exception: bad += 1; continue
    if e.get('type') == 'assistant':
        m = e.get('message') or {}; nested = bool(e.get('parent_tool_use_id'))
        if m.get('id'): (msgs_nest if nested else msgs_top).add(m.get('id'))
        mkey = m.get('id') or ('line', ln)
        for c in m.get('content') or []:
            if not (isinstance(c, dict) and c.get('type') == 'tool_use') or c.get('id') in seen_tu: continue
            seen_tu.add(c.get('id')); k += 1
            if c.get('name') == 'Read' and REFRX.search(str((c.get('input') or {}).get('file_path') or '')): ref_reads += 1
            if c.get('name') == 'Skill': skills.append(str((c.get('input') or {}).get('skill') or '?').split(':')[-1])
            if c.get('name') in ('Agent', 'Task'):
                allc += 1
                if not nested:
                    top += 1
                    per_msg[mkey] = per_msg.get(mkey, 0) + 1
                    st = str((c.get('input') or {}).get('subagent_type') or 'general-purpose').split(':')[-1]
                    by_type[st] = by_type.get(st, 0) + 1
            elif c.get('name') in ('Edit', 'Write', 'MultiEdit', 'NotebookEdit'):
                edits += 1; last_edit = k
            elif c.get('name') == 'Bash' and RUNRX.search((c.get('input') or {}).get('command') or ''):
                tests += 1; last_test = k
                if nested: tnest += 1
    elif e.get('type') == 'system' and e.get('subtype') == 'init' and init is None:
        init = e
    elif e.get('type') == 'rate_limit_event':
        if (e.get('rate_limit_info') or {}).get('status') == 'rejected': limited = 1
    elif e.get('type') == 'result':
        res = e
open(txt, 'w').write((res or {}).get('result') or '')
# The main session's model is the one the pin is about; a crew agent may run on another by design, so every model
# the run used is reported beside it (column 25), not held to the pin.
mu = (res or {}).get('modelUsage') or {}
used = sorted(mu.keys())
# No model in the opening event: the one that wrote the most is the main session's (a background model writes little).
# Nothing to tell them apart by: say nothing rather than guess.
def out_tok(v): return (v or {}).get('outputTokens', 0) if isinstance(v, dict) else 0
if init and init.get('model'): served = [init['model']]
elif used and any(out_tok(mu[k]) for k in used): served = [max(used, key=lambda k: out_tok(mu[k]))]
else: served = []
seen = []
for key in ('agents', 'skills', 'slash_commands', 'plugins', 'tools', 'mcp_servers'):
    seen += names((init or {}).get(key))
# Crewforth by name: a crew- component, the plugin itself (`crewforth`, `crewforth:<x>`), or a 2.x name (`*-csk`).
# A user's own `crewforth-notes` or `my-crew-tool` is not Crewforth. A plugin is also caught by its install path.
CREW = re.compile(r'(^|[:/])crew-[a-z0-9-]+|(^|[:/])crewforth(:|$)|-csk$', re.I)
paths = [x.get('path') for x in ((init or {}).get('plugins') or []) if isinstance(x, dict) and isinstance(x.get('path'), str)]
leak = sorted({n for n in seen if CREW.search(n)} | {p for p in paths if re.search(r'[/\\]crewforth([/\\@]|$)', p, re.I)})
u = (res or {}).get('usage') or {}
sp = ((res or {}).get('subagent_stats') or {}).get('spawned', '')
print('\t'.join(str(x) for x in (top, allc, sp, (res or {}).get('total_cost_usd', ''), u.get('input_tokens', ''),
      u.get('output_tokens', ''), u.get('cache_read_input_tokens', ''), u.get('cache_creation_input_tokens', ''),
      (res or {}).get('num_turns', ''), bad, 1 if res else 0, tests, tnest, len(msgs_top), len(msgs_nest),
      1 if (res or {}).get('is_error') else 0, 1 if limited or (res or {}).get('api_error_status') == 429 else 0,
      '' if not edits else (1 if last_test > last_edit else 0),
      sum(1 for v in per_msg.values() if v >= 2), max(per_msg.values(), default=0),
      ','.join(f'{k}:{by_type[k]}' for k in sorted(by_type)) or '-',
      ','.join(served) or '-', len(seen) if init else '-', ','.join(leak[:8]) or '-', ','.join(used) or '-',
      '', k, ref_reads, ','.join(skills) or '-')))
PYM
}

# served_is REQUESTED SERVED — 0 when the main session's model answers the request. An alias (sonnet, opus, haiku,
# fable) matches an id that names that family; a full id must equal it (a `[1m]` context suffix aside).
served_is() {
  local want got
  want="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"; got="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
  want="${want%%\[*}"; got="${got%%\[*}"          # a context-size suffix ([1m]) is not another model
  [ -n "$got" ] && [ "$got" != "-" ] || return 1
  case "$want" in
    sonnet|opus|haiku|fable) case "$got" in *"$want"*) return 0 ;; esac; return 1 ;;
    *) case "$got" in "$want"|"$want"-*) return 0 ;; esac; return 1 ;;   # claude-sonnet-4-5 answers by claude-sonnet-4-5-20250929
  esac
}

run_arm() {
  local dir="$1" arm="$2"
  local env_prefix=""
  { [ "$arm" = kit ] || [ "$arm" = kitb ]; } && [ "${NEEDS_GIT_OK:-0}" = 1 ] && env_prefix="CLAUDE_GIT_OK=1"
  # Both arms run with the permission LAYER out of the way, deliberately. What is under test here is what the
  # kit does to the model's output — commit shape, how a credential is handled — not whether the approval
  # prompt fires; that is a permission-layer contract, unit-tested in smoke-test §7 where it can be asserted
  # exactly rather than inferred from a headless denial. Leaving the prompt in play measured neither: the kit
  # arm simply stopped every run with "denied at the permission layer", which grades the absence of a human,
  # not the presence of a discipline. The git-hook gates (trace, secret) are unaffected by permission mode and
  # still run — those ARE part of what is being measured.
  # `Task`/`Agent` are in the default tool list DELIBERATELY, and their absence was a real defect: without them the
# kit arm cannot delegate at all, so every result this harness produced measured the discipline TEXT with the agent
# layer switched off — while the kit's central claim is the agent layer. Both arms get them (a bare project has no
# agents, so it simply never uses them, and the arms stay identical in tool access).
# Override with CREW_EVAL_PERM if your environment refuses the default.
  # CREW_GATE_LOG turns on the hooks' write-only observability channel (see kit/hooks/guard-bash.sh).
  # It exists because "the model never reached for the command" and "the gate stopped it" leave behind IDENTICAL
  # artifacts: permission-pressure had to report "guard-bash never fired" as an inference, and that inference is
  # the difference between evidence for the always-on discipline TEXT and evidence for the GATE. Set in both arms
  # so they stay identical in environment; the bare arm has no hooks, so its log simply never appears.
  ( cd "$dir" || exit 1
    # One call shape for every run: the event stream carries the served model, the components the session saw at
    # start, delegation and tokens; the reply text is re-derived into .eval-stdout.txt for the graders.
    # CREW_EVAL_TRACE now only decides whether the trace summary is printed.
    printf '%s\n' "--model $EVAL_MODEL $ISO_FLAGS CLAUDE_CODE_DISABLE_AUTO_MEMORY=1" > "$dir/.eval-flags.txt"
    # shellcheck disable=SC2086  # ISO_FLAGS is a fixed list of words
    env $env_prefix CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 CREW_GATE_LOG="$dir/.eval-gates.log" claude -p "$PROMPT" \
        --model "$EVAL_MODEL" $ISO_FLAGS --output-format stream-json --verbose \
        --permission-mode "${CREW_EVAL_PERM:-bypassPermissions}" \
        --allowedTools ${CREW_EVAL_TOOLS:-Bash Read Write Edit Task Agent} \
        </dev/null >"$dir/.eval-stream.jsonl" 2>"$dir/.eval-stderr.txt" &
    _cpid=$!
    # STOP_WHEN / FORBID / MAX_TURNS (case.env): a watcher reads the stream as it is written and stops the run once the
    # case has its answer, did what it forbids, or ran past its ceiling. Without them, nothing watches and the run ends
    # on its own, as before. The reason, if any, is left in .eval-stop.txt for the runner.
    if [ -n "${STOP_WHEN:-}${FORBID:-}${MAX_TURNS:-}" ]; then
      STOP_WHEN="${STOP_WHEN:-}" FORBID="${FORBID:-}" MAX_TURNS="${MAX_TURNS:-}" \
        python3 "$ROOT/evals/lib/watch.py" "$dir/.eval-stream.jsonl" "$_cpid" "$dir/.eval-stop.txt" 2>/dev/null &
      _wpid=$!
      wait "$_cpid" 2>/dev/null; wait "$_wpid" 2>/dev/null
    else
      wait "$_cpid" 2>/dev/null
    fi
    eval_trace_metrics "$dir/.eval-stream.jsonl" "$dir/.eval-stdout.txt" > "$dir/.eval-metrics.tsv"
  ) || true   # a non-zero exit is itself a result; the grader decides
}

# Arms come from CREW_EVAL_ARMS (default "kit bare"). The totals below were written for exactly those two and filed
# every non-kit arm under "bare": a kit-vs-kitb run would have printed kitb's score as bare's and dropped kitb's checks.
ARMS="${CREW_EVAL_ARMS:-kit bare}"; ARM_A="${ARMS%% *}"; ARM_B=""; [ "$ARMS" != "$ARM_A" ] && ARM_B="${ARMS#* }"; ARM_B="${ARM_B%% *}"
printf '== kit A/B eval ==  model %s (requested) · %s · %s runs/arm · arms: %s\n' "$EVAL_MODEL" "$CLI" "$RUNS" "$ARMS"
printf '   isolation: %s · CLAUDE_CODE_DISABLE_AUTO_MEMORY=1\n' "$ISO_FLAGS"
[ -f "$HOME/.claude/CLAUDE.md" ] && printf '   ! ~/.claude/CLAUDE.md exists: whether it loads into both arms under these flags is not measured\n'
printf '\n'
MISMATCH=0; LEAKED=0; SERVED_IDS=
[ -d "$CASES" ] || { echo "run.sh: no cases under evals/cases" >&2; exit 1; }

# A NODE THE KIT FETCHED IS STILL A NODE. ensure-node.sh deliberately never edits PATH, so on a machine whose only Node
# came from it, `command -v node` finds nothing — measured on Windows 11 — and every case that REQUIRES node was
# skipped on every run, leaving the whole eval INCOMPLETE on exactly the machines the kit had equipped. So when node is
# not on PATH, ask the kit's own resolver, and put what it finds on PATH for THIS RUN ONLY: both arms and every grader
# see the same interpreter, the comparison stays fair, and nothing outside this process is changed. It is said out
# loud, because an eval whose environment differs from the shell that launched it should never do so silently.
if ! command -v node >/dev/null 2>&1; then
  _en="$ROOT/kit/studio/ensure-node.sh"
  if [ -f "$_en" ] && _node="$(bash "$_en" 2>/dev/null)" && [ -n "$_node" ] && [ -x "$_node" ]; then
    PATH="$(dirname "$_node"):$PATH"; export PATH
    printf '   node is not on PATH; using the kit-fetched runtime for this run only: %s\n\n' "$_node"
  fi
fi

TOTAL_KIT=0; TOTAL_BARE=0; TOTAL_CHECKS=0; TOTAL_CHECKS_B=0; NOT_MEASURED=0; LIMITED=0; SKIPPED=0
for cdir in "$CASES"/*/; do
  [ "$LIMITED" = 1 ] && break
  cname="$(basename "$cdir")"
  [ -n "$ONLY" ] && [ "$ONLY" != "$cname" ] && continue
  [ -f "$cdir/case.env" ] && [ -f "$cdir/grade.sh" ] || { echo "run.sh: $cname is missing case.env or grade.sh" >&2; exit 1; }

  # shellcheck disable=SC1090
  NEEDS_GIT_OK=0; REQUIRES=""; NEEDS_OVERLAY_B=0; STOP_WHEN=""; FORBID=""; MAX_TURNS=""; unset -f seed post_seed 2>/dev/null; . "$cdir/case.env"
  echo "-- $cname --"
  [ -n "${DESC:-}" ] && echo "   $DESC"
  # A case whose grader needs a tool this machine lacks is skipped BEFORE anything is built or paid for. Run anyway, it
  # fails in every arm for a reason that has nothing to do with the kit, and a tie of failures reads like a result.
  # shellcheck disable=SC2086
  missing="$(req_missing $REQUIRES)"
  if [ -n "$missing" ]; then
    printf '   ! SKIPPED, NOT MEASURED — needs%s, not on this machine; nothing was built or run\n\n' "$missing"
    SKIPPED=$((SKIPPED+1)); continue
  fi

  # A CASE MAY DECLARE THAT ARM B IS INCOMPLETE WITHOUT AN OVERLAY, and the three high-risk cases do. The rule
  # they measure — the applicable audits are issued together — lives in TWO places: the discipline file and the
  # agents' own Coordination sections. `CREW_EVAL_DISCIPLINE_B` replaces the first; `CREW_EVAL_OVERLAY_B` the
  # second, and it is optional. Run arm B with only the first and it carries the new text beside the OLD agent
  # files: the rule is half applied, the arms differ in more than one thing, and the experiment reports a
  # number for a question nobody asked. The runner cannot know which cases care, so the case says so — the
  # same shape as REQUIRES, and refused BEFORE anything is built or paid for rather than noticed afterwards.
  if [ "${NEEDS_OVERLAY_B:-0}" = 1 ] && [ -z "${CREW_EVAL_OVERLAY_B:-}" ]; then
    case " $ARMS " in
      *" kitb "*)
        echo "run.sh: $cname declares NEEDS_OVERLAY_B=1 and arm kitb has no CREW_EVAL_OVERLAY_B." >&2
        echo "  The rule this case measures lives in the agent files too, so arm B would carry the new" >&2
        echo "  discipline text with the old agents and measure something else. Set CREW_EVAL_OVERLAY_B to a" >&2
        echo "  directory of agent files, or drop kitb from CREW_EVAL_ARMS for this case." >&2
        exit 1 ;;
    esac
  fi

  for arm in $ARMS; do
    [ "$LIMITED" = 1 ] && break
    passed=0; checks=0; detail=""; gates=""; arm_nm=0; arm_graded=0
    for r in $(seq 1 "$RUNS"); do
      [ "$LIMITED" = 1 ] && break
      P="$WORK/$cname-$arm-$r"
      # A failed install must never degrade into "the kit arm behaved like the bare one" — that is the single
      # result this harness could produce that looks like a finding and is actually a bug in itself.
      build_project "$P" "$arm" || { echo "run.sh: could not build $cname/$arm run $r — aborting" >&2; exit 1; }
      run_arm "$P" "$arm"
      # An arm that could not use its tools produces the same shape of result as an arm that chose not to act,
      # and the second reads like a finding. Surface the environment instead of scoring it.
      # SCOPE, MEASURED (2026-07-31), because the earlier wording was broad enough to make every result under it
      # look doubtful. An untrusted workspace drops `permissions.allow` entries AND NOTHING ELSE: a probe project
      # carrying both an allow entry and a PreToolUse hook produced this exact warning, and the hook still ran and
      # still returned exit 2 (the tool did not execute). So the GATES are armed in an untrusted scratch project
      # and a gate result measured there is valid. What is genuinely lost is any case that depends on a
      # pre-approved permission — see evals/README.md on commit-format and secret-refused.
      # Said once: a project that already fell back to `git init` was reported, with its cause, when it was built.
      if [ "$EVFELL" = 0 ] && { [ "$arm" = kit ] || [ "$arm" = kitb ]; } && grep -q "has not been trusted" "$P/.eval-stderr.txt" 2>/dev/null; then
        eval_untrusted "the CLI reported this project as not trusted" "$P" || exit 4
      fi
      # A run that never happened must not be graded. A usage-limit rejection leaves the seed project untouched, and an
      # untouched project passes every "was not changed" check: measured: the seven rejected runs scored 13 checks between them. So a run is
      # graded only on evidence that it ran. In trace mode that is a result that is neither an error nor limited. Without the
      # stream it is a reply that is not the limit message, in the one form seen so far, the result text of a rejected run:
      # "You've hit your session limit · resets …".
      nm=""; fclass="harness"
      m_has=""; m_err=""; m_lim=""; m_srv=""; m_seen=""; m_leak=""; m_calls=""
      IFS=$'\t' read -r m_has m_err m_lim m_srv m_seen m_leak m_calls < <(LC_ALL=C awk -F'\t' '{print ($11==""?0:$11) "\t" ($16==""?0:$16) "\t" ($17==""?0:$17) "\t" $22 "\t" $23 "\t" $24 "\t" ($27==""?0:$27)}' "$P/.eval-metrics.tsv" 2>/dev/null)
      stopw=""; [ -s "$P/.eval-stop.txt" ] && IFS= read -r stopw < "$P/.eval-stop.txt"
      # A run the watcher stopped has no result event. `stop` and `forbid` were stopped on purpose and are graded on
      # what they left; past MAX_TURNS the run is unfinished, so it is not graded, and its class says why.
      case "$stopw" in stop\ *|forbid\ *) m_has=1 ;; maxturns\ *) nm="stopped past MAX_TURNS ($stopw)"; fclass="timeout" ;; esac
      if [ -n "$nm" ]; then :
      elif [ "${m_has:-0}" != 1 ]; then nm="the stream is empty or broken"
      elif [ "${m_err:-0}" = 1 ] || [ "${m_lim:-0}" = 1 ]; then
        nm="the run ended in an error or hit the usage limit: $(head -1 "$P/.eval-stdout.txt" 2>/dev/null | cut -c1-160)"
      fi
      [ "${m_lim:-0}" = 1 ] && LIMITED=1
      # The comparison holds only if the run was served the model asked for, and the control could not see the kit.
      case " $SERVED_IDS " in *" ${m_srv:--} "*) ;; *) SERVED_IDS="$SERVED_IDS ${m_srv:--}" ;; esac
      if [ -z "$nm" ] && ! served_is "$EVAL_MODEL" "$m_srv"; then
        MISMATCH=$((MISMATCH+1)); nm="asked for model $EVAL_MODEL, the stream says it was served ${m_srv:-nothing}"
      fi
      if [ -z "$nm" ] && [ "$arm" != kit ] && [ "$arm" != kitb ]; then
        if [ -z "$m_seen" ] || [ "$m_seen" = "-" ]; then nm="the stream has no init event, so the control arm cannot be shown clean"
        elif [ -n "$m_leak" ] && [ "$m_leak" != "-" ]; then LEAKED=$((LEAKED+1)); nm="the control arm could see Crewforth components: $m_leak"; fi
      fi
      if [ -n "$nm" ]; then
        NOT_MEASURED=$((NOT_MEASURED+1)); arm_nm=$((arm_nm+1))
        printf '   ! %s run %s NOT MEASURED, not graded — %s · class %s\n' "$arm" "$r" "$nm" "$fclass"
        # Marked in column 26, so the trace summary leaves it out like an empty stream: a run that was not graded
        # must not lend its cost or its delegations to the arm's figures.
        [ -s "$P/.eval-metrics.tsv" ] && LC_ALL=C awk -F'\t' -v OFS='\t' '{ $26 = "rejected"; print }' "$P/.eval-metrics.tsv" >> "$WORK/trace-$cname-$arm.tsv"
        [ "$LIMITED" = 1 ] && { printf '   ! usage limit reached — no further run is started\n'; break; }
        continue
      fi
      arm_graded=$((arm_graded+1))
      # KIT_ROOT lets a grader reuse the kit's own pattern files. It must come from the RUNNER, not be
      # discovered inside the project: the bare arm has no .claude/, so a grader that looked there would score
      # "cannot grade" as a failure and quietly penalise the arm for being the control.
      out="$( cd "$P" && KIT_ROOT="$ROOT" EVAL_SECRET="${EVAL_SECRET:-}" bash "$cdir/grade.sh" 2>/dev/null )"
      case "$stopw" in forbid\ *) out="$(printf '%s\nFAIL the run did what the case forbids (%s)' "$out" "${stopw#forbid }")" ;; esac
      # A grader that could not take its measurement says so with a NOT_MEASURED line instead of scoring. Without this
      # protocol it had only PASS and FAIL to choose from, and a missing interpreter came out as a FAIL — measured, a
      # grader reported "the suite was weakened" when nothing had been touched and node simply could not run. A run
      # the grader could not read is not a result, so it is counted exactly like one that never happened.
      if printf '%s\n' "$out" | grep -q '^NOT_MEASURED '; then
        NOT_MEASURED=$((NOT_MEASURED+1)); arm_nm=$((arm_nm+1)); arm_graded=$((arm_graded-1))
        printf '   ! %s run %s NOT MEASURED by its grader — %s\n' "$arm" "$r" "$(printf '%s\n' "$out" | sed -n 's/^NOT_MEASURED //p' | head -1)"
        continue
      fi
      # FAILURE CLASS of a graded run that failed a check: `refusal` when it made no tool call at all (it answered and
      # stopped), `genuine` otherwise. Not-graded runs carry theirs on the NOT MEASURED line (harness / timeout).
      _nf="$(printf '%s\n' "$out" | grep -c '^FAIL ')"
      if [ "$_nf" -gt 0 ]; then
        if [ "${m_calls:-0}" = 0 ]; then fclass=refusal; else fclass=genuine; fi
        printf '   · %s run %s: %s FAIL · class %s%s\n' "$arm" "$r" "$_nf" "$fclass" "${stopw:+ · watcher: $stopw}"
      fi
      checks=$(( checks + $(printf '%s\n' "$out" | grep -c '^\(PASS\|FAIL\) ') ))
      passed=$(( passed + $(printf '%s\n' "$out" | grep -c '^PASS ') ))
      # Every run's lines are kept, not just the first. With --runs 3 the totals are the only thing that
      # matters and a single sample cannot explain them: a 7/9 against a 9/9 is unreadable without knowing
      # WHICH check failed and how often.
      detail="$(printf '%s\n%s' "$detail" "$out")"
      # REPORTED, NEVER SCORED. A channel only the kit arm can produce cannot enter the denominator without
      # handing the kit points the control is structurally unable to earn — the same bias that had to be fixed
      # in adr-recorded and no-secret-logging. It answers a different question from the grade: WHO produced the
      # outcome. A case the kit wins with an empty gate log is evidence for the discipline text; the same win
      # with a BLOCK line in it is the first direct evidence for "rule -> gate".
      [ -s "$P/.eval-gates.log" ] && gates="$(printf '%s\n%s' "$gates" "$(cut -f1,2,3 "$P/.eval-gates.log")")"
      # A run the watcher stopped on purpose has no result event; it was graded, so its trace row counts as one.
      if [ -s "$P/.eval-metrics.tsv" ]; then
        case "$stopw" in stop\ *|forbid\ *) LC_ALL=C awk -F'\t' -v OFS='\t' '{ $11 = 1; print }' "$P/.eval-metrics.tsv" >> "$WORK/trace-$cname-$arm.tsv" ;;
          *) cat "$P/.eval-metrics.tsv" >> "$WORK/trace-$cname-$arm.tsv" ;; esac
      fi
    done
    if [ "${CREW_EVAL_TRACE:-0}" = 1 ]; then
      LC_ALL=C awk -F'\t' -v arm="$arm" -v cname="$cname" '
        { n++; if ($11 != 1 || $16 == 1 || $17 == 1 || $26 == "rejected") { empty++; next } ok++; if ($1 > 0) deleg++; cost += $4; tin += $5; tout += $6; cr += $7; cc += $8; tst += $12; tsn += $13; ttop += $14; tnst += $15; refs += $28
          if ($21 != "" && $21 != "-") { m = split($21, kv, ","); for (i = 1; i <= m; i++) { split(kv[i], p, ":"); bt[p[1]] += p[2] } }
          if ($21 ~ /(^|,)crew-commit-agent:/) cagent++ }
        END {
          if (n == 0) { printf "     trace %-5s NO TRACE FILE — the runs wrote no metrics; this measured nothing\n", arm; exit }
          printf "     trace %-5s delegated %d/%d · cost $%.3f · in %d out %d cache_read %d cache_create %d · test runs %d (nested %d) · turns %d (nested %d)", arm, deleg, ok, cost, tin, tout, cr, cc, tst, tsn, ttop, tnst
          printf " · references read %d", refs
          if (empty) printf " · %d run(s) not graded (empty, error, limit, wrong model or leaked control), not counted", empty
          printf "\n"
          s = ""; for (k in bt) s = s (s == "" ? "" : ", ") k " " bt[k]
          if (s != "") printf "     agents %-5s %s\n", arm, s
          # A report, not a grade: the case grades the commit; this says whether the agent that owns the message wrote it.
          if (cname == "commit-format") printf "     agents %-5s crew-commit-agent ran in %d of %d run(s)\n", arm, cagent, ok
        }' "$WORK/trace-$cname-$arm.tsv" 2>/dev/null || printf '     trace %-5s NO TRACE FILE — the runs wrote no metrics; this measured nothing\n' "$arm"
    fi
    if [ "$arm" = "$ARM_A" ]; then TOTAL_KIT=$((TOTAL_KIT+passed)); TOTAL_CHECKS=$((TOTAL_CHECKS+checks));
    elif [ "$arm" = "$ARM_B" ]; then TOTAL_BARE=$((TOTAL_BARE+passed)); TOTAL_CHECKS_B=$((TOTAL_CHECKS_B+checks)); fi
    printf '   %-5s %s/%s checks' "$arm" "$passed" "$checks"
    if [ "$arm_graded" -lt "$RUNS" ]; then printf ' (%s of %s runs graded · %s NOT MEASURED)' "$arm_graded" "$RUNS" "$arm_nm"
    elif [ "$RUNS" -gt 1 ]; then printf ' (over %s runs)' "$RUNS"; fi
    printf '\n'
    # Tally each distinct check across the runs instead of printing them N times.
    printf '%s\n' "$detail" | grep -E '^(PASS|FAIL) ' \
      | awk '{v=$1; $1=""; c[$0]=c[$0]; if(v=="PASS") p[$0]++; n[$0]++}
             END{for(k in n) printf "         %s/%s %s\n", p[k]+0, n[k], substr(k,2)}' | sort -t/ -k1,1n
    # Diagnosis line, printed outside the score. "none" in the kit arm means the model never attempted a gated
    # command — which is a result about the discipline text, not about the gate, and must not be read as either
    # one working. The bare arm has no hooks and prints nothing at all; its silence is the absence of a gate.
    if [ "$arm" != bare ]; then
      if [ -n "$gates" ]; then
        printf '         gates fired:\n'
        printf '%s\n' "$gates" | grep -E '^(BLOCK|ASK|ALLOW)' | sort | uniq -c \
          | awk '{c=$1; $1=""; printf "           %sx%s\n", c, $0}'
      else
        printf '         gates fired: none — no gated command was attempted in any run\n'
      fi
    fi
  done
  echo
done

echo "== summary =="
printf '   %-4s %s/%s\n' "$ARM_A" "$TOTAL_KIT" "$TOTAL_CHECKS"
[ -n "$ARM_B" ] && printf '   %-4s %s/%s\n' "$ARM_B" "$TOTAL_BARE" "$TOTAL_CHECKS_B"
if [ -n "$ARM_B" ] && [ "$TOTAL_CHECKS" -gt 0 ] && [ "$NOT_MEASURED" = 0 ] && [ "$LIMITED" = 0 ] && [ "$SKIPPED" = 0 ]; then
  printf '   delta %s - %s: %+d checks\n' "$ARM_A" "$ARM_B" "$((TOTAL_KIT - TOTAL_BARE))"
  [ "$ARM_B" = bare ] && [ "$TOTAL_KIT" -le "$TOTAL_BARE" ] && \
    echo "   NOTE: the kit did not come out ahead. Report that as it stands — a harness that only publishes"
  [ "$ARM_B" = bare ] && [ "$TOTAL_KIT" -le "$TOTAL_BARE" ] && \
    echo "         favourable runs measures nothing."
fi
[ "$RUNS" = 1 ] && echo "   n=1: one run per arm is an anecdote, not a rate. Use --runs 3+ before quoting a number."
# An alias pins a family, not a version: two ids here mean the arms may not have run the same model.
printf '   served:%s\n' "${SERVED_IDS:- none}"
[ "$(printf '%s\n' $SERVED_IDS | grep -c .)" -gt 1 ] && printf '   ! more than one model id was served in this run: compare the arms per row before reading the delta\n'
[ "$MISMATCH" -gt 0 ] && printf '   MODEL MISMATCH: %s run(s) were served a model other than %s — not graded.\n' "$MISMATCH" "$EVAL_MODEL"
[ "$LEAKED" -gt 0 ] && printf '   CONTROL LEAK: %s control-arm run(s) could see a Crewforth component — not graded.\n' "$LEAKED"
if [ "$NOT_MEASURED" -gt 0 ] || [ "$LIMITED" = 1 ] || [ "$SKIPPED" -gt 0 ]; then
  printf '   INCOMPLETE: %s run(s) NOT MEASURED%s%s. The totals above are not a result.\n' "$NOT_MEASURED" \
    "$([ "$SKIPPED" -gt 0 ] && echo ", $SKIPPED case(s) SKIPPED for a missing tool")" \
    "$([ "$LIMITED" = 1 ] && echo ', and the usage limit stopped every later run before it started')"
  exit 3
fi
exit 0
