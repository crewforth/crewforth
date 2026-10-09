// The List view: one column, in the order of what needs the reader.
//
// What goes where is decided in list-plan.js. This file draws it. A waiting request is a card that carries its
// own three answers, so in this view the approval dock is not needed and is not shown.
import { sections, wants } from './list-plan.js';
import { Press } from './press.js';
import { hoverOf, modelOf } from './names.js';
import { remaining, asker, allowSessionLabel, VERDICTS } from './approvals.js';

function mk(tag, cls, text) {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text != null) n.textContent = text;
  return n;
}

export class List {
  /**
   * @param hooks.tileOf(node)          the agent's mark
   * @param hooks.onSelect(node)        a row was chosen
   * @param hooks.onDecide(item, verdict)
   * @param hooks.onLocate(item)        a request in another session: go to it
   * @param hooks.dimmed(node)          is this agent outside what Show is showing
   */
  constructor(root, hooks = {}) {
    this.root = root;
    this.hooks = hooks;
    // A redraw waits while a button is down on the view: the element under a press has to live to the release.
    this.press = new Press(() => this.render());
    if (typeof window !== 'undefined' && root.addEventListener) this.press.watch(root, window);
    this.nodes = [];
    this.queue = [];
    this.current = null;
    this.folded = new Map();
    this.selected = null;
    this.busy = new Set();
    this.now = () => Date.now();
    this.root.classList.add('ls');
  }

  setSession(id) { if (id !== this.current) { this.current = id; this.nodes = []; this.folded = new Map(); this.selected = null; this.render(); } }
  setNodes(nodes) { this.nodes = nodes ?? []; this.render(); }

  setQueue(queue) {
    this.queue = queue ?? [];
    for (const key of [...this.busy]) if (!this.queue.some((r) => r.key === key)) this.busy.delete(key);
    this.render();
  }

  select(id) { this.selected = id; this.render(); }

  /** An answer did not reach the server: the buttons come back. */
  release(key) { this.busy.delete(key); this.render(); }

  /** Once a second: the countdowns and the running times move. */
  tick() { if (!this.root.hidden && (this.queue.length || this.nodes.some((n) => n.status === 'running'))) this.render(); }

  render() {
    if (this.root.hidden) return;
    if (this.press.defer()) return;
    const now = this.now();
    const list = sections(this.nodes, { queue: this.queue, current: this.current, folded: this.folded, now });
    if (!list.length) {
      const empty = mk('div', 'ls-empty');
      empty.append(mk('strong', null, 'No agents yet'),
        mk('span', null, 'This session has not delegated to a subagent. When it does, each one is listed here.'));
      this.root.replaceChildren(empty);
      return;
    }
    const focused = this.root.contains?.(document.activeElement) ? document.activeElement.dataset?.key ?? null : null;
    const top = this.root.scrollTop;
    this.root.replaceChildren(...list.map((s) => this.#section(s, now)));
    this.root.scrollTop = top;
    if (focused) [...this.root.querySelectorAll('[data-key]')].find((el) => el.dataset.key === focused)?.focus();
  }

  #section(s, now) {
    const sec = mk('section', 'ls-sec');
    sec.dataset.tone = s.tone;
    const head = mk(s.foldable ? 'button' : 'div', 'ls-head');
    const dot = mk('span', 'dot');
    dot.dataset.tone = s.tone;
    head.append(dot, mk('span', 'ls-title', `${s.title} · ${s.count}`));
    if (s.foldable) {
      head.type = 'button';
      head.dataset.key = `sec:${s.key}`;
      head.setAttribute('aria-expanded', String(!s.folded));
      head.append(mk('span', 'row-fill'), mk('span', 'sub', s.folded ? 'show' : 'hide'));
      head.addEventListener('click', () => { this.folded.set(s.key, !s.folded); this.render(); });
    }
    sec.append(head);
    for (const item of s.cards) sec.append(this.#card(item, now));
    if (!s.folded) for (const r of s.rows) sec.append(this.#row(r));
    return sec;
  }

  /** A waiting request: who wants what, how long is left, and the three answers. */
  #card(item, now) {
    const card = mk('div', 'ls-card');
    const head = mk('div', 'ls-card-head');
    const who = mk('div', 'ls-card-who');
    who.append(mk('span', 'ls-name', asker(item)), mk('span', 'sub', wants(item)));
    const r = remaining(item, now);
    const clock = mk('span', 'ls-clock', r.known ? `${r.left}s` : '?');
    clock.setAttribute('role', 'timer');
    clock.setAttribute('aria-label', r.known ? `Auto-deny in ${r.left} seconds` : 'Time left not measured');
    head.append(who, mk('span', 'row-fill'), clock);
    card.append(head);
    if (item.detail) card.append(mk('pre', 'ls-cmd', item.detail));
    // A request from another session says which, and goes there.
    if (item.sessionId !== this.current) {
      const where = mk('button', 'ls-where', `in ${item.sessionName}`);
      where.type = 'button';
      where.addEventListener('click', () => this.hooks.onLocate?.(item));
      card.append(where);
    }
    const sent = this.busy.has(item.key);
    const acts = mk('div', 'ls-acts');
    for (const [verdict, label, cls] of [
      ['allow', VERDICTS.allow.label, 'btn primary'],
      ['always', allowSessionLabel(item.toolName), 'btn'],
      ['deny', VERDICTS.deny.label, 'btn'],
    ]) {
      const b = mk('button', cls, label);
      b.type = 'button';
      b.disabled = sent;
      b.dataset.key = `card:${item.key}:${verdict}`;
      b.addEventListener('click', () => {
        if (this.busy.has(item.key)) return;
        this.busy.add(item.key);
        this.render();
        this.hooks.onDecide?.(item, verdict);
      });
      acts.append(b);
    }
    card.append(acts);
    return card;
  }

  #row(r) {
    const row = mk('button', 'ls-row');
    row.type = 'button';
    row.dataset.key = `row:${r.id}`;
    if (r.id === this.selected) row.classList.add('on');
    if (this.hooks.dimmed?.(r.node)) row.classList.add('dim');
    const tile = this.hooks.tileOf?.(r.node);
    if (tile) row.append(tile);
    const text = mk('span', 'ls-text');
    text.append(mk('span', 'ls-name', r.type), mk('span', 'ls-line', r.line));
    const mdl = modelOf(r.node);
    row.title = [hoverOf(r.node), mdl.ran ? mdl.title : null].filter(Boolean).join('\n');
    row.append(text);
    if (mdl.ran) {
      const badge = mk('span', 'sub ls-model', `${mdl.ran}${mdl.differs ? ' \u2260' : ''}`);
      badge.title = mdl.title;
      row.append(badge);
    }
    if (r.aside) row.append(mk('span', 'sub ls-aside', r.aside));
    const chev = mk('span', 'ls-chev');
    chev.innerHTML = '<svg class="ic" viewBox="0 0 16 16" aria-hidden="true"><path d="M6 4l4 4-4 4"/></svg>';
    row.append(chev);
    row.addEventListener('click', () => this.hooks.onSelect?.(r.node));
    return row;
  }
}
