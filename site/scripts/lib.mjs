// Shared by generate.mjs, check.mjs and selftest.mjs. Pure functions over a repository root, so the self-test can
// point them at a mutated copy and prove that a missing translation or page turns the build red.
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

export const LOCALES = ['en', 'tr'];

export class BuildError extends Error {}
export const fail = (msg) => { throw new BuildError(msg); };

export const read = (p) => fs.readFileSync(p, 'utf8').replace(/\r\n/g, '\n');

// Frontmatter of an agent or a skill: the first block between two `---` lines. Handles `key: value` and the folded
// `description: |` form the payload uses; `metadata:` is read for `kind: command`.
export function frontmatter(file) {
  const lines = read(file).split('\n');
  if (lines[0] !== '---') fail(`${file}: no frontmatter`);
  const end = lines.indexOf('---', 1);
  if (end < 0) fail(`${file}: unterminated frontmatter`);
  const fm = {}; let key = null;
  for (const line of lines.slice(1, end)) {
    const m = line.match(/^([A-Za-z_-]+):\s*(.*)$/);
    if (m) { key = m[1]; fm[key] = m[2] === '|' || m[2] === '>' ? '' : m[2]; continue; }
    if (key && /^\s+/.test(line)) fm[key] = (fm[key] ? fm[key] + ' ' : '') + line.trim();
  }
  return fm;
}

// The first sentence of a description, markdown emphasis removed. A sentence ends at `.`/`!`/`?` followed by a space
// or the end — "etc.)" and "e.g." inside a sentence do not end it because no space follows the dot there.
export function firstSentence(text) {
  const t = String(text ?? '').replace(/\*\*/g, '').replace(/\s+/g, ' ').trim();
  const m = t.match(/^(.+?[.!?])(\s|$)/);
  return (m ? m[1] : t).trim();
}

export const cell = (s) => String(s).replace(/\|/g, '\\|');

export function tsv(file) {
  const map = new Map();
  for (const line of read(file).split('\n')) {
    if (!line || line.startsWith('#')) continue;
    const i = line.indexOf('\t');
    if (i < 0) fail(`${file}: a line without a TAB: ${line.slice(0, 60)}`);
    map.set(line.slice(0, i), line.slice(i + 1));
  }
  return map;
}

export function agents(root) {
  const dir = path.join(root, 'kit/agents');
  return fs.readdirSync(dir).filter((f) => /^crew-.*\.md$/.test(f)).sort().map((f) => {
    const fm = frontmatter(path.join(dir, f));
    return { name: fm.name || f.replace(/\.md$/, ''), summary: firstSentence(fm.description) };
  });
}

// Skills split in two: a skill whose metadata marks it `kind: command` is a command (since 3.0). One marked
// `experimental: true` still installs and still answers when typed, but no page counts or lists it.
export function skillsAndCommands(root) {
  const dir = path.join(root, 'kit/skills');
  const skills = []; const commands = [];
  for (const d of fs.readdirSync(dir).sort()) {
    const f = path.join(dir, d, 'SKILL.md');
    if (!fs.existsSync(f)) continue;
    const raw = read(f);
    if (/^\s+experimental:\s*true\s*$/m.test(raw.split('\n---')[0])) continue;
    const fm = frontmatter(f);
    const item = { name: fm.name || d, summary: firstSentence(fm.description) };
    if (/^\s+kind:\s*command\s*$/m.test(raw.split('\n---')[0])) {
      item.userOnly = /^disable-model-invocation:\s*true\s*$/m.test(raw);
      commands.push(item);
    } else skills.push(item);
  }
  return { skills, commands };
}

// Context-fill thresholds, read from the hook that enforces them: `[ "$INT" -ge 90 ] && TIER=90`.
export function fillThresholds(root) {
  const src = read(path.join(root, 'kit/hooks/session-guard.sh'));
  const t = [...src.matchAll(/\[\s*"\$INT"\s+-ge\s+(\d+)\s*\]\s*&&\s*TIER=\1/g)].map((m) => Number(m[1])).sort((a, b) => a - b);
  if (t.length !== 2) fail(`session-guard.sh: expected two fill thresholds, read ${t.length} — the hook changed shape`);
  return { warn: t[0], alert: t[1] };
}

// The gate inventory, from gate-report.sh itself (the one place it is derived from the hooks), run against a scratch
// project that holds only the hooks. Labels lose a trailing `(${VAR:-x})`, which the report prints unexpanded.
export function gateRules(root) {
  const tmp = fs.mkdtempSync(path.join(fs.realpathSync(process.env.TMPDIR || '/tmp'), 'crew-site-gates-'));
  try {
    fs.cpSync(path.join(root, 'kit/hooks'), path.join(tmp, '.claude/hooks'), { recursive: true });
    fs.writeFileSync(path.join(tmp, 'log.tsv'), '');
    let out;
    try { out = execFileSync('bash', [path.join(root, 'kit/eval/gate-report.sh'), '--log', 'log.tsv'], { cwd: tmp, encoding: 'utf8' }); }
    catch (e) { out = String(e.stdout ?? ''); }
    const at = out.indexOf('wired but not observed');
    if (at < 0) fail('gate-report.sh printed no rule inventory — the report changed shape');
    const rules = out.slice(at).split('\n').filter((l) => /^\s*·/.test(l))
      .map((l) => l.replace(/^\s*·\s*/, '').replace(/\s*\(\$\{[^}]*\}\)$/, '').trim());
    const n = Number((out.slice(at).match(/\((\d+) of (\d+)\)/) || [])[2]);
    if (!rules.length || rules.length !== n) fail(`gate-report.sh inventory: read ${rules.length} rule(s), the report says ${n}`);
    return rules;
  } finally { fs.rmSync(tmp, { recursive: true, force: true }); }
}

// The two counts the network diagrams print ("12 agents · 40 skills"), read from each SVG's <title>, which carries
// the diagram's words as text (the drawing itself is outlines). A stale picture is the claim a reader never checks.
export function checkNetworkSvgs(root, nAgents, nSkills) {
  for (const loc of ['en', 'tr']) for (const theme of ['dark', 'light']) {
    const n = `network-${loc}-${theme}`, f = path.join(root, 'assets', `${n}.svg`);
    if (!fs.existsSync(f)) fail(`assets/${n}.svg is missing — the skills page embeds it`);
    const m = (read(f).match(/<title[^>]*>[^<]*?(\d+) (?:agents|ajan) · (\d+) skills?/) || []);
    if (!m[1]) fail(`assets/${n}.svg has no readable count in its <title>`);
    if (Number(m[1]) !== nAgents || Number(m[2]) !== nSkills) fail(`assets/${n}.svg says ${m[1]} / ${m[2]} but the payload is ${nAgents} / ${nSkills} — rerun: node packaging/gen-diagrams.mjs`);
  }
}

// The always-on cost, measured exactly the way smoke-test.sh §6f measures it, so the page quoting it cannot drift:
// the discipline half of kit/CLAUDE.md (every line before the KIT:DISCIPLINE-END sentinel), plus the frontmatter of
// every agent and of every skill Claude can invoke (a `disable-model-invocation: true` skill costs the listing
// nothing), each without its `metadata:` block. Bytes of UTF-8, one newline per line, as `wc -c` counts them.
const bytes = (lines) => lines.reduce((n, l) => n + Buffer.byteLength(l, 'utf8') + 1, 0);
export function frontmatterBytes(file) {
  const out = []; let c = 0; let meta = false;
  for (const line of read(file).split('\n')) {
    if (line === '---') { c++; if (c > 1) break; continue; }
    if (c !== 1) continue;
    if (/^metadata:/.test(line)) { meta = true; continue; }
    if (meta && /^[ \t]/.test(line)) continue;
    meta = false; out.push(line);
  }
  return bytes(out);
}
export function alwaysOn(root) {
  const disc = read(path.join(root, 'kit/CLAUDE.md')).split('\n');
  const end = disc.findIndex((l) => l.startsWith('<!-- KIT:DISCIPLINE-END'));
  if (end < 0) fail('kit/CLAUDE.md: the KIT:DISCIPLINE-END sentinel is gone');
  const discipline = bytes(disc.slice(0, end));
  const agentFiles = fs.readdirSync(path.join(root, 'kit/agents')).filter((f) => f.endsWith('.md')).map((f) => path.join(root, 'kit/agents', f));
  const skillFiles = fs.readdirSync(path.join(root, 'kit/skills')).map((d) => path.join(root, 'kit/skills', d, 'SKILL.md'))
    .filter((f) => fs.existsSync(f) && !/^disable-model-invocation:\s*true/m.test(read(f)));
  const agentsB = agentFiles.reduce((n, f) => n + frontmatterBytes(f), 0);
  const skillsB = skillFiles.reduce((n, f) => n + frontmatterBytes(f), 0);
  const ui = ['kit/skills/a11y/SKILL.md', 'kit/skills/frontend/SKILL.md', 'kit/skills/frontend-design/SKILL.md',
    'kit/skills/frontend-rn-expo/SKILL.md', 'kit/skills/frontend-flutter/SKILL.md', 'kit/agents/crew-frontend-expert.md'].reduce((n, f) => n + frontmatterBytes(path.join(root, f)), 0);
  return { discipline, agents: agentsB, skills: skillsB, total: discipline + agentsB + skillsB, descriptions: agentsB + skillsB, ui };
}

// Each agent's stage, from its own frontmatter (`metadata: stage: …`; the metadata block is Crewforth's catalogue
// data — Claude Code ignores it, and smoke's always-on budget does not count it). The diagrams read it directly
// (packaging/gen-diagrams.mjs); the hand-written agents table on the skills page must agree with it.
export const STAGES = ['understand', 'produce', 'audit', 'close', 'handoff'];
export function stages(root) {
  const dir = path.join(root, 'kit/agents');
  const map = new Map();
  for (const f of fs.readdirSync(dir).filter((x) => /^crew-.*\.md$/.test(x)).sort()) {
    const fm = frontmatter(path.join(dir, f));
    const s = (String(fm.metadata || '').match(/(?:^|\s)stage:\s*([a-z]+)/) || [])[1];
    if (!STAGES.includes(s)) fail(`kit/agents/${f}: metadata.stage is ${s ? `"${s}"` : 'missing'} — one of ${STAGES.join(', ')}`);
    map.set(fm.name || f.replace(/\.md$/, ''), s);
  }
  const drift = [];
  const tableNames = { en: { Understand: 'understand', Produce: 'produce', Audit: 'audit', Close: 'close', 'Hand off': 'handoff' },
    tr: { Anla: 'understand', 'Üret': 'produce', Denetle: 'audit', Kapat: 'close', Devret: 'handoff' } };
  for (const loc of ['en', 'tr']) {
    const rows = [...read(path.join(root, 'site/content', loc, 'skills.md')).matchAll(/^\| `(crew-[a-z-]+)` \| ([^|]+?) \|/gm)];
    if (rows.length !== map.size) drift.push(`site/content/${loc}/skills.md lists ${rows.length} agent(s), the payload has ${map.size}`);
    for (const [, a, st] of rows) if (map.get(a) !== tableNames[loc][st.trim()]) drift.push(`site/content/${loc}/skills.md puts ${a} under "${st.trim()}", its frontmatter says ${map.get(a) ?? 'nothing'}`);
  }
  if (drift.length) fail(`the agents' stages disagree:\n  ${drift.join('\n  ')}`);
  return map;
}

// The install commands, from the README's own "Install and update" table: every inline-code span of each row, in
// order. The home page quotes them rather than keeping a second copy (5b renames the marketplace once).
export function installRows(root, loc) {
  const text = read(path.join(root, loc === 'en' ? 'README.md' : `README.${loc}.md`));
  const head = loc === 'en' ? '## Install and update' : '## Kurulum ve güncelleme';
  const sec = text.split(head)[1];
  if (!sec) fail(`README${loc === 'en' ? '' : '.' + loc}.md: no "${head}" section`);
  const rows = [...sec.split('\n## ')[0].matchAll(/^\| ([^|]+?) \| (.+) \|$/gm)];
  const all = rows.map(([, title, cmds]) => ({ title: title.trim(), cmds: [...cmds.matchAll(/`([^`]+)`/g)].map((m) => m[1]), text: cmds }));
  // Two channels carry commands (npx, the plugin); the release archive is one row with a link and no command, and the
  // home page points at it with its own line. Both counts are pinned: a row that comes back, or goes, fails the build.
  const out = all.filter((r) => r.cmds.length).map(({ title, cmds }) => ({ title, cmds }));
  const archive = all.filter((r) => !r.cmds.length && /\]\(https:\/\/crewforth\.com\/(tr\/)?install\/?\)/.test(r.text));
  const readme = `README${loc === 'en' ? '' : '.' + loc}.md`;
  if (out.length !== 2) fail(`${readme}: the install table has ${out.length} channel row(s), expected 2 (npx, Claude Code plugin)`);
  if (archive.length !== 1) fail(`${readme}: the install table has ${archive.length} release-archive row(s) linking to crewforth.com/install, expected 1`);
  return out;
}
