// The Timeline: the session's agents against time.
//
// Which rows there are, where a bar starts and ends and what it says is decided in timeline-plan.js. This file
// draws that, and hands back what the viewer did: a row chosen, a group folded, the view moved.
import {
  rows, groupsOf, foldedSet, extent, windowOf, place, ticks, clock, stepRange, waitNote, factsOf, xOf, RANGES, DEFAULT_RANGE,
} from './timeline-plan.js';
import { Press } from './press.js';
import { shownType, hoverOf, modelOf, modelFamily } from './names.js';


function mk(tag, cls, text) {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text != null) n.textContent = text;
  return n;
}

export class Timeline {
  /**
   * @param hooks.tileOf(node)      the agent's mark, as the graph draws it
   * @param hooks.statusOf(node)    the word and tone of its status
   * @param hooks.detailOf(node)    its transcript's reading, or null while it is not read
   * @param hooks.onSelect(node|null)
   * @param hooks.onShowOnGraph(node)
   * @param hooks.onOpenConversation()
   * @param hooks.onChange(state)   the toolbar's values changed
   * @param hooks.fmt               { duration(ms), tokens(n) }
   */
  constructor(root, hooks = {}) {
    this.root = root;
    this.hooks = hooks;
    // A redraw waits while a button is down on the view: the element under a press has to live to the release.
    this.press = new Press(() => this.render());
    if (typeof window !== 'undefined' && root.addEventListener) this.press.watch(root, window);
    this.nodes = [];
    this.session = null;
    this.group = 'run';
    this.range = DEFAULT_RANGE;
    this.follow = true;
    this.end = null;               // where the view ends when it is not following
    this.fold = new Map();       // group id -> folded, the viewer's own choices
    this.all = null;             // true after Expand all, false after Fold all: what an untouched group is
    this.expanded = new Set();
    this.waiting = new Set();
    this.filter = null;            // Set of statuses, or null
    this.keepWaiting = false;
    this.owned = null;             // the session's summary when Studio started it
    this.live = false;
    this.selected = null;
    this.now = () => Date.now();
    this.win = null;
    this.#build();
  }

  #build() {
    this.root.classList.add('tl');
    this.axis = mk('div', 'tl-axis');
    this.axisLabel = mk('div', 'tl-axis-label', 'Agent');
    this.axisTrack = mk('div', 'tl-axis-track');
    this.axis.append(this.axisLabel, this.axisTrack);

    this.body = mk('div', 'tl-body');
    this.rowsEl = mk('div', 'tl-rows');
    this.nowLine = mk('div', 'tl-now');
    this.nowLine.hidden = true;
    this.body.append(this.rowsEl, this.nowLine);

    this.noteEl = mk('div', 'tl-note');
    this.drawer = mk('div', 'tl-drawer');
    this.drawer.setAttribute('role', 'region');
    this.drawer.setAttribute('aria-label', 'Selected agent');
    this.drawer.hidden = true;
    this.empty = mk('div', 'tl-empty');
    this.empty.hidden = true;
    // Said when the stretch of time on screen holds no bar although the session has some: an empty track with
    // no word would read as a session in which nothing happened.
    this.away = mk('div', 'tl-away');
    this.away.hidden = true;
    const whole = mk('button', 'btn sm', 'Show the whole session');
    whole.type = 'button';
    whole.addEventListener('click', () => { this.range = 'all'; this.render(); this.#changed(); });
    this.awayText = mk('span', null);
    this.away.append(this.awayText, whole);

    this.root.replaceChildren(this.axis, this.body, this.empty, this.away, this.noteEl, this.drawer);

    // Moving the view by hand is the viewer saying "stay here": following stops.
    this.body.addEventListener('wheel', (e) => {
      const dx = Math.abs(e.deltaX) > Math.abs(e.deltaY) ? e.deltaX : (e.shiftKey ? e.deltaY : 0);
      if (!dx || !this.win) return;
      e.preventDefault();
      this.pan(dx);
    }, { passive: false });
  }

  state() {
    return { range: this.range, follow: this.follow && this.live, live: this.live, canZoomIn: stepRange(this.range, -1) !== null, canZoomOut: stepRange(this.range, 1) !== null };
  }

  #changed() { this.hooks.onChange?.(this.state()); }

  setSession(id) {
    if (id === this.session) return;
    this.session = id;
    this.nodes = [];
    this.fold = new Map();       // group id -> folded, the viewer's own choices
    this.all = null;             // true after Expand all, false after Fold all: what an untouched group is
    this.expanded = new Set();
    this.selected = null;
    this.follow = true;
    this.end = null;
    this.render();
    this.#changed();
  }

  setNodes(nodes) { this.nodes = nodes ?? []; this.render(); }
  setGroup(g) { if (g === this.group) return; this.group = g; this.fold = new Map(); this.all = null; this.expanded = new Set(); this.render(); }

  /** Open every group and show every row of the long ones; a group that arrives later arrives open. */
  expandAll() { this.all = true; this.fold = new Map(); this.render(); this.#changed(); }
  /** Fold every group; one that arrives later arrives folded. */
  foldAll() { this.all = false; this.fold = new Map(); this.expanded = new Set(); this.render(); this.#changed(); }
  /** Whether there is anything left for each of the two to do. */
  foldState() {
    const heads = (this.lastRows ?? []).filter((r) => r.kind === 'group');
    return {
      groups: heads.length,
      canExpand: heads.some((r) => r.folded) || (this.lastRows ?? []).some((r) => r.kind === 'more'),
      canFold: heads.some((r) => !r.folded),
    };
  }
  setWaiting(ids) { this.waiting = new Set(ids ?? []); this.render(); }
  setFilter(statuses, { keepWaiting = false } = {}) { this.filter = statuses ? new Set(statuses) : null; this.keepWaiting = keepWaiting; this.render(); }
  setModelFilter(family) { this.modelFilter = family ?? null; this.render(); }
  setOwned(summary) { this.owned = summary ?? null; this.render(); }
  setLive(live) { if (live === this.live) return; this.live = live; this.render(); this.#changed(); }

  zoom(by) {
    const next = stepRange(this.range, by);
    if (!next) return;
    this.range = next;
    this.render();
    this.#changed();
  }

  setFollow(on) {
    this.follow = on;
    if (on) this.end = null;
    this.render();
    this.#changed();
  }

  /** Move the view by pixels. Following stops: the viewer has chosen where to look. */
  pan(dx) {
    const width = this.trackWidth();
    if (!this.win || !width) return;
    this.end = this.win.to + (dx / width) * this.win.span;
    if (this.follow) { this.follow = false; this.#changed(); }
    this.render();
  }

  /** Choose an agent from outside (the attention strip, the dock, a card in the conversation). A folded group
   *  that holds it is opened, and a group cut short shows all its rows: choosing something never hides it. */
  select(id) {
    this.selected = id;
    if (id) {
      for (const g of groupsOf(this.nodes, this.group)) {
        if (!g.members.some((m) => m.id === id)) continue;
        this.fold.set(g.id, false);
        this.expanded.add(g.id);
      }
    }
    this.render();
    if (id) this.rowsEl.querySelector?.('.tl-row.on')?.scrollIntoView?.({ block: 'nearest' });
  }

  dimmed(n) {
    if (this.modelFilter && modelFamily(n.model) !== this.modelFilter) return true;
    if (!this.filter) return false;
    if (this.keepWaiting && this.waiting.has(n.id)) return false;
    return !this.filter.has(n.status);
  }

  /** The label column's width is the stylesheet's (it narrows on a phone); the track is what is left. */
  labelWidth() { return this.axisLabel.getBoundingClientRect?.().width ?? 0; }

  trackWidth() {
    const w = this.root.getBoundingClientRect?.().width ?? 0;
    return Math.max(0, w - this.labelWidth());
  }

  /** Called once a second while the session is live, so that now moves. */
  tick() { if (this.live && !this.root.hidden) this.render(); }

  render() {
    if (this.root.hidden) return;
    if (this.press.defer()) return;
    const now = this.now();
    const agents = this.nodes.filter((n) => n.kind === 'agent');
    const ext = extent(this.nodes, now, this.live);
    const width = this.trackWidth();

    this.empty.hidden = agents.length > 0;
    this.body.hidden = agents.length === 0;
    this.axis.hidden = agents.length === 0;
    if (!agents.length) {
      this.empty.replaceChildren(mk('strong', null, 'No agents yet'),
        mk('span', null, 'This session has not delegated to a subagent. When it does, each one gets a row here.'));
      this.noteEl.hidden = true;
      this.nowLine.hidden = true;
      this.away.hidden = true;
      this.paintDrawer();
      return;
    }

    this.win = windowOf(ext, this.range, { follow: this.follow && this.live, end: this.end });
    const win = this.win;

    // The axis.
    this.axisTrack.replaceChildren(...(win ? ticks(win, width).map((t) => {
      const m = mk('span', 'tl-tick', clock(t.at, t.seconds));
      m.style.left = `${xOf(t.at, win, width)}px`;
      return m;
    }) : []));

    // The rows.
    // The rows are drawn again from the data each time; a keyboard reader's place among them is kept.
    const focused = this.rowsEl.contains?.(document.activeElement) ? document.activeElement.dataset?.key ?? null : null;
    const top = this.body.scrollTop;
    const ids = groupsOf(this.nodes, this.group).map((g) => g.id);
    const list = rows(this.nodes, {
      group: this.group, folded: foldedSet(ids, this.fold, this.all), expanded: this.all === true ? new Set(ids) : this.expanded, waiting: this.waiting,
      approvals: this.owned?.approvals ?? null, now,
    });
    this.lastRows = list;
    this.rowsEl.replaceChildren(...list.map((r) => this.#row(r, win, width)));
    this.body.scrollTop = top;
    if (focused) [...this.rowsEl.querySelectorAll('[data-key]')].find((el) => el.dataset.key === focused)?.focus();

    // Now: a line across the rows, while the session is live and now is on screen.
    const nowX = win ? xOf(now, win, width) : -1;
    this.nowLine.hidden = !this.live || !win || nowX < 0 || nowX > width + 1;
    if (!this.nowLine.hidden) {
      this.nowLine.style.left = `${this.labelWidth() + Math.min(nowX, width - 1)}px`;
      this.nowLine.dataset.label = `now ${clock(now)}`;
    }

    // Bars exist, and none of them is in the stretch on screen.
    const timed = agents.filter((n) => n.startedAt != null);
    const onScreen = this.rowsEl.querySelectorAll('.tl-bar').length;
    this.away.hidden = !(timed.length && onScreen === 0);
    if (!this.away.hidden) {
      const last = Math.max(...timed.map((n) => n.endedAt ?? n.updatedAt ?? n.startedAt));
      this.awayText.textContent = last < win.from
        ? `Nothing in this stretch of time. The last activity ended at ${clock(last)}.`
        : 'Nothing in this stretch of time.';
    }

    const note = waitNote(this.owned);
    this.noteEl.hidden = false;
    this.noteEl.textContent = note.text;
    this.noteEl.dataset.measured = String(note.measured);

    this.paintDrawer();
  }

  #bars(track, laneList, win, width) {
    const thin = laneList.length > 1;
    laneList.forEach((lane, li) => {
      for (const seg of lane) {
        const at = win ? place(seg, win, width) : null;
        if (!at) continue;
        const b = mk('button', `tl-bar${thin ? ' thin' : ''}`);
        b.type = 'button';
        b.dataset.tone = seg.tone;
        b.dataset.lane = String(li);
        b.dataset.key = `bar:${seg.id}:${seg.from}`;
        if (at.cutLeft) b.dataset.cutLeft = 'true';
        if (at.cutRight) b.dataset.cutRight = 'true';
        b.style.left = `${at.left}px`;
        b.style.width = `${at.width}px`;
        const node = this.nodes.find((n) => n.id === seg.id);
        b.setAttribute('aria-label', `${node ? shownType(node) : 'agent'}, ${seg.tone === 'wait' ? 'waiting for you' : (node?.status ?? '')}, ${clock(seg.from)} to ${clock(seg.to)}`);
        if (node && this.dimmed(node)) b.classList.add('dim');
        if (seg.id === this.selected) b.classList.add('on');
        b.addEventListener('click', (e) => { e.stopPropagation(); this.#choose(seg.id); });
        track.append(b);
        // Where a failed agent stopped is marked.
        if (seg.failedAt != null && !at.cutRight) {
          const x = mk('span', 'tl-x', '×');
          x.style.left = `${at.left + at.width}px`;
          x.dataset.lane = String(li);
          track.append(x);
        }
      }
    });
  }

  #row(r, win, width) {
    if (r.kind === 'more') {
      const row = mk('div', 'tl-row tl-more');
      const b = mk('button', 'tl-more-btn', `Show ${r.count} more in this ${this.group === 'run' ? 'run' : 'group'}`);
      b.type = 'button';
      b.addEventListener('click', () => { this.expanded.add(r.group); this.render(); });
      const lab = mk('div', 'tl-lab');
      if (r.indent) lab.classList.add('indent');
      lab.append(b);
      row.append(lab);
      return row;
    }

    const row = mk('div', `tl-row tl-${r.kind}`);
    const lab = mk(r.kind === 'merged' ? 'div' : 'button', 'tl-lab');
    if (r.indent) lab.classList.add('indent');
    lab.dataset.key = `row:${r.id}`;
    const track = mk('div', 'tl-track');

    if (r.kind === 'group') {
      lab.type = 'button';
      lab.setAttribute('aria-expanded', String(!r.folded));
      const chev = mk('span', 'tl-chev');
      chev.innerHTML = '<svg class="ic" viewBox="0 0 16 16" aria-hidden="true"><path d="M6 4l4 4-4 4"/></svg>';
      lab.append(chev, mk('span', 'tl-name', r.label), mk('span', 'row-fill'), mk('span', 'sub', r.sub));
      lab.addEventListener('click', () => {
        this.fold.set(r.id, !r.folded);
        this.render();
        this.#changed();
      });
      this.#bars(track, r.lanes, win, width);
    } else if (r.kind === 'merged') {
      const tile = this.hooks.tileOf?.(r.members[0]);
      if (tile) lab.append(tile);
      lab.append(mk('span', 'tl-name', r.label), mk('span', 'row-fill'), mk('span', 'sub', r.sub));
      lab.title = r.real ?? '';
      this.#bars(track, r.lanes, win, width);
      if (r.members.every((m) => this.dimmed(m))) row.classList.add('dim');
    } else {
      lab.type = 'button';
      const tile = this.hooks.tileOf?.(r.node);
      if (tile) lab.append(tile);
      const sub = mk('span', 'sub', r.sub);
      if (r.tone) sub.dataset.tone = r.tone;
      // The model the row's agent ran on, before its state.
      const mdl = modelOf(r.node);
      const badge = mk('span', 'tl-model', `${mdl.ran}${mdl.differs ? ' \u2260' : ''}`);
      badge.hidden = !mdl.ran;
      badge.title = mdl.title;
      lab.append(mk('span', 'tl-name', r.label), mk('span', 'row-fill'), badge, sub);
      lab.title = [hoverOf(r.node), mdl.ran ? mdl.title : null].filter(Boolean).join('\n');
      // One listener, on the row: the label is a button inside it, and its click arrives here too. Two
      // listeners chose the agent and un-chose it in the same click.
      row.addEventListener('click', () => this.#choose(r.id));
      if (r.timed) this.#bars(track, [r.bars], win, width);
      // No start was recorded, so there is nowhere to put a bar; the row says that instead of drawing one at zero.
      else track.append(mk('span', 'tl-untimed', 'no start time recorded'));
      if (r.id === this.selected) row.classList.add('on');
      if (this.dimmed(r.node)) row.classList.add('dim');
    }
    row.append(lab, track);
    return row;
  }

  #choose(id) {
    this.selected = this.selected === id ? null : id;
    this.render();
    this.hooks.onSelect?.(this.selected ? this.nodes.find((n) => n.id === this.selected) ?? null : null);
  }

  /** The drawer under the rows: the chosen agent, its task, its numbers, and the last thing that went wrong. */
  paintDrawer() {
    const n = this.selected ? this.nodes.find((x) => x.id === this.selected) : null;
    this.drawer.hidden = !n;
    if (!n) return;
    const now = this.now();
    const st = this.hooks.statusOf?.(n) ?? { word: n.status, tone: null };

    const left = mk('div', 'tl-d-main');
    const head = mk('div', 'tl-d-head');
    const tile = this.hooks.tileOf?.(n);
    if (tile) head.append(tile);
    const pill = mk('span', 'pill');
    const dot = mk('span', 'dot');
    dot.dataset.tone = st.tone ?? 'none';
    pill.append(dot, mk('span', null, st.word ?? 'State not measured'));
    const dname = mk('span', 'tl-d-name', shownType(n));
    dname.title = n.agentType ?? '';
    head.append(dname, pill);
    const dtask = mk('div', 'tl-d-task', n.description ?? '');
    dtask.title = n.description ?? '';
    left.append(head, dtask, mk('div', 'sub tl-d-facts', factsOf(n, now, this.hooks.fmt)));

    const mid = mk('div', 'tl-d-error');
    mid.append(mk('div', 'isec-h', 'Last error'));
    const detail = this.hooks.detailOf?.(n);
    if (!detail || detail.loading) {
      mid.append(mk('div', 'ihint', 'Reading the agent transcript…'));
    } else if (detail.measured === false) {
      const hint = mk('div', 'ihint');
      hint.append(mk('strong', null, 'Not measured'), mk('div', null, detail.reason || 'no reason given'));
      mid.append(hint);
    } else if (!detail.lastError) {
      mid.append(mk('div', 'ihint', 'None — no tool call in this agent\'s transcript came back as an error.'));
    } else {
      const e = detail.lastError;
      const text = mk('pre', 'tl-d-errtext', e.truncated ? `… ${(e.length - e.text.length).toLocaleString('en-US')} earlier characters not shown\n${e.text}` : (e.text || '(no output)'));
      const count = detail.errors ?? 0;
      const facts = [`${count} ${count === 1 ? 'error' : 'errors'}`];
      if (e.at != null) facts.push(`last at ${clock(e.at, true)}`);
      if (e.tool) facts.push(e.tool);
      mid.append(text, mk('div', 'sub', facts.join(' · ')));
    }

    const acts = mk('div', 'tl-d-acts');
    const show = mk('button', 'btn sm primary', 'Show on graph');
    show.type = 'button';
    show.addEventListener('click', () => this.hooks.onShowOnGraph?.(n));
    const open = mk('button', 'btn sm', 'Open conversation');
    open.type = 'button';
    open.addEventListener('click', () => this.hooks.onOpenConversation?.());
    const close = mk('button', 'btn icon sm ghost');
    close.type = 'button';
    close.setAttribute('aria-label', 'Close');
    close.innerHTML = '<svg class="ic" viewBox="0 0 16 16" aria-hidden="true"><path d="M4 4l8 8M12 4l-8 8"/></svg>';
    close.addEventListener('click', () => this.#choose(n.id));
    acts.append(show, open, close);

    this.drawer.replaceChildren(left, mid, acts);
  }
}

export { RANGES };
