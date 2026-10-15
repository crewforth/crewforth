#!/usr/bin/env node
// scan.mjs — Crew Map's scanner: reads a project and writes .crewforth/crew-map.json, a map of its modules, the
// external resources it touches, the endpoints it provides and calls, and the gaps between them.
//
//   node scan.mjs [--root DIR]            scan, verify, write DIR/.crewforth/crew-map.json, print its path
//   node scan.mjs [--root DIR] --stdout   scan and verify; print the document, write nothing
//   node scan.mjs [--root DIR] --check    rc 0 when the file on disk is what a scan writes now, 1 when it is not
//       rc 1 = the scan produced a document that does not verify (nothing is written) · rc 2 = usage
//
// What it guarantees, each one a gate in packaging/crew-map-test:
//   evidence      every node, edge, endpoint and finding cites file:line, and the document goes through the
//                 findings core (kit/eval/lib/findings) before it is written: one that does not verify is not
//   deterministic no timestamp, every list in a fixed order: the same tree gives the same bytes, wherever it sits
//   no secrets    a configuration value is read only to name its kind; only a host is kept, credentials cut off
//                 and masked by Crewforth's own secret patterns. A line that carries values is cited by its key and
//                 never hashed (a hash of `DB_PASSWORD=hunter2` is an oracle for the password)
//   no machine    paths are relative to the project root; the findings core refuses a document that carries the
//                 machine's own directories
//   honest        what it cannot read goes to notMeasured with the reason, never read partly
//   cheap         two child processes per scan (git ls-files, git rev-parse), none per file
//
// Host-independent like the findings core: plain JSON out, Node's standard library only, no hook payload read.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { openProject, loadSecretPatterns, makeHostFilter, sortEv, bearsValues, risky, spawned, isTestPath } from './project.mjs';
import { scanStacks } from './stacks.mjs';
import { externals, configuration, codeUrls, endpoints, containers } from './surface.mjs';
import { detect } from './detect.mjs';
import { stamp, write, serialize, validate, OUT_DIR } from '../findings/findings.mjs';
import { carry, strip, validate as validateNarrative } from './narrative.mjs';

// Languages with source the scanner has no reader for, by extension.
const UNREAD = { dart: 'Dart', swift: 'Swift', rb: 'Ruby', php: 'PHP', rs: 'Rust', scala: 'Scala', ex: 'Elixir', exs: 'Elixir',
  c: 'C', cc: 'C++', cpp: 'C++', m: 'Objective-C', mm: 'Objective-C', lua: 'Lua', clj: 'Clojure', hs: 'Haskell', erl: 'Erlang' };

const SELF = fileURLToPath(import.meta.url);
const HERE = path.dirname(SELF);
export const SCHEMA = 'crewforth.crew-map/1';
export const NAME = 'crew-map';
const MAX_EV = 5;
const load = (f) => JSON.parse(fs.readFileSync(path.join(HERE, 'rules', f), 'utf8'));
const cmp = (a, b) => (a < b ? -1 : a > b ? 1 : 0);

// opts.hostFilter replaces the masking: ONLY the gate's must-fail twin uses it. No command-line flag reaches it.
export function scan(root = '.', opts = {}) {
  const pj = openProject(root);
  const patterns = loadSecretPatterns(HERE);
  const hostOf = opts.hostFilter || makeHostFilter(patterns);
  const rules = load('packages.json'); const names = load('names.json');
  const stdlib = new Set(load('python-stdlib.json').modules);
  const st = scanStacks(pj);
  const out = { edges: [], notMeasured: st.notMeasured, configUrls: [], codeHosts: new Set(), patterns };
  const ex = externals(pj, st, rules, hostOf, out);
  const cfg = configuration(pj, st, rules, hostOf, ex, out);
  codeUrls(pj, st, hostOf, ex, out);
  const eps = endpoints(pj, st, out);
  const services = containers(pj, st, rules, hostOf, ex, cfg, out);
  const findings = detect({ st, cfg, eps, names, stdlib, notMeasured: out.notMeasured, configUrls: out.configUrls, codeHosts: out.codeHosts });

  const ids = new Set([...st.modules.map((m) => m.id), ...services.map((s) => s.id), ...ex.ext.keys()]);
  for (const m of st.modules) {
    for (const r of m.refs) {
      if (ids.has(r.to)) { if (r.to !== m.id) out.edges.push({ from: m.id, to: r.to, kind: 'references', confidence: r.confidence, via: 'code', evidence: [r.ev] }); }
      else out.notMeasured.push({ what: `${r.ev.file}:${r.ev.line}`, reason: `names ${r.to.replace(/^missing:/, '')}, which is not in this repository` });
    }
  }
  for (const f of pj.tooBig) out.notMeasured.push({ what: f, reason: 'over 2 MiB, not read' });
  // Source in a language no reader here knows: say so, or its modules are absent from the map without a word.
  const unread = new Map();
  for (const f of pj.files) {
    const lang = UNREAD[/\.([a-z]+)$/i.exec(f)?.[1]?.toLowerCase()];
    if (lang && !isTestPath(f)) unread.set(lang, (unread.get(lang) ?? 0) + 1);
  }
  for (const [lang, n] of unread) out.notMeasured.push({ what: `${lang} source (${n} file${n === 1 ? '' : 's'})`, reason: 'no reader for this language: its modules, dependencies and endpoints are not on the map' });

  // ---- one edge per (from, to, kind, confidence), its evidence merged ----
  const em = new Map();
  for (const e of out.edges) {
    if (!ids.has(e.to)) { out.notMeasured.push({ what: `${e.evidence[0].file}:${e.evidence[0].line}`, reason: `names ${e.to}, which is not in this repository` }); continue; }
    const k = [e.from, e.to, e.kind, e.confidence].join('\u0000');
    if (!em.has(k)) em.set(k, { from: e.from, to: e.to, kind: e.kind, confidence: e.confidence, source: 'scanner', vias: new Set(), evidence: [] });
    const x = em.get(k); x.vias.add(e.via); x.evidence.push(...e.evidence);
  }
  const capped = (list) => { const all = sortEv(list); return all.length > MAX_EV ? { evidence: all.slice(0, MAX_EV), evidenceTotal: all.length } : { evidence: all }; };
  const edges = [...em.values()].map((x) => ({ from: x.from, to: x.to, kind: x.kind, confidence: x.confidence, source: x.source,
    via: [...x.vias].sort(), ...capped(x.evidence) })).sort((a, b) => cmp([a.from, a.to, a.kind, a.confidence].join('\u0000'), [b.from, b.to, b.kind, b.confidence].join('\u0000')));

  const nodes = [
    ...st.modules.map((m) => ({ id: m.id, kind: 'module', name: m.name, stack: m.stack, path: m.dir, manifest: m.manifest,
      tech: [...m.tech].sort(), entry: m.entry,
      // Named `evidence` so the findings core verifies it like every other citation. An empty __main__.py has no
      // line to cite: the entry is then the file, and it says so.
      ...(m.entry ? { entryPoint: m.entryEv ? { evidence: [m.entryEv] } : { file: m.entryFile, evidence: [] } } : {}),
      dependencies: m.deps.length,
      ...capped(m.evidence), narrative: null })),
    ...services.map((s) => ({ id: s.id, kind: 'service', name: s.name, ...(s.image ? { image: s.image } : {}), ...capped(s.evidence), narrative: null })),
    ...[...ex.ext.values()].map((n) => ({ id: n.id, kind: 'external', resource: n.resource, label: n.label, hosts: [...n.hosts].sort(), ...capped(n.evidence), narrative: null })),
  ].sort((a, b) => cmp(a.id, b.id));

  const epSort = (list) => {
    const seen = new Set(); const res = [];
    for (const e of list) { const k = [e.module, e.method, e.path, e.evidence[0].file, e.evidence[0].line].join('\u0000'); if (!seen.has(k)) { seen.add(k); res.push(e); } }
    return res.sort((a, b) => cmp([a.module, a.path, a.method, a.evidence[0].file, String(a.evidence[0].line).padStart(9, '0')].join('\u0000'),
      [b.module, b.path, b.method, b.evidence[0].file, String(b.evidence[0].line).padStart(9, '0')].join('\u0000')));
  };
  const nm = new Map();
  for (const x of out.notMeasured) nm.set(`${x.what}\u0000${x.reason}`, x);

  const stacks = [...new Set([...st.modules.map((m) => m.stack), ...(services.length ? ['container'] : [])])].sort();
  const doc = {
    schema: SCHEMA,
    producer: { name: NAME, version: '1' },
    ...(pj.commit ? { source: { commit: pj.commit } } : {}),
    stacks,
    coverage: { files: pj.files.length, modules: st.modules.length, listing: pj.git ? 'git' : 'walk' },
    nodes,
    edges,
    provides: { endpoints: epSort(eps.provides) },
    consumes: { endpoints: epSort(eps.consumes) },
    findings,
    notMeasured: [...nm.values()].sort((a, b) => cmp(`${a.what}\u0000${a.reason}`, `${b.what}\u0000${b.reason}`)),
    overview: null,
  };
  // The last net, whatever cited it: a quote is cut before anything that looks like a credential, and a line that
  // carries values (by its file, or by what is on it) is never hashed.
  const lineAt = (c) => { const r = pj.read(c.file); return r && r.lines[c.line - 1] !== undefined ? r.lines[c.line - 1] : ''; };
  const cites = [];
  const collect = (v) => {
    if (Array.isArray(v)) v.forEach(collect);
    else if (v && typeof v === 'object') {
      if (typeof v.file === 'string' && typeof v.line === 'number' && typeof v.text === 'string') cites.push(v);
      Object.values(v).forEach(collect);
    }
  };
  collect(doc);
  for (const c of cites) {
    const at = risky(c.text, patterns);
    if (at === 0) c.text = c.text[0]; else if (at > 0) c.text = c.text.slice(0, at);
  }
  const report = stamp(doc, pj.root);
  for (const c of cites) if (c.sha256 && (bearsValues(c.file) || risky(lineAt(c), patterns) >= 0)) delete c.sha256;
  return { doc, report, spawned: spawned.count };
}

function usage(msg) {
  if (msg) console.error(`crew-map: ${msg}`);
  console.error('usage: scan.mjs [--root DIR] [--stdout | --check | --validate]');
  return 2;
}

function summary(doc) {
  const hidden = doc.findings.filter((f) => f.data && f.data.defaultHidden).length;
  const mods = doc.nodes.filter((n) => n.kind === 'module').length;
  const ext = doc.nodes.filter((n) => n.kind === 'external').length;
  return `crew-map: ${mods} module(s) · ${ext} external resource(s) · ${doc.edges.length} edge(s) · `
    + `${doc.provides.endpoints.length} endpoint(s) provided · ${doc.consumes.endpoints.length} called · `
    + `${doc.findings.length} finding(s) (${hidden} hidden by default) · ${doc.notMeasured.length} not measured`;
}

export function main(argv) {
  let root = '.'; let mode = 'write';
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--root') { root = argv[++i]; if (root === undefined) return usage('--root needs a directory'); }
    else if (a === '--stdout' || a === '--check' || a === '--validate') { if (mode !== 'write') return usage('--stdout, --check and --validate do not go together'); mode = a.slice(2); }
    else return usage(`no such option: ${a}`);
  }
  try { if (!fs.statSync(root).isDirectory()) throw new Error('not a directory'); }
  catch (e) { console.error(`crew-map: --root ${root}: ${e.message}`); return 2; }
  const { doc, report } = scan(root);
  if (!report.ok) {
    for (const p of report.problems) console.error(`  FAIL ${p.at}: ${p.code} — ${p.message}`);
    console.error('crew-map: the scan produced citations that do not verify, so nothing was written (a scanner defect)');
    return 1;
  }
  if (mode === 'stdout') { process.stdout.write(serialize(doc)); console.error(summary(doc)); return 0; }
  const file = path.join(root, OUT_DIR, `${NAME}.json`);
  let old = null; try { old = fs.readFileSync(file, 'utf8'); } catch { /* absent */ }
  let was = null; try { was = old === null ? null : JSON.parse(old); } catch { /* unreadable: different */ }
  if (mode === 'validate') {
    if (!was) { console.log(`crew-map: ${OUT_DIR}/${NAME}.json ${old === null ? 'does not exist' : 'is not JSON'}`); return 1; }
    const problems = validateNarrative(was, doc, serialize);
    const written = (was.nodes ?? []).filter((n) => n.narrative != null).length + (was.overview != null ? 1 : 0);
    if (!problems.length) { console.log(`crew-map: ${OUT_DIR}/${NAME}.json holds: ${written} description(s), each citing lines the scan read; the scanner's fields untouched`); return 0; }
    for (const p of problems) console.log(`  FAIL ${p.at}: ${p.message}`);
    console.log(`crew-map: ${problems.length} problem(s); fix the descriptions, never the scanner's fields`);
    return 1;
  }
  if (mode === 'check') {
    if (old === null) { console.log(`crew-map: ${OUT_DIR}/${NAME}.json does not exist`); return 1; }
    // The content is compared, not the commit it was written at: a map committed to the repository is always
    // one commit behind the commit that carries it, and that alone does not make it stale. What the model wrote
    // (narrative, overview) is not the scan's, so it is left out of the comparison.
    const bare = (d) => { const { source, ...rest } = strip(d); return serialize(rest); };
    const then = was && was.source && was.source.commit; const now = doc.source && doc.source.commit;
    const at = then && now && then !== now ? ` (written at ${then.slice(0, 12)}, HEAD is ${now.slice(0, 12)})` : '';
    if (was && bare(was) === bare(doc)) { console.log(`crew-map: ${OUT_DIR}/${NAME}.json is up to date${at}`); return 0; }
    console.log(`crew-map: ${OUT_DIR}/${NAME}.json differs from a scan of this tree${at}`);
    return 1;
  }
  // The descriptions /crew-map wrote are kept where they still cite only lines this scan cites; the rest are dropped.
  const carried = was ? carry(was, doc) : { doc, kept: 0, dropped: 0 };
  const r = write(carried.doc, root, NAME);
  if (!r.ok) { for (const p of r.problems) console.error(`  FAIL ${p.at}: ${p.code} — ${p.message}`); return 1; }
  console.error(summary(doc) + (carried.kept || carried.dropped ? ` · ${carried.kept} description(s) kept, ${carried.dropped} dropped (they cited lines this scan no longer reads)` : ''));
  console.log(r.file);
  return 0;
}

let direct = false;
try { direct = !!process.argv[1] && fs.realpathSync(process.argv[1]) === fs.realpathSync(SELF); } catch { /* imported */ }
if (direct) process.exitCode = main(process.argv.slice(2));
