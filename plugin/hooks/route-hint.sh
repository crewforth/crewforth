#!/usr/bin/env bash
# Route hint — name the owning agent next to the request itself.
#
# WHY THIS EXISTS, measured rather than assumed. Crewforth's premise is that specialist agents run the work. On a
# focused, single-domain request that does not happen: 42 measured sessions across the eval suite, two A/B pairs
# and a twelve-agent domain sweep produced ZERO spontaneous delegations. Two things were tried first and both
# came back zero — rewriting the agents' `description` into ownership language, and telling the discipline to
# call the Agent tool concretely. What DOES work is naming the agent explicitly: a command body that @-mentions
# its agents delegated 3 of 3, and a single request carrying twelve different jobs fanned out to all twelve
# owners correctly. So the mechanism is sound; the trigger is the shape of the request.
#
# The subagents docs list three inputs to the delegation decision: "the task description in your request, the
# `description` field in subagent configurations, and current context". Crewforth had touched the second and the
# third. This hook is the first: `UserPromptSubmit` can return `additionalContext`, and for that event the docs
# place it "alongside the submitted prompt" — the one position we had never used.
#
# It states an owner. It never decides FOR the model, never blocks, and stays silent unless a match is clear:
# a wrong route is worse than none, because it looks like Crewforth worked.
#
# ---------------------------------------------------------------------------------------------------------
# ONE AWK PASS, NOT A SHELL LOOP — this hook runs on EVERY prompt, so its cost is the session's floor.
#
# The first version scored the components with nested shell loops: for each of ~50 component files a
# grep+head+grep+sed, and then for each of its trigger phrases a `norm()` pipeline (sed|tr|sed) plus a
# `printf|grep -qE` with another `sed` nested inside the pattern. 348 phrases across the shipped payload put
# that at roughly 2000 process spawns per prompt. Measured on an M-series Mac: 3.35s of pure fork overhead
# (104% CPU, ~1.7ms per spawn) for a hook whose actual work is substring matching on a few KB of text.
#
# That is merely wasteful on macOS/Linux. On Windows it is fatal. Git Bash has no real fork(): every process
# is a CreateProcess plus the MSYS2 emulation layer plus whatever the AV scanner charges. Measured on a
# Windows 11 desktop rather than assumed: 62-135 ms per spawn idle, and up to ~400 ms while the machine is
# busy — forty to eighty times the ~1.7 ms Linux pays, not the "20-50 ms" this comment claimed before anyone
# ran it here. The same 2000 spawns therefore land at two to four MINUTES, not 40-100 seconds, against a
# 10s hook timeout. Claude Code blocks on the hook until that timeout expires, on EVERY prompt, and then
# discards the output — so Crewforth paid the full stall and got no routing for it. That is the "it hangs and
# nothing works" report from Windows users, and it is not a Claude Code bug: Crewforth was spending the budget.
#
# Everything below is therefore one awk invocation over the component files, with the normalisation and the
# matching done inside awk. Total external processes: FIVE — cat, sed, sed, head, awk. (The count said four
# until it was traced with `bash -x` on Windows; the `cat` on the next line reads stdin and had been read
# past.) Measured end to end here: 5 spawns, ~328 ms per prompt idle. eval/smoke-test.sh §7y pins the shape.
set -uo pipefail
IN="$(cat)"
case "$IN" in *'"hook_event_name"'*UserPromptSubmit*) ;; *) exit 0 ;; esac

# Two editions, two layouts: a full install puts the components under .claude/, the plugin ships them beside the
# hook itself. Resolve both or the plugin channel silently loses routing — the same one-channel-weaker failure
# the commit content gate had before 1.9.0.
#
# `${VAR//\\//}` folds backslashes to forward slashes. On Windows both CLAUDE_PROJECT_DIR and CLAUDE_PLUGIN_ROOT
# arrive as native paths (`C:\Repos\app`), and a native path pasted into a POSIX one produces
# `C:\Repos\app/.claude/agents` — a shape neither side reliably resolves. Forward slashes work on every
# platform, including Git Bash, and the substitution is a no-op where there is nothing to fold.
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  PROOT="${CLAUDE_PLUGIN_ROOT//\\//}"
  [ -d "$PROOT/agents" ] && { AGENTS="$PROOT/agents"; SKILLS="$PROOT/skills"; }
fi
if [ -z "${AGENTS:-}" ]; then
  PROJ="${CLAUDE_PROJECT_DIR:-.}"; PROJ="${PROJ//\\//}"
  AGENTS="$PROJ/.claude/agents"; SKILLS="$PROJ/.claude/skills"
fi
[ -d "$AGENTS" ] || [ -d "$SKILLS" ] || exit 0

# The prompt text, taken as a raw slice: no jq dependency, and a partial read is fine because matching is by
# substring anyway. Everything after `"prompt":"` up to the closing quote that is not escaped. It goes to awk
# through the ENVIRONMENT, never through `-v`: awk expands escape sequences in a `-v` value, so a prompt
# containing a literal backslash would be rewritten before the normaliser ever saw it.
# TWO FIELD NAMES, because the payload has carried both and this hook is the only thing in Crewforth that reads
# the prompt text at all. The published UserPromptSubmit schema names the field `user_input`; the payload this
# hook was written against, and the suite that pins it, used `prompt`. Which one a given CLI sends is not a fact
# this repo can establish from here, and getting it wrong is SILENT: the slice comes back empty, the hook exits
# 0, and routing is simply gone while every test stays green because the tests choose the name too. So both are
# accepted. The fallback costs nothing on the path that already worked — it only runs when the first name found
# nothing. `prompt_id` cannot be mistaken for `prompt`: the pattern includes the closing quote.
CREW_PROMPT="$(printf '%s' "$IN" | sed -n 's/.*"prompt"[[:space:]]*:[[:space:]]*"\(.*\)/\1/p' | sed 's/","[a-z_]*":.*$//' | head -c 4000)"
[ -n "$CREW_PROMPT" ] || CREW_PROMPT="$(printf '%s' "$IN" | sed -n 's/.*"user_input"[[:space:]]*:[[:space:]]*"\(.*\)/\1/p' | sed 's/","[a-z_]*":.*$//' | head -c 4000)"
[ -n "$CREW_PROMPT" ] || exit 0

# NOT EVERY TURN CARRIES A REQUEST. A field session watched this hook inject "Use the <x> subagent for this task"
# on turns where the user had typed nothing at all: a background subagent finished, its REPORT arrived as the
# turn's text, and the report was scored as if it were the request. Both times the named owner was the agent
# whose finished work was being reported -- so the hint pushed the main thread to re-delegate work that was
# already done, at the 10-16k tokens a subagent floor costs. Ten injections that session, zero of them useful.
#
# Whether Claude Code really raises UserPromptSubmit for those turns is NOT established here, and this does not
# depend on the answer: text that OPENS with a notification marker is not a user request under any reading, so
# staying quiet is right either way. Anchored to the start deliberately -- a person may well write the words
# "system notification" inside a genuine request, and only a notification BEGINS as one.
# A subagent's hand-back arrives as its own turn, opening with `<agent-message from="…">` and then
# `[Subagent hand-back]` on the next line — measured by capturing this hook's stdin on a real hand-back (3.0.1,
# field report P2): the first 80 bytes of `prompt` were exactly that, and the hook named the agent whose work had
# just been reported, in three field sessions on two machines.
# ---- CREW-NOT-A-PERSON (one definition, carried by prompt-approval.sh and route-hint.sh; smoke-test pins it) ----
# Turns that open with one of these are not something a person typed: a finished background task, a subagent's
# hand-back, a message from another session. Measured on real hand-backs (3.0.1): they do raise UserPromptSubmit.
_crew_not_a_person(){  # $1 = the prompt as it sits in the payload -> 0 when it is not a person's message
  case "$1" in
    '<task-notification'*|'<system-reminder'*|'<cross-session-message'*|'<local-command-stdout'*|'<agent-message'*\
    |'[SYSTEM NOTIFICATION'*|'[Task '*|'Another Claude session sent a message'*)
      return 0 ;;
  esac
  return 1
}
# ---- /CREW-NOT-A-PERSON ----------------------------------------------------------------------------------
_crew_not_a_person "$CREW_PROMPT" && exit 0
export CREW_PROMPT

# Glob expansion is a shell builtin — no forks. Agents FIRST, then skills: awk reads its arguments in order and
# the tie-break below is first-wins, so the order is part of the contract, not incidental.
FILES=()
for f in "$AGENTS"/*.md "$SKILLS"/*/SKILL.md; do [ -e "$f" ] && FILES+=("$f"); done
[ "${#FILES[@]}" -gt 0 ] || exit 0

# Score every installed agent by how many of its trigger phrases appear. Longest phrase wins ties: "state
# management" is a stronger signal than "state", and a two-word hit beats a one-word hit from another agent.
# Agents AND skills are scored. The agent answers "who owns this"; the skill answers "how is it done", and the
# skill is the cheaper, more useful nudge: a subagent re-pays its whole context (measured at 10-16k tokens for a
# no-op), while a skill just loads its method into the turn already in progress. Measured on a focused request,
# neither fired on its own — 12 domain tasks produced zero delegations and a skill in only 2 of 12 — so the
# method Crewforth exists to carry was simply absent from the work.
RES="$(awk '
# Same normalisation the routing eval uses: Turkish diacritics folded, lowercased, every run of non-alphanumerics
# collapsed to one space, and the whole string space-padded so a match is word-bounded. Without the padding a
# short trigger hides inside a longer word — `UI` inside `build` once sent CI failures to the frontend expert.
# Folding runs before tolower() because tolower() is ASCII-only in a byte-oriented awk; the gsub pairs cover
# both cases explicitly so the result does not depend on which awk Git Bash happens to ship.
function norm(s) {
  gsub(/Ç/,"c",s); gsub(/ç/,"c",s); gsub(/Ğ/,"g",s); gsub(/ğ/,"g",s)
  gsub(/İ/,"i",s); gsub(/ı/,"i",s); gsub(/Ö/,"o",s); gsub(/ö/,"o",s)
  gsub(/Ş/,"s",s); gsub(/ş/,"s",s); gsub(/Ü/,"u",s); gsub(/ü/,"u",s)
  s = tolower(s)
  gsub(/[^a-z0-9]+/," ",s)          # also sweeps up any multi-byte leftovers, one space per run
  sub(/^ +/,"",s); sub(/ +$/,"",s)
  return s
}
BEGIN { np = " " norm(ENVIRON["CREW_PROMPT"]) " "; bestA=0; bestS=0; nameA=""; nameS="" }
seen[FILENAME] { next }                                    # one Trigger-phrases line per component, the first
{
  if (tolower($0) !~ /trigger phrases:/) next
  seen[FILENAME] = 1
  if (FILENAME ~ /\/SKILL\.md$/) { kind="skill"; name=FILENAME; sub(/\/SKILL\.md$/,"",name) }
  else                          { kind="agent"; name=FILENAME; sub(/\.md$/,"",name) }
  sub(/.*\//,"",name)
  score = 0; rest = $0
  while (match(rest, /"[^"]+"/)) {
    ph   = substr(rest, RSTART+1, RLENGTH-2)
    rest = substr(rest, RSTART+RLENGTH)
    p = norm(ph)
    if (p == "") continue
    # Suffix-tolerant, prefix-anchored: the trigger must START at a word boundary, but may carry up to three
    # trailing letters. Word-bounded matching alone silently lost every inflection — `component` did not match
    # "components", `test` did not match "tests" — which is how a hook that looked correct stayed quiet on two
    # thirds of real prompts. The boundary that matters is the LEADING one: it is what keeps `ui` out of `build`.
    # Written as three optional letters rather than {0,3} because interval expressions are not universal in awk.
    # No escaping needed: norm() has already reduced the phrase to [a-z0-9 ], so it carries no metacharacter.
    if (np ~ ("(^| )" p "[a-z]?[a-z]?[a-z]?( |$)")) score += length(ph)
  }
  if (score <= 0) next
  # An AGENT outranks a SKILL when both match: agent = who, skill = how, and the agent applies its own skills
  # anyway, so naming it delivers the method PLUS the isolation and the audit path. A skill is named when no
  # agent owns the domain at all (iterate, reflect, worktree, eval-grader).
  #
  # THE TWO KINDS ARE SCORED SEPARATELY, and that is the fix for a measured silence. The preference used to be
  # applied by OVERWRITING the best match the moment any agent matched, whatever its score — so a one-word
  # agent hit discarded a far stronger skill hit, and the discarded total then fell under the floor below and
  # the hook printed NOTHING. Measured before this change: "this needs an accessibility audit" produced the
  # a11y hint, and "the PAGE needs an accessibility audit" produced silence, because `page` is a
  # crew-frontend-expert trigger worth 4 which replaced the a11y score of ~30 and then failed `>= 6`. Adding a common noun
  # to a request removed the routing entirely, which is the opposite of what a preference is for. Each kind now
  # keeps its own best and the preference is applied at the END, among candidates that clear the floor.
  if (kind == "agent") { if (score > bestA) { bestA=score; nameA=name } }
  else                 { if (score > bestS) { bestS=score; nameS=name } }
}
# Silence is the default. No match, or a match too weak to be sure, means the main thread decides as before.
# The agent is preferred only when it is credible on its own: a weak agent match no longer buries a strong skill.
END {
  if      (bestA >= 6) print "agent\t" nameA
  else if (bestS >= 6) print "skill\t" nameS
}
' "${FILES[@]}" 2>/dev/null)"

[ -n "$RES" ] || exit 0
BESTKIND="${RES%%	*}"; BEST="${RES#*	}"
[ -n "$BEST" ] && [ "$BEST" != "$RES" ] || exit 0

# The wording is an INSTRUCTION, not a suggestion, and that distinction is the whole experiment. The first
# version hedged — "unless it is a one-line edit", "if it is genuinely not that agent's work, say so" — which
# handed the model two explicit ways to decline, and it took them: 4 of 12. The docs give the phrasing that
# works verbatim ("Use the test-runner subagent to fix failing tests"), so that is what goes in. A user typing
# "use crew-frontend-expert for this" gets obeyed without argument; there is no reason to write it more weakly
# just because a hook is doing the typing.
if [ "$BESTKIND" = skill ]; then
  MSG="Use the \`$BEST\` skill for this task."
else
  MSG="Use the $BEST subagent for this task."
fi
printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"%s"}}\n' "$MSG"
