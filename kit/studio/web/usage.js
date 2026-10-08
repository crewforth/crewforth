// What a session spent, as words: how long, how many tokens, and an estimate of the cost.
//
// The numbers are the server's (server/lib/usage.js); the prices are in one file there (server/lib/pricing.js).
// Nothing here knows a price. The cost is an estimate at API list price and is always written as one: a leading
// "~", and a note that says what it is. A session with tokens from a model the price table does not have gets
// a dash, not a smaller number.

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

/** The navigator's one line: time · tokens · ~cost. Null when nothing was read. */
export function usageLine(u) {
  if (!u) return null;
  const t = timeOf(u);
  const tokens = typeof u.tokens === 'number' ? u.tokens : u.tokens?.total;
  return [t ? fmtSpan(t.ms) : null, tokens ? fmtCount(tokens) : null, tokens ? fmtCost(u.cost) : null].filter(Boolean).join(' · ') || null;
}

/** The summary box's rows: [label, value, note]. */
export function summaryRows(u) {
  if (!u) return [];
  const t = timeOf(u);
  const k = u.tokens ?? {};
  const rows = [];
  if (t) rows.push([t.kind === 'worked' ? 'Working time' : 'First to last record', fmtSpan(t.ms), t.note]);
  if (t?.kind === 'worked' && u.durationMs != null) rows.push(['First to last record', fmtSpan(u.durationMs), 'Pauses included']);
  rows.push(['Tokens', fmtCount(k.total ?? 0),
    `Agents included, each response counted once\ninput ${fmtCount(k.input ?? 0)} · output ${fmtCount(k.output ?? 0)} · cache write ${fmtCount(k.cacheWrite ?? 0)} · cache read ${fmtCount(k.cacheRead ?? 0)}`]);
  rows.push(['Cost', k.total ? fmtCost(u.cost) : NO_COST, costNote(u)]);
  return rows;
}
