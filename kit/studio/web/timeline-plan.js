// What the Timeline draws, worked out from the graph's nodes with no page in it.
//
// A row is an agent, several agents of one type, a group's header, or the link that shows the rest of a group.
// A bar is where an agent was in time and what it was doing there. Everything here is a function of the server's
// data and the viewer's choices, so it can be checked without a browser.
//
// Two things the data does not hold are not invented. An agent with no recorded start has no bar. And the only
// change of state an agent's bar can show is a wait on the viewer, because that is the only one anything
// records: the server's log of approvals, for sessions started here. An agent that failed is drawn failed for
// its whole length — the transcript says how it ended, not when it started going wrong.
import { stateOf, tally } from './graph-plan.js';
import { typeOf, shownType } from './names.js';

export const RANGES = [
  { key: '5m', ms: 5 * 60_000 },
  { key: '15m', ms: 15 * 60_000 },
  { key: '1h', ms: 60 * 60_000 },
  { key: 'all', ms: null },
];
export const DEFAULT_RANGE = '15m';

// A group with more rows than this shows the first few and a link to the rest.
export const GROUP_ROWS = { showAllUpTo: 6, shown: 4 };

const SESSION = 'session';
const TONE = { live: 'busy', waking: 'busy', done: 'done', failed: 'fail', quiet: 'quiet', unknown: 'quiet' };

const isLive = (n) => { const s = stateOf(n.status); return s === 'live' || s === 'waking'; };

/** Where an agent's bar ends: its recorded end, or now while it is still going. */
function endOf(n, now) {
  if (isLive(n)) return now;
  return n.endedAt ?? n.updatedAt ?? null;
}

/**
 * One agent's bar, as the pieces it is drawn in.
 *
 * @param approvals the session's approval record (server), or null when Studio does not see them
 * @returns [] when no start was recorded — there is nothing to place
 */
export function segments(n, approvals, now) {
  if (n.startedAt == null) return [];
  const end = endOf(n, now);
  if (end == null || end < n.startedAt) return [];
  const tone = TONE[stateOf(n.status)] ?? 'quiet';
  const waits = (approvals ?? [])
    .filter((a) => a.agentId === n.id)
    .map((a) => ({ from: Math.max(a.askedAt, n.startedAt), to: Math.min(a.endedAt ?? now, end) }))
    .filter((w) => w.to > w.from)
    .sort((a, b) => a.from - b.from);

  const out = [];
  let at = n.startedAt;
  for (const w of waits) {
    if (w.from > at) out.push({ from: at, to: w.from, tone });
    const from = Math.max(w.from, at);
    if (w.to > from) out.push({ from, to: w.to, tone: 'wait' });
    at = Math.max(at, w.to);
  }
  if (end > at || !out.length) out.push({ from: at, to: end, tone });
  // The end of a failed agent is marked, on its last piece.
  if (tone === 'fail') out[out.length - 1].failedAt = end;
  for (const s of out) s.id = n.id;
  return out;
}

/** What the right of a row says about one agent. */
export function agentSub(n, waiting) {
  if (waiting?.has(n.id)) return { text: 'needs you', tone: 'wait' };
  const s = stateOf(n.status);
  if (s === 'failed') return { text: n.status, tone: 'fail' };
  if (s === 'live') return { text: 'running', tone: null };
  if (s === 'waking') return { text: 'starting', tone: null };
  if (s === 'done') return { text: 'done', tone: null };
  // A status this panel has no word for keeps its own.
  return { text: String(n.status ?? 'unknown'), tone: null };
}

/** "12 done · 2 running" for several agents, in the order a reader looks for them. */
export function countsSub(members, waiting) {
  const need = members.filter((m) => waiting?.has(m.id)).length;
  const counts = tally(members.filter((m) => !waiting?.has(m.id)));
  const parts = [];
  if (need) parts.push(`${need} need you`);
  const word = { running: 'running', starting: 'starting', done: 'done', failed: 'failed', killed: 'killed', stopped: 'stopped', ended: 'ended', stale: 'stale' };
  for (const k of ['failed', 'killed', 'stopped', 'running', 'starting', 'done', 'ended', 'stale']) {
    if (counts[k]) parts.push(`${counts[k]} ${word[k]}`);
  }
  for (const [k, v] of Object.entries(counts)) if (!word[k]) parts.push(`${v} ${k}`);
  return parts.join(' · ');
}

/**
 * Put bars that overlap on different lanes, two at most.
 * Returns lanes as arrays of segments; with one lane the bars are full height, with two they are thin.
 */
export function lanes(bars) {
  const sorted = bars.slice().sort((a, b) => a.from - b.from);
  const ends = [-Infinity, -Infinity];
  const out = [[], []];
  for (const b of sorted) {
    // The lane that has been free longest; with both busy, the one that frees first.
    const i = ends[0] <= b.from ? 0 : ends[1] <= b.from ? 1 : (ends[0] <= ends[1] ? 0 : 1);
    out[i].push(b);
    ends[i] = Math.max(ends[i], b.to);
  }
  return out[1].length ? out : [out[0]];
}

/** The groups of a session's agents under one grouping, in the order they first started. */
export function groupsOf(nodes, grouping) {
  const agents = nodes.filter((n) => n.kind === 'agent');
  const byId = new Map(nodes.map((n) => [n.id, n]));
  const key = (n) => {
    if (grouping === 'type') return { id: `type:${typeOf(n)}`, label: shownType(n), real: typeOf(n) };
    if (grouping === 'parent') {
      const p = byId.get(n.parentId);
      if (!p || p.kind === 'session') return { id: 'direct', label: 'Session · direct' };
      return { id: `parent:${p.id}`, label: p.kind === 'workflow' ? (p.workflowId ?? p.id) : `under ${shownType(p)}` };
    }
    if (grouping === 'none') return { id: 'all', label: null };
    // `run`: a workflow run is a group; everything the session started itself is another.
    if (n.workflow) return { id: `run:${n.workflow}`, label: String(n.workflow) };
    return { id: 'direct', label: 'Session · direct' };
  };
  const groups = new Map();
  for (const n of agents) {
    const k = key(n);
    if (!groups.has(k.id)) groups.set(k.id, { id: k.id, label: k.label, members: [] });
    groups.get(k.id).members.push(n);
  }
  const first = (g) => Math.min(...g.members.map((m) => m.startedAt ?? Infinity));
  const out = [...groups.values()];
  for (const g of out) g.members.sort((a, b) => (a.startedAt ?? Infinity) - (b.startedAt ?? Infinity) || String(a.id).localeCompare(String(b.id)));
  // What the session did itself comes first; the rest in the order they began.
  out.sort((a, b) => Number(b.id === 'direct') - Number(a.id === 'direct') || first(a) - first(b) || a.id.localeCompare(b.id));
  return out;
}

/**
 * The rows of the Timeline, top to bottom.
 *
 * @param opts.group     'run' | 'type' | 'parent' | 'none'
 * @param opts.folded    Set of group ids the viewer folded
 * @param opts.expanded  Set of group ids whose "Show N more" was used
 * @param opts.waiting   Set of agent ids parked on an approval right now
 * @param opts.approvals the session's approval record, or null
 * @param opts.now       the server's clock
 */
export function rows(nodes, opts = {}) {
  const { group = 'run', folded = new Set(), expanded = new Set(), waiting = new Set(), approvals = null, now = 0 } = opts;
  const out = [];
  const bar = (n) => segments(n, approvals, now);

  for (const g of groupsOf(nodes, group)) {
    const headed = g.label !== null;
    const isFolded = headed && folded.has(g.id);
    if (headed) {
      out.push({
        kind: 'group',
        id: g.id,
        label: g.label,
        folded: isFolded,
        sub: `${g.members.length} ${g.members.length === 1 ? 'agent' : 'agents'}${countsSub(g.members, waiting) ? ` · ${countsSub(g.members, waiting)}` : ''}`,
        // Folded, the header carries its members' bars, so a group that is out of sight is not out of time.
        lanes: isFolded ? lanes(g.members.flatMap(bar)) : [],
      });
      if (isFolded) continue;
    }

    // Several agents of one type, next to each other in a group, are one row: the same thing several times.
    // Not under `type` — there the group already is the type — and not under `none`, which means none.
    const merge = group === 'run' || group === 'parent';
    const body = [];
    const seen = new Set();
    for (const n of g.members) {
      if (seen.has(n.id)) continue;
      const same = merge ? g.members.filter((m) => typeOf(m) === typeOf(n)) : [n];
      for (const m of same) seen.add(m.id);
      if (same.length > 1) {
        body.push({
          kind: 'merged', id: `${g.id}|${typeOf(n)}`, group: g.id, label: `${shownType(n)} × ${same.length}`, real: typeOf(n),
          sub: countsSub(same, waiting), members: same, lanes: lanes(same.flatMap(bar)), indent: headed && g.id !== 'direct',
        });
      } else {
        const sub = agentSub(n, waiting);
        body.push({
          kind: 'agent', id: n.id, group: g.id, node: n, label: shownType(n), real: typeOf(n), sub: sub.text, tone: sub.tone,
          bars: bar(n), timed: n.startedAt != null, indent: headed && g.id !== 'direct',
        });
      }
    }

    const cut = headed && body.length > GROUP_ROWS.showAllUpTo && !expanded.has(g.id);
    const shown = cut ? body.slice(0, GROUP_ROWS.shown) : body;
    out.push(...shown);
    if (cut) out.push({ kind: 'more', id: `${g.id}|more`, group: g.id, count: body.length - shown.length, indent: true });
  }
  return out;
}

/** When the session's time starts and ends: its earliest start, and now if anything is still going. */
export function extent(nodes, now, live) {
  let from = Infinity;
  let to = -Infinity;
  for (const n of nodes) {
    if (n.startedAt != null) from = Math.min(from, n.startedAt);
    const end = n.kind === 'agent' ? endOf(n, now) : (n.endedAt ?? n.updatedAt ?? null);
    if (end != null) to = Math.max(to, end);
  }
  if (live) to = Math.max(to, now);
  if (!Number.isFinite(from) || !Number.isFinite(to)) return null;
  return { from, to: Math.max(to, from + 1000) };
}

/**
 * The stretch of time on screen.
 *
 * Following, it ends at now. Not following, it ends where the viewer left it. `all` is the whole session.
 * A range longer than the session shows the whole session rather than empty time before it began.
 */
export function windowOf(ext, rangeKey, { follow = true, end = null } = {}) {
  if (!ext) return null;
  const range = RANGES.find((r) => r.key === rangeKey) ?? RANGES.find((r) => r.key === DEFAULT_RANGE);
  const whole = ext.to - ext.from;
  const span = range.ms == null ? whole : Math.min(range.ms, Math.max(whole, 60_000));
  if (range.ms == null || span >= whole) return { from: ext.from, to: ext.from + Math.max(span, whole), span: Math.max(span, whole) };
  let to = follow || end == null ? ext.to : Math.min(Math.max(end, ext.from + span), ext.to);
  return { from: to - span, to, span };
}

/** Where a moment falls across a track `width` pixels wide. */
export function xOf(t, win, width) {
  return ((t - win.from) / win.span) * width;
}

/** A bar's place on the track, clipped to what is on screen; null when none of it is. */
export function place(seg, win, width, minW = 2) {
  const from = Math.max(seg.from, win.from);
  const to = Math.min(seg.to, win.to);
  if (to <= from && !(seg.from >= win.from && seg.from <= win.to)) return null;
  const left = xOf(from, win, width);
  return { left, width: Math.max(minW, xOf(Math.max(to, from), win, width) - left), cutLeft: seg.from < win.from, cutRight: seg.to > win.to };
}

const STEPS = [10_000, 30_000, 60_000, 5 * 60_000, 15 * 60_000, 30 * 60_000, 3_600_000, 3 * 3_600_000, 6 * 3_600_000, 12 * 3_600_000, 24 * 3_600_000];

/** The marks on the axis: round moments, about one every 120 pixels. */
export function ticks(win, width) {
  const want = Math.max(2, Math.floor(width / 120));
  const step = STEPS.find((s) => win.span / s <= want) ?? STEPS[STEPS.length - 1];
  const out = [];
  for (let t = Math.ceil(win.from / step) * step; t <= win.to; t += step) out.push({ at: t, seconds: step < 60_000 });
  return out;
}

/** HH:MM, or HH:MM:SS, in the viewer's own time zone. */
export function clock(ms, seconds = false) {
  const d = new Date(ms);
  const p = (n) => String(n).padStart(2, '0');
  return `${p(d.getHours())}:${p(d.getMinutes())}${seconds ? `:${p(d.getSeconds())}` : ''}`;
}

/** The next range in or out; null at either end. */
export function stepRange(key, by) {
  const i = RANGES.findIndex((r) => r.key === key);
  const next = RANGES[i + by];
  return next ? next.key : null;
}

/**
 * The line under the rows that says where the waiting periods come from, or that there are none to show.
 * @param owned the session's summary when Studio started it, else null
 */
export function waitNote(owned) {
  if (!owned) return { measured: false, text: 'Not measured: this session\'s approvals are not seen by Studio.' };
  if (owned.gated === false) return { measured: false, text: 'Not measured: this session runs without the approval gate.' };
  return { measured: true, text: `Waiting periods since Studio started this session at ${clock(owned.startedAt)}.` };
}

/** "14:01 → 14:09 · 8m 12s · 31 tool calls · 57k tokens", with only the parts that were read. */
export function factsOf(n, now, fmt) {
  const parts = [];
  const end = n.kind === 'agent' ? endOf(n, now) : n.endedAt;
  if (n.startedAt != null) parts.push(isLive(n) || end == null ? `${clock(n.startedAt)} → now` : `${clock(n.startedAt)} → ${clock(end)}`);
  if (n.startedAt != null && end != null) parts.push(fmt.duration(end - n.startedAt));
  if (n.toolCount != null) parts.push(`${n.toolCount} tool ${n.toolCount === 1 ? 'call' : 'calls'}`);
  if (n.tokens != null) parts.push(`${fmt.tokens(n.tokens)} tokens`);
  return parts.join(' · ');
}
