// The plan's to-do list, on the graph: the same boxes /crew-todo draws under the status line, read from the plan
// file of the session's project by the server (/api/todo). Done ✓, in work ◐, open ☐; the phase that holds the task in
// work (or the next one) is open, the others fold to one line and open on a click.
//
// A box in the canvas's top right corner, closed with its ×, opened again from View options. A project with no plan
// gets no box: an empty corner says that better than a box saying "nothing".
import { t } from './i18n.js';

const FLAG = 'crewforth-studio-todo';
const CLOSE = '<svg class="ic" viewBox="0 0 16 16" aria-hidden="true"><path d="M4 4l8 8M12 4l-8 8"/></svg>';
export const MARK = { done: '✓', work: '◐', open: '☐' };

/** A mark, with what it is in `data-mark` so the stylesheet can draw ◐, which few fonts draw legibly at 12px. */
function markEl(m) {
  const n = mk('span', 'cv-todo-mark', m);
  n.dataset.mark = m === MARK.done ? 'done' : m === MARK.work ? 'work' : 'open';
  return n;
}

function mk(tag, cls, text) {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text != null) n.textContent = text;
  return n;
}

function readFlag() { try { return globalThis.window?.localStorage?.getItem(FLAG) ?? null; } catch { return null; } }
function writeFlag(v) { try { globalThis.window?.localStorage?.setItem(FLAG, v); } catch { /* blocked storage: for this page only */ } }

/** A phase's mark: ✓ all done · ◐ a task in work or some done · ☐ none started. */
export const phaseMark = (p) => (p.done === p.total ? MARK.done : (p.work || p.done > 0) ? MARK.work : MARK.open);

/** The one line under the title: how far, and which task is in work or next. */
export function todoLine(d) {
  if (!d?.measured) return t('Not read: {reason}', { reason: d?.reason ?? t('no reason given') });
  if (!d.exists) return t('No plan at {file}', { file: d.file });
  if (!d.active) return t('{status}: not the work in progress ({done}/{total} done)', { status: d.status, done: d.done, total: d.total });
  if (!d.total) return t('No task with a box yet');
  const parts = [t('{done}/{total} done', { done: d.done, total: d.total })];
  if (d.ac) parts.push(`AC ${d.ac.done}/${d.ac.total}`);
  if (d.now?.kind === 'done') parts.push(t('all done'));
  return parts.join(' · ');
}

export class TodoBox {
  constructor() {
    this.el = mk('div', 'cv-legend cv-todo');
    this.el.setAttribute('role', 'region');
    this.el.setAttribute('aria-label', t('Plan'));
    const head = mk('div', 'cv-legend-head');
    this.titleEl = mk('span', 'cv-label', t('Plan'));
    const close = mk('button', 'cv-x');
    close.type = 'button';
    close.setAttribute('aria-label', t('Close the plan'));
    close.innerHTML = CLOSE;
    close.addEventListener('click', () => this.show(false));
    head.append(this.titleEl, close);
    this.nameEl = mk('div', 'cv-todo-name');
    this.lineEl = mk('div', 'cv-todo-line');
    this.listEl = mk('div', 'cv-todo-list');
    this.el.append(head, this.nameEl, this.lineEl, this.listEl);
    this.open = readFlag() !== 'closed';
    this.unfolded = new Set();   // phases the viewer opened by hand
    this.folded = new Set();     // the current phase, folded by hand
    this.data = null;
    this.sig = '';
    this.el.hidden = true;
  }

  /** Whether there is a plan to show: the box and the View options entry both ask. */
  get has() { return Boolean(this.data?.measured && this.data.exists); }

  show(on) {
    this.open = Boolean(on);
    writeFlag(on ? 'open' : 'closed');
    this.el.hidden = !this.open || !this.has;
  }

  /** The server's answer, or null when no session is on screen. Redrawn only when it changed. */
  render(d) {
    const sig = JSON.stringify(d ?? null);
    if (sig === this.sig) return;
    if (d?.file !== this.data?.file || d?.cwd !== this.data?.cwd) { this.unfolded.clear(); this.folded.clear(); }
    this.sig = sig;
    this.data = d ?? null;
    this.el.hidden = !this.open || !this.has;
    if (!this.has) return;
    this.nameEl.textContent = d.title || d.file;
    this.nameEl.title = d.file;
    this.lineEl.textContent = todoLine(d);
    const rows = [];
    if (d.active && d.total) {
      const phased = d.phases.length > 1 || d.phases[0]?.name;
      const current = d.now?.phase ?? null;
      for (const p of d.phases) {
        const key = p.name;
        const isCurrent = d.now && d.now.kind !== 'done' && p.name === current;
        const opened = !phased || (isCurrent ? !this.folded.has(key) : this.unfolded.has(key));
        if (phased) {
          const row = mk('button', 'cv-todo-phase');
          row.type = 'button';
          row.dataset.state = p.done === p.total ? 'done' : isCurrent ? 'current' : 'open';
          row.setAttribute('aria-expanded', String(opened));
          row.append(markEl(phaseMark(p)), mk('span', 'cv-todo-text', p.name || t('(no phase)')), mk('span', 'cv-todo-count', `${p.done}/${p.total}`));
          row.addEventListener('click', () => {
            const set = isCurrent ? this.folded : this.unfolded;
            if (set.has(key)) set.delete(key); else set.add(key);
            this.sig = '';
            this.render(this.data);
          });
          rows.push(row);
        }
        if (!opened) continue;
        const nextTask = d.now?.kind === 'next' && isCurrent ? d.now.task : null;
        let saidNext = false;
        for (const task of p.tasks) {
          const r = mk('div', 'cv-todo-task');
          r.dataset.state = task.state;
          if (phased) r.classList.add('cv-todo-in');
          r.append(markEl(MARK[task.state] ?? MARK.open), mk('span', 'cv-todo-text', task.text));
          r.title = task.text;
          if (!saidNext && nextTask === task.text && task.state === 'open') {
            saidNext = true;
            r.dataset.state = 'next';
            r.append(mk('span', 'cv-todo-next', t('next')));
          }
          rows.push(r);
        }
      }
    }
    this.listEl.replaceChildren(...rows);
  }
}
