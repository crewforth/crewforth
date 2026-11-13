#!/usr/bin/env node
// case-shortcuts.mjs — can a labelled case set be passed WITHOUT doing the task it measures?
//
// A set whose labels follow one surface feature (a word in the prompt, the size of the diff, where the case sits in
// the file) rewards a model or a matcher that learned the feature, not the skill. For each set this finds the BEST
// single-feature rule and its accuracy, and fails when that accuracy is above the set's declared ceiling: the ceiling
// is the most a shortcut may score before the set stops measuring what it says it measures.
//
//   node packaging/case-shortcuts.mjs          # rc 0 every set under its ceiling · 1 a set is above it · 2 unreadable
//
// The sets and their rules:
//   routing (working, held-out) — label = the target of a positive row. One word w predicts one target T for every
//       prompt containing w; everything else gets the most common target. The best (w, T) is reported.
//   review bench — label = defect or clean. A word in the diff, the diff's length (one threshold), or the case's
//       position in the sorted list (one cut); the best is reported.
// The ceilings were set from the first measurement (see CEILING) with a margin; raising one is a decision with a reason.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
// Measured 2026-11-06 on this repository (best rule; the most common label alone scores the 'always' figure printed
// beside it): routing-working 0.128, routing-holdout 0.167, review-bench 0.926 — the bench's clean cases sort first by
// name (position) and share the word "every" (0.889). A model reviewing one diff at a time sees neither, so the bench
// still measures review; anything tuned on the set as a whole could learn them. Each ceiling is its measured figure plus
// a small margin: it stops a set from getting MORE predictable without a decision, it does not claim the set is clean.
const CEILING = { 'routing-working': 0.15, 'routing-holdout': 0.2, 'review-bench': 0.95 };

const words = (s) => [...new Set(String(s).toLowerCase().match(/[a-z][a-z0-9-]{2,}/g) ?? [])];

function routingSet(file) {
  const rows = [];
  for (const raw of fs.readFileSync(path.join(ROOT, file), 'utf8').split(/\r?\n/)) {
    const l = raw.trim(); if (!l || l.startsWith('#')) continue;
    const cut = l.lastIndexOf('|'); if (cut < 0) continue;
    const target = l.slice(cut + 1).trim(); if (!target || target.startsWith('!')) continue;
    rows.push({ text: l.slice(0, cut), label: target });
  }
  return rows;
}

function bestWordRule(rows) {
  const count = (arr) => arr.reduce((m, x) => m.set(x, (m.get(x) ?? 0) + 1), new Map());
  const major = [...count(rows.map((r) => r.label))].sort((a, b) => b[1] - a[1])[0]?.[0];
  const ws = rows.map((r) => words(r.text));
  let best = { acc: rows.filter((r) => r.label === major).length / rows.length, rule: `always "${major}"` };
  best.always = best.acc;
  const vocab = new Set(ws.flat());
  for (const w of vocab) {
    const hit = rows.filter((_, i) => ws[i].includes(w));
    const t = [...count(hit.map((r) => r.label))].sort((a, b) => b[1] - a[1])[0]?.[0];
    const ok = rows.filter((r, i) => (ws[i].includes(w) ? t : major) === r.label).length;
    if (ok / rows.length > best.acc) best = { acc: ok / rows.length, rule: `"${w}" -> ${t}, else ${major}`, always: best.always };
  }
  return best;
}

async function benchSet() {
  // import() takes a URL: a bare Windows path (D:\…) is read as the scheme "d:".
  const bench = await import(pathToFileURL(path.join(ROOT, 'kit', 'eval', 'lib', 'review-bench', 'bench.mjs')).href);
  const cases = bench.loadCases(path.join(ROOT, 'packaging', 'review-bench', 'cases'), { split: 'all' });
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'crew-shortcuts-'));
  try {
    const rows = cases.filter((c) => c.kind === 'defect' || c.kind === 'clean').map((c, i) => {
      const diff = bench.build(c, tmp).diff;
      return { label: c.kind, text: diff.split('\n').filter((l) => /^[+-][^+-]/.test(l)).join('\n'), size: diff.length, pos: i };
    });
    let best = bestWordRule(rows); const per = { word: { ...best } };
    for (const key of ['size', 'pos']) {
      per[key] = { acc: 0, rule: '' };
      for (const v of new Set(rows.map((r) => r[key]))) {
        for (const [above, other] of [['defect', 'clean'], ['clean', 'defect']]) {
          const ok = rows.filter((r) => (r[key] >= v ? above : other) === r.label).length / rows.length;
          if (ok > per[key].acc) per[key] = { acc: ok, rule: `${key} >= ${v} -> ${above}` };
          if (ok > best.acc) best = { acc: ok, rule: `${key} >= ${v} -> ${above}`, always: best.always };
        }
      }
    }
    return { rows: rows.length, best, per };
  } finally { fs.rmSync(tmp, { recursive: true, force: true }); }
}

let bad = 0;
const report = (name, n, best) => {
  const over = best.acc > CEILING[name];
  if (over) bad++;
  console.log(`  ${over ? 'ABOVE' : 'ok   '} ${name.padEnd(16)} ${n} rows · best single-feature rule ${best.acc.toFixed(3)} (ceiling ${CEILING[name]}; always one label ${best.always.toFixed(3)}) · ${best.rule}`);
};
try {
  console.log('case-shortcuts: the best one-feature rule per labelled set');
  for (const [name, file] of [['routing-working', 'kit/eval/golden-routing.txt'], ['routing-holdout', 'kit/eval/golden-holdout.txt']]) {
    const rows = routingSet(file); report(name, rows.length, bestWordRule(rows));
  }
  const b = await benchSet(); report('review-bench', b.rows, b.best);
  for (const [k, v] of Object.entries(b.per)) console.log(`        review-bench by ${k.padEnd(4)} ${v.acc.toFixed(3)} · ${v.rule}`);
} catch (e) { console.error(`case-shortcuts: could not read a set: ${e.message}`); process.exit(2); }
process.exit(bad ? 1 : 0);
