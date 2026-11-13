// The Map view: the project as Crewforth's crew map shows it.
//
// Columns, left to right in the order things are used: what people use, what serves them, the code they share, what
// they run on, and the outside services; a line points from the module that uses to the one used, so the map reads
// left to right, and carries no words (what a line is, the inspector says). Cards sit where the layout puts them and
// are not dragged, so nothing on the pane is left behind; the pane pans and zooms like the graph's (the shared
// viewport.js). Tools and modules the map does not place fold into strips under the columns. Lines are solid where a
// file proves them, dotted where they are inferred, dashed where the model proposed them; selecting a card lights its
// own. A search dims the cards it does not name, and the tour /crew-map wrote steps through the map one stop at a
// time. Under the pane, the findings; beside it, the inspector. On a phone the pane gives way to the findings and a
// list of the modules. It reads the map the server sends and writes nothing; what leaves the page is copied text: a
// finding as a task, or a file:line.
import {
  nodesOf, edgesOf, edgeKey, litEdges, findingsOf, findingCounts, cardSub, summaryOf, sourceOf, inspectOf, taskOf,
  emptyNote, layoutOf, routesOf, chipsOf, inferredOnly, outsideOf, placeOf, STRIPS, BANDS, cardOf, tourOf, searchOf, resourceWord,
} from './map-plan.js';
import { Viewport } from './viewport.js';
import { t } from './i18n.js';

const SVG = 'http://www.w3.org/2000/svg';

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
const BAND_WORD = Object.fromEntries(BANDS);

const LAYERS = [['modules', t('Modules')], ['external', t('External')], ['endpoints', t('Endpoints')], ['findings', t('Findings')]];
// What a line is, in words, where the inspector lists it: the scan's kind, said plainly. A kind not here is shown as is.
const EDGE_WORD = {
  references: t('uses'), calls: t('calls'), builds: t('builds'), runs: t('runs'), 'depends-on': t('starts after'),
  'uses-db': t('database'), 'uses-cache': t('cache'), 'uses-queue': t('queue'), 'uses-auth': t('sign-in'),
  'uses-http-api': t('web address'), 'configured-http-api': t('web address in config'),
};
const kindWord = (k) => EDGE_WORD[k] ?? k;

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
    this.open = new Set();  // the strips opened (Tools, Unplaced), for this map
    this.groupOf = {};
    this.lay = null;
    this.fitted = false;
    this.query = '';
    this.tourAt = -1;      // the stop shown, or -1 when the tour is off
    this.root.classList.add('mp');
    this.#build();
  }

  /** The parts that live as long as the view: the pane and the layer it moves keep the zoom across redraws. */
  #build() {
    this.top = mk('div', 'mp-top');
    this.pane = mk('div', 'mp-canvas-pane');
    this.layer = mk('div', 'mp-canvas');
    this.pane.append(this.layer);
    this.tourBox = mk('div', 'mp-tour');
    this.tourBox.hidden = true;
    this.pane.append(this.tourBox);
    this.vp = new Viewport(this.pane, this.layer, {
      skip: (t) => Boolean(t.closest?.('.mp-card') || t.closest?.('.mp-strip-head') || t.closest?.('.mp-tour')),
      onApply: () => this.hooks.onZoom?.(this.vp.view.k),
    });
    this.below = mk('div', 'mp-below');
    this.list = mk('section', 'mp-modlist');
    this.list.setAttribute('aria-label', t('Modules'));
    this.side = mk('aside', 'mp-inspect');
    this.side.setAttribute('aria-label', t('Selected node'));
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
      new ResizeObserver(() => { if (this.lay && !this.vp.touched) this.fit(); }).observe(this.pane);
    }
    // A press anywhere outside the open legend closes it, as the design says: a popover, not a window.
    document.addEventListener?.('pointerdown', (e) => {
      if (this.legendOpen && !e.target?.closest?.('.mp-legend')) { this.legendOpen = false; this.render(); }
    });
  }

  setData(data) {
    if (data?.cwd !== this.data?.cwd) {
      this.selected = null; this.tab = 'overview'; this.fitted = false; this.query = ''; this.tourAt = -1; this.open = new Set();
    }
    this.data = data;
    this.render();
  }

  /** Select a node; with `reveal`, bring its card to the middle of the pane. */
  select(id, { reveal = false } = {}) {
    // A strip holding the card opens, so a finding row, the list or the tour can bring it into view; folding the
    // strip again afterwards is the viewer's to do, and keeps it folded.
    const band = id && this.data?.doc ? nodesOf(this.data.doc, this.data.compare).find((n) => n.id === id)?.band : null;
    if (band && STRIPS.some(([k]) => k === placeOf(band))) this.open.add(placeOf(band));
    const drawn = id ? (this.lay?.pos[id] ? id : this.groupOf[id] ?? id) : null;
    this.selected = id; this.tab = 'overview';
    this.render();
    const p = drawn ? this.lay?.pos[drawn] : null;
    if (reveal && p) this.vp.centerOn(p.x + p.w / 2, p.y + p.h / 2, 1);
  }

  /** Esc closes the legend first, then lets the selection go. Returns whether it had something to close. */
  escape() {
    if (this.legendOpen) { this.legendOpen = false; this.render(); return true; }
    if (this.tourAt >= 0) { this.tourAt = -1; this.render(); return true; }
    if (!this.selected) return false;
    this.selected = null; this.render(); return true;
  }

  zoomBy(f) { this.vp.zoomBy(f); }
  zoomTo(k) { this.vp.zoomTo(k); }
  fit() { if (this.lay) this.vp.fit(this.lay.width, this.lay.height); }
  get zoom() { return this.vp.view.k; }
  // No card is placed by hand on the map, so the toolbar's Reset layout has nothing to forget here.
  get moved() { return 0; }
  resetLayout() { return null; }
  restoreLayout() { return false; }

  /** Step the tour to a stop (clamped), selecting its node and bringing it to the middle; -1 ends it. */
  tour(at) {
    const stops = this.data?.doc ? tourOf(this.data.doc) : [];
    if (at < 0 || !stops.length) { this.tourAt = -1; this.render(); return; }
    this.tourAt = Math.min(at, stops.length - 1);
    this.select(stops[this.tourAt].node, { reveal: true });
  }

  /** Open a folded strip (Tools, Unplaced) into cards, or fold it back into a line of names. */
  toggleStrip(key) {
    if (this.open.has(key)) this.open.delete(key); else this.open.add(key);
    this.render();
  }

  render() {
    if (this.root.hidden) return;
    const note = emptyNote(this.data);
    if (note) {
      this.empty.replaceChildren(mk('p', null, note));
      if (this.data?.missing) this.empty.append(mk('p', 'sub', t('Studio only reads the map: nothing is scanned from the panel.')));
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
    // An outside service is a card of its own; web addresses called by the same modules are one card (outsideOf).
    const shown = all.filter((n) => (n.kind === 'external' ? this.layers.external : this.layers.modules));
    const ids = new Set(shown.map((n) => n.id));
    const view = outsideOf(shown, allEdges.filter((e) => ids.has(e.from) && ids.has(e.to)));
    const nodes = view.nodes;
    const edges = view.edges;
    this.groupOf = {};
    for (const n of nodes) for (const m of n.members ?? []) this.groupOf[m] = n.id;
    const chips = {};
    if (this.layers.endpoints) for (const n of nodes) if (n.kind === 'module') chips[n.id] = chipsOf(n, doc);
    this.lay = layoutOf(nodes, edges, { chips: Object.fromEntries(Object.entries(chips).map(([k, v]) => [k, v.length])), open: this.open });
    const lay = this.lay;
    const shownSel = this.selected ? (lay.pos[this.selected] ? this.selected : this.groupOf[this.selected] ?? null) : null;
    const lit = litEdges(edges, shownSel);
    const found = searchOf(this.query, nodes);

    this.top.replaceChildren(this.#head(doc, findings), this.#toolbar(d), this.#source(d));

    this.layer.style.width = `${lay.width}px`;
    this.layer.style.height = `${lay.height}px`;
    const parts = [];
    for (const c of lay.columns) {
      const head = mk('div', 'mp-colhead', c.label);
      head.dataset.column = c.key;
      head.style.left = `${c.x}px`; head.style.width = `${c.w}px`;
      parts.push(head);
    }
    const nameOf = new Map(nodes.map((n) => [n.id, n.name ?? n.label ?? n.id]));
    for (const s of lay.strips) {
      const strip = mk('div', 'mp-strip');
      strip.dataset.strip = s.key;
      strip.dataset.open = String(s.open);
      strip.style.top = `${s.y}px`; strip.style.width = `${lay.width}px`; strip.style.height = `${s.h}px`;
      const head = mk('button', 'mp-strip-head');
      head.type = 'button';
      head.setAttribute('aria-expanded', String(s.open));
      head.append(mk('span', 'lbl', `${s.label} · ${s.ids.length}`));
      if (!s.open) head.append(mk('span', 'mp-strip-names', s.ids.map((id) => nameOf.get(id)).join(' · ')));
      head.append(mk('span', 'row-fill'), mk('span', 'sub', s.open ? t('Fold') : t('Open')));
      head.addEventListener('click', () => this.toggleStrip(s.key));
      strip.append(head);
      parts.push(strip);
    }
    const lines = svg('svg', { class: 'mp-lines', width: lay.width, height: lay.height, 'aria-hidden': 'true' });
    const defs = svg('defs');
    for (const k of ['base', 'lit']) {
      const m = svg('marker', { id: `mp-arrow-${k}`, class: `mp-arrow mp-arrow-${k}`, viewBox: '0 0 10 10', refX: 9, refY: 5, markerWidth: 6, markerHeight: 6, orient: 'auto' });
      m.append(svg('path', { d: 'M0 0 L10 5 L0 10 z', class: 'mp-arrowhead' }));
      defs.append(m);
    }
    lines.append(defs);
    const routes = routesOf(edges, lay.pos);
    for (const [ei, e] of edges.entries()) {
      const p = routes[ei];
      if (!p) continue;
      const on = lit.has(edgeKey(e));
      const path = svg('path', { d: p.d, class: 'mp-line', 'marker-end': `url(#mp-arrow-${on ? 'lit' : 'base'})` });
      path.dataset.solid = String(e.solid);
      path.dataset.line = e.line;
      if (e.missing) path.dataset.missing = 'true';
      if (shownSel) path.dataset.lit = String(on);
      lines.append(path);
    }
    parts.push(lines);
    for (const n of nodes) {
      if (!lay.pos[n.id]) continue;
      const card = this.#card(n, doc, lay.pos[n.id], counts[n.id] ?? 0, chips[n.id], edges, shownSel);
      if (this.query.trim()) card.dataset.match = String(found.has(n.id));
      parts.push(card);
    }
    this.layer.replaceChildren(...parts);
    if (!this.fitted) { this.fitted = true; this.fit(); } else this.vp.apply();

    this.#tourBox(doc);
    this.below.replaceChildren(...(this.layers.findings ? [this.#findings(findings)] : []));
    this.#modList(all, counts);
    const picked = this.selected ? all.find((n) => n.id === this.selected) ?? nodes.find((n) => n.id === this.selected) ?? null : null;
    this.#inspector(picked, doc, allEdges, findings.shown);
  }

  #head(doc, findings) {
    const head = mk('header', 'mp-head');
    head.append(mk('h2', 'mp-title', t('Map')), mk('span', 'row-fill'));
    for (const s of summaryOf(doc, findings)) head.append(mk('span', 'mp-pill', s));
    return head;
  }

  #toolbar(d) {
    const bar = mk('div', 'mp-toolbar');
    bar.append(mk('span', 'lbl', t('Layers')));
    for (const [k, label] of LAYERS) {
      const b = mk('button', 'mp-tog', label);
      b.type = 'button';
      b.setAttribute('aria-pressed', String(this.layers[k]));
      b.addEventListener('click', () => { this.layers[k] = !this.layers[k]; this.render(); });
      bar.append(b);
    }
    bar.append(mk('span', 'row-fill'));
    const search = mk('input', 'mp-search');
    search.type = 'search';
    search.placeholder = t('Search files and modules');
    search.setAttribute('aria-label', t('Search files and modules'));
    search.value = this.query;
    search.addEventListener('input', () => { this.query = search.value; this.render(); this.top.querySelector('.mp-search')?.focus(); });
    search.addEventListener('keydown', (e) => {
      if (e.key !== 'Enter') return;
      const first = [...searchOf(this.query, nodesOf(d.doc, d.compare))][0];
      if (first) this.select(first, { reveal: true });
    });
    bar.append(search);
    if (tourOf(d.doc).length) {
      const tb = mk('button', 'mp-tog', t('Tour'));
      tb.type = 'button';
      tb.setAttribute('aria-pressed', String(this.tourAt >= 0));
      tb.title = t('The stops /crew-map wrote for someone new to the project, in order');
      tb.addEventListener('click', () => this.tour(this.tourAt >= 0 ? -1 : 0));
      bar.append(tb);
    }
    const pick = mk('select', 'mp-compare');
    pick.setAttribute('aria-label', t('Compare with'));
    const none = mk('option', null, d.others?.length ? t('Compare with…') : t('Compare with: no other project has a map'));
    none.value = '';
    pick.append(none);
    for (const o of d.others ?? []) { const opt = mk('option', null, o.label); opt.value = o.cwd; pick.append(opt); }
    pick.value = d.compare?.cwd ?? '';
    pick.disabled = !d.others?.length;
    pick.addEventListener('change', () => this.hooks.onCompare?.(pick.value || null));
    const legend = mk('div', 'mp-legend');
    const lb = mk('button', 'btn sm ghost', t('Legend'));
    lb.type = 'button';
    lb.setAttribute('aria-expanded', String(this.legendOpen));
    lb.addEventListener('click', () => { this.legendOpen = !this.legendOpen; this.render(); });
    legend.append(lb);
    if (this.legendOpen) {
      const lg = mk('div', 'mp-legend-box');
      for (const [kind, text] of [['evidence', t('A file proves this line')], ['inferred', t('Inferred, not proven')], ['model', t('Proposed by the model')], ['lit', t('A line of the selected node')]]) {
        const row = mk('div', 'mp-legend-row');
        const s = mk('span', 'mp-legend-line'); s.dataset.kind = kind;
        row.append(s, mk('span', 'sub', text));
        lg.append(row);
      }
      lg.append(mk('p', 'sub', t('An arrow points from what uses to what is used.')));
      for (const [kind, text] of [['solid', t('A resource a file shows')], ['dashed', t('A resource only inferred')]]) {
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
    if (d.compare?.reason) strip.append(mk('span', 'sub', t('Compare: {reason}', { reason: d.compare.reason })));
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
    if (n.kind === 'external') {
      if (inferredOnly(n, edges)) { card.dataset.inferred = 'true'; card.title = 'Only inferred: no file shows this resource directly'; }
      const top = mk('span', 'mp-row');
      top.append(mk('span', 'mp-kind', resourceWord(n.resource)), mk('span', 'mp-ename', n.label ?? n.id));
      if (n.more) top.append(mk('span', 'mp-more', `+${n.more}`));
      card.append(top);
      if (!card.title) card.title = (n.names ?? n.hosts ?? []).join('\n');
    } else {
      const top = mk('span', 'mp-row');
      const name = mk('span', 'mp-name', n.name ?? n.id);
      name.title = n.name ?? n.id;
      top.append(name);
      if (count) { const f = mk('span', 'mp-fb', String(count)); f.title = count === 1 ? t('1 finding') : t('{n} findings', { n: count }); top.append(f); }
      top.append(mk('span', 'row-fill'));
      if (n.kind !== 'module') { card.append(top, mk('span', 'sub', cardSub(n, doc))); }
      else {
        const c = cardOf(n, doc);
        if (c.kind) top.append(mk('span', 'mp-kind', c.kind));
        card.append(top);
        if (c.chips.length) {
          const row = mk('span', 'mp-chips mp-tech');
          for (const t of c.chips) row.append(mk('span', 'mp-chip', t));
          if (c.more) { const m = mk('span', 'mp-chip', `+${c.more}`); m.title = (n.tech ?? []).slice(3).map((t) => t.replace(/@.*$/, '')).join(', '); row.append(m); }
          card.append(row);
        }
      }
      if (chips?.length) { const c = mk('span', 'mp-chips'); for (const t of chips) c.append(mk('span', 'mp-chip', t)); card.append(c); }
    }
    const act = () => this.select(this.selected === n.id ? null : n.id);
    card.addEventListener('click', act);
    card.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); act(); } });
    return card;
  }

  #findings(f) {
    const box = mk('section', 'mp-findings');
    box.setAttribute('aria-label', t('Findings'));
    const h = mk('div', 'mp-row');
    h.append(mk('span', 'lbl', `${t('Findings')} · ${f.shown.length}`), mk('span', 'sub', t('{n} proven by a file · {m} inferred', { n: f.proven, m: f.shown.length - f.proven })), mk('span', 'row-fill'));
    if (f.hidden) {
      const tb = mk('button', 'btn sm ghost', this.showHidden ? t('Hide {n} hidden by default', { n: f.hidden }) : t('Show {n} hidden by default', { n: f.hidden }));
      tb.type = 'button';
      tb.title = t('Rules wrong too often to show unasked. Their findings are kept, not deleted.');
      tb.addEventListener('click', () => { this.showHidden = !this.showHidden; this.render(); });
      h.append(tb);
    }
    h.append(mk('span', 'sub mp-hint', t('Click a row to show it on the map')));
    box.append(h);
    if (!f.shown.length) box.append(mk('p', 'sub', f.total ? t('Every finding of this map is hidden by default.') : t('No finding in this map.')));
    const list = mk('div', 'mp-flist');
    for (const x of f.shown) {
      const row = mk('button', 'mp-frow');
      row.type = 'button';
      const dot = mk('span', 'mp-dot'); dot.dataset.proven = String(x.proven);
      row.append(dot, mk('span', 'mp-ftitle', x.title), mk('span', 'mp-fwhere', x.where), mk('span', 'row-fill'), mk('span', 'mp-badge', x.proven ? t('proven') : t('inferred')));
      if (x.hidden) row.title = x.hiddenReason ?? t('Hidden by default');
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
    this.list.replaceChildren(mk('span', 'lbl', `${t('Modules')} · ${rows.length}`), ...items);
  }

  #inspector(node, doc, edges, findings) {
    const parts = [];
    if (!node) {
      // The project's overview, when /crew-map wrote one: what it says, and the lines it rests on.
      const ov = doc?.overview;
      if (typeof ov?.text === 'string' && ov.text.trim()) {
        parts.push(mk('span', 'lbl', t('Overview')), mk('p', 'mp-overview', ov.text));
        if (Array.isArray(ov.cites) && ov.cites.length) parts.push(mk('p', 'sub mp-cites', `From ${ov.cites.filter((c) => typeof c === 'string').join(', ')}`));
      }
      parts.push(mk('p', 'sub', t('Select a module to see what it connects to and what was found in it. Esc lets it go.')));
    } else {
      const v = inspectOf(node, doc, edges, findings);
      const top = mk('div', 'mp-row');
      const close = mk('button', 'btn icon sm ghost', '×');
      close.type = 'button'; close.setAttribute('aria-label', t('Close inspector'));
      close.addEventListener('click', () => this.select(null));
      top.append(mk('span', 'mp-name', v.title), mk('span', 'row-fill'), close);
      parts.push(top);
      if (v.layer || v.domain) {
        const pills = mk('div', 'mp-row');
        if (v.layer) pills.append(mk('span', 'mp-pill', `${t('Layer')} · ${v.layer}`));
        if (v.domain) pills.append(mk('span', 'mp-pill', `${t('Domain')} · ${v.domain}`));
        parts.push(pills);
      }
      if (v.path) parts.push(mk('code', 'sub', v.path));
      if (v.chips.length) { const c = mk('div', 'mp-chips'); for (const t of v.chips) c.append(mk('span', 'mp-chip', t)); parts.push(c); }
      const tabs = mk('nav', 'mp-tabs');
      for (const [k, label] of [['overview', t('Overview')], ['connections', `${t('Connections')} ${v.connections.out.length + v.connections.in.length}`], ['findings', `${t('Findings')} ${v.findings.length}`]]) {
        const tb = mk('button', 'mp-tab', label);
        tb.type = 'button';
        tb.setAttribute('aria-selected', String(this.tab === k));
        tb.addEventListener('click', () => { this.tab = k; this.render(); });
        tabs.append(tb);
      }
      parts.push(tabs);
      const sec = mk('div', 'mp-isec');
      if (this.tab === 'overview') {
        sec.append(mk('span', 'lbl', t('What it is for')), mk('p', v.narrative ? null : 'sub', v.narrative ?? v.narrativeNote));
        if (v.narrative && v.narrativeCites.length) sec.append(mk('p', 'sub mp-cites', t('From {files}', { files: v.narrativeCites.join(', ') })));
        if (v.inside && (v.inside.entry || v.inside.folders.length)) {
          sec.append(mk('span', 'lbl', t('Inside')));
          if (v.inside.entry) { const r = mk('div', 'mp-conn mp-inside'); r.append(this.#cite(v.inside.entry), mk('span', 'mp-ev', 'entry point')); sec.append(r); }
          for (const f of v.inside.folders) { const r = mk('div', 'mp-conn mp-inside'); r.append(mk('span', 'mp-file', `${f.folder === '.' ? '(root)' : `${f.folder}/`}`), mk('span', 'mp-ev', `${f.files} ${f.files === 1 ? 'file' : 'files'}`)); sec.append(r); }
          if (v.inside.other) sec.append(mk('p', 'sub', t('{n} more files in other folders', { n: v.inside.other })));
          if (v.inside.tests) sec.append(mk('p', 'sub', v.inside.tests === 1 ? t('1 test file') : t('{n} test files', { n: v.inside.tests })));
        }
        if (v.changed) sec.append(mk('p', 'sub', v.changed));
        if (v.testFiles.length) {
          sec.append(mk('span', 'lbl', `${t('Tests')} · ${v.testTotal}`));
          for (const f of v.testFiles) { const r = mk('div', 'mp-conn mp-inside'); r.append(mk('span', 'mp-file', f)); sec.append(r); }
          if (v.testTotal > v.testFiles.length) sec.append(mk('p', 'sub', t('{n} more in the map file', { n: v.testTotal - v.testFiles.length })));
        }
        if (v.notes.length) {
          sec.append(mk('span', 'lbl', `${t('Notes in the code')} · ${v.notesTotal}`));
          for (const x of v.notes) { const r = mk('div', 'mp-conn mp-inside'); r.append(this.#cite(x.at), mk('span', 'mp-ev', x.text)); sec.append(r); }
          if (v.notesTotal > v.notes.length) sec.append(mk('p', 'sub', t('{n} more in the map file', { n: v.notesTotal - v.notes.length })));
        }
        sec.append(mk('span', 'lbl', t('Connects to')));
        if (!v.connectsTo.length) sec.append(mk('p', 'sub', t('Nothing on this map.')));
        for (const c of v.connectsTo) sec.append(this.#conn(c));
        if (v.evidence.length) {
          sec.append(mk('span', 'lbl', `${t('Evidence')} · ${v.evidenceTotal}`));
          for (const e of v.evidence) sec.append(this.#cite(e));
          if (v.evidenceTotal > v.evidence.length) sec.append(mk('p', 'sub', t('{n} more in the map file', { n: v.evidenceTotal - v.evidence.length })));
        }
      } else if (this.tab === 'connections') {
        if (!v.byKind.length) sec.append(mk('p', 'sub', t('Nothing on this map.')));
        for (const [kind, { out, in: into }] of v.byKind) {
          sec.append(mk('span', 'lbl', `${kindWord(kind)} · ${out.length + into.length}`));
          for (const c of out) sec.append(this.#conn(c, 'out'));
          for (const c of into) sec.append(this.#conn(c, 'in'));
        }
      } else {
        if (!v.findings.length) sec.append(mk('p', 'sub', t('No finding shown for this node.')));
        for (const f of v.findings) {
          const card = mk('div', 'mp-fcard');
          card.dataset.proven = String(f.proven);
          const r = mk('div', 'mp-row');
          r.append(mk('span', 'mp-ftitle', f.title), mk('span', 'row-fill'), mk('span', 'mp-badge', f.proven ? t('proven') : t('inferred')));
          const b = mk('button', 'btn sm', t('Copy as task'));
          b.type = 'button';
          b.title = t('Copies the finding as a task to paste into a session. Nothing is run.');
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
    nm.append(mk('span', 'lbl', t('Not measured')));
    if (!doc.notMeasured.length) nm.append(mk('p', 'sub', t('Nothing: every file of the project was read.')));
    for (const x of doc.notMeasured) nm.append(mk('p', 'sub', `${x.what} — ${x.reason}`));
    parts.push(nm);
    this.side.replaceChildren(...parts);
  }

  /** The tour's stop, over the bottom of the pane: which of how many, what to look at, and the way on. */
  #tourBox(doc) {
    const stops = tourOf(doc);
    if (this.tourAt < 0 || !stops.length) { this.tourBox.hidden = true; return; }
    const s = stops[Math.min(this.tourAt, stops.length - 1)];
    const head = mk('div', 'mp-row');
    head.append(mk('span', 'lbl', `${t('Tour')} · ${t('{at} of {n}', { at: this.tourAt + 1, n: stops.length })}`), mk('span', 'mp-name', s.name), mk('span', 'row-fill'));
    const nav = (label, at, off) => { const b = mk('button', 'btn sm ghost', label); b.type = 'button'; b.disabled = off; b.addEventListener('click', () => this.tour(at)); return b; };
    head.append(nav(t('Back'), this.tourAt - 1, this.tourAt === 0), nav(this.tourAt === stops.length - 1 ? t('Done') : t('Next'), this.tourAt === stops.length - 1 ? -1 : this.tourAt + 1, false));
    const body = [head, mk('p', null, s.text)];
    if (s.cites.length) body.push(mk('p', 'sub mp-cites', t('From {files}', { files: s.cites.join(', ') })));
    this.tourBox.replaceChildren(...body);
    this.tourBox.hidden = false;
  }

  /** A file:line the viewer can copy. */
  #cite(text) {
    const b = mk('button', 'mp-ev mp-cite', text);
    b.type = 'button';
    b.title = t('Copy the path');
    b.addEventListener('click', () => this.hooks.onCopy?.(text, 'path'));
    return b;
  }

  #conn(c, dir = null) {
    const row = mk('div', 'mp-conn');
    const r = mk('div', 'mp-row');
    r.append(mk('span', 'mp-kind', dir === 'in' ? `← ${kindWord(c.kind)}` : kindWord(c.kind)), mk('span', 'mp-name', c.to), mk('span', 'row-fill'));
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
}
