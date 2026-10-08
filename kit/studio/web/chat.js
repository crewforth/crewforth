// Conversations with sessions the panel owns, and readings of the ones it does not.
//
// Each session gets a pane that keeps its own stream open whether or not it is
// on screen, so a session working in the background is still working when you
// come back to it — its progress is not a replay, it happened.
//
// Two sources describe the same reply: partial `content_block_delta` events
// while it is being written, and the complete `assistant` record once it is
// done. Rendering both would double every message, so deltas only ever feed a
// provisional bubble that the authoritative record replaces.
//
// What a message is made of — a delegation, a tool row and its summary, the
// strip above the conversation — is decided in convo.js. This file draws it.

import { renderMarkdown } from './md.js';
import {
  toolBlock, resultsIn, isDelegation, summaryOf, outputOf, delegationCard, reminderOf, headerOf, refusals,
} from './convo.js';

const el = (tag, cls, text) => {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text != null) n.textContent = text;
  return n;
};

/**
 * Options a reply is offering, if it is offering any.
 *
 * Exported so it can be tested without a DOM: the rule for when prose counts
 * as a question is the part worth pinning, and it is easy to get wrong in a
 * direction that puts buttons under every bulleted list.
 */
export function quickReplies(text) {
  if (!text) return [];
  // Only the tail of the message: an option list in the middle is discussion,
  // not the question being asked now.
  const lines = text.trimEnd().split('\n').slice(-14);
  const opts = [];
  for (const raw of lines) {
    const m = raw.match(/^\s*(?:[-*+]|\d+[.)])\s+(.+?)\s*$/);
    if (!m) continue;
    const label = m[1].replace(/\*\*(.+?)\*\*/g, '$1').replace(/`(.+?)`/g, '$1').trim();
    if (label.length >= 2 && label.length <= 80) opts.push(label);
  }
  // Two to five short options reads as a question. One is a statement, a dozen
  // is a report, and without a question mark it is neither.
  return (opts.length >= 2 && opts.length <= 5 && /\?/.test(text)) ? opts : [];
}

/* ========================================================== one session === */

class Pane {
  constructor(session, { api, headers, onChange, onPermissions, hooks = {}, readOnly = false }) {
    this.api = api;
    this.headers = headers;
    this.onChange = onChange;
    this.onPermissions = onPermissions ?? (() => {});
    // What the page lends a pane: who an agent is on the graph, and what the two ways out of a read-only
    // conversation do. A pane does not know the canvas or the navigator.
    this.hooks = hooks;
    this.readOnly = readOnly;
    this.session = session;
    this.id = session.sessionId;
    this.source = null;
    this.messages = [];
    this.streaming = null;
    this.permissions = [];
    this.unread = 0;
    this.contextTokens = null;
    this.toolRows = new Map();     // tool_use id -> { block, row, sum, out }
    this.cards = [];               // { block, node } for every delegation drawn
    this.refused = new Set();      // tool_use ids already said to have been refused after an allowance

    this.root = el('div', 'pane');

    this.headEl = el('div', 'pane-head');
    this.logEl = el('div', 'chat-log');

    // A request waiting in this session, said where the conversation is being read.
    this.remindEl = el('div', 'chat-remind');
    this.remindEl.hidden = true;
    this.remindText = el('span', 'chat-remind-text');
    const review = el('button', 'chat-review', 'Review');
    review.type = 'button';
    review.addEventListener('click', () => this.hooks.onReview?.(this));
    this.remindEl.append(el('span', 'dot'), this.remindText, review);
    this.remindEl.firstChild.dataset.tone = 'waiting';

    this.formEl = el('form', 'chat-form');
    this.inputEl = el('textarea', 'chat-input');
    this.inputEl.rows = 3;
    this.inputEl.placeholder = 'Message this session';
    this.inputEl.setAttribute('aria-label', 'Message this session');
    const formFoot = el('div', 'chat-form-foot');
    const send = el('button', 'btn sm primary chat-send', 'Send');
    send.type = 'submit';
    formFoot.append(el('span', 'sub', 'Enter to send · Shift+Enter for a new line'), el('span', 'row-fill'), send);
    this.formEl.append(this.inputEl, formFoot);

    this.roEl = el('div', 'chat-ro');
    this.roEl.hidden = true;

    this.root.append(this.headEl, this.logEl, this.remindEl, this.formEl, this.roEl);

    this.formEl.addEventListener('submit', (e) => { e.preventDefault(); this.send(); });
    this.inputEl.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); this.send(); }
    });

    if (readOnly) {
      this.formEl.hidden = true;
      this.roEl.hidden = false;
      this.root.classList.add('pane-readonly');
      this.paintReadOnly();
    } else {
      this.connect();
    }
    this.paintHead();
    this.loadHistory();
  }

  get visible() { return !this.root.hidden; }

  /**
   * What was said before this pane existed.
   *
   * A resumed session remembers its history — it will answer questions about
   * it — but its stream starts fresh, so continuing a conversation looked
   * exactly like starting one. An observed session has no stream at all, and
   * its whole conversation is history.
   */
  async loadHistory() {
    const from = this.readOnly ? this.id : this.session?.resumedFrom;
    if (!from) return;
    let conv;
    try {
      conv = await fetch(this.api(`/api/session/${encodeURIComponent(from)}/conversation`), { cache: 'no-store' })
        .then((r) => r.json());
    } catch (e) {
      this.note(`History not read: ${e.message}`, 'bad');
      return;
    }
    if (conv?.measured === false) { this.note(`History not measured — ${conv.reason}`, 'bad'); return; }

    const frag = document.createDocumentFragment();
    if (conv.truncated) {
      frag.append(el('div', 'chat-note', `${conv.total - conv.messages.length} earlier message(s) not shown`));
    }
    for (const m of conv.messages ?? []) frag.append(this.renderMessage(m, { quick: false }));
    if (!this.readOnly) {
      // A visible seam, so nobody reads the history as part of this run — and
      // named for which of the two things actually happened. A fork that calls
      // itself "continued" reads as "you are typing into that session", which
      // is the one thing it is not; a real continuation that calls itself a
      // fork undersells it.
      frag.append(el('div', 'chat-seam', this.session?.forked
        ? `— forked from ${from.slice(0, 8)} · a separate session; the original does not see this —`
        : `— continuing ${from.slice(0, 8)} · same session, same transcript —`));
    }
    this.logEl.prepend(frag);
    this.logEl.scrollTop = this.logEl.scrollHeight;
  }

  connect() {
    if (this.source) return;
    this.source = new EventSource(this.api(`/api/owned/${encodeURIComponent(this.id)}/events`));
    this.source.addEventListener('state', (e) => {
      try { this.session = JSON.parse(e.data); } catch { return; }
      this.paintState();
      this.onChange(this);
    });
    this.source.addEventListener('event', (e) => {
      let ev;
      try { ev = JSON.parse(e.data); } catch { return; }
      this.absorb(ev.rec);
    });
    this.source.onerror = () => { this.streamBroken = true; this.onChange(this); };
  }

  disconnect() {
    if (this.source) { this.source.close(); this.source = null; }
  }

  /* --------------------------------------------------------- ingestion */

  absorb(rec) {
    if (!rec) return;

    if (rec.type === 'stream_event') {
      const t = rec.event?.type;
      if (t === 'message_start') { this.streaming = { text: '' }; this.paintStreaming(); }
      else if (t === 'content_block_delta' && rec.event.delta?.type === 'text_delta') {
        if (!this.streaming) this.streaming = { text: '' };
        this.streaming.text += rec.event.delta.text ?? '';
        this.paintStreaming();
      }
      return;
    }

    // A subagent's text is forwarded with a parent id. It belongs to the graph,
    // not to this conversation — showing it here would read as the session
    // saying things it never said.
    if (rec.parent_tool_use_id) return;

    if (rec.type === 'permissions') {
      // The requests themselves are drawn by the approval dock, under the canvas: one place for every session,
      // whichever conversation is in front. This pane keeps the count for its tab.
      this.permissions = rec.pending ?? [];
      this.onPermissions(this, rec);
      this.onChange(this);
      return;
    }

    if (rec.type === 'user' && rec.message?.content) {
      const c = rec.message.content;
      // What a tool came back with arrives as a user record. It is not something the viewer said: it goes to
      // the row of the call it answers.
      for (const [id, result] of resultsIn(c)) this.setResult(id, result);
      const text = typeof c === 'string' ? c : c.filter((x) => x?.type === 'text').map((x) => x.text).join('');
      if (text.trim()) { this.clearPending(); this.push({ role: 'user', text }); }
      return;
    }

    if (rec.type === 'assistant' && Array.isArray(rec.message?.content)) {
      this.streaming = null;
      const blocks = [];
      for (const c of rec.message.content) {
        if (c?.type === 'text' && c.text?.trim()) blocks.push({ kind: 'text', text: c.text });
        else if (c?.type === 'tool_use') blocks.push(toolBlock(c));
      }
      if (blocks.length) {
        this.push({ role: 'assistant', blocks });
        if (!this.visible) { this.unread += 1; this.onChange(this); }
      }
      return;
    }

    if (rec.type === 'result') {
      this.streaming = null;
      this.paintStreaming();
      this.noteRefusals(rec.permission_denials);
      return;
    }
    if (rec.type === 'fault' || rec.type === 'stderr') this.note(rec.reason ?? rec.text, 'bad');
  }

  push(msg) {
    for (const q of this.logEl.querySelectorAll('.quick')) q.remove();
    this.messages.push(msg);
    this.logEl.append(this.renderMessage(msg));
    this.paintStreaming();
    this.scroll();
  }

  /* --------------------------------------------------------- rendering */

  renderMessage(msg, { quick = true } = {}) {
    const wrap = el('div', `msg msg-${msg.role}`);

    if (msg.role === 'user') {
      wrap.append(el('div', 'msg-body msg-text', msg.text));
      return wrap;
    }

    wrap.append(el('div', 'msg-role', 'Session'));
    const body = el('div', 'msg-body');
    for (const b of msg.blocks) {
      if (b.kind === 'text') {
        const md = el('div', 'md');
        md.innerHTML = renderMarkdown(b.text);
        body.append(md);
      } else if (isDelegation(b)) {
        body.append(this.renderDelegation(b));
      } else {
        body.append(this.renderTool(b));
      }
    }
    wrap.append(body);

    // Options are offered on the reply that is waiting for an answer, not on every list in the history.
    if (quick && !this.readOnly) {
      const last = msg.blocks?.filter((b) => b.kind === 'text').pop();
      const opts = quickReplies(last?.text);
      if (opts.length) {
        const row = el('div', 'quick');
        for (const o of opts) {
          const b = el('button', 'btn sm quick-btn', o);
          b.type = 'button';
          b.addEventListener('click', () => { row.remove(); this.sendText(o); });
          row.append(b);
        }
        row.append(el('span', 'sub quick-hint', 'Clicking an option sends it as your reply.'));
        wrap.append(row);
      }
    }
    return wrap;
  }

  /** A tool call on one line: the tool, what it was run on, and how it ended. The output opens under it. */
  renderTool(block) {
    const box = el('div', 'tool');
    const row = el('button', 'tool-row');
    row.type = 'button';
    row.setAttribute('aria-expanded', 'false');
    const sum = el('span', 'tool-sum');
    row.append(el('span', 'tool-name', block.name));
    if (block.label) row.append(el('span', 'tool-label', String(block.label).slice(0, 200)));
    row.append(sum);
    const out = el('pre', 'tool-out');
    out.hidden = true;
    row.addEventListener('click', () => {
      const text = outputOf(block);
      // A call that has not come back has nothing to open, and says which it is rather than opening an empty box.
      out.textContent = text ?? (this.readOnly ? 'Output not read from the transcript.' : 'Not returned yet.');
      out.hidden = !out.hidden;
      row.setAttribute('aria-expanded', String(!out.hidden));
    });
    box.append(row, out);
    const entry = { block, row, sum, out };
    if (block.id) this.toolRows.set(block.id, entry);
    this.paintTool(entry);
    return box;
  }

  paintTool({ block, row, sum, out }) {
    const s = summaryOf(block);
    row.dataset.state = s.state;
    sum.textContent = s.text ?? '';
    sum.hidden = s.text == null;
    if (!out.hidden) out.textContent = outputOf(block) ?? '';
  }

  /** Say which calls were allowed in the dock and refused by Claude Code after it. Each is said once. */
  noteRefusals(denials) {
    const list = refusals(
      denials,
      (toolUseId, toolName) => !this.refused.has(toolUseId) && Boolean(this.hooks.wasAllowed?.(this.id, toolUseId, toolName)),
      (toolUseId) => this.toolRows.get(toolUseId)?.block.result ?? null,
    );
    for (const r of list) {
      this.refused.add(r.id);
      const row = this.toolRows.get(r.id)?.row;
      if (row) row.dataset.state = 'refused';
      this.note(r.text, 'bad');
    }
  }

  /** A tool's result has arrived for a call already on screen. */
  setResult(id, result) {
    const entry = this.toolRows.get(id);
    if (!entry) return;
    entry.block.result = result;
    this.paintTool(entry);
  }

  /** The session handing work to an agent: a card that goes to that agent on the graph. */
  renderDelegation(block) {
    const node = el('button', 'deleg');
    node.type = 'button';
    node.addEventListener('click', () => {
      const card = delegationCard(block, this.hooks.agentsOf?.(this.id));
      if (card.agentId) this.hooks.onAgent?.(this, card.agentId);
    });
    const entry = { block, node };
    this.cards.push(entry);
    this.paintCard(entry);
    return node;
  }

  paintCard({ block, node }) {
    const card = delegationCard(block, this.hooks.agentsOf?.(this.id));
    const sig = `${card.type}|${card.task}|${card.agentId}|${card.status}`;
    if (node.sig === sig) return;
    node.sig = sig;
    const text = el('span', 'deleg-text');
    text.append(el('span', 'deleg-type', card.type), el('span', 'deleg-task', card.task));
    text.title = [card.real, card.task].filter(Boolean).join('\n');
    const parts = [];
    const tile = card.agentId ? this.hooks.tileOf?.(this.id, card.agentId) : null;
    if (tile) parts.push(tile);
    parts.push(text);
    // The agent's state is the graph's. Before the graph has seen the agent there is none to show.
    const st = card.agentId ? this.hooks.statusOf?.(this.id, card.agentId) : null;
    if (st?.word) {
      const pill = el('span', 'pill');
      const d = el('span', 'dot');
      d.dataset.tone = st.tone ?? 'none';
      pill.append(d, el('span', null, st.word));
      parts.push(pill);
    }
    node.replaceChildren(...parts);
    node.disabled = !card.agentId;
    node.title = card.agentId ? 'Show this agent on the graph' : 'This agent is not on the graph being shown';
  }

  /** The graph moved: the cards say what their agents are doing now. */
  refreshAgents() { for (const c of this.cards) this.paintCard(c); }

  /** Which of this session's tool calls are waiting on the viewer. */
  setWaiting(items) {
    const text = reminderOf(items);
    this.remindEl.hidden = !text;
    this.remindText.textContent = text ?? '';
  }

  setContext(tokens) {
    if (tokens === this.contextTokens) return;
    this.contextTokens = tokens;
    this.paintHead();
  }

  paintStreaming() {
    let node = this.logEl.querySelector('.msg-streaming');
    if (!this.streaming) { node?.remove(); return; }
    if (!node) {
      node = el('div', 'msg msg-assistant msg-streaming');
      node.append(el('div', 'msg-role', 'Session'));
      node.append(el('div', 'msg-body'));
      this.logEl.append(node);
    }
    const body = node.querySelector('.msg-body');
    if (this.streaming.text) {
      body.textContent = this.streaming.text;
      body.classList.add('msg-text');
    } else {
      body.replaceChildren(el('span', 'thinking', 'thinking…'));
    }
    this.scroll();
  }

  /** The strip above the conversation: started here or read only, the mode, how far it has gone, and Stop. */
  paintHead() {
    const s = this.session;
    const h = headerOf(s, { readOnly: this.readOnly, contextTokens: this.contextTokens });
    const badge = el('span', 'pill pane-badge');
    const d = el('span', 'dot');
    d.dataset.tone = h.tone;
    badge.append(d, el('span', null, h.badge));
    const parts = [badge];
    for (const p of h.parts) parts.push(el('span', 'sub', p));
    if (h.ungated) {
      const warn = el('span', 'pill pane-ungated', 'No approval gate');
      warn.title = 'This session was started without the approval gate: its tool calls do not wait for you.';
      parts.push(warn);
    }
    parts.push(el('span', 'row-fill'));
    if (!this.readOnly && s?.costUsd) {
      const cost = el('span', 'sub pane-cost', `$${s.costUsd.toFixed(4)}`);
      cost.title = 'What this session has cost, as the CLI reported it';
      parts.push(cost);
    }
    // Stopping ends the process. It is offered for as long as there is one.
    if (!this.readOnly && s && s.state !== 'exited' && s.state !== 'failed') {
      const stop = el('button', 'btn sm chat-stop');
      stop.type = 'button';
      stop.innerHTML = '<svg class="ic" viewBox="0 0 16 16" aria-hidden="true"><rect x="4" y="4" width="8" height="8" rx="1.5"/></svg>';
      stop.append(el('span', null, 'Stop'));
      stop.addEventListener('click', () => this.stop());
      parts.push(stop);
    }
    this.headEl.replaceChildren(...parts);
  }

  /**
   * The foot of a conversation Studio only reads: why there is no message box, and the two ways on.
   *
   * What "Continue here" does depends on something this page learns only by doing it: a session nothing else
   * holds is continued itself; one still open somewhere is copied. Both are said, because a copy that reads as
   * "you are now typing into that session" is the one thing it is not.
   */
  paintReadOnly() {
    const lead = el('p', 'chat-ro-lead');
    lead.append(el('strong', null, 'This session was not started here.'),
      ' Studio can read it but cannot write to it or answer its approvals.');

    const cont = el('button', 'btn sm primary', 'Continue here');
    cont.type = 'button';
    cont.addEventListener('click', () => this.hooks.onContinue?.(this, cont));
    const contRow = el('div', 'chat-ro-row');
    contRow.append(cont, el('span', 'sub',
      'Continues it in Studio. If it is still open somewhere else, Studio starts a copy instead: '
      + 'the original does not see this, and messages here never reach your terminal.'));

    const term = el('button', 'btn sm', 'Open in terminal');
    term.type = 'button';
    term.addEventListener('click', (e) => { e.stopPropagation(); this.hooks.onTerminal?.(this, term); });
    const line = el('code', 'chat-ro-cmd');
    const termText = el('span', 'sub');
    termText.append('Shows the command first, then opens a terminal: ', line);
    const termRow = el('div', 'chat-ro-row');
    termRow.append(term, termText);

    this.roEl.replaceChildren(lead, contRow, termRow);

    // The command is the server's, read before anything runs. One that could not be worked out is said so.
    fetch(this.api(`/api/session/${encodeURIComponent(this.id)}/terminal`), { cache: 'no-store' })
      .then((r) => r.json())
      .then((r) => { line.textContent = r?.plan?.line ?? 'not measured — no working directory recorded'; })
      .catch((e) => { line.textContent = `not read — ${e.message}`; });
  }

  paintState() {
    const s = this.session;
    const dead = s.state === 'exited' || s.state === 'failed';
    this.formEl.hidden = false;
    this.inputEl.disabled = dead;
    this.paintHead();
  }

  note(text, kind = '') { this.logEl.append(el('div', `chat-note ${kind}`, text)); this.scroll(); }

  scroll() {
    // Only follow the tail when the reader is already at it, so scrolling back
    // through a long reply is not yanked forward by the next token.
    const near = this.logEl.scrollHeight - this.logEl.scrollTop - this.logEl.clientHeight < 120;
    if (near) this.logEl.scrollTop = this.logEl.scrollHeight;
  }

  pending(text) {
    this.clearPending();
    const wrap = el('div', 'msg msg-user msg-pending');
    wrap.append(el('div', 'msg-body msg-text', text));
    this.logEl.append(wrap);
    this.scroll();
  }

  clearPending() { this.logEl.querySelector('.msg-pending')?.remove(); }

  /* ------------------------------------------------------------ actions */

  send() {
    const text = this.inputEl.value.trim();
    if (!text) return null;
    this.inputEl.value = '';
    return this.sendText(text);
  }

  async sendText(text) {
    // No optimistic bubble. The session is started with --replay-user-messages,
    // so it echoes what it actually received; drawing our own copy as well
    // printed every message twice.
    this.pending(text);

    const res = await fetch(this.api(`/api/owned/${encodeURIComponent(this.id)}/message`), {
      method: 'POST',
      headers: { 'content-type': 'application/json', ...this.headers },
      body: JSON.stringify({ text }),
    }).then((r) => r.json()).catch((e) => ({ ok: false, reason: e.message }));

    if (!res.ok) { this.clearPending(); this.note(`Not sent: ${res.reason}`, 'bad'); }
    else { this.session = res.session; this.paintState(); this.onChange(this); }
    return res;
  }

  async stop() {
    await fetch(this.api(`/api/owned/${encodeURIComponent(this.id)}/stop`), {
      method: 'POST', headers: this.headers,
    }).catch(() => {});
  }
}

/* ============================================================== the tabs === */

export class Chat {
  /**
   * @param hooks what the page lends the conversation: `nameOf(sessionId)`, `agentsOf(sessionId)`,
   *              `tileOf(sessionId, agentId)`, `statusOf(sessionId, agentId)`, `onAgent(pane, agentId)`,
   *              `onReview(pane)`, `onContinue(pane, button)`, `onTerminal(pane, button)`
   */
  constructor(root, { api, headers, hooks = {} }) {
    this.root = root;
    this.api = api;
    this.headers = headers;
    this.hooks = hooks;
    this.panes = new Map();
    this.activeId = null;
    this.onActivate = () => {};
    // (pane, { pending }) — a session's waiting requests changed.
    this.onPermissions = () => {};

    this.root.innerHTML = `
      <div class="chat-head">
        <div class="tabs" role="tablist" aria-label="Conversations"></div>
        <button class="btn icon sm ghost chat-grow" type="button" aria-label="Widen the conversation" title="Widen the conversation">
          <svg class="ic" viewBox="0 0 16 16" aria-hidden="true"><path d="M9 4l-4 4 4 4M13 4l-4 4 4 4"/></svg>
        </button>
      </div>
      <div class="panes"></div>`;

    this.tabsEl = this.root.querySelector('.tabs');
    this.panesEl = this.root.querySelector('.panes');
    this.growEl = this.root.querySelector('.chat-grow');
    this.onGrow = () => {};
    this.growEl.addEventListener('click', () => this.onGrow());
  }

  get active() { return this.activeId ? this.panes.get(this.activeId) : null; }
  get ids() { return [...this.panes.keys()]; }

  async start({ cwd, model, permissionMode, resume }) {
    const res = await fetch(this.api('/api/owned'), {
      method: 'POST',
      headers: { 'content-type': 'application/json', ...this.headers },
      body: JSON.stringify({ cwd, model, permissionMode, resume }),
    });
    const body = await res.json().catch(() => ({ ok: false, reason: 'bad response' }));
    if (!body.ok) return { ok: false, reason: body.reason };
    this.open(body.session);
    return { ok: true, session: body.session };
  }

  /** An observed session, shown but not driven. */
  openReadOnly(sessionId, title) {
    let pane = this.panes.get(sessionId);
    if (!pane) {
      pane = new Pane(
        { sessionId, state: 'observed', permissionMode: 'read-only', gated: false, title },
        { api: this.api, headers: this.headers, hooks: this.hooks, onChange: () => this.paintTabs(), readOnly: true },
      );
      this.panesEl.append(pane.root);
      this.panes.set(sessionId, pane);
    }
    this.activate(sessionId);
    return pane;
  }

  open(session) {
    let pane = this.panes.get(session.sessionId);
    // Continuing a session in place keeps its id. The pane that was only reading it has no stream and no way
    // to send, so it is replaced: left as it was, the session would be owned and still say "read only".
    if (pane?.readOnly) {
      pane.disconnect();
      pane.root.remove();
      this.panes.delete(session.sessionId);
      pane = null;
    }
    if (!pane) {
      pane = new Pane(session, {
        api: this.api, headers: this.headers, hooks: this.hooks, onChange: () => this.paintTabs(),
        onPermissions: (p, rec) => this.onPermissions(p, rec),
      });
      this.panesEl.append(pane.root);
      this.panes.set(session.sessionId, pane);
    }
    this.activate(session.sessionId);
    return pane;
  }

  activate(id) {
    if (!this.panes.has(id)) return;
    this.activeId = id;
    for (const [pid, p] of this.panes) {
      p.root.hidden = pid !== id;
      if (pid === id) p.unread = 0;
    }
    this.paintTabs();
    this.active?.inputEl?.focus();
    this.onActivate(id);
  }

  close(id) {
    const pane = this.panes.get(id);
    if (!pane) return;
    // Closing a tab closes the view, not the session: it keeps running and can
    // be reopened from the sidebar. Stopping is a separate, explicit act.
    pane.disconnect();
    pane.root.remove();
    this.panes.delete(id);
    if (this.activeId === id) {
      const next = this.ids[0] ?? null;
      this.activeId = null;
      if (next) this.activate(next); else { this.paintTabs(); this.onActivate(null); }
    } else {
      this.paintTabs();
    }
  }

  /** The graph of one session moved: its pane's delegation cards and context figure follow. */
  refresh(sessionId, { contextTokens = null } = {}) {
    const pane = this.panes.get(sessionId);
    if (!pane) return;
    pane.refreshAgents();
    if (contextTokens != null) pane.setContext(contextTokens);
  }

  /** What is waiting on the viewer, as the approval queue has it: each pane is told its own share. */
  setWaiting(queue) {
    for (const [id, pane] of this.panes) pane.setWaiting((queue ?? []).filter((r) => r.sessionId === id));
  }

  paintTabs() {
    const frag = document.createDocumentFragment();
    for (const [id, p] of this.panes) {
      const tab = el('button', 'tab');
      tab.type = 'button';
      tab.setAttribute('role', 'tab');
      tab.setAttribute('aria-selected', String(id === this.activeId));
      const dot = el('span', 'tab-dot');
      dot.dataset.state = p.session?.state ?? 'unknown';
      tab.append(dot);
      // The name the navigator gives the session; its id only when it has none yet.
      const name = this.hooks.nameOf?.(id) ?? p.session?.title ?? shortId(id);
      tab.append(el('span', 'tab-name', String(name).slice(0, 28)));
      if (p.permissions?.length) tab.append(el('span', 'tab-badge warn', String(p.permissions.length)));
      else if (p.unread) tab.append(el('span', 'tab-badge', String(p.unread)));
      tab.title = `${name}\n${id}\n${p.readOnly ? 'read only' : `${p.session?.state ?? ''} · ${p.session?.permissionMode ?? ''}`}`;
      tab.addEventListener('click', () => this.activate(id));

      const x = el('span', 'tab-x', '×');
      x.title = 'Close this tab — the session keeps running';
      x.addEventListener('click', (e) => { e.stopPropagation(); this.close(id); });
      tab.append(x);
      frag.append(tab);
    }
    this.tabsEl.replaceChildren(frag);
    for (const p of this.panes.values()) p.paintHead();
  }
}

function shortId(id) { return id.slice(0, 8); }
