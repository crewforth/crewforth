#!/usr/bin/env node
// Crew Map's gate (kit/eval/lib/crew-map). Offline and hermetic: every project it scans is a copy in a temp
// directory, never this checkout, so a verdict here does not depend on the state of the machine that runs it.
//
// The fixtures are small projects with defects planted on purpose, one or more per detector, beside near misses
// that must stay silent. Each fixture's expected.json lists the findings it must produce and NOTHING ELSE may be
// produced: the comparison is exact, so a detector that fires everywhere fails as surely as one that never fires.
// Secrets are never in the repository: {{PW}} and {{TOKEN}} are replaced here with values made for this run, and
// _env files are renamed to .env in the copy (a global gitignore may hide a committed .env).

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { scan, SCHEMA } from '../../kit/eval/lib/crew-map/scan.mjs';
import { RULES, INFERRED } from '../../kit/eval/lib/crew-map/detect.mjs';
import { spawned, bearsValues, risky, makeHostFilter, loadSecretPatterns } from '../../kit/eval/lib/crew-map/project.mjs';
import { serialize, validate } from '../../kit/eval/lib/findings/findings.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '..', '..');
const LIB = path.join(REPO, 'kit', 'eval', 'lib', 'crew-map');
const FIX = path.join(HERE, 'fixtures');

let pass = 0; let fail = 0; let skipped = 0;
function check(name, ok, detail) {
  if (ok) pass += 1; else fail += 1;
  process.stdout.write(`${ok ? 'PASS' : 'FAIL'} ${name}${!ok && detail ? ` — ${detail}` : ''}\n`);
}
function skip(name, why) { skipped += 1; process.stdout.write(`SKIP ${name} — ${why}\n`); }

const TMP = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'crew-map-')));
process.on('exit', () => fs.rmSync(TMP, { recursive: true, force: true }));
// Made per run, in the shapes Crewforth's secret scanner knows, so a leak cannot hide behind a value the code expects.
const PW = `Pw${crypto.randomBytes(9).toString('hex')}Z9`;
const TOKEN = `ghp_${crypto.randomBytes(18).toString('hex')}`;

let n = 0;
function copy(name, { crlf = false, into = null } = {}) {
  const root = path.join(into || path.join(TMP, `c${n++}`), name);
  fs.cpSync(path.join(FIX, name), root, { recursive: true });
  fs.rmSync(path.join(root, 'expected.json'), { force: true });
  const walk = (d) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) { walk(p); continue; }
      let t = fs.readFileSync(p, 'utf8').replaceAll('{{PW}}', PW).replaceAll('{{TOKEN}}', TOKEN);
      if (crlf) t = t.replace(/\r?\n/g, '\r\n');
      fs.writeFileSync(p, t);
      if (e.name.startsWith('_env')) fs.renameSync(p, path.join(d, `.env${e.name.slice(4)}`));
    }
  };
  walk(root);
  return root;
}
const fixtures = fs.readdirSync(FIX).filter((d) => fs.existsSync(path.join(FIX, d, 'expected.json'))).sort();

/* -- 1. every fixture: exactly the planted findings, the nodes, the edges ----------------------------------- */
let expectedTotal = 0; let foundTotal = 0;
const rulesSeen = new Set();
for (const name of fixtures) {
  const exp = JSON.parse(fs.readFileSync(path.join(FIX, name, 'expected.json'), 'utf8'));
  const { doc, report } = scan(copy(name));
  check(`${name}: the document verifies against the project (findings core)`, report.ok, report.problems.map((p) => `${p.at} ${p.code}`).join('; '));
  check(`${name}: schema is ${SCHEMA}`, doc.schema === SCHEMA);
  const got = new Set(doc.findings.map((f) => `${f.rule}\u0000${f.data.subject}`));
  const want = new Set(exp.findings.map(([r, s]) => `${r}\u0000${s}`));
  const missing = [...want].filter((k) => !got.has(k)).map((k) => k.replace('\u0000', ' | '));
  const extra = [...got].filter((k) => !want.has(k)).map((k) => k.replace('\u0000', ' | '));
  expectedTotal += want.size; foundTotal += want.size - missing.length;
  exp.findings.forEach(([r]) => rulesSeen.add(r));
  check(`${name}: all ${want.size} planted finding(s) found`, missing.length === 0, `missing: ${missing.join('; ')}`);
  check(`${name}: nothing found that was not planted (${exp.nearMisses.length} near miss(es) stay silent)`, extra.length === 0, `extra: ${extra.join('; ')}`);
  const nodes = doc.nodes.map((x) => x.id).sort();
  check(`${name}: the nodes are exactly the expected ${exp.nodes.length}`, JSON.stringify(nodes) === JSON.stringify([...exp.nodes].sort()), nodes.join(' '));
  for (const [from, to, kind, conf] of exp.edges) {
    check(`${name}: edge ${from} → ${to} (${kind}, ${conf})`, doc.edges.some((e) => e.from === from && e.to === to && e.kind === kind && e.confidence === conf));
  }
  for (const [from, to] of exp.absentEdges ?? []) check(`${name}: no edge ${from} → ${to}`, !doc.edges.some((e) => e.from === from && e.to === to), doc.edges.filter((e) => e.from === from && e.to === to).map((e) => `${e.kind} ${e.evidence[0].file}:${e.evidence[0].line}`).join('; '));
  // By module: a call misread as a route lands in the CALLER's module, and only the module shows it.
  const prov = [...new Set(doc.provides.endpoints.map((e) => `${e.module} ${e.method} ${e.path}`))].sort();
  check(`${name}: provides exactly ${exp.provides.length} endpoint(s), each in its module`, JSON.stringify(prov) === JSON.stringify([...exp.provides].sort()), prov.join(', '));
  for (const s of exp.notMeasured) check(`${name}: notMeasured names "${s}"`, doc.notMeasured.some((x) => x.what.includes(s)), doc.notMeasured.map((x) => x.what).join('; '));
  for (const s of exp.absentNotMeasured ?? []) check(`${name}: notMeasured does not name "${s}"`, !doc.notMeasured.some((x) => x.what.includes(s)), doc.notMeasured.map((x) => x.what).join('; '));
  // What is inside each module: its folders (one level into a folder holding nearly all), counts, tests apart.
  for (const [id, want] of Object.entries(exp.structure ?? {})) {
    const got = doc.nodes.find((x) => x.id === id)?.structure;
    check(`${name}: ${id} is laid out as ${want.folders.map((r) => `${r.folder} ${r.files}`).join(', ')}`, JSON.stringify(got) === JSON.stringify(want), JSON.stringify(got));
  }
  // What a module says about itself: the first line of prose in its README, past headings, badges, images and code.
  for (const [id, want] of Object.entries(exp.aboutLine ?? {})) {
    const e = doc.nodes.find((x) => x.id === id)?.about?.evidence?.[0];
    check(`${name}: ${id} says what it is at ${want}`, e && `${e.file}:${e.line}` === want, JSON.stringify(e));
  }
  // What each module is built with: the exact labels, so a lost label and a stray one both show.
  for (const [id, want] of Object.entries(exp.tech ?? {})) {
    const got = [...(doc.nodes.find((x) => x.id === id)?.tech ?? [])].sort();
    check(`${name}: ${id} is built with ${want.join(', ') || 'nothing named'}`, JSON.stringify(got) === JSON.stringify([...want].sort()), got.join(', '));
  }
  const wrongClass = doc.findings.filter((f) => (INFERRED.has(f.rule) ? f.confidence !== 'inferred' || f.data.defaultHidden !== true : f.confidence !== 'proven' || f.data.defaultHidden));
  check(`${name}: inferred rules are hidden by default, proven ones are not`, wrongClass.length === 0, wrongClass.map((f) => f.id).join(' '));
  check(`${name}: every finding cites at least one line`, doc.findings.every((f) => f.evidence.length > 0));
}
check(`coverage: expected ${expectedTotal} of ${expectedTotal} planted findings found (${foundTotal})`, foundTotal === expectedTotal && expectedTotal > 0);
const unplanted = RULES.filter((r) => !rulesSeen.has(r));
check(`coverage: all ${RULES.length} detectors have a planted case`, unplanted.length === 0, `no case for: ${unplanted.join(', ')}`);

/* -- 2. deterministic: same bytes twice, in another directory, and with CRLF line ends ------------------------ */
{
  const a = serialize(scan(copy('node-ws')).doc);
  const b = serialize(scan(copy('node-ws')).doc);
  const deep = path.join(TMP, 'a dir with spaces', 'and more');
  fs.mkdirSync(deep, { recursive: true });
  const c = serialize(scan(copy('node-ws', { into: deep })).doc);
  const d = serialize(scan(copy('node-ws', { crlf: true })).doc);
  check('determinism: two scans of the same tree give the same bytes', a === b && a.length > 100);
  check('determinism: the same tree in another directory (with spaces) gives the same bytes', a === c);
  check('determinism: the same tree with CRLF line ends gives the same bytes', a === d, 'CRLF changed the output');
  check('determinism: no timestamp in the document', !/"(time|date|generated|scannedAt)"/i.test(a));
  let all = true;
  for (const name of fixtures) { const r = copy(name); if (serialize(scan(r).doc) !== serialize(scan(r).doc)) all = false; }
  check(`determinism: every fixture (${fixtures.length}) scans to the same bytes twice`, all);
}

/* -- 3. no secrets ------------------------------------------------------------------------------------------ */
{
  let leaks = []; let valueCites = 0; let hashedValueCites = 0; let hashedCode = 0;
  for (const name of fixtures) {
    const s = serialize(scan(copy(name)).doc);
    if (s.includes(PW)) leaks.push(`${name}: password`);
    if (s.includes(TOKEN)) leaks.push(`${name}: token`);
    const walk = (v) => {
      if (Array.isArray(v)) v.forEach(walk);
      else if (v && typeof v === 'object') {
        if (typeof v.file === 'string' && typeof v.line === 'number') {
          if (bearsValues(v.file)) { valueCites++; if (v.sha256) hashedValueCites++; } else if (v.sha256) hashedCode++;
        }
        Object.values(v).forEach(walk);
      }
    };
    walk(JSON.parse(s));
  }
  check('secrets: the planted password and token appear in no document', leaks.length === 0, leaks.join(', '));
  check(`secrets: lines that carry values are cited by key and never hashed (${valueCites} citations, ${hashedValueCites} hashed)`, valueCites > 0 && hashedValueCites === 0);
  check(`secrets: other citations are hashed, so the check above is not vacuous (${hashedCode})`, hashedCode > 0);
  // The last net, on its own: the anchors upstream are already cut, so only a direct drive shows it works.
  const pats = loadSecretPatterns(LIB);
  const cases = [['https://u:p4ss@host/x', 0], ['/api/y?apiKey=abc', 6], ['/a?x=1&token=t', 6], [`see ${TOKEN}`, 4], ['/api/users', -1], ['lodash', -1]];
  const wrong = cases.filter(([t, want]) => risky(t, pats) !== want).map(([t, want]) => `${t}: ${risky(t, pats)} (want ${want})`);
  check(`secrets: the quote net finds credentials, secret query keys and secret patterns, and leaves names alone (${cases.length} cases)`, pats && wrong.length === 0, wrong.join('; '));
  const host = makeHostFilter(pats);
  const hosts = [['redis://:pw#x@cache.io:6379', 'cache.io:6379'], ['postgres://a:b/c@db.io/app', 'db.io'], ['https://API.Io/x?k=1', 'api.io'], [`https://${TOKEN}.evil.io`, '[masked]'], ['https://h:abc', '[masked]']];
  const hw = hosts.filter(([v, want]) => host(v) !== want).map(([v, want]) => `${v} -> ${host(v)} (want ${want})`);
  check(`secrets: the host filter keeps only host[:port], after the userinfo (${hosts.length} cases)`, hw.length === 0, hw.join('; '));
  // The twin: masking turned off through the one door the tests have. The same scan must now leak, or the
  // gate above is not able to see a leak at all.
  const raw = serialize(scan(copy('node-ws'), { hostFilter: (v) => String(v) }).doc);
  check('secrets twin: with masking off the planted password DOES appear (the gate can see a leak)', raw.includes(PW));
}

/* -- 4. no machine paths ------------------------------------------------------------------------------------ */
{
  const root = copy('node-ws');
  const s = serialize(scan(root).doc);
  const bad = [TMP, os.homedir(), '/Users/', '/home/', 'C:\\', 'C:/'].filter((p) => p && s.includes(p));
  check('paths: the document carries no absolute path', bad.length === 0, bad.join(', '));
  const { doc } = scan(root);
  doc.notMeasured.push({ what: path.join(root, 'x'), reason: 'planted' });
  const r = validate(doc, root);
  check('paths twin: an absolute path planted in the document is refused (machine-path)', !r.ok && r.problems.some((p) => p.code === 'machine-path'));
}

/* -- 5. cost: child processes per scan do not grow with the files -------------------------------------------- */
{
  const small = copy('go-svc');
  const big = copy('go-svc');
  for (let i = 0; i < 300; i++) fs.writeFileSync(path.join(big, `extra${i}.go`), 'package main\n\nimport "fmt"\n');
  const before1 = spawned.count; scan(small); const s1 = spawned.count - before1;
  const before2 = spawned.count; scan(big); const s2 = spawned.count - before2;
  check(`cost: a scan starts at most 2 child processes (${s1}), and 300 more files start none more (${s2})`, s1 <= 2 && s2 === s1);
}

/* -- 6. git: the listing honours .gitignore and the commit is recorded --------------------------------------- */
{
  const git = spawnSync('git', ['--version'], { encoding: 'utf8' });
  if (git.status !== 0) skip('git listing', 'git is not on PATH');
  else {
    const root = copy('go-svc');
    fs.writeFileSync(path.join(root, '.gitignore'), 'ignored/\n');
    fs.mkdirSync(path.join(root, 'ignored'));
    fs.writeFileSync(path.join(root, 'ignored', 'x.go'), 'package main\n\nimport "github.com/should/not-appear"\n');
    const g = (...a) => spawnSync('git', ['-c', 'user.email=t@example.invalid', '-c', 'user.name=t', '-c', 'commit.gpgsign=false',
      '-c', 'core.hooksPath=/dev/null', '-c', 'maintenance.auto=false', '-c', 'gc.auto=0', ...a], { cwd: root, encoding: 'utf8' });
    g('init', '-q', '.'); g('add', '-A'); const c = g('commit', '-qm', 'x');
    const head = g('rev-parse', 'HEAD').stdout.trim();
    if (c.status !== 0 || !/^[0-9a-f]{40}/.test(head)) skip('git listing', `the fixture commit failed: ${c.stderr.trim()}`);
    else {
      const { doc } = scan(root);
      check('git: the document records HEAD', doc.source && doc.source.commit === head, JSON.stringify(doc.source));
      check('git: the listing came from git', doc.coverage.listing === 'git');
      check('git: a gitignored file is not scanned', !serialize(doc).includes('should/not-appear'));
      // A committed map is one commit behind the commit that carries it; --check compares content, not commits.
      const cli2 = (...a) => spawnSync(process.execPath, [path.join(LIB, 'scan.mjs'), '--root', root, ...a], { encoding: 'utf8' });
      cli2(); g('add', '-A'); g('commit', '-qm', 'map');
      const ck = cli2('--check');
      check('git: a map committed to the repository still checks as up to date', ck.status === 0 && /up to date \(written at/.test(ck.stdout), ck.stdout + ck.stderr);
      fs.appendFileSync(path.join(root, 'main.go'), '\nimport "github.com/new/dep"\n');
      check('git twin: once the tree changes it does not', cli2('--check').status === 1);
      const walked = scan(copy('go-svc'));
      check('git twin: outside a work tree the same project is walked, with no commit', walked.doc.coverage.listing === 'walk' && !walked.doc.source);
    }
  }
}

/* -- 7. the command line ------------------------------------------------------------------------------------- */
{
  const node = process.execPath;
  const root = copy('python-svc');
  const cli = (...a) => spawnSync(node, [path.join(LIB, 'scan.mjs'), '--root', root, ...a], { encoding: 'utf8' });
  const out = path.join(root, '.crewforth', 'crew-map.json');
  const s = cli('--stdout');
  check('cli --stdout: prints the document and writes nothing', s.status === 0 && s.stdout.startsWith('{') && !fs.existsSync(out), s.stderr);
  const w = cli();
  check('cli: writes .crewforth/crew-map.json and prints its path', w.status === 0 && w.stdout.trim() === '.crewforth/crew-map.json' && fs.existsSync(out), w.stderr);
  check('cli: what --stdout printed is what was written', fs.existsSync(out) && fs.readFileSync(out, 'utf8') === s.stdout);
  const c1 = cli('--check');
  check('cli --check: rc 0 on a fresh map', c1.status === 0, c1.stdout + c1.stderr);
  fs.appendFileSync(path.join(root, 'app', 'main.py'), '\nimport boto3\n');
  const c2 = cli('--check');
  check('cli --check twin: rc 1 once the project changed', c2.status === 1, c2.stdout + c2.stderr);
  const u = cli('--nope');
  check('cli: an unknown option is usage, rc 2', u.status === 2);
  const second = path.join(TMP, 'not-written');
  fs.mkdirSync(second);
  check('cli --check: rc 1 when there is no map', spawnSync(node, [path.join(LIB, 'scan.mjs'), '--root', second, '--check'], { encoding: 'utf8' }).status === 1);
  // The shell entry: no Node it can run is rc 3, never a pass. Copied alone, so the panel's resolver is not there to find one.
  const bash = spawnSync('bash', ['--version'], { encoding: 'utf8' });
  if (bash.status !== 0) skip('crew-map.sh', 'bash is not on PATH');
  else {
    const lone = path.join(TMP, 'lone'); fs.mkdirSync(lone);
    fs.copyFileSync(path.join(LIB, 'crew-map.sh'), path.join(lone, 'crew-map.sh'));
    // The Store-stub shape: a `node` that resolves first on PATH and exits 49 without running anything. bash is found
    // the usual way: a POSIX path asked of bash (/usr/bin/bash) is not one Node can start on Windows.
    const stub = path.join(TMP, 'stub'); fs.mkdirSync(stub);
    fs.writeFileSync(path.join(stub, 'node'), '#!/bin/sh\necho "Python was not found" >&2\nexit 49\n', { mode: 0o755 });
    const stubEnv = { ...process.env, PATH: stub + path.delimiter + process.env.PATH };
    const shadowed = spawnSync('bash', ['-c', 'node --version'], { encoding: 'utf8', env: stubEnv });
    const r3 = spawnSync('bash', [path.join(lone, 'crew-map.sh'), '--root', root, '--stdout'], { encoding: 'utf8', env: stubEnv });
    if (shadowed.status !== 49) skip('crew-map.sh with a node that resolves and does not run', `the stub did not shadow node here (rc=${shadowed.status})`);
    else check('crew-map.sh: with a node that resolves and does not run, it says so and exits 3', r3.status === 3 && /not a pass/.test(r3.stderr), `rc=${r3.status} ${r3.stderr}`);
    const r0 = spawnSync('bash', [path.join(LIB, 'crew-map.sh'), '--root', root, '--stdout'], { encoding: 'utf8' });
    check('crew-map.sh twin: with Node it hands over (rc 0, a document)', r0.status === 0 && r0.stdout.startsWith('{'), `rc=${r0.status} ${r0.stderr}`);
  }
}

/* -- 8. K1: no installer ignores .crewforth/crew-map.json ----------------------------------------------------- */
{
  // The entries the installers write, read from the scripts themselves, then asked of git: a string search
  // would miss a broader pattern ('.*', '/.c*') that git would honour.
  const entries = [];
  const st = fs.readFileSync(path.join(REPO, 'start.sh'), 'utf8');
  for (const m of st.matchAll(/GI_PLAN='([^']*)'/g)) entries.push(...m[1].split(/\s+/).filter(Boolean));
  const ad = fs.readFileSync(path.join(REPO, 'adopt.sh'), 'utf8');
  for (const m of ad.matchAll(/^\s*gi_add\s+(.+)$/gm)) for (const q of m[1].matchAll(/'([^']+)'/g)) entries.push(q[1]);
  const git = spawnSync('git', ['--version'], { encoding: 'utf8' });
  if (git.status !== 0) skip('K1', 'git is not on PATH');
  else {
    const ask = (list) => {
      const d = fs.mkdtempSync(path.join(TMP, 'k1-'));
      spawnSync('git', ['init', '-q', d]);
      fs.writeFileSync(path.join(d, '.gitignore'), list.join('\n') + '\n');
      return spawnSync('git', ['check-ignore', '-q', '--no-index', '.crewforth/crew-map.json'], { cwd: d }).status;
    };
    check(`K1: the ${entries.length} installer ignore entries leave .crewforth/crew-map.json committable`, entries.length >= 6 && ask(entries) === 1, `entries: ${entries.join(' ')} · rc ${ask(entries)}`);
    check('K1 twin: the same check sees an entry that would hide it', ask([...entries, '.crewforth/']) === 0);
  }
}

/* -- 8b. what /crew-map may add: a description per module and an overview, each citing lines the scan read --------
   eval/lib/crew-map/narrative.mjs holds the rule; the scanner is run here as /crew-map runs it. */
{
  const root = copy('node-ws');
  const cli = (...a) => spawnSync(process.execPath, [path.join(LIB, 'scan.mjs'), '--root', root, ...a], { encoding: 'utf8' });
  const file = path.join(root, '.crewforth', 'crew-map.json');
  cli();
  const base = fs.readFileSync(file, 'utf8');
  const doc = JSON.parse(base);
  const mod = doc.nodes.find((x) => x.kind === 'module' && (x.evidence ?? []).length);
  const cite = `${mod.evidence[0].file}:${mod.evidence[0].line}`;
  const put = (edit) => { const d = JSON.parse(base); edit(d, d.nodes.find((x) => x.id === mod.id)); fs.writeFileSync(file, `${JSON.stringify(d, null, 2)}\n`); return cli('--validate').status; };
  const rc = {
    none: put(() => {}),
    ok: put((d, m) => { m.narrative = { text: 'Serves the HTTP API. It is the entry point.', cites: [cite] }; d.overview = { text: 'Start at the API package.', cites: [cite] }; }),
    elsewhere: put((d, m) => { m.narrative = { text: 'Serves the API.', cites: ['packages/nope/x.js:1'] }; }),
    uncited: put((d, m) => { m.narrative = { text: 'Serves the API.', cites: [] }; }),
    long: put((d, m) => { m.narrative = { text: 'One. Two. Three.', cites: [cite] }; }),
    extra: put((d, m) => { m.narrative = { text: 'Serves the API.', cites: [cite], edge: 'to the db' }; }),
    field: put((d, m) => { m.narrative = { text: 'Serves the API.', cites: [cite] }; m.name = 'renamed'; }),
  };
  check('/crew-map --validate: a description citing the module\'s own lines holds; one citing elsewhere, nothing, three sentences or an extra field does not; a scanner field changed by hand does not',
    rc.none === 0 && rc.ok === 0 && rc.elsewhere === 1 && rc.uncited === 1 && rc.long === 1 && rc.extra === 1 && rc.field === 1, JSON.stringify(rc));
  put((d, m) => { m.narrative = { text: 'Serves the HTTP API.', cites: [cite] }; });
  const checked = cli('--check').status;
  const kept = cli();
  const after = JSON.parse(fs.readFileSync(file, 'utf8'));
  check('a map with descriptions is up to date for --check, and a scan again keeps a description whose lines it still cites',
    checked === 0 && kept.status === 0 && after.nodes.find((x) => x.id === mod.id).narrative?.text === 'Serves the HTTP API.' && /1 description\(s\) kept, 0 dropped/.test(kept.stderr),
    `check ${checked}; ${kept.stderr.trim().split('\n').pop()}`);
  // CM2: a module's layer and domain, and the tour. Each rests on lines the scan read, and is refused otherwise.
  const other = doc.nodes.find((x) => x.id !== mod.id && (x.evidence ?? []).length);
  const ocite = `${other.evidence[0].file}:${other.evidence[0].line}`;
  const ext = doc.nodes.find((x) => x.kind !== 'module' && (x.evidence ?? []).length);
  const xcite = `${ext.evidence[0].file}:${ext.evidence[0].line}`;
  const stop = (id, c) => ({ node: id, text: 'Start here.', cites: [c] });
  const rc2 = {
    layered: put((d, m) => { m.narrative = { text: 'Serves the HTTP API.', cites: [cite], layer: 'api', domain: 'orders and payments' }; }),
    badLayer: put((d, m) => { m.narrative = { text: 'Serves the HTTP API.', cites: [cite], layer: 'backend' }; }),
    sentenceDomain: put((d, m) => { m.narrative = { text: 'Serves the HTTP API.', cites: [cite], domain: 'It handles orders.' }; }),
    tour: put((d) => { d.tour = [stop(mod.id, cite), stop(other.id, ocite)]; }),
    tourUnknown: put((d) => { d.tour = [stop('mod:node:nope', cite)]; }),
    tourElsewhere: put((d) => { d.tour = [stop(mod.id, ocite)]; }),
    tourTwice: put((d) => { d.tour = [stop(mod.id, cite), stop(mod.id, cite)]; }),
    tourLong: put((d) => { d.tour = Array.from({ length: 9 }, () => stop(mod.id, cite)); }),
    tourEmpty: put((d) => { d.tour = []; }),
    externalLayer: put((d) => { const x = d.nodes.find((n) => n.id === ext.id); x.narrative = { text: 'A dependency.', cites: [xcite], layer: 'data' }; }),
  };
  check('/crew-map --validate (CM2): a layer from the list and a short domain hold; a layer not on it, a domain written as a sentence, or a layer on a node that is not a module do not',
    rc2.layered === 0 && rc2.badLayer === 1 && rc2.sentenceDomain === 1 && rc2.externalLayer === 1, JSON.stringify(rc2));
  check('/crew-map --validate (CM2): a tour of nodes citing their own lines holds; a stop at no node, citing another node\'s line, a node twice, nine stops or none does not',
    rc2.tour === 0 && rc2.tourUnknown === 1 && rc2.tourElsewhere === 1 && rc2.tourTwice === 1 && rc2.tourLong === 1 && rc2.tourEmpty === 1, JSON.stringify(rc2));
  put((d) => { d.tour = [stop('mod:node:nope', cite)]; });
  const why = cli('--validate');
  check('a stop at no node is refused for that reason, not only because its cite fails', /is not a node of this map/.test(why.stdout + why.stderr), (why.stdout + why.stderr).trim().split('\n').slice(-2).join(' | '));
  put((d, m) => { m.narrative = { text: 'Serves the HTTP API.', cites: [cite], layer: 'api' }; d.tour = [stop(mod.id, cite)]; });
  const kept2 = cli();
  const after2 = JSON.parse(fs.readFileSync(file, 'utf8'));
  check('a scan again keeps the layer and the tour while their lines still hold', kept2.status === 0 && after2.nodes.find((x) => x.id === mod.id).narrative?.layer === 'api' && after2.tour?.length === 1, kept2.stderr.trim().split('\n').pop());
  check('a fresh scan writes tour: null beside overview: null', JSON.parse(base).tour === null && JSON.parse(base).overview === null);
  const f = path.join(root, mod.evidence[0].file);
  fs.writeFileSync(f, `\n${fs.readFileSync(f, 'utf8')}`);
  const moved = cli();
  const gone = JSON.parse(fs.readFileSync(file, 'utf8')).nodes.find((x) => x.id === mod.id).narrative;
  check('a description whose cited line moved is dropped by the next scan, and said (the tour on it too)', gone === null && JSON.parse(fs.readFileSync(file, 'utf8')).tour === null && /0 description\(s\) kept, 2 dropped/.test(moved.stderr),
    moved.stderr.trim().split('\n').pop());
}

/* -- 8c. a description may rest on what a module's README says about it ------------------------------------------ */
{
  const root = copy('flutter-app');
  const cli = (...a) => spawnSync(process.execPath, [path.join(LIB, 'scan.mjs'), '--root', root, ...a], { encoding: 'utf8' });
  const file = path.join(root, '.crewforth', 'crew-map.json');
  cli();
  const d = JSON.parse(fs.readFileSync(file, 'utf8'));
  const app = d.nodes.find((x) => x.id === 'mod:dart:shop_app');
  app.narrative = { text: 'The shop mobile app.', cites: ['app/README.md:10'], layer: 'ui' };
  fs.writeFileSync(file, `${JSON.stringify(d, null, 2)}\n`);
  const v = cli('--validate');
  check('a description citing the README line the scan read for the module holds', v.status === 0, (v.stdout + v.stderr).trim().split('\n').pop());
}

/* -- 9. the rules files ---------------------------------------------------------------------------------------- */
{
  const rules = JSON.parse(fs.readFileSync(path.join(LIB, 'rules', 'packages.json'), 'utf8'));
  const KINDS = new Set(['db', 'cache', 'queue', 'http-api', 'storage', 'auth', 'other']);
  const bad = [];
  for (const [eco, table] of Object.entries(rules)) {
    if (eco === 'about') continue;
    for (const [k, v] of Object.entries(table)) if (k !== 'about' && !(Array.isArray(v) && v.length === 2 && KINDS.has(v[0]) && /^[a-z0-9-]+$/.test(v[1]))) bad.push(`${eco}.${k}`);
  }
  check('rules: every package line is [kind, label] with a known kind', bad.length === 0, bad.join(', '));
}

process.stdout.write(`\ncrew-map selfcheck: ${pass} passed · ${fail} failed · ${skipped} skipped\n`);
process.exitCode = fail ? 1 : 0;
