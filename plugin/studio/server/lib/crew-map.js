// What Crewforth's crew map says about a project, for the Map view.
//
// The map is `.crewforth/crew-map.json`, written by Crewforth's scanner (kit/eval/lib/crew-map/scan.mjs): the
// project's modules, the external resources it touches, the endpoints it provides and calls, and the findings
// between them, every one citing file:line. This file reads it and runs nothing that writes: no scan is started
// from here, and a map that is not on disk is said to be missing. The one process it starts is `git rev-list
// --count`, to say how far the project has moved since the commit the map was scanned at.
//
// Compare with: another project's map is read the same way. The scanner already says which of a project's calls
// no endpoint in that project provides (they go somewhere else); those are the calls compared here. One the other
// project provides is a match, one it does not is missing.

import fs from 'node:fs';
import path from 'node:path';
import { execFile } from 'node:child_process';

export const MAP_FILE = path.join('.crewforth', 'crew-map.json');
// How a project writes its map, said wherever a map is missing. The one place it is written: the view and the
// page show what the server sends.
export const WRITER = 'bash .claude/eval/lib/crew-map/crew-map.sh';
export const SCHEMA = /^crewforth\.crew-map\/1$/;
const MAX_BYTES = 8 * 1024 * 1024;
const GIT_TIMEOUT_MS = 5000;

const maps = new Map();               // cwd -> { sig, value }
export const _stats = { parsed: 0 };  // how many times a map was really read: the claims count it

/**
 * The map of one project, read once and kept until the file changes (its time or its size).
 * @returns { measured: true, file, bytes, doc } or { measured: false, reason }
 */
export function readMap(cwd) {
  const file = path.join(cwd, MAP_FILE);
  let st;
  try { st = fs.statSync(file); } catch {
    return { measured: false, missing: true, reason: `no ${MAP_FILE.replaceAll('\\', '/')} in this project. Write one there with: ${WRITER}` };
  }
  const sig = `${st.mtimeMs}:${st.size}`;
  const hit = maps.get(cwd);
  if (hit && hit.sig === sig) return hit.value;
  const value = parseMap(file, st.size);
  _stats.parsed += 1;
  if (maps.size > 50) maps.clear();
  maps.set(cwd, { sig, value });
  return value;
}

function parseMap(file, size) {
  const shown = MAP_FILE.replaceAll('\\', '/');
  // Read whole or not at all: half a map would draw modules without the edges that belong to them.
  if (size > MAX_BYTES) return { measured: false, reason: `${shown} is ${size} bytes, over the ${MAX_BYTES} Studio reads` };
  let doc;
  try { doc = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (e) { return { measured: false, reason: `${shown} is not JSON (${e.message.slice(0, 80)})` }; }
  if (!SCHEMA.test(String(doc?.schema))) return { measured: false, reason: `${shown} says schema ${JSON.stringify(doc?.schema ?? null)}, and Studio reads crewforth.crew-map/1` };
  for (const k of ['nodes', 'edges', 'findings', 'notMeasured']) {
    if (!Array.isArray(doc[k])) return { measured: false, reason: `${shown} has no ${k} list` };
  }
  return { measured: true, file: shown, bytes: size, doc };
}

/**
 * How many commits HEAD is past the commit the map was scanned at: { count } or { count: null, reason }.
 * Only a commit id is handed to git, so nothing in the file can become an option.
 */
export function behindOf(cwd, commit) {
  if (typeof commit !== 'string' || !/^[0-9a-f]{7,64}$/.test(commit)) return Promise.resolve({ count: null, reason: 'the map names no commit' });
  return new Promise((resolve) => {
    execFile('git', ['rev-list', '--count', `${commit}..HEAD`], { cwd, timeout: GIT_TIMEOUT_MS, windowsHide: true }, (err, stdout) => {
      const n = Number.parseInt(String(stdout).trim(), 10);
      if (err || !Number.isFinite(n)) resolve({ count: null, reason: 'git could not say (the commit may not be in this clone)' });
      else resolve({ count: n });
    });
  });
}

/** One endpoint as it is matched: the method, and the path with each parameter written as one `*`. */
export function endpointKey(e) {
  const p = String(e?.path ?? '').split('?')[0].replace(/\/+$/, '') || '/';
  const segs = p.split('/').map((s) => (/^(:\w+|\{[^}]*\}|<[^>]*>|\*)$/.test(s) ? '*' : s));
  return `${String(e?.method ?? '').toUpperCase()} ${segs.join('/')}`;
}

/**
 * Another project's calls into this one. `doc` is this project's map, `other` the other project's. A call of the
 * other project is compared when no endpoint of its own provides it (the scanner's own endpoint-missing). Each
 * calling module of the other project is one client: what it calls here that this project provides (`calls`,
 * each with `to`, the module of this project that provides it),
 * and what else it calls that its own project does not provide either (`missing`). A module none of whose calls
 * this project provides is not a client of it, and is not listed: its calls go to a third place, and naming them
 * missing here would say something the two maps do not.
 */
export function compareMaps(doc, other) {
  const own = new Set((other?.provides?.endpoints ?? []).map(endpointKey));
  const here = new Map((doc?.provides?.endpoints ?? []).map((e) => [endpointKey(e), e.module]));
  const names = new Map((other?.nodes ?? []).filter((n) => n.kind === 'module').map((n) => [n.id, n]));
  const by = new Map();
  for (const e of other?.consumes?.endpoints ?? []) {
    const k = endpointKey(e);
    if (own.has(k)) continue;
    const c = by.get(e.module) ?? by.set(e.module, { id: e.module, name: names.get(e.module)?.name ?? e.module, tech: names.get(e.module)?.tech ?? [], calls: [], missing: [] }).get(e.module);
    const call = { method: e.method, path: e.path, evidence: (e.evidence ?? []).slice(0, 1) };
    if (here.has(k)) c.calls.push({ ...call, to: here.get(k) }); else c.missing.push(call);
  }
  return [...by.values()].filter((c) => c.calls.length).sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
}
