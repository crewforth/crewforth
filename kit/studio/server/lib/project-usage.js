// What a project spent over all of its sessions: the per-session summary (usage.js), added up.
//
// Reading a project's whole history is expensive. Measured on one long project (58 sessions, 2.0 GB of transcripts,
// 1,880 agent transcripts): 6.6 s, peaking near 1 GB of memory, with the sessions read one after another. So:
//   - each session's answer is kept until its files change: the key is the size and mtime of the session's own
//     transcript and of every agent transcript under its subagents directory;
//   - sessions are read one at a time, and projects one at a time, behind the requests: nothing here is ever read
//     in parallel, and no request waits for it;
//   - a request is answered with what is kept, and says how many of the project's sessions are not read yet.
// A session that is running changes; only its own answer is read again, at most once per ROUND_MIN_MS.
//
// The total covers every transcript of the project, not only the ones the navigator lists: `projectGroups` gives
// the whole list, where `listProjects` shortens it.

import fsp from 'node:fs/promises';
import path from 'node:path';

import { sessionUsage } from './usage.js';
import { SOURCE } from './pricing.js';

/** A project whose files did not change is still checked again this often: an agent can write with no other file moving. */
export const RECHECK_MS = 120_000;
/** A project whose files did change is read again no sooner than this: a running session changes every second. */
export const ROUND_MIN_MS = 30_000;

const KINDS = ['input', 'output', 'cacheWrite', 'cacheRead', 'fresh', 'total'];

/** Every agent transcript under a subagents directory, nesting included (workflows put them one level deeper). */
async function agentTranscripts(dir, depth = 0) {
  const out = [];
  if (depth > 3) return out;
  let entries;
  try { entries = await fsp.readdir(dir, { withFileTypes: true }); } catch { return out; }
  for (const e of entries) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) out.push(...await agentTranscripts(p, depth + 1));
    else if (e.name.endsWith('.jsonl')) out.push(p);
  }
  return out.sort();
}

const stamp = async (file) => { try { const st = await fsp.stat(file); return `${st.size}:${st.mtimeMs}`; } catch { return '-'; } };

/**
 * What a session's kept answer is valid for: the size and mtime of its own transcript, then of each agent's.
 * The first part alone is what the project list already knows (`bytes`, `modifiedAt`), so a request can tell a
 * session that moved since it was read without reading anything.
 */
export async function sessionSig(session) {
  const parts = [await stamp(session.file)];
  for (const f of await agentTranscripts(session.subagentsDir)) parts.push(`${path.basename(f)}=${await stamp(f)}`);
  return parts.join('|');
}

const mainOf = (s) => `${s.bytes}:${s.modifiedAt}`;

/** The part of a session's answer the total needs. The rest (each agent's own share) is not kept. */
export function trimSession(u) {
  return {
    tokens: u.tokens, responses: u.responses, cost: u.cost, costAtNormal: u.costAtNormal, unpriced: u.unpriced ?? [],
    byModel: u.byModel ?? {}, parts: u.parts, advisor: u.advisor ?? null, advisorModels: u.advisorModels ?? {},
    workedMs: u.workedMs ?? 0, turns: u.turns ?? 0, activeMs: u.activeMs ?? 0, startedAt: u.startedAt ?? null, lastAt: u.lastAt ?? null,
  };
}

/** A running sum of tallies in usage.js's result shape: { tokens, responses, cost, costAtNormal, unpriced }. */
function sumTallies(list, extra = null) {
  const tokens = Object.fromEntries(KINDS.map((k) => [k, 0]));
  const unpriced = new Set();
  let usd = 0;
  let atNormal = 0;
  let normalKnown = true;
  let responses = 0;
  let calls = 0;
  for (const t of list) {
    if (!t) continue;
    for (const k of KINDS) tokens[k] += t.tokens?.[k] ?? 0;
    responses += t.responses ?? 0;
    calls += t.calls ?? 0;
    for (const m of t.unpriced ?? []) unpriced.add(m);
    // A cost of null without a model named is still a cost nobody could give: it stays unknown in the sum.
    if (t.cost == null) { if (!t.unpriced?.length) unpriced.add('unknown model'); } else usd += t.cost;
    if (t.costAtNormal == null) normalKnown = false; else atNormal += t.costAtNormal;
  }
  return {
    tokens, responses,
    cost: unpriced.size ? null : usd,
    costAtNormal: unpriced.size || !normalKnown ? null : atNormal,
    unpriced: [...unpriced].sort(),
    ...(extra === 'calls' ? { calls } : {}),
  };
}

/** One tally per key, over every session that has the key. */
function sumByKey(maps, extra = null) {
  const keys = new Map();
  for (const m of maps) for (const [k, v] of Object.entries(m ?? {})) { if (!keys.has(k)) keys.set(k, []); keys.get(k).push(v); }
  return Object.fromEntries([...keys].map(([k, list]) => [k, sumTallies(list, extra)]));
}

/**
 * The project's total from its sessions' answers (trimSession's shape), in the shape web/usage.js `summaryRows`
 * draws. The time is ONE of two measures, never both added together: when any of the transcripts timed a turn
 * (`system` / `turn_duration`), `workedMs` is those turns added up and `activeMs` is null; when none did,
 * `workedMs` is 0 and `activeMs` is the estimate (usage.js `timesOf`). `durationMs` is null: first record to last
 * over months of work is not a time anybody spent.
 */
export function combineUsage(list) {
  const all = list.filter(Boolean);
  const total = sumTallies(all);
  const turns = all.reduce((n, u) => n + (u.turns ?? 0), 0);
  const timed = all.filter((u) => (u.turns ?? 0) > 0);
  const advisors = all.map((u) => u.advisor).filter(Boolean);
  const byModel = sumByKey(all.map((u) => u.byModel));
  const first = all.map((u) => u.startedAt).filter((v) => v != null);
  const last = all.map((u) => u.lastAt).filter((v) => v != null);
  return {
    ...total,
    sessions: all.length,
    models: Object.keys(byModel).filter((m) => !total.unpriced.includes(m)).sort(),
    byModel: Object.fromEntries(Object.entries(byModel).sort((a, b) => b[1].tokens.total - a[1].tokens.total)),
    parts: { session: sumTallies(all.map((u) => u.parts?.session)), agents: sumTallies(all.map((u) => u.parts?.agents)) },
    advisor: advisors.length ? sumTallies(advisors, 'calls') : null,
    advisorModels: sumByKey(all.map((u) => u.advisorModels), 'calls'),
    turns,
    timedSessions: timed.length,
    workedMs: turns ? timed.reduce((n, u) => n + (u.workedMs ?? 0), 0) : 0,
    activeMs: turns ? null : all.reduce((n, u) => n + (u.activeMs ?? 0), 0),
    durationMs: null,
    startedAt: first.length ? Math.min(...first) : null,
    lastAt: last.length ? Math.max(...last) : null,
    priceSource: SOURCE,
  };
}

/**
 * The kept answers and the work behind them. One per server; the self-check builds its own with a counting reader.
 * @param read  a session's usage (usage.js `sessionUsage`)
 * @param sig   a session's signature (sessionSig)
 */
export class ProjectUsage {
  constructor({ read = sessionUsage, sig = sessionSig, now = Date.now, recheckMs = RECHECK_MS, roundMinMs = ROUND_MIN_MS } = {}) {
    Object.assign(this, { read, sig, now, recheckMs, roundMinMs });
    this.entries = new Map();   // session file -> { sig, main, value }   value null: a transcript that could not be read
    this.groups = new Map();    // project key -> its sessions, all of them
    this.checked = new Map();   // project key -> { at, print } of its last round
    this.queue = [];
    this.running = null;        // the key being read now
    this.reads = 0;             // sessions read, for the self-check
  }

  /**
   * The projects as `projectGroups` read them. Queues each one whose files changed, or that was not checked for a
   * while, and starts the work behind the caller; the order given is the order read.
   */
  note(groups) {
    const files = new Set();
    for (const g of groups.values()) {
      this.groups.set(g.key, g.sessions);
      for (const s of g.sessions) files.add(s.file);
    }
    for (const key of [...this.groups.keys()]) if (!groups.has(key)) this.groups.delete(key);
    for (const f of [...this.entries.keys()]) if (!files.has(f)) this.entries.delete(f);   // a transcript that is gone
    for (const key of groups.keys()) if (this.#due(key)) this.#enqueue(key);
    this.drain();
  }

  #print(key) { return (this.groups.get(key) ?? []).map((s) => `${s.file}:${mainOf(s)}:${s.agentCount ?? 0}`).join('\n'); }

  #due(key) {
    const c = this.checked.get(key);
    if (!c) return true;
    const age = this.now() - c.at;
    return age >= this.recheckMs || (c.print !== this.#print(key) && age >= this.roundMinMs);
  }

  #enqueue(key, first = false) {
    if (this.running === key) return;
    const at = this.queue.indexOf(key);
    if (at >= 0) { if (!first) return; this.queue.splice(at, 1); }
    if (first) this.queue.unshift(key); else this.queue.push(key);
  }

  /** Ask for one project's total: it moves to the front of the queue when it is due. */
  want(key) {
    if (this.groups.has(key) && this.#due(key)) this.#enqueue(key, true);
    this.drain();
  }

  /** Run the queue, one project at a time. Resolves when it is empty; a second call joins the first. */
  drain() {
    this.draining ??= (async () => {
      try {
        while (this.queue.length) {
          const key = this.queue.shift();
          this.running = key;
          try { await this.refresh(key); } catch { /* the next round tries again */ } finally { this.running = null; }
        }
      } finally { this.draining = null; }
    })();
    return this.draining;
  }

  /** One round over a project: each session whose signature moved is read again, one at a time. */
  async refresh(key) {
    const print = this.#print(key);
    for (const s of this.groups.get(key) ?? []) {
      const sig = await this.sig(s);
      const hit = this.entries.get(s.file);
      if (hit && hit.sig === sig) continue;
      let value = null;
      try { value = trimSession(await this.read(s)); } catch { value = null; }
      this.reads += 1;
      this.entries.set(s.file, { sig, main: sig.split('|')[0], value });
    }
    this.checked.set(key, { at: this.now(), print });
  }

  /**
   * What is kept for a project. `pending` is how many of its sessions have no answer yet, or one read before their
   * transcript last moved; `computing` says the work is under way. Null when nothing of it is read yet.
   */
  summary(key) {
    const sessions = this.groups.get(key);
    if (!sessions) return null;
    const values = [];
    let pending = 0;
    for (const s of sessions) {
      const e = this.entries.get(s.file);
      if (!e || e.main !== mainOf(s)) pending += 1;
      if (e?.value) values.push(e.value);
    }
    const computing = this.running === key || this.queue.includes(key);
    if (!values.length) return { measured: false, pending, computing, sessions: sessions.length };
    return { measured: true, ...combineUsage(values), sessions: sessions.length, read: values.length, pending, computing };
  }

  /** The navigator's few figures, or null while no session of the project has been read. */
  short(key) {
    const s = this.summary(key);
    if (!s?.measured) return null;
    return { workedMs: s.workedMs, activeMs: s.activeMs, tokens: s.tokens.fresh, cost: s.cost, unpriced: s.unpriced, pending: s.pending, sessions: s.sessions };
  }
}
