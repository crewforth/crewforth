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
// What the hooks write, and nothing else is a row. The words are hooks/guard-agent-model.sh's and
// hooks/agent-outcome.sh's; a word they do not use is a line this file cannot read, not a new kind of work.
export const VERIFY = ['pass', 'fail', 'none', 'blocked', 'timeout'];
export const CHANGES = ['text', 'feature', 'fix-known', 'fix-unknown', 'refactor', 'migration', 'security', 'architecture', 'test-run', 'test-write', 'audit'];
export const RISKS = ['critical', 'normal'];
const TIERS = ['haiku', 'sonnet', 'opus', 'fable'];
const MAX_BYTES = 4 * 1024 * 1024;      // the record is read whole; past this only its end is, and the answer says so
// How many of a held class's latest verified calls have to have passed first time before lowering it is offered.
// A starting point; it has not been measured.
export const LOOSEN_AFTER = 10;
const TRAIL_MAX = 6;

const stateDir = (cwd) => path.join(cwd, '.claude', 'state');
const dash = (v) => (v === '-' || v === '' || v == null ? null : v);

/** Is this line one the hooks could have written? Every field that is counted or compared has to be what they write. */
function rowProblem(f) {
  if (f.length < COLUMNS.length) return 'fewer than twelve columns';
  if (!/^[A-Za-z0-9._-]+$/.test(f[1])) return 'no agent id';
  if (!Number.isFinite(Date.parse(f[0])) || !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/.test(f[0])) return 'ts is not a UTC time';
  if (!f[2]) return 'no agent';
  if (!CHANGES.includes(f[3])) return 'change is not one of the eleven';
  if (!RISKS.includes(f[4])) return 'risk is not critical or normal';
  if (f[6] !== '-' && !TIERS.includes(f[6])) return 'model is not a tier';
  if (!VERIFY.includes(f[7])) return 'verify is not one of the five';
  if (!/^\d{1,4}$/.test(f[8])) return 'fixes is not a count';
  if (f[9] !== '-' && !TIERS.includes(f[9])) return 'escalated_from is not a tier';
  return null;
}

/**
 * The rows of a model-outcomes.tsv. A line the hooks could not have written is dropped and counted, with the
 * first reason of each kind kept so the view can say why the count is not zero.
 */
export function parseOutcomes(text) {
  const lines = String(text ?? '').split('\n').map((l) => l.replace(/\r$/, '')).filter((l) => l !== '');
  const out = { rows: [], dropped: 0, why: {}, header: false };
  for (const [i, line] of lines.entries()) {
    const f = line.split('\t');
    if (i === 0 && f[0] === 'ts' && f[1] === 'agent_id') { out.header = true; continue; }
    const problem = rowProblem(f);
    if (problem) { out.dropped += 1; out.why[problem] = (out.why[problem] ?? 0) + 1; continue; }
    const at = Date.parse(f[0]);
    out.rows.push({
      line: i, ts: f[0], at, agentId: f[1], agent: f[2], change: f[3], risk: f[4], card: dash(f[5]),
      model: dash(f[6]), verify: f[7], fixes: Number.parseInt(f[8], 10), escalatedFrom: dash(f[9]), ranOn: dash(f[10]),
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
 * The lowering that stands for a raised floor, or null. The rule is hooks/guard-agent-model.sh's (`_am_floor_now`),
 * word for word: a lowering counts when it is not older than the raise it answers (the times are UTC text and are
 * compared as text, as the hook does), is from the model the floor was raised to, and goes one model down. Raised
 * again afterwards, the floor is the raised one. The last line that counts is the one in force.
 */
export function loweringOf(floor, loosened = []) {
  let hit = null;
  for (const l of loosened) {
    if (keyOf(l) !== keyOf(floor)) continue;
    if (String(l.ts) < String(floor.when ?? '')) continue;
    if (l.from !== floor.model) continue;
    if (TIERS.indexOf(l.to) < 0 || TIERS.indexOf(l.to) !== TIERS.indexOf(l.from) - 1) continue;
    hit = { to: l.to, ts: l.ts };
  }
  return hit;
}

/** One line per class, the busiest first. What the class cost is asked apart (`classCosts`): it is read from elsewhere. */
export function classesOf(rows, floors = [], loosened = []) {
  const by = new Map();
  for (const r of rows) {
    const k = keyOf(r);
    if (!by.has(k)) {
      by.set(k, {
        key: k, agent: r.agent, change: r.change, risk: r.risk, runs: 0, verified: 0, firstTry: 0, fixed: 0, failed: 0, escalated: 0,
        notVerified: { none: 0, blocked: 0, timeout: 0 }, models: {}, ranOn: {}, lastAt: null, floor: null,
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
    } else c.notVerified[r.verify] += 1;
    if (r.escalatedFrom) c.escalated += 1;
    if (r.at !== null && (c.lastAt === null || r.at > c.lastAt)) c.lastAt = r.at;
  }
  // A floor the user lowered is still on record as raised; what holds now is the lowered one, and both are said.
  for (const f of floors) { const c = by.get(keyOf(f)); if (c) c.floor = { ...f, lowered: loweringOf(f, loosened) }; }
  return [...by.values()]
    // A rate with nothing under it is not zero: with no verified call there is none.
    .map((c) => ({ ...c, firstTryRate: c.verified ? c.firstTry / c.verified : null }))
    .sort((a, b) => b.runs - a.runs || a.key.localeCompare(b.key));
}

/**
 * What each class's agents come to, where an agent's tokens could be read: { classKey: { cost, costed, runs } }.
 * `costed` of `runs` were priced; the rest are not in the sum, so the sum is a floor and not the total.
 * @param costOf  (agentId) => USD or null
 */
export function classCosts(rows, costOf) {
  const out = {};
  for (const r of rows) {
    const c = (out[keyOf(r)] ??= { cost: 0, costed: 0, runs: 0 });
    c.runs += 1;
    const usd = costOf(r.agentId);
    if (typeof usd === 'number') { c.cost += usd; c.costed += 1; }
  }
  return out;
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
    // Once for each raise: a floor whose lowering stands is not offered again (the same rule the gate reads it by).
    if (loweringOf(f, loosened)) continue;
    const since = Date.parse(f.when ?? '') || 0;
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

const sigOf = (file) => { try { const st = fs.statSync(file); return `${st.mtimeMs}:${st.size}`; } catch { return '-'; } };
const FILES = ['model-outcomes.tsv', 'crew-model-floors.auto', 'crew-model-loosened.tsv'];
const records = new Map();           // cwd -> { sig, value }
export const _stats = { parsed: 0 };  // how many times a record was really read: the claims count it

/**
 * The record of one project, read once and kept until one of its three files changes (its time or its size).
 * A view that asks every few seconds costs three stats, not a parse.
 */
export function readRecord(cwd) {
  const dir = stateDir(cwd);
  const sig = FILES.map((f) => sigOf(path.join(dir, f))).join('|');
  const hit = records.get(cwd);
  if (hit && hit.sig === sig) return hit.value;
  const value = parseRecord(dir, cwd);
  _stats.parsed += 1;
  if (records.size > 50) records.clear();
  records.set(cwd, { sig, value });
  return value;
}

function parseRecord(dir, cwd) {
  const record = readBounded(path.join(dir, FILES[0]));
  if (!record) return { measured: false, reason: 'no .claude/state/model-outcomes.tsv in this project: no crew agent has finished here since model routing was installed', classes: [], suggestions: [], byAgent: {} };
  const parsed = parseOutcomes(record.text);
  const floors = parseFloors(readBounded(path.join(dir, FILES[1]))?.text ?? '');
  const loosened = parseLoosened(readBounded(path.join(dir, FILES[2]))?.text ?? '');
  const byAgent = {};
  for (const r of parsed.rows) byAgent[r.agentId] = r;           // a resumed agent's latest line is the one that stands
  // A card that failed is given again one model up, to another agent: the calls of one card, oldest first, are
  // the trail the inspector shows under the newest of them.
  const byCard = new Map();
  for (const r of parsed.rows) if (r.card) byCard.set(`${r.agent}\t${r.card}`, [...(byCard.get(`${r.agent}\t${r.card}`) ?? []), r]);
  for (const r of Object.values(byAgent)) {
    const same = r.card ? (byCard.get(`${r.agent}\t${r.card}`) ?? []) : [];
    // Earlier in the file, not earlier by the clock: two lines can carry the same second.
    r.before = same.filter((x) => x.agentId !== r.agentId && x.line < r.line).slice(-TRAIL_MAX)
      .map(({ agentId, model, verify, fixes, ranOn }) => ({ agentId, model, verify, fixes, ranOn }));
  }
  return {
    measured: true,
    cwd,
    rows: parsed.rows.length,
    dropped: parsed.dropped,
    droppedWhy: parsed.why,
    truncated: record.truncated,
    firstAt: parsed.rows.reduce((m, r) => (m === null || r.at < m ? r.at : m), null),
    classes: classesOf(parsed.rows, floors, loosened),
    floors,
    suggestions: suggestionsOf(parsed.rows, floors, loosened),
    loosened,
    byAgent,
    all: parsed.rows,
  };
}

/**
 * What the Models view and the inspector are sent for one project.
 * @param agents  the ids of the agents of the session on screen: only their lines are sent. Without it, none are:
 *                a project's record can hold every agent it ever ran, and a page shows one session's.
 * @returns measured: false with a reason when the project has no record — which is a project where no crew agent
 *          has finished since model routing was installed, not a project where every agent failed.
 */
export function readModels(cwd, { agents = null } = {}) {
  const rec = readRecord(cwd);
  if (!rec.measured) return rec;
  const byAgent = {};
  for (const id of agents ?? []) if (Object.hasOwn(rec.byAgent, id)) byAgent[id] = rec.byAgent[id];
  const { all, byAgent: _every, ...rest } = rec;
  return { ...rest, byAgent };
}

/** What the classes of one project cost, from the kept record: see `classCosts`. Null when there is no record. */
export function readCosts(cwd, costOf) {
  const rec = readRecord(cwd);
  return rec.measured ? classCosts(rec.all, costOf) : null;
}
