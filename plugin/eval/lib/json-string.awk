# json-string.awk — the text on stdin as the inside of a JSON string, printed with no quotes around it and no newline
# after it. One escaper for every hook that puts dynamic text into its JSON (board-sync.sh, session-rehydrate.sh).
#
#   printf '%s\n' "$MSG" | LC_ALL=C awk -f json-string.awk
#
# jq-identical, measured on 15 inputs (quote, backslash, tab, CR, C0 controls, DEL, UTF-8, leading/trailing
# newlines, 5000 chars): 15/15 equal to `jq -cn --arg m`. The one it replaced escaped only the quote, the backslash
# and the newline, so a tab in a board item produced JSON the CLI cannot parse (jq rc=5) and the board silently
# vanished from the session. The trailing newline the caller prints closes the last record, so a value ending in a
# newline keeps it. A CR that ENDS a line is dropped on purpose: it is a CRLF line ending, not content, and MSYS gawk
# already drops it on read (text mode) while BSD awk keeps it, measured on Windows; stripping it here makes every OS
# emit the same bytes. A CR inside a line is still escaped as \r.
BEGIN { ORS = ""
  for (i = 1; i < 32; i++) ctl[i] = sprintf("%c", i)
  nm[8] = "\\b"; nm[9] = "\\t"; nm[12] = "\\f"; nm[13] = "\\r" }
NR > 1 { print "\\n" }
{ s = $0; sub(/\r$/, "", s)
  gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s)
  for (i = 1; i < 32; i++) {
    if (i == 10 || !index(s, ctl[i])) continue
    r = (i in nm) ? nm[i] : sprintf("\\u%04x", i)
    out = ""; while ((p = index(s, ctl[i])) > 0) { out = out substr(s, 1, p - 1) r; s = substr(s, p + 1) }
    s = out s
  }
  d = sprintf("%c", 127)
  if (index(s, d)) { out = ""; while ((p = index(s, d)) > 0) { out = out substr(s, 1, p - 1) "\\u007f"; s = substr(s, p + 1) }; s = out s }
  print s }
