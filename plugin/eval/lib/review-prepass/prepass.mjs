#!/usr/bin/env node
// prepass.mjs — the review's deterministic first pass: cheap checks over the lines a change ADDS, run before the
// review agent reads the diff, written as a findings document (crewforth.findings/1) the agent starts from.
//
//   node prepass.mjs [--root DIR] [--base REF] [--stdout]
//       default   the staged change (git diff --cached), what the next commit will hold
//       --base    the working tree against REF (a branch under review: --base origin/next)
//       --stdout  print the document, write nothing; otherwise .crewforth/review-prepass.json, through findings.mjs
//   rc 0 = written (or printed), whatever it found · 1 = the document did not verify, nothing written ·
//   2 = usage, or not a git repository
//
// The checks are chosen by the file, and kept narrow on purpose: a first pass that cries wolf trains the reader to
// skip it. Each one either reads the added line alone (proven) or one fact next to it (inferred):
//
//   prepass-secret        a secret-blocklist.txt pattern on an added line (the pre-commit gate's own list and
//                         .secret-allowlist.txt). Cited by sha256 only: the value is never quoted.
//   prepass-debug-call    console.log / debugger (JS, TS), breakpoint() / pdb (Python), print( (Dart), outside a
//                         test and outside a command-line script (a shebang, or a bin/, scripts/ or tool/ folder).
//   prepass-todo          a TODO, FIXME, XXX or HACK opening a comment added in code, outside tests
//                         (Markdown is prose, not a promise; the word in a string or a pattern is not a marker).
//   prepass-shellcheck    shellcheck's own findings on a shell file, kept to the added lines. Without shellcheck
//                         the shell files are listed as not measured: nothing is installed.
//   prepass-lockfile      a lock file changed and the manifest beside it did not (inferred: a regenerated lock
//                         can be on purpose).
//   prepass-large-change  one file gains more than 500 lines (generated files, locks and snapshots aside).
//
// What it does not do: judge. A finding here says a line is there; whether it matters is the reviewer's call, and
// the reviewer writes its own findings beside these (.crewforth/review.json), in the same shape.
// Host-independent like findings.mjs: git, Node's standard library, and shellcheck when it is there.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { loadSecretPatterns, isTestPath } from '../crew-map/project.mjs';
import { SCHEMA_ID, validate, write, serialize } from '../findings/findings.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const NAME = 'review-prepass';
const LARGE = 500;
const QUOTE = 200;

const DEBUG = [
  { files: /\.(m?[jt]sx?|cjs|cts|vue|svelte)$/, re: /\bconsole\.(log|debug|trace)\(|^\s*debugger\s*;?\s*$/, what: 'a console call or debugger statement' },
  { files: /\.py$/, re: /\bbreakpoint\(\)|\bpdb\.set_trace\(|^\s*import\s+pdb\b/, what: 'a debugger breakpoint' },
  { files: /\.dart$/, re: /^\s*print\(/, what: 'a print call' },
];
const SCRIPT_DIR = /(^|\/)(bin|scripts?|tools?|tool)\//;
// A marker opens a comment; the word inside a string, a pattern or prose that names it is not one.
const TODO = /(?:\/\/|#|\/\*|^\s*\*|--|<!--)\s*(TODO|FIXME|XXX|HACK)\b/;
const PROSE = /\.(md|markdown|txt|rst|adoc)$/i;
const SHELL = /\.(sh|bash)$/;
const SECRET_LISTS = /(^|\/)secret-(block|allow)list\.txt$/;
// A lock file and the manifest that declares what it pins, in the same folder.
const LOCKS = {
  'package-lock.json': 'package.json', 'npm-shrinkwrap.json': 'package.json', 'yarn.lock': 'package.json',
  'pnpm-lock.yaml': 'package.json', 'bun.lockb': 'package.json', 'pubspec.lock': 'pubspec.yaml',
  'poetry.lock': 'pyproject.toml', 'uv.lock': 'pyproject.toml', 'Pipfile.lock': 'Pipfile', 'go.sum': 'go.mod',
  'Cargo.lock': 'Cargo.toml', 'composer.lock': 'composer.json', 'Gemfile.lock': 'Gemfile',
};
const GENERATED = /(^|\/)(dist|build|vendor|node_modules|__snapshots__)\/|\.(g|freezed|gr|pb)\.dart$|\.min\.(js|css)$|\.snap$|\.lock$|-lock\.(json|yaml)$/;

const sha = (s) => crypto.createHash('sha256').update(s).digest('hex');
const git = (root, args) => spawnSync('git', ['-C', root, '-c', 'core.quotePath=false', ...args], { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 });

// The added lines of a unified diff with no context: { file, line, text }[] and the files it touches.
export function addedLines(diff) {
  const added = []; const files = new Set(); const binary = new Set();
  let file = null; let n = 0;
  for (const raw of diff.split('\n')) {
    if (raw.startsWith('diff --git ')) { file = null; continue; }
    if (raw.startsWith('+++ ')) { file = raw === '+++ /dev/null' ? null : raw.slice(6).replace(/\t$/, ''); if (file) files.add(file); continue; }
    if (raw.startsWith('Binary files ')) { const b = / and b\/(.*) differ$/.exec(raw); if (b) binary.add(b[1]); continue; }
    const h = /^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@/.exec(raw);
    if (h) { n = Number(h[1]); continue; }
    if (file && raw.startsWith('+')) { added.push({ file, line: n, text: raw.slice(1).replace(/\r$/, '') }); n++; }
  }
  return { added, files: [...files].sort(), binary: [...binary].sort() };
}

// A finding id from a rule, a file and a line: lower case, the schema's characters only, unique in the document.
function idOf(seen, rule, file, line) {
  let id = `${rule}:${file.toLowerCase().replace(/[^a-z0-9._-]+/g, '-')}:${line}`.slice(0, 190);
  if (seen.has(id)) { let k = 2; while (seen.has(`${id}.${k}`)) k++; id = `${id}.${k}`; }
  seen.add(id); return id;
}

export function prepass(root = '.', { base = null } = {}) {
  const rootReal = fs.realpathSync(root);
  const top = git(rootReal, ['rev-parse', '--show-toplevel']);
  if (top.status !== 0) throw new Error('not a git repository');
  const diffArgs = ['diff', '--no-ext-diff', '--no-textconv', '--no-color', '-U0', '--diff-filter=AMR'];
  const d = git(rootReal, base ? [...diffArgs, base, '--'] : [...diffArgs, '--cached', '--']);
  if (d.status !== 0) throw new Error(`git diff failed: ${(d.stderr || '').trim().split('\n')[0]}`);
  const { added, files, binary } = addedLines(d.stdout);

  const doc = { schema: SCHEMA_ID, producer: { name: NAME, version: '1' }, findings: [], notMeasured: [] };
  const seen = new Set();
  const machine = [rootReal, os.homedir()].filter((p) => p && p.length > 1);
  const add = (rule, severity, confidence, title, at, detail, quote = true) => {
    // A line that carries this machine's directory, or must not be quoted, is cited by its hash.
    const ev = { file: at.file, line: at.line };
    if (quote && !machine.some((m) => at.text.includes(m)) && at.text.trim()) ev.text = at.text.trim().slice(0, QUOTE);
    else ev.sha256 = sha(at.text);
    doc.findings.push({ id: idOf(seen, rule, at.file, at.line), rule, title, confidence, severity, ...(detail ? { detail } : {}), evidence: [ev] });
  };

  // A staged line the working tree no longer has cannot be cited (the citation is checked against the tree).
  const tree = new Map();
  const linesOf = (f) => { if (!tree.has(f)) { let t = null; try { t = fs.readFileSync(path.join(rootReal, f), 'utf8').split('\n').map((l) => l.replace(/\r$/, '')); } catch { /* gone */ } tree.set(f, t); } return tree.get(f); };
  const stale = new Set();
  const lines = added.filter((a) => { const t = linesOf(a.file); if (t && t[a.line - 1] === a.text) return true; stale.add(a.file); return false; });
  for (const f of [...stale].sort()) doc.notMeasured.push({ what: f, reason: 'edited again after it was staged: its staged lines are not the ones on disk, so they were not read' });
  for (const f of binary) doc.notMeasured.push({ what: f, reason: 'a binary file: no line to read' });

  // ---- secrets: the pre-commit gate's list, minus the project's allowlist ----
  let allow = new Set();
  try { allow = new Set(fs.readFileSync(path.join(rootReal, '.secret-allowlist.txt'), 'utf8').split('\n').map((l) => l.replace(/\r$/, '')).filter(Boolean)); } catch { /* none */ }
  const patterns = loadSecretPatterns(path.join(HERE, '..', 'crew-map'), allow);
  if (!patterns) doc.notMeasured.push({ what: 'prepass-secret', reason: 'secret-blocklist.txt was not found beside the hooks, so no line was checked for a secret' });
  const byFile = new Map();
  for (const a of lines) { if (!byFile.has(a.file)) byFile.set(a.file, []); byFile.get(a.file).push(a); }

  for (const [f, list] of [...byFile].sort((x, y) => (x[0] < y[0] ? -1 : 1))) {
    const test = isTestPath(f);
    const first = linesOf(f)?.[0] ?? '';
    const script = first.startsWith('#!') || SCRIPT_DIR.test(f);
    const debug = DEBUG.find((x) => x.files.test(f));
    for (const a of list) {
      if (patterns && !SECRET_LISTS.test(f) && patterns.some((re) => re.test(a.text))) {
        add('prepass-secret', 'high', 'proven', 'A secret pattern on an added line', a, 'It matches a pattern of secret-blocklist.txt, the list the pre-commit gate refuses; the value is not quoted here.', false);
        continue;
      }
      if (debug && !test && !script && debug.re.test(a.text)) add('prepass-debug-call', 'low', 'proven', `An added ${debug.what}`, a);
      if (!PROSE.test(f) && !test && TODO.test(a.text)) add('prepass-todo', 'info', 'proven', `An added ${TODO.exec(a.text)[1]}`, a);
    }
    if (list.length > LARGE && !GENERATED.test(f)) add('prepass-large-change', 'low', 'proven', `${list.length} lines added to one file`, list[0], 'A change this size is hard to review in one pass; split it, or say in the description what to read first.');
  }

  // ---- lock files: the manifest beside them should have changed too ----
  const changed = new Set(files);
  for (const f of files) {
    const want = LOCKS[path.posix.basename(f)]; if (!want) continue;
    const dir = path.posix.dirname(f); const manifest = dir === '.' ? want : `${dir}/${want}`;
    if (changed.has(manifest) || !fs.existsSync(path.join(rootReal, manifest))) continue;
    const at = byFile.get(f)?.[0]; if (!at) continue;
    add('prepass-lockfile', 'low', 'inferred', `${path.posix.basename(f)} changed and ${want} did not`, at, 'A lock file that moves on its own pins different versions than the manifest asks for; regenerate it from the manifest, or say why it moved.');
  }

  // ---- shell: shellcheck's findings on the added lines ----
  const shells = [...byFile.keys()].filter((f) => SHELL.test(f) || /^#!.*\b(ba|z|da)?sh\b/.test(linesOf(f)?.[0] ?? '')).sort();
  if (shells.length) {
    // CREW_SHELLCHECK names another shellcheck. One ending in .mjs is run with this Node: the self-check's stand-in,
    // which a Windows runner could not start as a `#!/bin/sh` script (spawnSync runs no interpreter line there).
    const sc = process.env.CREW_SHELLCHECK || 'shellcheck';
    const run = (args, opts) => (sc.endsWith('.mjs') ? spawnSync(process.execPath, [sc, ...args], opts) : spawnSync(sc, args, opts));
    const v = run(['--version'], { encoding: 'utf8' });
    if (v.status !== 0) doc.notMeasured.push({ what: `prepass-shellcheck (${shells.length} shell file${shells.length === 1 ? '' : 's'})`, reason: 'shellcheck is not installed here, so the shell files were not linted; nothing was installed' });
    else {
      for (const f of shells) {
        const r = run(['-f', 'json1', '-x', f], { cwd: rootReal, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
        let out; try { out = JSON.parse(r.stdout || '{}'); } catch { doc.notMeasured.push({ what: f, reason: 'shellcheck gave no output this pass can read' }); continue; }
        const at = new Map(byFile.get(f).map((a) => [a.line, a]));
        for (const c of out.comments ?? []) {
          const a = at.get(c.line); if (!a) continue;
          const sev = { error: 'medium', warning: 'low' }[c.level] ?? 'info';
          add('prepass-shellcheck', sev, 'proven', `SC${c.code}: ${String(c.message).slice(0, 180)}`, a);
        }
      }
    }
  }
  doc.findings.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  return doc;
}

function main(argv) {
  let root = '.'; let base = null; let stdout = false;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--root') root = argv[++i];
    else if (a === '--base') base = argv[++i];
    else if (a === '--stdout') stdout = true;
    else { console.error(`prepass: unknown argument ${a}\nusage: prepass.mjs [--root DIR] [--base REF] [--stdout]`); return 2; }
    if (root === undefined || base === undefined) { console.error('prepass: --root and --base need a value'); return 2; }
  }
  let doc;
  try { doc = prepass(root, { base }); } catch (e) { console.error(`prepass: ${e.message}`); return 2; }
  const count = (s) => doc.findings.filter((f) => f.severity === s).length;
  const line = `review-prepass: ${doc.findings.length} finding(s) · high ${count('high')} · medium ${count('medium')} · low ${count('low')} · info ${count('info')} · ${doc.notMeasured.length} not measured`;
  if (stdout) {
    const r = validate(doc, root);
    if (!r.ok) { for (const p of r.problems) console.error(`prepass: ${p.at} ${p.code}: ${p.message}`); return 1; }
    process.stdout.write(serialize(doc)); console.error(line); return 0;
  }
  const r = write(doc, root, NAME);
  if (!r.ok) { for (const p of r.problems) console.error(`prepass: ${p.at} ${p.code}: ${p.message}`); return 1; }
  console.log(`${line} → ${r.file}`);
  return 0;
}

if (process.argv[1] && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) process.exitCode = main(process.argv.slice(2));
