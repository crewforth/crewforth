#!/usr/bin/env bash
# Session evidence — what ACTUALLY happened this session, measured from the transcript instead of recalled.
# A retrospective that asks the model what it did is interviewing the least reliable witness in the room: it
# reconstructs a tidy story from a context that has already been summarised, and the turns where it span on a
# failing approach are exactly the ones it remembers least. This reads the record instead.
#
# Consumers: the `reflect` skill runs it BEFORE writing findings, and `handoff` runs it when summarising a
# session. It is NOT wired to a hook event — nothing here is worth a per-turn token tax.
#
# Usage:
#   bash session-stats.sh [transcript.jsonl]           # no arg -> auto-find from pwd (same rule as context-usage.sh)
#   bash session-stats.sh --raw [transcript.jsonl]     # key=value lines instead of the report (tests/scripting)
#   echo '{"transcript_path":"..."}' | bash session-stats.sh
#
# Thresholds (env overrides): CREW_RUNAWAY_TOOLS=25 · CREW_DUP_MIN=2 · CREW_ERR_PCT=15 · CREW_INTERRUPT_MIN=3
#
# ONE awk engine, no jq path — deliberate. context-usage.sh carries two engines because it reads a nested usage
# object, and they drifted once (the sidechain bug) with a wrong number, not silence, as the result. Every signal
# here is a flat per-line text match, so a second engine would buy nothing and add that same failure mode back.
set -uo pipefail
RAW=0
case "${1:-}" in --raw) RAW=1; shift ;; esac
TR="${1:-}"

if [ -z "$TR" ] && [ ! -t 0 ]; then
  IN="$(cat 2>/dev/null || true)"
  [ -n "$IN" ] && TR="$(printf '%s' "$IN" | sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
fi
# ---- CREW-TRANSCRIPT-DIR (kept byte-identical in context-usage.sh and session-stats.sh; smoke-test §6i3 pins it)
# Claude Code stores a session under $HOME/.claude/projects/<cwd encoded as a directory name>. Reproducing that
# encoding is the ONLY way a by-hand call (no hook payload on stdin) can find its own transcript.
crew_project_dirs(){   # candidate directory names for the current cwd, best first, one per line
  local w p
  # Windows first. Claude Code sees the NATIVE cwd (C:\repo\app) while Git Bash's `pwd` reports /c/repo/app, so
  # the drive letter never matched and the by-hand call could not resolve a transcript on Windows AT ALL — the
  # same "transcript not found" was reported from that machine three separate times before the cause was found.
  # `pwd -W` is the MSYS builtin that returns the native form; elsewhere it just fails and is discarded.
  w="$(pwd -W 2>/dev/null || true)"
  # The encoder folds : \ / . AND _ to '-'. The underscore is the one that hides: a project named `report_api`
  # lands in `...-report-api`, so folding only slashes and dots misses every path containing an underscore — on
  # every platform, not just Windows.
  for p in "$w" "$(pwd)"; do
    [ -n "$p" ] && printf '%s\n' "$(printf '%s' "$p" | sed 's#[:\\/._]#-#g')"
  done
  # Legacy shapes, kept so a directory written by an older client still resolves.
  printf '%s\n' "$(pwd | sed 's#[/.]#-#g')" "$(pwd | sed 's#/#-#g')"
}
if [ -z "$TR" ]; then
  while IFS= read -r esc; do
    [ -n "$esc" ] || continue
    cand="$(ls -t "$HOME/.claude/projects/$esc"/*.jsonl 2>/dev/null | head -1)"
    [ -n "$cand" ] && { TR="$cand"; break; }
  done <<CREWEOF
$(crew_project_dirs)
CREWEOF
fi
# ---- /CREW-TRANSCRIPT-DIR
[ -n "$TR" ] && [ -f "$TR" ] || { echo "session-stats: transcript not found (pass an arg or use hook stdin)" >&2; exit 1; }

# Whole-file scan, unlike context-usage.sh's byte-bounded tail: that one runs on EVERY turn inside a hook
# timeout and only needs the last record, this one runs on demand and every count is a whole-session count.
#
# LC_ALL=C is load-bearing, not tidiness. Under a UTF-8 locale BSD awk aborts with "illegal byte sequence" the
# moment a character class meets a multi-byte character — and a transcript of a session held in Turkish is made
# of them, so the tool would die on exactly the sessions it was written for. Under C every regex is byte-wise,
# tolower() folds ASCII only (which is all the duplicate key needs), and non-ASCII bytes pass through untouched.
# THE TRIGGER MAP, read once: every `Trigger phrases:` line of the installed agents and skills, and which agents apply
# which skill (`skills: [..]`). One awk over the files, so the cost does not grow with the component count.
# `T <name> <phrase>` and `O <skill> <agent>` lines; empty when nothing is installed, and then trigger_missed is 0.
TRIGF=""; _CLD="${CLAUDE_PROJECT_DIR:-.}"; _CLD="${_CLD//\\//}/.claude"
if [ -d "$_CLD/agents" ] || [ -d "$_CLD/skills" ]; then
  TRIGF="$(mktemp 2>/dev/null)" || TRIGF=""
  [ -n "$TRIGF" ] && LC_ALL=C awk '
    FNR == 1 { n = FILENAME; if (n ~ /\/SKILL\.md$/) { sub(/\/SKILL\.md$/, "", n); sub(/.*\//, "", n) } else { sub(/.*\//, "", n); sub(/\.md$/, "", n) } }
    /^Trigger phrases:/ { s = $0; while (match(s, /"[^"]+"/)) { print "T\t" n "\t" tolower(substr(s, RSTART + 1, RLENGTH - 2)); s = substr(s, RSTART + RLENGTH) } }
    /^  skills: *\[/ { s = $0; sub(/^[^[]*\[/, "", s); sub(/\].*/, "", s); k = split(s, a, /, */); for (i = 1; i <= k; i++) if (a[i] != "") print "O\t" a[i] "\t" n }
  ' "$_CLD"/agents/*.md "$_CLD"/skills/*/SKILL.md > "$TRIGF" 2>/dev/null
fi
STATS="$(LC_ALL=C awk -v TRIGF="$TRIGF" '
  BEGIN { if (TRIGF != "") while ((getline l < TRIGF) > 0) { split(l, f, "\t")
            if (f[1] == "T") { nt++; tn[nt] = f[2]; tp[nt] = f[3] } else if (f[1] == "O") own[f[2]] = own[f[2]] " " f[3] } }
  # A subagent has its own window and its own story; counting its tool calls as the main thread\x27s would make
  # every delegating session look like it was spinning.
  /"isSidechain": *true/ { next }

  # --- compaction: the one event that silently destroys session state -------------------------------------
  /"subtype": *"compact_boundary"/ {
    comp++
    if ($0 ~ /"trigger": *"auto"/) autocomp++
    if (match($0, /"preTokens": *[0-9]+/))  { s=substr($0,RSTART,RLENGTH); gsub(/[^0-9]/,"",s); pre=s }
    if (match($0, /"postTokens": *[0-9]+/)) { s=substr($0,RSTART,RLENGTH); gsub(/[^0-9]/,"",s); post=s }
    next
  }

  # --- a REFUSED call is not a failed approach, and counting it as one is how this report cried wolf -------
  # `is_error: true` is set for two different things: a tool that RAN and failed, and a call that was never
  # executed because something refused it. The second is a decision ABOUT the call, not an outcome OF it, and
  # the approach the model chose may have been perfectly good. Lumping them together made the report accuse the model
  # of thrashing on a machine where refusals are simply more frequent — a field session produced a "runaway
  # loop" warning whose counted errors were mostly denials. A warning that fires on the innocent is worse
  # than none: the rule in Crewforth is that an ignored warning teaches nothing.
  #
  # MEASURED before it was written, over 14 real transcripts, 101 is_error results:
  #   69.3%  a genuine failure — the approach did not work
  #   18.8%  protocol: read-before-write, "string to replace not found". The tool RAN and rejected the input,
  #          so these stay counted: repeating one is exactly the thrash this report should see.
  #   11.9%  REFUSED: the harness blocked the command shape (6.9%), a kit gate blocked it (3.0%), the user
  #          declined (2.0%). None of them ran.
  # The field report describes a much larger refusal share on a Windows project; that mix is not measured here
  # and this split does not depend on which one is typical — a refusal is not a failure at any ratio.
  function refusals(line,   c, r) {
    c = line; r  = gsub(/want to proceed with this tool use/, "", c)
    c = line; r += gsub(/<tool_use_error>Blocked:/, "", c)
    c = line; r += gsub(/requested permissions/, "", c)
    # A PreToolUse hook that blocks (exit 2) and one that errors (exit 1) both surface as "hook error" here.
    # Neither one is a failing approach: the first is the gate doing its job, the second is a defect in Crewforth
    # Both belong outside the error rate, and the second is visible in the gate log instead.
    c = line; r += gsub(/PreToolUse:[^"]*hook error/, "", c)
    return r
  }

  # --- interrupts: anchored on the content block, never on raw text --------------------------------------
  # The bare phrase also appears inside tool inputs (a grep for it, this very comment) — matching that would
  # count the session\x27s own tooling as user frustration. The `"text":"[` prefix only occurs in a real block.
  {
    c=$0; n=gsub(/"text": *"\[Request interrupted by user/, "", c); if (n>0) ints+=n
  }

  # --- re-fetch / error loops: the SAME look taken again and again inside one prompt ------------------------
  # A bounded look (`sed -n 1,50p`, `| head -50`, a Read with a limit) that hid what was needed gets retaken
  # with a wider window — 50, then 100, then 200 — and each retake re-pays the whole output. The same command
  # failing over and over is the other half of that shape. The runaway warning cannot see either: it needs 25
  # calls, and a re-fetch loop is three. So a call is reduced to a KEY that collapses the window: tool name +
  # Bash command (or Read file_path — offset/limit never enter it). In the command a `| head`/`| tail` pipe is
  # dropped and only the WINDOW numbers become N — `sed -n A,Bp`, `head -N`, `tail -N`, `-n N`, `-c N`,
  # `NR<=N` — so `sed -n 1,50p f` and `sed -n 1,200p f` meet. Every other number stays. The first cut folded
  # every free-standing number, and over all 874 local transcripts its only re-fetch hit was a false alarm:
  # `adb shell input tap 540 1100; … | head -6` and `tap 763 205; … | head -12` — two different taps.
  #
  # A RE-FETCH also needs a WIDER look: some later window at the key must contain an earlier BOUNDED one and
  # reach further. look_key sets LK_W (the raw look, so identical retakes dedupe), LK_B (bounded at all) and a
  # window in three independent dimensions: a line range LK_LO..LK_HI (Read offset/limit, `sed -n A,Bp`), the
  # LAST `head N` (LK_H) and the LAST `tail N` (LK_T) in the command. A missing dimension is unbounded, so the
  # plain command widens every bounded variant of it. "Wider" = no dimension narrower, at least one wider. The
  # dimensions are separate because a real command carries several: `… | tail -1; sed -n 1,25p f | head -12`
  # widened to `head -200` kept its sed range and its `tail -1` — the first cut read ONE bound (the sed range,
  # first match) and missed exactly that planted loop. Earlier cuts were run on 20 real transcripts before
  # shipping, and each of their hits was a false alarm the conditions above now exclude: a script polled with
  # `sleep N` and a screenshot re-read after each regeneration (the same look on purpose, no window); a large
  # file PAGED in disjoint ranges (offset 48, 226, 440 · sed -n 780,812p then 1080,1112p); and, with "overlap"
  # as the rule, a region re-read NARROWER (offset 30 limit 170, then 44 limit 150).
  # An error loop needs no window: failing three times is the signal on its own.
  function last_count(s, re,   w, v) {          # the number in the LAST match of re in s; 1e9 when none
    v = 1e9
    while (match(s, re)) {
      w = substr(s, RSTART + 4, RLENGTH - 4); gsub(/[^0-9]/, "", w); v = w + 0; LK_B = 1
      s = substr(s, RSTART + RLENGTH)
    }
    return v
  }
  function look_key(seg,   nm, s, w, a) {
    LK_W = ""; LK_LO = 1; LK_HI = 1e9; LK_H = 1e9; LK_T = 1e9; LK_B = 0
    if (!match(seg, /"name": *"[^"]*"/)) return ""
    nm = substr(seg, RSTART, RLENGTH); sub(/^"name": *"/, "", nm); sub(/"$/, "", nm)
    if (nm == "Read") {
      if (!match(seg, /"file_path": *"[^"]*"/)) return ""
      s = "Read|" substr(seg, RSTART, RLENGTH); LK_W = "all"
      if (match(seg, /"offset": *[0-9]+/)) { w = substr(seg, RSTART, RLENGTH); gsub(/[^0-9]/, "", w); LK_LO = w + 0; LK_B = 1 }
      if (match(seg, /"limit": *[0-9]+/))  { w = substr(seg, RSTART, RLENGTH); gsub(/[^0-9]/, "", w); LK_HI = LK_LO + w - 1; LK_B = 1 }
      if (LK_B) LK_W = LK_LO "-" LK_HI
      return s
    }
    if (nm != "Bash") return ""
    if (!match(seg, /"command": *"([^"\\]|\\.)*"/)) return ""
    s = substr(seg, RSTART, RLENGTH); s = substr(s, 1, 400); LK_W = s
    if (match(s, /sed +-n +[^0-9 ]*[0-9]+,[0-9]+p/)) {
      w = substr(s, RSTART, RLENGTH); sub(/^sed +-n +[^0-9 ]*/, "", w); sub(/p$/, "", w); split(w, a, ",")
      LK_LO = a[1] + 0; LK_HI = a[2] + 0; LK_B = 1
    }
    LK_H = last_count(s, "head +(-[nc] *)?-?[0-9]+")
    LK_T = last_count(s, "tail +(-[nc] *)?-?[0-9]+")
    gsub(/ *\| *(head|tail)( +-[nc])?( *[-+]?[0-9]+)?/, "", s)
    gsub(/[0-9]+,[0-9]+p/, "N,Np", s); gsub(/head +-[0-9]+/, "head -N", s); gsub(/tail +-[0-9]+/, "tail -N", s)
    gsub(/-n *[-+]?[0-9]+/, "-n N", s); gsub(/-c *[-+]?[0-9]+/, "-c N", s); gsub(/NR *[<>=]+ *[0-9]+/, "NR<=N", s)
    gsub(/[ \t]+/, " ", s)
    return "Bash|" s
  }
  # The verdict is per prompt cycle: three looks spread over three prompts are three questions, not a loop.
  # Hits exclude REFUSED calls (refusals() semantics: they never ran, so they neither looked nor failed). The
  # key is an errloop when all but at most the last hit failed — the loop that finally got through still spun.
  function close_looks(   k, n, i, h, f, ok, ids) {
    for (k in lk_ids) {
      n = split(lk_ids[k], ids, " "); h = 0; f = 0; ok = 0
      for (i = 1; i <= n; i++) {
        if (st[ids[i]] == "R") continue
        h++
        # A success before the last hit ends the run of failures: pass, edit, fail, fail is two failures, not a loop.
        if (ok) ok = 2
        if (st[ids[i]] == "F") f++; else if (!ok) ok = 1
      }
      if (h >= 3) { if (f >= h - 1 && ok < 2) errloop++; else if (lk_ov[k]) refetch++ }
    }
    split("", lk_ids); split("", lk_nw); split("", lk_sw); split("", lk_ov)
    split("", lk_lo); split("", lk_hi); split("", lk_h); split("", lk_t); split("", lk_b)
  }
  # A new, different window at key k: does it WIDEN a bounded one already taken (contain it and reach further)?
  function add_window(k,   i, n) {
    if (LK_W == "" || ((k, LK_W) in lk_sw)) return
    lk_sw[k, LK_W] = 1; n = ++lk_nw[k]
    if (n > 20) return                    # a key paged 20 ways already said what it will say
    for (i = 1; i < n; i++)
      if (lk_b[k, i] && LK_LO <= lk_lo[k, i] && LK_HI >= lk_hi[k, i] && LK_H >= lk_h[k, i] && LK_T >= lk_t[k, i] &&
          (LK_LO < lk_lo[k, i] || LK_HI > lk_hi[k, i] || LK_H > lk_h[k, i] || LK_T > lk_t[k, i])) lk_ov[k] = 1
    lk_lo[k, n] = LK_LO; lk_hi[k, n] = LK_HI; lk_h[k, n] = LK_H; lk_t[k, n] = LK_T; lk_b[k, n] = LK_B
  }

  # --- assistant turns: tool calls belong to the user cycle that is currently open ------------------------
  /"type": *"assistant"/ {
    turns++
    c=$0; cur += gsub(/"type": *"tool_use"/, "", c)
    s=$0
    while (match(s, /"type": *"tool_use"/)) {
      s=substr(s, RSTART+RLENGTH); seg=s
      if (match(seg, /"type": *"tool_use"/)) seg=substr(seg, 1, RSTART-1)
      k=look_key(seg)
      if (k != "" && match(seg, /"id": *"[^"]*"/)) {
        id=substr(seg, RSTART, RLENGTH); sub(/^"id": *"/, "", id); sub(/"$/, "", id)
        lk_ids[k] = lk_ids[k] " " id
        add_window(k)
      }
    }
    # What ran this cycle (a skill loaded, an agent started, a shell command) and what was CLAIMED in the reply.
    c=$0; while (match(c, /"skill": *"[^"]*"/)) { v=substr(c, RSTART, RLENGTH); sub(/^"skill": *"/, "", v); sub(/"$/, "", v); sub(/.*:/, "", v); ranc[v]=1; c=substr(c, RSTART+RLENGTH) }
    c=$0; while (match(c, /"subagent_type": *"[^"]*"/)) { v=substr(c, RSTART, RLENGTH); sub(/^"subagent_type": *"/, "", v); sub(/"$/, "", v); sub(/.*:/, "", v); ranc[v]=1; c=substr(c, RSTART+RLENGTH) }
    if ($0 ~ /"name": *"Bash"/) curbash=1
    c=$0; while (match(c, /"type": *"text", *"text": *"([^"\\]|\\.)*"/)) { v=tolower(substr(c, RSTART, RLENGTH)); c=substr(c, RSTART+RLENGTH)
      if (v ~ /(^|[^a-z])(done|fixed|passing|all green|tests pass|works now)([^a-z]|$)/) curclaim=1 }
    c=$0; e=gsub(/"is_error": *true/, "", c)
    r=refusals($0); if (r>e) r=e          # a line cannot hold more refusals than it holds errors
    errs+=e-r; curerr+=e-r; refused+=r
    c=$0; deleg += gsub(/"name": *"Agent"/, "", c)
    next
  }

  # --- user records: a real prompt opens a new cycle; a tool_result is just the tail of this one ----------
  /"type": *"user"/ {
    c=$0; e=gsub(/"is_error": *true/, "", c)
    r=refusals($0); if (r>e) r=e
    errs+=e-r; curerr+=e-r; refused+=r
    if ($0 ~ /"type": *"tool_result"/) {
      # Link each result to its call by tool_use_id: R refused, F ran and failed, anything else succeeded.
      # Measured over 60 real transcripts: 18166 result records carried one id, 5 carried several. A record
      # with several cannot say WHICH one failed from flat text, so it is only judged when it is unambiguous
      # (every block refused, or every block a failure); otherwise its calls count as succeeded.
      c=$0; n=0
      while (match(c, /"tool_use_id": *"[^"]*"/)) {
        id=substr(c, RSTART, RLENGTH); sub(/^"tool_use_id": *"/, "", id); sub(/"$/, "", id)
        c=substr(c, RSTART+RLENGTH); n++; rid[n]=id
      }
      v=""
      if (n == 1) { if (r > 0) v="R"; else if (e > 0) v="F" }
      else if (n > 1) { if (r >= n) v="R"; else if (e - r >= n) v="F" }
      if (v != "") for (i = 1; i <= n; i++) st[rid[i]] = v
      next
    }
    # Not every user-role record is something a human typed. Slash-command invocations, their stdout, pasted
    # terminal output, image attachments, the caveat banner and the "continued from a previous conversation"
    # summary all arrive wearing the user role — and left in, they DOMINATE the duplicate report: measured on a
    # real 114-prompt session, every single "repeated prompt" was one of these. The signal described the
    # machinery and never the person. Two filters clear them:
    #   1. `"content":"` — a typed prompt is a plain string; pastes, images and attachments come as block arrays.
    #   2. a leading `<tag>` — every machinery wrapper announces itself that way (<command-name>, <bash-stdout>,
    #      <local-command-stdout>, <system-reminder>). A prompt that genuinely opens with a tag is lost to the
    #      count; that is the cheap side of the trade.
    if ($0 ~ /"isCompactSummary": *true/) next
    if (!match($0, /"content": *"/)) next
    t=substr($0, RSTART+RLENGTH); t=substr(t,1,240); lt=tolower(t)
    if (lt ~ /^<[a-z-]+>/) next
    if (lt ~ /^this session is being continued from a previous conversation/) next

    if (started) { close_cycle() } else { close_looks(); split("", ranc); curbash=0; curclaim=0 }   # pre-prompt calls are no cycle of their own
    started=1; cycles++; cur=0; curerr=0
    # Which components this prompt names by a trigger phrase (route-hint reads the same lines).
    if (nt) { p=tolower(substr($0, RSTART+RLENGTH, 2000)); for (i = 1; i <= nt; i++) if (index(p, tp[i])) cm[tn[i]]=1 }

    # Near-duplicate key: normalise hard and keep a prefix. Punctuation and escapes go, case folds, runs of
    # space collapse — but non-ASCII is LEFT ALONE, because stripping it would fold every prompt in a
    # non-Latin language onto the same key and report a session of distinct questions as one repeated one.
    if (t != "") {
      t=lt
      gsub(/\\[a-z"\\\/]/, " ", t)
      gsub(/[.,;:!?()\[\]{}<>"`*_#|=+-]/, " ", t)
      gsub(/  +/, " ", t); sub(/^ /, "", t)
      k=substr(t,1,60)
      if (length(k) >= 12) seen[k]++      # too short to judge: "ok", "devam" are not a failing prompt
    }
    next
  }

  # A high tool count alone is NOT spinning — an agentic prompt legitimately runs dozens of calls, and flagging
  # that would fire on the healthiest sessions and teach the reader to skip the whole block. What separates
  # working from spinning is that the calls keep FAILING, so both conditions must hold in the same cycle.
  function close_cycle() {
    tools += cur
    if (cur > maxtools) maxtools = cur
    if (cur >= RUNAWAY && curerr >= RUNERR) { runaway++; if (curerr > runworst) runworst = curerr }
    # A reply that says done/fixed/passing in a cycle where no shell command ran: the claim had nothing behind it.
    if (curclaim && !curbash) unbacked++
    # A component the prompt named by its trigger, where neither it nor an agent that applies it ran.
    for (n in cm) if (!(n in ranc)) { hit=0; k=split(own[n], ow, " "); for (i = 1; i <= k; i++) if (ow[i] in ranc) hit=1; if (!hit) tmissed++ }
    split("", cm); split("", ranc); curbash=0; curclaim=0
    close_looks()
  }

  END {
    if (started) close_cycle(); else close_looks()
    for (k in seen) if (seen[k] > 1) { dupdistinct++; dupextra += seen[k]-1 }
    printf "cycles=%d\nturns=%d\ntools=%d\nmaxtools=%d\nrunaway=%d\nrunaway_errors=%d\nerrors=%d\ninterrupts=%d\ndup_extra=%d\ndup_distinct=%d\ncompactions=%d\nauto_compactions=%d\npre_tokens=%d\npost_tokens=%d\ndelegations=%d\nrefused=%d\nrefetch=%d\nerrloop=%d\nclaims_unbacked=%d\ntrigger_missed=%d\n",
      cycles+0, turns+0, tools+0, maxtools+0, runaway+0, runworst+0, errs+0, ints+0, dupextra+0, dupdistinct+0, comp+0, autocomp+0, pre+0, post+0, deleg+0, refused+0, refetch+0, errloop+0, unbacked+0, tmissed+0
  }
' RUNAWAY="${CREW_RUNAWAY_TOOLS:-25}" RUNERR="${CREW_RUNAWAY_ERRORS:-3}" "$TR")"

# An awk that died (locale, a truncated file, a transcript format change) leaves this empty, and `set -u` would
# then fail deep inside the report with an unbound-variable trace. Say what happened instead.
[ -n "$TRIGF" ] && rm -f "$TRIGF"
case "$STATS" in *"cycles="*) ;; *) echo "session-stats: could not read the transcript ($TR)" >&2; exit 1 ;; esac

[ "$RAW" = 1 ] && { printf '%s\n' "$STATS"; exit 0; }

# shellcheck disable=SC2046  # each line is a bare key=value produced above, deliberately word-split into vars
eval "$(printf '%s\n' "$STATS" | sed 's/^/S_/')"

DUP_MIN="${CREW_DUP_MIN:-2}"; ERR_PCT="${CREW_ERR_PCT:-15}"; INT_MIN="${CREW_INTERRUPT_MIN:-3}"
AVG="$(LC_ALL=C awk -v t="$S_tools" -v c="$S_cycles" 'BEGIN{ if(c+0>0) printf "%.1f", t/c; else print "0" }')"
EPCT="$(LC_ALL=C awk -v e="$S_errors" -v t="$S_tools" 'BEGIN{ if(t+0>0) printf "%.0f", (e/t)*100; else print "0" }')"

echo "📊 Session evidence (measured from the transcript — not recalled)"
# Refusals are REPORTED but never warned about: a session that hit a gate twenty times is worth knowing and is
# not a defect, and the moment it counts toward the error rate the report starts accusing the model of the
# gate's work. Shown only when there were any, so a clean session's line does not grow a "0 refused".
if [ "${S_refused:-0}" -gt 0 ]; then
  echo "   $S_cycles prompt(s) · $S_tools tool call(s) · avg $AVG per prompt · ${EPCT}% tool errors · $S_refused refused (not counted as errors)"
else
  echo "   $S_cycles prompt(s) · $S_tools tool call(s) · avg $AVG per prompt · ${EPCT}% tool errors"
fi

# Findings only when a threshold is crossed. A clean line for every signal would bury the one that matters and
# train the reader to skim past the block — the failure mode of every dashboard that reports all-green.
FOUND=0
if [ "${S_runaway:-0}" -gt 0 ]; then
  echo "   ⚠️  runaway loop: $S_runaway prompt(s) ran ≥${CREW_RUNAWAY_TOOLS:-25} tool calls while failing (worst: $S_runaway_errors errors in one)."
  echo "       → an approach that needed that many failing attempts usually needed a different approach (systematic-debugging)."
  FOUND=1
fi
if [ "${S_refetch:-0}" -gt 0 ]; then
  echo "   ⚠️  re-fetch loop: $S_refetch look(s) repeated ≥3 times in one prompt, each a wider window of the same thing."
  echo "       → the first bounded look hid what was needed; redirect the full output to a file once and grep it."
  FOUND=1
fi
if [ "${S_errloop:-0}" -gt 0 ]; then
  echo "   ⚠️  error loop: $S_errloop command(s) retried ≥3 times in one prompt while failing."
  echo "       → re-running a variant of a failing call rarely changes the answer; read the error, fix the cause first."
  FOUND=1
fi
if [ "${S_claims_unbacked:-0}" -gt 0 ]; then
  echo "   ⚠️  unbacked claim: $S_claims_unbacked prompt(s) ended with done/fixed/passing and no command run in that prompt."
  echo "       → a claim of green is the output of a run; name the command and its result, or say it was not run."
  FOUND=1
fi
if [ "${S_trigger_missed:-0}" -gt 0 ]; then
  echo "   ·  $S_trigger_missed time(s) a prompt named a component by its trigger and neither it nor an agent applying it ran."
fi
if [ "${S_dup_extra:-0}" -ge "$DUP_MIN" ]; then
  echo "   ⚠️  repeated prompts: $S_dup_extra near-duplicate(s) across $S_dup_distinct distinct text(s)."
  echo "       → re-asking the same way means the context isn't landing; add the missing context instead of retrying."
  FOUND=1
fi
if [ "${S_interrupts:-0}" -ge "$INT_MIN" ]; then
  echo "   ⚠️  interrupted $S_interrupts time(s) — the user stopped work in progress."
  echo "       → each one is a place the plan and the user's intent had already diverged. Name them in the retro."
  FOUND=1
fi
if [ "${EPCT:-0}" -ge "$ERR_PCT" ] && [ "${S_tools:-0}" -gt 10 ]; then
  echo "   ⚠️  tool error rate ${EPCT}% ($S_errors/$S_tools) — above the ${ERR_PCT}% line."
  echo "       → repeated failing calls are usually a wrong assumption about the environment, not bad luck."
  FOUND=1
fi
# Delegation. The routing map in the discipline is a RULE, and nothing enforces it — no exit code can judge a
# delegate-or-not call, so over a long session it decays quietly and the work all ends up on the main thread.
# This is the only place it becomes visible. Measured across 44 real sessions the rate varies ~9x BETWEEN
# projects while staying roughly flat within a session, so the number worth reporting is this project's own.
# Only meaningful where agents are actually installed: in a repo with none, zero is the correct answer.
if ls .claude/agents/*.md >/dev/null 2>&1 && [ "${S_turns:-0}" -ge "${CREW_DELEG_MIN_TURNS:-30}" ]; then
  DRATE="$(LC_ALL=C awk -v d="$S_delegations" -v t="$S_turns" 'BEGIN{ printf "%.1f", (d/t)*100 }')"
  if [ "${S_delegations:-0}" = 0 ]; then
    echo "   ⚠️  no delegation in $S_turns turns — every task ran on the main thread."
    echo "       → check the routing map: work that should have gone to an agent (audit, migration, screen) stayed inline."
    FOUND=1
  else
    echo "   ·  $S_delegations delegation(s) across $S_turns turns (${DRATE} per 100)."
  fi
fi
if [ "${S_compactions:-0}" -gt 0 ]; then
  if [ "${S_auto_compactions:-0}" -gt 0 ]; then
    echo "   ⚠️  $S_auto_compactions AUTO compaction(s) (of $S_compactions; ${S_pre_tokens}→${S_post_tokens} tok on the last one)."
    echo "       → auto-compaction drops state nobody chose to drop. Hand off at a phase boundary before it fires (handoff)."
  else
    echo "   ·  $S_compactions manual compaction(s) (${S_pre_tokens}→${S_post_tokens} tok on the last) — deliberate, no state lost unannounced."
  fi
  FOUND=1
fi
[ "$FOUND" = 0 ] && echo "   ✅ no runaway, re-fetch or error loop, repeated prompt, interrupt, error spike or auto-compaction in this session."
exit 0
