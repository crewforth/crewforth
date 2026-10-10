#!/usr/bin/env bash
# guard-agent-model.sh - a crew agent is called with a task card and a model, and the model fits the card's risk.
#
# WHY. The model for a piece of work is chosen per call, by the risk of the work (the table in CLAUDE.md). 3.1.0's
# first form of this gate looked at the AGENT only, so database work under payments/ ran on Sonnet and passed. The
# risk is in the work: which files, what kind of change, and whether a command can say it is right. So a call to a
# crew-* agent opens with a card,
#     files:  the files or globs it will touch
#     change: text | feature | fix-known | fix-unknown | refactor | migration | security | architecture |
#             test-run | test-write | audit
#     verify: the command that says the work is right, or `none`
# and this gate reads the card. What it holds, all of it by refusing and never by rewriting a call:
#   * the call names a model, and carries a card;
#   * RISK CLASS. `critical` when the change is migration, security, architecture or fix-unknown, or a file is on a
#     critical path (auth, payments, billing, migrations, security, crypto, secrets, *.sql, schema.prisma;
#     .claude/crew-model-rules adds and removes paths). Otherwise `normal`.
#   * critical work runs on opus, whatever the agent. The one exception is test-run: running the tests is objective.
#   * the referee is as strong as the risk: test-write and audit on sonnet or above (opus when critical, by the rule
#     above); review, privacy, planner and database agents on sonnet or above; the security agent on opus.
#   * work with no verify command runs on sonnet or above: haiku goes only to work a command can check.
#   * a class that failed too often is held one model up (crew-model-floors.auto, written by hooks/agent-outcome.sh),
#     until the user lowers it again with /crew-loosen (one model, once for each raise).
#   * a card whose verify failed is not run again on the same or a lower model, and not a third time at all.
#   * critical work with a verify command runs in the foreground, where its result reaches the session.
# THE WORDING IS READ BY ANOTHER PROGRAM (the Studio panel): a refusal is one line that begins
# `GUARD (agent model):`, and a floor is said as ` runs on <model> or above`. The suite pins both.
#
# ALSO A LIBRARY. hooks/guard-write.sh sources this file for the check at write time (an agent that is not on opus
# does not write to a critical path, whatever its card said), and hooks/agent-outcome.sh for the card, the class and
# the state. Sourced, the file defines its functions and returns before it reads anything.
#
# NOT TOUCHED: an agent that is not crew-* (Explore, general-purpose, a project's own), and any tool but Agent.
# SWITCHES, read from the session's environment:
#   CREW_MODEL_ROUTING=off   nothing here does anything, which is how it was before 3.1.0.
#   CREW_ALLOW_FABLE=1       `fable` may be named; without it a call that names it is refused.
# HONEST SCOPE: the card is written by the caller and can be wrong. The write-time check and the verify command are
# what bound that; neither reads intent.
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
_AM_LIB=0; [ "${BASH_SOURCE[0]}" != "$0" ] && _AM_LIB=1
# ---- state: where the records of this gate and of agent-outcome.sh live ----------------------------------------
_am_state(){  # -> _AMP (the project), _AMS (.claude/state), _AMD (the records of calls, agents and results)
  _AMP="${CLAUDE_PROJECT_DIR:-$PWD}"; _AMP="${_AMP//\\//}"; _AMP="${_AMP%/}"
  _AMS="$_AMP/.claude/state"; _AMD="$_AMS/crew-model"
}
_am_rank(){  # $1 = haiku|sonnet|opus|fable -> _AMR 1..4, 0 for anything else
  case "$1" in haiku) _AMR=1 ;; sonnet) _AMR=2 ;; opus) _AMR=3 ;; fable) _AMR=4 ;; *) _AMR=0 ;; esac; }
_am_name(){  # $1 = 1..4 -> _AMN
  case "$1" in 1) _AMN=haiku ;; 2) _AMN=sonnet ;; 3) _AMN=opus ;; 4) _AMN=fable ;; *) _AMN="" ;; esac; }
_am_tier(){  # $1 = a model as a call or a transcript names it -> _AMT haiku|sonnet|opus|fable, "" unknown
  local nc=0; shopt -q nocasematch && nc=1; shopt -s nocasematch
  case "$1" in *haiku*) _AMT=haiku ;; *sonnet*) _AMT=sonnet ;; *opus*) _AMT=opus ;; *fable*) _AMT=fable ;; *) _AMT="" ;; esac
  [ "$nc" = 0 ] && shopt -u nocasematch; return 0; }

# ---- CRITICAL PATHS ---------------------------------------------------------------------------------------------
# One definition, asked of a card's files (this gate), of the file an agent is about to write (guard-write.sh) and
# of every file of the project (the scan in agent-outcome.sh). A path is critical when one of its parts is one of
# these WORDS, standing as a word: after a separator or at a capital (`auth/`, `user_auth.py`, `AuthController.cs`,
# `userAuth.ts`, `AUTH_KEYS`) and not running on in lower case (`author.md`, `cryptography/` are not). And by name:
# a .sql file, schema.prisma. The path is read from the project's root down, so the name of the folder the project
# sits in decides nothing. .claude/crew-model-rules, which only the user writes, adds (`+ glob`) and removes
# (`- glob`); the last line that matches wins.
_AM_W_L='auth|authn|authz|authentication|authorization|oauth|payments?|billing|migrations?|security|crypto|secrets?'
_AM_W_C='Auth|Authn|Authz|Authentication|Authorization|OAuth|Payments?|Billing|Migrations?|Security|Crypto|Secrets?'
_AM_W_U='AUTH|AUTHN|AUTHZ|OAUTH|PAYMENTS?|BILLING|MIGRATIONS?|SECURITY|CRYPTO|SECRETS?'
_AM_RE_L="(^|[^A-Za-z])($_AM_W_L)([^a-z]|\$)"
_AM_RE_C="(^|[^A-Z])($_AM_W_C)([^a-z]|\$)"
_AM_RE_U="(^|[^A-Za-z])($_AM_W_U)([^A-Za-z]|\$)"
_AM_RULES_READ=0; _AM_RULES=()
_am_rules(){  # reads .claude/crew-model-rules once -> _AM_RULES: "+<TAB>glob", "-<TAB>glob", "f<TAB>agent change risk tier", "v<TAB>command"
  local l a b c d
  [ "$_AM_RULES_READ" = 1 ] && return 0
  _AM_RULES_READ=1; _AM_RULES=()
  [ -n "${_AMP:-}" ] || _am_state
  [ -f "$_AMP/.claude/crew-model-rules" ] || return 0
  while IFS= read -r l || [ -n "$l" ]; do
    l="${l%$'\r'}"; l="${l%%#*}"
    while :; do case "$l" in [$' \t']*) l="${l:1}" ;; *) break ;; esac; done
    while :; do case "$l" in *[$' \t']) l="${l%?}" ;; *) break ;; esac; done
    case "$l" in
      "+ "*|"+"$'\t'*) l="${l:1}"; while :; do case "$l" in [$' \t']*) l="${l:1}" ;; *) break ;; esac; done; _AM_RULES+=("+"$'\t'"$l") ;;
      "- "*|"-"$'\t'*) l="${l:1}"; while :; do case "$l" in [$' \t']*) l="${l:1}" ;; *) break ;; esac; done; _AM_RULES+=("-"$'\t'"$l") ;;
      "verify "*) l="${l#verify }"; while :; do case "$l" in [$' \t']*) l="${l:1}" ;; *) break ;; esac; done
                  [ -n "$l" ] && case "$l" in *[\;\&\|\<\>\`\$]*) ;; *) _AM_RULES+=("v"$'\t'"$l") ;; esac ;;
      "floor "*) IFS=$' \t' read -r a b c d _ <<< "${l#floor }"; _am_tier "${d:-}"
                 [ -n "$_AMT" ] && [ -n "${c:-}" ] && _AM_RULES+=("f"$'\t'"$a $b $c $_AMT") ;;
    esac
  done < "$_AMP/.claude/crew-model-rules"
}
_am_rel(){  # $1 = a path as a card or a tool names it -> _AMRP, from the project's root where it is under it
  local p="${1//\\//}"
  [ -n "${_AMP:-}" ] || _am_state
  case "$p" in "$_AMP"/*) p="${p#"$_AMP"/}" ;; ./*) p="${p#./}" ;; esac
  _AMRP="$p"
}
_am_crit_path(){  # $1 = a path or a glob -> 0 critical (_AMW says by what), 1 not
  local p r k g hit=1
  _am_rel "$1"; p="$_AMRP"; _AMW=""
  if [[ "$p" =~ $_AM_RE_L ]] || [[ "$p" =~ $_AM_RE_C ]] || [[ "$p" =~ $_AM_RE_U ]]; then hit=0; _AMW="${BASH_REMATCH[2]}"
  else case "$p" in *.sql|*.SQL) hit=0; _AMW="a .sql file" ;; schema.prisma|*/schema.prisma) hit=0; _AMW="schema.prisma" ;; esac; fi
  _am_rules
  for r in ${_AM_RULES[@]+"${_AM_RULES[@]}"}; do
    k="${r%%$'\t'*}"; g="${r#*$'\t'}"
    case "$k" in +|-) ;; *) continue ;; esac
    # A rule's glob matches the path, anything under it, and the same at any depth.
    case "$p" in $g|$g/*|*/$g|*/$g/*) if [ "$k" = + ]; then hit=0; _AMW="crew-model-rules: + $g"; else hit=1; _AMW=""; fi ;; esac
  done
  return "$hit"
}

# ---- THE CARD ---------------------------------------------------------------------------------------------------
_AM_CHANGES=' text feature fix-known fix-unknown refactor migration security architecture test-run test-write audit '
_am_card(){  # $1 = a task text -> 0 and CARD_FILES, CARD_CHANGE, CARD_VERIFY; 1 and CARD_WHY
  local s="$1" l k v n=0 seen=""
  CARD_FILES=""; CARD_CHANGE=""; CARD_VERIFY=""; CARD_WHY=""
  s="${s//$'\r'/}"
  while [ "$n" -lt 3 ] && [ -n "$s" ]; do
    l="${s%%$'\n'*}"; if [ "$l" = "$s" ]; then s=""; else s="${s#*$'\n'}"; fi
    while :; do case "$l" in [$' \t']*) l="${l:1}" ;; *) break ;; esac; done
    [ -n "$l" ] || continue
    n=$((n+1))
    case "$l" in *:*) ;; *) CARD_WHY="line $n of the task is not one of files:, change:, verify:"; return 1 ;; esac
    k="${l%%:*}"; v="${l#*:}"
    while :; do case "$v" in [$' \t']*) v="${v:1}" ;; *) break ;; esac; done
    while :; do case "$v" in *[$' \t']) v="${v%?}" ;; *) break ;; esac; done
    case "$k" in
      files)  CARD_FILES="$v" ;;
      change) CARD_CHANGE="$v" ;;
      verify) CARD_VERIFY="$v" ;;
      *) CARD_WHY="line $n of the task is not one of files:, change:, verify:"; return 1 ;;
    esac
    case "$seen" in *" $k "*) CARD_WHY="the card names $k twice"; return 1 ;; esac
    seen="$seen $k "
  done
  [ "$n" = 3 ] || { CARD_WHY="the task does not begin with the three lines files:, change:, verify:"; return 1; }
  [ -n "$CARD_FILES" ] || { CARD_WHY="files: is empty (name the files or globs, or the folder)"; return 1; }
  case "$_AM_CHANGES" in *" $CARD_CHANGE "*) ;; *) CARD_WHY="change: is '${CARD_CHANGE:0:40}', not one of:$_AM_CHANGES"; return 1 ;; esac
  [ -n "$CARD_VERIFY" ] || { CARD_WHY="verify: is empty (a command, or none)"; return 1; }
  case "$CARD_VERIFY" in none|None|NONE|-) CARD_VERIFY=none ;; esac
  return 0
}
_am_risk(){  # after _am_card -> CARD_RISK critical|normal, CARD_RISKWHY
  local f unglob=0
  CARD_RISK=normal; CARD_RISKWHY=""
  case " migration security architecture fix-unknown " in *" $CARD_CHANGE "*) CARD_RISK=critical; CARD_RISKWHY="change: $CARD_CHANGE" ;; esac
  case "$-" in *f*) ;; *) unglob=1; set -f ;; esac
  for f in ${CARD_FILES//,/ }; do
    if _am_crit_path "$f"; then CARD_RISK=critical; [ -n "$CARD_RISKWHY" ] || CARD_RISKWHY="$f is on a critical path: $_AMW"; fi
  done
  [ "$unglob" = 1 ] && set +f
  return 0
}
_am_digest(){  # after _am_card -> CARD_ID: 12 hex of what the card says, so "the same card" is the same value
  local t
  t="$(printf '%s\n%s\n%s\n' "$CARD_FILES" "$CARD_CHANGE" "$CARD_VERIFY" | git hash-object --stdin 2>/dev/null)" || t=""
  case "$t" in ''|*[!0-9a-f]*) t="$(printf '%s\n%s\n%s\n' "$CARD_FILES" "$CARD_CHANGE" "$CARD_VERIFY" | cksum 2>/dev/null)"; t="${t%% *}"; printf -v t '%012x' "${t:-0}" 2>/dev/null || t=000000000000 ;; esac
  CARD_ID="${t:0:12}"
}
_am_rec_get(){  # $1 = a record file, $2 = key -> _AMV (lines are key=value)
  local l; _AMV=""
  [ -f "$1" ] || return 1
  while IFS= read -r l || [ -n "$l" ]; do case "$l" in "$2="*) _AMV="${l#*=}"; return 0 ;; esac; done < "$1"
  return 1
}

# ---- THE CALIBRATION FLOOR IN FORCE for a class ------------------------------------------------------------------
# hooks/agent-outcome.sh raises it (crew-model-floors.auto: agent, change, risk, model, calls, not-first-try, when);
# the user lowers it, one model, once for each raise, with /crew-loosen (crew-model-loosened.tsv: ts, agent, change,
# risk, from, to; written by hooks/prompt-approval.sh from the user's own message). A lowering counts when it is
# NEWER than the raise it answers: raised again afterwards, the floor is the raised one. One function, asked by this
# gate, by the hook that raises, and by the hook that records the lowering.
_am_floor_now(){  # $1 agent, $2 change, $3 risk -> _AMF_TIER (the raised floor, "" none), _AMF_WHEN, _AMF_LOOSE 0|1,
                  #   _AMF_TO and _AMF_LTS (the lowering that is in force), _AMF_EFF (the floor that holds now, "" none)
  local a b c t n bad w ts la lb lc lf lt
  _AMF_TIER=""; _AMF_WHEN=""; _AMF_LOOSE=0; _AMF_TO=""; _AMF_LTS=""; _AMF_EFF=""
  [ -n "${_AMS:-}" ] || _am_state
  [ -f "$_AMS/crew-model-floors.auto" ] || return 0
  while IFS=$'\t' read -r a b c t n bad w || [ -n "$a" ]; do
    [ "$a" = "$1" ] && [ "$b" = "$2" ] && [ "$c" = "$3" ] || continue
    _AMF_TIER="${t%$'\r'}"; _AMF_WHEN="${w%$'\r'}"
  done < "$_AMS/crew-model-floors.auto"
  [ -n "$_AMF_TIER" ] || return 0
  _AMF_EFF="$_AMF_TIER"
  [ -f "$_AMS/crew-model-loosened.tsv" ] || return 0
  while IFS=$'\t' read -r ts la lb lc lf lt || [ -n "$ts" ]; do
    [ "$la" = "$1" ] && [ "$lb" = "$2" ] && [ "$lc" = "$3" ] || continue
    lt="${lt%$'\r'}"
    # ISO 8601 in UTC sorts as text. Only a lowering of THIS raise counts: not older than it (the same second is a
    # lowering of it; the hook that raises again never stamps the second of a lowering), from its model, one down.
    [[ "$ts" < "$_AMF_WHEN" ]] && continue
    [ "$lf" = "$_AMF_TIER" ] || continue
    _am_rank "$lf"; n="$_AMR"; _am_rank "$lt"; [ "$_AMR" -gt 0 ] && [ "$_AMR" = $((n-1)) ] || continue
    _AMF_LOOSE=1; _AMF_TO="$lt"; _AMF_LTS="$ts"; _AMF_EFF="$lt"
  done < "$_AMS/crew-model-loosened.tsv"
  return 0
}

# ---- the gate log: a refusal of this gate is recorded like any other gate's -------------------------------------
_am_log(){  # $1 = the rule. Same file and line shape as guard-bash.sh's gatelog; the call's text is never recorded.
  local gl="${CREW_GATE_LOG:-}" v=BLOCK
  case "$1" in "note: "*) v=NOTE ;; esac          # something worth knowing that refused nothing
  if [ -z "$gl" ]; then
    [ -d ".claude" ] || return 0
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then git check-ignore -q ".claude/gate-log.tsv" 2>/dev/null || return 0; fi
    gl=".claude/gate-log.tsv"
  fi
  printf '%s\t§model\t%s\t\n' "$v" "$1" >> "$gl" 2>/dev/null || true
}

# ---- IS THIS VERIFY COMMAND ONE A HOOK MAY RUN? ------------------------------------------------------------------
# The command comes from the card, which the session wrote, and hooks/agent-outcome.sh would run it when the agent
# stops: outside any tool call, so past the permission rules, the auto-mode classifier and every PreToolUse gate.
# A list of what must NOT run cannot close that (the shell gate is such a list, and `python3 -c`, `node -e`, `npx`,
# `find -delete`, a wrapper like `timeout`, and a runner's own options such as `go test -exec` or `make SHELL=…`
# all pass it; found in review). So the rule is what MAY run, and everything else is left for the session to run
# itself, with the Bash tool, where the permission layer sees it. One function, asked at the moment the command
# would start; the rules, in this order:
#   1. ONE command: no `;`, `&`, `|`, `<`, `>`, backtick, `$(` or second line.
#   2. Never a git commit or a git push: an approval the user gave the SESSION is not for a hook.
#   3. NOT DENIED. A `Bash(...)` rule of permissions.deny or permissions.ask that covers it, in ANY settings file
#      (the project's two, the user's, a managed one), stops it: a hook cannot ask, and a deny is a deny. What
#      cannot be read stops it too: a settings file that is there and does not parse (a comment, a byte-order
#      mark), and a deny or ask rule in a form this reader does not match (a `*` that is not at the end, as in
#      `Bash(git * --force)`). Not knowing what is denied is not the same as nothing being denied.
#   4. ALLOWED BY NAME, one of:
#        a. a line `verify <command>` of .claude/crew-model-rules (the user's file);
#        b. a `Bash(...)` rule of permissions.allow in any of those settings files (a bare `Bash` allows nothing);
#        c. ONLY in `auto` and `bypassPermissions`, the two modes in which Claude Code itself runs a test command
#           without the user having allowed it: a test or build runner from the list below, with arguments that
#           are paths or test names (no argument that begins with `-` or holds `=`: an option can name a program
#           to run), and for make, mvn and gradle no argument at all (a second target is a second task). In
#           `default`, `acceptEdits` and `plan` Claude Code asks first, and `dontAsk` refuses whatever was not
#           allowed beforehand, so there the list allows nothing and only a or b does.
#   5. THE SHELL GATE AGREES, asked under a session id that is not the session's: only "nothing to say" or an
#      explicit allow passes.
_AM_HERE="${BASH_SOURCE%/*}"; [ "$_AM_HERE" = "${BASH_SOURCE}" ] && _AM_HERE=.
# CREW-NOT-A-RUNG: names of commands a PROJECT's verify line may begin with; nothing here is called by Crewforth.
_AM_RUNNERS=('npm test' 'npm t' 'pnpm test' 'yarn test' 'bun test' 'deno test'
  'dotnet test' 'dotnet build' 'flutter test' 'flutter analyze' 'dart test' 'dart analyze' 'go test' 'go build' 'go vet'
  'cargo test' 'cargo build' 'cargo check' 'cargo clippy' 'pytest' 'python -m pytest' 'python3 -m pytest'
  'python -m unittest' 'python3 -m unittest' 'mvn test' 'mvn verify' './mvnw test' './mvnw verify' 'gradle test'
  'gradle check' 'gradle build' './gradlew test' './gradlew check' './gradlew build' 'make test' 'make check'
  'make lint' 'make build' 'tsc' 'eslint' 'ruff check' 'mypy' 'phpunit' 'rspec' 'bundle exec rspec' 'swift test'
  'swift build' 'ctest' 'jest' 'vitest' 'mocha' 'mix test' 'composer test' 'test' 'true')
# /CREW-NOT-A-RUNG
_am_starts(){  # $1 = command, $2 = prefix -> 0 when the command is the prefix or the prefix and more words
  case "$1" in "$2"|"$2 "*) return 0 ;; esac; return 1; }
_am_plain_args(){  # $1 = runner, $2 = what follows it -> 0 when every word is a path or a test name
  local w unglob=0 rc=0
  # For these a further word is a further TASK: `make test deploy`, `gradle build publish`, `mvn test install`.
  case "$1" in make\ *|mvn\ *|./mvnw\ *|gradle\ *|./gradlew\ *) [ -z "$2" ]; return ;; esac
  case "$-" in *f*) ;; *) unglob=1; set -f ;; esac
  for w in $2; do
    # dotnet takes a project, a solution or a folder and nothing else: a bare word there is a verb or a target.
    case "$1" in dotnet\ *) case "$w" in */*|*.*) ;; *) rc=1 ;; esac ;; esac
    case "$w" in
      -[A-Za-z]) [ "$1" = test ] || rc=1 ;;                      # `test -f x`: the one runner whose flags are its questions
      -*|*=*) rc=1 ;;
      *[!A-Za-z0-9_./:@,+%^~\#\[\]\*\?-]*) rc=1 ;;
    esac
  done
  [ "$unglob" = 1 ] && set +f
  return "$rc"
}
_am_settings_files(){  # -> _AMSF: the settings files that exist, one per line: project, local, user, managed
  local f u; _AMSF=""
  # The user's settings are where Claude Code keeps them: CLAUDE_CONFIG_DIR when it is set, ~/.claude otherwise.
  u="${CLAUDE_CONFIG_DIR:-${HOME:+$HOME/.claude}}"; u="${u//\\//}"
  for f in "$_AMP/.claude/settings.json" "$_AMP/.claude/settings.local.json" "${u:+$u/settings.json}" \
           "/Library/Application Support/ClaudeCode/managed-settings.json" "/etc/claude-code/managed-settings.json" \
           "/c/Program Files/ClaudeCode/managed-settings.json" "/c/ProgramData/ClaudeCode/managed-settings.json" \
           "${CREW_MANAGED_SETTINGS:-}"; do          # one more file to read as managed: it can only add rules
    [ -n "$f" ] && [ -f "$f" ] && _AMSF="$_AMSF$f"$'\n'
  done
}
_am_perm_hit(){  # $1 = command, $2 = allow|deny|ask -> 0 a Bash(...) rule of that list covers it (_AMPH names it);
                 # 1 none does; 2 the list cannot be relied on (_AMPH says why): a file that does not parse, or,
                 # for deny and ask, a rule in a form this reader does not match
  local c="$1" list="$2" sj="$_AM_HERE/../eval/lib/settings-json.awk" f x g out
  _AMPH=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if ! awk -v op=validate -f "$sj" "$f" >/dev/null 2>&1; then _AMPH="${f##*/} is there and cannot be read as JSON"; return 2; fi
    out="$(awk -v op=strings -v path="permissions.$list" -f "$sj" "$f" 2>/dev/null)" || out=""
    while IFS= read -r x; do
      x="${x%$'\r'}"; [ -n "$x" ] || continue
      if [ "$x" = Bash ]; then [ "$list" = allow ] && continue; _AMPH="$list: Bash (${f##*/})"; return 0; fi
      case "$x" in 'Bash('*')') ;; *) continue ;; esac
      x="${x#Bash(}"; x="${x%)}"; g=""
      case "$x" in
        ''|'*'|':*') [ "$list" = allow ] && continue; _AMPH="$list: Bash($x) (${f##*/})"; return 0 ;;
      esac
      # A `*` anywhere but at the end is a form this reader does not match. An allow rule it cannot read allows
      # nothing; a deny or an ask rule it cannot read may cover the command, so the list cannot be relied on.
      g="${x%:\*}"; g="${g% \*}"; g="${g%\*}"
      case "$g" in *'*'*) [ "$list" = allow ] && continue; _AMPH="$list: Bash($x) (${f##*/}) is a form this hook does not match"; return 2 ;; esac
      case "$x" in
        *':*') g="${x%:\*}"; _am_starts "$c" "$g" || continue ;;
        *' *') g="${x% \*}"; _am_starts "$c" "$g" || continue ;;
        *'*')  g="${x%\*}"; case "$c" in "$g"*) ;; *) continue ;; esac ;;
        *)     [ "$c" = "$x" ] || continue ;;
      esac
      _AMPH="$list: Bash($x) (${f##*/})"; return 0
    done <<< "$out"
  done <<< "$_AMSF"
  return 1
}
_am_verify_ok(){  # $1 = the command, $2 = permission mode -> 0 it may run (_AMVB says by what); 1 and _AMVW says why not
  local c="$1" pm="${2:-default}" f r rc k g
  _AMVW=""; _AMVB=""
  case "$c" in ''|none) return 0 ;; esac
  case "$c" in
    *$'\n'*|*$'\r'*) _AMVW="it is more than one line"; return 1 ;;
    *';'*|*'&'*|*'|'*|*'<'*|*'>'*|*'`'*|*'$('*) _AMVW="it chains, pipes, redirects or substitutes (; & | < > \` \$( )"; return 1 ;;
    *[$'\001'-$'\010'$'\013'-$'\037']*) _AMVW="it holds a control character"; return 1 ;;
  esac
  c="${c//$'\t'/ }"; while :; do case "$c" in *'  '*) c="${c//  / }" ;; *) break ;; esac; done
  c="${c# }"; c="${c% }"
  if [[ " $c " =~ [[:space:]/]git([[:space:]]+[^[:space:]]+)*[[:space:]]+(commit|push)[[:space:]] ]]; then
    _AMVW="a hook never commits or pushes: the user's approval is for the session's own call"; return 1
  fi
  [ -n "${_AMP:-}" ] || _am_state
  [ -f "$_AM_HERE/../eval/lib/settings-json.awk" ] || { _AMVW="the settings reader is not beside this hook, so the permission rules cannot be read"; return 1; }
  _am_settings_files
  _am_perm_hit "$c" deny; r=$?
  if [ "$r" = 0 ]; then _AMVW="a permission rule denies it ($_AMPH)"; return 1; fi
  if [ "$r" = 2 ]; then _AMVW="what is denied cannot be known ($_AMPH), so nothing is run by the hook"; return 1; fi
  _am_perm_hit "$c" ask; r=$?
  if [ "$r" = 0 ]; then _AMVW="a permission rule says to ask the user first ($_AMPH), and a hook cannot ask"; return 1; fi
  if [ "$r" = 2 ]; then _AMVW="what has to be asked first cannot be known ($_AMPH), so nothing is run by the hook"; return 1; fi
  _am_rules
  for r in ${_AM_RULES[@]+"${_AM_RULES[@]}"}; do
    k="${r%%$'\t'*}"; g="${r#*$'\t'}"; [ "$k" = v ] || continue
    _am_starts "$c" "$g" && { _AMVB="crew-model-rules: verify $g"; break; }
  done
  if [ -z "$_AMVB" ]; then _am_perm_hit "$c" allow; [ "$?" = 0 ] && _AMVB="permissions.$_AMPH"; fi
  if [ -z "$_AMVB" ]; then
    case "$pm" in
      auto|bypassPermissions)
        for r in "${_AM_RUNNERS[@]}"; do
          _am_starts "$c" "$r" || continue
          g=""; [ "$c" != "$r" ] && g="${c#"$r "}"
          if _am_plain_args "$r" "$g"; then _AMVB="runner: $r"; break; fi
          _AMVW="it is a known runner ($r) with an argument a hook does not pass on: an option, an assignment, or for make, mvn and gradle anything after the one target"; return 1
        done
        [ -n "$_AMVB" ] || { _AMVW="it is not a test or build command on this hook's list, and no 'verify <command>' line of .claude/crew-model-rules or Bash(...) rule of permissions.allow names it"; return 1; } ;;
      *) _AMVW="in '${pm:-default}' mode Claude Code does not run a command the user has not allowed, so neither does a hook: allow it by name with a 'verify <command>' line of .claude/crew-model-rules, or a Bash(...) rule of permissions.allow"; return 1 ;;
    esac
  fi
  [ -f "$_AM_HERE/guard-bash.sh" ] || { _AMVW="the shell gate is not beside this hook, so the command cannot be judged"; return 1; }
  case "$pm" in *[!A-Za-z]*|'') pm=default ;; esac
  f="${c//\\/\\\\}"; f="${f//\"/\\\"}"
  r="$(printf '{"session_id":"crew-verify-not-a-session","permission_mode":"%s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"%s"}}' "$pm" "$f" | CREW_GATE_LOG=/dev/null bash "$_AM_HERE/guard-bash.sh" 2>/dev/null)"; rc=$?
  if [ "$rc" != 0 ]; then _AMVW="the shell gate refuses it"; return 1; fi
  case "$r" in
    '') return 0 ;;
    *'"permissionDecision"'*'"ask"'*)  _AMVW="the shell gate would ask the user about it, and a hook cannot ask"; return 1 ;;
    *'"permissionDecision"'*'"deny"'*) _AMVW="the shell gate denies it"; return 1 ;;
    *'"permissionDecision":"allow"'*|*'"permissionDecision": "allow"'*) return 0 ;;
    *) _AMVW="the shell gate answered something that is not an allow"; return 1 ;;
  esac
}

# ---- AT WRITE TIME (called by guard-write.sh) -------------------------------------------------------------------
# The card can leave a file out. So an agent that is not on opus does not write to a critical path at all: the write
# is refused where it happens, and the agent is told to stop and say so. Which model the agent is on: the record
# made when it was called (matched to it when it started), else what its own transcript names. Not known is not
# opus. The session's own writes carry no agent_id and are not this check's.
_am_write_check(){  # $1 = the payload, $2 = the file about to be written -> returns 0, or refuses and exits 2
  local in="$1" fp="$2" aid tp tier="" f m
  [ "${CREW_MODEL_ROUTING:-}" = off ] && return 0
  case "$in" in *'"agent_id"'*) ;; *) return 0 ;; esac
  _am_state
  _am_crit_path "$fp" || return 0
  _json_keycount "$in" agent_id; _json_slice "$in" agent_id >/dev/null; aid="$_JS"
  if [ "$_KC" != 1 ] || [ -z "$aid" ] || [ "${aid//[A-Za-z0-9._-]/}" != "" ]; then
    # The call says it comes from inside an agent and does not say which one. Not known is not opus.
    _am_log "critical path: write by an agent whose id could not be read"
    echo "GUARD (agent model): $_AMRP is on a critical path ($_AMW) and this call comes from an agent whose id could not be read; only an agent on opus writes there. Stop, and end your report with the two lines: escalate: $_AMRP / confidence: low" >&2
    exit 2
  fi
  if _am_rec_get "$_AMD/agents/$aid" tier; then tier="$_AMV"; fi
  if [ -z "$tier" ]; then
    _json_slice "$in" transcript_path >/dev/null; _json_unescape "$_JS" >/dev/null; tp="${_JU//\\//}"
    f="${tp%.jsonl}/subagents/agent-$aid.jsonl"
    if [ -f "$f" ]; then m="$(grep -m1 -o '"model":"[^"]*"' "$f" 2>/dev/null)" || m=""; _am_tier "$m"; tier="$_AMT"; fi
  fi
  case "$tier" in opus|fable) return 0 ;; esac
  _am_log "critical path: write by an agent not on opus"
  echo "GUARD (agent model): $_AMRP is on a critical path ($_AMW) and this agent runs on ${tier:-a model that could not be read}; only an agent on opus writes there. Do not reach the file another way. Stop, and end your report with the two lines: escalate: $_AMRP / confidence: low" >&2
  exit 2
}
[ "$_AM_LIB" = 1 ] && return 0
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
local tn st m ti rank=0 floor=0 fname="" why="" prompt bg tid here nf=0 l d f p pm vrc r a b c t
[ "${CREW_MODEL_ROUTING:-}" = off ] && exit 0
IFS= read -r -d '' INPUT || true
_json_slice "$INPUT" tool_name >/dev/null; tn="$_JS"
case "$tn" in Agent|Task) ;; *) exit 0 ;; esac
# The call's own fields: everything from "tool_input" on, so a key of the same name in front of it is not read.
_json_find "$INPUT" '"tool_input"'
[ "$_JF" -ge 0 ] || exit 0
ti="${INPUT:_JF}"
_json_keycount "$ti" subagent_type
if [ "$_KC" -gt 1 ]; then echo "GUARD (agent model): this call names subagent_type more than once, so which agent it starts cannot be read and the call is refused. Send one." >&2; _am_log "an ambiguous call"; exit 2; fi
_json_slice "$ti" subagent_type >/dev/null; _json_unescape "$_JS" >/dev/null; st="$_JU"
st="${st##*:}"                                  # a plugin names its agents <plugin>:crew-…
case "$st" in crew-*) ;; *) exit 0 ;; esac
case "$st" in *[!A-Za-z0-9_-]*) echo "GUARD (agent model): the agent's name holds a character this gate does not read, so the call is refused." >&2; _am_log "an agent name it cannot read"; exit 2 ;; esac
_json_keycount "$ti" model
if [ "$_KC" -gt 1 ]; then echo "GUARD (agent model): this call names model more than once, so which model it asks for cannot be read and the call is refused. Send one." >&2; _am_log "an ambiguous call"; exit 2; fi
_json_slice "$ti" model >/dev/null; _json_unescape "$_JS" >/dev/null; m="$_JU"
if [ -z "$m" ]; then rank=0; else _am_tier "$m"; if [ -n "$_AMT" ]; then m="$_AMT"; _am_rank "$m"; rank="$_AMR"; else rank=-1; fi; fi
# The agent's own floor, whatever the card says.
case "$st" in
  crew-security-expert) floor=3; why="the security audit" ;;
  crew-privacy-agent|crew-review-agent|crew-planner|crew-database-expert) floor=2; why="this agent's floor" ;;
esac
_am_name "$floor"; fname="$_AMN"
if [ "$rank" = 0 ]; then
  echo "GUARD (agent model): a call to $st has to name its model. Choose haiku, sonnet or opus by the table in CLAUDE.md (risk decides, not size) and repeat the same call with model set.${fname:+ $st runs on $fname or above.}" >&2
  _am_log "no model"; exit 2
fi
if [ "$rank" = -1 ]; then
  echo "GUARD (agent model): '${m:0:40}' is not a model this gate knows. Repeat the call to $st with model haiku, sonnet or opus.${fname:+ $st runs on $fname or above.}" >&2
  _am_log "unknown model"; exit 2
fi
if [ "$rank" = 4 ] && [ "${CREW_ALLOW_FABLE:-}" != 1 ]; then
  echo "GUARD (agent model): fable is not used for a crew agent unless the user has set CREW_ALLOW_FABLE=1 for the session.${fname:+ $st runs on $fname or above.} Repeat the call to $st with haiku, sonnet or opus, by the table in CLAUDE.md." >&2
  _am_log "fable not allowed"; exit 2
fi
# ---- the card ----
_json_keycount "$ti" prompt
if [ "$_KC" -gt 1 ]; then echo "GUARD (agent model): this call names prompt more than once, so its task card cannot be read and the call is refused. Send one." >&2; _am_log "an ambiguous call"; exit 2; fi
_json_slice "$ti" prompt >/dev/null; prompt="${_JS:0:6000}"; _json_unescape "$prompt" >/dev/null; prompt="$_JU"
if ! _am_card "$prompt"; then
  echo "GUARD (agent model): a call to $st opens with its task card and this one does not ($CARD_WHY). Begin the task with three lines, then the task itself: files: <files or globs> / change: <text|feature|fix-known|fix-unknown|refactor|migration|security|architecture|test-run|test-write|audit> / verify: <the command that proves it, or none>.${fname:+ $st runs on $fname or above.}" >&2
  _am_log "no card"; exit 2
fi
_am_state; _am_risk; _am_digest
# ---- the floor of THIS card: the highest of what applies, and the reason that set it ----
if [ "$CARD_VERIFY" = none ] && [ "$floor" -lt 2 ]; then floor=2; why="no verify command, so nothing checks the work but a reader"; fi
case "$CARD_CHANGE" in test-write|audit) if [ "$floor" -lt 2 ]; then floor=2; why="change: $CARD_CHANGE, the referee of the work"; fi ;; esac
if [ "$CARD_RISK" = critical ] && [ "$CARD_CHANGE" != test-run ] && [ "$floor" -lt 3 ]; then floor=3; why="critical work: $CARD_RISKWHY"; fi
# A class the user's rules or the record of outcomes hold higher. Neither can lower anything here.
_am_rules
for r in ${_AM_RULES[@]+"${_AM_RULES[@]}"}; do
  case "$r" in f$'\t'*) ;; *) continue ;; esac
  IFS=' ' read -r a b c t <<< "${r#*$'\t'}"
  case "$a" in '*'|"$st") ;; *) continue ;; esac; case "$b" in '*'|"$CARD_CHANGE") ;; *) continue ;; esac; case "$c" in '*'|"$CARD_RISK") ;; *) continue ;; esac
  _am_rank "$t"; if [ "$_AMR" -gt "$floor" ]; then floor="$_AMR"; why="crew-model-rules: floor $a $b $c $t"; fi
done
_am_floor_now "$st" "$CARD_CHANGE" "$CARD_RISK"
if [ -n "$_AMF_EFF" ]; then
  _am_rank "$_AMF_EFF"
  if [ "$_AMR" -gt "$floor" ]; then floor="$_AMR"; why="this class ($st, $CARD_CHANGE, $CARD_RISK) failed its first try too often on the model below"; [ "$_AMF_LOOSE" = 1 ] && why="$why; lowered once by the user, from $_AMF_TIER"; fi
fi
# A card whose verify failed: not on the same or a lower model again, and not a third time.
p=""
if [ -f "$_AMD/fails/$CARD_ID" ]; then
  d=0
  while IFS= read -r l || [ -n "$l" ]; do l="${l%$'\r'}"; [ -n "$l" ] || continue; nf=$((nf+1)); _am_rank "$l"; if [ "$_AMR" -gt "$d" ]; then d="$_AMR"; p="$l"; fi; done < "$_AMD/fails/$CARD_ID"
fi
if [ "$nf" -ge 2 ]; then
  echo "GUARD (agent model): this card's verify command has failed twice, the second time one model up, so it is not run a third time. Ask the user what to do (AskUserQuestion): what failed, on which models, and the choices. A changed task is a new card." >&2
  _am_log "a third run of a failed card"; exit 2
fi
if [ "$nf" = 1 ]; then
  _am_rank "$p"; d=$((_AMR+1))
  if [ "$d" -gt 3 ] && [ "${CREW_ALLOW_FABLE:-}" != 1 ]; then
    echo "GUARD (agent model): this card's verify command failed on $p and there is no model above it to repeat on. Ask the user what to do (AskUserQuestion). A changed task is a new card." >&2
    _am_log "a failed card with no model above"; exit 2
  fi
  if [ "$d" -gt "$floor" ]; then floor="$d"; why="its verify command failed on $p, so the repeat goes one model up"; fi
fi
_am_name "$floor"; fname="$_AMN"
if [ "$rank" -lt "$floor" ]; then
  echo "GUARD (agent model): $st runs on $fname or above for this card ($why), and this call asks for $m. Repeat the same call with model $fname." >&2
  _am_log "below the floor of the card"; exit 2
fi
# ---- where it runs, and what its verify command is ----
_json_keycount "$ti" run_in_background
if [ "$_KC" -gt 1 ]; then echo "GUARD (agent model): this call names run_in_background more than once, so where it runs cannot be read and the call is refused. Send one." >&2; _am_log "an ambiguous call"; exit 2; fi
_json_find "$ti" '"run_in_background"'; bg=unset
if [ "$_KC" = 1 ] && [ "$_JF" -ge 0 ]; then f="${ti:_JF+19:12}"; f="${f//[$' \t\n\r']/}"; case "$f" in :false*) bg=false ;; :true*) bg=true ;; esac; fi
if [ "$CARD_RISK" = critical ] && [ "$CARD_VERIFY" != none ] && [ "$bg" != false ]; then
  echo "GUARD (agent model): critical work with a verify command runs in the foreground, where its result comes back to you: repeat the same call with run_in_background set to false (left out, an agent starts in the background)." >&2
  _am_log "critical work not in the foreground"; exit 2
fi
# The verify command is NOT judged here. Whether the hook runs it is decided when it would start (_am_verify_ok, in
# hooks/agent-outcome.sh): a command it will not run is recorded as blocked and the session is told to run it
# itself with the Bash tool, where the permission layer and the shell gate see it. Refusing the call for it would
# leave no way to use a verify command in a mode where nothing is allowed by name.
# ---- the record of this call, for the agent it starts ----
_json_slice "$INPUT" tool_use_id >/dev/null; tid="$_JS"; case "$tid" in ''|*[!A-Za-z0-9._-]*) tid="x$RANDOM" ;; esac
if mkdir -p "$_AMD/pending" 2>/dev/null; then
  if [ "${BASH_VERSINFO[0]}" -ge 5 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then printf -v t '%(%s)T' -1; else t="$(date +%s)"; fi
  { printf 'agent=%s\ntier=%s\nchange=%s\nrisk=%s\ncard=%s\nbg=%s\nesc=%s\nverify=%s\nfiles=%s\n' "$st" "$m" "$CARD_CHANGE" "$CARD_RISK" "$CARD_ID" "$bg" "${p:--}" "$CARD_VERIFY" "$CARD_FILES" > "$_AMD/pending/$t-$tid"; } 2>/dev/null || true
fi
exit 0
}
_gate_main "$@"
_crew_stop "a command of the gate was abandoned"
