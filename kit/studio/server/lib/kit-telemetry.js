// What Crewforth already measures about itself.
//
// The panel does not recompute any of it. Each of these shells out to Crewforth's
// own tool and reports what it said, including when it said it could not
// answer — `gate-report.sh` exits 4 in a checkout that has no installed hooks,
// and that is a real answer, not an empty one.
//
// One distinction runs through the whole file. A gate event from an owned
// session's stream carries the moment it happened; a line in gate-log.tsv does
// not, because the format has no timestamp. Those are labelled differently all
// the way to the screen, because drawing an observation as an event would be
// the first thing here that is not true.

import { execFile } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const EXEC_TIMEOUT_MS = 10000;
const MAX_BUFFER = 8 * 1024 * 1024;

function run(cmd, args, opts = {}) {
  return new Promise((resolve) => {
    execFile(cmd, args, { timeout: EXEC_TIMEOUT_MS, maxBuffer: MAX_BUFFER, windowsHide: true, ...opts },
      (err, stdout, stderr) => resolve({
        code: err?.code ?? 0,
        stdout: stdout ?? '',
        stderr: stderr ?? '',
        failed: Boolean(err),
      }));
  });
}

/** Where Crewforth's own scripts live for a given project, if they do. */
function kitPaths(cwd) {
  const installed = path.join(cwd, '.claude');
  const source = path.join(cwd, 'kit');
  if (fs.existsSync(path.join(installed, 'hooks', 'guard-bash.sh'))) {
    return { kind: 'installed', hooks: path.join(installed, 'hooks'), evalDir: path.join(installed, 'eval') };
  }
  if (fs.existsSync(path.join(source, 'hooks', 'guard-bash.sh'))) {
    return { kind: 'source', hooks: path.join(source, 'hooks'), evalDir: path.join(source, 'eval') };
  }
  return null;
}

/* --------------------------------------------------------------- gate log */

/**
 * The gate decisions recorded on disk.
 *
 * Four tab-separated columns: verdict, section, rule, command. The command is
 * empty unless CREW_GATE_LOG_CMD=1 was set, and there is no timestamp at all —
 * both facts are returned rather than papered over.
 */
/**
 * Where the gate log is, by the rule the gates write by (eval/lib/gate-log.sh): .claude/gate-log.tsv, else the
 * repository's own .git/crewforth-gate-log.tsv (a project that tracks .claude/ has it there), searched from the
 * project root up. null when there is none yet.
 */
export function gateLogPath(cwd) {
  const own = path.join(cwd, '.claude', 'gate-log.tsv');
  if (fs.existsSync(own)) return own;
  let d = cwd;
  for (let n = 0; n < 12; n += 1) {
    const g = path.join(d, '.git');
    let st = null;
    try { st = fs.statSync(g); } catch { /* not here */ }
    if (st?.isDirectory()) { const f = path.join(g, 'crewforth-gate-log.tsv'); return fs.existsSync(f) ? f : null; }
    if (st?.isFile()) {
      const m = /^gitdir: (.+)$/m.exec(fs.readFileSync(g, 'utf8'));
      if (!m) return null;
      const gd = path.resolve(d, m[1].trim()); const f = path.join(gd, 'crewforth-gate-log.tsv');
      return fs.existsSync(f) ? f : null;
    }
    const up = path.dirname(d); if (up === d) return null; d = up;
  }
  return null;
}

export function gateLog(cwd, { limit = 200 } = {}) {
  const file = gateLogPath(cwd);
  let st;
  try { st = fs.statSync(file ?? ''); } catch {
    return { measured: false, reason: 'no gate log in this project yet (.claude/gate-log.tsv, or .git/crewforth-gate-log.tsv where .claude/ is tracked)', entries: [] };
  }

  // Only the tail: this file reached 21,730 lines in Crewforth's own checkout and
  // the panel wants the recent end of it.
  const TAIL = 256 * 1024;
  let text = '';
  let fd;
  try {
    fd = fs.openSync(file, 'r');
    const len = Math.min(st.size, TAIL);
    const buf = Buffer.allocUnsafe(len);
    fs.readSync(fd, buf, 0, len, Math.max(0, st.size - len));
    text = buf.toString('utf8');
  } catch {
    return { measured: false, reason: 'gate log could not be read', entries: [] };
  } finally {
    if (fd !== undefined) try { fs.closeSync(fd); } catch { /* gone */ }
  }

  const lines = text.split('\n');
  if (st.size > TAIL) lines.shift();          // the first line was cut mid-record
  const entries = [];
  for (const line of lines) {
    if (!line.trim()) continue;
    const [verdict, section, rule, command] = line.split('\t');
    if (!verdict) continue;
    entries.push({ verdict, section: section ?? null, rule: rule ?? null, command: command || null });
  }

  const counts = {};
  for (const e of entries) counts[e.verdict] = (counts[e.verdict] ?? 0) + 1;

  return {
    measured: true,
    file,
    total: entries.length,
    truncated: st.size > TAIL,
    counts,
    // Stated, not implied. The panel renders these as "observed", never as
    // something that happened at a known time.
    timestamped: false,
    commandsRecorded: entries.some((e) => e.command),
    entries: entries.slice(-limit).reverse(),
  };
}

/* ------------------------------------------------------------ gate report */

/** Crewforth's own inventory of gates, via gate-report.sh --json. */
export async function gateReport(cwd) {
  const kit = kitPaths(cwd);
  if (!kit) return { measured: false, reason: 'Crewforth is not installed in this project' };

  const script = path.join(kit.evalDir, 'gate-report.sh');
  if (!fs.existsSync(script)) return { measured: false, reason: 'gate-report.sh is not present' };

  // The script finds the hooks relative to where it is run: `./.claude/hooks`
  // in an installed project, `./hooks` otherwise. In Crewforth's own checkout
  // that second shape only resolves from inside kit/, and the log it
  // should read is one level up. Both layouts are given what they expect rather
  // than the script being asked to guess.
  const from = kit.kind === 'installed' ? cwd : path.dirname(kit.hooks);
  const logPath = gateLogPath(cwd);
  const env = { ...process.env };
  if (logPath) env.CREW_GATE_LOG = logPath;

  const r = await run('bash', [script, '--json'], { cwd: from, env });
  // 3 means there is no log to read, which the script calls "not an error"; 4
  // means it could not find the hooks. Both are answers.
  if (r.code === 3) return { measured: false, reason: 'no gate log to report on' };
  if (r.code === 4) return { measured: false, reason: 'gate-report could not find the hooks from here' };
  try {
    return { measured: true, ...JSON.parse(r.stdout) };
  } catch {
    return { measured: false, reason: r.stderr.trim().slice(0, 200) || 'gate-report produced no JSON' };
  }
}

/* --------------------------------------------------------- session stats */

/** session-stats.sh --raw: fifteen key=value metrics about one transcript. */
export async function sessionStats(cwd, transcriptFile) {
  const kit = kitPaths(cwd);
  if (!kit) return { measured: false, reason: 'Crewforth is not installed in this project' };

  const script = path.join(kit.hooks, 'session-stats.sh');
  if (!fs.existsSync(script)) return { measured: false, reason: 'session-stats.sh is not present' };
  if (!transcriptFile || !fs.existsSync(transcriptFile)) {
    return { measured: false, reason: 'no transcript to read' };
  }

  const r = await run('bash', [script, '--raw', transcriptFile], { cwd });
  const metrics = {};
  for (const line of r.stdout.split('\n')) {
    const m = line.match(/^([a-z_]+)=(-?\d+)$/);
    if (m) metrics[m[1]] = Number(m[2]);
  }
  if (!Object.keys(metrics).length) {
    return { measured: false, reason: r.stderr.trim().slice(0, 200) || 'session-stats produced no metrics' };
  }
  return { measured: true, metrics };
}

/* ----------------------------------------------------------------- board */

/** The team board, if this repo has one. */
export async function board(cwd) {
  const kit = kitPaths(cwd);
  if (!kit) return { measured: false, reason: 'Crewforth is not installed in this project' };

  const script = path.join(kit.hooks, 'board.sh');
  if (!fs.existsSync(script)) return { measured: false, reason: 'board.sh is not present' };

  const r = await run('bash', [script, 'status'], { cwd });
  const text = r.stdout.trim();
  // "No board in this repo yet" is a state, not a failure — a project that
  // never opened one should read as exactly that.
  if (/no board/i.test(text)) return { measured: true, present: false, text };
  if (!text) return { measured: false, reason: r.stderr.trim().slice(0, 200) || 'board.sh said nothing' };
  return { measured: true, present: true, text };
}

export const _internals = { kitPaths };
