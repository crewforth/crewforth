// The plan's to-do list, on the graph: the same boxes /crew-todo draws under the status line, read from the plan
// file of the session's project by the server (/api/todo). Done ✓, in work ◐, open ☐; the phase that holds the task in
// work (or the next one) is open, the others fold to one line and open on a click.
//
// A box in the canvas's top right corner, closed with its ×. Closed, a small "Plan" tab stays in the corner and opens
// it again (View options holds the same entry, but only a narrow toolbar shows that button). A project with no plan
// gets no box: an empty corner says that better than a box saying "nothing".
import { t } from './i18n.js';

const FLAG = 'crewforth-studio-todo';
const SIZE = 'crewforth-studio-todo-size';
const MIN_W = 200;
const MIN_H = 120;
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

/** The size the viewer dragged the box to, or null: a stored value that is not two finite numbers is no size. */
export function readSize() {
  try {
    const v = JSON.parse(globalThis.window?.localStorage?.getItem(SIZE) ?? 'null');
    return v && Number.isFinite(v.w) && Number.isFinite(v.h) ? { w: Math.max(MIN_W, v.w), h: Math.max(MIN_H, v.h) } : null;
  } catch { return null; }
}
function writeSize(w, h) { try { globalThis.window?.localStorage?.setItem(SIZE, JSON.stringify({ w: Math.round(w), h: Math.round(h) })); } catch { /* blocked storage: for this page only */ } }
function clearSize() { try { globalThis.window?.localStorage?.removeItem(SIZE); } catch { /* blocked storage */ } }

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
    // The box hangs from the top right corner, so it grows to the left and down: the handle is its bottom left.
    const grip = mk('div', 'cv-todo-grip');
    grip.setAttribute('role', 'separator');
    grip.setAttribute('aria-label', t('Resize the plan (double-click to reset)'));
    grip.title = t('Resize the plan (double-click to reset)');
    grip.addEventListener('pointerdown', (e) => this.#drag(e, grip));
    grip.addEventListener('dblclick', () => { clearSize(); this.#applySize(null); });
    this.el.append(head, this.nameEl, this.lineEl, this.listEl, grip);
    // What is left of a closed box: the way back, in the same corner.
    this.chip = mk('button', 'cv-todo-chip', t('Plan'));
    this.chip.type = 'button';
    this.chip.title = t('Show the plan\'s to-do list');
    this.chip.addEventListener('click', () => this.show(true));
    this.chip.hidden = true;
    this.#applySize(readSize());
    this.open = readFlag() !== 'closed';
    this.unfolded = new Set();   // phases the viewer opened by hand
    this.folded = new Set();     // the current phase, folded by hand
    this.data = null;
    this.sig = '';
    this.el.hidden = true;
  }

  #applySize(sz) {
    this.el.style.width = sz ? `${sz.w}px` : '';
    this.el.style.height = sz ? `${sz.h}px` : '';
  }

  #drag(e, grip) {
    const parent = this.el.parentElement;
    const box = this.el.getBoundingClientRect();
    const room = parent?.getBoundingClientRect();
    const maxW = room ? room.width - 24 : Infinity;
    const maxH = room ? room.height - 24 : Infinity;
    const x0 = e.clientX, y0 = e.clientY;
    let w = box.width, h = box.height;
    e.preventDefault();
    grip.setPointerCapture?.(e.pointerId);
    const move = (m) => {
      w = Math.min(maxW, Math.max(MIN_W, box.width + (x0 - m.clientX)));
      h = Math.min(maxH, Math.max(MIN_H, box.height + (m.clientY - y0)));
      this.#applySize({ w, h });
    };
    const end = () => {
      grip.removeEventListener('pointermove', move);
      grip.removeEventListener('pointerup', end);
      grip.removeEventListener('pointercancel', end);
      writeSize(w, h);
    };
    grip.addEventListener('pointermove', move);
    grip.addEventListener('pointerup', end);
    grip.addEventListener('pointercancel', end);
  }

  /** Whether there is a plan to show: the box and the View options entry both ask. */
  get has() { return Boolean(this.data?.measured && this.data.exists); }

  show(on) {
    this.open = Boolean(on);
    writeFlag(on ? 'open' : 'closed');
    this.#sync();
  }

  #sync() {
    this.el.hidden = !this.open || !this.has;
    this.chip.hidden = this.open || !this.has;
  }

  /** The server's answer, or null when no session is on screen. Redrawn only when it changed. */
  render(d) {
    const sig = JSON.stringify(d ?? null);
    if (sig === this.sig) return;
    if (d?.file !== this.data?.file || d?.cwd !== this.data?.cwd) { this.unfolded.clear(); this.folded.clear(); }
    this.sig = sig;
    this.data = d ?? null;
    this.#sync();
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
          row.title = p.name || '';
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
