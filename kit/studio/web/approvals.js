// What is waiting for the viewer, and how long it has left.
//
// A session started here asks before every tool call: a hook parks the call, the panel shows it, and the hook's
// exit code carries the answer. Nobody answering is an answer too — the hook denies on its own when its wait runs
// out. This file works out what the dock shows from what the server sends; it touches no page.
//
// Every number here is the server's. How long the hook waits (`gateWaitSeconds`), when a request was asked
// (`askedAt`) and what time it is now (`now`) all come from the machine the hook runs on, so a viewer whose clock
// differs — a browser on the far end of a tunnel — still counts down to the moment the hook will really give up.
import { roleName } from './names.js';

/** The server's clock, as seen from this page: the difference is measured each time the server says what time it is. */
export class ServerClock {
  constructor() { this.offset = 0; this.synced = false; }

  /** @param serverNow the server's `now` · @param localNow this page's clock when it arrived */
  sync(serverNow, localNow) {
    if (typeof serverNow !== 'number' || !Number.isFinite(serverNow)) return;
    this.offset = serverNow - localNow;
    this.synced = true;
  }

  now(localNow) { return localNow + this.offset; }
}

// A plan is approved into one of these; the words are the buttons'.
export const PLAN_CHOICES = [
  { mode: 'acceptEdits', label: 'Approve \u00b7 accept edits', title: 'Approve the plan and go on in acceptEdits: file edits in the project are accepted without asking; every call is still shown here first.' },
  { mode: 'default', label: 'Approve \u00b7 ask each time', title: 'Approve the plan and go on in default: each call is asked about here.' },
];

/**
 * What a request asks of the viewer when the answer is not allow-or-deny.
 *   { kind: 'questions', questions: [{ question, header, options: [{ label, description }], multiSelect }] }
 *   { kind: 'plan', plan }
 * Null for an ordinary tool call. Only what the tool's own input holds; nothing is added to it.
 */
export function askOf(r) {
  const input = r?.input && typeof r.input === 'object' ? r.input : {};
  if (r?.toolName === 'AskUserQuestion' && Array.isArray(input.questions)) {
    return {
      kind: 'questions',
      questions: input.questions.filter((q) => typeof q?.question === 'string').map((q) => ({
        question: q.question,
        header: typeof q.header === 'string' ? q.header : '',
        multiSelect: q.multiSelect === true,
        options: (Array.isArray(q.options) ? q.options : []).filter((o) => typeof o?.label === 'string')
          .map((o) => ({ label: o.label, description: typeof o.description === 'string' ? o.description : '' })),
      })),
    };
  }
  if (r?.toolName === 'ExitPlanMode') return { kind: 'plan', plan: typeof input.plan === 'string' ? input.plan : '' };
  return null;
}

/**
 * The answers a form holds, as the tool takes them: question text -> the chosen label, a list of labels for a
 * question that takes several, or the viewer's own text. Null while any question has no answer.
 * @param picked Map question -> Set of labels · @param typed Map question -> free text
 */
export function answersOf(ask, picked, typed) {
  const out = {};
  for (const q of ask?.questions ?? []) {
    const own = (typed?.get(q.question) ?? '').trim();
    const labels = [...(picked?.get(q.question) ?? [])];
    if (own && !q.multiSelect) out[q.question] = own;
    else if (q.multiSelect && (labels.length || own)) out[q.question] = own ? [...labels, own] : labels;
    else if (!q.multiSelect && labels.length) out[q.question] = labels[0];
    else return null;
  }
  return out;
}

/**
 * Every request waiting in every session started here, oldest first: that is the order they will time out in.
 *
 * @param sessions the session summaries of /api/owned
 * @param nameOf   sessionId -> what the navigator calls that session
 */
export function queue(sessions, nameOf = () => null) {
  const out = [];
  for (const s of sessions ?? []) {
    if (!s?.gated) continue;
    for (const r of s.pendingPermissions ?? []) {
      out.push({
        key: `${s.sessionId}/${r.toolUseId}`,
        sessionId: s.sessionId,
        sessionName: nameOf(s.sessionId) ?? String(s.sessionId).slice(0, 8),
        toolUseId: r.toolUseId,
        toolName: r.toolName ?? 'unknown',
        detail: r.detail == null ? null : String(r.detail),
        agentId: r.agentId ?? null,
        agentType: r.agentType ?? null,
        askedAt: r.askedAt,
        // Null when the server did not say. The dock then shows no countdown rather than one it made up.
        waitSeconds: typeof r.waitSeconds === 'number' && r.waitSeconds > 0 ? r.waitSeconds
          : (typeof s.gateWaitSeconds === 'number' && s.gateWaitSeconds > 0 ? s.gateWaitSeconds : null),
        // What a question asks and what a plan says: the two requests that are not answered with allow or deny.
        ask: askOf(r),
      });
    }
  }
  return out.sort((a, b) => (a.askedAt ?? 0) - (b.askedAt ?? 0) || a.key.localeCompare(b.key));
}

/**
 * How long one request has before the hook denies it.
 * @returns { known, left, fraction, expired } — `left` in whole seconds, rounded up, so it reads 1 until it is over.
 */
export function remaining(item, serverNowMs) {
  if (!item || item.waitSeconds == null || typeof item.askedAt !== 'number') {
    return { known: false, left: null, fraction: null, expired: false };
  }
  const total = item.waitSeconds * 1000;
  const ms = item.askedAt + total - serverNowMs;
  return {
    known: true,
    left: Math.max(0, Math.ceil(ms / 1000)),
    fraction: Math.min(1, Math.max(0, ms / total)),
    expired: ms <= 0,
  };
}

/** Who asked, in the words the dock uses. A call from the session itself has no agent, and says so. */
/**
 * A session started in a terminal that is waiting for its user there. Studio cannot answer for it: the question
 * is Claude Code's own prompt, in that terminal, and no hook of the panel's is in that session.
 *
 * @param status   the session's state as the machine reports it (nav.js `sessionStatus`)
 * @param session  the graph's session node, whose `openCall` is the newest call with no result
 * @param ownedHere true when the panel started this session: its requests are in the dock instead
 * @returns null, or { text, what } — `what` is the tool and its command when the transcript has them, and
 *          otherwise what the CLI itself says it waits for; nothing is made up when neither is there.
 */
export function terminalWait(status, session, ownedHere) {
  if (ownedHere || status?.key !== 'waiting') return null;
  const call = session?.openCall ?? null;
  const who = call?.agentType ? `${roleName(call.agentType)} · ` : '';
  const what = call ? `${who}${call.toolName}${call.detail ? ` · ${call.detail}` : ''}` : (status.waitingFor ?? null);
  return { text: 'Waiting for an answer in the terminal', what };
}

export function asker(item) {
  return item.agentType ? roleName(item.agentType) : 'Session';
}

export const VERDICTS = {
  allow: { label: 'Allow once', said: 'Allowed' },
  always: { label: null, said: 'Allowed for this session' },
  deny: { label: 'Deny', said: 'Denied' },
};

/** "Allow Bash this session": the button names the tool it widens the gate for. */
export function allowSessionLabel(toolName) {
  return `Allow ${toolName} this session`;
}

/**
 * What became of the requests that were waiting and no longer are.
 *
 * A request leaves the queue when the hook got its answer — from this page, from another one, or from its own
 * clock. Only the last is a timeout, and it is told apart by the clock: the request vanished at or after the
 * moment the hook was going to give up, and nobody here answered it.
 *
 * @param before   the queue as it was
 * @param after    the queue as it is
 * @param decided  Map key -> verdict this page sent
 * @param serverNowMs
 * @param slackMs  how early a disappearance still counts as the hook's own deadline (it polls; so does the panel)
 */
export function settled(before, after, decided, serverNowMs, slackMs = 2500) {
  const still = new Set((after ?? []).map((r) => r.key));
  const out = [];
  for (const r of before ?? []) {
    if (still.has(r.key)) continue;
    const verdict = decided?.get(r.key) ?? null;
    let outcome;
    if (verdict === 'deny') outcome = 'denied';
    else if (verdict === 'allow' || verdict === 'answer' || verdict === 'plan') outcome = 'allowed';
    else if (verdict === 'always') outcome = 'allowed-session';
    else if (r.waitSeconds != null && serverNowMs >= r.askedAt + r.waitSeconds * 1000 - slackMs) outcome = 'timed-out';
    else outcome = 'answered-elsewhere';
    out.push({ ...r, outcome, at: serverNowMs });
  }
  return out;
}

export const OUTCOME_WORD = {
  allowed: 'Allowed',
  'allowed-session': 'Allowed for this session',
  denied: 'Denied',
  'timed-out': 'Timed out — denied',
  'answered-elsewhere': 'Answered elsewhere',
};
