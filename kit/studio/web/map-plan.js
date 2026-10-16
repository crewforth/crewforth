// What the Map view draws, worked out from a crew map. No page in it.
//
// The map is Crewforth's (server/lib/crew-map.js reads it). This file puts each node in a band, says which lines
// a selection lights, orders the findings and words them. It invents no layer: a module's layer is the one /crew-map
// wrote for it (citing the lines it rests on); without one, its band is what the scan shows of it, and a module whose
// place the scan does not show goes to "Unplaced". A finding the scanner hides by default stays hidden until asked.

// The layers /crew-map may write (eval/lib/crew-map/narrative.mjs LAYERS), set between the bands the scan alone
// gives, so a map with no layer is drawn in the same order as before.
export const LAYER_KEYS = ['ui', 'api', 'service', 'data', 'infra', 'tool', 'library'];
export const BANDS = [
  ['ui', 'UI'],
  ['clients', 'Clients'],
  ['api', 'API'],
  ['entry', 'Entry points'],
  ['service', 'Service'],
  ['core', 'Core'],
  ['data', 'Data'],
  ['infra', 'Infrastructure'],
  ['library', 'Library'],
  ['tool', 'Tools'],
  ['external', 'External'],
  ['unplaced', 'Unplaced'],
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

/**
 * The folders that hold two or more modules of one band: a group the view can fold into one card. A module at the
 * project's root, or alone in its folder, is in no group. { groupId: { id, band, folder, members: [ids] } }
 */
export function groupsOf(nodes) {
  const by = new Map();
  for (const n of nodes) {
    if (n.kind !== 'module' || typeof n.path !== 'string' || !n.path.includes('/')) continue;
    const folder = n.path.slice(0, n.path.lastIndexOf('/'));
    const id = `grp:${n.band}:${folder}`;
    const g = by.get(id) ?? by.set(id, { id, band: n.band, folder, members: [] }).get(id);
    g.members.push(n.id);
  }
  return Object.fromEntries([...by].filter(([, g]) => g.members.length > 1));
}

/**
 * The nodes and edges with the folded groups folded: each folded group is one card in place of its members, and
 * the members' lines are its lines, one per (from, to, kind), drawn solid when any of them is.
 */
export function foldView(nodes, edges, groups, folded) {
  const into = new Map();
  for (const g of Object.values(groups)) if (folded.has(g.id)) for (const m of g.members) into.set(m, g.id);
  if (!into.size) return { nodes, edges };
  const out = [];
  const seen = new Set();
  for (const n of nodes) {
    const gid = into.get(n.id);
    if (!gid) { out.push(n); continue; }
    if (seen.has(gid)) continue;
    seen.add(gid);
    const g = groups[gid];
    out.push({ id: gid, kind: 'group', band: g.band, name: `${g.folder}/`, folder: g.folder, members: g.members });
  }
  const em = new Map();
  for (const e of edges) {
    const from = into.get(e.from) ?? e.from;
    const to = into.get(e.to) ?? e.to;
    if (from === to) continue;
    const k = `${from}>${to}>${e.kind}`;
    const was = em.get(k);
    if (!was) em.set(k, { ...e, from, to });
    else if (lineOf(e) === 'evidence' && was.line !== 'evidence') em.set(k, { ...was, solid: true, line: 'evidence' });
  }
  return { nodes: out, edges: [...em.values()] };
}

/** The layout with the viewer's own placings over it: a card placed by hand stays where it was put. */
export function placed(lay, pins) {
  const pos = { ...lay.pos };
  for (const [id, p] of Object.entries(pins ?? {})) if (pos[id]) pos[id] = { ...pos[id], x: p.x, y: p.y };
  const right = Object.values(pos).reduce((m, p) => Math.max(m, p.x + p.w), lay.width);
  const bottom = Object.values(pos).reduce((m, p) => Math.max(m, p.y + p.h), lay.height);
  return { ...lay, pos, width: right, height: bottom };
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
        id: `cmp:${c.id}:${m.method} ${m.path}`, rule: 'compare-missing', title: `${m.method} ${m.path} is called by ${c.name} and not provided here`,
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

/** What a card says under its name. */
export function cardSub(node, doc) {
  if (node.kind === 'client') return `${node.from} · ${node.calls.length} ${node.calls.length === 1 ? 'call' : 'calls'} here`;
  if (node.kind === 'service') return node.image ? `container · ${node.image}` : 'container';
  const provided = (doc.provides?.endpoints ?? []).filter((e) => e.module === node.id).length;
  const tech = (node.tech ?? []).slice(0, 2).map((t) => t.replace(/@.*$/, '')).join(' · ');
  return [tech || node.stack, provided ? `${provided} ${provided === 1 ? 'endpoint' : 'endpoints'}` : null].filter(Boolean).join(' · ');
}

/**
 * What a module's card says, as the Map draws it: a kind line (its domain, else its stack, and how many endpoints it
 * provides), up to three of what it is built with, and the outside services it calls, folded into one line under it.
 */
export const CARD_CHIPS = 3;
export function cardOf(node, doc) {
  const provided = (doc.provides?.endpoints ?? []).filter((e) => e.module === node.id).length;
  const kind = [node.narrative?.domain ?? node.stack ?? null, provided ? `${provided} ${provided === 1 ? 'endpoint' : 'endpoints'}` : null].filter(Boolean).join(' · ');
  const tech = (node.tech ?? []).map((t) => t.replace(/@.*$/, ''));
  return { kind, chips: tech.slice(0, CARD_CHIPS), more: Math.max(0, tech.length - CARD_CHIPS), outside: outsideOf(node, doc) };
}

/** The outside services a module calls, by name, in the order they are named: what its card folds under it. */
export function outsideOf(node, doc) {
  const byId = new Map((doc.nodes ?? []).map((n) => [n.id, n]));
  const names = [];
  for (const e of doc.edges ?? []) {
    if (e.from !== node.id) continue;
    const to = byId.get(e.to);
    if (to?.kind !== 'external') continue;
    const name = to.label && to.label !== 'unknown' ? to.label : (to.hosts ?? [])[0] ?? to.id.replace(/^ext:[^:]+:/, '');
    if (!names.includes(name)) names.push(name);
  }
  return names.sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
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
    `${n('module')} ${n('module') === 1 ? 'module' : 'modules'}`,
    `${n('external')} external`,
    `${eps} ${eps === 1 ? 'endpoint' : 'endpoints'}`,
    `${findings.shown.length} ${findings.shown.length === 1 ? 'finding' : 'findings'}`,
  ];
}

/** The source strip: the file, the commit it was scanned at, and how far HEAD has moved since. */
export function sourceOf(data) {
  const commit = data.doc?.source?.commit ?? null;
  const behind = data.behind?.count;
  return {
    file: data.file,
    at: commit ? `scanned at ${commit.slice(0, 7)}` : 'scanned outside git',
    behind: typeof behind === 'number' && behind > 0 ? `${behind} ${behind === 1 ? 'commit' : 'commits'} behind` : null,
    behindNote: typeof behind === 'number' ? null : (data.behind?.reason ?? null),
    rule: 'Nothing is run; files are only read.',
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
  const out = edges.filter((e) => e.from === node.id).map((e) => line(e, e.to));
  const into = edges.filter((e) => e.to === node.id).map((e) => line(e, e.from));
  // Connections, by the kind of line: what the inspector's second tab lists.
  const byKind = {};
  for (const [dir, list] of [['out', out], ['in', into]]) for (const c of list) (byKind[c.kind] ??= { out: [], in: [] })[dir].push(c);
  return {
    title: node.name ?? node.label ?? node.id,
    path: node.path ?? (node.kind === 'external' ? (node.hosts ?? []).join(', ') : null),
    chips: (node.tech ?? []).map((t) => t.replace('@', ' ')),
    // /crew-map's description: { text, cites }, each cite a file:line of this node's evidence (eval/lib/crew-map/narrative.mjs).
    narrative: typeof node.narrative?.text === 'string' ? node.narrative.text : null,
    narrativeCites: Array.isArray(node.narrative?.cites) ? node.narrative.cites.filter((c) => typeof c === 'string') : [],
    narrativeNote: 'Not written yet: this map holds no description of the module, only what its files show.',
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
  if (!data) return 'Reading the map…';
  if (data.measured === false) return data.missing ? `No map yet — ${data.reason}` : `Not read — ${data.reason}`;
  return null;
}

// A module card holds its name and kind, a row of what it is built with, and the line of outside services under it.
export const CARD = { module: [280, 104], service: [280, 104], client: [280, 104], group: [280, 104], external: [104, 52] };
const GAP_X = 24;
const GAP_Y = 20;
const LEFT = 140;      // the band's label sits in this column
const PAD_Y = 18;
const CHIP_ROW = 26;   // one row of endpoint chips under a card, when the Endpoints layer is on
export const CHIPS_MAX = 4;

/**
 * Where everything sits: bands from top to bottom, each as tall as its rows of cards; cards left to right,
 * wrapping at `width`. Empty bands are not drawn. A card with endpoint chips (`chips[id]`) is taller. With
 * `rowKey`, a run of cards that share a key (an open folder group) starts a row of its own and the next card after
 * it does too, so a frame drawn around the run holds those cards and no other.
 * @returns { bands: [{ key, label, y, h }], pos: { id: { x, y, w, h } }, width, height }
 */
export function layoutOf(nodes, { width = 960, chips = {}, rowKey = null } = {}) {
  const pos = {};
  const bands = [];
  let y = 0;
  for (const [key, label] of BANDS) {
    const members = nodes.filter((n) => n.band === key);
    if (!members.length) continue;
    let x = LEFT; let rowY = y + PAD_Y; let rowH = 0; let prev = null;
    for (const n of members) {
      const key = rowKey?.(n) ?? null;
      if (x > LEFT && key !== prev && (key || prev)) { x = LEFT; rowY += rowH + GAP_Y; rowH = 0; }
      prev = key;
      const [w, h0] = CARD[n.kind] ?? CARD.module;
      const extra = Math.ceil(Math.min(chips[n.id] ?? 0, CHIPS_MAX + 1) / 2) * CHIP_ROW;
      const h = h0 + extra;
      if (x > LEFT && x + w > width) { x = LEFT; rowY += rowH + GAP_Y; rowH = 0; }
      pos[n.id] = { x, y: rowY, w, h };
      x += w + GAP_X; rowH = Math.max(rowH, h);
    }
    const h = rowY + rowH + PAD_Y - y;
    bands.push({ key, label, y, h });
    y += h;
  }
  const right = Object.values(pos).reduce((m, p) => Math.max(m, p.x + p.w), LEFT);
  return { bands, pos, width: Math.max(width, right + GAP_X), height: y };
}

/** A line between two cards: out of the bottom of the upper one into the top of the lower, or side to side. */
export function pathOf(a, b) {
  if (!a || !b) return null;
  const down = b.y >= a.y + a.h;
  const up = a.y >= b.y + b.h;
  if (down || up) {
    const [s, t] = down ? [a, b] : [b, a];
    const x1 = s.x + s.w / 2; const y1 = s.y + s.h; const x2 = t.x + t.w / 2; const y2 = t.y;
    const m = (y1 + y2) / 2;
    return { d: `M${x1} ${y1} C${x1} ${m} ${x2} ${m} ${x2} ${y2}`, mid: [(x1 + x2) / 2, m] };
  }
  const [s, t] = a.x <= b.x ? [a, b] : [b, a];
  const x1 = s.x + s.w; const y1 = s.y + s.h / 2; const x2 = t.x; const y2 = t.y + t.h / 2;
  return { d: `M${x1} ${y1} L${x2} ${y2}`, mid: [(x1 + x2) / 2, (y1 + y2) / 2] };
}

/** The endpoint chips of a module, as the Endpoints layer lists them: what it provides, then what it calls. */
export function chipsOf(node, doc) {
  const p = (doc.provides?.endpoints ?? []).filter((e) => e.module === node.id).map((e) => `${e.method} ${e.path}`);
  const c = (doc.consumes?.endpoints ?? []).filter((e) => e.module === node.id).map((e) => `→ ${e.method} ${e.path}`);
  const all = [...p, ...c];
  return all.length > CHIPS_MAX ? [...all.slice(0, CHIPS_MAX), `+${all.length - CHIPS_MAX} more`] : all;
}
