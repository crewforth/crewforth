// What a session started here has changed in its directory, read from git.
//
// The commit the directory was on when the session started is recorded first; after that, the working tree is
// compared with it: `git diff-index --numstat <start>` for tracked files (what the session committed since counts too),
// and `git ls-files -o --exclude-standard` for new files git does not track yet. Nothing is staged to make a new
// file visible (no `add -N`), and the result is kept in memory only: it is never written anywhere.
//
// READ-ONLY. The plumbing `diff-index`, not `git diff`: measured on git 2.43, `git diff <commit>` rewrote the index
// to refresh a file whose time had changed, GIT_OPTIONAL_LOCKS=0 and --no-optional-locks notwithstanding (both are
// kept for `status`-like calls a later edit may add); `diff-index` reads the stat data and writes nothing. With
// `core.fsmonitor=` empty, a repository's own config cannot name a program for these calls to run; the diff runs
// with --no-ext-diff --no-textconv for the same reason.
//
// NOT MEASURED is said, not shown as zero: a directory that is not a repository, a git that is missing, or a call
// that fails gives `{ measured: false, reason }`.

import { execFile } from 'node:child_process';

const GIT_TIMEOUT_MS = 5000;
const MAX_BUFFER = 8 * 1024 * 1024;
const SAFE = ['-c', 'core.fsmonitor=', '-c', 'core.quotePath=false', '--no-optional-locks'];

function git(cwd, args) {
  return new Promise((resolve) => {
    execFile('git', [...SAFE, ...args], {
      cwd, timeout: GIT_TIMEOUT_MS, maxBuffer: MAX_BUFFER, windowsHide: true,
      env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', LC_ALL: 'C' },
    }, (err, stdout) => resolve(err ? null : String(stdout)));
  });
}

/** The commit `cwd` is on, or null (not a repository, no commit yet, no git). */
export async function headOf(cwd) {
  const out = await git(cwd, ['rev-parse', '--verify', '-q', 'HEAD^{commit}']);
  const sha = out?.trim();
  return sha && /^[0-9a-f]{40,64}$/.test(sha) ? sha : null;
}

/** Parse `git diff-index --numstat -z --no-renames`: "added\tremoved\tpath\0" per file, "-" for a binary file's counts. */
export function parseNumstat(text) {
  let files = 0; let added = 0; let removed = 0; let binary = 0;
  for (const rec of String(text ?? '').split('\0')) {
    const m = /^(-|\d+)\t(-|\d+)\t./s.exec(rec);
    if (!m) continue;
    files += 1;
    if (m[1] === '-' || m[2] === '-') { binary += 1; continue; }
    added += Number(m[1]); removed += Number(m[2]);
  }
  return { files, added, removed, binary };
}

/** Changes in `cwd` since `base` (a commit id). */
export async function readChanges(cwd, base) {
  if (!base) return { measured: false, reason: 'no commit was recorded when the session started' };
  const [diff, other] = await Promise.all([
    git(cwd, ['diff-index', '--numstat', '-z', '--no-renames', '--no-ext-diff', '--no-textconv', base, '--']),
    git(cwd, ['ls-files', '-o', '--exclude-standard', '-z']),
  ]);
  if (diff === null || other === null) return { measured: false, reason: 'git could not compare this directory' };
  const n = parseNumstat(diff);
  const untracked = other.split('\0').filter(Boolean).length;
  return { measured: true, base, ...n, untracked };
}

