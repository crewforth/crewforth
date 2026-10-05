#!/usr/bin/env bash
# The commit content gate, for installs that have no git hooks to put it in.
#
# §4.1/§4.2 (no AI trace, no vendor name) and the secret scan are enforced by `pre-commit` and `commit-msg`,
# which git runs via `core.hooksPath`. The PLUGIN edition cannot set that — a plugin ships Claude Code hooks,
# not git hooks — so a plugin-only install had the approval gate but none of the CONTENT gates: the model could
# commit a credential or an authorship trailer and nothing would look at it. Three distribution channels, one of
# them quietly weaker than the other two.
#
# This closes that by running the REAL scanners from PreToolUse, before the commit command executes. It does
# not re-implement them. A second matcher is how a gate passes while the thing it guards is broken — the same
# reasoning that made the blocklists carry their own test cases and made the eval graders reuse this very
# pattern file.
#
# In a FULL install this is harmless duplication: the git hooks still fire afterwards and catch the same
# content. Belt and braces on the strictest rules in Crewforth is a fair trade for the plugin edition no longer
# being the weak channel.
#
# Deliberately NOT covered: `--no-verify`. It is §4.5 and `guard-bash.sh` blocks it outright, so it never
# reaches this hook.
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
DIR="$(cd "$(dirname "$0")" && pwd)"

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

# Extract the -m/--message VALUES from the command line without an interpreter.
#
# Without this tier the fallback below hands the WHOLE command line to the message scanner, and a file path is
# not a message: `git commit -m "feat: add scaffolding" -- src/AI-generated/scaffold.ts` was refused with
# "TRACE-SCANNER (message): 'AI-generated'" while the message itself is clean. The same commit is ACCEPTED
# by a python3 shlex tier — which this file used to prefer where python ran — so the verdict depended on the
# machine, not on the commit. That tier is gone: this tokenizer is now the only one, on every machine.
#
# It is awk, not parameter expansion, and that is deliberate on a hook that already spawns ~49 processes for a
# commit: a pure-shell character walk was written first and MEASURED QUADRATIC — 146 B 0.006s,
# 4 KB 0.181s, 16 KB 1.03s, 64 KB 8.08s. That does NOT blow the 60 s timeout Crewforth sets, and the
# largest command payload seen across 6791 real Bash calls was 46.8 KB — so this is a tail-risk
# trade, not a rescue: awk is 0.049s flat to 64 KB and 0.585s at 1 MB, so the cost stops depending
# on what someone pasted into a commit message. One fork, on a path that already spawns ~49 and runs only
# for a `git commit`; the zero-fork rule still governs the per-Bash-call path.
# Byte-oriented under LC_ALL=C, which is safe because a UTF-8 continuation byte is always >= 0x80
# and can never equal an ASCII quote.
#
# Contract: rc=0 with the values, or rc=1 when the line cannot be parsed with confidence (unterminated quote,
# trailing backslash, an -m with nothing after it). rc=1 keeps the over-inclusive fallback, so this can only
# remove false positives — it can never open a blind spot. Verified against a POSIX shlex oracle written
# independently in another language: 37 command shapes, 33 byte-identical, 4 safe fallbacks, 0 mismatches,
# with the harness itself calibrated by two deliberate mutations.
# The one tokenizer: shell quoting rules (the subset shlex.split applies), then every value of the named option.
# $1 = command, $2 = short flag, $3 = long flag, $4 = 1 to stop at the first value.
crew_opt_values() {
  CREW_CMD="$1" CREW_S="$2" CREW_L="$3" CREW_FIRST="${4:-0}" LC_ALL=C awk '
    BEGIN {
      s = ENVIRON["CREW_CMD"]; n = length(s); i = 1
      ntok = 0; cur = ""; have = 0
      while (i <= n) {
        c = substr(s, i, 1)
        if (c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\f" || c == "\v") {
          if (have) { ntok++; tok[ntok] = cur; cur = ""; have = 0 }
          i++; continue
        }
        if (c == "\\") {                                  # outside quotes: escapes the next byte
          i++
          if (i > n) exit 1                               # trailing backslash
          cur = cur substr(s, i, 1); have = 1; i++; continue
        }
        if (c == "'"'"'") {                               # single quotes: literal to the next quote
          i++; have = 1
          while (1) {
            if (i > n) exit 1                             # no closing quote
            c = substr(s, i, 1)
            if (c == "'"'"'") { i++; break }
            cur = cur c; i++
          }
          continue
        }
        if (c == "\"") {                                  # double quotes: backslash escapes " and \
          i++; have = 1
          while (1) {
            if (i > n) exit 1                             # no closing quote
            c = substr(s, i, 1)
            if (c == "\"") { i++; break }
            if (c == "\\" && i < n) {
              nx = substr(s, i + 1, 1)
              if (nx == "\"" || nx == "\\") { cur = cur nx; i += 2; continue }
            }
            cur = cur c; i++
          }
          continue
        }
        cur = cur c; have = 1; i++
      }
      if (have) { ntok++; tok[ntok] = cur }

      S = ENVIRON["CREW_S"]; L = ENVIRON["CREW_L"]; first = ENVIRON["CREW_FIRST"] == "1"; LE = L "="
      out = ""; nout = 0
      for (k = 1; k <= ntok; k++) {
        t = tok[k]
        if (t == S || t == L) {
          k++
          if (k > ntok) exit 1                            # -m with nothing after it: do not guess
          nout++; res[nout] = tok[k]
        } else if (substr(t, 1, length(LE)) == LE) {
          nout++; res[nout] = substr(t, length(LE) + 1)
        }
        if (first && nout) break
      }
      for (k = 1; k <= nout; k++) printf "%s\n", res[k]
      exit 0
    }'
}
crew_msg_values() { crew_opt_values "$1" -m --message; }

INPUT="$(cat)"
# Same ladder as guard-bash.sh, and for the same reason: the raw-text fallback leaves JSON escapes in place,
# so `-m \"…\"` never matches a quote-based extraction and the message silently goes unscanned. That is
# precisely how the first version of this hook passed a commit carrying a co-author trailer.
# And the same rule as guard-bash.sh about WHICH rung is taken: a tier is chosen on whether it works, not on
# whether it exists. Windows ships a Store redirector stub named python3 on PATH by default; `command -v` finds
# it, it exits 49 with an empty stdout, and this hook then read CMD="" and exited 0 — the commit content scan
# never ran. Measured on a stock Windows 11 desktop. The extraction's own exit status is the probe.
# AN AMBIGUOUS COMMAND IS REFUSED HERE TOO, rather than leaning on guard-bash.sh doing it. That argument —
# "the other hook on the same matcher already refuses this" — was made in this very file and was wrong twice
# in one review round: for the value-form shadow BOTH hooks allowed, so §4.1/§4.2 and the secret scan never
# ran on a commit that carried a trailer. A content scanner that silently does not run is the exact failure
# `pre-commit` exists to prevent, and this hook is the plugin edition's only copy of it.
# `_KC`, not `$( )`: this hook runs before every Bash call and a command substitution is a fork. It is also
# deliberately BEFORE the `case "$CMD" in *git*` fast bail below, even though that means non-git commands pay
# for the count: an ambiguous payload's FIRST value can be `ls` while a `git commit` sits in the second key,
# and bailing on the first value is exactly how a content scan silently does not run. Fork-free, the count is
# expansion only, so paying it on every call is measured in microseconds rather than in processes.
_json_keycount "$INPUT" command; _n_cmd=$_KC
if [ "$_KC_CAPPED" != 0 ]; then
  echo "GUARD: this payload contains more than $_KC_CAPPED occurrences of \"command\", so the scan for the" >&2
  echo "real key was stopped. Refusing rather than scanning whichever one it had reached." >&2
  exit 2
elif [ "$_n_cmd" -gt 1 ]; then
  echo "GUARD: this payload carries $_n_cmd \"command\" keys, so the commit content to scan is ambiguous." >&2
  echo "Refusing rather than scanning whichever comes first." >&2
  exit 2
fi
# ONE READER, EVERYWHERE — the ladder is gone here too; the reasoning lives in guard-bash.sh next to the same
# change. Two things specific to THIS hook are worth keeping:
#   * The value must be UNESCAPED, not raw. A raw-text extraction leaves JSON escapes in place, so `-m \"…\"`
#     never matches a quote-based scan and the message silently goes unscanned. That is precisely how the
#     first version of this hook passed a commit carrying a co-author trailer.
#   * The Windows stub. `command -v python3` found the Microsoft Store redirector, it exited 49 with an empty
#     stdout, this hook read CMD="" and exited 0, and the commit content scan never ran at all.
# The shared reader also replaced a `sed | head | sed` pipeline: four processes on EVERY Bash tool call, to
# re-derive a string guard-bash.sh had already parsed one hook earlier. Measured on `ls -la`: guard-bash.sh 2
# processes, this hook 7. With the ladder gone neither hook spawns a process to SELECT a reader.
CMD="$(_json_unescape "$(_json_slice "$INPUT" command)")"
_join_cmd                                # continued lines joined, as the shell runs them (CREW-JOIN)
[ -z "$CMD" ] && exit 0

# A command that does not contain `git` at all cannot match the pattern below, and finding that out
# should not cost a process. Measured on `ls -la`: this hook spawned 7 processes to answer "no".
# The test is case-INSENSITIVE while the pattern is not, so it is a superset: it can only let more
# through to the real matcher, never less.
case "$CMD" in *[Gg][Ii][Tt]*) ;; *) exit 0 ;; esac

# Only git commit. Matching mirrors guard-bash.sh's tolerance for `git -C dir commit`, TAB separators and a
# quoted binary, because a gate that a whitespace change walks past is not a gate.
_grep "$CMD" -qE '(^|[;&|[:space:]])["'"'"'`]?git["'"'"'`]?([[:space:]]+-[^[:space:]]+)*[[:space:]]+commit([[:space:]]|$)' || exit 0

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# `git commit -a` has not staged anything yet at this point; tell the scanner to look at tracked-but-unstaged
# changes too. Matches -a, --all and clusters like -am.
UNSTAGED=0
_grep "$CMD" -qE '(^|[[:space:]])(--all|-[A-Za-z]*a[A-Za-z]*)([[:space:]]|$)' && UNSTAGED=1

FAILED=0
OUT=""
if [ -x "$DIR/pre-commit" ]; then
  OUT="$(CREW_SCAN_UNSTAGED="$UNSTAGED" bash "$DIR/pre-commit" 2>&1)" || FAILED=1
fi

# The message carries its own trace risk (a co-author trailer lives there, not in the diff), and commit-msg is
# what scans it. Reuse it on the -m value when there is one; an editor-composed message is not visible here and
# stays the git hook's job.
if [ "$FAILED" = 0 ] && [ -x "$DIR/commit-msg" ]; then
  # The message is tokenized the way a shell does (crew_opt_values), which matters because a real commit message
  # is MULTI-LINE: a line-oriented `sed` extraction found the subject and stopped, so a co-author trailer on line
  # 3 — the single most likely §4.1 violation, and the one the bare arm of the eval actually produced — went
  # unscanned. When the tokenizer cannot parse the command, scan the whole command text instead of guessing
  # where the message ends: over-inclusive beats a gate with a blind spot.
  #
  # But WHICH branch we are in cannot be decided from MSG's emptiness either, and that is the subtler half.
  # "there is no -m" and "there is an -m but nothing here can extract it" are different facts with opposite
  # correct answers: the first must fall through to the fail-closed editor/-F path below, the second must
  # scan. Reading both off one empty string is what let a first attempt at this fix skip the fail-closed path
  # on exactly the Windows machines it was written for. So ask the question directly, with a test that needs
  # no interpreter. Cheap: nothing below runs unless the command is already known to be a `git commit`.
  HAS_M=0
  _grep "$CMD" -qE '(^|[[:space:]])(-[A-Za-z]*m|--message)([[:space:]]|=|$)' && HAS_M=1
  # ONE tokenizer, awk, on every machine. A python3 `shlex` branch used to run first where python worked, so a
  # Mac and a Windows box took different code through a gate. Measured before it was removed: on 18 `-m`
  # shapes the awk tokenizer returned what shlex returned, 18/18. A command awk cannot tokenize (an unclosed
  # quote, a -m with nothing after it) scans the whole command instead, which can only over-report.
  if ! MSG="$(crew_msg_values "$CMD")"; then
    MSG="$CMD"
  fi
  if [ "$HAS_M" = 1 ] && [ -n "$MSG" ]; then
    MF="$(mktemp "${TMPDIR:-/tmp}/crew-msg.XXXXXX")"
    printf '%s\n' "$MSG" > "$MF"
    OUT="$OUT
$(bash "$DIR/commit-msg" "$MF" 2>&1)" || FAILED=1
    rm -f "$MF"
  else
    # No -m: either the message comes from a file (-F/--file, which we CAN read) or from an editor, which does
    # not exist yet at this point. In a full install the commit-msg git hook reads it afterwards and the gap
    # closes itself. In a plugin-only install nothing does — and a co-authorship trailer lives in the message,
    # not the diff, so that is precisely where §4.1 would be lost. Fail closed rather than wave it through:
    # a gate that silently skips the case it was built for is worse than no gate, because it reads as covered.
    # The same tokenizer finds -F/--file. The sed extraction it replaced stopped at the first space, so on the
    # machines with no python it read `-F "my msg.txt"` as `my` — measured, 5 of 12 shapes wrong (quoted or
    # spaced paths, a repeated -F, a Windows backslash path) — and the branch below then refused a CLEAN
    # commit. 12/12 now equal what shlex returned.
    #
    # The LAST -F wins, because that is the file git reads: measured on git 2.54, `commit -F one -F two` commits
    # two. Taking the first (what shlex-first-match did) let `-F clean.txt -F traced.txt` scan the clean file and
    # commit the traced one — a §4.1 hole, found in review. And when the tokenizer cannot parse the line (a shape
    # it does not model, e.g. ANSI-C `$'…'` quoting later in the command), a -F is still there: fall back to the
    # greedy extraction (last match), and if even that names no readable file, refuse rather than skip.
    if MFILE="$(crew_opt_values "$CMD" -F --file)"; then
      MFILE="${MFILE##*$'\n'}"
    else
      MFILE="$(printf '%s' "$CMD" \
        | sed -n 's/.*[[:space:]]--\{0,1\}[Ff]\(ile\)\{0,1\}[[:space:]=]\{1,\}\([^[:space:];&|]\{1,\}\).*/\2/p' | head -1)"
      MFILE="${MFILE%\"}"; MFILE="${MFILE#\"}"; MFILE="${MFILE%\'}"; MFILE="${MFILE#\'}"
      if _grep "$CMD" -qE '(^|[[:space:]])(-F|--file)([[:space:]=]|$)' && { [ -z "$MFILE" ] || [ ! -f "$MFILE" ]; }; then
        echo "GUARD (§4.1): this commit reads its message from a file (-F), and the command could not be parsed" >&2
        echo "well enough to know which file. Scan cannot run, so the commit is refused. Commit with a plain" >&2
        echo "-F <path> (or -m) in a command of its own." >&2
        exit 2
      fi
    fi
    if [ -n "$MFILE" ] && [ -f "$MFILE" ]; then
      OUT="$OUT
$(bash "$DIR/commit-msg" "$MFILE" 2>&1)" || FAILED=1
    else
      HP="$(git config core.hooksPath 2>/dev/null || true)"
      GITMSG_HOOK=""
      [ -n "$HP" ] && [ -x "$HP/commit-msg" ] && GITMSG_HOOK="$HP/commit-msg"
      [ -z "$GITMSG_HOOK" ] && [ -x "$(git rev-parse --git-path hooks/commit-msg 2>/dev/null)" ] \
        && GITMSG_HOOK="git-default"
      if [ -z "$GITMSG_HOOK" ]; then
        echo "GUARD (§4.1): this commit's message would go unscanned." >&2
        echo "No -m/-F was given, so the message is composed in an editor after this point, and no commit-msg" >&2
        echo "git hook is wired here to read it afterwards (plugin-only install: a plugin cannot set" >&2
        echo "core.hooksPath). Pass the message with -m so it can be scanned, or install Crewforth fully." >&2
        exit 2
      fi
    fi
  fi
fi

if [ "$FAILED" = 1 ]; then
  echo "GUARD (§4.1/§4.2): the commit content gate rejected this commit before it ran." >&2
  echo "$OUT" >&2
  echo "Fix the flagged content and commit again. --no-verify is §4.5 and stays blocked." >&2
  exit 2
fi
exit 0
}
_gate_main "$@"
_crew_stop "a command of the gate was abandoned"
