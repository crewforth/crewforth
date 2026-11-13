// Ending a session this server did not start.
//
// Studio can only read a session another process holds, and that process can outlive the window that showed it:
// measured here, a desktop session's process sat on an unanswered permission prompt for 18.7 hours after its window
// was gone. While it lives, Continue here can only start a copy (two writers on one transcript is corruption), and
// the Live tab keeps listing it. Ending it is the way out of both.
//
// It is a signal to a real process, so every step that could hit the wrong one is a refusal:
//   - the fleet must list this session, on this machine, with this pid, at the moment of asking;
//   - Claude Code's own status file for that pid must name this session (a pid is reused once its process is gone);
//   - the pid must not be this server or one of its ancestors: a session that runs Studio as a shell command
//     (measured: `node .claude/studio/server/index.js` under a CLI session) would take the panel down with it.
// What is sent is SIGTERM, the signal a terminal's close sends; Claude Code writes its transcript as it goes, so the
// history stays. Nothing escalates to SIGKILL here: a process that does not leave is reported as still running.

import { execFile } from 'node:child_process';
import { getFleet } from './fleet.js';
import { statusFile, sessionsRoot } from './activity.js';

const WAIT_MS = 5000;
const STEP_MS = 100;

function alive(pid) {
  try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; }
}

function parentOf(pid) {
  return new Promise((resolve) => {
    execFile('ps', ['-o', 'ppid=', '-p', String(pid)], { timeout: 2000, windowsHide: true }, (err, out) => {
      const n = Number.parseInt(String(out ?? '').trim(), 10);
      resolve(err || !Number.isInteger(n) ? null : n);
    });
  });
}

/**
 * This process and the processes above it. `ps` answers on macOS and Linux; where it does not (Windows), the chain
 * stops at the parent Node reports, which is the shell a session would have started the server in.
 */
export async function ancestry(start = process.pid, parent = parentOf) {
  const out = new Set([start, process.ppid]);
  let at = start;
  for (let i = 0; i < 32; i += 1) {
    const up = await parent(at);
    if (!up || up <= 1 || out.has(up)) { if (up) out.add(up); break; }
    out.add(up);
    at = up;
  }
  return out;
}

/**
 * @returns {ok, ended, reason?, status}  status is the HTTP answer: 200 ended or still running, 404 not on this
 *          machine, 409 refused because the pid could not be shown to be this session's or would end the server.
 */
export async function endForeignSession({ sessionId, pid }, {
  fleet = getFleet, root = sessionsRoot(), mine = ancestry, signal = (p) => process.kill(p, 'SIGTERM'), waitMs = WAIT_MS,
} = {}) {
  if (typeof sessionId !== 'string' || !/^[A-Za-z0-9-]+$/.test(sessionId)) return { ok: false, status: 400, reason: 'not a session id' };
  if (!Number.isInteger(pid) || pid <= 1) return { ok: false, status: 400, reason: 'not a process id' };

  const now = await fleet({ force: true });
  if (now?.measured === false) return { ok: false, status: 409, reason: `the machine's session list could not be read: ${now.reason ?? 'no reason given'}` };
  const row = (now?.sessions ?? []).find((s) => s.sessionId === sessionId);
  if (!row) return { ok: false, status: 404, reason: 'this machine does not list that session as running' };
  if (row.pid !== pid) return { ok: false, status: 409, reason: `that session runs as process ${row.pid ?? 'unknown'}, not ${pid}` };
  if (!(await statusFile(pid, sessionId, root))) {
    return { ok: false, status: 409, reason: 'Claude Code\'s own record for that process does not name this session, so it is not ended' };
  }
  if ((await mine()).has(pid)) {
    return { ok: false, status: 409, reason: 'that session runs this Studio server: ending it would stop the panel too. End it where it runs.' };
  }

  try { signal(pid); } catch (e) {
    return { ok: false, status: 409, reason: `the signal was refused: ${e.code ?? e.message}` };
  }
  // Gone is either of two things. The process is gone; or Claude Code removed its own status file, which it does on
  // the way out. Measured with a real CLI session: SIGTERM, exit 143, the status file removed and the fleet no longer
  // listing it, while its pid still answered for as long as its parent had not collected it.
  const gone = async () => !alive(pid) || !(await statusFile(pid, sessionId, root));
  const until = Date.now() + waitMs;
  while (Date.now() < until) {
    // The fleet is read again before answering: its cache still lists the session, and Continue here asks it next.
    if (await gone()) { await fleet({ force: true }); return { ok: true, status: 200, ended: true }; }
    await new Promise((r) => setTimeout(r, STEP_MS));
  }
  return (await gone())
    ? { ok: true, status: 200, ended: true }
    : { ok: true, status: 200, ended: false, reason: `asked to end; still running after ${waitMs / 1000}s` };
}
