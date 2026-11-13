#!/usr/bin/env bash
# Install-time skill/agent security scanner — zero-dep bash + regex. Scans a directory or file (meant for a
# project's EXISTING third-party .claude skills/agents that adopt.sh will coexist with) for supply-chain red flags
# and scores each file:  score = 100 − CRIT×20 − HIGH×10 − MED×3 − LOW×1  (floored at 0).
#   SAFE  ≥ 90 AND no CRIT/HIGH   ·   REVIEW  70–89, or any HIGH   ·   DANGER  < 70, or any CRIT
#
# ADVISORY + HEURISTIC. It substring-matches, so a *security-education* skill (a red-team guide, an exfil example)
# can legitimately score low — REVIEW the flagged file, don't trust the number blindly. Its job is to SURFACE
# curl|bash, prompt-injection directives, credential/exfil patterns, not to prove intent.
#
# Exit: 0 if every scanned file is SAFE, 1 if any is REVIEW/DANGER, 3 if NOTHING WAS SCANNED.
# 3 exists because 0 was answering a question nobody asked. skill-trust.sh gates on this exit code and prints
# "scanner: SAFE" when it is 0 — so a path the scanner never looked at (an empty directory, a vanished target,
# a folder with no manifest) was reported to the user as clean. "I found nothing wrong" and "I did not look"
# are different answers, and only one of them belongs on a security surface.
# Usage:  bash scan-skill.sh [path]   (default: .claude)
set -uo pipefail
# The C locale, so the byte patterns below are matched as bytes and `-i` folds ASCII only (as in every other gate).
export LC_ALL=C
TARGET="${1:-.claude}"

# --- pattern groups (ERE) ------------------------------------------------------------------------------------
# CRIT: download-and-exec, known exfil/collaborator hosts, rm -rf of home/root.
CRIT='(curl|wget|fetch)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(bash|sh|zsh|python[0-9.]*|node|perl|ruby)|(bash|sh)[[:space:]]+<\(|(webhook\.site|requestbin|pipedream\.net|ngrok\.io|burpcollaborator|oastify|interactsh|dnslog\.|\.oast\.)|rm[[:space:]]+-[A-Za-z]*r[A-Za-z]*[[:space:]]+(~|/|\$HOME)([[:space:]]|$|/)'
# HIGH: prompt-injection directives; a credential file READ/exfil (a reader verb + the path — a bare `~/.ssh/id_rsa`
# config value is NOT flagged); base64-decode piped to a shell; and a RUNTIME INSTRUCTION FETCH.
#
# That last one is not a missing regex, it is the assumption the trust model rests on. skill-trust.sh accepts a
# component by DIGEST, and a digest answers "have these bytes changed?" — which is the wrong question for a file
# whose bytes say "fetch your real instructions from this URL". The digest never moves while the behaviour is
# rewritten by whoever controls the endpoint, and the component stays on the accepted list forever. So fetching
# an instruction-shaped file (.md/.txt/.yml/.json) and a WebFetch tied to instructions/prompts are HIGH, while
# an ordinary outbound URL stays LOW: measured against Crewforth's own payload, this flags 0 of 59 files, and the
# two places Crewforth itself names WebFetch (a `tools:` line and a `Requires-tool` marker) are untouched.
HIGH='ignore[[:space:]]+(all[[:space:]]+)?(the[[:space:]]+)?(previous|prior|above)[[:space:]]+(instruction|prompt)|disregard[[:space:]]+(the[[:space:]]+|all[[:space:]]+)?(previous|above|prior)|ignore[[:space:]]+your[[:space:]]+(system[[:space:]]+)?(prompt|instruction)|(cat|less|more|tail|head|base64|xxd|od|strings|curl|wget|scp|cp|rsync)[^|]*(~/\.ssh|id_rsa|/etc/(passwd|shadow)|\.aws/credentials|\.netrc|\.git-credentials)|(~/\.ssh|id_rsa|/etc/(passwd|shadow)|\.aws/credentials|\.netrc|\.git-credentials)[^|]{0,80}(curl|wget|scp|nc |netcat|base64|exfiltrat)|base64[[:space:]]+-[A-Za-z]*d[^|]*\||(curl|wget)[[:space:]][^|]*https?://[^[:space:]]*\.(md|txt|ya?ml|json)|(WebFetch|web_fetch)[^|]{0,120}(instruction|prompt|then follow|steps to follow)'
# A HIDDEN INSTRUCTION in an HTML comment: it renders as nothing in a Markdown preview and in a PR's rich diff, and the
# model reads it like any other line. Only a comment that OPENS on an imperative is flagged, so Crewforth's own
# machine-readable markers (`<!-- routing-eval …`, `<!-- Requires-tool …`) and explanatory comments stay clean.
HIGH="$HIGH"'|<!--[[:space:]]*(ignore|disregard|forget|override|run|execute|send|post|upload|fetch|download|install|delete|remove|exfiltrate|you[[:space:]]+(must|should|are|will)|do[[:space:]]+not|always|never)([^a-z]|$)'
# INVISIBLE TEXT, as UTF-8 bytes (one more grep, in the C locale): Unicode tag characters (U+E0000-E007F, which spell
# ASCII nobody sees), bidi overrides and isolates (U+202A-202E, U+2066-2069, which reorder what an editor shows), and a
# zero-width character (U+200B-200D, U+2060, U+FEFF) BETWEEN two letters, where it splits a word a pattern would catch
# (`ign<ZWSP>ore previous instructions`). A BOM at the start of a file is not between letters and is not flagged.
# Reported as a count only: printing the decoded text would put the hidden instruction in front of the reader.
_ZW='('$'\xe2\x80\x8b''|'$'\xe2\x80\x8c''|'$'\xe2\x80\x8d''|'$'\xe2\x81\xa0''|'$'\xef\xbb\xbf'')'
INVIS=$'\xf3\xa0[\x80\x81]|\xe2\x80[\xaa\xab\xac\xad\xae]|\xe2\x81[\xa6\xa7\xa8\xa9]|[A-Za-z]'"$_ZW"'+[A-Za-z]'
# MED: named cloud/CI secret env vars, process.env secret access, chmod 777, code eval/exec.
MED='(GITHUB_TOKEN|AWS_SECRET|AWS_ACCESS_KEY|NPM_TOKEN|OPENAI_API_KEY|ANTHROPIC_API_KEY|SLACK_TOKEN)|process\.env\.[A-Za-z_]*(TOKEN|SECRET|KEY|PASSWORD)|chmod[[:space:]]+(-R[[:space:]]+)?0?777|[^a-zA-Z](eval|exec)[[:space:]]*\('
# LOW: an outbound URL fetch or a raw socket — common in benign deploy/example prose, hence low weight.
LOW='(^|[^a-zA-Z])(curl|wget)[[:space:]]+[^|]*https?://|/dev/tcp/|[^a-zA-Z]nc[[:space:]]+-[A-Za-z]*e'

# FRONTMATTER: what a component asks the HOST for, read from its YAML header — one awk over all files. A `hooks:` or
# `mcpServers:` key (it brings its own code to run), a `permissionMode:` other than default/plan/manual, and an
# `allowed-tools:` entry that is a bare `Bash` or a `Bash(…)` rule with `*` in it (any command, or any arguments).
# The one `*` rule not counted is a call of the component's OWN script: `Bash(bash ${CLAUDE_SKILL_DIR}/…)` reaches
# only files that ship inside the skill, and the scan already reads those. Anywhere in the file, a `!`cmd`` line
# counts too: it runs when the component loads, before anyone reads it.
FM_AWK='
function tools(v,   n, m, inner) {
  n = 0; sub(/^[[:space:]]*-[[:space:]]*/, "", v)
  if (v ~ /(^|[^A-Za-z])Bash([^A-Za-z(]|$)/) n++
  if (v ~ /(^|[,[:space:]])\*([,[:space:]]|$)/) n++
  while (match(v, /Bash\([^)]*\)/)) {
    inner = substr(v, RSTART + 5, RLENGTH - 6); v = substr(v, RSTART + RLENGTH)
    if (inner ~ /\*/ && inner !~ /^((bash|sh)[[:space:]]+)?\$\{CLAUDE_SKILL_DIR\}\//) n++
  }
  return n }
FNR == 1 { if (NR > 1) print f ":" c; f = FILENAME; c = 0; key = ""; sub(/^\357\273\277/, ""); fm = ($0 ~ /^---[[:space:]]*$/); if (fm) next }
fm && /^---[[:space:]]*$/ { fm = 0; next }
fm {
  if ($0 ~ /^[A-Za-z]/) { key = $0; sub(/:.*/, "", key) }
  if ($0 ~ /^(hooks|mcpServers):/) c++
  if ($0 ~ /^permissionMode:/) { v = $0; sub(/^permissionMode:/, "", v); gsub(/["\047[:space:]]/, "", v)
    if (v != "" && v != "default" && v != "plan" && v != "manual") c++ }
  if (key == "allowed-tools") { v = $0; sub(/^allowed-tools:/, "", v); c += tools(v) }
}
/(^|[[:space:]])!`[^`]+`/ { c++ }
END { if (NR > 0) print f ":" c }'
fm_counts(){ awk "$FM_AWK" "$@" 2>/dev/null; return 0; }   # `path:count` per non-empty file, in the order given

FAIL=0; N=0
# The score ranks; the SEVERITY decides. A single HIGH costs 10 points and lands on exactly 90 — the SAFE line —
# so one credential-exfil line or one prompt-injection directive used to pass as safe on arithmetic alone. That
# is the wrong way round: the score exists to order a review queue, not to let a high-severity hit through it.
# So severity floors the verdict — any CRIT is DANGER, any HIGH is never SAFE — and the number still ranks what
# is left. (Measured: Crewforth's own 59 payload files carry no CRIT or HIGH at all, lowest score 99.)
verdict(){   # $1 = score, $2 = crit count, $3 = high count
  if [ "${2:-0}" -gt 0 ]; then echo DANGER; return; fi
  if [ "${3:-0}" -gt 0 ]; then [ "$1" -ge 70 ] && echo REVIEW || echo DANGER; return; fi
  if [ "$1" -ge 90 ]; then echo SAFE; elif [ "$1" -ge 70 ]; then echo REVIEW; else echo DANGER; fi; }

# One grep PER SEVERITY over ALL files, not four greps per file.
#
# Measured on a user's Windows machine: scanning 64 files took 8m07s — user 12.6s, sys 2m46s. The regex work is
# not the cost; process creation is. Git Bash has no real fork, so every spawn is a CreateProcess plus MSYS
# emulation plus an antivirus scan of the binary, and 64 files × 4 greps = 256 of them. adopt.sh calls this on
# every refresh, which is where most of a "the update is hung" report actually went.
#
# grep accepts many files at once and `-cH` prints `path:count` for each, including zeros — so the same regex
# engine, the same `-i` semantics and the same per-file line counts come back in 4 processes instead of 256.
# Deliberately NOT rewritten in awk: these patterns carry intervals and alternations whose behaviour would have
# to be re-proved against a different engine, and the win here is process count, not matching speed.
counts_of(){   # $1 = pattern, $2 = output file. `path:count` per input file, in the order given.
  grep -cHiE "$1" -- "${FILES[@]}" > "$2" 2>/dev/null
  return 0     # grep exits 1 when nothing matched anywhere; that is a normal result, not an error
}

# Sets the named array AND the global RC_N. Deliberately not "$(read_counts …)": command substitution runs in a
# SUBSHELL, so the array assignments would be discarded and every file would score a spotless 100. That is exactly
# what the first version did — and the output diff against the old implementation is what caught it.
read_counts(){ # $1 = grep -cH output file, $2 = array name
  local line i=0
  while IFS= read -r line; do
    # split from the RIGHT: a path may contain ':' (a Windows drive letter), a count never does
    eval "$2[$i]=\"\${line##*:}\""
    i=$((i+1))
  done < "$1"
  RC_N=$i
}

emit(){        # prints one line per file, in FILES order, from the four count arrays
  local f c h m l score v i=0
  while [ "$i" -lt "${#FILES[@]}" ]; do
    f="${FILES[$i]}"
    c="${CNT_C[$i]:-0}"; h="${CNT_H[$i]:-0}"; m="${CNT_M[$i]:-0}"; l="${CNT_L[$i]:-0}"
    report "$f" "$c" "$h" "${CNT_I[$i]:-0}" "${CNT_F[$i]:-0}" "$m" "$l"
    i=$((i+1))
  done
}

# One file's line. Invisible text and frontmatter requests score as HIGH and are named beside the counts: the reader
# cannot see the first in an editor, and should not have to guess which header line the second is.
report(){      # $1 file, $2 crit, $3 high, $4 invisible, $5 frontmatter, $6 med, $7 low
  local f="$1" c="$2" h=$(( $3 + $4 + $5 )) m="$6" l="$7" score v x=""
  [ "$4" -gt 0 ] && x="$x · invisible characters: $4"
  [ "$5" -gt 0 ] && x="$x · frontmatter requests: $5"
  score=$((100 - c*20 - h*10 - m*3 - l*1)); [ "$score" -lt 0 ] && score=0
  v="$(verdict "$score" "$c" "$h")"
  N=$((N+1))
  case "$v" in
    SAFE)   printf '  ✅ %-3s %s\n' "$score" "$f" ;;
    REVIEW) printf '  ⚠️  %-3s %s  (crit:%s high:%s med:%s low:%s%s) — REVIEW\n' "$score" "$f" "$c" "$h" "$m" "$l" "$x"; FAIL=1 ;;
    DANGER) printf '  ❌ %-3s %s  (crit:%s high:%s med:%s low:%s%s) — DANGER\n' "$score" "$f" "$c" "$h" "$m" "$l" "$x"; FAIL=1 ;;
  esac
}

# A single file keeps the old path: grep prints a bare count with one argument, so the batch parser would have to
# special-case it anyway, and one file means one process either way.
scan_file(){
  local f="$1"
  local c h m l iv fm
  # grep -c prints the count (0 on no match) and exits 1 on no match; that non-zero exit is fine here (no set -e),
  # and a `|| echo 0` would DOUBLE the printed 0 and break the arithmetic — so don't add one.
  c=$(grep -icE "$CRIT" "$f" 2>/dev/null); h=$(grep -icE "$HIGH" "$f" 2>/dev/null)
  m=$(grep -icE "$MED"  "$f" 2>/dev/null); l=$(grep -icE "$LOW"  "$f" 2>/dev/null)
  iv=$(grep -cE "$INVIS" "$f" 2>/dev/null); fm=$(fm_counts "$f"); fm="${fm##*:}"
  report "$f" "${c:-0}" "${h:-0}" "${iv:-0}" "${fm:-0}" "${m:-0}" "${l:-0}"
}

echo "== skill/agent security scan: $TARGET =="
if [ -f "$TARGET" ]; then
  scan_file "$TARGET"
elif [ -d "$TARGET" ]; then
  # Skill/agent definition files only (markdown). Skip Crewforth's own crew- agents (trusted, not third-party).
  FILES=()
  while IFS= read -r f; do
    case "$f" in agents/crew-*.md|*/agents/crew-*.md) continue ;; esac   # kit agents only — a skill dir named crew-* is still scanned
    FILES+=("$f")
  done < <(find "$TARGET" \( -name 'SKILL.md' -o -name '*.md' \) -path '*/skills/*' -o -path '*/agents/*' -name '*.md' 2>/dev/null | sort -u)
  # A skill directory with no SKILL.md is invisible to the scan above — the loop only ever sees files, so a
  # folder carrying scripts and references but no manifest was scanned file by file (or not at all) and never
  # named as odd. It is also the shape a component takes when it is trying not to look like a component.
  # Globs, not `find`: `-depth 2` means "process contents first" to GNU find and takes no argument, so the
  # BSD spelling that works on macOS is a syntax error on Linux and in Git Bash — i.e. on two of the three
  # platforms Crewforth ships to. Globbing is also fork-free, which this scanner cares about (see the cost note).
  for d in "$TARGET"/skills/*/ "$TARGET"/*/skills/*/; do
    [ -d "$d" ] || continue                       # an unmatched glob expands to itself
    [ -f "${d}SKILL.md" ] && continue
    printf '  ⚠️  ---  %s  (no SKILL.md) — REVIEW: a skill directory without its manifest\n' "${d%/}"
    FAIL=1; N=$((N+1))
  done
  if [ "${#FILES[@]}" -le 1 ]; then
    [ "${#FILES[@]}" -eq 1 ] && scan_file "${FILES[0]}"
  else
    ST="$(mktemp -d)"
    counts_of "$CRIT" "$ST/c"; counts_of "$HIGH" "$ST/h"
    counts_of "$MED"  "$ST/m"; counts_of "$LOW"  "$ST/l"
    grep -cHE "$INVIS" -- "${FILES[@]}" > "$ST/i" 2>/dev/null; fm_counts "${FILES[@]}" > "$ST/f"
    read_counts "$ST/c" CNT_C; NC=$RC_N;  read_counts "$ST/h" CNT_H; NH=$RC_N
    read_counts "$ST/m" CNT_M; NM=$RC_N;  read_counts "$ST/l" CNT_L; NL=$RC_N
    read_counts "$ST/i" CNT_I; NI=$RC_N;  read_counts "$ST/f" CNT_F; NF=$RC_N
    rm -rf "$ST"
    # If grep skipped a file (unreadable, vanished mid-run) the rows no longer line up with FILES, and a silently
    # misaligned count would score the wrong file. Fall back to the per-file path rather than report a guess. awk
    # prints nothing for an empty file, so one empty file sends the whole run down that path: correct, only slower.
    if [ "$NC" = "${#FILES[@]}" ] && [ "$NH" = "$NC" ] && [ "$NM" = "$NC" ] && [ "$NL" = "$NC" ] && [ "$NI" = "$NC" ] && [ "$NF" = "$NC" ]; then
      emit
    else
      for f in "${FILES[@]}"; do scan_file "$f"; done
    fi
  fi
else
  echo "  (nothing to scan at '$TARGET')"; exit 3
fi

echo "---"
if [ "$N" -eq 0 ]; then echo "scan: nothing scanned"; exit 3; fi
if [ "$FAIL" -eq 0 ]; then echo "SCAN: all $N file(s) SAFE ✅"; exit 0
else echo "SCAN: review the flagged file(s) above ⚠️  (heuristic — security-education skills can score low by design)"; exit 1; fi
