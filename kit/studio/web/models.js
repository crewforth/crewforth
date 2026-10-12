// The Models view: which model each kind of task needs in this project, from Crewforth's record of outcomes.
//
// A class is an agent, a kind of change and a risk. Each line says what ran it, how many tasks, how many of the
// verified ones passed the first time, how many were repeated one model up, and what the agents' tokens come to.
// Under the table: the holds the record could let go of. They are shown, not acted on: the one button copies
// Crewforth's command for it and lowers nothing.
import { classRow, suggestionText, emptyNote, totalsLine, costLine, SOURCE, LOWER_RULE } from './models-plan.js';

function mk(tag, cls, text) {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text != null) n.textContent = text;
  return n;
}

const COLUMNS = [['Agent · change', ''], ['Risk', ''], ['Model', ''], ['Tasks', 'mv-num'], ['First try', 'mv-num'], ['Escalated', 'mv-num'], ['Est. cost', 'mv-num']];

export class Models {
  /** @param hooks.onCopy(text) put the command on the clipboard */
  constructor(root, hooks = {}) {
    this.root = root;
    this.hooks = hooks;
    this.data = null;
    this.costs = null;
    this.root.classList.add('mv');
  }

  setData(data) { this.data = data; this.render(); }
  /** What the classes cost, read apart and less often: { measured, costs: { classKey: { cost, costed, runs } } }. */
  setCosts(costs) { this.costs = costs; this.render(); }

  render() {
    if (this.root.hidden) return;
    const note = emptyNote(this.data);
    if (note) { this.root.replaceChildren(mk('div', 'mv-empty', note)); return; }
    const d = this.data;
    const pane = mk('section', 'mv-pane');
    const head = mk('header', 'mv-head');
    const source = mk('span', 'sub', SOURCE);
    source.title = [totalsLine(d), costLine(this.costs)].filter(Boolean).join(' \u00b7 ');
    // Lines the hooks could not have written are not counted, and that is said where the count is.
    if (d.dropped) source.textContent = `${SOURCE} \u00b7 ${d.dropped} ${d.dropped === 1 ? 'line' : 'lines'} not read`;
    head.append(mk('h2', 'mv-title', 'Which model each kind of task needs'), mk('span', 'row-fill'), source);
    pane.append(head);

    const scroll = mk('div', 'mv-scroll');
    const table = mk('table', 'mv-table');
    const hr = mk('tr');
    for (const [h, cls] of COLUMNS) { const th = mk('th', cls, h); th.scope = 'col'; hr.append(th); }
    const thead = mk('thead'); thead.append(hr);
    const tbody = mk('tbody');
    const raisedNotes = [];
    for (const c of d.classes) {
      const r = classRow(c, this.costs?.measured ? (this.costs.costs?.[c.key] ?? { cost: 0, costed: 0, runs: c.runs }) : null);
      const tr = mk('tr');
      const who = mk('td');
      const name = mk('span', null, `${r.who} · ${r.change}`);
      name.title = r.real;
      who.append(name);
      const risk = mk('td');
      const tag = mk('span', 'mv-tag', r.risk);
      tag.dataset.risk = r.risk;
      risk.append(tag);
      const model = mk('td');
      const ran = mk('span', null, r.models);
      ran.title = r.ranOn ? `Ran on: ${r.ranOn}` : '';
      model.append(ran);
      if (r.floorTag) {
        const raised = mk('span', 'mv-tag', r.floorTag);
        raised.dataset.kind = r.floorTag;
        raised.title = r.raisedWhy;
        model.append(raised);
        raisedNotes.push({ tag: r.floorTag, text: `${r.who} · ${r.change}: ${r.raisedWhy}` });
      }
      const first = mk('td', 'mv-num');
      first.title = [r.firstTryOf, r.after, r.notVerified ? `Not verified: ${r.notVerified}` : null].filter(Boolean).join('\n');
      first.append(mk('span', null, r.firstTry));
      if (r.rate !== null) {
        const meter = mk('span', 'mv-meter');
        const fill = mk('span', 'mv-meter-fill');
        fill.style.width = `${Math.round(r.rate * 100)}%`;
        // Under four in five the bar is the colour of something to look at.
        fill.dataset.tone = r.rate >= 0.8 ? 'good' : 'waiting';
        meter.setAttribute('aria-hidden', 'true');
        meter.append(fill);
        first.append(meter);
      }
      const cost = mk('td', 'mv-num', r.cost);
      cost.title = r.costNote;
      if (r.partial) cost.dataset.partial = 'true';
      tr.append(who, risk, model, mk('td', 'mv-num', r.tasks), first, mk('td', 'mv-num', r.escalated), cost);
      tbody.append(tr);
    }
    table.append(thead, tbody);
    scroll.append(table);
    pane.append(scroll);

    if (d.suggestions?.length) {
      const box = mk('section', 'mv-suggest');
      box.append(mk('h3', 'mv-suggest-h', 'Suggestion · needs your approval'));
      for (const s of d.suggestions) {
        const t = suggestionText(s);
        box.append(mk('p', 'mv-suggest-text', `${t.title} ${t.says}`));
        const row = mk('div', 'mv-suggest-row');
        row.append(mk('span', 'sub', `${LOWER_RULE} ${t.how}`), mk('span', 'row-fill'));
        if (t.command) {
          // It copies the words and does nothing else: the hold is lowered where the user sends them.
          const b = mk('button', 'btn sm', 'Copy command');
          b.type = 'button';
          b.title = 'Copies the command. Nothing is lowered until you send it in your own session.';
          b.addEventListener('click', () => this.hooks.onCopy?.(t.command));
          row.append(mk('code', 'mv-cmd', t.command), b);
        }
        box.append(row);
      }
      pane.append(box);
    }
    for (const note of raisedNotes) {
      const row = mk('div', 'mv-raised');
      const tag = mk('span', 'mv-tag', note.tag);
      tag.dataset.kind = note.tag;
      row.append(tag, mk('span', 'sub', note.text));
      pane.append(row);
    }
    this.root.replaceChildren(pane);
  }
}
