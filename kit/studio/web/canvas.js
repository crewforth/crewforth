// The orchestration canvas.
//
// HTML cards over an SVG layer of wires — the same split n8n and React Flow use, and for the same reason: cards
// are far easier to style as DOM, curves are far easier to draw as paths. One shared transform keeps them
// registered.
//
// Where things go is not decided here. graph-plan.js turns the session's nodes into boxes and wires; this file
// draws them, keeps them drawn across polls, and answers the pointer. Three things it holds to:
//
//   Colour says status and nothing else. Who an agent is, is said by the mark in its tile.
//   A status is never colour alone: every dot has its word beside it.
//   A poll that changed nothing writes nothing. Each element remembers what it last drew.
import {
  plan, sequence, crowdFolds, fitZoom, stateOf, ZOOM, GROUPINGS, DENSITIES,
} from './graph-plan.js';
import { agentStatus } from './nav.js';

// How long an arriving wire takes to draw itself toward its new card. Short on purpose: this is a status panel,
// and anything a viewer has to wait through is a cost they pay on every spawn.
const DRAW_MS = 300;

// Above this many wires in motion at once the canvas stops moving them and shows the same states standing still.
//
// Two reasons, and the second is the one that decided the number. A dash travelling along a stroke is a
// paint-driven animation, not a composited one, so its cost scales with how many strokes are in motion rather
// than with how many exist. And 200 flowing lines carry less than 20 do — past a certain density motion stops
// reading as direction and starts reading as noise.
//
// Profiled 2026-09-20: 250 nodes with the budget full held a median frame of 8.3 ms with nothing over 16.7 ms,
// and the knee was 400 strokes. So the number is conservative for performance and kept for legibility. Measure
// it with packaging/studio-test/paint-profile.mjs, which refuses to quote a number from a pane that is not
// painting.
const MOTION_BUDGET = 60;

// How long the pointer rests on a card before its details are shown.
const TIP_MS = 400;

// Marks, so a card says what kind of thing it is before it is read.
//
// Crewforth's own is the three chevrons, drawn here because the shape is three strokes and its colours are the
// chevron tokens. The session and the run are plain strokes in the text colour.
//
// The mark for every other agent is NOT here. It is one file, web/icons/builtin.svg, handed in through
// setIcons(), so that changing it is changing that file and nothing else.
const MARK = {
  kit: '<svg viewBox="0 0 16 16" aria-hidden="true"><g fill="none" stroke-linecap="round" stroke-linejoin="round">'
    + '<polyline points="3.52,4.64 6.88,8 3.52,11.36" style="stroke:var(--chevron-1)" stroke-width="1.92"/>'
    + '<polyline points="6.4,4.64 9.76,8 6.4,11.36" style="stroke:var(--chevron-2)" stroke-width="1.92"/>'
    + '<polyline points="9.28,4.64 12.64,8 9.28,11.36" style="stroke:var(--chevron-3)" stroke-width="2.24"/></g></svg>',
  session: '<svg class="ic" viewBox="0 0 16 16" aria-hidden="true"><path d="M3 5l3 3-3 3M8 11h5"/></svg>',
  run: '<svg class="ic" viewBox="0 0 16 16" aria-hidden="true"><path d="M8 2l6 3-6 3-6-3 6-3z"/><path d="M2 8l6 3 6-3M2 11l6 3 6-3"/></svg>',
  chevron: '<svg class="ic" viewBox="0 0 16 16" aria-hidden="true"><path d="M6 4l4 4-4 4"/></svg>',
  down: '<svg class="ic" viewBox="0 0 16 16" aria-hidden="true"><path d="M4 6l4 4 4-4"/></svg>',
  close: '<svg class="ic" viewBox="0 0 16 16" aria-hidden="true"><path d="M4 4l8 8M12 4l-8 8"/></svg>',
};

const SVG = 'http://www.w3.org/2000/svg';

/** Element helper. `el` is used as a local name for a node all over this file, so the helper is named for what
 *  it does instead. */
function mk(tag, cls, text) {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text != null) n.textContent = text;
  return n;
}

const cap = (s) => (s ? s[0].toUpperCase() + s.slice(1) : s);
const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));

export class Canvas {
  constructor(root, { onSelect, onMenu, onChange } = {}) {
    this.root = root;
    this.onSelect = onSelect ?? (() => {});
    this.onMenu = onMenu ?? (() => {});
    this.onChange = onChange ?? (() => {});
    this.view = { x: 0, y: 0, k: 1 };
    this.nodes = new Map();      // id -> the server's node
    this.pos = new Map();        // drawn item id -> {x, y}
    this.pinned = new Map();     // item id -> {x, y} the viewer set by hand
    this.els = new Map();        // drawn item id -> element
    this.cellEls = new Map();    // agent id -> its row or chip inside an open group
    this.edgeEls = new Map();    // wire key -> <path>
    this.mapRects = new Map();   // drawn item id -> its box on the minimap
    this.seq = new Map();        // id -> arrival number (see graph-plan.js)
    this.open = new Map();       // group id -> the viewer's own fold
    // Ids that arrived on the last poll. A wire into one of these draws itself; every other wire is left alone,
    // so opening a group of 105 does not set 105 animations running at once.
    this.newborn = new Set();
    this.palette = { map: {} };
    this.icons = {};
    this.filter = null;          // statuses the page asked to isolate
    this.waiting = new Set();    // agents parked on an approval
    this.sessionState = null;    // { word, tone } for the session card's pill
    this.focusId = null;         // show only this branch
    this.group = 'run';
    this.density = readPref('crewforth-studio-density', DENSITIES, 'auto');
    this.lastGraph = null;
    this.lastPlan = null;
    this.sessionKey = null;
    this.sessionY = null;
    this.selected = null;
    this.firstRender = true;
    this.touched = false;        // the viewer moved the view themselves
    this.drawn = 0;

    this.#build();
    this.#wire();
    this.applyView();
  }

  #build() {
    this.root.classList.add('cv-root');
    this.root.replaceChildren();

    this.viewport = mk('div', 'cv-viewport');
    this.svg = document.createElementNS(SVG, 'svg');
    this.svg.setAttribute('class', 'cv-edges');
    this.svg.setAttribute('aria-hidden', 'true');
    this.edgeG = document.createElementNS(SVG, 'g');
    this.edgeG.setAttribute('class', 'cv-edge-g');
    this.svg.append(this.edgeG);
    this.nodeLayer = mk('div', 'cv-nodes');
    this.viewport.append(this.svg, this.nodeLayer);

    this.emptyEl = mk('div', 'cv-empty');
    this.emptyEl.hidden = true;

    // The whole graph, small. The frame is what the pane shows.
    this.mapEl = mk('div', 'cv-minimap');
    this.mapEl.setAttribute('aria-label', 'Minimap');
    this.mapEl.hidden = true;
    this.mapSvg = document.createElementNS(SVG, 'svg');
    this.mapSvg.setAttribute('aria-hidden', 'true');
    this.mapBoxes = document.createElementNS(SVG, 'g');
    this.mapFrame = document.createElementNS(SVG, 'rect');
    this.mapFrame.setAttribute('class', 'cv-map-frame');
    this.mapSvg.append(this.mapBoxes, this.mapFrame);
    this.mapEl.append(this.mapSvg);

    this.legendEl = this.#legend();
    this.spendEl = this.#spend();
    this.tipEl = mk('div', 'cv-tip');
    this.tipEl.setAttribute('role', 'tooltip');
    this.tipEl.hidden = true;

    this.root.append(this.viewport, this.emptyEl, this.mapEl, this.legendEl, this.spendEl, this.tipEl);
  }

  /** What the session spent: time, tokens and an estimate of the cost. Closed, it stays closed until asked for. */
  #spend() {
    const box = mk('div', 'cv-legend cv-spend');
    box.setAttribute('aria-label', 'Session summary');
    const head = mk('div', 'cv-legend-head');
    head.append(mk('span', 'cv-label', 'Session'));
    const close = mk('button', 'cv-x');
    close.type = 'button';
    close.setAttribute('aria-label', 'Close the session summary');
    close.innerHTML = MARK.close;
    close.addEventListener('click', () => this.showSpend(false));
    head.append(close);
    this.spendRows = mk('dl', 'cv-spend-rows');
    box.append(head, this.spendRows);
    this.spendOpen = readFlag('crewforth-studio-spend') !== 'closed';
    box.hidden = true;                       // until there is a session's usage to show
    return box;
  }

  showSpend(on) {
    this.spendOpen = Boolean(on);
    writeFlag('crewforth-studio-spend', on ? 'open' : 'closed');
    this.spendEl.hidden = !on || !this.spendCount;
  }

  /** The rows to show: [label, value, note], from usage.js `summaryRows`. An empty list hides the box. */
  setSpend(rows) {
    const sig = JSON.stringify(rows ?? []);
    if (sig === this.spendSig) return;
    this.spendSig = sig;
    this.spendCount = (rows ?? []).length;
    this.spendRows.replaceChildren(...(rows ?? []).flatMap(([label, value, note]) => {
      const dd = mk('dd', null, value ?? '');
      dd.title = note ?? '';
      const dt = mk('dt', null, label);
      dt.title = note ?? '';
      return [dt, dd];
    }));
    this.spendEl.hidden = !this.spendOpen || !this.spendCount;
  }

  /** What the lines and the two marks mean. Shown until it is closed, and then not again unless asked for. */
  #legend() {
    const box = mk('div', 'cv-legend');
    box.setAttribute('aria-label', 'Legend');
    const head = mk('div', 'cv-legend-head');
    head.append(mk('span', 'cv-label', 'Legend'));
    const close = mk('button', 'cv-x');
    close.type = 'button';
    close.setAttribute('aria-label', 'Close the legend');
    close.innerHTML = MARK.close;
    close.addEventListener('click', () => this.showLegend(false));
    head.append(close);
    box.append(head);
    const line = (state, word) => {
      const item = mk('span', 'cv-legend-item');
      const sw = mk('span', 'cv-legend-line');
      sw.dataset.state = state;
      item.append(sw, mk('span', null, word));
      return item;
    };
    const rows = mk('div', 'cv-legend-grid');
    rows.append(line('live', 'working now'), line('waiting', 'needs you'), line('done', 'finished'), line('failed', 'failed'));
    box.append(rows);
    const marks = mk('div', 'cv-legend-grid');
    this.legendBuiltin = mk('span', 'cv-tile cv-tile-sm');
    const crew = mk('span', 'cv-tile cv-tile-sm');
    crew.innerHTML = MARK.kit;
    const a = mk('span', 'cv-legend-item');
    a.append(this.legendBuiltin, mk('span', null, 'Claude Code built-in'));
    const b = mk('span', 'cv-legend-item');
    b.append(crew, mk('span', null, 'Crewforth'));
    marks.append(a, b);
    box.append(marks);
    box.hidden = readFlag('crewforth-studio-legend') === 'closed';
    return box;
  }

  showLegend(on) {
    this.legendEl.hidden = !on;
    writeFlag('crewforth-studio-legend', on ? 'open' : 'closed');
  }

  /* ------------------------------------------------------------ input */

  #wire() {
    let panning = null;

    this.root.addEventListener('pointerdown', (e) => {
      if (e.button !== 0) return;                 // right/middle must not pan
      const t = e.target;
      if (t.closest?.('.cv-node') || t.closest?.('.cv-minimap') || t.closest?.('.cv-legend')) return;   // the summary box is a .cv-legend too
      panning = { px: e.clientX, py: e.clientY, x: this.view.x, y: this.view.y };
      this.root.setPointerCapture(e.pointerId);
      this.root.classList.add('cv-panning');
    });

    this.root.addEventListener('pointermove', (e) => {
      if (!panning) return;
      this.view.x = panning.x + (e.clientX - panning.px);
      this.view.y = panning.y + (e.clientY - panning.py);
      this.touched = true;
      this.applyView();
    });

    const endPan = () => { panning = null; this.root.classList.remove('cv-panning'); };
    this.root.addEventListener('pointerup', endPan);
    this.root.addEventListener('pointercancel', endPan);

    this.root.addEventListener('wheel', (e) => {
      e.preventDefault();
      const r = this.root.getBoundingClientRect();
      const mx = e.clientX - r.left;
      const my = e.clientY - r.top;

      // deltaMode 1 is lines and 2 is pages; Firefox reports ~3 where Chrome reports ~100, which made zoom
      // imperceptible and pan crawl.
      const unit = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? r.height : 1;
      const dY = e.deltaY * unit;
      const dX = e.deltaX * unit;

      if (e.ctrlKey || e.metaKey || Math.abs(dY) > Math.abs(dX)) {
        this.#zoomAbout(this.view.k * Math.exp(-dY * 0.0016), mx, my);
      } else {
        this.view.x -= dX;
        this.view.y -= dY;
      }
      this.touched = true;
      this.applyView();
    }, { passive: false });

    // The minimap's frame is the pane: put the pointer somewhere on the map and the pane goes there.
    let mapping = false;
    const mapTo = (e) => {
      const p = this.lastPlan;
      if (!p) return;
      const r = this.mapEl.getBoundingClientRect();
      const s = this.#mapScale(p);
      const wx = (e.clientX - r.left) / s;
      const wy = (e.clientY - r.top) / s;
      const pane = this.root.getBoundingClientRect();
      this.view.x = pane.width / 2 - wx * this.view.k;
      this.view.y = pane.height / 2 - wy * this.view.k;
      this.touched = true;
      this.applyView();
    };
    this.mapEl.addEventListener('pointerdown', (e) => { mapping = true; this.mapEl.setPointerCapture(e.pointerId); mapTo(e); });
    this.mapEl.addEventListener('pointermove', (e) => { if (mapping) mapTo(e); });
    this.mapEl.addEventListener('pointerup', () => { mapping = false; });
    this.mapEl.addEventListener('pointercancel', () => { mapping = false; });
  }

  /** Zoom to `k`, keeping the world point under (mx, my) where it is. */
  #zoomAbout(k, mx, my) {
    const next = clamp(k, ZOOM.min, ZOOM.max);
    this.view.x = mx - (mx - this.view.x) * (next / this.view.k);
    this.view.y = my - (my - this.view.y) * (next / this.view.k);
    this.view.k = next;
  }

  /** Step the zoom from the toolbar: about the middle of the pane. */
  zoomBy(factor) {
    const r = this.root.getBoundingClientRect();
    this.#zoomAbout(this.view.k * factor, r.width / 2, r.height / 2);
    this.touched = true;
    this.applyView();
  }

  zoomTo(k) {
    const r = this.root.getBoundingClientRect();
    this.#zoomAbout(k, r.width / 2, r.height / 2);
    this.touched = true;
    this.applyView();
  }

  /**
   * Turn `view` into pixels. Public because it is the single place that does so — the wheel, the pan, fit() and
   * the toolbar all come through here, and so does anything that wants to drive the view without a pointer.
   *
   * It writes one transform. Nothing a card draws depends on the zoom, so a zoom restyles nothing: that was the
   * cost of the old counter-scaled labels, 454 ms of style work per second at 250 nodes.
   */
  applyView() {
    const { x, y, k } = this.view;
    this.viewport.style.transform = `translate(${x}px, ${y}px) scale(${k})`;
    this.#mapView();
    this.onChange(this.state());
  }

  /** What the toolbar shows. */
  state() {
    return {
      zoom: this.view.k,
      group: this.group,
      density: this.density,
      drawnAs: this.lastPlan?.density ?? null,
      stacked: Boolean(this.lastPlan?.stacked),
      drawn: this.drawn,
      focus: this.focusId ? (this.nodes.get(this.focusId)?.agentType ?? this.focusId) : null,
      groups: (this.lastPlan?.items ?? []).filter((it) => it.kind === 'group').length,
    };
  }

  /* ---------------------------------------------------------- choices */

  setPalette(p) { if (p?.map) { this.palette = p; this.#redraw(); } }

  /** The marks that live in files. `builtin` is the markup of web/icons/builtin.svg. */
  setIcons(icons) {
    this.icons = { ...this.icons, ...icons };
    if (this.legendBuiltin && this.icons.builtin) this.legendBuiltin.innerHTML = this.icons.builtin;
    for (const el of this.els.values()) el.sig = null;
    for (const el of this.cellEls.values()) el.sig = null;
    this.#redraw();
  }

  setGroup(group) {
    if (!GROUPINGS.includes(group) || group === this.group) return;
    this.group = group;
    // Positions set by hand and folds chosen for one grouping say nothing about another.
    this.pinned.clear();
    this.open.clear();
    this.sessionY = null;
    this.#crowdFold();
    this.#persist();
    this.#redraw({ fit: true });
  }

  setDensity(density) {
    if (!DENSITIES.includes(density) || density === this.density) return;
    this.density = density;
    writeFlag('crewforth-studio-density', density);
    this.sessionY = null;
    this.#redraw({ fit: true });
  }

  /** Show some statuses and step the rest back. `null` shows everything.
   *
   *  Stepped back, not removed: the graph keeps its shape, so a card the viewer was looking at is where it was
   *  when the filter comes off. Only agents have the statuses the summary counts, so the session and the groups
   *  stay lit as the frame the agents hang from. */
  setFilter(statuses, { keepWaiting = false } = {}) {
    this.filter = statuses == null ? null : new Set(typeof statuses === 'string' ? [statuses] : statuses);
    this.filterKeepsWaiting = keepWaiting;
    this.#redraw();
  }

  dimmed(n) {
    if (!this.filter || n?.kind !== 'agent') return false;
    if (this.filterKeepsWaiting && this.waiting.has(n.id)) return false;
    return !this.filter.has(n.status);
  }

  /** Agents parked on an approval. The graph has no such status of its own; the page knows it. */
  setWaiting(ids) {
    this.waiting = new Set(ids ?? []);
    this.#redraw();
  }

  setSessionState(state) {
    this.sessionState = state ?? null;
    this.#redraw();
  }

  /** The same mark a card carries, for a surface outside the canvas: one answer to "whose agent is this". */
  tileFor(n) {
    const tile = mk('span', 'cv-tile');
    if (n?.kind === 'agent') this.#fillTile(tile, n);
    else tile.innerHTML = MARK.session;
    return tile;
  }

  /** The word and tone a node's status is drawn in on its card. */
  statusOf(n) {
    if (n?.kind === 'session') return this.sessionState ?? { word: null, tone: null, known: false };
    return this.#statusOf(n);
  }

  expandAll() {
    for (const it of this.lastPlan?.items ?? []) if (it.kind === 'group') this.open.set(it.id, true);
    // Opening one level can reveal groups inside it; open those too.
    for (let i = 0; i < 4; i += 1) {
      const p = this.#plan();
      let more = false;
      for (const it of p.items) if (it.kind === 'group' && !it.open) { this.open.set(it.id, true); more = true; }
      if (!more) break;
    }
    this.sessionY = null;
    this.#persist();
    this.#redraw({ fit: true });
  }

  foldAll() {
    for (const it of this.lastPlan?.items ?? []) if (it.kind === 'group') this.open.set(it.id, false);
    this.sessionY = null;
    this.#persist();
    this.#redraw({ fit: true });
  }

  /** Show only one agent's branch: what led to it and what it spawned. `null` shows everything again. */
  setFocus(id) {
    this.focusId = id && this.nodes.has(id) ? id : null;
    this.sessionY = null;
    this.#redraw({ fit: true });
  }

  /** Forget every hand-placed card and lay the graph out again. */
  resetLayout() {
    this.pinned.clear();
    this.sessionY = null;
    this.touched = false;
    this.#persist();
    this.#redraw({ fit: true });
  }

  /* ----------------------------------------------------------- layout */

  #crowdFold() {
    const nodes = this.#visibleNodes();
    for (const id of crowdFolds(nodes, { group: this.group, density: this.density, seq: this.seq })) {
      if (!this.open.has(id)) this.open.set(id, false);
    }
  }

  #visibleNodes() {
    const all = [...this.nodes.values()];
    if (!this.focusId) return all;
    const keep = new Set();
    for (let cur = this.nodes.get(this.focusId), guard = 0; cur && guard < 32; cur = this.nodes.get(cur.parentId), guard += 1) keep.add(cur.id);
    const down = (id) => { for (const n of all) if (n.parentId === id && !keep.has(n.id)) { keep.add(n.id); down(n.id); } };
    down(this.focusId);
    for (const n of all) if (n.kind === 'session') keep.add(n.id);
    return all.filter((n) => keep.has(n.id));
  }

  #plan() {
    return plan(this.#visibleNodes(), {
      group: this.group, density: this.density, seq: this.seq, open: this.open, pinned: this.pinned, sessionY: this.sessionY,
    });
  }

  /** Re-fit only while the view is still the canvas's own. Once the viewer has panned, zoomed or placed a card,
   *  moving the view under them is not helpful. */
  fitIfUntouched() {
    if (!this.touched && !this.pinned.size) this.fit();
  }

  fit() {
    const p = this.lastPlan;
    if (!p || !p.items.length) return;
    const r = this.root.getBoundingClientRect();
    const k = fitZoom(p.width, p.height, r.width, r.height);
    this.view.k = k;
    this.view.x = Math.max(ZOOM.pad, (r.width - p.width * k) / 2);
    this.view.y = Math.max(ZOOM.pad, (r.height - p.height * k) / 2);
    this.touched = false;
    this.applyView();
  }

  /* -------------------------------------------------------- rendering */

  setSession(sessionId) {
    if (this.sessionKey === sessionId) return;
    this.sessionKey = sessionId;
    this.nodes.clear(); this.pos.clear(); this.pinned.clear(); this.open.clear(); this.seq.clear();
    this.els.clear(); this.cellEls.clear(); this.nodeLayer.replaceChildren(); this.edgeG.replaceChildren();
    this.edgeEls.clear(); this.newborn.clear();
    this.mapRects.clear(); this.mapBoxes.replaceChildren();
    this.selected = null;
    this.focusId = null;
    this.lastGraph = null;
    this.lastPlan = null;
    this.sessionY = null;
    this.sessionState = null;
    this.waiting = new Set();
    this.firstRender = true;
    this.touched = false;
    this.group = 'run';
    this.#restore();
  }

  render(graph) {
    this.lastGraph = graph;
    if (!graph?.nodes?.length) {
      this.emptyEl.hidden = false;
      this.emptyEl.replaceChildren(mk('strong', null, 'No agents yet'),
        mk('div', null, 'This session has not delegated to a subagent. The moment it does, a card appears here.'));
      // els must go with the DOM. Leaving stale elements behind made the next render believe they were still
      // mounted, so cards never returned.
      this.nodeLayer.replaceChildren(); this.edgeG.replaceChildren();
      this.nodes.clear(); this.els.clear(); this.cellEls.clear(); this.pos.clear();
      this.edgeEls.clear(); this.newborn.clear(); this.seq.clear();
      this.mapRects.clear(); this.mapBoxes.replaceChildren();
      this.selected = null;
      this.drawn = 0;
      this.lastPlan = null;
      this.mapEl.hidden = true;
      this.onSelect(null);
      this.applyView();
      return;
    }
    this.emptyEl.hidden = true;

    const seen = new Set();
    let born = false;
    for (const n of graph.nodes) {
      seen.add(n.id);
      if (!this.nodes.has(n.id)) { born = true; this.newborn.add(n.id); }
      this.nodes.set(n.id, n);
    }
    for (const id of [...this.nodes.keys()]) {
      if (seen.has(id)) continue;
      this.nodes.delete(id);
      this.pinned.delete(id);
      // The inspector must not keep describing a node that is gone.
      if (this.selected === id) { this.selected = null; this.onSelect(null); }
      if (this.focusId === id) this.focusId = null;
    }
    sequence(graph.nodes, this.seq);

    if (this.firstRender) this.#crowdFold();
    // Fit once when a session opens, so the graph is never half off-screen. After that the view is the
    // viewer's: re-fitting under them as agents appear would yank the canvas mid-read.
    this.#redraw({ fit: this.firstRender || (born && !this.touched && !this.pinned.size) });
    this.firstRender = false;
  }

  /** Lay out and draw whatever is known now. */
  #redraw({ fit = false } = {}) {
    if (!this.nodes.size) return;
    const p = this.#plan();
    this.lastPlan = p;
    this.sessionY = p.sessionY;
    this.drawn = p.drawn;
    this.root.dataset.density = p.density;

    const live = new Set();
    const liveCells = new Set();
    this.pos.clear();
    for (const it of p.items) {
      live.add(it.id);
      this.pos.set(it.id, { x: it.x, y: it.y });
      this.#drawItem(it, liveCells);
    }
    for (const [id, el] of this.els) if (!live.has(id)) { el.remove(); this.els.delete(id); }
    for (const [id, el] of this.cellEls) if (!liveCells.has(id)) { el.remove(); this.cellEls.delete(id); }

    this.#drawEdges(p);
    this.#drawMap(p);
    if (fit) this.fit(); else this.applyView();
  }

  /** The card's position and size, and whatever only changes with them. */
  #place(el, it) {
    const box = `${it.x},${it.y},${it.w},${it.h}`;
    if (el.box === box) return;
    el.box = box;
    el.style.transform = `translate(${it.x}px, ${it.y}px)`;
    el.style.width = `${it.w}px`;
    el.style.height = `${it.h}px`;
  }

  #drawItem(it, liveCells) {
    let el = this.els.get(it.id);
    const shape = it.kind === 'group' ? `group:${it.open ? `open:${it.grid ? 'grid' : 'rows'}` : 'folded'}`
      : `${it.kind}:${it.compact ? 'chip' : 'card'}`;
    // A card that changes what it IS (an agent that becomes a chip, a group that opens) is rebuilt; one that only
    // changes what it says is updated in place.
    if (el && el.shape !== shape) {
      el.remove();
      this.els.delete(it.id);
      if (it.kind === 'group') for (const m of it.members) { this.cellEls.get(m.id)?.remove(); this.cellEls.delete(m.id); }
      el = null;
    }
    if (!el) {
      el = mk('div', 'cv-node');
      el.shape = shape;
      el.dataset.id = it.id;
      el.dataset.kind = it.kind === 'run-card' ? 'run' : it.kind;
      el.tabIndex = 0;
      this.#skeleton(el, it);
      this.nodeLayer.append(el);
      this.els.set(it.id, el);
      this.#interact(el, it.id);
      // Birth, only for nodes that actually just appeared.
      if (this.newborn.has(it.id) && !this.firstRender) {
        el.classList.add('cv-born');
        requestAnimationFrame(() => requestAnimationFrame(() => el.classList.remove('cv-born')));
      }
    }
    this.#place(el, it);
    el.classList.toggle('cv-selected', this.selected === it.id);
    el.classList.toggle('cv-pinned', Boolean(it.pinned));
    if (it.kind === 'session') this.#fillSession(el, it);
    else if (it.kind === 'group') this.#fillGroup(el, it, liveCells);
    else this.#fillAgent(el, it.node, it.compact);
  }

  /** The skeleton of a card: the parts it will fill. */
  #skeleton(el, it) {
    const p = {};
    if (it.kind === 'session') {
      el.classList.add('cv-session');
      p.tile = mk('span', 'cv-tile');
      p.tile.innerHTML = MARK.session;
      p.pill = this.#pill();
      const row = mk('div', 'cv-row');
      row.append(p.tile, mk('span', 'cv-title', 'Session'), mk('span', 'cv-fill'), p.pill.el);
      p.name = mk('div', 'cv-name cv-indent');
      p.sub = mk('div', 'cv-sub cv-indent');
      el.append(row, p.name, p.sub);
    } else if (it.kind === 'group') {
      el.classList.add('cv-group');
      p.tile = mk('span', 'cv-tile');
      p.name = mk('span', 'cv-name');
      p.sub = mk('span', 'cv-sub');
      p.fold = mk('button', 'cv-fold');
      p.fold.type = 'button';
      p.head = mk('div', 'cv-row cv-group-head');
      p.head.append(p.tile, p.name, mk('span', 'cv-fill'), p.sub, p.fold);
      p.bar = mk('div', 'cv-bar');
      p.count = mk('span', 'cv-sub');
      if (it.open) {
        el.classList.add('cv-open');
        el.append(p.head, p.bar);
      } else {
        const row = mk('div', 'cv-row cv-indent');
        row.append(p.bar, p.count);
        el.append(p.head, row);
      }
      p.fold.addEventListener('click', (e) => { e.stopPropagation(); this.toggle(it.id); });
    } else if (it.compact) {
      el.classList.add('cv-chip');
      p.dot = mk('span', 'dot');
      p.name = mk('span', 'cv-name');
      p.task = mk('span', 'cv-task');
      p.word = mk('span', 'cv-word');
      el.append(p.dot, p.name, p.task, p.word);
    } else {
      p.tile = mk('span', 'cv-tile');
      p.name = mk('span', 'cv-name');
      p.pill = this.#pill();
      const row = mk('div', 'cv-row');
      row.append(p.tile, p.name, mk('span', 'cv-fill'), p.pill.el);
      p.task = mk('div', 'cv-task cv-indent');
      el.append(row, p.task);
    }
    el.parts = p;
  }

  #pill() {
    const el = mk('span', 'cv-pill');
    const dot = mk('span', 'dot');
    const word = mk('span', 'cv-pill-word');
    el.append(dot, word);
    return { el, dot, word };
  }

  /** The word and the colour an agent's status is drawn in. Waiting on the viewer outranks what the transcript
   *  says, because that is what the agent is doing now. */
  #statusOf(n) {
    if (this.waiting.has(n.id)) return { word: 'Needs you', tone: 'waiting', known: true, state: 'waiting' };
    const s = agentStatus(n.status);
    // A status this panel has no word for keeps its own, exactly as the transcript wrote it.
    return { word: s.known ? cap(s.word) : s.word, tone: s.tone, known: s.known, state: stateOf(n.status) };
  }

  /**
   * Whose agent this is. The palette says where a type was declared; a type it does not know is drawn as unknown
   * rather than guessed into one camp or the other, and a palette that could not be read makes every agent
   * unknown, with the reason.
   */
  #identity(n) {
    if (this.palette.measured === false) {
      return { source: 'unknown', title: `Agent identity not measured — ${this.palette.reason ?? 'no reason given'}` };
    }
    const source = this.palette.map?.[n.agentType]?.source ?? null;
    if (source === 'kit') return { source: 'kit', title: 'Crewforth agent' };
    if (source === 'builtin') return { source: 'builtin', title: 'Claude Code built-in agent' };
    return { source: 'unknown', title: 'Not declared by Crewforth or by Claude Code — an agent type this panel does not recognise' };
  }

  #fillTile(tile, n) {
    const who = this.#identity(n);
    const sig = `${who.source}|${who.title}|${this.icons.builtin ? 1 : 0}`;
    if (tile.sig === sig) return who;
    tile.sig = sig;
    tile.innerHTML = who.source === 'kit' ? MARK.kit : (this.icons.builtin ?? '');
    tile.dataset.source = who.source;
    tile.title = who.title;
    return who;
  }

  #fillSession(el, it) {
    const n = it.node;
    const st = this.sessionState;
    const bg = n.backgroundNow?.length ?? 0;
    const sig = JSON.stringify([n.gitBranch, n.cwd, n.turns, n.tokens, st?.word, st?.tone, bg]);
    if (el.sig === sig) return;
    el.sig = sig;
    const p = el.parts;
    el.dataset.state = 'root';
    p.pill.el.hidden = !st?.word;
    p.pill.dot.dataset.tone = st?.tone ?? 'none';
    p.pill.word.textContent = st?.word ?? '';
    p.name.textContent = n.gitBranch || shortPath(n.cwd) || n.sessionId || '';
    const bits = [`${n.turns ?? 0} ${n.turns === 1 ? 'turn' : 'turns'}`];
    if (n.tokens != null) bits.push(`${fmtTokens(n.tokens)} ctx`);
    // What the session has running that is not an agent: commands sent to the background.
    if (bg) bits.push(`${bg} in background`);
    p.sub.textContent = bits.join(' · ');
    p.sub.title = bg ? n.backgroundNow.map((c) => `In the background: ${c.toolName}${c.detail ? ` · ${c.detail}` : ''}`).join('\n') : '';
    el.title = 'Click to inspect this session';
    el.setAttribute('aria-label', `Session, ${st?.word ?? 'state not measured'}, ${p.name.textContent}, ${p.sub.textContent}`);
  }

  #fillAgent(el, n, compact) {
    const st = this.#statusOf(n);
    const who = compact ? this.#identity(n) : this.#fillTile(el.parts.tile, n);
    const type = n.kind === 'workflow' ? (n.workflowId ?? 'workflow run') : (n.agentType ?? 'unknown agent');
    const task = n.kind === 'workflow' ? `${n.members ?? 0} agents` : (n.description ?? '');
    const dim = this.dimmed(n);
    const sig = JSON.stringify([type, task, st.word, st.tone, st.state, who.source, dim, n.status]);
    if (el.sig === sig) return;
    el.sig = sig;
    const p = el.parts;
    el.dataset.status = n.status ?? 'unknown';
    // What motion and the frame say about this card, separated from the raw status so that `killed` and
    // `stopped` read like the failures they are instead of like two more words nothing has a rule for.
    el.dataset.state = st.state;
    el.dataset.source = who.source;
    el.classList.toggle('cv-dim', dim);
    p.name.textContent = type;
    p.task.textContent = task;
    if (compact) {
      p.dot.dataset.tone = st.tone ?? 'none';
      p.word.textContent = st.word;
    } else {
      p.pill.dot.dataset.tone = st.tone ?? 'none';
      p.pill.word.textContent = st.word;
      p.pill.el.classList.toggle('cv-unknown', !st.known);
    }
    // The card's whole name, whatever it is drawn as: a chip shows less than a card, and what it leaves out
    // still has to reach a screen reader.
    el.setAttribute('aria-label', `${type}, ${st.word}${task ? `, ${task}` : ''} (${who.title})`);
  }

  #fillGroup(el, it, liveCells) {
    const p = el.parts;
    const counts = it.counts;
    const says = Object.entries(counts).map(([s, c]) => `${c} ${agentStatus(s).word}`).join(' · ');
    const sig = JSON.stringify([it.label, says, it.open, it.type, it.status]);
    if (el.sig !== sig) {
      el.sig = sig;
      el.dataset.state = stateOf(it.status);
      el.dataset.status = it.status;
      el.dataset.group = it.type;
      el.dataset.open = String(Boolean(it.open));
      p.name.textContent = it.label;
      if (it.type === 'run') { p.tile.innerHTML = MARK.run; p.tile.title = 'Workflow run'; }
      else this.#fillTile(p.tile, it.type === 'type' ? { agentType: it.agentType } : (it.of ?? {}));
      p.sub.textContent = it.type === 'type' ? '' : `${it.members.length} ${it.members.length === 1 ? 'agent' : 'agents'}`;
      p.fold.innerHTML = it.open ? MARK.down : MARK.chevron;
      p.fold.setAttribute('aria-label', `${it.open ? 'Fold' : 'Open'} ${it.label}`);
      p.fold.setAttribute('aria-expanded', String(Boolean(it.open)));
      // The bar: how the group went, in the order the eye wants it.
      const order = ['done', 'running', 'starting', 'failed', 'killed', 'stopped', 'stale', 'ended'];
      const keys = Object.keys(counts).sort((a, b) => (order.indexOf(a) + 99) % 99 - (order.indexOf(b) + 99) % 99);
      p.bar.replaceChildren(...keys.map((s) => {
        const seg = mk('span');
        seg.style.flexGrow = String(counts[s]);
        seg.dataset.tone = agentStatus(s).tone ?? 'none';
        return seg;
      }));
      p.bar.title = says;
      if (!it.open) p.count.textContent = says;
      el.title = it.open ? '' : `Click to show ${it.members.length} agents`;
      el.setAttribute('aria-label', `${it.label}, ${says}, ${it.open ? 'open' : 'folded'}`);
    }
    if (!it.open) return;

    for (const cell of it.cells) {
      liveCells.add(cell.id);
      let c = this.cellEls.get(cell.id);
      const shape = it.grid ? 'chip' : 'row';
      if (c && (c.shape !== shape || c.host !== el)) { c.remove(); this.cellEls.delete(cell.id); c = null; }
      if (!c) {
        c = mk('div', `cv-member cv-member-${shape}`);
        c.shape = shape;
        c.host = el;
        c.dataset.id = cell.id;
        c.tabIndex = 0;
        const q = {};
        if (!it.grid) { q.tile = mk('span', 'cv-tile'); c.append(q.tile); } else { q.dot = mk('span', 'dot'); c.append(q.dot); }
        q.name = mk('span', 'cv-name');
        c.append(q.name);
        if (!it.grid) { c.append(mk('span', 'cv-fill')); q.dot = mk('span', 'dot'); c.append(q.dot); }
        q.word = mk('span', 'cv-word');
        c.append(q.word);
        c.parts = q;
        el.append(c);
        this.cellEls.set(cell.id, c);
        this.#interactCell(c, cell.id);
      }
      const box = `${cell.x},${cell.y},${cell.w},${cell.h}`;
      if (c.box !== box) {
        c.box = box;
        c.style.transform = `translate(${cell.x}px, ${cell.y}px)`;
        c.style.width = `${cell.w}px`;
        c.style.height = `${cell.h}px`;
      }
      const n = cell.node;
      const st = this.#statusOf(n);
      const who = it.grid ? this.#identity(n) : this.#fillTile(c.parts.tile, n);
      // Inside a group of one type the type is the group's name, so a member is told apart by its task.
      const text = it.type === 'type' ? (n.description || n.agentType || n.id) : (n.agentType ?? 'unknown agent');
      const dim = this.dimmed(n);
      const csig = JSON.stringify([text, st.word, st.tone, st.state, dim, this.selected === n.id]);
      if (c.sig === csig) continue;
      c.sig = csig;
      c.dataset.state = st.state;
      c.dataset.status = n.status ?? 'unknown';
      c.classList.toggle('cv-dim', dim);
      c.classList.toggle('cv-selected', this.selected === n.id);
      c.parts.name.textContent = text;
      c.parts.dot.dataset.tone = st.tone ?? 'none';
      c.parts.word.textContent = st.word;
      c.setAttribute('aria-label', `${n.agentType ?? 'unknown agent'}, ${st.word}${n.description ? `, ${n.description}` : ''} (${who.title})`);
    }
  }

  // Wires are kept and updated, never rebuilt.
  //
  // Replacing the whole layer each pass was the reason motion could not live here: a CSS animation restarts when
  // its element leaves the document, so a travelling dash jumped back to its start on every 2s poll and on every
  // frame of a drag. Reusing the path element is what lets the stylesheet own the animation and JS own nothing
  // but geometry.
  #drawEdges(p) {
    const alive = new Set();
    let moving = 0;
    const onPath = this.#pathTo(this.selected);

    for (const e of p.edges) {
      alive.add(e.key);
      let path = this.edgeEls.get(e.key);
      const fresh = !path;
      if (fresh) {
        path = document.createElementNS(SVG, 'path');
        path.setAttribute('class', 'cv-edge');
        this.edgeEls.set(e.key, path);
        this.edgeG.append(path);
      }

      // Out of the right edge of what spawned it, into the left edge of the card. The control points are pushed
      // along the flow so siblings fan out instead of stacking on one line.
      const { from, to } = e;
      const c = Math.max(24, Math.abs(to.x - from.x) * 0.55);
      const d = `M ${from.x} ${from.y} C ${from.x + c} ${from.y}, ${to.x - c} ${to.y}, ${to.x} ${to.y}`;
      if (path.d !== d) {
        path.d = d;
        path.setAttribute('d', d);
        // The draw-in has to cover the whole curve without measuring it — getTotalLength() forces a synchronous
        // layout, once per wire. A cubic is never longer than its control polygon, so that bound is computed
        // from the numbers already in hand and handed to CSS as a length.
        path.style.setProperty('--edge-len', `${Math.ceil(Math.hypot(to.x - from.x, to.y - from.y) + 2 * c)}px`);
      }

      const target = this.nodes.get(e.target);
      const waiting = target && this.waiting.has(target.id);
      const state = waiting ? 'waiting' : e.state;
      path.dataset.status = e.status;
      path.dataset.state = state;
      path.classList.toggle('cv-dim', Boolean(target) && this.dimmed(target));
      path.classList.toggle('cv-path', onPath.has(e.target));

      if (state === 'live' || state === 'waking') moving += 1;

      // Only a wire into a node that just arrived draws itself. Opening a group is not an arrival, so opening a
      // 105-agent run reveals it rather than performing it.
      if (fresh && this.newborn.has(e.target)) {
        path.classList.add('cv-drawing');
        setTimeout(() => path.classList.remove('cv-drawing'), DRAW_MS);
      }
    }

    for (const [key, path] of this.edgeEls) {
      if (alive.has(key)) continue;
      path.remove();
      this.edgeEls.delete(key);
    }
    this.newborn.clear();

    // Only travelling strokes are counted. The card pulse rides the same flag, but it animates opacity on a
    // pseudo-element and costs the compositor almost nothing, so charging a running agent twice — once for its
    // wire and once for its card — would halve the budget for no reason anyone measured.
    this.root.dataset.motion = moving > MOTION_BUDGET ? 'still' : 'flow';

    const w = Math.max(1, Math.ceil(p.width + 200));
    const h = Math.max(1, Math.ceil(p.height + 200));
    if (this.svg.box !== `${w},${h}`) {
      this.svg.box = `${w},${h}`;
      this.svg.setAttribute('viewBox', `0 0 ${w} ${h}`);
      this.svg.style.width = `${w}px`;
      this.svg.style.height = `${h}px`;
    }
  }

  /** The drawn items on the way from the session to `id`, `id` included. */
  #pathTo(id) {
    const out = new Set();
    if (!id) return out;
    const byId = new Map((this.lastPlan?.items ?? []).map((it) => [it.id, it]));
    let cur = byId.get(id);
    if (!cur) {
      // A member inside an open group: the wire that leads to it is the one into its group.
      cur = (this.lastPlan?.items ?? []).find((it) => it.kind === 'group' && it.members.some((m) => m.id === id)) ?? null;
    }
    for (let guard = 0; cur && guard < 32; guard += 1) { out.add(cur.id); cur = cur.parent ? byId.get(cur.parent.id) : null; }
    return out;
  }

  /* ---------------------------------------------------------- minimap */

  #mapScale(p) { return Math.min(200 / Math.max(1, p.width), 88 / Math.max(1, p.height)); }

  #drawMap(p) {
    // A graph that is all one box needs no map of itself.
    this.mapEl.hidden = p.items.length < 2;
    const s = this.#mapScale(p);
    const live = new Set();
    for (const it of p.items) {
      live.add(it.id);
      // Kept and moved, like the wires: a map rebuilt on every poll is 250 elements made and thrown away.
      let r = this.mapRects.get(it.id);
      if (!r) {
        r = document.createElementNS(SVG, 'rect');
        r.setAttribute('class', 'cv-map-box');
        r.setAttribute('rx', '1.5');
        this.mapRects.set(it.id, r);
        this.mapBoxes.append(r);
      }
      // What needs someone stays findable at any zoom: its box keeps its colour here.
      const members = it.kind === 'group' ? it.members : (it.node ? [it.node] : []);
      const tone = members.some((m) => this.waiting.has(m.id)) ? 'waiting'
        : members.some((m) => stateOf(m.status) === 'failed') ? 'fail'
          : (it.id === this.selected || members.some((m) => m.id === this.selected)) ? 'selected' : 'none';
      const sig = `${(it.x * s).toFixed(1)},${(it.y * s).toFixed(1)},${Math.max(2, it.w * s).toFixed(1)},${Math.max(2, it.h * s).toFixed(1)},${tone}`;
      if (r.sig === sig) continue;
      r.sig = sig;
      const [x, y, w, h] = sig.split(',');
      r.setAttribute('x', x);
      r.setAttribute('y', y);
      r.setAttribute('width', w);
      r.setAttribute('height', h);
      r.dataset.tone = tone;
    }
    for (const [id, r] of this.mapRects) if (!live.has(id)) { r.remove(); this.mapRects.delete(id); }
    if (!this.mapSvg.sized) {
      this.mapSvg.sized = true;
      this.mapSvg.setAttribute('width', '200');
      this.mapSvg.setAttribute('height', '88');
    }
  }

    #mapView() {
    const p = this.lastPlan;
    if (!p || !this.mapFrame) return;
    const s = this.#mapScale(p);
    const r = this.root.getBoundingClientRect();
    const { x, y, k } = this.view;
    const fx = clamp((-x / k) * s, 0, 200);
    const fy = clamp((-y / k) * s, 0, 88);
    this.mapFrame.setAttribute('x', fx.toFixed(1));
    this.mapFrame.setAttribute('y', fy.toFixed(1));
    this.mapFrame.setAttribute('width', clamp((r.width / k) * s, 4, 200 - fx).toFixed(1));
    this.mapFrame.setAttribute('height', clamp((r.height / k) * s, 4, 88 - fy).toFixed(1));
  }

  /* -------------------------------------------------------- selection */

  /** Fold or open one group. */
  toggle(groupId) {
    const it = this.lastPlan?.items.find((x) => x.id === groupId);
    if (!it || it.kind !== 'group') return;
    this.open.set(groupId, !it.open);
    this.sessionY = null;
    this.#persist();
    this.#redraw();
  }

  /** Drop the selection without pretending a card was clicked. */
  clearSelection() {
    this.selected = null;
    this.#redraw();
  }

  #select(id) {
    this.selected = this.selected === id ? null : id;
    this.#redraw();
    this.onSelect(this.selected ? this.nodes.get(this.selected) ?? null : null);
  }

  /**
   * Bring one agent in front of the viewer: open the group it is folded into, put it in the middle of the pane at
   * a size it can be read at, and select it. This is what an attention chip does.
   */
  focus(id) {
    if (!this.nodes.has(id)) return false;
    for (let i = 0; i < 4; i += 1) {
      const p = this.lastPlan ?? this.#plan();
      if (p.items.some((it) => it.id === id) || p.items.some((it) => it.kind === 'group' && it.open && it.members.some((m) => m.id === id))) break;
      // Not drawn: something it sits under is folded. Open the nearest folded group above it.
      const chain = [];
      for (let cur = this.nodes.get(id), g = 0; cur && g < 32; cur = this.nodes.get(cur.parentId), g += 1) chain.push(cur.id);
      const holder = p.items.find((it) => it.kind === 'group' && !it.open && it.members.some((m) => chain.includes(m.id)));
      if (!holder) break;
      this.open.set(holder.id, true);
      this.sessionY = null;
      this.lastPlan = this.#plan();
    }
    this.selected = id;
    this.#redraw();
    const p = this.lastPlan;
    const item = p.items.find((it) => it.id === id);
    const host = item ?? p.items.find((it) => it.kind === 'group' && it.members.some((m) => m.id === id));
    if (host) {
      const cell = item ? null : host.cells?.find((c) => c.id === id);
      const cx = host.x + (cell ? cell.x + cell.w / 2 : host.w / 2);
      const cy = host.y + (cell ? cell.y + cell.h / 2 : host.h / 2);
      const r = this.root.getBoundingClientRect();
      // Close enough to read, and no closer than the viewer already was.
      this.view.k = clamp(Math.max(this.view.k, 1), ZOOM.min, ZOOM.max);
      this.view.x = r.width / 2 - cx * this.view.k;
      this.view.y = r.height / 2 - cy * this.view.k;
      this.touched = true;
      this.applyView();
    }
    this.#persist();
    this.onSelect(this.nodes.get(id) ?? null);
    return true;
  }

  /** Select a node without moving the view: for a choice made where the canvas is not on screen. */
  select(id) {
    if (!this.nodes.has(id)) return false;
    this.selected = id;
    this.#redraw();
    this.onSelect(this.nodes.get(id) ?? null);
    return true;
  }

  /* ------------------------------------------------------ interaction */

  #interact(el, id) {
    let drag = null;

    el.addEventListener('pointerdown', (e) => {
      if (e.button !== 0) return;
      e.stopPropagation();                       // do not pan the canvas too
      if (e.target.closest?.('.cv-fold')) return;
      const p = this.pos.get(id) ?? { x: 0, y: 0 };
      drag = { px: e.clientX, py: e.clientY, x: p.x, y: p.y, moved: false };
      el.setPointerCapture(e.pointerId);
    });

    el.addEventListener('pointermove', (e) => {
      if (!drag) return;
      const dx = (e.clientX - drag.px) / this.view.k;
      const dy = (e.clientY - drag.py) / this.view.k;
      if (!drag.moved && Math.abs(dx) <= 3 && Math.abs(dy) <= 3) return;
      drag.moved = true;
      el.classList.add('cv-dragging');
      this.pinned.set(id, { x: Math.round(drag.x + dx), y: Math.round(drag.y + dy) });
      this.#redraw();
    });

    const stop = () => {
      if (!drag) return;
      // A drag ends with a click on the same element. Without this guard every reposition also toggled selection.
      if (drag.moved) { this.#persist(); el.dataset.suppressClick = '1'; }
      drag = null;
      el.classList.remove('cv-dragging');
    };
    el.addEventListener('pointerup', stop);
    el.addEventListener('pointercancel', stop);

    const act = () => {
      const it = this.lastPlan?.items.find((x) => x.id === id);
      if (!it) return;
      // A group opens on click — the fold control is a small target and the card is the obvious one. The session
      // is not a group even though everything hangs off it: it is the conversation, and clicking it opens that.
      if (it.kind === 'group') { this.toggle(id); return; }
      this.#select(id);
    };
    el.addEventListener('click', (e) => {
      if (el.dataset.suppressClick === '1') { el.dataset.suppressClick = '0'; return; }
      if (e.target.closest?.('.cv-member')) return;   // the member answers for itself
      act();
    });
    el.addEventListener('keydown', (e) => {
      if (e.target !== el) return;
      if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); act(); }
    });
    el.addEventListener('contextmenu', (e) => {
      if (e.target.closest?.('.cv-member')) return;
      e.preventDefault();
      this.onMenu(this.nodes.get(id) ?? null, { x: e.clientX, y: e.clientY, pinned: this.pinned.size > 0 });
    });
    this.#tip(el, () => this.nodes.get(id));
  }

  #interactCell(c, id) {
    c.addEventListener('pointerdown', (e) => e.stopPropagation());
    c.addEventListener('click', (e) => { e.stopPropagation(); this.#select(id); });
    c.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); this.#select(id); } });
    c.addEventListener('contextmenu', (e) => {
      e.preventDefault();
      e.stopPropagation();
      this.onMenu(this.nodes.get(id) ?? null, { x: e.clientX, y: e.clientY, pinned: this.pinned.size > 0 });
    });
    this.#tip(c, () => this.nodes.get(id));
  }

  /** The whole task and the numbers, after the pointer has rested on a card. */
  #tip(el, nodeOf) {
    let timer = null;
    const hide = () => { clearTimeout(timer); timer = null; this.tipEl.hidden = true; };
    el.addEventListener('pointerenter', (e) => {
      const n = nodeOf();
      if (!n || n.kind !== 'agent' || e.target !== el) return;
      clearTimeout(timer);
      timer = setTimeout(() => {
        const bits = [];
        // What it is doing this moment, for an agent that is doing something.
        if (n.status === 'running' && n.lastTool) bits.push(`\u25b8 ${n.lastTool}`);
        if (n.durationMs != null) bits.push(fmtDuration(n.durationMs));
        if (n.toolCount) bits.push(`${n.toolCount} ${n.toolCount === 1 ? 'call' : 'calls'}`);
        if (n.tokens != null) bits.push(`${fmtTokens(n.tokens)} tokens`);
        if (n.errors) bits.push(`${n.errors} ${n.errors === 1 ? 'error' : 'errors'}`);
        this.tipEl.replaceChildren(
          mk('strong', null, n.agentType ?? 'unknown agent'),
          mk('div', null, n.description || 'No task recorded'),
          mk('div', 'cv-sub', bits.length ? bits.join(' · ') : 'No numbers yet'),
        );
        const host = this.root.getBoundingClientRect();
        const r = el.getBoundingClientRect();
        this.tipEl.hidden = false;
        this.tipEl.style.left = `${clamp(r.left - host.left, 8, Math.max(8, host.width - 300))}px`;
        this.tipEl.style.top = `${clamp(r.bottom - host.top + 6, 8, Math.max(8, host.height - 96))}px`;
      }, TIP_MS);
    });
    el.addEventListener('pointerleave', hide);
    el.addEventListener('pointerdown', hide);
  }

  /* -------------------------------------------------------- persistence
     Hand-placed positions, folds and the grouping are the viewer's work and outlive a refresh. Storage can be
     unavailable (private windows, blocked site data), so every access is guarded and the canvas falls back to
     its own layout. */

  #key() { return `crewforth-studio-graph:${this.sessionKey}`; }

  #persist() {
    if (!this.sessionKey) return;   // no session, nothing to key the layout to
    try {
      localStorage.setItem(this.#key(), JSON.stringify({
        group: this.group,
        pins: Object.fromEntries([...this.pinned].map(([id, p]) => [id, [p.x, p.y]])),
        open: Object.fromEntries(this.open),
      }));
    } catch { /* kept for this page view only */ }
  }

  #restore() {
    if (!this.sessionKey) return;
    try {
      const raw = localStorage.getItem(this.#key());
      if (!raw) return;
      const saved = JSON.parse(raw);
      if (GROUPINGS.includes(saved.group)) this.group = saved.group;
      for (const [id, [x, y]] of Object.entries(saved.pins ?? {})) this.pinned.set(id, { x, y });
      for (const [id, on] of Object.entries(saved.open ?? {})) this.open.set(id, Boolean(on));
    } catch { /* start from the canvas's own layout */ }
  }
}

/* -------------------------------------------------------------- helpers */

function readFlag(key) {
  try { return localStorage.getItem(key); } catch { return null; }
}

function writeFlag(key, value) {
  try { localStorage.setItem(key, value); } catch { /* blocked storage */ }
}

function readPref(key, allowed, fallback) {
  const v = readFlag(key);
  return allowed.includes(v) ? v : fallback;
}

function fmtTokens(t) {
  if (t == null) return '';
  if (t < 1000) return `${t}`;
  if (t < 1_000_000) return `${(t / 1000).toFixed(t < 10_000 ? 1 : 0)}k`;
  return `${(t / 1_000_000).toFixed(2)}M`;
}

function fmtDuration(ms) {
  const s = Math.round(ms / 1000);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  return m < 60 ? `${m}m ${s % 60}s` : `${Math.floor(m / 60)}h ${m % 60}m`;
}

function shortPath(p, max = 28) {
  if (!p) return '';
  const home = p.match(/^\/(Users|home)\/[^/]+/);
  const s = home ? `~${p.slice(home[0].length)}` : p;
  if (s.length <= max) return s;
  const keep = Math.floor((max - 1) / 2);
  return `${s.slice(0, keep)}…${s.slice(-keep)}`;
}
