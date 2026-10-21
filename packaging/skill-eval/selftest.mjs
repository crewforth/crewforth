#!/usr/bin/env node
// selftest.mjs — the skill-eval gate held to its own cases, in a repository it builds itself. Hermetic: nothing of
// this checkout is read, so the result is the same on every machine (SKILL_EVAL_ROOT points the tools at it).
//
//   node packaging/skill-eval/selftest.mjs        rc 0 = every case behaved · 1 = one did not · 3 = no git here
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const git = (cwd, ...a) => spawnSync('git', ['-C', cwd, ...a], { encoding: 'utf8' });
if (git(os.tmpdir(), '--version').status !== 0) { console.log('SKIP skill-eval selftest: no git here'); process.exit(3); }

let bad = 0;
let n = 0;
const check = (name, ok, said = '') => { n += 1; if (!ok) bad += 1; console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${said ? ` — ${said}` : ''}`); };

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'skill-eval-selftest-'));
const put = (rel, text) => { fs.mkdirSync(path.dirname(path.join(root, rel)), { recursive: true }); fs.writeFileSync(path.join(root, rel), text); };
const skill = (name, desc, command = false) => put(`kit/skills/${name}/SKILL.md`,
  `---\nname: ${name}\ndescription: |\n  ${desc}\n${command ? 'metadata:\n  kind: command\n' : ''}---\n\n# ${name}\n`);
skill('alpha', 'Writes alpha reports.');
skill('beta', 'Plans beta work.');
skill('crew-cmd', 'A command the user calls.', true);
put('kit/eval/golden-holdout.txt', '# held out\nplease summarise the alpha numbers|alpha\n');
put('kit/eval/golden-routing.txt', '# working\nwrite an alpha report|alpha\nplan the release|!alpha\nplan the beta sprint|beta\n');
git(root, 'init', '-q', '.');
git(root, '-c', 'user.email=a@b', '-c', 'user.name=x', 'add', '-A');
git(root, '-c', 'user.email=a@b', '-c', 'user.name=x', 'commit', '-qm', 'base');
git(root, 'tag', 'base');

const env = { ...process.env, SKILL_EVAL_ROOT: root };
delete env.GITHUB_BASE_REF;
// The base is `base` unless the case names its own.
const run = (...a) => { const r = spawnSync(process.execPath, [path.join(HERE, 'check.mjs'), ...(a.includes('--base') ? a : ['--base', 'base', ...a])], { env, encoding: 'utf8' }); return { rc: r.status, out: r.stdout + r.stderr }; };
const lib = await import(`${path.join(HERE, 'lib.mjs')}?t=${Date.now()}`);   // ROOT is this checkout here; only the pure helpers are used
const results = (rows) => put('packaging/skill-eval/results.tsv',
  ['# test', 'case\tskill\tkind\tsource\tdescription\tscore\tworst\truns', ...rows.map((r) => r.join('\t'))].join('\n') + '\n');
const floor = (rows) => put('packaging/skill-eval/baseline.tsv', ['# test', 'case\tfloor', ...rows.map((r) => r.join('\t'))].join('\n') + '\n');

// The pure helpers.
check('a block description and a one-line description are both read',
  lib.descriptionOf('---\nname: x\ndescription: |\n  one\n  two\nmetadata:\n  kind: command\n---\n') === 'one\ntwo'
  && lib.descriptionOf('---\nname: x\ndescription: Just one line.\n---\n') === 'Just one line.' && lib.descriptionOf('no frontmatter') === null);
check('a command is told by metadata.kind, and a skill without it is not one',
  lib.isCommand('---\nname: x\ndescription: d\nmetadata:\n  kind: command\n---\n') && !lib.isCommand('---\nname: x\ndescription: d\nmetadata:\n  stage: audit\n---\n'));

// The gate, end to end.
let r = run();
check('nothing changed: passes', r.rc === 0 && /no model-picked skill/.test(r.out), r.out.trim());
skill('alpha', 'Writes alpha reports, now with charts.');
const h = lib.hashOf('Writes alpha reports, now with charts.');
r = run();
check('a changed description with no measurement fails, naming every case', r.rc === 1 && (r.out.match(/not measured/g) ?? []).length === 3, r.out.trim().split('\n')[0]);
const ids = ['holdout-is-alpha-', 'working-is-alpha-', 'working-not-alpha-'];
const caseIds = spawnSync(process.execPath, ['--input-type=module', '-e',
  `import * as l from ${JSON.stringify(path.join(HERE, 'lib.mjs'))}; console.log(l.casesFor(['alpha']).map((c) => c.id).join(' '))`],
{ env, encoding: 'utf8' }).stdout.trim().split(' ');
check('the three rows of alpha are its cases: one held out, one positive, one that must not fire',
  caseIds.length === 3 && ids.every((p) => caseIds.some((c) => c.startsWith(p))), caseIds.join(' '));
results(caseIds.map((c) => [c, 'alpha', c.includes('-not-') ? 'not' : 'is', c.split('-')[0], h, '1.000', '1.000', '3']));
r = run();
check('every case measured for the current text, three runs each: passes', r.rc === 0 && /3 of 3 case/.test(r.out), r.out.trim());
floor([[caseIds[0], '1.000']]);
results(caseIds.map((c, k) => [c, 'alpha', c.includes('-not-') ? 'not' : 'is', c.split('-')[0], h, k === 0 ? '0.667' : '1.000', k === 0 ? '0.333' : '1.000', '3']));
r = run();
check('a case under its floor fails, with both numbers', r.rc === 1 && /0\.667 is under its floor 1\.000/.test(r.out), r.out.trim().split('\n')[1] ?? '');
floor([]);
results(caseIds.map((c) => [c, 'alpha', c.includes('-not-') ? 'not' : 'is', c.split('-')[0], lib.hashOf('Writes alpha reports.'), '1.000', '1.000', '3']));
r = run();
check('a measurement of the earlier text does not count for the new one', r.rc === 1 && /earlier text/.test(r.out), r.out.trim().split('\n')[1] ?? '');
results(caseIds.map((c) => [c, 'alpha', c.includes('-not-') ? 'not' : 'is', c.split('-')[0], h, '1.000', '1.000', '1']));
r = run();
check('one run is not enough', r.rc === 1 && /1 run\(s\), 3 needed/.test(r.out), r.out.trim().split('\n')[1] ?? '');

// A command's description is not held; a skill nothing measures is.
git(root, 'checkout', '-q', '--', 'kit/skills/alpha/SKILL.md');
skill('crew-cmd', 'A command the user calls, reworded.', true);
r = run();
check('a changed command is not held', r.rc === 0 && /1 command\(s\) changed/.test(r.out), r.out.trim());
skill('gamma', 'A new skill no row reaches.');
r = run();
check('a new skill with no routing row fails, and says what to add', r.rc === 1 && /gamma: no routing row measures it/.test(r.out), r.out.trim().split('\n')[1] ?? '');

r = run('--base', 'no-such-ref');
check('a base that cannot be read judges nothing and says so (rc 3, not a pass)', r.rc === 3 && /not a pass/.test(r.out), r.out.trim());

fs.rmSync(root, { recursive: true, force: true });
console.log(`${n - bad}/${n} skill-eval cases behaved`);
process.exit(bad ? 1 : 0);
