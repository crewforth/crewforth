// project.mjs — what the scanner may read, how it reads it, and how a fact is cited.
//
// One listing per run: `git ls-files` when the root is in a work tree (it honours .gitignore, which is what the
// project itself calls its source), a directory walk otherwise. Every other read happens inside Node, so the cost
// of a scan does not grow with a process per file — on Git Bash a process is tens of milliseconds.

import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

// Directories that hold output, dependencies or tool state, never the project's own source. `.claude` is
// Crewforth itself: its hooks read environment variables the project never defines, and would be reported as missing.
export const SKIP_DIRS = new Set(['.git', '.hg', '.svn', 'node_modules', 'bower_components', 'bin', 'obj', 'dist', 'build',
  'out', 'target', 'vendor', '.venv', 'venv', 'env', '__pycache__', '.mypy_cache', '.pytest_cache', '.tox', '.gradle',
  '.idea', '.vs', '.vscode', '.next', '.nuxt', '.svelte-kit', 'coverage', '.crewforth', '.claude', '.terraform']);
const MAX_BYTES = 2 * 1024 * 1024;

// Every child process the scanner starts goes through here, so the gate can count them.
export const spawned = { count: 0 };
export function run(cmd, args, cwd) {
  spawned.count++;
  const r = spawnSync(cmd, args, { cwd, encoding: 'buffer', maxBuffer: 256 * 1024 * 1024, windowsHide: true,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', LC_ALL: 'C' } });
  return { ok: r.status === 0 && !r.error, out: r.stdout ? r.stdout.toString('utf8') : '' };
}

const skipped = (rel) => rel.split('/').some((seg) => SKIP_DIRS.has(seg));

export function openProject(root) {
  const real = fs.realpathSync(root);
  let files = null; let commit = null;
  const git = run('git', ['ls-files', '-co', '--exclude-standard', '-z'], real);
  if (git.ok) {
    files = git.out.split('\0').filter((f) => f && !skipped(f)).filter((f) => {
      try { return fs.lstatSync(path.join(real, f)).isFile(); } catch { return false; }
    });
    const head = run('git', ['rev-parse', '--verify', '-q', 'HEAD'], real);
    if (head.ok && /^[0-9a-f]{40,64}\s*$/.test(head.out)) commit = head.out.trim();
  } else {
    files = [];
    const walk = (dir, rel) => {
      let names; try { names = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
      for (const d of names) {
        const r = rel ? `${rel}/${d.name}` : d.name;
        if (d.isDirectory()) { if (!SKIP_DIRS.has(d.name)) walk(path.join(dir, d.name), r); }
        else if (d.isFile()) files.push(r);
      }
    };
    walk(real, '');
  }
  files = [...new Set(files)].sort();
  const cache = new Map();
  const tooBig = [];
  // { text, lines } or null (unreadable, binary or over the size limit)
  const read = (rel) => {
    if (cache.has(rel)) return cache.get(rel);
    let r = null;
    try {
      const abs = path.join(real, rel);
      const st = fs.statSync(abs);
      if (st.size > MAX_BYTES) tooBig.push(rel);
      else {
        const buf = fs.readFileSync(abs);
        if (!buf.subarray(0, 8000).includes(0)) {
          const text = buf.toString('utf8').replace(/^﻿/, '');
          r = { text, lines: text.split('\n').map((l) => l.replace(/\r$/, '')) };
        }
      }
    } catch { r = null; }
    cache.set(rel, r);
    return r;
  };
  return { root: real, files, commit, read, tooBig, git: git.ok };
}

// A citation. `anchor` must be a piece of the cited line (the validator checks it, collapsing whitespace); the
// scanner always cites the NAME it matched — a package, a key, a route — never a configuration value.
export function ev(file, line, anchor) {
  return { file, line, text: String(anchor) };
}
// A citation of a file as a whole: the first token of its first line that has something on it. Never the line
// itself: line 1 of a requirements file is often `--extra-index-url https://user:pass@host`. null when the file
// has no such line, and then there is nothing to cite.
export function evFirst(file, lines) {
  const i = lines.findIndex((l) => /[^\s]/.test(l));
  if (i < 0) return null;
  const tok = /^\s*([^\s:@/?#=]+)/.exec(lines[i]);
  return ev(file, i + 1, tok ? tok[1] : lines[i].trim()[0]);
}
export const evKey = (e) => `${e.file}\u0000${String(e.line).padStart(9, '0')}\u0000${e.text}`;
export function sortEv(list) {
  const seen = new Set(); const out = [];
  for (const e of [...list].sort((a, b) => (evKey(a) < evKey(b) ? -1 : evKey(a) > evKey(b) ? 1 : 0))) {
    const k = evKey(e); if (!seen.has(k)) { seen.add(k); out.push(e); }
  }
  return out;
}

// The 1-based line of the first line in `lines` matching `re` (a RegExp), from `from` (0-based), or 0.
export function lineOf(lines, re, from = 0) {
  for (let i = from; i < lines.length; i++) if (re.test(lines[i])) return i + 1;
  return 0;
}

// Files whose lines carry configuration VALUES. Their citations keep the key as the anchor and are never given
// a sha256: a hash of a line like `DB_PASSWORD=hunter2` is an offline oracle for a weak password.
export function bearsValues(rel) {
  const b = rel.split('/').pop().toLowerCase();
  return b.startsWith('.env') || /^appsettings.*\.json$/.test(b) || /^requirements[^/]*\.txt$/.test(b) || ['.npmrc', 'pip.conf', '.pypirc', 'setup.cfg'].includes(b) || /^application.*\.(properties|ya?ml)$/.test(b)
    || /^(docker-)?compose.*\.ya?ml$/.test(b) || b === 'dockerfile' || b.endsWith('.dockerfile') || /^secrets?\./.test(b);
}

// A test, a fixture or an example: its routes, URLs and environment reads describe a fake system, not this one.
export const isTestPath = (rel) => /(^|\/)(tests?|__tests__|spec|specs|fixtures?|e2e|testdata|examples?|[\w-]*-test)(\/|$)|\.(test|spec)\.[\w]+$|(^|\/)test_[^/]*\.py$|_test\.go$|Tests?\.cs$|Tests?\.(java|kt)$/i.test(rel);
// A host that is this machine or a name reserved for tests and documentation is not an external resource.
export const isLocalHost = (h) => !h || /^(localhost|127\.\d+\.\d+\.\d+|0\.0\.0\.0|\[::1\]|::1)(:\d*)?$/.test(h) || /\.(invalid|example|test|localhost)(:\d*)?$/.test(h);

// A line that must not be hashed and a quote that must be cut: credentials in a URL, or a secret pattern.
export const CRED_URL = /[a-z][a-z0-9+.-]*:\/\/[^/\s@'"`]*@/i;
const QUERY_SECRET = /[?&][\w.-]*(key|token|secret|sig|signature|password|pwd|auth)[\w.-]*=/i;
export function risky(text, patterns) {
  let at = -1;
  for (const re of [CRED_URL, QUERY_SECRET, ...(patterns || [])]) {
    const m = re.exec(text); if (m && (at < 0 || m.index < at)) at = m.index;
  }
  return at;
}

// ---- secret masking -----------------------------------------------------------------------------------------
// A host is the only part of a connection string or URL the map keeps. Credentials are cut off first; then a host
// that looks like a secret by Crewforth's own scanner patterns is replaced. Without those patterns every host is
// replaced: a map with fewer names is a smaller loss than one that published a token.
export function loadSecretPatterns(fromDir) {
  for (const rel of ['../../../hooks/secret-blocklist.txt', '../../../../hooks/secret-blocklist.txt']) {
    const f = path.join(fromDir, rel);
    let text; try { text = fs.readFileSync(f, 'utf8'); } catch { continue; }
    const out = [];
    for (const raw of text.split('\n')) {
      const l = raw.replace(/\r$/, '');
      if (!l || l.startsWith('#')) continue;
      const js = l.replace(/\[\[:alnum:\]\]/g, '[A-Za-z0-9]').replace(/\[:alnum:\]/g, 'A-Za-z0-9')
        .replace(/\[:space:\]/g, '\\s').replace(/\[:alpha:\]/g, 'A-Za-z').replace(/\[:digit:\]/g, '0-9');
      try { out.push(new RegExp(js)); } catch { /* a pattern JS cannot read is skipped; the rest still apply */ }
    }
    if (out.length) return out;
  }
  return null;
}

export const MASK = '[masked]';
export function makeHostFilter(patterns) {
  return (raw) => {
    if (!raw) return null;
    let h = String(raw).trim().toLowerCase();
    h = h.replace(/^[a-z][a-z0-9+.-]*:\/\//, '');
    // Userinfo first: a password may hold '/', '?' or '#', so the authority is only known after the last '@'.
    if (h.includes('@')) h = h.slice(h.lastIndexOf('@') + 1);
    h = h.split(/[/?#]/)[0].replace(/:$/, '');
    if (!/^[a-z0-9.\-[\]]+(:\d+)?$/.test(h) || h === '') return MASK;
    // Only the host is kept, so only the host is judged: a token elsewhere in the value is never stored.
    return patterns.some((re) => re.test(h)) ? MASK : h;
  };
}
