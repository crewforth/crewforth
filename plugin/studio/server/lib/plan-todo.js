// The plan's to-do list, as /crew-todo draws it under the status line, for the panel.
//
// The source is the plan file itself: docs/PLAN.md, or the file /crew-todo was pointed at (its name is kept in
// .claude/state/todo/path). The rules are todo.awk's, read the same way, so the panel and the status line never
// disagree about what is done:
//
//   a task      a list item at the margin whose text starts with a box: `- [ ] …` `- [x] …` `1. [ ] …`
//               [ ] open · [x] done · [~] or [>] in work. A box indented under a task is a sub-step, not a task.
//   a phase     a heading (## or deeper) with at least one task under it.
//   the scope   under a `## Tasks` heading (or Görevler, İşler, To-do) when the plan has one, else the whole file.
//               An `Acceptance criteria` section is never a phase: its boxes are counted as AC n/m.
//   the status  a `status: <word>` line above the first ## heading. paused, on hold, stopped, dropped, abandoned,
//               cancelled, superseded, replaced, done, closed (or beklemede, durduruldu, bırakıldı, iptal, bitti)
//               mean the plan is not the work in progress.
//   code blocks are skipped.
//
// In work is a task marked [~]/[>], the first one. With none marked, the first open task is the next one, never
// "in work". Nothing here writes anything.

import fs from 'node:fs';
import path from 'node:path';

const DEFAULT_PLAN = 'docs/PLAN.md';
// A plan is a page of text. Past this it is not read: the answer says so instead of the panel stalling on it.
export const MAX_PLAN_BYTES = 512 * 1024;

const INACTIVE = /^(paused|hold|stopped|dropped|abandoned|cancell?ed|superseded|replaced|done|closed|beklemede|durduruldu|bırakıldı|iptal|bitti)$/;
const isAc = (t) => /^([Aa]cceptance [Cc]riteria|[Kk]abul [Kk]riter)/.test(t);
const isTasks = (t) => /^([Tt]asks|TASKS|[Gg]örevler|GÖREVLER|[İi]şler|İŞLER|[Tt]o-?[Dd]o|TODO)([^A-Za-z]|$)/u.test(t);

/** True when a `status:` value says the plan is not the work in progress. */
export function inactiveStatus(s) {
  const low = String(s ?? '').toLowerCase();
  if (/^on[ -]hold/.test(low)) return true;
  return INACTIVE.test(low.replace(/[ \t.,;:(].*$/, ''));
}

/**
 * Read a plan's text into its phases and tasks.
 * @returns { title, status, active, total, done, ac, now, phases }
 *   now: { kind: 'work' | 'next', phase, task } for the task in work or the next one, { kind: 'done' } when every
 *   task is done, null when there is no task. phases: [{ name, total, done, work, tasks: [{ text, state }] }],
 *   state 'done' | 'work' | 'open'; a phase's name is '' for tasks that stand before any heading.
 */
export function parsePlan(text) {
  const ev = [];
  let fence = '';
  let status = '';
  let inHead = true;
  for (const raw of String(text ?? '').split('\n')) {
    const line = raw.replace(/\r$/, '');
    const f = /^ *(```|~~~)/.exec(line);
    if (f) { if (!fence) fence = f[1]; else if (f[1] === fence) fence = ''; continue; }
    if (fence) continue;
    if (inHead && !status && /^ *\**[Ss][Tt][Aa][Tt][Uu][Ss]\**:/.test(line)) {
      status = line.replace(/^[^:]*:\**[ \t]*/, '').replace(/[ \t]+$/, '') || 'active';
      continue;
    }
    const h = /^(#+)[ \t]+(.*)$/.exec(line);
    if (h) {
      if (h[1].length >= 2) inHead = false;
      ev.push({ k: 'H', lv: h[1].length, t: h[2].replace(/[ \t]+#*[ \t]*$/, '') });
      continue;
    }
    const ind = /^ */.exec(line)[0].length;
    if (ind > 1) continue;
    const rest = line.slice(ind);
    const m = /^(?:[-*+]|(\d+)[.)])[ \t]+\[([ xX~>])\][ \t]+/.exec(rest);
    if (!m) continue;
    let txt = rest.slice(m[0].length);
    const cut = txt.indexOf(' — ');
    if (cut > 0) txt = txt.slice(0, cut);
    txt = txt.replace(/[ \t]+$/, '');
    if (m[1]) txt = `${m[1]}. ${txt}`;
    const b = m[2];
    ev.push({ k: 'I', st: b === 'x' || b === 'X' ? 'done' : b === '~' || b === '>' ? 'work' : 'open', t: txt });
  }

  const title = ev.find((e) => e.k === 'H' && e.lv === 1)?.t ?? '';
  // The scope: under a Tasks heading when the plan has one.
  let s0 = 0; let s1 = ev.length - 1; let base = 1;
  const ti = ev.findIndex((e) => e.k === 'H' && e.lv >= 2 && isTasks(e.t));
  if (ti >= 0) {
    s0 = ti + 1; base = ev[ti].lv;
    for (let j = ti + 1; j < ev.length; j += 1) if (ev[j].k === 'H' && ev[j].lv <= base) { s1 = j - 1; break; }
  }
  // Acceptance criteria, wherever they are: counted, never a phase.
  let acTotal = 0; let acDone = 0; let inAc = false; let acLv = 0;
  for (const e of ev) {
    if (e.k === 'H') { if (inAc && e.lv <= acLv) inAc = false; if (isAc(e.t)) { inAc = true; acLv = e.lv; } } else if (inAc) { acTotal += 1; if (e.st === 'done') acDone += 1; }
  }
  const phases = [];
  let cur = null; let skip = false; let skipLv = 0;
  for (let i = s0; i <= s1; i += 1) {
    const e = ev[i];
    if (e.k === 'H') {
      if (skip && e.lv <= skipLv) skip = false;
      if (e.lv <= base && base > 1) continue;
      if (isAc(e.t) || (e.lv === 1 && base === 1)) { if (isAc(e.t)) { skip = true; skipLv = e.lv; } cur = null; continue; }
      if (skip) continue;
      cur = { name: e.t, total: 0, done: 0, work: false, tasks: [] };
      phases.push(cur);
      continue;
    }
    if (skip) continue;
    if (!cur) { cur = { name: '', total: 0, done: 0, work: false, tasks: [] }; phases.push(cur); }
    cur.tasks.push({ text: e.t, state: e.st });
    cur.total += 1;
    if (e.st === 'done') cur.done += 1;
    if (e.st === 'work') cur.work = true;
  }
  const shown = phases.filter((p) => p.total > 0);
  const total = shown.reduce((a, p) => a + p.total, 0);
  const done = shown.reduce((a, p) => a + p.done, 0);
  let now = null;
  if (total) {
    for (const want of ['work', 'open']) {
      for (const p of shown) {
        const task = p.tasks.find((t) => t.state === want);
        if (task) { now = { kind: want === 'work' ? 'work' : 'next', phase: p.name, task: task.text }; break; }
      }
      if (now) break;
    }
    now ??= { kind: 'done' };
  }
  return {
    title,
    status: status || 'active',
    active: !inactiveStatus(status),
    total,
    done,
    ac: acTotal ? { total: acTotal, done: acDone } : null,
    now,
    phases: shown,
  };
}

/** The plan file a project's panel reads, relative to the project as it was written: the state file's, else docs/PLAN.md. */
export function planFileOf(cwd) {
  try {
    const named = fs.readFileSync(path.join(cwd, '.claude', 'state', 'todo', 'path'), 'utf8').split('\n')[0].replace(/\r$/, '').trim();
    if (named) return named;
  } catch { /* none named: the default */ }
  return DEFAULT_PLAN;
}

/**
 * The to-do list of the project at `cwd`, for the panel.
 * Only a file inside the project is read: a path that leaves it (`..`, an absolute path elsewhere, a link out) is
 * refused and said so, never followed.
 */
export function readPlanTodo(cwd) {
  if (typeof cwd !== 'string' || !cwd) return { measured: false, reason: 'no project named' };
  const file = planFileOf(cwd);
  let root;
  try { root = fs.realpathSync(cwd); } catch { return { measured: false, file, reason: 'the project directory is not there' }; }
  const abs = path.resolve(root, file);
  let real;
  try { real = fs.realpathSync(abs); } catch { return { measured: true, file, exists: false }; }
  const rel = path.relative(root, real);
  if (!rel || rel.startsWith('..') || path.isAbsolute(rel)) {
    return { measured: false, file, reason: 'the plan file is outside the project, so the panel does not read it' };
  }
  let st;
  try { st = fs.statSync(real); } catch { return { measured: true, file, exists: false }; }
  if (!st.isFile()) return { measured: false, file, reason: 'the plan path is not a file' };
  if (st.size > MAX_PLAN_BYTES) return { measured: false, file, reason: `the plan file is larger than ${MAX_PLAN_BYTES / 1024} KB` };
  let text;
  try { text = fs.readFileSync(real, 'utf8'); } catch (e) { return { measured: false, file, reason: `not read: ${e.code ?? e.message}` }; }
  return { measured: true, file, exists: true, modifiedAt: st.mtimeMs, ...parsePlan(text) };
}
