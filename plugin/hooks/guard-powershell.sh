#!/usr/bin/env bash
# Claude Code PreToolUse (PowerShell) — Crewforth's own scripts run through the Bash tool, never PowerShell.
#
# The skills, the agents and the hooks' own messages tell the model to run `bash .claude/hooks/<x>.sh` or
# `bash .claude/eval/<x>.sh`. On Windows the model sometimes sends that line through the PowerShell tool, and there
# `bash` can resolve to WSL's bash.exe: the script runs in another filesystem and fails, or runs against nothing.
# Measured in a field session: six PowerShell attempts at Crewforth's scripts, every one an error from WSL, while the
# same commands through the Bash tool (Git Bash) exit 0. This hook stops that one call and names the right tool, so
# the next attempt is the one that works.
#
# SCOPE, and nothing else: a word-boundary `bash` or `bash.exe` (a quoted full path included), optional flags, then
# a path whose folder is `.claude/hooks/` or `.claude/eval/` — relative, `./`, quoted or with an absolute prefix,
# with either slash. In the plugin edition the plugin root stands where `.claude` stands. Every other PowerShell
# command passes untouched: reading a hook file, `Test-Path` on it, `git config core.hooksPath`, `bash build.sh`.
# It is a redirect, not a security gate — the §4 rules for PowerShell live in guard-bash.sh, wired on the same tool —
# so a payload it cannot read is let through rather than refused.
#
# Wired ONLY on the PowerShell matcher (both editions; smoke pins it). On `Bash` it would block the very commands it
# points to.
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
# Read with the builtin: `INPUT="$(cat)"` is a subshell plus a process on EVERY PowerShell call, and on Git Bash a
# process costs 62-135 ms. With this, a command that cannot match (no `bash` in the payload) opens no process at all
# (measured with the xtrace counter: `cat` 1 -> 0). `read` returns 1 at end of input; the text is read regardless.
IFS= read -r -d '' INPUT || true
case "$INPUT" in *[Bb][Aa][Ss][Hh]*) ;; *) exit 0 ;; esac

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

# The matcher already routes only PowerShell here; the tool name is read anyway, so a wiring slip onto `Bash` cannot
# block the very commands this hook points to. `_json_slice` leaves its value in _JS: no fork for the read.
_json_slice "$INPUT" tool_name >/dev/null; [ "${_JS:-}" = PowerShell ] || exit 0
_json_keycount "$INPUT" command
[ "$_KC" = 1 ] && [ "$_KC_CAPPED" = 0 ] || exit 0          # unreadable or ambiguous: guard-bash.sh judges those
CMD="$(_json_unescape "$(_json_slice "$INPUT" command)")"
[ -n "$CMD" ] || exit 0

# WHAT COUNTS AS CREWFORTH'S SCRIPT — one rule, no folder list: any `.sh` under `.claude/` (or under the plugin root,
# which stands where `.claude` stands), except inside a skill the install manifest does not list — that skill is the
# user's own — and except Claude Code's plugin store (`.claude/plugins/`). So a script a later version adds anywhere is
# covered the day it ships.
#
# WHERE `bash` COUNTS: only in command position — the start of a statement (`;` `|` `&` `(` `{` or a newline before
# it), or right after a launcher (`wsl`, `cmd /c`, `Start-Process`, `iex`/`Invoke-Expression`, `pwsh -Command`,
# `bash -c`), optionally as a path to bash.exe. As a search term (`Select-String -Pattern bash -Path …`, `rg bash …`)
# or inside message text (`Write-Output "run bash …"`, a commit message) it is not an invocation and passes.
#
# NO WHOLE-COMMAND REWRITE: folding every backslash with ${CMD//\\//} is quadratic on bash 3.2 (a 60 KB command took
# 65 s, past the hook timeout); the pattern takes either slash instead, and only the short plugin root is folded.
_c="$CMD"
_pr="${CLAUDE_PLUGIN_ROOT:-}"; _pr="${_pr//\\//}"; _pr="${_pr%/}"
case "$_pr" in [A-Za-z]:/*) _pr="${_pr:2}" ;; esac                  # drive-less tail: C:\…, C:/…, c:/… and /c/… all fold
if [ "${#_pr}" -gt 1 ]; then _prb="${_pr//\//\\}"; _c="${_c//"$_pr"//.claude}"; _c="${_c//"$_prb"//.claude}"; fi
_S='[/\\]'; _Q="[\"']"
_NL=$'\n'; _PRE="(^|[;|&({${_NL}])[[:space:]]*"
_LAUNCH="((wsl(\\.exe)?([[:space:]]+(-e|--exec|--))?|cmd(\\.exe)?[[:space:]]+/[ck]|start-process([[:space:]]+-filepath)?|iex|invoke-expression|(pwsh|powershell)(\\.exe)?([[:space:]]+-[a-z]+)*[[:space:]]+-c(ommand)?|(bash|sh)(\\.exe)?([[:space:]]+-[a-z]+)*[[:space:]]+-[a-z]*c[a-z]*)[[:space:]]+${_Q}?)?"
_EXE="(${_Q}([^\"']*${_S})?bash(\\.exe)?${_Q}|([^[:space:]\"';|&(){}]*${_S})?bash(\\.exe)?)"
_PATH="(${_Q}([^\"']*${_S})?|([A-Za-z]:)?([^[:space:]\"']*${_S})?)\\.claude${_S}[^[:space:]\"']+\\.sh"
_re="${_PRE}${_LAUNCH}${_EXE}([[:space:]]+-[^[:space:]]+)*[[:space:]]+${_PATH}"
_man="${BASH_SOURCE%/*}"; [ "$_man" = "$BASH_SOURCE" ] && _man=.; _man="$_man/../kit-manifest.txt"
shopt -s nocasematch
_i=0
while [ "$_i" -lt 20 ] && [[ $_c =~ $_re ]]; do _i=$((_i+1))
  _m="${BASH_REMATCH[0]}"
  _rel="${_m##*.[Cc][Ll][Aa][Uu][Dd][Ee][/\\]}"; _rel="${_rel//\\//}"
  case "$_rel" in
    # ~/.claude/plugins/ is Claude Code's plugin store: whatever is there belongs to its plugin. Crewforth's own
    # plugin copy is recognised through CLAUDE_PLUGIN_ROOT above, which has already turned its path into .claude/.
    plugins/*) _c="${_c#*"$_m"}"; continue ;;
    skills/*/*)
      _n="${_rel#skills/}"; _n="${_n%%/*}"
      # No manifest (the plugin edition, or an install from before the manifest): every skill here is Crewforth's.
      if [ -f "$_man" ]; then
        _mt=$'\n'"$(<"$_man")"$'\n'; _mt="${_mt//$'\r'/}"
        case "$_mt" in *$'\n'"skills/$_n"$'\n'*) ;; *) _c="${_c#*"$_m"}"; continue ;; esac   # the user's own skill
      fi ;;
  esac
  echo "GUARD: Crewforth's scripts run through Claude Code's Bash tool, not PowerShell — this call was not run." >&2
  echo "Send the same command with the Bash tool. In PowerShell, 'bash' can resolve to WSL, where these scripts fail." >&2
  exit 2
done
exit 0
}
_gate_main "$@"
_crew_stop "a command of the gate was abandoned"
