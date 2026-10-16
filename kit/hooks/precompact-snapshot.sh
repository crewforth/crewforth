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
  CH="$(git status --porcelain 2>/dev/null)" || CH=""
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
[ "${#LINES[@]}" -gt 0 ] || exit 0

SUM=""; for l in "${LINES[@]}"; do SUM="${SUM:+$SUM; }$l"; done
SUM="${SUM:0:1800}"

# ---- where it goes ----
if [ -n "$GD" ] && [ -d "$GD" ]; then OUT="$GD/crewforth-session-snapshot.json"
else mkdir -p .claude/state 2>/dev/null || exit 0; OUT=".claude/state/session-snapshot.json"; fi
if [ "${BASH_VERSINFO[0]}" -ge 5 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then printf -v NOW '%(%Y-%m-%dT%H:%M:%SZ)T' -1; else NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; fi
ESC="$(printf '%s\n' "$SUM" | LC_ALL=C awk -f "$LIB/json-string.awk" 2>/dev/null)" || exit 0
printf '{"session_id":"%s","trigger":"%s","at":"%s","summary":"%s"}\n' "$SID" "${TRIG//[!a-z]/}" "$NOW" "$ESC" > "$OUT.$$" 2>/dev/null && mv -f "$OUT.$$" "$OUT" 2>/dev/null
rm -f "$OUT.$$" 2>/dev/null
exit 0
