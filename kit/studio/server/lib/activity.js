// When did a live session last do anything?
//
// `claude agents --json` says what state a session is in, not since when. Measured on this machine: a desktop
// session listed as "waiting · permission prompt" had been waiting 18.7 hours, its transcript untouched since the
// prompt was raised and the window that would have shown the prompt long gone. A CLI session listed as "busy" had
// ended its turn three hours earlier; its own status file said "shell", a shell command still running in it. Both
// read as live work on the Live tab, and the one that waited was counted as needing the viewer.
//
// So each local row gets two clocks, both read from files Claude Code already writes, and the later of the two:
//   statusSince  the session's own status file, <config>/sessions/<pid>.json, `statusUpdatedAt`
//   lastWriteAt  its transcript, and every agent transcript under it (an agent writes while its parent is silent)
// A clock that could not be read is null, never 0 or now: "not read" is not "quiet since 1970" or "active now".
//
// The status file also carries the session's own word for its state (`rawStatus`), which can be finer than the
// CLI's: "shell" arrives as "busy". The file is Claude Code's, undocumented, and read only if its `sessionId`
// matches the row's: a pid is reused once its process is gone.

import fsp from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { findSession } from './projects.js';

const CACHE_MS = 5000;
const cache = new Map();   // sessionId -> { at, value }

/** <config>/sessions, the config dir resolved the way projects.js resolves it. */
export function sessionsRoot(env = process.env, home = os.homedir()) {
  if (env.CREW_STUDIO_SESSIONS_ROOT) return env.CREW_STUDIO_SESSIONS_ROOT;
  const config = env.CLAUDE_CONFIG_DIR ? path.resolve(env.CLAUDE_CONFIG_DIR) : path.join(home, '.claude');
  return path.join(config, 'sessions');
}

/** The status file of one process, or null when there is none or it belongs to another session. */
export async function statusFile(pid, sessionId, root = sessionsRoot()) {
  if (!Number.isInteger(pid) || pid <= 0) return null;
  try {
    const row = JSON.parse(await fsp.readFile(path.join(root, `${pid}.json`), 'utf8'));
    if (!row || row.sessionId !== sessionId) return null;
    return row;
  } catch {
    return null;
  }
}

/** The latest mtime of any transcript under a directory, nesting included; null when there is none. */
async function latestJsonl(dir, depth = 0) {
  if (depth > 3) return null;
  let entries;
  try { entries = await fsp.readdir(dir, { withFileTypes: true }); } catch { return null; }
  let latest = null;
  for (const e of entries) {
    const p = path.join(dir, e.name);
    let t = null;
    if (e.isDirectory()) t = await latestJsonl(p, depth + 1);
    else if (e.name.endsWith('.jsonl')) { try { t = (await fsp.stat(p)).mtimeMs; } catch { /* gone */ } }
    if (t !== null && (latest === null || t > latest)) latest = t;
  }
  return latest;
}

const later = (a, b) => (a === null ? b : b === null ? a : Math.max(a, b));

/**
 * @param row  a normalised fleet row (fleet.js)
 * @returns { statusSince, lastWriteAt, activityAt, rawStatus, entrypoint } — every clock epoch ms or null
 */
export async function activityOf(row, { root = sessionsRoot(), find = findSession } = {}) {
  const status = await statusFile(row.pid, row.sessionId, root);
  const statusSince = typeof status?.statusUpdatedAt === 'number' ? status.statusUpdatedAt : null;
  let lastWriteAt = null;
  const found = await find(row.sessionId);
  if (found) lastWriteAt = later(found.modifiedAt ?? null, await latestJsonl(path.join(found.dir, row.sessionId)));
  return {
    statusSince,
    lastWriteAt,
    activityAt: later(statusSince, lastWriteAt),
    rawStatus: typeof status?.status === 'string' ? status.status : null,
    entrypoint: typeof status?.entrypoint === 'string' ? status.entrypoint : null,
  };
}

/** The rows with their clocks. Cached per session for a few seconds: the fleet is polled every two. */
export async function withActivity(rows, opts) {
  const now = Date.now();
  const listed = new Set(rows.map((r) => r.sessionId));
  for (const id of cache.keys()) if (!listed.has(id)) cache.delete(id);
  return Promise.all(rows.map(async (r) => {
    const hit = cache.get(r.sessionId);
    if (hit && now - hit.at < CACHE_MS && hit.pid === r.pid) return { ...r, ...hit.value };
    const value = await activityOf(r, opts);
    cache.set(r.sessionId, { at: now, pid: r.pid, value });
    return { ...r, ...value };
  }));
}
