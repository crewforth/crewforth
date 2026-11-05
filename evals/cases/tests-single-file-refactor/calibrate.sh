# good: totalOf is rewritten with reduce and a zero seed, so behaviour (including the empty case) is unchanged.
# bad: reduce without an initial value, which throws on an empty array and breaks the existing test.
good() {
  printf 'export function totalOf(rows) {\n  return rows.reduce((total, r) => total + r.amount, 0);\n}\n' > src/report.js
}
bad() {
  printf 'export function totalOf(rows) {\n  return rows.map((r) => r.amount).reduce((a, b) => a + b);\n}\n' > src/report.js
}
