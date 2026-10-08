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

export class Usage {
  constructor() {
    this.seen = new Set();
    this.tokens = { input: 0, output: 0, cacheWrite: 0, cacheRead: 0 };
    this.usd = 0;
    this.responses = 0;
    this.priced = new Set();
    this.unpriced = new Set();
  }

  /** Add a transcript's records. A response already counted, from this file or another, is not counted again. */
  add(records) {
    for (const r of records ?? []) {
      const u = usageOfRecord(r);
      if (!u) continue;
      if (u.id) { if (this.seen.has(u.id)) continue; this.seen.add(u.id); }
      const total = u.input + u.output + u.cacheWrite5m + u.cacheWrite1h + u.cacheRead;
      if (!total) continue;                    // a record the harness made up for itself carries no tokens
      this.responses += 1;
      this.tokens.input += u.input;
      this.tokens.output += u.output;
      this.tokens.cacheWrite += u.cacheWrite5m + u.cacheWrite1h;
      this.tokens.cacheRead += u.cacheRead;
      const usd = costOf(u);
      if (usd === null) this.unpriced.add(u.model ?? 'unknown model');
      else { this.usd += usd; this.priced.add(u.model); }
    }
    return this;
  }

  /**
   * @returns tokens by kind and in total; `cost` in USD at list price, or null when any of the tokens came from
   *          a model the table has no row for — a sum that leaves some of them out would read as the whole.
   */
  result() {
    const t = this.tokens;
    return {
      tokens: { ...t, total: t.input + t.output + t.cacheWrite + t.cacheRead },
      responses: this.responses,
      cost: this.unpriced.size ? null : this.usd,
      models: [...this.priced].sort(),
      unpriced: [...this.unpriced].sort(),
      priceSource: SOURCE,
    };
  }
}

/**
 * How long a session took, two ways. `durationMs` is from its first record to its last, pauses included.
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

/** A session's usage with its agents', and how long it took. */
export async function sessionUsage(session) {
  const usage = new Usage();
  const { records } = await readAll(session.file);
  usage.add(records);
  for (const meta of await agentMetaFiles(session.subagentsDir)) {
    const jsonl = meta.replace(/\.meta\.json$/, '.jsonl');
    try { usage.add((await readAll(jsonl)).records); } catch { /* an agent that has not written yet */ }
  }
  return { ...usage.result(), ...timesOf(records) };
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
