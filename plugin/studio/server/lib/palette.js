// Node colours.
//
// Crewforth's agents already declare a colour in their frontmatter; the hex
// values below give each of those names one shade, so an agent keeps the same
// colour in every session the panel draws.
//
// The map holds Crewforth's own agents and nothing else: the ones in its own
// agents directory. There is no list of Claude Code's built-in agent types
// here. There was one, and it went stale the first time Claude Code added a
// type: its own "Workflow Subagent" was drawn as "not declared by Claude Code".
// Whatever is not Crewforth's is a Claude Code agent, whoever defined it.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));

/**
 * Where Crewforth's agents sit, relative to this file.
 *
 * One rule, no candidate list: the panel lives inside the component tree it
 * reads, so `<studio>/../agents` is the answer in the repo (`kit/`),
 * in an install (`.claude/`) and in a plugin root alike. A two-candidate
 * resolver would be a branch exercised in one layout and rotting in the other.
 *
 * `here` is a parameter rather than a closed-over constant so the rule can be
 * measured against a synthetic tree instead of only against this checkout.
 * Returns null when the directory is not there — the caller must report that,
 * never render it as "no kit agents".
 */
function agentsDirFor(here) {
  const dir = path.resolve(here, '..', '..', '..', 'agents');
  try { return fs.statSync(dir).isDirectory() ? dir : null; } catch { return null; }
}

const AGENTS_DIR = agentsDirFor(HERE);

// The names agents declare, mapped onto hex values.
const NAMED = {
  green: '#35c874',
  cyan: '#26c6e6',
  blue: '#5b8cff',
  orange: '#f2a65a',
  purple: '#b07cf6',
  red: '#ff8a4d',
  pink: '#ffbc8a',
  yellow: '#db5f1c',
};

const UNKNOWN = '#94a3c8';

let cached = null;

function readKitAgents() {
  const out = {};
  if (!AGENTS_DIR) return null;
  let files;
  // null, not {}: an empty map and an unreadable directory are the same picture
  // on screen — twelve grey rings — and only one of them is the truth.
  try { files = fs.readdirSync(AGENTS_DIR); } catch { return null; }

  for (const f of files) {
    if (!f.endsWith('.md')) continue;
    let src;
    try { src = fs.readFileSync(path.join(AGENTS_DIR, f), 'utf8'); } catch { continue; }
    // Frontmatter only: stop at the closing fence so a colon in the body cannot
    // masquerade as a field.
    const fm = src.split(/^---$/m)[1] ?? '';
    const name = fm.match(/^name:\s*(.+)$/m)?.[1]?.trim();
    const color = fm.match(/^color:\s*(.+)$/m)?.[1]?.trim();
    if (name) out[name] = { color: color ?? null, hex: color ? (NAMED[color] ?? null) : null, source: 'kit' };
  }
  return out;
}

export function palette() {
  if (cached) return cached;
  const kit = readKitAgents();
  const measured = kit !== null;
  const map = {};
  for (const [name, v] of Object.entries(kit ?? {})) {
    map[name] = { hex: v.hex ?? UNKNOWN, declared: v.color, known: Boolean(v.hex), source: 'kit' };
  }
  cached = {
    map,
    unknown: UNKNOWN,
    named: NAMED,
    kitAgents: measured ? Object.keys(kit).length : 0,
    agentsDir: AGENTS_DIR ?? path.resolve(HERE, '..', '..', '..', 'agents'),
    measured,
    reason: measured ? null : `no agents directory beside the panel at ${path.resolve(HERE, '..', '..', '..', 'agents')}`,
  };
  return cached;
}

export function colorFor(agentType) {
  const p = palette();
  return p.map[agentType]?.hex ?? p.unknown;
}

// The resolver, exported for measurement: the pin drives it against synthetic
// trees, which is the only way to prove the "one rule, every layout" claim
// without three checkouts.
export const _internals = { agentsDirFor };
