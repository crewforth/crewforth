// What the inspector says about the node that is selected.
//
// Functions of the server's data, with no page in them: the four tiles, what the agent is doing right now, which
// skills it applied, who delegated to it. The rule they share is the panel's own: a value that was not read is
// written "Not measured", with why — never as 0 and never as an empty list.
import { roleName } from './names.js';

const NOT_MEASURED = 'Not measured';

export function fmtTokens(t) {
  if (t == null) return null;
  if (t < 1000) return `${t}`;
  if (t < 1_000_000) return `${(t / 1000).toFixed(t < 10_000 ? 1 : 0)}k`;
  return `${(t / 1_000_000).toFixed(2)}M`;
}

export function fmtDuration(ms) {
  if (ms == null || !Number.isFinite(ms)) return null;
  const s = Math.max(0, Math.round(ms / 1000));
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  return m < 60 ? `${m}m ${s % 60}s` : `${Math.floor(m / 60)}h ${m % 60}m`;
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
    { label: 'Tool calls', value: String(n.toolCount ?? 0), measured: n.toolCount != null },
    {
      label: 'Tokens',
      value: n.tokens == null ? NOT_MEASURED : fmtTokens(n.tokens),
      measured: n.tokens != null,
      why: n.tokens == null ? 'the transcript carries no usage record for this agent yet' : null,
    },
    {
      label: 'Elapsed',
      value: el == null ? NOT_MEASURED : fmtDuration(el),
      measured: el != null,
      why: el == null ? 'no start time was recorded' : null,
    },
    { label: 'Errors', value: String(n.errors ?? 0), measured: n.errors != null, bad: (n.errors ?? 0) > 0 },
  ].map((t) => (t.measured ? t : { ...t, value: NOT_MEASURED, why: t.why ?? 'not in the transcript' }));
}

/** "8m 20s · started 14:02" */
export function timeLine(n, nowMs) {
  const parts = [];
  const el = elapsed(n, nowMs);
  if (el != null) parts.push(fmtDuration(el));
  if (n.startedAt != null) {
    const d = new Date(n.startedAt);
    parts.push(`started ${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`);
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
  if (!tool) return { heading: live ? 'Right now' : 'Last tool', tool: null, text: live ? 'No tool call yet' : 'No tool was called' };
  return { heading: live ? 'Right now' : 'Last tool', tool, text: last?.label ?? '' };
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

/** Who handed this agent its work: the node it hangs from. */
export function delegatedBy(n, nodes) {
  const p = (nodes ?? []).find((x) => x.id === n.parentId) ?? null;
  if (!p) return null;
  if (p.kind === 'session') return { id: p.id, text: `Session${p.gitBranch ? ` · ${p.gitBranch}` : ''}` };
  if (p.kind === 'workflow') return { id: p.id, text: `Workflow run · ${p.workflowId ?? p.id}` };
  return { id: p.id, text: p.agentType ? roleName(p.agentType) : p.id };
}

/** The report, or the plain statement that there is none yet and why. */
export function reportOf(n, detail) {
  if (detail?.report) return { text: detail.report, present: true };
  const live = n.status === 'running' || n.status === 'starting';
  return {
    present: false,
    text: live ? 'Not reported yet — the agent is still running.' : 'Not reported — the transcript holds no closing text.',
  };
}

export const TABS = ['overview', 'conversation', 'gates', 'stats'];
export const TAB_WORD = { overview: 'Overview', conversation: 'Conversation', gates: 'Gates', stats: 'Stats' };
