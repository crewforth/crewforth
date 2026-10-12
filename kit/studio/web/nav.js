// What the top bar and the navigator say, kept apart from where they draw it.
//
// Everything here is a function of the data the server sent. None of it touches the page, so each rule can be
// asserted on its own: which word a status gets, what a version badge offers to copy, what a row is called when
// the transcript carried no title. The drawing is in app.js.
//
// One rule runs through it, the panel's own: a value that was not read is never written as if it had been. A
// status nobody recognises keeps its own word and gets no colour; a branch that could not be read leaves the line
// without one; a project that cannot be told to update by a command gets a hint instead of a command.

/* ------------------------------------------------------------- status --- */

// The words the design uses, and the token each is drawn in. `tone` names a status-* token; null is the hollow
// ring of something that is over.
const AGENT_STATUS = {
  running: { word: 'running', tone: 'busy' },
  starting: { word: 'starting', tone: 'busy' },
  done: { word: 'done', tone: 'good' },
  failed: { word: 'failed', tone: 'fail' },
  killed: { word: 'killed', tone: 'fail' },
  stopped: { word: 'stopped', tone: 'fail' },
  stale: { word: 'stale', tone: 'idle' },
  ended: { word: 'ended', tone: null },
};
const CHIP_ORDER = ['running', 'starting', 'stale', 'done', 'failed', 'killed', 'stopped', 'ended'];

/** The word and the tone one agent status is drawn in. A status this table does not know keeps its own word. */
export function agentStatus(status) {
  const known = AGENT_STATUS[status];
  return known
    ? { word: known.word, tone: known.tone, known: true }
    : { word: String(status ?? 'unknown'), tone: null, known: false };
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
  busy: { word: 'Running', tone: 'busy' },
  waiting: { word: 'Needs you', tone: 'waiting' },
  idle: { word: 'Idle', tone: 'idle' },
};

/**
 * @param fleet the /api/fleet answer, or null before the first one
 * @returns { key, word, tone, known } — key is 'unmeasured' when the fleet was not read: that is not "ended".
 */
export function sessionStatus(sessionId, fleet) {
  if (!fleet || fleet.measured === false) return { key: 'unmeasured', word: null, tone: null, known: false };
  const row = (fleet.sessions ?? []).find((s) => s.sessionId === sessionId && s.local !== false);
  if (!row) return { key: 'ended', word: 'Ended', tone: null, known: true };
  const known = SESSION_STATUS[row.status];
  if (!known) return { key: String(row.status), word: String(row.status), tone: null, known: false };
  return { key: row.status, word: known.word, tone: known.tone, known: true, waitingFor: row.waitingFor ?? null };
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
  if (status?.key === 'waiting' && status.waitingFor) parts.push(`Needs you · ${status.waitingFor}`);
  else if (status?.word) parts.push(status.word);
  if (sn.agentCount > 0) parts.push(`${sn.agentCount} ${sn.agentCount === 1 ? 'agent' : 'agents'}`);
  return parts.join(' · ');
}

/** "now", "4m", "2h", "3d" — how long ago, coarse on purpose. */
export function ago(thenMs, nowMs) {
  if (typeof thenMs !== 'number' || !Number.isFinite(thenMs)) return '';
  const s = Math.max(0, Math.round((nowMs - thenMs) / 1000));
  if (s < 60) return 'now';
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86400) return `${Math.floor(s / 3600)}h`;
  return `${Math.floor(s / 86400)}d`;
}

/** "seen just now", "seen 3 min ago", "seen 2 h ago" — for a fact recorded earlier, not read now. */
export function seenAgo(thenMs, nowMs) {
  if (typeof thenMs !== 'number' || !Number.isFinite(thenMs)) return 'seen at an unrecorded time';
  const s = Math.max(0, Math.round((nowMs - thenMs) / 1000));
  if (s < 60) return 'seen just now';
  if (s < 3600) return `seen ${Math.floor(s / 60)} min ago`;
  if (s < 86400) return `seen ${Math.floor(s / 3600)} h ago`;
  return `seen ${Math.floor(s / 86400)} d ago`;
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
      text: 'no Crewforth',
      tone: 'none',
      copy: null,
      title: 'No Crewforth files in this project. A plugin install leaves none, so this cannot tell the two '
        + 'apart; to update one, run /crew-update in the project.',
    };
  }
  const command = typeof kit.updateCommand === 'string' && kit.updateCommand ? kit.updateCommand : null;
  const how = command ? `click to copy: ${command}` : 'run /crew-update in this project';
  if (kit.compared === false) {
    return {
      text: `${kit.version} ?`,
      tone: 'unknown',
      copy: null,
      title: `Crewforth ${kit.version} — not compared: ${kit.reason ?? 'no reason given'}`,
    };
  }
  if (kit.outdated) {
    return {
      text: `${kit.version} · update`,
      tone: 'old',
      copy: command,
      title: `Crewforth ${kit.version} is behind ${kit.latest} — ${how}`,
    };
  }
  if (kit.ahead) {
    return {
      text: kit.version,
      tone: 'ahead',
      copy: null,
      title: `Crewforth ${kit.version} is ahead of the published ${kit.latest}`,
    };
  }
  return { text: kit.version, tone: 'current', copy: null, title: `Crewforth ${kit.version} — current` };
}

/* --------------------------------------------------------------- live --- */

/** The Live tab: sessions that are working or waiting on someone, the waiting ones first. */
export function liveSessions(fleet) {
  if (!fleet || fleet.measured === false) return [];
  const rank = { waiting: 0, busy: 1 };
  return (fleet.sessions ?? [])
    .filter((s) => s.status in rank)
    .sort((a, b) => rank[a.status] - rank[b.status] || (b.startedAt ?? 0) - (a.startedAt ?? 0));
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
