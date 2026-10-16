#!/usr/bin/env node
// CSK Studio — the server half.
//
// It binds to loopback and nothing else. The panel reads a developer's live
// sessions, transcripts and, later, drives Claude itself; none of that should
// be reachable from the network, so the host is not configurable.
//
// Zero dependencies, by design: the kit ships no npm packages and this stays
// inside that promise. `node server/index.js` is the whole install step.

import http from 'node:http';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath, pathToFileURL } from 'node:url';

import { getFleet, measureSpawnCost } from './lib/fleet.js';
import { projectDir, listSessions, findSession, listProjects, sessionCwd } from './lib/projects.js';
import { buildGraph, agentDetail, conversation } from './lib/graph.js';
import { palette } from './lib/palette.js';
import { latestVersion, kitStatus } from './lib/kit.js';
import { parsePeers, askAll, ask } from './lib/peers.js';
import {
  createSession, getSession, listSessionsOwned, reap, stopAll, ALLOWED_MODES,
} from './lib/session.js';
import { decide, pending, alwaysList } from './lib/permissions.js';
import { open as openTerminal, plan as terminalPlan } from './lib/terminal.js';
import * as pty from './lib/pty.js';
import { gateLog, gateReport, sessionStats, board } from './lib/kit-telemetry.js';
import { remoteRoster } from './lib/roster.js';
import { randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const WEB_ROOT = path.resolve(HERE, '..', 'web');
const LOOPBACK = '127.0.0.1';

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
};

function parseArgs(argv) {
  const out = { port: 7777, selftest: false, open: false, peers: [], name: null, pty: false };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--port' || a === '-p') {
      const n = Number(argv[i + 1]);
      if (!Number.isInteger(n) || n < 1 || n > 65535) {
        throw new Error(`--port needs a number between 1 and 65535, got: ${argv[i + 1]}`);
      }
      out.port = n;
      i += 1;
    } else if (a === '--peer') {
      if (!argv[i + 1]) throw new Error('--peer needs a URL');
      out.peers.push(argv[i + 1]);
      i += 1;
    } else if (a === '--name') {
      if (!argv[i + 1]) throw new Error('--name needs a label');
      out.name = argv[i + 1];
      i += 1;
    } else if (a === '--open' || a === '-o') {
      out.open = true;
    } else if (a === '--enable-pty') {
      out.pty = true;
    } else if (a === '--selftest') {
      out.selftest = true;
    } else if (a === '--help' || a === '-h') {
      out.help = true;
    } else {
      throw new Error(`unknown argument: ${a}`);
    }
  }
  return out;
}

function send(res, status, body, headers = {}) {
  res.writeHead(status, {
    'content-type': 'text/plain; charset=utf-8',
    'cache-control': 'no-store',
    ...headers,
  });
  res.end(body);
}

function sendJson(res, status, value) {
  send(res, status, JSON.stringify(value, null, 2), {
    'content-type': 'application/json; charset=utf-8',
  });
}

// Auth is opt-in while every endpoint is read-only and loopback-bound. It
// becomes mandatory in the sprint that adds write endpoints; wiring it now
// means that switch is a default change, not a retrofit.
// Once the panel can start a session, a token stops being optional: any page
// in the user's browser can POST to loopback. One is generated when none is
// supplied and printed with the URL, so the default is safe rather than
// convenient-and-open.
const TOKEN = process.env.CSK_STUDIO_TOKEN || randomUUID();
const TOKEN_GENERATED = !process.env.CSK_STUDIO_TOKEN;

// Peers are other machines running Studio, reached over a forwarded port. This
// server still listens on loopback only; a peer never widens that.
let PEERS = [];
let SELF_NAME = 'this machine';

function authorised(req, url) {
  const header = req.headers['authorization'];
  if (header === `Bearer ${TOKEN}`) return true;
  return url.searchParams.get('token') === TOKEN;
}

/**
 * Extra gate for anything that changes state.
 *
 * The token alone already stops a drive-by page, since it cannot read the
 * query string of another origin. The header requirement makes the attempt
 * fail earlier: a cross-origin POST carrying a custom header must pass a
 * preflight first, and this server answers none.
 */
export function writeAllowed(req) {
  if (req.headers['x-csk-studio'] !== '1') {
    return { ok: false, reason: 'missing x-csk-studio header' };
  }
  const origin = req.headers.origin;
  if (origin) {
    let host;
    try { host = new URL(origin).hostname; } catch { return { ok: false, reason: 'bad Origin' }; }
    if (host !== LOOPBACK && host !== 'localhost') return { ok: false, reason: `cross-origin request from ${origin}` };
  }
  return { ok: true };
}

const MAX_BODY_BYTES = 1024 * 1024;

function readBody(req) {
  return new Promise((resolve) => {
    let size = 0;
    const parts = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > MAX_BODY_BYTES) { req.destroy(); resolve(null); return; }
      parts.push(c);
    });
    req.on('end', () => {
      if (!parts.length) return resolve({});
      try { resolve(JSON.parse(Buffer.concat(parts).toString('utf8'))); } catch { resolve(null); }
    });
    req.on('error', () => resolve(null));
  });
}

async function serveStatic(res, urlPath) {
  const rel = urlPath === '/' ? '/index.html' : urlPath;
  // Resolve, then prove the result is still inside web/. Comparing spellings
  // is not enough; ask the resolver.
  const abs = path.resolve(WEB_ROOT, `.${rel}`);
  if (abs !== WEB_ROOT && !abs.startsWith(WEB_ROOT + path.sep)) {
    return send(res, 403, 'forbidden');
  }
  try {
    const data = await fsp.readFile(abs);
    return send(res, 200, data, {
      'content-type': MIME[path.extname(abs)] ?? 'application/octet-stream',
    });
  } catch {
    return send(res, 404, 'not found');
  }
}

async function handle(req, res) {
  const url = new URL(req.url, `http://${LOOPBACK}`);

  // The token guards data and actions, not the app shell. A browser does not
  // carry the page's query string into its sub-resource requests, so demanding
  // it for /style.css served an unstyled page and protected nothing: the shell
  // holds no secrets, and every /api/ path below is still gated.
  if (url.pathname.startsWith('/api/') && !authorised(req, url)) {
    return sendJson(res, 403, { ok: false, reason: 'token required' });
  }

  if (url.pathname === '/api/health') {
    return sendJson(res, 200, {
      ok: true,
      node: process.version,
      pid: process.pid,
      uptimeMs: Math.round(process.uptime() * 1000),
    });
  }

  if (url.pathname === '/api/fleet') {
    const local = await getFleet();
    const mine = (local.sessions ?? []).map((sn) => ({ ...sn, origin: SELF_NAME, local: true }));

    // Self is always in origins, peers or not: a machine that never names
    // itself cannot be labelled by the one reading it.
    const self = { name: SELF_NAME, local: true, ok: true, sessions: mine.length };
    // Sessions reachable on other machines. Not live and not this machine's —
    // a snapshot of what a Remote-Control-connected session last recorded.
    const roster = remoteRoster();
    if (!PEERS.length) return sendJson(res, 200, { ...local, sessions: mine, origins: [self], roster });

    const answers = await askAll(PEERS, '/api/fleet');
    const sessions = [...mine];
    const origins = [self];
    for (const a of answers) {
      if (!a.ok) {
        // An unreachable machine is reported as unreachable. Dropping it would
        // read as "that machine is quiet".
        origins.push({ name: a.peer.name, ok: false, reason: a.reason });
        continue;
      }
      // A machine knows its own name; the URL we reached it on is only a
      // fallback for one that does not say.
      const label = a.body?.origins?.find((o) => o.local)?.name ?? a.peer.name;
      const rows = (a.body?.sessions ?? []).map((sn) => ({ ...sn, origin: label, local: false }));
      origins.push({ name: label, via: a.peer.name, ok: true, sessions: rows.length, measured: a.body?.measured !== false });
      sessions.push(...rows);
    }
    return sendJson(res, 200, { measured: local.measured, sessions, origins, roster, at: Date.now() });
  }

  if (url.pathname === '/api/projects') {
    const cwd = url.searchParams.get('cwd') || process.cwd();
    const started = Date.now();
    const latest = await latestVersion();
    const projects = listProjects({ currentCwd: cwd, kitOf: (c) => kitStatus(c, latest) });
    for (const p of projects) { p.origin = SELF_NAME; p.local = true; }

    const origins = [{ name: SELF_NAME, local: true, ok: true, projects: projects.length }];
    if (PEERS.length) {
      for (const a of await askAll(PEERS, '/api/projects')) {
        if (!a.ok) { origins.push({ name: a.peer.name, ok: false, reason: a.reason }); continue; }
        const label = a.body?.origins?.find((o) => o.local)?.name ?? a.peer.name;
        const rows = (a.body?.projects ?? []).map((pr) => ({
          ...pr,
          origin: label,
          local: false,
          current: false,              // "the project you are standing in" is a local fact
          key: `${label}|${pr.key}`,
        }));
        origins.push({ name: label, via: a.peer.name, ok: true, projects: rows.length });
        projects.push(...rows);
      }
      projects.sort((a, b) =>
        Number(b.current) - Number(a.current) ||
        Number(b.local) - Number(a.local) ||
        Number(b.exists) - Number(a.exists) ||
        b.modifiedAt - a.modifiedAt);
    }

    const installed = projects.filter((p) => p.kit?.installed);
    return sendJson(res, 200, {
      measured: true,
      cwd,
      latest,
      origins,
      projects,
      totals: {
        projects: projects.length,
        live: projects.filter((p) => p.exists).length,
        sessions: projects.reduce((n, p) => n + p.total, 0),
        agents: projects.reduce((n, p) => n + p.agentTotal, 0),
        kitInstalled: installed.length,
        kitOutdated: installed.filter((p) => p.kit.outdated).length,
        kitUncompared: installed.filter((p) => p.kit.compared === false).length,
      },
      buildMs: Date.now() - started,
    });
  }

  // What the kit already measures about itself, reported as the kit reports it.
  if (url.pathname === '/api/kit') {
    const cwd = url.searchParams.get('cwd') || process.cwd();
    const sid = url.searchParams.get('session');
    const session = sid ? findSession(sid) : null;
    const [report, stats, brd] = await Promise.all([
      gateReport(cwd),
      session ? sessionStats(cwd, session.file) : Promise.resolve({ measured: false, reason: 'no session named' }),
      board(cwd),
    ]);
    return sendJson(res, 200, { measured: true, cwd, log: gateLog(cwd), report, stats, board: brd });
  }

  if (url.pathname === '/api/palette') {
    return sendJson(res, 200, palette());
  }

  if (url.pathname === '/api/sessions') {
    const cwd = url.searchParams.get('cwd') || process.cwd();
    const dir = projectDir(cwd);
    if (!dir) {
      // Nothing was read. That is not the same as "this project never ran".
      return sendJson(res, 200, {
        measured: false,
        reason: `no transcript directory for ${cwd}`,
        cwd,
        sessions: [],
      });
    }
    const sessions = listSessions(dir).map((s) => ({
      sessionId: s.sessionId,
      bytes: s.bytes,
      modifiedAt: s.modifiedAt,
      agentCount: s.agentCount,
    }));
    return sendJson(res, 200, { measured: true, cwd, dir, sessions });
  }

  const graphMatch = url.pathname.match(/^\/api\/session\/([^/]+)\/graph$/);
  if (graphMatch) {
    const session = findSession(decodeURIComponent(graphMatch[1]));
    if (!session) {
      const relayed = await relay(url.pathname);
      if (relayed) return sendJson(res, 200, relayed);
      return sendJson(res, 404, { measured: false, reason: 'no such session on this machine or any peer' });
    }
    const started = Date.now();
    const graph = buildGraph(session);
    return sendJson(res, 200, { ...graph, measured: true, buildMs: Date.now() - started });
  }

  const convMatch = url.pathname.match(/^\/api\/session\/([^/]+)\/conversation$/);
  if (convMatch) {
    const session = findSession(decodeURIComponent(convMatch[1]));
    if (!session) {
      const relayed = await relay(url.pathname);
      if (relayed) return sendJson(res, 200, relayed);
      return sendJson(res, 404, { measured: false, reason: 'no such session on this machine or any peer' });
    }
    return sendJson(res, 200, conversation(session));
  }

  const agentMatch = url.pathname.match(/^\/api\/session\/([^/]+)\/agent\/([^/]+)$/);
  if (agentMatch) {
    const session = findSession(decodeURIComponent(agentMatch[1]));
    if (!session) {
      const relayed = await relay(url.pathname);
      if (relayed) return sendJson(res, 200, relayed);
      return sendJson(res, 404, { measured: false, reason: 'no such session' });
    }
    const detail = agentDetail(session, decodeURIComponent(agentMatch[2]));
    if (!detail) return sendJson(res, 404, { measured: false, reason: 'no transcript for that agent' });
    return sendJson(res, 200, { ...detail, measured: true });
  }

  // Hand an observed session back to a real terminal, where it can be driven.
  const termMatch = url.pathname.match(/^\/api\/session\/([^/]+)\/terminal$/);
  if (termMatch) {
    const id = decodeURIComponent(termMatch[1]);
    const session = findSession(id);
    const cwd = url.searchParams.get('cwd') || (session ? sessionCwd(session.file, session.bytes) : null);

    if (req.method === 'GET') {
      // What WOULD run, so the panel can show it before anything is launched.
      return sendJson(res, 200, { measured: true, cwd, plan: cwd ? terminalPlan({ cwd, sessionId: id }) : null });
    }

    const gate = writeAllowed(req);
    if (!gate.ok) return sendJson(res, 403, { ok: false, reason: gate.reason });
    if (req.method !== 'POST') return sendJson(res, 405, { ok: false, reason: 'POST only' });

    const body = await readBody(req);
    if (!body) return sendJson(res, 400, { ok: false, reason: 'body was not JSON' });
    const out = openTerminal({
      cwd: typeof body.cwd === 'string' ? body.cwd : cwd,
      sessionId: id,
      command: typeof body.command === 'string' ? body.command : undefined,
    });
    return sendJson(res, out.ok ? 200 : 400, out);
  }

  /* ------------------------------------------------------------- pty ---
     Off unless asked for. A raw shell is the one surface here that the kit's
     own gates cannot see, so it is never on by default and the panel says so. */

  if (url.pathname === '/api/pty' && req.method === 'GET') {
    const cap = pty.capability();
    return sendJson(res, 200, {
      measured: true,
      enabled: pty.isEnabled(),
      available: cap.available,
      reason: cap.available ? null : cap.reason,
      // Said plainly, because the panel repeats it on screen.
      warning: 'a raw shell bypasses the kit gates: commands typed here never reach a PreToolUse hook',
      terminals: pty.list(),
    });
  }

  const ptyMatch = url.pathname.match(/^\/api\/pty(?:\/([^/]+)(?:\/(input|resize|close|stream))?)?$/);
  if (ptyMatch) {
    const [, tid, verb] = ptyMatch;

    if (tid && verb === 'stream') {
      const t = pty.get(tid);
      if (!t) return sendJson(res, 404, { ok: false, reason: 'no such terminal' });
      return ptyStream(req, res, t);
    }

    const gate = writeAllowed(req);
    if (!gate.ok) return sendJson(res, 403, { ok: false, reason: gate.reason });
    if (req.method !== 'POST') return sendJson(res, 405, { ok: false, reason: 'POST only' });

    const body = await readBody(req);
    if (!body) return sendJson(res, 400, { ok: false, reason: 'body was not JSON' });

    if (!tid) {
      const made = pty.create({ cwd: body.cwd, rows: body.rows, cols: body.cols });
      if (!made.ok) return sendJson(res, 400, made);
      return sendJson(res, 201, { ok: true, terminal: made.terminal.summary() });
    }

    const t = pty.get(tid);
    if (!t) return sendJson(res, 404, { ok: false, reason: 'no such terminal' });
    if (verb === 'input') return sendJson(res, 200, { ...t.write(String(body.data ?? '')), terminal: t.summary() });
    if (verb === 'resize') return sendJson(res, 200, { ...t.resize(body.rows, body.cols), terminal: t.summary() });
    if (verb === 'close') return sendJson(res, 200, { ...t.close(), terminal: t.summary() });
    return sendJson(res, 400, { ok: false, reason: 'unknown action' });
  }

  if (url.pathname === '/api/stream') {
    return stream(req, res, url);
  }

  /* ---------------------------------------------------------- owned ---
     Sessions the panel started. Their transcripts land in the usual place,
     so the graph endpoints already cover them; only the conversation needs
     a channel of its own. */

  if (url.pathname === '/api/owned' && req.method === 'GET') {
    reap();
    return sendJson(res, 200, { measured: true, modes: ALLOWED_MODES, sessions: listSessionsOwned() });
  }

  if (url.pathname === '/api/owned' && req.method === 'POST') {
    const gate = writeAllowed(req);
    if (!gate.ok) return sendJson(res, 403, { ok: false, reason: gate.reason });
    const body = await readBody(req);
    if (!body) return sendJson(res, 400, { ok: false, reason: 'body was not JSON' });
    const made = await createSession({
      cwd: typeof body.cwd === 'string' ? body.cwd : undefined,
      model: typeof body.model === 'string' ? body.model : undefined,
      permissionMode: typeof body.permissionMode === 'string' ? body.permissionMode : undefined,
      resume: typeof body.resume === 'string' ? body.resume : undefined,
    });
    if (!made.ok) return sendJson(res, 400, made);
    return sendJson(res, 201, { ok: true, session: made.session.summary() });
  }

  // Permission decisions: read the queue, or answer one item.
  const permMatch = url.pathname.match(/^\/api\/owned\/([^/]+)\/permissions(?:\/([^/]+))?$/);
  if (permMatch) {
    const s = getSession(decodeURIComponent(permMatch[1]));
    if (!s) return sendJson(res, 404, { ok: false, reason: 'no such owned session' });

    if (req.method === 'GET') {
      return sendJson(res, 200, {
        measured: true,
        gated: Boolean(s.gate),
        waitSeconds: s.gate?.waitSeconds ?? null,
        pending: s.gate ? pending(s.id) : [],
        always: s.gate ? alwaysList(s.id) : [],
      });
    }

    const gate = writeAllowed(req);
    if (!gate.ok) return sendJson(res, 403, { ok: false, reason: gate.reason });
    if (req.method !== 'POST' || !permMatch[2]) return sendJson(res, 405, { ok: false, reason: 'POST to a request id' });
    if (!s.gate) return sendJson(res, 409, { ok: false, reason: 'this session has no gate to answer' });

    const body = await readBody(req);
    if (!body) return sendJson(res, 400, { ok: false, reason: 'body was not JSON' });
    const out = decide(s.id, decodeURIComponent(permMatch[2]), body.verdict);
    return sendJson(res, out.ok ? 200 : 400, out);
  }

  const ownedMatch = url.pathname.match(/^\/api\/owned\/([^/]+)(?:\/(message|stop|events))?$/);
  if (ownedMatch) {
    const s = getSession(decodeURIComponent(ownedMatch[1]));
    if (!s) return sendJson(res, 404, { ok: false, reason: 'no such owned session' });
    const verb = ownedMatch[2];

    if (!verb) return sendJson(res, 200, { measured: true, session: s.summary() });

    if (verb === 'events') return ownedStream(req, res, url, s);

    const gate = writeAllowed(req);
    if (!gate.ok) return sendJson(res, 403, { ok: false, reason: gate.reason });
    if (req.method !== 'POST') return sendJson(res, 405, { ok: false, reason: 'POST only' });

    if (verb === 'stop') return sendJson(res, 200, { ...s.stop(), session: s.summary() });

    const body = await readBody(req);
    if (!body) return sendJson(res, 400, { ok: false, reason: 'body was not JSON' });
    const sent = s.send(body.text);
    return sendJson(res, sent.ok ? 200 : 400, { ...sent, session: s.summary() });
  }

  if (url.pathname.startsWith('/api/')) {
    return sendJson(res, 404, { error: `no such endpoint: ${url.pathname}` });
  }

  if (req.method !== 'GET' && req.method !== 'HEAD') {
    return send(res, 405, 'method not allowed');
  }

  return serveStatic(res, url.pathname);
}

/* ---------------------------------------------------------------- stream
   Server-sent events. A WebSocket would need a dependency or a hand-rolled
   frame codec; SSE is one-way, which is all the graph needs, and it reconnects
   on its own.

   Files are polled rather than watched: fs.watch's event semantics differ per
   platform, and a graph rebuild measured 17 ms on a 1.5 MB transcript, so a
   cheap signature check plus a conditional rebuild is both simpler and honest
   about its cost. */

const STREAM_TICK_MS = 700;

/** Ask each peer for a path this machine could not answer. */
async function relay(pathname) {
  for (const p of PEERS) {
    const r = await ask(p, pathname);
    if (r.ok && r.body?.measured !== false) return { ...r.body, origin: p.name, relayed: true };
  }
  return null;
}

function signature(session) {
  const parts = [];
  try { parts.push(String(fs.statSync(session.file).size)); } catch { parts.push('0'); }
  try {
    for (const n of fs.readdirSync(session.subagentsDir).sort()) {
      try { parts.push(`${n}:${fs.statSync(path.join(session.subagentsDir, n)).size}`); } catch { /* raced */ }
    }
  } catch { /* no subagents yet */ }
  return parts.join('|');
}

function stream(req, res, url) {
  const id = url.searchParams.get('session');
  let session = id ? findSession(id) : null;

  res.writeHead(200, {
    'content-type': 'text/event-stream; charset=utf-8',
    'cache-control': 'no-store',
    connection: 'keep-alive',
    'x-accel-buffering': 'no',
  });

  const send = (event, data) => {
    res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
  };

  // A session the panel just started has no transcript until its first turn
  // lands. That is a session waiting, not a session missing, and saying "no
  // such session" about one we are holding open would be a plain lie.
  //
  // The wait then has to hand over to the normal watch. Sending one graph and
  // stopping left the canvas frozen on the first frame while the conversation
  // carried on beside it.
  if (!session && id && getSession(id)) {
    send('waiting', { measured: true, sessionId: id, reason: 'no transcript yet — the first turn has not landed' });

    let timer = null;
    const stopWait = () => { if (timer) clearInterval(timer); try { res.end(); } catch { /* gone */ } };
    req.on('close', stopWait);
    req.on('error', stopWait);

    let last = null;
    const watch = (found) => {
      try {
        const sig = signature(found);
        if (sig !== last) { last = sig; send('graph', buildGraph(found)); }
        else send('idle', { at: Date.now() });
      } catch (e) {
        send('fault', { measured: false, reason: String(e?.message ?? e) });
      }
    };

    timer = setInterval(() => {
      const found = findSession(id);
      if (!found) return;                       // still waiting for the first turn
      clearInterval(timer);
      watch(found);
      timer = setInterval(() => watch(found), STREAM_TICK_MS);
    }, 1000);
    return undefined;
  }

  if (!session) {
    if (!id) { send('fault', { measured: false, reason: 'no session id given' }); return res.end(); }
    // A remote session is polled through its peer rather than watched: this
    // machine has no file to watch.
    let stopped = false;
    const pull = async () => {
      if (stopped) return;
      const relayed = await relay(`/api/session/${encodeURIComponent(id)}/graph`);
      if (stopped) return;
      if (relayed) send('graph', relayed);
      else { send('fault', { measured: false, reason: 'no such session on this machine or any peer' }); stop(); }
    };
    const timer2 = setInterval(pull, Math.max(STREAM_TICK_MS * 3, 2000));
    const stop = () => { stopped = true; clearInterval(timer2); try { res.end(); } catch { /* gone */ } };
    req.on('close', stop);
    req.on('error', stop);
    pull();
    return undefined;
  }

  let last = null;
  const tick = () => {
    try {
      const sig = signature(session);
      if (sig !== last) {
        last = sig;
        send('graph', buildGraph(session));
      } else {
        send('idle', { at: Date.now() });
      }
    } catch (e) {
      send('fault', { measured: false, reason: String(e?.message ?? e) });
    }
  };

  tick();
  const timer = setInterval(tick, STREAM_TICK_MS);
  const stop = () => { clearInterval(timer); try { res.end(); } catch { /* gone */ } };
  req.on('close', stop);
  req.on('error', stop);
}

/**
 * Open the panel in whatever the machine calls a browser.
 *
 * The URL carries a generated token, so copying it by hand is the one step
 * between starting the server and using it. Failure is reported rather than
 * assumed: a machine with no opener should say so, not look like it worked.
 */
function openBrowser(url) {
  const [cmd, args] = process.platform === 'darwin' ? ['open', [url]]
    : process.platform === 'win32' ? ['cmd', ['/c', 'start', '', url]]
      : ['xdg-open', [url]];
  try {
    const child = spawnDetached(cmd, args);
    child.on('error', (e) => {
      process.stdout.write(`            (could not open a browser: ${e.code ?? e.message})\n`);
    });
  } catch (e) {
    process.stdout.write(`            (could not open a browser: ${e?.message ?? e})\n`);
  }
}

function spawnDetached(cmd, args) {
  const child = spawn(cmd, args, { detached: true, stdio: 'ignore' });
  child.unref();
  return child;
}

/** The conversation of one owned session, replayed then followed. */
function ownedStream(req, res, url, session) {
  res.writeHead(200, {
    'content-type': 'text/event-stream; charset=utf-8',
    'cache-control': 'no-store',
    connection: 'keep-alive',
    'x-accel-buffering': 'no',
  });

  const write = (event, data) => {
    try { res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`); } catch { /* client gone */ }
  };

  // `after` lets a reconnecting client resume without replaying the whole
  // conversation, and without missing what it dropped.
  const after = Number(url.searchParams.get('after')) || 0;
  write('state', session.summary());

  const unsubscribe = session.subscribe((ev) => {
    write('event', ev);
    if (ev.rec?.type === 'result' || ev.rec?.type === 'exit') write('state', session.summary());
  }, after);

  const beat = setInterval(() => write('state', session.summary()), 15000);
  const stop = () => { clearInterval(beat); unsubscribe(); try { res.end(); } catch { /* gone */ } };
  req.on('close', stop);
  req.on('error', stop);
}

/** One terminal's output, replayed then followed. */
function ptyStream(req, res, terminal) {
  res.writeHead(200, {
    'content-type': 'text/event-stream; charset=utf-8',
    'cache-control': 'no-store',
    connection: 'keep-alive',
    'x-accel-buffering': 'no',
  });
  const write = (event, data) => {
    try { res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`); } catch { /* client gone */ }
  };
  write('state', terminal.summary());
  const unsubscribe = terminal.subscribe((msg) => write(msg.t === 'out' ? 'out' : 'state', msg.t === 'out' ? msg.d : terminal.summary()));
  const stop = () => { unsubscribe(); try { res.end(); } catch { /* gone */ } };
  req.on('close', stop);
  req.on('error', stop);
}

async function selftest() {
  const checks = [];
  const check = (name, ok, detail) => checks.push({ name, ok, detail });
  // A tool this machine does not have is an honest boundary, not a defect. The
  // spawn-cost probe needs the claude CLI, which CI installs only in the ubuntu
  // job — so on every other runner this said "skipped honestly" in its own detail
  // text and then counted itself a failure, taking e2e down with it.
  const skip = (name, detail) => checks.push({ name, skipped: true, detail });

  check('web root exists', fs.existsSync(WEB_ROOT), WEB_ROOT);
  check('index.html present', fs.existsSync(path.join(WEB_ROOT, 'index.html')), null);

  const fleet = await getFleet({ force: true });
  check(
    'fleet read returned a verdict',
    typeof fleet.measured === 'boolean',
    fleet.measured ? `${fleet.sessions.length} session(s)` : `not measured: ${fleet.reason}`,
  );

  const cost = await measureSpawnCost(3);
  if (cost === null) skip('spawn cost measured', 'claude CLI absent');
  else check('spawn cost measured', true, `min ${cost.minMs}ms · median ${cost.medianMs}ms · max ${cost.maxMs}ms`);

  for (const c of checks) {
    const tag = c.skipped ? 'SKIP' : c.ok ? 'PASS' : 'FAIL';
    process.stdout.write(`${tag} ${c.name}${c.detail ? ` — ${c.detail}` : ''}\n`);
  }
  // An empty run is a broken harness, not a clean bill of health.
  if (!checks.length) {
    process.stdout.write('FAIL selftest ran zero checks — the measurement is broken, not the server\n');
    return 1;
  }
  const skipped = checks.filter((c) => c.skipped).length;
  const graded = checks.filter((c) => !c.skipped);
  const failed = graded.filter((c) => !c.ok).length;
  process.stdout.write(`\n${graded.length - failed}/${graded.length} passed`
    + (skipped ? `, ${skipped} skipped` : '') + '\n');
  return failed ? 1 : 0;
}

async function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (e) {
    process.stderr.write(`csk-studio: ${e.message}\n`);
    process.exit(64);
  }

  if (args.help) {
    process.stdout.write(
      'csk-studio — visual orchestration panel for Claude Code\n\n' +
        '  --port <n>   port to listen on (default 7777, loopback only)\n' +
        '  --peer <url> another machine running Studio (repeatable)\n' +
        '  --enable-pty allow raw shells in the panel — these BYPASS the kit gates\n' +
        '  --open, -o   open the panel in a browser once it is listening\n' +
        '  --name <s>   label for this machine (default: hostname)\n' +
        '  --selftest   run offline checks and exit\n' +
        '  --help       this text\n\n' +
        'Set CSK_STUDIO_TOKEN to require a bearer token, CSK_STUDIO_PEERS for a\n' +
        'comma-separated peer list.\n\n' +
        'Peers are normally reached over a forwarded port, which keeps every\n' +
        'Studio on loopback:\n' +
        '  ssh -N -L 7778:127.0.0.1:7777 other-machine\n' +
        '  csk-studio --peer http://127.0.0.1:7778\n',
    );
    return;
  }

  if (args.selftest) {
    process.exit(await selftest());
  }

  const server = http.createServer((req, res) => {
    handle(req, res).catch((e) => {
      process.stderr.write(`csk-studio: unhandled: ${e?.stack ?? e}\n`);
      if (!res.headersSent) send(res, 500, 'internal error');
    });
  });

  server.on('error', (e) => {
    if (e.code === 'EADDRINUSE') {
      process.stderr.write(`csk-studio: port ${args.port} is already in use — try --port ${args.port + 1}\n`);
      process.exit(1);
    }
    throw e;
  });

  pty.enable(args.pty);
  PEERS = parsePeers([
    ...args.peers,
    ...(process.env.CSK_STUDIO_PEERS ?? '').split(',').map((x) => x.trim()).filter(Boolean),
  ]);
  SELF_NAME = args.name || os.hostname().replace(/\.local$/, '');

  server.listen(args.port, LOOPBACK, () => {
    const url = `http://${LOOPBACK}:${args.port}/?token=${TOKEN}`;
    process.stdout.write(`csk-studio  ${url}\n`);
    process.stdout.write(`            machine: ${SELF_NAME}\n`);
    if (args.pty) {
      process.stdout.write('            raw terminals: ENABLED — commands typed there bypass the kit gates\n');
    }
    if (PEERS.length) {
      for (const p of PEERS) {
        process.stdout.write(`            peer: ${p.error ? `${p.spec} — ${p.error}` : p.base}\n`);
      }
    }
    process.stdout.write(TOKEN_GENERATED
      ? '            (loopback only; token generated for this run)\n'
      : '            (loopback only; token from CSK_STUDIO_TOKEN)\n');

    if (args.open) openBrowser(url);

    // Say this once, to whoever is still typing the long path. Suppressed when
    // the process already came in under its bin name, and never written to
    // anyone's shell profile behind their back.
    const launchedAsBin = path.basename(process.argv[1] ?? '') === 'csk-studio';
    if (!launchedAsBin) {
      const dir = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
      process.stdout.write(
        `\n            For a shorter command, once:  npm install -g ${dir}\n`
        + `            then, from anywhere:          csk-studio --open\n`,
      );
    }
  });

  for (const sig of ['SIGINT', 'SIGTERM']) {
    process.on(sig, () => {
      // Children outlive their parent unless told otherwise, and a panel that
      // leaks running sessions is worse than one that never started them.
      stopAll();
      pty.closeAll();
      server.close(() => process.exit(0));
      setTimeout(() => process.exit(0), 2000).unref();
    });
  }
}

// Only when this file is the program. The self-check imports writeAllowed from
// here to exercise it rather than grep for it, and an import that silently
// opened a listening socket would make an offline gate not offline.
// Run only when invoked directly, never on import (the selfcheck imports this
// file). argv[1] must be resolved first: every global install path — `npm link`,
// `npm i -g`, Homebrew — puts a symlink on PATH, while import.meta.url is always
// the real file. Comparing them raw makes the command exit silently with rc 0.
function isDirectRun() {
  const entry = process.argv[1];
  if (!entry) return false;
  let real;
  try {
    real = fs.realpathSync(entry);
  } catch {
    real = entry;
  }
  return import.meta.url === pathToFileURL(real).href;
}

if (isDirectRun()) {
  main();
}
