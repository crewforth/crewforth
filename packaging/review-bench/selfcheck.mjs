#!/usr/bin/env node
// The review bench's gate: the matcher counts what it says it counts, the cases build as they claim, and the
// deterministic pre-pass holds its floor on them. No model runs here; the agent arm is measured by hand.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { score, fromText, hintInDiff, loadCases, build, summarise } from '../../kit/eval/lib/review-bench/bench.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CASES = path.join(HERE, 'cases');
let pass = 0; let fail = 0;
const check = (name, ok, detail) => { if (ok) pass++; else fail++; process.stdout.write(`${ok ? 'PASS' : 'FAIL'} ${name}${!ok && detail ? ` — ${detail}` : ''}\n`); };

// ---- the matcher ----
const d = { id: 'd', kind: 'defect', expect: [{ file: 'a.sh', from: 10, to: 12 }] };
check('a finding three lines past the range matches; four does not', score(d, [{ file: 'a.sh', line: 15, severity: 'low' }]).caught === true && score(d, [{ file: 'a.sh', line: 16, severity: 'low' }]).caught === false);
check('a finding three lines before the range matches; four does not', score(d, [{ file: 'a.sh', line: 7, severity: 'low' }]).caught === true && score(d, [{ file: 'a.sh', line: 6, severity: 'low' }]).caught === false);
check('the same line in another file does not match', score(d, [{ file: 'b.sh', line: 11, severity: 'high' }]).caught === false);
const m = { id: 'm', kind: 'defect', expect: [{ file: 'x.sh', from: null, to: null }] };
check('a file-level defect (a mode bit) is caught by any line of that file', score(m, [{ file: 'x.sh', line: 1, severity: 'medium' }]).caught === true);
const c = { id: 'c', kind: 'clean', expect: [] };
const sc = score(c, [{ file: 'a.sh', line: 1, severity: 'low', title: 't' }, { file: 'a.sh', line: 2, severity: 'info', title: 'note' }]);
check('in a clean case a low finding is a false alarm, an info one is not a claim', sc.claims === 1 && sc.falseAlarms.length === 1 && sc.caught === null, JSON.stringify(sc));
const s = summarise([{ id: 'a', kind: 'defect', stratum: 'judgement', caught: true, claims: 2, matched: 1, falseAlarms: [{}] }, { id: 'b', kind: 'defect', stratum: 'judgement', caught: false, claims: 0, matched: 0, falseAlarms: [] }, { id: 'c', kind: 'clean', stratum: 'judgement', caught: null, claims: 1, matched: 0, falseAlarms: [{}] }], { arm: 'prepass', split: 'all' });
check('recall counts defect cases (1 of 2), precision counts claims (1 of 3)', s.recall.caught === 1 && s.recall.of === 2 && s.precision.matched === 1 && s.precision.of === 3, JSON.stringify([s.recall, s.precision]));
const t = fromText('Plan…\nkit/x.sh:42 · high · bug · reads past the end · bound it\n./src/a.ts:7 - low - style - name\nnot a finding: 3:4\n');
check('the final answer is read: two findings, path and line and severity', t.length === 2 && t[0].file === 'kit/x.sh' && t[0].line === 42 && t[0].severity === 'high' && t[1].file === 'src/a.ts', JSON.stringify(t));
check('a removed comment line is a hint; a removed shebang or a removed code line is not', hintInDiff('@@\n-  # because grep -q ends early\n+x') && !hintInDiff('@@\n-#!/bin/sh\n+#!/bin/bash') && !hintInDiff('@@\n-a=1\n+a=2'));

// ---- the cases ----
const all = loadCases(CASES);
const hold = loadCases(CASES, { split: 'holdout' }); const train = loadCases(CASES, { split: 'train' });
check(`the set: ${all.length} cases, ${all.filter((x) => x.kind === 'defect').length} defects, ${hold.length} held out`, all.length >= 20 && hold.length >= 5 && hold.length + train.length === all.length);
check('every defect case says where the defect is, every clean case expects nothing', all.every((x) => (x.kind === 'defect' ? x.expect.length > 0 : x.expect.length === 0)));
const tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'crew-bench-check-')));
process.on('exit', () => fs.rmSync(tmp, { recursive: true, force: true }));
const mb = build(all.find((x) => x.id === 'mode-bit'), tmp);
check('the mode-bit case builds with the file losing its executable bit, and that is the whole diff', /old mode 100755\nnew mode 100644/.test(mb.diff) && !/^@@/m.test(mb.diff), mb.diff.slice(0, 200));
const cp = build(all.find((x) => x.id === 'cli-path-separator'), tmp);
check('a case stored under =bin/ is built under bin/, the name the reviewer sees', fs.existsSync(path.join(cp.root, 'bin', 'cli.js')) && !fs.existsSync(path.join(cp.root, '=bin')) && /b\/bin\/cli\.js/.test(cp.diff));
const ps = build(all.find((x) => x.id === 'pattern-secret'), tmp);
check('the secret case is built with a filled token (the stored file has none)', /gh[p]_[A-Za-z0-9]{36}/.test(fs.readFileSync(path.join(ps.root, 'src', 'deploy.ts'), 'utf8'))
  && !/gh[p]_[A-Za-z0-9]{36}/.test(fs.readFileSync(path.join(CASES, 'pattern-secret', 'after', 'src', 'deploy.ts'), 'utf8')));
check('no judgement case shows the fix\'s own explanation among its removed lines', all.filter((x) => x.stratum === 'judgement' && x.kind === 'defect').every((x) => !hintInDiff(build(x, tmp).diff)));

// ---- the agent arm's plumbing, on a fake CLI (CREW_BENCH_CLAUDE): the advisor, the cost by model, a task ----
{
  const BENCH = path.resolve(HERE, '..', '..', 'kit', 'eval', 'lib', 'review-bench', 'bench.mjs');
  const TASKS = path.resolve(HERE, '..', 'advisor-bench', 'tasks');
  const log = fs.mkdtempSync(path.join(tmp, 'fake-'));
  const go = (extra, env = {}) => {
    const out = path.join(log, 'out.json');
    const p = spawnSync(process.execPath, [BENCH, '--cases', TASKS, '--arm', 'agent', '--out', out, ...extra],
      { encoding: 'utf8', env: { ...process.env, CREW_BENCH_CLAUDE: path.join(HERE, 'fake-claude.mjs'), FAKE_LOG: log, ...env } });
    let s = null; try { s = JSON.parse(fs.readFileSync(out, 'utf8')); } catch { /* no summary */ }
    fs.rmSync(out, { force: true });
    return { rc: p.status, s, row: s?.rows?.[0], argv: JSON.parse(fs.readFileSync(path.join(log, 'argv.json'), 'utf8')), seen: JSON.parse(fs.readFileSync(path.join(log, 'seen.json'), 'utf8')), err: p.stderr };
  };
  const solved = go(['--model', 'sonnet', '--advisor', 'opus'], { FAKE_SOLVE: path.join(TASKS, 'parse-duration', 'reference', 'duration.js') });
  const si = solved.argv.indexOf('--settings');
  check('--advisor runs the arm with that advisor, passed as the advisorModel setting; the user\'s own settings stay unread',
    si > 0 && JSON.parse(solved.argv[si + 1]).advisorModel === 'opus' && solved.argv.join(' ').includes('--setting-sources project,local'), JSON.stringify(solved.argv));
  check('a run\'s cost is the result\'s total; each model\'s cost is kept apart; one advisor call shown twice is counted once',
    solved.row?.cost === 0.2 && solved.row.byModel?.['claude-opus-5-5']?.cost === 0.15 && solved.row.byModel['claude-sonnet-5-5'].input === 4
    && solved.row.advisorCalls === 1 && solved.s.advisorCalls === 1, JSON.stringify(solved.row));
  check('a task is graded by a check it never saw: not in the repository during the session, and a reference that meets the spec passes it',
    !solved.seen.includes('check.mjs') && solved.seen.includes('src/duration.js') && solved.row?.done === true && /25\/25/.test(solved.row.check ?? '')
    && solved.s.tasks.done === 1 && solved.s.tasks.of === 1, JSON.stringify({ seen: solved.seen, row: solved.row }));
  const idle = go(['--model', 'opus']);
  check('a session that leaves the task undone is not done, and an arm with no advisor passes no advisor setting',
    idle.row?.done === false && /rc 1/.test(idle.row.check ?? '') && !idle.argv.includes('--settings') && idle.s.advisor === null, JSON.stringify({ row: idle.row, argv: idle.argv }));
}

// ---- the pre-pass on the cases, at its floor ----
const r = spawnSync('node', [path.resolve(HERE, '..', '..', 'kit', 'eval', 'lib', 'review-bench', 'bench.mjs'), '--cases', CASES, '--arm', 'prepass', '--no-tools', '--floors', path.join(HERE, 'floors.json')], { encoding: 'utf8' });
process.stdout.write(r.stdout.split('\n').filter(Boolean).map((l) => `     ${l}\n`).join(''));
check('the pre-pass holds its floors on the bench cases (--no-tools)', r.status === 0, r.stderr);

console.log(`\nreview-bench selfcheck: ${pass} passed · ${fail} failed`);
process.exit(fail ? 1 : 0);
