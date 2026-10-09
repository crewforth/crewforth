// The permission bridge.
//
// A PreToolUse hook injected through --settings parks each tool call, writes a
// request into a spool, and waits for an answer file. The panel reads the spool
// and writes the answer. The hook's exit code carries the decision: 0 allows,
// 2 blocks.
//
// Why not simply let the hook time out on a "no": measured on this machine, a
// hook killed at its configured timeout emits nothing and the tool PROCEEDS —
// permission_denials came back 0 and the command ran. So the hook decides for
// itself well inside that limit, and a hook the harness never has to kill fails
// closed. The panel being shut is a denial, not an opening.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const HOOK = path.resolve(HERE, '..', 'hooks', 'studio-gate.sh');
const HOST = path.resolve(HERE, '..', 'hooks', 'studio-host.mjs');

// The hook answers at HOOK_WAIT; the harness is told a larger number, so the
// two never race and the harness has nothing to kill.
const HOOK_WAIT_S = 45;
// A question to the viewer, and a plan to read, are not a yes-or-no on one command: they get longer. The hook still
// answers by itself, with a denial, when this runs out.
const ASK_WAIT_S = 300;
const HARNESS_TIMEOUT_S = ASK_WAIT_S + 45;

// The two tools Claude Code offers only when someone can answer them. Their answer is not allow-or-deny: a
// question is answered with the answers, a plan with the mode to go on in.
export const INTERACTIVE = ['AskUserQuestion', 'ExitPlanMode'];
// The modes a plan can be approved into. `plan` is not one (that is "keep planning"), and nothing else exists here.
export const PLAN_MODES = ['acceptEdits', 'default'];
// The name the permission host's one tool has to Claude Code: mcp__<server>__<tool>.
const HOST_SERVER = 'crew_studio_host';
export const HOST_TOOL = `mcp__${HOST_SERVER}__approve`;
const POLL_MS = 250;

const ROOT = path.join(os.tmpdir(), 'crew-studio-gate');

export function spoolFor(sessionId) {
  if (!/^[A-Za-z0-9_-]+$/.test(sessionId)) throw new Error('bad session id');
  return path.join(ROOT, sessionId);
}

/**
 * Write the settings file a session is spawned with.
 *
 * It is the panel's own file in the panel's own directory: the user's settings
 * are never read, written, or merged. Returns null when the hook is missing, so
 * the caller can say "no gate" instead of quietly running without one.
 */
export function prepare(sessionId, mode = null) {
  if (!fs.existsSync(HOOK)) return null;

  const spool = spoolFor(sessionId);
  for (const d of ['req', 'ans', 'always', 'host']) fs.mkdirSync(path.join(spool, d), { recursive: true });
  // The mode an allowance in the panel is said out loud in. It starts as the mode the session starts in, and
  // changes only when the viewer approves a plan into another one (see `decide`).
  writeMode(spool, mode);

  const settingsPath = path.join(spool, 'settings.json');
  const settings = {
    hooks: {
      PreToolUse: [{
        // Every tool, not a chosen few: the panel cannot claim to gate a session
        // while quietly exempting whichever tool it forgot to list.
        matcher: '*',
        hooks: [{
          type: 'command',
          // Named, not left to the default: on Windows without a detected Git Bash, Claude Code runs a hook through
          // PowerShell, which cannot read the VAR=… prefix — the gate would fail open.
          shell: 'bash',
          // The mode goes to the hook so that an allowance given in the panel can be an approval the harness
          // honours — in the modes that may write, and never in plan. A mode that is not a plain word is not
          // passed at all, and the hook then approves nothing.
          command: `CREW_GATE_WAIT=${HOOK_WAIT_S} CREW_GATE_WAIT_ASK=${ASK_WAIT_S} ${gateMode(mode)}bash ${JSON.stringify(HOOK)} ${JSON.stringify(spool)}`,
          timeout: HARNESS_TIMEOUT_S,
        }],
      }],
    },
  };
  fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2));

  // The permission host: what makes Claude Code offer AskUserQuestion and ExitPlanMode in this session at all. It
  // denies whatever reaches it (hooks/studio-host.mjs says why). Without the file the session starts as it did
  // before there was one: the two tools are not offered, and nothing else changes.
  let host = null;
  if (fs.existsSync(HOST)) {
    const mcpPath = path.join(spool, 'mcp.json');
    fs.writeFileSync(mcpPath, JSON.stringify({ mcpServers: { [HOST_SERVER]: { command: process.execPath, args: [HOST, spool] } } }, null, 2));
    host = { mcpPath, tool: HOST_TOOL };
  }
  return { settingsPath, spool, waitSeconds: HOOK_WAIT_S, askWaitSeconds: ASK_WAIT_S, host };
}

/** Record the mode the hook may approve in. A word that is not one of the session's modes is not written. */
function writeMode(spool, mode) {
  const file = path.join(spool, 'mode');
  try {
    if (typeof mode === 'string' && /^[A-Za-z]+$/.test(mode)) fs.writeFileSync(file, `${mode}\n`);
    else fs.rmSync(file, { force: true });
  } catch { /* the hook then approves nothing, which is the safe side */ }
}

function gateMode(mode) {
  return typeof mode === 'string' && /^[A-Za-z]+$/.test(mode) ? `CREW_GATE_MODE=${mode} ` : '';
}

/**
 * The most identifying field each tool has. Showing "Bash" alone would ask someone to approve a command they
 * cannot see.
 */
export function detailOf(input) {
  const i = input && typeof input === 'object' ? input : {};
  const d = i.command ?? i.file_path ?? i.pattern ?? i.query ?? i.description ?? null;
  return typeof d === 'string' ? d : null;
}

/** One pending request, as the panel needs to show it. */
function readRequest(spool, file) {
  const toolUseId = file.replace(/\.json$/, '');
  let raw;
  try { raw = fs.readFileSync(path.join(spool, 'req', file), 'utf8'); } catch { return null; }

  let payload = {};
  try { payload = JSON.parse(raw); } catch { /* the hook writes it verbatim; keep going */ }

  const input = payload.tool_input ?? {};
  return {
    toolUseId,
    toolName: payload.tool_name ?? 'unknown',
    detail: detailOf(input),
    input,
    cwd: payload.cwd ?? null,
    // Who asked. Claude Code puts these in the hook's input only when the call comes from inside a subagent, so
    // their absence means the session itself asked — it is not a missing answer.
    agentId: typeof payload.agent_id === 'string' && /^[A-Za-z0-9_-]+$/.test(payload.agent_id) ? payload.agent_id : null,
    agentType: typeof payload.agent_type === 'string' ? payload.agent_type.slice(0, 120) : null,
    // How long this one waits before the hook denies it: longer for a question and for a plan.
    waitSeconds: INTERACTIVE.includes(payload.tool_name) ? ASK_WAIT_S : HOOK_WAIT_S,
    askedAt: (() => {
      try { return fs.statSync(path.join(spool, 'req', file)).mtimeMs; } catch { return Date.now(); }
    })(),
  };
}

export function pending(sessionId) {
  const spool = spoolFor(sessionId);
  let files;
  try { files = fs.readdirSync(path.join(spool, 'req')); } catch { return []; }
  return files
    .filter((f) => f.endsWith('.json'))
    .map((f) => readRequest(spool, f))
    .filter(Boolean)
    .sort((a, b) => a.askedAt - b.askedAt);
}

export function alwaysList(sessionId) {
  try { return fs.readdirSync(path.join(spoolFor(sessionId), 'always')); } catch { return []; }
}

const ANSWER_MAX = 2000;      // one answer's length; a question's options are short, free text may not be

/**
 * The answers to a question, checked: one per question of the request, keyed by the question's own text, each a
 * string or (for a question that takes several) a list of strings. Returns null when what was sent is not that.
 */
export function cleanAnswers(questions, answers) {
  if (!Array.isArray(questions) || !answers || typeof answers !== 'object') return null;
  const out = {};
  for (const q of questions) {
    const key = q?.question;
    if (typeof key !== 'string' || !Object.hasOwn(answers, key)) return null;
    const v = answers[key];
    const ok = (x) => typeof x === 'string' && x.trim() !== '' && x.length <= ANSWER_MAX;
    if (Array.isArray(v) ? !(q.multiSelect === true && v.length > 0 && v.every(ok)) : !ok(v)) return null;
    out[key] = v;
  }
  return out;
}

const hookAllow = (updatedInput) => JSON.stringify({
  hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'allow', permissionDecisionReason: 'answered in Crewforth Studio', updatedInput },
});

/**
 * Answer one request.
 *
 *   allow | deny | always   an ordinary tool call. `always` also allows that tool for the rest of the session,
 *                           which is the user widening their own gate deliberately — it is scoped to one session
 *                           and disappears with it.
 *   answer                  AskUserQuestion: `extra.answers` are the viewer's answers. The hook hands them to
 *                           Claude Code as the tool's input, which is how the hooks reference says a hook answers it.
 *   plan                    ExitPlanMode: the plan is approved, to go on in `extra.mode` — `default` (the hook
 *                           approves it; that is where Claude Code lands) or `acceptEdits` (the hook stays silent
 *                           and the permission host approves it with the change of mode, which only it can make).
 *
 * The two interactive tools take only their own verdict or `deny`: a bare allow does not answer them, and neither
 * may be allowed "for the session". No other tool takes `answer` or `plan`.
 */
export function decide(sessionId, toolUseId, verdict, extra = {}) {
  if (!/^[A-Za-z0-9_-]+$/.test(toolUseId)) return { ok: false, reason: 'bad tool use id' };
  if (!['allow', 'deny', 'always', 'answer', 'plan'].includes(verdict)) return { ok: false, reason: `unknown verdict: ${verdict}` };

  const spool = spoolFor(sessionId);
  const req = pending(sessionId).find((r) => r.toolUseId === toolUseId);
  const tool = req?.toolName ?? null;
  const own = { AskUserQuestion: 'answer', ExitPlanMode: 'plan' }[tool] ?? null;
  if (verdict === 'answer' || verdict === 'plan') {
    if (!req) return { ok: false, reason: 'no such request is waiting' };
    if (own !== verdict) return { ok: false, reason: `${tool} is not answered with "${verdict}"` };
  } else if (own && verdict !== 'deny') {
    return { ok: false, reason: `${tool} is answered with "${own}" or denied, not with "${verdict}"` };
  }

  let line = `${verdict}\n`;
  let mode = null;
  if (verdict === 'answer') {
    const answers = cleanAnswers(req.input?.questions, extra?.answers);
    if (!answers) return { ok: false, reason: 'the answers do not match the questions' };
    // Verdict on the first line, the hook's whole output on the second: the hook prints it and does nothing else.
    line = `output\n${hookAllow({ questions: req.input.questions, answers })}\n`;
  } else if (verdict === 'plan') {
    mode = extra?.mode;
    if (!PLAN_MODES.includes(mode)) return { ok: false, reason: `a plan is approved into ${PLAN_MODES.join(' or ')}` };
    try {
      if (mode === 'default') {
        line = `output\n${hookAllow(req.input ?? {})}\n`;
      } else {
        // Only the permission host can change the mode: the hook says nothing, and the host answers from this.
        fs.writeFileSync(path.join(spool, 'host', `${toolUseId}.json`), JSON.stringify({ mode }));
        line = 'host\n';
      }
      writeMode(spool, mode);
    } catch (e) {
      return { ok: false, reason: String(e?.message ?? e) };
    }
  }

  if (verdict === 'always') {
    if (tool && /^[A-Za-z0-9_-]+$/.test(tool)) {
      try { fs.writeFileSync(path.join(spool, 'always', tool), ''); } catch { /* best effort */ }
    }
  }

  try {
    fs.writeFileSync(path.join(spool, 'ans', toolUseId), line);
  } catch (e) {
    return { ok: false, reason: String(e?.message ?? e) };
  }
  return { ok: true, verdict, toolName: tool, mode };
}

/**
 * Take back an "allow this tool for the session". The hook looks for the tool's file on every call, so the next
 * call of that tool is asked about again. Returns whether there was anything to take back.
 */
export function revoke(sessionId, tool) {
  if (typeof tool !== 'string' || !/^[A-Za-z0-9_-]+$/.test(tool)) return { ok: false, reason: 'bad tool name' };
  const file = path.join(spoolFor(sessionId), 'always', tool);
  try {
    fs.rmSync(file);
    return { ok: true, tool, revoked: true };
  } catch (e) {
    if (e?.code === 'ENOENT') return { ok: true, tool, revoked: false };
    return { ok: false, reason: String(e?.message ?? e) };
  }
}

// How many answered requests a session remembers. In memory only: a server that restarts starts the record
// again, and the page says from when the record runs.
export const APPROVAL_LOG_MAX = 200;
// A request that vanished this close to the hook's own deadline, with no answer recorded, timed out. The hook
// polls and so does the watcher; this is their combined slack.
const TIMEOUT_SLACK_MS = 2500;
const VERDICT_OUTCOME = { allow: 'allowed', always: 'allowed-session', deny: 'denied', answer: 'allowed', plan: 'allowed' };

/**
 * Fold the requests waiting now into a session's record of approvals.
 *
 * A request not seen before is opened with the moment it was asked. One that was open and is no longer waiting
 * is closed with the moment that was noticed and with what became of it: the answer the panel recorded, a
 * timeout if nobody answered and the hook's deadline had come, and otherwise "unanswered" — the hook went away
 * without one, as it does when the session is stopped. Nothing is guessed into an answer.
 *
 * @param log        the record so far, oldest first; changed in place and returned
 * @param pending    what `pending()` returns now
 * @param decisions  Map toolUseId -> verdict the panel recorded
 */
export function logApprovals(log, pending, decisions, now, waitSeconds) {
  const waiting = new Set(pending.map((r) => r.toolUseId));
  const open = new Set(log.filter((e) => e.endedAt === null).map((e) => e.toolUseId));
  for (const e of log) {
    if (e.endedAt !== null || waiting.has(e.toolUseId)) continue;
    e.endedAt = now;
    const verdict = decisions?.get(e.toolUseId);
    if (verdict && VERDICT_OUTCOME[verdict]) e.outcome = VERDICT_OUTCOME[verdict];
    else if (typeof (e.waitSeconds ?? waitSeconds) === 'number' && now >= e.askedAt + (e.waitSeconds ?? waitSeconds) * 1000 - TIMEOUT_SLACK_MS) e.outcome = 'timed-out';
    else e.outcome = 'unanswered';
    decisions?.delete(e.toolUseId);
  }
  for (const r of pending) {
    if (open.has(r.toolUseId)) continue;
    log.push({
      toolUseId: r.toolUseId, toolName: r.toolName, agentId: r.agentId ?? null, agentType: r.agentType ?? null,
      askedAt: r.askedAt, endedAt: null, outcome: null,
      // A question and a plan wait longer than a command; each entry times out on its own clock.
      waitSeconds: r.waitSeconds ?? null,
    });
  }
  // The oldest closed entries go first; a request still waiting is never dropped.
  while (log.length > APPROVAL_LOG_MAX) {
    const i = log.findIndex((e) => e.endedAt !== null);
    if (i === -1) break;
    log.splice(i, 1);
  }
  return log;
}

/** Watch a session's spool and call back whenever the pending set changes. */
export function watch(sessionId, onChange) {
  let last = '';
  const tick = () => {
    const now = pending(sessionId);
    const sig = now.map((r) => r.toolUseId).join(',');
    if (sig !== last) { last = sig; onChange(now); }
  };
  tick();
  const timer = setInterval(tick, POLL_MS);
  return () => clearInterval(timer);
}

export function cleanup(sessionId) {
  try { fs.rmSync(spoolFor(sessionId), { recursive: true, force: true }); } catch { /* already gone */ }
}

export const _internals = { HOOK, HOST, HOOK_WAIT_S, ASK_WAIT_S, HARNESS_TIMEOUT_S, ROOT };
