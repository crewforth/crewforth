# todo.awk — reads a plan (docs/PLAN.md by default) and draws its to-do panel: the phases and the tasks, a tick on
# what is done (✓), a half-filled circle on what is in work (◐), an empty box on what is not (☐).
#
#   LC_ALL=C awk -v color=1 -v maxl=14 -v name=docs/PLAN.md -f todo.awk docs/PLAN.md
#
# Run it under LC_ALL=C: lengths are counted in bytes, so a cut never depends on the locale (and is mended so it never
# splits a UTF-8 character).
#
# What it reads, and nothing else:
#   a task      a list item whose text starts with a box:  `- [ ] …`  `- [x] …`  `1. [ ] …`  (at the margin)
#               [ ] open · [x] done · [~] or [>] in work. A box indented under a task is a sub-step, not a task.
#   a phase     a heading (## or deeper) with at least one task under it.
#   the scope   when the plan has a `## Tasks` heading (or Görevler, İşler, To-do), only what is under it; else the
#               whole file. With several, the last one that holds a task (a file that keeps several plans adds each
#               below the last), else the first. An `Acceptance criteria` section is never a phase: its boxes are counted as AC n/m.
#   the status a `status: <word>` line in the plan's head (above its first ## heading). paused, on hold, stopped,
#               dropped, abandoned, cancelled, superseded, replaced, done (or beklemede, durduruldu, bırakıldı, iptal,
#               bitti) mean the plan is not the work in progress: no count, no tasks, one line saying so. Anything
#               else, or no such line, is active.
#   code blocks are skipped (a template quoted in the plan is not the plan).
# In work means marked [~]/[>], and only that: the first such task. With none marked, the first open task is shown as
# the next one (☐ … ← next), never as in work. The phase of that task is the one opened up.
#
# Output: line 1 the short count for the status line ("📋 7/12"), or nothing when the plan has no task or is not
# active; line 2 one fact for `todo.sh status`, tab-separated: work<TAB>task · next<TAB>task · done · inactive<TAB>word
# · none; then the panel. It decides nothing and changes nothing.
BEGIN {
  if (maxl + 0 < 6) maxl = 14
  wmax = 64
  E = sprintf("%c", 27)
  if (color + 0) { DIM = E "[2m"; BOLD = E "[1m"; ACT = E "[1;36m"; WRK = E "[1;33m"; RST = E "[0m" } else { DIM = BOLD = ACT = WRK = RST = "" }
  for (i = 128; i < 192; i++) CONT = CONT sprintf("%c", i)
  for (i = 192; i < 256; i++) LEAD = LEAD sprintf("%c", i)
  TICK = "✓"; BOX = "☐"; WORK = "◐"; NEXT = "← next"
  nev = 0; fence = ""; status = ""; inhead = 1
}

# A fenced code block: skipped whole.
/^[ ]*(```|~~~)/ {
  f = $0; sub(/^[ ]*/, "", f); f = substr(f, 1, 3)
  if (fence == "") fence = f; else if (f == fence) fence = ""
  next
}
fence != "" { next }

# The plan's status: the first `status:` line above its first ## heading.
inhead && status == "" && /^[ ]*\**[Ss][Tt][Aa][Tt][Uu][Ss]\**:/ {
  status = $0; sub(/\r$/, "", status); sub(/^[^:]*:\**[ \t]*/, "", status); sub(/[ \t]+$/, "", status)
  if (status == "") status = "active"
  next
}

/^#+[ \t]/ {
  t = $0; match(t, /^#+/); lv = RLENGTH; if (lv >= 2) inhead = 0
  t = substr(t, lv + 1); sub(/^[ \t]+/, "", t); sub(/[ \t]+#*[ \t]*$/, "", t); sub(/\r$/, "", t)
  nev++; EV[nev] = "H"; LV[nev] = lv; TX[nev] = t
  next
}

{
  line = $0; sub(/\r$/, "", line)
  match(line, /^ */); ind = RLENGTH
  if (ind > 1) next
  rest = substr(line, ind + 1)
  if (match(rest, /^[-*+][ \t]+\[[ xX~>]\][ \t]+/)) num = ""
  else if (match(rest, /^[0-9]+[.)][ \t]+\[[ xX~>]\][ \t]+/)) { num = rest; sub(/[.)].*/, "", num) }
  else next
  head = substr(rest, 1, RLENGTH); txt = substr(rest, RLENGTH + 1)
  b = head; sub(/^[^[]*\[/, "", b); b = substr(b, 1, 1)
  st = (b == "x" || b == "X") ? "d" : (b == "~" || b == ">") ? "w" : "o"
  # The task's name is what comes before its first " — " (the plan's fields: satisfies, size, risk…).
  k = index(txt, " — "); if (k > 0) txt = substr(txt, 1, k - 1)
  sub(/[ \t]+$/, "", txt)
  if (num != "") txt = num ". " txt
  nev++; EV[nev] = "I"; ST[nev] = st; TX[nev] = txt
}

function isac(t) { return t ~ /^([Aa]cceptance [Cc]riteria|[Kk]abul [Kk]riter)/ }
function istasks(t) { return t ~ /^([Tt]asks|TASKS|[Gg]örevler|GÖREVLER|[İi]şler|İŞLER|[Tt]o-?[Dd]o|TODO)([^A-Za-z]|$)/ }
# A cut in bytes that never leaves half a UTF-8 character: drop trailing continuation bytes, then their lead byte.
function cut(s, n,   r) {
  if (length(s) <= n) return s
  r = substr(s, 1, n - 1)
  while (length(r) && index(CONT, substr(r, length(r), 1))) r = substr(r, 1, length(r) - 1)
  if (length(r) && index(LEAD, substr(r, length(r), 1))) r = substr(r, 1, length(r) - 1)
  return r "…"
}
function mark(st) { return st == "d" ? TICK : st == "w" ? WORK : BOX }
# Not the work in progress: the status's first word, lower-cased (ASCII; the Turkish words are written lower-case).
function inactive(s,   w) {
  w = tolower(s); sub(/[ \t.,;:(].*$/, "", w)
  if (w == "on" && tolower(s) ~ /^on[ -]hold/) return 1
  return w ~ /^(paused|hold|stopped|dropped|abandoned|cancell?ed|superseded|replaced|done|closed|beklemede|durduruldu|bırakıldı|iptal|bitti)$/
}
function out(s) { L[++nl] = s }

END {
  # The scope: under a Tasks heading when the plan has one.
  s0 = 1; s1 = nev; base = 1; title = ""
  for (i = 1; i <= nev; i++) if (EV[i] == "H" && LV[i] == 1 && title == "") title = TX[i]
  # A file that keeps several plans, each with its own Tasks heading, is read at the last one that holds a task: plans
  # are added below the ones before them, so that is the newest. With no Tasks heading holding one, the first.
  first = 0
  for (i = 1; i <= nev; i++) if (EV[i] == "H" && LV[i] >= 2 && istasks(TX[i])) {
    e = nev; has = 0
    for (j = i + 1; j <= nev; j++) { if (EV[j] == "H" && LV[j] <= LV[i]) { e = j - 1; break }; if (EV[j] == "I") has = 1 }
    if (!first) { first = 1; s0 = i + 1; s1 = e; base = LV[i] }
    if (has) { s0 = i + 1; s1 = e; base = LV[i] }
  }
  # Acceptance criteria, wherever they are: counted, never shown as a phase.
  ac = 0; acd = 0; inac = 0
  for (i = 1; i <= nev; i++) {
    if (EV[i] == "H") { if (inac && LV[i] <= aclv) inac = 0; if (isac(TX[i])) { inac = 1; aclv = LV[i] } }
    else if (inac) { ac++; if (ST[i] == "d") acd++ }
  }
  # Phases and tasks inside the scope. A heading opens a phase; tasks before any heading sit in an unnamed one.
  np = 0; cur = 0; skip = 0; skiplv = 0; nt = 0; done = 0
  for (i = s0; i <= s1; i++) {
    if (EV[i] == "H") {
      if (skip && LV[i] <= skiplv) skip = 0
      if (LV[i] <= base && base > 1) continue
      if (isac(TX[i]) || (LV[i] == 1 && base == 1)) { if (isac(TX[i])) { skip = 1; skiplv = LV[i] }; cur = 0; continue }
      if (skip) continue
      np++; PN[np] = TX[i]; PT[np] = 0; PD[np] = 0; cur = np
      continue
    }
    if (skip) continue
    if (cur == 0) { np++; PN[np] = ""; PT[np] = 0; PD[np] = 0; cur = np }
    PT[cur]++; nt++; T[cur, PT[cur]] = i
    if (ST[i] == "d") { PD[cur]++; done++ }
  }
  nm0 = cut(title != "" ? title : (name != "" ? name : FILENAME), wmax)
  if (inactive(status)) {
    print ""; print "inactive\t" status
    print DIM "📋 " nm0 " · " cut(status, 24) ": not the work in progress (" done "/" nt " done) · /crew-todo resume shows it again" RST
    exit
  }
  if (nt == 0) { print ""; print "none"; print "📋 " cut(name != "" ? name : FILENAME, wmax) ": no task with a box yet ( - [ ] task · - [x] done · - [~] in work )"; exit }

  # The task in work: the first marked [~]/[>]. With none, the first open one is the next (wk = 0), not in work.
  ap = 0; at = 0; wk = 0
  for (p = 1; p <= np && !ap; p++) for (t = 1; t <= PT[p]; t++) if (ST[T[p, t]] == "w") { ap = p; at = t; wk = 1; break }
  for (p = 1; p <= np && !ap; p++) for (t = 1; t <= PT[p]; t++) if (ST[T[p, t]] == "o") { ap = p; at = t; break }
  for (p = 1; p <= np; p++) { PW[p] = 0; for (t = 1; t <= PT[p]; t++) if (ST[T[p, t]] == "w") PW[p] = 1 }

  # Phases with no task are not phases.
  m = 0
  for (p = 1; p <= np; p++) if (PT[p] > 0) { m++; PN[m] = PN[p]; PT[m] = PT[p]; PD[m] = PD[p]; PW[m] = PW[p]; for (t = 1; t <= PT[p]; t++) T[m, t] = T[p, t]; if (p == ap) ap = m }
  np = m
  phased = (np > 1 || PN[1] != "")

  print "📋 " done "/" nt
  if (!ap) print "done"; else print (wk ? "work" : "next") "\t" TX[T[ap, at]]
  hd = BOLD "📋 " (title != "" ? cut(title, wmax) : "Plan") RST " · " done "/" nt " done"
  if (phased && ap) hd = hd " · phase " ap "/" np
  if (ac) hd = hd " · AC " acd "/" ac
  if (!ap) hd = hd " · all done"
  out(hd)

  # Which phases get a line: all of them when they fit, else the active one with its neighbours and a count of the rest.
  budget = maxl - 1
  pa = 1; pb = np
  if (phased && np > budget - 3) {
    c = (ap ? ap : np); pa = c - 1; if (pa < 1) pa = 1; pb = pa + (budget - 6); if (pb > np) pb = np
    if (pb - pa < budget - 6) { pa = pb - (budget - 6); if (pa < 1) pa = 1 }
  }
  # The tasks of the active phase (or of the plan, when it has no phases) get what is left.
  room = budget - (phased ? (pb - pa + 1) + (pa > 1) + (pb < np) : 0)
  if (room < 3) room = 3

  if (phased && pa > 1) { k = 0; for (p = 1; p < pa; p++) k += (PD[p] == PT[p]); out(DIM "… " (pa - 1) " phase" (pa > 2 ? "s" : "") " before (" k " done)" RST) }
  for (p = (phased ? pa : 1); p <= (phased ? pb : 1); p++) {
    if (phased) {
      nm = (PN[p] != "" ? cut(PN[p], wmax) : "(no phase)") "  " PD[p] "/" PT[p]
      # A phase: ✓ all done · ◐ a task in it is in work, or some are done · ☐ none started. The opened one is bright.
      pm = (PD[p] == PT[p]) ? TICK : (PW[p] || PD[p] > 0) ? WORK : BOX
      if (p == ap) out(ACT pm " " nm RST)
      else if (PD[p] == PT[p]) out(DIM pm " " nm RST)
      else out(pm " " nm)
    }
    if (p != ap && !(phased == 0 && !ap)) continue
    # A window over the tasks that keeps the one in work in sight: one before it, the rest after.
    n = PT[p]; lo = 1; hi = n
    if (n > room) {
      lo = (at > 1 ? at - 1 : 1)
      hi = (lo == 1) ? room - 1 : lo + room - 3
      if (hi >= n) { hi = n; lo = n - room + 2; if (lo < 1) lo = 1 }
    }
    ind = (phased ? "   " : "")
    if (lo > 1) out(ind DIM "… " (lo - 1) " above" RST)
    for (t = lo; t <= hi; t++) {
      e = T[p, t]; s = mark(ST[e]) " " cut(TX[e], wmax)
      if (t == at && p == ap && wk) out(ind WRK WORK " " cut(TX[e], wmax) RST)
      else if (t == at && p == ap) out(ind BOLD BOX " " cut(TX[e], wmax) "  " NEXT RST)
      else if (ST[e] == "d") out(ind DIM s RST)
      else if (ST[e] == "w") out(ind WRK s RST)
      else out(ind s)
    }
    if (hi < n) out(ind DIM "… " (n - hi) " more" RST)
  }
  if (phased && pb < np) { k = 0; for (p = pb + 1; p <= np; p++) k += PT[p] - PD[p]; out(BOX " … " (np - pb) " more phase" (np - pb > 1 ? "s" : "") " (" k " open)") }
  for (i = 1; i <= nl; i++) print L[i]
}
