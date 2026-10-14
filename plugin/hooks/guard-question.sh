#!/usr/bin/env bash
# guard-question.sh - the approval question reaches the person, not a hook (§4.4, 3.2.0).
#
# WHY. In `auto` the user can approve a commit or a push by answering one fixed question (AskUserQuestion), and
# hooks/prompt-approval.sh records the answer on PostToolUse. An answer is only worth recording if a person gave it.
# Two things can give it instead: another PreToolUse hook that answers `allow` with the answers filled in, and a
# PermissionRequest hook that answers the prompt before the person does (both measured on Claude Code 2.1.294).
#
# WHAT. Wired on PreToolUse for AskUserQuestion. Any question but the approval question gets no decision. The
# approval question must be the fixed text with no answers, asked in `auto` in an attended session; then this
# hook answers `ask`, which beats the first kind of hook in every mode, and only when no PermissionRequest hook
# may be wired (the second kind; _crew_prh_scan). It also notes the call it asked, and prompt-approval.sh records
# an answer to that call only. Everything it decides is defined in prompt-approval.sh (_crew_q_pre), sourced.
#
# A GATE, so an error of its own refuses the call (CREW-FAILCLOSED): a question let through with no `ask` is one a
# hook can answer.
# COST. Builtins on every AskUserQuestion; on the approval question the scan reads files and starts no process.
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
local here="${BASH_SOURCE%/*}"
[ "$here" = "${BASH_SOURCE}" ] && here=.
IFS= read -r -d '' INPUT || true
case "$INPUT" in *'Crewforth approval'*) ;; *) exit 0 ;; esac      # not the approval question: nothing to decide
if [ ! -f "$here/prompt-approval.sh" ]; then
  echo "GUARD (§4.4): prompt-approval.sh is not beside this gate, so the approval question cannot be checked and is not asked. Update Crewforth; the user can type /crew-approve instead." >&2
  exit 2
fi
. "$here/prompt-approval.sh"
declare -F _crew_q_pre >/dev/null 2>&1 || { echo "GUARD (§4.4): prompt-approval.sh beside this gate is an older one, so the approval question is not asked. Update Crewforth; the user can type /crew-approve instead." >&2; exit 2; }
_crew_q_pre
exit 0
}
_gate_main "$@"
_crew_stop "a command of the gate was abandoned"
