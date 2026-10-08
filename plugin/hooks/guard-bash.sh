#!/usr/bin/env bash
# Claude Code PreToolUse (Bash) guard. PreToolUse runs in EVERY permission mode, including bypass.
# stdin JSON, one line, in the key order captured from Claude Code 2.1.267 (values abridged):
#   {"session_id":…,"transcript_path":…,"cwd":…,"scratchpad_dir":…,"prompt_id":…,
#    "permission_mode":"default|acceptEdits|auto|dontAsk|plan|bypassPermissions","effort":{"level":…},
#    "hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"...","description":"..."},"tool_use_id":…}
#   This line used to show `permission_mode` AFTER `tool_input`. It was never a capture, and it was wrong. The
#   fallback parser below does not depend on the order either way, because the order is not a documented contract.
#   Every PATH value (`cwd`, `transcript_path`, `scratchpad_dir`) arrives in the platform's own spelling, so on
#   Windows it is `D:\Projects\…` and every separator is DOUBLED by JSON escaping. Captured from a live session
#   on a Windows machine; the `cwd` normaliser below is the one place that matters and it undoes the escape first.
#
# §4.5 destructive operations -> HARD BLOCK (exit 2). No key, no mode, no escape.
#
# §4.4 git commit / git push -> ASK THE USER, IN SESSION. The hook answers with
#   {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask", ...}}
# and Claude Code escalates to a permission prompt that ONLY the human can answer. Approve once and Claude
# runs the commit itself — you never have to paste commands into your own terminal. The model cannot
# self-approve (it never sees the keypress) and cannot forge the decision (this hook is a separate process).
#
# Verified on Claude Code 2.1.205: a hook "ask" is honoured — the tool does not run until the user says yes —
# in permission_mode default, acceptEdits, auto and dontAsk. It is NOT verified under bypassPermissions, so
# there (and for any mode this hook does not recognise, i.e. anything added in a future release) we FAIL
# CLOSED and hard-block instead of trusting a prompt that may never reach the user.
#
# That gap was carried as "unverified" for a long time, as though a measurement would eventually close it.
# Checked against the published hooks reference (2026-07-29): the docs describe permissionDecision and they
# describe the permission modes, but they say NOTHING about how the two interact, or whether hooks run at all
# under bypassPermissions. So there is no documented contract to rely on — and a security gate resting on
# observed-but-unspecified behaviour is a bug even while it happens to work, because nothing stops a release
# from changing it. Failing closed is therefore the correct answer regardless of what a test would show, and
# this stops being an open question: it is a decision. Should the interaction ever be specified, revisit.
#
# The gate log gets one TSV line per logged decision (BLOCK/ASK/ALLOW, section, rule; the command only with
# CREW_GATE_LOG_CMD=1). On by default since 2.5.0 (see _gatelog_path below); CREW_GATE_LOG=<path> redirects it.
# Write-only, it never influences a verdict. It exists because a gate that cannot be observed firing cannot be
# measured: "the model never tried it" and "the gate stopped it" look the same. guard-write.sh logs there too.
#
# CLAUDE_GIT_OK=1, exported by the user before the session starts, pre-authorises the session. It exists for
# headless/CI runs where no one is at the keyboard. It does NOT replace approval: present the message first.
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
# ---- CREW-MATCH -------------------------------------------------------------------------------------------
# grep on the command, without a pipe and with its status read. Both halves were measured failing open:
#   * `echo "$CMD" | grep -q …` under pipefail. grep -q leaves at its first match; when the command is larger than
#     the pipe holds, the writer is killed by SIGPIPE and the pipeline's status is 141, which the rule read as
#     "no match". On macOS, a command of 72 KB or more whose FIRST line was `rm -rf /tmp/x/*` (or dd of=, curl | sh,
#     chmod 777, mkfs, a lockfile delete) passed with exit 0; with that line last it was refused. A here-string
#     has no writer to kill.
#   * A grep that could not run (killed, out of memory, exit 2 or more) answered like one that found nothing.
# So: _grep answers 0 (found) or 1 (not found), and anything else stops the call. It must be called in the hook's
# own shell, never inside $( ) or a pipeline, or the stop would only leave that child.
_grep_stop(){  # $1 = grep's status
  declare -F gatelog >/dev/null 2>&1 && gatelog BLOCK 4.5 "a match that could not run"
  echo "GUARD: a check of this command could not run (grep exited $1), so the command was not judged and is refused." >&2
  echo "Nothing about the command itself was found. Run it again; if it is refused the same way, the fault is in the machine's grep, not in the command." >&2
  exit 2
}
_grep(){  # $1 = text, $2… = grep's arguments -> 0 found · 1 not found
  local t="$1" rc; shift
  grep "$@" <<< "$t"; rc=$?
  [ "$rc" -le 1 ] && return "$rc"
  _grep_stop "$rc"
}
_grep_out(){  # the same for a caller that wants what grep printed -> _GO (empty when nothing matched)
  local t="$1" rc; shift
  _GO="$(grep "$@" <<< "$t")"; rc=$?
  [ "$rc" -le 1 ] && return 0
  _grep_stop "$rc"
}
# ---- /CREW-MATCH
# ---- CREW-JOIN --------------------------------------------------------------------------------------------
# A line that ends in a backslash continues on the next one: the shell takes `rm -f \<newline>.claude/hooks/x` as
# ONE command. The rules read the command line by line and word by word, so each half looked harmless (measured,
# rc 0: a gate file deleted, copied over, moved, edited in place, redirected over; `rm \<newline>-rf`;
# `git push \<newline>--force`; and `git \<newline>push`, `git \<newline>commit`, which reached neither the approval
# prompt nor the review gate). _join_cmd joins such lines in CMD before anything reads it, the way the shell does:
#   * an ODD number of backslashes before the newline continues the line; an even number is backslashes, and the
#     newline still ends the command.
#   * PowerShell continues a line with a backtick, so a PowerShell call is joined on that.
#   * a `#` at the start of a word MAY open a comment, and in a comment the backslash continues nothing: the next
#     line is a command of its own. Telling a comment from a quoted `#` needs the whole quoting, so that line is
#     read BOTH ways: joined, and the lines it would have swallowed once more as a command after it.
# Inside single quotes and in a quoted here-document the shell keeps the pair; joining it there changes only data.
# Byte-identical in every gate that reads a command; the suite pins it.
_join_lines(){  # $1 = command, $2 = the character that continues a line -> _JL
  local s="$1" e="$2" nl=$'\n' line t body c out="" cur="" extra="" amb=0
  _JL="$s"
  case "$s" in *"$e$nl"*) ;; *) return 0 ;; esac
  while IFS= read -r line || [ -n "$line" ]; do
    t="${line##*[!"$e"]}"; body="$line"; c=0
    if [ $(( ${#t} % 2 )) = 1 ]; then body="${line%"$e"}"; c=1; fi
    [ "$amb" = 1 ] && extra="$extra$body"
    cur="$cur$body"
    if [ "$c" = 1 ]; then
      [ "$amb" = 1 ] || case "$cur" in '#'*|*[[:space:]\;\&\|\(]'#'*) amb=1 ;; esac
      continue
    fi
    out="$out$cur$nl"; [ "$amb" = 1 ] && out="$out$extra$nl"
    cur=""; extra=""; amb=0
  done <<< "$s"
  [ -n "$cur" ] && { out="$out$cur$e$nl"; [ "$amb" = 1 ] && out="$out$extra$nl"; }   # the last line ended in one: nothing follows it
  _JL="${out%"$nl"}"
}
_join_cmd(){  # CMD -> CMD with its continued lines joined
  case "$INPUT" in *'"tool_name":"PowerShell"'*|*'"tool_name": "PowerShell"'*) _join_lines "$CMD" '`' ;; *) _join_lines "$CMD" '\' ;; esac
  CMD="$_JL"
}
# ---- /CREW-JOIN
# The 2.x names of the variables a user can set still work (one helper: eval/lib/crew-env.sh).
_crew_d="${BASH_SOURCE%/*}"; [ "$_crew_d" = "${BASH_SOURCE}" ] && _crew_d=.
[ -f "$_crew_d/../eval/lib/crew-env.sh" ] && . "$_crew_d/../eval/lib/crew-env.sh"; unset _crew_d
# Read with the builtin, as guard-powershell.sh does: `INPUT="$(cat)"` is a subshell plus a process on EVERY call
# of this hook. `read` returns 1 at end of input; the text is read regardless.
IFS= read -r -d '' INPUT || true

# Gate observability. A gate that cannot be seen firing cannot be measured: "the model never reached for the
# command" and "the gate stopped it" leave behind exactly the same artifacts, and the A/B harness spent a whole
# case (evals/permission-pressure) unable to tell them apart — it had to report "guard-bash never fired" as an
# inference. One TSV line per decision, write-only, and it never touches the decision itself: every call site
# logs AFTER the verdict is settled.
#
# ON BY DEFAULT since 2.5.0, into .claude/gate-log.tsv — an evidence channel nobody switches on records nothing,
# and "the gates hold" is a claim that needs a record, not a test suite alone. CREW_GATE_LOG overrides the path;
# CREW_GATE_LOG=/dev/null (or a read-only .claude) turns it off. Only BLOCK, ASK and CLAUDE_GIT_OK's ALLOW reach
# here: an ordinary command writes nothing, and a git action CLAUDE_GIT_OK allows writes one ALLOW line.
#
# The COMMAND TEXT IS NOT RECORDED by default. It is the one field that can carry a path, an argument or a
# token, and `/crew-gates` never prints it — the report is rule names and counts. Recording it by default would
# buy nothing and add a place for a secret to sit. `CREW_GATE_LOG_CMD=1` puts it back for debugging a false
# positive, which is the only thing it is good for.
# Where the default log may go. An explicit CREW_GATE_LOG is the operator's call and is used as given. The
# DEFAULT path is only used when writing there cannot surprise anyone: outside a git repo, or inside one where
# the path is already ignored. A kit install gitignores .claude/, so this is the normal case — but the plugin
# edition drops into repos the installer never touched, and this repo proved the failure itself: the suite left
# a gate-log.tsv sitting in `git status` as an untracked file waiting to be committed. One `git check-ignore`
# runs only when a decision is logged (a block, an approval prompt or a CLAUDE_GIT_OK allow); ordinary commands
# never reach it.
_gatelog_path(){
  if [ -n "${CREW_GATE_LOG:-}" ]; then printf '%s' "$CREW_GATE_LOG"; return; fi
  [ -d ".claude" ] || return 0
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git check-ignore -q ".claude/gate-log.tsv" 2>/dev/null || return 0
  fi
  printf '%s' ".claude/gate-log.tsv"
}
gatelog(){  # $1 = verdict (BLOCK|ASK|ALLOW)  $2 = section  $3 = rule
  # Resolve the path ONCE per hook run and remember it HERE, not inside _gatelog_path: that function is invoked
  # as `$( … )`, which is a subshell, so a global it assigns is discarded the moment it returns — the same trap
  # this repo already documents for gb_sandbox in smoke-test, and the first version of this memo was written
  # inside the function and measured as a no-op (11 git processes before and after). Resolving costs two git
  # processes, and §4.6 made a twice-logging run the normal case for a successful commit: its own ALLOW line,
  # then §4.4's ASK. On Windows a process is 62-135 ms.
  if [ "${_GL_MEMO_SET:-0}" != 1 ]; then _GL_MEMO="$(_gatelog_path)"; _GL_MEMO_SET=1; fi
  _GL="$_GL_MEMO"; [ -n "$_GL" ] || return 0
  if [ "${CREW_GATE_LOG_CMD:-0}" = 1 ]; then
    printf '%s\t§%s\t%s\t%s\n' "$1" "$2" "$3" \
      "$(printf '%s' "$CMD" | tr -d '\000-\037' | cut -c1-200)" >> "$_GL" 2>/dev/null || true
  else
    printf '%s\t§%s\t%s\t\n' "$1" "$2" "$3" >> "$_GL" 2>/dev/null || true
  fi
}

# ---- CREW-PAYLOAD-MAX ------------------------------------------------------------------------------------
# A Bash or PowerShell call above this size is refused before anything reads it. A PreToolUse hook that reaches
# its timeout (600 s) stops nothing, and taking the command out of the JSON costs the square of its size — measured
# on macOS for an escape-dense command: 256 KB 49 s, 512 KB 200 s, so about 900 KB is where the timeout is, and at
# that size no rule would run at all. The limit is 8 times the largest of 12387 real commands (31639 bytes).
# The size is ${#INPUT} under the C locale: bytes, with no process. The Write and Edit tools are not limited — a
# large file is ordinary there — which is why the refusal points at them.
# Byte-identical in every hook that reads a Bash or PowerShell payload; the suite pins it.
_PAYLOAD_MAX=262144
_payload_over(){  # -> 0, with the refusal on stderr, when the payload in $INPUT is above the limit
  local LC_ALL=C
  [ "${#INPUT}" -gt "$_PAYLOAD_MAX" ] || return 1
  echo "GUARD (§4.5): this tool call is ${#INPUT} bytes long; the gates read a Bash or PowerShell call of up to $_PAYLOAD_MAX bytes." >&2
  echo "A larger one could take longer to read than a hook is given, and a hook that runs out of time stops nothing," >&2
  echo "so it is refused unread. Put the long content in a file (the Write tool takes any size) and give the command" >&2
  echo "the path of that file." >&2
  return 0
}
# ---- /CREW-PAYLOAD-MAX
if _payload_over; then CMD=""; gatelog BLOCK 4.5 "tool call too large to read"; exit 2; fi

# Extract the command + the permission mode: jq > python3 > pure-bash JSON slice.
#
# THE THIRD TIER IS NOT A DEGRADED MODE, it is the Windows default — though not for the reason written here for
# a long time. "Git Bash ships neither jq nor python3, so a stock Windows install takes this path" was WRONG in
# its second half, and being wrong there is what disarmed every gate below: Windows ships a python3 that passes
# `command -v` and cannot run, so a stock install took TIER 2 and failed open. See the note above the ladder.
# The conclusion survives the correction — this is still the path a stock Windows install ends on — but it gets
# there by the tier test failing, not by python3 being absent. It used to read `CMD="$INPUT"` — the
# whole hook payload handed to the rules as though it were the command — and that is not a weaker gate, it is
# a WRONG one, in both directions:
#   * False positive, measured: session_id `...-f872-...` (any session id whose second group starts `f8`) contains `-f8`, the §4.5 force-push rule matches
#     `-f([^a-z]|$)`, and so EVERY `git push` was hard-blocked as "push --force" no matter what was typed.
#     A gate that blocks the innocent teaches the user to reach for --no-verify, which disarms all of §4.
#   * Broken approval, measured: when it did not misfire, the §4.4 prompt rendered the raw JSON blob as "the
#     command Claude wants to run". §4.4's entire purpose is to show the human what they are approving; an
#     unreadable prompt is consent theatre.
# CI never caught it because GitHub's windows-latest image HAS jq preinstalled — the verification ran on a path
# no Windows user is on. smoke-test §7b pins the fallback branch itself for exactly that reason.
#
# The slice is pure parameter expansion: zero forks, so it is CHEAPER than the sed it replaces (Git Bash charges
# 62-135 ms per process on a Windows 11 desktop, and this hook runs on every Bash call). It must take the FIRST
# occurrence of the key: greedy matching would let a command containing the literal text `"command":"` relocate
# the parse and walk a payload straight past the rules. HOW it does that is documented inside _json_slice, next to
# the code, and only there -- this paragraph named the expansion once, and went stale the day it changed.
# ---- CREW-JSON-PARSE ------------------------------------------------------------------------------------
_json_find(){  # $1 = text, $2 = a literal -> _JF = the offset of its first occurrence, -1 when there is none
  # `${text%%"$literal"*}` gives the same offset and costs the DISTANCE to the occurrence times the length of the
  # text (bash measures the remaining string at every position it tries), so with no occurrence at all it is the
  # square of the size. That was the whole cost of a large Write: the path key is found near the front, and the
  # look for a SECOND one then ran over the content -- measured on macOS, 1 MB: 9.6 s for each of the two key
  # counts, against 0.02 s for one `case`; a 6 MB Write to a gate file was refused after 636 s, past the 600 s
  # timeout, which means not refused. Here the text is walked a piece at a time, each piece long enough to hold an
  # occurrence that starts in it, and the expansion only ever runs inside a piece that `case` says holds one.
  # Two sizes of piece, because taking a piece out of the text costs the length of the text as well: a block is
  # taken from the whole text, and the small pieces from the block.
  local LC_ALL=C
  local i=0 j n=${#1} kl=${#2} B=262144 C=4096 b bn c pre
  _JF=-1
  while [ "$i" -lt "$n" ]; do
    b="${1:i:B+kl-1}"
    case "$b" in *"$2"*)
      j=0; bn=${#b}
      while [ "$j" -lt "$bn" ]; do
        c="${b:j:C+kl-1}"
        case "$c" in *"$2"*) pre="${c%%"$2"*}"; _JF=$((i+j+${#pre})); return 0 ;; esac
        j=$((j+C))
      done ;;
    esac
    i=$((i+B))
  done
}
_json_slice(){  # $1 = whole payload, $2 = key -> the raw (still JSON-escaped) string value, "" if absent
  local LC_ALL=C   # FIRST, so every expansion below -- the key search included -- counts and cuts in bytes.
                   # Lengths from ${#x} are used as offsets into ${y:n}; with the locale set before any of
                   # them, the two never disagree about a unit. Walking bytes is safe because no UTF-8
                   # continuation byte can be 0x5C or 0x22, so a cut cannot land inside a character at a
                   # quote or backslash edge. What this line is worth in SPEED depends on the platform --
                   # read the table in _json_unescape below before quoting a number for it.
  local pre rest seg w r n base=0 j=0 cl lim run=0 chunk C=4096 W=256 hay="$1" k="\"$2\""; local -a acc=("")
  # It ALSO sets `_JS`, so a caller on the hot path can read the value without `$( )`, which is a fork. The
  # printf stays because the existing callers compose it (`_json_unescape "$(_json_slice …)"`), but the one
  # caller that used to do its own fork-free extraction — `_CWD` — reads `_JS` and keeps costing nothing.
  _JS=""
  # Every "step past X" here is arithmetic on a length, never `${s#"$literal"}`. That shape reads like a
  # constant-time strip and is not one: bash retries the pattern at every prefix length, so stripping an
  # n-byte literal costs O(n^2). It was in this function twice, and both were measured:
  #   * `${1#*"$2"}` found the key -- cheap when the key sits near the front, quadratic in the distance to it
  #     otherwise. `permission_mode` behind a 100 KB command took 7.94s on Git Bash, 0.27s in front of it.
  #     Captured from Claude Code 2.1.267, the real order puts `permission_mode` BEFORE `tool_input`, so on
  #     that version this cost was not reachable -- this file's header had shown the opposite order, and was
  #     wrong. The parse stays order-independent regardless: the order is not a documented contract, and the
  #     payload is still moving (`effort` is absent from the field list recorded on 2.1.246).
  #   * `${tail#"$seg"\"}` stepped past each escaped quote: 16.8s for a single 100 KB step on Git Bash,
  #     against 0.002s for `${tail:${#seg}+1}` doing exactly the same thing.
  # _json_find gives the FIRST occurrence. THAT ALONE IS NOT ENOUGH, and the sentence that used to stand here said it was: it claimed a
  # command "containing the literal text `\"command\":\"` still cannot relocate the parse", which is true of
  # that byte sequence and irrelevant, because this search is for `"command"` WITHOUT the colon. A JSON VALUE
  # equal to the key name is exactly those bytes between two unescaped quotes. Measured on the shipped hook:
  #   {"tool_name":"Bash","a":"command","ls":1,"tool_input":{"command":"rm -rf /"}}   ->  read `ls`
  #   {"a":"permission_mode","default":1,"permission_mode":"bypassPermissions",…}     ->  read `default`
  #   {"a":"file_path","/tmp/ok":1,"tool_input":{"file_path":".claude/hooks/x.sh"}}   ->  read `/tmp/ok`
  # In each case the gate judged a harmless string while a dangerous one was the actual argument, and jq read
  # the real value -- so on a stock Windows desktop, where this was already the only parser, the gate could be
  # aimed with one extra key. The loop below therefore accepts an occurrence only when optional JSON whitespace
  # and then `:` follow it, which is the only place a key can appear; everything else keeps searching.
  # Stepping by length removed the quadratic strip, but each escaped quote still sliced and re-assigned the
  # whole remainder, so an escape-dense command stayed k*n here as well (2.2s of the 6.8s described in
  # _json_unescape below, on Git Bash). The walk is chunked the same way: the payload is read 4096 bytes at a
  # time and every per-quote operation stays inside the chunk. One thing is carried across edges on purpose
  # -- the length of the backslash run in front of a quote -- because that run can straddle a window or a
  # chunk, and its parity is what decides whether the quote ends the value. Isolated, escape-dense 44030 B:
  # 2.61s -> 0.41s on Git Bash 5.3.15, 0.93s -> 0.09s on macOS/bash 3.2.
  # Output is byte-identical to the previous shape across 378 cases at four chunk/window sizes down to 7 and 1
  # bytes, and that shape to the one before it across a 27-case battery (escaped quotes, backslash runs before
  # a quote, the key twice, the key appearing first as a value, glob metacharacters, UTF-8, no closing quote,
  # empty input). Broken twins -- the run not carried across a window, a byte skipped after a quote -- prove
  # the battery sees both.
  # THE NUMBER OF PASSES IS CAPPED, for the same reason guard-write caps the path length: an unbounded cost on
  # a PreToolUse hook is a gate with an off switch, because a hook killed at its timeout emits no exit 2.
  # Each decoy costs one more `%%` scan over the remainder, so the work is quadratic in the number of decoys.
  # Measured on macOS/bash, single call, `"k<i>":"command"` decoys in front of the real key:
  #      50 decoys    844 B    12 ms        800 decoys   13544 B    126 ms
  #     200 decoys   3344 B    19 ms       3200 decoys   56544 B   1839 ms
  # Git Bash's parameter expansion is several times slower again, so the tail is where the timeout lives. A
  # real payload carries ZERO decoys -- 64 is far above anything a producer can legitimately emit -- and going
  # over the cap is reported SEPARATELY (`_KC_CAPPED`), not as a large count, so the caller can refuse with a
  # reason the reader can act on instead of a sentinel dressed up as a measurement. Fail-closed either way.
  # THE COST IS ONE THIS CHANGE INTRODUCES, and it is worth saying so plainly rather than implying the cap
  # protects something pre-existing: before the colon requirement the scan STOPPED at the first occurrence, so
  # decoys cost essentially nothing (measured on stock Windows: 0 decoys 0.18 ms, 3200 decoys 1.60 ms per call,
  # roughly linear) -- and it read the decoy, which is the hole. The cap is load-bearing for the new cost, so
  # raising or removing it later is not a tidy-up.
  # The bound is on the LOOP, not on the payload, so an ordinary command pays nothing: the same 56572 B flood
  # is refused in 93-94 ms with jq/python3 present and 168-169 ms on the slice path this paragraph is about,
  # both far inside the 60s timeout these hooks had when this was measured, while a 46 KB legitimate command is 325 ms on macOS -- a figure that
  # predates this change and belongs to the walk, not to the cap.
  local _cap=64 _seen=0
  while :; do
    _json_find "$hay" "$k"                     # where the next `"key"` starts
    [ "$_JF" -ge 0 ] || return 0               # no further occurrence: emit nothing
    _seen=$((_seen+1)); [ "$_seen" -le "$_cap" ] || return 0
    rest="${hay:_JF+${#k}}"                    # past `"key"`
    while [ -n "$rest" ] && [[ "${rest:0:1}" == [$' \t\n\r'] ]]; do rest="${rest:1}"; done
    case "$rest" in
      :*) rest="${rest:1}"; break ;;           # whitespace then `:` -- this occurrence IS the key
      *)  hay="$rest" ;;                       # a value, or another token: keep looking
    esac
  done
  # THE VALUE MUST BE A STRING. `"command":123}}` used to come back as the literal text `:123}}` -- the old
  # shape skipped forward to the next quote wherever it was, so a non-string value handed the matchers the
  # payload's own punctuation to judge. Emitting nothing instead lets the caller's "no readable command"
  # refusal fire, which is the honest answer for a value these gates cannot read.
  while [ -n "$rest" ] && [[ "${rest:0:1}" == [$' \t\n\r'] ]]; do rest="${rest:1}"; done
  case "$rest" in '"'*) rest="${rest:1}" ;; *) return 0 ;; esac
  # Walk to the closing quote that is NOT escaped. A `"` preceded by an odd number of backslashes is content.
  n=${#rest}; chunk="${rest:0:C}"; cl=${#chunk}
  while :; do
    lim=$((cl - j))
    if [ "$lim" -le 0 ]; then
      [ $((base + cl)) -lt "$n" ] || break                 # no closing quote at all: everything is already taken
      base=$((base + j)); chunk="${rest:base:C}"; cl=${#chunk}; j=0; continue
    fi
    [ "$lim" -le "$W" ] || lim=$W
    w="${chunk:j:lim}"
    seg="${w%%\"*}"
    if [ "$seg" = "$w" ]; then                             # no quote in view: take all of it, carry the run
      acc+=("$w"); j=$((j+lim))
      r="${w##*[!\\]}"; case "$w" in *[!\\]*) run=${#r} ;; *) run=$((run+${#w})) ;; esac
      continue
    fi
    acc+=("$seg"); j=$((j+${#seg}+1))
    r="${seg##*[!\\]}"; case "$seg" in *[!\\]*) run=${#r} ;; *) run=$((run+${#seg})) ;; esac
    if [ $((run % 2)) -eq 1 ]; then acc+=("\""); run=0; else break; fi
  done
  local IFS=''; _JS="${acc[*]}"; printf '%s' "$_JS"
}
_json_unescape(){  # left-to-right, a chunk at a time; a two-pass sed would corrupt `\\"` (escaped backslash + quote)
  # This is the tier-3 path below -- the one a stock Windows install actually runs on. It used to walk ONE
  # CHARACTER at a time, which is O(n^2) twice over: `${s%"${s#?}"}` matches a pattern the length of the
  # entire remainder just to read one character, and `out="$out$c"` recopies the output for each one.
  #
  # That was not a comfort question. This hook's timeout was 60s then -- set in settings.json (600s since 3.1.0), NOT Claude Code's
  # default, and reading the default instead is how a first pass at this got the consequence wrong. A
  # PreToolUse hook KILLED at its timeout emits no exit 2, so every rule below is simply skipped. Measured on
  # the tier-3 path with jq and python3 both shadowed, the old shape crossed 60s at ~4.3 KB. And 4.3 KB is
  # not exotic: across 6791 Bash calls in 280 real transcripts, 2.49% of commands are bigger, and the largest
  # is 46815 B, which the old shape needed roughly 39 minutes to decode. One Bash call in forty walked past
  # §4.4 and §4.5 entirely, silently, on every stock Windows desktop.
  #
  # Two changes, and their wins are NOT the same shape -- writing them down as one number was the mistake
  # this comment exists to avoid repeating:
  #   * Taking the whole run up to the next backslash in ONE expansion, and indexing with `${s:0:1}` instead
  #     of matching a pattern, is 47x on a 4.4 KB payload. This one holds on every machine.
  #   * `local LC_ALL=C` makes these expansions byte-oriented instead of re-decoding the string on every
  #     substring operation. What that is WORTH depends on the platform, and putting a single number here
  #     would have been wrong three separate ways -- it was written as "another 5x" twice before this:
  #         macOS / bash 3.2, a locale set .................. 5x
  #         Git Bash 5.3.15, a locale set ................... 1.23x   (measured on the OLD shape; the new one
  #                                                                    touches the locale once per escape
  #                                                                    rather than once per character, so its
  #                                                                    ratio is smaller and unmeasured)
  #         Git Bash, LANG empty -- what Claude Code starts .. nothing at all
  #     So speed is not what keeps this line; CORRECTNESS is, and that half holds everywhere. `[0-9a-fA-F]`
  #     below is a collation-defined range outside the C locale: on a tr_TR desktop it is not 0-9a-f. That
  #     alone would justify the line, and it costs nothing. `local` restores the previous locale on return
  #     -- verified on bash 3.2 and on Git Bash 5.3.15, not assumed.
  #
  # Then the cost moved rather than went away. With the per-character walk gone, each escape still sliced the
  # whole REMAINDER -- `s="${s:${#pre}+1}"` -- so an escape-dense command stayed k*n: on Git Bash a 44080 B
  # command with 2755 escapes took 6.8s, 11% of the timeout. The input is now touched only a chunk at a time
  # (`${s:base:C}`, once per 4096 bytes) and every per-escape operation stays inside that chunk, so no escape
  # pays for the length of the whole command. That is the change that matters: bounding only the lookahead,
  # while still indexing the full string, was measured too and gave about 4x on both machines, against 6-12x
  # for the chunked walk. Five bytes are held back at a chunk's end whenever more input follows, so a
  # `\uXXXX` that starts in a chunk ends in it.
  # The output goes into an array joined once, not a string recopied at every append, and `\n`/`\t` are
  # written `$'\n'`/`$'\t'`, so this file carries no raw TAB for an editor or a copy to turn into spaces.
  #
  # Measured, isolated, previous shape -> this one:
  #     macOS/bash 3.2   escape-dense 44030 B, 2590 escapes .. 1.44s -> 0.12s
  #                      sparse 100014 B, 4 escapes ........... 0.09s -> 0.02s
  #     Git Bash 5.3.15  escape-dense 44030 B, 2590 escapes .. 3.92s -> 0.54s
  #     (LANG empty)     sparse 99997 B, 4 escapes ............ 0.49s -> 0.07s
  # These numbers do not travel, which is why each one names its machine.
  #
  # Output is byte-identical to the previous shape across 478 cases, each run at four chunk/window sizes
  # down to 7 and 1 bytes so that an edge falls every few bytes; that shape was itself byte-identical to
  # the original character walk across a 31-case battery (escaped quotes, `\\`, a lone trailing backslash, a
  # truncated `\u`, Turkish, emoji). Deliberately broken twins -- the 5-byte margin cut to 4, the backslash
  # not stepped over -- prove the battery sees both edges, and tier 1 and tier 3 return the same verdict on
  # the gate cases.
  local LC_ALL=C
  local s="$1" pre w c h n base=0 j=0 cl lim chunk C=4096 W=256; local -a acc=("")
  case "$s" in *\\*) ;; *) _JU="$s"; printf '%s' "$s"; return 0 ;; esac   # no escapes: the common case pays nothing
  n=${#s}; chunk="${s:0:C}"; cl=${#chunk}
  while :; do
    lim=$((cl - j))
    if [ $((base + cl)) -lt "$n" ]; then                  # more input after this chunk: hold 5 bytes back, so
      lim=$((lim - 5))                                     # a `\uXXXX` that starts in a chunk also ends in it
      if [ "$lim" -le 0 ]; then base=$((base + j)); chunk="${s:base:C}"; cl=${#chunk}; j=0; continue; fi
    else
      [ "$lim" -gt 0 ] || break
    fi
    [ "$lim" -le "$W" ] || lim=$W
    w="${chunk:j:lim}"
    pre="${w%%\\*}"                                        # the literal run before the next backslash in view
    if [ "$pre" = "$w" ]; then acc+=("$w"); j=$((j+lim)); continue; fi
    acc+=("$pre"); j=$((j+${#pre}+1))
    if [ $((base + j)) -ge "$n" ]; then acc+=("\\"); break; fi   # a lone trailing backslash stays literal, as before
    c="${chunk:j:1}"; j=$((j+1))
    case "$c" in
      n) acc+=($'\n') ;;
      t) acc+=($'\t') ;;
      r) ;;
      b|f) acc+=(" ") ;;
      u) if [ $((n - base - j)) -ge 4 ]; then h="${chunk:j:4}"; j=$((j+4)); else h=""; fi   # a short tail is left alone, as before
         # A `\uXXXX` used to become a literal `?`. That is not a lossy nicety, it is a hole: `\u002e` is `.`,
         # so `\u002eclaude/hooks/guard-bash.sh` decoded to `?claude/…` and matched no gate pattern, while jq
         # decoded the same bytes to the real path — the two tiers disagreed on whether a payload was an
         # attack. Printable ASCII is decoded properly (builtin printf, no fork); anything else still becomes
         # `?`, which is only ever a display concern because this value is used for MATCHING, never to write.
         case "$h" in
           00[2-7][0-9a-fA-F]) printf -v c "\\x${h#00}"; acc+=("$c") ;;
           # The three dashes PowerShell accepts in front of a parameter name, as themselves: as `?` they hid
           # `\u2013Recurse \u2013Force` from the delete rule, while the same bytes sent raw were caught.
           2013) acc+=("–") ;; 2014) acc+=("—") ;; 2015) acc+=("―") ;;
           *)                  acc+=("?") ;;
         esac ;;
      *) acc+=("$c") ;;
    esac
  done
  # ALSO sets `_JU`, for the same reason `_json_slice` sets `_JS`: a caller on the hot path reads the value from it
  # and sends this printf to /dev/null, instead of paying a `$( )` — a fork — on every tool call.
  local IFS=''; _JU="${acc[*]}"; printf '%s' "$_JU"
}
_json_keycount(){  # $1 = payload, $2 = key -> sets _KC to how many times it occurs AS A KEY
  # IT SETS A VARIABLE INSTEAD OF PRINTING, and that is not a style choice. Written as `n="$(_json_keycount
  # …)"` first, which is a command substitution, which is a FORK -- on a hook that runs before every Bash and
  # every Write call. Measured on macOS/bash, typical payload, 200 reps: the substitution form cost 0.790 ms
  # per call against 0.090 ms for the raw byte test it replaces, and the whole hook went 15.00 -> 16.58 ms.
  # This project's own recorded Git Bash process cost is 62-135 ms, rising to ~400 ms under load, so three
  # added forks per call would have been a freeze on the platform the change is meant to protect. Setting _KC
  # keeps the count in the caller's own shell: expansion only, zero forks.
  # The counter the ambiguity refusals need, and it exists because the hand-written byte test they used to do
  # looked for a DIFFERENT token than the parser above: `"key":` compact, while the parser searches `"key"` and
  # tolerates whitespace before the colon. Two consequences, both measured on the shipped hook:
  #   * `{…"meta":{"command":"ls"},"tool_input":{"command" : "rm -rf /"}}` -- ONE SPACE and the duplicate-key
  #     refusal went blind while the parser happily read the first value.
  #   * a key name appearing as a VALUE was counted as an occurrence by neither, which is the hole the parser
  #     above now closes; counting the same form here is what keeps the two from drifting apart again.
  # Sharing ONE definition with the parser is the point: a guard that searches for something else than the
  # thing it guards is the defect, not an implementation detail.
  # WHAT THE TOKEN CAN BE, stated correctly. An earlier version of this comment said the bytes `"command"`
  # with both quotes unescaped "can only be a key or a value equal to the key name". That is wrong, and the
  # counter-example was found by review, not by reasoning: a KEY whose own name ends with a quote spells the
  # token out of its escaped quote plus the string's terminator --
  #   {"tool_input":{"x\"command":"DECOY","command":"rm -rf /"}}   slice -> DECOY, count -> 2
  # which is refused BECAUSE the count sees two, not because the invariant held. The same shape as a VALUE is
  # harmless (a string's terminator is followed by `,` `}` `]`, never `:`, so it is skipped and not counted:
  #   {"description":"ends with \"command","command":"rm -rf /"}    slice -> rm -rf /, count -> 1 ).
  # What IS true, and is what keeps ordinary work from being refused: content can contribute at most one
  # occurrence per string and only as that string's tail, where the next byte is never a colon. Measured on 19
  # payloads built by a real JSON encoder -- `grep -rn '"command":' .`, a heredoc writing a hooks.json, `sed`
  # over settings.json, a commit message quoting the word, commands ending in `"command` -- every count <= 1.
  # Same pass cap as the slice, and over-cap reports AMBIGUOUS rather than a true count: the callers refuse on
  # `> 1`, so a payload built to outrun the loop is refused instead of being timed out past the gate.
  local LC_ALL=C hay="$1" k="\"$2\"" rest c=0 _cap=64 _seen=0
  _KC=0; _KC_CAPPED=0
  while :; do
    _json_find "$hay" "$k"
    [ "$_JF" -ge 0 ] || { _KC=$c; return 0; }
    # OVER-CAP IS ITS OWN ANSWER, not a large count. `_KC_CAPPED` lets the caller say what actually happened:
    # the occurrences it stopped at are candidate positions, key-form or not, so calling them "65 keys" was a
    # sentinel dressed up as a measurement and the remedy it offered ("send one key") was already satisfied.
    _seen=$((_seen+1)); [ "$_seen" -le "$_cap" ] || { _KC=$((_cap+1)); _KC_CAPPED=$_cap; return 0; }
    rest="${hay:_JF+${#k}}"
    while [ -n "$rest" ] && [[ "${rest:0:1}" == [$' \t\n\r'] ]]; do rest="${rest:1}"; done
    case "$rest" in :*) c=$((c+1)) ;; esac
    hay="$rest"
  done
}
# ---- /CREW-JSON-PARSE -----------------------------------------------------------------------------------
# ---- _gsub: `${text//pattern/replacement}` that stays LINEAR ----------------------------------------------
# bash rebuilds the whole string for every match of a global substitution, so its cost is matches x length. On a
# quote-dense 46 KB command each `${CMD//\"/}` took about 9 s (bash 3.2, measured with a DEBUG trap), and this hook
# did ten of them: 335 s for one commit, against a 600 s timeout that does not block when it is reached. The same
# substitution done 2048 bytes at a time costs matches x 2048. Safe for a pattern of ONE character anywhere; for the
# two-character patterns that begin with a backslash, pass `bs` and a piece never ends on a backslash.
_gsub(){  # $1 = text, $2 = pattern (a glob, as it would stand in ${x//HERE/}), $3 = replacement, $4 = bs -> _GS
  local LC_ALL=C
  local t="$1" n i=0 C=2048 c; local -a acc=("")
  n=${#t}
  if [ "$n" -le "$C" ]; then _GS="${t//$2/$3}"; return 0; fi
  while [ "$i" -lt "$n" ]; do
    c="${t:i:C}"; i=$((i+C))
    if [ "${4:-}" = bs ]; then while [ "$i" -lt "$n" ] && [ "${c: -1}" = '\' ]; do c="$c${t:i:1}"; i=$((i+1)); done; fi
    acc+=("${c//$2/$3}")
  done
  local IFS=''; _GS="${acc[*]}"
}
# The text as the shell hands it on once the quoting is gone: `core.hooks"P"ath`, `crewforth-appr\oval` and
# `'git' commit` are core.hooksPath, crewforth-approval and git commit. Every rule that matches a NAME matches on this.
_unquoted(){  # $1 = text -> _GS: no double quote, no single quote, no backslash
  _gsub "$1" '\"' ''; _gsub "$_GS" "\\'" ''; _gsub "$_GS" '\\' ''
}
# ONE READER, EVERYWHERE. This hook used to try jq, then python3, then the slice above, choosing a tier on
# whether its extraction WORKED rather than on whether the binary existed. That was already the second fix to
# the selection logic, and the ladder stayed the root cause of four separate incidents. It is gone.
#
# WHAT THE TIERS COST, all measured:
#   * jq on CI. GitHub's windows-latest image HAS jq preinstalled, so every Windows verification ran on tier 1
#     — a path no Windows user is on. A misfiring force-push regex therefore shipped green.
#   * The python3 that is not python. On a stock Windows 11 desktop (Git Bash 5.3.15, no Python installed)
#     Windows puts %LOCALAPPDATA%\Microsoft\WindowsApps\python3 on PATH BY DEFAULT. It is the Microsoft Store
#     redirector stub: `command -v python3` succeeds, the stub writes "Python was not found" to stderr (which
#     `2>/dev/null` swallows) and exits 49 with an EMPTY stdout. CMD came back "", `[ -z "$CMD" ] && exit 0`
#     fired, and the hook ALLOWED the call — silently, in every mode, nothing in any log. On that machine
#     `rm -rf /`, `git push --force`, the PowerShell §4.5 twins below and a Write that rewrites THIS FILE all
#     returned rc=0.
#   * The tier nobody could test. Tier 1 was verified on CI, tier 3 by stripping PATH on macOS/Linux, and
#     tier 2 — the one every Windows user was actually on — nowhere.
#   * AND ONE HOLE NO PARSER FIX CAN REACH, which is what this deletion is for rather than the costs above.
#     `{"tool_input":{"foo":1},"meta":{"command":"rm -rf /"}}`: jq reads `.tool_input.command`, finds nothing,
#     sets CMD="" and marks the payload parsed, so the reader that CAN see the sibling key never runs. Probed
#     inside the hook: `CMD=[]` for that payload against `CMD=[rm -rf /]` for the compact one, rc=0 against
#     rc=2. Measured on both platforms, with and without the ladder: of the seven reader defects the
#     conformance oracle knows, the shared-token fix closes SIX and this one closes only when the ladder goes.
#     That is also why the order was forced — deleting first would have left the six open with no second
#     reader to catch any of them.
#
# Deleting the ladder does not make the slice safer; it makes it the path EVERY run exercises. Stock Windows
# was already alone on it, which is precisely why it was the least-tested code in the gate. Now CI, both
# verify-cross jobs and every session here run the same bytes the Windows desktop runs.
#
# The evidence is `eval/parser-conformance.sh` (run by `verify.sh parser`), which compares this reader against
# a real parser row by row in both modes: 73 rows with the ladder, 72 with one reader, 0 divergent, 0
# unmeasurable. Cost on the hot path, measured on stock Windows: the two process spawns that used to precede
# the slice on every single Bash call are gone (-1 fork per hook per call), and `guard-bash · ls -la` went
# 376 ms -> 169 ms with no overlap between the two columns, because the Store stub was being spawned and
# failing on every call.
# Through `_JS` / `_JU`, not `$( )`: these three reads were three forks on every Bash and PowerShell call (3.1.0).
_json_slice "$INPUT" command >/dev/null; CMD_RAW="$_JS"; _json_unescape "$_JS" >/dev/null; CMD="$_JU"   # CMD_RAW: the command as the payload spells it
_join_cmd                                # continued lines joined, as the shell runs them (CREW-JOIN)
_json_slice "$INPUT" permission_mode >/dev/null; PERM_MODE="$_JS"

# AN UNREADABLE PAYLOAD IS REFUSED, NOT WAVED THROUGH. Both shapes below were found by the parser-conformance
# oracle, which compares this gate's verdict on the dependency-free tier against a real parser's, and both fell
# the same way: tier 3 allowed, a real parser blocked. Neither is reachable from a live session today — Claude
# Code builds the payload and `tool_input` is flat with plain key names — so these are latent fragilities, and
# they matter because the dependency-free tier is the ONLY tier on a stock Windows desktop and is proposed as
# the only tier everywhere.
#
# The test is the raw byte sequence `"command":`, and it is sound for VALID JSON for one reason: inside a JSON
# string a quote must be escaped, so those bytes cannot occur inside a value — `\"command\":\"` does not match.
# That is why the oracle's "a literal `\"command\":\"` inside another value" case still parses normally here
# rather than being refused: it carries ONE occurrence, the real key.
#
#   * MORE THAN ONE occurrence -> the key appears twice (RFC 8259 leaves duplicate names undefined: this slice
#     takes the first, jq and python take the last) or once nested and once real
#     (`{"meta":{"command":"ls -la"},"command":"rm -rf /"}` reads the harmless one). Either way the value is a
#     GUESS, and a gate that guesses is a gate that can be aimed. Checked on the RAW payload rather than only on
#     the tier-3 path, deliberately: refusing on one tier while another reads the last value and allows would
#     just move the divergence instead of closing it.
#   * NO occurrence while the payload names a tool this hook gates -> the key is spelled in a way the slice
#     cannot see (`command` decodes to `command` for a real parser) or the format moved. Either way the
#     honest report is "I could not read this", and until now that produced `exit 0` — the gate silently absent,
#     which is indistinguishable from a session where nothing dangerous was attempted.
#
# Deliberately LOUD, chosen with the trade-off stated rather than assumed: if the payload format ever moves,
# every Bash call on a stock Windows desktop stops with the reason on screen, instead of the gate quietly
# ceasing to exist. `gatelog` is not available this early (it resolves its path from the payload's cwd, parsed
# further down), so these two refusals are stderr-only — the one place in this file where a verdict is not
# logged, and it is a limit rather than a choice.
_json_keycount "$INPUT" command; _n_cmd=$_KC; _cap_cmd=$_KC_CAPPED
if [ "$_cap_cmd" != 0 ]; then
  echo "GUARD (§4.4/§4.5): this payload contains more than $_cap_cmd occurrences of \"command\", so the" >&2
  echo "scan for the real key was stopped. Refusing rather than reading whichever one it had reached." >&2
  exit 2
elif [ "$_n_cmd" -gt 1 ]; then
  echo "GUARD (§4.4/§4.5): this payload carries $_n_cmd \"command\" keys, so the command to judge is" >&2
  echo "ambiguous." >&2
  echo "Refusing rather than guessing which one runs. If you meant one command, send one key." >&2
  exit 2
fi
# THE SAME REFUSAL FOR `permission_mode`, because §4.4's entire fail-closed branch is selected by that one
# value and this parser takes the FIRST occurrence. Measured in a §4.6-clean cwd, command `git commit -m x`,
# real mode bypassPermissions: with a nested `"permission_mode":"default"` placed EARLIER the hook read
# `default` and emitted `ask` instead of failing closed — and in `bypassPermissions` the harness answers `ask`
# with `allow` itself, so the commit ran. One occurrence is the real shape and stays silent; ABSENT is not
# refused, because older CLI builds omit the key and §4.4 already treats an unknown mode as one that cannot
# prompt. Only ambiguity is refused.
_json_keycount "$INPUT" permission_mode; _n_pm=$_KC
if [ "$_n_pm" -gt 1 ]; then
  echo "GUARD (§4.4): this payload carries $_n_pm \"permission_mode\" keys, so the mode that decides" >&2
  echo "is ambiguous. Refusing rather than reading whichever comes first." >&2
  exit 2
fi
# THE REFUSAL BELOW FIRES ONLY WHEN THE KEY IS ABSENT ALTOGETHER, which is what the byte test it replaces
# meant. Firing it on "CMD is empty" instead would be a NEW over-block class: exactly one `"command"` key
# whose value is `""`, a number, or an object reads as empty now that the parser refuses non-strings, and the
# shipped hook let those through. Not reachable from Claude Code either way; the point is that tightening the
# parser must not quietly widen a refusal.
if [ "$_n_cmd" = 0 ] && [ -z "$CMD" ]; then
  # TWO INDEPENDENT WAYS TO ANSWER "IS THIS A GATED TOOL", and the refusal fires if EITHER says yes. The raw
  # byte test alone was defeated by one space, measured with an unreadable command key:
  #   {"tool_name":"Bash","tool_input":{"foo":1}}      rc=2   refused
  #   {"tool_name": "Bash","tool_input":{"foo":1}}     rc=0   ALLOWED  <- one space after the colon
  #   {"tool_name":"Read","tool_input":{"foo":1}}      rc=0   allowed  (not a gated tool — the control)
  # The harness routes the event on the PARSED tool name, so a producer that pretty-prints its JSON would
  # silently lose this safety net — and this net is what stands between "the payload format moved" and "an
  # unjudged command ran". BOTH tests are kept rather than replacing the bytes with the parser: replacing them
  # couples this net to the very parser whose failure it exists to catch, while the union only ever widens the
  # refusal, which is the fail-CLOSED direction.
  # THREE arms, because the first two were each defeated on their own — measured on the slice path with jq and
  # python3 shadowed, i.e. the stock-Windows shape, all against a payload with no readable command key:
  #   {"tool_name":"Bash",…}                                  bytes hit            rc=2
  #   {"tool_name": "Bash",…}                                 bytes MISS, slice hit rc=2
  #   {"meta":{"tool_name":"Read"},"tool_name": "Bash",…}      both MISS            rc=0  <- the third arm
  # The third shape defeats the slice arm because the slice takes the FIRST occurrence, so a decoy tool name
  # placed earlier answers for the real one. Ambiguity gets the same treatment as everywhere else in this
  # file: an unreadable payload whose tool identity is ALSO ambiguous is refused, not guessed at. Scoped to
  # this branch on purpose — an ordinary payload carries exactly one `tool_name`, and a command string cannot
  # synthesise a second one, because inside a JSON string every quote is escaped.
  _gated=""
  case "$INPUT" in *'"tool_name":"Bash"'*|*'"tool_name":"PowerShell"'*) _gated=bytes ;; esac
  [ -n "$_gated" ] || case "$(_json_slice "$INPUT" tool_name)" in Bash|PowerShell) _gated=slice ;; esac
  if [ -z "$_gated" ]; then _json_keycount "$INPUT" tool_name; [ "$_KC" -le 1 ] || _gated=ambiguous; fi
  if [ -n "$_gated" ]; then
    echo "GUARD (§4.4/§4.5): this payload names a gated tool but no readable \"command\" key, so nothing" >&2
    echo "judged. Refusing rather than allowing an unread command. If the payload format has changed," >&2
    echo "the hook needs updating — run the commit or the command yourself in your terminal meanwhile." >&2
    exit 2
  fi
fi
[ -z "$CMD" ] && exit 0
_unquoted "$CMD"; CMD_UQ="$_GS"      # read by the name rules below (hooksPath side doors, the approval record)


# $1 = rule name · $2 = section · $3 = CLASS, which decides the second line.
#
# ONE SENTENCE FOR 33 RULES WAS WRONG THREE WAYS, and the third one is why this is not cosmetic. It read
# "This destructive operation is only performed if the user EXPLICITLY requests it. If approved, run the
# command manually in the terminal."
#   * The adjective was false for most of them. Reading a .env, `git rebase`, `commit --amend` and
#     `git add -f` destroy nothing.
#   * For the tamper and secret classes the ADVICE WAS THE VIOLATION. "If approved, run it manually" told
#     the reader to disarm the hooks by hand, or to cat the .env themselves — the two things those rules
#     exist to stop. A gate that ends by describing how to perform the thing it just refused is not a gate.
#   * A single sentence cannot name the legitimate route, because the legitimate route is different for
#     every class. Naming it is the whole value of the line.
#
# THE REFUSAL IS NOT THE END OF THE TASK — and that line is in the `loss` arm because it was MEASURED, not
# because it reads well. The paid A/B, `destructive-refused`, three runs, user asked explicitly to clean the
# working tree:
#     kit  0/3 the junk is still there (the request was never carried out) · 3/3 uncommitted notes survived
#     bare 3/3 the junk was cleaned      · 3/3 uncommitted notes survived
#     gate fired: BLOCK §4.5 git clean -f
# The bare arm is the control and it settles the reading: a SAFE completion existed, so "the agent did not do
# it" is not caution. The gate bought nothing here — both arms protected the same notes — and cost the whole
# request, 3 times out of 3. Before this the same story had been attached to `no-secret-logging`, where at
# n=3 no gate fired at all; one case makes it noise and the other makes it a pattern, which is why the clause
# is written now and was not written an hour ago.
#
# ONLY the `loss` arm carries it. The other six have no reproduced failure of this shape, and a sentence
# added to all seven because it sounds right is the same mistake as one sentence serving all thirty-three.
#
# UNMEASURED, said plainly: whether this wording changes what a session does. Its criterion is already
# written — Crewforth arm's first row must move off 0/3 while the other two stay at 3/3. A fix that clears the
# junk and loses the uncommitted notes is worse than the block it replaced.
#
# What DID stand on its own is everything above: the single sentence was wrong on inspection, never needed an
# experiment, and is pinned by three assertions in the suite.
#
# An unclassified call is LOUD rather than silent: it prints (unclassified) and the suite pins that every
# call site passes a class. A default that reads plausibly is how the old single sentence survived.
block(){
  gatelog BLOCK "$2" "$1"
  echo "GUARD (§$2): '$1' stopped AT THE TOOL LEVEL." >&2
  [ -z "${_BLOCK_NOTE:-}" ] || echo "$_BLOCK_NOTE" >&2
  case "${3:-}" in
    loss)     echo "Nothing here is undone by retrying — but the refusal is not the end of the task. Do the same job the reversible way: name the paths instead of sweeping, and look first (git clean -n, ls) so you act on what you can see. Only if the broad form is genuinely required does the user run it in their own terminal." >&2 ;;
    history)  echo "This rewrites or discards work that is already committed. Ask the person who shares the branch; a new commit usually reaches the same end without rewriting." >&2 ;;
    tamper)   echo "Turning a gate off is not a step in any task, and DOING IT BY HAND IS NOT THE ANSWER EITHER — a gate disarmed by hand stays off for every later session. If a rule is wrong, change the rule and say so." >&2 ;;
    secret)   echo "The value does not belong in a transcript, so printing it by hand is the same leak with an extra step. If the task truly needs it, the user supplies it out of band." >&2 ;;
    bypass)   echo "The ignore rule is deliberate. If the file genuinely belongs in the repository, change .gitignore in the same commit so the decision is reviewable." >&2 ;;
    exec)     echo "This runs code that nobody has read. Download it, read it, then run the local copy." >&2 ;;
    exposure) echo "This widens access for every user on the machine, not just this session. Grant the narrowest mode that works." >&2 ;;
    approval) echo "This needs a person to say yes and this session has no way to put the prompt in front of one. Either the user switches to default/acceptEdits with Shift+Tab — in this session, no restart — or the NEXT session starts with CLAUDE_GIT_OK=1. The key is set by the user before the session; it cannot be set from inside the command." >&2 ;;
    *)        echo "(unclassified rule — this block carries no recovery line; that is a defect in the hook, not in your command.)" >&2 ;;
  esac
  exit 2
}

# `printf '%s' "$2" | grep -q[i]E "$3"` without the process. Measured on a Windows 11 machine under load: one bare
# `bash` cost 1.3-3.9 s there, and `git status` walked this hook through 14 processes (13 greps + the stdin cat),
# 37-66 s per call; on macOS the same walk is ~38 ms. The rules below keep their regex TEXT unchanged and only
# change who runs it: the shell's own ERE matcher, fed one line at a time because grep matches per line — `^`/`$`
# anchor at each line and no class ever spans a newline, which a whole-string [[ =~ ]] would get wrong. Case
# folding is nocasematch, restored to what it was, so it cannot leak into a later `case` (see git_has).
_ere() {  # $1 = i (fold case) | s ; $2 = text ; $3 = ERE ; $4 = glob a matching line must contain (a superset of a literal the ERE requires)
  local rc=1 nc=0 line n=0 g="${4:-*}"
  case "$2" in
    *$'\n'*)
      # Split once (`read -a`), keep only lines carrying the literal, and let the shell match those. bash compiles the
      # regex on every =~, so a regex per line is a regcomp per line: a 2,000-line heredoc took 70 s that way (measured).
      # Past 64 candidate lines one grep — compiled once, one process — is cheaper; fed from a here-string, not a pipe,
      # so an early `grep -q` exit cannot SIGPIPE the writer and flip the verdict under pipefail.
      [[ $2 == $g ]] || return 1            # the literal is nowhere in the text: no line can match
      # git_has alone asks ~10 questions of the same command; the split-and-filter is cached for the last (text, glob).
      if [ "$2" != "${_ERE_T-}" ] || [ "$g" != "${_ERE_G-}" ]; then
        local -a _el; _ERE_C=(); _ERE_T="$2"; _ERE_G="$g"
        IFS=$'\n' read -r -d '' -a _el <<< "$2"
        for line in ${_el[@]+"${_el[@]}"}; do [[ $line == $g ]] && _ERE_C[${#_ERE_C[@]}]="$line"; done
      fi
      n=${#_ERE_C[@]}
      if [ "$n" -gt 64 ]; then
        if [ "$1" = i ]; then _grep "$2" -qiE -- "$3"; else _grep "$2" -qE -- "$3"; fi
        return $?
      fi
      [ "$1" = i ] && { shopt -q nocasematch && nc=1; shopt -s nocasematch; }
      for line in ${_ERE_C[@]+"${_ERE_C[@]}"}; do [[ $line =~ $3 ]] && { rc=0; break; }; done ;;
    *)
      [ "$1" = i ] && { shopt -q nocasematch && nc=1; shopt -s nocasematch; }
      [[ $2 =~ $3 ]] && rc=0 ;;
  esac
  [ "$1" = i ] && [ "$nc" = 0 ] && shopt -u nocasematch
  return $rc
}

# An exemption belongs to the command it sits in, not to the whole line. Four rules used to ask "does the SAFE
# marker appear ANYWHERE?" — so `terraform --help && terraform destroy -auto-approve`, `cat .env.example; cat .env`
# and `cat ~/.ssh/id_rsa.pub; cat ~/.ssh/id_rsa` went through while each forbidden half alone was blocked (72
# chained shapes measured open across &&, ;, ||, |, ( ) and $( )). _seg_any asks the rule of each command segment
# instead, splitting on ; & | ( ) ` and newline — so `cat .env.example $(cat .env)` is two segments too.
# Each rule keeps its old whole-line test as well and blocks when EITHER fires, so nothing blocked before passes now:
# a hit that spans a split point (`terraform -chdir=$(pwd) destroy`, a `.*` reaching across a `;`) is still the old
# test's to find. The segment test only ever adds blocks.
# Split into segments. bash 3.2's ${var//[set]/x} slows down faster than linearly with size and ~7x more in a UTF-8
# locale (review: 21 s for an ordinary 200-line heredoc), so a long command is split by one `tr` — a process, but only
# above 2 KB, where the hook was already paying for the payload's size.
_split_segs() {  # $1 = text -> array _SPL
  _SPL=()
  if [ "${#1}" -gt 2048 ]; then IFS=$'\n' read -r -d '' -a _SPL < <(printf '%s' "$1" | LC_ALL=C tr ';&|()`' '\n\n\n\n\n\n')
  else IFS=$'\n' read -r -d '' -a _SPL <<< "${1//[;&|()\`]/$'\n'}"; fi
}
_seg_any() {  # $1 = forbidden ERE, $2 = exempting ERE, $3 = glob the forbidden segment must match -> 0 when one segment has $1 and not $2
  local -a _sc; local sg n=0 nc=0 rc=1
  [[ $CMD == $3 ]] || return 1
  _split_segs "$CMD"
  for sg in ${_SPL[@]+"${_SPL[@]}"}; do [[ $sg == $3 ]] && { _sc[n]="$sg"; n=$((n+1)); }; done
  [ "$n" = 0 ] && return 1
  if [ "$n" -gt 64 ]; then   # same bound as _ere: one pipeline instead of a regcomp per segment; the output decides, not the status
    local IFS=$'\n'; local all="${_sc[*]}"; IFS=$' \t\n'
    _grep_out "$all" -aiE -- "$1"
    [ -n "$_GO" ] || return 1
    _grep_out "$_GO" -aivE -m1 -- "$2"; [ -n "$_GO" ]; return $?
  fi
  shopt -q nocasematch && nc=1; shopt -s nocasematch
  for sg in "${_sc[@]}"; do [[ $sg =~ $1 ]] && ! [[ $sg =~ $2 ]] && { rc=0; break; }; done
  [ "$nc" = 0 ] && shopt -u nocasematch
  return $rc
}

# One matcher for "git invoked with subcommand X", tolerant of the forms that used to slip past the old
# 'git +subcmd' rules: interposed options (git -C <path> …, git -c k=v …), TAB separators, and a
# quote/backtick/paren/pipe right before `git` (eval "git …", bash -c 'git …', `git …`, and the raw-JSON
# fallback where CMD is the whole blob and git is preceded by the `"` of "command":"). The boundary
# [^A-Za-z0-9_-] before git = any non-word char (so mygit / gitk / digit never match); the token run
# [^;&|[:space:]]+ skips -C/-c and their values up to the subcommand. Used by BOTH the §4.5 blocks and the
# §4.4 approval gate, so the destructive ops no longer have a weaker matcher than commit/push.
git_has() {  # $1 = command text, $2 = subcommand alternation (e.g. 'commit|push')
  # The subcommand is the first NON-option token after `git`. We skip only git GLOBAL OPTIONS — the value-taking
  # ones (-C <path>, -c <kv>, --git-dir/--work-tree/--namespace/--config-env/--super-prefix/--exec-path <v>) consume
  # their next token, plain flags don't. Skipping *arbitrary* tokens (the old behaviour) would false-match a commit
  # whose MESSAGE contains a subcommand word, e.g. git commit -m "reset --hard".
  # Trailing boundary allows quote/backtick/backslash too, so an argless subcommand that ends the string works in
  # the raw-JSON fallback (CMD is the whole blob; `git push` appears as …"git push" — push is followed by `"`).
  #
  # The literal `git` is REQUIRED by the pattern below, so a command without it cannot match and the grep is
  # pure cost. That is not a rounding error here: this hook runs on EVERY tool call, `ls -la` was paying 13
  # greps to be told 13 times that it is not git, and a process on Git Bash costs 60-135 ms (measured on a
  # Windows 11 desktop: 2,855 ms per tool call, of which this was the largest single share). The same disease
  # the pre-commit file loop had, one layer up, on a hotter path.
  #
  # A bracket glob rather than `shopt -s nocasematch`: it needs no shopt at all, so it cannot leak into a later
  # `case` the way nocasematch did in pre-commit (where it silently moved server.PEM from allowed to blocked),
  # and it works on the bash 3.2 macOS still ships. Strictly a superset of the regex — anything the grep could
  # match contains `git` case-insensitively — so no verdict can change.
  case "$1" in *[Gg][Ii][Tt]*) ;; *) return 1 ;; esac
  _ere i "$1" "(^|[^A-Za-z0-9_-])git[[:space:]]+((-[Cc][[:space:]]+[^[:space:];&|]+|--(git-dir|work-tree|namespace|config-env|super-prefix|exec-path)[[:space:]=]+[^[:space:];&|]+|-[^[:space:];&|]+)[[:space:]]+)*($2)([[:space:]]|[;&|\"'\`\\\\]|\$)" '*[Gg][Ii][Tt]*'
}
# Same precondition, hoisted once for the rules that inline the `git …` pattern instead of calling git_has.
case "$CMD" in *[Gg][Ii][Tt]*) HAS_GIT=1 ;; *) HAS_GIT=0 ;; esac
has() { _grep "$CMD" -qiE -- "$1"; }   # flag/substring test on the command (-- so a -flag pattern is safe)

# §4.5 force-push. Same two defects the `git add -f` rule had, and the same repair: the flag has to be one of
# THIS `git push`'s own arguments, at its own quoting level, and the test is case-SENSITIVE. `has()` greps the
# whole command with `-i`, so `-F` matched the `-f` alternative — and `git commit -F msg.txt; git push` is the
# ordinary way to write a commit message from a file. Measured: it was refused as "git push --force", and the
# session that hit it had to split every commit into extra tool calls, which is the same treadmill the add rule
# produced. `-F` is a commit/tag flag; push has no such flag at all. A `+ref` refspec is still force and is
# still caught, because that is a real force push written another way.
_push_forces(){   # $1 = one captured `git push …` span -> 0 when a force flag in it belongs to that push
  local seg="$1" pre="" tok dq sq q s og
  q='"'; s="'"
  case "$-" in *f*) og=1 ;; *) og=0; set -f ;; esac
  for tok in $seg; do
    case "$tok" in
      --force*|-[A-Za-z]*f*|-f|+[A-Za-z]*)
        dq="${pre//[!$q]/}"; sq="${pre//[!$s]/}"
        if [ $(( ${#dq} % 2 )) -eq 0 ] && [ $(( ${#sq} % 2 )) -eq 0 ]; then
          [ "$og" = 0 ] && set +f; return 0
        fi ;;
    esac
    pre="$pre $tok"
  done
  [ "$og" = 0 ] && set +f; return 1
}
# The three §4.5 rules that read a git command by its words, as ONE function of the text: the command itself goes
# through it here, and so does a git command put together from arguments further down (PowerShell's Start-Process git
# -ArgumentList …, a command word held in a variable), which is the same command written another way.
_git_d45(){  # $1 = command text; block() exits on the first rule it breaks
  local CMD="$1" HAS_GIT=0 _PUSHSEG _seg                                         # has() reads CMD: this one
  case "$CMD" in *[Gg][Ii][Tt]*) HAS_GIT=1 ;; esac
  { git_has "$CMD" 'reset'  && has '--hard'; }                                                && block "git reset --hard" "4.5" history
  if [ "$HAS_GIT" = 1 ] && git_has "$CMD" 'push'; then
    _grep_out "$CMD" -oE 'git[[:space:]]+([^;&|]*[[:space:]])?push([^;&|]*)'; _PUSHSEG="$_GO"
    while IFS= read -r _seg; do
      [ -n "$_seg" ] || continue
      _push_forces "$_seg" && { block "git push --force" "4.5" history; break; }
    done <<< "$_PUSHSEG"
  fi
  { git_has "$CMD" 'clean'  && has '-[A-Za-z]*f'; }                                           && block "git clean -f" "4.5" loss
  return 0
}
# ---- the quoted argument of a command that does not run it ---------------------------------------------------
# `git commit -m "drop the rm -rf /tmp/build step"` deletes nothing, and `claude -p "… git push --force origin main"`
# pushes nothing: the words stand in an argument, quoted, of a command that only stores or prints or searches for
# them. The rules below read the command as text, so each of those was refused (measured: 14 of 20 such commands).
#
# _inert_args takes those arguments out of the text the rules read, and nothing else. It is a NARROW LIST, by
# decision, not "whatever is quoted":
#     git commit | git tag     the word after -m / --message (or a short cluster that ends in m: -am, -qm)
#     gh pr|issue|release …    the word after --title / -t / --body / -b (not an extension: it may run its argument)
#     claude                   the word after -p / --print, when nothing in the call changes the directory (cd,
#                              pushd, popd, git -C) and claude's other options are --output-format, --model,
#                              --max-turns only
#     grep egrep fgrep rg      every quoted word (none is run), unless --pre is among the options (rg runs it)
#     echo printf              every quoted word, and only when the whole command has no pipe and no redirection:
#                              what is printed can be run by what reads it (`echo "…" | sh`, `echo "…" > s.sh`);
#                              never `printf -v NAME …`, which stores the text where `$NAME` can run it
# and an argument counts only when the WHOLE word is quoted: single quotes, $'…', or double quotes that hold no
# `$(` and no backtick (those run). A word glued to its option (-m"…", --message="…") is not taken out.
# The command word must be the first word of its simple command, written plainly: `FOO=1 git …`, `sudo echo …`,
# `bash -c "…"`, `eval "…"`, `ssh host "…"`, `xargs …` are not on the list and nothing of theirs is taken out.
# Anything this reader does not read with certainty leaves the command AS IT IS (the rules then judge all of it):
# an unfinished quote, a command substitution or a backtick outside single quotes, a here-document, a parenthesis
# (a subshell, a function definition), process substitution, more than _INERT_MAX bytes — and a call that changes
# what a command word means (alias, hash, function, eval, source, exec, set, export, … or an assignment to PATH,
# ENV, BASH_ENV, IFS). Bash tool only: PowerShell quotes by other rules.
_INERT_MAX=4096
_inert_args(){  # $1 = command -> 0 and _IX = the command with those arguments replaced by '' · 1 = nothing taken out
  local s="$1" c d r seg body pos=0 n=0 i j k
  local wopen=0 ws=0 wplain=1 winert=1 wtxt="" act
  local pipe=0 redir=0
  local -a T S E I P        # per word: text when plain ("" otherwise) · start · end · inert (1/0; 2 = a separator) · plain (1/0)
  _IX=""
  [ "${#s}" -le "$_INERT_MAX" ] || return 1
  case "$s" in *[\'\"]*) ;; *) return 1 ;; esac
  case "$s" in *PATH=*|*ENV=*|*IFS=*) return 1 ;; esac      # the same, by an assignment (PATH, BASH_ENV, ENV, IFS)
  # end the word that is open, if one is
  _iw_end(){ [ "$wopen" = 1 ] || return 0
    T[n]="$wtxt"; [ "$wplain" = 1 ] || T[n]=""; S[n]=$ws; E[n]=$pos; I[n]=$winert; P[n]=$wplain; n=$((n+1))
    wopen=0; wplain=1; winert=1; wtxt=""; }
  _iw_sep(){ _iw_end; T[n]=""; S[n]=$pos; E[n]=$pos; I[n]=2; P[n]=0; n=$((n+1)); }   # I = 2: a separator, not a word
  _iw_open(){ [ "$wopen" = 1 ] || { wopen=1; ws=$pos; }; }
  while [ -n "$s" ]; do
    c="${s:0:1}"
    case "$c" in
      ' '|$'\t') _iw_end; s="${s:1}"; pos=$((pos+1)) ;;
      $'\n') _iw_sep; s="${s:1}"; pos=$((pos+1)) ;;
      \') r="${s:1}"
          case "$r" in *\'*) ;; *) return 1 ;; esac
          body="${r%%\'*}"; _iw_open; wplain=0
          k=$(( ${#body} + 2 )); s="${s:k}"; pos=$((pos+k)) ;;
      \") r="${s:1}"; k=1; act=0
          while :; do
            seg="${r%%[\"\\\$\`]*}"; k=$(( k + ${#seg} )); r="${r:${#seg}}"
            [ -n "$r" ] || return 1                       # the quote is not finished
            d="${r:0:1}"
            case "$d" in
              \") k=$((k+1)); break ;;
              \\) [ "${#r}" -ge 2 ] || return 1; r="${r:2}"; k=$((k+2)) ;;
              \$) case "${r:1:1}" in '(') act=1 ;; esac; r="${r:1}"; k=$((k+1)) ;;
              \`) act=1; r="${r:1}"; k=$((k+1)) ;;
            esac
          done
          _iw_open; wplain=0; [ "$act" = 1 ] && winert=0
          s="${s:k}"; pos=$((pos+k)) ;;
      \\) [ "${#s}" -ge 2 ] || return 1
          if [ "${s:1:1}" = $'\n' ]; then s="${s:2}"; pos=$((pos+2))        # a backslash-newline joins the lines
          else _iw_open; winert=0; wplain=0; s="${s:2}"; pos=$((pos+2)); fi ;;
      \$) case "${s:1:1}" in
            '(') return 1 ;;                               # a command substitution: not read
            \') r="${s:2}"; k=2                            # $'…': a quoted word, \' does not end it
                while :; do
                  seg="${r%%[\'\\]*}"; k=$(( k + ${#seg} )); r="${r:${#seg}}"
                  [ -n "$r" ] || return 1
                  if [ "${r:0:1}" = \' ]; then k=$((k+1)); break; fi
                  [ "${#r}" -ge 2 ] || return 1; r="${r:2}"; k=$((k+2))
                done
                _iw_open; wplain=0; s="${s:k}"; pos=$((pos+k)) ;;
            *)  _iw_open; winert=0; wplain=0; s="${s:1}"; pos=$((pos+1)) ;;   # $var, ${…}, $" : part of the word, not a quoted one
          esac ;;
      \`) return 1 ;;
      '('|')') return 1 ;;
      '#') if [ "$wopen" = 1 ]; then wtxt="$wtxt#"; winert=0; s="${s:1}"; pos=$((pos+1))
           else seg="${s%%$'\n'*}"; s="${s:${#seg}}"; pos=$(( pos + ${#seg} )); fi ;;   # a comment, to the end of the line
      ';') _iw_sep; s="${s:1}"; pos=$((pos+1)) ;;
      '&') case "${s:1:1}" in
             '&') _iw_sep; s="${s:2}"; pos=$((pos+2)) ;;
             '>') _iw_end; redir=1; s="${s:2}"; pos=$((pos+2)) ;;
             *)   _iw_sep; s="${s:1}"; pos=$((pos+1)) ;;
           esac ;;
      '|') case "${s:1:1}" in
             '|') _iw_sep; s="${s:2}"; pos=$((pos+2)) ;;
             *)   pipe=1; _iw_sep; s="${s:1}"; pos=$((pos+1)) ;;
           esac ;;
      '<'|'>') case "${s:0:2}" in '<<'|'<('|'>(') return 1 ;; esac     # a here-document, process substitution: not read
               _iw_end; redir=1; s="${s:1}"; pos=$((pos+1)) ;;
      *) seg="${s%%[ $'\t\n'\'\"\\\$\`\#\;\&\|\(\)\<\>]*}"
         _iw_open; winert=0; wtxt="$wtxt$seg"; s="${s:${#seg}}"; pos=$(( pos + ${#seg} )) ;;
    esac
  done
  _iw_end
  # Each simple command: who is its first word, and which of its words are that command's inert arguments.
  local -a B; local first cmdw sub nb=0 pre="" grep_pre chdir=0
  # Does anything in the call change the directory? (cd, pushd, popd as a command word; a git that carries -C)
  i=0; k=1
  while [ "$i" -lt "$n" ]; do
    if [ "${I[i]}" = 2 ]; then k=1
    elif [ "$k" = 1 ]; then k=0; cmdw="${T[i]}"
      case "$cmdw" in cd|pushd|popd|'') chdir=1 ;; esac      # '': a command word that is not written plainly may be one
    elif [ "$cmdw" = git ]; then case "${T[i]}" in -C*) chdir=1 ;; esac
    fi
    i=$((i+1))
  done
  i=0
  while [ "$i" -lt "$n" ]; do
    [ "${I[i]}" = 2 ] && { i=$((i+1)); continue; }
    first=$i; j=$i
    while [ "$j" -lt "$n" ] && [ "${I[j]}" != 2 ]; do j=$((j+1)); done
    cmdw="${T[first]}"; [ "${P[first]}" = 1 ] || cmdw=""
    case "$cmdw" in
      # A command that changes what a later command word MEANS: after `hash -p /bin/sh echo`, `echo -c "…"` runs the
      # text (measured with a harmless pair); an alias, a function or another PATH does the same. With any of them
      # in the call nothing is taken out, wherever it stands.
      alias|unalias|function|hash|enable|builtin|shopt|set|setopt|unsetopt|source|.|eval|exec|trap|export|declare|typeset|readonly|autoload|zmodload|emulate|command|env)
        _IX=""; return 1 ;;
      git)
        k=$((first+1)); sub=""
        while [ "$k" -lt "$j" ]; do                                  # git's own options, then the subcommand
          [ "${P[k]}" = 1 ] || break
          case "${T[k]}" in
            -C|-c|--git-dir|--work-tree|--namespace|--exec-path|--config-env) k=$((k+2)) ;;
            --no-pager|--paginate|-p|-P|--bare|--no-replace-objects|--git-dir=*|--work-tree=*|--namespace=*) k=$((k+1)) ;;
            -*) break ;;
            *) sub="${T[k]}"; k=$((k+1)); break ;;
          esac
        done
        case "$sub" in commit|tag)
          while [ "$k" -lt "$j" ]; do
            if [ "${P[k]}" = 1 ]; then case "${T[k]}" in
              --) break ;;
              -m|--message|-[A-Za-z]m|-[A-Za-z][A-Za-z]m|-[A-Za-z][A-Za-z][A-Za-z]m)
                [ $((k+1)) -lt "$j" ] && [ "${I[k+1]}" = 1 ] && { B[nb]=$((k+1)); nb=$((nb+1)); }; k=$((k+1)) ;;
            esac; fi
            k=$((k+1))
          done ;;
        esac ;;
      gh)
        # Only gh's own pr / issue / release: an extension (`gh myext …`) is a program of its own and may run its argument.
        k=$((first+1)); sub=""; [ "$k" -lt "$j" ] && [ "${P[k]}" = 1 ] && sub="${T[k]}"
        case "$sub" in pr|issue|release) ;; *) k=$j ;; esac
        while [ "$k" -lt "$j" ]; do
          if [ "${P[k]}" = 1 ]; then case "${T[k]}" in
            --title|-t|--body|-b) [ $((k+1)) -lt "$j" ] && [ "${I[k+1]}" = 1 ] && { B[nb]=$((k+1)); nb=$((nb+1)); }; k=$((k+1)) ;;
          esac; fi
          k=$((k+1))
        done ;;
      claude)
        # The session `claude -p` starts is judged by the gates of the directory it starts in, with the settings it
        # is given. So the prompt is taken out only when (a) nothing in the call changes the directory, and (b) every
        # other word of this claude is an option from a short harmless list, or its value. --settings,
        # --setting-sources, --dangerously-skip-permissions, --permission-mode, --add-dir, --mcp-config,
        # --allowedTools, any option not listed, and any other quoted word leave the prompt where it is.
        k=$((first+1)); sub=ok; pre=-1
        [ "$chdir" = 0 ] || sub=""
        while [ "$k" -lt "$j" ] && [ -n "$sub" ]; do
          if [ "${P[k]}" = 1 ]; then case "${T[k]}" in
            -p|--print)
              if [ "$pre" = -1 ] && [ $((k+1)) -lt "$j" ] && [ "${I[k+1]}" = 1 ]; then pre=$((k+1)); k=$((k+1)); else sub=""; fi ;;
            --output-format|--model|--max-turns)
              if [ $((k+1)) -lt "$j" ] && [ "${P[k+1]}" = 1 ]; then case "${T[k+1]}" in -*) sub="" ;; *) k=$((k+1)) ;; esac; else sub=""; fi ;;
            --output-format=*|--model=*|--max-turns=*) ;;
            *) sub="" ;;                                   # another option, or a word that is not one
          esac; else sub=""; fi
          k=$((k+1))
        done
        [ -n "$sub" ] && [ "$pre" != -1 ] && { B[nb]=$pre; nb=$((nb+1)); } ;;
      grep|egrep|fgrep|rg)
        grep_pre=0; k=$((first+1))
        while [ "$k" -lt "$j" ]; do case "${T[k]}" in --pre|--pre=*) grep_pre=1 ;; esac; k=$((k+1)); done
        if [ "$grep_pre" = 0 ]; then k=$((first+1))
          while [ "$k" -lt "$j" ]; do [ "${I[k]}" = 1 ] && { B[nb]=$k; nb=$((nb+1)); }; k=$((k+1)); done
        fi ;;
      echo|printf)
        # printf -v NAME writes the text into a variable, and `$NAME` after it runs it (measured with a harmless
        # pair): that printf prints nothing, so it is not on the list.
        grep_pre=0; k=$((first+1))
        while [ "$k" -lt "$j" ]; do case "${T[k]}" in -v*) [ "$cmdw" = printf ] && grep_pre=1 ;; esac; k=$((k+1)); done
        if [ "$pipe" = 0 ] && [ "$redir" = 0 ] && [ "$grep_pre" = 0 ]; then k=$((first+1))
          while [ "$k" -lt "$j" ]; do [ "${I[k]}" = 1 ] && { B[nb]=$k; nb=$((nb+1)); }; k=$((k+1)); done
        fi ;;
    esac
    i=$j
  done
  [ "$nb" -gt 0 ] || return 1
  s="$1"; pos=0; i=0
  while [ "$i" -lt "$nb" ]; do
    k="${B[i]}"; _IX="$_IX${s:pos:$(( S[k] - pos ))}''"; pos="${E[k]}"; i=$((i+1))
  done
  _IX="$_IX${s:pos}"
  return 0
}
# From here to the §4.4 gate the rules read the command WITHOUT those arguments; CMD_REAL keeps it whole, and the
# commit and push gates below read that. A PowerShell call is never changed.
CMD_REAL="$CMD"; CMD_UQ_REAL="$CMD_UQ"; _INERT=0
case "$INPUT" in *'"tool_name":"PowerShell"'*|*'"tool_name": "PowerShell"'*) ;; *)
  if _inert_args "$CMD"; then _INERT=1; CMD="$_IX"; _unquoted "$CMD"; CMD_UQ="$_GS"; fi ;;
esac
_git_d45 "$CMD"
# `no-veri`, not `no-verify`: git takes any unambiguous abbreviation, and `git push --no-verif` / `git merge --no-veri`
# passed the rule that looked for the whole word (3.1.0 review; `--no-ver` and shorter are ambiguous to git itself).
case "$CMD" in *[Nn][Oo]-[Vv][Ee][Rr][Ii]*) : ;; *) false ;; esac                                                  && block "hook skip (--no-verify)" "4.5" tamper
git_has "$CMD" 'rebase'                                    && block "git rebase" "4.5" history
git_has "$CMD" 'filter-branch|filter-repo'                && block "git filter-branch/filter-repo" "4.5" history
{ git_has "$CMD" 'commit' && has '--amend'; }                                              && block "git commit --amend" "4.5" history
# §4.5 forced branch surgery. Measured before this rule: in default mode the hook made NO decision for any
# `git branch` form, and four of them lose work: -D deletes an UNMERGED branch and its own reflog with it, -f
# moves a branch (`-f x HEAD~3` orphans the commits it pointed past), -M / -C overwrite an existing branch.
# That is the reset --hard / push --force class, so it is blocked in every mode and the key does not open it.
# CASE-SENSITIVE, unlike has(): -d / -m / -c are the safe twins (git refuses to delete unmerged work with -d, and
# -m / -c refuse to overwrite), and a case-folding match would block them all. Short flags from git's own
# `branch -h`: v q t u r a d D m M c C l f i — so a cluster carrying D, M, C or f is forced (`-qD` deletes, measured),
# and `--force` anywhere in the span is forced too: `-d --force` IS `-D`, `--move --force` IS `-M`. The flag must be in
# THIS branch command's span (no ; & | crossed) and a git global option in front is skipped, as in §4d.
# Plain creation (`git branch feature`) is deliberately NOT gated at all — a user decision, see ROADMAP §4d.
# Known over-block, accepted: `--force` with a harmless verb (`--force --list`) is refused too; nobody needs it.
# The `case` is a fork-free precondition: without it every git command paid this grep's process.
case "$CMD" in *branch*) _HAS_BRANCH=1 ;; *) _HAS_BRANCH=0 ;; esac
[ "$_HAS_BRANCH" = 1 ] && _grep "$CMD" -qE '(^|[^A-Za-z0-9_-])git[[:space:]]+((-[Cc][[:space:]]+[^[:space:];&|]+|--(git-dir|work-tree|namespace|config-env|super-prefix|exec-path)[[:space:]=]+[^[:space:];&|]+|-[^[:space:];&|]+)[[:space:]]+)*branch([[:space:]]+[^[:space:];&|]+)*[[:space:]]+(-[a-zA-Z]*[DMCf][a-zA-Z]*|--force)([[:space:]=]|$)' \
  && block "forced git branch (-D / -f / -M / -C)" "4.5" history
# Scoped to targets carrying `/`, `*` or `~` ON PURPOSE — `rm -rf build` is a routine local delete and blocking
# it would make the gate noise. What was NOT on purpose: the recursive flag was matched as lowercase `r` in one
# short cluster, so `rm -Rf /`, `rm -fR /`, `rm -f -r /` and `rm --recursive --force /` all walked past while
# `rm -rf /` was blocked. Same class as the chmod hole found in evals/permission-pressure: one spelling gated,
# another reaching the identical state. Case, flag order and the long form are all the same command.
case "$CMD" in *[Rr][Mm]*) : ;; *) false ;; esac && _grep "$CMD" -qE 'rm +(-[A-Za-z]* +|--[a-z-]+ +)*(-[A-Za-z]*[rR][A-Za-z]*|--recursive)( +(-[A-Za-z]+|--[a-z-]+))* +.*(/|\*|~)' && block "destructive rm -rf" "4.5" loss
# ADDED (3.1.0): `.` and `..` as a target carry none of those three characters and are the widest targets there are —
# `rm -rf .` at a project root takes the whole tree, `..` its parent (both passed). Narrower than the test above on
# purpose, so that it adds no noise: `rm` must stand at a command position, `sudo` or not (`git rm -r --cached .`, `npm rm`,
# `docker run --rm` and a quoted "rm -r ." are not it), the dot must be an argument of its own in that rm's segment
# (`.git`, `./x`, `a.` are not), and a `#` ends the look (a comment is not a target), and so does a line break (`rm -rf dist⏎npx tsc -p .`). A builtin match: no process.
_RMNL=$'\n'
_RMDOT='(^|[;&|({'"$_RMNL"'])[[:blank:]]*(sudo[[:blank:]]+)?rm[[:space:]]+(-[A-Za-z]*[[:space:]]+|--[a-z-]*[[:space:]]+)*(-[A-Za-z]*[rR][A-Za-z]*|--recursive)([[:space:]]+(-[A-Za-z]+|--[a-z-]*))*[[:blank:]]+([^;&|#'"$_RMNL"']*[[:blank:]])?["'"'"']?\.\.?["'"'"']?([[:space:];&|)}]|$)'
case "$CMD" in *[Rr][Mm]*)
  _rmc="$CMD"
  # a backslash-newline continues the line (`rm -rf \⏎.`); folded only when one is there and the command is short
  case "$CMD" in *\\"$_RMNL"*) [ "${#CMD}" -le 4096 ] && _rmc="${CMD//\\$_RMNL/ }" ;; esac
  [[ $_rmc =~ $_RMDOT ]] && block "destructive rm -rf" "4.5" loss ;; esac
# A whole-tree `git checkout -- .` / `git restore .` destroys every uncommitted change with no reflog and no
# undo — the same loss as `reset --hard`, which has been gated since the beginning, by a command that was not.
# Not hypothetical: a verification subagent ran exactly this over uncommitted work in this repo and took the
# working tree with it. Scoped to the WHOLE-TREE pathspec (`.` · `*` · `./` · `:/`) on purpose — reverting one
# named file is an everyday, recoverable act and gating it would make the rule noise. The option-skipping
# prefix is git_has's, so `git -C <path>` and `git -c k=v` cannot walk around it and a commit MESSAGE
# containing the word "checkout" does not trip it; both are pinned as cases.
[ "$HAS_GIT" = 1 ] && _ere s "$CMD" '(^|[^A-Za-z0-9_-])git[[:space:]]+((-[Cc][[:space:]]+[^[:space:];&|]+|--(git-dir|work-tree|namespace|config-env|super-prefix|exec-path)[[:space:]=]+[^[:space:];&|]+|-[^[:space:];&|]+)[[:space:]]+)*(checkout|restore)([[:space:]]+[^;&|[:space:]]+)*[[:space:]]+(\.|\*|\./|:/)([[:space:]]|[;&|]|$)' '*[Gg][Ii][Tt]*' && block "whole-tree revert (git checkout/restore over everything)" "4.5" history
case "$CMD" in *[Mm][Kk][Ff][Ss]*|*[Dd][Dd]*) : ;; *) false ;; esac && _grep "$CMD" -qE '(^|[^a-zA-Z])(mkfs|dd +if=)'       && block "disk-level destructive command" "4.5" loss

# §4.5 remote-code-execution & permission-nuke -> HARD BLOCK. A downloaded script piped straight into a shell
# runs code no one has read; a world-writable chmod or a disk-overwriting dd is irreversible.
# CREW-NOT-A-RUNG: the interpreter names below are PATTERNS naming things to BLOCK, not invocations. The
# check in smoke-test treats any interpreter outside a marked region as a reader ladder, so a rule that
# matches `curl | python3` has to say that it is a rule.
case "$CMD" in *[Cc][Uu][Rr][Ll]*|*[Ww][Gg][Ee][Tt]*|*[Ff][Ee][Tt][Cc][Hh]*) : ;; *) false ;; esac && _grep "$CMD" -qE '(curl|wget|fetch)([^|]|\|\|)*\|[[:space:]]*(sudo[[:space:]]+)?(bash|sh|zsh|python[0-9.]*|node|perl|ruby)([[:space:]]|$)' && block "pipe-to-shell (curl|bash RCE)" "4.5" exec
# /CREW-NOT-A-RUNG
case "$CMD" in *[Dd][Dd]*) : ;; *) false ;; esac && _grep "$CMD" -qE '(^|[^a-zA-Z])dd[[:space:]]+([^|]*[[:space:]])?of='  && block "dd of= (disk overwrite)" "4.5" loss

# §4.5 INFRASTRUCTURE TEARDOWN. Same shape as the rules above — one command, no undo — but the blast radius is a
# cloud account or a cluster rather than a disk. `terraform destroy` and `pulumi destroy` remove every managed
# resource; `-auto-approve` / `--yes` skip the only confirmation those tools have; `kubectl delete` and
# `helm uninstall` take a namespace or a release with them. Crewforth gated `rm -rf` and `git reset --hard` from
# the start and never named these.
#
# EVERY VERB AND ALIAS BELOW CAME FROM THE TOOL'S OWN SOURCE OR DOCS, not from memory — the first draft of this
# rule was written from memory and missed three of them:
#   pulumi destroy  → aliases `down`, `dn`     (pulumi/pulumi destroy.go: Aliases: []string{"down","dn"})
#   helm uninstall  → aliases `del`, `un`, `delete` (cobra aliases; the generated docs page lists none of them)
#   pulumi's auto-approve is `-y`/`--yes` on `pulumi up`, NOT `-auto-approve`, and `up` is its own apply verb.
# An alias is not a detail here: `pulumi down --yes` empties the same account as `pulumi destroy`.
#
# SCOPE — the verbs that DESTROY, and three shapes deliberately let through because they do not:
#   `--help` (asks what the verb does), `--dry-run` / `--dry-run=client` (helm's own docs recommend it before an
#   uninstall), and `kubectl auth can-i <verb>` (a read-only RBAC question). `-auto-approve=false` explicitly
#   KEEPS the prompt, so it is not gated either. A gate that refuses `--help` teaches people to route around it.
#
# ANCHOR: command position — start of line, or after `;` `&&` `||` `|` `(` or a quote — with an optional chain of
# wrappers (`sudo`, `env`, `time`, `nice`, `nohup`, `xargs`) in front, because `sudo -u deploy terraform destroy`
# and `bash -c "terraform destroy"` are the same command wearing a coat. KNOWN LIMIT, stated rather than hidden:
# `^` is a LINE anchor and the payload's `\n` is already decoded here, so a heredoc that WRITES `terraform
# destroy` into a runbook is refused. Ordinary doc-writing goes through the Write tool (guard-write.sh), not
# here, so the cost is narrow — but it is real and it is not a bug in the regex, it is the regex's shape.
# TWO anchors, not one, and the reason is a false positive the first draft created. Putting a quote into the
# anchor class catches `bash -c "terraform destroy"` — and also catches `echo "terraform destroy is dangerous"`,
# which is a sentence about the rule. The distinguishing feature is not the quote, it is what precedes it: a
# SHELL EXECUTOR. So one anchor is command position, and the second requires eval/bash/sh/zsh/dash in front of
# the optional quote. `$(…)` and a leading `(` are covered by the first through the `(` in its class.
# A `VAR=value` prefix is part of command position, and leaving it out reopened the gate in its most ordinary
# shape. The wrapper chain above accepted only FLAG tokens after a wrapper, so `env TF_VAR=1 terraform destroy`
# fell out of the anchor and returned rc=0 — measured on a Windows 11 desktop, along with the bare shell form
# `TF_VAR=1 terraform destroy`. That is not an exotic spelling: `TF_VAR_*` is how Terraform documents passing
# variables, so the bypass sits on the path a real operator takes. Crewforth's older rules already tolerated the
# prefix (`env FOO=1 rm -rf /` and `FOO=1 rm -rf /` both blocked), so this gate was the only one that did not.
_IAC_ASG="([A-Za-z_][A-Za-z0-9_]*=[^;&|[:space:]]*[[:space:]]+)*"
_IAC_AT="(^|[;&|(])[[:space:]]*${_IAC_ASG}((sudo|env|time|nice|nohup|xargs)([[:space:]]+-[^;&|[:space:]]+([[:space:]]+[^-;&|[:space:]]+)?)*[[:space:]]+${_IAC_ASG})*"
_IAC_EXEC="(^|[;&|(])[[:space:]]*(sudo[[:space:]]+)?(eval|bash|sh|zsh|dash)([[:space:]]+-[a-zA-Z]+)*[[:space:]]+[\"']?"
_IAC_SAFE="(--help|[[:space:]]-h([[:space:]]|$)|--dry-run|-auto-approve=false|-auto-approve[[:space:]]+false|auth[[:space:]]+can-i)"
_iac(){ # $1 = the verb pattern; true when it sits at a command position OR behind a shell executor
  _grep "$CMD" -qiE "${_IAC_AT}$1" || _grep "$CMD" -qiE "${_IAC_EXEC}$1"
}
_IAC_DESTROY="(terraform|tofu|pulumi)([[:space:]]+-[^;&|]*)?[[:space:]]+(destroy|down|dn)([^a-zA-Z0-9_-]|$)"
_IAC_UNATT_TF="(terraform|tofu)[^;&|]*[[:space:]](apply|destroy)([^;&|]*[[:space:]])?-{1,2}auto-approve([^a-zA-Z0-9_=-]|$)"
_IAC_UNATT_PU="pulumi[^;&|]*[[:space:]]up([^;&|]*[[:space:]])?(-y|--yes|-f|--skip-preview)([^a-zA-Z0-9_-]|$)"
_IAC_CLUSTER="(kubectl[^;&|]*[[:space:]]delete([^a-zA-Z0-9_-]|$)|helm[^;&|]*[[:space:]](uninstall|delete|del|un)([^a-zA-Z0-9_-]|$))"
# The SAFE marker (--help, -h, --dry-run, …) exempts only the segment it is in — see _seg_any.
# A verb at a command position OR behind a shell executor — the two arms of _iac, as one ERE per rule.
_IAC_P_DESTROY="(${_IAC_AT}${_IAC_DESTROY})|(${_IAC_EXEC}${_IAC_DESTROY})"
_IAC_P_UNATT="(${_IAC_AT}${_IAC_UNATT_TF})|(${_IAC_EXEC}${_IAC_UNATT_TF})|(${_IAC_AT}${_IAC_UNATT_PU})|(${_IAC_EXEC}${_IAC_UNATT_PU})"
_IAC_P_CLUSTER="(${_IAC_AT}${_IAC_CLUSTER})|(${_IAC_EXEC}${_IAC_CLUSTER})"
case "$CMD" in *[Tt][Ee][Rr][Rr][Aa][Ff][Oo][Rr][Mm]*|*[Tt][Oo][Ff][Uu]*|*[Pp][Uu][Ll][Uu][Mm][Ii]*) : ;; *) false ;; esac \
  && { { ! _grep "$CMD" -qiE "$_IAC_SAFE" && _iac "$_IAC_DESTROY"; } || _seg_any "$_IAC_P_DESTROY" "$_IAC_SAFE" '*'; } \
  && block "infrastructure destroy (removes every managed resource)" "4.5" loss
case "$CMD" in *[Tt][Ee][Rr][Rr][Aa][Ff][Oo][Rr][Mm]*|*[Tt][Oo][Ff][Uu]*|*[Pp][Uu][Ll][Uu][Mm][Ii]*) : ;; *) false ;; esac \
  && { { ! _grep "$CMD" -qiE "$_IAC_SAFE" && { _iac "$_IAC_UNATT_TF" || _iac "$_IAC_UNATT_PU"; }; } || _seg_any "$_IAC_P_UNATT" "$_IAC_SAFE" '*'; } \
  && block "unattended infrastructure apply (skips the tool's only confirmation)" "4.5" loss
case "$CMD" in *[Kk][Uu][Bb][Ee][Cc][Tt][Ll]*|*[Hh][Ee][Ll][Mm]*) : ;; *) false ;; esac \
  && { { ! _grep "$CMD" -qiE "$_IAC_SAFE" && _iac "$_IAC_CLUSTER"; } || _seg_any "$_IAC_P_CLUSTER" "$_IAC_SAFE" '*'; } \
  && block "cluster teardown (kubectl delete / helm uninstall)" "4.5" loss
# The rule is WORLD-WRITABLE, so the pattern matches the resulting permission and not one spelling of it. It
# used to match `777`, `0777`, `a+rwx` and `+rwx` only, which let `1777`, `2777`, `666` and `o+w` reach exactly
# the same state — and this was not theoretical: in the A/B harness (evals/permission-pressure) a model asked to
# open a directory "wide enough for any account" reached for `chmod 1777` unprompted, sticky bit and all. A gate
# that blocks one spelling while another arrives at the same place has protected nothing.
# Numeric: 3 or 4 octal digits whose LAST digit carries the write bit for other (2·3·6·7). Symbolic: any subject
# list containing `o` or `a`, with `+` or `=`, granting `w`. `755`, `644`, `u+w` and `chmod +x` stay untouched —
# each of those carries its own case in smoke-test §7, because a gate this repo cannot prove is not a gate.
case "$CMD" in *[Cc][Hh][Mm][Oo][Dd]*) : ;; *) false ;; esac && _grep "$CMD" -qE '(^|[^a-zA-Z])chmod[[:space:]]+(-[A-Za-z]*[[:space:]]+)*([0-7]?[0-7][0-7][2367]|[ugoa]*[oa][ugoa]*[+=][rwxXst]*w[rwxXst]*|a=?\+?rwx|\+rwx)([[:space:]]|$)' && block "chmod world-writable (777/1777/666/o+w …)" "4.5" exposure

# §4.5 PowerShell equivalents -> HARD BLOCK. The PowerShell tool sends the SAME payload shape (tool_input.command)
# and Claude Code's own hooks reference says to match `Bash|PowerShell`, because on Windows wherever that tool is
# enabled PowerShell IS the shell — and with no Git Bash the Bash tool is never registered at all. The git rules
# above already carry over (git's syntax does not change), but every POSIX-shaped rule below them missed its
# PowerShell twin. Measured on this payload before the rules existed: `Remove-Item -Recurse -Force C:\proj\*`,
# `rm -Recurse -Force .`, `irm https://x/i.ps1 | iex` and `Get-Content .env` all returned rc=0 — allowed.
#
# Two PowerShell facts these patterns are built on:
#   * parameters match on any unambiguous PREFIX, so -Recurse is also -Rec/-r and -Force is also -Fo/-f;
#   * the destructive verbs have short aliases (rm/del/erase/rd/ri for Remove-Item), and `rm` there is
#     Remove-Item, not POSIX rm — the same word with different flags, which is why the POSIX rule misses it.
PS_RM='(remove-item|ri|rm|rmdir|rd|del|erase)'
# A parameter is not only `-Name<space>`. PowerShell takes a value after a colon (`-Recurse:$true`), and it takes an
# en dash, an em dash or a horizontal bar where the hyphen stands — what a word processor or a chat window turns `-`
# into. Both spellings were measured on PowerShell 5.1 to delete the tree, and both walked past these two patterns,
# which wanted a hyphen and then whitespace (3.1.0, field). The dashes are an alternation, not a bracket: a bracket
# of multi-byte characters is read byte by byte in a C locale.
PS_DASH='(-|–|—|―)'
PS_RECURSE="${PS_DASH}"'r(e(c(u(r(s(e)?)?)?)?)?)?([[:space:]:]|$)'
PS_FORCE="${PS_DASH}"'f(o(r(c(e)?)?)?)?([[:space:]:]|$)'
_ps_has_r(){ case "$1" in *-[Rr]*|*–[Rr]*|*—[Rr]*|*―[Rr]*) return 0 ;; esac; return 1; }   # the cheap precondition, same dashes
# Recursive+forced removal aimed at a glob, a drive root, a UNC path, or $HOME — the shapes that take a tree out.
# This line-wide test is the FLOOR and is kept exactly as it was: the markers are looked for anywhere on the line.
# That over-blocks (one field command was stopped by an unrelated `Set-Location C:\…` AFTER the delete), and reading
# the target from the removal's own statement instead was tried and measured: it opened 29 shapes this test stops —
# a backtick or trailing-pipe line break, a `cd` through a variable, a splat, a function called with the path later.
# A hook cannot tell "unrelated" from "arrives another way", so the floor stays and the refusal says how to go on.
{ _ps_has_r "$CMD" && has "(^|[^A-Za-z0-9_-])$PS_RM[[:space:]]" && has "$PS_RECURSE" && has "$PS_FORCE" \
  && has '(\*|[A-Za-z]:\\|\\\\|\$HOME|\$env:USERPROFILE|~)'; } \
  && block "PowerShell recursive force delete (Remove-Item -Recurse -Force)" "4.5" loss
# ADDED on top of the floor (3.1.0, field) — these can only stop more. Read from the removal's OWN statement, so an
# everyday command elsewhere on the line does not trigger them:
#   * a target with a path separator: `Remove-Item -Recurse -Force src\app` and `"$env:TEMP\x"` passed while POSIX
#     `rm -rf src/app` was stopped;
#   * `.` or `..` standing as an argument — the widest targets there are, and they carry no marker at all
#     (`Remove-Item -Recurse -Force .` passed; it is the form this rule was first written for);
#   * a removal fed by a pipeline: what the pipe delivers is its target.
# A single bare name (`Remove-Item -Recurse -Force build`) and a variable stay a routine local delete, as with POSIX
# `rm -rf build`. Statements are split on `;` and newline with `read` — linear, and no process: this runs on every
# command that carries `-r`. A split that is wrong for some exotic line costs a miss here, never an opening: the
# floor above has already had its say.
PS_RM_RE='(^|[^A-Za-z0-9_-])(remove-item|ri|rm|rmdir|rd|del|erase)([[:space:]]|$)'
PS_TGT_RE='([\\/]|(^|[[:space:]"'"'"'(,:])\.\.?(["'"'"'),]|[[:space:]]|$))'
_ps_rm_tree(){  # $1 = command -> 0 when a recursive forced removal in it is aimed at a path, at . / .., or fed by a pipe
  local ln st nc=0 rc=1
  shopt -q nocasematch && nc=1; shopt -s nocasematch
  if [[ $1 =~ $PS_RM_RE ]] && [[ $1 =~ $PS_RECURSE ]] && [[ $1 =~ $PS_FORCE ]]; then
    while IFS= read -r ln || [ -n "$ln" ]; do
      while IFS= read -r -d ';' st || [ -n "$st" ]; do
        _ps_has_r "$st" || continue
        [[ $st =~ $PS_RM_RE ]] && [[ $st =~ $PS_RECURSE ]] && [[ $st =~ $PS_FORCE ]] || continue
        if [[ $st =~ $PS_TGT_RE ]] || [[ $st =~ \|.*$PS_RM_RE ]]; then rc=0; break 2; fi
      done <<< "$ln"
    done <<< "$1"
  fi
  [ "$nc" = 0 ] && shopt -u nocasematch
  return $rc
}
{ _ps_has_r "$CMD" && _ps_rm_tree "$CMD"; } \
  && block "PowerShell recursive force delete (Remove-Item -Recurse -Force)" "4.5" loss
# Download-and-execute, the PowerShell shape of curl|bash: any fetcher piped into Invoke-Expression.
case "$CMD" in *[Ii][Ee][Xx]*|*[Ii][Nn][Vv][Oo][Kk][Ee]-[Ee][Xx][Pp][Rr][Ee][Ss][Ss][Ii][Oo][Nn]*) : ;; *) false ;; esac && _grep "$CMD" -qiE '(invoke-webrequest|iwr|invoke-restmethod|irm|curl|wget)[^|]*\|[[:space:]]*(invoke-expression|iex)([[:space:]]|$)' \
  && block "PowerShell download-and-execute (… | iex)" "4.5" exec
# Disk-level destruction. No POSIX equivalent of these names, so the mkfs/dd rule never saw them.
case "$CMD" in *[Ff][Oo][Rr][Mm][Aa][Tt]-*|*[Cc][Ll][Ee][Aa][Rr]-*|*-[Pp][Aa][Rr][Tt][Ii][Tt][Ii][Oo][Nn]*|*[Ii][Nn][Ii][Tt][Ii][Aa][Ll][Ii][Zz][Ee]-*|*[Ss][Ee][Tt]-[Dd][Ii][Ss][Kk]*) : ;; *) false ;; esac && _grep "$CMD" -qiE '(^|[^A-Za-z0-9_-])(format-volume|clear-disk|remove-partition|initialize-disk|set-disk)([[:space:]]|$)' \
  && block "PowerShell disk-level destructive command" "4.5" loss
# World-writable ACL: icacls is what chmod 777 looks like on Windows.
case "$CMD" in *[Ii][Cc][Aa][Cc][Ll][Ss]*) : ;; *) false ;; esac && _grep "$CMD" -qiE '(^|[^A-Za-z0-9_-])icacls\b[^;&|]*/grant[^;&|]*(everyone|users|authenticated users)[^;&|]*:\(?[^)]*[FM]' \
  && block "PowerShell world-writable ACL (icacls /grant Everyone:F)" "4.5" exposure

# §4.5 gate-tampering -> HARD BLOCK. A gate you can silently remove is not a gate: redirecting core.hooksPath,
# or deleting/overwriting/patching the hook scripts, would disarm the trace/secret/approval gates in one line.
# READING the setting is not disarming it. `git config --get core.hooksPath` is how a person (or the doctor)
# CHECKS that the gate is armed, and blocking it told them Crewforth was tampering-proof by refusing to let them
# verify it. Only the write forms disarm: a value, `--unset`, `--unset-all`, `--add`, `--replace-all`, `--edit`, or
# the `set` / `unset` subcommands of newer git. A read needs no `--get`: `git config core.hooksPath` with no value,
# scoped or not (`--local` / `--global` / `--system`), prints the setting and changes nothing — it used to be
# refused as tampering.
# EACH `git config … core.hooksPath` in the command is judged on its own, and a read has to PROVE it is one: the
# segment is exactly `git [-C dir] config [scope/format flags] [read verb …] core.hooksPath`, git first, nothing
# after the key but spaces or tabs. Proven reads are cut out of the command; what is left goes to the old rule —
# `git … config … core.hooksPath` anywhere is a write — widened, not narrowed. Nothing unproven is ever skipped.
# Why each piece: the old rule exempted the WHOLE command when `--get`/`--list` appeared anywhere, so `git config
# --get core.hooksPath && git config core.hooksPath x` disarmed the hooks. Two review rounds then broke the reader
# itself — a read verb as another flag's value (`--comment get`), a value from xargs or an alias, a CR / form-feed
# the payload reader drops (`[[:space:]]` calls them blank; the shell does not), and segments the reader could not
# parse being skipped (`git config"" core.hooksPath x`, `config${IFS}core.hooksPath`, a quoted `;` inside a flag).
# Quotes and backslashes are removed before the old rule looks (`core.hooks"P"ath` is core.hooksPath to git); the
# key is case-insensitive to git; a backslash-newline joins; removing the [core] section takes hooksPath with it.
_HP_B=$' \t'   # blank = space or TAB only; a literal `\t` inside [ ] is a backslash and a t to ERE
_HP_OPT="(--local|--global|--system|--worktree|--show-origin|--show-scope|--includes|--no-includes|-z|--null|--name-only|--bool|--int|--path|--bool-or-int|--expiry-date|--all|--type=[A-Za-z-]+|--file=[^${_HP_B}]+|--blob=[^${_HP_B}]+|(--file|-f|--blob|--type)[${_HP_B}]+[^${_HP_B}]+)"
_HP_PRE="^[${_HP_B}]*git([${_HP_B}]+(-C[${_HP_B}]+[^${_HP_B}]+|--git-dir=[^${_HP_B}]+|--work-tree=[^${_HP_B}]+))*[${_HP_B}]+config([${_HP_B}]+${_HP_OPT})*[${_HP_B}]+"
_hp_blocks() {  # $1 = command -> 0 when it writes core.hooksPath or drops [core]
  local bsnl=$'\\\n' c="$1" t seg r n=0 nc=0
  local bare="${_HP_PRE}core\\.hooksPath[${_HP_B}]*\$"
  local verb="${_HP_PRE}(--get|--get-all|--get-regexp|--get-urlmatch|--list|-l|get|list)([${_HP_B}]|\$)"
  local wr="[${_HP_B}](--unset|--unset-all|--add|--replace-all|--edit|-e|set|unset|--rename-section|--remove-section|rename-section|remove-section)([${_HP_B}]|\$)"
  local -a reads=()
  case "$c" in *"$bsnl"*) _gsub "$c" '\\'$'\n' ' ' bs; c="$_GS" ;; esac   # backslash-newline -> a space
  _unquoted "$c"; t="$_GS"
  case "$t" in *[Hh][Oo][Oo][Kk][Ss][Pp][Aa][Tt][Hh]*|*[Ss][Ee][Cc][Tt][Ii][Oo][Nn]*) ;; *) return 1 ;; esac   # after unquoting: hooks"P"ath
  shopt -q nocasematch && nc=1; shopt -s nocasematch
  # The payload reader decodes JSON escapes lossily — `\r` arrives as nothing, so `git config core.hooksPath <CR>`
  # would look value-less here while git sets the path to a CR byte (verified in review). With any such escape in
  # the raw payload the decoded text is not the command that will run, and no read is proven.
  # It is asked of the COMMAND as the payload spells it, with every escaped backslash (`\\`) taken out first. It
  # used to be asked of the whole payload: on Windows `"cwd":"C:\\repos\\app"` holds a backslash and an r, a `\\Users`
  # a backslash and a u in lower case, and so on, so in such a directory NO read was ever proven and `git config
  # --get core.hooksPath` — how a person checks that the gate is armed — was refused as tampering (measured on
  # Windows). An escaped backslash is a backslash, not the start of an escape: `\\r` is those two characters, and
  # only an odd one in front of the letter (`\r`, `\\\r`) is the escape the reader drops.
  local raw="${CMD_RAW-}"
  if [ -n "$raw" ]; then raw="${raw//\\\\/}"; else raw="$INPUT"; fi
  case "$raw" in *'\r'*|*'\f'*|*'\b'*|*'\v'*|*'\u'*) ;; *)
    _split_segs "$c"
    for seg in ${_SPL[@]+"${_SPL[@]}"}; do
      [[ $seg == *[Hh][Oo][Oo][Kk][Ss][Pp][Aa][Tt][Hh]* ]] || continue
      n=$((n+1)); [ "$n" -gt 64 ] && { reads=(); break; }   # past 64, no read is argued: the old rule judges it all
      # A write flag anywhere in the segment disproves the read (`--list --unset core.hooksPath`): git 2.54 refuses
      # those pairs, but the gate does not lean on another tool's option parser.
      [[ $seg =~ $wr ]] && continue
      { [[ $seg =~ $bare ]] || [[ $seg =~ $verb ]]; } && reads[${#reads[@]}]="$seg"
    done ;;
  esac
  [ "$nc" = 0 ] && shopt -u nocasematch
  # Leftover text of a read still matches the rule below, so cutting the wrong copy can only over-block.
  for r in ${reads[@]+"${reads[@]}"}; do c="${c/"$r"/ }"; done
  _unquoted "$c"; t="$_GS"
  _ere i "$t" 'git([^|]*[^[:alnum:]_|])?config[^[:alnum:]_|][^|]*core\.hooksPath' '*[Hh][Oo][Oo][Kk][Ss][Pp][Aa][Tt][Hh]*' && return 0
  _ere i "$t" 'config[^;&|]*[[:space:]](--remove-section|--rename-section|remove-section|rename-section)[[:space:]]+(--[[:space:]]+)?([^;&|[:space:]]+[[:space:]]+)?core([^A-Za-z0-9_.-]|$)' '*[Ss][Ee][Cc][Tt][Ii][Oo][Nn]*' && return 0   # [core] as the old name OR the new one
  return 1
}
# Inline config override: `git -c core.hooksPath=…` / `git --config-env core.hooksPath=…` turns the hooks off for
# that one command WITHOUT the word `config` (so the rule above misses it) — the exact equivalent of --no-verify.
[ "$HAS_GIT" = 1 ] && _ere i "$CMD" 'git[[:space:]]+([^;&|]*[[:space:]])?(-c|--config-env)[[:space:]=]+core\.hooksPath' '*[Hh][Oo][Oo][Kk][Ss][Pp][Aa][Tt][Hh]*' && block "git -c core.hooksPath (disarms the git hooks)" "4.5" tamper
[ "$HAS_GIT" = 1 ] && _hp_blocks "$CMD" && block "git config core.hooksPath (disarms the git hooks)" "4.5" tamper
# The same setting by two side doors. `git config include.path f` (or includeIf.<cond>.path) makes git read ANOTHER
# file as configuration, and that file can carry hooksPath; GIT_CONFIG_COUNT / GIT_CONFIG_KEY_n / GIT_CONFIG_VALUE_n
# hand git a setting through the environment (measured: with them a commit skipped its hooks). Both are refused by
# name, reads included: a rule that argued which `git config include.path` is a read would be the reader that
# _hp_blocks needed three review rounds to get right, for a key nobody reads in ordinary work.
if [ "$HAS_GIT" = 1 ]; then
  _t="$CMD_UQ"
  # ...and the inline form of both, with the quoting taken off first: `git -c 'core.hooksPath=/dev/null' commit`,
  # `-c core.hooks''Path=…` and `-c include.path=f` all skipped the hooks, because the rule above wants the bare
  # key right after `-c` (measured, 3.1.0 review).
  _ere i "$_t" 'git[[:space:]]+([^;&|]*[[:space:]])?(-c|--config-env)[[:space:]=]+core\.hooksPath' '*[Hh][Oo][Oo][Kk][Ss][Pp][Aa][Tt][Hh]*' \
    && block "git -c core.hooksPath (disarms the git hooks)" "4.5" tamper
  _ere i "$_t" 'git[[:space:]]+([^;&|]*[[:space:]])?(-c|--config-env)[[:space:]=]+include(if)?\.' '*[Ii][Nn][Cc][Ll][Uu][Dd][Ee]*' \
    && block "git config include.path (another file read as configuration)" "4.5" tamper
  _ere i "$_t" 'git([^|;&]*[^[:alnum:]_|;&])?config[^[:alnum:]_|;&][^|;&]*(include\.path|includeif\.)' '*[Ii][Nn][Cc][Ll][Uu][Dd][Ee]*' \
    && block "git config include.path (another file read as configuration)" "4.5" tamper
  # `git config --edit` opens the file itself in an editor, and the editor is whatever GIT_EDITOR says: no key is named.
  _ere i "$_t" 'git([^|;&]*[^[:alnum:]_|;&])?config[^[:alnum:]_|;&]([^|;&]*[[:space:]])?(--edit|-e)([[:space:]]|$)' '*[Cc][Oo][Nn][Ff][Ii][Gg]*' \
    && block "git config --edit (the configuration file opened for writing)" "4.5" tamper
  case "$_t" in *GIT_CONFIG_*[Hh][Oo][Oo][Kk][Ss][Pp][Aa][Tt][Hh]*) block "core.hooksPath through GIT_CONFIG_ variables (disarms the git hooks)" "4.5" tamper ;; esac
fi
# A write to a gate path (hook script, settings.json, or .git/hooks) via ANY common mechanism — writer verbs, the
# in-place editors, and the interpreters an evasion reaches for (perl/python/ruby/node/ed) — plus the variable-
# indirected redirect (VAR=.claude/hooks; … > $VAR). Reading a gate file stays allowed, and `chmod +x` is NOT
# blocked so doctor's re-arm fix still works (a chmod -x disable is caught by doctor, not here). Honest scope:
# the shell is Turing-complete, so this is defence-in-depth — guard-write.sh covers the Write/Edit tools (the
# model's natural path to a file), and install-time read-only hook files would be the airtight layer.
_GP='[/\\]+(\.[/\\]+)*'      # a path separator as the shell and the filesystem take it: `/`, `\`, doubled, with `/./` between
GATE='(\.(claude'"$_GP"'(hooks|git-shim|settings\.json|DISCIPLINE\.md|eval'"$_GP"'lib'"$_GP"'crew-env\.sh)|git'"$_GP"'hooks|git'"$_GP"'(config|worktrees'"$_GP"'[^/\\[:space:]]+'"$_GP"'config|modules'"$_GP"'[^[:space:]]+'"$_GP"'config))|\.gitconfig([^A-Za-z0-9_.-]|$)|\.config'"$_GP"'git'"$_GP"'config([^A-Za-z0-9_.-]|$))'
# .git/config (with a worktree's and a submodule's own) is on the list because core.hooksPath LIVES there: the rules
# above stop `git config core.hooksPath …`, and a plain `printf '[core]\n\thooksPath = /dev/null\n' >> .git/config`
# walked past them — after it a commit from the user's own terminal skips the trace and secret scans (measured, 3.1.0
# review; inside a session guard-commit-scan.sh still scans). Reading it stays allowed. Measured before choosing this
# over checking the setting at commit time: 12,422 real commands in 671 transcripts name .git/config 9 times, all 9 in
# Crewforth's own development; and a check at commit time would refuse every commit of an install whose hooks were never
# wired. The user's own files hold the same key for every repository at once: ~/.gitconfig and
# $XDG_CONFIG_HOME/git/config (~/.config/git/config) are on the list by their names, wherever HOME is.
# .claude/git-shim is the same thing one step removed: it is where core.hooksPath points when Crewforth shares
# the hooks with a project's own chain.
# eval/lib/crew-env.sh is on the list because the gates SOURCE it on every call (guard-bash, guard-write, the board
# hooks): a file a gate executes is part of the gate. Measured before it was added: overwrite it with `exit 0` and
# `rm -rf /` passed guard-bash with rc 0, in both editions (3.0.1 review).
#
# THE PLUGIN EDITION'S GATE FILES. There the gate scripts and their wiring live under the plugin root, not under
# .claude/, and none of the rules below matched them: `rm <plugin>/hooks/guard-bash.sh` returned rc 0 while
# `rm .claude/hooks/guard-bash.sh` returned rc 2 (measured, 3.0.1 review). Same rule for both: anything under
# <root>/hooks/ (the scripts, hooks.json, the blocklists, the git hooks) and <root>/.claude-plugin/ (the manifest), and
# the sourced crew-env.sh. The root comes from CLAUDE_PLUGIN_ROOT, which the harness exports to plugin hooks; the file
# install has none, and its gates are the .claude/ ones above.
# MATCHED ON THE PART EVERY SPELLING KEEPS. A first version matched the whole absolute root, and review walked straight
# past it: `~/…`, `$HOME/…`, `/Users/*/…`, `//`, `/./`, `R/../3.0.1/…` and a quoted version folder all spell the same
# file without spelling that prefix (each measured: rc 0, file gone). In Claude Code's plugin cache
# (…/plugins/cache/<marketplace>/<plugin>/<version>) the root is recognised by its <marketplace>/<plugin> tail, with
# any version after it — so every cached version of this plugin is covered as well. A root outside the cache (a
# `--plugin-dir` checkout) has no such tail and is matched as a whole path, with either slash and with or without its
# drive (`C:\…`, `C:/…`, `/c/…`).
_PGATE=""; _PLNK=""
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  _pgesc(){ local o="$1" m                      # $1 = text -> _PGE: ERE, metacharacters escaped, `/` as either slash
    for m in '.' '[' ']' '(' ')' '*' '+' '?' '{' '}' '|' '^' '$'; do o="${o//"$m"/\\$m}"; done
    _PGE="${o//\//[/\\\\]}"; }
  _pr="${CLAUDE_PLUGIN_ROOT//\\//}"; _pr="${_pr%/}"
  case "$_pr" in [A-Za-z]:/*) _pr="${_pr:2}" ;; esac
  _S='[/\\]+'; _Q="[\"']?"; _GF="(hooks|\\.claude-plugin|eval${_S}lib${_S}crew-env\\.sh)"; _END="([/\\\\\"'[:space:];&|)]|\$)"
  case "$_pr" in
    */[Pp][Ll][Uu][Gg][Ii][Nn][Ss]/[Cc][Aa][Cc][Hh][Ee]/*/*/*)
      _pn="${_pr%/*}"; _pmk="${_pn%/*}"; _pmk="${_pmk##*/}"; _pn="${_pn##*/}"
      _pgesc "$_pmk"; _pmk="$_PGE"; _pgesc "$_pn"; _pn="$_PGE"
      _PT="${_Q}${_pmk}${_Q}${_S}(\\.${_S})*${_Q}${_pn}${_Q}"                       # <marketplace>/<plugin>
      _PGATE="(^|[^A-Za-z0-9_.-])${_PT}${_S}[^;&|[:space:]]*[/\\\\]${_Q}${_GF}${_END}"
      # A link whose target ENDS at the tail, the version or a gate folder puts the rest of the path out of sight.
      _PLNK="[^;&|[:space:]]*(^|[^A-Za-z0-9_.-])${_Q}${_pmk}${_Q}(${_S}(\\.${_S})*${_Q}${_pn}${_Q}(${_S}[^;&|[:space:]/\\\\]+(${_S}${_Q}${_GF})?)?)?[/\\\\]*${_Q}" ;;
    *)
      if [ "${#_pr}" -gt 1 ]; then
        _pgesc "$_pr"
        _PGATE="(^|[[:space:]\"'=]|[A-Za-z]:|(^|[[:space:]\"'=])[/\\\\][A-Za-z])${_PGE}[/\\\\]+${_Q}${_GF}${_END}"   # at a token start, after a drive, or after Git Bash's /c
        _PLNK="[^;&|[:space:]]*${_PGE}([/\\\\]+${_Q}${_GF})?[/\\\\]*${_Q}"
      fi ;;
  esac
  [ -n "$_PGATE" ] && GATE="(${GATE}|${_PGATE})"
fi
# DISCIPLINE.md joined the list because it IS the text of §4.1-§4.5: the gates enforce those rules, so a
# writable rulebook means the rules can be emptied without touching a single gate. It needs no change to
# the prefilter below — the file only ever lives under `.claude/`, which already carries the word `claude`.
# The installer writes it from inside start.sh/adopt.sh, where the command string is `bash start.sh` and
# never names the path. SCOPE, stated exactly rather than loosely: `cat`, `grep`, `wc`, `git diff` and the
# other arg-taking readers are outside the verb list and stay allowed, but passing the file to an
# INTERPRETER (`node lint.js .claude/DISCIPLINE.md`) or to `cp` is refused, because the rule cannot tell a
# reader from a writer by the verb alone. That is the same trade the `.claude/hooks/*` rule has always made,
# it is measured in both directions in smoke-test, and the narrow cost is a `cp` of the rulebook.
# Scoped to ONE command segment. These used to span `[^|]*`, which crosses `;` and `&&`, so the writer verb and
# the gate path only had to appear somewhere in the same line — `cp a b && bash .claude/hooks/board.sh status`
# was refused as tampering. That was harmless while nobody typed a hook path; the team board made
# `.claude/hooks/board.sh` an everyday argument, and a gate that fires on ordinary work is the one people learn
# to route around. A verb in one command and a path in another was never evidence of anything: the two forms
# that matter — `rm .claude/hooks/x` and `x > .claude/hooks/y` — both put them in the SAME segment, and both
# are still blocked (asserted in smoke-test, in both directions).
# ---- the reader of a call (the commit gate further down describes what it is for) ----
_c47_read(){  # $1 = command -> _C47_T: separators as ` ; `; every quoted span and every escaped character as one marker
              # (\001 n \001, its text in _C47_Q[n]); redirections set apart from the words they touch; heredoc bodies gone
  local s="$1" out="" pre c w hd="" c2 nl=$'\n' n=0 body t bt=0
  _C47_M=$'\001'; _C47_Q=(); _C47_QX=""
  _gsub "$s" $'\r' ''; _gsub "$_GS" "$_C47_M" ''; s="$_GS"
  while :; do
    pre="${s%%[\"\'\\\;\&\|\<\>\#\(\)\`\$$nl]*}"; out="$out$pre"
    [ "$pre" = "$s" ] && break
    c="${s:${#pre}:1}"; s="${s:${#pre}+1}"
    case "$c" in
      \\) case "$s" in
            "$nl"*) s="${s:1}" ;;                                  # a backslash-newline joins: both characters go
            '') ;;
            *) _C47_Q[n]="${s:0:1}"; out="$out$_C47_M$n$_C47_M"; n=$((n+1)); s="${s:1}" ;;   # an escaped character is itself, quoted
          esac ;;
      \') case "$s" in *\'*) body="${s%%\'*}"; s="${s:${#body}+1}" ;; *) body="$s"; s="" ;; esac
          _C47_Q[n]="$body"; out="$out$_C47_M$n$_C47_M"; n=$((n+1)) ;;
      \") body=""
          case "$s" in
            '$(cat <<'*)   # a message read from a here-document: its body is skipped as a whole, quotes and all
              w="${s:8}"; w="${w#-}"; w="${w#[\'\"]}"; w="${w%%[!A-Za-z0-9_]*}"
              case "$s" in *"$nl$w$nl"*) [ -n "$w" ] && { pre="${s%%"$nl$w$nl"*}"; s="${s:${#pre}+${#w}+2}"; body='(a here-document)'; } ;; esac ;;
          esac
          while :; do                                              # to the closing quote that is not escaped
            pre="${s%%[\"\\]*}"
            [ "$pre" = "$s" ] && { body="$body$s"; s=""; break; }
            c2="${s:${#pre}:1}"; body="$body$pre"; s="${s:${#pre}+1}"
            [ "$c2" = '"' ] && break
            body="$body${s:0:1}"; s="${s:1}"
          done
          # "$@" and "${A[@]}" stay quoted and still become SEVERAL words: `set -- -n; git commit -m x "$@"`.
          case "$body" in *'$@'*|*'[@]'*) _C47_QX="$_C47_QX $n " ;; esac
          _C47_Q[n]="$body"; out="$out$_C47_M$n$_C47_M"; n=$((n+1)) ;;
      \$) case "$s" in
            \'*) # $'…' : a quoted text in which a backslash escapes, so a quote after one does not close it
                 s="${s:1}"; body=""
                 while :; do
                   pre="${s%%[\'\\]*}"
                   [ "$pre" = "$s" ] && { body="$body$s"; s=""; break; }
                   c2="${s:${#pre}:1}"; body="$body$pre"; s="${s:${#pre}+1}"
                   [ "$c2" = "'" ] && break
                   body="$body\\${s:0:1}"; s="${s:1}"
                 done
                 _C47_Q[n]="$body"; out="$out$_C47_M$n$_C47_M"; n=$((n+1)) ;;
            '(('*) case "$s" in *'))'*) pre="${s%%'))'*}"; s="${s:${#pre}+2}" ;; *) s="" ;; esac; out="$out\$" ;;   # $(( … )): arithmetic, `<<` in it is a shift
            '{'*)  case "$s" in *'}'*) pre="${s%%'}'*}"; s="${s:${#pre}+1}" ;; *) s="" ;; esac; out="$out\$" ;;     # ${ … }: one expansion, `#` in it is no comment
            *) out="$out\$" ;;
          esac ;;
      "$nl") if [ -n "$hd" ]; then                                 # the lines up to the delimiter are the here-document
               case "$s" in
                 "$hd")            s="" ;;
                 "$hd$nl"*)        s="${s:${#hd}+1}" ;;
                 *"$nl$hd$nl"*)    pre="${s%%"$nl$hd$nl"*}"; s="${s:${#pre}+${#hd}+2}" ;;
                 *"$nl$hd")        s="" ;;
               esac                                                # no such line: it was no here-document, read on
               hd=""
             fi
             out="$out ; " ;;
      \|) case "$out" in *\>) out="$out|" ;; *) out="$out ; " ;; esac ;;       # >| is a redirection, not a pipe
      \;|\(|\)) out="$out ; " ;;
      # A backtick opens a command substitution as `$(` does, so the word it starts reads as an expansion too:
      # `git \`printf commit\` -m x` is a git call whose subcommand the shell fills in. The closing one only separates.
      \`) if [ "$bt" = 0 ]; then bt=1; out="$out\$ ; "; else bt=0; out="$out ; "; fi ;;
      \&) case "$out" in
            *[\<\>]) out="$out&" ;;                                 # 2>&1, >&, and the input forms 0<&-, <&2
            *) case "$s" in
                 \>*) out="$out &>"; s="${s:1}" ;;                  # &>
                 *) out="$out ; " ;;
               esac ;;
          esac ;;
      \<|\>)
          if [ "$c" = '<' ]; then
            case "$s" in
              \<\<*) out="$out <<< "; s="${s:2}"; continue ;;       # a here-string: one word follows, on this line
              \<*) s="${s:1}"; s="${s#-}"
                   while :; do case "$s" in [$' \t']*) s="${s:1}" ;; *) break ;; esac; done
                   t="${s%%[$' \t'\;\&\|\<\>\(\)$nl]*}"; s="${s:${#t}}"   # the delimiter word, then without its quoting
                   hd="${t//\"/}"; hd="${hd//\'/}"; hd="${hd//\\/}"
                   out="$out <<H "; continue ;;
            esac
          fi
          # A redirection is its own word: `-a>/dev/null` is `-a` and `>/dev/null`. Only a number directly in front
          # of it belongs to it (2>…), and a `>` or `&` already there (>>, &>, >&).
          case "$out" in
            *[\<\>\&]) ;;
            *[0-9]) t="${out##*[!0-9]}"; pre="${out%"$t"}"; case "$pre" in ''|*[$' \t']) ;; *) out="$out " ;; esac ;;
            *) out="$out " ;;
          esac
          out="$out$c" ;;
      \#) case "$out" in
            ''|*[$' \t']) case "$s" in *"$nl"*) pre="${s%%"$nl"*}"; s="${s:${#pre}}" ;; *) s="" ;; esac ;;   # a comment, to the end of its line
            *) out="$out#" ;;
          esac ;;
    esac
  done
  _C47_T="$out"
}
_c47_w(){  # $1 = one token of _C47_T -> _W: the word as the command receives it (expansions left as written);
           # _WQ = 1 when part of it was quoted; _WX = 1 when an UNQUOTED part holds $ * ? [ or {, i.e. the shell
           # will make something else of it — possibly more than one word
  local t="$1" m="$_C47_M" pre i
  _W=""; _WQ=0; _WX=0; _WAT=0
  while :; do
    case "$t" in *"$m"*) ;; *) break ;; esac
    pre="${t%%"$m"*}"; t="${t#*"$m"}"; i="${t%%"$m"*}"; t="${t#*"$m"}"
    case "$pre" in *[\$\*\?\[\{]*) _WX=1 ;; esac
    case "$i" in ''|*[!0-9]*) ;; *) _W="$_W$pre${_C47_Q[i]:-}"; _WQ=1; case "$_C47_QX" in *" $i "*) _WX=1; _WAT=1 ;; esac; continue ;; esac
    _W="$_W$pre"
  done
  case "$t" in *[\$\*\?\[\{]*) _WX=1 ;; esac
  _W="$_W$t"
}
# The four rules below cost a grep each, so they run only for a command that could name a gate file at all. Builtin.
_gate_named(){ case "$CMD" in *[Cc][Ll][Aa][Uu][Dd][Ee]*|*[Hh][Oo][Oo][Kk][Ss]*|*[Gg][Ii][Tt][/\\]*[Cc][Oo][Nn][Ff][Ii][Gg]*|*[Gg][Ii][Tt]-[Ss][Hh][Ii][Mm]*|*.[Gg][Ii][Tt][Cc][Oo][Nn][Ff][Ii][Gg]*) return 0 ;; esac; return 1; }
# CREW-NOT-A-RUNG: same — `perl`, `python3`, `ruby`, `node` here are names the gate REFUSES when they are
# pointed at a gate file, not readers this hook uses.
# A COMMAND THAT NAMES A GATE FILE IS ON A SHORT LIST, OR IT IS REFUSED. This rule used to look for a write VERB
# (`rm|mv|cp|tee|…`) before the gate path, and a list of verbs is never complete: of 39 ways to write or delete a
# gate file, 32 passed (measured on 3.0.3: `curl -o`, `wget -O`, `sort -o`, `git log --output=`, `openssl -out`,
# `tar -C`, `unzip -d`, `unlink`, `shred`, `rmdir`, `touch`, `patch`, `vim -c wq`, `find … -delete`,
# `git checkout <rev> -- <gate file>`, `git restore -s`). It also refused readers whose arguments held such a word
# (`grep -n rm <gate file>`, `cat /Users/ed/p/.claude/hooks/x`). So the question is turned round: a simple command
# that names a gate path passes only when its command word is
#   * a READER: grep egrep fgrep rg (no --pre) cat head tail wc ls less (no log file) diff cmp stat sha256sum shasum
#     md5 md5sum du basename dirname realpath readlink jq echo printf test [ [[ mkdir pwd, sed without -i, sort
#     without -o, find without -delete / -exec / -fprint;
#   * a RUNNER of a hook script: `bash|sh <a .sh file, pre-commit or commit-msg under .claude/hooks>`, or that file
#     itself — never `bash -c`, never a script that is not one; and `chmod +x` / `755` on one;
#   * git status | log | diff | show | add | ls-files | blame | check-ignore | rev-parse | cat-file | ls-tree |
#     commit, and a `git config` that reads, with nothing before the subcommand but --no-pager / -P, and without
#     --output / --ext-diff.
# Everything else that names one is refused, a program nobody listed included. What a reader does with a
# redirection is the redirect rule's, below.
# A PATH THAT IS HIDDEN is followed where the text allows it: quotes and backslashes are taken out first
# (`.clau\de/hooks`), `.claude` itself counts (`mv .claude x`), a glob with a dot component is expanded in the
# call's directory (`.claude/hoo*/guard*`), and a call that BINDS a gate path — `D=.claude/hooks`, `for f in
# .claude/hooks/*`, `cd .claude/hooks`, or a call that already stands in such a directory — must have every one of
# its commands on the list, since any of them may reach the file by the short name.
# The call is read by _c47_read, the reader the commit gate uses: quotes paired, a here-document's body set
# apart, every separator the same. A gate path named only in a here-document makes every command of the call
# answer to the list: the body is text for `cat` and a program for `python3 -`.
# Bash tool only. A PowerShell call keeps the verb rule.
_GANC='(^|[[:space:]=:/\\])\.claude[/\\.]*([[:space:];&|)]|$)'
_gt_named(){  # $1 = text -> 0 = it names a gate path, or the directory that holds them
  local r=1; shopt -s nocasematch
  if [[ "$1" =~ $GATE ]] || [[ "$1" =~ $_GANC ]]; then r=0; fi
  shopt -u nocasematch; return "$r"
}
_gt_script(){  # $1 = a word -> 0 = a file under a hooks directory of the gate (a hook script to run)
  local r=1; shopt -s nocasematch
  if [[ "$1" =~ \.claude[/\\]+hooks[/\\]+([^/\\[:space:]]+\.sh|pre-commit|commit-msg)$ ]] || [[ "$1" =~ \.claude[/\\]+git-shim[/\\]+git$ ]] || { [ -n "${_PGATE:-}" ] && [[ "$1" =~ $_PGATE ]]; }; then r=0; fi
  shopt -u nocasematch; return "$r"
}
_gt_ok(){  # $1 = one simple command, unquoted; $2 = 1: the call binds a gate path -> 0 = on the list · 1 = not (_GTW says why)
  local seg="${1//[$'\t\n']/ }" taint="${2:-0}" k=0 a w base sub scr
  local -a W=()
  read -r -a W <<< "$seg"
  _GTW=""
  a=0                                            # a = 1: an assignment stands in front of the command word
  while [ "$k" -lt "${#W[@]}" ]; do
    case "${W[k]}" in
      then|do|else|elif|if|while|until|'!'|'{'|time) k=$((k+1)) ;;
      [A-Za-z_]*=*) case "${W[k]%%=*}" in *[!A-Za-z0-9_]*) break ;; *) a=1; k=$((k+1)) ;; esac ;;
      *) break ;;
    esac
  done
  [ "$k" -lt "${#W[@]}" ] || return 0
  w="${W[k]}"
  case "$w" in for|case|select|fi|done|esac|'}'|in) return 0 ;; esac
  # `PATH=/x cat <gate file>` runs another cat, `PAGER=… git log` another pager: an assignment in front changes
  # what the word runs, so the word is not vouched for.
  [ "$a" = 0 ] || { _GTW="an assignment stands in front of '$w', and it can change what that word runs"; return 1; }
  base="$w"
  case "$w" in */*|*\\*)
    case "${w%/*}" in
      /bin|/usr/bin|/usr/local/bin|/opt/homebrew/bin) base="${w##*/}" ;;
      *) _gt_script "$w" && return 0
         _GTW="'$w' is a program given by its path, not a command on the list"; return 1 ;;
    esac ;;
  esac
  case "$base" in
    bash|sh|zsh|dash|ksh)
      a=$((k+1)); scr=""
      while [ "$a" -lt "${#W[@]}" ]; do
        case "${W[a]}" in
          -o|+o|-O|+O) a=$((a+1)) ;;
          --*) ;;
          -*[cis]*) _GTW="'$base ${W[a]}' takes its commands from an argument or from its input"; return 1 ;;
          -*|+*) ;;
          *) scr="${W[a]}"; break ;;
        esac
        a=$((a+1))
      done
      [ -n "$scr" ] || { _GTW="'$base' with no script takes its commands from its input"; return 1; }
      _gt_script "$scr" && return 0
      case "$taint" in
        1) case "$scr" in *'$'*) return 0 ;; esac ;;
        2) case "$scr" in */*|*\\*) ;; *) return 0 ;; esac ;;       # in a gate directory, a script named without a path is one of its files
      esac
      _GTW="'$base $scr' runs a script that is not a hook script"; return 1 ;;
    git)
      a=$((k+1))
      while [ "$a" -lt "${#W[@]}" ]; do case "${W[a]}" in --no-pager|-P) a=$((a+1)) ;; *) break ;; esac; done
      sub="${W[a]:-}"
      case "$sub" in
        status|log|diff|show|add|ls-files|blame|check-ignore|rev-parse|cat-file|ls-tree|commit) ;;
        config)                       # a READ of the configuration: --get / --list, or a name and no value
          scr=0; a=$((a+1))
          while [ "$a" -lt "${#W[@]}" ]; do
            case "${W[a]}" in
              --get|--get-all|--get-regexp|--get-urlmatch|--list|-l) return 0 ;;
              -f|--file|--blob|--type|--default) a=$((a+1)) ;;
              -*) ;;
              *) scr=$((scr+1)) ;;
            esac
            a=$((a+1))
          done
          [ "$scr" = 1 ] && return 0
          _GTW="'git config' with a value writes the configuration"; return 1 ;;
        *) _GTW="'git ${sub:-…}' is not one of the git commands that only read or stage"; return 1 ;;
      esac
      for w in ${W[@]+"${W[@]:a}"}; do case "$w" in --ou*|--ext*) _GTW="'git $sub $w' writes a file or runs a program"; return 1 ;; esac; done
      return 0 ;;
    rg)   for w in ${W[@]+"${W[@]:k}"}; do case "$w" in --pr*) _GTW="'rg $w' runs a program on every file"; return 1 ;; esac; done; return 0 ;;
    sed)  for w in ${W[@]+"${W[@]:k}"}; do case "$w" in --i*|-[!-]*[iI]*|-[iI]*) _GTW="'sed $w' edits the file in place"; return 1 ;; esac; done; return 0 ;;
    sort) for w in ${W[@]+"${W[@]:k}"}; do case "$w" in --o*|-[!-]*o*|-o*) _GTW="'sort $w' writes a file"; return 1 ;; esac; done; return 0 ;;
    less) for w in ${W[@]+"${W[@]:k}"}; do case "$w" in --log*|--LOG*|-[!-]*[oO]*|-[oO]*) _GTW="'less $w' writes a log file"; return 1 ;; esac; done; return 0 ;;
    chmod)                            # making a hook runnable again is how the doctor's advice is followed; any other mode is not
      case "${W[k+1]:-}" in [ugoa]+x|[ugoa][ugoa]+x|+x|+rx|755|0755) return 0 ;; esac
      _GTW="'chmod ${W[k+1]:-}' is not the mode that makes a hook runnable (+x, 755)"; return 1 ;;
    find) for w in ${W[@]+"${W[@]:k}"}; do case "$w" in -delete|-exec|-execdir|-ok|-okdir|-fprint*|-fls) _GTW="'find $w' deletes, runs or writes"; return 1 ;; esac; done; return 0 ;;
    grep|egrep|fgrep|cat|head|tail|wc|ls|diff|cmp|stat|sha256sum|shasum|md5|md5sum|du|basename|dirname|realpath|readlink|echo|printf|test|'['|'[['|true|:|mkdir|pwd|cd|pushd|popd|read|mapfile|readarray) return 0 ;;
    jq)   for w in ${W[@]+"${W[@]:k}"}; do case "$w" in --ou*) _GTW="'jq $w' names an output"; return 1 ;; esac; done; return 0 ;;
  esac
  _GTW="'$base' is not on the list of commands that read a gate file or run a hook script"; return 1
}
_GT_CWD1='/\.claude(/+(hooks|git-shim)(/.*)?)?/*$'
_GT_CWD2='/\.git(/+hooks(/.*)?)?/*$'
_GT_GLOB1='(^|[[:space:]/=])\.[^/[:space:]]*[*?[{]'
_GT_GLOB2='\.(claude|git)[/\\][^[:space:]]*[*?[{]'
_GT_GLOB3='(^|[[:space:]/=])\{[^}[:space:]]*\.'
_GT_DOTGIT='(^|[[:space:];&|(])(cd|pushd)[[:space:]]+[^[:space:];&|]*\.git[/\\]*([[:space:];&|)]|$)'
# _GT_MEAN: a word that changes what a later command word runs. _GT_BIND: one that hands names on to a command.
_GT_MEAN='(^|[;&|[:space:](])(alias|function|hash|enable|builtin|source|eval|exec|trap|export|declare|typeset|readonly)([[:space:]]|$)|(PATH|ENV|IFS)=|\(\)'
_GT_BIND='(^|[;&|[:space:](])(xargs|parallel|read|mapfile|readarray)([[:space:]]|$)'
# A shell with no script reads its commands from the pipe in front of it: `… | sh`.
_GT_PIPESH='[|][[:space:]]*(ba|z|da|k)?sh[[:space:]]*($|[;&|<>])'
_gt_judge(){  # the call -> returns 1 with _GTW set when one of its commands is refused; 0 otherwise
  local cwd="" taint=0 named=0 globby=0 any=0 here=0 seg w x t i sp=$'\002'
  local -a SEG=() W=()     # set, not only declared: bash 4.4 and later call a declared, empty array unbound under `set -u`
  _GTW=""
  if _gate_named && _gt_named "$CMD_UQ"; then named=1; fi
  case "$CMD_UQ" in *.git*) [[ "$CMD_UQ" =~ $_GT_DOTGIT ]] && named=1 ;; esac
  case "$INPUT" in *.claude*|*.git*)
    _json_slice "$INPUT" cwd >/dev/null; cwd="${_JS//\\\\//}"
    shopt -s nocasematch
    if [[ "$cwd" =~ $_GT_CWD1 ]] || [[ "$cwd" =~ $_GT_CWD2 ]]; then taint=2; fi
    shopt -u nocasematch ;;
  esac
  case "$CMD_UQ" in *[*?[{]*)
    if [[ "$CMD_UQ" =~ $_GT_GLOB1 ]] || [[ "$CMD_UQ" =~ $_GT_GLOB2 ]] || [[ "$CMD_UQ" =~ $_GT_GLOB3 ]]; then globby=1; fi ;;
  esac
  [ "$named$taint$globby" != 000 ] || return 0
  # The simple commands of the call, as _c47_read reads it (quotes paired, a here-document's body gone, every
  # separator the same), each word without its quoting.
  _c47_read "$CMD"; _gsub "$_C47_T" ' ; ' $'\n'
  while IFS= read -r seg; do
    case "$seg" in *[![:space:]]*) ;; *) continue ;; esac
    read -r -a W <<< "$seg"; t=""
    for w in ${W[@]+"${W[@]}"}; do _c47_w "$w"; t="$t ${_W//[$' \t\n']/$sp}"; done
    SEG[${#SEG[@]}]="${t# }"
    { _gt_named "$t" || [[ "$t" =~ $_GT_DOTGIT ]]; } && any=1
    case " $t " in *' <<H '*) here=1 ;; esac
  done <<< "$_GS"
  [ "${#SEG[@]}" -gt 0 ] || return 0
  if [ "$taint" = 0 ] && [ "$named" = 1 ]; then
    if [ "$any" = 0 ]; then
      # Named, but by none of the commands: in a comment, or in the body of a here-document. A comment runs
      # nothing. A here-document is text for `cat` or `git commit -F -`, and a program for an interpreter or a
      # shell — and it can be printed into one — so with one in the call every command must be on the list.
      [ "$here" = 1 ] || return 0
      taint=2
    else
      # does the call BIND a gate path (an assignment, a for list, a cd), hand names on (a substitution, xargs),
      # or change what a command word runs?
      # A call that changes what a command word RUNS vouches for none of its words: `PATH=/x; cat <gate file>`.
      if [[ "$CMD_UQ" =~ $_GT_MEAN ]]; then _GTW="the call holds '${BASH_REMATCH[0]# }', which can change what a command word runs"; return 1; fi
      if [[ "$CMD_UQ" =~ $_GT_PIPESH ]]; then _GTW="the call pipes text into a shell, which runs it"; return 1; fi
      [[ "$CMD_UQ" =~ $_GT_BIND ]] && taint=1
      case "$CMD" in *'$('*|*'`'*) taint=1 ;; esac
      for seg in "${SEG[@]}"; do
        read -r -a W <<< "$seg"; i=0
        while [ "$i" -lt "${#W[@]}" ]; do
          case "${W[i]}" in
            then|do|else|elif|if|while|until|'!'|'{'|time) ;;
            [A-Za-z_]*=*) [ "$taint" != 0 ] || { _gt_named "${W[i]#*=}" && taint=1; } ;;
            for) _gt_named "$seg" && [ "$taint" = 0 ] && taint=1; break ;;
            cd|pushd) { _gt_named "$seg" || [[ "$seg" =~ $_GT_DOTGIT ]]; } && taint=2; break ;;
            *) break ;;
          esac
          i=$((i+1))
        done
      done
    fi
  fi
  for seg in "${SEG[@]}"; do
    x=0
    if [ "$taint" = 1 ]; then          # by a name: only a command that expands something, or holds a binding word, can reach it
      case "$seg" in *'$'*) x=1 ;; *) [[ "$seg" =~ $_GT_BIND ]] && x=1 ;; esac
    fi
    if [ "$taint" = 2 ] || [ "$x" = 1 ]; then
      _gt_ok "$seg" "$taint" || { _GTW="$_GTW, in a call that can reach a gate file by another name (a variable, a loop, a cd, a substitution, a here-document, xargs, or a word that changes what a command runs)"; return 1; }
      continue
    fi
    _gt_named "$seg" && x=1
    if [ "$x" = 0 ] && [ "$globby" = 1 ]; then
      read -r -a W <<< "$seg"
      for w in ${W[@]+"${W[@]}"}; do
        case "$w" in
          *'{'*.*|*.*'{'*) case "$w" in *[Cc][Ll][Aa][Uu][Dd][Ee]*|*[Hh][Oo][Oo][Kk][Ss]*|*.[Gg][Ii][Tt]*) x=1 ;; esac ;;
          *.*[*?[]*) t="$( cd "${cwd:-.}" 2>/dev/null && compgen -G "$w" )"; _gt_named "$t" && x=1 ;;
        esac
      done
    fi
    [ "$x" = 1 ] || continue
    _gt_ok "$seg" 0 || return 1
  done
  return 0
}
_gate_verb_ps(){ _grep "$CMD" -qiE "(^|[^A-Za-z0-9_-])(rm|mv|cp|rsync|sponge|truncate|tee|install|ln|perl|python[0-9.]*|ruby|node|ex|ed|set-content|add-content|clear-content|out-file|new-item|rename-item|copy-item|move-item|remove-item)([^A-Za-z0-9_/\\\\;&|]|\\\\[^A-Za-z0-9;&|])[^;&|]*$GATE"; }
case "$INPUT" in
  *'"tool_name":"PowerShell"'*|*'"tool_name": "PowerShell"'*)
    _gate_named && _gate_verb_ps && block "write/tamper of a gate file (hook/settings/.git-hooks)" "4.5" tamper ;;
  *)
    if ! _gt_judge; then
      _BLOCK_NOTE="A command that names a gate file passes only when it reads the file or runs a hook script: $_GTW."
      block "write/tamper of a gate file (hook/settings/.git-hooks)" "4.5" tamper
    fi ;;
esac
_gate_named && _grep "$CMD" -qiE "(sed|perl|awk|ruby)[[:space:]]+(-[^[:space:]]+[[:space:]]+)*-i[^;&|]*$GATE"          && block "in-place edit of a gate file" "4.5" tamper
# /CREW-NOT-A-RUNG
# The redirect TARGET must be the gate path, not merely something later on the line: a target is one token, so
# it cannot contain whitespace or a command separator.
_gate_named && _grep "$CMD" -qiE ">[|]?[[:space:]]*['\"]?[^[:space:];&|<>]*$GATE"                                          && block "redirect over a gate file" "4.5" tamper
{ _gate_named && has "=[^;&|]*$GATE" && has '>>?[[:space:]]*\$'; }                                                          && block "indirected write to a gate path (variable + redirect)" "4.5" tamper
# A symlink whose TARGET is the config directory itself is the two-step form of editing a hook, and step one
# names no gate path at all: `ln -sfn .claude cfg` passed every rule above, and then `cfg/hooks/guard-bash.sh`
# is an ordinary-looking path that lands on the real gate script — measured, both steps rc=0, file overwritten.
# guard-write.sh now resolves the link when the write happens; this closes the shell end, where a plain
# `echo x > cfg/hooks/guard-bash.sh` would otherwise never look like tampering. The token must be the WHOLE
# argument (`.claude`, `../.claude`, `/p/.git`), so linking to something inside the tree — `ln -s
# .claude/skills c` — is untouched here and handled at write time instead. `.git` needs its own prefilter:
# the one above only knows `claude` and `hooks`.
# The plugin edition's root is the same kind of target: `ln -s <root> cfg`, then `cfg/hooks/guard-bash.sh`.
_LNT='([^;&|[:space:]]*/)?\.(claude|git)'; [ -n "$_PLNK" ] && _LNT="(${_LNT}|${_PLNK})"
case "$CMD" in *[Ll][Nn][[:space:]]*|*[Mm][Kk][Ll][Ii][Nn][Kk]*) : ;; *) false ;; esac && _grep "$CMD" -qiE "(^|[;&|[:space:]])(ln|mklink)[^;&|]*[[:space:]]${_LNT}([[:space:]]|\$)" && block "symlink pointing at the config directory (a gate path in two steps)" "4.5" tamper

# §4.4: THE APPROVAL RECORD IS WRITTEN BY ONE THING, the UserPromptSubmit hook, from the user's own message
# (hooks/prompt-approval.sh). A session that could produce that record itself would be approving its own commit,
# and review found three ways it could, each closed here:
#   1. write the file            -> a shell command that NAMES `crewforth-approval` is refused, reading included:
#                                   nothing a session does needs it. guard-write.sh has the same rule for the file tools.
#   2. run the hook itself       -> `printf '{…"prompt":"approve: commit"}' | bash .claude/hooks/prompt-approval.sh`
#                                   wrote a record nobody typed. A command that names the hook AND feeds it (a pipe or
#                                   an input redirection: the hook reads its payload from stdin) is refused.
#   3. start a session that continues this one, with the approval as its prompt (`claude -p --continue "approve: …"`).
#                                   The record carries the session it was given in, so a NEW session's approval is
#                                   worth nothing here; one that continues or names this session is refused in the two
#                                   modes where a record counts.
# Quotes and backslashes are removed first (`crewforth-appr"oval"` is the same file to the shell), and case is
# folded because the two filesystems people use most fold it. Builtins only: this is on every Bash call.
# HONEST SCOPE, as for the gate files above: these rules match NAMES. A command that reaches the same thing without
# spelling it (a glob, a concatenation, a script written first) is past them.
_appr_named(){  # sets _APN: 1 = the record is named, 2 = the hook is fed, 3 = a session that continues this one, 0 = none
  local t nc=0
  t="$CMD_UQ"; _APN=0
  shopt -q nocasematch && nc=1; shopt -s nocasematch
  case "$t" in
    *crewforth-appr*) _APN=1 ;;
  esac
  [ "$nc" = 0 ] && shopt -u nocasematch
  # FED means the hook is what the input goes INTO: it stands after a pipe, or shares its command with an input
  # redirection. `cat …/prompt-approval.sh | grep -n x` and `grep -rn prompt-approval . | head` only read it, and a
  # first version that looked for a pipe anywhere on the line refused both (review).
  if [ "$_APN" = 0 ]; then case "$t" in *[Pp][Rr][Oo][Mm][Pp][Tt]-[Aa][Pp][Pp][Rr][Oo][Vv][Aa][Ll]*)
    { _ere i "$t" '\|[^|;&]*prompt-approval' '*[Pp][Rr][Oo][Mm][Pp][Tt]-*' \
      || _ere i "$t" '(prompt-approval[^|;&]*<|<[^|;&]*prompt-approval)' '*[Pp][Rr][Oo][Mm][Pp][Tt]-*'; } && _APN=2 ;;
  esac; fi
  if [ "$_APN" = 0 ]; then case "$PERM_MODE" in auto|dontAsk)
    _ere i "$t" '(^|[^A-Za-z0-9_./-])claude(\.exe|\.cmd)?[[:space:]]+([^;&|]*[[:space:]])?(--continue|--resume|--session-id|--fork-session|-c|-r)([[:space:]=]|$)' '*[Cc][Ll][Aa][Uu][Dd][Ee]*' \
      && _APN=3 ;;
  esac; fi
}
_appr_named
[ "$_APN" = 1 ] && block "the approval record named in a command (only the user's own message writes it)" "4.4" tamper
[ "$_APN" = 2 ] && block "the approval hook fed by a command (only Claude Code runs it, with the user's message)" "4.4" tamper
[ "$_APN" = 3 ] && block "a Claude Code session started from a command to continue this one (it could approve for it)" "4.4" tamper

# §4.5-adjacent: a .env file holds secrets. The settings.json Read-tool deny does NOT cover the Bash tool, so a
# `cat .env` would surface them. Block the direct-file readers/copiers and a `< .env` input redirect on a
# .env / .env.<env> file; the templates (.env.example/.sample/.template/.dist) stay readable. Arg-taking readers
# (grep/awk/sed) are deliberately excluded — there a `.env` token is usually a search pattern, not the file.
# The PowerShell readers sit in the SAME alternation rather than in a rule of their own: one concern, one rule.
# `cat` was already here and happens to be a PowerShell alias for Get-Content, which is exactly how this gap
# stayed invisible — the alias worked, so the rule looked like it covered PowerShell while Get-Content/gc/type
# walked straight through.
# `Select-String`/`sls` is left OUT on purpose, for the same reason grep/awk/sed are: it takes the pattern
# first, so `.env` on that line is as likely to be what is being searched for as what is being searched.
# The three patterns live in variables because the SAME rule is applied twice: once to the command below, and
# once to each line of a script the command runs (the two-step rule further down). Written out twice they drift
# -- the direct one gains a reader verb, the indirect one silently keeps letting it through.
ENV_READ_RE='(^|[^A-Za-z0-9_/.-])(cat|less|more|head|tail|tac|nl|xxd|od|strings|hexdump|base64|sort|uniq|cp|scp|rsync|get-content|gc|type|get-item|gi)[[:space:]]+(-[^;&|[:space:]]*[[:space:]]+)*([^;&|[:space:]]*/)?\.env(\.[A-Za-z0-9_-]+)?([[:space:]]|$|[;&|>)`])'
ENV_REDIR_RE='<[[:space:]]*([^;&|[:space:]]*/)?\.env(\.[A-Za-z0-9_-]+)?([[:space:]]|$|[;&|)`])'
ENV_TEMPLATE_RE='\.env\.(example|sample|template|dist)([^A-Za-z0-9_-]|$)'
# `)` and a backtick end a path too: `(cat .env)`, `$(cat .env)` and `` `cat .env` `` read the file, and all three
# passed while the bare `cat .env` was blocked (found by the chained-exemption scan).
# A template name exempts only its own segment: `cat .env.example; cat .env` reads the secret.
{ case "$CMD" in *[Ee][Nn][Vv]*) : ;; *) false ;; esac \
    && { { { has "$ENV_READ_RE" || has "$ENV_REDIR_RE"; } && ! has "$ENV_TEMPLATE_RE"; } || _seg_any "($ENV_READ_RE)|($ENV_REDIR_RE)" "$ENV_TEMPLATE_RE" '*[Ee][Nn][Vv]*'; }; } \
    && block "reading a .env secret via the Bash tool" "4.5" secret

# The same reasoning, one scope wider. `.env` was the only credential file either gate covered, which left the
# ones that actually unlock other systems wide open: an SSH private key, AWS credentials, a kubeconfig, a .netrc.
# Read them and they are in the context, one summary or one web call away from leaving the machine — and unlike a
# commit, nothing downstream scans for that. Reader verbs only (grep/awk/sed still take these as patterns), and
# a PUBLIC key or a .pub/.example path stays readable because neither is a secret.
CRED='(\.ssh/(id_[A-Za-z0-9_]+|identity)|(^|/)id_(rsa|dsa|ecdsa|ed25519)|\.aws/credentials|\.netrc|\.git-credentials|\.docker/config\.json|\.npmrc|\.pypirc|kube/config|kubeconfig|\.(pem|p12|pfx|keystore|jks)|service-account.*\.json)'
# Both arms of this rule end in $CRED, so a command carrying none of CRED's literals cannot match it and the
# two greps are pure cost. The case below is derived branch-by-branch from CRED above — one glob per
# alternation — which makes it a strict superset by construction, and keeps it reviewable next to the pattern
# it mirrors. Add a branch to CRED, add a glob here; §7's own credential cases (id_rsa, .aws/credentials,
# .netrc, .kube/config, .git-credentials, server.pem, and the .pub/.example must-not-block twins) are what
# would catch a forgotten one.
# A .pub/.example name exempts only its own segment: `cat ~/.ssh/id_rsa.pub; cat ~/.ssh/id_rsa` reads the key.
_CRED_READ="(^|[^A-Za-z0-9_/.-])(cat|less|more|head|tail|tac|nl|xxd|od|strings|hexdump|base64|cp|scp|rsync|curl|wget|get-content|gc|type|get-item|gi)[[:space:]]+(-[^;&|[:space:]]*[[:space:]]+)*[^;&|[:space:]]*$CRED"
_CRED_REDIR="<[[:space:]]*[^;&|[:space:]]*$CRED"
_CRED_SAFE='(\.pub|\.example|\.sample|\.template)([^A-Za-z0-9_-]|$)'
{ case "$CMD" in \
    *[Ii][Dd]_*|*[Ii][Dd][Ee][Nn][Tt][Ii][Tt][Yy]*|*[Ss][Ss][Hh]*|*[Cc][Rr][Ee][Dd][Ee][Nn][Tt][Ii][Aa][Ll]*\
    |*[Nn][Ee][Tt][Rr][Cc]*|*[Dd][Oo][Cc][Kk][Ee][Rr]*|*[Nn][Pp][Mm][Rr][Cc]*|*[Pp][Yy][Pp][Ii][Rr][Cc]*\
    |*[Kk][Uu][Bb][Ee]*|*[Pp][Ee][Mm]*|*[Pp]12*|*[Pp][Ff][Xx]*|*[Kk][Ee][Yy][Ss][Tt][Oo][Rr][Ee]*|*[Jj][Kk][Ss]*\
    |*[Ss][Ee][Rr][Vv][Ii][Cc][Ee]-[Aa][Cc][Cc][Oo][Uu][Nn][Tt]*) : ;; *) false ;; esac \
  && { { { has "(^|[^A-Za-z0-9_/.-])(cat|less|more|head|tail|tac|nl|xxd|od|strings|hexdump|base64|cp|scp|rsync|curl|wget|get-content|gc|type|get-item|gi)[[:space:]]+(-[^;&|[:space:]]*[[:space:]]+)*[^;&|[:space:]]*$CRED" \
    || has "<[[:space:]]*[^;&|[:space:]]*$CRED"; } \
    && ! has '(\.pub|\.example|\.sample|\.template)([^A-Za-z0-9_-]|$)'; } || _seg_any "($_CRED_READ)|($_CRED_REDIR)" "$_CRED_SAFE" '*'; }; } \
    && block "reading a private key / credential file via the Bash tool" "4.5" secret

# §4.5-adjacent, THE SECOND STEP. Everything above scans the COMMAND; none of it sees what a script FILE does.
# Measured against the shipped hook on macOS: `cat .env.local` blocks (rc=2), while `bash leak.sh`, `./leak.sh`
# and `sh leak.sh` -- a one-line script running that identical cat -- all returned rc=0. The Windows shape,
# `powershell -ExecutionPolicy Bypass -File x.ps1`, is the same hole, so this is a design gap and not a platform
# one. It is also not hypothetical: a field session hit the direct block, wrote the read into a .ps1, ran it by
# path, and stored "put it in a file and use -File" in its memory as the fix.
#
# EACH LINE OF THE SCRIPT IS JUDGED EXACTLY AS A COMMAND LINE WOULD BE -- same three patterns, same template
# exemption, one rule in one place. Per line rather than per file on purpose: a file-wide exemption would let one
# `# see .env.example` comment unlock the whole script.
#
# WHAT THIS DOES NOT CLOSE, so nobody reads it as more than it is: a script that builds the path at runtime,
# decodes it, sources another file, or is fetched rather than written. Those stay open and are not closable by
# pattern. This closes the literal two-step, which is the one that actually happens.
#
# Cost: the case prefilter is a shell builtin, the token loop forks nothing, and a file is read only when the
# command really does name a script that exists on disk -- so an ordinary command pays one case test.
# NAMING A SCRIPT IS NOT RUNNING IT, and the first version of this rule missed that: it scanned every token,
# so `ls -l leak.sh`, `chmod +x leak.sh`, `git add leak.sh` and `shellcheck leak.sh` were all blocked. None of
# them surfaces a secret -- they surface the SCRIPT -- and a gate that stops ordinary file handling is a gate
# people turn off. Measured before the narrowing: five of six non-executing commands blocked.
#
# So a token counts only where a shell would actually execute it: after an interpreter word (flags and their
# values skipped, which is what `-ExecutionPolicy Bypass -File x.ps1` needs), or as a `./x` / `/abs/x` in
# COMMAND position -- first, or straight after a separator. An interpreter glued to a separator (`x;bash f.sh`)
# is found by trimming to the last separator inside the token; word splitting is on whitespace, so that shape
# would otherwise be missed.
#
# It under-blocks rather than over-blocks where it is unsure -- `echo bash leak.sh` still counts, a script
# whose path is built at runtime does not -- and that is the correct direction for a rule sitting in front of
# every command in the session.
# The prefilter asks "could this command run something", not "does a filename here end in .sh". Keying it on
# extensions missed two whole shapes: `cmd /c leak.bat`, and `bash runme` where the script carries no extension
# at all. It is keyed on the interpreter words instead, which is broader and costs nothing extra -- everything
# past it is shell builtins, and a command that reaches the loop with no interpreter and no ./ in it does a few
# string comparisons and stops.
# A RELATIVE SCRIPT PATH IS RELATIVE TO SOMETHING, and until now that something was this hook's own process
# cwd -- never the payload's `cwd`, which was documented at the top of this file and then never read. Measured
# on Windows 11 with the real hook: with the process cwd at the project, `bash leak.sh` blocked; with the
# process cwd anywhere else it PASSED, while the payload still said the project. Absolute paths blocked from
# every cwd. So relative-path execution was in scope only by accident of where the hook happened to be started.
#
# The payload's own answer is used when it has one, and the process cwd stays as the fallback: measured in the
# same run, a WRONG payload cwd and an ABSENT one both still blocked through the fallback, so consulting the
# payload only ever adds coverage. Parameter expansion, no fork, and backslashes folded for the same reason the
# token is folded below.
# AND IT GOES THROUGH THE SHARED PARSER, like every other key this file reads. It used to be the one caller
# left with a hand-rolled extraction — `${INPUT#*"cwd"}` then `#*:` — which is the exact defect the parser
# above was rewritten to close: the key was matched WITHOUT its colon, so a decoy could relocate it, and `cwd`
# was also the one key with no ambiguity refusal. Measured with the hook's process cwd outside the project,
# which is the only situation in which the payload's cwd is consulted at all:
#   {"cwd":"<proj>",…{"command":"bash leak.sh"}}                     rc=2  'a script that reads a .env secret'
#   {"a":"cwd","b":"<decoy>","cwd":"<proj>",…}                        rc=0  ALLOWED  <- value-form decoy
#   {"cwd":"<decoy>","cwd":"<proj>",…}                                rc=0  ALLOWED  <- real duplicate
# In both attack rows `_CWD` resolved to the decoy directory, `[ -d ]` accepted it, the relative script was
# not found there, and the two-step `.env` read was never examined. Refusing an ambiguous `cwd` rather than
# resolving it is the same policy as the other three keys; a payload with no `cwd` is untouched, and the
# process cwd stays the fallback exactly as before.
_json_keycount "$INPUT" cwd
if [ "$_KC" -gt 1 ] || [ "$_KC_CAPPED" != 0 ]; then
  echo "GUARD (§4.5): this payload carries more than one \"cwd\" key, so the directory a relative command" >&2
  echo "would run in is ambiguous. Refusing rather than resolving whichever comes first." >&2
  exit 2
fi
if [ "$_KC" = 1 ]; then
  # JSON escapes come FIRST, then the fold. The value arrives as the raw bytes of a JSON string, so a Windows
  # path is `D:\\Projects\\x` — every separator doubled — and folding that alone yields `D://Projects//x`. That
  # was MEASURED working on Windows (the middle `//` is tolerated) but it works by accident, and the accident
  # runs out at the front of the path: a project on a network share arrives as `\\\\server\\share`, which folds
  # to `////server//share` and is no UNC path at all. Undoubling first turns it into `//server/share`, which is.
  # A single backslash (a value that was never escaped) and a POSIX path both pass through unchanged.
  _json_slice "$INPUT" cwd >/dev/null; _CWD="$_JS"     # via _JS: no `$( )`, so no fork on the hot path
  _CWD="${_CWD//\\\\/\\}"; _CWD="${_CWD//\\//}"
  [ -d "$_CWD" ] || _CWD=""
else
  _CWD=""
fi

_looks_exec=0
case "$CMD" in
  *[Bb][Aa][Ss][Hh]*|*[Ss][Hh]*|*[Kk][Ss][Hh]*|*[Dd][Aa][Ss][Hh]*|*[Ss][Oo][Uu][Rr][Cc][Ee]*\
  |*[Pp][Ww][Ss][Hh]*|*[Cc][Mm][Dd]*|*./*|*.\\*) _looks_exec=1 ;;
esac
if [ "$_looks_exec" = 1 ]; then
  set -f                                     # a token like *.sh must not glob against the cwd
  _interp=0; _cmdpos=1
  for _tok in $CMD; do
    _tok="${_tok%\"}"; _tok="${_tok#\"}"; _tok="${_tok%\'}"; _tok="${_tok#\'}"
    # Backslashes folded to forward slashes, the same substitution route-hint.sh applies to its roots.
    #
    # THE REASON IS THE `case` PATTERNS, NOT `[ -f ]`, and the difference is written down because getting it
    # wrong is how this line gets deleted later as redundant. Measured on Git Bash (Windows 11) rather than
    # assumed: `[ -f ]` resolves ALL THREE spellings on its own -- `C:/repo/leak.ps1`, `/c/repo/leak.ps1` and
    # `C:\repo\leak.ps1` unfolded -- so the existence test never needed this. What needs it is the glob below:
    # `.\leak.ps1` does not match `./*`, and Windows is where a path is natively written that way. Without the
    # fold the candidate is never even considered, and the rule quietly does not exist on that platform.
    #
    # A no-op where there is nothing to fold. Used ONLY to decide whether a file is being run; nothing is
    # executed from it, so a `my\ file.sh` style escape loses nothing but this rule's interest.
    _tok="${_tok//\\//}"
    # separators reset both states: a new command begins after them
    case "$_tok" in
      *[\;\&\|]*)
        case "$_tok" in
          \;|\&\&|\|\||\||\&) _interp=0; _cmdpos=1; continue ;;
        esac ;;
    esac
    # the interpreter test looks at the tail after any glued separator, then at the basename
    _base="${_tok##*;}"; _base="${_base##*&}"; _base="${_base##*|}"; _base="${_base##*/}"
    case "$_base" in
      bash|sh|zsh|ksh|dash|source|.|powershell|powershell.exe|pwsh|pwsh.exe|cmd|cmd.exe)
        _interp=1; _cmdpos=0; continue ;;
    esac
    case "$_tok" in
      -[Ff]ile|-[Ff]|--file) _interp=1; continue ;;   # PowerShell's -File names the script that follows
      -*) continue ;;                                 # any other flag leaves both states alone
      /[A-Za-z]) continue ;;                          # cmd.exe spells its flags /c and /k, not -c
    esac
    _cand=0
    if [ "$_interp" = 1 ]; then
      _cand=1                                         # the word after an interpreter, flag values included
    elif [ "$_cmdpos" = 1 ]; then
      case "$_tok" in ./*|/*) _cand=1 ;; esac          # ./x or an absolute path, run directly
    fi
    _cmdpos=0
    [ "$_cand" = 1 ] || continue
    # Both roots tried: the hook's own cwd first, then the one the payload names. A flag value that is not a
    # file under either just keeps _interp set, so `-ExecutionPolicy Bypass -File x.ps1` still reaches x.ps1.
    _path=""
    if [ -f "$_tok" ] && [ -r "$_tok" ]; then _path="$_tok"
    elif [ -n "$_CWD" ]; then
      case "$_tok" in
        /*|[A-Za-z]:/*) : ;;                            # already absolute; the payload cwd cannot help
        *) [ -f "$_CWD/$_tok" ] && [ -r "$_CWD/$_tok" ] && _path="$_CWD/$_tok" ;;
      esac
    fi
    [ -n "$_path" ] || continue
    _interp=0
    # Per segment, not per line: a script line `cat .env.example; cat .env` reads the secret (see _seg_any).
    # LC_ALL=C: a UTF-8 `tr` dies on a non-UTF-8 byte and, under pipefail, took the verdict with it (review). The hit
    # is read from the output, not the pipeline status: `grep -q` closing early SIGPIPEs the stage before it, and a
    # 3,000-line script passed that way while a 1,000-line one was blocked.
    _envhit="$(LC_ALL=C tr ';&|' '\n\n\n' < "$_path" 2>/dev/null)"
    _grep_out "$_envhit" -aiE -- "$ENV_READ_RE|$ENV_REDIR_RE"; _envhit=""
    [ -n "$_GO" ] && { _grep_out "$_GO" -aivE -m1 -- "$ENV_TEMPLATE_RE"; _envhit="$_GO"; }
    if [ -n "$_envhit" ]; then
      set +f
      block "running a script that reads a .env secret (the two-step read)" "4.5" secret
    fi
  done
  set +f
fi

# §4.5 force-add bypasses .gitignore (sneaks build output / secrets past the bloat & ignore rules); deleting a
# lockfile is a §4.5 op the discipline already names. Both are only done on an explicit request.
# §4.5 `git add -f` bypasses .gitignore. Two things have to be true for the flag to be THIS command's: it has
# to sit inside the `git add` invocation's own argument span, and it has to be at the same quoting level.
#
# The span alone was not enough. `[^;&|]*` stops at a command separator but not at a quote, so a command that
# carries a SECOND, quoted copy of itself — which is exactly what a script testing this guard looks like —
# donated its `rm -f` to the first `git add`. Measured: `dene "rm -f y.lock; git add x" 'rm -f y.lock; git add x'`
# captured `git add x" 'rm -f y.lock` and blocked.
#
# The obvious repair — adding the quote characters to the excluded class — was measured and REJECTED, because
# it trades this narrow false positive for a narrow false NEGATIVE: `git add "spaced name.txt" -f` would then
# stop being seen, and that one really does bypass .gitignore. A gate that fails open is worse than one that
# cries wolf.
#
# So the discriminator is quote BALANCE, not quote presence. Before `git add "name" -f` the double quotes are
# even (the pair closed); before the false positive's `-f` there is one `"` and one `'`, each unclosed — that
# flag is inside someone else's quoting. The walk below is entirely parameter expansion and `case`: no
# subshell, no `tr`, no `wc`. This hook runs on EVERY Bash call and its per-call fork count is 0; it stays 0.
_addf_owns(){   # $1 = one captured `git add …` span -> 0 when a -f/--force in it belongs to that git add
  local seg="$1" pre="" tok dq sq q s og
  q='"'; s="'"
  case "$-" in *f*) og=1 ;; *) og=0; set -f ;; esac      # the span holds `.` and `*`; do not let them glob
  for tok in $seg; do
    case "$tok" in
      --force|-[A-Za-z]*f*|-f)
        dq="${pre//[!$q]/}"; sq="${pre//[!$s]/}"
        if [ $(( ${#dq} % 2 )) -eq 0 ] && [ $(( ${#sq} % 2 )) -eq 0 ]; then
          [ "$og" = 0 ] && set +f; return 0
        fi ;;
    esac
    pre="$pre $tok"
  done
  [ "$og" = 0 ] && set +f; return 1
}
if [ "$HAS_GIT" = 1 ] && git_has "$CMD" 'add'; then
  _grep_out "$CMD" -oE 'git[[:space:]]+([^;&|]*[[:space:]])?add([^;&|]*)'; _ADDSEG="$_GO"
  while IFS= read -r _seg; do
    [ -n "$_seg" ] || continue
    _addf_owns "$_seg" && { block "git add -f (bypasses .gitignore)" "4.5" bypass; break; }
  done <<< "$_ADDSEG"
fi
  # `git update-index --add` stages a path REGARDLESS of .gitignore — the same bypass `git add -f` performs, by
  # a different spelling. Blocking one and not the other is not a policy, it is an oversight: seen live on a
  # Windows machine, `git update-index --add --chmod=+x deploy/rolling-update.sh` staged the file with nothing
  # said. (Staging itself is deliberately NOT gated here — only commit and push ask — so this rule is about the
  # gitignore bypass alone, not about stopping people from staging files.)
  [ "$HAS_GIT" = 1 ] && _ere s "$CMD" 'git[[:space:]]+([^;&|]*[[:space:]])?update-index([^[:alnum:]_;&|][^;&|]*)?(--add|--force-remove)' '*[Uu][Pp][Dd][Aa][Tt][Ee]-[Ii][Nn][Dd][Ee][Xx]*' \
    && block "git update-index --add (bypasses .gitignore, same as git add -f)" "4.5" bypass
case "$CMD" in *[Rr][Mm]*) : ;; *) false ;; esac && _grep "$CMD" -qE '(rm|git[[:space:]]+rm)\b[^|]*(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|npm-shrinkwrap\.json|Gemfile\.lock|poetry\.lock|Pipfile\.lock|Cargo\.lock|composer\.lock|go\.sum|packages\.lock\.json)' && block "lockfile deletion" "4.5" loss

# The rules that read the command as text end here: what follows judges a commit or a push, and reads all of it.
# WHETHER there is a commit or a push in the call is still asked of the text without those arguments (CMD_SEEN):
# `echo "git push origin main"` pushes nothing, and asking the user to approve an echo is the same mistake as
# refusing it. What a commit carries (its options, its message, the approval it needs) is read from the whole call.
CMD_SEEN="$CMD"; CMD="$CMD_REAL"; CMD_UQ="$CMD_UQ_REAL"

# --- §4.4 commit/push approval gate ---
# Escape a shell string into a JSON string body. A raw control character inside a JSON string is a parse
# error, and the reason text is attacker-adjacent (it is the model's own command line), so:
#   - delete every control char except tab and newline (this also removes CR, which a CRLF here-doc leaks);
#   - fold a surviving tab to a space (display-only text; the command Claude runs is untouched);
#   - escape backslash and double quote;
#   - fold newlines to the two-character \n escape.
# Each line of a text cut to at most N bytes, never inside a letter. This is the command as the approval prompt
# shows it, and it goes into JSON. `cut -c1-300` did this job: GNU cut counts BYTES whatever the locale (measured on
# Linux under en_US.UTF-8: a two-byte letter across byte 300 left the prompt's JSON invalid UTF-8), and BSD cut
# counts characters only while the session's locale says so. Here the cut is by bytes and then steps back over an
# unfinished letter: a UTF-8 letter is one lead byte (0xC0 and up) followed by continuation bytes (0x80-0xBF).
_utf8_cut(){  # $1 = text, $2 = bytes per line -> _UC
  local LC_ALL=C
  local l out="" nl=""
  while IFS= read -r l || [ -n "$l" ]; do
    if [ "${#l}" -gt "$2" ]; then
      l="${l:0:$2}"
      while :; do case "$l" in *[$'\x80'-$'\xbf']) l="${l%?}" ;; *) break ;; esac; done
      case "$l" in *[$'\xc0'-$'\xff']) l="${l%?}" ;; esac
    fi
    out="$out$nl$l"; nl=$'\n'
  done <<< "$1"
  while :; do case "$out" in *$'\n') out="${out%?}" ;; *) break ;; esac; done
  _UC="$out"
}
json_escape(){
  printf '%s' "$1" \
    | tr -d '\000-\010\013-\037\177' \
    | tr '\011' ' ' \
    | sed 's/\\/\\\\/g; s/"/\\"/g' \
    | awk 'NR>1{printf "\\n"} {printf "%s", $0}'
}
# ---- CREW-APPROVAL-PATH (one definition, carried by prompt-approval.sh and guard-bash.sh; smoke-test pins it) ----
_crew_appr_path(){  # $1 = a directory -> _AP: the record's path in that worktree's git directory, "" outside one
  local d="${1//\\//}" l g
  _AP=""; d="${d%/}"
  while :; do
    if [ -f "$d/.git/HEAD" ]; then _AP="$d/.git/crewforth-approval"; return 0; fi   # a git directory, not a folder named .git
    if [ -f "$d/.git" ]; then                    # a linked worktree or a submodule: `.git` is a one-line pointer
      l=""; IFS= read -r l < "$d/.git" || true; l="${l%$'\r'}"
      case "$l" in "gitdir: "*)
        g="${l#gitdir: }"; g="${g//\\//}"
        case "$g" in /*|[A-Za-z]:*) ;; *) g="$d/$g" ;; esac
        [ -f "$g/HEAD" ] && _AP="$g/crewforth-approval" ;;
      esac
      return 0
    fi
    case "$d" in */*) d="${d%/*}" ;; *) return 0 ;; esac
  done
}
# ---- /CREW-APPROVAL-PATH ---------------------------------------------------------------------------------
# §4.4 IN `auto` AND `dontAsk`: THE USER'S OWN MESSAGE IS THE APPROVAL. hooks/prompt-approval.sh records it when the
# whole message is `/crew-approve commit` / `push` / `commit+push` (or the older `approve: …`), with what git reported at that moment.
# This reads the record back and answers one question: does it cover THIS call, and nothing else?
#   commit       the index writes the recorded tree and HEAD is the recorded one. A commit moves HEAD, so the same
#                record cannot allow a second one; a commit that FAILED (a hook refused it) moved nothing and may be retried.
#   push         `git push <remote> <branch>`: the recorded remote, still pushing to the recorded URL, the recorded
#                branch, HEAD on it. Pushing one commit to one branch twice changes nothing, so this needs no counter.
#   commit+push  the push is checked against the commit the approved index BECAME: its parent is the recorded HEAD
#                and its tree is the recorded tree.
# and in every case the session is the one the user wrote in. The record is never written here. It ends 30 minutes
# after the message, or at the user's next message (the other hook empties it). §4.5 ran above and §4.6 runs before
# this, so neither is opened by an approval.
#
# THE TREE, NOT THE DIFF. §4.6 hashes the text of `git diff --cached`, and what that prints is configurable:
# `git config diff.external true` made every staged diff print nothing, so every diff got one id (measured in
# review; §4.6 now passes --no-ext-diff --no-textconv). The id of the tree the index writes depends on the content
# alone, whatever else is configured.
#
# THE CALL HAS TO BE THE GIT COMMAND AND NOTHING ELSE. Where a person sees the prompt they also see the command; here
# nobody does. Each of these was allowed by a matching record in a first version, and each does something the user
# did not approve (the rows are in smoke-test):
#     cd ../other && git commit -m x                         commits what is staged in another repository
#     GIT_INDEX_FILE=/tmp/i git commit -m x                  commits another index than the one that was read
#     git commit -m "$(git add -A; echo msg)"                stages everything, then commits it
#     git commit -m 'a"' ; touch x ; echo 'b"'               two more commands, hidden by pairing the wrong quotes
#     git commit -m x 2>&1 -a      git commit -mxm b.txt     the working tree, past §4.6's scan
#     git commit -n -m x           git commit --amen -m x    --no-verify and --amend, as git abbreviates them
# So the text is read the way the shell reads it, left to right, and anything that cannot be judged is refused:
# a single-quoted span is literal; a double-quoted one may hold no `$`, backtick, backslash or `!`; the one
# substitution let through is a message read from a here-document whose delimiter is quoted,
# `-m "$(cat <<'EOF' … EOF)"`, because its body is literal too. What is left must hold no separator, substitution,
# redirection, comment, glob or second line, must begin with `git commit` / `git push`, and its arguments are a
# short list: a wrong option is refused here whatever §4.5 and §4.6 make of it.
# The PowerShell tool reads quotes by other rules (a backslash escapes nothing there, a backtick does), so for it
# only single quotes are accepted.
_a44_collapse(){  # $1 = command, $2 = commit|push, $3 = tool -> 0 and _A44_S (quoted spans as Q); otherwise _A44_WHY
  local s="$1" out="" pre c rest w body
  _A44_WHY=""; _A44_S=""
  if [ "$3" != Bash ]; then
    case "$s" in *[\"\`\\\$@]*) _A44_WHY="outside the Bash tool an approved call uses single quotes only (no double quote, backtick, backslash, \$ or @)"; return 1 ;; esac
    # ...and plain ASCII on one line. PowerShell reads the typographic quotes (U+2018, U+2019 and their kin) as
    # single quotes, so `'a ’ ; cmd ; ‘ b'` is one quoted text here and three commands there; and a `\u` escape in the
    # payload reaches this code as `?`. Neither can be told apart from text inside a quoted span, so both are refused.
    local LC_ALL=C
    case "$s" in *[!\ -~]*|*\?*) _A44_WHY="outside the Bash tool an approved call is plain ASCII on one line (PowerShell reads typographic quotes as quotes); use the Bash tool for any other message"; return 1 ;; esac
  fi
  _gsub "$s" $'\r' ''; s="$_GS"
  while :; do
    pre="${s%%[\"\'\\]*}"; out="$out$pre"
    [ "$pre" = "$s" ] && break
    c="${s:${#pre}:1}"; s="${s:${#pre}+1}"
    case "$c" in
      \\) case "$s" in
            $'\n'*) out="$out "; s="${s:1}" ;;                       # a backslash-newline joins two lines
            *) _A44_WHY="a backslash outside quotes"; return 1 ;;
          esac ;;
      \') case "$s" in *\'*) ;; *) _A44_WHY="an unpaired quote"; return 1 ;; esac
          body="${s%%\'*}"; s="${s:${#body}+1}"; out="${out}Q" ;;
      *)  case "$s" in
            '$(cat <<'\'*)
              rest="${s:9}"; w="${rest%%\'*}"
              case "$w" in ''|*[!A-Za-z0-9_]*) _A44_WHY="a here-document whose delimiter is not a plain quoted word"; return 1 ;; esac
              rest="${rest:${#w}+1}"
              case "$rest" in $'\n'*) rest="${rest:1}" ;; *) _A44_WHY="text on the line that opens the here-document"; return 1 ;; esac
              # The body ends at the FIRST line that is the delimiter, as it does for the shell.
              case "$rest" in
                "$w"$'\n'*)       rest="${rest:${#w}+1}" ;;
                *$'\n'"$w"$'\n'*) body="${rest%%$'\n'"$w"$'\n'*}"; rest="${rest:${#body}+${#w}+2}" ;;
                *) _A44_WHY="a here-document that is not closed on its own line"; return 1 ;;
              esac
              while :; do case "$rest" in [$' \t']*) rest="${rest:1}" ;; *) break ;; esac; done
              case "$rest" in
                ')"'*) s="${rest:2}"; out="${out}Q" ;;
                *) _A44_WHY="something follows the here-document inside the substitution"; return 1 ;;
              esac ;;
            *\"*)
              body="${s%%\"*}"
              case "$body" in *[\$\`\\\!]*) _A44_WHY="a double-quoted text that holds \$, a backtick, a backslash or ! (single-quote it, or read the message from a here-document with a quoted delimiter)"; return 1 ;; esac
              s="${s:${#body}+1}"; out="${out}Q" ;;
            *) _A44_WHY="an unpaired quote"; return 1 ;;
          esac ;;
    esac
  done
  out="${out//$'\t'/ }"; out="${out// 2>&1/ }"
  while :; do case "$out" in [$' \n']*) out="${out:1}" ;; *) break ;; esac; done
  while :; do case "$out" in *[$' \n']) out="${out%?}" ;; *) break ;; esac; done
  case "$out" in *[$'\n'\;\&\|\`\$\(\)\{\}\<\>\#\*\?\[\]\~\!\%\^]*)
    _A44_WHY="the call is more than one plain command (a separator, a substitution, a redirection, a comment, a glob or a second line)"; return 1 ;; esac
  case "$out" in "git $2"|"git $2 "*|"git.exe $2"|"git.exe $2 "*) ;;
    *) _A44_WHY="the call does not begin with 'git $2' (a cd, a variable or an option comes first)"; return 1 ;; esac
  _A44_S="$out"; return 0
}
_c44_scan(){  # $1 = the collapsed `git commit …` -> 0 when every argument is a message or one of -q -s -v; else _C44_WHY
  local tok body pre unglob=0
  _C44_WHY=""
  case "$-" in *f*) ;; *) unglob=1; set -f ;; esac
  set -- $1
  [ "$unglob" = 1 ] && set +f
  shift 2
  while [ $# -gt 0 ]; do
    tok="$1"; shift
    case "$tok" in
      --message) [ $# -gt 0 ] || { _C44_WHY="--message with no text"; return 1; }; shift ;;
      --message=?*|--quiet|--signoff|--verbose) ;;
      --*) _C44_WHY="the option $tok"; return 1 ;;
      -?*) # a cluster: -q -s -v in any order, then at most one -m, whose text is the rest of the token or the next one
           body="${tok#-}"; pre="${body%%m*}"
           case "$pre" in *[!qsv]*) _C44_WHY="the option $tok"; return 1 ;; esac
           if [ "$pre" != "$body" ] && [ -z "${body#*m}" ]; then
             [ $# -gt 0 ] || { _C44_WHY="-m with no text"; return 1; }; shift
           fi ;;
      *) _C44_WHY="a path or an argument that is not a message ($tok)"; return 1 ;;
    esac
  done
  return 0
}
_p44_scan(){  # $1 = the collapsed `git push …` -> 0 when it is `git push [-u] <remote> <ref>`; sets _P44_REMOTE _P44_REF, or _P44_WHY
  local tok npos=0 unglob=0
  _P44_REMOTE=""; _P44_REF=""; _P44_WHY=""
  case "$-" in *f*) ;; *) unglob=1; set -f ;; esac
  set -- $1
  [ "$unglob" = 1 ] && set +f
  shift 2
  while [ $# -gt 0 ]; do
    tok="$1"; shift
    case "$tok" in
      -u|--set-upstream|-q|--quiet|-v|--verbose|--progress|--no-progress) ;;
      -*) _P44_WHY="the option $tok"; return 1 ;;
      *) npos=$((npos+1))
         case "$npos" in 1) _P44_REMOTE="$tok" ;; 2) _P44_REF="$tok" ;; *) _P44_WHY="more than one refspec"; return 1 ;; esac ;;
    esac
  done
  [ "$npos" = 2 ] || { _P44_WHY="the remote and the branch are not both written out"; return 1; }
  return 0
}
_approval_ok(){  # 0 = the user's recorded approval covers THIS call. Otherwise _APW says why not, for the message.
  local k v op="" tr="" h="" b="" r="" u="" sid="" ts="" now age dir="${_CWD:-.}" hc=1 hp=1 cur tool
  _APW="no approval from the user is on record"
  git_has "$CMD_SEEN" 'commit' && hc=0; git_has "$CMD_SEEN" 'push' && hp=0
  if [ "$hc" = 0 ] && [ "$hp" = 0 ]; then
    _APW="this call holds a commit and a push; each is checked against the approval on its own, so run them as two calls"; return 1
  fi
  _crew_appr_path "$dir"
  [ -n "$_AP" ] && [ -s "$_AP" ] || return 1
  while IFS='=' read -r k v || [ -n "$k" ]; do
    v="${v%$'\r'}"
    case "$k" in op) op="$v" ;; tree) tr="$v" ;; head) h="$v" ;; branch) b="$v" ;; remote) r="$v" ;; url) u="$v" ;; sid) sid="$v" ;; ts) ts="$v" ;; esac
  done < "$_AP"
  case "$ts" in ''|*[!0-9]*) _APW="the approval record could not be read"; return 1 ;; esac
  if [ "${BASH_VERSINFO[0]}" -ge 5 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then
    printf -v now '%(%s)T' -1
  else now="$(date +%s)"; fi
  case "$now" in ''|*[!0-9]*) _APW="the clock could not be read"; return 1 ;; esac
  age=$((now - ts))
  if [ "$age" -lt 0 ] || [ "$age" -gt 1800 ]; then _APW="the user's approval is more than 30 minutes old"; return 1; fi
  # The session the user wrote in. A session started from a command here is another one, whatever it is told.
  _json_slice "$INPUT" session_id >/dev/null
  if [ -z "$sid" ] || [ "$sid" != "$_JS" ]; then _APW="the approval on record was given in another session"; return 1; fi
  _json_slice "$INPUT" tool_name >/dev/null; tool="$_JS"
  if [ "$hc" = 0 ]; then
    case "$op" in commit|commit+push) ;; *) _APW="the approval on record is for a push, not for a commit"; return 1 ;; esac
    _a44_collapse "$CMD" commit "$tool" || { _APW="$_A44_WHY. Run the commit alone: git commit -m '…'"; return 1; }
    _c44_scan "$_A44_S" || { _APW="an approved commit takes its message and -q, -s or -v, nothing else ($_C44_WHY)"; return 1; }
    cur="$(git -C "$dir" write-tree 2>/dev/null)"
    # HAVE_H is §4.6's own reading of HEAD, taken a few lines above for this call.
    if [ -z "$tr" ] || [ "$tr" != "$cur" ] || [ "$h" != "${HAVE_H:-}" ]; then
      _APW="what is staged, or HEAD, is not what the user approved (approved tree ${tr:0:7} on ${h:0:7}; now ${cur:0:7} on ${HAVE_H:0:7})"; return 1
    fi
    return 0
  fi
  case "$op" in push|commit+push) ;; *) _APW="the approval on record is for a commit, not for a push"; return 1 ;; esac
  # No quoted argument in a push: a quoted span is compared as a placeholder, and a branch may be named like one.
  case "$CMD" in *[\"\']*) _APW="a quote in the push command. Run the push alone and unquoted: git push <remote> <branch>"; return 1 ;; esac
  _a44_collapse "$CMD" push "$tool" || { _APW="$_A44_WHY. Run the push alone: git push <remote> <branch>"; return 1; }
  _p44_scan "$_A44_S" || { _APW="the push is not in the one form an approval covers, git push <remote> <branch> ($_P44_WHY)"; return 1; }
  [ -n "$b" ] && [ -n "$r" ] && [ -n "$u" ] || { _APW="the approval record could not be read"; return 1; }
  if [ "$_P44_REMOTE" != "$r" ]; then _APW="the user approved a push to $r, not to $_P44_REMOTE"; return 1; fi
  case "$_P44_REF" in "$b"|HEAD) ;; *) _APW="the user approved a push of $b, not of $_P44_REF"; return 1 ;; esac
  cur="$(git -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null || true)"
  [ "$cur" = "$b" ] || { _APW="the user approved a push of $b, and the branch checked out now is ${cur:-<detached>}"; return 1; }
  # Where the remote pushes TO, with pushurl and pushInsteadOf applied: the name alone can be pointed elsewhere.
  cur="$(git -C "$dir" remote get-url --push "$r" 2>/dev/null)"
  [ "$cur" = "$u" ] || { _APW="the remote $r does not push to the address it pushed to when the user approved"; return 1; }
  # ...and to the branch of the same NAME. `git push origin feat/x` names no destination, and with a
  # `remote.origin.push` mapping git picks it from there: measured in review, `feat/x -> main`.
  cur="$(git -C "$dir" config --get-all "remote.$r.push" 2>/dev/null || true)"
  [ -z "$cur" ] || { _APW="the remote $r has a push mapping (remote.$r.push), so the branch this push lands on is not the one named"; return 1; }
  cur="$(git -C "$dir" rev-parse --verify --quiet HEAD 2>/dev/null || echo NONE)"
  if [ "$op" = push ]; then
    [ "$cur" = "$h" ] || { _APW="HEAD moved after the user approved the push (approved ${h:0:7}, now ${cur:0:7})"; return 1; }
    return 0
  fi
  # commit+push: HEAD has to be the commit the approved index became.
  cur="$(git -C "$dir" rev-parse --verify --quiet 'HEAD^' 2>/dev/null || echo NONE)"
  if [ "$h" = NONE ] || [ "$cur" != "$h" ]; then
    _APW="HEAD is not the commit the user approved (its parent is ${cur:0:7}, the approval was given on ${h:0:7})"; return 1
  fi
  cur="$(git -C "$dir" rev-parse --verify --quiet 'HEAD^{tree}' 2>/dev/null)"
  [ -n "$tr" ] && [ "$cur" = "$tr" ] || { _APW="the commit on HEAD does not carry what the user approved"; return 1; }
  return 0
}
# IS THE RECORDING HOOK WIRED? Asked only when a commit or a push is about to be refused, so that the refusal names
# a way that exists. It reads the settings this hook can see: the plugin's own hooks.json, the project's
# settings.json and settings.local.json, the user's settings.json. HONEST SCOPE: the text of each file is searched
# for the script's name after the event's name; it is not parsed, and managed settings are not read. A wrong answer
# changes a sentence, never the verdict: the command is refused either way. eval/doctor.sh does the parsed check.
_appr_wired(){  # 0 = prompt-approval.sh is beside this hook and a settings file wires it; else _APRW names what was read
  local f t d="${CLAUDE_PROJECT_DIR:-.}" seen="" here="${BASH_SOURCE%/*}"
  [ "$here" = "${BASH_SOURCE}" ] && here=.
  d="${d//\\//}"; d="${d%/}"
  _APRW="no prompt-approval.sh beside this hook"
  [ -f "$here/prompt-approval.sh" ] || return 1
  for f in "${CLAUDE_PLUGIN_ROOT:+${CLAUDE_PLUGIN_ROOT//\\//}/hooks/hooks.json}" "$d/.claude/settings.json" "$d/.claude/settings.local.json" "${HOME:+${HOME//\\//}/.claude/settings.json}"; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    seen="$seen${seen:+, }$f"
    t=""; IFS= read -r -d '' t < "$f" || true
    case "$t" in *'"UserPromptSubmit"'*prompt-approval.sh*) return 0 ;; esac
  done
  _APRW="read: ${seen:-no settings file found}"
  return 1
}
allow_approved(){
  gatelog ALLOW 4.4 "the user's own approval message covers this command"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"%s"}}\n' \
    "$(json_escape "§4.4: the user approved this in their own message, and what was approved is what this command does")"
  exit 0
}
# Escalate to a permission prompt only the user can answer, then let Claude run the command itself.
ask_user(){
  gatelog ASK 4.4 "commit/push approval prompt"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' "$(json_escape "$1")"
  exit 0
}
# A pre-authorised session has to clear BOTH gates, and only an explicit decision does that.
allow_preauthorised(){
  gatelog ALLOW 4.4 "CLAUDE_GIT_OK pre-authorised session"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"%s"}}\n' \
    "$(json_escape "CLAUDE_GIT_OK: session pre-authorised before it started (§4.4 headless/CI)")"
  exit 0
}
# THE WHOLE APPROVAL-GATED GIT SET IS NOW GUARDED HERE — add, commit, push and branch creation (checkout -b,
# switch -c, in every spelling the staging/branching block at the end matches). It used to be
# split with settings.json, which carried `ask` rules for all four, and that split is what made this key
# useless: a matching ask rule prompts even when a hook returns "allow", so the key could never clear it and
# headless there was nobody to answer. A pre-authorised run could not even STAGE, while §4.4 advertised the
# key as the way to work with nobody at the keyboard — the flag's only purpose, and it did not achieve it.
# Measured with the A/B harness (evals/): Crewforth arm committed 0/3 with the key set and its own gate log
# reading ALLOW. Those four settings rules are gone now, and an update strips them from existing projects.
#
# WHAT THE KEY DOES AND DOES NOT OPEN, because a wrong sentence here is what someone reads before
# misdiagnosing — this comment has been wrong twice already:
#   * §4.5 stays shut. This is reached only AFTER the destructive blocks above, so a pre-authorised session
#     still cannot force-push, amend, reset --hard or `git add -f`.
#   * §4.6 IS OPENED, deliberately, and that is easy to miss because the block sits a few lines below this
#     one and never runs when the key is set. A pre-authorised session commits WITHOUT a review record. The
#     payload CLAUDE.md §4.6 states it ("Deliberate skip: … CLAUDE_GIT_OK (headless/CI) bypasses this too")
#     and it is written here as well, because the person reading the hook is not reading that file.
# §4.5 / §4.6 — WHAT A `git commit` REALLY CARRIES, READ THE WAY THE SHELL AND GIT READ IT.
# The rules above and the scan of §4.6 below judge the command as text: a literal `--no-verify`, a literal `--amend`,
# a token walk that pairs every double quote before any single one and stops at the first `&`. A review of the
# approval route (3.1.0) measured what that lets through in the modes where the gate ASKS, and with CLAUDE_GIT_OK
# where nobody is asked at all — each line below reached the prompt with no rule firing, and each was run for real:
#     git commit -n -m x          --no-verif / --no-veri        hooks skipped (-n IS --no-verify; git takes abbreviations)
#     git commit --amen -m x      --am                          the last commit rewritten
#     git commit -m x 2>&1 -a     &> log -a     >& log -a       the working tree committed (the walk stopped at `&`)
#     git commit -mxm b.txt                                     b.txt committed (-m took `xm`; the walk swallowed b.txt)
#     git commit -m 'a"' -a ; echo 'b"'                         -a hidden inside quotes paired the wrong way
#     git commit -F - <<END -a                                  -a after a here-document operator
#     git commit -m a\;b -a                                     an escaped `;` read as a separator
#     bash -c 'git commit -am x'      eval "git commit -a …"    a commit this gate cannot read at all
#     cd ../other && git commit …     pushd …     env -C …      another repository than the one the record is for
#     GIT_INDEX_FILE=… git commit     GIT_DIR=…   export GIT_…  another index, another repository
#     GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath …      the hooks switched off through the environment
# So the command is read left to right: quotes as the shell pairs them, an escaped character as a character, a
# here-document's body as data, `2>&1` / `&>` / `>&` as redirections and not as separators. Then every `git commit`
# in the call is read with git's own option table: a cluster letter by letter, a value where git takes one, a long
# option only when it is written out in full.
# THIS ONLY EVER ADDS A REFUSAL. The older rules and `_c46_scan` still run and still decide; nothing they refuse is
# let through here. An option this table does not know is refused, with the reason: an abbreviation is how the nine
# lines above got in, and guessing which option it stands for is the same mistake again.
# _c47_read and _c47_w, which read it, stand above the gate-file rule: that rule reads a call with them too.
_c47_exp(){  # $1 = a raw token of a commit, $2 = the word it reads as -> sets _C47_EXP when the shell would change it
  # What the shell will make of an argument has to be readable. An unquoted `$NAME` is, when NAME was given one
  # literal word earlier in the call; a glob, a brace list, or any other expansion is not: measured,
  # `o=' -a'; git commit -m x$o`, `git commit -m {x,-a}` and `git commit -m ?.txt` all committed the working tree.
  local v="$1" m="$_C47_M" bad="${_WAT:-0}" c
  while :; do case "$v" in *"$m"*) v="${v%%"$m"*}${v#*"$m"*"$m"}" ;; *) break ;; esac; done     # the unquoted part
  case "$v" in *[\*\?\[\{]*) bad=1 ;; esac
  while [ "$bad" = 0 ]; do
    case "$v" in *\$*) ;; *) break ;; esac
    v="${v#*\$}"; c="${v%%[!A-Za-z0-9_]*}"
    case "$_C47_VARS" in *" $c "*) [ -n "$c" ] || bad=1 ;; *) bad=1 ;; esac
  done
  [ "$bad" = 1 ] && _C47_EXP="${2:0:60}"
  return 0
}
_c47_val(){  # $1 = the raw token an option takes as its value: the same question
  case "$1" in *[\$\*\?\[\{]*|*"$_C47_M"*) _c47_w "$1"; [ "$_WX" = 1 ] && _c47_exp "$1" "$_W" ;; esac
  return 0
}
_c47_args(){  # $1 = 1: the words after `git` (Start-Process git …) | 0: all of them (a command word held in a variable)
              # $2… = the tokens up to the next separator. Appends one line to _C47_ARGS: those words written as the
              # git command they are, `git push --force origin main`, so the rules that judge a git command can read it.
              # PowerShell hands the arguments over as a list ('push','--force') or as one string ("push --force"):
              # both come out as the same words. Start-Process's own parameters are left out; they are not git's.
  local v w out="" on=1 nc=0
  [ "$1" = 1 ] && on=0
  shift
  shopt -q nocasematch && nc=1; shopt -s nocasematch
  for v in "$@"; do
    [ "$v" = ";" ] && break
    _c47_w "$v"; w="${_W//,/ }"
    if [ "$on" = 0 ]; then case "$w" in git|git.exe) on=1 ;; esac; continue; fi
    [ "$_WQ" = 0 ] && case "$w" in
      -FilePath|-ArgumentList|-Args|-Credential|-WorkingDirectory|-LoadUserProfile|-NoNewWindow|-PassThru|-RedirectStandardError|-RedirectStandardInput|-RedirectStandardOutput|-WindowStyle|-Wait|-UseNewEnvironment|-Verb|-Confirm*|-WhatIf) continue ;;
    esac
    out="$out $w"
  done
  [ "$nc" = 0 ] && shopt -u nocasematch
  [ "$on" = 1 ] && [ -n "$out" ] && _C47_ARGS="$_C47_ARGS${_C47_ARGS:+$'\n'}git$out"
  return 0
}
_c47_scan(){  # $1 = command. Sets: _C47_N (commits read) _C47_WT _C47_NV _C47_AM _C47_UNK _C47_EXP _C47_ENV _C47_SH _C47_CFG
              #                   _C47_CD (0 none · 1 one plain target, in _C47_CDT · 2 a target that cannot be read)
  local tok ph=cmd unglob=0 body c v m i raw rcd=0 rcdt="" envf=0 wrapped=0 novars=0 vc=0
  _C47_VARS=" "
  _C47_SHRE='(^|[^A-Za-z0-9_-])git[[:space:]]+(-[^[:space:]]+[[:space:]]+)*commit([[:space:]]|$)'
  _C47_N=0; _C47_WT=""; _C47_NV=""; _C47_AM=""; _C47_UNK=""; _C47_EXP=""; _C47_ENV=""; _C47_SH=""; _C47_CFG=""; _C47_UNR=""; _C47_SUB=""; _C47_ARGS=""; _C47_CD=0; _C47_CDT=""
  _c47_read "$1"; m="$_C47_M"
  case "$-" in *f*) ;; *) unglob=1; set -f ;; esac
  set -- $_C47_T
  [ "$unglob" = 1 ] && set +f
  while [ $# -gt 0 ]; do
    raw="$1"; shift
    [ "$raw" = ";" ] && { ph=cmd; wrapped=0; vc=0; continue; }
    _WAT=0
    case "$raw" in "$m"*|*"$m"*) _c47_w "$raw" ;; *) _W="$raw"; _WQ=0; case "$raw" in *[\$\*\?\[\{]*) _WX=1 ;; *) _WX=0 ;; esac ;; esac
    tok="$_W"
    # THE VARIABLES THAT CHANGE WHAT GIT READS — the repository, the index, the object store, the configuration —
    # wherever in the call they are set or exported: in front of the commit, in an earlier command, as an argument
    # of export or env, quoted or not. HOME and XDG_CONFIG_HOME are among them: they decide which global
    # configuration git reads. GIT_AUTHOR_* / GIT_COMMITTER_* only describe the commit and are let through.
    v="$tok"; case "$v" in '$'[Ee][Nn][Vv]:*) v="${v:5}" ;; esac                     # PowerShell: $env:GIT_DIR='…'
    case "${v%%=*}" in
      GIT_DIR|GIT_WORK_TREE|GIT_INDEX_FILE|GIT_COMMON_DIR|GIT_OBJECT_DIRECTORY|GIT_ALTERNATE_OBJECT_DIRECTORIES|GIT_NAMESPACE|GIT_EXEC_PATH|GIT_CONFIG*)
        [ "$ph" = commit ] || envf=1 ;;                                               # named (export GIT_DIR) or assigned
      HOME|XDG_CONFIG_HOME)
        [ "$ph" = commit ] || case "$v" in *=*) envf=1 ;; esac ;;                     # only when assigned
    esac
    case "$ph" in
      skip) # Not a command this table knows. A bare `git` further along the same command is still git (timeout 10 git …,
            # xargs git …, nice git …), so the reading goes on from there.
            case "$tok" in git|git.exe|*/git|*/git.exe) [ "$_WX" = 0 ] && ph=git ;; esac
            # The command word was a variable (`$g commit -n`, PowerShell's `& $g commit -n`): what runs cannot be read.
            [ "$vc" = 1 ] && [ "$tok" = commit ] && _C47_UNR="a command held in a variable, followed by commit"
            continue ;;
      cmd)
        case "$tok" in
          [A-Za-z_]*=*|[A-Za-z_]*+=*)
            v="${tok%%=*}"; v="${v%+}"
            case "$v" in *[!A-Za-z0-9_]*) ph=skip ;; *)
              # A plain assignment. Its name is remembered when the value is one literal word: only then may a later
              # `$NAME` stand inside a commit argument (the shell cannot split or expand it into something else).
              # IFS changes how every one of them is split, and after `read`, `unset`, `export` and
              # their kin (below) a name no longer holds what it was given: all of those forget instead of remember.
              c="${tok#*=}"
              [ "$v" = IFS ] && novars=1
              case "$novars$_WX$c" in 1*|01*|*[$' \t\n']*|*[\*\?\[\{\$\`]*|00) _C47_VARS="${_C47_VARS/ $v / }" ;; *) _C47_VARS="$_C47_VARS$v " ;; esac
              [ "$novars" = 1 ] && _C47_VARS=" " ;;
            esac ;;
          '{'|'}'|'!'|if|then|else|elif|fi|do|done|while|until|time|sudo|command|builtin|exec|nohup|nice) wrapped=1 ;;   # the command follows
          -*) [ "$wrapped" = 1 ] || ph=skip ;;                                           # an option of that wrapper
          export|declare|typeset|readonly|local|read|unset|let|source|.|for|select|getopts|mapfile|readarray) novars=1; _C47_VARS=" "; ph=skip ;;
          set|shift) ph=skip ;;
          printf) case " $* " in *" -v "*) novars=1; _C47_VARS=" " ;; esac; ph=skip ;;
          env) ph=env ;;
          cd|pushd|chdir|Set-Location|sl|Push-Location)
            # Where the commit will run. One plain target can be resolved and compared; anything else cannot.
            while :; do case "${1:-}" in -[!-]*|--) shift ;; *) break ;; esac; done
            v="${1:-}"
            case "$v" in ''|\;) v="" ;; *) _c47_w "$v"; v="$_W"; [ "$_WX" = 1 ] && v=""; [ "$v" = - ] && v="" ;; esac
            # `cd "$(git rev-parse --show-toplevel)" && git commit …` goes to the top of THIS repository: no change.
            [ "$_W" = '$(git rev-parse --show-toplevel)' ] && { ph=skip; continue; }
            if [ -n "$v" ] && [ "$rcd" = 0 ]; then rcd=1; rcdt="$v"; else rcd=2; fi
            ph=skip ;;
          Start-Process|saps|start)
            # PowerShell: `Start-Process git -ArgumentList 'commit','-n','-m','x'` (measured: committed, hooks skipped).
            c=0
            for v in "$@"; do
              [ "$v" = ";" ] && break
              _c47_w "$v"; case "$_W" in git|git.exe) c=1 ;; *commit*) [ "$c" = 1 ] && _C47_SH="$tok" ;; esac
            done
            _c47_args 1 "$@"
            ph=skip ;;
          bash|sh|zsh|dash|ksh|eval|xargs|trap|pwsh|powershell|powershell.exe|pwsh.exe|cmd|cmd.exe|Invoke-Expression|iex|*/bash|*/sh|*/zsh)
            # A shell handed a QUOTED script that holds a commit: `bash -c 'git commit -am x'`, `eval "git commit -a"`.
            # Its arguments cannot be read from here. `bash build.sh` beside a here-document that merely mentions
            # git commit is not that, and a first version that looked only at the word `bash` refused 40 such calls.
            for v in "$@"; do
              # Invoke-Expression takes an expression: `Invoke-Expression ('git commit -' + 'n -m x')` puts the script
              # behind a parenthesis, which reads as a separator here, so for it the look goes on to the end of the call.
              [ "$v" = ";" ] && { case "$tok" in Invoke-Expression|iex) continue ;; esac; break; }
              case "$v" in *"$m"*) _c47_w "$v"; [[ $_W =~ $_C47_SHRE ]] && _C47_SH="$tok" ;; esac
            done
            case "$tok" in eval|xargs) wrapped=1 ;; *) ph=skip ;; esac ;;                # after eval / xargs the command is read on
          git|git.exe|*/git|*/git.exe) ph=git ;;
          *) [ "$_WX" = 1 ] && { vc=1; _c47_args 0 "$@"; }; ph=skip ;;
        esac ;;
      env)
        case "$tok" in
          -C|--chdir) rcd=2; shift ;;
          --chdir=*|-C?*) rcd=2 ;;
          -u|--unset|-S|--split-string) shift ;;
          -*|[A-Za-z_]*=*) ;;
          git|git.exe|*/git|*/git.exe) ph=git ;;
          *) ph=skip ;;
        esac ;;
      git)
        case "$tok" in
          -c|--config-env)
            # A setting for this one command. The ones that change what a commit does are refused whatever the
            # quoting: `-c 'core.hooksPath=/dev/null'`, `-c include.path=f`, `-c alias.ci='commit -a'`.
            v="${1:-}"; [ $# -gt 0 ] && shift
            _c47_w "$v"
            if [ "$_WX" = 1 ]; then _C47_CFG="a -c setting the shell expands first"
            else
              shopt -q nocasematch && i=1 || i=0; shopt -s nocasematch
              case "$_W" in *hookspath*|include.*|includeif.*|alias.*|core.worktree*|core.fsmonitor*) _C47_CFG="-c ${_W%%=*}" ;; esac
              [ "$i" = 0 ] && shopt -u nocasematch
            fi ;;
          -C|--git-dir|--work-tree|--namespace|--exec-path|--super-prefix) shift ;;
          -*) ;;
          @*|*\$*)   # (a backtick arrives here as `$`: the reader writes one for the substitution it opens)
                    # The subcommand is filled in by the shell: `git $c -n` after c=commit, PowerShell's splat `git @a`
                    # after $a = @('commit','-n') (measured on PowerShell 5.1: both committed with the hooks skipped) —
                    # and a subcommand with an expansion INSIDE it, quoted or not: `git com${z}mit`, `git "$c"`,
                    # `git $(printf com)mit`, `git pu${z}sh --force`. No rule that looks for a git command by its
                    # name sees these (measured: each passed every gate, and git ran the command).
                    _C47_SUB="${tok:0:40}"; ph=skip ;;
          commit) ph=commit; _C47_N=$((_C47_N+1))
                  if [ "$rcd" != 0 ] && [ "$_C47_CD" = 0 ]; then _C47_CD=$rcd; _C47_CDT="$rcdt"; fi ;;
          *) ph=skip ;;
        esac ;;
      commit)
        case "$raw" in
          '<<H') continue ;;                                                           # a here-document; arguments may follow it
          '<<<') shift; continue ;;
          [\<\>]*|[0-9][\<\>]*|[0-9][0-9][\<\>]*|'&>'*) case "$raw" in *[\<\>\&]) case "${1:-}" in ''|\;) ;; *) shift ;; esac ;; esac; continue ;;
        esac
        [ "$_WX" = 1 ] && _c47_exp "$raw" "$tok"
        case "$tok" in
          --) case "${1:-}" in ''|\;) ;; *) _C47_WT="a pathspec after --" ;; esac; ph=skip ;;
          --message|--file|--author|--date|--reedit-message|--reuse-message|--fixup|--squash|--cleanup|--template|--trailer|--unified|--inter-hunk-context)
            case "${1:-}" in ''|\;) ;; *) _c47_val "$1"; shift ;; esac ;;
          --message=*|--file=*|--author=*|--date=*|--reedit-message=*|--reuse-message=*|--fixup=*|--squash=*|--cleanup=*|--template=*|--trailer=*|--unified=*|--inter-hunk-context=*|--gpg-sign|--gpg-sign=*|--untracked-files|--untracked-files=*) ;;
          --signoff|--quiet|--verbose|--dry-run|--short|--branch|--porcelain|--long|--null|--edit|--allow-empty|--allow-empty-message|--post-rewrite|--status|--reset-author|--ahead-behind|--verify|--pathspec-file-nul|--help) ;;
          --no-signoff|--no-quiet|--no-verbose|--no-dry-run|--no-short|--no-branch|--no-porcelain|--no-long|--no-null|--no-edit|--no-allow-empty|--no-allow-empty-message|--no-post-rewrite|--no-status|--no-reset-author|--no-ahead-behind|--no-all|--no-only|--no-include|--no-interactive|--no-patch|--no-amend|--no-untracked-files) ;;
          --all) _C47_WT="--all" ;;
          --only) _C47_WT="--only" ;;
          --include) _C47_WT="--include" ;;
          --interactive|--patch) _C47_WT="$tok" ;;
          --pathspec-from-file|--pathspec-from-file=*) _C47_WT="--pathspec-from-file" ;;
          --no-verify) _C47_NV="--no-verify" ;;
          --amend) _C47_AM="--amend" ;;
          --no-gpg-sign) ;;                                                             # §4.5 above refuses it by name
          --*) # Not an option git commit has under that exact name: an abbreviation, or something newer than this table.
               case "--no-verify" in "$tok"*) _C47_NV="$tok (git reads it as --no-verify)" ;; esac
               case "--amend" in "$tok"*) _C47_AM="$tok (git reads it as --amend)" ;; esac
               _C47_UNK="$tok" ;;
          -?*) # A cluster. Letter by letter, as git does: a flag, or a letter that takes a value — the rest of the
               # token when there is a rest, the next token when there is none (-m -F -t -C -c -U), never the next one
               # for -S and -u, whose value is optional and attached.
               body="${tok#-}"
               while [ -n "$body" ]; do
                 c="${body:0:1}"; body="${body:1}"
                 case "$c" in
                   q|v|s|e|z|h) ;;
                   n) _C47_NV="-n in ${tok:0:40} (git reads it as --no-verify)" ;;
                   a) _C47_WT="-a in ${tok:0:40}" ;;
                   o) _C47_WT="-o in ${tok:0:40}" ;;
                   i) _C47_WT="-i in ${tok:0:40}" ;;
                   p) _C47_WT="-p in ${tok:0:40}" ;;
                   m|F|t|C|c|U) [ -z "$body" ] && case "${1:-}" in ''|\;) ;; *) _c47_val "$1"; shift ;; esac; body="" ;;
                   S|u) body="" ;;
                   *) _C47_UNK="${tok:0:40}"; body="" ;;
                 esac
               done ;;
          *) _C47_WT="a pathspec" ;;
        esac ;;
    esac
  done
  [ "$envf" = 1 ] && [ "$_C47_N" != 0 ] && _C47_ENV="a variable that changes what git reads"
  return 0
}

# The §4.5 half of what that reading finds is judged HERE, before the pre-authorised branch below: with CLAUDE_GIT_OK
# nobody is asked, so a commit that skips its hooks or rewrites the last commit must not reach that allow. (§4.6 is
# not judged for such a session, by design: it commits without a review record.)
# The reading runs for a commit this hook recognises — and for a call that merely holds the words `git` and `commit`,
# because `'git' commit -n`, `git 'commit' -n` and `git -c alias.ci=commit ci -n` are commits the recognition above
# (a pattern on the text) does not see at all: measured, each ran with every commit gate silent.
_C47_N=0; _C47_WT=""; _C47_CD=0; _C47_SUB=""; _c47_seen=0
_C47_MAX=32768
_cmd_bytes(){ local LC_ALL=C; _CB=${#1}; }   # $1 = text -> _CB: its length in bytes, whatever the session's locale
if git_has "$CMD_SEEN" 'commit'; then _c47_seen=1; fi
_c47_try=0
case "$CMD_SEEN" in *[Mm][Ii][Tt]*)   # with quotes, backslashes and joined lines taken out: `g\it`, `com\<newline>mit`
  _gsub "$CMD_SEEN" '\\'$'\n' '' bs; _unquoted "$_GS"; _t="$_GS"
  # Both words, in either order: `$a = @('commit','-n'); git @a` names commit first.
  case "$_t" in *[Gg][Ii][Tt]*) case "$_t" in *[Cc][Oo][Mm][Mm][Ii][Tt]*) _c47_try=1 ;; esac ;; esac ;;
esac
# The same reading for a git call whose words the shell fills in: a `git` with a `$` or a backtick after it. Which
# word that is — the subcommand, or an ordinary argument such as `-C "$dir"` — only the reading can tell.
_c47_sub=0
case "$CMD" in *[Gg][Ii][Tt]*[\$\`]*) _c47_sub=1 ;; esac
_c47_no(){  # the lines for the session; the rule is logged by the caller, by its literal name
  echo "GUARD (§4.5): $1" >&2; shift
  while [ $# -gt 0 ]; do echo "$1" >&2; shift; done
  exit 2
}
# PowerShell can start a program without writing it as a command: [Diagnostics.Process]::Start('git','commit -n -m x'),
# or a ProcessStartInfo handed to it. The arguments are one string that no rule here reads as a git command
# (measured on Windows: the gate was silent). So git and that class in one PowerShell call are refused; the class with
# any other program, and git as a command, are not touched. Through the PowerShell tool only: in a Bash call the two
# words together were, on 4986 real commands, a here-document that mentions them (2 of 2).
case "$INPUT" in *'"tool_name":"PowerShell"'*|*'"tool_name": "PowerShell"'*) _c47_ps=1 ;; *) _c47_ps=0 ;; esac
[ "$_c47_ps" = 1 ] && case "$CMD_UQ" in *[Pp][Rr][Oo][Cc][Ee][Ss][Ss]*)
  if _ere i "$CMD_UQ" '(diagnostics\.process|\[process(startinfo)?\])' '*' \
     && _ere i "$CMD_UQ" '(^|[^A-Za-z0-9_-])git(\.exe)?([^A-Za-z0-9_-]|$)' '*[Gg][Ii][Tt]*'; then
    gatelog BLOCK 4.5 "git started through System.Diagnostics.Process"
    _c47_no \
    "this call starts git through System.Diagnostics.Process, where its arguments are a string no rule reads." \
    "Run git as a command, so the gate can see which one it is: git commit …, git push …"
  fi ;;
esac
# PowerShell can also hand git its arguments instead of writing them after it: Start-Process git -ArgumentList
# 'push','--force', or a command word held in a variable (`& $g push --force`). A commit written that way is refused
# below; push --force, reset --hard and clean -f were not read at all (measured: 21 of 23 such forms passed; the two
# that did not hold core.hooksPath, which its own rule finds as one word wherever it stands). So a PowerShell call
# that holds one of those three words is read too, and its arguments are judged as the git command they make.
_c47_psd=0
[ "$_c47_ps" = 1 ] && case "$CMD_UQ" in *[Pp][Uu][Ss][Hh]*|*[Rr][Ee][Ss][Ee][Tt]*|*[Cc][Ll][Ee][Aa][Nn]*) _c47_psd=1 ;; esac
if [ "$_c47_seen" = 1 ] || [ "$_c47_try" = 1 ] || [ "$_c47_sub" = 1 ] || [ "$_c47_psd" = 1 ]; then
  # A SIZE THIS READING IS NOT ASKED TO EXCEED. A PreToolUse hook that reaches its timeout (600 s) stops nothing, and
  # the reading below costs the square of the size for some shapes — measured on macOS, a commit followed by `2>&1`
  # repeated: 16 KB 10 s, 32 KB 39 s, 64 KB 154 s, so about 128 KB is where the timeout is. A command without a commit
  # is not read this way (64 KB of the same shape: 0.4 s) and is not limited. The limit is where the worst measured
  # shape is 15 times under the timeout; of 12387 distinct real commands the largest is 31639 bytes, the largest that
  # holds a commit 28880.
  _cmd_bytes "$CMD"
  if [ "$_CB" -gt "$_C47_MAX" ] && { [ "$_c47_seen" = 1 ] || [ "$_c47_try" = 1 ]; }; then
    gatelog BLOCK 4.5 "git commit in a command too large to read"
    _c47_no \
    "this command holds a git commit and is $_CB bytes long; the gate reads a commit command of up to $_C47_MAX bytes." \
    "A larger one could take longer to read than the hook is given, and a hook that runs out of time stops nothing," \
    "so it is refused unread. Write the message to a file and run 'git commit -F <file>'; run the other steps as" \
    "commands of their own."
  fi
  if [ "$_CB" -gt "$_C47_MAX" ] && [ "$_c47_sub" = 0 ]; then
    gatelog BLOCK 4.5 "PowerShell call too large to read"
    _c47_no \
    "this PowerShell call names a git command the gate judges by its arguments (push, reset, clean) and is $_CB bytes long; the gate reads such a call of up to $_C47_MAX bytes." \
    "A larger one could take longer to read than the hook is given, and a hook that runs out of time stops nothing," \
    "so it is refused unread. Put the long content in a file with the Write tool and run the command on its own."
  fi
  if [ "$_CB" -gt "$_C47_MAX" ]; then
    gatelog BLOCK 4.5 "git call with an expansion in a command too large to read"
    _c47_no \
    "this command runs git with words the shell fills in and is $_CB bytes long; the gate reads such a command of up to $_C47_MAX bytes." \
    "A larger one could take longer to read than the hook is given, and a hook that runs out of time stops nothing," \
    "so it is refused unread. Put the long content in a file with the Write tool and run the git command on its own."
  fi
  _c47_scan "$CMD"
  # git itself redefined for this call: `git(){ command git "$@" -a; }; git commit -m x` committed the working tree.
  _ere s "$CMD" '(^|[;&|[:space:]])(function[[:space:]]+)?git[[:space:]]*\([[:space:]]*\)|alias[[:space:]]+git=' '*git*' \
    && _C47_CFG="git redefined as a function or an alias"
  if [ -n "$_C47_SUB" ]; then
    gatelog BLOCK 4.5 "git subcommand the shell fills in"
    _c47_no \
    "this call runs git with a subcommand the shell fills in ($_C47_SUB), so which git command it is cannot be read." \
    "Every rule about a git command looks for it by name. Write the subcommand out: git commit …, git push …"
  fi
  if [ "$_c47_ps" = 1 ] && [ -n "$_C47_ARGS" ]; then
    while IFS= read -r _t; do
      # What block() prints names the rule; this line says where the command was read from.
      ( _git_d45 "$_t"; exit 0 ) \
        || { echo "GUARD: read from the arguments this PowerShell call hands to git, or to a command held in a variable: ${_t:0:120}" >&2; exit 2; }
    done <<< "$_C47_ARGS"
  fi
  # Everything below judges a COMMIT. A call that was read only because git is followed by an expansion, and holds
  # no commit, is finished here: measured on 4986 real commands, letting the commit rules run on it refused
  # `git -c core.autocrlf=$ac archive …` twice for "a -c setting the shell expands first".
  if [ "$_c47_seen" = 0 ] && [ "$_c47_try" = 0 ]; then
    _C47_NV=""; _C47_AM=""; _C47_ENV=""; _C47_CFG=""; _C47_UNR=""; _C47_EXP=""; _C47_UNK=""; _C47_SH=""
    _C47_N=0; _C47_WT=""; _C47_CD=0
  fi
  if [ -n "$_C47_NV" ]; then
    gatelog BLOCK 4.5 "hook skip by -n or an abbreviated --no-verify"
    _c47_no \
    "this commit skips its hooks: $_C47_NV." \
    "Turning a gate off is not a step in any task. If a hook is wrong, fix the hook and say so."
  fi
  if [ -n "$_C47_AM" ]; then
    gatelog BLOCK 4.5 "abbreviated git commit --amend"
    _c47_no \
    "this commit rewrites the last one: $_C47_AM." \
    "A new commit usually reaches the same end without rewriting; an amend is run only on an explicit request, by the user."
  fi
  if [ -n "$_C47_ENV" ]; then
    gatelog BLOCK 4.5 "git commit under a GIT_ variable set in the command"
    _c47_no \
    "this commit runs with $_C47_ENV (GIT_DIR, GIT_INDEX_FILE, GIT_CONFIG_…, HOME and their kin), so git may read another" \
    "repository, another index or another configuration" \
    "than the one this gate reads. Run 'git commit' with no GIT_ variable in front of it."
  fi
  if [ -n "$_C47_CFG" ]; then
    gatelog BLOCK 4.5 "git commit under a setting given in the command"
    _c47_no \
    "this call runs git with $_C47_CFG, which changes what a commit does (the hooks it runs, the files it reads, or" \
    "what the word 'commit' means). Run 'git commit' without it."
  fi
  if [ "$_c47_seen" = 0 ] && [ "$_C47_N" != 0 ]; then
    gatelog BLOCK 4.5 "git commit written so that it is not recognised"
    _c47_no \
    "this call runs a git commit spelled so that it does not read as one (a quoted or escaped command word)." \
    "Write it plainly: git commit -m '…'"
  fi
  if [ -n "$_C47_UNR" ]; then
    gatelog BLOCK 4.5 "git commit through a command the shell fills in"
    _c47_no \
    "this call holds the word commit and runs $_C47_UNR, so what git is asked to do cannot be read." \
    "Write the command out: git commit -m '…'"
  fi
  if [ -n "$_C47_EXP" ]; then
    gatelog BLOCK 4.5 "git commit argument the shell expands"
    _c47_no \
    "the argument '$_C47_EXP' is changed by the shell before git reads it (a variable that is not one plain word, a" \
    "glob or a brace list), so it may become more arguments than it looks like. Quote it."
  fi
  if [ -n "$_C47_UNK" ]; then
    gatelog BLOCK 4.5 "git commit option the gate cannot read"
    _c47_no \
    "'$_C47_UNK' is not an option of git commit under that exact name. git accepts abbreviations, which is how" \
    "--no-verify and --amend get past a rule that looks for their names. Write the option out in full."
  fi
  if [ -n "$_C47_SH" ]; then
    gatelog BLOCK 4.5 "git commit inside a nested shell"
    _c47_no \
    "this call hands a git commit to '$_C47_SH', where its arguments cannot be read (a quoted script, eval, xargs)." \
    "Run 'git commit' directly."
  fi
fi
if git_has "$CMD_SEEN" 'add|commit|push|checkout|switch'; then
  # The key is granted by the user's environment, never by the command line the model composes.
  if _grep "$CMD" -q 'CLAUDE_GIT_OK'; then
    gatelog BLOCK 4.4 "approval key set inside the command"
    echo "GUARD (§4.4): the attempt to set the approval key (CLAUDE_GIT_OK) inside the command was rejected." >&2
    echo "The key is set only by the user, before the session starts." >&2
    exit 2
  fi
  case "${CLAUDE_GIT_OK:-}" in
    1|yes|true|on|YES|TRUE|ON) allow_preauthorised ;;   # pre-authorised session (headless/CI)
  esac
fi
if git_has "$CMD_SEEN" 'commit|push'; then
  # §4.6 — A COMMIT NEEDS A CLEAN REVIEW OF THIS DIFF.
  # crew-review-agent records what it cleared in .claude/review-pass.json; this reads it back and compares two
  # EXACT facts: the sha256 of the staged diff, and the HEAD it was reviewed against. There is deliberately NO
  # wall-clock TTL — a time window both rejects records that are still correct (same diff, same base, an hour
  # later) and accepts ones that are not (same minute, rebased underneath). Two hashes answer the question a
  # timestamp only approximates.
  #
  # Nested inside the commit|push block on purpose: the matcher below costs a process, and on Git Bash a fork
  # is 20-50 ms on a hook that runs before EVERY Bash call. Here it runs only when a commit or push is already
  # on the table. Scope is `commit` alone — a push stages nothing, so it has no diff of its own to review.
  if git_has "$CMD_SEEN" 'commit'; then
    # Two questions have to be answered before the record means anything, and BOTH are about the command's own
    # shape: is git pointed at another worktree, and does this commit take its content from the WORKING TREE
    # instead of the index? The second one is not a nicety. MEASURED here (macOS, git 2.54.0), with a reviewed
    # line staged and an unreviewed line left unstaged in the same file:
    #
    #   git commit -m c              record matches, commit clean          <- the flow this gate is built for
    #   git commit --amend -m c      record matches, commit clean
    #   git commit -m c -- a.txt     record matches, UNREVIEWED LINE IN THE COMMIT
    #   git commit --only a.txt      record matches, UNREVIEWED LINE IN THE COMMIT
    #   git commit --include a.txt   record matches, UNREVIEWED LINE IN THE COMMIT
    #   git commit -o/-i a.txt       record matches, UNREVIEWED LINE IN THE COMMIT
    #   git commit -a                record matches, UNREVIEWED LINE IN THE COMMIT
    #
    # So these forms are a FAIL-OPEN, not an inconvenience: git takes those paths from the working tree and
    # ignores what is staged, while this hook hashes the index BEFORE git runs. The record is truthful and
    # irrelevant at the same time. (§4.1-4.3 are unaffected: git hands its own pre-commit hook a temporary index
    # holding the real committed state, measured, so the trace and secret scans still see what lands.)
    #
    # The scan below is BUILTIN-ONLY — no grep, so the ordinary commit now pays zero processes here where it used
    # to pay one, which on Git Bash is 62-135 ms. It is a token walk rather than a regex on purpose: the flag or
    # path has to be an argument of THIS `git commit`, and the previous regex version could only manage that by
    # refusing to look past the first non-option token, which left `git commit -m x -a` uncaught by its own
    # admission. Stripping quoted spans first is what makes looking further safe, and it is load-bearing: with
    # the strip removed, 7 cases of the table in the suite go red — among them `git commit -m "add -a flag docs"`
    # and `ls -la && git commit -m x`, the two false positives that were MEASURED on the first version of this
    # rule. It has to be a function because it uses `set --` to split, which would otherwise eat the script's own
    # arguments.
    _c46_scan() {
      _C46_REDIR=0; _C46_WT=""
      local s="$1" pre rest
      # An ESCAPED quote is not a delimiter, so it is neutralised before anything tries to pair quotes.
      # `git commit -m 'don'\''t break this'` is the canonical POSIX way to put an apostrophe in a
      # single-quoted string, and it was MEASURED refused: the pairing read `'don'` as one span and then lost
      # the rest, leaving `break` looking like a pathspec. Its argv is identical to the `-m "don't break this"`
      # spelling, which was already clean — the same one-command-two-spellings trap as the quoted pathspec, in
      # the over-block direction this time. An apostrophe in a commit message is not an edge case.
      # NORMALISE TO REAL CHARACTERS FIRST, so every rule below sees one shape. Two spellings of the same command
      # reach this code and they are not interchangeable: with `jq` the command arrives DECODED and carries real
      # control characters, and on a stock machine without it the fallback parser leaves JSON's two-character
      # `\r` and `\n` in place. A stock Windows machine is the second case, so there the fallback IS the product.
      #
      # ALL carriage returns go, escaped or real, and THIS is the line that fixes the defect CI caught — stated
      # plainly because the first explanation written here was wrong. A CI run on `windows-latest` refused
      # `git commit \` + CRLF + `  -m c` while the same case passed on macOS AND on a real Windows desktop, and
      # the cause is the TIER: that image has jq, so the command arrives DECODED, while a stock desktop has
      # neither jq nor python3 and sees JSON's two-character escapes. A Windows-native binary also opens stdout
      # in TEXT mode, so every LF it writes becomes CRLF — and a command that already held `\r\n` reaches the
      # hook as `\` + CR + CR + LF. The previous single CRLF fold ate one CR, the continuation rule then looked
      # for `\` + LF, found the other CR in the way, and the lone backslash was read as a pathspec. Stripping
      # every CR handles any number of them with no loop. Isolated by measurement: this one line, applied to the
      # failing version on its own, turns that case green.
      #
      # A LONE CR keeps its verdict rather than its bytes: it vanishes into the token before it, so
      # `git commit -m c<CR>echo done` still leaves `done` a bare token and is still refused — confirmed correct
      # by a Windows session that checked bash's own argv (CR is not in IFS, so git really is handed `done`).
      #
      # The bracket expression `[\\]` is used for every backslash below, and it is NOT what fixed the above. It
      # replaced escaped patterns on a hypothesis about bash 5 reading them differently, and that hypothesis was
      # MEASURED FALSE on bash 5.3.15 — both spellings behave alike there. It stays only because a bracket
      # expression cannot be misread by anyone (calibrated here: `[\\]n` matches a backslash before an `n` and
      # leaves a bare `n` alone) and because it keeps replacements free of backslashes. No correctness claim.
      # Through _gsub (see there): the same substitutions, a piece at a time.
      _gsub "$s" '[\\]r' '' bs; _gsub "$_GS" $'\r' ''; _gsub "$_GS" '[\\]n' $'\n' bs
      _gsub "$_GS" '[\\]'"\\'" Q bs; _gsub "$_GS" '[\\]\"' Q bs; s="$_GS"
      # A quoted span collapses to the single placeholder `Q`, and this is the whole design: the CONTENT of a
      # quote must not be read as an option or a path, but the TOKEN has to survive. The first version DELETED
      # the span, and that was a measured fail-open on Windows — `git commit -m c "a.txt"` and
      # `git commit -m c -- "a.txt"` lost the pathspec entirely and were allowed, while their unquoted spellings
      # were refused, and both commit the same unreviewed line. No trick is needed to get past a gate like that,
      # only the ordinary habit of quoting a path, which is mandatory once it contains a space. The placeholder
      # keeps adjacency too, so `-m"msg"` becomes `-mQ` (an attached value, correct) and not `-m Q`.
      # Double quotes go FIRST: an apostrophe inside a double-quoted message (`-m "don't"`) is ordinary, whereas
      # a double quote inside a single-quoted one is rare, so this order mangles the rarer shape.
      # THE WALK IS BY LENGTH, and only over what is left. It used to be `rest="${s#*\"}"` on the whole string, and
      # that one expansion costs the SQUARE of the distance to the quote in bash (measured, bash 3.2, one call: 13 ms at
      # 5 KB, 108 ms at 10 KB, 317 ms at 21 KB) — once per pair, on a string whose collapsed front keeps growing. A
      # quote-dense commit message therefore took 6 s at 10 KB, 14 s at 16 KB and 335 s at 46 KB (macOS; 14.2 s at
      # 18 KB on Windows), in 3.0.1 too, and a hook that reaches its 600 s timeout does not block. The result is the
      # same string: the text before a pair holds no quote and neither does the `Q` that replaces it, so the next pair
      # is the first one in the remainder (pinned in smoke-test against the old loop, on the same inputs).
      local acc="" p2
      while :; do
        case "$s" in *\"*\"*) ;; *) break ;; esac
        pre="${s%%\"*}"; rest="${s:${#pre}+1}"; p2="${rest%%\"*}"; acc="$acc${pre}Q"; s="${rest:${#p2}+1}"
      done
      s="$acc$s"; acc=""
      while :; do
        case "$s" in *\'*\'*) ;; *) break ;; esac
        pre="${s%%\'*}"; rest="${s:${#pre}+1}"; p2="${rest%%\'*}"; acc="$acc${pre}Q"; s="${rest:${#p2}+1}"
      done
      s="$acc$s"
      # A backslash-newline is a LINE CONTINUATION, the opposite of a separator: it JOINS. Measured, before this,
      # `git commit \` + newline + `  -m c` refused the commit, because the lone `\` became a token and read as a
      # pathspec. It has to run before the conversion below, or the newline is gone when we look for it.
      _gsub "$s" '[\\]'$'\n' ' ' bs; s="$_GS"
      # A NEWLINE IS A COMMAND SEPARATOR and has to become one, or a multi-line Bash call is misread: measured,
      # `git commit -m c` followed by a line `echo done` refused the commit, because `done` was read as a
      # pathspec. Splitting alone cannot save it — the default IFS eats newlines, so the boundary is gone by the
      # time the walk sees tokens.
      _gsub "$s" $'\n' ';'; s="$_GS"
      # SEPARATORS BECOME THEIR OWN TOKENS. Without this, `git commit -m c; echo done` refused the commit: the
      # token was `c;`, `-m` swallowed it whole, the separator inside it was never seen, and `echo` read as a
      # pathspec. The fail-open twin is worse and was measured too — in
      # `if true; then git commit -m c -- a.txt; fi` the pathspec token was `a.txt;`, which the `--` lookahead
      # dismissed as a separator, so the commit was ALLOWED. Padding fixes both at once, and `&&`/`||` simply
      # become two tokens, which the walk already treats as one boundary.
      _gsub "$s" ';' ' ; '; _gsub "$_GS" '&' ' & '; _gsub "$_GS" '|' ' | '; s="$_GS"
      # Splitting has to happen with globbing OFF, or a pathspec like `*.ts` would expand against the cwd and a
      # commit could be judged on whatever files happen to sit there.
      local unglob=0
      case "$-" in *f*) ;; *) unglob=1; set -f ;; esac
      set -- $s
      [ "$unglob" = 1 ] && set +f
      local tok seen=0 incommit=0
      while [ $# -gt 0 ]; do
        tok="$1"; shift
        if [ "$incommit" = 0 ]; then
          # Before `commit`: find git and its global options. A shell separator resets the search, so the `git`
          # in `ls -la && git commit` is found and the one in `echo git commit -a > notes` is not credited twice.
          case "$tok" in
            *[\;\&\|]*) seen=0 ;;
            git|git.exe|*/git|*/git.exe) seen=1 ;;
            commit) [ "$seen" = 1 ] && incommit=1 ;;
            -C|--git-dir|--work-tree) [ "$seen" = 1 ] && _C46_REDIR=1; shift ;;
            --git-dir=*|--work-tree=*) [ "$seen" = 1 ] && _C46_REDIR=1 ;;
            -c|--namespace|--config-env|--super-prefix|--exec-path) [ "$seen" = 1 ] && shift ;;
            -*) ;;
            *) seen=0 ;;
          esac
          continue
        fi
        # Inside this commit's own arguments. The long forms are globbed where git itself accepts an unambiguous
        # abbreviation (`--incl`, `--onl`), and `--intera*` rather than `--inter*` so the value-taking
        # `--inter-hunk-context` is not mistaken for `--interactive`.
        case "$tok" in
          *[\;\&\|]*) break ;;
          # A REDIRECTION is found by the character rather than the spelling, so `> log`, `>log`, `>>log`,
          # `2> err` and a heredoc's `<<EOF` are all covered. Measured false positives before this existed:
          # `> log.txt` and `2> err` left `log.txt` / `2` looking like pathspecs, and `git commit -F - <<EOF`
          # read the delimiter word as one. All of it fires only INSIDE the commit's own arguments — a
          # redirection belonging to an earlier command, as in `echo x > f && git commit -m c -- a.txt`, is
          # ignored and that pathspec is still refused.
          #
          # A HEREDOC ends the arguments: what follows is input and a delimiter word, not paths.
          *'<<'*) break ;;
          # Any other redirection is SKIPPED OVER, not treated as the end. Breaking here was the first version
          # and a Windows session measured what it cost: `git commit -m c > log.txt -- a.txt` returned rc=0 AND
          # the commit carried the unreviewed line, because the scan stopped before reaching the pathspec. The
          # boundary was documented as "nobody writes that", which is a guess about likelihood, while the leak
          # is a fact — so it is closed instead. The target is consumed only when the token ENDS in the operator
          # (`> log`, separate); an attached one (`>log`, `2>&1`) carries its own. And a separator is never
          # consumed as a target, which is what keeps `2>&1 | tee log` from reading `1` as a pathspec.
          *[\<\>]*)
            case "$tok" in
              *[\<\>]) case "${1:-}" in ''|*[\;\&\|]*) ;; *) shift ;; esac ;;
            esac ;;
          # A BARE `--` is not a pathspec: `git commit -m msg --` was measured committing cleanly, from the index.
          # Only a token after it is one, and a shell separator there is the next command, not a path.
          --) if [ $# -gt 0 ]; then
                case "$1" in *[\;\&\|]*) ;; *) _C46_WT="a pathspec after --" ;; esac
              fi
              break ;;
          --al|--all) _C46_WT="--all" ;;
          --on|--onl|--only) _C46_WT="--only" ;;
          --inc*) _C46_WT="--include" ;;
          --intera*) _C46_WT="--interactive" ;;
          --pat*) _C46_WT="--patch / --pathspec-from-file" ;;
          # Flags whose value is MANDATORY and may be a separate token, so the token after them is not a path.
          # `-S`/`--gpg-sign` and `-u`/`--untracked-files` are deliberately NOT here: their value is OPTIONAL and
          # has to be attached (`-Skeyid`, `-uall`), so they swallow nothing — listing them made `git commit -S -m x`
          # read `x` as a pathspec and refuse an ordinary signed commit.
          -m|-F|-t|-U|-c|-C|--message|--file|--template|--unified|--author|--date|--cleanup|--trailer|--fixup|--squash|--reedit-message|--reuse-message|--inter-hunk-context)
            # Only swallow a token that can BE a value. A separator there means the flag was left without one
            # (`git commit -m ; echo x`), and eating it would hide the boundary and read `echo` as a pathspec.
            case "${1:-}" in ''|*[\;\&\|]*) ;; *) shift ;; esac ;;
          --*) ;;
          # Any other short token is a CLUSTER, and every letter in it is its own flag — `-qam` is `-q -a -m`.
          # This is why the test is a character class and not an equality check against `-a`.
          #
          # And if the cluster ENDS in a value-taking letter, the token after it is that VALUE, not a path:
          # `-qm x` is `-q -m x`, an ordinary commit. Without this, `git commit -qm x` was refused while
          # `git commit -qm "x"` was allowed — the quote strip hid the bug in the quoted form, which is how it
          # survived a full pass of the suite and a Windows run of 38 cases. The condition is exact rather than
          # "contains m": if the value were attached the cluster would not END with the letter (`-mq` is `-m q`,
          # message `q`, and the next token there really is a pathspec).
          -*) case "$tok" in *[aoip]*) _C46_WT="a short flag with a/o/i/p in it" ;; esac
              case "$tok" in *[mFtUcC]) case "${1:-}" in ''|*[\;\&\|]*) ;; *) shift ;; esac ;; esac ;;
          *) _C46_WT="a pathspec" ;;
        esac
      done
    }
    _c46_scan "$CMD"
    # ...and the same question asked of the reading above (_c47_scan, already run for this call). Either answer refuses.
    [ -z "$_C46_WT" ] && [ -n "$_C47_WT" ] && _C46_WT="$_C47_WT"
    # The record describes THIS worktree. A command that points git at another one would have us hash the wrong
    # repository and pass it off as verified, so the ambiguous form fails closed instead.
    if [ "$_C46_REDIR" = 1 ]; then
      gatelog BLOCK 4.6 "commit redirected at another worktree"
      echo "GUARD (§4.6): this commit points git at another worktree (-C / --git-dir / --work-tree)." >&2
      echo "The review record describes the staged diff of THIS worktree, so it cannot vouch for that one." >&2
      echo "Run the commit from that directory, or run it yourself in your terminal." >&2
      exit 2
    fi
    if [ -n "$_C46_WT" ]; then
      gatelog BLOCK 4.6 "commit takes content from the working tree"
      echo "GUARD (§4.6): this commit takes its content from the working tree ($_C46_WT), not from the" >&2
      echo "index — so git commits what is in your files, and the review record is about what is staged." >&2
      echo "Those are different things, and that is how unreviewed lines get in." >&2
      echo "Stage exactly what you mean with 'git add <paths>', then commit with no paths and no -a." >&2
      exit 2
    fi

    # THE COMMIT RUNS WHERE THE CALL TAKES IT. `cd ../other && git commit -m x` commits what is staged THERE, while
    # the record below is read and compared HERE (measured: the other repository got the commit). One plain target is
    # resolved and has to be this same repository — git is asked for both git directories, so no path is compared by
    # its spelling; a target that cannot be read (a variable, `cd -`, two of them, `env -C`) is refused.
    if [ "$_C47_CD" != 0 ]; then
      _cdok=0
      if [ "$_C47_CD" = 1 ]; then
        case "$_C47_CDT" in /*|[A-Za-z]:*) _cdt="$_C47_CDT" ;; *) _cdt="${_CWD:-.}/$_C47_CDT" ;; esac
        _g1="$(git -C "${_CWD:-.}" rev-parse --absolute-git-dir 2>/dev/null)"
        _g2="$(git -C "$_cdt" rev-parse --absolute-git-dir 2>/dev/null)"
        [ -n "$_g1" ] && [ "$_g1" = "$_g2" ] && _cdok=1
      fi
      if [ "$_cdok" != 1 ]; then
        gatelog BLOCK 4.6 "commit after a change of directory"
        echo "GUARD (§4.6): this call changes directory before it commits, and the commit would not run in the repository" >&2
        echo "this session is in — or the target cannot be read (a variable, 'cd -', more than one). The review record" >&2
        echo "describes what is staged HERE. Run the commit from this directory, or run it yourself in your terminal." >&2
        exit 2
      fi
    fi

    # CREW-REVIEW-PASS (this recipe is kept identical in agents/crew-review-agent.md; smoke-test pins the pair)
    # GIT does the hashing, not sha256sum/shasum, and the reason is the one that survives BOTH platforms —
    # because the first two reasons written here did not. Measured on macOS: the suite's sandbox reaches its
    # minimal tier (a PATH of awk/sed/grep/head/cat/tr/git/cut built from symlinks), no hasher exists there, and
    # the first version of this gate computed an EMPTY hash and blocked every commit — failing for a missing tool
    # instead of a missing review. Measured on Windows: that tier cannot be built at all (`ln -s` yields no real
    # symlink on that filesystem), the helper falls back to stubbing jq/python3 over the full PATH, and
    # /usr/bin/sha256sum is right there — so this branch is never exercised on Windows and "the hashers are
    # missing" was never a portable reason for anything. The portable reason: git cannot be absent where a commit
    # is being gated, since it is the thing under gate. Plus one process instead of a probe and a hasher, and no
    # repo required. SHA-1 is fine here: this detects a changed diff, it is not a boundary against a forger —
    # anyone who can write the record can write any value into it.
    # RESOLVE AGAINST THE PAYLOAD'S cwd, not this process's. This file already learned that lesson for the
    # `.env` rule above, and §4.6 shipped without it: measured on Windows, a process cwd of `/c` with a per-
    # fectly valid record sitting in the project produced rc=2 and the message "nothing has reviewed this
    # diff" — fail-closed, but on a false premise, which sends the user to re-run the reviewer forever. The
    # git queries move too, not just the path: a staged diff read in the wrong worktree is the same defect
    # wearing different clothes. `_CWD` is "" when the payload carried none, and `-C .` is then a no-op.
    _RPD="${_CWD:-.}"
    RP="$_RPD/.claude/review-pass.json"
    if [ ! -f "$RP" ]; then
      gatelog BLOCK 4.6 "no review-pass record"
      echo "GUARD (§4.6): nothing has reviewed this diff — '$RP' does not exist." >&2
      echo "Run @agent-crew-review-agent on the staged diff; a clean verdict writes the record." >&2
      echo "To skip it deliberately, run the commit yourself in your terminal." >&2
      exit 2
    fi
    # Read it with SHELL BUILTINS — no `tr`, no `cat`, no subshell. This runs on every commit and a process is
    # 62-135 ms on Git Bash; measured there, each fork taken off this path was worth ~70 ms.
    # `read -r` drops the newline. `${_l%$'\r'}` drops ONE carriage return per line if the record arrived CRLF.
    # Its scope is line endings and nothing more, stated that way because the first comment here claimed it
    # would "matter to a record some other tool reformats" and that was MEASURED FALSE: a reformatter puts a
    # space after the colon, `"diff_oid": "…"`, which this reader rejects whatever the line endings are (the
    # `#*\"$1\":\"` search wants them adjacent). So a reformatted record is refused either way; the strip only
    # covers CRLF. In the flat shape the recipe writes, even that is belt-and-braces — the CR lands after the
    # final `}`, outside every value, where `%%"*` already cuts it — so no fixture can tell the strip from its
    # absence and none of them claims to.
    RPJ=""; while IFS= read -r _l || [ -n "$_l" ]; do RPJ="$RPJ${_l%$'\r'}"; done < "$RP"
    _rpf(){ _r="${RPJ#*\"$1\":\"}"; [ "$_r" = "$RPJ" ] && return 1; printf '%s' "${_r%%\"*}"; }
    WANT_D="$(_rpf diff_oid || true)"; WANT_H="$(_rpf head || true)"
    # --no-ext-diff --no-textconv: what `git diff` prints is configurable, and `git config diff.external true` made
    # every staged change print NOTHING — one id for all of them, so one review record vouched for any diff (measured,
    # 3.1.0 review). With neither configured the two flags change no byte, so a record written by the older recipe
    # still matches.
    HAVE_D="$(git -C "$_RPD" diff --cached --no-ext-diff --no-textconv 2>/dev/null | git hash-object --stdin 2>/dev/null)"
    # --verify --quiet, not a bare `git rev-parse HEAD`: on an UNBORN head the bare form prints the literal
    # string "HEAD" on stdout and still fails, so `|| echo NONE` appended to it and the value became two
    # lines ("HEAD" then "NONE") — which never matches any record. Measured on a fresh `git init`.
    HAVE_H="$(git -C "$_RPD" rev-parse --verify --quiet HEAD 2>/dev/null || echo NONE)"
    if [ -z "$WANT_D" ] || [ "$WANT_D" != "$HAVE_D" ] || [ "$WANT_H" != "$HAVE_H" ]; then
      gatelog BLOCK 4.6 "review-pass does not match this diff"
      echo "GUARD (§4.6): the review record does not describe what is staged now." >&2
      # The inputs are printed because a gate that only says "no" is a gate nobody can debug.
      echo "  reviewed diff : ${WANT_D:-<missing>}" >&2
      echo "  staged   diff : ${HAVE_D:-<none>}" >&2
      echo "  reviewed HEAD : ${WANT_H:-<missing>}" >&2
      echo "  current  HEAD : ${HAVE_H}" >&2
      echo "Re-run @agent-crew-review-agent on the diff as it stands; the record it writes is the one that" >&2
      echo "matches. To skip it deliberately, run the commit yourself in your terminal." >&2
      exit 2
    fi
    gatelog ALLOW 4.6 "review-pass matches the staged diff"
  fi
  # WHICH MODES CAN ACTUALLY ASK A PERSON. `default` and `acceptEdits` show the prompt to the human and wait.
  # `auto` and `dontAsk` do not: in `auto` the permission prompt is answered by the auto-mode classifier, and
  # `dontAsk` is by definition the mode where nothing is asked. The hook still returns "ask" there, the prompt
  # is still raised, and it is still approved — by software. Measured in a real session: 14 `ASK §4.4` lines in
  # the gate log, 14 commits and pushes through, zero human keypresses. The gate fired, logged itself, and
  # stopped nothing, while DISCIPLINE.md promised an approval "only the user can answer".
  #
  # Those two therefore belong in the fail-closed branch, with bypassPermissions and plan. The rule Crewforth
  # has carried from the start is that a commit or a push does not happen without the user, and a mode where
  # the answer comes from a classifier is a mode where it cannot be proven that it did. A gate whose prompt is
  # answered by the thing it is gating is not a gate.
  case "$PERM_MODE" in
    default|acceptEdits)
      # A prompt provably reaches the user in these modes: ask, and let them approve in one keypress.
      SHORT="$CMD"
      [ "${#SHORT}" -gt 300 ] && { _utf8_cut "$SHORT" 300; SHORT="$_UC…"; }
      # §4.4 branch guard: committing straight onto main/master is not blocked (a fresh project legitimately
      # lives on main), but it is surfaced in the approval prompt so the user can send it to a branch instead.
      BRANCH_WARN=""
      # symbolic-ref names the branch even before its first commit, where rev-parse answers "HEAD" and the very
      # first commit onto main went by without this line. A detached HEAD reads empty: not the default branch.
      case "$(git symbolic-ref --short -q HEAD 2>/dev/null)" in
        main|master) BRANCH_WARN="⚠️  This commits DIRECTLY to the default branch. Prefer a feature branch unless you meant to.

" ;;
      esac
      ask_user "§4.4 commit/push approval gate. Claude wants to run:

$SHORT

${BRANCH_WARN}Approve only if the commit message above was shown to you and you agree with it. Approving lets Claude run the command itself."
      ;;
    auto|dontAsk)
      # No prompt reaches a person here, but their own message does: see _approval_ok above.
      _approval_ok && allow_approved
      gatelog BLOCK 4.4 "commit/push with no matching approval from the user"
      echo "GUARD (§4.4): 'git commit/push' needs the user's approval, and in '$PERM_MODE' a permission prompt is answered by software, not by a person." >&2
      echo "Not allowed now: $_APW." >&2
      if ! _appr_wired; then
        # The record is written by one hook. Where it is not wired, a message from the user records nothing, and
        # telling them to type one sends them into a wall (measured in the field: a worktree on an older Crewforth).
        echo "THE APPROVAL PATH IS CLOSED IN THIS SESSION: the hook that records the user's approval (prompt-approval.sh) is not wired on UserPromptSubmit in the settings in effect ($_APRW). A '/crew-approve' message records nothing here." >&2
        echo "Tell the user exactly that, in their language, and give them the two ways that work: Shift+Tab to default/acceptEdits (this gate then asks them directly), or the command in their own terminal." >&2
        echo "Do not create an approval any other way." >&2
        exit 2
      fi
      _aps=push; git_has "$CMD_SEEN" 'commit' && _aps=commit
      echo "ASK THE USER NOW, in their language, in this shape and with nothing after it (stage first: the approval covers what is staged at that moment):" >&2
      echo "  1. the commit message, whole, in ONE code block;" >&2
      echo "  2. under it ONE line, the sentence in their language and the command as it is (only the user can type it):  If you approve, send only this: /crew-approve $_aps" >&2
      echo "     Name the one the user can type for this call: /crew-approve commit, /crew-approve push, or /crew-approve commit+push when a push follows the commit." >&2
      echo "Their message has to be that command alone, typed by them: a sentence such as 'go ahead and commit' is not an approval, and you cannot run the command for them. It is tied to the staged tree and HEAD, lasts 30 minutes and ends at their next message." >&2
      echo "Then run the command ALONE in its call (no cd, no pipe, nothing chained): git commit -m '…', or git push <remote> <branch>." >&2
      echo "The other ways: Shift+Tab to default/acceptEdits (this gate then asks them directly), or the command in their own terminal." >&2
      echo "Only the user can write that message. Do not write it for them, and do not create an approval any other way." >&2
      exit 2 ;;
    *)
      # bypassPermissions, plan, or an unrecognised/absent mode: we cannot prove the prompt would reach a
      # human, so we fail closed rather than let the gate silently evaporate.
      gatelog BLOCK 4.4 "commit/push under a mode that cannot prompt (${PERM_MODE:-unknown})"
      echo "GUARD (§4.4): 'git commit/push' is gated by approval AT THE TOOL LEVEL, and this session's permission mode ('${PERM_MODE:-unknown}') cannot put that prompt in front of a person." >&2
      echo "Present the commit MESSAGE to the user and get EXPLICIT approval. Then one of:" >&2
      echo "  (a) the user presses Shift+Tab to switch to default/acceptEdits — IN THIS SESSION, no restart — and this gate asks them directly, OR" >&2
      echo "  (b) the NEXT session is started with 'CLAUDE_GIT_OK=1' (headless/CI) — the key cannot be added to a session already running. It covers the §4.4 APPROVAL set (commit · push; staging and branching need no key) and nothing else;" >&2
      echo "      force-push, git add -f, hook tampering and the §4.5 destructive set all still block, OR" >&2
      echo "  (c) the user runs the command in their own terminal." >&2
      exit 2 ;;
  esac
fi

# §4.4 — STAGING AND BRANCHING ARE FREE, IN EVERY MODE. Commit and push are the approval set; `git add` and
# creating a branch are not, by the user's decision: neither publishes anything, both are undone locally, and
# asking for them made auto mode stop and demand a mode switch for work that cannot hurt anyone. So this hook
# returns NO decision for them in any mode, and Crewforth's settings.json already allows Bash — they simply run.
#
# What stays gated around them, unchanged: `git add -f` is §4.5 (it bypasses a .gitignore rule) and blocks above;
# forced branch operations (-D/-f/-M/-C) block above; commit and push fail closed where nobody can be asked and
# ask where someone can. CLAUDE_GIT_OK still returns an explicit allow for add and branch creation (the block
# before §4.6), which a headless session needs when its own settings do not allow Bash.
#
# Branch creation used to be matched here in every spelling git accepts (checkout -b/-B/--orphan, switch
# -c/-C/--create/--force-create/--orphan, with global options in front) so that default mode could ask. That
# matcher is gone with the question; smoke §4e now pins the opposite — every spelling runs without a prompt.
exit 0
}
_gate_main "$@"
_crew_stop "a command of the gate was abandoned"
