// Which projects run Crewforth, and which of them are behind.
//
// An installed project records its version in `.claude/VERSION` and its
// install shape in `.claude/kit.conf`. The published version comes from the
// same npm dist-tags feed Crewforth's own SessionStart hook reads, so the panel
// and the hook can never disagree about what "latest" means.
//
// Read-only. Detecting that a project is behind and updating it are different
// acts, and only the first one happens here.

import fsp from 'node:fs/promises';
import path from 'node:path';

const FEED = process.env.CREW_UPDATE_URL
  ?? 'https://registry.npmjs.org/-/package/crewforth/dist-tags';
const FEED_TTL_MS = 60 * 60 * 1000;   // the hook uses a day; a panel refreshes hourly
const FETCH_TIMEOUT_MS = 8000;

// How an install made of files is updated: the command, as the project's own update notice words it. It lives
// here and travels in the payload so that the panel never types a command of its own.
//
// It is given ONLY to a project that has `.claude/VERSION`. A plugin install leaves no file in the project, so
// from here it cannot be told from a project without Crewforth — and it does not update through npx. Such a
// project gets null, and the panel shows the `/crew-update` hint instead of a command it would have to invent.
const FILE_INSTALL_UPDATE = 'npx crewforth@latest update --here';

let latestCache = null;   // { at, value }
let inflight = null;

/**
 * The published version WITHOUT waiting for the network.
 *
 * Returns whatever is cached, and starts a refresh if the cache is cold or stale — but never
 * awaits it. Measured on a corporate machine: with the feed hanging, /api/projects took 8.37 s
 * because it awaited this, which is the whole FETCH_TIMEOUT_MS. The project list is local data;
 * it has no business waiting on a registry, and a user watching a 12-second blank reads it as a
 * hung panel rather than as a slow lookup they never asked for.
 *
 * The honesty rule is unchanged: an unfetched answer says so with a reason. It never renders as
 * "up to date". The reason simply becomes "not fetched yet" until the first refresh lands, and
 * the next request serves the real answer.
 */
export function latestVersionCached() {
  const fresh = latestCache && Date.now() - latestCache.at < FEED_TTL_MS;
  // Deferred to a later tick, not merely un-awaited, so the request path does no work of its own.
  //
  // The panel stall once pinned on this feed was never the feed: a run with the feed disabled
  // entirely stalled the same way. It was a synchronous transcript read on one Windows machine: one
  // 128 KiB tail took 31,209 ms, and the event loop waited with it. projects.js has the panel's
  // numbers and, kept apart from them, what was measured on that machine later. The reads are async
  // now, so such a wait stays inside one request. This line stays because starting work on a request
  // path is wrong regardless.
  if (!fresh && !inflight) {
    setTimeout(() => { latestVersion().catch(() => {}); }, 0).unref();
  }
  if (latestCache) return latestCache.value;
  return { measured: false, reason: 'not fetched yet', at: Date.now(), pending: true };
}

/** The published version, or a stated reason it could not be read. Awaits the network. */
export async function latestVersion({ force = false } = {}) {
  if (!force && latestCache && Date.now() - latestCache.at < FEED_TTL_MS) return latestCache.value;
  if (inflight) return inflight;

  inflight = (async () => {
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), FETCH_TIMEOUT_MS);
    try {
      const res = await fetch(FEED, { signal: ctl.signal });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const body = await res.json();
      const v = sane(body?.latest ?? body?.version);
      if (!v) throw new Error('feed carried no version');
      return { measured: true, version: v, at: Date.now() };
    } catch (e) {
      // Offline is a legitimate answer. It is reported, never rendered as
      // "everything is up to date".
      return { measured: false, reason: String(e?.message ?? e), at: Date.now() };
    } finally {
      clearTimeout(timer);
    }
  })()
    .then((value) => { latestCache = { at: Date.now(), value }; return value; })
    .finally(() => { inflight = null; });

  return inflight;
}

function sane(v) {
  if (typeof v !== 'string') return null;
  const m = v.trim().match(/^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/);
  return m ? m[0] : null;
}

/** Numeric-segment comparison. Returns <0, 0, >0. A pre-release sorts below its release. */
export function compareVersions(a, b) {
  const split = (v) => {
    const [core, pre] = String(v).split(/[-+]/, 2);
    return { nums: core.split('.').map((n) => parseInt(n, 10) || 0), pre: pre ?? null };
  };
  const x = split(a);
  const y = split(b);
  for (let i = 0; i < Math.max(x.nums.length, y.nums.length); i += 1) {
    const d = (x.nums[i] ?? 0) - (y.nums[i] ?? 0);
    if (d !== 0) return d;
  }
  if (x.pre && !y.pre) return -1;
  if (!x.pre && y.pre) return 1;
  if (x.pre && y.pre) return x.pre < y.pre ? -1 : x.pre > y.pre ? 1 : 0;
  return 0;
}

/** What Crewforth looks like inside one working directory.
 *
 * Async because it runs once per project on the `/api/projects` path, and a
 * synchronous read there blocks the whole panel when one read stalls —
 * see the note at the top of projects.js for the measurement.
 */
export async function kitStatus(cwd, latest) {
  if (!cwd) return { installed: false, reason: 'no working directory recorded' };

  const claude = path.join(cwd, '.claude');
  let version = null;
  try { version = sane(await fsp.readFile(path.join(claude, 'VERSION'), 'utf8')); } catch { /* not installed */ }

  if (!version) {
    // Distinguish "no kit here" from "the directory is gone" — one is a choice,
    // the other is a dead path.
    let present = false;
    try { await fsp.stat(cwd); present = true; } catch { present = false; }
    return {
      installed: false,
      dirExists: present,
      reason: present ? 'Crewforth not installed' : 'directory no longer exists',
      updateCommand: null,
    };
  }

  const conf = {};
  try {
    for (const line of (await fsp.readFile(path.join(claude, 'kit.conf'), 'utf8')).split('\n')) {
      const m = line.match(/^\s*([A-Za-z_]+)\s*=\s*(.*)$/);
      if (m) conf[m[1]] = m[2].trim();
    }
  } catch { /* older installs have no kit.conf */ }

  const out = {
    installed: true,
    dirExists: true,
    version,
    stack: conf.stack ?? null,
    installer: conf.installer ?? null,
    updateCommand: FILE_INSTALL_UPDATE,
  };

  if (!latest?.measured) {
    // Not measured is not "current". Saying a project is up to date because
    // the network was down is the one answer worse than saying nothing.
    out.compared = false;
    out.reason = latest?.reason ?? 'latest version not read';
    return out;
  }

  const d = compareVersions(version, latest.version);
  out.compared = true;
  out.latest = latest.version;
  out.outdated = d < 0;
  out.ahead = d > 0;                 // a dev machine can legitimately run ahead of npm
  return out;
}

export const _internals = { sane, FEED, FILE_INSTALL_UPDATE };
