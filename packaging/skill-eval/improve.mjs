#!/usr/bin/env node
// improve.mjs — propose a better description for ONE skill, and keep it only if the measurement says so.
//
//   node packaging/skill-eval/improve.mjs --skill NAME [--runs N] [--dry-run]
//       --dry-run   print the limit, the rows and the rewriting prompt; call no model, change nothing
//
// The loop: the skill's rows in results.tsv are the evidence. Working-set rows (their prompts were written from the
// triggers) are shown to the rewriter; held-out rows (written without looking) are NOT shown, so they stay a test.
// The rewriter writes one candidate, no longer than the skill's current listing cost plus the headroom left under
// BUDGET_SKILL_LISTING (the listing is shared by every skill: a longer description is paid by all of them). The
// candidate goes into a scratch worktree, the plugin is rebuilt there, and run.mjs measures that skill there. It is
// KEPT only if every held-out row scores at or above its floor (baseline.tsv) and every must-not-fire row stays at
// 1.000; otherwise it is printed and dropped. Nothing in this checkout changes either way: a kept candidate is
// printed with the file to put it in, and a person applies it.
//
// THIS SPENDS REAL TOKENS (one rewrite call, then run.mjs's own runs), like run.mjs. Run by hand, never by CI.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync, execFileSync } from 'node:child_process';
import { ROOT, descriptionOf, readResults, readBaseline, casesFor } from './lib.mjs';

const args = process.argv.slice(2);
const opt = (k) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : null; };
const skill = opt('--skill');
const runs = opt('--runs');
const dry = args.includes('--dry-run');
if (!skill) { console.error('improve: --skill NAME is required (one skill per run)'); process.exit(2); }

const file = path.join(ROOT, 'kit', 'skills', skill, 'SKILL.md');
if (!fs.existsSync(file)) { console.error(`improve: no such skill: ${skill}`); process.exit(2); }
const text = fs.readFileSync(file, 'utf8');
const current = descriptionOf(text);
if (!current) { console.error(`improve: ${skill} has no description to improve`); process.exit(2); }

// The listing as Claude Code counts it (the same awk doctor.sh and the smoke test use), and the budget from the one
// place it is written. A headroom that cannot be read stops the run: a guessed limit is how a description overruns.
const awk = path.join(ROOT, 'kit', 'eval', 'lib', 'skill-listing.awk');
const skillFiles = fs.readdirSync(path.join(ROOT, 'kit', 'skills')).map((d) => path.join(ROOT, 'kit', 'skills', d, 'SKILL.md')).filter((f) => fs.existsSync(f));
let total = NaN;
try { total = Number(execFileSync('awk', ['-f', awk, ...skillFiles], { encoding: 'utf8', env: { ...process.env, LC_ALL: 'C' } }).trim().split(/\s+/)[0]); } catch { /* below */ }
const budgetLine = fs.readFileSync(path.join(ROOT, 'kit', 'eval', 'smoke-test.sh'), 'utf8').match(/^BUDGET_SKILL_LISTING=(\d+)/m);
const budget = budgetLine ? Number(budgetLine[1]) : NaN;
if (!Number.isFinite(total) || !Number.isFinite(budget)) { console.error('improve: could not read the skill listing size or its budget; no limit, no rewrite'); process.exit(2); }
const chars = (s) => [...s.replace(/\n/g, '')].length;
const limit = chars(current) + Math.max(0, budget - total);

const promptOf = new Map(casesFor([skill]).map((c) => [c.id, c.prompt]));
const rows = (readResults() ?? []).filter((r) => r.skill === skill).map((r) => ({ ...r, prompt: promptOf.get(r.case) ?? '' }));
const train = rows.filter((r) => r.source === 'working');
const test = rows.filter((r) => r.source === 'holdout');
const floor = readBaseline();
if (!test.length) { console.error(`improve: ${skill} has no held-out row measured, so a candidate could not be judged; measure it first (run.mjs --skill ${skill})`); process.exit(2); }

// The prompt is the model's whole brief: it sees the skill's own body, the current description and the working rows,
// and is told the limit in characters. It is not shown the held-out prompts.
const caseText = (r) => {
  const p = (r.prompt ?? '').trim();
  return `- ${r.kind === 'not' ? 'must NOT pick this skill' : 'should pick this skill'}${p ? `: "${p}"` : ` (case ${r.case})`} — scored ${r.score.toFixed(3)}`;
};
const body = text.replace(/^---[\s\S]*?\n---\r?\n/, '').split('\n').slice(0, 60).join('\n');
const prompt = [
  'You are rewriting the description of one skill in a plugin. The description is the only text the model reads when',
  'it decides whether to load the skill for a request, so it has to say what the skill does and when it applies, in',
  'plain words a request would use. It is not a keyword list and not a sales line.',
  '',
  `Hard limit: ${limit} characters, line breaks not counted. Write English. Keep every capability the current text names.`,
  'Do not claim anything the skill body below does not do. Do not name other products or vendors.',
  '',
  `Current description (${chars(current)} characters):`, current, '',
  'How it scored on requests (1.000 = always right):', ...(train.length ? train.map(caseText) : ['- no working-set row measured']), '',
  'The skill body, first lines:', body, '',
  'Reply with the new description only: no preamble, no quotes, no markdown.',
].join('\n');

console.log(`improve: ${skill} · current ${chars(current)} chars · listing ${total}/${budget} · limit ${limit} chars`);
console.log(`  shown to the rewriter: ${train.length} working row(s) · held back as the test: ${test.length} held-out row(s)`);
for (const r of test) console.log(`    test ${r.case} ${r.kind} score ${r.score.toFixed(3)} floor ${floor.has(r.case) ? floor.get(r.case).toFixed(3) : 'none'}`);
if (dry) { console.log('\n--- prompt ---\n' + prompt); process.exit(0); }

const w = spawnSync('claude', ['-p', prompt, '--model', 'sonnet', '--output-format', 'text'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'] });
const cand = (w.stdout ?? '').trim().replace(/^["'`]+|["'`]+$/g, '');
if (w.status !== 0 || !cand) { console.error(`improve: the rewrite call failed (rc ${w.status}); nothing measured`); process.exit(2); }
if (chars(cand) > limit) { console.log(`improve: the candidate is ${chars(cand)} chars, over the ${limit} limit; dropped unmeasured\n${cand}`); process.exit(1); }

// Measure the candidate in a scratch worktree of this commit: rebuild the plugin there, run run.mjs there.
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'skill-improve-'));
const wt = path.join(scratch, 'tree');
let kept = false;
try {
  execFileSync('git', ['-C', ROOT, 'worktree', 'add', '--detach', '-q', wt, 'HEAD'], { stdio: 'ignore' });
  const target = path.join(wt, 'kit', 'skills', skill, 'SKILL.md');
  const block = 'description: |\n' + cand.split('\n').map((l) => '  ' + l).join('\n');
  const src = fs.readFileSync(target, 'utf8');
  const next = src.replace(/^(---\r?\n[\s\S]*?)^description:.*(?:\r?\n[ \t]+.*)*/m, (_, head) => head + block);
  if (next === src) throw new Error('the description could not be replaced in the scratch copy');
  fs.writeFileSync(target, next);
  execFileSync('bash', [path.join(wt, 'packaging', 'build-plugin.sh')], { cwd: wt, stdio: 'ignore' });
  const m = spawnSync('node', [path.join(wt, 'packaging', 'skill-eval', 'run.mjs'), '--skill', skill, ...(runs ? ['--runs', runs] : [])], { cwd: wt, stdio: 'inherit' });
  const after = (fs.existsSync(path.join(wt, 'packaging', 'skill-eval', 'results.tsv'))
    ? fs.readFileSync(path.join(wt, 'packaging', 'skill-eval', 'results.tsv'), 'utf8') : '').split(/\r?\n/)
    .filter((l) => l && !l.startsWith('#') && !l.startsWith('case\t')).map((l) => l.split('\t')).filter((f) => f[1] === skill);
  const score = new Map(after.map((f) => [f[0], { kind: f[2], source: f[3], score: Number(f[5]), worst: Number(f[6]) }]));
  const fails = [];
  for (const r of rows) {
    const s = score.get(r.case);
    if (!s) { fails.push(`${r.case}: not measured`); continue; }
    if (r.kind === 'not' && s.score < 1) fails.push(`${r.case}: a must-not-fire row scored ${s.score.toFixed(3)}`);
    if (r.source === 'holdout' && floor.has(r.case) && s.worst < floor.get(r.case)) fails.push(`${r.case}: worst ${s.worst.toFixed(3)} under its floor ${floor.get(r.case).toFixed(3)}`);
  }
  if (m.status !== 0) fails.push(`run.mjs ended rc ${m.status}`);
  kept = fails.length === 0;
  console.log(kept ? `\nimprove: KEEP — every held-out row at or above its floor, every must-not-fire row at 1.000.` : `\nimprove: DROP —\n  ${fails.join('\n  ')}`);
  for (const r of test) { const s = score.get(r.case); console.log(`    ${r.case} ${r.score.toFixed(3)} -> ${s ? s.score.toFixed(3) : 'not measured'}`); }
  console.log(`\ncandidate (${chars(cand)} chars)${kept ? `, to put in kit/skills/${skill}/SKILL.md and then run build-plugin.sh` : ''}:\n${cand}`);
} catch (e) {
  console.error(`improve: ${e.message}`);
} finally {
  try { execFileSync('git', ['-C', ROOT, 'worktree', 'remove', '--force', wt], { stdio: 'ignore' }); } catch { /* gone */ }
  fs.rmSync(scratch, { recursive: true, force: true });
}
process.exit(kept ? 0 : 1);
