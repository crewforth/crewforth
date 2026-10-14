// The Map view: the project as Crewforth's crew map shows it.
//
// Bands from the clients down to the external resources, on a pane that pans and zooms like the graph's (the
// shared viewport.js). Lines are solid where a file proves them, dotted where they are inferred, dashed with their
// own mark where the model proposed them. A card can be placed by hand and stays placed for that project; modules
// that share a folder can be folded into one card. Under the pane, the findings; beside it, the inspector. On a
// phone the pane gives way to the findings and a list of the modules. It reads the map the server sends and writes
// nothing; what leaves the page is copied text: a finding as a task, or a file:line.
import {
  nodesOf, edgesOf, edgeKey, litEdges, findingsOf, findingCounts, cardSub, summaryOf, sourceOf, inspectOf, taskOf,
  emptyNote, layoutOf, pathOf, chipsOf, resourceWord, inferredOnly, groupsOf, foldView, placed, BANDS,
} from './map-plan.js';
import { Viewport, draggable, swallowClick } from './viewport.js';

const SVG = 'http://www.w3.org/2000/svg';
export const LAYOUT_KEY = 'crewforth-studio-map-layout:';

function mk(tag, cls, text) {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text != null) n.textContent = text;
  return n;
}
function svg(tag, attrs = {}) {
  const n = document.createElementNS(SVG, tag);
  for (const [k, v] of Object.entries(attrs)) n.setAttribute(k, String(v));
  return n;
}
const BAND_ORDER = Object.fromEntries(BANDS.map(([k], i) => [k, i]));
const BAND_WORD = Object.fromEntries(BANDS);

const LAYERS = [['modules', 'Modules'], ['external', 'External'], ['endpoints', 'Endpoints'], ['findings', 'Findings']];

export class MapView {
  /**
   * @param hooks.onCopy(text, what)  put text on the clipboard; `what` ('task' or 'path') is for the page's toast
   * @param hooks.onCompare(cwd)      read the map again, compared with that project's (null: with none)
   * @param hooks.onZoom(k)           the pane's zoom changed
   */
  constructor(root, hooks = {}) {
    this.root = root;
    this.hooks = hooks;
    this.data = null;
    this.layers = { modules: true, external: true, endpoints: false, findings: true };
    this.showHidden = false;
    this.selected = null;
    this.tab = 'overview';
    this.legendOpen = false;
    this.pins = {};
    this.folded = new Set();
    this.groupOf = {};
    this.lay = null;
    this.fitted = false;
    this.root.classList.add('mp');
    this.#build();
  }

  /** The parts that live as long as the view: the pane and the layer it moves keep the zoom across redraws. */
  #build() {
    this.top = mk('div', 'mp-top');
    this.pane = mk('div', 'mp-canvas-pane');
    this.layer = mk('div', 'mp-canvas');
    this.pane.append(this.layer);
    this.vp = new Viewport(this.pane, this.layer, {
      skip: (t) => Boolean(t.closest?.('.mp-card') || t.closest?.('.mp-group-fold')),
      onApply: () => this.hooks.onZoom?.(this.vp.view.k),
    });
    this.below = mk('div', 'mp-below');
    this.list = mk('section', 'mp-modlist');
    this.list.setAttribute('aria-label', 'Modules');
    this.side = mk('aside', 'mp-inspect');
    this.side.setAttribute('aria-label', 'Selected node');
    const main = mk('div', 'mp-main');
    main.append(this.pane, this.below, this.list);
    this.body = mk('div', 'mp-body');
    this.body.append(main, this.side);
    this.frame = mk('section', 'mp-pane');
    this.frame.append(this.top, this.body);
    this.empty = mk('div', 'mp-empty');
    // The pane has no size until it is on screen, so the first Fit is done again when it gets one, and whenever it
    // changes size while the viewer has not moved the view or placed a card: the graph does the same.
    if (typeof ResizeObserver !== 'undefined') {
      new ResizeObserver(() => { if (this.lay && !this.vp.touched && !this.moved) { this.layWidth = null; this.render(); this.fit(); } }).observe(this.pane);
    }
    // A press anywhere outside the open legend closes it, as the design says: a popover, not a window.
    document.addEventListener?.('pointerdown', (e) => {
      if (this.legendOpen && !e.target?.closest?.('.mp-legend')) { this.legendOpen = false; this.render(); }
    });
  }

  setData(data) {
    if (data?.cwd !== this.data?.cwd) {
      this.selected = null; this.tab = 'overview'; this.fitted = false; this.layWidth = null;
      this.#restore(data?.cwd);
    }
    this.data = data;
    this.render();
  }

  /** Select a node; with `reveal`, bring its card to the middle of the pane. */
  select(id, { reveal = false } = {}) {
    const drawn = id ? (this.lay?.pos[id] ? id : this.groupOf[id] ?? id) : null;
    this.selected = id; this.tab = 'overview';
    this.render();
    const p = drawn ? this.lay?.pos[drawn] : null;
    if (reveal && p) this.vp.centerOn(p.x + p.w / 2, p.y + p.h / 2, 1);
  }

  /** Esc closes the legend first, then lets the selection go. Returns whether it had something to close. */
  escape() {
    if (this.legendOpen) { this.legendOpen = false; this.render(); return true; }
    if (!this.selected) return false;
    this.selected = null; this.render(); return true;
  }

  zoomBy(f) { this.vp.zoomBy(f); }
  zoomTo(k) { this.vp.zoomTo(k); }
  fit() { if (this.lay) this.vp.fit(this.lay.width, this.lay.height); }
  get zoom() { return this.vp.view.k; }
  /** How many cards were placed by hand: what Reset layout would forget. */
  get moved() { return Object.keys(this.pins).length; }
  /** Forget every card placed by hand. Returns what was forgotten, for Undo; null when there was nothing. */
  resetLayout() {
    if (!this.moved) return null;
    const was = { ...this.pins };
    this.pins = {}; this.#persist(); this.render(); this.fit();
    return was;
  }

  restoreLayout(was) {
    if (!was) return false;
    this.pins = { ...was }; this.#persist(); this.render();
    return true;
  }

  toggleGroup(id) {
    if (this.folded.has(id)) this.folded.delete(id); else this.folded.add(id);
    this.#persist();
    this.render();
  }

  render() {
    if (this.root.hidden) return;
    const note = emptyNote(this.data);
    if (note) {
      this.empty.replaceChildren(mk('p', null, note));
      if (this.data?.missing) this.empty.append(mk('p', 'sub', 'Studio only reads the map: nothing is scanned from the panel.'));
      this.root.replaceChildren(this.empty);
      return;
    }
    if (this.root.children?.[0] !== this.frame) this.root.replaceChildren(this.frame);
    const d = this.data;
    const doc = d.doc;
    const findings = findingsOf(doc, { showHidden: this.showHidden, compare: d.compare });
    const counts = this.layers.findings ? findingCounts(findings.shown) : {};
    const allEdges = edgesOf(doc, d.compare);
    const all = nodesOf(doc, d.compare);
    let nodes = all.filter((n) => (n.kind === 'external' ? this.layers.external : this.layers.modules));
    const groups = groupsOf(nodes);
    this.groupOf = {};
    for (const g of Object.values(groups)) for (const m of g.members) if (this.folded.has(g.id)) this.groupOf[m] = g.id;
    const sortKey = {};
    for (const g of Object.values(groups)) for (const m of g.members) sortKey[m] = g.id;
    // Members of one folder side by side, so an open group can be framed.
    nodes = [...nodes].sort((a, b) => (BAND_ORDER[a.band] - BAND_ORDER[b.band]) || String(sortKey[a.id] ?? a.id).localeCompare(String(sortKey[b.id] ?? b.id)));
    const ids = new Set(nodes.map((n) => n.id));
    const view = foldView(nodes, allEdges.filter((e) => ids.has(e.from) && ids.has(e.to)), groups, this.folded);
    nodes = view.nodes;
    const edges = view.edges;
    for (const n of nodes) if (n.kind === 'group') counts[n.id] = n.members.reduce((s, m) => s + (counts[m] ?? 0), 0);
    const chips = {};
    if (this.layers.endpoints) for (const n of nodes) if (n.kind === 'module') chips[n.id] = chipsOf(n, doc);
    // The width cards wrap at is taken once per map and per pane size, not on every redraw: a click must not move
    // the cards it did not touch.
    this.layWidth ??= Math.max(720, (this.pane.clientWidth || 1100) - 24);
    const width = this.layWidth;
    const openGroup = (n) => (sortKey[n.id] && !this.folded.has(sortKey[n.id]) ? sortKey[n.id] : null);
    this.lay = placed(layoutOf(nodes, { width, chips: Object.fromEntries(Object.entries(chips).map(([k, v]) => [k, v.length])), rowKey: openGroup }), this.pins);
    const lay = this.lay;
    const shownSel = this.selected ? (lay.pos[this.selected] ? this.selected : this.groupOf[this.selected] ?? null) : null;
    const lit = litEdges(edges, shownSel);

    this.top.replaceChildren(this.#head(doc, findings), this.#toolbar(d), this.#source(d));

    this.layer.style.width = `${lay.width}px`;
    this.layer.style.height = `${lay.height}px`;
    const parts = [];
    for (const b of lay.bands) {
      const band = mk('div', 'mp-band');
      band.style.top = `${b.y}px`; band.style.height = `${b.h}px`; band.style.width = `${lay.width}px`;
      band.dataset.band = b.key;
      band.append(mk('span', 'lbl', b.label));
      parts.push(band);
    }
    // An open group is framed around its members, with the control that folds it.
    for (const g of Object.values(groups)) {
      if (this.folded.has(g.id)) continue;
      const boxes = g.members.map((m) => lay.pos[m]).filter(Boolean);
      if (boxes.length < 2) continue;
      const x = Math.min(...boxes.map((p) => p.x)) - 8; const y = Math.min(...boxes.map((p) => p.y)) - 24;
      const w = Math.max(...boxes.map((p) => p.x + p.w)) - x + 8; const h = Math.max(...boxes.map((p) => p.y + p.h)) - y + 8;
      const frame = mk('div', 'mp-group');
      frame.dataset.group = g.id;
      frame.style.left = `${x}px`; frame.style.top = `${y}px`; frame.style.width = `${w}px`; frame.style.height = `${h}px`;
      const fold = mk('button', 'mp-group-fold', `${g.folder}/ · fold`);
      fold.type = 'button';
      fold.title = `Fold the ${g.members.length} modules under ${g.folder}/ into one card`;
      fold.addEventListener('click', () => this.toggleGroup(g.id));
      frame.append(fold);
      parts.push(frame);
    }
    const lines = svg('svg', { class: 'mp-lines', width: lay.width, height: lay.height, 'aria-hidden': 'true' });
    const labels = [];
    for (const e of edges) {
      const p = pathOf(lay.pos[e.from], lay.pos[e.to]);
      if (!p) continue;
      const path = svg('path', { d: p.d, class: 'mp-line' });
      path.dataset.solid = String(e.solid);
      path.dataset.line = e.line;
      if (shownSel) path.dataset.lit = String(lit.has(edgeKey(e)));
      lines.append(path);
      const tags = [];
      if (e.line === 'model') { const m = mk('span', 'mp-pill', 'model'); m.dataset.tone = 'model'; m.title = 'Proposed by the model, not shown by a file'; tags.push(m); }
      if (e.calls) {
        tags.push(mk('span', 'mp-pill', `${e.calls} ${e.calls === 1 ? 'call' : 'calls'}`));
        if (e.missing) { const m = mk('span', 'mp-pill', `${e.missing} missing`); m.dataset.tone = 'missing'; tags.push(m); }
      }
      if (tags.length) {
        const tag = mk('div', 'mp-elab');
        tag.style.left = `${p.mid[0]}px`; tag.style.top = `${p.mid[1]}px`;
        tag.append(...tags);
        labels.push(tag);
      }
    }
    parts.push(lines, ...labels);
    for (const n of nodes) parts.push(this.#card(n, doc, lay.pos[n.id], counts[n.id] ?? 0, chips[n.id], edges, shownSel));
    this.layer.replaceChildren(...parts);
    if (!this.fitted) { this.fitted = true; this.fit(); } else this.vp.apply();

    this.below.replaceChildren(...(this.layers.findings ? [this.#findings(findings)] : []));
    this.#modList(all, counts);
    const picked = this.selected ? all.find((n) => n.id === this.selected) ?? null : null;
    this.#inspector(picked, doc, allEdges, findings.shown);
  }

  #head(doc, findings) {
    const head = mk('header', 'mp-head');
    head.append(mk('h2', 'mp-title', 'Map'), mk('span', 'row-fill'));
    for (const s of summaryOf(doc, findings)) head.append(mk('span', 'mp-pill', s));
    return head;
  }

  #toolbar(d) {
    const bar = mk('div', 'mp-toolbar');
    bar.append(mk('span', 'lbl', 'Layers'));
    for (const [k, label] of LAYERS) {
      const b = mk('button', 'mp-tog', label);
      b.type = 'button';
      b.setAttribute('aria-pressed', String(this.layers[k]));
      b.addEventListener('click', () => { this.layers[k] = !this.layers[k]; this.render(); });
      bar.append(b);
    }
    bar.append(mk('span', 'row-fill'));
    const pick = mk('select', 'mp-compare');
    pick.setAttribute('aria-label', 'Compare with');
    const none = mk('option', null, d.others?.length ? 'Compare with…' : 'Compare with: no other project has a map');
    none.value = '';
    pick.append(none);
    for (const o of d.others ?? []) { const opt = mk('option', null, o.label); opt.value = o.cwd; pick.append(opt); }
    pick.value = d.compare?.cwd ?? '';
    pick.disabled = !d.others?.length;
    pick.addEventListener('change', () => this.hooks.onCompare?.(pick.value || null));
    const legend = mk('div', 'mp-legend');
    const lb = mk('button', 'btn sm ghost', 'Legend');
    lb.type = 'button';
    lb.setAttribute('aria-expanded', String(this.legendOpen));
    lb.addEventListener('click', () => { this.legendOpen = !this.legendOpen; this.render(); });
    legend.append(lb);
    if (this.legendOpen) {
      const lg = mk('div', 'mp-legend-box');
      for (const [kind, text] of [['evidence', 'A file proves this line'], ['inferred', 'Inferred, not proven'], ['model', 'Proposed by the model'], ['lit', 'A line of the selected node']]) {
        const row = mk('div', 'mp-legend-row');
        const s = mk('span', 'mp-legend-line'); s.dataset.kind = kind;
        row.append(s, mk('span', 'sub', text));
        lg.append(row);
      }
      for (const [kind, text] of [['solid', 'A resource a file shows'], ['dashed', 'A resource only inferred']]) {
        const row = mk('div', 'mp-legend-row');
        const s = mk('span', 'mp-legend-card'); s.dataset.kind = kind;
        row.append(s, mk('span', 'sub', text));
        lg.append(row);
      }
      legend.append(lg);
    }
    bar.append(pick, legend);
    return bar;
  }

  #source(d) {
    const s = sourceOf(d);
    const strip = mk('div', 'mp-source');
    strip.append(mk('code', 'mp-file', s.file), mk('span', 'sub', `· ${s.at}`));
    if (s.behind) { const b = mk('span', 'mp-pill', s.behind); b.dataset.tone = 'behind'; strip.append(b); }
    if (s.behindNote) strip.append(mk('span', 'sub', s.behindNote));
    if (d.compare?.reason) strip.append(mk('span', 'sub', `Compare: ${d.compare.reason}`));
    strip.append(mk('span', 'row-fill'), mk('span', 'sub', s.rule));
    return strip;
  }

  #card(n, doc, p, count, chips, edges, shownSel) {
    const card = mk('div', `mp-card ${n.kind === 'external' ? 'mp-ext' : 'mp-mod'}`);
    card.tabIndex = 0;
    card.setAttribute('role', 'button');
    card.dataset.id = n.id;
    card.dataset.kind = n.kind;
    card.style.left = `${p.x}px`; card.style.top = `${p.y}px`; card.style.width = `${p.w}px`; card.style.height = `${p.h}px`;
    if (shownSel === n.id) card.dataset.selected = 'true';
    if (this.pins[n.id]) card.dataset.pinned = 'true';
    if (n.kind === 'external') {
      if (inferredOnly(n, edges)) { card.dataset.inferred = 'true'; card.title = 'Only inferred: no file shows this resource directly'; }
      card.append(mk('span', 'mp-kind', resourceWord(n.resource)), mk('span', 'mp-ename', n.label ?? n.id));
      if (!card.title) card.title = (n.hosts ?? []).join(', ');
    } else {
      const top = mk('span', 'mp-row');
      top.append(mk('span', 'mp-name', n.name ?? n.id), mk('span', 'row-fill'));
      if (count) { const f = mk('span', 'mp-fb', String(count)); f.title = `${count} ${count === 1 ? 'finding' : 'findings'}`; top.append(f); }
      const sub = n.kind === 'group' ? `${n.members.length} modules · click to open` : cardSub(n, doc);
      card.append(top, mk('span', 'sub', sub));
      if (chips?.length) { const c = mk('span', 'mp-chips'); for (const t of chips) c.append(mk('span', 'mp-chip', t)); card.append(c); }
    }
    draggable(card, {
      scale: () => this.vp.view.k,
      at: () => this.lay?.pos[n.id],
      move: (x, y) => { card.style.left = `${x}px`; card.style.top = `${y}px`; this.pins[n.id] = { x, y }; },
      end: () => { this.#persist(); this.render(); },
    });
    const act = () => (n.kind === 'group' ? this.toggleGroup(n.id) : this.select(this.selected === n.id ? null : n.id));
    card.addEventListener('click', () => { if (!swallowClick(card)) act(); });
    card.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); act(); } });
    return card;
  }

  #findings(f) {
    const box = mk('section', 'mp-findings');
    box.setAttribute('aria-label', 'Findings');
    const h = mk('div', 'mp-row');
    h.append(mk('span', 'lbl', `Findings · ${f.shown.length}`), mk('span', 'sub', `${f.proven} proven by a file · ${f.shown.length - f.proven} inferred`), mk('span', 'row-fill'));
    if (f.hidden) {
      const t = mk('button', 'btn sm ghost', this.showHidden ? `Hide ${f.hidden} hidden by default` : `Show ${f.hidden} hidden by default`);
      t.type = 'button';
      t.title = 'Rules wrong too often to show unasked. Their findings are kept, not deleted.';
      t.addEventListener('click', () => { this.showHidden = !this.showHidden; this.render(); });
      h.append(t);
    }
    h.append(mk('span', 'sub mp-hint', 'Click a row to show it on the map'));
    box.append(h);
    if (!f.shown.length) box.append(mk('p', 'sub', f.total ? 'Every finding of this map is hidden by default.' : 'No finding in this map.'));
    const list = mk('div', 'mp-flist');
    for (const x of f.shown) {
      const row = mk('button', 'mp-frow');
      row.type = 'button';
      const dot = mk('span', 'mp-dot'); dot.dataset.proven = String(x.proven);
      row.append(dot, mk('span', 'mp-ftitle', x.title), mk('span', 'mp-fwhere', x.where), mk('span', 'row-fill'), mk('span', 'mp-badge', x.proven ? 'proven' : 'inferred'));
      if (x.hidden) row.title = x.hiddenReason ?? 'Hidden by default';
      row.addEventListener('click', () => { if (x.modules[0]) this.select(x.modules[0], { reveal: true }); });
      list.append(row);
    }
    box.append(list);
    return box;
  }

  /** The modules as a list: what a phone shows in place of the pane. */
  #modList(all, counts) {
    const rows = all.filter((n) => n.kind !== 'external');
    const items = rows.map((n) => {
      const r = mk('button', 'mp-mrow');
      r.type = 'button';
      r.dataset.id = n.id;
      r.append(mk('span', 'mp-name', n.name ?? n.id), mk('span', 'row-fill'), mk('span', 'sub', BAND_WORD[n.band] ?? ''));
      if (counts[n.id]) r.append(mk('span', 'mp-fb', String(counts[n.id])));
      r.addEventListener('click', () => this.select(n.id));
      return r;
    });
    this.list.replaceChildren(mk('span', 'lbl', `Modules · ${rows.length}`), ...items);
  }

  #inspector(node, doc, edges, findings) {
    const parts = [];
    if (!node) {
      parts.push(mk('p', 'sub', 'Select a module to see what it connects to and what was found in it. Esc lets it go.'));
    } else {
      const v = inspectOf(node, doc, edges, findings);
      const top = mk('div', 'mp-row');
      const close = mk('button', 'btn icon sm ghost', '×');
      close.type = 'button'; close.setAttribute('aria-label', 'Close inspector');
      close.addEventListener('click', () => this.select(null));
      top.append(mk('span', 'mp-name', v.title), mk('span', 'row-fill'), close);
      parts.push(top);
      if (v.path) parts.push(mk('code', 'sub', v.path));
      if (v.chips.length) { const c = mk('div', 'mp-chips'); for (const t of v.chips) c.append(mk('span', 'mp-chip', t)); parts.push(c); }
      const tabs = mk('nav', 'mp-tabs');
      for (const [k, label] of [['overview', 'Overview'], ['connections', `Connections ${v.connections.out.length + v.connections.in.length}`], ['findings', `Findings ${v.findings.length}`]]) {
        const t = mk('button', 'mp-tab', label);
        t.type = 'button';
        t.setAttribute('aria-selected', String(this.tab === k));
        t.addEventListener('click', () => { this.tab = k; this.render(); });
        tabs.append(t);
      }
      parts.push(tabs);
      const sec = mk('div', 'mp-isec');
      if (this.tab === 'overview') {
        sec.append(mk('span', 'lbl', 'What it is for'), mk('p', v.narrative ? null : 'sub', v.narrative ?? v.narrativeNote));
        sec.append(mk('span', 'lbl', 'Connects to'));
        if (!v.connectsTo.length) sec.append(mk('p', 'sub', 'Nothing on this map.'));
        for (const c of v.connectsTo) sec.append(this.#conn(c));
        if (v.evidence.length) {
          sec.append(mk('span', 'lbl', `Evidence · ${v.evidenceTotal}`));
          for (const e of v.evidence) sec.append(this.#cite(e));
          if (v.evidenceTotal > v.evidence.length) sec.append(mk('p', 'sub', `${v.evidenceTotal - v.evidence.length} more in the map file`));
        }
      } else if (this.tab === 'connections') {
        if (!v.byKind.length) sec.append(mk('p', 'sub', 'Nothing on this map.'));
        for (const [kind, { out, in: into }] of v.byKind) {
          sec.append(mk('span', 'lbl', `${kind} · ${out.length + into.length}`));
          for (const c of out) sec.append(this.#conn(c, 'out'));
          for (const c of into) sec.append(this.#conn(c, 'in'));
        }
      } else {
        if (!v.findings.length) sec.append(mk('p', 'sub', 'No finding shown for this node.'));
        for (const f of v.findings) {
          const card = mk('div', 'mp-fcard');
          card.dataset.proven = String(f.proven);
          const r = mk('div', 'mp-row');
          r.append(mk('span', 'mp-ftitle', f.title), mk('span', 'row-fill'), mk('span', 'mp-badge', f.proven ? 'proven' : 'inferred'));
          const b = mk('button', 'btn sm', 'Copy as task');
          b.type = 'button';
          b.title = 'Copies the finding as a task to paste into a session. Nothing is run.';
          b.addEventListener('click', () => this.hooks.onCopy?.(taskOf(f), 'task'));
          card.append(r);
          if (f.where) card.append(this.#cite(f.where));
          card.append(b);
          sec.append(card);
        }
      }
      parts.push(sec);
    }
    const nm = mk('div', 'mp-notmeasured');
    nm.append(mk('span', 'lbl', 'Not measured'));
    if (!doc.notMeasured.length) nm.append(mk('p', 'sub', 'Nothing: every file of the project was read.'));
    for (const x of doc.notMeasured) nm.append(mk('p', 'sub', `${x.what} — ${x.reason}`));
    parts.push(nm);
    this.side.replaceChildren(...parts);
  }

  /** A file:line the viewer can copy. */
  #cite(text) {
    const b = mk('button', 'mp-ev mp-cite', text);
    b.type = 'button';
    b.title = 'Copy the path';
    b.addEventListener('click', () => this.hooks.onCopy?.(text, 'path'));
    return b;
  }

  #conn(c, dir = null) {
    const row = mk('div', 'mp-conn');
    const r = mk('div', 'mp-row');
    r.append(mk('span', 'mp-kind', dir === 'in' ? `← ${c.kind}` : c.kind), mk('span', 'mp-name', c.to), mk('span', 'row-fill'));
    if (c.host) r.append(mk('span', 'sub', c.host));
    row.append(r);
    if (c.evidence) {
      const ev = this.#cite(c.evidence);
      if (c.line !== 'evidence') ev.title = `Copy the path · ${c.line === 'model' ? 'proposed by the model' : 'inferred'}`;
      row.append(ev);
      if (c.line !== 'evidence') row.append(mk('span', 'sub', c.line === 'model' ? 'proposed by the model' : 'inferred'));
    }
    return row;
  }

  #persist() {
    const cwd = this.data?.cwd;
    if (!cwd) return;
    try {
      localStorage.setItem(LAYOUT_KEY + cwd, JSON.stringify({ pins: this.pins, folded: [...this.folded] }));
    } catch { /* kept for this page view only */ }
  }

  #restore(cwd) {
    this.pins = {}; this.folded = new Set();
    if (!cwd) return;
    try {
      const saved = JSON.parse(localStorage.getItem(LAYOUT_KEY + cwd) ?? 'null');
      for (const [id, p] of Object.entries(saved?.pins ?? {})) if (Number.isFinite(p?.x) && Number.isFinite(p?.y)) this.pins[id] = { x: p.x, y: p.y };
      for (const id of saved?.folded ?? []) if (typeof id === 'string') this.folded.add(id);
    } catch { /* start from the map's own layout */ }
  }
}
