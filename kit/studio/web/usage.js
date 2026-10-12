// What a session spent, as words: how long, how many tokens, and an estimate of the cost.
//
// The numbers are the server's (server/lib/usage.js); the prices are in one file there (server/lib/pricing.js).
// Nothing here knows a price. The cost is an estimate at API list price and is always written as one: a leading
// "~", and a note that says what it is. A session with tokens from a model the price table does not have gets
// a dash, not a smaller number.

import { modelName } from './names.js';

export const COST_NOTE = 'Estimated at API list price; on a subscription it is not what you are billed';
export const NO_COST = '—';

/** 950 · 12.4k · 3.2M · 1.53B */
export function fmtCount(n) {
  if (n == null || !Number.isFinite(n)) return null;
  if (n < 1000) return String(Math.round(n));
  if (n < 1_000_000) return `${(n / 1000).toFixed(n < 100_000 ? 1 : 0)}k`;
  if (n < 1_000_000_000) return `${(n / 1_000_000).toFixed(n < 100_000_000 ? 1 : 0)}M`;
  return `${(n / 1_000_000_000).toFixed(2)}B`;
}

/** "~$4.10", "~$1,240", "<$0.01"; a dash when there is no estimate to give. */
export function fmtCost(usd) {
  if (usd == null || !Number.isFinite(usd)) return NO_COST;
  if (usd > 0 && usd < 0.01) return '<$0.01';
  if (usd >= 1000) return `~$${Math.round(usd).toLocaleString('en-US')}`;
  return `~$${usd.toFixed(2)}`;
}

/** "40s", "12m", "3h 5m", "2d 4h": coarse, for a line with no room. */
export function fmtSpan(ms) {
  if (ms == null || !Number.isFinite(ms) || ms < 0) return null;
  const s = Math.round(ms / 1000);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ${m % 60}m`;
  return `${Math.floor(h / 24)}d ${h % 24}h`;
}

/**
 * How long a session took. The time Claude Code itself timed its turns at, when it recorded any; otherwise the
 * time from the first record to the last, which counts every pause as well.
 * @returns { ms, kind: 'worked' | 'elapsed', note } or null
 */
export function timeOf(u) {
  if (u?.workedMs) return { ms: u.workedMs, kind: 'worked', note: 'The turns Claude Code timed, added up; a turn still running is not in it yet' };
  if (u?.durationMs != null) return { ms: u.durationMs, kind: 'elapsed', note: 'From the first record to the last, pauses included: no turn was timed' };
  return null;
}

/** Why there is no estimate, when there is none. */
export function costNote(u) {
  if (!u?.unpriced?.length) return COST_NOTE;
  return `No estimate: the price table has no row for ${u.unpriced.join(', ')}`;
}

/** "40s", "4m 40s", "3h 5m": a span that is being counted, so the seconds show while they matter. */
export function fmtRunning(ms) {
  if (ms == null || !Number.isFinite(ms) || ms < 0) return null;
  const s = Math.floor(ms / 1000);
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m ${s % 60}s`;
  return fmtSpan(ms);
}

/**
 * The navigator's one line: time · new tokens · ~cost. Null when nothing was read.
 * @param live  the session is running: its time is counted from its first record to now
 */
export function usageLine(u, { live = false, now = null } = {}) {
  if (!u) return null;
  const t = timeOf(u);
  const span = live && u.startedAt != null && now != null ? fmtSpan(now - u.startedAt) : (t ? fmtSpan(t.ms) : null);
  const tokens = typeof u.tokens === 'number' ? u.tokens : u.tokens?.fresh;
  return [span, tokens ? fmtCount(tokens) : null, tokens ? fmtCost(u.cost) : null].filter(Boolean).join(' · ') || null;
}

const kinds = (k, cached = true) => [
  ['Input', fmtCount(k?.input ?? 0)], ['Output', fmtCount(k?.output ?? 0)], ['Cache write', fmtCount(k?.cacheWrite ?? 0)],
  ...(cached ? [['Cache read', fmtCount(k?.cacheRead ?? 0)]] : []),
];

/**
 * The summary box's rows: { label, value, note, detail }. `detail` is what a click on the row opens: the same
 * number broken down, as [name, value] pairs.
 *
 * "Tokens" is what was new: input, output and cache writes. What was read back from the cache is its own row —
 * it is the same context counted again on every response, and added in it made a session that had just opened
 * read as millions.
 *
 * @param opts.live  the session is running: its time is counted from its first record to `opts.now`
 */
export function summaryRows(u, { live = false, now = null } = {}) {
  if (!u) return [];
  const k = u.tokens ?? {};
  const rows = [];
  const t = timeOf(u);
  if (live && u.startedAt != null && now != null) {
    rows.push({ label: 'Running for', value: fmtRunning(now - u.startedAt), note: 'From the session\'s first record to now' });
  } else if (t) {
    rows.push({ label: t.kind === 'worked' ? 'Working time' : 'First to last record', value: fmtSpan(t.ms), note: t.note });
    if (t.kind === 'worked' && u.durationMs != null) rows.push({ label: 'First to last record', value: fmtSpan(u.durationMs), note: 'Pauses included; the agents\' transcripts too' });
  }
  rows.push({ label: 'Tokens', value: fmtCount(k.fresh ?? 0), note: 'New tokens: input, output and cache writes. Agents included, each response counted once', detail: kinds(k, false) });
  rows.push({ label: 'From cache', value: fmtCount(k.cacheRead ?? 0), note: 'Read back from the prompt cache: the same context, counted on every response that reused it' });
  const part = (label, p, note) => {
    if (!p?.tokens?.total) return;
    rows.push({ label, value: `${fmtCount(p.tokens.fresh)} · ${fmtCost(p.cost)}`, note: `${note}: new tokens and estimated cost\n${costNote(p)}`, detail: kinds(p.tokens) });
  };
  part('Session', u.parts?.session, 'The session\'s own transcript');
  part('Agents', u.parts?.agents, 'Everything its agents did');
  // Behind the cost: each model's new tokens and what they come to. A model with no price says so with a dash.
  const perModel = Object.entries(u.byModel ?? {}).map(([model, t]) => [modelName(model), `${fmtCount(t.tokens.fresh)} \u00b7 ${fmtCost(t.cost)}`]);
  rows.push({ label: 'Cost', value: k.total ? fmtCost(u.cost) : NO_COST, note: costNote(u), detail: perModel.length ? perModel : undefined });
  return rows;
}
