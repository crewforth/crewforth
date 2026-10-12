// Where a Claude Code agent is defined, as far as that can be read from disk.
//
// Claude Code takes an agent that is not built in from a Markdown file whose frontmatter names it: in the project
// (`.claude/agents/`), in the user's own directory (`~/.claude/agents/`), or in a plugin. This file reads the first
// two and nothing else. It keeps no list of built-in types: an agent found in neither place is reported as not
// found, which is all that is known about it.
//
// Not read: a plugin's files (a plugin agent is told by its name, `plugin:agent`, in web/names.js), agents given
// on the command line, managed settings, and files in a directory under `agents/`.

import fs from 'node:fs';
import path from 'node:path';
import { PROJECTS_ROOT } from './projects.js';

/** The agents one directory defines: { name: file name }. Null when the directory is not there or cannot be read. */
export function agentsIn(dir) {
  let files;
  try { files = fs.readdirSync(dir); } catch { return null; }
  const out = {};
  for (const f of files.sort()) {
    if (!f.endsWith('.md')) continue;
    let src;
    try { src = fs.readFileSync(path.join(dir, f), 'utf8'); } catch { continue; }
    // Frontmatter only, as the palette reads it: a "name:" in the body is not the agent's name.
    const fm = src.replace(/\r\n/g, '\n').split(/^---$/m)[1] ?? '';
    const name = fm.match(/^name:\s*(.+)$/m)?.[1]?.trim().replace(/^["']|["']$/g, '');
    if (name && out[name] === undefined) out[name] = f;
  }
  return out;
}

/** Claude Code's own directory is the parent of its projects directory; the user's agents sit beside the projects. */
export const USER_AGENTS_DIR = path.join(path.dirname(PROJECTS_ROOT), 'agents');

/**
 * @returns { project, user } — each { name: file name }, or null where that directory was not read. A project's
 *          definition is the one Claude Code uses when both name the same agent, and it is listed in both here.
 */
export function agentOrigins(cwd, userDir = USER_AGENTS_DIR) {
  return {
    project: cwd ? agentsIn(path.join(cwd, '.claude', 'agents')) : null,
    user: agentsIn(userDir),
  };
}
