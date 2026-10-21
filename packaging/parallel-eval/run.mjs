#!/usr/bin/env node
// run.mjs — D1: is the same work cheaper, faster or cleaner with parallel owners than with one?
//
//   node packaging/parallel-eval/run.mjs --all [--runs 3] [--cap 50] [--out DIR]
//   node packaging/parallel-eval/run.mjs --task notes-cli --arm parallel [--cap 50] [--out DIR]
//   node packaging/parallel-eval/run.mjs --dry-run                       prepare one project, call no model
//
// THIS SPENDS REAL TOKENS, the user's own session (claude -p). Run by hand, never by CI.
//
// Each run starts from a task's seed, as a git repository with Crewforth installed (start.sh). Then:
//   single    one claude -p session is given the whole task
//   parallel  a planning session splits it into parts that touch disjoint files (crew-planner), each part runs in
//             its own git worktree at the same time, and the parts are merged into the base in order; a conflict is
//             counted and handed to one more session to resolve
// Both arms then run the project's tests (node --test), and one review session (crew-review-agent) lists findings.
// Recorded per run, one JSON line in DIR/results.jsonl: wall time of the work (review excluded), its cost and the
// review's (each claude -p reports total_cost_usd), merge conflicts, tests, findings by severity.
//
// The cap is checked before every session and handed to it (--max-budget-usd, what is left): past it, nothing
// more starts, and the run is recorded as partial. Main threads run on Sonnet in both arms, so the arms differ in
// how the work is organised and nothing else.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '..', '..');
const TASKS = fs.readdirSync(path.join(HERE, 'tasks')).filter((t) => fs.existsSync(path.join(HERE, 'tasks', t, 'task.md'))).sort();
const MODEL = 'sonnet';
const TOOLS = ['Bash(node:*)', 'Bash(npm test:*)', 'Bash(git diff:*)', 'Bash(git status:*)', 'Bash(git log:*)', 'Read', 'Edit', 'Write', 'Glob', 'Grep', 'Agent'];

const args = process.argv.slice(2);
const opt = (k, d = null) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d; };
const CAP = Number(opt('--cap', 50));
const RUNS = Number(opt('--runs', 3));
const OUT = path.resolve(opt('--out', path.join(os.tmpdir(), 'parallel-eval')));
fs.mkdirSync(OUT, { recursive: true });
const LEDGER = path.join(OUT, 'results.jsonl');

let spent = 0;
const done = new Set();   // task/arm/run already in the ledger: --all does not run them again
if (fs.existsSync(LEDGER)) for (const l of fs.readFileSync(LEDGER, 'utf8').split('\n').filter(Boolean)) { try { const r = JSON.parse(l); spent += (r.cost ?? 0) + (r.reviewCost ?? 0); done.add(`${r.task}/${r.arm}/${r.run}`); } catch { /* skip */ } }

const git = (cwd, ...a) => spawnSync('git', ['-C', cwd, ...a], { encoding: 'utf8' });
const sh = (cwd, cmd, a, input) => spawnSync(cmd, a, { cwd, encoding: 'utf8', input, env: { ...process.env, CREW_NO_STAR: '1' } });

/** A fresh project: the task's seed, committed, with Crewforth installed and committed. */
function prepare(task, where) {
  const p = path.join(where, task);
  fs.cpSync(path.join(HERE, 'tasks', task, 'seed'), p, { recursive: true });
  git(p, 'init', '-q', '.'); git(p, 'config', 'user.email', 'eval@example.invalid'); git(p, 'config', 'user.name', 'eval');
  git(p, 'add', '-A'); git(p, 'commit', '-qm', 'seed');
  for (const f of ['start.sh', 'VERSION']) fs.copyFileSync(path.join(REPO, f), path.join(p, f));
  fs.cpSync(path.join(REPO, 'kit'), path.join(p, 'kit'), { recursive: true });
  const env = { ...process.env, CREW_NO_STAR: '1' }; delete env.CI;
  const r = spawnSync('bash', ['start.sh'], { cwd: p, input: 'yes\n', encoding: 'utf8', env });
  if (r.status !== 0) throw new Error(`start.sh failed in ${p}: ${(r.stderr || r.stdout).slice(-400)}`);
  git(p, 'add', '-A'); git(p, 'commit', '-qm', 'crewforth', '--no-verify');
  return p;
}

/** One claude -p session, its JSON result, its cost; refused when the cap is reached. */
function claude(cwd, prompt) {
  return new Promise((resolve) => {
    const left = CAP - spent;
    if (left <= 0.5) { resolve({ skipped: true, cost: 0, text: '' }); return; }
    const a = ['-p', prompt, '--output-format', 'json', '--model', MODEL, '--permission-mode', 'acceptEdits',
      '--max-budget-usd', String(Math.min(10, left).toFixed(2)), '--allowedTools', ...TOOLS];
    const c = spawn('claude', a, { cwd, env: { ...process.env, CREW_NO_STAR: '1' }, stdio: ['ignore', 'pipe', 'pipe'] });
    let out = ''; c.stdout.on('data', (d) => { out += d; });
    c.on('close', (code) => {
      let j = null; try { j = JSON.parse(out); } catch { /* none */ }
      const cost = Number(j?.total_cost_usd ?? 0);
      spent += cost;
      resolve({ code, cost, text: String(j?.result ?? ''), error: j?.is_error ? (j.subtype ?? 'error') : null });
    });
  });
}

const tests = (p) => { const r = sh(p, 'node', ['--test']); return { pass: r.status === 0, out: (r.stdout || '').split('\n').filter((l) => /^ℹ (pass|fail) /.test(l)).join(' ') }; };

async function review(p, base) {
  const r = await claude(p, `Use crew-review-agent to review the change from commit ${base} to the working tree (git diff ${base}). Do not edit anything. End your answer with one line of JSON and nothing after it: {"findings":[{"severity":"critical|high|medium|low","title":"..."}]}`);
  let f = []; const m = r.text.match(/\{"findings":\s*\[[\s\S]*\]\}\s*$/);
  if (m) { try { f = JSON.parse(m[0]).findings ?? []; } catch { /* unread */ } }
  const by = {}; for (const x of f) by[x.severity] = (by[x.severity] ?? 0) + 1;
  return { cost: r.cost, findings: by, read: Boolean(m), skipped: Boolean(r.skipped) };
}

async function single(task, n) {
  const p = prepare(task, fs.mkdtempSync(path.join(OUT, `${task}-single-${n}-`)));
  const base = git(p, 'rev-parse', 'HEAD').stdout.trim();
  const brief = fs.readFileSync(path.join(HERE, 'tasks', task, 'task.md'), 'utf8');
  const t0 = Date.now();
  const r = await claude(p, `${brief}\nDo all of it in this checkout. Run the tests with \`node --test\` until they pass. Do not commit.`);
  const wall = Date.now() - t0;
  const t = tests(p);
  const rv = await review(p, base);
  return { task, arm: 'single', run: n, wallMs: wall, cost: r.cost, sessions: 1, conflicts: 0, testsPass: t.pass, tests: t.out, findings: rv.findings, reviewRead: rv.read, reviewCost: rv.cost, partial: Boolean(r.skipped || rv.skipped), error: r.error };
}

async function parallel(task, n) {
  const p = prepare(task, fs.mkdtempSync(path.join(OUT, `${task}-parallel-${n}-`)));
  const base = git(p, 'rev-parse', 'HEAD').stdout.trim();
  const brief = fs.readFileSync(path.join(HERE, 'tasks', task, 'task.md'), 'utf8');
  const t0 = Date.now(); let cost = 0; let sessions = 0; let partial = false;
  const plan = await claude(p, `${brief}\nUse crew-planner to split this work into 2 or 3 parts that owners will do AT THE SAME TIME in separate checkouts, so each part should touch files no other part touches. Edit nothing. End your answer with one line of JSON and nothing after it: {"parts":[{"name":"short-name","files":["..."],"prompt":"the full instruction for that owner"}]}`);
  cost += plan.cost; sessions += 1; partial ||= Boolean(plan.skipped);
  let parts = []; const m = plan.text.match(/\{"parts":\s*\[[\s\S]*\]\}\s*$/);
  if (m) { try { parts = JSON.parse(m[0]).parts ?? []; } catch { /* unread */ } }
  if (!parts.length) return { task, arm: 'parallel', run: n, wallMs: Date.now() - t0, cost, sessions, conflicts: null, testsPass: false, tests: '', findings: {}, reviewCost: 0, partial: true, error: 'the plan could not be read' };
  const trees = parts.map((x, i) => { const w = `${p}-part${i}`; git(p, 'worktree', 'add', '-q', '-b', `part${i}`, w, base); return w; });
  const ran = await Promise.all(parts.map((x, i) => claude(trees[i], `${x.prompt}\nTouch only: ${(x.files ?? []).join(', ') || 'the files this part needs'}. Run the tests with \`node --test\`. Do not commit.`)));
  for (const d of ran) { cost += d.cost; sessions += 1; partial ||= Boolean(d.skipped); }
  let conflicts = 0; const conflicted = [];
  for (const [i, w] of trees.entries()) {
    git(w, 'add', '-A'); git(w, 'commit', '-qm', `part ${i}`, '--no-verify');
    const mg = git(p, 'merge', '--no-edit', '-q', `part${i}`);
    if (mg.status !== 0) {
      conflicts += 1; conflicted.push(...git(p, 'diff', '--name-only', '--diff-filter=U').stdout.split('\n').filter(Boolean));
      const fix = await claude(p, 'A git merge stopped on conflicts. Resolve every conflict so the work of both sides is kept, run `node --test` until it passes, and stage the result with no commit (git add is done for you after). Do not commit.');
      cost += fix.cost; sessions += 1; partial ||= Boolean(fix.skipped);
      git(p, 'add', '-A'); git(p, 'commit', '-qm', `merge part ${i}`, '--no-verify');
    }
  }
  const wall = Date.now() - t0;
  const t = tests(p);
  const rv = await review(p, base);
  return { task, arm: 'parallel', run: n, wallMs: wall, cost, sessions, parts: parts.length, conflicts, conflicted, testsPass: t.pass, tests: t.out, findings: rv.findings, reviewRead: rv.read, reviewCost: rv.cost, partial: partial || rv.skipped, error: null };
}

async function one(task, arm, n) {
  const r = arm === 'single' ? await single(task, n) : await parallel(task, n);
  fs.appendFileSync(LEDGER, `${JSON.stringify({ ...r, at: new Date().toISOString(), spentSoFar: Number(spent.toFixed(4)) })}\n`);
  console.log(`${task} ${arm} #${n}: ${(r.wallMs / 1000).toFixed(0)} s · $${r.cost.toFixed(2)} (+$${(r.reviewCost ?? 0).toFixed(2)} review) · conflicts ${r.conflicts} · tests ${r.testsPass ? 'pass' : 'FAIL'} · findings ${JSON.stringify(r.findings)}${r.partial ? ' · PARTIAL' : ''} · spent $${spent.toFixed(2)} of $${CAP}`);
}

if (args.includes('--dry-run')) {
  const p = prepare(TASKS[0], fs.mkdtempSync(path.join(OUT, 'dry-')));
  const t = tests(p);
  console.log(`prepared ${p}: Crewforth ${fs.existsSync(path.join(p, '.claude', 'settings.json')) ? 'installed' : 'MISSING'}, tests ${t.pass ? 'pass' : 'FAIL'} (${t.out}); tasks: ${TASKS.join(', ')}; spent so far $${spent.toFixed(2)} of $${CAP}`);
} else if (args.includes('--all')) {
  // Interleaved, so time of day and the account's load fall on both arms alike.
  for (let n = 1; n <= RUNS; n += 1) for (const task of TASKS) for (const arm of ['single', 'parallel']) {
    if (done.has(`${task}/${arm}/${n}`)) continue;
    if (CAP - spent <= 0.5) { console.log(`cap reached: $${spent.toFixed(2)} of $${CAP}; nothing more starts`); process.exit(0); }
    await one(task, arm, n);
  }
} else {
  await one(opt('--task', TASKS[0]), opt('--arm', 'single'), Number(opt('--run', 1)));
}
