// What a conversation is made of, worked out from records with no page in it.
//
// The same shapes come from two places: the server's reading of a transcript (history, and sessions Studio only
// watches) and the live stream of a session started here. Both go through these functions, so a tool row reads
// the same whichever way it arrived.
import { roleName } from './names.js';

// How much of a tool's output the page keeps for a live result: the same tail the server keeps for history.
const RESULT_TAIL = 4096;
const SUMMARY_MAX = 80;

const DELEGATION_TOOLS = new Set(['Agent', 'Task']);

/** A `tool_use` content item as the block the panel draws. */
export function toolBlock(c) {
  const i = c?.input ?? {};
  return {
    kind: 'tool',
    name: c?.name ?? 'tool',
    label: i.description ?? i.file_path ?? i.command ?? i.pattern ?? i.query ?? null,
    id: typeof c?.id === 'string' ? c.id : null,
    subagentType: typeof i.subagent_type === 'string' ? i.subagent_type : null,
    result: null,
  };
}

/** A `tool_result` content item, cut to its tail, with the cut said. */
export function resultFrom(c) {
  const raw = typeof c?.content === 'string'
    ? c.content
    : Array.isArray(c?.content) ? c.content.filter((x) => x?.type === 'text').map((x) => x.text).join('\n') : '';
  const truncated = raw.length > RESULT_TAIL;
  return { error: c?.is_error === true, text: truncated ? raw.slice(-RESULT_TAIL) : raw, truncated, length: raw.length };
}

/** The tool results in one `user` record: [[toolUseId, result], …]. */
export function resultsIn(content) {
  if (!Array.isArray(content)) return [];
  return content
    .filter((c) => c?.type === 'tool_result' && typeof c.tool_use_id === 'string')
    .map((c) => [c.tool_use_id, resultFrom(c)]);
}

/** Is this call the session handing work to an agent? */
export function isDelegation(block) {
  return block?.kind === 'tool' && DELEGATION_TOOLS.has(block.name);
}

/**
 * What a tool row says after the tool's name and what it was run on.
 *
 * The output's own last line, and nothing made from it: "42 passed" is there because the test runner printed
 * it. A call that has not come back says so, and so does one whose result was not read; neither is drawn as a
 * call that returned nothing.
 */
export function summaryOf(block) {
  const r = block?.result;
  if (!r) return { state: 'pending', text: null };
  const lines = r.text.split('\n').map((l) => l.trim()).filter(Boolean);
  const last = lines.length ? lines[lines.length - 1] : null;
  const text = last == null ? 'no output' : (last.length > SUMMARY_MAX ? `${last.slice(0, SUMMARY_MAX - 1)}…` : last);
  return { state: r.error ? 'error' : 'ok', text };
}

/** The output as it is shown when a row is opened, with what was left out said first. */
export function outputOf(block) {
  const r = block?.result;
  if (!r) return null;
  if (!r.text) return '(no output)';
  return r.truncated ? `… ${(r.length - r.text.length).toLocaleString('en-US')} earlier characters not shown\n${r.text}` : r.text;
}

/**
 * The card a delegation is drawn as: the agent's type, its task, and — when the graph knows the agent that call
 * became — its status. An agent the graph has not seen yet has no status here; none is guessed.
 */
export function delegationCard(block, nodes) {
  const node = block.id ? (nodes ?? []).find((n) => n.kind === 'agent' && n.toolUseId === block.id) ?? null : null;
  return {
    type: roleName(block.subagentType ?? node?.agentType ?? 'agent'),
    real: block.subagentType ?? node?.agentType ?? null,
    task: block.label ?? node?.description ?? '',
    agentId: node?.id ?? null,
    status: node?.status ?? null,
  };
}

/**
 * The calls the viewer allowed and Claude Code refused anyway.
 *
 * An answer given in the dock is not the last word: the harness has its own checks after the hook, and a
 * headless session has nobody to ask when one of them wants a person. The session's `result` record lists every
 * call that was refused, by id; the ones this page allowed are the ones worth a line, because without it the
 * dock said "allowed" and nothing happened. A tool that ran and failed is not in that list, and is not called
 * a refusal here.
 *
 * @param denials     `permission_denials` of a result record
 * @param wasAllowed  (toolUseId, toolName) => did this page allow it
 * @param resultOf    toolUseId => the result on screen for that call, if there is one
 */
export function refusals(denials, wasAllowed, resultOf = () => null) {
  const out = [];
  for (const d of Array.isArray(denials) ? denials : []) {
    if (typeof d?.tool_use_id !== 'string' || !wasAllowed(d.tool_use_id, d.tool_name ?? null)) continue;
    const i = d.tool_input ?? {};
    const what = i.command ?? i.file_path ?? i.description ?? null;
    const reason = resultOf(d.tool_use_id)?.text?.split('\n').map((l) => l.trim()).filter(Boolean)[0] ?? null;
    // Who refused is in the result's own words. Another PreToolUse hook that blocked the call is reported by
    // the harness as a hook error; anything else is the harness's own check. With no result on screen the line
    // says only what is known: it was allowed here and did not run.
    const by = reason == null ? 'it did not run'
      : /^PreToolUse:\S* hook error/.test(reason) ? 'another gate blocked it' : 'Claude Code refused it';
    out.push({
      id: d.tool_use_id,
      text: `Allowed here, but ${by}: ${d.tool_name ?? 'tool'}${what ? ` · ${String(what).slice(0, 120)}` : ''}`
        + (reason ? ` — ${reason.slice(0, 200)}` : ''),
    });
  }
  return out;
}

/** The line that says a request is waiting, for the session a pane shows. Null when none is. */
export function reminderOf(waiting) {
  const list = waiting ?? [];
  if (!list.length) return null;
  const who = list[0].agentType ? roleName(list[0].agentType) : 'This session';
  const more = list.length - 1;
  return `${who} is waiting for approval${more > 0 ? `, and ${more} more ${more === 1 ? 'request is' : 'requests are'}` : ''}`;
}

/** The strip above a conversation: what kind of session this is, in the order the design has it. */
export function headerOf(session, { readOnly = false, contextTokens = null } = {}) {
  if (readOnly) return { badge: 'Read only', tone: 'none', parts: [] };
  const parts = [];
  if (session?.permissionMode) parts.push(`mode: ${session.permissionMode}`);
  const facts = [];
  if (typeof session?.turns === 'number') facts.push(`${session.turns} ${session.turns === 1 ? 'turn' : 'turns'}`);
  if (contextTokens != null) facts.push(`${fmtK(contextTokens)} ctx`);
  if (facts.length) parts.push(facts.join(' · '));
  return {
    badge: 'Started here',
    tone: 'good',
    parts,
    // A session started here without the gate is running unguarded, and that is said in the strip itself.
    ungated: session ? session.gated === false : false,
  };
}

function fmtK(t) {
  if (t < 1000) return `${t}`;
  if (t < 1_000_000) return `${(t / 1000).toFixed(t < 10_000 ? 1 : 0)}k`;
  return `${(t / 1_000_000).toFixed(2)}M`;
}

/**
 * Run `fn` at most once per arming.
 *
 * A guard that only refuses while a request is in flight lets a second click through the moment the first
 * answer lands: two clicks, two sessions. This one is spent by its first call and stays spent — a later call
 * gets the first call's answer — until `arm()` says a new attempt is meant. A call that failed re-arms itself,
 * so a refusal can be retried without reopening anything.
 */
export function oneShot(fn) {
  let spent = null;
  const run = (...args) => {
    if (spent) return spent;
    spent = Promise.resolve().then(() => fn(...args)).then(
      (out) => { if (out && out.ok === false) spent = null; return out; },
      (err) => { spent = null; throw err; },
    );
    return spent;
  };
  run.arm = () => { spent = null; };
  run.spent = () => spent !== null;
  return run;
}
