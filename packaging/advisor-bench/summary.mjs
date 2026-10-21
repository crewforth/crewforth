#!/usr/bin/env node
// summary.mjs — the advisor bench's runs, arm by arm: what was found, what was done, the time and what it cost.
//   node packaging/advisor-bench/summary.mjs DIR      (the --out of run.sh)
// Every number is a sum over the arm's runs, read from review-bench's own JSON. Nothing is estimated: a run that
// did not happen is counted as not run, never as zero.
import fs from 'node:fs';
import path from 'node:path';

const dir = process.argv[2];
if (!dir) { console.error('usage: summary.mjs DIR'); process.exit(2); }
const ARMS = { a: 'Sonnet + Opus advisor', b: 'Opus alone' };
const files = fs.readdirSync(dir).filter((f) => /^[ab]-\d+-(review|task)\.json$/.test(f));
const out = {};
for (const f of files) {
  const [arm] = f.split('-'); const s = JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8'));
  const t = (out[arm] ??= { invocations: 0, rows: [], notRun: 0 });
  t.invocations++;
  for (const r of s.rows) (r.skipped ? t.notRun++ : t.rows.push(r));
}
const pct = (a, b) => (b ? `${Math.round((1000 * a) / b) / 10}%` : '—');
const lines = ['| | ' + Object.keys(ARMS).filter((k) => out[k]).map((k) => ARMS[k]).join(' | ') + ' |', '|:--|' + Object.keys(ARMS).filter((k) => out[k]).map(() => '--:').join('|') + '|'];
const row = (name, fn) => lines.push(`| ${name} | ${Object.keys(ARMS).filter((k) => out[k]).map((k) => fn(out[k])).join(' | ')} |`);
const R = (t, kind) => t.rows.filter((r) => r.kind === kind);
const sum = (rows, f) => rows.reduce((n, r) => n + (Number(f(r)) || 0), 0);
const model = (r, re) => Object.entries(r.byModel ?? {}).filter(([k]) => re.test(k)).reduce((n, [, u]) => n + u.cost, 0);
row('runs (not run)', (t) => `${t.rows.length} (${t.notRun})`);
row('defects caught', (t) => { const d = R(t, 'defect'); const c = d.filter((r) => r.caught).length; return `${c}/${d.length}`; });
row('precision', (t) => { const rs = t.rows.filter((r) => r.kind !== 'task'); const m = sum(rs, (r) => r.matched); const c = sum(rs, (r) => r.claims); return `${m}/${c} (${pct(m, c)})`; });
row('false alarms', (t) => String(sum(t.rows, (r) => r.falseAlarms?.length ?? 0)));
row('task done', (t) => { const k = R(t, 'task'); return `${k.filter((r) => r.done).length}/${k.length}`; });
row('errors', (t) => String(t.rows.filter((r) => r.error).length));
row('time, all runs', (t) => `${Math.round(sum(t.rows, (r) => r.ms) / 1000)} s`);
row('cost, all runs', (t) => `$${sum(t.rows, (r) => r.cost).toFixed(2)}`);
row('  of it Opus', (t) => `$${sum(t.rows, (r) => model(r, /opus/)).toFixed(2)}`);
row('advisor calls', (t) => String(sum(t.rows, (r) => r.advisorCalls)));
row('output tokens', (t) => String(sum(t.rows, (r) => Object.values(r.byModel ?? {}).reduce((n, u) => n + (u.output || 0), 0))));
console.log(lines.join('\n'));
const per = (t) => t.rows.map((r) => `${r.id}${r.kind === 'task' ? ` done=${r.done}` : ` caught=${r.caught} claims=${r.claims} fa=${r.falseAlarms?.length ?? 0}`} $${(r.cost ?? 0).toFixed(3)} ${Math.round((r.ms ?? 0) / 1000)}s adv=${r.advisorCalls ?? 0}${r.error ? ` ERROR ${r.error}` : ''}`);
for (const k of Object.keys(ARMS)) if (out[k]) console.log(`\n${ARMS[k]}:\n  ${per(out[k]).join('\n  ')}`);
