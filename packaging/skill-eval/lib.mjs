// lib.mjs — what run.mjs and check.mjs share: a skill's description, its hash, the routing rows that are its cases,
// and the result file. One definition of each, read by both.
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

// SKILL_EVAL_ROOT points the tools at another tree: only the gate's own tests set it.
export const ROOT = process.env.SKILL_EVAL_ROOT ? path.resolve(process.env.SKILL_EVAL_ROOT)
  : path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');   // not URL.pathname: on Windows that is /C:/…
export const RESULTS = path.join(ROOT, 'packaging', 'skill-eval', 'results.tsv');
export const BASELINE = path.join(ROOT, 'packaging', 'skill-eval', 'baseline.tsv');
// The two routing sets. The held-out one was written without reading the triggers, so it is the honest measure of a
// description reaching a request; the working set's positives were derived from the triggers, but its negatives
// (`!target`) still ask the question that matters for a widened description: does it now take a neighbour's work.
export const SETS = [
  { file: 'kit/eval/golden-holdout.txt', source: 'holdout' },
  { file: 'kit/eval/golden-routing.txt', source: 'working' },
];

/** The `description:` of a SKILL.md frontmatter, a block (`|`) or one line, with the indentation taken off. */
export function descriptionOf(text) {
  const m = String(text ?? '').match(/^---\r?\n([\s\S]*?)\r?\n---/);
  if (!m) return null;
  const lines = m[1].split(/\r?\n/);
  const i = lines.findIndex((l) => /^description:/.test(l));
  if (i < 0) return null;
  const first = lines[i].replace(/^description:\s*/, '');
  if (first && !/^[|>][+-]?$/.test(first)) return first.trim();
  const out = [];
  for (const l of lines.slice(i + 1)) { if (/^\S/.test(l)) break; out.push(l.trim()); }
  return out.join('\n').trim();
}

/** A skill the user calls by name (`metadata.kind: command`): the model does not pick it from its description. */
export function isCommand(text) {
  const m = String(text ?? '').match(/^---\r?\n([\s\S]*?)\r?\n---/);
  return Boolean(m && /^metadata:\s*\r?\n(?:[ \t]+.*\r?\n)*?[ \t]+kind:\s*command\s*$/m.test(m[1] + '\n'));
}

export const commandSkills = () => new Set(fs.readdirSync(path.join(ROOT, 'kit', 'skills')).filter((n) => {
  const f = path.join(ROOT, 'kit', 'skills', n, 'SKILL.md');
  return fs.existsSync(f) && isCommand(fs.readFileSync(f, 'utf8'));
}));

export const hashOf = (s) => crypto.createHash('sha256').update(s ?? '').digest('hex').slice(0, 16);

/** Every skill of a tree (the working tree, or a git ref) by name, with its description. */
export function skillsAt(ref = null) {
  const out = new Map();
  if (!ref) {
    for (const name of fs.readdirSync(path.join(ROOT, 'kit', 'skills')).sort()) {
      const f = path.join(ROOT, 'kit', 'skills', name, 'SKILL.md');
      if (fs.existsSync(f)) out.set(name, descriptionOf(fs.readFileSync(f, 'utf8')));
    }
    return out;
  }
  const list = execFileSync('git', ['-C', ROOT, 'ls-tree', '--name-only', `${ref}:kit/skills`], { encoding: 'utf8' });
  for (const name of list.split('\n').filter(Boolean).sort()) {
    try {
      out.set(name, descriptionOf(execFileSync('git', ['-C', ROOT, 'show', `${ref}:kit/skills/${name}/SKILL.md`], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] })));
    } catch { /* a directory with no SKILL.md at that ref */ }
  }
  return out;
}

/** The skills whose description differs from `ref`'s, a new skill included. A removed one has nothing to measure. */
export function changedSince(ref) {
  const now = skillsAt(null);
  const then = skillsAt(ref);
  return [...now.keys()].filter((k) => now.get(k) !== then.get(k)).sort();
}

/**
 * The cases of the given skills: each row of the two sets whose target is one of them. A positive row asks that the
 * skill is invoked, a `!` row that it is not. The prompt is used as it is written: editing it toward the trigger is
 * the thing a held-out set exists to catch.
 */
export function casesFor(skills) {
  const want = new Set(skills);
  const out = [];
  for (const { file, source } of SETS) {
    const text = fs.readFileSync(path.join(ROOT, file), 'utf8');
    for (const raw of text.split(/\r?\n/)) {
      const line = raw.trim();
      if (!line || line.startsWith('#')) continue;
      const cut = line.lastIndexOf('|');
      if (cut < 0) continue;
      const prompt = line.slice(0, cut).trim();
      let target = line.slice(cut + 1).trim();
      const negative = target.startsWith('!');
      if (negative) target = target.slice(1);
      if (!want.has(target) || !prompt) continue;
      const id = `${source}-${negative ? 'not' : 'is'}-${target}-${hashOf(prompt).slice(0, 8)}`;
      out.push({ id, skill: target, negative, source, prompt });
    }
  }
  return out;
}

/** results.tsv: one line per case, under a header that names the descriptions it measured. */
// score is the mean of the case's runs, worst the lowest run: the baseline is built from worst (several runs' floor).
export const RESULT_COLUMNS = ['case', 'skill', 'kind', 'source', 'description', 'score', 'worst', 'runs'];

export function readResults(file = RESULTS) {
  if (!fs.existsSync(file)) return null;
  const rows = [];
  for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
    if (!line || line.startsWith('#')) continue;
    const f = line.split('\t');
    if (f[0] === 'case') continue;
    rows.push({ case: f[0], skill: f[1], kind: f[2], source: f[3], description: f[4], score: Number(f[5]), worst: Number(f[6]), runs: Number(f[7]) });
  }
  return rows;
}

/** baseline.tsv: case, the floor its score may not go under. Only ever raised (run.mjs --baseline). */
export function readBaseline(file = BASELINE) {
  const out = new Map();
  if (!fs.existsSync(file)) return out;
  for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
    if (!line || line.startsWith('#') || line.startsWith('case\t')) continue;
    const [c, floor] = line.split('\t');
    if (c && Number.isFinite(Number(floor))) out.set(c, Number(floor));
  }
  return out;
}
