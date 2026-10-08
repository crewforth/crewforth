// Where everything on the graph goes.
//
// A session's agents are laid out as a tree that reads left to right: the session on the left, what it spawned in
// the next column, what those spawned in the one after. Siblings stack downward. This file decides which nodes are
// drawn on their own, which are drawn as one group, how big each thing is and where it sits. It touches no page:
// it is a function from the server's nodes to boxes and wires, so every rule below can be asserted by calling it.
//
// THREE RULES THE REST FOLLOWS FROM
//
// 1. Arrival appends. Every node gets a sequence number the first time it is seen, and a column is stacked in
//    that order. A new agent therefore lands at the end of its column and nothing that was already drawn changes
//    place. What does move things is a container growing (a run that gains a member is taller) and the viewer
//    asking for a different picture (folding, grouping, density).
// 2. Nothing here reads the zoom. Positions are a function of the nodes and the viewer's choices, never of the
//    view, so zooming cannot move a card.
// 3. Colour is not decided here at all. A box carries its status; the stylesheet turns status into colour.

import { typeOf, roleName, shownType } from './names.js';

/* ------------------------------------------------------------- measures --- */

export const SIZE = {
  padX: 24, padY: 16,          // the canvas's own margin
  colGap: 56,                  // between one depth and the next
  rowGap: 12,                  // between siblings
  session: { w: 200, h: 84 },
  card: { w: 248, h: 64 },     // an agent, and a folded group
  chip: { w: 248, h: 36 },     // an agent at compact density
  group: {                     // an open group: a container holding its members
    padX: 8, top: 10, head: 20, gap: 6, bar: 4, bottom: 8,
    row: { h: 40, gap: 6 },    // a member as a row
    cell: { w: 150, h: 36, gap: 8 },   // a member as a chip in a grid
    rowsMax: 8,                // more members than this and rows become a grid
    colsMax: 4,
  },
};

// What `Auto` density does, and when. It reaches for things in order — nothing, then folding agents of one type
// together, then chips, then folding the largest groups — and stops at the first that makes the picture short
// enough to read. Both numbers were chosen by measuring; the measurements are in the pull request that added
// this file.
export const AUTO = {
  // How tall the picture may be. The canvas of a 1440x900 window with the inspector open is 724px high, of which
  // fitting leaves 676 after its margin; a card's 12px name reads down to 9px, which is a zoom of 0.75.
  // 676 / 0.75 = 901.
  tallest: 900,
  // Same-type siblings fold into one card from this many, once the picture is too tall.
  stackAt: 3,
};

export const GROUPINGS = ['run', 'type', 'parent', 'none'];
export const DENSITIES = ['auto', 'comfortable', 'compact'];

// The handful of things a status means to a reader. `killed` and `stopped` come off the transcript verbatim and
// mean what `failed` means: this branch did not finish on its own terms.
export const STATE = {
  running: 'live',
  starting: 'waking',
  done: 'done',
  failed: 'failed',
  killed: 'failed',
  stopped: 'failed',
  ended: 'quiet',
  stale: 'quiet',
  session: 'root',
};
export const stateOf = (status) => STATE[status] ?? 'unknown';

const SESSION = 'session';

/* --------------------------------------------------------------- groups --- */

const byArrival = (seq) => (a, b) => (seq.get(a.id) ?? 0) - (seq.get(b.id) ?? 0);

/** Counts by status, in the order a bar draws them. */
export function tally(members) {
  const counts = {};
  for (const m of members) counts[m.status ?? 'unknown'] = (counts[m.status ?? 'unknown'] ?? 0) + 1;
  return counts;
}

/**
 * The one status a group's wire and frame speak for. Something alive outranks something wrong, and something wrong
 * outranks something finished: a group with a running member is still working, and that is what its wire shows,
 * while its bar and its count carry the failure.
 */
export function groupStatus(members) {
  const states = new Set(members.map((m) => stateOf(m.status)));
  if (states.has('live')) return 'running';
  if (states.has('waking')) return 'starting';
  if (states.has('failed')) return 'failed';
  if (states.has('done')) return 'done';
  if (states.has('quiet')) return 'ended';
  return members[0]?.status ?? 'unknown';
}

/**
 * Give every node not seen before the next sequence number, in an order that makes a first layout tidy: a parent's
 * children together, each family in the order it started. Later arrivals simply continue the count.
 */
export function sequence(nodes, seq = new Map()) {
  const kids = new Map();
  for (const n of nodes) {
    if (n.kind === 'session') continue;
    const p = n.parentId ?? SESSION;
    if (!kids.has(p)) kids.set(p, []);
    kids.get(p).push(n);
  }
  let next = seq.size ? Math.max(...seq.values()) + 1 : 0;
  const visit = (id) => {
    const list = (kids.get(id) ?? []).slice().sort((a, b) => (a.startedAt ?? Infinity) - (b.startedAt ?? Infinity)
      || String(a.id).localeCompare(String(b.id)));
    for (const n of list) {
      if (!seq.has(n.id)) { seq.set(n.id, next); next += 1; }
      visit(n.id);
    }
  };
  const session = nodes.find((n) => n.kind === 'session');
  if (session && !seq.has(session.id)) { seq.set(session.id, -1); }
  visit(session?.id ?? SESSION);
  // A node whose parent is not in the graph still gets a place.
  for (const n of nodes) if (!seq.has(n.id)) { seq.set(n.id, next); next += 1; }
  return seq;
}

/**
 * Which nodes are drawn together. Returns the items of the tree: each is a session, an agent, or a group.
 *
 * `run` — a workflow run is a group holding its agents.
 * `type` — the same, and siblings of one agent type are a group.
 * `parent` — the same, and an agent's children are a group.
 * `none` — nothing is grouped; a run is an ordinary card with its agents after it.
 *
 * At `auto` density, once the picture is too tall (`stack`), siblings of one type fold into a group from
 * AUTO.stackAt whatever the grouping is, except under `none`, which means none.
 *
 * `aside(id)` says a type group is open beside itself: its members are then items of their own, one column to the
 * right of the group's card, and what they spawned is a column further on.
 */
function itemsOf(nodes, { group, density, seq, stack, aside }) {
  const byId = new Map(nodes.map((n) => [n.id, n]));
  const kids = new Map();
  for (const n of nodes) {
    if (n.kind === 'session') continue;
    const p = byId.has(n.parentId) ? n.parentId : SESSION;
    if (!kids.has(p)) kids.set(p, []);
    kids.get(p).push(n);
  }
  for (const list of kids.values()) list.sort(byArrival(seq));

  const items = [];
  const session = nodes.find((n) => n.kind === 'session');
  if (session) items.push({ id: session.id, kind: 'session', node: session, parent: null, depth: 0 });

  const stackAt = group === 'type' ? 2 : (density === 'auto' && group !== 'none' && stack ? AUTO.stackAt : Infinity);

  // `anchor` is the item a node's wire comes out of; `via` is the member row inside it, when the parent is one.
  const place = (parentId, anchor, via, depth) => {
    const list = kids.get(parentId) ?? [];
    if (!list.length) return;

    // An agent's children as one group.
    if (group === 'parent' && list.length >= 2 && byId.get(parentId)?.kind === 'agent') {
      const g = groupItem(`kids:${parentId}`, 'parent', list, anchor, via, depth, seq, {
        label: `${shownType(byId.get(parentId))} → ${list.length}`, of: byId.get(parentId),
      });
      items.push(g);
      for (const m of list) place(m.id, g, m.id, depth + 1);
      return;
    }

    const types = new Map();
    for (const n of list) {
      if (n.kind !== 'agent') continue;
      const t = typeOf(n);
      if (!types.has(t)) types.set(t, []);
      types.get(t).push(n);
    }
    const stacked = new Set();
    for (const [t, members] of types) {
      if (members.length < stackAt) continue;
      const g = groupItem(`type:${parentId}:${t}`, 'type', members, anchor, via, depth, seq, {
        // The role is the name and the number is a badge beside it: `count` is drawn apart from `label`.
        label: roleName(t), count: members.length, real: t, agentType: members[0].agentType ?? null,
      });
      items.push(g);
      g.aside = Boolean(aside?.(g.id));
      for (const m of members) {
        stacked.add(m.id);
        if (!g.aside) { place(m.id, g, m.id, depth + 1); continue; }
        const item = { id: m.id, kind: 'agent', node: m, parent: g, via: null, depth: depth + 1, seq: seq.get(m.id) ?? 0, member: true };
        items.push(item);
        place(m.id, item, null, depth + 2);
      }
    }

    for (const n of list) {
      if (stacked.has(n.id)) continue;
      if (n.kind === 'workflow' && group !== 'none') {
        const members = kids.get(n.id) ?? [];
        const g = groupItem(n.id, 'run', members, anchor, via, depth, seq, {
          label: n.workflowId ?? 'workflow run', node: n,
        });
        g.seq = seq.get(n.id) ?? g.seq;
        items.push(g);
        for (const m of members) place(m.id, g, m.id, depth + 1);
        continue;
      }
      const item = { id: n.id, kind: n.kind === 'workflow' ? 'run-card' : 'agent', node: n, parent: anchor, via, depth, seq: seq.get(n.id) ?? 0 };
      items.push(item);
      place(n.id, item, null, depth + 1);
    }
  };
  if (session) place(session.id, items[0], null, 1);
  return items;
}

function groupItem(id, type, members, anchor, via, depth, seq, extra) {
  return {
    id,
    kind: 'group',
    type,
    members,
    counts: tally(members),
    status: groupStatus(members),
    parent: anchor,
    via,
    depth,
    seq: Math.min(...members.map((m) => seq.get(m.id) ?? 0), Infinity),
    ...extra,
  };
}

/* ----------------------------------------------------------------- plan --- */

/**
 * @param nodes   the server's nodes
 * @param opts.group     one of GROUPINGS
 * @param opts.density   one of DENSITIES
 * @param opts.seq       Map id -> arrival number, kept by the caller across calls (see `sequence`)
 * @param opts.open      Map groupId -> boolean, the viewer's own folds; a group not in it takes its default
 * @param opts.pinned    Map itemId -> {x, y}, positions the viewer set by hand
 * @param opts.sessionY  where the session card was put, to keep it there; omitted on a fresh layout
 * @param opts.aside     true when an open type group puts its agents in the next column instead of growing
 *                       downward; a narrow window leaves it off
 * @returns { items, edges, width, height, drawn, density, sessionY }
 */
export function plan(nodes, opts = {}) {
  const group = GROUPINGS.includes(opts.group) ? opts.group : 'run';
  const asked = DENSITIES.includes(opts.density) ? opts.density : 'auto';
  const seq = opts.seq ?? sequence(nodes);
  const open = opts.open ?? new Map();
  const pinned = opts.pinned ?? new Map();

  // A type group starts folded: it is the same thing several times. A run or an agent's children start open.
  const isOpen = (g) => (open.has(g.id) ? open.get(g.id) : g.type !== 'type');
  const aside = opts.aside ? (id) => open.get(id) === true : null;

  // What is drawn, and how many agents of it the viewer reads one by one: a card, a row or a chip each.
  const drawFrom = (items) => {
    // A node inside a folded group is not drawn, and neither is anything it spawned.
    const hidden = new Set();
    for (const it of items) {
      const p = it.parent;
      if (!p) continue;
      if (hidden.has(p.id) || (p.kind === 'group' && it.via && !isOpen(p))) hidden.add(it.id);
    }
    const shown = items.filter((it) => !hidden.has(it.id));
    let count = 0;
    for (const it of shown) {
      if (it.kind === 'agent' || it.kind === 'run-card') count += 1;
      // A group open beside itself has its agents among the items already.
      else if (it.kind === 'group' && !it.aside) count += isOpen(it) ? it.members.length : 1;
    }
    return { shown, count };
  };

  const G = SIZE.group;

  /** Size and place everything drawn, at one density. Returns the box the picture needs. */
  const lay = (drawnItems, compact) => {
    for (const it of drawnItems) {
      if (it.kind === 'session') { it.w = SIZE.session.w; it.h = SIZE.session.h; continue; }
      if (it.kind !== 'group') {
        const sz = compact ? SIZE.chip : SIZE.card;
        it.w = sz.w; it.h = sz.h; it.compact = compact;
        continue;
      }
      it.open = isOpen(it);
      // `boxed` is the group drawn as a container with its members inside. Open beside itself it stays a card.
      it.boxed = it.open && !it.aside;
      if (!it.boxed) { it.w = SIZE.card.w; it.h = SIZE.card.h; it.cells = null; continue; }
      const n = it.members.length;
      const grid = compact || n > G.rowsMax;
      const cols = grid ? Math.min(G.colsMax, Math.max(1, Math.ceil(n / G.rowsMax))) : 1;
      const rows = Math.ceil(n / cols);
      const cellH = grid ? G.cell.h : G.row.h;
      const cellGap = grid ? G.cell.gap : G.row.gap;
      const bodyH = rows * cellH + Math.max(0, rows - 1) * cellGap;
      it.grid = grid;
      it.cols = cols;
      it.w = cols === 1 ? SIZE.card.w : 2 * G.padX + cols * G.cell.w + (cols - 1) * G.cell.gap;
      it.h = G.top + G.head + G.gap + G.bar + G.gap + bodyH + G.bottom;
      // Where each member sits inside the container, so a wire can leave from its row.
      const cellW = (it.w - 2 * G.padX - (cols - 1) * cellGap) / cols;
      const top = G.top + G.head + G.gap + G.bar + G.gap;
      it.cells = it.members.map((m, i) => ({
        id: m.id,
        node: m,
        x: G.padX + (i % cols) * (cellW + cellGap),
        y: top + Math.floor(i / cols) * (cellH + cellGap),
        w: cellW,
        h: cellH,
      }));
    }

    // Columns: one per depth, as wide as the widest thing in it.
    const depths = [...new Set(drawnItems.map((it) => it.depth))].sort((a, b) => a - b);
    const colX = new Map();
    let x = SIZE.padX;
    for (const d of depths) {
      colX.set(d, x);
      x += Math.max(...drawnItems.filter((it) => it.depth === d).map((it) => it.w)) + SIZE.colGap;
    }
    const width = x - SIZE.colGap + SIZE.padX;

    // Stack each column in arrival order. A child starts level with what spawned it when there is room, and
    // below the previous box when there is not.
    const anchorY = (it) => {
      const p = it.parent;
      if (!p || p.kind === 'session') return SIZE.padY;
      const cell = cellOf(it);
      const cy = cell ? p.y + cell.y + cell.h / 2 : p.y + p.h / 2;
      return Math.max(SIZE.padY, cy - it.h / 2);
    };
    let height = 0;
    for (const d of depths) {
      if (d === 0) continue;
      const col = drawnItems.filter((it) => it.depth === d).sort((a, b) => a.seq - b.seq || String(a.id).localeCompare(String(b.id)));
      let cursor = SIZE.padY;
      for (const it of col) {
        it.x = colX.get(d);
        it.y = Math.max(cursor, anchorY(it));
        cursor = it.y + it.h + SIZE.rowGap;
      }
      height = Math.max(height, cursor - SIZE.rowGap + SIZE.padY);
    }

    // The session sits beside the middle of what it spawned, and stays where it was first put.
    const session = drawnItems.find((it) => it.kind === 'session');
    let sessionY = opts.sessionY;
    if (session) {
      const first = drawnItems.filter((it) => it.depth === 1);
      if (sessionY == null) {
        const top = first.length ? Math.min(...first.map((it) => it.y)) : SIZE.padY;
        const bottom = first.length ? Math.max(...first.map((it) => it.y + it.h)) : SIZE.padY + session.h;
        sessionY = Math.max(SIZE.padY, Math.round((top + bottom) / 2 - session.h / 2));
      }
      session.x = colX.get(0);
      session.y = sessionY;
      height = Math.max(height, sessionY + session.h + SIZE.padY);
    }
    return { width, height, sessionY: sessionY ?? null };
  };
  const cellOf = (it) => (it.via && it.parent?.kind === 'group' && it.parent.open
    ? it.parent.cells?.find((c) => c.id === it.via) ?? null : null);

  // Auto, in the order it reaches for things: nothing while the picture is short enough to read; siblings of one
  // type folded together when it is not; chips if it still is not.
  let pass = drawFrom(itemsOf(nodes, { group, density: asked, seq, stack: false, aside }));
  let compact = asked === 'compact';
  let stacked = false;
  let box = lay(pass.shown, compact);
  if (asked === 'auto' && box.height > AUTO.tallest) {
    if (group !== 'none' && group !== 'type') {
      const folded = drawFrom(itemsOf(nodes, { group, density: asked, seq, stack: true, aside }));
      if (folded.shown.some((it) => it.kind === 'group' && it.type === 'type')) { pass = folded; stacked = true; box = lay(pass.shown, false); }
    }
    if (box.height > AUTO.tallest) { compact = true; box = lay(pass.shown, true); }
  }
  const drawnItems = pass.shown;
  const drawn = pass.count;
  const density = compact ? 'compact' : 'comfortable';
  const { width } = box;
  let { height } = box;
  const { sessionY } = box;

  // The viewer's own placements win, and the wires follow them.
  for (const it of drawnItems) {
    const p = pinned.get(it.id);
    if (p) { it.x = p.x; it.y = p.y; it.pinned = true; }
  }

  // Wires: out of the right edge of what spawned a thing, into its left edge.
  const edges = [];
  for (const it of drawnItems) {
    const p = it.parent;
    if (!p) continue;
    const cell = cellOf(it);
    const from = cell
      ? { x: p.x + cell.x + cell.w, y: p.y + cell.y + cell.h / 2 }
      : { x: p.x + p.w, y: p.y + p.h / 2 };
    const status = it.kind === 'group' ? it.status : (it.node.status ?? 'unknown');
    // A group's wire says whether the group is still working. What went wrong inside it is said by its bar, its
    // count and the member itself; a red wire into twelve agents because one failed would say the wrong thing
    // about eleven.
    const state = it.kind === 'group' && stateOf(status) === 'failed' ? 'done' : stateOf(status);
    edges.push({
      key: `${it.via ?? p.id}\u0000${it.id}`,
      source: it.via ?? p.id,
      target: it.id,
      from,
      to: { x: it.x, y: it.y + it.h / 2 },
      status,
      state,
    });
  }

  return {
    items: drawnItems, edges, width: Math.max(width, SIZE.padX * 2), height: Math.max(height, SIZE.padY * 2),
    drawn, density, group, stacked, aside: Boolean(aside), sessionY: sessionY ?? null,
  };
}

/**
 * Which open groups to fold when a session first opens too tall even as chips: the largest first, until the
 * picture is short enough to read or there is nothing left to fold. Returns the ids to fold; an empty list when
 * nothing needs it.
 */
export function crowdFolds(nodes, opts = {}) {
  if ((opts.density ?? 'auto') !== 'auto') return [];
  const open = new Map(opts.open ?? []);
  const folds = [];
  for (let guard = 0; guard < 64; guard += 1) {
    const p = plan(nodes, { ...opts, open, pinned: new Map(), sessionY: null });
    if (p.height <= AUTO.tallest) break;
    const next = p.items.filter((it) => it.kind === 'group' && it.open && it.members.length > 1)
      .sort((a, b) => b.members.length - a.members.length || String(a.id).localeCompare(String(b.id)))[0];
    if (!next) break;
    open.set(next.id, false);
    folds.push(next.id);
  }
  return folds;
}

/** The zoom that shows the whole plan in a pane, between the two bounds the toolbar allows. */
export const ZOOM = { min: 0.25, max: 2, fitMax: 1, pad: 24 };
export function fitZoom(width, height, paneW, paneH) {
  const k = Math.min((paneW - 2 * ZOOM.pad) / Math.max(1, width), (paneH - 2 * ZOOM.pad) / Math.max(1, height), ZOOM.fitMax);
  return Math.min(ZOOM.max, Math.max(ZOOM.min, k));
}

/* ------------------------------------------------------------ attention --- */

/**
 * What needs someone: agents waiting on the viewer first, then the ones that did not finish on their own terms,
 * newest first. `waiting` is the set of agent ids the page knows are parked on an approval; the graph itself has
 * no such status.
 */
export function attention(nodes, waiting = new Set()) {
  const agents = nodes.filter((n) => n.kind === 'agent');
  const when = (n) => n.endedAt ?? n.updatedAt ?? n.startedAt ?? 0;
  const needs = agents.filter((n) => waiting.has(n.id)).sort((a, b) => when(b) - when(a));
  const failed = agents.filter((n) => !waiting.has(n.id) && stateOf(n.status) === 'failed').sort((a, b) => when(b) - when(a));
  return [
    ...needs.map((n) => ({ id: n.id, tone: 'waiting', name: shownType(n), real: typeOf(n), says: 'waiting for you' })),
    ...failed.map((n) => ({
      id: n.id,
      tone: 'fail',
      name: shownType(n),
      real: typeOf(n),
      says: [n.status, n.errors ? `${n.errors} ${n.errors === 1 ? 'error' : 'errors'}` : null,
        n.workflow ? `in ${n.workflow}` : null].filter(Boolean).join(' · '),
    })),
  ];
}
