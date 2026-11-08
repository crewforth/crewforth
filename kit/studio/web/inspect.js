// What the inspector says about the node that is selected.
//
// Functions of the server's data, with no page in them: the four tiles, what the agent is doing right now, which
// skills it applied, who delegated to it. The rule they share is the panel's own: a value that was not read is
// written "Not measured", with why — never as 0 and never as an empty list.
import { roleName, modelName, modelFamily, modelOf } from './names.js';
import { t } from './i18n.js';

const NOT_MEASURED = t('Not measured');

export function fmtTokens(t) {
  if (t == null) return null;
  if (t < 1000) return `${t}`;
  if (t < 1_000_000) return `${(t / 1000).toFixed(t < 10_000 ? 1 : 0)}k`;
  return `${(t / 1_000_000).toFixed(2)}M`;
}

export function fmtDuration(ms) {
  if (ms == null || !Number.isFinite(ms)) return null;
  const s = Math.max(0, Math.round(ms / 1000));
  if (s < 60) return t('{n}s', { n: s });
  const m = Math.floor(s / 60);
  return m < 60 ? t('{m}m {s}s', { m, s: s % 60 }) : t('{h}h {m}m', { h: Math.floor(m / 60), m: m % 60 });
}

/** How long the agent has been at it: the recorded duration when it has ended, the clock since it started while
 *  it is still running, and null when neither was recorded. */
export function elapsed(n, nowMs) {
  if (n.durationMs != null) return n.durationMs;
  if (n.startedAt != null && (n.status === 'running' || n.status === 'starting')) return Math.max(0, nowMs - n.startedAt);
  if (n.startedAt != null && n.endedAt != null) return n.endedAt - n.startedAt;
  return null;
}

/**
 * The four tiles. A count the transcript gave is a count, zero included; a figure it did not give says so.
 */
export function tiles(n, nowMs) {
  const el = elapsed(n, nowMs);
  return [
    { label: t('Tool calls'), value: String(n.toolCount ?? 0), measured: n.toolCount != null },
    {
      label: t('Tokens'),
      value: n.tokens == null ? NOT_MEASURED : fmtTokens(n.tokens),
      measured: n.tokens != null,
      why: n.tokens == null ? t('the transcript carries no usage record for this agent yet') : null,
    },
    {
      label: t('Elapsed'),
      value: el == null ? NOT_MEASURED : fmtDuration(el),
      measured: el != null,
      why: el == null ? t('no start time was recorded') : null,
    },
    { label: t('Errors'), value: String(n.errors ?? 0), measured: n.errors != null, bad: (n.errors ?? 0) > 0 },
  ].map((x) => (x.measured ? x : { ...x, value: NOT_MEASURED, why: x.why ?? t('not in the transcript') }));
}

/** "8m 20s · started 14:02" */
export function timeLine(n, nowMs) {
  const parts = [];
  const el = elapsed(n, nowMs);
  if (el != null) parts.push(fmtDuration(el));
  if (n.startedAt != null) {
    const d = new Date(n.startedAt);
    parts.push(t('started {time}', { time: `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}` }));
  }
  return parts.join(' · ');
}

/**
 * The tool the agent is running, with what it is running it on. "Right now" while the agent works; "Last tool"
 * once it has stopped. The command comes from the agent's transcript, which may not be read yet.
 */
export function rightNow(n, detail) {
  const live = n.status === 'running' || n.status === 'starting';
  const last = detail?.timeline?.length ? detail.timeline[detail.timeline.length - 1] : null;
  const tool = last?.name ?? n.lastTool ?? null;
  if (!tool) return { heading: live ? t('Right now') : t('Last tool'), tool: null, text: live ? t('No tool call yet') : t('No tool was called') };
  return { heading: live ? t('Right now') : t('Last tool'), tool, text: last?.label ?? '' };
}

/** The skills the agent invoked, in the order it first did, each once. */
export function skillsOf(detail) {
  const seen = [];
  for (const step of detail?.timeline ?? []) {
    if (step.name !== 'Skill' || !step.label) continue;
    if (!seen.includes(step.label)) seen.push(step.label);
  }
  return seen;
}

/**
 * The commands a session has running in the background, as lines: what runs, and for how long.
 * `backgroundNow` is empty unless the session is live (graph-plan.js `settle`), so a session that is over lists none.
 */
export function backgroundLines(session, now) {
  return (session?.backgroundNow ?? []).map((c) => ({
    id: c.id,
    what: `${c.toolName}${c.detail ? ` · ${c.detail}` : ''}`,
    age: c.startedAt != null && now >= c.startedAt ? fmtDuration(now - c.startedAt) : null,
  }));
}

/**
 * What the inspector says about an agent's model, as lines: { label, text, goto }.
 *
 * Two facts are kept apart: what the call ASKED for (its own `model` field; none means the agent's default) and
 * what the agent RAN on (the model its own transcript names). Then, when the transcript shows them: the call the
 * model gate refused first, and the same work repeated one model up after a report that closed `confidence: low`.
 * `goto` is the id of the other agent a line is about, for a line that leads somewhere.
 */
export function modelLines(n, nodes) {
  if (n?.kind !== 'agent') return [];
  const m = modelOf(n);
  const lines = [
    { label: t('Ran on'), text: n.model ? `${m.ran} \u00b7 ${n.model}` : t('not recorded') },
    { label: t('Asked for'), text: n.modelAsked ? `${n.modelAsked}${m.differs ? ` \u2014 ${t('differs from what ran')}` : ''}` : t('no model named (the agent\'s default)') },
  ];
  // The family is the word the choice is made in (haiku, sonnet, opus); a model with none keeps its own name.
  const short = (model) => (model ? (modelFamily(model) ?? modelName(model).toLowerCase()) : t('no model'));
  if (n.firstTry) {
    lines.push({
      label: t('Model gate'),
      text: n.firstTry.floor
        ? t('first asked: {asked} \u2192 refused (floor: {floor}) \u2192 {ran}', { asked: short(n.firstTry.asked), floor: n.firstTry.floor, ran: short(n.modelAsked ?? n.model) })
        : t('first asked: {asked} \u2192 refused \u2192 {ran}', { asked: short(n.firstTry.asked), ran: short(n.modelAsked ?? n.model) }),
      note: n.firstTry.text,
    });
  }
  const tagOf = (id) => { const o = (nodes ?? []).find((x) => x.id === id); return o?.order != null ? ` (#${o.order})` : ''; };
  if (n.escalatedFrom) {
    lines.push({ label: t('Escalated'), text: t('escalated: {from} \u2192 {to}, after{tag} closed "confidence: low"', { from: short(n.escalatedFrom.from), to: short(n.escalatedFrom.to), tag: tagOf(n.escalatedFrom.id) }), goto: n.escalatedFrom.id });
  }
  if (n.escalatedTo) lines.push({ label: t('Escalated'), text: t('closed "confidence: low"; repeated one model up{tag}', { tag: tagOf(n.escalatedTo) }), goto: n.escalatedTo });
  return lines;
}

/** Who handed this agent its work: the node it hangs from. */
export function delegatedBy(n, nodes) {
  const p = (nodes ?? []).find((x) => x.id === n.parentId) ?? null;
  if (!p) return null;
  if (p.kind === 'session') return { id: p.id, text: `${t('Session')}${p.gitBranch ? ` · ${p.gitBranch}` : ''}` };
  if (p.kind === 'workflow') return { id: p.id, text: `${t('Workflow run')} · ${p.workflowId ?? p.id}` };
  return { id: p.id, text: p.agentType ? roleName(p.agentType) : p.id };
}

/** The report, or the plain statement that there is none yet and why. */
export function reportOf(n, detail) {
  if (detail?.report) return { text: detail.report, present: true };
  const live = n.status === 'running' || n.status === 'starting';
  return {
    present: false,
    text: live ? t('Not reported yet — the agent is still running.') : t('Not reported — the transcript holds no closing text.'),
  };
}

export const TABS = ['overview', 'conversation', 'gates', 'stats'];
export const TAB_WORD = { overview: t('Overview'), conversation: t('Conversation'), gates: t('Gates'), stats: t('Stats') };
