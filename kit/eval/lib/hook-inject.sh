#!/usr/bin/env bash
# What the hooks wired on UserPromptSubmit and SessionStart put into the model's context, in bytes. One definition:
# doctor prints it (4c), smoke-test.sh pins a budget on it. Run from anywhere:
#
#   bash .claude/eval/lib/hook-inject.sh [PROJECT_ROOT]
#
# Prints tab-separated lines, nothing else on stdout:
#   run    <event> <hook> <bytes> <rc>      a hook that was run; bytes = what Claude Code would inject (0 when rc != 0)
#   skip   <event> <hook> <reason-key>      a hook that was NOT run, and why (keys: see the table below)
#   total  <event> <bytes> <hooks run>
#   prompt <the fixture prompt>
#
# WHY IT IS RUN AND NOT READ. A hook's injection depends on the project (route-hint matches the prompt against the
# installed agents, board-sync prints the cached board, context-usage the fill), so reading the scripts cannot give a
# number; running them on a fixture payload can. The number is therefore A FLOOR FOR THIS FIXTURE, not a maximum: a
# hook that speaks only for some prompts or states (an approval, an update, a compaction) prints nothing here.
#
# WHAT "INJECT" MEANS. For both events Claude Code adds a hook's stdout to the context on exit 0, or, when stdout is a
# JSON object, its hookSpecificOutput.additionalContext (a systemMessage goes to the user, not the model). That is
# what is counted: the decoded bytes of additionalContext, or the plain stdout. NOT counted (not measured here): the
# framing Claude Code puts around each injection.
#
# NO LASTING SIDE EFFECT. Every hook runs with a throwaway HOME, TMPDIR, XDG_CACHE_HOME and CLAUDE_CONFIG_DIR, a
# fixture transcript, and a session id no real session has (real ones are UUIDs). What each Crewforth hook writes was
# read from its source (grep for `> "`, `mkdir`, `.claude/state`) and each is placed in one of three rows:
#   read-only for these payloads ............ run against the project (route-hint, session-rehydrate, skill-trust,
#     branch-fresh with CREW_BRANCH_FRESH_FETCH=off: no fetch; its merge-tree check leaves only unreachable objects)
#   writes only under TMPDIR ................ run against the project, TMPDIR thrown away (context-usage)
#   board-sync: its detached half fetches over the network when the cache is stale; CREW_BOARD_MAX_AGE[_NOBOARD]
#     set beyond any age keeps it on the cached read, which writes nothing
#   prompt-approval: EVERY user message empties a recorded approval in the worktree's git directory and the
#     question's state in .claude/state, so it runs with the project dir and cwd on a scratch folder outside any
#     repository. For a prompt that is not an approval it prints nothing wherever it runs (read from its source).
#   writes into the project, cannot be redirected -> not run, said so:
#     agent-outcome (SessionStart rewrites .claude/state/crew-critical-paths.auto),
#     session-update-check (writes .claude/.state/update-asked, which silences the real question for a day, and
#     starts a network refresh)
# A hook not in this table (the project's own, or a Crewforth hook added later) is not run: nothing has checked
# what it writes. smoke-test.sh fails when a hook Crewforth wires on these events is missing from the table.
#
# Process cost: two awk per hook and a handful for the wiring, never one per line (Git Bash: 20-130 ms a process).
set -uo pipefail
export LC_ALL=C   # bytes, not characters: length() in awk and the shell both count bytes under C

_hi_d="${BASH_SOURCE[0]//\\//}"; _hi_d="${_hi_d%/*}"; [ "$_hi_d" = "${BASH_SOURCE[0]//\\//}" ] && _hi_d=.
_hi_d="$(cd "$_hi_d" 2>/dev/null && pwd)" || _hi_d=.   # absolute: the script cd's into ROOT below
SJ="$_hi_d/settings-json.awk"
ROOT="${1:-.}"
cd "$ROOT" 2>/dev/null || { echo "hook-inject: cannot enter '$ROOT'" >&2; exit 2; }
S=.claude/settings.json
[ -f "$SJ" ] || { echo "hook-inject: Crewforth's JSON reader is missing ($SJ)" >&2; exit 2; }
[ -f "$S" ] || { echo "hook-inject: no $S" >&2; exit 2; }
awk -v op=validate -f "$SJ" "$S" 2>/dev/null || { echo "hook-inject: $S is not valid JSON" >&2; exit 2; }

PROMPT="write unit tests for the payment service"
SID="crew-inject-probe-$$-${RANDOM:-0}"
GCG="${GIT_CONFIG_GLOBAL:-${HOME:-}/.gitconfig}"

# CREW_INJECT_SCRATCH: a folder to use and KEEP (smoke reads it back to prove the redirection happened). Otherwise a
# fresh one, removed on exit.
if [ -n "${CREW_INJECT_SCRATCH:-}" ]; then T="$CREW_INJECT_SCRATCH"; mkdir -p "$T" || exit 2
else T="$(mktemp -d 2>/dev/null)" || { echo "hook-inject: no scratch folder" >&2; exit 2; }; trap 'rm -rf "$T"' EXIT; fi
mkdir -p "$T/home/.claude" "$T/tmp" "$T/cache" "$T/proj" || exit 2

# A JSON string body for a path: backslash and quote escaped (a Windows path or an odd folder name).
_js(){ local s="${1//\\/\\\\}"; _JSV="${s//\"/\\\"}"; }
_js "$PWD"; PJ="$_JSV"; _js "$T/proj"; SCJ="$_JSV"; _js "$T/transcript.jsonl"; TJ="$_JSV"

# The fixture transcript: one assistant turn with usage, the record context-usage reads (2% of a 1M window).
printf '%s\n' '{"type":"assistant","message":{"role":"assistant","model":"claude-fixture","usage":{"input_tokens":100,"cache_read_input_tokens":20000,"cache_creation_input_tokens":0,"output_tokens":10}}}' > "$T/transcript.jsonl"
printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","permission_mode":"default","hook_event_name":"UserPromptSubmit","prompt":"%s"}\n' "$SID" "$TJ" "$PJ" "$PROMPT" > "$T/ups.json"
printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","permission_mode":"default","hook_event_name":"UserPromptSubmit","prompt":"%s"}\n' "$SID" "$TJ" "$SCJ" "$PROMPT" > "$T/ups-scratch.json"
printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","hook_event_name":"SessionStart","source":"startup"}\n' "$SID" "$TJ" "$PJ" > "$T/ss.json"

# prompt-approval's scratch folder must not sit inside a repository: its record lives in the enclosing git directory.
SCRATCH_OK=1; git -C "$T/proj" rev-parse --git-dir >/dev/null 2>&1 && SCRATCH_OK=0

# The decoded byte length of a JSON string token (quotes included in the input), or of plain text. One awk per hook.
#   \\ and the one-letter escapes are one byte; \uXXXX is the UTF-8 length of that code point (a surrogate half 2,
#   so a pair is 4). In C locale length() counts bytes, so raw UTF-8 in the string is counted as it will be sent.
DEC='
function hx(h,  i, v) { v = 0; h = tolower(h); for (i = 1; i <= 4; i++) v = v * 16 + index("0123456789abcdef", substr(h, i, 1)) - 1; return v }
{ buf = buf (NR > 1 ? "\n" : "") $0 }
END {
  if (mode == "plain") { print length(buf) + (NR > 0 ? 1 : 0); exit }
  s = buf; sub(/^[[:space:]]*"/, "", s); sub(/"[[:space:]]*$/, "", s)
  gsub(/\\\\/, "B", s)
  while (match(s, /\\u[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]/)) {
    v = hx(substr(s, RSTART + 2, 4)); k = (v < 128 ? 1 : (v < 2048 ? 2 : ((v >= 55296 && v <= 57343) ? 2 : 3)))
    r = substr("UUU", 1, k); s = substr(s, 1, RSTART - 1) r substr(s, RSTART + 6)
  }
  gsub(/\\./, "E", s)
  print length(s)
}'

measure(){  # $1 = event, $2 = hook file name -> one run/skip line; adds to TOT_* and RUN_*
  local ev="$1" h="$2" pl proj="$PWD" rc n ac
  case "$ev" in UserPromptSubmit) pl="$T/ups.json" ;; *) pl="$T/ss.json" ;; esac
  case "$h" in
    context-usage.sh|route-hint.sh|session-rehydrate.sh|skill-trust.sh|board-sync.sh|branch-fresh.sh) ;;
    prompt-approval.sh)
      [ "$SCRATCH_OK" = 1 ] || { printf 'skip\t%s\t%s\t%s\n' "$ev" "$h" scratch-in-repo; return 0; }
      proj="$T/proj"; pl="$T/ups-scratch.json" ;;
    agent-outcome.sh)        printf 'skip\t%s\t%s\t%s\n' "$ev" "$h" writes-state; return 0 ;;
    session-update-check.sh) printf 'skip\t%s\t%s\t%s\n' "$ev" "$h" writes-update; return 0 ;;
    *)                       printf 'skip\t%s\t%s\t%s\n' "$ev" "$h" unchecked; return 0 ;;
  esac
  [ -f ".claude/hooks/$h" ] || { printf 'skip\t%s\t%s\t%s\n' "$ev" "$h" missing; return 0; }
  # Launched the way settings.json launches it (`bash .claude/hooks/<name>` from the project root): context-usage
  # compares its own $0 with that spelling and warns about stale wiring when they differ. git keeps reading the
  # user's own global config (GIT_CONFIG_GLOBAL, git 2.32+): session-rehydrate's answer depends on core.hooksPath.
  GIT_CONFIG_GLOBAL="$GCG" HOME="$T/home" TMPDIR="$T/tmp" XDG_CACHE_HOME="$T/cache" CLAUDE_CONFIG_DIR="$T/home/.claude" \
  CLAUDE_PROJECT_DIR="$proj" CLAUDE_PLUGIN_ROOT="" CREW_BOARD_MAX_AGE=999999999999 CREW_BOARD_MAX_AGE_NOBOARD=999999999999 CREW_BRANCH_FRESH_FETCH=off \
    bash ".claude/hooks/$h" < "$pl" > "$T/out" 2>/dev/null
  rc=$?
  n=0
  if [ "$rc" = 0 ] && [ -s "$T/out" ]; then
    awk -v op=get -v path=hookSpecificOutput.additionalContext -f "$SJ" "$T/out" > "$T/ac" 2>/dev/null
    case $? in
      0)  n="$(awk -v mode=json "$DEC" "$T/ac")" ;;
      10) n="$(awk -v mode=plain "$DEC" "$T/out")" ;;   # not a JSON object: Claude Code injects the text as it is
      *)  n=0 ;;                                         # a JSON object with no additionalContext: nothing reaches the model
    esac
  fi
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf 'run\t%s\t%s\t%s\t%s\n' "$ev" "$h" "$n" "$rc"
  case "$ev" in UserPromptSubmit) TOT_U=$((TOT_U + n)); RUN_U=$((RUN_U + 1)) ;; *) TOT_S=$((TOT_S + n)); RUN_S=$((RUN_S + 1)) ;; esac
}

TOT_U=0; RUN_U=0; TOT_S=0; RUN_S=0
printf 'prompt\t%s\n' "$PROMPT"
for ev in UserPromptSubmit SessionStart; do
  ne="$(awk -v op=len -v path="hooks.$ev" -f "$SJ" "$S" 2>/dev/null)"; case "$ne" in ''|*[!0-9]*) ne=0 ;; esac
  i=0
  while [ "$i" -lt "$ne" ]; do
    nh="$(awk -v op=len -v path="hooks.$ev.$i.hooks" -f "$SJ" "$S" 2>/dev/null)"; case "$nh" in ''|*[!0-9]*) nh=0 ;; esac
    j=0
    while [ "$j" -lt "$nh" ]; do
      c="$(awk -v op=get -v path="hooks.$ev.$i.hooks.$j.command" -f "$SJ" "$S" 2>/dev/null)" || c=""
      r="${c#*bash .claude/hooks/}"
      if [ "$r" != "$c" ]; then
        r="${r%\"}"
        case "$r" in *.sh) case "$r" in *[!A-Za-z0-9._-]*) r="" ;; esac ;; *) r="" ;; esac
      else r=""; fi
      if [ -n "$r" ]; then measure "$ev" "$r"
      else
        # Not one of Crewforth's: named by its last word only (no path, no argument is printed).
        f="${c%\"}"; f="${f//\\//}"; f="${f##*[ /]}"; f="${f//[!A-Za-z0-9._-]/}"
        printf 'skip\t%s\t%s\t%s\n' "$ev" "${f:-hook}" unchecked
      fi
      j=$((j + 1))
    done
    i=$((i + 1))
  done
done
printf 'total\tUserPromptSubmit\t%s\t%s\n' "$TOT_U" "$RUN_U"
printf 'total\tSessionStart\t%s\t%s\n' "$TOT_S" "$RUN_S"
exit 0
