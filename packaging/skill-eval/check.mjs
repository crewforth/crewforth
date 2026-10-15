#!/usr/bin/env node
// check.mjs — the gate on a skill's description. Free: it reads results.tsv and calls no model.
//
//   node packaging/skill-eval/check.mjs [--base REF]
//       rc 0 = no description changed, or every changed one is measured, for its current text, at or above its floor
//       rc 1 = a changed description is not measured as it is now, or scored under its floor, or has no case at all
//       rc 3 = the base could not be read, so nothing was judged (not a pass)
//
// Only a PR that changes a description is held (K10): the descriptions are compared with REF (default: the PR's
// base when GITHUB_BASE_REF says it, else origin/next). A command (`metadata.kind: command`) is called by name and
// is not held. For every other changed skill, each of its cases needs a line in results.tsv that measured THIS
// description (its hash), with at least MIN_RUNS runs, and a score at or above the case's floor in baseline.tsv.
// The measurement itself is run.mjs, by hand: it spends tokens, and this file never does.
import { execFileSync } from 'node:child_process';
import { ROOT, skillsAt, changedSince, casesFor, commandSkills, hashOf, readResults, readBaseline } from './lib.mjs';

const MIN_RUNS = 3;
const args = process.argv.slice(2);
const i = args.indexOf('--base');
const base = i >= 0 ? args[i + 1] : process.env.GITHUB_BASE_REF ? `origin/${process.env.GITHUB_BASE_REF}` : 'origin/next';

try { execFileSync('git', ['-C', ROOT, 'rev-parse', '--verify', '--quiet', `${base}^{commit}`], { stdio: 'ignore' }); } catch {
  console.log(`skill-eval: the base ${base} could not be read here, so no description was compared (not a pass)`);
  process.exit(3);
}

const commands = commandSkills();
const changed = changedSince(base);
const held = changed.filter((s) => !commands.has(s));
if (!held.length) {
  console.log(`skill-eval: no model-picked skill's description changed against ${base}${changed.length ? ` (${changed.length} command(s) changed; a command is called by name)` : ''}`);
  process.exit(0);
}

const now = skillsAt(null);
const rows = new Map((readResults() ?? []).map((r) => [r.case, r]));
const floor = readBaseline();
const problems = [];
let checked = 0;
let expected = 0;
for (const skill of held) {
  const cases = casesFor([skill]);
  if (!cases.length) { problems.push(`${skill}: no routing row measures it; add a held-out row (kit/eval/golden-holdout.txt)`); continue; }
  const h = hashOf(now.get(skill));
  for (const c of cases) {
    expected += 1;
    const r = rows.get(c.id);
    if (!r) { problems.push(`${c.id}: not measured`); continue; }
    if (r.description !== h) { problems.push(`${c.id}: measured for an earlier text of the description`); continue; }
    if (!(r.runs >= MIN_RUNS)) { problems.push(`${c.id}: ${r.runs} run(s), ${MIN_RUNS} needed`); continue; }
    const f = floor.get(c.id);
    if (f !== undefined && !(r.score >= f)) { problems.push(`${c.id}: score ${r.score.toFixed(3)} is under its floor ${f.toFixed(3)}`); continue; }
    checked += 1;
  }
}

if (problems.length) {
  console.log(`skill-eval: ${held.length} description(s) changed against ${base}: ${held.join(', ')}`);
  for (const p of problems) console.log(`  ${p}`);
  console.log(`  ${checked} of ${expected} case(s) hold. Measure with: node packaging/skill-eval/run.mjs --base ${base}`);
  process.exit(1);
}
console.log(`skill-eval: ${held.length} changed description(s) (${held.join(', ')}); ${checked} of ${expected} case(s) measured for the current text and at or above their floor`);
