// What the Models view and the inspector say about which model did which work. No page in it.
//
// The numbers are Crewforth's own record (server/lib/model-outcomes.js reads it); this file turns them into words.
// A rate with nothing under it is not written as zero, and a call whose verify command gave no verdict is shown
// apart from the ones that passed or failed.
import { roleName, modelName } from './names.js';
import { fmtCost, fmtCount } from './usage.js';

const TIER = { haiku: 'Haiku', sonnet: 'Sonnet', opus: 'Opus', fable: 'Fable' };
export const tierWord = (t) => TIER[t] ?? (t ? String(t) : 'no model');
const pct = (r) => `${Math.round(r * 100)}%`;
const plural = (n, word, many = `${word}s`) => `${n} ${n === 1 ? word : many}`;

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
const VERIFY_SAYS = { none: 'no verify command', blocked: 'verify not run: the command was not allowed', timeout: 'verify not finished: the command ran out of time' };

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
  const bits = [again ? `Re-run on ${on}` : `Ran on ${on}`];
  if (r.fixes > 0) bits.push(`fixed ${r.fixes === 1 ? 'once' : `${r.fixes} times`} inside the agent`);
  // A verdict is a tag (pass, fail); anything else is said in words, because it is no verdict.
  const tone = VERIFY_TONE[r.verify] ?? null;
  if (!tone) bits.push(VERIFY_SAYS[r.verify] ?? `verify ${r.verify}`);
  return { text: bits.join(' \u00b7 '), verify: tone ? r.verify : null, tone, escalated: again };
}

/**
 * How the work went, as steps: the earlier calls of the same card, then this one. `row` is Crewforth's line for
 * the agent with `before` (see server/lib/model-outcomes.js), or null when it has none: it has not stopped, or it
 * is not a crew agent.
 * @returns { risk, steps: [{ text, verify, tone, escalated }], note }
 */
export function workSteps(row) {
  if (!row) return { risk: null, steps: [], note: 'Not recorded yet: the line is written when the agent stops.' };
  const steps = [...(row.before ?? []).map((r) => stepOf(r, false)), stepOf(row, Boolean(row.escalatedFrom))];
  if (row.escalatedFrom && !(row.before ?? []).length) {
    steps.unshift({ text: `An earlier call on ${tierWord(row.escalatedFrom)} did not pass; its line is not in the record`, verify: null, tone: null, escalated: false });
  }
  return { risk: row.risk ?? null, steps, note: row.escalatedFrom ? 'A re-run with the same or a lower model is refused by the gate.' : null };
}

/** One class as the view's row: who and what kind of change, how risky, what ran it, and how it went. */
export function classRow(c) {
  const models = Object.entries(c.models ?? {}).sort((a, b) => b[1].runs - a[1].runs).map(([t, m]) => `${tierWord(t)} ${m.runs}`).join(' \u00b7 ');
  const apart = [
    c.notVerified?.none ? `${c.notVerified.none} with no verify command` : null,
    c.notVerified?.blocked ? `${c.notVerified.blocked} not run` : null,
    c.notVerified?.timeout ? `${c.notVerified.timeout} timed out` : null,
    c.notVerified?.other ? `${c.notVerified.other} unreadable` : null,
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
    raised: c.floor ? tierWord(c.floor.model) : null,
    raisedWhy: c.floor ? `Raised to ${tierWord(c.floor.model)} automatically: ${c.floor.notFirstTry} of ${c.floor.calls ?? '?'} calls one model down did not pass first time` : '',
    tasks: String(c.runs),
    // The rate and what it is a rate of: "83%" of five calls is not "83%" of five hundred.
    firstTry: c.firstTryRate === null ? '\u2014' : pct(c.firstTryRate),
    firstTryOf: c.firstTryRate === null ? 'No call of this class got a verdict from its verify command' : `${c.firstTry} of ${c.verified} verified calls passed the first time`,
    rate: c.firstTryRate,
    notVerified: apart.join(' \u00b7 '),
    after: [c.fixed ? `${c.fixed} fixed by the agent` : null, c.failed ? `${c.failed} failed` : null].filter(Boolean).join(' \u00b7 '),
    escalated: String(c.escalated ?? 0),
    cost: c.cost === null ? '\u2014' : fmtCost(c.cost),
    costNote: c.cost === null ? 'No agent of this class has a transcript on this machine that could be priced' : `${c.costed} of ${c.runs} calls priced, at API list price`,
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
    says: `passed ${s.passed} of ${s.passed} on ${tierWord(s.from)}: try ${tierWord(s.to)} for this class?`,
    how: 'Yours to decide: send the command in your own session. Studio does not write it.',
    command: lowerCommand(s),
  };
}

/** What the view says when there is nothing to list. */
export function emptyNote(data) {
  if (!data) return 'Reading the record…';
  if (data.measured === false) return `Not measured — ${data.reason}`;
  if (!data.classes?.length) return 'The record is there and has no line yet.';
  return null;
}

export const SOURCE = 'Source: .claude/state/model-outcomes.tsv';
export const LOWER_RULE = 'Lowering a floor is never automatic. Raising it is.';

export const totalsLine = (data) => [
  `${plural(data.rows ?? 0, 'task')} in ${plural(data.classes?.length ?? 0, 'class', 'classes')}`,
  data.dropped ? `${data.dropped} unreadable ${data.dropped === 1 ? 'line' : 'lines'}` : null,
  data.truncated ? 'only the end of a long record was read' : null,
  `${fmtCount(data.sessionsRead ?? 0)} ${data.sessionsRead === 1 ? 'session' : 'sessions'} read for cost`,
].filter(Boolean).join(' · ');
