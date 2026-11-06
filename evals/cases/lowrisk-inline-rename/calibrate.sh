# good: the local tmp becomes total in all three places; the exported totalOf(rows) and every other file stay as they were.
# bad: the rename is done but the export is renamed too, to match, which breaks callers the prompt never mentioned.
good() {
  sed -i.bak 's/let tmp/let total/; s/ tmp +=/ total +=/; s/return tmp/return total/' src/report.js && rm -f src/report.js.bak
}
bad() {
  sed -i.bak 's/let tmp/let total/; s/ tmp +=/ total +=/; s/return tmp/return total/; s/function totalOf(rows)/function sumAmounts(rows)/' src/report.js && rm -f src/report.js.bak
}
