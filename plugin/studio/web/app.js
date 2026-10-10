// Crewforth Studio — wiring.
//
// One rule runs through the rendering: "not measured" and "nothing running"
// are different facts and never share a screen state. An empty list because
// the CLI is missing would read as a quiet, healthy machine, which is exactly
// the kind of lie this panel exists to stop telling.

import { migrateStorage } from './storage-migrate.js';
import { initTheme } from './theme.js';
import { Canvas } from './canvas.js';
import { renderMarkdown } from './md.js';
import { Chat } from './chat.js';
import {
  summaryChips, sessionStatus, sessionName, sessionSub, ago, matchesSession, highlight, badgeFor,
  liveSessions, machines, seenAgo, isFirstRun,
} from './nav.js';
import { liveness, offlineNote } from './liveness.js';
import { attention, settle, AUTO } from './graph-plan.js';
import { summaryRows, usageLine, costNote } from './usage.js';
import { ServerClock, queue, settled, terminalWait, OUTCOME_WORD } from './approvals.js';
import { Dock } from './dock.js';
import { NewSession } from './newsession.js';
import { Timeline } from './timeline.js';
import { List } from './list.js';
import { defaultView, narrowWarning } from './list-plan.js';
import { fitLevel, runsOver } from './toolbar-fit.js';
import { roleName, shownType, modelFamily } from './names.js';
import { shortcutOf } from './keys.js';
import { fmtDuration, fmtTokens, tiles, timeLine, rightNow, skillsOf, delegatedBy, reportOf, backgroundLines, modelLines, TABS as INSPECTOR_TABS, TAB_WORD } from './inspect.js';

const FLEET_POLL_MS = 2000;
const SESSION_POLL_MS = 5000;

const el = {
  fleet: document.getElementById('fleet'),
  sessions: document.getElementById('sessions'),
  reach: document.getElementById('reach'),
  otherMachines: document.getElementById('other-machines'),
  liveCount: document.getElementById('live-count'),
  filter: document.getElementById('filter'),
  chat: document.getElementById('chat'),
  chatSplit: document.getElementById('chat-split'),
  resizer: document.getElementById('resizer'),
  sideHide: document.getElementById('side-hide'),
  sideShow: document.getElementById('side-show'),
  rail: document.getElementById('side-rail'),
  home: document.getElementById('home'),
  bar: document.querySelector('.bar'),
  crumb: document.getElementById('crumb'),
  fullscreen: document.getElementById('fullscreen'),
  newSession: document.getElementById('new-session'),
  summary: document.getElementById('graph-summary'),
  pulse: document.getElementById('pulse'),
  foot: document.getElementById('foot-note'),
  theme: document.getElementById('theme'),
  inspector: document.getElementById('inspector'),
  toast: document.getElementById('toast'),
  attention: document.getElementById('attention'),
  dock: document.getElementById('dock'),
  terminalWait: document.getElementById('terminal-wait'),
  newPanel: document.getElementById('new-panel'),
  tbGroup: document.getElementById('tb-group'),
  tbDensity: document.getElementById('tb-density'),
  tbShow: document.getElementById('tb-show'),
  tbExpand: document.getElementById('tb-expand'),
  tbFold: document.getElementById('tb-fold'),
  tbZoomOut: document.getElementById('tb-zoom-out'),
  tbZoom: document.getElementById('tb-zoom'),
  tbZoomIn: document.getElementById('tb-zoom-in'),
  tbFit: document.getElementById('tb-fit'),
  tbReset: document.getElementById('tb-reset'),
  canvasEl: document.getElementById('canvas'),
  timeline: document.getElementById('timeline'),
  viewGraph: document.getElementById('view-graph'),
  viewTimeline: document.getElementById('view-timeline'),
  viewList: document.getElementById('view-list'),
  list: document.getElementById('list'),
  firstRun: document.getElementById('first-run'),
  stageNote: document.getElementById('stage-note'),
  stage: document.querySelector('.stage'),
  phoneHead: document.getElementById('phone-head'),
  menuBtn: document.getElementById('menu-btn'),
  tbOptions: document.getElementById('tb-options'),
  toolbar: document.querySelector('.toolbar'),
  tbFollow: document.getElementById('tb-follow'),
  tbRangeOut: document.getElementById('tb-range-out'),
  tbRange: document.getElementById('tb-range'),
  tbRangeIn: document.getElementById('tb-range-in'),
  menu: document.getElementById('menu'),
};

const token = new URLSearchParams(location.search).get('token');
const api = (p) => (token ? `${p}${p.includes('?') ? '&' : '?'}token=${encodeURIComponent(token)}` : p);

// When the server was last heard from, for the Live indicator. A request that does not complete is the
// connection failing; one that completes with an error status is the server answering, and is neither.
const heard = { okAt: null, failed: false };
const heardNow = () => { heard.okAt = Date.now(); heard.failed = false; };

const getJson = async (p) => {
  let r;
  try {
    r = await fetch(api(p), { cache: 'no-store' });
  } catch (e) {
    heard.failed = true;
    throw e;
  }
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  const body = await r.json();
  heardNow();
  return body;
};

/* ---------------------------------------------------------------- theme */

try { migrateStorage(localStorage); } catch { /* blocked storage */ }
const store = {
  get(k) { try { return localStorage.getItem(k); } catch { return null; } },
  set(k, v) { try { localStorage.setItem(k, v); } catch { /* blocked storage */ } },
};

// Handed the raw storage and not `store`: theme.js guards its own reads and
// writes, and a storage that cannot even be named is replaced by one that
// remembers nothing.
const systemLight = window.matchMedia('(prefers-color-scheme: light)');
let themeStorage = { getItem: () => null, setItem: () => {} };
try { themeStorage = localStorage; } catch { /* blocked storage */ }
const relabelTheme = initTheme(document.documentElement, el.theme, themeStorage, () => systemLight.matches);
systemLight.addEventListener('change', relabelTheme);

/* --------------------------------------------------------------- panels
   Three columns and two dividers. Each width is the user's, remembered, and
   clamped so neither side panel can be dragged to nothing by accident or made
   to swallow the graph. Collapsing is a separate, deliberate act with its own
   control. */

const PANEL = {
  side: { min: 170, max: 620, def: 272, wide: 460, varName: '--side-w', key: 'crewforth-studio-side-w' },
  chat: { min: 280, max: 900, def: 480, wide: 720, varName: '--chat-w', key: 'crewforth-studio-chat-w' },
  // The inspector's default is the stylesheet's own --inspector-w.
  inspector: { min: 280, max: 720, def: 344, varName: '--inspector-w', key: 'crewforth-studio-inspector-w' },
};

function setPanel(which, px, persist = true) {
  const p = PANEL[which];
  const w = Math.round(Math.min(p.max, Math.max(p.min, px)));
  document.documentElement.style.setProperty(p.varName, `${w}px`);
  if (persist) store.set(p.key, String(w));
  return w;
}

for (const which of Object.keys(PANEL)) {
  setPanel(which, Number(store.get(PANEL[which].key)) || PANEL[which].def, false);
}

const shell = document.querySelector('.shell');

// `refit` is off for the first call, which restores the remembered state before
// the canvas exists. `typeof canvas` is not a guard here: a const in its
// temporal dead zone throws on typeof too, which is what took the whole page
// down rather than skipping one re-fit.
//
// Below 1024px the navigator is its rail and opens over the canvas. That is the
// window's doing, not the viewer's choice, so nothing done in that band is
// remembered: widening the window brings back whatever was chosen at a width
// where there was a choice to make.
const railBand = window.matchMedia('(max-width: 1023px)');

function setSideHidden(hidden, refit = true, persist = !railBand.matches) {
  shell.classList.toggle('no-side', hidden);
  el.rail.hidden = !hidden;
  if (persist) store.set('crewforth-studio-side-hidden', hidden ? '1' : '0');
  if (refit) canvas.fitIfUntouched();
}
const applyRailBand = (refit) => setSideHidden(
  railBand.matches || store.get('crewforth-studio-side-hidden') === '1', refit, false,
);
applyRailBand(false);
railBand.addEventListener('change', () => applyRailBand(true));

function dragPanel(handle, which, edge) {
  let drag = null;
  handle.addEventListener('pointerdown', (e) => {
    if (e.button !== 0) return;
    drag = { px: e.clientX, w: parseInt(getComputedStyle(document.documentElement).getPropertyValue(PANEL[which].varName), 10) || PANEL[which].def };
    handle.setPointerCapture(e.pointerId);
    handle.classList.add('dragging');
    document.body.classList.add('resizing');
  });
  handle.addEventListener('pointermove', (e) => {
    if (!drag) return;
    // The right-hand panel grows as the pointer moves left, so its delta is
    // inverted. Sharing one handler without this made the conversation shrink
    // when it was dragged open.
    const delta = (e.clientX - drag.px) * (edge === 'right' ? -1 : 1);
    setPanel(which, drag.w + delta);
  });
  const stop = () => {
    if (!drag) return;
    drag = null;
    handle.classList.remove('dragging');
    document.body.classList.remove('resizing');
    canvas.fitIfUntouched();
  };
  handle.addEventListener('pointerup', stop);
  handle.addEventListener('pointercancel', stop);
  handle.addEventListener('dblclick', () => { setPanel(which, PANEL[which].def); canvas.fitIfUntouched(); });
  handle.addEventListener('keydown', (e) => {
    const cur = parseInt(getComputedStyle(document.documentElement).getPropertyValue(PANEL[which].varName), 10) || PANEL[which].def;
    const step = edge === 'right' ? -16 : 16;
    if (e.key === 'ArrowLeft') { setPanel(which, cur + step); e.preventDefault(); }
    if (e.key === 'ArrowRight') { setPanel(which, cur - step); e.preventDefault(); }
  });
}

dragPanel(el.resizer, 'side', 'left');
dragPanel(el.chatSplit, 'chat', 'right');

// The inspector is filled again whenever its agent changes; its handle is made once and put back each time, so a
// drag is not cut short by a poll.
const inspectorSplit = document.createElement('div');
inspectorSplit.className = 'resizer inspector-split';
inspectorSplit.setAttribute('role', 'separator');
inspectorSplit.setAttribute('aria-orientation', 'vertical');
inspectorSplit.setAttribute('aria-label', 'Resize inspector');
inspectorSplit.tabIndex = 0;
dragPanel(inspectorSplit, 'inspector', 'right');

/* ------------------------------------------------------------ full screen
   The browser's own, so it hides the browser too — a panel meant to be watched
   while work runs should be able to take the whole display. The panels keep
   their state: what was open stays open, and `[` and `]` still fold the navigator. */

async function toggleFullscreen() {
  try {
    if (document.fullscreenElement) await document.exitFullscreen();
    else await document.documentElement.requestFullscreen();
  } catch (e) {
    // Denied by policy, or unsupported. Say so rather than appear inert.
    el.foot.textContent = `full screen refused: ${e?.message ?? e}`;
  }
}

el.fullscreen.addEventListener('click', toggleFullscreen);

document.addEventListener('fullscreenchange', () => {
  const on = Boolean(document.fullscreenElement);
  el.fullscreen.classList.toggle('on', on);
  el.fullscreen.title = on ? 'Leave full screen (f or Esc)' : 'Full screen (f)';
  el.fullscreen.setAttribute('aria-label', on ? 'Leave full screen' : 'Full screen');
  canvas.fitIfUntouched();
});

// `f` toggles it, unless something is being typed into.
document.addEventListener('keydown', (e) => {
  if (e.key !== 'f' || e.metaKey || e.ctrlKey || e.altKey) return;
  const t = e.target;
  if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.isContentEditable)) return;
  e.preventDefault();
  toggleFullscreen();
});

el.sideHide.addEventListener('click', () => setSideHidden(true));
el.sideShow.addEventListener('click', () => setSideHidden(false));

/* ----------------------------------------------------------------- chat
   Write endpoints need the token and a header that a cross-origin page cannot
   attach without a preflight this server never answers. */

const writeHeaders = { 'x-crew-studio': '1', ...(token ? { authorization: `Bearer ${token}` } : {}) };
// What the conversation is lent from the rest of the page: the navigator's names, the graph's agents, and the
// two ways out of a conversation Studio only reads. It knows none of those places itself.
const nodeOf = (sessionId, agentId) => (sessionId === current ? canvas.nodes.get(agentId) ?? null : null);
const chat = new Chat(el.chat, {
  api,
  headers: writeHeaders,
  hooks: {
    nameOf: (id) => sessionLabel(id),
    agentsOf: (id) => (id === current ? lastNodes : null),
    tileOf: (id, agentId) => { const n = nodeOf(id, agentId); return n ? canvas.tileFor(n) : null; },
    statusOf: (id, agentId) => { const n = nodeOf(id, agentId); return n ? canvas.statusOf(n) : null; },
    // A delegation card goes to its agent: the graph selects it, and the inspector takes the panel.
    onAgent: (pane, agentId) => {
      if (pane.id !== current) selectSession(pane.id);
      goTo(agentId);
    },
    // The reminder in the conversation leads to the dock, where the answer is given.
    onReview: () => el.dock.focus(),
    // Did this page allow that call? Asked when Claude Code reports having refused it anyway.
    wasAllowed: (sessionId, toolUseId, toolName) =>
      (outcomes.get(sessionId) ?? []).some((o) => o.toolUseId === toolUseId && o.outcome.startsWith('allowed'))
      || (owned.get(sessionId)?.alwaysAllowed ?? []).includes(toolName),
    onContinue: (pane, button) => continueHere(button, pane.id),
    onTerminal: (pane, button) => offerTerminal(button, pane.id),
  },
});

const ownedIds = new Set();

/* The right-hand panel is one thing at a time: the inspector, a conversation, or New session. Side by side with
   the navigator they left the graph a third of the window; one at a time, the canvas keeps its width and the
   way back is always one click — "Open conversation" from the inspector, a card or a node from the conversation.
   Conversations that are not in front keep streaming. */
let right = 'none';
const restRight = () => (chat.ids.length ? 'conversation' : 'none');
function setRight(which) {
  right = which;
  const column = which === 'conversation' || which === 'new';
  el.chat.hidden = which !== 'conversation';
  el.newPanel.hidden = which !== 'new';
  el.chatSplit.hidden = !column;
  shell.classList.toggle('no-chat', !column);
  el.inspector.hidden = which !== 'inspector';
  canvas.fitIfUntouched();
}

// The conversation's own widen control lives in its header, beside the tabs.
chat.onGrow = () => {
  const cur = parseInt(getComputedStyle(document.documentElement).getPropertyValue('--chat-w'), 10) || PANEL.chat.def;
  setPanel('chat', Math.abs(cur - PANEL.chat.wide) < 24 ? PANEL.chat.def : PANEL.chat.wide);
  canvas.fitIfUntouched();
};

// Switching tabs points the canvas at that session too: the graph and the
// conversation are two views of one thing.
chat.onActivate = (sessionId) => {
  // The last tab closing gives the panel back; a tab coming forward takes it.
  if (sessionId) setRight('conversation');
  else if (right === 'conversation') setRight('none');
  // Activating a tab is not a claim of ownership. It used to add the id here,
  // which meant opening a read-only conversation marked that session as one the
  // panel had started — and every later attempt to open it went down the owned
  // path, got a 404, and gave up without saying anything.
  if (sessionId) selectSession(sessionId);
};

/** Bring a session's conversation forward, however the panel can reach it. */
function openConversation(sessionId) {
  if (chat.activeId === sessionId) { setRight('conversation'); return; }
  if (ownedIds.has(sessionId)) { openOwned(sessionId); return; }
  openReadOnlyPane(sessionId);
}

function openReadOnlyPane(sessionId) {
  const known = findSessionRow(sessionId);
  chat.openReadOnly(sessionId, known ? sessionName(known.session, labels.all()) : null);
}

async function openOwned(sessionId) {
  if (chat.panes.has(sessionId)) { chat.activate(sessionId); return true; }
  try {
    const r = await getJson(`/api/owned/${encodeURIComponent(sessionId)}`);
    if (!r.session) throw new Error('not an owned session');
    chat.open(r.session);
    return true;
  } catch {
    // Reaped, or never ours. Either way the conversation is still readable, and
    // falling through to that beats leaving the panel blank with no reason.
    ownedIds.delete(sessionId);
    openReadOnlyPane(sessionId);
    return false;
  }
}

// Continuing a conversation the panel did not start. A session nothing else holds is continued itself; one
// still open in a terminal somewhere is copied instead, so it is never written to by two things at once.
// Offered on the session in the inspector and at the foot of its read-only conversation.
async function continueHere(button, from = current) {
  if (!from) return;
  button.disabled = true;
  button.textContent = 'Continuing…';
  try {
    const r = await chat.start({ cwd: projectsData?.cwd ?? null, permissionMode: 'plan', resume: from });
    if (!r.ok) {
      el.foot.textContent = `could not continue: ${r.reason}`;
    } else {
      ownedIds.add(r.session.sessionId);
      // Two genuinely different outcomes, so say which one happened rather
      // than printing a sentence that is true either way.
      el.foot.textContent = r.session.forked
        ? `${from.slice(0, 8)} is open in another process, so this is a copy — `
          + `messages here do not reach it.`
        : `continued ${from.slice(0, 8)} itself — same session, same transcript.`;
      pollOwned();
    }
  } finally {
    button.disabled = false;
    button.textContent = 'Continue here';
  }
}

/* New session: a panel, not a button that starts one. Where it runs, how much it may do and what it is asked
   first are chosen before anything starts — and `plan` is what it opens on: a panel that can start a session
   must not also be the reason one got write access nobody asked for. */
let offeredModes = [];
const newPanel = new NewSession(el.newPanel, {
  shorten: (p) => shortPath(p, 44),
  onClose: () => setRight(inspectorNode ? 'inspector' : restRight()),
  onStart: async ({ cwd, permissionMode, first }) => {
    const r = await chat.start({ cwd, permissionMode });
    if (!r.ok) return r;
    ownedIds.add(r.session.sessionId);
    pollOwned();
    // The first message goes the way every later one does, and shows the same way: as what the session
    // says it received.
    if (first) chat.panes.get(r.session.sessionId)?.sendText(first);
    return r;
  },
});
el.newSession.addEventListener('click', () => {
  // Already open: a second click is not a second panel, and not a second session.
  const opened = newPanel.open({
    projects: projectsData?.projects ?? [],
    modes: offeredModes,
    preferKey: (current ? findSessionRow(current)?.project.key : null) ?? null,
  });
  if (opened) setRight('new');
});

/* --------------------------------------------------------------- canvas */

/* The toolbar says what the canvas is doing. It is painted from the canvas's own
   state, so a choice restored from storage shows without being re-made. */
const GROUP_WORD = { run: 'Workflow run', type: 'Agent type', parent: 'Parent', order: 'Order', none: 'None' };
const DENSITY_WORD = { auto: 'Auto', comfortable: 'Comfortable', compact: 'Compact' };
const SHOW = {
  all: { word: 'All', statuses: null },
  attention: { word: 'Needs attention', statuses: ['failed', 'killed', 'stopped'], waiting: true },
  running: { word: 'Running', statuses: ['running', 'starting'] },
  failed: { word: 'Failed', statuses: ['failed', 'killed', 'stopped'] },
};
let show = 'all';
const tbValue = {
  group: el.tbGroup.querySelector('span'),
  density: el.tbDensity.querySelector('span'),
  show: el.tbShow.querySelector('span'),
};

function paintToolbar(st) {
  tbValue.group.textContent = GROUP_WORD[st.group] ?? st.group;
  // The grouping is one choice for both views: the Timeline's rows follow the graph's.
  timeline.setGroup(st.group);
  // When Auto has turned the cards into chips the button says so: the picture did not fit this pane as cards.
  tbValue.density.textContent = st.density === 'auto' && st.drawnAs === 'compact' ? 'Auto \u00b7 compact' : (DENSITY_WORD[st.density] ?? st.density);
  // Auto is a choice the canvas makes; say which one it made, and why.
  el.tbDensity.title = st.density === 'auto' && st.drawnAs
    ? `Auto: ${st.drawnAs}${st.stacked ? ', agents of one type folded together' : ''}. `
      + `Cards stay cards while the picture fits this pane at ${Math.round(AUTO.readable * 100)}% or larger; choose Comfortable to keep them anyway.`
    : '';
  const pct = `${Math.round(st.zoom * 100)}%`;
  el.tbZoom.textContent = pct;
  el.tbZoom.setAttribute('aria-label', `Zoom ${pct}. Back to 100%`);
  // Enabled only while a card has been moved: with none there is nothing to reset.
  if (el.tbReset) el.tbReset.disabled = !(st?.moved > 0);
  paintFoldButtons();
}

/* Expand all and Fold all act on the view that is open: the graph's groups, the Timeline's, the List's sections.
   Each is enabled only while it has something left to do there, so the pair always says what is true. */
const foldTarget = () => (view === 'timeline' ? timeline : view === 'list' ? list : null);
function foldState() {
  const t = foldTarget();
  if (t) return t.foldState();
  const st = canvas.state();
  return { groups: st.groups, canExpand: st.canExpand, canFold: st.canFold };
}
function paintFoldButtons() {
  // The canvas reports its state while it is being built, before the view and the other two views exist; a
  // `let` or `const` that has not been reached yet throws on any read, `typeof` included.
  let s;
  try { s = foldState(); } catch { return; }
  el.tbExpand.disabled = !s.canExpand;
  el.tbFold.disabled = !s.canFold;
}

// Made before the canvas: the canvas reports its state while it is being built, and the toolbar passes the
// grouping on to the Timeline.
const timeline = new Timeline(el.timeline, {
  tileOf: (n) => canvas.tileFor(n),
  statusOf: (n) => canvas.statusOf(n),
  detailOf: (n) => detailCache.get(`${n.id}:${n.status ?? '?'}`) ?? null,
  // The drawer's "last error" is read from the agent's transcript, the same reading the inspector uses.
  onSelect: (n) => { if (n?.kind === 'agent') loadDetail(n.id, n.status); },
  onShowOnGraph: (n) => { setView('graph', n.id); },
  onOpenConversation: () => { if (current) openConversation(current); },
  // A group folded or opened by hand changes what Expand all and Fold all have left to do, at once.
  onChange: (st) => { paintTimelineBar(st); paintFoldButtons(); },
  fmt: { duration: fmtDuration, tokens: fmtTokens },
});
// Bars are placed on the server's clock: the timestamps they are drawn from are that machine's.
timeline.now = () => serverNow();

const canvas = new Canvas(document.getElementById('canvas'), {
  onSelect: showInspector,
  onChange: paintToolbar,
  onMenu: (n, at) => {
    if (!n) return;
    const st = canvas.state();
    const items = [];
    if (n.kind === 'agent') {
      items.push(st.focus
        ? { label: 'Show the whole graph', run: () => canvas.setFocus(null) }
        : { label: 'Focus on this branch', run: () => canvas.setFocus(n.id) });
      items.push({ label: 'Copy agent id', run: () => copyText(n.id, 'Copied the agent id') });
    }
    if (at.pinned) items.push({ label: 'Reset layout', run: () => resetLayout() });
    if (!items.length) return;
    openMenu({ getBoundingClientRect: () => ({ left: at.x, bottom: at.y }) }, items);
  },
});

// The mark for every agent that is not Crewforth's is one file, so that changing
// it is changing that file.
fetch('/icons/builtin.svg')
  .then((r) => (r.ok ? r.text() : Promise.reject(new Error(`HTTP ${r.status}`))))
  .then((svg) => canvas.setIcons({ builtin: svg }))
  .catch(() => { /* the tile stays empty; its title still says whose agent it is */ });

const pickFrom = (button, words, current, set) => button.addEventListener('click', (e) => {
  e.stopPropagation();
  openMenu(button, Object.entries(words).map(([key, w]) => ({
    label: typeof w === 'string' ? w : w.word, checked: current() === key, run: () => set(key),
  })));
});
pickFrom(el.tbGroup, GROUP_WORD, () => canvas.state().group, (g) => canvas.setGroup(g));

// In a window with room an agent group opens into the next column; in the band where the navigator is a rail
// there is no room for another column, and it opens downward as it always did.
canvas.setAside(!railBand.matches);
railBand.addEventListener('change', () => canvas.setAside(!railBand.matches));
pickFrom(el.tbDensity, DENSITY_WORD, () => canvas.state().density, (d) => canvas.setDensity(d));
// Show: by state, and by the model the work ran on. The two are separate choices and both hold at once.
let showModel = null;
function setShowModel(family) {
  showModel = family;
  canvas.setModelFilter(family);
  timeline.setModelFilter(family);
  list.render?.();
  tbValue.show.textContent = [SHOW[show].word, family ? `${family[0].toUpperCase()}${family.slice(1)}` : null].filter(Boolean).join(' \u00b7 ');
}
el.tbShow.addEventListener('click', (e) => {
  e.stopPropagation();
  const items = Object.entries(SHOW).map(([key, w]) => ({ label: w.word, checked: show === key, run: () => { setShow(key); setShowModel(showModel); } }));
  const families = [...new Set((lastNodes ?? []).filter((n) => n.kind === 'agent').map((n) => modelFamily(n.model)).filter(Boolean))].sort();
  if (families.length) {
    items.push({ note: 'Model' }, { label: 'Every model', checked: showModel === null, run: () => setShowModel(null) },
      ...families.map((f) => ({ label: `Only ${f[0].toUpperCase()}${f.slice(1)}`, checked: showModel === f, run: () => setShowModel(f) })));
  }
  openMenu(el.tbShow, items);
});
// The toolbar is measured, not assumed: it gives up a step at a time until what it shows fits (toolbar-fit.js).
// Every step is tried from the first, so a toolbar that has room again takes its words back.
function fitToolbar() {
  const bar = el.toolbar;
  const step = fitLevel((n) => {
    bar.dataset.fit = String(n);
    const box = bar.getBoundingClientRect();
    if (!box.width) return false;                       // not on screen: nothing to fit
    const shown = [...bar.children].filter((c) => !c.classList.contains('toolbar-fill') && !c.classList.contains('toolbar-note') && c.getClientRects().length);
    return runsOver({ right: box.right, padRight: parseFloat(getComputedStyle(bar).paddingRight) || 0 }, shown.map((c) => c.getBoundingClientRect().right));
  });
  bar.dataset.fit = String(step);
}
let fitQueued = false;
function queueFit() {
  if (fitQueued) return;
  fitQueued = true;
  // A frame later, so the write is not made inside an observer's own delivery.
  requestAnimationFrame(() => { fitQueued = false; fitToolbar(); });
}
// Its width changes with the window and with the panels beside it; what it holds changes with the view (setView
// asks) and with the words of its menus. Those words are written on every report from the canvas, a zoom frame
// included, so a write is not a change: the toolbar is measured again only when the words are different ones.
if (typeof ResizeObserver !== 'undefined') new ResizeObserver(queueFit).observe(el.toolbar);
if (typeof MutationObserver !== 'undefined') {
  const wordsNow = () => Object.values(tbValue).map((v) => v.textContent).join('|');
  let fitWords = wordsNow();
  const words = new MutationObserver(() => { const now = wordsNow(); if (now !== fitWords) { fitWords = now; queueFit(); } });
  for (const v of Object.values(tbValue)) words.observe(v, { childList: true, characterData: true, subtree: true });
}
// A narrow toolbar drops Group, Density, Show, Expand and Fold. They are not gone: this one menu holds them.
el.tbOptions.addEventListener('click', (e) => {
  e.stopPropagation();
  const st = canvas.state();
  const pick = (words, now, set) => Object.entries(words).map(([key, w]) => ({
    label: typeof w === 'string' ? w : w.word, checked: now === key, run: () => set(key),
  }));
  const items = view === 'list' ? [] : [{ note: 'Group' }, ...pick(GROUP_WORD, st.group, (g) => canvas.setGroup(g))];
  if (view === 'graph') items.push({ note: 'Density' }, ...pick(DENSITY_WORD, st.density, (d) => canvas.setDensity(d)));
  items.push({ note: 'Show' }, ...pick(SHOW, show, (key) => setShow(key)));
  if (view === 'graph' && st.groups > 0) {
    items.push({ note: 'Groups' }, { label: 'Expand all', run: () => canvas.expandAll() }, { label: 'Fold all', run: () => canvas.foldAll() });
  }
  if (view === 'graph') {
    const open = canvas.spendOpen;
    items.push({ note: 'Session summary' }, { label: open ? 'Hide time, tokens and cost' : 'Show time, tokens and cost', run: () => canvas.showSpend(!open) });
  }
  openMenu(el.tbOptions, items);
});
el.tbExpand.addEventListener('click', () => { (foldTarget() ?? canvas).expandAll(); paintFoldButtons(); });
el.tbFold.addEventListener('click', () => { (foldTarget() ?? canvas).foldAll(); paintFoldButtons(); });
el.tbZoomOut.addEventListener('click', () => canvas.zoomBy(1 / 1.2));
el.tbZoomIn.addEventListener('click', () => canvas.zoomBy(1.2));
el.tbZoom.addEventListener('click', () => canvas.zoomTo(1));
el.tbFit.addEventListener('click', () => canvas.fit());

/* Reset layout: the cards moved by hand go back where the layout puts them, and for a moment that can be undone. */
function resetLayout() {
  const was = canvas.resetLayout();
  if (!was) return;
  toast('Layout reset', { label: 'Undo', run: () => { if (canvas.restoreLayout(was)) toast('Layout restored'); } });
}
el.tbReset.addEventListener('click', resetLayout);

/* --------------------------------------------------------------- views
   The same session two ways: where its agents are, and when they were. The choice of what is selected, how it is
   grouped and what is shown is one choice, kept across the switch. */

let view = 'graph';

// The List: the same agents by what they need from the reader. A waiting request is a card with its own three
// answers there, so the dock stands down while the List is the view.
const list = new List(el.list, {
  tileOf: (n) => canvas.tileFor(n),
  dimmed: (n) => canvas.dimmed(n),
  // A row leads to the agent's detail: the inspector, which on a phone is a page of its own.
  onSelect: (n) => { list.select(n.id); canvas.select(n.id); },
  onDecide: (item, verdict) => decideRequest(item, verdict),
  onLocate: (item) => { if (item.sessionId !== current) selectSession(item.sessionId); },
  // A section folded or opened by hand changes what Expand all and Fold all have left to do, at once.
  onFold: () => paintFoldButtons(),
});
list.now = () => serverNow();

// Under 640px there is no room for the graph beside anything: the List is what a phone opens on.
const phoneBand = window.matchMedia('(max-width: 639px)');

function paintTimelineBar(st) {
  el.tbRange.textContent = st.range;
  el.tbRange.setAttribute('aria-label', `Time shown: ${st.range === 'all' ? 'the whole session' : st.range}`);
  el.tbRangeIn.disabled = !st.canZoomIn;
  el.tbRangeOut.disabled = !st.canZoomOut;
  // The range is in the buttons' own names too: on a narrow toolbar the label between them is not shown.
  el.tbRangeIn.setAttribute('aria-label', `Show less time (now ${st.range})`);
  el.tbRangeOut.setAttribute('aria-label', `Show more time (now ${st.range})`);
  el.tbFollow.setAttribute('aria-checked', String(st.follow));
  // There is no "now" to follow in a session that has ended.
  el.tbFollow.disabled = !st.live;
  el.tbFollow.title = st.live ? 'Keep the view at now' : 'This session has ended: there is no now to follow';
}

/**
 * @param select an agent to select in the view being opened; without one, what was selected stays selected
 */
function setView(next, select = null, remember = true) {
  const was = view;
  view = ['graph', 'timeline', 'list'].includes(next) ? next : 'graph';
  // A view the window opened on by default is not a choice, and is not remembered as one.
  if (remember) store.set('crewforth-studio-view', view);
  const carried = select ?? (was === 'timeline' ? timeline.selected : was === 'list' ? list.selected : canvas.selected) ?? null;
  el.canvasEl.hidden = view !== 'graph';
  el.timeline.hidden = view !== 'timeline';
  el.list.hidden = view !== 'list';
  el.viewGraph.setAttribute('aria-selected', String(view === 'graph'));
  el.viewTimeline.setAttribute('aria-selected', String(view === 'timeline'));
  el.viewList.setAttribute('aria-selected', String(view === 'list'));
  // Each control names the views it belongs to; the List has no grouping, so Group is not offered there.
  for (const c of document.querySelectorAll('.toolbar [data-view]')) c.hidden = !c.dataset.view.split(' ').includes(view);
  queueFit();
  el.stage.dataset.view = view;
  paintFoldButtons();
  // The List's cards carry the answers; the dock would be the same requests a second time.
  dock.setSuppressed(view === 'list');
  measureDock();
  paintStageNote();

  if (view === 'timeline') {
    // The drawer shows the selection here; the inspector gives the panel back.
    if (right === 'inspector') setRight(restRight());
    timeline.select(carried && canvas.nodes.get(carried)?.kind === 'agent' ? carried : null);
    paintTimelineBar(timeline.state());
    const n = timeline.selected ? canvas.nodes.get(timeline.selected) : null;
    if (n) loadDetail(n.id, n.status);
  } else if (view === 'list') {
    list.select(carried && canvas.nodes.get(carried)?.kind === 'agent' ? carried : null);
    list.render();
  } else {
    canvas.fitIfUntouched();
    if (carried && canvas.nodes.has(carried)) canvas.focus(carried);
  }
}
/** Bring an agent forward in whichever view is open: its card on the graph, or its row on the Timeline. */
function goTo(agentId) {
  if (view === 'graph') { canvas.focus(agentId); return; }
  if (view === 'list') { list.select(agentId); canvas.select(agentId); return; }
  timeline.select(agentId);
  const n = canvas.nodes.get(agentId);
  if (n?.kind === 'agent') loadDetail(n.id, n.status);
}
el.viewGraph.addEventListener('click', () => setView('graph'));
el.viewTimeline.addEventListener('click', () => setView('timeline'));
el.viewList.addEventListener('click', () => setView('list'));
el.tbFollow.addEventListener('click', () => timeline.setFollow(el.tbFollow.getAttribute('aria-checked') !== 'true'));
// "Out" is more time on screen, "in" is less: the same way round as the graph's zoom.
el.tbRangeOut.addEventListener('click', () => timeline.zoom(1));
el.tbRangeIn.addEventListener('click', () => timeline.zoom(-1));
if (typeof ResizeObserver !== 'undefined') new ResizeObserver(() => requestAnimationFrame(() => timeline.render())).observe(el.timeline);
// The canvas's pane changing size changes what fits in it, and with that what Auto density draws.
if (typeof ResizeObserver !== 'undefined') new ResizeObserver(() => requestAnimationFrame(() => canvas.fitIfUntouched())).observe(el.canvasEl);

getJson('/api/palette')
  .then((p) => {
    canvas.setPalette(p);
    // With Crewforth's agents unread, a `crew-…` agent cannot be told from one that only carries the name. That has
    // to be said out loud, or the panel is drawing "not measured" as a fact about the agents.
    if (p && p.measured === false) {
      document.body.dataset.paletteMeasured = 'false';
      el.foot.textContent = `agent identity Not measured — ${p.reason}`;
    }
  })
  .catch(() => { /* every agent is drawn with the common mark, which is what is known */ });

let inspectorTab = 'overview';
let inspectorNode = null;
let detailCache = new Map();

function showInspector(node) {
  const before = inspectorNode;
  inspectorNode = node;
  if (!node) {
    list.select(null);
    // Closing the inspector gives the panel back to the conversation, when one is open.
    if (right === 'inspector') setRight(restRight());
    return;
  }
  setRight('inspector');
  // A tab is a question being asked of the node. Another node of the same kind is asked the same question.
  if (before?.kind !== node.kind) inspectorTab = 'overview';
  paintInspector();
  if (node.kind === 'agent') loadDetail(node.id, node.status);
  // Gates and Stats are the session's, whichever node is selected in it.
  if (current) loadKit(current);
}

// Keyed by status as well as id: a report fetched while the agent was still
// running says "no report yet", and that answer must not outlive the run.
// Failures are not cached at all — a network blip should not permanently hide
// a report behind a stale error.
async function loadDetail(agentId, status) {
  const key = `${agentId}:${status ?? '?'}`;
  if (detailCache.has(key)) return;
  detailCache.set(key, { loading: true });
  paintInspector();
  try {
    const d = await getJson(`/api/session/${encodeURIComponent(current)}/agent/${encodeURIComponent(agentId)}`);
    detailCache.set(key, d);
  } catch (e) {
    detailCache.delete(key);
    detailCache.set(key, { measured: false, reason: e.message, transient: true });
  }
  if (inspectorNode?.id === agentId) paintInspector();
  if (timeline.selected === agentId) timeline.paintDrawer();
}

function metaRows(n) {
  const rows = [];
  const row = (k, v) => { if (v != null && v !== '') rows.push([k, String(v)]); };
  if (n.kind === 'session') {
    row('session', n.sessionId); row('cwd', n.cwd); row('branch', n.gitBranch);
    row('model', n.model); row('turns', n.turns);
    row('context', n.tokens?.toLocaleString()); row('cli', n.version);
  } else {
    row('type', n.agentType ?? 'unknown'); row('status', n.status);
    row('depth', n.spawnDepth); row('model', n.model);
    row('turns', n.turns); row('last tool', n.lastTool);
    row('agent id', n.id);
  }
  const dl = document.createElement('dl');
  for (const [k, v] of rows) {
    const dt = document.createElement('dt'); dt.textContent = k;
    const dd = document.createElement('dd'); dd.textContent = v;
    dl.append(dt, dd);
  }
  return dl;
}

/** A titled block of the inspector. */
function isection(title, ...children) {
  const s = node('section', 'isec');
  s.append(node('h4', 'isec-h', title), ...children);
  return s;
}

/** The agent transcript, as far as it has been read: null when it is there to use. */
function detailGap(n, detail) {
  if (!detail || detail.loading) return node('div', 'ihint', 'Reading the agent transcript…');
  if (detail.measured !== false) return null;
  const hint = node('div', 'ihint');
  hint.append(node('strong', null, 'Not measured'), node('div', null, detail.reason || 'no reason given'));
  if (detail.transient) {
    const retry = node('button', 'btn sm', 'Retry');
    retry.type = 'button';
    retry.addEventListener('click', () => {
      detailCache.delete(`${n.id}:${n.status ?? '?'}`);
      loadDetail(n.id, n.status);
    });
    hint.append(retry);
  }
  return hint;
}

/** Where a node's transcript is on disk, when this page was told. */
function transcriptPathOf(n, detail) {
  if (n.kind === 'session') return findSessionRow(current)?.session?.file ?? null;
  return detail?.transcriptPath ?? null;
}

function paintInspector() {
  const n = inspectorNode;
  if (!n) return;
  const isSession = n.kind === 'session';
  const detail = n.kind === 'agent' ? detailCache.get(`${n.id}:${n.status ?? '?'}`) : null;
  const st = canvas.statusOf(n);

  const head = node('div', 'ihead');
  const close = node('button', 'btn icon sm ghost');
  close.type = 'button';
  close.setAttribute('aria-label', 'Close');
  close.title = 'Close (Esc)';
  close.append(icon(ICON.close));
  close.addEventListener('click', () => { canvas.clearSelection(); showInspector(null); });
  // On a phone the inspector is a page of its own, and the way out of a page is back.
  const back = node('button', 'btn icon sm ghost ihead-back');
  back.type = 'button';
  back.setAttribute('aria-label', 'Back to the list');
  back.append(icon(ICON.back));
  back.addEventListener('click', () => { canvas.clearSelection(); showInspector(null); });
  close.classList.add('ihead-close');
  const name = isSession ? 'Session' : n.kind === 'workflow' ? (n.workflowId ?? 'Workflow run') : shownType(n);
  const iname = node('h3', 'iname', name);
  if (n.kind === 'agent') iname.title = n.agentType ?? '';
  head.append(back, canvas.tileFor(n), iname, close);

  const meta = node('div', 'imeta');
  const pill = node('span', 'pill');
  // A state nobody read is said, not left as a blank pill.
  pill.append(dot(st.tone), node('span', null, st.word ?? 'State not measured'));
  meta.append(pill, node('span', 'sub', timeLine(n, serverNow())));
  // The role is the name; the type as it is declared is said here, where there is room for it.
  if (n.kind === 'agent' && n.agentType) meta.append(node('code', 'ireal', n.agentType));

  const task = node('div', 'itask', isSession
    ? (sessionLabel(current) ?? n.sessionId ?? '')
    : n.kind === 'workflow' ? `${n.members ?? 0} agents` : (n.description ?? ''));

  const tabs = node('div', 'itabs');
  tabs.setAttribute('role', 'tablist');
  for (const t of INSPECTOR_TABS) {
    const b = node('button', 'itab', TAB_WORD[t]);
    b.type = 'button';
    b.setAttribute('role', 'tab');
    b.setAttribute('aria-selected', String(inspectorTab === t));
    b.addEventListener('click', () => { inspectorTab = t; paintInspector(); });
    tabs.append(b);
  }

  const body = node('div', 'ibody');
  body.setAttribute('role', 'tabpanel');
  if (inspectorTab === 'gates') paintGates(body);
  else if (inspectorTab === 'stats') paintStats(body);
  else if (inspectorTab === 'conversation') paintTranscript(body, n, detail);
  else if (isSession) paintSessionOverview(body, n);
  else paintAgentOverview(body, n, detail);

  const foot = node('div', 'ifoot');
  const open = node('button', 'btn', 'Open conversation');
  open.type = 'button';
  open.addEventListener('click', () => { if (current) openConversation(current); });
  const file = transcriptPathOf(n, detail);
  const copy = node('button', 'btn icon');
  copy.type = 'button';
  copy.append(icon(ICON.copy));
  copy.setAttribute('aria-label', 'Copy the transcript path');
  // A path nobody handed over is not built from parts here: the button says it has none.
  copy.disabled = !file;
  copy.title = file ? `Copy the transcript path\n${file}` : 'Transcript path not read yet';
  copy.addEventListener('click', () => copyText(file, 'Copied'));
  foot.append(open, copy);

  el.inspector.replaceChildren(inspectorSplit, head, meta, task, tabs, body, foot);
}

function paintAgentOverview(body, n, detail) {
  const grid = node('div', 'itiles');
  for (const t of tiles(n, serverNow())) {
    const tile = node('div', 'itile');
    const value = node('strong', null, t.value);
    if (!t.measured) { tile.classList.add('unmeasured'); tile.title = `Not measured — ${t.why}`; }
    if (t.bad) value.classList.add('bad');
    tile.append(node('span', 'itile-k', t.label), value);
    grid.append(tile);
  }
  body.append(grid);

  // What it ran on and what its call asked for, and what the model gate or a low-confidence report did to it.
  const models = modelLines(n, lastNodes);
  if (models.length) {
    const dl = node('dl', 'imodel');
    for (const m of models) {
      const dd = node('dd', null, m.text);
      if (m.note) dd.title = m.note;
      if (m.goto) {
        const go = node('button', 'ilink', 'show');
        go.type = 'button';
        go.addEventListener('click', () => goTo(m.goto));
        dd.append(' ', go);
      }
      dl.append(node('dt', null, m.label), dd);
    }
    body.append(isection('Model', dl));
  }

  const gap = n.kind === 'agent' ? detailGap(n, detail) : null;
  const read = n.kind === 'agent' && !gap ? detail : null;

  const now = rightNow(n, read);
  const box = node('div', 'inow');
  if (now.tool) box.append(node('span', 'inow-tool', now.tool));
  box.append(node('span', 'inow-text', now.text || (gap ? '' : '—')));
  body.append(isection(now.heading, box));

  if (n.kind !== 'agent') { body.append(metaRows(n)); return; }

  const skills = read ? skillsOf(read) : [];
  const chips = node('div', 'ichips');
  for (const s of skills) {
    const chip = node('button', 'ichip', s);
    chip.type = 'button';
    chip.title = 'Copy the skill name';
    chip.addEventListener('click', () => copyText(s, `Copied ${s}`));
    chips.append(chip);
  }
  body.append(isection('Skills applied',
    gap ?? (skills.length ? chips : node('div', 'ihint', 'None — this agent invoked no skill.'))));

  const by = delegatedBy(n, [...canvas.nodes.values()]);
  if (by) {
    const link = node('button', 'ilink', by.text);
    link.type = 'button';
    link.addEventListener('click', () => canvas.focus(by.id));
    body.append(isection('Delegated by', link));
  }

  if (gap) { body.append(isection('Report', node('div', 'ihint', 'Reading the agent transcript…'))); return; }
  const rep = reportOf(n, read);
  if (!rep.present) { body.append(isection('Report', node('div', 'ihint', rep.text))); return; }
  const md = node('div', 'md');
  md.innerHTML = renderMarkdown(rep.text);
  const copy = node('button', 'btn sm ghost', 'Copy');
  copy.type = 'button';
  copy.addEventListener('click', () => copyText(rep.text, 'Copied the report'));
  const sec = isection('Report', md);
  sec.querySelector('.isec-h').append(copy);
  body.append(sec);
}

function paintSessionOverview(body, n) {
  if (current && !ownedIds.has(current)) {
    // Said in the place the missing controls would have been: there is no approval dock for this session, and
    // no way to write to it, and this is why.
    const banner = node('div', 'ibanner');
    banner.append(node('p', null, 'This session was not started here, so Studio can read it but not write to it.'));
    const acts = node('div', 'ibanner-acts');
    const cont = node('button', 'btn sm primary', 'Continue here');
    cont.type = 'button';
    cont.title = 'Start a new session holding a copy of this conversation. It does not write into the original.';
    cont.addEventListener('click', () => continueHere(cont));
    const term = node('button', 'btn sm', 'Open in terminal');
    term.type = 'button';
    term.addEventListener('click', (e) => { e.stopPropagation(); offerTerminal(term, current); });
    acts.append(cont, term);
    banner.append(acts);
    body.append(banner);
  }
  body.append(metaRows(n));

  // Commands the session sent to the background and that are still going. They are not agents and have no card.
  const running = backgroundLines(n, serverNow());
  if (running.length) {
    const rows = running.map((c) => {
      const row = node('div', 'ibg-row');
      const what = node('code', 'ibg-what', c.what);
      what.title = c.what;
      row.append(what);
      if (c.age) row.append(node('span', 'sub', c.age));
      return row;
    });
    const box = isection('In the background', ...rows);
    body.append(box);
  }

  const b = kitData?.board;
  let board;
  if (!kitData) board = node('div', 'ihint', 'Reading Crewforth…');
  else if (!b?.measured) board = unmeasured(b?.reason);
  else if (!b.present) board = node('div', 'ihint', b.text);
  else board = node('pre', 'md-code', b.text);
  body.append(isection('Board', board));
}

/** The agent's own transcript, read-only: what it was asked, what it did, what it said. */
function paintTranscript(body, n, detail) {
  const full = node('button', 'btn sm', 'Open full conversation');
  full.type = 'button';
  full.addEventListener('click', () => { if (current) openConversation(current); });

  if (n.kind !== 'agent') {
    body.append(node('div', 'ihint', n.kind === 'session'
      ? 'The session\'s conversation is in the conversation panel.'
      : 'A workflow run has no transcript of its own; its agents do.'), full);
    return;
  }
  const gap = detailGap(n, detail);
  if (gap) { body.append(gap, full); return; }

  const prompt = node('div', 'md');
  prompt.innerHTML = renderMarkdown(detail.prompt ?? '');
  body.append(isection('Asked', detail.prompt ? prompt : node('div', 'ihint', 'No prompt recorded.')));

  const list = node('div', 'itimeline');
  if (!detail.timeline?.length) list.append(node('div', 'ihint', 'No tool calls recorded.'));
  for (const [i, step] of (detail.timeline ?? []).entries()) {
    const r = node('div', 'istep');
    r.append(node('span', 'istep-n', String(i + 1)), node('span', 'istep-tool', step.name), node('span', 'istep-label', step.label ?? ''));
    list.append(r);
  }
  body.append(isection('Did', list));

  const said = node('div', 'isaid');
  for (const t of detail.narration ?? []) {
    const md = node('div', 'md md-narration');
    md.innerHTML = renderMarkdown(t);
    said.append(md);
  }
  const rep = reportOf(n, detail);
  if (rep.present) {
    const md = node('div', 'md');
    md.innerHTML = renderMarkdown(rep.text);
    said.append(md);
  } else {
    said.append(node('div', 'ihint', rep.text));
  }
  body.append(isection('Said', said), full);
}

/* ------------------------------------------------------------------ kit
   What Crewforth already measures about itself. Nothing here is recomputed —
   each panel shows what Crewforth's own tool said, including when it said it
   could not answer. */

let kitData = null;
let kitFor = null;

async function loadKit(sessionId) {
  if (kitFor === sessionId && kitData) return;
  kitFor = sessionId;
  kitData = null;
  try {
    kitData = await getJson(`/api/kit?session=${encodeURIComponent(sessionId)}`);
  } catch (e) {
    kitData = { measured: false, reason: e.message };
  }
  if (inspectorNode) paintInspector();
}

function unmeasured(reason) {
  const d = node('div', 'ihint');
  d.append(node('strong', null, 'Not measured'));
  d.append(node('div', null, reason || 'no reason given'));
  d.append(node('div', 'why', 'Which is not the same as nothing having happened.'));
  return d;
}

function paintStats(body) {
  if (!kitData) { body.append(node('div', 'ihint', 'Reading Crewforth…')); return; }
  const s = kitData.stats;
  if (!s?.measured) {
    const reason = s?.reason ?? kitData.reason ?? '';
    const box = node('div', 'ihint');
    box.append(node('strong', null, 'Not measured'), node('div', null, reason || 'no reason given'),
      node('div', 'why', 'This is not a zero: there is nothing to read here.'));
    // The script that measures this comes with a full install. That is said only when its absence is the
    // reason, and no command is typed here: the page offers commands the server gave it, and it gave none.
    if (/session-stats\.sh is not present|not installed/.test(reason)) {
      box.append(node('div', 'why', 'A full install of Crewforth in this project adds it.'));
    }
    body.append(box);
    return;
  }
  const dl = document.createElement('dl');
  for (const [k, v] of Object.entries(s.metrics)) {
    const dt = node('dt', null, k.replace(/_/g, ' '));
    const dd = node('dd', null, v.toLocaleString());
    if (v > 0 && /runaway|errors|interrupts/.test(k)) dd.classList.add('bad');
    dl.append(dt, dd);
  }
  body.append(dl);
  body.append(node('div', 'ihint', 'session-stats.sh --raw, over this transcript.'));
}

async function revokeAllowance(tool, button) {
  const sessionId = current;
  button.disabled = true;
  let res;
  try {
    const r = await fetch(api(`/api/owned/${encodeURIComponent(sessionId)}/permissions/${encodeURIComponent(tool)}`), {
      method: 'DELETE', headers: writeHeaders,
    });
    res = await r.json();
  } catch (e) {
    res = { ok: false, reason: e.message };
  }
  if (!res.ok) {
    toast(`Not revoked — ${res.reason ?? 'no reason given'}`);
    button.disabled = false;
    return;
  }
  const sn = owned.get(sessionId);
  if (sn) owned.set(sessionId, { ...sn, alwaysAllowed: res.always ?? [] });
  toast(res.revoked ? `${tool} asks again from the next call` : `${tool} was already asking`);
  if (inspectorNode) paintInspector();
}

function paintGates(body) {
  const mine = current ? owned.get(current) : null;

  // What the viewer widened, first: it is the one thing on this tab that can be taken back.
  if (mine?.gated) {
    const allowed = mine.alwaysAllowed ?? [];
    const list = node('div', 'iallow');
    for (const tool of allowed) {
      const row = node('div', 'iallow-row');
      const revoke = node('button', 'btn sm', 'Revoke');
      revoke.type = 'button';
      revoke.setAttribute('aria-label', `Revoke ${tool}`);
      revoke.addEventListener('click', () => revokeAllowance(tool, revoke));
      row.append(node('span', 'iallow-tool', tool), node('span', 'sub', 'not asked about here'), node('span', 'row-fill'), revoke);
      list.append(row);
    }
    // What a session allowance is and is not: the dock stops asking, and nothing more. A call Claude Code
    // would itself have asked a person about is still refused, because nobody saw it.
    if (allowed.length) list.append(node('div', 'ihint', 'Studio does not ask about these again. Claude Code\'s own checks still apply to each call.'));
    body.append(isection('Allowed for this session',
      allowed.length ? list : node('div', 'ihint', 'Nothing — every tool call asks first.')));
  } else if (mine) {
    body.append(isection('Allowed for this session',
      node('div', 'ihint', 'This session runs without the approval gate, so nothing asks and nothing was allowed here.')));
  } else {
    body.append(isection('Allowed for this session',
      node('div', 'ihint', 'This session was not started here, so its tool calls do not wait for an answer in Studio.')));
  }

  // Happened: what was seen with a time on it. The answers given to requests come from this page; the hook
  // runs come from the session's own stream.
  const answers = (current ? outcomes.get(current) : null) ?? [];
  const live = mine?.gateEvents ?? chat.panes.get(current)?.session?.gateEvents ?? [];
  if (answers.length || live.length) {
    const rows = [];
    for (const a of answers.slice(-12)) {
      const row = node('div', 'gate-row');
      row.append(node('span', 'gate-when', new Date(a.at - clock.offset).toLocaleTimeString()));
      row.append(node('span', 'gate-name', `${a.toolName}${a.agentType ? ` · ${roleName(a.agentType)}` : ''}`));
      const v = node('span', 'gate-verdict', OUTCOME_WORD[a.outcome]);
      v.dataset.verdict = a.outcome.startsWith('allowed') ? 'ALLOW' : a.outcome === 'answered-elsewhere' ? 'ASK' : 'BLOCK';
      row.append(v);
      rows.push({ at: a.at, row });
    }
    for (const e of live.slice(-12)) {
      const row = node('div', 'gate-row');
      row.append(node('span', 'gate-when', new Date(e.at - clock.offset).toLocaleTimeString()));
      row.append(node('span', 'gate-name', e.name ?? e.event ?? 'hook'));
      const v = node('span', 'gate-verdict', e.phase === 'started' ? 'ran' : (e.exitCode === 2 ? 'blocked' : e.outcome ?? 'done'));
      v.dataset.verdict = e.exitCode === 2 ? 'BLOCK' : 'ALLOW';
      row.append(v);
      rows.push({ at: e.at, row });
    }
    // One list, newest first: both kinds carry the server's time.
    rows.sort((x, y) => y.at - x.at);
    body.append(isection('Happened', ...rows.map((r) => r.row)));
  }

  if (!kitData) { body.append(node('div', 'ihint', 'Reading Crewforth…')); return; }
  const log = kitData.log;
  const rep = kitData.report;

  const observed = [];
  if (rep?.measured) {
    const head = node('div', 'kit-sum');
    head.append(node('span', 'cv-bit', `${rep.rules} rules`));
    head.append(node('span', 'cv-bit', `${(rep.decisions ?? 0).toLocaleString()} decisions`));
    observed.push(head);
  } else {
    observed.push(unmeasured(rep?.reason ?? kitData.reason));
  }

  if (!log?.measured) {
    observed.push(unmeasured(log?.reason ?? kitData.reason));
    body.append(isection('Observed', ...observed));
    return;
  }

  // The distinction is the point: this file has no timestamp column, so these
  // are decisions found in the log, not decisions seen happening.
  observed.push(node('div', 'ihint',
    `${log.total.toLocaleString()} in the tail of gate-log.tsv${log.truncated ? ' (truncated)' : ''} · `
    + 'no timestamps in this format, so these are what the log holds, not when they ran'
    + (log.commandsRecorded ? '' : ' · commands not recorded (CREW_GATE_LOG_CMD=1 records them)')));

  const counts = node('div', 'kit-sum');
  for (const [k, v] of Object.entries(log.counts ?? {})) {
    const b = node('span', 'cv-bit', `${v.toLocaleString()} ${k}`);
    b.dataset.verdict = k;
    counts.append(b);
  }
  observed.push(counts);

  for (const e of (log.entries ?? []).slice(0, 40)) {
    const row = node('div', 'gate-row');
    const v = node('span', 'gate-verdict', e.verdict);
    v.dataset.verdict = e.verdict;
    row.append(v);
    row.append(node('span', 'gate-name', e.rule ?? '—'));
    if (e.section) row.append(node('span', 'gate-sec', e.section));
    observed.push(row);
  }
  body.append(isection('Observed', ...observed));
}

/* ------------------------------------------------------------ navigator
   One search box, three tabs. Projects is everything on this machine; Live is
   what is working or waiting right now, whichever project it is in; Machines
   is what is known about the others. The words and the rules are in nav.js —
   this is where they are drawn. */

function node(tag, cls, text) {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text != null) n.textContent = text;
  return n;
}

function renderNote(host, { kind, title, body, why }) {
  const wrap = node('div', `note${kind ? ` ${kind}` : ''}`);
  wrap.append(node('strong', null, title));
  if (body) wrap.append(node('div', null, body));
  if (why) wrap.append(node('div', 'why', why));
  host.replaceChildren(wrap);
}

function shortPath(p, max = 34) {
  if (!p) return '';
  const home = p.match(/^\/(Users|home)\/[^/]+/);
  const s = home ? `~${p.slice(home[0].length)}` : p;
  if (s.length <= max) return s;
  const keep = Math.floor((max - 1) / 2);
  return `${s.slice(0, keep)}…${s.slice(-keep)}`;
}

const SVG_NS = 'http://www.w3.org/2000/svg';
function icon(d) {
  const svg = document.createElementNS(SVG_NS, 'svg');
  svg.setAttribute('class', 'ic');
  svg.setAttribute('viewBox', '0 0 16 16');
  svg.setAttribute('aria-hidden', 'true');
  const path = document.createElementNS(SVG_NS, 'path');
  path.setAttribute('d', d);
  svg.append(path);
  return svg;
}
const ICON = {
  close: 'M4 4l8 8M12 4l-8 8',
  back: 'M10 4l-4 4 4 4',
  copy: 'M5.5 5.5v-2A1.5 1.5 0 0 1 7 2h5.5A1.5 1.5 0 0 1 14 3.5V9a1.5 1.5 0 0 1-1.5 1.5h-2M3.5 5.5H9A1.5 1.5 0 0 1 10.5 7v5.5A1.5 1.5 0 0 1 9 14H3.5A1.5 1.5 0 0 1 2 12.5V7a1.5 1.5 0 0 1 1.5-1.5z',
  chevron: 'M6 4l4 4-4 4',
  more: 'M3.5 8h.01M8 8h.01M12.5 8h.01',
  machine: 'M3.5 3h9A1.5 1.5 0 0 1 14 4.5v5a1.5 1.5 0 0 1-1.5 1.5h-9A1.5 1.5 0 0 1 2 9.5v-5A1.5 1.5 0 0 1 3.5 3zM6 14h4M8 11v3',
};

/** A status dot. No tone is the hollow ring: something over, or something nobody has a colour for. */
function dot(tone) {
  const d = node('span', 'dot');
  d.dataset.tone = tone ?? 'none';
  return d;
}

/** `text` with the part that matches the search marked. */
function marked(text, cls) {
  const span = node('span', cls);
  for (const part of highlight(text, filterText)) {
    span.append(part.hit ? node('mark', null, part.text) : document.createTextNode(part.text));
  }
  return span;
}

/* A short line that says something happened and goes away. Not a dialog: it
   takes no focus and needs no answer. */
let toastTimer = null;
function toast(text, action = null) {
  el.toast.replaceChildren(document.createTextNode(text));
  // One thing that can be done about what just happened, while the line is up: "Undo".
  if (action) {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'toast-act';
    b.textContent = action.label;
    b.addEventListener('click', () => { el.toast.hidden = true; action.run(); });
    el.toast.append(' \u00b7 ', b);
  }
  el.toast.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { el.toast.hidden = true; }, action ? 6000 : 3200);
}

async function copyText(text, said) {
  try {
    await navigator.clipboard.writeText(text);
    toast(said);
  } catch {
    // A page without clipboard access still has to hand the text over.
    toast(`Could not copy — ${text}`);
  }
}

/* What the viewer changed about the list, kept in this browser. A label is a
   name for a row here; the transcript is not touched. */
function stored(key, fallback) {
  try { return JSON.parse(store.get(key) ?? 'null') ?? fallback; } catch { return fallback; }
}
const labels = {
  map: stored('crewforth-studio-labels', {}),
  all() { return this.map; },
  set(id, text) {
    if (text) this.map[id] = text; else delete this.map[id];
    store.set('crewforth-studio-labels', JSON.stringify(this.map));
  },
};
const hiddenIds = new Set(stored('crewforth-studio-hidden', []));
function setHidden(id, hidden) {
  if (hidden) hiddenIds.add(id); else hiddenIds.delete(id);
  store.set('crewforth-studio-hidden', JSON.stringify([...hiddenIds]));
}

/* ----------------------------------------------------------------- tabs */

const TABS = { projects: el.sessions, live: el.fleet, machines: el.reach };
let navTab = 'projects';

function setTab(tab) {
  navTab = tab in TABS ? tab : 'projects';
  for (const [name, panel] of Object.entries(TABS)) panel.hidden = name !== navTab;
  for (const b of document.querySelectorAll('[data-tab]')) {
    b.setAttribute('aria-selected', String(b.dataset.tab === navTab));
  }
  for (const b of document.querySelectorAll('[data-rail-tab]')) {
    b.classList.toggle('on', b.dataset.railTab === navTab);
  }
  // The short list of other machines belongs under the projects; on its own
  // tab it would be saying the same thing twice.
  paintOtherMachines();
  store.set('crewforth-studio-nav-tab', navTab);
}

for (const b of document.querySelectorAll('[data-tab]')) b.addEventListener('click', () => setTab(b.dataset.tab));
// On the rail a tab is also the way back in: it opens the navigator on that tab.
for (const b of document.querySelectorAll('[data-rail-tab]')) {
  b.addEventListener('click', () => { setTab(b.dataset.railTab); setSideHidden(false); });
}

/* ----------------------------------------------------------------- menu
   The few things a session row can do besides being opened. A menu, not a
   dialog: it closes on the next click anywhere and on Esc. */

function closeMenu() { el.menu.hidden = true; el.menu.replaceChildren(); }

function openMenu(anchor, items) {
  el.menu.replaceChildren(...items.map((it) => {
    if (it.note) return node('div', 'menu-note', it.note);
    const b = node('button', `menu-item${it.primary ? ' primary' : ''}`);
    b.type = 'button';
    if ('tone' in it) b.append(dot(it.tone));
    b.append(document.createTextNode(it.label));
    if (it.checked !== undefined) {
      b.setAttribute('role', 'menuitemcheckbox');
      b.setAttribute('aria-checked', String(it.checked));
    } else {
      b.setAttribute('role', 'menuitem');
    }
    b.addEventListener('click', (e) => { e.stopPropagation(); closeMenu(); it.run(); });
    return b;
  }));
  const r = anchor.getBoundingClientRect();
  el.menu.hidden = false;
  el.menu.style.left = `${Math.max(8, Math.min(r.left, window.innerWidth - 280))}px`;
  el.menu.style.top = `${Math.min(r.bottom + 4, window.innerHeight - 8 - el.menu.offsetHeight)}px`;
  el.menu.querySelector('button')?.focus();
}

document.addEventListener('click', (e) => { if (!el.menu.hidden && !el.menu.contains(e.target)) closeMenu(); });

/** Hand a session to a real terminal. The command is shown first and runs only on the second click. */
async function offerTerminal(anchor, sessionId) {
  let plan = null;
  try {
    plan = (await getJson(`/api/session/${encodeURIComponent(sessionId)}/terminal`)).plan;
  } catch (e) {
    toast(`Could not read the terminal command — ${e.message}`);
    return;
  }
  if (!plan) { toast('Not measured — this session recorded no working directory to open a terminal in.'); return; }
  openMenu(anchor, [
    { note: `This will run in ${plan.via ?? 'a terminal'}:` },
    { note: plan.line },
    {
      label: 'Open terminal',
      primary: true,
      run: async () => {
        try {
          const r = await fetch(api(`/api/session/${encodeURIComponent(sessionId)}/terminal`), {
            method: 'POST', headers: { ...writeHeaders, 'content-type': 'application/json' }, body: '{}',
          });
          const out = await r.json();
          toast(out.ok ? `Opened in ${plan.via ?? 'a terminal'}` : `Could not open a terminal — ${out.reason ?? 'no reason given'}`);
        } catch (e) {
          toast(`Could not open a terminal — ${e.message}`);
        }
      },
    },
    { label: 'Cancel', run: () => {} },
  ]);
}

/* ------------------------------------------------------------- projects */

let projectsData = null;
let fleetData = null;
let expanded = new Set();
let filterText = '';
let showMissing = false;
let showHidden = false;
let renaming = null;          // the session whose name is being typed

el.filter.addEventListener('input', () => {
  filterText = el.filter.value.trim().toLowerCase();
  paintProjects();
  paintLive();
});

function findSessionRow(sessionId) {
  for (const project of projectsData?.projects ?? []) {
    const session = project.sessions.find((x) => x.sessionId === sessionId);
    if (session) return { project, session };
  }
  return null;
}

function renderSessions(data) {
  if (!data.measured) {
    renderNote(el.sessions, {
      kind: 'unmeasured',
      title: 'No transcripts here',
      body: 'Nothing was read.',
      why: data.reason,
    });
    return;
  }
  projectsData = data;
  // The project you are standing in starts open; the rest stay folded, or a
  // machine with 175 projects buries the one you are working in.
  if (!expanded.size) {
    const cur = data.projects.find((p) => p.current) ?? data.projects[0];
    if (cur) expanded.add(cur.key);
  }
  paintProjects();
  paintCrumb();
  paintFirstRun();
}

/* The first run: the transcripts were read and there are none. The stage says what Studio is waiting for and
   offers the one thing that can be done about it here. */
function paintFirstRun() {
  const first = isFirstRun(projectsData);
  el.sessions.removeAttribute('aria-busy');
  el.stage.dataset.firstRun = String(first);
  // No "New session" here, although the design has one: a session is started in a project, and on a machine
  // with no transcripts this panel knows of no project to start it in.
  if (first && !el.firstRun.firstChild) {
    el.firstRun.append(
      node('strong', null, 'No Claude Code sessions yet'),
      node('p', null, 'Studio reads the sessions Claude Code saves on this machine. Start one in a terminal in any project and it shows up here within a few seconds.'),
    );
  }
  el.firstRun.hidden = !first;
}

function versionBadge(kit) {
  const b = badgeFor(kit);
  const tag = node(b.copy ? 'button' : 'span', `badge badge-${b.tone}`, b.text);
  tag.title = b.title;
  if (b.copy) {
    tag.type = 'button';
    tag.addEventListener('click', (e) => { e.stopPropagation(); copyText(b.copy, `Copied: ${b.copy}`); });
  }
  return tag;
}

function sessionRow(project, sn) {
  const status = sessionStatus(sn.sessionId, fleetData);
  const name = sessionName(sn, labels.all());
  const row = node('div', 'srow');
  row.dataset.id = sn.sessionId;
  row.tabIndex = 0;
  row.setAttribute('role', 'treeitem');
  row.setAttribute('aria-current', String(sn.sessionId === current));
  if (ownedIds.has(sn.sessionId)) row.classList.add('owned');

  const top = node('span', 'srow-top');
  const d = dot(status.tone);
  // The word travels with the colour; where there is no status to give, say why.
  d.title = status.key === 'unmeasured' ? 'Status not measured — the session list could not be read' : (status.word ?? '');
  top.append(d);

  if (renaming === sn.sessionId) {
    const input = node('input', 'srow-rename');
    input.value = name;
    input.setAttribute('aria-label', `Rename ${name}`);
    const done = (save) => {
      if (renaming !== sn.sessionId) return;
      renaming = null;
      if (save) labels.set(sn.sessionId, input.value.trim() === (sn.title ?? '') ? '' : input.value.trim());
      paintProjects();
      paintCrumb();
    };
    input.addEventListener('click', (e) => e.stopPropagation());
    input.addEventListener('keydown', (e) => {
      e.stopPropagation();
      if (e.key === 'Enter') done(true);
      if (e.key === 'Escape') done(false);
    });
    input.addEventListener('blur', () => done(true));
    top.append(input);
    queueMicrotask(() => { input.focus(); input.select(); });
  } else {
    top.append(marked(name, 'nm'));
  }
  top.append(node('span', 'row-fill'));
  top.append(node('span', 'sub', ago(sn.modifiedAt, Date.now())));

  const more = node('button', 'row-more');
  more.type = 'button';
  more.setAttribute('aria-label', `More for ${name}`);
  more.setAttribute('aria-haspopup', 'menu');
  more.append(icon(ICON.more));
  more.addEventListener('click', (e) => {
    e.stopPropagation();
    openMenu(more, [
      { label: 'Rename', run: () => { renaming = sn.sessionId; paintProjects(); } },
      { label: 'Copy session id', run: () => copyText(sn.sessionId, 'Copied the session id') },
      { label: 'Open in terminal', run: () => offerTerminal(more, sn.sessionId) },
      hiddenIds.has(sn.sessionId)
        ? { label: 'Show in list', run: () => { setHidden(sn.sessionId, false); paintProjects(); } }
        : { label: 'Hide from list', run: () => { setHidden(sn.sessionId, true); paintProjects(); } },
    ]);
  });
  top.append(more);
  row.append(top);
  // The same menu from a right click, where a menu for a row is expected to be.
  row.addEventListener('contextmenu', (e) => { e.preventDefault(); more.click(); });

  const subText = sessionSub(sn, status) + (ownedIds.has(sn.sessionId) ? ' · started here' : '');
  if (subText) row.append(marked(subText, 'sub srow-sub'));
  // What it spent, once the server has read it: time · tokens · ~cost. Asked for a few rows at a time.
  const spent = usageFor(sn);
  const line = usageLine(spent, { live: sessionStatus(sn.sessionId, fleetData).known && sessionStatus(sn.sessionId, fleetData).key !== 'ended', now: serverNow() });
  if (line) {
    const u = node('span', 'sub srow-usage', line);
    u.title = costNote(spent);
    row.append(u);
  }

  row.title = `${sn.sessionId}${sn.title ? `\n${sn.title}` : ''}`;
  const open = () => selectSession(sn.sessionId);
  row.addEventListener('click', open);
  row.addEventListener('keydown', (e) => {
    if (e.target !== row) return;
    if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); open(); }
  });
  return row;
}

/* What each session spent, for its row. The server reads a transcript once and keeps the answer until it grows, so
   this asks only for rows that are on screen and whose transcript has changed since it last asked. */
const usageRows = new Map();    // sessionId -> { at: modifiedAt it was read for, value }
const usageWanted = new Set();
let usageBusy = false;
function usageFor(sn) {
  const hit = usageRows.get(sn.sessionId);
  if (!hit || hit.at !== sn.modifiedAt) { usageWanted.add(sn.sessionId); queueMicrotask(pullUsage); }
  return hit?.value ?? null;
}
async function pullUsage() {
  if (usageBusy || !usageWanted.size) return;
  usageBusy = true;
  const ids = [...usageWanted].slice(0, 12);
  for (const id of ids) usageWanted.delete(id);
  try {
    const got = await getJson(`/api/usage?ids=${ids.map(encodeURIComponent).join(',')}`);
    for (const id of ids) {
      const sn = findSessionRow(id)?.session;
      // A session the server did not answer for (another machine's) is remembered as not read, and not asked again
      // until its row changes.
      usageRows.set(id, { at: sn?.modifiedAt ?? null, value: got.usage?.[id] ?? null });
    }
    paintProjects();
  } catch { /* the Live indicator says so; the rows keep what they had */ } finally {
    usageBusy = false;
    if (usageWanted.size) queueMicrotask(pullUsage);
  }
}

function paintProjects() {
  const data = projectsData;
  if (!data || renaming && document.activeElement?.classList?.contains('srow-rename')) return;

  // Typing a search is an explicit request, so it looks everywhere — including
  // the projects whose directories are gone. Hiding a result someone asked for
  // by name is worse than showing a dead path.
  const pool = (showMissing || filterText) ? data.projects : data.projects.filter((p) => p.exists);
  const missing = data.projects.length - pool.length;

  const frag = document.createDocumentFragment();
  let shown = 0;
  let hiddenCount = 0;

  for (const p of pool) {
    const projectHit = filterText && p.label.toLowerCase().includes(filterText);
    const sessions = p.sessions.filter((sn) => {
      if (hiddenIds.has(sn.sessionId) && !showHidden) { hiddenCount += 1; return false; }
      return !filterText || projectHit || matchesSession(filterText, p, sn, labels.all());
    });
    if (filterText && !projectHit && !sessions.length) continue;
    shown += 1;

    const open = expanded.has(p.key) || Boolean(filterText);
    const group = node('div', 'proj');
    const head = node('div', `proj-head${p.current ? ' current' : ''}${p.exists ? '' : ' gone'}`);
    head.tabIndex = 0;
    head.setAttribute('role', 'treeitem');
    head.setAttribute('aria-expanded', String(open));
    head.dataset.project = p.key;
    const caret = icon(ICON.chevron);
    caret.classList.add('proj-caret');
    head.append(caret, marked(p.label, 'proj-name'));
    // Where a project lives is part of its identity once more than one machine
    // is in view.
    if (p.origin && p.local === false) head.append(node('span', 'origin', p.origin));
    head.append(node('span', 'row-fill'), versionBadge(p.kit));
    head.title = (p.cwd ?? p.dir) + (p.exists ? '' : ' — directory no longer exists');
    const toggle = () => {
      if (expanded.has(p.key)) expanded.delete(p.key); else expanded.add(p.key);
      paintProjects();
    };
    head.addEventListener('click', toggle);
    head.addEventListener('keydown', (e) => {
      if (e.target !== head) return;
      if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggle(); }
    });
    group.append(head);

    if (open) {
      for (const sn of sessions) group.append(sessionRow(p, sn));
      if (p.total > p.sessions.length) {
        group.append(node('div', 'nav-line', `${p.total - p.sessions.length} older session(s) not listed`));
      }
    }
    frag.append(group);
  }

  if (!shown) {
    renderNote(el.sessions, filterText
      ? { title: 'No match', body: `Nothing here is called “${filterText}”.` }
      : { title: 'No projects', body: 'Measured — no transcript was found on this machine.' });
    return;
  }

  for (const o of (data.origins ?? []).filter((x) => x.ok === false)) {
    frag.append(node('div', 'nav-line bad', `${o.name} unreachable — ${o.reason}`));
  }
  const lineWith = (text, label, run) => {
    const line = node('div', 'nav-line');
    line.append(node('span', null, text));
    const b = node('button', 'link', label);
    b.type = 'button';
    b.addEventListener('click', run);
    line.append(b);
    return line;
  };
  if (hiddenIds.size && !filterText) {
    frag.append(lineWith(
      showHidden ? `${hiddenIds.size} hidden session(s) shown` : `${hiddenCount} session(s) hidden from this list`,
      showHidden ? 'hide' : 'show',
      () => { showHidden = !showHidden; paintProjects(); },
    ));
  }
  if (missing > 0 && !filterText) {
    frag.append(lineWith(
      `${missing} project(s) hidden — their directories no longer exist`, 'show',
      () => { showMissing = true; paintProjects(); },
    ));
  } else if (showMissing && !filterText) {
    frag.append(lineWith('Showing projects whose directories no longer exist', 'hide',
      () => { showMissing = false; paintProjects(); }));
  }
  el.sessions.replaceChildren(frag);

  if (!current) {
    const cur = data.projects.find((x) => x.current) ?? data.projects[0];
    const best = cur?.sessions.find((x) => x.agentCount > 0) ?? cur?.sessions[0];
    if (best) selectSession(best.sessionId);
  }
}

/* ------------------------------------------------------- live and machines */

function renderFleet(data) {
  fleetData = data;
  paintLive();
  paintMachines();
  // A session's dot comes from this answer, so the project list follows it, and
  // so does the pill on the session's own card.
  paintProjects();
  if (current) canvas.setSessionState(sessionStateNow());
  timeline.setLive(sessionIsLive());
}

function paintLive() {
  const data = fleetData;
  if (!data) return;

  if (!data.measured) {
    el.liveCount.hidden = false;
    el.liveCount.textContent = '?';
    el.liveCount.title = 'Not measured';
    renderNote(el.fleet, {
      kind: 'unmeasured',
      title: 'Not measured',
      body: 'This is not the same as "nothing is running" — nothing was read.',
      why: data.reason || 'no reason reported',
    });
    return;
  }

  const live = liveSessions(data);
  el.liveCount.hidden = live.length === 0;
  el.liveCount.textContent = String(live.length);
  el.liveCount.title = `${live.length} working or waiting`;

  const rows = live.filter((s) => !filterText
    || [s.name, s.cwd, s.sessionId, s.origin].some((v) => typeof v === 'string' && v.toLowerCase().includes(filterText)));

  if (!live.length) {
    const open = (data.sessions ?? []).length;
    renderNote(el.fleet, {
      title: 'No sessions running',
      body: open
        ? `Measured — ${open} open on this machine, none of them working or waiting.`
        : 'Measured — the machine has none open.',
    });
    return;
  }
  if (!rows.length) {
    renderNote(el.fleet, { title: 'No match', body: `No live session is called “${filterText}”.` });
    return;
  }

  el.fleet.replaceChildren(...rows.map((s) => {
    const status = sessionStatus(s.sessionId, { measured: true, sessions: [{ ...s, local: true }] });
    const known = findSessionRow(s.sessionId);
    const name = known ? sessionName(known.session, labels.all()) : (s.name || s.sessionId.slice(0, 8));
    const row = node('div', 'srow');
    const top = node('span', 'srow-top');
    top.append(dot(status.tone), marked(name, 'nm'));
    if (s.origin && s.local === false) top.append(node('span', 'origin', s.origin));
    top.append(node('span', 'row-fill'), node('span', 'sub', ago(s.startedAt, Date.now())));
    row.append(top);
    const where = known?.project.label ?? shortPath(s.cwd);
    const said = status.key === 'waiting' && s.waitingFor ? `Needs you · ${s.waitingFor}` : (status.word ?? s.status);
    row.append(marked([where, said].filter(Boolean).join(' · '), 'sub srow-sub'));

    if (s.local !== false && s.sessionId) {
      row.tabIndex = 0;
      row.dataset.id = s.sessionId;
      row.setAttribute('aria-current', String(s.sessionId === current));
      row.title = `Open ${name}`;
      const open = () => selectSession(s.sessionId);
      row.addEventListener('click', open);
      row.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); open(); } });
    } else {
      // A session on another machine has no transcript here to open.
      row.classList.add('remote');
      row.title = `${name} — on ${s.origin}. Its transcript is on that machine.`;
    }
    return row;
  }));
}

function machineRow(m) {
  const row = node('div', 'srow remote');
  const top = node('span', 'srow-top');
  top.append(icon(ICON.machine), node('span', 'mname', m.name), node('span', 'row-fill'));
  if (m.kind === 'snapshot') {
    // Recorded by a session, not asked just now: the label says which.
    top.append(node('span', 'badge', 'snapshot'));
    row.append(top);
    const seen = seenAgo(m.seenAt, Date.now());
    row.append(node('div', 'sub srow-sub', [m.status, m.note, seen].filter(Boolean).join(' · ')));
    row.title = `${m.name} — on another machine. Its transcript lives there, so the panel can list it but not draw it.`;
  } else {
    top.append(node('span', 'badge', 'peer'));
    row.append(top);
    const sub = node('div', `sub srow-sub${m.ok ? '' : ' bad'}`,
      m.ok ? `${m.sessions ?? 0} session(s) · asked just now` : `unreachable — ${m.reason ?? 'no reason given'}`);
    row.append(sub);
  }
  return row;
}

function paintMachines() {
  const m = machines(fleetData);
  const self = (fleetData?.origins ?? []).find((o) => o.local);
  const frag = document.createDocumentFragment();

  if (self) {
    const row = node('div', 'srow remote');
    const top = node('span', 'srow-top');
    top.append(icon(ICON.machine), node('span', 'mname', self.name), node('span', 'row-fill'), node('span', 'badge', 'this machine'));
    row.append(top);
    frag.append(row);
  }
  for (const p of m.peers) frag.append(machineRow(p));
  for (const r of m.remote) frag.append(machineRow(r));

  if (!m.remote.length) {
    // A roster nobody has recorded is not "no other machines". Say which it is.
    const note = node('div', 'nav-note');
    renderNote(note, {
      kind: m.rosterMeasured ? '' : 'unmeasured',
      title: m.rosterMeasured ? 'None reachable' : 'Not measured',
      body: m.rosterMeasured
        ? 'A connected session looked and found no machines besides this one.'
        : 'No session here has recorded a list of other machines yet.',
      why: m.rosterMeasured ? null : m.rosterReason,
    });
    frag.append(note);
  }
  el.reach.replaceChildren(frag);
  paintOtherMachines();
}

/** The short form under the project list: the first two, and the way to the rest. */
function paintOtherMachines() {
  const m = machines(fleetData);
  const others = [...m.peers, ...m.remote];
  el.otherMachines.hidden = navTab !== 'projects' || others.length === 0;
  if (el.otherMachines.hidden) return;
  const label = node('button', 'nav-foot-label', 'Other machines');
  label.type = 'button';
  label.addEventListener('click', () => setTab('machines'));
  const rows = others.slice(0, 2).map(machineRow);
  const more = others.length > 2 ? [node('div', 'nav-line', `${others.length - 2} more in Machines`)] : [];
  el.otherMachines.replaceChildren(label, ...rows, ...more);
}

/* ------------------------------------------------------------- sessions */

let current = null;
let source = null;
let statusFilter = null;
let lastStats = null;

/** The breadcrumb: which project, which session. The project is the way back to its list. */
function paintCrumb() {
  const found = current ? findSessionRow(current) : null;
  if (!found) { el.crumb.replaceChildren(); return; }
  const proj = node('button', 'crumb-project', found.project.label);
  proj.type = 'button';
  proj.title = `Show ${found.project.label} in the navigator`;
  proj.addEventListener('click', () => showProject(found.project.key));
  const sep = icon(ICON.chevron);
  sep.classList.add('crumb-sep');
  const name = node('span', 'crumb-session', sessionName(found.session, labels.all()));
  // The branch is on the session's row and on its card; here it is one hover away.
  name.title = found.session.branch ? `on ${found.session.branch}` : '';
  el.crumb.replaceChildren(proj, sep, name);
  fitBar();
}

function showProject(key) {
  el.filter.value = '';
  filterText = '';
  expanded.add(key);
  setTab('projects');
  setSideHidden(false);
  paintProjects();
  el.sessions.querySelector(`[data-project="${CSS.escape(key)}"]`)?.scrollIntoView({ block: 'nearest' });
}

/** The summary: one chip per status, each a filter on the canvas. Clicking the lit one puts everything back. */
function paintSummary(stats, extra = []) {
  lastStats = stats;
  const chips = summaryChips(stats?.byStatus);
  // A filter on a status nothing has any more would hide every agent with no chip left to undo it.
  if (statusFilter && !chips.some((c) => c.status === statusFilter)) setStatusFilter(null, false);
  const toggle = (c) => setStatusFilter(statusFilter === c.status ? null : c.status);
  const full = chips.map((c) => {
    const b = node('button', 'pill chip');
    b.type = 'button';
    b.setAttribute('aria-pressed', String(statusFilter === c.status));
    b.title = statusFilter === c.status ? 'Show every agent' : `Show only ${c.text.replace(/^\d+ /, '')}`;
    b.append(dot(c.tone), document.createTextNode(c.text));
    b.addEventListener('click', () => toggle(c));
    return b;
  });

  // The same chips as one: dots and counts, for a bar too narrow to spell them
  // out. The words are in its label and in the menu it opens, where each line
  // is the same filter the full chip is.
  const compact = [];
  if (chips.length) {
    const words = [...chips.map((c) => c.text), ...extra].join(', ');
    const b = node('button', 'pill chip chip-compact');
    b.type = 'button';
    b.setAttribute('aria-label', `Session summary: ${words}. Open details`);
    b.setAttribute('aria-haspopup', 'menu');
    b.setAttribute('aria-pressed', String(Boolean(statusFilter)));
    b.title = words;
    for (const c of chips) b.append(dot(c.tone), document.createTextNode(String(c.count)));
    b.append(icon('M4 6l4 4 4-4'));
    b.addEventListener('click', (e) => {
      e.stopPropagation();
      openMenu(b, [
        ...chips.map((c) => ({ label: c.text, tone: c.tone, checked: statusFilter === c.status, run: () => toggle(c) })),
        ...extra.map((t) => ({ note: t })),
      ]);
    });
    compact.push(b);
  }
  el.summary.replaceChildren(...full, ...extra.map((t) => node('span', 'pill note-pill', t)), ...compact);
  fitBar();
}

/** Spell the summary out while it fits; fold it into one chip the moment the bar would overflow. Measured, not
 *  guessed from the window's width: how much room the chips need depends on how many statuses are in play. */
function fitBar() {
  delete el.bar.dataset.compact;
  if (el.bar.scrollWidth > el.bar.clientWidth) el.bar.dataset.compact = 'true';
}
window.addEventListener('resize', fitBar);

function setStatusFilter(status, repaint = true) {
  statusFilter = status;
  show = 'all';
  tbValue.show.textContent = status ? 'One status' : SHOW.all.word;
  canvas.setFilter(status ? [status] : null);
  timeline.setFilter(status ? [status] : null);
  if (repaint) paintSummary(lastStats, lastStats?.malformed ? [`${lastStats.malformed} malformed`] : []);
}

/** The Show menu: the same filter the chips are, by what the viewer is looking for rather than by one status. */
function setShow(key) {
  show = key in SHOW ? key : 'all';
  statusFilter = null;
  tbValue.show.textContent = SHOW[show].word;
  canvas.setFilter(SHOW[show].statuses, { keepWaiting: Boolean(SHOW[show].waiting) });
  timeline.setFilter(SHOW[show].statuses, { keepWaiting: Boolean(SHOW[show].waiting) });
  paintSummary(lastStats, lastStats?.malformed ? [`${lastStats.malformed} malformed`] : []);
}

/* ------------------------------------------------------ needs attention */

let attentionIds = [];
let attentionAt = -1;

/** The strip above the canvas: who is waiting on the viewer, then who failed. Absent when nobody is. */
function paintAttention(nodes) {
  const list = attention(nodes ?? [], canvas.waiting);
  attentionIds = list.map((a) => a.id);
  // The strip takes 44px from the canvas when it appears and gives them back when it goes.
  const was = el.attention.hidden;
  el.attention.hidden = list.length === 0;
  if (was !== el.attention.hidden) canvas.fitIfUntouched();
  if (!list.length) { el.attention.replaceChildren(); attentionAt = -1; return; }
  const MAX = 5;
  const chips = list.slice(0, MAX).map((a) => {
    const b = node('button', 'att');
    b.type = 'button';
    b.append(dot(a.tone), node('span', 'att-name', a.name), node('span', 'att-says', a.says));
    b.title = a.real ?? '';
    b.addEventListener('click', () => { attentionAt = attentionIds.indexOf(a.id); goTo(a.id); });
    return b;
  });
  if (list.length > MAX) {
    const more = node('button', 'att', `+${list.length - MAX} more`);
    more.type = 'button';
    more.addEventListener('click', () => setShow('attention'));
    chips.push(more);
  }
  el.attention.replaceChildren(
    node('span', 'attention-label', 'Needs attention'), ...chips,
    node('span', 'row-fill'), node('span', 'sub attention-hint', 'Click one to go to it'),
  );
}

function stepAttention(by) {
  if (!attentionIds.length) return;
  attentionAt = (attentionAt + by + attentionIds.length) % attentionIds.length;
  goTo(attentionIds[attentionAt]);
}

// Selecting a session points the graph at it. It does NOT open the
// conversation: the navigator is for choosing what to look at, and having a
// reading panel appear on every click there made choosing expensive. The
// conversation is opened from the session node on the canvas, which is the
// thing that represents it.
// Where this session's agents are defined. Asked once per session; an answer for a session no longer shown is dropped.
async function loadOrigins(sessionId) {
  canvas.setOrigins(null);
  let o = null;
  try { o = await getJson(`/api/agents?session=${encodeURIComponent(sessionId)}`); } catch { /* the mark says whose it is without it */ }
  if (current === sessionId) canvas.setOrigins(o?.measured ? o : null);
}

function selectSession(sessionId) {
  if (current === sessionId) return;
  current = sessionId;
  canvas.setSession(sessionId);
  loadOrigins(sessionId);
  timeline.setSession(sessionId);
  list.setSession(sessionId);
  timeline.setFilter(null);
  timeline.setOwned(owned.get(sessionId) ?? null);
  statusFilter = null;
  show = 'all';
  tbValue.show.textContent = SHOW.all.word;
  canvas.setFilter(null);
  canvas.setSessionState(sessionStateNow());
  paintAttention(null);
  showInspector(null);
  paintWaiting(true);

  // The session being looked at is never inside a folded project: the row that
  // says "you are here" has to be on screen.
  const home = findSessionRow(sessionId);
  if (home && !expanded.has(home.project.key)) { expanded.add(home.project.key); paintProjects(); }
  for (const r of document.querySelectorAll('.srow[data-id]')) {
    r.setAttribute('aria-current', String(r.dataset.id === sessionId));
  }
  paintCrumb();
  paintSummary(null);
  // A new session means the cached agent reports belong to someone else.
  detailCache.clear();

  if (source) source.close();
  lastGraph = null;
  source = new EventSource(api(`/api/stream?session=${encodeURIComponent(sessionId)}`));

  source.addEventListener('graph', (e) => {
    heardNow();
    lastGraph = JSON.parse(e.data);
    showGraph();
  });

  source.addEventListener('idle', heardNow);

  source.addEventListener('waiting', (e) => {
    heardNow();
    let reason = '';
    try { reason = JSON.parse(e.data).reason ?? ''; } catch { /* keep default */ }
    paintSummary(null);
    paintAttention(null);
    timeline.setNodes([]);
    list.setNodes([]);
    el.foot.textContent = reason;
    canvas.render({ nodes: [], edges: [] });
  });

  // A server-side fault and a dropped connection are different facts. They
  // used to share EventSource's 'error' event, so "no such session" was shown
  // as "reconnecting" and the reason was thrown away.
  source.addEventListener('fault', (e) => {
    let reason = 'unknown';
    try { reason = JSON.parse(e.data).reason ?? reason; } catch { /* keep default */ }
    el.foot.textContent = `stream fault: ${reason}`;
    source.close();
    source = null;
  });

  // A dropped stream reconnects by itself, and the two polls say within two
  // seconds whether the server is gone. So this only names what happened; it
  // does not decide Offline.
  source.onerror = () => {
    if (!source) return;               // already closed by a fault
    el.foot.textContent = 'stream dropped — reconnecting';
  };
}

/* ------------------------------------------------------- live indicator */

const pulse = {
  dot: el.pulse.querySelector('.dot'),
  word: el.pulse.querySelector('strong'),
  detail: el.pulse.querySelector('.live-detail'),
};
function paintPulse() {
  const l = liveness(Date.now(), heard.okAt, heard.failed);
  el.pulse.dataset.state = l.state;
  pulse.dot.dataset.tone = l.tone ?? 'none';
  pulse.word.textContent = l.word;
  pulse.detail.textContent = l.detail ? `· ${l.detail}` : '';
}
paintPulse();
setInterval(() => { paintPulse(); dock.tick(); timeline.tick(); list.tick(); paintStageNote(); }, 1000);

/* -------------------------------------------------------------- home, keys */

// The mark goes back to where the panel opens: the session that moved last.
el.home.addEventListener('click', (e) => {
  e.preventDefault();
  let latest = null;
  for (const p of projectsData?.projects ?? []) {
    for (const sn of p.sessions) if (!latest || sn.modifiedAt > latest.sn.modifiedAt) latest = { p, sn };
  }
  setTab('projects');
  if (!latest) return;
  expanded.add(latest.p.key);
  paintProjects();
  selectSession(latest.sn.sessionId);
});

document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') {
    if (!el.menu.hidden) { closeMenu(); return; }
    if (document.activeElement === el.filter) {
      if (el.filter.value) { el.filter.value = ''; filterText = ''; paintProjects(); paintLive(); }
      return;
    }
    if (shell.classList.contains('side-open')) { setDrawer(false); return; }
    if (newPanel.isOpen) { newPanel.close(); return; }
    if (view === 'timeline' && timeline.selected) { timeline.select(null); return; }
    // Close the inspector and let go of the selection.
    if (!el.inspector.hidden) { canvas.clearSelection(); showInspector(null); }
    return;
  }
  // A letter is a shortcut only when it is not being typed into a field and no modifier is held: Cmd+R is the
  // browser's reload, not "reset layout".
  const key = shortcutOf(e);
  if (key === null) return;
  if (key === '/') {
    e.preventDefault();
    setSideHidden(false);
    el.filter.focus();
  } else if (key === '[') {
    setSideHidden(true);
  } else if (key === ']') {
    setSideHidden(false);
  } else if (key === 'g') {
    setView('graph');
  } else if (key === 't') {
    setView('timeline');
  } else if (key === 'l') {
    setView('list');
  } else if (key === 'r') {
    if (view === 'graph') resetLayout();
  } else if (key === 'j') {
    stepAttention(1);
  } else if (key === 'k') {
    stepAttention(-1);
  } else if (key === '?') {
    canvas.showLegend(true);
  }
});

/* ------------------------------------------------------------ approvals
   A session started here asks before every tool call. What is waiting, in every
   such session, is one queue, drawn in one place: the dock under the canvas. The
   rules are in approvals.js; this is where they meet the server and the page. */

const clock = new ServerClock();
const serverNow = () => clock.now(Date.now());
const owned = new Map();        // sessionId -> its summary, as /api/owned last gave it
const decided = new Map();      // request key -> the verdict this page sent
const answered = new Set();     // request keys the server has taken an answer for; the hook picks it up within a poll
const outcomes = new Map();     // sessionId -> what became of its requests, as far as this page saw
let waitingNow = [];
let waitingSig = '';
let lastNodes = null;
let lastGraph = null;   // what the stream last sent, before it is settled against the fleet
let lastLive = null;    // whether the session was live when that was last drawn

function sessionLabel(id) {
  const known = findSessionRow(id);
  return known ? sessionName(known.session, labels.all()) : null;
}

const dock = new Dock(el.dock, {
  now: serverNow,
  onDecide: decideRequest,
  onLocate: (item) => {
    if (item.sessionId !== current) selectSession(item.sessionId);
    if (item.agentId) goTo(item.agentId);
  },
  where: (item) => (item.sessionId === current ? null : item.sessionName),
});

/** Is the session being looked at still going? The fleet says so, and so does a session started here. */
function sessionIsLive() {
  if (!current) return false;
  const mine = owned.get(current);
  if (mine && ['starting', 'idle', 'working'].includes(mine.state)) return true;
  const st = sessionStatus(current, fleetData);
  return st.known && st.key !== 'ended';
}

/** The session card's state: waiting on the viewer outranks what the fleet says, as it does for an agent. */
function sessionStateNow() {
  const own = waitingNow.some((r) => r.sessionId === current && !r.agentId);
  if (own) return { key: 'waiting', word: 'Needs you', tone: 'waiting', known: true };
  return sessionStatus(current, fleetData);
}

/** Tell the canvas who is parked on an approval, so the card, its wire, the map and the strip all say it. */
function paintWaiting(force = false) {
  const here = waitingNow.filter((r) => r.sessionId === current);
  const sig = `${current}|${here.map((r) => r.agentId ?? 'session').sort().join(',')}`;
  if (!force && sig === waitingSig) return;
  waitingSig = sig;
  canvas.setWaiting(here.filter((r) => r.agentId).map((r) => r.agentId));
  timeline.setWaiting(here.filter((r) => r.agentId).map((r) => r.agentId));
  if (current) canvas.setSessionState(sessionStateNow());
  if (lastNodes) paintAttention(lastNodes);
  if (inspectorNode) paintInspector();
}

function paintApprovals() {
  // A request the server has recorded an answer for is over, as far as the viewer is concerned: the hook reads
  // the answer on its next poll, and until it does the request would sit here with nothing left to press.
  const listed = queue([...owned.values()], sessionLabel);
  for (const key of [...answered]) if (!listed.some((r) => r.key === key)) answered.delete(key);
  const next = listed.filter((r) => !answered.has(r.key));
  for (const s of settled(waitingNow, next, decided, serverNow())) {
    decided.delete(s.key);
    const log = outcomes.get(s.sessionId) ?? [];
    log.push(s);
    if (log.length > 40) log.shift();
    outcomes.set(s.sessionId, log);
    // An allowed call simply goes ahead; a refused one is said, because the agent has already been told.
    if (s.outcome === 'denied' || s.outcome === 'timed-out') dock.say(s.outcome, next.length > 0);
  }
  waitingNow = next;
  // The dock takes its height from the canvas when it appears and gives it back when it goes.
  const was = el.dock.hidden;
  dock.render(next);
  list.setQueue(next);
  chat.setWaiting(next);
  // The Timeline's waiting periods are the server's record of this session's approvals; a session Studio did
  // not start has none, and the Timeline says so.
  timeline.setOwned(current ? owned.get(current) ?? null : null);
  timeline.setLive(sessionIsLive());
  measureDock();
  if (was !== el.dock.hidden) canvas.fitIfUntouched();
  paintWaiting();
  if (inspectorNode && inspectorTab === 'gates') paintInspector();
}

async function decideRequest(item, verdict) {
  decided.set(item.key, verdict);
  let res;
  try {
    const r = await fetch(
      api(`/api/owned/${encodeURIComponent(item.sessionId)}/permissions/${encodeURIComponent(item.toolUseId)}`),
      { method: 'POST', headers: { 'content-type': 'application/json', ...writeHeaders }, body: JSON.stringify({ verdict }) },
    );
    res = await r.json();
  } catch (e) {
    res = { ok: false, reason: e.message };
  }
  if (!res.ok) {
    // Nothing reached the hook, so nothing was decided: the buttons come back and the clock is still running.
    decided.delete(item.key);
    dock.release(item.key);
    list.release(item.key);
    toast(`Decision not recorded — ${res.reason ?? 'no reason given'}`);
    return;
  }
  answered.add(item.key);
  paintApprovals();
  pollOwned();
}

// The dock's height and form follow its own size. A floating inspector stops above it, so the three answers are
// never under a panel; and a dock too narrow for one row goes to two, whatever the window's width.
const DOCK_ONE_ROW_PX = 760;
let dockSize = '';
function measureDock() {
  const h = el.dock.hidden ? 0 : el.dock.offsetHeight;
  const form = el.dock.hidden ? '' : (el.dock.offsetWidth < DOCK_ONE_ROW_PX ? 'stacked' : 'row');
  // Written only when it changed: this runs from a resize observer, and a write that changes nothing would
  // still ask for another layout.
  const size = `${h}|${form}`;
  if (size === dockSize) return;
  dockSize = size;
  shell.style.setProperty('--dock-h', `${h}px`);
  if (form) el.dock.dataset.form = form;
}
// A frame later, so the write is not made inside the observer's own delivery.
if (typeof ResizeObserver !== 'undefined') new ResizeObserver(() => requestAnimationFrame(measureDock)).observe(el.dock);

// The sessions this panel owns: which ones, what each is waiting for, and what time the server makes it.
// They survive a page reload as long as the server does.
let ownedBusy = false;
async function pollOwned() {
  if (ownedBusy) return;
  ownedBusy = true;
  try {
    const r = await getJson('/api/owned');
    clock.sync(r.now, Date.now());
    if (Array.isArray(r.modes)) offeredModes = r.modes;
    const seen = new Set();
    for (const sn of r.sessions ?? []) { ownedIds.add(sn.sessionId); owned.set(sn.sessionId, sn); seen.add(sn.sessionId); }
    for (const id of [...owned.keys()]) if (!seen.has(id)) owned.delete(id);
    paintApprovals();
  } catch { /* the Live indicator says so; the dock keeps what it last showed, clock included */ }
  finally { ownedBusy = false; }
}

// A pane's stream says the moment a session's queue changes. It replays what it has already said when it
// reconnects, so it is taken as a reason to ask, not as the answer.
chat.onPermissions = () => pollOwned();

/* ------------------------------------------------------- the stage's note
   One line above the view, for two things that are about the whole stage: the server is not answering, or this
   view is being shown in a window too narrow for it. Offline is said first. */

let nextPollAt = null;
const stageNote = { text: node('span', 'stage-note-text'), retry: node('span', 'sub'), button: node('button', 'btn sm', 'Retry now') };
stageNote.button.type = 'button';
stageNote.button.addEventListener('click', () => retryNow());
el.stageNote.append(stageNote.text, stageNote.retry, node('span', 'row-fill'), stageNote.button);

function paintStageNote() {
  const l = liveness(Date.now(), heard.okAt, heard.failed);
  const off = offlineNote(l.state, heard.okAt, nextPollAt, Date.now());
  const warn = narrowWarning(view, phoneBand.matches);
  // The last picture stays on screen while the server is away, and is drawn as old.
  el.stage.dataset.offline = String(Boolean(off));
  el.stageNote.hidden = !off && !warn;
  el.stageNote.dataset.kind = off ? 'offline' : 'narrow';
  stageNote.text.textContent = off ? off.text : (warn ?? '');
  stageNote.retry.textContent = off ? off.retry : '';
  stageNote.retry.hidden = !off;
  stageNote.button.hidden = !off;
  // The fleet can say a session ended, or came back, with no transcript changing.
  if (lastGraph && sessionIsLive() !== lastLive) showGraph();
  else if (lastLive === true) paintSpend();
  paintFoldButtons();
  paintTerminalWait();
}

/**
 * Draw the graph the stream last sent. What the server read from files is settled against what the machine says
 * of the session first, so this is called again when that changes with no file changing.
 */
/** The summary box, from the session on screen. A live session's time is counted to now, so this runs on the tick. */
function paintSpend() {
  const usage = lastNodes?.find((n) => n.kind === 'session')?.usage ?? null;
  canvas.setSpend(summaryRows(usage, { live: lastLive === true, now: serverNow() }));
}

function showGraph() {
  if (!lastGraph) return;
  lastLive = sessionIsLive();
  const g = settle(lastGraph, lastLive);
  canvas.render(g);
  lastNodes = g.nodes;
  paintSpend();
  timeline.setNodes(g.nodes);
  list.setNodes(g.nodes);
  paintAttention(g.nodes);
  // The conversation's delegation cards and its context figure are the graph's.
  chat.refresh(current, { contextTokens: g.nodes.find((n) => n.kind === 'session')?.tokens ?? null });
  // The inspector holds a node object from an earlier frame; refresh it so
  // status, tokens and tool counts keep moving while it is open.
  if (inspectorNode) {
    const fresh = g.nodes.find((n) => n.id === inspectorNode.id);
    if (fresh) {
      const changed = fresh.status !== inspectorNode.status;
      inspectorNode = fresh;
      paintInspector();
      if (changed && fresh.kind === 'agent') loadDetail(fresh.id, fresh.status);
    }
  }
  // Every status is named, so the chips add up to the total. A summary that
  // reports "250 agents · 7 done" and stops invites the reader to assume the
  // other 243 failed. A count of records that could not be read stays beside
  // them: it is not a status, and it is not nothing.
  const s = g.stats ?? {};
  paintSummary(s, s.malformed ? [`${s.malformed} malformed`] : []);
  el.foot.textContent = '';
}

/** A session waiting on its own terminal is said under the view, with what it asks about. */
let terminalWaitSig = '';
function paintTerminalWait() {
  const session = lastNodes?.find((n) => n.kind === 'session') ?? null;
  const w = current
    ? terminalWait(sessionStatus(current, fleetData), session, ownedIds.has(current) || owned.has(current))
    : null;
  const sig = w ? `${w.text}|${w.what ?? ''}` : '';
  if (sig === terminalWaitSig) return;
  terminalWaitSig = sig;
  el.terminalWait.hidden = !w;
  if (w) {
    const what = node('span', 'terminal-wait-what', w.what ?? '');
    what.title = w.what ?? '';
    el.terminalWait.replaceChildren(
      node('span', 'terminal-wait-word', `${w.text}${w.what ? ':' : ''}`), what,
      node('span', 'sub terminal-wait-note', 'Studio answers only for sessions started here'),
    );
  }
  canvas.fitIfUntouched();
}

function retryNow() {
  nextPollAt = Date.now() + FLEET_POLL_MS;
  pollFleet(); pollSessions(); pollOwned();
}

/* ---------------------------------------------------------------- phone
   Under 640px the bar has room for the mark and three controls. The session's name and its summary move under
   it, above the view; the navigator is a drawer the menu button opens. */

const barFill = el.bar.querySelector('.bar-fill');
const afterSummary = el.summary.nextElementSibling;

function setDrawer(open) {
  shell.classList.toggle('side-open', open);
  el.menuBtn.setAttribute('aria-expanded', String(open));
  el.menuBtn.setAttribute('aria-label', open ? 'Close the navigator' : 'Open the navigator');
}
el.menuBtn.addEventListener('click', () => setDrawer(!shell.classList.contains('side-open')));
// Choosing a session in the drawer is why it was opened; it closes behind the choice.
el.sessions.addEventListener('click', (e) => { if (phoneBand.matches && e.target.closest?.('.srow')) setDrawer(false); });
el.fleet.addEventListener('click', (e) => { if (phoneBand.matches && e.target.closest?.('.srow, .live-row')) setDrawer(false); });
el.sideHide.addEventListener('click', () => { if (phoneBand.matches) setDrawer(false); });

let headOnPhone = false;
function applyPhoneBand(initial = false) {
  // Moved only when the band changes: the bar is where they are written in the page.
  if (phoneBand.matches && !headOnPhone) {
    el.phoneHead.append(el.crumb, el.summary);
    headOnPhone = true;
  } else if (!phoneBand.matches && headOnPhone) {
    el.bar.insertBefore(el.crumb, barFill);
    el.bar.insertBefore(el.summary, afterSummary);
    headOnPhone = false;
    setDrawer(false);
  }
  // A window that crosses the line takes that width's default view, unless the viewer has chosen one.
  if (!initial && !store.get('crewforth-studio-view')) setView(defaultView(null, phoneBand.matches), null, false);
  paintStageNote();
  fitBar();
}
phoneBand.addEventListener('change', () => applyPhoneBand());

/* --------------------------------------------------------------- polling */

async function pollFleet() {
  try {
    renderFleet(await getJson('/api/fleet'));
  } catch (e) {
    renderNote(el.fleet, { kind: 'unmeasured', title: 'Server unreachable', why: e.message });
  }
}

async function pollSessions() {
  try {
    renderSessions(await getJson('/api/projects'));
  } catch { /* the Live indicator says so; the list keeps what it last showed */ }
}

setTab(store.get('crewforth-studio-nav-tab') ?? 'projects');
// The view the viewer chose, or the one this window opens on: the List on a phone, the graph elsewhere.
applyPhoneBand(true);
{
  const stored = store.get('crewforth-studio-view');
  setView(defaultView(stored, phoneBand.matches), null, Boolean(stored));
}
pollFleet(); pollSessions(); pollOwned();
setInterval(() => { nextPollAt = Date.now() + FLEET_POLL_MS; pollFleet(); }, FLEET_POLL_MS);
nextPollAt = Date.now() + FLEET_POLL_MS;
setInterval(pollOwned, FLEET_POLL_MS);
setInterval(pollSessions, SESSION_POLL_MS);
