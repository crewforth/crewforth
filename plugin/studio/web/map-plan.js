// What the Map view draws, worked out from a crew map. No page in it.
//
// The map is Crewforth's (server/lib/crew-map.js reads it). This file puts each node in a band, says which lines
// a selection lights, orders the findings and words them. It invents no layer: a module's layer is the one /crew-map
// wrote for it (citing the lines it rests on); without one, its band is what the scan shows of it, and a module whose
// place the scan does not show goes to "Unplaced". A finding the scanner hides by default stays hidden until asked.

// The layers /crew-map may write (eval/lib/crew-map/narrative.mjs LAYERS), set between the bands the scan alone
// gives, so a map with no layer is drawn in the same order as before.
import { t } from './i18n.js';

export const LAYER_KEYS = ['ui', 'api', 'service', 'data', 'infra', 'tool', 'library'];
export const BANDS = [
  ['ui', t('UI')],
  ['clients', t('Clients')],
  ['api', t('API')],
  ['entry', t('Entry points')],
  ['service', t('Service')],
  ['core', t('Core')],
  ['data', t('Data')],
  ['infra', t('Infrastructure')],
  ['library', t('Library')],
  ['tool', t('Tools')],
  ['external', t('External')],
  ['unplaced', t('Unplaced')],
];

const RESOURCE = { db: 'db', cache: 'cache', queue: 'queue', auth: 'auth', 'http-api': 'api' };
export const resourceWord = (r) => RESOURCE[r] ?? String(r ?? 'external');

/** The modules a finding is about: named in its data, or the module whose folder holds its first cited file. */
export function findingModules(f, modules) {
  const named = [f?.data?.module, ...(Array.isArray(f?.data?.modules) ? f.data.modules : [])].filter((x) => typeof x === 'string');
  if (named.length) return [...new Set(named)];
  const file = f?.evidence?.[0]?.file;
  if (typeof file !== 'string') return [];
  let best = null;
  for (const m of modules) {
    const dir = m.path === '.' || m.path === '' ? '' : `${m.path}/`;
    if ((dir === '' || file.startsWith(dir)) && (!best || dir.length > best.dir.length)) best = { id: m.id, dir };
  }
  return best ? [best.id] : [];
}

/**
 * Each node's band, from what the map shows of it:
 *   external resource → External · container service → Infrastructure · a module of a compared project → Clients
 *   a module that provides an endpoint, or that a container service builds → Entry points
 *   one that only calls endpoints → Clients
 *   one another module of this project references → Core · one with an entry point and nothing above → Entry points
 *   anything else → Unplaced, so a guess is never drawn as a fact.
 * A module /crew-map gave a layer goes to that layer's band first.
 */
export function bandOf(node, doc) {
  if (node.kind === 'module' && LAYER_KEYS.includes(node.narrative?.layer)) return node.narrative.layer;
  if (node.kind === 'external') return 'external';
  if (node.kind === 'service') return 'infra';
  if (node.kind === 'client') return 'clients';
  if ((doc.provides?.endpoints ?? []).some((e) => e.module === node.id)) return 'entry';
  if ((doc.edges ?? []).some((e) => e.to === node.id && e.kind === 'builds')) return 'entry';
  if ((doc.consumes?.endpoints ?? []).some((e) => e.module === node.id)) return 'clients';
  if ((doc.edges ?? []).some((e) => e.to === node.id && e.from !== node.id && e.from.startsWith('mod:'))) return 'core';
  if (node.entry) return 'entry';
  return 'unplaced';
}

/**
 * The nodes the view draws, each with its band, and the clients of a compared project as nodes of their own.
 * @param compare  the server's `compare` ({ label, clients }) or null
 */
export function nodesOf(doc, compare = null) {
  const own = (doc.nodes ?? []).map((n) => ({ ...n, band: bandOf(n, doc) }));
  const clients = (compare?.clients ?? []).map((c) => ({
    id: `cmp:${c.id}`, kind: 'client', name: c.name, tech: c.tech ?? [], from: compare.label, calls: c.calls, missing: c.missing, band: 'clients',
  }));
  return [...clients, ...own];
}

/** The edges between drawn nodes; a compared client gets one edge to each module of this project it calls. */
export function edgesOf(doc, compare = null) {
  const own = (doc.edges ?? []).map((e) => ({ ...e, solid: e.confidence !== 'inferred', line: lineOf(e) }));
  const extra = [];
  for (const c of compare?.clients ?? []) {
    // The module each call lands on is the server's match (`to`), never a guess made here.
    const to = new Map();
    for (const call of c.calls) if (call.to) to.set(call.to, (to.get(call.to) ?? 0) + 1);
    for (const [m, n] of to) extra.push({ from: `cmp:${c.id}`, to: m, kind: 'calls', confidence: 'evidence', solid: true, line: 'evidence', calls: n, missing: c.missing.length });
  }
  return [...extra, ...own];
}

export const edgeKey = (e) => `${e.from}>${e.to}>${e.kind}`;

/**
 * How a line is drawn: `evidence` (solid, a file proves it), `inferred` (dotted) or `model` (a line the model
 * proposed: dashed with its own mark, never drawn as if a file showed it).
 */
export function lineOf(e) {
  if (e?.source === 'model') return 'model';
  return e?.confidence === 'inferred' ? 'inferred' : 'evidence';
}

/** An external resource every line of which is inferred is itself only inferred, and its card says so. */
export function inferredOnly(node, edges) {
  if (node.kind !== 'external') return false;
  const into = edges.filter((e) => e.to === node.id || e.from === node.id);
  return into.length > 0 && into.every((e) => lineOf(e) !== 'evidence');
}

/** Which lines a selection lights: the selected node's own, in and out. With nothing selected, none is lit. */
export function litEdges(edges, selected) {
  if (!selected) return new Set();
  return new Set(edges.filter((e) => e.from === selected || e.to === selected).map(edgeKey));
}

/**
 * The findings the list shows, proven first, then by title. Hidden by default: the scanner's own mark
 * (`data.defaultHidden`, for rules too often wrong to show unasked); shown when `showHidden`. A compared client's
 * calls this project does not provide are findings too, marked as coming from the comparison.
 */
export function findingsOf(doc, { showHidden = false, compare = null } = {}) {
  const modules = (doc.nodes ?? []).filter((n) => n.kind === 'module');
  const all = (doc.findings ?? []).map((f) => ({
    id: f.id, rule: f.rule, title: f.title, proven: f.confidence === 'proven', hidden: Boolean(f.data?.defaultHidden),
    hiddenReason: f.data?.hiddenReason ?? null, where: whereOf(f), modules: findingModules(f, modules), evidence: f.evidence ?? [], from: null,
  }));
  for (const c of compare?.clients ?? []) {
    for (const m of c.missing) {
      all.push({
        id: `cmp:${c.id}:${m.method} ${m.path}`, rule: 'compare-missing', title: t('{endpoint} is called by {client} and not provided here', { endpoint: `${m.method} ${m.path}`, client: c.name }),
        proven: true, hidden: false, hiddenReason: null, where: m.evidence?.[0] ? `${m.evidence[0].file}:${m.evidence[0].line}` : '', modules: [`cmp:${c.id}`],
        evidence: m.evidence ?? [], from: compare.label,
      });
    }
  }
  const shown = all.filter((f) => showHidden || !f.hidden);
  shown.sort((a, b) => Number(b.proven) - Number(a.proven) || (a.title < b.title ? -1 : a.title > b.title ? 1 : 0));
  return { shown, hidden: all.filter((f) => f.hidden).length, proven: shown.filter((f) => f.proven).length, total: all.length };
}

function whereOf(f) {
  const e = f.evidence?.[0];
  return e ? `${e.file}:${e.line}` : '';
}

/** How many findings each drawn node carries, of those the list shows. */
export function findingCounts(findings) {
  const out = {};
  for (const f of findings) for (const m of f.modules) out[m] = (out[m] ?? 0) + 1;
  return out;
}

const endpoints = (n) => (n === 1 ? t('1 endpoint') : t('{n} endpoints', { n }));

/** What a card says under its name. */
export function cardSub(node, doc) {
  if (node.kind === 'client') return `${node.from} · ${node.calls.length === 1 ? t('1 call here') : t('{n} calls here', { n: node.calls.length })}`;
  if (node.kind === 'service') return node.image ? `${t('container')} · ${node.image}` : t('container');
  const provided = (doc.provides?.endpoints ?? []).filter((e) => e.module === node.id).length;
  const tech = (node.tech ?? []).slice(0, 2).map((t) => t.replace(/@.*$/, '')).join(' · ');
  return [tech || node.stack, provided ? endpoints(provided) : null].filter(Boolean).join(' · ');
}

/**
 * What a module's card says, as the Map draws it: a kind line (its domain, else its stack, and how many endpoints it
 * provides) and up to three of what it is built with. What it calls outside is a card of its own (outsideOf).
 */
export const CARD_CHIPS = 3;
export function cardOf(node, doc) {
  const provided = (doc.provides?.endpoints ?? []).filter((e) => e.module === node.id).length;
  const kind = [node.narrative?.domain ?? node.stack ?? null, provided ? endpoints(provided) : null].filter(Boolean).join(' · ');
  const tech = (node.tech ?? []).map((t) => t.replace(/@.*$/, ''));
  return { kind, chips: tech.slice(0, CARD_CHIPS), more: Math.max(0, tech.length - CARD_CHIPS) };
}

const extName = (n) => (n.label && n.label !== 'unknown' ? n.label : (n.hosts ?? [])[0] ?? n.id.replace(/^ext:[^:]+:/, ''));

/**
 * The outside services as the Map draws them. A database, cache, queue or sign-in service is a card of its own. Web
 * addresses called by exactly the same modules are one card ("eur-lex.europa.eu +17"), so a module that calls twenty
 * sites draws one line, not twenty; the card's lines are the same lines its addresses had, solid when any was.
 * Nothing is merged that a selection could tell apart.
 * @returns { nodes, edges } with the outside nodes and the lines into them replaced
 */
export function outsideOf(nodes, edges) {
  const isExt = new Set(nodes.filter((n) => n.kind === 'external').map((n) => n.id));
  const callers = new Map();
  for (const e of edges) if (isExt.has(e.to)) (callers.get(e.to) ?? callers.set(e.to, new Set()).get(e.to)).add(e.from);
  const byKey = new Map();
  for (const n of nodes) {
    if (!isExt.has(n.id)) continue;
    const web = n.resource === 'http-api' || n.resource == null;
    const key = web ? `web|${[...(callers.get(n.id) ?? [])].sort().join(',')}` : n.id;
    (byKey.get(key) ?? byKey.set(key, []).get(key)).push(n);
  }
  const into = new Map();
  const cards = new Map();
  for (const members of byKey.values()) {
    if (members.length === 1) continue;
    // Named by its first address, a masked one last: a card called "[masked] +10" says nothing.
    const sortName = (n) => `${extName(n).startsWith('[') ? '~' : ''}${extName(n)}`;
    members.sort((a, b) => (sortName(a) < sortName(b) ? -1 : sortName(a) > sortName(b) ? 1 : 0));
    const id = `extg:${members[0].id}`;
    for (const m of members) into.set(m.id, id);
    cards.set(id, {
      id, kind: 'external', resource: 'http-api', band: 'external', label: extName(members[0]), more: members.length - 1,
      members: members.map((m) => m.id), names: members.map(extName), hosts: members.flatMap((m) => m.hosts ?? []),
      evidence: members.flatMap((m) => m.evidence ?? []),
    });
  }
  if (!into.size) return { nodes, edges };
  const out = [];
  for (const n of nodes) {
    const gid = into.get(n.id);
    if (!gid) out.push(n);
    else if (cards.has(gid)) { out.push(cards.get(gid)); cards.delete(gid); }
  }
  const em = new Map();
  for (const e of edges) {
    const to = into.get(e.to) ?? e.to;
    const k = `${e.from}>${to}>${e.kind}`;
    const was = em.get(k);
    if (!was) em.set(k, to === e.to ? e : { ...e, to });
    else if (lineOf(e) === 'evidence' && was.line !== 'evidence') em.set(k, { ...was, solid: true, line: 'evidence' });
  }
  return { nodes: out, edges: [...em.values()] };
}

/** The tour /crew-map wrote, the stops whose node is on this map, each with the node's name. */
export function tourOf(doc) {
  const byId = new Map((doc.nodes ?? []).map((n) => [n.id, n]));
  return (Array.isArray(doc.tour) ? doc.tour : []).filter((s) => s && byId.has(s.node) && typeof s.text === 'string')
    .map((s) => ({ node: s.node, name: byId.get(s.node).name ?? byId.get(s.node).label ?? s.node, text: s.text, cites: (s.cites ?? []).filter((c) => typeof c === 'string') }));
}

/**
 * The nodes a search names: by name, folder, what they are built with, their domain, the folders inside them and
 * what their README says. Case does not matter; an empty search names none.
 */
export function searchOf(query, nodes) {
  const q = String(query ?? '').trim().toLowerCase();
  if (!q) return new Set();
  const hay = (n) => [n.name, n.label, n.path, n.stack, ...(n.tech ?? []), ...(n.hosts ?? []), n.narrative?.domain, n.narrative?.layer,
    ...(n.structure?.folders ?? []).map((f) => f.folder), ...(n.about?.evidence ?? []).map((e) => e.text)]
    .filter((x) => typeof x === 'string').join('\n').toLowerCase();
  return new Set(nodes.filter((n) => hay(n).includes(q)).map((n) => n.id));
}

/** The summary pills: what the map holds, and how many findings the list shows. */
export function summaryOf(doc, findings) {
  const n = (k) => (doc.nodes ?? []).filter((x) => x.kind === k).length;
  const eps = (doc.provides?.endpoints?.length ?? 0) + (doc.consumes?.endpoints?.length ?? 0);
  return [
    n('module') === 1 ? t('1 module') : t('{n} modules', { n: n('module') }),
    t('{n} external', { n: n('external') }),
    endpoints(eps),
    findings.shown.length === 1 ? t('1 finding') : t('{n} findings', { n: findings.shown.length }),
  ];
}

/** The source strip: the file, the commit it was scanned at, and how far HEAD has moved since. */
export function sourceOf(data) {
  const commit = data.doc?.source?.commit ?? null;
  const behind = data.behind?.count;
  return {
    file: data.file,
    at: commit ? t('scanned at {commit}', { commit: commit.slice(0, 7) }) : t('scanned outside git'),
    behind: typeof behind === 'number' && behind > 0 ? (behind === 1 ? t('1 commit behind') : t('{n} commits behind', { n: behind })) : null,
    behindNote: typeof behind === 'number' ? null : (data.behind?.reason ?? null),
    rule: t('Nothing is run; files are only read.'),
  };
}

/** What the inspector shows for one node. */
export function inspectOf(node, doc, edges, findings) {
  const byId = new Map(nodesOf(doc).map((n) => [n.id, n]));
  const nameOf = (id) => byId.get(id)?.name ?? byId.get(id)?.label ?? id.replace(/^(mod|svc|ext):/, '');
  const line = (e, other) => ({
    kind: e.kind, to: nameOf(other), host: byId.get(other)?.hosts?.[0] ?? null,
    evidence: e.evidence?.[0] ? `${e.evidence[0].file}:${e.evidence[0].line}` : null, solid: e.solid, line: e.line ?? lineOf(e),
  });
  // An outside card that stands for several addresses has their lines.
  const mine = new Set([node.id, ...(node.members ?? [])]);
  const out = edges.filter((e) => mine.has(e.from)).map((e) => line(e, e.to));
  const into = edges.filter((e) => mine.has(e.to)).map((e) => line(e, e.from));
  // Connections, by the kind of line: what the inspector's second tab lists.
  const byKind = {};
  for (const [dir, list] of [['out', out], ['in', into]]) for (const c of list) (byKind[c.kind] ??= { out: [], in: [] })[dir].push(c);
  return {
    title: node.name ?? node.label ?? node.id,
    path: node.path ?? (node.kind === 'external' ? (node.names ?? node.hosts ?? []).join(', ') : null),
    chips: (node.tech ?? []).map((t) => t.replace('@', ' ')),
    // /crew-map's description: { text, cites }, each cite a file:line of this node's evidence (eval/lib/crew-map/narrative.mjs).
    narrative: typeof node.narrative?.text === 'string' ? node.narrative.text : null,
    narrativeCites: Array.isArray(node.narrative?.cites) ? node.narrative.cites.filter((c) => typeof c === 'string') : [],
    narrativeNote: t('Not written yet: this map holds no description of the module, only what its files show.'),
    // /crew-map's layer and domain, when it wrote them; the band is the layer's (bandOf).
    layer: LAYER_KEYS.includes(node.narrative?.layer) ? (BANDS.find(([k]) => k === node.narrative.layer)?.[1] ?? null) : null,
    domain: typeof node.narrative?.domain === 'string' ? node.narrative.domain : null,
    // What is inside it: the entry point the scan found, its folders with how many source files each holds, tests apart.
    inside: node.kind === 'module' ? {
      entry: node.entryPoint?.evidence?.[0] ? `${node.entryPoint.evidence[0].file}:${node.entryPoint.evidence[0].line}` : (node.entryPoint?.file ?? null),
      folders: (node.structure?.folders ?? []).map((f) => ({ folder: f.folder, files: f.files })),
      other: node.structure?.otherFiles ?? 0,
      tests: node.structure?.testFiles ?? 0,
    } : null,
    // Where its tests are (its own test files and a test project named for it), how often it changed in the commits
    // the scan read, and the WHY/HACK/FIXME lines in its code: what someone about to change it asks first.
    testFiles: Array.isArray(node.tests?.files) ? node.tests.files.filter((f) => typeof f === 'string') : [],
    testTotal: Number.isInteger(node.tests?.total) ? node.tests.total : 0,
    changed: Number.isInteger(node.commits) && Number.isInteger(doc?.source?.commitsRead) && doc.source.commitsRead > 0
      ? (doc.source.commitsRead === 1 ? t('Changed in {n} of the last 1 commit', { n: node.commits }) : t('Changed in {n} of the last {of} commits', { n: node.commits, of: doc.source.commitsRead })) : null,
    notes: (node.markers?.evidence ?? []).filter((e) => e && typeof e.file === 'string').map((e) => ({ at: `${e.file}:${e.line}`, text: String(e.text ?? '') })),
    notesTotal: node.markers?.evidenceTotal ?? (node.markers?.evidence ?? []).length,
    connectsTo: out,
    connections: { out, in: into },
    byKind: Object.entries(byKind).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)),
    // Every line the map cites for this node itself, as file:line: what the inspector lets the viewer copy.
    evidence: (node.evidence ?? []).map((e) => `${e.file}:${e.line}`),
    evidenceTotal: node.evidenceTotal ?? (node.evidence ?? []).length,
    findings: findings.filter((f) => f.modules.includes(node.id)),
  };
}

/** A finding as a task to paste into a session: what, where, and that the map is the source. */
export function taskOf(f) {
  return [
    `${f.title}.`,
    f.where ? `Evidence: ${f.where}${f.evidence?.[0]?.text ? ` (${f.evidence[0].text})` : ''}.` : null,
    f.proven ? null : 'The crew map inferred this; check it before acting on it.',
    f.from ? `Found by comparing this project's map with ${f.from}'s.` : `From the crew map (rule ${f.rule}).`,
  ].filter(Boolean).join(' ');
}

/** What the view says when there is no map to draw. */
export function emptyNote(data) {
  if (!data) return t('Reading the map…');
  if (data.measured === false) return data.missing ? t('No map yet — {reason}', { reason: data.reason }) : t('Not read — {reason}', { reason: data.reason });
  return null;
}

// The Map is drawn in columns, left to right in the order things are used: what people use, what serves them, the
// code they share, what they run on, and the outside services. A line points from the module that uses to the one
// used, so most lines run left to right. Tools and modules the map does not place sit in strips under the columns,
// folded to a line of names until opened. Cards do not move by hand: the layout is the map's, the same every time.
export const COLUMNS = [
  ['people', t('What people use'), ['ui', 'clients']],
  ['serve', t('What serves them'), ['api', 'entry', 'service']],
  ['shared', t('Shared code'), ['core', 'data', 'library']],
  ['infra', t('Infrastructure'), ['infra']],
  ['outside', t('Outside services'), ['external']],
];
export const STRIPS = [['tool', t('Tools')], ['unplaced', t('Unplaced')]];
const COLUMN_OF = Object.fromEntries(COLUMNS.flatMap(([k, , bands]) => bands.map((b) => [b, k])));
/** The column a band is drawn in, or the strip it folds into. */
export const placeOf = (band) => COLUMN_OF[band] ?? (STRIPS.some(([k]) => k === band) ? band : 'unplaced');

export const CARD = { module: [240, 76], service: [240, 76], client: [240, 76], external: [200, 48] };
const COL_GAP = 110;   // the room between two columns, where their lines run
const ROW_GAP = 14;
const HEAD = 44;       // a column's title sits in this strip at its top
const STRIP_GAP = 36;
const STRIP_CLOSED = 44;
const CHIP_ROW = 26;   // one row of endpoint chips under a card, when the Endpoints layer is on
export const CHIPS_MAX = 4;

const sizeOf = (n, chips) => {
  const [w, h] = CARD[n.kind] ?? CARD.module;
  return [w, h + Math.ceil(Math.min(chips[n.id] ?? 0, CHIPS_MAX + 1) / 2) * CHIP_ROW];
};
const byName = (a, b) => { const x = String(a.name ?? a.label ?? a.id); const y = String(b.name ?? b.label ?? b.id); return x < y ? -1 : x > y ? 1 : 0; };

/**
 * Where everything sits. Empty columns are not drawn. In a column, a card sits as near as it can to the cards it is
 * joined to in the columns before it (the mean of their middles, one pass, left to right), so lines cross less; a
 * card joined to none comes after, by name. A strip is one line of names while folded (`open` lacks it) and a row of
 * cards, wrapping at the columns' width, while open; a folded strip's cards have no place, so their lines are not drawn.
 * @returns { columns: [{ key, label, x, w }], strips: [{ key, label, y, h, open, ids }], pos: { id: { x, y, w, h, strip? } }, width, height }
 */
export function layoutOf(nodes, edges = [], { chips = {}, open = new Set() } = {}) {
  const pos = {};
  const columns = [];
  const near = new Map();
  for (const e of edges) {
    (near.get(e.from) ?? near.set(e.from, []).get(e.from)).push(e.to);
    (near.get(e.to) ?? near.set(e.to, []).get(e.to)).push(e.from);
  }
  let x = 0; let bottom = HEAD;
  for (const [key, label] of COLUMNS) {
    const members = nodes.filter((n) => placeOf(n.band) === key);
    if (!members.length) continue;
    const at = (n) => {
      const ys = (near.get(n.id) ?? []).map((id) => pos[id]).filter((p) => p && !p.strip).map((p) => p.y + p.h / 2);
      return ys.length ? ys.reduce((s, v) => s + v, 0) / ys.length : Infinity;
    };
    const order = members.map((n) => ({ n, at: at(n) })).sort((a, b) => (a.at - b.at) || byName(a.n, b.n));
    let y = HEAD; let w = 0;
    for (const { n } of order) {
      const [cw, ch] = sizeOf(n, chips);
      pos[n.id] = { x, y, w: cw, h: ch };
      y += ch + ROW_GAP; w = Math.max(w, cw);
    }
    // Cards narrower than their column sit in its middle, so a column's lines leave and enter at one edge.
    for (const { n } of order) pos[n.id].x = x + (w - pos[n.id].w) / 2;
    columns.push({ key, label, x, w });
    bottom = Math.max(bottom, y - ROW_GAP);
    x += w + COL_GAP;
  }
  const width = Math.max(720, x - COL_GAP);
  const strips = [];
  let y = bottom + STRIP_GAP;
  for (const [key, label] of STRIPS) {
    const members = nodes.filter((n) => placeOf(n.band) === key).sort(byName);
    if (!members.length) continue;
    const isOpen = open.has(key);
    let h = STRIP_CLOSED;
    if (isOpen) {
      let cx = 0; let cy = y + STRIP_CLOSED; let rowH = 0;
      for (const n of members) {
        const [cw, ch] = sizeOf(n, chips);
        if (cx > 0 && cx + cw > width) { cx = 0; cy += rowH + ROW_GAP; rowH = 0; }
        pos[n.id] = { x: cx, y: cy, w: cw, h: ch, strip: true };
        cx += cw + ROW_GAP; rowH = Math.max(rowH, ch);
      }
      h = cy + rowH - y;
    }
    strips.push({ key, label, y, h, open: isOpen, ids: members.map((n) => n.id) });
    y += h + ROW_GAP;
  }
  return { columns, strips, pos, width, height: strips.length ? y - ROW_GAP : bottom };
}

/** The two ends a line is drawn between: from the one that uses to the one used. A container builds a module, so that
 * line is drawn from the module to the container it runs in, the way the columns read. */
export const endsOf = (e) => (e.kind === 'builds' ? [e.to, e.from] : [e.from, e.to]);

/**
 * The side of a card a line leaves or enters: across columns, the facing sides; within one column, the right side of
 * both (the line bows out into the gap); to or from a strip, the bottom of the upper card and the top of the lower.
 */
function sidesOf(a, b) {
  if (a.strip || b.strip) return a.y + a.h <= b.y ? ['bottom', 'top'] : ['top', 'bottom'];
  if (a.x + a.w <= b.x) return ['right', 'left'];
  if (b.x + b.w <= a.x) return ['left', 'right'];
  return ['right', 'right'];
}
function portOf(p, side, f) {
  if (side === 'right') return [p.x + p.w, p.y + p.h * f];
  if (side === 'left') return [p.x, p.y + p.h * f];
  if (side === 'bottom') return [p.x + p.w * f, p.y + p.h];
  return [p.x + p.w * f, p.y];
}

/**
 * A line from card `a` to card `b`, a smooth curve that leaves and enters each side square to it. `pa` and `pb` say
 * where along its side the line leaves `a` and enters `b`, as a fraction of that side (½ = the middle); `routesOf`
 * spreads them so lines that share a side do not share a pixel. `end` is where the arrowhead sits.
 */
export function pathOf(a, b, pa = 0.5, pb = 0.5) {
  if (!a || !b) return null;
  const [sa, sb] = sidesOf(a, b);
  const [x1, y1] = portOf(a, sa, pa); const [x2, y2] = portOf(b, sb, pb);
  const out = { right: [1, 0], left: [-1, 0], bottom: [0, 1], top: [0, -1] };
  const reach = sa === sb ? 36 + Math.abs(y2 - y1) * 0.12 : Math.max(36, (Math.abs(x2 - x1) + Math.abs(y2 - y1)) * 0.4);
  const [ax, ay] = out[sa]; const [bx, by] = out[sb];
  const d = `M${x1} ${y1} C${x1 + ax * reach} ${y1 + ay * reach} ${x2 + bx * reach} ${y2 + by * reach} ${x2} ${y2}`;
  return { d, mid: [(x1 + x2) / 2, (y1 + y2) / 2], end: [x2, y2] };
}

/**
 * Every edge's line, with the lines that leave or enter one side of one card spread along it: the k-th of N at
 * k/(N+1), ranked by where the other end sits, so neighbours do not cross. A side with one line keeps the middle.
 * A line with an end that has no place (a folded strip's card, a node not drawn) is null.
 */
export function routesOf(edges, pos) {
  const sides = new Map();
  const add = (key, i, c) => { if (!sides.has(key)) sides.set(key, []); sides.get(key).push({ i, c }); };
  const geo = edges.map((e, i) => {
    const [from, to] = endsOf(e);
    const a = pos[from]; const b = pos[to];
    if (!a || !b || from === to) return null;
    const [sa, sb] = sidesOf(a, b);
    const vertical = sa === 'top' || sa === 'bottom';
    const ka = `${from}:${sa}`; const kb = `${to}:${sb}`;
    add(ka, i, vertical ? b.x + b.w / 2 : b.y + b.h / 2);
    add(kb, i, vertical ? a.x + a.w / 2 : a.y + a.h / 2);
    return { a, b, ka, kb };
  });
  const at = new Map();
  for (const [key, list] of sides) {
    list.sort((p, q) => p.c - q.c || p.i - q.i);
    list.forEach((p, k) => at.set(`${key}|${p.i}`, (k + 1) / (list.length + 1)));
  }
  return geo.map((g, i) => (g ? pathOf(g.a, g.b, at.get(`${g.ka}|${i}`), at.get(`${g.kb}|${i}`)) : null));
}

export function chipsOf(node, doc) {
  const p = (doc.provides?.endpoints ?? []).filter((e) => e.module === node.id).map((e) => `${e.method} ${e.path}`);
  const c = (doc.consumes?.endpoints ?? []).filter((e) => e.module === node.id).map((e) => `→ ${e.method} ${e.path}`);
  const all = [...p, ...c];
  return all.length > CHIPS_MAX ? [...all.slice(0, CHIPS_MAX), t('+{n} more', { n: all.length - CHIPS_MAX })] : all;
}
