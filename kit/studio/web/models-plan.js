// What the Models view and the inspector say about which model did which work. No page in it.
//
// The numbers are Crewforth's own record (server/lib/model-outcomes.js reads it); this file turns them into words.
// A rate with nothing under it is not written as zero, and a call whose verify command gave no verdict is shown
// apart from the ones that passed or failed.
import { roleName, modelName } from './names.js';
import { fmtCost, fmtCount } from './usage.js';
import { t } from './i18n.js';

const TIER = { haiku: 'Haiku', sonnet: 'Sonnet', opus: 'Opus', fable: 'Fable' };
export const tierWord = (k) => TIER[k] ?? (k ? String(k) : t('no model'));
const pct = (r) => `${Math.round(r * 100)}%`;

/**
 * The task card a crew agent's work starts with: three lines at the top of its task text.
 *   files: what it may touch · change: the kind of change · verify: the command that checks it, or none
 * Returns null when the text does not begin with a card; a card with a line missing keeps the others.
 */
export function cardOf(prompt) {
  if (typeof prompt !== 'string') return null;
  const card = {};
  for (const line of prompt.split('\n').slice(0, 12)) {
    const m = line.match(/^\s*(files|change|verify)\s*:\s*(.*)$/i);
    if (m && card[m[1].toLowerCase()] === undefined) card[m[1].toLowerCase()] = m[2].trim();
  }
  return Object.keys(card).length ? { files: card.files ?? null, change: card.change ?? null, verify: card.verify ?? null } : null;
}

const VERIFY_TONE = { pass: 'pass', fail: 'fail' };
const VERIFY_SAYS = { none: t('no verify command'), blocked: t('verify not run: the command was not allowed'), timeout: t('verify not finished: the command ran out of time') };

/** The card as the inspector lists it: the three lines, each kept as it was written. */
export function cardLines(card, row) {
  const out = [];
  if (card?.files) out.push({ label: 'files', text: card.files });
  if (card?.change || row?.change) out.push({ label: 'change', text: row?.change ?? card.change });
  if (card?.verify) out.push({ label: 'verify', text: card.verify });
  return out;
}

function stepOf(r, again) {
  const on = r.ranOn ? modelName(r.ranOn) : tierWord(r.model);
  const bits = [again ? t('Re-run on {model}', { model: on }) : t('Ran on {model}', { model: on })];
  if (r.fixes > 0) bits.push(r.fixes === 1 ? t('fixed once inside the agent') : t('fixed {n} times inside the agent', { n: r.fixes }));
  // A verdict is a tag (pass, fail); anything else is said in words, because it is no verdict.
  const tone = VERIFY_TONE[r.verify] ?? null;
  if (!tone) bits.push(VERIFY_SAYS[r.verify] ?? t('verify {verdict}', { verdict: r.verify }));
  return { text: bits.join(' \u00b7 '), verify: tone ? r.verify : null, tone, escalated: again };
}

/**
 * How the work went, as steps: the earlier calls of the same card, then this one. `row` is Crewforth's line for
 * the agent with `before` (see server/lib/model-outcomes.js), or null when it has none: it has not stopped, or it
 * is not a crew agent.
 * @returns { risk, riskWhy, steps: [{ text, verify, tone, escalated }], note }
 */
export function workSteps(row) {
  if (!row) return { risk: null, riskWhy: null, steps: [], note: t('Not recorded yet: the line is written when the agent stops.') };
  const steps = [...(row.before ?? []).map((r) => stepOf(r, false)), stepOf(row, Boolean(row.escalatedFrom))];
  if (row.escalatedFrom && !(row.before ?? []).length) {
    steps.unshift({ text: t('An earlier call on {model} did not pass; its line is not in the record', { model: tierWord(row.escalatedFrom) }), verify: null, tone: null, escalated: false });
  }
  // The reason is the gate's own sentence, kept as it wrote it; a line written before the gate kept one has none.
  return { risk: row.risk ?? null, riskWhy: row.risk === 'critical' ? row.riskWhy ?? null : null, steps, note: row.escalatedFrom ? t('A re-run with the same or a lower model is refused by the gate.') : null };
}

/**
 * What is said about an agent that is not crew-*: it has no floor and no line in the record, but the model gate still
 * holds its expensive end, except for a card naming critical work (_am_outside in hooks/guard-agent-model.sh). Null for a crew agent or an unknown type.
 */
export function outsideRouting(agentType) {
  if (typeof agentType !== 'string' || !agentType || agentType.startsWith('crew-')) return null;
  return t('Outside model routing: not a crew agent, so it has no floor and Crewforth keeps no outcome line for it. The gate only holds the expensive end: a call that asks for opus or fable, or names no model and would take the session\u2019s, is held at sonnet unless its task carries an above: <why> line or opens with a card naming critical work. An agent whose own definition names a model keeps it.');
}

/**
 * What is said about a class's floor. Raised and standing: the tag `raised` and what raised it. Raised and then
 * lowered by the user: the tag `lowered`, and both facts, because the raise is still on record and the floor that
 * holds is the lowered one. `floorTag` is the tag's word, or null when the class has no floor on record.
 */
export function floorWords(floor) {
  if (!floor) return { floorTag: null, raised: null, raisedWhy: '' };
  const why = t('Raised to {model} automatically: {n} of {calls} calls one model down did not pass first time', { model: tierWord(floor.model), n: floor.notFirstTry, calls: floor.calls ?? '?' });
  if (!floor.lowered) return { floorTag: 'raised', raised: tierWord(floor.model), raisedWhy: why };
  return {
    floorTag: 'lowered',
    raised: null,
    raisedWhy: `${why}. ${t('You lowered it to {model} on {date}; its outcomes are counted afresh from then.', { model: tierWord(floor.lowered.to), date: String(floor.lowered.ts).slice(0, 10) })}`,
  };
}

/**
 * The cost cell of a class. `cost` is { cost, costed, runs } for it, or null while costs have not been read.
 * Every call priced: the estimate. Some priced: a floor, marked as one, with how many it is the sum of
 * ("\u2265$0.75 \u00b7 2/7"), because a sum of two calls must not be read as the cost of seven. None: a dash.
 */
export function costCell(cost, runs) {
  if (!cost) return { cost: '\u2026', costNote: t('Reading what this class cost\u2026'), partial: false, advisor: null };
  if (!cost.costed) return { cost: '\u2014', costNote: t('No agent of this class has a transcript on this machine that could be priced'), partial: false, advisor: null };
  const usd = fmtCost(cost.cost);
  const advisor = advisorWords(cost);
  const tail = advisor ? `\n${advisor}` : '';
  if (cost.costed >= runs) return { cost: usd, costNote: `${runs === 1 ? t('The 1 task priced, at API list price. An estimate: what a subscription is charged is not known here.') : t('All {n} tasks priced, at API list price. An estimate: what a subscription is charged is not known here.', { n: runs })}${tail}`, partial: false, advisor };
  return {
    cost: `\u2265${usd.replace(/^~/, '')} \u00b7 ${cost.costed}/${runs}`,
    costNote: `${t('At least this much: {n} of {runs} tasks could be priced; the others have no transcript on this machine. At API list price.', { n: cost.costed, runs })}${tail}`,
    partial: true,
    advisor,
  };
}

/**
 * What of a class's cost was the advisor (a second model its agents consulted mid-task), or null when they consulted
 * none: no call is no tag, not a zero. Its share is already in the class's cost; this only says how much it was.
 */
export function advisorWords(cost) {
  const n = cost?.advisorCalls ?? 0;
  if (!(n > 0)) return null;
  const share = typeof cost.advisorCost === 'number' && cost.advisorCost > 0 ? t('{cost} of it', { cost: fmtCost(cost.advisorCost) }) : t('its cost not priced');
  return n === 1 ? t('Advisor: 1 call, {share}. A second model the agents consulted, at that model\'s rates; included above.', { share })
    : t('Advisor: {n} calls, {share}. A second model the agents consulted, at that model\'s rates; included above.', { n, share });
}

/** One class as the view's row: who and what kind of change, how risky, what ran it, and how it went. */
export function classRow(c, cost = null) {
  const models = Object.entries(c.models ?? {}).sort((a, b) => b[1].runs - a[1].runs).map(([k, m]) => `${tierWord(k)} ${m.runs}`).join(' \u00b7 ');
  const apart = [
    c.notVerified?.none ? t('{n} with no verify command', { n: c.notVerified.none }) : null,
    c.notVerified?.blocked ? t('{n} not run', { n: c.notVerified.blocked }) : null,
    c.notVerified?.timeout ? t('{n} timed out', { n: c.notVerified.timeout }) : null,
  ].filter(Boolean);
  return {
    key: c.key,
    who: roleName(c.agent),
    real: c.agent,
    change: c.change,
    risk: c.risk,
    models,
    ranOn: Object.keys(c.ranOn ?? {}).map(modelName).join(', '),
    // Held one model up by the record of outcomes: said beside the model, with the count that did it.
    ...floorWords(c.floor),
    tasks: String(c.runs),
    // The rate and what it is a rate of: "83%" of five calls is not "83%" of five hundred.
    firstTry: c.firstTryRate === null ? '\u2014' : pct(c.firstTryRate),
    firstTryOf: c.firstTryRate === null ? t('No call of this class got a verdict from its verify command') : t('{n} of {of} verified calls passed the first time', { n: c.firstTry, of: c.verified }),
    rate: c.firstTryRate,
    notVerified: apart.join(' \u00b7 '),
    after: [c.fixed ? t('{n} fixed by the agent', { n: c.fixed }) : null, c.failed ? t('{n} failed', { n: c.failed }) : null].filter(Boolean).join(' \u00b7 '),
    escalated: String(c.escalated ?? 0),
    ...costCell(cost, c.runs),
  };
}

/**
 * The command that lowers one hold: Crewforth's own, typed by the user in their own session. Studio copies it and
 * runs nothing. Three words, the class as Crewforth's record names it; the model is not in it, because the command
 * lowers by one step and works that out itself. Null when a word is not one the command could take.
 */
export function lowerCommand(s) {
  const words = [s?.agent, s?.change, s?.risk];
  return words.every((w) => typeof w === 'string' && /^[A-Za-z0-9._-]+$/.test(w)) ? `/crew-loosen ${words.join(' ')}` : null;
}

/** A hold that could be lowered, in words. */
export function suggestionText(s) {
  return {
    title: `${roleName(s.agent)} \u00b7 ${s.change}`,
    says: t('passed {n} of {n} on {from}: try {to} for this class?', { n: s.passed, from: tierWord(s.from), to: tierWord(s.to) }),
    how: t('Yours to decide: send the command in your own session. Studio does not write it.'),
    command: lowerCommand(s),
  };
}

/**
 * Normal work that ran above the table's model, in words. The gate holds a floor, not a ceiling, so this is said
 * and nothing is blocked. That the table's model would have done is said only from the record (`a.passed`); the
 * cost beside it is the same tokens at that model's price, which is not what that model would have spent.
 * @param a     one class of server/lib/model-outcomes.js `aboveTableOf`
 * @param cost  { cost, atNormal, costed, runs } for it, or null while costs have not been read
 */
export function aboveText(a, cost = null) {
  const to = tierWord(a.to);
  const ran = Object.entries(a.models ?? {}).sort((x, y) => y[1] - x[1]).map(([k, n]) => t('{n} on {model}', { n, model: tierWord(k) })).join(', ');
  let costs = null;
  if (cost?.costed) {
    const some = cost.costed < cost.runs;
    const usd = (v) => (some ? `\u2265${fmtCost(v).replace(/^~/, '')}` : fmtCost(v));
    costs = some
      ? t('{cost} as run; the same tokens at {model}\'s price {normal} ({n} of {runs} priced). API list price; another model would not spend the same tokens.', { cost: usd(cost.cost), model: to, normal: usd(cost.atNormal), n: cost.costed, runs: cost.runs })
      : t('{cost} as run; the same tokens at {model}\'s price {normal}. API list price; another model would not spend the same tokens.', { cost: usd(cost.cost), model: to, normal: usd(cost.atNormal) });
  }
  return {
    title: `${roleName(a.agent)} \u00b7 ${a.change}`,
    says: a.runs === 1 ? t('normal risk, 1 task above {model}: {ran}.', { model: to, ran }) : t('normal risk, {n} tasks above {model}: {ran}.', { n: a.runs, model: to, ran }),
    verdict: a.passed
      ? t('{model} is enough for this class: its latest {n} verified calls on {model} all passed the first time.', { model: to, n: a.passed })
      : a.need != null
        ? t('Whether {model} would have done is not measured: this class does not have {n} verified calls on {model} that all passed the first time.', { model: to, n: a.need })
        : t('Whether {model} would have done is not measured: this class does not have enough verified calls on {model} that all passed the first time.', { model: to }),
    measured: Boolean(a.passed),
    costs,
  };
}

export const ABOVE_HEAD = t('Above the table \u00b7 nothing is blocked');
export const ABOVE_RULE = t('The gate holds a floor, not a ceiling: which model runs normal work is yours to choose.');

/** What the view says when there is nothing to list. */
export function emptyNote(data) {
  if (!data) return t('Reading the record…');
  if (data.measured === false) return t('Not measured — {reason}', { reason: data.reason });
  if (!data.classes?.length) return t('The record is there and has no line yet.');
  return null;
}

export const SOURCE = t('Source: .claude/state/model-outcomes.tsv');
export const LOWER_RULE = t('Lowering a floor is never automatic. Raising it is.');

/** What was read for cost, for the header's tooltip; null before it has been. */
export const costLine = (costs) => (costs?.measured ? (costs.sessionsRead === 1 ? t('1 session read for cost') : t('{n} sessions read for cost', { n: fmtCount(costs.sessionsRead ?? 0) })) : null);

export const totalsLine = (data) => [
  `${(data.rows ?? 0) === 1 ? t('1 task') : t('{n} tasks', { n: data.rows ?? 0 })} ${(data.classes?.length ?? 0) === 1 ? t('in 1 class') : t('in {n} classes', { n: data.classes?.length ?? 0 })}`,
  data.dropped ? `${data.dropped === 1 ? t('1 line not read') : t('{n} lines not read', { n: data.dropped })} (${Object.entries(data.droppedWhy ?? {}).map(([why, n]) => `${n}: ${why}`).join('; ') || t('no reason kept')})` : null,
  data.truncated ? t('only the end of a long record was read') : null,
].filter(Boolean).join(' · ');
