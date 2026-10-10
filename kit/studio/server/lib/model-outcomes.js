// What Crewforth recorded about which model did which work, and how it went.
//
// Crewforth writes one line per finished crew agent to `.claude/state/model-outcomes.tsv` (hooks/agent-outcome.sh):
//
//   ts  agent_id  agent  change  risk  card  model  verify  fixes  escalated_from  ran_on  confidence
//
// Twelve columns, tab-separated, a header on the first line, "-" for an empty value, and any column added later
// is added at the end. This file reads that and adds nothing to it: a class's first-try success is counted from
// the rows, never estimated, and a row that says nothing about the work says nothing here either.
//
//   class            agent x change x risk
//   verified         verify is pass or fail: the command ran and gave a verdict
//   first try        verify = pass and fixes = 0
//   not verified     verify is none (no command), blocked (the command was not allowed to run) or timeout: no
//                    verdict about the work, so these are shown apart and are in no rate
//   escalated        escalated_from is not "-": this call repeats a card that failed one model down
//
// Crewforth also writes `.claude/state/crew-model-floors.auto`: a class held one model up because its first try
// failed too often. Lowering such a hold is the user's to approve, with a Crewforth command in their own session:
// Studio shows which holds could be lowered (`suggestionsOf`) and writes nothing. A panel's button is a request
// any process of the same user can send, so it cannot stand for the user.

import fs from 'node:fs';
import path from 'node:path';

export const COLUMNS = ['ts', 'agent_id', 'agent', 'change', 'risk', 'card', 'model', 'verify', 'fixes', 'escalated_from', 'ran_on', 'confidence'];
const VERIFIED = new Set(['pass', 'fail']);
const TIERS = ['haiku', 'sonnet', 'opus', 'fable'];
const MAX_BYTES = 4 * 1024 * 1024;      // the record is read whole; past this only its end is, and the answer says so
// How many of a held class's latest verified calls have to have passed first time before lowering it is offered.
// A starting point; it has not been measured.
export const LOOSEN_AFTER = 10;
const TRAIL_MAX = 6;

const stateDir = (cwd) => path.join(cwd, '.claude', 'state');
const dash = (v) => (v === '-' || v === '' || v == null ? null : v);

/** The rows of a model-outcomes.tsv. A line with fewer than the twelve columns, or with no agent id, is dropped and counted. */
export function parseOutcomes(text) {
  const lines = String(text ?? '').split('\n').map((l) => l.replace(/\r$/, '')).filter((l) => l !== '');
  const out = { rows: [], dropped: 0, header: false };
  for (const [i, line] of lines.entries()) {
    const f = line.split('\t');
    if (i === 0 && f[0] === 'ts' && f[1] === 'agent_id') { out.header = true; continue; }
    if (f.length < COLUMNS.length || !/^[A-Za-z0-9._-]+$/.test(f[1])) { out.dropped += 1; continue; }
    const at = Date.parse(f[0]);
    out.rows.push({
      ts: f[0], at: Number.isFinite(at) ? at : null, agentId: f[1], agent: f[2], change: f[3], risk: f[4], card: dash(f[5]),
      model: dash(f[6]), verify: f[7], fixes: Number.parseInt(f[8], 10) || 0, escalatedFrom: dash(f[9]), ranOn: dash(f[10]),
      confidence: dash(f[11]),
    });
  }
  return out;
}

/** The lines of crew-model-floors.auto: agent, change, risk, model, calls, not-first-try, when. Comments start with #. */
export function parseFloors(text) {
  const out = [];
  for (const line of String(text ?? '').split('\n')) {
    const l = line.replace(/\r$/, '');
    if (!l || l.startsWith('#')) continue;
    const f = l.split('\t');
    if (f.length < 4 || !TIERS.includes(f[3])) continue;
    out.push({ agent: f[0], change: f[1], risk: f[2], model: f[3], calls: Number.parseInt(f[4], 10) || null, notFirstTry: Number.parseInt(f[5], 10) || 0, when: f[6] ?? null });
  }
  return out;
}

/** The user's approvals to lower a held class: ts, agent, change, risk, from, to. The newest for a class is the one that counts. */
export function parseLoosened(text) {
  const out = [];
  for (const [i, line] of String(text ?? '').split('\n').entries()) {
    const f = line.replace(/\r$/, '').split('\t');
    if (i === 0 && f[0] === 'ts') continue;
    if (f.length < 6 || !TIERS.includes(f[4]) || !TIERS.includes(f[5])) continue;
    out.push({ ts: f[0], at: Date.parse(f[0]) || null, agent: f[1], change: f[2], risk: f[3], from: f[4], to: f[5] });
  }
  return out;
}

const keyOf = (r) => `${r.agent}\t${r.change}\t${r.risk}`;
const firstTry = (r) => r.verify === 'pass' && r.fixes === 0;

/**
 * One line per class, the busiest first.
 * @param costOf  (agentId) => USD or null — what that agent's tokens come to at list price, where it was read
 */
export function classesOf(rows, floors = [], costOf = () => null) {
  const by = new Map();
  for (const r of rows) {
    const k = keyOf(r);
    if (!by.has(k)) {
      by.set(k, {
        key: k, agent: r.agent, change: r.change, risk: r.risk, runs: 0, verified: 0, firstTry: 0, fixed: 0, failed: 0, escalated: 0,
        notVerified: { none: 0, blocked: 0, timeout: 0, other: 0 }, models: {}, ranOn: {}, cost: 0, costed: 0, lastAt: null, floor: null,
      });
    }
    const c = by.get(k);
    c.runs += 1;
    const m = (c.models[r.model ?? 'unknown'] ??= { runs: 0, verified: 0, firstTry: 0 });
    m.runs += 1;
    if (r.ranOn) c.ranOn[r.ranOn] = (c.ranOn[r.ranOn] ?? 0) + 1;
    if (VERIFIED.has(r.verify)) {
      c.verified += 1; m.verified += 1;
      if (firstTry(r)) { c.firstTry += 1; m.firstTry += 1; }
      if (r.verify === 'fail') c.failed += 1;
      if (r.fixes > 0) c.fixed += 1;
    } else if (Object.hasOwn(c.notVerified, r.verify)) c.notVerified[r.verify] += 1;
    else c.notVerified.other += 1;
    if (r.escalatedFrom) c.escalated += 1;
    const usd = costOf(r.agentId);
    if (typeof usd === 'number') { c.cost += usd; c.costed += 1; }
    if (r.at !== null && (c.lastAt === null || r.at > c.lastAt)) c.lastAt = r.at;
  }
  for (const f of floors) { const c = by.get(keyOf(f)); if (c) c.floor = f; }
  return [...by.values()]
    // A rate with nothing under it is not zero: with no verified call there is none.
    .map((c) => ({ ...c, firstTryRate: c.verified ? c.firstTry / c.verified : null, cost: c.costed ? c.cost : null }))
    .sort((a, b) => b.runs - a.runs || a.key.localeCompare(b.key));
}

/**
 * The holds that could be lowered: a class the record of outcomes holds one model up (a line in
 * crew-model-floors.auto), whose latest LOOSEN_AFTER verified calls on that model all passed the first time.
 * Calls made before the user last approved a lowering of that class are not counted, and a hold already lowered
 * since it was written is not offered again.
 */
export function suggestionsOf(rows, floors = [], loosened = [], need = LOOSEN_AFTER) {
  const out = [];
  for (const f of floors) {
    const tier = TIERS.indexOf(f.model);
    if (tier <= 0) continue;
    const k = keyOf(f);
    const last = loosened.filter((l) => keyOf(l) === k).sort((a, b) => (b.at ?? 0) - (a.at ?? 0))[0] ?? null;
    const heldAt = Date.parse(f.when ?? '') || null;
    if (last && (heldAt === null || (last.at ?? 0) >= heldAt)) continue;
    const since = last?.at ?? 0;
    const recent = rows.filter((r) => keyOf(r) === k && r.model === f.model && VERIFIED.has(r.verify) && (r.at ?? 0) >= since)
      .sort((a, b) => (b.at ?? 0) - (a.at ?? 0)).slice(0, need);
    if (recent.length < need || !recent.every(firstTry)) continue;
    out.push({ key: k, agent: f.agent, change: f.change, risk: f.risk, from: f.model, to: TIERS[tier - 1], passed: recent.length, heldSince: f.when ?? null });
  }
  return out;
}

function readBounded(file) {
  let st;
  try { st = fs.statSync(file); } catch { return null; }
  if (st.size <= MAX_BYTES) return { text: fs.readFileSync(file, 'utf8'), truncated: false, bytes: st.size };
  const fd = fs.openSync(file, 'r');
  try {
    const buf = Buffer.alloc(MAX_BYTES);
    fs.readSync(fd, buf, 0, MAX_BYTES, st.size - MAX_BYTES);
    const text = buf.toString('utf8');
    return { text: text.slice(text.indexOf('\n') + 1), truncated: true, bytes: st.size };
  } finally { fs.closeSync(fd); }
}

/**
 * Everything the Models view shows for one project.
 * @returns measured: false with a reason when the project has no record — which is a project where no crew agent
 *          has finished since model routing was installed, not a project where every agent failed.
 */
export function readModels(cwd, { costOf = () => null } = {}) {
  const dir = stateDir(cwd);
  const record = readBounded(path.join(dir, 'model-outcomes.tsv'));
  if (!record) return { measured: false, reason: 'no .claude/state/model-outcomes.tsv in this project: no crew agent has finished here since model routing was installed', classes: [], suggestions: [], byAgent: {} };
  const parsed = parseOutcomes(record.text);
  const floors = parseFloors(readBounded(path.join(dir, 'crew-model-floors.auto'))?.text ?? '');
  const loosened = parseLoosened(readBounded(path.join(dir, 'crew-model-loosened.tsv'))?.text ?? '');
  const byAgent = {};
  for (const r of parsed.rows) byAgent[r.agentId] = r;           // a resumed agent's latest line is the one that stands
  // A card that failed is given again one model up, to another agent: the calls of one card, oldest first, are
  // the trail the inspector shows under the newest of them.
  const byCard = new Map();
  for (const r of parsed.rows) if (r.card) byCard.set(`${r.agent}\t${r.card}`, [...(byCard.get(`${r.agent}\t${r.card}`) ?? []), r]);
  for (const r of Object.values(byAgent)) {
    const same = r.card ? (byCard.get(`${r.agent}\t${r.card}`) ?? []) : [];
    r.before = same.filter((x) => x.agentId !== r.agentId && (x.at ?? 0) <= (r.at ?? 0)).slice(-TRAIL_MAX)
      .map(({ agentId, model, verify, fixes, ranOn }) => ({ agentId, model, verify, fixes, ranOn }));
  }
  return {
    measured: true,
    cwd,
    rows: parsed.rows.length,
    dropped: parsed.dropped,
    truncated: record.truncated,
    firstAt: parsed.rows.reduce((m, r) => (r.at !== null && (m === null || r.at < m) ? r.at : m), null),
    classes: classesOf(parsed.rows, floors, costOf),
    floors,
    suggestions: suggestionsOf(parsed.rows, floors, loosened),
    loosened,
    byAgent,
  };
}
