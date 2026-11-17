// project-settings.js — a project's install settings, read and written by the panel (DECISIONS 2026-11-17, N45).
//
// Two files hold them, and the session can write neither (guard-write.sh / guard-bash.sh): `.claude/kit.conf`
// (visibility=, docs=) and `.claude/crew-model-rules` (`profile <name>`, `verify-timeout <seconds>`). The panel is the
// user's own process, so this is where the user changes them after the install. Beside each one it shows what git
// actually does with the files, because a setting says what was meant and git says what happens.
//
// Readers it must agree with: session-rehydrate.sh (anything but `shared` is private), profile.sh (`profile` line,
// the last one wins, standard when none), guard-agent-model.sh _am_verify_limit (last `verify-timeout` line, 1..560,
// 120 when none). A write touches only the lines of the key it sets and keeps every other line as it was.
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

export const CHOICES = Object.freeze({
  visibility: ['shared', 'private'],
  docs: ['shared', 'private'],
  profile: ['light', 'standard', 'strict'],
});
export const VERIFY_DEFAULT = 120;
export const VERIFY_MAX = 560;
// What git is asked about: the paths session-rehydrate.sh asks about.
const GIT_PATHS = Object.freeze({ claude: '.claude/settings.json', claudeMd: 'CLAUDE.md', docs: 'docs/PLAN.md' });

function readText(f) {
  try { return fs.readFileSync(f, 'utf8'); } catch { return null; }
}
const splitLines = (text) => (text ?? '').split(/\r?\n/);
const eolOf = (text) => (/\r\n/.test(text ?? '') ? '\r\n' : '\n');

function git(root, args) {
  try {
    return { rc: 0, out: execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 5000 }) };
  } catch (e) {
    return { rc: typeof e.status === 'number' ? e.status : -1, out: String(e.stdout ?? '') };
  }
}

/** What git does with each path the settings speak of: tracked, ignored. null when `root` is no git work tree. */
export function gitState(root) {
  if (git(root, ['rev-parse', '--is-inside-work-tree']).out.trim() !== 'true') return null;
  const out = {};
  for (const [k, p] of Object.entries(GIT_PATHS)) {
    out[k] = {
      path: p,
      tracked: git(root, ['ls-files', '--', p]).out.trim() !== '',
      ignored: git(root, ['check-ignore', '-q', '--', p]).rc === 0,
    };
  }
  return out;
}

/** The settings as the hooks read them. `{ installed: false }` when the project has no `.claude/`. */
export function readSettings(root) {
  const claude = path.join(root, '.claude');
  if (!fs.existsSync(claude)) return { installed: false };
  const confText = readText(path.join(claude, 'kit.conf'));
  const conf = {};
  for (const l of splitLines(confText)) {
    const m = /^([A-Za-z_]+)=(.*)$/.exec(l);
    if (m) conf[m[1]] = m[2];
  }
  let profile = 'standard'; let profileSet = false; let verifyTimeout = null;
  for (const raw of splitLines(readText(path.join(claude, 'crew-model-rules')))) {
    let m;
    if ((m = /^profile (light|standard|strict)$/.exec(raw))) { profile = m[1]; profileSet = true; }
    else if ((m = /^verify-timeout[ \t]+(\d+)$/.exec(raw))) {
      // As _am_verify_limit: over four digits is the cap; 0 is no setting; above the cap is the cap.
      const n = m[1].length > 4 ? VERIFY_MAX : Number(m[1]);
      verifyTimeout = n >= 1 ? Math.min(n, VERIFY_MAX) : null;
    }
  }
  return {
    installed: true,
    recorded: confText !== null,
    visibility: 'visibility' in conf ? (conf.visibility === 'shared' ? 'shared' : 'private') : null,
    docs: 'docs' in conf ? (conf.docs === 'shared' ? 'shared' : 'private') : null,
    profile,
    profileSet,
    verifyTimeout,
    verifyDefault: VERIFY_DEFAULT,
    verifyMax: VERIFY_MAX,
    git: gitState(root),
  };
}

/** Checks a requested change; returns `{ ok, set }` with only the keys asked for, or `{ ok: false, reason }`. */
export function checkChange(asked) {
  if (!asked || typeof asked !== 'object' || Array.isArray(asked)) return { ok: false, reason: 'expected an object of settings' };
  const set = {};
  for (const [k, v] of Object.entries(asked)) {
    if (k in CHOICES) {
      if (!CHOICES[k].includes(v)) return { ok: false, reason: `${k} must be one of ${CHOICES[k].join(', ')}` };
      set[k] = v;
    } else if (k === 'verifyTimeout') {
      if (v === null) { set[k] = null; continue; }
      if (!Number.isInteger(v) || v < 1 || v > VERIFY_MAX) return { ok: false, reason: `verifyTimeout must be a whole number from 1 to ${VERIFY_MAX}, or null for the default` };
      set[k] = v;
    } else {
      return { ok: false, reason: `unknown setting: ${k}` };
    }
  }
  if (!Object.keys(set).length) return { ok: false, reason: 'nothing to change' };
  return { ok: true, set };
}

function writeAtomic(file, text) {
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, text);
  fs.renameSync(tmp, file);
}

// Replaces the lines `drop` matches with `add` (null: only removes), keeping every other line and the file's line
// endings. The new line goes where the first dropped one stood, else at the end.
function rewrite(file, drop, add) {
  const text = readText(file);
  const eol = eolOf(text);
  const lines = text === null ? [] : splitLines(text);
  if (lines.length && lines[lines.length - 1] === '') lines.pop();
  const out = []; let placed = false;
  for (const l of lines) {
    if (drop(l)) { if (add !== null && !placed) { out.push(add); placed = true; } continue; }
    out.push(l);
  }
  if (add !== null && !placed) out.push(add);
  writeAtomic(file, out.length ? out.join(eol) + eol : '');
}

/** Writes a checked change (`checkChange(...).set`) into the project's files, then reads them back. */
export function writeSettings(root, set) {
  const claude = path.join(root, '.claude');
  if (!fs.existsSync(claude)) return { ok: false, reason: 'Crewforth is not installed in this project' };
  const conf = path.join(claude, 'kit.conf');
  const rules = path.join(claude, 'crew-model-rules');
  for (const k of ['visibility', 'docs']) {
    if (k in set) rewrite(conf, (l) => l.replace(/\r$/, '').startsWith(`${k}=`), `${k}=${set[k]}`);
  }
  if ('profile' in set) rewrite(rules, (l) => /^profile (light|standard|strict)\r?$/.test(l), `profile ${set.profile}`);
  if ('verifyTimeout' in set) {
    rewrite(rules, (l) => /^verify-timeout[ \t]/.test(l), set.verifyTimeout === null ? null : `verify-timeout ${set.verifyTimeout}`);
  }
  return { ok: true, settings: readSettings(root) };
}
