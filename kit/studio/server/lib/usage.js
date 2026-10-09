// What a session spent: tokens read from its transcripts, and what they would cost at API list price.
//
// Claude Code writes one record per content block, and every record of one API response repeats that response's
// usage. Measured on one machine before this was written: 23,867 assistant records carried usage, for 11,245
// responses, and every repeat carried the same numbers. So a response is counted once, by its message id — and
// once across the session's files too, which is what keeps an agent's tokens from being added twice.

import fsp from 'node:fs/promises';
import path from 'node:path';

import { readAll } from './transcript.js';
import { agentMetaFiles } from './projects.js';
import { costOf, SOURCE } from './pricing.js';

const num = (v) => (typeof v === 'number' && Number.isFinite(v) && v > 0 ? v : 0);

/** One response's usage, in the shape pricing.js prices. Null when the record carries none. */
export function usageOfRecord(r) {
  const m = r?.type === 'assistant' ? r.message : null;
  const u = m?.usage;
  if (!u || typeof u !== 'object') return null;
  const split = u.cache_creation && typeof u.cache_creation === 'object' ? u.cache_creation : null;
  const w1h = num(split?.ephemeral_1h_input_tokens);
  // With no split recorded, a cache write is the 5-minute kind: that is the default, and the cheaper of the two.
  const w5m = split ? num(split.ephemeral_5m_input_tokens) : num(u.cache_creation_input_tokens);
  return {
    id: typeof m.id === 'string' ? m.id : null,
    model: typeof m.model === 'string' ? m.model : null,
    input: num(u.input_tokens),
    output: num(u.output_tokens),
    cacheWrite5m: w5m,
    cacheWrite1h: w1h,
    cacheRead: num(u.cache_read_input_tokens),
    fast: u.speed === 'fast',
    usOnly: u.inference_geo === 'us',
  };
}

const KINDS = ['input', 'output', 'cacheWrite', 'cacheRead'];

/** One running sum: tokens by kind, what they cost, and which models had no price. */
class Tally {
  constructor() {
    this.tokens = { input: 0, output: 0, cacheWrite: 0, cacheRead: 0 };
    this.usd = 0;
    this.responses = 0;
    this.unpriced = new Set();
  }

  take(u, usd) {
    this.responses += 1;
    this.tokens.input += u.input;
    this.tokens.output += u.output;
    this.tokens.cacheWrite += u.cacheWrite5m + u.cacheWrite1h;
    this.tokens.cacheRead += u.cacheRead;
    if (usd === null) this.unpriced.add(u.model ?? 'unknown model');
    else this.usd += usd;
  }

  /**
   * `fresh` is what was sent and written for the first time: input, output and cache writes. `cacheRead` is the
   * same context read back from the cache on every later response, which is why it dwarfs the rest in a long
   * session and is kept out of the headline. `cost` is null when any of the tokens came from a model the price
   * table has no row for — a sum that leaves some of them out would read as the whole.
   */
  result() {
    const t = this.tokens;
    return {
      tokens: { ...t, fresh: t.input + t.output + t.cacheWrite, total: KINDS.reduce((a, k) => a + t[k], 0) },
      responses: this.responses,
      cost: this.unpriced.size ? null : this.usd,
      unpriced: [...this.unpriced].sort(),
    };
  }
}

export class Usage {
  constructor() {
    this.seen = new Set();
    this.all = new Tally();
    this.who = new Map();      // 'session', or an agent's id -> Tally
    this.model = new Map();    // model id -> Tally
    this.first = null;         // the earliest and the latest record of any file added
    this.last = null;
  }

  #tally(map, key) {
    if (!map.has(key)) map.set(key, new Tally());
    return map.get(key);
  }

  /**
   * Add a transcript's records. A response already counted, from this file or another, is not counted again.
   * @param who  'session' for the session's own transcript, or the id of the agent whose transcript this is.
   *             A record the session's transcript marks as an agent's (`isSidechain`) is counted as an agent's.
   */
  add(records, who = 'session') {
    for (const r of records ?? []) {
      const t = r?.timestamp ? Date.parse(r.timestamp) : NaN;
      if (Number.isFinite(t)) {
        if (this.first === null || t < this.first) this.first = t;
        if (this.last === null || t > this.last) this.last = t;
      }
      const u = usageOfRecord(r);
      if (!u) continue;
      if (u.id) { if (this.seen.has(u.id)) continue; this.seen.add(u.id); }
      if (!(u.input + u.output + u.cacheWrite5m + u.cacheWrite1h + u.cacheRead)) continue;   // a record the harness made up carries no tokens
      const usd = costOf(u);
      this.all.take(u, usd);
      this.#tally(this.who, who === 'session' && r.isSidechain === true ? 'agents:inline' : who).take(u, usd);
      this.#tally(this.model, u.model ?? 'unknown model').take(u, usd);
    }
    return this;
  }

  /** One agent's own share, or null when its transcript carried no usage. */
  of(who) { return this.who.get(who)?.result() ?? null; }

  /**
   * @returns the whole session's tally, and the same split two ways: `parts.session` is what the session's own
   *          transcript spent and `parts.agents` everything its agents did; `byModel` is one tally per model.
   */
  result() {
    const agents = new Tally();
    for (const [who, t] of this.who) {
      if (who === 'session') continue;
      for (const k of KINDS) agents.tokens[k] += t.tokens[k];
      agents.usd += t.usd;
      agents.responses += t.responses;
      for (const m of t.unpriced) agents.unpriced.add(m);
    }
    const all = this.all.result();
    return {
      ...all,
      models: [...this.model.keys()].filter((m) => !all.unpriced.includes(m)).sort(),
      parts: { session: (this.who.get('session') ?? new Tally()).result(), agents: agents.result() },
      byModel: Object.fromEntries([...this.model].map(([m, t]) => [m, t.result()]).sort((a, b) => b[1].tokens.total - a[1].tokens.total)),
      startedAt: this.first,
      lastAt: this.last,
      priceSource: SOURCE,
    };
  }
}

/**
 * How long a session's own transcript says it took. `durationMs` is from its first record to its last, pauses
 * included; with its agents' transcripts counted too, that span is `Usage`'s `startedAt` to `lastAt`.
 * `workedMs` is the turns Claude Code timed itself (`system` / `turn_duration` records), added up; zero when it
 * recorded none, and a turn that is still running is not in it.
 */
export function timesOf(records) {
  let first = null;
  let last = null;
  let workedMs = 0;
  let turns = 0;
  for (const r of records ?? []) {
    const t = r?.timestamp ? Date.parse(r.timestamp) : NaN;
    if (Number.isFinite(t)) {
      if (first === null || t < first) first = t;
      if (last === null || t > last) last = t;
    }
    if (r?.type === 'system' && r.subtype === 'turn_duration' && typeof r.durationMs === 'number' && r.durationMs > 0) {
      workedMs += r.durationMs;
      turns += 1;
    }
  }
  return { durationMs: first !== null && last !== null ? last - first : null, workedMs, turns };
}

/**
 * The usage with the times beside it. The span runs to the last record of ANY of the session's files: an agent
 * can be writing long after the session's own transcript last moved.
 */
export function withTimes(usage, mainRecords) {
  const u = usage.result();
  const t = timesOf(mainRecords);
  return { ...u, workedMs: t.workedMs, turns: t.turns, durationMs: u.startedAt !== null && u.lastAt !== null ? u.lastAt - u.startedAt : null };
}

/** A session's usage with its agents', and how long it took. */
export async function sessionUsage(session) {
  const usage = new Usage();
  const { records } = await readAll(session.file);
  usage.add(records);
  for (const meta of await agentMetaFiles(session.subagentsDir)) {
    const jsonl = meta.replace(/\.meta\.json$/, '.jsonl');
    const agentId = path.basename(jsonl).slice('agent-'.length, -'.jsonl'.length);
    try { usage.add((await readAll(jsonl)).records, agentId); } catch { /* an agent that has not written yet */ }
  }
  return withTimes(usage, records);
}

// One answer per session, kept until one of its files changes. The key is what the stream's own signature
// watches: the transcript's size, and every agent file's.
const cache = new Map();   // sessionId -> { sig, value }

async function sigOf(session) {
  const parts = [];
  try { parts.push(String((await fsp.stat(session.file)).size)); } catch { parts.push('0'); }
  for (const meta of await agentMetaFiles(session.subagentsDir)) {
    const jsonl = meta.replace(/\.meta\.json$/, '.jsonl');
    try { parts.push(`${path.basename(jsonl)}:${(await fsp.stat(jsonl)).size}`); } catch { /* not written yet */ }
  }
  return parts.join('|');
}

export async function cachedUsage(session) {
  const sig = await sigOf(session);
  const hit = cache.get(session.sessionId);
  if (hit && hit.sig === sig) return hit.value;
  const value = await sessionUsage(session);
  if (cache.size > 500) cache.clear();
  cache.set(session.sessionId, { sig, value });
  return value;
}
