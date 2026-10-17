// The check the session never saw: copied in after it ends. rc 0 only when every case holds.
import { parseDuration } from './src/duration.js';

const ok = [
  ['1h30m', 5400000], ['1h 30m', 5400000], ['90s', 90000], ['250ms', 250], ['2d', 172800000],
  ['1.5h', 5400000], ['0', 0], ['-1m', -60000], ['1d2h3m4s5ms', 93784005], ['0.5s', 500], ['1m 1ms', 60001],
];
const bad = ['', '10', '5x', '1m1h', '1h1h', '1m 1m', 'h', ' ', '--1m', null, 5, undefined, '1s500', 'ms'];

let failed = 0; let n = 0;
for (const [input, want] of ok) {
  n++;
  let got; try { got = parseDuration(input); } catch (e) { got = `threw ${e?.name}`; }
  if (got !== want) { failed++; console.log(`FAIL ${JSON.stringify(input)}: want ${want}, got ${got}`); }
}
for (const input of bad) {
  n++;
  let got = 'returned'; try { got = `returned ${parseDuration(input)}`; } catch (e) { got = e instanceof TypeError ? 'TypeError' : `threw ${e?.name}`; }
  if (got !== 'TypeError') { failed++; console.log(`FAIL ${JSON.stringify(input)}: want TypeError, got ${got}`); }
}
console.log(`${n - failed}/${n} cases`);
process.exitCode = failed ? 1 : 0;
