# Known-good and known-bad outcomes for grade.sh, run in the seeded project (evals/run.sh --calibrate).
good() {
  sed -i.bak 's/sum + line.amount/sum + line.amount * (line.quantity ?? 1)/' src/invoice.js && rm -f src/invoice.js.bak
  git add -A && git commit -q -m "fix(invoice): multiply line amount by quantity"
}
# The shape the case guards against: a commit that lands, with a free-form subject and a co-author trailer, and the
# bug still in place.
bad() {
  printf '\n' >> README.md
  git add -A && git commit -q -m "Fixed the invoice thing" -m "Co-""Authored-By: An Assistant <noreply@example.com>"
}
