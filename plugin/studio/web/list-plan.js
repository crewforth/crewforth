// What the List view shows: the session's agents by what they need from the reader, in a fixed order.
//
// Needs you, then Failed, then Running, then Done. The order never changes with the data, so the thing that
// needs someone is always at the top. A status this panel has no word for is not put into one of the four: it
// gets a section of its own, under its own name, after them.
import { stateOf } from './graph-plan.js';
import { typeOf, shownType } from './names.js';

/** "8m", "1h 4m", "40s": how long, in as little room as a row has. */
export function short(ms) {
  if (ms == null || !Number.isFinite(ms) || ms < 0) return null;
  const s = Math.floor(ms / 1000);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m`;
  return `${Math.floor(m / 60)}h ${m % 60}m`;
}

const when = (n) => n.endedAt ?? n.updatedAt ?? n.startedAt ?? 0;

/** One agent as a row: who, what it is on, and the one number worth the room. */
function rowOf(n, now) {
  const state = stateOf(n.status);
  if (state === 'failed') {
    const bits = [];
    if (n.workflow) bits.push(`in ${n.workflow}`);
    // The count the transcript gave. An agent can fail without a tool error; then there is none to report.
    if (n.errors) bits.push(`${n.errors} ${n.errors === 1 ? 'error' : 'errors'}`);
    if (n.status !== 'failed') bits.push(n.status);
    return { id: n.id, node: n, type: shownType(n), real: typeOf(n), line: bits.join(' · ') || (n.description ?? ''), aside: null };
  }
  const live = state === 'live' || state === 'waking';
  return {
    id: n.id,
    node: n,
    type: shownType(n),
    real: typeOf(n),
    line: n.description ?? '',
    // How long it has been going. With no start recorded there is nothing to count from, and nothing is shown.
    aside: state === 'waking' ? 'starting' : live && n.startedAt != null ? short(now - n.startedAt) : null,
  };
}

/**
 * The sections of the List, top to bottom. A section with nothing in it is left out.
 *
 * @param nodes    the graph's nodes
 * @param queue    the approval queue (every session started here), as approvals.js orders it
 * @param current  the session being looked at
 * @param folded   Map sectionKey -> boolean, the viewer's own choices; a section not in it takes its default
 * @param all      true after "Expand all", false after "Fold all": what a section not in `folded` is
 */
export function sections(nodes, { queue = [], current = null, folded = new Map(), all = null, now = 0 } = {}) {
  const agents = (nodes ?? []).filter((n) => n.kind === 'agent');
  const out = [];

  // Needs you: every request waiting, this session's first. Each is a card that carries its own answers.
  const cards = [...queue].sort((a, b) => Number(b.sessionId === current) - Number(a.sessionId === current) || (a.askedAt ?? 0) - (b.askedAt ?? 0));
  if (cards.length) out.push({ key: 'needs', title: 'Needs you', count: cards.length, tone: 'waiting', cards, rows: [], folded: false, foldable: false });

  const by = (pred, sort) => agents.filter(pred).sort(sort).map((n) => rowOf(n, now));
  const newest = (a, b) => when(b) - when(a);
  const oldest = (a, b) => (a.startedAt ?? Infinity) - (b.startedAt ?? Infinity) || String(a.id).localeCompare(String(b.id));

  const fixed = [
    { key: 'failed', title: 'Failed', tone: 'fail', rows: by((n) => stateOf(n.status) === 'failed', newest), foldedByDefault: false },
    { key: 'running', title: 'Running', tone: 'busy', rows: by((n) => ['live', 'waking'].includes(stateOf(n.status)), oldest), foldedByDefault: false },
    { key: 'done', title: 'Done', tone: 'good', rows: by((n) => stateOf(n.status) === 'done', newest), foldedByDefault: true },
  ];

  // Everything else, by the status the transcript wrote. `ended` and `stale` have words here; anything the panel
  // does not recognise keeps its own.
  const rest = new Map();
  for (const n of agents) {
    const s = stateOf(n.status);
    if (s === 'failed' || s === 'live' || s === 'waking' || s === 'done') continue;
    const key = String(n.status ?? 'unknown');
    if (!rest.has(key)) rest.set(key, []);
    rest.get(key).push(n);
  }
  const WORD = { ended: 'Ended', stale: 'Stale' };
  for (const [status, members] of [...rest].sort((a, b) => a[0].localeCompare(b[0]))) {
    fixed.push({
      key: `status:${status}`, title: WORD[status] ?? status, tone: 'none', known: status in WORD,
      rows: members.sort(newest).map((n) => rowOf(n, now)), foldedByDefault: true,
    });
  }

  for (const s of fixed) {
    if (!s.rows.length) continue;
    out.push({
      key: s.key, title: s.title, count: s.rows.length, tone: s.tone, cards: [], rows: s.rows,
      // As the viewer left it; untouched, it follows the last "Expand all" or "Fold all" (`all`), and before
      // either its own default.
      folded: folded.has(s.key) ? folded.get(s.key) : (typeof all === 'boolean' ? !all : s.foldedByDefault), foldable: true,
    });
  }
  return out;
}

/** What a request card says under the agent's name. */
export function wants(item) {
  if (item.ask?.kind === 'questions') return 'asks';
  if (item.ask?.kind === 'plan') return 'wants its plan approved';
  return `wants to run ${item.toolName}`;
}

/** Which view a window opens on when the viewer has not chosen one: the List on a phone, the graph elsewhere. */
export function defaultView(stored, phone) {
  if (stored === 'graph' || stored === 'timeline' || stored === 'list' || stored === 'models') return stored;
  return phone ? 'list' : 'graph';
}

/** The graph and the Timeline are drawn for a wide window. On a phone they still open, and say so. */
export function narrowWarning(view, phone) {
  return phone && view !== 'list' ? 'Best on a wider screen' : null;
}
