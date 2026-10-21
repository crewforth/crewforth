#!/usr/bin/env node
// make-case.mjs — turn a commit of this repository into a review-bench case. Run in a checkout with history.
//
//   node make-case.mjs defect <fix-sha> <id> "<intent>" [--holdout] [--only path,...]
//       The change under review UNDOES the fix: before = the fixed files, after = the files as they were before it.
//       So the diff brings the defect back, and where it lands is known without a person marking it: every hunk
//       of that diff is an expected finding, in the after side's lines. <intent> is what the change says it does,
//       written as its author would, without naming the defect (a reviewer is not told what to look for).
//   node make-case.mjs clean <sha> <id> "<intent>" [--holdout] [--only path,...]
//       A commit nothing later had to fix, applied forward: no finding is expected.
//
// A fix in this repository says why in a comment, so undoing it would show that comment among the removed lines and
// the reviewer would read the defect instead of finding it. The comment-only lines a fix ADDED are therefore left
// out of the before side too (case.json counts them): the diff changes code, and the code is what is reviewed.
//
// Writes packaging/review-bench/cases/<id>/{case.json, before/…, after/…}. Only the touched files are kept, with
// their modes: a change of mode alone (100755 → 100644) is a case too, expected on the file with no line.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { storedPath, realPath } from '../../kit/eval/lib/review-bench/bench.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const git = (...a) => { const r = spawnSync('git', ['-c', 'core.quotePath=false', ...a], { encoding: 'buffer', maxBuffer: 64 << 20 }); if (r.status !== 0) throw new Error(`git ${a.join(' ')}: ${r.stderr}`); return r.stdout; };
const [kind, sha, id, intent, ...rest] = process.argv.slice(2);
if (!['defect', 'clean'].includes(kind) || !sha || !/^[a-z0-9-]+$/.test(id ?? '') || !intent) {
  console.error('usage: make-case.mjs defect|clean <sha> <id> "<intent>" [--holdout] [--only a,b]'); process.exit(2);
}
const holdout = rest.includes('--holdout');
const only = rest.includes('--only') ? rest[rest.indexOf('--only') + 1].split(',') : null;
const full = git('rev-parse', sha).toString().trim();
const subject = git('log', '-1', '--format=%s', full).toString().trim();
// defect: before = the fix, after = its parent. clean: before = the parent, after = the commit.
const [from, to] = kind === 'defect' ? [full, `${full}^`] : [`${full}^`, full];
const touched = git('diff', '--name-only', '--no-renames', `${full}^`, full).toString().trim().split('\n').filter(Boolean)
  .filter((f) => !only || only.includes(f));
// The comment-only lines the fix added, per file, in order (defect cases).
const COMMENT = /^\s*(#(?!!)|\/\/|\/\*|\*)/;
const fixComments = {};
if (kind === 'defect') {
  let file = null;
  for (const l of git('diff', '-U0', '--no-renames', `${full}^`, full, '--', ...touched).toString().split('\n')) {
    if (l.startsWith('+++ ')) { file = l === '+++ /dev/null' ? null : l.slice(6); continue; }
    if (file && l.startsWith('+') && COMMENT.test(l.slice(1))) (fixComments[file] ??= []).push(l.slice(1));
  }
}
let stripped = 0;
const dir = path.join(HERE, 'cases', id);
fs.rmSync(dir, { recursive: true, force: true });
const modes = { before: {}, after: {} };
for (const [side, rev] of [['before', from], ['after', to]]) {
  for (const f of touched) {
    const ls = git('ls-tree', rev, '--', f).toString().trim();
    if (!ls) continue;   // added or deleted on this side
    const [mode] = ls.split(/\s+/);
    const out = path.join(dir, side, storedPath(f));
    fs.mkdirSync(path.dirname(out), { recursive: true });
    let body = git('show', `${rev}:${f}`);
    if (side === 'before' && fixComments[f]) {
      // Drop each added comment line once, in order, so a line the file had before the fix stays.
      const want = [...fixComments[f]]; const kept = [];
      for (const l of body.toString().split('\n')) { if (want.length && l === want[0]) { want.shift(); stripped++; } else kept.push(l); }
      body = Buffer.from(kept.join('\n'));
    }
    fs.writeFileSync(out, body);
    modes[side][f] = mode;
  }
}
// Every hunk of the change under review, in the after side's lines; a pure deletion is cited at the line after it.
// Read from the files as written (the before side may have lost comment lines), not from git.
const expect = [];
if (kind === 'defect') {
  const d = spawnSync('git', ['diff', '--no-index', '-U0', 'before', 'after'], { cwd: dir, encoding: 'utf8', maxBuffer: 64 << 20 }).stdout;
  let file = null;
  for (const l of d.split('\n')) {
    if (l.startsWith('+++ ')) file = l === '+++ /dev/null' ? null : realPath(l.slice(4).replace(/^b\/after\//, ''));
    const h = /^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/.exec(l);
    if (h && file) { const a = Number(h[1]); const n = h[2] === undefined ? 1 : Number(h[2]); expect.push({ file, from: Math.max(1, a), to: Math.max(1, a + Math.max(n, 1) - 1) }); }
  }
  for (const f of touched) if (modes.before[f] && modes.after[f] && modes.before[f] !== modes.after[f] && !expect.some((e) => e.file === f)) expect.push({ file: f, from: null, to: null });
}
const c = { id, kind, stratum: 'judgement', holdout, source: `${full.slice(0, 9)} ${subject}`, intent, ...(stripped ? { strippedComments: stripped } : {}), modes, expect };
fs.writeFileSync(path.join(dir, 'case.json'), JSON.stringify(c, null, 2) + '\n');
console.log(`${id}: ${kind} · ${touched.length} file(s) · ${expect.length} expected location(s)${stripped ? ` · ${stripped} comment line(s) of the fix left out` : ''}`);
