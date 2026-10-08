#!/usr/bin/env bash
# prompt-approval.sh - the user's own message as the approval for a commit or a push (§4.4).
#
# WHY. In `auto` and `dontAsk` the §4.4 gate fails closed: a permission prompt raised there is answered by
# software, so it proves nothing. Until now the only way through was to switch mode for every commit. What a
# person DOES still do in those modes is type. `UserPromptSubmit` is handed the text of the submitted prompt, and
# the model cannot raise that event: so a message that is nothing but an approval is evidence that a person said
# yes, and this hook is the only thing that turns it into a record.
#
# WHAT COUNTS. The WHOLE message, trimmed, is one of (letter case does not matter):
#     /crew-approve commit      /crew-approve push      /crew-approve commit+push
# and, as the release candidates of 3.1.0 had it, `approve: <what>` or `onay: <what>`.
# A sentence that contains those words is not an approval, and neither is a message with a second line: text
# that was pasted, quoted or relayed from somewhere else never has that shape by accident.
#
# WHAT IS RECORDED is measured here, never taken from the message:
#     commit  ->  the id of the tree the index writes + HEAD, so the approval covers exactly what was staged
#                 when the user answered
#     push    ->  HEAD + the current branch + the remote that branch pushes to, and the address it pushes to
#     commit+push  ->  both; the push half is checked against the commit the approved index became
#                 (its parent is the recorded HEAD and its tree is the recorded tree)
# plus the session and the time. guard-bash.sh reads the record back in `auto` / `dontAsk` and allows only a command that matches
# it; 30 minutes later, or at the user's next message, it is gone. Nothing here opens §4.5 or §4.6.
#
# WHERE. `crewforth-approval` in the worktree's git directory: never in `git status`, never committed, the same
# place in both editions. A record the model can produce is not a record of the user, so guard-write.sh refuses the
# file tools on it, and guard-bash.sh refuses a shell command that names it, one that feeds THIS hook a payload of
# its own, and (in auto / dontAsk) one that starts a session continuing this one. HONEST SCOPE: those rules match
# names, and the shell is Turing-complete - a command that reaches the same thing without spelling it is past them,
# exactly as it is past the rules that protect the gate scripts.
#
# COST. This runs on every prompt, so the ordinary one is builtins only: no process is started unless the
# message is an approval (then git is asked what is staged). eval/smoke-test.sh pins both.
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
# guard-schedule.sh SOURCES this file for one thing, _crew_appr_op: which text is an approval is decided here and
# nowhere else. Sourced, the file defines its functions and returns before anything is read or written.
_PA_LIB=0; [ "${BASH_SOURCE[0]}" != "$0" ] && _PA_LIB=1
if [ "$_PA_LIB" = 0 ]; then
  IFS= read -r -d '' INPUT || true
  case "$INPUT" in *'"hook_event_name"'*UserPromptSubmit*) ;; *) exit 0 ;; esac
fi
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

# ---- WHICH TEXT IS AN APPROVAL: one function, asked here of the user's prompt and by guard-schedule.sh of a
# prompt a tool is about to schedule ---------------------------------------------------------------------------
_crew_appr_op(){  # $1 = a text, decoded -> OP: commit | push | commit+push, or "" when the text is not an approval
  local P="$1" _k _v LC_ALL=C
  OP=""
  P="${P//$'\r'/}"
  while :; do case "$P" in [$' \t\n']*) P="${P:1}" ;; *) break ;; esac; done
  while :; do case "$P" in *[$' \t\n']) P="${P%?}" ;; *) break ;; esac; done
  [ "${#P}" -le 40 ] || return 0
  case "$P" in
    *$'\n'*) return 0 ;;
    # THE COMMAND: `/crew-approve <what>`, or `/<plugin>:crew-approve <what>` as a plugin names its commands. Measured
    # on Claude Code 2.1.284: a command the user types reaches UserPromptSubmit with `prompt` as typed, and a skill
    # the model starts with the Skill tool raises PreToolUse and PostToolUse only, never that event.
    /*) _k="${P%%[$' \t']*}"; [ "$_k" != "$P" ] || return 0
        _v="${P:${#_k}}"; _k="${_k#/}"; _k="@${_k##*:}" ;;      # `@`: a command, so `crew-approve: commit` as text is not one
    # The text form of 3.1.0's release candidates, kept: `approve: <what>` and `onay: <what>`.
    *:*) _k="${P%%:*}"; _v="${P#*:}" ;;
    *) return 0 ;;
  esac
  _k="${_k//[$' \t']/}"; _v="${_v//[$' \t']/}"
  # In the C locale: under tr_TR an upper-case I does not fold to i, and `ONAY: COMMIT` was not an approval (review).
  shopt -s nocasematch
  case "$_k" in
    @crew-approve|approve|onay)
      case "$_v" in commit) OP=commit ;; push) OP=push ;; commit+push) OP=commit+push ;; esac ;;
  esac
  shopt -u nocasematch
}

[ "$_PA_LIB" = 1 ] && return 0

# A second "prompt" key cannot come from the text of a prompt (inside a JSON string every quote is escaped), so
# more than one means the payload is not the shape this hook knows, and nothing is read from it.
_json_keycount "$INPUT" prompt; _n_prompt=$_KC
_json_slice "$INPUT" prompt >/dev/null; RAW="$_JS"

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
# Such a turn neither gives an approval nor ends one: a review agent handing back between the user's yes and the
# commit must not cost the user a second yes.
_crew_not_a_person "$RAW" && exit 0

_json_slice "$INPUT" cwd >/dev/null; _json_unescape "$_JS" >/dev/null; CWD="$_JU"
[ -n "$CWD" ] || CWD="${CLAUDE_PROJECT_DIR:-.}"
CWD="${CWD//\\//}"
_crew_appr_path "$CWD"; REC="$_AP"

# THE USER'S NEXT MESSAGE ENDS THE APPROVAL, whatever it says. Emptied with a redirection, which is a builtin:
# `rm` would be a process on a hook that runs on every prompt.
if [ -n "$REC" ] && [ -s "$REC" ]; then : > "$REC" 2>/dev/null || true; fi

# ---- is this message an approval? ------------------------------------------------------------------------
[ "$_n_prompt" = 1 ] || exit 0
[ "${#RAW}" -le 120 ] || exit 0        # an approval is a few words; a pasted page is not decoded to find that out
_json_unescape "$RAW" >/dev/null
_crew_appr_op "$_JU"
[ -n "$OP" ] || exit 0

# From here on the message IS an approval, so every way of not recording it says why - to the user and to the
# model - instead of leaving a commit to fail later with no explanation.
say(){  # $1 = for the user, $2 = for the model. Both are built from fixed text and values checked below.
  printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"%s"}}\n' "$1" "$2"
  exit 0
}
no(){ say "Crewforth: approval NOT recorded - $1" "The user's message is an approval for $OP, but Crewforth could not record it: $1 Tell the user exactly that; the commit/push gate stays closed until they approve again."; }

_json_slice "$INPUT" permission_mode >/dev/null; PM="$_JS"
case "$PM" in
  auto|dontAsk) ;;
  # Where a prompt reaches the user the gate asks them itself; in plan and bypassPermissions this route is not
  # open (a decision, 3.1.0). Nothing is recorded and nothing is said: guard-bash.sh explains when it refuses.
  *) exit 0 ;;
esac
[ -n "$REC" ] || no "this directory is not inside a git repository."

# A PERSON, IN A SESSION THAT HAS SHOWN THEM SOMETHING. A session can start another one and hand it the approval as
# its prompt: `claude -p "/crew-approve commit"`, or an interactive one driven through a pseudo-terminal. That
# session's only message is the approval, this hook would record it, and the session would then commit: the first
# session has approved for the user. Measured on Claude Code 2.1.294 (macOS), from a hook that printed what it saw:
#   started how                                CLAUDE_CODE_SESSION_ATTENDED   the transcript file when this hook runs
#   claude -p, from a session's Bash           0 (set to 1 by the caller: still 0)   not there (first message)
#   claude -p, from an emptied environment     0                               not there (first message)
#   interactive, in a pty, from a session      1                               not there, and never written: a
#                                                                              session started inside another keeps none
#   interactive, in a pty, emptied environment 1                               not there at the first message; there after
#   the desktop app, a conversation under way  1                               there
# Nothing else told them apart: the payload has the same fields, CLAUDECODE and CLAUDE_CODE_CHILD_SESSION are 1 in
# all of them, CLAUDE_CODE_ENTRYPOINT is inherited from the outer session, and no hook has a terminal on stdin.
# So two things are asked. Neither is a documented contract, and both fail towards NOT recording:
#   1. the session is not a headless one;
#   2. the session's transcript is already on disk when the approval arrives, so the approval is not the session's
#      first message and the session is not one that keeps no transcript.
# HONEST SCOPE: a session started with an emptied environment and driven through a pseudo-terminal for a second
# message passes both. guard-bash.sh refuses the forms of that it can read; a program that types is past it.
case "${CLAUDE_CODE_SESSION_ATTENDED-}" in
  0) no "this session has nobody in front of it (it was started with -p, or by a program), and an approval is what a person types into their own session." ;;
esac
_json_slice "$INPUT" transcript_path >/dev/null; _json_unescape "$_JS" >/dev/null; TP="${_JU//\\//}"
{ [ -n "$TP" ] && [ -s "$TP" ]; } || no "this is the first message of this session, or the session keeps no transcript (one started from inside another session keeps none). An approval answers a commit message the session has shown: have it shown, then approve."

# The session the user is writing in. guard-bash.sh accepts the record only from that one: a session started by a
# command can be handed any prompt.
_json_slice "$INPUT" session_id >/dev/null; SID="$_JS"
case "$SID" in ''|*[!A-Za-z0-9._-]*) no "this prompt carries no session id to bind the approval to." ;; esac

HEAD_NOW="$(git -C "$CWD" rev-parse --verify --quiet HEAD 2>/dev/null || echo NONE)"
case "$HEAD_NOW" in NONE) ;; *[!0-9a-f]*|'') no "git could not name HEAD here." ;; esac
TREE=""; BR=""; RM=""; URL=""
case "$OP" in commit*)
  # THE TREE THE INDEX WRITES, not the text of the staged diff: what `git diff` prints is configurable
  # (`diff.external`, a textconv filter), and with it two different staged changes can print the same text.
  TREE="$(git -C "$CWD" write-tree 2>/dev/null)"
  case "$TREE" in *[!0-9a-f]*|'') no "git could not write the tree of what is staged (an unresolved merge?)." ;; esac
  if [ "$HEAD_NOW" = NONE ]; then _ht=4b825dc642cb6eb9a060e54bf8d69288fbee4904      # the empty tree
  else _ht="$(git -C "$CWD" rev-parse --verify --quiet 'HEAD^{tree}' 2>/dev/null)"; fi
  [ "$TREE" != "$_ht" ] || no "nothing is staged, so there is nothing to approve. Stage the change with git add, show the commit message, then ask again." ;;
esac
case "$OP" in *push)
  [ "$OP" = push ] && [ "$HEAD_NOW" = NONE ] && no "there is no commit to push yet."
  BR="$(git -C "$CWD" symbolic-ref --short -q HEAD 2>/dev/null || true)"
  [ -n "$BR" ] || no "HEAD is detached, so there is no branch to bind the push to."
  RM="$(git -C "$CWD" config --get "branch.$BR.pushRemote" 2>/dev/null)" \
    || RM="$(git -C "$CWD" config --get remote.pushDefault 2>/dev/null)" \
    || RM="$(git -C "$CWD" config --get "branch.$BR.remote" 2>/dev/null)" || RM=""
  case "$RM" in ''|.)
    RM="$(git -C "$CWD" remote 2>/dev/null)"
    case "$RM" in ''|*$'\n'*) no "this branch has no upstream and the repository does not have exactly one remote, so the push target is not known. Set the upstream, or approve the commit alone." ;; esac ;;
  esac
  # Both values go into JSON and into a line-per-field record, so anything outside this set is refused, not escaped.
  case "$BR$RM" in *[!A-Za-z0-9._/@+-]*) no "the branch or remote name has a character this record does not carry." ;; esac
  # Where that remote pushes TO, with pushurl and pushInsteadOf applied. The name alone can be pointed elsewhere
  # after the approval (`git config remote.origin.pushurl …`), so the address is part of what was approved.
  URL="$(git -C "$CWD" remote get-url --push "$RM" 2>/dev/null)"
  case "$URL" in ''|*$'\n'*) no "the remote $RM does not push to exactly one address." ;; esac ;;
esac
if [ "${BASH_VERSINFO[0]}" -ge 5 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then
  printf -v TS '%(%s)T' -1
else TS="$(date +%s)"; fi
case "$TS" in ''|*[!0-9]*) no "the clock could not be read." ;; esac

{ printf 'v=1\nop=%s\ntree=%s\nhead=%s\nbranch=%s\nremote=%s\nurl=%s\nsid=%s\nts=%s\n' "$OP" "$TREE" "$HEAD_NOW" "$BR" "$RM" "$URL" "$SID" "$TS" > "$REC"; } 2>/dev/null \
  || no "the record could not be written in the git directory."

_h="${HEAD_NOW:0:7}"; _d="${TREE:0:7}"
# THE ADDRESS IS SHOWN TO THE USER, not only compared: a rewrite set BEFORE the approval (`url.<x>.insteadOf`) is
# already in what git reports, so the record and the push agree and only the person can tell that "origin" is not
# where they think (review). Shown to the user alone, with any `user:secret@` taken out, and never put in front of
# the model.
_u="$URL"
case "$_u" in *://*@*) _ua="${_u#*://}"; case "${_ua%%/*}" in *@*) _u="${_u%%://*}://${_ua#*@}" ;; esac ;; esac
case "$_u" in *[\"\\]*|*[![:print:]]*) _u="an address this line cannot print; check it with: git remote get-url --push $RM" ;; esac
case "$OP" in
  commit)      WHAT="commit of what is staged now (tree $_d) on HEAD $_h"
               HOW="Run git commit -m with the message, alone in its call: no other option than -q, -s or -v, no paths, no cd, no pipe, nothing chained. Single-quote the message, or read it from a here-document with a quoted delimiter. The review record of §4.6 is still required." ;;
  push)        WHAT="push of $BR at $_h to $RM"
               HOW="Run exactly: git push $RM $BR (alone in its call: the remote and the branch written out, no cd, no pipe, nothing chained)." ;;
  commit+push) WHAT="commit of what is staged now (tree $_d) on HEAD $_h, then push of that commit on $BR to $RM"
               HOW="Run git commit -m with the message, alone in its call (no other option than -q, -s or -v, no paths, no cd, no pipe, nothing chained; single-quote the message; §4.6 still applies), then in a separate call exactly: git push $RM $BR" ;;
esac
[ -n "$_u" ] && _u=" ($RM pushes to $_u)"
say "Crewforth: approval recorded - $WHAT$_u. Valid for 30 minutes; your next message ends it." \
    "The user approved this in their own message and Crewforth recorded it: $WHAT. $HOW The approval covers what was staged and where HEAD was at that moment, in this session: if either changes it no longer applies and the user approves again. It ends in 30 minutes or at the user's next message. Force-push and the rest of §4.5 are not opened by it."
