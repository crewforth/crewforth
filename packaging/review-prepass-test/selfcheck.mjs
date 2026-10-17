#!/usr/bin/env node
// The review pre-pass's gate (kit/eval/lib/review-prepass). Hermetic: every project is a git repository built in
// a temp directory here, never this checkout, and every secret is assembled at run time so none sits in a file.
//
// Each rule is driven both ways: the planted line is found with its rule, and its near miss beside it stays
// silent. A pass that only met lines it should flag would be satisfied by one that flags every line.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { prepass, addedLines, NAME } from '../../kit/eval/lib/review-prepass/prepass.mjs';
import { validate } from '../../kit/eval/lib/findings/findings.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const LIB = path.resolve(HERE, '..', '..', 'kit', 'eval', 'lib', 'review-prepass');

let pass = 0; let fail = 0;
function check(name, ok, detail) {
  if (ok) pass += 1; else fail += 1;
  process.stdout.write(`${ok ? 'PASS' : 'FAIL'} ${name}${!ok && detail ? ` — ${detail}` : ''}\n`);
}

const TMP = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'crew-prepass-')));
process.on('exit', () => fs.rmSync(TMP, { recursive: true, force: true }));
const ENV = { ...process.env, GIT_CONFIG_GLOBAL: path.join(TMP, 'gitconfig'), GIT_CONFIG_NOSYSTEM: '1' };
fs.writeFileSync(ENV.GIT_CONFIG_GLOBAL, '[user]\n\tname = t\n\temail = t@t.invalid\n[core]\n\tautocrlf = false\n');
const g = (root, ...args) => { const r = spawnSync('git', ['-C', root, ...args], { encoding: 'utf8', env: ENV }); if (r.status !== 0) throw new Error(`FIXTURE: git ${args.join(' ')}: ${r.stderr}`); return r.stdout; };
function repo(name, base, change) {
  const root = path.join(TMP, name); fs.mkdirSync(root, { recursive: true });
  const put = (rel, text) => { const f = path.join(root, rel); fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, text); };
  g(root, 'init', '-q', '.'); for (const [f, t] of Object.entries(base)) put(f, t);
  g(root, 'add', '-A'); g(root, 'commit', '-qm', 'base', '--allow-empty');
  for (const [f, t] of Object.entries(change)) put(f, t);
  g(root, 'add', '-A');
  return { root, put };
}
// The rules a document holds, as "rule file:line".
const got = (doc) => doc.findings.map((f) => `${f.rule} ${f.evidence[0].file}:${f.evidence[0].line}`).sort();
const has = (doc, rule, at) => got(doc).includes(`${rule} ${at}`);
const none = (doc, file) => !doc.findings.some((f) => f.evidence[0].file === file);
const withEnv = (vars, fn) => { const old = {}; for (const k of Object.keys(vars)) { old[k] = process.env[k]; if (vars[k] === undefined) delete process.env[k]; else process.env[k] = vars[k]; } try { return fn(); } finally { for (const k of Object.keys(old)) { if (old[k] === undefined) delete process.env[k]; else process.env[k] = old[k]; } } };

const TOKEN = `ghp_${'A1b2'.repeat(9)}`;      // the gh token shape the blocklist names
const lines = (n, f) => Array.from({ length: n }, (_, i) => f(i)).join('\n') + '\n';

// ---- 1. the planted lines, each with its near miss --------------------------------------------------------------
const A = repo('planted', {
  'package.json': '{ "name": "a" }\n', 'package-lock.json': '{}\n',
  'app/pubspec.yaml': 'name: app\n', 'app/pubspec.lock': 'packages: {}\n',
  'src/old.ts': "console.log('was here before');\n",
  'README.md': '# a\n',
}, {
  'src/a.ts': "export const x = 1;\nconsole.log(x);\ndebugger;\n// TODO: remove the flag\n",
  'src/old.ts': "console.log('was here before');\nexport const y = 2;\n",
  'src/a.test.ts': "console.log('a test may print');\n",
  'bin/run.js': "console.log('a command prints');\n",
  'tools/gen.mjs': "#!/usr/bin/env node\nconsole.log('a script prints');\n",
  'svc/main.py': 'def f():\n    breakpoint()\n    # FIXME handle the empty case\n',
  'src/words.ts': "const MARK = /\\b(TODO|FIXME)\\b/;\nexport const hint = 'say TODO when unsure';\n",
  'src/a.spec.ts': '// TODO: a test may keep a note\n',
  'app/lib/main.dart': "void main() {\n  print('hi');\n}\n",
  'app/test/main_test.dart': "void main() {\n  print('a test may print');\n}\n",
  'README.md': '# a\n\nTODO: write the guide\n',
  'config/keys.ts': `export const key = '${TOKEN}';\n`,
  'package-lock.json': '{ "lockfileVersion": 3 }\n',
  'app/pubspec.lock': 'packages: { http: {} }\n', 'app/pubspec.yaml': 'name: app\ndependencies:\n  http: ^1.0.0\n',
  'big/table.ts': lines(520, (i) => `export const v${i} = ${i};`),
  'dist/bundle.js': lines(600, (i) => `var a${i}=${i};`),
});
const docA = withEnv({ CREW_SHELLCHECK: path.join(TMP, 'no-such-shellcheck') }, () => prepass(A.root));
const wantA = [
  'prepass-debug-call src/a.ts:2', 'prepass-debug-call src/a.ts:3', 'prepass-todo src/a.ts:4', 'prepass-todo svc/main.py:3',
  'prepass-debug-call svc/main.py:2', 'prepass-debug-call app/lib/main.dart:2',
  'prepass-secret config/keys.ts:1', 'prepass-lockfile package-lock.json:1', 'prepass-large-change big/table.ts:1',
];
for (const w of wantA) { const [r, at] = w.split(' '); check(`planted: ${w}`, has(docA, r, at), got(docA).join(', ')); }
check(`planted: nothing else is found (${wantA.length} findings)`, docA.findings.length === wantA.length, got(docA).join(', '));
check('near miss: a console call in a test file is silent', none(docA, 'src/a.test.ts'));
check('near miss: a console call in bin/ is silent (a command prints)', none(docA, 'bin/run.js'));
check('near miss: a console call in a script with a shebang is silent', none(docA, 'tools/gen.mjs'));
check('near miss: print( in a Dart test is silent', none(docA, 'app/test/main_test.dart'));
check('near miss: a TODO in Markdown is silent (prose, not a promise)', none(docA, 'README.md'));
check('near miss: the word TODO in a pattern or a string is not a marker', none(docA, 'src/words.ts'));
check('near miss: a TODO in a test file is silent', none(docA, 'src/a.spec.ts'));
check('near miss: a console call on a line the change did not add is silent', !has(docA, 'prepass-debug-call', 'src/old.ts:1'));
check('near miss: a lock file whose manifest changed with it is silent', none(docA, 'app/pubspec.lock'));
check('near miss: a large generated file (dist/) is not a large change', none(docA, 'dist/bundle.js'));
const sec = docA.findings.find((f) => f.rule === 'prepass-secret');
check('a secret is cited by sha256, never quoted', sec && !sec.evidence[0].text && /^[0-9a-f]{64}$/.test(sec.evidence[0].sha256) && !JSON.stringify(docA).includes(TOKEN), JSON.stringify(sec?.evidence));
check('the planted secret is severity high and proven', sec?.severity === 'high' && sec?.confidence === 'proven');
check('the lock-file finding is inferred, not proven', docA.findings.find((f) => f.rule === 'prepass-lockfile')?.confidence === 'inferred');
const vA = validate(docA, A.root);
check('the document verifies against the project (findings core)', vA.ok, vA.problems.map((p) => `${p.at} ${p.code}`).join('; '));
check('the producer is review-prepass', docA.producer?.name === NAME);

// ---- 2. shellcheck: present (its findings on the added lines only), absent (said, not skipped) ---------------------
const B = repo('shell', { 'run.sh': '#!/bin/sh\necho ok\n' }, { 'run.sh': '#!/bin/sh\necho ok\necho $1\nrm -rf $DIR/x\n', 'notes.txt': 'x\n' });
// A Node script, not a shell one: Windows cannot start a `#!/bin/sh` file from spawnSync, and this check failed there
// for that reason alone (the product runs shellcheck.exe). prepass runs a CREW_SHELLCHECK ending in .mjs with Node.
const stub = path.join(TMP, 'shellcheck-stub.mjs');
// The stub answers as shellcheck -f json1 does: one comment per line, on lines 2 (unchanged), 3 and 4 (added).
const scOut = path.join(TMP, 'shellcheck-out.json');
fs.writeFileSync(scOut, JSON.stringify({ comments: [
  { file: 'run.sh', line: 2, level: 'style', code: 2000, message: 'on a line the change did not add' },
  { file: 'run.sh', line: 3, level: 'info', code: 2086, message: 'Double quote to prevent globbing and word splitting.' },
  { file: 'run.sh', line: 4, level: 'warning', code: 2115, message: 'Use "${var:?}" to ensure this never expands to /* .' },
] }));
fs.writeFileSync(stub, `import fs from 'node:fs';\nif (process.argv[2] === '--version') { console.log('ShellCheck - shell script analysis tool'); process.exit(0); }\nprocess.stdout.write(fs.readFileSync(${JSON.stringify(scOut)}, 'utf8'));\nprocess.exit(1);\n`);
const docB = withEnv({ CREW_SHELLCHECK: stub }, () => prepass(B.root));
check('shellcheck: its findings on added lines are kept (SC2086 info, SC2115 warning → low)',
  has(docB, 'prepass-shellcheck', 'run.sh:3') && has(docB, 'prepass-shellcheck', 'run.sh:4')
  && docB.findings.find((f) => f.evidence[0].line === 4)?.severity === 'low' && docB.findings.find((f) => f.evidence[0].line === 3)?.severity === 'info', got(docB).join(', '));
check('shellcheck: a finding on a line the change did not add is dropped (2 of its 3 kept)', !has(docB, 'prepass-shellcheck', 'run.sh:2') && docB.findings.filter((f) => f.rule === 'prepass-shellcheck').length === 2, got(docB).join(', '));
const docB2 = withEnv({ CREW_SHELLCHECK: path.join(TMP, 'no-such-shellcheck') }, () => prepass(B.root));
check('shellcheck absent: the shell file is listed as not measured, and nothing is found for it',
  docB2.notMeasured.some((x) => /^prepass-shellcheck \(1 shell file\)$/.test(x.what)) && none(docB2, 'run.sh'), JSON.stringify(docB2.notMeasured));
const real = spawnSync('shellcheck', ['--version'], { encoding: 'utf8' });
if (real.status === 0) {
  const docB3 = withEnv({ CREW_SHELLCHECK: undefined }, () => prepass(B.root));
  check('shellcheck (the real one, on this machine): SC2086 is found on the added `echo $1`', docB3.findings.some((f) => f.rule === 'prepass-shellcheck' && f.title.startsWith('SC2086') && f.evidence[0].line === 3), got(docB3).join(', '));
} else process.stdout.write('NOTE shellcheck is not installed here: the real tool was not run, the stub above stands for its output shape\n');

// ---- 3. what cannot be cited is said, not cited wrongly ---------------------------------------------------------
const C = repo('stale', { 'src/a.ts': 'export const a = 1;\n' }, { 'src/a.ts': "export const a = 1;\nconsole.log(a);\n" });
C.put('src/a.ts', "export const a = 2;\n");   // edited again after staging: the staged line is not on disk
const docC = prepass(C.root);
check('a file edited after staging: not read, said as not measured', none(docC, 'src/a.ts') && docC.notMeasured.some((x) => x.what === 'src/a.ts'), JSON.stringify(docC));
const home = os.homedir();
const D = repo('machine', {}, { 'src/p.ts': `console.log('${home}/secret-place');\n` });
const docD = prepass(D.root);
const dEv = docD.findings[0]?.evidence[0];
check("a line carrying this machine's home directory is cited by sha256, so the document still verifies", dEv && !dEv.text && dEv.sha256 && validate(docD, D.root).ok, JSON.stringify(dEv));
const E = repo('allow', {}, { 'config/k.ts': `export const k = '${TOKEN}';\n`, '.secret-allowlist.txt': 'gh[pousr]_[A-Za-z0-9]{36,}\n' });
check('a pattern the project allows (.secret-allowlist.txt, the exact line) is not a finding', none(prepass(E.root), 'config/k.ts'));

// ---- 4. the two modes, the command line, and the same bytes twice ---------------------------------------------
const F = repo('base', { 'src/a.ts': 'export const a = 1;\n' }, {});
g(F.root, 'checkout', '-qb', 'work'); F.put('src/a.ts', "export const a = 1;\nconsole.log(a);\n"); g(F.root, 'commit', '-qam', 'work');
const staged = prepass(F.root); const based = prepass(F.root, { base: 'HEAD~1' });
check('--base: the branch\'s change is read (the staged area is empty)', staged.findings.length === 0 && has(based, 'prepass-debug-call', 'src/a.ts:2'), `${got(staged)} | ${got(based)}`);
const cli = (root, ...a) => spawnSync('bash', [path.join(LIB, 'prepass.sh'), '--root', root, ...a], { encoding: 'utf8', env: { ...ENV, CREW_SHELLCHECK: path.join(TMP, 'none') } });
const w = cli(A.root);
const out = path.join(A.root, '.crewforth', `${NAME}.json`);
check('prepass.sh writes .crewforth/review-prepass.json, rc 0', w.status === 0 && fs.existsSync(out) && /→ \.crewforth\/review-prepass\.json/.test(w.stdout), `${w.status} ${w.stderr}`);
const first = fs.readFileSync(out, 'utf8'); cli(A.root);
check('two runs write the same bytes', first === fs.readFileSync(out, 'utf8'));
const so = cli(A.root, '--stdout');
check('--stdout prints the document and the summary goes to stderr', so.status === 0 && JSON.parse(so.stdout).producer.name === NAME && /review-prepass: 9 finding/.test(so.stderr), so.stderr);
const outside = path.join(TMP, 'not-a-repo'); fs.mkdirSync(outside);
check('outside a git repository: rc 2, nothing written', cli(outside).status === 2 && !fs.existsSync(path.join(outside, '.crewforth')));
check('an unknown argument: rc 2', cli(A.root, '--bogus').status === 2);

// ---- 5. the diff reader on its own: a hunk with no count, a deleted file, a binary ----------------------------
const r = addedLines('diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\ndiff --git a/y b/y\n--- a/y\n+++ /dev/null\n@@ -1 +0,0 @@\n-gone\ndiff --git a/i.png b/i.png\nBinary files a/i.png and b/i.png differ\n');
check('the diff reader: one added line at 1, the deleted file and the binary give no line', JSON.stringify(r.added) === JSON.stringify([{ file: 'x', line: 1, text: 'b' }]) && r.binary[0] === 'i.png', JSON.stringify(r));

console.log(`\nreview-prepass selfcheck: ${pass} passed · ${fail} failed`);
process.exit(fail ? 1 : 0);
