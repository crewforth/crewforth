// Locating a project's transcripts on disk.
//
// Claude Code stores them under ~/.claude/projects/<encoded-cwd>/, where the
// encoding folds `: \ / . _` all down to `-`. That is lossy: two different
// directories can encode to the same name, so this asks the filesystem rather
// than trusting the spelling.
//
// Crewforth already solves this in bash (utilization.sh, context-usage.sh,
// session-stats.sh share one byte-identical block that smoke-test §6i3 pins).
// This is a re-implementation in another language on purpose — a fourth bash
// copy would break that pin.

// EVERY filesystem call here is async, and that is the point rather than a style
// choice. On a Windows machine a single synchronous 128 KiB tail read once took
// 31,209 ms, and because it blocked the event loop other requests waited with it:
// `/api/projects` took 33,391 ms and a separate `/api/health` on its own connection
// went unanswered for 312 of 324 pings. Measured later on the same machine with no
// kit code running, a plain `tail -c 131072` of a freshly copied 25 MB transcript
// waited 63-65 s right after the copy, 0.04 s warm, and 0.044 s when it waited 90 s
// first. What holds the file was not identified, and the wait could not be produced
// on demand. Async does not make the read faster; it keeps the wait inside the one
// request that hit it while the rest of the panel stays up.
import fsp from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

// Overridable so a second instance can be pointed at a different transcript
// store — which is also the only way to exercise the peer relay on one machine.
export const PROJECTS_ROOT = process.env.CREW_STUDIO_PROJECTS_ROOT
  || path.join(os.homedir(), '.claude', 'projects');

/** Fold a working directory into the directory name Claude Code uses. */
export function encodeCwd(cwd) {
  return cwd.replace(/[:\\/._]/g, '-');
}

/** Candidate directory names for a cwd, best first. */
export function candidateDirs(cwd) {
  const seen = new Set();
  const out = [];
  for (const c of [encodeCwd(cwd), cwd.replace(/[/.]/g, '-'), cwd.replace(/\//g, '-')]) {
    if (c && !seen.has(c)) { seen.add(c); out.push(c); }
  }
  return out;
}

/** The project directory for a cwd, or null when nothing was recorded yet. */
export async function projectDir(cwd) {
  for (const name of candidateDirs(cwd)) {
    const p = path.join(PROJECTS_ROOT, name);
    try { if ((await fsp.stat(p)).isDirectory()) return p; } catch { /* next */ }
  }
  return null;
}

/** Every project directory on this machine. */
export async function allProjectDirs() {
  try {
    const entries = await fsp.readdir(PROJECTS_ROOT, { withFileTypes: true });
    return entries.filter((e) => e.isDirectory()).map((e) => path.join(PROJECTS_ROOT, e.name));
  } catch {
    return [];
  }
}

// Sessions carry three kinds of name, in descending order of intent:
// a custom title the person typed, the agent name, and an AI-written topic.
// Reading them means scanning the transcript, and the sidebar refreshes on a
// timer over every session in the project — so only the tail is read (the
// latest record wins anyway) and the result is cached against size+mtime.
//
// The branch comes out of the same read. Every record carries `gitBranch`, and the last one in the tail is the
// branch the session is on now — a session can change branch, and the navigator names where it is, not where it
// began. A transcript with no such field, or an empty one (not a repository), yields null: the caller shows
// nothing rather than a branch nobody read.
const TITLE_TAIL_BYTES = 131072;
const titleCache = new Map(); // file -> { sig, title, branch }

export async function sessionTitle(file, size, mtimeMs) {
  return (await sessionTail(file, size, mtimeMs)).title;
}

export async function sessionTail(file, size, mtimeMs) {
  const sig = `${size}:${mtimeMs}`;
  const hit = titleCache.get(file);
  if (hit && hit.sig === sig) return { title: hit.title, branch: hit.branch };

  let title = null;
  let branch = null;
  let fh;
  try {
    fh = await fsp.open(file, 'r');
    const len = Math.min(size, TITLE_TAIL_BYTES);
    const buf = Buffer.allocUnsafe(len);
    await fh.read(buf, 0, len, Math.max(0, size - len));
    const text = buf.toString('utf8');

    // Cheap prefilter: most sessions carry none of these, and parsing every
    // line of a 128 KiB tail for all of them is wasted work.
    const found = { custom: null, agent: null, ai: null };
    if (/"(custom-title|agent-name|ai-title)"/.test(text)) {
      for (const line of text.split('\n')) {
        if (!line.startsWith('{')) continue;                 // tail cut mid-record
        if (!line.includes('-title"') && !line.includes('agent-name"')) continue;
        let r;
        try { r = JSON.parse(line); } catch { continue; }
        if (r.type === 'custom-title' && r.customTitle) found.custom = r.customTitle;
        else if (r.type === 'agent-name' && r.agentName) found.agent = r.agentName;
        else if (r.type === 'ai-title' && r.aiTitle) found.ai = r.aiTitle;
      }
    }
    title = found.custom ?? found.agent ?? found.ai ?? null;

    // In a record the key is followed by a bare quote; inside a quoted message every quote is escaped, so text
    // that merely mentions the field cannot match.
    let last = null;
    for (const m of text.matchAll(/"gitBranch"\s*:\s*"((?:[^"\\]|\\.)*)"/g)) last = m[1];
    if (last) {
      try { branch = JSON.parse(`"${last}"`) || null; } catch { branch = null; }
    }
  } catch {
    title = null;
    branch = null;
  } finally {
    if (fh !== undefined) try { await fh.close(); } catch { /* already gone */ }
  }

  if (titleCache.size > 500) titleCache.clear();
  titleCache.set(file, { sig, title, branch });
  return { title, branch };
}

// The working directory a session ran in. The encoded folder name cannot be
// decoded back — the fold is lossy — so it is read from the first record,
// which carries `cwd`. Head, not tail: the value never changes mid-session.
const cwdCache = new Map();

export async function sessionCwd(file, size) {
  const hit = cwdCache.get(file);
  if (hit && hit.size === size) return hit.cwd;

  let cwd = null;
  let fh;
  try {
    fh = await fsp.open(file, 'r');
    const len = Math.min(size, 8192);
    const buf = Buffer.allocUnsafe(len);
    await fh.read(buf, 0, len, 0);
    cwd = buf.toString('utf8').match(/"cwd"\s*:\s*"((?:[^"\\]|\\.)*)"/)?.[1] ?? null;
    if (cwd) cwd = cwd.replace(/\\\\/g, '\\').replace(/\\"/g, '"');
  } catch {
    cwd = null;
  } finally {
    if (fh !== undefined) try { await fh.close(); } catch { /* already gone */ }
  }

  if (cwdCache.size > 500) cwdCache.clear();
  cwdCache.set(file, { size, cwd });
  return cwd;
}

/**
 * Sessions inside one project directory.
 * The tree is `<sid>.jsonl` at the top and a `<sid>/subagents/` directory
 * beside it — counting only the top level is how you end up reporting that
 * nothing ever delegated.
 */
export async function listSessions(dir) {
  let entries;
  try { entries = await fsp.readdir(dir, { withFileTypes: true }); } catch { return []; }

  // One transcript's reads do not depend on another's, so they run together.
  // Sequential awaits cost 12 ms here where the synchronous version cost 7 —
  // measured, 10 runs each — and that gap grows with the number of sessions.
  // The order is irrelevant: the list is sorted by mtime below.
  const settled = await Promise.all(entries.map(async (e) => {
    if (!e.isFile() || !e.name.endsWith('.jsonl')) return null;
    const sessionId = e.name.slice(0, -'.jsonl'.length);
    const file = path.join(dir, e.name);
    let st;
    try { st = await fsp.stat(file); } catch { return null; }

    const subagentsDir = path.join(dir, sessionId, 'subagents');
    const [agentCount, tail, cwd] = await Promise.all([
      countAgentMetas(subagentsDir),
      sessionTail(file, st.size, st.mtimeMs),
      sessionCwd(file, st.size),
    ]);

    return {
      sessionId, file, subagentsDir, bytes: st.size, modifiedAt: st.mtimeMs, agentCount,
      title: tail.title, branch: tail.branch, cwd,
    };
  }));

  const out = settled.filter(Boolean);
  out.sort((a, b) => b.modifiedAt - a.modifiedAt);
  return out;
}

/** Find one session anywhere on this machine, by id. */
export async function findSession(sessionId) {
  if (!/^[A-Za-z0-9._-]+$/.test(sessionId)) return null; // it becomes a path
  for (const dir of await allProjectDirs()) {
    const file = path.join(dir, `${sessionId}.jsonl`);
    try {
      const st = await fsp.stat(file);
      return {
        sessionId,
        file,
        dir,
        subagentsDir: path.join(dir, sessionId, 'subagents'),
        bytes: st.size,
        modifiedAt: st.mtimeMs,
      };
    } catch { /* next project */ }
  }
  return null;
}

/**
 * How many agents a session spawned.
 *
 * Agents land in two places: directly in `subagents/`, and one level deeper
 * under `subagents/workflows/<id>/` when a workflow ran. Measured on this
 * machine, 324 of 596 metas — 54% — were in the nested form, so a flat read
 * silently reported a busy session as having delegated nothing.
 */
export async function countAgentMetas(subagentsDir) {
  return (await agentMetaFiles(subagentsDir)).length;
}

/** Every agent meta file under a subagents directory, nesting included. */
export async function agentMetaFiles(subagentsDir, depth = 0) {
  const out = [];
  if (depth > 3) return out;                    // workflows nest one level; this is slack
  let entries;
  try { entries = await fsp.readdir(subagentsDir, { withFileTypes: true }); } catch { return out; }
  for (const e of entries) {
    const p = path.join(subagentsDir, e.name);
    if (e.isDirectory()) out.push(...await agentMetaFiles(p, depth + 1));
    else if (e.name.endsWith('.meta.json')) out.push(p);
  }
  return out;
}

/**
 * The branch a directory is on NOW, read from its `.git/HEAD` and nowhere else.
 *
 * No process is started: a `git` per project per poll is the cost this file exists to avoid. A worktree's `.git`
 * is a file that points at its real git directory, and that pointer is followed once. A detached HEAD, a
 * directory that is not a repository's root, and a file that cannot be read all answer null: the caller then
 * names no branch, which is different from naming the one a session recorded last week.
 */
export async function headBranch(cwd) {
  if (!cwd) return null;
  const dot = path.join(cwd, '.git');
  let head;
  try {
    const st = await fsp.stat(dot);
    if (st.isDirectory()) {
      head = await fsp.readFile(path.join(dot, 'HEAD'), 'utf8');
    } else {
      const m = (await fsp.readFile(dot, 'utf8')).match(/^gitdir:\s*(.+?)\s*$/m);
      if (!m) return null;
      head = await fsp.readFile(path.join(path.resolve(cwd, m[1]), 'HEAD'), 'utf8');
    }
  } catch {
    return null;
  }
  const ref = head.match(/^ref:\s*refs\/heads\/(\S+)\s*$/m);
  return ref ? ref[1] : null;
}

/**
 * Every session on this machine, grouped by the project it ran in.
 *
 * Grouping is by the recorded `cwd` rather than by transcript folder: a folder
 * name is a lossy fold of the path, so two different projects can share one.
 * The folder is only the fallback when no record carried a cwd.
 */
export async function listProjects({ currentCwd = null, limitPerProject = 60, kitOf = null } = {}) {
  const groups = new Map();

  const dirs = await allProjectDirs();
  const perDir = await Promise.all(dirs.map(async (dir) => [dir, await listSessions(dir)]));

  for (const [dir, sessions] of perDir) {
    for (const s of sessions) {
      const key = s.cwd ?? `dir:${path.basename(dir)}`;
      if (!groups.has(key)) {
        groups.set(key, { key, cwd: s.cwd, dir, label: labelFor(s.cwd, dir), sessions: [] });
      }
      groups.get(key).sessions.push(s);
    }
  }

  const out = [];
  for (const g of groups.values()) {
    g.sessions.sort((a, b) => b.modifiedAt - a.modifiedAt);
    const kit = kitOf ? await kitOf(g.cwd) : null;
    out.push({
      ...g,
      kit,
      // Most transcript folders on a busy machine point at directories that no
      // longer exist — test scratch dirs, moved checkouts. They are counted,
      // not deleted: the panel says how many it is holding back rather than
      // quietly shortening the list.
      exists: kit?.dirExists ?? (g.cwd ? await existsCached(g.cwd) : false),
      // Where a session started here now would be working. Not the branch a session recorded: that one is on
      // each session row, and may be weeks old.
      branch: await headBranch(g.cwd),
      total: g.sessions.length,
      agentTotal: g.sessions.reduce((n, s) => n + s.agentCount, 0),
      modifiedAt: g.sessions[0]?.modifiedAt ?? 0,
      current: currentCwd != null && g.cwd === currentCwd,
      // Long histories are truncated rather than silently dropped, and the
      // count above still reports the whole.
      sessions: g.sessions.slice(0, limitPerProject),
    });
  }

  // Standing-in first, then live directories, then an outdated kit ahead of a
  // current one — the rows that need a decision float up.
  out.sort((a, b) =>
    Number(b.current) - Number(a.current) ||
    Number(b.exists) - Number(a.exists) ||
    Number(Boolean(b.kit?.outdated)) - Number(Boolean(a.kit?.outdated)) ||
    b.modifiedAt - a.modifiedAt);
  return out;
}

function labelFor(cwd, dir) {
  if (!cwd) return path.basename(dir);
  const parts = cwd.split(/[/\\]/).filter(Boolean);
  return parts[parts.length - 1] || cwd;
}

const existsMemo = new Map();
async function existsCached(p) {
  if (existsMemo.has(p)) return existsMemo.get(p);
  let v = false;
  try { await fsp.stat(p); v = true; } catch { v = false; }
  if (existsMemo.size > 2000) existsMemo.clear();
  existsMemo.set(p, v);
  return v;
}
