// What the top bar and the navigator say, kept apart from where they draw it.
//
// Everything here is a function of the data the server sent. None of it touches the page, so each rule can be
// asserted on its own: which word a status gets, what a version badge offers to copy, what a row is called when
// the transcript carried no title. The drawing is in app.js.
//
// One rule runs through it, the panel's own: a value that was not read is never written as if it had been. A
// status nobody recognises keeps its own word and gets no colour; a branch that could not be read leaves the line
// without one; a project that cannot be told to update by a command gets a hint instead of a command.

import { t } from './i18n.js';

/* ------------------------------------------------------------- status --- */

// The words the design uses, and the token each is drawn in. `tone` names a status-* token; null is the hollow
// ring of something that is over.
const AGENT_STATUS = {
  running: { word: t('running'), tone: 'busy' },
  starting: { word: t('starting'), tone: 'busy' },
  done: { word: t('done'), tone: 'good' },
  failed: { word: t('failed'), tone: 'fail' },
  killed: { word: t('killed'), tone: 'fail' },
  stopped: { word: t('stopped'), tone: 'fail' },
  stale: { word: t('stale'), tone: 'idle' },
  ended: { word: t('ended'), tone: null },
};
const CHIP_ORDER = ['running', 'starting', 'stale', 'done', 'failed', 'killed', 'stopped', 'ended'];

/** The word and the tone one agent status is drawn in. A status this table does not know keeps its own word. */
export function agentStatus(status) {
  const known = AGENT_STATUS[status];
  return known
    ? { word: known.word, tone: known.tone, known: true }
    : { word: String(status ?? t('unknown')), tone: null, known: false };
}

/**
 * One chip per status that has at least one agent, so the chips add up to the total. A status this table does
 * not know is still a chip: its own word, no colour, `known: false`.
 */
export function summaryChips(byStatus) {
  const entries = Object.entries(byStatus ?? {}).filter(([, n]) => n > 0);
  const rank = (k) => { const i = CHIP_ORDER.indexOf(k); return i === -1 ? CHIP_ORDER.length : i; };
  entries.sort((a, b) => rank(a[0]) - rank(b[0]) || a[0].localeCompare(b[0]));
  return entries.map(([status, count]) => {
    const known = AGENT_STATUS[status];
    return {
      status,
      count,
      known: Boolean(known),
      tone: known ? known.tone : null,
      text: `${count} ${known ? known.word : status}`,
    };
  });
}

// A session, as the machine reports it. `claude agents` knows three states; a session it does not list is not
// running anywhere on this machine.
const SESSION_STATUS = {
  busy: { word: t('Running'), tone: 'busy' },
  waiting: { word: t('Needs you'), tone: 'waiting' },
  idle: { word: t('Idle'), tone: 'idle' },
};

// A session that says it is working or waiting, and has written nothing for this long, is drawn as quiet: still
// open, no longer counted as live work or as needing the viewer. Measured on this machine: sessions doing work wrote
// within a minute; the one listed as "waiting · permission prompt" for a window that was gone had been silent for
// 1124 minutes. A tool call can run ten minutes without a line (the Bash tool's longest timeout), so an hour is six
// times that and still far from the case it exists for.
export const QUIET_AFTER_MS = 60 * 60 * 1000;

/** "45m", "18h", "3d" — a quiet stretch, coarse on purpose. */
export function span(ms) {
  const m = Math.max(0, Math.floor(ms / 60000));
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  return h < 48 ? `${h}h` : `${Math.floor(h / 24)}d`;
}

/**
 * One fleet row's status, read against `now` (the server's clock: the row's activity clock is that machine's).
 * A row with no activity clock, or no clock to read it against, keeps what the machine said: not read is not quiet.
 */
export function rowStatus(row, now = null) {
  const known = SESSION_STATUS[row.status];
  if (!known) return { key: String(row.status), word: String(row.status), tone: null, known: false };
  const quietFor = typeof now === 'number' && typeof row.activityAt === 'number' ? now - row.activityAt : null;
  if ((row.status === 'busy' || row.status === 'waiting') && quietFor !== null && quietFor > QUIET_AFTER_MS) {
    return {
      key: 'quiet', word: t('Quiet for {span}', { span: span(quietFor) }), tone: 'idle', known: true,
      was: row.status, quietFor, waitingFor: row.waitingFor ?? null,
    };
  }
  // The session's own word can be finer than the CLI's: "shell" arrives as busy, and it is a command running in
  // the session, not the model at work.
  if (row.status === 'busy' && row.rawStatus === 'shell') {
    return { key: 'busy', word: t('Shell command running'), tone: 'busy', known: true, waitingFor: null };
  }
  return { key: row.status, word: known.word, tone: known.tone, known: true, waitingFor: row.waitingFor ?? null };
}

/**
 * The session card's word, once the graph has said what shell commands the session has running (`shells`, a count
 * that is 0 unless the session is live). The machine calls a session that ended its turn with a command still
 * running in the background "idle", and one inside a long foreground command plain "busy"; both are a command
 * running. Waiting on someone, and a state that was not read, are left as they are: the first outranks it, and
 * the second is not measured.
 */
export function withShell(status, shells) {
  if (!shells || !status || (status.key !== 'idle' && status.key !== 'busy')) return status;
  return { ...status, key: 'busy', word: t('Shell command running'), tone: 'busy', known: true, waitingFor: null };
}

/**
 * @param fleet the /api/fleet answer, or null before the first one
 * @returns { key, word, tone, known } — key is 'unmeasured' when the fleet was not read: that is not "ended".
 */
export function sessionStatus(sessionId, fleet) {
  if (!fleet || fleet.measured === false) return { key: 'unmeasured', word: null, tone: null, known: false };
  const row = (fleet.sessions ?? []).find((s) => s.sessionId === sessionId && s.local !== false);
  if (!row) return { key: 'ended', word: t('Ended'), tone: null, known: true };
  return rowStatus(row, fleet.now ?? null);
}

/**
 * Is this the first run: the transcripts were read, and there are none?
 * An answer that could not be read is not a first run — it is not measured, and the navigator says that.
 */
export function isFirstRun(data) {
  return Boolean(data) && data.measured !== false && Array.isArray(data.projects) && data.projects.length === 0;
}

/* --------------------------------------------------------------- rows --- */

/** What a session is called: the label given here, the title it carries, and only then its id. */
export function sessionName(sn, labels) {
  const own = labels?.[sn.sessionId];
  if (typeof own === 'string' && own.trim()) return own.trim();
  if (sn.title) return sn.title;
  return String(sn.sessionId).slice(0, 8);
}

/** The line under the name: branch, state, agents. A part that was not read is left out, not filled in. */
export function sessionSub(sn, status) {
  const parts = [];
  if (sn.branch) parts.push(sn.branch);
  if (status?.key === 'waiting' && status.waitingFor) parts.push(`${t('Needs you')} · ${status.waitingFor}`);
  else if (status?.word) parts.push(status.word);
  if (sn.agentCount > 0) parts.push(sn.agentCount === 1 ? t('{n} agent', { n: 1 }) : t('{n} agents', { n: sn.agentCount }));
  return parts.join(' · ');
}

/** "now", "4m", "2h", "3d" — how long ago, coarse on purpose. */
export function ago(thenMs, nowMs) {
  if (typeof thenMs !== 'number' || !Number.isFinite(thenMs)) return '';
  const s = Math.max(0, Math.round((nowMs - thenMs) / 1000));
  if (s < 60) return t('now');
  if (s < 3600) return t('{n}m', { n: Math.floor(s / 60) });
  if (s < 86400) return t('{n}h', { n: Math.floor(s / 3600) });
  return t('{n}d', { n: Math.floor(s / 86400) });
}

/** "seen just now", "seen 3 min ago", "seen 2 h ago" — for a fact recorded earlier, not read now. */
export function seenAgo(thenMs, nowMs) {
  if (typeof thenMs !== 'number' || !Number.isFinite(thenMs)) return t('seen at an unrecorded time');
  const s = Math.max(0, Math.round((nowMs - thenMs) / 1000));
  if (s < 60) return t('seen just now');
  if (s < 3600) return t('seen {n} min ago', { n: Math.floor(s / 60) });
  if (s < 86400) return t('seen {n} h ago', { n: Math.floor(s / 3600) });
  return t('seen {n} d ago', { n: Math.floor(s / 86400) });
}

/* ------------------------------------------------------------- search --- */

/** Project name, branch, session id, and the name the row shows. An empty query matches everything. */
export function matchesSession(query, project, sn, labels) {
  const q = String(query ?? '').trim().toLowerCase();
  if (!q) return true;
  return [project.label, sn.branch, sn.sessionId, sessionName(sn, labels)]
    .some((v) => typeof v === 'string' && v.toLowerCase().includes(q));
}

/** `text` cut into parts, the ones that match `query` marked. Case is kept as written. */
export function highlight(text, query) {
  const t = String(text ?? '');
  const q = String(query ?? '').trim().toLowerCase();
  if (!q) return [{ text: t, hit: false }];
  const out = [];
  const low = t.toLowerCase();
  let i = 0;
  while (i < t.length) {
    const at = low.indexOf(q, i);
    if (at === -1) { out.push({ text: t.slice(i), hit: false }); break; }
    if (at > i) out.push({ text: t.slice(i, at), hit: false });
    out.push({ text: t.slice(at, at + q.length), hit: true });
    i = at + q.length;
  }
  return out.length ? out : [{ text: t, hit: false }];
}

/* -------------------------------------------------------------- badge --- */

/**
 * The version badge on a project row.
 *
 * `copy` is the command a click copies, and it is only ever the one the server sent. Without one — a project
 * with no Crewforth files, which is also what a plugin install looks like from here — the badge offers the
 * `/crew-update` hint in its title and copies nothing.
 */
export function badgeFor(kit) {
  if (!kit || !kit.installed) {
    return {
      text: t('no Crewforth'),
      tone: 'none',
      copy: null,
      title: t('No Crewforth files in this project. A plugin install leaves none, so this cannot tell the two apart; to update one, run /crew-update in the project.'),
    };
  }
  const command = typeof kit.updateCommand === 'string' && kit.updateCommand ? kit.updateCommand : null;
  const how = command ? t('click to copy: {command}', { command }) : t('run /crew-update in this project');
  if (kit.compared === false) {
    return {
      text: `${kit.version} ?`,
      tone: 'unknown',
      copy: null,
      title: t('Crewforth {version} — not compared: {reason}', { version: kit.version, reason: kit.reason ?? t('no reason given') }),
    };
  }
  if (kit.outdated) {
    return {
      text: `${kit.version} · ${t('update')}`,
      tone: 'old',
      copy: command,
      title: t('Crewforth {version} is behind {latest} — {how}', { version: kit.version, latest: kit.latest, how }),
    };
  }
  if (kit.ahead) {
    return {
      text: kit.version,
      tone: 'ahead',
      copy: null,
      title: t('Crewforth {version} is ahead of the published {latest}', { version: kit.version, latest: kit.latest }),
    };
  }
  return { text: kit.version, tone: 'current', copy: null, title: t('Crewforth {version} — current', { version: kit.version }) };
}

/* --------------------------------------------------------------- live --- */

/** The Live tab: sessions that are working or waiting on someone, the waiting ones first. */
export function liveSessions(fleet) {
  if (!fleet || fleet.measured === false) return [];
  const now = fleet.now ?? null;
  return (fleet.sessions ?? [])
    .filter((s) => s.status in LIVE_RANK)
    .map((s) => ({ s, k: rowStatus(s, now).key }))
    .sort((a, b) => LIVE_RANK[a.k] - LIVE_RANK[b.k] || (b.s.startedAt ?? 0) - (a.s.startedAt ?? 0))
    .map(({ s }) => s);
}
const LIVE_RANK = { waiting: 0, busy: 1, quiet: 2 };

/** How many of the live rows are live work: the badge's number. A quiet one is listed, not counted. */
export function liveCount(fleet) {
  const now = fleet?.now ?? null;
  return liveSessions(fleet).filter((s) => rowStatus(s, now).key !== 'quiet').length;
}

/** Where a live session belongs: its project, with a worktree folded into the repository that holds it. */
export function projectOfCwd(cwd) {
  if (typeof cwd !== 'string' || !cwd) return '';
  const root = cwd.replace(/[\\/]\.claude[\\/]worktrees[\\/].*$/, '');
  const parts = root.split(/[\\/]/).filter(Boolean);
  return parts[parts.length - 1] || root;
}

/**
 * The Live tab, one group per project. Groups keep the order of the rows they hold, so the project with a session
 * waiting on the viewer comes first; another machine's sessions never share a group with this machine's.
 * @param placeOf  row -> the project's name (the panel knows the projects; a bare cwd falls back to projectOfCwd)
 */
export function liveGroups(fleet, placeOf = (s) => projectOfCwd(s.cwd)) {
  const now = fleet?.now ?? null;
  const groups = new Map();
  for (const s of liveSessions(fleet)) {
    const origin = s.local === false ? (s.origin ?? '') : null;
    const label = placeOf(s) || t('unknown');
    const key = `${origin ?? ''}\u0000${label}`;
    if (!groups.has(key)) groups.set(key, { key, label, origin, rows: [] });
    groups.get(key).rows.push({ row: s, status: rowStatus(s, now) });
  }
  return [...groups.values()];
}

/**
 * The Machines tab. Two kinds of other machine, and they are not the same kind of fact: a peer Studio was asked
 * just now; a Remote Control session is what one session last recorded, at `seenAt`.
 */
export function machines(fleet) {
  const peers = (fleet?.origins ?? []).filter((o) => !o.local).map((o) => ({
    kind: 'peer',
    name: o.name,
    ok: o.ok !== false,
    reason: o.reason ?? null,
    sessions: typeof o.sessions === 'number' ? o.sessions : null,
  }));
  const roster = fleet?.roster ?? null;
  const remote = (roster?.peers ?? []).filter((p) => p.remote).map((p) => ({
    kind: 'snapshot',
    name: p.name,
    status: p.status ?? null,
    note: p.note || p.kind || '',
    seenAt: roster.seenAt ?? null,
  }));
  return {
    peers,
    remote,
    rosterMeasured: Boolean(roster?.measured),
    rosterReason: roster?.reason ?? null,
  };
}
