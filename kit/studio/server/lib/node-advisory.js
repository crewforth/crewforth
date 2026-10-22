// Is the Node running this panel missing a published security fix? The table is eval/lib/node-advisory.tsv, the
// same file eval/doctor.sh reads, so the two cannot disagree. A warning only: the panel still starts.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const TABLE = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..', 'eval', 'lib', 'node-advisory.tsv');

/** The table's text as { url, lines: Map(major -> 'x.y.z') }; null when it holds no release line. */
export function parseAdvisory(text) {
  let url = '';
  const lines = new Map();
  for (const raw of String(text ?? '').split(/\r?\n/)) {
    if (!raw || raw.startsWith('#')) continue;
    const [k, v] = raw.split('\t');
    if (k === 'advisory') url = v ?? '';
    else if (/^\d+$/.test(k) && /^\d+\.\d+\.\d+$/.test(v ?? '')) lines.set(Number(k), v);
  }
  return lines.size ? { url, lines } : null;
}

const parts = (v) => String(v).replace(/^v/, '').split('.').map((n) => Number.parseInt(n, 10) || 0);
const below = (a, b) => { const x = parts(a), y = parts(b); for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] < y[i]; return false; };

/**
 * The sentence to print for `version` (process.versions.node), or null when there is nothing to say: it carries
 * its line's fixes, its line is newer than the table, or the table could not be read.
 */
export function judgeNode(version, advisory) {
  if (!advisory || !/^\d+\.\d+\.\d+/.test(String(version ?? ''))) return null;
  const major = parts(version)[0];
  const newest = Math.max(...advisory.lines.keys());
  if (major > newest) return null;
  const fixed = advisory.lines.get(major);
  if (fixed && !below(version, fixed)) return null;
  return fixed
    ? `Node ${version} is below ${fixed}, the release of its line with the fixes of ${advisory.url} — update Node`
    : `Node ${version} is on a line that no longer gets security fixes (${advisory.url} fixes ${[...advisory.lines.values()].join(', ')}) — update Node`;
}

/** judgeNode for the running process, reading the table from disk; null when the table is not there. */
export function nodeAdvisoryNote(version = process.versions.node) {
  let text;
  try { text = fs.readFileSync(TABLE, 'utf8'); } catch { return null; }
  return judgeNode(version, parseAdvisory(text));
}
