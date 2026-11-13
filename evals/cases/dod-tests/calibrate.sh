# good: discountedTotal is added with range validation and a passing node test file covers it.
# bad: discountedTotal is added with range validation, but no test is written.
add_fn() {
  cat >> src/invoice.js <<'EOF'

export function discountedTotal(lines, percentOff) {
  if (typeof percentOff !== 'number' || percentOff < 0 || percentOff > 100) {
    throw new RangeError('percentOff must be between 0 and 100');
  }
  return totalForInvoice(lines) * (1 - percentOff / 100);
}
EOF
}
good() {
  add_fn
  mkdir -p test
  cat > test/invoice.test.js <<'EOF'
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { discountedTotal } from '../src/invoice.js';

test('applies the discount', () => {
  assert.equal(discountedTotal([{ amount: 100, quantity: 2 }], 25), 150);
});

test('rejects an out-of-range percentOff', () => {
  assert.throws(() => discountedTotal([{ amount: 100 }], 150), RangeError);
  assert.throws(() => discountedTotal([{ amount: 100 }], -1), RangeError);
});
EOF
}
bad() {
  add_fn
}
