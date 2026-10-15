#!/usr/bin/env node
// run.mjs — does Claude pick a skill from its description? Runs `claude plugin eval` on the cases of the skills
// whose description changed, and writes packaging/skill-eval/results.tsv for check.mjs to hold the change to.
//
//   node packaging/skill-eval/run.mjs [--base REF] [--skill NAME]... [--all] [--runs N] [--baseline] [--dry-run]
//       --base REF   the descriptions are compared with this ref (default origin/next)
//       --skill      measure these skills instead of the changed ones; --all measures every skill that has cases
//       --baseline   also raise baseline.tsv to each case's worst run (never lowers it; a partial run sets nothing)
//       --dry-run    write the cases and print the command; call no model
//
// THIS SPENDS REAL TOKENS (the user's own Claude Code session; no API key of the repository). It is run by hand,
// when a description changed, and never by CI: CI only reads the file it writes (check.mjs).
//
// Fixed, decided once (docs: the R3 decisions): the model is Sonnet, a run stops at $5 (--max-cost-usd: what had not
// run by then is not measured, and the file says partial), and the report is not published (--no-publish; the
// tool's default is to publish it to claude.ai). The plugin under test is a COPY of plugin/ with the cases added, so
// nothing of this reaches the shipped edition. Its hooks are on: what is measured is what a user gets.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { ROOT, RESULTS, BASELINE, RESULT_COLUMNS, skillsAt, changedSince, casesFor, commandSkills, hashOf, readBaseline } from './lib.mjs';

const MODEL = 'sonnet';
const MAX_COST_USD = '5';
const MAX_TURNS = 6;

const args = process.argv.slice(2);
const opt = (k) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : null; };
const base = opt('--base') ?? 'origin/next';
const runs = opt('--runs');
const dry = args.includes('--dry-run');
const commands = commandSkills();
const named = args.flatMap((a, i) => (a === '--skill' ? [args[i + 1]] : []));
const now = skillsAt(null);
let skills = args.includes('--all') ? [...now.keys()] : named.length ? named : changedSince(base);
const asked = skills.length;
skills = skills.filter((s) => !commands.has(s));
const cases = casesFor(skills);
if (!skills.length) {
  console.log(asked ? 'skill-eval: only commands were named; a command is called by name, not picked from its description'
    : `skill-eval: no description changed against ${base}; nothing to measure`);
  process.exit(0);
}
const without = skills.filter((s) => !cases.some((c) => c.skill === s));
if (without.length) {
  console.error(`skill-eval: no routing row measures ${without.join(', ')}: add a held-out row (kit/eval/golden-holdout.txt) first`);
  process.exit(1);
}

// The plugin under test: plugin/ as built, copied, with the cases beside it.
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'skill-eval-'));
const plug = path.join(work, 'plugin');
fs.cpSync(path.join(ROOT, 'plugin'), plug, { recursive: true });
for (const c of cases) {
  const dir = path.join(plug, 'evals', c.id, 'graders');
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(plug, 'evals', c.id, 'prompt.md'),
    `---\nmax_turns: ${MAX_TURNS}\nallowed_tools: [Read, Glob, Grep, Skill]\ntags: [${c.skill}]\n---\n\n${c.prompt}\n`);
  // The skill by its name, or by its namespaced plugin:name form. A `!` row passes when it was never invoked.
  const match = `'"skill"\\s*:\\s*"(?:[\\w-]+:)?${c.skill}"'`;
  fs.writeFileSync(path.join(dir, 'skill.md'),
    `---\ntype: tool_used\ntool: Skill\ninput_match: ${match}\n${c.negative ? 'min: 0\nmax: 0\n' : 'min: 1\n'}---\n`);
}
const out = path.join(work, 'result.json');
const cmd = ['plugin', 'eval', plug, '--model', MODEL, '--max-cost-usd', MAX_COST_USD, '--no-publish', '--trust-plugin',
  '--ablation', 'none', '--threshold', '0', '--json', out, ...(runs ? ['--runs', runs] : [])];
console.log(`skill-eval: ${skills.length} skill(s), ${cases.length} case(s) (${cases.filter((c) => c.negative).length} must not fire) in ${plug}`);
console.log(`  claude ${cmd.join(' ')}`);
if (dry) process.exit(0);

const r = spawnSync('claude', cmd, { stdio: ['ignore', 'inherit', 'inherit'] });
let doc = null;
try { doc = JSON.parse(fs.readFileSync(out, 'utf8')); } catch { /* reported below */ }
if (!doc) { console.error(`skill-eval: no result was written (claude rc ${r.status}); nothing recorded`); process.exit(2); }

// One line per case. A case the run did not reach (partial) is left out, so check.mjs sees it as not measured.
const byId = new Map(cases.map((c) => [c.id, c]));
const lines = [];
for (const k of doc.cases ?? []) {
  const c = byId.get(k.name);
  if (!c || typeof k.aggregates?.score !== 'number') continue;
  // A run that ended on an API error scores 0 with no grader result: that is no measurement, and it is not counted.
  const good = (k.arms?.with ?? []).filter((x) => !x.skippedPaidGraders && typeof x.score === 'number' && (x.graders ?? []).length);
  if (!good.length) continue;
  const mean = good.reduce((a, x) => a + x.score, 0) / good.length;
  const worst = Math.min(...good.map((x) => x.score));
  lines.push([c.id, c.skill, c.negative ? 'not' : 'is', c.source, hashOf(now.get(c.skill)), mean.toFixed(3), worst.toFixed(3), good.length].join('\t'));
}
const head = [
  '# Written by packaging/skill-eval/run.mjs; read by check.mjs. One line per case: does the description pick the',
  `# skill (kind is) or keep away from a neighbour's request (kind not). claude ${doc.claudeVersion ?? '?'} · model ${MODEL} ·`,
  `# cost ~$${Number(doc.costUsd ?? 0).toFixed(2)} at list price · ${doc.partial ? `PARTIAL (${doc.partialReason})` : 'complete'}`,
  RESULT_COLUMNS.join('\t'),
];
// The lines of skills not measured this time are kept: the file holds the latest measurement of every skill.
const keep = fs.existsSync(RESULTS) ? fs.readFileSync(RESULTS, 'utf8').split(/\r?\n/)
  .filter((l) => l && !l.startsWith('#') && !l.startsWith('case\t') && !skills.includes(l.split('\t')[1])) : [];
fs.writeFileSync(RESULTS, [...head, ...[...keep, ...lines].sort()].join('\n') + '\n');
// --baseline: raise each measured case's floor to its worst run, never lower it. Only on a complete run.
if (args.includes('--baseline') && !doc.partial) {
  const floor = readBaseline();
  for (const l of lines) { const f = l.split('\t'); const w = Number(f[6]); if (!(floor.get(f[0]) >= w)) floor.set(f[0], w); }
  fs.writeFileSync(BASELINE, ['# The floor of each case (its worst run when it was set). Only raised: run.mjs --baseline.', 'case\tfloor',
    ...[...floor].sort((a, b) => a[0].localeCompare(b[0])).map(([c, w]) => `${c}\t${w.toFixed(3)}`)].join('\n') + '\n');
  console.log(`skill-eval: baseline raised where a case's worst run was above its floor (${path.relative(ROOT, BASELINE)})`);
}
console.log(`skill-eval: ${lines.length} of ${cases.length} case(s) recorded in ${path.relative(ROOT, RESULTS)}${doc.partial ? ' — PARTIAL, the rest is not measured' : ''}`);
process.exit(doc.partial || lines.length < cases.length ? 2 : 0);
