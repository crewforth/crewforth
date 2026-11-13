# good: applyDiscount skips amounts under 10 and its test gains a case that checks exactly that.
# bad: the rule lands in the code but the test is left as it was, so nothing checks the new behaviour.
good() {
  printf 'export function applyDiscount(amount, pct) {\n  if (amount < 10) return amount;\n  return amount - amount * pct / 100;\n}\n' > src/price.js
  printf "test('no discount under 10', () => { assert.equal(applyDiscount(5, 10), 5); });\n" >> test/price.test.js
}
bad() {
  printf 'export function applyDiscount(amount, pct) {\n  if (amount < 10) return amount;\n  return amount - amount * pct / 100;\n}\n' > src/price.js
}
