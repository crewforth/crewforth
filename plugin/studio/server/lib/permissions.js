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
const HARNESS_TIMEOUT_S = 90;
// The longer limit is given to the harness for those two tools alone, on a hook entry of their own: every other
// call keeps the 90 seconds it had.
const ASK_HARNESS_TIMEOUT_S = ASK_WAIT_S + 45;

// The two tools Claude Code offers only when someone can answer them. Their answer is not allow-or-deny: a
// question is answered with the answers, a plan with the mode to go on in.
export const INTERACTIVE = ['AskUserQuestion', 'ExitPlanMode'];
// The modes a plan can be approved into. `plan` is not one (that is "keep planning"), and nothing else exists here.
export const PLAN_MODES = ['acceptEdits', 'default'];
// The name the permission host has to Claude Code, and its one tool's: mcp__<server>__<tool>. The server's name
// carries the session's id, so it cannot be the name of a server the user's own configuration already has, and
// two sessions' hosts are never one name.
export function hostNames(sessionId) {
  const server = `crew_studio_host_${String(sessionId).replace(/[^A-Za-z0-9]/g, '').slice(0, 16)}`;
  return { server, tool: `mcp__${server}__approve` };
}

/**
 * Is this directory ours alone? The spool holds the answers a hook acts on: a file dropped into it is an answer.
 * It sits under the system's temporary directory, which on some systems every user can write to, so a directory
 * of that name is not taken on trust: it must be a real directory (not a link to one), owned by this user, and
 * closed to everyone else. One that is ours and too open is closed; one that is somebody else's is refused.
 * Where the platform has no owner to ask about (Windows), only "a real directory" is asked.
 * @param uid  whose it has to be: this process's user. A parameter so the rule can be asked about another one.
 * @returns null when it is, or the reason it is not
 */
export function spoolProblem(dir, uid = typeof process.getuid === 'function' ? process.getuid() : null) {
  let st;
  try { st = fs.lstatSync(dir); } catch { return 'it does not exist'; }
  if (st.isSymbolicLink()) return 'it is a symbolic link';
  if (!st.isDirectory()) return 'it is not a directory';
  if (uid === null) return null;
  if (st.uid !== uid) return 'it belongs to another user';
  if ((st.mode & 0o077) !== 0) {
    try { fs.chmodSync(dir, 0o700); } catch { return 'it is open to other users and could not be closed'; }
    if ((fs.lstatSync(dir).mode & 0o077) !== 0) return 'it is open to other users and could not be closed';
  }
  return null;
}

/** Make a directory that is ours alone, or say why the one that is there is not. */
function ownDir(dir) {
  try { fs.mkdirSync(dir, { recursive: true, mode: 0o700 }); } catch { /* spoolProblem says what is there */ }
  return spoolProblem(dir);
}

/** The spool of a session, checked each time it is about to be read or written. */
function spoolUsable(sessionId) {
  const spool = spoolFor(sessionId);
  return spoolProblem(ROOT) === null && spoolProblem(spool) === null ? spool : null;
}
const POLL_MS = 250;

// One root per user: on a machine with a shared temp directory, two users' panels do not meet in one directory.
// Where the platform has no user id to ask for (Windows), the temp directory is already the user's own.
const UID = typeof process.getuid === 'function' ? process.getuid() : null;
const ROOT = path.join(os.tmpdir(), UID === null ? 'crew-studio-gate' : `crew-studio-gate-${UID}`);
// Where spools were kept before the root carried the user: swept, never written to.
const OLD_ROOT = path.join(os.tmpdir(), 'crew-studio-gate');

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
  // A spool that is not ours alone is not used: the session starts without a gate, and says so, rather than
  // with one whose answers somebody else can write.
  for (const d of [ROOT, spool, ...['req', 'ans', 'always', 'host'].map((x) => path.join(spool, x))]) {
    const problem = ownDir(d);
    if (problem) { prepare.refused = `${d}: ${problem}`; return null; }
  }
  prepare.refused = null;
  // Whose spool this is: the server that made it. A later start reads this to tell a spool that was left behind
  // (see `sweep`) from one a running server is still using.
  try { fs.writeFileSync(path.join(spool, OWNER), `${process.pid}\n`, { mode: 0o600 }); } catch { /* swept by age instead */ }
  // The mode an allowance in the panel is said out loud in. It starts as the mode the session starts in, and
  // changes only when the viewer approves a plan into another one (see `decide`).
  writeMode(spool, mode);

  const settingsPath = path.join(spool, 'settings.json');
  const ask = (role) => `CREW_GATE_WAIT=${HOOK_WAIT_S} CREW_GATE_WAIT_ASK=${ASK_WAIT_S} CREW_GATE_ROLE=${role} ${gateMode(mode)}bash ${JSON.stringify(HOOK)} ${JSON.stringify(spool)}`;
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
          // `general`: it answers every tool but the two below, and for those two it says nothing and leaves at
          // once, so it is never held past this entry's limit.
          command: ask('general'),
          timeout: HARNESS_TIMEOUT_S,
        }],
      }, {
        // The two tools that wait for a person to read something: the same hook, with the longer limit that only
        // they need. If this entry did not fire for them, nothing would answer them and the permission host
        // would deny them: the failure is a refusal.
        matcher: INTERACTIVE.join('|'),
        hooks: [{ type: 'command', shell: 'bash', command: ask('ask'), timeout: ASK_HARNESS_TIMEOUT_S }],
      }],
    },
  };
  fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2));

  // The permission host: what makes Claude Code offer AskUserQuestion and ExitPlanMode in this session at all. It
  // denies whatever reaches it (hooks/studio-host.mjs says why). Without the file the session starts as it did
  // before there was one: the two tools are not offered, and nothing else changes.
  let host = null;
  if (fs.existsSync(HOST)) {
    const names = hostNames(sessionId);
    const mcpPath = path.join(spool, 'mcp.json');
    fs.writeFileSync(mcpPath, JSON.stringify({ mcpServers: { [names.server]: { command: process.execPath, args: [HOST, spool] } } }, null, 2));
    host = { mcpPath, tool: names.tool, server: names.server };
  }
  return { settingsPath, spool, waitSeconds: HOOK_WAIT_S, askWaitSeconds: ASK_WAIT_S, host };
}

/** Record the mode the hook may approve in. A word that is not one of the session's modes is not written. */
export function writeMode(spool, mode) {
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
  const spool = spoolUsable(sessionId);
  if (!spool) return [];
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

const QUESTIONS_MAX = 8;      // the tool takes one to four questions; twice that is refused as not a question
const ANSWER_MAX = 2000;      // one answer's length; a question's options are short, free text may not be

/**
 * The answers to a question, checked: one per question of the request, keyed by the question's own text, each a
 * string or (for a question that takes several) a list of strings. Returns null when what was sent is not that.
 */
export function cleanAnswers(questions, answers) {
  if (!Array.isArray(questions) || questions.length > QUESTIONS_MAX || !answers || typeof answers !== 'object' || Array.isArray(answers)) return null;
  // No prototype: a question whose text is `__proto__` or `constructor` is a key like any other, and nothing
  // an answer is called can reach an inherited one.
  const out = Object.create(null);
  const seen = new Set();
  for (const q of questions) {
    const key = q?.question;
    if (typeof key !== 'string' || seen.has(key) || !Object.hasOwn(answers, key)) return null;
    seen.add(key);
    const v = answers[key];
    const ok = (x) => typeof x === 'string' && x.trim() !== '' && x.length <= ANSWER_MAX;
    // Several answers only to a question that takes several, and no more of them than it has options plus the
    // viewer's own one.
    const most = (Array.isArray(q.options) ? q.options.length : 0) + 1;
    if (Array.isArray(v) ? !(q.multiSelect === true && v.length > 0 && v.length <= most && v.every(ok)) : !ok(v)) return null;
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

  const spool = spoolUsable(sessionId);
  if (!spool) return { ok: false, reason: 'the gate\'s spool is not a directory of this user\'s alone' };
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

const OWNER = 'owner';
const STALE_MS = 24 * 60 * 60 * 1000;

/** Is a process with this id running? One that exists and is somebody else's counts: it is not ours to judge. */
function pidAlive(pid) {
  try { process.kill(pid, 0); return true; } catch (e) { return e?.code === 'EPERM'; }
}

/** The latest change time of a directory and of what is in it, two levels down: a spool is no deeper. Links are not followed. */
function newest(dir, seen, depth = 2) {
  let at = seen;
  let names;
  try { names = fs.readdirSync(dir); } catch { return at; }
  for (const n of names) {
    let st;
    try { st = fs.lstatSync(path.join(dir, n)); } catch { continue; }
    if (st.mtimeMs > at) at = st.mtimeMs;
    if (depth > 1 && st.isDirectory()) at = newest(path.join(dir, n), at, depth - 1);
  }
  return at;
}

/** What `sweep` is run on when a server starts: this user's root, and the one from before roots carried the user. */
export function sweepLeft(opts = {}) {
  return [...sweep({ ...opts, root: ROOT }), ...(OLD_ROOT === ROOT ? [] : sweep({ ...opts, root: OLD_ROOT }))];
}

/**
 * Remove the spools a server left behind.
 *
 * A session's spool goes when the session exits (`cleanup`). A server that is killed never sees that exit, and on
 * Windows a kill runs no handler at all, so its spools stay under the temp directory: settings, the mode, and
 * whatever was waiting. This is run when a server starts.
 *
 * What is removed, and nothing else: a real directory (not a link) directly under the root, named like a session
 * id, that is this user's alone, and whose owner — the server that made it — is no longer running. A spool with
 * no owner written (made by a version before this) goes once it has not been touched for a day. A spool whose
 * owner is running is another panel's, or this one's, and is left.
 *
 * @returns the names removed
 */
export function sweep({ root = ROOT, alive = pidAlive, self = process.pid, now = Date.now(), staleMs = STALE_MS } = {}) {
  const gone = [];
  if (spoolProblem(root) !== null) return gone;
  let names;
  try { names = fs.readdirSync(root); } catch { return gone; }
  for (const name of names) {
    if (!/^[A-Za-z0-9_-]+$/.test(name)) continue;
    const dir = path.join(root, name);
    let st;
    try { st = fs.lstatSync(dir); } catch { continue; }
    if (!st.isDirectory() || spoolProblem(dir) !== null) continue;
    let pid = null;
    try { pid = Number.parseInt(fs.readFileSync(path.join(dir, OWNER), 'utf8'), 10); } catch { /* no owner written */ }
    // With no owner to ask, age decides, and the age is the newest thing in the spool: a hook that wrote a request
    // a minute ago touched a file two levels down, not the directory at the top.
    const left = Number.isInteger(pid) && pid > 0 ? pid !== self && !alive(pid) : now - newest(dir, st.mtimeMs) > staleMs;
    if (!left) continue;
    try { fs.rmSync(dir, { recursive: true, force: true }); gone.push(name); } catch { /* still there; the next start tries again */ }
  }
  return gone;
}

export const _internals = { HOOK, HOST, HOOK_WAIT_S, ASK_WAIT_S, HARNESS_TIMEOUT_S, ASK_HARNESS_TIMEOUT_S, ROOT, OLD_ROOT, UID };
