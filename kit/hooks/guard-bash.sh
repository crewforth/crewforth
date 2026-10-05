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
#     turns GIT into gıt. The suite, run whole under that locale, went from 2 failures to 23: a recursive
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
INPUT="$(cat)"

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
  # `${hay%%"$k"*}` finds the FIRST occurrence -- the longest suffix that starts with the key starts at the
  # earliest one. THAT ALONE IS NOT ENOUGH, and the sentence that used to stand here said it was: it claimed a
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
  # a PreToolUse hook is a gate with an off switch, because a hook killed at its 60s timeout emits no exit 2.
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
  # both far inside the 60s timeout, while a 46 KB legitimate command is 325 ms on macOS -- a figure that
  # predates this change and belongs to the walk, not to the cap.
  local _cap=64 _seen=0
  while :; do
    pre="${hay%%"$k"*}"                        # everything before the next `"key"`
    [ "$pre" != "$hay" ] || return 0           # no further occurrence: emit nothing
    _seen=$((_seen+1)); [ "$_seen" -le "$_cap" ] || return 0
    rest="${hay:${#pre}+${#k}}"                # past `"key"`
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
  # That was not a comfort question. This hook's timeout is 60s -- set in settings.json, NOT Claude Code's
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
  case "$s" in *\\*) ;; *) printf '%s' "$s"; return 0 ;; esac   # no escapes: the common case pays nothing
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
           *)                  acc+=("?") ;;
         esac ;;
      *) acc+=("$c") ;;
    esac
  done
  local IFS=''; printf '%s' "${acc[*]}"
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
  local LC_ALL=C hay="$1" k="\"$2\"" pre rest c=0 _cap=64 _seen=0
  _KC=0; _KC_CAPPED=0
  while :; do
    pre="${hay%%"$k"*}"
    [ "$pre" != "$hay" ] || { _KC=$c; return 0; }
    # OVER-CAP IS ITS OWN ANSWER, not a large count. `_KC_CAPPED` lets the caller say what actually happened:
    # the occurrences it stopped at are candidate positions, key-form or not, so calling them "65 keys" was a
    # sentinel dressed up as a measurement and the remedy it offered ("send one key") was already satisfied.
    _seen=$((_seen+1)); [ "$_seen" -le "$_cap" ] || { _KC=$((_cap+1)); _KC_CAPPED=$_cap; return 0; }
    rest="${hay:${#pre}+${#k}}"
    while [ -n "$rest" ] && [[ "${rest:0:1}" == [$' \t\n\r'] ]]; do rest="${rest:1}"; done
    case "$rest" in :*) c=$((c+1)) ;; esac
    hay="$rest"
  done
}
# ---- /CREW-JSON-PARSE -----------------------------------------------------------------------------------
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
CMD="$(_json_unescape "$(_json_slice "$INPUT" command)")"
_join_cmd                                # continued lines joined, as the shell runs them (CREW-JOIN)
PERM_MODE="$(_json_slice "$INPUT" permission_mode)"

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

{ git_has "$CMD" 'reset'  && has '--hard'; }                                                && block "git reset --hard" "4.5" history
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
if [ "$HAS_GIT" = 1 ] && git_has "$CMD" 'push'; then
  _grep_out "$CMD" -oE 'git[[:space:]]+([^;&|]*[[:space:]])?push([^;&|]*)'; _PUSHSEG="$_GO"
  while IFS= read -r _seg; do
    [ -n "$_seg" ] || continue
    _push_forces "$_seg" && { block "git push --force" "4.5" history; break; }
  done <<< "$_PUSHSEG"
fi
{ git_has "$CMD" 'clean'  && has '-[A-Za-z]*f'; }                                           && block "git clean -f" "4.5" loss
case "$CMD" in *[Nn][Oo]-[Vv][Ee][Rr][Ii][Ff][Yy]*) : ;; *) false ;; esac                                          && block "hook skip (--no-verify)" "4.5" tamper
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
PS_RECURSE='-r(e(c(u(r(s(e)?)?)?)?)?)?([[:space:]]|$)'
PS_FORCE='-f(o(r(c(e)?)?)?)?([[:space:]]|$)'
# Recursive+forced removal aimed at a glob, a drive root, a UNC path, or $HOME — the shapes that take a tree out.
{ case "$CMD" in *-[Rr]*) : ;; *) false ;; esac && has "(^|[^A-Za-z0-9_-])$PS_RM[[:space:]]" && has "$PS_RECURSE" && has "$PS_FORCE" \
  && has '(\*|[A-Za-z]:\\|\\\\|\$HOME|\$env:USERPROFILE|~)'; } \
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
  case "$c" in *"$bsnl"*) c="${c//"$bsnl"/ }" ;; esac   # quoted: in a ${//} pattern a bare backslash escapes the newline
  t=${c//\"/}; t=${t//\'/}; t=${t//\\/}   # unquoted, one class each: inside "…" a [\"\'\\] class never closes
  case "$t" in *[Hh][Oo][Oo][Kk][Ss][Pp][Aa][Tt][Hh]*|*[Ss][Ee][Cc][Tt][Ii][Oo][Nn]*) ;; *) return 1 ;; esac   # after unquoting: hooks"P"ath
  shopt -q nocasematch && nc=1; shopt -s nocasematch
  # The payload reader decodes JSON escapes lossily — `\r` arrives as nothing, so `git config core.hooksPath <CR>`
  # would look value-less here while git sets the path to a CR byte (verified in review). With any such escape in
  # the raw payload the decoded text is not the command that will run, and no read is proven.
  case "$INPUT" in *'\r'*|*'\f'*|*'\b'*|*'\v'*|*'\u'*) ;; *)
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
  t=${c//\"/}; t=${t//\'/}; t=${t//\\/}   # unquoted, one class each: inside "…" a [\"\'\\] class never closes
  _ere i "$t" 'git([^|]*[^[:alnum:]_|])?config[^[:alnum:]_|][^|]*core\.hooksPath' '*[Hh][Oo][Oo][Kk][Ss][Pp][Aa][Tt][Hh]*' && return 0
  _ere i "$t" 'config[^;&|]*[[:space:]](--remove-section|--rename-section|remove-section|rename-section)[[:space:]]+(--[[:space:]]+)?core([^A-Za-z0-9_.-]|$)' '*[Ss][Ee][Cc][Tt][Ii][Oo][Nn]*' && return 0
  return 1
}
# Inline config override: `git -c core.hooksPath=…` / `git --config-env core.hooksPath=…` turns the hooks off for
# that one command WITHOUT the word `config` (so the rule above misses it) — the exact equivalent of --no-verify.
[ "$HAS_GIT" = 1 ] && _ere i "$CMD" 'git[[:space:]]+([^;&|]*[[:space:]])?(-c|--config-env)[[:space:]=]+core\.hooksPath' '*[Hh][Oo][Oo][Kk][Ss][Pp][Aa][Tt][Hh]*' && block "git -c core.hooksPath (disarms the git hooks)" "4.5" tamper
[ "$HAS_GIT" = 1 ] && _hp_blocks "$CMD" && block "git config core.hooksPath (disarms the git hooks)" "4.5" tamper
# A write to a gate path (hook script, settings.json, or .git/hooks) via ANY common mechanism — writer verbs, the
# in-place editors, and the interpreters an evasion reaches for (perl/python/ruby/node/ed) — plus the variable-
# indirected redirect (VAR=.claude/hooks; … > $VAR). Reading a gate file stays allowed, and `chmod +x` is NOT
# blocked so doctor's re-arm fix still works (a chmod -x disable is caught by doctor, not here). Honest scope:
# the shell is Turing-complete, so this is defence-in-depth — guard-write.sh covers the Write/Edit tools (the
# model's natural path to a file), and install-time read-only hook files would be the airtight layer.
# Either separator: a PowerShell call spells these `.claude\hooks\…`, and it was not recognised (measured, rc 0).
GATE='\.(claude[/\\]+(hooks|settings\.json|DISCIPLINE\.md|eval[/\\]+lib[/\\]+crew-env\.sh)|git[/\\]+hooks)'
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
# CREW-NOT-A-RUNG: same — `perl`, `python3`, `ruby`, `node` here are names the gate REFUSES when they are
# pointed at a gate file, not readers this hook uses.
case "$CMD" in *[Cc][Ll][Aa][Uu][Dd][Ee]*|*[Hh][Oo][Oo][Kk][Ss]*) : ;; *) false ;; esac && _grep "$CMD" -qiE "(^|[^A-Za-z0-9_-])(rm|mv|cp|truncate|tee|install|ln|perl|python[0-9.]*|ruby|node|ex|ed|set-content|add-content|clear-content|out-file|new-item|rename-item|copy-item|move-item|remove-item)\b[^;&|]*$GATE" && block "write/tamper of a gate file (hook/settings/.git-hooks)" "4.5" tamper
case "$CMD" in *[Cc][Ll][Aa][Uu][Dd][Ee]*|*[Hh][Oo][Oo][Kk][Ss]*) : ;; *) false ;; esac && _grep "$CMD" -qiE "(sed|perl|awk|ruby)[[:space:]]+(-[^[:space:]]+[[:space:]]+)*-i[^;&|]*$GATE"          && block "in-place edit of a gate file" "4.5" tamper
# /CREW-NOT-A-RUNG
# The redirect TARGET must be the gate path, not merely something later on the line: a target is one token, so
# it cannot contain whitespace or a command separator.
case "$CMD" in *[Cc][Ll][Aa][Uu][Dd][Ee]*|*[Hh][Oo][Oo][Kk][Ss]*) : ;; *) false ;; esac && _grep "$CMD" -qiE ">[[:space:]]*['\"]?[^[:space:];&|<>]*$GATE"                                          && block "redirect over a gate file" "4.5" tamper
{ case "$CMD" in *[Cc][Ll][Aa][Uu][Dd][Ee]*|*[Hh][Oo][Oo][Kk][Ss]*) : ;; *) false ;; esac && has "=[^;&|]*$GATE" && has '>>?[[:space:]]*\$'; }                                                          && block "indirected write to a gate path (variable + redirect)" "4.5" tamper
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
if git_has "$CMD" 'add|commit|push|checkout|switch'; then
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
if git_has "$CMD" 'commit|push'; then
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
  if git_has "$CMD" 'commit'; then
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
      s="${s//[\\]r/}"
      s="${s//$'\r'/}"
      s="${s//[\\]n/$'\n'}"
      s="${s//[\\]\'/Q}"
      s="${s//[\\]\"/Q}"
      # A quoted span collapses to the single placeholder `Q`, and this is the whole design: the CONTENT of a
      # quote must not be read as an option or a path, but the TOKEN has to survive. The first version DELETED
      # the span, and that was a measured fail-open on Windows — `git commit -m c "a.txt"` and
      # `git commit -m c -- "a.txt"` lost the pathspec entirely and were allowed, while their unquoted spellings
      # were refused, and both commit the same unreviewed line. No trick is needed to get past a gate like that,
      # only the ordinary habit of quoting a path, which is mandatory once it contains a space. The placeholder
      # keeps adjacency too, so `-m"msg"` becomes `-mQ` (an attached value, correct) and not `-m Q`.
      # Double quotes go FIRST: an apostrophe inside a double-quoted message (`-m "don't"`) is ordinary, whereas
      # a double quote inside a single-quoted one is rare, so this order mangles the rarer shape.
      while :; do
        case "$s" in *\"*\"*) ;; *) break ;; esac
        pre="${s%%\"*}"; rest="${s#*\"}"; rest="${rest#*\"}"; s="${pre}Q${rest}"
      done
      while :; do
        case "$s" in *\'*\'*) ;; *) break ;; esac
        pre="${s%%\'*}"; rest="${s#*\'}"; rest="${rest#*\'}"; s="${pre}Q${rest}"
      done
      # A backslash-newline is a LINE CONTINUATION, the opposite of a separator: it JOINS. Measured, before this,
      # `git commit \` + newline + `  -m c` refused the commit, because the lone `\` became a token and read as a
      # pathspec. It has to run before the conversion below, or the newline is gone when we look for it.
      s="${s//[\\]$'\n'/ }"
      # A NEWLINE IS A COMMAND SEPARATOR and has to become one, or a multi-line Bash call is misread: measured,
      # `git commit -m c` followed by a line `echo done` refused the commit, because `done` was read as a
      # pathspec. Splitting alone cannot save it — the default IFS eats newlines, so the boundary is gone by the
      # time the walk sees tokens.
      s="${s//$'\n'/;}"
      # SEPARATORS BECOME THEIR OWN TOKENS. Without this, `git commit -m c; echo done` refused the commit: the
      # token was `c;`, `-m` swallowed it whole, the separator inside it was never seen, and `echo` read as a
      # pathspec. The fail-open twin is worse and was measured too — in
      # `if true; then git commit -m c -- a.txt; fi` the pathspec token was `a.txt;`, which the `--` lookahead
      # dismissed as a separator, so the commit was ALLOWED. Padding fixes both at once, and `&&`/`||` simply
      # become two tokens, which the walk already treats as one boundary.
      s="${s//;/ ; }"
      s="${s//&/ & }"
      s="${s//|/ | }"
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
    HAVE_D="$(git -C "$_RPD" diff --cached 2>/dev/null | git hash-object --stdin 2>/dev/null)"
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
