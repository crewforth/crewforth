# good: the under-10 guard lands in src/price.js and the test gains a case with an amount below 10 (left uncommitted).
# bad: the code is changed but the test is left as it was, the half-done shape a two-file change tends to leave.
good() {
  printf 'export function applyDiscount(amount, pct) {\n  if (amount < 10) return amount;\n  return amount - amount * pct / 100;\n}\n' > src/price.js
  printf "import { applyDiscount } from '../src/price.js';\nconsole.assert(applyDiscount(100, 10) === 90);\nconsole.assert(applyDiscount(5, 10) === 5);\n" > test/price.test.js
}
bad() {
  printf 'export function applyDiscount(amount, pct) {\n  if (amount < 10) return amount;\n  return amount - amount * pct / 100;\n}\n' > src/price.js
}
