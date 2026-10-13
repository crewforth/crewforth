// remote.js — read-only viewers.
//
// The panel's own token can start a session and answer a tool call. Handing that token to a phone, over
// whatever tunnel reaches this machine, hands the phone all of it. A viewer token is the smaller thing: it
// reads what the panel reads and can change nothing. The server decides that, not the page — a viewer's
// request is refused here before any handler sees it.
//
// THE SERVER STILL LISTENS ON LOOPBACK ONLY. A viewer does not widen that. The way in from another device is a
// tunnel the user runs (an ssh forward, a tailnet), and this module knows nothing about it.
//
// Kept in memory, like the owner's token: a viewer lasts as long as the server that made it. A link that
// survived a restart would be a credential nobody remembers handing out.
import { randomUUID } from 'node:crypto';

export const MAX_VIEWERS = 8;
const LABEL_MAX = 40;

const viewers = new Map();          // id -> viewer
const byToken = new Map();          // token -> viewer

const publicOf = (v) => ({
  id: v.id,
  label: v.label,
  createdAt: v.createdAt,
  lastSeenAt: v.lastSeenAt,
  requests: v.requests,
  agent: v.agent,
  open: v.conns.size,
});

/** Make a viewer. The token is in this answer and in no later one. */
export function addViewer(label) {
  if (viewers.size >= MAX_VIEWERS) {
    return { ok: false, reason: `${MAX_VIEWERS} viewers already; revoke one first` };
  }
  const named = typeof label === 'string' ? label.replace(/\s+/g, ' ').trim().slice(0, LABEL_MAX) : '';
  const v = {
    id: randomUUID().slice(0, 8),
    label: named || `Viewer ${viewers.size + 1}`,
    token: randomUUID(),
    createdAt: Date.now(),
    lastSeenAt: null,
    requests: 0,
    agent: null,
    conns: new Set(),
  };
  viewers.set(v.id, v);
  byToken.set(v.token, v);
  return { ok: true, viewer: { ...publicOf(v), token: v.token } };
}

export function listViewers() {
  return [...viewers.values()].map(publicOf);
}

export function viewerByToken(token) {
  return (typeof token === 'string' && byToken.get(token)) || null;
}

/**
 * Take a viewer's access back. Its token stops working with this call, and a stream it holds open is closed:
 * a revoke that left the live graph running on the phone would be a revoke in name only.
 */
export function revokeViewer(id) {
  const v = viewers.get(id);
  if (!v) return { ok: true, revoked: false };
  viewers.delete(id);
  byToken.delete(v.token);
  for (const res of v.conns) { try { res.destroy(); } catch { /* already gone */ } }
  v.conns.clear();
  return { ok: true, revoked: true };
}

/** Count a viewer's request and remember its response for as long as it is open. */
export function noteRequest(v, req, res) {
  v.requests += 1;
  v.lastSeenAt = Date.now();
  const ua = req.headers['user-agent'];
  v.agent = typeof ua === 'string' ? ua.slice(0, 160) : null;
  v.conns.add(res);
  res.on('close', () => v.conns.delete(res));
}

/**
 * What a viewer may ask for: a GET of anything the panel reads, and nothing about viewers themselves.
 * The list of viewers is the owner's; a viewer that could read it could count who else is watching.
 */
export function viewerMay(method, pathname) {
  if (method !== 'GET') return { ok: false, reason: 'read-only token: GET only' };
  if (pathname === '/api/remote' || pathname.startsWith('/api/remote/')) {
    return { ok: false, reason: 'read-only token: viewers are managed from the machine itself' };
  }
  return { ok: true };
}

/** For the self-check: start from nothing. */
export function _reset() {
  for (const id of [...viewers.keys()]) revokeViewer(id);
}
