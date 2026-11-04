#!/usr/bin/env bash
# loop-guard.sh - notices a turn that has stopped converging: many calls, the same files edited again and again,
# and the same failure coming back. Shipped in SHADOW mode: it records that it would have spoken, and says nothing.
#
# WHY. systematic-debugging step 3 asks for one falsifiable hypothesis before the next change. A session that has
# lost the thread does the opposite: it edits, runs, sees the same error, edits again. Nothing in that loop is
# wrong call by call, so no gate sees it; only the shape of the turn does. This hook counts the shape.
#
# WIRING (settings.json / hooks.json): PostToolUse and PostToolUseFailure, matcher Bash|Edit|Write|MultiEdit|NotebookEdit.
#   PostToolUse          a call that finished: counted; an edit is counted against its file.
#   PostToolUseFailure   a call that failed (Claude Code's own event; a Bash command that exits non-zero arrives here
#                        with its `error` text): counted as a call, and as an error under a normalised signature.
#                        An interrupt (`is_interrupt: true`) is the user's decision, not a failure, and is not an error.
#
# THE TURN. Counters belong to one user prompt. Every hook payload carries `prompt_id` (Claude Code's common input
# field, "UUID identifying the user prompt currently being processed"), so a new prompt is seen here as a changed
# id and the counters start again. No UserPromptSubmit hook is added for it: that would be one more process on every
# prompt to learn what the next tool call already says. A payload without `prompt_id` (an older Claude Code, or a
# call before the first prompt) keeps the counters it has: the window is then the session, and the record says so.
# Subagents count separately: their calls carry `agent_id`, and the state file is named by session and agent.
#
# FIRES when ALL of these hold, once per turn:
#   calls >= 20  AND  (one file edited >= 4 times OR edits across >= 3 files)  AND  errors >= 6
#   AND the most frequent error signature is >= 20% of the errors and was seen at least twice.
# The signature is the first 400 bytes of the error with paths, hex and runs of digits collapsed, so the same failure
# at another line number or in another temp folder is the same signature.
#
# MODES (CREW_LOOP_GUARD):
#   unset / shadow  one JSON line is appended to .claude/state/loop-guard.jsonl: the time, the session, the counters.
#                   Never a command, a path or error text. Nothing reaches the session.
#   on              the redirect below is returned as additionalContext instead (for the A/B that measures it).
#   off             nothing runs and no state is written.
#
# NOT A GATE. It never blocks and never asks: every path out is exit 0, and a failure of its own is silence.
#
# COST. It runs after EVERY Bash, Edit and Write call, and on Git Bash a process costs 20-130 ms. A call that does
# not fire starts no process: the payload is read with the builtin `read` and Crewforth's builtin JSON parser below, the
# state is read with `read` and written with a redirection, the hashes are arithmetic. The first call in a project
# may pay one `mkdir`; a firing call in shadow mode may pay one more `mkdir` and, on bash < 4.2, one `date`.
# Two calls finishing at the same moment can lose one count between them: the state is rewritten without a lock,
# because a lock costs processes on every call and an undercount only makes this quieter.
LG_REDIRECT="Do not stop; form one new falsifiable hypothesis (systematic-debugging step 3) and test it before the next edit."
LG_CALLS=20; LG_FILE_EDITS=4; LG_FILES=3; LG_ERRORS=6; LG_SIG_PCT=20
case "${CREW_LOOP_GUARD:-shadow}" in off|OFF|0|false) exit 0 ;; on|ON|1|true) LG_MODE=on ;; *) LG_MODE=shadow ;; esac
export LC_ALL=C
trap 'exit 0' EXIT
IFS= read -r -d '' INPUT || true
# The fields this reads sit near the front of a payload; a Write's content after them is not needed.
INPUT="${INPUT:0:65536}"

# The JSON helpers are a byte-identical copy of the gates' block (smoke-test pins every copy equal).
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

# ---- helpers: builtins only ------------------------------------------------------------------------------
_lg_id(){  # $1 = raw id -> _LGI: letters, digits, _ and - only, 80 at most (it names a file)
  _LGI="${1//[!A-Za-z0-9_-]/}"; _LGI="${_LGI:0:80}"; }
_lg_hash(){  # $1 = text -> _LGH, a 31-bit djb2 of its bytes (LC_ALL=C, so ${s:i:1} is one byte)
  local s="$1" i=0 n=${#1} h=5381 o
  while [ "$i" -lt "$n" ]; do printf -v o '%d' "'${s:i:1}"; h=$(( (h * 33 + o) & 2147483647 )); i=$((i + 1)); done
  _LGH=$h; }
_lg_sig(){  # $1 = the error, still JSON-escaped -> _LGS: its first 400 bytes, paths/hex/numbers collapsed
  local s="${1:0:400}" w out=""
  s="${s//\\n/ }"; s="${s//\\r/ }"; s="${s//\\t/ }"; s="${s//\\\"/ }"; s="${s//\\\\/\\}"
  set -f; local IFS=$' \t'
  for w in $s; do
    case "$w" in
      */*|*\\*) w=P ;;                  # a path, a URL, a Windows path: where it happened, not what
      0x*|0X*) w=H ;;
      *) if [ "${#w}" -ge 7 ] && [[ "$w" != *[!0-9a-fA-F]* && "$w" == *[0-9]* ]]; then w=H   # a hash, an id
         else w="${w//[0-9]/#}"; while [[ "$w" == *'##'* ]]; do w="${w//'##'/#}"; done; fi ;;   # 42, 1337 -> #
    esac
    out="$out $w"
  done
  set +f; _LGS="${out:0:200}"; }
_lg_num(){  # $@ = values -> 0 when every one is a plain non-negative integer
  local v; for v in "$@"; do case "$v" in ''|*[!0-9]*) return 1 ;; esac; done; return 0; }
_lg_bump(){  # $1 = table name (FT|ST), $2 = key -> _LGN = its new count, _LGNEW = 1 when the key is new
  local tab="${!1}" cur
  _LGNEW=0
  case "$tab" in
    *" $2="*) cur="${tab#* $2=}"; cur="${cur%% *}"; _lg_num "$cur" || cur=0
              _LGN=$((cur + 1)); tab="${tab/ $2=$cur / $2=$_LGN }" ;;
    *) _LGN=1; _LGNEW=1; [ "${#tab}" -lt 6000 ] && tab="$tab$2=1 " ;;   # bounded: a key not kept still counts as new
  esac
  printf -v "$1" '%s' "$tab"; }

# ---- the payload -----------------------------------------------------------------------------------------
_json_slice "$INPUT" hook_event_name >/dev/null; EV="$_JS"
case "$EV" in PostToolUse|PostToolUseFailure) ;; *) exit 0 ;; esac
_json_slice "$INPUT" tool_name >/dev/null; TN="$_JS"
case "$TN" in Bash|Edit|Write|MultiEdit|NotebookEdit) ;; *) exit 0 ;; esac
_json_slice "$INPUT" session_id >/dev/null; _lg_id "$_JS"; SID="$_LGI"; [ -n "$SID" ] || exit 0
_json_slice "$INPUT" agent_id >/dev/null;   _lg_id "$_JS"; AG="$_LGI"
_json_slice "$INPUT" prompt_id >/dev/null;  _lg_id "$_JS"; PID="$_LGI"

# The project: the hook is started in it (settings.json cds there); the plugin edition reads it from the env or the payload.
P="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$P" ]; then _json_slice "$INPUT" cwd >/dev/null; P="${_JS//\\\\/\\}"; fi
P="${P//\\//}"; P="${P%/}"; [ -n "$P" ] || P=.
D="$P/.claude/state"
[ -d "$D" ] || mkdir -p "$D" 2>/dev/null || exit 0
F="$D/loop-$SID${AG:+-$AG}.txt"

# ---- the state: one line of counters, then the file table, then the signature table --------------------------
# lg1 <prompt|-> <calls> <errors> <fired> <files> <max edits one file> <max one signature> <signatures>
S_P=-; S_C=0; S_E=0; S_X=0; S_NF=0; S_MF=0; S_MS=0; S_NS=0; FT=""; ST=""
if [ -f "$F" ]; then
  { read -r _v S_P S_C S_E S_X S_NF S_MF S_MS S_NS; read -r FT; read -r ST; } < "$F" 2>/dev/null
  if [ "${_v:-}" != lg1 ] || ! _lg_num "$S_C" "$S_E" "$S_X" "$S_NF" "$S_MF" "$S_MS" "$S_NS"; then
    S_P=-; S_C=0; S_E=0; S_X=0; S_NF=0; S_MF=0; S_MS=0; S_NS=0; FT=""; ST=""
  fi
fi
# A new prompt is a new turn: everything starts again.
if [ -n "$PID" ] && [ "$PID" != "$S_P" ]; then
  S_P="$PID"; S_C=0; S_E=0; S_X=0; S_NF=0; S_MF=0; S_MS=0; S_NS=0; FT=""; ST=""
fi
FT=" $FT "; ST=" $ST "

S_C=$((S_C + 1))
case "$TN" in
  Edit|Write|MultiEdit|NotebookEdit)
    _json_slice "$INPUT" file_path >/dev/null; FP="$_JS"
    [ -n "$FP" ] || { _json_slice "$INPUT" notebook_path >/dev/null; FP="$_JS"; }
    if [ -n "$FP" ]; then
      FP="${FP//\\\\/\\}"; FP="${FP//\\//}"
      _lg_hash "$FP"; _lg_bump FT "f$_LGH"
      [ "$_LGNEW" = 1 ] && S_NF=$((S_NF + 1))
      [ "$_LGN" -gt "$S_MF" ] && S_MF=$_LGN
    fi ;;
esac
if [ "$EV" = PostToolUseFailure ]; then
  case "$INPUT" in
    *'"is_interrupt":true'*|*'"is_interrupt": true'*) ;;   # the user stopped it: not a failure
    *) S_E=$((S_E + 1))
       _json_slice "$INPUT" error >/dev/null; _lg_sig "$_JS"; _lg_hash "$_LGS"; _lg_bump ST "s$_LGH"
       [ "$_LGNEW" = 1 ] && S_NS=$((S_NS + 1))
       [ "$_LGN" -gt "$S_MS" ] && S_MS=$_LGN ;;
  esac
fi

# ---- the conjunction -------------------------------------------------------------------------------------------
FIRE=0
if [ "$S_X" = 0 ] && [ "$S_C" -ge "$LG_CALLS" ] && [ "$S_E" -ge "$LG_ERRORS" ] \
   && { [ "$S_MF" -ge "$LG_FILE_EDITS" ] || [ "$S_NF" -ge "$LG_FILES" ]; } \
   && [ "$S_MS" -ge 2 ] && [ $((S_MS * 100)) -ge $((S_E * LG_SIG_PCT)) ] \
   && :; then
  FIRE=1; S_X=1
fi
FT="${FT# }"; FT="${FT% }"; ST="${ST# }"; ST="${ST% }"
printf 'lg1 %s %s %s %s %s %s %s %s\n%s\n%s\n' "$S_P" "$S_C" "$S_E" "$S_X" "$S_NF" "$S_MF" "$S_MS" "$S_NS" "$FT" "$ST" > "$F" 2>/dev/null
[ "$FIRE" = 1 ] || exit 0

if [ "$LG_MODE" = on ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}\n' "$EV" "$LG_REDIRECT"
  exit 0
fi
# Shadow: one line, counters only. Epoch seconds, which no time zone changes.
if [ -n "${EPOCHSECONDS:-}" ]; then TS=$EPOCHSECONDS
elif [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" = 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then printf -v TS '%(%s)T' -1
else TS="$(date +%s 2>/dev/null)"; fi
_lg_num "$TS" || TS=0
TURN=prompt; [ "$S_P" = - ] && TURN=session
# Beside the counters, in .claude/state, and not in .crewforth/: that directory holds what a team shares (crew-map.json,
# review.json), so a per-session log written there could be committed by a team that tracks it.
O="$P/.claude/state"; [ -d "$O" ] || mkdir -p "$O" 2>/dev/null || exit 0
printf '{"ts":%s,"session":"%s","agent":"%s","mode":"shadow","window":"%s","calls":%s,"errors":%s,"files_edited":%s,"max_edits_one_file":%s,"top_signature":%s,"signatures":%s}\n' \
  "$TS" "$SID" "$AG" "$TURN" "$S_C" "$S_E" "$S_NF" "$S_MF" "$S_MS" "$S_NS" >> "$O/loop-guard.jsonl" 2>/dev/null
exit 0
