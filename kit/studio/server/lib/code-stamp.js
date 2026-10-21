// code-stamp.js — is the code this server runs still the code on disk?
//
// A server keeps the code it started with. An update replaces the files on disk, the page is served fresh from
// them, and the two disagree: measured in a real project, a server started before 3.2.0 answered the new Map
// view's /api/map with 404, which the view showed as "Not read — HTTP 404". The stamp is the size and mtime of
// every file of the server, taken at start and again when asked; when they differ, the page says to restart.
import fs from 'node:fs';
import path from 'node:path';

/** Size and mtime of every .js/.mjs/.sh file under `dir` (the server's own code), as one string. */
export function codeStamp(dir) {
  const parts = [];
  const walk = (d) => {
    let entries;
    try { entries = fs.readdirSync(d, { withFileTypes: true }); } catch { return; }
    for (const e of entries.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0))) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) { if (e.name !== 'node_modules') walk(p); continue; }
      if (!/\.(m?js|sh)$/.test(e.name)) continue;
      try { const st = fs.statSync(p); parts.push(`${path.relative(dir, p)}:${st.size}:${Math.round(st.mtimeMs)}`); } catch { /* gone */ }
    }
  };
  walk(dir);
  return parts.join('|');
}

/** Stamp the code now, and answer later whether it has changed on disk (re-read at most every `everyMs`). */
export function stampAtStart(dir, { everyMs = 5000, now = () => Date.now() } = {}) {
  const boot = codeStamp(dir);
  let last = boot; let at = now();
  return () => {
    if (now() - at >= everyMs) { last = codeStamp(dir); at = now(); }
    return { changed: last !== boot };
  };
}
