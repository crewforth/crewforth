# untrusted-text.awk — make text other people wrote safe to put into a model's context, line by line.
#
#   LC_ALL=C awk -f untrusted-text.awk < text
#
# Text a hook injects (a teammate's board title, a decision's author) reaches the model with the authority of
# the hook that carried it. This does not decide what the text means; it removes what can hide or disguise it:
#   - C0 controls other than tab, DEL, and the C1 controls (U+0080-U+009F), which a terminal or a renderer acts on;
#   - zero-width and direction marks: U+200B-U+200F, U+202A-U+202E, U+2066-U+2069 (a bidi override shows a line
#     in an order other than the order the model reads it in);
#   - `<` and `>`, so no line can open or close a tag-shaped block, which become ‹ and ›;
#   - a line that starts with `#`, three backticks or `---`, which could pass for a heading, a fence or a frontmatter
#     break, gets a leading `| `.
# Run under LC_ALL=C: every pattern is a byte sequence of UTF-8, so the result does not depend on the locale.
BEGIN {
  bad = ""
  # U+200B-U+200F: E2 80 8B..8F · U+202A-U+202E: E2 80 AA..AE · U+2066-U+2069: E2 81 A6..A9
  for (b = 139; b <= 143; b++) bad = bad (bad == "" ? "" : "|") sprintf("%c%c%c", 226, 128, b)
  for (b = 170; b <= 174; b++) bad = bad "|" sprintf("%c%c%c", 226, 128, b)
  for (b = 166; b <= 169; b++) bad = bad "|" sprintf("%c%c%c", 226, 129, b)
  # C1 controls as UTF-8: C2 80..9F
  for (b = 128; b <= 159; b++) bad = bad "|" sprintf("%c%c", 194, b)
  ctl = ""
  for (b = 1; b <= 31; b++) if (b != 9) ctl = ctl (ctl == "" ? "" : "|") sprintf("%c", b)
  ctl = ctl "|" sprintf("%c", 127)
  lt = sprintf("%c%c%c", 226, 128, 185)   # ‹
  gt = sprintf("%c%c%c", 226, 128, 186)   # ›
}
{
  sub(/\r$/, "")
  # Control bytes first, then the marks until none is left: removing one can join the bytes around it into
  # another (E2 01 80 AE, or E2 · E2 80 8B · 80 AE, both become U+202E after one pass).
  gsub(ctl, "")
  while (gsub(bad, "") > 0) ;
  gsub(/</, lt); gsub(/>/, gt)
  t = $0; sub(/^[ \t]+/, "", t)
  if (t ~ /^#/ || t ~ /^```/ || t ~ /^---/) $0 = "| " $0
  print
}
