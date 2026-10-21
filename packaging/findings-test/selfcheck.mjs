#!/usr/bin/env node
// The findings core's gate (kit/eval/lib/findings). Offline and hermetic: every project it validates against
// is built in a temp directory here, never this checkout.
//
// Each rule is driven both ways. A validator that is only shown documents it should reject is satisfied by one
// that rejects everything, so every failing case sits beside the passing twin it was made from, and a failing
// case names the CODE it must fail with: "it was rejected" is not the same as "it was rejected for this".

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { validate, stamp, write, serialize, loadSchema, SCHEMA_ID, OUT_DIR, SHAPE_KEYWORDS, LEDGER, verdictOf }
  from '../../kit/eval/lib/findings/findings.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CORE = path.resolve(HERE, '..', '..', 'kit', 'eval', 'lib', 'findings');
const CLI = path.join(CORE, 'findings.mjs');

let pass = 0; let fail = 0; let skipped = 0;
function check(name, ok, detail) {
  if (ok) pass += 1; else fail += 1;
  process.stdout.write(`${ok ? 'PASS' : 'FAIL'} ${name}${!ok && detail ? ` — ${detail}` : ''}\n`);
}
function skip(name, why) { skipped += 1; process.stdout.write(`SKIP ${name} — ${why}\n`); }

// ---- the fixture project ----------------------------------------------------------------------------------
const TMP = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'crew-findings-')));
process.on('exit', () => fs.rmSync(TMP, { recursive: true, force: true }));
const ROOT = path.join(TMP, 'project');
const put = (rel, text) => { const f = path.join(ROOT, rel); fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, text); };
put('src/app.js', "const a = 1;\nhello\napp.get('/users',   listUsers);\nconst b = 2;\n");
put('src/crlf.js', 'first\r\nhello\r\nthird\r\n');
put('src/no-newline.txt', 'only line');
put('src/empty.txt', '');
fs.writeFileSync(path.join(TMP, 'outside.txt'), 'hello\n');

// Known answers, not computed by the code under test: sha256("hello") and sha256("hello\nthird").
const SHA_HELLO = '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824';
const SHA_TWO = crypto.createHash('sha256').update('hello\nthird').digest('hex');

const finding = (over = {}) => ({
  id: 'endpoint-no-handler:users', rule: 'endpoint-no-handler', title: 'Endpoint has no handler',
  confidence: 'proven', evidence: [{ file: 'src/app.js', line: 3, text: "app.get('/users', listUsers);" }], ...over,
});
// Through JSON and back, as a document on disk would be: a member set to undefined here is a member left out.
const plain = (o) => JSON.parse(JSON.stringify(o));
const doc = (findings = [finding()], over = {}) => plain({ schema: SCHEMA_ID, producer: { name: 'selfcheck' }, findings, ...over });
const ev = (over) => doc([finding({ evidence: [{ file: 'src/app.js', line: 2, sha256: SHA_HELLO, ...over }] })]);
const codes = (r) => r.problems.map((p) => p.code).join(',');
// Holds: verified, with the counts saying the entry was actually looked at.
const holds = (name, d, n = 1) => { const r = validate(d, ROOT);
  check(name, r.ok && r.counts.evidence === n && r.counts.verified === n, `${codes(r)} ${JSON.stringify(r.counts)} ${r.problems[0]?.message ?? ''}`); };
// Fails, for the stated reason and no other.
const fails = (name, d, code, at) => { const r = validate(d, ROOT);
  check(name, !r.ok && r.problems.length > 0 && r.problems.every((p) => p.code === code) && (!at || r.problems.some((p) => p.at === at)),
    `wanted ${code}${at ? ' at ' + at : ''}, got ${r.ok ? 'a pass' : r.problems.map((p) => `${p.code}@${p.at}`).join(',')}`); };

/* -- 1. anchors ------------------------------------------------------------------------------------------- */
holds('a quoted line verifies, whitespace runs aside', doc());
holds('a sha256 anchor verifies against a known answer', ev({}));
holds('the same line in a CRLF file has the same sha256', ev({ file: 'src/crlf.js' }));
holds('a range hashes its lines joined by LF', ev({ file: 'src/crlf.js', endLine: 3, sha256: SHA_TWO }));
holds('a file with no trailing newline has its last line', ev({ file: 'src/no-newline.txt', line: 1, sha256: undefined, text: 'only line' }));
holds('both anchors on one entry, both true', ev({ text: 'hello' }));
fails('a sha256 that is not the line is stale', ev({ line: 1 }), 'stale');
fails('a quote that is not in the cited line is stale', ev({ sha256: undefined, text: 'goodbye' }), 'stale');
fails('a true sha256 does not excuse a false quote', ev({ text: 'goodbye' }), 'stale');
fails('a true quote does not excuse a false sha256', ev({ line: 1, text: 'const a' }), 'stale');
fails('a quote of only whitespace is not an anchor', ev({ sha256: undefined, text: '  \t ' }), 'shape');
fails('an entry with no anchor is refused', ev({ sha256: undefined }), 'shape', 'findings[0].evidence[0]');
{ const r = validate(ev({ line: 1 }), ROOT);
  check('a stale entry reports the sha256 it measured', /sha256 is [0-9a-f]{64}, the document says 2cf24dba/.test(r.problems[0]?.message ?? ''), r.problems[0]?.message); }

/* -- 2. range and file ------------------------------------------------------------------------------------ */
fails('a line past the end is out of range', ev({ line: 5 }), 'range');
fails('an endLine past the end is out of range', ev({ endLine: 9 }), 'range');
fails('an endLine before the line is out of range', ev({ line: 3, endLine: 2 }), 'range');
fails('an empty file has no line 1', ev({ file: 'src/empty.txt', line: 1 }), 'range');
fails('a file that is not there is missing', ev({ file: 'src/gone.js' }), 'missing');
fails('a directory is not a file', ev({ file: 'src' }), 'missing');
fails('a path spelled in another case is missing on every disk', ev({ file: 'SRC/app.js' }), 'missing');
{ const r = validate(ev({ line: 5 }), ROOT);
  check('an out-of-range entry reports how long the file is', /has 4 line\(s\)/.test(r.problems[0]?.message ?? ''), r.problems[0]?.message); }

/* -- 3. paths that leave the project ---------------------------------------------------------------------- */
for (const [file, what] of [['../outside.txt', 'a parent segment'], ['src/../../outside.txt', 'a parent segment inside'],
  [path.join(TMP, 'outside.txt').split(path.sep).join('/'), 'an absolute path'], ['C:/outside.txt', 'a drive letter'],
  ['src\\app.js', 'a backslash'], ['./src/app.js', 'a dot segment'], ['src//app.js', 'an empty segment']]) {
  // The absolute spelling also carries this machine's directory, which is its own problem; the path one is asserted.
  const r = validate(ev({ file }), ROOT);
  check(`${what} is refused as a path`, !r.ok && r.problems.some((p) => p.code === 'path') && r.counts.verified === 0, codes(r));
}
try {
  fs.symlinkSync(path.join(TMP, 'outside.txt'), path.join(ROOT, 'src', 'link.txt'));
  fails('a link that resolves outside the project is refused', ev({ file: 'src/link.txt', line: 1 }), 'path');
  fs.symlinkSync(path.join(ROOT, 'src', 'app.js'), path.join(ROOT, 'src', 'inside-link.js'));
  holds('a link that stays inside the project verifies', ev({ file: 'src/inside-link.js' }));
} catch (e) { skip('links out of and inside the project (2 checks)', `this machine cannot create a symlink: ${e.code}`); }

/* -- 4. the shape of a finding ---------------------------------------------------------------------------- */
holds('severity, detail and data are accepted', doc([finding({ severity: 'high', detail: 'x', data: { module: 'api' } })]));
holds('an inferred finding carries evidence like any other', doc([finding({ confidence: 'inferred' })]));
holds('a document with no findings is valid, and says it checked nothing', doc([]), 0);
fails('a finding with no evidence is refused', doc([finding({ evidence: [] })]), 'shape', 'findings[0].evidence');
fails('a finding without the member is refused', doc([finding({ evidence: undefined })]), 'shape');
fails('a confidence outside the two is refused', doc([finding({ confidence: 'certain' })]), 'shape', 'findings[0].confidence');
fails('a severity outside the list is refused', doc([finding({ severity: 'blocker' })]), 'shape');
fails('an unknown field on a finding is refused', doc([finding({ location: 'x' })]), 'shape');
fails('an unknown field on an entry is refused', ev({ column: 4 }), 'shape');
fails('a line that is not an integer is refused', ev({ line: 2.5 }), 'shape');
fails('a line of zero is refused', ev({ line: 0 }), 'shape');
fails('an id that is not a slug is refused', doc([finding({ id: 'Has Space' })]), 'shape');
fails('two findings with one id are refused', doc([finding(), finding()]), 'duplicate-id', 'findings[1].id');
fails('an unknown member at the root of a standalone document is refused', doc([finding()], { modules: [] }), 'shape');
fails('a document that is not an object is refused', [], 'shape');

/* -- 5. host documents ------------------------------------------------------------------------------------ */
const host = (edgeEv, over = {}) => plain({ schema: 'crewforth.crew-map/1', modules: [{ name: 'api' }],
  edges: [{ from: 'api', to: 'db', evidence: [edgeEv] }], findings: [finding()], ...over });
holds('a host document keeps its own members, and its own evidence is verified too', host({ file: 'src/app.js', line: 2, sha256: SHA_HELLO }), 2);
fails('stale evidence outside the findings is caught where it sits', host({ file: 'src/app.js', line: 1, sha256: SHA_HELLO }), 'stale', 'edges[0].evidence[0]');
fails('malformed evidence outside the findings is caught where it sits', host({ file: 'src/app.js' }), 'shape', 'edges[0].evidence[0]');
fails('an evidence member that is not an array is refused', host(null, { edges: [{ evidence: 'src/app.js:2' }] }), 'shape', 'edges[0].evidence');
fails('a host document still needs a findings array', host({ file: 'src/app.js', line: 2, sha256: SHA_HELLO }, { findings: undefined }), 'shape', 'findings');
fails('a host document needs a schema of the crewforth.<name>/<n> form', host({ file: 'src/app.js', line: 2, sha256: SHA_HELLO }, { schema: 'map' }), 'shape', 'schema');
fails('a finding in a host document is held to the same shape', host({ file: 'src/app.js', line: 2, sha256: SHA_HELLO }, { findings: [finding({ confidence: 'maybe' })] }), 'shape');

/* -- 6. this machine's directories ------------------------------------------------------------------------ */
fails("the project's own directory in a string is refused", doc([finding({ detail: `see ${ROOT}/src/app.js` })]), 'machine-path', 'findings[0].detail');
holds('the same sentence with a relative path is accepted', doc([finding({ detail: 'see src/app.js' })]));

/* -- 7. stamp --------------------------------------------------------------------------------------------- */
{ const d = ev({ sha256: undefined, text: 'hello' }); const r = stamp(d, ROOT);
  check('stamp writes the known sha256 onto a verified entry and keeps the quote', r.ok && d.findings[0].evidence[0].sha256 === SHA_HELLO && d.findings[0].evidence[0].text === 'hello', JSON.stringify(d.findings[0].evidence[0])); }
{ const d = ev({ sha256: undefined, text: 'hello' }); const r = stamp(d, ROOT, { redact: true });
  check('stamp --redact leaves the hash and drops the quote, and the result still verifies', r.ok && !('text' in d.findings[0].evidence[0]) && validate(d, ROOT).ok, JSON.stringify(d.findings[0].evidence[0])); }
{ const d = ev({ sha256: undefined, text: 'goodbye' }); const r = stamp(d, ROOT);
  check('stamp never hashes an entry that did not verify', !r.ok && !('sha256' in d.findings[0].evidence[0]), JSON.stringify(d.findings[0].evidence[0])); }

/* -- 8. write --------------------------------------------------------------------------------------------- */
{
  const f1 = finding({ id: 'b-second' }); const f2 = finding({ id: 'a-first' });
  const out = path.join(ROOT, OUT_DIR, 'crew-map.json');
  const r = write(doc([f1, f2]), ROOT, 'crew-map');
  const bytes1 = fs.existsSync(out) ? fs.readFileSync(out, 'utf8') : '';
  check('write puts a verified document at .crewforth/crew-map.json', r.ok && r.file === '.crewforth/crew-map.json' && bytes1.length > 0, JSON.stringify(r.problems));
  check('the stored findings are in id order and the file ends in one newline',
    JSON.parse(bytes1 || '{"findings":[]}').findings.map((f) => f.id).join() === 'a-first,b-second' && /[^\n]\n$/.test(bytes1) && !bytes1.includes('\r'));
  write(doc([f2, f1]), ROOT, 'crew-map');
  check('the same findings in another order give the same bytes', bytes1 !== '' && fs.readFileSync(out, 'utf8') === bytes1);
  check('what was written validates when read back', validate(JSON.parse(bytes1 || 'null'), ROOT).ok);
  const r2 = write(ev({ line: 1 }), ROOT, 'audit');
  check('a document that does not verify is not written', !r2.ok && !fs.existsSync(path.join(ROOT, OUT_DIR, 'audit.json')));
  check('nothing but the document is left in the directory', fs.readdirSync(path.join(ROOT, OUT_DIR)).join() === 'crew-map.json', fs.readdirSync(path.join(ROOT, OUT_DIR)).join());
  let threw = ''; try { write(doc(), ROOT, '../escape'); } catch (e) { threw = e.message; }
  check('a name that is not a slug is refused', /must match/.test(threw) && !fs.existsSync(path.join(TMP, 'escape.json')), threw);
  const ROOT2 = path.join(TMP, 'linked'); fs.mkdirSync(path.join(ROOT2, 'src'), { recursive: true });
  fs.writeFileSync(path.join(ROOT2, 'src', 'app.js'), "x\nhello\napp.get('/users', listUsers);\n");
  fs.mkdirSync(path.join(TMP, 'elsewhere'));
  try {
    fs.symlinkSync(path.join(TMP, 'elsewhere'), path.join(ROOT2, OUT_DIR), 'dir');
    let t2 = ''; try { write(doc(), ROOT2, 'crew-map'); } catch (e) { t2 = e.message; }
    check('an output directory that is a link elsewhere is refused', /not a directory of this project/.test(t2) && fs.readdirSync(path.join(TMP, 'elsewhere')).length === 0, t2);
  } catch (e) { skip('an output directory that is a link elsewhere (1 check)', `this machine cannot create a symlink: ${e.code}`); }
  check('serialize does not reorder the caller\'s own array', (() => { const d = doc([f1, f2]); serialize(d); return d.findings[0].id === 'b-second'; })());
}

/* -- 9. the command line ---------------------------------------------------------------------------------- */
const run = (args, input) => spawnSync(process.execPath, [CLI, ...args], { input, encoding: 'utf8', cwd: TMP });
const good = JSON.stringify(doc()); const bad = JSON.stringify(ev({ line: 1 }));
{ const r = run(['validate', '--root', ROOT, '-'], good);
  check('validate: rc 0 and a line that says how many entries it checked', r.status === 0 && /1 finding\(s\) · 1 evidence entry checked · 1 verified · 0 problem\(s\)/.test(r.stdout), `rc=${r.status} ${r.stdout}${r.stderr}`); }
{ const r = run(['validate', '--root', ROOT, '-'], bad);
  check('validate: rc 1 and the failing entry named', r.status === 1 && /FAIL findings\[0\]\.evidence\[0\]: stale/.test(r.stdout), `rc=${r.status} ${r.stdout}${r.stderr}`); }
{ const r = run(['validate', '--root', ROOT, '--json', '-'], bad); let j = null; try { j = JSON.parse(r.stdout); } catch { /* reported below */ }
  check('validate --json: a report a program can read', r.status === 1 && j && j.ok === false && j.problems[0].code === 'stale' && j.counts.evidence === 1 && !('held' in j), `rc=${r.status} ${r.stdout}`); }
{ const f = path.join(TMP, 'doc.json'); fs.writeFileSync(f, good); const r = run(['validate', '--root', ROOT, f]);
  check('validate reads a file as well as stdin', r.status === 0, `rc=${r.status} ${r.stderr}`); }
{ const r = spawnSync(process.execPath, [CLI, 'validate', '-'], { input: good, encoding: 'utf8', cwd: ROOT });
  check('the root defaults to the working directory', r.status === 0, `rc=${r.status} ${r.stdout}${r.stderr}`); }
{ const r = run(['validate', '--root', ROOT, '-'], '{not json');
  check('a document that is not JSON is rc 2, not a failed finding', r.status === 2 && /could not be read as JSON/.test(r.stderr), `rc=${r.status} ${r.stderr}`); }
{ const r = run(['validate', '--root', path.join(TMP, 'nowhere'), '-'], good);
  check('a root that is not a directory is rc 2', r.status === 2, `rc=${r.status} ${r.stderr}`); }
{ const r = run(['approve', '-'], good); const r2 = run(['validate'], good); const r3 = run(['validate', '--redact', '-'], good);
  check('an unknown operation, a missing document and a foreign option are rc 2', r.status === 2 && r2.status === 2 && r3.status === 2, `${r.status} ${r2.status} ${r3.status}`); }
{ const r = run(['stamp', '--root', ROOT, '--redact', '-'], JSON.stringify(ev({ sha256: undefined, text: 'hello' }))); let j = null; try { j = JSON.parse(r.stdout); } catch { /* below */ }
  check('stamp: the stamped document on stdout, the summary on stderr', r.status === 0 && j && j.findings[0].evidence[0].sha256 === SHA_HELLO && !('text' in j.findings[0].evidence[0]) && /1 verified/.test(r.stderr), `rc=${r.status} ${r.stdout}${r.stderr}`); }
{ const r = run(['stamp', '--root', ROOT, '-'], bad);
  check('stamp: nothing on stdout when an entry does not verify', r.status === 1 && r.stdout === '', `rc=${r.status} ${r.stdout}`); }
{ const r = run(['write', '--root', ROOT, 'cli-out', '-'], good);
  check('write: prints the path it wrote', r.status === 0 && r.stdout.trim() === '.crewforth/cli-out.json' && fs.existsSync(path.join(ROOT, OUT_DIR, 'cli-out.json')), `rc=${r.status} ${r.stdout}${r.stderr}`); }
{ const r = run(['write', '--root', ROOT, 'cli-bad', '-'], bad);
  check('write: rc 1 and no file for an unverified document', r.status === 1 && /nothing was written/.test(r.stderr) && !fs.existsSync(path.join(ROOT, OUT_DIR, 'cli-bad.json')), `rc=${r.status} ${r.stderr}`); }
{ const r = run(['schema']); let j = null; try { j = JSON.parse(r.stdout); } catch { /* below */ }
  check('schema: prints the shipped schema', r.status === 0 && j && j.$id === SCHEMA_ID, `rc=${r.status}`); }

/* -- 9b. verification: refuters, and the ledger only the hook writes ------------------------------------- */
{
  // A ledger in the fixture project, where --verified looks for it, written here the way the hook writes it.
  const ledgerAt = path.join(ROOT, LEDGER);
  fs.mkdirSync(path.dirname(ledgerAt), { recursive: true });
  const row = (agent, finding, lens, verdict) => `2026-10-14T00:00:00Z\ts1\t${agent}\t${finding}\t${lens}\t${verdict}\n`;
  const ID = 'endpoint-no-handler:users';
  fs.writeFileSync(ledgerAt, 'ts\tsession\tagent_id\tfinding\tlens\tverdict\n'
    + row('a1', ID, 'protection', 'TRUE_POSITIVE') + row('a2', ID, 'reachability', 'TRUE_POSITIVE') + row('a3', ID, 'reproduction', 'TRUE_POSITIVE')
    + row('b1', ID, 'protection', 'FALSE_POSITIVE') + row('c1', 'other:id', 'reachability', 'TRUE_POSITIVE'));
  const vf = (r) => ({ verdict: verdictOf(r.map((x) => x[2])), verifiers: r.map(([agent, lens, verdict]) => ({ agent, lens, verdict })) });
  const V = (d) => validate(d, ROOT, { verified: true });
  const vholds = (name, d) => { const r = V(d); check(name, r.ok, `${codes(r)} ${r.problems[0]?.message ?? ''}`); };
  const vfails = (name, d, code) => { const r = V(d); check(name, !r.ok && r.problems.every((p) => p.code === code),
    `wanted ${code}, got ${r.ok ? 'a pass' : r.problems.map((p) => `${p.code}@${p.at}: ${p.message}`).join('; ')}`); };
  const one = [['a1', 'protection', 'TRUE_POSITIVE']];
  const three = [['a1', 'protection', 'TRUE_POSITIVE'], ['a2', 'reachability', 'TRUE_POSITIVE'], ['a3', 'reproduction', 'TRUE_POSITIVE']];
  vfails('verified: a medium finding with no verification is refused', doc([finding({ severity: 'medium' })]), 'unverified');
  check('verified twin: without --verified the same document holds', validate(doc([finding({ severity: 'medium' })]), ROOT).ok);
  vholds('verified: a medium finding with one ledger-backed verifier holds', doc([finding({ severity: 'medium', verification: vf(one) })]));
  vholds('verified: a low finding needs no verifier (not in the x-verifiers table)', doc([finding({ severity: 'low' })]));
  vfails('verified: a high finding with one verifier is refused (needs 3)', doc([finding({ severity: 'high', verification: vf(one) })]), 'unverified');
  vholds('verified: a high finding with three ledger-backed verifiers on three lenses holds', doc([finding({ severity: 'high', verification: vf(three) })]));
  vfails('verified: a verifier the ledger does not have is refused', doc([finding({ severity: 'medium', verification: vf([['zz', 'protection', 'TRUE_POSITIVE']]) })]), 'ledger');
  vfails('verified: a ledger line for another finding does not count', doc([finding({ severity: 'medium', verification: vf([['c1', 'reachability', 'TRUE_POSITIVE']]) })]), 'ledger');
  vfails('verified: the ledger said FALSE_POSITIVE, the document says TRUE_POSITIVE: refused',
    doc([finding({ severity: 'medium', verification: vf([['b1', 'protection', 'TRUE_POSITIVE']]) })]), 'ledger');
  fails('verification: a verdict its verifiers do not give is refused',
    doc([finding({ verification: { verdict: 'TRUE_POSITIVE', verifiers: [{ agent: 'a1', lens: 'protection', verdict: 'TRUE_POSITIVE' }, { agent: 'b1', lens: 'reachability', verdict: 'FALSE_POSITIVE' }] } })]), 'verification');
  fails('verification: one agent counted twice is refused', doc([finding({ verification: vf([['a1', 'protection', 'TRUE_POSITIVE'], ['a1', 'reachability', 'TRUE_POSITIVE']]) })]), 'verification');
  fails('verification: one lens twice is refused', doc([finding({ verification: vf([['a1', 'protection', 'TRUE_POSITIVE'], ['a2', 'protection', 'TRUE_POSITIVE']]) })]), 'verification');
  fails('verification: a FALSE_POSITIVE that keeps its severity is refused', doc([finding({ severity: 'medium', verification: vf([['b1', 'protection', 'FALSE_POSITIVE']]) })]), 'verification');
  vholds('verification twin: the same FALSE_POSITIVE without a severity holds, and stays on record', doc([finding({ verification: vf([['b1', 'protection', 'FALSE_POSITIVE']]) })]));
  check('verdictOf: one FALSE_POSITIVE outweighs, then CANNOT_VERIFY, then TRUE_POSITIVE',
    verdictOf(['TRUE_POSITIVE', 'FALSE_POSITIVE', 'CANNOT_VERIFY']) === 'FALSE_POSITIVE' && verdictOf(['TRUE_POSITIVE', 'CANNOT_VERIFY']) === 'CANNOT_VERIFY' && verdictOf(['TRUE_POSITIVE']) === 'TRUE_POSITIVE');
  // The ledger is read from the project, at one fixed path. Elsewhere, or absent, is no ledger at all.
  const moved = ledgerAt + '.away'; fs.renameSync(ledgerAt, moved);
  vfails('verified: with no ledger in the project a verifier cannot be backed', doc([finding({ severity: 'medium', verification: vf(one) })]), 'ledger');
  fs.renameSync(moved, ledgerAt);
  const d1 = JSON.stringify(doc([finding({ severity: 'medium', verification: vf(one) })]));
  const c1 = run(['validate', '--root', ROOT, '--verified', '-'], d1);
  check('cli: validate --verified reads the project\'s ledger (rc 0)', c1.status === 0, c1.stdout + c1.stderr);
  const c2 = run(['validate', '--root', ROOT, '--ledger', ledgerAt, '-'], d1);
  check('cli: there is no --ledger: a path the caller names is one the caller could write (usage, rc 2)', c2.status === 2, `rc=${c2.status}`);
  const c3 = run(['write', '--root', ROOT, '--verified', 'v-bad', '-'], JSON.stringify(doc([finding({ severity: 'high', verification: vf(one) })])));
  check('cli: write --verified refuses an under-verified document and writes nothing', c3.status === 1 && !fs.existsSync(path.join(ROOT, OUT_DIR, 'v-bad.json')), `rc=${c3.status}`);
  fs.rmSync(path.dirname(path.dirname(ledgerAt)), { recursive: true, force: true });
}

/* -- 10. one definition of the shape ---------------------------------------------------------------------- */
{
  const schema = loadSchema();
  // x-verifiers is not a shape keyword: it is the verification rule's table, read and enforced by validate --verified.
  const NOTES = ['$schema', '$id', 'title', 'description', '$defs', 'x-verifiers'];
  const unknown = new Set();
  // A keyword is a key of a schema object; the keys of "properties" and "$defs" are names, not keywords.
  (function walk(s) {
    if (Array.isArray(s)) { s.forEach(walk); return; }
    if (!s || typeof s !== 'object') return;
    for (const [k, v] of Object.entries(s)) {
      if (!SHAPE_KEYWORDS.includes(k) && !NOTES.includes(k)) unknown.add(k);
      if (k === 'properties' || k === '$defs') Object.values(v).forEach(walk);
      else if (k === 'items' || k === 'anyOf') walk(v);
    }
  }(schema));
  check('the schema uses only keywords the validator enforces', unknown.size === 0, [...unknown].join(','));
  check('the schema names itself as the validator does', schema.$id === SCHEMA_ID && schema.properties.schema.const === SCHEMA_ID);
  const src = fs.readFileSync(CLI, 'utf8');
  check('the validator holds no list of its own for confidence or severity', !/proven|inferred|critical/.test(src.replace(/^\s*\/\/.*$/gm, '')));
}

/* -- 11. the shell entry ---------------------------------------------------------------------------------- */
{
  const bash = spawnSync('bash', ['-c', 'echo ok'], { encoding: 'utf8' });
  if (bash.status !== 0) skip('the shell entry (3 checks)', 'bash is not on PATH');
  else {
    // A copy with nothing beside it, so the panel's resolver is not there to find a runtime behind our back.
    const lone = path.join(TMP, 'lone', 'a', 'b', 'c'); fs.mkdirSync(lone, { recursive: true });
    for (const f of ['findings.sh', 'findings.mjs', 'findings.schema.json']) fs.copyFileSync(path.join(CORE, f), path.join(lone, f));
    const sh = (env, input, args) => spawnSync('bash', [path.join(lone, 'findings.sh'), ...args], { input, encoding: 'utf8', env });
    const withNode = { ...process.env, PATH: path.dirname(process.execPath) + path.delimiter + process.env.PATH };
    const r1 = sh(withNode, good, ['validate', '--root', ROOT, '-']);
    check('findings.sh hands a good document through with rc 0', r1.status === 0 && /1 verified/.test(r1.stdout), `rc=${r1.status} ${r1.stdout}${r1.stderr}`);
    const r2 = sh(withNode, bad, ['validate', '--root', ROOT, '-']);
    // rc 1 alone is what Node gives when it cannot find findings.mjs at all, so the summary line must be there too.
    check('findings.sh hands a failing document through with rc 1', r2.status === 1 && /\b1 problem\(s\)/.test(r2.stdout), `rc=${r2.status} ${r2.stdout}${r2.stderr}`);
    // The Store-stub shape: a `node` that resolves first on PATH and exits 49 without running anything.
    const stub = path.join(TMP, 'stub'); fs.mkdirSync(stub);
    fs.writeFileSync(path.join(stub, 'node'), '#!/bin/sh\necho "Python was not found" >&2\nexit 49\n', { mode: 0o755 });
    const r3 = sh({ ...process.env, PATH: stub + path.delimiter + process.env.PATH }, good, ['validate', '--root', ROOT, '-']);
    const shadowed = spawnSync('bash', ['-c', 'node --version'], { encoding: 'utf8', env: { ...process.env, PATH: stub + path.delimiter + process.env.PATH } });
    if (shadowed.status !== 49) skip('findings.sh with a node that resolves and does not run (1 check)', `the stub did not shadow node here (rc=${shadowed.status})`);
    else check('with a node that resolves and does not run, findings.sh says nothing was checked and exits 3', r3.status === 3 && /not a pass/.test(r3.stderr) && r3.stdout === '', `rc=${r3.status} ${r3.stdout}${r3.stderr}`);
  }
}

process.stdout.write(`${pass}/${pass + fail} assertions passed${skipped ? `, ${skipped} skipped` : ''}\n`);
process.exit(fail ? 1 : 0);
