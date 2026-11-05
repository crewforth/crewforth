#!/usr/bin/env bash
# PreCompact hook — just before the context is compacted, write down the state of the work in a few lines, so the
# session that comes back after the compaction is told it (session-rehydrate.sh reads it on SessionStart, source
# compact). A compaction summary is the model's own retelling; this is what the files and the gates say.
#
# What it writes, at most ~2 KB: the branch, the uncommitted files (five named, the rest counted), the last refusal in
# the gate log, how many findings each document under .crewforth/ holds, and whether a handover
# (docs/SESSION_STATE.md) is there. With the session id and the trigger, so a snapshot is only read back into the
# session that wrote it.
#
# Where: inside the repository's git directory (crewforth-session-snapshot.json), so it is never committed even in a
# project that tracks .claude/; outside a repository, .claude/state/session-snapshot.json.
#
# NEVER BLOCKS. PreCompact exit 2 blocks the compaction (docs: hooks, PreCompact), and blocking an automatic one at
# the context limit fails the request that needed it. Every path here ends in exit 0, and nothing is printed: a
# PreCompact hook's output does not reach the summary.
set -u
IN="$(cat 2>/dev/null || true)"
_here="${BASH_SOURCE%[/\\]*}"; [ "$_here" = "${BASH_SOURCE}" ] && _here=.
LIB="$_here/../eval/lib"

ROOT="${CLAUDE_PROJECT_DIR:-}"
[ -n "$ROOT" ] || ROOT="$(printf '%s' "$IN" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
[ -n "$ROOT" ] || ROOT="$PWD"
ROOT="${ROOT//\\\\//}"; ROOT="${ROOT//\\//}"
cd "$ROOT" 2>/dev/null || exit 0

field(){ local v="${IN#*\"$1\"}"; [ "$v" = "$IN" ] && return 1; v="${v#*:}"; v="${v#"${v%%[![:space:]]*}"}"; case "$v" in \"*) v="${v#\"}"; printf '%s' "${v%%\"*}" ;; *) printf '%s' "${v%%[,\}]*}" ;; esac; }
SID="$(field session_id)" || SID=""
TRIG="$(field trigger)" || TRIG=""
case "$SID" in ''|*[!A-Za-z0-9._-]*) exit 0 ;; esac   # a snapshot no session can claim is not written

# ---- what the files and the gates say ----
LINES=()
GD=""
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  GD="$(git rev-parse --absolute-git-dir 2>/dev/null)" || GD=""
  BR="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || BR=""
  [ -n "$BR" ] && LINES+=("branch $BR")
  # quotePath off: a name in Turkish (or any non-ASCII) is given as written, not as octal escapes (seen on Windows).
  CH="$(git -c core.fsmonitor= -c core.quotePath=false status --porcelain 2>/dev/null)" || CH=""
  if [ -n "$CH" ]; then
    n=0; names=""
    while IFS= read -r l; do n=$((n+1)); [ "$n" -le 5 ] && names="${names:+$names, }${l:3}"; done <<< "$CH"
    LINES+=("$n uncommitted file(s): $names$([ "$n" -gt 5 ] && printf ', and %d more' $((n-5)))")
  else LINES+=("nothing uncommitted"); fi
fi
if [ -f "$LIB/gate-log.sh" ]; then
  . "$LIB/gate-log.sh"; crew_gate_log_read
  if [ -n "${_CREW_GL:-}" ] && [ -f "$_CREW_GL" ]; then
    last=""; while IFS= read -r l; do case "$l" in BLOCK$'\t'*) last="$l" ;; esac; done < "$_CREW_GL"
    if [ -n "$last" ]; then IFS=$'\t' read -r _ rule why _ <<< "$last"; LINES+=("the last refusal in the gate log: ${rule} ${why:0:120}"); fi
  fi
fi
fnd=""
for f in .crewforth/*.json; do
  [ -f "$f" ] || continue
  c=0; while IFS= read -r l; do case "$l" in *'"rule": '*) c=$((c+1)) ;; esac; done < "$f"
  [ "$c" -gt 0 ] && { b="${f##*/}"; fnd="${fnd:+$fnd, }${b%.json} $c"; }
done
[ -n "$fnd" ] && LINES+=("findings on record: $fnd")
[ -s docs/SESSION_STATE.md ] && LINES+=("a handover is at docs/SESSION_STATE.md")

# ---- what the transcript says: the user's own words, and the skills in use ----
# A compaction summary retells the task, and a retelling can soften a hard "do not". So the first prompt and the
# last three are kept as the user typed them, each cut at about 300 characters. And a skill's text is not always
# brought back after a compaction (measured on local transcripts: 3 of 12 compactions that followed a Skill call
# re-attached nothing), so the skill names are kept too. ONE grep over the transcript; the rest is builtins.
# A prompt line in a transcript is already a JSON string, so it is stored as it is and never re-escaped; a cut
# that splits an escape or a multibyte character is trimmed back to a whole one. Skipped: a prompt that opens with
# a tag (command output, a notification, pasted content), a meta, sidechain or compaction-summary record, and any
# prompt a secret pattern matches. <private>…</private> becomes [redacted], as the handover does.
clip(){ local LC_ALL=C p="$1" t k c n o=""
  # Left to right, one pass: each <private> to the NEXT </private> becomes [redacted]; an unclosed one hides the rest.
  # (Cutting at the first <private> and the first </private> separately loops forever on "</private> … <private>x</private>".)
  while case "$p" in *'<private>'*) true ;; *) false ;; esac; do
    o="$o${p%%<private>*}[redacted]"; p="${p#*<private>}"
    case "$p" in *'</private>'*) p="${p#*</private>}" ;; *) p="" ;; esac
  done; p="$o$p"
  if [ "${#p}" -gt 300 ]; then
    p="${p:0:300}"
    case "$p" in *\\u|*\\u?|*\\u??|*\\u???) p="${p%\\u*}" ;; esac
    t="${p##*[!\\]}"; [ $(( ${#t} % 2 )) = 1 ] && p="${p%\\}"
    # A UTF-8 character cut in half: walk back over continuation bytes to the lead byte, and drop the
    # sequence only if it is shorter than its lead byte says (C locale: these compare as bytes).
    k=0
    while [ "$k" -lt 4 ] && [ "$k" -lt "${#p}" ]; do
      c="${p: -$((k+1)):1}"
      [[ "$c" < $'\x80' ]] && break
      if [[ "$c" > $'\xbf' ]]; then
        n=2; [[ "$c" > $'\xdf' ]] && n=3; [[ "$c" > $'\xef' ]] && n=4
        [ $((k+1)) -lt "$n" ] && p="${p:0:$((${#p}-k-1))}"
        break
      fi
      k=$((k+1))
    done
    p="$p ...(cut)"
  fi
  CLIP="$p"; }
TP="$(field transcript_path)" || TP=""
TP="${TP//\\\\//}"; TP="${TP//\\//}"
SKILLS=""; PROMPTS=""
if [ -n "$TP" ] && [ -f "$TP" ]; then
  first=""; p1=""; p2=""; p3=""; sk=" "   # " a b ": a name moves to the end each time it is called again
  while IFS= read -r l; do
    case "$l" in
      *'"name":"Skill","input":{"skill":"'*)
        s="${l#*\"name\":\"Skill\",\"input\":\{\"skill\":\"}"; s="${s%%\"*}"
        case "$s" in ''|*[!A-Za-z0-9:._-]*) continue ;; esac
        sk="${sk// $s / }$s " ;;
      *'"isMeta":true'*|*'"isSidechain":true'*|*'"isCompactSummary":true'*) ;;
      *'"type":"user","message":{"role":"user","content":"'*)
        v="${l#*\"type\":\"user\",\"message\":\{\"role\":\"user\",\"content\":\"}"
        # Only the first ~300 bytes are kept, so a pasted megabyte is cut to 1200 first: bash's pattern removals
        # on the whole string grow faster than its length (measured: 1 MB took 8 s, 2 MB passed the 30 s timeout).
        # A prompt longer than that keeps no end marker and is cut where clip cuts it.
        long=0; [ "${#v}" -gt 1200 ] && { v="${v:0:1200}"; long=1; }
        # The string ends where the message object closes: before more record fields, or at the line's end.
        case "$v" in *'"},"'*) v="${v%%\"\},\"*}"; long=0 ;; *'"}}'*) v="${v%\"\}\}*}"; long=0 ;; *) [ "$long" = 1 ] || continue ;; esac
        case "$v" in ''|'<'*|'[Request interrupted'*) continue ;; esac
        if [ "$long" = 0 ]; then t="${v##*[!\\]}"; [ $(( ${#t} % 2 )) = 1 ] && continue; fi   # the end was an escaped quote: not a whole prompt
        [ -z "$first" ] && { first="$v"; continue; }
        p1="$p2"; p2="$p3"; p3="$v" ;;
    esac
  done < <(LC_ALL=C grep -E '"name":"Skill","input":\{"skill":"|"type":"user","message":\{"role":"user","content":"[^<]' "$TP" 2>/dev/null)
  sk="${sk# }"; sk="${sk% }"; SKILLS="${sk// /, }"
  # The four candidates go through the secret patterns in ONE grep; a line it names is dropped whole.
  BL="$_here/secret-blocklist.txt"; keep=(); bad=" "; i=0
  # Fails CLOSED: no pattern file, or a grep that errors (rc 2), keeps no prompt at all.
  hits="$(printf '%s\n' "$first" "$p1" "$p2" "$p3" | LC_ALL=C grep -nE -f <(LC_ALL=C grep -vE '^#|^$' "$BL" 2>/dev/null) 2>/dev/null)"; rc=$?
  if [ ! -s "$BL" ] || [ "$rc" -gt 1 ]; then bad=" 1 2 3 4 "
  else while IFS=: read -r n _; do bad="$bad$n "; done <<< "$hits"; fi
  for v in "$first" "$p1" "$p2" "$p3"; do
    i=$((i+1))
    [ -n "$v" ] || continue
    case "$bad" in *" $i "*) continue ;; esac
    clip "$v"; keep+=("$CLIP")
  done
  for v in "${keep[@]+"${keep[@]}"}"; do PROMPTS="${PROMPTS:+$PROMPTS\\n}- $v"; done
fi
[ "${#LINES[@]}" -gt 0 ] || [ -n "$SKILLS$PROMPTS" ] || exit 0

SUM=""; for l in "${LINES[@]+"${LINES[@]}"}"; do SUM="${SUM:+$SUM; }$l"; done
# Cut at the cap, and say so: a summary that just stops reads as complete.
[ "${#SUM}" -gt 1800 ] && SUM="${SUM:0:1780} ...(truncated)"

# ---- where it goes ----
if [ -n "$GD" ] && [ -d "$GD" ]; then OUT="$GD/crewforth-session-snapshot.json"
else mkdir -p .claude/state 2>/dev/null || exit 0; OUT=".claude/state/session-snapshot.json"; fi
if [ "${BASH_VERSINFO[0]}" -ge 5 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then printf -v NOW '%(%Y-%m-%dT%H:%M:%SZ)T' -1; else NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; fi
ESC="$(printf '%s\n' "$SUM" | LC_ALL=C awk -f "$LIB/json-string.awk" 2>/dev/null)" || exit 0
printf '{"session_id":"%s","trigger":"%s","at":"%s","skills":"%s","prompts":"%s","summary":"%s"}\n' "$SID" "${TRIG//[!a-z]/}" "$NOW" "$SKILLS" "$PROMPTS" "$ESC" > "$OUT.$$" 2>/dev/null && mv -f "$OUT.$$" "$OUT" 2>/dev/null
rm -f "$OUT.$$" 2>/dev/null
exit 0
