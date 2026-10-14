#!/usr/bin/env node
// findings.mjs — the evidence-backed findings core: one document shape, and a validator that holds every
// finding to the lines it cites.
//
//   node findings.mjs validate [--root DIR] [--verified] [--json] FILE|-    rc 0 = every entry verified · 1 = at least one problem
//   node findings.mjs stamp    [--root DIR] [--verified] [--redact] FILE|-  the document on stdout with a sha256 on each verified entry
//   node findings.mjs write    [--root DIR] [--verified] NAME FILE|-        validate, then write DIR/.crewforth/NAME.json
//   node findings.mjs schema                                   the schema, as shipped
//       rc 2 = usage, or a document that could not be read as a JSON object. Nothing is written on a non-zero rc.
//
// Host-independent on purpose: plain JSON in, plain JSON and an exit code out, Node's standard library only. It
// reads no hook payload, no settings file and no environment variable, so the same file serves a scanner, a CI
// job and an assistant; whatever is specific to one host belongs in the caller.
//
// The shape lives in findings.schema.json beside this file and is READ from there, so there is one definition.
// What a schema cannot say is checked here, against the project at --root (default: the working directory):
//
//   path      the cited file is a relative, forward-slash path with no '.' or '..' segment, spelled exactly as
//             the directory lists it (a case-insensitive disk would otherwise verify a path that another
//             machine cannot open), and it resolves inside the project after symlinks
//   missing   the file is there and is a regular file
//   range     line..endLine exist in it
//   stale     the anchor still matches: sha256 of the cited lines, and/or the quoted text is in them
//   machine-path   no string in the document carries this machine's project or home directory
//   verification   a finding's verdict is the one its verifiers' verdicts give, its verifiers are distinct agents on
//                  distinct lenses, and only a TRUE_POSITIVE keeps a severity
//   --verified     every finding of a severity in the schema's x-verifiers table has that many verifiers, and every
//                  verifier is a line of the refuter ledger, .claude/state/crew-refuter.tsv under --root, which only
//                  Crewforth's SubagentStop hook writes. The path is fixed on purpose: a ledger the caller could name
//                  is one the caller could write.
//
// A document is either standalone ("schema": "crewforth.findings/1", held to the whole schema) or a host
// document with its own "schema": "crewforth.<name>/<n>" and a "findings" array in the same shape. In both,
// EVERY "evidence" array is verified wherever it sits, so a host document can put evidence on its own objects
// (an edge, a module) and have it held to the same standard.
//
// Not checked: that the cited lines actually support the finding's claim. That is a judgement; this proves only
// that the lines exist and are the ones the producer read.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

const SELF = fileURLToPath(import.meta.url);
export const SCHEMA_ID = 'crewforth.findings/1';
export const OUT_DIR = '.crewforth';
const HOST_SCHEMA = /^crewforth\.[a-z][a-z0-9-]*\/[1-9][0-9]*$/;
const OUT_NAME = /^[a-z0-9][a-z0-9-]*$/;
const MAX_FILE_BYTES = 32 * 1024 * 1024;

export function loadSchema() {
  return JSON.parse(fs.readFileSync(path.join(path.dirname(SELF), 'findings.schema.json'), 'utf8'));
}

// ---- shape: the subset of JSON Schema that findings.schema.json uses --------------------------------------
// $ref into $defs, type, const, enum, pattern, min/maxLength, minimum, minItems, items, required, properties,
// additionalProperties:false, anyOf. A keyword outside this list in the schema is a bug the selfcheck pins.
export const SHAPE_KEYWORDS = ['$ref', 'type', 'const', 'enum', 'pattern', 'minLength', 'maxLength', 'minimum',
  'minItems', 'items', 'required', 'properties', 'additionalProperties', 'anyOf'];

const kind = (v) => (v === null ? 'null' : Array.isArray(v) ? 'array'
  : Number.isInteger(v) ? 'integer' : typeof v);
const show = (v) => { const s = JSON.stringify(v); return s === undefined ? String(v) : s.length > 80 ? s.slice(0, 77) + '...' : s; };

function shape(v, s, at, schema, out) {
  if (s.$ref) s = s.$ref.replace(/^#\//, '').split('/').reduce((o, k) => o[k], schema);
  const bad = (message) => out.push({ at, code: 'shape', message });
  if ('const' in s && v !== s.const) return bad(`must be ${show(s.const)}, is ${show(v)}`);
  if (s.enum && !s.enum.includes(v)) return bad(`must be one of ${s.enum.join(' | ')}, is ${show(v)}`);
  if (s.type && kind(v) !== s.type) return bad(`must be of type ${s.type}, is ${show(v)}`);
  if (typeof v === 'string') {
    if (s.minLength !== undefined && v.length < s.minLength) bad(`is shorter than ${s.minLength}`);
    if (s.maxLength !== undefined && v.length > s.maxLength) bad(`is longer than ${s.maxLength} (${v.length})`);
    if (s.pattern && !new RegExp(s.pattern).test(v)) bad(`must match ${s.pattern}, is ${show(v)}`);
  }
  if (typeof v === 'number' && s.minimum !== undefined && v < s.minimum) bad(`must be at least ${s.minimum}, is ${v}`);
  if (Array.isArray(v)) {
    if (s.minItems !== undefined && v.length < s.minItems) bad(`needs at least ${s.minItems} entr${s.minItems === 1 ? 'y' : 'ies'}, has ${v.length}`);
    if (s.items) v.forEach((x, i) => shape(x, s.items, `${at}[${i}]`, schema, out));
  }
  if (kind(v) === 'object') {
    for (const k of s.required || []) if (!(k in v)) bad(`"${k}" is required`);
    for (const k of Object.keys(v)) {
      if (s.properties && k in s.properties) shape(v[k], s.properties[k], at ? `${at}.${k}` : k, schema, out);
      else if (s.additionalProperties === false) bad(`"${k}" is not a field of this object`);
    }
    if (s.anyOf && !s.anyOf.some((alt) => { const o = []; shape(v, alt, at, schema, o); return o.length === 0; })) {
      bad(`needs one of: ${s.anyOf.map((alt) => (alt.required || []).join('+')).join(' | ')}`);
    }
  }
}

// ---- evidence: a cited range, held against the project ----------------------------------------------------
const squash = (t) => t.replace(/\s+/g, ' ').trim();

function unsafePath(file) {
  if (file.includes('\0')) return 'contains a NUL';
  if (file.includes('\\')) return 'uses a backslash; write forward slashes';
  if (file.startsWith('/') || /^[A-Za-z]:/.test(file)) return 'is absolute; write it relative to the project root';
  for (const seg of file.split('/')) {
    if (seg === '' || seg === '.' || seg === '..') return `has ${seg === '' ? 'an empty' : `a "${seg}"`} segment`;
  }
  return '';
}

// One project, opened once: directory listings and file lines are cached for the run.
export function openProject(root) {
  const real = fs.realpathSync(root);
  const dirs = new Map();
  const files = new Map();
  const list = (dir) => {
    if (!dirs.has(dir)) { let names = null; try { names = new Set(fs.readdirSync(dir)); } catch { /* not a directory */ } dirs.set(dir, names); }
    return dirs.get(dir);
  };
  // { lines: Buffer[] } or { code, message }
  const read = (file) => {
    if (files.has(file)) return files.get(file);
    const done = (r) => { files.set(file, r); return r; };
    const why = unsafePath(file);
    if (why) return done({ code: 'path', message: `${show(file)} ${why}` });
    let abs = real;
    for (const seg of file.split('/')) {
      const names = list(abs);
      if (!names || !names.has(seg)) return done({ code: 'missing', message: `${file}: no "${seg}" with that exact spelling in the project` });
      abs = path.join(abs, seg);
    }
    let target;
    try { target = fs.realpathSync(abs); } catch { return done({ code: 'missing', message: `${file}: a link that leads nowhere` }); }
    if (target !== real && !target.startsWith(real + path.sep)) return done({ code: 'path', message: `${file} resolves outside the project` });
    const st = fs.statSync(target);
    if (!st.isFile()) return done({ code: 'missing', message: `${file} is not a regular file` });
    if (st.size > MAX_FILE_BYTES) return done({ code: 'unreadable', message: `${file} is ${st.size} bytes; the limit is ${MAX_FILE_BYTES}` });
    const buf = fs.readFileSync(target);
    const lines = [];
    for (let from = 0; from < buf.length;) {
      let nl = buf.indexOf(0x0a, from);
      if (nl === -1) nl = buf.length;
      let to = nl;
      if (to > from && buf[to - 1] === 0x0d) to--;
      lines.push(buf.subarray(from, to));
      from = nl + 1;
    }
    return done({ lines });
  };
  return { root: real, read };
}

// The anchor's bytes: the cited lines joined by LF, CR at line ends already removed, no trailing newline.
function rangeOf(project, ev) {
  const f = project.read(ev.file);
  if (!f.lines) return f;
  const end = ev.endLine === undefined ? ev.line : ev.endLine;
  if (end < ev.line) return { code: 'range', message: `${ev.file}: endLine ${end} is before line ${ev.line}` };
  if (end > f.lines.length) return { code: 'range', message: `${ev.file}:${ev.line}${end > ev.line ? '-' + end : ''} is past the end; the file has ${f.lines.length} line(s)` };
  const parts = [];
  for (let i = ev.line; i <= end; i++) { if (i > ev.line) parts.push(Buffer.from('\n')); parts.push(f.lines[i - 1]); }
  const bytes = Buffer.concat(parts);
  return { bytes, sha256: crypto.createHash('sha256').update(bytes).digest('hex'), where: `${ev.file}:${ev.line}${end > ev.line ? '-' + end : ''}` };
}

// null when the entry holds; otherwise { code, message }. `ev` has already passed the shape check.
export function checkEvidence(project, ev) {
  const r = rangeOf(project, ev);
  if (!r.bytes) return r;
  if (ev.sha256 !== undefined && ev.sha256 !== r.sha256) {
    return { code: 'stale', message: `${r.where} sha256 is ${r.sha256}, the document says ${ev.sha256}` };
  }
  if (ev.text !== undefined) {
    const want = squash(ev.text);
    if (want === '') return { code: 'shape', message: `${r.where} "text" is only whitespace` };
    if (!squash(r.bytes.toString('utf8')).includes(want)) return { code: 'stale', message: `${r.where} does not contain the quoted text ${show(want)}` };
  }
  return null;
}

// Every "evidence" member in the document, with its JSON path. The key is the contract: a host document that
// puts evidence anywhere gets it verified, and one that names the member differently gets nothing — which the
// counts in the report make visible.
function evidenceArrays(v, at, out) {
  if (Array.isArray(v)) v.forEach((x, i) => evidenceArrays(x, `${at}[${i}]`, out));
  else if (v && typeof v === 'object') {
    for (const k of Object.keys(v)) {
      const here = at ? `${at}.${k}` : k;
      if (k === 'evidence') out.push({ at: here, value: v[k] });
      else evidenceArrays(v[k], here, out);
    }
  }
  return out;
}

function strings(v, at, out) {
  if (typeof v === 'string') out.push({ at, value: v });
  else if (Array.isArray(v)) v.forEach((x, i) => strings(x, `${at}[${i}]`, out));
  else if (v && typeof v === 'object') for (const k of Object.keys(v)) strings(v[k], at ? `${at}.${k}` : k, out);
  return out;
}

// The spellings of this machine's project and home directory that must not travel in a document. A root or a
// home of three characters or fewer ("/", "C:\") is skipped: it would match every path there is.
function machinePaths(rootGiven, rootReal) {
  const set = new Set();
  for (const p of [path.resolve(rootGiven), rootReal, os.homedir()]) {
    if (!p || p.length <= 3) continue;
    set.add(p); set.add(p.split(path.sep).join('/'));
  }
  return [...set];
}

// { ok, schema, counts: { findings, evidence, verified }, problems: [{ at, code, message }], held: [entry…] }
export function validate(doc, root = '.', opts = {}) {
  const problems = [];
  const counts = { findings: 0, evidence: 0, verified: 0 };
  const held = [];
  const report = () => ({ ok: problems.length === 0, schema: doc && doc.schema, counts, problems, held });
  if (kind(doc) !== 'object') { problems.push({ at: '', code: 'shape', message: `the document must be a JSON object, is ${show(doc)}` }); return report(); }
  const schema = loadSchema();
  const FINDING = { $ref: '#/$defs/finding' }; const EVIDENCE = { $ref: '#/$defs/evidence' };
  if (doc.schema === SCHEMA_ID) shape(doc, schema, '', schema, problems);
  else {
    if (typeof doc.schema !== 'string' || !HOST_SCHEMA.test(doc.schema)) problems.push({ at: 'schema', code: 'shape', message: `must be "${SCHEMA_ID}" or a host document's "crewforth.<name>/<n>", is ${show(doc.schema)}` });
    if (!Array.isArray(doc.findings)) problems.push({ at: 'findings', code: 'shape', message: `must be an array, is ${show(doc.findings)}` });
    else doc.findings.forEach((f, i) => shape(f, FINDING, `findings[${i}]`, schema, problems));
  }
  if (Array.isArray(doc.findings)) {
    counts.findings = doc.findings.length;
    const seen = new Map();
    doc.findings.forEach((f, i) => {
      if (!f || typeof f.id !== 'string') return;
      if (seen.has(f.id)) problems.push({ at: `findings[${i}].id`, code: 'duplicate-id', message: `${show(f.id)} is also findings[${seen.get(f.id)}]` });
      else seen.set(f.id, i);
    });
  }
  const project = openProject(root);
  for (const m of machinePaths(root, project.root)) {
    for (const s of strings(doc, '', [])) {
      if (s.value.includes(m)) problems.push({ at: s.at, code: 'machine-path', message: `carries this machine's directory ${show(m)}` });
    }
  }
  const inFinding = /^findings\[\d+\]\.evidence$/;
  for (const arr of evidenceArrays(doc, '', [])) {
    if (!Array.isArray(arr.value)) { problems.push({ at: arr.at, code: 'shape', message: `must be an array, is ${show(arr.value)}` }); continue; }
    arr.value.forEach((ev, i) => {
      const at = `${arr.at}[${i}]`;
      counts.evidence++;
      // A finding's evidence was already shaped, and reported, with the finding; evidence anywhere else is
      // reported here. Either way an entry that is not well-formed is not taken to the project.
      const o = []; shape(ev, EVIDENCE, at, schema, o);
      if (o.length) { if (!inFinding.test(arr.at)) problems.push(...o); return; }
      const p = checkEvidence(project, ev);
      if (p) problems.push({ at, ...p }); else { counts.verified++; held.push(ev); }
    });
  }
  if (Array.isArray(doc.findings)) verification(doc.findings, schema, project, opts, problems);
  return report();
}

// ---- verification: what refuters concluded, and the ledger it must come from -------------------------------
export const LEDGER = path.join('.claude', 'state', 'crew-refuter.tsv');
// The verdict a set of verifiers gives: one that shows the claim wrong outweighs the rest, an open question
// outweighs agreement. The producer writes it down; it does not get to choose it.
export function verdictOf(verdicts) {
  if (verdicts.includes('FALSE_POSITIVE')) return 'FALSE_POSITIVE';
  if (verdicts.includes('CANNOT_VERIFY')) return 'CANNOT_VERIFY';
  return 'TRUE_POSITIVE';
}
// { rows: [{ agent, finding, lens, verdict }] } or { error }
export function readLedger(file) {
  let text;
  try { text = fs.readFileSync(file, 'utf8'); } catch { return { error: `no refuter ledger at ${LEDGER.split(path.sep).join('/')}` }; }
  const rows = [];
  for (const line of text.split('\n')) {
    const c = line.replace(/\r$/, '').split('\t');
    if (c.length < 6 || c[0] === 'ts') continue;
    rows.push({ agent: c[2], finding: c[3], lens: c[4], verdict: c[5] });
  }
  return { rows };
}
function verification(findings, schema, project, opts, problems) {
  const table = opts.verified ? (schema['x-verifiers'] || {}) : {};
  let ledger = null;
  findings.forEach((f, i) => {
    if (!f || typeof f !== 'object') return;
    const at = `findings[${i}]`;
    const v = f.verification;
    const ok = v && typeof v === 'object' && Array.isArray(v.verifiers) && v.verifiers.every((x) => x && typeof x === 'object');
    if (ok) {
      const want = verdictOf(v.verifiers.map((x) => x.verdict));
      if (v.verdict !== want) problems.push({ at: `${at}.verification.verdict`, code: 'verification', message: `is ${show(v.verdict)}; its verifiers give ${want}` });
      const agents = v.verifiers.map((x) => x.agent); const lenses = v.verifiers.map((x) => x.lens);
      if (new Set(agents).size !== agents.length) problems.push({ at: `${at}.verification.verifiers`, code: 'verification', message: 'names one agent twice: one context counted as two verifiers' });
      if (new Set(lenses).size !== lenses.length) problems.push({ at: `${at}.verification.verifiers`, code: 'verification', message: 'repeats a lens: the same method twice is repetition, not confirmation' });
      if (f.severity !== undefined && v.verdict !== 'TRUE_POSITIVE') problems.push({ at: `${at}.severity`, code: 'verification', message: `a finding judged ${v.verdict} carries no severity` });
    }
    if (!opts.verified) return;
    const need = typeof f.severity === 'string' ? table[f.severity] : undefined;
    if (typeof need === 'number' && need > 0) {
      if (!ok) { problems.push({ at, code: 'unverified', message: `a ${f.severity} finding needs ${need} verifier(s) from the refuter ledger, and has none` }); return; }
      if (v.verifiers.length < need) problems.push({ at: `${at}.verification.verifiers`, code: 'unverified', message: `a ${f.severity} finding needs ${need} verifier(s), has ${v.verifiers.length}` });
    }
    if (!ok) return;
    if (ledger === null) ledger = readLedger(opts.ledger || path.join(project.root, LEDGER));
    if (ledger.error) { problems.push({ at: `${at}.verification`, code: 'ledger', message: ledger.error }); return; }
    v.verifiers.forEach((x, k) => {
      const hit = ledger.rows.some((r) => r.agent === x.agent && r.finding === f.id && r.lens === x.lens && r.verdict === x.verdict);
      if (!hit) problems.push({ at: `${at}.verification.verifiers[${k}]`, code: 'ledger', message: `no ledger line says agent ${show(x.agent)} judged ${show(f.id)} on ${show(x.lens)} as ${show(x.verdict)}` });
    });
  });
}

// The document with the cited lines' sha256 written onto every entry that verifies. An entry that does not
// verify is never given a hash: stamping would turn an unchecked claim into one that looks checked.
// `redact` then drops "text" from those entries, for lines that should not be quoted (a secret, personal data).
export function stamp(doc, root = '.', { redact = false, ...opts } = {}) {
  const r = validate(doc, root, opts);
  const project = openProject(root);
  for (const ev of r.held) {
    ev.sha256 = rangeOf(project, ev).sha256;
    if (redact) delete ev.text;
  }
  return r;
}

// The bytes a document is stored as: findings in id order, two-space indent, LF, one trailing newline. Members
// keep the order the producer gave them; a producer that wants a byte-stable file emits them in a fixed order.
export function serialize(doc) {
  const out = { ...doc };
  if (Array.isArray(out.findings)) out.findings = [...out.findings].sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  return JSON.stringify(out, null, 2) + '\n';
}

// Validate, then write <root>/.crewforth/<name>.json. An unverified document is never written. Returns the
// validation report with `file` (relative to the root) when it was.
export function write(doc, root, name, opts = {}) {
  if (!OUT_NAME.test(name)) throw new Error(`the name must match ${OUT_NAME}, is ${show(name)}`);
  const r = validate(doc, root, opts);
  if (!r.ok) return r;
  const real = fs.realpathSync(root);
  const dir = path.join(real, OUT_DIR);
  fs.mkdirSync(dir, { recursive: true });
  if (!fs.lstatSync(dir).isDirectory()) throw new Error(`${OUT_DIR} is not a directory of this project`);
  const tmp = path.join(dir, `.${name}.${process.pid}.tmp`);
  fs.writeFileSync(tmp, serialize(doc));
  fs.renameSync(tmp, path.join(dir, `${name}.json`));
  return { ...r, file: `${OUT_DIR}/${name}.json` };
}

// ---- command line -----------------------------------------------------------------------------------------
function usage(msg) {
  if (msg) console.error(`findings: ${msg}`);
  console.error('usage: findings.mjs validate [--root DIR] [--verified] [--json] FILE|-\n'
    + '       findings.mjs stamp    [--root DIR] [--verified] [--redact] FILE|-\n'
    + '       findings.mjs write    [--root DIR] [--verified] NAME FILE|-\n'
    + '       findings.mjs schema');
  return 2;
}

function summary(r, log) {
  for (const p of r.problems) log(`  FAIL ${p.at || '(document)'}: ${p.code} — ${p.message}`);
  log(`findings: ${r.counts.findings} finding(s) · ${r.counts.evidence} evidence entr${r.counts.evidence === 1 ? 'y' : 'ies'} checked · ${r.counts.verified} verified · ${r.problems.length} problem(s)`);
}

export function main(argv) {
  const [op, ...rest] = argv;
  if (op === 'schema' && rest.length === 0) { process.stdout.write(JSON.stringify(loadSchema(), null, 2) + '\n'); return 0; }
  if (!['validate', 'stamp', 'write'].includes(op)) return usage(op ? `no such operation: ${op}` : '');
  let root = '.'; let json = false; let redact = false; let verified = false; const pos = [];
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i];
    if (a === '--root') { root = rest[++i]; if (root === undefined) return usage('--root needs a directory'); }
    else if (a === '--json' && op === 'validate') json = true;
    else if (a === '--redact' && op === 'stamp') redact = true;
    else if (a === '--verified') verified = true;
    else if (a !== '-' && a.startsWith('-')) return usage(`${op} has no option ${a}`);
    else pos.push(a);
  }
  if (pos.length !== (op === 'write' ? 2 : 1)) return usage(`${op} takes ${op === 'write' ? 'a name and a document' : 'one document'}`);
  const src = pos[pos.length - 1];
  let doc;
  try {
    if (!fs.statSync(root).isDirectory()) throw new Error('not a directory');
  } catch (e) { console.error(`findings: --root ${root}: ${e.message}`); return 2; }
  try { doc = JSON.parse(fs.readFileSync(src === '-' ? 0 : src, 'utf8')); }
  catch (e) { console.error(`findings: ${src === '-' ? 'stdin' : src} could not be read as JSON: ${e.message}`); return 2; }

  if (op === 'validate') {
    const r = validate(doc, root, { verified });
    if (json) { const { held, ...pub } = r; process.stdout.write(JSON.stringify(pub, null, 2) + '\n'); }
    else summary(r, (l) => console.log(l));
    return r.ok ? 0 : 1;
  }
  if (op === 'stamp') {
    const r = stamp(doc, root, { redact, verified });
    summary(r, (l) => console.error(l));
    if (!r.ok) return 1;
    process.stdout.write(serialize(doc));
    return 0;
  }
  let r;
  try { r = write(doc, root, pos[0], { verified }); } catch (e) { return usage(e.message); }
  summary(r, (l) => console.error(l));
  if (!r.ok) { console.error('findings: nothing was written'); return 1; }
  console.log(r.file);
  return 0;
}

let direct = false;
try { direct = !!process.argv[1] && fs.realpathSync(process.argv[1]) === fs.realpathSync(SELF); } catch { /* imported */ }
if (direct) process.exitCode = main(process.argv.slice(2));
