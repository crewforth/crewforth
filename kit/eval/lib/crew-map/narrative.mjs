// narrative.mjs — what the model may add to a crew map, and the rule it is held to. One definition, read by the
// scanner (--write keeps it, --check ignores it, --validate judges it) and by its tests.
//
// The scanner writes every node with `narrative: null` and the document with `overview: null`. /crew-map lets the
// model fill them, and nothing else:
//   node.narrative  { text, cites }  what the module is for, in at most two sentences; `cites` are "file:line"
//                   strings, each one a line the scanner itself cited for THAT node (its evidence)
//                   and, optionally, `layer` (one of LAYERS: where the module sits) and `domain` (what part of the
//                   business it serves, a short phrase), both resting on the same cites
//   doc.overview    { text, cites }  a short orientation for someone new to the project; its cites may be any
//                   node's evidence
//   doc.tour        [{ node, text, cites }]  one to eight stops a newcomer reads in order: each names a node of the
//                   map, says in at most two sentences why to look there, and cites that node's own lines
// A narrative with no citation, or one citing a line the scan did not read, is refused: the model may describe
// what the scan found, not add to it. A scanner field changed by hand is refused too (validate).

const MAX_NODE = 400;
const MAX_OVERVIEW = 2000;
const MAX_STOP = 300;
const MAX_STOPS = 8;
const MAX_DOMAIN = 60;
export const LAYERS = ['ui', 'api', 'service', 'data', 'infra', 'tool', 'library'];

/** The "file:line" a narrative of this node may cite. */
export function citesOf(node) {
  const out = new Set();
  // Its evidence, its entry point and what its README says about it: every line the scan read for this node.
  for (const e of [node?.evidence, node?.entryPoint?.evidence, node?.about?.evidence].flatMap((x) => (Array.isArray(x) ? x : []))) {
    if (e && typeof e.file === 'string' && Number.isInteger(e.line)) out.add(`${e.file}:${e.line}`);
  }
  return out;
}

/** Every line any node of the document cites: what an overview may point at. */
export function allCites(doc) {
  const out = new Set();
  for (const n of doc?.nodes ?? []) for (const c of citesOf(n)) out.add(c);
  return out;
}

const sentences = (t) => (String(t).trim().match(/[.!?](\s|$)/g) ?? []).length;

/**
 * Why a narrative is not acceptable, or null when it is (null itself is: not written yet).
 * @param allowed  the set of "file:line" it may cite
 */
export function problemOf(n, allowed, { max = MAX_NODE, twoSentences = true, module = false } = {}) {
  if (n === null || n === undefined) return null;
  if (typeof n !== 'object' || Array.isArray(n)) return 'is not { text, cites }';
  const may = module ? ['cites', 'domain', 'layer', 'text'] : ['cites', 'text'];
  const odd = Object.keys(n).filter((k) => !may.includes(k));
  if (odd.length || !('text' in n) || !('cites' in n)) return `has fields other than ${may.join(', ')} (${Object.keys(n).sort().join()})`;
  if ('layer' in n && !LAYERS.includes(n.layer)) return `names the layer ${JSON.stringify(n.layer)}, not one of ${LAYERS.join(', ')}`;
  if ('domain' in n && (typeof n.domain !== 'string' || !n.domain.trim() || n.domain.length > MAX_DOMAIN || /[.!?]/.test(n.domain))) return `has a domain that is not a short phrase (at most ${MAX_DOMAIN} characters, no sentence)`;
  if (typeof n.text !== 'string' || !n.text.trim()) return 'has no text';
  if (n.text.length > max) return `is ${n.text.length} characters, more than ${max}`;
  if (twoSentences && sentences(n.text) > 2) return 'is more than two sentences';
  if (!Array.isArray(n.cites) || !n.cites.length) return 'cites nothing: a description must point at a line the scan read';
  const bad = n.cites.filter((c) => typeof c !== 'string' || !allowed.has(c));
  if (bad.length) return `cites ${bad.slice(0, 3).map(String).join(', ')}, which the scan did not cite here`;
  return null;
}

/** The document without what the model may add: the scanner's fields alone. */
export function strip(doc) {
  if (!doc || typeof doc !== 'object') return doc;
  return { ...doc, nodes: (doc.nodes ?? []).map((n) => ({ ...n, narrative: null })), overview: null, tour: null };
}

/** Why a tour is not acceptable, or null when it is (null itself is: not written yet). */
export function tourProblem(tour, doc) {
  if (tour === null || tour === undefined) return null;
  if (!Array.isArray(tour) || !tour.length || tour.length > MAX_STOPS) return `is not a list of 1 to ${MAX_STOPS} stops`;
  const byId = new Map((doc?.nodes ?? []).map((n) => [n.id, n]));
  const seen = new Set();
  for (const [i, s] of tour.entries()) {
    if (!s || typeof s !== 'object' || Array.isArray(s) || Object.keys(s).sort().join() !== 'cites,node,text') return `stop ${i + 1} is not { node, text, cites }`;
    if (!byId.has(s.node)) return `stop ${i + 1} names ${JSON.stringify(s.node)}, which is not a node of this map`;
    if (seen.has(s.node)) return `stop ${i + 1} names ${s.node} again: a tour stops at a node once`;
    seen.add(s.node);
    const p = problemOf({ text: s.text, cites: s.cites }, citesOf(byId.get(s.node)), { max: MAX_STOP });
    if (p) return `stop ${i + 1} (${s.node}) ${p}`;
  }
  return null;
}

/**
 * A new scan with the narratives of the old map carried over, where they still hold: a node with the same id
 * whose narrative still cites only lines this scan cites for it. One that no longer holds is dropped, and counted.
 */
export function carry(old, fresh) {
  const was = new Map((old?.nodes ?? []).map((n) => [n.id, n.narrative]));
  let kept = 0; let dropped = 0;
  const nodes = fresh.nodes.map((n) => {
    const nar = was.get(n.id);
    if (nar === null || nar === undefined) return n;
    if (problemOf(nar, citesOf(n), { module: n.kind === 'module' }) === null) { kept += 1; return { ...n, narrative: nar }; }
    dropped += 1; return n;
  });
  const doc = { ...fresh, nodes };
  if (old?.overview != null) {
    if (problemOf(old.overview, allCites(doc), { max: MAX_OVERVIEW, twoSentences: false }) === null) { doc.overview = old.overview; kept += 1; }
    else dropped += 1;
  }
  if (old?.tour != null) {
    if (tourProblem(old.tour, doc) === null) { doc.tour = old.tour; kept += 1; } else dropped += 1;
  }
  return { doc, kept, dropped };
}

/**
 * Hold a map the model wrote to the rules: its scanner fields are what a scan of the tree writes now, and every
 * narrative and the overview pass `problemOf`. Returns a list of { at, message }; empty means it holds.
 * @param serialize  how the scanner writes a document (so the comparison is of its own bytes)
 */
export function validate(file, fresh, serialize) {
  const out = [];
  const bare = (d) => { const { source, ...rest } = strip(d); return serialize(rest); };
  if (bare(file) !== bare(fresh)) {
    out.push({ at: 'scan', message: 'the map\'s scanner fields differ from a scan of this tree: a field was changed by hand, or the tree changed since (scan again first)' });
  }
  const byId = new Map((fresh.nodes ?? []).map((n) => [n.id, n]));
  for (const n of file.nodes ?? []) {
    const p = problemOf(n.narrative, citesOf(byId.get(n.id) ?? n), { module: (byId.get(n.id) ?? n).kind === 'module' });
    if (p) out.push({ at: n.id, message: `the narrative ${p}` });
  }
  const p = problemOf(file.overview, allCites(fresh), { max: MAX_OVERVIEW, twoSentences: false });
  if (p) out.push({ at: 'overview', message: `the overview ${p}` });
  const t = tourProblem(file.tour, fresh);
  if (t) out.push({ at: 'tour', message: `the tour ${t}` });
  return out;
}
