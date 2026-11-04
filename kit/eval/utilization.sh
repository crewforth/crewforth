#!/usr/bin/env bash
# What Crewforth LOADS versus what it actually FIRES.
#
# Every installed skill spends its name and description in EVERY session's skill listing, forever, whether or not
# it is ever used. doctor.sh §4a already measures the loaded half and reports it against the budget. This
# measures the other half, because the documented remedy for an over-budget listing — setting rarely-used skills
# to "name-only" in skillOverrides — needs a list of WHICH skills, and nothing produced one. A cold skill is not
# automatically a bad skill (an incident runbook earns its keep by existing), so this REPORTS and never enforces.
#
# Usage:  bash utilization.sh [--all-projects]
#         bash utilization.sh --tools     tools and MCP servers available in >= N sessions and never called
#                                         (N = CREW_TOOLS_MIN_SESSIONS, default 5): a deny PROPOSAL, nothing written
# Exit:   0 always. Measuring context cost must never fail a build.
#
# PRIVACY (§4.3): the current project only, unless --all-projects is asked for explicitly. What is printed is
# skill NAMES and COUNTS — never a path, never the encoded project directory, never a prompt or a file content.
# Nothing is written anywhere; this script only reads.
set -uo pipefail

ALL=0; TOOLS=0
case "${1:-}" in
  --all-projects) ALL=1 ;;
  --tools) TOOLS=1 ;;
  ""|--help|-h) [ "${1:-}" != "" ] && { sed -n '2,14p' "$0"; exit 0; } ;;
esac

# Where the skills live: an installed project, or this repo's payload when run from Crewforth's own checkout.
SKILLS=""; OWNREPO=0
for d in .claude/skills kit/skills; do [ -d "$d" ] && { SKILLS="$d"; break; }; done
[ "$SKILLS" = "kit/skills" ] && OWNREPO=1
if [ -z "$SKILLS" ] && [ "$TOOLS" = 0 ]; then echo "utilization: no skills directory here (looked for .claude/skills)"; exit 0; fi

TR=""
# ---- CREW-TRANSCRIPT-DIR (kept byte-identical in context-usage.sh and session-stats.sh; smoke-test §6i3 pins it)
# Claude Code stores a session under $HOME/.claude/projects/<cwd encoded as a directory name>. Reproducing that
# encoding is the ONLY way a by-hand call (no hook payload on stdin) can find its own transcript.
crew_project_dirs(){   # candidate directory names for the current cwd, best first, one per line
  local w p
  # Windows first. Claude Code sees the NATIVE cwd (C:\repo\app) while Git Bash's `pwd` reports /c/repo/app, so
  # the drive letter never matched and the by-hand call could not resolve a transcript on Windows AT ALL — the
  # same "transcript not found" was reported from that machine three separate times before the cause was found.
  # `pwd -W` is the MSYS builtin that returns the native form; elsewhere it just fails and is discarded.
  w="$(pwd -W 2>/dev/null || true)"
  # The encoder folds : \ / . AND _ to '-'. The underscore is the one that hides: a project named `report_api`
  # lands in `...-report-api`, so folding only slashes and dots misses every path containing an underscore — on
  # every platform, not just Windows.
  for p in "$w" "$(pwd)"; do
    [ -n "$p" ] && printf '%s\n' "$(printf '%s' "$p" | sed 's#[:\\/._]#-#g')"
  done
  # Legacy shapes, kept so a directory written by an older client still resolves.
  printf '%s\n' "$(pwd | sed 's#[/.]#-#g')" "$(pwd | sed 's#/#-#g')"
}
if [ -z "$TR" ]; then
  while IFS= read -r esc; do
    [ -n "$esc" ] || continue
    cand="$(ls -t "$HOME/.claude/projects/$esc"/*.jsonl 2>/dev/null | head -1)"
    [ -n "$cand" ] && { TR="$cand"; break; }
  done <<CREWEOF
$(crew_project_dirs)
CREWEOF
fi
# ---- /CREW-TRANSCRIPT-DIR

# THE TRANSCRIPTS ARE NOT ONE FILE, AND THAT IS THE WHOLE MEASUREMENT. A project directory holds
# <session>.jsonl at the top AND a <session>/ directory per session whose subagents/ tree carries one transcript
# per delegated agent. Measured on this machine while writing this: 14 transcripts at the top level, 306 nested.
# A parser that reads only the top level therefore misses most of the work — and delegated agents are precisely
# where skills fire, because that is what they are delegated with. Counting only the top level reported 2 of 40
# skills as used; counting the tree reported 21. The difference is not a rounding error, it is the answer.
if [ "$ALL" = 1 ]; then
  DIRS="$HOME/.claude/projects"
  [ -d "$DIRS" ] || { echo "utilization: NOT MEASURED — no transcripts directory"; exit 0; }
  SCOPE="all projects"
else
  [ -n "$TR" ] || { echo "utilization: NOT MEASURED — no transcript found for this project."
                    echo "  (a fresh checkout, a first session, or a project directory the encoder cannot reproduce)"
                    echo "  NOT MEASURED is not the same as 'nothing fired'; it means nothing was read."; exit 0; }
  DIRS="$(dirname "$TR")"
  SCOPE="this project"
fi

# ---- --tools: what a session HAD versus what it CALLED -----------------------------------------------------------
# Every tool a session has costs its definition in the prompt; a tool or MCP server nothing ever calls is pure cost.
# WHERE AVAILABILITY IS RECORDED (read from real transcripts, Claude Code 2.1.308, 2026-11-04): an attachment
#   {"type":"deferred_tools_delta","addedNames":["EnterWorktree",…,"mcp__<server>__<tool>",…],"removedNames":[…],…}
# lists the DEFERRED tools (the ones loaded by name on demand) as they become available. Tools loaded up front
# (Bash, Read, Edit, Agent, …) and an MCP server whose tools are not deferred are NOT recorded anywhere in the
# transcript, so they can never be proposed here: absence from this list is "not recorded", not "not available".
# Measured on this repository's transcripts: 36 of 37 sessions carry the record (513 records). Calls are
# {"type":"tool_use","id":"…","name":"<tool>"} — that key order held for every one of 25,413 calls counted.
# Calls are read from the whole tree (a subagent's call is a call); availability per session (a subagent's
# transcript counts towards the session it belongs to).
#
# THE PROPOSAL'S SYNTAX is Claude Code's own (code.claude.com/docs/en/permissions, fetched 2026-11-04):
# `mcp__<server>__*` matches every tool of that server, and a bare tool name in `deny` removes that tool from
# Claude's context. Only proposed, never written: a deny rule is the user's decision, and the change takes effect
# for a session's prompt cache only by re-writing it.
# NEVER PROPOSED, whatever the counts: the tools Crewforth's own flow relies on even when a project never used them
# (the approval question, delegation, skills, task tracking) and the two web tools.
if [ "$TOOLS" = 1 ]; then
  MINS="${CREW_TOOLS_MIN_SESSIONS:-5}"; case "$MINS" in ''|*[!0-9]*|0) MINS=5 ;; esac
  # One grep over the tree, one awk to count, one sort: never a process per line or per file.
  TOUT="$(LC_ALL=C grep -rHoE --include='*.jsonl' -e '"type":"tool_use","id":"[^"]*","name":"[^"]*"' \
      -e '"type":"deferred_tools_delta","addedNames":\[[^]]*\]' "$DIRS" 2>/dev/null \
  | LC_ALL=C awk -v N="$MINS" '
      { i = index($0, ":\"type\":\""); if (!i) next
        f = substr($0, 1, i - 1); m = substr($0, i + 1)
        # the session a file belongs to: <dir>/<sid>.jsonl, or <dir>/<sid>/subagents/<agent>.jsonl
        r = f; sub(/\/subagents\/.*/, "", r); sub(/\.jsonl$/, "", r)
        if (m ~ /^"type":"tool_use"/) { n = m; sub(/.*"name":"/, "", n); sub(/"$/, "", n); called[n]++
          if (n ~ /^mcp__/) { s = substr(n, 6); sub(/__.*/, "", s); scalled[s]++ }
          next }
        sess[r] = 1
        l = m; sub(/^[^[]*\[/, "", l); sub(/\]$/, "", l); k = split(l, a, ",")
        for (j = 1; j <= k; j++) { t = a[j]; gsub(/"/, "", t); if (t == "") continue
          if (!((r, t) in seen)) { seen[r, t] = 1; avail[t]++ }
          if (t ~ /^mcp__/) { s = substr(t, 6); sub(/__.*/, "", s); ntool[s, t] = 1
            if (!((r, "S", s) in seen)) { seen[r, "S", s] = 1; savail[s]++ } } } }
      END {
        ns = 0; for (r in sess) ns++; print "S\t" ns
        for (k2 in ntool) { split(k2, p, SUBSEP); stools[p[1]]++ }
        for (s in savail) if (savail[s] >= N && !(s in scalled)) print "P\tmcp__" s "__*\t" savail[s] "\t" stools[s] " tool(s)"
        for (t in avail) {
          if (t ~ /^mcp__/) continue
          if (t ~ /^(AskUserQuestion|Agent|Skill|WebFetch|WebSearch|EndConversation)$/ || t ~ /^Task/) continue
          if (avail[t] >= N && !(t in called)) print "P\t" t "\t" avail[t] "\t"
        }
      }' | LC_ALL=C sort)"
  NS="$(printf '%s\n' "$TOUT" | awk -F'\t' '$1 == "S" { print $2; exit }')"; NS="${NS:-0}"
  echo "== tool availability ($SCOPE: $NS session(s) with a tool record; threshold $MINS session(s)) =="
  if [ "$NS" = 0 ]; then
    echo "  NOT MEASURED — no transcript here records which tools a session had (deferred_tools_delta)."
    echo "  Only deferred tools are ever recorded; tools loaded up front are not, so nothing can be proposed from them."
    exit 0
  fi
  echo "  read from deferred_tools_delta.addedNames: deferred tools only — tools loaded up front (Bash, Read, Edit, …)"
  echo "  are not recorded there and are never proposed. A deferred tool costs its name in every request, not its"
  echo "  schema, so a deny here saves little until something loads it. Never proposed: AskUserQuestion, Agent, Skill,"
  echo "  Task*, WebFetch, WebSearch, EndConversation."
  PN="$(printf '%s\n' "$TOUT" | awk -F'\t' '$1 == "P"' | wc -l | tr -d ' ')"
  if [ "${PN:-0}" = 0 ]; then
    echo "  nothing to propose: every recorded tool was called, or was available in fewer than $MINS session(s)."
    exit 0
  fi
  echo "  available in >= $MINS session(s) and never called ($PN):"
  printf '%s\n' "$TOUT" | awk -F'\t' '$1 == "P" { printf "    %-44s available in %s session(s), 0 calls%s\n", $2, $3, ($4 == "" ? "" : ", " $4) }'
  echo "  PROPOSAL only — nothing was written. To apply it, add to .claude/settings.local.json (your own file):"
  printf '%s\n' "$TOUT" | awk -F'\t' '$1 == "P" { l = l (l == "" ? "" : ", ") "\"" $2 "\"" } END { print "    \"permissions\": { \"deny\": [" l "] }" }'
  echo "  apply after sessions are idle; a mid-conversation change re-writes the cache"
  exit 0
fi

# One grep over the tree, not one per skill: 40 greps × 320 files is the cost pattern Crewforth keeps removing.
#
# TWO SHAPES COUNT AS A FIRING, and only these two:
#   "file_path":"…/skills/<name>/SKILL.md"   — the skill was READ (how a skill is actually consumed)
#   "name":"Skill","input":{"skill":"<name>" — the Skill tool was invoked by name
# THE ANCHOR IS THE POINT. Matching a bare skill name anywhere in the JSON would count Crewforth measuring itself:
# a single `grep -rn description: skills/` tool result echoes all 40 paths on one line, and every skill would
# report as used forever. Both patterns above require the name to sit in a position only a real invocation puts
# it in. Lines carrying "is_error":true are dropped first — a read that failed is not a use. That drop is
# line-level, so it catches the error record itself; correlating a failed result back to its own tool_use id
# would need a second pass over every line, and a Read of a file that is installed rarely fails.
HITS="$(grep -rhI --include='*.jsonl' -e '"file_path":"' -e '"name":"Skill"' "$DIRS" 2>/dev/null \
        | grep -v '"is_error":true' \
        | grep -ohE '/skills/[A-Za-z0-9._-]+/SKILL\.md|"name":"Skill","input":\{"skill":"[A-Za-z0-9._-]+"' 2>/dev/null \
        | sed -e 's#^/skills/##' -e 's#/SKILL\.md$##' -e 's#.*"skill":"##' -e 's#"$##' \
        | sort | uniq -c | sort -rn)"

FIRED=0; COLD=0; COLDLIST=""; COLDBYTES=0; FIREDLIST=""
for f in "$SKILLS"/*/SKILL.md; do
  [ -e "$f" ] || continue
  n="$(basename "$(dirname "$f")")"
  c="$(printf '%s\n' "$HITS" | awk -v s="$n" '$2==s {print $1; exit}')"
  if [ -n "$c" ]; then
    FIRED=$((FIRED+1)); FIREDLIST="$FIREDLIST  $n($c)"
  else
    COLD=$((COLD+1)); COLDLIST="$COLDLIST  $n"
    b="$(awk '/^---$/{k++; next} k==1' "$f" | awk '/^(name|description):/,0' | wc -c | tr -d ' ')"
    COLDBYTES=$((COLDBYTES + b))
  fi
done
TOTAL=$((FIRED+COLD))
[ "$TOTAL" -gt 0 ] || { echo "utilization: NOT MEASURED — no skills installed"; exit 0; }

NSESS="$(find "$DIRS" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')"
echo "== skill utilization ($SCOPE, $NSESS transcript file(s)) =="
echo "  fired : $FIRED/$TOTAL"
echo "  cold  : $COLD/$TOTAL   (${COLDBYTES} B of always-on listing spent on skills nothing reached)"
[ -n "$FIREDLIST" ] && { echo "  --- fired (times reached) ---"; printf '%s\n' "$FIREDLIST" | tr ' ' '\n' | grep -v '^$' | sort | paste -sd' ' - | fold -s -w 100 | sed 's/^/    /'; }
[ -n "$COLDLIST" ]  && { echo "  --- cold ---";                  printf '%s\n' "$COLDLIST"  | tr ' ' '\n' | grep -v '^$' | sort | paste -sd' ' - | fold -s -w 100 | sed 's/^/    /'; }
echo "  ---"
# Crewforth's own repository is the one place where this number lies, so it says so rather than being quoted out
# of context later. Here a SKILL.md is opened to EDIT it, and an edit is indistinguishable from an invocation at
# the transcript level — both are a Read of the same path. In a project that USES Crewforth there is no such
# traffic, which is the case the measurement is for.
[ "$OWNREPO" = 1 ] && {
  echo "  NOTE: read from Crewforth's OWN repository, where a SKILL.md is opened to be EDITED. Those edits are"
  echo "  indistinguishable from invocations here, so 'fired' is inflated. Run this in a project that USES the"
  echo "  Crewforth for a number that means what it says."
  echo "  ---"; }
echo "  A cold skill is not a bad skill — a runbook earns its place by existing. This is the evidence for the"
echo "  skillOverrides \"name-only\" decision doctor.sh §4a asks you to make, not the decision itself."
exit 0
