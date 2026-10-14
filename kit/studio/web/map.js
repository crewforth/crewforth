// The Map view: the project as Crewforth's crew map shows it.
//
// Bands from the clients down to the external resources, the lines between them (solid where a file proves the
// line, dotted where it is inferred), the findings under the canvas and an inspector for the selected node. It reads
// the map the server sends and writes nothing; the one button that leaves the page copies a finding as a task.
import {
  nodesOf, edgesOf, edgeKey, litEdges, findingsOf, findingCounts, cardSub, summaryOf, sourceOf, inspectOf, taskOf,
  emptyNote, layoutOf, pathOf, chipsOf, resourceWord,
} from './map-plan.js';

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

const LAYERS = [['modules', 'Modules'], ['external', 'External'], ['endpoints', 'Endpoints'], ['findings', 'Findings']];

export class MapView {
  /**
   * @param hooks.onCopy(text)    put a finding, as a task, on the clipboard
   * @param hooks.onCompare(cwd)  read the map again, compared with that project's (null: with none)
   */
  constructor(root, hooks = {}) {
    this.root = root;
    this.hooks = hooks;
    this.data = null;
    this.layers = { modules: true, external: true, endpoints: false, findings: true };
    this.showHidden = false;
    this.selected = null;
    this.tab = 'overview';
    this.root.classList.add('mp');
  }

  setData(data) {
    if (data?.cwd !== this.data?.cwd) { this.selected = null; this.tab = 'overview'; }
    this.data = data;
    this.render();
  }

  select(id) { this.selected = id; this.tab = 'overview'; this.render(); }

  /** Esc lets the selection go. Returns whether it had one. */
  escape() { if (!this.selected) return false; this.selected = null; this.render(); return true; }

  render() {
    if (this.root.hidden) return;
    const note = emptyNote(this.data);
    if (note) {
      const box = mk('div', 'mp-empty');
      box.append(mk('p', null, note));
      if (this.data?.missing) box.append(mk('p', 'sub', 'Studio only reads the map: nothing is scanned from the panel.'));
      this.root.replaceChildren(box);
      return;
    }
    const d = this.data;
    const doc = d.doc;
    const findings = findingsOf(doc, { showHidden: this.showHidden, compare: d.compare });
    const counts = this.layers.findings ? findingCounts(findings.shown) : {};
    const nodes = nodesOf(doc, d.compare).filter((n) => (n.kind === 'external' ? this.layers.external : this.layers.modules));
    const ids = new Set(nodes.map((n) => n.id));
    const edges = edgesOf(doc, d.compare).filter((e) => ids.has(e.from) && ids.has(e.to));
    const chips = {};
    if (this.layers.endpoints) for (const n of nodes) if (n.kind === 'module') chips[n.id] = chipsOf(n, doc);
    const width = Math.max(720, (this.root.clientWidth || 1100) - 380);
    const lay = layoutOf(nodes, { width, chips: Object.fromEntries(Object.entries(chips).map(([k, v]) => [k, v.length])) });
    const lit = litEdges(edges, this.selected);

    const pane = mk('section', 'mp-pane');
    pane.append(this.#head(doc, findings), this.#toolbar(d), this.#source(d));

    const body = mk('div', 'mp-body');
    const main = mk('div', 'mp-main');
    const scroll = mk('div', 'mp-scroll');
    const canvas = mk('div', 'mp-canvas');
    canvas.style.width = `${lay.width}px`;
    canvas.style.height = `${lay.height}px`;
    for (const b of lay.bands) {
      const band = mk('div', 'mp-band');
      band.style.top = `${b.y}px`; band.style.height = `${b.h}px`;
      band.dataset.band = b.key;
      band.append(mk('span', 'lbl', b.label));
      canvas.append(band);
    }
    const lines = svg('svg', { class: 'mp-lines', width: lay.width, height: lay.height, 'aria-hidden': 'true' });
    for (const e of edges) {
      const p = pathOf(lay.pos[e.from], lay.pos[e.to]);
      if (!p) continue;
      const path = svg('path', { d: p.d, class: 'mp-line' });
      path.dataset.solid = String(e.solid);
      if (this.selected) path.dataset.lit = String(lit.has(edgeKey(e)));
      lines.append(path);
      if (e.calls) {
        const tag = mk('div', 'mp-elab');
        tag.style.left = `${p.mid[0]}px`; tag.style.top = `${p.mid[1]}px`;
        tag.append(mk('span', 'mp-pill', `${e.calls} ${e.calls === 1 ? 'call' : 'calls'}`));
        if (e.missing) { const m = mk('span', 'mp-pill', `${e.missing} missing`); m.dataset.tone = 'missing'; tag.append(m); }
        canvas.append(tag);
      }
    }
    canvas.append(lines);
    for (const n of nodes) canvas.append(this.#card(n, doc, lay.pos[n.id], counts[n.id] ?? 0, chips[n.id]));
    scroll.append(canvas);
    main.append(scroll);
    if (this.layers.findings) main.append(this.#findings(findings));
    body.append(main);
    const picked = this.selected ? nodesOf(doc, d.compare).find((n) => n.id === this.selected) : null;
    body.append(this.#inspector(picked, doc, edgesOf(doc, d.compare), findings.shown));
    pane.append(body);
    this.root.replaceChildren(pane);
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
    const legend = mk('details', 'mp-legend');
    legend.append(mk('summary', 'btn sm ghost', 'Legend'));
    const lg = mk('div', 'mp-legend-box');
    for (const [cls, text] of [['solid', 'A file proves this line'], ['dotted', 'Inferred, not proven'], ['lit', 'A line of the selected node']]) {
      const row = mk('div', 'mp-legend-row');
      const s = mk('span', 'mp-legend-line'); s.dataset.kind = cls;
      row.append(s, mk('span', 'sub', text));
      lg.append(row);
    }
    legend.append(lg);
    bar.append(pick, legend);
    return bar;
  }

  #source(d) {
    const s = sourceOf(d);
    const strip = mk('div', 'mp-source');
    strip.append(mk('code', 'mp-file', s.file), mk('span', 'sub', `· ${s.at}`));
    if (s.behind) { const b = mk('span', 'mp-pill', s.behind); b.dataset.tone = 'behind'; strip.append(b); }
    if (s.behindNote) { const n = mk('span', 'sub', s.behindNote); strip.append(n); }
    if (d.compare?.reason) strip.append(mk('span', 'sub', `Compare: ${d.compare.reason}`));
    strip.append(mk('span', 'row-fill'), mk('span', 'sub', s.rule));
    return strip;
  }

  #card(n, doc, p, count, chips) {
    const card = mk('button', n.kind === 'external' ? 'mp-ext' : 'mp-mod');
    card.type = 'button';
    card.dataset.id = n.id;
    card.dataset.kind = n.kind;
    card.style.left = `${p.x}px`; card.style.top = `${p.y}px`; card.style.width = `${p.w}px`; card.style.height = `${p.h}px`;
    if (this.selected === n.id) card.dataset.selected = 'true';
    if (n.kind === 'external') {
      card.append(mk('span', 'mp-kind', resourceWord(n.resource)), mk('span', 'mp-ename', n.label ?? n.id));
      card.title = (n.hosts ?? []).join(', ');
    } else {
      const top = mk('span', 'mp-row');
      top.append(mk('span', 'mp-name', n.name ?? n.id), mk('span', 'row-fill'));
      if (count) { const f = mk('span', 'mp-fb', String(count)); f.title = `${count} ${count === 1 ? 'finding' : 'findings'}`; top.append(f); }
      card.append(top, mk('span', 'sub', cardSub(n, doc)));
      if (chips?.length) { const c = mk('span', 'mp-chips'); for (const t of chips) c.append(mk('span', 'mp-chip', t)); card.append(c); }
    }
    card.addEventListener('click', () => this.select(this.selected === n.id ? null : n.id));
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
    box.append(h);
    if (!f.shown.length) box.append(mk('p', 'sub', f.total ? 'Every finding of this map is hidden by default.' : 'No finding in this map.'));
    const list = mk('div', 'mp-flist');
    for (const x of f.shown) {
      const row = mk('button', 'mp-frow');
      row.type = 'button';
      const dot = mk('span', 'mp-dot'); dot.dataset.proven = String(x.proven);
      row.append(dot, mk('span', 'mp-ftitle', x.title), mk('span', 'mp-fwhere', x.where), mk('span', 'row-fill'), mk('span', 'mp-badge', x.proven ? 'proven' : 'inferred'));
      if (x.hidden) row.title = x.hiddenReason ?? 'Hidden by default';
      row.addEventListener('click', () => { if (x.modules[0]) this.select(x.modules[0]); });
      list.append(row);
    }
    box.append(list);
    return box;
  }

  #inspector(node, doc, edges, findings) {
    const side = mk('aside', 'mp-inspect');
    side.setAttribute('aria-label', 'Selected node');
    if (!node) {
      side.append(mk('p', 'sub', 'Select a module to see what it connects to and what was found in it. Esc lets it go.'));
    } else {
      const v = inspectOf(node, doc, edges, findings);
      const top = mk('div', 'mp-row');
      const close = mk('button', 'btn icon sm ghost', '×');
      close.type = 'button'; close.setAttribute('aria-label', 'Close inspector');
      close.addEventListener('click', () => this.select(null));
      top.append(mk('span', 'mp-name', v.title), mk('span', 'row-fill'), close);
      side.append(top);
      if (v.path) side.append(mk('code', 'sub', v.path));
      if (v.chips.length) { const c = mk('div', 'mp-chips'); for (const t of v.chips) c.append(mk('span', 'mp-chip', t)); side.append(c); }
      const tabs = mk('nav', 'mp-tabs');
      for (const [k, label] of [['overview', 'Overview'], ['connections', `Connections ${v.connections.out.length + v.connections.in.length}`], ['findings', `Findings ${v.findings.length}`]]) {
        const t = mk('button', 'mp-tab', label);
        t.type = 'button';
        t.setAttribute('aria-selected', String(this.tab === k));
        t.addEventListener('click', () => { this.tab = k; this.render(); });
        tabs.append(t);
      }
      side.append(tabs);
      const sec = mk('div', 'mp-isec');
      if (this.tab === 'overview') {
        sec.append(mk('span', 'lbl', 'What it is for'), mk('p', v.narrative ? null : 'sub', v.narrative ?? v.narrativeNote));
        sec.append(mk('span', 'lbl', 'Connects to'));
        if (!v.connectsTo.length) sec.append(mk('p', 'sub', 'Nothing on this map.'));
        for (const c of v.connectsTo) sec.append(this.#conn(c));
      } else if (this.tab === 'connections') {
        for (const [label, list] of [['Out', v.connections.out], ['In', v.connections.in]]) {
          sec.append(mk('span', 'lbl', `${label} · ${list.length}`));
          for (const c of list) sec.append(this.#conn(c));
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
          b.addEventListener('click', () => this.hooks.onCopy?.(taskOf(f)));
          card.append(r, mk('span', 'sub', f.where), b);
          sec.append(card);
        }
      }
      side.append(sec);
    }
    const nm = mk('div', 'mp-notmeasured');
    nm.append(mk('span', 'lbl', 'Not measured'));
    if (!doc.notMeasured.length) nm.append(mk('p', 'sub', 'Nothing: every file of the project was read.'));
    for (const x of doc.notMeasured) nm.append(mk('p', 'sub', `${x.what} — ${x.reason}`));
    side.append(nm);
    return side;
  }

  #conn(c) {
    const row = mk('div', 'mp-conn');
    const r = mk('div', 'mp-row');
    r.append(mk('span', 'mp-kind', c.kind), mk('span', 'mp-name', c.to), mk('span', 'row-fill'));
    if (c.host) r.append(mk('span', 'sub', c.host));
    row.append(r);
    if (c.evidence) row.append(mk('span', 'mp-ev', `${c.evidence}${c.solid ? '' : ' · inferred'}`));
    return row;
  }
}
