// The approval dock: a strip under the canvas that exists only while a tool call is waiting.
//
// Not a dialog. It takes no focus and covers nothing, so the graph stays usable while a request waits — and the
// request is not forgotten either, because its clock is on screen and counting. What it says and when comes from
// approvals.js; this file draws it and hands the three answers back.
import { remaining, asker, allowSessionLabel, VERDICTS, OUTCOME_WORD } from './approvals.js';

const SVG = 'http://www.w3.org/2000/svg';
const RING = 2 * Math.PI * 15;      // the countdown ring's circumference, r = 15
// How long "Denied" or "Timed out — denied" stays up. Shorter when another request is waiting behind it: its
// clock is running while the word is on screen.
const FLASH_MS = { alone: 2600, queued: 1400 };

function mk(tag, cls, text) {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text != null) n.textContent = text;
  return n;
}

export class Dock {
  /**
   * @param root      the element the dock lives in
   * @param onDecide  (item, verdict) => void — verdict is 'allow', 'always' or 'deny'
   * @param onLocate  (item) => void — show the agent that asked
   * @param where     (item) => the session's name when the request is not in the one on screen, else null
   * @param now       () => the server's clock, in ms
   */
  constructor(root, { onDecide, onLocate, where, now } = {}) {
    this.root = root;
    this.onDecide = onDecide ?? (() => {});
    this.onLocate = onLocate ?? (() => {});
    this.where = where ?? (() => null);
    this.now = now ?? (() => Date.now());
    this.items = [];
    this.at = 0;
    this.open = false;        // the command shown in full
    this.busy = new Set();    // requests an answer has been sent for
    this.flash = null;        // { word, outcome, until }
    this.flashTimer = null;
    this.suppressed = false;  // another surface is showing the requests with their answers
    this.#build();
  }

  #build() {
    this.root.classList.add('dock');
    this.root.tabIndex = -1;

    const timer = mk('div', 'dock-timer');
    timer.setAttribute('role', 'timer');
    const svg = document.createElementNS(SVG, 'svg');
    svg.setAttribute('viewBox', '0 0 36 36');
    svg.setAttribute('aria-hidden', 'true');
    const track = document.createElementNS(SVG, 'circle');
    const ring = document.createElementNS(SVG, 'circle');
    for (const c of [track, ring]) { c.setAttribute('cx', '18'); c.setAttribute('cy', '18'); c.setAttribute('r', '15'); }
    track.setAttribute('class', 'dock-ring-track');
    ring.setAttribute('class', 'dock-ring');
    svg.append(track, ring);
    const secs = mk('span', 'dock-secs');
    timer.append(svg, secs);

    const text = mk('div', 'dock-text');
    const head = mk('div', 'dock-head');
    const word = mk('span', 'dock-word', 'Needs you');
    // Who asked is the way to them: it brings that agent's card into view.
    const who = mk('button', 'dock-who');
    who.type = 'button';
    who.title = 'Show on the canvas';
    who.addEventListener('click', () => { if (this.current) this.onLocate(this.current); });
    const tool = mk('span', 'dock-tool');
    const where = mk('span', 'dock-where');
    head.append(word, who, tool, where);
    // The command is a control: one line until it is asked for in full.
    const cmd = mk('button', 'dock-cmd');
    cmd.type = 'button';
    cmd.addEventListener('click', () => { this.open = !this.open; this.paint(); });
    const note = mk('div', 'dock-note');
    text.append(head, cmd, note);

    const nav = mk('div', 'dock-nav');
    const prev = mk('button', 'btn icon sm ghost dock-step');
    prev.type = 'button';
    prev.setAttribute('aria-label', 'Previous request');
    prev.innerHTML = '<svg class="ic" viewBox="0 0 16 16" aria-hidden="true"><path d="M10 4l-4 4 4 4"/></svg>';
    const count = mk('span', 'dock-count');
    const next = mk('button', 'btn icon sm ghost dock-step');
    next.type = 'button';
    next.setAttribute('aria-label', 'Next request');
    next.innerHTML = '<svg class="ic" viewBox="0 0 16 16" aria-hidden="true"><path d="M6 4l4 4-4 4"/></svg>';
    prev.addEventListener('click', () => this.step(-1));
    next.addEventListener('click', () => this.step(1));
    nav.append(prev, count, next);

    const acts = mk('div', 'dock-acts');
    const deny = mk('button', 'btn sm', VERDICTS.deny.label);
    const always = mk('button', 'btn sm');
    const allow = mk('button', 'btn sm primary', VERDICTS.allow.label);
    for (const b of [deny, always, allow]) b.type = 'button';
    deny.addEventListener('click', () => this.decide('deny'));
    always.addEventListener('click', () => this.decide('always'));
    allow.addEventListener('click', () => this.decide('allow'));
    acts.append(deny, always, allow);

    // a / s / d, and only while the dock itself has the focus: a letter typed anywhere else is a letter.
    this.root.addEventListener('keydown', (e) => {
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      const verdict = { a: 'allow', s: 'always', d: 'deny' }[e.key];
      if (!verdict) return;
      e.preventDefault();
      this.decide(verdict);
    });

    this.parts = { timer, ring, secs, word, who, tool, where, cmd, note, nav, prev, next, count, acts, deny, always, allow };
    this.root.replaceChildren(timer, text, nav, acts);
  }

  get current() { return this.items[this.at] ?? null; }

  /** The queue changed. The request being looked at stays the one being looked at, if it is still waiting. */
  render(items) {
    const was = this.current?.key ?? null;
    this.items = items ?? [];
    const keep = this.items.findIndex((r) => r.key === was);
    this.at = keep === -1 ? Math.min(this.at, Math.max(0, this.items.length - 1)) : keep;
    if (keep === -1) this.open = false;
    for (const key of [...this.busy]) if (!this.items.some((r) => r.key === key)) this.busy.delete(key);
    this.paint();
  }

  step(by) {
    if (this.items.length < 2) return;
    this.at = (this.at + by + this.items.length) % this.items.length;
    this.open = false;
    this.paint();
  }

  decide(verdict) {
    const item = this.current;
    // While the dock is saying what became of the last request, the next one is not on screen yet, and a key
    // pressed then must not answer something nobody has read.
    if (!item || this.busy.has(item.key) || this.flashing) return;
    this.busy.add(item.key);
    this.paint();
    this.onDecide(item, verdict);
  }

  /** An answer could not be delivered: the buttons come back. */
  release(key) { this.busy.delete(key); this.paint(); }

  /** Say what became of a request for a moment: "Denied", "Timed out — denied". */
  say(outcome, queued = false) {
    const ms = queued ? FLASH_MS.queued : FLASH_MS.alone;
    this.flash = { word: OUTCOME_WORD[outcome] ?? outcome, outcome, until: Date.now() + ms };
    clearTimeout(this.flashTimer);
    this.flashTimer = setTimeout(() => { this.flash = null; this.paint(); }, ms);
    this.paint();
  }

  get flashing() { return Boolean(this.flash) && Date.now() < this.flash.until; }

  /** The List view shows each request as a card with its own answers; the dock stands down while it does. */
  setSuppressed(on) { this.suppressed = Boolean(on); this.paint(); }

  /** Called once a second by the page, so the clock moves on its own. */
  tick() { if (this.items.length || this.flash) this.paint(); }

  paint() {
    const p = this.parts;
    const item = this.current;
    const flashing = this.flashing;
    this.root.hidden = this.suppressed || (!item && !flashing);
    if (this.root.hidden) return;

    // What became of the last request is said in the place it was, before the next one takes it.
    for (const part of [p.timer, p.who, p.tool, p.where, p.cmd, p.note, p.nav, p.acts]) part.hidden = flashing;
    if (flashing) {
      this.root.dataset.state = this.flash.outcome;
      p.word.textContent = this.flash.word;
      this.root.setAttribute('aria-label', this.flash.word);
      return;
    }
    this.root.dataset.state = 'waiting';
    p.word.textContent = 'Needs you';

    p.who.textContent = asker(item);
    p.who.title = item.agentType ? `${item.agentType} — show on the canvas` : 'Show on the canvas';
    p.tool.textContent = item.toolName;
    const where = this.where(item);
    p.where.hidden = !where;
    p.where.textContent = where ? `in ${where}` : '';
    p.cmd.hidden = !item.detail;
    p.cmd.textContent = item.detail ?? '';
    p.cmd.classList.toggle('open', this.open);
    p.cmd.setAttribute('aria-expanded', String(this.open));
    p.cmd.title = this.open ? 'Show on one line' : 'Show the whole command';

    const r = remaining(item, this.now());
    if (r.known) {
      p.ring.style.strokeDasharray = `${(r.fraction * RING).toFixed(1)} ${RING.toFixed(1)}`;
      p.secs.textContent = `${r.left}s`;
      p.timer.setAttribute('aria-label', `Auto-deny in ${r.left} seconds`);
      p.note.textContent = `Auto-deny in ${r.left}s if nobody answers`;
    } else {
      // The server did not say how long the hook waits. No clock is better than an invented one.
      p.ring.style.strokeDasharray = `0 ${RING.toFixed(1)}`;
      p.secs.textContent = '?';
      p.timer.setAttribute('aria-label', 'Time left not measured');
      p.note.textContent = 'Time left not measured — it is denied if nobody answers';
    }

    p.nav.hidden = this.items.length < 2;
    p.count.textContent = `${this.at + 1} of ${this.items.length}`;
    p.nav.setAttribute('aria-label', `Request ${this.at + 1} of ${this.items.length}`);

    const sent = this.busy.has(item.key);
    p.always.textContent = allowSessionLabel(item.toolName);
    p.always.title = `Allow this call, and stop asking here about ${item.toolName} for the rest of the session. Later calls are not approved for Claude Code: it still applies its own checks to them.`;
    for (const b of [p.deny, p.always, p.allow]) b.disabled = sent;
    this.root.setAttribute('aria-label', `Waiting for approval: ${asker(item)} wants to run ${item.toolName}`);
  }
}
