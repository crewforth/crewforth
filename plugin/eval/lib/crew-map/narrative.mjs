// narrative.mjs — what the model may add to a crew map, and the rule it is held to. One definition, read by the
// scanner (--write keeps it, --check ignores it, --validate judges it) and by its tests.
//
// The scanner writes every node with `narrative: null` and the document with `overview: null`. /crew-map lets the
// model fill them, and nothing else:
//   node.narrative  { text, cites }  what the module is for, in at most two sentences; `cites` are "file:line"
//                   strings, each one a line the scanner itself cited for THAT node (its evidence)
//   doc.overview    { text, cites }  a short orientation for someone new to the project; its cites may be any
//                   node's evidence
// A narrative with no citation, or one citing a line the scan did not read, is refused: the model may describe
// what the scan found, not add to it. A scanner field changed by hand is refused too (validate).

const MAX_NODE = 400;
const MAX_OVERVIEW = 2000;

/** The "file:line" a node's evidence lets a narrative cite. */
export function citesOf(node) {
  const out = new Set();
  for (const e of Array.isArray(node?.evidence) ? node.evidence : []) {
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
export function problemOf(n, allowed, { max = MAX_NODE, twoSentences = true } = {}) {
  if (n === null || n === undefined) return null;
  if (typeof n !== 'object' || Array.isArray(n)) return 'is not { text, cites }';
  const keys = Object.keys(n).sort().join();
  if (keys !== 'cites,text') return `has fields other than text and cites (${keys})`;
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
  return { ...doc, nodes: (doc.nodes ?? []).map((n) => ({ ...n, narrative: null })), overview: null };
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
    if (problemOf(nar, citesOf(n)) === null) { kept += 1; return { ...n, narrative: nar }; }
    dropped += 1; return n;
  });
  const doc = { ...fresh, nodes };
  if (old?.overview != null) {
    if (problemOf(old.overview, allCites(doc), { max: MAX_OVERVIEW, twoSentences: false }) === null) { doc.overview = old.overview; kept += 1; }
    else dropped += 1;
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
    const p = problemOf(n.narrative, citesOf(byId.get(n.id) ?? n));
    if (p) out.push({ at: n.id, message: `the narrative ${p}` });
  }
  const p = problemOf(file.overview, allCites(fresh), { max: MAX_OVERVIEW, twoSentences: false });
  if (p) out.push({ at: 'overview', message: `the overview ${p}` });
  return out;
}
