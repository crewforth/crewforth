#!/usr/bin/env node
// bench.mjs — how right the review is, in numbers: run labelled cases, match what was found to where the defect
// is, and say the precision, the recall and every false alarm by name.
//
//   node bench.mjs --cases DIR [--arm prepass|agent] [--split all|train|holdout] [--only id,id]
//                  [--model sonnet] [--advisor opus] [--case-budget 0.75] [--max-cost 12] [--floors FILE] [--out FILE]
//                  [--no-tools]
//       --no-tools  the pre-pass runs without shellcheck, so its numbers do not depend on what the machine has
//                   installed (the gate in CI uses it; shellcheck's own precision is not part of the floors)
//   rc 0 = ran (and, with --floors, at or above every floor) · 1 = below a floor, or the agent arm could not run a
//   case · 2 = usage
//
// A CASE is a directory: case.json, before/ and after/ (the touched files only, with their modes in case.json).
// It is built as a git repository with `before` committed and `after` staged, so a reviewer meets it the way it
// meets real work: `git diff --cached`. case.json says what the change claims to do (`intent`, the only thing the
// reviewer is told) and where the defect is (`expect`: file and line range in the after side; a null range is a
// file-level defect, a mode bit). A clean case expects nothing.
//
// SCORING. A finding matches an expected location when it cites the same file within three lines of the range
// (any line, for a file-level defect). A defect case is CAUGHT when any finding matches any of its locations:
// one defect is one defect, however many hunks its fix took. Recall = caught / defect cases. Precision =
// matching findings / all findings of severity low or above (info is a note, not a claim). Every finding that
// matches nothing is listed as a false alarm with its case, line and title.
//
// A defect case made by undoing a fix can show the fix's own explanation among the removed lines. That is what a
// reviewer of a real revert would see too, but it is a hint, so such cases are marked and recall is reported for
// both halves.
//
// ARMS. prepass: kit/eval/lib/review-prepass, in process, no model. agent: Claude Code headless, the session run
// AS crew-review-agent (--agent) with Crewforth's review agent, skills and eval/lib copied into the case's .claude/,
// on --model, each case capped by --case-budget and the run by --max-cost (it stops before a case that could pass
// it). The agent arm scores what it wrote to .crewforth/review.json together with the pre-pass it was told to carry
// over; when it wrote no valid file, its final answer's `file:line · severity` lines are read instead, and the
// result says so. It runs one review pass: the refuter is not installed in the case, so nothing is --verified.
//
// --advisor MODEL runs the agent arm with that advisor (the `advisorModel` setting, passed with --settings; the user's
// own settings are not read). What a run cost is the result's own total, which counts the advisor's calls; each row
// also carries the cost and tokens by model (the result's modelUsage) and how many advisor calls were made.
//
// A TASK is a case of `kind: "task"`: an implementation, not a review. before/ is the repository, `intent` is what
// the session is asked to do, check/ is copied in only after the session has ended and `check` (argv, run in the
// repository) grades it: rc 0 is done. The session runs as itself, not as the review agent.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { prepass } from '../review-prepass/prepass.mjs';
import { validate } from '../findings/findings.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const KIT = path.resolve(HERE, '..', '..', '..');   // kit/ (source) or .claude/ (installed)
const NEAR = 3;
const RANK = { info: 0, low: 1, medium: 2, high: 3, critical: 4 };
const TOKEN = `ghp_${'R3v1'.repeat(9)}`;

function args(argv) {
  const o = { arm: 'prepass', split: 'all', model: 'sonnet', advisor: null, caseBudget: 0.75, maxCost: 12 };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]; const v = () => { const x = argv[++i]; if (x === undefined) throw new Error(`${a} needs a value`); return x; };
    if (a === '--cases') o.cases = v(); else if (a === '--arm') o.arm = v(); else if (a === '--split') o.split = v();
    else if (a === '--only') o.only = v().split(','); else if (a === '--model') o.model = v(); else if (a === '--advisor') o.advisor = v();
    else if (a === '--case-budget') o.caseBudget = Number(v()); else if (a === '--max-cost') o.maxCost = Number(v());
    else if (a === '--floors') o.floors = v(); else if (a === '--out') o.out = v(); else if (a === '--no-tools') o.noTools = true;
    else throw new Error(`unknown argument ${a}`);
  }
  if (!o.cases || !['prepass', 'agent'].includes(o.arm) || !['all', 'train', 'holdout'].includes(o.split)) throw new Error('--cases DIR is required; --arm prepass|agent; --split all|train|holdout');
  return o;
}

export function loadCases(dir, { split = 'all', only = null } = {}) {
  return fs.readdirSync(dir).sort().filter((d) => fs.existsSync(path.join(dir, d, 'case.json')))
    .map((d) => ({ ...JSON.parse(fs.readFileSync(path.join(dir, d, 'case.json'), 'utf8')), dir: path.join(dir, d) }))
    .filter((c) => (split === 'all' || (split === 'holdout') === !!c.holdout) && (!only || only.includes(c.id)));
}

const ENV = (tmp) => ({ ...process.env, GIT_CONFIG_GLOBAL: path.join(tmp, 'gitconfig'), GIT_CONFIG_NOSYSTEM: '1' });
function git(root, env, ...a) { const r = spawnSync('git', ['-C', root, ...a], { encoding: 'utf8', env }); if (r.status !== 0) throw new Error(`git ${a.join(' ')}: ${r.stderr}`); return r.stdout; }
// A folder a build writes (bin, dist, …) is stored with a leading '=' inside a case, so a repository's own commit
// gates do not read a case's past source file as a build artifact; the case is built under the real name.
const BUILD_DIRS = new Set(['node_modules', 'bower_components', 'dist', 'build', 'out', 'target', 'bin', 'obj', 'vendor', 'coverage']);
export const storedPath = (p) => p.split('/').map((s, i, a) => (i < a.length - 1 && BUILD_DIRS.has(s) ? `=${s}` : s)).join('/');
export const realPath = (p) => p.split('/').map((s) => (s.startsWith('=') && BUILD_DIRS.has(s.slice(1)) ? s.slice(1) : s)).join('/');
function tree(dir) { const out = []; const walk = (d) => { if (!fs.existsSync(d)) return; for (const e of fs.readdirSync(d, { withFileTypes: true })) { const p = path.join(d, e.name); if (e.isDirectory()) walk(p); else out.push(path.relative(dir, p).split(path.sep).join('/')); } }; walk(dir); return out.sort(); }

// The case as a repository: before committed, after staged. Returns { root, env, diff }.
export function build(c, tmp) {
  const root = path.join(tmp, c.id); fs.mkdirSync(root, { recursive: true });
  fs.writeFileSync(path.join(tmp, 'gitconfig'), '[user]\n\tname = bench\n\temail = bench@bench.invalid\n[core]\n\tautocrlf = false\n\tfileMode = true\n[init]\n\tdefaultBranch = main\n');
  const env = ENV(tmp);
  const put = (side) => {
    for (const s of tree(path.join(c.dir, side))) {
      const f = realPath(s);
      const out = path.join(root, f); fs.mkdirSync(path.dirname(out), { recursive: true });
      fs.writeFileSync(out, fs.readFileSync(path.join(c.dir, side, s), 'utf8').replaceAll('{{TOKEN}}', TOKEN));
      fs.chmodSync(out, c.modes?.[side]?.[f] === '100755' ? 0o755 : 0o644);
    }
  };
  git(root, env, 'init', '-q', '.');
  put('before'); git(root, env, 'add', '-A'); git(root, env, 'commit', '-qm', 'base', '--allow-empty');
  if (c.kind !== 'task') {
    for (const s of tree(path.join(c.dir, 'before'))) if (!fs.existsSync(path.join(c.dir, 'after', s))) fs.rmSync(path.join(root, realPath(s)));
    put('after'); git(root, env, 'add', '-A');
  }
  fs.appendFileSync(path.join(root, '.git', 'info', 'exclude'), '.claude/\n.crewforth/\n');
  const diff = git(root, env, 'diff', '--cached', '--no-ext-diff', '-U3');
  return { root, env, diff };
}

// Whether the removed lines of the diff carry a comment: the fix's own explanation, visible to the reviewer.
export const hintInDiff = (diff) => diff.split('\n').some((l) => /^-(?!--)\s*(#|\/\/|\/\*|\*)\s*\S/.test(l) && !/^-\s*#!/.test(l));

export function score(c, findings) {
  const claims = findings.filter((f) => (RANK[f.severity] ?? 1) >= RANK.low);
  const hits = (f) => (c.expect ?? []).some((e) => e.file === f.file && (e.from == null || (f.line >= e.from - NEAR && f.line <= e.to + NEAR)));
  const matched = claims.filter(hits);
  return { caught: c.kind === 'defect' ? findings.some(hits) : null, claims: claims.length, matched: matched.length,
    falseAlarms: claims.filter((f) => !hits(f)).map((f) => ({ case: c.id, file: f.file, line: f.line, severity: f.severity, title: f.title })) };
}

const flat = (doc) => (doc?.findings ?? []).map((f) => ({ file: f.evidence?.[0]?.file, line: f.evidence?.[0]?.line, severity: f.severity ?? 'low', title: f.title, rule: f.rule }));
// `file:line · severity · …` lines of a final answer, for a review that wrote no file.
export const fromText = (text) => [...String(text).matchAll(/([\w./-]+\.[\w]+):(\d+)\s*[·|-]\s*(critical|high|medium|low|info)\b[^\n]*/gi)]
  .map((m) => ({ file: m[1].replace(/^\.\//, ''), line: Number(m[2]), severity: m[3].toLowerCase(), title: m[0].slice(0, 160) }));

function copyKit(root) {
  const dst = path.join(root, '.claude');
  const parts = [['agents/crew-review-agent.md'], ['skills/crew-code-review'], ['skills/docs-writer'], ['eval/lib/review-prepass'], ['eval/lib/findings'], ['eval/lib/crew-map'], ['hooks/secret-blocklist.txt']];
  for (const [p] of parts) { const s = path.join(KIT, p); if (fs.existsSync(s)) fs.cpSync(s, path.join(dst, p), { recursive: true }); }
}

// The flags every headless run shares. The bench measures the model and Crewforth, not the machine it runs on: no
// user settings (an advisor model, hooks), no MCP server of the user's, no session written. Seen without them: a run
// took the user's advisor model, and the process stayed alive after its answer. An advisor is the arm's own choice.
function claudeArgs(prompt, o, tools) {
  return ['-p', prompt, '--model', o.model, '--output-format', 'stream-json', '--verbose',
    '--permission-mode', 'bypassPermissions', '--allowedTools', tools, '--max-budget-usd', String(o.caseBudget),
    '--setting-sources', 'project,local', '--strict-mcp-config', '--no-session-persistence',
    ...(o.advisor ? ['--settings', JSON.stringify({ advisorModel: o.advisor })] : [])];
}

// The result event, what each model cost (modelUsage counts the advisor's calls under the advisor's model), and the
// advisor calls themselves. Measured on a headless run: an assistant event's usage carries no `iterations`; a call is
// a `server_tool_use` block named `advisor` in the message's content, so those are counted, once per block id.
export function readRun(stdout) {
  let res = null; const seen = new Set();
  for (const l of String(stdout || '').split('\n')) {
    let e; try { e = JSON.parse(l); } catch { continue; }
    if (e.type === 'result') res = e;
    if (e.type === 'assistant' && Array.isArray(e.message?.content)) {
      for (const c of e.message.content) if (c?.type === 'server_tool_use' && c.name === 'advisor' && c.id) seen.add(c.id);
    }
  }
  const advisorCalls = seen.size;
  const byModel = Object.fromEntries(Object.entries(res?.modelUsage ?? {}).map(([k, u]) => [k, { cost: Number(u.costUSD ?? 0),
    input: u.inputTokens ?? 0, output: u.outputTokens ?? 0, cacheRead: u.cacheReadInputTokens ?? 0, cacheWrite: u.cacheCreationInputTokens ?? 0 }]));
  return { res, byModel, advisorCalls };
}

const runFields = ({ res, byModel, advisorCalls }) => ({
  cost: Number(res?.total_cost_usd ?? 0), turns: res?.num_turns ?? null, ms: res?.duration_ms ?? null, byModel, advisorCalls,
  tokens: res?.usage ? { input: res.usage.input_tokens, output: res.usage.output_tokens, cacheRead: res.usage.cache_read_input_tokens, cacheWrite: res.usage.cache_creation_input_tokens } : null });
const runError = (res, r) => (!res ? `no result event (rc ${r.status}${r.error ? `, ${r.error.code}` : ''})` : (res.is_error ? (res.subtype || 'error') : null));
// The CLI. CREW_BENCH_CLAUDE names a node script that stands in for it (the selfcheck's fake, on every platform: a
// script called `claude` cannot be spawned on Windows without a shell).
const claude = (args, opts) => (process.env.CREW_BENCH_CLAUDE
  ? spawnSync(process.execPath, [process.env.CREW_BENCH_CLAUDE, ...args], opts) : spawnSync('claude', args, opts));
const SPAWN = (b) => ({ cwd: b.root, encoding: 'utf8', env: b.env, maxBuffer: 256 << 20, timeout: 12 * 60 * 1000, killSignal: 'SIGKILL', input: '' });

// A task: the session does the work, then the check it never saw grades it.
function runTask(c, b, o) {
  const r = claude(claudeArgs(c.intent, o, 'Bash Read Grep Glob Edit Write'), SPAWN(b));
  const run = readRun(r.stdout);
  if (fs.existsSync(path.join(c.dir, 'check'))) fs.cpSync(path.join(c.dir, 'check'), b.root, { recursive: true });
  const [cmd, ...rest] = c.check ?? [];
  const k = cmd ? spawnSync(cmd, rest, { cwd: b.root, encoding: 'utf8', env: b.env, timeout: 120000 }) : null;
  const tail = `${k?.stdout ?? ''}${k?.stderr ?? ''}`.trim().split('\n').slice(-3).join(' | ');
  return { findings: [], source: 'check', done: !!k && k.status === 0, check: k ? `rc ${k.status}${tail ? ` · ${tail.slice(0, 200)}` : ''}` : 'no check',
    ...runFields(run), error: runError(run.res, r) };
}

function runAgent(c, b, o) {
  copyKit(b.root);
  const prompt = `files: the staged change (git diff --cached)\nchange: audit\nverify: none\n\n`
    + `Review the staged change. Its author says: "${c.intent}". Follow crew-code-review: run the pre-pass first `
    + `(bash .claude/eval/lib/review-prepass/prepass.sh), carry its findings over, then write your own findings to `
    + `.crewforth/review.json with bash .claude/eval/lib/findings/findings.sh write review <file> (the refuter is `
    + `not installed here, so write without --verified). Change no other file. End with your findings in the format `
    + `file:line · severity · category · observation · what to do instead.`;
  const r = claude(['--agent', 'crew-review-agent', ...claudeArgs(prompt, o, 'Bash Read Grep Glob Write')], SPAWN(b));
  const run = readRun(r.stdout); const { res } = run;
  const read = (n) => { try { return JSON.parse(fs.readFileSync(path.join(b.root, '.crewforth', `${n}.json`), 'utf8')); } catch { return null; } };
  const review = read('review'); const pre = read('review-prepass');
  const reviewOk = !!review && validate(review, b.root).ok;
  const own = reviewOk ? flat(review) : fromText(res?.result ?? '');
  const seen = new Set(); const all = [];
  for (const f of [...own, ...flat(pre)]) { const k = `${f.file}:${f.line}:${f.rule ?? f.title}`; if (f.file && f.line && !seen.has(k)) { seen.add(k); all.push(f); } }
  return { findings: all, source: reviewOk ? 'review.json' : 'final answer', prepassRan: !!pre, ...runFields(run), error: runError(res, r) };
}

export function run(o) {
  const cases = loadCases(o.cases, o);
  const tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'crew-bench-')));
  const rows = []; let spent = 0;
  try {
    for (const c of cases) {
      if (o.arm === 'agent' && spent + o.caseBudget > o.maxCost) { rows.push({ id: c.id, skipped: `the run's cap ($${o.maxCost}) would be passed` }); continue; }
      const b = build(c, tmp);
      let out;
      if (c.kind === 'task') {
        if (o.arm !== 'agent') { rows.push({ id: c.id, kind: c.kind, skipped: 'a task needs the agent arm' }); continue; }
        out = runTask(c, b, o); spent += out.cost;
      }
      else if (o.arm === 'prepass') {
        const keep = process.env.CREW_SHELLCHECK; if (o.noTools) process.env.CREW_SHELLCHECK = path.join(tmp, 'no-shellcheck');
        try { out = { findings: flat(prepass(b.root)), source: 'prepass' }; } finally { if (o.noTools) { if (keep === undefined) delete process.env.CREW_SHELLCHECK; else process.env.CREW_SHELLCHECK = keep; } }
      }
      else { out = runAgent(c, b, o); spent += out.cost; }
      rows.push({ id: c.id, kind: c.kind, stratum: c.stratum, holdout: !!c.holdout, hint: c.kind === 'defect' ? hintInDiff(b.diff) : null, ...out, ...score(c, out.findings) });
    }
  } finally { fs.rmSync(tmp, { recursive: true, force: true }); }
  return summarise(rows, o, spent);
}

export function summarise(rows, o, spent = 0) {
  const done = rows.filter((r) => !r.skipped);
  const defects = done.filter((r) => r.kind === 'defect'); const tasks = done.filter((r) => r.kind === 'task');
  const pct = (a, b) => (b ? Math.round((1000 * a) / b) / 10 : null);
  const rec = (list) => ({ caught: list.filter((r) => r.caught).length, of: list.length, pct: pct(list.filter((r) => r.caught).length, list.length) });
  const claims = done.reduce((s, r) => s + r.claims, 0); const matched = done.reduce((s, r) => s + r.matched, 0);
  const sum = (k) => done.reduce((n, r) => n + (Number(r[k]) || 0), 0);
  return { arm: o.arm, model: o.arm === 'agent' ? o.model : null, advisor: o.arm === 'agent' ? o.advisor ?? null : null, split: o.split, cases: rows.length, ran: done.length,
    tasks: { done: tasks.filter((r) => r.done).length, of: tasks.length }, ms: sum('ms'), advisorCalls: sum('advisorCalls'),
    recall: rec(defects), recallNoHint: rec(defects.filter((r) => !r.hint)), recallHint: rec(defects.filter((r) => r.hint)),
    byStratum: Object.fromEntries(['pattern', 'judgement'].map((s) => [s, rec(defects.filter((r) => r.stratum === s))])),
    precision: { matched, of: claims, pct: pct(matched, claims) },
    falseAlarms: done.flatMap((r) => r.falseAlarms), cost: Math.round(spent * 100) / 100, errors: done.filter((r) => r.error).map((r) => `${r.id}: ${r.error}`), rows };
}

function main(argv) {
  let o; try { o = args(argv); } catch (e) { console.error(`review-bench: ${e.message}`); return 2; }
  if (o.arm === 'agent' && claude(['--version'], { encoding: 'utf8' }).status !== 0) { console.error('review-bench: the claude CLI does not run here; the agent arm needs it'); return 2; }
  const s = run(o);
  const line = (n, x) => `${n} ${x.caught}/${x.of}${x.pct === null ? '' : ` (${x.pct}%)`}`;
  console.log(`review-bench · arm ${s.arm}${s.model ? ` (${s.model}${s.advisor ? ` + ${s.advisor} advisor` : ''})` : ''} · split ${s.split} · ${s.ran}/${s.cases} cases`);
  console.log(`  ${line('recall', s.recall)} · ${line('without a hint', s.recallNoHint)} · ${line('with one', s.recallHint)}`);
  console.log(`  ${line('pattern', s.byStratum.pattern)} · ${line('judgement', s.byStratum.judgement)}`);
  console.log(`  precision ${s.precision.matched}/${s.precision.of}${s.precision.pct === null ? ' (no claim made)' : ` (${s.precision.pct}%)`} · ${s.falseAlarms.length} false alarm(s)${s.arm === 'agent' ? ` · cost $${s.cost}` : ''}`);
  if (s.tasks.of) console.log(`  tasks done ${s.tasks.done}/${s.tasks.of}`);
  if (s.arm === 'agent') console.log(`  time ${Math.round(s.ms / 1000)} s · advisor calls ${s.advisorCalls}`);
  for (const f of s.falseAlarms) console.log(`    FALSE ALARM ${f.case} ${f.file}:${f.line} ${f.severity} ${String(f.title).slice(0, 100)}`);
  for (const e of s.errors) console.log(`    ERROR ${e}`);
  for (const r of s.rows.filter((x) => x.skipped)) console.log(`    NOT RUN ${r.id}: ${r.skipped}`);
  if (o.out) fs.writeFileSync(o.out, JSON.stringify(s, null, 2) + '\n');
  let rc = s.errors.length && o.arm === 'agent' ? 1 : 0;
  if (o.floors) {
    const fl = JSON.parse(fs.readFileSync(o.floors, 'utf8'))[o.arm] ?? {};
    for (const [k, v] of Object.entries(fl)) {
      const got = k === 'precision' ? s.precision.pct : k === 'falseAlarms' ? s.falseAlarms.length : (k === 'recall' ? s.recall : s.byStratum[k.replace(/^recall-/, '')])?.pct;
      const ok = k === 'falseAlarms' ? got <= v : got !== null && got !== undefined && got >= v;
      console.log(`  floor ${k}: ${got} ${k === 'falseAlarms' ? '≤' : '≥'} ${v} ${ok ? 'ok' : 'BELOW THE FLOOR'}`);
      if (!ok) rc = 1;
    }
  }
  return rc;
}

if (process.argv[1] && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) process.exitCode = main(process.argv.slice(2));
