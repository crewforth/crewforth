// The orchestration graph: one node per agent, one edge per spawn.
//
// Nothing here is documented by Claude Code, so every field was read off real
// transcripts and every one of them is optional. A record shape that changes
// should cost this file a field, never a crash — unknown values are carried,
// not coerced.
//
// The chain that makes the graph possible, measured:
//   main transcript  assistant → content[].tool_use{ name:"Agent", id, input }
//   main transcript  user      → toolUseResult{ agentId, status, resolvedModel }
//   on disk          subagents/agent-<agentId>.meta.json{ agentType, toolUseId, spawnDepth }
//   main transcript  text      → <task-id>…</task-id> + <status>completed</status>
//
// `toolUseId` is the join. Whoever emitted that tool_use is the parent: the
// session itself for depth 1, another agent for anything deeper.

import fsp from 'node:fs/promises';
import path from 'node:path';

import { readAll, contextFill } from './transcript.js';
import { agentMetaFiles } from './projects.js';
import { Usage, withTimes } from './usage.js';
import { detailOf } from './permissions.js';

const SESSION_NODE = 'session';

function textOf(content) {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  let s = '';
  for (const c of content) if (c?.type === 'text' && typeof c.text === 'string') s += c.text;
  return s;
}

/**
 * Completion notices arrive as prose, so they are read as prose.
 *
 * Claude Code sometimes batches several ids under one status. A regex that
 * pairs the first id with the status swallows the rest; measured on this
 * machine, one notice carried six ids and five were being dropped. Every id
 * seen since the previous status takes that status.
 *
 * `at` is when the record carrying the notice was written. A notice is not the end of an agent: Claude Code sends
 * one each time a background agent stops, and the agent can be sent another message and work again. Whether a
 * notice still stands is decided by comparing `at` with what the agent wrote afterwards.
 */
function harvestCompletions(text, into, at = null) {
  if (!text || !text.includes('<task-id>')) return;
  const token = /<task-id>([^<]+)<\/task-id>|<status>([^<]+)<\/status>/g;
  let pending = [];
  let m;
  while ((m = token.exec(text)) !== null) {
    if (m[1] !== undefined) {
      pending.push(m[1].trim());
    } else {
      const status = m[2].trim();
      for (const id of pending) into.set(id, { status, at });
      pending = [];
    }
  }
}

// The line the model gate (kit/hooks/guard-agent-model.sh) refuses a call with starts with this, whatever follows.
const MODEL_GATE = 'GUARD (agent model):';

/**
 * What the model gate said when it refused a call, or null when the text is not its refusal.
 * `floor` is the model it says the agent runs on "or above", when it says one; nothing is read into a sentence
 * that does not say it.
 */
export function refusalOf(text) {
  const at = typeof text === 'string' ? text.indexOf(MODEL_GATE) : -1;
  if (at === -1) return null;
  const line = text.slice(at).split('\n')[0].trim();
  const floor = line.match(/ runs on ([a-z0-9.-]+) or above/);
  return { text: line.slice(0, 400), floor: floor ? floor[1] : null };
}

// Which of two models is the larger, for the two questions asked of it: was a call repeated on a higher model,
// and which is "one model up". A name this does not know has no rank, and nothing is concluded from it.
const FAMILY = ['haiku', 'sonnet', 'opus', 'fable'];
export function modelRank(model) {
  if (typeof model !== 'string') return null;
  const i = FAMILY.findIndex((f) => model === f || model.includes(`-${f}-`) || model.startsWith(`${f}-`) || model.endsWith(`-${f}`));
  return i === -1 ? null : i;
}

/** How a report says it ended: the `confidence: high|low` line a crew agent closes with, or null. */
export function confidenceOf(text) {
  const m = typeof text === 'string' ? text.trimEnd().match(/(?:^|\n)\W*confidence:\s*(high|low)\W*$/i) : null;
  return m ? m[1].toLowerCase() : null;
}

/**
 * Tie each agent call to what came before it, where the transcript says so.
 *
 * `firstTry` — the gate refused a call and the session made the same call again (same agent, same task): the
 * call that ran carries what was asked first and why it was refused.
 * Returns nothing; it writes onto the calls.
 */
export function linkRetries(calls) {
  const list = [...calls.values()].sort((a, b) => a.order - b.order);
  list.forEach((c, i) => {
    if (!c.refused) return;
    const again = list.slice(i + 1).find((n) => n.subagentType === c.subagentType && n.description === c.description);
    if (!again) return;
    // A call refused twice keeps the first thing that was asked.
    again.firstTry = c.firstTry ?? { asked: c.model, floor: c.refused.floor, text: c.refused.text };
  });
}

/**
 * `escalatedFrom` / `escalatedTo` — an agent's report closed with `confidence: low`, and the next call to the same
 * agent after it reported asked for a higher model: the same work, done again one model up. Read from the order
 * of the calls, the two reports and the two models; where any of the three is missing nothing is linked.
 */
export function linkEscalations(nodes) {
  const agents = nodes.filter((n) => n.kind === 'agent' && n.order != null).sort((a, b) => a.order - b.order);
  agents.forEach((low, i) => {
    if (low.confidence !== 'low' || low.reportedAt == null) return;
    const from = modelRank(low.model ?? low.modelAsked);
    if (from === null) return;
    const again = agents.slice(i + 1).find((n) => n.agentType === low.agentType && n.calledAt != null && n.calledAt >= low.reportedAt);
    const to = again ? modelRank(again.modelAsked ?? again.model) : null;
    if (to === null || to <= from || again.escalatedFrom) return;
    again.escalatedFrom = { id: low.id, from: low.model ?? low.modelAsked, to: again.modelAsked ?? again.model };
    low.escalatedTo = again.id;
  });
}

function scanMain(records) {
  const out = {
    cwd: null, gitBranch: null, version: null, model: null,
    startedAt: null, updatedAt: null,
    agentCalls: new Map(),   // toolUseId -> { subagentType, description }
    links: new Map(),        // toolUseId -> { agentId, status, model }
    completions: new Map(),  // task id (an agent's, or a background command's) -> { status, at }
    waves: new Map(),        // assistant message id -> wave number, in the order the messages were written
    commands: new Map(),     // toolUseId -> the command a Bash call ran
    background: new Map(),   // background task id -> { toolUseId, startedAt }
    owners: new Map(),       // toolUseId -> owner node id
    userTurns: 0,
  };

  for (const r of records) {
    if (r?.isSidechain === true) continue;

    if (r?.cwd && !out.cwd) out.cwd = r.cwd;
    if (r?.gitBranch && !out.gitBranch) out.gitBranch = r.gitBranch;
    if (r?.version && !out.version) out.version = r.version;
    let at = null;
    if (r?.timestamp) {
      const t = Date.parse(r.timestamp);
      if (Number.isFinite(t)) {
        at = t;
        if (out.startedAt === null || t < out.startedAt) out.startedAt = t;
        if (out.updatedAt === null || t > out.updatedAt) out.updatedAt = t;
      }
    }

    if (r?.type === 'assistant') {
      if (r.message?.model && !out.model) out.model = r.message.model;
      const content = r.message?.content;
      if (Array.isArray(content)) {
        for (const c of content) {
          if (c?.type === 'tool_use' && c.id) {
            out.owners.set(c.id, SESSION_NODE);
            if (typeof c.input?.command === 'string') out.commands.set(c.id, c.input.command);
            if (c.name === 'Agent' || c.name === 'Task') {
              // The order the session called its agents in, and which calls were made together: the calls of one
              // assistant message are one wave. A message is written as several records, one per block, and they
              // share its id — so the wave is the message id, not the record.
              const mid = r.message?.id ?? `record:${out.agentCalls.size}`;
              if (!out.waves.has(mid)) out.waves.set(mid, out.waves.size + 1);
              out.agentCalls.set(c.id, {
                subagentType: c.input?.subagent_type ?? null,
                description: c.input?.description ?? null,
                order: out.agentCalls.size + 1,
                wave: out.waves.get(mid),
                calledAt: at,
                // The model the call asked for: its own `model` field. Absent, the agent runs on its default.
                model: typeof c.input?.model === 'string' ? c.input.model : null,
              });
            }
          }
        }
      }
      harvestCompletions(textOf(content), out.completions, at);
    }

    if (r?.type === 'user') {
      // A call the model gate refused: the answer is an error that carries the gate's own line. No agent started.
      for (const c of Array.isArray(r.message?.content) ? r.message.content : []) {
        if (c?.type !== 'tool_result' || c.is_error !== true || !out.agentCalls.has(c.tool_use_id)) continue;
        const said = refusalOf(textOf(typeof c.content === 'string' ? [{ type: 'text', text: c.content }] : c.content));
        if (said) out.agentCalls.get(c.tool_use_id).refused = said;
      }
      out.userTurns += 1;
      harvestCompletions(textOf(r.message?.content), out.completions, at);
    }

    // Present on the record that carries a subagent's result, whatever its type.
    const tur = r?.toolUseResult;
    if (tur && typeof tur === 'object' && tur.agentId) {
      const id = r.message?.content?.find?.((c) => c?.type === 'tool_result')?.tool_use_id
        ?? r.toolUseID ?? null;
      // `at` is when the answer was written: for a call the session waited on, that is when the agent reported.
      const entry = { agentId: tur.agentId, status: tur.status ?? null, model: tur.resolvedModel ?? null, at };
      if (id) out.links.set(id, entry);
      else out.links.set(`agent:${tur.agentId}`, entry);
    }
    // A command sent to the background answers at once with the id it runs under; its end comes later, as a notice.
    if (tur && typeof tur === 'object' && typeof tur.backgroundTaskId === 'string') {
      const id = r.message?.content?.find?.((c) => c?.type === 'tool_result')?.tool_use_id ?? null;
      out.background.set(tur.backgroundTaskId, { toolUseId: id, startedAt: at });
    }
    if (r?.type === 'attachment') harvestCompletions(JSON.stringify(r.attachment ?? ''), out.completions, at);
  }

  return out;
}

/**
 * Does a transcript stop in the middle of a turn? It does when the last thing in it is a tool call with no answer,
 * or an answer the agent has not replied to. A turn that is over ends on the agent's own words.
 */
export function midTurn(records) {
  for (let i = records.length - 1; i >= 0; i -= 1) {
    const r = records[i];
    if (r?.type !== 'assistant' && r?.type !== 'user') continue;
    const content = r.message?.content;
    if (r.type === 'user') return true;
    return Array.isArray(content) && content.some((c) => c?.type === 'tool_use');
  }
  return false;
}

// How long after a notice an agent's own last record may be and still belong to the turn the notice ended. The
// notice is written after the agent's last record, so anything later than this is the agent working again.
const NOTICE_SLACK_MS = 5000;

/**
 * Does a completion notice still say how the agent stands? Not when the agent wrote to its transcript after it:
 * it was sent another message and is working, or has worked, again.
 */
export function noticeStands(notice, lastOwnAt) {
  if (!notice) return false;
  if (notice.at == null || lastOwnAt == null) return true;
  return lastOwnAt <= notice.at + NOTICE_SLACK_MS;
}

// A call that hands work to an agent is open for as long as that agent runs; it is not a call anyone is asked about.
const DELEGATES = new Set(['Agent', 'Task']);
const OPEN_DETAIL_MAX = 2000;

/**
 * The tool calls a transcript has asked for and has no result for yet, oldest first.
 *
 * A call is open while it runs and while it waits for someone to allow it; the transcript does not say which. It
 * is what a session started in a terminal is asking about when the machine reports it as waiting for its user —
 * the panel has no hook in such a session, so this is the only place the question can be read from.
 */
export function openCalls(records) {
  const open = new Map();
  for (const r of records) {
    const content = r?.message?.content;
    if (!Array.isArray(content)) continue;
    for (const c of content) {
      if (r.type === 'assistant' && c?.type === 'tool_use' && c.id && !DELEGATES.has(c.name)) {
        const at = Date.parse(r.timestamp ?? '');
        const detail = detailOf(c.input);
        open.set(c.id, {
          toolUseId: c.id, toolName: c.name ?? 'unknown',
          detail: detail === null ? null : detail.slice(0, OPEN_DETAIL_MAX),
          at: Number.isFinite(at) ? at : null,
        });
      } else if (r.type === 'user' && c?.type === 'tool_result' && c.tool_use_id) open.delete(c.tool_use_id);
    }
  }
  return [...open.values()];
}

/** Roll one agent's own transcript into the numbers its node shows. */
async function scanAgent(file, usage = null, agentId = null) {
  const { records } = await readAll(file);
  usage?.add(records, agentId ?? 'agents:unnamed');
  const stats = {
    tools: {}, toolCount: 0, lastTool: null, errors: 0,
    model: null,      // the model its own transcript names: what it actually ran on
    lastText: null,   // the end of the last thing it said, for the line a report closes with
    tokens: null, startedAt: null, endedAt: null, turns: 0,
    owns: [], // tool_use ids this agent emitted — how nesting is resolved
  };

  for (const r of records) {
    if (r?.timestamp) {
      const t = Date.parse(r.timestamp);
      if (Number.isFinite(t)) {
        if (stats.startedAt === null || t < stats.startedAt) stats.startedAt = t;
        if (stats.endedAt === null || t > stats.endedAt) stats.endedAt = t;
      }
    }
    if (r?.type === 'assistant') {
      stats.turns += 1;
      const mdl = r.message?.model;
      if (typeof mdl === 'string' && mdl && mdl !== '<synthetic>') stats.model = mdl;
      const said = textOf(r.message?.content);
      if (said.trim()) stats.lastText = said.slice(-400);
      const u = r.message?.usage;
      if (u && u.cache_read_input_tokens != null) {
        stats.tokens = (u.input_tokens ?? 0) + (u.cache_read_input_tokens ?? 0) + (u.cache_creation_input_tokens ?? 0);
      }
      const content = r.message?.content;
      if (Array.isArray(content)) {
        for (const c of content) {
          if (c?.type !== 'tool_use') continue;
          const n = c.name ?? 'unknown';
          stats.tools[n] = (stats.tools[n] ?? 0) + 1;
          stats.toolCount += 1;
          stats.lastTool = n;
          if (c.id) stats.owns.push(c.id);
        }
      }
    }
    if (r?.type === 'user') {
      const content = r.message?.content;
      if (Array.isArray(content)) {
        for (const c of content) if (c?.type === 'tool_result' && c.is_error === true) stats.errors += 1;
      }
    }
  }

  stats.durationMs = stats.startedAt !== null && stats.endedAt !== null
    ? stats.endedAt - stats.startedAt
    : null;
  stats.midTurn = midTurn(records);
  stats.open = openCalls(records);
  return stats;
}

async function readAgentDir(subagentsDir, usage = null) {
  const out = [];
  // Nested too: a workflow puts its agents under subagents/workflows/<id>/.
  for (const metaPath of await agentMetaFiles(subagentsDir)) {
    const name = path.basename(metaPath);
    const dir = path.dirname(metaPath);
    if (!name.startsWith('agent-')) continue;
    const agentId = name.slice('agent-'.length, -'.meta.json'.length);
    let meta = {};
    try { meta = JSON.parse(await fsp.readFile(metaPath, 'utf8')); } catch { /* keep going */ }

    const jsonl = path.join(dir, `agent-${agentId}.jsonl`);
    let mtime = null;
    try { mtime = (await fsp.stat(jsonl)).mtimeMs; } catch { /* not written yet */ }

    // `stats` needs the transcript read; a missing file is a normal state (the
    // agent has not written yet), so absence is a null rather than a throw.
    let stats = null;
    if (mtime !== null) stats = await scanAgent(jsonl, usage, agentId);

    out.push({
      agentId,
      agentType: meta.agentType ?? null,
      description: meta.description ?? null,
      toolUseId: meta.toolUseId ?? null,
      spawnDepth: typeof meta.spawnDepth === 'number' ? meta.spawnDepth : 1,
      jsonl,
      mtime,
      // A workflow agent belongs to the run that spawned it, not the session
      // root; without this they all hang off the root as one flat fan.
      workflow: dir === subagentsDir ? null : path.basename(dir),
      stats,
    });
  }
  return out;
}

/**
 * Build the graph for one session.
 * `staleMs` decides when an agent with no completion notice is called stale
 * rather than running — an unfinished agent whose file stopped growing is a
 * different fact from one that is working.
 */
/** How long an unfinished agent may stay quiet before it is called stale
 *  rather than running. Exported because index.js's stream signature has to
 *  know the same number: a status that changes on the clock alone has to be
 *  re-asked for while it can still change, and two copies of this window
 *  would drift into a panel that never updates or one that never settles. */
export const STALE_MS = 120000;

export async function buildGraph(session, { staleMs = STALE_MS } = {}) {
  const { records, malformed } = await readAll(session.file);
  const main = scanMain(records);
  // What the session spent, its agents' tokens included and each response counted once.
  linkRetries(main.agentCalls);
  const usage = new Usage().add(records);
  const agents = await readAgentDir(session.subagentsDir, usage);
  const now = Date.now();

  // Ownership: session first, then every agent's own tool_use ids, so a nested
  // agent attaches to its real parent instead of the root.
  const owners = new Map(main.owners);
  for (const a of agents) {
    for (const id of a.stats?.owns ?? []) owners.set(id, a.agentId);
  }

  // toolUseId -> agentId, from the returning result record.
  const byToolUse = new Map();
  for (const [k, v] of main.links) if (!k.startsWith('agent:')) byToolUse.set(k, v);
  const callOf = new Map();
  for (const [k, v] of byToolUse) callOf.set(v.agentId, k);

  const nodes = [{
    id: SESSION_NODE,
    kind: 'session',
    label: session.sessionId.slice(0, 8),
    sessionId: session.sessionId,
    cwd: main.cwd,
    gitBranch: main.gitBranch,
    model: main.model,
    version: main.version,
    status: 'session',
    turns: main.userTurns,
    tokens: contextFill(records),
    startedAt: main.startedAt,
    endedAt: main.updatedAt,
    usage: withTimes(usage, records),
    // Commands sent to the background that no notice has ended, oldest first. A session that is over has none
    // running whatever this says: the page shows them only while the session is live.
    backgroundCommands: [...main.background]
      .filter(([id]) => !main.completions.has(id))
      .map(([id, b]) => ({ id, toolName: 'Bash', detail: main.commands.get(b.toolUseId) ?? null, startedAt: b.startedAt }))
      .sort((x, y) => (x.startedAt ?? 0) - (y.startedAt ?? 0)),
    // The newest call nothing has answered, the session's own or an agent's. Null when every call has its result.
    openCall: [
      ...openCalls(records).map((c) => ({ ...c, agentId: null, agentType: null })),
      ...agents.flatMap((a) => (a.stats?.open ?? []).map((c) => ({ ...c, agentId: a.agentId, agentType: a.agentType ?? null }))),
    ].sort((a, b) => (b.at ?? 0) - (a.at ?? 0))[0] ?? null,
  }];
  const edges = [];

  for (const a of agents) {
    // The call that started it: named by its own meta file, or found from the answer that named the agent.
    const callId = a.toolUseId ?? callOf.get(a.agentId) ?? null;
    const call = callId ? main.agentCalls.get(callId) : null;
    const link = callId ? byToolUse.get(callId) : null;
    const notice = main.completions.get(a.agentId) ?? null;
    const completion = noticeStands(notice, a.stats?.endedAt ?? null) ? notice.status : null;

    // Order matters. A synchronous Agent call never produces a task
    // notification — it reports through toolUseResult.status instead. Reading
    // the notice first and falling back to file freshness labelled 87 of 272
    // finished agents "stale" on this machine; the transcript had said
    // "completed" all along.
    let status;
    if (completion === 'completed') status = 'done';
    else if (completion) status = completion;             // failed / killed / stopped, carried as-is
    else if (link?.status === 'completed') status = 'done';
    else if (a.mtime === null) status = 'starting';
    else if (now - a.mtime < staleMs) status = 'running';
    // "Stale" only means something while the session is still being written:
    // an agent that went quiet under a live session may be stuck. In a session
    // that itself finished long ago, the agent simply ended and no notice was
    // recorded — calling that stale would raise an alarm about history.
    else if (main.updatedAt !== null && main.updatedAt - a.mtime > staleMs) status = 'ended';
    else status = 'stale';

    const parentId = a.toolUseId ? (owners.get(a.toolUseId) ?? SESSION_NODE) : SESSION_NODE;

    nodes.push({
      id: a.agentId,
      kind: 'agent',
      label: a.agentType ?? call?.subagentType ?? 'agent',
      agentType: a.agentType ?? call?.subagentType ?? null,
      description: a.description ?? call?.description ?? null,
      status,
      spawnDepth: a.spawnDepth,
      workflow: a.workflow,
      toolUseId: a.toolUseId,
      // The model it ran on: what its own transcript names, and failing that what the launch answer resolved.
      model: a.stats?.model ?? link?.model ?? null,
      // The model the call asked for; null when the call named none and the agent ran on its default.
      modelAsked: call?.model ?? null,
      // Set when the model gate refused this call the first time it was made: what was asked then, and why not.
      firstTry: call?.firstTry ?? null,
      // `confidence: high|low`, the line a crew agent's report closes with; null when it has none.
      confidence: confidenceOf(a.stats?.lastText ?? null),
      // Its own share of the session's tokens, and what they cost at list price.
      usage: usage.of(a.agentId),
      launchStatus: link?.status ?? null,
      // Started in the background, and its transcript stops in the middle of a turn. Such an agent can be quiet
      // for a long time inside one tool call; whether it is still working is the live session's to say, so the
      // page decides (graph-plan.js `settle`), not this file.
      background: link?.status === 'async_launched',
      midTurn: a.stats?.midTurn ?? false,
      parentId,
      tools: a.stats?.tools ?? {},
      toolCount: a.stats?.toolCount ?? 0,
      lastTool: a.stats?.lastTool ?? null,
      errors: a.stats?.errors ?? 0,
      turns: a.stats?.turns ?? 0,
      tokens: a.stats?.tokens ?? null,
      startedAt: a.stats?.startedAt ?? null,
      endedAt: a.stats?.endedAt ?? null,
      durationMs: a.stats?.durationMs ?? null,
      updatedAt: a.mtime,
      // Where it stands among the agents the session called: its place in the order of the calls, the wave it
      // was called in, and when. Null for an agent the session's own transcript did not call (one a workflow
      // started): nothing is known about its place from here.
      order: call?.order ?? null,
      wave: call?.wave ?? null,
      calledAt: call?.calledAt ?? null,
      // When it handed its result back: the answer to a call the session waited on, or the notice that ended a
      // background agent. Null while it has not, and when no time was recorded.
      reportedAt: link?.status === 'completed' ? (link.at ?? null) : (completion ? (notice.at ?? null) : null),
    });

    edges.push({ id: `${parentId}->${a.agentId}`, source: parentId, target: a.agentId, kind: 'spawn' });
  }

  linkEscalations(nodes);

  // A workflow run is a real container, not a rendering trick: its agents were
  // spawned by one orchestration script, not by the session directly. Hanging
  // 243 of them straight off the root produced a graph nobody could read, and
  // it was also the wrong shape.
  const wfGroups = new Map();
  for (const n of nodes) {
    if (n.kind !== 'agent' || !n.workflow) continue;
    if (!wfGroups.has(n.workflow)) wfGroups.set(n.workflow, []);
    wfGroups.get(n.workflow).push(n);
  }

  for (const [wfId, members] of wfGroups) {
    const id = `wf:${wfId}`;
    const byStatusIn = {};
    let tokens = 0;
    let tools = 0;
    let startedAt = null;
    let endedAt = null;
    for (const m of members) {
      byStatusIn[m.status] = (byStatusIn[m.status] ?? 0) + 1;
      tokens += m.tokens ?? 0;
      tools += m.toolCount ?? 0;
      if (m.startedAt != null) startedAt = startedAt === null ? m.startedAt : Math.min(startedAt, m.startedAt);
      if (m.endedAt != null) endedAt = endedAt === null ? m.endedAt : Math.max(endedAt, m.endedAt);
      m.parentId = id;
      m.spawnDepth = (m.spawnDepth ?? 1) + 1;
    }
    const running = byStatusIn.running ?? 0;

    nodes.push({
      id,
      kind: 'workflow',
      label: 'workflow',
      workflowId: wfId,
      description: `${members.length} agents`,
      status: running ? 'running' : 'done',
      members: members.length,
      byStatus: byStatusIn,
      tokens,
      toolCount: tools,
      startedAt,
      endedAt,
      durationMs: startedAt !== null && endedAt !== null ? endedAt - startedAt : null,
      spawnDepth: 1,
      parentId: SESSION_NODE,
    });
    edges.push({ id: `${SESSION_NODE}->${id}`, source: SESSION_NODE, target: id, kind: 'spawn' });
  }

  // Edges follow the reparenting.
  for (const e of edges) {
    const target = nodes.find((n) => n.id === e.target);
    if (target && target.kind === 'agent' && target.parentId !== e.source) {
      e.source = target.parentId;
      e.id = `${e.source}->${e.target}`;
    }
  }

  const count = (s) => nodes.filter((n) => n.kind === 'agent' && n.status === s).length;
  // Every status is counted, so the parts always add up to the whole. A
  // summary that quietly drops "failed" reads as a clean run.
  const byStatus = {};
  for (const n of nodes) if (n.kind === 'agent') byStatus[n.status] = (byStatus[n.status] ?? 0) + 1;

  return {
    sessionId: session.sessionId,
    cwd: main.cwd,
    gitBranch: main.gitBranch,
    model: main.model,
    version: main.version,
    updatedAt: main.updatedAt,
    contextTokens: contextFill(records),
    nodes,
    edges,
    stats: {
      agents: agents.length,
      workflows: wfGroups.size,
      running: count('running'),
      done: count('done'),
      stale: count('stale'),
      ended: count('ended'),
      failed: count('failed') + count('killed') + count('stopped'),
      byStatus,
      records: records.length,
      malformed,          // surfaced, never swallowed
    },
  };
}

export const _internals = { scanMain, harvestCompletions, SESSION_NODE };

/**
 * One agent's work in full: what it was asked, what it did, what it reported.
 *
 * Deliberately not part of buildGraph — a finished report runs to tens of
 * thousands of characters and the graph is pushed down an SSE stream every
 * time a file changes. This is fetched when someone opens a node.
 */
export async function agentDetail(session, agentId) {
  if (!/^[A-Za-z0-9_-]+$/.test(agentId)) return null;

  // An agent a workflow started lives one directory down (subagents/workflows/<run>/). The graph finds those;
  // looking only at the top level answered "no such agent" for every one of them.
  let file = path.join(session.subagentsDir, `agent-${agentId}.jsonl`);
  try {
    await fsp.stat(file);
  } catch {
    const nested = (await agentMetaFiles(session.subagentsDir)).find((m) => path.basename(m) === `agent-${agentId}.meta.json`);
    if (!nested) return null;
    file = nested.replace(/\.meta\.json$/, '.jsonl');
    try { await fsp.stat(file); } catch { return null; }
  }

  const { records, malformed } = await readAll(file);

  let meta = {};
  try {
    meta = JSON.parse(await fsp.readFile(file.replace(/\.jsonl$/, '.meta.json'), 'utf8'));
  } catch { /* the transcript is still the source of truth */ }

  const timeline = [];
  const texts = [];       // every text block, in order
  let prompt = null;
  let lastThinking = null;
  // The last tool call that came back as an error: which tool, when, and the end of what it said. Null when
  // none did — which is a finding about this transcript, and not the same as the transcript being unread.
  const toolNames = new Map();
  let lastError = null;
  let errors = 0;

  for (const r of records) {
    const at = r?.timestamp ? Date.parse(r.timestamp) : null;

    if (r?.type === 'user' && Array.isArray(r.message?.content)) {
      for (const c of r.message.content) {
        if (c?.type !== 'tool_result' || c.is_error !== true) continue;
        errors += 1;
        const res = toolResult(c);
        lastError = { tool: toolNames.get(c.tool_use_id) ?? null, at, text: res.text, truncated: res.truncated, length: res.length };
      }
    }

    if (r?.type === 'user' && prompt === null) {
      const c = r.message?.content;
      const t = typeof c === 'string' ? c : (Array.isArray(c) ? c.find((x) => x?.type === 'text')?.text : null);
      if (t) prompt = t;
    }

    if (r?.type !== 'assistant') continue;
    const content = r.message?.content;
    if (!Array.isArray(content)) continue;

    for (const c of content) {
      if (c?.type === 'text' && typeof c.text === 'string' && c.text.trim()) {
        texts.push({ at, text: c.text });
      } else if (c?.type === 'thinking' && typeof c.thinking === 'string') {
        lastThinking = c.thinking;
      } else if (c?.type === 'tool_use') {
        // Bash carries a written description; other tools describe themselves
        // through their most identifying input.
        const i = c.input ?? {};
        const label = i.description ?? i.file_path ?? i.pattern ?? i.query ?? i.command ?? i.skill ?? null;
        if (typeof c.id === 'string') toolNames.set(c.id, c.name ?? 'unknown');
        timeline.push({
          at,
          name: c.name ?? 'unknown',
          label: label ? String(label).slice(0, 160) : null,
        });
      }
    }
  }

  // The report is the last text block the agent produced. Earlier blocks are
  // narration between tool calls, which is progress rather than conclusion.
  const report = texts.length ? texts[texts.length - 1].text : null;

  return {
    agentId,
    // Where this agent's transcript is, for whoever wants to open it themselves.
    transcriptPath: file,
    agentType: meta.agentType ?? null,
    description: meta.description ?? null,
    spawnDepth: meta.spawnDepth ?? null,
    prompt,
    report,
    // Kept apart so the UI can show progress for an agent that has not
    // reported yet, without pretending the narration is a conclusion.
    narration: texts.slice(0, -1).map((t) => t.text),
    thinking: lastThinking,
    timeline,
    lastError,
    errors,
    records: records.length,
    malformed,
  };
}


// How much of a tool's output travels to the page. The END is kept: a test run says how it went in its last
// lines, and a build says what broke there.
const RESULT_TAIL_BYTES = 4096;

/** One tool result, cut to its tail, with the cut said. */
export function toolResult(c) {
  const raw = typeof c.content === 'string'
    ? c.content
    : Array.isArray(c.content) ? c.content.filter((x) => x?.type === 'text').map((x) => x.text).join('\n') : '';
  const truncated = raw.length > RESULT_TAIL_BYTES;
  return {
    error: c.is_error === true,
    text: truncated ? raw.slice(-RESULT_TAIL_BYTES) : raw,
    truncated,
    length: raw.length,
  };
}

/**
 * The conversation a transcript holds, as the panel renders conversations.
 *
 * Needed because a resumed session starts a fresh stream: it remembers what was
 * said — it will answer questions about it — but the panel had nothing to draw,
 * so continuing a conversation looked exactly like starting one.
 *
 * Sidechains are skipped: a subagent's exchange belongs to the graph, not to
 * the conversation the person had.
 */
export async function conversation(session, { limit = 400 } = {}) {
  const { records } = await readAll(session.file);
  const out = [];

  // What each tool call came back with, by the call's id. A call with no entry here has not returned, or its
  // result is not in this transcript; the block then carries `result: null`, which is not "it returned nothing".
  const results = new Map();
  for (const r of records) {
    if (r?.isSidechain === true || r?.type !== 'user' || !Array.isArray(r.message?.content)) continue;
    for (const c of r.message.content) {
      if (c?.type === 'tool_result' && typeof c.tool_use_id === 'string') results.set(c.tool_use_id, toolResult(c));
    }
  }

  for (const r of records) {
    if (r?.isSidechain === true) continue;
    if (r?.parent_tool_use_id) continue;
    const at = r?.timestamp ? Date.parse(r.timestamp) : null;

    if (r?.type === 'user') {
      const c = r.message?.content;
      const text = typeof c === 'string'
        ? c
        : Array.isArray(c) ? c.filter((x) => x?.type === 'text').map((x) => x.text).join('') : '';
      // Command envelopes and tool results are machinery, not what was said.
      if (!text.trim()) continue;
      if (/^<(command-name|command-message|local-command|task-notification)/.test(text.trim())) continue;
      out.push({ role: 'user', at, text });
      continue;
    }

    if (r?.type === 'assistant' && Array.isArray(r.message?.content)) {
      const blocks = [];
      for (const c of r.message.content) {
        if (c?.type === 'text' && c.text?.trim()) blocks.push({ kind: 'text', text: c.text });
        else if (c?.type === 'tool_use') {
          const i = c.input ?? {};
          blocks.push({
            kind: 'tool',
            name: c.name ?? 'tool',
            label: i.description ?? i.file_path ?? i.command ?? i.pattern ?? i.query ?? null,
            // The call's own id: what a result, and an agent on the graph, are matched to it by.
            id: typeof c.id === 'string' ? c.id : null,
            // Only a delegation has one. The agent's type is what the card in the conversation is named after.
            subagentType: typeof i.subagent_type === 'string' ? i.subagent_type : null,
            result: (typeof c.id === 'string' ? results.get(c.id) : null) ?? null,
          });
        }
      }
      if (blocks.length) out.push({ role: 'assistant', at, blocks });
    }
  }

  // The tail: a long history is the part nearest the continuation that matters,
  // and the count says what was left out rather than hiding it.
  return {
    measured: true,
    total: out.length,
    truncated: out.length > limit,
    messages: out.slice(-limit),
  };
}
