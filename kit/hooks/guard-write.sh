#!/usr/bin/env bash
# Claude Code PreToolUse guard for the FILE tools (Write / Edit / NotebookEdit).
# Companion to guard-bash.sh: that one covers shell tampering, this one covers the model editing the gate
# scripts directly with its file tools. A gate you can silently rewrite is not a gate.
#
# stdin JSON: {"tool_name":"Write|Edit|...","tool_input":{"file_path":"...", ...}}
#
# HARD BLOCK (exit 2, every permission mode) when the target is a gate FILE:
#   - .claude/hooks/*       (guard-bash.sh, guard-write.sh, pre-commit, commit-msg, session-guard.sh, blocklists)
#   - .git/hooks/*          (the armed git hooks themselves)
#   - .claude/DISCIPLINE.md (kit-owned, @imported every session, and the text of §4.1-§4.5 itself — the gates
#     enforce those rules, so leaving the rules writable means the gates can be emptied without touching a gate)
# settings.json is deliberately NOT blocked: the update-config skill legitimately edits it, and a hook/permission
# change there is reviewable — the irreversible, silent move is rewriting the scripts, so that is what we gate.
#
# THE PATH IS NORMALISED BEFORE IT IS MATCHED, and that is the whole point of this file's second half.
# Until this version the gate compared the RAW string, so it recognised exactly one spelling of each gate path.
# Every line below was measured against the shipped hook and reached rc=0 — a SINGLE Write call, no shell
# access, no symlink, no second step:
#     .claude/skills/../hooks/guard-bash.sh      .claude//hooks/…       .claude/./hooks/…
#     .git/refs/../hooks/pre-commit              C:\…\.claude\hooks\…    (backslashes)
# The backslash row is a string fact, measured here: the matcher recognised `/` only, while five other hooks in
# Crewforth already fold Windows separators and this one did not. What a real Windows install actually puts in
# `file_path` is NOT measured on the machine this was written on and must not be assumed — it is verified on
# Windows. Folding both spellings is correct either way, which is why the fix does not wait for that answer.
# NotebookEdit was a sixth hole on any machine with neither jq nor python3 — the pre-tier-3 fallback read
# only `file_path`, and `notebook_path` is a different key.
# Claude Code passes file_path to the hook VERBATIM (measured: a `..` survives into the payload) while the
# filesystem resolves it, so the string the model writes and the file it opens are two different things.
# Normalise first, match second — and normalise with parameter expansion only, because this hook runs before
# EVERY Write/Edit and a fork per call is a freeze on Windows (Git Bash charges 62-135 ms per process, measured).
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
# The 2.x names of the variables a user can set still work (one helper: eval/lib/crew-env.sh).
_crew_d="${BASH_SOURCE%/*}"; [ "$_crew_d" = "${BASH_SOURCE}" ] && _crew_d=.
[ -f "$_crew_d/../eval/lib/crew-env.sh" ] && . "$_crew_d/../eval/lib/crew-env.sh"; unset _crew_d
# Read with the builtin, as guard-powershell.sh does: `INPUT="$(cat)"` is a subshell plus a process on EVERY call
# of this hook. `read` returns 1 at end of input; the text is read regardless.
IFS= read -r -d '' INPUT || true

# The two helpers below are a byte-identical copy of guard-bash.sh's block. A shared file would have to be
# added to build-plugin.sh's explicit copy list and a miss there breaks the plugin channel silently — the same
# reasoning as the CREW-TRANSCRIPT-DIR resolver, which is duplicated for the same reason. Two copies are only
# safe while they cannot drift, so smoke-test pins these markers byte-identical rather than trusting it.
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

block(){  # $1 = rule name for the log (must keep the `gate-file edit` prefix — /crew-gates groups on it), $2 = why
  # Same write-only observability channel as guard-bash.sh, on by default into .claude/gate-log.tsv since 2.5.0
  # and with the same rule about the payload: the path is NOT recorded unless CREW_GATE_LOG_CMD=1, because
  # /crew-gates reports rule names and counts and never the argument. Logged after the verdict; it cannot
  # change it. CREW_GATE_LOG overrides the path; point it at /dev/null to turn recording off.
  _GL="${CREW_GATE_LOG:-}"
  if [ -z "$_GL" ] && [ -d ".claude" ]; then
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1 || git check-ignore -q ".claude/gate-log.tsv" 2>/dev/null; then
      _GL=".claude/gate-log.tsv"
    fi
  fi
  if [ -n "$_GL" ]; then
    if [ "${CREW_GATE_LOG_CMD:-0}" = 1 ]; then
      printf 'BLOCK\t§4.5\t%s\t%s\n' "$1" \
        "$(printf '%s' "$FP" | tr -d '\000-\037' | cut -c1-200)" >> "$_GL" 2>/dev/null
    else
      printf 'BLOCK\t§4.5\t%s\t\n' "$1" >> "$_GL" 2>/dev/null
    fi
  fi
  echo "GUARD (§4.5): editing '$FP' is blocked AT THE TOOL LEVEL." >&2
  echo "$2" >&2
  echo "Crewforth updates go through the installer/update script, not the assistant's file tools. If the user explicitly wants it changed, they edit it in their own editor." >&2
  exit 2
}
WHY_SCRIPT="This file is a gate script — rewriting it would disarm the trace/secret/approval gates."
WHY_DISC="This file is Crewforth's discipline document — it IS the text of §4.1-§4.5, so editing it empties the rules the gates enforce."
WHY_LINK="A parent directory of this path is a symlink and it resolves into a gate directory, so the write would land on a gate file."
WHY_APPR="This file records the user's own approval for a commit or a push (§4.4). Only the user's message writes it, so a session cannot approve its own commit."
WHY_GITCFG="This file holds core.hooksPath: writing it can switch the git hooks off without touching one of them. Settings go through git config, which the Bash guard reads."
WHY_LONG="The path in this payload is longer than any filesystem accepts. It is refused rather than parsed, because parsing it is the slow path an attacker would aim at."
# Sized from the cost curve, not from PATH_MAX. Tier 3 walks the value character by character and bash string
# append is O(n) each time, so the walk is quadratic: measured 0.09s at 512 raw bytes, 0.52s at 1,024, 3.7s at
# 2,048, ~30s at 4,096. Real paths are nowhere near: measured on a Windows install, actual `file_path` values
# average ~60 bytes and Windows itself stops at 260 without the long-path opt-in (macOS PATH_MAX is 1,024).
# 2,048 therefore keeps every path anyone can really produce and bounds the worst case at a few seconds,
# well inside the 60s timeout this hook had then — the number that mattered, because a hook killed at its timeout emits
# no exit 2 and the write proceeds.
MAXPATH=2048

# ---- extract ---------------------------------------------------------------------------------------------
# Tiers are selected on whether they WORK, not on whether they exist — see the long note in guard-bash.sh.
# Short version, measured on a stock Windows 11 desktop: Windows ships a Microsoft Store redirector stub named
# python3 on PATH by default, `command -v` finds it, it exits 49 with an empty stdout, FP came back "" and
# `[ -z "$FP" ] && exit 0` let the model rewrite .claude/hooks/guard-bash.sh with its Write tool.
# AN AMBIGUOUS TARGET IS REFUSED, and this hook needed it most: it is the one that stops the model rewriting
# the other gates with its file tools. The parser takes the FIRST occurrence of the key, so a harmless path
# placed EARLIER used to decide the verdict. Measured on the shipped hook, tier 3 (the only tier on a stock
# Windows desktop), against `.claude/hooks/guard-bash.sh` as the real target:
#   {"meta":{"file_path":"/tmp/ok.txt"},…"tool_input":{"file_path":".claude/hooks/guard-bash.sh"}}   rc=0
#   {"tool_input":{"file_path":".claude/hooks/guard-bash.sh"}}                                       rc=2
# The raw-payload net further down only fires when FP is EMPTY, and here FP was a plausible non-gate path, so
# nothing looked at the real one. Counted on the raw payload rather than per tier, deliberately: refusing on
# one tier while another reads a different occurrence just moves the divergence instead of closing it.
# Both counts read `_KC` instead of `$( )`: a command substitution is a fork, and this hook runs before every
# Write, Edit, MultiEdit and NotebookEdit call. Measured on macOS the substitution form cost 0.79 ms per call
# and took the whole hook from 13.81 to 15.49 ms; on Git Bash a process is 62-135 ms, so two of them per call
# would have been a freeze on the platform this change exists to protect.
_json_keycount "$INPUT" file_path;     _n_fp=$_KC; _cap_p=$_KC_CAPPED
_json_keycount "$INPUT" notebook_path; _n_nb=$_KC; [ "$_KC_CAPPED" = 0 ] || _cap_p=$_KC_CAPPED
if [ "$_cap_p" != 0 ]; then
  echo "GUARD (§4.5): this payload contains more than $_cap_p occurrences of a path key, so the scan for" >&2
  echo "the real one was stopped. Refusing rather than reading whichever one it had reached." >&2
  exit 2
elif [ $((_n_fp + _n_nb)) -gt 1 ]; then
  echo "GUARD (§4.5): this payload carries $((_n_fp + _n_nb)) path keys (file_path/notebook_path), so the" >&2
  echo "file to judge is ambiguous. Refusing rather than reading whichever comes first." >&2
  exit 2
fi
# ONE READER, EVERYWHERE — the jq/python3 ladder that stood here is gone; the reasoning and the measurements
# are in guard-bash.sh next to the same change. What the ladder cost THIS hook specifically: Windows ships a
# Microsoft Store redirector stub named python3 on PATH by default, `command -v` finds it, it exits 49 with an
# empty stdout, FP came back "" and `[ -z "$FP" ] && exit 0` let the model rewrite .claude/hooks/guard-bash.sh
# with its Write tool. Pure parameter expansion cannot fail that way.
# Through `_JS` / `_JU`, not `$( )`: no fork on the path every Write and Edit takes (3.1.0).
_json_slice "$INPUT" file_path >/dev/null; _raw="$_JS"
[ -n "$_raw" ] || { _json_slice "$INPUT" notebook_path >/dev/null; _raw="$_JS"; }
# THE CAP GOES BEFORE THE UNESCAPER, and the cost it bounds is one the shared reader INTRODUCED — worth saying
# plainly rather than dressing up as a pre-existing bug. What it replaced was a single `sed`, which is linear
# and was never slow; it was replaced because it truncated the value at the first escaped quote and never
# looked at `notebook_path`. The parser that fixes those walks character by character, which is quadratic in
# bash, and on Windows every separator is a backslash, i.e. an escape, so the "no escapes" fast path never
# fires. Uncapped, that is a gate with an off switch: a hook killed at its timeout emits no exit 2 and the
# write proceeds. Refusing above the cap is safe in the direction that matters, and the cap sits far above any
# path a filesystem will accept.
# ONE cap, not two. The second check used to follow the unescaper because the jq tier reached the fold with no
# unescaper in front of it; with one reader that is gone, and the unescaper only ever SHRINKS its input —
# measured over 23 escape forms including a surrogate pair and a 4900-byte run of `€` across the chunk
# edge, with a deliberately-growing stand-in as the calibration, so the check could be seen to fail.
[ "${#_raw}" -le "$MAXPATH" ] || { FP="(oversized path: ${#_raw} bytes)"; block "gate-file edit (oversized path)" "$WHY_LONG"; }
_json_unescape "$_raw" >/dev/null; FP="$_JU"

# Nothing extractable. Exiting 0 unconditionally is what a future field rename turns into a silent bypass, so
# look at the RAW payload instead: refuse only when the text itself names a gate tree. A payload that mentions
# no gate path still passes, so a rename cannot lock anyone out of ordinary work — it can only cost a false
# block on a file whose own path says `.claude/…hooks`, which is the trade this gate exists to make.
if [ -z "$FP" ]; then
  case "$INPUT" in
    *.claude*hooks*|*.git*hooks*|*DISCIPLINE.md*|*crewforth-approval*|*.git/config*|*.git\\config*|*git-shim*|*.gitconfig*|*.config/git/config*) FP="(unparsed payload naming a gate path)"; block "gate-file edit (unparsed payload)" "$WHY_SCRIPT" ;;
  esac
  exit 0
fi

# ---- normalise -------------------------------------------------------------------------------------------
# Windows separators first: Crewforth folds `\\` then `\` in five other hooks and this is the same idiom.
RP="${FP//\\\\//}"; RP="${RP//\\//}"; NP="$RP"
# Lexical resolution of `.`, `..` and repeated slashes. Lexical is the right kind here: it is what makes
# `.claude/skills/../hooks/x` and `.claude/hooks/x` the same string, it costs zero processes, and it cannot be
# defeated by a directory that does not exist yet (a `realpath` on an unborn path returns the input unchanged,
# which is exactly the hole this closes). Symlinks are the one thing lexical resolution gets wrong, and they
# are handled separately below.
_norm(){                               # assigns NORM; NOT `NP="$(_norm …)"` — a command substitution is a
  local p="$1" lead="" seg rest out="" # fork, and a fork per Write/Edit is the cost this whole file avoids
  case "$p" in /*) lead="/" ;; esac
  rest="$p"
  while [ -n "$rest" ]; do
    seg="${rest%%/*}"
    if [ "$seg" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
    case "$seg" in
      ''|'.') continue ;;
      '..')
        if [ -n "$out" ] && [ "${out##*/}" != ".." ]; then
          case "$out" in */*) out="${out%/*}" ;; *) out="" ;; esac
        elif [ -z "$lead" ]; then
          out="${out:+$out/}.."          # relative path climbing above the cwd: keep it, it is not a gate path
        fi
        continue ;;                      # absolute path at the root: `/..` is `/`, so drop it
    esac
    # Trailing dots and spaces are stripped from every component, because Win32 strips them when it OPENS the
    # file: `.claude./hooks/x` and `DISCIPLINE.md ` reach the same inode as the plain spelling there. The
    # `DISCIPLINE.md` rule is an exact tail match with no trailing wildcard, so one trailing byte defeated it.
    # This value is only ever compared, never written through, so a POSIX file genuinely named `foo.` is
    # unaffected in every way except that it would be matched as `foo`.
    while :; do case "$seg" in *.|*' ') seg="${seg%?}" ;; *) break ;; esac; done
    [ -n "$seg" ] || continue
    out="${out:+$out/}$seg"
  done
  NORM="$lead$out"
}
_norm "$NP"; NP="$NORM"
# The plugin root (plugin edition only: the harness exports CLAUDE_PLUGIN_ROOT to plugin hooks), folded like the path.
# In the plugin cache the version folder is a wildcard, so an older cached copy is guarded as well. Read by _is_gate.
_PWB=""; _PWV=""
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  _PWB="${CLAUDE_PLUGIN_ROOT//\\//}"; _PWB="${_PWB%/}"
  case "$_PWB" in [A-Za-z]:/*) _PWB="${_PWB:2}" ;; esac
  case "$_PWB" in */[Pp][Ll][Uu][Gg][Ii][Nn][Ss]/[Cc][Aa][Cc][Hh][Ee]/*/*/*) _PWB="${_PWB%/*}"; _PWB="/${_PWB#"${_PWB%/*/*}"/}"; _PWV='/*' ;; esac
  [ "${#_PWB}" -gt 1 ] || _PWB=""
fi

# ---- match -----------------------------------------------------------------------------------------------
# One place where "is this a gate file?" is answered, because it has to be asked twice — once on the path as
# written, once on the path as it resolves through a symlink.
#
# THE PATTERNS FOLD CASE. APFS and NTFS are case-insensitive by default, so `.CLAUDE/HOOKS/GUARD-BASH.SH` and
# `.claude/hooks/guard-bash.sh` are the SAME FILE — measured on this machine: identical inode, and a write
# through the uppercase spelling landed in the real gate script. The shell-side guard already folds case
# (`grep -i`), so the two guards disagreed on the same path. The bracket form needs no `shopt`, cannot leak
# into a later `case`, and works on bash 3.2.
_is_gate(){   # 0 = gate file; sets GATE_RULE and GATE_WHY
  case "$1" in
    */.[Cc][Ll][Aa][Uu][Dd][Ee]/[Hh][Oo][Oo][Kk][Ss]/*|.[Cc][Ll][Aa][Uu][Dd][Ee]/[Hh][Oo][Oo][Kk][Ss]/*)
      GATE_RULE="gate-file edit (Write/Edit tools)"; GATE_WHY="$WHY_SCRIPT"; return 0 ;;
    */.[Gg][Ii][Tt]/[Hh][Oo][Oo][Kk][Ss]/*|.[Gg][Ii][Tt]/[Hh][Oo][Oo][Kk][Ss]/*)
      GATE_RULE="gate-file edit (Write/Edit tools)"; GATE_WHY="$WHY_SCRIPT"; return 0 ;;
    # .claude/git-shim is where core.hooksPath points when Crewforth shares the hooks with a project's own chain.
    */.[Cc][Ll][Aa][Uu][Dd][Ee]/[Gg][Ii][Tt]-[Ss][Hh][Ii][Mm]/*|.[Cc][Ll][Aa][Uu][Dd][Ee]/[Gg][Ii][Tt]-[Ss][Hh][Ii][Mm]/*|*/.[Cc][Ll][Aa][Uu][Dd][Ee]/[Gg][Ii][Tt]-[Ss][Hh][Ii][Mm]|.[Cc][Ll][Aa][Uu][Dd][Ee]/[Gg][Ii][Tt]-[Ss][Hh][Ii][Mm])
      GATE_RULE="gate-file edit (Write/Edit tools)"; GATE_WHY="$WHY_SCRIPT"; return 0 ;;
    # The gates SOURCE eval/lib/crew-env.sh on every call, so it is part of them: overwritten with `exit 0`, every
    # rule stopped firing (3.0.1 review). Same file in the plugin edition, below.
    */.[Cc][Ll][Aa][Uu][Dd][Ee]/[Ee][Vv][Aa][Ll]/[Ll][Ii][Bb]/[Cc][Rr][Ee][Ww]-[Ee][Nn][Vv].[Ss][Hh]|.[Cc][Ll][Aa][Uu][Dd][Ee]/[Ee][Vv][Aa][Ll]/[Ll][Ii][Bb]/[Cc][Rr][Ee][Ww]-[Ee][Nn][Vv].[Ss][Hh])
      GATE_RULE="gate-file edit (Crewforth gate script)"; GATE_WHY="$WHY_SCRIPT"; return 0 ;;
    */.[Cc][Ll][Aa][Uu][Dd][Ee]/[Dd][Ii][Ss][Cc][Ii][Pp][Ll][Ii][Nn][Ee].[Mm][Dd]|.[Cc][Ll][Aa][Uu][Dd][Ee]/[Dd][Ii][Ss][Cc][Ii][Pp][Ll][Ii][Nn][Ee].[Mm][Dd])
      GATE_RULE="gate-file edit (discipline document)"; GATE_WHY="$WHY_DISC"; return 0 ;;
    # The plugin edition keeps the SAME gate scripts at $CLAUDE_PLUGIN_ROOT/hooks/, which is not `.claude/hooks/`
    # and so matched nothing above — one of Crewforth's three channels shipped an unguarded copy of its own gates.
    # Matched by Crewforth's own filenames rather than by guessing a plugin path, so a project's unrelated
    # `hooks/` directory is untouched.
    */[Hh][Oo][Oo][Kk][Ss]/[Gg][Uu][Aa][Rr][Dd]-*.[Ss][Hh]|*/[Hh][Oo][Oo][Kk][Ss]/[Ss][Ee][Ss][Ss][Ii][Oo][Nn]-[Gg][Uu][Aa][Rr][Dd].[Ss][Hh])
      GATE_RULE="gate-file edit (Crewforth gate script)"; GATE_WHY="$WHY_SCRIPT"; return 0 ;;
    # The record of the user's approval for a commit or a push (§4.4, hooks/prompt-approval.sh). It sits in the git
    # directory and is written from the user's own message only; a session that writes it approves its own commit.
    # Matched by name wherever it is: a linked worktree keeps its git directory elsewhere.
    */[Cc][Rr][Ee][Ww][Ff][Oo][Rr][Tt][Hh]-[Aa][Pp][Pp][Rr][Oo][Vv][Aa][Ll]|[Cc][Rr][Ee][Ww][Ff][Oo][Rr][Tt][Hh]-[Aa][Pp][Pp][Rr][Oo][Vv][Aa][Ll])
      GATE_RULE="approval-record edit (Write/Edit tools)"; GATE_WHY="$WHY_APPR"; return 0 ;;
  esac
  # core.hooksPath lives in git's configuration files: the repository's (.git/config, with a linked worktree's and a
  # submodule's own) and the user's (~/.gitconfig, ~/.config/git/config). Writing one switches the git hooks off without
  # touching a hook. guard-bash.sh carries the same list for the shell. The path gets a slash in front, so one pattern
  # serves both `<dir>/.git/config` and a bare `.git/config`; matched by name, not against $HOME — on Windows the
  # payload says C:\Users\… where the shell says /c/Users/…, and two spellings of one path never compare equal.
  case "/$1" in
    */.[Gg][Ii][Tt]/[Cc][Oo][Nn][Ff][Ii][Gg]|*/.[Gg][Ii][Tt]/[Cc][Oo][Nn][Ff][Ii][Gg].[Ww][Oo][Rr][Kk][Tt][Rr][Ee][Ee]|*/.[Gg][Ii][Tt]/[Ww][Oo][Rr][Kk][Tt][Rr][Ee][Ee][Ss]/*/[Cc][Oo][Nn][Ff][Ii][Gg]|*/.[Gg][Ii][Tt]/[Ww][Oo][Rr][Kk][Tt][Rr][Ee][Ee][Ss]/*/[Cc][Oo][Nn][Ff][Ii][Gg].[Ww][Oo][Rr][Kk][Tt][Rr][Ee][Ee]|*/.[Gg][Ii][Tt]/[Mm][Oo][Dd][Uu][Ll][Ee][Ss]/*/[Cc][Oo][Nn][Ff][Ii][Gg]|*/.[Gg][Ii][Tt][Cc][Oo][Nn][Ff][Ii][Gg]|*/.[Cc][Oo][Nn][Ff][Ii][Gg]/[Gg][Ii][Tt]/[Cc][Oo][Nn][Ff][Ii][Gg])
      GATE_RULE="git-config edit (Write/Edit tools)"; GATE_WHY="$WHY_GITCFG"; return 0 ;;
  esac
  # ...and not only the gate scripts it knew by name: everything under the plugin root's hooks/ (hooks.json, the
  # blocklists, the git hooks, every hook), .claude-plugin/ and the sourced crew-env.sh is the plugin's equivalent of
  # .claude/hooks and settings.json. In Claude Code's plugin cache the root is recognised by its <marketplace>/<plugin>
  # tail with any version after it, so every cached version is covered and the drive spelling does not matter; outside
  # the cache, by the whole path without its drive. Case folded.
  if [ -n "$_PWB" ]; then
    local r=1; shopt -q nocasematch && r=0; shopt -s nocasematch
    case "$1" in *"$_PWB"$_PWV/hooks/*|*"$_PWB"$_PWV/hooks|*"$_PWB"$_PWV/.claude-plugin/*|*"$_PWB"$_PWV/.claude-plugin|*"$_PWB"$_PWV/eval/lib/crew-env.sh)
      [ "$r" = 0 ] || shopt -u nocasematch
      GATE_RULE="gate-file edit (Crewforth gate script)"; GATE_WHY="$WHY_SCRIPT"; return 0 ;; esac
    [ "$r" = 0 ] || shopt -u nocasematch
  fi
  return 1
}
_is_gate "$NP" && block "$GATE_RULE" "$GATE_WHY"

# The one thing lexical resolution cannot see: a symlinked ancestor. Two directions matter and only the second
# one is dangerous — a link INTO the config tree (`cfg -> .claude`, then write `cfg/hooks/guard-bash.sh`),
# which names no gate path at all and so passes every pattern above. Measured before this loop existed: rc=0,
# and the file really was overwritten. The reverse direction — a symlink ABOVE the project (`~/Projects ->
# /Volumes/…`, or plain `/tmp -> private/tmp` on macOS) — is routine and must stay allowed.
#
# So the walk runs for EVERY path (`[ -L ]` is a builtin: no process, and the loop is bounded), and only when
# an ancestor really is a symlink does it pay ONE fork to resolve it and ask the same question again about the
# real location. That fork is charged to the rare case instead of to every Write, which is what the hot-path
# budget requires; an ordinary repo pays nothing at all.
# The walk runs over RP — the folded path BEFORE `..` was collapsed — and that ordering is the rule, not a
# detail. Lexical `..` collapsing is only valid when no component before it is a symlink: with `c -> .claude/
# skills`, the written path `c/../hooks/guard-bash.sh` collapses to `hooks/guard-bash.sh` (no gate) while the
# filesystem resolves `c/..` through the link to `.claude`, landing on the real gate script. Collapsing first
# would delete the very component that has to be examined. Resolving from RP and re-normalising afterwards
# gets both: `<real>/.claude/skills` + `/../hooks/guard-bash.sh` normalises back onto the gate.
_anc="$RP"; _sfx=""; _depth=0
while case "$_anc" in */*) true ;; *) false ;; esac; do
  _depth=$((_depth+1)); [ "$_depth" -gt 64 ] && break
  _sfx="${_anc##*/}${_sfx:+/$_sfx}"
  _anc="${_anc%/*}"
  [ -n "$_anc" ] || break
  if [ -L "$_anc" ]; then
    _real="$(cd -P "$_anc" 2>/dev/null && pwd)"
    if [ -n "$_real" ]; then
      _norm "$_real/$_sfx"
      _is_gate "$NORM" && { FP="$FP  (resolves to $NORM)"; block "gate-file edit (symlinked ancestor)" "$WHY_LINK"; }
    fi
    break
  fi
done

# ---- team board: you may not start work nobody knows you started -----------------------------------------------
# The claim lock already makes it impossible for two people to HOLD the same item — a losing claim is refused in
# under a second, before any code exists. The hole this closes is the other one: somebody who never claims at all.
# Caught only at commit time, that is hours of work discovered as duplicated at the end, which is exactly the
# wasted effort the board exists to prevent. So the first file edit is where it is caught instead.
#
# Cost: this runs before EVERY Write/Edit, so it must not shell out. board.sh maintains a one-bit flag file
# (present == a board exists, it requires a claim, and this user holds none); everything here is a file test.
[ -n "${CREW_NO_BOARD:-}" ] && exit 0
GD=".git"
[ -d "$GD" ] || GD="$(git rev-parse --git-common-dir 2>/dev/null)"   # worktree/submodule: .git is a file
if [ -n "$GD" ] && [ -f "$GD/crew-board-guard" ]; then
  case "$FP" in
    */docs/*|docs/*|*/.claude/*|.claude/*) ;;   # planning notes and kit config are not the work being claimed
    *)
      # /crew-board is user-only: name the command Claude can run itself, then the slash form for the user.
      _gwd="${BASH_SOURCE%/*}"; _gwd="$(cd "$_gwd" 2>/dev/null && pwd)"
      if [ -f "$_gwd/../.claude-plugin/plugin.json" ]; then _BB="bash \"$_gwd/board.sh\""; else _BB='bash .claude/hooks/board.sh'; fi
      echo "BOARD GATE: you hold no work item, so nobody else can see what you are starting." >&2
      echo "Claim one first (Bash tool, not PowerShell): $_BB claim <id> — $_BB status lists what is free, what is blocked and who holds the rest (or the user can type /crew-board claim <id>)." >&2
      echo "Work that belongs to no item: set CREW_NO_BOARD=1 for this session, and commit it with [chore]." >&2
      echo "Just claimed one elsewhere? The board view is cached — $_BB sync refreshes it (Bash tool, not PowerShell — or the user can type /crew-board sync)." >&2
      exit 2 ;;
  esac
fi
exit 0
}
_gate_main "$@"
_crew_stop "a command of the gate was abandoned"
