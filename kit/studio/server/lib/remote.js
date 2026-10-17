// remote.js — read-only viewers.
//
// The panel's own token can start a session and answer a tool call. Handing that token to a phone hands the phone
// all of it. A viewer token is the smaller thing: it reads what the panel reads and can change nothing. The server
// decides that, not the page — a viewer's request is refused here before any handler sees it.
//
// THE WAY IN FROM ANOTHER DEVICE IS THE SAME WI-FI. While at least one viewer is live, the server also listens on
// this machine's Wi-Fi address (index.js), and there it answers a viewer's token and nothing else: the panel's own
// token is not accepted from the network at all. With no viewer, nothing listens beyond 127.0.0.1.
//
// A viewer lasts EIGHT HOURS, or until it is revoked, or until the server stops — whichever comes first. Kept in
// memory, like the owner's token: a link that survived a restart would be a credential nobody remembers handing out.
// An expired token is remembered as expired (not as unknown) so the phone can say "Session expired" rather than
// "no access", and only for as long as the server runs.
//
// TRANSCRIPTS ARE HIDDEN by default: a viewer made without `transcripts` is answered with no text that came from a
// transcript (lib/redact.js does that on the server; the page hiding it would not be enough).
import { randomUUID } from 'node:crypto';

export const MAX_VIEWERS = 8;
export const VIEWER_TTL_MS = 8 * 60 * 60 * 1000;
const LABEL_MAX = 40;
const LOG_MAX = 200;

const viewers = new Map();          // id -> viewer
const byToken = new Map();          // token -> viewer
const expired = new Map();          // token -> label, for "Session expired"
const log = [];                     // what happened to viewers' links, newest last

let clock = () => Date.now();
let onChange = () => {};
let note = () => {};

/** For the self-check: a clock it can move (eight hours are not waited for). */
export function _setClock(fn) { clock = fn ?? (() => Date.now()); }
/** index.js opens and closes the Wi-Fi listener when the number of live viewers changes. */
export function onViewersChange(fn) { onChange = fn ?? (() => {}); }
/** Where a log line also goes (the server's own output). */
export function onLog(fn) { note = fn ?? (() => {}); }

function record(entry) {
  const e = { at: clock(), ...entry };
  log.push(e);
  if (log.length > LOG_MAX) log.splice(0, log.length - LOG_MAX);
  note(e);
}

const publicOf = (v) => ({
  id: v.id,
  label: v.label,
  createdAt: v.createdAt,
  expiresAt: v.expiresAt,
  transcripts: v.transcripts,
  lastSeenAt: v.lastSeenAt,
  requests: v.requests,
  agent: v.agent,
  open: v.conns.size,
  addresses: [...v.addresses],
});

/** Make a viewer. The token is in this answer and in no later one. */
export function addViewer(label, { transcripts = false } = {}) {
  sweep();
  if (viewers.size >= MAX_VIEWERS) {
    return { ok: false, reason: `${MAX_VIEWERS} viewers already; revoke one first` };
  }
  const named = typeof label === 'string' ? label.replace(/\s+/g, ' ').trim().slice(0, LABEL_MAX) : '';
  const now = clock();
  const v = {
    id: randomUUID().slice(0, 8),
    label: named || `Viewer ${viewers.size + 1}`,
    token: randomUUID(),
    createdAt: now,
    expiresAt: now + VIEWER_TTL_MS,
    transcripts: transcripts === true,
    lastSeenAt: null,
    requests: 0,
    agent: null,
    conns: new Set(),
    addresses: new Set(),
  };
  viewers.set(v.id, v);
  byToken.set(v.token, v);
  record({ event: 'added', viewer: v.label, transcripts: v.transcripts });
  onChange(viewers.size);
  return { ok: true, viewer: { ...publicOf(v), token: v.token } };
}

export function listViewers() {
  sweep();
  return [...viewers.values()].map(publicOf);
}

export function liveCount() {
  sweep();
  return viewers.size;
}

export function remoteLog(n = 50) {
  return log.slice(-n);
}

/** The viewer this token belongs to, if it is live; `{ expired: label }` if it was one and its eight hours are up. */
export function viewerByToken(token) {
  if (typeof token !== 'string') return null;
  const v = byToken.get(token);
  if (v && clock() >= v.expiresAt) { end(v, 'expired'); return { expired: v.label }; }
  if (v) return v;
  if (expired.has(token)) return { expired: expired.get(token) };
  return null;
}

function end(v, why) {
  viewers.delete(v.id);
  byToken.delete(v.token);
  if (why === 'expired') expired.set(v.token, v.label);
  for (const res of v.conns) { try { res.destroy(); } catch { /* already gone */ } }
  v.conns.clear();
  record({ event: why, viewer: v.label });
  onChange(viewers.size);
}

/** End every viewer whose eight hours are up. Called on every read of the list and by index.js's timer. */
export function sweep() {
  const now = clock();
  for (const v of [...viewers.values()]) if (now >= v.expiresAt) end(v, 'expired');
}

/**
 * Take a viewer's access back. Its token stops working with this call, and a stream it holds open is closed:
 * a revoke that left the live graph running on the phone would be a revoke in name only.
 */
export function revokeViewer(id) {
  const v = viewers.get(id);
  if (!v) return { ok: true, revoked: false };
  end(v, 'revoked');
  return { ok: true, revoked: true };
}

/** Count a viewer's request and remember its response for as long as it is open. A new address is logged once. */
export function noteRequest(v, req, res) {
  v.requests += 1;
  v.lastSeenAt = clock();
  const ua = req.headers['user-agent'];
  v.agent = typeof ua === 'string' ? ua.slice(0, 160) : null;
  const ip = req.socket?.remoteAddress ?? null;
  if (ip && !v.addresses.has(ip)) {
    v.addresses.add(ip);
    record({ event: 'connected', viewer: v.label, ip, over: req.crewLan ? 'wifi' : 'loopback', result: 'ok' });
  }
  v.conns.add(res);
  res.on('close', () => v.conns.delete(res));
}

/**
 * A request that was turned away: logged with who it claimed to be, from where, and why. The same refusal again
 * (same viewer, address, path and answer) is counted on its entry rather than written again, so a page that keeps
 * asking cannot push everything else out of the log.
 */
export function noteRefusal(req, { viewer = null, status, reason }) {
  const e = { event: 'refused', viewer, ip: req.socket?.remoteAddress ?? null, over: req.crewLan ? 'wifi' : 'loopback',
    result: `${status} ${reason}`, path: String(req.url ?? '').split('?')[0].slice(0, 120) };
  const same = log.findLast((x) => x.event === 'refused' && x.viewer === e.viewer && x.ip === e.ip && x.path === e.path && x.result === e.result);
  if (same) { same.count = (same.count ?? 1) + 1; same.lastAt = clock(); return; }
  record(e);
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
  for (const v of [...viewers.values()]) end(v, 'revoked');
  expired.clear();
  log.length = 0;
}
