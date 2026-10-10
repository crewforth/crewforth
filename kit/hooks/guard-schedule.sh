#!/usr/bin/env bash
# guard-schedule.sh - a prompt a tool schedules is not the user's (§4.4).
#
# WHY. In `auto` and `dontAsk` the approval for a commit or a push is what the user types: `/crew-approve commit`,
# recorded by hooks/prompt-approval.sh from UserPromptSubmit. A prompt that a tool SCHEDULES raises the same event
# when it fires. So a session that scheduled `/crew-approve commit` would be approving its own commit.
#
# WHAT. Wired on PreToolUse for the tools that schedule a prompt (CronCreate, ScheduleWakeup, RemoteTrigger, and an
# MCP tool whose name holds trigger, schedule, cron or later). The call is refused when ANY string in its input is
# an approval, by the function that reads the user's own prompt: prompt-approval.sh is sourced for it, so there is
# one definition of what an approval is. An ordinary scheduled prompt holds no such string and passes untouched.
#
# COST. One awk on these few tools, to take the strings out of the payload; nothing on any other tool call.
# HONEST SCOPE. A tool this hook is not wired on, or a prompt put together only when it fires, is past it.
set -uo pipefail
# ---- CREW-LOCALE -----------------------------------------------------------------------------------------
# Everything this gate matches with runs in the C locale, whatever the session's own is. Under a Turkish locale
# the letters i and I are not each other's other case (their partners are İ and ı), and every case-insensitive
# match here is written in ASCII. Measured under tr_TR.UTF-8 with the locale left as it came:
#   GNU grep 3.11 / bash 5.2 on Linux: `grep -i init` does not find INIT (-F, -E and plain alike);
#     bash's nocasematch does not match GIT against git; `[A-Za-z]` in a regex does not hold I; awk's tolower
#     turns GIT into gıt. The suite, run whole under that locale, went from 4 failures to 30: a recursive
#     Remove-Item, a write to a gate file, `git config --remove-section core`, a read of a nested .env and a
#     staged key all passed.
#   GNU grep 3.0 in Git Bash on Windows: `grep -iF` with an ASCII pattern aborts (exit 134), and the pre-commit
#     scan for private strings read that as "no match".
#   macOS (BSD grep, bash 3.2): none of it; tr_TR.UTF-8 folds i and I the ASCII way there.
# The cost: a letter outside ASCII has no other case in the C locale. The two git hooks that scan a user's own
# words look a second time under the session's locale for a pattern that holds such a letter (_CREW_LOCALE).
# Byte-identical in every gate; the suite pins it.
_CREW_LOCALE="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
case "$_CREW_LOCALE" in C|POSIX) _CREW_LOCALE="" ;; esac
export LC_ALL=C
# ---- /CREW-LOCALE
# ---- CREW-FAILCLOSED ---------------------------------------------------------------------------------------
# A gate that stops on an error of its own must refuse the call, not let it through. Claude Code blocks a tool call
# on exit 2 only; a hook that dies with 1, or runs on past the rule that broke, has allowed it. Both happened in
# one defect (measured, bash 5): a local array declared and not set is "unbound" under `set -u`, the rule that read
# it was abandoned in the middle, the script went on with the NEXT top-level command and left with 0, and
# `rm .claude/hooks/pre-commit` passed. bash does one of two things with such an error, by the kind of error:
#   * it leaves the shell with a status that is neither 0 nor 2  -> the EXIT trap below turns that into a refusal;
#   * it abandons the top-level command it was in and continues -> the whole gate IS one top-level command,
#     _gate_main, which only ever ends by `exit`. If it RETURNS, it was abandoned, and the line after it refuses.
# Not covered, and said so: an error inside a command substitution (only that subshell ends), and a command
# that is not found (status 127, the script continues inside the same command).
# Byte-identical in every PreToolUse gate; the suite pins it. No process is started.
_crew_stop(){  # $1 = what happened
  declare -F gatelog >/dev/null 2>&1 && gatelog BLOCK 4.5 "the gate stopped on an error of its own"
  echo "GUARD (§4.5): this gate stopped on an error of its own ($1) before it finished judging the call, so the call is refused." >&2
  echo "Nothing about the call itself was found. The error is the line above these two; it is a defect in Crewforth, not in what you ran. Run the doctor (bash .claude/eval/doctor.sh, Bash tool, not PowerShell) and report it." >&2
  exit 2
}
trap '_crew_rc=$?; trap - EXIT; case "$_crew_rc" in 0|2) exit "$_crew_rc" ;; esac; _crew_stop "exit status $_crew_rc"' EXIT
# ---- /CREW-FAILCLOSED
_gate_main(){
local here="${BASH_SOURCE%/*}" strs sv tn sch=0
[ "$here" = "${BASH_SOURCE}" ] && here=.
IFS= read -r -d '' INPUT || true
if [ ! -f "$here/prompt-approval.sh" ]; then
  echo "GUARD (§4.4): prompt-approval.sh is not beside this gate, so a scheduled prompt cannot be checked for an approval and the call is refused. Update Crewforth." >&2
  exit 2
fi
. "$here/prompt-approval.sh"
declare -F _crew_appr_op >/dev/null 2>&1 || { echo "GUARD (§4.4): prompt-approval.sh did not give the approval check, so the call is refused. Update Crewforth." >&2; exit 2; }
_json_slice "$INPUT" tool_name >/dev/null; tn="$_JS"
shopt -s nocasematch
case "$tn" in *cron*|*schedul*|*trigger*|*later*|*wakeup*) sch=1 ;; esac
shopt -u nocasematch
[ "$sch" = 1 ] || exit 0
# Every JSON string of at most 120 bytes, still escaped, one per line (a JSON string holds no raw newline). An
# approval is a few words: a longer string is never one, and is not kept.
strs="$(printf '%s' "$INPUT" | LC_ALL=C awk '{ buf = buf $0 " " } END { n = length(buf); ins = 0; esc = 0; s = ""; big = 0
    for (i = 1; i <= n; i++) { c = substr(buf, i, 1)
      if (!ins) { if (c == "\"") { ins = 1; s = ""; big = 0 }; continue }
      if (esc) { esc = 0; if (!big) s = s c; continue }
      if (c == "\\") { esc = 1; if (!big) s = s c; continue }
      if (c == "\"") { ins = 0; if (!big) print s; continue }
      if (!big) { s = s c; if (length(s) > 120) big = 1 } } }')" || {
  echo "GUARD (§4.4): the prompt this call schedules could not be read (awk did not run), so the call is refused." >&2; exit 2; }
while IFS= read -r sv; do
  [ -n "$sv" ] || continue
  _json_unescape "$sv" >/dev/null; _crew_appr_op "$_JU"
  if [ -n "$OP" ]; then
    if [ "$OP" = loosen ]; then
      echo "GUARD (§4.4): this call schedules a prompt that lowers a model floor. Only the user can type /crew-loosen; a prompt a tool schedules would lower the floor in their place, so the call is refused." >&2
      echo "Schedule the work without it. If a floor looks too high, say so: the user can type /crew-loosen $LO_AGENT $LO_CHANGE $LO_RISK themselves." >&2
    else
      echo "GUARD (§4.4): this call schedules a prompt that is an approval for a commit or a push ($OP). An approval is what the user types; a prompt a tool schedules would approve in their place, so the call is refused." >&2
      echo "Schedule the work without it. For the approval itself, show the commit message and ask: the user can type /crew-approve $OP when they agree." >&2
    fi
    exit 2
  fi
done <<< "$strs"
exit 0
}
_gate_main "$@"
_crew_stop "a command of the gate was abandoned"
